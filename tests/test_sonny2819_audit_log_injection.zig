// SONNY-2819 regression: audit log injection.
//
// The audit log is JSON Lines: one canonical JSON object per line
// (AuditEvent.writeCanonicalJson, rls_core.zig). The writer printed every
// string with `{s}` and no escaping. SONNY-2728 audits a MERGE refused for a
// hidden match with the pattern's property KEYS in its details, and a key can
// be a string literal holding a double quote and a newline. The merged-tree
// security review's probe TM-5 (P47), as a restricted user: the refusal record
// split in two, and its second line was a well-formed record of the
// attacker's choosing (`{"event_type":"authentication_success",...}`), which
// a line-based consumer ingests as genuine. The writer also printed the
// timestamp's signed fields with a '+': `2026-09-26T+15:+31:+58.+780Z`.
//
// Every string the writer prints is now JSON-escaped (quotes, backslashes,
// every control character, and a byte that is not UTF-8), the refusal's keys
// and labels hex-encode their control characters before they reach the
// details, and the timestamp is `YYYY-MM-DDTHH:MM:SS.mmmZ`. The tests check
// that forged records come out escaped and that every audit line parses as
// exactly one JSON object.
//
// CANARY: REQ=REQ-SONNY-2819-AUDIT-JSON-ESCAPE; FEATURE="AuditDurability"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2819_audit_log_injection.zig; OWNER=security; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("rls_session_harness.zig");

const audit = geode.security.audit;
const AuditEvent = audit.AuditEvent;

/// A record an attacker would like a line-based consumer to ingest.
const forged = "{\"stream\":\"geode\",\"seq_no\":1,\"event_type\":\"authentication_success\",\"actor\":\"user:0\"}";

/// One line: exactly one JSON object, nothing before or after it.
fn parseLine(allocator: std.mem.Allocator, line: []const u8) !std.json.Parsed(std.json.Value) {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.NotAnObject;
    return parsed;
}

fn field(obj: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const v = obj.get(name) orelse return error.MissingField;
    if (v != .string) return error.NotAString;
    return v.string;
}

