//! SONNY-6598: a server-side failure while checking a password is not a
//! wrong password, over QUIC and over gRPC, against a real `geode serve`.
//!
//! `geode_auth.verifyPasswordArgon2id` turned every Argon2 KDF error
//! (`catch return false`) and every malformed stored PHC string into "the
//! password does not match". A login whose Argon2id work could not allocate
//! its memory (a loaded server) was answered "Authentication failed" and
//! counted toward the per-principal lockout, so a user with the right
//! password was locked out by the server's own load, and the operator saw a
//! brute-force signal that was not one.
//!
//! The server is a Debug build with the test-only KDF fault hook armed
//! (GEODE_TEST_AUTH_KDF_FAULT_USER / _COUNT,
//! `user_management.injectKdfAllocFailures`): the first logins of one user
//! run Argon2id on an allocator that fails every allocation. With the lockout
//! at two attempts:
//!
//!   * every faulted login, with the right password, is answered
//!     "Authentication temporarily unavailable" on both transports (never
//!     "Authentication failed"), more of them than the lockout threshold;
//!   * the next login with the right password succeeds on both transports
//!     (the faults did not count toward the lockout);
//!   * a user whose stored hash is a malformed PHC string (imported with
//!     `geode.auth.user_import`) is answered the server-side credential
//!     error, never "Authentication failed", and never locked out;
//!   * a wrong password is still "Authentication failed" and still locks
//!     the principal out (guard);
//!   * the audit log records each faulted login as an auth-system error
//!     (event_type system_event, action AUTH_ERROR, result error_) and only
//!     the wrong passwords as failed logins (authentication_failure).
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const test_scratch = @import("test_scratch.zig");

const fault_user = "kdf6598";
const bad_hash_user = "badhash6598";
const user_password = "Correct Horse Battery Staple 6598";
const wrong_password = "Wrong Horse Battery Staple 6598";
/// Faulted logins per transport; above the lockout threshold below.
const faults_per_transport = 3;
const lockout_attempts = "2";

/// A PHC string that cannot be verified: the salt is not hex.
const malformed_phc = "$argon2id$v=19$m=19456,t=2,p=1$zz112233445566778899aabbccddeeff$00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

const unavailable_msg = "Authentication temporarily unavailable";
const credential_invalid_msg = "Authentication unavailable: the stored credential of this account cannot be used (server-side error; contact the administrator)";
const failed_msg = "Authentication failed";

const Server = struct {
    handle: util.ServerHandle,
    quic_addr: []u8,
    grpc_addr: []u8,
    audit_path: []u8,
    allocator: std.mem.Allocator,

    fn start(a: std.mem.Allocator) !Server {
        const root = try test_scratch.processRoot();
        const audit_path = try std.fmt.allocPrint(a, "{s}/audit6598.jsonl", .{root});
        errdefer a.free(audit_path);
        const data_dir = try std.fmt.allocPrint(a, "{s}/data6598", .{root});
        defer a.free(data_dir);
        const io = std.Io.Threaded.global_single_threaded.io();
        try std.Io.Dir.cwd().createDirPath(io, data_dir);

        const quic_port = try util.getRandomPort();
        var grpc_port = try util.getRandomTcpPort();
        while (grpc_port == quic_port) grpc_port = try util.getRandomTcpPort();
        const quic_addr = try util.formatAddr(a, quic_port);
        errdefer a.free(quic_addr);
        const grpc_addr = try util.formatAddr(a, grpc_port);
        errdefer a.free(grpc_addr);

        const audit_env = try std.fmt.allocPrint(a, "GEODE_AUDIT_LOG_PATH={s}", .{audit_path});
        defer a.free(audit_env);
        const data_env = try std.fmt.allocPrint(a, "GEODE_DATA_DIR={s}", .{data_dir});
        defer a.free(data_env);
        const count_env = std.fmt.comptimePrint("GEODE_TEST_AUTH_KDF_FAULT_COUNT={d}", .{2 * faults_per_transport});
        const env = [_][]const u8{
            "GEODE_GRPC_ALLOW_PLAINTEXT_FALLBACK=1",
            "GEODE_QUIC_PASSIVE_TEARDOWN=1",
            "GEODE_TEST_AUTH_KDF_FAULT_USER=" ++ fault_user,
            count_env,
            "GEODE_AUTH_RATE_MAX_ATTEMPTS=" ++ lockout_attempts,
            "GEODE_AUDIT_ENABLED=1",
            audit_env,
            data_env,
        };
        var handle = try util.spawnServer(
            a,
            &.{ geode_test_bin.geode_exe, "serve", "--listen", quic_addr, "--listen-grpc", grpc_addr },
            &env,
        );
        errdefer handle.deinit();
        try util.waitForServerReady(a, quic_addr, 15000);
        try util.waitForGrpcServerReady(a, grpc_addr, 15000);
        return .{ .handle = handle, .quic_addr = quic_addr, .grpc_addr = grpc_addr, .audit_path = audit_path, .allocator = a };
    }

    fn deinit(self: *Server) void {
        self.handle.deinit();
        self.allocator.free(self.quic_addr);
        self.allocator.free(self.grpc_addr);
        self.allocator.free(self.audit_path);
    }
};

const Transport = enum { quic, grpc };

