/// Audit Event Formatting Module
///
/// This module contains formatting functions for audit events, separated
/// from the core audit logic to improve testability and modularity.
///
/// Extracted as part of Phase 1, M1.1 of the modularization effort.
const std = @import("std");

// CANARY: REQ=REQ-GQL-031; FEATURE="Security Audit"; ASPECT=AuditFormatting; STATUS=TESTED; TEST=tests/test_sonny3045_audit_text_escaping.zig; OWNER=security; UPDATED=2026-09-27

/// Import the AuditEvent type from the main audit module
pub const AuditEvent = @import("audit.zig").AuditEvent;
pub const AuditEventType = @import("audit.zig").AuditEventType;

// CANARY: REQ=REQ-SONNY-3045-AUDIT-TEXT-ESCAPING; FEATURE="AuditDurability"; ASPECT=ExporterEscaping; STATUS=TESTED; TEST=tests/test_sonny3045_audit_text_escaping.zig; OWNER=security; UPDATED=2026-09-27
// SONNY-3045: every string an exporter prints can come from a client (a
// tenant, a session, a resource id, an action, a refusal's reason), so each
// is escaped for its format: a value holding markup, a line break or a
// `key=` could otherwise forge an element, a syslog line or a field. These
// exporters had also stopped compiling against the audit event (its resource
// became a record and its tenant a string); nothing called them, so it went
// unnoticed.

/// `s` as XML character data or an attribute value: `&`, `<`, `>`, `'` and
/// `"` as entities, a tab, a line feed and a carriage return as character
/// references, and every other control character (which XML 1.0 does not
/// allow even as a reference) and every byte that is not UTF-8 as U+FFFD.
fn writeXmlText(writer: anytype, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '\'' => try writer.writeAll("&apos;"),
            '"' => try writer.writeAll("&quot;"),
            '\t' => try writer.writeAll("&#x9;"),
            '\n' => try writer.writeAll("&#xA;"),
            '\r' => try writer.writeAll("&#xD;"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try writer.writeAll("\u{FFFD}"),
            0x7F => try writer.writeAll("&#x7F;"),
            0x20...0x21, 0x23...0x25, 0x28...0x3B, 0x3D, 0x3F...0x7E => try writer.writeByte(c),
            0x80...0xFF => {
                const len = std.unicode.utf8ByteSequenceLength(c) catch 0;
                const valid = len != 0 and i + len <= s.len and std.unicode.utf8ValidateSlice(s[i..][0..len]);
                if (valid) {
                    try writer.writeAll(s[i..][0..len]);
                    i += len;
                } else {
                    try writer.writeAll("\u{FFFD}");
                    i += 1;
                }
                continue;
            },
        }
        i += 1;
    }
}

