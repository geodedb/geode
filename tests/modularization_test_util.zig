/// Modularization Test Utilities
///
/// This module provides testing utilities specifically designed to support
/// the modularization effort. It includes:
/// - Test isolation helpers
/// - Module testing framework
/// - Dependency injection utilities
/// - Mock implementations for common interfaces
///
/// Usage in tests:
///   const mod_test = @import("modularization_test_util.zig");
///   var ctx = try mod_test.TestContext.init(testing.allocator);
///   defer ctx.deinit();
const std = @import("std");
const testing = std.testing;

// =============================================================================
// Test Context Management
// =============================================================================

/// TestContext provides isolated test environment for module testing
pub const TestContext = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    temp_dir: ?[]const u8,

    /// Initialize a new test context with isolated resources
    pub fn init(allocator: std.mem.Allocator) !TestContext {
        var arena = std.heap.ArenaAllocator.init(allocator);
        return TestContext{
            .allocator = allocator,
            .arena = arena,
            .temp_dir = null,
        };
    }

    /// Create a temporary directory for test data isolation
    pub fn createTempDir(self: *TestContext) ![]const u8 {
        if (self.temp_dir) |dir| return dir;

        const tmp = try self.arena.allocator().dupe(u8, "/tmp/geode_test_XXXXXX");
        // Note: In real implementation, mkdtemp would be called
        // For now, create a unique dir name
        const timestamp = std.time.milliTimestamp();
        const dir_name = try std.fmt.allocPrint(self.arena.allocator(), "/tmp/geode_test_{d}", .{timestamp});

        std.fs.cwd().makeDir(dir_name) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        self.temp_dir = dir_name;
        return dir_name;
    }

    /// Get arena allocator for temporary test allocations
    pub fn arenaAllocator(self: *TestContext) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Clean up all test resources
    pub fn deinit(self: *TestContext) void {
        // Clean up temp directory if created
        if (self.temp_dir) |dir| {
            std.fs.cwd().deleteTree(dir) catch |err| {
                std.debug.print("Warning: Failed to clean up test dir {s}: {}\n", .{ dir, err });
            };
        }
        self.arena.deinit();
    }
};

// =============================================================================
// Mock Allocator with Tracking
// =============================================================================

/// TrackedAllocator wraps an allocator to track allocations for leak detection
pub const TrackedAllocator = struct {
    parent: std.mem.Allocator,
    allocations: std.ArrayList(AllocationInfo),
    total_allocated: usize,
    total_freed: usize,
    peak_memory: usize,
    mutex: std.Thread.Mutex,

    const AllocationInfo = struct {
        ptr: usize,
        size: usize,
        freed: bool,
    };

    pub fn init(parent: std.mem.Allocator) !TrackedAllocator {
        return TrackedAllocator{
            .parent = parent,
            .allocations = std.ArrayList(AllocationInfo).init(parent),
            .total_allocated = 0,
            .total_freed = 0,
            .peak_memory = 0,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn allocator(self: *TrackedAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = self.parent.rawAlloc(len, ptr_align, ret_addr) orelse return null;

        const ptr_value = @intFromPtr(result);
        self.allocations.append(.{
            .ptr = ptr_value,
            .size = len,
            .freed = false,
        }) catch return result; // Don't fail allocation if tracking fails

        self.total_allocated += len;
        const current = self.total_allocated - self.total_freed;
        if (current > self.peak_memory) {
            self.peak_memory = current;
        }

        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const ptr_value = @intFromPtr(buf.ptr);
        for (self.allocations.items) |*alloc| {
            if (alloc.ptr == ptr_value and !alloc.freed) {
                alloc.freed = true;
                self.total_freed += buf.len;
                break;
            }
        }

        self.parent.rawFree(buf, buf_align, ret_addr);
    }

    /// Check for memory leaks
    pub fn checkLeaks(self: *TrackedAllocator) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var leaked: usize = 0;
        for (self.allocations.items) |alloc| {
            if (!alloc.freed) {
                leaked += alloc.size;
            }
        }

        if (leaked > 0) {
            std.debug.print("Memory leak detected: {d} bytes leaked\n", .{leaked});
            return error.MemoryLeak;
        }
    }

    /// Get memory statistics
    pub fn getStats(self: *TrackedAllocator) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();

        return Stats{
            .total_allocated = self.total_allocated,
            .total_freed = self.total_freed,
            .peak_memory = self.peak_memory,
            .current_memory = self.total_allocated - self.total_freed,
        };
    }

    pub const Stats = struct {
        total_allocated: usize,
        total_freed: usize,
        peak_memory: usize,
        current_memory: usize,
    };

    pub fn deinit(self: *TrackedAllocator) void {
        self.allocations.deinit();
    }
};

// =============================================================================
// Dependency Injection Framework
// =============================================================================

/// Interface for injectable dependencies
/// Modules can define their dependencies using this pattern
pub fn DependencyInterface(comptime T: type) type {
    return struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        const VTable = T;

        pub fn init(implementation: anytype) @This() {
            const Impl = @TypeOf(implementation);
            const impl_ptr = @as(*anyopaque, @ptrCast(@constCast(implementation)));

            return .{
                .ptr = impl_ptr,
                .vtable = comptime &createVTable(Impl),
            };
        }

        fn createVTable(comptime Impl: type) VTable {
            var vtable: VTable = undefined;
            inline for (std.meta.fields(VTable)) |field| {
                @field(vtable, field.name) = @field(Impl, field.name);
            }
            return vtable;
        }
    };
}

