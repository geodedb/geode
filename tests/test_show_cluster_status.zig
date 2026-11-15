// CANARY: REQ=REQ-DIST-SHOW-CLUSTER-STATUS; FEATURE="SHOW CLUSTER STATUS"; ASPECT=ShowClusterStatusTest; STATUS=TESTED; TEST=tests/test_show_cluster_status.zig; OWNER=distributed; UPDATED=2026-05-26
// Task A7 (2026-05-25 distributed cluster testing plan):
// SHOW CLUSTER STATUS GQL-statement smoke tests.
//
// Two scenarios:
//
//   1. Standalone mode (no global ClusterCoordinator wired): the handler
//      must return exactly one row with role=standalone, node_id=0,
//      leader_id=0, term=0, endpoint=0.0.0.0:0.  This is what every test
//      runner and the harness B2 probe relies on as the "no cluster" baseline.
//
//   2. 3-node in-process cluster: after the cluster elects a leader (driven
//      via raft_lib.InProcessTransport, mirroring tests A5 / A3d), executing
//      SHOW CLUSTER STATUS against the leader's context must return exactly
//      3 rows, exactly one row must report role=leader, and all rows must
//      agree on leader_id.  This guarantees the harness can read a stable
//      membership view via a single GQL roundtrip.
//
// We call `admin_ddl.executeShowClusterStatus` directly rather than going
// through the parser + execution pipeline.  The parser is exercised
// separately (see the unit tests at the bottom of src/gql/parser.zig and
// any future geodetestlab spec); this file is concerned with the global
// coordinator handle and the row-builder logic only.

const std = @import("std");
const geode = @import("geode");

const ClusterCoordinator = geode.distributed.cluster.ClusterCoordinator;
const cluster_mod = geode.distributed.cluster;
const raft_lib = geode.distributed.raft;
// SONNY-6633 (5): every message with its real sender (it was guessed).
const raft_net = @import("raft_inproc_net.zig");
const admin_ddl = geode.execution.admin_ddl;
const execution = geode.execution;
const value_types = geode.value_types;

fn nowMillis() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    if (comptime @import("builtin").os.tag == .linux) {
        const req = std.os.linux.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
    } else {
        const req = std.c.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
    }
}

// ---------------------------------------------------------------------------
// Test 1: standalone mode
// ---------------------------------------------------------------------------

test "SHOW CLUSTER STATUS in standalone mode returns one row with role=standalone" {
    const allocator = std.testing.allocator;

    // Defensive: clear any global ClusterCoordinator pointer left over from
    // a prior test in this binary.  Tests run sequentially in Zig's
    // single-binary harness, so the global is shared state we own.
    cluster_mod.clearGlobalClusterCoordinator();

    // executeShowClusterStatus takes (allocator, ExecutionContext).  It does
    // NOT read any field from the context yet — we pass a stub with a
    // valid catalog pointer so the struct invariant holds (catalog is a
    // *Catalog, must not be undefined).
    const catalog = try execution.ensureCatalogInstance(allocator);
    defer execution.cleanupCatalogInstance();

    const ctx = execution.ExecutionContext{ .catalog = catalog };
    var res = try admin_ddl.executeShowClusterStatus(allocator, ctx);
    defer res.deinit(allocator);

    // Exactly one row.
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);

    // Column count = 6: node_id, role, term, leader_id, endpoint, last_contact_ms.
    try std.testing.expectEqual(@as(usize, 6), res.columns.len);
    try std.testing.expectEqualStrings("node_id", res.columns[0]);
    try std.testing.expectEqualStrings("role", res.columns[1]);
    try std.testing.expectEqualStrings("term", res.columns[2]);
    try std.testing.expectEqualStrings("leader_id", res.columns[3]);
    try std.testing.expectEqualStrings("endpoint", res.columns[4]);
    try std.testing.expectEqualStrings("last_contact_ms", res.columns[5]);

    // Row contents.
    const row = res.rows[0];
    try std.testing.expectEqual(@as(i64, 0), row[0].Int); // node_id = 0
    try std.testing.expectEqualStrings("standalone", row[1].Str); // role
    try std.testing.expectEqual(@as(i64, 0), row[2].Int); // term = 0
    try std.testing.expectEqual(@as(i64, 0), row[3].Int); // leader_id = 0
    try std.testing.expectEqualStrings("0.0.0.0:0", row[4].Str); // endpoint
    try std.testing.expectEqual(@as(i64, 0), row[5].Int); // last_contact_ms = 0
}

