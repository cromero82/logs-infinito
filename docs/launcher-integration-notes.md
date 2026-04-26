# Notas de integracion - intinito-launcher x logs-infinito

Hallazgos validados durante la primera puesta en marcha de InfluxDB 3 Core y
Grafana, para tenerlos a mano cuando se modifique la app lanzadora (JavaFX).

> Estado al cierre de esta sesion: los dos servicios arrancan, pasan
> healthcheck y son accesibles via navegador. Listos para integrar.

---

## 1. InfluxDB 3 Core 3.9.1

### Comando de arranque verificado
```
influxdb3.exe serve ^
  --node-id node1 ^
  --object-store file ^
  --data-dir <PATH> ^
  --http-bind 127.0.0.1:8181 ^
  --without-auth
```

### Tiempos
- Arranque en frio: **~10 segundos** (vimos `startup time: 10241ms`).
- Crea `<data-dir>/node1/catalog/...` y archivos parquet en cuanto recibe writes.

### Logs
- Salen a **stdout** en formato estructurado:
  `<ISO-timestamp>  <LEVEL> <module>: msg key=value ...`
- Linea de "ya esta arriba" que sirve como senal:
  `INFO influxdb3_server: startup time: ... address=127.0.0.1:8181`

### Endpoints utiles
| Path | Metodo | Para que |
|---|---|---|
| `/health` | GET | Devuelve 200 + `OK`. Mejor para healthcheck rapido. |
| `/ping`   | GET | Equivalente, devuelve build info en headers. |
| `/api/v3/write_lp?db=<bucket>` | POST | Ingestar line protocol (lo que usara el ms negocio). |
| `/api/v3/query_sql?...` | GET/POST | Queries SQL (lo que usara Grafana). |

### Apagado limpio
- `Ctrl+C` en la ventana, o `taskkill /F /IM influxdb3.exe`.
- Como se usa filesystem object-store, no hay drenado pendiente.

### Notas
- El binario es **210 MB** (lleva Python embebido para plugins). No commitear.
- El warning "Setting worker thread priority not supported on this platform"
  en Windows es esperado, ignorarlo.
- Sin `--without-auth` el primer arranque crea un token; lo dejamos para
  cuando demos el salto a "produccion local".

---

## 2. Grafana 13.0.1

### Comando de arranque verificado
```
grafana.exe server ^
  --homepath C:\dev\repos\logs-infinito\grafana-13.0.1 ^
  --config   C:\dev\repos\logs-infinito\grafana-13.0.1\conf\custom.ini
```

### Tiempos
- Arranque en frio: **~10-15 segundos** (migracion SQLite + provisioning).
- Reinicios calientes: 3-5s.

### Logs
- IMPORTANTE: por default Grafana 13 NO loguea a consola si en `[log]` no esta
  `mode = console`. Hay que ponerlo explicito:
  ```ini
  [log]
  mode = console file
  level = info
  ```
- Formato: `LEVEL [MM-DD|HH:mm:ss] <msg>  logger=<x> key=value ...`
- Linea de "ya esta arriba":
  `INFO ... HTTP Server Listen ... address=127.0.0.1:3000`

### Endpoints utiles
| Path | Metodo | Para que |
|---|---|---|
| `/api/health`         | GET  | JSON `{"database":"ok","version":"13.0.1",...}` |
| `/api/datasources`    | GET  | Listar datasources (auth requerida) |
| `/api/dashboards/uid/<uid>` | GET | Lectura de dashboard |
| `/login`              | GET  | UI de login |
| `/d/<uid>/<slug>?kiosk=tv` | GET | Embed sin chrome (para iframes en el front) |

### Credenciales iniciales
- `admin` / `admin` (el primer login pide cambiarla).
- Quedan persistidas en `grafana-13.0.1/data/grafana.db` (SQLite).

### Datos persistentes
- `grafana-13.0.1/data/grafana.db`     - DB SQLite (users, dashboards, etc.)
- `grafana-13.0.1/data/sessions/`      - sesiones HTTP
- `grafana-13.0.1/data/plugins/`       - plugins descargados desde la UI
- `grafana-13.0.1/data/log/grafana.log` - log a archivo

Borrar `data/` resetea Grafana a estado de fabrica.

---

## 3. Recomendaciones para `intinito-launcher`

### Botones nuevos sugeridos (panel "Monitoreo")
- **Iniciar Monitoreo** -> arranca ambos procesos (InfluxDB primero, despues
  Grafana - aunque el orden no es estricto).
