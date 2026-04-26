# Scripts de operacion - logs-infinito

Operaciones del stack de monitoreo (InfluxDB 3 Core + Grafana). Todos
**idempotentes**, **no interactivos**, con **exit code claro** y una linea
JSON al final del output. Pensados para uso manual y para invocacion
automatica desde la app lanzadora (`intinito-launcher`).

## Scripts principales (los que vas a usar)

| Script | Para que |
|---|---|
| `start-monitoreo.ps1`    | Si los servicios estan UP no hace nada. Si no, los arranca **en background**, espera health, asegura que la database `infinito_logs` existe (90d retencion). |
| `stop-monitoreo.ps1`     | Mata `grafana.exe` e `influxdb3.exe`. |
| `restart-monitoreo.ps1`  | stop + start. Usar tras cambiar provisioning o `custom.ini`. |
| `healthcheck.ps1`        | Valida puertos + endpoints + database + datasource provisionado + dashboard provisionado. Tabla legible + JSON resumen. |
| `smoke-test.ps1`         | Escribe + lee 1 linea de prueba en `backend_log` y `frontend_error`. Confirma end-to-end. |

## Scripts por-servicio (background, idempotentes)

Para gestionar **cada servicio por separado** (los usa la app lanzadora):

| Script | Para que |
|---|---|
| `start-influx.ps1`     | Solo InfluxDB. Crea database al primer arranque. |
| `stop-influx.ps1`      | Solo mata `influxdb3.exe`. |
| `restart-influx.ps1`   | stop + start de InfluxDB. |
| `start-grafana-bg.ps1` | Solo Grafana en background. |
| `stop-grafana.ps1`     | Solo mata `grafana.exe`. |
| `restart-grafana.ps1`  | stop + start de Grafana. Usar tras cambiar provisioning. |

## Scripts secundarios (foreground, para debugging manual)

| Script | Para que |
|---|---|
| `start-influxdb.ps1` | Arranca InfluxDB en **primer plano** (logs visibles). Util para depurar. |
| `start-grafana.ps1`  | Idem para Grafana. |
| `stop-services.ps1`  | Equivalente a `stop-monitoreo.ps1`, mantenido por compatibilidad. |

## Flujo first-run (manual o launcher)

```
.\scripts\start-monitoreo.ps1     <- arranca todo, crea DB, espera health
.\scripts\healthcheck.ps1         <- valida que todo esta OK end-to-end
.\scripts\smoke-test.ps1          <- (opcional) confirma escritura/lectura
start http://localhost:3000       <- abre Grafana
```

## Si cambias provisioning de Grafana (datasources/dashboards)

```
.\scripts\restart-monitoreo.ps1   <- recarga la config (Grafana solo lee provisioning al startup)
```

## Tabla de exit codes

| Script | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| start-monitoreo | OK | influx fail | grafana fail | database fail |
| stop-monitoreo  | OK | - | - | - |
| restart-monitoreo | OK | influx fail | grafana fail | database fail |
| healthcheck | OK | algun chequeo fallo | - | - |
| smoke-test  | OK | escritura fail | lectura/marker no encontrado | - |

## Output JSON

Cada script imprime una linea JSON al **final** de su output. Util para que
la app lanzadora parsee el resultado sin tener que interpretar el log
humano.

Ejemplos:
```json
{"status":"ok","influxdb":"started","grafana":"running","database":"infinito_logs"}
{"status":"ok","grafana_killed":1,"influxdb_killed":1}
{"status":"ok","failed":0,"warn":0,"total":7,"checks":[...]}
{"status":"ok","marker":"smoke-a1b2c3d4"}
```

## Ejecutar desde Java (app lanzadora)

Ver `docs/contrato-launcher.md` para el contrato completo, snippets de
ProcessBuilder y mapping a botones de UI.

## Habilitar PowerShell scripts (primera vez)

Si Windows bloquea la ejecucion:
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```
o ejecuta cada script con override:
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-monitoreo.ps1
```
