// FN-DISPATCH-PARITY — "never advertise what isn't dispatched".
//
// Three defects found by the 2026-08 docs audit, all the same shape: a name the
// engine PUBLISHES (SHOW FUNCTIONS / SHOW PROCEDURES / src/gql/language_metadata.zig)
// that the engine does not actually answer to, or answers wrongly.
//
// VERIFIED READ-ONLY AGAINST v0.8.5 / 13836738 BEFORE THE FIX:
//
//   (A) split(str, delim) — advertised by src/gql/language_metadata.zig:681 AND
//       src/execution/statement_handlers.zig:344 ("(string, delimiter) -> LIST"),
//       dispatched nowhere:
//           RETURN split('a,b', ',')            -> error.UnknownFunction
//       reduce(acc, list, expr) — advertised by statement_handlers.zig:355; the
//       higher-order form is not even accepted by the grammar:
//           RETURN reduce(acc = 0, x IN [1,2,3] | acc + x) -> error.UnexpectedToken
//
//   (B) algo.* metadata/dispatch mismatch — language_metadata advertises the
//       `.stream` spelling and a bare alias for every procedure, but
//       src/execution/algo_dispatch.zig registered only `algo.<name>` (no
//       `.stream`) for the graph-statistics family and no bare alias at all for
//       eleven procedures. Every one of these was UnknownProcedure:
//           CALL algo.triangleCounting.stream()   CALL algo.graphDensity.stream()
//           CALL algo.globalClustering.stream()   CALL algo.graphDiameter.stream()
//           CALL algo.localClustering.stream()    CALL algo.meanDistance.stream()
//           CALL triangleCounting()  CALL graphDensity()  CALL katz()
//           CALL hits()  CALL kcore()  CALL kshell()  CALL biconnectedComponents()
//       …while the exact same statements are printed as the `example` string in
//       the metadata row that SHOW PROCEDURES renders.
//
//   (C) size()/length() on a VECTOR returned 0 — src/eval.zig and
//       src/eval/call_handlers.zig both fell through to `else => Int 0` for
//       ExtValue.VectorF32 / VectorI32:
//           RETURN size(vectorf32([1.0,2.0,3.0]))  -> Int 0
//           MATCH (n:V) RETURN size(n.emb)         -> Int 0   (a 5-dim stored vector)
//       "0" is indistinguishable from "empty", so a dimension check written in
//       GQL silently passed on every embedding in the database.
//
// WHAT THESE TESTS PIN (contract, not implementation):
//
//   1. split() returns a real LIST with the right element count AND the right
//      elements, including the leading/trailing/consecutive-separator edge cases
//      where an off-by-one is invisible to a length-only assertion.
//   2. SHOW FUNCTIONS does not advertise `reduce` (removed rather than faked —
//      see the comment at its former site in statement_handlers.zig).
//   3. THE SWEEP: every procedure name AND alias in
//      language_metadata.procedures CALLs successfully. This is the
//      recurrence guard — adding a metadata row without a dispatch entry fails
//      this test, in either direction.
//   4. size()/length() of a vector is its dimension, for a literal and for a
//      vector read back from a stored property (which is the path that also
//      covers graph-storage overflow storage for large vectors).
//
// CANARY: REQ=REQ-FN-DISPATCH-PARITY; FEATURE="AdvertiseDispatchParity"; ASPECT=FunctionsAndProcedures; STATUS=TESTED; TEST=tests/test_fn_dispatch_parity.zig; OWNER=execution; UPDATED=2026-08-25
// CANARY: REQ=REQ-FN-SIZE-OF-VECTOR; FEATURE="SizeFunction"; ASPECT=VectorDimension; STATUS=TESTED; TEST=tests/test_fn_dispatch_parity.zig; OWNER=eval; UPDATED=2026-08-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const language_metadata = geode.language_metadata;
const Value = geode.value_types.Value;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Same shape as tests/test_eng3906_index_with_params.zig — one real catalog +
/// store driven through the real parser and executor. No mocks: every defect
/// here lives in the advertise -> dispatch seam, so both halves must be real.
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
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// First column of the first row, or an error if the statement produced no
    /// rows at all.
    pub fn scalar(self: *Harness, query: []const u8) !Value {
        const res = try self.exec(query);
        if (res.rows.len == 0 or res.rows[0].len == 0) return error.NoRows;
        return res.rows[0][0];
    }

    pub fn scalarInt(self: *Harness, query: []const u8) !i64 {
        const v = try self.scalar(query);
        return switch (v) {
            .Int => |i| i,
            else => {
                std.debug.print("\n[FN-DISPATCH-PARITY] {s} returned {s}, expected Int\n", .{ query, @tagName(v) });
                return error.NotAnInt;
            },
        };
    }

    /// The numeric surface of this engine answers fractional results as a
    /// fixed-point Decimal (see src/eval/call_handlers.zig), so a float
    /// assertion has to go through the same representation the engine uses.
    pub fn scalarF64(self: *Harness, query: []const u8) !f64 {
        const v = try self.scalar(query);
        return switch (v) {
            .Int => |i| @floatFromInt(i),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) /
                std.math.pow(f64, 10.0, @floatFromInt(d.scale)),
            .Double => |f| f,
            .Real => |f| @floatCast(f),
            else => {
                std.debug.print("\n[FN-DISPATCH-PARITY] {s} returned {s}, expected a number\n", .{ query, @tagName(v) });
                return error.NotANumber;
            },
        };
    }

    pub fn scalarBool(self: *Harness, query: []const u8) !bool {
        const v = try self.scalar(query);
        return switch (v) {
            .Bool => |b| b,
            else => {
                std.debug.print("\n[FN-DISPATCH-PARITY] {s} returned {s}, expected Bool\n", .{ query, @tagName(v) });
                return error.NotABool;
            },
        };
    }

    /// Every name SHOW FUNCTIONS advertises, lowercased, caller-owned.
    pub fn showFunctionNames(self: *Harness, gpa: std.mem.Allocator) ![][]const u8 {
        const res = try self.exec("SHOW FUNCTIONS");
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        for (res.rows) |row| {
            if (row.len == 0) continue;
            const name = switch (row[0]) {
                .Str => |s| s,
                else => continue,
            };
            const lowered = try gpa.alloc(u8, name.len);
            for (name, 0..) |c, i| lowered[i] = std.ascii.toLower(c);
            try names.append(gpa, lowered);
        }
        return names.toOwnedSlice(gpa);
    }
};

