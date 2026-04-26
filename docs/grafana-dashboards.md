# Dashboards de Grafana - logs-infinito

## Que se provisiona

| Recurso | Path |
|---|---|
| Datasource InfluxDB-Infinito (uid: `infinito-influx`) | `grafana-13.0.1/conf/provisioning/datasources/infinito-influx.yaml` |
| Provider de dashboards | `grafana-13.0.1/conf/provisioning/dashboards/infinito-provider.yaml` |
| Dashboard "Infinito - Monitoreo" (uid: `infinito-monitoreo`) | `grafana-13.0.1/conf/provisioning/dashboards/json/infinito-monitoreo.json` |

Todos quedan dentro de `conf/` -> se versionan en git.

## Como recargar Grafana para que tome los cambios

Grafana solo escanea provisioning al startup. Tras cambiar cualquiera de los
archivos anteriores hay que reiniciar:

```cmd
REM Mata grafana y vuelvelo a lanzar (los servicios siguen vivos: solo Grafana)
taskkill /F /IM grafana.exe

cd C:\dev\repos\logs-infinito\grafana-13.0.1
.\bin\grafana.exe server --homepath . --config conf\custom.ini
```

Espera ~10 segundos y abre <http://localhost:3000>:

1. Login: `admin` / `admin` (la primera vez te pide cambiarla).
2. Menu izquierdo -> Dashboards -> carpeta **Infinito** -> dashboard
   **Infinito - Monitoreo (Backend + Frontend)**.
3. Si no aparece, revisa **Connections -> Data sources** y verifica que
   **InfluxDB-Infinito** este verde en "Test".

## Que ves en el dashboard

| Panel | Equivalente "viejo" en postgres |
|---|---|
| Backend - eventos por nivel (rate / min) | (no existia) |
| Frontend - errores ultima hora | `SELECT count(*) FROM reporte_frontend WHERE fecha_registro > now() - interval '1 hour'` |
| Backend - errores ultima hora | `SELECT count(*) FROM app_log WHERE nivel='ERROR' AND fecha > now() - interval '1 hour'` |
| Frontend errors - ultimos 50 | `SELECT * FROM reporte_frontend ORDER BY fecha_registro DESC LIMIT 50` |
| Backend logs - ultimos 100 | `SELECT * FROM app_log ORDER BY fecha DESC LIMIT 100` |

## Consultas SQL ad-hoc (sin Grafana)

InfluxDB 3 acepta SQL via HTTP. Ejemplos en CMD:

### Ver los ultimos 5 errores frontend (lo que pediste como simil de reporte_frontend)
```cmd
curl -G "http://127.0.0.1:8181/api/v3/query_sql" ^
  --data-urlencode "db=infinito_logs" ^
  --data-urlencode "q=SELECT time, url, error_type, error, actividad, reporte_id FROM frontend_error ORDER BY time DESC LIMIT 5" ^
  --data-urlencode "format=jsonl"
```

### Solo los errores ERROR del backend en las ultimas 24h
```cmd
curl -G "http://127.0.0.1:8181/api/v3/query_sql" ^
  --data-urlencode "db=infinito_logs" ^
  --data-urlencode "q=SELECT time, logger, message FROM backend_log WHERE level = 'ERROR' AND time >= NOW() - INTERVAL '24 hours' ORDER BY time DESC" ^
  --data-urlencode "format=jsonl"
```

### Conteo de errores frontend por url
```cmd
curl -G "http://127.0.0.1:8181/api/v3/query_sql" ^
  --data-urlencode "db=infinito_logs" ^
  --data-urlencode "q=SELECT url, COUNT(*) AS errores FROM frontend_error WHERE time >= NOW() - INTERVAL '7 days' GROUP BY url ORDER BY errores DESC" ^
  --data-urlencode "format=jsonl"
```

### Listar measurements (tablas) que existen
```cmd
curl -G "http://127.0.0.1:8181/api/v3/query_sql" ^
  --data-urlencode "db=infinito_logs" ^
  --data-urlencode "q=SHOW TABLES" ^
  --data-urlencode "format=jsonl"
```

## Si el datasource no conecta

Sintomas: en el dashboard ves "No data" o errores del estilo
`unable to connect`.

Causas mas comunes:

1. **InfluxDB no esta corriendo** -> `curl http://127.0.0.1:8181/health`
   debe responder `OK`.
2. **Database `infinito_logs` no existe** -> el ms negocio la crea al
   arrancar. Si lo arrancaste antes de que Influx estuviera arriba, prueba
   reiniciandolo, o creala a mano:
   ```cmd
   curl -X POST "http://127.0.0.1:8181/api/v3/configure/database" ^
     -H "Content-Type: application/json" ^
     -d "{\"db\":\"infinito_logs\",\"retention_period\":\"90d\"}"
   ```
3. **Modo SQL del datasource requiere FlightSQL** -> InfluxDB 3 Core lo expone
   en el mismo puerto 8181. Si Grafana se queja, ir a la UI:
   `Connections -> Data sources -> InfluxDB-Infinito -> Test`. Si falla,
   cambiar `version: SQL` por `version: Flux` no servira (Flux es de v2).
   En ultimo caso, instalar el plugin **Infinity** y consultar via HTTP API.

## Modificar el dashboard desde la UI

El YAML del provider tiene `allowUiUpdates: true`. Puedes editar el dashboard
desde la UI de Grafana, pero **al reiniciar se sobrescribe** con el JSON del
disco. Para hacer cambios permanentes:

1. Modifica el dashboard en la UI a tu gusto.
2. Settings (engranaje arriba a la derecha) -> JSON model -> copia todo.
3. Pega y reemplaza el contenido de
   `grafana-13.0.1/conf/provisioning/dashboards/json/infinito-monitoreo.json`.
4. Commit + push.

## Anadir mas dashboards

Soltar mas archivos `.json` en
`grafana-13.0.1/conf/provisioning/dashboards/json/` y reiniciar Grafana.
Cada uno necesita un `uid` unico.
