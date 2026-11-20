// SONNY-6447 item 4: the raw-string RLS policy interpreter
// (`rls_core.ContextEvaluator`, reached by `RLSEngine.evaluateExpression` for a
// policy without compiled code in a server built with
// -Dallow-rls-raw-interp=true) split a policy at the first " OR " / " AND ",
// the first comparison operator, the first "(" and every "," of a call's
// arguments, wherever they were: inside a quoted string or a parenthesised
// group. So `name = 'q OR true OR q'` admitted every row (its tail `true OR q'`
// is True), `(off OR active) AND active` failed to parse, and `has_role('a,b')`
// passed two arguments. A policy whose quotes or parentheses do not balance
// was evaluated up to the first OR that held (`active OR (` admitted).
//
// The interpreter now splits only at operators outside quotes and at
// parenthesis depth 0, splits call arguments the same way, and refuses (an
// error, which every caller turns into a deny) a policy whose quotes or
// parentheses do not balance.
//
// CANARY: REQ=REQ-SONNY-6447-RLS-RAW-TOKENIZE; FEATURE="RLSExpressionEvaluation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6447_rls_raw_tokenize.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const rls = @import("rls");
const auth = @import("geode_auth");

const Value = rls.Value;

const Case = struct {
    expr: []const u8,
    want: bool,
};

fn fillRow(row: *std.StringHashMap(Value)) !void {
    try row.put("name", .{ .string = "test" });
    try row.put("phrase", .{ .string = "a AND b" });
    try row.put("either", .{ .string = "a OR b" });
    try row.put("cmp", .{ .string = "x <> y" });
    try row.put("paren", .{ .string = "(p)" });
    try row.put("active", .{ .boolean = true });
    try row.put("off", .{ .boolean = false });
}

/// A quoted operator, comma or parenthesis is part of the string.
const quoted = [_]Case{
    .{ .expr = "phrase = 'a AND b'", .want = true },
    .{ .expr = "either = 'a OR b'", .want = true },
    .{ .expr = "phrase = 'a AND b' AND active", .want = true },
    .{ .expr = "cmp = 'x <> y'", .want = true },
    .{ .expr = "paren = '(p)'", .want = true },
    .{ .expr = "has_role('a,b')", .want = true },
    .{ .expr = "has_role('a OR b')", .want = false },
    // Not "name = 'q" OR "true OR q'", whose tail is True.
    .{ .expr = "name = 'q OR true OR q'", .want = false },
    .{ .expr = "name = 'q AND true' OR off", .want = false },
};

/// A parenthesised group is one operand.
const grouped = [_]Case{
    .{ .expr = "(off OR active) AND active", .want = true },
    .{ .expr = "active AND (off OR active)", .want = true },
    .{ .expr = "(off OR active) AND off", .want = false },
    .{ .expr = "(active AND off) OR (off AND active)", .want = false },
    .{ .expr = "((active))", .want = true },
    .{ .expr = "(active) AND (name = 'test')", .want = true },
    .{ .expr = "has_role('reader') AND (off OR has_role('a,b'))", .want = true },
};

/// A policy that does not parse denies (an error or false, never true).
const malformed = [_][]const u8{
    "active OR (",
    "active OR off)",
    "active OR 'unterminated",
    "off OR active OR 'oops",
    "(active",
    "active)",
    "has_role('reader'",
};

fn testUser(allocator: std.mem.Allocator) auth.User {
    return .{
        .id = 42,
        .username = "u6447",
        .email = "u6447@example.com",
        .password_hash = "$argon2id$v=19$m=65536,t=3,p=4$test$test",
        .created_at = 0,
        .updated_at = 0,
        .last_login = null,
        .is_active = true,
        .is_superuser = false,
        .mfa_enabled = false,
        .mfa_secret = null,
        .recovery_codes = null,
        .attributes = std.StringHashMap([]const u8).init(allocator),
    };
}

fn role(id: u64, name: []const u8) auth.Role {
    return .{ .id = id, .name = name, .description = "", .permissions = .empty, .created_at = 0, .is_system = false, .priority = 0, .parent_role = null };
}

test "SONNY-6447: the raw-string RLS interpreter splits only outside quotes and parentheses, and denies what does not parse" {
    const allocator = testing.allocator;
    var evaluator = try rls.ContextEvaluator.init(allocator);
    defer evaluator.deinit();
    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();
    try fillRow(&row);

    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();
    var user = testUser(allocator);
    defer user.attributes.deinit();
    const roles = [_]auth.Role{ role(1, "reader"), role(2, "a,b") };
    var context = auth.SecurityContext{
        .user = &user,
        .roles = &roles,
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = .{ .ip_address = "127.0.0.1", .user_agent = "t", .device_id = null, .location = null, .timestamp = 0 },
    };

    var wrong: usize = 0;
    for ([_][]const Case{ &quoted, &grouped }, [_][]const u8{ "quoted", "grouped" }) |cases, group| {
        for (cases) |c| {
            const got = evaluator.evaluate(c.expr, &row, &context) catch |err| {
                std.debug.print("[{s}] \"{s}\": error {s}, expected {}\n", .{ group, c.expr, @errorName(err), c.want });
                wrong += 1;
                continue;
            };
            if (got != c.want) {
                std.debug.print("[{s}] \"{s}\": {}, expected {}\n", .{ group, c.expr, got, c.want });
                wrong += 1;
            }
        }
    }
    for (malformed) |expr| {
        const got = evaluator.evaluate(expr, &row, &context) catch false;
        if (got) {
            std.debug.print("[malformed] \"{s}\": admitted, expected a deny\n", .{expr});
            wrong += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}
