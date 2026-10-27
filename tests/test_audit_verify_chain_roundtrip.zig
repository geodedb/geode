// CANARY: REQ=REQ-GAP-0305-AUDIT-PREV-HASH; FEATURE="AuditVerifyChainRoundTrip"; ASPECT=ChainVerification; STATUS=TESTED; TEST=tests/test_audit_verify_chain_roundtrip.zig; OWNER=security; UPDATED=2026-05-21
//
// Regression test for geode issue #828 / GAP-0305.
//
// The writer in src/security/audit.zig:467-469 (appendEventLocked) stores
//     prev_hash = SHA256(self.last_hash)
// — i.e. the on-disk prev_hash is the SHA256 of the previous record's
// last_hash, NOT the bare last_hash.
//
// The verifier in src/cli/geode_audit_verify.zig:123 compares the on-disk
// prev_hash against last_hash directly, with no SHA256 step. Every record
// in every well-formed audit log mismatches, so `geode audit verify` always
// exits 3 (TAMPER chain) on a clean log.
//
// This test round-trips writer → verifier on a freshly written 3-event log
// and expects the verifier to accept it. Before the Task-2 fix the verifier
// will hit the std.process.exit(3) path on the first record, which kills
// the test runner; that counts as a failing test. After Task 2 the test
// passes cleanly.

const std = @import("std");
const testing = std.testing;
const audit = @import("audit");
const rls = @import("rls");
const verify = @import("audit_verify");

const AuditLogger = audit.AuditLogger;
const Config = AuditLogger.Config;
const AuditEvent = rls.AuditLogger.AuditEvent;

// Helper: build an absolute path inside the per-test tmp dir.
// Copied verbatim from tests/test_audit_chain.zig (Zig 0.16 getcwd shape).
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

test "verifier accepts a freshly-written 3-event chain (round-trip)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(dir_path);
    const full_path = try std.fs.path.join(allocator, &.{ dir_path, "roundtrip.jsonl" });
    defer allocator.free(full_path);

    // Writer: emit 3 events through the production AuditLogger path.
    {
        const config = Config{ .enabled = true, .file_path = full_path };
        var logger = try AuditLogger.init(allocator, config);
        defer logger.deinit();

        var i: u8 = 0;
        while (i < 3) : (i += 1) {
            var ev = AuditEvent{
                .timestamp = 1000 + @as(i64, i),
                .event_type = .data_access,
                .severity = .info,
                .user_id = @as(u32, i) + 1,
                .resource = .{ .type = "node", .id = "1", .name = "n", .graph = null, .table = null },
                .action = "read",
                .result = .success,
                .session_id = null,
                .details = null,
            };
            try logger.appendAuditEvent(&ev);
        }
    }

    // Verifier: must return OK (no error) on the well-formed chain.
    // Before the Task-2 fix this calls std.process.exit(3) on the first
    // record's prev_hash check, terminating the test runner. After the fix
    // it returns void normally.
    try verify.verifyFile(allocator, full_path, .sha256, 0, false, null, false);
}
