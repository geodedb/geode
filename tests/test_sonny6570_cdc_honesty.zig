//! SONNY-6570: the CDC surface answers truthfully, to administrators only,
//! audits every change, and is reachable under the names the .proto
//! publishes.
//!
//! Change capture is not implemented (SONNY-6572): no write path feeds the
//! CDC engine, so no change is ever captured. The `CALL cdc.*` procedures
//! (src/execution/storage_dispatch.zig `cdc_table`) answered as if it were:
//! `cdc.get_events` returned one invented event, other readers fixed rows or
//! fixed numbers, and `pause`, `resume`, `set_guardrail`, `configure_*`,
//! `set_retention_policy` and `cleanup_expired_events` changed nothing and
//! reported success. Every procedure now either answers from the running
//! engine (compared here with the engine's own CDC_DIAGNOSTICS answer) or
//! is refused with SQLSTATE 0A000 and a message naming it and SONNY-6572;
//! `start`, `stop` and `reset_guardrails` with no engine are refused 55000
//! instead of reporting a reset or a start that did not happen.
//!
//! A readwrite or readonly user could read `cdc.status()` /
//! `cdc.export_diagnostics()` (the counters the admin-only CDC_DIAGNOSTICS
//! frame refuses them, 42501) and run `cdc.enable()` / `cdc.disable()`
//! (which the admin-only CDC_CONTROL frame refuses). Every `cdc.*` procedure
//! is now Admin only, like the frames, on QUIC and gRPC.
//!
//! No CDC frame or procedure wrote an audit record; the changes and their
//! refusals now do, and the audit chain still verifies.
//!
//! src/proto/geode.proto (the published gRPC contract, shipped by the
//! clients) declares GetCdcDiagnostics and ControlCdc; the server served
//! only /CdcDiag and /CdcCtrl, so a client generated from the .proto got
//! UNIMPLEMENTED.
//!
//! `cdc_enhanced.startCDC` leaked the engine when `start()` failed.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const schema = @import("schema");
const protobuf = @import("protobuf");
const geode = @import("geode");
const util = @import("proto_test_util.zig");
const test_scratch = @import("test_scratch.zig");

const gq = geode.grpc_query_transport;
const cdc = geode.streaming.cdc_enhanced;
const linux = std.os.linux;

const H2_DATA: u8 = 0x0;
const H2_HEADERS: u8 = 0x1;
const H2_RST_STREAM: u8 = 0x3;
const H2_SETTINGS: u8 = 0x4;
const H2_PING: u8 = 0x6;
const H2_GOAWAY: u8 = 0x7;

const rw_user = "rw6570";
const ro_user = "ro6570";
const plain_user = "us6570";
const user_password = "Correct Horse Battery Staple 6570";

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Principal = enum {
    admin,
    readwrite,
    readonly,
    user,
    anonymous,

    fn credentials(self: Principal) ?[2][]const u8 {
        return switch (self) {
            .admin => .{ util.defaultUsername(), util.defaultPassword() },
            .readwrite => .{ rw_user, user_password },
            .readonly => .{ ro_user, user_password },
            .user => .{ plain_user, user_password },
            .anonymous => null,
        };
    }
};

const Transport = enum { quic, grpc };

/// Every `cdc.*` procedure the server dispatches (storage_dispatch
/// `cdc_table`).
const all_procedures = [_][]const u8{
    "cdc.enable",                   "cdc.disable",                 "cdc.status",
    "cdc.export_diagnostics",       "cdc.get_events",              "cdc.pause",
    "cdc.resume",                   "cdc.set_guardrail",           "cdc.get_guardrail_status",
    "cdc.reset_guardrails",         "cdc.get_watermark",           "cdc.get_pending_events",
    "cdc.configure_adaptive_flush", "cdc.get_flush_metrics",       "cdc.get_malformed_records",
    "cdc.get_corruption_analysis",  "cdc.get_ordered_events",      "cdc.check_duplicates",
    "cdc.get_change_status",        "cdc.configure_change_stream", "cdc.set_retention_policy",
    "cdc.cleanup_expired_events",   "cdc.get_telemetry_metrics",   "cdc.get_performance_alerts",
    "cdc.stop",                     "cdc.start",
};

