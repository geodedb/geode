# Bug-fix Triage — GitLab #749: Prometheus `/metrics` + `/health` HTTP Endpoints

**Scope:** Implementation planning for `src/monitoring/metrics_server.zig` — currently a Zig 0.16 migration stub. Triage only, no implementation.

**Reproduction:** `curl --connect-timeout 2 http://127.0.0.1:9091/metrics` against a running `geode serve` with `GEODE_METRICS_PORT=9091` → `Connection refused` (kernel-level; no listener bound). Confirmed locally 2026-04-16.

**Upstream config proof:** `src/server/main.zig:541-556` reads `GEODE_METRICS_PORT`, calls `metrics_server.initGlobalMetrics(gpa, port)`, which calls `MetricsServer.start()` at `src/monitoring/metrics_server.zig:47`. `start()` body: sets `running = false`, returns. No socket is ever opened.

---

## (a) Exact 5-Test HTTP I/O Contract

Spec: `/home/benji/src/devnw/codepros/geode/geode-test-harness/geodetestlab-cli/specs/gap_0166_prometheus_metrics.yml`. All tests run against a server started with `GEODE_METRICS_PORT=9091` and no `GEODE_METRICS_BIND` override (default `127.0.0.1`).

| # | Test | Request | Expected response |
|---|------|---------|-------------------|
| 1 | `metrics_endpoint_available` | `GET http://127.0.0.1:9091/metrics` | `200`, `Content-Type: text/plain`, body contains `geode_queries_total` **and** `geode_connections_active` |
| 2 | `health_endpoint_available` | `GET http://127.0.0.1:9091/health` | `200`, `Content-Type: application/json`, body contains `status` **and** `ok` |
| 3 | `query_metrics_increment` | Two GQL queries (`RETURN 1 AS x`, `RETURN 2 AS y`) over QUIC, then `GET /metrics` | `200`, body contains `geode_queries_total` |
| 4 | `unknown_path_returns_404` | `GET http://127.0.0.1:9091/unknown` | `404` |
| 5 | `metric_types_correct` | `GET http://127.0.0.1:9091/metrics` | `200`, body contains `# TYPE geode_queries_total counter`, `# TYPE geode_connections_active gauge`, `# HELP geode_queries_total` |

**Port discovery:** Env var `GEODE_METRICS_PORT` read by `src/server/main.zig:541`. Spec hardcodes `9091`. There is no explicit `--metrics-bind` flag today; lifecycle is env-gated — if `GEODE_METRICS_PORT` is unset, metrics server is skipped. No server-alongside-`serve` flag; init happens automatically when env var is set.

**Body substring matches are substring tests** (harness `body_contains`), so `application/json; charset=utf-8` and `text/plain; version=0.0.4` both satisfy the `content_type` checks.

**Content sufficiency:** `exportMetrics(writer)` at `src/monitoring/prometheus.zig:147-229` already emits `# HELP`, `# TYPE`, and bare-value lines in the exact Prometheus 0.0.4 text format the spec asserts. Test 5's assertions are already satisfied by the existing formatter output — no format work required.

---

## (b) Existing Surface Map

### `src/monitoring/metrics_server.zig` (current stubs)

| Line | Symbol | Status | Intended semantics |
|------|--------|--------|--------------------|
| 20-37 | `MetricsServer` struct + `init` | Compiles | Holds `allocator`, `collector`, `port`, `server: ?std.Io.net.Server`, `running`, `accept_pool: ?*pooled.ThreadPool` |
| 39-41 | `deinit` | Works (calls stop) | — |
| 47-52 | `start` | **STUB** | Must bind TCP, store `Server`, spawn `acceptLoop` on `accept_pool`, set `running=true` |
| 55-62 | `stop` | Partial | Flips `running=false`, nils server, deinits pool; does NOT close the `Server.socket` (missing `server.deinit(io)`) |
| 66-69 | `handleConnection(conn: std.Io.net.Server.Connection)` | **STUB + WRONG SIGNATURE** | `std.Io.net.Server.Connection` does NOT exist in Zig 0.16 (`Server.accept` returns `Stream` directly). Signature must change to `Stream`. |
| 72-75 | `serveMetrics(stream: Stream)` | **STUB** | Must write `HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: N\r\n\r\n<body>` where body = `collector.exportMetrics(writer)` output |
| 78-81 | `serveHealth(stream: Stream)` | **STUB** | Must write `HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n...\r\n\r\n{"status":"ok"}\n` |
| 84-87 | `serve404(stream: Stream)` | **STUB** | Must write `HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n` |
| 90-92 | `acceptLoop()` | **STUB** | Must loop on `server.accept(io)` until `g_shutdown_requested` or `running==false`; on each stream, parse request-line + dispatch route |
| 94-97 | `runAcceptLoop(ctx)` | **STUB** trampoline | Thread-pool entry wrapper for `acceptLoop` |
| 102-130 | `resolveMetricsBindAddress()` / `parseIp4Addr` | **Works** | Returns `[4]u8` from `GEODE_METRICS_BIND` env or `127.0.0.1`. Safe to reuse. |
| 132-173 | `initGlobalMetrics` / `shutdownGlobalMetrics` | **Works** | Lifecycle glue; already wired from `server/main.zig:545` |

