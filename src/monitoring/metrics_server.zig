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

pub const RuntimeSnapshotCallback = *const fn (allocator: Allocator, ctx: *anyopaque) anyerror![]u8;

var g_runtime_snapshot_mu: std.Io.Mutex = std.Io.Mutex.init;
var g_runtime_snapshot_callback: ?RuntimeSnapshotCallback = null;
var g_runtime_snapshot_ctx: ?*anyopaque = null;

// CANARY: REQ=REQ-QUIC-HC-172; FEATURE="High-Concurrency Diagnostics"; ASPECT=RuntimeMetricsScrape; STATUS=IMPL; TEST=test_metrics_server_lifecycle; OWNER=monitoring; UPDATED=2026-05-29
//
// The QUIC high-concurrency ceiling work uses the lightweight
// runtime_metrics registry for transport and storage counters. Expose an
// optional append hook so /metrics can include those counters without making
// this monitoring module depend on the server module or duplicating the
// registry singleton.
pub fn setRuntimeSnapshotCallback(callback: ?RuntimeSnapshotCallback, ctx: ?*anyopaque) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    g_runtime_snapshot_mu.lockUncancelable(io);
    defer g_runtime_snapshot_mu.unlock(io);
    g_runtime_snapshot_callback = callback;
    g_runtime_snapshot_ctx = ctx;
}

// CANARY: REQ=REQ-PROMETHEUS-WIRE-001; FEATURE="Prometheus Metrics Endpoint"; ASPECT=HTTPServer; STATUS=TESTED; TEST=geodetestlab/specs/gap_0166_prometheus_metrics.yml; OWNER=monitoring; UPDATED=2026-04-16
// GAP-0166 / GitLab #749: Wire Prometheus metrics exporter to a real HTTP
// listener at /metrics, with a /health probe and a catch-all 404. This file
// intentionally implements the minimum viable HTTP/1.0-style responder — no
// keep-alive, no body parsing, no chunked encoding. Prometheus scrapers only
// need GET /metrics with a plain-text body every ~15s.

