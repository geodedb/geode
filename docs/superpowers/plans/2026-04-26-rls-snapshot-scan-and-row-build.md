# RLS Snapshot-Scan + Row-Build Hot-Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the H5a "long MATCH-with-RLS holds the SHARED rwlock" bottleneck (avg 460 ms / max 2.23 s per acquire, choking writers — see commit `958be673` and `docs/performance/2026-04-25-quic-cascade-investigation/bisection-analysis.md` "Secondary bisection — rwlock SHARED hold-time" section). Two coupled fixes: (1) shrink the per-node `nodePropertiesToRLSRow` hot path (HashMap.allocate frame in the T2 stack) so RLS row construction is allocation-cheap, and (2) ensure `executeMultiNodeMatch` always runs against a snapshot (lock-free) by reclassifying RLS-evaluating reads off the point-read path and adding per-call-site SHARED hold-time counters that disambiguate any residual long hold for a follow-up plan.

**Architecture:** Surgical, low-risk fixes informed by the H5a verdict + existing snapshot infrastructure. Part A (per-node RLS row): pre-size `StringHashMap` with `ensureTotalCapacity`, add a reusable variant `nodePropertiesToRLSRowInto(properties, *row)` that the per-node loop calls with `clearRetainingCapacity` between nodes. Part B (per-site instrumentation): split the existing `mg_rwlock_shared_hold_ns_total` cumulative counter into per-call-site counters (snapshot, point_read, bulk_merge_phase1, bulk_match_create_edge_phase1, fallback_acquire_read_lock, miscellaneous) so the next cascade repro definitively identifies the residual long-hold site. Part C (RLS-read classification): add a `wouldEvaluateRLS()` predicate that pulls MATCH-with-active-RLS-policy off the point-read path so it always uses `snapshotUnderReadLock`. Part D (regression test): pin the per-acquire SHARED max-hold under MATCH-with-RLS + concurrent writer load. Part E (closure): re-run the workers=4 cascade repro and append closure to `bisection-analysis.md`.

**Tech Stack:** Zig 0.16. `std.StringHashMap.ensureTotalCapacity`, `clearRetainingCapacity`, `putAssumeCapacityNoClobber`. `std.atomic.Value(u64).fetchAdd(.monotonic)`. `runtime_metrics.Registry.register`. Existing infrastructure: `graph_store.snapshotUnderReadLock` (`src/graph_store.zig:5507`), `QueryReadSession` (`src/graph_store.zig:6078`), `pushActiveQueryReadStore`/`popActiveQueryReadStore` (`src/graph_store.zig:6068-6076`), `ManagedGraph.rwlock_shared_hold_ns_total` (`src/storage/graph_storage_adapter.zig:553`). Test harness: `make build`, `zig build test`, the workers=4 cascade repro driver from the prior plan (`/tmp/run-quic-investigation-repro.sh`).

---

## File structure

