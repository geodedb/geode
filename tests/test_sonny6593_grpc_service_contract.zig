// CANARY: REQ=REQ-SONNY-6593-GRPC-SERVICE-CONTRACT; FEATURE="GrpcTransport"; ASPECT=ServedEqualsDeclared; STATUS=TESTED; TEST=tests/test_sonny6593_grpc_service_contract.zig; OWNER=transport; UPDATED=2026-11-15
//
// SONNY-6593 item 2: geode's gRPC server served RPCs that the published
// contract, src/proto/geode.proto (the clients ship it and generate their
// stubs from it), does not declare: Savepoint, RollbackTo, Backup, Restore
// and UploadBackup, and the CDC aliases CdcDiag and CdcCtrl. A client
// generated from the .proto could not call the first five, and nothing
// documented the last two.
//
// The contract: the RPCs `geode serve --listen-grpc` answers are exactly
// the RPCs geode.proto's `service GeodeService` declares. A declared RPC
// is served (it does not answer grpc-status 12, UNIMPLEMENTED); any other
// name under /geode.GeodeService/ answers UNIMPLEMENTED.
//
// A real `geode serve` with a plaintext gRPC listener. Each probe is an
// empty request (every field at its default) on its own connection with no
// HELLO: the handler is reached and refuses or answers it; only an
// unrouted path is UNIMPLEMENTED.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const options = @import("sonny6593_options");
const util = @import("proto_test_util.zig");

const gq = geode.grpc_query_transport;

const H2_DATA: u8 = 0x0;
const H2_HEADERS: u8 = 0x1;
const H2_RST_STREAM: u8 = 0x3;
const H2_SETTINGS: u8 = 0x4;
const H2_PING: u8 = 0x6;
const H2_GOAWAY: u8 = 0x7;

const grpc_unimplemented: u8 = 12;
const service_prefix = "/geode.GeodeService/";

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn readRepoFile(a: std.mem.Allocator, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(a, &.{ options.repo_root, rel });
    defer a.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(fsIo(), abs, a, .limited(16 << 20));
}

/// The RPC names `service GeodeService { ... }` declares in `proto`.
/// Slices of `proto`.
fn declaredRpcs(a: std.mem.Allocator, proto: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(a);
    const open = "service GeodeService {";
    const start = (std.mem.indexOf(u8, proto, open) orelse return error.NoServiceBlock) + open.len;
    const len = std.mem.indexOfScalar(u8, proto[start..], '}') orelse return error.NoServiceBlock;
    var lines = std.mem.splitScalar(u8, proto[start .. start + len], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "rpc ")) continue;
        const rest = std.mem.trimStart(u8, line[4..], " ");
        const paren = std.mem.indexOfScalar(u8, rest, '(') orelse return error.MalformedRpc;
        try out.append(a, std.mem.trim(u8, rest[0..paren], " "));
    }
    if (out.items.len == 0) return error.NoRpcs;
    return out;
}

/// Every method name geode's gRPC server has routed (grpc_server.zig's
/// registered paths and `handlePacket`'s suffix dispatch, past and
/// present), and one it never has.
const candidate_names = [_][]const u8{
    "Handshake", "Execute",   "Ping",             "Begin",             "Commit",
    "Rollback",  "Savepoint", "RollbackTo",       "GetCdcDiagnostics", "ControlCdc",
    "CdcDiag",   "CdcCtrl",   "Backup",           "Restore",           "UploadBackup",
    "Pull",      "Cancel",    "NoSuchMethod6593",
};

fn literalHeader(block: []const u8, name: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, block, name) orelse return null;
    const len_at = at + name.len;
    if (len_at >= block.len) return null;
    const len = block[len_at] & 0x7f;
    if (block[len_at] & 0x80 != 0 or len_at + 1 + len > block.len) return null;
    return block[len_at + 1 .. len_at + 1 + len];
}