// ---------------------------------------------------------------------------
// (A) split() — advertised, now dispatched.
// ---------------------------------------------------------------------------

test "FN-DISPATCH-PARITY: split(str, delim) returns a real LIST of the substrings" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3912_split");
    _ = try h.exec("USE GRAPH eng3912_split");

    // KEY ASSERTION (RED before the fix: error.UnknownFunction).
    const two = try h.scalar("RETURN split('a,b', ',')");
    try testing.expect(two == .List);
    try testing.expectEqual(@as(usize, 2), two.List.len);
    try testing.expectEqualStrings("a", two.List[0].Str);
    try testing.expectEqualStrings("b", two.List[1].Str);

    // The documented example from src/gql/language_metadata.zig.
    const three = try h.scalar("RETURN split('a,b,c', ',')");
    try testing.expect(three == .List);
    try testing.expectEqual(@as(usize, 3), three.List.len);
    try testing.expectEqualStrings("a", three.List[0].Str);
    try testing.expectEqualStrings("b", three.List[1].Str);
    try testing.expectEqualStrings("c", three.List[2].Str);

    // Multi-byte delimiter.
    const multi = try h.scalar("RETURN split('a::b::c', '::')");
    try testing.expect(multi == .List);
    try testing.expectEqual(@as(usize, 3), multi.List.len);
    try testing.expectEqualStrings("b", multi.List[1].Str);

    // Edge cases where an off-by-one would be invisible to a length-only check:
    // a leading, a trailing and a doubled separator each yield an EMPTY element
    // rather than being swallowed.
    const lead = try h.scalar("RETURN split(',a', ',')");
    try testing.expectEqual(@as(usize, 2), lead.List.len);
    try testing.expectEqualStrings("", lead.List[0].Str);
    try testing.expectEqualStrings("a", lead.List[1].Str);

    const trail = try h.scalar("RETURN split('a,', ',')");
    try testing.expectEqual(@as(usize, 2), trail.List.len);
    try testing.expectEqualStrings("a", trail.List[0].Str);
    try testing.expectEqualStrings("", trail.List[1].Str);

    const doubled = try h.scalar("RETURN split('a,,b', ',')");
    try testing.expectEqual(@as(usize, 3), doubled.List.len);
    try testing.expectEqualStrings("", doubled.List[1].Str);

    // No separator present -> one element, the whole string.
    const none = try h.scalar("RETURN split('abc', ',')");
    try testing.expectEqual(@as(usize, 1), none.List.len);
    try testing.expectEqualStrings("abc", none.List[0].Str);

    // Empty input -> one empty element (NOT an empty list): 'a,b' has 2 fields,
    // 'a' has 1, so '' must have 1.
    const empty_input = try h.scalar("RETURN split('', ',')");
    try testing.expectEqual(@as(usize, 1), empty_input.List.len);
    try testing.expectEqualStrings("", empty_input.List[0].Str);

    // An empty delimiter has no well-defined split point; the whole string comes
    // back as a single element instead of looping forever or exploding UTF-8.
    const empty_delim = try h.scalar("RETURN split('abc', '')");
    try testing.expectEqual(@as(usize, 1), empty_delim.List.len);
    try testing.expectEqualStrings("abc", empty_delim.List[0].Str);

    // The result is a first-class LIST: the collection functions accept it.
    try testing.expectEqual(@as(i64, 3), try h.scalarInt("RETURN size(split('a,b,c', ','))"));

    // Case-insensitive per ISO/IEC 39075:2024 RQ-0022.
    const upper = try h.scalar("RETURN SPLIT('a,b', ',')");
    try testing.expectEqual(@as(usize, 2), upper.List.len);
}

// ---------------------------------------------------------------------------
// (A) reduce() — advertised, NOT implemented, therefore no longer advertised.
// ---------------------------------------------------------------------------

test "FN-DISPATCH-PARITY: SHOW FUNCTIONS does not advertise reduce (no grammar, no dispatch)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3912_show");
    _ = try h.exec("USE GRAPH eng3912_show");

    // The construct genuinely does not exist: it is not even parseable. If this
    // ever starts succeeding, `reduce` should go BACK into SHOW FUNCTIONS in the
    // same commit, and this assertion should be replaced by a behavioural one.
    try testing.expectError(
        error.UnexpectedToken,
        h.exec("RETURN reduce(acc = 0, x IN [1,2,3] | acc + x)"),
    );

    const res = try h.exec("SHOW FUNCTIONS");
    try testing.expect(res.rows.len > 0);
    for (res.rows) |row| {
        if (row.len == 0) continue;
        const name = switch (row[0]) {
            .Str => |s| s,
            else => continue,
        };
        if (std.ascii.eqlIgnoreCase(name, "reduce")) {
            std.debug.print(
                "\n[FN-DISPATCH-PARITY] SHOW FUNCTIONS still advertises 'reduce', which the parser rejects\n",
                .{},
            );
            return error.UnimplementedFunctionAdvertised;
        }
    }

    // Guard against "fix it by emptying the table": the functions that DO
    // dispatch must still be advertised.
    var saw_split = false;
    var saw_count = false;
    for (res.rows) |row| {
        if (row.len == 0) continue;
        const name = switch (row[0]) {
            .Str => |s| s,
            else => continue,
        };
        if (std.ascii.eqlIgnoreCase(name, "split")) saw_split = true;
        if (std.ascii.eqlIgnoreCase(name, "count")) saw_count = true;
    }
    try testing.expect(saw_split);
    try testing.expect(saw_count);
}

