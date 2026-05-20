// GPS Phase 4 (Task 4-3): parser unit tests for CREATE POLICY, DROP POLICY, SHOW POLICIES.
//
// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=ParserTests; STATUS=TESTED; TEST=self; OWNER=security; UPDATED=2026-05-20

const std = @import("std");
const geode = @import("geode");
const parser_mod = geode.gql.parser;
const lexer_mod = geode.gql.lexer;
const ast = geode.gql.ast;

fn parseOne(src: []const u8, arena: *std.heap.ArenaAllocator) !ast.Statement {
    var lx = lexer_mod.Lexer{ .src = src };
    var p = parser_mod.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), prog.statements.len);
    return prog.statements[0];
}

// ---------------------------------------------------------------------------
// CREATE POLICY
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=CreatePolicyParse; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "parser: CREATE POLICY p1 ON GRAPH * FOR READ" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("CREATE POLICY p1 ON GRAPH * FOR READ;", &arena);
    try std.testing.expect(st == .CreatePolicy);
    try std.testing.expectEqualStrings("p1", st.CreatePolicy.name);
    try std.testing.expectEqualStrings("*", st.CreatePolicy.scope_graph);
    try std.testing.expectEqual(@as(usize, 1), st.CreatePolicy.actions.len);
    try std.testing.expectEqual(ast.PolicyAction.read, st.CreatePolicy.actions[0]);
}

// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=CreatePolicyMultiAction; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "parser: CREATE POLICY p2 ON GRAPH hr FOR READ, WRITE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("CREATE POLICY p2 ON GRAPH hr FOR READ, WRITE;", &arena);
    try std.testing.expect(st == .CreatePolicy);
    try std.testing.expectEqualStrings("p2", st.CreatePolicy.name);
    try std.testing.expectEqualStrings("hr", st.CreatePolicy.scope_graph);
    try std.testing.expectEqual(@as(usize, 2), st.CreatePolicy.actions.len);
    try std.testing.expectEqual(ast.PolicyAction.read, st.CreatePolicy.actions[0]);
    try std.testing.expectEqual(ast.PolicyAction.write, st.CreatePolicy.actions[1]);
}

// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=CreatePolicyAllActions; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "parser: CREATE POLICY p3 ON GRAPH * FOR READ, WRITE, MATCH, CREATE, UPDATE, DELETE, SCHEMA" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne(
        "CREATE POLICY p3 ON GRAPH * FOR READ, WRITE, MATCH, CREATE, UPDATE, DELETE, SCHEMA;",
        &arena,
    );
    try std.testing.expect(st == .CreatePolicy);
    try std.testing.expectEqualStrings("p3", st.CreatePolicy.name);
    try std.testing.expectEqualStrings("*", st.CreatePolicy.scope_graph);
    try std.testing.expectEqual(@as(usize, 7), st.CreatePolicy.actions.len);
    try std.testing.expectEqual(ast.PolicyAction.read, st.CreatePolicy.actions[0]);
    try std.testing.expectEqual(ast.PolicyAction.write, st.CreatePolicy.actions[1]);
    try std.testing.expectEqual(ast.PolicyAction.match_, st.CreatePolicy.actions[2]);
    try std.testing.expectEqual(ast.PolicyAction.create, st.CreatePolicy.actions[3]);
    try std.testing.expectEqual(ast.PolicyAction.update, st.CreatePolicy.actions[4]);
    try std.testing.expectEqual(ast.PolicyAction.delete, st.CreatePolicy.actions[5]);
    try std.testing.expectEqual(ast.PolicyAction.schema, st.CreatePolicy.actions[6]);
}

// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=CreatePolicyNamedGraph; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "parser: CREATE POLICY q1 ON GRAPH finance FOR SCHEMA" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("CREATE POLICY q1 ON GRAPH finance FOR SCHEMA;", &arena);
    try std.testing.expect(st == .CreatePolicy);
    try std.testing.expectEqualStrings("q1", st.CreatePolicy.name);
    try std.testing.expectEqualStrings("finance", st.CreatePolicy.scope_graph);
    try std.testing.expectEqual(@as(usize, 1), st.CreatePolicy.actions.len);
    try std.testing.expectEqual(ast.PolicyAction.schema, st.CreatePolicy.actions[0]);
}

// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=CreatePolicyTrailingClauses; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "parser: CREATE POLICY with trailing TO ROLE clause discarded (Phase 5+)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Phase 5+ clause: TO ROLE myrole — should be silently discarded.
    const st = try parseOne(
        "CREATE POLICY sec1 ON GRAPH * FOR READ TO ROLE myrole;",
        &arena,
    );
    try std.testing.expect(st == .CreatePolicy);
    try std.testing.expectEqualStrings("sec1", st.CreatePolicy.name);
    try std.testing.expectEqualStrings("*", st.CreatePolicy.scope_graph);
    try std.testing.expectEqual(@as(usize, 1), st.CreatePolicy.actions.len);
    try std.testing.expectEqual(ast.PolicyAction.read, st.CreatePolicy.actions[0]);
}

// ---------------------------------------------------------------------------
// DROP POLICY
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=DropPolicyParse; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "parser: DROP POLICY p1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("DROP POLICY p1;", &arena);
    try std.testing.expect(st == .DropPolicy);
    try std.testing.expectEqualStrings("p1", st.DropPolicy.name);
    try std.testing.expect(!st.DropPolicy.if_exists);
}

// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=DropPolicyIfExists; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "parser: DROP POLICY IF EXISTS p1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("DROP POLICY IF EXISTS p1;", &arena);
    try std.testing.expect(st == .DropPolicy);
    try std.testing.expectEqualStrings("p1", st.DropPolicy.name);
    try std.testing.expect(st.DropPolicy.if_exists);
}

// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=DropPolicyNoSemicolon; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "parser: DROP POLICY without semicolon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("DROP POLICY my_pol", &arena);
    try std.testing.expect(st == .DropPolicy);
    try std.testing.expectEqualStrings("my_pol", st.DropPolicy.name);
    try std.testing.expect(!st.DropPolicy.if_exists);
}

// ---------------------------------------------------------------------------
// SHOW POLICIES
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=ShowPoliciesParse; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "parser: SHOW POLICIES" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("SHOW POLICIES;", &arena);
    try std.testing.expect(st == .Show);
    try std.testing.expectEqual(ast.ShowType.policies, st.Show.show_type);
    try std.testing.expect(st.Show.target == null);
}

// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=ShowPolicySingular; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "parser: SHOW POLICY (singular alias)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("SHOW POLICY", &arena);
    try std.testing.expect(st == .Show);
    try std.testing.expectEqual(ast.ShowType.policies, st.Show.show_type);
}
