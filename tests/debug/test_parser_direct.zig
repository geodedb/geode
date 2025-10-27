const std = @import("std");
const Parser = @import("src/gql/parser.zig").Parser;
const Lexer = @import("src/gql/lexer.zig").Lexer;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Test parsing a simple string literal
    const source = "RETURN \"hello\" AS greeting";
    std.debug.print("Testing parser with: {s}\n", .{source});

    var lexer = Lexer{ .src = source };
    var parser = Parser{ .lx = &lexer, .arena = &arena, .cur = lexer.next() };

    std.debug.print("Starting parse...\n", .{});

    const result = parser.parseProgram() catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        return;
    };

    std.debug.print("Parse completed successfully!\n", .{});
    std.debug.print("Number of statements: {}\n", .{result.statements.len});
}
