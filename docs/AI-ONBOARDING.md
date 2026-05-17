# AI Onboarding - Sistema POS Infinito
### Version 2 — Abril 2026

Documento de contexto para una IA que vaya a trabajar en cualquiera de los
repos del **Sistema POS Infinito** (stack de monitoreo). Lectura inicial de
5-10 minutos. Punteros a docs mas profundos al final de cada seccion.

> Si esta es tu primera interaccion con este proyecto: **lee este archivo
> entero** antes de tocar codigo.

> **Que cambio en v2 respecto a v1:**
> Grafana fue **eliminado** del stack de distribucion. La visualizacion de
> logs ahora la provee un **componente Angular nativo** en la app frontend,
> que consume dos endpoints nuevos en el ms negocio. InfluxDB sigue siendo
> el unico store de logs. Ver seccion 4 para el detalle completo.

---

## 1. TL;DR

- Sistema POS para tiendas de abarrotes colombianas, distribucion **local**
  (sin nube). Stack OSS para evitar lios de licencia.
- Compuesto por **5 repos** (ms negocio, ms seguridad, ms smtp, frontend
  Angular, app lanzadora JavaFX) + **1 repo: `logs-infinito`** que bundlea
  solo InfluxDB 3 Core para monitoreo local.
- Los logs del backend y los errores del frontend se guardan en
  **InfluxDB 3 Core** (measurements `backend_log` y `frontend_error`).
- Un **componente Angular** (en `infinito-ai-front`) visualiza esos datos
  consumiendo endpoints REST del ms negocio — no hay Grafana.
- La **app lanzadora** gestiona el ciclo de vida de InfluxDB (y ya no de
  Grafana).

---

## 2. Repos del proyecto

Todos viven bajo `C:\dev\repos\` (configurable desde el launcher).

| Repo | Que hace | Stack |
|---|---|---|
| `pos-relational-data-service` | **ms negocio**: productos, tickets, ventas. Escribe logs a InfluxDB. Expone endpoints de consulta de logs. | Spring Boot 2.7, Java 11, log4j2, Postgres |
| `infinito-security`           | ms seguridad: autenticacion / autorizacion | Spring Boot, Spring Security |
| `infinito-smtp-service`       | ms correos via cuenta Google | Spring Boot |
| `infinito-ai-front`           | frontend SPA del POS. Incluye componente dashboard de monitoreo. | Angular |
| `intinito-launcher`           | **app lanzadora**: gobierno/lifecycle de los servicios | JavaFX 11 |
| `logs-infinito`               | **app monitoreo**: solo InfluxDB 3 Core + scripts de operacion | PowerShell |

Otras carpetas como `bci/` no son del proyecto y se ignoran.

---

## 3. Arquitectura actual

```
+------------------+       logs (line protocol)      +-----------------+
| ms negocio       | -------------------------------> | InfluxDB 3 Core |
| (8088, Java)     |   POST /api/v3/write_lp          | (8181)          |
|                  |   measurement: backend_log       |   db: infinito  |
|                  |                                  |       _logs     |
|                  |   measurement: frontend_error    |                 |
+--------^---------+                                  +-----------------+
         |                                                    ^
         | POST /reporte-frontend                             |
         |                                             GET /api/v3/query_sql
         | GET  /api/v1/logs/backend  <---+            (via influxWebClient
         | GET  /api/v1/logs/frontend <---+             interno del ms negocio)
         |
+--------+---------+        +---------------+
| frontend Angular |        | intinito-     |
| (4200)           |        | launcher      |
| componente logs  |        | (JavaFX)      |---ps1--> InfluxDB lifecycle
|                  |        |               |
+------------------+        +---------------+
                                   ^
                                   | gestiona lifecycle de InfluxDB
                                   | (Grafana ya NO forma parte del stack)
