// SONNY-6334 regression: FLE authorization.
//
// (1) The mutating FLE procedures (geode.fle.configureField, grantPlaintext,
//     revokePlaintext) and the key-affecting tde.* procedures were gated by
//     the GPS `.write` action, so a ReadWrite user could grant its own FLE
//     role plaintext access (or reconfigure a field). They are security
//     administration: Admin only, 42501 and an access_denied audit event for
//     anyone else, the catalog unchanged in memory and on disk.
// (2) The plaintext decision was the FLE catalog's role list alone; the GPS
//     `decrypt_field` gate (fle_hooks.decryptPropertyIfNeeded) had no caller,
//     so a DENY DECRYPT_FIELD policy was never consulted, and a client could
//     name any FLE role in HELLO. Plaintext now needs both: the request's FLE
//     role in the field's list AND GPS allowing decrypt_field for the
//     authenticated principal.
// (3) The gRPC server never put the session's FLE role on the thread that
//     encodes results (Pull), and its Handshake left the role on the
//     Handshake's thread. Both transports now install one request context
//     (`ServerState.installRequestThreadState`) and clear it on every exit.
// (4) grant/revoke/configure were log lines only; they are audit events
//     (success and failure).
//
// The executor tests run through `execution.executeStatementWithContext` with
// authentication on; the gRPC tests through the real Execute/Pull handlers
// (SONNY-1560 shim) with authentication on; the QUIC test spawns the built
// server and speaks QUIC.
//
// CANARY: REQ=REQ-SONNY-6334-FLE-AUTHZ; FEATURE="FieldLevelEncryption"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6334_fle_authorization.zig; OWNER=security; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");
const util = @import("proto_test_util.zig");

