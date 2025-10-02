const std = @import("std");
const parser = @import("src/gql/parser.zig");
const lexer = @import("src/gql/lexer.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    
    // Test CREATE with properties
    const query = "CREATE (n:Person {name: 'Alice', age: 30})";
    
    var l = lexer.Lexer.init(ally, query);
    defer l.deinit();
    
    var p = parser.Parser.init(ally);
    defer p.deinit();
    
    const result = p.parse(&l) catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        if (p.error_message) |msg| {
            std.debug.print("Error message: {s}\n", .{msg});
        }
        return;
    };
    
    std.debug.print("Parse successful!\n", .{});
    _ = result;
}

test "parse CREATE with properties" {
    const ally = std.testing.allocator;
    
    const test_cases = [_][]const u8{
        "CREATE (n:Person {name: 'Alice'})",
        "CREATE (n:Person {name: 'Alice', age: 30})",
        "CREATE (n {id: 1})",
    };
    
    for (test_cases) |query| {
        var l = lexer.Lexer.init(ally, query);
        defer l.deinit();
        
        var p = parser.Parser.init(ally);
        defer p.deinit();
        
        _ = p.parse(&l) catch |err| {
            std.debug.print("Failed to parse: {s}\n", .{query});
            std.debug.print("Error: {}\n", .{err});
            if (p.error_message) |msg| {
                std.debug.print("Message: {s}\n", .{msg});
            }
            return err;
        };
    }
}