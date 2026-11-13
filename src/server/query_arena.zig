// CANARY: REQ=REQ-PERF-QUERY-ARENA-001; FEATURE="PerQueryArenaPool"; ASPECT=ScratchAllocator; STATUS=TESTED; TEST=tests/test_query_arena_reuse.zig; OWNER=engine; UPDATED=2026-04-18
//! Per-query arena allocator pool for executor scratch work (GAP-0755).
//!
//! After GAP-0753 narrowed the handler lock-hold window and GAP-0754 swapped
//! the graph_store global allocator to `smp_allocator`, the next bottleneck
//! on the MATCH hot path is per-query scratch allocations (start-slot lists,
//! property-row ArrayLists, intermediate ResultRow buffers). For a hot path
//! with dozens of allocations per query, bundling all of it into one
//! per-query `ArenaAllocator` that's reset between queries removes the
//! round-trip and guarantees zero fragmentation across queries.
//!
//! Usage:
//!   * One `Pool` per process (acquired by QUIC and gRPC handlers).
//!   * One `*Arena` borrowed per query; all scratch allocations go through
//!     `arena.allocator()`.
//!   * On release, the arena is reset (retaining capacity) and returned to
//!     the pool's free list. If the free list is already at capacity on
//!     release (oversubscription), the arena is deinitialized instead of
//!     pooled.
//!
//! Thread-safety:
//!   The pool's free list is guarded by a short internal mutex (acquire and
//!   release are measured in microseconds). Individual arenas are NOT
//!   thread-safe — each query holds exclusive use between acquire and
//!   release.

const std = @import("std");

/// One per-query arena. Consumers call `arena.allocator()` for all scratch
/// work during a query; the pool resets the arena on release so the next
/// borrow reuses the backing memory without re-allocating from the system
/// allocator.
pub const Arena = struct {
    inner: std.heap.ArenaAllocator,

    pub fn allocator(self: *Arena) std.mem.Allocator {
        return self.inner.allocator();
    }
};

