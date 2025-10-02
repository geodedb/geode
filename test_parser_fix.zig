const std = @import("std");
const Parser = @import("src/gql/parser.zig").Parser;
const Lexer = @import("src/gql/lexer.zig").Lexer;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    const test_cases = [_][]const u8{
        "CREATE (n:Test {value: 1})",
        "CREATE (n:Test {name: 'Alice', age: 30})",
        "CREATE (n1:Number {value: 1}), (n2:Number {value: 2})",
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
    }
}