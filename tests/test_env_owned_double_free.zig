// `Env` binding-array ownership is broken in two distinct, compounding ways.
// Together they give an unprivileged `RETURN` expression a heap DOUBLE-FREE
// plus a use-after-free, and give every covered fast-path query a permanent
// per-query leak.
//
// ---------------------------------------------------------------------------
// DEFECT A — `Env.owned = true` on an `Env` that is passed BY VALUE.
// ---------------------------------------------------------------------------
//
//   * `src/value_types.zig:269-272` — `Env.withBinding` is the ONE and ONLY
//     reader of `Env.owned`. When it is set, `withBinding` does
//     `self.allocator.free(self.names); self.allocator.free(self.values);`
//     before returning the extended copy. `self` is a BY-VALUE `Env`, so this
//     frees memory the CALLER's `Env` still points at.
//   * `src/eval.zig:1533-1556` — the list-comprehension evaluator calls
//     `env.withBinding(...)` in a LOOP over `source_list`, always on the same
//     by-value `env`. Iteration 1 frees `env.names`/`env.values`. Iteration 2
//     then `@memcpy`s OUT of that freed memory (value_types.zig:260-261 — a
//     use-after-free) and frees the SAME two pointers again
//     (value_types.zig:270-271 — a double free). Any source list with >= 2
//     elements trips it. `src/eval/quantifier_call_handlers.zig:100` has the
//     identical loop shape for quantified predicates.
//   * Two allocating sites still opt into this with no frame-level free:
//       - `src/execution/match_operations.zig:1830-1841` — `pointWriteFastPath`
//         builds `env_names`/`env_values` and sets `.owned = true`. Its shape
//         gate at :1671 rejects only AGGREGATIONS, so a list comprehension in
//         `RETURN` sails straight through to the `evalExpr` at :1844.
//       - `src/execution/match_operations.zig:3446-3460` —
//         `handleShortestPathAssignment`, same shape (`path_env_names` /
//         `path_env_values`, `.owned = true`, no free). Its `RETURN` loop at
//         :3464 has no shape gate at all.
//   * `src/execution/match_operations.zig:11046-11067` is THE REFERENCE FIX,
//     already applied to the legacy match loop: allocate, `defer` the free
//     unconditionally, and set `.owned = false` so `withBinding` copies out and
//     leaves the frame's arrays alone. Its comment spells out exactly why
//     ownership conditional on `owned` is unsound. The two sites above are the
//     un-migrated remnants.
//
//   Without a comprehension in `RETURN`, `withBinding` never runs at either
//   site, nobody frees the arrays, and EVERY such query leaks exactly 2
//   allocations — the steady-state cost of the bug even with no attacker.
//
// ---------------------------------------------------------------------------
// DEFECT B — `withBinding`'s RESULT is never freed by its caller.
// ---------------------------------------------------------------------------
//
//   Found while building this suite; NOT in the original triage, and the fix
//   for A cannot be validated without it. `withBinding` returns a brand-new
//   `Env` whose `names`/`values` are freshly allocated at value_types.zig:254
//   and :257. `eval.zig:1535` binds that to `new_env`, uses it, and drops it —
//   there is no `defer` and no free anywhere in the loop body. So every
//   comprehension leaks 2 allocations PER ELEMENT, on every code path,
//   including the already-"fixed" :11046 one. `withBinding`'s free-self-if-
//   `owned` was evidently intended to be that cleanup (chained
//   `env -> withBinding -> withBinding`), but the LOOP shape calls it on the
//   ORIGINAL env every time, so it never collects anything and corrupts the
//   heap instead.
//
//   Consequence: a fix that only flips `.owned = false` at :1834 / :3455 closes
//   the double free and the 2-alloc leak, but leaves a 2-alloc-per-element leak
//   on every comprehension in the product. Test 5 below isolates B with no
//   MATCH and no fast path involved at all.
//
// ---------------------------------------------------------------------------
// WHY THIS SUITE EXISTS
// ---------------------------------------------------------------------------
//
// Production runs on `c_allocator`, which silently tolerates both the double
// free and the leaks. The pre-existing `tests/test_point_write_fastpath.zig:136`
// drives this exact code path but on an `ArenaAllocator` — an arena's `free` is
// a no-op and its teardown sweeps leaks, so that suite is structurally blind to
// every facet of this bug. These tests are the only enforcement.
//
// ---------------------------------------------------------------------------
// THE RIG
// ---------------------------------------------------------------------------
//
// Every test drives the REAL parse -> executeStatementWithContext path against
// a REAL store. Nothing is stubbed, mocked, or simulated.
//
// The one piece of test-owned machinery is `TrackingAllocator`: a thin
// instrumentation wrapper that forwards every alloc/resize/remap/free to a real
// `DebugAllocator` and, on the side, records live allocations. It exists for two
// reasons that plain `std.testing.allocator` cannot serve:
//
//   1. It makes the double free an ASSERTABLE NUMBER instead of a line on
//      stderr. `std.testing.allocator` prints "Double free detected" and lets
//      the test PASS, so a suite built on it cannot fail on defect A at all.
//      The wrapper counts the duplicate free and swallows it (the first free is
//      forwarded for real, so the use-after-free the next loop iteration
//      performs is still a genuine read of freed memory).
//   2. It measures leaks as a DELTA ACROSS ONE STATEMENT, so a count can be
//      attributed to the statement under test rather than to store/catalog
//      setup, and so defect A and defect B can be asserted separately.
//
// Nothing is weakened by this: every assertion is an exact `expectEqual(0, ...)`
// on counts the wrapper observed while REAL geode code ran.
//
// EXPECTED RED SIGNATURES ON THIS BRANCH (measured, see commit message):
//   1. point-write + comprehension .... 14 double frees, alloc site
//                                       match_operations.zig:1830/:1831
//   2. shortestPath + comprehension ...  8 double frees, alloc site
//                                       match_operations.zig:3446/:3447
//   3. point-write, no comprehension ...  2 leaks @ :1830, :1831
//   4. shortestPath, no comprehension ..  3 leaks @ :3446, :3447 + the
//                                       findShortestPath path array
//   5. bare comprehension (defect B) ... +12 leaks going from 2 to 8 elements
//                                       (2 per element @ value_types.zig:254/:257)
//   CONTROL `RETURN 1` ................. clean today (the rig is honest)
//   GUARDRAIL `RETURN p` ............... green today, must stay green
//   DISCRIMINATOR, legacy :11046 ....... ZERO double frees today (green, and
//                                       must stay green); leaks only from B
//
// CANARY: REQ=REQ-EVAL-ENV-OWNERSHIP-001; FEATURE="EnvBindingOwnership"; ASPECT=WithBindingDoubleFree; STATUS=TESTED; TEST=tests/test_env_owned_double_free.zig; OWNER=execution; UPDATED=2026-09-01
// CANARY: REQ=REQ-EVAL-ENV-OWNERSHIP-002; FEATURE="EnvBindingOwnership"; ASPECT=PointWriteFastPathEnvLeak; STATUS=TESTED; TEST=tests/test_env_owned_double_free.zig; OWNER=execution; UPDATED=2026-09-01
// CANARY: REQ=REQ-EVAL-ENV-OWNERSHIP-003; FEATURE="EnvBindingOwnership"; ASPECT=ShortestPathEnvLeak; STATUS=TESTED; TEST=tests/test_env_owned_double_free.zig; OWNER=execution; UPDATED=2026-09-01
// CANARY: REQ=REQ-EVAL-ENV-OWNERSHIP-004; FEATURE="EnvBindingOwnership"; ASPECT=WithBindingResultLeak; STATUS=TESTED; TEST=tests/test_env_owned_double_free.zig; OWNER=eval; UPDATED=2026-09-01

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;

