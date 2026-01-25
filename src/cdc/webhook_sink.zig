const std = @import("std");
const cdc = @import("core.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=CDC; STATUS=IMPL; OWNER=cdc; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("cdc");
const Attr = logging.Attr;

/// Webhook sink configuration
pub const WebhookConfig = struct {
    endpoint: []const u8,
    method: HttpMethod = .POST,

    /// Custom HTTP headers for auth/routing
    custom_headers: []const Header = &.{},

    /// Retry configuration
    max_retries: u32 = 3,
    retry_base_delay_ms: u64 = 100,
    retry_max_delay_ms: u64 = 30000,
    retry_jitter: bool = true,

    /// Idempotency configuration
    enable_idempotency: bool = true,
    idempotency_header: []const u8 = "X-Idempotency-Key",

    /// Dead letter queue configuration
    enable_dlq: bool = true,
    dlq_max_size: u64 = 10000,
    dlq_retention_ms: u64 = 7 * 24 * 60 * 60 * 1000, // 7 days

    /// Delivery policy
    delivery_guarantee: DeliveryGuarantee = .at_least_once,
    batch_size: u32 = 100,
    batch_timeout_ms: u64 = 1000,

    /// Connection settings
    connect_timeout_ms: u64 = 5000,
    request_timeout_ms: u64 = 30000,
    keepalive: bool = true,
};

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const DeliveryGuarantee = enum {
    at_most_once,
    at_least_once,
    exactly_once,
};

/// Webhook sink for CDC events
// CANARY: REQ=REQ-GQL-CDC-001; FEATURE="CDC Webhook Hardening"; ASPECT=Reliability; STATUS=TESTED; TEST=e2e_cdc_webhook_reliability; BENCH=benchmark_cdc_webhook_throughput; OWNER=streaming; UPDATED=2026-01-17
pub const WebhookSink = struct {
    allocator: std.mem.Allocator,
    config: WebhookConfig,
    http_client: HttpClient,
    batch_buffer: std.ArrayList(cdc.Event),
    dlq: DeadLetterQueue,
    metrics: WebhookMetrics,
    last_flush_time: i64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: WebhookConfig) !Self {
        return .{
            .allocator = allocator,
            .config = config,
            .http_client = try HttpClient.init(allocator, config),
            .batch_buffer = std.ArrayList(cdc.Event).init(allocator),
            .dlq = try DeadLetterQueue.init(allocator, config.dlq_max_size),
            .metrics = WebhookMetrics.init(),
            .last_flush_time = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.batch_buffer.deinit();
        self.dlq.deinit();
        self.http_client.deinit();
    }

    /// Send a CDC event to the webhook
    pub fn sendEvent(self: *Self, event: cdc.Event) !void {
        // Add to batch buffer
        try self.batch_buffer.append(event);

        // Check if we should flush
        const should_flush = self.batch_buffer.items.len >= self.config.batch_size or
            (std.time.milliTimestamp() - self.last_flush_time) >= @as(i64, @intCast(self.config.batch_timeout_ms));

        if (should_flush) {
            try self.flush();
        }
    }

    /// Flush pending events
    pub fn flush(self: *Self) !void {
        if (self.batch_buffer.items.len == 0) return;

        const events = try self.batch_buffer.toOwnedSlice();
        defer self.allocator.free(events);

        // Generate idempotency key for batch
        const idempotency_key = if (self.config.enable_idempotency)
            try self.generateIdempotencyKey(events)
        else
            null;
        defer if (idempotency_key) |key| self.allocator.free(key);

        // Attempt delivery with retries
        const result = self.deliverWithRetry(events, idempotency_key) catch |err| {
            // Add to DLQ on failure
            if (self.config.enable_dlq) {
                try self.addToDLQ(events, err);
            }
            return err;
        };

        // Update metrics
        self.metrics.recordDelivery(events.len, result.attempts, result.latency_ms);
        self.last_flush_time = std.time.milliTimestamp();
    }

    /// Deliver events with retry logic
    fn deliverWithRetry(self: *Self, events: []const cdc.Event, idempotency_key: ?[]const u8) !DeliveryResult {
        var attempt: u32 = 0;
        var last_error: anyerror = undefined;

        while (attempt < self.config.max_retries) : (attempt += 1) {
            const start_time = std.time.milliTimestamp();

            // Prepare request
            const payload = try self.serializeEvents(events);
            defer self.allocator.free(payload);

            // Build headers
            var headers = std.ArrayList(Header).init(self.allocator);
            defer headers.deinit();

            // Add custom headers
            for (self.config.custom_headers) |header| {
                try headers.append(header);
            }

            // Add idempotency header
            if (idempotency_key) |key| {
                try headers.append(.{
                    .name = self.config.idempotency_header,
                    .value = key,
                });
            }

            // Add standard headers
            try headers.append(.{
                .name = "Content-Type",
                .value = "application/json",
            });
            try headers.append(.{
                .name = "X-CDC-Attempt",
                .value = try std.fmt.allocPrint(self.allocator, "{}", .{attempt + 1}),
            });
            defer self.allocator.free(headers.items[headers.items.len - 1].value);

            // Send request
            const response = self.http_client.request(
                self.config.method,
                self.config.endpoint,
                headers.items,
                payload,
            ) catch |err| {
                last_error = err;

                // Calculate backoff delay
                if (attempt < self.config.max_retries - 1) {
                    const delay = self.calculateBackoff(attempt);
                    std.time.sleep(delay * 1_000_000);
                }

                continue;
            };
            defer response.deinit();

            // Check response status
            if (response.status >= 200 and response.status < 300) {
                // Success
                const latency = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
                return DeliveryResult{
                    .success = true,
                    .attempts = attempt + 1,
                    .latency_ms = latency,
                };
            } else if (response.status >= 400 and response.status < 500) {
                // Client error - don't retry
                return error.ClientError;
            } else {
                // Server error - retry
                last_error = error.ServerError;

                if (attempt < self.config.max_retries - 1) {
                    const delay = self.calculateBackoff(attempt);
                    std.time.sleep(delay * 1_000_000);
                }
            }
        }

        return last_error;
    }

    /// Calculate exponential backoff with jitter
    fn calculateBackoff(self: *Self, attempt: u32) u64 {
        const base_delay = self.config.retry_base_delay_ms;
        var delay = base_delay * std.math.pow(u64, 2, attempt);

        // Cap at max delay
        delay = @min(delay, self.config.retry_max_delay_ms);

        // Add jitter
        if (self.config.retry_jitter) {
            const jitter = std.crypto.random.int(u64) % (delay / 2);
            delay = delay + jitter;
        }

        return delay;
    }

    /// Generate idempotency key for event batch
    fn generateIdempotencyKey(self: *Self, events: []const cdc.Event) ![]const u8 {
        var hasher = std.hash.Wyhash.init(0);

        for (events) |event| {
            hasher.update(std.mem.asBytes(&event.sequence_number));
            hasher.update(event.table_name);
        }

        const hash = hasher.final();
        return try std.fmt.allocPrint(self.allocator, "{x}", .{hash});
    }

    /// Serialize events to JSON
    fn serializeEvents(self: *Self, events: []const cdc.Event) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        var writer = buffer.writer();
        try writer.writeAll("[");

        for (events, 0..) |event, i| {
            if (i > 0) try writer.writeAll(",");
            try std.json.stringify(event, .{}, writer);
        }

        try writer.writeAll("]");

        return try buffer.toOwnedSlice();
    }

    /// Add failed events to dead letter queue
    fn addToDLQ(self: *Self, events: []const cdc.Event, err: anyerror) !void {
        const entry = DLQEntry{
            .events = events,
            .message = @errorName(err),
            .timestamp = std.time.milliTimestamp(),
            .retry_count = self.config.max_retries,
        };

        try self.dlq.add(entry);
        self.metrics.dlq_events += @as(u64, @intCast(events.len));
    }

    /// Process dead letter queue for redelivery
    pub fn processDLQ(self: *Self) !u64 {
        var processed: u64 = 0;

        while (self.dlq.pop()) |entry| {
            // Check if entry is expired
            const age = std.time.milliTimestamp() - entry.timestamp;
            if (age > @as(i64, @intCast(self.config.dlq_retention_ms))) {
                // Expired - discard
                self.metrics.dlq_expired += @as(u64, @intCast(entry.events.len));
                continue;
            }

            // Attempt redelivery
            const idempotency_key = try self.generateIdempotencyKey(entry.events);
            defer self.allocator.free(idempotency_key);

            self.deliverWithRetry(entry.events, idempotency_key) catch {
                // Failed again - re-add to DLQ with updated timestamp
                var new_entry = entry;
                new_entry.timestamp = std.time.milliTimestamp();
                new_entry.retry_count += self.config.max_retries;
                try self.dlq.add(new_entry);
                continue;
            };

            processed += @as(u64, @intCast(entry.events.len));
            self.metrics.dlq_recovered += @as(u64, @intCast(entry.events.len));
        }

        return processed;
    }
};

