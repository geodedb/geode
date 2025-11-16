const std = @import("std");
const GeodeClient = @import("geode_client.zig").GeodeClient;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Creating Geode client...\n", .{});
    var client = GeodeClient.init(allocator, "127.0.0.1", 8443, true);
    defer client.deinit();

    std.debug.print("Attempting to connect...\n", .{});
    client.connect() catch |err| {
        std.debug.print("Connection failed: {}\n", .{err});
        return err;
    };

    std.debug.print("✓ Connected successfully!\n", .{});

    std.debug.print("Opening stream...\n", .{});
    client.openStream() catch |err| {
        std.debug.print("Stream open failed: {}\n", .{err});
        return err;
    };

    std.debug.print("✓ Stream opened successfully!\n", .{});

    std.debug.print("Sending HELLO...\n", .{});
    client.sendHello("test-client", "1.0.0") catch |err| {
        std.debug.print("Send HELLO failed: {}\n", .{err});
        return err;
    };

    std.debug.print("✓ HELLO sent!\n", .{});

    std.debug.print("Receiving response...\n", .{});
    const response = client.receiveMessage() catch |err| {
        std.debug.print("Receive failed: {}\n", .{err});
        return err;
    };
    defer allocator.free(response);

    std.debug.print("✓ Received response: {s}\n", .{response});
}
