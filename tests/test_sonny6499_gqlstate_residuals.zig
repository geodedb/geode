// SONNY-6499 item 6: the remaining errors a client's data causes reach it
// with an ISO/IEC 39075:2024 GQLSTATUS (23.1 Table 8), on QUIC and gRPC.
//
// Before, each answered 58000 (system error: "the server broke"):
//   - TypeMismatch, a value of the wrong type for an operation or a
//     function (`1 + 'a'`) -> 22G03 invalid value type; also a CAST whose
//     source type has no conversion to the target (20.8 GR 7 d ii,
//     Table 4 "N": a list to STRING, a BOOLEAN to DOUBLE), which answered
//     22018 -> 22G03;
//   - IndexOutOfBounds, raised only by evaluator_functions.substring for a
//     start before the first character -> 22011 substring error; no GQL
//     query reaches it on this HEAD (substring('abc', 0, 1) answers 'a'),
//     so it has no wire case here;
//   - FloatNaN, a NaN or an infinity stored or given to a function -> 22003
//     numeric value out of range (no GQL number is NaN or infinite);
//   - RangeTooLarge, range() past its 10,000,000-element limit -> 54000
//     program limit exceeded (the class the other size limits use);
//   - RangeBoundsError, intrange() with a lower bound above the upper ->
//     22000 data exception (no subclass names it);
//   - the text of an extension value that does not parse (json, xml, url,
//     domain, uuid, bit, from_hex, subnet) -> 22018 invalid character value
//     for cast; ipaddr and mac answered 22P02 (a PostgreSQL code, not GQL)
//     -> 22018;
//   - a duration string whose component overflows answered 22G0H (invalid
//     duration format) -> 22015 interval field overflow.
//
// gRPC runs in-process (`grpc_impl.handleExecute`); QUIC against the geode
// this build emitted.
//
// CANARY: REQ=REQ-SONNY-6499-GQLSTATE-RESIDUALS; FEATURE="ErrorMapping"; ASPECT=DataExceptionGqlstatusResiduals; STATUS=TESTED; TEST=tests/test_sonny6499_gqlstate_residuals.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const util = @import("proto_test_util.zig");

const graph_store = geode.graph_store;

const Case = struct { query: []const u8, code: []const u8, nan_param: bool = false };

const cases = [_]Case{
    .{ .query = "RETURN 1 + 'a' AS x", .code = "22G03" },
    .{ .query = "RETURN CAST([1, 2] AS STRING) AS x", .code = "22G03" },
    .{ .query = "RETURN CAST(true AS DOUBLE) AS x", .code = "22G03" },
    .{ .query = "CREATE (:Sonny6499Nan {k: $d})", .code = "22003", .nan_param = true },
    .{ .query = "RETURN size(range(0, 100000000)) AS x", .code = "54000" },
    .{ .query = "RETURN intrange(5, 1, true, false) AS x", .code = "22000" },
    .{ .query = "RETURN json('{bad') AS x", .code = "22018" },
    .{ .query = "RETURN xml('<a>') AS x", .code = "22018" },
    .{ .query = "RETURN url('::') AS x", .code = "22018" },
    .{ .query = "RETURN domain('..') AS x", .code = "22018" },
    .{ .query = "RETURN uuid('zz') AS x", .code = "22018" },
    .{ .query = "RETURN bit('102') AS x", .code = "22018" },
    .{ .query = "RETURN from_hex('zz') AS x", .code = "22018" },
    .{ .query = "RETURN subnet('10.0.0.0/99') AS x", .code = "22018" },
    .{ .query = "RETURN ipaddr('300.1.1.1') AS x", .code = "22018" },
    .{ .query = "RETURN duration('P99999999999Y') AS x", .code = "22015" },
    .{ .query = "RETURN duration('P999999999Y') AS x", .code = "22015" },
    // Still 22G0H: not an ISO 8601 duration.
    .{ .query = "RETURN duration('P1Q') AS x", .code = "22G0H" },
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

fn nanParam(allocator: std.mem.Allocator) !schema.Param {
    return .{
        .name = try allocator.dupe(u8, "d"),
        .value = .{ .kind = .{ .double_val = .{ .value = std.math.inf(f64), .kind = .DOUBLE } } },
    };
}

fn params(allocator: std.mem.Allocator, c: Case) !std.ArrayList(schema.Param) {
    var list = util.emptyParams();
    if (c.nan_param) try list.append(allocator, try nanParam(allocator));
    return list;
}

/// The error code a query answered with over gRPC ("" when it ran).
fn grpcCode(ga: std.mem.Allocator, session_id: []const u8, c: Case) ![]const u8 {
    const req = try encodeProto(ga, schema.ExecuteRequest{ .session_id = session_id, .query = c.query, .params = try params(ga, c) });
    const resp = try decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
    return switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| e.code,
        else => "",
    };
}

test "SONNY-6499: over gRPC a data error answers its Table 8 code, not 58000" {
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
    const sid = try sessions.createSession("sonny6499", "", .Admin, null, null, false, 0);

    var failures: usize = 0;
    for (cases) |c| {
        const got = try grpcCode(ga, sid, c);
        if (!std.mem.eql(u8, got, c.code)) {
            std.debug.print("gRPC {s}: got '{s}', want {s}\n", .{ c.query, got, c.code });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6499: over QUIC a data error answers its Table 8 code, not 58000" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny6499-codes-{d}", .{port});
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
        // The client owns (and frees) the parameter list.
        var r = try client.executeAndCollect(allocator, c.query, try params(allocator, c), 1000);
        defer r.deinit(allocator);
        const got = r.error_code orelse "";
        if (!std.mem.eql(u8, got, c.code)) {
            std.debug.print("QUIC {s}: got '{s}' ({s}), want {s}\n", .{ c.query, got, r.error_message orelse "", c.code });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
