//! GAP-0535: ExecutionResult value-memory ownership.
//!
//! Before this fix, bare-RETURN projection results were built with
//! `owns_value_memory = false`, so `ExecutionResult.deinit` never freed row
//! values. Allocated values (e.g. the fresh buffer `UPPER('x')` returns)
//! leaked under any strict allocator — the server only stayed leak-free
//! because it executes under a per-request arena (GAP-0755), and the
//! GAP-0868 test had to hide the same leak behind an arena.
//!
//! After the fix, `executeReturnClauseWithEnv` produces rows the result fully
//! OWNS (provably-allocating calls are adopted; everything else — string
//! literals borrowed from the AST, env/param values, store-derived values —
//! is deep-duplicated) and sets `owns_value_memory = true`. The UNION /
//! INTERSECT / EXCEPT combiners were taught to deep-copy values out of owned
//! part results (previously a shallow copy that would have dangled) and to
//! free the values of dropped rows.
//!
//! Every test runs std.testing.allocator end-to-end (parse →
//! executeStatementWithContext → deinit); the zig test runner fails on any
//! leak, which is the regression assertion.
//!
// CANARY: REQ=REQ-EXEC-RESULT-OWNERSHIP-001; FEATURE="ExecutionResultOwnership"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0535_result_ownership.zig; OWNER=execution; UPDATED=2026-06-11
const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const Value = geode.value_types.Value;

/// Parse + execute a single statement through the full execution path — the
/// same entry the QUIC/gRPC servers use (`executeStatementWithContext`).
/// Identical harness shape to tests/test_gap0866_ts_scalar_eval.zig.
fn runQuery(allocator: std.mem.Allocator, query: []const u8) !execution.ExecutionResult {
    var parsed = try geode.parseGql(query, allocator);
    defer parsed.deinit();

    const catalog = try execution.ensureCatalogInstance(allocator);
    defer execution.cleanupCatalogInstance();
    defer geode.graph_store.deinitGlobalStore();

    const ctx = execution.ExecutionContext{ .catalog = catalog };
    return execution.executeStatementWithContext(allocator, parsed.program.statements[0], ctx);
}

fn expectStrCell(result: execution.ExecutionResult, row: usize, col: usize, expected: []const u8) !void {
    try testing.expect(result.rows.len > row);
    try testing.expect(result.rows[row].len > col);
    try testing.expect(result.rows[row][col] == .Str);
    try testing.expectEqualStrings(expected, result.rows[row][col].Str);
}

test "GAP-0535: RETURN UPPER('x') is leak-free under a strict allocator" {
    var result = try runQuery(testing.allocator, "RETURN UPPER('x') AS u");
    defer result.deinit(testing.allocator);

    try testing.expect(result.owns_value_memory);
    try testing.expectEqual(@as(usize, 1), result.rows.len);
    try expectStrCell(result, 0, 0, "X");
}

test "GAP-0535: string literal projection is duplicated, not borrowed from the AST" {
    // The AST (and its 'lit' string) is freed inside runQuery before the
    // result is inspected — only an owned duplicate survives that.
    var result = try runQuery(testing.allocator, "RETURN 'lit' AS l");
    defer result.deinit(testing.allocator);

    try testing.expect(result.owns_value_memory);
    try expectStrCell(result, 0, 0, "lit");
}

test "GAP-0535: mixed row (owned call result, duplicated literal, scalar)" {
    var result = try runQuery(testing.allocator, "RETURN UPPER('a') AS u, 'lit' AS l, 1 AS n");
    defer result.deinit(testing.allocator);

    try testing.expect(result.owns_value_memory);
    try testing.expectEqual(@as(usize, 3), result.columns.len);
    try expectStrCell(result, 0, 0, "A");
    try expectStrCell(result, 0, 1, "lit");
    try testing.expect(result.rows[0][2] == .Int);
    try testing.expectEqual(@as(i64, 1), result.rows[0][2].Int);
}

test "GAP-0535: lower()/tolower() projection is adopted as owned" {
    var result = try runQuery(testing.allocator, "RETURN LOWER('ABC') AS l");
    defer result.deinit(testing.allocator);

    try testing.expect(result.owns_value_memory);
    try expectStrCell(result, 0, 0, "abc");
}

test "GAP-0535: UNION ALL of owned arms deep-copies part values (no dangle, no leak)" {
    var result = try runQuery(
        testing.allocator,
        "RETURN UPPER('a') AS x UNION ALL RETURN UPPER('b') AS x",
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.rows.len);
    try expectStrCell(result, 0, 0, "A");
    try expectStrCell(result, 1, 0, "B");
}

test "GAP-0535: UNION DISTINCT frees the dropped duplicate's owned values" {
    var result = try runQuery(
        testing.allocator,
        "RETURN UPPER('a') AS x UNION RETURN UPPER('a') AS x",
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.rows.len);
    try expectStrCell(result, 0, 0, "A");
}

// NOTE: standalone `A INTERSECT B` / `A EXCEPT B` statements are NOT wired
// into executeStatementWithContext (pre-existing `error.NotImplemented`,
// independent of GAP-0535) — the executable surface is the parenthesized
// union-tail form (`(A UNION B) EXCEPT C`, REQ-GQL-085), which is what these
// tests drive through executeUnionWithContext's intersect/except arms.

test "GAP-0535: EXCEPT (union-tail) drops owned rows without leaking them" {
    var result = try runQuery(
        testing.allocator,
        "(RETURN UPPER('a') AS x UNION ALL RETURN UPPER('b') AS x) EXCEPT RETURN UPPER('b') AS x",
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.rows.len);
    try expectStrCell(result, 0, 0, "A");
}