// ---------------------------------------------------------------------------
// (B) THE SWEEP: every advertised algo.* procedure must dispatch.
// ---------------------------------------------------------------------------

test "FN-DISPATCH-PARITY: every procedure name and alias in language_metadata CALLs successfully" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    _ = try h.exec("CREATE GRAPH eng3912_procs");
    _ = try h.exec("USE GRAPH eng3912_procs");

    // A triangle plus a pendant: small, but non-degenerate for every family in
    // the table (clustering wants a closed triangle, diameter/mean-distance want
    // a path longer than one hop, k-core wants unequal degrees).
    _ = try h.exec("CREATE (a:PSweep {n: 'a'})-[:LINK]->(b:PSweep {n: 'b'})");
    _ = try h.exec("MATCH (b:PSweep {n: 'b'}), (a:PSweep {n: 'a'}) CREATE (b)-[:LINK]->(c:PSweep {n: 'c'})");
    _ = try h.exec("MATCH (c:PSweep {n: 'c'}), (a:PSweep {n: 'a'}) CREATE (c)-[:LINK]->(a)");
    _ = try h.exec("MATCH (c:PSweep {n: 'c'}) CREATE (c)-[:LINK]->(d:PSweep {n: 'd'})");

    // Accumulate every failure so one RED run enumerates the whole mismatch
    // instead of stopping at the first missing name.
    var failures: std.ArrayListUnmanaged([]const u8) = .empty;

    for (language_metadata.procedures) |proc| {
        // Every procedure in the table today is parameterless; a future entry
        // that needs arguments must extend this sweep rather than be skipped.
        const by_name = try std.fmt.allocPrint(gpa, "CALL {s}()", .{proc.name});
        if (h.exec(by_name)) |_| {} else |err| {
            try failures.append(gpa, try std.fmt.allocPrint(
                gpa,
                "advertised procedure name does not dispatch: {s} -> {s}",
                .{ by_name, @errorName(err) },
            ));
        }

        if (proc.alias) |alias| {
            const by_alias = try std.fmt.allocPrint(gpa, "CALL {s}()", .{alias});
            if (h.exec(by_alias)) |_| {} else |err| {
                try failures.append(gpa, try std.fmt.allocPrint(
                    gpa,
                    "advertised procedure alias does not dispatch: {s} (alias of {s}) -> {s}",
                    .{ by_alias, proc.name, @errorName(err) },
                ));
            }
        }
    }

    if (failures.items.len != 0) {
        std.debug.print(
            "\n[FN-DISPATCH-PARITY] {d} advertised algo.* name(s) with no dispatch entry:\n",
            .{failures.items.len},
        );
        for (failures.items) |f| std.debug.print("  - {s}\n", .{f});
        return error.AdvertisedProcedureNotDispatched;
    }

    // Guard against a vacuous pass if the metadata table is ever emptied.
    try testing.expect(language_metadata.procedures.len >= 20);
}

// ---------------------------------------------------------------------------
// (C) size()/length() of a VECTOR is its dimension, not 0.
// ---------------------------------------------------------------------------

test "FN-DISPATCH-PARITY: size()/length() of a VECTOR reports its dimension" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3912_vec");
    _ = try h.exec("USE GRAPH eng3912_vec");

    // KEY ASSERTIONS (RED before the fix: every one of these was Int 0).
    try testing.expectEqual(@as(i64, 3), try h.scalarInt("RETURN size(vectorf32([1.0,2.0,3.0]))"));
    try testing.expectEqual(@as(i64, 3), try h.scalarInt("RETURN length(vectorf32([1.0,2.0,3.0]))"));
    try testing.expectEqual(@as(i64, 4), try h.scalarInt("RETURN size(vectori32([1,2,3,4]))"));

    // Read back from a STORED property — the path a real query takes, and the
    // one that also exercises graph-storage overflow storage for a vector too
    // large to live inline.
    _ = try h.exec("CREATE (:VSmall {emb: vectorf32([1.0,2.0,3.0,4.0,5.0])})");
    try testing.expectEqual(@as(i64, 5), try h.scalarInt("MATCH (n:VSmall) RETURN size(n.emb)"));

    // A large vector: 2560 dims is past the inline-property threshold, so this
    // covers the overflow read path as well. Built as a literal so the test
    // stays independent of any loader.
    {
        var q: std.ArrayListUnmanaged(u8) = .empty;
        defer q.deinit(testing.allocator);
        try q.appendSlice(testing.allocator, "CREATE (:VBig {emb: vectorf32([");
        var i: usize = 0;
        while (i < 2560) : (i += 1) {
            if (i != 0) try q.appendSlice(testing.allocator, ",");
            var num_buf: [32]u8 = undefined;
            const num = try std.fmt.bufPrint(&num_buf, "{d}.0", .{i % 7});
            try q.appendSlice(testing.allocator, num);
        }
        try q.appendSlice(testing.allocator, "])})");
        _ = try h.exec(q.items);
    }
    try testing.expectEqual(@as(i64, 2560), try h.scalarInt("MATCH (n:VBig) RETURN size(n.emb)"));

    // Guard against "fix it by returning something non-zero for everything":
    // the pre-existing List / Str / Map answers must be untouched.
    try testing.expectEqual(@as(i64, 3), try h.scalarInt("RETURN size([1,2,3])"));
    try testing.expectEqual(@as(i64, 5), try h.scalarInt("RETURN size('hello')"));
    try testing.expectEqual(@as(i64, 1), try h.scalarInt("RETURN size({a: 1})"));
}