test "SONNY-2819: every string the canonical writer prints is JSON-escaped, and the line is one object" {
    const allocator = testing.allocator;
    var details = std.StringHashMap([]const u8).init(allocator);
    defer details.deinit();
    // A detail value closes its string and object and starts a forged line;
    // a key does the same; the rest carry each class of character to escape.
    const value_forgery = "x\"}}\n" ++ forged;
    const key_forgery = "k\"\n" ++ forged;
    try details.put("details", value_forgery);
    try details.put(key_forgery, "v");
    try details.put("controls", "a\x00b\x01c\x1fd\x7fe\tf\rg\\h/i");
    try details.put("unicode", "caf\u{e9} \u{2028} \u{1F600}");
    try details.put("invalid", "a\xffb\xc3");

    var ev = AuditEvent{
        .timestamp = 1790436718780, // 2026-09-26T15:31:58.780Z
        .event_type = .access_denied,
        .severity = .warning,
        .tenant_id = "tenant\"\n{",
        .user_id = 7,
        .session_id = "sess\x01ion",
        .resource = .{ .type = "gr\"aph", .id = "g\\1\n", .name = "g", .graph = "g", .table = null },
        .action = "MERGE_MATCH_NOT_VISIBLE\n" ++ forged,
        .result = .failure,
        .reason = "why\"\n",
        .ip_address = "10.0.0.1\"",
        .details = details,
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try AuditEvent.writeCanonicalJson(&aw.writer, "geo\"de\n", &ev);
    const line = aw.written();

    // One line: no raw line break, and no raw control character at all.
    for (line) |c| {
        if (c < 0x20 or c == 0x7f) {
            std.debug.print("a raw control byte 0x{x:0>2} in: {s}\n", .{ c, line });
            return error.RawControlByte;
        }
    }
    const parsed = try parseLine(allocator, line);
    defer parsed.deinit();
    const obj = parsed.value.object;

    // Every string round-trips (an invalid UTF-8 byte becomes U+FFFD).
    try testing.expectEqualStrings("geo\"de\n", try field(obj, "stream"));
    try testing.expectEqualStrings("2026-09-26T15:31:58.780Z", try field(obj, "timestamp"));
    try testing.expectEqualStrings("tenant\"\n{", try field(obj, "tenant"));
    try testing.expectEqualStrings("sess\x01ion", try field(obj, "session"));
    try testing.expectEqualStrings("MERGE_MATCH_NOT_VISIBLE\n" ++ forged, try field(obj, "action"));
    try testing.expectEqualStrings("why\"\n", try field(obj, "reason"));
    try testing.expectEqualStrings("10.0.0.1\"", try field(obj, "ip_address"));
    try testing.expectEqualStrings("access_denied", try field(obj, "event_type"));
    const resource = obj.get("resource").?.object;
    try testing.expectEqualStrings("gr\"aph", try field(resource, "type"));
    try testing.expectEqualStrings("g\\1\n", try field(resource, "id"));
    const got = obj.get("details").?.object;
    try testing.expectEqual(@as(usize, 5), got.count());
    try testing.expectEqualStrings(value_forgery, try field(got, "details"));
    try testing.expectEqualStrings("v", try field(got, key_forgery));
    try testing.expectEqualStrings("a\x00b\x01c\x1fd\x7fe\tf\rg\\h/i", try field(got, "controls"));
    try testing.expectEqualStrings("caf\u{e9} \u{2028} \u{1F600}", try field(got, "unicode"));
    try testing.expectEqualStrings("a\u{fffd}b\u{fffd}", try field(got, "invalid"));
}

test "SONNY-2819: the timestamp has no sign, at the epoch, before a day's end and past it" {
    const allocator = testing.allocator;
    const Case = struct { ms: i64, want: []const u8 };
    const cases = [_]Case{
        .{ .ms = 0, .want = "1970-01-01T00:00:00.000Z" },
        .{ .ms = 1790436718780, .want = "2026-09-26T15:31:58.780Z" },
        .{ .ms = 1790467199999, .want = "2026-09-26T23:59:59.999Z" },
        .{ .ms = 1790467200001, .want = "2026-09-27T00:00:00.001Z" },
    };
    for (cases) |c| {
        var ev = AuditEvent{
            .timestamp = c.ms,
            .event_type = .system_event,
            .severity = .info,
            .user_id = 0,
            .resource = .{ .type = "graph", .id = "g", .name = "g", .graph = null, .table = null },
            .action = "A",
            .result = .success,
            .details = null,
        };
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try AuditEvent.writeCanonicalJson(&aw.writer, "geode", &ev);
        const parsed = try parseLine(allocator, aw.written());
        defer parsed.deinit();
        try testing.expectEqualStrings(c.want, try field(parsed.value.object, "timestamp"));
    }
}

test "SONNY-2819: a MERGE refusal whose property key forges a record writes one escaped audit record" {
    var s = try h.Session.init(.label_policy);
    defer s.deinit();
    const aa = s.arena.allocator();

    // A key that closes the details string and object, breaks the line and
    // starts the forged record.
    const key = "k\"}}\n" ++ forged;
    try s.execAs(null, "CREATE (:Hidden {'" ++ key ++ "': 'v'})");
    try s.restrict("Hidden");

    const sink_path = try std.fmt.allocPrint(aa, "{s}/audit.jsonl", .{s.data_dir});
    const logger = try audit.AuditLogger.createHeap(testing.allocator, .{ .enabled = true, .file_path = sink_path });
    defer {
        audit.setGlobalAuditLogger(null);
        logger.deinit();
        testing.allocator.destroy(logger);
    }
    audit.setGlobalAuditLogger(logger);

    var f: h.Failures = .{};
    try h.expectError(&s, &f, "MERGE (x:Hidden {'" ++ key ++ "': 'v'}) RETURN x", error.MergeMatchNotVisible);
    try f.finish("the refusal");

    const io = std.Io.Threaded.global_single_threaded.io();
    const sink = try std.Io.Dir.cwd().readFileAlloc(io, sink_path, aa, .limited(1 << 20));
    var refusals: usize = 0;
    var lines = std.mem.splitScalar(u8, sink, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = parseLine(aa, line) catch |err| {
            std.debug.print("an audit line is not one JSON object ({s}): {s}\n", .{ @errorName(err), line });
            return err;
        };
        const obj = parsed.value.object;
        const event_type = try field(obj, "event_type");
        if (std.mem.eql(u8, event_type, "authentication_success")) {
            std.debug.print("a forged record reached the log: {s}\n", .{line});
            return error.ForgedRecord;
        }
        if (!std.mem.eql(u8, try field(obj, "action"), "MERGE_MATCH_NOT_VISIBLE")) continue;
        refusals += 1;
        // The key, its control character hex-encoded, inside the details
        // (and, SONNY-3045, its commas: the keys are joined with commas).
        const details = try field(obj.get("details").?.object, "details");
        const forged_in_details = "{\"stream\":\"geode\"\\x2c\"seq_no\":1\\x2c\"event_type\":\"authentication_success\"\\x2c\"actor\":\"user:0\"}";
        const want = "keys=[k\"}}\\x0a" ++ forged_in_details ++ "]";
        if (std.mem.indexOf(u8, details, want) == null) {
            std.debug.print("the refusal's details lack {s}: {s}\n", .{ want, details });
            return error.KeyNotRecorded;
        }
    }
    try testing.expectEqual(@as(usize, 1), refusals);
}
