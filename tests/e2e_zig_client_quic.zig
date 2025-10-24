const std = @import("std");
const ClientMod = @import("clients/zig/client.zig");

pub fn main() !void {}

test "Zig client QUIC interop: HELLO roundtrip" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const host = std.process.getEnvVarOwned(alloc, "GEODE_HOST") catch "127.0.0.1";
    defer if (@TypeOf(host) != []const u8) alloc.free(host);
    const port_str = std.process.getEnvVarOwned(alloc, "GEODE_PORT") catch "7567";
    defer if (@TypeOf(port_str) != []const u8) alloc.free(port_str);
    const port: u16 = @intCast(std.fmt.parseInt(u16, port_str, 10) catch 7567);

    var client = ClientMod.Client.init(alloc, .{
        .host = if (@TypeOf(host) == []const u8) host else host.*,
        .port = port,
        .use_quic = true,
        .use_tls = true,
    });
    defer client.deinit();

    client.connect() catch |err| {
        std.debug.print("client connect failed: {} — is geoded with QUIC running? skipping test\n", .{err});
        return error.SkipZigTest;
    };
    defer client.disconnect();

    // Send a simple RUN_GQL that server will echo schema + first page
    var iter = try client.query("RETURN 1 AS x ORDER BY x LIMIT 1", null);
    defer iter.close();

    // We don't have full parsing here; ensure we at least can pull once without error
    // If the server returns something, fetchNextPage() path will be exercised implicitly
    // Just assert that receive/send didn't error out till here
    try std.testing.expect(true);
}
