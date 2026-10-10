// SONNY-3045 regression (the Task W review's minor items): audit text that a
// client controls is printed unambiguously.
//
//   * joinAuditText (a MERGE refusal's labels and keys, SONNY-2819) joined the
//     items with ',' and hex-encoded only control characters, so a key holding
//     a comma, or a backslash followed by `x0a`, read as two keys or as a
//     newline: `keys=[a,b]` was one key or two. A backslash and a comma are
//     now hex-encoded too (`\x5c`, `\x2c`), so the text decodes to exactly the
//     items it was given.
//   * The Windows Event Log (XML), syslog and JSON exporters
//     (audit_formatter) printed every string as it was: a reason holding
//     `</Data>`, a newline or `" action=` wrote markup, a second syslog line or
//     a forged key. They also no longer compiled against the audit event (its
//     resource is a record and its tenant a string), which went unnoticed
//     because nothing called them. XML text is now escaped (`&`, `<`, `>`,
//     quotes, control characters as character references or U+FFFD), syslog
//     values are quoted with `"`, `\` and `]` escaped and control characters
//     hex-encoded, and JSON strings are JSON-escaped.
//
// CANARY: REQ=REQ-SONNY-3045-AUDIT-TEXT-ESCAPING; FEATURE="AuditDurability"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3045_audit_text_escaping.zig; OWNER=security; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const AuditEvent = geode.security.audit.AuditEvent;

/// The exporters, where the build exports them (the file still builds, and
/// the tests fail, where it does not).
const has_formatter = @hasDecl(geode.security, "audit_formatter");
const formatter = if (has_formatter) geode.security.audit_formatter else struct {};
const has_join = @hasDecl(geode.execution, "joinAuditText");

/// Undo joinAuditText: split on ',' and decode each `\xHH`.
fn decodeAuditText(allocator: std.mem.Allocator, text: []const u8) ![][]u8 {
    var items: std.ArrayList([]u8) = .empty;
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |part| {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var i: usize = 0;
        while (i < part.len) {
            if (part[i] == '\\') {
                if (i + 4 > part.len or part[i + 1] != 'x') return error.BadEscape;
                try out.append(allocator, try std.fmt.parseInt(u8, part[i + 2 .. i + 4], 16));
                i += 4;
            } else {
                try out.append(allocator, part[i]);
                i += 1;
            }
        }
        try items.append(allocator, try out.toOwnedSlice(allocator));
    }
    return items.toOwnedSlice(allocator);
}

test "SONNY-3045: joinAuditText encodes a comma and a backslash, so its text decodes to exactly its items" {
    const allocator = testing.allocator;
    const Case = []const []const u8;
    const cases = [_]Case{
        &.{ "a,b", "c" },
        &.{"a\\x0ab"},
        &.{ "k\"}}\n{\"x\":1}", "\\", "," },
        &.{ "plain", "two words", "caf\u{e9}" },
    };
    if (comptime !has_join) return error.JoinAuditTextNotExported;
    for (cases) |items| {
        const text = try geode.execution.joinAuditText(allocator, items);
        defer allocator.free(text);
        for (text) |c| if (c < 0x20 or c == 0x7f) return error.RawControlByte;
        const decoded = try decodeAuditText(allocator, text);
        defer {
            for (decoded) |d| allocator.free(d);
            allocator.free(decoded);
        }
        try testing.expectEqual(items.len, decoded.len);
        for (items, decoded) |want, got| try testing.expectEqualStrings(want, got);
    }
}

fn hostileEvent() AuditEvent {
    return .{
        .timestamp = 1790436718780,
        .event_type = .access_denied,
        .severity = .warning,
        .tenant_id = "t</Data>\n<Data Name='x'>",
        .user_id = 7,
        .session_id = "s\" action=forged",
        .resource = .{ .type = "graph&<>", .id = "g\n1", .name = "g", .graph = "g", .table = null },
        .action = "MERGE\nlocalhost geode[1]: event_type=authentication user_id=0",
        .result = .failure,
        .reason = "why</Data></EventData><Data Name='Forged'>1] \"\\",
        .ip_address = "10.0.0.1'",
        .details = null,
    };
}

test "SONNY-3045: the Windows Event Log exporter escapes every string" {
    if (comptime !has_formatter) return error.FormatterNotExported;
    const allocator = testing.allocator;
    const xml = try formatter.formatWindowsEventLog(hostileEvent(), allocator);
    defer allocator.free(xml);
    // No markup from the event, and no raw control character but the
    // exporter's own line breaks.
    try testing.expect(std.mem.indexOf(u8, xml, "<Data Name='Forged'>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<Data Name='x'>") == null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, xml, "</EventData>"));
    for (xml) |c| if ((c < 0x20 and c != '\n') or c == 0x7f) return error.RawControlByte;
    var lines = std.mem.splitScalar(u8, xml, '\n');
    var data_lines: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "<Data ") != null) {
            data_lines += 1;
            // Each Data element is on one line, opened and closed once.
            try testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "</Data>"));
        }
    }
    try testing.expect(data_lines >= 6);
    // The escaped text is there.
    try testing.expect(std.mem.indexOf(u8, xml, "why&lt;/Data&gt;&lt;/EventData&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "graph&amp;&lt;&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "g&#xA;1") != null);
}

