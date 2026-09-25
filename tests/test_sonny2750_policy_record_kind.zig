// SONNY-2750 regression: an RLS policy record is never loaded as a GPS policy.
//
// GPS policies (CREATE POLICY, through policy_persistence) and RLS policies
// (the geode-auth CLI through user_manager, and `geode auth policy create`)
// are stored as the same :Policy records in __geode_security. GPS startup
// hydration loaded every record as a GPS policy: an RLS operation index read
// as a GPS action bitmask (update = 2 = write), `permissive` as the effect,
// and the missing USING clause as "true". So `geode-auth policy create p
// orders update` came back after a restart as "allow write on `default` for
// everyone", which also answers the handlers' database-level write check.
//
// The integrity check: the CLI writes the record with no HMAC and does not
// reseal, so the server's startup verifyChain refuses the chain and the server
// does not start. The documented remedy (`geode auth reseal`, or
// GEODE_AUTH_RESEAL_CHAIN=1) signs every record as it stands, the RLS one
// included, after which GPS loaded it.
//
// Records now carry a `kind` ("gps" or "rls"), decoded strictly and covered
// by the HMAC. GPS loads only GPS records, and refuses (and audits) the rest.
// A record written before the kind existed is classified by the shape GPS
// gave its records.
//
// CANARY: REQ=REQ-SONNY-2750-POLICY-RECORD-KIND; FEATURE="GPS Policy Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2750_policy_record_kind.zig; OWNER=security; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const auth = @import("geode_auth");
const auth_hmac = @import("auth_lib").hmac;
const rls = @import("rls");
const user_manager = @import("user_manager");
const user_storage = @import("user_storage");
const auth_graph_manager = @import("auth_graph_manager");
const policy_persistence = @import("policy_persistence");

const graph_store = geode.graph_store;
const gps = geode.security.gps;
const principal_mod = geode.security.principal;
const policy_catalog = geode.security.policy_catalog;
const PolicyCatalog = policy_catalog.PolicyCatalog;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;
const PolicyKind = user_storage.UserStorageBackend.PolicyKind;

const HMAC_KEY = [_]u8{0x5a} ** 32;

