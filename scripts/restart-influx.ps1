# =============================================================================
# restart-influx.ps1 - stop + start de InfluxDB
# =============================================================================
param([int] $WaitSeconds = 60)
$ErrorActionPreference = "Continue"
& "$PSScriptRoot\stop-influx.ps1" | Out-Null
Start-Sleep -Milliseconds 800
& "$PSScriptRoot\start-influx.ps1" -WaitSeconds $WaitSeconds
exit $LASTEXITCODE
