const std = @import("std");

/// Memory pressure levels for graduated response
pub const MemoryPressure = enum {
    none,
    low,
    medium,
    high,
    critical,

    pub fn fromUtilization(utilization: f64) MemoryPressure {
        if (utilization < 0.5) return .none;
        if (utilization < 0.7) return .low;
        if (utilization < 0.85) return .medium;
        if (utilization < 0.95) return .high;
        return .critical;
    }
};

/// Memory allocation tracking for detailed monitoring
const AllocationTracker = struct {
    allocations: std.AutoHashMap(usize, AllocationInfo),
    total_allocations: usize,
    total_deallocations: usize,
    peak_usage: usize,

    const AllocationInfo = struct {
        size: usize,
        timestamp: i64,
        tag: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) AllocationTracker {
        return .{
            .allocations = std.AutoHashMap(usize, AllocationInfo).init(allocator),
            .total_allocations = 0,
            .total_deallocations = 0,
            .peak_usage = 0,
        };
    }

    pub fn deinit(self: *AllocationTracker) void {
        self.allocations.deinit();
    }

    pub fn trackAllocation(self: *AllocationTracker, ptr: usize, size: usize, tag: []const u8) !void {
        try self.allocations.put(ptr, .{
            .size = size,
            .timestamp = std.time.timestamp(),
            .tag = tag,
        });
        self.total_allocations += 1;

        const current_usage = self.getCurrentUsage();
        if (current_usage > self.peak_usage) {
            self.peak_usage = current_usage;
        }
    }

    pub fn trackDeallocation(self: *AllocationTracker, ptr: usize) void {
        _ = self.allocations.remove(ptr);
        self.total_deallocations += 1;
    }

    pub fn getCurrentUsage(self: *const AllocationTracker) usize {
        var total: usize = 0;
        var iter = self.allocations.iterator();
        while (iter.next()) |entry| {
            total += entry.value_ptr.size;
        }
        return total;
    }

    pub fn getLargestAllocations(self: *const AllocationTracker, allocator: std.mem.Allocator, count: usize) ![]AllocationInfo {
        var allocations = try allocator.alloc(AllocationInfo, @min(count, self.allocations.count()));
        var i: usize = 0;

        var iter = self.allocations.iterator();
        while (iter.next()) |entry| {
            if (i < allocations.len) {
                allocations[i] = entry.value_ptr.*;
                i += 1;
            }
        }

        // Sort by size (descending)
        std.mem.sort(AllocationInfo, allocations, {}, struct {
            fn lessThan(_: void, a: AllocationInfo, b: AllocationInfo) bool {
                return a.size > b.size;
            }
        }.lessThan);

        return allocations;
    }
};

