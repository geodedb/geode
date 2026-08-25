// RED reproduction tests — ENG-3910: the IN / NOT IN predicate FAILS OPEN when
// its right-hand side is not a LIST.
//
// THE BUG (triage complete; file:line verified against v0.8.5 / 5c37d58a):
//
//   src/eval.zig:1142  .InListExpr    -> `if (list_val != .List) return Value{ .Bool = false };`
//   src/eval.zig:1155  .NotInListExpr -> `if (list_val != .List) return Value{ .Bool = true  };`
//
// A caller who binds a scalar where a list belongs (the classic
// `--param s '"a string"'` typo, or a parameter that a client library
// serialised as a scalar) gets a SILENT wrong answer, and the two spellings
// disagree in the most dangerous possible direction:
//
//   WHERE d.x IN $scalar      -> matches NOTHING  (looks like "no results")
//   WHERE NOT d.x IN $scalar  -> matches EVERYTHING
//
// Live probe on a real server (v0.8.5, two :C3910 nodes with x = 1 and x = 2):
//
//   --param s '"a string"'  WHERE d.x IN $s      -> 00000, 0 rows
//   --param s '"a string"'  WHERE NOT d.x IN $s  -> 00000, 2 rows   <-- fail-open
//   --param n '7'           WHERE d.x IN $n      -> 00000, 0 rows
//   RETURN 1 IN 'abc'                            -> 00000, false
//
// If that predicate is load-bearing for an allow/deny decision (`WHERE NOT
// u.role IN $blocked`), the typo silently converts a deny-list into an
// allow-all. That is the reason this is a fail-open and not a cosmetic bug.
//
// NULL is a separate, equally wrong case. ISO/IEC 39075 three-valued logic says
// `x IN NULL` is UNKNOWN, not FALSE, and `x NOT IN NULL` is UNKNOWN, not TRUE.
// Today both collapse to a definite boolean via the same two lines. Live probe:
//
//   RETURN 1 IN null                             -> 00000, false   (want: null)
//   --param z 'null'  WHERE NOT d.x IN $z        -> 00000, 2 rows  (want: 0 rows)
//
// INTENDED FIX CONTRACT (what these tests pin; NOT the implementation):
//
//   1. A non-NULL, non-LIST right-hand side is a TYPE ERROR. `evalExpr` returns
//      an error rather than a Value; the error maps to a data-exception
//      (22xxx) SQLSTATE on the wire. The exact error name is left to the fixer
//      — these tests assert only that an error is raised, and the harness spec
//      (geode-test-harness/geodetestlab-cli/specs/in_predicate_type_safety.yml)
//      pins the SQLSTATE class.
//   2. A NULL right-hand side yields NULL (UNKNOWN) for both IN and NOT IN.
//   3. A genuine LIST right-hand side keeps its exact current semantics —
//      membership for IN, non-membership for NOT IN, including the empty list.
//      This is the guard against "fix it by erroring on everything".
//
// RED MECHANISM: `eval.evalExpr` is public and the AST nodes are plain structs,
// so the two faulty lines are driven directly with hand-built expressions — no
// server, no store, no mocks, and no way for an unrelated layer to mask the
// result. Cases 1 and 2 fail today (a Bool comes back where an error / Null is
// required); case 3 passes today and must keep passing.
//
// CANARY: REQ=REQ-ENG-3910-IN-PREDICATE-TYPE-SAFETY; FEATURE="InOperator"; ASPECT=NonListRightHandSide; STATUS=TESTED; TEST=tests/test_eng3910_in_type_safety.zig; OWNER=eval; UPDATED=2026-08-24

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const ast = geode.ast;
const eval = geode.eval;
const Value = eval.Value;
const Env = eval.Env;

fn emptyEnv(allocator: std.mem.Allocator) Env {
    return .{ .names = &.{}, .values = &.{}, .allocator = allocator };
}

fn inExpr(lhs: *ast.Expr, rhs: *ast.Expr) ast.Expr {
    return ast.Expr{ .InListExpr = .{ .value = lhs, .list_expr = rhs } };
}

fn notInExpr(lhs: *ast.Expr, rhs: *ast.Expr) ast.Expr {
    return ast.Expr{ .NotInListExpr = .{ .value = lhs, .list_expr = rhs } };
}

/// Assert the predicate raises a type error instead of quietly returning a
/// boolean. Prints the fail-open value it actually produced so the RED output
/// names the defect rather than just "expected error".
fn expectTypeError(allocator: std.mem.Allocator, e: ast.Expr, env: Env, label: []const u8) !void {
    if (eval.evalExpr(allocator, e, env)) |v| {
        std.debug.print(
            "\n[ENG-3910] {s}: expected a type error, got {s} (fail-open)\n",
            .{ label, @tagName(v) },
        );
        switch (v) {
            .Bool => |b| std.debug.print("           value = {}\n", .{b}),
            else => {},
        }
        return error.InPredicateFailedOpenInsteadOfTypeError;
    } else |_| {}
}