// ---------------------------------------------------------------------------
// Test 2: 3-node in-process cluster — exactly one leader, consistent leader_id
// ---------------------------------------------------------------------------

test "SHOW CLUSTER STATUS in 3-node cluster returns 3 rows with consistent leader" {
    const a = std.testing.allocator;

    // Make sure no stale global pointer is set before we install ours.
    cluster_mod.clearGlobalClusterCoordinator();
    defer cluster_mod.clearGlobalClusterCoordinator();

    // Build three coordinators wired exactly the way the A5 / A3d tests do.
    // Each sees the other two as peers; ports are static and unused (we
    // route raft via InProcessTransport).  Picked from the 24xxx range so
    // we don't collide with A5 (21xxx), A3d (22xxx), or A3e (23xxx) if the
    // build system ever runs the suites concurrently.
    const port_base: u16 = 24000;
    const ports = [_]u16{ port_base, port_base + 1, port_base + 2 };

    var peer_lists: [3][2]ClusterCoordinator.PeerConfig = undefined;
    inline for (0..3) |i| {
        var pi: usize = 0;
        inline for (0..3) |j| {
            if (i == j) continue;
            peer_lists[i][pi] = .{
                .id = j + 1,
                .address = "127.0.0.1",
                .port = ports[j],
            };
            pi += 1;
        }
    }

    var coords_storage: [3]*ClusterCoordinator = undefined;
    var alive: usize = 0;
    // SONNY-6463: the cleanup of a partial setup is scoped to the setup.
    // It used to be a function-level errdefer beside the `defer` below, so
    // any failed assertion later deinitialized every coordinator twice and
    // the test died with a segfault instead of reporting the assertion.
    {
        errdefer {
            for (coords_storage[0..alive]) |c| {
                c.deinit();
                a.destroy(c);
            }
        }
        for (0..3) |i| {
            const cfg = ClusterCoordinator.Config{
                .peers = peer_lists[i][0..],
                .listen_address = "127.0.0.1",
                .cluster_port = ports[i],
                .cluster_token = "test-show-cluster-status",
                .cluster_name = "test-cluster",
                .election_timeout_ms = 250,
            };
            coords_storage[i] = try a.create(ClusterCoordinator);
            errdefer a.destroy(coords_storage[i]);
            coords_storage[i].* = try ClusterCoordinator.init(a, @intCast(i + 1), cfg);
            alive += 1;
        }
    }
    defer {
        for (coords_storage) |c| {
            c.deinit();
            a.destroy(c);
        }
    }

    const coords: []*ClusterCoordinator = coords_storage[0..];

    // Wire raft over InProcessTransport.
    var ipt = raft_net.RaftNet.init(a);
    defer ipt.deinit();
    for (coords, 1..) |c, id| c.raft.setInnerTransport(ipt.transportFor(id));

    // Drive ticking + message routing until exactly one leader emerges.
    const deadline_ms: i64 = nowMillis() + 10_000;
    while (nowMillis() < deadline_ms) {
        for (coords) |c| {
            try c.raft.tick();
        }

        for (1..@as(u64, @intCast(coords.len + 1))) |id| {
            const msgs = try ipt.drain(@intCast(id), a);
            defer a.free(msgs);
            if (msgs.len == 0) continue;
            const target_idx = id - 1;
            for (msgs) |d| {
                const msg = d.msg;
                const inferred_from = d.from;
                coords[target_idx].raft.stepInner(inferred_from, msg) catch |err| {
                    freeMsgPayload(a, msg);
                    return err;
                };
                freeMsgPayload(a, msg);
            }
        }

        var leader_count: u8 = 0;
        for (coords) |c| {
            if (c.role() == .leader) leader_count += 1;
        }
        if (leader_count == 1) break;

        sleepMs(10);
    }

    // Identify the leader.  We need this to (a) pick which coordinator to
    // install as the global, and (b) compare leader_id values from
    // SHOW CLUSTER STATUS output.
    var leader: ?*ClusterCoordinator = null;
    for (coords) |c| {
        if (c.role() == .leader) {
            leader = c;
            break;
        }
    }
    try std.testing.expect(leader != null);

    // Install the leader as the global ClusterCoordinator and run SHOW
    // CLUSTER STATUS through it.  The handler reads peer info from
    // `coord.cluster_state.nodes` (seeded from PeerConfig at init) plus
    // role/term from the inner raft mirror.
    cluster_mod.setGlobalClusterCoordinator(leader.?);

    const catalog = try execution.ensureCatalogInstance(a);
    defer execution.cleanupCatalogInstance();

    const ctx = execution.ExecutionContext{ .catalog = catalog };
    var res = try admin_ddl.executeShowClusterStatus(a, ctx);
    defer res.deinit(a);

    // Row count = peer_count + 1 = 2 + 1 = 3.
    try std.testing.expectEqual(@as(usize, 3), res.rows.len);
    try std.testing.expectEqual(@as(usize, 6), res.columns.len);

    // Walk the rows and count leaders + collect leader_ids.
    var leader_rows: u8 = 0;
    var first_leader_id: ?i64 = null;
    var leader_id_consistent = true;
    var seen_self_row = false;
    for (res.rows) |row| {
        // node_id is Int, role is Str, term is Int, leader_id is Int,
        // endpoint is Str. last_contact_ms is 0 for this node and NULL for
        // a peer never heard from (SONNY-6463): raft runs over the
        // in-process transport here, so no cluster frame ever arrives.
        try std.testing.expect(row[0] == .Int);
        try std.testing.expect(row[1] == .Str);
        try std.testing.expect(row[2] == .Int);
        try std.testing.expect(row[3] == .Int);
        try std.testing.expect(row[4] == .Str);
        if (row[0].Int == @as(i64, @intCast(leader.?.node_id))) {
            try std.testing.expectEqual(@as(i64, 0), row[5].Int);
        } else {
            try std.testing.expect(row[5] == .Null);
        }

        const role_str = row[1].Str;
        if (std.mem.eql(u8, role_str, "leader")) {
            leader_rows += 1;
        }

        // Verify leader_id is consistent across all rows (every row should
        // agree on who the leader is).
        const this_leader_id = row[3].Int;
        if (first_leader_id) |fl| {
            if (fl != this_leader_id) leader_id_consistent = false;
        } else {
            first_leader_id = this_leader_id;
        }

        // The leader's row in SHOW CLUSTER STATUS should self-identify:
        // node_id == leader_id when role == leader.
        if (std.mem.eql(u8, role_str, "leader")) {
            try std.testing.expectEqual(row[0].Int, row[3].Int);
            seen_self_row = true;
        }
    }
    try std.testing.expectEqual(@as(u8, 1), leader_rows);
    try std.testing.expect(leader_id_consistent);
    try std.testing.expect(seen_self_row);
    try std.testing.expect(first_leader_id != null);
    try std.testing.expect(first_leader_id.? >= 1);
    try std.testing.expect(first_leader_id.? <= 3);

    // term must be >= 1 (a leader must have won an election).
    for (res.rows) |row| {
        try std.testing.expect(row[2].Int >= 1);
    }

    // SONNY-6463: once a peer has been heard from (the cluster's inbound
    // handlers store the frame's time in `last_contact`), its row reports
    // the time since, not NULL.
    const heard = &leader.?.raft.peers[0];
    @atomicStore(i64, &heard.last_contact, nowMillis() - 1500, .monotonic);
    var res2 = try admin_ddl.executeShowClusterStatus(a, ctx);
    defer res2.deinit(a);
    var saw_heard = false;
    for (res2.rows) |row| {
        if (row[0].Int != @as(i64, @intCast(heard.id))) continue;
        saw_heard = true;
        try std.testing.expect(row[5] == .Int);
        try std.testing.expect(row[5].Int >= 1500 and row[5].Int < 60_000);
    }
    try std.testing.expect(saw_heard);

    _ = value_types; // touch the import so unused-import lint is quiet if
    // the file is ever stripped of explicit Value typings.
}

fn freeMsgPayload(allocator: std.mem.Allocator, msg: raft_lib.Message) void {
    // raft v0.2.0: the copy owns each entry's data as well (SONNY-6592).
    raft_net.freeMessage(allocator, msg);
}
