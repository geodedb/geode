const std = @import("std");
const gql = @import("src/lib.zig");
const eval = @import("src/eval.zig");
const execution = @import("src/execution.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    const queries = [_][]const u8{
        "RETURN abs(10) AS test",
        "RETURN round(10.5) AS test",
        "RETURN abs(round(10.5)) AS test",
        "RETURN sqrt(16) AS test",
        "RETURN abs(sqrt(16)) AS test",
    };

    for (queries) |query| {
        std.debug.print("\n=== Testing: {s} ===\n", .{query});

        // Parse
        const parse_result = gql.parse(ally, query, .{}) catch |err| {
            std.debug.print("Parse error: {}\n", .{err});
            continue;
        };
        defer {
            var mut_pr = parse_result;
            mut_pr.deinit();
        }

        std.debug.print("Parse OK\n", .{});

        // Execute
        const exec_result = execution.executeProgramWithContext(ally, &parse_result.program, .{}) catch |err| {
            std.debug.print("Execution error: {}\n", .{err});
            continue;
        };
        defer {
            var mut_result = exec_result;
            mut_result.deinit(ally);
        }

        // Print result
        const json = try exec_result.toJson(ally);
        defer ally.free(json);
        std.debug.print("Result: {s}\n", .{json});
    }
}
