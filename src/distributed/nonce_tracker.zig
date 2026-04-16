const std = @import("std");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        _ = std.c.getrandom(buf.ptr, buf.len, 0);
    }
}

// CANARY: REQ=REQ-SEC-NONCE-001; FEATURE="Nonce Replay Protection"; ASPECT=NonceTracker; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
// SEC-D009: Ring-buffer backed nonce tracker for replay protection on Raft frames.
// Provides O(1) lookup via a HashSet and bounded memory via a ring buffer that
// evicts the oldest nonce when capacity is reached.

/// Thread-safe nonce tracker with bounded memory.
/// Uses a ring buffer of capacity `max_nonces` and a HashSet for O(1) lookup.
pub const NonceTracker = struct {
    mu: std.Io.Mutex = std.Io.Mutex.init,
    ring: []u64,
    seen: std.AutoHashMap(u64, void),
    head: usize = 0,
    count: usize = 0,
    capacity: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, max_nonces: usize) !Self {
        const cap = @max(max_nonces, 1);
        const ring = try allocator.alloc(u64, cap);
        @memset(ring, 0);
        return .{
            .ring = ring,
            .seen = std.AutoHashMap(u64, void).init(allocator),
            .capacity = cap,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.seen.deinit();
        self.allocator.free(self.ring);
    }

    /// Check if a nonce has been seen before. If not, record it and return true (valid).
    /// If already seen, return false (replay detected). A nonce of 0 is always rejected
    /// (indicates an uninitialized or legacy frame).
    pub fn checkAndRecord(self: *Self, nonce: u64) bool {
        if (nonce == 0) return false;

        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        // Already seen => replay.
        if (self.seen.contains(nonce)) return false;

        // If ring is full, evict the oldest entry.
        if (self.count == self.capacity) {
            const old_nonce = self.ring[self.head];
            if (old_nonce != 0) {
                _ = self.seen.remove(old_nonce);
            }
        } else {
            self.count += 1;
        }

        // Record new nonce.
        self.ring[self.head] = nonce;
        self.seen.put(nonce, {}) catch return false;
        self.head = (self.head + 1) % self.capacity;

        return true;
    }

    /// Generate a cryptographically random nonce suitable for embedding in a frame.
    pub fn generateNonce() u64 {
        return blk: {
            var _rng_buf: [@sizeOf(u64)]u8 = undefined;
            compat_fillRandom(&_rng_buf);
            break :blk std.mem.readInt(u64, &_rng_buf, .little);
        };
    }
};

// ---- Tests ----

test "NonceTracker: basic checkAndRecord" {
    const ally = std.testing.allocator;
    var tracker = try NonceTracker.init(ally, 100);
    defer tracker.deinit();

    // First time seeing nonce 42 => valid.
    try std.testing.expect(tracker.checkAndRecord(42));
    // Second time seeing nonce 42 => replay.
    try std.testing.expect(!tracker.checkAndRecord(42));
    // Different nonce => valid.
    try std.testing.expect(tracker.checkAndRecord(43));
}

test "NonceTracker: rejects zero nonce" {
    const ally = std.testing.allocator;
    var tracker = try NonceTracker.init(ally, 10);
    defer tracker.deinit();

    try std.testing.expect(!tracker.checkAndRecord(0));
}

test "NonceTracker: ring buffer eviction" {
    const ally = std.testing.allocator;
    // Small capacity to trigger eviction.
    var tracker = try NonceTracker.init(ally, 3);
    defer tracker.deinit();

    try std.testing.expect(tracker.checkAndRecord(1));
    try std.testing.expect(tracker.checkAndRecord(2));
    try std.testing.expect(tracker.checkAndRecord(3));
    // Ring is full (contains [1,2,3]). Adding 4 evicts oldest (1).
    try std.testing.expect(tracker.checkAndRecord(4));
    // Nonce 1 was evicted, so it should be accepted again.
    // This also evicts the next oldest (2).
    try std.testing.expect(tracker.checkAndRecord(1));
    // Nonce 3 should still be tracked.
    try std.testing.expect(!tracker.checkAndRecord(3));
    // Nonce 4 should still be tracked.
    try std.testing.expect(!tracker.checkAndRecord(4));
    // Nonce 2 was evicted by the insert of 1, so it should be accepted.
    try std.testing.expect(tracker.checkAndRecord(2));
}

test "NonceTracker: generateNonce produces nonzero values" {
    // It is statistically impossible for a 64-bit random to be 0 twice.
    var nonzero_count: usize = 0;
    for (0..10) |_| {
        const n = NonceTracker.generateNonce();
        if (n != 0) nonzero_count += 1;
    }
    try std.testing.expect(nonzero_count >= 9);
}
