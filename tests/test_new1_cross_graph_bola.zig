// NEW-1 (#861): end-to-end regression — a non-Admin user may NOT bind a graph
// for which they hold no GRANT. This is the BOLA reproduction: pre-fix alice
// can bind graph_b even though her only grant is READ ON GRAPH graph_a.
//
// TDD order: RED on the current codebase (BOLA assertion fails because the
//   fail-open RBAC block lets alice bind graph_b pre-fix).
//   Task 2 (register global GraphRBACPolicy) + Task 3 (route QUIC HELLO
//   through gps.decide(.bind_graph)) make every assertion GREEN.

const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

test "QUIC HELLO graph-bind RBAC: non-admin may not bind ungranted graph (cross-graph BOLA)" {
    const allocator = testing.allocator;

    // Persistent data-dir required: user + grant DDL must survive across the
    // admin-setup session and the alice-bind sessions within the same server.
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var data_dir_buf: [80]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&data_dir_buf, "/tmp/geode-new1-bola-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};

    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--data-dir", data_dir },
        util.TestEnv.standard(),
    );
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);

    // Admin setup: create graph_a, graph_b, alice (ReadOnly), grant alice READ
    // on graph_a only. graph_b is intentionally ungranted.
    {
        var admin = try util.QuicProtoClient.connect(allocator, addr);
        defer admin.deinit();
        var ah = try admin.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer ah.deinit(allocator);
        try testing.expect(ah.success);

        var r1 = try admin.executeAndCollect(allocator, "CREATE GRAPH graph_a", util.emptyParams(), 10);
        r1.deinit(allocator);
        var r2 = try admin.executeAndCollect(allocator, "CREATE GRAPH graph_b", util.emptyParams(), 10);
        r2.deinit(allocator);
        var r3 = try admin.executeAndCollect(allocator, "CREATE USER alice SET PASSWORD 'Alice Cross Graph Passphrase' ROLE readonly", util.emptyParams(), 10);
        r3.deinit(allocator);
        var r4 = try admin.executeAndCollect(allocator, "GRANT READ ON GRAPH graph_a TO alice", util.emptyParams(), 10);
        r4.deinit(allocator);
    }

    // BOLA assertion: alice MUST NOT bind graph_b (no grant).
    // PRE-FIX: the bespoke fail-open RBAC block lets alice in, so this
    // assertion FAILS — the test is RED.
    {
        var client = try util.QuicProtoClient.connect(allocator, addr);
        defer client.deinit();
        var h = try client.helloWithGraph(allocator, "alice", "Alice Cross Graph Passphrase", "graph_b");
        defer h.deinit(allocator);
        if (h.success) std.debug.print("BOLA: alice bound graph_b without a grant (pre-fix fail-open)\n", .{});
        try testing.expect(!h.success); // <- RED pre-fix
    }

    // Grant assertion: alice CAN bind graph_a (explicit grant).
    {
        var client = try util.QuicProtoClient.connect(allocator, addr);
        defer client.deinit();
        var h = try client.helloWithGraph(allocator, "alice", "Alice Cross Graph Passphrase", "graph_a");
        defer h.deinit(allocator);
        if (!h.success) std.debug.print("grant assertion: alice denied graph_a unexpectedly: {s}\n", .{h.error_message});
        try testing.expect(h.success);
    }

    // Compatibility: alice can always bind the default graph by name.
    // Any authenticated user must be able to bind "default" (backward compat
    // for single-graph deployments that never issue per-graph grants).
    {
        var client = try util.QuicProtoClient.connect(allocator, addr);
        defer client.deinit();
        var h = try client.helloWithGraph(allocator, "alice", "Alice Cross Graph Passphrase", "default");
        defer h.deinit(allocator);
        if (!h.success) std.debug.print("compat: alice denied default graph: {s}\n", .{h.error_message});
        try testing.expect(h.success);
    }

    // Compatibility: no-graph HELLO (alice gets default; no RBAC check fires
    // because hello_req.graph is null — the check only runs for non-empty names).
    {
        var client = try util.QuicProtoClient.connect(allocator, addr);
        defer client.deinit();
        var h = try client.hello(allocator, "alice", "Alice Cross Graph Passphrase");
        defer h.deinit(allocator);
        try testing.expect(h.success);
    }
}

test "QUIC HELLO race-recovery path: ReadOnly user bind to existing ungranted graph is denied" {
    // NOTE: This test covers the existing-graph deny path. The race-recovery sub-path guard
    // (lines 5904-5915) rests on code-symmetry with this path + the guard added in this commit.
    // The race cannot be triggered deterministically; the guard mirrors the block at
    // line 5827-5872 exactly.
    const allocator = testing.allocator;

    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var data_dir_buf: [80]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&data_dir_buf, "/tmp/geode-new1-race-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};

    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--data-dir", data_dir },
        util.TestEnv.standard(),
    );
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);

    // Admin setup: create graph_a (granted to bob) and graph_c (not granted to bob).
    // bob is ReadOnly — cannot create graphs, so graph_c must be pre-created by admin.
    {
        var admin = try util.QuicProtoClient.connect(allocator, addr);
        defer admin.deinit();
        var ah = try admin.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer ah.deinit(allocator);
        try testing.expect(ah.success);

        var r1 = try admin.executeAndCollect(allocator, "CREATE GRAPH graph_a", util.emptyParams(), 10);
        r1.deinit(allocator);
        var r2 = try admin.executeAndCollect(allocator, "CREATE GRAPH graph_c", util.emptyParams(), 10);
        r2.deinit(allocator);
        var r3 = try admin.executeAndCollect(allocator, "CREATE USER bob SET PASSWORD 'Bobby Cross Graph Passphrase' ROLE readonly", util.emptyParams(), 10);
        r3.deinit(allocator);
        var r4 = try admin.executeAndCollect(allocator, "GRANT READ ON GRAPH graph_a TO bob", util.emptyParams(), 10);
        r4.deinit(allocator);
    }

    // graph_c now exists in the store/catalog. The existing-graph path (line 5827)
    // must deny bob because he holds no grant on graph_c. This is the same gate
    // that the race-recovery guard (lines 5904-5915) mirrors: after the fix, a
    // ReadWrite user who triggers the race-recovery path is subject to the same
    // GPS decision, preventing a silent privilege escalation.
    {
        var client = try util.QuicProtoClient.connect(allocator, addr);
        defer client.deinit();
        var h = try client.helloWithGraph(allocator, "bob", "Bobby Cross Graph Passphrase", "graph_c");
        defer h.deinit(allocator);
        if (h.success) std.debug.print("SECURITY: bob bound graph_c without a grant\n", .{});
        try testing.expect(!h.success); // Access denied — no grant on graph_c
    }

    // Positive: bob can bind graph_a (explicit grant).
    {
        var client = try util.QuicProtoClient.connect(allocator, addr);
        defer client.deinit();
        var h = try client.helloWithGraph(allocator, "bob", "Bobby Cross Graph Passphrase", "graph_a");
        defer h.deinit(allocator);
        if (!h.success) std.debug.print("grant assertion: bob denied graph_a unexpectedly: {s}\n", .{h.error_message});
        try testing.expect(h.success);
    }
}
