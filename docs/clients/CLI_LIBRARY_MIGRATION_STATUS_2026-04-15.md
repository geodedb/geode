# CLI Library Migration Status - 2026-04-15

## Scope completed

This work continues the migration of `geode` away from its in-repo client implementations and onto the sibling Zig client library in `../geode-client-zig`.

The following CLI-facing paths are now routed through `geode-client-zig`:

- `geode query`
- `geode shell` / REPL QUIC transport
- `src/mcp/client.zig`
- `geode auth login`
- remote `geode migrate` execution path
- remote `geode restore`
- remote `geode backup`

## Key code changes

In `geode`:

- `build.zig` / `build.zig.zon`
  - Added the sibling `../geode-client-zig` dependency to the main build graph.
  - Wired the installed Zig client artifact and example binary through the real external library instead of the old in-repo stub implementation.
- `clients/zig/client_minimal.zig` / `clients/zig/example_minimal.zig`
  - Re-exported the real `geode-client-zig` API surface so `zig build clients` now ships the sibling library through the existing `geode` packaging entrypoint.
- `src/lib.zig`
  - Re-exported `zig_client` and the shared `zig_quic_bridge` so internal modules can migrate onto the sibling client package without importing it ad hoc.
- `src/client/zig_quic_bridge.zig`
  - Added `initClientStrictTls(...)` so commands that previously defaulted to verified TLS can keep that behavior while still using the shared Zig client library.
- `src/cli/main.zig`
  - Migrated `auth login` server handshake (`connectToServer`) to `geode-client-zig`.
  - Removed the last direct QUIC client usage from the main CLI command path.
- `src/cli/backup_cli.zig`
  - Migrated migration/backup/restore remote transport helpers to `geode-client-zig`.
- `src/client/query_scope.zig`
  - Added leading `USE GRAPH ...;` extraction so `geode query -` binds graph context correctly for stdin batches.
- `src/client/repl/quic_transport.zig`
  - REPL transport already uses the shared Zig client bridge.
- `src/mcp/client.zig`
  - Switched MCP transport/session ownership onto `geode-client-zig`.
  - Rebuilt query JSON collection on top of sibling-library protobuf responses instead of the old in-repo QUIC client path.
- `src/server/quic_connection_handler.zig`
  - Follow-up validation fix: changed remote backup payload streaming from raw `stream.write(...)` to `stream.writeAll(...)` so larger backup downloads do not stall mid-transfer under QUIC flow control.

In `geode-client-zig`:

- `geode_client_v2.zig`
  - Added `receiveRawBytes(...)` so admin flows can switch from framed protobuf control messages to raw stream payloads without falling back to the old in-repo QUIC client.

In `geode-test-harness`:

- `geodetestlab-cli/geodetestlab/lib/executor.py`
  - Follow-up validation fix: injects managed server address, QUIC TLS flag, and default admin credentials for remote admin commands (`backup create`, `restore`, `migrate`) the same way the harness already does for `query`.

## Verification completed

Builds:

- `zig build` in `../geode-client-zig`: passed
- `zig build` in `./`: passed

Targeted spec runs against `geode-test-harness/geodetestlab-cli`:

- `shell_source_batch.yml`: `50 passed`
- `geode_auth.yml`: `11 passed`
- `backup_operations_basic.yml`: `3 passed`
- `gap_137_backup_tls.yml`: `2 passed`
- `geode_migrations.yml`: `30 passed`
- `backup_restore_operations.yml`: `10 passed`

Manual regression verification:

- `USE GRAPH <graph>; MATCH ...` via `geode query -` now returns correct counts.
- Explicit transaction stdin batches (`BEGIN/COMMIT`, mixed case, rollback) complete without hanging.
- `geode backup create --output ... --server ... --user geode --password ... --insecure-tls-skip-verify` now completes end-to-end instead of stalling after the metadata response.

## Broader harness follow-up

On a directory-wide `geodetestlab run --specs specs` attempt from `geode-test-harness/geodetestlab-cli`, the first concrete blocker was `backup_restore_operations.yml` (`7 passed, 3 failed`).

That run exposed two separate follow-up issues:

- the harness was not injecting the managed server address/credentials for remote admin commands, so `backup create` defaulted to `127.0.0.1:3141` during random-port managed runs
- the QUIC server backup path streamed payload bytes with `stream.write(...)`, which could stop after a partial chunk and leave the migrated client path waiting for the remaining bytes

After fixing both issues, `backup_restore_operations.yml` passes (`10 passed`).

## Remaining broad verification

Still pending at time of this note:

- clean rerun of the full `geode-test-harness` spec sweep (`geodetestlab run --specs geodetestlab-cli/specs`) from the beginning after the backup streaming and harness-command fixes
- harness Python/unit reruns from their correct working directories
- previously requested cross-repo client validation beyond the targeted harness slice

## Worktree notes

The `geode`, `geode-client-zig`, and `geode-test-harness` worktrees were already dirty before / during this continuation. Unrelated edits were intentionally preserved.