/// Memory governance system to prevent OOMs with soft limits and spill triggers
pub const MemoryGovernor = struct {
    allocator: std.mem.Allocator,
    soft_limit_bytes: usize,
    hard_limit_bytes: usize,
    current_usage: std.atomic.Value(usize),
    spill_callbacks: std.ArrayList(SpillCallback),
    pressure_callbacks: std.ArrayList(PressureCallback),
    allocation_tracker: ?AllocationTracker,
    enable_detailed_tracking: bool,
    last_pressure_check: i64,
    pressure_check_interval_ms: i64,
    fragmentation_threshold: f64,

    const SpillCallback = struct {
        context: *anyopaque,
        trigger_fn: *const fn (*anyopaque) void,
        name: []const u8,
        priority: u8, // 0 = highest priority
    };

    const PressureCallback = struct {
        context: *anyopaque,
        pressure_fn: *const fn (*anyopaque, MemoryPressure) void,
        name: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, soft_limit: usize, hard_limit: usize) MemoryGovernor {
        return .{
            .allocator = allocator,
            .soft_limit_bytes = soft_limit,
            .hard_limit_bytes = hard_limit,
            .current_usage = std.atomic.Value(usize).init(0),
            .spill_callbacks = std.ArrayList(SpillCallback).initCapacity(allocator, 0) catch @panic("OOM"),
            .pressure_callbacks = std.ArrayList(PressureCallback).initCapacity(allocator, 0) catch @panic("OOM"),
            .allocation_tracker = null,
            .enable_detailed_tracking = false,
            .last_pressure_check = 0,
            .pressure_check_interval_ms = 1000, // 1 second
            .fragmentation_threshold = 0.3, // 30% fragmentation triggers concern
        };
    }

    pub fn initWithTracking(allocator: std.mem.Allocator, soft_limit: usize, hard_limit: usize, enable_tracking: bool) MemoryGovernor {
        var governor = MemoryGovernor.init(allocator, soft_limit, hard_limit);
        governor.enable_detailed_tracking = enable_tracking;
        if (enable_tracking) {
            governor.allocation_tracker = AllocationTracker.init(allocator);
        }
        return governor;
    }

    pub fn deinit(self: *MemoryGovernor) void {
        self.spill_callbacks.deinit(self.allocator);
        self.pressure_callbacks.deinit(self.allocator);
        if (self.allocation_tracker) |*tracker| {
            tracker.deinit();
        }
    }

    pub fn registerSpillCallback(self: *MemoryGovernor, context: *anyopaque, trigger_fn: *const fn (*anyopaque) void, name: []const u8) !void {
        try self.registerSpillCallbackWithPriority(context, trigger_fn, name, 128); // Default priority
    }

    pub fn registerSpillCallbackWithPriority(self: *MemoryGovernor, context: *anyopaque, trigger_fn: *const fn (*anyopaque) void, name: []const u8, priority: u8) !void {
        try self.spill_callbacks.append(self.allocator, .{
            .context = context,
            .trigger_fn = trigger_fn,
            .name = name,
            .priority = priority,
        });

        // Sort callbacks by priority (lower number = higher priority)
        std.mem.sort(SpillCallback, self.spill_callbacks.items, {}, struct {
            fn lessThan(_: void, a: SpillCallback, b: SpillCallback) bool {
                return a.priority < b.priority;
            }
        }.lessThan);
    }

    pub fn registerPressureCallback(self: *MemoryGovernor, context: *anyopaque, pressure_fn: *const fn (*anyopaque, MemoryPressure) void, name: []const u8) !void {
        try self.pressure_callbacks.append(self.allocator, .{
            .context = context,
            .pressure_fn = pressure_fn,
            .name = name,
        });
    }

    pub fn allocate(self: *MemoryGovernor, size: usize) ![]u8 {
        return self.allocateWithTag(size, "untagged");
    }

    pub fn allocateWithTag(self: *MemoryGovernor, size: usize, tag: []const u8) ![]u8 {
        const current = self.current_usage.load(.monotonic);
        const new_usage = current + size;

        if (new_usage > self.hard_limit_bytes) {
            return error.OutOfMemory;
        }

        // Check memory pressure and trigger appropriate responses
        const pressure = self.checkMemoryPressure(new_usage);
        self.handleMemoryPressure(pressure);

        const memory = try self.allocator.alloc(u8, size);
        _ = self.current_usage.fetchAdd(size, .monotonic);

        // Track allocation if detailed tracking is enabled
        if (self.allocation_tracker) |*tracker| {
            tracker.trackAllocation(@intFromPtr(memory.ptr), size, tag) catch {};
        }

        return memory;
    }

    pub fn deallocate(self: *MemoryGovernor, memory: []u8) void {
        // Track deallocation if detailed tracking is enabled
        if (self.allocation_tracker) |*tracker| {
            tracker.trackDeallocation(@intFromPtr(memory.ptr));
        }

        self.allocator.free(memory);
        _ = self.current_usage.fetchSub(memory.len, .monotonic);
    }

    pub fn currentUsage(self: *const MemoryGovernor) usize {
        return self.current_usage.load(.monotonic);
    }

    pub fn utilizationPercent(self: *const MemoryGovernor) f64 {
        const current = self.currentUsage();
        return @as(f64, @floatFromInt(current)) / @as(f64, @floatFromInt(self.soft_limit_bytes)) * 100.0;
    }

    pub fn shouldSpill(self: *const MemoryGovernor) bool {
        return self.currentUsage() > self.soft_limit_bytes;
    }

    /// Check current memory pressure level
    pub fn getMemoryPressure(self: *const MemoryGovernor) MemoryPressure {
        const utilization = self.utilizationPercent() / 100.0;
        return MemoryPressure.fromUtilization(utilization);
    }

    /// Check memory pressure with rate limiting
    fn checkMemoryPressure(self: *MemoryGovernor, projected_usage: usize) MemoryPressure {
        const now = std.time.milliTimestamp();
        if (now - self.last_pressure_check < self.pressure_check_interval_ms) {
            // Use cached pressure level to avoid excessive computation
            return self.getMemoryPressure();
        }

        self.last_pressure_check = now;
        const utilization = @as(f64, @floatFromInt(projected_usage)) / @as(f64, @floatFromInt(self.soft_limit_bytes));
        return MemoryPressure.fromUtilization(utilization);
    }

    /// Handle memory pressure by triggering appropriate callbacks
    fn handleMemoryPressure(self: *MemoryGovernor, pressure: MemoryPressure) void {
        // Notify pressure callbacks
        for (self.pressure_callbacks.items) |callback| {
            callback.pressure_fn(callback.context, pressure);
        }

        // Trigger spill callbacks based on pressure level
        switch (pressure) {
            .none, .low => {}, // No action needed
            .medium => {
                // Trigger low-priority spill callbacks
                for (self.spill_callbacks.items) |callback| {
                    if (callback.priority >= 200) {
                        callback.trigger_fn(callback.context);
                    }
                }
            },
            .high => {
                // Trigger medium and low-priority spill callbacks
                for (self.spill_callbacks.items) |callback| {
                    if (callback.priority >= 100) {
                        callback.trigger_fn(callback.context);
                    }
                }
            },
            .critical => {
                // Trigger all spill callbacks
                for (self.spill_callbacks.items) |callback| {
                    callback.trigger_fn(callback.context);
                }
            },
        }
    }

    /// Get detailed memory statistics
    pub fn getMemoryStats(self: *const MemoryGovernor) struct {
        current_usage: usize,
        soft_limit: usize,
        hard_limit: usize,
        utilization_percent: f64,
        pressure: MemoryPressure,
        total_allocations: usize,
        total_deallocations: usize,
        peak_usage: usize,
        active_allocations: usize,
    } {
        const StatsType = struct {
            total_allocations: usize,
            total_deallocations: usize,
            peak_usage: usize,
            active_allocations: usize,
        };

        const tracker_stats: StatsType = if (self.allocation_tracker) |tracker| StatsType{
            .total_allocations = tracker.total_allocations,
            .total_deallocations = tracker.total_deallocations,
            .peak_usage = tracker.peak_usage,
            .active_allocations = tracker.allocations.count(),
        } else StatsType{
            .total_allocations = 0,
            .total_deallocations = 0,
            .peak_usage = 0,
            .active_allocations = 0,
        };

        return .{
            .current_usage = self.currentUsage(),
            .soft_limit = self.soft_limit_bytes,
            .hard_limit = self.hard_limit_bytes,
            .utilization_percent = self.utilizationPercent(),
            .pressure = self.getMemoryPressure(),
            .total_allocations = tracker_stats.total_allocations,
            .total_deallocations = tracker_stats.total_deallocations,
            .peak_usage = tracker_stats.peak_usage,
            .active_allocations = tracker_stats.active_allocations,
        };
    }

    /// Get the largest memory allocations for debugging
    pub fn getLargestAllocations(self: *const MemoryGovernor, allocator: std.mem.Allocator, count: usize) ![]AllocationTracker.AllocationInfo {
        if (self.allocation_tracker) |tracker| {
            return tracker.getLargestAllocations(allocator, count);
        }
        return try allocator.alloc(AllocationTracker.AllocationInfo, 0);
    }
};

