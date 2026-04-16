const std = @import("std");

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const Allocator = std.mem.Allocator;
const prometheus = @import("prometheus.zig");
const pooled = @import("transport/thread_pool");

// CANARY: REQ=REQ-PROMETHEUS-WIRE-001; FEATURE="Prometheus Metrics Endpoint"; ASPECT=HTTPServer; STATUS=TESTED; TEST=geodetestlab/specs/gap_0166_prometheus_metrics.yml; OWNER=monitoring; UPDATED=2026-01-14
// GAP-0166: Wire Prometheus metrics exporter to runtime endpoint
// Simple HTTP server for serving Prometheus metrics at /metrics endpoint

/// MetricsServer provides an HTTP endpoint for Prometheus metrics scraping
pub const MetricsServer = struct {
    allocator: Allocator,
    collector: *prometheus.MetricsCollector,
    port: u16,
    server: ?std.Io.net.Server,
    running: bool,
    accept_pool: ?*pooled.ThreadPool,

    pub fn init(allocator: Allocator, collector: *prometheus.MetricsCollector, port: u16) MetricsServer {
        return .{
            .allocator = allocator,
            .collector = collector,
            .port = port,
            .server = null,
            .running = false,
            .accept_pool = null,
        };
    }

    pub fn deinit(self: *MetricsServer) void {
        self.stop();
    }

    /// Start the metrics HTTP server.
    /// SECURITY (S10): Binds to 127.0.0.1 by default to prevent unauthenticated
    /// metrics scraping from the network.  Override with GEODE_METRICS_BIND env var
    /// (e.g. "0.0.0.0" to restore the old behavior behind a firewall).
    pub fn start(self: *MetricsServer) !void {
        // Zig 0.16 compat: the metrics HTTP server is temporarily disabled
        // pending a full rewrite against std.Io.net.Server.
        _ = resolveMetricsBindAddress();
        self.running = false;
    }

    /// Stop the metrics HTTP server
    pub fn stop(self: *MetricsServer) void {
        self.running = false;
        self.server = null;
        if (self.accept_pool) |pool| {
            pool.deinit();
            self.accept_pool = null;
        }
    }

    /// Handle a single incoming connection.
    /// Zig 0.16 compat: stubbed until std.Io.net.Server.Connection wiring is reimplemented.
    pub fn handleConnection(self: *MetricsServer, conn: std.Io.net.Server.Connection) !void {
        _ = self;
        _ = conn;
    }

    /// Serve Prometheus metrics - stub.
    fn serveMetrics(self: *MetricsServer, stream: std.Io.net.Stream) !void {
        _ = self;
        _ = stream;
    }

    /// Serve health check response - stub.
    fn serveHealth(self: *MetricsServer, stream: std.Io.net.Stream) !void {
        _ = self;
        _ = stream;
    }

    /// Serve 404 response - stub.
    fn serve404(self: *MetricsServer, stream: std.Io.net.Stream) !void {
        _ = self;
        _ = stream;
    }

    /// Accept and handle connections - stub (disabled until net rewrite).
    pub fn acceptLoop(self: *MetricsServer) void {
        _ = self;
    }

    fn runAcceptLoop(ctx: *anyopaque) void {
        const self: *MetricsServer = @ptrCast(@alignCast(ctx));
        self.acceptLoop();
    }
};

/// Resolve the metrics bind address from GEODE_METRICS_BIND env var,
/// defaulting to 127.0.0.1 (localhost only).
fn resolveMetricsBindAddress() [4]u8 {
    var gpa_alloc = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_alloc.deinit();
    const alloc = gpa_alloc.allocator();
    const env_val = getEnvVarOwned(alloc, "GEODE_METRICS_BIND") catch null;
    defer if (env_val) |v| alloc.free(v);
    if (env_val) |val| {
        return parseIp4Addr(val) orelse .{ 127, 0, 0, 1 };
    }
    return .{ 127, 0, 0, 1 };
}

/// Parse a dotted-quad IPv4 string into a 4-byte array, or null on failure.
fn parseIp4Addr(s: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var octet_idx: usize = 0;
    var seg_start: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '.') {
            if (octet_idx >= 3) return null;
            result[octet_idx] = std.fmt.parseInt(u8, s[seg_start..i], 10) catch return null;
            octet_idx += 1;
            seg_start = i + 1;
        }
    }
    if (octet_idx != 3) return null;
    result[3] = std.fmt.parseInt(u8, s[seg_start..], 10) catch return null;
    return result;
}

// CANARY: REQ=REQ-PROMETHEUS-WIRE-002; FEATURE="Prometheus Metrics Endpoint"; ASPECT=GlobalCollector; STATUS=TESTED; TEST=geodetestlab/specs/gap_0166_prometheus_metrics.yml; OWNER=monitoring; UPDATED=2026-01-14
// Global metrics collector for the server
var g_metrics_collector: ?*prometheus.MetricsCollector = null;
var g_metrics_server: ?*MetricsServer = null;

/// Initialize global metrics with a collector and optional HTTP server
pub fn initGlobalMetrics(allocator: Allocator, port: ?u16) !*prometheus.MetricsCollector {
    if (g_metrics_collector != null) return g_metrics_collector.?;

    const collector = try allocator.create(prometheus.MetricsCollector);
    collector.* = try prometheus.MetricsCollector.init(allocator);
    g_metrics_collector = collector;

    // Start HTTP server if port specified
    if (port) |p| {
        const server = try allocator.create(MetricsServer);
        server.* = MetricsServer.init(allocator, collector, p);
        try server.start();
        g_metrics_server = server;
    }

    return collector;
}

/// Get the global metrics collector (may be null if not initialized)
pub fn getGlobalMetrics() ?*prometheus.MetricsCollector {
    return g_metrics_collector;
}

/// Shutdown global metrics
pub fn shutdownGlobalMetrics(allocator: Allocator) void {
    if (g_metrics_server) |server| {
        server.deinit();
        allocator.destroy(server);
        g_metrics_server = null;
    }
    if (g_metrics_collector) |collector| {
        collector.deinit();
        allocator.destroy(collector);
        g_metrics_collector = null;
    }
}

// Unit tests
test "MetricsServer initialization" {
    const allocator = std.testing.allocator;

    var collector = try prometheus.MetricsCollector.init(allocator);
    defer collector.deinit();

    var server = MetricsServer.init(allocator, &collector, 9091);
    defer server.deinit();

    // Just test initialization, not actual network operations
    try std.testing.expect(server.port == 9091);
    try std.testing.expect(server.running == false);
}
