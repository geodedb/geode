# Task 9: Full validation sweep — Report

Date: 2026-08-29
Executed from: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode
Starting HEADs (matched expectation): geode a45866b2, harness 4003ea80, mcp 19fa8c20

## Status: DONE

All gate steps passed. No fixes were required — the entire series (Tasks 1-8) is validated
green end-to-end. One incidental revert was made (see Step 5 notes) to undo a known-red
hook's autofix side effect; this is not a code change and required no commit.

## Step 1 — `make fmt`

| Command | Result |
|---|---|
| `make fmt` | OK — ran `zig fmt src/`, `zig fmt tests/`, `zig fmt build.zig` |
| `git status --short` | Only pre-existing untracked `.glab-ci-autoheal/` — no residual diff |

**Result: PASS**

## Step 2 — Targeted steps (serial, one `zig build <step>` each)

Exact step-name resolution via `grep -n` in `build.zig` before running (two names differed from the brief's shorthand):

- `test-gap0509` → actual step name `test-gap0509-tenant-isolation` (build.zig:5978)
- `test-rls-expr-engine-wiring`, `test-gap0868`, `test-reopen-merge-hydration-dup` — brief's names were already exact, confirmed present
- All others matched the brief's names exactly

| Step | Result |
|---|---|
| test-profile-rls-tenant | PASS |
| test-fts-storage-adapter | PASS |
| test-fts-rebuild | PASS |
| test-fts-bulk-merge-maintenance | PASS |
| test-fts-e2e | PASS |
| test-fts-authorization | PASS |
| test-mcp-read-only | PASS |
| test-gap0516 | PASS |
| test-gap0875 | PASS |
| test-read-only-execute | PASS |
| test-rls-expr-engine-wiring | PASS |
| test-gap0509-tenant-isolation | PASS |
| test-gap0868 | PASS |
| test-scan-ingest-race | PASS |
| test-reopen-merge-hydration-dup | PASS |
| test-cluster-replicable-mutations | PASS |
| test-show-capabilities | PASS |
| test-transport-parity | PASS |

**Result: 18/18 PASS**

## Step 3 — Full suite (sharded)

`CI=1 GEODE_SKIP_SUBPROC_CLUSTER=1 timeout 1800 zig build test -Dtest-shard-total=4 -Dtest-shard-index=N`, run sequentially N=0..3.

| Shard | Exit code | Notes |
|---|---|---|
| 0 | 0 | PASS |
| 1 | 0 | PASS |
| 2 | 0 | PASS |
| 3 | 0 | PASS |

All four shards exited 0. Interleaved "failed command: .../test --cache-dir=... --seed=..." lines
appeared in every shard's output tail — these are the documented self-skipping
subprocess/protobuf tree-node noise pattern (child test binaries under `zig build test`'s
tree-runner reporting a non-fatal skip for subprocess/cluster-dependent sub-tests), not real
failures; judged by each shard's own exit code, which was 0 in all four cases.

Known flakes named in the brief (`test_edge_popular_parent_throughput`,
`test_match_set_label_scan_regression`, `test_where_scan_writer_progress`) did not flake this
run — no failures were observed anywhere in the sharded run, so no serial re-verification was
triggered. Known pre-broken (`test-gap0866`, `test-quic-condition-cadence`) were not
independently isolated since the full-suite run had zero failures to attribute to them; nothing
in the shard output flagged either as failing this run.

**Result: 4/4 shards PASS (exit 0)**

## Step 4 — Harness specs + pytest unit suite

Binary built first: `make build` → exit 0, `zig-out/bin/geode` (274MB) produced.

`GEODE_BINARY=<path-to-built-geode> make test-spec SPEC=<name>` run serially from
`../geode-test-harness`:

| Spec | Result | Managed server started? |
|---|---|---|
| fts_bulk_merge_visibility.yml | PASS | Yes — QUIC transport listening confirmed in log |
| fts_storage_basic.yml | PASS | Yes |
| fulltext_search_basic.yml | PASS | Yes |
| read_only_execute.yml | PASS | Yes |
| show_capabilities_discovery.yml | PASS | Yes |
| knn_metric_mismatch.yml | PASS | Yes |

Each run's log shows `{"component":"transport","transport":"quic","tls":"true",...,"status":"listening"}`
and `[startup] QUIC transport listening` — confirmed the managed geode server actually started
per spec run (6/6 distinct ports/PIDs, not reused).

**Result: 6/6 specs PASS**

Harness pytest unit suite: `make test-unit` (`geodetestlab-cli/geodetestlab/tests/`):

```
174 passed, 1 skipped, 7 warnings in 4.13s
EXIT: 0
```

**Result: PASS (174/175, 1 documented skip)**

## Step 5 — `make status-generate-test` and `make pre-commit`

`make status-generate-test`: exit 0. Ran 8 tests then 21 tests, both `OK`.

`make pre-commit`: exit 2 (make aggregates hook failures into a nonzero exit). Per-hook results:

| Hook | Result | Notes |
|---|---|---|
| trim trailing whitespace | Passed | |
| fix end of files | Passed | |
| mixed line ending | Passed | |
| check yaml / json / toml / xml | Passed | |
| detect private key | Passed | |
| check for added large files | Passed | |
| check for merge conflicts / case conflicts | Passed | |
| check for broken/destroyed symlinks | Passed | |
| shebang checks | Passed | |
| shellcheck | Passed | |
| ruff (legacy alias) / ruff format | Passed | |
| **markdownlint** | **Failed (known-red)** | MD029/MD025 violations in `docs/bugs/2026-06-10-...md` and `docs/ENTERPRISE_GAPS.md` (multiple top-level H1s) — the exact documented legacy-doc known-red |
| Pretty format YAML | Passed | |
| **Lint Dockerfiles (hadolint-docker)** | **Failed (known-red)** | DL3066/DL3025 info/warning-level findings across `Dockerfile*` variants — documented known-red |
| **goreleaser check** | **Failed (known-red)** | `.goreleaser.yaml` uses deprecated `dockers`/`docker_manifests`/`brews` keys — documented known-red |
| zig fmt (check) | Passed | |
| governance — no std.heap.page_allocator in production src/ | Passed | |
| build.zig.zon no local path deps | Passed | |
| build.zig.zon hash freshness | Passed | |
| build-options content collision guard | Passed | |
| .gitlab-ci.yml docker jobs require linux tag | Passed | |
| .gitlab-ci.yml docker container names valid | Passed | |
| glab ci lint (.gitlab-ci.yml schema) | Passed | |
| check for TODOs/FIXMEs | Passed | |
| CANARY marker lint | Passed | |
| status.csv sync check | Passed | |
| CANARY parser/generator golden tests | Passed | |
| **detect diamond deps in build.zig.zon** | **Failed (known-red)** | Pre-existing transitive-version diamonds on `fips`, `protobuf`, `quic`, `thread_pool`, `uuid` — documented known-red, unrelated to this series |

**Only the 4 documented known-red hooks were red** (markdownlint, hadolint, goreleaser,
detect-diamond-deps) — exact match to the brief's expected known-red set. No new/unexpected
failures.

**Note:** markdownlint's autofix pass modified `docs/ENTERPRISE_GAPS.md` in place (its
`files were modified by this hook` side effect, +31 lines) as a byproduct of running
`make pre-commit`. This was not part of the Task 1-8 series and was reverted
(`git checkout -- docs/ENTERPRISE_GAPS.md`) to keep `git status` clean per the Step 6
requirement — no commit was made since it was a no-op revert of pre-commit's own autofix
artifact, not a code change.

