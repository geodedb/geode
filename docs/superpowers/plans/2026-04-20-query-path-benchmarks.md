# Geode Query-Path Benchmark Framework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an extensive, thread-pool-style benchmark suite that measures the Geode **query parser, planner, and executor** in isolation and end-to-end, publish a full baseline, then turn the profiling output into a ranked list of application-code bottlenecks to attack.

**Architecture:**

1. **Framework first (M0)** — port thread-pool's `benchmarks/common.zig` pattern to a geode-specific `benchmarks/common_query.zig` that owns `QueryScenarioSpec` + `runQueryScenario` + extended `ResultRow` (query-path metrics: parse_ns, plan_ns, execute_ns, materialize_ns, row_count, plan_cache_hit_rate, alloc_count, alloc_bytes, peak_rss_delta). Reuse the M0.4 `bench_schema.ResultDocument` for JSON output.
2. **Three measurement layers (M1–M3)** — parser-only, planner-only, executor-only (in-process, bypass QUIC). Each layer has its own bench exe with a fixed catalog of representative query shapes. Deterministic dataset seeding (copied from loadtest scenarios) so results are reproducible.
3. **End-to-end harness (M4)** — a `bench_query_e2e.zig` that stitches parse → plan → execute with full JSON output, plus `scripts/query-perf-gate.sh` that drives before/after A/B across all three layers and emits `diff.md` via the existing `zig build compare-bench` noise gate.
4. **Baseline + bottleneck report (M5)** — freeze a baseline JSON, run the full matrix, aggregate the profile + per-layer timings into `FINAL.md` with a ranked bottleneck list (top-5 opportunities by expected QPS impact).
5. **CI wiring (M6)** — add a `bench-query-path` stage to `.gitlab-ci.yml` using the existing compare-bench infrastructure. Starts warning-only, flips to blocking once the baseline stabilizes.

**Tech Stack:** Zig 0.16.0, existing `benchmarks/bench_schema.zig` (`ResultRow`/`ResultDocument`), `zig build compare-bench` (M0.6), `scripts/perf-gate.sh` (M0.7), `compare_ab.py` (M0.8), Python 3.12 for test glue.

**Plan-level reference artifacts:**

- Framework reference: `~/src/devnw/zig/thread-pool/benchmarks/common.zig` + `benchmarks/compare.zig` + `scripts/perf-gate.sh`
- Existing geode harness: `benchmarks/bench_schema.zig`, `benchmarks/compare_bench.zig`, `scripts/perf-gate.sh`, `tests/perf/`
- Source under measurement: `src/gql/parser.zig`, `src/planner/*`, `src/query/query_traits.zig`, `src/execution/planned_read_runtime.zig`, `src/execution/match_operations.zig`
- Prior profile outputs to build on: `docs/performance/2026-04-19-qps-closure/step-{1,2,3,4}-*.md`

**Per-step artifact directory:** `docs/performance/2026-04-20-query-bench/`. Every milestone's JSON outputs, diff.md, and profile reports live here. Final roll-up is `docs/performance/2026-04-20-query-bench/FINAL.md`.

**Worktree:** This plan runs on `perf/query-bench-2026-04-20`. Create with `git worktree add ../geode-query-bench -b perf/query-bench-2026-04-20` before Task 0.1.

---

## File structure (new and modified)

**New files (framework — M0):**
- `benchmarks/common_query.zig` — `QueryScenarioSpec`, `runQueryScenario`, `QueryResultRow`, dataset-seed helpers, warmup loop. Mirrors thread-pool's `common.zig`.
- `benchmarks/query_datasets.zig` — deterministic seed routines (`seedPerson(n)`, `seedPersonKnowsGraph(n, edges_per)`, `seedFanOut(...)`). Called by the benches; same data shapes as the loadtest scenarios.
- `tests/perf/test_common_query.zig` — unit tests for ScenarioSpec default values, QueryResultRow JSON serialization round-trip, dataset determinism.

**New files (measurement benches — M1/M2/M3):**
- `benchmarks/bench_parser.zig` — parse-only throughput for 10 canonical query shapes (ping, point_read inline-prop, point_read WHERE, one_hop, two_hop, fan_out, aggregation, DISTINCT, ORDER BY + LIMIT, UNION).
- `benchmarks/bench_planner.zig` — parse + plan for the same 10 shapes, reports plan_ns per shape plus plan cache hit rate over N iterations.
- `benchmarks/bench_executor_match.zig` — parse + plan + execute in-process (no QUIC) for the same 10 shapes, on fixed dataset sizes (500, 2000, 10000 nodes).
- `benchmarks/bench_executor_mutation.zig` — CREATE (single node), CREATE (batch 100), SET, DELETE, MERGE. Measures mutation-path cost separately from read-path.
- `benchmarks/bench_query_e2e.zig` — end-to-end harness: start an in-process server, drive through the QUIC client, report full-stack latency. Complements the out-of-process loadtest.

**New files (tests — M1/M2/M3):**
- `tests/perf/test_bench_parser.zig` — smoke-tests each parser scenario runs and emits a valid ResultRow.
- `tests/perf/test_bench_planner.zig` — planner smoke + cache hit-rate assertion.
- `tests/perf/test_bench_executor_match.zig` — match-exec smoke.
- `tests/perf/test_bench_executor_mutation.zig` — mutation-exec smoke.
- `tests/perf/test_bench_query_e2e.zig` — e2e smoke (marked slow, opt-in via env var).

**New files (A/B harness — M4):**
- `scripts/query-perf-gate.sh` — runs all query benches before/after, emits `diff.md`. Extends `scripts/perf-gate.sh` idioms with `LOADTEST_SCENARIOS` equivalent (`QUERY_BENCHES=...`).

**New files (CI — M6):**
- `.gitlab-ci.yml` — add `bench-query-path` job.

**Modified files:**
- `build.zig` — register the 5 new bench exes + 5 new test files + new `zig build bench-query-{parser,planner,executor-match,executor-mutation,e2e}` steps + a `bench-query-all` aggregate.
- `benchmarks/bench_schema.zig` — **no change**. We reuse `ResultRow`/`ResultDocument` as-is; `common_query.zig` adds a `QueryResultRow` *specialization* via embedding + extra fields.

**New docs:**
- `docs/performance/2026-04-20-query-bench/README.md` — per-plan artifact index.
- `docs/performance/2026-04-20-query-bench/query-bench-design.md` — scenario catalog, metrics schema, noise gate choices.
- `docs/performance/2026-04-20-query-bench/baseline/*.json` — initial baseline captures.
- `docs/performance/2026-04-20-query-bench/FINAL.md` — ranked bottleneck report (M5 close-out).

---

## Milestone 0 — Framework: `common_query.zig` + `query_datasets.zig`

No measurement work ships without the shared types and helpers landing first.

### Task 0.1: Create the worktree and per-plan artifact directory

**Files:**
- Create: `docs/performance/2026-04-20-query-bench/README.md`

- [ ] **Step 1: Create the worktree**

```bash
cd /home/benji/src/devnw/codepros/geode/geode
git worktree add ../geode-query-bench -b perf/query-bench-2026-04-20
cd ../geode-query-bench
```

- [ ] **Step 2: Create the artifact directory and README**

Create `docs/performance/2026-04-20-query-bench/README.md`:

```markdown
# 2026-04-20 Query Path Benchmark Plan — Artifact Ledger

Plan: `docs/superpowers/plans/2026-04-20-query-path-benchmarks.md`

Each milestone drops JSON outputs + diff.md here. Naming:

- `baseline/bench-<layer>.json` — M5 frozen baseline (parser / planner / executor-match / executor-mutation / e2e)
- `step-<N>-<slug>-{before,after}-*.json` — per-step A/B artifacts
- `step-<N>-<slug>-diff.md` — generated diff via `zig build compare-bench`
- `FINAL.md` — M5 close-out + ranked bottleneck list

Regression gate:
- `zig build compare-bench` uses `max(15%, 3σ)` noise gate on each (scenario, variant, measurement).
- Query-path measurements use these prefixes (see `common_query.zig`):
  - `throughput_ops_per_sec` — higher-is-better
  - `latency_p50_ns`, `latency_p95_ns`, `latency_p99_ns` — lower-is-better
  - `plan_ns_per_op`, `parse_ns_per_op`, `execute_ns_per_op` — lower-is-better
  - `plan_cache_hit_rate` — higher-is-better
  - `alloc_bytes_per_op`, `peak_rss_delta_bytes` — lower-is-better
```

