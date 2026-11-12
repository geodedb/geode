// SONNY-6341 regression: the FLE role is bound to the authenticated principal.
//
// The role a session reads encrypted fields with was whatever its client
// named in HELLO (`role=...`), checked for shape only. Since SONNY-6334
// plaintext also needs GPS decrypt_field, but every principal GPS lets
// decrypt (every Admin, any ALLOW DECRYPT_FIELD) could name ANY FLE role and
// read every field listed for it. A named role now counts only when the
// user holds it: `CALL geode.fle.grantRole(user, role)` (Admin only, audited,
// stored in the HMAC-chained security graph, loaded at startup). A HELLO
// naming a role the user does not hold still connects, with no FLE role, and
// is an access_denied audit event. Grants and revokes count from the next
// request of every live session. With authentication off the named role is
// used as before.
//
// gRPC through the real Execute/Pull handlers (SONNY-1560 shim) and the real
// HELLO role setter; QUIC and the CLI against the built server, restarted on
// its data directory; the security-graph records through AuthGraphManager.
//
// CANARY: REQ=REQ-SONNY-6341-FLE-ROLE-BINDING; FEATURE="FieldLevelEncryption"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6341_fle_role_binding.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");
const util = @import("proto_test_util.zig");
const cli = @import("cli_test_util.zig");
const auth_graph_manager_mod = @import("auth_graph_manager");

const execution = geode.execution;
const fle_integration = geode.fle_integration;
const fle_catalog = fle_integration.catalog_mod;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const audit = geode.security.audit;
const policy_catalog = geode.security.policy_catalog;
const principal_mod = geode.security.principal;
const proto_util = geode.proto_util;
const fle_role_grants = geode.security.fle_role_grants;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const master_key = "6341a6341a6341a6341a6341a6341a6341a6341a6341a6341a6341a6341a6341";
const secret = "SSN-6341-SECRET";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn expectStr(want: []const u8, got: []const u8, what: []const u8) !void {
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("{s}: got '{s}', expected '{s}'\n", .{ what, got, want });
        return error.WrongValue;
    }
}

fn expectSqlstate(err: anyerror, code: []const u8) !void {
    const info = proto_util.mapError(err);
    if (!std.mem.eql(u8, info.code, code)) {
        std.debug.print("{s} maps to {s}; expected {s}\n", .{ @errorName(err), info.code, code });
        return error.WrongSqlstate;
    }
}

fn principal(username: []const u8, roles: []const []const u8) principal_mod.Principal {
    return .{
        .user_id = 6341,
        .username = username,
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = roles,
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = 0,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .test_harness,
    };
}

const admin_roles = [_][]const u8{"Admin"};
const rw_roles = [_][]const u8{"ReadWrite"};
const ro_roles = [_][]const u8{"ReadOnly"};

const Who = struct {
    user: []const u8,
    role: user_mgmt.Role,
    roles: []const []const u8,
};

const admin: Who = .{ .user = "admin6341", .role = .Admin, .roles = &admin_roles };
const rw: Who = .{ .user = "rw6341", .role = .ReadWrite, .roles = &rw_roles };
const ro: Who = .{ .user = "ro6341", .role = .ReadOnly, .roles = &ro_roles };

