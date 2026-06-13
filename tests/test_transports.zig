const std = @import("std");
const testing = std.testing;
// CANARY: REQ=REQ-QUALITY-GAP-413-004; FEATURE="OrphanedTestRemediation"; ASPECT=AuditTransports; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
const audit_lib = @import("audit_lib");
const events = audit_lib.events;
const config = audit_lib.config;
const syslog = audit_lib.syslog;
const file_sink = audit_lib.file_sink;
const time = audit_lib.time;

test "syslog RFC5424 formatting" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fixed_clock = time.FixedClock.init(time.TEST_TIMESTAMP_MS);
    const clock = fixed_clock.clock();

    const service_config = config.ServiceConfig{
        .name = "authsvc",
        .host = "app-host",
        .pid = 1234,
    };

    const identity_config = config.CefIdentityConfig{
        .vendor = "DEVNW",
        .product = "GEODE",
        .version = "0.1.0",
    };

    const syslog_config = config.SyslogSinkConfig{
        .enabled = true,
        .protocol = .udp,
        .host = "{{SYSLOG_HOST}}", // Mock host
        .port = 514,
        .rfc5424 = config.SyslogRfc5424Config{
            .facility = .local4,
        },
    };

    var mock_sender = try syslog.MockSyslogSender.init(allocator);
    defer mock_sender.deinit();

    const event = events.AuditEvent{
        .category = "auth",
        .action = "login",
        .outcome = .success,
        .ts_unix_ms = time.TEST_TIMESTAMP_MS,
        .severity = .INFO,
        .actor_id = "jane.doe",
        .subject_id = null,
        .request_id = "req-abc123",
        .session_id = "ses-999",
        .source_ip = "203.0.113.5",
        .trace_id = time.TEST_TRACE_ID,
        .span_id = time.TEST_SPAN_ID,
        .metadata = null,
    };

    try mock_sender.send(&event, &identity_config, &service_config, &syslog_config, clock);

    const messages = mock_sender.getMessages();
    try testing.expect(messages.len == 1);

    const expected_line = "<166>1 2025-01-01T00:00:00.000Z app-host authsvc 1234 AUDIT - CEF:0|DEVNW|GEODE|0.1.0|auth.login|User login|5|rt=2025-01-01T00:00:00.000Z act=login outcome=success suser=jane.doe src=203.0.113.5 requestId=req-abc123 traceId=11111111111111111111111111111111 spanId=2222222222222222 cs1Label=actorId cs1=jane.doe cs2Label=sessionId cs2=ses-999 deviceExternalId=req-abc123";

    try testing.expectEqualStrings(expected_line, messages[0]);
}

test "syslog severity and facility calculation" {
    // Test facility and severity calculation
    // local4 = 20, INFO severity = 6, so PRI = 20*8 + 6 = 166
    const facility = config.SyslogFacility.local4;
    const severity = events.Severity.INFO;

    try testing.expect(facility.toInt() == 20);
    try testing.expect(severity.toSyslogSeverity() == 6);

    const pri = facility.toInt() * 8 + severity.toSyslogSeverity();
    try testing.expect(pri == 166);
}

test "file sink JSON formatting" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fixed_clock = time.FixedClock.init(time.TEST_TIMESTAMP_MS);
    const clock = fixed_clock.clock();

    // Create test directory
    const test_dir = "zig-out/tmp/test-file-sink";
    std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), test_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), test_dir) catch {};

    const file_config = config.FileSinkConfig{
        .enabled = true,
        .path = test_dir ++ "/test.log",
        .max_bytes = 1024 * 1024,
        .backup_count = 3,
    };

    const sink = try file_sink.FileSink.init(allocator, file_config, clock);

    // Create test metadata
    var metadata_obj: std.json.ObjectMap = .{};
    defer metadata_obj.deinit(allocator);
    try metadata_obj.put(allocator, "user_action", std.json.Value{ .string = "profile_update" });
    try metadata_obj.put(allocator, "request_size", std.json.Value{ .integer = 1024 });
    const metadata = std.json.Value{ .object = metadata_obj };

    const event = events.AuditEvent{
        .category = "auth",
        .action = "login",
        .outcome = .success,
        .ts_unix_ms = time.TEST_TIMESTAMP_MS,
        .severity = .INFO,
        .actor_id = "test-user",
        .subject_id = "test-subject",
        .request_id = "req-test-001",
        .session_id = "ses-test-001",
        .source_ip = "192.168.1.1",
        .trace_id = time.TEST_TRACE_ID,
        .span_id = time.TEST_SPAN_ID,
        .metadata = metadata,
    };

    // audit FileSink is async (enqueue → background worker); deinit drains
    // all queued writes to disk before closing, so deinit BEFORE readback.
    _ = try sink.write(&event, metadata);
    sink.deinit();

    // Read back the file and verify JSON format
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().openFile(io_fs, file_config.path, .{});
    defer file.close(io_fs);

    var file_reader_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io_fs, &file_reader_buf);
    const content = try file_reader.interface.allocRemaining(allocator, .limited(8192));
    defer allocator.free(content);

    // Parse the JSON line
    const line = std.mem.trim(u8, content, " \n\r\t");
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    const json_obj = parsed.value.object;

    // Verify required fields
    try testing.expect(json_obj.contains("ts"));
    try testing.expect(json_obj.contains("category"));
    try testing.expect(json_obj.contains("action"));
    try testing.expect(json_obj.contains("outcome"));
    try testing.expect(json_obj.contains("severity"));
    try testing.expect(json_obj.contains("actor_id"));

    // Verify values
    try testing.expectEqualStrings("auth", json_obj.get("category").?.string);
    try testing.expectEqualStrings("login", json_obj.get("action").?.string);
    try testing.expectEqualStrings("success", json_obj.get("outcome").?.string);
    try testing.expectEqualStrings("test-user", json_obj.get("actor_id").?.string);

    // Verify metadata was included
    try testing.expect(json_obj.contains("user_action"));
    try testing.expectEqualStrings("profile_update", json_obj.get("user_action").?.string);
    try testing.expect(json_obj.get("request_size").?.integer == 1024);
}