- [ ] **Step 3: Commit**

```bash
git add docs/performance/2026-04-20-query-bench/README.md
git commit -m "perf(bench): scaffold 2026-04-20 query-bench artifact dir"
```

### Task 0.2: Design doc — scenario catalog + metrics schema

**Files:**
- Create: `docs/performance/2026-04-20-query-bench/query-bench-design.md`

- [ ] **Step 1: Write the design doc**

Create `docs/performance/2026-04-20-query-bench/query-bench-design.md`:

```markdown
# Query Path Benchmark — Design

## Why a separate framework

The existing `benchmarks/bench_schema.zig` + `zig build compare-bench` (M0.4 / M0.6) handle generic result-document JSON and A/B diffing. They do NOT know about query lifecycle. This plan adds a query-specific scenario spec + runner on top of the generic schema so every bench emits the same `ResultRow` shape while capturing parse / plan / execute phase timings separately.

## Scenario catalog (10 canonical queries)

Same shapes across parser / planner / executor layers so results stack:

1. `ping` — `RETURN 1 AS x` (baseline, no data access)
2. `point_read_inline` — `MATCH (p:LT_Person {lt_id: $id}) RETURN p.name, p.age` (GAP-0808 fast path)
3. `point_read_where` — `MATCH (p:LT_Person) WHERE p.lt_id = $id RETURN p.name` (label-scan path)
4. `one_hop` — `MATCH (a:LT_Person {lt_id: $id})-[:LT_KNOWS]->(b) RETURN b.name, b.age`
5. `two_hop_distinct` — `MATCH (a:LT_Person {lt_id: $id})-[:LT_KNOWS]->(b)-[:LT_KNOWS]->(c) RETURN DISTINCT c.name, c.lt_id LIMIT 20`
6. `fan_out_cross_type` — `MATCH (p:LT_Person {lt_id: $id})-[:LT_KNOWS]->(f)-[:LT_WORKS_AT]->(c:LT_Company) RETURN DISTINCT c.name LIMIT 10`
7. `agg_count_label` — `MATCH (p:LT_Person) RETURN count(p) AS n` (pure aggregation)
8. `agg_avg_property` — `MATCH (p:LT_Person) WHERE p.age > 30 RETURN avg(p.age) AS mean_age`
9. `order_by_limit` — `MATCH (p:LT_Person) RETURN p.lt_id ORDER BY p.lt_id DESC LIMIT 50`
10. `union_two_labels` — `MATCH (p:LT_Person) RETURN p.lt_id UNION MATCH (c:LT_Company) RETURN c.lt_id`

## Dataset sizes

Three fixed sizes for executor benches: `small=500 nodes`, `medium=2000 nodes + 8000 edges`, `large=10000 nodes + 30000 edges`. Each scenario runs against each size. Seeded deterministically by `query_datasets.zig` (same shapes as the loadtest's point_read / two_hop / fan_out so results compare directly).

## Measurements (per scenario × dataset)

Extended `QueryResultRow` (lives in `common_query.zig`; serializes via `bench_schema.ResultDocument`):

- `scenario_name`, `variant`, `dataset_size` (string: small/medium/large)
- `iterations`, `warmup_iterations` (typically 7 + 1 warmup, same as bench-timeseries)
- `wall_time_ns_median`, `wall_time_ns_stddev`
- `throughput_ops_per_sec`, `throughput_stddev_ops_per_sec`
- `parse_ns_per_op_p50`, `plan_ns_per_op_p50`, `execute_ns_per_op_p50` (phase timings — planner and executor benches only)
- `materialize_ns_per_op_p50` (executor-match bench only)
- `row_count_p50` (correctness sanity — should be stable across variants)
- `plan_cache_hits`, `plan_cache_misses` (planner bench only)
- `alloc_count_per_op`, `alloc_bytes_per_op` (via DebugAllocator stats in Debug mode only)
- `peak_rss_delta_bytes` (delta between warmup-end and run-end, mirrors thread-pool pattern)

## Noise gate

Reuse `zig build compare-bench`'s `max(15%, 3σ)` rule. Higher-is-better prefixes: `throughput_`, `plan_cache_hit_rate`. Lower-is-better prefixes: `latency_`, `wall_time_`, `*_ns_per_op`, `alloc_`, `peak_rss_`.

## Variant axis

Initially a single variant `default`. Reserved for future A/B sweeps (e.g. fast-path on/off, arena scratch size, RLS on/off).
```

- [ ] **Step 2: Commit**

```bash
git add docs/performance/2026-04-20-query-bench/query-bench-design.md
git commit -m "docs(bench): query-bench scenario catalog + metrics schema"
```

### Task 0.3: `benchmarks/query_datasets.zig` — deterministic seed routines

**Files:**
- Create: `benchmarks/query_datasets.zig`
- Test: `tests/perf/test_query_datasets.zig`

- [ ] **Step 1: Write the failing test**

Create `tests/perf/test_query_datasets.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const graph_store = @import("graph_store");
const datasets = @import("query_datasets");

test "seedPerson(500) creates exactly 500 LT_Person nodes with unique lt_id" {
    graph_store.deinitGlobalStore();
    defer graph_store.deinitGlobalStore();

    try datasets.seedPerson(testing.allocator, "default", 500);
    const store = graph_store.getGlobalStore(testing.allocator);

    var count: usize = 0;
    var seen_ids = std.AutoHashMap(i64, void).init(testing.allocator);
    defer seen_ids.deinit();

    var iter = store.nodes.iterator();
    while (iter.next()) |entry| {
        const node = entry.value_ptr;
        for (node.labels) |label| {
            if (std.mem.eql(u8, label, "LT_Person")) {
                count += 1;
                const lt_id = node.properties.get("lt_id") orelse continue;
                try testing.expect(!seen_ids.contains(lt_id.Int));
                try seen_ids.put(lt_id.Int, {});
                break;
            }
        }
    }
    try testing.expectEqual(@as(usize, 500), count);
}

test "seedPerson is deterministic across runs" {
    graph_store.deinitGlobalStore();
    defer graph_store.deinitGlobalStore();
    try datasets.seedPerson(testing.allocator, "default", 10);
    const first_run = graph_store.getGlobalStore(testing.allocator).nodes.count();

    graph_store.deinitGlobalStore();
    try datasets.seedPerson(testing.allocator, "default", 10);
    const second_run = graph_store.getGlobalStore(testing.allocator).nodes.count();

    try testing.expectEqual(first_run, second_run);
}
```

- [ ] **Step 2: Run test, expect FAIL** — module `query_datasets` not found.

```bash
zig build test-perf --summary all 2>&1 | grep -E "query_datasets|not declared"
```

- [ ] **Step 3: Implement `benchmarks/query_datasets.zig`**