- **Detener Monitoreo** -> taskkill de los dos.
- **Reiniciar Monitoreo** -> stop + start.
- **Estado** (LED/chip) -> verde/amarillo/rojo segun healthchecks.
- **Abrir Grafana** -> `Desktop.getDesktop().browse(URI("http://localhost:3000"))`.
- **Abrir Logs Backend** -> dashboard especifico, ej.
  `http://localhost:3000/d/<uid-logs-backend>/`.
- **Abrir Logs Frontend** -> dashboard de errores frontend.
- **Ver logs locales** (consola) -> ya existe el patron en el launcher.

### Como arrancar desde Java (ProcessBuilder)
```java
ProcessBuilder pb = new ProcessBuilder(
    "C:\\dev\\repos\\logs-infinito\\influxdb3-core-3.9.1-windows_amd64\\influxdb3.exe",
    "serve",
    "--node-id", "node1",
    "--object-store", "file",
    "--data-dir", "C:\\dev\\repos\\logs-infinito\\influxdb3-core-3.9.1-windows_amd64\\object-store",
    "--http-bind", "127.0.0.1:8181",
    "--without-auth"
);
pb.directory(new File("C:\\dev\\repos\\logs-infinito\\influxdb3-core-3.9.1-windows_amd64"));
pb.redirectErrorStream(true);
Process p = pb.start();
// Leer p.getInputStream() en un hilo y volcarlo al panel de logs del launcher
```

Lo mismo para Grafana cambiando bin y args.

### Como detectar "arriba" desde Java
Mejor que parsear logs: hacer **polling al endpoint de health** cada 500ms con
timeout de 30s. Mas robusto y no depende del formato de logs de cada release.

```java
HttpClient client = HttpClient.newBuilder()
    .connectTimeout(Duration.ofSeconds(2)).build();

boolean isUp(String url) {
    try {
        HttpResponse<String> r = client.send(
            HttpRequest.newBuilder(URI.create(url))
                .timeout(Duration.ofSeconds(2)).GET().build(),
            HttpResponse.BodyHandlers.ofString());
        return r.statusCode() == 200;
    } catch (Exception e) { return false; }
}

// Endpoints:
//   InfluxDB: http://127.0.0.1:8181/health
//   Grafana : http://127.0.0.1:3000/api/health
```

### Lifecycle de los procesos
- Guardar el `Process` para poder `destroy()` al cerrar el launcher.
- Registrar shutdown hook: `Runtime.getRuntime().addShutdownHook(...)` que mate
  los procesos hijos para no dejar zombies.
- En Windows, `Process#destroyForcibly()` equivale a TerminateProcess; suficiente.

### "Actualizar" (analogo al boton existente para microservicios)
- Para InfluxDB y Grafana NO hay `git pull && build`. La actualizacion seria:
  bajar la nueva release, descomprimirla en una carpeta nueva con sufijo de
  version (`grafana-13.0.2/`), apuntar el launcher al nuevo path y borrar la
  carpeta vieja. Lo dejamos para una segunda iteracion.

---

## 4. Gotcha de InfluxDB 3 - schema dinamico

InfluxDB 3 (DataFusion) construye el schema de cada measurement a partir de
los fields que se han escrito alguna vez. **Si una columna jamas se ha
escrito, no existe**, y cualquier `SELECT campo_X` desde Grafana revienta
con `Schema error: no field named ...`.

**Regla**: cuando se diseña un nuevo measurement o se anade un field nuevo
al appender, hay que escribirlo SIEMPRE (con valor vacio "" cuando no
aplique) para que la columna exista en el schema. Visto en la primera
puesta en marcha con la columna `exception` del measurement `backend_log`.

## 5. Siguiente paso (no en esta sesion)

Modificar `pos-relational-data-service` (ms negocio) para:
1. Reemplazar el appender de logback `DbAppender` (que escribe a `app_log` en
   postgres) por uno que envie a InfluxDB via line protocol (`/api/v3/write_lp`).
2. Reemplazar el endpoint `POST /reporte-frontend` (que escribe a la tabla
   `reporte_frontend`) por una escritura tambien a InfluxDB en una "measurement"
   distinta (ej: `frontend_error`).
3. Eliminar las tablas `app_log` y `reporte_frontend` de postgres una vez
   verificada la migracion.
4. Crear dashboards Grafana provisionados (en
   `grafana-13.0.1/conf/provisioning/dashboards/`) para visualizar:
   - Volumen de logs por nivel/logger
   - Errores recientes (backend + frontend)
   - Detalle de errores frontend con su `actividadReciente`.
