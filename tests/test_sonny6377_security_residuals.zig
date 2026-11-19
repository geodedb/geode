// SONNY-6377 items 3-6 regression (found during SONNY-6369/3135/2729).
//
// 3. RLSEngine.checkRowAccess cached its per-row verdict under (graph, table,
//    user, operation), a key with no row in it, and returned a cached deny
//    before evaluating: once one row was denied, every later row of that
//    table was denied to that user for that operation until the entry
//    expired (fail closed, wrong results). A row-level decision is not
//    cached (as checkRowAccessByUsernameSeeded already does, GAP-0284).
// 4. geode.auth.user_import's result, and geode.rls.list_deny_policies' and
//    policy_count's, did not own their rows (the caller leaked their
//    strings), and policy_count with no filter engine answered 0 instead of
//    an error (55000, as the other geode.rls procedures since SONNY-6369).
// 5. user_attribute_store.setAttribute: an allocation failure after it
//    inserted a new user's entry left that entry with a borrowed key and an
//    undefined attribute map; one after it removed the old value lost the
//    attribute.
// 6. Security-graph writes made outside a statement (the login's legacy hash
//    upgrade, the QUIC and gRPC ALTER USER SET PASSWORD intercepts) must be
//    durable when the operation reports success: they survive a SIGKILL.
//    They are: each write-through runs before the reply, with no statement
//    or session engine transaction on the thread, so every adapter write
//    auto-commits, and `__geode_security`'s engines fsync each commit. This
//    test pins it. (Its first version imported the legacy user with the
//    offline `geode user import`; after an offline mutation, the server's
//    later security-graph writes, statement or not, are lost to a SIGKILL,
//    and the next start may fail to load the security graph at all: a
//    storage recovery defect, SONNY-6384, fixed and pinned by
//    tests/test_sonny6384_offline_change_crash_durability.zig.)
//
// CANARY: REQ=REQ-SONNY-6377-SECURITY-RESIDUALS; FEATURE="RLS Expression Wiring"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6377_security_residuals.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const rls = @import("rls");
const auth = @import("geode_auth");
const rls_types = @import("rls_types");
const attr_store = @import("user_attr_store");
const cli_auth = @import("cli_auth_helpers");
const harness = @import("node_scan_stream_harness.zig");
const util = @import("proto_test_util.zig");

const RLSEngine = rls.RLSEngine;
const graph_store = geode.graph_store;
const user_mgmt = geode.user_management;
const execution = geode.execution;
const rls_dispatch = geode.execution.rls_dispatch;
const linux = std.os.linux;

// ---------------------------------------------------------------------------
// 3. A row-level RLS decision is not cached for the whole table
// ---------------------------------------------------------------------------

const role_user: auth.RoleId = 7;

