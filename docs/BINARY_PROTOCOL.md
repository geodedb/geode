# Binary Protocol — GQL Outcome & Diagnostics Mapping

## Messages

- `HELLO` — client greeting (name, version, wanted conformance).
- `BEGIN` / `COMMIT` / `ROLLBACK` — transaction demarcation.
- `RUN_GQL` — submit a GQL program (single statement supported currently) plus params.
- `PULL` — request next page of current result binding table.

**Transport**: All messages transmitted over QUIC+TLS. TCP support removed. Frame format benefits from QUIC stream multiplexing and 0-RTT resumption.

## Status & Diagnostics

Each response frame includes:

- `status_class` (ISO/IEC 39075 codes, e.g. 00000 success, 02000 warning) — subclass future.
- Optional `additional_statuses` (UA002 precedence policy) when multiple diagnostics apply.
- Optional `flagger_findings` listing implementation-defined (I:_) and dependent (U:_) behaviors (e.g. `I:PropertyOrderingEnabled`, `U:NullsFirstPolicy`, `U:OrderTiebreak=LexJSON`).

## Result Frames

- `SCHEMA` — column descriptors `{name,type}` (always first for a new statement, including PROFILE mode).
  `type` describes every value the column holds in the result (SONNY-6562): the
  ISO/IEC 39075:2024 22.18 / 22.19 combination of the types of all its values.
  A decimal is `DECIMAL` (exact numeric, 21.2), an integer `INTEGER`, an
  approximate number `DOUBLE` / `REAL`; exact numerics combine to the wider one
  (`DECIMAL` over the integer types), any approximate value makes the column
  `DOUBLE`, character strings `STRING`, a zoned and a local datetime or time the
  zoned type, lists `LIST`; values of different base types make it `ANY` (18.9's
  open dynamic union type); NULL adds nothing, and a column of only NULLs is
  `NULL`. The node-scan stream (`MATCH (n:L) RETURN n.p` served without the
  executor) sends this frame after its first 10 rows: when those are all its
  rows it declares their combined type, as the executor would, and when more
  follow it declares each property column `ANY` (a bare node column `NODE`).
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
- `ordered` / `order_keys` propagate logical ordering guarantees; server does not reorder inside a page. `ordered` is true exactly when the statement that returns the rows ends in an ORDER BY (14.10; a UNION's trailing ORDER BY, 14.2), whatever its shape (a query, a chain's last part, FOR, `CALL ... RETURN`), and `order_keys` are that ORDER BY's keys; a WITH's ORDER BY earlier in a chain orders nothing in the result (SONNY-6562).

## Extended Frames

`EXPLAIN` / `PROFILE` carry a JSON payload under `result.json`. Format is additive; consumers must ignore unknown keys.

Current (v0.15.x) JSON fields:

### EXPLAIN

- `logical`: array of `{ op }`
- `properties`: may include `ordered`, `limit`, `offset`, `distinct`, `union_mode` ("DISTINCT" | "ALL")
- (flags emitted via outer `flagger_findings`)

### PROFILE

The `PROFILE` result is a `ProfilePayload` message (src/proto/geode.proto);
the CLI and the client library render it as the JSON object below
(`profile_payload.profilePayloadToJson`). Consumers must ignore unknown keys.
`profile_version` says which builder produced it:

- **Version 2** (`buildProfilePayloadFromTrace`): a query the planned read
  runtime runs (`planned_read_runtime.executeProfiledIfSupported`). Each op is
  an operator the runtime executed, with its measured wall-clock time and row
  counts.
- **Version 1** (`buildProfilePayload`): every other statement a PROFILE wraps
  (data changes, UNION and the other shapes the planned runtime declines). Its
  op list is derived from the statement's traits (`NodeScan`, `Expand`, then
  `AggregateBuild` / `AggregateEmit`, `Distinct`, `Sort`, `Project`, `Limit`,
  `UnionLeft` / `UnionTails` / `UnionDedup` / `SetOpUnion` as the statement
  has them) and its timings and byte counts are a deterministic synthetic
  model, not measurements (GAP-0874; docs/EXPLAIN_PROFILE.md).

