// CANARY: REQ=REQ-OTEL-FACADE-001; FEATURE="OTel Instrumentation"; ASPECT=Facade; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28
//! Global MeterProvider facade for Geode.
//!
//! There is exactly one `MeterProvider` per process. All instrumentation
//! sites import this module and call `recordX` helpers (added by Task 8+)
//! rather than touching the provider directly. This keeps import fan-out
//! minimal and makes replacing the backend trivial.
//!
//! Lifecycle:
//!   1. Call `init` (or `initForTesting`) once at startup.
//!   2. Call `meter()` to obtain a `Meter` and register instruments.
//!   3. Call `shutdown()` on process exit to flush and free resources.
//!
//! `init` and `initForTesting` are idempotent: a second call while the
//! provider is already initialised returns immediately without modifying
//! any state. `shutdown` resets global state so `init` can be called
//! again (useful in test suites that exercise the full lifecycle).

const std = @import("std");
const otel = @import("otel");
// Named import: otel_resource is wired as a named dep in build.zig for
// all module contexts that use otel_metrics (test + production). This
// avoids "file exists in two modules" errors when otel_metrics.zig is
// declared as a named module root and otel_resource.zig is simultaneously
// the root of a peer module.
const otel_resource = @import("otel_resource");

const Resource = otel.sdk.resource.Resource;
const MeterProvider = otel.sdk.metrics.MeterProvider;
const Meter = otel.api.metrics.Meter;

pub const SCOPE_NAME = "com.codepros.geode";
pub const SCHEMA_URL = "https://schemas.geodedb.com/otel/geode/metrics/1.0.0";

// --- Module-level globals (one per process) ---

var g_provider: ?*MeterProvider = null;
var g_resource: ?*Resource = null;
var g_allocator: ?std.mem.Allocator = null;
var g_init_mu: std.Io.Mutex = std.Io.Mutex.init;

fn initIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

// -----------------------------------------------------------------------
// Public API
// -----------------------------------------------------------------------

/// Initialise the global MeterProvider. Idempotent: returns immediately
/// if already initialised. Thread-safe via `g_init_mu`.
pub fn init(allocator: std.mem.Allocator, opts: otel_resource.Options) !void {
    g_init_mu.lockUncancelable(initIo());
    defer g_init_mu.unlock(initIo());
    if (g_provider != null) return;

    // Build Resource on the heap so MetricsConfig can hold a pointer.
    const resource = try allocator.create(Resource);
    errdefer allocator.destroy(resource);
    resource.* = try otel_resource.buildResource(allocator, opts);
    errdefer resource.deinit();

    const provider = try allocator.create(MeterProvider);
    errdefer allocator.destroy(provider);
    provider.* = try MeterProvider.init(allocator, .{
        .resource = resource,
        .disabled = false,
    });

    g_resource = resource;
    g_provider = provider;
    g_allocator = allocator;
}

/// Test variant: builds a fixed-attribute resource so unit tests do not
/// depend on environment variables or a real service version.
pub fn initForTesting(allocator: std.mem.Allocator) !void {
    return init(allocator, .{
        .service_version = "test",
        .instance_id = "test-instance",
        .node_role = .standalone,
    });
}

/// Flush and free the global MeterProvider. Safe to call even if `init`
/// was never called. Resets state so `init` may be called again.
pub fn shutdown() void {
    g_init_mu.lockUncancelable(initIo());
    defer g_init_mu.unlock(initIo());

    if (g_provider) |p| {
        p.deinit();
        if (g_allocator) |a| a.destroy(p);
        g_provider = null;
    }
    if (g_resource) |r| {
        // MeterProvider.deinit only frees the resource when owns_resource
        // is true (i.e. when no resource was passed via MetricsConfig).
        // We supplied our heap resource via MetricsConfig.resource so the
        // provider did NOT free it — we must do so here.
        r.deinit();
        if (g_allocator) |a| a.destroy(r);
        g_resource = null;
    }
    // Lifecycle state cleanup — must happen before nulling g_allocator.
    if (g_allocator) |a| g_health_states.deinit(a);
    g_health_states = .{};
    g_uptime_start_ns = 0;
    g_config_reload_counter = null;
    g_shutdown_counter = null;
    // Transport metrics state reset.
    g_transport = null;
    g_active_connections_provider = null;
    // Query metrics state reset.
    g_query = null;
    // Transaction metrics state reset.
    g_transaction = null;
    // Storage + WAL metrics state reset.
    g_storage = null;
    g_storage_file_size_provider = null;
    g_storage_disk_usage_provider = null;
    g_wal = null;
    g_wal_size_provider = null;
    // Graph data model metrics state reset.
    g_graph = null;
    g_node_count_provider = null;
    g_edge_count_provider = null;
    g_allocator = null;
}

// Hot-path reads — no lock. Callers MUST be in the init..shutdown window;
// concurrent access with shutdown() is undefined behaviour. In production
// this is enforced by the lifecycle: init() runs at server startup before
// any instrumentation site is reachable, and shutdown() runs after all
// request paths have drained.

/// Return the global MeterProvider, or `null` if not yet initialised.
pub fn getProvider() ?*MeterProvider {
    return g_provider;
}

/// Return a `Meter` scoped to Geode's instrumentation library.
/// If called before `init` or after `shutdown`, returns an inert no-op
/// `Meter` that satisfies the OTel API contract without crashing.
pub fn meter() Meter {
    if (g_provider) |p| {
        return p.meter(.{
            .name = SCOPE_NAME,
            .version = otel.version,
            .schema_url = SCHEMA_URL,
        });
    }
    // Pre-init or post-shutdown: the API-layer noop shape only requires
    // `scope`; all function pointers default to their noop variants.
    return .{ .scope = .{ .name = SCOPE_NAME } };
}

