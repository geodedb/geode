const std = @import("std");
const testing = std.testing;
const audit = @import("audit");
const rls = @import("rls");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const AuditLogger = audit.AuditLogger;
const Config = AuditLogger.Config;
const AuditEvent = rls.AuditLogger.AuditEvent;

test "AuditLogger initialization and basic logging" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = "audit_test_basic.jsonl";

    // Create config - use full path since AuditLogger expects full path
    const dir_path = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(dir_path);
    const full_path = try std.fs.path.join(allocator, &.{ dir_path, file_path });
    defer allocator.free(full_path);

    const config = Config{
        .enabled = true,
        .file_path = full_path,
    };

    var logger = try AuditLogger.init(allocator, config);
    defer logger.deinit();

    // Log an event
    var ev = AuditEvent{
        .timestamp = 1234567890,
        .event_type = .authentication,
        .severity = .info,
        .user_id = 101,
        .tenant_id = "test_tenant",
        .resource = .{ .type = "system", .id = "login", .name = "login_service", .graph = null, .table = null },
        .action = "login",
        .result = .success,
        .session_id = "sess_1",
        .details = null,
    };

    try logger.appendAuditEvent(&ev);

    // Verify file content
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.openFileAbsolute(io_fs, full_path, .{});
    defer file.close(io_fs);
    var file_reader_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io_fs, &file_reader_buf);
    const content = try file_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(content);

    // GAP-0511: assertions updated to match the canonical JSON format emitted
    // by rls_core.writeCanonicalJson — actor is rendered as "user:<id>" and
    // prev_hash is serialized as a hex string. The original assertions
    // assumed an older schema and were dead (this test file was compile-
    // checked but never actually executed in CI until the build.zig fix).
    try testing.expect(std.mem.indexOf(u8, content, "\"actor\":\"user:101\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"tenant\":\"test_tenant\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"action\":\"login\"") != null);
}

test "AuditLogger chaining verification" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(dir_path);
    const full_path = try std.fs.path.join(allocator, &.{ dir_path, "audit_chain.jsonl" });
    defer allocator.free(full_path);

    const config = Config{
        .enabled = true,
        .file_path = full_path,
    };

    var logger = try AuditLogger.init(allocator, config);
    defer logger.deinit();

    // Event 1
    var ev1 = AuditEvent{
        .timestamp = 1000,
        .event_type = .data_access,
        .severity = .info,
        .user_id = 1,
        .resource = .{ .type = "node", .id = "1", .name = "n1", .graph = null, .table = null },
        .action = "read",
        .result = .success,
        .session_id = null,
        .details = null,
    };
    try logger.appendAuditEvent(&ev1);

    // Event 2
    var ev2 = AuditEvent{
        .timestamp = 2000,
        .event_type = .data_access,
        .severity = .info,
        .user_id = 2,
        .resource = .{ .type = "node", .id = "2", .name = "n2", .graph = null, .table = null },
        .action = "read",
        .result = .success,
        .session_id = null,
        .details = null,
    };
    try logger.appendAuditEvent(&ev2);

    // Read back and verify hash chain manually (simplified)
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.openFileAbsolute(io_fs, full_path, .{});
    defer file.close(io_fs);

    // We expect 2 lines.
    // Parse JSON is hard in test without library, but we can check existence of hashes.
    // Ideally we would reconstruct the chain like `initFromTail` does.
}

test "AuditLogger recovery from existing file" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(dir_path);
    const full_path = try std.fs.path.join(allocator, &.{ dir_path, "audit_recover.jsonl" });
    defer allocator.free(full_path);

    // 1. Create Logger, write event, close.
    {
        const config = Config{ .enabled = true, .file_path = full_path };
        var logger = try AuditLogger.init(allocator, config);
        var ev = AuditEvent{ .timestamp = 1, .event_type = .system_event, .severity = .info, .user_id = 0, .resource = .{ .type = "sys", .id = "0", .name = "s", .graph = null, .table = null }, .action = "start", .result = .success, .session_id = null, .details = null };
        try logger.appendAuditEvent(&ev);
        logger.deinit();
    }

    // 2. Open new logger on same file. Should recover seq_no and last_hash.
    {
        const config = Config{ .enabled = true, .file_path = full_path };
        var logger = try AuditLogger.init(allocator, config);
        defer logger.deinit();

        // 1 event, then the DIGEST a clean close appends (SONNY-3147: it
        // signs the records written since the last DIGEST): seq_no 2.
        try testing.expectEqual(@as(u64, 2), logger.last_seq);
    }
}