/// MetricsServer provides an HTTP endpoint for Prometheus metrics scraping.
pub const MetricsServer = struct {
    allocator: Allocator,
    collector: *prometheus.MetricsCollector,
    port: u16,
    /// Io backend used for all socket operations. Owned by this struct and
    /// torn down in `stop()`. Pattern mirrors `src/tools/cert_gen.zig:17-18`
    /// — we must NOT use `std.Io.Threaded.global_single_threaded` because
    /// that ships with `.allocator = .failing` in 0.16 and OOMs inside the
    /// net vtable.
    threaded: ?std.Io.Threaded,
    server: ?std.Io.net.Server,
    running: std.atomic.Value(bool),
    /// Accept-loop thread handle. `start()` spawns, `stop()` joins.
    accept_thread: ?std.Thread,
    /// Legacy field kept for ABI stability with callers constructing via
    /// `init`; unused now that we spawn a bare `std.Thread` instead of
    /// routing through the shared thread pool.
    accept_pool: ?*pooled.ThreadPool,

    pub fn init(allocator: Allocator, collector: *prometheus.MetricsCollector, port: u16) MetricsServer {
        return .{
            .allocator = allocator,
            .collector = collector,
            .port = port,
            .threaded = null,
            .server = null,
            .running = std.atomic.Value(bool).init(false),
            .accept_thread = null,
            .accept_pool = null,
        };
    }

    pub fn deinit(self: *MetricsServer) void {
        self.stop();
    }

    /// Start the metrics HTTP server.
    /// SECURITY (S10): Binds to 127.0.0.1 by default to prevent unauthenticated
    /// metrics scraping from the network. Override with GEODE_METRICS_BIND env
    /// var (e.g. "0.0.0.0" to restore the old behavior behind a firewall).
    pub fn start(self: *MetricsServer) !void {
        // Reset idempotent state — a prior stop() may have left stale handles.
        if (self.accept_thread != null or self.server != null or self.threaded != null) {
            self.stop();
        }

        const bytes = resolveMetricsBindAddress();
        var ip_buf: [16]u8 = undefined;
        const ip_str = try std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });

        const addr = try std.Io.net.IpAddress.parseIp4(ip_str, self.port);

        // Local Threaded backend. `smp_allocator` is the governance-approved
        // choice here (page_allocator is forbidden in src/).
        self.threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        errdefer {
            if (self.threaded) |*t| t.deinit();
            self.threaded = null;
        }

        const io = self.threaded.?.io();

        self.server = std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true }) catch |err| {
            return err;
        };
        errdefer {
            if (self.server) |*s| s.deinit(io);
            self.server = null;
        }

        self.running.store(true, .release);

        self.accept_thread = std.Thread.spawn(.{}, runAcceptLoop, .{self}) catch |err| {
            self.running.store(false, .release);
            return err;
        };
    }

    /// Stop the metrics HTTP server. Closes the listen fd so the accept loop
    /// unblocks with `error.SocketNotListening`, then joins the thread.
    pub fn stop(self: *MetricsServer) void {
        const should_wake_accept = self.server != null;
        self.running.store(false, .release);
        if (should_wake_accept) wakeAcceptLoop(self.port);

        // Close the listener first so accept() returns with SocketNotListening
        // on whatever thread is currently blocked inside it.
        if (self.server) |*s| {
            if (self.threaded) |*t| {
                s.deinit(t.io());
            }
            self.server = null;
        }

        if (self.accept_thread) |thread| {
            thread.join();
            self.accept_thread = null;
        }

        if (self.threaded) |*t| {
            t.deinit();
            self.threaded = null;
        }

        // Legacy pool field is never populated anymore, but defensively drain
        // it in case a future caller wires it up.
        if (self.accept_pool) |pool| {
            pool.deinit();
            self.accept_pool = null;
        }
    }

    /// Handle a single incoming connection: parse the request line, dispatch
    /// to the matching handler, close the stream. Errors are swallowed — one
    /// bad client must not take down the accept loop.
    fn handleConnection(self: *MetricsServer, stream: std.Io.net.Stream) !void {
        const io = self.threaded.?.io();
        defer stream.close(io);

        var read_buf: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buf);

        // Request line: `METHOD SP PATH SP HTTP/VERSION\r\n`.
        //
        // CANARY: REQ=REQ-PROMETHEUS-WIRE-004; FEATURE="Prometheus Metrics Endpoint"; ASPECT=RequestLineLifetime; STATUS=TESTED; TEST=tests/test_metrics_server_lifecycle.zig; OWNER=monitoring; UPDATED=2026-07-31
        //
        // `takeDelimiterInclusive` returns a slice into the reader's OWN
        // buffer, valid only until the next read. The header drain below
        // refills that buffer, so the request line must be copied out before
        // draining — parsing it afterwards read whatever the drain left
        // behind. Observed symptom: a well-formed `GET /health` answered with
        // a bogus 404/400 whenever the remaining request bytes did not
        // already sit in the buffer (a minimal `GET /health HTTP/1.0\r\n\r\n`
        // reproduced it every time; curl's multi-header request masked it).
        // That made the out-of-band liveness endpoint — the endpoint the
        // Docker HEALTHCHECK probes — unreliable for ordinary HTTP clients.
        var line_buf: [4096]u8 = undefined;
        const line = blk: {
            const req_line = reader.interface.takeDelimiterInclusive('\n') catch {
                try self.serveBadRequest(stream);
                return;
            };
            const trimmed = std.mem.trimEnd(u8, req_line, "\r\n");
            if (trimmed.len > line_buf.len) {
                try self.serveBadRequest(stream);
                return;
            }
            @memcpy(line_buf[0..trimmed.len], trimmed);
            break :blk line_buf[0..trimmed.len];
        };

        // Drain headers until empty line (\r\n\r\n). Cap at 64 header lines.
        var header_count: usize = 0;
        while (header_count < 64) : (header_count += 1) {
            const hdr = reader.interface.takeDelimiterInclusive('\n') catch break;
            const trimmed = std.mem.trimEnd(u8, hdr, "\r\n");
            if (trimmed.len == 0) break;
        }

        // Parse METHOD SP PATH.
        const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse {
            try self.serveBadRequest(stream);
            return;
        };
        const method = line[0..sp1];
        const rest = line[sp1 + 1 ..];
        const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse {
            try self.serveBadRequest(stream);
            return;
        };
        const path = rest[0..sp2];

        // Only GET is served; everything else → 404 per spec.
        if (!std.mem.eql(u8, method, "GET")) {
            try self.serve404(stream);
            return;
        }

        // Strip any query string for path matching.
        const path_only = if (std.mem.indexOfScalar(u8, path, '?')) |q| path[0..q] else path;

        if (std.mem.eql(u8, path_only, "/metrics")) {
            try self.serveMetrics(stream);
        } else if (std.mem.eql(u8, path_only, "/health")) {
            try self.serveHealth(stream);
        } else {
            try self.serve404(stream);
        }
    }

    /// Serve `GET /metrics` — Prometheus text exposition format 0.0.4.
    ///
    /// When the OTel MeterProvider is initialised, renders via the OTel
    /// Prometheus exporter AND appends the legacy MetricsCollector output so
    /// that pre-OTel metric names (geode_queries_total, geode_connections_active,
    /// etc.) remain visible for backward-compatible scrapers and test specs.
    /// Falls back to the legacy collector only when OTel rendering fails or
    /// the provider is not yet initialised.
    fn serveMetrics(self: *MetricsServer, stream: std.Io.net.Stream) !void {
        const io = self.threaded.?.io();
        const otel_resp = @import("otel_prometheus_responder");

        var body: std.Io.Writer.Allocating = try .initCapacity(self.allocator, 4096);
        defer body.deinit();

        if (otel_resp.isAvailable()) {
            otel_resp.renderInto(self.allocator, &body.writer) catch |err| {
                std.log.warn("OTel /metrics render failed, falling back to legacy collector: {s}", .{@errorName(err)});
                // Deinit the partially-written buffer and reinit so we don't
                // mix partial OTel output with the full legacy payload.
                // std.Io.Writer.Allocating has no clearRetainingCapacity, so
                // deinit+reinit is the safest reset pattern.
                body.deinit();
                body = try .initCapacity(self.allocator, 2048);
                try self.collector.exportMetrics(&body.writer);
            };
            // Append legacy metrics after OTel output for backward compatibility.
            // This ensures pre-OTel metric names (geode_queries_total,
            // geode_connections_active) are always present for scrapers and
            // test specs that pre-date the OTel migration. Prometheus scrapers
            // tolerate multiple metric families with distinct names in one payload.
            try self.collector.exportMetrics(&body.writer);
        } else {
            try self.collector.exportMetrics(&body.writer);
        }
        g_runtime_snapshot_mu.lockUncancelable(io);
        defer g_runtime_snapshot_mu.unlock(io);
        if (g_runtime_snapshot_callback) |callback| {
            if (g_runtime_snapshot_ctx) |ctx| {
                const runtime_body_opt: ?[]u8 = callback(self.allocator, ctx) catch |err| blk: {
                    std.log.warn("runtime /metrics snapshot failed: {s}", .{@errorName(err)});
                    break :blk null;
                };
                if (runtime_body_opt) |runtime_body| {
                    defer self.allocator.free(runtime_body);
                    if (runtime_body.len != 0) {
                        try body.writer.writeByte('\n');
                        try body.writer.writeAll(runtime_body);
                    }
                }
            }
        }
        const body_bytes = body.written();

        var header_buf: [256]u8 = undefined;
        const headers = try std.fmt.bufPrint(
            &header_buf,
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{body_bytes.len},
        );

        var write_buf: [4096]u8 = undefined;
        var w = stream.writer(io, &write_buf);
        try w.interface.writeAll(headers);
        try w.interface.writeAll(body_bytes);
        try w.interface.flush();
    }

    /// Serve `GET /health` — fixed-size JSON body.
    fn serveHealth(self: *MetricsServer, stream: std.Io.net.Stream) !void {
        const io = self.threaded.?.io();
        const response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\nConnection: close\r\n\r\n{\"status\":\"ok\"}";
        var write_buf: [512]u8 = undefined;
        var w = stream.writer(io, &write_buf);
        try w.interface.writeAll(response);
        try w.interface.flush();
    }

    /// Serve `* → 404` with a short plain-text body.
    fn serve404(self: *MetricsServer, stream: std.Io.net.Stream) !void {
        const io = self.threaded.?.io();
        const response = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 10\r\nConnection: close\r\n\r\nNot Found\n";
        var write_buf: [256]u8 = undefined;
        var w = stream.writer(io, &write_buf);
        try w.interface.writeAll(response);
        try w.interface.flush();
    }

    /// Serve `400 Bad Request` for malformed request lines.
    fn serveBadRequest(self: *MetricsServer, stream: std.Io.net.Stream) !void {
        const io = self.threaded.?.io();
        const response = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 12\r\nConnection: close\r\n\r\nBad Request\n";
        var write_buf: [256]u8 = undefined;
        var w = stream.writer(io, &write_buf);
        try w.interface.writeAll(response);
        try w.interface.flush();
    }

    /// Accept loop. One request at a time — Prometheus scrapes are infrequent
    /// enough that serial handling is well below the budget (~15s cadence).
    /// Exits when `stop()` closes the listen fd (accept returns
    /// `error.SocketNotListening`) or when the global shutdown flag is set.
    pub fn acceptLoop(self: *MetricsServer) void {
        const io = self.threaded.?.io();
        while (self.running.load(.acquire)) {
            if (self.server == null) break;
            const stream = self.server.?.accept(io) catch |err| switch (err) {
                error.SocketNotListening => return,
                error.ConnectionAborted, error.WouldBlock => continue,
                else => return,
            };
            self.handleConnection(stream) catch {
                // Per-connection errors are non-fatal; stream was closed
                // inside handleConnection via `defer stream.close(io)`.
            };
        }
    }

    fn runAcceptLoop(self: *MetricsServer) void {
        self.acceptLoop();
    }
};

fn wakeAcceptLoop(port: u16) void {
    // CANARY: REQ=REQ-QUIC-HC-172; FEATURE="High-Concurrency Diagnostics"; ASPECT=MetricsAcceptWake; STATUS=IMPL; TEST=test_metrics_server_lifecycle; OWNER=monitoring; UPDATED=2026-05-29
    //
    // Closing a listening socket from another thread does not reliably
    // interrupt a blocking accept4 on Linux after the endpoint has handled a
    // real scrape. A best-effort self-connect wakes acceptLoop so it observes
    // running=false and exits before stop() joins the thread.
    // Use the target's socket ABI. Raw Linux syscalls raise SIGSYS on macOS.
    const fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    if (std.c.fcntl(fd, std.posix.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC)) < 0) return;

    const sa = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = .{0} ** 8,
    };
    _ = std.c.connect(fd, @ptrCast(&sa), @sizeOf(std.posix.sockaddr.in));
}

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
    try std.testing.expect(server.running.load(.acquire) == false);
}