/// The in-process persisted store and gRPC sessions with authentication ON,
/// an FLE master key, a policy catalog holding an ALLOW DECRYPT_FIELD for
/// everyone (so GPS is never what refuses below: the FLE role is), an audit
/// sink, and the three users in the user store.
const Env = struct {
    f: fx.Fixture,
    cat: policy_catalog.PolicyCatalog,
    logger: *audit.AuditLogger,
    sink_path: []u8,
    session: execution.SessionState,
    arena: std.heap.ArenaAllocator,

    fn init(self: *Env) !void {
        try self.f.init();
        errdefer self.f.deinit();
        _ = setenv("GEODE_MASTER_KEY", master_key, 1);
        fle_integration.resetGlobalKeyStateForTesting();
        // The process-global key manager on the process allocator (SONNY-2670).
        _ = try fle_integration.getCurrentKeyVersion(.{ .tenant_id = "default", .schema_name = "T6341", .allocator = std.heap.smp_allocator }, "init");
        fle_catalog.resetGlobalCatalog(testing.allocator);
        fle_integration.setHasEncryptedFields(false);
        fle_role_grants.resetForTesting();

        try user_mgmt.initUserStore(std.heap.c_allocator);
        for ([_]Who{ admin, rw, ro }) |w| {
            user_mgmt.createUser(std.heap.c_allocator, w.user, "pass-6341-xyz", "", w.role, false) catch |err| switch (err) {
                error.UserAlreadyExists => {},
                else => return err,
            };
        }
        user_mgmt.setAuthEnabled(true);
        gps.setInsecureAllowAll(false);

        self.cat = policy_catalog.PolicyCatalog.init(testing.allocator);
        policy_catalog.setGlobalCatalog(&self.cat);
        try self.cat.addPolicyStrict(.{ .name = "allow-decrypt-6341", .scope_graph = "*", .actions = &.{.decrypt_field}, .effect = .allow, .expression_source = "true", .enabled = true });

        self.sink_path = try std.fmt.allocPrint(testing.allocator, "{s}/audit6341.jsonl", .{self.f.h.data_dir});
        self.logger = try audit.AuditLogger.createHeap(testing.allocator, .{ .enabled = true, .file_path = self.sink_path });
        audit.setGlobalAuditLogger(self.logger);

        self.session = execution.SessionState.init(testing.allocator);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
    }

    fn deinit(self: *Env) void {
        fle_integration.clearCurrentThreadState();
        self.arena.deinit();
        self.session.deinit();
        audit.setGlobalAuditLogger(null);
        self.logger.deinit();
        testing.allocator.destroy(self.logger);
        testing.allocator.free(self.sink_path);
        policy_catalog.clearGlobalCatalog();
        self.cat.deinit();
        for ([_]Who{ admin, rw, ro }) |w| user_mgmt.deleteUser(w.user) catch {};
        fle_role_grants.resetForTesting();
        fle_catalog.resetGlobalCatalog(testing.allocator);
        fle_integration.setHasEncryptedFields(false);
        fle_integration.resetGlobalKeyStateForTesting();
        _ = unsetenv("GEODE_MASTER_KEY");
        self.f.deinit();
    }

    fn aa(self: *Env) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// A statement through the executor as `who` (no FLE role: the CALLs).
    fn exec(self: *Env, who: Who, query: []const u8) !execution.ExecutionResult {
        const p = principal(who.user, who.roles);
        const catalog = try execution.ensureCatalogInstance(testing.allocator);
        const ctx = execution.ExecutionContext{
            .catalog = catalog,
            .session_state = &self.session,
            .user = who.user,
            .role = who.role,
            .principal = &p,
        };
        var parsed = try geode.parseGqlOptions(query, self.aa(), .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.aa(), parsed.program.statements[0], ctx);
    }

    fn run(self: *Env, who: Who, query: []const u8) !void {
        _ = self.exec(who, query) catch |err| {
            std.debug.print("{s} as {s}: {s}\n", .{ query, who.user, @errorName(err) });
            return err;
        };
    }

    fn refusedWith(self: *Env, who: Who, query: []const u8) anyerror {
        if (self.exec(who, query)) |_| {
            std.debug.print("{s} as {s}: ran; expected a refusal\n", .{ query, who.user });
            return error.ExpectedRefusal;
        } else |err| return err;
    }

    fn sink(self: *Env) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(io(), self.sink_path, testing.allocator, .limited(4 << 20)) catch |err| switch (err) {
            error.FileNotFound => testing.allocator.dupe(u8, ""),
            else => err,
        };
    }

    /// T6341.ssn encrypted for FLE role `pii`; one node holding it.
    fn setupField(self: *Env) !void {
        try self.run(admin, "CALL geode.fle.configureField('T6341', 'ssn', {visibility: ['pii']})");
        try self.run(admin, "CREATE (:T6341 {k: 1, ssn: '" ++ secret ++ "'})");
    }

    /// A gRPC session of `who` whose HELLO named `fle_role`, through the
    /// handshake's own setter.
    fn grpcSession(self: *Env, who: Who, fle_role: ?[]const u8) ![]const u8 {
        const version = (try user_mgmt.currentAuthVersion(who.user)) orelse 0;
        const id = try self.f.sessions.createSession(who.user, "", who.role, null, null, false, version);
        try self.f.sessions.setSessionFleRole(id, fle_role);
        return id;
    }
};