// ---------------------------------------------------------------------------
// (D) THE FUNCTION SWEEP — the loophole the (B) sweep left open.
//
// The (B) sweep above walks `language_metadata.procedures` and CALLs every one.
// There was NO equivalent walk for FUNCTIONS, so the whole advertise -> dispatch
// seam on the function side was unguarded and twelve advertised names rotted in
// place. VERIFIED READ-ONLY AGAINST 1459b456 BEFORE THE FIX:
//
//   RETURN rand()                       -> error.UnknownFunction
//   RETURN pi()                         -> error.UnknownFunction
//   RETURN e()                          -> error.UnknownFunction
//   RETURN startsWith('abc','a')        -> error.UnknownFunction
//   RETURN endsWith('abc','c')          -> error.UnknownFunction
//   RETURN contains('abc','b')          -> error.UnknownFunction
//   RETURN nullIf(1, 1)                 -> error.UnknownFunction
//   RETURN localtime()                  -> error.UnknownFunction
//   MATCH (n:P) RETURN elementId(n)     -> error.UnknownFunction
//   RETURN point({x: 1.0, y: 2.0})      -> error.UnknownFunction
//   RETURN none(x IN [1,2] WHERE x > 5) -> error.UnexpectedToken   (no grammar)
//   RETURN single(x IN [1,2] WHERE x>1) -> error.UnexpectedToken   (no grammar)
//
// The sweep is a PROBE TABLE rather than a generated call because the advertised
// functions do not share one call shape (quantifiers take `x IN list WHERE …`,
// path functions need a bound path, degree functions need a bound node). The
// table is kept honest by the completeness half of the test: EVERY name in
// `SHOW FUNCTIONS` and EVERY name in `language_metadata.functions` must have a
// probe, so adding a metadata row without a dispatch entry fails here — in
// either direction, exactly like the procedure sweep.
// ---------------------------------------------------------------------------

const FunctionProbe = struct {
    /// Advertised name, lowercased.
    name: []const u8,
    /// A statement that reaches the function's dispatch entry. It must not be
    /// a parse error and must not raise UnknownFunction; the per-function
    /// behavioural assertions live in the dedicated tests below.
    query: []const u8,
};

