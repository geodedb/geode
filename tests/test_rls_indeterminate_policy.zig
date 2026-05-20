// CANARY: REQ=REQ-GPS-PDP-006; FEATURE="GPS Decision Engine"; ASPECT=RLSIndeterminatePolicy; STATUS=TESTED; TEST=tests/test_rls_indeterminate_policy.zig; OWNER=security; UPDATED=2026-05-20
//
// Regression test for GPS Phase 2 task 2-8: RLS VM no-result returns
// error.IndeterminatePolicy instead of `return true` (fail-open).
//
// Prior to this fix (task 2-8), `evaluateCompiledExpressionWithUsername`
// returned `true` (allow) when the bytecode program ran to completion
// without leaving any value on the stack and without executing a `ret`
// instruction.  This was fail-open Site #4 in the GPS Fail-Open Catalog.
//
// After the fix, the same code path returns `error.IndeterminatePolicy`.
// `checkRowAccessByUsername` propagates that error, and the match loop's
// `catch false` in `passesRLSExprFilter` (match_operations.zig) converts
// it to a user-visible deny — making the path fail-closed.
//
// How we provoke the no-result path:
//
//   The simplest program that exhausts all opcodes without leaving a result
//   is a `.nop` (opcode 0x00) sequence.  A lone `.nop` executes to EOF with
//   sp == 0 — the exact condition triggering the default-allow path before
//   this fix and `error.IndeterminatePolicy` after.
//
// NOTE: checkRowAccessByUsername propagates VM errors (it does NOT catch
// them internally).  The match loop caller has a `catch false`, but this
// test exercises the lower-level call directly to assert the exact error tag.

const std = @import("std");
const testing = std.testing;
const rls = @import("rls");

const RLSEngine = rls.RLSEngine;
const Value = rls.Value;
const Policy = rls.RLSEngine.Policy;
const Expression = rls.RLSEngine.Expression;
const CompiledExpression = rls.RLSEngine.CompiledExpression;

fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Build a Policy wrapping the given compiled bytecode so we can invoke the
/// real production path (createPolicy → checkRowAccessByUsername).  The
/// caller owns the bytecode/jump_table/constants slices.
fn makePolicy(
    compiled: *CompiledExpression,
    graph: []const u8,
    table: []const u8,
) Policy {
    return .{
        .id = 200,
        .name = "indeterminate_test_policy",
        .description = "GPS Phase 2 task 2-8: no-result VM path must be error.IndeterminatePolicy",
        .graph = graph,
        .table = table,
        .operation = .all,
        .permissive = false,
        .roles = &.{},
        .using_expr = Expression{
            .raw = "",
            .parsed = null,
            .compiled = compiled,
            .parameters = &.{},
        },
        .check_expr = null,
        .enabled = true,
        .created_at = compat_milliTimestamp(),
        .updated_at = compat_milliTimestamp(),
        .created_by = 0,
        .temporal = null,
        .data_classification = null,
        .audit_level = .none,
    };
}

// CANARY: REQ=REQ-GPS-PDP-006; FEATURE="GPS Decision Engine"; ASPECT=RLSIndeterminatePolicy; STATUS=TESTED; TEST=tests/test_rls_indeterminate_policy.zig; OWNER=security; UPDATED=2026-05-20
test "GPS-2-8: empty-stack nop program surfaces as IndeterminatePolicy" {
    // A single `.nop` (0x00) opcode: executes to EOF, sp == 0, no result.
    // Before fix: returns true (allow).
    // After fix:  returns error.IndeterminatePolicy.
    const allocator = testing.allocator;
    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();

    const bytecode = [_]u8{0x00}; // nop
    const constants = [_]Value{};
    const jump_table = [_]usize{};
    var compiled = CompiledExpression{
        .bytecode = &bytecode,
        .constants = &constants,
        .jump_table = &jump_table,
    };

    const policy = makePolicy(&compiled, "g_indeterminate", "t_indeterminate");
    try engine.createPolicy(policy);

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();

    // Use a username that has never been cached so the VM actually executes.
    const res = engine.checkRowAccessByUsername(
        &row,
        .select,
        "indeterminate_probe",
        "g_indeterminate",
        "t_indeterminate",
    );
    try testing.expectError(error.IndeterminatePolicy, res);
}

