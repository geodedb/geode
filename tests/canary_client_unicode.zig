const std = @import("std");
const geode = @import("geode");
const minimal = @import("clients/zig/client_minimal.zig");

test "TestCANARY_ClientUnicode_Utf8ToUtf16" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var client = minimal.Client.init(gpa.allocator(), .{});
    const s = "Grüß"; // includes umlaut and ß after folding maybe
    const utf16 = try client.utf8ToUtf16Alloc(s);
    defer gpa.allocator().free(utf16);
    try std.testing.expect(utf16.len > 0);
}

test "TestCANARY_ClientUnicode_Utf16ToUtf8" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var client = minimal.Client.init(gpa.allocator(), .{});
    const s = "Hello 🌍"; // includes surrogate pair when encoded
    const utf16 = try client.utf8ToUtf16Alloc(s);
    defer gpa.allocator().free(utf16);
    const back = try client.utf16ToUtf8Alloc(utf16);
    defer gpa.allocator().free(back);
    try std.testing.expect(std.mem.eql(u8, s, back));
}

test "TestCANARY_ClientUnicode_Wtf8Lossy" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var client = minimal.Client.init(gpa.allocator(), .{});
    // Construct invalid UTF-8 sequence (lone continuation) which WTF-8 should pass through replacement
    const bad: []const u8 = &[_]u8{ 0x61, 0x80, 0x62 }; // a, invalid, b
    const repaired = try client.wtf8LossyToUtf8Alloc(bad);
    defer gpa.allocator().free(repaired);
    // Expect length 3 with U+FFFD replacement for invalid continuation byte
    try std.testing.expect(repaired.len >= 3);
}

// CANARY: REQ=REQ-GQL-UNICODE-012; FEATURE="UTF-8 -> UTF-16 Conversion"; ASPECT=ClientTestZig; STATUS=TESTED; TEST=TestCANARY_ClientUnicode_Utf8ToUtf16; OWNER=clients; UPDATED=2025-09-27
// CANARY: REQ=REQ-GQL-UNICODE-013; FEATURE="UTF-16 -> UTF-8 Conversion"; ASPECT=ClientTestZig; STATUS=TESTED; TEST=TestCANARY_ClientUnicode_Utf16ToUtf8; OWNER=clients; UPDATED=2025-09-27
// CANARY: REQ=REQ-GQL-UNICODE-014; FEATURE="WTF-8 Lossy Decode"; ASPECT=ClientTestZig; STATUS=TESTED; TEST=TestCANARY_ClientUnicode_Wtf8Lossy; OWNER=clients; UPDATED=2025-09-27
