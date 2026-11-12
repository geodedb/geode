// SONNY-6291: the `geode.auth.apikey_*` procedures and `user_show` fail
// closed.
//
// The server has no API-key store: no procedure creates, stores, hashes or
// revokes a key, and the QUIC / gRPC handshake does not authenticate by one
// (the `geode apikey` CLI keeps its own local state file). The procedures
// were stubs: `apikey_check_scope` answered "scope granted" for any key,
// `apikey_revoke` answered "revoked" and revoked nothing, `apikey_create`
// printed a made-up key, `apikey_list` / `apikey_check_scope` told any caller
// whether a user exists. Each now answers 0A000 (not supported).
//
// `geode.auth.user_show` gave any authenticated user another user's email,
// role and status, and for a user that does not exist made a row up
// (unknown / user / active). It now follows the SONNY-6269 rule: a user may
// see itself, another user needs Admin (42501, audited); a missing user is
// an error, the same refusal as "not permitted" for a non-admin (no
// existence oracle), 42704 for an Admin. `user_permissions` for a missing
// user is 42704 for an Admin (it listed the `user` role's permissions).
//
// The statements run through the in-process gRPC Execute handler with
// authorization on.
//
// CANARY: REQ=REQ-SONNY-6291-APIKEY-USER-SHOW; FEATURE="GQL Auth DDL"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6291_apikey_user_show.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const audit = geode.security.audit;

/// Authorization on; users alice (readonly) and bob (readwrite); sessions
/// for both and for an Admin; an audit logger writing to a file.
const World = struct {
    h: harness.Harness,
    arena: std.heap.ArenaAllocator,
    sessions: grpc.SessionStore,
    sink_path: []u8,
    logger: *audit.AuditLogger,
    admin: []const u8 = "",
    alice: []const u8 = "",
    bob: []const u8 = "",
    auth_was: bool,
    allow_was: bool,
    strict_was: bool,

    fn init(self: *World) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        _ = graph_store.getGlobalStore(testing.allocator);
        _ = geode.txn_undo_log.getGlobalUndoLog(testing.allocator);

        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        self.allow_was = gps.isInsecureAllowAll();
        gps.setInsecureAllowAll(false);
        self.strict_was = geode.tenancy.isStrictTenancy();
        geode.tenancy.setStrictTenancy(false);

        user_mgmt.deinitUserStore();
        try user_mgmt.initUserStore(testing.allocator);
        try user_mgmt.createUserWithHash(testing.allocator, "alice", "not_a_real_hash", "alice@example.com", .ReadOnly, false);
        try user_mgmt.createUserWithHash(testing.allocator, "bob", "not_a_real_hash", "bob@example.com", .ReadWrite, false);

        self.sink_path = try std.fmt.allocPrint(testing.allocator, "{s}/audit6291.jsonl", .{self.h.data_dir});
        self.logger = try audit.AuditLogger.createHeap(testing.allocator, .{ .enabled = true, .file_path = self.sink_path });
        audit.setGlobalAuditLogger(self.logger);

        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
        self.admin = try self.sessions.createSession("root6291", "", .Admin, null, null, false, 0);
        self.alice = try self.sessions.createSession("alice", "", .ReadOnly, null, null, false, 0);
        self.bob = try self.sessions.createSession("bob", "", .ReadWrite, null, null, false, 0);
    }

    fn deinit(self: *World) void {
        grpc.setSessionStore(null);
        self.sessions.deinit();
        self.arena.deinit();
        audit.setGlobalAuditLogger(null);
        self.logger.deinit();
        testing.allocator.destroy(self.logger);
        testing.allocator.free(self.sink_path);
        user_mgmt.deinitUserStore();
        geode.tenancy.setStrictTenancy(self.strict_was);
        gps.setInsecureAllowAll(self.allow_was);
        user_mgmt.setAuthEnabled(self.auth_was);
        geode.txn_undo_log.setThreadTxnId(0);
        self.h.deinit();
    }

    fn ga(self: *World) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn auditLog(self: *World) ![]u8 {
        const io = std.Io.Threaded.global_single_threaded.io();
        return std.Io.Dir.cwd().readFileAlloc(io, self.sink_path, testing.allocator, .limited(1 << 20));
    }
};