**Result: PASS (only documented known-red hooks red)**

## Step 6 — git status + commit lists (all three repos)

### geode (`/data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode`)

`git status --short`:

```
?? .glab-ci-autoheal/
```

(pre-existing untracked scratch, acceptable per brief)

Commits `38b25f74..HEAD` (a45866b2, 8 commits, all pre-existing from Tasks 1-8 — none added by Task 9):

```
a45866b2 feat(governance): add Line column to status.csv — duplicate markers now distinguishable
cef507ea chore(deps): bump mcp to v0.1.12 — tools/call results freed by server
34c3988b fix(fts): hydrate-on-miss fallback in live maintenance for evicted nodes
e1910a52 fix(fts): geode.fts.rebuild nodes_indexed counts actually-indexed nodes
d8841d68 fix(fts): tolerate IndexNotFound in maintenance create leg; harden rebuild race test
8d210891 fix(fts): queue concurrent writes during geode.fts.rebuild and drain post-backfill
c31702f8 fix(fts): refcounted quiescence for dropIndex vs in-flight readers and writers
b1c37530 fix(fts): drain in-flight writers in dropIndex before engine teardown
887139d1 fix(security): push active context in PROFILE execution path
```

### harness (`../geode-test-harness`)

`git status --short`:

```
?? reports_baseline/
?? reports_clean/
?? reports_m31/
?? reports_p2/
?? reports_v038/
?? runners/rust_runner/Cargo.lock
```