/// The `key=value` pairs after a syslog line's `geode[pid]: ` tag. A value is
/// a bare token or a quoted string with `\"`, `\\`, `\]` and `\xHH` escapes.
/// A key seen twice is an error: a value forged it.
fn parseSyslogPairs(allocator: std.mem.Allocator, line: []const u8) !std.StringHashMap([]u8) {
    var pairs = std.StringHashMap([]u8).init(allocator);
    errdefer {
        var it = pairs.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        pairs.deinit();
    }
    const tag_end = std.mem.indexOf(u8, line, "]: ") orelse return error.NoTag;
    var i = tag_end + 3;
    while (i < line.len) {
        const eq = std.mem.indexOfScalarPos(u8, line, i, '=') orelse return error.NoValue;
        const key = line[i..eq];
        i = eq + 1;
        var value: std.ArrayList(u8) = .empty;
        errdefer value.deinit(allocator);
        if (i < line.len and line[i] == '"') {
            i += 1;
            while (true) {
                if (i >= line.len) return error.Unterminated;
                const c = line[i];
                if (c == '"') {
                    i += 1;
                    break;
                }
                if (c == '\\') {
                    if (i + 1 >= line.len) return error.BadEscape;
                    switch (line[i + 1]) {
                        '"', '\\', ']' => |e| {
                            try value.append(allocator, e);
                            i += 2;
                        },
                        'x' => {
                            if (i + 4 > line.len) return error.BadEscape;
                            try value.append(allocator, try std.fmt.parseInt(u8, line[i + 2 .. i + 4], 16));
                            i += 4;
                        },
                        else => return error.BadEscape,
                    }
                    continue;
                }
                try value.append(allocator, c);
                i += 1;
            }
        } else {
            const end = std.mem.indexOfScalarPos(u8, line, i, ' ') orelse line.len;
            try value.appendSlice(allocator, line[i..end]);
            i = end;
        }
        if (i < line.len) {
            if (line[i] != ' ') return error.NoSeparator;
            i += 1;
        }
        const owned = try value.toOwnedSlice(allocator);
        if (pairs.contains(key)) {
            allocator.free(owned);
            return error.DuplicateKey;
        }
        try pairs.put(key, owned);
    }
    return pairs;
}

test "SONNY-3045: the syslog exporter writes one line, every value quoted and escaped" {
    if (comptime !has_formatter) return error.FormatterNotExported;
    const allocator = testing.allocator;
    const line = try formatter.formatSyslog(hostileEvent(), allocator);
    defer allocator.free(line);
    for (line) |c| if (c < 0x20 or c == 0x7f) return error.RawControlByte;
    // Every key once (none forged from a value), and every value decodes to
    // the event's own text.
    var pairs = try parseSyslogPairs(allocator, line);
    defer {
        var it = pairs.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        pairs.deinit();
    }
    const ev = hostileEvent();
    try testing.expectEqualStrings(ev.action, pairs.get("action").?);
    try testing.expectEqualStrings(ev.reason.?, pairs.get("reason").?);
    try testing.expectEqualStrings(ev.session_id.?, pairs.get("session").?);
    try testing.expectEqualStrings(ev.tenant_id.?, pairs.get("tenant").?);
    try testing.expectEqualStrings(ev.resource.type, pairs.get("resource_type").?);
    try testing.expectEqualStrings(ev.resource.id, pairs.get("resource_id").?);
    try testing.expectEqualStrings("7", pairs.get("user_id").?);
    try testing.expectEqualStrings("access_denied", pairs.get("event_type").?);
}

test "SONNY-3045: the JSON exporter writes one object on one line" {
    if (comptime !has_formatter) return error.FormatterNotExported;
    const allocator = testing.allocator;
    const out = try formatter.formatJson(hostileEvent(), allocator);
    defer allocator.free(out);
    const line = std.mem.trimEnd(u8, out, "\n");
    for (line) |c| if (c < 0x20 or c == 0x7f) return error.RawControlByte;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("MERGE\nlocalhost geode[1]: event_type=authentication user_id=0", obj.get("action").?.string);
    try testing.expectEqualStrings("why</Data></EventData><Data Name='Forged'>1] \"\\", obj.get("reason").?.string);
    try testing.expectEqualStrings("t</Data>\n<Data Name='x'>", obj.get("tenant").?.string);
    try testing.expectEqualStrings("g\n1", obj.get("resource_id").?.string);
}
