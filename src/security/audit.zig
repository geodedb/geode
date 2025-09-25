const std = @import("std");
const rls = @import("rls.zig");

// CANARY: REQ=REQ-GQL-031; FEATURE="Security Audit"; ASPECT=AuditLogging; STATUS=TESTED; TEST=e2e_rls_integration; OWNER=security; UPDATED=2025-09-25

pub const AuditEventType = enum {
    access_granted,
    access_denied,
    policy_violation,
    authentication_failure,
    authorization_failure,
    data_export,
    schema_change,
    privilege_change,
};

pub const AuditEvent = struct {
    timestamp: i64,
    event_type: AuditEventType,
    user_id: ?u64,
    tenant_id: ?u64,
    resource: []const u8,
    action: []const u8,
    policy_id: ?u64,
    reason: ?[]const u8,
    ip_address: ?[]const u8,
    session_id: ?[]const u8,
    query_hash: ?u64,
    additional_context: ?std.json.Value,
    
    // PII redaction fields
    redacted_fields: []const []const u8 = &.{},
};

pub const AuditLogger = struct {
    allocator: std.mem.Allocator,
    file: ?std.fs.File,
    mutex: std.Thread.Mutex,
    config: Config,
    
    pub const Config = struct {
        enabled: bool = true,
        file_path: []const u8 = "audit.jsonl",
        redact_pii: bool = true,
        log_denies_only: bool = false,
        rotation_size_mb: u32 = 100,
        retention_days: u32 = 90,
    };
    
    pub fn init(allocator: std.mem.Allocator, config: Config) !AuditLogger {
        var logger = AuditLogger{
            .allocator = allocator,
            .file = null,
            .mutex = .{},
            .config = config,
        };
        
        if (config.enabled) {
            logger.file = try std.fs.cwd().createFile(config.file_path, .{ 
                .truncate = false,
                .exclusive = false,
            });
            try logger.file.?.seekFromEnd(0);
        }
        
        return logger;
    }
    
    pub fn deinit(self: *AuditLogger) void {
        if (self.file) |f| {
            f.close();
        }
    }
    
    pub fn logEvent(self: *AuditLogger, event: AuditEvent) !void {
        if (!self.config.enabled) return;
        
        if (self.config.log_denies_only) {
            switch (event.event_type) {
                .access_denied, .policy_violation, .authentication_failure, .authorization_failure => {},
                else => return,
            }
        }
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        
        // Build JSON object
        var obj = std.json.ObjectMap.init(alloc);
        
        try obj.put("timestamp", .{ .integer = event.timestamp });
        try obj.put("event_type", .{ .string = @tagName(event.event_type) });
        
        if (event.user_id) |uid| {
            if (self.config.redact_pii) {
                // Hash user ID for privacy
                const hashed = std.hash.Wyhash.hash(0, std.mem.asBytes(&uid));
                try obj.put("user_hash", .{ .integer = @intCast(hashed) });
            } else {
                try obj.put("user_id", .{ .integer = @intCast(uid) });
            }
        }
        
        if (event.tenant_id) |tid| {
            try obj.put("tenant_id", .{ .integer = @intCast(tid) });
        }
        
        try obj.put("resource", .{ .string = event.resource });
        try obj.put("action", .{ .string = event.action });
        
        if (event.policy_id) |pid| {
            try obj.put("policy_id", .{ .integer = @intCast(pid) });
        }
        
        if (event.reason) |r| {
            try obj.put("reason", .{ .string = r });
        }
        
        if (event.ip_address) |ip| {
            if (self.config.redact_pii) {
                // Redact last octet
                var ip_copy = try alloc.dupe(u8, ip);
                if (std.mem.lastIndexOf(u8, ip_copy, ".")) |idx| {
                    _ = try std.fmt.bufPrint(ip_copy[idx..], ".xxx", .{});
                }
                try obj.put("ip_address", .{ .string = ip_copy });
            } else {
                try obj.put("ip_address", .{ .string = ip });
            }
        }
        
        if (event.session_id) |sid| {
            try obj.put("session_id", .{ .string = sid });
        }
        
        if (event.query_hash) |qh| {
            try obj.put("query_hash", .{ .integer = @intCast(qh) });
        }
        
        // Write JSON line
        const json_value = std.json.Value{ .object = obj };
        var string = std.ArrayList(u8).init(alloc);
        try std.json.stringify(json_value, .{}, string.writer());
        try string.append('\n');
        
        if (self.file) |f| {
            try f.writeAll(string.items);
        }
        
        // Also print to stdout for testing
        std.debug.print("AUDIT_LOGGED type={s} policy_id={?}\n", .{
            @tagName(event.event_type),
            event.policy_id,
        });
    }
    
    pub fn logRlsDeny(self: *AuditLogger, ctx: *const rls.SecurityContext, resource: []const u8, reason: []const u8) !void {
        try self.logEvent(.{
            .timestamp = std.time.milliTimestamp(),
            .event_type = .access_denied,
            .user_id = ctx.user_id,
            .tenant_id = ctx.tenant_id,
            .resource = resource,
            .action = "read",
            .policy_id = null,
            .reason = reason,
            .ip_address = null,
            .session_id = ctx.session_id,
            .query_hash = null,
            .additional_context = null,
        });
    }
    
    pub fn logAbacDeny(self: *AuditLogger, ctx: *const rls.SecurityContext, rule: []const u8, resource: []const u8) !void {
        try self.logEvent(.{
            .timestamp = std.time.milliTimestamp(),
            .event_type = .policy_violation,
            .user_id = ctx.user_id,
            .tenant_id = ctx.tenant_id,
            .resource = resource,
            .action = "access",
            .policy_id = null,
            .reason = rule,
            .ip_address = null,
            .session_id = ctx.session_id,
            .query_hash = null,
            .additional_context = null,
        });
    }
};