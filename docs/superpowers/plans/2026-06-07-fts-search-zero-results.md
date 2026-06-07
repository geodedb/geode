# FTS Search Returns Zero Results — Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `CREATE INDEX … USING fulltext` followed by `CALL geode.fts.search(...)` return matching rows when the index is created **before** any node write on a graph (the index-first ordering), fixing `docs/bugs/2026-06-07-fts-search-returns-zero-results-at-runtime.md`.

**Architecture:** Single-line root-cause fix plus a regression test and a loud-failure guard. FTS is fully functional (BM25 backfill + live-write indexing + search all work) — the only defect is graph resolution in the DDL path.

**Tech Stack:** Zig 0.16, `src/execution/fts_index_ops.zig`, `src/storage/graph_storage_adapter.zig`, `src/execution.zig`, `tests/test_fts_e2e.zig`.

---

## Root cause (confirmed by runtime diagnostic, 2026-06-07)

`createFulltextIndex` (`src/execution/fts_index_ops.zig:61`) resolves the target graph with
`adapter.lookupManagedGraph(graph_name)` — a **find-only** lookup that returns
`error.GraphNotFound` when the graph is not yet in the adapter's `engines` map. Every normal
write path uses `adapter.getOrCreateGraph(name)` (which lazily creates/opens the graph **and its
`fts_adapter`** via `createGraphLocked`/`openGraphLocked` → `initFtsForGraph`). So when
`CREATE INDEX … USING fulltext` is the **first** operation on a graph (before any node write that
would have lazily registered it), `lookupManagedGraph("default")` fails → `createFulltextIndex`
returns `Error.FulltextUnavailable`, which `src/execution.zig:~1496` **silently swallows**
(`FulltextUnavailable => {}`), so `CREATE INDEX` reports `00000` but no engine is created. A later
`CALL geode.fts.search` then resolves no engine and returns `0A000 Unsupported` (or `00000` + 0
rows on older builds).

**Evidence:**
- Runtime `[FTSDIAG]` print confirmed `lookupManagedGraph('default') err=error.GraphNotFound`.
- **Nodes-first ordering works**: insert a `:Doc` node (registers `default` via `getOrCreateGraph`)
  → `CREATE INDEX` → `CALL geode.fts.search('idx','fox')` returns 1 row, BM25 score ~0.288, and the
  on-disk `fts/<idx>/{wal,segments}` engine dir is created.
- The existing `tests/test_fts_e2e.zig` creates nodes **before** the index, so it never exercises
  index-first ordering and does not catch this.

---

## File structure

- `tests/test_fts_e2e.zig` — add an **index-first** regression test (Task 1).
- `src/execution/fts_index_ops.zig` — `createFulltextIndex` line 61: `lookupManagedGraph` →
  `getOrCreateGraph` (Task 2).
- `src/execution.zig` — make the swallowed `FulltextUnavailable` visible (Task 3).

---

## Task 1: Failing index-first regression test

> **Build wiring note:** `tests/test_fts_e2e.zig` currently runs ONLY via
> `tests/all_tests.zig` (the sharded `zig build test` umbrella) — there is no isolated step. Add a
> dedicated `test-fts-e2e` step (Step 0 below), mirroring `match_call_tests` at `build.zig:1752`
> (`addTest` over `tests/test_fts_e2e.zig` → `addImport("geode", root_mod)` → `link_libc = true` →
> `b.step("test-fts-e2e", ...)`), so the regression can be run in isolation and gated in CI.

**Files:**
- Modify: `build.zig` (add the `test-fts-e2e` step — Step 0)
- Modify: `tests/test_fts_e2e.zig` (add one test using the existing `Harness`)

- [ ] **Step 0: Add an isolated build step** mirroring `build.zig:1752` (`match_call_tests`):

```zig
    // Isolated FTS end-to-end step (also pulled into `zig build test` via all_tests.zig).
    const fts_e2e_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_fts_e2e.zig"), .target = target, .optimize = optimize }) });
    fts_e2e_tests.root_module.addImport("geode", root_mod);
    fts_e2e_tests.root_module.link_libc = true;
    const run_fts_e2e_tests = b.addRunArtifact(fts_e2e_tests);
    const fts_e2e_step = b.step("test-fts-e2e", "FTS end-to-end: CREATE INDEX (nodes-first AND index-first) + CALL geode.fts.search");
    fts_e2e_step.dependOn(&run_fts_e2e_tests.step);
```

Run `zig build test-fts-e2e` once to confirm the step builds and the EXISTING (nodes-first) test still passes before adding the new one.

