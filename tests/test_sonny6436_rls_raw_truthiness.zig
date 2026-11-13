// SONNY-6436 item 5: an RLS policy admits a row only when its predicate is
// True (ISO/IEC 39075:2024 19.1 GR 2, as SONNY-6425 made every query search
// condition); anything else denies.
//
// The raw-string policy interpreter (`rls_core.ContextEvaluator`, used by
// `RLSEngine.evaluateExpression` for a policy without compiled code when the
// server is built with -Dallow-rls-raw-interp=true) took:
//   * a bare non-zero integer or non-empty string (a column or a literal) as
//     true, and any other non-boolean value (a float, a timestamp, the
//     integer `current_user()` returns) as true;
//   * `a = b` / `a <> b` with a null side, or with values of kinds that do
//     not compare, as false / TRUE (so `row.cls <> 'secret'` admitted a row
//     without `cls`), and `NULL = NULL` as true;
//   * a function call followed by a comparison (`current_user() = 999`) as
//     the call alone, dropping the comparison;
//   * an empty sub-expression (`()`) as true.
// docs/audit/security-phase3-review.md finding 2 (M2).
//
// The compiled-expression VM (`evaluateCompiledExpression`) already admits
// only a boolean TRUE and compares in three-valued logic (SONNY-2709,
// SONNY-2732); the same expressions are pinned against it here, compiled by
// the engine from their text.
//
// CANARY: REQ=REQ-SONNY-6436-RLS-RAW-TRUTHINESS; FEATURE="RLSExpressionEvaluation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6436_rls_raw_truthiness.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const rls = @import("rls");
const auth = @import("geode_auth");

const Value = rls.Value;

const Case = struct {
    expr: []const u8,
    want: bool,
};

/// The row every case is evaluated against.
fn fillRow(row: *std.StringHashMap(Value)) !void {
    try row.put("owner_id", .{ .integer = 42 });
    try row.put("cnt", .{ .integer = 5 });
    try row.put("zero", .{ .integer = 0 });
    try row.put("name", .{ .string = "test" });
    try row.put("flag", .{ .string = "no" });
    try row.put("empty", .{ .string = "" });
    try row.put("active", .{ .boolean = true });
    try row.put("off", .{ .boolean = false });
    try row.put("ratio", .{ .float = 0.5 });
    try row.put("nan", .{ .float = std.math.nan(f64) });
    try row.put("at", .{ .timestamp = 1000 });
    try row.put("nothing", .null);
}

/// Expressions whose verdict changes (BREAKING): each used to admit the row
/// (or, for `has_role('auditor') = false`, to deny it).
const changed = [_]Case{
    // A value that is not a boolean is not True.
    .{ .expr = "cnt", .want = false },
    .{ .expr = "flag", .want = false },
    .{ .expr = "ratio", .want = false },
    .{ .expr = "at", .want = false },
    .{ .expr = "'anything'", .want = false },
    .{ .expr = "1", .want = false },
    .{ .expr = "current_user()", .want = false },
    .{ .expr = "current_timestamp()", .want = false },
    .{ .expr = "cnt AND active", .want = false },
    // A comparison with a null side is UNKNOWN: not True, under = or <>.
    .{ .expr = "missing = NULL", .want = false },
    .{ .expr = "nothing = NULL", .want = false },
    .{ .expr = "missing <> 'secret'", .want = false },
    .{ .expr = "nothing <> 'secret'", .want = false },
    .{ .expr = "name <> NULL", .want = false },
    // Values that do not compare (and NaN) are UNKNOWN too.
    .{ .expr = "owner_id <> 'x'", .want = false },
    .{ .expr = "name <> 1", .want = false },
    .{ .expr = "active <> 1", .want = false },
    .{ .expr = "nan <> nan", .want = false },
    // A call followed by a comparison is the comparison.
    .{ .expr = "current_user() = 999", .want = false },
    .{ .expr = "has_role('auditor') = false", .want = true },
    // An empty sub-expression is not True.
    .{ .expr = "()", .want = false },
    .{ .expr = "active AND ()", .want = false },
};

