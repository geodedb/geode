# Binary Protocol — GQL Outcome & Diagnostics Mapping (v0.15.x)

## Messages

- `HELLO` — client greeting (name, version, wanted conformance).
- `BEGIN` / `COMMIT` / `ROLLBACK` — transaction demarcation.
- `RUN_GQL` — submit a GQL program (single statement supported currently) plus params.
- `PULL` — request next page of current result binding table.

## Status & Diagnostics

Each response frame includes:

- `status_class` (ISO/IEC 39075 codes, e.g. 00000 success, 02000 warning) — subclass future.
- Optional `additional_statuses` (UA002 precedence policy) when multiple diagnostics apply.
- Optional `flagger_findings` listing implementation-defined (I:_) and dependent (U:_) behaviors (e.g. `I:IllegalOrderKeyPolicy=ident-only`, `U:US001/enforced`).

## Result Frames

- `SCHEMA` — column descriptors `{name,type}` (always first for a new statement, including PROFILE mode).
- `BINDINGS` — page of rows plus ordering + pagination metadata (not produced for PROFILE statements).
- `EXPLAIN` — logical operator array JSON.
- `PROFILE` — per‑operator metrics JSON (staged: emitted only after the first `PULL` following the SCHEMA line; no BINDINGS lines are sent in PROFILE mode).

## Pagination Semantics

Row production currently materializes the full result, then serves slices on `PULL` (simple + UNION queries). PROFILE mode differs: rows are evaluated (or aggregated) only to collect metrics; they are not streamed back — only `SCHEMA` then `PROFILE`.

Example `BINDINGS` frame:

```json
{
  "status_class": "00000",
  "result": {
    "type": "BINDINGS",
    "ordered": true,
    "order_keys": ["x"],
    "rows": [{ "x": 1 }, { "x": 2 }],
    "final": false,
    "flagger_findings": ["I:IllegalOrderKeyPolicy=ident-only"]
  }
}
```

When the last page is emitted, `final:true` signals completion of the current result set. A subsequent `PULL` (without a new `RUN_GQL`) now returns an `ERROR` frame with code `NoResult` (no replay) — clients MUST stop pulling once `final:true` is observed.

Constraints:

- `page_size=0` defaults to 1000.
- Interleaving multiple active result sets is not supported; a second `PULL` after `final:true` yields `NoResult`.
- PROFILE: first `PULL` after `SCHEMA` returns a `PROFILE` frame (not BINDINGS) and completes the statement (`NoResult` thereafter).
- `ordered` / `order_keys` propagate logical ordering guarantees; server does not reorder inside a page.

## Extended Frames

`EXPLAIN` / `PROFILE` carry a JSON payload under `result.json`. Format is additive; consumers must ignore unknown keys.

Current (v0.15.x) JSON fields:

### EXPLAIN

- `logical`: array of `{ op }`
- `properties`: may include `ordered`, `limit`, `offset`, `distinct`, `union_mode` ("DISTINCT" | "ALL")
- (flags emitted via outer `flagger_findings`)

### PROFILE

- `ops`: array of `{ op, rows, time_ns }`
  - Core ops: `Project`, `Distinct`, `Sort`, `Offset`, `Limit`
  - Aggregation ops (GROUP BY): `AggregateBuild`, `AggregateEmit`
  - UNION phase ops (PROFILE UNION ...): `UnionLeft`, `UnionTails`, `UnionDedup` (DISTINCT only), final `SetOpUnion`
- `setop` (optional for UNION): `{ type:"UNION", mode:"DISTINCT"|"ALL", input_rows_left, input_rows_right, output_rows, hash_dedup_size? }`
- `total_time_ns`: wall clock encompassing all ops listed
- (flags emitted via outer `flagger_findings`)

### Notes

- Timing is nanosecond resolution (`time_ns`). Earlier drafts referenced `time_ms`; documentation updated to match implementation.
- Aggregation PROFILE emits no detail rows — only operator metrics.
- Flag `U:UnionPhaseTimings` may appear when UNION phase timings are present.

Planned additions (not yet present): per-op `input_rows`, memory metrics, allocation counters.

## Diagnostics Examples

- Unordered pagination (`LIMIT/OFFSET` without `ORDER BY`) ⇒ primary `US001` (anchor 16.18–16.19) with flag `U:US001/enforced`.
- Illegal ORDER key (function call) ⇒ `IllegalOrderKey` (anchor 14.10) + flag `I:IllegalOrderKeyPolicy=ident-only`.
- Multiple diagnostics (e.g. illegal ORDER key plus unordered pagination) => primary chosen per precedence; secondary appear in `additional_statuses` (UA002 policy).

## Versioning

This document describes protocol draft for Geode v0.15.0+ (post PROFILE staging change). Wire stability: additive until v0.20.0; removals / incompatible renames require a major bump.

### Change Log (recent)

- Added staged PROFILE emission (SCHEMA then PROFILE on first PULL; no BINDINGS in PROFILE mode).
- Added aggregation ops (`AggregateBuild`, `AggregateEmit`).
- Added UNION phase ops & flag `U:UnionPhaseTimings`.
- Switched timing field name from `time_ms` draft -> `time_ns` implementation.
