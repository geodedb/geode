// CANARY: REQ=REQ-ENG-3904-LIST-LEADING-NEGATIVE; FEATURE="ListValueConstructor"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_eng3904_3905_vector_literals.zig:1; OWNER=parser; UPDATED=2026-08-24
// CANARY: REQ=REQ-ENG-3905-VECTORF32-PARAM; FEATURE="VectorF32"; ASPECT=ParameterBinding; STATUS=TESTED; TEST=tests/test_eng3904_3905_vector_literals.zig:1; OWNER=parser; UPDATED=2026-08-24
//
// Reproduction tests for two parser-level rejections of VALID GQL.
//
// ENG-3904 — a list literal whose FIRST element is negative is a parse error:
//
//     RETURN [-0.0483, 1.0]
//     → 42000 "expected token 'l_paren', got 'minus'"
//
//   Root cause: the pattern-comprehension heuristic in
//   src/gql/parser.zig:3951 treats `[` followed by `.minus` (or `.arrow_l`)
//   as the start of a graph pattern and routes into parseGraphPattern(),
//   which cannot parse a numeric expression. Controls that already work and
//   must keep working: `RETURN [1.0, -0.0483]` (negative NOT first) and
//   `RETURN -1` (bare negative), plus real pattern comprehensions.
//
// ENG-3905 — vectorf32($param) is rejected at PARSE time:
//
//     geode query --param vec '[1.0,2.0,3.0]' "RETURN vectorf32($vec)"
//     → 42000 "invalid builtin function call"
//
//   Root cause: the parse-time validateBuiltinCall gate
//   (src/gql/parser.zig:4237/4240) accepts only an ArrayLit or a string-like
//   argument; an `ast.Param` node is not accepted — even though the runtime
//   constructor already handles a List argument
//   (constructVectorF32, src/eval_extended.zig:625-658).
//
//   `--param vec '[1.0,2.0,3.0]'` arrives as Value.List of Value.Double
//   (src/cli/main.zig:jsonToProtoValue → src/server/proto_util.zig:64), so
//   that is the exact param shape exercised here. Invalid param values must
//   still be REJECTED (error.TypeMismatch) rather than silently coerced or
//   silently resolved to NULL.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

// Serialize the executing tests in this file — the graph_store/catalog state
// is process-wide and the build's test runner may run tests in parallel.
// Mirrors tests/test_merge_relationship_bugs.zig.
var test_mutex: std.Io.Mutex = .init;

// ---------------------------------------------------------------------------
// Parse-only helpers (no global state — safe without the mutex).
// ---------------------------------------------------------------------------

fn expectParseOk(src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try geode.parseGqlOutcome(src, arena.allocator(), .{});
    switch (result) {
        .Ok => {},
        .Err => |e| {
            std.debug.print("\nPARSE FAILED for: {s}\n  error: {s}\n", .{ src, e.msg });
            return error.UnexpectedParseError;
        },
    }
}

// ---------------------------------------------------------------------------
// Execution harness (mirrors tests/test_bug731_aggregates_vectors.zig).
// ---------------------------------------------------------------------------

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .session = execution.SessionState.init(allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.arena.deinit();
        self.tmp.cleanup();
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        return self.execParams(query, &.{}, &.{});
    }

    /// Execute with query-level parameter bindings, exactly the way the QUIC
    /// handler supplies `geode query --param <name> <json>` values.
    pub fn execParams(
        self: *Harness,
        query: []const u8,
        param_names: []const []const u8,
        param_values: []const Value,
    ) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        var ctx = self.ctx;
        ctx.session_state = &self.session;
        ctx.query_param_names = param_names;
        ctx.query_param_values = param_values;
        return execution.executeProgramWithContext(aa, &parsed.program, ctx);
    }

    /// Single value of a single-row/single-column result.
    pub fn scalarParams(
        self: *Harness,
        query: []const u8,
        param_names: []const []const u8,
        param_values: []const Value,
    ) !Value {
        const res = try self.execParams(query, param_names, param_values);
        if (res.rows.len != 1) return error.ExpectedOneRow;
        if (res.rows[0].len != 1) return error.ExpectedOneColumn;
        return res.rows[0][0];
    }
};

