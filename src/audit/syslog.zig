const std = @import("std");
const events = @import("events.zig");
const config = @import("config.zig");
const cef = @import("cef.zig");
const time = @import("time.zig");

const QUEUE_SIZE = 10000;

pub const SyslogSender = struct {
    allocator: std.mem.Allocator,
    config: config.SyslogSinkConfig,
    service: config.ServiceConfig,
    identity: config.CefIdentityConfig,
    clock: time.Clock,
    queue: RingBuffer([]const u8),
    mutex: std.Thread.Mutex,
    should_stop: std.atomic.Value(bool),
    thread: ?std.Thread,

    pub fn init(
        allocator: std.mem.Allocator,
        syslog_config: config.SyslogSinkConfig,
        service_config: config.ServiceConfig,
        identity_config: config.CefIdentityConfig,
        clock: time.Clock,
    ) !*SyslogSender {
        const sender = try allocator.create(SyslogSender);
        sender.* = SyslogSender{
            .allocator = allocator,
            .config = syslog_config,
            .service = service_config,
            .identity = identity_config,
            .clock = clock,
            .queue = RingBuffer([]const u8).init(allocator, QUEUE_SIZE),
            .mutex = std.Thread.Mutex{},
            .should_stop = std.atomic.Value(bool).init(false),
            .thread = null,
        };

        if (sender.config.enabled) {
            sender.thread = try std.Thread.spawn(.{}, workerThread, .{sender});
        }

        return sender;
    }

    pub fn deinit(self: *SyslogSender) void {
        if (self.thread) |thread| {
            self.should_stop.store(true, .seq_cst);
            thread.join();
        }

        // Clean up remaining messages in queue
        while (self.queue.pop()) |msg| {
            self.allocator.free(msg);
        }
        self.queue.deinit();
        self.allocator.destroy(self);
    }

    pub fn send(self: *SyslogSender, event: *const events.AuditEvent) !void {
        if (!self.config.enabled) return;

        const cef_msg = try cef.formatCef(self.allocator, event, &self.identity, self.clock);
        const syslog_line = try self.formatRfc5424(event, cef_msg);
        defer self.allocator.free(cef_msg);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.queue.push(syslog_line)) {
            // Queue full, drop oldest message
            if (self.queue.pop()) |old_msg| {
                self.allocator.free(old_msg);
            }
            _ = self.queue.push(syslog_line);
        }
    }

    fn formatRfc5424(self: *SyslogSender, event: *const events.AuditEvent, cef_msg: []const u8) ![]const u8 {
        // <PRI>1 TIMESTAMP HOST APP PROCID MSGID - MSG
        const facility = self.config.rfc5424.facility.toInt();
        const severity = event.severity.toSyslogSeverity();
        const pri = facility * 8 + severity;

        var ts_buf: [64]u8 = undefined;
        const timestamp = self.clock.nowRfc3339(&ts_buf);

        return std.fmt.allocPrint(self.allocator, "<{d}>1 {s} {s} {s} {d} AUDIT - {s}", .{
            pri,
            timestamp,
            self.service.host,
            self.service.name,
            self.service.pid,
            cef_msg,
        });
    }

    fn workerThread(self: *SyslogSender) void {
        while (!self.should_stop.load(.seq_cst)) {
            self.processQueue() catch |err| {
                // Log error to stderr, but continue processing
                std.debug.print("Syslog sender error: {}\n", .{err});
            };
            std.time.sleep(std.time.ns_per_ms * 100); // 100ms sleep
        }
    }

    fn processQueue(self: *SyslogSender) !void {
        var messages: [32][]const u8 = undefined;
        var count: usize = 0;

        // Batch dequeue messages
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (count < messages.len) {
                if (self.queue.pop()) |msg| {
                    messages[count] = msg;
                    count += 1;
                } else {
                    break;
                }
            }
        }

        if (count == 0) return;

        // Send messages (outside of lock)
        for (messages[0..count]) |msg| {
            defer self.allocator.free(msg);
            self.sendToSyslog(msg) catch |err| {
                // On error, just log and continue
                std.debug.print("Failed to send syslog message: {}\n", .{err});
            };
        }
    }

    fn sendToSyslog(self: *SyslogSender, message: []const u8) !void {
        // Skip sending if host contains placeholder
        if (std.mem.indexOf(u8, self.config.host, "{{") != null) {
            return; // Mock mode for testing
        }

        switch (self.config.protocol) {
            .udp => try self.sendUdp(message),
            .tcp => try self.sendTcp(message),
            .tls => try self.sendTls(message),
        }
    }

    fn sendUdp(self: *SyslogSender, message: []const u8) !void {
        const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
        defer std.posix.close(socket);

        const addr = try std.net.Address.parseIp4(self.config.host, self.config.port);
        _ = try std.posix.sendto(socket, message, 0, &addr.any, addr.getOsSockLen());
    }

    fn sendTcp(self: *SyslogSender, message: []const u8) !void {
        const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        defer std.posix.close(socket);

        const addr = try std.net.Address.parseIp4(self.config.host, self.config.port);
        try std.posix.connect(socket, &addr.any, addr.getOsSockLen());

        // TCP syslog typically uses length-prefixed messages
        const length_prefix = try std.fmt.allocPrint(self.allocator, "{d} ", .{message.len});
        defer self.allocator.free(length_prefix);

        _ = try std.posix.send(socket, length_prefix, 0);
        _ = try std.posix.send(socket, message, 0);
    }

    fn sendTls(self: *SyslogSender, message: []const u8) !void {
        // TLS implementation would go here
        // For now, fallback to TCP
        try self.sendTcp(message);
    }
};