/// The first row of `query` over gRPC (Execute, then Pull).
fn grpcRow(e: *Env, session: []const u8, query: []const u8) ![]schema.Value {
    const ga = e.f.ga();
    const resp = try fx.execute(ga, session, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |er| {
            std.debug.print("{s}: {s} {s}\n", .{ query, er.code, er.message });
            return error.QueryFailed;
        },
        else => {},
    }
    const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = session, .page_size = 16 });
    const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
    const presp = pull.response orelse return error.MissingPayload;
    return switch (presp.payload orelse return error.MissingPayload) {
        .page => |p| if (p.rows.items.len == 1) p.rows.items[0].values.items else error.UnexpectedRows,
        .@"error" => |er| {
            std.debug.print("pull {s}: {s} {s}\n", .{ query, er.code, er.message });
            return error.QueryFailed;
        },
        else => error.UnexpectedPayload,
    };
}

fn nodeProp(v: schema.Value, key: []const u8) ![]const u8 {
    for (v.kind.?.node_val.properties.items) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value.?.kind.?.string_val.value;
    }
    return error.NoSuchProperty;
}

fn strOf(v: schema.Value) []const u8 {
    return v.kind.?.string_val.value;
}

const read_q = "MATCH (n:T6341 {k: 1}) RETURN n.ssn AS v, n";

/// `n.ssn` and `RETURN n`'s ssn over gRPC for `session` equal `want`.
fn expectGrpcRead(e: *Env, session: []const u8, want: []const u8, what: []const u8) !void {
    const row = try grpcRow(e, session, read_q);
    try expectStr(want, strOf(row[0]), what);
    try expectStr(want, try nodeProp(row[1], "ssn"), what);
}

// ---------------------------------------------------------------------------
// The attack and the grant, over gRPC
// ---------------------------------------------------------------------------

test "SONNY-6341: over gRPC a ReadOnly user with ALLOW DECRYPT_FIELD naming FLE role 'pii' it was never granted reads [REDACTED]; an Admin likewise; the HELLO is audited" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.setupField();

    const s_ro = try e.grpcSession(ro, "pii");
    try expectGrpcRead(&e, s_ro, "[REDACTED]", "ro naming an ungranted pii");
    // The Admin builtin holds no FLE role implicitly.
    const s_admin = try e.grpcSession(admin, "pii");
    try expectGrpcRead(&e, s_admin, "[REDACTED]", "admin naming an ungranted pii");
    // No role left on this thread.
    try testing.expect(fle_integration.getCurrentUserRole() == null);

    const s = try e.sink();
    defer testing.allocator.free(s);
    try testing.expect(contains(s, "access_denied"));
    try testing.expect(contains(s, "fle role not held: pii"));
    try testing.expect(contains(s, "ro6341"));
    try testing.expect(!contains(s, secret));
    try testing.expect(!contains(s, master_key));
}

test "SONNY-6341: a granted user reads plaintext; grant and revoke count from the next request of an existing session" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.setupField();

    const s_ro = try e.grpcSession(ro, "pii");
    try expectGrpcRead(&e, s_ro, "[REDACTED]", "before the grant");

    try e.run(admin, "CALL geode.fle.grantRole('ro6341', 'pii')");
    try testing.expect(fle_role_grants.holds("ro6341", "pii"));
    // The same session, next request: plaintext.
    try expectGrpcRead(&e, s_ro, secret, "after the grant, same session");
    // A grant of another role does not open 'pii' to a session naming it.
    const s_rw = try e.grpcSession(rw, "pii");
    try e.run(admin, "CALL geode.fle.grantRole('rw6341', 'other')");
    try expectGrpcRead(&e, s_rw, "[REDACTED]", "rw holding 'other', naming pii");

    try e.run(admin, "CALL geode.fle.revokeRole('ro6341', 'pii')");
    try testing.expect(!fle_role_grants.holds("ro6341", "pii"));
    // The same live session, next request: redacted again.
    try expectGrpcRead(&e, s_ro, "[REDACTED]", "after the revoke, same session");

    // A dropped user holds nothing.
    try e.run(admin, "CALL geode.fle.grantRole('rw6341', 'pii')");
    try user_mgmt.deleteUser("rw6341");
    try testing.expect(!fle_role_grants.holds("rw6341", "pii"));
}

