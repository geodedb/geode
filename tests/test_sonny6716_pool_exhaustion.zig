// CANARY: REQ=REQ-SONNY-6716-POOL-EXHAUSTION; FEATURE="BufferPool"; ASPECT=SmallPoolFloorAndCleanOversizedStatement; STATUS=TESTED; TEST=tests/test_sonny6716_pool_exhaustion.zig; OWNER=storage; UPDATED=2026-11-17
//
// SONNY-6716: with GEODE_BUFFER_POOL_PAGES=96 (and auto-sizing off) auto-commit
// writes failed with BufferPoolFull once the data outgrew the pool.
//
// Cause. graph-storage splits the pool across its 16 shards: 96 pages are 6
// frames per shard. No-steal (SONNY-6648) keeps every page an open transaction
// dirtied in the pool until it ends, and one statement that creates two nodes
// with a relationship dirties about eight pages of one shard (node, property,
// var-store, adjacency, in-edge directory, free-space pages). Six frames cannot
// hold that, so writes failed (not a leak: committed pages stay evictable, a
// probe of 1500 committed transactions in an 8-frame pool never fails).
//
// Contract.
//  1. A configured pool smaller than 16 frames per shard is raised to 16 per
//     shard (256 pages), with a warning. Writes then never run out of frames
//     for a statement of ordinary size, however much data the store holds.
//  2. A statement that on its own dirties more pages than the pool holds fails
//     with 53200 naming GEODE_BUFFER_POOL_PAGES, applies nothing and leaves the
//     server usable (needs graph-storage's undo reserve, SONNY-6716 0.4.29: the
//     test skips until the pinned graph-storage has it).
//
// Real `geode serve`, real wire.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const gs = @import("graph_storage");
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn connect(addr: []const u8) !util.QuicProtoClient {
    var c = try util.QuicProtoClient.connect(testing.allocator, addr);
    errdefer c.deinit();
    var h = try c.hello(testing.allocator, util.defaultUsername(), util.defaultPassword());
    defer h.deinit(testing.allocator);
    if (!h.success) return error.HelloRefused;
    return c;
}

/// The error code of `query` (owned), or null when it succeeded.
fn status(client: *util.QuicProtoClient, query: []const u8) !?[]u8 {
    var r = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 100);
    defer r.deinit(testing.allocator);
    if (r.error_code) |c| return try testing.allocator.dupe(u8, c);
    return null;
}

fn count(client: *util.QuicProtoClient, query: []const u8) !i64 {
    var r = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 100);
    defer r.deinit(testing.allocator);
    if (r.error_code != null or r.rows.len != 1) return error.UnexpectedResult;
    return switch (r.rows[0][0]) {
        .int => |v| v,
        else => error.UnexpectedValue,
    };
}

const Server = struct {
    handle: util.ServerHandle,
    addr: []u8,
    root: []u8,

    fn start(pool_pages: []const u8) !Server {
        const a = testing.allocator;
        const root = try std.fmt.allocPrint(a, "/tmp/geode-6716-{d}", .{std.os.linux.getpid()});
        errdefer a.free(root);
        std.Io.Dir.cwd().deleteTree(io(), root) catch {};
        const data_dir = try std.fmt.allocPrint(a, "{s}/data", .{root});
        defer a.free(data_dir);
        try std.Io.Dir.cwd().createDirPath(io(), data_dir);
        const addr = try util.formatAddr(a, try util.getRandomPort());
        errdefer a.free(addr);
        const pages_env = try std.fmt.allocPrint(a, "GEODE_BUFFER_POOL_PAGES={s}", .{pool_pages});
        defer a.free(pages_env);
        var handle = try util.spawnServer(a, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, &.{ pages_env, "GEODE_BUFFER_POOL_AUTO_SIZE=0" });
        errdefer handle.deinit();
        try util.waitForServerReady(a, addr, 60000);
        return .{ .handle = handle, .addr = addr, .root = root };
    }

    fn stop(self: *Server) void {
        self.handle.deinit();
        std.Io.Dir.cwd().deleteTree(io(), self.root) catch {};
        testing.allocator.free(self.addr);
        testing.allocator.free(self.root);
    }
};

test "SONNY-6716: a 96-page pool is raised to a working size; 750 two-node-and-edge statements all succeed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try Server.start("96");
    defer server.stop();
    var c = try connect(server.addr);
    defer c.deinit();
    const pad = try testing.allocator.alloc(u8, 1000);
    defer testing.allocator.free(pad);
    @memset(pad, 'p');
    var failed: usize = 0;
    var first_code: ?[]u8 = null;
    defer if (first_code) |f| testing.allocator.free(f);
    var k: usize = 1;
    while (k <= 750) : (k += 1) {
        const q = try std.fmt.allocPrint(testing.allocator, "CREATE (:S6716 {{i: {d}, pad: '{s}'}})-[:NEXT]->(:S6716 {{i: {d}, pad: '{s}'}})", .{ 2 * k - 1, pad, 2 * k, pad });
        defer testing.allocator.free(q);
        if (try status(&c, q)) |code| {
            failed += 1;
            if (first_code == null) first_code = code else testing.allocator.free(code);
        }
    }
    if (failed != 0) std.debug.print("SONNY-6716: {d} of 750 statements failed (first: {?s})\n", .{ failed, first_code });
    try testing.expectEqual(@as(usize, 0), failed);
    try testing.expectEqual(@as(i64, 1500), try count(&c, "MATCH (n:S6716) RETURN count(n) AS c"));
}

test "SONNY-6716: a statement larger than the pool fails with 53200, applies nothing and the server keeps working" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (!@hasDecl(gs.buffer_pool, "enterUndoReplay")) return error.SkipZigTest; // graph-storage < 0.4.29
    var server = try Server.start("256");
    defer server.stop();
    var c = try connect(server.addr);
    defer c.deinit();
    const pad = try testing.allocator.alloc(u8, 1000);
    defer testing.allocator.free(pad);
    @memset(pad, 'p');
    try testing.expect((try status(&c, "CREATE (:Keep6716 {i: 1})")) == null);
    const q = try std.fmt.allocPrint(testing.allocator, "FOR i IN range(1, 4000) CREATE (:Big6716 {{i: i, pad: '{s}'}})", .{pad});
    defer testing.allocator.free(q);
    const code = (try status(&c, q)) orelse return error.OversizedStatementSucceeded;
    defer testing.allocator.free(code);
    try testing.expectEqualStrings("53200", code);
    try testing.expectEqual(@as(i64, 0), try count(&c, "MATCH (n:Big6716) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 1), try count(&c, "MATCH (n:Keep6716) RETURN count(n) AS c"));
    try testing.expect((try status(&c, "CREATE (:Keep6716 {i: 2})")) == null);
}

test "SONNY-6716: BufferPoolFull answers 53200 and names the knob, not 58000" {
    const info = geode.proto_util.mapError(error.BufferPoolFull);
    try testing.expectEqualStrings("53200", info.code);
    try testing.expect(std.mem.indexOf(u8, info.message, "GEODE_BUFFER_POOL_PAGES") != null);
}