test "ENG-3910: IN with a non-LIST right-hand side is a type error, not false" {
    // Arena: evalExpr allocates the materialised list for a list-valued RHS and
    // the caller owns it; an arena keeps the tests leak-free without teaching
    // them the ownership rules of a value they are only inspecting.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = emptyEnv(a);

    var lhs = ast.Expr{ .Int = 1 };

    // KEY ASSERTION (RED): string RHS. Today: Bool=false.
    var rhs_str = ast.Expr{ .String = "abc" };
    try expectTypeError(a, inExpr(&lhs, &rhs_str), env, "1 IN 'abc'");

    // KEY ASSERTION (RED): integer RHS. Today: Bool=false.
    var rhs_int = ast.Expr{ .Int = 7 };
    try expectTypeError(a, inExpr(&lhs, &rhs_int), env, "1 IN 7");

    // KEY ASSERTION (RED): boolean RHS. Today: Bool=false.
    var rhs_bool = ast.Expr{ .Bool = true };
    try expectTypeError(a, inExpr(&lhs, &rhs_bool), env, "1 IN true");
}

test "ENG-3910: NOT IN with a non-LIST right-hand side is a type error, not true" {
    // Arena: evalExpr allocates the materialised list for a list-valued RHS and
    // the caller owns it; an arena keeps the tests leak-free without teaching
    // them the ownership rules of a value they are only inspecting.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = emptyEnv(a);

    var lhs = ast.Expr{ .Int = 1 };

    // KEY ASSERTIONS (RED) — this is the dangerous direction: today every one
    // of these returns Bool=true, so a deny-list predicate admits every row.
    var rhs_str = ast.Expr{ .String = "abc" };
    try expectTypeError(a, notInExpr(&lhs, &rhs_str), env, "1 NOT IN 'abc'");

    var rhs_int = ast.Expr{ .Int = 7 };
    try expectTypeError(a, notInExpr(&lhs, &rhs_int), env, "1 NOT IN 7");

    var rhs_bool = ast.Expr{ .Bool = true };
    try expectTypeError(a, notInExpr(&lhs, &rhs_bool), env, "1 NOT IN true");
}

test "ENG-3910: a NULL right-hand side yields NULL (three-valued logic), not a definite boolean" {
    // Arena: evalExpr allocates the materialised list for a list-valued RHS and
    // the caller owns it; an arena keeps the tests leak-free without teaching
    // them the ownership rules of a value they are only inspecting.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = emptyEnv(a);

    var lhs = ast.Expr{ .Int = 1 };
    var rhs_null = ast.Expr{ .Null = {} };

    // KEY ASSERTION (RED): today this is Bool=false.
    const in_res = try eval.evalExpr(a, inExpr(&lhs, &rhs_null), env);
    if (in_res != .Null) {
        std.debug.print(
            "\n[ENG-3910] 1 IN NULL: expected Null (UNKNOWN), got {s}\n",
            .{@tagName(in_res)},
        );
        return error.InNullRightHandSideNotUnknown;
    }

    // KEY ASSERTION (RED): today this is Bool=true — the fail-open shape again.
    const not_in_res = try eval.evalExpr(a, notInExpr(&lhs, &rhs_null), env);
    if (not_in_res != .Null) {
        std.debug.print(
            "\n[ENG-3910] 1 NOT IN NULL: expected Null (UNKNOWN), got {s}\n",
            .{@tagName(not_in_res)},
        );
        return error.NotInNullRightHandSideNotUnknown;
    }
}

test "ENG-3910 (guard): a genuine LIST right-hand side keeps its exact semantics" {
    // Arena: evalExpr allocates the materialised list for a list-valued RHS and
    // the caller owns it; an arena keeps the tests leak-free without teaching
    // them the ownership rules of a value they are only inspecting.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = emptyEnv(a);

    var lhs = ast.Expr{ .Int = 2 };

    var one = ast.Expr{ .Int = 1 };
    var two = ast.Expr{ .Int = 2 };
    var three = ast.Expr{ .Int = 3 };

    // `[1, 2, 3]` parses to ast.Expr.ArrayLit — that is the node evalExpr
    // actually turns into a Value.List (src/eval.zig:1377).
    var members = [_]*ast.Expr{ &one, &two, &three };
    var rhs_list = ast.Expr{ .ArrayLit = members[0..] };

    // Present in the list.
    try testing.expectEqual(
        Value{ .Bool = true },
        try eval.evalExpr(a, inExpr(&lhs, &rhs_list), env),
    );
    try testing.expectEqual(
        Value{ .Bool = false },
        try eval.evalExpr(a, notInExpr(&lhs, &rhs_list), env),
    );

    // Absent from the list.
    var missing = ast.Expr{ .Int = 9 };
    try testing.expectEqual(
        Value{ .Bool = false },
        try eval.evalExpr(a, inExpr(&missing, &rhs_list), env),
    );
    try testing.expectEqual(
        Value{ .Bool = true },
        try eval.evalExpr(a, notInExpr(&missing, &rhs_list), env),
    );

    // The empty list is a LIST, not a type error: nothing is in it, everything
    // is not in it.
    var empty_members = [_]*ast.Expr{};
    var rhs_empty = ast.Expr{ .ArrayLit = empty_members[0..] };
    try testing.expectEqual(
        Value{ .Bool = false },
        try eval.evalExpr(a, inExpr(&lhs, &rhs_empty), env),
    );
    try testing.expectEqual(
        Value{ .Bool = true },
        try eval.evalExpr(a, notInExpr(&lhs, &rhs_empty), env),
    );
}
