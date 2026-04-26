# =============================================================================
# restart-grafana.ps1 - stop + start de Grafana
# Util tras cambiar provisioning o custom.ini.
# =============================================================================
param([int] $WaitSeconds = 60)
$ErrorActionPreference = "Continue"
& "$PSScriptRoot\stop-grafana.ps1" | Out-Null
Start-Sleep -Milliseconds 800
& "$PSScriptRoot\start-grafana-bg.ps1" -WaitSeconds $WaitSeconds
exit $LASTEXITCODE
