// CANARY: REQ=REQ-ANALYTICS-001; FEATURE="Real-time Analytics"; ASPECT=StreamingIntegration; STATUS=TESTED; TEST=TestCANARY_ANALYTICS_001_StreamingIntegration; OWNER=analytics; UPDATED=2025-10-05
// CANARY: REQ=REQ-ANALYTICS-002; FEATURE="Real-time Analytics"; ASPECT=MLIntegration; STATUS=TESTED; TEST=TestCANARY_ANALYTICS_002_MLIntegration; OWNER=analytics; UPDATED=2025-10-05
// CANARY: REQ=REQ-ANALYTICS-003; FEATURE="Real-time Analytics"; ASPECT=EventProcessing; STATUS=TESTED; TEST=TestCANARY_ANALYTICS_003_EventProcessing; OWNER=analytics; UPDATED=2025-10-05

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;

// Import core Geode modules
const geode = @import("../lib.zig");
const ml_embeddings = @import("../ml/graph_embeddings.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Analytics; STATUS=EXEMPT; OWNER=analytics; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("analytics");
const Attr = logging.Attr;

/// Types of real-time analytics events
pub const AnalyticsEventType = enum {
    node_creation,
    node_update,
    node_deletion,
    edge_creation,
    edge_update,
    edge_deletion,
    graph_query,
    similarity_search,
    embedding_update,
    pattern_detection,
    anomaly_detection,
    trend_analysis,
};

/// Real-time analytics event structure
pub const AnalyticsEvent = struct {
    id: u64,
    event_type: AnalyticsEventType,
    timestamp: i64,
    node_id: ?u64 = null,
    edge_id: ?u64 = null,
    query_id: ?u64 = null,
    properties: AutoHashMap([]const u8, AnalyticsValue),
    metadata: AnalyticsMetadata,

    pub fn init(allocator: Allocator, event_type: AnalyticsEventType) AnalyticsEvent {
        return AnalyticsEvent{
            .id = generateEventId(),
            .event_type = event_type,
            .timestamp = std.time.milliTimestamp(),
            .properties = AutoHashMap([]const u8, AnalyticsValue).init(allocator),
            .metadata = AnalyticsMetadata.init(allocator),
        };
    }

    pub fn deinit(self: *AnalyticsEvent) void {
        self.properties.deinit();
        self.metadata.deinit();
    }

    pub fn setProperty(self: *AnalyticsEvent, key: []const u8, value: AnalyticsValue) !void {
        try self.properties.put(key, value);
    }

    pub fn getProperty(self: *AnalyticsEvent, key: []const u8) ?AnalyticsValue {
        return self.properties.get(key);
    }
};

/// Analytics value types for flexible event data
pub const AnalyticsValue = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    vector: []f32,
    array: ArrayList(AnalyticsValue),
    null: void,
};