// -------------------------------------------------------------------------
// Histogram bucket profiles per docs/otel-updates.md §2.
//
// These are the seven canonical bucket sets every OTel histogram in Geode
// should reference, so panel-template aggregation across instruments stays
// consistent. Use the slice that matches the metric's domain: durations
// land in the *_duration profiles (seconds), payloads in `buckets_bytes`
// or `buckets_rows`, and graph fan-out in `buckets_graph_degree`.
// -------------------------------------------------------------------------

pub const buckets_db_client_duration: []const f64 = &.{ 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 10 };
pub const buckets_query_duration: []const f64 = &.{ 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60 };
pub const buckets_storage_io_duration: []const f64 = &.{ 0.00001, 0.00005, 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1 };
pub const buckets_lock_wait_duration: []const f64 = &.{ 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 30 };
pub const buckets_rows: []const f64 = &.{ 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000 };
pub const buckets_bytes: []const f64 = &.{ 128, 512, 1024, 4096, 16384, 65536, 262144, 1048576, 4194304, 16777216, 67108864 };
pub const buckets_graph_degree: []const f64 = &.{ 0, 1, 2, 5, 10, 20, 50, 100, 500, 1000, 10000 };

// -------------------------------------------------------------------------
// Server lifecycle metrics — geode.server.* per docs/otel-updates.md §4.1.
// -------------------------------------------------------------------------

const attrs = otel.internal.attributes;

// CANARY: REQ=REQ-OTEL-METRICS-003; FEATURE="OTel Instrumentation"; ASPECT=ServerLifecycle; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28

pub const Outcome = enum {
    success,
    error_,
    timeout,
    cancelled,
    partial_success,
};

fn outcomeName(o: Outcome) []const u8 {
    return switch (o) {
        .success => "success",
        .error_ => "error",
        .timeout => "timeout",
        .cancelled => "cancelled",
        .partial_success => "partial_success",
    };
}

pub const ShutdownReason = enum { graceful, forced, panic_ };

fn shutdownReasonName(r: ShutdownReason) []const u8 {
    return switch (r) {
        .graceful => "graceful",
        .forced => "forced",
        .panic_ => "panic",
    };
}

// Nanosecond timestamp of process start, set by registerServerLifecycle.
var g_uptime_start_ns: u64 = 0;
var g_health_states: std.StringHashMapUnmanaged(bool) = .{};
var g_health_mu: std.Io.Mutex = std.Io.Mutex.init;

var g_config_reload_counter: ?otel.api.metrics.Counter = null;
var g_shutdown_counter: ?otel.api.metrics.Counter = null;

/// Register the two observable lifecycle gauges (uptime, health). Must be
/// called once at server startup AFTER `init()`. Idempotent — second call is
/// a no-op (the OTel SDK rejects duplicate instrument registrations).
/// `start_time_ms` is unused (kept for API compatibility); pass 0.
pub fn registerServerLifecycle(start_time_ms: i64) !void {
    _ = start_time_ms;
    g_uptime_start_ns = otel.internal.clock.unixNanoNow();
    const m = meter();
    _ = try m.createObservableGauge(
        .{
            .name = "geode.server.uptime",
            .unit = "s",
            .kind = .observable_gauge,
            .description = "Seconds since process start",
        },
        observeUptime,
        null,
    );
    _ = try m.createObservableGauge(
        .{
            .name = "geode.server.health",
            .unit = "1",
            .kind = .observable_gauge,
            .description = "1 healthy, 0 unhealthy per component",
        },
        observeHealth,
        null,
    );
}

fn observeUptime(_: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    const now_ns = otel.internal.clock.unixNanoNow();
    const elapsed_ns = if (now_ns >= g_uptime_start_ns) now_ns - g_uptime_start_ns else 0;
    const seconds: f64 = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s);
    observer.observeDouble(seconds, &.{});
}

fn observeHealth(_: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    const io = std.Io.Threaded.global_single_threaded.io();
    g_health_mu.lockUncancelable(io);
    defer g_health_mu.unlock(io);
    var it = g_health_states.iterator();
    while (it.next()) |kv| {
        const v: f64 = if (kv.value_ptr.*) 1.0 else 0.0;
        const component_attr = attrs.Entry{ .key = "geode.component", .value = .{ .string = kv.key_ptr.* } };
        observer.observeDouble(v, &.{component_attr});
    }
}

/// Record/update a component's health state. The component name MUST be a
/// string literal or have process-lifetime storage — the HashMap stores the
/// pointer, not a copy.
pub fn recordServerHealth(component: []const u8, healthy: bool) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    g_health_mu.lockUncancelable(io);
    defer g_health_mu.unlock(io);
    if (g_allocator) |alloc| {
        g_health_states.put(alloc, component, healthy) catch {};
    }
}

fn ensureLifecycleCounters() !void {
    const m = meter();
    if (g_config_reload_counter == null) {
        g_config_reload_counter = try m.counter(.{
            .name = "geode.server.config.reload.count",
            .unit = "{reload}",
            .kind = .counter,
            .description = "Config reload attempts",
        });
    }
    if (g_shutdown_counter == null) {
        g_shutdown_counter = try m.counter(.{
            .name = "geode.server.shutdown.count",
            .unit = "{shutdown}",
            .kind = .counter,
            .description = "Graceful or forced shutdowns",
        });
    }
}

