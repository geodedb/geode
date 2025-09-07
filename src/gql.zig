const std = @import("std");
const Lexer = @import("gql/lexer.zig").Lexer;
const Parser = @import("gql/parser.zig").Parser;
const ast = @import("gql/ast.zig");
const printer = @import("gql/print.zig");

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

test "string predicates and regex operator parse" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (n) WHERE n.name STARTS WITH \"Al\" AND n.tag ENDS WITH \"Z\" AND n.bio CONTAINS \"graph\" AND n.name =~ \"^A.*\" RETURN n";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
}

test "temporal literals DATE and DATETIME parse" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (n) WHERE n.dob = DATE\"2024-08-12\" AND n.ts = DATETIME\"2024-08-12T10:15:30Z\" RETURN n";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
}

test "DATETIME variants: offsets and fractional seconds" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const cases = [_][]const u8{
        "MATCH (n) WHERE n.ts = DATETIME\"2024-08-12T10:15:30.123Z\" RETURN n",
        "MATCH (n) WHERE n.ts = DATETIME\"2024-08-12t10:15:30z\" RETURN n",
        "MATCH (n) WHERE n.ts = DATETIME\"2024-08-12T10:15+02:00\" RETURN n",
        "MATCH (n) WHERE n.ts = DATETIME\"2024-08-12T10:15-05:30\" RETURN n",
        "MATCH (n) WHERE n.ts = DATETIME\"2024-08-12T10:15:30.999+00:00\" RETURN n",
    };
    inline for (cases) |src| {
        var lx = Lexer{ .src = src };
        var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
        const program = try p.parseProgram();
        try std.testing.expect(program.statements.len == 1);
    }
    // Bad forms: missing T, bad offset, bad fractional
    const bads = [_][]const u8{
        "MATCH (n) WHERE n.ts = DATETIME\"2024-08-12 10:15\" RETURN n",
        "MATCH (n) WHERE n.ts = DATETIME\"2024-08-12T10:15+2:00\" RETURN n",
        "MATCH (n) WHERE n.ts = DATETIME\"2024-08-12T10:15:30.\" RETURN n",
    };
    inline for (bads) |src| {
        var lx = Lexer{ .src = src };
        var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
        try std.testing.expectError(error.UnexpectedToken, p.parseProgram());
    }
}

test "printer normalization for temporal literals" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (n) WHERE n.t = TIME\"10:05:03.123z\" AND n.ts = DATETIME\"2024-08-12t10:05:03.123+00:00\" RETURN n";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    // Print normalized query
    var out = std.ArrayList(u8).initCapacity(ally, 0) catch @panic("OOM");
    defer out.deinit(ally);
    const q = blk: {
        const st = program.statements[0];
        switch (st) {
            .Query => |qq| break :blk qq,
            else => return error.Unexpected,
        }
    };
    try printer.printQueryWith(out.writer(ally), q, 0, .{ .normalize_temporals = true, .clamp_frac_digits = 3 });
    const s = out.items;
    try std.testing.expect(std.mem.indexOf(u8, s, "TIME\"10:05:03.123Z\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "DATETIME\"2024-08-12T10:05:03.123Z\"") != null);
}

test "printer normalization: offset and fraction clamping" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (n) WHERE n.ts1 = DATETIME\"2024-01-02t03:04+05\" AND n.ts2 = DATETIME\"2024-01-02T03:04-05:30\" AND n.t = TIME\"03:04:05.123456789Z\" RETURN n";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    var out = std.ArrayList(u8).initCapacity(ally, 0) catch @panic("OOM");
    defer out.deinit(ally);
    const q = blk: {
        const st = program.statements[0];
        switch (st) {
            .Query => |qq| break :blk qq,
            else => return error.Unexpected,
        }
    };
    try printer.printQueryWith(out.writer(ally), q, 0, .{ .normalize_temporals = true, .clamp_frac_digits = 6 });
    const s = out.items;
    // offset formatting is normalized, fraction clamped below
    // Fraction clamped to 6
    try std.testing.expect(std.mem.indexOf(u8, s, "TIME\"03:04:05.123456Z\"") != null);
}

