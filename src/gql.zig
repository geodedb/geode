const std = @import("std");
const Lexer = @import("gql/lexer.zig").Lexer;
const Parser = @import("gql/parser.zig").Parser;
const ast = @import("gql/ast.zig");

test "parse simple MATCH ... RETURN" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (a)-[r]->(b) RETURN a";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
}

test "parse WHERE and ORDER BY" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (n)-[r]->(m) WHERE name RETURN n ORDER BY name, id LIMIT 10 OFFSET 5";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
}

test "labels, properties, member access, aliasing, and DISTINCT" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (a:Person:Admin {age: 30, name: \"x\"})-[r:KNOWS {since: 2020}]->(b) RETURN DISTINCT a.name AS name";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
}

test "OPTIONAL MATCH with WITH and IS NOT NULL predicate" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "OPTIONAL MATCH (n)-[r]->(m) WITH n WHERE n.name IS NOT NULL RETURN n";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
}

test "arithmetic and IN list predicate" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (n)-[r]->(m) WHERE n.age + 1 > 21 AND n.age IN [20,21,22] RETURN n";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
}

test "ORDER BY with ASC and DESC per key" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (n)-[r]->(m) RETURN n ORDER BY name ASC, id DESC";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
    const st = program.statements[0];
    switch (st) {
        .Query => |q| {
            try std.testing.expect(q.order_by != null);
            const ob = q.order_by.?;
            try std.testing.expect(ob.keys.len == 2);
            try std.testing.expect(!ob.keys[0].desc);
            try std.testing.expect(ob.keys[1].desc);
        },
        else => return error.Unexpected,
    }
}

test "UNION ALL basic" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (a)-[r]->(b) RETURN a UNION ALL MATCH (c)-[d]->(e) RETURN c";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
}

test "ORDER BY expression keys" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (n)-[r]->(m) RETURN n ORDER BY n.age + 1 DESC, n.name";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
    const st = program.statements[0];
    switch (st) {
        .Query => |q| {
            try std.testing.expect(q.order_by != null);
            const ob = q.order_by.?;
            try std.testing.expect(ob.keys.len == 2);
            try std.testing.expect(ob.keys[0].desc);
            // First key should be Binary(Add) between Member(n.age) and Int(1)
            const k0 = ob.keys[0].expr;
            try std.testing.expect(@as(@TypeOf(k0), k0) == .Binary);
            const b = k0.Binary;
            try std.testing.expect(b.op == .Add);
            try std.testing.expect(b.left.* == .Member);
            try std.testing.expect(b.right.* == .Int);
            // Second key should be Member(n.name)
            const k1 = ob.keys[1].expr;
            try std.testing.expect(@as(@TypeOf(k1), k1) == .Member);
        },
        else => return error.Unexpected,
    }
}

test "ident_order_only rejects member keys" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (n)-[r]->(m) RETURN n ORDER BY n.name";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next(), .ident_order_only = true };
    try std.testing.expectError(error.UnexpectedToken, p.parseProgram());
}

test "UNION chain" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (a)-[r]->(b) RETURN a UNION DISTINCT MATCH (c)-[d]->(e) RETURN c UNION ALL MATCH (x)-[y]->(z) RETURN x";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
    const st = program.statements[0];
    switch (st) {
        .Union => |u| {
            try std.testing.expect(u.tails.len == 2);
            try std.testing.expect(u.tails[0].distinct);
            try std.testing.expect(!u.tails[0].all);
            try std.testing.expect(u.tails[1].all);
        },
        else => return error.Unexpected,
    }
}

test "function call and map literal" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (n)-[r]->(m) WHERE exists(n.name) RETURN {k: 1, v: n.age} AS m";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
}

test "multi-hop and multiple MATCH patterns" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (a)-[r1]->(b)-[r2]->(c), (x)<-[r3]-(y) RETURN a";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
    const st = program.statements[0];
    switch (st) {
        .Query => |q| {
            const chains = q.match.chains;
            try std.testing.expect(chains.len == 2);
            try std.testing.expect(chains[0].hops.len == 2);
            try std.testing.expect(chains[1].hops.len == 1);
        },
        else => return error.Unexpected,
    }
}

test "relationship length quantifiers" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (a)-[r*2..5]->(b), (x)-[s*]->(y), (m)-[t*3]-(n) RETURN a";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
    const st = program.statements[0];
    switch (st) {
        .Query => |q| {
            const ch = q.match.chains;
            const r1 = ch[0].hops[0].rel;
            try std.testing.expect(r1.min_len.? == 2 and r1.max_len.? == 5);
            const r2 = ch[1].hops[0].rel;
            try std.testing.expect(r2.min_len.? == 0 and r2.max_len == null);
            const r3 = ch[2].hops[0].rel;
            try std.testing.expect(r3.min_len.? == 3 and r3.max_len.? == 3);
        },
        else => return error.Unexpected,
    }
}

test "GROUP BY syntax" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (n)-[r]->(m) WHERE n.age > 20 GROUP BY n.name, n.age RETURN COUNT(n)";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
    const st = program.statements[0];
    switch (st) {
        .Query => |q| {
            try std.testing.expect(q.group_by != null);
            try std.testing.expect(q.group_by.?.keys.len == 2);
        },
        else => return error.Unexpected,
    }
}

test "path variable alias and RETURN" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH p = (a)-[r*..5]->(b) RETURN p";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
    const st = program.statements[0];
    switch (st) {
        .Query => |q| {
            try std.testing.expect(q.match.chains.len == 1);
            try std.testing.expect(q.match.chains[0].name != null);
        },
        else => return error.Unexpected,
    }
}

test "alternation in relationship types" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (a)-[r:KNOWS|LIKES|FOLLOWS]->(b) RETURN a";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
    const st = program.statements[0];
    switch (st) {
        .Query => |q| {
            const rel = q.match.chains[0].hops[0].rel;
            try std.testing.expect(rel.types.len == 3);
        },
        else => return error.Unexpected,
    }
}

test "pattern comprehension basic" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (n) RETURN [ (n)-[r]->(m) WHERE m.age > 10 | m.name ]";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
}

test "ORDER BY path alias is rejected (policy)" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH p = (a)-[r]->(b) RETURN a ORDER BY p";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next(), .forbid_orderby_paths = true };
    try std.testing.expectError(error.UnexpectedToken, p.parseProgram());
}