Top-level keys, in the order sent:

- `profile_version`: 1 or 2.
- `ops`: one object per operator:
  - `op`: version 2: `ConstProjection`, `AllNodesScan`, `LabelScan`,
    `IndexSeek`, `ExpandOut`, `ExpandIn`, `ExpandEither`, `OptionalMatch`,
    `VarLengthExpand`, `ShortestPath`, `PathModeExpand`, `PathCapture`,
    `CallProcedure`, `CallSubquery`, `Create`, `Merge`, `Unwind`, `Set`,
    `Remove`, `Delete`, `RecursiveCTE`, `QueryChain`, `LegacyExecute`,
    `Filter`, `Aggregate`, `Project`, `Distinct`, `Limit`, `Sort`; version 1
    (a statement the legacy executor ran, which has no operator hooks):
    `LegacyExecute`, the statement, preceded by `NodeIndexScan` only for a
    catalog index the executor seeked (SONNY-1335). Until SONNY-6596 version
    1 listed a fixed set (`NodeScan`, `Expand`, `Project`, the `Union*`
    phases, ...) whatever ran.
  - `phase`: `SCAN`, `EXPAND`, `MATCH`, `PROJECT`, `CALL`, `WRITE`, `UNWIND`,
    `CTE`, `CHAIN`, `EXECUTE`, `FILTER`, `AGGREGATE`, `DISTINCT`, `ORDER`,
    `PAGE` or `OTHER`.
  - `id` (always 0), `op_index` (0-based position).
  - `input_rows`, `rows`: rows consumed and produced (version 1:
    `input_rows` 0, not counted; `rows` the statement's result rows, or the
    nodes the index seek returned).
  - `time_ns`, `cpu_time_ns`, `cumulative_time_ns`: version 2 measured
    (`cpu_time_ns` equals `time_ns`); version 1: `LegacyExecute`'s
    `time_ns` is the wall-clock time measured around the statement,
    `NodeIndexScan`'s 0 (part of the statement's), `cpu_time_ns` 0 (not
    measured).
  - `bytes_out`, `bytes_alloc`, `estimate_bytes`, `estimate_vs_actual`,
    `percent_peak`, `percent_net`, `freed_bytes`, `net_after_op`,
    `error_bytes`, `error_abs_pct`: all 0 (not measured) in both versions.
    With `GEODE_PROFILE_COMPACT` set, `estimate_bytes`, `estimate_vs_actual`,
    `percent_peak` and `percent_net` are omitted when 0.
  - `index_name`, `selectivity_est`: present only on an op that seeked a
    catalog index.
- `peak_contributors`: empty (no allocation is measured).
- `totals`: `{ time_ns, peak_bytes }`; `total_time_ns` repeats
  `totals.time_ns`.
- `spills`: `{ sort_spills, distinct_spills, union_spills }`, followed by
  `spill_reason`, `peak_bytes_at_spill` and `first_spill_op_index` only when
  a counter is above 0. The executor never spills a sort, DISTINCT, UNION or
  GROUP BY to disk, so every counter is 0 and `spill_reason` is absent in both
  versions; `GEODE_SPILL_THRESHOLD_BYTES` / `GEODE_QUERY_MEM_LIMIT_BYTES`
  change nothing (until SONNY-6562 version 1 reported a spill when its
  synthetic peak passed the threshold).
- `memory`: `{ net_bytes, peak_bytes, total_alloc_bytes }`, all 0 (not
  measured; version 1 reported a fixed model until SONNY-6596).
- `planner_estimates`: absent. No planner estimates byte counts (version 1
  reported invented ones until SONNY-6596).
- `mem_curve`: `[{ op_index, net_after_op }]`, version 1 with
  `GEODE_PROFILE_MEMCURVE` set (one point per op, `net_after_op` 0); absent
  when empty.