/// Assert a value is a VECTOR (VectorF32) of the expected dimension, and
/// return its components. A NULL / non-vector value fails loudly — the point
/// of both bugs is that the vector must actually materialize.
fn expectVectorF32(v: Value, expected_dim: usize) ![]const f32 {
    switch (v) {
        .ExtValue => |ext| switch (ext) {
            .VectorF32 => |vec| {
                if (vec.data.len != expected_dim) {
                    std.debug.print("\nFAIL: vector dim {d}; expected {d}\n", .{ vec.data.len, expected_dim });
                    return error.WrongVectorDimension;
                }
                return vec.data;
            },
            else => {
                std.debug.print("\nFAIL: expected VectorF32, got ExtValue.{s}\n", .{@tagName(ext)});
                return error.ExpectedVectorF32;
            },
        },
        else => {
            std.debug.print("\nFAIL: expected VectorF32, got Value.{s}\n", .{@tagName(v)});
            return error.ExpectedVectorF32;
        },
    }
}

fn expectApprox(expected: f32, actual: f32) !void {
    try testing.expect(std.math.approxEqAbs(f32, expected, actual, 1e-6));
}

// ---------------------------------------------------------------------------
// ENG-3904 — list literal with a leading negative element
// ---------------------------------------------------------------------------

test "ENG-3904/3905 control: the already-working vectorf32 forms build a VECTOR" {
    // Green today. Also self-checks `expectVectorF32` against the shape the
    // engine really projects, so a failure of the sibling tests below can only
    // mean the bug — not a wrong assertion helper.
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    const s = try h.scalarParams("RETURN vectorf32('[1.0, 2.0, 3.0]') AS v", &.{}, &.{});
    const sdata = try expectVectorF32(s, 3);
    try expectApprox(1.0, sdata[0]);

    const l = try h.scalarParams("RETURN vectorf32([1.0, 2.0, 3.0]) AS v", &.{}, &.{});
    const ldata = try expectVectorF32(l, 3);
    try expectApprox(3.0, ldata[2]);

    // WITH-variable control from the ENG-3905 triage: the runtime constructor
    // already accepts a List argument once the parse gate lets it through.
    const w = try h.scalarParams("WITH [1.0, 2.0, 3.0] AS xs RETURN vectorf32(xs) AS v", &.{}, &.{});
    const wdata = try expectVectorF32(w, 3);
    try expectApprox(2.0, wdata[1]);
}

test "ENG-3904: a list literal whose first element is negative parses" {
    // FAILS on v0.8.5: 42000 "expected token 'l_paren', got 'minus'".
    try expectParseOk("RETURN [-0.0483, 1.0]");
    try expectParseOk("RETURN [-1, 2, 3]");
    try expectParseOk("RETURN [-1.5]");
    try expectParseOk("WITH [-0.0483, 1.0, 2.0] AS v RETURN v");
    try expectParseOk("RETURN [-0.0483, 1.0, 2.0][0]");
    try expectParseOk("CREATE (t:VecTest3904 {embedding: vectorf32([-0.0483, 1.0, 2.0])})");
}

test "ENG-3904 control: negative elements elsewhere and bare negatives still parse" {
    // Green today; guards against a regression while relaxing the heuristic.
    try expectParseOk("RETURN [1.0, -0.0483]");
    try expectParseOk("RETURN [1, 2, -3]");
    try expectParseOk("RETURN -1");
    try expectParseOk("RETURN vectorf32([1.0, -0.0483, 2.0])");
    try expectParseOk("RETURN []");
}

test "ENG-3904 control: pattern comprehensions must keep parsing" {
    // The heuristic at parser.zig:3951 exists to route these into
    // parseGraphPattern(); the ENG-3904 fix must not break them.
    try expectParseOk("MATCH (a:P3904) RETURN [(a)-[:R3904]->(b) | b] AS xs");
    try expectParseOk("MATCH (a:P3904) RETURN [(a)<-[:R3904]-(b) | b] AS xs");
    try expectParseOk("MATCH (a:P3904) RETURN [(a)-[:R3904]->(b) WHERE b.n > 1 | b] AS xs");
    // List comprehension (the other `[`-prefixed form).
    try expectParseOk("RETURN [x IN [1, 2, 3] WHERE x > 1 | x] AS xs");
}

test "ENG-3904: vectorf32 with a leading-negative literal evaluates to a VECTOR" {
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    const v = try h.scalarParams("RETURN vectorf32([-0.0483, 1.0, 2.0]) AS v", &.{}, &.{});
    const data = try expectVectorF32(v, 3);
    try expectApprox(-0.0483, data[0]);
    try expectApprox(1.0, data[1]);
    try expectApprox(2.0, data[2]);
}

test "ENG-3904: a leading-negative vector literal round-trips through a node property" {
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    {
        var r = try h.exec("CREATE (t:VecTest3904 {id: 1, embedding: vectorf32([-0.0483, 1.0, 2.0])})");
        r.deinit(allocator);
    }

    const v = try h.scalarParams(
        "MATCH (t:VecTest3904 {id: 1}) RETURN t.embedding AS v",
        &.{},
        &.{},
    );
    const data = try expectVectorF32(v, 3);
    try expectApprox(-0.0483, data[0]);
}

