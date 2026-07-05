//! GAP-ENT-0044/0045 (T5): working-set budget + cancellation for the READ
//! executor — the exact GAP-ENT-0040 write-budget discipline applied to the
//! read/aggregate/scan materialization path.
//!
//! Incident (2026-07-05): two abandoned `GROUP BY source count(*)` reads
//! (client timed out and disconnected) kept running server-side for ~50 min,
//! materializing one full node row per node with NO memory bound and NO
//! cancellation signal. RSS grew 27G -> 93.6G and the kernel OOM killer took
//! the whole server (and the operator's session). Two independent guards fix
//! the two failure modes:
//!
//!   BUDGET — a thread-local `Scope` is installed by the query executor around
//!   the READ dispatch of any MATCH-carrying non-write query. Every allocation
//!   routed through the scope's `MeteredAllocator` (planned-read row
//!   materialization, legacy binding arrays, aggregation scratch) is charged
//!   net-live; once live > `GEODE_READ_EXECUTOR_BUDGET_MB` (default 8192 MB,
//!   0 disables) the scope trips: poll sites abort with
//!   `error.ReadQueryBudgetExceeded` (mapped to SQLSTATE 53200) and the
//!   metered allocator REFUSES further memory as a hard backstop. The OOM
//!   killer is never the arbiter.
//!
//!   CANCEL — the transport layer publishes a per-stream atomic cancel flag
//!   (`setStreamCancelSource`) before dispatching a query on the handler
//!   thread; `Scope.init` captures it. Client stream close / connection
//!   teardown / the proto-reader stall watchdog set the flag; the executor's
//!   scan+aggregate loops poll `check()` at row/batch boundaries and abort
//!   with `error.ReadQueryCancelled` (mapped to SQLSTATE 57014) within one
//!   batch — a disconnected client can no longer pin CPU/RSS for minutes.
//!
//! Poll sites are the same candidate/slot loops that poll the write budget:
//! a thread-local load + two atomic loads per row at most, no-ops without an
//! installed scope (write paths, DDL, tests that don't install one).
//!
//! Configuration: `GEODE_READ_EXECUTOR_BUDGET_MB` (default 8192). `0` disables
//! the budget (cancel still works). Parsed once, cached; tests override via
//! `setBudgetBytesForTest`.

const std = @import("std");

pub const env_var_name = "GEODE_READ_EXECUTOR_BUDGET_MB";
pub const default_budget_mb: u64 = 8192;

/// Sentinel for "no budget" (env set to 0): never trips.
pub const unlimited: u64 = std.math.maxInt(u64);

pub const CheckError = error{ ReadQueryBudgetExceeded, ReadQueryCancelled };

var g_env_parsed = std.atomic.Value(bool).init(false);
var g_env_bytes = std.atomic.Value(u64).init(0);
/// Test override; 0 = unset. Takes precedence over the env value.
var g_test_override_bytes = std.atomic.Value(u64).init(0);

threadlocal var t_active: ?*Scope = null;
/// Transport-installed per-stream cancel flag for the CURRENT handler thread.
/// Wired to `QuicStream.shutdown_requested` (→ `Connection.shutdown_requested`),
/// which the transport sets the instant the client connection is closed /
/// reset / idle-reaped — the same source the node-scan streaming cancel uses.
/// Captured by `Scope.init` so nested scopes (chained queries) all observe the
/// same stream's flag. Null on threads with no transport (tests, CLI).
threadlocal var t_stream_cancel: ?*const std.atomic.Value(bool) = null;
/// Watchdog-installed per-reader cancel flag (GAP-ENT-0045): the proto-reader
/// stall watchdog sets THIS flag (via the reader registry's requestCancel)
/// when it detects a wedged handler, aborting the executor instead of only
/// logging. Separate from the connection flag so a targeted watchdog abort
/// never tears down healthy sibling streams.
threadlocal var t_watchdog_cancel: ?*const std.atomic.Value(bool) = null;