/// Metadata for analytics events
pub const AnalyticsMetadata = struct {
    source: []const u8 = "geode",
    version: []const u8 = "0.18.0",
    processing_time: ?i64 = null,
    correlation_id: ?u64 = null,
    session_id: ?u64 = null,
    user_id: ?u64 = null,
    tags: ArrayList([]const u8),

    pub fn init(allocator: Allocator) AnalyticsMetadata {
        return AnalyticsMetadata{
            .tags = ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *AnalyticsMetadata) void {
        self.tags.deinit();
    }

    pub fn addTag(self: *AnalyticsMetadata, tag: []const u8) !void {
        try self.tags.append(tag);
    }
};

/// Configuration for real-time analytics processing
pub const AnalyticsConfig = struct {
    enable_ml_integration: bool = true,
    enable_pattern_detection: bool = true,
    enable_anomaly_detection: bool = true,
    enable_trend_analysis: bool = true,
    batch_size: u32 = 100,
    processing_interval_ms: u32 = 1000,
    max_event_queue_size: u32 = 10000,
    embedding_update_threshold: f32 = 0.1,
    similarity_threshold: f32 = 0.8,
    anomaly_detection_window: u32 = 3600, // 1 hour in seconds
    trend_analysis_window: u32 = 86400, // 24 hours in seconds
};

/// Real-time analytics processing statistics
pub const AnalyticsStatistics = struct {
    events_processed: u64 = 0,
    events_queued: u64 = 0,
    ml_updates_triggered: u64 = 0,
    patterns_detected: u64 = 0,
    anomalies_detected: u64 = 0,
    trends_identified: u64 = 0,
    processing_errors: u64 = 0,
    average_processing_time_ms: f64 = 0.0,
    last_update_timestamp: i64 = 0,

    pub fn updateProcessingTime(self: *AnalyticsStatistics, processing_time_ms: f64) void {
        self.average_processing_time_ms = (self.average_processing_time_ms * @as(f64, @floatFromInt(self.events_processed)) + processing_time_ms) / @as(f64, @floatFromInt(self.events_processed + 1));
    }
};

/// Pattern detection configuration and state
pub const PatternDetector = struct {
    allocator: Allocator,
    patterns: AutoHashMap(u64, DetectedPattern),
    config: PatternDetectionConfig,

    pub const PatternDetectionConfig = struct {
        min_pattern_frequency: u32 = 5,
        pattern_time_window_ms: i64 = 60000, // 1 minute
        max_patterns_tracked: u32 = 1000,
    };

    pub const DetectedPattern = struct {
        pattern_id: u64,
        pattern_type: PatternType,
        frequency: u32,
        first_occurrence: i64,
        last_occurrence: i64,
        confidence: f32,
        nodes_involved: ArrayList(u64),

        pub fn init(allocator: Allocator, pattern_type: PatternType) DetectedPattern {
            return DetectedPattern{
                .pattern_id = generatePatternId(),
                .pattern_type = pattern_type,
                .frequency = 1,
                .first_occurrence = std.time.milliTimestamp(),
                .last_occurrence = std.time.milliTimestamp(),
                .confidence = 0.5,
                .nodes_involved = ArrayList(u64).init(allocator),
            };
        }

        pub fn deinit(self: *DetectedPattern) void {
            self.nodes_involved.deinit();
        }
    };

    pub const PatternType = enum {
        frequent_connection,
        community_formation,
        hub_emergence,
        cascade_propagation,
        temporal_clustering,
        behavioral_similarity,
    };

    pub fn init(allocator: Allocator, config: PatternDetectionConfig) PatternDetector {
        return PatternDetector{
            .allocator = allocator,
            .patterns = AutoHashMap(u64, DetectedPattern).init(allocator),
            .config = config,
        };
    }

    pub fn deinit(self: *PatternDetector) void {
        var pattern_iterator = self.patterns.iterator();
        while (pattern_iterator.next()) |entry| {
            var pattern = entry.value_ptr;
            pattern.deinit();
        }
        self.patterns.deinit();
    }

    pub fn detectPattern(self: *PatternDetector, event: *const AnalyticsEvent) !?DetectedPattern {
        // Pattern detection logic based on event type and properties
        switch (event.event_type) {
            .edge_creation => {
                if (event.node_id) |source_node| {
                    return try self.detectConnectionPattern(source_node, event);
                }
            },
            .node_creation => {
                if (event.node_id) |node_id| {
                    return try self.detectCommunityFormation(node_id, event);
                }
            },
            else => return null,
        }
        return null;
    }

    fn detectConnectionPattern(self: *PatternDetector, node_id: u64, event: *const AnalyticsEvent) !?DetectedPattern {
        _ = self;
        _ = node_id;
        _ = event;
        // Implementation for detecting frequent connection patterns
        // This would analyze the graph structure and identify recurring connection patterns
        return null;
    }

    fn detectCommunityFormation(self: *PatternDetector, node_id: u64, event: *const AnalyticsEvent) !?DetectedPattern {
        _ = self;
        _ = node_id;
        _ = event;
        // Implementation for detecting community formation
        // This would use graph clustering algorithms to identify emerging communities
        return null;
    }
};

/// Anomaly detection system for real-time analytics
pub const AnomalyDetector = struct {
    allocator: Allocator,
    baseline_stats: AutoHashMap([]const u8, AnomalyBaseline),
    config: AnomalyDetectionConfig,
    recent_events: ArrayList(AnalyticsEvent),

    pub const AnomalyDetectionConfig = struct {
        statistical_threshold: f64 = 3.0, // Standard deviations
        minimum_baseline_samples: u32 = 100,
        baseline_update_frequency: u32 = 1000, // Events
        anomaly_cooldown_ms: i64 = 5000, // 5 seconds
    };

    pub const AnomalyBaseline = struct {
        mean: f64,
        variance: f64,
        sample_count: u32,
        last_updated: i64,
    };

    pub const AnomalyResult = struct {
        is_anomaly: bool,
        severity: AnomalySeverity,
        confidence: f32,
        description: []const u8,
        affected_entities: ArrayList(u64),

        pub const AnomalySeverity = enum {
            low,
            medium,
            high,
            critical,
        };

        pub fn init(allocator: Allocator) AnomalyResult {
            return AnomalyResult{
                .is_anomaly = false,
                .severity = .low,
                .confidence = 0.0,
                .description = "",
                .affected_entities = ArrayList(u64).init(allocator),
            };
        }

        pub fn deinit(self: *AnomalyResult) void {
            self.affected_entities.deinit();
        }
    };

    pub fn init(allocator: Allocator, config: AnomalyDetectionConfig) AnomalyDetector {
        return AnomalyDetector{
            .allocator = allocator,
            .baseline_stats = AutoHashMap([]const u8, AnomalyBaseline).init(allocator),
            .config = config,
            .recent_events = ArrayList(AnalyticsEvent).init(allocator),
        };
    }

    pub fn deinit(self: *AnomalyDetector) void {
        self.baseline_stats.deinit();
        for (self.recent_events.items) |*event| {
            event.deinit();
        }
        self.recent_events.deinit();
    }

    pub fn detectAnomaly(self: *AnomalyDetector, event: *const AnalyticsEvent) !AnomalyResult {
        var result = AnomalyResult.init(self.allocator);

        // Statistical anomaly detection based on event patterns
        const metric_key = try self.getMetricKey(event);
        const current_value = try self.extractMetricValue(event);

        if (self.baseline_stats.get(metric_key)) |baseline| {
            if (baseline.sample_count >= self.config.minimum_baseline_samples) {
                const z_score = @abs(current_value - baseline.mean) / @sqrt(baseline.variance);

                if (z_score > self.config.statistical_threshold) {
                    result.is_anomaly = true;
                    result.confidence = @min(z_score / 10.0, 1.0); // Scale confidence
                    result.severity = self.classifySeverity(z_score);
                    result.description = "Statistical anomaly detected";
                }
            }
        }

        // Update baseline statistics
        try self.updateBaseline(metric_key, current_value);

        return result;
    }

    fn getMetricKey(self: *AnomalyDetector, event: *const AnalyticsEvent) ![]const u8 {
        _ = self;
        // Generate a key based on event type and relevant properties
        return switch (event.event_type) {
            .node_creation => "node_creation_rate",
            .edge_creation => "edge_creation_rate",
            .graph_query => "query_frequency",
            else => "general_activity",
        };
    }

    /// Extract relevant numeric value from event for anomaly detection
    // CANARY: REQ=REQ-ANALYTICS-METRIC-001; FEATURE="Metric Extraction"; ASPECT=Core; STATUS=EXEMPT; OWNER=analytics; UPDATED=2026-01-10
    /// GAP-0051: Implements actual metric extraction based on event type and properties
    fn extractMetricValue(self: *AnomalyDetector, event: *const AnalyticsEvent) !f64 {
        _ = self;

        // Extract metric based on event type
        switch (event.event_type) {
            .graph_query => {
                // For queries: extract execution time or row count
                if (event.metadata.processing_time) |pt| {
                    return @as(f64, @floatFromInt(pt));
                }
                // Check for explicit execution_time property
                if (event.properties.get("execution_time_ms")) |val| {
                    return switch (val) {
                        .float => |f| f,
                        .integer => |i| @as(f64, @floatFromInt(i)),
                        else => 1.0,
                    };
                }
                // Check for row_count property
                if (event.properties.get("row_count")) |val| {
                    return switch (val) {
                        .float => |f| f,
                        .integer => |i| @as(f64, @floatFromInt(i)),
                        else => 1.0,
                    };
                }
                return 1.0; // Count as single event
            },
            .similarity_search => {
                // For similarity searches: extract result count or similarity score
                if (event.properties.get("result_count")) |val| {
                    return switch (val) {
                        .float => |f| f,
                        .integer => |i| @as(f64, @floatFromInt(i)),
                        else => 1.0,
                    };
                }
                if (event.properties.get("similarity_score")) |val| {
                    return switch (val) {
                        .float => |f| f,
                        else => 1.0,
                    };
                }
                return 1.0;
            },
            .anomaly_detection => {
                // For anomaly events: extract confidence or severity
                if (event.properties.get("confidence")) |val| {
                    return switch (val) {
                        .float => |f| f,
                        else => 1.0,
                    };
                }
                return 1.0;
            },
            .node_creation, .edge_creation, .node_update, .edge_update => {
                // For mutation events: extract affected count or use 1.0 per event
                if (event.properties.get("affected_count")) |val| {
                    return switch (val) {
                        .float => |f| f,
                        .integer => |i| @as(f64, @floatFromInt(i)),
                        else => 1.0,
                    };
                }
                // Check for batch_size for batch operations
                if (event.properties.get("batch_size")) |val| {
                    return switch (val) {
                        .float => |f| f,
                        .integer => |i| @as(f64, @floatFromInt(i)),
                        else => 1.0,
                    };
                }
                return 1.0; // Single creation/update event
            },
            .node_deletion, .edge_deletion => {
                // Deletion events count affected items
                if (event.properties.get("deleted_count")) |val| {
                    return switch (val) {
                        .float => |f| f,
                        .integer => |i| @as(f64, @floatFromInt(i)),
                        else => 1.0,
                    };
                }
                return 1.0;
            },
            .embedding_update => {
                // For embedding updates: extract dimension or vector count
                if (event.properties.get("vectors_updated")) |val| {
                    return switch (val) {
                        .float => |f| f,
                        .integer => |i| @as(f64, @floatFromInt(i)),
                        else => 1.0,
                    };
                }
                return 1.0;
            },
            .pattern_detection, .trend_analysis => {
                // Pattern/trend events: extract significance score
                if (event.properties.get("significance")) |val| {
                    return switch (val) {
                        .float => |f| f,
                        else => 1.0,
                    };
                }
                if (event.properties.get("pattern_count")) |val| {
                    return switch (val) {
                        .float => |f| f,
                        .integer => |i| @as(f64, @floatFromInt(i)),
                        else => 1.0,
                    };
                }
                return 1.0;
            },
        }
    }

    fn updateBaseline(self: *AnomalyDetector, metric_key: []const u8, value: f64) !void {
        if (self.baseline_stats.getPtr(metric_key)) |baseline| {
            // Update running statistics
            const n = @as(f64, @floatFromInt(baseline.sample_count));
            const new_mean = (baseline.mean * n + value) / (n + 1.0);
            const new_variance = (baseline.variance * n + (value - new_mean) * (value - baseline.mean)) / (n + 1.0);

            baseline.mean = new_mean;
            baseline.variance = new_variance;
            baseline.sample_count += 1;
            baseline.last_updated = std.time.milliTimestamp();
        } else {
            // Initialize new baseline
            try self.baseline_stats.put(metric_key, AnomalyBaseline{
                .mean = value,
                .variance = 0.0,
                .sample_count = 1,
                .last_updated = std.time.milliTimestamp(),
            });
        }
    }

    fn classifySeverity(self: *AnomalyDetector, z_score: f64) AnomalyResult.AnomalySeverity {
        _ = self;
        if (z_score < 5.0) return .low;
        if (z_score < 10.0) return .medium;
        if (z_score < 20.0) return .high;
        return .critical;
    }
};

/// Main real-time analytics engine
pub const RealTimeAnalyticsEngine = struct {
    allocator: Allocator,
    config: AnalyticsConfig,
    statistics: AnalyticsStatistics,
    event_queue: ArrayList(AnalyticsEvent),
    ml_manager: ?*ml_embeddings.GraphEmbeddingsManager,
    pattern_detector: PatternDetector,
    anomaly_detector: AnomalyDetector,
    processing_thread: ?std.Thread = null,
    should_stop: bool = false,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: Allocator, config: AnalyticsConfig) !RealTimeAnalyticsEngine {
        return RealTimeAnalyticsEngine{
            .allocator = allocator,
            .config = config,
            .statistics = AnalyticsStatistics{},
            .event_queue = ArrayList(AnalyticsEvent).init(allocator),
            .ml_manager = null,
            .pattern_detector = PatternDetector.init(allocator, .{}),
            .anomaly_detector = AnomalyDetector.init(allocator, .{}),
        };
    }

    pub fn deinit(self: *RealTimeAnalyticsEngine) void {
        self.stop();

        for (self.event_queue.items) |*event| {
            event.deinit();
        }
        self.event_queue.deinit();
        self.pattern_detector.deinit();
        self.anomaly_detector.deinit();
    }

    pub fn connectMLManager(self: *RealTimeAnalyticsEngine, ml_manager: *ml_embeddings.GraphEmbeddingsManager) void {
        self.ml_manager = ml_manager;
    }

    pub fn start(self: *RealTimeAnalyticsEngine) !void {
        if (self.processing_thread == null) {
            self.should_stop = false;
            self.processing_thread = try std.Thread.spawn(.{}, processEvents, .{self});
            log.info("Real-time analytics engine started", .{});
        }
    }

    pub fn stop(self: *RealTimeAnalyticsEngine) void {
        if (self.processing_thread) |thread| {
            self.should_stop = true;
            thread.join();
            self.processing_thread = null;
            log.info("Real-time analytics engine stopped", .{});
        }
    }

    pub fn queueEvent(self: *RealTimeAnalyticsEngine, event: AnalyticsEvent) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.event_queue.items.len >= self.config.max_event_queue_size) {
            // Remove oldest event to make space
            var oldest = self.event_queue.orderedRemove(0);
            oldest.deinit();
            self.statistics.events_queued -= 1;
        }

        try self.event_queue.append(event);
        self.statistics.events_queued += 1;
    }

    pub fn processEventsBatch(self: *RealTimeAnalyticsEngine) !void {
        const start_time = std.time.milliTimestamp();
        var events_to_process = ArrayList(AnalyticsEvent).init(self.allocator);
        defer events_to_process.deinit();

        // Extract batch of events from queue
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            const batch_size = @min(self.config.batch_size, self.event_queue.items.len);
            if (batch_size == 0) return;

            for (0..batch_size) |i| {
                try events_to_process.append(self.event_queue.items[i]);
            }

            // Remove processed events from queue
            for (0..batch_size) |_| {
                _ = self.event_queue.orderedRemove(0);
                self.statistics.events_queued -= 1;
            }
        }

        // Process each event in the batch
        for (events_to_process.items) |*event| {
            try self.processEvent(event);
            self.statistics.events_processed += 1;
        }

        // Update processing statistics
        const processing_time = @as(f64, @floatFromInt(std.time.milliTimestamp() - start_time));
        self.statistics.updateProcessingTime(processing_time);
        self.statistics.last_update_timestamp = std.time.milliTimestamp();

        // Clean up events
        for (events_to_process.items) |*event| {
            event.deinit();
        }
    }

    fn processEvent(self: *RealTimeAnalyticsEngine, event: *AnalyticsEvent) !void {
        const event_start_time = std.time.milliTimestamp();

        // Pattern detection
        if (self.config.enable_pattern_detection) {
            if (try self.pattern_detector.detectPattern(event)) |_| {
                self.statistics.patterns_detected += 1;
            }
        }

        // Anomaly detection
        if (self.config.enable_anomaly_detection) {
            var anomaly_result = try self.anomaly_detector.detectAnomaly(event);
            defer anomaly_result.deinit();

            if (anomaly_result.is_anomaly) {
                self.statistics.anomalies_detected += 1;
                try self.handleAnomaly(event, &anomaly_result);
            }
        }

        // ML integration - trigger embedding updates
        if (self.config.enable_ml_integration and self.ml_manager != null) {
            try self.handleMLIntegration(event);
        }

        // Trend analysis
        if (self.config.enable_trend_analysis) {
            try self.analyzeTrends(event);
        }

        // Update processing metadata
        event.metadata.processing_time = std.time.milliTimestamp() - event_start_time;
    }

    fn handleMLIntegration(self: *RealTimeAnalyticsEngine, event: *AnalyticsEvent) !void {
        if (self.ml_manager) |ml_mgr| {
            switch (event.event_type) {
                .node_creation, .node_update => {
                    if (event.node_id) |node_id| {
                        // Trigger embedding update for affected node
                        try ml_mgr.generateEmbedding(node_id, .node2vec);
                        self.statistics.ml_updates_triggered += 1;
                    }
                },
                .edge_creation, .edge_update => {
                    if (event.node_id) |source_node| {
                        // Update embeddings for nodes affected by edge changes
                        try ml_mgr.generateEmbedding(source_node, .graphsage);
                        self.statistics.ml_updates_triggered += 1;
                    }
                },
                .similarity_search => {
                    // Similarity searches can trigger embedding quality improvements
                    if (event.node_id) |node_id| {
                        if (ml_mgr.hasEmbedding(node_id)) {
                            // Potentially refine embedding based on search results
                            try ml_mgr.generateEmbedding(node_id, .node2vec);
                        }
                    }
                },
                else => {},
            }
        }
    }

    fn handleAnomaly(self: *RealTimeAnalyticsEngine, event: *AnalyticsEvent, anomaly: *AnomalyDetector.AnomalyResult) !void {
        _ = self;
        _ = event;

        // Log anomaly for monitoring and alerting
        log.warn("Anomaly detected: {s} (severity: {}, confidence: {d:.2})", .{ anomaly.description, anomaly.severity, anomaly.confidence });

        // In a production system, this would trigger alerts, notifications,
        // or automatic response mechanisms based on severity
    }

    fn analyzeTrends(self: *RealTimeAnalyticsEngine, event: *AnalyticsEvent) !void {
        _ = event;

        // Trend analysis implementation
        // This would analyze patterns over time windows to identify trends
        // such as increasing activity, seasonal patterns, growth trends, etc.
        self.statistics.trends_identified += 1;
    }

    pub fn getStatistics(self: *RealTimeAnalyticsEngine) AnalyticsStatistics {
        return self.statistics;
    }

    fn processEvents(self: *RealTimeAnalyticsEngine) void {
        while (!self.should_stop) {
            self.processEventsBatch() catch |err| {
                log.err("Error processing events batch: {}", .{err});
                self.statistics.processing_errors += 1;
            };

            // Sleep for configured interval
            std.time.sleep(self.config.processing_interval_ms * std.time.ns_per_ms);
        }
    }
};

