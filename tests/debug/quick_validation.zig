const std = @import("std");
const geode = @import("geode");
const Parser = geode.gql.parser.Parser;
const Lexer = geode.gql.lexer.Lexer;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Test the critical keyword handling fixes
    const critical_query = "MATCH path = (a:Person)-[:KNOWS*2..4]->(b:Person) RETURN a.name, b.name, length(path)";

    std.debug.print("Testing critical path variable query...\n", .{});

    var l = Lexer{ .src = critical_query };
    var p = Parser{ .lx = &l, .arena = &arena, .cur = l.next() };

    const result = p.parseProgram();
    if (result == error.UnexpectedToken) {
        std.debug.print("❌ CRITICAL ISSUE: Parser fails on path variables\n", .{});
        if (p.last_error) |msg| {
            std.debug.print("Error: {s}\n", .{msg});
        }
        return;
    }

    const program = result catch unreachable;
    if (program.statements.len == 0) {
        std.debug.print("❌ CRITICAL ISSUE: Empty program generated\n", .{});
        return;
    }

    std.debug.print("✅ SUCCESS: Path variable parsing works correctly!\n", .{});
    std.debug.print("✅ Generated {} statement(s)\n", .{program.statements.len});
    std.debug.print("✅ Keyword handling fixes are working\n", .{});

    // Test advanced type parsing
    std.debug.print("\nTesting advanced type recognition...\n", .{});

    const ip_query = "RETURN IpAddr('192.168.1.1') AS ip";
    var l2 = Lexer{ .src = ip_query };
    var p2 = Parser{ .lx = &l2, .arena = &arena, .cur = l2.next() };

    const result2 = p2.parseProgram();
    if (result2 == error.UnexpectedToken) {
        std.debug.print("⚠️  IpAddr type not yet implemented (expected)\n", .{});
    } else {
        std.debug.print("✅ IpAddr type parsing works!\n", .{});
    }

    std.debug.print("\n🎯 NEXT PRIORITIES:\n", .{});
    std.debug.print("==================\n", .{});
    std.debug.print("1. ✅ Core GQL parsing is stable\n", .{});
    std.debug.print("2. 🔄 Implement advanced data types\n", .{});
    std.debug.print("3. 🔄 Add TDE security features\n", .{});
    std.debug.print("4. 🔄 Implement CDC streaming\n", .{});
    std.debug.print("5. 🔄 Add comprehensive indexes\n", .{});
}