const execution = geode.execution;
const fle_integration = geode.fle_integration;
const fle_catalog = fle_integration.catalog_mod;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const audit = geode.security.audit;
const policy_catalog = geode.security.policy_catalog;
const principal_mod = geode.security.principal;
const proto_util = geode.proto_util;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const master_key = "6334a6334a6334a6334a6334a6334a6334a6334a6334a6334a6334a6334a6334";
const secret = "SSN-6334-SECRET";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn principal(username: []const u8, roles: []const []const u8) principal_mod.Principal {
    return .{
        .user_id = 6334,
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

/// Who runs a statement: the authenticated role and principal, and the FLE
/// role the session named.
const Who = struct {
    user: []const u8,
    role: user_mgmt.Role,
    roles: []const []const u8,
    fle_role: ?[]const u8,
};

const admin_pii: Who = .{ .user = "admin6334", .role = .Admin, .roles = &admin_roles, .fle_role = "pii" };
const rw_pii: Who = .{ .user = "rw6334", .role = .ReadWrite, .roles = &rw_roles, .fle_role = "pii" };
const ro_pii: Who = .{ .user = "ro6334", .role = .ReadOnly, .roles = &ro_roles, .fle_role = "pii" };
const rw_own: Who = .{ .user = "rw6334", .role = .ReadWrite, .roles = &rw_roles, .fle_role = "rw_own" };
const ro_none: Who = .{ .user = "ro6334", .role = .ReadOnly, .roles = &ro_roles, .fle_role = null };

/// The in-process persisted store and gRPC sessions (fx.Fixture), with
/// authentication ON, --insecure-allow-all OFF, an FLE master key, a policy
/// catalog and an audit sink. The FLE catalog lives in the store's data
/// directory.
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
        user_mgmt.setAuthEnabled(true);
        gps.setInsecureAllowAll(false);
        _ = setenv("GEODE_MASTER_KEY", master_key, 1);
        fle_integration.resetGlobalKeyStateForTesting();
        // The process-global key manager, built on the process allocator
        // (never a request arena: it outlives every query; SONNY-2670).
        _ = try fle_integration.getCurrentKeyVersion(.{ .tenant_id = "default", .schema_name = "T6334", .allocator = std.heap.smp_allocator }, "init");
        fle_catalog.resetGlobalCatalog(testing.allocator);
        fle_integration.setHasEncryptedFields(false);
        // SONNY-6341: a session acts under an FLE role its user holds. The
        // principals below hold the roles they name (this file tests the
        // GPS half of the decision; the role binding is SONNY-6341's).
        geode.security.fle_role_grants.resetForTesting();
        for ([_]Who{ admin_pii, rw_pii, ro_pii, rw_own }) |w| try geode.security.fle_role_grants.load(w.user, w.fle_role.?);
        try geode.security.fle_role_grants.load("admin6334", "other");
        try geode.security.fle_role_grants.load("ro6334", "other");

        self.cat = policy_catalog.PolicyCatalog.init(testing.allocator);
        policy_catalog.setGlobalCatalog(&self.cat);

        self.sink_path = try std.fmt.allocPrint(testing.allocator, "{s}/audit6334.jsonl", .{self.f.h.data_dir});
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
        geode.security.fle_role_grants.resetForTesting();
        fle_catalog.resetGlobalCatalog(testing.allocator);
        fle_integration.setHasEncryptedFields(false);
        fle_integration.resetGlobalKeyStateForTesting();
        _ = unsetenv("GEODE_MASTER_KEY");
        self.f.deinit();
    }

    fn aa(self: *Env) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// A statement through the executor as `who`, with the request's FLE
    /// role on the context (GAP-0852) as both transports set it.
    fn exec(self: *Env, who: Who, query: []const u8) !execution.ExecutionResult {
        const p = principal(who.user, who.roles);
        const catalog = try execution.ensureCatalogInstance(testing.allocator);
        const ctx = execution.ExecutionContext{
            .catalog = catalog,
            .session_state = &self.session,
            .user = who.user,
            .role = who.role,
            .principal = &p,
            .fle_role = who.fle_role,
        };
        var parsed = try geode.parseGqlOptions(query, self.aa(), .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.aa(), parsed.program.statements[0], ctx);
    }

    fn run(self: *Env, who: Who, query: []const u8) !execution.ExecutionResult {
        return self.exec(who, query) catch |err| {
            std.debug.print("{s} as {s}: {s}\n", .{ query, who.user, @errorName(err) });
            return err;
        };
    }

    fn str(self: *Env, who: Who, query: []const u8) ![]const u8 {
        const res = try self.run(who, query);
        if (res.rows.len != 1) return error.UnexpectedRows;
        return switch (res.rows[0][0]) {
            .Str => |s| s,
            else => error.UnexpectedValue,
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

    /// The FLE catalog file's bytes ("" when there is none).
    fn catalogBytes(self: *Env) ![]u8 {
        const path = (try fle_catalog.catalogFilePath(testing.allocator)) orelse return error.ExpectedPersistedCatalog;
        defer testing.allocator.free(path);
        _ = self;
        return std.Io.Dir.cwd().readFileAlloc(io(), path, testing.allocator, .limited(4 << 20)) catch |err| switch (err) {
            error.FileNotFound => testing.allocator.dupe(u8, ""),
            else => err,
        };
    }

    /// Field T6334.ssn encrypted, plaintext role `pii`, one node holding it.
    fn setupField(self: *Env) !void {
        _ = try self.run(admin_pii, "CALL geode.fle.configureField('T6334', 'ssn', {visibility: ['pii']})");
        _ = try self.run(admin_pii, "CREATE (:T6334 {k: 1, ssn: '" ++ secret ++ "'})");
    }
};

fn expectSqlstate(err: anyerror, code: []const u8) !void {
    const info = proto_util.mapError(err);
    if (!std.mem.eql(u8, info.code, code)) {
        std.debug.print("{s} maps to {s}; expected {s}\n", .{ @errorName(err), info.code, code });
        return error.WrongSqlstate;
    }
}

fn expectStr(want: []const u8, got: []const u8, what: []const u8) !void {
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("{s}: got '{s}', expected '{s}'\n", .{ what, got, want });
        return error.WrongValue;
    }
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

const read_q = "MATCH (n:T6334 {k: 1}) RETURN n.ssn AS v";

// ---------------------------------------------------------------------------
// (1) + (4): FLE administration is Admin only, and audited
// ---------------------------------------------------------------------------

test "SONNY-6334 (1)(4): configureField, grantPlaintext and revokePlaintext are Admin only; refusals are 42501 with an access_denied audit event and change nothing in memory or on disk" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.setupField();
    const catalog = try fle_catalog.globalCatalog(testing.allocator);
    const before = try e.catalogBytes();
    defer testing.allocator.free(before);
    try testing.expect(before.len > 0);

    const mutating = [_][]const u8{
        "CALL geode.fle.configureField('T6334', 'ssn', {visibility: ['rw_own']})",
        "CALL geode.fle.configureField('T6334', 'other', {visibility: ['rw_own']})",
        "CALL geode.fle.grantPlaintext('T6334', 'ssn', 'rw_own')",
        "CALL geode.fle.revokePlaintext('T6334', 'ssn', 'pii')",
    };
    for ([_]Who{ ro_pii, rw_pii }) |who| {
        for (mutating) |q| {
            const err = e.refusedWith(who, q);
            try expectSqlstate(err, "42501");
        }
    }
    // Nothing changed, in memory or on disk.
    try testing.expect(catalog.hasVisibilityRole("T6334", "ssn", "pii"));
    try testing.expect(!catalog.hasVisibilityRole("T6334", "ssn", "rw_own"));
    try testing.expect(!catalog.isFieldEncrypted("T6334", "other"));
    const after = try e.catalogBytes();
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);

    // The key-affecting tde.* procedures are Admin only too.
    try expectSqlstate(e.refusedWith(rw_pii, "CALL tde.rotate_keys()"), "42501");
    try expectSqlstate(e.refusedWith(rw_pii, "CALL tde.zeroize_keys()"), "42501");

    // Reads of the configuration stay open to any authenticated reader, and
    // name no roles.
    const cfg = try e.run(ro_none, "CALL geode.fle.getFieldConfig('T6334', 'ssn')");
    try testing.expectEqual(@as(usize, 1), cfg.rows.len);
    for (cfg.columns) |c| try testing.expect(!contains(c, "role") and !contains(c, "visib"));
    const list = try e.run(ro_none, "CALL geode.fle.listEncryptedFields('T6334')");
    try testing.expectEqual(@as(usize, 1), list.rows.len);
    for (list.columns) |c| try testing.expect(!contains(c, "role") and !contains(c, "visib"));

    // Admin may.
    _ = try e.run(admin_pii, "CALL geode.fle.grantPlaintext('T6334', 'ssn', 'auditor6334')");
    _ = try e.run(admin_pii, "CALL geode.fle.revokePlaintext('T6334', 'ssn', 'auditor6334')");
    try testing.expect(!catalog.hasVisibilityRole("T6334", "ssn", "auditor6334"));

    // Audit: each refusal names the procedure and the caller; each change is
    // an event naming the type.field and role; no key material.
    const s = try e.sink();
    defer testing.allocator.free(s);
    try testing.expect(contains(s, "access_denied"));
    try testing.expect(contains(s, "geode.fle.grantplaintext"));
    try testing.expect(contains(s, "geode.fle.revokeplaintext"));
    try testing.expect(contains(s, "geode.fle.configurefield"));
    try testing.expect(contains(s, "tde.rotate_keys"));
    try testing.expect(contains(s, "rw6334"));
    try testing.expect(contains(s, "ro6334"));
    try testing.expect(contains(s, "T6334.ssn"));
    try testing.expect(contains(s, "auditor6334"));
    try testing.expect(contains(s, "admin6334"));
    try testing.expect(!contains(s, master_key));
    try testing.expect(!contains(s, secret));
}

