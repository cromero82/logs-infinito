# =============================================================================
# healthcheck.ps1
# Verifica que TODO el stack de monitoreo este saludable:
#   1. Puertos: 8181 (Influx) y 3000 (Grafana)
#   2. Endpoints HTTP: /health en ambos
#   3. Database 'infinito_logs' existe en InfluxDB
#   4. Datasource 'infinito-influx' provisionado en Grafana
#   5. Dashboard 'infinito-monitoreo' visible en Grafana
#
# Salida: tabla legible + linea JSON al final + exit code (0 ok / 1 algo fallo).
# Pensado para uso manual y para polling desde la app lanzadora.
# =============================================================================

param(
    [string] $InfluxUrl   = "http://127.0.0.1:8181",
    [string] $GrafanaUrl  = "http://127.0.0.1:3000",
    [string] $Database    = "infinito_logs",
    [string] $DataSourceUid = "infinito-influx",
    [string] $DashboardUid  = "infinito-monitoreo",
    [string] $GrafanaUser = "admin",
    [string] $GrafanaPass = "admin"
)

$ErrorActionPreference = "SilentlyContinue"
$results = @()

# ---------- helpers ---------------------------------------------------------

function Add-Result($name, $url, $status, $detail) {
    $script:results += [pscustomobject]@{
        Servicio = $name
        Detalle  = $detail
        Estado   = $status
        URL      = $url
    }
}

function Test-Port($name, $hostname, $port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($hostname, $port, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne(2500, $false)
        if ($ok -and $client.Connected) {
            $client.EndConnect($async); $client.Close()
            Add-Result $name "${hostname}:${port}" "OK" "puerto en escucha"
            return $true
        }
        Add-Result $name "${hostname}:${port}" "DOWN" "timeout / no conecta"
        return $false
    } catch {
        Add-Result $name "${hostname}:${port}" "DOWN" $_.Exception.Message
        return $false
    } finally { $client.Close() }
}

function Get-Json($url, $headers = $null, $bodyPreview = 80) {
    try {
        $args = @{ Uri = $url; UseBasicParsing = $true; TimeoutSec = 5 }
        if ($headers) { $args.Headers = $headers }
        return Invoke-WebRequest @args -ErrorAction Stop
    } catch { return $null }
}

# ---------- 1. Puertos -----------------------------------------------------

$influxUri = [Uri]$InfluxUrl
$grafUri   = [Uri]$GrafanaUrl
Test-Port "InfluxDB (puerto)" $influxUri.Host $influxUri.Port | Out-Null
Test-Port "Grafana  (puerto)" $grafUri.Host   $grafUri.Port   | Out-Null

# ---------- 2. Endpoints health --------------------------------------------

$resp = Get-Json "$InfluxUrl/health"
if ($resp -and $resp.StatusCode -eq 200) {
    Add-Result "InfluxDB /health" "$InfluxUrl/health" "OK" $resp.Content
} else {
    Add-Result "InfluxDB /health" "$InfluxUrl/health" "DOWN" "no responde"
}

$resp = Get-Json "$GrafanaUrl/api/health"
if ($resp -and $resp.StatusCode -eq 200) {
    Add-Result "Grafana /api/health" "$GrafanaUrl/api/health" "OK" $resp.Content.Substring(0,[Math]::Min(80,$resp.Content.Length))
} else {
    Add-Result "Grafana /api/health" "$GrafanaUrl/api/health" "DOWN" "no responde"
}

# ---------- 3. Database existe ---------------------------------------------

# InfluxDB 3 expone GET /api/v3/configure/database (lista) y SHOW TABLES via SQL.
$dbCheck = "DOWN"; $dbDetail = ""
try {
    $url = "$InfluxUrl/api/v3/query_sql?db=$Database&q=" + [Uri]::EscapeDataString("SHOW TABLES") + "&format=jsonl"
    $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    if ($r.StatusCode -eq 200) {
        $dbCheck = "OK"
        # Influx devuelve bytes con jsonl; convertimos a string UTF-8.
        $bodyStr = if ($r.Content -is [byte[]]) {
            [System.Text.Encoding]::UTF8.GetString($r.Content)
        } else { [string]$r.Content }
        $count = ($bodyStr -split "`n" | Where-Object { $_.Trim() -ne "" }).Count
        $dbDetail = "$count measurement(s)"
    } else { $dbDetail = "HTTP $($r.StatusCode)" }
} catch { $dbDetail = $_.Exception.Message }
Add-Result "InfluxDB db '$Database'" "$InfluxUrl/api/v3/query_sql?db=$Database" $dbCheck $dbDetail

