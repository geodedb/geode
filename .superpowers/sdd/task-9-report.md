# Task 9 Report: Full validation sweep

## Status: DONE — no genuine regressions found from Tasks 1-8; no fixes needed; no commits made

Scope: validate tasks 1-8 (FTS row-visibility authorization, knn metric-mismatch
validation, `geode.fts.rebuild`, bulk-MERGE FTS maintenance, per-request
read-only floor, MCP read-only mode, SHOW CAPABILITIES discovery, and the RAG
orchestrator prompt/guide) did not break anything, then run the full local +
harness gate honestly.

Repo state at start: `main` @ `d2b19c52` (14 commits ahead of `origin/main`,
tasks 1-8 already committed and reviewed per `.superpowers/sdd/progress.md`).
Environment: `GEODE_MASTER_KEY` set to the documented 32-byte test value where
required; Zig 0.16.0.

---

## Step 1 — `make fmt`

| Command | Result |
|---|---|
| `make fmt` | ran `zig fmt src/`, `zig fmt tests/`, `zig fmt build.zig` — no reformatting needed |
| `git status --short` after | only pre-existing untracked `.glab-ci-autoheal/` scratch dir — **no residual diff** |

**PASS.**

---

## Step 2 — Targeted steps (run serially, `GEODE_MASTER_KEY` set)

| # | Step | rc | Result |
|---|---|---|---|
| 1 | `test-fts-authorization` | 0 | PASS |
| 2 | `test-knn-metric-mismatch` | 0 | PASS |
| 3 | `test-fts-rebuild` | 0 | PASS |
| 4 | `test-fts-bulk-merge-maintenance` | 0 | PASS |
| 5 | `test-read-only-execute` | 0 | PASS |
| 6 | `test-mcp-read-only` | 0 | PASS |
| 7 | `test-show-capabilities` | 0 | PASS |
| 8 | `test-fts-e2e` | 0 | PASS |
| 9 | `test-using-vector-index` | 0 | PASS |
| 10 | `test-knn-scan-race` | 0 | PASS |
| 11 | `test-transport-parity` | 0 | PASS |
| 12 | `test-grpc-raw-io` | 0 | PASS |
| 13 | `test-gap0516` | 0 | PASS |
| 14 | `test-auth-rate-limiter` | 0 | PASS |
| 15 | `test-scan-ingest-race` | 0 | PASS |
| 16 | `test-cluster-replicable-mutations` | 0 | PASS (300s timeout raised to 320s per the "long steps, be patient" rule; completed cleanly with **no output**, which is normal silent-pass `zig build test` behavior) |

All 16 step names were verified verbatim against `build.zig` (`grep -n "\"<name>\"" build.zig`) before running — no renames needed.