pub fn recordConfigReload(outcome: Outcome, error_type: ?[]const u8) void {
    ensureLifecycleCounters() catch return;
    var buf: [2]attrs.Entry = undefined;
    var n: usize = 0;
    buf[n] = .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } };
    n += 1;
    if (error_type) |e| {
        buf[n] = .{ .key = "error.type", .value = .{ .string = e } };
        n += 1;
    }
    g_config_reload_counter.?.add(1, buf[0..n]);
}

pub fn recordShutdown(reason: ShutdownReason) void {
    ensureLifecycleCounters() catch return;
    const reason_attr = attrs.Entry{ .key = "geode.shutdown.reason", .value = .{ .string = shutdownReasonName(reason) } };
    g_shutdown_counter.?.add(1, &.{reason_attr});
}

// -------------------------------------------------------------------------
// QUIC transport metrics — geode.transport.* per docs/otel-updates.md §4.2.
// -------------------------------------------------------------------------

// CANARY: REQ=REQ-OTEL-METRICS-004; FEATURE="OTel Instrumentation"; ASPECT=Transport; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28

pub const TransportProtocol = enum { quic, tcp };
pub const NetworkDirection = enum { transmit, receive };
pub const TimeoutKind = enum { request, connection, handshake };

const TransportMetrics = struct {
    connection_opened: otel.api.metrics.Counter,
    connection_closed: otel.api.metrics.Counter,
    handshake_duration: otel.api.metrics.Histogram,
    request_duration: otel.api.metrics.Histogram,
    request_inflight: otel.api.metrics.UpDownCounter,
    bytes: otel.api.metrics.Counter,
    timeout_count: otel.api.metrics.Counter,
};

var g_transport: ?TransportMetrics = null;

fn ensureTransport() !*TransportMetrics {
    if (g_transport) |*t| return t;
    const m = meter();
    g_transport = TransportMetrics{
        .connection_opened = try m.counter(.{
            .name = "geode.transport.connection.opened",
            .unit = "{connection}",
            .kind = .counter,
            .description = "Accepted/opened QUIC connections",
        }),
        .connection_closed = try m.counter(.{
            .name = "geode.transport.connection.closed",
            .unit = "{connection}",
            .kind = .counter,
            .description = "Closed QUIC connections",
        }),
        .handshake_duration = try m.histogram(.{
            .name = "geode.transport.handshake.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "QUIC/TLS handshake duration in seconds",
            .explicit_buckets = .{ .boundaries = buckets_db_client_duration },
        }),
        .request_duration = try m.histogram(.{
            .name = "geode.transport.request.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "End-to-end server request handling duration",
            .explicit_buckets = .{ .boundaries = buckets_query_duration },
        }),
        .request_inflight = try m.upDownCounter(.{
            .name = "geode.transport.request.inflight",
            .unit = "{request}",
            .kind = .up_down_counter,
            .description = "Currently active protocol requests",
        }),
        .bytes = try m.counter(.{
            .name = "geode.transport.bytes",
            .unit = "By",
            .kind = .counter,
            .description = "Bytes sent or received over QUIC",
        }),
        .timeout_count = try m.counter(.{
            .name = "geode.transport.timeout.count",
            .unit = "{timeout}",
            .kind = .counter,
            .description = "Request, connection, or handshake timeouts",
        }),
    };
    return &g_transport.?;
}

pub fn recordTransportConnectionOpened(proto: TransportProtocol) void {
    const t = ensureTransport() catch return;
    t.connection_opened.add(1, &.{attrs.Entry{ .key = "geode.transport.protocol", .value = .{ .string = @tagName(proto) } }});
}

pub fn recordTransportConnectionClosed(reason: []const u8) void {
    const t = ensureTransport() catch return;
    t.connection_closed.add(1, &.{attrs.Entry{ .key = "geode.close.reason", .value = .{ .string = reason } }});
}

// NOTE: recordTransportHandshake and recordTransportTimeout are
// currently exposed but have no production call sites — the vendor
// QUIC library does not surface a TLS-handshake-completion callback
// or a per-timeout hook. They are smoke-tested for forward compatibility
// when the vendor lib gains these hooks. Do not assume they are dead
// code.

pub fn recordTransportHandshake(duration_s: f64, outcome: Outcome, error_type: ?[]const u8) void {
    const t = ensureTransport() catch return;
    var buf: [3]attrs.Entry = undefined;
    var n: usize = 0;
    buf[n] = .{ .key = "geode.transport.protocol", .value = .{ .string = "quic" } };
    n += 1;
    buf[n] = .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } };
    n += 1;
    if (error_type) |e| {
        buf[n] = .{ .key = "error.type", .value = .{ .string = e } };
        n += 1;
    }
    t.handshake_duration.record(duration_s, buf[0..n]);
}

pub fn recordTransportRequest(op_name: []const u8, duration_s: f64, outcome: Outcome, error_type: ?[]const u8) void {
    const t = ensureTransport() catch return;
    var buf: [3]attrs.Entry = undefined;
    var n: usize = 0;
    buf[n] = .{ .key = "db.operation.name", .value = .{ .string = op_name } };
    n += 1;
    buf[n] = .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } };
    n += 1;
    if (error_type) |e| {
        buf[n] = .{ .key = "error.type", .value = .{ .string = e } };
        n += 1;
    }
    t.request_duration.record(duration_s, buf[0..n]);
}

