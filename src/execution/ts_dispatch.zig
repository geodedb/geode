/// Timeseries Dispatch Module
///
/// Handles routing for the `geode.ts.*` procedure family — the native GQL
/// surface over the timeseries-storage backed Store. This is the direct analog
/// of `fts_dispatch.zig` (the `geode.fts.*` family): row-returning and write
/// operations are exposed via the ISO/IEC 39075:2024 `CALL <proc>(args) [YIELD …]`
/// surface, returning ordinary `ExecutionResult{ columns, rows }` tables that
/// flow over the same in-process / QUIC / gRPC result encoder as every other
/// procedure — no client or transport change, no grammar change (runtime
/// dotted-name dispatch).
///
/// Before this family, there was NO GQL way to WRITE or richly query timeseries
/// over the wire; the 13 scalar `timeseries.*` eval FUNCTIONS only read. The
/// row-returning queries (`range`, `last`, `bucket_avg`, `sample_by`) and the
/// ingest verbs (`insert`, `insert_many`) become procedures because ISO GQL
/// exposes a row set ONLY through `CALL … YIELD`.
///
/// Procedures:
///   - geode.ts.insert(device_id, metric, ts, value)            → YIELD inserted
///   - geode.ts.insert_many(device_id, metric, points)          → YIELD inserted
///   - geode.ts.range(device_id, metric, start_ts, end_ts)      → YIELD ts, value
///   - geode.ts.last(device_id, metric)                         → YIELD ts, value
///   - geode.ts.bucket_avg(device_id, metric, start_ts, end_ts, bucket_seconds)
///                                                              → YIELD bucket_ts, avg
///   - geode.ts.sample_by(device_id, metric, interval_ms, start_ts, end_ts, agg)
///                                                              → YIELD bucket_ts, value
///
/// Value type: i64 ONLY in this surface. A GQL `Int` maps to storage `i64`
/// losslessly (identity). A GQL float literal (`DoubleLit`/`RealLit`/`Decimal`)
/// for a `value`/`ts` argument is REJECTED with `error.TypeMismatch` — there is
/// no wired f64 (`PointF64`) lane through the Store, so accepting a Double would
/// force a silent lossy choice. The float lane is a deferred, explicit follow-up.
///
/// Store resolution: `eval.getTimeseriesStoreForGraph(null)` — the DEFAULT graph
/// / global pointer, exactly the server-boot store. This mirrors the FTS path's
/// posture (FTS hardcodes the DEFAULT graph too); per-graph context plumbing is
/// a follow-up. A missing store is `error.Unsupported` (a clear failure, not a
/// silent empty set).
const std = @import("std");
const ast = @import("../gql/ast.zig");
const value_types = @import("../value_types.zig");
const eval = @import("../eval.zig");
const ts = @import("../timeseries/timeseries.zig");

const execution = @import("../execution.zig");
const execution_helpers = @import("execution_helpers.zig");
const filterYieldColumns = execution_helpers.filterYieldColumns;
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;

const Value = value_types.Value;
const Aggregation = ts.lib.store.Aggregation;

/// Execute a `geode.ts.*` procedure. Returns null if the procedure name is not
/// recognized by this dispatcher (the router falls through to UnknownProcedure).
///
/// `proc_name` is the ASCII-lowercased, dotted procedure name (e.g.
/// "geode.ts.range") produced by `procedure_registry.extractNormalizedProcName`.
pub fn execute(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    call_stmt: ast.CallProcedure,
    context: ExecutionContext,
) !?ExecutionResult {
    _ = context;
    if (std.mem.eql(u8, proc_name, "geode.ts.insert")) return try handleInsert(allocator, call_stmt);
    if (std.mem.eql(u8, proc_name, "geode.ts.insert_many")) return try handleInsertMany(allocator, call_stmt);
    if (std.mem.eql(u8, proc_name, "geode.ts.range")) return try handleRange(allocator, call_stmt);
    if (std.mem.eql(u8, proc_name, "geode.ts.last")) return try handleLast(allocator, call_stmt);
    if (std.mem.eql(u8, proc_name, "geode.ts.bucket_avg")) return try handleBucketAvg(allocator, call_stmt);
    if (std.mem.eql(u8, proc_name, "geode.ts.sample_by")) return try handleSampleBy(allocator, call_stmt);
    return null;
}

