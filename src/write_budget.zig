//! GAP (write-path OOM): working-set budget for the LEGACY write-carrying
//! MATCH executor.
//!
//! Incident (2026-07-04): ONE single-node `MATCH (n:Taxon) WHERE
//! n.source_id='X' SET n.p='v'` on the 14.27M store ran 50+ minutes
//! materializing O(graph) on the legacy executor (detached scan boxes +
//! per-candidate env/eval allocations), RSS 82 -> 86.4 G, available -> 0, and
//! the OOM killer took the server AND the operator session. The write path had
//! NO memory bound of its own — the OOM killer was the arbiter.
//!
//! This module provides that bound. A `Scope` is installed (thread-local) by
//! the query executor around the LEGACY dispatch of any write-carrying MATCH
//! shape (SET / REMOVE / DELETE / MATCH..CREATE / MATCH..MERGE). While active:
//!
//!   * every allocation routed through the scope's `MeteredAllocator` (the
//!     per-query executor allocator: candidate lists, env arrays, eval scratch,
//!     result rows) is charged/credited NET-LIVE against the budget;
//!   * the graph store charges each DETACHED scan-box adoption
//!     (`getNodePtrForScan` hydrate-on-miss — the O(graph) resident-growth
//!     family from the incident) via `chargeStoreBytes`;
//!   * once live > budget the scope trips `exceeded`:
//!       - the executor's candidate loops poll `check()` and abort the query
//!         with `error.WriteQueryBudgetExceeded` (clean, client-visible);
//!       - as a hard backstop, the metered allocator REFUSES further
//!         allocations (null -> error.OutOfMemory), which the installing
//!         boundary translates to `error.WriteQueryBudgetExceeded`, so even an
//!         un-instrumented allocation-heavy path cannot run away.
//!
//! PRECISION (intentionally coarse — page granularity is fine): the query-side
//! meter is exact for everything routed through the metered allocator; the
//! store-side meter approximates each detached box as
//! `@sizeOf(Node) + graph_name + labels + per-property entry overhead + string
//! payload bytes`. Memory the store hydrates into the bounded node cache is NOT
//! charged (it is bounded by the cache cap and evictable). The budget is a
//! working-set tripwire, not an accounting ledger.
//!
//! ATOMICITY at abort: the budget is polled BETWEEN candidates, before a
//! candidate's mutation is applied — a node's SET/REMOVE is never left
//! half-applied. The legacy executor provides NO statement-level rollback for
//! autocommit multi-row writes (pre-existing semantics: any mid-query error —
//! eval failure, OOM — leaves earlier per-node writes applied). The budget
//! abort therefore guarantees: (a) per-node atomicity, (b) no further writes
//! after the trip, (c) a loud, clean error instead of the OOM killer.
//!
//! Configuration: `GEODE_WRITE_EXECUTOR_BUDGET_MB` (default 8192 MB).
//! `0` disables the budget (unlimited). Parsed once, cached; tests override via
//! `setBudgetBytesForTest`.

const std = @import("std");

pub const env_var_name = "GEODE_WRITE_EXECUTOR_BUDGET_MB";
pub const default_budget_mb: u64 = 8192;

/// Sentinel for "no budget" (env set to 0): never trips.
pub const unlimited: u64 = std.math.maxInt(u64);

var g_env_parsed = std.atomic.Value(bool).init(false);
var g_env_bytes = std.atomic.Value(u64).init(0);
/// Test override; 0 = unset. Takes precedence over the env value.
var g_test_override_bytes = std.atomic.Value(u64).init(0);

threadlocal var t_active: ?*Scope = null;

/// Resolve the configured budget in BYTES. Env parsed once and cached.
pub fn budgetBytes() u64 {
    const override = g_test_override_bytes.load(.acquire);
    if (override != 0) return override;
    if (g_env_parsed.load(.acquire)) return g_env_bytes.load(.acquire);
    const bytes: u64 = blk: {
        const raw = std.posix.getenv(env_var_name) orelse
            break :blk default_budget_mb * 1024 * 1024;
        const mb = std.fmt.parseInt(u64, raw, 10) catch
            break :blk default_budget_mb * 1024 * 1024;
        if (mb == 0) break :blk unlimited; // 0 = disabled
        break :blk std.math.mul(u64, mb, 1024 * 1024) catch unlimited;
    };
    g_env_bytes.store(bytes, .release);
    g_env_parsed.store(true, .release);
    return bytes;
}

/// Test hook: force a budget (bytes). Pass 0 to clear the override.
pub fn setBudgetBytesForTest(bytes: u64) void {
    g_test_override_bytes.store(bytes, .release);
}

/// One active write-query budget window. Owned by the installing frame
/// (stack), accessed only from the installing thread — no internal locking.
pub const Scope = struct {
    budget_bytes: u64,
    live_bytes: u64 = 0,
    peak_bytes: u64 = 0,
    exceeded: bool = false,
    prev: ?*Scope = null,

    pub fn init() Scope {
        return .{ .budget_bytes = budgetBytes() };
    }
};

