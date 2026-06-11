//! GAP-0866: scalar `timeseries.*` GQL function family — end-to-end tests
//! through the REAL parse → executeStatementWithContext → eval path.
//!
//! `docs/TIMESERIES_REQUIREMENTS_INVENTORY.md` (2026-04-01) recorded the
//! `TSFunctionCall` system in `src/timeseries/gql_functions.zig` as "completely
//! independent from the actual GQL eval path". That is stale: since GAP-0282 /
//! GAP-0290 the eval fallback `.Call` branch (`evalTimeseriesFunction` /
//! `evalArrayBasedTsFunction` in `src/eval.zig`) builds `TSFunctionCall`s and
//! executes them against the real Store. What was MISSING was integration
//! evidence through the public parser+executor entry point — every prior test
//! either built ASTs by hand (eval.zig GAP-0280 tests) or called
//! `executeFunction` directly (tests/e2e_timeseries.zig). This file closes that
//! evidence gap: one test per documented function, each running a real GQL
//! query string through `executeStatementWithContext` (the same entry the
//! QUIC/gRPC servers use), with the Store installed via the server-boot wiring
//! (`eval.setGlobalTimeseriesStore`, see src/server/main.zig).
//!
//! Writing these tests exposed (and the paired eval.zig fix closed) a real
//! reachability bug: parsed float literals (`[1.0, 2.0]`, penalty `1.0`,
//! gamma `1.0`) evaluate to `.Decimal` (exact numeric), which the array-based
//! function argument extraction rejected with TypeMismatch — so dtw*, sbd,
//! cosine_similarity, cross_correlate, change_points, and dtw_soft were
//! unreachable from real queries despite passing AST-built unit tests.
//!
//! Allocator note: most tests run inside an ArenaAllocator, mirroring the
//! per-request arena the QUIC server wraps execution in (GAP-0755,
//! src/server/quic_connection_handler.zig) — eval treats the execution
//! allocator as arena-scoped for non-scalar temporaries. The scalar
//! `timeseries.value` and no-store tests run strict (std.testing.allocator)
//! to keep leak-checking the scalar path.
//!
// CANARY: REQ=REQ-TS-GQL-EXEC-001; FEATURE="TimeSeriesGqlExecute"; ASPECT=Integration; STATUS=TESTED; TEST=tests/test_gap0866_ts_scalar_eval.zig:"GAP-0866: timeseries.value through real parse+execute"; OWNER=timeseries; UPDATED=2026-06-10
const std = @import("std");
const geode = @import("geode");
const execution = geode.execution;
const eval = geode.eval;
const ts = geode.timeseries;

const SeriesKey = ts.SeriesKey;
const Point = ts.Point;
const Store = ts.Store;
const Value = geode.value_types.Value;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Parse + execute a single statement through the full execution path — the
/// same entry the QUIC/gRPC servers use (`executeStatementWithContext`).
fn runQuery(
    allocator: std.mem.Allocator,
    query: []const u8,
) !execution.ExecutionResult {
    var parsed = try geode.parseGql(query, allocator);
    defer parsed.deinit();

    const catalog = try execution.ensureCatalogInstance(allocator);
    defer execution.cleanupCatalogInstance();
    defer geode.graph_store.deinitGlobalStore();

    const ctx = execution.ExecutionContext{ .catalog = catalog };
    return execution.executeStatementWithContext(allocator, parsed.program.statements[0], ctx);
}

/// Seed a Store with the canonical fixture series.
/// device 1, metric 'temp': (100,10) (200,20) (300,30) (400,40).
fn seedStore(allocator: std.mem.Allocator) !Store {
    var store = Store.init(allocator);
    errdefer store.deinit();
    const key = SeriesKey{ .device_id = 1, .metric = "temp" };
    try store.insertMany(key, &[_]Point{
        .{ .ts = 100, .value = 10 },
        .{ .ts = 200, .value = 20 },
        .{ .ts = 300, .value = 30 },
        .{ .ts = 400, .value = 40 },
    });
    return store;
}

/// Arena-backed harness mirroring the server's per-request arena (GAP-0755).
const ArenaHarness = struct {
    arena: std.heap.ArenaAllocator,
    store: Store,

    fn init() !ArenaHarness {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const store = try seedStore(arena.allocator());
        return .{ .arena = arena, .store = store };
    }

    fn install(self: *ArenaHarness) void {
        eval.setGlobalTimeseriesStore(&self.store);
    }

    fn allocator(self: *ArenaHarness) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn deinit(self: *ArenaHarness) void {
        eval.setGlobalTimeseriesStore(null);
        self.arena.deinit();
    }
};

fn expectSingleInt(res: execution.ExecutionResult, expected: i64) !void {
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expect(res.rows[0][0] == .Int);
    try std.testing.expectEqual(expected, res.rows[0][0].Int);
}

