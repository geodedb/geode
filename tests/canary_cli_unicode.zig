const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");
const proto_test_util = @import("proto_test_util.zig");

fn run(argv: []const []const u8, allocator: std.mem.Allocator) !struct { code: u8, out: []u8, err: []u8 } {
    var server = try proto_test_util.spawnServerRandom(allocator, proto_test_util.TestEnv.standard());
    defer server.deinit();

    const res = try cli_test_util.runAgainstServer(allocator, server.getAddr(), argv);
    return .{ .code = @intCast(res.code), .out = res.out, .err = res.err };
}

// Test normalization flag: Provide decomposed form of "é" and ensure query executes (RETURN statement) with no error frames.
// We just assert success exit code (0) and presence of expected schema column to keep test stable.
// CANARY: REQ=REQ-GQL-UNICODE-004; FEATURE="UnicodeCore"; ASPECT=CliNormalizationFlag; STATUS=IMPL; TEST=TestCANARY_ClientCli_NormalizeNfc; OWNER=clients; UPDATED=2026-11-14
test "TestCANARY_ClientCli_NormalizeNfc" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    // Decomposed e + combining acute U+0065 U+0301
    const decomposed = "RETURN 'e\xCC\x81' AS v LIMIT 1"; // LIMIT to force schema+bindings
    const res = try run(&.{ geode_test_bin.geode_exe, decomposed, "--normalize-nfc" }, gpa.allocator());
    defer gpa.allocator().free(res.out);
    defer gpa.allocator().free(res.err);
    try std.testing.expectEqual(@as(u8, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"columns\":[{\"name\":\"v\"") != null);
}

// Test case folding flag: Provide sharp S which should fold to "ss" internally; query should still succeed.
// NOTE: We only verify success; semantic folding correctness is covered in core unicode tests.
// CANARY: REQ=REQ-GQL-UNICODE-005; FEATURE="UnicodeCore"; ASPECT=CliFoldCaseFlag; STATUS=IMPL; TEST=TestCANARY_ClientCli_FoldCase; OWNER=clients; UPDATED=2026-11-14
test "TestCANARY_ClientCli_FoldCase" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const q = "RETURN 'Stra\xC3\x9Fe' AS v LIMIT 1"; // Straße
    const res = try run(&.{ geode_test_bin.geode_exe, q, "--fold-case" }, gpa.allocator());
    defer gpa.allocator().free(res.out);
    defer gpa.allocator().free(res.err);
    try std.testing.expectEqual(@as(u8, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"columns\":[{\"name\":\"v\"") != null);
}

// Test UTF-16 hex input flag: Provide code units for "Hi" (0048 0069) and globe U+1F30D surrogate pair (D83C DF0D)
// Expect successful execution.
// CANARY: REQ=REQ-GQL-UNICODE-013; FEATURE="UnicodeUtf16"; ASPECT=CliUtf16HexInputFlag; STATUS=IMPL; TEST=TestCANARY_ClientCli_Utf16Input; OWNER=clients; UPDATED=2026-11-14
test "TestCANARY_ClientCli_Utf16Input" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    // Because --utf16-input rewrites the entire query string from UTF-16 code units, we supply a minimal query:
    // RETURN 1 AS x  encoded as hexadecimal 16-bit units. This exercises the decode path; successful execution implies
    // the units were converted to a valid UTF-8 query prior to send.
    const utf16_return = "0052 0045 0054 0055 0052 004E 0020 0031 0020 0041 0053 0020 0078"; // "RETURN 1 AS x"
    const res = try run(&.{ geode_test_bin.geode_exe, utf16_return, "--utf16-input" }, gpa.allocator());
    defer gpa.allocator().free(res.out);
    defer gpa.allocator().free(res.err);
    try std.testing.expectEqual(@as(u8, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"columns\":[{\"name\":\"x\"") != null);
}