const RowWorld = struct {
    engine: RLSEngine,
    user: auth.User,
    permissions: std.ArrayList(auth.PermissionId),
    roles: [1]auth.Role,
    context: auth.SecurityContext,

    fn init(self: *RowWorld) !void {
        self.engine = try RLSEngine.init(testing.allocator);
        errdefer self.engine.deinit();
        try self.engine.createPolicy(.{
            .id = 6377,
            .name = "team_a",
            .description = "SONNY-6377",
            .graph = "g6377",
            .table = "Doc6377",
            .operation = .all,
            .permissive = true,
            .roles = &.{role_user},
            .using_expr = .{ .raw = "row.team = 'a'", .parsed = null, .compiled = null, .parameters = &.{} },
            .check_expr = null,
            .enabled = true,
            .created_at = 0,
            .updated_at = 0,
            .created_by = 0,
            .temporal = null,
            .data_classification = null,
            .audit_level = .none,
        });
        self.user = .{
            .id = 9,
            .username = "bob",
            .email = "bob@example.com",
            .password_hash = undefined,
            .created_at = 0,
            .updated_at = 0,
            .last_login = null,
            .is_active = true,
            .is_superuser = false,
            .mfa_enabled = false,
            .mfa_secret = null,
            .attributes = std.StringHashMap([]const u8).init(testing.allocator),
        };
        self.permissions = .empty;
        self.roles = .{.{ .id = role_user, .name = "user", .description = "", .permissions = self.permissions, .created_at = 0, .is_system = false, .priority = 1, .parent_role = null }};
        self.context = .{
            .user = &self.user,
            .roles = &self.roles,
            .session_attributes = std.StringHashMap([]const u8).init(testing.allocator),
            .request_attributes = std.StringHashMap([]const u8).init(testing.allocator),
            .environment = .{ .timestamp = 0, .ip_address = "127.0.0.1", .user_agent = "test", .location = null, .device_id = null },
        };
    }

    fn deinit(self: *RowWorld) void {
        self.context.session_attributes.deinit();
        self.context.request_attributes.deinit();
        self.permissions.deinit(testing.allocator);
        self.user.attributes.deinit();
        self.engine.deinit();
    }

    fn check(self: *RowWorld, team: []const u8) !bool {
        var row = std.StringHashMap(rls.Value).init(testing.allocator);
        defer row.deinit();
        try row.put("team", .{ .string = team });
        return self.engine.checkRowAccess(&row, .select, &self.context, "g6377", "Doc6377");
    }
};

test "SONNY-6377 item 3: one denied row does not deny the table's other rows" {
    var w: RowWorld = undefined;
    try w.init();
    defer w.deinit();

    try testing.expect(!try w.check("b"));
    // The same user, table and operation; a row the policy admits.
    const second = try w.check("a");
    if (!second) {
        std.debug.print("a row the policy admits was denied after another row was denied (the per-row verdict was cached per table)\n", .{});
        return error.RowDecisionCachedForTable;
    }
    // And the reverse order.
    try testing.expect(try w.check("a"));
    try testing.expect(!try w.check("b"));
    try testing.expect(try w.check("a"));
}

// ---------------------------------------------------------------------------
// 4. Procedure results own their rows; policy_count with no engine is 55000
// ---------------------------------------------------------------------------

const StrictWorld = struct {
    h: harness.Harness,
    auth_was: bool,

    fn init(self: *StrictWorld) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        user_mgmt.deinitUserStore();
        try user_mgmt.initUserStore(testing.allocator);
        rls_dispatch.resetCallbacks();
        self.h.ctx.role = .Admin;
        self.h.ctx.user = "root6377";
    }

    fn deinit(self: *StrictWorld) void {
        rls_dispatch.resetCallbacks();
        user_mgmt.deinitUserStore();
        user_mgmt.setAuthEnabled(self.auth_was);
        self.h.deinit();
    }

    /// Run `q` with std.testing.allocator and free its result (a leak fails
    /// the test).
    fn run(self: *StrictWorld, q: []const u8) !void {
        var parsed = try geode.parseGqlOptions(q, testing.allocator, .{});
        defer parsed.deinit();
        var result = try execution.executeStatementWithContext(testing.allocator, parsed.program.statements[0], self.h.ctx);
        result.deinit(testing.allocator);
    }

    fn expectCode(self: *StrictWorld, q: []const u8, code: []const u8) !void {
        if (self.run(q)) |_| {
            std.debug.print("`{s}` answered 00000, want {s}\n", .{ q, code });
            return error.FailureReportedAsSuccess;
        } else |err| {
            const got = geode.proto_util.mapError(err).code;
            if (!std.mem.eql(u8, got, code)) std.debug.print("`{s}`: {s} ({s}), want {s}\n", .{ q, got, @errorName(err), code });
            try testing.expectEqualStrings(code, got);
        }
    }
};

