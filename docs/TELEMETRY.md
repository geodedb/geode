# Streaming Telemetry (Paging Events) - v0.16.0

Geode can emit optional paging telemetry as JSON Lines on stderr. This is disabled by default and gated by environment variables to avoid noisy logs in normal operation.

**v0.16.0 Note**: Transport telemetry now includes QUIC+TLS metrics (handshake latency, stream multiplexing, loss recovery). TCP telemetry has been removed.

Status: optional; single-node; development/ops aid.

## Environment Variables

### Core Toggles

- `GEODE_TELEMETRY_PAGING=1` - Enable pagination telemetry (emits one JSON line per `PULL` page)
- `GEODE_CAPTURE_SERVER_STDERR=1` - Client-side toggle to capture server's stderr for e2e tests

### CI/Testing Variables

- `GEODE_CI_TELEMETRY_SMOKE=1` - Enable the optional test that verifies telemetry presence
- `GEODE_CI_TELEMETRY_STRICT=1` - Treat missing telemetry in the smoke test as a failure (use in dedicated pipelines)
- `GEODE_QUIC_PASSIVE_TEARDOWN=1` - For short-lived QUIC tests, avoid vendor teardown crashes (optional safety)

Defaults: all unset.

## Event Shape

Each page emission produces a single JSON line on `stderr` with the fields below (names are stable for tests):

```json
{
  "ts": "1758732000",
  "level": "INFO",
  "component": "server",
  "type": "TELEMETRY",
  "event": "PULL_PAGE",
  "page_size": "<n>",
  "rows_emitted": "<m>",
  "final": "true|false",
  "page": { "index": 0, "size": 1 },
  "ordered": true,
  "order_keys": ["x"],
  "request_id": "abc123"
}
```

### Field Descriptions

- `type`: always `TELEMETRY` for these events
- `event`: always `PULL_PAGE` for paging emissions
- `page_size`: stringified page size requested by the client
- `rows_emitted`: stringified number of rows included in this page
- `final`: `true` when this page is the last page of the stream, else `false`
- `ordered`: whether the result set is ordered
- `order_keys`: keys used for ordering (when applicable)
- `request_id`: unique identifier for the request

**Notes**: Values are strings for stability in grep and simple tooling. The server logger may prepend other stable keys like `level` and `component`.

## Emission Location

Location in code: `src/server/main.zig` (`state.telemetry_paging` guards `logger.info` with `{ "type":"TELEMETRY", "event":"PULL_PAGE" }`).

The server logs JSON on stderr when a `PULL` emits a page. Telemetry is orthogonal to the wire protocol; frames on stdout remain unchanged.

## Usage Examples

### Server with Telemetry

```bash
GEODE_TELEMETRY_PAGING=1 ./zig-out/bin/geode serve --listen 127.0.0.1:7567 --log_json --result-format json 2>server.log &
PID=$!
./zig-out/bin/geode query "RETURN 1 AS x ORDER BY x LIMIT 1" --format json
kill $PID
cat server.log | grep '"event":"PULL_PAGE"'
```

### Client with Server Stderr Capture

```bash
GEODE_CAPTURE_SERVER_STDERR=1 ./zig-out/bin/geode query "RETURN 1 AS x ORDER BY x LIMIT 1" --format json
```

The stderr line will contain a substring like:

```json
{ "type": "TELEMETRY", "event": "PULL_PAGE", "page_size": 1, "rows": 1 }
```

## Tests

### CANARY Integration

A CANARY e2e test validates the presence and shape of this telemetry:

- Test name: `TestCANARY_REQ_GQL_090_TelemetryPagingPull`
- Requirement: `REQ-GQL-090` - FEATURE "StreamingTelemetry", ASPECT `PagingEvents`, STATUS `TESTED`

### Smoke Tests

`test_telemetry_smoke.zig` (env-gated): spawns a server with `--test-exit-after-first-request` and ensures the `"event":"PULL_PAGE"` substring appears in stderr logs when enabled.

```bash
# Basic smoke test
GEODE_TELEMETRY_PAGING=1 GEODE_CI_TELEMETRY_SMOKE=1 zig test test_telemetry_smoke.zig

# Strict mode (dedicated pipelines) - fail if telemetry is missing
make quic-smoke-strict

# Convenience/local (non-fatal)
make quic-smoke
```

## Helper Script

For quick local validation, a helper script is provided:

- Path: `scripts/telemetry-smoke.sh`
- Usage: `scripts/telemetry-smoke.sh [page_size]`

Behavior: Builds are assumed present in `zig-out/bin`. The script starts the server with `GEODE_TELEMETRY_PAGING=1`, runs a small ordered+limited query, prints any captured telemetry lines containing `"event":"PULL_PAGE"`, and cleans up the server process.

```bash
make build && bash scripts/telemetry-smoke.sh 1
```

**Notes**:
- Requires a successful `zig build` to produce the geode binary
- The script captures server `stderr` to a temp file and greps for telemetry lines
- Exit status is always 0; inspect stderr warnings if no telemetry lines are shown

## Safety Note

This telemetry does not alter wire protocol frames and is safe to leave disabled in production unless required for observability.
