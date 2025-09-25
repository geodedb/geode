# Binary Protocol — GQL Outcome & Diagnostics Mapping (v0.16.0)

## Messages

- `HELLO` — client greeting (name, version, wanted conformance).
- `BEGIN` / `COMMIT` / `ROLLBACK` — transaction demarcation.
- `RUN_GQL` — submit a GQL program (single statement supported currently) plus params.
- `PULL` — request next page of current result binding table.

**v0.16.0 Transport**: All messages now transmitted over QUIC+TLS. TCP support removed. Frame format remains unchanged but benefits from QUIC stream multiplexing and 0-RTT resumption.

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

Additive JSON payload describing per-operator performance & memory. Clients SHOULD treat unknown keys as ignorable. Stable core fields marked (S). Everything else is additive and may evolve without a breaking version bump (unless explicitly labeled breaking in release notes).

- `ops`: array of operator metric objects (S). Each object currently includes:

  - `op` (S): name — e.g. `NodeScan`, `Expand`, `Project`, `Distinct`, `Sort`, `Offset`, `Limit`, `AggregateBuild`, `AggregateEmit`, `UnionLeft`, `UnionTails`, `UnionDedup`
  - `phase`: coarse phase bucket (`SCAN`,`EXPAND`,`PROJECT`,`DISTINCT`,`ORDER`,`PAGE`,`AGGREGATE`,`OTHER`)
  - `id` / `op_index` (S): monotonic index (both present for v1; `id` is canonical going forward)
  - `input_rows` (S): logical rows consumed
  - `rows` (S): logical rows produced
  - `time_ns` (S): wall clock duration for the op
  - `cpu_time_ns`: CPU approximation (prototype = same as `time_ns` until multi-threading lands)
  - `bytes_out`: approximate payload bytes produced (JSON row bytes heuristic)
  - `bytes_alloc`: attributed allocated bytes (heuristic; will shift to counting allocator)
  - `estimate_bytes`: planner estimate (0 when estimates disabled)
  - `estimate_vs_actual`: `(actual/estimate * 100)` when estimate available
  - `percent_peak`: share of peak bytes attributable to this op
  - `percent_net`: share of net bytes at measurement point
  - `cumulative_time_ns`: running total time up to and including this op
  - `freed_bytes`: bytes released since prior op (captured via synthetic allocations + allocator net deltas)
  - `net_after_op`: allocator net bytes after this op
  - `error_bytes`: absolute difference between estimate and actual (if estimated)
  - `error_abs_pct`: `(error_bytes/estimate_bytes * 100)` when estimate > 0

- `peak_contributors`: top (≤3) ops by `bytes_alloc` with `{ op, bytes_alloc }`.
- `totals`: { `time_ns`, `peak_bytes` } (S)
- `total_time_ns`: legacy duplicate of `totals.time_ns` (may be deprecated later)
- `spills`: { `sort_spills`, `distinct_spills`, `union_spills` } — counters for forced or threshold spills
- `spill_reason`: one of `forced` | `threshold` (present only if any spill counter > 0)
- `peak_bytes_at_spill`: peak bytes at time of first spill (if any)
- `first_spill_op_index`: op index where first spill triggered (may omit if indeterminate)
- `mem_curve`: optional array of `{ op_index, net_after_op }` points when memory curve profiling enabled
- `memory`: { `net_bytes`, `peak_bytes`, `total_alloc_bytes` } (S)
- `planner_estimates`: summary statistics when estimates enabled:
  - `sum_estimate_bytes`, `sum_actual_bytes`, `count_estimated_ops`
  - `min_error_abs_pct`, `max_error_abs_pct`, `mean_error_abs_pct`, `median_error_abs_pct`, `stddev_error_abs_pct`
  - `adjusted_estimate_factor`: factor to scale future estimates (prototype calibration)

Flags remain on the outer frame (`flagger_findings`). Typical flags: `I:IllegalOrderKeyPolicy=ident-only`, `U:NullsFirstPolicy`, `U:OrderTiebreak=LexJSON`, `U:DistinctOutputUnordered`, `U:UnionPhaseTimings`.

### Notes

- Timing is nanosecond resolution (`time_ns`). Earlier drafts referenced `time_ms`; documentation updated to match implementation.
- Aggregation PROFILE emits no detail rows — only operator metrics.
- Flag `U:UnionPhaseTimings` may appear when UNION phase timings are present.

