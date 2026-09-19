//! Bridge between the OTel `MeterProvider` and the existing `/metrics`
//! HTTP listener. When the global provider is initialised (see
//! `otel_metrics.init` in src/server/main.zig), `render` produces a
//! Prometheus exposition payload from the OTel snapshot via the
//! upstream `otel.exporters.prometheus.Prometheus.render` call. The
//! payload is heap-allocated; callers MUST free it with the same
//! allocator. When the provider is not initialised, callers should
//! fall back to the legacy `prometheus.MetricsCollector.exportMetrics`
//! path.

// CANARY: REQ=REQ-OTEL-PROMETHEUS-RESPONDER-001; FEATURE="OTel Instrumentation"; ASPECT=PrometheusBridge; STATUS=TESTED; TEST=tests/test_otel_prometheus_parity.zig; OWNER=monitoring; UPDATED=2026-04-28

const std = @import("std");
const otel = @import("otel");
const otel_metrics = @import("otel_metrics");

/// Render the current OTel metric snapshot in Prometheus exposition
/// format. Caller owns the returned slice and must free it with the
/// same allocator.
///
/// Returns `error.MeterProviderNotInitialised` when the global
/// MeterProvider is not initialised.
///
/// SONNY-1807: the upstream `otel.exporters.prometheus.Prometheus.render`
/// emits metric names verbatim (dots sanitised to underscores) with NO
/// Prometheus/OpenMetrics naming conventions — monotonic counters lack the
/// `_total` suffix and no metric carries a base-unit suffix (`_seconds`,
/// `_bytes`, ...). Scrapers and dashboards then need manual renaming. The
/// proper fix lives in the otel dep exporter, but bumping otel is cascade-
/// blocked, so we post-process the rendered payload engine-locally here (in
/// `render`, so every responder path — including `renderInto` — benefits).
pub fn render(allocator: std.mem.Allocator) ![]u8 {
    const provider = otel_metrics.getProvider() orelse return error.MeterProviderNotInitialised;
    var prom = otel.exporters.prometheus.Prometheus.init(allocator, provider);
    const raw = try prom.render();
    defer allocator.free(raw);

    // The rendered exposition format drops the declared OTel unit and does
    // not encode monotonicity beyond the `# TYPE` line, so recover both from
    // an authoritative snapshot and drive a text post-pass off it.
    const snapshot = try otel.sdk.metrics.collect(provider, allocator);
    defer otel.sdk.metrics.freeSnapshot(allocator, snapshot);

    return try applyNamingConventions(allocator, raw, snapshot);
}

// -------------------------------------------------------------------------
// Prometheus/OpenMetrics naming-convention post-processor (SONNY-1807)
// -------------------------------------------------------------------------

const MetricData = otel.sdk.exporter.MetricData;

/// A single `original -> conventional` metric-name rename. Both slices are
/// heap-allocated and freed by `applyNamingConventions`.
const Rename = struct {
    from: []u8,
    to: []u8,
};

/// Post-process the upstream exposition payload so metric names follow
/// Prometheus/OpenMetrics conventions. The payload is rewritten line-by-line;
/// `# HELP`/`# TYPE`/`# UNIT` header lines and every sample line (including the
/// histogram `_count`/`_sum`/`_bucket` family) for a renamed metric are
/// updated in lockstep, while label sets, values and any non-metric line pass
/// through untouched. Caller owns the returned slice.
fn applyNamingConventions(
    allocator: std.mem.Allocator,
    raw: []const u8,
    snapshot: []const MetricData,
) ![]u8 {
    // Build the rename table from the snapshot. Keyed by the *sanitised* name,
    // exactly as the exporter writes it into the payload.
    var renames: std.ArrayListUnmanaged(Rename) = .empty;
    defer {
        for (renames.items) |r| {
            allocator.free(r.from);
            allocator.free(r.to);
        }
        renames.deinit(allocator);
    }

    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer map.deinit(allocator);

    for (snapshot) |m| {
        const sanitized = try sanitizeName(allocator, m.name);
        const conventional = try conventionalName(allocator, sanitized, m.kind, m.unit);
        if (std.mem.eql(u8, sanitized, conventional)) {
            allocator.free(sanitized);
            allocator.free(conventional);
            continue;
        }
        try renames.append(allocator, .{ .from = sanitized, .to = conventional });
        // Last writer wins on the (rare) sanitised-name collision; harmless
        // because colliding metrics resolve to the same conventional name.
        try map.put(allocator, sanitized, conventional);
    }

    if (map.count() == 0) return allocator.dupe(u8, raw);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, raw.len);

    // splitScalar is the exact inverse of joining with '\n', so reconstructing
    // segment-by-segment preserves the payload's exact newline structure
    // (including any trailing newline / empty final segment).
    var it = std.mem.splitScalar(u8, raw, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        try rewriteLine(allocator, &out, line, map);
    }

    return out.toOwnedSlice(allocator);
}

