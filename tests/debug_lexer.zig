const std = @import("std");

pub fn main() !void {
    _ = std.heap.page_allocator; // Might use later

    // Test inputs
    const tests = [_][]const u8{
        "RETURN 'test'",
        "RETURN \"test\",
        "CREATE (n {name: 'alice'})",
        "CREATE (n {name: \"alice\"})",
    };

    for (tests) |input| {
        std.debug.print("\nTesting: {s}\n", .{input});

        // We'll need to manually trace through what the lexer is doing
        var idx: usize = 0;
        while (idx < input.len) : (idx += 1) {
            const c = input[idx];
            if (c == '"') {
                std.debug.print("  Found double quote at position {}\n", .{idx});
                // Find the closing quote
                var closed = false;
                var end_idx = idx + 1;
                while (end_idx < input.len) : (end_idx += 1) {
                    if (input[end_idx] == '"') {
                        std.debug.print("  Found closing quote at position {}\n", .{end_idx});
                        closed = true;
                        break;
                    }
                }
                if (!closed) {
                    std.debug.print("  ERROR: Unclosed double quote\n", .{});
                }
                break;
            } else if (c == '\'') {
                std.debug.print("  Found single quote at position {}\n", .{idx});
                // Find the closing quote
                var closed = false;
                var end_idx = idx + 1;
                while (end_idx < input.len) : (end_idx += 1) {
                    if (input[end_idx] == '\'') {
                        std.debug.print("  Found closing quote at position {}\n", .{end_idx});
                        closed = true;
                        break;
                    }
                }
                if (!closed) {
                    std.debug.print("  ERROR: Unclosed single quote\n", .{});
                }
                break;
            }
        }
    }
}