test "SONNY-6341: grantRole and revokeRole are Admin only (42501, audited), validated, and audited when they run" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();

    for ([_]Who{ ro, rw }) |who| {
        try expectSqlstate(e.refusedWith(who, "CALL geode.fle.grantRole('ro6341', 'pii')"), "42501");
        try expectSqlstate(e.refusedWith(who, "CALL geode.fle.revokeRole('ro6341', 'pii')"), "42501");
    }
    try testing.expect(!fle_role_grants.holds("ro6341", "pii"));
    // An unknown user, a role outside the HELLO alphabet, wrong arity.
    try expectSqlstate(e.refusedWith(admin, "CALL geode.fle.grantRole('nobody6341', 'pii')"), "42704");
    try expectSqlstate(e.refusedWith(admin, "CALL geode.fle.grantRole('ro6341', 'p;ii')"), "22023");
    try expectSqlstate(e.refusedWith(admin, "CALL geode.fle.grantRole('ro6341')"), "22023");

    try e.run(admin, "CALL geode.fle.grantRole('ro6341', 'auditor6341')");
    try e.run(admin, "CALL geode.fle.revokeRole('ro6341', 'auditor6341')");

    const s = try e.sink();
    defer testing.allocator.free(s);
    try testing.expect(contains(s, "geode.fle.grantrole"));
    try testing.expect(contains(s, "geode.fle.revokerole"));
    try testing.expect(contains(s, "access_denied"));
    try testing.expect(contains(s, "rw6341"));
    try testing.expect(contains(s, "user=ro6341 role=auditor6341"));
    try testing.expect(contains(s, "admin6341"));
}

fn failGrant(_: ?*anyopaque, _: []const u8, _: []const u8) anyerror!void {
    return error.NoSpaceLeft;
}
fn failRevoke(_: ?*anyopaque, _: []const u8, _: []const u8) anyerror!bool {
    return error.NoSpaceLeft;
}

test "SONNY-6341: a grant that cannot be saved is not applied (58030); a revoke that cannot be saved stays in force and says so (58030)" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.setupField();
    const s_ro = try e.grpcSession(ro, "pii");

    try e.run(admin, "CALL geode.fle.grantRole('ro6341', 'pii')");
    fle_role_grants.setPersistence(.{ .ctx = null, .grant_fn = &failGrant, .revoke_fn = &failRevoke });
    try expectSqlstate(e.refusedWith(admin, "CALL geode.fle.grantRole('ro6341', 'late6341')"), "58030");
    try testing.expect(!fle_role_grants.holds("ro6341", "late6341"));

    try expectSqlstate(e.refusedWith(admin, "CALL geode.fle.revokeRole('ro6341', 'pii')"), "58030");
    try testing.expect(!fle_role_grants.holds("ro6341", "pii"));
    try expectGrpcRead(&e, s_ro, "[REDACTED]", "revoke not saved, still in force");

    const s = try e.sink();
    defer testing.allocator.free(s);
    try testing.expect(contains(s, "FleRoleGrantNotPersisted"));
    try testing.expect(contains(s, "FleRoleRevokeNotPersisted"));
}

test "SONNY-6341: with authentication off the named FLE role is used as before" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.setupField();
    user_mgmt.setAuthEnabled(false);
    const s = try e.f.session("anon6341");
    try e.f.sessions.setSessionFleRole(s, "pii");
    try expectGrpcRead(&e, s, secret, "auth off, pii named");
    const s2 = try e.f.session("anon6341b");
    try e.f.sessions.setSessionFleRole(s2, "other");
    try expectGrpcRead(&e, s2, "[REDACTED]", "auth off, other named");
}

// ---------------------------------------------------------------------------
// The security-graph records
// ---------------------------------------------------------------------------

const HMAC_KEY = [_]u8{0x63} ** 32;

