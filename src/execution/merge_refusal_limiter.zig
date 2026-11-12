// CANARY: REQ=REQ-SONNY-2817-MERGE-REFUSAL-LIMIT; FEATURE="MergeRowVisibility"; ASPECT=Limiter; STATUS=TESTED; TEST=tests/test_sonny2817_merge_refusal_limit.zig; OWNER=security; UPDATED=2026-11-12
//
// SONNY-2817: the per-session, per-label limit on MERGE visibility refusals.
//
// A MERGE whose only match is a row row-level security hides from the session
// is refused (MergeMatchNotVisible, SONNY-2686). The refusal tells the session
// that some hidden row equals the pattern: an equality oracle over any
// property the pattern names (docs/kb/RLS_IMPLEMENTATION.md). Each session
// (`execution.SessionState`, one per QUIC or gRPC session) counts its
// refusals per (graph, label): more than `refusal_limit` within `window_ms`
// starts a cooldown of `cooldown_ms`, during which every MERGE that names the
// label on that graph is refused (MergeRefusalRateLimited, 53400) whatever it
// would have matched, so the cooldown answers nothing. The cooldown ends on
// its own; a new session starts with no count (the limit is per session, as
// the failed-login limiter is per user: a client that opens sessions to
// evade it pays a HELLO, and an authentication, for each).

const std = @import("std");

/// Refusals a session may collect on one (graph, label) within `window_ms`
/// before the cooldown.
pub const refusal_limit: u32 = 5;
/// The window the refusals are counted in.
pub const window_ms: i64 = 60 * std.time.ms_per_s;
/// How long every MERGE naming the label is refused once the limit is passed.
pub const cooldown_ms: i64 = 5 * 60 * std.time.ms_per_s;
/// The (graph, label) pairs one session tracks; past it the entry whose
/// window started first (and is not cooling down) makes room.
pub const max_tracked: usize = 256;

/// The pseudo-label a pattern node with no label counts under: no label is
/// empty, so it cannot collide with one.
pub const no_label: []const u8 = "";

/// The monotonic clock the limiter is driven by, in ms.
pub fn nowMs() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(i64, ts.sec) * std.time.ms_per_s + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

const Entry = struct {
    window_start_ms: i64,
    count: u32,
    /// The cooldown ends here; 0 when none runs.
    blocked_until_ms: i64 = 0,
};

pub const MergeRefusalLimiter = struct {
    allocator: std.mem.Allocator,
    /// Key: graph ++ "\x00" ++ label, owned.
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    /// A leaf: held only for the map, never while taking another lock.
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    pub fn init(allocator: std.mem.Allocator) MergeRefusalLimiter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MergeRefusalLimiter) void {
        var it = self.entries.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.entries.deinit(self.allocator);
    }

    fn lock(self: *MergeRefusalLimiter) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    }

    fn unlock(self: *MergeRefusalLimiter) void {
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    }

    fn keyBuf(buf: []u8, graph: []const u8, label: []const u8) ?[]const u8 {
        if (graph.len + 1 + label.len > buf.len) return null;
        @memcpy(buf[0..graph.len], graph);
        buf[graph.len] = 0;
        @memcpy(buf[graph.len + 1 ..][0..label.len], label);
        return buf[0 .. graph.len + 1 + label.len];
    }

    /// Is a cooldown running for `label` on `graph` at `now_ms`? A key too
    /// long to track is never limited (it was never counted either).
    pub fn isLimited(self: *MergeRefusalLimiter, graph: []const u8, label: []const u8, now_ms: i64) bool {
        var buf: [512]u8 = undefined;
        const key = keyBuf(&buf, graph, label) orelse return false;
        self.lock();
        defer self.unlock();
        const e = self.entries.getPtr(key) orelse return false;
        if (e.blocked_until_ms == 0) return false;
        if (now_ms < e.blocked_until_ms) return true;
        // Over: a fresh window.
        e.* = .{ .window_start_ms = now_ms, .count = 0 };
        return false;
    }

    /// Count a refusal on `label` of `graph` at `now_ms`. True when this one
    /// passed the limit and started the cooldown. A new pair that cannot be
    /// stored (allocation failure) is not counted; the refusal itself stands.
    pub fn noteRefusal(self: *MergeRefusalLimiter, graph: []const u8, label: []const u8, now_ms: i64) bool {
        var buf: [512]u8 = undefined;
        const key = keyBuf(&buf, graph, label) orelse return false;
        self.lock();
        defer self.unlock();
        if (self.entries.getPtr(key)) |e| return bump(e, now_ms);
        if (self.entries.count() >= max_tracked) self.evictOneLocked();
        const owned = self.allocator.dupe(u8, key) catch return false;
        self.entries.put(self.allocator, owned, .{ .window_start_ms = now_ms, .count = 0 }) catch {
            self.allocator.free(owned);
            return false;
        };
        return bump(self.entries.getPtr(owned).?, now_ms);
    }

    fn bump(e: *Entry, now_ms: i64) bool {
        if (e.blocked_until_ms != 0 and now_ms < e.blocked_until_ms) return false;
        if (e.blocked_until_ms != 0 or now_ms - e.window_start_ms >= window_ms) {
            e.* = .{ .window_start_ms = now_ms, .count = 0 };
        }
        e.count += 1;
        if (e.count >= refusal_limit) {
            e.blocked_until_ms = now_ms + cooldown_ms;
            return true;
        }
        return false;
    }

    /// Make room: drop the entry whose window started first among those not
    /// cooling down (a cooldown is never dropped early); with every entry
    /// cooling down, the one whose cooldown ends first.
    fn evictOneLocked(self: *MergeRefusalLimiter) void {
        var victim: ?[]const u8 = null;
        var victim_rank: i64 = std.math.maxInt(i64);
        var victim_blocked = true;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const blocked = kv.value_ptr.blocked_until_ms != 0;
            const rank = if (blocked) kv.value_ptr.blocked_until_ms else kv.value_ptr.window_start_ms;
            if ((victim_blocked and !blocked) or (blocked == victim_blocked and rank < victim_rank)) {
                victim = kv.key_ptr.*;
                victim_rank = rank;
                victim_blocked = blocked;
            }
        }
        if (victim) |k| {
            _ = self.entries.remove(k);
            self.allocator.free(k);
        }
    }
};
