// SONNY-6347 regression: FLE store envelope check and record identity.
//
// (2) The graph-store write primitives (setNodeProperty, setNodePropertiesBatch,
//     setEdgeProperty, setEdgePropertiesBatch) skipped encryption for any
//     string shaped like an FLE envelope (graph_store.isLikelyFleEnvelope:
//     algorithm byte 1-3 and a length field that matches). A crafted
//     plaintext of that shape reaching a primitive outside the executor (a
//     raft payload, an internal caller) was stored unencrypted. Now a value
//     is kept as stored only when it authenticates as this record's field
//     envelope (AEAD under the field key and the record identity); anything
//     else is encrypted.
// (5) The encryption identity used the writer's request tenant, so a parent
//     tenant reading a child tenant's encrypted row (allowed by the tenant
//     hierarchy, GAP-0846) failed to decrypt (58030). The identity now uses
//     the record's stored tenant; values written under the writer's request
//     tenant still decrypt.
//
// Through the executor (executeStatementWithContext) and the graph-store
// primitives on the in-process persisted store.
//
// CANARY: REQ=REQ-SONNY-6347-FLE-ENVELOPE-IDENTITY; FEATURE="FieldLevelEncryption"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6347_fle_envelope_identity.zig; OWNER=security; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls = @import("rls");
const rls_types = @import("rls_types");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const execution = geode.execution;
const fle_integration = geode.fle_integration;
const fle_catalog = fle_integration.catalog_mod;
const graph_store = geode.graph_store;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const master_key = "6347a6347a6347a6347a6347a6347a6347a6347a6347a6347a6347a6347a6347";
const secret = "SSN-6347-SECRET";

fn expectStr(want: []const u8, got: []const u8, what: []const u8) !void {
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("{s}: got '{s}', expected '{s}'\n", .{ what, got, want });
        return error.WrongValue;
    }
}

/// A plaintext the old shape heuristic took for an envelope: algorithm byte
/// 1, a 30-byte "nonce/version" region, then a little-endian length that
/// matches the rest, which carries the secret in the clear.
fn craftedEnvelopeShape() [35 + secret.len]u8 {
    var buf: [35 + secret.len]u8 = undefined;
    @memset(&buf, 'A');
    buf[0] = 1;
    std.mem.writeInt(u32, buf[31..35], secret.len, .little);
    @memcpy(buf[35..], secret);
    return buf;
}

