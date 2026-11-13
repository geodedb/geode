// CANARY: REQ=REQ-OTEL-LEGACY-DEPRECATED-002; FEATURE="OTel Instrumentation"; ASPECT=Migration; STATUS=EXEMPT; TEST=tests/test_otel_prometheus_parity.zig; OWNER=monitoring; UPDATED=2026-04-28
//
// LEGACY FALLBACK — DEPRECATED. PrometheusExporter and MetricsCollector
// are kept as a fallback path for the /metrics endpoint when the OTel
// MeterProvider is not yet initialised (see src/monitoring/metrics_server.zig
// serveMetrics for the routing logic added in Task 7). New instrumentation
// MUST go through `src/monitoring/otel_metrics.zig`. Scheduled for deletion
// after one full release cycle of OTel-only operation. See
// docs/otel-updates.md §5 for the migration table.

const std = @import("std");
const Allocator = std.mem.Allocator;

// Prometheus metrics exporter
pub const PrometheusExporter = struct {
    allocator: Allocator,
    metrics: std.StringHashMap(Metric),
    labels: std.StringHashMap([]const u8),

    pub const MetricType = enum {
        counter,
        gauge,
        histogram,
        summary,
    };

    pub const Metric = struct {
        name: []const u8,
        help: []const u8,
        type: MetricType,
        value: MetricValue,
        labels: ?std.StringHashMap([]const u8),
        timestamp: ?i64,
    };

    pub const MetricValue = union(enum) {
        counter: u64,
        gauge: f64,
        histogram: Histogram,
        summary: Summary,
    };

    pub const Histogram = struct {
        buckets: []Bucket,
        sum: f64,
        count: u64,
    };

    pub const Bucket = struct {
        upper_bound: f64,
        count: u64,
    };

    pub const Summary = struct {
        quantiles: []Quantile,
        sum: f64,
        count: u64,
    };

    pub const Quantile = struct {
        quantile: f64,
        value: f64,
    };

    pub fn init(allocator: Allocator) PrometheusExporter {
        return .{
            .allocator = allocator,
            .metrics = std.StringHashMap(Metric).init(allocator),
            .labels = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *PrometheusExporter) void {
        var it = self.metrics.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.labels) |*labels| {
                labels.deinit();
            }
        }
        self.metrics.deinit();
        self.labels.deinit();
    }

    // Register a new metric
    pub fn registerMetric(
        self: *PrometheusExporter,
        name: []const u8,
        help: []const u8,
        metric_type: MetricType,
    ) !void {
        const metric = Metric{
            .name = try self.allocator.dupe(u8, name),
            .help = try self.allocator.dupe(u8, help),
            .type = metric_type,
            .value = switch (metric_type) {
                .counter => .{ .counter = 0 },
                .gauge => .{ .gauge = 0 },
                .histogram => .{ .histogram = .{
                    .buckets = &[_]Bucket{},
                    .sum = 0,
                    .count = 0,
                } },
                .summary => .{ .summary = .{
                    .quantiles = &[_]Quantile{},
                    .sum = 0,
                    .count = 0,
                } },
            },
            .labels = null,
            .timestamp = null,
        };

        try self.metrics.put(name, metric);
    }

    // Increment counter
    pub fn incrementCounter(self: *PrometheusExporter, name: []const u8, value: u64) !void {
        if (self.metrics.getPtr(name)) |metric| {
            switch (metric.value) {
                .counter => |*c| c.* += value,
                else => return error.MetricKindMismatch,
            }
        }
    }

    // Set gauge value
    pub fn setGauge(self: *PrometheusExporter, name: []const u8, value: f64) !void {
        if (self.metrics.getPtr(name)) |metric| {
            switch (metric.value) {
                .gauge => |*g| g.* = value,
                else => return error.MetricKindMismatch,
            }
        }
    }

    // Observe histogram value
    pub fn observeHistogram(self: *PrometheusExporter, name: []const u8, value: f64) !void {
        if (self.metrics.getPtr(name)) |metric| {
            switch (metric.value) {
                .histogram => |*h| {
                    h.sum += value;
                    h.count += 1;

                    // Update bucket counts
                    for (h.buckets) |*bucket| {
                        if (value <= bucket.upper_bound) {
                            bucket.count += 1;
                        }
                    }
                },
                else => return error.MetricKindMismatch,
            }
        }
    }

    // Export metrics in Prometheus format
    pub fn exportMetrics(self: *PrometheusExporter, writer: anytype) !void {
        var it = self.metrics.iterator();
        while (it.next()) |entry| {
            const metric = entry.value_ptr.*;

            // Write HELP line
            try writer.print("# HELP {s} {s}\n", .{ metric.name, metric.help });

            // Write TYPE line
            try writer.print("# TYPE {s} {s}\n", .{ metric.name, @tagName(metric.type) });

            // Write metric value(s)
            switch (metric.value) {
                .counter => |c| {
                    try writer.print("{s} {}", .{ metric.name, c });
                },
                .gauge => |g| {
                    try writer.print("{s} {}", .{ metric.name, g });
                },
                .histogram => |h| {
                    // Write bucket values
                    for (h.buckets) |bucket| {
                        try writer.print("{s}_bucket{{le=\"{}\"}} {}", .{
                            metric.name,
                            bucket.upper_bound,
                            bucket.count,
                        });
                        if (metric.timestamp) |ts| {
                            try writer.print(" {}", .{ts});
                        }
                        try writer.writeByte('\n');
                    }

                    // Write +Inf bucket
                    try writer.print("{s}_bucket{{le=\"+Inf\"}} {}", .{
                        metric.name,
                        h.count,
                    });
                    if (metric.timestamp) |ts| {
                        try writer.print(" {}", .{ts});
                    }
                    try writer.writeByte('\n');

                    // Write sum and count
                    try writer.print("{s}_sum {}", .{ metric.name, h.sum });
                    if (metric.timestamp) |ts| {
                        try writer.print(" {}", .{ts});
                    }
                    try writer.writeByte('\n');

                    try writer.print("{s}_count {}", .{ metric.name, h.count });
                },
                .summary => |s| {
                    // Write quantile values
                    for (s.quantiles) |quantile| {
                        try writer.print("{s}_quantile{{quantile=\"{}\"}} {}", .{
                            metric.name,
                            quantile.quantile,
                            quantile.value,
                        });
                        if (metric.timestamp) |ts| {
                            try writer.print(" {}", .{ts});
                        }
                        try writer.writeByte('\n');
                    }

                    // Write sum and count
                    try writer.print("{s}_sum {}", .{ metric.name, s.sum });
                    if (metric.timestamp) |ts| {
                        try writer.print(" {}", .{ts});
                    }
                    try writer.writeByte('\n');

                    try writer.print("{s}_count {}", .{ metric.name, s.count });
                },
            }

            if (metric.timestamp) |ts| {
                try writer.print(" {}", .{ts});
            }
            try writer.writeByte('\n');
        }
    }
};

