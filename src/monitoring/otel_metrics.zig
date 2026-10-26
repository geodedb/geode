// CANARY: REQ=REQ-OTEL-FACADE-001; FEATURE="OTel Instrumentation"; ASPECT=Facade; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28
// CANARY: REQ=REQ-OTEL-OTLP-PUSH-001; FEATURE="OTel Instrumentation"; ASPECT=OTLPPush; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28
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
//!
//! OTLP/HTTP push (Task 21):
//!   When `OTEL_METRICS_EXPORTER=otlp` is set in the environment, `init`
//!   additionally wires a `PeriodicMetricReader` backed by an OTLP/HTTP
//!   exporter. The exporter pushes to `OTEL_EXPORTER_OTLP_ENDPOINT`
//!   (default: `http://localhost:4318`) on the interval set by
//!   `OTEL_METRIC_EXPORT_INTERVAL` (default: 60 000 ms). The Prometheus
//!   pull path (`/metrics`) continues to work in parallel — it calls
//!   `Prometheus.render` directly on the MeterProvider, independent of
//!   the periodic reader.
//!
//!   The PeriodicMetricReader is stored in `g_otlp_reader`; `shutdown()`
//!   calls `reader.shutdown()` (which joins the timer thread and flushes
//!   one last time) before tearing down the provider.

const std = @import("std");
const otel = @import("otel");
// Named import: otel_resource is wired as a named dep in build.zig for
// all module contexts that use otel_metrics (test + production). This
// avoids "file exists in two modules" errors when otel_metrics.zig is
// declared as a named module root and otel_resource.zig is simultaneously
// the root of a peer module.
const otel_resource = @import("otel_resource");
// Phase C1: the process-global runtime metrics registry (quic_* / proto_reader_*
// / quic_stream_write_* / poll-phase counters). `registerRuntimeMetricsOtel`
// bridges every entry into OTLP as a `geode.runtime.<name>` observable gauge.
const runtime_metrics = @import("runtime_metrics");

const Resource = otel.sdk.resource.Resource;
const MeterProvider = otel.sdk.metrics.MeterProvider;
const Meter = otel.api.metrics.Meter;
const PeriodicMetricReader = otel.sdk.periodic_metric_reader.PeriodicMetricReader;
const exporter_factory = otel.sdk.exporter_factory;
const sdk_config = otel.sdk.config;
const TracerProvider = otel.sdk.trace.TracerProvider;
const Tracer = otel.api.trace.Tracer;
/// In-memory span/metric/log recorder. Re-exported so unit tests can stage
/// a recorder (`otel_metrics.InMemoryRecorder.init(alloc)`) and pass it to
/// `initForTracingTest` without importing the otel exporters tree directly.
pub const InMemoryRecorder = otel.exporters.in_memory.Recorder;

pub const SCOPE_NAME = "com.geodedb.geode";
pub const SCHEMA_URL = "https://schemas.geodedb.com/otel/geode/metrics/1.0.0";

/// Elapsed instrumentation time uses the monotonic clock, never Unix time.
/// NTP adjustments must not panic in a query's metrics defer or distort latency.
pub const DurationTimer = struct {
    io: std.Io,
    started_ns: i96,

    pub fn start() DurationTimer {
        return startWithIo(std.Io.Threaded.global_single_threaded.io());
    }

    pub fn startWithIo(io: std.Io) DurationTimer {
        return .{ .io = io, .started_ns = std.Io.Clock.awake.now(io).nanoseconds };
    }

    pub fn seconds(self: DurationTimer) f64 {
        const now_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        // An unavailable or faulty clock must not break the instrumented work.
        const elapsed_ns = @max(now_ns -| self.started_ns, 0);
        return @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    }
};

// --- Module-level globals (one per process) ---

var g_provider: ?*MeterProvider = null;
var g_resource: ?*Resource = null;
var g_allocator: ?std.mem.Allocator = null;
var g_init_mu: std.Io.Mutex = std.Io.Mutex.init;

// OTLP/HTTP push: heap-allocated reader + owned exporter bundle, or null
// when OTEL_METRICS_EXPORTER != "otlp".
var g_otlp_reader: ?*PeriodicMetricReader = null;
var g_otlp_exporter: ?exporter_factory.OwnedMetricExporter = null;

// Tracing pipeline: heap-allocated TracerProvider + owned span exporter.
// Wired when OTEL_TRACES_EXPORTER=otlp, or by initForTracingTest when
// running unit tests against an in-memory recorder.
var g_tracer_provider: ?*TracerProvider = null;
var g_tracer_owned_exporter: ?exporter_factory.OwnedSpanExporter = null;

// Periodic span flush. The otel BatchSpanProcessor only spawns its own drain
// timer when built with `-Dotel_use_devnw_pool=true` (export.zig:241,271);
// geode builds otel with the pool OFF (avoids the otel<->thread-pool diamond),
// so without this loop a long-running, low-span-volume server never exports
// spans until the queue hits max_export_batch_size (512) or shutdown. This
// background thread drains the BSP on the BSP-schedule cadence — the trace
// analogue of the PeriodicMetricReader on the metrics side. forceFlush is
// mutex-serialized against producers inside the SDK, so this is concurrency-safe.
var g_tracer_flush_thread: ?std.Thread = null;
var g_tracer_flush_stop: std.atomic.Value(bool) = .init(false);
var g_tracer_flush_interval_ms: u64 = 5_000;

// Same nanosleep idiom as src/server/leaked_conn_reaper.zig. Linux-only; the
// flush thread only runs in the server (never the CLI), and the std.os.linux
// namespace still compiles for cross-target builds.
fn tracerFlushSleep(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

fn tracerFlushLoop() void {
    while (!g_tracer_flush_stop.load(.acquire)) {
        // Chunked wait so shutdown latency is bounded (~100ms) regardless of
        // the configured interval.
        var slept: u64 = 0;
        while (slept < g_tracer_flush_interval_ms) : (slept += 100) {
            if (g_tracer_flush_stop.load(.acquire)) return;
            tracerFlushSleep(@min(@as(u64, 100), g_tracer_flush_interval_ms - slept));
        }
        forceFlushTraces(g_tracer_flush_interval_ms) catch {};
    }
}

// Library binding handles. Each call to `bindLibraryGlobals` allocates a
// stable Tracer / Meter handle on the heap (the lib's `global.tracer`
// pointer needs a value that outlives the binding call). `shutdown()`
// frees them. We over-allocate by tracking pairs to keep cleanup simple.
const LibHandle = struct {
    tracer: ?*Tracer = null,
    meter: ?*Meter = null,
};
var g_lib_handles: std.ArrayListUnmanaged(LibHandle) = .empty;

fn initIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

// -----------------------------------------------------------------------
// Public API
// -----------------------------------------------------------------------

/// Initialise the global MeterProvider. Idempotent: returns immediately
/// if already initialised. Thread-safe via `g_init_mu`.
///
/// OTLP/HTTP push (Task 21): when `OTEL_METRICS_EXPORTER=otlp` is set,
/// a `PeriodicMetricReader` is built and started after the provider is
/// ready. The reader runs on a background thread and pushes metric
/// snapshots to the OTLP/HTTP endpoint. The Prometheus pull path is
/// unaffected.
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

    // --- OTLP export-status summary (DX visibility) ----------------------
    // Emit one unconditional, actionable line about whether OTLP/HTTP push is
    // enabled, and warn if a legacy GEODE_OTEL_* var is set (which geode
    // ignores). This makes the "silently exporting nothing" misconfiguration
    // visible at startup instead of requiring an end-to-end trace to discover.
    // See docs/bugs/2026-06-03-otel-export-not-enabled-wrong-env-vars.md.
    logOtlpExportStatusFromEnv();

    // --- OTLP/HTTP push wiring (Task 21) ---------------------------------
    // Read the OTel env config. Errors are non-fatal: a misconfigured
    // endpoint should not prevent the server from starting. If wiring
    // fails, a warning is logged to stderr and the Prometheus pull path
    // continues working normally.
    tryWireOtlpReader(allocator, provider) catch |err| {
        std.log.warn("otel_metrics: OTLP/HTTP push wiring failed ({s}); falling back to pull-only", .{@errorName(err)});
    };

    // --- Tracing pipeline wiring -----------------------------------------
    // When OTEL_TRACES_EXPORTER=otlp is set, build a TracerProvider that
    // pushes spans to the OTLP/HTTP endpoint. Errors are non-fatal: tracing
    // is opt-in and a misconfigured collector should not prevent geode
    // from starting. The metrics pipeline is independent.
    tryWireOtlpTracer(allocator, resource) catch |err| {
        std.log.warn("otel_metrics: OTLP/HTTP tracer wiring failed ({s}); spans will not be exported", .{@errorName(err)});
    };
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

    // Shut down the OTLP periodic reader BEFORE the provider so the
    // reader's final flush can still collect from live instruments. The
    // reader's shutdown() joins the timer thread internally.
    if (g_otlp_reader) |r| {
        r.deinit();
        if (g_allocator) |a| a.destroy(r);
        g_otlp_reader = null;
    }
    if (g_otlp_exporter) |*e| {
        e.deinit();
        g_otlp_exporter = null;
    }

    // Free library binding handles BEFORE the providers below — the
    // libs' `global.tracer/meter` pointers become dangling once these
    // structs are freed, but the libs are racing nothing at this point
    // (the process is shutting down).
    if (g_allocator) |a| {
        for (g_lib_handles.items) |h| {
            if (h.tracer) |t| a.destroy(t);
            if (h.meter) |m| a.destroy(m);
        }
        g_lib_handles.deinit(a);
    }
    g_lib_handles = .empty;

    // Stop the periodic span-flush thread before tearing down the provider it
    // touches. Join guarantees no in-flight forceFlush races the deinit below.
    if (g_tracer_flush_thread) |t| {
        g_tracer_flush_stop.store(true, .release);
        t.join();
        g_tracer_flush_thread = null;
    }

    // Tear down the tracer pipeline before the resource is freed below.
    // TracerProvider.deinit shuts down processors, which flushes the
    // OTLP/HTTP exporter; the owned exporter is freed afterwards. The
    // resource pointer is shared with g_resource and will be freed once,
    // below — TracerProvider was constructed with `owns_resource = false`
    // because we passed a non-null `resource` field.
    if (g_tracer_provider) |p| {
        p.deinit();
        if (g_allocator) |a| a.destroy(p);
        g_tracer_provider = null;
    }
    if (g_tracer_owned_exporter) |*e| {
        e.deinit();
        g_tracer_owned_exporter = null;
    }
    // Test-path pieces (initForTracingTest). Freed AFTER the provider —
    // provider.deinit() shut the processors down via their vtables, which
    // dereference these structs.
    if (g_test_simple_processor) |sp| {
        if (g_allocator) |a| a.destroy(sp);
        g_test_simple_processor = null;
    }
    if (g_test_locked_exporter) |le| {
        if (g_allocator) |a| a.destroy(le);
        g_test_locked_exporter = null;
    }

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
    // Index + vector metrics state reset.
    g_index = null;
    g_index_count_provider = null;
    // Security / RLS / audit / TDE metrics state reset.
    g_security = null;
    g_audit_queue_depth_provider = null;
    // Distributed + cluster metrics state reset.
    g_distributed = null;
    g_cluster_node_count_provider = null;
    g_shard_count_provider = null;
    // CDC + analytics metrics state reset.
    g_cdc = null;
    g_cdc_lag_provider = null;
    g_cdc_queue_depth_provider = null;
    g_analytics = null;
    g_analytics_queue_depth_provider = null;
    // Backup + restore metrics state reset.
    g_backup = null;
    // Process / runtime + db.client metrics state reset.
    g_runtime_registered = false;
    g_runtime_rss_gauge = null;
    g_runtime_threads_gauge = null;
    g_db_client = null;
    // Phase C1: free the runtime-metrics OTLP bridge ctxs + name strings. Safe
    // here because the provider (and its observable callbacks) was already torn
    // down above, so nothing can dereference these after this point.
    if (g_allocator) |a| {
        for (g_runtime_bridges.items) |rb| {
            a.destroy(rb.bridge);
            a.free(rb.name);
        }
        g_runtime_bridges.deinit(a);
    }
    g_runtime_bridges = .empty;
    g_allocator = null;
}

// -----------------------------------------------------------------------
// OTLP/HTTP push wiring (Task 21)
// -----------------------------------------------------------------------

