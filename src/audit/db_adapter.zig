const std = @import("std");
const events = @import("events.zig");
const logger = @import("logger.zig");

pub const DbOperation = enum {
    SELECT,
    INSERT,
    UPDATE,
    DELETE,
    DDL,

    pub fn toString(self: DbOperation) []const u8 {
        return switch (self) {
            .SELECT => "SELECT",
            .INSERT => "INSERT",
            .UPDATE => "UPDATE",
            .DELETE => "DELETE",
            .DDL => "DDL",
        };
    }
};

pub fn emitDbEvent(
    audit_logger: *logger.AuditLogger,
    operation: DbOperation,
    table: []const u8,
    row_count: u64,
    duration_ms: u64,
    actor_id: []const u8,
    subject_id: ?[]const u8,
    request_id: ?[]const u8,
    trace_id: ?[32]u8,
    span_id: ?[16]u8,
    source_ip: ?[]const u8,
) !void {
    // Build metadata object with DB-specific fields
    var metadata_obj = std.json.ObjectMap.init(audit_logger.allocator);
    errdefer metadata_obj.deinit();

    try metadata_obj.put("db.operation", std.json.Value{ .string = try audit_logger.allocator.dupe(u8, operation.toString()) });
    try metadata_obj.put("db.table", std.json.Value{ .string = try audit_logger.allocator.dupe(u8, table) });
    try metadata_obj.put("db.rowCount", std.json.Value{ .integer = @intCast(row_count) });
    try metadata_obj.put("duration_ms", std.json.Value{ .integer = @intCast(duration_ms) });

    const metadata = std.json.Value{ .object = metadata_obj };

    // Determine severity based on operation
    const severity = switch (operation) {
        .SELECT => events.Severity.DEBUG,
        .INSERT, .UPDATE => events.Severity.INFO,
        .DELETE, .DDL => events.Severity.WARN,
    };

    // Determine outcome (assume success unless specified otherwise)
    const outcome = events.Outcome.success;

    // Create audit event
    var event = events.AuditEvent{
        .category = "db",
        .action = operation.toString(),
        .outcome = outcome,
        .ts_unix_ms = 0, // Will be filled by logger
        .severity = severity,
        .actor_id = actor_id,
        .subject_id = subject_id,
        .request_id = request_id,
        .session_id = null, // Not typically available at DB level
        .source_ip = source_ip,
        .trace_id = trace_id,
        .span_id = span_id,
        .metadata = metadata,
    };

    // Emit the event
    try audit_logger.audit(&event);
}

pub fn emitDbError(
    audit_logger: *logger.AuditLogger,
    operation: DbOperation,
    table: []const u8,
    error_msg: []const u8,
    actor_id: []const u8,
    request_id: ?[]const u8,
    trace_id: ?[32]u8,
    span_id: ?[16]u8,
    source_ip: ?[]const u8,
) !void {
    // Build metadata object for error
    var metadata_obj = std.json.ObjectMap.init(audit_logger.allocator);
    errdefer metadata_obj.deinit();

    try metadata_obj.put("db.operation", std.json.Value{ .string = try audit_logger.allocator.dupe(u8, operation.toString()) });
    try metadata_obj.put("db.table", std.json.Value{ .string = try audit_logger.allocator.dupe(u8, table) });
    try metadata_obj.put("error", std.json.Value{ .string = try audit_logger.allocator.dupe(u8, error_msg) });

    const metadata = std.json.Value{ .object = metadata_obj };

    // Create audit event for error
    var event = events.AuditEvent{
        .category = "db",
        .action = operation.toString(),
        .outcome = events.Outcome.@"error",
        .ts_unix_ms = 0,
        .severity = events.Severity.ERROR,
        .actor_id = actor_id,
        .subject_id = null,
        .request_id = request_id,
        .session_id = null,
        .source_ip = source_ip,
        .trace_id = trace_id,
        .span_id = span_id,
        .metadata = metadata,
    };

    try audit_logger.audit(&event);
}