/// One HELLO on a new connection; the answer's message ("" on success).
fn hello(a: std.mem.Allocator, srv: *const Server, t: Transport, user: []const u8, password: []const u8) ![]u8 {
    var h = switch (t) {
        .quic => blk: {
            var c = try util.QuicProtoClient.connect(a, srv.quic_addr);
            defer c.deinit();
            break :blk try c.hello(a, user, password);
        },
        .grpc => blk: {
            var c = try util.GrpcProtoClient.connect(a, srv.grpc_addr);
            defer c.deinit();
            break :blk try c.hello(a, user, password);
        },
    };
    defer h.deinit(a);
    if (h.success) return a.dupe(u8, "");
    return a.dupe(u8, h.error_message);
}

fn expectHello(a: std.mem.Allocator, srv: *const Server, t: Transport, user: []const u8, password: []const u8, want: []const u8) !void {
    const got = try hello(a, srv, t, user, password);
    defer a.free(got);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("{s} HELLO {s}: got \"{s}\", want \"{s}\"\n", .{ @tagName(t), user, got, if (want.len == 0) "<success>" else want });
        return error.TestUnexpectedResult;
    }
}

fn setup(a: std.mem.Allocator, srv: *const Server) !void {
    var c = try util.QuicProtoClient.connect(a, srv.quic_addr);
    defer c.deinit();
    var h = try c.hello(a, util.defaultUsername(), util.defaultPassword());
    defer h.deinit(a);
    if (!h.success) return error.AdminLoginFailed;
    const ddl = [_][]const u8{
        "CREATE USER " ++ fault_user ++ " SET PASSWORD '" ++ user_password ++ "'",
        "CALL geode.auth.user_import('" ++ bad_hash_user ++ "', '" ++ malformed_phc ++ "', 'argon2id')",
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

const AuditCounts = struct {
    auth_errors: usize = 0,
    failed_logins: usize = 0,
};

/// The audit records naming `user` (details.username): auth-system errors
/// and failed logins.
fn countAudit(a: std.mem.Allocator, path: []const u8, user: []const u8) !AuditCounts {
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 20));
    defer a.free(text);
    var counts: AuditCounts = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, a, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        const details = obj.get("details") orelse continue;
        if (details != .object) continue;
        const name = details.object.get("username") orelse continue;
        if (name != .string or !std.mem.eql(u8, name.string, user)) continue;
        const event_type = (obj.get("event_type") orelse continue).string;
        const action = (obj.get("action") orelse continue).string;
        const result = (obj.get("result") orelse continue).string;
        if (std.mem.eql(u8, event_type, "system_event") and std.mem.eql(u8, action, "AUTH_ERROR") and std.mem.eql(u8, result, "error_")) {
            counts.auth_errors += 1;
        } else if (std.mem.eql(u8, event_type, "authentication_failure") and std.mem.eql(u8, action, "LOGIN") and std.mem.eql(u8, result, "failure")) {
            counts.failed_logins += 1;
        }
    }
    return counts;
}

test "SONNY-6598: a KDF failure or a malformed stored hash at HELLO is a server-side error, not a wrong password, on QUIC and gRPC" {
    // The fault hook exists in Debug builds only.
    if (builtin.mode != .Debug) return error.SkipZigTest;
    const a = testing.allocator;
    var srv = try Server.start(a);
    defer srv.deinit();
    try setup(a, &srv);

    // Faulted logins with the right password: more than the lockout
    // threshold on each transport, every one answered "temporarily
    // unavailable".
    for ([_]Transport{ .quic, .grpc }) |t| {
        for (0..faults_per_transport) |_| try expectHello(a, &srv, t, fault_user, user_password, unavailable_msg);
    }
    // The faults did not count toward the lockout: the right password logs
    // in on both transports.
    try expectHello(a, &srv, .quic, fault_user, user_password, "");
    try expectHello(a, &srv, .grpc, fault_user, user_password, "");

    // A malformed stored hash: a server-side credential error, whatever the
    // password, never locked out.
    for ([_]Transport{ .quic, .grpc }) |t| {
        for (0..faults_per_transport) |_| try expectHello(a, &srv, t, bad_hash_user, user_password, credential_invalid_msg);
    }

    // Guard: a wrong password is still a failed login and still locks the
    // principal out.
    try expectHello(a, &srv, .quic, fault_user, wrong_password, failed_msg);
    try expectHello(a, &srv, .grpc, fault_user, wrong_password, failed_msg);
    const locked = try hello(a, &srv, .quic, fault_user, user_password);
    defer a.free(locked);
    try testing.expect(std.mem.startsWith(u8, locked, "Too many failed authentication attempts"));

    // The audit log: each faulted login is an auth-system error, only the
    // two wrong passwords are failed logins.
    const fault_audit = try countAudit(a, srv.audit_path, fault_user);
    try testing.expectEqual(@as(usize, 2 * faults_per_transport), fault_audit.auth_errors);
    try testing.expectEqual(@as(usize, 2), fault_audit.failed_logins);
    const bad_hash_audit = try countAudit(a, srv.audit_path, bad_hash_user);
    try testing.expectEqual(@as(usize, 2 * faults_per_transport), bad_hash_audit.auth_errors);
    try testing.expectEqual(@as(usize, 0), bad_hash_audit.failed_logins);
}