/// Install `s` as the current thread's active scope (LIFO; nested write
/// queries — chains/subqueries — each meter independently).
pub fn beginScope(s: *Scope) void {
    s.prev = t_active;
    t_active = s;
}

pub fn endScope(s: *Scope) void {
    t_active = s.prev;
}

pub fn activeScope() ?*Scope {
    return t_active;
}

/// Charge `n` live bytes to the active scope (no-op without one).
pub fn charge(n: u64) void {
    const s = t_active orelse return;
    s.live_bytes +|= n;
    if (s.live_bytes > s.peak_bytes) s.peak_bytes = s.live_bytes;
    if (s.live_bytes > s.budget_bytes) s.exceeded = true;
}

/// Credit `n` bytes back (freed) to the active scope (no-op without one).
/// Once `exceeded` trips it stays tripped — the abort must not be raced away
/// by a late free.
pub fn credit(n: u64) void {
    const s = t_active orelse return;
    s.live_bytes -|= n;
}

/// Store-side charge for a DETACHED scan-box adoption (graph_store
/// `getNodePtrForScan` hydrate-on-miss). Same accounting as `charge`; separate
/// name so grep finds the store call sites.
pub fn chargeStoreBytes(n: u64) void {
    charge(n);
}

pub fn exceeded() bool {
    const s = t_active orelse return false;
    return s.exceeded;
}

/// Poll site for the executor's candidate loops: aborts the write query with
/// a clean, client-mappable error once the working set crossed the budget.
pub fn check() error{WriteQueryBudgetExceeded}!void {
    if (exceeded()) return error.WriteQueryBudgetExceeded;
}

/// Pass-through observer allocator. Forwards every call to `inner` unchanged
/// (returned memory IS `inner` memory — freeing it later via `inner` directly
/// is legal), adjusting the active scope's net-live counter. HARD BACKSTOP:
/// once the active scope is exceeded, `alloc`/growing-`remap` refuse (null),
/// so an un-instrumented runaway path degrades to error.OutOfMemory instead of
/// eating the box; the installing boundary translates that to
/// `error.WriteQueryBudgetExceeded` when the scope tripped.
pub const MeteredAllocator = struct {
    inner: std.mem.Allocator,

    pub fn allocator(self: *MeteredAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocImpl,
        .resize = resizeImpl,
        .remap = remapImpl,
        .free = freeImpl,
    };

    fn allocImpl(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *MeteredAllocator = @ptrCast(@alignCast(ctx));
        if (exceeded()) return null; // backstop: no new memory once tripped
        const p = self.inner.rawAlloc(len, alignment, ret_addr) orelse return null;
        charge(len);
        return p;
    }

    fn resizeImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *MeteredAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and exceeded()) return false;
        if (!self.inner.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len > memory.len) {
            charge(new_len - memory.len);
        } else {
            credit(memory.len - new_len);
        }
        return true;
    }

    fn remapImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *MeteredAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and exceeded()) return null;
        const p = self.inner.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len > memory.len) {
            charge(new_len - memory.len);
        } else {
            credit(memory.len - new_len);
        }
        return p;
    }

    fn freeImpl(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *MeteredAllocator = @ptrCast(@alignCast(ctx));
        credit(memory.len);
        self.inner.rawFree(memory, alignment, ret_addr);
    }
};

test "scope charge/credit/exceeded lifecycle" {
    var s = Scope{ .budget_bytes = 100 };
    beginScope(&s);
    defer endScope(&s);
    charge(60);
    try std.testing.expect(!exceeded());
    charge(30);
    try std.testing.expect(!exceeded());
    credit(50);
    charge(80); // live 120 > 100
    try std.testing.expect(exceeded());
    try std.testing.expectError(error.WriteQueryBudgetExceeded, check());
    // Trip is sticky: a later credit does not un-exceed.
    credit(120);
    try std.testing.expect(exceeded());
}

test "metered allocator charges net-live and backstops after trip" {
    var s = Scope{ .budget_bytes = 1024 };
    beginScope(&s);
    defer endScope(&s);
    var metered = MeteredAllocator{ .inner = std.testing.allocator };
    const a = metered.allocator();

    const b1 = try a.alloc(u8, 512);
    try std.testing.expectEqual(@as(u64, 512), s.live_bytes);
    a.free(b1);
    try std.testing.expectEqual(@as(u64, 0), s.live_bytes);

    const b2 = try a.alloc(u8, 2048); // over budget -> tripped, memory still granted
    try std.testing.expect(s.exceeded);
    // Backstop: further allocation refused while tripped.
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
    a.free(b2);
}

test "no active scope: charge/check are no-ops" {
    try std.testing.expect(t_active == null);
    charge(1 << 40);
    try check();
    try std.testing.expect(!exceeded());
}