pub fn incTransportInflight(op_name: []const u8) void {
    const t = ensureTransport() catch return;
    t.request_inflight.add(1, &.{.{ .key = "db.operation.name", .value = .{ .string = op_name } }});
}

pub fn decTransportInflight(op_name: []const u8) void {
    const t = ensureTransport() catch return;
    t.request_inflight.add(-1, &.{.{ .key = "db.operation.name", .value = .{ .string = op_name } }});
}

pub fn recordTransportBytes(direction: NetworkDirection, n_bytes: u64) void {
    const t = ensureTransport() catch return;
    t.bytes.add(n_bytes, &.{.{ .key = "network.io.direction", .value = .{ .string = @tagName(direction) } }});
}

pub fn recordTransportTimeout(kind: TimeoutKind) void {
    const t = ensureTransport() catch return;
    t.timeout_count.add(1, &.{.{ .key = "geode.timeout.kind", .value = .{ .string = @tagName(kind) } }});
}

// Observable gauge for current active connection count. Caller (transport
// init) MUST call `registerTransportConnectionGauge` once after `listen()`.
var g_active_connections_provider: ?*const fn () i64 = null;

pub fn registerTransportConnectionGauge(provider_fn: *const fn () i64) !void {
    g_active_connections_provider = provider_fn;
    const m = meter();
    _ = try m.createObservableGauge(
        .{
            .name = "geode.transport.connection.count",
            .unit = "{connection}",
            .kind = .observable_gauge,
            .description = "Current number of active QUIC connections",
        },
        observeActiveConnections,
        null,
    );
}

fn observeActiveConnections(_: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    if (g_active_connections_provider) |fnp| {
        observer.observeInt(fnp(), &.{.{ .key = "geode.transport.protocol", .value = .{ .string = "quic" } }});
    }
}

// -------------------------------------------------------------------------
// Query lifecycle metrics — geode.query.* per docs/otel-updates.md §4.3.
// -------------------------------------------------------------------------

// CANARY: REQ=REQ-OTEL-METRICS-005; FEATURE="OTel Instrumentation"; ASPECT=QueryLifecycle; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28

pub const QueryType = enum { read, write, ddl, admin, algorithm, ml, analytics };

const QueryMetrics = struct {
    count: otel.api.metrics.Counter,
    active: otel.api.metrics.UpDownCounter,
    execution_duration: otel.api.metrics.Histogram,
    parse_duration: otel.api.metrics.Histogram,
    parse_error_count: otel.api.metrics.Counter,
    plan_duration: otel.api.metrics.Histogram,
    rows_returned: otel.api.metrics.Histogram,
    timeout_count: otel.api.metrics.Counter,
};

var g_query: ?QueryMetrics = null;

fn ensureQuery() !*QueryMetrics {
    if (g_query) |*q| return q;
    const m = meter();
    g_query = QueryMetrics{
        .count = try m.counter(.{
            .name = "geode.query.count",
            .unit = "{query}",
            .kind = .counter,
            .description = "Total number of queries executed",
        }),
        .active = try m.upDownCounter(.{
            .name = "geode.query.active",
            .unit = "{query}",
            .kind = .up_down_counter,
            .description = "Number of queries currently executing",
        }),
        .execution_duration = try m.histogram(.{
            .name = "geode.query.execution.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "End-to-end query execution duration in seconds",
            .explicit_buckets = .{ .boundaries = buckets_query_duration },
        }),
        .parse_duration = try m.histogram(.{
            .name = "geode.query.parse.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "GQL parse duration in seconds",
            .explicit_buckets = .{ .boundaries = buckets_query_duration },
        }),
        .parse_error_count = try m.counter(.{
            .name = "geode.query.parse.error.count",
            .unit = "{error}",
            .kind = .counter,
            .description = "Number of GQL parse errors",
        }),
        .plan_duration = try m.histogram(.{
            .name = "geode.query.plan.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "Query plan compilation duration in seconds",
            .explicit_buckets = .{ .boundaries = buckets_query_duration },
        }),
        .rows_returned = try m.histogram(.{
            .name = "geode.query.rows.returned",
            .unit = "{row}",
            .kind = .histogram,
            .description = "Number of rows returned per query",
            .explicit_buckets = .{ .boundaries = buckets_rows },
        }),
        .timeout_count = try m.counter(.{
            .name = "geode.query.timeout.count",
            .unit = "{timeout}",
            .kind = .counter,
            .description = "Number of query timeouts",
        }),
    };
    return &g_query.?;
}

pub fn incQueryActive(qt: QueryType) void {
    const q = ensureQuery() catch return;
    q.active.add(1, &.{.{ .key = "geode.query.type", .value = .{ .string = @tagName(qt) } }});
}

pub fn decQueryActive(qt: QueryType) void {
    const q = ensureQuery() catch return;
    q.active.add(-1, &.{.{ .key = "geode.query.type", .value = .{ .string = @tagName(qt) } }});
}

/// Record a completed query execution. Also bumps geode.query.count so the
/// count and duration sample are always correlated (per spec §4.3).
pub fn recordQueryExecution(op: []const u8, summary: []const u8, qt: QueryType, duration_s: f64, outcome: Outcome, error_type: ?[]const u8) void {
    _ = summary;
    const q = ensureQuery() catch return;
    var buf: [4]attrs.Entry = undefined;
    var n: usize = 0;
    buf[n] = .{ .key = "db.operation.name", .value = .{ .string = op } };
    n += 1;
    buf[n] = .{ .key = "geode.query.type", .value = .{ .string = @tagName(qt) } };
    n += 1;
    buf[n] = .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } };
    n += 1;
    if (error_type) |e| {
        buf[n] = .{ .key = "error.type", .value = .{ .string = e } };
        n += 1;
    }
    q.count.add(1, buf[0..n]);
    q.execution_duration.record(duration_s, buf[0..n]);
}

