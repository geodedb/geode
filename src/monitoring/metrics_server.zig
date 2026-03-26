const std = @import("std");
const Allocator = std.mem.Allocator;
const prometheus = @import("prometheus.zig");

// CANARY: REQ=REQ-PROMETHEUS-WIRE-001; FEATURE="Prometheus Metrics Endpoint"; ASPECT=HTTPServer; STATUS=TESTED; TEST=geodetestlab/specs/gap_0166_prometheus_metrics.yml; OWNER=monitoring; UPDATED=2026-01-14
// GAP-0166: Wire Prometheus metrics exporter to runtime endpoint
// Simple HTTP server for serving Prometheus metrics at /metrics endpoint

/// MetricsServer provides an HTTP endpoint for Prometheus metrics scraping
pub const MetricsServer = struct {
    allocator: Allocator,
    collector: *prometheus.MetricsCollector,
    port: u16,
    server: ?std.net.Server,
    running: bool,

    pub fn init(allocator: Allocator, collector: *prometheus.MetricsCollector, port: u16) MetricsServer {
        return .{
            .allocator = allocator,
            .collector = collector,
            .port = port,
            .server = null,
            .running = false,
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
        const bind_addr = resolveMetricsBindAddress();
        const address = std.net.Address.initIp4(bind_addr, self.port);
        self.server = try address.listen(.{
            .reuse_address = true,
        });
        self.running = true;
    }

    /// Stop the metrics HTTP server
    pub fn stop(self: *MetricsServer) void {
        self.running = false;
        if (self.server) |*s| {
            s.deinit();
            self.server = null;
        }
    }

    /// Handle a single incoming connection
    pub fn handleConnection(self: *MetricsServer, conn: std.net.Server.Connection) !void {
        defer conn.stream.close();

        // Read HTTP request (minimal parsing)
        var buf: [4096]u8 = undefined;
        const bytes_read = conn.stream.read(&buf) catch return;
        if (bytes_read == 0) return;

        const request = buf[0..bytes_read];

        // Check if this is a GET /metrics request
        if (std.mem.startsWith(u8, request, "GET /metrics")) {
            try self.serveMetrics(conn.stream);
        } else if (std.mem.startsWith(u8, request, "GET /health") or std.mem.startsWith(u8, request, "GET /ready")) {
            // Health check endpoint
            try self.serveHealth(conn.stream);
        } else {
            // Return 404 for other paths
            try self.serve404(conn.stream);
        }
    }

    /// Serve Prometheus metrics
    fn serveMetrics(self: *MetricsServer, stream: std.net.Stream) !void {
        var body = std.ArrayList(u8){};
        defer body.deinit(self.allocator);

        try self.collector.exportMetrics(body.writer(self.allocator));

        const body_slice = body.items;

        // Build HTTP response
        var response = std.ArrayList(u8){};
        defer response.deinit(self.allocator);

        try response.writer(self.allocator).print(
            "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Connection: close\r\n" ++
                "\r\n",
            .{body_slice.len},
        );
        try response.appendSlice(self.allocator, body_slice);

        _ = stream.write(response.items) catch {};
    }

    /// Serve health check response
    fn serveHealth(self: *MetricsServer, stream: std.net.Stream) !void {
        _ = self;
        const response =
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: 15\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{\"status\":\"ok\"}";
        _ = stream.write(response) catch {};
    }

    /// Serve 404 response
    fn serve404(self: *MetricsServer, stream: std.net.Stream) !void {
        _ = self;
        const response =
            "HTTP/1.1 404 Not Found\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: 9\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "Not Found";
        _ = stream.write(response) catch {};
    }

    /// Accept and handle connections (run in a separate thread)
    pub fn acceptLoop(self: *MetricsServer) void {
        while (self.running) {
            if (self.server) |*s| {
                const conn = s.accept() catch continue;
                self.handleConnection(conn) catch continue;
            } else {
                break;
            }
        }
    }
};

/// Resolve the metrics bind address from GEODE_METRICS_BIND env var,
/// defaulting to 127.0.0.1 (localhost only).
fn resolveMetricsBindAddress() [4]u8 {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_alloc.deinit();
    const alloc = gpa_alloc.allocator();
    const env_val = std.process.getEnvVarOwned(alloc, "GEODE_METRICS_BIND") catch null;
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

        // Start accept loop in a new thread
        _ = std.Thread.spawn(.{}, struct {
            fn run(s: *MetricsServer) void {
                s.acceptLoop();
            }
        }.run, .{server}) catch {};
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
