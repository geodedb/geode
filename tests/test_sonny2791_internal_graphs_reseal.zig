// SONNY-2791 regression (round-7 review P40).
//
// (a) The engine's own graphs (`__geode_security`, every `__geode_*` name)
// are never a session's graph, and no statement creates or drops one. After
// SONNY-2775 an Admin could still `USE GRAPH __geode_security` (or SESSION
// SET [PROPERTY] GRAPH it) and write :Policy nodes there directly, and any
// writer could `DROP GRAPH __geode_security`. HELLO could bind it too.
//
// (b) The recovery reseal (`geode auth reseal`, GEODE_AUTH_RESEAL_CHAIN=1)
// signed every record as it stood. A policy record planted in the pre-kind
// GPS shape with no USING text (probe R7-K2) broke the chain; the reseal
// signed it, and GPS then loaded it as "allow write, for everyone". So did
// the seal after every auth change, e.g. an offline `geode user
// reset-password`, which loads the security graph as it is. No seal now signs
// a record without a kind whose HMAC does not verify. Only the recovery
// reseal does, on the operator's decision for its id: drop it, or accept it,
// which stores its kind and USING text, so nothing is "true by absence".
//
// CANARY: REQ=REQ-SONNY-2791-INTERNAL-GRAPHS; FEATURE="GraphRBACEnforcement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2791_internal_graphs_reseal.zig; OWNER=security; UPDATED=2026-09-26

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const util = @import("proto_test_util.zig");
const auth_hmac = @import("auth_lib").hmac;
const auth_graph_manager = @import("auth_graph_manager");
const policy_persistence = @import("policy_persistence");
const user_storage = @import("user_storage");

const execution = geode.execution;
const graph_store = geode.graph_store;
const principal_mod = geode.security.principal;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const policy_catalog = geode.security.policy_catalog;
const PolicyCatalog = policy_catalog.PolicyCatalog;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;
const PolicyRecord = user_storage.UserStorageBackend.PolicyRecord;
const PolicyKind = user_storage.UserStorageBackend.PolicyKind;

const security_graph = "__geode_security";