test "SONNY-6334 (4): a configureField or grant whose save fails is audited as a failure" {
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.setupField();
    // The data directory read-only: the next save fails (58030).
    const dir_z = try testing.allocator.dupeZ(u8, e.f.h.data_dir);
    defer testing.allocator.free(dir_z);
    const chmod = struct {
        extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
    }.chmod;
    try testing.expectEqual(@as(c_int, 0), chmod(dir_z.ptr, 0o500));
    defer _ = chmod(dir_z.ptr, 0o700);
    try expectSqlstate(e.refusedWith(admin_pii, "CALL geode.fle.grantPlaintext('T6334', 'ssn', 'late6334')"), "58030");
    _ = chmod(dir_z.ptr, 0o700);
    const s = try e.sink();
    defer testing.allocator.free(s);
    try testing.expect(contains(s, "late6334"));
    try testing.expect(contains(s, "FleCatalogNotPersisted"));
    try testing.expect(contains(s, "failure"));
}

// ---------------------------------------------------------------------------
// (1)+(2): the self-grant attack fails end to end
// ---------------------------------------------------------------------------

test "SONNY-6334 (1)(2): a ReadWrite user cannot obtain plaintext: it cannot grant its own FLE role, and naming a listed FLE role is not enough" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.setupField();

    try expectStr("[REDACTED]", try e.str(rw_own, read_q), "rw before the attempt");
    try expectSqlstate(e.refusedWith(rw_own, "CALL geode.fle.grantPlaintext('T6334', 'ssn', 'rw_own')"), "42501");
    try expectStr("[REDACTED]", try e.str(rw_own, read_q), "rw after the refused self-grant");
    // A session naming the listed FLE role 'pii' (a client-asserted HELLO
    // role) is not Admin and holds no decrypt_field allow: redacted.
    try expectStr("[REDACTED]", try e.str(rw_pii, read_q), "rw naming pii");
    // Admin with the listed role reads it.
    try expectStr(secret, try e.str(admin_pii, read_q), "admin with pii");
}