```zig
const std = @import("std");
const graph_store = @import("graph_store");

/// Seed `count` LT_Person nodes with properties `{lt_id: i, name: "LT_Person_i", age: 20 + (i % 50)}`.
/// Matches the shape used by the loadtest's batchCreateNodes so benchmark results compare directly
/// with loadtest baselines.
pub fn seedPerson(allocator: std.mem.Allocator, graph_name: []const u8, count: usize) !void {
    const store = graph_store.getWritableGlobalStore(allocator);
    const labels: []const []const u8 = &.{"LT_Person"};
    var name_buf: [64]u8 = undefined;
    for (0..count) |i| {
        const node_id = try store.createNodeWithGraph(labels, graph_name);
        try store.setNodeProperty(node_id, "lt_id", .{ .Int = @intCast(i) });
        const name = try std.fmt.bufPrint(&name_buf, "LT_Person_{d}", .{i});
        try store.setNodeProperty(node_id, "name", .{ .String = name });
        try store.setNodeProperty(node_id, "age", .{ .Int = 20 + @as(i64, @intCast(i % 50)) });
    }
}

/// Seed `nodes` LT_Person nodes + `edges_per_node` outgoing LT_KNOWS edges per node.
/// Edge targets follow the loadtest's round-robin scheme: node i connects to
/// (i + 1 + k * stride) % nodes for k in [0, edges_per_node), with stride = 7.
pub fn seedPersonKnowsGraph(allocator: std.mem.Allocator, graph_name: []const u8, nodes: usize, edges_per_node: usize) !void {
    try seedPerson(allocator, graph_name, nodes);
    const store = graph_store.getWritableGlobalStore(allocator);
    const stride: usize = 7;
    for (0..nodes) |i| {
        for (0..edges_per_node) |k| {
            const target_idx = (i + 1 + k * stride) % nodes;
            // Resolve source + target node_ids by lt_id.
            // Relies on the merge_prop_index (hydrated by setNodeProperty above).
            var src_id: u64 = undefined;
            var tgt_id: u64 = undefined;
            if (store.lookupMergeCandidate(graph_name, "LT_Person", "lt_id", .{ .Int = @intCast(i) }, &src_id) != .found) return error.SeedFailed;
            if (store.lookupMergeCandidate(graph_name, "LT_Person", "lt_id", .{ .Int = @intCast(target_idx) }, &tgt_id) != .found) return error.SeedFailed;
            _ = try store.createEdgeWithType(src_id, tgt_id, "LT_KNOWS", graph_name);
        }
    }
}

/// Seed the fan-out scenario: `persons` LT_Person + `companies` LT_Company +
/// `knows_per_person` LT_KNOWS person→person + 1 LT_WORKS_AT person→company per person.
pub fn seedFanOut(allocator: std.mem.Allocator, graph_name: []const u8, persons: usize, companies: usize, knows_per_person: usize) !void {
    try seedPersonKnowsGraph(allocator, graph_name, persons, knows_per_person);
    const store = graph_store.getWritableGlobalStore(allocator);
    const labels: []const []const u8 = &.{"LT_Company"};
    var name_buf: [64]u8 = undefined;
    for (0..companies) |i| {
        const cid = try store.createNodeWithGraph(labels, graph_name);
        try store.setNodeProperty(cid, "lt_id", .{ .Int = @intCast(i) });
        const name = try std.fmt.bufPrint(&name_buf, "Company_{d}", .{i});
        try store.setNodeProperty(cid, "name", .{ .String = name });
    }
    for (0..persons) |i| {
        const company_idx = i % companies;
        var src_id: u64 = undefined;
        var tgt_id: u64 = undefined;
        if (store.lookupMergeCandidate(graph_name, "LT_Person", "lt_id", .{ .Int = @intCast(i) }, &src_id) != .found) return error.SeedFailed;
        if (store.lookupMergeCandidate(graph_name, "LT_Company", "lt_id", .{ .Int = @intCast(company_idx) }, &tgt_id) != .found) return error.SeedFailed;
        _ = try store.createEdgeWithType(src_id, tgt_id, "LT_WORKS_AT", graph_name);
    }
}
```

- [ ] **Step 4: Register module in `build.zig`**

Find the section where bench modules are declared (post-M0.4 pattern, grep for `bench_schema_mod`). Add:

```zig
const query_datasets_mod = b.createModule(.{
    .root_source_file = b.path("benchmarks/query_datasets.zig"),
    .target = target,
    .optimize = optimize,
});
query_datasets_mod.addImport("graph_store", root_mod);
```

Wire as an import on every query-bench exe and on `test_query_datasets.zig`.

- [ ] **Step 5: Run tests, expect PASS**

```bash
zig build test-perf --summary all 2>&1 | grep -E "test_query_datasets|passed"
```

Expected: both tests pass.

- [ ] **Step 6: Commit**

```bash
git add benchmarks/query_datasets.zig tests/perf/test_query_datasets.zig build.zig
git commit -m "perf(bench): query_datasets.zig — deterministic seed routines

seedPerson / seedPersonKnowsGraph / seedFanOut match the loadtest
scenarios' data shapes so bench results line up directly with
loadtest baselines. Round-robin stride=7 edge layout is identical
to geode-test-harness's batchCreateEdges."
```

### Task 0.4: `benchmarks/common_query.zig` — scenario spec + runner

**Files:**
- Create: `benchmarks/common_query.zig`
- Test: `tests/perf/test_common_query.zig`

- [ ] **Step 1: Write the failing test**

Create `tests/perf/test_common_query.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const common_query = @import("common_query");
const schema = @import("bench_schema");

test "QueryResultRow serializes to ResultDocument row with all phase timings" {
    const row = common_query.QueryResultRow{
        .git_sha = "deadbeef",
        .run_timestamp_unix_s = 1_700_000_000,
        .zig_version = "0.16.0",
        .os = "linux",
        .arch = "x86_64",
        .cpu = "test-cpu",
        .scenario_name = "point_read_inline",
        .variant = "default",
        .dataset_size = "small",
        .iterations = 6,
        .warmup_iterations = 1,
        .wall_time_ns_median = 1_000_000,
        .wall_time_ns_stddev = 50_000,
        .throughput_ops_per_sec = 1_000_000.0,
        .throughput_stddev_ops_per_sec = 50_000.0,
        .parse_ns_per_op_p50 = 100_000,
        .plan_ns_per_op_p50 = 200_000,
        .execute_ns_per_op_p50 = 700_000,
        .materialize_ns_per_op_p50 = 300_000,
        .row_count_p50 = 1,
        .plan_cache_hits = 5,
        .plan_cache_misses = 1,
        .alloc_count_per_op = 12,
        .alloc_bytes_per_op = 1024,
        .peak_rss_delta_bytes = 0,
    };
    const rows = try common_query.expand(testing.allocator, &[_]common_query.QueryResultRow{row});
    defer common_query.freeExpanded(testing.allocator, rows);

    // One input row expands to N generic bench_schema ResultRows — one per
    // measurement (throughput, latency p50, phase timings, alloc, rss).
    // That lets `zig build compare-bench` apply its prefix-based direction
    // rule to each measurement independently.
    try testing.expect(rows.len >= 5);
    // Spot-check: one row must have measurement = "throughput_ops_per_sec".
    var found_throughput = false;
    for (rows) |r| {
        if (std.mem.eql(u8, r.measurement, "throughput_ops_per_sec")) {
            found_throughput = true;
            try testing.expectEqual(@as(f64, 1_000_000.0), r.value);
        }
    }
    try testing.expect(found_throughput);
}

test "ScenarioSpec defaults are sensible" {
    const spec = common_query.QueryScenarioSpec{
        .name = "test",
        .query = "RETURN 1",
        .dataset_size = .small,
    };
    try testing.expectEqual(@as(usize, 7), spec.iterations);
    try testing.expectEqual(@as(usize, 1), spec.warmup_iterations);
    try testing.expectEqualStrings("default", spec.variant);
}
```

- [ ] **Step 2: Run test, expect FAIL**

```bash
zig build test-perf --summary all 2>&1 | grep -E "common_query|not declared"
```

- [ ] **Step 3: Implement `benchmarks/common_query.zig`**

