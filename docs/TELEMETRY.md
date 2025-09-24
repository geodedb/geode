# Paging Telemetry (env-gated)

Geode can emit optional paging telemetry as JSON Lines on stderr. This is disabled by default and gated by environment variables to avoid noisy logs in normal operation.

- Env to enable: `GEODE_TELEMETRY_PAGING=1`
- Emission: server logs JSON on stderr when a `PULL` emits a page.
- Location in code: `src/server/main.zig` (`state.telemetry_paging` guards `logger.info` with `{ "type":"TELEMETRY", "event":"PULL_PAGE" }`).

Example server run:

```bash
GEODE_TELEMETRY_PAGING=1 ./zig-out/bin/geoded --listen-quic 127.0.0.1:7567 --log_json --result-format json
```

Example client (stdio):

```bash
GEODE_CAPTURE_SERVER_STDERR=1 ./zig-out/bin/geodec "RETURN 1 AS x ORDER BY x LIMIT 1" --format json
```

- The stderr line (pretty-printed) will contain a substring like:

```json
{ "type": "TELEMETRY", "event": "PULL_PAGE", "page_size": 1, "rows": 1 }
```

Notes:

- Telemetry is orthogonal to the wire protocol; frames on stdout remain unchanged.
- Tests: `test_telemetry_smoke.zig` (env-gated) spawns a server with `--test-exit-after-first-request` and ensures the `"event":"PULL_PAGE"` substring appears in stderr logs when enabled.
