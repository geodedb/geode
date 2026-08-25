// UNSUPPORTED-AGGREGATES — parse-only aggregate traps: a statistic that silently evaluates to
// NULL instead of not existing.
//
// VERIFIED READ-ONLY AGAINST v0.8.5 / 13836738 BEFORE THE FIX:
//
//   src/gql/parser.zig:4199's <set quantifier> allow-list admitted
//   collect_list / stddev_samp / stddev_pop / percentile_cont / percentile_disc,
//   and SHOW FUNCTIONS additionally advertised stdev / percentileCont /
//   percentileDisc — while src/execution/aggregation_evaluation.zig implements
//   exactly count / countDistinct / sum / avg / min / max / collect.
//
//   The dangerous half is the GROUPED path. `evaluateGroupAggregation` answers
//   NULL for any Call it does not recognise, so:
//
//     MATCH (n:G) RETURN n.k, percentile_cont(n.v, 0.5) GROUP BY n.k
//        -> [ Str('a') NULL ]
//           [ Str('b') NULL ]
//
//   A full, successful result set with a NULL statistic in it — indistinguishable
//   from "the median of this group really is null". Same for percentile_disc,
//   stddev_samp, stddev_pop, collect_list, stdev. (Outside GROUP BY the same
//   calls raised error.UnknownFunction, so the failure was loud in one shape and
//   silent in the other — which is worse than uniformly loud.)
//
// WHAT THESE TESTS PIN (contract, not implementation):
//
//   1. Every trap name is REFUSED, with an error distinct from a bare syntax
//      error, in BOTH the grouped and the ungrouped shape, and with or without a
//      <set quantifier>. The SQLSTATE (42000) is pinned in
//      src/server/proto_util.zig; these tests pin THAT it is refused.
//   2. The six implemented aggregates keep working, including the DISTINCT/ALL
//      <set quantifier> forms that ISO/IEC 39075:2024 allows on every aggregate
//      (the guard against "fix it by rejecting everything").
//   3. SHOW FUNCTIONS no longer advertises the unimplemented spellings.
//
// SCOPE / HONEST RESIDUAL: this fix refuses the aggregate names the engine
// RECOGNISES but does not implement. A completely unknown function inside
// GROUP BY (`RETURN n.k, banana(n.v) GROUP BY n.k`) still evaluates to NULL,
// because `evaluateGroupAggregation` returns NULL for every unrecognised Call.
// That is a separate, wider defect in the grouped-evaluation path and is
// deliberately NOT asserted here so this file stays inside the UNSUPPORTED-AGGREGATES blast
// radius.
//
// CANARY: REQ=REQ-UNSUPPORTED-AGGREGATE-REJECTION; FEATURE="AggregateSetQuantifier"; ASPECT=UnsupportedAggregateReject; STATUS=TESTED; TEST=tests/test_unsupported_aggregates.zig; OWNER=parser; UPDATED=2026-08-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

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
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// Record (do NOT abort on) a statement that was accepted when it should
    /// have been refused, so one RED run enumerates the whole trap surface.
    pub fn checkRefused(
        self: *Harness,
        failures: *std.ArrayListUnmanaged([]const u8),
        gpa: std.mem.Allocator,
        query: []const u8,
    ) !void {
        if (self.exec(query)) |res| {
            // Report the shape of the silent answer, so the RED output names the
            // defect ("returned rows with a NULL statistic") rather than just
            // "expected error".
            const shape: []const u8 = if (res.rows.len == 0)
                "0 rows"
            else if (res.rows[0].len == 0)
                "row with no columns"
            else
                @tagName(res.rows[res.rows.len - 1][res.rows[0].len - 1]);
            try failures.append(gpa, try std.fmt.allocPrint(
                gpa,
                "ACCEPTED (expected refusal), last cell = {s}: {s}",
                .{ shape, query },
            ));
        } else |err| {
            if (err != error.UnsupportedAggregateFunction) {
                try failures.append(gpa, try std.fmt.allocPrint(
                    gpa,
                    "REFUSED with {s} (expected UnsupportedAggregateFunction, which names the function): {s}",
                    .{ @errorName(err), query },
                ));
            }
        }
    }

    pub fn checkAccepted(
        self: *Harness,
        failures: *std.ArrayListUnmanaged([]const u8),
        gpa: std.mem.Allocator,
        query: []const u8,
    ) !void {
        if (self.exec(query)) |_| {} else |err| {
            try failures.append(gpa, try std.fmt.allocPrint(
                gpa,
                "REFUSED with {s} (expected acceptance): {s}",
                .{ @errorName(err), query },
            ));
        }
    }
};

