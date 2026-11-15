//! SONNY-6561: the CDC surface answers the same on QUIC and gRPC.
//!
//! One real server listens on both transports. For every principal (the
//! admin, a readwrite user, a readonly user, an unauthenticated caller) and
//! every CDC state (never enabled, enabled by `CALL cdc.enable()`, disabled
//! again by `CALL cdc.disable()`), each CDC operation is sent over QUIC and
//! over gRPC and the two answers are compared:
//!
//!   * the CDC_DIAGNOSTICS frame (`.cdc_diag`, gRPC `/CdcDiag`);
//!   * the CDC_CONTROL frame (`.cdc_ctrl`, gRPC `/CdcCtrl`) with the one
//!     documented action (RESET_GUARDRAILS), an unknown action and an empty
//!     one;
//!   * `CALL cdc.*` procedures (src/execution/storage_dispatch.zig
//!     `cdc_table`) that read the engine.
//!
//! The QUIC handler read `ServerState.cdc_engine`, which nothing assigned, so
//! with CDC running QUIC answered NO_ENGINE / "CDC disabled" where gRPC
//! answered from the engine `CALL cdc.enable()` started. A refusal is an
//! SQLSTATE on both transports: 28000 for a caller that is not
//! authenticated, 42501 for one that is not an administrator (QUIC: an error
//! frame; gRPC: a grpc-status trailer whose grpc-message starts with the
//! SQLSTATE).
//!
//! Each RESET_GUARDRAILS is compared as the epoch increment it caused (the two
//! transports reset the same engine, one after the other).
const std = @import("std");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const schema = @import("schema");
const protobuf = @import("protobuf");
const geode = @import("geode");
const util = @import("proto_test_util.zig");

const gq = geode.grpc_query_transport;

const H2_DATA: u8 = 0x0;
const H2_HEADERS: u8 = 0x1;
const H2_RST_STREAM: u8 = 0x3;
const H2_SETTINGS: u8 = 0x4;
const H2_PING: u8 = 0x6;
const H2_GOAWAY: u8 = 0x7;

const rw_user = "rw6561";
const ro_user = "ro6561";
const user_password = "Correct Horse Battery Staple 6561";

const Principal = enum {
    admin,
    readwrite,
    readonly,
    anonymous,

    fn credentials(self: Principal) ?[2][]const u8 {
        return switch (self) {
            .admin => .{ util.defaultUsername(), util.defaultPassword() },
            .readwrite => .{ rw_user, user_password },
            .readonly => .{ ro_user, user_password },
            .anonymous => null,
        };
    }
};

const Server = struct {
    handle: util.ServerHandle,
    quic_addr: []u8,
    grpc_addr: []u8,
    allocator: std.mem.Allocator,

    fn start(a: std.mem.Allocator) !Server {
        const quic_port = try util.getRandomPort();
        var grpc_port = try util.getRandomTcpPort();
        while (grpc_port == quic_port) grpc_port = try util.getRandomTcpPort();
        const quic_addr = try util.formatAddr(a, quic_port);
        errdefer a.free(quic_addr);
        const grpc_addr = try util.formatAddr(a, grpc_port);
        errdefer a.free(grpc_addr);
        var handle = try util.spawnServer(
            a,
            &.{ geode_test_bin.geode_exe, "serve", "--listen", quic_addr, "--listen-grpc", grpc_addr },
            util.TestEnv.grpcPlaintext(),
        );
        errdefer handle.deinit();
        try util.waitForServerReady(a, quic_addr, 15000);
        try util.waitForGrpcServerReady(a, grpc_addr, 15000);
        return .{ .handle = handle, .quic_addr = quic_addr, .grpc_addr = grpc_addr, .allocator = a };
    }

    fn deinit(self: *Server) void {
        self.handle.deinit();
        self.allocator.free(self.quic_addr);
        self.allocator.free(self.grpc_addr);
    }
};

// ---------------------------------------------------------------------------
// Answer formatting: one line per answer, so a mismatch prints both.
// ---------------------------------------------------------------------------