// ===========================================================================
// TrackingAllocator — real allocations, side-channel accounting.
// ===========================================================================

const Rec = struct {
    len: usize,
    alignment: std.mem.Alignment,
};

/// Zig 0.16 removed `std.Thread.Mutex`, and `std.Io.Mutex` needs an `Io` handle
/// this rig has no reason to carry. The critical sections here are a few
/// hash-map operations, so a spin lock is both sufficient and the smallest
/// possible dependency. Present for safety only: any executor-internal worker
/// thread that allocates through the wrapper must not corrupt the side table.
const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

const TrackingAllocator = struct {
    backing: std.mem.Allocator,
    meta: std.mem.Allocator,
    live: std.AutoHashMapUnmanaged(usize, Rec) = .empty,
    /// A `free` of a pointer that is not currently live. On this branch that is
    /// exclusively `withBinding` freeing the caller's arrays a second time.
    double_frees: usize = 0,
    /// Bookkeeping failed (OOM in the side table); makes the counts untrustworthy.
    accounting_failed: bool = false,
    mu: SpinLock = .{},

    fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = tAlloc,
                .resize = tResize,
                .remap = tRemap,
                .free = tFree,
            },
        };
    }

    fn liveCount(self: *TrackingAllocator) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.live.count();
    }

    /// Release everything still outstanding so the wrapper's own teardown is
    /// clean. Counts have already been sampled by the tests via deltas.
    fn deinit(self: *TrackingAllocator) void {
        var it = self.live.iterator();
        while (it.next()) |e| {
            const ptr: [*]u8 = @ptrFromInt(e.key_ptr.*);
            self.backing.rawFree(ptr[0..e.value_ptr.len], e.value_ptr.alignment, @returnAddress());
        }
        self.live.deinit(self.meta);
    }

    fn tAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.mu.lock();
        defer self.mu.unlock();
        self.live.put(self.meta, @intFromPtr(p), .{ .len = len, .alignment = alignment }) catch {
            self.accounting_failed = true;
        };
        return p;
    }

    fn tResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.mu.lock();
        defer self.mu.unlock();
        // Same address, new length.
        if (self.live.getPtr(@intFromPtr(memory.ptr))) |rec| rec.len = new_len;
        return true;
    }

    fn tRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.mu.lock();
        defer self.mu.unlock();
        _ = self.live.remove(@intFromPtr(memory.ptr));
        self.live.put(self.meta, @intFromPtr(p), .{ .len = new_len, .alignment = alignment }) catch {
            self.accounting_failed = true;
        };
        return p;
    }

    fn tFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        const known = self.live.remove(@intFromPtr(memory.ptr));
        if (!known) {
            // Freeing something that is not live: the duplicate free. Count it
            // and DROP it — forwarding would corrupt the backing allocator's
            // state and take the whole test binary down, destroying the
            // per-test attribution this suite exists to provide. The FIRST free
            // was forwarded for real, so the use-after-free that the next loop
            // iteration performs is a genuine read of released memory.
            self.double_frees += 1;
            self.mu.unlock();
            return;
        }
        self.mu.unlock();
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

