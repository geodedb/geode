//! SONNY-6587 item 2 (a): a PROFILE of a point write served by the exact-index
//! seek (`match_operations.pointWriteFastPath`) names the catalog index it
//! seeked, on QUIC and gRPC.
//!
//! `MATCH (n:L) WHERE n.k = 'v' SET ...` on a persisted graph is answered by
//! pointWriteFastPath: an exact-property seek, then the write. Its PROFILE is
//! the version-1 payload (a data change), which reported no index: the
//! transports had no way to learn the seek (SONNY-1335 left
//! `ProfileOptions.index_name` unset for every version-1 caller). As the
//! version-2 trace does (SONNY-1335, `recordStartAccess`), the seek is
//! reported as `NodeIndexScan`, named after the catalog btree or hash index
//! on the label and key, with the nodes it returned, only when such an index
//! exists; an equality the internal exact-property lookup answers without a
//! declared index reports no index.
//!
//! CANARY: REQ=REQ-SONNY-6587-PROFILE-POINT-WRITE-SEEK; FEATURE="PROFILE"; ASPECT=PointWriteIndexName; STATUS=TESTED; TEST=tests/test_sonny6587_profile_point_write_seek.zig; OWNER=engine; UPDATED=2026-11-15

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const geode = @import("geode");
const util = @import("proto_test_util.zig");
const grpc_query_transport = geode.grpc_query_transport;
const query_runner = geode.query_runner;

/// The `index_name` of each NodeIndexScan op and its rows, in `json`.
const Seek = struct { count: usize = 0, name: []const u8 = "", rows: i64 = -1 };

fn seekOf(a: std.mem.Allocator, json: []const u8) !Seek {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    var out: Seek = .{};
    for (parsed.value.object.get("ops").?.array.items) |op| {
        if (!std.mem.eql(u8, op.object.get("op").?.string, "NodeIndexScan")) continue;
        out.count += 1;
        out.name = try a.dupe(u8, op.object.get("index_name").?.string);
        out.rows = op.object.get("rows").?.integer;
    }
    return out;
}

fn quicRun(a: std.mem.Allocator, quic: *util.QuicProtoClient, q: []const u8) !void {
    var r = try quic.executeAndCollect(a, q, util.emptyParams(), 100);
    defer r.deinit(a);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ q, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
}

fn grpcProfile(a: std.mem.Allocator, grpc_addr: []const u8, q: []const u8) ![]u8 {
    var grpc = try util.GrpcProtoClient.connect(a, grpc_addr);
    defer grpc.deinit();
    var hg = try grpc.hello(a, util.defaultUsername(), util.defaultPassword());
    hg.deinit(a);
    var adapter = grpc_query_transport.StreamingQueryAdapter{ .stream = grpc.stream, .stream_ids = &grpc.stream_ids };
    var transport = adapter.asTransport();
    var result = try query_runner.collectQueryWithTransport(a, &transport, .{
        .session_id = grpc.session_id,
        .query_text = q,
        .format = "json",
        .timeout_secs = 10,
        .page_size = 100,
        .params = util.emptyParams(),
    });
    defer result.deinit();
    if (result.has_error) {
        std.debug.print("{s} [grpc]: {s} {s}\n", .{ q, result.error_status, result.error_message });
        return error.QueryFailed;
    }
    return a.dupe(u8, result.result_payload orelse return error.MissingProfile);
}

test "SONNY-6587: a PROFILE'd point write names the catalog index its seek used (QUIC and gRPC)" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    const quic_port = try util.getRandomPort();
    var grpc_port = try util.getRandomTcpPort();
    while (grpc_port == quic_port) grpc_port = try util.getRandomTcpPort();
    const quic_addr = try util.formatAddr(a, quic_port);
    defer a.free(quic_addr);
    const grpc_addr = try util.formatAddr(a, grpc_port);
    defer a.free(grpc_addr);

    var handle = try util.spawnServer(a, &.{ geode_test_bin.geode_exe, "serve", "--listen", quic_addr, "--listen-grpc", grpc_addr }, util.TestEnv.grpcPlaintext());
    defer handle.deinit();
    try util.waitForServerReady(a, quic_addr, 10000);

    var quic = try util.QuicProtoClient.connect(a, quic_addr);
    defer quic.deinit();
    var hq = try quic.hello(a, util.defaultUsername(), util.defaultPassword());
    hq.deinit(a);

    try quicRun(a, &quic, "CREATE (:PW6587 {k: 'a'}), (:PW6587 {k: 'b'}), (:PN6587 {k: 'a'})");
    try quicRun(a, &quic, "CREATE INDEX pw6587_k FOR (n:PW6587) ON (n.k)");

    var failures: usize = 0;
    const Want = struct { q: []const u8, name: ?[]const u8, rows: i64 };
    const wants = [_]Want{
        // A seek that matched, and the authoritative empty one.
        .{ .q = "PROFILE MATCH (n:PW6587) WHERE n.k = 'a' SET n.v = 1", .name = "pw6587_k", .rows = 1 },
        .{ .q = "PROFILE MATCH (n:PW6587) WHERE n.k = 'zz' SET n.v = 1", .name = "pw6587_k", .rows = 0 },
        // No catalog index on the label: no index is claimed.
        .{ .q = "PROFILE MATCH (n:PN6587) WHERE n.k = 'a' SET n.v = 1", .name = null, .rows = 0 },
    };
    for (wants) |w| {
        for ([_][]const u8{ "quic", "grpc" }) |t| {
            const json = if (std.mem.eql(u8, t, "quic")) try quic.executeProfileJson(a, w.q) else try grpcProfile(a, grpc_addr, w.q);
            defer a.free(json);
            const seek = try seekOf(a, json);
            defer if (seek.name.len > 0) a.free(seek.name);
            const ok = if (w.name) |name|
                seek.count == 1 and std.mem.eql(u8, seek.name, name) and seek.rows == w.rows
            else
                seek.count == 0;
            if (!ok) {
                std.debug.print("{s} [{s}]: want index {s} rows {d}, got {d} index op(s) \"{s}\" rows {d}\n  {s}\n", .{ w.q, t, w.name orelse "(none)", w.rows, seek.count, seek.name, seek.rows, json });
                failures += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