/// The procedures that cannot answer truthfully while change capture is not
/// implemented: they report captured events, rates and latencies the engine
/// does not have, or configure what the engine does not use.
const refused_procedures = [_][]const u8{
    "cdc.get_events",               "cdc.pause",                   "cdc.resume",
    "cdc.set_guardrail",            "cdc.get_watermark",           "cdc.get_pending_events",
    "cdc.configure_adaptive_flush", "cdc.get_flush_metrics",       "cdc.get_malformed_records",
    "cdc.get_corruption_analysis",  "cdc.get_ordered_events",      "cdc.check_duplicates",
    "cdc.get_change_status",        "cdc.configure_change_stream", "cdc.set_retention_policy",
    "cdc.cleanup_expired_events",   "cdc.get_telemetry_metrics",   "cdc.get_performance_alerts",
};

/// A call with arguments the procedure accepts (set_guardrail validated
/// two; the others take none).
fn callText(buf: []u8, proc: []const u8) ![]const u8 {
    if (std.mem.eql(u8, proc, "cdc.set_guardrail")) return std.fmt.bufPrint(buf, "CALL {s}('warn_threshold', 10)", .{proc});
    return std.fmt.bufPrint(buf, "CALL {s}()", .{proc});
}

const Server = struct {
    handle: util.ServerHandle,
    quic_addr: []u8,
    grpc_addr: []u8,
    allocator: std.mem.Allocator,

    fn start(a: std.mem.Allocator, extra_args: []const []const u8, extra_env: []const []const u8) !Server {
        const quic_port = try util.getRandomPort();
        var grpc_port = try util.getRandomTcpPort();
        while (grpc_port == quic_port) grpc_port = try util.getRandomTcpPort();
        const quic_addr = try util.formatAddr(a, quic_port);
        errdefer a.free(quic_addr);
        const grpc_addr = try util.formatAddr(a, grpc_port);
        errdefer a.free(grpc_addr);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(a);
        try argv.appendSlice(a, &.{ geode_test_bin.geode_exe, "serve", "--listen", quic_addr, "--listen-grpc", grpc_addr });
        try argv.appendSlice(a, extra_args);
        var env: std.ArrayList([]const u8) = .empty;
        defer env.deinit(a);
        try env.appendSlice(a, util.TestEnv.grpcPlaintext());
        try env.appendSlice(a, extra_env);
        var handle = try util.spawnServer(a, argv.items, env.items);
        errdefer handle.deinit();
        try util.waitForServerReady(a, quic_addr, 15000);
        try util.waitForGrpcServerReady(a, grpc_addr, 15000);
        return .{ .handle = handle, .quic_addr = quic_addr, .grpc_addr = grpc_addr, .allocator = a };
    }

    /// SIGTERM, then wait (without reaping) for the server to exit, so it
    /// closes its audit log.
    fn terminate(self: *Server) void {
        const pid = self.handle.child.id orelse return;
        std.posix.kill(pid, .TERM) catch return;
        var waited: u32 = 0;
        while (util.processAlive(pid) and waited < 300) : (waited += 1) {
            fsIo().sleep(.fromNanoseconds(100 * std.time.ns_per_ms), .awake) catch {};
        }
    }

    fn deinit(self: *Server) void {
        self.handle.deinit();
        self.allocator.free(self.quic_addr);
        self.allocator.free(self.grpc_addr);
    }
};