// ---------------------------------------------------------------------------
// (2): plaintext = FLE role in the list AND GPS decrypt_field
// ---------------------------------------------------------------------------

test "SONNY-6334 (2): the plaintext decision table (FLE role list x GPS decrypt_field)" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.setupField();
    const admin_nopii: Who = .{ .user = "admin6334", .role = .Admin, .roles = &admin_roles, .fle_role = "other" };

    // Admin (builtin decrypt_field allow): role in list -> plaintext; not -> redacted.
    try expectStr(secret, try e.str(admin_pii, read_q), "admin, in list");
    try expectStr("[REDACTED]", try e.str(admin_nopii, read_q), "admin, not in list");
    // ReadOnly / ReadWrite without an allow policy: redacted even in the list.
    try expectStr("[REDACTED]", try e.str(ro_pii, read_q), "ro, in list, no allow");
    try expectStr("[REDACTED]", try e.str(rw_pii, read_q), "rw, in list, no allow");

    // An ALLOW DECRYPT_FIELD policy: ReadOnly in the list reads plaintext;
    // ReadOnly not in the list does not.
    try e.cat.addPolicyStrict(.{ .name = "allow-decrypt-6334", .scope_graph = "*", .actions = &.{.decrypt_field}, .effect = .allow, .expression_source = "true", .enabled = true });
    try expectStr(secret, try e.str(ro_pii, read_q), "ro, in list, allow");
    const ro_other: Who = .{ .user = "ro6334", .role = .ReadOnly, .roles = &ro_roles, .fle_role = "other" };
    try expectStr("[REDACTED]", try e.str(ro_other, read_q), "ro, not in list, allow");

    // A DENY DECRYPT_FIELD overrides the allow and the Admin shortcut, for a
    // principal whose role IS in the list.
    try e.cat.addPolicyStrict(.{ .name = "deny-decrypt-6334", .scope_graph = "*", .actions = &.{.decrypt_field}, .effect = .deny, .expression_source = "true", .enabled = true });
    try expectStr("[REDACTED]", try e.str(admin_pii, read_q), "admin, in list, deny");
    try expectStr("[REDACTED]", try e.str(ro_pii, read_q), "ro, in list, allow+deny");
    // The whole value over gRPC (Pull encodes it) says the same.
    const s_admin = try grpcSession(&e, admin_pii);
    const row = try grpcRow(&e, s_admin, "MATCH (n:T6334 {k: 1}) RETURN n.ssn AS v, n");
    try expectStr("[REDACTED]", strOf(row[0]), "grpc admin, deny");
    try testing.expect(!contains(try nodeProp(row[1], "ssn"), secret));

    // The deny removed: Admin reads it again.
    try e.cat.removePolicy("deny-decrypt-6334");
    try expectStr(secret, try e.str(admin_pii, read_q), "admin, deny removed");
}