/// Expressions whose verdict is unchanged.
const unchanged = [_]Case{
    .{ .expr = "active", .want = true },
    .{ .expr = "off", .want = false },
    .{ .expr = "zero", .want = false },
    .{ .expr = "empty", .want = false },
    .{ .expr = "missing", .want = false },
    .{ .expr = "true", .want = true },
    .{ .expr = "false", .want = false },
    .{ .expr = "owner_id = 42", .want = true },
    .{ .expr = "owner_id = 41", .want = false },
    .{ .expr = "owner_id <> 41", .want = true },
    .{ .expr = "owner_id != 42", .want = false },
    .{ .expr = "name = 'test'", .want = true },
    .{ .expr = "name <> 'test'", .want = false },
    .{ .expr = "name = 1", .want = false },
    .{ .expr = "ratio = 0.5", .want = false }, // the interpreter reads no float literal
    .{ .expr = "owner_id = current_user()", .want = true },
    .{ .expr = "current_user() = 42", .want = true },
    .{ .expr = "has_role('reader')", .want = true },
    .{ .expr = "has_role('auditor')", .want = false },
    .{ .expr = "has_role('reader') = true", .want = true },
    .{ .expr = "has_permission('reader')", .want = true },
    .{ .expr = "owner_id = 41 OR active", .want = true },
    .{ .expr = "owner_id = 42 AND off", .want = false },
    .{ .expr = "(owner_id = 42)", .want = true },
    .{ .expr = "", .want = true }, // no predicate at all (`evaluate`'s documented default)
};

fn testUser(allocator: std.mem.Allocator) auth.User {
    return .{
        .id = 42,
        .username = "u6436",
        .email = "u6436@example.com",
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

test "SONNY-6436: the raw-string RLS interpreter admits a row only when the predicate is True" {
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
    const roles = [_]auth.Role{.{ .id = 1, .name = "reader", .description = "", .permissions = .empty, .created_at = 0, .is_system = false, .priority = 0, .parent_role = null }};
    var context = auth.SecurityContext{
        .user = &user,
        .roles = &roles,
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = .{ .ip_address = "127.0.0.1", .user_agent = "t", .device_id = null, .location = null, .timestamp = 0 },
    };

    var wrong: usize = 0;
    for ([_][]const Case{ &changed, &unchanged }, [_][]const u8{ "changed", "unchanged" }) |cases, group| {
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
    try testing.expectEqual(@as(usize, 0), wrong);
}

/// The compiled VM's verdict on `expr` (a restrictive policy on table `T`)
/// for the row above, or null when the engine refuses to compile it.
fn compiledVerdict(engine: *rls.RLSEngine, id: u64, expr: []const u8, row: *const std.StringHashMap(Value)) !?bool {
    engine.createPolicy(.{
        .id = id,
        .name = "sonny6436",
        .description = expr,
        .graph = "g6436",
        .table = "T",
        .operation = .all,
        .permissive = false,
        .roles = &.{},
        .using_expr = .{ .raw = expr, .parsed = null, .compiled = null, .parameters = &.{} },
        .check_expr = null,
        .enabled = true,
        .created_at = 0,
        .updated_at = 0,
        .created_by = 0,
        .temporal = null,
        .data_classification = null,
        .audit_level = .none,
    }) catch return null;
    defer engine.deletePolicy(id) catch {};
    return engine.checkRowAccessByUsername(row, .select, "u6436", "g6436", "T") catch false;
}

test "SONNY-6436: the compiled RLS VM admits a row only when the predicate is True" {
    const allocator = testing.allocator;
    var engine = try rls.RLSEngine.init(allocator);
    defer engine.deinit();
    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();
    try fillRow(&row);

    // The policy language names a row's property `row.<name>`.
    const cases = [_]Case{
        .{ .expr = "row.cnt", .want = false },
        .{ .expr = "row.flag", .want = false },
        .{ .expr = "row.ratio", .want = false },
        .{ .expr = "'anything'", .want = false },
        .{ .expr = "1", .want = false },
        .{ .expr = "row.missing <> 'secret'", .want = false },
        .{ .expr = "row.nothing <> 'secret'", .want = false },
        .{ .expr = "row.owner_id <> 'x'", .want = false },
        .{ .expr = "row.cnt AND row.active", .want = false },
        .{ .expr = "row.active", .want = true },
        .{ .expr = "row.owner_id = 42", .want = true },
        .{ .expr = "row.name <> 'other'", .want = true },
    };
    var wrong: usize = 0;
    var compiled: usize = 0;
    for (cases, 0..) |c, i| {
        const got = (try compiledVerdict(&engine, 100 + i, c.expr, &row)) orelse continue;
        compiled += 1;
        if (got != c.want) {
            std.debug.print("[compiled] \"{s}\": {}, expected {}\n", .{ c.expr, got, c.want });
            wrong += 1;
        }
    }
    // Not vacuous: the engine compiled the cases it can express.
    try testing.expect(compiled >= 8);
    try testing.expectEqual(@as(usize, 0), wrong);
}