fn expectSingleDoubleApprox(res: execution.ExecutionResult, expected: f64) !void {
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expect(res.rows[0][0] == .Double);
    try std.testing.expectApproxEqAbs(expected, res.rows[0][0].Double, 1e-9);
}

fn expectSingleList(res: execution.ExecutionResult, min_len: usize) ![]const Value {
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expect(res.rows[0][0] == .List);
    try std.testing.expect(res.rows[0][0].List.len >= min_len);
    return res.rows[0][0].List;
}

// ---------------------------------------------------------------------------
// Series-based functions (resolve the real Store via the server-boot global)
// ---------------------------------------------------------------------------

test "GAP-0866: timeseries.value through real parse+execute" {
    // Strict allocator: the scalar path must be leak-free without an arena.
    const allocator = std.testing.allocator;
    var store = try seedStore(allocator);
    defer store.deinit();
    eval.setGlobalTimeseriesStore(&store);
    defer eval.setGlobalTimeseriesStore(null);

    var res = try runQuery(allocator, "RETURN timeseries.value(1, 'temp', 200) AS v");
    defer res.deinit(allocator);
    try expectSingleInt(res, 20);
}

test "GAP-0866: timeseries.last_value through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();
    h.install();

    const res = try runQuery(h.allocator(), "RETURN timeseries.last_value(1, 'temp').value AS v");
    try expectSingleInt(res, 40);
}

test "GAP-0866: timeseries.value_at through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();
    h.install();

    const res = try runQuery(h.allocator(), "RETURN timeseries.value_at(1, 'temp', 300).value AS v");
    try expectSingleInt(res, 30);
}

test "GAP-0866: timeseries.sample_by avg through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();
    h.install();

    const res = try runQuery(h.allocator(), "RETURN timeseries.sample_by(1, 'temp', 200, 100, 400, 'avg') AS s");
    const list = try expectSingleList(res, 1);
    // Every sample is a {ts, value} map.
    for (list) |item| {
        try std.testing.expect(item == .Map);
        try std.testing.expect(item.Map.get("ts") != null);
        try std.testing.expect(item.Map.get("value") != null);
    }
}

test "GAP-0866: timeseries.sample_by sum/first/last aggregations (TS-AGG-006..008)" {
    inline for (.{ "sum", "first", "last" }) |agg| {
        var h = try ArenaHarness.init();
        defer h.deinit();
        h.install();

        const res = try runQuery(
            h.allocator(),
            "RETURN timeseries.sample_by(1, 'temp', 200, 100, 400, '" ++ agg ++ "') AS s",
        );
        _ = try expectSingleList(res, 1);
    }
}

test "GAP-0866: timeseries.time_bucket through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();
    h.install();

    const res = try runQuery(h.allocator(), "RETURN timeseries.time_bucket(1, 'temp', 200000, 100, 400) AS b");
    const list = try expectSingleList(res, 1);
    for (list) |item| {
        try std.testing.expect(item == .Map);
        try std.testing.expect(item.Map.get("avg") != null);
    }
}

test "GAP-0866: timeseries.interpolate linear through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();
    h.install();

    const res = try runQuery(h.allocator(), "RETURN timeseries.interpolate(1, 'temp', 250, 'linear').value AS v");
    try expectSingleInt(res, 25);
}

test "GAP-0866: timeseries.moving_avg through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();
    h.install();

    const res = try runQuery(h.allocator(), "RETURN timeseries.moving_avg(1, 'temp', 200, 100) AS m");
    _ = try expectSingleList(res, 1);
}

test "GAP-0866: timeseries.rate through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();
    h.install();

    const res = try runQuery(h.allocator(), "RETURN timeseries.rate(1, 'temp', 1000) AS r");
    // 4 points -> 3 deltas; each delta is +10 over 100 time units scaled by
    // interval 1000 -> rate 100.0.
    const list = try expectSingleList(res, 3);
    try std.testing.expect(list[0] == .Map);
    const rate0 = list[0].Map.get("rate").?;
    try std.testing.expect(rate0 == .Double);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), rate0.Double, 1e-9);
}

test "GAP-0866: timeseries.derivative through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();
    h.install();

    const res = try runQuery(h.allocator(), "RETURN timeseries.derivative(1, 'temp', 1) AS d");
    // First-order derivative: dv=10 over dt=0.1s -> 100.0 per second.
    const list = try expectSingleList(res, 3);
    try std.testing.expect(list[0] == .Map);
    const d0 = list[0].Map.get("derivative").?;
    try std.testing.expect(d0 == .Double);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), d0.Double, 1e-9);
}

test "GAP-0866: timeseries.change_points through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();
    h.install();

    const res = try runQuery(h.allocator(), "RETURN timeseries.change_points(1, 'temp', 100, 400, 1.0, 2) AS c");
    // A short monotone ramp may legitimately contain zero change points; the
    // contract under test is List-of-Int through the real path, not PELT math.
    const list = try expectSingleList(res, 0);
    for (list) |item| try std.testing.expect(item == .Int);
}