const Listed = struct {
    fn list(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]rls_dispatch.ListedPolicy {
        const out = try allocator.alloc(rls_dispatch.ListedPolicy, 2);
        out[0] = .{ .graph = try allocator.dupe(u8, "g6377"), .label = try allocator.dupe(u8, "Secret"), .username = try allocator.dupe(u8, "bob") };
        out[1] = .{ .graph = try allocator.dupe(u8, "g6377"), .label = try allocator.dupe(u8, "Hidden"), .username = try allocator.dupe(u8, "") };
        return out;
    }
    fn count(_: ?*anyopaque) usize {
        return 2;
    }
};

test "SONNY-6377 item 4: user_import, list_deny_policies and policy_count results own their rows" {
    var w: StrictWorld = undefined;
    try w.init();
    defer w.deinit();

    try w.run("CALL geode.auth.user_import('imported6377', '$argon2id$v=19$m=65536,t=3,p=4$c2FsdHNhbHQ$aGFzaGhhc2hoYXNoaGFzaA', 'argon2id')");
    rls_dispatch.setCallbacks(.{ .ctx = null, .list_deny_fn = Listed.list, .policy_count_fn = Listed.count });
    try w.run("CALL geode.rls.list_deny_policies()");
    try w.run("CALL geode.rls.policy_count()");
}

test "SONNY-6377 item 4: policy_count and list_deny_policies with no filter engine answer 55000, not an empty answer" {
    var w: StrictWorld = undefined;
    try w.init();
    defer w.deinit();

    try w.expectCode("CALL geode.rls.policy_count()", "55000");
    try w.expectCode("CALL geode.rls.list_deny_policies()", "55000");
}

// ---------------------------------------------------------------------------
// 5. user_attribute_store.setAttribute under allocation failure
// ---------------------------------------------------------------------------

test "SONNY-6377 item 5: setAttribute leaves no half-built entry and keeps the old value when an allocation fails" {
    attr_store.resetForTesting(testing.allocator);
    // The old value of an existing attribute.
    try attr_store.setAttribute(testing.allocator, "keep6377", "dept", "eng");

    var fail_index: usize = 0;
    var failures: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        attr_store.setAllocatorForTesting(failing.allocator());

        // A new user's first attribute. The caller frees its username string
        // after the call, as a request would, so the store must own a copy.
        const name = try std.fmt.allocPrint(testing.allocator, "new6377_{d}", .{fail_index});
        const new_result = attr_store.setAttribute(testing.allocator, name, "dept", "eng");
        if (new_result) |_| {} else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            if (attr_store.get(name)) |attrs| {
                // Only a fully built, empty entry may remain.
                if (attrs.count() != 0) {
                    std.debug.print("fail_index {d}: a failed setAttribute left an entry whose attribute map is undefined (count {d})\n", .{ fail_index, attrs.count() });
                    attr_store.setAllocatorForTesting(testing.allocator);
                    return error.HalfBuiltEntry;
                }
            }
        }
        const probe = try testing.allocator.dupe(u8, name);
        defer testing.allocator.free(probe);
        @memset(name, '#');
        testing.allocator.free(name);
        if (new_result) |_| {
            const attrs = attr_store.get(probe) orelse return error.SetAttributeLost;
            try testing.expectEqualStrings("eng", attrs.get("dept").?);
        } else |_| {}

        // Replacing an existing attribute: a failure keeps the old value.
        failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        attr_store.setAllocatorForTesting(failing.allocator());
        if (attr_store.setAttribute(testing.allocator, "keep6377", "dept", "ops")) |_| {
            attr_store.setAllocatorForTesting(testing.allocator);
            try attr_store.setAttribute(testing.allocator, "keep6377", "dept", "eng");
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            const attrs = attr_store.get("keep6377") orelse return error.UserEntryLost;
            const v = attrs.get("dept") orelse {
                std.debug.print("fail_index {d}: a failed replacement removed the old value\n", .{fail_index});
                attr_store.setAllocatorForTesting(testing.allocator);
                return error.OldValueLost;
            };
            try testing.expectEqualStrings("eng", v);
        }
    }
    try testing.expect(failures > 0);
    attr_store.resetForTesting(testing.allocator);
}

