const std = @import("std");
const GeodeClient = @import("geode_client_v2.zig").GeodeClient;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Creating Geode client...\n", .{});
    var client = try GeodeClient.init(allocator, "127.0.0.1", 8443, true);
    defer client.deinit();

    std.debug.print("Connecting to server...\n", .{});
    try client.connect();
    std.debug.print("✓ Connected successfully!\n", .{});

    std.debug.print("Sending HELLO...\n", .{});
    try client.sendHello("test-client-v2", "2.0.0");
    std.debug.print("✓ HELLO sent!\n", .{});

    std.debug.print("Receiving HELLO response...\n", .{});
    const hello_response = try client.receiveMessage();
    defer allocator.free(hello_response);
    std.debug.print("✓ HELLO response: {s}\n", .{hello_response});

    std.debug.print("Sending test query...\n", .{});
    try client.sendRunGql("req_1", "RETURN 1 AS x", null);
    std.debug.print("✓ Query sent!\n", .{});

    std.debug.print("Receiving SCHEMA response...\n", .{});
    const schema_response = try client.receiveMessage();
    defer allocator.free(schema_response);
    std.debug.print("✓ SCHEMA response: {s}\n", .{schema_response});

    std.debug.print("Sending PULL...\n", .{});
    try client.sendPull("req_1", 1000);
    std.debug.print("✓ PULL sent!\n", .{});

    std.debug.print("Receiving BINDINGS response...\n", .{});
    const bindings_response = try client.receiveMessage();
    defer allocator.free(bindings_response);
    std.debug.print("✓ BINDINGS response: {s}\n", .{bindings_response});

    std.debug.print("\n✅ All tests passed!\n", .{});
}
