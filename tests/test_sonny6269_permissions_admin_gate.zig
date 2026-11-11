// SONNY-6269: `SHOW PERMISSIONS FOR <user>` and
// `CALL geode.auth.user_permissions(<user>)` must enforce what
// docs/GQL_AUTH_DDL.md states: without FOR (or for itself) any authenticated
// user; another user's permissions need the Admin role.
//
// Before the fix `geode.auth.user_permissions` was in the read-only set with
// no check in its handler, so any authenticated user listed any other user's
// permissions. SONNY-1333 gave `geode.auth.grant_list` (SHOW GRANTS) the rule;
// this applies the same rule, through the same check: another user's answers
// 42501 and is audited as `access_denied`, like the admin-only procedures.
//
// The statements run through the in-process gRPC Execute handler with
// authorization on (the SONNY-1333 test's harness), and through the executor
// directly for a request with no authenticated role.
//
// CANARY: REQ=REQ-SONNY-6269-PERMISSIONS-ADMIN-GATE; FEATURE="GQL Auth DDL"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6269_permissions_admin_gate.zig; OWNER=security; UPDATED=2026-11-11

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
const execution = geode.execution;

/// Authorization on; users alice (readonly) and bob (readwrite) in the user
/// store; sessions for both and for an Admin; an audit logger writing to a
/// file in the harness's data directory.
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

        self.sink_path = try std.fmt.allocPrint(testing.allocator, "{s}/audit6269.jsonl", .{self.h.data_dir});
        self.logger = try audit.AuditLogger.createHeap(testing.allocator, .{ .enabled = true, .file_path = self.sink_path });
        audit.setGlobalAuditLogger(self.logger);

        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
        self.admin = try self.sessions.createSession("root6269", "", .Admin, null, null, false, 0);
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

    /// The audit file as written so far (caller frees).
    fn auditLog(self: *World) ![]u8 {
        const io = std.Io.Threaded.global_single_threaded.io();
        return std.Io.Dir.cwd().readFileAlloc(io, self.sink_path, testing.allocator, .limited(1 << 20));
    }
};

/// The rows a statement returned, each value a string or null.
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

/// The permission rows (username, permission) say `user` holds exactly
/// `want`, in order.
fn expectPermissions(rows: []const []const ?[]const u8, user: []const u8, want: []const []const u8) !void {
    if (rows.len != want.len) {
        std.debug.print("{s}: {d} permission rows, want {d}\n", .{ user, rows.len, want.len });
        return error.WrongPermissionRows;
    }
    for (rows, want) |r, w| {
        try testing.expectEqual(@as(usize, 2), r.len);
        try testing.expectEqualStrings(user, r[0].?);
        try testing.expectEqualStrings(w, r[1].?);
    }
}

test "SONNY-6269: a non-admin cannot list another user's permissions (42501, audited)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();

    _ = try fx.expectRefused(ga, w.alice, "SHOW PERMISSIONS FOR bob", "42501");
    _ = try fx.expectRefused(ga, w.alice, "CALL geode.auth.user_permissions('bob')", "42501");
    _ = try fx.expectRefused(ga, w.bob, "SHOW PERMISSIONS FOR alice", "42501");
    // A user that does not exist is another user too: no oracle.
    _ = try fx.expectRefused(ga, w.alice, "SHOW PERMISSIONS FOR nobody6269", "42501");

    const log = try w.auditLog();
    defer testing.allocator.free(log);
    // One access_denied record per refusal, naming the procedure and caller.
    var denied: usize = 0;
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "access_denied") == null) continue;
        if (std.mem.indexOf(u8, line, "geode.auth.user_permissions") == null) continue;
        try testing.expect(std.mem.indexOf(u8, line, "failure") != null);
        denied += 1;
    }
    try testing.expectEqual(@as(usize, 4), denied);
    try testing.expect(std.mem.indexOf(u8, log, "alice") != null);
}

test "SONNY-6269: any authenticated user lists its own permissions, with or without FOR" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();

    for ([_][]const u8{
        "SHOW PERMISSIONS",
        "SHOW PERMISSIONS FOR alice",
        "CALL geode.auth.user_permissions('alice')",
        "CALL geode.auth.user_permissions()",
    }) |q| {
        try expectPermissions(try queryRows(ga, w.alice, q), "alice", &.{"read"});
    }
    try expectPermissions(try queryRows(ga, w.bob, "SHOW PERMISSIONS"), "bob", &.{ "read", "write" });
}

test "SONNY-6269: an admin lists any user's permissions" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();

    try expectPermissions(try queryRows(ga, w.admin, "SHOW PERMISSIONS FOR bob"), "bob", &.{ "read", "write" });
    try expectPermissions(try queryRows(ga, w.admin, "CALL geode.auth.user_permissions('alice')"), "alice", &.{"read"});
}

test "SONNY-6269: a request with no authenticated role gets the answer SHOW GRANTS gives" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var session = execution.SessionState.init(testing.allocator);
    defer session.deinit();
    var ctx = w.h.ctx;
    ctx.session_state = &session;
    ctx.role = null;
    ctx.user = "alice";

    const exec = struct {
        fn run(al: std.mem.Allocator, c: execution.ExecutionContext, q: []const u8) anyerror!execution.ExecutionResult {
            var parsed = try geode.parseGqlOptions(q, al, .{});
            defer parsed.deinit();
            return execution.executeStatementWithContext(al, parsed.program.statements[0], c);
        }
    }.run;

    for ([_][2][]const u8{
        .{ "SHOW GRANTS FOR bob", "SHOW PERMISSIONS FOR bob" },
        .{ "SHOW GRANTS", "SHOW PERMISSIONS" },
    }) |pair| {
        const grants_err: ?anyerror = if (exec(aa, ctx, pair[0])) |_| null else |e| e;
        const perms_err: ?anyerror = if (exec(aa, ctx, pair[1])) |_| null else |e| e;
        try testing.expect(grants_err != null);
        try testing.expectEqual(grants_err, perms_err);
    }
}