// --- OTLP export-status classification (DX visibility) ------------------
// Bug 2026-06-03: a deployment set `GEODE_OTEL_ENDPOINT` / `GEODE_OTEL_INSECURE`
// (which geode does NOT read) and left the standard `OTEL_{METRICS,TRACES}_EXPORTER`
// unset, so geode exported nothing — silently. The classification below drives an
// unconditional startup log so that "nothing is being exported" is visible, and a
// warning when a legacy GEODE_OTEL_* var is the likely cause.
// See docs/bugs/2026-06-03-otel-export-not-enabled-wrong-env-vars.md.

/// Status of a single OTLP signal (metrics or traces) exporter, derived from
/// the corresponding `OTEL_{METRICS,TRACES}_EXPORTER` env var.
pub const OtlpSignalStatus = enum {
    /// Env var unset — OTLP push not enabled for this signal (Prometheus pull
    /// / stdout only).
    unset,
    /// Set to `otlp` / `otlp_http` — OTLP/HTTP push enabled for this signal.
    enabled,
    /// Set to `none` — explicitly disabled.
    disabled_none,
    /// Set to some other value (e.g. `prometheus`, `console`) — OTLP push NOT
    /// enabled for this signal.
    other,
};

/// Pure description of geode's OTLP export configuration, derived from the
/// environment without side effects. Produced by `classifyExportStatus` so the
/// decision logic is unit-testable without touching the process environment.
pub const OtelExportStatus = struct {
    metrics: OtlpSignalStatus,
    traces: OtlpSignalStatus,
    /// A legacy, geode-specific `GEODE_OTEL_*` env var is present. geode does
    /// NOT read these — it uses only the standard `OTEL_*` SDK vars — so a set
    /// value is almost always an operator mistake.
    legacy_geode_var_present: bool,

    /// True when OTLP/HTTP push is enabled for at least one signal.
    pub fn anyEnabled(self: OtelExportStatus) bool {
        return self.metrics == .enabled or self.traces == .enabled;
    }

    /// True when a legacy `GEODE_OTEL_*` var is set but neither standard
    /// exporter var enables OTLP — the exact misconfiguration that produces a
    /// silently non-exporting server.
    pub fn legacyMisconfig(self: OtelExportStatus) bool {
        return self.legacy_geode_var_present and !self.anyEnabled();
    }
};

fn classifySignal(value: ?[]const u8) OtlpSignalStatus {
    const v = value orelse return .unset;
    if (sdk_config.ExporterKind.fromString(v) == .otlp_http) return .enabled;
    if (std.ascii.eqlIgnoreCase(v, "none")) return .disabled_none;
    return .other;
}

/// Classify the OTLP export configuration from raw env values. Pure: no
/// `getenv`, no logging, no allocation — callers pass the values they read.
pub fn classifyExportStatus(
    metrics_exporter: ?[]const u8,
    traces_exporter: ?[]const u8,
    legacy_geode_var_present: bool,
) OtelExportStatus {
    return .{
        .metrics = classifySignal(metrics_exporter),
        .traces = classifySignal(traces_exporter),
        .legacy_geode_var_present = legacy_geode_var_present,
    };
}

/// Legacy, geode-specific OTLP env vars that geode does NOT read. Presence of
/// any of these is treated as a likely misconfiguration (the operator reached
/// for `GEODE_OTEL_*` instead of the standard `OTEL_*` SDK vars).
const legacy_geode_otel_vars = [_][*:0]const u8{
    "GEODE_OTEL_ENDPOINT",
    "GEODE_OTEL_INSECURE",
    "GEODE_OTEL_PROTOCOL",
    "GEODE_OTEL_HEADERS",
};

/// Return the name of the first legacy `GEODE_OTEL_*` env var that is set, or
/// `null` if none are.
fn firstLegacyGeodeOtelVar() ?[]const u8 {
    for (legacy_geode_otel_vars) |name| {
        if (getenv(name) != null) return std.mem.sliceTo(name, 0);
    }
    return null;
}

/// Resolve the OTLP endpoint for the startup summary line, mirroring the
/// resolution order used by the metric/trace wiring (shared var, then either
/// per-signal var, then the loopback default).
fn resolvedOtlpEndpointForSummary() []const u8 {
    return getenv("OTEL_EXPORTER_OTLP_ENDPOINT") orelse
        getenv("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT") orelse
        getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT") orelse
        "http://localhost:4318 (default)";
}

/// Emit an unconditional, actionable startup log describing whether OTLP/HTTP
/// push export is enabled. Called once from `init()`. The Prometheus pull path
/// (`/metrics`) is always available regardless of this status.
fn logExportStatus(status: OtelExportStatus, resolved_endpoint: []const u8, legacy_var: ?[]const u8) void {
    if (status.anyEnabled()) {
        std.log.info(
            "otel: OTLP/HTTP push ENABLED (metrics={s} traces={s}) endpoint={s} protocol=http/protobuf; /metrics pull also available",
            .{ @tagName(status.metrics), @tagName(status.traces), resolved_endpoint },
        );
    } else {
        std.log.info(
            "otel: OTLP/HTTP push DISABLED (OTEL_METRICS_EXPORTER/OTEL_TRACES_EXPORTER != otlp); metrics available via /metrics pull only. To enable: set OTEL_METRICS_EXPORTER=otlp OTEL_TRACES_EXPORTER=otlp OTEL_EXPORTER_OTLP_ENDPOINT=http://<collector>:4318 (OTLP/HTTP on port 4318, NOT gRPC 4317)",
            .{},
        );
    }
    if (legacy_var) |name| {
        std.log.warn(
            "otel: env var {s} is set but geode IGNORES it — geode reads only the standard OTEL_* SDK vars, not GEODE_OTEL_*. Use OTEL_METRICS_EXPORTER=otlp / OTEL_TRACES_EXPORTER=otlp / OTEL_EXPORTER_OTLP_ENDPOINT=http://<collector>:4318 instead.",
            .{name},
        );
    }
}

/// Read the environment and emit the startup OTLP export-status summary. Thin
/// wrapper over the pure `classifyExportStatus` + `logExportStatus`.
fn logOtlpExportStatusFromEnv() void {
    const legacy_var = firstLegacyGeodeOtelVar();
    const status = classifyExportStatus(
        getenv("OTEL_METRICS_EXPORTER"),
        getenv("OTEL_TRACES_EXPORTER"),
        legacy_var != null,
    );
    logExportStatus(status, resolvedOtlpEndpointForSummary(), legacy_var);
}

/// Read an env var (no allocation) via `std.c.getenv`. Returns the
/// value slice as a zero-terminated C string borrowed from the process
/// environment block, or `null` if not set. Safe to use before any
/// allocator is available.
fn getenv(name: [*:0]const u8) ?[:0]const u8 {
    const ptr = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(ptr, 0);
}

// std.c.unsetenv is not exposed in Zig 0.16; bind the POSIX symbol directly.
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Detect `OTEL_METRICS_EXPORTER=otlp` in the environment and, when set,
/// construct an OTLP/HTTP metric exporter + PeriodicMetricReader and
/// start the background push loop.
///
/// This function is called from `init()` under `g_init_mu`. Errors
/// propagate to `init()` which logs a warning and continues with the
/// Prometheus pull path.
///
/// Reads (in priority order, most specific wins):
///   `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` (metrics-specific)
///   `OTEL_EXPORTER_OTLP_ENDPOINT`         (shared default)
///   fallback: `http://localhost:4318`
///
/// `OTEL_METRIC_EXPORT_INTERVAL` — push interval in ms (default 60 000)
/// `OTEL_METRIC_EXPORT_TIMEOUT`  — per-export timeout in ms (default 30 000)
///
/// The loopback default `http://localhost:4318` is grandfathered by the
/// OTel SDK `validateEndpoint` so it works without `allow_loopback`.
fn tryWireOtlpReader(allocator: std.mem.Allocator, provider: *MeterProvider) !void {
    // Check OTEL_METRICS_EXPORTER. Only "otlp" / "otlp_http" triggers
    // the periodic push path.
    const exporter_env = getenv("OTEL_METRICS_EXPORTER") orelse return;
    const kind = sdk_config.ExporterKind.fromString(exporter_env);
    if (kind != .otlp_http) return;

    // Resolve endpoint: per-signal var wins over the shared var.
    const default_endpoint = "http://localhost:4318";
    const endpoint: []const u8 =
        getenv("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT") orelse
        getenv("OTEL_EXPORTER_OTLP_ENDPOINT") orelse
        default_endpoint;

    // Resolve interval / timeout (in ms) from env, or use OTel spec defaults.
    const interval_ms: u64 = blk: {
        const s = getenv("OTEL_METRIC_EXPORT_INTERVAL") orelse break :blk 60_000;
        break :blk std.fmt.parseInt(u64, s, 10) catch 60_000;
    };
    const timeout_ms: u64 = blk: {
        const s = getenv("OTEL_METRIC_EXPORT_TIMEOUT") orelse break :blk 30_000;
        break :blk std.fmt.parseInt(u64, s, 10) catch 30_000;
    };

    std.log.info(
        "otel_metrics: OTLP/HTTP push enabled — endpoint={s} interval={d}ms timeout={d}ms",
        .{ endpoint, interval_ms, timeout_ms },
    );

    // Build the OTLP/HTTP metric exporter directly via the factory's
    // lower-level helper, bypassing `Config.resolve` (which uses the
    // POSIX `Environ.Block.global` API that doesn't exist on Linux in
    // Zig 0.16.0). We construct a minimal `OtlpConfig` from the env
    // vars we already read above.
    const otlp_cfg: sdk_config.OtlpConfig = .{
        .endpoint = endpoint,
        .protocol = .http_protobuf,
        .timeout_ms = timeout_ms,
        // The loopback default is grandfathered; user-set loopback needs
        // the allow_loopback flag. We default to false here — operators
        // who point at a loopback collector (other than the OTel default)
        // should set `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=http://127.0.0.1:4318`
        // and also set allow_loopback if the SDK validates it strictly.
        .allow_loopback = false,
    };
    var owned = (try exporter_factory.metricExporterFor(
        allocator,
        .otlp_http,
        otlp_cfg,
    )) orelse return;
    errdefer owned.deinit();

    // Plumb a `std.Io` into the underlying OtlpHttpExporter so its HTTPS
    // path actually fires `std.http.Client.fetch`. Without this, the
    // exporter's `io` field stays null, `httpTransportImpl` returns
    // `error.UnsupportedTransport`, and every export silently drops.
    if (owned.state) |state| {
        const exp_ptr: *otel.exporters.otlp_http.OtlpHttpExporter = @ptrCast(@alignCast(state));
        exp_ptr.io = initIo();
    }

    // Allocate the reader on the heap so its address stays stable once we
    // hand `*provider` into it.
    const reader = try allocator.create(PeriodicMetricReader);
    errdefer allocator.destroy(reader);
    reader.* = try PeriodicMetricReader.init(
        allocator,
        provider,
        owned.exporter,
        .{
            .export_interval_ms = interval_ms,
            .export_timeout_ms = timeout_ms,
        },
    );
    try reader.start();

    g_otlp_reader = reader;
    g_otlp_exporter = owned;
}

// -----------------------------------------------------------------------
// OTLP/HTTP tracer wiring
// -----------------------------------------------------------------------