pub fn recordQueryParse(duration_s: f64, outcome: Outcome, error_type: ?[]const u8) void {
    const q = ensureQuery() catch return;
    var buf: [2]attrs.Entry = undefined;
    var n: usize = 0;
    buf[n] = .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } };
    n += 1;
    if (error_type) |e| {
        buf[n] = .{ .key = "error.type", .value = .{ .string = e } };
        n += 1;
    }
    q.parse_duration.record(duration_s, buf[0..n]);
}

pub fn recordQueryParseError(error_type: []const u8) void {
    const q = ensureQuery() catch return;
    q.parse_error_count.add(1, &.{.{ .key = "error.type", .value = .{ .string = error_type } }});
}

pub fn recordQueryPlan(op: []const u8, duration_s: f64, planner_strategy: []const u8) void {
    const q = ensureQuery() catch return;
    q.plan_duration.record(duration_s, &.{
        .{ .key = "db.operation.name", .value = .{ .string = op } },
        .{ .key = "geode.planner.strategy", .value = .{ .string = planner_strategy } },
    });
}

pub fn recordQueryRowsReturned(op: []const u8, summary: []const u8, rows: u64) void {
    _ = summary;
    const q = ensureQuery() catch return;
    q.rows_returned.record(@floatFromInt(rows), &.{.{ .key = "db.operation.name", .value = .{ .string = op } }});
}

pub fn recordQueryTimeout(op: []const u8, kind: TimeoutKind) void {
    const q = ensureQuery() catch return;
    q.timeout_count.add(1, &.{
        .{ .key = "db.operation.name", .value = .{ .string = op } },
        .{ .key = "geode.timeout.kind", .value = .{ .string = @tagName(kind) } },
    });
}

// -------------------------------------------------------------------------
// Transaction lifecycle metrics — geode.transaction.* per §4.6.
// -------------------------------------------------------------------------

// CANARY: REQ=REQ-OTEL-METRICS-006; FEATURE="OTel Instrumentation"; ASPECT=TransactionLifecycle; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28

pub const IsolationLevel = enum {
    read_committed,
    snapshot,
    serializable_snapshot,
    repeatable_read,
    read_uncommitted,
    serializable,
};

pub const AbortReason = enum {
    user,
    conflict,
    timeout,
    deadlock,
    system_error,
};

pub const LockType = enum {
    row,
    predicate,
    range,
    exclusive,
    shared,
};

const TransactionMetrics = struct {
    count: otel.api.metrics.Counter,
    active: otel.api.metrics.UpDownCounter,
    duration: otel.api.metrics.Histogram,
    commit_duration: otel.api.metrics.Histogram,
    abort_count: otel.api.metrics.Counter,
    timeout_count: otel.api.metrics.Counter,
    serialization_conflict_count: otel.api.metrics.Counter,
    deadlock_count: otel.api.metrics.Counter,
    lock_wait_duration: otel.api.metrics.Histogram,
};

var g_transaction: ?TransactionMetrics = null;

fn ensureTransaction() !*TransactionMetrics {
    if (g_transaction) |*t| return t;
    const m = meter();
    g_transaction = TransactionMetrics{
        .count = try m.counter(.{
            .name = "geode.transaction.count",
            .unit = "{transaction}",
            .kind = .counter,
            .description = "Total number of transactions begun",
        }),
        .active = try m.upDownCounter(.{
            .name = "geode.transaction.active",
            .unit = "{transaction}",
            .kind = .up_down_counter,
            .description = "Number of currently active transactions",
        }),
        .duration = try m.histogram(.{
            .name = "geode.transaction.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "Total transaction duration in seconds",
            .explicit_buckets = .{ .boundaries = buckets_query_duration },
        }),
        .commit_duration = try m.histogram(.{
            .name = "geode.transaction.commit.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "Transaction commit phase duration in seconds",
            .explicit_buckets = .{ .boundaries = buckets_query_duration },
        }),
        .abort_count = try m.counter(.{
            .name = "geode.transaction.abort.count",
            .unit = "{transaction}",
            .kind = .counter,
            .description = "Number of aborted transactions",
        }),
        .timeout_count = try m.counter(.{
            .name = "geode.transaction.timeout.count",
            .unit = "{timeout}",
            .kind = .counter,
            .description = "Number of transaction timeouts",
        }),
        .serialization_conflict_count = try m.counter(.{
            .name = "geode.transaction.serialization_conflict.count",
            .unit = "{conflict}",
            .kind = .counter,
            .description = "Number of serialization conflicts",
        }),
        .deadlock_count = try m.counter(.{
            .name = "geode.transaction.deadlock.count",
            .unit = "{deadlock}",
            .kind = .counter,
            .description = "Number of deadlocks detected",
        }),
        .lock_wait_duration = try m.histogram(.{
            .name = "geode.transaction.lock.wait.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "Time spent waiting to acquire locks in seconds",
            .explicit_buckets = .{ .boundaries = buckets_lock_wait_duration },
        }),
    };
    return &g_transaction.?;
}

pub fn incTransactionActive(level: IsolationLevel) void {
    const t = ensureTransaction() catch return;
    t.active.add(1, &.{.{ .key = "geode.transaction.isolation_level", .value = .{ .string = @tagName(level) } }});
}

