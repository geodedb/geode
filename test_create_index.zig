const std = @import("std");
const lib = @import("lib.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const test_queries = [_][]const u8{
        "CREATE INDEX test_idx FOR (n:Test) ON (n.value)",
        "CREATE INDEX test_idx ON Test (value)",
        "CREATE INDEX test_idx FOR (n:Test) ON (n.value) USING btree",
    };

    for (test_queries) |query| {
        std.debug.print("\n=== Testing: {s}\n", .{query});

        if (lib.parse(allocator, query, .{})) |result| {
            var mut_result = result;
            defer mut_result.deinit();
            std.debug.print("SUCCESS! Parsed {d} statements\n", .{result.program.statements.len});
            if (result.program.statements.len > 0) {
                std.debug.print("Statement type: {s}\n", .{@tagName(result.program.statements[0])});
            }
        } else |err| {
            std.debug.print("ERROR: {}\n", .{err});
        }
    }
}
