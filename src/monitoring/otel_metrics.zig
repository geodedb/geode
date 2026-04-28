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
// Path-relative import: otel_resource.zig lives next to this file in
// src/monitoring/. If the build system places them in separate modules
// and path-relative resolution fails, fall back to addImport("otel_resource",
// otel_resource_mod) in build.zig and switch to @import("otel_resource").
const otel_resource = @import("otel_resource.zig");

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