### `src/monitoring/prometheus.zig` (collector ready)

| Line | Symbol | Purpose |
|------|--------|---------|
| 146-229 | `PrometheusExporter.exportMetrics(writer: anytype)` | Writes `# HELP` / `# TYPE` / value lines for all registered metrics |
| 249-327 | `MetricsCollector.init` | Registers `geode_queries_total` (counter), `geode_connections_active` (gauge), plus 8 more |
| 376-378 | `MetricsCollector.exportMetrics(writer)` | Wrapper around `PrometheusExporter.exportMetrics` — **this is the one-line call the HTTP handler needs** |

Global singletons: `g_metrics_collector`, `g_metrics_server` at `metrics_server.zig:134-135`. `MetricsCollector` is thread-safe at the `StringHashMap` level for reads while writes happen on the query hot-path (existing assumption; no additional mutex required for the triage — flag for fixer verification).

### `src/server/main.zig` boot path

Line 541 reads env; line 544-550 calls `initGlobalMetrics` which itself invokes `server.start()` at line 149. Nothing behind a flag — env presence is the switch. Nothing else calls the metrics server directly.

### Zig 0.16 `std.Io.net.Server` API (verified against `/home/benji/.local/share/mise/installs/zig/0.16.0/lib/std/Io/net.zig`)

- `std.Io.net.IpAddress.parseIp4(text, port)` → `Ip4Address.ParseError!IpAddress` (line 114).
- `std.Io.net.IpAddress.listen(*const IpAddress, io: Io, options: ListenOptions) !Server` (line 246). `ListenOptions{ .reuse_address = true, .kernel_backlog = 128, .mode = .stream, .protocol = .tcp }`.
- `Server.accept(*Server, io) AcceptError!Stream` (line 1442). **Returns `Stream`, NOT `Connection`.**
- `Server.deinit(*Server, io)` closes the listen socket (line 1406).
- `Stream.reader(stream, io, buffer) Reader` and `Stream.writer(stream, io, buffer) Writer` (lines 1393/1397) — both take a user-provided `[]u8` buffer and return struct containing an `Io.Reader`/`Io.Writer` via `.interface`.
- `Stream.close(*const Stream, io)` closes the connection (line 1248).
- `Stream.shutdown(stream, io, how)` available if needed for half-close.

### Thread pool

`src/transport/thread_pool.zig` `ThreadPool.init(allocator, config)` returns `*ThreadPool`; submit via `submitBlocking(WorkItem{ .context, .callback })`. Already imported in `metrics_server.zig:13` as `pooled`. Single worker is sufficient — clamp is enforced to `@max(n, 2)` upstream (line 176), so 1 worker request → 2 threads allocated (acceptor + spare for blocking lane). Acceptable.

---

## (c) Minimal Implementation Plan (method-by-method)

Keep the existing struct layout; only fill in stubs. Total ~180 lines of net-new code.

### 1. Add a Threaded Io backend field

Extend struct (`metrics_server.zig:20-26`):

```
threaded: ?std.Io.Threaded = null,   // owned; init in start(), deinit in stop()
```

`start()` creates `std.Io.Threaded.init(std.heap.smp_allocator, .{})` (cert_gen.zig:17-18 pattern), caches it, and uses `threaded.io()` for all subsequent net ops.

### 2. `start(self) !void` — ~25 lines

1. `const bytes = resolveMetricsBindAddress();` (already returns `[4]u8`).
2. `const ip_str = std.fmt.bufPrint(buf[0..], "{d}.{d}.{d}.{d}", .{bytes[0],...})`.
3. `var addr = try std.Io.net.IpAddress.parseIp4(ip_str, self.port);`
4. `self.threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{}); const io = self.threaded.?.io();`
5. `self.server = try std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true });`
6. `self.accept_pool = try pooled.ThreadPool.init(self.allocator, .{ .num_threads = 1, .queue_capacity = 4 });`
7. `self.running = true;`
8. `try self.accept_pool.?.submitBlocking(.{ .context = @ptrCast(self), .callback = runAcceptLoop });`
9. On any error: set `running = false`, null `server`, free pool, deinit threaded — return the error.