const function_probes = [_]FunctionProbe{
    // Aggregates
    .{ .name = "count", .query = "RETURN count(1)" },
    .{ .name = "sum", .query = "RETURN sum(1)" },
    .{ .name = "avg", .query = "RETURN avg(1)" },
    .{ .name = "min", .query = "RETURN min(1)" },
    .{ .name = "max", .query = "RETURN max(1)" },
    .{ .name = "collect", .query = "RETURN collect(1)" },
    // Numeric
    .{ .name = "abs", .query = "RETURN abs(-1)" },
    .{ .name = "ceil", .query = "RETURN ceil(1.2)" },
    .{ .name = "floor", .query = "RETURN floor(1.2)" },
    .{ .name = "round", .query = "RETURN round(1.2)" },
    .{ .name = "sqrt", .query = "RETURN sqrt(4.0)" },
    .{ .name = "rand", .query = "RETURN rand()" },
    .{ .name = "sign", .query = "RETURN sign(-3)" },
    .{ .name = "exp", .query = "RETURN exp(1.0)" },
    .{ .name = "log", .query = "RETURN log(1.0)" },
    .{ .name = "log10", .query = "RETURN log10(10.0)" },
    .{ .name = "sin", .query = "RETURN sin(0.0)" },
    .{ .name = "cos", .query = "RETURN cos(0.0)" },
    .{ .name = "tan", .query = "RETURN tan(0.0)" },
    .{ .name = "asin", .query = "RETURN asin(0.0)" },
    .{ .name = "acos", .query = "RETURN acos(1.0)" },
    .{ .name = "atan", .query = "RETURN atan(0.0)" },
    .{ .name = "atan2", .query = "RETURN atan2(1.0, 1.0)" },
    .{ .name = "pi", .query = "RETURN pi()" },
    .{ .name = "e", .query = "RETURN e()" },
    .{ .name = "degrees", .query = "RETURN degrees(1.0)" },
    .{ .name = "radians", .query = "RETURN radians(90.0)" },
    // Collections / strings
    .{ .name = "size", .query = "RETURN size([1,2])" },
    .{ .name = "length", .query = "RETURN length([1,2])" },
    .{ .name = "substring", .query = "RETURN substring('abcd', 1, 2)" },
    .{ .name = "replace", .query = "RETURN replace('abc','b','x')" },
    .{ .name = "tolower", .query = "RETURN toLower('AB')" },
    .{ .name = "toupper", .query = "RETURN toUpper('ab')" },
    .{ .name = "lower", .query = "RETURN lower('AB')" },
    .{ .name = "upper", .query = "RETURN upper('ab')" },
    .{ .name = "trim", .query = "RETURN trim('  a  ')" },
    .{ .name = "ltrim", .query = "RETURN lTrim('  a')" },
    .{ .name = "rtrim", .query = "RETURN rTrim('a  ')" },
    .{ .name = "left", .query = "RETURN left('abc', 2)" },
    .{ .name = "right", .query = "RETURN right('abc', 2)" },
    .{ .name = "split", .query = "RETURN split('a,b', ',')" },
    .{ .name = "startswith", .query = "RETURN startsWith('abc','a')" },
    .{ .name = "endswith", .query = "RETURN endsWith('abc','c')" },
    .{ .name = "contains", .query = "RETURN contains('abc','b')" },
    .{ .name = "icontains", .query = "RETURN icontains('AbC','b')" },
    .{ .name = "reverse", .query = "RETURN reverse('abc')" },
    .{ .name = "head", .query = "RETURN head([1,2])" },
    .{ .name = "last", .query = "RETURN last([1,2])" },
    .{ .name = "tail", .query = "RETURN tail([1,2])" },
    .{ .name = "range", .query = "RETURN range(1, 3)" },
    .{ .name = "keys", .query = "RETURN keys({a: 1})" },
    .{ .name = "values", .query = "RETURN values({a: 1})" },
    // Conversions
    .{ .name = "tointeger", .query = "RETURN toInteger('1')" },
    .{ .name = "tofloat", .query = "RETURN toFloat('1.5')" },
    .{ .name = "tostring", .query = "RETURN toString(1)" },
    .{ .name = "toboolean", .query = "RETURN toBoolean('true')" },
    // Temporal
    .{ .name = "timestamp", .query = "RETURN timestamp()" },
    .{ .name = "date", .query = "RETURN date('2024-01-01')" },
    .{ .name = "time", .query = "RETURN time('10:11:12')" },
    .{ .name = "datetime", .query = "RETURN datetime('2024-01-01T00:00:00Z')" },
    .{ .name = "valuetype", .query = "RETURN valueType(123)" },
    .{ .name = "localtime", .query = "RETURN localtime()" },
    .{ .name = "localdatetime", .query = "RETURN localdatetime()" },
    .{ .name = "duration", .query = "RETURN duration('PT1H')" },
    // Graph / path
    .{ .name = "id", .query = "MATCH (n:PSweepFn) RETURN id(n)" },
    .{ .name = "type", .query = "MATCH ()-[r:LINKFN]->() RETURN type(r)" },
    .{ .name = "labels", .query = "MATCH (n:PSweepFn) RETURN labels(n)" },
    .{ .name = "properties", .query = "MATCH (n:PSweepFn) RETURN properties(n)" },
    .{ .name = "exists", .query = "MATCH (n:PSweepFn) RETURN exists(n.n)" },
    .{ .name = "indegree", .query = "MATCH (n:PSweepFn) RETURN indegree(n)" },
    .{ .name = "outdegree", .query = "MATCH (n:PSweepFn) RETURN outdegree(n)" },
    .{ .name = "nodes", .query = "MATCH p = (a:PSweepFn)-[:LINKFN]->(b:PSweepFn) RETURN nodes(p)" },
    .{ .name = "relationships", .query = "MATCH p = (a:PSweepFn)-[:LINKFN]->(b:PSweepFn) RETURN relationships(p)" },
    .{ .name = "shortestpath", .query = "MATCH p = shortestPath((a:PSweepFn)-[:LINKFN*]->(b:PSweepFn)) RETURN p" },
    .{ .name = "allshortestpaths", .query = "MATCH p = allShortestPaths((a:PSweepFn)-[:LINKFN*]->(b:PSweepFn)) RETURN p" },
    // Vectors
    .{ .name = "vectorf32", .query = "RETURN vectorf32([1.0,2.0])" },
    .{ .name = "vectori32", .query = "RETURN vectori32([1,2])" },
    .{ .name = "vector_l2", .query = "RETURN vector_l2(vectorf32([1.0]), vectorf32([2.0]))" },
    .{ .name = "vector_cosine", .query = "RETURN vector_cosine(vectorf32([1.0]), vectorf32([2.0]))" },
    .{ .name = "vector_dot", .query = "RETURN vector_dot(vectorf32([1.0]), vectorf32([2.0]))" },
    .{ .name = "distance", .query = "RETURN distance(vectorf32([1.0]), vectorf32([2.0]))" },
    .{ .name = "similarity", .query = "RETURN similarity(vectorf32([1.0]), vectorf32([2.0]))" },
    .{ .name = "cosine", .query = "RETURN cosine(vectorf32([1.0]), vectorf32([2.0]))" },
    .{ .name = "euclidean", .query = "RETURN euclidean(vectorf32([1.0]), vectorf32([2.0]))" },
    .{ .name = "manhattan", .query = "RETURN manhattan(vectorf32([1.0]), vectorf32([2.0]))" },
    .{ .name = "vector_knn", .query = "RETURN vector_knn('emb', vectorf32([1.0]), 1, 'l2')" },
    .{ .name = "knn", .query = "RETURN knn('emb', vectorf32([1.0]), 1, 'l2')" },
    // Predicates
    .{ .name = "all", .query = "RETURN all(x IN [1,2] WHERE x > 0)" },
    .{ .name = "any", .query = "RETURN any(x IN [1,2] WHERE x > 1)" },
    .{ .name = "none", .query = "RETURN none(x IN [1,2] WHERE x > 5)" },
    .{ .name = "single", .query = "RETURN single(x IN [1,2] WHERE x > 1)" },
    // Null handling
    .{ .name = "coalesce", .query = "RETURN coalesce(NULL, 1)" },
    .{ .name = "nullif", .query = "RETURN nullIf(1, 1)" },
};

fn probeFor(name: []const u8) ?FunctionProbe {
    for (function_probes) |p| {
        if (std.ascii.eqlIgnoreCase(p.name, name)) return p;
    }
    return null;
}