test "SONNY-6341: FLE role grants are FleRoleGrant records sealed by the auth HMAC chain; they reload and a tampered one fails verification" {
    const graph_store = geode.graph_store;
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    var mgr = try auth_graph_manager_mod.AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    const uid = try mgr.createUser(&HMAC_KEY, "carol6341", "c@x", "fakehash", false);
    try mgr.grantUserFleRole(&HMAC_KEY, uid, "pii");
    try mgr.grantUserFleRole(&HMAC_KEY, uid, "pii"); // idempotent
    try mgr.grantUserFleRole(&HMAC_KEY, uid, "hr");
    try mgr.verifyChain(&HMAC_KEY);
    {
        var reloaded = try auth_graph_manager_mod.AuthGraphManager.init(testing.allocator, &store);
        defer reloaded.deinit();
        try reloaded.verifyChain(&HMAC_KEY);
        const list = try reloaded.listFleRoleGrants(testing.allocator);
        defer testing.allocator.free(list);
        try testing.expectEqual(@as(usize, 2), list.len);
        for (list) |g| try testing.expectEqual(uid, g.user_id);
    }
    try testing.expect(try mgr.revokeUserFleRole(&HMAC_KEY, uid, "hr"));
    try testing.expect(!try mgr.revokeUserFleRole(&HMAC_KEY, uid, "hr"));
    try mgr.verifyChain(&HMAC_KEY);

    // A record edited behind the chain's back (the role renamed) fails.
    var it = mgr.storage.fle_role_grant_nodes.valueIterator();
    const node_id = it.next().?.*;
    try store.setNodeProperty(node_id, "role", .{ .String = "admin" });
    try testing.expectError(error.RecordHmacMismatch, mgr.verifyChain(&HMAC_KEY));
    try store.setNodeProperty(node_id, "role", .{ .String = "pii" });
    try mgr.verifyChain(&HMAC_KEY);

    // DROP USER takes the user's grants.
    try mgr.revokeAllUserFleRoles(&HMAC_KEY, uid);
    try testing.expectEqual(@as(u32, 0), mgr.storage.fle_role_grant_nodes.count());
    try mgr.verifyChain(&HMAC_KEY);
}

// ---------------------------------------------------------------------------
// QUIC and the CLI against the built server, across a restart; the
// documented end-to-end example (docs/FIELD_LEVEL_ENCRYPTION.md)
// ---------------------------------------------------------------------------

fn quicStr(client: *util.QuicProtoClient, query: []const u8) ![]u8 {
    var r = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 100);
    defer r.deinit(testing.allocator);
    if (r.error_code) |c| {
        std.debug.print("{s}: {s}\n", .{ query, c });
        return error.UnexpectedStatus;
    }
    if (r.rows.len != 1) return error.UnexpectedRows;
    return switch (r.rows[0][0]) {
        .string => |s| testing.allocator.dupe(u8, s),
        else => error.UnexpectedValue,
    };
}

fn quicOk(client: *util.QuicProtoClient, query: []const u8) !void {
    var r = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 100);
    defer r.deinit(testing.allocator);
    if (r.error_code) |c| {
        std.debug.print("{s}: {s}\n", .{ query, c });
        return error.UnexpectedStatus;
    }
}

fn expectQuic(client: *util.QuicProtoClient, query: []const u8, want: []const u8, what: []const u8) !void {
    const got = try quicStr(client, query);
    defer testing.allocator.free(got);
    try expectStr(want, got, what);
}

const Server = struct {
    handle: util.ServerHandle,
    addr: []u8,

    fn start(data_dir: []const u8) !Server {
        const allocator = testing.allocator;
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var handle = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--data-dir", data_dir }, &.{"GEODE_MASTER_KEY=" ++ master_key});
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .handle = handle, .addr = addr };
    }

    fn stop(self: *Server) void {
        self.handle.deinit();
        testing.allocator.free(self.addr);
    }

    fn client(self: *Server, user: []const u8, pass: []const u8, fle_role: []const u8) !util.QuicProtoClient {
        var c = try util.QuicProtoClient.connect(testing.allocator, self.addr);
        errdefer c.deinit();
        var h = try c.helloAs(testing.allocator, user, pass, fle_role);
        defer h.deinit(testing.allocator);
        if (!h.success) return error.HelloRefused;
        return c;
    }

    /// `geode query` as the docs run it, with `--role`.
    fn cliQuery(self: *Server, user: []const u8, pass: []const u8, fle_role: ?[]const u8, gql: []const u8) ![]u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(testing.allocator);
        try argv.appendSlice(testing.allocator, &.{ "./zig-out/bin/geode", "query", "-U", user, "-P", pass });
        if (fle_role) |r| try argv.appendSlice(testing.allocator, &.{ "--role", r });
        try argv.append(testing.allocator, gql);
        const res = try cli.runAgainstServer(testing.allocator, self.addr, argv.items);
        defer testing.allocator.free(res.err);
        if (res.code != 0) {
            std.debug.print("geode query ({d}): {s}\n", .{ res.code, res.err });
            testing.allocator.free(res.out);
            return error.CliFailed;
        }
        return res.out;
    }
};

