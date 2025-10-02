const std = @import("std");
const Lexer = @import("../src/gql/lexer.zig").Lexer;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    _ = allocator;

    // Test single quotes (working)
    {
        const src = "CREATE (n {name: 'test'})";
        var lexer = Lexer{ .src = src };
        var token_count: usize = 0;

        std.debug.print("Testing single quotes: {s}\n", .{src});
        while (true) {
            const tok = lexer.next();
            token_count += 1;
            if (tok.kind == .eof) break;
            if (token_count > 100) {
                std.debug.print("ERROR: Too many tokens (possible infinite loop)\n", .{});
                break;
            }
        }
        std.debug.print("Single quotes: {} tokens\n", .{token_count});
    }

    // Test double quotes (hanging)
    {
        const src = "CREATE (n {name: \"test\"})";
        var lexer = Lexer{ .src = src };
        var token_count: usize = 0;

        std.debug.print("\nTesting double quotes: {s}\n", .{src});
        const start = std.time.milliTimestamp();

        while (true) {
            const tok = lexer.next();
            token_count += 1;
            std.debug.print("Token {}: kind={}, lexeme='{}'\n", .{ token_count, tok.kind, tok.lexeme });

            if (tok.kind == .eof) break;
            if (token_count > 100) {
                std.debug.print("ERROR: Too many tokens (infinite loop detected)\n", .{});
                break;
            }

            const elapsed = std.time.milliTimestamp() - start;
            if (elapsed > 1000) {
                std.debug.print("ERROR: Timeout after {}ms\n", .{elapsed});
                break;
            }
        }
        std.debug.print("Double quotes: {} tokens\n", .{token_count});
    }
}
