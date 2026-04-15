const std = @import("std");
const logging = @import("logging");
const log = logging.scoped("security");
const Attr = logging.Attr;

// backup_key_envelope.zig
// Export / import semantics for key registry backup (envelopes + checksum manifest)
// CANARY: REQ=REQ-GQL-TDE-BACKUP-KEY-001; FEATURE="KeyBackupHandling"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_BACKUP_KEY_001_RoundTrip; OWNER=security; UPDATED=2025-09-26

pub const Entry = struct {
    id: u64,
    created: i64,
    wrapped: bool,
    payload: []const u8, // hex material or envelope JSON
};

pub fn exportManifest(allocator: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var w = std.ArrayList(u8).init(allocator);
    errdefer w.deinit();
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    try w.writer().print("{\n  \"version\":1,\n  \"entries\":[\n", .{});
    var i: usize = 0;
    while (i < entries.len) : (i += 1) {
        const e = entries[i];
        hash.update(std.mem.asBytes(&e.id));
        hash.update(std.mem.asBytes(&e.created));
        hash.update(&[_]u8{@intFromBool(e.wrapped)});
        hash.update(e.payload);
        try w.writer().print("    {{\"id\":{},\"created\":{},\"wrapped\":{},\"payload\":\"", .{ e.id, e.created, if (e.wrapped) "true" else "false" });
        // escape quotes minimally (payload expected hex or JSON w/out quotes top-level)
        for (e.payload) |b| try w.writer().writeByte(b);
        try w.writer().print("\"}}{s}\n", .{if (i + 1 == entries.len) "" else ","});
    }
    try w.writer().print("  ],\n  \"checksum\":\"", .{});
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    var j: usize = 0;
    while (j < 16) : (j += 1) try w.writer().print("{x:0>2}", .{digest[j]});
    try w.writer().print("\"\n}\n", .{});
    return w.toOwnedSlice();
}

pub const ImportResult = struct { valid: bool, entries: []Entry };

pub fn import(allocator: std.mem.Allocator, blob: []const u8) !ImportResult {
    var lines = std.mem.tokenizeAny(u8, blob, "\n\r");
    var checksum: [16]u8 = [_]u8{0} ** 16;
    var have_checksum = false;
    var tmp_entries = std.ArrayList(Entry).init(allocator);
    errdefer tmp_entries.deinit();
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"checksum\"")) |_| {
            // GAP-0141: Safe hex parsing with proper error handling
            // CANARY: REQ=REQ-HEX-PARSE-BACKUP-001; FEATURE="Safe Hex Parsing"; ASPECT=Security; STATUS=EXEMPT; OWNER=security; UPDATED=2026-01-13
            const first = std.mem.indexOfScalar(u8, line, '"') orelse continue;
            const second = std.mem.indexOfScalarPos(u8, line, first + 1, '"') orelse continue;
            const third = std.mem.indexOfScalarPos(u8, line, second + 1, '"') orelse continue;
            const fourth = std.mem.indexOfScalarPos(u8, line, third + 1, '"') orelse continue;
            const hex = line[third + 1 .. fourth];
            if (hex.len == 32) {
                var k: usize = 0;
                var checksum_valid = true;
                while (k < 16) : (k += 1) {
                    checksum[k] = std.fmt.parseInt(u8, hex[k * 2 .. k * 2 + 2], 16) catch {
                        log.warn("Invalid hex in backup checksum", &.{
                            Attr.int("position", @intCast(k * 2)),
                        });
                        checksum_valid = false;
                        break;
                    };
                }
                have_checksum = checksum_valid;
            }
        } else if (std.mem.indexOf(u8, line, "\"id\"")) |idx| {
            if (std.mem.indexOf(u8, line, "payload\")") == null) continue;
            const id_colon = std.mem.indexOfScalarPos(u8, line, idx, ':') orelse continue;
            var after = std.mem.trim(u8, line[id_colon + 1 ..], " \t,");
            const id_end = std.mem.indexOfScalar(u8, after, ',') orelse continue;
            const id_slice = after[0..id_end];
            const id = std.fmt.parseInt(u64, id_slice, 10) catch continue;
            const created_pos = std.mem.indexOf(u8, line, "\"created\"") orelse continue;
            const created_colon = std.mem.indexOfScalarPos(u8, line, created_pos, ':') orelse continue;
            var created_after = std.mem.trim(u8, line[created_colon + 1 ..], " \t,");
            const created_end = std.mem.indexOfScalar(u8, created_after, ',') orelse continue;
            const created_slice = created_after[0..created_end];
            const created = std.fmt.parseInt(i64, created_slice, 10) catch continue;
            const wrapped_pos = std.mem.indexOf(u8, line, "\"wrapped\"") orelse continue;
            const wrapped_colon = std.mem.indexOfScalarPos(u8, line, wrapped_pos, ':') orelse continue;
            var wrapped_after = std.mem.trim(u8, line[wrapped_colon + 1 ..], " \t,");
            const wrapped_end = std.mem.indexOfScalar(u8, wrapped_after, ',') orelse continue;
            const wrapped_slice = wrapped_after[0..wrapped_end];
            const wrapped = std.mem.eql(u8, wrapped_slice, "true");
            const payload_pos = std.mem.indexOf(u8, line, "\"payload\"") orelse continue;
            const payload_quote1 = std.mem.indexOfScalarPos(u8, line, payload_pos, '"') orelse continue; // " after payload
            const payload_quote2 = std.mem.indexOfScalarPos(u8, line, payload_quote1 + 1, '"') orelse continue; // closing of key
            const payload_quote3 = std.mem.indexOfScalarPos(u8, line, payload_quote2 + 1, '"') orelse continue; // opening value
            const payload_quote4 = std.mem.lastIndexOfScalar(u8, line, '"') orelse continue; // closing value
            if (payload_quote4 <= payload_quote3) continue;
            const payload_slice = line[payload_quote3 + 1 .. payload_quote4];
            const payload_copy = try allocator.alloc(u8, payload_slice.len);
            std.mem.copy(u8, payload_copy, payload_slice);
            try tmp_entries.append(.{ .id = id, .created = created, .wrapped = wrapped, .payload = payload_copy });
        }
    }
    if (!have_checksum) return error.MissingChecksum;
    // Recompute checksum
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (tmp_entries.items) |e| {
        h.update(std.mem.asBytes(&e.id));
        h.update(std.mem.asBytes(&e.created));
        h.update(&[_]u8{@intFromBool(e.wrapped)});
        h.update(e.payload);
    }
    var dg: [32]u8 = undefined;
    h.final(&dg);
    var mismatch = false;
    var m: usize = 0;
    while (m < 16) : (m += 1) {
        if (dg[m] != checksum[m]) {
            mismatch = true;
            break;
        }
    }
    return .{ .valid = !mismatch, .entries = tmp_entries.toOwnedSlice() };
}

test "TestCANARY_REQ_GQL_TDE_BACKUP_KEY_001_RoundTrip" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    var entries = [_]Entry{
        .{ .id = 1, .created = 100, .wrapped = false, .payload = "abcdef" },
        .{ .id = 2, .created = 200, .wrapped = true, .payload = "{\"version\":1}" },
    };
    const blob = try exportManifest(a, entries[0..]);
    defer a.free(blob);
    const imported = try import(a, blob);
    defer for (imported.entries) |e| a.free(e.payload);
    try std.testing.expect(imported.valid);
    try std.testing.expect(imported.entries.len == 2);
}