/// Rewrite one exposition line into `out`, renaming the metric name where it
/// appears. Header lines (`# HELP`/`# TYPE`/`# UNIT`) carry the name as their
/// second token; sample lines lead with it (optionally followed by a histogram
/// `_count`/`_sum`/`_bucket` suffix, then a label set or the value).
fn rewriteLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    line: []const u8,
    map: std.StringHashMapUnmanaged([]const u8),
) !void {
    const header_prefixes = [_][]const u8{ "# HELP ", "# TYPE ", "# UNIT " };
    for (header_prefixes) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) {
            const after = line[prefix.len..];
            const sp = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
            const name = after[0..sp];
            if (map.get(name)) |to| {
                try out.appendSlice(allocator, prefix);
                try out.appendSlice(allocator, to);
                try out.appendSlice(allocator, after[sp..]);
                return;
            }
            try out.appendSlice(allocator, line);
            return;
        }
    }

    // Any other comment line, or a blank line: pass through verbatim.
    if (line.len == 0 or line[0] == '#') {
        try out.appendSlice(allocator, line);
        return;
    }

    // Sample line. The leading token is the metric name (plus, for histograms,
    // a `_count`/`_sum`/`_bucket` suffix), terminated by '{' (labels) or ' '.
    const tok_end = blk: {
        for (line, 0..) |c, i| {
            if (c == '{' or c == ' ') break :blk i;
        }
        break :blk line.len;
    };
    const token = line[0..tok_end];
    const rest = line[tok_end..];

    // Direct hit: counter / gauge / plain sample.
    if (map.get(token)) |to| {
        try out.appendSlice(allocator, to);
        try out.appendSlice(allocator, rest);
        return;
    }

    // Histogram family: strip the exporter's per-point suffix, rename the base,
    // then re-attach the suffix so `<base>_seconds_bucket{...}` stays intact.
    const hist_suffixes = [_][]const u8{ "_bucket", "_count", "_sum" };
    for (hist_suffixes) |suffix| {
        if (std.mem.endsWith(u8, token, suffix)) {
            const base = token[0 .. token.len - suffix.len];
            if (map.get(base)) |to| {
                try out.appendSlice(allocator, to);
                try out.appendSlice(allocator, suffix);
                try out.appendSlice(allocator, rest);
                return;
            }
        }
    }

    try out.appendSlice(allocator, line);
}

/// Sanitise an OTel metric name into a Prometheus metric name, byte-for-byte
/// identical to the upstream exporter's `sanitize` (any character outside
/// `[a-zA-Z0-9_]` becomes `_`). Caller owns the returned slice.
fn sanitizeName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        out[i] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => c,
            else => '_',
        };
    }
    return out;
}

/// Map an OTel unit to its Prometheus base-unit name suffix, or `null` when the
/// convention does not apply. Conservative by design: only real base units are
/// mapped. Annotation-only units (`{query}`, `{event}`, ...) and dimensionless
/// units (`1`, `%`, ...) carry no numeric suffix.
fn unitSuffix(unit: []const u8) ?[]const u8 {
    if (unit.len == 0) return null;
    if (unit[0] == '{') return null; // annotation-only, e.g. {query}
    if (std.mem.eql(u8, unit, "s")) return "seconds";
    if (std.mem.eql(u8, unit, "By")) return "bytes";
    if (std.mem.eql(u8, unit, "bytes")) return "bytes";
    return null;
}

/// True when `name` already ends in `_<suffix>` (the suffix as a trailing
/// underscore-delimited token).
fn endsWithToken(name: []const u8, suffix: []const u8) bool {
    if (name.len < suffix.len + 1) return false;
    if (name[name.len - suffix.len - 1] != '_') return false;
    return std.mem.eql(u8, name[name.len - suffix.len ..], suffix);
}

/// Compute the Prometheus/OpenMetrics-conventional name for a metric from its
/// sanitised name, instrument kind, and declared unit:
///   * monotonic counters get a trailing `_total`;
///   * metrics with a real base unit get the unit suffix (`_seconds`, `_bytes`);
///   * for counters the order is `<base>_<unit>_total` (`_total` LAST).
/// Idempotent: a name already carrying the correct suffixes is unchanged, so
/// re-running the post-processor never double-appends. Caller owns the slice.
fn conventionalName(
    allocator: std.mem.Allocator,
    sanitized: []const u8,
    kind: otel.api.metrics.InstrumentKind,
    unit: []const u8,
) ![]u8 {
    const is_counter = kind == .counter or kind == .observable_counter;

    // Normalise: peel a trailing `_total` off counters so we can reason about
    // the core name and re-attach `_total` LAST.
    var core = sanitized;
    if (is_counter and endsWithToken(core, "total")) {
        core = core[0 .. core.len - "total".len - 1]; // drop "_total"
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, core);

    // Append the base-unit suffix unless the core already ends in it.
    if (unitSuffix(unit)) |us| {
        if (!endsWithToken(core, us)) {
            try buf.append(allocator, '_');
            try buf.appendSlice(allocator, us);
        }
    }

    // Re-attach `_total` last for monotonic counters.
    if (is_counter) {
        try buf.appendSlice(allocator, "_total");
    }

    return buf.toOwnedSlice(allocator);
}

/// Append the OTel snapshot to an existing writer. Convenience for the
/// HTTP path that already owns a `std.Io.Writer.Allocating`. The
/// snapshot is materialised once via `render`, written to `writer`, and
/// the intermediate buffer is freed before return.
pub fn renderInto(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    const body = try render(allocator);
    defer allocator.free(body);
    try writer.writeAll(body);
}

/// Returns true when the OTel MeterProvider is initialised so callers
/// can decide whether to fall back to the legacy collector path.
pub fn isAvailable() bool {
    return otel_metrics.getProvider() != null;
}
