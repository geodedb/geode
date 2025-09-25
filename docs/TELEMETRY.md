# Streaming Telemetry — Paging Events (env-gated) - v0.16.0

Geode can emit optional paging telemetry as JSON Lines on stderr. This is disabled by default and gated by environment variables to avoid noisy logs in normal operation.

**v0.16.0 Note**: Transport telemetry now includes QUIC+TLS metrics (handshake latency, stream multiplexing, loss recovery). TCP telemetry has been removed.

## Enablement (Environment)

- `GEODE_TELEMETRY_PAGING=1` — Enable pagination telemetry
- `GEODE_CI_TELEMETRY_SMOKE=1` — Enable the optional test that verifies telemetry presence
- `GEODE_CI_TELEMETRY_STRICT=1` — Treat missing telemetry in the smoke test as a failure (use in dedicated pipelines)
- `GEODE_QUIC_PASSIVE_TEARDOWN=1` — For short-lived QUIC tests, avoid vendor teardown crashes (optional safety)

## Emission

- Location in code: `src/server/main.zig` (`state.telemetry_paging` guards `logger.info` with `{ "type":"TELEMETRY", "event":"PULL_PAGE" }`).
- The server logs JSON on stderr when a `PULL` emits a page. Telemetry is orthogonal to the wire protocol; frames on stdout remain unchanged.

## Example server run

```bash
GEODE_TELEMETRY_PAGING=1 ./zig-out/bin/geoded --listen-quic 127.0.0.1:7567 --log_json --result-format json
```

## Example client (stdio)

```bash
GEODE_CAPTURE_SERVER_STDERR=1 ./zig-out/bin/geodec "RETURN 1 AS x ORDER BY x LIMIT 1" --format json
```

The stderr line will contain a substring like:

```json
{ "type": "TELEMETRY", "event": "PULL_PAGE", "page_size": 1, "rows": 1 }
```

## Example event (QUIC)

```json
{
  "ts": "1758732000",
  "level": "INFO",
  "component": "geode",
  "event": "PULL_PAGE",
  "page": { "index": 0, "size": 1 },
  "ordered": true,
  "order_keys": ["x"],
  "request_id": "abc123"
}
```

## Tests

- `test_telemetry_smoke.zig` (env-gated): spawns a server with `--test-exit-after-first-request` and ensures the `"event":"PULL_PAGE"` substring appears in stderr logs when enabled.

Example run:

```bash
GEODE_TELEMETRY_PAGING=1 GEODE_CI_TELEMETRY_SMOKE=1 zig test test_telemetry_smoke.zig
```

Strict mode (dedicated pipelines) — fail if telemetry is missing:

```bash
make quic-smoke-strict
```

Convenience/local (non-fatal):

```bash
make quic-smoke
```