test "file rotation" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fixed_clock = time.FixedClock.init(time.TEST_TIMESTAMP_MS);
    const clock = fixed_clock.clock();

    // Create test directory
    const test_dir = "zig-out/tmp/test-rotation";
    std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), test_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), test_dir) catch {};

    const file_config = config.FileSinkConfig{
        .enabled = true,
        .path = test_dir ++ "/rotate.log",
        .max_bytes = 512, // Small size to force rotation
        .backup_count = 2,
    };

    const sink = try file_sink.FileSink.init(allocator, file_config, clock);

    // Write many events to trigger rotation
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const event = events.AuditEvent{
            .category = "test",
            .action = "rotation_test",
            .outcome = .success,
            .ts_unix_ms = time.TEST_TIMESTAMP_MS,
            .severity = .INFO,
            .actor_id = "rotation-test-user",
            .subject_id = null,
            .request_id = null,
            .session_id = null,
            .source_ip = null,
            .trace_id = null,
            .span_id = null,
            .metadata = null,
        };

        _ = try sink.write(&event, null);
    }

    // deinit drains all queued writes to disk before closing, so rotation
    // and backup files are present before the access checks below.
    sink.deinit();

    // Check that backup files exist (Zig 0.15 access returns void on success, error on failure)
    // CANARY: REQ=REQ-QUALITY-GAP-413-015; FEATURE="OrphanedTestRemediation"; ASPECT=FileAccessAPI; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
    const file_exists = blk: {
        std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), test_dir ++ "/rotate.log", .{}) catch break :blk false;
        break :blk true;
    };
    try testing.expect(file_exists);
    const backup_exists = blk: {
        std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), test_dir ++ "/rotate.log.1", .{}) catch break :blk false;
        break :blk true;
    };
    try testing.expect(backup_exists);
    // rotate.log.2 may or may not exist depending on how many rotations occurred
}

test "syslog protocol enum parsing" {
    try testing.expect(try config.SyslogProtocol.fromString("udp") == .udp);
    try testing.expect(try config.SyslogProtocol.fromString("tcp") == .tcp);
    try testing.expect(try config.SyslogProtocol.fromString("tls") == .tls);

    try testing.expectError(error.InvalidProtocol, config.SyslogProtocol.fromString("invalid"));
}

test "syslog facility enum parsing and mapping" {
    try testing.expect(try config.SyslogFacility.fromString("local0") == .local0);
    try testing.expect(try config.SyslogFacility.fromString("local4") == .local4);
    try testing.expect(try config.SyslogFacility.fromString("local7") == .local7);

    try testing.expectError(error.InvalidFacility, config.SyslogFacility.fromString("invalid"));

    // Test facility code mapping
    try testing.expect(config.SyslogFacility.local0.toInt() == 16);
    try testing.expect(config.SyslogFacility.local1.toInt() == 17);
    try testing.expect(config.SyslogFacility.local4.toInt() == 20);
    try testing.expect(config.SyslogFacility.local7.toInt() == 23);
}

test "event outcome enum string conversion" {
    try testing.expectEqualStrings("success", events.Outcome.success.toString());
    try testing.expectEqualStrings("failure", events.Outcome.failure.toString());
    try testing.expectEqualStrings("deny", events.Outcome.deny.toString());
    try testing.expectEqualStrings("error", events.Outcome.@"error".toString());
}
