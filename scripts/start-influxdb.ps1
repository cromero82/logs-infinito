# =============================================================================
# start-influxdb.ps1
# Arranca InfluxDB 3 Core en modo desarrollo local SIN autenticacion.
# - Object store: filesystem (carpeta data/ dentro de la propia distribucion)
# - Puerto HTTP: 8181 (default)
# - Logs en consola (esta ventana)
# - El binario se queda en primer plano. Cierra la ventana o Ctrl+C para parar.
# Uso (PowerShell, parado en C:\dev\repos\logs-infinito):
#     .\scripts\start-influxdb.ps1
# =============================================================================

$ErrorActionPreference = "Stop"

# Resolver rutas relativas al script para que funcione desde cualquier cwd
$RepoRoot   = Resolve-Path (Join-Path $PSScriptRoot "..")
$InfluxHome = Join-Path $RepoRoot "influxdb3-core-3.9.1-windows_amd64"
$InfluxBin  = Join-Path $InfluxHome "influxdb3.exe"
$DataDir    = Join-Path $InfluxHome "data"
$ObjectDir  = Join-Path $InfluxHome "object-store"

if (-not (Test-Path $InfluxBin)) {
    Write-Host "ERROR: no se encontro $InfluxBin" -ForegroundColor Red
    Write-Host "       Verifica que la distribucion este descomprimida ahi."
    exit 1
}

# Crear carpetas de datos si no existen (ignoradas por git)
New-Item -ItemType Directory -Force -Path $DataDir   | Out-Null
New-Item -ItemType Directory -Force -Path $ObjectDir | Out-Null

Write-Host "==> Arrancando InfluxDB 3 Core" -ForegroundColor Cyan
Write-Host "    bin       : $InfluxBin"
Write-Host "    node-id   : infinito-node"
Write-Host "    http      : http://127.0.0.1:8181"
Write-Host "    data-dir  : $DataDir"
Write-Host "    auth      : DESACTIVADA (--without-auth)"
Write-Host ""
Write-Host "Para parar: Ctrl+C o cerrar esta ventana." -ForegroundColor Yellow
Write-Host ""

# Cambiarnos a la carpeta del binario para que rutas relativas internas
# (python embebido, etc.) funcionen.
Push-Location $InfluxHome
try {
    & $InfluxBin serve `
        --node-id "infinito-node" `
        --object-store "file" `
        --data-dir $ObjectDir `
        --http-bind "127.0.0.1:8181" `
        --without-auth
}
finally {
    Pop-Location
}
