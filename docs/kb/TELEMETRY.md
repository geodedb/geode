# Streaming Telemetry (Paging Events)

This document describes the optional, environment-guarded streaming telemetry emitted by `geoded` during result paging. It does not change the binary protocol; it logs JSON lines to `stderr` for observability and integration with log pipelines.

Status: optional; single-node; development/ops aid.

## Toggles

- `GEODE_TELEMETRY_PAGING=1`
  - When set, the server emits one telemetry JSON line per `PULL` page.
- `GEODE_CAPTURE_SERVER_STDERR=1`
  - Client-side test/helper toggle. When set, `geodec` captures the server's `stderr` and forwards it to the client's `stderr`, enabling e2e tests to assert on telemetry.

Defaults: both unset.

## Event Shape

Each page emission produces a single JSON line on `stderr` with the fields below (names are stable for tests):

```json
{
  "level": "INFO",
  "component": "server",
  "type": "TELEMETRY",
  "event": "PULL_PAGE",
  "page_size": "<n>",
  "rows_emitted": "<m>",
  "final": "true|false"
}
```

- `type`: always `TELEMETRY` for these events.
- `event`: always `PULL_PAGE` for paging emissions.
- `page_size`: stringified page size requested by the client.
- `rows_emitted`: stringified number of rows included in this page.
- `final`: `true` when this page is the last page of the stream, else `false`.

Notes:

- Values are strings for stability in grep and simple tooling.
- The server logger may prepend other stable keys like `level` and `component`.

## Example

Enable paging telemetry and run a paginated query:

```sh
GEODE_TELEMETRY_PAGING=1 ./zig-out/bin/geoded --data_dir ./data --log_json --result-format json 2>server.log &
PID=$!
./zig-out/bin/geodec "RETURN 1 AS x ORDER BY x LIMIT 1" --format json
kill $PID
cat server.log | grep '"event":"PULL_PAGE"'
```

Example line:

```json
{
  "level": "INFO",
  "component": "server",
  "type": "TELEMETRY",
  "event": "PULL_PAGE",
  "page_size": "1",
  "rows_emitted": "1",
  "final": "true"
}
```

## Tests and CANARY

A CANARY e2e test validates the presence and shape of this telemetry:

- Test name: `TestCANARY_REQ_GQL_090_TelemetryPagingPull`
- Requirement: `REQ-GQL-090` — FEATURE "StreamingTelemetry", ASPECT `PagingEvents`, STATUS `TESTED`.

This telemetry does not alter wire protocol frames and is safe to leave disabled in production unless required for observability.

## Helper Script

For quick local validation, a helper script is provided:

- Path: `scripts/telemetry-smoke.sh`
- Usage: `scripts/telemetry-smoke.sh [page_size]`
- Behavior: Builds are assumed present in `zig-out/bin`. The script starts `geoded` with `GEODE_TELEMETRY_PAGING=1`, runs a small ordered+limited query via `geodec`, prints any captured telemetry lines containing `"event":"PULL_PAGE"`, and cleans up the server process.

Makefile convenience target (if available in your checkout):

```sh
make build && bash scripts/telemetry-smoke.sh 1
```

Notes:

- Requires a successful `zig build` to produce `geoded` and `geodec`.
- The script captures server `stderr` to a temp file and greps for telemetry lines.
- Exit status is always 0; inspect stderr warnings if no telemetry lines are shown.