### 3. `acceptLoop(self)` — ~15 lines

```
while (self.running and !g_shutdown_requested.load(.acquire)) {
    const stream = self.server.?.accept(io) catch |err| switch (err) {
        error.SocketNotListening, error.ConnectionAborted => continue,
        error.WouldBlock => { std.time.sleep(10_000_000); continue; },
        else => return,  // fatal — log and bail
    };
    defer stream.close(io);
    self.handleConnection(stream) catch {};  // per-conn errors are logged but don't kill the loop
}
```

Single-threaded accept + synchronous serve is fine — Prometheus scrapes are low-cardinality (typ. 1 scrape/15s). If we need parallelism later, dispatch `handleConnection` onto another pool slot. Initial impl: serial.

### 4. `handleConnection(self, stream)` — ~40 lines

Replace erroneous `Server.Connection` signature with `std.Io.net.Stream`.

1. Stack buffer `var read_buf: [4096]u8 = undefined;` + `var reader = stream.reader(io, &read_buf);`.
2. Read request line until `\r\n` via `reader.interface.takeDelimiterInclusive('\n')` or `readUntilDelimiter`. Max 8 KiB — reject larger as 400.
3. Parse `GET /path HTTP/1.x` with a trivial scanner: skip method (verify starts with `GET`), slice until next space = path, ignore rest.
4. Drain remaining headers (read until `\r\n\r\n`) — we don't need their content.
5. Route:
   - `std.mem.eql(u8, path, "/metrics")` → `serveMetrics(stream)`.
   - `std.mem.eql(u8, path, "/health")` → `serveHealth(stream)`.
   - else → `serve404(stream)`.

No full HTTP/1.1 parsing needed: no body, no keep-alive, no chunked, no query string. Minimal state machine.

### 5. `serveMetrics(self, stream)` — ~20 lines

1. `var body: std.ArrayList(u8) = .init(self.allocator); defer body.deinit();`
2. `try self.collector.exportMetrics(body.writer());` — this returns the canonical Prometheus text format from `prometheus.zig:376`.
3. Compose response headers into a stack buffer via `std.fmt.bufPrint`:  
   `"HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n"`.
4. Write headers then body via `stream.writer(io, &write_buf)` → `try w.interface.writeAll(headers); try w.interface.writeAll(body.items); try w.interface.flush();`.

