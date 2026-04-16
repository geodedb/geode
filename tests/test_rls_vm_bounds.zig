// CANARY: REQ=REQ-GAP-0723-RLS-VM-BOUNDS; FEATURE="RLSBytecodeVMBounds"; ASPECT=MemorySafety; STATUS=TESTED; TEST=tests/test_rls_vm_bounds.zig; OWNER=security; UPDATED=2026-04-16
//
// Regression tests for GAP-0723 / SEC-RLS-01.
//
// The bytecode VM in src/security/rls_core.zig used a fixed-size 64-slot
// stack with no bounds checks.  A crafted policy that issued 65+ consecutive
// push opcodes would write past stack[63], corrupting whatever sat next to
// `stack` on the VM's frame.  @enumFromInt on an arbitrary u8 was also UB in
// release, giving a second path to hijacked control flow.
//
// These tests walk the production entry point (checkRowAccessByUsername,
// the wire exercised by match_operations.passesRLSExprFilter) and confirm
// that:
//
//   1. 65 consecutive `push_true` opcodes surface as `error.StackOverflow`
//      (plus cache the deny).
//   2. A lone `pop` on an empty stack surfaces as `error.StackUnderflow`.
//   3. A bytecode byte that isn't a legal opcode surfaces as
//      `error.InvalidOpcode`.
//   4. Truncated bytecode (a `push_const` without its immediate byte) is
//      caught via `error.BytecodeUnderrun` rather than reading past the
//      bytecode slice.
//
// NOTE: checkRowAccessByUsername calls evaluateExpressionWithUsername,
// which propagates VM errors.  The caller in match_operations.zig has a
// `catch false` so the user-visible behaviour is deny.  These tests exercise
// the lower-level function directly so we can assert on the exact error set.

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
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Build a Policy wrapping the given compiled bytecode so we can invoke the
/// real production path (createPolicy → checkRowAccessByUsername).  The
/// test's caller owns the bytecode/jump_table/constants slices.
fn makePolicy(
    compiled: *CompiledExpression,
    graph: []const u8,
    table: []const u8,
) Policy {
    return .{
        .id = 1,
        .name = "test_policy",
        .description = "GAP-0723 regression harness",
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

test "GAP-0723: 65 push_true opcodes surface as StackOverflow" {
    const allocator = testing.allocator;
    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();

    // 65 consecutive push_true (0x02) overflows the 64-slot stack.  The old
    // VM would write stack[64] silently; the new VM must return
    // error.StackOverflow.
    var bytecode: [65]u8 = undefined;
    for (0..65) |i| bytecode[i] = 0x02;

    const constants = [_]Value{};
    const jump_table = [_]usize{};
    var compiled = CompiledExpression{
        .bytecode = &bytecode,
        .constants = &constants,
        .jump_table = &jump_table,
    };

    const policy = makePolicy(&compiled, "g_overflow", "t_overflow");
    try engine.createPolicy(policy);

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();

    // Use a unique username so the per-call cache misses and the VM actually
    // re-executes the bytecode.
    const res = engine.checkRowAccessByUsername(&row, .select, "overflow_probe", "g_overflow", "t_overflow");
    try testing.expectError(error.StackOverflow, res);
}

test "GAP-0723: lone pop on empty stack surfaces as StackUnderflow" {
    const allocator = testing.allocator;
    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();

    // pop (0x05) on an empty stack.  Old VM silently masked this with
    // `if (sp > 0) sp -= 1`; new VM must return error.StackUnderflow.
    const bytecode = [_]u8{0x05};
    const constants = [_]Value{};
    const jump_table = [_]usize{};
    var compiled = CompiledExpression{
        .bytecode = &bytecode,
        .constants = &constants,
        .jump_table = &jump_table,
    };

    const policy = makePolicy(&compiled, "g_under", "t_under");
    try engine.createPolicy(policy);

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();

    const res = engine.checkRowAccessByUsername(&row, .select, "underflow_probe", "g_under", "t_under");
    try testing.expectError(error.StackUnderflow, res);
}

test "GAP-0723: unknown opcode byte surfaces as InvalidOpcode" {
    const allocator = testing.allocator;
    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();

    // 0xAA is not a legal opcode.  Old VM did `@enumFromInt` and entered
    // UB-land; new VM must return error.InvalidOpcode.
    const bytecode = [_]u8{0xAA};
    const constants = [_]Value{};
    const jump_table = [_]usize{};
    var compiled = CompiledExpression{
        .bytecode = &bytecode,
        .constants = &constants,
        .jump_table = &jump_table,
    };

    const policy = makePolicy(&compiled, "g_invalid", "t_invalid");
    try engine.createPolicy(policy);

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();

    const res = engine.checkRowAccessByUsername(&row, .select, "invalid_probe", "g_invalid", "t_invalid");
    try testing.expectError(error.InvalidOpcode, res);
}

test "GAP-0723: truncated bytecode surfaces as BytecodeUnderrun" {
    const allocator = testing.allocator;
    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();

    // push_const (0x01) normally consumes the next byte as the constant
    // index.  Truncate so only the opcode byte is present — old VM indexed
    // past the slice (memory unsafety); new VM must return
    // error.BytecodeUnderrun.
    const bytecode = [_]u8{0x01};
    const constants = [_]Value{.{ .boolean = true }};
    const jump_table = [_]usize{};
    var compiled = CompiledExpression{
        .bytecode = &bytecode,
        .constants = &constants,
        .jump_table = &jump_table,
    };

    const policy = makePolicy(&compiled, "g_trunc", "t_trunc");
    try engine.createPolicy(policy);

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();

    const res = engine.checkRowAccessByUsername(&row, .select, "trunc_probe", "g_trunc", "t_trunc");
    try testing.expectError(error.BytecodeUnderrun, res);
}

test "GAP-0723: well-formed 64-depth program still works" {
    // Proof that the bound is EXACTLY at 65, not earlier — a 64-push
    // program followed by ret is still accepted and evaluates to true.
    const allocator = testing.allocator;
    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();

    var bytecode: [65]u8 = undefined;
    for (0..64) |i| bytecode[i] = 0x02; // 64 push_true
    bytecode[64] = 0xFF; // ret (returns top of stack = true)

    const constants = [_]Value{};
    const jump_table = [_]usize{};
    var compiled = CompiledExpression{
        .bytecode = &bytecode,
        .constants = &constants,
        .jump_table = &jump_table,
    };

    const policy = makePolicy(&compiled, "g_ok", "t_ok");
    try engine.createPolicy(policy);

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();

    const allowed = try engine.checkRowAccessByUsername(&row, .select, "ok_probe", "g_ok", "t_ok");
    try testing.expect(allowed);
}

test "GAP-0723: Opcode.fromByte returns null on unknown byte" {
    // Direct test of the helper, so a regression that accidentally widens
    // the lookup table (e.g. `else => .nop`) fails here too.
    try testing.expect(CompiledExpression.Opcode.fromByte(0xAA) == null);
    try testing.expect(CompiledExpression.Opcode.fromByte(0x06) == null); // gap in ops
    try testing.expect(CompiledExpression.Opcode.fromByte(0x13) == null); // gap in ops
    // Positive cases: a few spot-checks of real opcodes.
    try testing.expect(CompiledExpression.Opcode.fromByte(0x00) == .nop);
    try testing.expect(CompiledExpression.Opcode.fromByte(0x02) == .push_true);
    try testing.expect(CompiledExpression.Opcode.fromByte(0x41) == .jump_if_false);
    try testing.expect(CompiledExpression.Opcode.fromByte(0xFF) == .ret);
}