/// Resolve the configured budget in BYTES. Env parsed once and cached.
pub fn budgetBytes() u64 {
    const override = g_test_override_bytes.load(.acquire);
    if (override != 0) return override;
    if (g_env_parsed.load(.acquire)) return g_env_bytes.load(.acquire);
    const bytes: u64 = blk: {
        const ptr = std.c.getenv(env_var_name) orelse
            break :blk default_budget_mb * 1024 * 1024;
        const raw = std.mem.span(ptr);
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

/// Install the CURRENT thread's stream cancel flag (transport handler entry).
/// Pass null to clear on handler exit. The pointee must outlive every query
/// dispatched while installed.
pub fn setStreamCancelSource(flag: ?*const std.atomic.Value(bool)) void {
    t_stream_cancel = flag;
}

pub fn streamCancelSource() ?*const std.atomic.Value(bool) {
    return t_stream_cancel;
}

/// Install the CURRENT thread's watchdog cancel flag (the per-reader
/// `cancel_requested` set by the stall watchdog via the reader registry).
pub fn setWatchdogCancelSource(flag: ?*const std.atomic.Value(bool)) void {
    t_watchdog_cancel = flag;
}

/// One active read-query budget/cancel window. Owned by the installing frame
/// (stack), accessed only from the installing thread — no internal locking
/// (the cancel flag itself is atomic and set cross-thread).
pub const Scope = struct {
    budget_bytes: u64,
    live_bytes: u64 = 0,
    peak_bytes: u64 = 0,
    exceeded: bool = false,
    /// Per-stream (connection close) cancel flag captured at install time.
    cancel: ?*const std.atomic.Value(bool) = null,
    /// Per-reader (watchdog abort) cancel flag captured at install time.
    watchdog_cancel: ?*const std.atomic.Value(bool) = null,
    prev: ?*Scope = null,

    pub fn init() Scope {
        return .{
            .budget_bytes = budgetBytes(),
            .cancel = t_stream_cancel,
            .watchdog_cancel = t_watchdog_cancel,
        };
    }
};

/// Install `s` as the current thread's active scope (LIFO; nested read
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

pub fn exceeded() bool {
    const s = t_active orelse return false;
    return s.exceeded;
}

pub fn cancelled() bool {
    const s = t_active orelse return false;
    if (s.cancel) |flag| {
        if (flag.load(.acquire)) return true;
    }
    if (s.watchdog_cancel) |flag| {
        if (flag.load(.acquire)) return true;
    }
    return false;
}

/// Poll site for the executor's scan/aggregate loops: aborts the read query
/// with a clean, client-mappable error once the working set crossed the
/// budget (SQLSTATE 53200) or the client is gone / the watchdog aborted the
/// wedged executor (SQLSTATE 57014). No-op without an installed scope.
pub fn check() CheckError!void {
    const s = t_active orelse return;
    if (s.exceeded) return error.ReadQueryBudgetExceeded;
    if (s.cancel) |flag| {
        if (flag.load(.acquire)) return error.ReadQueryCancelled;
    }
    if (s.watchdog_cancel) |flag| {
        if (flag.load(.acquire)) return error.ReadQueryCancelled;
    }
}

/// GAP-ENT-0048 DEFECT B: a snapshot of the active read scope's cancel flag
/// pointers, so a worker on a DIFFERENT thread than the installing handler can
/// poll cancellation directly. The exact-index rebuild dispatches its per-shard
/// scans onto the shared thread pool, whose workers do NOT inherit the
/// handler's threadlocal `Scope` — so `check()` (which reads that threadlocal)
/// is a silent no-op on them. Capturing the raw atomic pointers here lets those
/// workers observe a client disconnect / stall-watchdog abort at a batch
/// boundary and free the wedged handler instead of running the whole O(graph)
/// rebuild to completion.
///
/// Empty (never trips) when no read scope is installed — so a WRITE-path rebuild
/// (writes never install a read scope) is never cancelled.
pub const CancelFlags = struct {
    cancel: ?*const std.atomic.Value(bool) = null,
    watchdog: ?*const std.atomic.Value(bool) = null,

    /// True once either captured cancel source has been set (cross-thread safe).
    pub fn tripped(self: CancelFlags) bool {
        if (self.cancel) |flag| {
            if (flag.load(.acquire)) return true;
        }
        if (self.watchdog) |flag| {
            if (flag.load(.acquire)) return true;
        }
        return false;
    }
};

/// Snapshot the active read scope's cancel flag pointers (see `CancelFlags`).
/// Both null when no read scope is installed on the calling thread.
pub fn activeCancelFlags() CancelFlags {
    const s = t_active orelse return .{};
    return .{ .cancel = s.cancel, .watchdog = s.watchdog_cancel };
}

/// Pass-through observer allocator. Forwards every call to `inner` unchanged
/// (returned memory IS `inner` memory — freeing it later via `inner` directly
/// is legal), adjusting the active scope's net-live counter. HARD BACKSTOP:
/// once the active scope is exceeded, `alloc`/growing-`remap` refuse (null),
/// so an un-instrumented runaway path degrades to error.OutOfMemory instead
/// of eating the box; the installing boundary translates that to
/// `error.ReadQueryBudgetExceeded` when the scope tripped.
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
    try check();
    charge(30);
    try check();
    credit(50);
    charge(80); // live 120 > 100
    try std.testing.expect(exceeded());
    try std.testing.expectError(error.ReadQueryBudgetExceeded, check());
    // Trip is sticky: a later credit does not un-exceed.
    credit(120);
    try std.testing.expect(exceeded());
}

test "cancel flag aborts check() within one poll" {
    var flag = std.atomic.Value(bool).init(false);
    setStreamCancelSource(&flag);
    defer setStreamCancelSource(null);

    var s = Scope.init();
    try std.testing.expect(s.cancel != null);
    beginScope(&s);
    defer endScope(&s);

    try check(); // not cancelled yet
    flag.store(true, .release); // transport: client gone / watchdog abort
    try std.testing.expectError(error.ReadQueryCancelled, check());
}

test "watchdog cancel source aborts independently of the connection flag" {
    var conn_flag = std.atomic.Value(bool).init(false);
    var wd_flag = std.atomic.Value(bool).init(false);
    setStreamCancelSource(&conn_flag);
    setWatchdogCancelSource(&wd_flag);
    defer setStreamCancelSource(null);
    defer setWatchdogCancelSource(null);

    var s = Scope.init();
    beginScope(&s);
    defer endScope(&s);

    try check();
    wd_flag.store(true, .release); // watchdog: abort the wedged executor
    try std.testing.expectError(error.ReadQueryCancelled, check());
}

test "activeCancelFlags snapshots the scope's cancel sources for cross-thread polling" {
    // No scope installed -> empty snapshot, never trips.
    try std.testing.expect(!activeCancelFlags().tripped());

    var conn = std.atomic.Value(bool).init(false);
    var wd = std.atomic.Value(bool).init(false);
    setStreamCancelSource(&conn);
    setWatchdogCancelSource(&wd);
    defer setStreamCancelSource(null);
    defer setWatchdogCancelSource(null);

    var s = Scope.init();
    beginScope(&s);
    defer endScope(&s);

    const flags = activeCancelFlags();
    try std.testing.expect(flags.cancel != null);
    try std.testing.expect(flags.watchdog != null);
    try std.testing.expect(!flags.tripped());
    // A cross-thread set on the connection flag is observed through the
    // captured pointer (the rebuild's pool workers rely on exactly this).
    conn.store(true, .release);
    try std.testing.expect(flags.tripped());
}

test "budget trip takes precedence over cancel; no scope = no-op" {
    var flag = std.atomic.Value(bool).init(true);
    setStreamCancelSource(&flag);
    defer setStreamCancelSource(null);

    var s = Scope.init();
    s.budget_bytes = 10;
    beginScope(&s);
    charge(11);
    try std.testing.expectError(error.ReadQueryBudgetExceeded, check());
    endScope(&s);

    // No active scope: check() is a no-op even with the flag set.
    try check();
    try std.testing.expect(!exceeded());
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
