// GAP-0514 Phase 6 P1: real end-to-end regression coverage for the
// src/server/quic_connection_handler.zig CANARY hotspot lanes that the
// repl e2e (tests/test_gap0514_repl_dispatch.zig) does not reach:
//
//   - QUIC SAVEPOINT / ROLLBACK TO dispatch (REQ-TXN-SAVEPOINT-004/-005):
//     auth/txn gating + happy lanes through the real message loop.
//   - HELLO graph resolution (REQ-DSN-GRAPH-BIND-003): valid graph
//     auto-create + session bind, oversize and malformed graph names refused.
//   - Graph-RBAC bind authorization (REQ-MULTI-GRAPH-RBAC-WIRE-002):
//     the rbac_allowed check runs on every authenticated graph bind.
//
// Every test spawns this build's geode server (geode_test_bin) and speaks the real
// length-prefixed protobuf protocol over QUIC.  No mocks.
//
// CANARY: REQ=REQ-GAP-0514-QUIC-HANDLER; FEATURE="CanaryReconciliation"; ASPECT=QuicHandlerRegression; STATUS=TESTED; TEST=tests/test_gap0514_quic_handler.zig; OWNER=server; UPDATED=2026-06-11

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

// ---------------------------------------------------------------------------
// REQ-TXN-SAVEPOINT-004 (QuicSavepoint) + REQ-TXN-SAVEPOINT-005 (QuicRollbackTo)
// ---------------------------------------------------------------------------
test "savepoint/rollback_to over QUIC: txn-gated, happy lane, unknown-name refused" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var server = try util.spawnServerRandom(allocator, util.TestEnv.standard());
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();

    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer hello.deinit(allocator);
    try testing.expect(hello.success);

    // Outside a transaction both ops must be refused (the handler's
    // `!state.in_txn` lanes).
    try testing.expect(!(try client.savepoint(allocator, "sp0")));
    try testing.expect(!(try client.rollbackTo(allocator, "sp0")));

    // Happy lane: BEGIN -> SAVEPOINT -> mutate -> ROLLBACK TO -> COMMIT.
    // This drives the QUIC dispatch + session-auth + txn gating around the
    // session's undo log.
    var begin_res = try client.begin(allocator);
    defer begin_res.deinit(allocator);
    try testing.expect(begin_res.tx_id.len > 0);

    try testing.expect(try client.savepoint(allocator, "sp1"));

    var exec = try client.executeAndCollect(allocator, "CREATE (:Gap0514Sp {x: 1})", util.emptyParams(), 10);
    exec.deinit(allocator);

    try testing.expect(try client.rollbackTo(allocator, "sp1"));

    // Unknown savepoint name must be refused while still in the txn.
    try testing.expect(!(try client.rollbackTo(allocator, "no_such_savepoint")));

    try testing.expect(try client.commit(allocator));
}

// ---------------------------------------------------------------------------
// REQ-DSN-GRAPH-BIND-003 (QuicGraphResolution) +
// REQ-MULTI-GRAPH-RBAC-WIRE-002 (QuicGraphAuth)
// ---------------------------------------------------------------------------
test "HELLO graph binding: valid graph binds (RBAC-checked), oversize/malformed names refused" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    // Graph auto-create at HELLO requires the persistent storage adapter
    // (the bind path refuses a graph without a persistent UUID), so this
    // server gets an explicit throwaway --data-dir.
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var data_dir_buf: [64]u8 = undefined;
    // The random port is unique-enough for a throwaway dir name
    // (std.time.milliTimestamp was removed in Zig 0.16).
    const data_dir = try std.fmt.bufPrint(&data_dir_buf, "/tmp/geode-gap0514-quic-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};

    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(
        allocator,
        &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir },
        util.TestEnv.standard(),
    );
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);

    // Valid graph: validated, auto-created, RBAC-checked (auth is enabled in
    // the fixture, so the rbac_allowed block runs), and bound to the session.
    {
        var client = try util.QuicProtoClient.connect(allocator, addr);
        defer client.deinit();
        var hello = try client.helloWithGraph(
            allocator,
            util.defaultUsername(),
            util.defaultPassword(),
            "gap0514_bound",
        );
        defer hello.deinit(allocator);
        if (!hello.success) std.debug.print("graph-bind HELLO refused: {s}\n", .{hello.error_message});
        try testing.expect(hello.success);

        // The bound session must be usable: writes land in the bound graph.
        var create_res = try client.executeAndCollect(allocator, "CREATE (:Gap0514Bind {y: 2})", util.emptyParams(), 10);
        create_res.deinit(allocator);

        var count_res = try client.executeAndCollect(allocator, "MATCH (n:Gap0514Bind) RETURN count(n) AS c", util.emptyParams(), 10);
        defer count_res.deinit(allocator);
        try testing.expect(count_res.error_code == null);
        try testing.expect(count_res.rows.len == 1);
        try testing.expect(count_res.rows[0][0] == .int and count_res.rows[0][0].int == 1);
    }

    // Oversize graph name (>128 chars) must be refused at HELLO.
    {
        var client = try util.QuicProtoClient.connect(allocator, addr);
        defer client.deinit();
        const long_name = "g" ** 129;
        var hello = try client.helloWithGraph(
            allocator,
            util.defaultUsername(),
            util.defaultPassword(),
            long_name,
        );
        defer hello.deinit(allocator);
        try testing.expect(!hello.success);
    }

    // Malformed graph name (illegal characters) must be refused at HELLO.
    {
        var client = try util.QuicProtoClient.connect(allocator, addr);
        defer client.deinit();
        var hello = try client.helloWithGraph(
            allocator,
            util.defaultUsername(),
            util.defaultPassword(),
            "bad;name--",
        );
        defer hello.deinit(allocator);
        try testing.expect(!hello.success);
    }
}
