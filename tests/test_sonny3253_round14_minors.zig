// SONNY-3253 (round 15, F11, F13): the round 14 review's minor findings.
//
// F11: a dropped graph's IdMap was kept until the store went (about 0.5 KB
// per DROP GRAPH, unbounded), and `clearNodes` (reload, Raft snapshot
// install) freed every IdMap outright, breaking the address
// `idMapsSnapshot` promises the walks that hold one. Now an IdMap no walk
// holds is freed at DROP GRAPH; one a walk holds is freed when the last walk
// lets its list go; `clearNodes` does the same. SONNY-3314 (round 16) made
// the hold per map: a map not on a walk's list is freed at its drop.
//
// F13: the QUIC admission threads' stacks reserve `threads x stack` of
// address space (4096 x 16 MiB = 64 GiB); a release build now takes 8 MiB,
// GEODE_QUIC_ADMISSION_STACK_MB overrides it, and a thread that cannot be
// spawned rejects its connection while the server serves on (tested with a
// stack no kernel will map: 512 TiB, above every 64-bit Linux mmap window.
// The first version used 1 TiB, which a kernel with vm.overcommit_memory=1,
// as on the k8s CI nodes, maps, so the connection was served).
//
// CANARY: REQ=REQ-SONNY-3253-RETIRED-IDMAPS; FEATURE="IdMap"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3253_round14_minors.zig; OWNER=storage; UPDATED=2026-09-28

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const util = @import("proto_test_util.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;
const labels_z = [_][]const u8{"Z"};

fn monoMs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn churn(st: *graph_store.GraphStore, n: usize) !void {
    var buf: [32]u8 = undefined;
    const labels = [_][]const u8{"Z"};
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const name = try std.fmt.bufPrint(&buf, "rt{d}", .{i});
        try st.createGraph(name);
        _ = try st.createNodeWithGraph(&labels, name);
        try st.dropGraph(name);
    }
}

// IdMap lifetime is GraphStore behavior in both supported storage modes.
// The large sweep uses the real in-memory store; the persisted sweep also
// exercises the adapter without opening more files than Darwin permits.
fn checkIdMapRetirement(st: *graph_store.GraphStore, held_graph_count: usize, churn_count: usize) !void {
    std.debug.print("sizeof(IdMap)={d} bytes, a retired entry {d} bytes more\n", .{ @sizeOf(graph_store.IdMap), @sizeOf(graph_store.GraphStore.IdMapRef) });
    // No walk: nothing is kept.
    try churn(st, churn_count);
    std.debug.print("after {d} drops with no walk: retired={d}\n", .{ churn_count, st.retired_id_maps.items.len });
    try testing.expectEqual(@as(usize, 0), st.retired_id_maps.items.len);
    // A walk lists every held graph; dropped maps are kept, then
    // freed when it lets go. SONNY-3314 (round 16, M1): a graph made and
    // dropped after the walk began is not on its list, and is freed at once
    // (round 15 kept it until no walk at all ran).
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < held_graph_count) : (i += 1) {
        const name = try std.fmt.bufPrint(&buf, "held{d}", .{i});
        try st.createGraph(name);
        _ = try st.createNodeWithGraph(&labels_z, name);
    }
    const refs = try st.idMapsSnapshotForTest(testing.allocator);
    // Every created graph must have a real IdMap on the snapshot, so the
    // in-memory path cannot pass with an empty set of maps.
    var held_maps: usize = 0;
    for (refs) |r| if (std.mem.startsWith(u8, r.graph_name, "held")) {
        held_maps += 1;
    };
    try testing.expectEqual(held_graph_count, held_maps);
    i = 0;
    while (i < held_graph_count) : (i += 1) {
        const name = try std.fmt.bufPrint(&buf, "held{d}", .{i});
        try st.dropGraph(name);
    }
    try churn(st, 20);
    // The IdMaps the walk listed are still whole (their contents emptied).
    for (refs) |r| _ = r.map.nodeCount();
    std.debug.print("{d} listed graphs dropped while a walk holds the list, and 20 unlisted ones: retired={d}\n", .{ held_graph_count, st.retired_id_maps.items.len });
    try testing.expectEqual(held_graph_count, st.retired_id_maps.items.len);
    st.releaseIdMapsForTest(testing.allocator, refs);
    try testing.expectEqual(@as(usize, 0), st.retired_id_maps.items.len);
}

test "SONNY-3253 (F11): a dropped graph's IdMap is freed when no walk holds it, and when the last walk lets go otherwise" {
    try testing.expect(graph_store.getGlobalAdapter() == null);
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    try checkIdMapRetirement(&store, 50, 200);
}

test "SONNY-3253 (F11): persisted graph drops retain exactly the IdMaps held by a walk" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    // Each graph owns sixteen real storage shards. Sixteen simultaneously
    // held graphs stay below Zig's Darwin OPEN_MAX ceiling while exercising
    // the same adapter-backed drop and retirement paths as production.
    try checkIdMapRetirement(f.st, 16, 20);
}

test "SONNY-3253 (F11): clearNodes (reload, Raft snapshot install) keeps an IdMap a walk holds until the walk lets go" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const labels = [_][]const u8{"K"};
    _ = try f.st.createNodeWithGraph(&labels, "g1");
    const refs = try f.st.idMapsSnapshotForTest(testing.allocator);
    try testing.expect(refs.len > 0);
    try f.st.clearNodes();
    // Round 14 freed them here: this read was of freed memory.
    for (refs) |r| try testing.expectEqual(@as(u32, 0), r.map.nodeCount());
    try testing.expect(f.st.retired_id_maps.items.len >= refs.len);
    f.st.releaseIdMapsForTest(testing.allocator, refs);
    try testing.expectEqual(@as(usize, 0), f.st.retired_id_maps.items.len);
}

test "SONNY-3253 (F13): a QUIC admission thread that cannot be spawned rejects its connection, quickly, and the server serves on" {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny3253-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    // A 512 TiB admission stack (GEODE_QUIC_ADMISSION_STACK_MB's ceiling):
    // larger than the 47-bit (x86-64) or 48-bit (arm64) mmap window, so even
    // the PROT_NONE reservation fails and every spawn fails, whatever the
    // kernel's overcommit policy. 1 TiB was mapped under
    // vm.overcommit_memory=1 (k8s nodes) and the connection was served.
    var server = try util.spawnServer(
        allocator,
        &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir },
        &.{ "GEODE_QUIC_DETACHED_CONNECTION_ADMISSION=1", "GEODE_QUIC_ADMISSION_STACK_MB=536870912" },
    );
    defer server.deinit();
    fx.sleepMs(4000);
    try testing.expect(util.processAlive(server.child.id.?));
    var attempt: usize = 0;
    while (attempt < 3) : (attempt += 1) {
        const t0 = monoMs();
        const outcome: []const u8 = blk: {
            var c = util.QuicProtoClient.connect(allocator, addr) catch |err| break :blk @errorName(err);
            defer c.deinit();
            var h = c.hello(allocator, util.defaultUsername(), util.defaultPassword()) catch |err| break :blk @errorName(err);
            h.deinit(allocator);
            break :blk "served";
        };
        const ms = monoMs() - t0;
        std.debug.print("connection {d} with the admission spawn failing: {s} in {d} ms; server alive={}\n", .{ attempt, outcome, ms, util.processAlive(server.child.id.?) });
        // Refused, not served and not hung (the client's own timeouts are
        // tens of seconds).
        try testing.expect(!std.mem.eql(u8, outcome, "served"));
        try testing.expect(ms < 20_000);
        try testing.expect(util.processAlive(server.child.id.?));
    }
}
