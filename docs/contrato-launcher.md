# Contrato logs-infinito <-> intinito-launcher (Java)

Define como la app lanzadora JavaFX invocara los scripts de operacion del
stack de monitoreo, sin necesidad de intervencion humana.

> **Premisa**: todos los scripts en `logs-infinito/scripts/` son idempotentes,
> imprimen una linea JSON al final con el resumen, y reportan exit code claro.
> La app lanzadora solo necesita: ejecutar -> leer exit code -> opcionalmente
> parsear el JSON.

## Tabla de scripts

### Stack completo
| Script | Proposito | Exit codes | Output JSON |
|---|---|---|---|
| `start-monitoreo.ps1` | Idempotente. Arranca ambos servicios en background y crea database. | 0 ok, 1 influx fail, 2 grafana fail, 3 db fail | `{"status":"ok","influxdb":"started\|running","grafana":"started\|running","database":"infinito_logs"}` |
| `stop-monitoreo.ps1`  | Mata grafana e influxdb. | 0 | `{"status":"ok","grafana_killed":N,"influxdb_killed":N}` |
| `restart-monitoreo.ps1` | stop + start | 0..3 | hereda de start |
| `healthcheck.ps1` | Valida puertos, /health, database, datasource y dashboard | 0 ok, 1 algo fallo | `{"status":"ok\|warn\|fail","failed":N,"warn":N,"total":N,"checks":[...]}` |
| `smoke-test.ps1` | Escribe + lee 1 linea de prueba en cada measurement | 0 ok, 1 escritura fail, 2 lectura fail | `{"status":"ok\|fail","marker":"...","stage":"..."}` |

### Por servicio (los usa el launcher para botones individuales)
| Script | Proposito | Exit codes | Output JSON |
|---|---|---|---|
| `start-influx.ps1`     | Solo InfluxDB. Crea database al primer arranque. | 0 ok, 1 influx fail, 3 db fail | `{"status":"ok","influxdb":"started\|running","database":"infinito_logs"}` |
| `stop-influx.ps1`      | Mata influxdb3.exe | 0 | `{"status":"ok","influxdb_killed":N}` |
| `restart-influx.ps1`   | stop + start de Influx | 0,1,3 | hereda de start-influx |
| `start-grafana-bg.ps1` | Solo Grafana en background | 0 ok, 2 grafana fail | `{"status":"ok","grafana":"started\|running"}` |
| `stop-grafana.ps1`     | Mata grafana.exe | 0 | `{"status":"ok","grafana_killed":N}` |
| `restart-grafana.ps1`  | stop + start de Grafana | 0,2 | hereda de start-grafana-bg |

## Como invocar desde Java (ProcessBuilder)

PowerShell debe ejecutarse via `powershell.exe -ExecutionPolicy Bypass -File ...`
para evitar problemas con la politica de ejecucion del usuario.

```java
public class MonitoreoLauncher {

    private static final Path REPO = Paths.get("C:/dev/repos/logs-infinito");

    public ResultadoOperacion startMonitoreo() throws IOException, InterruptedException {
        return runScript("start-monitoreo.ps1");
    }

    public ResultadoOperacion stopMonitoreo() throws IOException, InterruptedException {
        return runScript("stop-monitoreo.ps1");
    }

    public ResultadoOperacion healthcheck() throws IOException, InterruptedException {
        return runScript("healthcheck.ps1");
    }

    private ResultadoOperacion runScript(String name) throws IOException, InterruptedException {
        Path script = REPO.resolve("scripts").resolve(name);
        ProcessBuilder pb = new ProcessBuilder(
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", script.toString()
        );
        pb.directory(REPO.toFile());
        pb.redirectErrorStream(true);

        Process p = pb.start();

        // Capturar TODO el output. La ULTIMA linea no vacia es el JSON resumen.
        StringBuilder full = new StringBuilder();
        String lastLine = "";
        try (BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()))) {
            String line;
            while ((line = r.readLine()) != null) {
                full.append(line).append('\n');
                if (!line.trim().isEmpty()) lastLine = line.trim();
            }
        }
        int exit = p.waitFor();
        return new ResultadoOperacion(exit, lastLine, full.toString());
    }

    public static class ResultadoOperacion {
        public final int exitCode;
        public final String jsonResumen;   // ultima linea (JSON parseable)
        public final String outputCompleto; // para mostrar en panel de logs
        public ResultadoOperacion(int e, String j, String o) {
            this.exitCode = e; this.jsonResumen = j; this.outputCompleto = o;
        }
        public boolean isOk() { return exitCode == 0; }
    }
}
```

