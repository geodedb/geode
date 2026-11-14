// SONNY-6567 (1): every RPC on one gRPC connection rides its own HTTP/2
// stream.
//
// HTTP/2 (RFC 9113 §5.1.1): a client opens streams with odd ids that only
// increase, and never reuses one. The client transport
// (`src/client/grpc_query_transport.zig`) sent the handshake on stream 1 and
// EVERY Execute on stream 3 (`execute_stream_id`), so the second Execute on
// a connection reused a closed stream: the server refused it and the client
// saw the stream end with no answer (`IncompleteResponse`). The CLI opens a
// connection per Execute and was not hit; every other user of the transport
// (the public `StreamingQueryAdapter`, the test client `GrpcProtoClient`,
// which callers worked around by reconnecting per statement) was.
//
// Against a real `geode serve` with a plaintext gRPC listener, one
// connection runs: a HELLO, eight Execute RPCs back to back, a response
// large enough (well over the 65,535-byte connection flow-control window)
// to need WINDOW_UPDATEs on a late stream, then another Execute after it.
// Every answer must be right. The CLI's multi-statement `--file` over gRPC
// must also succeed, and the stream-id allocator must refuse to wrap.
//
// CANARY: REQ=REQ-SONNY-6567-GRPC-STREAM-IDS; FEATURE="GrpcTransport"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6567_grpc_stream_ids.zig; OWNER=transport; UPDATED=2026-11-14

const std = @import("std");
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const SEQUENTIAL: usize = 8;
const BIG_ROWS: usize = 4000;
const PAD_LEN: usize = 200;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Server = struct {
    handle: util.ServerHandle,
    quic_addr: []u8,
    grpc_addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8, log_path: []const u8) !Server {
        const quic_port = try util.getRandomPort();
        var grpc_port = try util.getRandomTcpPort();
        while (grpc_port == quic_port) grpc_port = try util.getRandomTcpPort();
        const quic_addr = try util.formatAddr(allocator, quic_port);
        errdefer allocator.free(quic_addr);
        const grpc_addr = try util.formatAddr(allocator, grpc_port);
        errdefer allocator.free(grpc_addr);
        const cmd = try std.fmt.allocPrint(allocator, "exec '{s}' serve --listen {s} --listen-grpc {s} --data-dir '{s}' 2>>'{s}'", .{ geode_test_bin.geode_exe, quic_addr, grpc_addr, data_dir, log_path });
        defer allocator.free(cmd);
        var handle = try util.spawnServer(allocator, &.{ "/bin/sh", "-c", cmd, "--data-dir" }, util.TestEnv.grpcPlaintext());
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, quic_addr, 30000);
        return .{ .handle = handle, .quic_addr = quic_addr, .grpc_addr = grpc_addr };
    }

    fn stop(self: *Server, allocator: std.mem.Allocator) void {
        self.handle.deinit();
        allocator.free(self.quic_addr);
        allocator.free(self.grpc_addr);
    }
};

/// Run `q` on `client`; null when the RPC itself failed (the error printed).
fn execute(client: *util.GrpcProtoClient, allocator: std.mem.Allocator, what: []const u8, q: []const u8) ?util.ExecResult {
    const r = client.executeAndCollect(allocator, q, util.emptyParams(), 1000) catch |err| {
        std.debug.print("SONNY-6567 (1) {s}: the RPC failed: {s}\n", .{ what, @errorName(err) });
        return null;
    };
    if (r.error_code) |c| std.debug.print("SONNY-6567 (1) {s}: {s} {s}\n", .{ what, c, r.error_message orelse "" });
    return r;
}

test "SONNY-6567 (1): N Execute RPCs and a large response on one gRPC connection" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(dir);
    const data_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{dir});
    defer allocator.free(data_dir);
    const log_path = try std.fmt.allocPrint(allocator, "{s}/server.log", .{dir});
    defer allocator.free(log_path);

    var server = try Server.start(allocator, data_dir, log_path);
    defer server.stop(allocator);

    var client = try util.GrpcProtoClient.connect(allocator, server.grpc_addr);
    defer client.deinit();
    {
        var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(allocator);
        try testing.expect(h.success);
    }

    var failures: usize = 0;
    for (0..SEQUENTIAL) |i| {
        var qbuf: [64]u8 = undefined;
        const q = try std.fmt.bufPrint(&qbuf, "RETURN {d} AS x", .{i});
        var what_buf: [64]u8 = undefined;
        const what = try std.fmt.bufPrint(&what_buf, "Execute #{d}", .{i + 1});
        var r = execute(&client, allocator, what, q) orelse {
            failures += 1;
            continue;
        };
        defer r.deinit(allocator);
        const right = r.error_code == null and r.rows.len == 1 and r.rows[0].len == 1 and
            r.rows[0][0] == .int and r.rows[0][0].int == @as(i64, @intCast(i));
        if (!right) failures += 1;
    }
    std.debug.print("SONNY-6567 (1) {d} sequential Execute RPCs on one connection, {d} failed\n", .{ SEQUENTIAL, failures });

    // A large response on a late stream: well over the connection-level
    // window, so the client's WINDOW_UPDATEs must reach the server on it.
    const big_q = try std.fmt.allocPrint(allocator, "UNWIND range(1, {d}) AS i RETURN i, '{s}' AS pad", .{ BIG_ROWS, "p" ** PAD_LEN });
    defer allocator.free(big_q);
    if (execute(&client, allocator, "large response", big_q)) |r_const| {
        var r = r_const;
        defer r.deinit(allocator);
        std.debug.print("SONNY-6567 (1) large response: {d} rows (want {d})\n", .{ r.rows.len, BIG_ROWS });
        if (r.error_code != null or r.rows.len != BIG_ROWS) failures += 1;
    } else failures += 1;

    if (execute(&client, allocator, "Execute after the large response", "RETURN 'after' AS s")) |r_const| {
        var r = r_const;
        defer r.deinit(allocator);
        const right = r.error_code == null and r.rows.len == 1 and r.rows[0][0] == .string and
            std.mem.eql(u8, r.rows[0][0].string, "after");
        if (!right) failures += 1;
    } else failures += 1;

    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6567 (1): a multi-statement --file runs over gRPC" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(dir);
    const data_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{dir});
    defer allocator.free(data_dir);
    const log_path = try std.fmt.allocPrint(allocator, "{s}/server.log", .{dir});
    defer allocator.free(log_path);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/program.gql", .{dir});
    defer allocator.free(file_path);
    try std.Io.Dir.cwd().writeFile(io(), .{
        .sub_path = file_path,
        .data = "CREATE (:F6567 {k: 1});\nCREATE (:F6567 {k: 2});\nCREATE (:F6567 {k: 3});\nMATCH (n:F6567) RETURN count(n) AS c;\n",
    });

    var server = try Server.start(allocator, data_dir, log_path);
    defer server.stop(allocator);

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const r = try std.process.run(allocator, threaded.io(), .{ .argv = &.{
        geode_test_bin.geode_exe, "query",          "--grpc",
        "--server",               server.grpc_addr, "-U",
        util.defaultUsername(),   "-P",             util.defaultPassword(),
        "--format",               "json",           "--file",
        file_path,
    } });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    const code: u8 = switch (r.term) {
        .exited => |c| c,
        else => 255,
    };
    std.debug.print("SONNY-6567 (1) --file over gRPC exited {d}\nstdout: {s}\nstderr: {s}\n", .{ code, r.stdout, r.stderr });
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "\"c\":3") != null);
}
