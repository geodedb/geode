// SONNY-3377: an unlabeled relationship scan with a property filter,
// `MATCH ()-[e]->() WHERE e.zz = 1 RETURN count(e)`, must answer after the
// persisted store is reloaded. It failed with EdgeSlotMappingMissing: the
// storage-native read materialized each relationship through the graph's
// IdMap, which a reload had not filled for edges yet.
//
// CANARY: REQ=REQ-SONNY-3377-EDGE-SCAN-RELOAD; FEATURE="StorageNativeReads"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3377_unlabeled_edge_scan_reload.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const query_arena = geode.query_arena;

const EDGES: usize = 40;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Run `query` through the executor and return the first cell of its one
/// row as an integer.
fn countOf(allocator: std.mem.Allocator, query: []const u8) !i64 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const prev_scratch = query_arena.pushScratchAllocator(scratch.allocator());
    defer query_arena.popScratchAllocator(prev_scratch);

    var parsed = try geode.parseGql(query, allocator);
    defer parsed.deinit();
    const catalog = try execution.ensureCatalogInstance(allocator);
    var result = try execution.executeProgramWithContext(allocator, &parsed.program, .{ .catalog = catalog });
    defer result.deinit(allocator);
    if (result.rows.len != 1 or result.rows[0].len < 1) return error.UnexpectedRows;
    return switch (result.rows[0][result.rows[0].len - 1]) {
        .Int => |v| v,
        else => error.UnexpectedValue,
    };
}

fn run(allocator: std.mem.Allocator, query: []const u8) !void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const prev_scratch = query_arena.pushScratchAllocator(scratch.allocator());
    defer query_arena.popScratchAllocator(prev_scratch);

    var parsed = try geode.parseGql(query, allocator);
    defer parsed.deinit();
    const catalog = try execution.ensureCatalogInstance(allocator);
    var result = try execution.executeProgramWithContext(allocator, &parsed.program, .{ .catalog = catalog });
    result.deinit(allocator);
}

const queries = [_]struct { q: []const u8, want: i64 }{
    .{ .q = "MATCH ()-[e]->() WHERE e.zz = 1 RETURN count(e) AS c", .want = EDGES / 2 },
    .{ .q = "MATCH ()-[e]->() RETURN count(e) AS c", .want = EDGES },
    .{ .q = "MATCH (a)-[e]->(b) WHERE e.zz = 1 RETURN count(*) AS c", .want = EDGES / 2 },
    .{ .q = "MATCH ()-[e:R]->() WHERE e.zz = 1 RETURN count(e) AS c", .want = EDGES / 2 },
};

test "SONNY-3377: an unlabeled relationship scan with a property filter answers after a reload" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    {
        _ = try graph_store.initGlobalStore(allocator, data_dir);
        defer graph_store.deinitGlobalStore();
        defer execution.cleanupCatalogInstance();
        var buf: [96]u8 = undefined;
        for (0..EDGES) |i| {
            try run(allocator, try std.fmt.bufPrint(&buf, "CREATE (:A {{i: {d}}})-[:R {{zz: {d}}}]->(:B {{i: {d}}})", .{ i, i % 2, i }));
        }
        for (queries) |c| try std.testing.expectEqual(c.want, try countOf(allocator, c.q));
    }

    // Reloaded, twice: after a clean shutdown, and after a crash-style
    // teardown that skips the IdMap snapshot.
    for (0..2) |round| {
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        defer if (round == 0) graph_store.deinitGlobalStoreForTestCrash() else graph_store.deinitGlobalStore();
        defer execution.cleanupCatalogInstance();
        try store.loadFromFile();
        var failed: usize = 0;
        for (queries) |c| {
            const got = countOf(allocator, c.q) catch |err| {
                std.debug.print("reload {d}: '{s}' failed: {s}\n", .{ round, c.q, @errorName(err) });
                failed += 1;
                continue;
            };
            if (got != c.want) {
                std.debug.print("reload {d}: '{s}' = {d}, want {d}\n", .{ round, c.q, got, c.want });
                failed += 1;
            }
        }
        if (failed > 0) return error.EdgeScanAfterReloadFailed;
    }
}
