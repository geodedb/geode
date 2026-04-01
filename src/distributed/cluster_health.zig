const std = @import("std");
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
            .health_checks = std.ArrayList(HealthCheck).init(allocator),
        };
    }

    pub fn deinit(self: *HealthMonitor) void {
        self.health_checks.deinit();
    }

    /// Evaluate a node's health based on its last heartbeat timestamp.
    pub fn evaluateNodeHealth(last_heartbeat: i64) HealthStatus {
        const now = std.time.milliTimestamp();
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
                check.last_check = std.time.milliTimestamp();
                return;
            }
        }

        try self.health_checks.append(.{
            .node_id = node_id,
            .consecutive_failures = 0,
            .last_check = std.time.milliTimestamp(),
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
