# =============================================================================
# smoke-test.ps1
# Prueba end-to-end: escribe 1 line de prueba en cada measurement (backend_log
# y frontend_error), las consulta y verifica que aparecieron.
#
# InfluxDB 3 hace flush WAL -> parquet asincronamente; por eso reintentamos
# la lectura varias veces con backoff antes de declarar fallo.
#
# EXIT CODES:
#   0  todo OK (escritura + lectura)
#   1  fallo de escritura
#   2  fallo de lectura / dato no encontrado tras reintentos
# =============================================================================

param(
    [string] $InfluxUrl    = "http://127.0.0.1:8181",
    [string] $Database     = "infinito_logs",
    [int]    $MaxRetries   = 12,    # 12 x 1s = hasta 12s esperando el flush
    [int]    $SleepMs      = 1000
)

$ErrorActionPreference = "Stop"
$marker = "smoke-" + ([guid]::NewGuid().ToString("N").Substring(0,8))
$nowNs  = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) * 1000000

Write-Host "==> Smoke test (marker=$marker)" -ForegroundColor Cyan

# ---------- Escritura ------------------------------------------------------

$body = @"
backend_log,app=smoke-test,level=INFO,logger=Smoke,thread=ps message="hola desde smoke-test $marker" $nowNs
frontend_error,app=smoke-test,url=/smoke,error_type=SmokeError error="error sintetico $marker",actividad="ninguna",reporte_id="$marker" $nowNs
"@

try {
    $r = Invoke-WebRequest `
        -Uri "$InfluxUrl/api/v3/write_lp?db=$Database&precision=ns" `
        -Method POST -Body $body -ContentType "text/plain" `
        -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
    if ($r.StatusCode -lt 200 -or $r.StatusCode -ge 300) {
        Write-Host "  !! escritura HTTP $($r.StatusCode)" -ForegroundColor Red
        Write-Output ('{"status":"fail","stage":"write","http":' + $r.StatusCode + '}')
        exit 1
    }
    Write-Host "  OK escritura (HTTP $($r.StatusCode))" -ForegroundColor Green
} catch {
    $msg = $_.Exception.Message
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $_.ErrorDetails.Message }
    Write-Host "  !! escritura fallo: $msg" -ForegroundColor Red
    Write-Output ('{"status":"fail","stage":"write","error":"' + ($msg -replace '"','\"') + '"}')
    exit 1
}

# ---------- Lectura --------------------------------------------------------

function Query($sql) {
    $url = "$InfluxUrl/api/v3/query_sql?db=$Database&q=" + [Uri]::EscapeDataString($sql) + "&format=jsonl"
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        # Influx devuelve Content-Type=application/jsonl que PowerShell trata como
        # byte[]; forzamos conversion a string UTF-8 para poder hacer -match/.Trim.
        $bodyStr = ""
        if ($r.Content -is [byte[]]) {
            $bodyStr = [System.Text.Encoding]::UTF8.GetString($r.Content)
        } elseif ($r.Content) {
            $bodyStr = [string]$r.Content
        }
        return @{ ok = $true; body = $bodyStr; status = $r.StatusCode }
    } catch {
        $msg = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $_.ErrorDetails.Message }
        return @{ ok = $false; body = $msg; status = -1 }
    }
}

function Wait-Marker($measurement, $whereClause) {
    Write-Host "  esperando marker en $measurement ..." -NoNewline
    for ($i = 1; $i -le $MaxRetries; $i++) {
        $sql = "SELECT * FROM $measurement WHERE $whereClause ORDER BY time DESC LIMIT 1"
        $res = Query $sql
        if ($res.ok -and $res.body -and ($res.body -match [Regex]::Escape($marker))) {
            Write-Host " encontrado en intento $i" -ForegroundColor Green
            return @{ ok = $true; body = $res.body; tries = $i }
        }
        Write-Host "." -NoNewline
        Start-Sleep -Milliseconds $SleepMs
    }
    Write-Host " no encontrado tras $MaxRetries intentos" -ForegroundColor Red
    return @{ ok = $false; body = $res.body; tries = $MaxRetries }
}

$ok = $true
$debug = @{}

$r1 = Wait-Marker "backend_log"    "message LIKE '%$marker%'"
if (-not $r1.ok) {
    $ok = $false
    $debug.backend_log = $r1.body
    # Diagnostico extra: hay algo en backend_log?
    $countRes = Query "SELECT COUNT(*) AS c FROM backend_log WHERE time >= NOW() - INTERVAL '1 minute'"
    Write-Host "    debug backend_log count last 1min: $($countRes.body.Trim())" -ForegroundColor Yellow
}

$r2 = Wait-Marker "frontend_error" "reporte_id = '$marker'"
if (-not $r2.ok) {
    $ok = $false
    $debug.frontend_error = $r2.body
    $countRes = Query "SELECT COUNT(*) AS c FROM frontend_error WHERE time >= NOW() - INTERVAL '1 minute'"
    Write-Host "    debug frontend_error count last 1min: $($countRes.body.Trim())" -ForegroundColor Yellow
}

if ($ok) {
    Write-Host "==> SMOKE TEST OK" -ForegroundColor Green
    Write-Output ('{"status":"ok","marker":"' + $marker + '","tries_backend":' + $r1.tries + ',"tries_frontend":' + $r2.tries + '}')
    exit 0
} else {
    Write-Host "==> SMOKE TEST FAIL" -ForegroundColor Red
    $debugJson = ($debug | ConvertTo-Json -Compress -Depth 4) -replace '"', '\"'
    Write-Output ('{"status":"fail","stage":"read","marker":"' + $marker + '","debug":"' + $debugJson + '"}')
    exit 2
}
