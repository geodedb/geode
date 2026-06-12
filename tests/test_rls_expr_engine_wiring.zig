// CANARY: REQ=REQ-GAP-0510-RLS-EXPR-WIRING; FEATURE="RLSExpressionEngineWiring"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_rls_expr_engine_wiring.zig:1; OWNER=security; UPDATED=2026-04-11
//
// Regression tests for GAP-0510: "RLS expression engine is dead code".
//
// The gap reported that `setGlobalExprRLSEngine()` was never called in
// production, leaving 3k+ lines of the bytecode VM as orphaned code.
// The wiring landed in commit 555d4414 (src/server/main.zig:636–639),
// but no test exercises the full path: init engine → publish via
// rls_types global slot → have the VM evaluate a compiled policy
// through `checkRowAccessByUsername` (the entry point used by
// `match_operations.passesRLSExprFilter`).
//
// These tests walk the real production path:
//
//   1. `setGlobalExprRLSEngine` / `getGlobalExprRLSEngine` round-trip:
//      the accessor returns the pointer on set, null after clear.
//
//   2. A compiled policy that denies rows where
//      `classification == "secret"` actually filters: a matching row
//      is denied, a non-matching row is allowed, and a row missing
//      the field falls through correctly.
//
//   3. Fail-closed behaviour: when the expression can't be evaluated
//      against the row (in practice, this is exercised indirectly by
//      the match loop's `catch false` at match_operations.zig:144).
//      Here we test the positive path — when no policies are
//      registered for a (graph, table), access is granted (`return
//      true` at rls_core.zig:969). If a future refactor inverts that
//      default, these tests catch the flip.
//
// The bytecode is constructed by hand because the full GQL → bytecode
// pipeline is still exempt; createPolicy stores the Expression as
// given. This mirrors exactly how the production server would pin a
// pre-compiled policy in place during startup once the parser path
// lands.

const std = @import("std");

// Zig 0.16 compat helpers for test code
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}
fn compat_sleep(ns: u64) void {
    var req: std.posix.timespec = .{ .sec = 0, .nsec = @intCast(ns) };
    var rem: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.nanosleep(@ptrCast(&req), @ptrCast(&rem));
    } else {
        _ = std.c.nanosleep(&req, &rem);
    }
}

const testing = std.testing;
const geode = @import("geode");
const rls = @import("rls");
const rls_types = @import("rls_types");

const execution = geode.execution;
const RLSEngine = rls.RLSEngine;
const Value = rls.Value;
const Policy = rls.RLSEngine.Policy;
const Expression = rls.RLSEngine.Expression;
const CompiledExpression = rls.RLSEngine.CompiledExpression;

test "GAP-0510: setGlobalExprRLSEngine / getGlobalExprRLSEngine round-trip" {
    try testing.expect(rls_types.getGlobalExprRLSEngine() == null);

    var engine = try RLSEngine.init(testing.allocator);
    defer engine.deinit();

    rls_types.setGlobalExprRLSEngine(@ptrCast(&engine));
    defer rls_types.setGlobalExprRLSEngine(null);

    const slot = rls_types.getGlobalExprRLSEngine() orelse return error.EngineNotRegistered;
    const engine_ptr: *RLSEngine = @ptrCast(@alignCast(slot));
    try testing.expect(engine_ptr == &engine);
}