fn sweepGraph(h: *Harness, name: []const u8) !void {
    var buf: [128]u8 = undefined;
    _ = try h.exec(try std.fmt.bufPrint(&buf, "CREATE GRAPH {s}", .{name}));
    _ = try h.exec(try std.fmt.bufPrint(&buf, "USE GRAPH {s}", .{name}));
    _ = try h.exec("CREATE (a:PSweepFn {n: 'a'})-[:LINKFN]->(b:PSweepFn {n: 'b'})");
    // geode#877 (c): the `vector_knn` / `knn` dispatch probes below name the
    // property 'emb'. Under the new contract a knn() over a property NO row
    // supplies is a diagnostic (error.UnknownProperty) rather than a silent
    // empty list — see tests/test_vector_knn_silent_failures.zig. This seeds a
    // row that actually carries 'emb', so those two probes keep testing what
    // this sweep is for (advertise -> DISPATCH parity) instead of accidentally
    // asserting the old silent-empty behaviour. Distinct label so the
    // labels()/properties()/id() probes above are unaffected.
    _ = try h.exec("CREATE (:PSweepVec {emb: vectorf32([1.0])})");
}

test "FN-DISPATCH-PARITY: every function name advertised by SHOW FUNCTIONS and language_metadata dispatches" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try sweepGraph(&h, "fnsweep_dispatch");

    var advertised: std.ArrayListUnmanaged([]const u8) = .empty;
    for (try h.showFunctionNames(gpa)) |n| try advertised.append(gpa, n);
    for (language_metadata.functions) |f| {
        const lowered = try gpa.alloc(u8, f.name.len);
        for (f.name, 0..) |c, i| lowered[i] = std.ascii.toLower(c);
        try advertised.append(gpa, lowered);
    }

    var failures: std.ArrayListUnmanaged([]const u8) = .empty;
    var probed: std.ArrayListUnmanaged([]const u8) = .empty;

    for (advertised.items) |name| {
        var already = false;
        for (probed.items) |seen| {
            if (std.mem.eql(u8, seen, name)) already = true;
        }
        if (already) continue;
        try probed.append(gpa, name);

        // COMPLETENESS HALF: an advertised name with no probe is the exact hole
        // that let rand/pi/e/nullIf/localtime/point/elementId rot.
        const probe = probeFor(name) orelse {
            try failures.append(gpa, try std.fmt.allocPrint(
                gpa,
                "advertised function has no dispatch probe in this sweep: {s}",
                .{name},
            ));
            continue;
        };

        // DISPATCH HALF.
        if (h.exec(probe.query)) |_| {} else |err| {
            try failures.append(gpa, try std.fmt.allocPrint(
                gpa,
                "advertised function does not dispatch: {s} ({s}) -> {s}",
                .{ probe.query, name, @errorName(err) },
            ));
        }
    }

    if (failures.items.len != 0) {
        std.debug.print(
            "\n[FN-DISPATCH-PARITY] {d} advertised function name(s) with no dispatch:\n",
            .{failures.items.len},
        );
        for (failures.items) |f| std.debug.print("  - {s}\n", .{f});
        return error.AdvertisedFunctionNotDispatched;
    }

    // Guard against a vacuous pass if either advertised table is emptied.
    try testing.expect(probed.items.len >= 85);
    try testing.expect(language_metadata.functions.len >= 80);
}

// ---------------------------------------------------------------------------
// (E) The names that were implemented rather than un-advertised.
// ---------------------------------------------------------------------------

test "FN-DISPATCH-PARITY: rand() is a float in [0,1)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try sweepGraph(&h, "fnsweep_rand");

    // KEY ASSERTION (RED before the fix: error.UnknownFunction).
    var i: usize = 0;
    var saw_distinct = false;
    var first: f64 = -1;
    while (i < 16) : (i += 1) {
        const v = try h.scalarF64("RETURN rand()");
        try testing.expect(v >= 0.0);
        try testing.expect(v < 1.0);
        if (first < 0) first = v else if (v != first) saw_distinct = true;
    }
    // Not a constant dressed up as a PRNG.
    try testing.expect(saw_distinct);
}

test "FN-DISPATCH-PARITY: pi() and e() are the mathematical constants" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try sweepGraph(&h, "fnsweep_consts");

    // KEY ASSERTIONS (RED before the fix: error.UnknownFunction for both).
    try testing.expectApproxEqAbs(
        @as(f64, std.math.pi),
        try h.scalarF64("RETURN pi()"),
        1e-6,
    );
    try testing.expectApproxEqAbs(
        @as(f64, std.math.e),
        try h.scalarF64("RETURN e()"),
        1e-6,
    );
    // The documented example in src/gql/language_metadata.zig composes the two
    // math surfaces; it must produce a straight 180 degrees.
    try testing.expectApproxEqAbs(
        @as(f64, 180.0),
        try h.scalarF64("RETURN degrees(pi())"),
        1e-4,
    );
}

test "FN-DISPATCH-PARITY: startsWith / endsWith / contains dispatch like their icontains sibling" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try sweepGraph(&h, "fnsweep_strpred");

    // KEY ASSERTIONS (RED before the fix: error.UnknownFunction for all three,
    // while the case-insensitive icontains() next to them dispatched fine).
    try testing.expect(try h.scalarBool("RETURN startsWith('hello', 'he')"));
    try testing.expect(!(try h.scalarBool("RETURN startsWith('hello', 'lo')")));
    try testing.expect(try h.scalarBool("RETURN endsWith('hello', 'lo')"));
    try testing.expect(!(try h.scalarBool("RETURN endsWith('hello', 'he')")));
    try testing.expect(try h.scalarBool("RETURN contains('hello', 'ell')"));
    try testing.expect(!(try h.scalarBool("RETURN contains('hello', 'xyz')")));

    // Case SENSITIVITY is the whole difference from icontains: keep them apart.
    try testing.expect(!(try h.scalarBool("RETURN contains('Hello', 'hello')")));
    try testing.expect(try h.scalarBool("RETURN icontains('Hello', 'hello')"));

    // Empty needle is a prefix/suffix/substring of everything.
    try testing.expect(try h.scalarBool("RETURN startsWith('hello', '')"));
    try testing.expect(try h.scalarBool("RETURN endsWith('hello', '')"));
    try testing.expect(try h.scalarBool("RETURN contains('hello', '')"));

    // A needle longer than the haystack is not a match (an unguarded slice
    // would panic here rather than answer false).
    try testing.expect(!(try h.scalarBool("RETURN startsWith('ab', 'abc')")));
    try testing.expect(!(try h.scalarBool("RETURN endsWith('ab', 'abc')")));

    // The operator spellings keep their existing meaning.
    try testing.expect(try h.scalarBool("RETURN 'hello' STARTS WITH 'he'"));
    try testing.expect(try h.scalarBool("RETURN 'hello' CONTAINS 'ell'"));
}

