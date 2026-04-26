# =============================================================================
# start-monitoreo.ps1
# Idempotente. Si InfluxDB y Grafana ya estan UP no hace nada. Si no, los
# arranca en BACKGROUND (procesos detached) y espera que respondan health.
#
# Pensado para ser invocado tanto a mano (un-click) como desde la app lanzadora
# Java via ProcessBuilder.
#
# EXIT CODES:
#   0  todo arriba (ya estaba o se arranco OK)
#   1  fallo arrancando InfluxDB
#   2  fallo arrancando Grafana
#   3  fallo creando database infinito_logs
#
# OUTPUT: una linea JSON al final con el resumen (parseable desde Java).
# =============================================================================

param(
    [int]    $WaitSeconds = 60,
    [string] $InfluxBind  = "127.0.0.1:8181",
    [string] $GrafanaUrl  = "http://127.0.0.1:3000",
    [string] $Database    = "infinito_logs",
    [string] $Retention   = "90d"
)

$ErrorActionPreference = "Stop"

$RepoRoot   = Resolve-Path (Join-Path $PSScriptRoot "..")
$InfluxHome = Join-Path $RepoRoot "influxdb3-core-3.9.1-windows_amd64"
$InfluxBin  = Join-Path $InfluxHome "influxdb3.exe"
$ObjectDir  = Join-Path $InfluxHome "object-store"
$GrafanaHome= Join-Path $RepoRoot "grafana-13.0.1"
$GrafanaBin = Join-Path $GrafanaHome "bin\grafana.exe"
$CustomIni  = Join-Path $GrafanaHome "conf\custom.ini"
$LogsDir    = Join-Path $RepoRoot "logs"
New-Item -ItemType Directory -Force -Path $LogsDir, $ObjectDir | Out-Null

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok  ($msg) { Write-Host "    OK: $msg" -ForegroundColor Green }
function Write-Bad ($msg) { Write-Host "    !!: $msg" -ForegroundColor Red   }

function Test-HttpOk($url, $timeoutSec = 2) {
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $timeoutSec -ErrorAction Stop
        return $r.StatusCode -ge 200 -and $r.StatusCode -lt 300
    } catch { return $false }
}

function Wait-Until($name, $url, $maxSeconds) {
    Write-Step "Esperando $name en $url ..."
    $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $maxSeconds) {
        if (Test-HttpOk $url 2) { Write-Ok "$name UP"; return $true }
        Start-Sleep -Milliseconds 750
    }
    Write-Bad "$name no respondio en $maxSeconds segundos"
    return $false
}

function Is-ProcessRunning($name) {
    return (Get-Process -Name $name -ErrorAction SilentlyContinue) -ne $null
}

# --- 1. InfluxDB ------------------------------------------------------------
$influxState = "running"
if (Is-ProcessRunning "influxdb3" -and (Test-HttpOk "http://$InfluxBind/health" 2)) {
    Write-Ok "InfluxDB ya estaba arriba"
} else {
    if (Is-ProcessRunning "influxdb3") {
        Write-Step "InfluxDB en proceso pero sin responder; lo mato y rearranco"
        Get-Process influxdb3 -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 1
    }
    if (-not (Test-Path $InfluxBin)) {
        Write-Bad "no existe $InfluxBin"
        Write-Output '{"status":"fail","reason":"missing_influxdb_binary"}'
        exit 1
    }
    Write-Step "Arrancando InfluxDB en background"
    $influxLog = Join-Path $LogsDir "influxdb.log"
    Start-Process -FilePath $InfluxBin `
        -WorkingDirectory $InfluxHome `
        -ArgumentList @(
            "serve",
            "--node-id","node1",
            "--object-store","file",
            "--data-dir",$ObjectDir,
            "--http-bind",$InfluxBind,
            "--without-auth"
        ) `
        -WindowStyle Hidden `
        -RedirectStandardOutput $influxLog `
        -RedirectStandardError  ($influxLog + ".err")
    if (-not (Wait-Until "InfluxDB" "http://$InfluxBind/health" $WaitSeconds)) {
        Write-Output ('{"status":"fail","reason":"influxdb_no_health","log":"' + $influxLog + '"}')
        exit 1
    }
    $influxState = "started"
}

# --- 2. database infinito_logs (idempotente) --------------------------------
Write-Step "Asegurando database '$Database' (retencion $Retention)"
try {
    $body = @{ db = $Database; retention_period = $Retention } | ConvertTo-Json -Compress
    $r = Invoke-WebRequest `
        -Uri "http://$InfluxBind/api/v3/configure/database" `
        -Method POST -Body $body -ContentType "application/json" `
        -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    Write-Ok "database '$Database' creada (HTTP $($r.StatusCode))"
} catch {
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 409) {
        Write-Ok "database '$Database' ya existia"
    } else {
        Write-Bad "no se pudo crear/verificar database: $($_.Exception.Message)"
        Write-Output '{"status":"fail","reason":"database_create_failed"}'
        exit 3
    }
}

# --- 3. Grafana -------------------------------------------------------------
$grafanaState = "running"
if (Is-ProcessRunning "grafana" -and (Test-HttpOk "$GrafanaUrl/api/health" 2)) {
    Write-Ok "Grafana ya estaba arriba"
} else {
    if (Is-ProcessRunning "grafana") {
        Write-Step "Grafana en proceso pero sin responder; lo mato y rearranco"
        Get-Process grafana -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 1
    }
    if (-not (Test-Path $GrafanaBin)) {
        Write-Bad "no existe $GrafanaBin"
        Write-Output '{"status":"fail","reason":"missing_grafana_binary"}'
        exit 2
    }
    Write-Step "Arrancando Grafana en background"
    $grafanaLog = Join-Path $LogsDir "grafana.log"
    Start-Process -FilePath $GrafanaBin `
        -WorkingDirectory $GrafanaHome `
        -ArgumentList @("server","--homepath",$GrafanaHome,"--config",$CustomIni) `
        -WindowStyle Hidden `
        -RedirectStandardOutput $grafanaLog `
        -RedirectStandardError  ($grafanaLog + ".err")
    if (-not (Wait-Until "Grafana" "$GrafanaUrl/api/health" $WaitSeconds)) {
        Write-Output ('{"status":"fail","reason":"grafana_no_health","log":"' + $grafanaLog + '"}')
        exit 2
    }
    $grafanaState = "started"
}

# --- Resumen final ----------------------------------------------------------
Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Monitoreo OK" -ForegroundColor Green
Write-Host "  InfluxDB : http://$InfluxBind  ($influxState)"
Write-Host "  Grafana  : $GrafanaUrl  ($grafanaState)"
Write-Host "  Logs     : $LogsDir"
Write-Host "==================================================" -ForegroundColor Cyan
Write-Output ('{"status":"ok","influxdb":"' + $influxState + '","grafana":"' + $grafanaState + '","database":"' + $Database + '"}')
exit 0