fn sleepMs(ms: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

fn principal(username: []const u8, roles: []const []const u8) principal_mod.Principal {
    return .{
        .user_id = 7,
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

/// What the geode-auth CLI does for `policy create <name> <table> <operation>`
/// (src/tools/user_auth.zig): the same request, through user_manager. The
/// CLI's policy id is the wall-clock millisecond, so two calls in one
/// millisecond would write one record; the pause keeps them apart.
///
/// The CLI process's own memory is an arena, freed when the "process" ends:
/// RLSEngine.deinit does not free the strings user_manager.createPolicy
/// copies into each policy (a leak of the short-lived CLI, not of the store).
/// Its SecurityManager has no default user: `init` would write a generated
/// admin password to `./.geode_admin_password`, and the policy record does not
/// depend on it.
fn cliCreateRlsPolicy(store: *graph_store.GraphStore, name: []const u8, table: []const u8, operation: rls.RLSEngine.Operation) !void {
    var process = std.heap.ArenaAllocator.init(testing.allocator);
    defer process.deinit();
    const allocator = process.allocator();
    var security_manager = try auth.SecurityManager.initEmpty(allocator);
    defer security_manager.deinit();
    var rls_engine = try rls.RLSEngine.init(allocator);
    defer rls_engine.deinit();
    var backend = try user_storage.UserStorageBackend.init(allocator, store);
    defer backend.deinit();
    var mgr = try user_manager.UserManager.init(allocator, &security_manager, &rls_engine, &backend);
    defer mgr.deinit();
    _ = try mgr.createPolicy(.{
        .name = name,
        .description = "RLS policy",
        .graph = "default",
        .table = table,
        .operation = operation,
        .permissive = true,
        .roles = &[_][]const u8{"user"},
        .using_clause = null,
        .check_clause = null,
        .temporal = null,
        .data_classification = null,
        .audit_level = .denials,
    });
    sleepMs(2);
}

fn decisionFor(p: *const principal_mod.Principal, action: gps.Action, resource: gps.ResourceRef) !gps.PolicyDecisionKind {
    const req = gps.DecisionRequest{ .principal = p, .action = action, .resource = resource };
    return (try gps.decide(testing.allocator, &req)).kind;
}

test "SONNY-2750: an RLS policy created through the geode-auth CLI grants nothing after a restart" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // A server's sealed security graph with one GPS policy.
    {
        var agm = try AuthGraphManager.init(allocator, &store);
        defer agm.deinit();
        try policy_persistence.persistPolicy(&agm, &HMAC_KEY, allow_hr_read);
        try agm.verifyChain(&HMAC_KEY);
    }

    // The geode-auth CLI creates an RLS policy on table `orders` for each
    // operation (`update` read as a GPS action set is "write").
    const ops = [_]rls.RLSEngine.Operation{ .select, .insert, .update, .delete, .all };
    const names = [_][]const u8{ "orders-select", "orders-insert", "orders-update", "orders-delete", "orders-all" };
    for (ops, names) |op, name| try cliCreateRlsPolicy(&store, name, "orders", op);

    // Restart. The CLI neither signs its records nor reseals, so the chain
    // no longer verifies and the server would refuse to start; the
    // documented remedy (`geode auth reseal`) signs every record.
    var agm = try AuthGraphManager.init(allocator, &store);
    defer agm.deinit();
    try testing.expectError(error.RecordCountMismatch, agm.verifyChain(&HMAC_KEY));
    try agm.sealChain(&HMAC_KEY);
    try agm.verifyChain(&HMAC_KEY);

    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();
    try policy_persistence.hydrateCatalog(allocator, &agm, &cat);
    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();

    // The RLS policies grant nothing: a read-only principal still cannot
    // write, and a principal with no role cannot read or write `default`.
    const reader = principal("reader", &.{"ReadOnly"});
    const nobody = principal("nobody", &.{});
    try testing.expect(!gps.writePermitted(allocator, &reader));
    try testing.expect(try decisionFor(&reader, .write, .{ .graph = "default" }) != .allow);
    try testing.expect(try decisionFor(&nobody, .read, .{ .graph = "default" }) != .allow);
    try testing.expect(try decisionFor(&nobody, .match_, .{ .graph = "default" }) != .allow);
    try testing.expect(try decisionFor(&nobody, .write, .{ .database = {} }) != .allow);

    // GPS loaded its own policy and none of the RLS ones.
    try testing.expectEqual(@as(usize, 1), cat.listPolicies().len);
    try testing.expectEqualStrings("allow-hr-read", cat.listPolicies()[0].name);
    try testing.expect(try decisionFor(&nobody, .read, .{ .graph = "hr" }) == .allow);

    // The RLS records are stored as such.
    var it = agm.storage.policyIterator();
    var rls_records: usize = 0;
    while (it.next()) |record| {
        if (record.kind == .rls) rls_records += 1 else try testing.expectEqual(PolicyKind.gps, record.kind);
    }
    try testing.expectEqual(names.len, rls_records);
}

/// Persist `spec` as a GPS policy, then change the stored record with `edit`
/// (another writer, or an older one), reseal, restart and hydrate. Returns the
/// number of policies GPS loaded.
fn hydratedAfter(allocator: std.mem.Allocator, spec: policy_catalog.PolicySpec, edit: *const fn (*graph_store.GraphStore, u64) anyerror!void) !usize {
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    {
        var agm = try AuthGraphManager.init(allocator, &store);
        defer agm.deinit();
        try policy_persistence.persistPolicy(&agm, &HMAC_KEY, spec);
        var nodes = agm.storage.policy_nodes.valueIterator();
        try edit(&store, nodes.next().?.*);
    }
    var agm = try AuthGraphManager.init(allocator, &store);
    defer agm.deinit();
    try agm.sealChain(&HMAC_KEY);
    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();
    try policy_persistence.hydrateCatalog(allocator, &agm, &cat);
    return cat.listPolicies().len;
}

const write_actions = [_]policy_catalog.Action{.write};
const allow_write = policy_catalog.PolicySpec{
    .name = "allow-write",
    .scope_graph = "hr",
    .actions = &write_actions,
    .effect = .allow,
    .expression_source = "true",
    .enabled = true,
};
const read_actions = [_]policy_catalog.Action{.read};
const allow_hr_read = policy_catalog.PolicySpec{
    .name = "allow-hr-read",
    .scope_graph = "hr",
    .actions = &read_actions,
    .effect = .allow,
    .expression_source = "true",
    .enabled = true,
};

fn noEdit(_: *graph_store.GraphStore, _: u64) anyerror!void {}
fn dropKind(store: *graph_store.GraphStore, node: u64) anyerror!void {
    store.removeNodeProperty(node, "kind");
}
fn dropKindAndUsing(store: *graph_store.GraphStore, node: u64) anyerror!void {
    store.removeNodeProperty(node, "kind");
    store.removeNodeProperty(node, "using_clause");
}
fn legacyRlsShape(store: *graph_store.GraphStore, node: u64) anyerror!void {
    store.removeNodeProperty(node, "kind");
    try store.setNodeProperty(node, "table", .{ .String = "orders" });
}
fn legacyAuthCliShape(store: *graph_store.GraphStore, node: u64) anyerror!void {
    // `geode auth policy create` with `--table ''`: everything GPS wrote but
    // the graph, which it leaves empty.
    store.removeNodeProperty(node, "kind");
    try store.setNodeProperty(node, "graph", .{ .String = "" });
}
fn legacyNoDescription(store: *graph_store.GraphStore, node: u64) anyerror!void {
    store.removeNodeProperty(node, "kind");
    store.removeNodeProperty(node, "description");
}
fn legacyNoTable(store: *graph_store.GraphStore, node: u64) anyerror!void {
    store.removeNodeProperty(node, "kind");
    store.removeNodeProperty(node, "table");
}
fn upperKind(store: *graph_store.GraphStore, node: u64) anyerror!void {
    try store.setNodeProperty(node, "kind", .{ .String = "GPS" });
}
fn intKind(store: *graph_store.GraphStore, node: u64) anyerror!void {
    try store.setNodeProperty(node, "kind", .{ .Int = 1 });
}
fn rlsKind(store: *graph_store.GraphStore, node: u64) anyerror!void {
    try store.setNodeProperty(node, "kind", .{ .String = "rls" });
}
fn dropEnabled(store: *graph_store.GraphStore, node: u64) anyerror!void {
    store.removeNodeProperty(node, "enabled");
}
fn dropUsing(store: *graph_store.GraphStore, node: u64) anyerror!void {
    store.removeNodeProperty(node, "using_clause");
}
fn dropPermissive(store: *graph_store.GraphStore, node: u64) anyerror!void {
    store.removeNodeProperty(node, "permissive");
}

test "SONNY-2750: GPS loads GPS records, legacy ones by shape, and refuses every other kind and any missing property" {
    const allocator = testing.allocator;
    const Case = struct { name: []const u8, edit: *const fn (*graph_store.GraphStore, u64) anyerror!void, loaded: usize };
    const cases = [_]Case{
        .{ .name = "a GPS record", .edit = noEdit, .loaded = 1 },
        // Written before records had a kind.
        .{ .name = "a legacy record with GPS's shape", .edit = dropKind, .loaded = 1 },
        .{ .name = "a legacy GPS record for USING true (not stored then)", .edit = dropKindAndUsing, .loaded = 1 },
        .{ .name = "a legacy record with an RLS shape (a table)", .edit = legacyRlsShape, .loaded = 0 },
        .{ .name = "a legacy record with an empty graph", .edit = legacyAuthCliShape, .loaded = 0 },
        .{ .name = "a legacy record with no description property", .edit = legacyNoDescription, .loaded = 0 },
        .{ .name = "a legacy record with no table property", .edit = legacyNoTable, .loaded = 0 },
        // Strict decoding.
        .{ .name = "kind 'GPS'", .edit = upperKind, .loaded = 0 },
        .{ .name = "kind stored as an integer", .edit = intKind, .loaded = 0 },
        .{ .name = "kind 'rls'", .edit = rlsKind, .loaded = 0 },
        // A property the policy needs is missing: no default stands in.
        .{ .name = "no 'enabled'", .edit = dropEnabled, .loaded = 0 },
        .{ .name = "no USING text", .edit = dropUsing, .loaded = 0 },
        .{ .name = "no 'permissive'", .edit = dropPermissive, .loaded = 0 },
    };
    var failures: usize = 0;
    for (cases) |c| {
        const got = try hydratedAfter(allocator, allow_write, c.edit);
        if (got != c.loaded) {
            std.debug.print("{s}: GPS loaded {d} policies, expected {d}\n", .{ c.name, got, c.loaded });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-2750: the kind is covered by the record HMAC" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    try cliCreateRlsPolicy(&store, "orders-update", "orders", .update);
    {
        var agm = try AuthGraphManager.init(allocator, &store);
        defer agm.deinit();
        try agm.sealChain(&HMAC_KEY);
        try agm.verifyChain(&HMAC_KEY);
        // Turning the signed RLS record into a GPS one breaks the chain.
        var nodes = agm.storage.policy_nodes.valueIterator();
        try store.setNodeProperty(nodes.next().?.*, "kind", .{ .String = "gps" });
    }
    var agm = try AuthGraphManager.init(allocator, &store);
    defer agm.deinit();
    try testing.expectError(error.RecordHmacMismatch, agm.verifyChain(&HMAC_KEY));
}

/// The policy record HMAC as v0.8.22 computed it (auth_graph_manager.zig,
/// computePolicyHmac): these fourteen properties, and no kind.
fn preKindPolicyHmac(record: *const user_storage.UserStorageBackend.PolicyRecord) ![64]u8 {
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
    const h = try auth_hmac.computeRecordHmac(&HMAC_KEY, &props);
    return auth_hmac.hmacToHex(&h);
}

test "SONNY-2750: a GPS record stored before records had a kind is hashed as before and still loads" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    // A GPS policy as v0.8.22 stored it: no `kind`, and no USING text for
    // "true".
    {
        var agm = try AuthGraphManager.init(allocator, &store);
        defer agm.deinit();
        try policy_persistence.persistPolicy(&agm, &HMAC_KEY, allow_write);
        var nodes = agm.storage.policy_nodes.valueIterator();
        const node = nodes.next().?.*;
        store.removeNodeProperty(node, "kind");
        store.removeNodeProperty(node, "using_clause");
    }
    var agm = try AuthGraphManager.init(allocator, &store);
    defer agm.deinit();
    try agm.sealChain(&HMAC_KEY);
    var it = agm.storage.policyIterator();
    const record = it.next().?;
    const node = agm.storage.policy_nodes.get(record.id).?;
    try testing.expectEqual(PolicyKind.legacy, record.kind);
    try testing.expectEqual(PolicyKind.gps, record.effectiveKind());
    // The HMAC stored for it is the one v0.8.22 computed, so a chain sealed
    // before the upgrade still verifies after it.
    const expected = try preKindPolicyHmac(record);
    try testing.expectEqualStrings(&expected, store.getNodeProperty(node, "hmac").?.String);
    try agm.verifyChain(&HMAC_KEY);

    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();
    try policy_persistence.hydrateCatalog(allocator, &agm, &cat);
    try testing.expectEqual(@as(usize, 1), cat.listPolicies().len);
    try testing.expectEqualStrings("true", cat.listPolicies()[0].expression_source);

    // ALTER POLICY rewrites it as a GPS record, kind and USING text stored,
    // and it still loads after the next restart.
    try policy_persistence.alterPolicy(&agm, &HMAC_KEY, "allow-write", false, null);
    try testing.expectEqualStrings("gps", store.getNodeProperty(node, "kind").?.String);
    try testing.expectEqualStrings("true", store.getNodeProperty(node, "using_clause").?.String);
    var agm2 = try AuthGraphManager.init(allocator, &store);
    defer agm2.deinit();
    try agm2.verifyChain(&HMAC_KEY);
    var cat2 = PolicyCatalog.init(allocator);
    defer cat2.deinit();
    try policy_persistence.hydrateCatalog(allocator, &agm2, &cat2);
    try testing.expectEqual(@as(usize, 1), cat2.listPolicies().len);
    try testing.expect(!cat2.listPolicies()[0].enabled);
}

test "SONNY-2750: ALTER POLICY does not rewrite a record with a missing property; DROP POLICY removes it" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    {
        var agm = try AuthGraphManager.init(allocator, &store);
        defer agm.deinit();
        try policy_persistence.persistPolicy(&agm, &HMAC_KEY, allow_write);
        var nodes = agm.storage.policy_nodes.valueIterator();
        store.removeNodeProperty(nodes.next().?.*, "enabled");
    }
    var agm = try AuthGraphManager.init(allocator, &store);
    defer agm.deinit();
    try agm.sealChain(&HMAC_KEY);
    // The rename would store `enabled = true`, the default that stood in for
    // the missing property.
    try testing.expectError(error.PolicyNotFound, policy_persistence.alterPolicy(&agm, &HMAC_KEY, "allow-write", null, "renamed"));
    var nodes = agm.storage.policy_nodes.valueIterator();
    try testing.expect(store.getNodeProperty(nodes.next().?.*, "enabled") == null);
    try policy_persistence.dropPolicy(&agm, &HMAC_KEY, "allow-write");
    try testing.expectEqual(@as(u32, 0), agm.storage.policy_nodes.count());
    try agm.verifyChain(&HMAC_KEY);
}

test "SONNY-2750: CREATE, ALTER and DROP POLICY never reach an RLS record of the same name" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    try cliCreateRlsPolicy(&store, "shared", "orders", .update);

    var agm = try AuthGraphManager.init(allocator, &store);
    defer agm.deinit();
    // CREATE POLICY writes its own record instead of taking the RLS one's id.
    var spec = allow_write;
    spec.name = "shared";
    try policy_persistence.persistPolicy(&agm, &HMAC_KEY, spec);
    var gps_records: usize = 0;
    var rls_records: usize = 0;
    var it = agm.storage.policyIterator();
    while (it.next()) |record| switch (record.kind) {
        .gps => gps_records += 1,
        .rls => rls_records += 1,
        else => return error.UnexpectedKind,
    };
    try testing.expectEqual(@as(usize, 1), gps_records);
    try testing.expectEqual(@as(usize, 1), rls_records);

    // ALTER POLICY changes the GPS record, not the RLS one.
    try policy_persistence.alterPolicy(&agm, &HMAC_KEY, "shared", false, null);
    it = agm.storage.policyIterator();
    while (it.next()) |record| {
        if (record.kind == .rls) try testing.expect(record.enabled);
        if (record.kind == .gps) try testing.expect(!record.enabled);
    }

    // DROP POLICY removes the GPS record; the RLS one stays.
    try policy_persistence.dropPolicy(&agm, &HMAC_KEY, "shared");
    it = agm.storage.policyIterator();
    var left: usize = 0;
    while (it.next()) |record| {
        try testing.expectEqual(PolicyKind.rls, record.kind);
        left += 1;
    }
    try testing.expectEqual(@as(usize, 1), left);
    try testing.expectError(error.PolicyNotFound, policy_persistence.dropPolicy(&agm, &HMAC_KEY, "shared"));
}
