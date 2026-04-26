# =============================================================================
# stop-monitoreo.ps1
# Mata grafana.exe e influxdb3.exe. Idempotente (no falla si no hay nada).
#
# EXIT CODES:
#   0  ok
# =============================================================================

$ErrorActionPreference = "SilentlyContinue"

function Stop-ByName($name) {
    $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Host "==> Matando $($procs.Count) proceso(s) de $name.exe" -ForegroundColor Yellow
        $procs | Stop-Process -Force
        Start-Sleep -Milliseconds 500
        Write-Host "    OK" -ForegroundColor Green
        return $procs.Count
    } else {
        Write-Host "==> $name.exe no estaba corriendo" -ForegroundColor Gray
        return 0
    }
}

$g = Stop-ByName "grafana"
$i = Stop-ByName "influxdb3"

Write-Output ('{"status":"ok","grafana_killed":' + $g + ',"influxdb_killed":' + $i + '}')
exit 0
