// SONNY-6702 regression: `LIMIT 0` and a window past the single count row
// returned a row on the engine-direct node scan.
//
// With no WHERE, matched rows are scanned slots, so the scan bounds slot
// collection by OFFSET + LIMIT. `collectMatchingSlotIds` appended a slot and
// only then compared the collected count to that cap, so a cap of 0 still
// collected one slot: `MATCH (n:M) RETURN n.s LIMIT 0` (and `LIMIT $l` with
// l = 0, `RETURN n LIMIT 0`, an inline-map pattern `LIMIT 0`) returned one row.
// An ungrouped `count(*)` stream ignored OFFSET and LIMIT altogether, so
// `RETURN count(*) AS c LIMIT 0` and `... SKIP 1` returned the count row.
// ISO/IEC 39075:2024 14.10 (limit and offset clauses): the one aggregate row
// is windowed like any other.
//
// Leak-checked (`std.testing.allocator`).
//
// CANARY: REQ=REQ-SONNY-6702-LIMIT-ZERO; FEATURE="EngineDirectRowWindow"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6702_limit_zero_node_scan.zig; OWNER=engine; UPDATED=2026-11-17

const std = @import("std");
const testing = std.testing;
const harness = @import("node_scan_stream_harness.zig");

const many = harness.many;

/// Rows the fast path serves for `query`, paging to the end.
fn rowsServed(h: *harness.Harness, qa: *std.heap.ArenaAllocator, query: []const u8, prefetch: bool) !usize {
    const allocator = testing.allocator;
    var stream = try harness.openStream(h, allocator, qa, query);
    defer stream.deinit();
    if (prefetch) try stream.prefetchSchemaSample(allocator);
    var total: usize = 0;
    var pages: usize = 0;
    while (true) : (pages += 1) {
        if (pages > many + 2) return error.NeverFinal;
        var page = try stream.buildNextPage(allocator, 0);
        defer page.result.deinit(allocator);
        total += page.result.rows.len;
        if (page.final) break;
    }
    return total;
}

fn expectRows(h: *harness.Harness, qa: *std.heap.ArenaAllocator, query: []const u8, want: usize) !void {
    for ([_]bool{ false, true }) |prefetch| {
        const got = try rowsServed(h, qa, query, prefetch);
        if (got != want) {
            std.debug.print("{s} (prefetch={}): expected {d} rows, found {d}\n", .{ query, prefetch, want, got });
            return error.TestExpectedEqual;
        }
    }
}

test "SONNY-6702: LIMIT 0 on an unfiltered node scan returns no rows" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try harness.seedMany(&h);
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    try expectRows(&h, &qa, "MATCH (n:M) RETURN n.s LIMIT 0", 0);
    try expectRows(&h, &qa, "MATCH (n:M) RETURN n.s, n.i LIMIT 0", 0);
    try expectRows(&h, &qa, "MATCH (n:M) RETURN n LIMIT 0", 0);
    try expectRows(&h, &qa, "MATCH (n:M) RETURN n.s OFFSET 3 LIMIT 0", 0);
    try expectRows(&h, &qa, "MATCH (n:M {i: 4}) RETURN n.s LIMIT 0", 0);
    // The neighbours of the bug keep their rows.
    try expectRows(&h, &qa, "MATCH (n:M) RETURN n.s LIMIT 1", 1);
    try expectRows(&h, &qa, "MATCH (n:M) RETURN n.s LIMIT 7", 7);
    try expectRows(&h, &qa, "MATCH (n:M) RETURN n.s OFFSET 3 LIMIT 2", 2);
    try expectRows(&h, &qa, "MATCH (n:M {i: 4}) RETURN n.s LIMIT 1", 1);
    try expectRows(&h, &qa, "MATCH (n:M) WHERE n.i >= 3 RETURN n.s LIMIT 0", 0);
}

test "SONNY-6702: an ungrouped count honours OFFSET and LIMIT on its one row" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try harness.seedMany(&h);
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    try expectRows(&h, &qa, "MATCH (n:M) RETURN count(*) AS c", 1);
    try expectRows(&h, &qa, "MATCH (n:M) RETURN count(*) AS c LIMIT 1", 1);
    try expectRows(&h, &qa, "MATCH (n:M) RETURN count(*) AS c OFFSET 0", 1);
    try expectRows(&h, &qa, "MATCH (n:M) RETURN count(*) AS c LIMIT 0", 0);
    try expectRows(&h, &qa, "MATCH (n:M) RETURN count(*) AS c SKIP 1", 0);
    try expectRows(&h, &qa, "MATCH (n:M) RETURN count(*) AS c OFFSET 1 LIMIT 5", 0);
    try expectRows(&h, &qa, "MATCH (n:M {i: 4}) RETURN count(*) AS c OFFSET 1", 0);
    try expectRows(&h, &qa, "MATCH (n:M {i: 4}) RETURN count(*) AS c LIMIT 0", 0);
    try expectRows(&h, &qa, "MATCH (n:M) WHERE n.i >= 3 RETURN count(*) AS c LIMIT 0", 0);
    try expectRows(&h, &qa, "MATCH (n:M) WHERE n.i >= 3 RETURN count(*) AS c OFFSET 1", 0);
    try expectRows(&h, &qa, "MATCH (n:M) WHERE n.i >= 3 RETURN count(*) AS c LIMIT 1", 1);
}

fn executorRows(h: *harness.Harness, query: []const u8) !usize {
    const aa = h.arena.allocator();
    var r = try h.run(query);
    defer r.deinit(aa);
    return r.rows.len;
}