// ---------------------------------------------------------------------------
// Argument extraction helpers (mirror fts_dispatch's literal-only contract).
// ---------------------------------------------------------------------------

/// The positional argument list of the CALL, or `error.InvalidArgs` if the
/// CallProcedure is not a plain procedure call expression.
fn args(call_stmt: ast.CallProcedure) ![]*ast.Expr {
    return switch (call_stmt.procedure) {
        .Call => |call| call.args,
        else => error.InvalidArgs,
    };
}

/// Extract an integer literal argument. Accepts the AST `.Int` literal (i64)
/// and a unary-negated integer (`-1` parses as `Unary{ .op = .Neg, .expr =
/// .Int }`, not a literal `.Int = -1`). A float literal
/// (`.DoubleLit`/`.RealLit`/`.Decimal`) or any other expression kind is rejected
/// with `error.TypeMismatch` — i64-only ingest.
fn literalInt(expr: *const ast.Expr) error{ TypeMismatch, IntegerOverflow }!i64 {
    return switch (expr.*) {
        .Int => |n| n,
        .Unary => |u| switch (u.op) {
            .Neg => blk: {
                const inner = try literalInt(u.expr);
                break :blk std.math.negate(inner) catch return error.IntegerOverflow;
            },
            .Pos => try literalInt(u.expr),
            else => error.TypeMismatch,
        },
        else => error.TypeMismatch,
    };
}

/// Extract a string literal argument (the form a quoted GQL string parses to).
fn literalString(expr: *const ast.Expr) ![]const u8 {
    return switch (expr.*) {
        .String => |s| s,
        else => error.TypeMismatch,
    };
}

/// Extract the element slice from a list-literal expression. A GQL `[...]`
/// literal parses to `Expr.List` (or `Expr.ArrayLit` on the array-constructor
/// path); both carry `[]*Expr`. Anything else is `error.TypeMismatch`.
fn asExprList(expr: *ast.Expr) ![]*ast.Expr {
    return switch (expr.*) {
        .List => |items| items,
        .ArrayLit => |items| items,
        else => error.TypeMismatch,
    };
}

/// Resolve the timeseries Store on the DEFAULT graph / global pointer, mirroring
/// the FTS facade resolution posture. A missing store is a hard failure.
fn resolveStore() !*ts.Store {
    return eval.getTimeseriesStoreForGraph(null) orelse error.Unsupported;
}

/// Build a `SeriesKey` from the first two positional args `(device_id, metric)`.
/// `device_id` is the storage `u64`; a negative GQL i64 is out of range and is
/// rejected with `error.InvalidArgs`.
fn keyOf(a: []*ast.Expr) !ts.SeriesKey {
    const device_i64 = try literalInt(a[0]);
    if (device_i64 < 0) return error.InvalidArgs;
    return .{ .device_id = @intCast(device_i64), .metric = try literalString(a[1]) };
}

/// Project the YIELD columns when present (e.g. `YIELD value` only), matching
/// the FTS path exactly. The YIELD names match the result columns
/// case-insensitively.
fn maybeYield(allocator: std.mem.Allocator, result: ExecutionResult, call_stmt: ast.CallProcedure) !ExecutionResult {
    var r = result;
    if (call_stmt.yield_items) |yield_items| {
        r = try filterYieldColumns(allocator, r, yield_items);
    }
    return r;
}

/// Allocate a 1-row `inserted = n` status table (the write-procedure result).
fn insertedTable(allocator: std.mem.Allocator, n: i64) !ExecutionResult {
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "inserted");
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = try allocator.alloc(Value, 1);
    rows[0][0] = Value{ .Int = n };
    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// ---------------------------------------------------------------------------