/// Dead letter queue for failed events
const DeadLetterQueue = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(DLQEntry),
    max_size: u64,

    fn init(allocator: std.mem.Allocator, max_size: u64) !DeadLetterQueue {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(DLQEntry).init(allocator),
            .max_size = max_size,
        };
    }

    fn deinit(self: *DeadLetterQueue) void {
        self.entries.deinit();
    }

    fn add(self: *DeadLetterQueue, entry: DLQEntry) !void {
        if (self.entries.items.len >= self.max_size) {
            // Remove oldest entry
            _ = self.entries.orderedRemove(0);
        }
        try self.entries.append(entry);
    }

    fn pop(self: *DeadLetterQueue) ?DLQEntry {
        if (self.entries.items.len == 0) return null;
        return self.entries.orderedRemove(0);
    }
};

const DLQEntry = struct {
    events: []const cdc.Event,
    error_message: []const u8,
    timestamp: i64,
    retry_count: u32,
};

/// HTTP client for webhook delivery
const HttpClient = struct {
    allocator: std.mem.Allocator,
    config: WebhookConfig,

    fn init(allocator: std.mem.Allocator, config: WebhookConfig) !HttpClient {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    fn deinit(self: *HttpClient) void {
        _ = self;
    }

    // CANARY: REQ=REQ-CDC-HTTP-001; FEATURE="CDCWebhookHTTP"; ASPECT=Request; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-09
    fn request(
        self: *HttpClient,
        method: HttpMethod,
        url: []const u8,
        headers: []const Header,
        body: []const u8,
    ) !HttpResponse {
        // Parse the URL
        const uri = std.Uri.parse(url) catch {
            log.err("CDC webhook: Invalid URL", &.{
                Attr.string("url", url),
            });
            return HttpResponse{ .status = 400, .body = "Invalid URL" };
        };

        // Create HTTP client
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // Build headers
        var extra_headers = std.http.Client.Request.Headers{};
        extra_headers.content_type = .{ .override = "application/json" };

        // Add custom headers (limited to what std.http supports)
        for (headers) |header| {
            if (std.mem.eql(u8, header.name, "Authorization")) {
                extra_headers.authorization = .{ .override = header.value };
            }
        }

        // Determine HTTP method
        const http_method: std.http.Method = switch (method) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .DELETE => .DELETE,
            .PATCH => .PATCH,
        };

        // Open request
        var request_obj = client.open(http_method, uri, extra_headers, .{}) catch |err| {
            log.err("CDC webhook: Failed to open connection", &.{
                Attr.string("url", url),
                Attr.err("error", err),
            });
            return HttpResponse{ .status = 503, .body = "Connection failed" };
        };
        defer request_obj.deinit();

        // Write body
        if (body.len > 0) {
            request_obj.write(body) catch |err| {
                log.err("CDC webhook: Failed to write body", &.{
                    Attr.err("error", err),
                });
                return HttpResponse{ .status = 500, .body = "Write failed" };
            };
        }

        // Finish and read response
        request_obj.finish() catch |err| {
            log.err("CDC webhook: Failed to finish request", &.{
                Attr.err("error", err),
            });
            return HttpResponse{ .status = 500, .body = "Request failed" };
        };

        // Wait for response
        request_obj.wait() catch |err| {
            log.err("CDC webhook: Failed to get response", &.{
                Attr.err("error", err),
            });
            return HttpResponse{ .status = 504, .body = "Timeout" };
        };

        const status = @intFromEnum(request_obj.response.status);

        log.debug("CDC webhook request completed", &.{
            Attr.string("method", @tagName(method)),
            Attr.string("url", url),
            Attr.int("status", status),
        });

        return HttpResponse{
            .status = status,
            .body = "",
        };
    }
};

const HttpResponse = struct {
    status: u16,
    body: []const u8,

    fn deinit(self: *const HttpResponse) void {
        _ = self;
    }
};

const DeliveryResult = struct {
    success: bool,
    attempts: u32,
    latency_ms: u64,
};

/// Webhook metrics
const WebhookMetrics = struct {
    total_events: u64,
    successful_deliveries: u64,
    failed_deliveries: u64,
    retry_attempts: u64,
    dlq_events: u64,
    dlq_recovered: u64,
    dlq_expired: u64,
    total_latency_ms: u64,

    fn init() WebhookMetrics {
        return .{
            .total_events = 0,
            .successful_deliveries = 0,
            .failed_deliveries = 0,
            .retry_attempts = 0,
            .dlq_events = 0,
            .dlq_recovered = 0,
            .dlq_expired = 0,
            .total_latency_ms = 0,
        };
    }

    fn recordDelivery(self: *WebhookMetrics, event_count: usize, attempts: u32, latency_ms: u64) void {
        self.total_events += @as(u64, @intCast(event_count));
        self.successful_deliveries += 1;
        self.retry_attempts += @as(u64, attempts - 1);
        self.total_latency_ms += latency_ms;
    }
};