/// `s` as a quoted syslog value (the RFC 5424 PARAM-VALUE escapes): `"`,
/// `\` and `]` backslash-escaped, and every control character and DEL as
/// `\xHH`, so a value never ends the line or the quotes early.
fn writeSyslogValue(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"', '\\', ']' => {
                try writer.writeByte('\\');
                try writer.writeByte(c);
            },
            0x00...0x1F, 0x7F => try writer.print("\\x{x:0>2}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

/// Format an audit event as Windows Event Log XML
///
/// Returns a Windows Event Log XML formatted string that can be written
/// to Windows Event Log compatible outputs. Every string is escaped
/// (`writeXmlText`).
///
/// Caller owns the returned memory.
pub fn formatWindowsEventLog(event: AuditEvent, allocator: std.mem.Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const writer = &aw.writer;

    try writer.writeAll("<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'>\n");
    try writer.writeAll("  <System>\n");
    try writer.writeAll("    <Provider Name='Geode Audit' />\n");
    try writer.print("    <EventID>{d}</EventID>\n", .{@intFromEnum(event.event_type)});
    try writer.print("    <TimeCreated SystemTime='{d}' />\n", .{event.timestamp});
    try writer.writeAll("    <Computer>localhost</Computer>\n");
    try writer.print("    <Security UserID='{d}' />\n", .{event.user_id});
    try writer.writeAll("  </System>\n");
    try writer.writeAll("  <EventData>\n");
    const fields = [_]struct { name: []const u8, value: ?[]const u8 }{
        .{ .name = "EventType", .value = @tagName(event.event_type) },
        .{ .name = "Result", .value = @tagName(event.result) },
        .{ .name = "Tenant", .value = event.tenant_id },
        .{ .name = "ResourceType", .value = event.resource.type },
        .{ .name = "ResourceID", .value = event.resource.id },
        .{ .name = "Graph", .value = event.resource.graph },
        .{ .name = "Action", .value = event.action },
        .{ .name = "Reason", .value = event.reason },
        .{ .name = "SessionID", .value = event.session_id },
        .{ .name = "IPAddress", .value = event.ip_address },
    };
    for (fields) |field| {
        const value = field.value orelse continue;
        try writer.print("    <Data Name='{s}'>", .{field.name});
        try writeXmlText(writer, value);
        try writer.writeAll("</Data>\n");
    }
    try writer.writeAll("  </EventData>\n");
    try writer.writeAll("</Event>\n");

    return aw.toOwnedSlice();
}

/// Format an audit event as RFC3164/RFC5424 syslog message
///
/// Returns a syslog formatted string following RFC3164 format with
/// priority calculated based on event type. Every string value is quoted
/// and escaped (`writeSyslogValue`), so the message is one line and every
/// `key=` in it is the exporter's.
///
/// Caller owns the returned memory.
pub fn formatSyslog(event: AuditEvent, allocator: std.mem.Allocator) ![]u8 {
    // Priority = Facility (16 = local0) * 8 + Severity (based on event type)
    const severity: u8 = switch (event.event_type) {
        .authentication_failure => 3, // Error
        .access_denied, .policy_violation => 4, // Warning
        .access_granted => 6, // Info
        else => 5, // Notice
    };
    const priority = 16 * 8 + severity; // local0 facility

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const writer = &aw.writer;
    const datetime = @divFloor(event.timestamp, 1000);

    // Format: <priority>Jan 01 12:00:00 hostname geode[pid]: message
    try writer.print("<{d}>", .{priority});

    // Simple timestamp formatting (would need proper date formatting in production)
    try writer.writeAll("Jan 01 12:00:00 ");

    try writer.print("localhost geode[{d}]: ", .{if (@import("builtin").os.tag == .linux) std.os.linux.getpid() else 0});
    try writer.print("event_type={s} user_id={d} result={s}", .{ @tagName(event.event_type), event.user_id, @tagName(event.result) });
    const fields = [_]struct { name: []const u8, value: ?[]const u8 }{
        .{ .name = "tenant", .value = event.tenant_id },
        .{ .name = "resource_type", .value = event.resource.type },
        .{ .name = "resource_id", .value = event.resource.id },
        .{ .name = "action", .value = event.action },
        .{ .name = "reason", .value = event.reason },
        .{ .name = "session", .value = event.session_id },
        .{ .name = "ip_address", .value = event.ip_address },
    };
    for (fields) |field| {
        const value = field.value orelse continue;
        try writer.print(" {s}=", .{field.name});
        try writeSyslogValue(writer, value);
    }
    try writer.print(" timestamp={d}", .{datetime});

    return aw.toOwnedSlice();
}

/// Format an audit event as JSON (JSONL format)
///
/// Returns a single-line JSON representation of the audit event suitable
/// for JSONL (JSON Lines) format logging. Every string is JSON-escaped
/// (`AuditEvent.writeJsonString`, the canonical writer's).
///
/// Caller owns the returned memory.
pub fn formatJson(event: AuditEvent, allocator: std.mem.Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const writer = &aw.writer;
    try writer.print("{{\"timestamp\":{d},\"event_type\":\"{s}\",\"result\":\"{s}\",\"user_id\":{d}", .{
        event.timestamp,
        @tagName(event.event_type),
        @tagName(event.result),
        event.user_id,
    });
    const fields = [_]struct { name: []const u8, value: ?[]const u8 }{
        .{ .name = "tenant", .value = event.tenant_id },
        .{ .name = "resource_type", .value = event.resource.type },
        .{ .name = "resource_id", .value = event.resource.id },
        .{ .name = "action", .value = event.action },
        .{ .name = "reason", .value = event.reason },
        .{ .name = "ip_address", .value = event.ip_address },
        .{ .name = "session_id", .value = event.session_id },
    };
    for (fields) |field| {
        const value = field.value orelse continue;
        try writer.print(",\"{s}\":", .{field.name});
        try AuditEvent.writeJsonString(writer, value);
    }
    if (event.policy_id) |pid| try writer.print(",\"policy_id\":{d}", .{pid});
    if (event.query_hash) |qh| try writer.print(",\"query_hash\":{d}", .{qh});
    try writer.writeAll("}\n");

    return aw.toOwnedSlice();
}