/// The string values of the rows a statement returned.
fn queryRows(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) ![]const []const ?[]const u8 {
    const resp = try fx.execute(ga, session_id, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("{s}: refused {s} {s}\n", .{ query, e.code, e.message });
            return error.Refused;
        },
        else => {},
    }
    var out = std.ArrayList([]const ?[]const u8).empty;
    var pulls: usize = 0;
    while (pulls < 32) : (pulls += 1) {
        const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = session_id, .page_size = 64 });
        const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
        const presp = pull.response orelse return error.MissingPayload;
        const page = switch (presp.payload orelse return error.MissingPayload) {
            .page => |p| p,
            else => return error.UnexpectedPayload,
        };
        for (page.rows.items) |row| {
            const vals = try ga.alloc(?[]const u8, row.values.items.len);
            for (row.values.items, 0..) |v, i| {
                vals[i] = if (v.kind) |k| switch (k) {
                    .string_val => |s| s.value,
                    else => null,
                } else null;
            }
            try out.append(ga, vals);
        }
        if (page.final) return out.toOwnedSlice(ga);
    }
    return error.PullNeverFinished;
}

const ApikeyCall = struct { q: []const u8, mutating: bool };

const apikey_calls = [_]ApikeyCall{
    .{ .q = "CALL geode.auth.apikey_create('bob', 'k6291', 'read')", .mutating = true },
    .{ .q = "CALL geode.auth.apikey_revoke('bob', 'k6291')", .mutating = true },
    .{ .q = "CALL geode.auth.apikey_revoke_all('bob')", .mutating = true },
    .{ .q = "CALL geode.auth.apikey_list('bob')", .mutating = false },
    .{ .q = "CALL geode.auth.apikey_list('nobody6291')", .mutating = false },
    .{ .q = "CALL geode.auth.apikey_check_scope('bob', 'k6291', 'write')", .mutating = false },
    .{ .q = "CALL geode.auth.apikey_check_scope('nobody6291', 'k6291', 'write')", .mutating = false },
};

test "SONNY-6291: every geode.auth.apikey_* procedure answers not supported (0A000), never granted or revoked; the mutating ones still need Admin" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();

    for (apikey_calls) |c| {
        _ = try fx.expectRefused(ga, w.admin, c.q, "0A000");
        for ([_][]const u8{ w.alice, w.bob }) |s| {
            // Admin-only before anything else; the read-only ones are not
            // supported for anyone (and say nothing about the user).
            _ = try fx.expectRefused(ga, s, c.q, if (c.mutating) "42501" else "0A000");
        }
    }
    // The two unknown-user calls answer exactly what the known-user calls do.
    const known = try fx.expectRefused(ga, w.alice, "CALL geode.auth.apikey_check_scope('bob', 'k6291', 'write')", "0A000");
    const unknown = try fx.expectRefused(ga, w.alice, "CALL geode.auth.apikey_check_scope('nobody6291', 'k6291', 'write')", "0A000");
    try testing.expectEqualStrings(known.message, unknown.message);
}

test "SONNY-6291: user_show: a user sees itself; another user's needs Admin (42501, audited), the same refusal whether or not it exists" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();

    const own = try queryRows(ga, w.alice, "CALL geode.auth.user_show('alice')");
    try testing.expectEqual(@as(usize, 1), own.len);
    try testing.expectEqualStrings("alice", own[0][0].?);
    try testing.expectEqualStrings("alice@example.com", own[0][1].?);
    try testing.expectEqualStrings("readonly", own[0][2].?);
    try testing.expectEqualStrings("active", own[0][3].?);

    const other = try fx.expectRefused(ga, w.alice, "CALL geode.auth.user_show('bob')", "42501");
    const missing = try fx.expectRefused(ga, w.alice, "CALL geode.auth.user_show('nobody6291')", "42501");
    try testing.expectEqualStrings(other.message, missing.message);
    _ = try fx.expectRefused(ga, w.bob, "CALL geode.auth.user_show('alice')", "42501");

    const log = try w.auditLog();
    defer testing.allocator.free(log);
    var denied: usize = 0;
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "access_denied") == null) continue;
        if (std.mem.indexOf(u8, line, "geode.auth.user_show") == null) continue;
        denied += 1;
    }
    try testing.expectEqual(@as(usize, 3), denied);
}

test "SONNY-6291: an admin sees any user with user_show; a missing user is an error, not a made-up row" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();

    const bob = try queryRows(ga, w.admin, "CALL geode.auth.user_show('bob')");
    try testing.expectEqual(@as(usize, 1), bob.len);
    try testing.expectEqualStrings("bob", bob[0][0].?);
    try testing.expectEqualStrings("bob@example.com", bob[0][1].?);
    try testing.expectEqualStrings("readwrite", bob[0][2].?);

    _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.user_show('nobody6291')", "42704");
    _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.user_permissions('nobody6291')", "42704");
    _ = try fx.expectRefused(ga, w.admin, "SHOW PERMISSIONS FOR nobody6291", "42704");
}
