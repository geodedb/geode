//! SONNY-6624 (1) and (2).
//!
//! (1) `geode.auth.mfa_disable` needs no proof of possession (an Admin's
//!     recovery route: no code, or a code checked for its format only). It
//!     was audited only as the security graph's `MFA_DISABLE` mutation, the
//!     same record a user's own disable would leave, with no actor. Every
//!     mfa_disable now also leaves a `MFA_RESET_BY_ADMIN` record naming the
//!     actor (`username`) and the target (`target_user`).
//! (2) DROP USER removes the user's stored MfaAttempts record (through
//!     `storage.removeUser`) and its in-memory attempt record
//!     (`forgetMfaEnrollment`): both go, and a user made again under the
//!     name starts with no failures, before and after a restart.
//!
// CANARY: REQ=REQ-SONNY-6624-MFA-RESET-AUDIT; FEATURE="MFA authentication"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6624_mfa_reset_audit.zig; OWNER=security; UPDATED=2026-11-15
const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");
const auth_graph_manager = @import("auth_graph_manager");
const hydration = @import("auth_startup_hydration");

const um = geode.user_management;
const graph_store = geode.graph_store;
const gps = geode.security.gps;
const audit = geode.security.audit;
const auth_dispatch = geode.auth_dispatch;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;
const Role = um.Role;

const HMAC_KEY = [_]u8{0x24} ** 32;
const user_pw = "Correct Horse Battery Staple 6624";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn agmOf(ctx: ?*anyopaque) *AuthGraphManager {
    return @ptrCast(@alignCast(ctx.?));
}

fn writerCreateUser(ctx: ?*anyopaque, username: []const u8, email: []const u8, password_hash: []const u8, role: Role) anyerror!void {
    const agm = agmOf(ctx);
    _ = try agm.createUserWithRole(&agm.hmac_key, username, email, password_hash, role == .Admin, if (role == .Admin) null else role.toString());
}

fn writerDeleteUser(ctx: ?*anyopaque, username: []const u8) anyerror!void {
    const agm = agmOf(ctx);
    try agm.deleteUserWriteThrough(&agm.hmac_key, username);
}

const World = struct {
    h: harness.Harness,
    arena: std.heap.ArenaAllocator,
    sessions: grpc.SessionStore,
    sec_store: graph_store.GraphStore,
    agm: AuthGraphManager,
    admin: []const u8 = "",
    auth_was: bool,
    allow_was: bool,

    fn init(self: *World) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        _ = graph_store.getGlobalStore(testing.allocator);
        _ = geode.txn_undo_log.getGlobalUndoLog(testing.allocator);
        self.auth_was = um.isAuthEnabled();
        um.setAuthEnabled(true);
        self.allow_was = gps.isInsecureAllowAll();
        gps.setInsecureAllowAll(false);

        self.sec_store = try graph_store.GraphStore.init(testing.allocator);
        self.agm = try AuthGraphManager.init(testing.allocator, &self.sec_store);
        self.agm.hmac_key = HMAC_KEY;
        AuthGraphManager.setGlobal(&self.agm);

        um.deinitUserStore();
        um.setPersistentUserResolver(null);
        try um.initUserStore(testing.allocator);
        um.setPersistentUserWriter(.{ .ctx = @ptrCast(&self.agm), .create_fn = &writerCreateUser, .delete_fn = &writerDeleteUser });

        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
        self.admin = try self.sessions.createSession("root6624", "", .Admin, null, null, false, 0);
        auth_dispatch.deinitMfaStore();
        auth_dispatch.setMfaPersistCallbacks(hydration.mfaPersistCallbacks(&self.agm));
    }

    fn deinit(self: *World) void {
        auth_dispatch.setMfaPersistCallbacks(.{});
        auth_dispatch.deinitMfaStore();
        grpc.setSessionStore(null);
        self.sessions.deinit();
        self.arena.deinit();
        um.setPersistentUserWriter(null);
        um.deinitUserStore();
        AuthGraphManager.setGlobal(null);
        self.agm.deinit();
        self.sec_store.deinit();
        gps.setInsecureAllowAll(self.allow_was);
        um.setAuthEnabled(self.auth_was);
        geode.txn_undo_log.setThreadTxnId(0);
        self.h.deinit();
    }
};

fn tmpPath(ga: std.mem.Allocator, tmp: *const testing.TmpDir, name: []const u8) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io(), &buf);
    return std.fmt.allocPrint(ga, "{s}/{s}", .{ buf[0..n], name });
}

/// The audit records (one JSON object per line) whose action is `action`.
fn recordsWithAction(ga: std.mem.Allocator, sink: []const u8, action: []const u8) ![]std.json.Value {
    var out: std.ArrayList(std.json.Value) = .empty;
    var lines = std.mem.tokenizeScalar(u8, sink, '\n');
    while (lines.next()) |line| {
        const v = std.json.parseFromSliceLeaky(std.json.Value, ga, line, .{}) catch continue;
        if (v != .object) continue;
        const a = v.object.get("action") orelse continue;
        if (a == .string and std.mem.eql(u8, a.string, action)) try out.append(ga, v);
    }
    return out.items;
}

