// SONNY-6331: one password policy on every path that sets a password.
//
// docs/USER_AUTH.md section 2 documents the policy (at least 20 characters,
// upper and lower case, at least 3 space-separated words; the length and word
// limits raised by GEODE_PASSWORD_MIN_LENGTH / GEODE_PASSWORD_MIN_WORDS), and
// `PasswordPolicy.validate` implements it for the offline CLI and the forced
// reset. Before the fix, on the server:
//   - CREATE USER / geode.auth.user_create applied an older rule (8
//     characters, a letter and a digit), answered with a message naming it;
//   - ALTER USER ... SET PASSWORD (geode.auth.user_reset_password) and
//     geode.auth.user_change_password checked nothing: any password, an
//     empty one included;
//   - the policy's messages always said "minimum 20 characters" / "at least 3
//     words", whatever the configured limits;
//   - the passwords the server generates (user_create's placeholder, the
//     first-boot admin) were hex strings the policy refuses;
//   - a first-boot GEODE_ADMIN_PASSWORD that broke the policy was taken with
//     no forced reset, although the docs list it as a reset trigger.
//
// The statements run through the in-process gRPC Execute handler with
// authorization on (an Admin session), the user store wired to a real
// `__geode_security` AuthGraphManager as `server_init` wires it.
//
// CANARY: REQ=REQ-SONNY-6331-ONE-PASSWORD-POLICY; FEATURE="Unified Password Policy Validation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6331_password_policy_paths.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");
const auth_graph_manager_mod = @import("auth_graph_manager");
const geode_auth = @import("geode_auth");

const graph_store = geode.graph_store;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;

const HMAC_KEY = [_]u8{0x31} ** 32;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const policy_env = [_][:0]const u8{ "GEODE_PASSWORD_MIN_LENGTH", "GEODE_PASSWORD_MIN_WORDS", "GEODE_ADMIN_PASSWORD", "GEODE_DEFAULT_PASSWORD", "GEODE_ADMIN_USERNAME" };

fn clearEnv() void {
    for (policy_env) |name| _ = unsetenv(name.ptr);
}

fn setEnv(name: [:0]const u8, value: [:0]const u8) !void {
    if (setenv(name.ptr, value.ptr, 1) != 0) return error.SetEnvFailed;
}

const GOOD = "Correct Horse Battery Staple";
const GOOD2 = "Another Correct Horse Battery";

fn agmOf(ctx: ?*anyopaque) *AuthGraphManager {
    return @ptrCast(@alignCast(ctx.?));
}

/// `server_init.writerCreateUser`.
fn writerCreateUser(ctx: ?*anyopaque, username: []const u8, email: []const u8, password_hash: []const u8, role: user_mgmt.Role) anyerror!void {
    const agm = agmOf(ctx);
    _ = try agm.createUserWithRole(&agm.hmac_key, username, email, password_hash, role == .Admin, if (role == .Admin) null else role.toString());
}

/// Authorization on, a `__geode_security` store with the user-store writer
/// wired to it, and an Admin session.
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
        clearEnv();
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        _ = graph_store.getGlobalStore(testing.allocator);
        _ = geode.txn_undo_log.getGlobalUndoLog(testing.allocator);
        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        self.allow_was = gps.isInsecureAllowAll();
        gps.setInsecureAllowAll(false);

        self.sec_store = try graph_store.GraphStore.init(testing.allocator);
        self.agm = try AuthGraphManager.init(testing.allocator, &self.sec_store);
        self.agm.hmac_key = HMAC_KEY;
        AuthGraphManager.setGlobal(&self.agm);

        user_mgmt.deinitUserStore();
        try user_mgmt.initUserStore(testing.allocator);
        user_mgmt.setPersistentUserWriter(.{ .ctx = @ptrCast(&self.agm), .create_fn = &writerCreateUser });

        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
        self.admin = try self.sessions.createSession("root6331", "", .Admin, null, null, false, 0);
    }

    fn deinit(self: *World) void {
        grpc.setSessionStore(null);
        self.sessions.deinit();
        self.arena.deinit();
        user_mgmt.setPersistentUserWriter(null);
        user_mgmt.deinitUserStore();
        AuthGraphManager.setGlobal(null);
        self.agm.deinit();
        self.sec_store.deinit();
        gps.setInsecureAllowAll(self.allow_was);
        user_mgmt.setAuthEnabled(self.auth_was);
        geode.txn_undo_log.setThreadTxnId(0);
        self.h.deinit();
        clearEnv();
    }

    fn ga(self: *World) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// The statement is refused with 22000 and `message`, which does not
    /// contain `password`.
    fn expectPolicyRefusal(self: *World, query: []const u8, password: []const u8, message: []const u8) !void {
        const err = try fx.expectRefused(self.ga(), self.admin, query, "22000");
        if (!std.mem.eql(u8, message, err.message)) std.debug.print("{s}: message \"{s}\", want \"{s}\"\n", .{ query, err.message, message });
        try testing.expectEqualStrings(message, err.message);
        if (password.len > 0) try testing.expect(std.mem.indexOf(u8, err.message, password) == null);
    }

    fn canLogIn(_: *World, username: []const u8, password: []const u8) bool {
        _ = user_mgmt.authenticate(username, password) catch return false;
        return true;
    }
};