/// Every recognised-but-unimplemented aggregate, in every spelling the engine
/// used to admit somewhere.
const trap_names = [_][]const u8{
    "percentile_cont",
    "percentile_disc",
    "percentileCont",
    "percentileDisc",
    "stddev_samp",
    "stddev_pop",
    "collect_list",
    "stdev",
};

test "UNSUPPORTED-AGGREGATES: unimplemented aggregates are refused, not silently NULL" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var failures: std.ArrayListUnmanaged([]const u8) = .empty;

    _ = try h.exec("CREATE GRAPH eng3914");
    _ = try h.exec("USE GRAPH eng3914");
    _ = try h.exec("CREATE (:AggT {k: 'a', v: 1})");
    _ = try h.exec("CREATE (:AggT {k: 'a', v: 3})");
    _ = try h.exec("CREATE (:AggT {k: 'b', v: 5})");

    for (trap_names) |name| {
        // KEY ASSERTIONS (RED): the GROUPED shape. Every one of these used to
        // return a full result set with a NULL statistic.
        try h.checkRefused(&failures, gpa, try std.fmt.allocPrint(
            gpa,
            "MATCH (n:AggT) RETURN n.k, {s}(n.v) GROUP BY n.k",
            .{name},
        ));
        try h.checkRefused(&failures, gpa, try std.fmt.allocPrint(
            gpa,
            "MATCH (n:AggT) RETURN n.k, {s}(n.v, 0.5) GROUP BY n.k",
            .{name},
        ));

        // The ungrouped shape raised error.UnknownFunction before; it must now
        // raise the error that NAMES the aggregate.
        try h.checkRefused(&failures, gpa, try std.fmt.allocPrint(
            gpa,
            "MATCH (n:AggT) RETURN {s}(n.v)",
            .{name},
        ));

        // With a <set quantifier>: the five snake_case names used to be admitted
        // by the parser's allow-list here specifically.
        try h.checkRefused(&failures, gpa, try std.fmt.allocPrint(
            gpa,
            "MATCH (n:AggT) RETURN {s}(DISTINCT n.v)",
            .{name},
        ));
        try h.checkRefused(&failures, gpa, try std.fmt.allocPrint(
            gpa,
            "MATCH (n:AggT) RETURN {s}(ALL n.v)",
            .{name},
        ));

        // Case-insensitive per ISO/IEC 39075:2024 RQ-0022: the refusal cannot be
        // sidestepped by shouting.
        const upper = try std.ascii.allocUpperString(gpa, name);
        try h.checkRefused(&failures, gpa, try std.fmt.allocPrint(
            gpa,
            "MATCH (n:AggT) RETURN {s}(n.v)",
            .{upper},
        ));

        // Nested inside an expression, and inside WITH — the refusal is on the
        // name, not on one clause position.
        try h.checkRefused(&failures, gpa, try std.fmt.allocPrint(
            gpa,
            "MATCH (n:AggT) RETURN 1 + {s}(n.v)",
            .{name},
        ));
        try h.checkRefused(&failures, gpa, try std.fmt.allocPrint(
            gpa,
            "MATCH (n:AggT) WITH {s}(n.v) AS s RETURN s",
            .{name},
        ));
    }

    if (failures.items.len != 0) {
        std.debug.print("\n[UNSUPPORTED-AGGREGATES] {d} unimplemented-aggregate contract violation(s):\n", .{failures.items.len});
        for (failures.items) |f| std.debug.print("  - {s}\n", .{f});
        return error.UnimplementedAggregateNotRefused;
    }
}