Planned additions (not yet present): per-op `input_rows`, memory metrics, allocation counters.

## Raft Replication & Cluster Control Framing (Internal over QUIC)

CANARY: REQ=REQ-GQL-074; FEATURE="RaftFrame/TransportEnvelope"; ASPECT=NetworkTransport; STATUS=IMPLEMENTED; TEST=TestRaftFrameEncodeDecodeRoundTrip; OWNER=cluster; UPDATED=2025-09-23

While the client/server binary protocol above governs GQL interactions, intra-cluster consensus traffic (Raft) uses a lightweight newline‑delimited JSON envelope (one frame per line) over a QUIC bidirectional stream. This keeps the transport simple (no length prefix — QUIC records ensure ordering and reliability) and debuggable with plaintext inspection.

RaftFrame JSON schema (prototype v0.15.x):

```json
{
  "term": 12,
  "from": "node-a",
  "kind": "append_entries",
  "payload": {
    /* kind-specific object (currently minimal) */
  }
}
```

Fields (updated after entries & snapshot support):

- `term` (u64) — Raft term.
- `from` (string) — sender node id (stable cluster identity string).
- `kind` (enum string) — one of `request_vote`, `append_entries`, `append_resp`, `install_snapshot`, `install_snapshot_resp` (additional kinds like `snapshot_chunk` reserved).
- `payload` (object) — shape depends on `kind`:
  - `append_entries`: includes `term,leader_id,prev_log_index,prev_log_term,leader_commit,entries[]` where each entry is `{term,index,cmd}` (command kind tag only; payload elided in prototype).
  - `install_snapshot`: includes `term,leader_id,last_included_index,last_included_term,offset,done` (empty `data` slice in prototype; chunking TBD).
  - `request_vote` / `request_vote_response` / `append_entries_response`: unchanged minimal fields.

Framing Rules:

- Each serialized frame ends with a single `\n` (LF). Readers call `readLine` with an upper bound (currently 256 KiB) to obtain the full JSON text.
- Oversized lines => stream error + connection close (future explicit diagnostic code).
- Unknown `kind` ⇒ ignored (logged at DEBUG) to preserve forward compatibility.

Rationale:

- Simplicity: Avoid bespoke varint length prefix while leveraging QUIC's segmentation.
- Human readability for initial bring‑up & wireshark/plaintext debugging.
- Forward compatible: additive fields ignored by existing decoders.

Limitations / TODO:

- `entries` omit full command payloads (write data, mutations) and checksums; to be added with size guards.
- Snapshot `data` omitted (will become chunked binary or base64 with checksum & size guard).
- `snapshot_chunk` not yet emitted.

CANARY: REQ=REQ-GQL-074; FEATURE="RaftFrameEntriesArray"; ASPECT=NetworkTransport; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_RaftFrameEntries; OWNER=cluster; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-074; FEATURE="RaftFrameSnapshotInstall"; ASPECT=NetworkTransport; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_RaftFrameSnapshotInstall; OWNER=cluster; UPDATED=2025-09-23

## Federated Query Result Line Protocol (Prototype)

CANARY: REQ=REQ-GQL-052; FEATURE="FederationResultLine"; ASPECT=Federation; STATUS=IMPLEMENTED; TEST=TestFederationParseResultsLineBasic; OWNER=federation; UPDATED=2025-09-23

Early federation support introduces a single‑line (newline‑delimited JSON) response per remote sub‑query execution. This is distinct from the client/server `BINDINGS` paging: federation currently performs gather/merge at a coordinator after receiving one JSON object per remote shard or remote database.

Result JSON schema (current minimal form):

```json
{
  "rows": [{ "col": 1 }],
  "schema": [{ "name": "col", "type": "INT" }],
  "exec_ms": 0.42
}
```

Fields:

- `rows` — array of binding objects (unordered unless the sub‑plan enforces ordering; ordering metadata forthcoming).
- `schema` — array describing columns (`name`, `type`). Can be empty when remote side elides schema (coordinator may reconcile from plan or first non‑empty contributor).
- `exec_ms` — execution latency observed at remote node (floating seconds or ms? (IMPLEMENTATION: floating milliseconds) — will standardize to integer microseconds in later revision; Flagger will announce the unit change).

Coordinator Behavior (current):