// Default metrics collector
pub const MetricsCollector = struct {
    allocator: Allocator,
    exporter: PrometheusExporter,

    // Standard metrics
    queries_total: u64,
    queries_failed: u64,
    query_duration_seconds: []f64,
    connections_active: u64,
    connections_total: u64,
    transactions_total: u64,
    transactions_failed: u64,
    nodes_total: u64,
    edges_total: u64,
    memory_bytes: u64,

    pub fn init(allocator: Allocator) !MetricsCollector {
        var collector = MetricsCollector{
            .allocator = allocator,
            .exporter = PrometheusExporter.init(allocator),
            .queries_total = 0,
            .queries_failed = 0,
            .query_duration_seconds = &[_]f64{},
            .connections_active = 0,
            .connections_total = 0,
            .transactions_total = 0,
            .transactions_failed = 0,
            .nodes_total = 0,
            .edges_total = 0,
            .memory_bytes = 0,
        };

        // Register standard metrics
        try collector.exporter.registerMetric(
            "geode_queries_total",
            "Total number of queries executed",
            .counter,
        );

        try collector.exporter.registerMetric(
            "geode_queries_failed_total",
            "Total number of failed queries",
            .counter,
        );

        try collector.exporter.registerMetric(
            "geode_query_duration_seconds",
            "Query execution duration in seconds",
            .histogram,
        );

        try collector.exporter.registerMetric(
            "geode_connections_active",
            "Number of active connections",
            .gauge,
        );

        try collector.exporter.registerMetric(
            "geode_connections_total",
            "Total number of connections",
            .counter,
        );

        try collector.exporter.registerMetric(
            "geode_transactions_total",
            "Total number of transactions",
            .counter,
        );

        try collector.exporter.registerMetric(
            "geode_transactions_failed_total",
            "Total number of failed transactions",
            .counter,
        );

        try collector.exporter.registerMetric(
            "geode_nodes_total",
            "Total number of nodes in the graph",
            .gauge,
        );

        try collector.exporter.registerMetric(
            "geode_edges_total",
            "Total number of edges in the graph",
            .gauge,
        );

        try collector.exporter.registerMetric(
            "geode_memory_bytes",
            "Memory usage in bytes",
            .gauge,
        );

        return collector;
    }

    pub fn deinit(self: *MetricsCollector) void {
        self.exporter.deinit();
    }

    pub fn recordQuery(self: *MetricsCollector, duration_seconds: f64, success: bool) !void {
        self.queries_total += 1;
        try self.exporter.incrementCounter("geode_queries_total", 1);

        if (!success) {
            self.queries_failed += 1;
            try self.exporter.incrementCounter("geode_queries_failed_total", 1);
        }

        try self.exporter.observeHistogram("geode_query_duration_seconds", duration_seconds);
    }

    pub fn updateConnections(self: *MetricsCollector, active: u64, total: u64) !void {
        self.connections_active = active;
        self.connections_total = total;

        try self.exporter.setGauge("geode_connections_active", @as(f64, @floatFromInt(active)));
        try self.exporter.incrementCounter("geode_connections_total", total - self.connections_total);
    }

    pub fn recordTransaction(self: *MetricsCollector, success: bool) !void {
        self.transactions_total += 1;
        try self.exporter.incrementCounter("geode_transactions_total", 1);

        if (!success) {
            self.transactions_failed += 1;
            try self.exporter.incrementCounter("geode_transactions_failed_total", 1);
        }
    }

    pub fn updateGraphStats(self: *MetricsCollector, nodes: u64, edges: u64) !void {
        self.nodes_total = nodes;
        self.edges_total = edges;

        try self.exporter.setGauge("geode_nodes_total", @as(f64, @floatFromInt(nodes)));
        try self.exporter.setGauge("geode_edges_total", @as(f64, @floatFromInt(edges)));
    }

    pub fn updateMemory(self: *MetricsCollector, bytes: u64) !void {
        self.memory_bytes = bytes;
        try self.exporter.setGauge("geode_memory_bytes", @as(f64, @floatFromInt(bytes)));
    }

    pub fn exportMetrics(self: *MetricsCollector, writer: anytype) !void {
        try self.exporter.exportMetrics(writer);
    }
};
