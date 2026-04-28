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