// ---------------------------------------------------------------------------
// 6. Security-graph writes made outside a statement survive a SIGKILL
// ---------------------------------------------------------------------------

const binary_path = @import("geode_test_bin").geode_exe;
const admin_user = util.DefaultAuth.username;
const admin_pw = util.DefaultAuth.password;
const legacy_pw = "Amber Window Gentle Thunder Two";
const first_pw = "Copper Meadow Whisper Falcon One";
const second_pw = "Silver Harbor Quiet Lantern Three";
const third_pw = "Velvet Orchard Distant Comet Four";

fn nowMillis() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn skipWithoutBinary() !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), binary_path, .{}) catch return error.SkipZigTest;
}

fn freshDir(aa: std.mem.Allocator, tag: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny6377-{s}-{d}", .{ tag, nowMillis() });
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn removeDir(dir: []const u8) void {
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), dir) catch {};
}

/// `user`'s stored password hash, read offline.
fn storedHash(aa: std.mem.Allocator, dir: []const u8, user: []const u8) ![]const u8 {
    var process = std.heap.ArenaAllocator.init(testing.allocator);
    defer process.deinit();
    const pa = process.allocator();
    var mgr = try cli_auth.initCliAuthManager(pa, dir);
    defer {
        cli_auth.deinitAndSaveCliAuth(pa, &mgr);
        graph_store.deinitGlobalStore();
    }
    const r = mgr.storage.getUserByUsername(user) orelse return error.UserNotStored;
    return aa.dupe(u8, r.getPasswordHash());
}

fn legacyBlake2bHex(password: []const u8) [64]u8 {
    var h = std.crypto.hash.blake2.Blake2b256.init(.{});
    h.update(password);
    h.update("geode-salt-secure-v2");
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

const Server = struct {
    proc: util.ServerHandle,
    addr: []const u8,
    grpc_addr: []const u8,

    fn start(allocator: std.mem.Allocator, dir: []const u8) !Server {
        const addr = try util.formatAddr(allocator, try util.getRandomPort());
        errdefer allocator.free(addr);
        const grpc_addr = try util.formatAddr(allocator, try util.getRandomPort());
        errdefer allocator.free(grpc_addr);
        var proc = try util.spawnServer(allocator, &.{ binary_path, "serve", "--listen", addr, "--data-dir", dir, "--listen-grpc", grpc_addr }, util.TestEnv.grpcPlaintext());
        errdefer proc.deinit();
        try util.waitForServerReady(allocator, addr, 60_000);
        try util.waitForGrpcServerReady(allocator, grpc_addr, 60_000);
        return .{ .proc = proc, .addr = addr, .grpc_addr = grpc_addr };
    }

    /// SIGKILL: no shutdown flush. What the server acknowledged must already
    /// be durable.
    fn kill(self: *Server, allocator: std.mem.Allocator) void {
        self.proc.deinit();
        allocator.free(self.addr);
        allocator.free(self.grpc_addr);
    }
};

fn quicLogin(allocator: std.mem.Allocator, addr: []const u8, user: []const u8, pw: []const u8) !bool {
    var c = try util.QuicProtoClient.connect(allocator, addr);
    defer c.deinit();
    var h = try c.hello(allocator, user, pw);
    defer h.deinit(allocator);
    return h.success;
}

fn quicExec(allocator: std.mem.Allocator, addr: []const u8, user: []const u8, pw: []const u8, q: []const u8) !void {
    var c = try util.QuicProtoClient.connect(allocator, addr);
    defer c.deinit();
    var h = try c.hello(allocator, user, pw);
    defer h.deinit(allocator);
    if (!h.success) return error.LoginFailed;
    var r = try c.executeAndCollectWithTimeout(allocator, q, util.emptyParams(), 100, 60);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("`{s}` as {s}: {s} {?s}\n", .{ q, user, code, r.error_message });
        return error.QueryFailed;
    }
}