/// Mock implementation builder for testing
pub fn MockBuilder(comptime Interface: type) type {
    return struct {
        const Self = @This();

        call_count: usize = 0,
        return_value: ?Interface = null,
        error_to_return: ?anyerror = null,

        pub fn init() Self {
            return Self{};
        }

        pub fn withReturnValue(self: *Self, value: Interface) *Self {
            self.return_value = value;
            return self;
        }

        pub fn withError(self: *Self, err: anyerror) *Self {
            self.error_to_return = err;
            return self;
        }

        pub fn callCount(self: *const Self) usize {
            return self.call_count;
        }

        pub fn wasCalled(self: *const Self) bool {
            return self.call_count > 0;
        }

        pub fn reset(self: *Self) void {
            self.call_count = 0;
            self.return_value = null;
            self.error_to_return = null;
        }
    };
}

// =============================================================================
// Module Testing Helpers
// =============================================================================

/// Helper to create isolated module test
pub fn moduleTest(comptime name: []const u8, comptime test_fn: fn (*TestContext) anyerror!void) fn () anyerror!void {
    return struct {
        fn run() anyerror!void {
            var ctx = try TestContext.init(testing.allocator);
            defer ctx.deinit();

            std.debug.print("Running module test: {s}\n", .{name});
            try test_fn(&ctx);
            std.debug.print("✓ {s} passed\n", .{name});
        }
    }.run;
}

/// Assert that a module interface is correctly implemented
pub fn assertInterfaceComplete(comptime Interface: type, comptime Implementation: type) !void {
    // Compile-time check that all interface methods are implemented
    inline for (std.meta.declarations(Interface)) |decl| {
        if (!@hasDecl(Implementation, decl.name)) {
            @compileError("Implementation missing: " ++ decl.name);
        }
    }
}

// =============================================================================
// Test Fixtures
// =============================================================================

/// Fixture management for test data
pub const Fixture = struct {
    ctx: *TestContext,
    data: std.StringHashMap([]const u8),

    pub fn init(ctx: *TestContext) Fixture {
        return Fixture{
            .ctx = ctx,
            .data = std.StringHashMap([]const u8).init(ctx.arenaAllocator()),
        };
    }

    pub fn set(self: *Fixture, key: []const u8, value: []const u8) !void {
        const key_copy = try self.ctx.arenaAllocator().dupe(u8, key);
        const value_copy = try self.ctx.arenaAllocator().dupe(u8, value);
        try self.data.put(key_copy, value_copy);
    }

    pub fn get(self: *Fixture, key: []const u8) ?[]const u8 {
        return self.data.get(key);
    }

    pub fn deinit(self: *Fixture) void {
        self.data.deinit();
    }
};

// =============================================================================
// State Verification Helpers
// =============================================================================

/// Helper to verify module state after operations
pub const StateVerifier = struct {
    checks: std.ArrayList(Check),
    allocator: std.mem.Allocator,

    const Check = struct {
        name: []const u8,
        passed: bool,
        message: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) StateVerifier {
        return StateVerifier{
            .checks = std.ArrayList(Check).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn addCheck(self: *StateVerifier, name: []const u8, passed: bool, message: []const u8) !void {
        try self.checks.append(.{
            .name = try self.allocator.dupe(u8, name),
            .passed = passed,
            .message = try self.allocator.dupe(u8, message),
        });
    }

    pub fn verify(self: *StateVerifier) !void {
        var failed: usize = 0;
        for (self.checks.items) |check| {
            if (!check.passed) {
                std.debug.print("✗ {s}: {s}\n", .{ check.name, check.message });
                failed += 1;
            } else {
                std.debug.print("✓ {s}\n", .{check.name});
            }
        }

        if (failed > 0) {
            std.debug.print("\n{d}/{d} checks failed\n", .{ failed, self.checks.items.len });
            return error.VerificationFailed;
        }
    }

    pub fn deinit(self: *StateVerifier) void {
        for (self.checks.items) |check| {
            self.allocator.free(check.name);
            self.allocator.free(check.message);
        }
        self.checks.deinit();
    }
};

// =============================================================================
// Example Usage Tests
// =============================================================================

test "TestContext basic usage" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    const temp_dir = try ctx.createTempDir();
    try testing.expect(temp_dir.len > 0);
}

test "TrackedAllocator memory tracking" {
    var tracked = try TrackedAllocator.init(testing.allocator);
    defer tracked.deinit();

    const alloc = tracked.allocator();

    const ptr1 = try alloc.alloc(u8, 100);
    defer alloc.free(ptr1);

    const stats = tracked.getStats();
    try testing.expect(stats.total_allocated >= 100);
    try testing.expect(stats.current_memory >= 100);
}

test "Fixture data management" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var fixture = Fixture.init(&ctx);
    defer fixture.deinit();

    try fixture.set("key1", "value1");
    try fixture.set("key2", "value2");

    const val1 = fixture.get("key1");
    try testing.expect(val1 != null);
    try testing.expectEqualStrings("value1", val1.?);
}

test "StateVerifier validation" {
    var verifier = StateVerifier.init(testing.allocator);
    defer verifier.deinit();

    try verifier.addCheck("check1", true, "passed");
    try verifier.addCheck("check2", true, "passed");

    try verifier.verify();
}
