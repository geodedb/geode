// ENG-3912 — "never advertise what isn't dispatched".
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
// CANARY: REQ=REQ-ENG-3912-ADVERTISE-DISPATCH-PARITY; FEATURE="AdvertiseDispatchParity"; ASPECT=FunctionsAndProcedures; STATUS=TESTED; TEST=tests/test_eng3912_advertise_dispatch_parity.zig; OWNER=execution; UPDATED=2026-08-25
// CANARY: REQ=REQ-ENG-3912-SIZE-OF-VECTOR; FEATURE="SizeFunction"; ASPECT=VectorDimension; STATUS=TESTED; TEST=tests/test_eng3912_advertise_dispatch_parity.zig; OWNER=eval; UPDATED=2026-08-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const language_metadata = geode.language_metadata;
const Value = geode.value_types.Value;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
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
                std.debug.print("\n[ENG-3912] {s} returned {s}, expected Int\n", .{ query, @tagName(v) });
                return error.NotAnInt;
            },
        };
    }
};

// ---------------------------------------------------------------------------
// (A) split() — advertised, now dispatched.
// ---------------------------------------------------------------------------

test "ENG-3912: split(str, delim) returns a real LIST of the substrings" {
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

test "ENG-3912: SHOW FUNCTIONS does not advertise reduce (no grammar, no dispatch)" {
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
                "\n[ENG-3912] SHOW FUNCTIONS still advertises 'reduce', which the parser rejects\n",
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

test "ENG-3912: every procedure name and alias in language_metadata CALLs successfully" {
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
            "\n[ENG-3912] {d} advertised algo.* name(s) with no dispatch entry:\n",
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

test "ENG-3912: size()/length() of a VECTOR reports its dimension" {
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
