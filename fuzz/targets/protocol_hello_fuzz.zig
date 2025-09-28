const std = @import("std");
const geode = @import("geode");
const protocol = geode.protocol;
const Context = struct {};

fn fuzz_hello(context: Context, data: []const u8) anyerror!void {
    _ = context;
    const ally = std.testing.allocator;
    const line = data[0..@min(data.len, 4096)];
    const msg = protocol.parseClientMessage(ally, line) catch return;
    switch (msg) {
        .HELLO => |h| {
            defer ally.free(h.client_name);
            defer ally.free(h.client_ver);
            defer ally.free(h.wanted_conformance);
            var buf = std.ArrayList(u8){};
            defer buf.deinit(ally);
            try buf.writer(ally).print("{any}", .{std.json.fmt(.{ .type = "HELLO", .client_name = h.client_name, .client_ver = h.client_ver, .wanted_conformance = h.wanted_conformance }, .{})});
            const msg2 = protocol.parseClientMessage(ally, buf.items) catch return;
            switch (msg2) {
                .HELLO => |h2| {
                    defer ally.free(h2.client_name);
                    defer ally.free(h2.client_ver);
                    defer ally.free(h2.wanted_conformance);
                },
                else => return error.Unexpected,
            }
        },
        else => {},
    }
}

test "fuzz protocol hello" {
    try std.testing.fuzz(Context{}, fuzz_hello, .{});
    std.debug.print("fuzzing: completed\n", .{});
}