fn grpcExec(allocator: std.mem.Allocator, addr: []const u8, user: []const u8, pw: []const u8, q: []const u8) !void {
    var c = try util.GrpcProtoClient.connect(allocator, addr);
    defer c.deinit();
    var h = try c.hello(allocator, user, pw);
    defer h.deinit(allocator);
    if (!h.success) return error.LoginFailed;
    var r = try c.executeAndCollect(allocator, q, util.emptyParams(), 100);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("`{s}` as {s} over gRPC: {s} {?s}\n", .{ q, user, code, r.error_message });
        return error.QueryFailed;
    }
}

test "SONNY-6377 item 6: the login hash upgrade and the QUIC / gRPC ALTER USER intercepts are durable when they report success" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try skipWithoutBinary();
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try freshDir(aa, "durable");
    defer removeDir(dir);

    {
        var s = try Server.start(allocator, dir);
        defer s.kill(allocator);
        // Users created by a statement change their own passwords through
        // the QUIC intercept and the gRPC one (outside any statement).
        try quicExec(allocator, s.addr, admin_user, admin_pw, "CREATE USER carol6377 SET PASSWORD '" ++ first_pw ++ "' ROLE readwrite");
        try quicExec(allocator, s.addr, "carol6377", first_pw, "ALTER USER carol6377 SET PASSWORD '" ++ second_pw ++ "'");
        // SONNY-6782: the gRPC intercept is reachable in Debug only (plaintext gRPC).
        if (util.grpc_plaintext_served) {
            try quicExec(allocator, s.addr, admin_user, admin_pw, "CREATE USER dave6377 SET PASSWORD '" ++ first_pw ++ "' ROLE readwrite");
            try grpcExec(allocator, s.grpc_addr, "dave6377", first_pw, "ALTER USER dave6377 SET PASSWORD '" ++ third_pw ++ "'");
        }
        // A BLAKE2b-imported user (geode.auth.user_import, a statement); its
        // login replaces the legacy hash (outside any statement).
        const hex = legacyBlake2bHex(legacy_pw);
        const import_q = try std.fmt.allocPrint(aa, "CALL geode.auth.user_import('legacy6377', '{s}', 'blake2b', '', 'readwrite')", .{&hex});
        try quicExec(allocator, s.addr, admin_user, admin_pw, import_q);
        try testing.expect(try quicLogin(allocator, s.addr, "legacy6377", legacy_pw));
    }

    var violations: usize = 0;
    const after = try storedHash(aa, dir, "legacy6377");
    if (!std.mem.startsWith(u8, after, "$argon2id$")) {
        std.debug.print("after a SIGKILL the login's hash upgrade is gone (stored: {s})\n", .{after});
        violations += 1;
    }
    var s = try Server.start(allocator, dir);
    defer s.kill(allocator);
    if (!try quicLogin(allocator, s.addr, "carol6377", second_pw)) {
        std.debug.print("after a SIGKILL the QUIC ALTER USER password change is gone\n", .{});
        violations += 1;
    }
    if (try quicLogin(allocator, s.addr, "carol6377", first_pw)) violations += 1;
    if (util.grpc_plaintext_served) {
        if (!try quicLogin(allocator, s.addr, "dave6377", third_pw)) {
            std.debug.print("after a SIGKILL the gRPC ALTER USER password change is gone\n", .{});
            violations += 1;
        }
        if (try quicLogin(allocator, s.addr, "dave6377", first_pw)) violations += 1;
    }
    if (!try quicLogin(allocator, s.addr, "legacy6377", legacy_pw)) violations += 1;
    if (violations > 0) return error.SecurityWriteNotDurable;
}