# ---------- 4. Datasource Grafana provisionado -----------------------------

$pair  = "${GrafanaUser}:${GrafanaPass}"
$bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
$auth  = [Convert]::ToBase64String($bytes)
$hdr   = @{ Authorization = "Basic $auth" }

$dsCheck = "DOWN"; $dsDetail = ""
try {
    $r = Invoke-WebRequest -Uri "$GrafanaUrl/api/datasources/uid/$DataSourceUid" -Headers $hdr -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    if ($r.StatusCode -eq 200) {
        $obj = $r.Content | ConvertFrom-Json
        $dsCheck = "OK"
        $dsDetail = "type=$($obj.type) name=$($obj.name)"
    } else { $dsDetail = "HTTP $($r.StatusCode)" }
} catch {
    if ($_.Exception.Response.StatusCode.value__ -eq 404) {
        $dsDetail = "NO PROVISIONADO (revisar conf/provisioning/datasources/)"
    } else { $dsDetail = $_.Exception.Message }
}
Add-Result "Grafana datasource '$DataSourceUid'" "$GrafanaUrl/api/datasources/uid/$DataSourceUid" $dsCheck $dsDetail

# Probar el datasource (Test connection)
if ($dsCheck -eq "OK") {
    try {
        $r = Invoke-WebRequest -Uri "$GrafanaUrl/api/datasources/uid/$DataSourceUid/health" -Headers $hdr -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        if ($r.StatusCode -eq 200) {
            $obj = $r.Content | ConvertFrom-Json
            $estado = if ($obj.status -eq "OK" -or $obj.status -eq "ok") { "OK" } else { "WARN" }
            Add-Result "Grafana datasource health" "/api/datasources/uid/$DataSourceUid/health" $estado "$($obj.status): $($obj.message)"
        }
    } catch {
        $msg = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $_.ErrorDetails.Message }
        Add-Result "Grafana datasource health" "/api/datasources/uid/$DataSourceUid/health" "WARN" $msg
    }
}

# ---------- 5. Dashboard provisionado --------------------------------------

$dbCheck = "DOWN"; $dbDetail = ""
try {
    $r = Invoke-WebRequest -Uri "$GrafanaUrl/api/dashboards/uid/$DashboardUid" -Headers $hdr -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    if ($r.StatusCode -eq 200) {
        $obj = $r.Content | ConvertFrom-Json
        $dbCheck = "OK"
        $dbDetail = "title='$($obj.dashboard.title)' panels=$($obj.dashboard.panels.Count)"
    }
} catch {
    if ($_.Exception.Response.StatusCode.value__ -eq 404) {
        $dbDetail = "NO PROVISIONADO (revisar conf/provisioning/dashboards/)"
    } else { $dbDetail = $_.Exception.Message }
}
Add-Result "Grafana dashboard '$DashboardUid'" "$GrafanaUrl/api/dashboards/uid/$DashboardUid" $dbCheck $dbDetail

# ---------- Render ---------------------------------------------------------

Write-Host ""
Write-Host "==> Healthcheck logs-infinito" -ForegroundColor Cyan
$results | Format-Table Servicio, Estado, Detalle -AutoSize -Wrap

# Resumen JSON
$failed = @($results | Where-Object { $_.Estado -in @("DOWN","FAIL") })
$warn   = @($results | Where-Object { $_.Estado -eq "WARN" })
$jsonResults = $results | ForEach-Object {
    @{ servicio = $_.Servicio; estado = $_.Estado; detalle = $_.Detalle }
}
$summary = @{
    status   = if ($failed.Count -gt 0) { "fail" } elseif ($warn.Count -gt 0) { "warn" } else { "ok" }
    failed   = $failed.Count
    warn     = $warn.Count
    total    = $results.Count
    checks   = $jsonResults
} | ConvertTo-Json -Compress -Depth 4
Write-Output $summary

if ($failed.Count -gt 0) {
    Write-Host "RESULTADO: $($failed.Count) chequeo(s) fallaron." -ForegroundColor Red
    exit 1
}
Write-Host "RESULTADO: todo OK." -ForegroundColor Green
exit 0