```zig
const std = @import("std");
const schema = @import("bench_schema");

pub const DatasetSize = enum {
    small,  // 500 nodes, no edges
    medium, // 2000 nodes + 8000 edges
    large,  // 10000 nodes + 30000 edges

    pub fn label(self: DatasetSize) []const u8 {
        return @tagName(self);
    }

    pub fn nodeCount(self: DatasetSize) usize {
        return switch (self) {
            .small => 500,
            .medium => 2000,
            .large => 10000,
        };
    }

    pub fn edgesPerNode(self: DatasetSize) usize {
        return switch (self) {
            .small => 0,
            .medium => 4,
            .large => 3,
        };
    }
};

pub const QueryScenarioSpec = struct {
    name: []const u8,
    query: []const u8,
    dataset_size: DatasetSize = .small,
    variant: []const u8 = "default",
    iterations: usize = 7,
    warmup_iterations: usize = 1,
    /// Optional parameter injector. If null, the bench uses a fixed seed
    /// value (int 42 for point/one/two/fan_out shapes).
    param_fn: ?*const fn (iteration: usize) i64 = null,
};

pub const QueryResultRow = struct {
    git_sha: []const u8,
    run_timestamp_unix_s: i64,
    zig_version: []const u8,
    os: []const u8,
    arch: []const u8,
    cpu: []const u8,
    scenario_name: []const u8,
    variant: []const u8 = "default",
    dataset_size: []const u8,
    iterations: usize,
    warmup_iterations: usize,
    wall_time_ns_median: u64,
    wall_time_ns_stddev: u64 = 0,
    throughput_ops_per_sec: f64,
    throughput_stddev_ops_per_sec: f64 = 0,
    parse_ns_per_op_p50: u64 = 0,
    plan_ns_per_op_p50: u64 = 0,
    execute_ns_per_op_p50: u64 = 0,
    materialize_ns_per_op_p50: u64 = 0,
    row_count_p50: u64 = 0,
    plan_cache_hits: u64 = 0,
    plan_cache_misses: u64 = 0,
    alloc_count_per_op: u64 = 0,
    alloc_bytes_per_op: u64 = 0,
    peak_rss_delta_bytes: i64 = 0,
};

/// Expand one QueryResultRow into N generic ResultRow records (one per
/// named measurement) so `zig build compare-bench` can apply its prefix-
/// based noise gate per measurement. The scenario_name/variant get a
/// `/<dataset_size>` suffix to keep rows unique when we run the same
/// query across multiple dataset sizes.
pub fn expand(allocator: std.mem.Allocator, rows: []const QueryResultRow) ![]schema.ResultRow {
    var out = try std.ArrayList(schema.ResultRow).initCapacity(allocator, rows.len * 10);
    errdefer out.deinit(allocator);
    for (rows) |row| {
        const name_suffix = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ row.scenario_name, row.dataset_size });
        // Add one entry per measurement.
        const measurements = [_]struct { m: []const u8, v: f64, stddev: f64 }{
            .{ .m = "throughput_ops_per_sec", .v = row.throughput_ops_per_sec, .stddev = row.throughput_stddev_ops_per_sec },
            .{ .m = "wall_time_ns", .v = @floatFromInt(row.wall_time_ns_median), .stddev = @floatFromInt(row.wall_time_ns_stddev) },
            .{ .m = "latency_parse_ns_p50", .v = @floatFromInt(row.parse_ns_per_op_p50), .stddev = 0 },
            .{ .m = "latency_plan_ns_p50", .v = @floatFromInt(row.plan_ns_per_op_p50), .stddev = 0 },
            .{ .m = "latency_execute_ns_p50", .v = @floatFromInt(row.execute_ns_per_op_p50), .stddev = 0 },
            .{ .m = "latency_materialize_ns_p50", .v = @floatFromInt(row.materialize_ns_per_op_p50), .stddev = 0 },
            .{ .m = "alloc_bytes_per_op", .v = @floatFromInt(row.alloc_bytes_per_op), .stddev = 0 },
            .{ .m = "peak_rss_delta_bytes", .v = @floatFromInt(row.peak_rss_delta_bytes), .stddev = 0 },
        };
        for (measurements) |m| {
            try out.append(allocator, .{
                .git_sha = row.git_sha,
                .run_timestamp_unix_s = row.run_timestamp_unix_s,
                .zig_version = row.zig_version,
                .os = row.os,
                .arch = row.arch,
                .cpu = row.cpu,
                .scenario_name = name_suffix,
                .variant = row.variant,
                .measurement = m.m,
                .value = m.v,
                .value_stddev = m.stddev,
                .sample_count = row.iterations,
                .wall_time_ns = row.wall_time_ns_median,
            });
        }
    }
    return try out.toOwnedSlice(allocator);
}

pub fn freeExpanded(allocator: std.mem.Allocator, rows: []schema.ResultRow) void {
    // scenario_name entries were allocPrint'd in expand(). Free them here.
    for (rows) |row| allocator.free(row.scenario_name);
    allocator.free(rows);
}

/// Compute median + stddev over a slice of ns samples. Caller sorts the
/// slice in-place; this function assumes it's sorted ascending.
pub fn medianAndStddev(samples_sorted: []u64) struct { median: u64, stddev: u64 } {
    if (samples_sorted.len == 0) return .{ .median = 0, .stddev = 0 };
    const mid = samples_sorted.len / 2;
    const median: u64 = if (samples_sorted.len % 2 == 0)
        (samples_sorted[mid - 1] + samples_sorted[mid]) / 2
    else
        samples_sorted[mid];
    var sum_sq: u128 = 0;
    for (samples_sorted) |s| {
        const diff: i128 = @as(i128, s) - @as(i128, median);
        sum_sq += @intCast(diff * diff);
    }
    const variance = sum_sq / samples_sorted.len;
    const stddev: u64 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(variance))));
    return .{ .median = median, .stddev = stddev };
}
```

- [ ] **Step 4: Register module in `build.zig`**

Same pattern as Task 0.3. Wire `common_query_mod` as an import on every query-bench exe and test file.

- [ ] **Step 5: Run test, expect PASS**

```bash
zig build test-perf --summary all 2>&1 | grep -E "test_common_query|passed"
```

Expected: both tests pass.

- [ ] **Step 6: Commit**

```bash
git add benchmarks/common_query.zig tests/perf/test_common_query.zig build.zig
git commit -m "perf(bench): common_query.zig — QueryScenarioSpec + expand()

QueryResultRow carries phase timings (parse/plan/execute/materialize)
and plan-cache stats alongside the generic schema fields.

expand() flattens each QueryResultRow into N ResultRow records (one
per named measurement) so the existing 'zig build compare-bench'
infrastructure can apply its max(15%, 3σ) noise gate per measurement
using the standard throughput_/latency_/alloc_/peak_rss_ prefixes."
```

**M0 exit criterion:** `zig build test-perf` passes. `benchmarks/query_datasets.zig` + `benchmarks/common_query.zig` are ready to be consumed by the M1/M2/M3 benches.

---

## Milestone 1 — Parser benchmark

Measures pure parse cost per query shape, with no planner or executor involvement.

### Task 1.1: `benchmarks/bench_parser.zig` — parse-only throughput

**Files:**
- Create: `benchmarks/bench_parser.zig`
- Test: `tests/perf/test_bench_parser.zig`

- [ ] **Step 1: Write the failing smoke test**

Create `tests/perf/test_bench_parser.zig`:

```zig
const std = @import("std");
const testing = std.testing;

test "zig build bench-query-parser produces a valid ResultDocument with 10 scenarios" {
    // This test shells out to the build system; it's slow, opt-in.
    if (std.process.hasEnvVar(testing.allocator, "GEODE_RUN_SLOW_TESTS") catch false == false) {
        return error.SkipZigTest;
    }

    const tmp_json = "/tmp/test-bench-query-parser.json";
    var child = std.process.Child.init(&.{
        "zig", "build", "bench-query-parser", "-Doptimize=ReleaseFast",
        "--", "--output", tmp_json,
    }, testing.allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = try child.spawnAndWait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);

    const contents = try std.fs.cwd().readFileAlloc(testing.allocator, tmp_json, 8 * 1024 * 1024);
    defer testing.allocator.free(contents);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, contents, .{});
    defer parsed.deinit();
    const rows = parsed.value.object.get("rows").?.array;
    // 10 scenarios × 8 measurements (throughput + wall + 4 phase + alloc + rss) = 80 rows
    try testing.expect(rows.items.len >= 60);
}
```

- [ ] **Step 2: Run test, expect SKIP (module exists) or build failure**

```bash
zig build test-perf --summary all 2>&1 | grep -E "test_bench_parser"
```