test "SONNY-6702: the executor windows an ungrouped count and a LIMIT 0 scan the same way" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try harness.seedMany(&h);

    const cases = [_]struct { q: []const u8, want: usize }{
        .{ .q = "MATCH (n:M) RETURN n.s LIMIT 0", .want = 0 },
        .{ .q = "MATCH (n:M) RETURN count(*) AS c", .want = 1 },
        .{ .q = "MATCH (n:M) RETURN count(*) AS c LIMIT 1", .want = 1 },
        .{ .q = "MATCH (n:M) RETURN count(*) AS c LIMIT 0", .want = 0 },
        .{ .q = "MATCH (n:M) RETURN count(*) AS c SKIP 1", .want = 0 },
        .{ .q = "MATCH (n:M) RETURN count(*) AS c OFFSET 1", .want = 0 },
        .{ .q = "MATCH (n:M) RETURN count(n) AS c OFFSET 1 LIMIT 3", .want = 0 },
        .{ .q = "MATCH (n:M {i: 4}) RETURN count(*) AS c OFFSET 1", .want = 0 },
        .{ .q = "MATCH (n:M) WHERE n.i >= 3 RETURN count(*) AS c OFFSET 1", .want = 0 },
    };
    for (cases) |c| {
        const got = try executorRows(&h, c.q);
        if (got != c.want) {
            std.debug.print("{s}: expected {d} rows, found {d}\n", .{ c.q, c.want, got });
            return error.TestExpectedEqual;
        }
    }
}

// A COLD store: seeded, closed and reopened, so nothing is resident and the
// first statements run on the storage-native path the server takes right after
// a restart.
const geode = @import("geode");
const logging = @import("logging");
const execution = geode.execution;
const graph_store = geode.graph_store;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const ColdSession = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    ctx: execution.ExecutionContext,

    fn open(allocator: std.mem.Allocator, data_dir: []const u8) !ColdSession {
        logging.init(.{ .level = .fatal });
        logging.setLevel(.fatal);
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        _ = try graph_store.initGlobalStore(allocator, data_dir);
        execution.initEvaluator();
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator), .ctx = execution.ExecutionContext{ .catalog = catalog } };
    }

    fn close(self: *ColdSession) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
    }

    fn rows(self: *ColdSession, query: []const u8) !usize {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        var r = try execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
        defer r.deinit(aa);
        return r.rows.len;
    }
};

test "SONNY-6702: a cold store windows an ungrouped count and a LIMIT 0 scan too" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    {
        var s = try ColdSession.open(allocator, data_dir);
        defer s.close();
        for (0..3) |i| {
            const q = try std.fmt.allocPrint(s.arena.allocator(), "CREATE (:C6702 {{k: {d}}})", .{i});
            _ = try s.rows(q);
        }
    }

    var s = try ColdSession.open(allocator, data_dir);
    defer s.close();
    const cases = [_]struct { q: []const u8, want: usize }{
        .{ .q = "MATCH (n:C6702) RETURN count(*) AS c OFFSET 1", .want = 0 },
        .{ .q = "MATCH (n:C6702) RETURN count(*) AS c LIMIT 0", .want = 0 },
        .{ .q = "MATCH (n:C6702) RETURN count(*) AS c SKIP 1", .want = 0 },
        .{ .q = "MATCH (n:C6702) RETURN n.k AS k LIMIT 0", .want = 0 },
        .{ .q = "MATCH (n:C6702) RETURN count(*) AS c", .want = 1 },
        .{ .q = "MATCH (n:C6702) RETURN count(*) AS c LIMIT 1", .want = 1 },
        .{ .q = "MATCH (n:C6702) RETURN n.k AS k LIMIT 2", .want = 2 },
    };
    for (cases) |c| {
        const got = try s.rows(c.q);
        if (got != c.want) {
            std.debug.print("{s}: expected {d} rows, found {d}\n", .{ c.q, c.want, got });
            return error.TestExpectedEqual;
        }
    }
}

test "SONNY-6702: the node-scan stream of a cold store windows an ungrouped count too" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    {
        var s = try ColdSession.open(allocator, data_dir);
        defer s.close();
        for (0..3) |i| {
            const q = try std.fmt.allocPrint(s.arena.allocator(), "CREATE (:C6702 {{k: {d}}})", .{i});
            _ = try s.rows(q);
        }
    }
    var s = try ColdSession.open(allocator, data_dir);
    defer s.close();
    var qa = std.heap.ArenaAllocator.init(allocator);
    defer qa.deinit();
    const cases = [_]struct { q: []const u8, want: usize }{
        .{ .q = "MATCH (n:C6702) RETURN count(*) AS c OFFSET 1", .want = 0 },
        .{ .q = "MATCH (n:C6702) RETURN count(*) AS c LIMIT 0", .want = 0 },
        .{ .q = "MATCH (n:C6702) RETURN n.k AS k LIMIT 0", .want = 0 },
        .{ .q = "MATCH (n:C6702) RETURN count(*) AS c", .want = 1 },
    };
    for (cases) |c| {
        const q = try harness.parseQuery(&qa, c.q);
        var stream = (try geode.node_scan_stream.prepare(allocator, q, s.ctx, &.{}, &.{}, &.{})) orelse {
            std.debug.print("{s}: the fast path declined\n", .{c.q});
            return error.FastPathDeclined;
        };
        defer stream.deinit();
        var total: usize = 0;
        while (true) {
            var page = try stream.buildNextPage(allocator, 0);
            defer page.result.deinit(allocator);
            total += page.result.rows.len;
            if (page.final) break;
        }
        if (total != c.want) {
            std.debug.print("{s}: expected {d} rows, found {d}\n", .{ c.q, c.want, total });
            return error.TestExpectedEqual;
        }
    }
}
