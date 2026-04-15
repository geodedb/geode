const std = @import("std");
const audit_lib = @import("audit_lib");
const events = audit_lib.events;
const config = audit_lib.config;
const logger = audit_lib.logger;
const db_adapter = @import("audit/db_adapter.zig");
const time = audit_lib.time;
const test_support = @import("audit/test_support.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Audit Logging & Tracing Demo\n");
    std.debug.print("============================\n\n");

    // Load configuration
    const audit_config = config.loadConfig(allocator, "config/logging.json") catch |err| switch (err) {
        error.ConfigNotFound => blk: {
            std.debug.print("Config file not found, using default configuration\n");
            break :blk try test_support.loadTestConfig(allocator);
        },
        else => return err,
    };
    defer audit_config.deinit();

    std.debug.print("Configuration loaded:\n");
    std.debug.print("  Service: {s}@{s}:{d}\n", .{ audit_config.service.name, audit_config.service.host, audit_config.service.pid });
    std.debug.print("  File sink: {s} (enabled: {})\n", .{ audit_config.sinks.file.path, audit_config.sinks.file.enabled });
    std.debug.print("  Syslog sink: {s}:{d} (enabled: {})\n", .{ audit_config.sinks.syslog.host, audit_config.sinks.syslog.port, audit_config.sinks.syslog.enabled });
    std.debug.print("\n");

    // Create system clock and ID generator
    var sys_clock = time.SystemClock{};
    var sys_id_gen = time.SystemIdGen.init();

    // Initialize audit logger
    const audit_logger = try logger.AuditLogger.init(
        allocator,
        audit_config,
        sys_clock.clock(),
        sys_id_gen.idGen(),
    );
    defer audit_logger.deinit();

    std.debug.print("Audit logger initialized. Emitting demo events...\n\n");

    // Demo 1: Authentication events
    try demonstrateAuthEvents(audit_logger);

    // Demo 2: Database events
    try demonstrateDatabaseEvents(audit_logger);

    // Demo 3: Sensitive data handling
    try demonstrateSensitiveDataHandling(audit_logger, allocator);

    std.debug.print("Demo completed successfully!\n");
    if (audit_config.sinks.file.enabled) {
        std.debug.print("File logs written to: {s}\n", .{audit_config.sinks.file.path});
    }
    if (audit_config.sinks.syslog.enabled) {
        std.debug.print("Syslog messages sent to: {s}:{d}\n", .{ audit_config.sinks.syslog.host, audit_config.sinks.syslog.port });
    }
}

fn demonstrateAuthEvents(audit_logger: *logger.AuditLogger) !void {
    std.debug.print("=== Authentication Events Demo ===\n");

    // Successful login
    var login_event = events.AuditEvent{
        .category = "auth",
        .action = "login",
        .outcome = .success,
        .ts_unix_ms = 0,
        .severity = .INFO,
        .actor_id = "jane.doe",
        .subject_id = null,
        .request_id = "req-login-001",
        .session_id = "ses-abc123",
        .source_ip = "203.0.113.5",
        .trace_id = null,
        .span_id = null,
        .metadata = null,
    };

    try audit_logger.audit(&login_event);
    std.debug.print("✓ Login success event emitted\n");

    // Failed login
    var failed_login = events.AuditEvent{
        .category = "auth",
        .action = "login",
        .outcome = .failure,
        .ts_unix_ms = 0,
        .severity = .WARN,
        .actor_id = "unknown",
        .subject_id = null,
        .request_id = "req-login-002",
        .session_id = null,
        .source_ip = "198.51.100.42",
        .trace_id = null,
        .span_id = null,
        .metadata = null,
    };

    try audit_logger.audit(&failed_login);
    std.debug.print("✓ Login failure event emitted\n");

    // Logout
    var logout_event = events.AuditEvent{
        .category = "auth",
        .action = "logout",
        .outcome = .success,
        .ts_unix_ms = 0,
        .severity = .INFO,
        .actor_id = "jane.doe",
        .subject_id = null,
        .request_id = "req-logout-001",
        .session_id = "ses-abc123",
        .source_ip = "203.0.113.5",
        .trace_id = null,
        .span_id = null,
        .metadata = null,
    };

    try audit_logger.audit(&logout_event);
    std.debug.print("✓ Logout event emitted\n");

    // Password change
    var password_change = events.AuditEvent{
        .category = "auth",
        .action = "password.change",
        .outcome = .success,
        .ts_unix_ms = 0,
        .severity = .INFO,
        .actor_id = "jane.doe",
        .subject_id = "jane.doe",
        .request_id = "req-passwd-001",
        .session_id = "ses-abc123",
        .source_ip = "203.0.113.5",
        .trace_id = null,
        .span_id = null,
        .metadata = null,
    };

    try audit_logger.audit(&password_change);
    std.debug.print("✓ Password change event emitted\n\n");
}