test "DATE/TIME two-digit component formatting in normalization" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    // Note: Non-two-digit inputs would be rejected; assert normalized printing keeps two digits with valid inputs.
    const src2 = "MATCH (n) WHERE n.d = DATE\"2024-01-02\" AND n.t = TIME\"03:04\" RETURN n";
    var lx2 = Lexer{ .src = src2 };
    var p2 = Parser{ .lx = &lx2, .arena = &arena, .cur = lx2.next() };
    const pr = try p2.parseProgram();
    var out = std.ArrayList(u8).initCapacity(ally, 0) catch @panic("OOM");
    defer out.deinit(ally);
    const q = blk: {
        const st = pr.statements[0];
        switch (st) {
            .Query => |qq| break :blk qq,
            else => return error.Unexpected,
        }
    };
    try printer.printQueryWith(out.writer(ally), q, 0, .{ .normalize_temporals = true });
    const s = out.items;
    try std.testing.expect(std.mem.indexOf(u8, s, "DATE\"2024-01-02\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "TIME\"03:04\"") != null);
}

test "JSON verbose temporals includes kind/raw/parsed" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (n) WHERE n.d = DATE\"2024-01-02\" AND n.t = TIME\"03:04:05.123Z\" AND n.ts = DATETIME\"2024-01-02T03:04Z\" AND n.l = LOCAL DATETIME\"2024-01-02T03:04\" RETURN n";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    var out = std.ArrayList(u8).initCapacity(ally, 0) catch @panic("OOM");
    defer out.deinit(ally);
    try printer.printProgramJsonWith(out.writer(ally), program, .{ .verbose_temporals = true });
    const s = out.items;
    // Top-level temporals array exists
    try std.testing.expect(std.mem.indexOf(u8, s, "\"temporals\"") != null);
    // Contains each kind at least once
    try std.testing.expect(std.mem.indexOf(u8, s, "\"Date\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"Time\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"DateTime\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"LocalDateTime\"") != null);
    // Has raw and parsed fields
    try std.testing.expect(std.mem.indexOf(u8, s, "\"raw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"parsed\"") != null);
}

test "temporal TIME and LOCAL DATETIME parse and validate" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src_ok = "MATCH (n) WHERE n.t = TIME\"10:15:30.123Z\" AND n.l = LOCAL DATETIME\"2024-08-12T10:15\" RETURN n";
    var lx1 = Lexer{ .src = src_ok };
    var p1 = Parser{ .lx = &lx1, .arena = &arena, .cur = lx1.next() };
    const pr1 = try p1.parseProgram();
    try std.testing.expect(pr1.statements.len == 1);
    const src_bad_time = "MATCH (n) WHERE n.t = TIME\"25:00\" RETURN n"; // invalid hour
    var lx2 = Lexer{ .src = src_bad_time };
    var p2 = Parser{ .lx = &lx2, .arena = &arena, .cur = lx2.next() };
    try std.testing.expectError(error.UnexpectedToken, p2.parseProgram());
    const src_bad_local_dt = "MATCH (n) WHERE n.l = LOCAL DATETIME\"2024-08-12T10:15Z\" RETURN n"; // zone not allowed
    var lx3 = Lexer{ .src = src_bad_local_dt };
    var p3 = Parser{ .lx = &lx3, .arena = &arena, .cur = lx3.next() };
    try std.testing.expectError(error.UnexpectedToken, p3.parseProgram());
}

test "DATE literal format validation (rejects bad format)" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (n) WHERE n.dob = DATE\"2024/08/12\" RETURN n";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    try std.testing.expectError(error.UnexpectedToken, p.parseProgram());
}

