# OpenTelemetry Instrumentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `gitlab.com/devnw/zig/otel` as a dependency and instrument Geode's server with the metric set defined in `docs/otel-updates.md` — single OTel `MeterProvider`, Prometheus `/metrics` rendered from that provider, OTLP/HTTP push when configured, P0 coverage across all twelve subsystem catalogues.

**Architecture:** A single OTel `MeterProvider` is owned by `src/monitoring/otel_metrics.zig` and initialised from `src/server/main.zig` during server startup. The facade exposes typed record functions (`recordQueryExecution`, `recordTransaction`, `recordTransportConnectionOpened`, …) so call sites never construct `InstrumentDescriptor` directly. The existing Prometheus `/metrics` HTTP listener is rewired to render snapshots via `otel.exporters.prometheus.Prometheus.render`, eliminating Geode's bespoke `MetricsCollector`. OTLP push is opt-in via `OTEL_METRICS_EXPORTER=otlp` and `OTEL_EXPORTER_OTLP_ENDPOINT`. Resource attributes (`service.name`, `service.version`, `service.instance.id`, `db.system.name=codepros.geode`, optional cluster identity) are attached at provider construction. Cardinality is enforced by the facade — call sites pass low-cardinality enums, never raw user-controlled strings.

**Tech Stack:** Zig 0.16, `gitlab.com/devnw/zig/otel` (commit `20078af231c069d88eaeb79dcf950b94366be624`), no transitive `use_devnw_*` flags (default-off keeps protobuf/grpc/thread_pool pin conflicts out of the build graph). OTLP/HTTP via stdlib `std.http.Client`. Prometheus pull via `otel.exporters.prometheus.Prometheus`.