/// The grpc-status of an empty request to `path`, on a fresh connection.
fn probe(a: std.mem.Allocator, grpc_addr: []const u8, path: []const u8) !u8 {
    var client = try util.GrpcProtoClient.connect(a, grpc_addr);
    defer client.deinit();
    const stream = client.stream;
    const sid: u31 = 1;
    try gq.sendRequest(a, stream, path, "", sid);
    var status: ?u8 = null;
    while (true) {
        const frame = try gq.readFrame(a, stream, .{});
        defer a.free(frame.payload);
        const end_stream = frame.flags & 0x1 != 0;
        switch (frame.frame_type) {
            H2_SETTINGS => if (frame.flags & 0x1 == 0) try gq.writeFrame(stream, H2_SETTINGS, 0x1, 0, &.{}),
            H2_PING => if (frame.flags & 0x1 == 0) try gq.writeFrame(stream, H2_PING, 0x1, 0, frame.payload),
            H2_RST_STREAM, H2_GOAWAY => return error.StreamReset,
            H2_DATA => if (frame.stream_id == sid and end_stream) break,
            H2_HEADERS => if (frame.stream_id == sid) {
                if (literalHeader(frame.payload, "grpc-status")) |s| status = try std.fmt.parseUnsigned(u8, s, 10);
                if (end_stream) break;
            },
            else => {},
        }
    }
    return status orelse 0;
}

fn isDeclared(declared: []const []const u8, name: []const u8) bool {
    for (declared) |d| {
        if (std.mem.eql(u8, d, name)) return true;
    }
    return false;
}

test "SONNY-6593 (2): geode serve answers exactly the gRPC RPCs geode.proto declares" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // SONNY-6782: plaintext gRPC is served in Debug only.
    if (!util.grpc_plaintext_served) return error.SkipZigTest;
    const a = testing.allocator;

    const proto = try readRepoFile(a, "src/proto/geode.proto");
    defer a.free(proto);
    var declared = try declaredRpcs(a, proto);
    defer declared.deinit(a);

    // Every declared RPC is probed, and every name the server has routed.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);
    try names.appendSlice(a, declared.items);
    for (candidate_names) |c| {
        if (!isDeclared(declared.items, c)) try names.append(a, c);
    }

    const quic_port = try util.getRandomPort();
    var grpc_port = try util.getRandomTcpPort();
    while (grpc_port == quic_port) grpc_port = try util.getRandomTcpPort();
    const quic_addr = try util.formatAddr(a, quic_port);
    defer a.free(quic_addr);
    const grpc_addr = try util.formatAddr(a, grpc_port);
    defer a.free(grpc_addr);
    var server = try util.spawnServer(a, &.{ geode_test_bin.geode_exe, "serve", "--listen", quic_addr, "--listen-grpc", grpc_addr }, util.TestEnv.grpcPlaintext());
    defer server.deinit();
    try util.waitForServerReady(a, quic_addr, 15000);
    try util.waitForGrpcServerReady(a, grpc_addr, 15000);

    var wrong: usize = 0;
    for (names.items) |name| {
        const path = try std.mem.concat(a, u8, &.{ service_prefix, name });
        defer a.free(path);
        const status = probe(a, grpc_addr, path) catch |err| {
            std.debug.print("SONNY-6593: {s}: {s}\n", .{ path, @errorName(err) });
            wrong += 1;
            continue;
        };
        const served = status != grpc_unimplemented;
        const want = isDeclared(declared.items, name);
        if (served != want) {
            std.debug.print("SONNY-6593: {s} is {s} by geode.proto but {s} (grpc-status {d})\n", .{
                path,
                if (want) "declared" else "not declared",
                if (served) "served" else "UNIMPLEMENTED",
                status,
            });
            wrong += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}

test "SONNY-6593 (2): the paths the gRPC server registers are geode.proto's RPCs" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // `GeodeGrpcServer.registerHandlers` registers
    // `grpc_service_methods.paths` and nothing else, so this list is what
    // the server serves; the probe above checks it against a running one.
    const a = testing.allocator;
    const methods = geode.grpc_service_methods;
    const proto = try readRepoFile(a, "src/proto/geode.proto");
    defer a.free(proto);
    var declared = try declaredRpcs(a, proto);
    defer declared.deinit(a);

    var wrong: usize = 0;
    for (declared.items) |d| {
        if (!isDeclared(&methods.names, d)) {
            std.debug.print("SONNY-6593: geode.proto declares {s}; the server does not register it\n", .{d});
            wrong += 1;
        }
    }
    for (methods.names) |n| {
        if (!isDeclared(declared.items, n)) {
            std.debug.print("SONNY-6593: the server registers {s}; geode.proto does not declare it\n", .{n});
            wrong += 1;
        }
    }
    try testing.expectEqual(declared.items.len, methods.names.len);
    for (methods.names, methods.paths) |n, p| {
        const want = try std.mem.concat(a, u8, &.{ service_prefix, n });
        defer a.free(want);
        try testing.expectEqualStrings(want, p);
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}
