/// Audit Event Formatting Module
///
/// This module contains formatting functions for audit events, separated
/// from the core audit logic to improve testability and modularity.
///
/// Extracted as part of Phase 1, M1.1 of the modularization effort.
const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}

// CANARY: REQ=REQ-GQL-031; FEATURE="Security Audit"; ASPECT=AuditFormatting; STATUS=TESTED; TEST=audit_tests; OWNER=security; UPDATED=2025-11-12

/// Import the AuditEvent type from the main audit module
pub const AuditEvent = @import("audit.zig").AuditEvent;
pub const AuditEventType = @import("audit.zig").AuditEventType;

/// Format an audit event as Windows Event Log XML
///
/// Returns a Windows Event Log XML formatted string that can be written
/// to Windows Event Log compatible outputs.
///
/// Caller owns the returned memory.
pub fn formatWindowsEventLog(event: AuditEvent, allocator: std.mem.Allocator) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 4096);
    errdefer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    try writer.print("<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'>\n", .{});
    try writer.print("  <System>\n", .{});
    try writer.print("    <Provider Name='Geode Audit' />\n", .{});
    try writer.print("    <EventID>{d}</EventID>\n", .{@intFromEnum(event.event_type)});
    try writer.print("    <TimeCreated SystemTime='{d}' />\n", .{event.timestamp});
    try writer.print("    <Computer>localhost</Computer>\n", .{});
    try writer.print("    <Security UserID='{d}' />\n", .{event.user_id orelse 0});
    try writer.print("  </System>\n", .{});
    try writer.print("  <EventData>\n", .{});
    try writer.print("    <Data Name='EventType'>{s}</Data>\n", .{@tagName(event.event_type)});
    try writer.print("    <Data Name='Resource'>{s}</Data>\n", .{event.resource});
    try writer.print("    <Data Name='Action'>{s}</Data>\n", .{event.action});
    if (event.reason) |reason| {
        try writer.print("    <Data Name='Reason'>{s}</Data>\n", .{reason});
    }
    if (event.session_id) |session| {
        try writer.print("    <Data Name='SessionID'>{s}</Data>\n", .{session});
    }
    try writer.print("  </EventData>\n", .{});
    try writer.print("</Event>\n", .{});

    return try buf.toOwnedSlice(allocator);
}

/// Format an audit event as RFC3164/RFC5424 syslog message
///
/// Returns a syslog formatted string following RFC3164 format with
/// priority calculated based on event type.
///
/// Caller owns the returned memory.
pub fn formatSyslog(event: AuditEvent, allocator: std.mem.Allocator) ![]u8 {
    // Priority = Facility (16 = local0) * 8 + Severity (based on event type)
    const severity: u8 = switch (event.event_type) {
        .authentication_failure, .authorization_failure => 3, // Error
        .access_denied, .policy_violation => 4, // Warning
        .access_granted => 6, // Info
        else => 5, // Notice
    };
    const priority = 16 * 8 + severity; // local0 facility

    var buf = try std.ArrayList(u8).initCapacity(allocator, 2048);
    errdefer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    // RFC3164 format: <priority>timestamp hostname tag[pid]: message
    const timestamp = compat_milliTimestamp();
    const datetime = @divFloor(timestamp, 1000);

    // Format: <priority>Jan 01 12:00:00 hostname geode[pid]: message
    try writer.print("<{d}>", .{priority});

    // Simple timestamp formatting (would need proper date formatting in production)
    try writer.print("Jan 01 12:00:00 ", .{});

    try writer.print("localhost geode[{d}]: ", .{if (@import("builtin").os.tag == .linux) std.os.linux.getpid() else 0});
    try writer.print("event_type={s} ", .{@tagName(event.event_type)});
    try writer.print("user_id={d} ", .{event.user_id orelse 0});
    try writer.print("resource={s} ", .{event.resource});
    try writer.print("action={s} ", .{event.action});
    if (event.reason) |reason| {
        try writer.print("reason={s} ", .{reason});
    }
    try writer.print("timestamp={d}", .{datetime});

    return try buf.toOwnedSlice(allocator);
}