test "GAP-0535: INTERSECT (union-tail) keeps matching owned rows leak-free" {
    var result = try runQuery(
        testing.allocator,
        "(RETURN UPPER('a') AS x UNION ALL RETURN UPPER('b') AS x) INTERSECT RETURN UPPER('a') AS x",
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.rows.len);
    try expectStrCell(result, 0, 0, "A");
}

// ---------------------------------------------------------------------------
// GAP-0535 review follow-up: the ALL-variant combiners (INTERSECT ALL /
// EXCEPT ALL) re-scan the original rows array for occurrence counting on
// every iteration. The original fix freed dropped-row values MID-LOOP, so
// later scans read freed memory — silent under std.testing.allocator (freed
// bytes are poisoned to 0xaa, which never compares equal), but a recycling
// allocator can rewrite those bytes and corrupt the occurrence counts.
// The tests below assert correct RESULT VALUES on the ALL-variant repros,
// and the PoisonAllocator test makes the read-after-free deterministically
// observable: freed bytes are rewritten to 'A' (kept alive in quarantine),
// so a mid-loop free of the dropped "B" row inflates `count_in_result` for
// the later "A" rows and EXCEPT ALL keeps one row too many.
// ---------------------------------------------------------------------------

test "GAP-0535 review: INTERSECT ALL (union-tail) keeps min-occurrence count with correct values" {
    // left = [A, A, B], right = [A] → INTERSECT ALL keeps min(2,1) = 1 "A".
    var result = try runQuery(
        testing.allocator,
        "(RETURN UPPER('a') AS x UNION ALL RETURN UPPER('a') AS x UNION ALL RETURN UPPER('b') AS x) INTERSECT ALL RETURN UPPER('a') AS x",
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.rows.len);
    try expectStrCell(result, 0, 0, "A");
}

test "GAP-0535 review: EXCEPT ALL (union-tail) removes one occurrence with correct values" {
    // left = [A, A, B], right = [A] → EXCEPT ALL keeps [A, B] (2-1 A's, 1-0 B's).
    var result = try runQuery(
        testing.allocator,
        "(RETURN UPPER('a') AS x UNION ALL RETURN UPPER('a') AS x UNION ALL RETURN UPPER('b') AS x) EXCEPT ALL RETURN UPPER('a') AS x",
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.rows.len);
    try expectStrCell(result, 0, 0, "A");
    try expectStrCell(result, 1, 0, "B");
}

const QuarantineEntry = struct {
    memory: []u8,
    alignment: std.mem.Alignment,
};

/// Read-after-free detector: freed memory is NOT returned to the parent
/// allocator until `deinit`; instead its bytes are overwritten with 'A' and
/// the allocation is quarantined. Any later read of freed value bytes (the
/// mid-loop dropped-row free bug) deterministically sees "A" instead of the
/// 0xaa poison the testing allocator would apply — turning the silent UAF
/// read into an observable wrong-results failure (a freed "B" row counts as
/// an extra "A" occurrence in the EXCEPT ALL re-scan).
const PoisonAllocator = struct {
    parent: std.mem.Allocator,
    quarantine: std.ArrayList(QuarantineEntry) = .empty,

    fn allocator(self: *PoisonAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn deinit(self: *PoisonAllocator) void {
        for (self.quarantine.items) |entry| {
            self.parent.rawFree(entry.memory, entry.alignment, @returnAddress());
        }
        self.quarantine.deinit(self.parent);
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawAlloc(len, alignment, ret_addr);
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = ret_addr;
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        @memset(memory, 'A');
        self.quarantine.append(self.parent, .{ .memory = memory, .alignment = alignment }) catch {
            // Bookkeeping OOM: fall back to a real free (loses the poison for
            // this one allocation; the test stays sound).
            self.parent.rawFree(memory, alignment, @returnAddress());
        };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };
};

test "GAP-0535 review: EXCEPT ALL occurrence re-scan must not read freed dropped-row values" {
    // left = [B, A, A], right = [A, B] → EXCEPT ALL keeps exactly one "A".
    // Pre-fix, the dropped "B" row (excluded by the right side) was freed on
    // iteration 0; the quarantining allocator rewrites its bytes to "A", so
    // the `count_in_result` re-scan on iterations 1-2 counted THREE "A"
    // occurrences instead of two and the combiner kept [A, A] — wrong.
    //
    // The multi-row right arm needs UNWIND, whose evaluated list intermediate
    // is a documented GAP-0535 residual leak (non-whitelisted allocating
    // expression; absorbed by the per-request arena, GAP-0755, in
    // production). Parent on an arena — exactly the production posture — so
    // this test asserts VALUE CORRECTNESS (the UAF symptom) without
    // re-asserting the leak-freedom that residual already excludes. The
    // poison wrapper still rewrites freed bytes, so the UAF stays observable.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var poison = PoisonAllocator{ .parent = arena.allocator() };
    defer poison.deinit();
    const alloc = poison.allocator();

    var result = try runQuery(
        alloc,
        "(RETURN UPPER('b') AS x UNION ALL RETURN UPPER('a') AS x UNION ALL RETURN UPPER('a') AS x) EXCEPT ALL UNWIND ['A', 'B'] AS v RETURN v AS x",
    );
    defer result.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), result.rows.len);
    try expectStrCell(result, 0, 0, "A");
}
