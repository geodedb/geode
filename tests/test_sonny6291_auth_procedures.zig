// SONNY-6291: real authenticated executor calls must never fabricate API-key
// authorization or disclose another user's profile. No database responses are
// mocked: users, catalog, executor and audit sink are the production modules.
// CANARY: REQ=REQ-SONNY-6291-AUTH-PROCEDURES; FEATURE="Auth procedure safety"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6291_auth_procedures.zig; OWNER=security; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const Harness = @import("support/auth_procedure_harness.zig").Harness;

test "SONNY-6291: every API-key procedure refuses instead of fabricating success" {
    var h = try Harness.init();
    defer h.deinit();
    for ([_][]const u8{
        "CALL geode.auth.apikey_create('alice', 'key', 'read', '3600')",
        "CALL geode.auth.apikey_create('alice', 'key', '')",
        "CALL geode.auth.apikey_list('alice')",
        "CALL geode.auth.apikey_list('missing')",
        "CALL geode.auth.apikey_list()",
        "CALL geode.auth.apikey_revoke('alice', 'key')",
        "CALL geode.auth.apikey_check_scope('alice', 'key', 'admin')",
        "CALL geode.auth.apikey_check_scope('missing', 'key', 'admin')",
        "CALL geode.auth.apikey_revoke_all('alice')",
        "CALL geode.auth.apikey_unknown('alice')",
    }) |query| {
        try testing.expectError(error.ApiKeysUnsupported, h.run(query, .Admin, "operator"));
    }
    const info = geode.proto_util.mapError(error.ApiKeysUnsupported);
    try testing.expectEqualStrings("0A000", info.code);
    try testing.expect(std.mem.indexOf(u8, info.message, "API key") != null);
}

test "SONNY-6291: unsupported keys cannot enumerate users and still require authentication" {
    var h = try Harness.init();
    defer h.deinit();
    for ([_][]const u8{
        "CALL geode.auth.apikey_list('alice')",
        "CALL geode.auth.apikey_list('missing')",
        "CALL geode.auth.apikey_check_scope('alice', 'key', 'read')",
        "CALL geode.auth.apikey_check_scope('missing', 'key', 'read')",
        "CALL geode.auth.apikey_create('alice', 'key', 'read')",
        "CALL geode.auth.apikey_revoke('alice', 'key')",
        "CALL geode.auth.apikey_revoke_all('alice')",
    }) |query| {
        try testing.expectError(error.ApiKeysUnsupported, h.run(query, .ReadOnly, "bob"));
        try testing.expectError(error.Unauthenticated, h.run(query, null, null));
    }
}

test "SONNY-6291: user_show allows self and Admin, denies other profiles before lookup and audits" {
    var h = try Harness.init();
    defer h.deinit();
    var own = try h.run("CALL geode.auth.user_show('alice')", .User, "alice");
    defer own.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 1), own.rows.len);
    try testing.expectEqualStrings("alice@example.test", own.rows[0][1].Str);
    var other = try h.run("CALL geode.auth.user_show('bob')", .Admin, "operator");
    defer other.deinit(h.arena.allocator());
    try testing.expectEqualStrings("bob@example.test", other.rows[0][1].Str);
    try testing.expectError(error.Unauthorized, h.run("CALL geode.auth.user_show('bob')", .User, "alice"));
    try testing.expectError(error.Unauthorized, h.run("CALL geode.auth.user_show('missing')", .User, "alice"));
    try testing.expectError(error.Unauthorized, h.run("CALL geode.auth.user_show('bob')", .ReadOnly, null));
    try testing.expectError(error.Unauthenticated, h.run("CALL geode.auth.user_show('alice')", null, null));
    const sink = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), h.audit_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(sink);
    try testing.expect(std.mem.indexOf(u8, sink, "access_denied") != null);
    try testing.expect(std.mem.indexOf(u8, sink, "geode.auth.user_show") != null);
    try testing.expect(std.mem.indexOf(u8, sink, "alice") != null);
    try testing.expect(std.mem.indexOf(u8, sink, "failure") != null);
    try testing.expectEqualStrings("42501", geode.proto_util.mapError(error.Unauthorized).code);
}

test "SONNY-6291: missing users are errors, never invented profiles or permissions" {
    var h = try Harness.init();
    defer h.deinit();
    try testing.expectError(error.UserNotFound, h.run("CALL geode.auth.user_show('missing')", .Admin, "operator"));
    try testing.expectError(error.UserNotFound, h.run("CALL geode.auth.user_show('missing')", .User, "missing"));
    try testing.expectError(error.UserNotFound, h.run("CALL geode.auth.user_permissions('missing')", .Admin, "operator"));
    try testing.expectError(error.Unauthorized, h.run("CALL geode.auth.user_permissions('bob')", .User, "alice"));
    var permissions = try h.run("CALL geode.auth.user_permissions('bob')", .Admin, "operator");
    defer permissions.deinit(h.arena.allocator());
    try testing.expect(permissions.rows.len > 0);
    try testing.expectEqualStrings("bob", permissions.rows[0][0].Str);
    try testing.expectEqualStrings("42704", geode.proto_util.mapError(error.UserNotFound).code);
}

test "SONNY-6291: profile and permission calls reject missing or malformed targets" {
    var h = try Harness.init();
    defer h.deinit();
    for ([_][]const u8{
        "CALL geode.auth.user_show()",
        "CALL geode.auth.user_show('')",
        "CALL geode.auth.user_show(1)",
        "CALL geode.auth.user_show('alice', 'bob')",
        "CALL geode.auth.user_permissions()",
        "CALL geode.auth.user_permissions('')",
    }) |query| {
        try testing.expectError(error.InvalidArgs, h.run(query, .Admin, "operator"));
    }
}