// WRITE procedures (classified .mutating by default — left out of
// procedure_access.read_only_procedure_names).
// ---------------------------------------------------------------------------

/// `geode.ts.insert(device_id, metric, ts, value)` → 1-row `inserted = 1`.
fn handleInsert(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) !ExecutionResult {
    const a = try args(call_stmt);
    if (a.len != 4) return error.InvalidArgs;
    const key = try keyOf(a);
    const pt = ts.Point{ .ts = try literalInt(a[2]), .value = try literalInt(a[3]) };
    const store = try resolveStore();
    store.insertMany(key, &.{pt}) catch return error.Unsupported;
    const result = try insertedTable(allocator, 1);
    return try maybeYield(allocator, result, call_stmt);
}

/// `geode.ts.insert_many(device_id, metric, points)` where `points` is a list
/// of 2-element `[ts, value]` Int lists, e.g. `[[100, 72], [110, 73]]`. Returns
/// 1-row `inserted = N`. One sort + one WAL append for the whole batch.
fn handleInsertMany(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) !ExecutionResult {
    const a = try args(call_stmt);
    if (a.len != 3) return error.InvalidArgs;
    const key = try keyOf(a);

    // The `points` argument is a list literal of 2-element [ts, value] lists.
    // Accept either AST list variant (.List / .ArrayLit).
    const points_list = try asExprList(a[2]);

    // Build the point slice on a temp arena (freed after the single insertMany).
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const pts = try aa.alloc(ts.Point, points_list.len);
    for (points_list, 0..) |inner_expr, i| {
        const inner = try asExprList(inner_expr);
        if (inner.len != 2) return error.InvalidArgs;
        pts[i] = ts.Point{ .ts = try literalInt(inner[0]), .value = try literalInt(inner[1]) };
    }

    const store = try resolveStore();
    store.insertMany(key, pts) catch return error.Unsupported;

    const result = try insertedTable(allocator, @intCast(points_list.len));
    return try maybeYield(allocator, result, call_stmt);
}

// ---------------------------------------------------------------------------
// READ procedures (classified .read_only via procedure_access).
// ---------------------------------------------------------------------------

/// `geode.ts.range(device_id, metric, start_ts, end_ts)` → rows of `(ts, value)`,
/// one per stored point in `[start_ts, end_ts]` (inclusive). The fts.search analog.
fn handleRange(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) !ExecutionResult {
    const a = try args(call_stmt);
    if (a.len != 4) return error.InvalidArgs;
    const key = try keyOf(a);
    const start_ts = try literalInt(a[2]);
    const end_ts = try literalInt(a[3]);
    const store = try resolveStore();

    // queryRange allocates the Point slice with the request `allocator`; we copy
    // the i64 values into the result rows (by value) and free the intermediate
    // slice here. The result rows hold only scalar Ints (no owned heap memory),
    // so ExecutionResult.deinit's value-free path is a no-op for them.
    const pts = store.queryRange(key, start_ts, end_ts, allocator) catch return error.Unsupported;
    defer allocator.free(pts);

    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "ts");
    columns[1] = try allocator.dupe(u8, "value");

    const rows = try allocator.alloc([]Value, pts.len);
    for (pts, 0..) |pt, i| {
        const row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = pt.ts };
        row[1] = Value{ .Int = pt.value };
        rows[i] = row;
    }

    const result = ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
    return try maybeYield(allocator, result, call_stmt);
}