// ---------------------------------------------------------------------------
// ENG-3905 — vectorf32($param)
// ---------------------------------------------------------------------------

test "ENG-3905: vectorf32($param) parses" {
    // FAILS on v0.8.5: 42000 "invalid builtin function call" — rejected by the
    // parse-time builtin-argument gate before any parameter is bound.
    try expectParseOk("RETURN vectorf32($vec)");
    try expectParseOk("RETURN vectorf32($vec) AS v");
    try expectParseOk("CREATE (t:VecParam3905 {id: 1, embedding: vectorf32($vec)})");
    try expectParseOk("RETURN vectori32($vec)");
}

test "ENG-3905: vectorf32($vec) with a list parameter evaluates to a VECTOR" {
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    const names = [_][]const u8{"vec"};

    // `--param vec '[1.0,2.0,3.0]'` → List of Double (proto DOUBLE).
    var doubles = [_]Value{ .{ .Double = 1.0 }, .{ .Double = 2.0 }, .{ .Double = 3.0 } };
    const double_params = [_]Value{.{ .List = &doubles }};
    const dv = try h.scalarParams("RETURN vectorf32($vec) AS v", &names, &double_params);
    const ddata = try expectVectorF32(dv, 3);
    try expectApprox(1.0, ddata[0]);
    try expectApprox(2.0, ddata[1]);
    try expectApprox(3.0, ddata[2]);

    // `--param vec '[1,2,3]'` → List of Int.
    var ints = [_]Value{ .{ .Int = 1 }, .{ .Int = 2 }, .{ .Int = 3 } };
    const int_params = [_]Value{.{ .List = &ints }};
    const iv = try h.scalarParams("RETURN vectorf32($vec) AS v", &names, &int_params);
    const idata = try expectVectorF32(iv, 3);
    try expectApprox(1.0, idata[0]);
    try expectApprox(3.0, idata[2]);
}

test "ENG-3905: a vectorf32($vec) parameter stores as a VECTOR node property" {
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    const names = [_][]const u8{"vec"};
    var doubles = [_]Value{ .{ .Double = 1.0 }, .{ .Double = 2.0 }, .{ .Double = 3.0 } };
    const params = [_]Value{.{ .List = &doubles }};

    {
        var r = try h.execParams(
            "CREATE (t:VecParam3905 {id: 1, embedding: vectorf32($vec)})",
            &names,
            &params,
        );
        r.deinit(allocator);
    }

    const v = try h.scalarParams(
        "MATCH (t:VecParam3905 {id: 1}) RETURN t.embedding AS v",
        &.{},
        &.{},
    );
    const data = try expectVectorF32(v, 3);
    try expectApprox(1.0, data[0]);
    try expectApprox(3.0, data[2]);
}

test "ENG-3905 control: a non-list vectorf32 ARGUMENT already errors with TypeMismatch" {
    // Green today via a WITH variable (which the parse gate lets through).
    // This pins the error shape the $param path must match after the fix.
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    try testing.expectError(
        error.TypeMismatch,
        h.exec("WITH 42 AS x RETURN vectorf32(x) AS v"),
    );
}

test "ENG-3905 negative: a non-list vectorf32 parameter is rejected, not coerced" {
    // Accepting `$param` at parse time must NOT open a silent-accept hole:
    // a scalar (non-list, non-vector-string) parameter has to fail loudly at
    // evaluation time with error.TypeMismatch — the same shape GAP-0918
    // pinned for the malformed vector literal — instead of yielding NULL or
    // a coerced 1-element vector.
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    const names = [_][]const u8{"bad"};
    const int_param = [_]Value{.{ .Int = 42 }};
    try testing.expectError(
        error.TypeMismatch,
        h.execParams("RETURN vectorf32($bad) AS v", &names, &int_param),
    );

    // A string parameter that is not a vector literal is equally invalid.
    const str_param = [_]Value{.{ .Str = "not-a-vector" }};
    if (h.execParams("RETURN vectorf32($bad) AS v", &names, &str_param)) |res| {
        var r = res;
        defer r.deinit(allocator);
        std.debug.print(
            "\nFAIL: vectorf32($bad) with a non-vector string returned {s} instead of erroring\n",
            .{if (r.rows.len == 1 and r.rows[0].len == 1) @tagName(r.rows[0][0]) else "success"},
        );
        return error.ExpectedQueryRejection;
    } else |_| {}
}