test "FN-DISPATCH-PARITY: nullIf(a, b) is NULL when equal and a otherwise" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try sweepGraph(&h, "fnsweep_nullif");

    // KEY ASSERTIONS (RED before the fix: error.UnknownFunction).
    try testing.expect((try h.scalar("RETURN nullIf(1, 1)")) == .Null);
    try testing.expectEqual(@as(i64, 1), try h.scalarInt("RETURN nullIf(1, 2)"));

    try testing.expect((try h.scalar("RETURN nullIf('a', 'a')")) == .Null);
    const str_val = try h.scalar("RETURN nullIf('a', 'b')");
    try testing.expect(str_val == .Str);
    try testing.expectEqualStrings("a", str_val.Str);

    // The documented example shape: a property that does NOT equal the sentinel
    // comes back unchanged, one that does collapses to NULL.
    _ = try h.exec("CREATE (:NIf {status: 'active'}), (:NIf {status: 'inactive'})");
    const res = try h.exec("MATCH (n:NIf) RETURN nullIf(n.status, 'inactive')");
    try testing.expectEqual(@as(usize, 2), res.rows.len);
    var nulls: usize = 0;
    var actives: usize = 0;
    for (res.rows) |row| {
        switch (row[0]) {
            .Null => nulls += 1,
            .Str => |s| if (std.mem.eql(u8, s, "active")) {
                actives += 1;
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), nulls);
    try testing.expectEqual(@as(usize, 1), actives);

    // NULL never "equals" anything, so nullIf(NULL, x) is NULL by way of the
    // first argument, not by way of the equality.
    try testing.expect((try h.scalar("RETURN nullIf(NULL, 1)")) == .Null);
    // A non-equal, non-comparable pair returns the first argument.
    try testing.expectEqual(@as(i64, 1), try h.scalarInt("RETURN nullIf(1, 'a')"));
}

test "FN-DISPATCH-PARITY: localtime() mirrors the time()/localdatetime() family" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try sweepGraph(&h, "fnsweep_localtime");

    // KEY ASSERTIONS (RED before the fix: error.UnknownFunction for both arities).
    const now = try h.scalar("RETURN localtime()");
    try testing.expect(now == .ExtValue or now == .Time);

    // localtime(string) parses the same ISO time literal time(string) does, and
    // must agree with it to the microsecond — they are the same clock reading.
    const parsed = try h.scalar("RETURN localtime('10:11:12')");
    const via_time = try h.scalar("RETURN time('10:11:12')");
    const micros_of = struct {
        fn get(v: Value) !i64 {
            return switch (v) {
                .Time => |t| t.micros_since_midnight,
                .ExtValue => |ext| switch (ext) {
                    .Time => |t| t.micros_since_midnight,
                    else => error.NotATime,
                },
                else => error.NotATime,
            };
        }
    }.get;
    try testing.expectEqual(try micros_of(via_time), try micros_of(parsed));
    // 10:11:12 is 36672 seconds past midnight — pin the value, not just equality
    // with a sibling that could be wrong in the same way.
    try testing.expectEqual(@as(i64, 36672) * 1_000_000, try micros_of(parsed));
}

test "FN-DISPATCH-PARITY: datetime accepts a date-only literal and reports parse failures as data exceptions" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try sweepGraph(&h, "fnsweep_dtonly");

    // KEY ASSERTIONS (RED before the fix): Timestamp.fromStr requires a time
    // part and the caller swallowed the parse failure with `catch return null`,
    // which fell through to error.UnknownFunction (42883) — a data exception
    // misreported as "no such function".
    try testing.expectEqual(@as(i64, 2024), try h.scalarInt("RETURN datetime('2024-06-15').year AS year"));

    // A malformed literal on a RESOLVED function is TimeParse, never 42883.
    try testing.expectError(error.TimeParse, h.exec("RETURN datetime('garbage') AS x"));
    try testing.expectError(error.TimeParse, h.exec("RETURN duration('garbage') AS x"));
    // Non-string / wrong-arity are data exceptions on the resolved name too.
    try testing.expectError(error.TypeMismatch, h.exec("RETURN datetime(123) AS x"));
    try testing.expectError(error.InvalidArgs, h.exec("RETURN datetime('a', 'b') AS x"));
}

test "FN-DISPATCH-PARITY: valueType() names the value's type without type()'s edge special-case" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try sweepGraph(&h, "fnsweep_valuetype");

    const int_t = try h.scalar("RETURN valueType(123) AS t");
    try testing.expectEqualStrings("INTEGER", int_t.Str);
    const str_t = try h.scalar("RETURN valueType('hello') AS t");
    try testing.expectEqualStrings("STRING", str_t.Str);
}