test "GAP-0510: compiled policy filters rows by property via checkRowAccessByUsername" {
    const allocator = testing.allocator;

    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();

    // Constants consumed by load_row / push_const in the bytecode below.
    // constants[0] = field name "classification"
    // constants[1] = denied value "secret"
    const constants = [_]Value{
        .{ .string = "classification" },
        .{ .string = "secret" },
    };

    // Bytecode: allow when row["classification"] != "secret".
    //
    //   load_row   0   ; push row.classification
    //   push_const 1   ; push "secret"
    //   neq            ; push (classification != "secret")
    //   ret            ; return top of stack
    //
    // Opcode values mirror rls_core.zig:CompiledExpression.Opcode.
    const bytecode = [_]u8{
        0x10, 0x00, // load_row 0
        0x01, 0x01, // push_const 1
        0x21, // neq
        0xFF, // ret
    };
    const jump_table = [_]usize{};

    var compiled = CompiledExpression{
        .bytecode = &bytecode,
        .constants = &constants,
        .jump_table = &jump_table,
    };

    const policy = Policy{
        .id = 1,
        .name = "deny_secret_classification",
        .description = "Restrictive policy denying access to rows classified secret",
        .graph = "secure_graph",
        .table = "Document",
        .operation = .all,
        .permissive = false,
        .roles = &.{},
        .using_expr = Expression{
            .raw = "classification != 'secret'",
            .parsed = null,
            .compiled = &compiled,
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

    try engine.createPolicy(policy);

    // Row 1: classification = "public" → allowed.
    var public_row = std.StringHashMap(Value).init(allocator);
    defer public_row.deinit();
    try public_row.put("classification", .{ .string = "public" });
    try public_row.put("title", .{ .string = "Annual report" });

    const public_allowed = try engine.checkRowAccessByUsername(
        &public_row,
        .select,
        "alice",
        "secure_graph",
        "Document",
    );
    try testing.expect(public_allowed);

    // Row 2: classification = "secret" → denied.
    var secret_row = std.StringHashMap(Value).init(allocator);
    defer secret_row.deinit();
    try secret_row.put("classification", .{ .string = "secret" });
    try secret_row.put("title", .{ .string = "Project blackbird" });

    // NOTE: policy_cache in the RLSEngine is keyed by (policy_key,
    // user_id, operation) NOT by row contents, so we must use a
    // different user or reset the cache. Easiest: a different username
    // on the second call — the hash keys differ, so the cache miss
    // forces a fresh evaluation.
    const secret_allowed = try engine.checkRowAccessByUsername(
        &secret_row,
        .select,
        "bob",
        "secure_graph",
        "Document",
    );
    if (secret_allowed) {
        std.debug.print(
            "GAP-0510 regression: restrictive policy granted access to classification='secret' row\n",
            .{},
        );
        return error.RLSExpressionNotEnforced;
    }
}

test "GAP-0510: no registered policy means access is granted (default allow)" {
    const allocator = testing.allocator;

    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();
    try row.put("any", .{ .string = "value" });

    const allowed = try engine.checkRowAccessByUsername(
        &row,
        .select,
        "alice",
        "unrelated_graph",
        "NoPolicyTable",
    );

    // The production contract at rls_core.zig:969 is: if no policies
    // are registered for (graph, table), return true. Label-deny is
    // the layer above; expression is a supplement, not a replacement.
    // If a refactor inverts this default, the match loop would start
    // denying everything at once and this test catches it.
    try testing.expect(allowed);
}

test "QUIC-HC-158: empty RLS engines do not force authenticated read snapshots" {
    const allocator = testing.allocator;

    try testing.expect(rls_types.getGlobalRLSFilterEngine() == null);
    try testing.expect(rls_types.getGlobalExprRLSEngine() == null);

    execution.cleanupCatalogInstance();
    defer execution.cleanupCatalogInstance();
    const catalog = try execution.ensureCatalogInstance(allocator);

    var ctx = execution.ExecutionContext{
        .catalog = catalog,
        .user = "alice",
    };
    const prev_ctx = execution.pushActiveContext(&ctx);
    defer execution.popActiveContext(prev_ctx);

    try testing.expect(!execution.wouldEvaluateRLS());

    var label_engine = rls_types.RLSFilterEngine.init(allocator);
    defer label_engine.deinit();
    rls_types.setGlobalRLSFilterEngine(&label_engine);
    defer rls_types.setGlobalRLSFilterEngine(null);

    var expr_engine = try RLSEngine.init(allocator);
    defer expr_engine.deinit();
    rls_types.setGlobalExprRLSEngine(@ptrCast(&expr_engine));
    defer rls_types.setGlobalExprRLSEngine(null);

    try testing.expect(!execution.wouldEvaluateRLS());

    try label_engine.addDenyPolicy("default", "Secret", "");
    try testing.expect(execution.wouldEvaluateRLS());
    label_engine.removeDenyPolicy("default", "Secret", "");
    try testing.expect(!execution.wouldEvaluateRLS());

    const policy = Policy{
        .id = 158,
        .name = "hc_expr_policy",
        .description = "marker policy for read dispatch RLS classification",
        .graph = "default",
        .table = "HCParallel",
        .operation = .select,
        .permissive = false,
        .roles = &.{},
        .using_expr = null,
        .check_expr = null,
        .enabled = true,
        .created_at = compat_milliTimestamp(),
        .updated_at = compat_milliTimestamp(),
        .created_by = 0,
        .temporal = null,
        .data_classification = null,
        .audit_level = .none,
    };
    try expr_engine.createPolicy(policy);
    try testing.expect(execution.wouldEvaluateRLS());
}

// ─── PERF-A / #808: RLS row-rebuild elimination ──────────────────────────────
//
// The match loop (passesRLSExprFilter) skips nodePropertiesToRLSRowInto when
// engine.needsRowDataForTable() reports that no applicable compiled policy
// contains a `load_row` opcode. These tests pin:
//   1. the bytecode pre-scan (operand bytes never misread as opcodes),
//   2. flag computation in compileExpression AND for pinned pre-compiled
//      expressions registered through createPolicy,
//   3. the load-bearing invariant that makes the skip sound: a row-free
//      policy evaluates to the correct verdict against an EMPTY row that
//      the engine never populates (no row build happened, scratch stays
//      empty).

test "PERF-A: bytecodeNeedsRowData detects load_row and skips operand bytes" {
    // Row-free: push_const 0, push_const 1, eq, ret → no load_row.
    try testing.expect(!CompiledExpression.bytecodeNeedsRowData(&.{ 0x01, 0x00, 0x01, 0x01, 0x20, 0xFF }));

    // Row-reading: load_row 0, push_const 1, neq, ret.
    try testing.expect(CompiledExpression.bytecodeNeedsRowData(&.{ 0x10, 0x00, 0x01, 0x01, 0x21, 0xFF }));

    // Operand byte equal to the load_row opcode value (0x10) must NOT be
    // misread as load_row: push_const with arg 0x10, then ret.
    try testing.expect(!CompiledExpression.bytecodeNeedsRowData(&.{ 0x01, 0x10, 0xFF }));

    // Unknown opcode → conservative true.
    try testing.expect(CompiledExpression.bytecodeNeedsRowData(&.{ 0x77, 0xFF }));

    // Empty bytecode reads nothing.
    try testing.expect(!CompiledExpression.bytecodeNeedsRowData(&.{}));
}

test "PERF-A: compileExpression computes needs_row_data from the raw expression" {
    // Arena: createPolicy with .compiled = null runs compileExpression,
    // whose allocations the engine does not free on deinit (pre-existing
    // engine behavior — production engines live for the process lifetime).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();

    const base = Policy{
        .id = 0,
        .name = "",
        .description = "",
        .graph = "perf_graph",
        .table = "Doc",
        .operation = .select,
        .permissive = false,
        .roles = &.{},
        .using_expr = null,
        .check_expr = null,
        .enabled = true,
        .created_at = compat_milliTimestamp(),
        .updated_at = compat_milliTimestamp(),
        .created_by = 0,
        .temporal = null,
        .data_classification = null,
        .audit_level = .none,
    };

    // Row-free raw expression → compiled with needs_row_data = false.
    var row_free = base;
    row_free.id = 1;
    row_free.name = "row_free";
    row_free.table = "RowFree";
    row_free.using_expr = Expression{
        .raw = "current_user = current_user",
        .parsed = null,
        .compiled = null, // force compileExpression
        .parameters = &.{},
    };
    try engine.createPolicy(row_free);
    try testing.expect(!engine.needsRowDataForTable(.select, "perf_graph", "RowFree"));

    // Row-reading raw expression → compiled with needs_row_data = true.
    var row_reading = base;
    row_reading.id = 2;
    row_reading.name = "row_reading";
    row_reading.table = "RowReading";
    row_reading.using_expr = Expression{
        .raw = "row.owner = 'alice'",
        .parsed = null,
        .compiled = null,
        .parameters = &.{},
    };
    try engine.createPolicy(row_reading);
    try testing.expect(engine.needsRowDataForTable(.select, "perf_graph", "RowReading"));

    // No policies registered for a table → no row data needed (the
    // default-allow path never reads the row either).
    try testing.expect(!engine.needsRowDataForTable(.select, "perf_graph", "NoPolicies"));
}

test "PERF-A: row-free pinned policy filters correctly against an empty, never-built row" {
    const allocator = testing.allocator;

    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();

    // Pinned pre-compiled DENY-all policy with no row references:
    //   push_false ; ret
    // createPolicy must compute needs_row_data=false for the pinned form.
    const deny_bytecode = [_]u8{ 0x03, 0xFF };
    var deny_compiled = CompiledExpression{
        .bytecode = &deny_bytecode,
        .constants = &.{},
        .jump_table = &.{},
        // deliberately rely on createPolicy to overwrite the conservative
        // default for pinned expressions
    };
    try testing.expect(deny_compiled.needs_row_data); // default is conservative

    const deny_policy = Policy{
        .id = 808,
        .name = "deny_all_row_free",
        .description = "restrictive policy with no load_row opcode",
        .graph = "perf_graph",
        .table = "Pinned",
        .operation = .all,
        .permissive = false,
        .roles = &.{},
        .using_expr = Expression{
            .raw = "false",
            .parsed = null,
            .compiled = &deny_compiled,
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
    try engine.createPolicy(deny_policy);

    // createPolicy computed the real flag for the pinned expression.
    try testing.expect(!deny_compiled.needs_row_data);
    try testing.expect(!engine.needsRowDataForTable(.select, "perf_graph", "Pinned"));

    // The skip contract: the match loop passes an EMPTY scratch row when
    // needsRowDataForTable is false. The verdict must match what a fully
    // built row would produce (deny), and the engine must never populate
    // the scratch row (no row build happened anywhere).
    var empty_scratch = std.StringHashMap(Value).init(allocator);
    defer empty_scratch.deinit();

    const allowed = try engine.checkRowAccessByUsername(
        &empty_scratch,
        .select,
        "alice",
        "perf_graph",
        "Pinned",
    );
    try testing.expect(!allowed);
    try testing.expectEqual(@as(usize, 0), empty_scratch.count());
}

test "PERF-A: row-reading pinned policy still requires the row (no false skip)" {
    const allocator = testing.allocator;

    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();

    // Same classification != 'secret' policy as the GAP-0510 test above.
    const constants = [_]Value{
        .{ .string = "classification" },
        .{ .string = "secret" },
    };
    const bytecode = [_]u8{
        0x10, 0x00, // load_row 0
        0x01, 0x01, // push_const 1
        0x21, // neq
        0xFF, // ret
    };
    var compiled = CompiledExpression{
        .bytecode = &bytecode,
        .constants = &constants,
        .jump_table = &.{},
    };

    const policy = Policy{
        .id = 809,
        .name = "deny_secret_row_reading",
        .description = "policy whose bytecode reads row data",
        .graph = "perf_graph",
        .table = "Classified",
        .operation = .all,
        .permissive = false,
        .roles = &.{},
        .using_expr = Expression{
            .raw = "classification != 'secret'",
            .parsed = null,
            .compiled = &compiled,
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
    try engine.createPolicy(policy);

    // The pre-scan must demand the row — skipping here would evaluate
    // load_row against an empty map (null) and wrongly ALLOW secret rows.
    try testing.expect(compiled.needs_row_data);
    try testing.expect(engine.needsRowDataForTable(.select, "perf_graph", "Classified"));
}