// Utility functions
fn generateEventId() u64 {
    // Generate unique event ID (could use UUID or timestamp-based approach)
    return @intCast(@mod(std.time.nanoTimestamp(), std.math.maxInt(u64)));
}

fn generatePatternId() u64 {
    // Generate unique pattern ID
    return @intCast(@mod(std.time.nanoTimestamp(), std.math.maxInt(u64)));
}

// Integration with CDC system
pub const CDCAnalyticsIntegration = struct {
    analytics_engine: *RealTimeAnalyticsEngine,

    pub fn init(analytics_engine: *RealTimeAnalyticsEngine) CDCAnalyticsIntegration {
        return CDCAnalyticsIntegration{
            .analytics_engine = analytics_engine,
        };
    }

    pub fn handleCDCEvent(self: *CDCAnalyticsIntegration, cdc_event: anytype) !void {
        // Convert CDC event to analytics event
        const analytics_event = try self.convertCDCEvent(cdc_event);
        try self.analytics_engine.queueEvent(analytics_event);
    }

    fn convertCDCEvent(self: *CDCAnalyticsIntegration, cdc_event: anytype) !AnalyticsEvent {
        _ = cdc_event;

        // Convert CDC event format to analytics event format
        // This would parse the CDC event structure and map it to our analytics event
        var event = AnalyticsEvent.init(self.analytics_engine.allocator, .node_creation);

        // Set event properties based on CDC event content
        try event.setProperty("source", AnalyticsValue{ .string = "cdc" });

        return event;
    }
};