/// One statement's allocation accounting.
const Delta = struct {
    double_frees: usize,
    leaked: usize,
};

// ===========================================================================
// Harness — real store, real catalog, real parser, real executor.
// ===========================================================================

// Zig 0.16 compat: `Io.Dir.realpathAlloc` was removed; join cwd + tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    dbg: std.heap.DebugAllocator(.{}),
    tracker: TrackingAllocator,
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    /// Heap-allocated so `tracker`'s address is stable across the move out of
    /// `init` (the vtable closes over `&self.tracker`).
    pub fn create() !*Harness {
        const h = try testing.allocator.create(Harness);
        errdefer testing.allocator.destroy(h);

        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();

        h.dbg = .init;
        h.tracker = .{ .backing = h.dbg.allocator(), .meta = testing.allocator };
        h.allocator = h.tracker.allocator();

        h.tmp = std.testing.tmpDir(.{});
        h.data_dir = try tmpDirRealpathAlloc(h.allocator, &h.tmp.sub_path);

        graph_store.setDataDirOverride(h.allocator, h.data_dir);
        _ = graph_store.getGlobalStore(h.allocator);
        const catalog = try execution.ensureCatalogInstance(h.allocator);
        h.ctx = execution.ExecutionContext{ .catalog = catalog };
        return h;
    }

    pub fn destroy(self: *Harness) void {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
        self.tracker.deinit();
        _ = self.dbg.deinit();
        testing.allocator.destroy(self);
    }

    /// Parse + execute ONE statement and release everything the RESULT owns,
    /// returning what the executor failed to clean up. Anything still
    /// outstanding was leaked by the executor; anything freed twice is the
    /// double free.
    pub fn run(self: *Harness, query: []const u8) !Delta {
        const df_before = self.tracker.double_frees;
        const live_before = self.tracker.liveCount();

        {
            var parsed = try geode.parseGqlOptions(query, self.allocator, .{});
            defer parsed.deinit();
            const prev = execution.pushActiveContext(&self.ctx);
            defer execution.popActiveContext(prev);
            var result = try execution.executeStatementWithContext(
                self.allocator,
                parsed.program.statements[0],
                self.ctx,
            );
            result.deinit(self.allocator);
        }

        const live_after = self.tracker.liveCount();
        try testing.expect(!self.tracker.accounting_failed);
        return .{
            .double_frees = self.tracker.double_frees - df_before,
            .leaked = live_after -| live_before,
        };
    }

    /// Seed nodes carrying a unique indexed string key, straight through the
    /// store APIs (the shape `tests/test_point_write_fastpath.zig:112` uses).
    /// Seeding via the store rather than via `CREATE` keeps this suite's
    /// attribution on the RETURN env, with no write-path evaluation noise.
    pub fn seedKeyed(self: *Harness, label: []const u8, n: usize) !void {
        const store = graph_store.getGlobalStore(self.allocator);
        var labels_buf = [_][]const u8{label};
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const id = try store.createNode(labels_buf[0..]);
            var kb: [32]u8 = undefined;
            const key = std.fmt.bufPrint(&kb, "k-{d}", .{i}) catch unreachable;
            try store.setNodeProperty(id, "k", .{ .String = key });
            try store.setNodeProperty(id, "seq", .{ .Int = @intCast(i) });
        }
    }

    /// A tiny connected graph so `shortestPath` finds a real path.
    pub fn seedPath(self: *Harness, label: []const u8) !void {
        const store = graph_store.getGlobalStore(self.allocator);
        var labels_buf = [_][]const u8{label};
        const a = try store.createNode(labels_buf[0..]);
        try store.setNodeProperty(a, "name", .{ .String = "a" });
        const b = try store.createNode(labels_buf[0..]);
        try store.setNodeProperty(b, "name", .{ .String = "b" });
        const c = try store.createNode(labels_buf[0..]);
        try store.setNodeProperty(c, "name", .{ .String = "c" });
        _ = try store.createEdge(a, b, "SP_LINK");
        _ = try store.createEdge(b, c, "SP_LINK");
    }
};

