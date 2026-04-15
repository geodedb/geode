const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const Allocator = std.mem.Allocator;

const logging = @import("logging");
const log = logging.scoped("cluster");
const Attr = logging.Attr;

/// Health monitoring subsystem for distributed cluster nodes.
pub const HealthMonitor = struct {
    allocator: Allocator,
    check_interval_ms: u64,
    unhealthy_threshold: u32,
    health_checks: std.ArrayList(HealthCheck),

    pub const HealthCheck = struct {
        node_id: u64,
        consecutive_failures: u32,
        last_check: i64,
        latency_ms: u64,
        status: HealthStatus,
    };

    pub const HealthStatus = enum {
        healthy,
        degraded,
        unhealthy,
        unknown,
    };

    pub fn init(allocator: Allocator, check_interval_ms: u64, unhealthy_threshold: u32) HealthMonitor {
        return HealthMonitor{
            .allocator = allocator,
            .check_interval_ms = check_interval_ms,
            .unhealthy_threshold = unhealthy_threshold,
            .health_checks = std.ArrayList(HealthCheck).empty,
        };
    }

    pub fn deinit(self: *HealthMonitor) void {
        self.health_checks.deinit(self.allocator);
    }

    /// Evaluate a node's health based on its last heartbeat timestamp.
    pub fn evaluateNodeHealth(last_heartbeat: i64) HealthStatus {
        const now = compat_milliTimestamp();
        const elapsed = now - last_heartbeat;

        if (elapsed < 1000) return .healthy;
        if (elapsed < 5000) return .degraded;
        return .unhealthy;
    }

    /// Update or insert a health check record for a node.
    pub fn updateHealthStatus(self: *HealthMonitor, node_id: u64, status: HealthStatus) !void {
        for (self.health_checks.items) |*check| {
            if (check.node_id == node_id) {
                check.status = status;
                check.last_check = compat_milliTimestamp();
                return;
            }
        }

        try self.health_checks.append(self.allocator, .{
            .node_id = node_id,
            .consecutive_failures = 0,
            .last_check = compat_milliTimestamp(),
            .latency_ms = 0,
            .status = status,
        });
    }

    /// Estimate replication lag for a node/shard pair based on health-check latency.
    pub fn estimateReplicationLag(self: *HealthMonitor, node_id: u64, shard_size_bytes: u64) u64 {
        for (self.health_checks.items) |check| {
            if (check.node_id == node_id) {
                // Lag estimated based on network latency and shard size
                // Formula: latency_ms * (shard_size_bytes / 1MB) as estimate
                const size_factor = @max(1, shard_size_bytes / (1024 * 1024));
                return check.latency_ms * size_factor;
            }
        }
        // If no health check found, return 0 (assume in sync)
        return 0;
    }
};

// CANARY: REQ=REQ-GAP-0513-DIST-HEALTH-001; FEATURE="ClusterHealth"; ASPECT=evaluateNodeHealth; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-06
// CANARY: REQ=REQ-GAP-0513-DIST-HEALTH-002; FEATURE="ClusterHealth"; ASPECT=updateHealthStatus; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-06
// CANARY: REQ=REQ-GAP-0513-DIST-HEALTH-003; FEATURE="ClusterHealth"; ASPECT=estimateReplicationLag; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-06

test "HealthMonitor.evaluateNodeHealth: healthy when elapsed < 1000ms" {
    const now = compat_milliTimestamp();
    const last_heartbeat = now - 500;
    const status = HealthMonitor.evaluateNodeHealth(last_heartbeat);
    try std.testing.expectEqual(HealthMonitor.HealthStatus.healthy, status);
}

test "HealthMonitor.evaluateNodeHealth: degraded when elapsed 1000-5000ms" {
    const now = compat_milliTimestamp();
    const last_heartbeat = now - 2000;
    const status = HealthMonitor.evaluateNodeHealth(last_heartbeat);
    try std.testing.expectEqual(HealthMonitor.HealthStatus.degraded, status);
}

test "HealthMonitor.evaluateNodeHealth: unhealthy when elapsed > 5000ms" {
    const now = compat_milliTimestamp();
    const last_heartbeat = now - 10000;
    const status = HealthMonitor.evaluateNodeHealth(last_heartbeat);
    try std.testing.expectEqual(HealthMonitor.HealthStatus.unhealthy, status);
}

test "HealthMonitor.updateHealthStatus: insert new node grows list" {
    var hm = HealthMonitor.init(std.testing.allocator, 1000, 3);
    defer hm.deinit();

    try hm.updateHealthStatus(1, .healthy);
    try std.testing.expectEqual(@as(usize, 1), hm.health_checks.items.len);
    try std.testing.expectEqual(HealthMonitor.HealthStatus.healthy, hm.health_checks.items[0].status);
}

test "HealthMonitor.updateHealthStatus: update existing node keeps list same length" {
    var hm = HealthMonitor.init(std.testing.allocator, 1000, 3);
    defer hm.deinit();

    try hm.updateHealthStatus(1, .healthy);
    try std.testing.expectEqual(@as(usize, 1), hm.health_checks.items.len);

    try hm.updateHealthStatus(1, .degraded);
    try std.testing.expectEqual(@as(usize, 1), hm.health_checks.items.len);
    try std.testing.expectEqual(HealthMonitor.HealthStatus.degraded, hm.health_checks.items[0].status);
}

test "HealthMonitor.updateHealthStatus: insert second node grows list" {
    var hm = HealthMonitor.init(std.testing.allocator, 1000, 3);
    defer hm.deinit();

    try hm.updateHealthStatus(1, .healthy);
    try hm.updateHealthStatus(2, .unhealthy);
    try std.testing.expectEqual(@as(usize, 2), hm.health_checks.items.len);
    try std.testing.expectEqual(HealthMonitor.HealthStatus.unhealthy, hm.health_checks.items[1].status);
}

test "HealthMonitor.estimateReplicationLag: unknown node returns 0" {
    var hm = HealthMonitor.init(std.testing.allocator, 1000, 3);
    defer hm.deinit();

    const lag = hm.estimateReplicationLag(99, 1024 * 1024);
    try std.testing.expectEqual(@as(u64, 0), lag);
}

test "HealthMonitor.estimateReplicationLag: known node with latency_ms=10 and shard < 1MB returns 10" {
    var hm = HealthMonitor.init(std.testing.allocator, 1000, 3);
    defer hm.deinit();

    try hm.health_checks.append(std.testing.allocator, .{
        .node_id = 42,
        .consecutive_failures = 0,
        .last_check = compat_milliTimestamp(),
        .latency_ms = 10,
        .status = .healthy,
    });

    // shard_size_bytes < 1MB → size_factor = max(1, 0) = 1 → lag = 10 * 1 = 10
    const lag = hm.estimateReplicationLag(42, 512 * 1024);
    try std.testing.expectEqual(@as(u64, 10), lag);
}

test "HealthMonitor.estimateReplicationLag: known node with latency_ms=10 and 5MB shard returns 50" {
    var hm = HealthMonitor.init(std.testing.allocator, 1000, 3);
    defer hm.deinit();

    try hm.health_checks.append(std.testing.allocator, .{
        .node_id = 43,
        .consecutive_failures = 0,
        .last_check = compat_milliTimestamp(),
        .latency_ms = 10,
        .status = .healthy,
    });

    // shard_size_bytes = 5MB → size_factor = max(1, 5) = 5 → lag = 10 * 5 = 50
    const lag = hm.estimateReplicationLag(43, 5 * 1024 * 1024);
    try std.testing.expectEqual(@as(u64, 50), lag);
}