/// Fixed-capacity free-list of query arenas. Acquire is lock-guarded
/// (short critical section) and reuses arenas across queries without
/// re-allocating. Oversubscribed callers fall back to a fresh
/// `ArenaAllocator` backed by the pool's backing allocator.
pub const Pool = struct {
    backing: std.mem.Allocator,
    free_list: std.ArrayList(*Arena),
    lock: std.Io.Mutex = std.Io.Mutex.init,
    capacity: usize,

    pub fn init(backing: std.mem.Allocator, capacity: usize) !Pool {
        return Pool{
            .backing = backing,
            .free_list = std.ArrayList(*Arena).empty,
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *Pool) void {
        self.lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.lock.unlock(std.Io.Threaded.global_single_threaded.io());
        for (self.free_list.items) |a| {
            a.inner.deinit();
            self.backing.destroy(a);
        }
        self.free_list.deinit(self.backing);
    }

    /// Borrow an arena from the pool. If the free list is non-empty, reuses
    /// an existing arena (already reset). Otherwise allocates a fresh one.
    pub fn acquire(self: *Pool) !*Arena {
        self.lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.lock.unlock(std.Io.Threaded.global_single_threaded.io());
        if (self.free_list.items.len > 0) {
            return self.free_list.pop().?;
        }
        const a = try self.backing.create(Arena);
        a.* = .{ .inner = std.heap.ArenaAllocator.init(self.backing) };
        return a;
    }

    /// Return an arena to the pool. Resets the arena (retains capacity) so
    /// the next borrower starts at the top of the retained buffer. If the
    /// free list is already at capacity, tears the arena down instead of
    /// pooling it — keeps peak memory bounded under bursty oversubscription.
    pub fn release(self: *Pool, arena: *Arena) void {
        _ = arena.inner.reset(.retain_capacity);
        self.lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.lock.unlock(std.Io.Threaded.global_single_threaded.io());
        if (self.free_list.items.len >= self.capacity) {
            arena.inner.deinit();
            self.backing.destroy(arena);
            return;
        }
        self.free_list.append(self.backing, arena) catch {
            // On OOM appending the pointer, fall back to tearing the arena
            // down — we must not leak the arena allocation itself.
            arena.inner.deinit();
            self.backing.destroy(arena);
        };
    }
};

// =============================================================================
// Thread-local "current scratch allocator" install/uninstall.
//
// The executor entry point (executeMatchQueryImpl and its callees) is a
// ~7000-line fan-out with hundreds of allocator usages; threading a
// scratch_allocator parameter through every call site is a follow-up.
// For now, the handler installs the arena's allocator as a thread-local
// *hint* that opportunistic scratch sites (future refactors) can pick up
// via `currentScratchAllocator()`. When unset, scratch sites fall back to
// their existing allocator (usually the graph_store global allocator).
// =============================================================================

threadlocal var g_current_scratch: ?std.mem.Allocator = null;

/// Install a scratch allocator for the current thread. Returns the previous
/// value so nested scopes (e.g. subqueries) can restore it on pop. Pair
/// every push with a `popScratchAllocator(prev)` on all exit paths.
pub fn pushScratchAllocator(alloc: std.mem.Allocator) ?std.mem.Allocator {
    const prev = g_current_scratch;
    g_current_scratch = alloc;
    return prev;
}

pub fn popScratchAllocator(previous: ?std.mem.Allocator) void {
    g_current_scratch = previous;
}

/// Returns the current-thread scratch allocator if one is installed, or null
/// otherwise. Callers that need scratch memory but have no hard requirement
/// on lifetime beyond the query boundary should prefer this over the
/// graph_store global allocator.
pub fn currentScratchAllocator() ?std.mem.Allocator {
    return g_current_scratch;
}

// CANARY: REQ=REQ-SONNY-6449-STATEMENT-SCRATCH; FEATURE="PerQueryArenaPool"; ASPECT=StatementScratch; STATUS=TESTED; TEST=tests/test_sonny6449_projection_value_ownership.zig; OWNER=engine; UPDATED=2026-11-12
/// SONNY-6449: the scratch arena of a statement run with none installed (an
/// embedded caller: no transport borrowed one from the pool). The outermost
/// executor entry point opens it, so every statement runs with a scratch
/// arena, as one sent over a transport does, and what the evaluator gives a
/// caller to borrow (a member read's decrypted string or list copy, a list
/// comprehension) has one owner on every path. The entry point copies its
/// result out of the arena before it closes it (`used`). With a scratch
/// arena already installed it does nothing. It must not move once opened.
pub const StatementScratch = struct {
    arena: std.heap.ArenaAllocator = undefined,
    previous: ?std.mem.Allocator = null,
    installed: bool = false,

    pub fn open(self: *StatementScratch, backing: std.mem.Allocator) void {
        self.* = .{};
        if (g_current_scratch != null) return;
        self.arena = std.heap.ArenaAllocator.init(backing);
        self.previous = pushScratchAllocator(self.arena.allocator());
        self.installed = true;
    }

    /// Whether anything was allocated on the arena this opened: a result
    /// may then borrow from it.
    pub fn used(self: *const StatementScratch) bool {
        return self.installed and self.arena.queryCapacity() > 0;
    }

    pub fn close(self: *StatementScratch) void {
        if (!self.installed) return;
        popScratchAllocator(self.previous);
        self.arena.deinit();
        self.installed = false;
    }
};

// =============================================================================
// Process-wide default pool.
//
// Wired from the QUIC and gRPC handlers at startup. Initializing here (as an
// optional) keeps the pool a single process-wide resource shared across
// transport threads.
// =============================================================================

var g_default_pool: ?Pool = null;
var g_default_pool_init_lock: std.Io.Mutex = std.Io.Mutex.init;

/// Lazily initialize the process-wide default pool. Safe to call from any
/// handler thread; the first call wins, subsequent calls are no-ops.
/// Capacity defaults to `cpu_count * 2` which covers both transport workers
/// and any background worker that wants an arena.
pub fn ensureDefaultPool(backing: std.mem.Allocator) !*Pool {
    g_default_pool_init_lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_default_pool_init_lock.unlock(std.Io.Threaded.global_single_threaded.io());
    if (g_default_pool == null) {
        const cpu = std.Thread.getCpuCount() catch 4;
        const cap = @max(@as(usize, 4), cpu * 2);
        g_default_pool = try Pool.init(backing, cap);
    }
    return &g_default_pool.?;
}

/// Accessor for the already-initialized default pool. Returns null if
/// `ensureDefaultPool` has not been called yet.
pub fn defaultPool() ?*Pool {
    if (g_default_pool == null) return null;
    return &g_default_pool.?;
}

/// Tear down the default pool. Intended for tests and clean shutdown.
pub fn deinitDefaultPool() void {
    g_default_pool_init_lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_default_pool_init_lock.unlock(std.Io.Threaded.global_single_threaded.io());
    if (g_default_pool) |*p| {
        p.deinit();
        g_default_pool = null;
    }
}
