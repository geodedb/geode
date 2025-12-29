# Gap Register: Graph DB Alpha Spec Compliance

| ID | Title | Type | Spec Ref | Evidence/Link | Severity | Fix Plan | Owner | Status | PR/Commit | Notes |
|----|-------|------|----------|---------------|----------|----------|-------|--------|-----------|-------|
| G01 | Runtime `Value` missing spec types | correctness | A1, Requirements | `src/value_types.zig` L62 | P0 | Update `value_types.Value` to include UUID, URL, Domain, Jsonb, etc. Sync with `heap.Value`. | Agent | Closed | | Critical: Eval engine cannot handle these types. |
| G02 | `ExtValue` missing spec types | correctness | A1 | `src/eval_extended.zig` L66 | P1 | Update or migrate `ExtValue` types to `value_types.Value`. | Agent | Closed | | Bridge needed or unification. |
| G03 | Eval operators missing support | correctness | Functions | `src/eval.zig` | P0 | Implement operators (comparison, math) for new types in `eval.zig`. | Agent | Closed | | e.g. UUID comparison, date math. |
| G04 | Missing `Interval` type | correctness | Temporal | `src/value_types.zig` | P1 | Add `Interval` to `Value`. | Agent | Closed | | Required for temporal math. |
| G05 | Check Persistence wiring | ops | Persistence | `src/index` | P1 | Verify `interval_tree`, `jsonb`, `domain` indexes are hooked up to storage/wal. | Agent | Closed | | Integrated into AdvancedIndexManager and persisted. |
| G06 | Spec vs Impl: `Char`/`Varchar` | correctness | Strings | `src/value_types.zig` | P2 | Impl uses `Str`. Spec requires `Char(n)`/`Varchar(n)` with length byte. | Agent | Closed | | Types added to `Value`. |
| G07 | `Decimal128` vs `Decimal` | correctness | Numeric | `src/value_types.zig` | P2 | `value_types.Value` has `Decimal` (i128, u8). `heap.Value` has `Decimal128`. Consistent? | Agent | Closed | | Confirmed compatible structs. |
