# Binary Protocol — GQL Outcome & Diagnostics Mapping

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

- `SCHEMA` — column descriptors `{name,type}`.
- `BINDINGS` — page of rows plus ordering + pagination metadata.
- `EXPLAIN` — logical operator array JSON.
- `PROFILE` — per-operator metrics JSON (early minimal form).

## Pagination Semantics

Row production currently materializes the full result, then serves slices on `PULL`. A `BINDINGS` frame:

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
  -- Interleaving multiple active result sets is not supported; a second `PULL` after `final:true` yields `NoResult`.
- `ordered` and `order_keys` propagate logical ordering guarantees; the server does not reorder within pages.

## Extended Frames

`EXPLAIN` / `PROFILE` carry a JSON payload under `result.json`. Format is versioned implicitly; fields may expand (add-only) — consumers should ignore unknown keys.

Current (v0.15.x) JSON fields (additive set):

EXPLAIN:

- logical: array of { op }
- properties: may include ordered, limit, offset, distinct, union_mode ("DISTINCT"|"ALL")
- flags: array of flagger findings (implementation / user policy)

PROFILE:

- ops: array of { op, rows, time_ms }
- setop (optional): { type: "UNION", mode: "DISTINCT"|"ALL", input_rows_left, input_rows_right, output_rows }
- flags: array of flagger findings

Planned additions (not yet present): per-op input_rows, hash_dedup_size (DISTINCT), allocs, memory_bytes.

## Diagnostics Examples

- Unordered pagination (`LIMIT/OFFSET` without `ORDER BY`) ⇒ primary `US001` (anchor 16.18–16.19) with flag `U:US001/enforced`.
- Illegal ORDER key (function call) ⇒ `IllegalOrderKey` (anchor 14.10) + flag `I:IllegalOrderKeyPolicy=ident-only`.

## Versioning

This document describes protocol draft for Geode v0.15.0; wire stability commitments: additive changes only until v0.20.0, after which field removals require a major.