## Botones sugeridos en el panel "Monitoreo" del launcher

| Boton | Accion | UI feedback |
|---|---|---|
| Iniciar  | runScript("start-monitoreo.ps1") | spinner -> chip verde si exit=0 |
| Detener  | runScript("stop-monitoreo.ps1")  | chip gris |
| Reiniciar| runScript("restart-monitoreo.ps1") | spinner |
| Healthcheck | runScript("healthcheck.ps1") | popup tabla + chip color global |
| Smoke test  | runScript("smoke-test.ps1")  | popup OK/FAIL |
| Abrir Grafana | `Desktop.browse(URI.create("http://localhost:3000"))` | abre navegador |
| Abrir dashboard | `Desktop.browse(URI.create("http://localhost:3000/d/infinito-monitoreo"))` | abre dashboard directo |

## Polling de estado para el indicador del launcher

En lugar de invocar `healthcheck.ps1` cada N segundos (caro porque arranca un
PowerShell), la app lanzadora puede hacer **polling HTTP nativo**:

```java
private static boolean isUp(String url) {
    try {
        HttpClient c = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(2)).build();
        HttpResponse<Void> r = c.send(
            HttpRequest.newBuilder(URI.create(url))
                .timeout(Duration.ofSeconds(2)).GET().build(),
            HttpResponse.BodyHandlers.discarding());
        return r.statusCode() == 200;
    } catch (Exception e) { return false; }
}

// Cada 5s en un Timer JavaFX:
boolean influx  = isUp("http://127.0.0.1:8181/health");
boolean grafana = isUp("http://127.0.0.1:3000/api/health");

EstadoChip chip = (influx && grafana) ? EstadoChip.VERDE
                : (influx || grafana) ? EstadoChip.AMARILLO
                : EstadoChip.ROJO;
```

`healthcheck.ps1` se reserva para **diagnostico bajo demanda** (cuando el
usuario pulsa el boton "Diagnosticar").

## Lifecycle / shutdown del launcher

Importante: si la app lanzadora cierra mientras los procesos `influxdb3.exe` y
`grafana.exe` siguen vivos, es deseable matarlos para no dejar zombies.

```java
Runtime.getRuntime().addShutdownHook(new Thread(() -> {
    try { runScript("stop-monitoreo.ps1"); } catch (Exception ignored) {}
}));
```

Alternativa mas elegante: NO mover los procesos del Process devuelto por
ProcessBuilder (porque los lanzo PowerShell, no Java directamente), y matar
por nombre via `taskkill /F /IM grafana.exe`. Es lo que hace el script.

## Distribucion futura: instalacion automatica

Para distribuir a otras tiendas, la app lanzadora podra (en una iteracion
futura) descargar las distribuciones desde GitHub releases:

```java
// Solo si no existe la carpeta correspondiente
if (!Files.exists(REPO.resolve("influxdb3-core-3.9.1-windows_amd64"))) {
    String url = "https://download.influxdata.com/influxdb/releases/influxdb3-core_3.9.1_windows_amd64.zip";
    // descargar -> descomprimir en REPO
}
if (!Files.exists(REPO.resolve("grafana-13.0.1"))) {
    String url = "https://dl.grafana.com/oss/release/grafana-13.0.1.windows-amd64.zip";
    // descargar -> descomprimir en REPO
}
```

(De momento esto se asume manual; la primer iteracion del launcher solo
gestiona los procesos y abre dashboards.)

## Resumen "first-run" desde la app lanzadora

```
1. usuario pulsa "Iniciar Monitoreo"
2. launcher ejecuta start-monitoreo.ps1
3. parsea JSON: si status=ok -> chip verde
4. (opcional) launcher ejecuta healthcheck.ps1 -> popup tabla con todos los chequeos
5. usuario pulsa "Abrir Grafana" -> abre browser en localhost:3000
6. (opcional) usuario pulsa "Smoke test" -> verifica que la integracion end-to-end funciona
```