test "UNSUPPORTED-AGGREGATES: the six implemented aggregates keep working, quantifiers included" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var failures: std.ArrayListUnmanaged([]const u8) = .empty;

    _ = try h.exec("CREATE GRAPH eng3914_ok");
    _ = try h.exec("USE GRAPH eng3914_ok");
    _ = try h.exec("CREATE (:AggOk {k: 'a', v: 1})");
    _ = try h.exec("CREATE (:AggOk {k: 'a', v: 3})");
    _ = try h.exec("CREATE (:AggOk {k: 'b', v: 5})");

    const implemented = [_][]const u8{ "count", "sum", "avg", "min", "max", "collect" };
    for (implemented) |name| {
        try h.checkAccepted(&failures, gpa, try std.fmt.allocPrint(gpa, "MATCH (n:AggOk) RETURN {s}(n.v)", .{name}));
        try h.checkAccepted(&failures, gpa, try std.fmt.allocPrint(gpa, "MATCH (n:AggOk) RETURN {s}(DISTINCT n.v)", .{name}));
        try h.checkAccepted(&failures, gpa, try std.fmt.allocPrint(gpa, "MATCH (n:AggOk) RETURN {s}(ALL n.v)", .{name}));
        try h.checkAccepted(&failures, gpa, try std.fmt.allocPrint(gpa, "MATCH (n:AggOk) RETURN n.k, {s}(n.v) GROUP BY n.k", .{name}));
    }
    try h.checkAccepted(&failures, gpa, "MATCH (n:AggOk) RETURN count(*)");

    if (failures.items.len != 0) {
        std.debug.print("\n[UNSUPPORTED-AGGREGATES] {d} implemented aggregate(s) broken by the refusal:\n", .{failures.items.len});
        for (failures.items) |f| std.debug.print("  - {s}\n", .{f});
        return error.ImplementedAggregateRegressed;
    }

    // The refusal must not have changed what the working aggregates COMPUTE.
    const res = try h.exec("MATCH (n:AggOk) RETURN sum(n.v)");
    try testing.expect(res.rows.len == 1);
    try testing.expectEqual(@as(i64, 9), res.rows[0][0].Int);

    const distinct = try h.exec("MATCH (n:AggOk) RETURN count(DISTINCT n.k)");
    try testing.expect(distinct.rows.len == 1);
    try testing.expectEqual(@as(i64, 2), distinct.rows[0][0].Int);
}

test "UNSUPPORTED-AGGREGATES: SHOW FUNCTIONS no longer advertises the unimplemented aggregates" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3914_show");
    _ = try h.exec("USE GRAPH eng3914_show");

    const res = try h.exec("SHOW FUNCTIONS");
    try testing.expect(res.rows.len > 0);

    var advertised_traps: usize = 0;
    var saw_sum = false;
    var saw_collect = false;
    for (res.rows) |row| {
        if (row.len == 0) continue;
        const name = switch (row[0]) {
            .Str => |s| s,
            else => continue,
        };
        for (trap_names) |trap| {
            if (std.ascii.eqlIgnoreCase(name, trap)) {
                std.debug.print("\n[UNSUPPORTED-AGGREGATES] SHOW FUNCTIONS still advertises unimplemented aggregate '{s}'\n", .{name});
                advertised_traps += 1;
            }
        }
        if (std.ascii.eqlIgnoreCase(name, "sum")) saw_sum = true;
        if (std.ascii.eqlIgnoreCase(name, "collect")) saw_collect = true;
    }
    try testing.expectEqual(@as(usize, 0), advertised_traps);

    // Guard against "fix it by emptying the aggregate section".
    try testing.expect(saw_sum);
    try testing.expect(saw_collect);
}