Expected: `SkipZigTest` (GEODE_RUN_SLOW_TESTS unset) — this is the right behavior; slow tests are opt-in.

- [ ] **Step 3: Implement `benchmarks/bench_parser.zig`**

```zig
const std = @import("std");
const common_query = @import("common_query");
const schema = @import("bench_schema");
const geode = @import("geode");

fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const SCENARIOS = [_]struct { name: []const u8, query: []const u8 }{
    .{ .name = "ping", .query = "RETURN 1 AS x" },
    .{ .name = "point_read_inline", .query = "MATCH (p:LT_Person {lt_id: $id}) RETURN p.name, p.age" },
    .{ .name = "point_read_where", .query = "MATCH (p:LT_Person) WHERE p.lt_id = $id RETURN p.name" },
    .{ .name = "one_hop", .query = "MATCH (a:LT_Person {lt_id: $id})-[:LT_KNOWS]->(b) RETURN b.name, b.age" },
    .{ .name = "two_hop_distinct", .query = "MATCH (a:LT_Person {lt_id: $id})-[:LT_KNOWS]->(b)-[:LT_KNOWS]->(c) RETURN DISTINCT c.name, c.lt_id LIMIT 20" },
    .{ .name = "fan_out_cross_type", .query = "MATCH (p:LT_Person {lt_id: $id})-[:LT_KNOWS]->(f)-[:LT_WORKS_AT]->(c:LT_Company) RETURN DISTINCT c.name LIMIT 10" },
    .{ .name = "agg_count_label", .query = "MATCH (p:LT_Person) RETURN count(p) AS n" },
    .{ .name = "agg_avg_property", .query = "MATCH (p:LT_Person) WHERE p.age > 30 RETURN avg(p.age) AS mean_age" },
    .{ .name = "order_by_limit", .query = "MATCH (p:LT_Person) RETURN p.lt_id ORDER BY p.lt_id DESC LIMIT 50" },
    .{ .name = "union_two_labels", .query = "MATCH (p:LT_Person) RETURN p.lt_id UNION MATCH (c:LT_Company) RETURN c.lt_id" },
};

pub fn main(proc_init: std.process.Init.Minimal) !void {
    var dbg_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg_alloc.deinit();
    const allocator: std.mem.Allocator = if (@import("builtin").mode == .Debug)
        dbg_alloc.allocator()
    else
        std.heap.smp_allocator;

    // Parse --output <path>
    var output_path: ?[]const u8 = null;
    const argv = try proc_init.args.toSlice(allocator);
    defer allocator.free(argv);
    var idx: usize = 1;
    while (idx + 1 < argv.len) : (idx += 1) {
        if (std.mem.eql(u8, argv[idx], "--output")) {
            output_path = try allocator.dupe(u8, argv[idx + 1]);
        }
    }

    const iterations: usize = 10_000;
    const warmup: usize = 500;

    var rows = std.ArrayList(common_query.QueryResultRow).empty;
    defer rows.deinit(allocator);

    for (SCENARIOS) |scn| {
        // Warmup
        for (0..warmup) |_| {
            var result = try geode.gql.parser.parse(allocator, scn.query, .{});
            result.deinit(allocator);
        }
        // Timed
        const start = nowNs();
        for (0..iterations) |_| {
            var result = try geode.gql.parser.parse(allocator, scn.query, .{});
            result.deinit(allocator);
        }
        const elapsed = nowNs() - start;
        const throughput: f64 = @as(f64, @floatFromInt(iterations)) * 1e9 / @as(f64, @floatFromInt(elapsed));
        const ns_per_op: u64 = elapsed / iterations;

        try rows.append(allocator, .{
            .git_sha = "unknown",
            .run_timestamp_unix_s = std.time.timestamp(),
            .zig_version = @import("builtin").zig_version_string,
            .os = @tagName(@import("builtin").os.tag),
            .arch = @tagName(@import("builtin").cpu.arch),
            .cpu = "unknown",
            .scenario_name = scn.name,
            .dataset_size = "none",
            .iterations = iterations,
            .warmup_iterations = warmup,
            .wall_time_ns_median = ns_per_op,
            .throughput_ops_per_sec = throughput,
            .parse_ns_per_op_p50 = ns_per_op,
            .row_count_p50 = 1,
        });
    }

    if (output_path) |path| {
        const expanded = try common_query.expand(allocator, rows.items);
        defer common_query.freeExpanded(allocator, expanded);
        const doc = schema.ResultDocument{
            .generated_at_unix_s = std.time.timestamp(),
            .rows = expanded,
        };
        const io = std.Io.Threaded.global_single_threaded.io();
        try schema.writeDocument(allocator, io, path, doc);
    } else {
        const stdout = std.Io.File.stdout();
        const io = std.Io.Threaded.global_single_threaded.io();
        for (rows.items) |row| {
            const line = try std.fmt.allocPrint(allocator, "{s}: {d:.0} ops/sec, parse {d} ns/op\n", .{ row.scenario_name, row.throughput_ops_per_sec, row.parse_ns_per_op_p50 });
            defer allocator.free(line);
            try stdout.writeStreamingAll(io, line);
        }
    }
}
```

Note: the import `geode.gql.parser.parse` may differ — verify the actual public parser entry point via `grep -n "pub fn parse" src/gql/parser.zig` and adjust if needed.

- [ ] **Step 4: Register in `build.zig`**

```zig
const bench_parser_exe = b.addExecutable(.{
    .name = "bench-query-parser",
    .root_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/bench_parser.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common_query", .module = common_query_mod },
            .{ .name = "bench_schema", .module = bench_schema_mod },
            .{ .name = "geode", .module = root_mod },
        },
    }),
});
const run_bench_parser = b.addRunArtifact(bench_parser_exe);
if (b.args) |args| run_bench_parser.addArgs(args);
const bench_parser_step = b.step("bench-query-parser", "Parser-only throughput across 10 canonical queries");
bench_parser_step.dependOn(&run_bench_parser.step);
```

- [ ] **Step 5: Smoke-run**

```bash
mkdir -p benchmarks/results
zig build bench-query-parser -Doptimize=ReleaseFast -- --output benchmarks/results/bench-parser-smoke.json
jq '.rows | length' benchmarks/results/bench-parser-smoke.json
jq '.rows[0]' benchmarks/results/bench-parser-smoke.json
```

Expected: `.rows | length` ≥ 60 (10 scenarios × 8 measurements). First row has the expected schema fields.

- [ ] **Step 6: Run the slow test, expect PASS**

```bash
GEODE_RUN_SLOW_TESTS=1 zig build test-perf --summary all 2>&1 | grep -E "test_bench_parser|passed"
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add benchmarks/bench_parser.zig tests/perf/test_bench_parser.zig build.zig
git commit -m "perf(bench): bench_parser.zig — parse-only throughput (M1)

10 canonical query shapes × 10,000 iterations + 500 warmup. Emits
ResultDocument JSON via --output. Measures parse_ns_per_op_p50 +
throughput_ops_per_sec per shape.

Unblocks the planner + executor benches in M2/M3, which use the
same scenario catalog to stack phase timings per query shape."
```

**M1 exit criterion:** `zig build bench-query-parser -- --output <path>` produces ≥ 60 ResultRow entries; each scenario has a `parse_ns_per_op_p50` value.

---

## Milestone 2 — Planner benchmark

Measures parse + plan time per shape. Differences from M1 (parse-only) isolate the planner-phase cost per query.

### Task 2.1: `benchmarks/bench_planner.zig`

**Files:**
- Create: `benchmarks/bench_planner.zig`
- Test: `tests/perf/test_bench_planner.zig`

- [ ] **Step 1: Write the failing smoke test**

Create `tests/perf/test_bench_planner.zig` with the same shell-out pattern as `test_bench_parser.zig`, targeting `bench-query-planner` and checking `.rows | length >= 60` + that at least one row has `measurement == "latency_plan_ns_p50"` with a positive value.

- [ ] **Step 2: Run test, expect SKIP/FAIL**

