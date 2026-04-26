# =============================================================================
# stop-services.ps1
# Mata cualquier proceso vivo de influxdb3.exe y grafana.exe.
# Util cuando se cerro mal una ventana o cuando se quiere reiniciar limpio.
# =============================================================================

$ErrorActionPreference = "SilentlyContinue"

function Stop-ByName($name) {
    $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Host "==> Matando $($procs.Count) proceso(s) de $name.exe" -ForegroundColor Yellow
        $procs | Stop-Process -Force
        Start-Sleep -Milliseconds 500
        Write-Host "    OK" -ForegroundColor Green
    } else {
        Write-Host "==> No hay procesos de $name.exe corriendo" -ForegroundColor Gray
    }
}

Stop-ByName "influxdb3"
Stop-ByName "grafana"

Write-Host ""
Write-Host "Listo." -ForegroundColor Cyan
