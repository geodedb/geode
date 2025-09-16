const std = @import("std");

/// Memory governance system to prevent OOMs with soft limits and spill triggers
pub const MemoryGovernor = struct {
    allocator: std.mem.Allocator,
    soft_limit_bytes: usize,
    hard_limit_bytes: usize,
    current_usage: std.atomic.Value(usize),
    spill_callbacks: std.ArrayList(SpillCallback),
    
    const SpillCallback = struct {
        context: *anyopaque,
        trigger_fn: *const fn (*anyopaque) void,
        name: []const u8,
    };
    
    pub fn init(allocator: std.mem.Allocator, soft_limit: usize, hard_limit: usize) MemoryGovernor {
        return .{
            .allocator = allocator,
            .soft_limit_bytes = soft_limit,
            .hard_limit_bytes = hard_limit,
            .current_usage = std.atomic.Value(usize).init(0),
            .spill_callbacks = std.ArrayList(SpillCallback).initCapacity(allocator, 0) catch @panic("OOM"),
        };
    }
    
    pub fn deinit(self: *MemoryGovernor) void {
        self.spill_callbacks.deinit(self.allocator);
    }
    
    pub fn registerSpillCallback(self: *MemoryGovernor, context: *anyopaque, trigger_fn: *const fn (*anyopaque) void, name: []const u8) !void {
        try self.spill_callbacks.append(self.allocator, .{
            .context = context,
            .trigger_fn = trigger_fn,
            .name = name,
        });
    }
    
    pub fn allocate(self: *MemoryGovernor, size: usize) ![]u8 {
        const current = self.current_usage.load(.monotonic);
        const new_usage = current + size;
        
        if (new_usage > self.hard_limit_bytes) {
            return error.OutOfMemory;
        }
        
        if (new_usage > self.soft_limit_bytes) {
            // Trigger spill callbacks
            for (self.spill_callbacks.items) |callback| {
                callback.trigger_fn(callback.context);
            }
        }
        
        const memory = try self.allocator.alloc(u8, size);
        _ = self.current_usage.fetchAdd(size, .monotonic);
        return memory;
    }
    
    pub fn deallocate(self: *MemoryGovernor, memory: []u8) void {
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