- [ ] **Step 3: Implement `benchmarks/bench_planner.zig`**

Same structure as `bench_parser.zig` but runs parse → plan per iteration:

```zig
// Per-iteration loop (replaces the parser-only block)
const parse_start = nowNs();
var parsed = try geode.gql.parser.parse(allocator, scn.query, .{});
defer parsed.deinit(allocator);
const parse_end = nowNs();

const plan_start = nowNs();
var plan = try geode.planner.optimizer.plan(allocator, &parsed, plan_ctx);
defer plan.deinit(allocator);
const plan_end = nowNs();

// Per-op timings
parse_ns_samples[i] = parse_end - parse_start;
plan_ns_samples[i] = plan_end - plan_start;
```

Split `parse_ns_per_op_p50` and `plan_ns_per_op_p50` into separate medians via `common_query.medianAndStddev`. Also track:

```zig
const optimizer_state = geode.planner.optimizer.getGlobalSharedOptimizer() orelse null;
const hits_before = if (optimizer_state) |o| o.stats.hits.load(.monotonic) else 0;
// ... run iterations ...
const hits_after = if (optimizer_state) |o| o.stats.hits.load(.monotonic) else 0;
row.plan_cache_hits = hits_after - hits_before;
```

Export the same 10 scenarios across dataset sizes `small` / `medium` / `large` — 30 `QueryResultRow` entries total (the planner itself doesn't touch data, but the planner's cost-model may use dataset statistics so we include size as a dimension).

**Verify public symbols before coding:** `grep -n "pub fn plan\|pub const SharedQueryOptimizer\|getGlobalSharedOptimizer" src/planner/ src/execution/ | head -20`. If the public API differs, adjust imports.

- [ ] **Step 4: Register in `build.zig`**

Same pattern as Task 1.1. Step name: `bench-query-planner`.

- [ ] **Step 5: Smoke-run**

```bash
zig build bench-query-planner -Doptimize=ReleaseFast -- --output benchmarks/results/bench-planner-smoke.json
jq '.rows | map(select(.measurement == "latency_plan_ns_p50")) | length' benchmarks/results/bench-planner-smoke.json
```

Expected: `≥ 10` (one per scenario/size).

- [ ] **Step 6: Run slow test, expect PASS**

- [ ] **Step 7: Commit**

```bash
git add benchmarks/bench_planner.zig tests/perf/test_bench_planner.zig build.zig
git commit -m "perf(bench): bench_planner.zig — parse+plan phase timings (M2)

Reuses M1's 10-scenario catalog, adds dataset_size (small/medium/
large) and plan-cache stats (hits/misses). Per-op split into
parse_ns_per_op_p50 and plan_ns_per_op_p50 via
common_query.medianAndStddev."
```

**M2 exit criterion:** `bench-query-planner` emits 30 scenario-rows (10 queries × 3 sizes); every row has distinct `parse_ns_per_op_p50` and `plan_ns_per_op_p50`.

---

## Milestone 3 — Executor benchmarks

Measures end-to-end in-process execute cost, bypassing QUIC so we isolate the executor from transport effects.

### Task 3.1: `benchmarks/bench_executor_match.zig`

**Files:**
- Create: `benchmarks/bench_executor_match.zig`
- Test: `tests/perf/test_bench_executor_match.zig`

- [ ] **Step 1: Write the failing smoke test**

Same shell-out pattern, targeting `bench-query-executor-match`, asserting at least one row per scenario has `measurement == "latency_execute_ns_p50"` with a positive value and `row_count_p50 > 0` (rules out "query executed but returned nothing").

- [ ] **Step 2: Run test, expect SKIP/FAIL**

- [ ] **Step 3: Implement `benchmarks/bench_executor_match.zig`**

Key decisions:

1. **Seed the dataset ONCE per size** via `query_datasets.seedPerson(...)` / `seedPersonKnowsGraph(...)`. Reset the global store between size transitions with `graph_store.deinitGlobalStore()`.
2. For each scenario, run the full parse → plan → execute cycle per iteration and record `execute_ns` separately from `materialize_ns`. If the executor doesn't expose a separate materialize-phase timer, measure by inspecting trace output (`planned_read_runtime.RuntimeTrace`).
3. Use a fresh `ExecutionContext` per iteration (matches real handler behavior).
4. Drop results immediately — we're measuring executor throughput, not serialization.

Pseudocode for the inner loop:

```zig
for (0..iterations) |i| {
    const params = [_]geode.Value{ .{ .Int = param_fn(i) } };

    const parse_start = nowNs();
    var parsed = try geode.gql.parser.parse(allocator, scn.query, .{});
    const parse_end = nowNs();

    const plan_start = nowNs();
    var plan = try geode.planner.optimizer.plan(allocator, &parsed, plan_ctx);
    const plan_end = nowNs();

    const exec_start = nowNs();
    var result = try geode.execution.executeStatementWithContext(allocator, &parsed, ctx);
    const exec_end = nowNs();

    parse_ns_samples[i] = parse_end - parse_start;
    plan_ns_samples[i] = plan_end - plan_start;
    exec_ns_samples[i] = exec_end - exec_start;
    row_counts[i] = result.rows.len;

    result.deinit(allocator);
    plan.deinit(allocator);
    parsed.deinit(allocator);
}
```

**Verify entry point**: `grep -n "pub fn executeStatementWithContext\|pub fn execute" src/execution/query_execution.zig src/execution/execution.zig | head`. If the public entry is named differently (the existing loadtest goes through the QUIC handler, not a direct `execute` function), check what `tests/test_handler_point_read_zero_copy.zig` uses and copy its pattern.

- [ ] **Step 4: Register in `build.zig`**

Step name: `bench-query-executor-match`.

- [ ] **Step 5: Smoke-run**

```bash
zig build bench-query-executor-match -Doptimize=ReleaseFast -- --output benchmarks/results/bench-exec-match-smoke.json
# 10 scenarios × 3 sizes = 30 scenario-rows; each row expands to ~8 measurements.
jq '.rows | length' benchmarks/results/bench-exec-match-smoke.json  # ≥ 240
# Verify row_count_p50 is non-zero for scenarios that should match:
jq '.rows | map(select(.measurement == "latency_execute_ns_p50" and .scenario_name | startswith("point_read_inline"))) | .[]' benchmarks/results/bench-exec-match-smoke.json
```

- [ ] **Step 6: Run slow test, expect PASS**

- [ ] **Step 7: Commit**

```bash
git add benchmarks/bench_executor_match.zig tests/perf/test_bench_executor_match.zig build.zig
git commit -m "perf(bench): bench_executor_match.zig — in-process MATCH execution (M3)

10 scenarios × 3 dataset sizes × 1000 iterations + 100 warmup. Full
parse → plan → execute cycle, bypasses QUIC so the measurement
isolates executor cost. Dataset seeded once per size via
query_datasets.zig.

Phase timings split into parse_ns / plan_ns / execute_ns via
common_query.medianAndStddev. row_count_p50 is a correctness sanity
check (non-zero for scenarios that should match)."
```

### Task 3.2: `benchmarks/bench_executor_mutation.zig`

**Files:**
- Create: `benchmarks/bench_executor_mutation.zig`
- Test: `tests/perf/test_bench_executor_mutation.zig`

- [ ] **Step 1: Write the failing smoke test**

Same pattern, targeting `bench-query-executor-mutation`.

- [ ] **Step 2: Run test, expect SKIP/FAIL**

- [ ] **Step 3: Implement `benchmarks/bench_executor_mutation.zig`**

Mutation scenarios (6 total):

1. `create_single_node` — `CREATE (:LT_Person {lt_id: $id, name: $name, age: $age})`
2. `create_batch_100` — 100 single-node CREATEs in a tight loop (same query, different params)
3. `set_property` — `MATCH (p:LT_Person {lt_id: $id}) SET p.last_seen = $ts`
4. `delete_single` — `MATCH (p:LT_Person {lt_id: $id}) DELETE p`
5. `merge_single` — `MERGE (p:LT_Person {lt_id: $id}) ON CREATE SET p.name = $name`
6. `create_edge` — `MATCH (a:LT_Person {lt_id: $src}), (b:LT_Person {lt_id: $dst}) CREATE (a)-[:LT_KNOWS]->(b)`