/// The first string column of the first row a statement returned.
fn firstRow(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) ![]const ?[]const u8 {
    const resp = try fx.execute(ga, session_id, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("{s}: refused {s} {s}\n", .{ query, e.code, e.message });
            return error.Refused;
        },
        else => {},
    }
    const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = session_id, .page_size = 16 });
    const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
    const page = switch ((pull.response orelse return error.MissingPayload).payload orelse return error.MissingPayload) {
        .page => |p| p,
        else => return error.UnexpectedPayload,
    };
    if (page.rows.items.len == 0) return error.NoRows;
    const row = page.rows.items[0];
    const vals = try ga.alloc(?[]const u8, row.values.items.len);
    for (row.values.items, 0..) |v, i| {
        vals[i] = if (v.kind) |k| switch (k) {
            .string_val => |s| s.value,
            else => null,
        } else null;
    }
    return vals;
}

// ---------------------------------------------------------------------------
// CREATE USER / geode.auth.user_create
// ---------------------------------------------------------------------------

test "SONNY-6331: CREATE USER applies the documented policy, names the broken rule, and creates nothing" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    // The old rule's examples: 8+ characters with a letter and a digit.
    try w.expectPolicyRefusal("CREATE USER carol SET PASSWORD 'Alice123!'", "Alice123!", "Password too short (minimum 20 characters)");
    try w.expectPolicyRefusal("CREATE USER carol SET PASSWORD 'sneaky12345'", "sneaky12345", "Password too short (minimum 20 characters)");
    try w.expectPolicyRefusal("CREATE USER carol SET PASSWORD 'all lower case words here'", "all lower case words here", "Password must contain at least one uppercase letter");
    try w.expectPolicyRefusal("CREATE USER carol SET PASSWORD 'ALL UPPER CASE WORDS HERE'", "ALL UPPER CASE WORDS HERE", "Password must contain at least one lowercase letter");
    try w.expectPolicyRefusal("CREATE USER carol SET PASSWORD 'CorrectHorseBatteryStaple1'", "CorrectHorseBatteryStaple1", "Password must be a passphrase with at least 3 words");
    try w.expectPolicyRefusal("CALL geode.auth.user_create('carol', 'Alice123!')", "Alice123!", "Password too short (minimum 20 characters)");
    try testing.expect(user_mgmt.getUser("carol") == null);
    try testing.expect((try w.agm.findUserIdByName("carol")) == null);

    const status = try firstRow(w.ga(), w.admin, "CREATE USER carol SET PASSWORD '" ++ GOOD ++ "'");
    try testing.expectEqualStrings("created carol", status[0].?);
    try testing.expect(w.canLogIn("carol", GOOD));
    try testing.expect((try w.agm.findUserIdByName("carol")) != null);
}

test "SONNY-6331: the refusal names the configured limits (GEODE_PASSWORD_MIN_LENGTH / _MIN_WORDS)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    try setEnv("GEODE_PASSWORD_MIN_LENGTH", "32");
    try w.expectPolicyRefusal("CREATE USER carol SET PASSWORD '" ++ GOOD ++ "'", GOOD, "Password too short (minimum 32 characters)");
    try setEnv("GEODE_PASSWORD_MIN_LENGTH", "20");
    try setEnv("GEODE_PASSWORD_MIN_WORDS", "5");
    try w.expectPolicyRefusal("CREATE USER carol SET PASSWORD '" ++ GOOD ++ "'", GOOD, "Password must be a passphrase with at least 5 words");
    try testing.expect(user_mgmt.getUser("carol") == null);
    try fx.expectRuns(w.ga(), w.admin, "CREATE USER carol SET PASSWORD 'Correct Horse Battery Staple Again'");
}

