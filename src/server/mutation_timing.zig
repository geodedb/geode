/// Per-mutation wall-clock timing instrumentation.
///
/// Off by default.  Enable by setting GEODE_MUTATION_TIMING_LOG=1 in the
/// server environment before startup; `init()` reads the variable once and
/// stores the result in an atomic flag so all threads see it without a lock.
///
/// Usage (in the mutation hot path):
///
///   var s = mutation_timing.begin();
///   // … acquire write lock …
///   s.markLockAcquired();
///   // … execute statement …
///   s.markExecuteDone();
///   // … release write lock …
///   s.markLockReleased();
///   s.record(query_text[0..@min(query_text.len, 80)]);
///
/// Each `record()` call emits one structured log line when timing is enabled
/// and saves the sample thread-locally so unit tests can inspect it via
/// `lastSampleForTest()`.
const std = @import("std");
const builtin = @import("builtin");

// ---------------------------------------------------------------------------
// Internal monotonic clock helper (Zig 0.16 compat — no std.time.Timer).
// ---------------------------------------------------------------------------

fn monoNanos() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// ---------------------------------------------------------------------------
// Global enable flag (atomic — written once at startup, read from every
// connection thread).
// ---------------------------------------------------------------------------

var enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Call once at server startup.  Reads GEODE_MUTATION_TIMING_LOG from the
/// process environment; sets the enable flag accordingly.
///
/// `init()` takes an optional override string so that callers that have
/// already resolved the env var (e.g. via a Zig 0.16-safe wrapper) can pass
/// the value directly.  When `override` is null the function falls back to
/// `std.c.getenv`.
pub fn init(override: ?[:0]const u8) void {
    const val: ?[:0]const u8 = override orelse
        (if (std.c.getenv("GEODE_MUTATION_TIMING_LOG")) |p| std.mem.span(p) else null);
    const on = val != null and val.?.len > 0 and val.?[0] != '0';
    enabled.store(on, .release);
}

// ---------------------------------------------------------------------------
// Sample type.
// ---------------------------------------------------------------------------

pub const Sample = struct {
    // Raw timestamps (nanoseconds since an arbitrary epoch).
    stage_start_ns: u64,
    lock_acquire_start_ns: u64 = 0,
    lock_acquired_ns: u64 = 0,
    execute_done_ns: u64 = 0,
    lock_released_ns: u64 = 0,

    // Computed phase durations — populated by record() so tests can access
    // them as plain fields.
    lock_wait_ns: u64 = 0,
    execute_ns: u64 = 0,
    release_ns: u64 = 0,

    /// Mark the instant the write lock was successfully acquired.
    pub fn markLockAcquired(self: *Sample) void {
        self.lock_acquired_ns = monoNanos();
    }

    /// Mark the instant execution completed (before lock release).
    pub fn markExecuteDone(self: *Sample) void {
        self.execute_done_ns = monoNanos();
    }

    /// Mark the instant the write lock was released.
    pub fn markLockReleased(self: *Sample) void {
        self.lock_released_ns = monoNanos();
    }

    /// Emit a structured log line (when timing is enabled) and save the
    /// sample thread-locally for test inspection.  Computes phase durations
    /// from the raw timestamps and stores them in the public fields.
    pub fn record(self: *Sample, stmt_preview: []const u8) void {
        // Compute derived durations.
        self.lock_wait_ns = if (self.lock_acquired_ns != 0 and self.lock_acquire_start_ns != 0)
            self.lock_acquired_ns - self.lock_acquire_start_ns
        else
            0;
        self.execute_ns = if (self.execute_done_ns != 0 and self.lock_acquired_ns != 0)
            self.execute_done_ns - self.lock_acquired_ns
        else
            0;
        self.release_ns = if (self.lock_released_ns != 0 and self.execute_done_ns != 0)
            self.lock_released_ns - self.execute_done_ns
        else
            0;

        // Always save thread-local so tests can inspect via lastSampleForTest().
        t_last_sample = self.*;

        if (!enabled.load(.acquire)) return;

        std.debug.print(
            "MUT_TIMING lock_wait_ns={d} execute_ns={d} release_ns={d} stmt=\"{s}\"\n",
            .{
                self.lock_wait_ns,
                self.execute_ns,
                self.release_ns,
                stmt_preview,
            },
        );
    }
};

// Thread-local storage for the most recent sample — lets unit tests inspect
// results without going through I/O.
threadlocal var t_last_sample: ?Sample = null;

// ---------------------------------------------------------------------------
// Public API.
// ---------------------------------------------------------------------------

/// Start a new timing sample.  Records `lock_acquire_start_ns` at the point
/// where the caller is about to attempt write lock acquisition.
pub fn begin() Sample {
    const now = monoNanos();
    return .{
        .stage_start_ns = now,
        .lock_acquire_start_ns = now,
    };
}

// ---------------------------------------------------------------------------
// Test helpers (never called in production).
// ---------------------------------------------------------------------------

/// Force-enable or force-disable timing for the current test.  Call
/// `setEnabledForTest(false)` in a `defer` to restore the default.
pub fn setEnabledForTest(v: bool) void {
    enabled.store(v, .release);
}

/// Returns the last sample recorded on this thread, or null if none.
pub fn lastSampleForTest() ?Sample {
    return t_last_sample;
}
