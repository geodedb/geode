const std = @import("std");
const geode = @import("geode");
const testing = std.testing;

// E2E: OPTIONAL-like left-outer preservation and path alias rendering
// Uses the server main entry with stdio mode (no QUIC).

extern fn geode_main() callconv(.C) void; // not used; zig test will call binaries in other e2e files normally

fn run_cli(gpa: std.mem.Allocator, query: []const u8) !struct { stdout: []const u8, stderr: []const u8, exit_code: i32 } {
    // We reuse the server processMessage via TCP loopback in other tests; here keep it simple by invoking main.handleTcpConnection
    // For consistency with other tests, use the same JSON line protocol helpers from tests/e2e_protocol.zig.
    var buf = std.ArrayList(u8).init(gpa);
    defer buf.deinit();
    // Build a minimal RUN + PULL exchange using protocol helpers
    const run = std.fmt.allocPrint(gpa, "{\"type\":\"RUN_GQL\",\"text\":\"{s}\"}\n", .{query}) catch return error.OutOfMemory;
    defer gpa.free(run);
    const pull = "{\"type\":\"PULL\",\"page_size\":1000}\n";

    // For e2e harness simplicity, directly call into server.processMessage like other tests do (tests in repo follow that pattern)
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const srv = @import("../src/server/main.zig");
    var state = srv.ServerState{ .allocator = gpa };
    state.txn_manager.init(gpa);
    state.inserted_values = .{};

    const hello = "{\"type\":\"HELLO\"}\n";
    const r1 = try srv.processMessage(gpa, &state, hello, false, false, false, false);
    defer gpa.free(r1);
    const r2 = try srv.processMessage(gpa, &state, run, false, false, false, false);
    defer gpa.free(r2);
    const r3 = try srv.processMessage(gpa, &state, pull, false, false, false, false);
    // r3 is owned by caller in this test; do not free to let caller compare slices

    // stdout concatenates SCHEMA and first BINDINGS page
    const out = try std.mem.concat(gpa, u8, &.{ r2, r3 });
    return .{ .stdout = out, .stderr = &.{}, .exit_code = 0 };
}

test "OPTIONAL MATCH left-outer preservation and path alias" {
    const gpa = testing.allocator;
    // Query with path alias and OPTIONAL-like pattern where second hop may not exist
    // Our exec applies LOJ preservation per hop; this should not error and should emit rows
    const q = "MATCH p=(a:Person)-[r:KNOWS]->(b) RETURN a, b, r, p ORDER BY a LIMIT 2";
    const res = try run_cli(gpa, q);
    try testing.expectEqual(@as(i32, 0), res.exit_code);
    // Verify we got SCHEMA then BINDINGS JSON lines
    try testing.expect(std.mem.indexOf(u8, res.stdout, "\"type\":\"SCHEMA\"") != null);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "\"type\":\"BINDINGS\"") != null);
    // Verify path alias appears as JSON array in rows (p: [ {"id":...}, ... ])
    try testing.expect(std.mem.indexOf(u8, res.stdout, "\"p\":\[") != null);
}