Important: dataset setup differs per scenario (create needs nothing pre-seeded; set/delete/merge/create_edge need pre-seeded nodes). Each scenario has its own `setupFn`.

Scope guardrail: wrap the batch in a `try` / seed-on-setup pattern so an early test failure doesn't corrupt the global store for subsequent scenarios. Reset the store between scenarios.

- [ ] **Step 4: Register in `build.zig`**

Step name: `bench-query-executor-mutation`.

- [ ] **Step 5: Smoke-run + slow test + commit** — same pattern as Task 3.1.

```bash
git commit -m "perf(bench): bench_executor_mutation.zig — mutation-path benchmarks (M3)

6 mutation scenarios: create_single, create_batch_100, set_property,
delete_single, merge_single, create_edge. Each runs with its own
seeded dataset and resets the global store between scenarios."
```

**M3 exit criterion:** `bench-query-executor-match` + `bench-query-executor-mutation` each emit valid ResultDocument JSON; every scenario's `latency_execute_ns_p50` is positive; match scenarios have `row_count_p50 > 0`.

---

## Milestone 4 — A/B harness: `scripts/query-perf-gate.sh` + `bench-query-all`

### Task 4.1: `bench-query-all` aggregate in `build.zig`

- [ ] **Step 1: Add an aggregate step that depends on all 4 query-bench exes**

```zig
const bench_query_all_step = b.step("bench-query-all", "Run all query-path benchmarks (parser/planner/executor-match/executor-mutation)");
bench_query_all_step.dependOn(&run_bench_parser.step);
bench_query_all_step.dependOn(&run_bench_planner.step);
bench_query_all_step.dependOn(&run_bench_executor_match.step);
bench_query_all_step.dependOn(&run_bench_executor_mutation.step);
```

- [ ] **Step 2: Smoke-run**

```bash
zig build bench-query-all -Doptimize=ReleaseFast -- --output /tmp/bench-query-all.json
```

Note: each sub-step writes to its own `--output` path or accumulates into the same JSON if they all honor the same flag. Confirm during implementation that repeated `--output` in the aggregate doesn't overwrite earlier results — if it does, the aggregate should invoke each with a per-step path.

- [ ] **Step 3: Commit**

```bash
git add build.zig
git commit -m "perf(bench): bench-query-all aggregate step (M4.1)"
```

### Task 4.2: `scripts/query-perf-gate.sh` — A/B driver

**Files:**
- Create: `scripts/query-perf-gate.sh`

- [ ] **Step 1: Write the script**

Mirror `scripts/perf-gate.sh` structure. Key differences:

- No loadtest invocation (this is a pure in-process bench suite).
- Drives `bench-query-parser`, `bench-query-planner`, `bench-query-executor-match`, `bench-query-executor-mutation` per phase.
- Merges the 4 per-bench JSONs into a single `<step>-<phase>-query-all.json` via `jq -s '{rows: (map(.rows) | add), generated_at_unix_s: .[0].generated_at_unix_s}'`.
- On `after`, runs `zig build compare-bench -- --baseline <before> --current <after>` and writes the output into `diff.md`.

```bash
#!/usr/bin/env bash
# scripts/query-perf-gate.sh <step-name> <before|after>

set -euo pipefail

ZIG="${ZIG:-zig}"
STEP="${1:?step name required}"
PHASE="${2:?phase required: before|after}"
ART_DIR="${ART_DIR:-docs/performance/2026-04-20-query-bench}"
export GEODE_BENCH_GIT_SHA="${GEODE_BENCH_GIT_SHA:-$(git rev-parse HEAD)}"
export GEODE_BENCH_CPU="${GEODE_BENCH_CPU:-$(uname -m)}"

if [[ "$PHASE" != "before" && "$PHASE" != "after" ]]; then
  echo "[query-perf-gate] ERROR: phase must be 'before' or 'after'" >&2
  exit 2
fi

mkdir -p "$ART_DIR"

for bench in parser planner executor-match executor-mutation; do
  OUT="$ART_DIR/${STEP}-${PHASE}-${bench}.json"
  echo "[query-perf-gate] $STEP $PHASE: zig build bench-query-$bench -> $OUT"
  "$ZIG" build "bench-query-$bench" -Doptimize=ReleaseFast -- --output "$OUT"
done

MERGED="$ART_DIR/${STEP}-${PHASE}-query-all.json"
jq -s '{
  generated_at_unix_s: .[0].generated_at_unix_s,
  rows: (map(.rows) | add)
}' "$ART_DIR/${STEP}-${PHASE}-"{parser,planner,executor-match,executor-mutation}.json > "$MERGED"

if [[ "$PHASE" == "after" ]]; then
  DIFF_OUT="$ART_DIR/${STEP}-diff.md"
  BEFORE_MERGED="$ART_DIR/${STEP}-before-query-all.json"
  [[ -f "$BEFORE_MERGED" ]] || { echo "[query-perf-gate] ERROR: missing $BEFORE_MERGED" >&2; exit 3; }
  {
    echo "# Query perf diff — $STEP"
    echo
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Commit: $(git rev-parse HEAD)"
    echo "CPU: $GEODE_BENCH_CPU"
    echo
    echo '## zig build compare-bench output'
    echo
    echo '```'
    "$ZIG" build compare-bench -- --baseline "$BEFORE_MERGED" --current "$MERGED" 2>&1 || true
    echo '```'
    echo
    echo '## Review checklist'
    echo
    echo '- throughput_* regression >= 5% on any scenario/size -> BLOCK'
    echo '- latency_*_ns_p50 rise    >= 10% on any scenario/size -> BLOCK'
    echo '- alloc_bytes_per_op       >= 10% -> WARN, disposition below'
    echo
    echo '## Disposition'
    echo
    echo '_(Fill this in if any row in the compare-bench output crosses a gate.)_'
  } > "$DIFF_OUT"
  echo "[query-perf-gate] diff written to $DIFF_OUT"
fi

echo "[query-perf-gate] done."
```

- [ ] **Step 2: `chmod +x`**

- [ ] **Step 3: Smoke test on a no-op before/after**

```bash
./scripts/query-perf-gate.sh m4-smoke before
./scripts/query-perf-gate.sh m4-smoke after
cat docs/performance/2026-04-20-query-bench/m4-smoke-diff.md
```

Expected: diff.md exists; compare-bench reports "no regressions detected" (identical binary on before + after).

- [ ] **Step 4: Clean up smoke artifacts**

```bash
rm docs/performance/2026-04-20-query-bench/m4-smoke-*
```

- [ ] **Step 5: Commit**

```bash
git add scripts/query-perf-gate.sh
git commit -m "perf(bench): query-perf-gate.sh — A/B driver for query benches (M4.2)"
```

**M4 exit criterion:** `./scripts/query-perf-gate.sh <step> before` then `after` produces a valid `diff.md` with a `compare-bench` table and the review checklist populated; both paths exit 0 on a no-op change.

---

## Milestone 5 — Baseline + bottleneck report

### Task 5.1: Freeze the baseline

**Files:**
- Create: `docs/performance/2026-04-20-query-bench/baseline/bench-query-all.json`

- [ ] **Step 1: Run the full suite on a clean HEAD**

```bash
./scripts/query-perf-gate.sh baseline before
cp docs/performance/2026-04-20-query-bench/baseline-before-query-all.json \
   docs/performance/2026-04-20-query-bench/baseline/bench-query-all.json
rm docs/performance/2026-04-20-query-bench/baseline-before-*.json
```

- [ ] **Step 2: Sanity check**

```bash
jq '.rows | length' docs/performance/2026-04-20-query-bench/baseline/bench-query-all.json
# Expect: 10 parser scenarios × 8 measurements (80) + 30 planner rows × 8 (240) + 30 exec-match × 8 (240) + 6 mutation × 8 (48) = 608
```

- [ ] **Step 3: Commit**

```bash
git add docs/performance/2026-04-20-query-bench/baseline/
git commit -m "perf(bench): freeze initial query-bench baseline (M5.1)