fn principal(username: []const u8, roles: []const []const u8) principal_mod.Principal {
    return .{
        .user_id = 1,
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

fn runAs(h: *harness.Harness, session: *execution.SessionState, as: ?*const principal_mod.Principal, query: []const u8) !void {
    var request = std.heap.ArenaAllocator.init(testing.allocator);
    defer request.deinit();
    const ra = request.allocator();
    var parsed = try geode.parseGql(query, ra);
    defer parsed.deinit();
    var ctx = h.ctx;
    ctx.session_state = session;
    ctx.principal = as;
    var result = try execution.executeProgramWithContext(ra, &parsed.program, ctx);
    result.deinit(ra);
}

test "SONNY-2791: no statement selects, creates or drops an internal __geode_* graph, for anyone" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const st = graph_store.getGlobalStore(testing.allocator);
    try st.createGraph(security_graph);
    const nodes_before = st.getNodeCount();

    const admin = principal("root", &.{"Admin"});
    for ([_]?*const principal_mod.Principal{ null, &admin }) |as| {
        var session = execution.SessionState.init(testing.allocator);
        defer session.deinit();
        const refused = [_][]const u8{
            "USE GRAPH __geode_security",
            "USE __geode_security",
            "SESSION SET GRAPH __geode_security",
            "SESSION SET PROPERTY GRAPH __geode_security",
            "SESSION SET GRAPH = '__geode_security'",
            "SESSION SET PROPERTY GRAPH \"__geode_other\"",
            // Probe R7-A's shapes: a switch, then a write.
            "USE GRAPH __geode_security; CREATE (:X)",
            "SESSION SET PROPERTY GRAPH __geode_security; CREATE (:Policy {name: 'evil'})",
            "CREATE GRAPH __geode_x",
            "DROP GRAPH __geode_security",
            "DROP GRAPH IF EXISTS __geode_security",
        };
        for (refused) |query| {
            testing.expectError(error.InternalGraph, runAs(&h, &session, as, query)) catch |err| {
                std.debug.print("{s}: expected InternalGraph\n", .{query});
                return err;
            };
            try testing.expect(session.graph == null);
        }
    }
    try testing.expect(st.graphExists(security_graph));
    try testing.expect(!st.graphExists("__geode_x"));
    try testing.expectEqual(nodes_before, st.getNodeCount());
}

fn encodeProto(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    return allocator.dupe(u8, aw.written());
}

fn decodeProto(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !T {
    var reader: std.Io.Reader = .fixed(bytes);
    return protobuf.decode(T, &reader, allocator);
}

test "SONNY-2791: over gRPC an Admin cannot switch to, write or drop __geode_security" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const st = graph_store.getGlobalStore(testing.allocator);
    try st.createGraph(security_graph);

    const auth_was_enabled = user_mgmt.isAuthEnabled();
    user_mgmt.setAuthEnabled(true);
    defer user_mgmt.setAuthEnabled(auth_was_enabled);
    var grpc_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer grpc_arena.deinit();
    const ga = grpc_arena.allocator();
    var sessions = grpc.SessionStore.init(ga, .{});
    defer sessions.deinit();
    grpc.setSessionStore(&sessions);
    defer grpc.setSessionStore(null);
    const root = try sessions.createSession("root", "", .Admin, null, null, false, 0);

    for ([_][]const u8{
        "SESSION SET PROPERTY GRAPH __geode_security; CREATE (:Policy {name: 'evil', operation: 2, permissive: true})",
        "USE GRAPH __geode_security; MATCH (n) RETURN count(n) AS c",
        "DROP GRAPH __geode_security",
    }) |query| {
        const req = try encodeProto(ga, schema.ExecuteRequest{ .session_id = root, .query = query, .params = .empty });
        const resp = try decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
        const err = switch (resp.payload orelse return error.MissingPayload) {
            .@"error" => |e| e,
            else => {
                std.debug.print("{s}: ran\n", .{query});
                return error.ExpectedRefusal;
            },
        };
        try testing.expectEqualStrings("42501", err.code);
    }
    try testing.expect(st.graphExists(security_graph));
    try testing.expect(st.getNodesByLabel(security_graph, "Policy") == null or st.getNodesByLabel(security_graph, "Policy").?.len == 0);
}

// ---------------------------------------------------------------------------
// (b) the recovery reseal

const HMAC_KEY = [_]u8{0x91} ** 32;

const read_actions = [_]policy_catalog.Action{.read};
const hr_readers = policy_catalog.PolicySpec{
    .name = "hr-readers",
    .scope_graph = "hr",
    .actions = &read_actions,
    .effect = .allow,
    .expression_source = "true",
    .enabled = true,
};

/// Probe R7-K2: an attacker writes a :Policy node directly into
/// __geode_security, in the pre-kind GPS shape of an "allow write for
/// everyone": no `kind`, no USING text, and no valid HMAC (they do not know
/// the key).
fn plantLegacyAllowWrite(store: *graph_store.GraphStore, id: i64, name: []const u8) !u64 {
    const labels = [_][]const u8{"Policy"};
    const node = try store.createNodeWithGraph(@constCast(&labels), security_graph);
    try store.setNodeProperty(node, "id", .{ .Int = id });
    try store.setNodeProperty(node, "name", .{ .String = name });
    try store.setNodeProperty(node, "description", .{ .String = "" });
    try store.setNodeProperty(node, "graph", .{ .String = "*" });
    try store.setNodeProperty(node, "table", .{ .String = "" });
    try store.setNodeProperty(node, "operation", .{ .Int = 2 });
    try store.setNodeProperty(node, "permissive", .{ .Bool = true });
    try store.setNodeProperty(node, "enabled", .{ .Bool = true });
    try store.setNodeProperty(node, "audit_level", .{ .Int = 0 });
    try store.setNodeProperty(node, "created_at", .{ .Int = 1 });
    try store.setNodeProperty(node, "updated_at", .{ .Int = 1 });
    try store.setNodeProperty(node, "created_by", .{ .Int = 0 });
    return node;
}

/// The policy record HMAC as v0.8.22 computed it: these fourteen properties,
/// no kind (auth_graph_manager.zig computePolicyHmac for a legacy record).
fn preKindPolicyHmac(record: *const PolicyRecord) ![64]u8 {
    var id_buf: [20]u8 = undefined;
    var created_buf: [20]u8 = undefined;
    var updated_buf: [20]u8 = undefined;
    var operation_buf: [10]u8 = undefined;
    var audit_buf: [10]u8 = undefined;
    var created_by_buf: [20]u8 = undefined;
    const props = [_]auth_hmac.KeyValue{
        .{ .key = "audit_level", .value = try std.fmt.bufPrint(&audit_buf, "{d}", .{record.audit_level}) },
        .{ .key = "check_clause", .value = record.getCheckClause() orelse "" },
        .{ .key = "created_at", .value = try std.fmt.bufPrint(&created_buf, "{d}", .{record.created_at}) },
        .{ .key = "created_by", .value = try std.fmt.bufPrint(&created_by_buf, "{d}", .{record.created_by}) },
        .{ .key = "description", .value = record.getDescription() },
        .{ .key = "enabled", .value = if (record.enabled) "true" else "false" },
        .{ .key = "graph", .value = record.getGraph() },
        .{ .key = "id", .value = try std.fmt.bufPrint(&id_buf, "{d}", .{record.id}) },
        .{ .key = "name", .value = record.getName() },
        .{ .key = "operation", .value = try std.fmt.bufPrint(&operation_buf, "{d}", .{record.operation}) },
        .{ .key = "permissive", .value = if (record.permissive) "true" else "false" },
        .{ .key = "table", .value = record.getTable() },
        .{ .key = "updated_at", .value = try std.fmt.bufPrint(&updated_buf, "{d}", .{record.updated_at}) },
        .{ .key = "using_clause", .value = record.getUsingClause() orelse "" },
    };
    const hm = try auth_hmac.computeRecordHmac(&HMAC_KEY, &props);
    return auth_hmac.hmacToHex(&hm);
}

fn hydrated(agm: *AuthGraphManager) !usize {
    var cat = PolicyCatalog.init(testing.allocator);
    defer cat.deinit();
    try policy_persistence.hydrateCatalog(testing.allocator, agm, &cat);
    return cat.listPolicies().len;
}

test "SONNY-2791: the recovery reseal refuses a planted legacy record (probe R7-K2) unless its id is accepted, and then stores it explicitly" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    // A signed GPS policy, and a record authentically written before the
    // upgrade: signed with this key, no kind, no USING text for "true".
    var legacy_id: u64 = 0;
    {
        var agm = try AuthGraphManager.init(allocator, &store);
        defer agm.deinit();
        try policy_persistence.persistPolicy(&agm, &HMAC_KEY, hr_readers);
        var spec = hr_readers;
        spec.name = "pre-upgrade";
        try policy_persistence.persistPolicy(&agm, &HMAC_KEY, spec);
        legacy_id = agm.findPolicyIdByName("pre-upgrade").?;
    }
    {
        var agm = try AuthGraphManager.init(allocator, &store);
        defer agm.deinit();
        const node = agm.storage.policy_nodes.get(legacy_id).?;
        store.removeNodeProperty(node, "kind");
        store.removeNodeProperty(node, "using_clause");
    }
    {
        var agm = try AuthGraphManager.init(allocator, &store);
        defer agm.deinit();
        const record = agm.storage.getPolicy(legacy_id).?;
        const hex = try preKindPolicyHmac(&record);
        try store.setNodeProperty(agm.storage.policy_nodes.get(legacy_id).?, "hmac", .{ .String = &hex });
    }
    // The plant (probe R7-K2): it breaks the chain.
    _ = try plantLegacyAllowWrite(&store, 987654321, "evil-legacy-true");

    var agm = try AuthGraphManager.init(allocator, &store);
    defer agm.deinit();
    if (agm.verifyChain(&HMAC_KEY)) |_| return error.PlantVerified else |_| {}

    // The recovery reseal refuses, and signs nothing: the chain still fails.
    try testing.expectError(error.UnsignedLegacyPolicyRecord, agm.resealChain(&HMAC_KEY, .{}));
    if (agm.verifyChain(&HMAC_KEY)) |_| return error.ResealSignedThePlant else |_| {}
    // Accepting another id does not accept the plant.
    try testing.expectError(error.UnsignedLegacyPolicyRecord, agm.resealChain(&HMAC_KEY, .{ .accept = &.{legacy_id} }));

    // The operator checked the record and accepts it by id: it is stored as
    // what it is now, explicitly, and then signed.
    try agm.resealChain(&HMAC_KEY, .{ .accept = &.{987654321} });
    try agm.verifyChain(&HMAC_KEY);
    const accepted = agm.storage.getPolicy(987654321).?;
    try testing.expectEqual(PolicyKind.gps, accepted.kind);
    try testing.expectEqualStrings("true", accepted.getUsingClause().?);
    // The authentic legacy record verified; it is kept as it was.
    try testing.expectEqual(PolicyKind.legacy, agm.storage.getPolicy(legacy_id).?.kind);
    try testing.expectEqual(@as(usize, 3), try hydrated(&agm));
}