(all acceptable untracked scratch per brief — `reports_*` are test-run output dirs, `Cargo.lock` is a generated lockfile)

Commits `6c0f68b3..HEAD` (4003ea80, 1 commit):

```
4003ea8 fix(capture): defer capture storage until step failure is finalized
```

### mcp (`~/src/gl/gitlab.com/devnw/zig/mcp`)

`git status --short`: clean (no output)

Commits `956b07d7..HEAD` (19fa8c20, 1 commit):

```
19fa8c2 fix: thread demo handler allocator per-instance via ctx, not a global
```

## Summary

All 6 gate steps passed cleanly. No substantive breakage was found anywhere in the sweep — the
2026-08-29 follow-up series (Tasks 1-8) is validated green:

- `make fmt`: no residual diff
- 18/18 targeted `zig build test-*` steps: PASS
- 4/4 sharded full-suite runs: exit 0, no failures
- 6/6 harness specs: PASS, managed servers verified started each run
- Harness pytest: 174 passed, 1 skipped
- `make status-generate-test`: PASS
- `make pre-commit`: only the 4 documented known-red hooks red (markdownlint legacy docs,
  hadolint, goreleaser deprecated-config, detect-diamond-deps pre-existing transitive versions)
- git status clean (modulo documented acceptable untracked scratch) in all three repos

No commits were made by Task 9 (nothing needed fixing). Per the task rules, no repo was pushed —
push is left to the orchestrator.

## Final-review fix wave (series 2)

Date: 2026-08-29. Executed from: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode
(main, on top of `a45866b2`). Three commits, no push (per instructions).

### Item 1 — read-side hydrating fallback in FTS search hit resolution

**Change**: `filterAuthorizedHits` (`src/execution/fts_dispatch.zig`) resolved each
`CALL geode.fts.search/phrase/proximity` hit via a resident-cache-only lookup
(`store.nodes.lockShardShared` + `getPtrUnlocked`) and silently dropped the hit on a miss,
treating it as "deleted since indexing". A node evicted from the bounded node cache is durable,
not deleted. Fixed by falling back — outside the shard lock — to `store.nodes.getOrHydrate`
(the by-value, concurrency-safe hydrate-on-miss accessor), same fix shape as Task 5's write-side
fix (commit `34c3988b`). A genuine hydrate miss (node truly gone) still drops the hit. Added one
sentence to the module doc noting the `eval.zig` `scanVectorKnn` scan remains resident-only by
separate documented design and was NOT touched.

**RED/GREEN**: Genuinely confirmed both directions by toggling only the src fix (not the tests)
and rebuilding:

- Pre-fix: 2/6 tests in `tests/test_fts_authorization.zig` fail (`expected 1, found 0`) — the
  hydrate test and the tenant-scoped-hydrate test.
- Post-fix: 6/6 pass.

**Non-obvious finding during TDD**: a bare top-level `CALL geode.fts.search(...)` goes through
`executeCallStatement` (`src/execution/call_operations.zig:74-89`), which ALWAYS wraps the call
in a `QueryReadSession` — a deep clone of the ENTIRE store that re-materializes every node from
the durable engine on every single call (`GraphStore.cloneNodesFrom`'s bounded-source branch,
`src/graph_store.zig:2437-2461`, already walks every id in the per-graph IdMap and rebuilds from
the engine if not resident). This means a bare `CALL` masks bounded-cache eviction entirely —
confirmed empirically with a debug stack trace showing `cloneNodesFrom` reinserting the "evicted"
node into a fresh per-call snapshot before `filterAuthorizedHits` ever runs. The one documented,
unprivileged way to reach the SAME code path `filterAuthorizedHits` runs against directly (no
snapshot) is a CALL inside an explicit transaction body — `START TRANSACTION { CALL ... }` —
which `execution.zig:1383-1388` dispatches straight to `call_operations.executeCallProcedure`,
bypassing the snapshot wrapper. Added `Harness.runQueryUnsnapshotted` to
`tests/test_fts_authorization.zig` for this and used it in the three new eviction-sensitive
tests; the pre-existing tenant/RLS tests were left using the bare-CALL helper since they don't
depend on cache residency.