test "SONNY-6331: user_create's generated password meets the policy and logs in" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    const row = try firstRow(w.ga(), w.admin, "CALL geode.auth.user_create('dave', 'auto_generated_password_placeholder')");
    try testing.expectEqualStrings("created dave", row[0].?);
    const generated = row[2] orelse return error.NoGeneratedPassword;
    try testing.expectEqual(@as(?[]const u8, null), geode_auth.PasswordPolicy.geodeSecure().validate(generated));
    try testing.expect(w.canLogIn("dave", generated));
}

// ---------------------------------------------------------------------------
// ALTER USER SET PASSWORD / user_reset_password / user_change_password
// ---------------------------------------------------------------------------

/// The GQL statement through the executor's statement dispatch, as an Admin
/// (ALTER USER ... SET PASSWORD of ANOTHER user: the QUIC / gRPC password
/// intercept answers that one with 42501 before the parser, so this is the
/// route an embedded or MCP caller takes; admin_ddl.executeAlterUser).
fn gqlAsAdmin(w: *World, query: []const u8) !void {
    var parsed = try geode.parseGql(query, testing.allocator);
    defer parsed.deinit();
    var ctx = w.h.ctx;
    ctx.role = .Admin;
    ctx.user = "root6331";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try geode.execution.executeStatementWithContext(arena.allocator(), parsed.program.statements[0], ctx);
}

test "SONNY-6331: ALTER USER SET PASSWORD (GQL) and user_reset_password apply the policy; the old password stays" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try fx.expectRuns(w.ga(), w.admin, "CREATE USER carol SET PASSWORD '" ++ GOOD ++ "'");

    try testing.expectError(error.PasswordTooShort, gqlAsAdmin(&w, "ALTER USER carol SET PASSWORD 'short1'"));
    try testing.expectError(error.PasswordNotPassphrase, gqlAsAdmin(&w, "ALTER USER carol SET PASSWORD 'onewordbutlongenoughHere'"));
    try testing.expectError(error.PasswordMissingUppercase, gqlAsAdmin(&w, "ALTER USER carol SET PASSWORD 'no upper case letters here'"));
    try w.expectPolicyRefusal("CALL geode.auth.user_reset_password('carol', '')", "", "Password too short (minimum 20 characters)");
    try w.expectPolicyRefusal("CALL geode.auth.user_reset_password('carol', 'x')", "x", "Password too short (minimum 20 characters)");
    try w.expectPolicyRefusal("CALL geode.auth.user_reset_password('carol', 'onewordbutlongenoughHere')", "onewordbutlongenoughHere", "Password must be a passphrase with at least 3 words");
    try testing.expect(w.canLogIn("carol", GOOD));
    try testing.expect(!w.canLogIn("carol", "short1"));
    try testing.expect(!w.canLogIn("carol", ""));

    try gqlAsAdmin(&w, "ALTER USER carol SET PASSWORD '" ++ GOOD2 ++ "'");
    try testing.expect(w.canLogIn("carol", GOOD2));
}

test "SONNY-6331: geode.auth.user_change_password applies the policy" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try fx.expectRuns(w.ga(), w.admin, "CREATE USER carol SET PASSWORD '" ++ GOOD ++ "'");

    try w.expectPolicyRefusal("CALL geode.auth.user_change_password('carol', '" ++ GOOD ++ "', 'weakpass9')", "weakpass9", "Password too short (minimum 20 characters)");
    try w.expectPolicyRefusal("CALL geode.auth.user_change_password('carol', '" ++ GOOD ++ "', '')", "", "Password too short (minimum 20 characters)");
    try testing.expect(w.canLogIn("carol", GOOD));
    try fx.expectRuns(w.ga(), w.admin, "CALL geode.auth.user_change_password('carol', '" ++ GOOD ++ "', '" ++ GOOD2 ++ "')");
    try testing.expect(w.canLogIn("carol", GOOD2));
}

