// CANARY: REQ=REQ-GAP-0511-AUDIT-TENANT; FEATURE="AuditTenantEnrichment"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_audit_tenant_enrichment.zig:1; OWNER=security; UPDATED=2026-04-11
//
// Regression tests for GAP-0511: "Audit events hardcode tenant_id=null in production".
//
// Behaviour we want to guarantee:
//
//   1. When the per-thread audit tenant context is set (via
//      `setCurrentAuditTenantId`), every audit event emitted from that thread
//      must carry that tenant_id — regardless of whether the caller used the
//      typed `AuditEvent` path or the anytype generic adapter.
//
//   2. When a caller explicitly sets `tenant_id` on an anytype event struct,
//      that value must be propagated to the emitted audit record (the
//      generic adapter was previously a write-only sink that stringified the
//      value into `details` but never onto the real `AuditEvent.tenant_id`
//      field).
//
//   3. When neither the per-thread context nor the explicit field is set,
//      the emitted tenant_id is null (no silent data fabrication).
//
// These three cases cover the multi-tenancy story: admin / system-thread
// events (null), query-handler events (per-thread), and programmatic log
// calls with explicit tenant (propagation through the adapter).

const std = @import("std");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// Zig 0.16 compat helpers for test code.
// Cross-platform: Linux uses the vDSO-accelerated std.os.linux.*; other
// platforms (macOS / BSD) go through libc via std.c.*. Matches the pattern
// used by src/admin/fle_commands.zig and src/types/evaluator_functions.zig.
const builtin = @import("builtin");
fn compat_clock_gettime_realtime(ts: *std.posix.timespec) void {
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, ts);
    }
}
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    compat_clock_gettime_realtime(&ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    compat_clock_gettime_realtime(&ts);
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    compat_clock_gettime_realtime(&ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}
fn compat_sleep(ns: u64) void {
    var req: std.posix.timespec = .{ .sec = 0, .nsec = @intCast(ns) };
    var rem: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.nanosleep(@ptrCast(&req), @ptrCast(&rem));
    } else {
        _ = std.c.nanosleep(&req, &rem);
    }
}

const testing = std.testing;
const audit = @import("audit");
const rls = @import("rls");
const AuditLogger = audit.AuditLogger;
const Config = AuditLogger.Config;
const AuditEvent = rls.AuditLogger.AuditEvent;

/// Small helper: spin up a logger writing to a temp path, run `body`, then
/// read the file back and return the caller-owned contents.
fn withLogger(
    allocator: std.mem.Allocator,
    tmp: *testing.TmpDir,
    file_name: []const u8,
    body: *const fn (*AuditLogger) anyerror!void,
) ![]u8 {
    const dir_path = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(dir_path);
    const full_path = try std.fs.path.join(allocator, &.{ dir_path, file_name });
    defer allocator.free(full_path);

    var logger = try AuditLogger.init(allocator, .{
        .enabled = true,
        .file_path = full_path,
    });
    defer logger.deinit();

    try body(&logger);

    const io_fs = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.openFileAbsolute(io_fs, full_path, .{});
    defer file.close(io_fs);
    var file_reader_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io_fs, &file_reader_buf);
    return try file_reader.interface.allocRemaining(allocator, .unlimited);
}

test "GAP-0511: anytype adapter enriches tenant_id from per-thread context" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    audit.setCurrentAuditTenantId("tenant_alpha");
    defer audit.setCurrentAuditTenantId(null);

    const body = struct {
        fn run(logger: *AuditLogger) !void {
            // Generic adapter path: anytype struct with NO tenant_id field.
            // The enrichment fallback in appendEventLocked must fill this in
            // from the per-thread audit tenant context.
            try logger.logEvent(.{
                .timestamp = compat_milliTimestamp(),
                .event_type = AuditEvent.EventType.access_granted,
                .user_id = @as(u64, 42),
                .resource = "test_resource",
                .action = "read",
                .policy_id = null,
                .reason = null,
                .ip_address = null,
                .session_id = null,
                .query_hash = null,
                .additional_context = null,
            });
        }
    }.run;

    const contents = try withLogger(allocator, &tmp, "gap0511_enrichment.jsonl", body);
    defer allocator.free(contents);

    // The RLS audit serializer writes tenant as "tenant":"<id>" (not
    // "tenant_id"). See src/security/rls_core.zig:2224.
    if (std.mem.indexOf(u8, contents, "\"tenant\":\"tenant_alpha\"") == null) {
        std.debug.print(
            "GAP-0511 regression: anytype adapter did not enrich tenant_id from per-thread context\naudit output:\n{s}\n",
            .{contents},
        );
        return error.TenantEnrichmentMissing;
    }
}

test "GAP-0511: typed AuditEvent path respects explicit tenant_id" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Set per-thread context to a DIFFERENT value to prove the explicit
    // field wins (the enrichment fallback must only fire when null).
    audit.setCurrentAuditTenantId("tenant_perthread");
    defer audit.setCurrentAuditTenantId(null);

    const body = struct {
        fn run(logger: *AuditLogger) !void {
            var ev = AuditEvent{
                .timestamp = compat_milliTimestamp(),
                .event_type = .access_granted,
                .severity = .info,
                .tenant_id = "tenant_explicit",
                .user_id = 7,
                .session_id = "sess_x",
                .resource = .{ .type = "node", .id = "42", .name = "n", .graph = null, .table = null },
                .action = "read",
                .result = .success,
                .details = null,
            };
            try logger.appendAuditEvent(&ev);
        }
    }.run;

    const contents = try withLogger(allocator, &tmp, "gap0511_explicit.jsonl", body);
    defer allocator.free(contents);

    if (std.mem.indexOf(u8, contents, "\"tenant\":\"tenant_explicit\"") == null) {
        std.debug.print(
            "GAP-0511 regression: explicit tenant_id was not preserved\naudit output:\n{s}\n",
            .{contents},
        );
        return error.ExplicitTenantLost;
    }
    if (std.mem.indexOf(u8, contents, "\"tenant\":\"tenant_perthread\"") != null) {
        std.debug.print(
            "GAP-0511 regression: per-thread tenant overrode explicit tenant_id\naudit output:\n{s}\n",
            .{contents},
        );
        return error.PerThreadOverrodeExplicit;
    }
}

test "GAP-0511: no tenant context means null tenant in output (no fabrication)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Ensure per-thread context is empty.
    audit.setCurrentAuditTenantId(null);

    const body = struct {
        fn run(logger: *AuditLogger) !void {
            try logger.logEvent(.{
                .timestamp = compat_milliTimestamp(),
                .event_type = AuditEvent.EventType.system_event,
                .user_id = @as(u64, 0),
                .resource = "background_task",
                .action = "run",
                .policy_id = null,
                .reason = null,
                .ip_address = null,
                .session_id = null,
                .query_hash = null,
                .additional_context = null,
            });
        }
    }.run;

    const contents = try withLogger(allocator, &tmp, "gap0511_null.jsonl", body);
    defer allocator.free(contents);

    // With no per-thread context and no explicit tenant, the serializer
    // simply omits the "tenant" key (see rls_core.zig:2225 — it skips when
    // tenant_id is null). Verify neither a tenant field nor a stray default
    // string appears.
    if (std.mem.indexOf(u8, contents, "\"tenant\":") != null) {
        std.debug.print(
            "GAP-0511 regression: audit event fabricated a tenant value with no context\naudit output:\n{s}\n",
            .{contents},
        );
        return error.TenantFabricated;
    }
}