test "CASE expression parse (simple and searched)" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src1 = "MATCH (n) RETURN CASE n.age WHEN 18 THEN \"minor\" WHEN 21 THEN \"twenty-one\" ELSE \"adult\" END";
    var lx1 = Lexer{ .src = src1 };
    var p1 = Parser{ .lx = &lx1, .arena = &arena, .cur = lx1.next() };
    const pr1 = try p1.parseProgram();
    try std.testing.expect(pr1.statements.len == 1);
    const src2 = "MATCH (n) RETURN CASE WHEN n.age < 18 THEN \"minor\" ELSE \"adult\" END";
    var lx2 = Lexer{ .src = src2 };
    var p2 = Parser{ .lx = &lx2, .arena = &arena, .cur = lx2.next() };
    const pr2 = try p2.parseProgram();
    try std.testing.expect(pr2.statements.len == 1);
}

test "eval acceptance: CASE WHEN a>0 THEN 'p' ELSE 'n' END" {
    const ally = std.testing.allocator;
    const geode = @import("lib.zig");
    const env = geode.eval.Env{ .names = &.{"a"}, .values = &.{geode.eval.Value{ .Int = 5 }} };
    var a_expr = geode.ast.Expr{ .Ident = "a" };
    var zero = geode.ast.Expr{ .Int = 0 };
    var pred = geode.ast.Expr{ .Binary = .{ .op = .Gt, .left = &a_expr, .right = &zero } };
    var p = geode.ast.Expr{ .String = "p" };
    var n = geode.ast.Expr{ .String = "n" };
    var whs: [1]geode.ast.CaseWhen = .{.{ .when = &pred, .then_expr = &p }};
    const cse = geode.ast.Expr{ .Case = .{ .operand = null, .whens = whs[0..], .else_expr = &n } };
    const out = try geode.eval.evalExpr(ally, cse, env);
    try std.testing.expect(out == .Str and std.mem.eql(u8, out.Str, "p"));
}

test "diagnostics acceptance: codes presence" {
    const d = @import("lib.zig").diagnostics;
    try std.testing.expectEqualStrings("US001", d.codeName(.US001));
    try std.testing.expectEqualStrings("GroupByIllegal", d.codeName(.GroupByIllegal));
    try std.testing.expectEqualStrings("IllegalOrderKey", d.codeName(.IllegalOrderKey));
    try std.testing.expectEqualStrings("TypeMismatch", d.codeName(.TypeMismatch));
}

// TODO: Pagination orderedness legality is a planner/runtime check.
// Add integration tests when planner properties and ORDER propagation exist.

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

test "INTERSECT and EXCEPT parse" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const s1 = "MATCH (a) RETURN a INTERSECT MATCH (b) RETURN b";
    var lx1 = Lexer{ .src = s1 };
    var p1 = Parser{ .lx = &lx1, .arena = &arena, .cur = lx1.next() };
    const pr1 = try p1.parseProgram();
    try std.testing.expect(pr1.statements.len == 1);
    const s2 = "MATCH (a) RETURN a EXCEPT ALL MATCH (b) RETURN b";
    var lx2 = Lexer{ .src = s2 };
    var p2 = Parser{ .lx = &lx2, .arena = &arena, .cur = lx2.next() };
    const pr2 = try p2.parseProgram();
    try std.testing.expect(pr2.statements.len == 1);
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

test "parameters: parse $name in expressions" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (n) WHERE n.age = $age AND n.name STARTS WITH $prefix RETURN n";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
}

test "parameters in GROUP BY, ORDER BY, and RETURN print" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (n) WHERE n.age > $min GROUP BY n.name RETURN n.name, COUNT(n) ORDER BY $ord";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
    var out = std.ArrayList(u8).initCapacity(ally, 0) catch @panic("OOM");
    defer out.deinit(ally);
    const st = program.statements[0];
    switch (st) {
        .Query => |q| try printer.printQueryWith(out.writer(ally), q, 0, .{}),
        else => return error.Unexpected,
    }
    const s = out.items;
    // Ensure $min and $ord are preserved in the printed text
    try std.testing.expect(std.mem.indexOf(u8, s, "$min") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "$ord") != null);
}