test "SONNY-6334 (2): a searchable field refused by GPS is 42501 on member access, as for a role not in the list" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    const catalog = try fle_catalog.globalCatalog(testing.allocator);
    var roles = [_][]const u8{"pii"};
    try catalog.configureField("S6334", .{ .field_name = "ssn", .encryption = .{ .enabled = true }, .search = .{ .enabled = true }, .visibility = .{ .to_roles = &roles } });
    fle_integration.setHasEncryptedFields(true);
    // The process-global blind index is made by its first user with that
    // user's allocator: make it here on the process allocator, not on a
    // request arena (SONNY-2670).
    std.heap.smp_allocator.free(try fle_integration.encryptFieldIfNeeded(.{ .tenant_id = "default", .schema_name = "S6334", .allocator = std.heap.smp_allocator }, "S6334", "ssn", "warm", "0"));
    _ = try e.run(admin_pii, "CREATE (:S6334 {k: 1, ssn: 'x'})");
    try expectSqlstate(e.refusedWith(ro_pii, "MATCH (n:S6334 {k: 1}) RETURN n.ssn AS v"), "42501");
}

// ---------------------------------------------------------------------------
// (3): gRPC sets the FLE request context like QUIC, and leaks none
// ---------------------------------------------------------------------------

/// A gRPC session as `who` with authentication on: the session's
/// authenticated user and role, and the FLE role its HELLO named.
fn grpcSession(e: *Env, who: Who) ![]const u8 {
    const id = try e.f.sessions.createSession(who.user, "", who.role, null, null, false, 0);
    const entry = e.f.sessions.acquire(id) orelse return error.NoSession;
    defer e.f.sessions.release(entry);
    if (who.fle_role) |r| entry.state.fle_user_role = try entry.state.allocator.dupe(u8, r);
    return id;
}

/// The first row's values of `query` over gRPC (Execute, then Pull: Pull
/// encodes the rows).
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