test "memory governor basic functionality" {
    var governor = MemoryGovernor.init(std.testing.allocator, 1024, 2048);
    defer governor.deinit();

    // Test allocation under soft limit
    const mem1 = try governor.allocate(512);
    try std.testing.expect(governor.currentUsage() == 512);
    try std.testing.expect(!governor.shouldSpill());

    // Test allocation over soft limit
    const mem2 = try governor.allocate(600);
    try std.testing.expect(governor.currentUsage() == 1112);
    try std.testing.expect(governor.shouldSpill());

    // Test deallocation
    governor.deallocate(mem1);
    try std.testing.expect(governor.currentUsage() == 600);
    try std.testing.expect(!governor.shouldSpill());

    governor.deallocate(mem2);
    try std.testing.expect(governor.currentUsage() == 0);
}

test "memory governor hard limit enforcement" {
    var governor = MemoryGovernor.init(std.testing.allocator, 1024, 2048);
    defer governor.deinit();

    // Should fail when exceeding hard limit
    try std.testing.expectError(error.OutOfMemory, governor.allocate(3000));
}

test "memory pressure detection" {
    var governor = MemoryGovernor.init(std.testing.allocator, 1000, 2000);
    defer governor.deinit();

    // Test pressure levels
    try std.testing.expect(governor.getMemoryPressure() == .none);

    const mem1 = try governor.allocate(600); // 60% utilization
    try std.testing.expect(governor.getMemoryPressure() == .medium);

    const mem2 = try governor.allocate(300); // 90% utilization
    try std.testing.expect(governor.getMemoryPressure() == .high);

    governor.deallocate(mem1);
    governor.deallocate(mem2);
}