test "SONNY-2791: no seal signs a planted record without a kind: probe R7-K2's sealChain, and the seal after an auth change" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    {
        var agm = try AuthGraphManager.init(allocator, &store);
        defer agm.deinit();
        try policy_persistence.persistPolicy(&agm, &HMAC_KEY, hr_readers);
    }
    const plant = try plantLegacyAllowWrite(&store, 987654321, "evil-legacy-true");

    // An offline CLI command, or the server at startup, loads the security
    // graph as it is.
    var agm = try AuthGraphManager.init(allocator, &store);
    defer agm.deinit();
    // Probe R7-K2's step, sealChain: it refuses and signs nothing.
    try testing.expectError(error.UnsignedLegacyPolicyRecord, agm.sealChain(&HMAC_KEY));
    try testing.expect(store.getNodeProperty(plant, "hmac") == null);
    if (agm.verifyChain(&HMAC_KEY)) |_| return error.SealSignedThePlant else |_| {}

    // Every auth change seals after it. CREATE POLICY, and a new user (as
    // `geode user create` or `geode user reset-password` would seal), fail
    // there, and the plant stays unsigned: the next start refuses the chain
    // until the operator decides the plant's id.
    var spec = hr_readers;
    spec.name = "hr-readers-2";
    try testing.expectError(error.UnsignedLegacyPolicyRecord, policy_persistence.persistPolicy(&agm, &HMAC_KEY, spec));
    try testing.expectError(error.UnsignedLegacyPolicyRecord, agm.createUser(&HMAC_KEY, "carol", "carol@example.com", "$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA", false));
    try testing.expect(store.getNodeProperty(plant, "hmac") == null);
    if (agm.verifyChain(&HMAC_KEY)) |_| return error.SealSignedThePlant else |_| {}
}