/// Format an audit event as JSON (JSONL format)
///
/// Returns a single-line JSON representation of the audit event suitable
/// for JSONL (JSON Lines) format logging.
///
/// Caller owns the returned memory.
pub fn formatJson(event: AuditEvent, allocator: std.mem.Allocator) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 256);
    errdefer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    try writer.print("{{\"timestamp\":{d},\"event_type\":\"{s}\",\"resource\":\"{s}\",\"action\":\"{s}\"", .{
        event.timestamp,
        @tagName(event.event_type),
        event.resource,
        event.action,
    });

    if (event.user_id) |uid| {
        try writer.print(",\"user_id\":{d}", .{uid});
    }
    if (event.tenant_id) |tid| {
        try writer.print(",\"tenant_id\":{d}", .{tid});
    }
    if (event.policy_id) |pid| {
        try writer.print(",\"policy_id\":{d}", .{pid});
    }
    if (event.reason) |reason| {
        try writer.print(",\"reason\":\"{s}\"", .{reason});
    }
    if (event.ip_address) |ip| {
        try writer.print(",\"ip_address\":\"{s}\"", .{ip});
    }
    if (event.session_id) |sid| {
        try writer.print(",\"session_id\":\"{s}\"", .{sid});
    }
    if (event.query_hash) |qh| {
        try writer.print(",\"query_hash\":{d}", .{qh});
    }

    try writer.writeAll("}\n");

    return try buf.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

test "formatWindowsEventLog - basic event" {
    const testing = std.testing;

    const event = AuditEvent{
        .timestamp = 1699999999000,
        .event_type = .access_granted,
        .user_id = 1001,
        .tenant_id = null,
        .resource = "database.users",
        .action = "SELECT",
        .policy_id = null,
        .reason = null,
        .ip_address = null,
        .session_id = "test-session",
        .query_hash = null,
        .additional_context = null,
    };

    const formatted = try formatWindowsEventLog(event, testing.allocator);
    defer testing.allocator.free(formatted);

    try testing.expect(std.mem.indexOf(u8, formatted, "<Event xmlns=") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "EventType'>access_granted</Data>") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "Resource'>database.users</Data>") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "SessionID'>test-session</Data>") != null);
}

test "formatSyslog - access denied event" {
    const testing = std.testing;

    const event = AuditEvent{
        .timestamp = compat_milliTimestamp(),
        .event_type = .access_denied,
        .user_id = 2001,
        .tenant_id = null,
        .resource = "database.passwords",
        .action = "SELECT",
        .policy_id = 42,
        .reason = "Insufficient privileges",
        .ip_address = "192.168.1.100",
        .session_id = null,
        .query_hash = null,
        .additional_context = null,
    };

    const formatted = try formatSyslog(event, testing.allocator);
    defer testing.allocator.free(formatted);

    try testing.expect(std.mem.indexOf(u8, formatted, "<132>") != null); // Priority 132 for warning
    try testing.expect(std.mem.indexOf(u8, formatted, "event_type=access_denied") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "resource=database.passwords") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "reason=Insufficient privileges") != null);
}

test "formatJson - comprehensive event" {
    const testing = std.testing;

    const event = AuditEvent{
        .timestamp = 1700000000000,
        .event_type = .authentication_failure,
        .user_id = null,
        .tenant_id = 5,
        .resource = "system",
        .action = "LOGIN",
        .policy_id = null,
        .reason = "Invalid credentials",
        .ip_address = "10.0.0.1",
        .session_id = null,
        .query_hash = 987654321,
        .additional_context = null,
    };

    const formatted = try formatJson(event, testing.allocator);
    defer testing.allocator.free(formatted);

    try testing.expect(std.mem.indexOf(u8, formatted, "\"timestamp\":1700000000000") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "\"event_type\":\"authentication_failure\"") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "\"tenant_id\":5") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "\"reason\":\"Invalid credentials\"") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "\"ip_address\":\"10.0.0.1\"") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "\"query_hash\":987654321") != null);
}