/// The persisted in-process store, authentication off (implicit admin: the
/// FLE role list alone decides), an FLE master key, a published expr-RLS
/// engine whose tenant hierarchy the test provisions.
const Env = struct {
    f: fx.Fixture,
    session: execution.SessionState,
    arena: std.heap.ArenaAllocator,
    engine: *rls.RLSEngine,

    fn init(self: *Env) !void {
        try self.f.init();
        errdefer self.f.deinit();
        _ = setenv("GEODE_MASTER_KEY", master_key, 1);
        fle_integration.resetGlobalKeyStateForTesting();
        // Process-lifetime key manager (SONNY-2670 workaround).
        _ = try fle_integration.getCurrentKeyVersion(.{ .tenant_id = "default", .schema_name = "T6347", .allocator = std.heap.smp_allocator }, "init");
        fle_catalog.resetGlobalCatalog(testing.allocator);
        fle_integration.setHasEncryptedFields(false);
        self.engine = try testing.allocator.create(rls.RLSEngine);
        self.engine.* = try rls.RLSEngine.init(testing.allocator);
        rls_types.setGlobalExprRLSEngine(@ptrCast(self.engine));
        self.session = execution.SessionState.init(testing.allocator);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
    }

    fn deinit(self: *Env) void {
        fle_integration.clearCurrentThreadState();
        self.arena.deinit();
        self.session.deinit();
        rls_types.setGlobalExprRLSEngine(null);
        self.engine.deinit();
        testing.allocator.destroy(self.engine);
        fle_catalog.resetGlobalCatalog(testing.allocator);
        fle_integration.setHasEncryptedFields(false);
        fle_integration.resetGlobalKeyStateForTesting();
        _ = unsetenv("GEODE_MASTER_KEY");
        self.f.deinit();
    }

    fn exec(self: *Env, fle_role: ?[]const u8, tenant: ?[]const u8, query: []const u8) !execution.ExecutionResult {
        const catalog = try execution.ensureCatalogInstance(testing.allocator);
        const ctx = execution.ExecutionContext{
            .catalog = catalog,
            .session_state = &self.session,
            .fle_role = fle_role,
            .tenant_id = tenant,
        };
        var parsed = try geode.parseGqlOptions(query, self.arena.allocator(), .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.arena.allocator(), parsed.program.statements[0], ctx);
    }

    fn run(self: *Env, tenant: ?[]const u8, query: []const u8) !void {
        _ = self.exec("pii", tenant, query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
    }

    fn str(self: *Env, tenant: ?[]const u8, query: []const u8) ![]const u8 {
        const res = self.exec("pii", tenant, query) catch |err| {
            std.debug.print("{s} (tenant {s}): {s}\n", .{ query, tenant orelse "-", @errorName(err) });
            return err;
        };
        if (res.rows.len != 1) {
            std.debug.print("{s} (tenant {s}): {d} rows\n", .{ query, tenant orelse "-", res.rows.len });
            return error.UnexpectedRows;
        }
        return switch (res.rows[0][0]) {
            .Str => |s| s,
            else => error.UnexpectedValue,
        };
    }

    fn encrypt(self: *Env, type_name: []const u8, field: []const u8) !void {
        _ = self;
        const catalog = try fle_catalog.globalCatalog(testing.allocator);
        var roles = [_][]const u8{"pii"};
        try catalog.configureField(type_name, .{ .field_name = field, .encryption = .{ .enabled = true }, .visibility = .{ .to_roles = &roles } });
        fle_integration.setHasEncryptedFields(true);
    }

    fn onlyNode(self: *Env, label: []const u8) !u64 {
        const ids = self.f.st.getNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, label) orelse return error.NoNodes;
        if (ids.len != 1) return error.UnexpectedNodes;
        return ids[0];
    }
};

fn expectNotInClear(stored: []const u8, what: []const u8) !void {
    if (std.mem.indexOf(u8, stored, secret) != null) {
        std.debug.print("{s}: the secret is stored in the clear ({d} bytes)\n", .{ what, stored.len });
        return error.StoredInPlaintext;
    }
}

// ---------------------------------------------------------------------------
// (2) a string shaped like an envelope is not taken for one
// ---------------------------------------------------------------------------

test "SONNY-6347 (2): a crafted envelope-shaped node value reaching setNodeProperty is encrypted, and reads back as written" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.encrypt("T6347", "ssn");
    try e.run(null, "CREATE (:T6347 {k: 1})");
    const id = try e.onlyNode("T6347");

    const crafted = craftedEnvelopeShape();
    try e.f.st.setNodeProperty(id, "ssn", .{ .String = &crafted });
    try expectNotInClear(e.f.st.getNodeProperty(id, "ssn").?.String, "setNodeProperty");
    try expectStr(&crafted, try e.str(null, "MATCH (n:T6347) RETURN n.ssn"), "read back");
}

test "SONNY-6347 (2): a crafted envelope-shaped value reaching the batch primitive is encrypted" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.encrypt("T6347", "ssn");
    try e.run(null, "CREATE (:T6347 {k: 1})");
    const id = try e.onlyNode("T6347");

    const crafted = craftedEnvelopeShape();
    const props = [_]graph_store.GraphStore.BatchPropertyEntry{.{ .key = "ssn", .value = .{ .String = &crafted } }};
    try e.f.st.setNodePropertiesBatch(id, &props);
    try expectNotInClear(e.f.st.getNodeProperty(id, "ssn").?.String, "setNodePropertiesBatch");
    try expectStr(&crafted, try e.str(null, "MATCH (n:T6347) RETURN n.ssn"), "read back");
}

