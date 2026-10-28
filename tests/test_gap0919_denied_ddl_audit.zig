// CANARY: REQ=REQ-GAP-0919-DENIED-DDL-AUDIT; FEATURE="AuditDenials"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0919_denied_ddl_audit.zig:1; OWNER=security; UPDATED=2026-07-10
//
// Regression tests for GAP-0919: "denied DDL-escalation attempts emit no
// audit record".
//
// Root cause: the admin-only gate in auth_dispatch.execute returned
// error.Unauthorized/Unauthenticated BEFORE any audit path ran, so non-admin
// CREATE USER / GRANT / REVOKE attempts (SQLSTATE 42501) left no trace — an
// authz-attack blind spot (successful GRANTs WERE audited). The policy-DDL
// admin gate (GAP-0911) had the same blind spot.
//
// Expected behavior after the fix: every denial emits an `access_denied`
// audit event (result=failure, severity=warning) naming the attempted
// action and the caller, through the same logSecurityGraphEvent path the
// success events use.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const audit = geode.security.audit;
const user_mgmt = geode.user_management;
const policy_catalog_mod = geode.security.policy_catalog;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

test "GAP-0919: denied auth DDL and policy DDL attempts are audited" {
    const allocator = testing.allocator;

    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    graph_store.setDataDirOverride(allocator, data_dir);
    _ = graph_store.getGlobalStore(allocator);
    defer {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const catalog = try execution.ensureCatalogInstance(allocator);
    var session = execution.SessionState.init(allocator);
    defer session.deinit();

    // Install an enabled audit logger with a tmp sink.
    const sink_path = try std.fmt.allocPrint(allocator, "{s}/audit.jsonl", .{data_dir});
    defer allocator.free(sink_path);
    const logger = try audit.AuditLogger.createHeap(allocator, .{
        .enabled = true,
        .file_path = sink_path,
    });
    defer {
        audit.setGlobalAuditLogger(null);
        logger.deinit();
        allocator.destroy(logger);
    }
    audit.setGlobalAuditLogger(logger);

    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();
    policy_catalog_mod.setGlobalCatalog(&cat);
    defer policy_catalog_mod.setGlobalCatalog(undefined);

    user_mgmt.setAuthEnabled(true);
    defer user_mgmt.setAuthEnabled(false);

    var ctx = execution.ExecutionContext{ .catalog = catalog };
    ctx.session_state = &session;
    ctx.role = .ReadOnly;
    ctx.user = "intruder";

    const exec = struct {
        fn run(al: std.mem.Allocator, c: execution.ExecutionContext, q: []const u8) !execution.ExecutionResult {
            var parsed = try geode.parseGqlOptions(q, al, .{});
            defer parsed.deinit();
            return execution.executeStatementWithContext(al, parsed.program.statements[0], c);
        }
    }.run;

    // Denied auth DDL: CREATE USER, CREATE ROLE.
    try testing.expectError(error.Unauthorized, exec(aa, ctx, "CREATE USER mallory SET PASSWORD 'sneaky12345'"));
    try testing.expectError(error.Unauthorized, exec(aa, ctx, "CREATE ROLE shadow"));

    // Denied policy DDL (GAP-0911 gate).
    try testing.expectError(error.Unauthorized, exec(aa, ctx, "CREATE POLICY p_evil ON GRAPH * FOR READ;"));

    // The audit sink must now contain access_denied records naming the
    // attempted actions and the caller.
    const io = std.Io.Threaded.global_single_threaded.io();
    const sink = try std.Io.Dir.cwd().readFileAlloc(io, sink_path, allocator, .limited(1 << 20));
    defer allocator.free(sink);

    try testing.expect(std.mem.indexOf(u8, sink, "access_denied") != null);
    try testing.expect(std.mem.indexOf(u8, sink, "geode.auth.user_create") != null);
    try testing.expect(std.mem.indexOf(u8, sink, "geode.auth.role_create") != null);
    try testing.expect(std.mem.indexOf(u8, sink, "GPS_CREATE_POLICY") != null);
    try testing.expect(std.mem.indexOf(u8, sink, "intruder") != null);
    try testing.expect(std.mem.indexOf(u8, sink, "failure") != null);
}