/// Detect `OTEL_TRACES_EXPORTER=otlp` in the environment and, when set,
/// construct an OTLP/HTTP span exporter and a `TracerProvider` backed by
/// the SDK's default BatchSpanProcessor. The provider takes ownership of
/// the resource pointer (it is shared with the MeterProvider — the resource
/// lifetime is tied to `g_resource`, not to the provider).
///
/// Reads (in priority order, most specific wins):
///   `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` (traces-specific)
///   `OTEL_EXPORTER_OTLP_ENDPOINT`        (shared default)
///   fallback: `http://localhost:4318`
///
/// `OTEL_BSP_SCHEDULE_DELAY` — batch flush interval in ms (default 5_000)
/// `OTEL_BSP_EXPORT_TIMEOUT` — per-export timeout in ms (default 30_000)
///
/// Errors propagate to `init()` which logs a warning and continues.
fn tryWireOtlpTracer(allocator: std.mem.Allocator, resource: *Resource) !void {
    const exporter_env = getenv("OTEL_TRACES_EXPORTER") orelse return;
    const kind = sdk_config.ExporterKind.fromString(exporter_env);
    if (kind != .otlp_http) return;

    const default_endpoint = "http://localhost:4318";
    const endpoint: []const u8 =
        getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT") orelse
        getenv("OTEL_EXPORTER_OTLP_ENDPOINT") orelse
        default_endpoint;

    const timeout_ms: u64 = blk: {
        const s = getenv("OTEL_BSP_EXPORT_TIMEOUT") orelse break :blk 30_000;
        break :blk std.fmt.parseInt(u64, s, 10) catch 30_000;
    };
    const schedule_delay_ms: u64 = blk: {
        const s = getenv("OTEL_BSP_SCHEDULE_DELAY") orelse break :blk 5_000;
        break :blk std.fmt.parseInt(u64, s, 10) catch 5_000;
    };

    std.log.info(
        "otel_metrics: OTLP/HTTP tracer enabled — endpoint={s} schedule_delay={d}ms timeout={d}ms",
        .{ endpoint, schedule_delay_ms, timeout_ms },
    );

    const otlp_cfg: sdk_config.OtlpConfig = .{
        .endpoint = endpoint,
        .protocol = .http_protobuf,
        .timeout_ms = timeout_ms,
        .allow_loopback = false,
    };
    var owned = (try exporter_factory.spanExporterFor(
        allocator,
        .otlp_http,
        otlp_cfg,
    )) orelse return;
    errdefer owned.deinit();

    // Plumb a `std.Io` into the underlying OtlpHttpExporter — see the
    // matching block in tryWireOtlpReader for rationale. Without this,
    // every BatchSpanProcessor flush returns UnsupportedTransport and
    // spans never reach the collector.
    if (owned.state) |state| {
        const exp_ptr: *otel.exporters.otlp_http.OtlpHttpExporter = @ptrCast(@alignCast(state));
        exp_ptr.io = initIo();
    }

    const provider = try allocator.create(TracerProvider);
    errdefer allocator.destroy(provider);
    provider.* = try TracerProvider.init(allocator, .{
        .resource = resource,
        .default_exporter = owned.exporter,
        .bsp_options = .{
            .schedule_delay_ms = schedule_delay_ms,
            .export_timeout_ms = timeout_ms,
        },
        .disabled = false,
    });

    g_tracer_provider = provider;
    g_tracer_owned_exporter = owned;

    // Start the geode-side periodic span flush (the no-pool BSP has no timer).
    // Flush on the BSP schedule delay so spans reach the collector promptly.
    g_tracer_flush_interval_ms = schedule_delay_ms;
    g_tracer_flush_stop.store(false, .release);
    g_tracer_flush_thread = std.Thread.spawn(.{}, tracerFlushLoop, .{}) catch null;
}

/// Test-only: mutex-guarded pass-through `SpanExporter`. The in-memory
/// recorder's ArrayList appends are NOT thread-safe, and with the
/// synchronous `SimpleSpanProcessor` below every `span.end()` exports
/// inline on the *calling* thread — the span-concurrency test ends spans
/// from 8 threads at once. The BSP used to serialize via its queue mutex;
/// this wrapper restores that guarantee on the Simple path.
///
/// Export errors are logged (warn) before propagating: the 2026-07-13 CI
/// flake was silent span loss, and a named failure beats a mystery zero.
const LockedRecorderExporter = struct {
    mu: std.Io.Mutex = std.Io.Mutex.init,
    inner: otel.sdk.exporter.SpanExporter,

    fn exporter(self: *LockedRecorderExporter) otel.sdk.exporter.SpanExporter {
        return .{ .ctx = self, .exportFn = expSpans, .shutdownFn = shut, .forceFlushFn = flush };
    }

    fn expSpans(ctx: ?*anyopaque, items: []const otel.sdk.exporter.SpanData) anyerror!otel.sdk.exporter.SpanExportResult {
        const self: *LockedRecorderExporter = @ptrCast(@alignCast(ctx.?));
        const io = initIo();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        return self.inner.exportSpans(items) catch |err| {
            std.log.warn("otel_metrics: test recorder span export failed ({s}) — spans lost", .{@errorName(err)});
            return err;
        };
    }

    fn flush(ctx: ?*anyopaque, timeout_ms: u64) anyerror!void {
        const self: *LockedRecorderExporter = @ptrCast(@alignCast(ctx.?));
        const io = initIo();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        return self.inner.forceFlush(timeout_ms);
    }

    fn shut(ctx: ?*anyopaque) void {
        const self: *LockedRecorderExporter = @ptrCast(@alignCast(ctx.?));
        self.inner.shutdown();
    }
};

var g_test_simple_processor: ?*otel.sdk.exporter.SimpleSpanProcessor = null;
var g_test_locked_exporter: ?*LockedRecorderExporter = null;