pub fn decTransactionActive(level: IsolationLevel) void {
    const t = ensureTransaction() catch return;
    t.active.add(-1, &.{.{ .key = "geode.transaction.isolation_level", .value = .{ .string = @tagName(level) } }});
}

pub fn recordTransactionBegin(level: IsolationLevel) void {
    const t = ensureTransaction() catch return;
    t.count.add(1, &.{.{ .key = "geode.transaction.isolation_level", .value = .{ .string = @tagName(level) } }});
}

pub fn recordTransactionCommit(level: IsolationLevel, duration_s: f64, outcome: Outcome) void {
    const t = ensureTransaction() catch return;
    const level_attr = attrs.Entry{ .key = "geode.transaction.isolation_level", .value = .{ .string = @tagName(level) } };
    const outcome_attr = attrs.Entry{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } };
    t.commit_duration.record(duration_s, &.{ level_attr, outcome_attr });
    t.duration.record(duration_s, &.{ level_attr, outcome_attr });
}

pub fn recordTransactionAbort(reason: AbortReason, error_type: ?[]const u8) void {
    const t = ensureTransaction() catch return;
    var buf: [2]attrs.Entry = undefined;
    var n: usize = 0;
    buf[n] = .{ .key = "geode.transaction.abort_reason", .value = .{ .string = @tagName(reason) } };
    n += 1;
    if (error_type) |e| {
        buf[n] = .{ .key = "error.type", .value = .{ .string = e } };
        n += 1;
    }
    t.abort_count.add(1, buf[0..n]);
}

pub fn recordTransactionTimeout(level: IsolationLevel) void {
    const t = ensureTransaction() catch return;
    t.timeout_count.add(1, &.{.{ .key = "geode.transaction.isolation_level", .value = .{ .string = @tagName(level) } }});
}

pub fn recordSerializationConflict(conflict_type: []const u8) void {
    const t = ensureTransaction() catch return;
    t.serialization_conflict_count.add(1, &.{.{ .key = "geode.conflict.type", .value = .{ .string = conflict_type } }});
}

pub fn recordDeadlock(victim_policy: []const u8) void {
    const t = ensureTransaction() catch return;
    t.deadlock_count.add(1, &.{.{ .key = "geode.deadlock.victim_policy", .value = .{ .string = victim_policy } }});
}

pub fn recordLockWait(lock_type: LockType, duration_s: f64, outcome: Outcome) void {
    const t = ensureTransaction() catch return;
    t.lock_wait_duration.record(duration_s, &.{
        .{ .key = "geode.lock.type", .value = .{ .string = @tagName(lock_type) } },
        .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } },
    });
}

// -------------------------------------------------------------------------
// Storage + WAL metrics — geode.storage.* / geode.wal.* per §4.5 P0.
// -------------------------------------------------------------------------

// CANARY: REQ=REQ-OTEL-METRICS-007; FEATURE="OTel Instrumentation"; ASPECT=StorageWAL; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28

pub const StorageOp = enum { read_node, write_node, read_edge, write_edge, scan, compact };
pub const StorageIoDir = enum { read, write };
pub const CacheOutcome = enum { hit, miss, evicted };
pub const WalRecordType = enum { node_create, node_update, node_delete, edge_create, edge_update, edge_delete, txn_begin, txn_commit, txn_abort, checkpoint };
pub const WalIoDir = enum { write, replay };

const StorageMetrics = struct {
    op_count: otel.api.metrics.Counter,
    op_duration: otel.api.metrics.Histogram,
    bytes: otel.api.metrics.Counter,
    page_cache_lookup: otel.api.metrics.Counter,
};

const WalMetrics = struct {
    record_count: otel.api.metrics.Counter,
    bytes: otel.api.metrics.Counter,
    append_duration: otel.api.metrics.Histogram,
    flush_duration: otel.api.metrics.Histogram,
    fsync_duration: otel.api.metrics.Histogram,
    replay_duration: otel.api.metrics.Histogram,
    replay_record_count: otel.api.metrics.Counter,
};

var g_storage: ?StorageMetrics = null;
var g_wal: ?WalMetrics = null;

// Observable gauge function pointers — set by registerXxxGauge.
var g_storage_file_size_provider: ?*const fn () i64 = null;
var g_storage_disk_usage_provider: ?*const fn () i64 = null;
var g_wal_size_provider: ?*const fn () i64 = null;

fn ensureStorage() !*StorageMetrics {
    if (g_storage) |*s| return s;
    const m = meter();
    g_storage = StorageMetrics{
        .op_count = try m.counter(.{
            .name = "geode.storage.operation.count",
            .unit = "{operation}",
            .kind = .counter,
            .description = "Total storage operations by type and outcome",
        }),
        .op_duration = try m.histogram(.{
            .name = "geode.storage.operation.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "Storage operation duration in seconds",
            .explicit_buckets = .{ .boundaries = buckets_storage_io_duration },
        }),
        .bytes = try m.counter(.{
            .name = "geode.storage.bytes",
            .unit = "By",
            .kind = .counter,
            .description = "Bytes read or written by the storage engine",
        }),
        .page_cache_lookup = try m.counter(.{
            .name = "geode.storage.page.cache.lookup",
            .unit = "{lookup}",
            .kind = .counter,
            .description = "Page cache lookups by outcome (hit/miss/evicted)",
        }),
    };
    return &g_storage.?;
}