test "SONNY-2791: the recovery reseal deletes a refused record the operator drops, and refuses an id both accepted and dropped" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    {
        var agm = try AuthGraphManager.init(allocator, &store);
        defer agm.deinit();
        try policy_persistence.persistPolicy(&agm, &HMAC_KEY, hr_readers);
    }
    _ = try plantLegacyAllowWrite(&store, 987654321, "evil-legacy-true");
    {
        var agm = try AuthGraphManager.init(allocator, &store);
        defer agm.deinit();
        try testing.expectError(error.ConflictingLegacyPolicyDecision, agm.resealChain(&HMAC_KEY, .{
            .accept = &.{987654321},
            .drop = &.{987654321},
        }));
        try testing.expect(agm.storage.getPolicy(987654321) != null);
        if (agm.verifyChain(&HMAC_KEY)) |_| return error.ResealSignedThePlant else |_| {}

        try agm.resealChain(&HMAC_KEY, .{ .drop = &.{987654321} });
        try testing.expect(agm.storage.getPolicy(987654321) == null);
        try agm.verifyChain(&HMAC_KEY);
    }

    // After a restart the chain verifies, GPS loads only the signed policy,
    // and nobody may write.
    var agm = try AuthGraphManager.init(allocator, &store);
    defer agm.deinit();
    try agm.verifyChain(&HMAC_KEY);
    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();
    try policy_persistence.hydrateCatalog(allocator, &agm, &cat);
    try testing.expectEqual(@as(usize, 1), cat.listPolicies().len);
    try testing.expectEqualStrings("hr-readers", cat.listPolicies()[0].name);
    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();
    const nobody = principal("nobody", &.{});
    try testing.expect(!gps.writePermitted(allocator, &nobody));
}