// ===========================================================================
// 0. CONTROL — the rig itself is clean.
//    A statement that touches no graph and builds no binding env must show zero
//    double frees and zero leaks. If THIS fails, every number below is
//    measuring the harness rather than the bug.
// ===========================================================================
test "control: a statement with no binding env is clean under the tracking allocator" {
    const h = try Harness.create();
    defer h.destroy();

    const d = try h.run("RETURN 1");
    try testing.expectEqual(@as(usize, 0), d.double_frees);
    try testing.expectEqual(@as(usize, 0), d.leaked);
}

// ===========================================================================
// 1. REGRESSION (defect A) — `pointWriteFastPath` + a >=2-element comprehension.
//
//    `MATCH (n:PW) WHERE n.k='k-3' SET n.x=2 RETURN [y IN [...] | y]` is a
//    covered point-write shape (single node pattern, no hops, indexed string
//    equality WHERE, literal SET), so match_operations.zig:1627 serves it and
//    reaches the `.owned = true` env at :1834. The 8-element comprehension then
//    calls `withBinding` on that by-value env once per element.
//
//    RED TODAY: 14 double frees. DebugAllocator names the allocation site as
//    match_operations.zig:1830 (`env_names`) / :1831 (`env_values`) and the
//    freeing site as value_types.zig:270 <- eval.zig:1535 <- :1844.
// ===========================================================================
test "regression: point-write fast path env is not double-freed by a list comprehension" {
    const h = try Harness.create();
    defer h.destroy();

    try h.seedKeyed("PW", 8);

    const d = try h.run(
        "MATCH (n:PW) WHERE n.k = 'k-3' SET n.x = 2 RETURN [y IN [1,2,3,4,5,6,7,8] | y]",
    );
    try testing.expectEqual(@as(usize, 0), d.double_frees);
}