```

### Flujo de datos completo

**Escritura (ingest):**
1. Backend genera log -> `InfluxLogAppender` (plugin log4j2) crea una
   linea de line protocol (measurement `backend_log`) y la entrega al
   `InfluxWriter`.
2. Frontend genera un error -> `POST /reporte-frontend` al ms negocio ->
   `ReporteFrontendServiceImpl` crea linea (measurement `frontend_error`) ->
   entrega al mismo `InfluxWriter`.
3. Worker thread del `InfluxWriter` agrupa en batches de 100 y hace
   `POST /api/v3/write_lp` a InfluxDB cada 2s.
4. Si InfluxDB esta caido -> el batch se **spool a disco** en
   `monitor-spool/*.lp`. Un retry job reintenta cada 30s.

**Lectura (dashboard Angular):**
1. Componente Angular autentica como `admin` y llama al ms negocio:
   `GET /api/v1/logs/backend` o `GET /api/v1/logs/frontend`.
2. `LogsMonitorController` (ms negocio) recibe la peticion, invoca
   `InfluxQueryService`, que usa el `influxWebClient` existente para
   hacer `GET /api/v3/query_sql` directamente a InfluxDB.
3. La respuesta JSON array se retransmite al cliente Angular sin
   transformacion adicional.

---

## 4. Que cambio respecto a v1 (Grafana eliminado)

| Aspecto | v1 (con Grafana) | v2 (sin Grafana) |
|---|---|---|
| Visualizacion de logs | Grafana 13 en puerto 3000 | Componente Angular nativo en la app frontend |
| Consulta a InfluxDB | Grafana via FlightSQL | ms negocio via `GET /api/v3/query_sql` (proxy) |
| Quien entra al dashboard | Usuario abre browser en localhost:3000 | Usuario abre la misma app Angular del POS |
| Dependencia nueva a distribuir | Grafana (zip ~100MB) | Ninguna |
| CORS en InfluxDB | No aplica (Grafana es server-side) | No aplica (Angular llama al ms negocio, no a Influx directamente) |
| Endpoints nuevos en ms negocio | Solo `POST /reporte-frontend` | Ademas `GET /api/v1/logs/backend` y `GET /api/v1/logs/frontend` |
| Estado en el launcher | Chips Influx + Grafana | Solo chip Influx |
| Scripts de Grafana | Activos | Obsoletos (siguen en disco pero no se usan) |

**Por que se elimino Grafana:** friccion de instalacion al distribuir el
producto a otras tiendas (zip extra, proceso extra, puerto extra). El
componente Angular cubre el mismo caso de uso sin dependencias nuevas.

---

## 5. Componentes clave por repo

### 5.1 `pos-relational-data-service` (ms negocio)

**Paquete `monitoring/`** — escritura a InfluxDB (sin cambios en v2):
- `InfluxProperties` — bind de `monitor.influx.*` en `application.properties`
- `InfluxConfig` — bean `WebClient` preconfigurado (baseUrl, auth-header, timeouts)
- `InfluxStaticHolder` — puente para que log4j2 alcance al bean Spring
- `LineProtocol` — builder de line protocol con escape correcto
- `InfluxWriter` — cola en memoria + worker thread + spool a disco + retry job
- `InfluxBootstrap` — crea database `infinito_logs` con retencion 90d al startup
- **`InfluxQueryService`** *(nuevo en v2)* — consulta `backend_log` y
  `frontend_error` via `GET /api/v3/query_sql`. Reutiliza `influxWebClient`.

**Paquete `logging/`** — appender log4j2 (sin cambios en v2):
- `InfluxLogAppender` — reemplaza al `DbAppender` anterior. Plugin log4j2.

**Paquete `controllers/`** — endpoints REST:
- `ReporteFrontendController` — `POST /reporte-frontend` (ingest de errores Angular)
- **`LogsMonitorController`** *(nuevo en v2)* — endpoints de consulta de logs

**DTOs relevantes:**
- `ReporteFrontendRequest` — body del endpoint de ingest

**Configuracion:**
- `application.properties` — bloque `monitor.influx.*` + `cors.allowed-origins`
- `log4j2-spring.xml` — usa `InfluxLogAppender`

**Archivos vacios / pendiente de borrar:**
- `logging/DbAppender.java`
- `logging/Log4jDataSourceConfig.java`
- `entities/ReporteFrontend.java`
- `repositories/ReporteFrontendRepository.java`

### 5.2 Endpoints de consulta de logs (nuevos en v2)

Ambos son `GET`, requieren token JWT de `admin`, devuelven JSON array.
Todos los query params son opcionales.

```
GET http://localhost:8088/api/v1/logs/backend
GET http://localhost:8088/api/v1/logs/frontend
```

**Query params comunes:**

| Param | Tipo | Descripcion | Ejemplo |
|---|---|---|---|
| `from` | string | Fecha/datetime inicio (inclusive). Formatos: `yyyy-MM-dd` o `yyyy-MM-ddTHH:mm:ssZ` | `2026-04-01` |
| `to`   | string | Fecha/datetime fin (inclusive). Mismos formatos. | `2026-04-25T23:59:59Z` |
| `limit`| integer | Max filas (1–500). Si se omite, no hay LIMIT. | `100` |

Regla: si se pasa solo fecha `yyyy-MM-dd`, `from` asume `T00:00:00Z` y
`to` asume `T23:59:59Z`. Si se pasa datetime con offset distinto a UTC
se normaliza a UTC automaticamente.

**Respuesta `/backend`** (array de objetos):
```json
[
  {
    "time": "2026-04-25T14:00:00Z",
    "level": "ERROR",
    "logger": "com.infinitesoft.pos_relational_data_service.services...",
    "message": "Descripcion del error"
  }
]
```

**Respuesta `/frontend`** (array de objetos):
```json
[
  {
    "time": "2026-04-25T13:55:00Z",
    "url": "/pos/venta",
    "error_type": "TypeError",
    "error": "Cannot read property 'id' of undefined",
    "actividad": "Intentando procesar venta",
    "reporte_id": "uuid-xxxx"
  }
]
```

Si InfluxDB esta caido, ambos endpoints retornan `[]` silenciosamente
(no rompen la UI). Formato invalido en `from`/`to` retorna `400 Bad Request`
con mensaje descriptivo.

**Clases involucradas:**
- `controllers/LogsMonitorController.java`
- `monitoring/InfluxQueryService.java`

### 5.3 `infinito-ai-front` (frontend Angular)

Pendiente de implementar (fuera de alcance de este repo): un componente
Angular que consuma los endpoints anteriores y reemplace el dashboard de
Grafana. El componente debe:
- Autenticar con el token JWT del admin (igual que cualquier otro servicio)
- Tener date pickers para `from` y `to`
- Tener un input para `limit`
- Mostrar tablas separadas para backend logs y frontend errors

### 5.4 `logs-infinito` (este repo)

```
logs-infinito/
├── grafana-13.0.1/                  (OBSOLETO en v2; se conserva en disco
│                                     pero no se usa ni se distribuye)
├── influxdb3-core-3.9.1-windows_amd64/   (activo; se bundlea en distribucion)
├── scripts/
│   ├── start-influx.ps1             (ACTIVO)
│   ├── stop-influx.ps1              (ACTIVO)
│   ├── restart-influx.ps1           (ACTIVO)
│   ├── healthcheck.ps1              (ACTIVO — solo chequea Influx en v2)
│   ├── smoke-test.ps1               (ACTIVO)
│   ├── start-monitoreo.ps1          (LEGACY — arrancaba Influx + Grafana)
│   ├── stop-monitoreo.ps1           (LEGACY)
│   ├── restart-monitoreo.ps1        (LEGACY)
│   ├── start-grafana*.ps1           (OBSOLETO)
│   ├── stop-grafana.ps1             (OBSOLETO)
│   └── restart-grafana.ps1          (OBSOLETO)
└── docs/
    ├── AI-ONBOARDING.md             (este archivo, v2)
    ├── contrato-launcher.md         (referencia — tabla de scripts desactualizada en v2)
    ├── grafana-dashboards.md        (OBSOLETO en v2)
    └── launcher-integration-notes.md
```

**Scripts activos en v2** (los del launcher deben usar estos):

| Script | Proposito | Exit codes | JSON final |
|---|---|---|---|
| `start-influx.ps1`   | Arranca InfluxDB, crea database si no existe | 0 ok, 1 fail influx, 3 fail db | `{"status":"ok","influxdb":"started\|running","database":"infinito_logs"}` |
| `stop-influx.ps1`    | Mata influxdb3.exe | 0 | `{"status":"ok","influxdb_killed":N}` |
| `restart-influx.ps1` | stop + start de InfluxDB | 0,1,3 | hereda de start-influx |
| `healthcheck.ps1`    | Verifica puerto 8181, `/health`, database | 0 ok, 1 algo fallo | `{"status":"ok\|warn\|fail","failed":N,"checks":[...]}` |
| `smoke-test.ps1`     | Escribe + lee 1 linea de prueba en cada measurement | 0 ok, 1 escritura fail, 2 lectura fail | `{"status":"ok\|fail","marker":"..."}` |

**Nota sobre `healthcheck.ps1`:** el script actual todavia chequea Grafana
(puerto 3000, datasource, dashboard). En v2 esos checks simplemente fallaran
si Grafana no esta corriendo. Si se actualiza el script, se pueden comentar
o eliminar los checks de Grafana (chequeos 4 y 5 en el codigo actual).

### 5.5 `intinito-launcher` (app lanzadora)

El `MonitoreoManager` existente gestiona Influx + Grafana. En v2 Grafana ya
no se levanta. Las acciones a actualizar en el launcher:

- Boton "Iniciar Monitoreo" -> usar `start-influx.ps1` en lugar de
  `start-monitoreo.ps1`
- Boton "Detener Monitoreo" -> usar `stop-influx.ps1`
- Eliminar el boton "Abrir Grafana" y el chip de estado de Grafana
- El polling de salud ahora solo verifica `http://127.0.0.1:8181/health`

---

## 6. Decisiones de diseno relevantes

| # | Decision | Por que |
|---|---|---|
| 1 | InfluxDB 3 Core OSS | Libre de licencia para SaaS. Liviano. Estandar de facto en metricas. |
| 2 | Grafana eliminado del stack | Reduce friccion de instalacion al distribuir a otras tiendas. Cero dependencias extra. |
| 3 | Angular como dashboard (en lugar de Grafana) | El frontend ya existe, el usuario ya esta logueado, se reusan tokens JWT. Sin nuevo proceso ni puerto. |
| 4 | MS negocio como proxy a InfluxDB | Resuelve CORS: Angular no puede llamar a InfluxDB directamente desde el browser sin configurar CORS en Influx (no soportado de fabrica en v3). |
| 5 | Modo `--without-auth` en local | Cero friccion para tienda local; auth se activa cuando se exponga a la red. |
| 6 | Un bucket `infinito_logs` con 2 measurements | Queries unificadas. Simplicidad. |
| 7 | Retencion 90d | Equilibrio disco / poder ver tendencias. |
| 8 | Resiliencia: cola memoria + spool disco + retry | El POS NUNCA debe romperse por monitoreo caido. Sobrevive a reinicios. |
| 9 | WebClient (Spring WebFlux) para escribir Y consultar | Cero dep nuevas en pom; reutiliza el bean `influxWebClient` ya existente. |
| 10 | Scripts PowerShell idempotentes + JSON output | Reusables a mano y desde launcher; faciles de debuggear. |
| 11 | El contrato JSON de `POST /reporte-frontend` NO cambia | El frontend Angular no necesita cambios para el ingest. |
| 12 | `limit` opcional en endpoints de consulta | Si hay filtros de fecha, el rango controla el volumen. Si no hay nada, la UI decide cuantos mostrar. |

---

## 7. Gotchas conocidos

### A) InfluxDB 3 tiene schema dinamico
Una columna (field) **solo existe si se ha escrito alguna vez**. Si el
componente Angular hace una consulta y un field nunca se escribio, el
query devuelve `[]` o un error de schema.

**Regla:** en cualquier appender / writer hacia InfluxDB, escribir
SIEMPRE todos los fields que el componente Angular pueda consultar (con
valor vacio `""` cuando no aplique). Vivido con la columna `exception`
del measurement `backend_log`. Ver `launcher-integration-notes.md` seccion 4.

### B) InfluxDB hace flush WAL -> parquet asincrono
Tras escribir una linea, puede tardar hasta ~12s en ser legible por
query. El `smoke-test.ps1` reintenta hasta 12s antes de dar la lectura
por fallida. No bajar de ese umbral al hacer pruebas manuales.

### C) `Invoke-WebRequest` con `format=jsonl` devuelve `byte[]`
PowerShell trata el Content-Type `application/jsonl` como binario.
Cualquier script PS1 que consulte InfluxDB por SQL debe convertir:
```powershell
$bodyStr = if ($r.Content -is [byte[]]) {
    [System.Text.Encoding]::UTF8.GetString($r.Content)
} else { [string]$r.Content }
```
Ya aplicado en `healthcheck.ps1` y `smoke-test.ps1`.

### D) El `influxWebClient` usa `format=json` (no `jsonl`)
Los endpoints nuevos del ms negocio consultan InfluxDB con `format=json`
(devuelve un JSON array directo), mientras que los curls de ejemplo en
docs usan `format=jsonl`. Ambos formatos funcionan; para server-side
`json` es mas conveniente porque no requiere parseo de lineas.

### E) `LogsMonitorController` requiere rol `admin`
Los endpoints `/api/v1/logs/*` tienen `@PreAuthorize("hasRole('admin')")`.
El componente Angular debe estar dentro de una ruta/guard de admin, y
enviar el JWT del usuario admin en el header `Authorization`.

### F) Distribuciones NO se versionan en git
El `.gitignore` de `logs-infinito` solo persiste la configuracion.
Las distribuciones (el zip de InfluxDB) vienen de releases oficiales y
se asume que estan descomprimidas en su carpeta. Grafana puede ignorarse
o eliminarse del disco.

### G) `healthcheck.ps1` todavia incluye chequeos de Grafana
En v2 esos chequeos fallaran si Grafana no esta corriendo, haciendo que
el exit code sea 1 (warn/fail) aunque Influx este perfectamente. Si el
launcher usa `healthcheck.ps1` para el chip de estado de Influx, hay
que actualizar el script para omitir los chequeos de Grafana, o crear
un `healthcheck-influx.ps1` simplificado.

---

## 8. Como orientarse segun el tipo de tarea

| Si vas a... | Empieza por... |
|---|---|
| Tocar logs / appenders del ms negocio | `monitoring/InfluxWriter.java` + `logging/InfluxLogAppender.java` + `application.properties` |
| Agregar campos al componente de dashboard Angular | `monitoring/InfluxQueryService.java` (modifica el SQL) + `controllers/LogsMonitorController.java` |
| Agregar un filtro nuevo a los endpoints de consulta | `InfluxQueryService.appendWhereClause()` + firma publica del metodo + `LogsMonitorController` params |
| Cambiar como el launcher arranca/para Influx | `intinito-launcher/.../core/MonitoreoManager.java` + scripts `start-influx.ps1` / `stop-influx.ps1` |
| Diagnosticar "no veo datos en el componente Angular" | 1) curl directo a InfluxDB (ver seccion 11). 2) curl al endpoint del ms negocio con token admin. 3) Ver `smoke-test.ps1`. |
| Agregar un nuevo measurement a InfluxDB | Recordar gotcha A: escribir TODOS los fields siempre, aunque sea `""`. Convencion: `LineProtocol.Line` de `monitoring/LineProtocol.java`. |
| Distribuir el POS a otra tienda | Manual: descomprimir `influxdb3-core-*.zip` en `logs-infinito/`, lanzar el launcher, pulsar "Iniciar InfluxDB". Grafana no se distribuye. |
| Actualizar `healthcheck.ps1` para omitir Grafana | Comentar o eliminar chequeos 4 y 5 (datasource y dashboard de Grafana) y ajustar el contador `$total`. |

---

## 9. Pendientes / proximos pasos

- **Componente Angular de dashboard**: implementar en `infinito-ai-front`
  consumiendo `GET /api/v1/logs/backend` y `GET /api/v1/logs/frontend`.
  Ver seccion 5.3 para el contrato de los endpoints.
- **Actualizar `healthcheck.ps1`**: quitar los chequeos de Grafana (o crear
  `healthcheck-influx.ps1` simplificado) para que el chip de Influx en el
  launcher no reporte falsos negativos.
- **Actualizar `MonitoreoManager` en el launcher**: usar `start-influx.ps1`
  / `stop-influx.ps1` en lugar de `start-monitoreo.ps1` / `stop-monitoreo.ps1`.
  Remover el chip y los botones de Grafana de la UI JavaFX.
- **Borrar archivos vacios** del ms negocio: `DbAppender.java`,
  `Log4jDataSourceConfig.java`, `ReporteFrontend.java`,
  `ReporteFrontendRepository.java`.
- **Dropear tablas postgres**: cuando todo este validado, ejecutar
  `pos-relational-data-service/src/main/resources/doc/drop-tablas-monitoreo.sql`.
- **Auto-instalacion**: que el launcher descargue InfluxDB automaticamente
  desde GitHub releases si la carpeta no existe.
- **Auth en Influx**: cuando se exponga a la red, dejar de usar
  `--without-auth`, generar token y rellenar `monitor.influx.auth-header`
  en `application.properties`.
- **Metricas de negocio en Influx**: si se quieren agregar ventas / tickets
  / inventario al mismo `InfluxWriter`, la infraestructura ya esta lista.

---

## 10. Glosario

| Termino | Significado |
|---|---|
| **measurement** | Equivalente a "tabla" en InfluxDB. Aqui: `backend_log` y `frontend_error`. |
| **tag** | Columna indexada de baja cardinalidad (`level`, `url`, `error_type`). Solo string. |
| **field** | Columna no indexada (`message`, `exception`, `actividad`). Tipos: string, int, float, bool. |
| **line protocol** | Formato de texto de ingest de Influx: `measurement,tag1=v1 field1="..." timestampNs`. |
| **bucket / database** | En Influx 3 se llama `database`. Aqui: `infinito_logs`. |
| **spool** | Carpeta `monitor-spool/` donde `InfluxWriter` deja batches `.lp` cuando Influx esta caido. |
| **influxWebClient** | Bean `WebClient` de Spring, configurado en `InfluxConfig.java`. Se usa tanto para escribir como para consultar. |
| **--without-auth** | Flag de InfluxDB 3 para arrancar sin autenticacion (modo local). |
| **PS1** | Script PowerShell. |
| **JSON summary** | Ultima linea de cada script PS1, parseable, con `{"status":"ok\|fail",...}`. |
| **basePath** | `C:/dev/repos` por defecto. Configurable desde el launcher. |
| **logs-infinito** | El repo que bundlea InfluxDB + scripts de operacion. Grafana fue removido en v2. |

---

## 11. Comandos utiles para verificar estado actual

```cmd
REM Arrancar InfluxDB
powershell -ExecutionPolicy Bypass -File C:\dev\repos\logs-infinito\scripts\start-influx.ps1

REM Healthcheck de InfluxDB
powershell -ExecutionPolicy Bypass -File C:\dev\repos\logs-infinito\scripts\healthcheck.ps1

REM Smoke test end-to-end
powershell -ExecutionPolicy Bypass -File C:\dev\repos\logs-infinito\scripts\smoke-test.ps1

REM Ver logs recientes directamente en InfluxDB
curl -G "http://127.0.0.1:8181/api/v3/query_sql" ^
  --data-urlencode "db=infinito_logs" ^
  --data-urlencode "q=SELECT time, level, logger, message FROM backend_log ORDER BY time DESC LIMIT 10" ^
  --data-urlencode "format=jsonl"

REM Ver errores frontend directamente en InfluxDB
curl -G "http://127.0.0.1:8181/api/v3/query_sql" ^
  --data-urlencode "db=infinito_logs" ^
  --data-urlencode "q=SELECT time, url, error_type, error, actividad, reporte_id FROM frontend_error ORDER BY time DESC LIMIT 5" ^
  --data-urlencode "format=jsonl"

REM Llamar al endpoint proxy del ms negocio (requiere token JWT de admin)
curl -H "Authorization: Bearer <token>" ^
  "http://localhost:8088/api/v1/logs/backend?limit=10"

curl -H "Authorization: Bearer <token>" ^
  "http://localhost:8088/api/v1/logs/backend?from=2026-04-25&to=2026-04-25&limit=50"

curl -H "Authorization: Bearer <token>" ^
  "http://localhost:8088/api/v1/logs/frontend?from=2026-04-01"
```

---

## 12. Cambios recientes — Mayo 2026

### 12.1 Boton "Scripts Admin" en el launcher

Se agrego un boton **"Scripts Admin"** (azul/indigo) en la barra inferior del launcher
(`hello-view.fxml`), entre "Ver Logs" y "Iniciar Todo".

**Que hace:** abre una ventana con scroll que muestra 5 scripts de PowerShell listos
para copiar y pegar, generados dinamicamente con la `basePath` configurada en el
launcher (`AppConfig.getInstance().getBasePath()`). El usuario los copia y los ejecuta
manualmente en una consola de PowerShell como Administrador.

**Por que existen:** dos motivos. (1) instalacion limpia en un laptop nuevo
(item 1, agregado posteriormente). (2) tras una actualizacion de Windows (mayo
2026), la politica de Control de aplicaciones (WDAC / Zone.Identifier) bloqueo
ejecutables y scripts descargados de internet, incluyendo `influxdb3.exe` y
`start-influx.ps1` (items 2-5).

**Scripts incluidos en la ventana:**

| # | Descripcion | Que hace |
|---|---|---|
| 1 | **Instalar InfluxDB en este laptop** (all-in-one) | Verifica binario, `Unblock-File` recursivo, crea `object-store/`, mata instancias previas, arranca en background, espera `/health` (45s), crea database `infinito_logs` con retencion 90d (idempotente: 409 = ok), y hace **seed del schema** escribiendo 1 linea de `backend_log` y 1 de `frontend_error` con todos los tags/fields. El seed evita el gotcha de schema dinamico (gotcha A) — sin seed, las queries del componente Angular fallarian si un field nunca se escribio |
| 2 | Crear certificado autofirmado | `New-SelfSignedCertificate` + lo agrega a `Root` y `TrustedPublisher` de `LocalMachine` + exporta `.pfx` a `C:\infinito-pos-sign.pfx` |
| 3 | Desbloquear script de arranque InfluxDB | `Unblock-File` sobre `{basePath}\logs-infinito\scripts\start-influx.ps1` |
| 4 | Desbloquear ejecutable `influxdb3.exe` | `Get-ChildItem` recursivo en `{basePath}\logs-infinito` filtrando `influxdb3.exe` + `Unblock-File` |
| 5 | Verificar archivos aun bloqueados | Busca `.exe` y `.ps1` en `{basePath}\logs-infinito` que tengan el stream `Zone.Identifier` activo |

**Archivos modificados:**
- `intinito-launcher/src/main/resources/com/infinitesoft/launcher/hello-view.fxml` — boton nuevo en HBox inferior
- `intinito-launcher/src/main/java/com/infinitesoft/launcher/HelloController.java` — metodos `onOpenAdminScripts()` y `crearSeccionScript()`

**Contexto tecnico del bloqueo de Windows:**
- El error del launcher era: `Start-Process : Este comando no se puede ejecutar debido al error: Una directiva de Control de aplicaciones bloqueo este archivo.`
- AppLocker estaba vacio (`<AppLockerPolicy Version="1" />`), el problema era `Zone.Identifier` (marca que Windows pone a archivos descargados) + politica de grupo que fuerza `RemoteSigned`.
- La solucion fue `Unblock-File` (elimina el stream `Zone.Identifier`), NO cambiar `ExecutionPolicy` (bloqueado por GPO).
- El script de certificado autofirmado (punto 1) resuelve el caso de SmartScreen bloqueando aplicaciones por firma desconocida (problema distinto al de Zone.Identifier).

---

### 12.2 Fix: los servicios ya no se detienen al cerrar el launcher

**Problema:** al cerrar la ventana del launcher, `HelloApplication.stop()` llamaba a
`controller.shutdown()` → `serviceManager.shutdown()` → `stopAll()`, matando todos
los procesos (Java, Node, InfluxDB).

**Solucion:** se modifico `ServiceManager.shutdown()` para que solo detenga los
hilos internos de monitoreo (el `ScheduledExecutorService` de polling de estado y el
`MonitoreoManager`), sin llamar a `stopAll()`. Los procesos hijos lanzados via
`ProcessBuilder` continuan corriendo de forma independiente.

**Comportamiento resultante:**
- Cerrar el launcher → servicios permanecen activos.
- Boton "Detener Todo" → sigue funcionando igual (llama a `stopAll()` explicitamente).
- `MonitoreoManager.shutdown()` solo detiene el hilo de polling HTTP, NO apaga InfluxDB.

**Archivos modificados:**
- `intinito-launcher/src/main/java/com/infinitesoft/launcher/core/ServiceManager.java` — metodo `shutdown()`: se elimino la llamada a `stopAll()`.
- `intinito-launcher/src/main/java/com/infinitesoft/launcher/HelloApplication.java` — mensaje de log actualizado.

---

## 13. Como pedir ayuda a una IA

Cuando arranques una sesion nueva pidele a la IA que **lea primero este
archivo entero**. Si la tarea toca el ms negocio o el launcher, pedirle
ademas que lea el `AI-CONTEXT.md` en la raiz del repo correspondiente.

Mal: "agrega un filtro al dashboard de logs"
Bien: "lee `C:\dev\repos\logs-infinito\docs\AI-ONBOARDING.md` (v2) y
luego agrega al endpoint `GET /api/v1/logs/backend` un filtro por `level`
(INFO, WARN, ERROR) que se pase como query param opcional."
