/// Sample Module Test
///
/// This test demonstrates how to use the modularization test utilities
/// to test modules in isolation. It serves as both documentation and
/// verification that the test utilities work correctly.

const std = @import("std");
const testing = std.testing;
const mod_test = @import("modularization_test_util.zig");

// =============================================================================
// Sample Module Interface
// =============================================================================

/// Example interface that a module might implement
const StorageInterface = struct {
    writeFn: *const fn(*anyopaque, []const u8, []const u8) anyerror!void,
    readFn: *const fn(*anyopaque, []const u8) anyerror![]const u8,
    deleteFn: *const fn(*anyopaque, []const u8) anyerror!void,
};

// =============================================================================
// Sample Module Implementation
// =============================================================================

/// Sample storage module (simplified example)
const SampleStorage = struct {
    allocator: std.mem.Allocator,
    data: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) SampleStorage {
        return SampleStorage{
            .allocator = allocator,
            .data = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn write(ctx: *anyopaque, key: []const u8, value: []const u8) anyerror!void {
        const self: *SampleStorage = @ptrCast(@alignCast(ctx));
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.data.put(key_copy, value_copy);
    }

    pub fn read(ctx: *anyopaque, key: []const u8) anyerror![]const u8 {
        const self: *SampleStorage = @ptrCast(@alignCast(ctx));
        return self.data.get(key) orelse error.KeyNotFound;
    }

    pub fn delete(ctx: *anyopaque, key: []const u8) anyerror!void {
        const self: *SampleStorage = @ptrCast(@alignCast(ctx));
        _ = self.data.remove(key);
    }

    pub fn interface(self: *SampleStorage) mod_test.DependencyInterface(StorageInterface) {
        return mod_test.DependencyInterface(StorageInterface).init(self);
    }

    pub fn deinit(self: *SampleStorage) void {
        var it = self.data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.data.deinit();
    }
};

// =============================================================================
// Mock Implementation for Testing
// =============================================================================

/// Mock storage for testing modules that depend on storage
const MockStorage = struct {
    calls: std.ArrayList(Call),
    allocator: std.mem.Allocator,
    write_error: ?anyerror = null,
    read_return: ?[]const u8 = null,

    const Call = union(enum) {
        write: struct { key: []const u8, value: []const u8 },
        read: []const u8,
        delete: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) MockStorage {
        return MockStorage{
            .calls = std.ArrayList(Call).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn write(ctx: *anyopaque, key: []const u8, value: []const u8) anyerror!void {
        const self: *MockStorage = @ptrCast(@alignCast(ctx));
        try self.calls.append(.{ .write = .{ .key = key, .value = value } });
        if (self.write_error) |err| return err;
    }

    pub fn read(ctx: *anyopaque, key: []const u8) anyerror![]const u8 {
        const self: *MockStorage = @ptrCast(@alignCast(ctx));
        try self.calls.append(.{ .read = key });
        return self.read_return orelse error.KeyNotFound;
    }

    pub fn delete(ctx: *anyopaque, key: []const u8) anyerror!void {
        const self: *MockStorage = @ptrCast(@alignCast(ctx));
        try self.calls.append(.{ .delete = key });
    }

    pub fn interface(self: *MockStorage) mod_test.DependencyInterface(StorageInterface) {
        return mod_test.DependencyInterface(StorageInterface).init(self);
    }

    pub fn wasCalled(self: *const MockStorage, expected: Call) bool {
        for (self.calls.items) |call| {
            switch (expected) {
                .write => |exp| {
                    if (call == .write) {
                        if (std.mem.eql(u8, call.write.key, exp.key) and
                            std.mem.eql(u8, call.write.value, exp.value)) {
                            return true;
                        }
                    }
                },
                .read => |exp| {
                    if (call == .read and std.mem.eql(u8, call.read, exp)) {
                        return true;
                    }
                },
                .delete => |exp| {
                    if (call == .delete and std.mem.eql(u8, call.delete, exp)) {
                        return true;
                    }
                },
            }
        }
        return false;
    }

    pub fn deinit(self: *MockStorage) void {
        self.calls.deinit();
    }
};

// =============================================================================
// Test Cases
// =============================================================================

test "Module test with TestContext" {
    var ctx = try mod_test.TestContext.init(testing.allocator);
    defer ctx.deinit();

    // Create temporary directory for module data
    const temp_dir = try ctx.createTempDir();
    try testing.expect(temp_dir.len > 0);

    // Use arena allocator for test-specific allocations
    const alloc = ctx.arenaAllocator();
    const test_data = try alloc.dupe(u8, "test_data");
    try testing.expectEqualStrings("test_data", test_data);
}

test "Module with dependency injection" {
    var ctx = try mod_test.TestContext.init(testing.allocator);
    defer ctx.deinit();

    // Create real storage implementation
    var storage = SampleStorage.init(ctx.arenaAllocator());
    defer storage.deinit();

    // Test through interface
    var storage_iface = storage.interface();
    try storage_iface.vtable.writeFn(storage_iface.ptr, "key1", "value1");

    const value = try storage_iface.vtable.readFn(storage_iface.ptr, "key1");
    try testing.expectEqualStrings("value1", value);
}

test "Module with mock dependencies" {
    var ctx = try mod_test.TestContext.init(testing.allocator);
    defer ctx.deinit();

    // Create mock storage
    var mock = MockStorage.init(ctx.arenaAllocator());
    defer mock.deinit();
    mock.read_return = "mock_value";

    // Test through interface
    var mock_iface = mock.interface();

    // Perform operations
    try mock_iface.vtable.writeFn(mock_iface.ptr, "key1", "value1");
    const value = try mock_iface.vtable.readFn(mock_iface.ptr, "key1");
    try mock_iface.vtable.deleteFn(mock_iface.ptr, "key1");

    // Verify mock was called correctly
    try testing.expect(mock.wasCalled(.{ .write = .{ .key = "key1", .value = "value1" } }));
    try testing.expect(mock.wasCalled(.{ .read = "key1" }));
    try testing.expect(mock.wasCalled(.{ .delete = "key1" }));
    try testing.expectEqualStrings("mock_value", value);
}

test "TrackedAllocator for leak detection" {
    var tracked = try mod_test.TrackedAllocator.init(testing.allocator);
    defer tracked.deinit();

    const alloc = tracked.allocator();

    // Allocate and free memory
    const ptr1 = try alloc.alloc(u8, 100);
    const ptr2 = try alloc.alloc(u8, 200);

    alloc.free(ptr1);
    alloc.free(ptr2);

    // Should not leak
    try tracked.checkLeaks();

    // Verify statistics
    const stats = tracked.getStats();
    try testing.expect(stats.total_allocated >= 300);
    try testing.expect(stats.total_freed >= 300);
    try testing.expect(stats.current_memory == 0);
}

test "Fixture management" {
    var ctx = try mod_test.TestContext.init(testing.allocator);
    defer ctx.deinit();

    var fixture = mod_test.Fixture.init(&ctx);
    defer fixture.deinit();

    // Set up test fixtures
    try fixture.set("api_key", "test_key_123");
    try fixture.set("endpoint", "http://localhost:3141");

    // Use fixtures in test
    const api_key = fixture.get("api_key");
    try testing.expect(api_key != null);
    try testing.expectEqualStrings("test_key_123", api_key.?);
}

test "StateVerifier for module state validation" {
    var verifier = mod_test.StateVerifier.init(testing.allocator);
    defer verifier.deinit();

    // Perform operations on a module
    var storage = SampleStorage.init(testing.allocator);
    defer storage.deinit();

    try storage.write(&storage, "key1", "value1");
    try storage.write(&storage, "key2", "value2");

    // Verify module state
    const val1 = try storage.read(&storage, "key1");
    try verifier.addCheck("key1 exists", true, "value found");
    try verifier.addCheck("key1 correct", std.mem.eql(u8, val1, "value1"), "value matches");

    const val2 = try storage.read(&storage, "key2");
    try verifier.addCheck("key2 exists", true, "value found");
    try verifier.addCheck("key2 correct", std.mem.eql(u8, val2, "value2"), "value matches");

    try verifier.verify();
}

test "Memory leak detection" {
    var tracked = try mod_test.TrackedAllocator.init(testing.allocator);
    defer tracked.deinit();

    const alloc = tracked.allocator();

    // Allocate but don't free (simulating a leak)
    const ptr1 = try alloc.alloc(u8, 100);
    _ = ptr1;
    // Intentionally not freeing

    // This should detect the leak
    const result = tracked.checkLeaks();
    try testing.expectError(error.MemoryLeak, result);
}