test "memory governor with detailed tracking" {
    var governor = MemoryGovernor.initWithTracking(std.testing.allocator, 1024, 2048, true);
    defer governor.deinit();

    const mem1 = try governor.allocateWithTag(512, "test_allocation");
    const mem2 = try governor.allocateWithTag(256, "another_allocation");

    const stats = governor.getMemoryStats();
    try std.testing.expect(stats.current_usage == 768);
    try std.testing.expect(stats.total_allocations == 2);
    try std.testing.expect(stats.active_allocations == 2);

    governor.deallocate(mem1);

    const stats2 = governor.getMemoryStats();
    try std.testing.expect(stats2.current_usage == 256);
    try std.testing.expect(stats2.total_deallocations == 1);
    try std.testing.expect(stats2.active_allocations == 1);

    governor.deallocate(mem2);
}

test "priority-based spill callbacks" {
    var governor = MemoryGovernor.init(std.testing.allocator, 500, 1000);
    defer governor.deinit();

    var high_priority_called = false;
    var low_priority_called = false;

    const HighPriorityContext = struct {
        called: *bool,
        fn callback(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called.* = true;
        }
    };

    const LowPriorityContext = struct {
        called: *bool,
        fn callback(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called.* = true;
        }
    };

    var high_ctx = HighPriorityContext{ .called = &high_priority_called };
    var low_ctx = LowPriorityContext{ .called = &low_priority_called };

    try governor.registerSpillCallbackWithPriority(&high_ctx, HighPriorityContext.callback, "high_priority", 50);
    try governor.registerSpillCallbackWithPriority(&low_ctx, LowPriorityContext.callback, "low_priority", 200);

    // Allocate enough to trigger medium pressure (should only trigger low priority)
    const mem = try governor.allocate(400); // 80% of soft limit

    // In a real scenario, pressure would be detected during allocation
    // For testing, we manually trigger pressure handling
    governor.handleMemoryPressure(.medium);

    try std.testing.expect(!high_priority_called);
    try std.testing.expect(low_priority_called);

    governor.deallocate(mem);
}

test "allocation tracker largest allocations" {
    var governor = MemoryGovernor.initWithTracking(std.testing.allocator, 2048, 4096, true);
    defer governor.deinit();

    const mem1 = try governor.allocateWithTag(1000, "large_allocation");
    const mem2 = try governor.allocateWithTag(500, "medium_allocation");
    const mem3 = try governor.allocateWithTag(100, "small_allocation");

    const largest = try governor.getLargestAllocations(std.testing.allocator, 2);
    defer std.testing.allocator.free(largest);

    try std.testing.expect(largest.len == 2);
    try std.testing.expect(largest[0].size == 1000); // Largest first
    try std.testing.expect(largest[1].size == 500); // Second largest

    governor.deallocate(mem1);
    governor.deallocate(mem2);
    governor.deallocate(mem3);
}