fn demonstrateDatabaseEvents(audit_logger: *logger.AuditLogger) !void {
    std.debug.print("=== Database Events Demo ===\n");

    // DB Update operation
    try db_adapter.emitDbEvent(
        audit_logger,
        .UPDATE,
        "users",
        1,
        42, // duration_ms
        "admin",
        "usr-123",
        "req-db-001",
        null,
        null,
        "192.168.1.100",
    );
    std.debug.print("✓ DB UPDATE event emitted\n");

    // DB Select operation
    try db_adapter.emitDbEvent(
        audit_logger,
        .SELECT,
        "products",
        25,
        15, // duration_ms
        "api-user",
        null,
        "req-db-002",
        null,
        null,
        "10.0.0.50",
    );
    std.debug.print("✓ DB SELECT event emitted\n");

    // DB Insert operation
    try db_adapter.emitDbEvent(
        audit_logger,
        .INSERT,
        "orders",
        1,
        8, // duration_ms
        "web-app",
        "customer-456",
        "req-db-003",
        null,
        null,
        "172.16.0.10",
    );
    std.debug.print("✓ DB INSERT event emitted\n");

    // DB Access denied
    try db_adapter.emitDbAccessDenied(
        audit_logger,
        .DELETE,
        "sensitive_data",
        "Insufficient privileges",
        "guest-user",
        "req-db-004",
        null,
        null,
        "203.0.113.100",
    );
    std.debug.print("✓ DB access denied event emitted\n\n");
}

fn demonstrateSensitiveDataHandling(audit_logger: *logger.AuditLogger, allocator: std.mem.Allocator) !void {
    std.debug.print("=== Sensitive Data Handling Demo ===\n");

    // Create metadata with sensitive information
    var metadata_obj = std.json.ObjectMap.init(allocator);
    defer metadata_obj.deinit();

    // Add some sensitive data that should be redacted
    try metadata_obj.put("password", std.json.Value{ .string = "SuperSecret123!" });
    try metadata_obj.put("card", std.json.Value{ .string = "4111 1111 1111 1111" });
    try metadata_obj.put("jwt", std.json.Value{ .string = "example.jwt.token.for-redaction-demo" });
    try metadata_obj.put("user_action", std.json.Value{ .string = "profile_update" });
    try metadata_obj.put("ip_address", std.json.Value{ .string = "192.168.1.1" });

    const metadata = std.json.Value{ .object = metadata_obj };

    var sensitive_event = events.AuditEvent{
        .category = "auth",
        .action = "password.change",
        .outcome = .success,
        .ts_unix_ms = 0,
        .severity = .INFO,
        .actor_id = "jane.doe",
        .subject_id = "jane.doe",
        .request_id = "req-sensitive-001",
        .session_id = "ses-def456",
        .source_ip = "203.0.113.10",
        .trace_id = null,
        .span_id = null,
        .metadata = metadata,
    };

    try audit_logger.audit(&sensitive_event);
    std.debug.print("✓ Event with sensitive data emitted (data should be redacted)\n");

    // Create an event with unknown fields (should be filtered out by default deny)
    var unknown_metadata = std.json.ObjectMap.init(allocator);
    defer unknown_metadata.deinit();

    try unknown_metadata.put("nickname", std.json.Value{ .string = "Jay" });
    try unknown_metadata.put("favorite_color", std.json.Value{ .string = "blue" });
    try unknown_metadata.put("actor_id", std.json.Value{ .string = "jane.doe" }); // This should be allowed

    const unknown_fields_metadata = std.json.Value{ .object = unknown_metadata };

    var filtered_event = events.AuditEvent{
        .category = "auth",
        .action = "profile.view",
        .outcome = .success,
        .ts_unix_ms = 0,
        .severity = .DEBUG,
        .actor_id = "jane.doe",
        .subject_id = "jane.doe",
        .request_id = "req-filter-001",
        .session_id = "ses-ghi789",
        .source_ip = "203.0.113.15",
        .trace_id = null,
        .span_id = null,
        .metadata = unknown_fields_metadata,
    };

    try audit_logger.audit(&filtered_event);
    std.debug.print("✓ Event with unknown fields emitted (unknown fields should be filtered)\n\n");
}