// ===========================================================================
// 2. REGRESSION (defect A) — `handleShortestPathAssignment` + a comprehension.
//
//    `MATCH p = shortestPath(...)` reaches match_operations.zig:3413, whose
//    `path_env` at :3455 is `.owned = true` over arrays allocated at :3446 /
//    :3447 and never freed. Its RETURN loop at :3464 has no shape gate at all.
//
//    RED TODAY: 8 double frees, allocation site match_operations.zig:3446/:3447.
// ===========================================================================
test "regression: shortestPath env is not double-freed by a list comprehension" {
    const h = try Harness.create();
    defer h.destroy();

    try h.seedPath("SP");

    const d = try h.run(
        "MATCH p = shortestPath((a:SP)-[*]-(c:SP)) RETURN [y IN [1,2,3,4,5] | y]",
    );
    try testing.expectEqual(@as(usize, 0), d.double_frees);
}

// ===========================================================================
// 3. The LEAK half of defect A, point-write site.
//
//    With no comprehension in `RETURN`, `withBinding` never runs, so nothing
//    ever frees `env_names`/`env_values`. That is a guaranteed 2-allocation
//    leak on EVERY covered point-write query — the cost of the bug even when no
//    client ever sends a comprehension.
//
//    RED TODAY: exactly 2 leaked allocations, match_operations.zig:1830 and
//    :1831.
// ===========================================================================
test "point-write fast path frees its binding env even without a comprehension" {
    const h = try Harness.create();
    defer h.destroy();

    try h.seedKeyed("PWL", 8);

    const d = try h.run("MATCH (n:PWL) WHERE n.k = 'k-2' SET n.x = 1 RETURN 1");
    try testing.expectEqual(@as(usize, 0), d.double_frees);
    try testing.expectEqual(@as(usize, 0), d.leaked);
}

// ===========================================================================
// 4. The LEAK half of defect A, shortestPath site.
//
//    RED TODAY: 3 leaked allocations, all owned by
//    `handleShortestPathAssignment`'s own frame and all released by nobody:
//      - match_operations.zig:3446  `path_env_names`
//      - match_operations.zig:3447  `path_env_values`
//      - the node array inside the `path_result` Value that :3440
//        (`findShortestPath`) allocated and stashed at :3453. With `RETURN 1`
//        that Value is never read and never escapes, so it is pure garbage.
//
//    NOTE FOR THE FIX: `path_result` is NOT unconditionally garbage — with
//    `RETURN p` the RETURN loop at :3465 can alias it into the row. Test 4b
//    pins that shape so ownership is TRANSFERRED rather than blind-freed.
// ===========================================================================
test "shortestPath frees its path env even without a comprehension" {
    const h = try Harness.create();
    defer h.destroy();

    try h.seedPath("SPL");

    const d = try h.run("MATCH p = shortestPath((a:SPL)-[*]-(c:SPL)) RETURN 1");
    try testing.expectEqual(@as(usize, 0), d.double_frees);
    try testing.expectEqual(@as(usize, 0), d.leaked);
}

