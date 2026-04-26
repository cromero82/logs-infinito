# =============================================================================
# stop-grafana.ps1 - mata SOLO grafana.exe. Idempotente.
# EXIT CODE: 0
# =============================================================================
$ErrorActionPreference = "SilentlyContinue"
$procs = Get-Process -Name "grafana" -ErrorAction SilentlyContinue
if ($procs) {
    Write-Host "==> Matando $($procs.Count) proceso(s) grafana.exe" -ForegroundColor Yellow
    $procs | Stop-Process -Force
    Start-Sleep -Milliseconds 400
    Write-Output ('{"status":"ok","grafana_killed":' + $procs.Count + '}')
} else {
    Write-Host "==> grafana.exe no estaba corriendo" -ForegroundColor Gray
    Write-Output '{"status":"ok","grafana_killed":0}'
}
exit 0