/// `geode.ts.last(device_id, metric)` → 0 or 1 row of `(ts, value)`. An empty /
/// missing series returns 0 rows (the spec-clean "no result"), not an error.
fn handleLast(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) !ExecutionResult {
    const a = try args(call_stmt);
    if (a.len != 2) return error.InvalidArgs;
    const key = try keyOf(a);
    const store = try resolveStore();

    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "ts");
    columns[1] = try allocator.dupe(u8, "value");

    var rows: [][]Value = undefined;
    if (store.last(key)) |pt| {
        rows = try allocator.alloc([]Value, 1);
        rows[0] = try allocator.alloc(Value, 2);
        rows[0][0] = Value{ .Int = pt.ts };
        rows[0][1] = Value{ .Int = pt.value };
    } else {
        rows = try allocator.alloc([]Value, 0);
    }

    const result = ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
    return try maybeYield(allocator, result, call_stmt);
}

/// `geode.ts.bucket_avg(device_id, metric, start_ts, end_ts, bucket_seconds)`
/// → rows of `(bucket_ts, avg)`. `avg` is `Null` for an empty bucket.
fn handleBucketAvg(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) !ExecutionResult {
    const a = try args(call_stmt);
    if (a.len != 5) return error.InvalidArgs;
    const key = try keyOf(a);
    const start_ts = try literalInt(a[2]);
    const end_ts = try literalInt(a[3]);
    const bucket_seconds = try literalInt(a[4]);
    const store = try resolveStore();

    const out = store.timeBucketAvg(key, bucket_seconds, start_ts, end_ts, allocator) catch return error.Unsupported;
    defer allocator.free(out);

    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "bucket_ts");
    columns[1] = try allocator.dupe(u8, "avg");

    const rows = try allocator.alloc([]Value, out.len);
    for (out, 0..) |bucket, i| {
        const row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = bucket.ts };
        row[1] = if (bucket.avg) |v| Value{ .Int = v } else Value{ .Null = {} };
        rows[i] = row;
    }

    const result = ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
    return try maybeYield(allocator, result, call_stmt);
}

/// `geode.ts.sample_by(device_id, metric, interval_ms, start_ts, end_ts, agg)`
/// → rows of `(bucket_ts, value)`. `agg` is one of
/// avg/min/max/count/sum/first/last (case-insensitive). `value` is `Null` for
/// an empty bucket.
fn handleSampleBy(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) !ExecutionResult {
    const a = try args(call_stmt);
    if (a.len != 6) return error.InvalidArgs;
    const key = try keyOf(a);
    const interval_ms = try literalInt(a[2]);
    const start_ts = try literalInt(a[3]);
    const end_ts = try literalInt(a[4]);
    const agg_str = try literalString(a[5]);
    const agg = parseAggregation(agg_str) orelse return error.InvalidArgs;
    const store = try resolveStore();

    const out = store.sampleBy(key, interval_ms, start_ts, end_ts, agg, allocator) catch return error.Unsupported;
    defer allocator.free(out);

    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "bucket_ts");
    columns[1] = try allocator.dupe(u8, "value");

    const rows = try allocator.alloc([]Value, out.len);
    for (out, 0..) |sample, i| {
        const row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = sample.ts };
        row[1] = if (sample.value) |v| Value{ .Int = v } else Value{ .Null = {} };
        rows[i] = row;
    }

    const result = ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
    return try maybeYield(allocator, result, call_stmt);
}

/// Map an aggregation name to the storage `Aggregation` enum (case-insensitive),
/// reusing the exact set the existing `timeseries.sample_by` eval function
/// accepts (eval.zig). Returns null for an unknown name.
fn parseAggregation(s: []const u8) ?Aggregation {
    if (std.ascii.eqlIgnoreCase(s, "avg")) return .avg;
    if (std.ascii.eqlIgnoreCase(s, "sum")) return .sum;
    if (std.ascii.eqlIgnoreCase(s, "min")) return .min;
    if (std.ascii.eqlIgnoreCase(s, "max")) return .max;
    if (std.ascii.eqlIgnoreCase(s, "count")) return .count;
    if (std.ascii.eqlIgnoreCase(s, "first")) return .first;
    if (std.ascii.eqlIgnoreCase(s, "last")) return .last;
    return null;
}
