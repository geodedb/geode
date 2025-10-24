const std = @import("std");
const lexer = @import("src/gql/lexer.zig");
const parser = @import("src/gql/parser.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    // Test different property patterns
    const test_cases = [_][]const u8{
        "{name: 'Alice'}",
        "{name: 'Alice', age: 30}",
        "{value: 1}",
        "{a: 1, b: 2}",
    };
    
    for (test_cases) |props_str| {
        const query = std.fmt.allocPrint(arena.allocator(), "CREATE (n:Test {s})", .{props_str}) catch unreachable;
        std.debug.print("\nTesting: {s}\n", .{query});
        
        var l = lexer.Lexer{ .src = query };
        
        // Skip CREATE and (n:Test
        _ = l.next(); // CREATE
        _ = l.next(); // (
        _ = l.next(); // n
        _ = l.next(); // :
        _ = l.next(); // Test
        
        // Now we should be at the {
        std.debug.print("Tokens starting from brace:\n", .{});
        while (true) {
            const tok = l.next();
            std.debug.print("  {any}: '{s}'\n", .{tok.kind, tok.lexeme});
            if (tok.kind == .eof or tok.kind == .r_paren) break;
        }
    }
}