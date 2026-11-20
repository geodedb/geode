// SONNY-3317 regression (round 16): the round 15 review's minor findings.
//
// - M4: `createGraph` and `openOrCreateGraphWithUuid` kept an errdefer armed
//   on their copy of the name after the copy was freed as a duplicate or
//   became the `graphs` key, so an out of memory later in them freed it
//   (twice, or while in use). Every allocation of each is failed in turn
//   here, under the testing allocator.
// - M5: `GEODE_QUIC_ADMISSION_STACK_MB` took 1 MiB; its floor is 8 MiB.
//   Pinned in main.zig, and a server started with 1 serves a first stream.
// - M7: `clearNodes` (reload, Raft snapshot install) freed the caches with no
//   shard lock, and the Raft install ran with no store lock. (Its test raced
//   the JSON-lines snapshot install, removed with it in SONNY-6636.)
// - M8: `createSessionAs` leaked the tenant's connection quota when the copy
//   of the tenant id could not be made; every allocation of a Handshake with
//   a tenant is failed in turn here, and the quota must come back each time.
//
// CANARY: REQ=REQ-SONNY-3317-ROUND15-MINORS; FEATURE="MultiGraphIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3317_round15_minors.zig; OWNER=storage; UPDATED=2026-09-28

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const geode = @import("geode");
const util = @import("proto_test_util.zig");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;
const tenant_quota = geode.tenant_quota;

fn createGraphUnderFailure(which: enum { create, open_with_uuid }) !void {
    var k: usize = 0;
    while (k < 64) : (k += 1) {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
        var st = try graph_store.GraphStore.init(fa.allocator());
        defer st.deinit();
        // Only the call under test fails: the store's own teardown allocates.
        defer fa.fail_index = std.math.maxInt(usize);
        // Fail the k-th allocation the call makes.
        fa.fail_index = fa.alloc_index + k;
        const result = switch (which) {
            .create => st.createGraph("m4g"),
            .open_with_uuid => st.openOrCreateGraphWithUuid("m4g", [_]u8{7} ** 16),
        };
        if (result) |_| {
            if (!fa.has_induced_failure) return; // every allocation succeeded
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
    return error.TooManyAllocations;
}

test "SONNY-3317 (M4): createGraph and openOrCreateGraphWithUuid free their name copy once, under an out of memory at each allocation" {
    if (graph_store.getGlobalAdapter() != null) return error.SkipZigTest;
    try createGraphUnderFailure(.create);
    try createGraphUnderFailure(.open_with_uuid);
}

test "SONNY-3317 (M8): a Handshake with a tenant that fails at any allocation gives the tenant's connection quota back" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    var qm = tenant_quota.TenantQuotaManager.init(testing.allocator);
    defer qm.deinit();
    const prev = tenant_quota.getGlobalQuotaManager();
    tenant_quota.setGlobalQuotaManager(&qm);
    defer tenant_quota.setGlobalQuotaManager(prev);
    var k: usize = 0;
    var failed: usize = 0;
    while (k < 200) : (k += 1) {
        var fa = std.testing.FailingAllocator.init(std.heap.smp_allocator, .{});
        var store = grpc.SessionStore.init(fa.allocator(), .{ .idle_in_transaction_timeout_ms = 0, .session_idle_timeout_ms = 0, .max_sessions_per_principal = 4 });
        defer store.deinit();
        defer fa.fail_index = std.math.maxInt(usize);
        fa.fail_index = fa.alloc_index + k;
        if (store.createSessionAs("m8", "", "", null, "tenant-m8", null, false, 0)) |_| {
            try testing.expectEqual(@as(u32, 1), qm.getUsage("tenant-m8").connections);
            if (!fa.has_induced_failure) break;
        } else |err| {
            failed += 1;
            try testing.expectEqual(error.OutOfMemory, err);
            // A Handshake that failed holds no connection of the tenant's.
            const held = qm.getUsage("tenant-m8").connections;
            if (held != 0) std.debug.print("SONNY-3317 M8: failing allocation {d} left {d} connection(s) held\n", .{ k, held });
            try testing.expectEqual(@as(u32, 0), held);
        }
    }
    std.debug.print("SONNY-3317 M8: {d} failing allocations tried, quota given back each time\n", .{failed});
    try testing.expect(failed > 0);
    try testing.expectEqual(@as(u32, 0), qm.getUsage("tenant-m8").connections);
}

test "SONNY-3317 (M5): the QUIC admission stack's floor is 8 MiB (pinned), and a server told 1 MiB serves" {
    const main_src = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "src/server/main.zig", testing.allocator, .limited(8 * 1024 * 1024));
    defer testing.allocator.free(main_src);
    try testing.expect(std.mem.indexOf(u8, main_src, "const min_quic_admission_stack_mb: usize = 8;") != null);
    try testing.expect(std.mem.indexOf(u8, main_src, "default_quic_admission_stack_mb,\n            min_quic_admission_stack_mb,") != null);

    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny3317-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(
        allocator,
        &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir },
        &.{ "GEODE_QUIC_DETACHED_CONNECTION_ADMISSION=1", "GEODE_QUIC_ADMISSION_STACK_MB=1" },
    );
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);
    var c = try util.QuicProtoClient.connect(allocator, addr);
    defer c.deinit();
    var h = try c.hello(allocator, util.defaultUsername(), util.defaultPassword());
    h.deinit(allocator);
    for ([_][]const u8{ "CREATE (:P {name: 'x', age: 40})", "MATCH (n:P) WHERE n.age > 30 AND n.name = 'x' RETURN n.name ORDER BY n.name LIMIT 10", "RETURN [[[[[[[[1]]]]]]]] AS x" }) |q| {
        var r = try c.executeAndCollectWithTimeout(allocator, q, util.emptyParams(), 100, 30);
        defer r.deinit(allocator);
        std.debug.print("SONNY-3317 M5 (admission stack env 1): {s} -> {s}\n", .{ q, r.error_code orelse "ran" });
        try testing.expect(r.error_code == null);
    }
    try testing.expect(util.processAlive(server.child.id.?));
}