**Note on `test-cluster-replicable-mutations`:** `docs/KNOWN_TEST_ISSUES.md` (dated
2026-06-10) documents this step as an *intentionally-red* TDD reproduction
that times out at 300s by design (cluster write-replication gaps: edge
CREATE, DELETE/DETACH DELETE, MERGE, ungated MATCH…SET didn't replicate).
In this run it **passed** within 320s. This is not a regression — it is
either host-speed variance or replication work that landed on `main` between
the 2026-06-10 baseline and the current commit (`d2b19c52`, 14 commits ahead
of `origin/main`). Out of scope for Task 9 to investigate further (not part
of tasks 1-8's change surface); flagged here for whoever refreshes
`KNOWN_TEST_ISSUES.md` next.

**Step 2: ALL 16/16 PASS.**

---

## Step 3 — Full suite, sharded (`CI=1 GEODE_SKIP_SUBPROC_CLUSTER=1 zig build test -Dtest-shard-total=4 -Dtest-shard-index=N`)

| Shard | rc | "failed command" tree-node count | Notes |
|---|---|---|---|
| 0 | 0 | 15 | self-skipping subprocess-cluster / protobuf-union-gated tests (documented pattern) |
| 1 | 0 | 22 | same pattern |
| 2 | 0 | 24 | same pattern |
| 3 | 0 | 11 | same pattern |

Each shard's outer `zig build` process exited 0 (captured explicitly via
`echo "shardN rc=$?"` appended to each log, not inferred from the Bash-tool
wrapper's own exit code). The "failed command: .../test --listen=-" lines in
each log are the zig-internal IPC tree-renderer noting sub-binary exits — this
is the exact same pattern `docs/KNOWN_TEST_ISSUES.md` describes for the
sharded gate (opted-out subprocess-cluster tests + protobuf-union-gated 2PC
self-skips), and none of them dragged down the aggregate `test` step's exit
code. No `error:` lines, no assertion failures, no "Build Summary: N/M failed"
in any shard log.

Given the monolithic `zig build test` protobuf union-submessage limitation
noted in CLAUDE.md, the **sharded** invocation was used exactly as directed
by the task brief (not the un-sharded aggregate) — this is the documented
canonical pre-push gate, distinct from the blocked monolithic path.

Known flakes named in the brief (`test_edge_popular_parent_throughput`,
`test_match_set_label_scan_regression`, `test_where_scan_writer_progress`)
did not surface as failures in any shard, so no serial re-verification was
required. `test-gap0866` and `test-quic-condition-cadence` are pre-broken
per the brief; the sharded run does not isolate individual named `test-*`
steps so their pre-broken status could not directly regress this gate (they
are absent from the shard tree entirely under the sharded runner, consistent
with the documented "opted-out" pattern).

**Step 3: ALL 4/4 SHARDS PASS (rc=0).**

---

## Step 4 — Harness specs

Built the production binary first: `zig build` → rc=0,
`zig-out/bin/geode` (273 MB) produced cleanly.

`SPEC=` must be the bare filename (`geodetestlab-cli/specs/` is prepended by
the Makefile's `test-spec` target) — corrected after an initial invocation
error.

| Spec | rc | Server started? | Result |
|---|---|---|---|
| `knn_metric_mismatch.yml` | 0 | yes ("Server ready on port 56198") | PASS 8/8 |
| `fts_bulk_merge_visibility.yml` | 0 | yes (port 13000) | PASS 21/21 |
| `read_only_execute.yml` | 0 | yes (port 59588) | PASS 7/7 |
| `show_capabilities_discovery.yml` | 0 | yes (port 28221) | PASS 4/4 |
| `fts_storage_basic.yml` | 0 | yes (port 11249) | PASS 13/13 |
| `fulltext_search_basic.yml` | 0 | yes (port 49209) | PASS 4/4 |
| `vector_index_errors.yml` | 0 | yes (port 47118) | PASS 18/18 |
| `vector_hnsw_comprehensive.yml` | 0 | yes (port 45845) | PASS 24/24 |
| `authn_rate_limiter.yml` | 0 | yes (port 57122) | PASS 16/16 |

Every log was checked for the literal `Server ready on port ...` line to
confirm the managed server actually started (not a false-green from the
runner) — present in all 9 runs, each on a distinct port.

**Step 4: ALL 9/9 SPECS PASS (135/135 individual spec assertions).**

---

## Step 5 — `make pre-commit`

Result: `rc=2` (as expected — some hooks are known-red).

| Hook | Result | Expected red? |
|---|---|---|
| `markdownlint` | **Failed** — pre-existing `MD025` (multiple H1s) in `docs/ENTERPRISE_GAPS.md`, `MD029` (ordered-list prefix) in `docs/bugs/2026-06-10-...md` | Yes (brief's 4th known-red) |
| `hadolint-docker` (Lint Dockerfiles) | **Failed** — pre-existing `DL3066`/`DL3025` info/warning across all repo Dockerfiles | Yes |
| `goreleaser check` | **Failed** — pre-existing deprecated-property warnings in `.goreleaser.yaml` (`dockers`→`dockers_v2`, `brews` deprecated) | Yes |
| `detect-diamond-deps` | **Failed** — pre-existing diamond deps in `build.zig.zon` (`fips`, `protobuf`, `quic`, `thread_pool`, `uuid` each have 2-3 version hashes among transitive deps) | Yes |
| Everything else (`zig fmt` check, governance checks, `.gitlab-ci.yml` lints, CANARY marker lint, `status.csv` sync, CANARY golden tests, Pretty format YAML, etc.) | **Passed** | — |

Exactly the 4 documented known-red hooks were red; nothing else.

**Side effect noted and reverted:** the `markdownlint` hook auto-fixed
`docs/ENTERPRISE_GAPS.md` in place (inserted blank lines after `##` headings)
before failing on the un-fixable `MD025` issues. This is pre-existing doc
formatting unrelated to tasks 1-8 and outside this task's fix authority, so
it was reverted (`git checkout -- docs/ENTERPRISE_GAPS.md`) to keep the tree
clean rather than left as a stray uncommitted diff.

**Step 5: PASS (matches the documented 4-known-red baseline exactly).**

---

## Step 6 — `git status` in both repos

### geode (this repo)

```
On branch main
Your branch is ahead of 'origin/main' by 14 commits.
Untracked files:
 .glab-ci-autoheal/
```

No tracked-file diff. `.glab-ci-autoheal/` is a pre-existing untracked
scratch dir (present before this task started) — acceptable per the brief.

### ../geode-test-harness

```
On branch main
Your branch is ahead of 'origin/main' by 5 commits.
Untracked files:
 reports_baseline/
 reports_clean/
 reports_m31/
 reports_p2/
 reports_v038/
 runners/rust_runner/Cargo.lock
```

No tracked-file diff. `reports_*/` are per-run harness report scratch dirs
(some pre-existing, some generated by this task's `make test-spec` runs);
`runners/rust_runner/Cargo.lock` is a pre-existing untracked lockfile. All
acceptable scratch per the brief.

**Step 6: CLEAN in both repos** (no push performed — orchestrator's job).

---

## Fixes / commits made

**None.** No genuine regression from tasks 1-8 was found anywhere in the
gate. The only in-flight repo mutation (`markdownlint`'s auto-fix of
`docs/ENTERPRISE_GAPS.md` in Step 5) was reverted rather than committed,
since it was pre-existing formatting debt outside this task's authorized
fix scope (trivial test-expectation fixes caused by tasks 1-8's new
behavior), not something tasks 1-8 touched.

---

## Summary

| Gate | Result |
|---|---|
| 1. `make fmt` | PASS — no residual diff |
| 2. 16 targeted steps | 16/16 PASS |
| 3. 4 sharded `zig build test` shards | 4/4 PASS (rc=0 each) |
| 4. 9 harness specs | 9/9 PASS (135/135 assertions), server confirmed started each run |
| 5. `make pre-commit` | Only the 4 documented known-red hooks red; everything else green |
| 6. `git status` both repos | Clean (only acceptable untracked scratch) |

**Overall: DONE.** Tasks 1-8's changes (FTS authorization, knn metric-mismatch
guard, `geode.fts.rebuild`, bulk-MERGE FTS live maintenance, per-request
read-only floor, MCP read-only mode, SHOW CAPABILITIES discovery, RAG
orchestrator docs) introduce no regressions against the full local gate or
the harness integration specs. No code changes were required or made.

## Final-review fix wave

A separate whole-branch review of the same 9-task series (Tasks 1-8) surfaced
four findings after this report's original validation sweep. Fixed here,
one commit per finding, TDD where behavior changed.

### Finding 1 (CRITICAL): read-only floor bypass via MATCH…CALL and CALL{} subquery

**What changed.** `src/query/query_traits.zig`'s `isQueryMutating` checked
`create_pattern`/`merge_statement`/`set_clauses`/`remove_clauses`/
`delete_items` but never `q.call_clause` (`MATCH (n) CALL <procedure>`) or
`q.initial_call_subquery` (`CALL { ... } WITH ... RETURN ...`). A mutating
procedure invoked through either shape — e.g. `MATCH (n) CALL
geode.fts.rebuild('idx')` or `CALL { MATCH (n) SET n.k=1 RETURN n } WITH n
RETURN n` — classified as non-mutating, bypassing the
`ExecuteRequest.read_only` 42501 floor (`quic_connection_handler.zig`,
`grpc_server.zig`), the MCP read-only gate (both consume
`isMutatingProgram` transitively), the GPS role gate, and write-lock
selection (same classifier, pre-existing hole this fix also closes).

**Design choice / import structure.** `q.call_clause` is now classified via
`procedure_access.classifyCallProcedure` — the SAME single source of truth
already used by `isMutatingCallStatement` for standalone `CALL` statements.
No import-cycle workaround or classifier duplication was needed:
`query_traits.zig` already imports `procedure_access`, and `CallClause`
(the `MATCH...CALL` AST node) and `CallProcedure` (the standalone-`CALL`
AST node) share the exact `procedure`/`yield_items` shape the classifier
inspects — a zero-cost adapter struct literal bridges the two. An
unresolved/unlisted procedure name defaults to `.mutating` inside
`classifyCallProcedure` itself (fail closed), so no extra fail-closed
handling was needed at the call site. `q.initial_call_subquery` recurses
into `isQueryMutating` on the inner `*Query`, reusing the existing
per-clause classification (the parser stores the `CALL { ... }` body as a
full `ast.Query`, so recursion is exact, not approximate).

**RED (before fix, `zig build test-read-only-execute`):**

```
error: 'test.read-only classification refuses MATCH...CALL with a mutating procedure' failed
error: 'test.read-only classification refuses MATCH...CALL geode.fts.rebuild' failed
error: 'test.read-only classification refuses CALL{}...SET inline subquery' failed
Build Summary: 4/7 tests passed (3 failed)
```

`zig build test-mcp-read-only` RED: `test.read-only MCP refuses
MATCH...CALL geode.fts.rebuild before the wire` failed (4/5 passed).

**GREEN (after fix):** `zig build test-read-only-execute test-mcp-read-only`
— all pass, including the new read-only-wrapped-CALL-procedure-still-allowed
canary (`MATCH (n:Doc) CALL geode.fts.search(...)`) confirming no
over-blocking.

**Commands + results:**

- `zig build test-read-only-execute test-mcp-read-only test-transport-parity
  test-merge-query-is-mutating test-fts-rebuild test-gap0516` — all green.
- Harness canaries: `fts_storage_basic.yml` 13/13 PASS,
  `read_only_execute.yml` 7/7 PASS.

**Commit:** `3cbeeac7` — `fix(security): classify MATCH...CALL and CALL{}
subqueries in read-only floor`

### Finding 2 (IMPORTANT): unlocked property borrow in bulk-MERGE FTS maintenance

**What changed.** `quic_connection_handler.zig:1316`/`:1532`
(`executeBulkSimpleMerge` / `executeBulkMergeBatch`) call
`maintainFulltextOnWrite` AFTER releasing the graph lock. Inside it,
`indexNodeDocument` (`fts_index_ops.zig`) read node property text via
`store.getNodeProperty`, whose returned `String` borrows the node's live
property storage and is valid only while a lock excludes a concurrent
SET/DELETE for the read's duration (documented contract in
`graph_store.zig`). With no lock held at these two call sites, a concurrent
SET/DELETE from another connection racing the same node could
realloc/free the property mid-read — a UAF (ENG-3954 class).

**Design choice.** Fixed at `indexNodeDocument`, the single call site all 5
`maintainFulltextOnWrite` callers funnel through (CREATE batch fast path,
the SET chokepoint, DELETE, raft-apply/snapshot-install, and the two
bulk-MERGE sites) — benefits every caller with one change instead of
patching two call sites. It now takes `store.nodes.lockShardShared(node_id)`,
reads via `getPtrUnlocked`, and COPIES each indexable property's raw text
(`allocator.dupe`) before releasing the lock; tokenizing and calling into
the fts engine happen afterward on the owned copies — same
`lockShardShared` + `getPtrUnlocked` pattern already used by
`fts_dispatch.filterAuthorizedHits` and `eval.scanVectorKnn` (ENG-3954/#874).
Deliberately does **NOT** call `store.getNodeProperty` while holding the
shard lock: that function internally re-acquires the same shard's
`map_lock` via `getOrHydratePtr`, and `node_cache.zig`'s `lockShardShared`
doc explicitly forbids nesting ("no re-entrant cache calls while held").
Verified no other `maintainFulltextOnWrite` caller holds this shard lock at
its own call site, so adding it inside `indexNodeDocument` cannot
double-lock or deadlock any existing caller — no ordering change against
CLAUDE.md's tier-1 lock table.

**Documented residual.** The fix bypasses FLE decryption (the raw
shard-locked copy is not run through `store.getNodeProperty`'s decrypt
path — replicating that safely would require carrying RBAC/role context
this late in a write-committed maintenance hook, and FLE+FTS indexing has
no existing test coverage). Behavior is byte-for-byte identical to before
whenever no FLE fields are configured (`fle_integration.hasEncryptedFields()
== false`, the default/tested posture). When FLE IS configured, an indexed
field now stores its ciphertext envelope instead of decrypted plaintext —
narrower exposure than before, not wider.

**Testing.** A true UAF race is timing-dependent and not feasible to pin
deterministically without invasive fault-injection hooks this module
doesn't have — per the review's own guidance, relied on the lock-discipline
reasoning above plus the existing race suites, all green after the fix:
`zig build test-scan-ingest-race test-bulk-shard-concurrency
test-fts-bulk-merge-maintenance test-fts-e2e` (exit 0, no failures).

**Commit:** `813d2592` — `fix(fts): copy property text under shard lock in
bulk-MERGE FTS maintenance`

### Finding 3 (IMPORTANT): status.csv cites gitignored .superpowers briefs + stale header comment

**What changed.** `tools/status_generate.py`'s `os.walk` skip list excluded
`.git`/`vendor`/`zig-cache`/worktrees/`zig-out`/`docs/superpowers/plans` but
not `.superpowers/` itself — an entirely gitignored, per-session scratch
directory whose task briefs (`.superpowers/sdd/task-*-brief.md`) sometimes
carry CANARY markers copy-pasted from source for planning purposes. Those
aren't real requirement evidence and don't ship, so `docs/status.csv` was
not reproducible from tracked source: a machine with an active
`.superpowers/` session produced 8 extra rows a clean clone or CI checkout
would never see. Added `"/.superpowers" in root` to the skip list,
mirroring the existing `/docs/superpowers/plans` exclusion, and regenerated
`docs/status.csv` — the diff removes exactly the 8 brief-sourced rows
(`REQ-FTS-ROW-VISIBILITY-001` ×2, `REQ-VECTOR-KNN-METRIC-VALIDATE-001`,
`REQ-FTS-REBUILD-001`, `REQ-FTS-BULK-MERGE-LIVE-001`,
`REQ-EXEC-READ-ONLY-REQUEST-001` ×2, `REQ-MCP-READ-ONLY-001`); every
legitimate source-file row is preserved.

Same commit: fixed the stale header comment in
`tests/test_cluster_replicable_mutations.zig:824-836` ("At HEAD each of
these surfaces is completely ungated ... red run") — this has been the
green fail-closed pin since the 2026-06-10 fix landed
(`docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md`).
Rewrote it to describe current reality and point at CLAUDE.md's
"Cluster-mode fail-closed surfaces" section for the up-to-date gated-surface
list.

**Verification.** `make status-generate-test` (28/28 golden tests) and
`zig build test-cluster-replicable-mutations` (7/7, including "unreplicated
write surfaces fail closed") both green.

**Commit:** `2bddce30` — `chore(status): exclude .superpowers/ from CANARY
status generation`

### Finding 4 (MINOR): graph-scope caveat for `CALL geode.fts.*`

Added a one-sentence caveat to both `docs/rag/RAG_INTEGRATION_GUIDE.md` §8
(FTS operational notes) and `docs/FULLTEXT_SEARCH.md` (Live Maintenance
section): `CALL geode.fts.*` operates on the default graph — a node
bulk-MERGE'd into a non-default graph is maintained into that graph's own
index, which the procedures cannot currently query. Verified against
`src/execution/fts_dispatch.zig`, which resolves every `geode.fts.*`
procedure via `graph_store.DEFAULT_GRAPH_NAME` unconditionally.

**Commit:** (this report append, folded into the same commit as the docs
change — see repo log)

## Fix: next_query recursion

A follow-up review of Finding 1 (chained-WITH sibling) found that
`isQueryMutating` still did not recurse into `q.next_query`
(`src/query/query_traits.zig` ~:443-467, `ast.zig:114`), the pointer the
parser populates for chained-WITH shapes
(`src/gql/parser.zig` ~:1772-1792/2289/2338/4558, e.g.
`MATCH ... WITH ... MATCH ... SET/CALL/CREATE ...`). A tail query carrying
`set_clauses` or a mutating `call_clause` left the whole statement
classified non-mutating — the same read-only-floor bypass class as
Finding 1, one chaining level deeper. `isStoreFreeQuery` (:387) and
`isPointReadQuery` (:501) already treated any non-null `next_query` as
disqualifying, so the fix mirrors their existing pattern.

**AST-structural precondition evidence.** Before trusting the mutation
assertion, a dedicated test parses
`"MATCH (n:X) WITH n MATCH (m:Y) SET m.k = 1"` with the real parser and
asserts directly on the AST: the head query's own `set_clauses.len == 0`,
`head_query.next_query != null`, and
`head_query.next_query.?.set_clauses.len > 0` — proving the mutating `SET`
genuinely lands on the tail query reachable only via `next_query`, not on
the head. This precondition test passed on the first run (no code change
needed to make the AST shape correct — only the classifier was missing the
recursion).

**RED (before fix, `zig build test-read-only-execute`):**

```
+- run test 9 pass, 1 fail (10 total)
error: 'test_read_only_execute.test.read-only classification refuses chained-WITH tail SET (next_query mutation)' failed:
       .../testing.zig:615:14: 0x12601d9 in expect (std.zig)
       tests/test_read_only_execute.zig:171:5: try testing.expect(query_traits.isMutatingProgram(&mutating[0]));
Build Summary: 34/36 steps succeeded (1 failed); 9/10 tests passed (1 failed)
```

The structural-precondition test itself passed even in this RED run,
confirming the AST shape was already correct and only the classifier logic
was the bug.

**Fix.** One `if (q.next_query) |next| { if (isQueryMutating(next)) return true; }`
block added to `isQueryMutating`, mirroring the existing
`initial_call_subquery` recursion immediately above it. Each recursion
level re-checks `call_clause`/`initial_call_subquery`/`next_query`, so
arbitrarily deep WITH chains are covered without additional code.

**GREEN:**

- `zig build test-read-only-execute` — 10/10 pass.
- `zig build test-mcp-read-only` — pass.
- `zig build test-transport-parity` — all 12 sub-tests `✓`, rc=0.
- `zig build test-merge-query-is-mutating` — pass.
- `zig build` (full binary build) — rc=0.

**Over-block canary (harness, managed server confirmed started via
"Server ready on port ..." in each log):**

- `geode-test-harness make test-spec SPEC=read_only_execute.yml` —
  7/7 PASS.
- `geode-test-harness make test-spec SPEC=fts_storage_basic.yml` —
  13/13 PASS.

Both confirm the fix does not over-block legitimate read-only chained-WITH
or FTS traffic.

**CANARY.** Updated the marker above `isQueryMutating`
(`src/query/query_traits.zig:431`) — FEATURE broadened to include
"chained-WITH mutation classification", UPDATED=2026-08-28 — and appended a
GAP note documenting the follow-up fix and its mirror relationship to
`isStoreFreeQuery`/`isPointReadQuery`. `docs/status.csv` regenerated via
`make status-generate` (1-line diff reflecting the updated FEATURE text for
REQ-ENG-3960-CALL-MUTATION-CLASSIFICATION).

**Commit:** `6159f95d` — `fix(security): recurse into next_query in the
read-only mutation classifier`
