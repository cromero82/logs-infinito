# =============================================================================
# stop-influx.ps1 - mata SOLO influxdb3.exe. Idempotente.
# EXIT CODE: 0
# =============================================================================
$ErrorActionPreference = "SilentlyContinue"
$procs = Get-Process -Name "influxdb3" -ErrorAction SilentlyContinue
if ($procs) {
    Write-Host "==> Matando $($procs.Count) proceso(s) influxdb3.exe" -ForegroundColor Yellow
    $procs | Stop-Process -Force
    Start-Sleep -Milliseconds 400
    Write-Output ('{"status":"ok","influxdb_killed":' + $procs.Count + '}')
} else {
    Write-Host "==> influxdb3.exe no estaba corriendo" -ForegroundColor Gray
    Write-Output '{"status":"ok","influxdb_killed":0}'
}
exit 0