/// Test-only: wire a `TracerProvider` against a caller-supplied in-memory
/// recorder so unit tests can assert on emitted spans without spinning up
/// an OTLP collector. Uses `SimpleSpanProcessor` for synchronous export so
/// `forceFlushTraces` is unnecessary, but the public flush API is still
/// honoured for symmetry with production.
///
/// 2026-07-13: this comment used to LIE — the implementation passed
/// `default_exporter`, which ADR-0003 wires to a BatchSpanProcessor. The
/// BSP queues spans and silently DROPS them on allocation failure
/// (`exportBatch`'s alloc-failure path recycles the whole batch), so on
/// memory-squeezed CI runner pods the delivery-asserting otel tests
/// intermittently saw `expected N, found 0` (reproduced locally under
/// `ulimit -v 16000`). Now it really does wire a SimpleSpanProcessor via
/// `processors` — synchronous inline export on `end()`, no queue layer to
/// drop from — behind the locked exporter wrapper above.
///
/// Caller owns `recorder` and must keep it alive across `shutdown()`.
pub fn initForTracingTest(allocator: std.mem.Allocator, recorder: *InMemoryRecorder) !void {
    // GitLab CI runners export ambient OTEL_TRACES_EXPORTER=otlp / OTEL_EXPORTER_
    // OTLP_* env for THEIR OWN tracing. init() below honours those and auto-wires
    // an OTLP TracerProvider — after which the `g_tracer_provider != null`
    // early-return skips wiring OUR in-memory recorder, so the recorder stays
    // EMPTY and every span-count assertion sees 0. That is a DETERMINISTIC CI-ONLY
    // failure (these tests pass locally, where the env is unset). Clear the
    // ambient OTLP env BEFORE init() so the caller's recorder is the sole span
    // exporter for the test. (Tearing an already-installed OTLP provider down via
    // shutdown() instead crashes on the dead-endpoint flush, so prevent it here.)
    _ = unsetenv("OTEL_TRACES_EXPORTER");
    _ = unsetenv("OTEL_EXPORTER_OTLP_ENDPOINT");
    _ = unsetenv("OTEL_EXPORTER_OTLP_PROTOCOL");

    // Bootstrap the MeterProvider first (its own init takes the lock).
    if (g_provider == null) try initForTesting(allocator);

    g_init_mu.lockUncancelable(initIo());
    defer g_init_mu.unlock(initIo());
    if (g_tracer_provider != null) return;

    const resource = g_resource orelse return error.MeterProviderNotInitialised;

    const locked = try allocator.create(LockedRecorderExporter);
    errdefer allocator.destroy(locked);
    locked.* = .{ .inner = recorder.spanExporter() };

    const ssp = try allocator.create(otel.sdk.exporter.SimpleSpanProcessor);
    errdefer allocator.destroy(ssp);
    ssp.* = otel.sdk.exporter.SimpleSpanProcessor.init(allocator, locked.exporter(), resource);

    const provider = try allocator.create(TracerProvider);
    errdefer allocator.destroy(provider);
    provider.* = try TracerProvider.init(allocator, .{
        .resource = resource,
        .processors = &.{ssp.processor()},
        .disabled = false,
    });
    g_tracer_provider = provider;
    g_tracer_owned_exporter = null;
    g_test_simple_processor = ssp;
    g_test_locked_exporter = locked;
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

/// Return a `Tracer` scoped to Geode's instrumentation library.
/// If called before `init` or after `shutdown` (or when no
/// `TracerProvider` was wired because `OTEL_TRACES_EXPORTER` was unset),
/// returns an inert noop `Tracer` whose `startSpan` calls collapse to
/// `Span.noop` without touching the SDK pipeline.
pub fn tracer() Tracer {
    if (g_tracer_provider) |p| {
        return p.tracer(.{
            .name = SCOPE_NAME,
            .version = otel.version,
            .schema_url = SCHEMA_URL,
        });
    }
    return .{ .scope = .{ .name = SCOPE_NAME } };
}

// -----------------------------------------------------------------------
// Span facade (Phase B tracing)
// -----------------------------------------------------------------------

const Span = otel.api.trace.Span;
const Context = otel.api.context.Context;
// Note: `attrs` (otel.internal.attributes) is aliased module-level further
// down; module consts are order-independent, so `attrs.Entry` resolves here.

/// Serializes span CREATION (id generation). The otel `id_generator` is a
/// shared `std.Random.DefaultPrng` that is NOT safe for concurrent
/// `nextTraceId`/`nextSpanId` from multiple QUIC query threads. Same
/// discipline as `g_query_mu` for the metric SDK. Held only across
/// `startSpan` (nanoseconds), never across span body execution.
var g_span_mu: std.Io.Mutex = std.Io.Mutex.init;

/// Thread-confined span wrapper that guarantees the underlying otel
/// `Span.end()` is invoked EXACTLY ONCE, even if geode code double-ends
/// (e.g. a `defer` plus an explicit end, or a future refactor that shares
/// the span). This closes the otel BatchSpanProcessor span-reuse UAF at the
/// geode boundary — that UAF requires a concurrent *double-end* of the same
/// span, which the per-span atomic here makes impossible.
///
/// Spans are thread-confined: created and ended on one request thread. The
/// atomic only guards against accidental double-end, not cross-thread use.
pub const GeodeSpan = struct {
    span: Span,
    ended: std.atomic.Value(bool) = .init(false),

    /// End the span exactly once. The first call records the end and drains
    /// to the processor; any subsequent call is a no-op.
    pub fn end(self: *GeodeSpan) void {
        if (self.ended.swap(true, .acq_rel)) return;
        self.span.end(null);
    }

    /// Attach a bounded integer attribute (e.g. row_count). Errors are
    /// swallowed: instrumentation must never fail a query.
    pub fn setIntAttr(self: *GeodeSpan, key: []const u8, value: i64) void {
        self.span.setIntAttribute(key, value) catch {};
    }

    /// Attach a bounded string attribute. The caller MUST pass an enum-like
    /// value (op name, graph name) — never raw query text or user values.
    pub fn setStrAttr(self: *GeodeSpan, key: []const u8, value: []const u8) void {
        self.span.setStringAttribute(key, value) catch {};
    }

    /// Mark the span as failed and record the bounded error type name.
    pub fn setError(self: *GeodeSpan, err: anyerror) void {
        self.setErrorName(@errorName(err));
    }

    /// Mark error with an already-resolved error name (bounded — pass an
    /// @errorName, never user content). Used where the concrete error value
    /// is not capturable (inferred-error-set functions).
    pub fn setErrorName(self: *GeodeSpan, name: []const u8) void {
        self.span.setStatus(.@"error", name);
        self.span.setStringAttribute("error.type", name) catch {};
    }

    /// Mark the span as successful.
    pub fn setOk(self: *GeodeSpan) void {
        self.span.setStatus(.ok, "");
    }
};

/// Start a `geode.query.execute` SERVER span (new trace; cross-process
/// context propagation from the client traceparent is a later phase).
///
/// `op_name` MUST be a BOUNDED enum-like string (MATCH/CREATE/INSERT/…).
/// `namespace` is the current graph name (bounded). `is_mutation` records
/// whether the statement writes. NEVER pass raw query text, parameter
/// values, or user-supplied keys — those are unbounded cardinality.
///
/// When no TracerProvider is wired (`OTEL_TRACES_EXPORTER` unset, or otel never
/// initialised), this returns a noop `GeodeSpan` LOCK-FREE — `g_span_mu` is only
/// taken when a real tracer exists (the mutex exists solely to serialise the
/// non-thread-safe otel id-generator). This keeps the per-query span path at
/// zero cost (no mutex, no allocation) when tracing is off, so instrumentation
/// never serialises concurrent queries on the disabled default path.
pub fn startQuerySpan(op_name: []const u8, namespace: []const u8, is_mutation: bool) GeodeSpan {
    if (g_tracer_provider == null) return .{ .span = Span.noop };
    const t = tracer();
    const io = initIo();
    g_span_mu.lockUncancelable(io);
    defer g_span_mu.unlock(io);
    const attrs_buf = [_]attrs.Entry{
        .{ .key = "db.system.name", .value = .{ .string = "codepros.geode" } },
        .{ .key = "db.operation.name", .value = .{ .string = op_name } },
        .{ .key = "db.namespace", .value = .{ .string = namespace } },
        .{ .key = "geode.query.is_mutation", .value = .{ .bool = is_mutation } },
    };
    const span = t.startSpan(Context.empty(), "geode.query.execute", .{
        .kind = .server,
        .initial_attributes = &attrs_buf,
    }) catch return .{ .span = Span.noop };
    return .{ .span = span };
}

/// Force a flush of all pending spans through the wired processors.
/// Safe to call when no tracer provider is active — returns immediately.
pub fn forceFlushTraces(timeout_ms: u64) !void {
    if (g_tracer_provider) |p| try p.forceFlush(timeout_ms);
}

/// Bind a dependent library's `observability` seam to geode's
/// TracerProvider + MeterProvider so spans/metrics emitted by that
/// library land in geode's OTLP/HTTP pipeline.
///
/// `LibObservability` MUST be the named module re-exported by a CodePros
/// DevNW library that follows the canonical observability seam (the lib
/// exposes `pub const enabled: bool` and `pub const global = struct {
/// pub var tracer: ?*Tracer; pub var meter: ?*Meter; }`). At time of
/// writing this matches: wal, gql, repl, dns, slog, vulkan, protobuf,
/// thread_pool — see `docs/otel-updates.md` for the full list.
///
/// The lib MUST be built with `-Dwith_otel=true` for the seam to actually
/// emit spans; when built with the default `-Dwith_otel=false`, the
/// `global` struct collapses to `struct {}` and this function compiles
/// to a comptime no-op (zero binary impact).
///
/// Each successful call allocates one `Tracer` + one `Meter` on the
/// global allocator. Both are freed by `shutdown()`. Calls are
/// idempotent only across distinct `(LibObservability, scope_name)`
/// pairs — calling twice with the same library leaks the previous
/// handles without unbinding them.
pub fn bindLibraryGlobals(
    comptime LibObservability: type,
    comptime scope_name: []const u8,
) !void {
    if (comptime !@hasDecl(LibObservability, "enabled") or !LibObservability.enabled) {
        return;
    }

    g_init_mu.lockUncancelable(initIo());
    defer g_init_mu.unlock(initIo());

    const allocator = g_allocator orelse return error.OtelNotInitialised;
    var handle: LibHandle = .{};

    if (g_tracer_provider) |tp| {
        const t = try allocator.create(Tracer);
        errdefer allocator.destroy(t);
        t.* = tp.tracer(.{
            .name = scope_name,
            .version = otel.version,
            .schema_url = SCHEMA_URL,
        });
        LibObservability.global.tracer = t;
        handle.tracer = t;
    }

    if (g_provider) |mp| {
        const m = try allocator.create(Meter);
        errdefer allocator.destroy(m);
        m.* = mp.meter(.{
            .name = scope_name,
            .version = otel.version,
            .schema_url = SCHEMA_URL,
        });
        LibObservability.global.meter = m;
        handle.meter = m;
    }

    if (handle.tracer != null or handle.meter != null) {
        try g_lib_handles.append(allocator, handle);
    }
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

/// Bounded set of transport connection-close reasons. SONNY-1806: a closed
/// enum keeps `geode.close.reason` low-cardinality and typo-proof. Tag names
/// are the exact label values emitted (via @tagName).
pub const CloseReason = enum { client_close, server_close, idle_timeout, protocol_error, destroy };

pub fn recordTransportConnectionClosed(reason: CloseReason) void {
    const t = ensureTransport() catch return;
    t.connection_closed.add(1, &.{attrs.Entry{ .key = "geode.close.reason", .value = .{ .string = @tagName(reason) } }});
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
// Runtime-metrics registry → OTLP bridge (Phase C1).
//
// geode computes a rich set of runtime counters/gauges (quic_*, proto_reader_*,
// quic_stream_write_*, poll-phase ns) in a process-global
// `runtime_metrics.Registry`. They render to Prometheus /metrics but did not
// reach OTLP. `registerRuntimeMetricsOtel` creates one OTel observable gauge
// per registry entry, named `geode.runtime.<original_name>`, backed by a heap
// bridge that reads the source atomic/callback at OTel collection time.
// -------------------------------------------------------------------------

// CANARY: REQ=REQ-OTEL-METRICS-RUNTIME-BRIDGE-001; FEATURE="OTel Instrumentation"; ASPECT=RuntimeCounterBridge; STATUS=TESTED; TEST=tests/test_otel_runtime_bridge.zig; OWNER=monitoring; UPDATED=2026-05-29

// Heap bridge so an OTel observable callback (single ?*anyopaque ctx) can carry
// either a counter atomic ptr or a runtime Gauge{callback,ctx}. The read path is
// bounded + safe: an atomic load for counters, or the registry gauge callback
// (cheap field reads / a brief connection-mutex at collection cadence; no
// unbounded labels).
const RuntimeBridge = struct {
    counter_ptr: ?*std.atomic.Value(u64) = null,
    gauge_cb: ?*const fn (*anyopaque) u64 = null,
    gauge_ctx: ?*anyopaque = null,

    fn read(self: *const RuntimeBridge) i64 {
        if (self.counter_ptr) |p| return @intCast(p.load(.acquire));
        if (self.gauge_cb) |cb| return @intCast(cb(self.gauge_ctx.?));
        return 0;
    }
};

fn observeRuntimeBridge(ctx: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    const b: *const RuntimeBridge = @ptrCast(@alignCast(ctx.?));
    observer.observeInt(b.read(), &.{});
}

// Process-lifetime storage for the bridge ctxs + their `geode.runtime.<name>`
// strings. These outlive `registerRuntimeMetricsOtel` (the meter holds the
// callback ctx + descriptor name for the life of the provider) and are freed
// ONLY in `shutdown()`, after the provider is torn down. Same ownership idiom
// as `g_lib_handles`.
const RuntimeBridgeAlloc = struct {
    bridge: *RuntimeBridge,
    name: []const u8,
};
var g_runtime_bridges: std.ArrayListUnmanaged(RuntimeBridgeAlloc) = .empty;

/// Export every entry of the runtime metrics Registry as a `geode.runtime.<name>`
/// OTel observable gauge. Call ONCE at startup AFTER the registry is fully
/// populated. No-op when the OTLP meter provider is not active.
///
/// Lifetime: the `geode.runtime.<name>` name strings and the per-entry
/// `RuntimeBridge` structs are allocated on `g_allocator` and registered as the
/// instrument descriptor / callback ctx for the LIFE OF THE PROVIDER. They are
/// intentionally NOT freed here — the meter holds them until `shutdown()` tears
/// the whole provider down and then frees them via `g_runtime_bridges` (the
/// same owned-handle idiom as `g_lib_handles`). Freeing them while the provider
/// lives would dangle the observable callbacks. (Bounded, one-shot allocation
/// at startup.)
pub fn registerRuntimeMetricsOtel(registry: *runtime_metrics.Registry) !void {
    if (g_provider == null) return; // metrics pipeline not active -> nothing to do
    const alloc = g_allocator orelse return;
    const m = meter();
    const io = initIo();

    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);

    for (registry.counters.items) |c| {
        const name = try std.fmt.allocPrint(alloc, "geode.runtime.{s}", .{c.name});
        errdefer alloc.free(name);
        const b = try alloc.create(RuntimeBridge);
        errdefer alloc.destroy(b);
        b.* = .{ .counter_ptr = c.ptr };
        try g_runtime_bridges.append(alloc, .{ .bridge = b, .name = name });
        _ = try m.createObservableGauge(
            .{ .name = name, .unit = "", .kind = .observable_gauge, .description = c.name },
            observeRuntimeBridge,
            b,
        );
    }
    for (registry.gauges.items) |g| {
        const name = try std.fmt.allocPrint(alloc, "geode.runtime.{s}", .{g.name});
        errdefer alloc.free(name);
        const b = try alloc.create(RuntimeBridge);
        errdefer alloc.destroy(b);
        b.* = .{ .gauge_cb = g.callback, .gauge_ctx = g.ctx };
        try g_runtime_bridges.append(alloc, .{ .bridge = b, .name = name });
        _ = try m.createObservableGauge(
            .{ .name = name, .unit = "", .kind = .observable_gauge, .description = g.name },
            observeRuntimeBridge,
            b,
        );
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
// CANARY: REQ=REQ-QUIC-HC-039; FEATURE="QUIC High-Concurrency Requests"; ASPECT=QueryMetricThreadSafety; STATUS=IMPL; OWNER=monitoring; UPDATED=2026-05-26
// The vendored OTel metric SDK is not safe for concurrent lazy init/record
// from hundreds of query threads. Guard query metric handles and add/record
// calls behind one small facade mutex so instrumentation cannot crash the
// server during high-fanout QUIC workloads.
var g_query_mu: std.Io.Mutex = std.Io.Mutex.init;

fn ensureQueryLocked() !*QueryMetrics {
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
    if (g_provider == null) return; // lock-free when metrics off (no mutex contention)
    const io = initIo();
    g_query_mu.lockUncancelable(io);
    defer g_query_mu.unlock(io);
    const q = ensureQueryLocked() catch return;
    q.active.add(1, &.{.{ .key = "geode.query.type", .value = .{ .string = @tagName(qt) } }});
}

pub fn decQueryActive(qt: QueryType) void {
    if (g_provider == null) return;
    const io = initIo();
    g_query_mu.lockUncancelable(io);
    defer g_query_mu.unlock(io);
    const q = ensureQueryLocked() catch return;
    q.active.add(-1, &.{.{ .key = "geode.query.type", .value = .{ .string = @tagName(qt) } }});
}

/// Record a completed query execution. Also bumps geode.query.count so the
/// count and duration sample are always correlated (per spec §4.3).
pub fn recordQueryExecution(op: []const u8, summary: []const u8, qt: QueryType, duration_s: f64, outcome: Outcome, error_type: ?[]const u8) void {
    _ = summary;
    if (g_provider == null) return; // lock-free when metrics off
    const io = initIo();
    g_query_mu.lockUncancelable(io);
    defer g_query_mu.unlock(io);
    const q = ensureQueryLocked() catch return;
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
    if (g_provider == null) return;
    const io = initIo();
    g_query_mu.lockUncancelable(io);
    defer g_query_mu.unlock(io);
    const q = ensureQueryLocked() catch return;
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
    if (g_provider == null) return;
    const io = initIo();
    g_query_mu.lockUncancelable(io);
    defer g_query_mu.unlock(io);
    const q = ensureQueryLocked() catch return;
    q.parse_error_count.add(1, &.{.{ .key = "error.type", .value = .{ .string = error_type } }});
}

/// Bounded set of query planner strategies. SONNY-1806: closed enum bounds the
/// `geode.planner.strategy` label. Tag names are the emitted label values.
pub const PlannerStrategy = enum { cbo, rbo, heuristic };

pub fn recordQueryPlan(op: []const u8, duration_s: f64, planner_strategy: PlannerStrategy) void {
    if (g_provider == null) return;
    const io = initIo();
    g_query_mu.lockUncancelable(io);
    defer g_query_mu.unlock(io);
    const q = ensureQueryLocked() catch return;
    q.plan_duration.record(duration_s, &.{
        .{ .key = "db.operation.name", .value = .{ .string = op } },
        .{ .key = "geode.planner.strategy", .value = .{ .string = @tagName(planner_strategy) } },
    });
}

pub fn recordQueryRowsReturned(op: []const u8, summary: []const u8, rows: u64) void {
    _ = summary;
    if (g_provider == null) return;
    const io = initIo();
    g_query_mu.lockUncancelable(io);
    defer g_query_mu.unlock(io);
    const q = ensureQueryLocked() catch return;
    q.rows_returned.record(@floatFromInt(rows), &.{.{ .key = "db.operation.name", .value = .{ .string = op } }});
}

pub fn recordQueryTimeout(op: []const u8, kind: TimeoutKind) void {
    if (g_provider == null) return;
    const io = initIo();
    g_query_mu.lockUncancelable(io);
    defer g_query_mu.unlock(io);
    const q = ensureQueryLocked() catch return;
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

// SONNY-1805: number of buckets a raw graph namespace can hash into. Keeps
// `db.namespace` cardinality bounded (this many + the "default" literal).
const graph_id_buckets: u64 = 64;

/// Map a graph namespace to a bounded, stable metric-attribute id.
///
/// The raw graph name is a per-tenant pseudonym and an unbounded-cardinality
/// value — it MUST NOT be emitted as a metric label (privacy + cardinality
/// blow-up). `"default"` is preserved verbatim so this path aligns with the
/// observable node/edge-count gauges, which emit `db.namespace = "default"`.
/// Every other name hashes (FNV-1a 64, stable across runs) into one of
/// `graph_id_buckets` fixed buckets rendered as `ns-<n>`. `buf` must be the
/// caller's stack buffer (>= 24 bytes); the returned slice borrows it.
fn boundedGraphId(namespace: []const u8, buf: []u8) []const u8 {
    if (std.mem.eql(u8, namespace, "default")) return "default";
    var h: u64 = 0xcbf29ce484222325;
    for (namespace) |c| {
        h ^= c;
        h *%= 0x100000001b3;
    }
    return std.fmt.bufPrint(buf, "ns-{d}", .{h % graph_id_buckets}) catch "ns-?";
}

/// Record a node mutation (create/update/delete). `namespace` is the graph
/// name; it is mapped to a bounded id (see `boundedGraphId`) before emission so
/// the raw per-tenant name never reaches the metric label.
pub fn recordNodeMutation(op: GraphMutation, namespace: []const u8, outcome: Outcome) void {
    const g = ensureGraph() catch return;
    var ns_buf: [24]u8 = undefined;
    g.node_op_count.add(1, &.{
        .{ .key = "geode.graph.operation", .value = .{ .string = graphMutationName(op) } },
        .{ .key = "db.namespace", .value = .{ .string = boundedGraphId(namespace, &ns_buf) } },
        .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } },
    });
}

/// Record an edge mutation (create/update/delete). Same attribute semantics as
/// `recordNodeMutation` — the raw namespace is bounded before emission.
pub fn recordEdgeMutation(op: GraphMutation, namespace: []const u8, outcome: Outcome) void {
    const g = ensureGraph() catch return;
    var ns_buf: [24]u8 = undefined;
    g.edge_op_count.add(1, &.{
        .{ .key = "geode.graph.operation", .value = .{ .string = graphMutationName(op) } },
        .{ .key = "db.namespace", .value = .{ .string = boundedGraphId(namespace, &ns_buf) } },
        .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } },
    });
}

// -------------------------------------------------------------------------
// Index + vector metrics — geode.index.* per spec §4.7 P0.
// -------------------------------------------------------------------------

// CANARY: REQ=REQ-OTEL-METRICS-009; FEATURE="OTel Instrumentation"; ASPECT=IndexVector; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28

/// Index structure types tracked by geode.index.* metrics.
pub const IndexType = enum { btree, hash, full_text, spatial, vector_hnsw, interval };

/// Distance metrics used by HNSW vector searches.
pub const VectorMetric = enum { l2, cosine, dot, hamming, jaccard, manhattan };

fn indexTypeName(t: IndexType) []const u8 {
    return switch (t) {
        .btree => "btree",
        .hash => "hash",
        .full_text => "full_text",
        .spatial => "spatial",
        .vector_hnsw => "vector_hnsw",
        .interval => "interval",
    };
}

fn vectorMetricName(m: VectorMetric) []const u8 {
    return switch (m) {
        .l2 => "l2",
        .cosine => "cosine",
        .dot => "dot",
        .hamming => "hamming",
        .jaccard => "jaccard",
        .manhattan => "manhattan",
    };
}

const IndexMetrics = struct {
    lookup_duration: otel.api.metrics.Histogram,
    lookup_count: otel.api.metrics.Counter,
    update_duration: otel.api.metrics.Histogram,
    hnsw_search_duration: otel.api.metrics.Histogram,
};

var g_index: ?IndexMetrics = null;
var g_index_count_provider: ?*const fn () i64 = null;

fn ensureIndex() !*IndexMetrics {
    if (g_index) |*idx| return idx;
    const m = meter();
    g_index = IndexMetrics{
        .lookup_duration = try m.histogram(.{
            .name = "geode.index.lookup.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "Index point-lookup duration in seconds",
            .explicit_buckets = .{ .boundaries = buckets_storage_io_duration },
        }),
        .lookup_count = try m.counter(.{
            .name = "geode.index.lookup.count",
            .unit = "{lookup}",
            .kind = .counter,
            .description = "Total index point-lookups by type and outcome",
        }),
        .update_duration = try m.histogram(.{
            .name = "geode.index.update.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "Index insert/update/delete duration in seconds",
            .explicit_buckets = .{ .boundaries = buckets_storage_io_duration },
        }),
        .hnsw_search_duration = try m.histogram(.{
            .name = "geode.index.vector.hnsw.search.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "HNSW approximate nearest-neighbour search duration in seconds",
            .explicit_buckets = .{ .boundaries = buckets_db_client_duration },
        }),
    };
    return &g_index.?;
}

fn observeIndexCount(_: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    if (g_index_count_provider) |fnp| {
        observer.observeInt(fnp(), &.{});
    }
}

/// Register an observable gauge that reports the total number of live indexes.
/// `provider_fn` MUST be a module-lifetime function pointer; called on each
/// Prometheus scrape. Idempotent — duplicate registrations are silently ignored
/// by the OTel SDK.
pub fn registerIndexCountGauge(provider_fn: *const fn () i64) !void {
    g_index_count_provider = provider_fn;
    const m = meter();
    _ = try m.createObservableGauge(
        .{
            .name = "geode.index.count",
            .unit = "{index}",
            .kind = .observable_gauge,
            .description = "Total number of live indexes per index type",
        },
        observeIndexCount,
        null,
    );
}

/// Record a completed index point-lookup. Also bumps geode.index.lookup.count
/// so count and duration are always correlated (per spec §4.7).
pub fn recordIndexLookup(idx_type: IndexType, duration_s: f64, outcome: Outcome) void {
    const idx = ensureIndex() catch return;
    const type_attr = attrs.Entry{ .key = "geode.index.type", .value = .{ .string = indexTypeName(idx_type) } };
    const outcome_attr = attrs.Entry{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } };
    idx.lookup_duration.record(duration_s, &.{ type_attr, outcome_attr });
    idx.lookup_count.add(1, &.{ type_attr, outcome_attr });
}