test "GAP-0866: timeseries.extract_features through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();
    h.install();

    const res = try runQuery(h.allocator(), "RETURN timeseries.extract_features(1, 'temp', 100, 400) AS f");
    // 22-element feature vector from the external library.
    const list = try expectSingleList(res, 22);
    for (list) |item| try std.testing.expect(item == .Double);
}

test "GAP-0866: timeseries.matrix_profile through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();
    h.install();

    const res = try runQuery(h.allocator(), "RETURN timeseries.matrix_profile(1, 'temp', 100, 400, 2) AS p");
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expect(res.rows[0][0] == .Map);
    const map = res.rows[0][0].Map;
    try std.testing.expect(map.get("profile") != null);
    try std.testing.expect(map.get("indices") != null);
}

test "GAP-0866: timeseries.z_normalize through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();
    h.install();

    const res = try runQuery(h.allocator(), "RETURN timeseries.z_normalize(1, 'temp', 100, 400) AS z");
    const list = try expectSingleList(res, 4);
    for (list) |item| try std.testing.expect(item == .Double);
}

test "GAP-0866: timeseries.invariants through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();
    h.install();

    const res = try runQuery(h.allocator(), "RETURN timeseries.invariants(1, 'temp', 100, 400).mean AS m");
    try expectSingleDoubleApprox(res, 25.0);
}

// ---------------------------------------------------------------------------
// Array-based functions (GAP-0290; take f64 list literals directly).
// Float literals parse to exact-numeric Decimals — these tests pin the
// GAP-0866 fix that accepts Decimal list elements / penalty / gamma.
// ---------------------------------------------------------------------------

test "GAP-0866: timeseries.dtw through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();

    const res = try runQuery(h.allocator(), "RETURN timeseries.dtw([1.0, 2.0, 3.0], [1.0, 2.0, 3.0], 1) AS d");
    try expectSingleDoubleApprox(res, 0.0);
}

test "GAP-0866: timeseries.dtw_derivative through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();

    const res = try runQuery(h.allocator(), "RETURN timeseries.dtw_derivative([1.0, 2.0, 3.0, 4.0], [1.0, 2.0, 3.0, 4.0], 1) AS d");
    try expectSingleDoubleApprox(res, 0.0);
}

test "GAP-0866: timeseries.dtw_open_end through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();

    const res = try runQuery(h.allocator(), "RETURN timeseries.dtw_open_end([1.0, 2.0, 3.0], [1.0, 2.0, 3.0]) AS d");
    try expectSingleDoubleApprox(res, 0.0);
}

test "GAP-0866: timeseries.dtw_shape through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();

    const res = try runQuery(h.allocator(), "RETURN timeseries.dtw_shape([1.0, 2.0, 3.0], [1.0, 2.0, 3.0], 1) AS d");
    try expectSingleDoubleApprox(res, 0.0);
}

test "GAP-0866: timeseries.dtw_soft through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();

    const res = try runQuery(h.allocator(), "RETURN timeseries.dtw_soft([1.0, 2.0, 3.0], [1.0, 2.0, 3.0], 1.0) AS d");
    // Soft-DTW of identical short series is a small (possibly negative)
    // smoothed distance; the contract under test is a Double through the path.
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expect(res.rows[0][0] == .Double);
}

test "GAP-0866: timeseries.cosine_similarity through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();

    const res = try runQuery(h.allocator(), "RETURN timeseries.cosine_similarity([1.0, 2.0], [1.0, 2.0]) AS c");
    try expectSingleDoubleApprox(res, 1.0);
}

test "GAP-0866: timeseries.cross_correlate through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();

    const res = try runQuery(h.allocator(), "RETURN timeseries.cross_correlate([1.0, 2.0, 3.0], [1.0, 2.0, 3.0]).lag AS l");
    try expectSingleInt(res, 0);
}

test "GAP-0866: timeseries.sbd through real parse+execute" {
    var h = try ArenaHarness.init();
    defer h.deinit();

    const res = try runQuery(h.allocator(), "RETURN timeseries.sbd([1.0, 2.0, 3.0], [1.0, 2.0, 3.0]) AS s");
    try expectSingleDoubleApprox(res, 0.0);
}

// ---------------------------------------------------------------------------
// Store-resolution contract: without a store, series functions return Null
// (never crash) through the same real path.
// ---------------------------------------------------------------------------

test "GAP-0866: series functions return Null without a store" {
    const allocator = std.testing.allocator;
    eval.setGlobalTimeseriesStore(null);

    var res = try runQuery(allocator, "RETURN timeseries.last_value(1, 'temp') AS v");
    defer res.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expect(res.rows[0][0] == .Null);
}
