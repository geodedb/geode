// CANARY: REQ=REQ-MULTI-TENANT-QUOTA-001; FEATURE="PerTenantResourceQuotas"; ASPECT=QuotaManager; STATUS=TESTED; TEST=src/security/tenant_quota.zig; OWNER=security; UPDATED=2026-04-01
// GAP-0289: Per-tenant resource quotas with connection and query limits.
// Prevents a single tenant from exhausting server resources (connections, memory,
// query concurrency), protecting multi-tenant deployments from noisy-neighbour DoS.

const std = @import("std");

const logging = @import("logging");
const log = logging.scoped("quota");
const Attr = logging.Attr;

/// Per-tenant resource quota configuration.
/// Default values are generous so single-tenant deployments are unaffected.
pub const TenantQuota = struct {
    max_connections: u32 = 100,
    max_concurrent_queries: u32 = 32,
    max_graphs: u32 = 100,
    max_nodes_per_graph: u64 = 1_000_000,
};

/// Live usage counters for a tenant. Tracked with atomics for lock-free hot-path.
pub const TenantUsage = struct {
    active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    active_queries: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

pub const QuotaError = error{
    ConnectionQuotaExceeded,
    QueryQuotaExceeded,
};

/// Manages per-tenant resource quotas and usage tracking.
///
/// Thread-safety:
///   - `mu` protects the `quotas` and `usage` maps (structural mutations).
///   - Once a `TenantUsage` pointer is obtained under `mu`, the atomic
///     fields can be read/written lock-free.
pub const TenantQuotaManager = struct {
    allocator: std.mem.Allocator,
    quotas: std.StringHashMapUnmanaged(TenantQuota),
    usage: std.StringHashMapUnmanaged(*TenantUsage),
    mu: std.Io.Mutex,
    default_quota: TenantQuota,

    pub fn init(allocator: std.mem.Allocator) TenantQuotaManager {
        return .{
            .allocator = allocator,
            .quotas = .empty,
            .usage = .empty,
            .mu = .init,
            .default_quota = .{},
        };
    }

    pub fn deinit(self: *TenantQuotaManager) void {
        // Free all owned keys and usage structs.
        var usage_iter = self.usage.iterator();
        while (usage_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.usage.deinit(self.allocator);

        var quota_iter = self.quotas.iterator();
        while (quota_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.quotas.deinit(self.allocator);
    }

    // ── Quota management ──────────────────────────────────────────────────

    /// Set (or update) the quota for a tenant.
    pub fn setQuota(self: *TenantQuotaManager, tenant_id: []const u8, quota: TenantQuota) !void {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        const result = self.quotas.getOrPut(self.allocator, tenant_id) catch return error.OutOfMemory;
        if (!result.found_existing) {
            result.key_ptr.* = self.allocator.dupe(u8, tenant_id) catch return error.OutOfMemory;
        }
        result.value_ptr.* = quota;
    }

    /// Return the effective quota for a tenant (explicit or default).
    pub fn getQuota(self: *TenantQuotaManager, tenant_id: []const u8) TenantQuota {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.quotas.get(tenant_id) orelse self.default_quota;
    }

    /// Return the current live usage counters for a tenant (zero if none tracked yet).
    pub fn getUsage(self: *TenantQuotaManager, tenant_id: []const u8) struct { connections: u32, queries: u32 } {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        if (self.usage.get(tenant_id)) |u| {
            return .{
                .connections = u.active_connections.load(.monotonic),
                .queries = u.active_queries.load(.monotonic),
            };
        }
        return .{ .connections = 0, .queries = 0 };
    }

    // ── Connection quota ──────────────────────────────────────────────────

    /// Attempt to acquire a connection slot for a tenant.
    /// Returns `QuotaError.ConnectionQuotaExceeded` if the tenant is at limit.
    pub fn acquireConnection(self: *TenantQuotaManager, tenant_id: []const u8) QuotaError!void {
        const quota = blk: {
            self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk self.quotas.get(tenant_id) orelse self.default_quota;
        };
        const u = self.getOrCreateUsage(tenant_id) catch return QuotaError.ConnectionQuotaExceeded;

        // CAS loop: increment only if below quota.
        while (true) {
            const current = u.active_connections.load(.monotonic);
            if (current >= quota.max_connections) {
                log.warn("Connection quota exceeded", &.{
                    Attr.string("tenant", tenant_id),
                    Attr.int("current", @intCast(current)),
                    Attr.int("max", @intCast(quota.max_connections)),
                });
                return QuotaError.ConnectionQuotaExceeded;
            }
            if (u.active_connections.cmpxchgWeak(current, current + 1, .monotonic, .monotonic) == null) {
                return; // success
            }
            // Lost race — retry.
        }
    }

    /// Release a connection slot for a tenant.
    pub fn releaseConnection(self: *TenantQuotaManager, tenant_id: []const u8) void {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        const u = self.usage.get(tenant_id);
        self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        if (u) |usage| {
            const prev = usage.active_connections.fetchSub(1, .monotonic);
            if (prev == 0) {
                // Should never happen — log but don't underflow.
                log.warn("Connection counter underflow for tenant", &.{
                    Attr.string("tenant", tenant_id),
                });
                _ = usage.active_connections.fetchAdd(1, .monotonic); // undo
            }
        }
    }

    /// Check (without acquiring) whether a connection can be opened.
    pub fn checkConnectionQuota(self: *TenantQuotaManager, tenant_id: []const u8) bool {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        const quota = self.quotas.get(tenant_id) orelse self.default_quota;
        const u = self.usage.get(tenant_id) orelse return true;
        return u.active_connections.load(.monotonic) < quota.max_connections;
    }

    // ── Query quota ───────────────────────────────────────────────────────

    /// Attempt to acquire a query execution slot for a tenant.
    /// Returns `QuotaError.QueryQuotaExceeded` if the tenant is at limit.
    pub fn acquireQuery(self: *TenantQuotaManager, tenant_id: []const u8) QuotaError!void {
        const quota = blk: {
            self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk self.quotas.get(tenant_id) orelse self.default_quota;
        };
        const u = self.getOrCreateUsage(tenant_id) catch return QuotaError.QueryQuotaExceeded;

        while (true) {
            const current = u.active_queries.load(.monotonic);
            if (current >= quota.max_concurrent_queries) {
                log.warn("Query quota exceeded", &.{
                    Attr.string("tenant", tenant_id),
                    Attr.int("current", @intCast(current)),
                    Attr.int("max", @intCast(quota.max_concurrent_queries)),
                });
                return QuotaError.QueryQuotaExceeded;
            }
            if (u.active_queries.cmpxchgWeak(current, current + 1, .monotonic, .monotonic) == null) {
                return;
            }
        }
    }

    /// Release a query execution slot for a tenant.
    pub fn releaseQuery(self: *TenantQuotaManager, tenant_id: []const u8) void {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        const u = self.usage.get(tenant_id);
        self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        if (u) |usage| {
            const prev = usage.active_queries.fetchSub(1, .monotonic);
            if (prev == 0) {
                log.warn("Query counter underflow for tenant", &.{
                    Attr.string("tenant", tenant_id),
                });
                _ = usage.active_queries.fetchAdd(1, .monotonic);
            }
        }
    }

    /// Check (without acquiring) whether a query can be started.
    pub fn checkQueryQuota(self: *TenantQuotaManager, tenant_id: []const u8) bool {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        const quota = self.quotas.get(tenant_id) orelse self.default_quota;
        const u = self.usage.get(tenant_id) orelse return true;
        return u.active_queries.load(.monotonic) < quota.max_concurrent_queries;
    }

    // ── Internal ──────────────────────────────────────────────────────────

    /// Return (or create) the usage entry for a tenant, allocating under `mu`.
    fn getOrCreateUsage(self: *TenantQuotaManager, tenant_id: []const u8) !*TenantUsage {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        const result = self.usage.getOrPut(self.allocator, tenant_id) catch return error.OutOfMemory;
        if (!result.found_existing) {
            const key_copy = self.allocator.dupe(u8, tenant_id) catch return error.OutOfMemory;
            const usage_ptr = self.allocator.create(TenantUsage) catch {
                self.allocator.free(key_copy);
                return error.OutOfMemory;
            };
            usage_ptr.* = .{};
            result.key_ptr.* = key_copy;
            result.value_ptr.* = usage_ptr;
        }
        return result.value_ptr.*;
    }
};

// ── Global singleton ──────────────────────────────────────────────────────────
// The global quota manager is initialised once at server startup and lives for
// the duration of the process. Connection handlers and query executors access it
// via `getGlobalQuotaManager()`.

var g_global_quota_manager: ?*TenantQuotaManager = null;

pub fn setGlobalQuotaManager(mgr: ?*TenantQuotaManager) void {
    g_global_quota_manager = mgr;
}

pub fn getGlobalQuotaManager() ?*TenantQuotaManager {
    return g_global_quota_manager;
}

// ============================================================================
// Tests
// ============================================================================

test "TenantQuotaManager: default quota applies when no explicit quota set" {
    var mgr = TenantQuotaManager.init(std.testing.allocator);
    defer mgr.deinit();

    const q = mgr.getQuota("tenant-A");
    try std.testing.expectEqual(@as(u32, 100), q.max_connections);
    try std.testing.expectEqual(@as(u32, 32), q.max_concurrent_queries);
}

test "TenantQuotaManager: setQuota and getQuota" {
    var mgr = TenantQuotaManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.setQuota("tenant-B", .{
        .max_connections = 5,
        .max_concurrent_queries = 2,
        .max_graphs = 10,
        .max_nodes_per_graph = 500,
    });

    const q = mgr.getQuota("tenant-B");
    try std.testing.expectEqual(@as(u32, 5), q.max_connections);
    try std.testing.expectEqual(@as(u32, 2), q.max_concurrent_queries);
    try std.testing.expectEqual(@as(u32, 10), q.max_graphs);
    try std.testing.expectEqual(@as(u64, 500), q.max_nodes_per_graph);
}

test "TenantQuotaManager: acquire and release connections within quota" {
    var mgr = TenantQuotaManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.setQuota("t1", .{ .max_connections = 3, .max_concurrent_queries = 32 });

    try mgr.acquireConnection("t1");
    try mgr.acquireConnection("t1");
    try mgr.acquireConnection("t1");

    const usage = mgr.getUsage("t1");
    try std.testing.expectEqual(@as(u32, 3), usage.connections);

    // Fourth should fail
    try std.testing.expectError(QuotaError.ConnectionQuotaExceeded, mgr.acquireConnection("t1"));

    // Release one, then acquire again
    mgr.releaseConnection("t1");
    try mgr.acquireConnection("t1");

    // Clean up
    mgr.releaseConnection("t1");
    mgr.releaseConnection("t1");
    mgr.releaseConnection("t1");
}

test "TenantQuotaManager: acquire and release queries within quota" {
    var mgr = TenantQuotaManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.setQuota("t2", .{ .max_connections = 100, .max_concurrent_queries = 2 });

    try mgr.acquireQuery("t2");
    try mgr.acquireQuery("t2");

    try std.testing.expectError(QuotaError.QueryQuotaExceeded, mgr.acquireQuery("t2"));

    mgr.releaseQuery("t2");
    try mgr.acquireQuery("t2");

    mgr.releaseQuery("t2");
    mgr.releaseQuery("t2");
}

test "TenantQuotaManager: checkConnectionQuota without acquiring" {
    var mgr = TenantQuotaManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.setQuota("t3", .{ .max_connections = 1, .max_concurrent_queries = 32 });

    try std.testing.expect(mgr.checkConnectionQuota("t3"));
    try mgr.acquireConnection("t3");
    try std.testing.expect(!mgr.checkConnectionQuota("t3"));
    mgr.releaseConnection("t3");
    try std.testing.expect(mgr.checkConnectionQuota("t3"));
}

test "TenantQuotaManager: checkQueryQuota without acquiring" {
    var mgr = TenantQuotaManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.setQuota("t4", .{ .max_connections = 100, .max_concurrent_queries = 1 });

    try std.testing.expect(mgr.checkQueryQuota("t4"));
    try mgr.acquireQuery("t4");
    try std.testing.expect(!mgr.checkQueryQuota("t4"));
    mgr.releaseQuery("t4");
    try std.testing.expect(mgr.checkQueryQuota("t4"));
}

test "TenantQuotaManager: unknown tenant uses default quota" {
    var mgr = TenantQuotaManager.init(std.testing.allocator);
    defer mgr.deinit();

    // Default allows 100 connections — just verify one works
    try mgr.acquireConnection("unknown-tenant");
    const usage = mgr.getUsage("unknown-tenant");
    try std.testing.expectEqual(@as(u32, 1), usage.connections);
    mgr.releaseConnection("unknown-tenant");
}

test "TenantQuotaManager: update existing quota" {
    var mgr = TenantQuotaManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.setQuota("t5", .{ .max_connections = 2, .max_concurrent_queries = 1 });
    try mgr.acquireConnection("t5");
    try mgr.acquireConnection("t5");
    try std.testing.expectError(QuotaError.ConnectionQuotaExceeded, mgr.acquireConnection("t5"));

    // Increase quota
    try mgr.setQuota("t5", .{ .max_connections = 5, .max_concurrent_queries = 1 });
    try mgr.acquireConnection("t5"); // should succeed now
    mgr.releaseConnection("t5");
    mgr.releaseConnection("t5");
    mgr.releaseConnection("t5");
}

test "TenantQuotaManager: concurrent acquire/release is thread-safe" {
    var mgr = TenantQuotaManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.setQuota("concurrent", .{ .max_connections = 1000, .max_concurrent_queries = 1000 });

    const num_threads = 8;
    const ops_per_thread = 100;

    var threads: [num_threads]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(m: *TenantQuotaManager) void {
                for (0..ops_per_thread) |_| {
                    m.acquireConnection("concurrent") catch {};
                    m.acquireQuery("concurrent") catch {};
                    m.releaseQuery("concurrent");
                    m.releaseConnection("concurrent");
                }
            }
        }.run, .{&mgr});
    }

    for (&threads) |*t| t.join();

    // After all threads complete, usage should be back to zero.
    const usage = mgr.getUsage("concurrent");
    try std.testing.expectEqual(@as(u32, 0), usage.connections);
    try std.testing.expectEqual(@as(u32, 0), usage.queries);
}