/// Record a completed index insert/update/delete.
pub fn recordIndexUpdate(idx_type: IndexType, op: GraphMutation, duration_s: f64) void {
    const idx = ensureIndex() catch return;
    idx.update_duration.record(duration_s, &.{
        .{ .key = "geode.index.type", .value = .{ .string = indexTypeName(idx_type) } },
        .{ .key = "geode.graph.operation", .value = .{ .string = graphMutationName(op) } },
    });
}

/// Record a completed HNSW approximate-nearest-neighbour search.
pub fn recordHnswSearch(metric: VectorMetric, duration_s: f64) void {
    const idx = ensureIndex() catch return;
    idx.hnsw_search_duration.record(duration_s, &.{
        .{ .key = "geode.vector.metric", .value = .{ .string = vectorMetricName(metric) } },
    });
}

// -------------------------------------------------------------------------
// Security / RLS / audit / TDE / KMS metrics — geode.security.* +
// geode.audit.* + geode.crypto.* per spec §4.8 P0.
//
// Privacy rule (spec §4.8 §7): NEVER include usernames, raw tokens, key
// IDs, policy text, query property values, or session IDs as metric
// attributes. All facade functions accept typed enums or low-cardinality
// string labels only.
// -------------------------------------------------------------------------

// CANARY: REQ=REQ-OTEL-METRICS-010; FEATURE="OTel Instrumentation"; ASPECT=SecurityRLSAuditTDE; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28

/// Authentication method — low-cardinality enum; NEVER pass a username here.
pub const AuthMethod = enum { password, mfa, certificate, api_key, hmac_chain };

/// Session lifecycle state.
pub const SessionState = enum { active, idle, terminated };

/// Binary access-control decision.
pub const SecurityDecision = enum { allow, deny };

/// Policy framework that produced an authorization decision.
pub const PolicyType = enum { rbac, abac, rls, tde };

/// Cryptographic operation kind for TDE/KMS instrumentation.
pub const CryptoOp = enum { encrypt, decrypt, rotate, derive };

const SecurityMetrics = struct {
    // geode.security.authentication.attempt.count
    auth_attempt_count: otel.api.metrics.Counter,
    // geode.security.authentication.duration (GAP-0874: real histogram,
    // previously a counter-only stub that discarded the duration)
    auth_duration: otel.api.metrics.Histogram,
    // geode.security.session.count (up-down, +1 on open, -1 on close)
    session_count: otel.api.metrics.UpDownCounter,
    // geode.security.authorization.check.count
    authz_check_count: otel.api.metrics.Counter,
    // geode.security.authorization.check.duration
    authz_check_duration: otel.api.metrics.Histogram,
    // geode.security.rls.evaluation.count
    rls_eval_count: otel.api.metrics.Counter,
    // geode.security.rls.evaluation.duration
    rls_eval_duration: otel.api.metrics.Histogram,
    // geode.audit.event.count
    audit_event_count: otel.api.metrics.Counter,
    // geode.audit.event.dropped
    audit_event_dropped: otel.api.metrics.Counter,
    // geode.crypto.tde.operation.duration
    tde_op_duration: otel.api.metrics.Histogram,
    // geode.crypto.tde.bytes
    tde_bytes: otel.api.metrics.Counter,
    // geode.crypto.tde.error.count
    tde_error_count: otel.api.metrics.Counter,
};

var g_security: ?SecurityMetrics = null;
var g_audit_queue_depth_provider: ?*const fn () i64 = null;

fn ensureSecurity() !*SecurityMetrics {
    if (g_security) |*s| return s;
    const m = meter();
    g_security = SecurityMetrics{
        .auth_attempt_count = try m.counter(.{
            .name = "geode.security.authentication.attempt.count",
            .unit = "{attempt}",
            .kind = .counter,
            .description = "Authentication attempts by method and outcome",
        }),
        .auth_duration = try m.histogram(.{
            .name = "geode.security.authentication.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "Authentication latency in seconds by method and outcome",
            .explicit_buckets = .{ .boundaries = buckets_storage_io_duration },
        }),
        .session_count = try m.upDownCounter(.{
            .name = "geode.security.session.count",
            .unit = "{session}",
            .kind = .up_down_counter,
            .description = "Current active/idle/terminated session delta",
        }),
        .authz_check_count = try m.counter(.{
            .name = "geode.security.authorization.check.count",
            .unit = "{check}",
            .kind = .counter,
            .description = "Authorization policy evaluations by decision and policy type",
        }),
        .authz_check_duration = try m.histogram(.{
            .name = "geode.security.authorization.check.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "Authorization check latency in seconds",
            .explicit_buckets = .{ .boundaries = buckets_storage_io_duration },
        }),
        .rls_eval_count = try m.counter(.{
            .name = "geode.security.rls.evaluation.count",
            .unit = "{evaluation}",
            .kind = .counter,
            .description = "Row-level security policy evaluations by decision and type",
        }),
        .rls_eval_duration = try m.histogram(.{
            .name = "geode.security.rls.evaluation.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "RLS policy evaluation latency in seconds",
            .explicit_buckets = .{ .boundaries = buckets_storage_io_duration },
        }),
        .audit_event_count = try m.counter(.{
            .name = "geode.audit.event.count",
            .unit = "{event}",
            .kind = .counter,
            .description = "Audit events emitted by event type and outcome",
        }),
        .audit_event_dropped = try m.counter(.{
            .name = "geode.audit.event.dropped",
            .unit = "{event}",
            .kind = .counter,
            .description = "Audit events dropped (queue overflow, I/O error, etc.)",
        }),
        .tde_op_duration = try m.histogram(.{
            .name = "geode.crypto.tde.operation.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "TDE/KMS cryptographic operation latency in seconds",
            .explicit_buckets = .{ .boundaries = buckets_storage_io_duration },
        }),
        .tde_bytes = try m.counter(.{
            .name = "geode.crypto.tde.bytes",
            .unit = "By",
            .kind = .counter,
            .description = "Bytes processed by the TDE engine (encrypt/decrypt/rotate/derive)",
        }),
        .tde_error_count = try m.counter(.{
            .name = "geode.crypto.tde.error.count",
            .unit = "{error}",
            .kind = .counter,
            .description = "TDE/KMS errors by error type",
        }),
    };
    return &g_security.?;
}

