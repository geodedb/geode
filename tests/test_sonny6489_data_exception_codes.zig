// SONNY-6489 item 1: a data exception reaches the client with its ISO/IEC
// 39075:2024 GQLSTATUS (23.1, Table 8, class 22), on QUIC and on gRPC.
//
// Before: `proto_util.mapError` had no arm for these errors, so each fell to
// the generic 58000 (system error), telling the client the SERVER broke when
// its value was bad:
//   - a date, time or datetime string that does not parse (`datetime('x')`)
//     -> 22007 invalid date, time, or datetime format (20.8 GR, the rule a
//        CAST of a character string to a datetime type applies);
//   - a duration string that does not parse (`duration('P1Q')`)
//     -> 22G0H invalid duration format (20.29 GR 1c);
//   - DECIMAL division by zero (`decimal_div(1, 0)`) -> 22012;
//   - a string longer than its CHAR(n) (`char('abcdef', 3)`) -> 22001
//     string data, right truncation (20.8 GR, CAST to a fixed-length string).
//
// gRPC runs in-process (`grpc_impl.handleExecute`); QUIC against the geode
// this build emitted.
//
// CANARY: REQ=REQ-SONNY-6489-DATA-EXCEPTION-CODES; FEATURE="ErrorMapping"; ASPECT=DataExceptionGqlstatus; STATUS=TESTED; TEST=tests/test_sonny6489_data_exception_codes.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const util = @import("proto_test_util.zig");

const graph_store = geode.graph_store;

const Case = struct { query: []const u8, code: []const u8 };

const cases = [_]Case{
    .{ .query = "RETURN datetime('garbage') AS x", .code = "22007" },
    .{ .query = "RETURN date('2024-13-45') AS x", .code = "22007" },
    .{ .query = "RETURN time('nope') AS x", .code = "22007" },
    .{ .query = "RETURN localdatetime('nope') AS x", .code = "22007" },
    .{ .query = "RETURN duration('P1Q') AS x", .code = "22G0H" },
    .{ .query = "RETURN decimal_div(1, 0) AS x", .code = "22012" },
    .{ .query = "RETURN char('abcdef', 3) AS x", .code = "22001" },
};

fn encodeProto(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    return allocator.dupe(u8, aw.written());
}

fn decodeProto(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !T {
    var reader: std.Io.Reader = .fixed(bytes);
    return protobuf.decode(T, &reader, allocator);
}

/// The error code a query answered with over gRPC ("" when it ran).
fn grpcCode(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) ![]const u8 {
    const req = try encodeProto(ga, schema.ExecuteRequest{ .session_id = session_id, .query = query, .params = .empty });
    const resp = try decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
    return switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| e.code,
        else => "",
    };
}

test "SONNY-6489: over gRPC a malformed datetime or duration string, DECIMAL division by zero and CHAR truncation answer their class-22 code" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    _ = graph_store.getGlobalStore(testing.allocator);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ga = arena.allocator();
    var sessions = grpc.SessionStore.init(ga, .{});
    defer sessions.deinit();
    grpc.setSessionStore(&sessions);
    defer grpc.setSessionStore(null);
    const sid = try sessions.createSession("sonny6489", "", .Admin, null, null, false, 0);

    var failures: usize = 0;
    for (cases) |c| {
        const got = try grpcCode(ga, sid, c.query);
        if (!std.mem.eql(u8, got, c.code)) {
            std.debug.print("gRPC {s}: got '{s}', want {s}\n", .{ c.query, got, c.code });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6489: over QUIC a malformed datetime or duration string, DECIMAL division by zero and CHAR truncation answer their class-22 code" {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny6489-codes-{d}", .{port});
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

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    var failures: usize = 0;
    for (cases) |c| {
        var r = try client.executeAndCollect(allocator, c.query, util.emptyParams(), 1000);
        defer r.deinit(allocator);
        const got = r.error_code orelse "";
        if (!std.mem.eql(u8, got, c.code)) {
            std.debug.print("QUIC {s}: got '{s}' ({s}), want {s}\n", .{ c.query, got, r.error_message orelse "", c.code });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