// CANARY: REQ=REQ-GPS-PDP-006; FEATURE="GPS Decision Engine"; ASPECT=RLSIndeterminatePolicy; STATUS=TESTED; TEST=tests/test_rls_indeterminate_policy.zig; OWNER=security; UPDATED=2026-05-20
test "GPS-2-8: truly empty bytecode program surfaces as IndeterminatePolicy" {
    // Zero-length bytecode: the while loop body never executes, sp == 0.
    // Same no-result path, but via the EOF-without-any-opcode branch.
    const allocator = testing.allocator;
    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();

    const bytecode = [_]u8{}; // empty — falls straight through to sp == 0 check
    const constants = [_]Value{};
    const jump_table = [_]usize{};
    var compiled = CompiledExpression{
        .bytecode = &bytecode,
        .constants = &constants,
        .jump_table = &jump_table,
    };

    const policy = makePolicy(&compiled, "g_empty", "t_empty");
    try engine.createPolicy(policy);

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();

    const res = engine.checkRowAccessByUsername(
        &row,
        .select,
        "empty_probe",
        "g_empty",
        "t_empty",
    );
    try testing.expectError(error.IndeterminatePolicy, res);
}

// CANARY: REQ=REQ-GPS-PDP-006; FEATURE="GPS Decision Engine"; ASPECT=RLSIndeterminatePolicy; STATUS=TESTED; TEST=tests/test_rls_indeterminate_policy.zig; OWNER=security; UPDATED=2026-05-20
test "GPS-2-8: well-formed program still allows (regression guard)" {
    // A push_true + ret program should still return true (allow) — confirming
    // that the IndeterminatePolicy change doesn't break the normal allow path.
    const allocator = testing.allocator;
    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();

    const bytecode = [_]u8{ 0x02, 0xFF }; // push_true, ret
    const constants = [_]Value{};
    const jump_table = [_]usize{};
    var compiled = CompiledExpression{
        .bytecode = &bytecode,
        .constants = &constants,
        .jump_table = &jump_table,
    };

    const policy = makePolicy(&compiled, "g_allow", "t_allow");
    try engine.createPolicy(policy);

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();

    const allowed = try engine.checkRowAccessByUsername(
        &row,
        .select,
        "allow_probe",
        "g_allow",
        "t_allow",
    );
    try testing.expect(allowed);
}

// CANARY: REQ=REQ-GPS-PDP-006; FEATURE="GPS Decision Engine"; ASPECT=RLSIndeterminatePolicy; STATUS=TESTED; TEST=tests/test_rls_indeterminate_policy.zig; OWNER=security; UPDATED=2026-05-20
test "GPS-2-8: pop-all-and-ret program surfaces as IndeterminatePolicy via ret" {
    // push_true (0x02), pop (0x05), ret (0xFF):
    //   After pop, sp == 0; ret with empty stack falls into its own `return false`
    //   branch.  This is the .ret arm with empty stack — not the IndeterminatePolicy
    //   path — so we expect `false`, not the error.
    //   This test documents and guards the distinction between the two empty-stack
    //   paths: `.ret` with sp==0 → false; fallthrough with sp==0 → IndeterminatePolicy.
    const allocator = testing.allocator;
    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();

    const bytecode = [_]u8{ 0x02, 0x05, 0xFF }; // push_true, pop, ret
    const constants = [_]Value{};
    const jump_table = [_]usize{};
    var compiled = CompiledExpression{
        .bytecode = &bytecode,
        .constants = &constants,
        .jump_table = &jump_table,
    };

    const policy = makePolicy(&compiled, "g_ret_empty", "t_ret_empty");
    try engine.createPolicy(policy);

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();

    // `.ret` with empty stack returns `false` (deny) — not an error.
    const result = try engine.checkRowAccessByUsername(
        &row,
        .select,
        "ret_empty_probe",
        "g_ret_empty",
        "t_ret_empty",
    );
    try testing.expect(!result);
}