- Parses each line, validates JSON shape, appends into intermediate lists.
- Merging logic presently stubbed — final result uses first non‑empty schema; row concatenation without dedup or re‑ordering.
- Future: stable ordered merge (when all contributors flagged ordered), set op reconciliation, error propagation with per‑remote diagnostics.

Safety / Limits:

- Per‑line size guard (512 KiB). Exceeding guard => connection closed.
- Unknown fields ignored (forward compatibility).

Ordering Merge:

- Ordered k-way merge implemented when all contributors set `ordered:true` and share identical `order_keys` sequence (and now optional `order_dirs` direction flags). Implementation (v0.15.x) performs a multi-key, direction-aware (ASC/DESC per key) stable global merge using a binary min-heap O(N log k); tie-breaking proceeds to later keys then implicit row source order (deterministic). Missing: mixed collations, NULLS FIRST/LAST override flags (future). Metadata (`ordered`, `order_keys`, `order_dirs`) preserved.
- Fallback: If any contributor mismatches on `order_keys` length/content OR (when present) `order_dirs` sequence, coordinator downgrades to unordered concatenation (`union_all` strategy); returned `ordered` flag is `false` and ordering metadata is not propagated (test: direction mismatch fallback).
- Flag Emission: Direction or key mismatch fallback emits usage flag `U:FederationOrderMismatch` (single-frame consumption via `federation_flag` module; emitted exactly once per affected result stream).
  Nulls Ordering: Federated ordering now carries a uniform `nulls_first` boolean (default true). Comparator respects this across all order keys (future per-key policy). Tests: FederationNullsOrdering (NULLS FIRST and NULLS LAST). Implementation-defined default surfaced via existing collation/null policy flags; future explicit query clause `NULLS FIRST/LAST` will set this field. Variance envelope benchmark added (FederationNullMergeVarianceEnvelope) guarding high NULL density performance.

Remaining Enhancements:

- Pagination support for large remote result sets.
- Error frame lines carrying `status_class` + `additional_statuses` for partial failures.
- Binary row encoding option behind capability negotiation.

NOTE: Federation protocol is internal/experimental; external stability not guaranteed until v0.17+.

Memory Lifecycle: `QueryResults.deinit` releases duplicated `order_keys` strings to avoid allocator growth in high fan‑out queries.

CANARY: REQ=REQ-GQL-052; FEATURE="FederationResultLineMemoryLifecycle"; ASPECT=Federation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_052_FederationResultLineDeinit; OWNER=federation; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-052; FEATURE="FederationOrderedMerge"; ASPECT=Federation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_052_FederationOrderedMerge; OWNER=federation; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-052; FEATURE="FederationOrderedMultiKeyMerge"; ASPECT=Federation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_052_FederationOrderedMultiKeyMerge; OWNER=federation; UPDATED=2025-09-23
CANARY: REQ=REQ-GQL-052; FEATURE="FederationOrderedMultiKeyDirMerge"; ASPECT=Federation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_052_FederationOrderedMultiKeyDirMerge; OWNER=federation; UPDATED=2025-09-23

## Diagnostics Examples

- Unordered pagination (`LIMIT/OFFSET` without `ORDER BY`) ⇒ primary `US001` (anchor 16.18–16.19) with flag `U:US001/enforced`.
- Illegal ORDER key (function call) ⇒ `IllegalOrderKey` (anchor 14.10) + flag `I:IllegalOrderKeyPolicy=ident-only`.
- Multiple diagnostics (e.g. illegal ORDER key plus unordered pagination) => primary chosen per precedence; secondary appear in `additional_statuses` (UA002 policy).

Note: Optional server-side paging telemetry logs to `stderr` and does not affect wire frames; see `docs/TELEMETRY.md`.

## Versioning

This document describes protocol draft for Geode v0.15.0+ (post PROFILE staging change). Wire stability: additive until v0.20.0; removals / incompatible renames require a major bump.

### Change Log (recent)

- Added staged PROFILE emission (SCHEMA then PROFILE on first PULL; no BINDINGS in PROFILE mode).
- Added aggregation ops (`AggregateBuild`, `AggregateEmit`).
- Added UNION phase ops & flag `U:UnionPhaseTimings`.
- Switched timing field name from `time_ms` draft -> `time_ns` implementation.
- Expanded PROFILE op metrics (input_rows, bytes_out/alloc, estimates, error metrics, memory attribution, peak_contributors, mem_curve, planner_estimates, spills metadata).