pub fn emitDbAccessDenied(
    audit_logger: *logger.AuditLogger,
    operation: DbOperation,
    table: []const u8,
    reason: []const u8,
    actor_id: []const u8,
    request_id: ?[]const u8,
    trace_id: ?[32]u8,
    span_id: ?[16]u8,
    source_ip: ?[]const u8,
) !void {
    // Build metadata object for access denial
    var metadata_obj = std.json.ObjectMap.init(audit_logger.allocator);
    errdefer metadata_obj.deinit();

    try metadata_obj.put("db.operation", std.json.Value{ .string = try audit_logger.allocator.dupe(u8, operation.toString()) });
    try metadata_obj.put("db.table", std.json.Value{ .string = try audit_logger.allocator.dupe(u8, table) });
    try metadata_obj.put("reason", std.json.Value{ .string = try audit_logger.allocator.dupe(u8, reason) });

    const metadata = std.json.Value{ .object = metadata_obj };

    // Create audit event for access denial
    var event = events.AuditEvent{
        .category = "db",
        .action = operation.toString(),
        .outcome = events.Outcome.deny,
        .ts_unix_ms = 0,
        .severity = events.Severity.WARN,
        .actor_id = actor_id,
        .subject_id = null,
        .request_id = request_id,
        .session_id = null,
        .source_ip = source_ip,
        .trace_id = trace_id,
        .span_id = span_id,
        .metadata = metadata,
    };

    try audit_logger.audit(&event);
}

/// Helper to create a simplified DB event with minimal parameters
pub fn emitSimpleDbEvent(
    audit_logger: *logger.AuditLogger,
    operation: DbOperation,
    table: []const u8,
    actor_id: []const u8,
) !void {
    try emitDbEvent(
        audit_logger,
        operation,
        table,
        1, // Default row count
        0, // No duration tracking
        actor_id,
        null, // No subject_id
        null, // No request_id
        null, // No trace_id
        null, // No span_id
        null, // No source_ip
    );
}

/// Database adapter that provides a more ergonomic interface
pub const DbAuditor = struct {
    logger: *logger.AuditLogger,
    default_actor: []const u8,

    pub fn init(audit_logger: *logger.AuditLogger, default_actor: []const u8) DbAuditor {
        return DbAuditor{
            .logger = audit_logger,
            .default_actor = default_actor,
        };
    }

    pub fn select(self: *const DbAuditor, table: []const u8, row_count: u64) !void {
        try emitDbEvent(
            self.logger,
            .SELECT,
            table,
            row_count,
            0,
            self.default_actor,
            null,
            null,
            null,
            null,
            null,
        );
    }

    pub fn insert(self: *const DbAuditor, table: []const u8, row_count: u64) !void {
        try emitDbEvent(
            self.logger,
            .INSERT,
            table,
            row_count,
            0,
            self.default_actor,
            null,
            null,
            null,
            null,
            null,
        );
    }

    pub fn update(self: *const DbAuditor, table: []const u8, row_count: u64) !void {
        try emitDbEvent(
            self.logger,
            .UPDATE,
            table,
            row_count,
            0,
            self.default_actor,
            null,
            null,
            null,
            null,
            null,
        );
    }

    pub fn delete(self: *const DbAuditor, table: []const u8, row_count: u64) !void {
        try emitDbEvent(
            self.logger,
            .DELETE,
            table,
            row_count,
            0,
            self.default_actor,
            null,
            null,
            null,
            null,
            null,
        );
    }

    pub fn ddl(self: *const DbAuditor, table: []const u8) !void {
        try emitDbEvent(
            self.logger,
            .DDL,
            table,
            0, // No row count for DDL
            0,
            self.default_actor,
            null,
            null,
            null,
            null,
            null,
        );
    }
};

test "DB adapter basic functionality" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config_mod = @import("config.zig");
    const time_mod = @import("time.zig");

    var test_config = try config_mod.loadTestConfig(allocator);
    defer test_config.deinit();

    var fixed_clock = time_mod.FixedClock.init(time_mod.TEST_TIMESTAMP_MS);
    var fixed_id_gen = time_mod.FixedIdGen.init(time_mod.TEST_TRACE_ID, time_mod.TEST_SPAN_ID, time_mod.TEST_REQUEST_ID);

    const audit_logger = try logger.AuditLogger.init(allocator, test_config, fixed_clock.clock(), fixed_id_gen.idGen());
    defer audit_logger.deinit();

    // Test basic DB operation
    try emitDbEvent(
        audit_logger,
        .UPDATE,
        "users",
        1,
        42,
        "admin",
        "usr-123",
        "req-abc123",
        null,
        null,
        "192.168.1.100",
    );

    // Test DB auditor wrapper
    const db_auditor = DbAuditor.init(audit_logger, "system");
    try db_auditor.select("products", 10);
    try db_auditor.update("inventory", 5);
}
