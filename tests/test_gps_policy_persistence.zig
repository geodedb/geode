// GPS Phase 4 (Task 4-5) — Round-trip tests for policy_persistence.zig
//
// Covers:
//   - persistPolicy writes a :Policy node to __geode_security
//   - hydrateCatalog loads that node back into a fresh PolicyCatalog
//   - dropPolicy removes the node; hydrating after gives an empty catalog
//   - HMAC chain verifies correctly after create and after drop
//   - Idempotent createPolicy (calling persistPolicy twice with the same name)

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const auth_graph_manager_mod = @import("auth_graph_manager");
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;
const policy_catalog_mod = geode.security.policy_catalog;
const PolicyCatalog = policy_catalog_mod.PolicyCatalog;
const policy_persistence = @import("policy_persistence");

const testing = std.testing;

const HMAC_KEY = [_]u8{0xde} ** 32;

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=RoundTrip; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "persistPolicy then hydrateCatalog round-trips a policy" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    // Persist one policy
    const actions = [_]policy_catalog_mod.Action{ .read, .match_ };
    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, .{
        .name = "allow-readers",
        .scope_graph = "hr",
        .actions = &actions,
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });

    // Verify HMAC chain is intact after write
    try mgr.verifyChain(&HMAC_KEY);

    // Hydrate a fresh catalog
    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();
    try policy_persistence.hydrateCatalog(allocator, &mgr, &cat);

    // Assert the policy came back correctly
    const policies = cat.listPolicies();
    try testing.expectEqual(@as(usize, 1), policies.len);
    try testing.expectEqualStrings("allow-readers", policies[0].name);
    try testing.expectEqualStrings("hr", policies[0].scope_graph);
    try testing.expectEqual(policy_catalog_mod.Effect.allow, policies[0].effect);
    try testing.expect(policies[0].enabled);

    // Verify at least one action survived the op-byte round-trip
    try testing.expect(policies[0].actions.len >= 1);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=DropRoundTrip; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "dropPolicy removes the policy and hydrateCatalog gives empty catalog" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const actions = [_]policy_catalog_mod.Action{.write};
    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, .{
        .name = "deny-writers",
        .scope_graph = "*",
        .actions = &actions,
        .effect = .deny,
        .expression_source = "true",
        .enabled = true,
    });

    // Drop the policy
    try policy_persistence.dropPolicy(&mgr, &HMAC_KEY, "deny-writers");

    // HMAC chain must still be valid after drop
    try mgr.verifyChain(&HMAC_KEY);

    // Hydrating from an empty store yields an empty catalog
    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();
    try policy_persistence.hydrateCatalog(allocator, &mgr, &cat);

    try testing.expectEqual(@as(usize, 0), cat.listPolicies().len);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=IdempotentPersist; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "persistPolicy twice with the same name is idempotent — only one node persisted" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const actions = [_]policy_catalog_mod.Action{.schema};
    const spec = policy_catalog_mod.PolicySpec{
        .name = "schema-admin",
        .scope_graph = "infra",
        .actions = &actions,
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    };

    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, spec);
    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, spec); // second call must not duplicate

    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();
    try policy_persistence.hydrateCatalog(allocator, &mgr, &cat);

    // Must have exactly one policy, not two
    try testing.expectEqual(@as(usize, 1), cat.listPolicies().len);
    try testing.expectEqualStrings("schema-admin", cat.listPolicies()[0].name);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=DropNotFound; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "dropPolicy returns PolicyNotFound for unknown policy name" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const result = policy_persistence.dropPolicy(&mgr, &HMAC_KEY, "nonexistent");
    try testing.expectError(error.PolicyNotFound, result);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=MultiPolicy; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "multiple policies persist and all hydrate correctly" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const read_actions = [_]policy_catalog_mod.Action{.read};
    const write_actions = [_]policy_catalog_mod.Action{.write};

    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, .{
        .name = "p1",
        .scope_graph = "a",
        .actions = &read_actions,
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });
    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, .{
        .name = "p2",
        .scope_graph = "b",
        .actions = &write_actions,
        .effect = .deny,
        .expression_source = "true",
        .enabled = false,
    });

    try mgr.verifyChain(&HMAC_KEY);

    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();
    try policy_persistence.hydrateCatalog(allocator, &mgr, &cat);

    try testing.expectEqual(@as(usize, 2), cat.listPolicies().len);
}