test "SONNY-6347 (2): a crafted envelope-shaped edge value reaching setEdgeProperty is encrypted" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.encrypt("R6347", "p");
    try e.run(null, "CREATE (:A6347)-[:R6347 {k: 1}]->(:B6347)");
    const edges = e.f.st.getEdgesByType(testing.allocator, "R6347", null, graph_store.DEFAULT_GRAPH_NAME);
    defer testing.allocator.free(edges);
    try testing.expectEqual(@as(usize, 1), edges.len);

    const crafted = craftedEnvelopeShape();
    try e.f.st.setEdgeProperty(edges[0], "p", .{ .String = &crafted });
    const edge = e.f.st.getEdgeHydrated(edges[0]).?;
    try expectNotInClear(edge.properties.get("p").?.String, "setEdgeProperty");
    try expectStr(&crafted, try e.str(null, "MATCH ()-[r:R6347]->() RETURN r.p"), "read back");
}

test "SONNY-6347 (2): an executor write is encrypted once (the store keeps the executor's envelope)" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.encrypt("T6347", "ssn");
    try e.run(null, "CREATE (:T6347 {ssn: '" ++ secret ++ "'})");
    try e.run(null, "MATCH (n:T6347) SET n.ssn = '" ++ secret ++ "-2'");
    try expectStr(secret ++ "-2", try e.str(null, "MATCH (n:T6347) RETURN n.ssn"), "executor write");
    try expectNotInClear(e.f.st.getNodeProperty(try e.onlyNode("T6347"), "ssn").?.String, "executor write");
}

// ---------------------------------------------------------------------------
// (5) the record's tenant is the encryption identity
// ---------------------------------------------------------------------------

test "SONNY-6347 (5): a parent tenant reads its child tenant's encrypted row in plaintext; the child still does" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.engine.hierarchy_manager.addTenant("org6347", null);
    try e.engine.hierarchy_manager.addTenant("unit6347", "org6347");
    try e.encrypt("T6347", "ssn");

    try e.run("unit6347", "CREATE (:T6347 {k: 1, ssn: '" ++ secret ++ "'})");
    try expectStr(secret, try e.str("unit6347", "MATCH (n:T6347 {k: 1}) RETURN n.ssn"), "child reads its row");
    try expectStr(secret, try e.str("org6347", "MATCH (n:T6347 {k: 1}) RETURN n.ssn"), "parent reads the child's row");

    // A parent's SET on the child's row is readable by both.
    try e.run("org6347", "MATCH (n:T6347 {k: 1}) SET n.ssn = '" ++ secret ++ "-P'");
    try expectStr(secret ++ "-P", try e.str("unit6347", "MATCH (n:T6347 {k: 1}) RETURN n.ssn"), "child reads the parent's SET");
    try expectStr(secret ++ "-P", try e.str("org6347", "MATCH (n:T6347 {k: 1}) RETURN n.ssn"), "parent reads its SET");
}

test "SONNY-6347 (5): a value encrypted under the writer's request tenant (before the fix) is kept as stored and still decrypts" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.engine.hierarchy_manager.addTenant("org6347", null);
    try e.engine.hierarchy_manager.addTenant("unit6347", "org6347");
    try e.encrypt("T6347", "ssn");
    try e.run("unit6347", "CREATE (:T6347 {k: 1})");
    const id = try e.onlyNode("T6347");

    // The old identity: the writer's request tenant ("org6347"), not the
    // record's ("unit6347"), as a parent's SET wrote it before the fix.
    var id_buf: [32]u8 = undefined;
    const record_id = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
    const old = try fle_integration.encryptFieldIfNeeded(.{ .tenant_id = "org6347", .schema_name = "T6347", .allocator = testing.allocator }, "T6347", "ssn", secret, record_id);
    defer testing.allocator.free(old);

    // Written back by the store primitive under that request tenant (an
    // undo, a replay): an authentic envelope is kept, not encrypted again.
    fle_integration.setCurrentTenantId("org6347");
    try e.f.st.setNodeProperty(id, "ssn", .{ .String = old });
    fle_integration.setCurrentTenantId(null);
    try testing.expectEqualSlices(u8, old, e.f.st.getNodeProperty(id, "ssn").?.String);
    try expectStr(secret, try e.str("org6347", "MATCH (n:T6347 {k: 1}) RETURN n.ssn"), "request-tenant identity");
}
