# =============================================================================
# restart-monitoreo.ps1
# stop + start. Util tras cambiar provisioning (datasources, dashboards) o
# custom.ini de Grafana.
#
# EXIT CODES: hereda los de start-monitoreo.ps1
# =============================================================================

param(
    [int]    $WaitSeconds = 60
)

$ErrorActionPreference = "Continue"

& "$PSScriptRoot\stop-monitoreo.ps1" | Out-Null
Start-Sleep -Seconds 1
& "$PSScriptRoot\start-monitoreo.ps1" -WaitSeconds $WaitSeconds
exit $LASTEXITCODE