- [ ] **Step 1: Add the test** (mirror the existing test's `Harness`/assertion style). The KEY is
  that `CREATE INDEX` is the FIRST query — no node is created beforehand — so the `default` graph is
  not yet registered in the adapter's `engines`.

```zig
test "A4a FTS e2e: CREATE INDEX *before* any node write (index-first) still indexes + searches" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    // 1. Create the fulltext index FIRST — before any :Doc node exists. This is
    //    the index-first ordering that regressed: the graph is not yet in the
    //    adapter's engines map, so the DDL must getOrCreate it (not find-only).
    {
        var r = try h.runQuery("CREATE INDEX idx_first FOR (d:Doc) ON (d.body) USING fulltext");
        r.deinit(aa);
    }
    // 2. Now insert a node — the live-write maintenance hook must index it.
    {
        var r = try h.runQuery("CREATE (:Doc {body: 'the quick brown fox'})");
        r.deinit(aa);
    }
    // 3. Search must return exactly the fox node (>= 1 row).
    {
        var res = try h.runQuery("CALL geode.fts.search('idx_first', 'fox')");
        defer res.deinit(aa);
        try testing.expect(res.rows.len >= 1);
    }
}
```

- [ ] **Step 2: Run it, verify it FAILS** (red — proves the bug)

Run: `zig build test-fts-e2e` (or the FTS e2e build step that wraps `tests/test_fts_e2e.zig`; confirm the exact step name with `grep -n "test_fts_e2e" build.zig`)
Expected: FAIL — `res.rows.len` is 0 because the index-first `CREATE INDEX` no-ops.

- [ ] **Step 3: Commit the failing test**

```bash
git add tests/test_fts_e2e.zig
git commit -m "test(fts): index-first CREATE INDEX before node write must still search (failing)"
```

## Task 2: Fix — use getOrCreateGraph in the DDL create path

**Files:**
- Modify: `src/execution/fts_index_ops.zig:61`

- [ ] **Step 1: Change the resolution from find-only to get-or-create**

```zig
    // Resolve (creating/opening if needed) the ManagedGraph that owns the fts
    // adapter for this graph. CREATE INDEX may be the FIRST op on a graph (before
    // any node write registered it in `engines`), so use getOrCreateGraph — the
    // same path every write uses — instead of the find-only lookupManagedGraph,
    // which returned GraphNotFound and silently disabled the index.
    const mg = adapter.getOrCreateGraph(graph_name) catch return Error.FulltextUnavailable;
    const fa = mg.fts_adapter orelse return Error.FulltextUnavailable;
```

- [ ] **Step 2: Run the new test, verify it PASSES** (green)

Run: `zig build test-fts-e2e`
Expected: PASS — the index engine is created, the node is live-indexed, search returns the fox node.

- [ ] **Step 3: Run the full FTS suite to confirm no regression**

Run: `zig build test-fts-e2e && zig build test-fts-storage-adapter && zig build test-fts-maintenance` (confirm exact step names via `grep -nE "test-fts" build.zig`)
Expected: all PASS (nodes-first and index-first both work).

- [ ] **Step 4: Commit the fix**

```bash
git add src/execution/fts_index_ops.zig
git commit -m "fix(fts): CREATE INDEX getOrCreate the target graph so index-first ordering indexes (2026-06-07 zero-results bug)"
```

## Task 3: Make a genuine FTS-unavailable loud, not silent

The bug doc (§4) calls out the silent-success failure mode as the worst part. After Task 2,
`FulltextUnavailable` only occurs on a genuine failure (no global adapter, or getOrCreateGraph
failed). Today `src/execution.zig` swallows it as `00000`. Make it visible so a real FTS-unavailable
is observable, WITHOUT changing the catalog-row contract (keep the row as the SHOW source of truth).

**Files:**
- Modify: `src/execution.zig` (the `fts_index_ops.Error.FulltextUnavailable => {}` arm, ~line 1496)

- [ ] **Step 1: Replace the silent swallow with a visible breadcrumb**

```zig
                    // FTS could not be initialised for this graph (genuine init
                    // failure — getGlobalAdapter null or getOrCreateGraph failed).
                    // The catalog row above still records the index (SHOW source of
                    // truth), but the engine is absent and search will report it
                    // missing. Surface it loudly (std.debug.print reaches stdout/
                    // stderr on the serve path, unlike log.warn) so this is never a
                    // silent success. See docs/bugs/2026-06-07-fts-search-returns-zero-results-at-runtime.md
                    fts_index_ops.Error.FulltextUnavailable => {
                        std.debug.print("[fts] WARNING: CREATE INDEX '{s}' recorded in catalog but the fulltext engine is UNAVAILABLE for this graph — search will return no results\n", .{index_name});
                    },
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `zig build`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add src/execution.zig
git commit -m "fix(fts): surface a loud warning when CREATE INDEX cannot init the fulltext engine (no more silent success)"
```

---

## Self-review

- Spec coverage: doc §3 root cause (index population path) → Task 2; doc §4 "add an e2e test that
  asserts a match is returned" → Task 1; doc §4 "fail loud if FTS not functional" → Task 3.
- Placeholders: every step carries exact code / commands. Build-step names must be confirmed with
  the two `grep` commands noted inline (Task 1 Step 2, Task 2 Step 3).
- Type consistency: `getOrCreateGraph` returns `!*ManagedGraph` (same shape as `lookupManagedGraph`),
  so the `catch return Error.FulltextUnavailable` and the subsequent `mg.fts_adapter` usage are
  unchanged. No call-site type drift.
- Downstream: `../geode-client-zig` and `~/src/devnw/zig` need NO change — this is a server-side
  graph-resolution bug; the wire protocol and client are unaffected (search already works for
  nodes-first ordering with no client change).
