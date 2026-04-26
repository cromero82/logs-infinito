# =============================================================================
# start-grafana.ps1
# Arranca Grafana en modo standalone con custom.ini.
# - Puerto: 3000 (configurado en grafana-13.0.1/conf/custom.ini)
# - Datos: grafana-13.0.1/data/  (SQLite, plugins, logs - ignorados por git)
# - El binario se queda en primer plano. Ctrl+C o cerrar ventana para parar.
# Uso (PowerShell, parado en C:\dev\repos\logs-infinito):
#     .\scripts\start-grafana.ps1
# =============================================================================

$ErrorActionPreference = "Stop"

$RepoRoot    = Resolve-Path (Join-Path $PSScriptRoot "..")
$GrafanaHome = Join-Path $RepoRoot "grafana-13.0.1"
$GrafanaBin  = Join-Path $GrafanaHome "bin\grafana.exe"
$CustomIni   = Join-Path $GrafanaHome "conf\custom.ini"
$DefaultsIni = Join-Path $GrafanaHome "conf\defaults.ini"
$DataDir     = Join-Path $GrafanaHome "data"

if (-not (Test-Path $GrafanaBin)) {
    Write-Host "ERROR: no se encontro $GrafanaBin" -ForegroundColor Red
    Write-Host "       Verifica que la distribucion este descomprimida ahi."
    exit 1
}
if (-not (Test-Path $DefaultsIni)) {
    Write-Host "ERROR: no se encontro $DefaultsIni" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $CustomIni)) {
    Write-Host "WARN: no existe custom.ini, Grafana usara solo defaults" -ForegroundColor Yellow
}

# Crear data dir si no existe
New-Item -ItemType Directory -Force -Path $DataDir         | Out-Null
New-Item -ItemType Directory -Force -Path "$DataDir\log"   | Out-Null
New-Item -ItemType Directory -Force -Path "$DataDir\plugins" | Out-Null

Write-Host "==> Arrancando Grafana" -ForegroundColor Cyan
Write-Host "    bin       : $GrafanaBin"
Write-Host "    homepath  : $GrafanaHome"
Write-Host "    config    : $CustomIni"
Write-Host "    http      : http://localhost:3000"
Write-Host "    login     : admin / admin   (Grafana pedira cambiarla al primer login)"
Write-Host ""
Write-Host "Para parar: Ctrl+C o cerrar esta ventana." -ForegroundColor Yellow
Write-Host ""

Push-Location $GrafanaHome
try {
    # Grafana 11+ usa subcomando 'server'.
    & $GrafanaBin server --homepath $GrafanaHome --config $CustomIni
}
finally {
    Pop-Location
}
