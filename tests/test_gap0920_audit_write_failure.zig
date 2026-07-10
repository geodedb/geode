// CANARY: REQ=REQ-GAP-0920-AUDIT-WRITE-FAILURE-DIAGNOSTIC; FEATURE="AuditDurability"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0920_audit_write_failure.zig:1; OWNER=security; UPDATED=2026-07-10
//
// Regression tests for GAP-0920: "mid-run audit write failure produces no
// diagnostic".
//
// Root cause: the single audit write funnel (appendEventLocked) did a bare
// `try f.writePositionalAll(...)`. A genuine mid-run write failure (EFBIG
// under prlimit --fsize, ENOSPC on a full disk) advanced the seq counter and
// hash chain, then propagated an error that several call sites swallow —
// producing zero diagnostic anywhere (a silent, invisible audit gap).
//
// The trigger here is /dev/full, whose writes always fail with ENOSPC — a
// deterministic mid-run write failure with no process-killing signal (unlike
// RLIMIT_FSIZE's SIGXFSZ).
//
// Expected behavior after the fix: the write failure emits a loud diagnostic
// at the funnel, flags the logger degraded (isWriteDegraded / writeFailure-
// Count are queryable), rolls the chain state back so it stays consistent,
// and re-raises the error.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");

const audit = geode.security.audit;

test "GAP-0920: a mid-run audit write failure is diagnosable (degraded flag + count) and consistent" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.Io.Threaded.global_single_threaded.io();

    // /dev/full: opens fine, every write returns ENOSPC.
    const devfull = std.Io.Dir.cwd().openFile(io, "/dev/full", .{ .mode = .write_only }) catch return error.SkipZigTest;

    // Build a disabled logger (skips real file open + key load), then wire it
    // to /dev/full and enable it — exactly the state a live logger is in when
    // its sink starts failing writes mid-run.
    var logger = try audit.AuditLogger.init(testing.allocator, .{ .enabled = false });
    defer logger.deinit();
    logger.file = devfull;
    logger.config.enabled = true;
    logger.enabled = true;

    try testing.expect(!logger.isWriteDegraded());
    try testing.expectEqual(@as(u64, 0), logger.writeFailureCount());

    var ev = audit.AuditEvent{
        .timestamp = 1,
        .event_type = .access_denied,
        .severity = .warning,
        .tenant_id = null,
        .user_id = 7,
        .session_id = "",
        .resource = .{ .type = "graph", .id = "g", .name = "g", .graph = "g", .table = null },
        .action = "GAP0920_PROBE",
        .result = .failure,
        .details = null,
    };

    // The write must fail AND be observable, not silent.
    try testing.expectError(error.NoSpaceLeft, logger.appendAuditEvent(&ev));
    try testing.expect(logger.isWriteDegraded());
    try testing.expectEqual(@as(u64, 1), logger.writeFailureCount());

    // Chain state rolled back: the failed record did not advance the seq
    // counter (so the NEXT successful write is contiguous, not gapped).
    try testing.expectEqual(@as(u64, 0), logger.last_seq);

    // A second failure increments the count and keeps the flag latched.
    try testing.expectError(error.NoSpaceLeft, logger.appendAuditEvent(&ev));
    try testing.expectEqual(@as(u64, 2), logger.writeFailureCount());
    try testing.expectEqual(@as(u64, 0), logger.last_seq);
}

test "GAP-0920: recovery to a writable sink clears the degraded flag and resumes the chain" {
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const devfull = std.Io.Dir.cwd().openFile(io, "/dev/full", .{ .mode = .write_only }) catch return error.SkipZigTest;

    var logger = try audit.AuditLogger.init(testing.allocator, .{ .enabled = false });
    defer logger.deinit();
    logger.file = devfull;
    logger.config.enabled = true;
    logger.enabled = true;

    var ev = audit.AuditEvent{
        .timestamp = 1,
        .event_type = .access_denied,
        .severity = .warning,
        .tenant_id = null,
        .user_id = 1,
        .session_id = "",
        .resource = .{ .type = "graph", .id = "g", .name = "g", .graph = "g", .table = null },
        .action = "GAP0920_PROBE",
        .result = .failure,
        .details = null,
    };
    try testing.expectError(error.NoSpaceLeft, logger.appendAuditEvent(&ev));
    try testing.expect(logger.isWriteDegraded());

    // Swap in a real writable sink and log again: success clears the flag and
    // the chain advances from where it was (seq 0 -> 1, no gap).
    const good = try tmp.dir.createFile(io, "audit.jsonl", .{ .truncate = true, .read = true });
    logger.file.?.close(io);
    logger.file = good;

    try logger.appendAuditEvent(&ev);
    try testing.expect(!logger.isWriteDegraded());
    try testing.expectEqual(@as(u64, 1), logger.last_seq);
}