fn createUsers(a: std.mem.Allocator, srv: *const Server) !void {
    var c = try quicConnect(a, srv, .admin);
    defer c.deinit();
    const ddl = [_][]const u8{
        "CREATE USER " ++ rw_user ++ " SET PASSWORD '" ++ user_password ++ "'",
        "ALTER USER " ++ rw_user ++ " SET ROLE readwrite",
        "CREATE USER " ++ ro_user ++ " SET PASSWORD '" ++ user_password ++ "'",
        "ALTER USER " ++ ro_user ++ " SET ROLE readonly",
        "CREATE USER " ++ plain_user ++ " SET PASSWORD '" ++ user_password ++ "'",
        "ALTER USER " ++ plain_user ++ " SET ROLE user",
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

// ---------------------------------------------------------------------------
// QUIC.
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

/// A frame's answer: the decoded reply, or the SQLSTATE it was refused with.
fn FrameAnswer(comptime T: type) type {
    return union(enum) {
        answer: T,
        refused: [5]u8,

        fn deinit(self: *@This(), a: std.mem.Allocator) void {
            if (self.* == .answer) self.answer.deinit(a);
        }
    };
}
const DiagAnswer = FrameAnswer(schema.CdcDiagnosticsResponse);
const CtrlAnswer = FrameAnswer(schema.CdcControlResponse);

fn sqlstate5(code: []const u8) [5]u8 {
    var out: [5]u8 = "?????".*;
    @memcpy(out[0..@min(5, code.len)], code[0..@min(5, code.len)]);
    return out;
}

fn quicRefusal(msg: schema.QuicServerMessage) ![5]u8 {
    if (msg != .execute) return error.UnexpectedReply;
    const payload = msg.execute.payload orelse return error.UnexpectedReply;
    if (payload != .@"error") return error.UnexpectedReply;
    return sqlstate5(payload.@"error".code);
}

fn quicDiag(a: std.mem.Allocator, c: *util.QuicProtoClient) !DiagAnswer {
    try c.writeMessage(.{ .cdc_diag = .{} });
    var pkt = try quicReply(a, c);
    errdefer pkt.deinit(a);
    const msg = pkt.quic orelse return error.UnexpectedReply;
    if (msg == .cdc_diag) {
        // The response moves out of the packet.
        const d = msg.cdc_diag;
        pkt.quic = null;
        return .{ .answer = d };
    }
    defer pkt.deinit(a);
    return .{ .refused = try quicRefusal(msg) };
}

fn quicCtrl(a: std.mem.Allocator, c: *util.QuicProtoClient, action: []const u8) !CtrlAnswer {
    try c.writeMessage(.{ .cdc_ctrl = .{ .action = action } });
    var pkt = try quicReply(a, c);
    errdefer pkt.deinit(a);
    const msg = pkt.quic orelse return error.UnexpectedReply;
    if (msg == .cdc_ctrl) {
        const r = msg.cdc_ctrl;
        pkt.quic = null;
        return .{ .answer = r };
    }
    defer pkt.deinit(a);
    return .{ .refused = try quicRefusal(msg) };
}

// ---------------------------------------------------------------------------
// gRPC: unary calls on their own HTTP/2 stream ids, reading the grpc-status
// trailer (as tests/test_sonny6561_cdc_transport_parity.zig).
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

    fn refusal(u: *const Unary) [5]u8 {
        // "<SQLSTATE>: <message>"; a status with no SQLSTATE (UNIMPLEMENTED,
        // 12) is reported as "G<status>".
        if (u.grpc_message.len >= 5 and u.grpc_message.len > 5 and u.grpc_message[5] == ':') return sqlstate5(u.grpc_message[0..5]);
        var out: [5]u8 = "G????".*;
        _ = std.fmt.bufPrint(out[1..], "{d}", .{u.grpc_status}) catch {};
        return out;
    }

    fn diag(self: *GrpcSession, a: std.mem.Allocator, method: []const u8) !DiagAnswer {
        const req = try gq.encodeMessage(a, schema.CdcDiagnosticsRequest{ .session_id = self.client.session_id });
        defer a.free(req);
        var u = try self.call(a, method, req);
        defer u.deinit(a);
        if (u.grpc_status != 0) return .{ .refused = refusal(&u) };
        const bytes = u.message orelse return error.EmptyReply;
        var reader: std.Io.Reader = .fixed(bytes);
        return .{ .answer = try protobuf.decode(schema.CdcDiagnosticsResponse, &reader, a) };
    }

    fn ctrl(self: *GrpcSession, a: std.mem.Allocator, method: []const u8, action: []const u8) !CtrlAnswer {
        const req = try gq.encodeMessage(a, schema.CdcControlRequest{ .action = action, .session_id = self.client.session_id });
        defer a.free(req);
        var u = try self.call(a, method, req);
        defer u.deinit(a);
        if (u.grpc_status != 0) return .{ .refused = refusal(&u) };
        const bytes = u.message orelse return error.EmptyReply;
        var reader: std.Io.Reader = .fixed(bytes);
        return .{ .answer = try protobuf.decode(schema.CdcControlResponse, &reader, a) };
    }
};

// ---------------------------------------------------------------------------
// Statements on either transport (one connection per statement:
// `GrpcProtoClient.executeAndCollect` runs Execute on a fixed stream id).
// ---------------------------------------------------------------------------

fn run(a: std.mem.Allocator, srv: *const Server, t: Transport, who: Principal, query: []const u8) !util.ExecResult {
    switch (t) {
        .quic => {
            var c = try quicConnect(a, srv, who);
            defer c.deinit();
            return c.executeAndCollect(a, query, util.emptyParams(), 100);
        },
        .grpc => {
            var s = try GrpcSession.open(a, srv, who);
            defer s.deinit();
            return s.client.executeAndCollect(a, query, util.emptyParams(), 100);
        },
    }
}

/// The engine's own answer, read by the admin over the CDC_DIAGNOSTICS frame.
fn engineState(a: std.mem.Allocator, srv: *const Server) !schema.CdcDiagnosticsResponse {
    var c = try quicConnect(a, srv, .admin);
    defer c.deinit();
    var d = try quicDiag(a, &c);
    errdefer d.deinit(a);
    if (d != .answer) return error.DiagnosticsRefused;
    return d.answer;
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

/// "cols=a,b [v1,v2]" or "error <SQLSTATE> <message>".
fn describe(a: std.mem.Allocator, r: *const util.ExecResult) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const w = &aw.writer;
    if (r.error_code) |code| {
        try w.print("error {s} {s}", .{ code, r.error_message orelse "" });
        return aw.toOwnedSlice();
    }
    try w.writeAll("cols=");
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

/// `r` is exactly `want` ("cols=... [..]" as `describe` writes it).
fn expectAnswer(a: std.mem.Allocator, t: Transport, query: []const u8, r: *const util.ExecResult, want: []const u8) !void {
    const got = try describe(a, r);
    defer a.free(got);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("{s} `{s}`:\n  want: {s}\n  got:  {s}\n", .{ @tagName(t), query, want, got });
        return error.UntruthfulAnswer;
    }
}

fn expectRefusedNotImplemented(a: std.mem.Allocator, t: Transport, proc: []const u8, r: *const util.ExecResult) !void {
    const code = r.error_code orelse "";
    const msg = r.error_message orelse "";
    if (!std.mem.eql(u8, code, "0A000") or std.mem.indexOf(u8, msg, proc) == null or std.mem.indexOf(u8, msg, "SONNY-6572") == null) {
        const got = try describe(a, r);
        defer a.free(got);
        std.debug.print("{s} CALL {s}: want 0A000 naming the procedure and SONNY-6572; got {s}\n", .{ @tagName(t), proc, got });
        return error.NotRefused;
    }
}

fn expectSqlstate(a: std.mem.Allocator, t: Transport, query: []const u8, r: *const util.ExecResult, code: []const u8) !void {
    if (r.error_code == null or !std.mem.eql(u8, r.error_code.?, code)) {
        const got = try describe(a, r);
        defer a.free(got);
        std.debug.print("{s} `{s}`: want SQLSTATE {s}; got {s}\n", .{ @tagName(t), query, code, got });
        return error.WrongAnswer;
    }
}

fn isRefused(proc: []const u8) bool {
    for (refused_procedures) |p| if (std.mem.eql(u8, p, proc)) return true;
    return false;
}

fn expectAllRefusedNotImplemented(a: std.mem.Allocator, srv: *const Server, t: Transport) !void {
    for (refused_procedures) |proc| {
        var buf: [128]u8 = undefined;
        const q = try callText(&buf, proc);
        var r = try run(a, srv, t, .admin, q);
        defer r.deinit(a);
        try expectRefusedNotImplemented(a, t, proc, &r);
    }
}

/// Every procedure that reads the engine answers its state, CDC never
/// enabled (no engine) and running.
fn checkTruthful(a: std.mem.Allocator, srv: *const Server, t: Transport) !void {
    // ---- No engine. ----
    {
        var r = try run(a, srv, t, .admin, "CALL cdc.status()");
        defer r.deinit(a);
        try expectAnswer(a, t, "CALL cdc.status()", &r, "cols=enabled,streaming,event_count [false,false,0]");
    }
    {
        var r = try run(a, srv, t, .admin, "CALL cdc.export_diagnostics()");
        defer r.deinit(a);
        try expectAnswer(a, t, "CALL cdc.export_diagnostics()", &r, "cols=event_count,malformed_count,last_seq_id [0,0,0]");
    }
    {
        // No engine: no epoch, no thresholds.
        var r = try run(a, srv, t, .admin, "CALL cdc.get_guardrail_status()");
        defer r.deinit(a);
        try expectAnswer(a, t, "CALL cdc.get_guardrail_status()", &r, "cols=current_epoch,warn_threshold,abort_threshold,pending_events [0,null,null,0]");
    }
    // Nothing to reset, start or stop: refused, not "reset_complete" /
    // "started" / "stopped".
    for ([_][]const u8{ "CALL cdc.reset_guardrails()", "CALL cdc.start()", "CALL cdc.stop()" }) |q| {
        var r = try run(a, srv, t, .admin, q);
        defer r.deinit(a);
        try expectSqlstate(a, t, q, &r, "55000");
    }
    try expectAllRefusedNotImplemented(a, srv, t);

    // ---- Running engine. ----
    {
        var r = try run(a, srv, t, .admin, "CALL cdc.enable()");
        defer r.deinit(a);
        try expectAnswer(a, t, "CALL cdc.enable()", &r, "cols=status ['enabled']");
    }
    var d = try engineState(a, srv);
    defer d.deinit(a);
    const cfg = d.config orelse return error.NoConfig;
    const eng = d.engine orelse return error.NoEngine;
    try testing.expect(cfg.enabled and eng.is_running);
    {
        const want = try std.fmt.allocPrint(a, "cols=enabled,streaming,event_count [{},{},0]", .{ cfg.enabled, eng.is_running });
        defer a.free(want);
        var r = try run(a, srv, t, .admin, "CALL cdc.status()");
        defer r.deinit(a);
        try expectAnswer(a, t, "CALL cdc.status()", &r, want);
    }
    {
        // A fresh engine has assigned no sequence number (last_seq_id 0; it
        // reported the next one, 1).
        const want = try std.fmt.allocPrint(a, "cols=event_count,malformed_count,last_seq_id [0,{d},0]", .{d.malformed_change_records});
        defer a.free(want);
        var r = try run(a, srv, t, .admin, "CALL cdc.export_diagnostics()");
        defer r.deinit(a);
        try expectAnswer(a, t, "CALL cdc.export_diagnostics()", &r, want);
    }
    {
        // The engine's guardrail thresholds (its malformed-record ratios), not
        // 1000 / 10000.
        const want = try std.fmt.allocPrint(a, "cols=current_epoch,warn_threshold,abort_threshold,pending_events [{d},{d},{d},{d}]", .{ d.guardrail_epoch, cfg.malformed_warn_pct, cfg.malformed_abort_pct, eng.current_buffer });
        defer a.free(want);
        var r = try run(a, srv, t, .admin, "CALL cdc.get_guardrail_status()");
        defer r.deinit(a);
        try expectAnswer(a, t, "CALL cdc.get_guardrail_status()", &r, want);
    }
    {
        const want = try std.fmt.allocPrint(a, "cols=status,new_epoch ['reset_complete',{d}]", .{d.guardrail_epoch + 1});
        defer a.free(want);
        var r = try run(a, srv, t, .admin, "CALL cdc.reset_guardrails()");
        defer r.deinit(a);
        try expectAnswer(a, t, "CALL cdc.reset_guardrails()", &r, want);
        var after = try engineState(a, srv);
        defer after.deinit(a);
        try testing.expectEqual(d.guardrail_epoch + 1, after.guardrail_epoch);
    }
    {
        var r = try run(a, srv, t, .admin, "CALL cdc.stop()");
        defer r.deinit(a);
        try expectAnswer(a, t, "CALL cdc.stop()", &r, "cols=status,final_event_count ['stopped',0]");
        var after = try engineState(a, srv);
        defer after.deinit(a);
        try testing.expect(!(after.engine orelse return error.NoEngine).is_running);
        var s = try run(a, srv, t, .admin, "CALL cdc.status()");
        defer s.deinit(a);
        try expectAnswer(a, t, "CALL cdc.status()", &s, "cols=enabled,streaming,event_count [true,false,0]");
    }
    {
        var r = try run(a, srv, t, .admin, "CALL cdc.start()");
        defer r.deinit(a);
        try expectAnswer(a, t, "CALL cdc.start()", &r, "cols=status,event_count ['started',0]");
        var after = try engineState(a, srv);
        defer after.deinit(a);
        try testing.expect((after.engine orelse return error.NoEngine).is_running);
    }
    try expectAllRefusedNotImplemented(a, srv, t);
    {
        var r = try run(a, srv, t, .admin, "CALL cdc.disable()");
        defer r.deinit(a);
        try testing.expect(r.error_code == null);
        var after = try engineState(a, srv);
        defer after.deinit(a);
        try testing.expect(!(after.config orelse return error.NoConfig).enabled);
    }
}

test "SONNY-6570: every CALL cdc.* answers from the CDC engine or is refused 0A000, over QUIC and gRPC" {
    const a = testing.allocator;
    var srv = try Server.start(a, &.{}, &.{});
    defer srv.deinit();
    for ([_]Transport{ .quic, .grpc }) |t| try checkTruthful(a, &srv, t);
}

// ---------------------------------------------------------------------------
// Authorization: every role x operation x transport.
// ---------------------------------------------------------------------------

test "SONNY-6570: every CDC procedure and frame is Admin only on QUIC and gRPC (42501 for readwrite, readonly and user; 28000 unauthenticated)" {
    const a = testing.allocator;
    var srv = try Server.start(a, &.{}, &.{});
    defer srv.deinit();
    try createUsers(a, &srv);

    var wrong: usize = 0;
    var checked: usize = 0;
    std.debug.print("SONNY-6570 authorization table (principal | transport | operation | answer)\n", .{});
    // CDC on: a refusal must also leave the running engine alone.
    {
        var r = try run(a, &srv, .quic, .admin, "CALL cdc.enable()");
        defer r.deinit(a);
        try testing.expect(r.error_code == null);
    }
    for ([_]Principal{ .admin, .readwrite, .readonly, .user, .anonymous }) |who| {
        for ([_]Transport{ .quic, .grpc }) |t| {
            const want: []const u8 = switch (who) {
                .admin => "allowed",
                .anonymous => "28000",
                else => "42501",
            };
            // The frames.
            {
                var diag: DiagAnswer = undefined;
                var ctrl: CtrlAnswer = undefined;
                switch (t) {
                    .quic => {
                        var c = try quicConnect(a, &srv, who);
                        defer c.deinit();
                        diag = try quicDiag(a, &c);
                        ctrl = try quicCtrl(a, &c, "RESET_GUARDRAILS");
                    },
                    .grpc => {
                        var s = try GrpcSession.open(a, &srv, who);
                        defer s.deinit();
                        diag = try s.diag(a, "/geode.GeodeService/GetCdcDiagnostics");
                        ctrl = try s.ctrl(a, "/geode.GeodeService/ControlCdc", "RESET_GUARDRAILS");
                    },
                }
                defer diag.deinit(a);
                defer ctrl.deinit(a);
                inline for (.{ .{ "CDC_DIAGNOSTICS", &diag }, .{ "CDC_CONTROL", &ctrl } }) |pair| {
                    const got: []const u8 = switch (pair[1].*) {
                        .answer => "allowed",
                        .refused => |*s| s,
                    };
                    checked += 1;
                    const ok = std.mem.eql(u8, got, want);
                    if (!ok) wrong += 1;
                    std.debug.print("{s:<9} | {s:<4} | {s:<34} | {s}{s}{s}\n", .{ @tagName(who), @tagName(t), pair[0], got, if (ok) "" else "   <-- want ", if (ok) "" else want });
                }
            }
            if (who == .anonymous) continue; // a CALL needs a session on both transports
            for (all_procedures) |proc| {
                var buf: [128]u8 = undefined;
                const q = try callText(&buf, proc);
                var r = try run(a, &srv, t, who, q);
                defer r.deinit(a);
                const code = r.error_code orelse "allowed";
                // The admin is allowed: an answer, or the procedure's own
                // refusal (0A000 not implemented, 55000 CDC not enabled).
                const ok = if (who == .admin)
                    (r.error_code == null or std.mem.eql(u8, code, "0A000") or std.mem.eql(u8, code, "55000"))
                else
                    std.mem.eql(u8, code, want);
                checked += 1;
                if (!ok) wrong += 1;
                std.debug.print("{s:<9} | {s:<4} | {s:<34} | {s}{s}{s}\n", .{ @tagName(who), @tagName(t), q, code, if (ok) "" else "   <-- want ", if (ok) "" else want });
                // A refused cdc.disable / cdc.stop must not have stopped it.
                if (who == .admin) {
                    if (std.mem.eql(u8, proc, "cdc.disable") or std.mem.eql(u8, proc, "cdc.stop")) {
                        var e = try run(a, &srv, .quic, .admin, "CALL cdc.enable()");
                        defer e.deinit(a);
                        var s = try run(a, &srv, .quic, .admin, "CALL cdc.start()");
                        defer s.deinit(a);
                    }
                } else {
                    var d = try engineState(a, &srv);
                    defer d.deinit(a);
                    const running = if (d.engine) |e| e.is_running else false;
                    if (!running) {
                        std.debug.print("  {s} `{s}` stopped or disabled the CDC engine\n", .{ @tagName(who), q });
                        wrong += 1;
                        var e = try run(a, &srv, .quic, .admin, "CALL cdc.enable()");
                        defer e.deinit(a);
                        var s = try run(a, &srv, .quic, .admin, "CALL cdc.start()");
                        defer s.deinit(a);
                    }
                }
            }
        }
    }
    std.debug.print("SONNY-6570: {d} of {d} CDC authorization answers wrong\n", .{ wrong, checked });
    try testing.expectEqual(@as(usize, 0), wrong);
}

// ---------------------------------------------------------------------------
// Audit.
// ---------------------------------------------------------------------------

fn readFile(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(fsIo(), path, a, .limited(64 << 20));
}

const Run = struct {
    code: ?u8,
    output: []u8,
};

/// `geode audit verify ...`, output to a file, killed after `timeout_s`.
fn runGeode(a: std.mem.Allocator, dir: []const u8, argv: []const []const u8, timeout_s: i64) !Run {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    const out_path = try std.fmt.allocPrint(a, "{s}/verify.out", .{dir});
    defer a.free(out_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
    defer out.close(fsIo());
    const child = try std.process.spawn(threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .{ .file = out },
        .stderr = .{ .file = out },
    });
    const pid = child.id.?;
    var status: u32 = 0;
    var exited = false;
    var waited_ms: i64 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        if (rc == @as(usize, @intCast(pid))) {
            exited = true;
            break;
        }
        if (waited_ms >= timeout_s * 1000) {
            std.posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            break;
        }
        fsIo().sleep(.fromNanoseconds(100 * std.time.ns_per_ms), .awake) catch {};
        waited_ms += 100;
    }
    const code: ?u8 = if (exited and (status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else null;
    return .{ .code = code, .output = try readFile(a, out_path) };
}

/// The audit record lines naming `action` (`"action":"<action>"`).
fn countAction(log: []const u8, action: []const u8, result: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, log, '\n');
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"action\":\"{s}\"", .{action}) catch return 0;
    var result_buf: [64]u8 = undefined;
    const result_needle = std.fmt.bufPrint(&result_buf, "\"result\":\"{s}\"", .{result}) catch return 0;
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) != null and std.mem.indexOf(u8, line, result_needle) != null) n += 1;
    }
    return n;
}