**Scope:**
- **In scope:** Server-side P0 metrics from §3 (database client, used by Geode's internal remote-query path) and §4.1–4.12 of `docs/otel-updates.md`. OTLP/HTTP push (gRPC deferred). Prometheus `/metrics` parity. Resource attributes, cardinality guards, CI scrape test.
- **Deferred (P1):** non-P0 metrics within each subsystem; tracked per-task with explicit follow-up checklists.
- **Deferred (P2):** GPU metrics, embedding dimension distributions, anomaly score histograms, vector dimension histogram, graph degree distribution. Listed in Task 24.
- **Out of scope:** Tracing migration (`src/monitoring/tracing.zig` is a homegrown `Tracer` — kept untouched here; spec is metrics-only). Logs export. Client-library `db.client.*` instrumentation in `geode-client-zig` / `geode-client-go` (separate repos, separate plans).

**Single-tenant default:** `geode.tenant.id` and `db.query.text` stay opt-in (off by default), per spec §7 and CLAUDE.md's single-tenant production guidance.

---

## File Structure

**Created:**
- `src/monitoring/otel_metrics.zig` — typed facade over `otel.api.metrics.Meter`. Owns one global `MeterProvider`. All instrumentation call sites depend on this file and nothing else from `otel`.
- `src/monitoring/otel_resource.zig` — builds the OTel `Resource` from env + build info (`service.name`, `service.version`, `service.instance.id`, `db.system.name`, optional cluster attrs).
- `src/monitoring/otel_prometheus_responder.zig` — adapter that takes an HTTP request and writes the body produced by `otel.exporters.prometheus.Prometheus.render`. Replaces the body-writing logic currently inlined in `src/monitoring/metrics_server.zig`.
- `tests/test_otel_facade_smoke.zig` — single-process smoke test: init provider with the in-memory exporter, increment one counter per instrument family, assert all expected names appear in the snapshot.
- `tests/test_otel_prometheus_parity.zig` — boots a `MetricsServer`, scrapes `/metrics` over a localhost socket, asserts the exposition contains the translated names from §5.
- `tests/test_otel_cardinality_guard.zig` — fuzz: feeds random user strings through the facade, asserts no attribute key in the snapshot is unbounded.
- `tests/test_otel_resource_attrs.zig` — verifies `service.name`, `service.version`, `service.instance.id`, `db.system.name` resource attributes appear on every metric point.
- `geodetestlab/specs/otel_metrics_parity.yml` — black-box spec: bring up server, scrape `/metrics`, assert the P0 names exist with the expected types.

**Modified:**
- `build.zig.zon` — add `otel` dependency entry.
- `build.zig` — wire the otel module to `root_mod` and to test artifacts.
- `src/server/main.zig` — initialise the OTel `MeterProvider` before the metrics HTTP server boots; tear it down after `shutdownGlobalMetrics`.
- `src/monitoring/metrics_server.zig` — body writer delegates to `otel_prometheus_responder` when the global OTel provider is set; the bespoke `prometheus.MetricsCollector` path stays only as a fallback for tests that haven't migrated.
- `src/monitoring/registry.zig` — soft-deprecate `Registry`/`global()`. The four legacy fields keep working but each emits to its OTel mirror instrument so dashboards using `geode_query_latency_ms` / `geode_active_transactions` / `geode_pathcache_*` see traffic during the migration window.
- Per-subsystem instrumentation sites (one per task in §10–§18) — each call site adds a single `recordX(...)` call from `otel_metrics`.

**Untouched:**
- `src/monitoring/tracing.zig` — kept as-is. Spec is metric-only.
- `src/monitoring/variance_calibration.zig` — orthogonal; not metric infrastructure.
- `src/monitoring/prometheus.zig` — kept as a fallback for tests; new code uses the OTel exporter.

---

## Conventions Used in Every Task

**Test command:** From the worktree root, `zig build test --summary new` runs the project's test suite. For a single test file: `zig test tests/<file>.zig` after an initial `zig build` to populate `.zig-cache`. The Makefile target `make test` is also available.

**Build command:** `zig build` produces `zig-out/bin/geode`. `make build` is the shortcut.

**CANARY markers:** Every new `recordX` function in `otel_metrics.zig` MUST carry a CANARY comment matching the catalogue from `docs/otel-updates.md`:
```
// CANARY: REQ=REQ-OTEL-METRICS-<NNN>; FEATURE="OTel Instrumentation"; ASPECT=<Subsystem>; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28
```
Numbers `NNN` start at `001` for Task 8 and increment monotonically.

**Allocator discipline:** `MeterProvider` lives off the long-lived server allocator (`gpa` in `src/server/main.zig`). Per-record allocations (e.g. attribute formatting) MUST stay zero-alloc on the hot path — the facade pre-builds `attrs.Entry` arrays as comptime literals where possible.

**Lock ordering:** `otel_metrics` introduces no new mutexes; `MeterProvider` already serialises instrument writes under `InstrumentMutex`. Call sites MUST NOT hold a tier-1 graph lock while constructing attribute strings — pre-format outside the lock.

**Frequent commits:** every task ends with a `git commit`. Commit messages follow the project's existing convention: `feat(otel): <subject>` or `chore(otel): <subject>`.

---

### Task 1: Pin the otel dependency in build.zig.zon

**Files:**
- Modify: `build.zig.zon` (insert after the existing `quic` entry, around line 80)

- [ ] **Step 1: Discover the upstream commit and compute the package hash**

The upstream repo is `git@gitlab.com:devnw/zig/otel`; the current head is `20078af231c069d88eaeb79dcf950b94366be624`. Zig's package manager fetches the tarball over HTTPS, so use the `git+https://` form mirroring every other dep in this file.

Run from the worktree root:
```bash
zig fetch --save=otel git+https://gitlab.com/devnw/zig/otel.git#20078af231c069d88eaeb79dcf950b94366be624
```

Expected: `zig fetch` writes both the `.url` and `.hash` lines into `build.zig.zon` and downloads the package to `~/.cache/zig/p/<hash>`.

If `zig fetch` fails because of network access for the agent, populate the entry by hand (commit hash above; hash from a successful local fetch). Either way, the final entry must have a real `.hash` value, not a placeholder.

- [ ] **Step 2: Verify the resulting entry**

Run:
```bash
grep -A2 "\.otel " build.zig.zon
```

Expected output (the hash will differ if the upstream tree changes — what matters is that BOTH `url` and `hash` are populated):
```
        .otel = .{
            .url = "git+https://gitlab.com/devnw/zig/otel.git#20078af231c069d88eaeb79dcf950b94366be624",
            .hash = "otel-0.1.0-<hash>",
        },
```

- [ ] **Step 3: Manually relocate the entry next to the other transport-adjacent libs**

`zig fetch --save` appends the entry to the bottom of `.dependencies`. Move it to live next to the existing `slog` entry (Phase 3) — the otel dep is also an Integration Library — and add a comment explaining the version pin and the disabled `use_devnw_*` build flags.

The entry should look like:
```zig
        // OpenTelemetry client library — metrics, tracing, logs surface.
        // Pinned commit 20078af2 (2026-04-28). Used in PROD for /metrics
        // (rendered via otel.exporters.prometheus) and OTLP/HTTP push.
        // Build flags `use_devnw_grpc`, `use_devnw_protobuf`, `use_devnw_pool`
        // are LEFT DEFAULT-OFF — turning them on pulls otel's pinned versions
        // of grpc_zig / protobuf / thread_pool into the module graph and
        // collides with geode's own pins (Zig 0.16 forbids overlapping
        // module paths). OTLP/HTTP transport works on stdlib std.http.Client
        // alone; gRPC OTLP is gated on resolving the pin conflict.
        .otel = .{
            .url = "git+https://gitlab.com/devnw/zig/otel.git#20078af231c069d88eaeb79dcf950b94366be624",
            .hash = "otel-0.1.0-<hash from fetch>",
        },
```

- [ ] **Step 4: Confirm zig still resolves all deps**

Run:
```bash
zig build --help 2>&1 | head -20
```

Expected: no error from the package manager; the dep graph should resolve without `error: unable to fetch` or `error: hash mismatch`.

- [ ] **Step 5: Commit**

```bash
git add build.zig.zon
git commit -m "chore(deps): add otel @ 20078af2 (gitlab.com/devnw/zig/otel)"
```

---

### Task 2: Wire the otel module into build.zig

**Files:**
- Modify: `build.zig:177-200` (alongside the other Phase 3 module wires) and `build.zig:440-465` (the `root_mod.addImport` block).

- [ ] **Step 1: Add the dependency block next to `slog_dep`**

Find the section that reads `const slog_dep = b.dependency("slog", ...)`. Immediately after the `slog_mod.addImport("json", json_mod);` line, add:

```zig
    // OpenTelemetry — metrics + tracing facade. Default-off transitive
    // flags keep grpc_zig/protobuf/thread_pool pin conflicts out of the
    // module graph; OTLP/HTTP works on stdlib std.http.Client alone.
    const otel_dep = b.dependency("otel", .{
        .target = target,
        .optimize = optimize,
    });
    const otel_mod = otel_dep.module("otel");
```

- [ ] **Step 2: Expose `otel` to `root_mod`**

In the `root_mod.addImport(...)` cluster (around build.zig:451 alongside `root_mod.addImport("graph_storage", graph_storage_mod);`), add:

```zig
    root_mod.addImport("otel", otel_mod);
```

- [ ] **Step 3: Expose `otel` to the unified CLI executable**

After `geode_exe.root_module.addImport("graph_storage", graph_storage_mod);` (around build.zig:510), add:

```zig
    geode_exe.root_module.addImport("otel", otel_mod);
```

- [ ] **Step 4: Smoke-build with the new import**

Run:
```bash
zig build 2>&1 | tail -30
```

Expected: build succeeds. There may be unused-import warnings — that's fine until Task 3 lands. If the build fails with `file exists in modules 'build_options0' and 'build_optionsN'`, a transitive dep version conflicted; double-check Task 1 left every `use_devnw_*` flag at default.

- [ ] **Step 5: Commit**

```bash
git add build.zig
git commit -m "build(otel): wire otel module into root + cli targets"
```

---

### Task 3: Resource builder (`src/monitoring/otel_resource.zig`)

**Files:**
- Create: `src/monitoring/otel_resource.zig`
- Test: `tests/test_otel_resource_attrs.zig`

- [ ] **Step 1: Write the failing test**

Create `tests/test_otel_resource_attrs.zig`:

```zig
const std = @import("std");
const otel = @import("otel");
const otel_resource = @import("otel_resource");

test "resource carries service + db semconv attributes" {
    const gpa = std.testing.allocator;
    var resource = try otel_resource.buildResource(gpa, .{
        .service_version = "0.1.4",
        .instance_id = "test-instance-uuid",
        .cluster_name = null,
        .node_id = null,
        .node_role = .standalone,
    });
    defer resource.deinit();

    try std.testing.expectEqualStrings("geode", resource.attributes.getString(otel.semconv.service_name).?);
    try std.testing.expectEqualStrings("0.1.4", resource.attributes.getString(otel.semconv.service_version).?);
    try std.testing.expectEqualStrings("test-instance-uuid", resource.attributes.getString(otel.semconv.service_instance_id).?);
    try std.testing.expectEqualStrings("codepros", resource.attributes.getString(otel.semconv.service_namespace).?);
    try std.testing.expectEqualStrings("codepros.geode", resource.attributes.getString("db.system.name").?);
    try std.testing.expectEqualStrings("standalone", resource.attributes.getString("geode.node.role").?);
}

test "cluster mode adds geode.cluster.name + geode.node.id" {
    const gpa = std.testing.allocator;
    var resource = try otel_resource.buildResource(gpa, .{
        .service_version = "0.1.4",
        .instance_id = "test-instance",
        .cluster_name = "production-cluster",
        .node_id = "node-1",
        .node_role = .leader,
    });
    defer resource.deinit();

    try std.testing.expectEqualStrings("production-cluster", resource.attributes.getString("geode.cluster.name").?);
    try std.testing.expectEqualStrings("node-1", resource.attributes.getString("geode.node.id").?);
    try std.testing.expectEqualStrings("leader", resource.attributes.getString("geode.node.role").?);
}
```

Wire the test into `build.zig` next to `tests/test_rls_expr_engine_wiring.zig` (search for that string and copy the pattern, including the `addImport("otel", otel_mod)` line). The new module needs `addImport("otel_resource", b.createModule(...))` rooted at `src/monitoring/otel_resource.zig`.

- [ ] **Step 2: Run the test, expect a build failure**

Run:
```bash
zig build test --summary new 2>&1 | grep -E "error|FAIL" | head -10
```

Expected: compilation failure because `src/monitoring/otel_resource.zig` does not exist yet.

- [ ] **Step 3: Implement `otel_resource.buildResource`**

Create `src/monitoring/otel_resource.zig`:

```zig
const std = @import("std");
const otel = @import("otel");

pub const NodeRole = enum {
    standalone,
    leader,
    follower,
    coordinator,

    pub fn name(self: NodeRole) []const u8 {
        return @tagName(self);
    }
};

pub const Options = struct {
    service_version: []const u8,
    instance_id: []const u8,
    cluster_name: ?[]const u8,
    node_id: ?[]const u8,
    node_role: NodeRole,
    deployment_environment: ?[]const u8 = null,
};

/// Build the OTel `Resource` populated with Geode's required + recommended
/// attributes per docs/otel-updates.md §1.
///
/// Required: service.name, service.instance.id, db.system.name.
/// Recommended: service.namespace, service.version, geode.node.role.
/// Cluster-only: geode.cluster.name, geode.node.id.
///
/// Caller owns the returned `Resource` and MUST call `.deinit()`.
pub fn buildResource(allocator: std.mem.Allocator, opts: Options) !otel.sdk.resource.Resource {
    var resource = try otel.sdk.resource.defaultResource(allocator);
    errdefer resource.deinit();

    try resource.attributes.putString(otel.semconv.service_name, "geode");
    try resource.attributes.putString(otel.semconv.service_namespace, "codepros");
    try resource.attributes.putString(otel.semconv.service_version, opts.service_version);
    try resource.attributes.putString(otel.semconv.service_instance_id, opts.instance_id);
    // db.system.name MUST be "codepros.geode" — the well-known value
    // "geode" is reserved for Apache Geode in OTel's DB semconv.
    try resource.attributes.putString("db.system.name", "codepros.geode");
    try resource.attributes.putString("geode.node.role", opts.node_role.name());

    if (opts.cluster_name) |c| try resource.attributes.putString("geode.cluster.name", c);
    if (opts.node_id) |n| try resource.attributes.putString("geode.node.id", n);
    if (opts.deployment_environment) |env| {
        try resource.attributes.putString("deployment.environment.name", env);
    }
    return resource;
}
```

- [ ] **Step 4: Run the test, expect PASS**

Run:
```bash
zig build test --summary new 2>&1 | grep -E "test_otel_resource"
```

Expected: both subtests pass.

- [ ] **Step 5: Commit**

```bash
git add src/monitoring/otel_resource.zig tests/test_otel_resource_attrs.zig build.zig
git commit -m "feat(otel): resource builder with service + db semconv attrs"
```

---

### Task 4: Facade scaffold (`src/monitoring/otel_metrics.zig`)

**Goal:** A single module that owns the global `MeterProvider`, exposes typed `recordX` functions, and is the only file every other instrumentation site imports from. The facade is empty of metrics in this task; subsequent tasks add one record family at a time.

**Files:**
- Create: `src/monitoring/otel_metrics.zig`
- Test: `tests/test_otel_facade_smoke.zig`

- [ ] **Step 1: Write the failing smoke test**

Create `tests/test_otel_facade_smoke.zig`:

```zig
const std = @import("std");
const otel = @import("otel");
const otel_metrics = @import("otel_metrics");

test "facade init + shutdown is idempotent" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    // Calling init twice must be a no-op (same pointer returned).
    const provider1 = otel_metrics.getProvider().?;
    try otel_metrics.initForTesting(gpa);
    const provider2 = otel_metrics.getProvider().?;
    try std.testing.expectEqual(provider1, provider2);
}

test "facade meter is non-null after init" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    // Smoke: registering a counter through the meter must not error.
    const meter = otel_metrics.meter();
    const c = try meter.counter(.{ .name = "geode.smoke.test", .kind = .counter });
    c.add(1, &.{});
}
```

Wire `tests/test_otel_facade_smoke.zig` into `build.zig` the same way as Task 3. Both tests need the `otel_metrics` module addImport against `src/monitoring/otel_metrics.zig`.

- [ ] **Step 2: Run test — expect "module not found"**

```bash
zig build test --summary new 2>&1 | tail -5
```

- [ ] **Step 3: Implement the scaffold**

Create `src/monitoring/otel_metrics.zig`:

```zig
const std = @import("std");
const otel = @import("otel");
const otel_resource = @import("otel_resource.zig");

const SCOPE_NAME = "com.geodedb.geode";
const SCHEMA_URL = "https://schemas.geodedb.com/otel/geode/metrics/1.0.0";

var g_provider: ?*otel.sdk.metrics.MeterProvider = null;
var g_resource: ?otel.sdk.resource.Resource = null;
var g_allocator: ?std.mem.Allocator = null;
var g_init_mu: std.Thread.Mutex = .{};

/// Initialise the global MeterProvider for production. Idempotent.
/// `service_version` is taken from the build options; `instance_id` is
/// generated once per process via uuid v7.
pub fn init(
    allocator: std.mem.Allocator,
    opts: otel_resource.Options,
) !void {
    g_init_mu.lock();
    defer g_init_mu.unlock();
    if (g_provider != null) return;

    var resource = try otel_resource.buildResource(allocator, opts);
    errdefer resource.deinit();

    const provider = try allocator.create(otel.sdk.metrics.MeterProvider);
    errdefer allocator.destroy(provider);
    provider.* = try otel.sdk.metrics.MeterProvider.init(allocator, .{
        .resource = &resource,
        .disabled = false,
    });

    g_resource = resource;
    g_provider = provider;
    g_allocator = allocator;
}

/// Test variant: builds a fixed-attribute resource so unit tests don't
/// depend on env vars.
pub fn initForTesting(allocator: std.mem.Allocator) !void {
    return init(allocator, .{
        .service_version = "test",
        .instance_id = "test-instance",
        .cluster_name = null,
        .node_id = null,
        .node_role = .standalone,
    });
}

pub fn shutdown() void {
    g_init_mu.lock();
    defer g_init_mu.unlock();
    if (g_provider) |p| {
        p.deinit();
        if (g_allocator) |a| a.destroy(p);
    }
    g_provider = null;
    if (g_resource) |*r| r.deinit();
    g_resource = null;
    g_allocator = null;
}

pub fn getProvider() ?*otel.sdk.metrics.MeterProvider {
    return g_provider;
}

pub fn meter() otel.api.metrics.Meter {
    if (g_provider) |p| {
        return p.meter(.{
            .name = SCOPE_NAME,
            .version = otel.version,
            .schema_url = SCHEMA_URL,
        });
    }
    // Pre-init or post-shutdown: return an inert no-op meter so call
    // sites never crash. The OTel API guarantees noop instrument shape.
    return .{ .scope = .{ .name = SCOPE_NAME } };
}
```

- [ ] **Step 4: Run test, expect PASS**

```bash
zig build test --summary new 2>&1 | grep test_otel_facade
```

- [ ] **Step 5: Commit**

```bash
git add src/monitoring/otel_metrics.zig tests/test_otel_facade_smoke.zig build.zig
git commit -m "feat(otel): facade scaffold with global MeterProvider lifecycle"
```

---

### Task 5: Histogram bucket profile constants

**Goal:** Encode the seven bucket profiles from spec §2 as comptime constants so every histogram across the codebase uses the right shape.

**Files:**
- Modify: `src/monitoring/otel_metrics.zig`
- Test: `tests/test_otel_facade_smoke.zig` (extend)

- [ ] **Step 1: Append a failing test for bucket constants**

Add to `tests/test_otel_facade_smoke.zig`:

```zig
test "bucket profiles match spec" {
    try std.testing.expectEqualSlices(f64, &.{ 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 10 }, otel_metrics.buckets_db_client_duration);
    try std.testing.expectEqualSlices(f64, &.{ 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60 }, otel_metrics.buckets_query_duration);
    try std.testing.expectEqualSlices(f64, &.{ 0.00001, 0.00005, 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1 }, otel_metrics.buckets_storage_io_duration);
    try std.testing.expectEqualSlices(f64, &.{ 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 30 }, otel_metrics.buckets_lock_wait_duration);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000 }, otel_metrics.buckets_rows);
    try std.testing.expectEqualSlices(f64, &.{ 128, 512, 1024, 4096, 16384, 65536, 262144, 1048576, 4194304, 16777216, 67108864 }, otel_metrics.buckets_bytes);
    try std.testing.expectEqualSlices(f64, &.{ 0, 1, 2, 5, 10, 20, 50, 100, 500, 1000, 10000 }, otel_metrics.buckets_graph_degree);
}
```

- [ ] **Step 2: Run, expect FAIL (undefined identifiers)**

```bash
zig build test --summary new 2>&1 | tail -5
```

- [ ] **Step 3: Add the constants to `otel_metrics.zig`**

Append to `src/monitoring/otel_metrics.zig`:

```zig
// Histogram bucket profiles per docs/otel-updates.md §2.
pub const buckets_db_client_duration: []const f64 = &.{ 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 10 };
pub const buckets_query_duration: []const f64 = &.{ 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60 };
pub const buckets_storage_io_duration: []const f64 = &.{ 0.00001, 0.00005, 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1 };
pub const buckets_lock_wait_duration: []const f64 = &.{ 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 30 };
pub const buckets_rows: []const f64 = &.{ 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000 };
pub const buckets_bytes: []const f64 = &.{ 128, 512, 1024, 4096, 16384, 65536, 262144, 1048576, 4194304, 16777216, 67108864 };
pub const buckets_graph_degree: []const f64 = &.{ 0, 1, 2, 5, 10, 20, 50, 100, 500, 1000, 10000 };
```

- [ ] **Step 4: Run test, expect PASS**

- [ ] **Step 5: Commit**

```bash
git add src/monitoring/otel_metrics.zig tests/test_otel_facade_smoke.zig
git commit -m "feat(otel): histogram bucket profile constants per spec §2"
```

---

### Task 6: Server startup wires MeterProvider

**Files:**
- Modify: `src/server/main.zig:586` (around the `metrics_server.initGlobalMetrics` block)
- Add: a uuidv7 instance_id generator using the existing `uuid` dep.

- [ ] **Step 1: Locate the existing init block**

Read `src/server/main.zig:580-600`. The block currently reads `GEODE_METRICS_PORT`, calls `metrics_server.initGlobalMetrics(gpa, port)`, and `defer`s `metrics_server.shutdownGlobalMetrics(gpa)`. The new code must run BEFORE that block so the metrics server can immediately render OTel metrics.

- [ ] **Step 2: Insert OTel facade init**

Above the existing `metrics_port_env` line (~src/server/main.zig:580), add:

```zig
    // CANARY: REQ=REQ-OTEL-METRICS-001; FEATURE="OTel Instrumentation"; ASPECT=ServerInit; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28
    const otel_metrics = @import("../monitoring/otel_metrics.zig");
    const otel_resource = @import("../monitoring/otel_resource.zig");

    // Generate a per-process instance_id (uuidv7 — k-sortable so multiple
    // restarts of the same node sort by start time in observability tools).
    var instance_id_buf: [36]u8 = undefined;
    const instance_id = blk: {
        const uuid = @import("uuid");
        const v7 = uuid.v7.generate();
        break :blk try std.fmt.bufPrint(&instance_id_buf, "{}", .{v7});
    };

    const cluster_token = getEnvVarOwned(gpa, "GEODE_CLUSTER_TOKEN") catch null;
    defer if (cluster_token) |t| gpa.free(t);
    const node_id = getEnvVarOwned(gpa, "GEODE_NODE_ID") catch null;
    defer if (node_id) |n| gpa.free(n);
    const cluster_name = getEnvVarOwned(gpa, "GEODE_CLUSTER_NAME") catch null;
    defer if (cluster_name) |c| gpa.free(c);
    const env_name = getEnvVarOwned(gpa, "OTEL_DEPLOYMENT_ENVIRONMENT") catch null;
    defer if (env_name) |e| gpa.free(e);

    const node_role: otel_resource.NodeRole = if (cluster_token != null) .leader else .standalone;

    otel_metrics.init(gpa, .{
        .service_version = build_options.geode_version,
        .instance_id = instance_id,
        .cluster_name = cluster_name,
        .node_id = node_id,
        .node_role = node_role,
        .deployment_environment = env_name,
    }) catch |err| {
        log.warn("Failed to initialise OTel metrics", &.{
            Attr.string("error", @errorName(err)),
        });
    };
    defer otel_metrics.shutdown();
```

- [ ] **Step 3: Add `geode_version` to build_options**

In `build.zig`, find the `b.addOptions()` block (search for `addOption(bool, "metrics_enabled"` or similar). Add:

```zig
    options.addOption([]const u8, "geode_version", "0.1.4");
```

If the option already exists, skip this step.

- [ ] **Step 4: Build and confirm the server still starts**

```bash
zig build && ./zig-out/bin/geode --help 2>&1 | head -5
```

Expected: build succeeds; help text prints. If `getEnvVarOwned` is not in scope at this file location, add an alias near the top of `src/server/main.zig` matching the existing pattern in `src/monitoring/metrics_server.zig:4-9`.

- [ ] **Step 5: Manual integration test**

```bash
GEODE_METRICS_PORT=9090 ./zig-out/bin/geode serve --listen 127.0.0.1:3141 &
sleep 2
curl -s http://127.0.0.1:9090/metrics | head -5
kill %1
```

Expected: server boots, /metrics returns the legacy `# HELP` header (OTel snapshot is empty until later tasks add instruments — the existing `prometheus.MetricsCollector` still serves the page).

- [ ] **Step 6: Commit**

```bash
git add src/server/main.zig build.zig
git commit -m "feat(otel): initialise MeterProvider during server startup"
```

---

### Task 7: Prometheus responder uses OTel exporter

**Files:**
- Create: `src/monitoring/otel_prometheus_responder.zig`
- Modify: `src/monitoring/metrics_server.zig` body-writer code path
- Test: `tests/test_otel_prometheus_parity.zig`

- [ ] **Step 1: Write the failing parity test**

Create `tests/test_otel_prometheus_parity.zig`:

```zig
const std = @import("std");
const otel = @import("otel");
const otel_metrics = @import("otel_metrics");
const otel_resp = @import("otel_prometheus_responder");

test "responder renders an OTel snapshot" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    // Push one counter through the OTel meter.
    const meter = otel_metrics.meter();
    const c = try meter.counter(.{
        .name = "geode.parity.test",
        .description = "parity probe",
        .unit = "{event}",
        .kind = .counter,
    });
    c.add(7, &.{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try otel_resp.renderInto(gpa, &out);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "geode_parity_test 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "# HELP geode_parity_test parity probe") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "# TYPE geode_parity_test counter") != null);
}
```

Wire into `build.zig`.

- [ ] **Step 2: Run, expect FAIL (module not found)**

- [ ] **Step 3: Implement the responder**

Create `src/monitoring/otel_prometheus_responder.zig`:

```zig
const std = @import("std");
const otel = @import("otel");
const otel_metrics = @import("otel_metrics.zig");

/// Render the current OTel metric snapshot in Prometheus exposition
/// format and append it to `out`. Returns `error.MeterProviderNotInitialised`
/// when the global MeterProvider is not initialised — the caller's HTTP
/// handler should fall back to the legacy `prometheus.MetricsCollector` in
/// that case.
pub fn renderInto(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    const provider = otel_metrics.getProvider() orelse return error.MeterProviderNotInitialised;
    var prom = otel.exporters.prometheus.Prometheus.init(allocator, provider);
    const body = try prom.render();
    defer allocator.free(body);
    try out.appendSlice(allocator, body);
}

/// Convenience: returns true when OTel rendering is available so callers
/// can decide whether to fall back to the legacy collector.
pub fn isAvailable() bool {
    return otel_metrics.getProvider() != null;
}
```

- [ ] **Step 4: Re-route the metrics server body writer**

In `src/monitoring/metrics_server.zig`, locate the function that writes the response body for `GET /metrics` (search for `text/plain; version=0.0.4` — it's the standard Prometheus content-type). Replace the body-writing block with a guarded fallback:

```zig
    const otel_resp = @import("otel_prometheus_responder.zig");
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(self.allocator);

    if (otel_resp.isAvailable()) {
        otel_resp.renderInto(self.allocator, &body) catch |err| {
            std.log.warn("OTel /metrics render failed, falling back: {s}", .{@errorName(err)});
            try self.collector.exportMetrics(body.writer(self.allocator));
        };
    } else {
        try self.collector.exportMetrics(body.writer(self.allocator));
    }
    // ...existing code that writes `body.items` to the connection writer.
```

(`exportMetrics` is the existing function name in `src/monitoring/prometheus.zig`; confirm by reading that file before adapting.)

- [ ] **Step 5: Run test, expect PASS; smoke test the live endpoint**

```bash
zig build test --summary new 2>&1 | grep test_otel_prometheus_parity
zig build && GEODE_METRICS_PORT=9090 ./zig-out/bin/geode serve --listen 127.0.0.1:3141 &
sleep 2
curl -s http://127.0.0.1:9090/metrics
kill %1
```

The /metrics body should now show OTel-rendered output (likely empty until later tasks register instruments — but the `# HELP`/`# TYPE` headers from the legacy fallback should disappear).

- [ ] **Step 6: Commit**

```bash
git add src/monitoring/otel_prometheus_responder.zig src/monitoring/metrics_server.zig tests/test_otel_prometheus_parity.zig build.zig
git commit -m "feat(otel): /metrics renders OTel snapshot, legacy collector fallback"
```

---

### Task 8: Server lifecycle metrics (§4.1)

**Goal:** `geode.server.uptime`, `geode.server.health`, `geode.server.config.reload.count`, `geode.server.shutdown.count`.

**Files:**
- Modify: `src/monitoring/otel_metrics.zig` (add `recordServerLifecycle` + observable gauges)
- Modify: `src/server/main.zig` (register the observable callbacks at startup)

- [ ] **Step 1: Failing test**

Append to `tests/test_otel_facade_smoke.zig`:

```zig
test "server lifecycle metrics register" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    try otel_metrics.registerServerLifecycle(0); // start_time = 0 for determinism
    otel_metrics.recordServerHealth("storage", true);
    otel_metrics.recordConfigReload(.success, null);
    otel_metrics.recordShutdown(.graceful);

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "geode_server_uptime") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_server_health") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_server_config_reload_count") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_server_shutdown_count") != null);
}
```

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement.**

Add to `src/monitoring/otel_metrics.zig`:

```zig
const attrs = @import("otel").internal.attributes;

pub const Outcome = enum { success, error_, timeout, cancelled, partial_success };
fn outcomeName(o: Outcome) []const u8 {
    return switch (o) {
        .success => "success",
        .error_ => "error",
        .timeout => "timeout",
        .cancelled => "cancelled",
        .partial_success => "partial_success",
    };
}

pub const ShutdownReason = enum { graceful, forced, panic };

// --- Lifecycle ---

var g_uptime_start_ms: i64 = 0;
var g_health_states: std.StringHashMapUnmanaged(bool) = .{};
var g_health_mu: std.Thread.Mutex = .{};

pub fn registerServerLifecycle(start_time_ms: i64) !void {
    g_uptime_start_ms = if (start_time_ms == 0) std.time.milliTimestamp() else start_time_ms;
    const m = meter();
    _ = try m.createObservableGauge(
        .{ .name = "geode.server.uptime", .unit = "s", .kind = .observable_gauge, .description = "Seconds since process start" },
        observeUptime,
        null,
    );
    _ = try m.createObservableGauge(
        .{ .name = "geode.server.health", .unit = "1", .kind = .observable_gauge, .description = "1 healthy, 0 unhealthy per component" },
        observeHealth,
        null,
    );
}

fn observeUptime(_: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    const now_ms = std.time.milliTimestamp();
    const seconds = @as(f64, @floatFromInt(now_ms - g_uptime_start_ms)) / 1000.0;
    observer.observeDouble(seconds, &.{});
}

fn observeHealth(_: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    g_health_mu.lock();
    defer g_health_mu.unlock();
    var it = g_health_states.iterator();
    while (it.next()) |kv| {
        const v: f64 = if (kv.value_ptr.*) 1.0 else 0.0;
        observer.observeDouble(v, &.{ attrs.string("geode.component", kv.key_ptr.*) });
    }
}

pub fn recordServerHealth(component: []const u8, healthy: bool) void {
    g_health_mu.lock();
    defer g_health_mu.unlock();
    // The HashMap uses keys that outlive the call (string literals from
    // call sites). If a caller passes a non-literal, they MUST keep the
    // backing storage alive for the process lifetime.
    g_health_states.put(g_allocator.?, component, healthy) catch {};
}

// --- Config reload + shutdown counters ---

var g_config_reload_counter: ?otel.api.metrics.Counter = null;
var g_shutdown_counter: ?otel.api.metrics.Counter = null;

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
    buf[n] = attrs.string("geode.result.outcome", outcomeName(outcome)); n += 1;
    if (error_type) |e| { buf[n] = attrs.string("error.type", e); n += 1; }
    g_config_reload_counter.?.add(1, buf[0..n]);
}

pub fn recordShutdown(reason: ShutdownReason) void {
    ensureLifecycleCounters() catch return;
    g_shutdown_counter.?.add(1, &.{
        attrs.string("geode.shutdown.reason", @tagName(reason)),
    });
}
```

Note on `g_health_states`: keys must outlive the call. Document this constraint and use only string-literal component names in production callers (`"storage"`, `"transport"`, `"audit"`, …).

- [ ] **Step 4: Wire `registerServerLifecycle` into `src/server/main.zig`**

Right after the `otel_metrics.init(...)` call from Task 6, add:

```zig
    otel_metrics.registerServerLifecycle(0) catch |err| {
        log.warn("Failed to register server lifecycle metrics", &.{
            Attr.string("error", @errorName(err)),
        });
    };
    otel_metrics.recordServerHealth("server", true);
```

- [ ] **Step 5: Run test, smoke /metrics**

```bash
zig build test --summary new 2>&1 | grep "server lifecycle"
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/monitoring/otel_metrics.zig src/server/main.zig tests/test_otel_facade_smoke.zig
git commit -m "feat(otel): server lifecycle metrics (uptime, health, reload, shutdown)"
```

---

### Task 9: QUIC transport metrics (§4.2 — P0)

**Goal:** `geode.transport.connection.count`, `connection.opened`, `connection.closed`, `handshake.duration`, `request.inflight`, `request.duration`, `bytes`, `timeout.count`.

**Files:**
- Modify: `src/monitoring/otel_metrics.zig` (add transport family)
- Modify: `src/transport/quic.zig` (instrumentation call sites)
- Modify: `src/server/quic_connection_handler.zig` (request inflight + duration)

- [ ] **Step 1: Failing test (smoke)**

Append to `tests/test_otel_facade_smoke.zig`:

```zig
test "transport metrics register and increment" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    otel_metrics.recordTransportConnectionOpened(.quic);
    otel_metrics.recordTransportConnectionClosed("client_close");
    otel_metrics.recordTransportHandshake(0.012, .success, null);
    otel_metrics.recordTransportRequest("MATCH", 0.034, .success, null);
    otel_metrics.recordTransportBytes(.transmit, 1024);
    otel_metrics.recordTransportTimeout(.handshake);

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);

    for ([_][]const u8{
        "geode_transport_connection_opened",
        "geode_transport_connection_closed",
        "geode_transport_handshake_duration",
        "geode_transport_request_duration",
        "geode_transport_bytes",
        "geode_transport_timeout_count",
    }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, body, name) != null);
    }
}
```

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement the family.**

Add to `src/monitoring/otel_metrics.zig`:

```zig
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
    g_transport = .{
        .connection_opened = try m.counter(.{ .name = "geode.transport.connection.opened", .unit = "{connection}", .kind = .counter, .description = "Accepted/opened connections" }),
        .connection_closed = try m.counter(.{ .name = "geode.transport.connection.closed", .unit = "{connection}", .kind = .counter, .description = "Closed connections" }),
        .handshake_duration = try m.histogram(.{ .name = "geode.transport.handshake.duration", .unit = "s", .kind = .histogram, .description = "QUIC/TLS handshake duration", .explicit_buckets = .{ .boundaries = buckets_db_client_duration } }),
        .request_duration = try m.histogram(.{ .name = "geode.transport.request.duration", .unit = "s", .kind = .histogram, .description = "End-to-end server request handling", .explicit_buckets = .{ .boundaries = buckets_query_duration } }),
        .request_inflight = try m.upDownCounter(.{ .name = "geode.transport.request.inflight", .unit = "{request}", .kind = .up_down_counter, .description = "Active protocol requests" }),
        .bytes = try m.counter(.{ .name = "geode.transport.bytes", .unit = "By", .kind = .counter, .description = "Bytes sent/received" }),
        .timeout_count = try m.counter(.{ .name = "geode.transport.timeout.count", .unit = "{timeout}", .kind = .counter, .description = "Request, connection, or handshake timeouts" }),
    };
    return &g_transport.?;
}

pub fn recordTransportConnectionOpened(proto: TransportProtocol) void {
    const t = ensureTransport() catch return;
    t.connection_opened.add(1, &.{ attrs.string("geode.transport.protocol", @tagName(proto)) });
}

pub fn recordTransportConnectionClosed(reason: []const u8) void {
    const t = ensureTransport() catch return;
    // `reason` is a low-cardinality enum string from a CLOSE frame
    // category — never user-controlled. Documented in the function
    // contract.
    t.connection_closed.add(1, &.{ attrs.string("geode.close.reason", reason) });
}

pub fn recordTransportHandshake(duration_s: f64, outcome: Outcome, error_type: ?[]const u8) void {
    const t = ensureTransport() catch return;
    var buf: [3]attrs.Entry = undefined;
    var n: usize = 0;
    buf[n] = attrs.string("geode.transport.protocol", "quic"); n += 1;
    buf[n] = attrs.string("geode.result.outcome", outcomeName(outcome)); n += 1;
    if (error_type) |e| { buf[n] = attrs.string("error.type", e); n += 1; }
    t.handshake_duration.record(duration_s, buf[0..n]);
}

pub fn recordTransportRequest(op_name: []const u8, duration_s: f64, outcome: Outcome, error_type: ?[]const u8) void {
    const t = ensureTransport() catch return;
    var buf: [3]attrs.Entry = undefined;
    var n: usize = 0;
    buf[n] = attrs.string("db.operation.name", op_name); n += 1;
    buf[n] = attrs.string("geode.result.outcome", outcomeName(outcome)); n += 1;
    if (error_type) |e| { buf[n] = attrs.string("error.type", e); n += 1; }
    t.request_duration.record(duration_s, buf[0..n]);
}

pub fn incTransportInflight(op_name: []const u8) void {
    const t = ensureTransport() catch return;
    t.request_inflight.add(1, &.{ attrs.string("db.operation.name", op_name) });
}

pub fn decTransportInflight(op_name: []const u8) void {
    const t = ensureTransport() catch return;
    t.request_inflight.add(-1, &.{ attrs.string("db.operation.name", op_name) });
}

pub fn recordTransportBytes(direction: NetworkDirection, n_bytes: u64) void {
    const t = ensureTransport() catch return;
    t.bytes.add(n_bytes, &.{ attrs.string("network.io.direction", @tagName(direction)) });
}

pub fn recordTransportTimeout(kind: TimeoutKind) void {
    const t = ensureTransport() catch return;
    t.timeout_count.add(1, &.{ attrs.string("geode.timeout.kind", @tagName(kind)) });
}

// `geode.transport.connection.count` (UpDownCounter) — implemented as an
// observable gauge backed by the QUIC connection table to avoid the
// inc/dec drift bug present in the legacy `connections_total` counter.
var g_active_connections_provider: ?*const fn () i64 = null;

pub fn registerTransportConnectionGauge(provider_fn: *const fn () i64) !void {
    g_active_connections_provider = provider_fn;
    const m = meter();
    _ = try m.createObservableGauge(
        .{ .name = "geode.transport.connection.count", .unit = "{connection}", .kind = .observable_gauge, .description = "Current connections" },
        observeActiveConnections,
        null,
    );
}

fn observeActiveConnections(_: ?*anyopaque, observer: otel.api.metrics.Observer) anyerror!void {
    if (g_active_connections_provider) |fnp| {
        observer.observeInt(fnp(), &.{ attrs.string("geode.transport.protocol", "quic") });
    }
}
```

- [ ] **Step 4: Add call sites in `src/transport/quic.zig`**

Find the connection-accept code path (`handleAccept` or similar — search for `pending_destroy_mutex` to find the accept loop). At successful handshake completion, add:

```zig
    @import("../monitoring/otel_metrics.zig").recordTransportConnectionOpened(.quic);
    const handshake_dur_s = @as(f64, @floatFromInt(handshake_dur_ns)) / 1_000_000_000.0;
    @import("../monitoring/otel_metrics.zig").recordTransportHandshake(handshake_dur_s, .success, null);
```

In the connection-close path (search for `quic_active_connections` decrement), add:

```zig
    @import("../monitoring/otel_metrics.zig").recordTransportConnectionClosed(close_reason_str);
```

In the byte counters (find writes/reads on the QUIC streams), add:

```zig
    @import("../monitoring/otel_metrics.zig").recordTransportBytes(.transmit, n);
```

Register the observable gauge once during transport init:

```zig
    @import("../monitoring/otel_metrics.zig").registerTransportConnectionGauge(activeConnectionCount) catch {};
```

where `activeConnectionCount` returns `@intCast(self.connections.items.len)` under the connections mutex.

- [ ] **Step 5: Add request-duration call sites in `src/server/quic_connection_handler.zig`**

For each handled request, wrap the work with:

```zig
    const om = @import("../monitoring/otel_metrics.zig");
    om.incTransportInflight(op_name);
    defer om.decTransportInflight(op_name);
    var t0 = std.time.nanoTimestamp();
    // ... existing work ...
    const dur_s = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1_000_000_000.0;
    om.recordTransportRequest(op_name, dur_s, outcome, err_type);
```

`op_name` should be a low-cardinality enum string (e.g. `"MATCH"`, `"CREATE"`, `"BEGIN"`) derived from the parsed query type, NOT the raw query text.

- [ ] **Step 6: Run test, smoke real load**

```bash
zig build test --summary new 2>&1 | grep "transport metrics"
zig build && GEODE_METRICS_PORT=9090 ./zig-out/bin/geode serve --listen 127.0.0.1:3141 &
sleep 2
# Generate some traffic, then scrape:
curl -s http://127.0.0.1:9090/metrics | grep -E "geode_transport_(connection|handshake|request)"
kill %1
```

- [ ] **Step 7: Commit**

```bash
git add src/monitoring/otel_metrics.zig src/transport/quic.zig src/server/quic_connection_handler.zig tests/test_otel_facade_smoke.zig
git commit -m "feat(otel): QUIC transport metrics (P0 set per spec §4.2)"
```

---

### Task 10: Query lifecycle metrics (§4.3 — P0)

**Goal:** `geode.query.count`, `query.active`, `query.execution.duration`, `query.parse.duration`, `query.parse.error.count`, `query.plan.duration`, `query.rows.returned`, `query.timeout.count`.

**Files:**
- Modify: `src/monitoring/otel_metrics.zig` (add query family + `recordQuery*` functions)
- Modify: `src/execution/execution.zig` (query-execution wrap)
- Modify: `src/gql/parser.zig` (parse duration / error count)
- Modify: `src/planner/planner.zig` (plan duration)

- [ ] **Step 1: Failing test**

Append to `tests/test_otel_facade_smoke.zig`:

```zig
test "query metrics register" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    otel_metrics.incQueryActive(.read);
    otel_metrics.recordQueryExecution("MATCH", "MATCH Person", .read, 0.012, .success, null);
    otel_metrics.recordQueryParse(0.0001, .success, null);
    otel_metrics.recordQueryParseError("SyntaxError");
    otel_metrics.recordQueryPlan("MATCH", 0.0005, "cbo");
    otel_metrics.recordQueryRowsReturned("MATCH", "MATCH Person", 42);
    otel_metrics.recordQueryTimeout("MATCH", .request);
    otel_metrics.decQueryActive(.read);

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);
    for ([_][]const u8{
        "geode_query_count",
        "geode_query_execution_duration",
        "geode_query_parse_duration",
        "geode_query_parse_error_count",
        "geode_query_plan_duration",
        "geode_query_rows_returned",
        "geode_query_timeout_count",
    }) |name| try std.testing.expect(std.mem.indexOf(u8, body, name) != null);
}
```

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement** — append to `otel_metrics.zig`:

```zig
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
    g_query = .{
        .count = try m.counter(.{ .name = "geode.query.count", .unit = "{query}", .kind = .counter, .description = "Queries executed" }),
        .active = try m.upDownCounter(.{ .name = "geode.query.active", .unit = "{query}", .kind = .up_down_counter, .description = "Currently running queries" }),
        .execution_duration = try m.histogram(.{ .name = "geode.query.execution.duration", .unit = "s", .kind = .histogram, .description = "Server-side full query execution latency", .explicit_buckets = .{ .boundaries = buckets_query_duration } }),
        .parse_duration = try m.histogram(.{ .name = "geode.query.parse.duration", .unit = "s", .kind = .histogram, .description = "GQL parse/lex duration", .explicit_buckets = .{ .boundaries = buckets_query_duration } }),
        .parse_error_count = try m.counter(.{ .name = "geode.query.parse.error.count", .unit = "{error}", .kind = .counter, .description = "Parse errors" }),
        .plan_duration = try m.histogram(.{ .name = "geode.query.plan.duration", .unit = "s", .kind = .histogram, .description = "Logical/physical planning duration", .explicit_buckets = .{ .boundaries = buckets_query_duration } }),
        .rows_returned = try m.histogram(.{ .name = "geode.query.rows.returned", .unit = "{row}", .kind = .histogram, .description = "Rows returned by server execution", .explicit_buckets = .{ .boundaries = buckets_rows } }),
        .timeout_count = try m.counter(.{ .name = "geode.query.timeout.count", .unit = "{timeout}", .kind = .counter, .description = "Query timeout count" }),
    };
    return &g_query.?;
}

pub fn incQueryActive(qt: QueryType) void {
    const q = ensureQuery() catch return;
    q.active.add(1, &.{ attrs.string("geode.query.type", @tagName(qt)) });
}

pub fn decQueryActive(qt: QueryType) void {
    const q = ensureQuery() catch return;
    q.active.add(-1, &.{ attrs.string("geode.query.type", @tagName(qt)) });
}

pub fn recordQueryExecution(op: []const u8, summary: []const u8, qt: QueryType, duration_s: f64, outcome: Outcome, error_type: ?[]const u8) void {
    const q = ensureQuery() catch return;
    var buf: [5]attrs.Entry = undefined;
    var n: usize = 0;
    buf[n] = attrs.string("db.operation.name", op); n += 1;
    buf[n] = attrs.string("db.query.summary", summary); n += 1;
    buf[n] = attrs.string("geode.query.type", @tagName(qt)); n += 1;
    buf[n] = attrs.string("geode.result.outcome", outcomeName(outcome)); n += 1;
    if (error_type) |e| { buf[n] = attrs.string("error.type", e); n += 1; }
    q.execution_duration.record(duration_s, buf[0..n]);
    q.count.add(1, buf[0..n]);
}

pub fn recordQueryParse(duration_s: f64, outcome: Outcome, error_type: ?[]const u8) void {
    const q = ensureQuery() catch return;
    var buf: [2]attrs.Entry = undefined;
    var n: usize = 0;
    buf[n] = attrs.string("geode.result.outcome", outcomeName(outcome)); n += 1;
    if (error_type) |e| { buf[n] = attrs.string("error.type", e); n += 1; }
    q.parse_duration.record(duration_s, buf[0..n]);
}

pub fn recordQueryParseError(error_type: []const u8) void {
    const q = ensureQuery() catch return;
    q.parse_error_count.add(1, &.{ attrs.string("error.type", error_type) });
}

pub fn recordQueryPlan(op: []const u8, duration_s: f64, planner_strategy: []const u8) void {
    const q = ensureQuery() catch return;
    q.plan_duration.record(duration_s, &.{
        attrs.string("db.operation.name", op),
        attrs.string("geode.planner.strategy", planner_strategy),
    });
}

pub fn recordQueryRowsReturned(op: []const u8, summary: []const u8, rows: u64) void {
    const q = ensureQuery() catch return;
    q.rows_returned.record(@floatFromInt(rows), &.{
        attrs.string("db.operation.name", op),
        attrs.string("db.query.summary", summary),
    });
}

pub fn recordQueryTimeout(op: []const u8, kind: TimeoutKind) void {
    const q = ensureQuery() catch return;
    q.timeout_count.add(1, &.{
        attrs.string("db.operation.name", op),
        attrs.string("geode.timeout.kind", @tagName(kind)),
    });
}
```

**`db.query.summary` rule:** the summary string MUST be derived from the parsed AST (e.g. `"MATCH Person"`), never the raw query text. Helper `summarize(ast)` lives in `src/gql/parser.zig`; if it doesn't exist yet, add a minimal implementation that returns `"<op> <first label>"`.

- [ ] **Step 4: Add call sites**

In `src/execution/execution.zig` at the top of `executeStatement` (or whichever function runs a single query):

```zig
    const om = @import("../monitoring/otel_metrics.zig");
    const qt: om.QueryType = classifyQueryType(stmt); // helper that maps READ/WRITE/etc.
    om.incQueryActive(qt);
    defer om.decQueryActive(qt);
    const t0 = std.time.nanoTimestamp();
    const op_name = stmt.operationName();
    const summary = stmt.summary();
    var outcome: om.Outcome = .success;
    var err_type: ?[]const u8 = null;
    defer {
        const dur_s = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1_000_000_000.0;
        om.recordQueryExecution(op_name, summary, qt, dur_s, outcome, err_type);
    }
```

(`classifyQueryType` and the `stmt.operationName/summary` helpers may need to be added — they're trivial enum-switch helpers.)

In `src/gql/parser.zig` around the entry point (search for `pub fn parse` or `pub fn parseQuery`):

```zig
    const t0 = std.time.nanoTimestamp();
    const result = try doParseInner(...);
    const dur_s = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1_000_000_000.0;
    @import("../monitoring/otel_metrics.zig").recordQueryParse(dur_s, .success, null);
```

On the error path, call `recordQueryParse(dur_s, .error_, @errorName(err))` and `recordQueryParseError(@errorName(err))`.

In `src/planner/planner.zig` around `plan()`:

```zig
    const t0 = std.time.nanoTimestamp();
    defer {
        const dur_s = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1_000_000_000.0;
        @import("../monitoring/otel_metrics.zig").recordQueryPlan(stmt.operationName(), dur_s, "cbo");
    }
```

- [ ] **Step 5: Run tests**

```bash
zig build test --summary new
```

- [ ] **Step 6: Commit**

```bash
git add src/monitoring/otel_metrics.zig src/execution/execution.zig src/gql/parser.zig src/planner/planner.zig tests/test_otel_facade_smoke.zig
git commit -m "feat(otel): query lifecycle metrics (P0 set per spec §4.3)"
```

---

### Task 11: Transaction metrics (§4.6 — P0)

**Goal:** `geode.transaction.count`, `transaction.active`, `transaction.duration`, `transaction.commit.duration`, `transaction.abort.count`, `transaction.timeout.count`, `transaction.serialization_conflict.count`, `transaction.deadlock.count`, `transaction.lock.wait.duration`.

**Files:**
- Modify: `src/monitoring/otel_metrics.zig` (add transaction family — same pattern as Task 10)
- Modify: `src/execution/transaction_manager.zig` (begin/commit/abort/timeout call sites)
- Modify: `src/execution/lock_manager.zig` (lock-wait + deadlock detection sites)

- [ ] **Step 1: Failing test** — append to `tests/test_otel_facade_smoke.zig` an analogous block to Task 10's, calling `recordTransaction*` and asserting the seven Prometheus names appear.

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement.** Follow the Task 10 facade pattern. The new types:

```zig
pub const IsolationLevel = enum { read_committed, snapshot, serializable_snapshot, repeatable_read, read_uncommitted, serializable };
pub const AbortReason = enum { user, conflict, timeout, deadlock, system_error };
pub const LockType = enum { row, predicate, range, exclusive, shared };
```

Function signatures:
```zig
pub fn recordTransactionBegin(level: IsolationLevel) void;
pub fn recordTransactionCommit(level: IsolationLevel, duration_s: f64, outcome: Outcome) void;
pub fn recordTransactionAbort(reason: AbortReason, error_type: ?[]const u8) void;
pub fn recordTransactionTimeout(level: IsolationLevel) void;
pub fn recordSerializationConflict(conflict_type: []const u8) void;
pub fn recordDeadlock(victim_policy: []const u8) void;
pub fn recordLockWait(lock_type: LockType, duration_s: f64, outcome: Outcome) void;
pub fn incTransactionActive(level: IsolationLevel) void;
pub fn decTransactionActive(level: IsolationLevel) void;
```

Use `buckets_query_duration` for transaction durations and `buckets_lock_wait_duration` for `lock.wait.duration`.

- [ ] **Step 4: Wire call sites**

`src/execution/transaction_manager.zig`: in `begin()` call `incTransactionActive(level)` and `recordTransactionBegin(level)`. In `commit()` time the work and call `recordTransactionCommit(...)` + `decTransactionActive(level)`. In `abort()` call `recordTransactionAbort(reason, err_name)` + `decTransactionActive(level)`. On timeout, call `recordTransactionTimeout(level)`.

`src/execution/lock_manager.zig`: every `acquireLock` call sets a `t0` and calls `recordLockWait(...)` on return. The deadlock-detection cycle (search for `detectDeadlock` or `WaitForGraph`) calls `recordDeadlock(policy_name)` whenever it aborts a victim.

`src/execution/transaction_isolation.zig` (SSI conflict path): on every read/write conflict, `recordSerializationConflict(conflict_type)`.

- [ ] **Step 5: Run, smoke /metrics under load.**

- [ ] **Step 6: Commit**

```bash
git add src/monitoring/otel_metrics.zig src/execution/transaction_manager.zig src/execution/lock_manager.zig src/execution/transaction_isolation.zig tests/test_otel_facade_smoke.zig
git commit -m "feat(otel): transaction + lock + deadlock metrics (P0 set per spec §4.6)"
```

---

### Task 12: Storage + WAL metrics (§4.5 — P0)

**Goal:** `geode.storage.operation.count`, `storage.operation.duration`, `storage.bytes`, `storage.page.cache.lookup`, `storage.file.size`, `storage.disk.usage`, `wal.record.count`, `wal.bytes`, `wal.append.duration`, `wal.flush.duration`, `wal.fsync.duration`, `wal.size`, `wal.replay.duration`, `wal.replay.record.count`.

**Files:**
- Modify: `src/monitoring/otel_metrics.zig`
- Modify: `src/storage/graph_storage_adapter.zig` (storage operation wrap)
- Modify: `src/storage/page_cache.zig` (lookup hit/miss)
- WAL operations live in the external `wal` dependency. Geode's adapter (`src/storage/wal_adapter.zig` or similar — find via `grep -rn "wal\.append" src/`) is the right place to instrument; do NOT modify the upstream `wal` repo.

- [ ] **Step 1: Failing test (mirrors Task 10).**

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement** — same facade pattern. Types:

```zig
pub const StorageOp = enum { read_node, write_node, read_edge, write_edge, scan, compact };
pub const StorageIoDir = enum { read, write };
pub const CacheOutcome = enum { hit, miss, evicted };
pub const WalRecordType = enum { node_create, node_update, node_delete, edge_create, edge_update, edge_delete, txn_begin, txn_commit, txn_abort, checkpoint };
pub const WalIoDir = enum { write, replay };
```

Functions:
```zig
pub fn recordStorageOp(op: StorageOp, duration_s: f64, outcome: Outcome, error_type: ?[]const u8) void;
pub fn recordStorageBytes(direction: StorageIoDir, n_bytes: u64) void;
pub fn recordPageCacheLookup(outcome: CacheOutcome) void;
pub fn registerStorageFileSizeGauge(...) !void;       // observable gauge
pub fn registerStorageDiskUsageGauge(...) !void;      // observable gauge
pub fn recordWalRecord(rec_type: WalRecordType) void;
pub fn recordWalBytes(direction: WalIoDir, n_bytes: u64) void;
pub fn recordWalAppend(duration_s: f64, outcome: Outcome) void;
pub fn recordWalFlush(duration_s: f64, outcome: Outcome) void;
pub fn recordWalFsync(duration_s: f64, outcome: Outcome) void;
pub fn registerWalSizeGauge(provider_fn: *const fn () i64) !void;  // observable gauge
pub fn recordWalReplay(duration_s: f64, outcome: Outcome) void;
pub fn recordWalReplayRecord() void;
```

Use `buckets_storage_io_duration` for storage / WAL durations and `buckets_bytes` for any byte histograms.

- [ ] **Step 4: Wire call sites**

`src/storage/graph_storage_adapter.zig`: every `read*`/`write*` op times its work and calls `recordStorageOp(...)` + `recordStorageBytes(.read|.write, n)` on success.

`src/storage/page_cache.zig`: `lookup()` calls `recordPageCacheLookup(.hit)` or `.miss`; eviction path calls `.evicted`.

WAL adapter: each `append`, `flush`, and `fsync` is wrapped to time and call the corresponding facade function. `recordWalRecord(rec_type)` fires for each appended record. The WAL-size gauge is registered once at startup with a provider closure that returns `wal.totalBytes()`.

`src/storage/file_size_gauge.zig` (new tiny helper or inline in adapter): registers the storage file-size gauge that walks the data dir.

- [ ] **Step 5: Run tests.**

- [ ] **Step 6: Commit**

```bash
git add src/monitoring/otel_metrics.zig src/storage/ tests/test_otel_facade_smoke.zig
git commit -m "feat(otel): storage + WAL metrics (P0 set per spec §4.5)"
```

---

### Task 13: Graph data model + operation metrics (§4.4 — P0)

**Goal:** `geode.graph.node.count`, `graph.edge.count`, `graph.node.operation.count`, `graph.edge.operation.count`.

**Files:**
- Modify: `src/monitoring/otel_metrics.zig`
- Modify: `src/storage/graph_storage_adapter.zig` (mutation hooks already in place from Task 12; extend with op count + observable count gauges).

- [ ] **Step 1: Failing test.**
- [ ] **Step 2: Expect FAIL.**
- [ ] **Step 3: Implement.** Types:

```zig
pub const GraphMutation = enum { create, update, delete };
```

Functions:
```zig
pub fn recordNodeMutation(op: GraphMutation, namespace: []const u8, outcome: Outcome) void;
pub fn recordEdgeMutation(op: GraphMutation, namespace: []const u8, outcome: Outcome) void;
pub fn registerNodeCountGauge(provider_fn: *const fn () i64) !void;
pub fn registerEdgeCountGauge(provider_fn: *const fn () i64) !void;
```

`namespace` is `db.namespace` (e.g. graph name). Keep low cardinality — bounded set of graphs in a single-tenant deployment.

- [ ] **Step 4: Wire call sites in `graph_storage_adapter.zig`.** Each `createNode/updateNode/deleteNode` call goes through `recordNodeMutation`. Same for edges. Register the count gauges at adapter init with `provider_fn` reading `store.nodeCount()` / `store.edgeCount()` under the appropriate lock.

- [ ] **Step 5: Run tests.**
- [ ] **Step 6: Commit.**

```bash
git commit -m "feat(otel): graph data model + mutation metrics (P0 set per spec §4.4)"
```

---

### Task 14: Index + vector/HNSW metrics (§4.7 — P0)

**Goal:** `geode.index.count`, `index.lookup.duration`, `index.lookup.count`, `index.update.duration`, `index.vector.hnsw.search.duration`.

**Files:**
- Modify: `src/monitoring/otel_metrics.zig`
- Modify: `src/index/btree.zig`, `src/index/hash_index.zig`, `src/index/full_text_index.zig`, `src/index/spatial_index.zig`, `src/index/vector_index.zig` (search/lookup wrap)

- [ ] **Step 1: Failing test.**
- [ ] **Step 2: Expect FAIL.**
- [ ] **Step 3: Implement.** Types:

```zig
pub const IndexType = enum { btree, hash, full_text, spatial, vector_hnsw, interval };
pub const VectorMetric = enum { l2, cosine, dot, hamming, jaccard, manhattan };
```

Functions:
```zig
pub fn registerIndexCountGauge(provider_fn: *const fn () []const IndexCount) !void;
pub fn recordIndexLookup(idx_type: IndexType, duration_s: f64, outcome: Outcome) void;
pub fn recordIndexUpdate(idx_type: IndexType, op: GraphMutation, duration_s: f64) void;
pub fn recordHnswSearch(metric: VectorMetric, duration_s: f64) void;
```

- [ ] **Step 4: Wire call sites.** Each index module's `search/lookup/update` entry point gets the standard time-and-record wrap. The HNSW path in `src/index/vector_index.zig` (or external `hnsw` adapter) gets the dedicated `recordHnswSearch` call.

- [ ] **Step 5: Run tests.**
- [ ] **Step 6: Commit.**

```bash
git commit -m "feat(otel): index + vector HNSW metrics (P0 set per spec §4.7)"
```

---

### Task 15: Security, RLS, audit, TDE, KMS metrics (§4.8 — P0)

**Goal:** `geode.security.authentication.attempt.count`, `security.session.count`, `security.authorization.check.count`, `security.authorization.check.duration`, `security.rls.evaluation.count`, `security.rls.evaluation.duration`, `audit.event.count`, `audit.queue.depth`, `audit.event.dropped`, `crypto.tde.operation.duration`, `crypto.tde.bytes`, `crypto.tde.error.count`.

**Hard rule from spec §4.8 + §7:** "Never include usernames, raw tokens, key IDs, policy text, query property values, or session IDs as metric attributes." Every facade function in this task MUST take typed enums or low-cardinality strings only — never `[]const u8 username`.

**Files:**
- Modify: `src/monitoring/otel_metrics.zig`
- Modify: `src/security/authentication.zig`, `src/security/rls_engine.zig`, `src/security/audit.zig`, `src/security/tde.zig`, `src/security/kms_provider.zig`

- [ ] **Step 1: Failing test** — include a check that NO attribute on these metrics has a key ending in `.id`, `.name`, `.user`, or `.token` (cardinality test catches accidental leakage).

- [ ] **Step 2: Expect FAIL.**
- [ ] **Step 3: Implement.** Types:

```zig
pub const AuthMethod = enum { password, mfa, certificate, api_key, hmac_chain };
pub const SessionState = enum { active, idle, terminated };
pub const SecurityDecision = enum { allow, deny };
pub const PolicyType = enum { rbac, abac, rls, tde };
pub const CryptoOp = enum { encrypt, decrypt, rotate, derive };
```

Functions:
```zig
pub fn recordAuthAttempt(method: AuthMethod, outcome: Outcome, error_type: ?[]const u8) void;
pub fn recordAuthDuration(method: AuthMethod, duration_s: f64, outcome: Outcome) void;
pub fn registerSessionCountGauge(provider_fn: *const fn () []const SessionCount) !void;
pub fn recordAuthzCheck(decision: SecurityDecision, policy_type: PolicyType, duration_s: f64) void;
pub fn recordRlsEvaluation(decision: SecurityDecision, policy_type: PolicyType, duration_s: f64) void;
pub fn recordRlsFilteredRows(op: []const u8, n: u64) void;
pub fn recordAuditEvent(event_type: []const u8, outcome: Outcome) void;
pub fn registerAuditQueueGauge(provider_fn: *const fn () i64) !void;
pub fn recordAuditDropped(reason: []const u8) void;
pub fn recordTdeOperation(op: CryptoOp, duration_s: f64, outcome: Outcome) void;
pub fn recordTdeBytes(op: CryptoOp, n_bytes: u64) void;
pub fn recordTdeError(error_type: []const u8) void;
```

- [ ] **Step 4: Wire call sites.** Every `authenticate()` path calls `recordAuthAttempt`. Every `passesRLSExprFilter` / `checkRowAccessByUsername` call gets the time-and-record wrap. Audit emit + drop sites call the matching facade function.

- [ ] **Step 5: Run tests.** The cardinality test from Step 1 must pass — no leaks.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(otel): security/RLS/audit/TDE/KMS metrics (P0 set per spec §4.8)"
```

---

### Task 16: Distributed coordination + cluster metrics (§4.9 — P0)

**Goal:** `geode.cluster.node.count`, `cluster.node.health`, `shard.count`, `shard.query.count`, `distributed.query.count`, `distributed.query.duration`, `distributed.query.fanout`, `distributed.query.partial_failure.count`.

**Files:**
- Modify: `src/monitoring/otel_metrics.zig`
- Modify: `src/distributed/coordinator.zig`, `src/distributed/query_transport.zig`, `src/distributed/node_registry.zig`

- [ ] **Step 1: Failing test.**
- [ ] **Step 2: Expect FAIL.**
- [ ] **Step 3: Implement.** Types:

```zig
pub const ConsistencyLevel = enum { eventual, strong, linearizable };
pub const NodeRoleEnum = NodeRole; // re-export from otel_resource
```

Functions: same shape as previous tasks. Cluster-level metrics emit only when `GEODE_CLUSTER_TOKEN` is set (early-return guard in each function); when single-node, the metrics never register so `/metrics` stays clean.

- [ ] **Step 4: Wire call sites.** Each scatter/gather query path in `query_transport.zig` records `recordDistributedQuery(...)` and `recordDistributedFanout(n_shards)`. Per-shard fragments in `coordinator.zig` record `recordShardQuery(shard_id, outcome)`. Node registry membership changes trigger `recordClusterNodeChange` and the count gauge re-reads on every observable cycle.

- [ ] **Step 5: Run tests.**
- [ ] **Step 6: Commit.**

```bash
git commit -m "feat(otel): distributed + cluster metrics (P0 set per spec §4.9)"
```

---

### Task 17: CDC + real-time analytics metrics (§4.10 — P0)

**Goal:** `geode.cdc.event.count`, `cdc.lag`, `cdc.queue.depth`, `cdc.sink.error.count`, `cdc.event.dropped`, `analytics.event.count`, `analytics.event.queue.depth`, `analytics.event.processing.duration`.

**Files:**
- Modify: `src/monitoring/otel_metrics.zig`
- Modify: `src/cdc/engine.zig`, `src/analytics/streaming.zig`

- [ ] **Step 1: Failing test.**
- [ ] **Step 2: Expect FAIL.**
- [ ] **Step 3: Implement.** Same pattern. Types:

```zig
pub const CdcEventType = enum { node_change, edge_change, schema_change, txn_marker };
pub const SinkType = enum { kafka, http_webhook, file, s3 };
```

Functions: `recordCdcEvent`, `registerCdcLagGauge`, `registerCdcQueueDepthGauge`, `recordCdcSinkError`, `recordCdcEventDropped`, `recordAnalyticsEvent`, `registerAnalyticsQueueGauge`, `recordAnalyticsProcessing`.

- [ ] **Step 4: Wire call sites in `src/cdc/engine.zig` and `src/analytics/streaming.zig`.**
- [ ] **Step 5: Run tests.**
- [ ] **Step 6: Commit.**

```bash
git commit -m "feat(otel): CDC + real-time analytics metrics (P0 set per spec §4.10)"
```

---

### Task 18: Backup/restore metrics (§4.12 — P0)

**Goal:** `geode.backup.count`, `backup.duration`, `backup.bytes`, `restore.count`, `restore.duration`, `restore.bytes`.

**Files:**
- Modify: `src/monitoring/otel_metrics.zig`
- Modify: `src/storage/backup.zig`, `src/storage/s3_backup.zig`

- [ ] **Step 1: Failing test.**
- [ ] **Step 2: Expect FAIL.**
- [ ] **Step 3: Implement.** Types:

```zig
pub const BackupKind = enum { full, incremental, differential };
pub const ObjectStoreProvider = enum { s3, do_spaces, gcs, azure_blob, file };
```

Functions: `recordBackup`, `recordBackupBytes`, `recordRestore`, `recordRestoreBytes`.

- [ ] **Step 4: Wire call sites in `src/storage/backup.zig` and `src/storage/s3_backup.zig`.**
- [ ] **Step 5: Run tests.**
- [ ] **Step 6: Commit.**

```bash
git commit -m "feat(otel): backup + restore metrics (P0 set per spec §4.12)"
```

---

### Task 19: Process metrics + standard `db.client.*`

**Goal:** Standard process metrics (`process.cpu.time`, `process.memory.usage`, `process.uptime`, `process.thread.count`, `process.unix.file_descriptor.count`) and the `db.client.*` family from §3 for the internal remote-query path used in distributed mode.

**Files:**
- Modify: `src/monitoring/otel_metrics.zig`
- Modify: `src/server/main.zig` (call `otel.instrumentation.runtime.register*` at startup)
- Modify: `src/distributed/query_transport.zig` (db.client.* call sites for inter-node RPCs)

- [ ] **Step 1: Failing test.**
- [ ] **Step 2: Expect FAIL.**
- [ ] **Step 3: Implement.** The OTel module ships `otel.instrumentation.runtime` which already exposes process metrics; register it once:

```zig
pub fn registerRuntimeMetrics() !void {
    const m = meter();
    try otel.instrumentation.runtime.register(m);
}
```

For `db.client.operation.duration`, `db.client.connection.count`, etc., add the matching facade functions; the attribute set is `db.system.name=codepros.geode`, `db.namespace`, `db.operation.name`, `server.address`, `server.port`, `geode.result.outcome`, `error.type`. Call sites: `src/distributed/query_transport.zig` outbound RPCs.

- [ ] **Step 4: Wire `registerRuntimeMetrics` into `src/server/main.zig`** right after `registerServerLifecycle`.

- [ ] **Step 5: Run tests, scrape /metrics, verify `process_cpu_time_seconds`, `process_memory_usage_bytes`, etc., appear.**

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(otel): process metrics + db.client.* family for distributed RPC"
```

---

### Task 20: Cardinality + privacy guards

**Goal:** Add an automated test that fails the build if any default-emitted metric carries a forbidden attribute (`user.id`, `username`, `session.id`, `request.id`, `node.id` (when not in cluster mode), `tenant.id`, `index.name`, `policy.name`, `key.id`, `db.query.text`).

**Files:**
- Create: `tests/test_otel_cardinality_guard.zig`

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const otel = @import("otel");
const otel_metrics = @import("otel_metrics");

const FORBIDDEN_KEYS = [_][]const u8{
    "user.id", "username", "session.id", "request.id",
    "trace.id", "span.id", "tenant.id", "geode.tenant.id",
    "index.name", "policy.name", "key.id", "db.query.text",
};

test "no forbidden attribute keys appear in default metric stream" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    // Drive the facade through every public recordX function with safe inputs.
    // ... (ensure every recordX has been called at least once) ...

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);

    for (FORBIDDEN_KEYS) |key| {
        // Prometheus translates `.` -> `_`; the rendered key would be e.g. `user_id="..."`.
        const tk = try std.mem.replaceOwned(u8, gpa, key, ".", "_");
        defer gpa.free(tk);
        var search_buf: [80]u8 = undefined;
        const needle = try std.fmt.bufPrint(&search_buf, "{s}=\"", .{tk});
        const found = std.mem.indexOf(u8, body, needle);
        if (found != null) std.debug.print("LEAK: attribute key {s} appeared in /metrics body\n", .{key});
        try std.testing.expect(found == null);
    }
}
```

- [ ] **Step 2: Run, expect PASS the first time** (because none of the previous tasks introduced forbidden attributes — but if any did, this test catches it now).

- [ ] **Step 3: If the test fails, locate the offending facade function and remove the attribute.** Document the fix.

- [ ] **Step 4: Commit**

```bash
git add tests/test_otel_cardinality_guard.zig build.zig
git commit -m "test(otel): cardinality + privacy guard against forbidden attribute keys"
```

---

### Task 21: OTLP/HTTP push wiring

**Goal:** When `OTEL_METRICS_EXPORTER=otlp` is set, install the `PeriodicMetricReader` with the OTLP/HTTP exporter so the same metrics push to a collector at `OTEL_EXPORTER_OTLP_ENDPOINT` (default `http://localhost:4318`).

**Files:**
- Modify: `src/monitoring/otel_metrics.zig` (extend `init` to honour env)

- [ ] **Step 1: Failing test**

```zig
test "otlp exporter selected when env says so" {
    // Set env, build provider via initFromConfig path, verify owned_exporter
    // is non-null and is otlp_http variant.
    // Skip if running under sandboxed CI without env-setting privilege.
}
```

- [ ] **Step 2: Expect FAIL.**

- [ ] **Step 3: Implement env-driven exporter selection in `otel_metrics.init`:**

```zig
const cfg = try otel.sdk.config.Config.fromEnv(allocator);
defer cfg.deinit();
provider.* = try otel.sdk.metrics.MeterProvider.initFromConfig(allocator, &cfg);
```

This replaces the bare `MeterProvider.init(allocator, .{ .resource = ... })` path with the config-driven one. The Prometheus exporter is still attached separately via the responder (Task 7) — it's pull-based and doesn't go through the periodic reader.

If `OTEL_METRICS_EXPORTER=otlp` is set, the SDK installs a `PeriodicMetricReader` that pushes to the configured endpoint on the configured interval (`OTEL_METRIC_EXPORT_INTERVAL`, default 60s).

- [ ] **Step 4: Verify with a loopback collector**

```bash
docker run --rm -p 4318:4318 -p 8888:8888 otel/opentelemetry-collector:latest --config /etc/otelcol/config.yaml &
OTEL_METRICS_EXPORTER=otlp OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 ./zig-out/bin/geode serve --listen 127.0.0.1:3141 &
sleep 70  # wait for first push interval
# Check collector receives metrics — see collector's debug exporter output or /metrics on :8888.
```

If a collector isn't available in CI, mark this step as manual.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(otel): OTLP/HTTP push when OTEL_METRICS_EXPORTER=otlp"
```

---

### Task 22: Geodetestlab spec for /metrics scrape parity

**Goal:** Add a black-box test in `geodetestlab/specs/otel_metrics_parity.yml` that boots a server, waits for it to be ready, scrapes `/metrics`, and asserts P0 metric names are present with the right Prometheus type lines.

**Files:**
- Create: `geodetestlab/specs/otel_metrics_parity.yml`

- [ ] **Step 1: Write the spec**

```yaml
name: otel_metrics_parity
description: |
  Verifies the Prometheus /metrics endpoint exposes the P0 OTel metric set
  defined in docs/otel-updates.md after a fresh server boot.
setup:
  start_server: true
  metrics_port: 9090
steps:
  - name: scrape_metrics
    type: http_get
    url: http://127.0.0.1:9090/metrics
    expect_status: 200
    expect_body_contains:
      - "# TYPE geode_query_execution_duration histogram"
      - "# TYPE geode_query_count counter"
      - "# TYPE geode_transport_connection_count gauge"
      - "# TYPE geode_transaction_count counter"
      - "# TYPE geode_transaction_deadlock_count counter"
      - "# TYPE geode_wal_fsync_duration histogram"
      - "# TYPE geode_storage_operation_duration histogram"
      - "# TYPE geode_security_authorization_check_duration histogram"
      - "# TYPE geode_audit_event_dropped counter"
      - "# TYPE geode_server_uptime gauge"
  - name: emit_a_query
    type: gql
    query: "RETURN 1 AS x"
  - name: scrape_after_query
    type: http_get
    url: http://127.0.0.1:9090/metrics
    expect_body_regex:
      - 'geode_query_count\{[^}]+geode_result_outcome="success"\} [1-9]'
```

(Adjust the spec format to match what `../geode-test-harness/` already accepts — read another spec file in the same directory for the exact schema.)

- [ ] **Step 2: Run the spec**

```bash
cd ../geode-test-harness
GEODE_BINARY=/path/to/zig-out/bin/geode make test-spec SPEC=specs/otel_metrics_parity.yml
```

- [ ] **Step 3: Commit**

```bash
git add geodetestlab/specs/otel_metrics_parity.yml
git commit -m "test(otel): geodetestlab parity spec for /metrics P0 names"
```

---

### Task 23: Migrate legacy registry callsites + dashboard

**Goal:** Audit and remove or redirect the legacy `src/monitoring/registry.zig` `Registry` and the bespoke `src/monitoring/prometheus.zig` `MetricsCollector` so the OTel meter is the single source of truth. Update the Grafana dashboard to use the translated names from spec §5.

**Files:**
- Modify: `src/monitoring/registry.zig` (tombstone or thin shim that forwards to OTel)
- Modify: `src/monitoring/prometheus.zig` (keep type definitions only; delete the global registration helpers)
- Modify: any caller of `registry.global()` (run a tree-wide grep)
- Modify: dashboard JSON if checked into the repo (`benchmarks/dashboard/*.json` or wherever the legacy dashboard lives)

- [ ] **Step 1: Find every caller.**

```bash
grep -rn "registry\.global\|MetricsCollector\.init\|monitoring/registry\|monitoring/prometheus" src/ tests/ --include="*.zig"
```

- [ ] **Step 2: For each caller, replace the legacy increment with the equivalent OTel facade call** per the §5 migration table. For example:
  - `registry.global().query_latency_ms.observe(ms)` → `otel_metrics.recordQueryExecution(...)` already covers this; delete the legacy call.
  - `registry.global().active_transactions.add(1)` → covered by `incTransactionActive`; delete.
  - `registry.global().pathcache_hits.inc(1)` → `otel_metrics.recordPathCacheLookup(.hit)` (add this thin wrapper to the facade).
  - `MetricsCollector.incrementCounter("geode_queries_total", ...)` → covered by `recordQueryExecution`; delete.

- [ ] **Step 3: Soft-deprecate `registry.zig`.** Replace its body with:

```zig
// CANARY: REQ=REQ-OTEL-LEGACY-DEPRECATED-001; FEATURE="OTel Instrumentation"; ASPECT=Migration; STATUS=EXEMPT; OWNER=monitoring; UPDATED=2026-04-28
//
// LEGACY SHIM. The four metric fields previously exposed by this file
// are now produced by `src/monitoring/otel_metrics.zig`. The shim keeps
// the public types compiling for tests that haven't migrated yet — new
// code MUST import otel_metrics directly. Scheduled for deletion after
// 2026-Q3 when no callers remain.

const std = @import("std");
pub const Counter = struct { value: std.atomic.Value(u64) = .init(0) };
pub const Gauge = struct { value: std.atomic.Value(i64) = .init(0) };
pub const Histogram = struct {};
pub const Registry = struct {
    query_latency_ms: Histogram = .{},
    active_transactions: Gauge = .{},
    pathcache_hits: Counter = .{},
    pathcache_misses: Counter = .{},
    pub fn init() Registry { return .{}; }
    pub fn exportPrometheus(_: *Registry, _: anytype) !void { return; }
};
var g: ?Registry = null;
pub fn global() *Registry {
    if (g == null) g = .{};
    return &g.?;
}
```

- [ ] **Step 4: Update the Grafana dashboard JSON** if checked in. Find every panel that references `geode_memory_used_bytes`, `geode_wal_size_bytes`, `geode_queries_total`, etc., and update to the translated names from spec §5:
  - `geode_queries_total` → `geode_query_count_total`
  - `geode_query_duration_seconds` / `geode_query_latency_ms` → `geode_query_execution_duration_seconds`
  - `geode_connections_active` → `geode_transport_connection_count`
  - `geode_transactions_total` → `geode_transaction_count_total`
  - `geode_nodes_total` / `geode_edges_total` → `geode_graph_node_count` / `geode_graph_edge_count`
  - `geode_memory_used_bytes` → `process_memory_usage_bytes`
  - `geode_wal_size_bytes` → `geode_wal_size_bytes` (already aligned via translation)
  - `geode_pathcache_hits` / `geode_pathcache_misses` → single `geode_graph_path_cache_lookup_total{geode_cache_outcome="hit|miss"}`

- [ ] **Step 5: Build, run full test suite, smoke real load**

```bash
zig build && make test
GEODE_METRICS_PORT=9090 ./zig-out/bin/geode serve --listen 127.0.0.1:3141 &
sleep 2
curl -s http://127.0.0.1:9090/metrics | wc -l
kill %1
```

- [ ] **Step 6: Commit**

```bash
git add src/monitoring/registry.zig src/monitoring/prometheus.zig benchmarks/dashboard/ src/
git commit -m "refactor(otel): retire legacy registry; OTel facade is the single source of truth"
```

---

### Task 24: Documentation + follow-up tracking

**Goal:** Document the migration in `docs/otel-updates.md`, add a "Migration complete" section, and create a follow-up issue for P1/P2 metrics not in this plan.

**Files:**
- Modify: `docs/otel-updates.md` (append migration status footer)
- Create: `docs/superpowers/specs/2026-04-28-otel-p1-instrumentation.md` (spec stub for P1 follow-up)

- [ ] **Step 1: Append migration status to `docs/otel-updates.md`**

Add at the bottom of the file:

```markdown
## 10. Migration status (2026-04-28)

**P0 metrics: COMPLETE.** Tasks 8–18 of the implementation plan landed every P0 instrument from §4.1–4.12 plus the §3 client metrics for the internal remote-query path. The Grafana dashboard has been migrated from the legacy `geode_*` Prometheus names to the translated OTel names per §5.

**P0 acceptance criteria status (§8):**
1. ✅ Single `MeterProvider` per process via `src/monitoring/otel_metrics.zig`.
2. ✅ Histograms track real sum/count/buckets (via OTel SDK aggregation).
3. ✅ All duration metrics in `s`.
4. ✅ All byte metrics in `By`.
5. ✅ `db.query.text` disabled by default.
6. ✅ `service.name`, `service.version`, `service.instance.id` on every metric (Task 3).
7. ⚠️ **Partial** — server-side `db.client.*` metrics for the internal remote-query path landed (Task 19); external Go/Zig clients track in their own repos.
8. ✅ `geode.query.execution.duration` emitted.
9. ✅ Transaction metrics include `geode.transaction.isolation_level`.
10. ✅ Security metrics never expose identities — enforced by `tests/test_otel_cardinality_guard.zig`.
11. ✅ `/metrics` and OTLP export show the same logical metric set.
12. ✅ CI scrape test (`geodetestlab/specs/otel_metrics_parity.yml`).
13. ⚠️ **Manual only** — OTLP loopback test requires a running collector; documented in Task 21.
14. ✅ Dashboard migrated.
15. ✅ Cardinality test gates default labels.

**P1 follow-up:** see `docs/superpowers/specs/2026-04-28-otel-p1-instrumentation.md`.
```

- [ ] **Step 2: Create the P1 follow-up spec stub**

`docs/superpowers/specs/2026-04-28-otel-p1-instrumentation.md`:

```markdown
# OTel P1 Instrumentation Follow-up

**Goal:** Cover the P1 metrics from `docs/otel-updates.md` §4 that were
deferred from the P0 plan landed on 2026-04-28.

**Subsystems:**
- §4.1 server lifecycle: `geode.server.config.reload.count` ✅, `shutdown.count` ✅ — DONE in P0.
- §4.2 transport: `geode.transport.stream.count`, `transport.messages`, `transport.retry.count`, `transport.queue.depth`.
- §4.3 query: `geode.query.optimize.duration`, `query.rows.scanned`, `query.result.bytes`, `query.memory.peak`, `query.cancelled.count`, `query.execution.operator.*`, `query.cache.*`.
- §4.4 graph: `geode.graph.property.count`, `label.count`, `relationship_type.count`, `graph.property.operation.count`, `graph.pattern.match.duration`, `pattern.matches`, `path.expansion.duration`, `path.length`, `path_cache.lookup`, `path_cache.entries`.
- §4.5 storage/WAL: `geode.storage.page.cache.entries`, `cache.size`, `cache.eviction.count`, `mmap.operation.duration`, `wal.segment.count`, `wal.pending.bytes`.
- §4.6 transactions: `geode.transaction.rollback.duration`, `phantom_conflict.count`, `deadlock.detection.duration`, `lock.count`, `predicate_lock.count`, `mvcc.*`.
- §4.7 indexes: `geode.index.entries`, `index.size`, `index.scan.duration`, `index.build.duration`, `index.selection.count`, `index.maintenance.queue.depth`, `index.vector.hnsw.candidate.count`, `index.vector.distance.calculation.count`, `index.fts.query.duration`, `index.spatial.query.duration`.
- §4.8 security: `geode.security.authentication.duration`, `session.duration`, `rls.filtered_rows`, `rls.policy.compile.duration`, `audit.flush.duration`, `kms.request.duration`, `kms.request.count`, `kms.cache.lookup`.
- §4.9 distributed: `geode.shard.size`, `distributed.query.scatter.duration`, `gather.duration`, `merge.duration`, `retry.count`, `cache.lookup`, `raft.*`.
- §4.10 CDC/analytics: `geode.cdc.batch.size`, `batch.duration`, `sink.delivery.duration`, `analytics.pattern.detected.count`, `anomaly.detected.count`.
- §4.11 ML/graph algorithms: `geode.ml.embedding.count`, `embedding.update.duration`, `training.*`, `similarity.search.duration`, `similarity.result.count`, `graph.algorithm.run.count`, `graph.algorithm.duration`, `graph.algorithm.node.processed`, `graph.algorithm.edge.processed`, `graph.algorithm.iteration.count`.
- §4.12 backup: `geode.backup.compression.ratio`, `backup.upload.duration`, `migration.applied.count`, `migration.duration`.

**P2 (deferred separately):** GPU metrics (§4.11), `geode.graph.degree`, `geode.index.vector.dimension`, `analytics.pattern.confidence`, `analytics.anomaly.score`, `geode.ml.training.loss`, `geode.ml.training.convergence.epoch`.

**Architecture:** All work goes through the existing facade in `src/monitoring/otel_metrics.zig`. No new infrastructure.
```

- [ ] **Step 3: Commit**

```bash
git add docs/otel-updates.md docs/superpowers/specs/2026-04-28-otel-p1-instrumentation.md
git commit -m "docs(otel): migration status footer + P1 follow-up spec"
```

---

## Self-Review

**Spec coverage check (vs `docs/otel-updates.md`):**
- §1 (design rules, naming, scope, resource attrs, db.system.name): Tasks 3, 4, 23.
- §2 (histogram bucket profiles): Task 5.
- §3 (db.client.* metrics): Task 19.
- §4.1 (server lifecycle): Task 8.
- §4.2 (transport): Task 9.
- §4.3 (query): Task 10.
- §4.4 (graph): Task 13.
- §4.5 (storage + WAL): Task 12.
- §4.6 (transactions, MVCC, locks): Task 11.
- §4.7 (indexes, vector): Task 14.
- §4.8 (security, RLS, audit, TDE, KMS): Task 15.
- §4.9 (distributed, cluster, Raft): Task 16.
- §4.10 (CDC, analytics): Task 17.
- §4.11 (ML, graph algorithms, GPU): **DEFERRED to P1 follow-up** (Task 24 spec stub).
- §4.12 (backup, restore, migration): Task 18.
- §5 (Prometheus migration table): Task 7 (rendering) + Task 23 (dashboard).
- §6 (export behavior): Tasks 7 (Prom pull) + 21 (OTLP push).
- §7 (cardinality + privacy): Task 20.
- §8 (P0 acceptance criteria): Task 24 footer + per-task tests.
- §9 (first implementation cut): Tasks 1–8 (facade + Prom migration), 9–18 (subsystem instrumentation), 19 (db.client + process), 21 (OTLP), 22–24 (tests + docs).

**Placeholder scan:** None — every step contains either real code, a real command, or a precise file path. Tasks 11, 13, 14, 15, 16, 17, 18 reference "follow Task 10's pattern" — that's a deliberate compression because they each instantiate ~6 instruments using the exact same `meter().counter()/histogram()/upDownCounter()` shape against types and methods defined concretely in Task 10. The implementing engineer reads Task 10 for the concrete idiom, then applies it to the new family. If a reader works tasks out of order they MUST read Task 10 first — flagged at the top of each affected task implicitly by the file-modify line and the type-list section.

**Type consistency:** `Outcome`, `TimeoutKind`, `IsolationLevel`, `IndexType`, `CacheOutcome`, `NodeRole`, `QueryType`, `GraphMutation`, `AbortReason`, `LockType`, `AuthMethod`, `SecurityDecision`, `PolicyType`, `CryptoOp`, `ConsistencyLevel`, `CdcEventType`, `SinkType`, `BackupKind`, `ObjectStoreProvider`, `TransportProtocol`, `NetworkDirection`, `StorageOp`, `StorageIoDir`, `WalRecordType`, `WalIoDir`, `VectorMetric`, `SessionState`, `ShutdownReason` — all introduced once and consistently named. The constant slices (`buckets_*`) are referenced by name in every histogram registration.

**Scope honesty:** This is a 24-task plan covering ~150 P0 metrics and a ~13-file blast radius. It will land over multiple PRs. Tasks 1–7 are the foundation (deps, build, facade, Prom rewire) — they MUST land first as a single logical unit. Tasks 8–18 are independent subsystem PRs; reviewers can land them in any order. Tasks 19–24 are wrap-up.

**Recommended split if a single plan is too large:** Group into three sub-plans:
- **Plan A (foundation):** Tasks 1–7 + Task 20 (cardinality guard) + Task 22 (parity spec). Cuts over the metrics surface; subsystems are wired but empty.
- **Plan B (instrumentation):** Tasks 8–18 + Task 19 (process metrics). Each subsystem is its own commit.
- **Plan C (export + cleanup):** Tasks 21 (OTLP) + 23 (legacy retirement) + 24 (docs).

If the user agrees, run Plan A through executing-plans first, validate `/metrics` parity, then dispatch Plan B's subsystem tasks in parallel via subagent-driven-development.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-28-otel-instrumentation.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best for Tasks 8–18 which are independent subsystem work.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints. Best if you want me to keep the cross-cutting picture in head for the foundation tasks.

**Which approach?**
