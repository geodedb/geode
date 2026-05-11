const std = @import("std");
const geode = @import("geode");
const parser_mod = geode.gql.parser;
const lexer_mod = geode.gql.lexer;
const ast = geode.gql.ast;

// CANARY: REQ=REQ-GQL-AUTH-DDL-002; FEATURE="GQL Auth DDL"; ASPECT=Parser; STATUS=TESTED; TEST=self; OWNER=parser; UPDATED=2026-05-11

fn parseOne(src: []const u8, arena: *std.heap.ArenaAllocator) !ast.Statement {
    var lx = lexer_mod.Lexer{ .src = src };
    var p = parser_mod.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), prog.statements.len);
    return prog.statements[0];
}

test "auth ddl: CREATE USER with password" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("CREATE USER alice SET PASSWORD 's3cret11'", &arena);
    try std.testing.expect(st == .CreateUser);
    try std.testing.expectEqualStrings("alice", st.CreateUser.name);
    // Lexer strips surrounding quotes; lexeme is the bare string content.
    try std.testing.expectEqualStrings("s3cret11", st.CreateUser.password);
    try std.testing.expect(st.CreateUser.email == null);
    try std.testing.expect(st.CreateUser.role == null);
}

test "auth ddl: CREATE USER with email and role" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("CREATE USER bob SET PASSWORD 'pw123456' EMAIL 'bob@x.io' ROLE readwrite", &arena);
    try std.testing.expect(st == .CreateUser);
    try std.testing.expectEqualStrings("bob", st.CreateUser.name);
    try std.testing.expectEqualStrings("pw123456", st.CreateUser.password);
    try std.testing.expect(st.CreateUser.email != null);
    try std.testing.expectEqualStrings("bob@x.io", st.CreateUser.email.?);
    try std.testing.expect(st.CreateUser.role != null);
    try std.testing.expectEqualStrings("readwrite", st.CreateUser.role.?);
}

test "auth ddl: ALTER USER SET PASSWORD" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("ALTER USER alice SET PASSWORD 'newpass9'", &arena);
    try std.testing.expect(st == .AlterUser);
    try std.testing.expectEqualStrings("alice", st.AlterUser.name);
    try std.testing.expect(st.AlterUser.action == .set_password);
    // Lexer strips quotes; bare content only.
    try std.testing.expectEqualStrings("newpass9", st.AlterUser.action.set_password);
}

test "auth ddl: ALTER USER SET ROLE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("ALTER USER alice SET ROLE admin", &arena);
    try std.testing.expect(st == .AlterUser);
    try std.testing.expect(st.AlterUser.action == .set_role);
    try std.testing.expectEqualStrings("admin", st.AlterUser.action.set_role);
}

test "auth ddl: ALTER USER ENABLE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("ALTER USER alice ENABLE", &arena);
    try std.testing.expect(st == .AlterUser);
    try std.testing.expect(st.AlterUser.action == .enable);
}

test "auth ddl: ALTER USER DISABLE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("ALTER USER alice DISABLE", &arena);
    try std.testing.expect(st == .AlterUser);
    try std.testing.expect(st.AlterUser.action == .disable);
}

test "auth ddl: DROP USER plain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("DROP USER alice", &arena);
    try std.testing.expect(st == .DropUser);
    try std.testing.expectEqualStrings("alice", st.DropUser.name);
    try std.testing.expect(!st.DropUser.if_exists);
}

test "auth ddl: DROP ROLE IF EXISTS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("DROP ROLE IF EXISTS auditor", &arena);
    try std.testing.expect(st == .DropRole);
    try std.testing.expectEqualStrings("auditor", st.DropRole.name);
    try std.testing.expect(st.DropRole.if_exists);
}

test "auth ddl: CREATE ROLE with description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("CREATE ROLE auditor SET DESCRIPTION 'read only'", &arena);
    try std.testing.expect(st == .CreateRole);
    try std.testing.expectEqualStrings("auditor", st.CreateRole.name);
    try std.testing.expect(st.CreateRole.description != null);
    // Lexer strips quotes; spaces within the string are preserved.
    try std.testing.expectEqualStrings("read only", st.CreateRole.description.?);
}

test "auth ddl: GRANT ROLE TO user" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("GRANT ROLE auditor TO alice", &arena);
    try std.testing.expect(st == .Grant);
    try std.testing.expect(st.Grant.subject == .role);
    try std.testing.expectEqualStrings("auditor", st.Grant.subject.role);
    try std.testing.expectEqualStrings("alice", st.Grant.grantee);
    try std.testing.expect(st.Grant.on_graph == null);
}

test "auth ddl: GRANT privilege ON GRAPH TO user" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("GRANT READ ON GRAPH sales TO alice", &arena);
    try std.testing.expect(st == .Grant);
    try std.testing.expect(st.Grant.subject == .privilege);
    try std.testing.expect(st.Grant.subject.privilege == .read);
    try std.testing.expect(st.Grant.on_graph != null);
    try std.testing.expectEqualStrings("sales", st.Grant.on_graph.?);
    try std.testing.expectEqualStrings("alice", st.Grant.grantee);
}

test "auth ddl: REVOKE privilege FROM user" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("REVOKE WRITE FROM alice", &arena);
    try std.testing.expect(st == .Revoke);
    try std.testing.expect(st.Revoke.privilege == .write);
    try std.testing.expect(st.Revoke.on_graph == null);
    try std.testing.expectEqualStrings("alice", st.Revoke.grantee);
}

test "auth ddl: SHOW USERS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("SHOW USERS", &arena);
    try std.testing.expect(st == .Show);
    try std.testing.expect(st.Show.show_type == .users);
    try std.testing.expect(st.Show.target == null);
}

test "auth ddl: SHOW ROLES" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("SHOW ROLES", &arena);
    try std.testing.expect(st == .Show);
    try std.testing.expect(st.Show.show_type == .roles);
}

test "auth ddl: SHOW PERMISSIONS (no target)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("SHOW PERMISSIONS", &arena);
    try std.testing.expect(st == .Show);
    try std.testing.expect(st.Show.show_type == .permissions);
    try std.testing.expect(st.Show.target == null);
}

test "auth ddl: SHOW PERMISSIONS FOR user" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("SHOW PERMISSIONS FOR alice", &arena);
    try std.testing.expect(st == .Show);
    try std.testing.expect(st.Show.show_type == .permissions);
    try std.testing.expect(st.Show.target != null);
    try std.testing.expectEqualStrings("alice", st.Show.target.?);
}

test "auth ddl: SHOW VERSION" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("SHOW VERSION", &arena);
    try std.testing.expect(st == .Show);
    try std.testing.expect(st.Show.show_type == .version);
}

test "auth ddl: SHOW CAPABILITIES" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("SHOW CAPABILITIES", &arena);
    try std.testing.expect(st == .Show);
    try std.testing.expect(st.Show.show_type == .capabilities);
}
