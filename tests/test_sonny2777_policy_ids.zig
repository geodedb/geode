// SONNY-2777 regression: every policy writer takes its record id from one
// sequence, and a new record never overwrites an existing one.
//
// `geode auth policy create` took its policy id from the next *user* id
// (`AuthGraphManager.next_user_id`). With no user beyond id N, it wrote id
// N + 1, and when a GPS policy already had that id, `upsertPolicyNode` reused
// the GPS policy's node and overwrote the record: the GPS policy was gone.
// The geode-auth tool used the wall-clock millisecond, so two policies created
// in one millisecond shared a record, and a GPS policy (whose id was the
// largest id + 1) could hold the next millisecond.
//
// CANARY: REQ=REQ-SONNY-2777-POLICY-IDS; FEATURE="GPS Policy Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2777_policy_ids.zig; OWNER=security; UPDATED=2026-09-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const auth = @import("geode_auth");
const rls = @import("rls");
const user_manager = @import("user_manager");
const user_storage = @import("user_storage");
const auth_graph_manager = @import("auth_graph_manager");
const policy_persistence = @import("policy_persistence");
const cli_auth = @import("cli_auth_helpers");

const graph_store = geode.graph_store;
const policy_catalog = geode.security.policy_catalog;
const PolicyCatalog = policy_catalog.PolicyCatalog;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;
const PolicyKind = user_storage.UserStorageBackend.PolicyKind;

const HMAC_KEY = [_]u8{0x27} ** 32;

const read_actions = [_]policy_catalog.Action{.read};
const gps_spec = policy_catalog.PolicySpec{
    .name = "hr-readers",
    .scope_graph = "hr",
    .actions = &read_actions,
    .effect = .allow,
    .expression_source = "true",
    .enabled = true,
};

fn kindCounts(agm: *AuthGraphManager) struct { gps: usize, rls: usize } {
    var gps: usize = 0;
    var rls_n: usize = 0;
    var it = agm.storage.policyIterator();
    while (it.next()) |record| switch (record.kind) {
        .gps => gps += 1,
        .rls => rls_n += 1,
        else => {},
    };
    return .{ .gps = gps, .rls = rls_n };
}

test "SONNY-2777: a GPS policy and a CLI RLS policy both survive, across a restart" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var gps_id: u64 = 0;
    var rls_id: u64 = 0;
    {
        var agm = try AuthGraphManager.init(allocator, &store);
        defer agm.deinit();
        // No users: the next user id is 1, and so is the first policy id.
        try testing.expectEqual(@as(u64, 1), agm.next_user_id);
        try policy_persistence.persistPolicy(&agm, &HMAC_KEY, gps_spec);
        gps_id = agm.findPolicyIdByName("hr-readers").?;
        try testing.expectEqual(@as(u64, 1), gps_id);
        // What `geode auth policy create orders-rls --table orders` does.
        rls_id = try cli_auth.createRlsPolicyRecord(&agm, "orders-rls", "orders", "true");
    }
    try testing.expect(rls_id != gps_id);

    var agm = try AuthGraphManager.init(allocator, &store);
    defer agm.deinit();
    const counts = kindCounts(&agm);
    try testing.expectEqual(@as(usize, 1), counts.gps);
    try testing.expectEqual(@as(usize, 1), counts.rls);
    try testing.expectEqualStrings("hr-readers", agm.storage.getPolicy(gps_id).?.getName());
    try testing.expectEqualStrings("orders-rls", agm.storage.getPolicy(rls_id).?.getName());

    // GPS still loads its policy after the reseal the CLI's unsigned write
    // needs.
    try agm.sealChain(&HMAC_KEY);
    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();
    try policy_persistence.hydrateCatalog(allocator, &agm, &cat);
    try testing.expectEqual(@as(usize, 1), cat.listPolicies().len);
    try testing.expectEqualStrings("hr-readers", cat.listPolicies()[0].name);

    // And a GPS policy created after the RLS one takes a fresh id too.
    var spec2 = gps_spec;
    spec2.name = "hr-readers-2";
    try policy_persistence.persistPolicy(&agm, &HMAC_KEY, spec2);
    const id2 = agm.findPolicyIdByName("hr-readers-2").?;
    try testing.expect(id2 != gps_id and id2 != rls_id);
    try testing.expectEqual(@as(usize, 2), kindCounts(&agm).gps);
    try testing.expectEqual(@as(usize, 1), kindCounts(&agm).rls);
}

test "SONNY-2777: a new record never overwrites one, and a replace keeps the record's kind" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var agm = try AuthGraphManager.init(allocator, &store);
    defer agm.deinit();
    try policy_persistence.persistPolicy(&agm, &HMAC_KEY, gps_spec);
    const gps_id = agm.findPolicyIdByName("hr-readers").?;

    const rls_over_gps: user_storage.UserStorageBackend.PolicyPersistOptions = .{
        .policy_id = gps_id,
        .name = "intruder",
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
    };
    try testing.expectError(error.PolicyIdInUse, agm.storage.persistPolicy(rls_over_gps));
    var replace = rls_over_gps;
    replace.mode = .replace;
    try testing.expectError(error.PolicyKindMismatch, agm.storage.persistPolicy(replace));
    replace.policy_id = 999;
    try testing.expectError(error.PolicyNotFound, agm.storage.persistPolicy(replace));
    // The GPS record is untouched.
    const record = agm.storage.getPolicy(gps_id).?;
    try testing.expectEqualStrings("hr-readers", record.getName());
    try testing.expectEqual(PolicyKind.gps, record.kind);
}

test "SONNY-2777: the geode-auth tool gives each policy its own record, even within one millisecond" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    {
        var agm = try AuthGraphManager.init(allocator, &store);
        defer agm.deinit();
        try policy_persistence.persistPolicy(&agm, &HMAC_KEY, gps_spec);
    }

    // The geode-auth tool's process: its own arena (RLSEngine.deinit does
    // not free the strings user_manager copies into each policy).
    {
        var process = std.heap.ArenaAllocator.init(allocator);
        defer process.deinit();
        const pa = process.allocator();
        var security_manager = try auth.SecurityManager.initEmpty(pa);
        defer security_manager.deinit();
        var rls_engine = try rls.RLSEngine.init(pa);
        defer rls_engine.deinit();
        var backend = try user_storage.UserStorageBackend.init(pa, &store);
        defer backend.deinit();
        var mgr = try user_manager.UserManager.init(pa, &security_manager, &rls_engine, &backend);
        defer mgr.deinit();
        for ([_][]const u8{ "p1", "p2", "p3" }) |name| {
            _ = try mgr.createPolicy(.{
                .name = name,
                .description = "RLS policy",
                .graph = "default",
                .table = "orders",
                .operation = .select,
                .roles = &[_][]const u8{"user"},
            });
        }
    }

    var agm = try AuthGraphManager.init(allocator, &store);
    defer agm.deinit();
    const counts = kindCounts(&agm);
    try testing.expectEqual(@as(usize, 1), counts.gps);
    try testing.expectEqual(@as(usize, 3), counts.rls);
}