fn fmtDiag(a: std.mem.Allocator, d: schema.CdcDiagnosticsResponse) ![]u8 {
    const cfg = d.config orelse schema.CdcDiagnosticsConfig{};
    const eng = d.engine orelse schema.CdcDiagnosticsEngine{};
    return std.fmt.allocPrint(a, "diag enabled={} running={} epoch={d} attempts={d} malformed={d} batch_size={d} flush_interval_ms={d} buffer={d}", .{
        cfg.enabled,             eng.is_running,             d.guardrail_epoch,
        d.total_change_attempts, d.malformed_change_records, cfg.batch_size,
        cfg.flush_interval_ms,   eng.current_buffer,
    });
}

fn fmtCtrl(a: std.mem.Allocator, r: schema.CdcControlResponse, epoch_before: u64) ![]u8 {
    const delta: i64 = @as(i64, @intCast(r.guardrail_epoch)) - @as(i64, @intCast(epoch_before));
    return std.fmt.allocPrint(a, "ctrl success={} status={s} epoch_delta={d}", .{ r.success, r.status, delta });
}

fn fmtRefused(a: std.mem.Allocator, sqlstate: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "refused {s}", .{sqlstate});
}

fn fmtValue(w: *std.Io.Writer, v: util.TestValue) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .int => |i| try w.print("{d}", .{i}),
        .double => |d| try w.print("{d}", .{d}),
        .bool => |b| try w.print("{}", .{b}),
        .string => |s| try w.print("'{s}'", .{s}),
        else => try w.writeAll("?"),
    }
}

