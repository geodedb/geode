// SONNY-6291: real authenticated executor calls must never fabricate API-key
// authorization or disclose another user's profile. No database responses are
// mocked: users, catalog, executor and audit sink are the production modules.
// CANARY: REQ=REQ-SONNY-6291-AUTH-PROCEDURES; FEATURE="Auth procedure safety"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6291_auth_procedures.zig; OWNER=security; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const execution = geode.execution;
const graph_store = geode.graph_store;
const users = geode.user_management;
const audit = geode.security.audit;

const Harness = struct {
    tmp: testing.TmpDir,
    data_dir: []u8,
    audit_path: []u8,
    logger: *audit.AuditLogger,
    catalog: *geode.catalog.Catalog,
    arena: std.heap.ArenaAllocator,
    auth_was: bool,

    fn init() !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        users.deinitUserStore();
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = try std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf);
        const cwd = std.mem.trimEnd(u8, cwd_buf[0..cwd_len], "\x00");
        const data_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd, tmp.sub_path });
        errdefer testing.allocator.free(data_dir);
        graph_store.setDataDirOverride(testing.allocator, data_dir);
        _ = graph_store.getGlobalStore(testing.allocator);
        const catalog = try execution.ensureCatalogInstance(testing.allocator);
        const audit_path = try std.fmt.allocPrint(testing.allocator, "{s}/audit.jsonl", .{data_dir});
        errdefer testing.allocator.free(audit_path);
        const logger = try audit.AuditLogger.createHeap(testing.allocator, .{ .enabled = true, .file_path = audit_path });
        audit.setGlobalAuditLogger(logger);
        try users.createUserWithHash(testing.allocator, "alice", "unused-test-hash", "alice@example.test", .User, false);
        try users.createUserWithHash(testing.allocator, "bob", "unused-test-hash", "bob@example.test", .ReadOnly, false);
        const auth_was = users.isAuthEnabled();
        users.setAuthEnabled(true);
        return .{ .tmp = tmp, .data_dir = data_dir, .audit_path = audit_path, .logger = logger, .catalog = catalog, .arena = std.heap.ArenaAllocator.init(testing.allocator), .auth_was = auth_was };
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
        users.setAuthEnabled(self.auth_was);
        users.deinitUserStore();
        audit.setGlobalAuditLogger(null);
        self.logger.deinit();
        testing.allocator.destroy(self.logger);
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.audit_path);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    fn run(self: *Harness, query: []const u8, role: ?users.Role, username: ?[]const u8) !execution.ExecutionResult {
        const allocator = self.arena.allocator();
        var parsed = try geode.parseGql(query, allocator);
        defer parsed.deinit();
        return execution.executeStatementWithContext(allocator, parsed.program.statements[0], .{ .catalog = self.catalog, .role = role, .user = username });
    }
};

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