// ---------------------------------------------------------------------------
// SONNY-2731: a policy's text means the same after a restart.
// CANARY: REQ=REQ-SONNY-2731-POLICY-TEXT-LIMITS; FEATURE="GPS Policy Persistence"; ASPECT=RestartSameMeaning; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-09-25
// ---------------------------------------------------------------------------

const policy_expression = geode.security.policy_expression;
const PolicyRecord = @FieldType(AuthGraphManager, "storage").PolicyRecord;

fn fieldCapacity(comptime field: []const u8) usize {
    return @typeInfo(@FieldType(PolicyRecord, field)).array.len;
}

test "SONNY-2731: the catalog's length limits are what the policy record stores" {
    // UserStorageBackend.persistPolicy stores one byte less than each field.
    try testing.expectEqual(fieldCapacity("using_clause"), policy_catalog_mod.max_policy_expression_len + 1);
    try testing.expectEqual(fieldCapacity("name"), policy_catalog_mod.max_policy_name_len + 1);
    try testing.expectEqual(fieldCapacity("graph"), policy_catalog_mod.max_policy_scope_len + 1);
}

/// `current_user() = 'u000' OR current_user() = 'u001' OR …`, exactly `len`
/// bytes: the last user name is padded to fit. Returns the text and the
/// users it names.
fn allowList(allocator: std.mem.Allocator, len: usize, users: *std.ArrayList([]const u8)) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    const term_len = "current_user() = 'u000'".len;
    const last_min = " OR current_user() = 'last'".len;
    var i: usize = 0;
    // Room for this term and for the shortest last term.
    while (text.items.len + " OR ".len + term_len + last_min <= len) : (i += 1) {
        if (i > 0) try text.appendSlice(allocator, " OR ");
        try text.print(allocator, "current_user() = 'u{d:0>3}'", .{i});
    }
    // The last term takes the rest: a longer user name.
    try text.appendSlice(allocator, " OR current_user() = 'last");
    while (text.items.len < len - 1) try text.append(allocator, 'x');
    try text.append(allocator, '\'');
    std.debug.assert(text.items.len == len);

    // The user names are slices of the returned text (so taken after it is
    // owned: toOwnedSlice may move the buffer).
    const owned = try text.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    var it = std.mem.splitSequence(u8, owned, " OR ");
    while (it.next()) |term| {
        const start = std.mem.indexOfScalar(u8, term, '\'').? + 1;
        try users.append(allocator, term[start .. term.len - 1]);
    }
    return owned;
}

fn grants(p: *const policy_catalog_mod.Policy, user: []const u8) bool {
    if (p.compiled) |*c| return policy_expression.evaluate(c, .{ .current_user = user, .current_tenant = null, .current_graph = null, .resource_label = null });
    return false;
}

