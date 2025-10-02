const std = @import("std");
const Parser = @import("src/gql/parser.zig").Parser;
const Lexer = @import("src/gql/lexer.zig").Lexer;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    const test_cases = [_][]const u8{
        "MATCH (n:Test) DELETE n",
        "MATCH (n:Test) WHERE n.id = 1 DELETE n",
        "MATCH (n:Test) DELETE n RETURN count(n)",
    };
    
    for (test_cases) |query| {
        std.debug.print("\nParsing: {s}\n", .{query});
        
        var l = Lexer{ .src = query };
        var p = Parser{ .lx = &l, .arena = &arena, .cur = l.next() };
        
        const result = p.parseProgram() catch |err| {
            std.debug.print("  ERROR: {}\n", .{err});
            if (p.last_error) |msg| {
                std.debug.print("  Message: {s}\n", .{msg});
            }
            continue;
        };
        
        std.debug.print("  SUCCESS: Parsed {d} statement(s)\n", .{result.statements.len});
        if (result.statements.len > 0) {
            const stmt = result.statements[0];
            switch (stmt) {
                .Delete => std.debug.print("  Type: Delete statement\n", .{}),
                .Query => std.debug.print("  Type: Query statement\n", .{}),
                else => std.debug.print("  Type: Other statement\n", .{}),
            }
        }
    }
}