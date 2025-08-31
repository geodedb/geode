# Binary Protocol — GQL Outcome & Diagnostics Mapping

## Messages

- `HELLO` → server caps, conformance profile digest.
- `BEGIN/COMMIT/ROLLBACK` → txn control; includes access mode.
- `RUN_GQL` → carries text + params + session settings.
- `PULL` → streaming of binding table pages; page carries **ordered flag**, **order keys**.

## Status & Diagnostics

- Each response frame includes: `status_class` (00000/01000/02000/… per ISO), `status_subclass`, optional **additional statuses** array (UA002 policy), and `flagger_findings[]` if any extension/option is in effect. **Precedence** follows ISO rules.

## Result Frames

- `SCHEMA`: column names + value types (incl. temporal normal forms).
- `BINDINGS`: rows (may repeat) + `ordered=true|false` meta (binds LIMIT/OFFSET semantics).
- `EXPLAIN/PROFILE`: JSON as per `query_engine.md` Zig POCs. :contentReference[oaicite:80]{index=80}