test "SONNY-6334 (3): over gRPC the session's FLE role decides as over the executor (QUIC), whole values included, and no request leaves a role on its thread" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.setupField();

    const s_admin = try grpcSession(&e, admin_pii);
    const s_ro = try grpcSession(&e, ro_pii);
    const s_none = try grpcSession(&e, ro_none);

    // Admin naming pii: plaintext, member access and whole node.
    const a = try grpcRow(&e, s_admin, "MATCH (n:T6334 {k: 1}) RETURN n.ssn AS v, n");
    try expectStr(secret, strOf(a[0]), "grpc admin n.ssn");
    try expectStr(secret, try nodeProp(a[1], "ssn"), "grpc admin RETURN n");
    // The request left no FLE role on this thread.
    try testing.expect(fle_integration.getCurrentUserRole() == null);

    // ReadOnly naming pii (no decrypt_field allow): redacted, as over the executor.
    const r = try grpcRow(&e, s_ro, "MATCH (n:T6334 {k: 1}) RETURN n.ssn AS v, n");
    try expectStr(try e.str(ro_pii, read_q), strOf(r[0]), "grpc ro vs executor ro");
    try expectStr("[REDACTED]", strOf(r[0]), "grpc ro n.ssn");
    try testing.expect(!contains(try nodeProp(r[1], "ssn"), secret));

    // An Admin request with plaintext, then a session with no FLE role on
    // the same thread: the second sees no plaintext.
    _ = try grpcRow(&e, s_admin, "MATCH (n:T6334 {k: 1}) RETURN n");
    const n = try grpcRow(&e, s_none, "MATCH (n:T6334 {k: 1}) RETURN n.ssn AS v, n");
    try expectStr("[REDACTED]", strOf(n[0]), "grpc no-role after admin");
    try testing.expect(!contains(try nodeProp(n[1], "ssn"), secret));
    try testing.expect(fle_integration.getCurrentUserRole() == null);

    // A ReadWrite gRPC session cannot grant itself plaintext.
    const s_rw = try grpcSession(&e, rw_own);
    const err = try fx.expectRefused(e.f.ga(), s_rw, "CALL geode.fle.grantPlaintext('T6334', 'ssn', 'rw_own')", "42501");
    _ = err;
}

// ---------------------------------------------------------------------------
// (1)(2)(3) over QUIC: the built server
// ---------------------------------------------------------------------------

fn quicStatus(client: *util.QuicProtoClient, query: []const u8) ![]u8 {
    var r = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 100);
    defer r.deinit(testing.allocator);
    const code = r.error_code orelse "00000";
    return testing.allocator.dupe(u8, code);
}

fn quicOk(client: *util.QuicProtoClient, query: []const u8) !void {
    const code = try quicStatus(client, query);
    defer testing.allocator.free(code);
    if (!std.mem.eql(u8, code, "00000")) {
        std.debug.print("{s}: {s}\n", .{ query, code });
        return error.UnexpectedStatus;
    }
}

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

test "SONNY-6334 (1)(2)(3): over QUIC a ReadWrite user naming the listed FLE role reads no plaintext and cannot grant itself; Admin reads it" {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr }, &.{"GEODE_MASTER_KEY=" ++ master_key});
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);

    var admin = try util.QuicProtoClient.connect(allocator, addr);
    defer admin.deinit();
    var h = try admin.helloAs(allocator, util.defaultUsername(), util.defaultPassword(), "pii");
    defer h.deinit(allocator);
    try testing.expect(h.success);
    try quicOk(&admin, "CALL geode.fle.configureField('Q6334', 'ssn', {visibility: ['pii']})");
    try quicOk(&admin, "CREATE (:Q6334 {k: 1, ssn: '" ++ secret ++ "'})");
    try quicOk(&admin, "CREATE USER rw6334 SET PASSWORD 'rw6334-pass-123' ROLE readwrite");
    // SONNY-6341: the admin acts under 'pii' once granted it; rw6334 names
    // 'pii' below without a grant.
    try quicOk(&admin, "CALL geode.fle.grantRole('geode', 'pii')");
    const as_admin = try quicStr(&admin, "MATCH (n:Q6334 {k: 1}) RETURN n.ssn AS v");
    defer allocator.free(as_admin);
    try expectStr(secret, as_admin, "quic admin");

    var rw = try util.QuicProtoClient.connect(allocator, addr);
    defer rw.deinit();
    var h2 = try rw.helloAs(allocator, "rw6334", "rw6334-pass-123", "pii");
    defer h2.deinit(allocator);
    try testing.expect(h2.success);
    const as_rw = try quicStr(&rw, "MATCH (n:Q6334 {k: 1}) RETURN n.ssn AS v");
    defer allocator.free(as_rw);
    try expectStr("[REDACTED]", as_rw, "quic rw naming pii");
    const grant = try quicStatus(&rw, "CALL geode.fle.grantPlaintext('Q6334', 'ssn', 'rw_own')");
    defer allocator.free(grant);
    try testing.expectEqualStrings("42501", grant);
}