// ===========================================================================
// 4b. GUARDRAIL — GREEN TODAY AND MUST STAY GREEN.
//
//     `RETURN p` reads the path variable, so the `path_result` Value flows into
//     the result row. A fix for test 4 that simply frees `path_result` at the
//     end of the frame would hand the caller freed memory here. This pins the
//     boundary: the shape must keep executing and keep returning its row.
//     Leaks are not asserted (test 4 owns that contract); behaviour is.
// ===========================================================================
test "guardrail: shortestPath RETURN p still yields its path row" {
    const h = try Harness.create();
    defer h.destroy();

    try h.seedPath("SPR");

    const d = try h.run("MATCH p = shortestPath((a:SPR)-[*]-(c:SPR)) RETURN p");
    try testing.expectEqual(@as(usize, 0), d.double_frees);
}

// ===========================================================================
// 5. REGRESSION (defect B) — `withBinding`'s RESULT is never freed.
//
//    Deliberately NO `MATCH` and NO fast path: a bare comprehension. The `Env`
//    here has `names.len == 0`, so the `self.names.len > 0` guard at
//    value_types.zig:269 short-circuits and defect A cannot fire — which is
//    exactly what isolates B. `eval.zig:1535` allocates a fresh 1-element
//    `names`/`values` pair per element (value_types.zig:254/:257) and drops it.
//
//    Asserted DIFFERENTIALLY, on purpose. `RETURN <list>` also leaks a small
//    CONSTANT (measured: 2 — the source list literal built at eval.zig:1514 and
//    the result list at eval.zig:1558; `ExecutionResult.owns_value_memory` is
//    false on this path so `result.deinit` frees neither). That constant is a
//    SEPARATE defect about result-value ownership and is not this suite's
//    contract. Defect B is the part that scales with element count, so
//    comparing an 8-element comprehension against a 2-element one cancels the
//    constant exactly and leaves only the per-iteration env.
//
//    RED TODAY: 18 leaks at 8 elements vs 6 at 2 elements -> a growth of 12
//    across 6 extra elements, i.e. exactly the 2 allocations `withBinding`
//    makes per iteration. AFTER THE FIX the growth must be 0 (the absolute
//    counts may legitimately stay at the constant 2).
// ===========================================================================
test "list comprehension frees the per-iteration binding env it allocates" {
    const h = try Harness.create();
    defer h.destroy();

    const small = try h.run("RETURN [y IN [1,2] | y]");
    const large = try h.run("RETURN [y IN [1,2,3,4,5,6,7,8] | y]");

    try testing.expectEqual(@as(usize, 0), small.double_frees);
    try testing.expectEqual(@as(usize, 0), large.double_frees);

    // Per-element leak growth must be zero: six extra elements must not cost
    // six extra binding envs.
    try testing.expectEqual(@as(usize, 0), large.leaked -| small.leaked);
}

// ===========================================================================
// 6. DISCRIMINATOR — GREEN TODAY AND MUST STAY GREEN.
//
//    The legacy match loop at match_operations.zig:11046-11067 ALREADY carries
//    the correct pattern (unconditional frame `defer` + `.owned = false`). The
//    same comprehension shape routed through it must report ZERO double frees
//    today. That proves (a) the counter in this rig reports the defect and not
//    the rig, and (b) `owned = false` + frame `defer` is the right shape for
//    the fixer to copy onto :1834 and :3455.
//
//    A bare `MATCH ... RETURN` carries no SET/REMOVE, so `pointWriteFastPath`
//    declines at :1674 and the legacy loop runs.
//
//    Leaks are deliberately NOT asserted here: this path still leaks via defect
//    B (test 5 owns that contract), and folding B's leak into this assertion
//    would destroy the one signal that distinguishes the fixed site from the
//    broken ones.
// ===========================================================================
test "discriminator: the already-fixed legacy match env reports no double free" {
    const h = try Harness.create();
    defer h.destroy();

    try h.seedKeyed("GRD", 4);

    const d = try h.run("MATCH (n:GRD) WHERE n.k = 'k-1' RETURN [y IN [1,2,3,4,5,6,7,8] | y]");
    try testing.expectEqual(@as(usize, 0), d.double_frees);
}