test "FN-DISPATCH-PARITY: none() and single() are parseable and correct quantifiers" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try sweepGraph(&h, "fnsweep_quant");

    // KEY ASSERTIONS (RED before the fix: error.UnexpectedToken — the grammar
    // special-cased only all()/any(), so these two advertised predicates could
    // not even be written).
    try testing.expect(try h.scalarBool("RETURN none(x IN [1,2,3] WHERE x > 5)"));
    try testing.expect(!(try h.scalarBool("RETURN none(x IN [1,2,3] WHERE x > 2)")));
    try testing.expect(try h.scalarBool("RETURN single(x IN [1,2,3] WHERE x > 2)"));
    try testing.expect(!(try h.scalarBool("RETURN single(x IN [1,2,3] WHERE x > 1)")));
    try testing.expect(!(try h.scalarBool("RETURN single(x IN [1,2,3] WHERE x > 5)")));

    // Vacuous cases: nothing fails a none() over an empty list; single() needs
    // exactly one and so is false on an empty list.
    try testing.expect(try h.scalarBool("RETURN none(x IN [] WHERE x > 0)"));
    try testing.expect(!(try h.scalarBool("RETURN single(x IN [] WHERE x > 0)")));

    // The pre-existing siblings must be untouched by the shared implementation.
    try testing.expect(try h.scalarBool("RETURN all(x IN [1,2,3] WHERE x > 0)"));
    try testing.expect(!(try h.scalarBool("RETURN all(x IN [1,2,3] WHERE x > 2)")));
    try testing.expect(try h.scalarBool("RETURN any(x IN [1,2,3] WHERE x > 2)"));
    try testing.expect(!(try h.scalarBool("RETURN any(x IN [1,2,3] WHERE x > 5)")));

    // Case-insensitive, like every other function name.
    try testing.expect(try h.scalarBool("RETURN NONE(x IN [1,2,3] WHERE x > 5)"));
    try testing.expect(try h.scalarBool("RETURN SINGLE(x IN [1,2,3] WHERE x > 2)"));
}

test "FN-DISPATCH-PARITY: cosine() answers for VECTOR arguments, not just LIST" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try sweepGraph(&h, "fnsweep_cosine");

    // KEY ASSERTION (RED before the fix: Value.Null — cosine() worked for a
    // LIST literal and silently answered NULL for the VECTORF32/VECTORI32
    // values its own metadata says it takes).
    const identical = try h.scalarF64("RETURN cosine(vectorf32([1.0,2.0,3.0]), vectorf32([1.0,2.0,3.0]))");
    try testing.expectApproxEqAbs(@as(f64, 1.0), identical, 1e-5);

    // It must agree with vector_cosine, which is the same similarity.
    const via_alias = try h.scalarF64("RETURN cosine(vectorf32([1.0,2.0]), vectorf32([3.0,4.0]))");
    const via_vector = try h.scalarF64("RETURN vector_cosine(vectorf32([1.0,2.0]), vectorf32([3.0,4.0]))");
    try testing.expectApproxEqAbs(via_vector, via_alias, 1e-5);

    // Orthogonal vectors -> 0, opposite vectors -> -1.
    try testing.expectApproxEqAbs(
        @as(f64, 0.0),
        try h.scalarF64("RETURN cosine(vectorf32([1.0,0.0]), vectorf32([0.0,1.0]))"),
        1e-5,
    );
    try testing.expectApproxEqAbs(
        @as(f64, -1.0),
        try h.scalarF64("RETURN cosine(vectorf32([1.0,0.0]), vectorf32([-1.0,0.0]))"),
        1e-5,
    );

    // Integer vectors cross the same path.
    try testing.expectApproxEqAbs(
        @as(f64, 1.0),
        try h.scalarF64("RETURN cosine(vectori32([1,2,3]), vectori32([2,4,6]))"),
        1e-5,
    );

    // A vector read back from a stored property (the real query shape).
    _ = try h.exec("CREATE (:CosV {emb: vectorf32([1.0,2.0,3.0])})");
    try testing.expectApproxEqAbs(
        @as(f64, 1.0),
        try h.scalarF64("MATCH (n:CosV) RETURN cosine(n.emb, vectorf32([1.0,2.0,3.0]))"),
        1e-5,
    );

    // Guard against "fix it by rerouting everything": the LIST form keeps its
    // pre-existing answer.
    try testing.expectApproxEqAbs(
        @as(f64, 1.0),
        try h.scalarF64("RETURN cosine([1.0,2.0], [1.0,2.0])"),
        1e-5,
    );
}

// ---------------------------------------------------------------------------
// (F) The names that were un-advertised rather than implemented.
// ---------------------------------------------------------------------------

test "FN-DISPATCH-PARITY: SHOW FUNCTIONS does not advertise elementId or point" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try sweepGraph(&h, "fnsweep_removed");

    // Both were listed by SHOW FUNCTIONS and dispatched nowhere. `elementId` is
    // an ISO/Neo4j element-id scheme this engine has not decided on (`id()` is
    // the implemented identity), and `point(map)` is a fourth, incompatible
    // spelling of a geometry constructor next to the implemented `st_point`
    // family. Both are removed rather than faked.
    try testing.expectError(error.UnknownFunction, h.exec("MATCH (n:PSweepFn) RETURN elementId(n)"));
    try testing.expectError(error.UnknownFunction, h.exec("RETURN point({x: 1.0, y: 2.0})"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (try h.showFunctionNames(arena.allocator())) |name| {
        if (std.mem.eql(u8, name, "elementid") or std.mem.eql(u8, name, "point")) {
            std.debug.print(
                "\n[FN-DISPATCH-PARITY] SHOW FUNCTIONS still advertises '{s}', which does not dispatch\n",
                .{name},
            );
            return error.UnimplementedFunctionAdvertised;
        }
    }

    // The real constructors this engine DOES implement stay reachable, so the
    // removal is not a capability loss.
    const pt = try h.scalar("RETURN st_point(1.0, 2.0)");
    try testing.expect(pt != .Null);
    // id() is the implemented identity surface elementId() was shadowing.
    _ = try h.scalarInt("MATCH (n:PSweepFn) RETURN id(n)");
}