608 rows covering parser/planner/executor-match/executor-mutation
across the 10+6 scenario catalog and small/medium/large datasets."
```

### Task 5.2: Profile-driven bottleneck report → FINAL.md

**Files:**
- Create: `docs/performance/2026-04-20-query-bench/FINAL.md`

- [ ] **Step 1: Capture a `sudo perf record` profile against each executor bench**

```bash
for bench in executor-match executor-mutation; do
  bench_pid=$(setsid zig build "bench-query-$bench" -Doptimize=ReleaseFast & echo $!)
  sleep 2
  sudo perf record -F 999 -g --call-graph dwarf -p "$bench_pid" \
       -o "docs/performance/2026-04-20-query-bench/profile-$bench.perf.data" -- sleep 25 || true
  wait $bench_pid 2>/dev/null || true
done
```

- [ ] **Step 2: Extract top symbols into text reports**

```bash
for bench in executor-match executor-mutation; do
  sudo chmod 644 "docs/performance/2026-04-20-query-bench/profile-$bench.perf.data"
  sudo perf report -i "docs/performance/2026-04-20-query-bench/profile-$bench.perf.data" \
       --stdio --no-children --no-call-graph --percent-limit 0.1 2>&1 \
       | grep -E "^\s+[0-9]" | head -40 \
       > "docs/performance/2026-04-20-query-bench/profile-$bench-flat.txt"
done
rm docs/performance/2026-04-20-query-bench/profile-*.perf.data
```

- [ ] **Step 3: Write `FINAL.md` with ranked bottlenecks**

Use this template:

```markdown
# Query Path Benchmark — Baseline + Bottleneck Report

Captured on `perf/query-bench-2026-04-20` at commit <HEAD>.

## Baseline summary

From `baseline/bench-query-all.json`:

| layer | scenario | dataset | throughput (ops/sec) | p50 latency (ns) | alloc bytes/op |
|---|---|---|---:|---:|---:|
| parser | ping | none | <X> | <Y> | <Z> |
| ... | | | | | |

(Populate by running `jq -r` over the baseline JSON — script template included at end of doc.)

## Top bottlenecks (ranked by expected QPS impact)

1. **<symbol> (<pct>%)** — evidence: `profile-executor-match-flat.txt` line N.
   Expected fix: <description>. Est. win: <factor>×.
2. ...

## Follow-ups

(file per-bottleneck tickets)
```

- [ ] **Step 4: Commit**

```bash
git add docs/performance/2026-04-20-query-bench/FINAL.md docs/performance/2026-04-20-query-bench/profile-*-flat.txt
git commit -m "perf(bench): M5 — query-bench baseline + bottleneck report

Ranked top bottleneck candidates from profile-driven analysis.
Each candidate lists evidence (flat profile line), expected fix,
and rough win estimate. To be attacked one-by-one in follow-up
branches using scripts/query-perf-gate.sh as the A/B driver."
```

**M5 exit criterion:** `FINAL.md` exists with a ranked list of at least 5 bottleneck candidates, each backed by a citation into the profile or JSON.

---

## Milestone 6 — CI wiring

### Task 6.1: Add `bench-query-path` job to `.gitlab-ci.yml`

**Files:**
- Modify: `.gitlab-ci.yml`

- [ ] **Step 1: Add the job**

```yaml
# =============================================================================
# Test Stage - Query-Path Benchmark Regression Check
# Runs the query parser/planner/executor bench suite and compares against
# the committed baseline. Starts warning-only (allow_failure: true) until
# the baseline stabilizes; flip to blocking after ~4 weeks of quiet runs.
# =============================================================================

bench-query-path:
  stage: test
  image: $ZIG_IMAGE
  variables:
    GIT_SUBMODULE_STRATEGY: recursive
  before_script:
    - *zig-vendor-cache
  script:
    - |
      echo "=== Running query-path benchmarks ==="
      zig build bench-query-parser -Doptimize=ReleaseFast -- --output bench-parser.json
      zig build bench-query-planner -Doptimize=ReleaseFast -- --output bench-planner.json
      zig build bench-query-executor-match -Doptimize=ReleaseFast -- --output bench-exec-match.json
      zig build bench-query-executor-mutation -Doptimize=ReleaseFast -- --output bench-exec-mut.json
      jq -s '{generated_at_unix_s: .[0].generated_at_unix_s, rows: (map(.rows) | add)}' \
        bench-parser.json bench-planner.json bench-exec-match.json bench-exec-mut.json \
        > bench-query-all.json
      if [ -f docs/performance/2026-04-20-query-bench/baseline/bench-query-all.json ]; then
        zig build compare-bench -- \
          --baseline docs/performance/2026-04-20-query-bench/baseline/bench-query-all.json \
          --current bench-query-all.json
      else
        echo "SKIP: baseline not found"
      fi
  allow_failure: true
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
  artifacts:
    when: always
    paths:
      - bench-query-all.json
    expire_in: 4 weeks
```

- [ ] **Step 2: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "ci(perf): bench-query-path regression job (M6.1)

Runs the full query-bench suite on every MR + main push, compares
against the committed baseline. allow_failure: true until stable."
```

**M6 exit criterion:** `bench-query-path` job appears in CI on the next MR, runs, uploads the merged JSON artifact, compares against the baseline, exits non-zero on regression (but doesn't block because `allow_failure: true`).

---

## Self-review

**Spec coverage (against the ARGUMENTS brief):**
- [x] Extensive benchmarks similar to thread-pool — M0 framework + M1/M2/M3 per-layer benches, all emitting `ResultRow` via the same `bench_schema` pipeline.
- [x] A/B testing for query planning + execution — M4 `scripts/query-perf-gate.sh` driving `zig build compare-bench`.
- [x] Create baselines — M5.1 freezes `baseline/bench-query-all.json`.
- [x] Identify areas of improvement for performance — M5.2 `FINAL.md` with ranked bottleneck list backed by `perf record` evidence.

**Placeholder scan:** grepped for `TBD`, `TODO`, `FIXME`, `implement later`, "similar to Task N". Task 2.1 Step 3 uses pseudocode instead of full code — justified because the public planner API (`geode.planner.optimizer.plan`) wasn't verified at plan-write time; the task explicitly flags this with `**Verify public symbols before coding**`. Task 3.1 Step 3 same pattern. Task 3.2 Step 3 delegates details to "same pattern as Task 3.1" — expanded the commit message explicitly so readers don't have to cross-reference.

**Type consistency:**
- `QueryScenarioSpec` defined in Task 0.4 (name, query, dataset_size, variant, iterations, warmup_iterations, param_fn). Consumed by Tasks 1.1, 2.1, 3.1, 3.2 with matching field names.
- `QueryResultRow` defined in Task 0.4 with 25 fields. Consumed by Tasks 1.1, 2.1, 3.1, 3.2 — I stuck with the same names (`throughput_ops_per_sec`, `parse_ns_per_op_p50`, `plan_ns_per_op_p50`, `execute_ns_per_op_p50`, `plan_cache_hits`, etc).
- `expand()` signature in Task 0.4 matches the usage in Tasks 1.1 / 2.1 / 3.1 / 3.2 (`common_query.expand(allocator, rows)` returns `[]schema.ResultRow`).
- `DatasetSize` enum in Task 0.4 with `nodeCount()` / `edgesPerNode()` / `label()` — referenced correctly throughout.
- `query_datasets.seedPerson` / `seedPersonKnowsGraph` / `seedFanOut` signatures defined in Task 0.3 — referenced correctly in Task 3.1.

All consistent. Plan complete.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-20-query-path-benchmarks.md`.

Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task with fast iteration and spec-compliance + code-quality review between tasks. Best for a plan this size because each subagent can focus on a single bench exe without carrying the cross-bench context.

**2. Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints.

Which approach?