fn ensureWal() !*WalMetrics {
    if (g_wal) |*w| return w;
    const m = meter();
    g_wal = WalMetrics{
        .record_count = try m.counter(.{
            .name = "geode.wal.record.count",
            .unit = "{record}",
            .kind = .counter,
            .description = "WAL records written by type",
        }),
        .bytes = try m.counter(.{
            .name = "geode.wal.bytes",
            .unit = "By",
            .kind = .counter,
            .description = "Bytes written to or replayed from the WAL",
        }),
        .append_duration = try m.histogram(.{
            .name = "geode.wal.append.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "WAL record append duration in seconds",
            .explicit_buckets = .{ .boundaries = buckets_storage_io_duration },
        }),
        .flush_duration = try m.histogram(.{
            .name = "geode.wal.flush.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "WAL buffer flush duration in seconds",
            .explicit_buckets = .{ .boundaries = buckets_storage_io_duration },
        }),
        .fsync_duration = try m.histogram(.{
            .name = "geode.wal.fsync.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "WAL fsync duration in seconds",
            .explicit_buckets = .{ .boundaries = buckets_storage_io_duration },
        }),
        .replay_duration = try m.histogram(.{
            .name = "geode.wal.replay.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "WAL full-replay duration in seconds",
            .explicit_buckets = .{ .boundaries = buckets_storage_io_duration },
        }),
        .replay_record_count = try m.counter(.{
            .name = "geode.wal.replay.record.count",
            .unit = "{record}",
            .kind = .counter,
            .description = "Records processed during WAL replay",
        }),
    };
    return &g_wal.?;
}

// ---- Observable gauge observers ----

fn observeStorageFileSize(_: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    if (g_storage_file_size_provider) |fnp| {
        observer.observeInt(fnp(), &.{});
    }
}

fn observeStorageDiskUsage(_: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    if (g_storage_disk_usage_provider) |fnp| {
        observer.observeInt(fnp(), &.{});
    }
}

fn observeWalSize(_: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    if (g_wal_size_provider) |fnp| {
        observer.observeInt(fnp(), &.{});
    }
}

// ---- Storage public API ----

/// Record a completed storage operation. Bumps both the count and duration.
pub fn recordStorageOp(op: StorageOp, duration_s: f64, outcome: Outcome, error_type: ?[]const u8) void {
    const s = ensureStorage() catch return;
    var buf: [3]attrs.Entry = undefined;
    var n: usize = 0;
    buf[n] = .{ .key = "geode.storage.operation", .value = .{ .string = @tagName(op) } };
    n += 1;
    buf[n] = .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } };
    n += 1;
    if (error_type) |e| {
        buf[n] = .{ .key = "error.type", .value = .{ .string = e } };
        n += 1;
    }
    s.op_count.add(1, buf[0..n]);
    s.op_duration.record(duration_s, buf[0..n]);
}

/// Record bytes transferred by the storage layer.
pub fn recordStorageBytes(direction: StorageIoDir, n_bytes: u64) void {
    const s = ensureStorage() catch return;
    s.bytes.add(n_bytes, &.{.{ .key = "geode.io.direction", .value = .{ .string = @tagName(direction) } }});
}

/// Record a page-cache lookup result.
pub fn recordPageCacheLookup(outcome: CacheOutcome) void {
    const s = ensureStorage() catch return;
    s.page_cache_lookup.add(1, &.{.{ .key = "geode.cache.outcome", .value = .{ .string = @tagName(outcome) } }});
}

/// Register an observable gauge that reports total on-disk file size for the
/// storage engine. `provider_fn` must be a module-lifetime function pointer
/// returning the current size in bytes; called on each Prometheus scrape.
pub fn registerStorageFileSizeGauge(provider_fn: *const fn () i64) !void {
    g_storage_file_size_provider = provider_fn;
    const m = meter();
    _ = try m.createObservableGauge(
        .{
            .name = "geode.storage.file.size",
            .unit = "By",
            .kind = .observable_gauge,
            .description = "Total size of storage data files in bytes",
        },
        observeStorageFileSize,
        null,
    );
}

/// Register an observable gauge reporting total disk space consumed by the
/// storage directory (data + indexes + WAL).
pub fn registerStorageDiskUsageGauge(provider_fn: *const fn () i64) !void {
    g_storage_disk_usage_provider = provider_fn;
    const m = meter();
    _ = try m.createObservableGauge(
        .{
            .name = "geode.storage.disk.usage",
            .unit = "By",
            .kind = .observable_gauge,
            .description = "Total disk space used by the storage directory in bytes",
        },
        observeStorageDiskUsage,
        null,
    );
}

// ---- WAL public API ----

/// Record a WAL record write (bumps geode.wal.record.count).
pub fn recordWalRecord(rec_type: WalRecordType) void {
    const w = ensureWal() catch return;
    w.record_count.add(1, &.{.{ .key = "geode.wal.record.type", .value = .{ .string = @tagName(rec_type) } }});
}

/// Record bytes written to or replayed from the WAL.
pub fn recordWalBytes(direction: WalIoDir, n_bytes: u64) void {
    const w = ensureWal() catch return;
    w.bytes.add(n_bytes, &.{.{ .key = "geode.io.direction", .value = .{ .string = @tagName(direction) } }});
}

/// Record a WAL record append duration.
pub fn recordWalAppend(duration_s: f64, outcome: Outcome) void {
    const w = ensureWal() catch return;
    w.append_duration.record(duration_s, &.{.{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } }});
}

/// Record a WAL buffer flush duration (write-behind to OS page cache).
pub fn recordWalFlush(duration_s: f64, outcome: Outcome) void {
    const w = ensureWal() catch return;
    w.flush_duration.record(duration_s, &.{.{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } }});
}