test "SONNY-2731: a policy at the length limit means the same after a restart; a longer one is refused and nothing is stored" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var users: std.ArrayList([]const u8) = .empty;
    defer users.deinit(allocator);
    const text = try allowList(allocator, policy_catalog_mod.max_policy_expression_len, &users);
    defer allocator.free(text);
    const actions = [_]policy_catalog_mod.Action{.read};
    const spec = policy_catalog_mod.PolicySpec{ .name = "long-allow", .scope_graph = "hr", .actions = &actions, .effect = .allow, .expression_source = text, .enabled = true };

    // CREATE POLICY accepts it (the DDL path), and it is persisted.
    var before = PolicyCatalog.init(allocator);
    defer before.deinit();
    try before.addPolicyStrict(spec);
    {
        var mgr = try AuthGraphManager.init(allocator, &store);
        defer mgr.deinit();
        try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, spec);
    }

    // Restart: a new manager reloads the :Policy nodes from the store, and a
    // fresh catalog is hydrated from it.
    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();
    var after = PolicyCatalog.init(allocator);
    defer after.deinit();
    try policy_persistence.hydrateCatalog(allocator, &mgr, &after);
    try testing.expectEqual(@as(usize, 1), after.listPolicies().len);
    const restored = &after.listPolicies()[0];
    try testing.expectEqualStrings(text, restored.expression_source);
    try testing.expect(PolicyCatalog.policyIsValid(restored));

    // It grants exactly what it granted before the restart.
    const original = &before.listPolicies()[0];
    try testing.expect(users.items.len > 10);
    for (users.items) |user| {
        try testing.expect(grants(original, user));
        try testing.expect(grants(restored, user));
    }
    for ([_][]const u8{ "nobody", "u999", "not_last" }) |user| {
        try testing.expect(!grants(original, user));
        try testing.expect(!grants(restored, user));
    }

    // One byte more: refused by CREATE POLICY, and by the store; nothing is
    // stored, so nothing can come back cut after a restart.
    var more_users: std.ArrayList([]const u8) = .empty;
    defer more_users.deinit(allocator);
    const too_long = try allowList(allocator, policy_catalog_mod.max_policy_expression_len + 1, &more_users);
    defer allocator.free(too_long);
    var long_spec = spec;
    long_spec.name = "too-long";
    long_spec.expression_source = too_long;
    try testing.expectError(error.PolicyFieldTooLong, before.addPolicyStrict(long_spec));
    try testing.expectError(error.FieldTooLong, policy_persistence.persistPolicy(&mgr, &HMAC_KEY, long_spec));
    var again = PolicyCatalog.init(allocator);
    defer again.deinit();
    try policy_persistence.hydrateCatalog(allocator, &mgr, &again);
    try testing.expectEqual(@as(usize, 1), again.listPolicies().len);

    // Names and graphs past their fields are refused the same way.
    var long_name = spec;
    long_name.name = "n" ** (policy_catalog_mod.max_policy_name_len + 1);
    try testing.expectError(error.PolicyFieldTooLong, before.addPolicyStrict(long_name));
    var long_graph = spec;
    long_graph.name = "long-graph";
    long_graph.scope_graph = "g" ** (policy_catalog_mod.max_policy_scope_len + 1);
    try testing.expectError(error.PolicyFieldTooLong, before.addPolicyStrict(long_graph));
    try testing.expectError(error.PolicyFieldTooLong, before.alterPolicy("long-allow", null, "r" ** (policy_catalog_mod.max_policy_name_len + 1)));
}

test "SONNY-2731: a stored policy text longer than its record loads fail-closed instead of cut" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    const actions = [_]policy_catalog_mod.Action{.read};
    const spec = policy_catalog_mod.PolicySpec{ .name = "rewritten", .scope_graph = "*", .actions = &actions, .effect = .allow, .expression_source = "current_user() = 'alice'", .enabled = true };
    // Its first 512 bytes are a complete allow-list on their own, so a
    // loader that cuts the text to the record compiles a different, valid
    // policy (without the last user).
    var users: std.ArrayList([]const u8) = .empty;
    defer users.deinit(allocator);
    const head = try allowList(allocator, fieldCapacity("using_clause"), &users);
    defer allocator.free(head);
    const long_text = try std.mem.concat(allocator, u8, &.{ head, " OR current_user() = 'mallory'" });
    defer allocator.free(long_text);
    {
        var mgr = try AuthGraphManager.init(allocator, &store);
        defer mgr.deinit();
        try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, spec);
        // An older or foreign writer stored a longer text than the record
        // holds. The loader used to cut it to 512 bytes and compile that.
        var nodes = mgr.storage.policy_nodes.valueIterator();
        const node_id = nodes.next().?.*;
        try store.setNodeProperty(node_id, "using_clause", .{ .String = long_text });
    }

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();
    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();
    try policy_persistence.hydrateCatalog(allocator, &mgr, &cat);
    try testing.expectEqual(@as(usize, 1), cat.listPolicies().len);
    const p = &cat.listPolicies()[0];
    try testing.expect(!PolicyCatalog.policyIsValid(p));
    try testing.expectEqual(@as(usize, 1), cat.invalidPolicyCount());
    try testing.expect(!grants(p, "u000"));
    try testing.expect(!grants(p, "mallory"));
    try testing.expect(!grants(p, "alice"));
}