test "SONNY-6570: CDC changes and refusals write audit records, on both transports, and the audit chain verifies" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var dir = try test_scratch.ScratchDir.create("sonny6570-audit");
    defer dir.remove();
    const data_dir = try std.fmt.allocPrint(a, "{s}/data", .{dir.path()});
    defer a.free(data_dir);
    try std.Io.Dir.cwd().createDirPath(fsIo(), data_dir);
    const log_path = try std.fmt.allocPrint(a, "{s}/audit6570.jsonl", .{dir.path()});
    defer a.free(log_path);
    const log_env = try std.fmt.allocPrint(a, "GEODE_AUDIT_LOG_PATH={s}", .{log_path});
    defer a.free(log_env);

    {
        var srv = try Server.start(a, &.{ "--data-dir", data_dir }, &.{ "GEODE_AUDIT_ENABLED=1", log_env });
        defer srv.deinit();
        try createUsers(a, &srv);

        for ([_]Transport{ .quic, .grpc }) |t| {
            for ([_][]const u8{
                "CALL cdc.enable()",
                "CALL cdc.reset_guardrails()",
                "CALL cdc.stop()",
                "CALL cdc.start()",
                "CALL cdc.pause()",
            }) |q| {
                var r = try run(a, &srv, t, .admin, q);
                defer r.deinit(a);
            }
            // The control frame, the admin and a readwrite user.
            for ([_]Principal{ .admin, .readwrite }) |who| {
                var ctrl: CtrlAnswer = switch (t) {
                    .quic => blk: {
                        var c = try quicConnect(a, &srv, who);
                        defer c.deinit();
                        break :blk try quicCtrl(a, &c, "RESET_GUARDRAILS");
                    },
                    .grpc => blk: {
                        var s = try GrpcSession.open(a, &srv, who);
                        defer s.deinit();
                        break :blk try s.ctrl(a, "/geode.GeodeService/ControlCdc", "RESET_GUARDRAILS");
                    },
                };
                ctrl.deinit(a);
            }
            {
                var r = try run(a, &srv, t, .readwrite, "CALL cdc.disable()");
                defer r.deinit(a);
            }
            {
                var r = try run(a, &srv, t, .admin, "CALL cdc.disable()");
                defer r.deinit(a);
            }
        }
        srv.terminate();
    }

    const log = try readFile(a, log_path);
    defer a.free(log);
    const Expect = struct { action: []const u8, result: []const u8, min: usize };
    const expected = [_]Expect{
        // One per transport.
        .{ .action = "cdc.enable", .result = "success", .min = 2 },
        .{ .action = "cdc.reset_guardrails", .result = "success", .min = 2 },
        .{ .action = "cdc.stop", .result = "success", .min = 2 },
        .{ .action = "cdc.start", .result = "success", .min = 2 },
        .{ .action = "cdc.disable", .result = "success", .min = 2 },
        // A refused change attempt is a failure record.
        .{ .action = "cdc.pause", .result = "failure", .min = 2 },
        // The readwrite user's refusals (access_denied).
        .{ .action = "cdc.disable", .result = "failure", .min = 2 },
        .{ .action = "CDC_CONTROL", .result = "success", .min = 2 },
        .{ .action = "CDC_CONTROL", .result = "failure", .min = 2 },
    };
    var missing: usize = 0;
    for (expected) |e| {
        const n = countAction(log, e.action, e.result);
        std.debug.print("audit {s} result={s}: {d} record(s) (want at least {d})\n", .{ e.action, e.result, n, e.min });
        if (n < e.min) missing += 1;
    }
    if (missing > 0) std.debug.print("--- audit log ---\n{s}\n", .{log});
    try testing.expectEqual(@as(usize, 0), missing);

    // The chain and the signatures verify.
    const pub_path = try std.fmt.allocPrint(a, "{s}.pub", .{log_path});
    defer a.free(pub_path);
    const pub_raw = try readFile(a, pub_path);
    defer a.free(pub_raw);
    const pub_hex = std.mem.trim(u8, pub_raw, " \t\r\n");
    const v = try runGeode(a, dir.path(), &.{ geode_test_bin.geode_exe, "audit", "verify", "--file", log_path, "--pubkey", pub_hex }, 120);
    defer a.free(v.output);
    if (v.code != @as(?u8, 0)) std.debug.print("geode audit verify: exit {?d}\n{s}\n", .{ v.code, v.output });
    try testing.expectEqual(@as(?u8, 0), v.code);
}