/// Record a WAL fsync duration (durable write to storage device).
pub fn recordWalFsync(duration_s: f64, outcome: Outcome) void {
    const w = ensureWal() catch return;
    w.fsync_duration.record(duration_s, &.{.{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } }});
}

/// Register an observable gauge that reports the current logical WAL size
/// (bytes since last checkpoint).
pub fn registerWalSizeGauge(provider_fn: *const fn () i64) !void {
    g_wal_size_provider = provider_fn;
    const m = meter();
    _ = try m.createObservableGauge(
        .{
            .name = "geode.wal.size",
            .unit = "By",
            .kind = .observable_gauge,
            .description = "Current WAL size (bytes since last checkpoint)",
        },
        observeWalSize,
        null,
    );
}

/// Record a full WAL replay (crash-recovery or CDC) duration.
pub fn recordWalReplay(duration_s: f64, outcome: Outcome) void {
    const w = ensureWal() catch return;
    w.replay_duration.record(duration_s, &.{.{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } }});
}

/// Increment the count of records processed during WAL replay.
pub fn recordWalReplayRecord() void {
    const w = ensureWal() catch return;
    w.replay_record_count.add(1, &.{});
}

// -------------------------------------------------------------------------
// Graph data model metrics — geode.graph.* per spec §4.4 P0.
// -------------------------------------------------------------------------

// CANARY: REQ=REQ-OTEL-METRICS-008; FEATURE="OTel Instrumentation"; ASPECT=GraphDataModel; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28

/// Mutation kind for node/edge operation counters.
pub const GraphMutation = enum { create, update, delete };

fn graphMutationName(m: GraphMutation) []const u8 {
    return switch (m) {
        .create => "create",
        .update => "update",
        .delete => "delete",
    };
}

const GraphMetrics = struct {
    node_op_count: otel.api.metrics.Counter,
    edge_op_count: otel.api.metrics.Counter,
};

var g_graph: ?GraphMetrics = null;

// Observable gauge function pointers — set by registerXxxCountGauge.
var g_node_count_provider: ?*const fn () i64 = null;
var g_edge_count_provider: ?*const fn () i64 = null;

fn ensureGraph() !*GraphMetrics {
    if (g_graph) |*g| return g;
    const m = meter();
    g_graph = GraphMetrics{
        .node_op_count = try m.counter(.{
            .name = "geode.graph.node.operation.count",
            .unit = "{operation}",
            .kind = .counter,
            .description = "Total node create/update/delete operations by graph and outcome",
        }),
        .edge_op_count = try m.counter(.{
            .name = "geode.graph.edge.operation.count",
            .unit = "{operation}",
            .kind = .counter,
            .description = "Total edge create/update/delete operations by graph and outcome",
        }),
    };
    return &g_graph.?;
}

fn observeNodeCount(_: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    if (g_node_count_provider) |fnp| {
        observer.observeInt(fnp(), &.{.{ .key = "db.namespace", .value = .{ .string = "default" } }});
    }
}

fn observeEdgeCount(_: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    if (g_edge_count_provider) |fnp| {
        observer.observeInt(fnp(), &.{.{ .key = "db.namespace", .value = .{ .string = "default" } }});
    }
}

/// Register an observable gauge reporting the current live node count.
/// `provider_fn` is called on each Prometheus scrape; it MUST be a
/// module-lifetime function pointer (no closure captures). The gauge emits
/// `db.namespace = "default"` unless the adapter wires a per-graph variant.
///
/// Production-only path: call once from StorageAdapter after engine init.
/// Unit tests exercise the operation counters instead (see smoke test).
pub fn registerNodeCountGauge(provider_fn: *const fn () i64) !void {
    g_node_count_provider = provider_fn;
    const m = meter();
    _ = try m.createObservableGauge(
        .{
            .name = "geode.graph.node.count",
            .unit = "{node}",
            .kind = .observable_gauge,
            .description = "Current number of live nodes per graph namespace",
        },
        observeNodeCount,
        null,
    );
}

/// Register an observable gauge reporting the current live edge count.
/// Same lifetime and threading rules as `registerNodeCountGauge`.
pub fn registerEdgeCountGauge(provider_fn: *const fn () i64) !void {
    g_edge_count_provider = provider_fn;
    const m = meter();
    _ = try m.createObservableGauge(
        .{
            .name = "geode.graph.edge.count",
            .unit = "{edge}",
            .kind = .observable_gauge,
            .description = "Current number of live edges per graph namespace",
        },
        observeEdgeCount,
        null,
    );
}

/// Record a node mutation (create/update/delete). `namespace` is the graph
/// name; defaults to `"default"` when the caller does not have a name.
pub fn recordNodeMutation(op: GraphMutation, namespace: []const u8, outcome: Outcome) void {
    const g = ensureGraph() catch return;
    g.node_op_count.add(1, &.{
        .{ .key = "geode.graph.operation", .value = .{ .string = graphMutationName(op) } },
        .{ .key = "db.namespace", .value = .{ .string = namespace } },
        .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } },
    });
}

/// Record an edge mutation (create/update/delete). Same attribute semantics as
/// `recordNodeMutation`.
pub fn recordEdgeMutation(op: GraphMutation, namespace: []const u8, outcome: Outcome) void {
    const g = ensureGraph() catch return;
    g.edge_op_count.add(1, &.{
        .{ .key = "geode.graph.operation", .value = .{ .string = graphMutationName(op) } },
        .{ .key = "db.namespace", .value = .{ .string = namespace } },
        .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } },
    });
}