**Results**: `zig build test-fts-authorization test-fts-e2e test-fts-bulk-merge-maintenance
test-scan-ingest-race` → 45/45 build steps, 14/14 tests pass.

**SHA**: `429caa51` — `fix(fts): hydrate evicted-but-durable nodes when resolving search hits`

### Item 2 — drain-phase residual documentation

**Change**: documented two accepted drain-phase residuals in `rebuildFulltextIndex`
(`src/execution/fts_index_ops.zig`, ahead of the `endRebuild` call in the drain block): (a) back
edge — a write landing after `endRebuild` clears the rebuilding flag but before the drain loop
reaches that id can interleave with the drain's own reindex and double-append a posting, cleared
only by the next rebuild; (b) in-snapshot delete — a node already covered by the backfill
snapshot that is deleted mid-window is queued into `pending` but the `snapshot_set.contains`
check skips it unconditionally, so no tombstone is written and a stale posting for the gone node
persists until the next rebuild. Noted both are invisible to callers because
`filterAuthorizedHits` (Item 1) drops any hit whose node cannot be resolved. Softened
`docs/FULLTEXT_SEARCH.md`'s "handled correctly with no special casing" sentence to describe the
two delete sub-cases accurately.

**RED/GREEN**: N/A — comments/docs only, no behavior change.

**Results**: `zig build test-fts-rebuild` → 36/36 build steps, 5/5 tests pass (unchanged
behavior, confirming no regression from the comment-only edit).

**SHA**: `8ad95e99` — `docs(fts): document drain-phase rebuild residuals (back edge, in-snapshot delete)`
(includes an incidental `docs/status.csv` line-number refresh from the pre-commit sync hook —
the marker line shifted because of the inserted comment block).

### Item 3 — two small test/hygiene items

**Change 1**: `tools/test_status_generate.py`'s `EXPECTED_ROWS` comment referenced a nonexistent
`test_line_numbers_match_fixture`. Corrected the comment to name the two tests that actually pin
those line values: `test_golden_rows_exact` (all rows) and
`test_duplicate_marker_disambiguated_by_line` (the `REQ-GOLD-DUP` pair's `[15, 19]` specifically).

**Change 2**: added regression coverage in `tests/test_read_only_execute.zig` for the
`.Profile => |prof| isMutatingStatement(prof.query),` unwrap (`query_traits.zig:327`) →
`call_clause` chain, which had no dedicated test. Two new tests: `PROFILE MATCH (n:Device) CALL
geode.ts.insert(...)` classifies mutating (with a structural precondition asserting PROFILE
really does wrap a `.Query` whose `call_clause` is set — not a parse fallback), and a
PROFILE-wrapped read-only CALL (`geode.fts.search`) does not.

**RED/GREEN**: Change 2 is a regression pin for already-correct behavior (no bug found), so no
RED was expected from the unmodified codebase. Verified the new test actually exercises the
`.Profile` unwrap by temporarily changing `.Profile => |prof| isMutatingStatement(prof.query),`
to `.Profile => false` and rebuilding: 1/12 tests failed (exactly the new PROFILE-mutating test,
`expected true` via `isMutatingProgram`), confirming the test is load-bearing; reverted and
rebuilt clean.

**Results**: `zig build test-read-only-execute` → 36/36 build steps, 12/12 tests pass (was 10/10
before the two additions). `python3 tools/test_status_generate.py` → 8/8 unittest cases pass.
`make status-generate` → no `docs/status.csv` diff (neither changed file carries CANARY markers
at shifted line offsets).

**SHA**: `25963c45` — `test: pin PROFILE-wrapped mutating CALL classification; fix stale status-generate comment`

### Constraints check

- `make fmt` run on all touched Zig files before each commit.
- `docs/status.csv` regenerated via `make status-generate` / the pre-commit sync hook in the same
  commit whenever the hook detected a change (Item 2 only).
- CANARY markers on all new Item-1 test/dispatch sites, dated `UPDATED=2026-08-29`.
- No mocks/simulation — every test drives the real parser, real executor, real store, real
  fts-storage engine.
- No push performed.