fn observeAuditQueueDepth(_: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    if (g_audit_queue_depth_provider) |fnp| {
        observer.observeInt(fnp(), &.{});
    }
}

// ---- Security public API ----

/// Record an authentication attempt.
/// `method` — enum; NEVER pass a username or credential material.
/// `error_type` — an optional low-cardinality classifier (e.g. "InvalidCredentials").
pub fn recordAuthAttempt(method: AuthMethod, outcome: Outcome, error_type: ?[]const u8) void {
    const s = ensureSecurity() catch return;
    var buf: [3]attrs.Entry = undefined;
    var n: usize = 0;
    buf[n] = .{ .key = "geode.auth.method", .value = .{ .string = @tagName(method) } };
    n += 1;
    buf[n] = .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } };
    n += 1;
    if (error_type) |e| {
        buf[n] = .{ .key = "error.type", .value = .{ .string = e } };
        n += 1;
    }
    s.auth_attempt_count.add(1, buf[0..n]);
}

/// Record authentication duration (histogram companion to recordAuthAttempt).
/// Kept separate so callers that only want the attempt count need not measure
/// the wall-clock duration.
///
/// GAP-0874: records `duration_s` into the real
/// `geode.security.authentication.duration` histogram (previously a stub
/// that discarded the duration and double-bumped the attempt counter).
/// Callers measuring an auth attempt should call BOTH recordAuthAttempt
/// (count) and recordAuthDuration (latency) — this function no longer
/// bumps the attempt counter.
pub fn recordAuthDuration(method: AuthMethod, duration_s: f64, outcome: Outcome) void {
    const s = ensureSecurity() catch return;
    s.auth_duration.record(duration_s, &.{
        .{ .key = "geode.auth.method", .value = .{ .string = @tagName(method) } },
        .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } },
    });
}

/// Increment the session count for a given state. Call once when a session
/// transitions INTO the state. Counterpart: decSession.
pub fn incSession(state: SessionState) void {
    const s = ensureSecurity() catch return;
    s.session_count.add(1, &.{.{ .key = "geode.session.state", .value = .{ .string = @tagName(state) } }});
}

/// Decrement the session count for a given state. Call once when a session
/// transitions OUT OF the state.
pub fn decSession(state: SessionState) void {
    const s = ensureSecurity() catch return;
    s.session_count.add(-1, &.{.{ .key = "geode.session.state", .value = .{ .string = @tagName(state) } }});
}

/// Record an authorization check result. Bumps both the count and duration
/// so the two instruments are always correlated.
pub fn recordAuthzCheck(decision: SecurityDecision, policy_type: PolicyType, duration_s: f64) void {
    const s = ensureSecurity() catch return;
    const decision_attr = attrs.Entry{ .key = "geode.security.decision", .value = .{ .string = @tagName(decision) } };
    const policy_attr = attrs.Entry{ .key = "geode.security.policy_type", .value = .{ .string = @tagName(policy_type) } };
    s.authz_check_count.add(1, &.{ decision_attr, policy_attr });
    s.authz_check_duration.record(duration_s, &.{ decision_attr, policy_attr });
}

/// Record an RLS policy evaluation result. Bumps both count and duration.
pub fn recordRlsEvaluation(decision: SecurityDecision, policy_type: PolicyType, duration_s: f64) void {
    const s = ensureSecurity() catch return;
    const decision_attr = attrs.Entry{ .key = "geode.security.decision", .value = .{ .string = @tagName(decision) } };
    const policy_attr = attrs.Entry{ .key = "geode.security.policy_type", .value = .{ .string = @tagName(policy_type) } };
    s.rls_eval_count.add(1, &.{ decision_attr, policy_attr });
    s.rls_eval_duration.record(duration_s, &.{ decision_attr, policy_attr });
}

/// Record an audit event emission.
/// `event_type` MUST be a low-cardinality classifier (e.g. "login", "query",
/// "schema_change"). NEVER pass a username, session ID, or query text here.
pub fn recordAuditEvent(event_type: []const u8, outcome: Outcome) void {
    const s = ensureSecurity() catch return;
    s.audit_event_count.add(1, &.{
        .{ .key = "geode.audit.event_type", .value = .{ .string = event_type } },
        .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } },
    });
}

/// Register an observable gauge reporting the current audit queue backlog.
/// `provider_fn` MUST be a module-lifetime function pointer returning the
/// current pending-event count; called on each Prometheus scrape.
pub fn registerAuditQueueGauge(provider_fn: *const fn () i64) !void {
    g_audit_queue_depth_provider = provider_fn;
    const m = meter();
    _ = try m.createObservableGauge(
        .{
            .name = "geode.audit.queue.depth",
            .unit = "{event}",
            .kind = .observable_gauge,
            .description = "Current number of audit events pending in the write queue",
        },
        observeAuditQueueDepth,
        null,
    );
}

/// Bounded set of audit-drop reasons. SONNY-1806: closed enum keeps
/// `geode.audit.drop_reason` low-cardinality. Tag names are the label values.
pub const AuditDropReason = enum { queue_full, append_error, write_error, io_error };

/// Record an audit event that was dropped before being written.
pub fn recordAuditDropped(reason: AuditDropReason) void {
    const s = ensureSecurity() catch return;
    s.audit_event_dropped.add(1, &.{.{ .key = "geode.audit.drop_reason", .value = .{ .string = @tagName(reason) } }});
}

/// Record a TDE/KMS cryptographic operation. Bumps both count (via duration
/// histogram) and latency. `outcome` allows callers to track success vs
/// error on the same instrument.
/// Privacy: `op` is an enum — no key IDs or policy names ever reach here.
pub fn recordTdeOperation(op: CryptoOp, duration_s: f64, outcome: Outcome) void {
    const s = ensureSecurity() catch return;
    s.tde_op_duration.record(duration_s, &.{
        .{ .key = "geode.crypto.op", .value = .{ .string = @tagName(op) } },
        .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } },
    });
}

/// Record bytes processed by the TDE engine.
/// Privacy: `op` is an enum — no key IDs flow here.
pub fn recordTdeBytes(op: CryptoOp, n_bytes: u64) void {
    const s = ensureSecurity() catch return;
    s.tde_bytes.add(n_bytes, &.{.{ .key = "geode.crypto.op", .value = .{ .string = @tagName(op) } }});
}

/// Record a TDE/KMS error.
/// `error_type` MUST be a low-cardinality classifier (e.g. "KeyMissing",
/// "DecryptionFailed"). NEVER pass a key ID or policy name here.
pub fn recordTdeError(error_type: []const u8) void {
    const s = ensureSecurity() catch return;
    s.tde_error_count.add(1, &.{.{ .key = "error.type", .value = .{ .string = error_type } }});
}

// -------------------------------------------------------------------------
// Distributed + cluster metrics — geode.cluster.* / geode.shard.* /
// geode.distributed.* per spec §4.9 P0.
//
// Cluster metrics are registered unconditionally so the facade API is
// always available. The caller is responsible for guarding emission behind
// an `GEODE_CLUSTER_TOKEN` check at the call site — when running in
// single-node mode the record* functions simply never get called.
//
// Privacy / cardinality rule: `node_id_low_card` MUST be a stable, bounded
// identifier such as "node-1", "node-2" (ordinal or role-based). It MUST
// NOT be a UUID, IP address, or any other unbounded value.
// -------------------------------------------------------------------------

// CANARY: REQ=REQ-OTEL-METRICS-011; FEATURE="OTel Instrumentation"; ASPECT=DistributedCluster; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28

/// Distributed query consistency model.
pub const ConsistencyLevel = enum { eventual, strong, linearizable };

const DistributedMetrics = struct {
    // geode.shard.query.count — per-shard query counter
    shard_query_count: otel.api.metrics.Counter,
    // geode.distributed.query.count — cluster-wide distributed query counter
    dist_query_count: otel.api.metrics.Counter,
    // geode.distributed.query.duration — distributed query end-to-end latency
    dist_query_duration: otel.api.metrics.Histogram,
    // geode.distributed.query.fanout — number of shards contacted per query
    dist_query_fanout: otel.api.metrics.Histogram,
    // geode.distributed.query.partial_failure.count
    partial_failure_count: otel.api.metrics.Counter,
    // geode.cluster.node.health — per-node health level (1 = healthy, 0 = unhealthy).
    // A gauge (last-value) so health can fall back to 0 and recover to 1; a
    // counter could only ever increase and never reflect return-to-healthy.
    node_health: otel.api.metrics.Gauge,
};

var g_distributed: ?DistributedMetrics = null;

// Observable gauge function pointers for the two cluster-level gauges.
var g_cluster_node_count_provider: ?*const fn () i64 = null;
var g_shard_count_provider: ?*const fn () i64 = null;

fn ensureDistributed() !*DistributedMetrics {
    if (g_distributed) |*d| return d;
    const m = meter();
    g_distributed = DistributedMetrics{
        .shard_query_count = try m.counter(.{
            .name = "geode.shard.query.count",
            .unit = "{query}",
            .kind = .counter,
            .description = "Total queries routed to each shard by outcome",
        }),
        .dist_query_count = try m.counter(.{
            .name = "geode.distributed.query.count",
            .unit = "{query}",
            .kind = .counter,
            .description = "Total distributed (multi-shard) queries by consistency level and outcome",
        }),
        .dist_query_duration = try m.histogram(.{
            .name = "geode.distributed.query.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "End-to-end distributed query duration in seconds",
            .explicit_buckets = .{ .boundaries = buckets_query_duration },
        }),
        .dist_query_fanout = try m.histogram(.{
            .name = "geode.distributed.query.fanout",
            .unit = "{shard}",
            .kind = .histogram,
            .description = "Number of shards contacted per distributed query",
            .explicit_buckets = .{ .boundaries = buckets_rows },
        }),
        .partial_failure_count = try m.counter(.{
            .name = "geode.distributed.query.partial_failure.count",
            .unit = "{failure}",
            .kind = .counter,
            .description = "Distributed queries that completed with one or more shard failures",
        }),
        .node_health = try m.gauge(.{
            .name = "geode.cluster.node.health",
            .unit = "1",
            .kind = .gauge,
            .description = "Cluster node health level (1=healthy, 0=unhealthy); last-value gauge",
        }),
    };
    return &g_distributed.?;
}

fn observeClusterNodeCount(_: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    if (g_cluster_node_count_provider) |fnp| {
        observer.observeInt(fnp(), &.{.{ .key = "geode.cluster.role", .value = .{ .string = "any" } }});
    }
}

fn observeShardCount(_: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    if (g_shard_count_provider) |fnp| {
        observer.observeInt(fnp(), &.{.{ .key = "geode.cluster.role", .value = .{ .string = "any" } }});
    }
}

/// Register an observable gauge that reports the current cluster node count.
/// `provider_fn` MUST be a module-lifetime function pointer; called on each
/// Prometheus scrape. Idempotent — duplicate registrations are ignored by
/// the OTel SDK. Only call when `GEODE_CLUSTER_TOKEN` is set.
pub fn registerClusterNodeCountGauge(provider_fn: *const fn () i64) !void {
    g_cluster_node_count_provider = provider_fn;
    const m = meter();
    _ = try m.createObservableGauge(
        .{
            .name = "geode.cluster.node.count",
            .unit = "{node}",
            .kind = .observable_gauge,
            .description = "Current number of nodes in the cluster",
        },
        observeClusterNodeCount,
        null,
    );
}