fn detail(rec: std.json.Value, key: []const u8) ?[]const u8 {
    const d = rec.object.get("details") orelse return null;
    if (d != .object) return null;
    const v = d.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

test "SONNY-6624 (1): mfa_disable leaves a MFA_RESET_BY_ADMIN audit record with the actor and the target" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sink_path = try tmpPath(ga, &tmp, "audit.jsonl");
    const logger = try audit.AuditLogger.createHeap(testing.allocator, .{ .enabled = true, .file_path = sink_path });
    defer {
        audit.setGlobalAuditLogger(null);
        logger.deinit();
        testing.allocator.destroy(logger);
    }
    audit.setGlobalAuditLogger(logger);

    try fx.expectRuns(ga, w.admin, "CREATE USER tg6624 SET PASSWORD '" ++ user_pw ++ "'");
    try fx.expectRuns(ga, w.admin, "CALL geode.auth.mfa_setup('tg6624')");
    // No code: the recovery route.
    try fx.expectRuns(ga, w.admin, "CALL geode.auth.mfa_disable('tg6624')");
    // A code that is only checked for its format proves nothing either.
    try fx.expectRuns(ga, w.admin, "CALL geode.auth.mfa_disable('tg6624', '123456')");

    const sink = try std.Io.Dir.cwd().readFileAlloc(io(), sink_path, ga, .limited(1 << 22));
    const resets = try recordsWithAction(ga, sink, "MFA_RESET_BY_ADMIN");
    if (resets.len != 2) {
        std.debug.print("SONNY-6624 (1): {d} MFA_RESET_BY_ADMIN record(s) after two mfa_disable calls, want 2; sink:\n{s}\n", .{ resets.len, sink });
        return error.MfaResetNotAudited;
    }
    for (resets) |rec| {
        try testing.expectEqualStrings("root6624", detail(rec, "username") orelse return error.ActorNotRecorded);
        try testing.expectEqualStrings("tg6624", detail(rec, "target_user") orelse return error.TargetNotRecorded);
    }
    try testing.expect(std.mem.indexOf(u8, detail(resets[0], "details").?, "no code") != null);
    try testing.expect(std.mem.indexOf(u8, detail(resets[1], "details").?, "not verified") != null);

    // A refused disable (no such user) is not a reset.
    _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.mfa_disable('nobody6624')", "42002");
    const sink2 = try std.Io.Dir.cwd().readFileAlloc(io(), sink_path, ga, .limited(1 << 22));
    try testing.expectEqual(@as(usize, 2), (try recordsWithAction(ga, sink2, "MFA_RESET_BY_ADMIN")).len);
}

test "SONNY-6624 (2): DROP USER removes both the stored MfaAttempts record and the in-memory one" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    const flags = geode.util_feature_flags.global();
    defer flags.mfa.clearTestOverride();
    flags.mfa.enableForTests();

    try fx.expectRuns(ga, w.admin, "CREATE USER dr6624 SET PASSWORD '" ++ user_pw ++ "'");
    try fx.expectRuns(ga, w.admin, "CALL geode.auth.mfa_setup('dr6624')");
    const uid = (w.agm.storage.getUserByUsername("dr6624") orelse return error.UserNotStored).id;
    // Five wrong codes: locked out, in memory and in the security graph.
    var i: usize = 0;
    while (i < 5) : (i += 1) _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.mfa_verify('dr6624', '000000')", "28000");
    const st = (try w.agm.mfaAttempts(uid)) orelse return error.LockoutNotStored;
    try testing.expectEqual(@as(u32, 5), st.fail_count);
    try testing.expect(auth_dispatch.g_mfa_attempts_init and auth_dispatch.g_mfa_attempts.contains("dr6624"));
    const stored_before = w.agm.storage.mfa_attempt_nodes.count();
    try testing.expect(stored_before >= 1);

    try fx.expectRuns(ga, w.admin, "DROP USER dr6624");

    if (try w.agm.mfaAttempts(uid)) |left| {
        std.debug.print("SONNY-6624 (2): the dropped user's stored MfaAttempts record stayed (fail_count {d})\n", .{left.fail_count});
        return error.StoredAttemptsStayed;
    }
    try testing.expectEqual(stored_before - 1, w.agm.storage.mfa_attempt_nodes.count());
    if (auth_dispatch.g_mfa_attempts_init and auth_dispatch.g_mfa_attempts.contains("dr6624")) {
        std.debug.print("SONNY-6624 (2): the dropped user's in-memory attempt record stayed\n", .{});
        return error.InMemoryAttemptsStayed;
    }

    // A restart loads nothing for the name, and a user made again under it
    // is not locked out: it can enroll and verify a code check (28000, a
    // wrong code, not 53400, a lockout).
    auth_dispatch.deinitMfaStore();
    _ = try hydration.hydrateMfaEnrollments(testing.allocator, &w.agm);
    try testing.expect(!(auth_dispatch.g_mfa_attempts_init and auth_dispatch.g_mfa_attempts.contains("dr6624")));
    try fx.expectRuns(ga, w.admin, "CREATE USER dr6624 SET PASSWORD '" ++ user_pw ++ "'");
    try fx.expectRuns(ga, w.admin, "CALL geode.auth.mfa_setup('dr6624')");
    _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.mfa_verify('dr6624', '000000')", "28000");
}
