# =============================================================================
# start-influx.ps1
# Idempotente. Arranca SOLO InfluxDB 3 Core en background si no esta UP.
# Crea la database si hace falta.
#
# EXIT CODES: 0 ok, 1 fail influx, 3 fail database
# OUTPUT JSON al final.
# =============================================================================

param(
    [int]    $WaitSeconds = 60,
    [string] $InfluxBind  = "127.0.0.1:8181",
    [string] $Database    = "infinito_logs",
    [string] $Retention   = "90d"
)

$ErrorActionPreference = "Stop"
$RepoRoot   = Resolve-Path (Join-Path $PSScriptRoot "..")
$InfluxHome = Join-Path $RepoRoot "influxdb3-core-3.9.1-windows_amd64"
$InfluxBin  = Join-Path $InfluxHome "influxdb3.exe"
$ObjectDir  = Join-Path $InfluxHome "object-store"
$LogsDir    = Join-Path $RepoRoot "logs"
New-Item -ItemType Directory -Force -Path $LogsDir, $ObjectDir | Out-Null

function Test-HttpOk($url, $timeoutSec = 2) {
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $timeoutSec -ErrorAction Stop
        return $r.StatusCode -ge 200 -and $r.StatusCode -lt 300
    } catch { return $false }
}
function Wait-Until($name, $url, $maxSec) {
    Write-Host "==> Esperando $name en $url ..." -ForegroundColor Cyan
    $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $maxSec) {
        if (Test-HttpOk $url 2) { Write-Host "    OK" -ForegroundColor Green; return $true }
        Start-Sleep -Milliseconds 750
    }
    Write-Host "    !! no respondio en $maxSec s" -ForegroundColor Red
    return $false
}

$state = "running"
if ((Get-Process -Name "influxdb3" -ErrorAction SilentlyContinue) -and (Test-HttpOk "http://$InfluxBind/health" 2)) {
    Write-Host "==> InfluxDB ya esta arriba" -ForegroundColor Green
} else {
    Get-Process influxdb3 -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    if (-not (Test-Path $InfluxBin)) {
        Write-Output '{"status":"fail","reason":"missing_influxdb_binary"}'
        exit 1
    }
    Write-Host "==> Arrancando InfluxDB en background" -ForegroundColor Cyan
    $logFile = Join-Path $LogsDir "influxdb.log"
    Start-Process -FilePath $InfluxBin `
        -WorkingDirectory $InfluxHome `
        -ArgumentList @("serve","--node-id","node1","--object-store","file","--data-dir",$ObjectDir,"--http-bind",$InfluxBind,"--without-auth") `
        -WindowStyle Hidden `
        -RedirectStandardOutput $logFile `
        -RedirectStandardError  ($logFile + ".err")
    if (-not (Wait-Until "InfluxDB" "http://$InfluxBind/health" $WaitSeconds)) {
        Write-Output ('{"status":"fail","reason":"influxdb_no_health","log":"' + $logFile + '"}')
        exit 1
    }
    $state = "started"
}

# database (idempotente)
try {
    $body = @{ db = $Database; retention_period = $Retention } | ConvertTo-Json -Compress
    $r = Invoke-WebRequest -Uri "http://$InfluxBind/api/v3/configure/database" `
        -Method POST -Body $body -ContentType "application/json" `
        -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    Write-Host "    OK database '$Database' creada" -ForegroundColor Green
} catch {
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 409) {
        Write-Host "    OK database '$Database' ya existia" -ForegroundColor Green
    } else {
        Write-Output '{"status":"fail","reason":"database_create_failed"}'
        exit 3
    }
}

Write-Output ('{"status":"ok","influxdb":"' + $state + '","database":"' + $Database + '"}')
exit 0