/// Register an observable gauge that reports the current shard count.
/// `provider_fn` MUST be a module-lifetime function pointer; called on each
/// Prometheus scrape. Only call when `GEODE_CLUSTER_TOKEN` is set.
pub fn registerShardCountGauge(provider_fn: *const fn () i64) !void {
    g_shard_count_provider = provider_fn;
    const m = meter();
    _ = try m.createObservableGauge(
        .{
            .name = "geode.shard.count",
            .unit = "{shard}",
            .kind = .observable_gauge,
            .description = "Current number of active shards in the cluster",
        },
        observeShardCount,
        null,
    );
}

/// Record a cluster node health state change.
/// `node_id_low_card` MUST be a stable, bounded identifier (e.g. "node-1").
/// It MUST NOT be a UUID, IP address, or other unbounded value.
/// Call whenever a health check transitions a node between states.
pub fn recordClusterNodeHealth(node_id_low_card: []const u8, healthy: bool) void {
    const d = ensureDistributed() catch return;
    const v: f64 = if (healthy) 1 else 0;
    d.node_health.set(v, &.{.{ .key = "geode.cluster.node_id", .value = .{ .string = node_id_low_card } }});
}

/// Record a query routed to a specific shard.
/// `shard_id` is bounded (≤32 per Geode spec) so it is safe as an attribute.
pub fn recordShardQuery(shard_id: u32, outcome: Outcome) void {
    const d = ensureDistributed() catch return;
    var shard_buf: [12]u8 = undefined;
    const shard_str = std.fmt.bufPrint(&shard_buf, "shard-{d}", .{shard_id}) catch "shard-?";
    d.shard_query_count.add(1, &.{
        .{ .key = "geode.shard.id", .value = .{ .string = shard_str } },
        .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } },
    });
}

/// Record a completed distributed (multi-shard) query. Bumps both the counter
/// and the latency histogram so they remain correlated per spec §4.9.
pub fn recordDistributedQuery(level: ConsistencyLevel, duration_s: f64, outcome: Outcome) void {
    const d = ensureDistributed() catch return;
    const level_attr = attrs.Entry{ .key = "geode.consistency.level", .value = .{ .string = @tagName(level) } };
    const outcome_attr = attrs.Entry{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } };
    d.dist_query_count.add(1, &.{ level_attr, outcome_attr });
    d.dist_query_duration.record(duration_s, &.{ level_attr, outcome_attr });
}

/// Record the shard fan-out for a distributed query.
/// `shards` is the number of shards contacted; `level` is the consistency
/// model that determined the fan-out set.
pub fn recordDistributedFanout(level: ConsistencyLevel, shards: u64) void {
    const d = ensureDistributed() catch return;
    d.dist_query_fanout.record(@floatFromInt(shards), &.{
        .{ .key = "geode.consistency.level", .value = .{ .string = @tagName(level) } },
    });
}

/// Record a partial failure on a distributed query (one or more shards failed
/// but the query still returned a result).
/// `error_type` MUST be a low-cardinality classifier (e.g. "ShardUnavailable",
/// "ShardTimeout"). NEVER pass a node ID or query text here.
pub fn recordPartialFailure(error_type: []const u8) void {
    const d = ensureDistributed() catch return;
    d.partial_failure_count.add(1, &.{.{ .key = "error.type", .value = .{ .string = error_type } }});
}

// -------------------------------------------------------------------------
// CDC + real-time analytics metrics — geode.cdc.* / geode.analytics.* per
// spec §4.10 P0.
//
// CDC metrics track change-data-capture event throughput, pipeline lag,
// queue health, and sink delivery errors.  Analytics metrics track
// real-time aggregation event throughput, queue depth, and processing
// latency.
//
// Privacy / cardinality: event_type and sink_type are enums (bounded).
// drop reason and error_type MUST be low-cardinality literals.
// -------------------------------------------------------------------------

// CANARY: REQ=REQ-OTEL-METRICS-012; FEATURE="OTel Instrumentation"; ASPECT=CdcAnalytics; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28

/// Kind of CDC event that was emitted.
pub const CdcEventType = enum { node_change, edge_change, schema_change, txn_marker };

/// Downstream sink type that a CDC event is delivered to.
pub const SinkType = enum { kafka, http_webhook, file, s3 };

const CdcMetrics = struct {
    // geode.cdc.event.count — events emitted by type and outcome
    event_count: otel.api.metrics.Counter,
    // geode.cdc.sink.error.count — delivery errors per sink
    sink_error_count: otel.api.metrics.Counter,
    // geode.cdc.event.dropped — events dropped before delivery
    event_dropped: otel.api.metrics.Counter,
};

var g_cdc: ?CdcMetrics = null;

// Observable gauge function pointers for CDC lag and queue depth.
var g_cdc_lag_provider: ?*const fn () f64 = null;
var g_cdc_queue_depth_provider: ?*const fn () i64 = null;

fn ensureCdc() !*CdcMetrics {
    if (g_cdc) |*c| return c;
    const m = meter();
    g_cdc = CdcMetrics{
        .event_count = try m.counter(.{
            .name = "geode.cdc.event.count",
            .unit = "{event}",
            .kind = .counter,
            .description = "Total CDC events emitted by event type and outcome",
        }),
        .sink_error_count = try m.counter(.{
            .name = "geode.cdc.sink.error.count",
            .unit = "{error}",
            .kind = .counter,
            .description = "CDC delivery errors per sink type and error classifier",
        }),
        .event_dropped = try m.counter(.{
            .name = "geode.cdc.event.dropped",
            .unit = "{event}",
            .kind = .counter,
            .description = "CDC events dropped before delivery (queue overflow, serialization error, etc.)",
        }),
    };
    return &g_cdc.?;
}

fn observeCdcLag(_: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    if (g_cdc_lag_provider) |fnp| {
        observer.observeDouble(fnp(), &.{});
    }
}

fn observeCdcQueueDepth(_: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    if (g_cdc_queue_depth_provider) |fnp| {
        observer.observeInt(fnp(), &.{});
    }
}

// ---- CDC public API ----

/// Record a CDC event emission.
/// `event_type` is a bounded enum — no document content flows here.
/// `outcome` is `.success` for events acknowledged by the sink, `.error_`
/// when the sink rejected or the delivery timed out.
pub fn recordCdcEvent(event_type: CdcEventType, outcome: Outcome) void {
    const c = ensureCdc() catch return;
    c.event_count.add(1, &.{
        .{ .key = "geode.cdc.event_type", .value = .{ .string = @tagName(event_type) } },
        .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } },
    });
}

/// Register an observable gauge reporting the current CDC pipeline lag in
/// seconds (wall-clock delay between event creation and sink acknowledgement).
/// `provider_fn` MUST be a module-lifetime pointer; called on each scrape.
pub fn registerCdcLagGauge(provider_fn: *const fn () f64) !void {
    g_cdc_lag_provider = provider_fn;
    const m = meter();
    _ = try m.createObservableGauge(
        .{
            .name = "geode.cdc.lag",
            .unit = "s",
            .kind = .observable_gauge,
            .description = "Current CDC pipeline lag in seconds (event creation to sink acknowledgement)",
        },
        observeCdcLag,
        null,
    );
}

/// Register an observable gauge reporting the current CDC in-flight queue
/// depth (events buffered pending delivery to sink).
/// `provider_fn` MUST be a module-lifetime pointer; called on each scrape.
pub fn registerCdcQueueDepthGauge(provider_fn: *const fn () i64) !void {
    g_cdc_queue_depth_provider = provider_fn;
    const m = meter();
    _ = try m.createObservableGauge(
        .{
            .name = "geode.cdc.queue.depth",
            .unit = "{event}",
            .kind = .observable_gauge,
            .description = "Current number of CDC events buffered in the delivery queue",
        },
        observeCdcQueueDepth,
        null,
    );
}

/// Record a CDC sink delivery error.
/// `sink` is an enum (bounded).  `error_type` MUST be a low-cardinality
/// classifier (e.g. "ConnectionRefused", "SerializationFailed").  NEVER
/// pass a topic name, URL, or document content here.
pub fn recordCdcSinkError(sink: SinkType, error_type: []const u8) void {
    const c = ensureCdc() catch return;
    c.sink_error_count.add(1, &.{
        .{ .key = "geode.sink.type", .value = .{ .string = @tagName(sink) } },
        .{ .key = "error.type", .value = .{ .string = error_type } },
    });
}

/// Bounded set of CDC event-drop reasons. SONNY-1806: closed enum keeps
/// `geode.drop.reason` low-cardinality. Tag names are the label values.
pub const CdcDropReason = enum { queue_full, serialization_error, io_error };

/// Record a CDC event that was dropped before delivery.
pub fn recordCdcEventDropped(reason: CdcDropReason) void {
    const c = ensureCdc() catch return;
    c.event_dropped.add(1, &.{.{ .key = "geode.drop.reason", .value = .{ .string = @tagName(reason) } }});
}

// ---- Real-time analytics metrics ----

const AnalyticsMetrics = struct {
    // geode.analytics.event.count — analytics events processed by type
    event_count: otel.api.metrics.Counter,
    // geode.analytics.event.processing.duration — event processing latency
    processing_duration: otel.api.metrics.Histogram,
};

var g_analytics: ?AnalyticsMetrics = null;

// Observable gauge function pointer for analytics queue depth.
var g_analytics_queue_depth_provider: ?*const fn () i64 = null;

fn ensureAnalytics() !*AnalyticsMetrics {
    if (g_analytics) |*a| return a;
    const m = meter();
    g_analytics = AnalyticsMetrics{
        .event_count = try m.counter(.{
            .name = "geode.analytics.event.count",
            .unit = "{event}",
            .kind = .counter,
            .description = "Total real-time analytics events processed by event type and outcome",
        }),
        .processing_duration = try m.histogram(.{
            .name = "geode.analytics.event.processing.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "Real-time analytics event processing latency in seconds",
            .explicit_buckets = .{ .boundaries = buckets_query_duration },
        }),
    };
    return &g_analytics.?;
}

fn observeAnalyticsQueueDepth(_: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    if (g_analytics_queue_depth_provider) |fnp| {
        observer.observeInt(fnp(), &.{});
    }
}

// ---- Analytics public API ----

/// Record a real-time analytics event processed by the streaming engine.
/// `event_type` MUST be a low-cardinality classifier (e.g. "aggregate",
/// "pattern_match", "anomaly").  NEVER pass query text or document content.
pub fn recordAnalyticsEvent(event_type: []const u8, outcome: Outcome) void {
    const a = ensureAnalytics() catch return;
    a.event_count.add(1, &.{
        .{ .key = "geode.analytics.event_type", .value = .{ .string = event_type } },
        .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } },
    });
}

/// Register an observable gauge reporting the current analytics event queue
/// depth (events buffered pending processing).
/// `provider_fn` MUST be a module-lifetime pointer; called on each scrape.
pub fn registerAnalyticsQueueGauge(provider_fn: *const fn () i64) !void {
    g_analytics_queue_depth_provider = provider_fn;
    const m = meter();
    _ = try m.createObservableGauge(
        .{
            .name = "geode.analytics.event.queue.depth",
            .unit = "{event}",
            .kind = .observable_gauge,
            .description = "Current number of analytics events buffered pending processing",
        },
        observeAnalyticsQueueDepth,
        null,
    );
}

/// Record the processing duration for a real-time analytics event.
/// `event_type` MUST be a low-cardinality classifier (same domain as
/// `recordAnalyticsEvent`).  `duration_s` is wall-clock seconds from
/// event ingestion to completion.
pub fn recordAnalyticsProcessing(event_type: []const u8, duration_s: f64) void {
    const a = ensureAnalytics() catch return;
    a.processing_duration.record(duration_s, &.{
        .{ .key = "geode.analytics.event_type", .value = .{ .string = event_type } },
    });
}

// -------------------------------------------------------------------------
// Backup + restore metrics — geode.backup.* / geode.restore.* per §4.12 P0.
// CANARY: REQ=REQ-OTEL-METRICS-013; FEATURE="OTel Instrumentation"; ASPECT=Backup; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28
// -------------------------------------------------------------------------

/// Backup kind: full snapshot, incremental (delta since last backup), or
/// differential (delta since last full backup).
pub const BackupKind = enum { full, incremental, differential };

/// Object-store provider backing the backup destination.
pub const ObjectStoreProvider = enum { s3, do_spaces, gcs, azure_blob, file };

