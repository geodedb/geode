const std = @import("std");
const geode = @import("geode");
const Parser = @import("gql/parser.zig").Parser;
const Lexer = @import("gql/lexer.zig").Lexer;

fn parseWithTs(src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next(), .ts_extensions = true };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
}

test "ts udfs: parser flag allows last_value/value_at/sample_by" {
    try parseWithTs("RETURN last_value(s.temp)");
    try parseWithTs("RETURN value_at(s.temp, 1000)");
    try parseWithTs("RETURN sample_by(s.temp, 60)");
}