**Allocator note:** Use `self.allocator` (the server's GPA passed through `initGlobalMetrics`), not a fresh page allocator. Typical export is ~1 KiB.

### 6. `serveHealth(self, stream)` — ~10 lines

Constant response: `"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\nConnection: close\r\n\r\n{\"status\":\"ok\"}"`. Write as one `writeAll` + flush.

### 7. `serve404(self, stream)` — ~5 lines

Constant `"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"`.

### 8. `stop(self)` — add 3 lines

Before nil-ing `self.server`: `if (self.server) |*srv| if (self.threaded) |*t| srv.deinit(t.io());`. Then deinit `threaded` after `accept_pool` drains. Current stop() leaks the listen fd.

### 9. Compile-clean the erroneous signature

`handleConnection` declared with `std.Io.net.Server.Connection` must change to `std.Io.net.Stream`. That type does not exist in 0.16.

---

## (d) Risks + Recommended Allocator/Threading Pattern

| Risk | Mitigation |
|------|------------|
| **R1 — `global_single_threaded.io()` OOM** (`failing` allocator) | **Do not use it.** Create a local `std.Io.Threaded` in `start()` via `std.heap.smp_allocator` — same pattern as `src/tools/cert_gen.zig:17-18` (governance-approved, not `page_allocator`). Store it on the `MetricsServer` struct; `deinit` it in `stop()`. |
| **R2 — shutdown deadlock: accept blocks indefinitely** | `g_shutdown_requested` (atomic at `src/server/main.zig:286`) can't interrupt a blocking `accept`. Options: (a) call `server.socket.close(io)` from signal path — `accept` returns `error.SocketNotListening` which the loop treats as exit signal; (b) set SO_RCVTIMEO on the listen socket via posix for periodic wakeup. Prefer (a): `stop()` calls `server.deinit(io)` first; the accept loop checks `running` after `accept` returns and exits cleanly. |
| **R3 — mutex ordering** | Metrics server holds NO cross-module mutexes during request handling. `MetricsCollector.exportMetrics` iterates its own `StringHashMap` — if writers are concurrent, wrap with a per-collector `std.Thread.RwLock` (fixer's call — existing code assumes single-writer from query-hotpath; inspect concurrency before adding). Per CLAUDE.md tiering this is a new Tier 6 concern, outside the QUIC-connections tier. |
| **R4 — bind address default** | Already correct: `resolveMetricsBindAddress()` returns `127.0.0.1` unless `GEODE_METRICS_BIND` overrides. Keep. Do NOT hardcode `0.0.0.0`. Spec uses `127.0.0.1` in all curls. |
| **R5 — Content-Length drift** | Compute `body.items.len` dynamically; do NOT hardcode. Prometheus bodies grow with registered metrics over time. |
| **R6 — `Server.accept` signature returns `Stream`, not `Connection`** | Delete the phantom `.Connection` reference on line 66. Change handler signature throughout. |
| **R7 — `accept_pool` clamps to 2 threads** | The thread-pool compat wrapper forces `@max(num_threads, 2)`. Acceptable — 2 threads for an accept loop + its blocking lane is within budget. No code change required. |
| **R8 — test 3 gates on QUIC working** | Test 3 runs two GQL statements over QUIC before scraping. If `GEODE_METRICS_PORT=9091` is set but the QUIC path is broken (GitLab #747), test 3 fails for a different reason. Not a blocker for this fix; note in the verification plan. |

---

## (e) File:Line Fix Sites

All under `/home/benji/src/devnw/codepros/geode/geode/`:

- `src/monitoring/metrics_server.zig:20-37` — add `threaded: ?std.Io.Threaded = null` field.
- `src/monitoring/metrics_server.zig:47-52` — replace stub `start()` with real listen + spawn.
- `src/monitoring/metrics_server.zig:55-62` — extend `stop()` to close the listener via `server.deinit(io)` and deinit `threaded`.
- `src/monitoring/metrics_server.zig:66-69` — fix signature (`Connection`→`Stream`) and implement.
- `src/monitoring/metrics_server.zig:72-75` — implement `serveMetrics` (call `src/monitoring/prometheus.zig:376`).
- `src/monitoring/metrics_server.zig:78-81` — implement `serveHealth`.
- `src/monitoring/metrics_server.zig:84-87` — implement `serve404`.
- `src/monitoring/metrics_server.zig:90-97` — implement `acceptLoop` + keep `runAcceptLoop` trampoline.
- No changes to `src/server/main.zig` — boot wiring is already correct.
- No changes to `src/monitoring/prometheus.zig` — formatter ready.

**Reference implementations in-tree (for fixer's copy-paste inspiration):**

- `src/tools/cert_gen.zig:17-18` — local `std.Io.Threaded` with `smp_allocator`.
- `src/client/grpc_query_transport.zig:69-74` — canonical `parseIp4` + connect pattern (adapt for listen).
- Zig stdlib `lib/std/Io/net.zig:246-254` — `IpAddress.listen` signature.
- Zig stdlib `lib/std/Io/net.zig:1442-1444` — `Server.accept` returns `Stream`.

---

## Classification Summary

| Aspect | Value |
|--------|-------|
| Class | (b) missing-impl (migration stub) |
| Blast radius | 1 file (`metrics_server.zig`), ~180 net-new lines |
| Test gate | 5/5 specs in `gap_0166_prometheus_metrics.yml` |
| Existing CANARY | `REQ-PROMETHEUS-WIRE-001/002/003/004/005` already tagged `TESTED` (aspirational, must stay) |
| Security posture | Preserved — bind defaults to `127.0.0.1` |
| Fix-session tractability | Yes — single file, ~1-2 hours, no cross-cutting refactor |
| Dependencies | None (independent of GitLab #747 QUIC watchdog) |

**Verification plan (for fixer, not this triage):** `make build && GEODE_METRICS_PORT=9091 ./zig-out/bin/geode serve --listen 127.0.0.1:3141 &`; `curl -sv http://127.0.0.1:9091/metrics | head` ; then `cd ../geode-test-harness && make test-spec SPEC=geodetestlab-cli/specs/gap_0166_prometheus_metrics.yml`. Expect 5/5 green. Note test 3 transitively depends on QUIC `on_progress` wiring (#747) — rerun after #747 lands if test 3 alone remains red.