test "SONNY-6341: over QUIC and the CLI an Admin naming an FLE role it does not hold reads [REDACTED]; the documented grant makes the documented example true, and it survives a restart; a revoke does too" {
    const allocator = testing.allocator;
    var dir_buf: [64]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-6341-{d}", .{std.os.linux.getpid()});
    std.Io.Dir.cwd().deleteTree(io(), data_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io(), data_dir);
    defer std.Io.Dir.cwd().deleteTree(io(), data_dir) catch {};
    const admin_user = util.defaultUsername();
    const admin_pass = util.defaultPassword();
    const q = "MATCH (p:Person {user_id:'P001'}) RETURN p.ssn AS ssn";

    {
        var server = try Server.start(data_dir);
        defer server.stop();
        var a = try server.client(admin_user, admin_pass, "admin");
        defer a.deinit();
        // docs/FIELD_LEVEL_ENCRYPTION.md, "End-to-end example", steps 1-3.
        try quicOk(&a, "CALL geode.fle.configureField('Person', 'ssn', { algorithm: 'AES-256-GCM', visibility: ['admin'] })");
        try quicOk(&a, "CREATE USER pii_reader SET PASSWORD 'reader-pass-123' ROLE readonly");
        try quicOk(&a, "CREATE (p:Person { user_id: 'P001', ssn: '" ++ secret ++ "', city: 'Denver' })");

        // The attack: the Admin (GPS allows it decrypt_field) names 'admin',
        // which it was never granted.
        try expectQuic(&a, q, "[REDACTED]", "quic admin, ungranted 'admin'");
        const before = try server.cliQuery(admin_user, admin_pass, "admin", q);
        defer allocator.free(before);
        try testing.expect(!contains(before, secret));

        // The documented migration: the Admin grants itself the FLE role.
        try quicOk(&a, "CALL geode.fle.grantRole('geode', 'admin')");
        // The same session, next request.
        try expectQuic(&a, q, secret, "quic admin after grantRole, same session");
        // Step 4a as documented.
        const after = try server.cliQuery(admin_user, admin_pass, "admin", q);
        defer allocator.free(after);
        try testing.expect(contains(after, secret));
        // Without --role: no FLE role, redacted.
        const no_role = try server.cliQuery(admin_user, admin_pass, null, q);
        defer allocator.free(no_role);
        try testing.expect(!contains(no_role, secret));
        // Step 4b: the readonly user naming 'admin' reads the row, not the value.
        const reader = try server.cliQuery("pii_reader", "reader-pass-123", "admin", "MATCH (p:Person {user_id:'P001'}) RETURN p.ssn AS ssn, p.city AS city");
        defer allocator.free(reader);
        try testing.expect(!contains(reader, secret));
        try testing.expect(contains(reader, "Denver"));
        // A non-admin cannot grant.
        var r = try server.client("pii_reader", "reader-pass-123", "admin");
        defer r.deinit();
        var res = try r.executeAndCollect(allocator, "CALL geode.fle.grantRole('pii_reader', 'admin')", util.emptyParams(), 10);
        defer res.deinit(allocator);
        try testing.expectEqualStrings("42501", res.error_code orelse "00000");
    }
    {
        // Restarted on the same data directory: the grant was stored.
        var server = try Server.start(data_dir);
        defer server.stop();
        var a = try server.client(admin_user, admin_pass, "admin");
        defer a.deinit();
        try expectQuic(&a, q, secret, "quic admin after restart");
        try quicOk(&a, "CALL geode.fle.revokeRole('geode', 'admin')");
        try expectQuic(&a, q, "[REDACTED]", "quic admin after revokeRole, same session");
    }
    {
        // And the revoke was stored.
        var server = try Server.start(data_dir);
        defer server.stop();
        var a = try server.client(admin_user, admin_pass, "admin");
        defer a.deinit();
        try expectQuic(&a, q, "[REDACTED]", "quic admin after revoke and restart");
    }
}