// ---------------------------------------------------------------------------
// The .proto's method names.
// ---------------------------------------------------------------------------

test "SONNY-6570: the server serves the CDC RPCs src/proto/geode.proto declares (GetCdcDiagnostics, ControlCdc), as it serves /CdcDiag and /CdcCtrl" {
    const a = testing.allocator;
    var srv = try Server.start(a, &.{}, &.{});
    defer srv.deinit();
    {
        var r = try run(a, &srv, .quic, .admin, "CALL cdc.enable()");
        defer r.deinit(a);
        try testing.expect(r.error_code == null);
    }
    var s = try GrpcSession.open(a, &srv, .admin);
    defer s.deinit();

    var proto_diag = try s.diag(a, "/geode.GeodeService/GetCdcDiagnostics");
    defer proto_diag.deinit(a);
    var short_diag = try s.diag(a, "/geode.GeodeService/CdcDiag");
    defer short_diag.deinit(a);
    if (proto_diag != .answer) std.debug.print("GetCdcDiagnostics answered {s}\n", .{&proto_diag.refused});
    try testing.expect(proto_diag == .answer);
    try testing.expect(short_diag == .answer);
    try testing.expectEqual(short_diag.answer.guardrail_epoch, proto_diag.answer.guardrail_epoch);
    try testing.expect((proto_diag.answer.engine orelse return error.NoEngine).is_running);

    const epoch = short_diag.answer.guardrail_epoch;
    var proto_ctrl = try s.ctrl(a, "/geode.GeodeService/ControlCdc", "RESET_GUARDRAILS");
    defer proto_ctrl.deinit(a);
    if (proto_ctrl != .answer) std.debug.print("ControlCdc answered {s}\n", .{&proto_ctrl.refused});
    try testing.expect(proto_ctrl == .answer);
    try testing.expect(proto_ctrl.answer.success);
    try testing.expectEqual(epoch + 1, proto_ctrl.answer.guardrail_epoch);
    var short_ctrl = try s.ctrl(a, "/geode.GeodeService/CdcCtrl", "RESET_GUARDRAILS");
    defer short_ctrl.deinit(a);
    try testing.expect(short_ctrl == .answer);
    try testing.expectEqual(epoch + 2, short_ctrl.answer.guardrail_epoch);
}

// ---------------------------------------------------------------------------
// startCDC on a failing start.
// ---------------------------------------------------------------------------

test "SONNY-6570: cdc_enhanced.startCDC frees the engine when start() fails (every allocation failure)" {
    // Each run fails one more allocation; std.testing.allocator reports
    // anything a failed start left behind.
    var fail_index: usize = 0;
    var failures: usize = 0;
    while (fail_index < 256) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const fa = failing.allocator();
        const engine = cdc.startCDC(fa, .{ .enabled = true, .batch_size = 100, .flush_interval_ms = 1000 }) catch {
            failures += 1;
            continue;
        };
        engine.deinit();
        fa.destroy(engine);
        break;
    }
    // At least the engine allocation and a start() allocation failed.
    try testing.expect(failures >= 2);
    try testing.expect(fail_index < 256);
}