test "eval acceptance: WHERE and RETURN via unit harness" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    // Query uses identifiers 'a' (Int) and 's' (Str) which the harness supplies via Env
    const src = "MATCH (n) WHERE s STARTS WITH \"A\" AND a = \"42\" RETURN CASE WHEN a IN [\"41\", \"42\"] THEN s ELSE \"x\" END";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    const st = program.statements[0];
    const geode = @import("lib.zig");
    const env = geode.eval.Env{ .names = &.{ "a", "s" }, .values = &.{ geode.eval.Value{ .Int = 42 }, geode.eval.Value{ .Str = "Alice" } } };
    switch (st) {
        .Query => |q| {
            if (q.where_clause) |wc| {
                const v = try geode.eval.evalExpr(ally, wc, env);
                try std.testing.expect(v == .Bool and v.Bool == true);
            } else return error.Unexpected;
            try std.testing.expect(q.ret.items.len == 1);
            const r0 = q.ret.items[0].expr;
            const out = try geode.eval.evalExpr(ally, r0, env);
            try std.testing.expect(out == .Str and std.mem.eql(u8, out.Str, "Alice"));
        },
        else => return error.Unexpected,
    }
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

test "GROUP BY with HAVING and ORDER BY NULLS policy" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (n) WHERE n.age > 20 GROUP BY n.name HAVING COUNT(n) > 1 RETURN n ORDER BY n.name ASC NULLS LAST, n.age DESC NULLS FIRST";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
    const st = program.statements[0];
    switch (st) {
        .Query => |q| {
            try std.testing.expect(q.group_by != null);
            try std.testing.expect(q.having != null);
            try std.testing.expect(q.order_by != null);
            const ob = q.order_by.?;
            try std.testing.expect(ob.keys.len == 2);
            try std.testing.expect(ob.keys[0].nulls == .last);
            try std.testing.expect(ob.keys[1].nulls == .first);
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

test "alias lookahead: ident '=' '[' vs equality ident '=' expr" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    // Should parse as equality, not alias
    const src1 = "MATCH (n) WHERE a = 1 RETURN n";
    var lx1 = Lexer{ .src = src1 };
    var p1 = Parser{ .lx = &lx1, .arena = &arena, .cur = lx1.next() };
    const pr1 = try p1.parseProgram();
    try std.testing.expect(pr1.statements.len == 1);
    // Should parse as equality (list comprehension), not path alias, when '[' follows '=' in RETURN
    const src2 = "MATCH (n) RETURN p = [ (n)-[r]->(m) | m ]";
    var lx2 = Lexer{ .src = src2 };
    var p2 = Parser{ .lx = &lx2, .arena = &arena, .cur = lx2.next() };
    const pr2 = try p2.parseProgram();
    try std.testing.expect(pr2.statements.len == 1);
}

test "NOT IN parse" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const src = "MATCH (n) WHERE n.age NOT IN [1,2,null] RETURN n";
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    try std.testing.expect(program.statements.len == 1);
}

test "parser: chained NOT with IN and IS NULL precedence" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const s1 = "MATCH (n) WHERE NOT a IN [1,2] RETURN n"; // unary NOT over (a IN ...)
    var lx1 = Lexer{ .src = s1 };
    var p1 = Parser{ .lx = &lx1, .arena = &arena, .cur = lx1.next() };
    const pr1 = try p1.parseProgram();
    try std.testing.expect(pr1.statements.len == 1);
    const s2 = "MATCH (n) WHERE a IS NOT NULL RETURN n"; // IS NOT NULL
    var lx2 = Lexer{ .src = s2 };
    var p2 = Parser{ .lx = &lx2, .arena = &arena, .cur = lx2.next() };
    const pr2 = try p2.parseProgram();
    try std.testing.expect(pr2.statements.len == 1);
}

test "parser: nested list comprehension in expressions" {
    const ally = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const s = "MATCH (n) RETURN size([ (n)-[r]->(m) | [ (m)-[t]->(k) | k ] ])";
    var lx = Lexer{ .src = s };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const pr = try p.parseProgram();
    try std.testing.expect(pr.statements.len == 1);
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