fn fmtExec(a: std.mem.Allocator, r: *const util.ExecResult) ![]u8 {
    if (r.error_code) |code| return fmtRefused(a, code);
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("rows cols=");
    for (r.columns, 0..) |c, i| try w.print("{s}{s}", .{ if (i == 0) "" else ",", c });
    for (r.rows) |row| {
        try w.writeAll(" [");
        for (row, 0..) |cell, i| {
            if (i > 0) try w.writeAll(",");
            try fmtValue(w, cell);
        }
        try w.writeAll("]");
    }
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// QUIC side.
// ---------------------------------------------------------------------------

fn quicConnect(a: std.mem.Allocator, srv: *const Server, who: Principal) !util.QuicProtoClient {
    var c = try util.QuicProtoClient.connect(a, srv.quic_addr);
    errdefer c.deinit();
    if (who.credentials()) |cred| {
        var h = try c.hello(a, cred[0], cred[1]);
        defer h.deinit(a);
        if (!h.success) return error.AuthenticationFailed;
    }
    return c;
}

fn quicReply(a: std.mem.Allocator, c: *util.QuicProtoClient) !schema.ServerPacket {
    return c.readPacketWait(a, .{ .while_server_alive_ms = 10000 });
}

fn quicRefusal(a: std.mem.Allocator, msg: schema.QuicServerMessage) ![]u8 {
    if (msg != .execute) return error.UnexpectedReply;
    const payload = msg.execute.payload orelse return error.UnexpectedReply;
    if (payload != .@"error") return error.UnexpectedReply;
    return fmtRefused(a, payload.@"error".code);
}

fn quicDiag(a: std.mem.Allocator, c: *util.QuicProtoClient) ![]u8 {
    try c.writeMessage(.{ .cdc_diag = .{} });
    var pkt = try quicReply(a, c);
    defer pkt.deinit(a);
    const msg = pkt.quic orelse return error.UnexpectedReply;
    return switch (msg) {
        .cdc_diag => |d| fmtDiag(a, d),
        else => quicRefusal(a, msg),
    };
}

fn quicCtrl(a: std.mem.Allocator, c: *util.QuicProtoClient, action: []const u8, epoch_before: u64) ![]u8 {
    try c.writeMessage(.{ .cdc_ctrl = .{ .action = action } });
    var pkt = try quicReply(a, c);
    defer pkt.deinit(a);
    const msg = pkt.quic orelse return error.UnexpectedReply;
    return switch (msg) {
        .cdc_ctrl => |r| fmtCtrl(a, r, epoch_before),
        else => quicRefusal(a, msg),
    };
}

fn quicCall(a: std.mem.Allocator, srv: *const Server, who: Principal, query: []const u8) ![]u8 {
    var c = try quicConnect(a, srv, who);
    defer c.deinit();
    var r = try c.executeAndCollect(a, query, util.emptyParams(), 100);
    defer r.deinit(a);
    return fmtExec(a, &r);
}

// ---------------------------------------------------------------------------
// gRPC side: unary calls on their own HTTP/2 stream ids, reading the
// grpc-status trailer (`grpc_query_transport.readResponse` discards it).
// ---------------------------------------------------------------------------

const GrpcSession = struct {
    client: util.GrpcProtoClient,
    next_stream_id: u31 = 5,

    fn open(a: std.mem.Allocator, srv: *const Server, who: Principal) !GrpcSession {
        var client = try util.GrpcProtoClient.connect(a, srv.grpc_addr);
        errdefer client.deinit();
        if (who.credentials()) |cred| {
            var h = try client.hello(a, cred[0], cred[1]);
            defer h.deinit(a);
            if (!h.success) return error.AuthenticationFailed;
        }
        return .{ .client = client };
    }

    fn deinit(self: *GrpcSession) void {
        self.client.deinit();
    }

    const Unary = struct {
        message: ?[]u8 = null,
        grpc_status: u8 = 0,
        grpc_message: []u8 = &.{},

        fn deinit(self: *Unary, a: std.mem.Allocator) void {
            if (self.message) |m| a.free(m);
            a.free(self.grpc_message);
        }
    };

    /// The value of a literal (non-Huffman) header field `name` in an HPACK
    /// block, as grpc-zig writes its trailers.
    fn literalHeader(block: []const u8, name: []const u8) ?[]const u8 {
        const at = std.mem.indexOf(u8, block, name) orelse return null;
        const len_at = at + name.len;
        if (len_at >= block.len) return null;
        const len = block[len_at] & 0x7f;
        if (block[len_at] & 0x80 != 0 or len_at + 1 + len > block.len) return null;
        return block[len_at + 1 .. len_at + 1 + len];
    }

    fn call(self: *GrpcSession, a: std.mem.Allocator, path: []const u8, request: []const u8) !Unary {
        const sid = self.next_stream_id;
        self.next_stream_id += 2;
        const stream = self.client.stream;
        try gq.sendRequest(a, stream, path, request, sid);

        var out: Unary = .{};
        errdefer out.deinit(a);
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(a);
        while (true) {
            const frame = try gq.readFrame(a, stream, .{});
            defer a.free(frame.payload);
            const end_stream = frame.flags & 0x1 != 0;
            switch (frame.frame_type) {
                H2_SETTINGS => if (frame.flags & 0x1 == 0) try gq.writeFrame(stream, H2_SETTINGS, 0x1, 0, &.{}),
                H2_PING => if (frame.flags & 0x1 == 0) try gq.writeFrame(stream, H2_PING, 0x1, 0, frame.payload),
                H2_RST_STREAM, H2_GOAWAY => return error.StreamReset,
                H2_DATA => if (frame.stream_id == sid) {
                    try data.appendSlice(a, frame.payload);
                    if (end_stream) break;
                },
                H2_HEADERS => if (frame.stream_id == sid) {
                    if (literalHeader(frame.payload, "grpc-status")) |s| out.grpc_status = try std.fmt.parseUnsigned(u8, s, 10);
                    if (literalHeader(frame.payload, "grpc-message")) |m| {
                        a.free(out.grpc_message);
                        out.grpc_message = try a.dupe(u8, m);
                    }
                    if (end_stream) break;
                },
                else => {},
            }
        }
        if (data.items.len >= 5) {
            const len = std.mem.readInt(u32, data.items[1..5], .big);
            if (data.items.len < 5 + len) return error.TruncatedMessage;
            out.message = try a.dupe(u8, data.items[5 .. 5 + len]);
        }
        return out;
    }

    /// A refusal: a non-zero grpc-status whose message starts with the
    /// SQLSTATE ("42501: ...").
    fn refusal(a: std.mem.Allocator, u: *const Unary) ![]u8 {
        if (u.grpc_message.len < 5) {
            return std.fmt.allocPrint(a, "grpc-status {d} '{s}'", .{ u.grpc_status, u.grpc_message });
        }
        return fmtRefused(a, u.grpc_message[0..5]);
    }

    fn diag(self: *GrpcSession, a: std.mem.Allocator) ![]u8 {
        const req = try gq.encodeMessage(a, schema.CdcDiagnosticsRequest{ .session_id = self.client.session_id });
        defer a.free(req);
        var u = try self.call(a, "/geode.GeodeService/CdcDiag", req);
        defer u.deinit(a);
        if (u.grpc_status != 0) return refusal(a, &u);
        const bytes = u.message orelse return error.EmptyReply;
        var reader: std.Io.Reader = .fixed(bytes);
        var d = try protobuf.decode(schema.CdcDiagnosticsResponse, &reader, a);
        defer d.deinit(a);
        return fmtDiag(a, d);
    }

    fn ctrl(self: *GrpcSession, a: std.mem.Allocator, action: []const u8, epoch_before: u64) ![]u8 {
        const req = try gq.encodeMessage(a, schema.CdcControlRequest{ .action = action, .session_id = self.client.session_id });
        defer a.free(req);
        var u = try self.call(a, "/geode.GeodeService/CdcCtrl", req);
        defer u.deinit(a);
        if (u.grpc_status != 0) return refusal(a, &u);
        const bytes = u.message orelse return error.EmptyReply;
        var reader: std.Io.Reader = .fixed(bytes);
        var r = try protobuf.decode(schema.CdcControlResponse, &reader, a);
        defer r.deinit(a);
        return fmtCtrl(a, r, epoch_before);
    }
};

/// `GrpcProtoClient.executeAndCollect` runs Execute on a fixed stream id, so
/// each statement gets its own connection.
fn grpcCall(a: std.mem.Allocator, srv: *const Server, who: Principal, query: []const u8) ![]u8 {
    var s = try GrpcSession.open(a, srv, who);
    defer s.deinit();
    var r = try s.client.executeAndCollect(a, query, util.emptyParams(), 100);
    defer r.deinit(a);
    return fmtExec(a, &r);
}

// ---------------------------------------------------------------------------
// The comparison.
// ---------------------------------------------------------------------------

const Tally = struct {
    mismatches: usize = 0,
    compared: usize = 0,

    fn check(self: *Tally, a: std.mem.Allocator, state: []const u8, who: Principal, op: []const u8, quic: []u8, grpc: []u8) void {
        defer a.free(quic);
        defer a.free(grpc);
        self.compared += 1;
        const same = std.mem.eql(u8, quic, grpc);
        if (!same) self.mismatches += 1;
        std.debug.print("{s} | {s:<9} | {s:<34} | QUIC: {s}\n{s} | {s:<9} | {s:<34} | gRPC: {s}{s}\n", .{
            state, @tagName(who), op, quic, state, @tagName(who), op, grpc, if (same) "" else "   <-- MISMATCH",
        });
    }
};

/// The engine's guardrail epoch as the admin reads it (0 without an engine).
fn adminEpoch(a: std.mem.Allocator, srv: *const Server) !u64 {
    var c = try quicConnect(a, srv, .admin);
    defer c.deinit();
    try c.writeMessage(.{ .cdc_diag = .{} });
    var pkt = try quicReply(a, &c);
    defer pkt.deinit(a);
    const msg = pkt.quic orelse return error.UnexpectedReply;
    return if (msg == .cdc_diag) msg.cdc_diag.guardrail_epoch else 0;
}

const read_procedures = [_][]const u8{
    "CALL cdc.status()",
    "CALL cdc.export_diagnostics()",
    "CALL cdc.get_guardrail_status()",
    "CALL cdc.get_watermark()",
};

fn compareState(a: std.mem.Allocator, srv: *const Server, state: []const u8, tally: *Tally) !void {
    for ([_]Principal{ .admin, .readwrite, .readonly, .anonymous }) |who| {
        var qc = try quicConnect(a, srv, who);
        defer qc.deinit();
        var gs = try GrpcSession.open(a, srv, who);
        defer gs.deinit();

        tally.check(a, state, who, "CDC_DIAGNOSTICS", try quicDiag(a, &qc), try gs.diag(a));

        for ([_][]const u8{ "RESET_GUARDRAILS", "UNKNOWN_ACTION", "" }) |action| {
            const op = try std.fmt.allocPrint(a, "CDC_CONTROL '{s}'", .{action});
            defer a.free(op);
            const before_q = try adminEpoch(a, srv);
            const q = try quicCtrl(a, &qc, action, before_q);
            const before_g = try adminEpoch(a, srv);
            const g = try gs.ctrl(a, action, before_g);
            tally.check(a, state, who, op, q, g);
        }

        if (who == .anonymous) continue; // CALL needs a session on both transports
        for (read_procedures) |query| {
            tally.check(a, state, who, query, try quicCall(a, srv, who, query), try grpcCall(a, srv, who, query));
        }
    }
}

test "SONNY-6561: the CDC surface answers the same over QUIC and gRPC, CDC off, on and disabled again" {
    const a = testing.allocator;
    var srv = try Server.start(a);
    defer srv.deinit();

    // A readwrite and a readonly user, created by the admin.
    {
        var c = try quicConnect(a, &srv, .admin);
        defer c.deinit();
        const ddl = [_][]const u8{
            "CREATE USER " ++ rw_user ++ " SET PASSWORD '" ++ user_password ++ "'",
            "ALTER USER " ++ rw_user ++ " SET ROLE readwrite",
            "CREATE USER " ++ ro_user ++ " SET PASSWORD '" ++ user_password ++ "'",
            "ALTER USER " ++ ro_user ++ " SET ROLE readonly",
        };
        for (ddl) |q| {
            var r = try c.executeAndCollect(a, q, util.emptyParams(), 100);
            defer r.deinit(a);
            if (r.error_code) |code| {
                std.debug.print("setup `{s}` failed: {s} {s}\n", .{ q, code, r.error_message orelse "" });
                return error.SetupFailed;
            }
        }
    }

    var tally: Tally = .{};

    try compareState(a, &srv, "off     ", &tally);

    // `CALL cdc.enable()` answers the same on both transports (the second
    // call finds the engine running).
    tally.check(a, "enable  ", .admin, "CALL cdc.enable()", try quicCall(a, &srv, .admin, "CALL cdc.enable()"), try grpcCall(a, &srv, .admin, "CALL cdc.enable()"));
    try compareState(a, &srv, "on      ", &tally);

    tally.check(a, "disable ", .admin, "CALL cdc.disable()", try quicCall(a, &srv, .admin, "CALL cdc.disable()"), try grpcCall(a, &srv, .admin, "CALL cdc.disable()"));
    try compareState(a, &srv, "disabled", &tally);

    std.debug.print("SONNY-6561: {d} of {d} CDC answers differ between QUIC and gRPC\n", .{ tally.mismatches, tally.compared });
    try testing.expectEqual(@as(usize, 0), tally.mismatches);
}

test "SONNY-6561: with CDC running, RESET_GUARDRAILS resets the running engine on both transports and refusals are SQLSTATEs" {
    const a = testing.allocator;
    var srv = try Server.start(a);
    defer srv.deinit();

    var qc = try quicConnect(a, &srv, .admin);
    defer qc.deinit();
    var gs = try GrpcSession.open(a, &srv, .admin);
    defer gs.deinit();
    {
        var r = try qc.executeAndCollect(a, "CALL cdc.enable()", util.emptyParams(), 100);
        defer r.deinit(a);
        try testing.expect(r.error_code == null);
    }

    // The engine is running: diagnostics say so on both transports.
    const qd = try quicDiag(a, &qc);
    defer a.free(qd);
    const gd = try gs.diag(a);
    defer a.free(gd);
    try testing.expect(std.mem.startsWith(u8, qd, "diag enabled=true running=true"));
    try testing.expectEqualStrings(gd, qd);

    // Each transport's RESET_GUARDRAILS advances the same engine's epoch by 1.
    const e0 = try adminEpoch(a, &srv);
    const q = try quicCtrl(a, &qc, "RESET_GUARDRAILS", e0);
    defer a.free(q);
    try testing.expectEqualStrings("ctrl success=true status=OK epoch_delta=1", q);
    const g = try gs.ctrl(a, "RESET_GUARDRAILS", e0 + 1);
    defer a.free(g);
    try testing.expectEqualStrings("ctrl success=true status=OK epoch_delta=1", g);
    try testing.expectEqual(e0 + 2, try adminEpoch(a, &srv));

    // An unauthenticated caller is refused 28000 on both transports.
    var anon_q = try quicConnect(a, &srv, .anonymous);
    defer anon_q.deinit();
    var anon_g = try GrpcSession.open(a, &srv, .anonymous);
    defer anon_g.deinit();
    const answers = [_][]u8{
        try quicDiag(a, &anon_q),
        try anon_g.diag(a),
        try quicCtrl(a, &anon_q, "RESET_GUARDRAILS", 0),
        try anon_g.ctrl(a, "RESET_GUARDRAILS", 0),
    };
    defer for (answers) |answer| a.free(answer);
    for (answers) |answer| try testing.expectEqualStrings("refused 28000", answer);
    try testing.expectEqual(e0 + 2, try adminEpoch(a, &srv));
}

test "SONNY-6561: GEODE_CDC_ENABLE=1 starts the CDC engine at startup, as CALL cdc.enable() does" {
    const a = testing.allocator;
    const quic_port = try util.getRandomPort();
    var grpc_port = try util.getRandomTcpPort();
    while (grpc_port == quic_port) grpc_port = try util.getRandomTcpPort();
    var srv: Server = .{
        .quic_addr = try util.formatAddr(a, quic_port),
        .grpc_addr = try util.formatAddr(a, grpc_port),
        .allocator = a,
        .handle = undefined,
    };
    srv.handle = util.spawnServer(
        a,
        &.{ geode_test_bin.geode_exe, "serve", "--listen", srv.quic_addr, "--listen-grpc", srv.grpc_addr },
        &.{ "GEODE_GRPC_ALLOW_PLAINTEXT_FALLBACK=1", "GEODE_QUIC_PASSIVE_TEARDOWN=1", "GEODE_CDC_ENABLE=1" },
    ) catch |err| {
        a.free(srv.quic_addr);
        a.free(srv.grpc_addr);
        return err;
    };
    defer srv.deinit();
    try util.waitForServerReady(a, srv.quic_addr, 15000);
    try util.waitForGrpcServerReady(a, srv.grpc_addr, 15000);

    var qc = try quicConnect(a, &srv, .admin);
    defer qc.deinit();
    var gs = try GrpcSession.open(a, &srv, .admin);
    defer gs.deinit();
    const qd = try quicDiag(a, &qc);
    defer a.free(qd);
    const gd = try gs.diag(a);
    defer a.free(gd);
    try testing.expect(std.mem.startsWith(u8, qd, "diag enabled=true running=true"));
    try testing.expectEqualStrings(qd, gd);
    const status = try quicCall(a, &srv, .admin, "CALL cdc.status()");
    defer a.free(status);
    // SONNY-6570: last_checkpoint (total_events again) is gone.
    try testing.expectEqualStrings("rows cols=enabled,streaming,event_count [true,true,0]", status);
}

test "SONNY-6561: in cluster mode CDC_CONTROL is refused as CALL cdc.reset_guardrails() is" {
    const cluster = geode.distributed.cluster;
    const storage_dispatch = geode.storage_dispatch;
    const a = testing.allocator;

    var coord_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer coord_arena.deinit();
    // A fresh coordinator is a follower (as in test-sonny6321-tde-fle-cases).
    var coord = try cluster.ClusterCoordinator.init(coord_arena.allocator(), 1, .{ .peers = &.{}, .cluster_token = "sonny6561" });
    const saved = cluster.getGlobalClusterCoordinator();
    cluster.setGlobalClusterCoordinator(&coord);
    defer if (saved) |c| cluster.setGlobalClusterCoordinator(c) else cluster.clearGlobalClusterCoordinator();

    for ([_][]const u8{ "RESET_GUARDRAILS", "UNKNOWN_ACTION", "" }) |action| {
        var resp = try storage_dispatch.cdcControlAnswer(a, action, .{});
        defer resp.deinit(a);
        try testing.expect(!resp.success);
        try testing.expectEqualStrings("CLUSTER_NOT_LEADER", resp.status);
    }
    try testing.expectError(error.ClusterNotLeader, cluster.gateUnreplicatedWrite());
}