test "SONNY-6331: a user whose stored password predates the policy still logs in (no lockout)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    // A record stored before the policy applied (an import, an upgrade).
    const hash = try user_mgmt.hashPassword(testing.allocator, "Alice123!");
    defer testing.allocator.free(hash);
    try user_mgmt.createUserWithHash(testing.allocator, "legacy", hash, "l@x", .User, false);
    try testing.expect(w.canLogIn("legacy", "Alice123!"));
    // The next change of it is held to the policy.
    try w.expectPolicyRefusal("CALL geode.auth.user_reset_password('legacy', 'Bobby123!')", "Bobby123!", "Password too short (minimum 20 characters)");
    try testing.expect(w.canLogIn("legacy", "Alice123!"));
}

// ---------------------------------------------------------------------------
// The policy's own messages and the first-boot admin
// ---------------------------------------------------------------------------

test "SONNY-6331: PasswordPolicy.validate names the configured limits" {
    defer clearEnv();
    clearEnv();
    try testing.expectEqualStrings("Password too short (minimum 20 characters)", geode_auth.PasswordPolicy.geodeSecure().validate("Short One Two").?);
    try setEnv("GEODE_PASSWORD_MIN_LENGTH", "40");
    try setEnv("GEODE_PASSWORD_MIN_WORDS", "6");
    try testing.expectEqualStrings("Password too short (minimum 40 characters)", geode_auth.PasswordPolicy.geodeSecure().validate(GOOD).?);
    try testing.expectEqualStrings("Password must be a passphrase with at least 6 words", geode_auth.PasswordPolicy.geodeSecure().validate("Correctly Horsing Batteries Staplers Extended").?);
}

fn bootstrapPersistent(env_password: ?[:0]const u8) !struct { reset: bool, password_ok: bool } {
    clearEnv();
    defer clearEnv();
    if (env_password) |pw| try setEnv("GEODE_ADMIN_PASSWORD", pw);
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();
    const b = try mgr.bootstrapDefaultAdmin(&HMAC_KEY);
    defer testing.allocator.free(b.username);
    defer testing.allocator.free(b.password);
    const user = mgr.storage.getUser(b.user_id) orelse return error.UserNotFound;
    return .{
        .reset = user.password_reset_required,
        .password_ok = geode_auth.PasswordPolicy.geodeSecure().validate(b.password) == null,
    };
}

test "SONNY-6331: first-boot admin (persistent store): a seed that breaks the policy forces a reset; a generated one meets it" {
    // Generated: meets the policy, reset forced (the operator reads it once).
    const gen = try bootstrapPersistent(null);
    try testing.expect(gen.password_ok);
    try testing.expect(gen.reset);
    // A weak seed is taken (the server boots) but only to set a new one.
    const weak = try bootstrapPersistent("GeodeTestPassword123!");
    try testing.expect(weak.reset);
    // A compliant seed: no reset.
    const good = try bootstrapPersistent(GOOD);
    try testing.expect(!good.reset);
}

test "SONNY-6331: first-boot admin (in-memory user store): a seed that breaks the policy forces a reset; a generated one meets it" {
    clearEnv();
    defer clearEnv();
    defer user_mgmt.deinitUserStore();

    user_mgmt.deinitUserStore();
    try user_mgmt.initUserStore(testing.allocator);
    try setEnv("GEODE_ADMIN_PASSWORD", "GeodeTestPassword123!");
    try user_mgmt.ensureDefaultUser(testing.allocator);
    const weak = user_mgmt.getUser("geode") orelse return error.UserNotFound;
    try testing.expect(weak.password_reset_required);
    _ = user_mgmt.authenticate("geode", "GeodeTestPassword123!") catch |e| {
        // The seed still authenticates (into the forced reset).
        if (e != error.PasswordResetRequired) return e;
    };

    user_mgmt.deinitUserStore();
    try user_mgmt.initUserStore(testing.allocator);
    try setEnv("GEODE_ADMIN_PASSWORD", GOOD);
    try user_mgmt.ensureDefaultUser(testing.allocator);
    const good = user_mgmt.getUser("geode") orelse return error.UserNotFound;
    try testing.expect(!good.password_reset_required);
}