- `setop` (version 1, UNION only): `{ type: "UNION", mode, input_rows,
  output_rows }`: `output_rows` the rows returned, `input_rows` 0 (the
  parts' rows are not counted), plus `hash_dedup_size` (0) for
  `mode: "DISTINCT"`; `distinct_fill_pct` appears only when above 0, so
  never (both were derived from an invented input count until SONNY-6596).
- `hashagg_spills`: always 0 (`hashagg_spill_reason` only when it is not).
- `committed_txns`, `graph_store_nodes`, `graph_store_edges`,
  `graph_store_dirty`: server counters read when the PROFILE ran.
- `flagger_findings`: the statement's findings (also on the outer frame).

Flags remain on the outer frame (`flagger_findings`). Typical flags: `I:IllegalOrderKeyPolicy=ident-only`, `U:NullsFirstPolicy`, `U:OrderTiebreak=LexJSON`, `U:DistinctOutputUnordered` (`U:UnionPhaseTimings` is no longer sent: no
UNION phase is timed, SONNY-6596).

### Notes

- Timing is nanosecond resolution (`time_ns`).
- A PROFILE returns no detail rows, only the payload.

## Raft Replication & Cluster Control Framing (Internal over QUIC)

CANARY: REQ=REQ-GQL-074; FEATURE="RaftFrame/TransportEnvelope"; ASPECT=NetworkTransport; STATUS=TESTED; TEST=TestRaftFrameEncodeDecodeRoundTrip; OWNER=cluster; UPDATED=2025-09-23

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

CANARY: REQ=REQ-GQL-052; FEATURE="FederationResultLine"; ASPECT=Federation; STATUS=TESTED; TEST=TestFederationParseResultsLineBasic; OWNER=federation; UPDATED=2025-09-23

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
- Merging logic implemented: performs stable ordered merge when all contributors are ordered; falls back to unordered union if any contributor is unordered or order keys mismatch.
- Handles partial schema reconciliation (first non-empty schema used if others are empty).

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

- Unordered pagination (`LIMIT/OFFSET` without `ORDER BY`) is **NOT** a diagnostic: it succeeds with `status_class` 00000. ISO/IEC 39075:2024 leaves the ordering of an unordered result set implementation-defined, and Geode lists `UnorderedPaginationAllowed` among its implementation-defined items (`collectImplDefinedFlags` in `src/conformance.zig`; the server does not send that list to clients). The `US001` code is retained in `src/diagnostics.zig` for classification only and is never emitted; an opt-in strict mode (`ExecutionContext.strict_offset_validation`) exists as a seam but is not wired.
- Illegal ORDER key (function call) ⇒ status class `42000`, message `function calls in ORDER BY are disabled` (classified `IllegalOrderKey`, anchor 14.10) + flag `I:IllegalOrderKeyPolicy=ident-only`. This fires **only** under the opt-in ident-only policy (`GEODE_ORDER_KEYS_EXPR=0`); the default is the standards-correct expression form, which flags `I:PropertyOrderingEnabled` and accepts the query. Note the code name is an internal classification and is not part of the wire payload.
- Multiple diagnostics => primary chosen per precedence; secondary appear in `additional_statuses` (UA002 policy).

Note: Optional server-side paging telemetry logs to `stderr` and does not affect wire frames; see `docs/TELEMETRY.md`.

## Versioning

This document describes protocol draft for Geode (post PROFILE staging change). Wire stability: additive; removals / incompatible renames require a major bump.

### Change Log (recent)

- Added staged PROFILE emission (SCHEMA then PROFILE on first PULL; no BINDINGS in PROFILE mode).
- Added aggregation ops (`AggregateBuild`, `AggregateEmit`).
- Added UNION phase ops & flag `U:UnionPhaseTimings`.
- Switched timing field name from `time_ms` draft -> `time_ns` implementation.
- Expanded PROFILE op metrics (input_rows, bytes_out/alloc, estimates, error metrics, memory attribution, peak_contributors, mem_curve, planner_estimates, spills metadata).