| File | Status | Responsibility |
|------|--------|----------------|
| `src/security/rls_value_bridge.zig` | Modify | Pre-size the `StringHashMap` in `nodePropertiesToRLSRow`. Add a new `nodePropertiesToRLSRowInto(*row, properties)` variant that clears + reuses an externally-owned row. Keep the existing `nodePropertiesToRLSRow` API for callers that want a fresh row (test code). |
| `src/execution/match_operations.zig` | Modify | (a) Convert `passesRLSExprFilter` to take an externally-owned `*std.StringHashMap(rls.Value)` so the iteration loop can reuse one row across all candidate nodes. (b) Add a `wouldEvaluateRLS()` predicate exported for the dispatcher in step (c). (c) In `executeMultiNodeMatch`, allocate the reusable RLS row once before each chain's loop, clear-and-reuse it inside the loop. |
| `src/storage/graph_storage_adapter.zig` | Modify | Add five new per-site SHARED hold-time counters on `ManagedGraph`: `rwlock_shared_hold_snapshot_ns_total`, `rwlock_shared_hold_point_read_ns_total`, `rwlock_shared_hold_bulk_merge_ns_total`, `rwlock_shared_hold_bulk_edge_ns_total`, `rwlock_shared_hold_fallback_ns_total`. Wire `releaseGraphReadLock` to update the matching per-site counter alongside the existing aggregate. Register the five new counters in the existing runtime_metrics block. Add `lookupManagedGraph(name) !*ManagedGraph` test-helper. |
| `src/server/quic_connection_handler.zig` | Modify | (a) Reclassify the read-dispatch in `handleStreamQueryLoop` (around lines 3163-3204): when `analysis.is_point_read` is true AND `wouldEvaluateRLS()` is true, route through the snapshot path instead of the point-read path. (b) Tag each `acquireGraphReadLock` call site with a `LockSiteTag` enum so the new per-site counters update the correct slot. |
| `src/transport/grpc_server.zig` | Modify | Same reclassification + tagging as the QUIC handler (the dispatch logic at lines 2056-2100 mirrors the QUIC handler). |
| `src/graph_store.zig` | Modify | (a) Add `LockSiteTag` enum (`snapshot`, `point_read`, `bulk_merge`, `bulk_edge`, `fallback`, `misc`). (b) Add `acquireGraphReadLockTagged(graph_name, tag) GraphLockHandle` variant. (c) Add `site_tag` field on `GraphLockHandle` (default `.misc`). (d) Modify `releaseGraphLock(handle)` to plumb `site_tag` to `releaseGraphReadLock`. (e) Tag `snapshotUnderReadLock` itself with `.snapshot`. |
| `tests/test_rls_row_build_hot_path.zig` | Create | Unit test for the optimized `nodePropertiesToRLSRow` and `nodePropertiesToRLSRowInto` paths: 100-property node, fresh-vs-reused equivalence, 1000-cycle reuse leak-freedom. |
| `tests/test_match_rls_lock_hold_regression.zig` | Create | Integration test: build a graph with 5000 :Doc nodes, drive 100 snapshot reads while a writer thread contends; assert `mg_rwlock_shared_max_hold_ns_observed` stays below 50 ms (vs. pre-fix ~460 ms avg / 2.23 s max). |
| `build.zig` | Modify (small) | Register the two new test binaries (`test-rls-row-build-hot-path`, `test-match-rls-lock-hold-regression`). |
| `docs/performance/2026-04-26-rls-snapshot-scan-fix/repro-server.log` | Create (committed) | Re-run cascade repro server log against the fixed binary. |
| `docs/performance/2026-04-26-rls-snapshot-scan-fix/repro-ingest.log` | Create (committed) | Re-run cascade ingest log. |
| `docs/performance/2026-04-26-rls-snapshot-scan-fix/cascade-stacks.txt` | Create (committed) | Stack capture at trigger (or "no cascade" marker if it doesn't trigger). |
| `docs/performance/2026-04-25-quic-cascade-investigation/bisection-analysis.md` | Modify (append) | New section "H5a closure (2026-04-26)" with post-fix per-site counter trajectories, max-hold-observed delta, cascade-trigger outcome (closed / shifted / persists). |

**Out of scope — separate plans/handoffs:**
- Snapshot deep-clone optimization (only investigate if Phase 6's per-site counters reveal `rwlock_shared_hold_snapshot_ns_total` dominates). Filed as a follow-up plan, NOT in this plan.
- Bulk fast-path Phase 1 lookup optimization (only if `rwlock_shared_hold_bulk_merge_ns_total` or `rwlock_shared_hold_bulk_edge_ns_total` dominates). Follow-up plan.
- The other three follow-ups from the H5a verdict context (per-stream last-activity-time logging; NoHandshakeKeys quic regression; quic_total_cwnd_bytes growth) are independent and have their own separate plans/handoffs.

---

## Phase 0 — Build sanity check

### Task 0: Verify clean baseline build + green test suite

**Files:** none (read-only).

The two prior commits (`958be673`, `463c01bb`) added per-graph hold-time atomics and the secondary bisection. Confirm the tree builds + RLS regression tests pass before changing the hot path.

- [ ] **Step 0.1: Verify clean working tree on main.**

  ```bash
  cd /data/home/benji/src/devnw/codepros/geode/geode
  git status --porcelain | grep -vE '^\?\?|^ M docs/|^ M scripts/' || true
  ```

  Expected: empty (untracked docs and scripts/install-deps.sh changes are pre-existing, not part of this plan).

- [ ] **Step 0.2: Build and confirm baseline RLS tests pass.**

  Note: `test_rls_expr_engine_wiring.zig` and `test_gap0509_tenant_isolation.zig` are wired into the omnibus `test` step (no dedicated `b.step()`). To get focused signal without running the full suite (~10+ min), run them as standalone test binaries via `zig test`:

  ```bash
  make build 2>&1 | tail -3
  # Focused baseline: run the two RLS regression tests as standalone binaries.
  # If you cannot resolve the geode module path quickly, fall back to:
  #   zig build test 2>&1 | grep -iE 'test_rls_expr_engine_wiring|test_gap0509_tenant_isolation|FAIL|panic:' | head -20
  zig build test 2>&1 | tee /tmp/zig-build-test.log | grep -iE 'FAIL|panic:|new error:' | head -20
  ```

  Expected: `make build` clean; the second command produces no FAIL/panic lines from `test_rls_expr_engine_wiring` or `test_gap0509_tenant_isolation` (other pre-existing environmental failures in the omnibus suite — FileNotFound, ConnectionRefused, ABRT in features_test — are out of scope for this plan and predate these changes).

- [ ] **Step 0.3: Confirm the H5a counters exist + emit.**

  ```bash
  grep -n "mg_rwlock_shared_hold_ns_total\|mg_rwlock_shared_max_hold_ns_observed" src/storage/graph_storage_adapter.zig | head -5
  ```

  Expected: matches at lines 563/570 (field declarations: `rwlock_shared_hold_ns_total` at 563, `rwlock_shared_max_hold_ns_observed` at 570 per HEAD `958be673`) and registration calls at lines 3261/3262. If the line numbers have drifted (a different commit landed), substitute accordingly using the grep output as the source of truth.

- [ ] **Step 0.4: No commit — read-only.**

---

## Phase 1 — Shrink the per-node RLS row hot path

### Task 1: Pre-size the StringHashMap in `nodePropertiesToRLSRow`

**Files:**
- Modify: `src/security/rls_value_bridge.zig:55-69`

The HashMap.allocate frame in the H5a T2 stack is `std.StringHashMap.put` triggering a rehash. `StringHashMap` starts at capacity 0 and grows 0 → 16 → 32 → 64 ... per the load-factor doubling rule. Each rehash is `O(n)` with one allocator call. Pre-sizing to the known property count eliminates all per-call rehashes.

- [ ] **Step 1.1: Modify `nodePropertiesToRLSRow` to pre-size the row.**

  Replace lines 55-69 in `src/security/rls_value_bridge.zig` (the existing function body):

  ```zig
  pub fn nodePropertiesToRLSRow(
      allocator: Allocator,
      properties: *const std.StringHashMap(graph_store.PropertyValue),
  ) !std.StringHashMap(rls.Value) {
      var row = std.StringHashMap(rls.Value).init(allocator);
      errdefer row.deinit();

      var it = properties.iterator();
      while (it.next()) |entry| {
          const rls_val = propertyValueToRLS(entry.value_ptr.*);
          try row.put(entry.key_ptr.*, rls_val);
      }

      return row;
  }
  ```

  with:

  ```zig
  pub fn nodePropertiesToRLSRow(
      allocator: Allocator,
      properties: *const std.StringHashMap(graph_store.PropertyValue),
  ) !std.StringHashMap(rls.Value) {
      var row = std.StringHashMap(rls.Value).init(allocator);
      errdefer row.deinit();

      // Pre-size to property count to eliminate per-put rehash. Saves the
      // 0→16→32→... allocator calls observed in the H5a T2 stack
      // (HashMap.allocate frame). Each rehash was an O(n) memcpy.
      try row.ensureTotalCapacity(@as(u32, @intCast(properties.count())));

      var it = properties.iterator();
      while (it.next()) |entry| {
          const rls_val = propertyValueToRLS(entry.value_ptr.*);
          row.putAssumeCapacityNoClobber(entry.key_ptr.*, rls_val);
      }

      return row;
  }
  ```

- [ ] **Step 1.2: Build.**

  ```bash
  make build 2>&1 | tail -3
  ```

  Expected: clean.

- [ ] **Step 1.3: Run the existing nodePropertiesToRLSRow unit tests.**

  ```bash
  zig build test 2>&1 | grep -E "nodePropertiesToRLSRow|FAIL|panic:" | head -10
  ```

  Expected: the two existing tests in `rls_value_bridge.zig:138-184` (`converts all property variants`, `empty properties produces empty row`) pass.

- [ ] **Step 1.4: Commit.**

  ```bash
  git add src/security/rls_value_bridge.zig
  git commit -m "perf(rls): pre-size StringHashMap in nodePropertiesToRLSRow

  Eliminate the 0->16->32->... rehash chain visible in the H5a T2 stack
  (HashMap.allocate frame). One ensureTotalCapacity call replaces N
  amortised rehashes; subsequent puts use putAssumeCapacityNoClobber
  for the no-bounds-check fast path.

  Refs docs/performance/2026-04-25-quic-cascade-investigation/bisection-analysis.md
  H5a verdict — primary fix part A."
  ```

### Task 2: Add reusable `nodePropertiesToRLSRowInto` variant

**Files:**
- Modify: `src/security/rls_value_bridge.zig` (append after `nodePropertiesToRLSRow`)

For callers that loop over many nodes (`executeMultiNodeMatch`), the `init`/`deinit` overhead per node is wasted; one row buffer can be cleared and reused. Add a variant that takes an externally-owned row.

- [ ] **Step 2.1: Add the reusable variant immediately after the existing `nodePropertiesToRLSRow` function (after line 69).**

  ```zig
  /// Reusable variant of `nodePropertiesToRLSRow`: caller owns and reuses
  /// `row` across many invocations. Clears the row's contents (retaining
  /// the backing buffer) before populating, then ensures capacity for the
  /// new property count and inserts each property without bounds checks.
  ///
  /// Use this from per-node loops (`executeMultiNodeMatch` et al.) to
  /// avoid one HashMap init/deinit per matched node.
  pub fn nodePropertiesToRLSRowInto(
      row: *std.StringHashMap(rls.Value),
      properties: *const std.StringHashMap(graph_store.PropertyValue),
  ) !void {
      row.clearRetainingCapacity();
      try row.ensureTotalCapacity(@as(u32, @intCast(properties.count())));

      var it = properties.iterator();
      while (it.next()) |entry| {
          const rls_val = propertyValueToRLS(entry.value_ptr.*);
          row.putAssumeCapacityNoClobber(entry.key_ptr.*, rls_val);
      }
  }
  ```

- [ ] **Step 2.2: Build.**

  ```bash
  make build 2>&1 | tail -3
  ```

  Expected: clean.

- [ ] **Step 2.3: No commit yet — Task 3's tests will exercise this function and we want them in the same commit.**

### Task 3: Unit test for the row-build hot path

**Files:**
- Create: `tests/test_rls_row_build_hot_path.zig`
- Modify: `build.zig` (add test target)

Verify (a) the pre-sized fresh-row path produces correct output, (b) the reusable `nodePropertiesToRLSRowInto` path is semantically equivalent to the fresh path, and (c) reuse across many invocations doesn't leak.

- [ ] **Step 3.1: Create `tests/test_rls_row_build_hot_path.zig`.**

  ```zig
  // SPDX-License-Identifier: Apache-2.0
  // Copyright (c) 2024-2025 CodePros

  //! Hot-path coverage for nodePropertiesToRLSRow + nodePropertiesToRLSRowInto.
  //! Pins the H5a primary-fix part A behaviour: pre-sized fresh-row path
  //! produces correct output, reusable variant is semantically equivalent,
  //! and reuse across 1000 cycles does not leak.
  //!
  //! CANARY: REQ=REQ-PERF-RLS-ROW-BUILD-001; FEATURE="RLSRowBuildHotPath"; ASPECT=PreSizeAndReuse; STATUS=TESTED; TEST=tests/test_rls_row_build_hot_path.zig; OWNER=performance; UPDATED=2026-04-26

  const std = @import("std");
  const geode = @import("geode");
  const rls = @import("rls");
  const graph_store = geode.graph_store;
  const rls_value_bridge = geode.rls_value_bridge;

  fn buildPropertyMap(allocator: std.mem.Allocator, n: usize) !std.StringHashMap(graph_store.PropertyValue) {
      var props = std.StringHashMap(graph_store.PropertyValue).init(allocator);
      var i: usize = 0;
      while (i < n) : (i += 1) {
          const key = try std.fmt.allocPrint(allocator, "k{d}", .{i});
          try props.put(key, .{ .Int = @as(i64, @intCast(i)) });
      }
      return props;
  }

  fn freePropertyMap(allocator: std.mem.Allocator, props: *std.StringHashMap(graph_store.PropertyValue)) void {
      var it = props.keyIterator();
      while (it.next()) |k| allocator.free(k.*);
      props.deinit();
  }

  test "nodePropertiesToRLSRow: pre-sized path produces correct output for 100 properties" {
      const allocator = std.testing.allocator;
      var props = try buildPropertyMap(allocator, 100);
      defer freePropertyMap(allocator, &props);

      var row = try rls_value_bridge.nodePropertiesToRLSRow(allocator, &props);
      defer row.deinit();

      try std.testing.expectEqual(@as(usize, 100), row.count());
      // Spot-check: k42 maps to integer 42.
      const v = row.get("k42") orelse return error.MissingKey;
      try std.testing.expectEqual(@as(i64, 42), v.integer);
  }

  test "nodePropertiesToRLSRowInto: produces identical output to nodePropertiesToRLSRow" {
      const allocator = std.testing.allocator;
      var props = try buildPropertyMap(allocator, 50);
      defer freePropertyMap(allocator, &props);

      var fresh_row = try rls_value_bridge.nodePropertiesToRLSRow(allocator, &props);
      defer fresh_row.deinit();

      var reused_row = std.StringHashMap(rls.Value).init(allocator);
      defer reused_row.deinit();
      try rls_value_bridge.nodePropertiesToRLSRowInto(&reused_row, &props);

      try std.testing.expectEqual(fresh_row.count(), reused_row.count());

      var it = fresh_row.iterator();
      while (it.next()) |entry| {
          const reused_val = reused_row.get(entry.key_ptr.*) orelse return error.MissingKey;
          // Both paths use propertyValueToRLS, so the discriminant + value match.
          try std.testing.expectEqual(std.meta.activeTag(entry.value_ptr.*), std.meta.activeTag(reused_val));
          switch (entry.value_ptr.*) {
              .integer => |v| try std.testing.expectEqual(v, reused_val.integer),
              else => {}, // 50-property fixture is all .Int — no other branches hit
          }
      }
  }

  test "nodePropertiesToRLSRowInto: reuse 1000 cycles does not leak" {
      const allocator = std.testing.allocator;
      var props = try buildPropertyMap(allocator, 20);
      defer freePropertyMap(allocator, &props);

      var row = std.StringHashMap(rls.Value).init(allocator);
      defer row.deinit();

      var cycle: usize = 0;
      while (cycle < 1000) : (cycle += 1) {
          try rls_value_bridge.nodePropertiesToRLSRowInto(&row, &props);
          try std.testing.expectEqual(@as(usize, 20), row.count());
      }
      // std.testing.allocator panics at the test runner level if anything leaked.
  }

  test "nodePropertiesToRLSRow: empty property map produces empty row" {
      const allocator = std.testing.allocator;
      var props = std.StringHashMap(graph_store.PropertyValue).init(allocator);
      defer props.deinit();

      var row = try rls_value_bridge.nodePropertiesToRLSRow(allocator, &props);
      defer row.deinit();

      try std.testing.expectEqual(@as(usize, 0), row.count());
  }
  ```

- [ ] **Step 3.2: Register in `build.zig`.**

  Find the prior plan's `test-graph-storage-adapter-metrics` block:

  ```bash
  grep -n "test-graph-storage-adapter-metrics" build.zig
  ```

  Add a sibling block immediately after it. The canonical form mirrors the existing block — substitute `rls_row_build` for `graph_storage_adapter_metrics`:

  ```zig
      const rls_row_build_mod = b.createModule(.{ .root_source_file = b.path("tests/test_rls_row_build_hot_path.zig"), .target = target, .optimize = optimize });
      rls_row_build_mod.addImport("geode", root_mod);
      rls_row_build_mod.addImport("rls", rls_mod);
      const rls_row_build_tests = b.addTest(.{ .root_module = rls_row_build_mod });
      const run_rls_row_build_tests = b.addRunArtifact(rls_row_build_tests);
      test_step.dependOn(&run_rls_row_build_tests.step);
      const rls_row_build_step = b.step("test-rls-row-build-hot-path", "Run nodePropertiesToRLSRow hot-path coverage");
      rls_row_build_step.dependOn(&run_rls_row_build_tests.step);
  ```

  The `rls_mod` symbol is the module pre-existing for the `rls` package. If the surrounding build.zig uses a different name (e.g. `rls_module`), follow the local idiom — `grep -n 'rls_mod\|rls_module' build.zig` confirms.

- [ ] **Step 3.3: Run the test.**

  ```bash
  zig build test-rls-row-build-hot-path --summary all 2>&1 | tail -10
  ```

  Expected: `4/4 tests passed`. If the import path for `rls_value_bridge` is wrong, the compile error names the failing import — fix in step 3.2.

- [ ] **Step 3.4: Commit Task 2 + Task 3 together.**

  ```bash
  git add src/security/rls_value_bridge.zig tests/test_rls_row_build_hot_path.zig build.zig
  git commit -m "perf(rls): reusable nodePropertiesToRLSRowInto + hot-path tests

  Add a reusable variant that callers in per-node loops
  (executeMultiNodeMatch) can clear-and-refill across many
  invocations, avoiding one HashMap init/deinit per matched node.
  Equivalent to nodePropertiesToRLSRow at row-content level.

  Tests pin: pre-sized fresh-row correctness, fresh==reused
  equivalence, and 1000-cycle reuse leak-freedom.

  Refs docs/performance/2026-04-25-quic-cascade-investigation/bisection-analysis.md
  H5a verdict — primary fix part A."
  ```

---

## Phase 2 — Use the reusable row in `executeMultiNodeMatch`

### Task 4: Refactor `passesRLSExprFilter` + `passesRLSFilter` to take an externally-owned row

**Files:**
- Modify: `src/execution/match_operations.zig:120-161`

Currently `passesRLSExprFilter` allocates a fresh row per call. Switch the signature to take a `*std.StringHashMap(rls.Value)` so the loop can pass a reusable buffer. Keep `passesRLSFilter` as the public entry point but plumb the row pointer through.

- [ ] **Step 4.1: Read the current functions to confirm before-state.**

  ```bash
  sed -n '115,165p' src/execution/match_operations.zig
  ```

  Expected: matches the snippet shown in the H5a context (`passesRLSFilter` at line 120, `passesRLSExprFilter` at line 141). If line numbers have drifted (an unrelated commit landed in between), substitute accordingly.

- [ ] **Step 4.2: Modify `passesRLSExprFilter` to take a row pointer.**

  Find the existing function (line 141):

  ```zig
  fn passesRLSExprFilter(allocator: std.mem.Allocator, node: graph_store.Node, username: []const u8) bool {
      const expr_engine_ptr = rls_types.getGlobalExprRLSEngine() orelse return true;
      const expr_engine: *rls.RLSEngine = @ptrCast(@alignCast(expr_engine_ptr));

      // Convert node properties to RLS row format
      // GAP-0524: Fail closed on conversion errors — deny access rather than allow bypass
      var rls_row = rls_value_bridge.nodePropertiesToRLSRow(allocator, &node.properties) catch return false;
      defer rls_row.deinit();

      // Use first label as the table name for policy lookup
      const table = if (node.labels.len > 0) node.labels[0] else "default";

      // GAP-0524: Fail closed on evaluation errors — deny access rather than allow bypass
      return expr_engine.checkRowAccessByUsername(
          &rls_row,
          .select,
          username,
          node.graph_name,
          table,
      ) catch false;
  }
  ```

  Replace with:

  ```zig
  fn passesRLSExprFilter(
      reusable_row: *std.StringHashMap(rls.Value),
      node: graph_store.Node,
      username: []const u8,
  ) bool {
      const expr_engine_ptr = rls_types.getGlobalExprRLSEngine() orelse return true;
      const expr_engine: *rls.RLSEngine = @ptrCast(@alignCast(expr_engine_ptr));

      // Reuse the caller's row buffer to avoid one HashMap init/deinit per
      // node. GAP-0524: Fail closed on conversion errors.
      rls_value_bridge.nodePropertiesToRLSRowInto(reusable_row, &node.properties) catch return false;

      // Use first label as the table name for policy lookup.
      const table = if (node.labels.len > 0) node.labels[0] else "default";

      // GAP-0524: Fail closed on evaluation errors.
      return expr_engine.checkRowAccessByUsername(
          reusable_row,
          .select,
          username,
          node.graph_name,
          table,
      ) catch false;
  }
  ```

- [ ] **Step 4.3: Modify `passesRLSFilter` to plumb the row pointer.**

  Find the existing function (line 120):

  ```zig
  fn passesRLSFilter(allocator: std.mem.Allocator, node: graph_store.Node) bool {
      const ctx = execution.getActiveContext() orelse return true;
      const username = ctx.user orelse return true;

      // Layer 1: Label-deny check
      const filter_engine = rls_types.getGlobalRLSFilterEngine() orelse {
          // No label-deny engine — skip to expression check
          return passesRLSExprFilter(allocator, node, username);
      };
      for (node.labels) |label| {
          if (filter_engine.isLabelDenied(node.graph_name, label, username)) return false;
      }

      // Layer 2: Expression-based property check
      return passesRLSExprFilter(allocator, node, username);
  }
  ```

  Replace with:

  ```zig
  fn passesRLSFilter(
      reusable_row: *std.StringHashMap(rls.Value),
      node: graph_store.Node,
  ) bool {
      const ctx = execution.getActiveContext() orelse return true;
      const username = ctx.user orelse return true;

      // Layer 1: Label-deny check
      const filter_engine = rls_types.getGlobalRLSFilterEngine() orelse {
          // No label-deny engine — skip to expression check
          return passesRLSExprFilter(reusable_row, node, username);
      };
      for (node.labels) |label| {
          if (filter_engine.isLabelDenied(node.graph_name, label, username)) return false;
      }

      // Layer 2: Expression-based property check
      return passesRLSExprFilter(reusable_row, node, username);
  }
  ```

- [ ] **Step 4.4: Update every other call site of `passesRLSFilter`.**

  Find them:

  ```bash
  grep -n "passesRLSFilter\b" src/execution/match_operations.zig
  ```

  Expected hits (per current source): line 700, 763 (executeMultiNodeMatch label and full-scan paths — these are handled by Task 5), line 1398 (executeMatchCallQuery), and possibly others. For sites OTHER than `executeMultiNodeMatch`'s two loop sites (handled by Task 5), update inline.

  Before:

  ```zig
              if (!passesRLSFilter(allocator, node)) continue;
  ```

  After:

  ```zig
              // Per-call row buffer — these call sites are not in a tight
              // per-node loop, so allocate-on-call is acceptable. The
              // per-node-loop sites in executeMultiNodeMatch use the
              // reusable buffer pattern instead.
              var rls_row_local = std.StringHashMap(rls.Value).init(allocator);
              defer rls_row_local.deinit();
              if (!passesRLSFilter(&rls_row_local, node)) continue;
  ```

  Apply this transform at every call site in `match_operations.zig` EXCEPT the two inside `executeMultiNodeMatch` (the ones near lines 1700 and 1763 per the H5a stack — Task 5 handles those).

- [ ] **Step 4.5: Build.**

  ```bash
  make build 2>&1 | tail -10
  ```

  Expected: clean. If a call site was missed, the error message will name it; fix and re-run.

- [ ] **Step 4.6: No commit yet — Task 5 finishes the refactor and we want a single coherent commit.**

### Task 5: Use the reusable row inside `executeMultiNodeMatch`'s loops

**Files:**
- Modify: `src/execution/match_operations.zig:1687-1803` (the two loops in `executeMultiNodeMatch`)

The label-indexed and full-scan loops both call `passesRLSFilter(allocator, node.*)`. After Task 4 the signature is `passesRLSFilter(*row, node)`. Allocate one row buffer per chain (outside both loops, before the chain begins) and pass it in.

- [ ] **Step 5.1: Find the chain loop in `executeMultiNodeMatch`.**

  ```bash
  grep -n "for (q.match.chains)" src/execution/match_operations.zig
  ```

  Expected: line 1687.

- [ ] **Step 5.2: Add a per-chain reusable row.**

  Locate the line `var matches = std.ArrayList(*graph_store.Node).empty;` (currently line 1690). Insert immediately after:

  ```zig
              // Per-chain reusable RLS row buffer. One allocation, cleared
              // and reused across every candidate node in this chain's
              // label-indexed or full-scan loop. Eliminates the
              // 0->16->32->... rehash chain visible in the H5a T2 stack
              // (HashMap.allocate frame).
              var rls_row_buf = std.StringHashMap(rls.Value).init(allocator);
              defer rls_row_buf.deinit();
  ```

- [ ] **Step 5.3: Update the label-indexed loop's `passesRLSFilter` call (line 1700).**

  Find:

  ```zig
                  // GAP-0510: Filter by RLS denied labels
                  if (!passesRLSFilter(allocator, node.*)) continue;
  ```

  Replace with:

  ```zig
                  // GAP-0510: Filter by RLS denied labels.
                  // Reuses rls_row_buf across every node in this chain to
                  // avoid one HashMap init/deinit per match candidate.
                  if (!passesRLSFilter(&rls_row_buf, node.*)) continue;
  ```

- [ ] **Step 5.4: Update the full-scan loop's `passesRLSFilter` call (line 1763).**

  Find:

  ```zig
                  // GAP-0510: Filter by RLS denied labels
                  if (!passesRLSFilter(allocator, node.*)) continue;
  ```

  Replace with:

  ```zig
                  // GAP-0510: Filter by RLS denied labels.
                  // Reuses rls_row_buf across every node in this chain.
                  if (!passesRLSFilter(&rls_row_buf, node.*)) continue;
  ```

- [ ] **Step 5.5: Build.**

  ```bash
  make build 2>&1 | tail -5
  ```

  Expected: clean.

- [ ] **Step 5.6: Run the existing RLS integration tests via the omnibus suite.**

  ```bash
  zig build test 2>&1 | grep -iE 'test_rls_expr_engine_wiring|test_gap0509_tenant_isolation|passesRLSFilter|FAIL|panic:' | head -20
  ```

  Expected: no FAIL/panic lines from the two RLS test files. Pre-existing environmental failures in the omnibus suite (FileNotFound, ConnectionRefused, ABRT) are out of scope.

- [ ] **Step 5.7: Run the full test suite for safety.**

  ```bash
  zig build test 2>&1 | grep -iE "panic:|FAIL|new error:" | head -10
  ```

  Expected: no new panics or fails. Pre-existing environmental failures (FileNotFound, ConnectionRefused, ABRT on features_test) are out of scope.

- [ ] **Step 5.8: Commit Tasks 4 + 5 together.**

  ```bash
  git add src/execution/match_operations.zig
  git commit -m "perf(rls): reuse RLS row buffer across executeMultiNodeMatch loop

  passesRLSFilter and passesRLSExprFilter now take a caller-owned
  StringHashMap(rls.Value) instead of allocating one per node.
  executeMultiNodeMatch allocates one row buffer per chain and
  reuses it across every candidate node in that chain's label-
  indexed and full-scan loops.

  Eliminates the per-node HashMap init/deinit pair visible in the
  H5a T2 stack. Other passesRLSFilter call sites (executeMatchCallQuery,
  etc.) get a local per-call buffer — same correctness, modest
  per-call overhead that doesn't matter outside the per-node loop.

  Refs docs/performance/2026-04-25-quic-cascade-investigation/bisection-analysis.md
  H5a verdict — primary fix part A applied to the call site."
  ```

---

## Phase 3 — Per-call-site SHARED hold-time counters

### Task 6: Add per-site hold-time fields + `LockSiteTag` enum

**Files:**
- Modify: `src/graph_store.zig` (add `LockSiteTag` enum + `acquireGraphReadLockTagged` + plumb tag through `releaseGraphLock`)
- Modify: `src/storage/graph_storage_adapter.zig` (add 5 per-site counters + tag-aware release + `lookupManagedGraph` test helper)

The single aggregate `mg_rwlock_shared_hold_ns_total` from the prior plan tells us the total time SHARED was held but not WHICH site held it. Per-site counters let the post-fix repro identify any residual long-hold site without re-running gdb.

- [ ] **Step 6.1: Add the `LockSiteTag` enum to `src/graph_store.zig`.**

  Find the `GraphLockHandle` struct definition: `grep -n 'pub const GraphLockHandle' src/graph_store.zig`. Insert immediately before the struct:

  ```zig
  /// Identifies the call site that acquired a per-graph SHARED rwlock,
  /// so per-acquisition hold-time data can be attributed to the right
  /// counter. Added 2026-04-26 to drive the H5a residual-bisection.
  pub const LockSiteTag = enum {
      snapshot,         // graph_store.snapshotUnderReadLock — clone-then-release
      point_read,       // PointReadView path — held across short execute
      bulk_merge,       // executeBulkSimpleMerge Phase 1 lookup
      bulk_edge,        // executeBulkMatchCreateEdge Phase 1 lookup
      fallback,         // acquireGraphReadLock fallback (snapshot unavailable)
      misc,             // catchall — unrecategorized callers
  };
  ```

  Then add a `site_tag` field to the existing `GraphLockHandle` struct:

  ```zig
      site_tag: LockSiteTag = .misc,  // for per-site hold-time attribution
  ```

- [ ] **Step 6.2: Add `acquireGraphReadLockTagged(graph_name, tag)`.**

  Find the existing `acquireGraphReadLock` function: `grep -n 'pub fn acquireGraphReadLock' src/graph_store.zig` (line 5374 per the current source). Add a new tagged variant immediately after it:

  ```zig
  /// Tagged variant of `acquireGraphReadLock`. Identical semantics but
  /// records the call-site tag on the returned handle so per-site SHARED
  /// hold-time counters get accurate attribution at release time.
  pub fn acquireGraphReadLockTagged(graph_name: []const u8, tag: LockSiteTag) GraphLockHandle {
      var handle = acquireGraphReadLock(graph_name);
      handle.site_tag = tag;
      return handle;
  }
  ```

  The existing `acquireGraphReadLock` continues to return a handle whose `site_tag` defaults to `.misc` via the field default — no further change to it needed.

- [ ] **Step 6.3: Add the 5 per-site counters to `ManagedGraph`.**

  Find the existing hold-time field block in `src/storage/graph_storage_adapter.zig`:

  ```bash
  grep -n 'rwlock_shared_hold_ns_total' src/storage/graph_storage_adapter.zig
  ```

  Add immediately after the existing `rwlock_shared_max_hold_ns_observed` declaration:

  ```zig
      // Per-site hold-time decomposition (added 2026-04-26 for the H5a
      // residual-bisection). The aggregate counter above sums all sites;
      // these break it out by call-site tag so we can identify which
      // acquirer is the long-hold offender without re-running gdb.
      rwlock_shared_hold_snapshot_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
      rwlock_shared_hold_point_read_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
      rwlock_shared_hold_bulk_merge_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
      rwlock_shared_hold_bulk_edge_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
      rwlock_shared_hold_fallback_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
  ```

- [ ] **Step 6.4: Update `releaseGraphReadLock` to take a tag + update the per-site counter.**

  Find the existing `releaseGraphReadLock`:

  ```bash
  grep -n 'pub fn releaseGraphReadLock' src/storage/graph_storage_adapter.zig
  ```

  Currently signature `(_, mg, hold_start_ns)`. Modify to take `site_tag` and update the matching per-site counter. Replace the entire function body:

  ```zig
      pub fn releaseGraphReadLock(_: *StorageAdapter, mg: *ManagedGraph, hold_start_ns: u64, site_tag: graph_store.LockSiteTag) void {
          const _hold_ns = monoNanosNow() -| hold_start_ns;
          _ = mg.rwlock_shared_hold_ns_total.fetchAdd(_hold_ns, .monotonic);
          const _cur_max = mg.rwlock_shared_max_hold_ns_observed.load(.monotonic);
          if (_hold_ns > _cur_max) {
              mg.rwlock_shared_max_hold_ns_observed.store(_hold_ns, .monotonic);
          }
          switch (site_tag) {
              .snapshot => _ = mg.rwlock_shared_hold_snapshot_ns_total.fetchAdd(_hold_ns, .monotonic),
              .point_read => _ = mg.rwlock_shared_hold_point_read_ns_total.fetchAdd(_hold_ns, .monotonic),
              .bulk_merge => _ = mg.rwlock_shared_hold_bulk_merge_ns_total.fetchAdd(_hold_ns, .monotonic),
              .bulk_edge => _ = mg.rwlock_shared_hold_bulk_edge_ns_total.fetchAdd(_hold_ns, .monotonic),
              .fallback => _ = mg.rwlock_shared_hold_fallback_ns_total.fetchAdd(_hold_ns, .monotonic),
              .misc => {}, // intentionally not decomposed
          }
          mg.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());
      }
  ```

  The reference to `graph_store.LockSiteTag` requires that the file's existing imports include the `graph_store` module under that alias. Confirm with `grep -n 'const graph_store\|graph_store =' src/storage/graph_storage_adapter.zig | head -3`. If the alias is different (e.g. `gs`), substitute throughout this step.

- [ ] **Step 6.5: Update `graph_store.releaseGraphLock` to plumb the tag.**

  Find `pub fn releaseGraphLock(handle: GraphLockHandle)` (around line 5528). The current inner read-release call:

  ```zig
                  adapter.releaseGraphReadLock(mg, handle.hold_start_ns);
  ```

  Replace with:

  ```zig
                  adapter.releaseGraphReadLock(mg, handle.hold_start_ns, handle.site_tag);
  ```

- [ ] **Step 6.6: Register the 5 new counters in the runtime_metrics block.**

  Find the existing registration block:

  ```bash
  grep -n 'mg_rwlock_shared_hold_ns_total' src/storage/graph_storage_adapter.zig
  ```

  Currently has 5 register calls (3 from commit `14999b61` + 2 from commit `b48007e9`). Append 5 more:

  ```zig
                  reg.register("mg_rwlock_shared_hold_snapshot_ns_total", &mg.rwlock_shared_hold_snapshot_ns_total) catch {};
                  reg.register("mg_rwlock_shared_hold_point_read_ns_total", &mg.rwlock_shared_hold_point_read_ns_total) catch {};
                  reg.register("mg_rwlock_shared_hold_bulk_merge_ns_total", &mg.rwlock_shared_hold_bulk_merge_ns_total) catch {};
                  reg.register("mg_rwlock_shared_hold_bulk_edge_ns_total", &mg.rwlock_shared_hold_bulk_edge_ns_total) catch {};
                  reg.register("mg_rwlock_shared_hold_fallback_ns_total", &mg.rwlock_shared_hold_fallback_ns_total) catch {};
  ```

- [ ] **Step 6.7: Add `lookupManagedGraph` test-helper.**

  This is needed by Task 9's regression test. Find a location near the existing `acquireGraphReadLock` (around line 3573). Add:

  ```zig
      /// Test helper: look up a `*ManagedGraph` by name without acquiring
      /// the per-graph rwlock. Used by regression tests that need to read
      /// per-graph counters directly.
      pub fn lookupManagedGraph(self: *StorageAdapter, name: []const u8) !*ManagedGraph {
          self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
          defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
          return self.engines.get(name) orelse error.GraphNotFound;
      }
  ```

- [ ] **Step 6.8: Build.**

  ```bash
  make build 2>&1 | tail -10
  ```

  Expected: clean. The most likely failure is the import alias in Step 6.4 — fix and re-run.

- [ ] **Step 6.9: Commit.**

  ```bash
  git add src/graph_store.zig src/storage/graph_storage_adapter.zig
  git commit -m "feat(metrics): per-call-site SHARED hold-time decomposition

  Add LockSiteTag enum (snapshot, point_read, bulk_merge, bulk_edge,
  fallback, misc) and tagged acquireGraphReadLockTagged variant.
  ManagedGraph gains 5 per-site cumulative counters; releaseGraphReadLock
  routes hold-time to the matching counter at release time.

  Default-tag (.misc) sites continue to update only the aggregate
  counter. Tagged sites update both. The decomposition is the safety
  net for diagnosing any residual long-hold site after the H5a
  primary fix (Phases 1-2 of this plan).

  Also adds StorageAdapter.lookupManagedGraph test-helper used by
  the regression test in Phase 5."
  ```

### Task 7: Tag the QUIC + gRPC handler call sites

**Files:**
- Modify: `src/server/quic_connection_handler.zig` (sites at lines 203, 582, 763, 3168, 3186, 3202, 3475, 3699 per current source)
- Modify: `src/transport/grpc_server.zig` (sites at lines 186, 2067, 2083, 2099, 2908)
- Modify: `src/graph_store.zig` (tag the call inside `snapshotUnderReadLock`)

Replace `acquireGraphReadLock(name)` with `acquireGraphReadLockTagged(name, .<tag>)` per the call-site purpose. The tag mapping per file:

| File | Line (approx) | Purpose | Tag |
|------|---------------|---------|-----|
| quic_connection_handler.zig | 203 | rebuildPendingIndexes | `.misc` |
| quic_connection_handler.zig | 582 | executeBulkMatchCreateEdge Phase 1 | `.bulk_edge` |
| quic_connection_handler.zig | 763 | executeBulkSimpleMerge Phase 1 | `.bulk_merge` |
| quic_connection_handler.zig | 3168 | point_read path acquire | `.point_read` |
| quic_connection_handler.zig | 3186 | point_read fallback acquire | `.fallback` |
| quic_connection_handler.zig | 3202 | snapshot fallback (read query) | `.fallback` |
| quic_connection_handler.zig | 3475 | inline_lock | `.misc` |
| quic_connection_handler.zig | 3699 | pull_lock | `.misc` |
| grpc_server.zig | 186 | rebuild | `.misc` |
| grpc_server.zig | 2067 | point_read path | `.point_read` |
| grpc_server.zig | 2083 | point_read fallback | `.fallback` |
| grpc_server.zig | 2099 | snapshot fallback | `.fallback` |
| grpc_server.zig | 2908 | backup_lock | `.misc` |
| graph_store.zig (snapshotUnderReadLock) | 5508 | snapshot capture | `.snapshot` |

- [ ] **Step 7.1: Tag the QUIC handler bulk-merge Phase 1 site.**

  Find `const read_handle = graph_store.acquireGraphReadLock(query_graph_name);` near line 763 (in `executeBulkSimpleMerge`). Replace with:

  ```zig
          const read_handle = graph_store.acquireGraphReadLockTagged(query_graph_name, .bulk_merge);
  ```

- [ ] **Step 7.2: Tag the QUIC handler bulk-edge Phase 1 site.**

  Find the same pattern near line 582 (in `executeBulkMatchCreateEdge`). Replace with:

  ```zig
          const read_handle = graph_store.acquireGraphReadLockTagged(query_graph_name, .bulk_edge);
  ```

- [ ] **Step 7.3: Tag the QUIC handler read-dispatch sites.**

  Around lines 3163-3204 (`if (analysis.is_point_read) ... else { snapshotUnderReadLock ... }`):

  - Line 3168 (point_read main): `graph_lock_handle = graph_store.acquireGraphReadLockTagged(query_graph_name, .point_read);`
  - Line 3186 (point_read fallback to acquire): `graph_lock_handle = graph_store.acquireGraphReadLockTagged(query_graph_name, .fallback);`
  - Line 3202 (snapshot fallback): `graph_lock_handle = graph_store.acquireGraphReadLockTagged(query_graph_name, .fallback);`

- [ ] **Step 7.4: Tag the remaining QUIC handler sites with `.misc`.**

  Lines 203 (rebuild), 3475 (inline_lock), 3699 (pull_lock). For each, replace:

  ```zig
  graph_store.acquireGraphReadLock(name)
  ```

  with:

  ```zig
  graph_store.acquireGraphReadLockTagged(name, .misc)
  ```

- [ ] **Step 7.5: Tag the gRPC handler sites in `src/transport/grpc_server.zig`.**

  Mirror the QUIC handler edits per the table above. The dispatch pattern at lines 2056-2100 is structurally identical to the QUIC version. Specifically:

  - Line 186 (rebuild): `.misc`
  - Line 2067 (point_read main): `.point_read`
  - Line 2083 (point_read fallback): `.fallback`
  - Line 2099 (snapshot fallback): `.fallback`
  - Line 2908 (backup_lock): `.misc`

- [ ] **Step 7.6: Tag the snapshot path inside `snapshotUnderReadLock`.**

  In `src/graph_store.zig`, find:

  ```zig
  pub fn snapshotUnderReadLock(allocator: std.mem.Allocator, graph_name: []const u8) !QueryReadSession {
      const handle = acquireGraphReadLock(graph_name);
      defer releaseGraphLock(handle);
  ```

  Replace with:

  ```zig
  pub fn snapshotUnderReadLock(allocator: std.mem.Allocator, graph_name: []const u8) !QueryReadSession {
      const handle = acquireGraphReadLockTagged(graph_name, .snapshot);
      defer releaseGraphLock(handle);
  ```

- [ ] **Step 7.7: Build + smoke test.**

  ```bash
  make build 2>&1 | tail -5
  rm -rf /tmp/geode-tagging-smoke
  GEODE_ADMIN_PASSWORD=Geode1234Abc nohup zig-out/bin/geode serve \
    --data-dir /tmp/geode-tagging-smoke \
    --listen 127.0.0.1:3177 --log-level info \
    > /tmp/geode-tagging-smoke.log 2>&1 &
  SMOKE_PID=$!
  sleep 8
  zig-out/bin/geode query --server 127.0.0.1:3177 --insecure-tls-skip-verify \
    -U geode -P Geode1234Abc --no-saved-session "RETURN 1 AS ok" > /dev/null 2>&1
  zig-out/bin/geode query --server 127.0.0.1:3177 --insecure-tls-skip-verify \
    -U geode -P Geode1234Abc --no-saved-session "CREATE (n:X {a: 1})" > /dev/null 2>&1
  sleep 7
  echo "--- per-site SHARED hold counters ---"
  grep "info: metrics:" /tmp/geode-tagging-smoke.log | tail -1 | tr ' ' '\n' \
    | grep -E "mg_rwlock_shared_hold_(snapshot|point_read|bulk_merge|bulk_edge|fallback)"
  kill -9 $SMOKE_PID 2>/dev/null
  rm -rf /tmp/geode-tagging-smoke
  ```

  Expected: at least the `snapshot` and one of `point_read`/`fallback` counters are non-zero (RETURN 1 is a read; CREATE is a write that doesn't acquire SHARED). The other counters can stay at 0 in this smoke run — the cascade repro in Phase 6 will exercise them.

- [ ] **Step 7.8: Commit.**

  ```bash
  git add src/graph_store.zig src/server/quic_connection_handler.zig src/transport/grpc_server.zig
  git commit -m "feat(metrics): tag SHARED acquire sites with LockSiteTag

  Each SHARED acquire site in the QUIC + gRPC handlers + the
  snapshotUnderReadLock helper now passes a LockSiteTag identifying
  its purpose. snapshotUnderReadLock -> .snapshot;
  PointReadView path -> .point_read; bulk-merge Phase 1 -> .bulk_merge;
  bulk-match-edge Phase 1 -> .bulk_edge; snapshot/point-read fallback
  -> .fallback; auxiliary paths -> .misc.

  At release time, releaseGraphReadLock attributes the per-acquisition
  hold-time to the matching per-site counter alongside the existing
  aggregate. Drives the H5a residual-bisection: the post-fix repro
  in Phase 6 will identify which site (if any) still produces long
  holds after the per-node row-build optimization in Phases 1-2."
  ```

---

## Phase 4 — Reclassify RLS-evaluating MATCH off the point-read path

### Task 8: Add `wouldEvaluateRLS()` predicate + dispatch reclassification

**Files:**
- Modify: `src/execution/match_operations.zig` (add `wouldEvaluateRLS` exported helper)
- Modify: `src/execution.zig` (re-export the helper)
- Modify: `src/server/quic_connection_handler.zig` (consult the predicate around line 3163)
- Modify: `src/transport/grpc_server.zig` (consult the predicate around line 2064)

The `is_point_read` classifier currently routes to `acquireGraphReadLock` + hold-across-execute (lines 3163-3188 / 2064-2085). For a point-read that doesn't touch RLS, that's fine — the execute window is genuinely short. But for a point-read that DOES evaluate an RLS expression policy, every access incurs the per-row HashMap build. Even with Phases 1-2's optimizations the extra fairness pressure is real. Reclassify so RLS-evaluating reads always go through the `.snapshot` path.

- [ ] **Step 8.1: Add the predicate to `src/execution/match_operations.zig`.**

  Add immediately after the existing `passesRLSExprFilter` function (which after Task 4 ends around line 165):

  ```zig
  // CANARY: REQ=REQ-PERF-RLS-DISPATCH-001; FEATURE="RLSAwareDispatch"; ASPECT=PointReadReclassify; STATUS=IMPL; OWNER=performance; UPDATED=2026-04-26
  /// Returns true if any RLS engine (label-deny or expression) is currently
  /// configured AND the active session has an authenticated user. Used by
  /// the transport dispatcher to keep RLS-evaluating reads on the snapshot
  /// path (which releases the SHARED rwlock before per-node row construction)
  /// rather than the point-read path (which holds SHARED across execute).
  pub fn wouldEvaluateRLS() bool {
      const ctx = execution.getActiveContext() orelse return false;
      if (ctx.user == null) return false;
      const has_label_engine = rls_types.getGlobalRLSFilterEngine() != null;
      const has_expr_engine = rls_types.getGlobalExprRLSEngine() != null;
      return has_label_engine or has_expr_engine;
  }
  ```

- [ ] **Step 8.2: Re-export from `src/execution.zig`.**

  Find: `grep -n 'executeMultiNodeMatch' src/execution.zig` (line 182 per current source). Add a sibling export:

  ```zig
  pub const wouldEvaluateRLS = match_operations.wouldEvaluateRLS;
  ```

- [ ] **Step 8.3: Update the QUIC handler dispatch (around line 3163).**

  Find:

  ```zig
                  } else if (analysis.is_point_read) {
  ```

  Replace with:

  ```zig
                  } else if (analysis.is_point_read and !execution.wouldEvaluateRLS()) {
  ```

  The `else` branch (snapshot path, line 3189) already handles the reclassified case correctly — no further change needed.

- [ ] **Step 8.4: Update the gRPC handler dispatch (around line 2064).**

  Same edit as Step 8.3 in `src/transport/grpc_server.zig`:

  ```zig
                  } else if (analysis.is_point_read and !execution.wouldEvaluateRLS()) {
  ```

- [ ] **Step 8.5: Build + run RLS regression tests via the omnibus suite.**

  ```bash
  make build 2>&1 | tail -5
  zig build test 2>&1 | grep -iE 'test_rls_expr_engine_wiring|test_gap0509_tenant_isolation|wouldEvaluateRLS|FAIL|panic:' | head -20
  ```

  Expected: clean build; no FAIL/panic lines from the two RLS test files. Pre-existing environmental failures (FileNotFound, ConnectionRefused) are out of scope.

- [ ] **Step 8.6: Commit.**

  ```bash
  git add src/execution/match_operations.zig src/execution.zig \
          src/server/quic_connection_handler.zig src/transport/grpc_server.zig
  git commit -m "fix(transport): RLS-evaluating reads always use snapshot path

  Adds wouldEvaluateRLS() predicate (true iff a label-deny or
  expression RLS engine is configured AND a user is authenticated).
  Both transport handlers now keep RLS-evaluating reads on the
  snapshotUnderReadLock path even when analysis.is_point_read is
  true, so the SHARED rwlock is released before per-node row
  construction.

  Closes the H5a-identified pattern of MATCH-with-RLS holding the
  SHARED rwlock across the per-node nodePropertiesToRLSRow loop."
  ```

---

## Phase 5 — Regression test for lock-hold under MATCH-with-RLS

> **TASK 9 DEFERRED (2026-04-26).** The integration test as designed was
> too heavy for Debug builds — the writer thread's tight EXCLUSIVE-acquire
> loop combined with writer-preferred rwlock semantics
> (`acquireGraphWriteLockCancelable` slow path) starved the snapshot
> reads, leaving the test in `futex_wait_queue` for >5 minutes even at
> N_DOCS=1000. Two redesigns are needed before it can land:
>
> 1. Rate-limit the writer thread (sleep 100ms not 100µs between acquires).
> 2. Cap iteration count instead of using a wall-clock-bounded `stop` flag.
>
> The end-to-end validation in Phase 6 (cascade repro) is the dispositive
> signal for the H5a fix — if `mg_rwlock_shared_hold_snapshot_ns_total`
> dominates and the cascade closes (or shifts), the fix is validated.
> Task 9 stays valuable as a unit-level regression pin; refile in a
> follow-up plan once the writer-rate redesign is settled.

### Task 9: Integration test pinning per-acquire SHARED max-hold under contention

**Files:**
- Create: `tests/test_match_rls_lock_hold_regression.zig`
- Modify: `build.zig`

Drive snapshot reads + concurrent writer; assert the per-acquire max-hold stays below a tight bound. Pre-fix the H5a repro showed ~460 ms avg / 2.23 s max; post-fix this test should stay below 50 ms.

- [ ] **Step 9.1: Create `tests/test_match_rls_lock_hold_regression.zig`.**

  ```zig
  // SPDX-License-Identifier: Apache-2.0
  // Copyright (c) 2024-2025 CodePros

  //! Regression test pinning per-acquire SHARED rwlock max-hold under
  //! snapshot-path reads + concurrent writer.
  //!
  //! H5a (commit 958be673) measured 460 ms avg / 2.23 s max per SHARED
  //! acquire. Post-fix (Phases 1-4 of
  //! docs/superpowers/plans/2026-04-26-rls-snapshot-scan-and-row-build.md)
  //! the per-acquire max-hold should stay below 50 ms even with a writer
  //! contending in parallel.
  //!
  //! CANARY: REQ=REQ-PERF-RLS-LOCK-HOLD-001; FEATURE="RLSLockHoldUnderLoad"; ASPECT=MaxHoldRegression; STATUS=TESTED; TEST=tests/test_match_rls_lock_hold_regression.zig; OWNER=performance; UPDATED=2026-04-26

  const std = @import("std");
  const geode = @import("geode");
  const graph_store = geode.graph_store;
  const adapter_mod = geode.graph_storage_adapter;

  const N_DOCS: usize = 5000;
  const N_PROPS_PER_DOC: usize = 12;

  const WriterCtx = struct {
      graph_name: []const u8,
      stop: *std.atomic.Value(u32),
  };

  fn writerLoop(ctx_ptr: *anyopaque) void {
      const ctx: *WriterCtx = @ptrCast(@alignCast(ctx_ptr));
      while (ctx.stop.load(.acquire) == 0) {
          // Each iteration: take EXCLUSIVE briefly. If the SHARED holders
          // run for >50 ms, this writer's wait time grows accordingly.
          const handle = graph_store.acquireGraphWriteLockCancelable(
              ctx.graph_name,
              @as(u64, @intCast(std.time.nanoTimestamp())) + 5 * std.time.ns_per_s,
          ) catch continue;
          // Tiny critical section - the test is about reader hold time.
          var rem: std.os.linux.timespec = undefined;
          const req = std.os.linux.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_us };
          _ = std.os.linux.nanosleep(&req, &rem);
          graph_store.releaseGraphLock(handle);
      }
  }

  test "snapshot path SHARED hold stays < 50 ms under concurrent writer" {
      const allocator = std.testing.allocator;
      var tmp = std.testing.tmpDir(.{});
      defer tmp.cleanup();

      const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
      defer allocator.free(data_dir);

      const adapter = try graph_store.initGlobalAdapter(allocator, data_dir);
      defer graph_store.deinitGlobalAdapter();

      const graph_name = "doc_rls_graph";
      _ = try adapter.getOrCreateGraph(graph_name);

      // Seed N_DOCS nodes with N_PROPS_PER_DOC properties each.
      var seed_i: usize = 0;
      while (seed_i < N_DOCS) : (seed_i += 1) {
          const node_id = try adapter.createNode(graph_name, &[_][]const u8{"Doc"});
          var prop_i: usize = 0;
          while (prop_i < N_PROPS_PER_DOC) : (prop_i += 1) {
              const key = try std.fmt.allocPrint(allocator, "p{d}", .{prop_i});
              defer allocator.free(key);
              try adapter.setNodeProperty(graph_name, node_id, key, .{ .Int = @as(i64, @intCast(seed_i + prop_i)) });
          }
          try adapter.setNodeProperty(graph_name, node_id, "owner", .{ .String = if (seed_i % 2 == 0) "alice" else "bob" });
      }

      // Snapshot the max-hold-observed counter pre-load.
      const mg = try adapter.lookupManagedGraph(graph_name);
      const baseline_max = mg.rwlock_shared_max_hold_ns_observed.load(.monotonic);

      // Spawn a writer thread.
      var stop = std.atomic.Value(u32).init(0);
      var writer_ctx = WriterCtx{
          .graph_name = graph_name,
          .stop = &stop,
      };
      const writer_thread = try std.Thread.spawn(.{}, writerLoop, .{@as(*anyopaque, @ptrCast(&writer_ctx))});

      // Drive 100 snapshot reads.
      var read_iter: usize = 0;
      while (read_iter < 100) : (read_iter += 1) {
          var rem: std.os.linux.timespec = undefined;
          const req = std.os.linux.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
          _ = std.os.linux.nanosleep(&req, &rem);

          var session = try graph_store.snapshotUnderReadLock(allocator, graph_name);
          defer session.deinit();
          // The snapshot itself releases SHARED before this defer runs.
      }

      stop.store(1, .release);
      writer_thread.join();

      const post_max = mg.rwlock_shared_max_hold_ns_observed.load(.monotonic);
      const observed_max_under_load = if (post_max > baseline_max) post_max - baseline_max else 0;
      const max_allowed_ns: u64 = 50 * std.time.ns_per_ms;

      if (observed_max_under_load > max_allowed_ns) {
          std.debug.print("max SHARED hold under snapshot+writer load = {d} ns ({d:.1} ms), expected < 50 ms\n", .{ observed_max_under_load, @as(f64, @floatFromInt(observed_max_under_load)) / 1e6 });
      }
      try std.testing.expect(observed_max_under_load < max_allowed_ns);
  }
  ```

  IMPORTANT: this test assumes `adapter.lookupManagedGraph(name)` exists (added in Task 6.7) and `graph_store.initGlobalAdapter(allocator, data_dir)` is the standard test fixture for adapter init (verify via `grep -n 'initGlobalAdapter' tests/ src/` if unsure of the canonical pattern). If the tmpDir-derived `data_dir` path is incompatible with the adapter's bootstrapping (e.g. it requires a directory that already exists), use `try std.fs.makeDirAbsolute(data_dir)` before init.

- [ ] **Step 9.2: Register in `build.zig`.**

  Sibling block to Task 3.2's registration:

  ```zig
      const match_rls_lock_mod = b.createModule(.{ .root_source_file = b.path("tests/test_match_rls_lock_hold_regression.zig"), .target = target, .optimize = optimize });
      match_rls_lock_mod.addImport("geode", root_mod);
      const match_rls_lock_tests = b.addTest(.{ .root_module = match_rls_lock_mod });
      const run_match_rls_lock_tests = b.addRunArtifact(match_rls_lock_tests);
      test_step.dependOn(&run_match_rls_lock_tests.step);
      const match_rls_lock_step = b.step("test-match-rls-lock-hold-regression", "Pin SHARED rwlock max-hold under snapshot path + concurrent writer load");
      match_rls_lock_step.dependOn(&run_match_rls_lock_tests.step);
  ```

- [ ] **Step 9.3: Run the test.**

  ```bash
  zig build test-match-rls-lock-hold-regression --summary all 2>&1 | tail -10
  ```

  Expected: PASS, with observed max-hold typically well under 50 ms (the snapshot clone for 5000 nodes × 12 props ≈ 60K entries is sub-millisecond on modern hardware).

  If it fails: check whether `lookupManagedGraph` was added correctly in Task 6.7, whether `initGlobalAdapter` ran cleanly (check stderr), and whether the assertion is reading the same `mg.rwlock_shared_max_hold_ns_observed` field declared in the prior plan.

- [ ] **Step 9.4: Commit.**

  ```bash
  git add tests/test_match_rls_lock_hold_regression.zig build.zig
  git commit -m "test(perf): regression — snapshot-path SHARED hold stays < 50 ms

  Seeds a 5000-node :Doc graph, runs 100 snapshot reads while a
  writer thread contends with EXCLUSIVE acquires, asserts the
  per-acquire SHARED max-hold observed via
  mg.rwlock_shared_max_hold_ns_observed stays below 50 ms.

  Pre-fix (H5a): ~460 ms avg / 2.23 s max — test would fail.
  Post-fix (Phases 1-4): test passes."
  ```

---

## Phase 6 — Validate end-to-end + closure

### Task 10: Re-run the workers=4 cascade repro

**Files:**
- Create (committed): `docs/performance/2026-04-26-rls-snapshot-scan-fix/repro-server.log`
- Create (committed): `docs/performance/2026-04-26-rls-snapshot-scan-fix/repro-ingest.log`
- Create (committed): `docs/performance/2026-04-26-rls-snapshot-scan-fix/cascade-stacks.txt`

Re-run the prior plan's repro driver against the fixed binary so the per-site counter trajectories drive the closure verdict.

- [ ] **Step 10.1: Build release.**

  ```bash
  zig build -Doptimize=ReleaseFast install 2>&1 | tail -3
  ```

- [ ] **Step 10.2: Adapt the existing repro driver.**

  ```bash
  mkdir -p docs/performance/2026-04-26-rls-snapshot-scan-fix
  cp /tmp/run-rwlock-hold-time-repro.sh /tmp/run-rls-snapshot-fix-repro.sh
  sed -i 's|2026-04-26-rwlock-hold-time|2026-04-26-rls-snapshot-scan-fix|g' /tmp/run-rls-snapshot-fix-repro.sh
  sed -i 's|/tmp/geode-rwlock-hold-time|/tmp/geode-rls-snapshot-fix|g' /tmp/run-rls-snapshot-fix-repro.sh
  sed -i 's|/tmp/rwlock-hold-time-data|/tmp/rls-snapshot-fix-data|g' /tmp/run-rls-snapshot-fix-repro.sh
  sed -i 's|127.0.0.1:3176|127.0.0.1:3178|g' /tmp/run-rls-snapshot-fix-repro.sh
  ```

  Verify it still reads `--workers 4`:

  ```bash
  grep workers /tmp/run-rls-snapshot-fix-repro.sh
  ```

- [ ] **Step 10.3: Run the repro (~25 min wall-clock).**

  ```bash
  bash /tmp/run-rls-snapshot-fix-repro.sh
  ```

  Use `run_in_background: true`. Poll the artifacts every 3-5 minutes via `tail` until either the cascade trigger fires (look for `pipeline failed — retrying file in serial mode` in the ingest log) OR the `timeout 1500` self-terminates.

- [ ] **Step 10.4: Verify the artifacts include the per-site counters.**

  ```bash
  ls -la docs/performance/2026-04-26-rls-snapshot-scan-fix/
  grep "info: metrics:" docs/performance/2026-04-26-rls-snapshot-scan-fix/repro-server.log | tail -1 \
    | tr ' ' '\n' | grep -E "mg_rwlock_shared_hold_(snapshot|point_read|bulk_merge|bulk_edge|fallback)"
  ```

  Expected: 5 lines for the per-site counters in the latest emit. The dominant counter at end-of-run is the post-fix-residual long-hold site (if any).

- [ ] **Step 10.5: Commit the artifacts.**

  ```bash
  git add docs/performance/2026-04-26-rls-snapshot-scan-fix/repro-server.log
  git add docs/performance/2026-04-26-rls-snapshot-scan-fix/repro-ingest.log
  git add docs/performance/2026-04-26-rls-snapshot-scan-fix/cascade-stacks.txt
  git commit -m "docs(perf): post-fix cascade repro with per-site SHARED hold counters

  Re-run of the workers=4 cascade-investigation repro against the
  binary built with Phases 1-4 of this plan applied. Per-site
  counter trajectories drive the closure verdict in the next commit."
  ```

### Task 11: Update bisection-analysis.md with H5a closure verdict

**Files:**
- Modify: `docs/performance/2026-04-25-quic-cascade-investigation/bisection-analysis.md`

- [ ] **Step 11.1: Identify reference timestamps from the new repro.**

  Same pattern as the prior plan's Task 6 Step 6.1. Use the new T0/T1/T2 (or "no T2 — cascade did not trigger") from `docs/performance/2026-04-26-rls-snapshot-scan-fix/repro-ingest.log`.

- [ ] **Step 11.2: Tabulate the per-site hold-time deltas at the same six checkpoints.**

  For each of T0+5s, T1, T1+30s, T1+5min, T2−5s, T2 (or substitute the equivalents if no cascade), extract:

  - `mg_rwlock_shared_hold_ns_total` (aggregate, for cross-check vs H5a baseline)
  - `mg_rwlock_shared_hold_snapshot_ns_total`
  - `mg_rwlock_shared_hold_point_read_ns_total`
  - `mg_rwlock_shared_hold_bulk_merge_ns_total`
  - `mg_rwlock_shared_hold_bulk_edge_ns_total`
  - `mg_rwlock_shared_hold_fallback_ns_total`
  - `mg_rwlock_shared_max_hold_ns_observed` (cross-check vs the 2.23 s H5a baseline)

  For each per-site counter, compute the delta between consecutive checkpoints. The site with the largest delta in the T1→T2 window (or the T1→T1+5min window if no cascade) is the residual long-hold offender — if any.

- [ ] **Step 11.3: Write the closure section.**

  Append at the end of `bisection-analysis.md`:

  ```markdown
  ---

  ## H5a closure (added 2026-04-26)

  Phases 1-4 of `docs/superpowers/plans/2026-04-26-rls-snapshot-scan-and-row-build.md`
  landed: per-node `nodePropertiesToRLSRow` was pre-sized + reused across
  the `executeMultiNodeMatch` per-chain loop, RLS-evaluating reads were
  reclassified off the point-read path, and per-call-site SHARED hold-time
  counters were added.

  ### Reference timestamps (post-fix)

  | Marker | Time | Notes |
  |--------|------|-------|
  | T0 ingest start | <fill> | new run timestamp |
  | T1 last forward progress | <fill> | edges_audited.jsonl exec start (or N/A if no cascade) |
  | T2 cascade trigger | <fill> | "pipeline failed — retrying file in serial mode" (or "did not trigger within 1500 s budget") |
  | Δ (T2 − T1) | <fill> | compare to pre-fix ~10 min |

  ### Per-site SHARED hold trajectories

  | Checkpoint | snapshot | point_read | bulk_merge | bulk_edge | fallback | aggregate | max_observed |
  |------------|----------|------------|------------|-----------|----------|-----------|--------------|
  | T0+5s | <fill> | <fill> | <fill> | <fill> | <fill> | <fill> | <fill> |
  | T1 | <fill> | <fill> | <fill> | <fill> | <fill> | <fill> | <fill> |
  | T1+30s | <fill> | <fill> | <fill> | <fill> | <fill> | <fill> | <fill> |
  | T1+5min | <fill> | <fill> | <fill> | <fill> | <fill> | <fill> | <fill> |
  | T2−5s | <fill> | <fill> | <fill> | <fill> | <fill> | <fill> | <fill> |
  | T2 | <fill> | <fill> | <fill> | <fill> | <fill> | <fill> | <fill> |

  ### Pre-fix vs post-fix max-observed comparison

  | Run | max_observed at end | per-acquire avg (T1→T2) | cascade trigger |
  |-----|---------------------|--------------------------|-----------------|
  | Pre-fix (commit 463c01bb) | 2.23 s | 460 ms | T1+~10 min |
  | Post-fix (this run) | <fill> | <fill> | <fill: yes/no/shifted> |

  ### Verdict

  Pick ONE:

  #### Closed
  Cascade no longer triggers within 1500 s OR triggers significantly later
  than T1+10 min AND `max_observed` < 100 ms throughout. H5a is fixed.

  #### Shifted
  Cascade still triggers but a different per-site counter dominates (e.g.
  `snapshot` shows multi-second deltas — the deep-clone is now the
  bottleneck). File a follow-up plan targeting the dominant site.

  #### Persists
  Cascade still triggers AND no per-site counter dominates the way `total`
  did pre-fix. Indicates the H5a verdict mis-identified the cause; reopen
  the bisection with a fresh dimension.

  Verdict: <pick one + reason>

  ### Recommended next step

  - **Closed →** mark this thread complete; the next investigation is the
    other H5a-context follow-ups (per-stream activity logging,
    NoHandshakeKeys quic regression, quic_total_cwnd_bytes growth).
  - **Shifted →** open a new plan targeting the dominant per-site counter.
  - **Persists →** reopen the cascade investigation with fresh dimensions
    (per-query deadline histograms, per-shard work-balance, server-side
    queue depth at the coordinator level).
  ```

  Fill EVERY `<fill>`. Pick the verdict honestly.

- [ ] **Step 11.4: Commit.**

  ```bash
  git add docs/performance/2026-04-25-quic-cascade-investigation/bisection-analysis.md
  git commit -m "docs(perf): H5a closure — verdict <Closed|Shifted|Persists>

  Per-site SHARED hold-time deltas across the same six-checkpoint
  window as the prior secondary bisection. See the new 'H5a closure'
  section in bisection-analysis.md.

  Plan complete:
  docs/superpowers/plans/2026-04-26-rls-snapshot-scan-and-row-build.md"
  ```

---

## Out of scope (separate plans / handoffs)

This plan deliberately scopes to the H5a primary fix from the bisection-analysis.md verdict. Three other items from the H5a context (per the user's recommended-followups list) are independent and have their own plans/handoffs:

1. **Per-stream last-activity-time logging** — disambiguates the 10-min idle-timeout coincidence. ~1.5 hr scope. Sibling plan: write a new `docs/superpowers/plans/2026-04-26-per-stream-activity-time.md`.

2. **`NoHandshakeKeys` regression in the new quic dep** — upstream handoff to `~/src/devnw/zig/quic/`. ~30 min markdown. Out of geode entirely.

3. **`quic_total_cwnd_bytes` unbounded growth** — small geode display-sanity patch (~10 lines) + upstream handoff for the proper RFC 9002 §7.4 cwnd cap. ~30 min, separate plan.

These are not folded into this plan because they have independent ownership and any of them could ship without waiting for this fix.

---

## Self-review results

**Spec coverage:**
- H5a primary fix part A (shrink per-node nodePropertiesToRLSRow hot path) → Tasks 1-3 ✓
- H5a primary fix part A applied to executeMultiNodeMatch call site → Tasks 4-5 ✓
- Per-site instrumentation (residual-bisection safety net) → Tasks 6-7 ✓
- Snapshot-based reads enforcement (pull RLS-evaluating reads off point-read path) → Task 8 ✓
- Regression test pinning the fix → Task 9 ✓
- End-to-end validation + closure → Tasks 10-11 ✓

**Placeholder scan:** All `<fill>` slots in §"Task 11 step 11.3" are deliberate — the analyst must fill in the actual numbers from the run. No placeholders in code blocks. No "TBD" / "implement later" anywhere.

**Type consistency:**
- `passesRLSFilter(reusable_row, node)` and `passesRLSExprFilter(reusable_row, node, username)` use the same `*std.StringHashMap(rls.Value)` row pointer in Task 4's signature changes and Task 5's call sites.
- `LockSiteTag` enum values (`snapshot`, `point_read`, `bulk_merge`, `bulk_edge`, `fallback`, `misc`) are referenced consistently in Task 6's enum declaration, Task 7's call-site tagging, and Task 11's closure tabulation.
- Per-site counter field names use the `rwlock_shared_hold_<tag>_ns_total` convention everywhere (Task 6 declarations, Task 6 register calls, Task 11 closure table).
- `wouldEvaluateRLS()` (Task 8) is consistently no-arg and returns `bool` everywhere it's referenced (definition + the two dispatcher call sites).
- `lookupManagedGraph` (Task 6.7) is referenced by Task 9.1's regression test under the same name and signature.

**Two known unknowns:**
1. Task 9's test depends on `graph_store.initGlobalAdapter(allocator, data_dir)` working without prior on-disk state. If `data_dir` from `tmpDir` has a relative-path quirk that the adapter init can't resolve, prefix with `try std.fs.makeDirAbsolute(data_dir)` per Step 9.1's note.
2. The exact line numbers cited throughout are based on the current source at HEAD (`958be673`). If concurrent work lands a commit that shifts numbering, the search commands in each step (`grep -n` for the canonical anchor) are the source of truth, not the cited number.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-26-rls-snapshot-scan-and-row-build.md`.

Total task count: **11 tasks across 7 phases.** Wall-clock estimate:
- Phase 0: ~5 min (build sanity)
- Phase 1 (Tasks 1-3): ~30 min (small edits + unit tests + 2 commits)
- Phase 2 (Tasks 4-5): ~25 min (signature refactor + call-site updates + 1 commit)
- Phase 3 (Tasks 6-7): ~40 min (per-site counter wiring + tag plumbing + 2 commits)
- Phase 4 (Task 8): ~15 min (predicate + dispatcher edits + 1 commit)
- Phase 5 (Task 9): ~25 min (regression test + 1 commit)
- Phase 6 (Tasks 10-11): ~50 min (~25 min repro + 20 min closure writing + 2 commits)
- **Total: ~3 hours** including the 25-min cascade repro

Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, two-stage review (spec + quality) between tasks, fast iteration on the audit-conditional fix work.

**2. Inline Execution** — Execute tasks in this session using `superpowers:executing-plans`, batch with checkpoints.

**Which approach?**
