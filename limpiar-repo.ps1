# =============================================================================
# limpiar-repo.ps1
# Quita del índice de git los archivos que YA estaban versionados pero que el
# nuevo .gitignore quiere ignorar. NO borra archivos del disco (--cached).
# Ejecutar UNA SOLA VEZ desde la raíz del repo logs-infinito.
#
# Uso (PowerShell, parado en C:\dev\repos\logs-infinito):
#     .\limpiar-repo.ps1
# =============================================================================

Write-Host "==> Repositorio: $(Get-Location)" -ForegroundColor Cyan
Write-Host "==> Rama actual:" -ForegroundColor Cyan
git branch --show-current

Write-Host ""
Write-Host "==> Archivos rastreados ANTES:" -ForegroundColor Yellow
$before = (git ls-files | Measure-Object -Line).Lines
Write-Host "    $before archivos"

Write-Host ""
Write-Host "==> Quitando del indice (no del disco) los binarios y datos runtime..." -ForegroundColor Green

# Grafana: quitar todo excepto conf/, README, LICENSE, NOTICE, VERSION, Dockerfile
git rm -r --cached --quiet "grafana-13.0.1/bin/"            2>$null
git rm -r --cached --quiet "grafana-13.0.1/public/"         2>$null
git rm -r --cached --quiet "grafana-13.0.1/docs/"           2>$null
git rm -r --cached --quiet "grafana-13.0.1/packaging/"      2>$null
git rm -r --cached --quiet "grafana-13.0.1/plugins-bundled/" 2>$null
git rm -r --cached --quiet "grafana-13.0.1/tools/"          2>$null
git rm -r --cached --quiet "grafana-13.0.1/data/"           2>$null

# InfluxDB: quitar python embebido, binarios y datos runtime
git rm -r --cached --quiet "influxdb3-core-3.9.1-windows_amd64/python/"        2>$null
git rm    --cached --quiet "influxdb3-core-3.9.1-windows_amd64/influxdb3.exe"  2>$null
git rm    --cached --quiet "influxdb3-core-3.9.1-windows_amd64/python3.dll"    2>$null
git rm    --cached --quiet "influxdb3-core-3.9.1-windows_amd64/python313.dll"  2>$null
git rm    --cached --quiet "influxdb3-core-3.9.1-windows_amd64/vcruntime140.dll"   2>$null
git rm    --cached --quiet "influxdb3-core-3.9.1-windows_amd64/vcruntime140_1.dll" 2>$null

# Carpetas runtime que aparecerán cuando se ejecute InfluxDB (preventivo)
git rm -r --cached --quiet "influxdb3-core-3.9.1-windows_amd64/data/"         2>$null
git rm -r --cached --quiet "influxdb3-core-3.9.1-windows_amd64/object-store/" 2>$null
git rm -r --cached --quiet "influxdb3-core-3.9.1-windows_amd64/wal/"          2>$null
git rm -r --cached --quiet "influxdb3-core-3.9.1-windows_amd64/cache/"        2>$null
git rm -r --cached --quiet "influxdb3-core-3.9.1-windows_amd64/plugins/"      2>$null

Write-Host ""
Write-Host "==> Archivos rastreados DESPUES:" -ForegroundColor Yellow
$after = (git ls-files | Measure-Object -Line).Lines
Write-Host "    $after archivos (se removieron $($before - $after))"

Write-Host ""
Write-Host "==> Lo que se mantiene versionado (top niveles):" -ForegroundColor Green
git ls-files | ForEach-Object { ($_ -split '/')[0..1] -join '/' } | Sort-Object -Unique

Write-Host ""
Write-Host "==> Revisa con 'git status' y luego haz commit:" -ForegroundColor Cyan
Write-Host "    git status"
Write-Host "    git add .gitignore"
Write-Host "    git commit -m `"chore: gitignore para Grafana+InfluxDB, limpiar binarios y runtime`""
Write-Host "    git push"
