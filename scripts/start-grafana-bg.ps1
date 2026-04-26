# =============================================================================
# start-grafana-bg.ps1
# Idempotente. Arranca SOLO Grafana en background si no esta UP.
# (Sufijo -bg para distinguirlo de start-grafana.ps1 foreground/debug.)
#
# EXIT CODES: 0 ok, 2 fail grafana
# OUTPUT JSON al final.
# =============================================================================

param(
    [int]    $WaitSeconds = 60,
    [string] $GrafanaUrl  = "http://127.0.0.1:3000"
)

$ErrorActionPreference = "Stop"
$RepoRoot    = Resolve-Path (Join-Path $PSScriptRoot "..")
$GrafanaHome = Join-Path $RepoRoot "grafana-13.0.1"
$GrafanaBin  = Join-Path $GrafanaHome "bin\grafana.exe"
$CustomIni   = Join-Path $GrafanaHome "conf\custom.ini"
$LogsDir     = Join-Path $RepoRoot "logs"
New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null

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
if ((Get-Process -Name "grafana" -ErrorAction SilentlyContinue) -and (Test-HttpOk "$GrafanaUrl/api/health" 2)) {
    Write-Host "==> Grafana ya esta arriba" -ForegroundColor Green
} else {
    Get-Process grafana -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    if (-not (Test-Path $GrafanaBin)) {
        Write-Output '{"status":"fail","reason":"missing_grafana_binary"}'
        exit 2
    }
    Write-Host "==> Arrancando Grafana en background" -ForegroundColor Cyan
    $logFile = Join-Path $LogsDir "grafana.log"
    Start-Process -FilePath $GrafanaBin `
        -WorkingDirectory $GrafanaHome `
        -ArgumentList @("server","--homepath",$GrafanaHome,"--config",$CustomIni) `
        -WindowStyle Hidden `
        -RedirectStandardOutput $logFile `
        -RedirectStandardError  ($logFile + ".err")
    if (-not (Wait-Until "Grafana" "$GrafanaUrl/api/health" $WaitSeconds)) {
        Write-Output ('{"status":"fail","reason":"grafana_no_health","log":"' + $logFile + '"}')
        exit 2
    }
    $state = "started"
}

Write-Output ('{"status":"ok","grafana":"' + $state + '"}')
exit 0