pub const MockSyslogSender = struct {
    allocator: std.mem.Allocator,
    captured_messages: std.ArrayList([]const u8),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) MockSyslogSender {
        return MockSyslogSender{
            .allocator = allocator,
            .captured_messages = std.ArrayList([]const u8).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *MockSyslogSender) void {
        for (self.captured_messages.items) |msg| {
            self.allocator.free(msg);
        }
        self.captured_messages.deinit();
    }

    pub fn send(self: *MockSyslogSender, event: *const events.AuditEvent, identity: *const config.CefIdentityConfig, service: *const config.ServiceConfig, syslog_config: *const config.SyslogSinkConfig, clock: time.Clock) !void {
        const cef_msg = try cef.formatCef(self.allocator, event, identity, clock);
        defer self.allocator.free(cef_msg);

        const facility = syslog_config.rfc5424.facility.toInt();
        const severity = event.severity.toSyslogSeverity();
        const pri = facility * 8 + severity;

        var ts_buf: [64]u8 = undefined;
        const timestamp = clock.nowRfc3339(&ts_buf);

        const syslog_line = try std.fmt.allocPrint(self.allocator, "<{d}>1 {s} {s} {s} {d} AUDIT - {s}", .{
            pri,
            timestamp,
            service.host,
            service.name,
            service.pid,
            cef_msg,
        });

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.captured_messages.append(syslog_line);
    }

    pub fn getMessages(self: *MockSyslogSender) []const []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.captured_messages.items;
    }

    pub fn clear(self: *MockSyslogSender) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.captured_messages.items) |msg| {
            self.allocator.free(msg);
        }
        self.captured_messages.clearRetainingCapacity();
    }
};

fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        head: usize,
        tail: usize,
        count: usize,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) Self {
            return Self{
                .items = allocator.alloc(T, capacity) catch unreachable,
                .head = 0,
                .tail = 0,
                .count = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
        }

        pub fn push(self: *Self, item: T) bool {
            if (self.count >= self.items.len) {
                return false; // Buffer full
            }

            self.items[self.tail] = item;
            self.tail = (self.tail + 1) % self.items.len;
            self.count += 1;
            return true;
        }

        pub fn pop(self: *Self) ?T {
            if (self.count == 0) {
                return null;
            }

            const item = self.items[self.head];
            self.head = (self.head + 1) % self.items.len;
            self.count -= 1;
            return item;
        }

        pub fn isFull(self: *Self) bool {
            return self.count >= self.items.len;
        }

        pub fn isEmpty(self: *Self) bool {
            return self.count == 0;
        }
    };
}