const BackupMetrics = struct {
    // geode.backup.count — total completed backup operations
    backup_count: otel.api.metrics.Counter,
    // geode.backup.duration — wall-clock backup duration in seconds
    backup_duration: otel.api.metrics.Histogram,
    // geode.backup.bytes — bytes written to the backup store
    backup_bytes: otel.api.metrics.Counter,
    // geode.restore.count — total completed restore operations
    restore_count: otel.api.metrics.Counter,
    // geode.restore.duration — wall-clock restore duration in seconds
    restore_duration: otel.api.metrics.Histogram,
    // geode.restore.bytes — bytes read from the backup store during restore
    restore_bytes: otel.api.metrics.Counter,
};

var g_backup: ?BackupMetrics = null;

fn ensureBackup() !*BackupMetrics {
    if (g_backup) |*b| return b;
    const m = meter();
    g_backup = BackupMetrics{
        .backup_count = try m.counter(.{
            .name = "geode.backup.count",
            .unit = "{backup}",
            .kind = .counter,
            .description = "Total backup operations completed, partitioned by kind and outcome",
        }),
        .backup_duration = try m.histogram(.{
            .name = "geode.backup.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "Wall-clock duration of backup operations in seconds",
            .explicit_buckets = .{ .boundaries = buckets_query_duration },
        }),
        .backup_bytes = try m.counter(.{
            .name = "geode.backup.bytes",
            .unit = "By",
            .kind = .counter,
            .description = "Total bytes written to the backup store, partitioned by backup kind",
        }),
        .restore_count = try m.counter(.{
            .name = "geode.restore.count",
            .unit = "{restore}",
            .kind = .counter,
            .description = "Total restore operations completed, partitioned by outcome",
        }),
        .restore_duration = try m.histogram(.{
            .name = "geode.restore.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "Wall-clock duration of restore operations in seconds",
            .explicit_buckets = .{ .boundaries = buckets_query_duration },
        }),
        .restore_bytes = try m.counter(.{
            .name = "geode.restore.bytes",
            .unit = "By",
            .kind = .counter,
            .description = "Total bytes read from the backup store during a restore",
        }),
    };
    return &g_backup.?;
}

// ---- Backup + restore public API ----

/// Record a completed backup operation.
/// Also bumps `geode.backup.count`.  `kind` is the backup strategy;
/// `duration_s` is total wall-clock time; `outcome` is the result;
/// `error_type` MUST be null on success and a low-cardinality classifier
/// (e.g. "StorageError", "NetworkTimeout") on failure — NEVER pass
/// a file path, bucket name, or user-supplied string here.
pub fn recordBackup(kind: BackupKind, duration_s: f64, outcome: Outcome, error_type: ?[]const u8) void {
    const b = ensureBackup() catch return;
    var buf: [3]attrs.Entry = undefined;
    var n: usize = 0;
    buf[n] = .{ .key = "geode.backup.kind", .value = .{ .string = @tagName(kind) } };
    n += 1;
    buf[n] = .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } };
    n += 1;
    if (error_type) |e| {
        buf[n] = .{ .key = "error.type", .value = .{ .string = e } };
        n += 1;
    }
    b.backup_count.add(1, buf[0..n]);
    b.backup_duration.record(duration_s, buf[0..n]);
}

/// Record bytes written to the backup store for a single backup operation.
/// `kind` is the backup strategy; `n_bytes` is the raw payload size in bytes.
pub fn recordBackupBytes(kind: BackupKind, n_bytes: u64) void {
    const b = ensureBackup() catch return;
    b.backup_bytes.add(n_bytes, &.{
        .{ .key = "geode.backup.kind", .value = .{ .string = @tagName(kind) } },
    });
}

/// Record a completed restore operation.
/// Also bumps `geode.restore.count`.  `duration_s` is total wall-clock time;
/// `outcome` is the result; `error_type` follows the same rules as
/// `recordBackup` — low-cardinality only, never user data.
pub fn recordRestore(duration_s: f64, outcome: Outcome, error_type: ?[]const u8) void {
    const b = ensureBackup() catch return;
    var buf: [2]attrs.Entry = undefined;
    var n: usize = 0;
    buf[n] = .{ .key = "geode.result.outcome", .value = .{ .string = outcomeName(outcome) } };
    n += 1;
    if (error_type) |e| {
        buf[n] = .{ .key = "error.type", .value = .{ .string = e } };
        n += 1;
    }
    b.restore_count.add(1, buf[0..n]);
    b.restore_duration.record(duration_s, buf[0..n]);
}

/// Record bytes read from the backup store during a single restore operation.
/// `n_bytes` is the raw payload size in bytes.
pub fn recordRestoreBytes(n_bytes: u64) void {
    const b = ensureBackup() catch return;
    b.restore_bytes.add(n_bytes, &.{});
}

// -------------------------------------------------------------------------
// Process / runtime metrics — REQ-OTEL-METRICS-014 (Sub-A).
//
// NOTE: otel.instrumentation.runtime uses std.fs.openFileAbsolute which was
// removed in Zig 0.16. Until the upstream otel library is patched, Sub-A is
// implemented as a native snapshot that reads /proc/self/statm directly via
// std.fs.cwd().openFile and wires it into two observable gauges. The OTel
// library's runtime.zig is intentionally NOT imported to avoid the compile
// error. Process metrics are still collected via the native path below.
// -------------------------------------------------------------------------
// CANARY: REQ=REQ-OTEL-METRICS-014; FEATURE="OTel Instrumentation"; ASPECT=ProcessMetrics; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28

/// Snapshot of process-level metrics read from /proc/self/statm and /proc/self/status.
/// Uses std.posix syscalls directly to avoid std.fs API churn across Zig versions.
const ProcessSnapshot = struct {
    rss_bytes: ?u64 = null,
    threads: ?u32 = null,

    fn readProcFile(path: []const u8, buf: []u8) []u8 {
        if (comptime @import("builtin").os.tag != .linux) return buf[0..0];
        // Use std.posix.openat (AT.FDCWD = -100 on Linux) and raw read.
        // std.posix.close was removed in Zig 0.16; use std.os.linux.close.
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return buf[0..0];
        defer _ = std.os.linux.close(fd);
        const n = std.posix.read(fd, buf) catch return buf[0..0];
        return buf[0..n];
    }

    fn capture() ProcessSnapshot {
        var s: ProcessSnapshot = .{};
        if (comptime @import("builtin").os.tag != .linux) return s;
        // Read resident-set size from /proc/self/statm.
        var buf: [256]u8 = undefined;
        const statm = readProcFile("/proc/self/statm", &buf);
        if (statm.len > 0) {
            var iter = std.mem.tokenizeScalar(u8, statm, ' ');
            _ = iter.next(); // total pages
            const resident_str = iter.next() orelse return s;
            const pages = std.fmt.parseInt(u64, std.mem.trim(u8, resident_str, " \n"), 10) catch return s;
            s.rss_bytes = pages * std.heap.pageSize();
        }
        // Thread count from /proc/self/status.
        var sbuf: [4096]u8 = undefined;
        const status = readProcFile("/proc/self/status", &sbuf);
        if (std.mem.indexOf(u8, status, "Threads:")) |idx| {
            const rest = status[idx + "Threads:".len ..];
            const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            s.threads = std.fmt.parseInt(u32, std.mem.trim(u8, rest[0..end], " \t"), 10) catch null;
        }
        return s;
    }
};

var g_runtime_rss_gauge: ?otel.api.metrics.Gauge = null;
var g_runtime_threads_gauge: ?otel.api.metrics.Gauge = null;
var g_runtime_registered: bool = false;

/// Install process/runtime instruments (process.runtime.zig.memory.resident_set
/// and process.runtime.zig.threads) via observable gauges backed by /proc/self.
/// Must be called once after `init()`. Idempotent — second call is a no-op.
pub fn registerRuntimeMetrics() !void {
    if (g_runtime_registered) return;
    const m = meter();
    g_runtime_rss_gauge = try m.gauge(.{
        .name = "process.runtime.zig.memory.resident_set",
        .unit = "By",
        .kind = .gauge,
        .description = "Resident set size of the process in bytes",
    });
    g_runtime_threads_gauge = try m.gauge(.{
        .name = "process.runtime.zig.threads",
        .unit = "{thread}",
        .kind = .gauge,
        .description = "Number of OS threads in the process",
    });
    g_runtime_registered = true;
}

/// Refresh the runtime gauges from a fresh /proc/self snapshot.
/// Call from a periodic timer (e.g. every 15 s).
pub fn refreshRuntimeMetrics() void {
    if (!g_runtime_registered) return;
    const s = ProcessSnapshot.capture();
    if (g_runtime_rss_gauge) |g| if (s.rss_bytes) |v| g.set(@floatFromInt(v), &.{});
    if (g_runtime_threads_gauge) |g| if (s.threads) |v| g.set(@floatFromInt(v), &.{});
}

// -------------------------------------------------------------------------
// db.client.* metrics — REQ-OTEL-METRICS-014 (Sub-B).
//
// Instruments the internal remote-query path used in distributed mode.
// Follows the OTel semantic conventions for database clients:
//   db.client.operation.duration  — histogram (seconds)
//   db.client.connection.count    — up-down counter ({connection})
// -------------------------------------------------------------------------

pub const DbClientOp = []const u8;

const DbClientMetrics = struct {
    operation_duration: otel.api.metrics.Histogram,
    connection_count: otel.api.metrics.UpDownCounter,
};

var g_db_client: ?DbClientMetrics = null;

fn ensureDbClient() !*DbClientMetrics {
    if (g_db_client != null) return &g_db_client.?;
    const m = meter();
    g_db_client = .{
        .operation_duration = try m.histogram(.{
            .name = "db.client.operation.duration",
            .unit = "s",
            .kind = .histogram,
            .description = "Duration of outbound database operations sent to peer nodes",
            .explicit_buckets = .{ .boundaries = buckets_db_client_duration },
        }),
        .connection_count = try m.upDownCounter(.{
            .name = "db.client.connection.count",
            .unit = "{connection}",
            .kind = .up_down_counter,
            .description = "Number of connections in the client connection pool",
        }),
    };
    return &g_db_client.?;
}

/// Record a completed outbound database operation to a remote peer.
/// `op` is a low-cardinality operation name (e.g. "MATCH", "CREATE").
/// `server_addr` is a low-cardinality `"<host>:<port>"` string — use only
/// static cluster peer addresses, never user-supplied data.
/// `duration_s` is wall-clock time in seconds.
/// `outcome` and `error_type` follow the same conventions as all other
/// `record*` helpers in this module.
pub fn recordDbClientOperation(op: DbClientOp, server_addr: []const u8, duration_s: f64, outcome: Outcome, error_type: ?[]const u8) void {
    const db = ensureDbClient() catch return;
    var buf: [4]attrs.Entry = undefined;
    var n: usize = 0;
    buf[n] = .{ .key = "db.system.name", .value = .{ .string = "codepros.geode" } };
    n += 1;
    buf[n] = .{ .key = "db.operation.name", .value = .{ .string = op } };
    n += 1;
    buf[n] = .{ .key = "server.address", .value = .{ .string = server_addr } };
    n += 1;
    if (error_type) |e| {
        buf[n] = .{ .key = "error.type", .value = .{ .string = e } };
        n += 1;
    }
    db.operation_duration.record(duration_s, buf[0..n]);
    // outcome is not recorded on the histogram itself — callers that need
    // per-outcome counters should use recordQueryExecution or the transport
    // helpers instead.  Suppress the unused-variable warning:
    _ = outcome;
}

pub const DbClientConnectionState = enum { idle, used };

/// Increment the db.client.connection.count gauge for the given pool/state.
/// `server_addr` is used as the pool name (low-cardinality peer address).
pub fn incDbClientConnection(server_addr: []const u8, state: DbClientConnectionState) void {
    const db = ensureDbClient() catch return;
    db.connection_count.add(1, &.{
        .{ .key = "db.client.connection.pool.name", .value = .{ .string = server_addr } },
        .{ .key = "db.client.connection.state", .value = .{ .string = @tagName(state) } },
    });
}

/// Decrement the db.client.connection.count gauge for the given pool/state.
pub fn decDbClientConnection(server_addr: []const u8, state: DbClientConnectionState) void {
    const db = ensureDbClient() catch return;
    db.connection_count.add(-1, &.{
        .{ .key = "db.client.connection.pool.name", .value = .{ .string = server_addr } },
        .{ .key = "db.client.connection.state", .value = .{ .string = @tagName(state) } },
    });
}