test "SONNY-2791: without a plant, the recovery reseal signs what verifies, as before" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    {
        var agm = try AuthGraphManager.init(allocator, &store);
        defer agm.deinit();
        try policy_persistence.persistPolicy(&agm, &HMAC_KEY, hr_readers);
    }
    // Something else broke the chain (a record with a kind, unsigned: the
    // RLS CLI's write, SONNY-2750).
    {
        var agm = try AuthGraphManager.init(allocator, &store);
        defer agm.deinit();
        try agm.storage.persistPolicy(.{
            .policy_id = agm.storage.nextPolicyId(),
            .name = "orders-rls",
            .description = "",
            .graph = "",
            .table = "orders",
            .operation = 0,
            .permissive = false,
            .enabled = true,
            .using_clause = "true",
            .check_clause = null,
            .audit_level = 0,
            .created_by = 0,
            .kind = .rls,
            .mode = .create,
        });
    }
    var agm = try AuthGraphManager.init(allocator, &store);
    defer agm.deinit();
    if (agm.verifyChain(&HMAC_KEY)) |_| return error.ChainAcceptedUnsignedRecord else |_| {}
    try agm.resealChain(&HMAC_KEY, .{});
    try agm.verifyChain(&HMAC_KEY);
    try testing.expectEqual(@as(usize, 1), try hydrated(&agm));
}

test "SONNY-2791: over QUIC no HELLO binds an internal graph, and an Admin cannot USE one" {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var data_dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&data_dir_buf, "/tmp/geode-sonny2791-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, util.TestEnv.standard());
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);

    for ([_][]const u8{ "__geode_security", "__geode_new" }) |graph| {
        var client = try util.QuicProtoClient.connect(allocator, addr);
        defer client.deinit();
        var h = try client.helloWithGraph(allocator, util.defaultUsername(), util.defaultPassword(), graph);
        defer h.deinit(allocator);
        if (h.success) std.debug.print("HELLO bound {s}\n", .{graph});
        try testing.expect(!h.success);
    }
    var admin = try util.QuicProtoClient.connect(allocator, addr);
    defer admin.deinit();
    var ah = try admin.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer ah.deinit(allocator);
    try testing.expect(ah.success);
    var r = try admin.executeAndCollect(allocator, "USE GRAPH __geode_security; MATCH (n) RETURN count(n) AS c", util.emptyParams(), 10);
    defer r.deinit(allocator);
    try testing.expectEqualStrings("42501", r.error_code orelse return error.ExpectedRefusal);
}
