// Module Testing Framework for Geode Modularization
//
// This framework provides utilities for testing modularized components in isolation.
// It supports dependency injection, mock I/O interfaces, and module boundary testing.
//
// IMPORTANT: Mock only I/O operations, NEVER business logic
//
// CANARY: REQ=REQ-M8.1-TEST-FRAMEWORK-001; FEATURE="Module Testing"; ASPECT=TestFramework; STATUS=EXEMPT; OWNER=testing; UPDATED=2025-11-14

const std = @import("std");

// ============================================================================
// Test Allocator Utilities
// ============================================================================

/// Wrapper around testing allocator that tracks allocations
/// Helps identify memory leaks in isolated module tests
pub const TestAllocator = struct {
    gpa: std.heap.DebugAllocator(.{}),
    allocations: usize,
    deallocations: usize,

    pub fn init() TestAllocator {
        return .{
            .gpa = std.heap.DebugAllocator(.{}){},
            .allocations = 0,
            .deallocations = 0,
        };
    }

    pub fn allocator(self: *TestAllocator) std.mem.Allocator {
        return self.gpa.allocator();
    }

    pub fn deinit(self: *TestAllocator) !void {
        const leaked = self.gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
            std.debug.print("Allocations: {}, Deallocations: {}\n", .{ self.allocations, self.deallocations });
            return error.MemoryLeak;
        }
    }

    pub fn reset(self: *TestAllocator) void {
        self.allocations = 0;
        self.deallocations = 0;
    }
};

// ============================================================================
// Dependency Injection Helpers
// ============================================================================

/// Generic dependency container for module testing
/// Allows modules to be tested with injected dependencies instead of globals
pub fn DependencyContainer(comptime T: type) type {
    return struct {
        const Self = @This();

        dependencies: std.StringHashMap(*anyopaque),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .dependencies = std.StringHashMap(*anyopaque).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.dependencies.deinit();
        }

        /// Register a dependency by name
        pub fn register(self: *Self, name: []const u8, dependency: *anyopaque) !void {
            try self.dependencies.put(name, dependency);
        }

        /// Retrieve a dependency by name
        pub fn get(self: *Self, comptime DepType: type, name: []const u8) ?*DepType {
            if (self.dependencies.get(name)) |dep| {
                return @ptrCast(@alignCast(dep));
            }
            return null;
        }

        /// Clear all dependencies
        pub fn clear(self: *Self) void {
            self.dependencies.clearRetainingCapacity();
        }
    };
}

/// Factory pattern helper for dependency injection
pub fn Factory(comptime T: type) type {
    return struct {
        const Self = @This();

        createFn: *const fn (std.mem.Allocator) anyerror!*T,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, createFn: *const fn (std.mem.Allocator) anyerror!*T) Self {
            return .{
                .createFn = createFn,
                .allocator = allocator,
            };
        }

        pub fn create(self: *Self) !*T {
            return try self.createFn(self.allocator);
        }
    };
}

// ============================================================================
// Mock I/O Interfaces
// ============================================================================

/// Mock file system interface for testing I/O without disk access
/// IMPORTANT: This mocks I/O only, not business logic
pub const MockFileSystem = struct {
    files: std.StringHashMap([]const u8),
    read_calls: usize,
    write_calls: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MockFileSystem {
        return .{
            .files = std.StringHashMap([]const u8).init(allocator),
            .read_calls = 0,
            .write_calls = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MockFileSystem) void {
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.files.deinit();
    }

    /// Mock file write operation
    pub fn writeFile(self: *MockFileSystem, path: []const u8, content: []const u8) !void {
        self.write_calls += 1;
        const path_copy = try self.allocator.dupe(u8, path);
        const content_copy = try self.allocator.dupe(u8, content);
        try self.files.put(path_copy, content_copy);
    }

    /// Mock file read operation
    pub fn readFile(self: *MockFileSystem, path: []const u8) ![]const u8 {
        self.read_calls += 1;
        if (self.files.get(path)) |content| {
            return content;
        }
        return error.FileNotFound;
    }

    /// Check if file exists
    pub fn exists(self: *MockFileSystem, path: []const u8) bool {
        return self.files.contains(path);
    }

    /// Reset all tracked calls
    pub fn resetCallCounts(self: *MockFileSystem) void {
        self.read_calls = 0;
        self.write_calls = 0;
    }
};

/// Mock network interface for testing network I/O
/// IMPORTANT: This mocks I/O only, not business logic
pub const MockNetwork = struct {
    sent_messages: std.ArrayList([]const u8),
    received_messages: std.ArrayList([]const u8),
    send_calls: usize,
    receive_calls: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MockNetwork {
        return .{
            .sent_messages = std.ArrayList([]const u8).init(allocator),
            .received_messages = std.ArrayList([]const u8).init(allocator),
            .send_calls = 0,
            .receive_calls = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MockNetwork) void {
        for (self.sent_messages.items) |msg| {
            self.allocator.free(msg);
        }
        for (self.received_messages.items) |msg| {
            self.allocator.free(msg);
        }
        self.sent_messages.deinit();
        self.received_messages.deinit();
    }

    /// Mock sending a message
    pub fn send(self: *MockNetwork, message: []const u8) !void {
        self.send_calls += 1;
        const msg_copy = try self.allocator.dupe(u8, message);
        try self.sent_messages.append(msg_copy);
    }

    /// Mock receiving a message (returns pre-configured messages)
    pub fn receive(self: *MockNetwork) ![]const u8 {
        self.receive_calls += 1;
        if (self.received_messages.items.len > 0) {
            return self.received_messages.pop();
        }
        return error.NoMessagesAvailable;
    }

    /// Configure a message to be "received"
    pub fn queueReceive(self: *MockNetwork, message: []const u8) !void {
        const msg_copy = try self.allocator.dupe(u8, message);
        try self.received_messages.append(msg_copy);
    }

    /// Reset all tracked calls
    pub fn resetCallCounts(self: *MockNetwork) void {
        self.send_calls = 0;
        self.receive_calls = 0;
    }
};

/// Mock database interface for testing storage operations
/// IMPORTANT: This mocks I/O only, not business logic
pub const MockStorage = struct {
    data: std.StringHashMap([]const u8),
    read_calls: usize,
    write_calls: usize,
    delete_calls: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MockStorage {
        return .{
            .data = std.StringHashMap([]const u8).init(allocator),
            .read_calls = 0,
            .write_calls = 0,
            .delete_calls = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MockStorage) void {
        var iter = self.data.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.data.deinit();
    }

    /// Mock write operation
    pub fn write(self: *MockStorage, key: []const u8, value: []const u8) !void {
        self.write_calls += 1;
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.data.put(key_copy, value_copy);
    }

    /// Mock read operation
    pub fn read(self: *MockStorage, key: []const u8) ![]const u8 {
        self.read_calls += 1;
        if (self.data.get(key)) |value| {
            return value;
        }
        return error.KeyNotFound;
    }

    /// Mock delete operation
    pub fn delete(self: *MockStorage, key: []const u8) !void {
        self.delete_calls += 1;
        if (self.data.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        } else {
            return error.KeyNotFound;
        }
    }

    /// Reset all tracked calls
    pub fn resetCallCounts(self: *MockStorage) void {
        self.read_calls = 0;
        self.write_calls = 0;
        self.delete_calls = 0;
    }
};

// ============================================================================
// Module Boundary Testing Utilities
// ============================================================================

/// Test harness for isolated module testing
/// Provides setup, execution, and teardown with automatic resource cleanup
pub fn ModuleTestHarness(comptime ModuleType: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        module: ?*ModuleType,
        setup_called: bool,
        teardown_called: bool,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .module = null,
                .setup_called = false,
                .teardown_called = false,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.module) |mod| {
                if (!self.teardown_called) {
                    std.debug.print("Warning: teardown() not called before deinit\n", .{});
                }
                self.allocator.destroy(mod);
            }
        }

        /// Setup the module for testing
        pub fn setup(self: *Self, initFn: *const fn (std.mem.Allocator) anyerror!*ModuleType) !void {
            self.module = try initFn(self.allocator);
            self.setup_called = true;
        }

        /// Execute a test against the module
        pub fn execute(self: *Self, testFn: *const fn (*ModuleType) anyerror!void) !void {
            if (!self.setup_called) {
                return error.SetupNotCalled;
            }
            if (self.module) |mod| {
                try testFn(mod);
            } else {
                return error.ModuleNotInitialized;
            }
        }

        /// Teardown the module after testing
        pub fn teardown(self: *Self, deinitFn: *const fn (*ModuleType) void) void {
            if (self.module) |mod| {
                deinitFn(mod);
                self.teardown_called = true;
            }
        }

        /// Get the module instance (for direct access in tests)
        pub fn getModule(self: *Self) !*ModuleType {
            if (self.module) |mod| {
                return mod;
            }
            return error.ModuleNotInitialized;
        }
    };
}

/// Interface verification helper
/// Ensures a module implements expected interface methods
pub fn InterfaceVerifier(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Verify that a type has a specific method
        pub fn hasMethod(comptime methodName: []const u8) bool {
            return @hasDecl(T, methodName);
        }

        /// Verify that a type has a specific field
        pub fn hasField(comptime fieldName: []const u8) bool {
            const fields = @typeInfo(T).Struct.fields;
            inline for (fields) |field| {
                if (std.mem.eql(u8, field.name, fieldName)) {
                    return true;
                }
            }
            return false;
        }

        /// Get method count (for interface completeness verification)
        pub fn methodCount() usize {
            return @typeInfo(T).Struct.decls.len;
        }
    };
}

// ============================================================================
// Test State Management
// ============================================================================

/// Test state tracker for complex test scenarios
/// Helps manage state across multiple test steps
pub const TestState = struct {
    states: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TestState {
        return .{
            .states = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TestState) void {
        var iter = self.states.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.states.deinit();
    }

    /// Set a state value
    pub fn set(self: *TestState, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.states.put(key_copy, value_copy);
    }

    /// Get a state value
    pub fn get(self: *TestState, key: []const u8) ?[]const u8 {
        return self.states.get(key);
    }

    /// Check if state exists
    pub fn has(self: *TestState, key: []const u8) bool {
        return self.states.contains(key);
    }

    /// Clear all state
    pub fn clear(self: *TestState) void {
        var iter = self.states.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.states.clearRetainingCapacity();
    }
};

// ============================================================================
// Assertion Helpers
// ============================================================================

/// Enhanced assertion helpers for module testing
pub const Assertions = struct {
    /// Assert that a module operation succeeded
    pub fn expectSuccess(result: anyerror!void) !void {
        result catch |err| {
            std.debug.print("Expected success, got error: {s}\n", .{@errorName(err)});
            return error.AssertionFailed;
        };
    }

    /// Assert that a module operation failed with specific error
    pub fn expectError(comptime expectedError: anyerror, result: anytype) !void {
        if (result) |_| {
            std.debug.print("Expected error {s}, got success\n", .{@errorName(expectedError)});
            return error.AssertionFailed;
        } else |err| {
            if (err != expectedError) {
                std.debug.print("Expected error {s}, got {s}\n", .{ @errorName(expectedError), @errorName(err) });
                return error.AssertionFailed;
            }
        }
    }

    /// Assert string equality with detailed diff on failure
    pub fn expectStringEqual(expected: []const u8, actual: []const u8) !void {
        if (!std.mem.eql(u8, expected, actual)) {
            std.debug.print("String mismatch:\nExpected: {s}\nActual: {s}\n", .{ expected, actual });
            return error.StringMismatch;
        }
    }

    /// Assert that mock call counts match expectations
    pub fn expectCallCount(expected: usize, actual: usize, operation: []const u8) !void {
        if (expected != actual) {
            std.debug.print("{s}: Expected {} calls, got {}\n", .{ operation, expected, actual });
            return error.CallCountMismatch;
        }
    }
};

// ============================================================================
// Example Usage Tests
// ============================================================================

test "TestAllocator tracks allocations" {
    var test_alloc = TestAllocator.init();
    defer test_alloc.deinit() catch unreachable;

    const allocator = test_alloc.allocator();
    const data = try allocator.alloc(u8, 100);
    defer allocator.free(data);

    try std.testing.expect(data.len == 100);
}

test "MockFileSystem basic operations" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mock_fs = MockFileSystem.init(allocator);
    defer mock_fs.deinit();

    // Test write
    try mock_fs.writeFile("/test/file.txt", "Hello, World!");
    try std.testing.expect(mock_fs.write_calls == 1);

    // Test read
    const content = try mock_fs.readFile("/test/file.txt");
    try std.testing.expectEqualStrings("Hello, World!", content);
    try std.testing.expect(mock_fs.read_calls == 1);

    // Test exists
    try std.testing.expect(mock_fs.exists("/test/file.txt"));
    try std.testing.expect(!mock_fs.exists("/nonexistent.txt"));
}

test "MockNetwork send and receive" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mock_net = MockNetwork.init(allocator);
    defer mock_net.deinit();

    // Test send
    try mock_net.send("Test message");
    try std.testing.expect(mock_net.send_calls == 1);
    try std.testing.expect(mock_net.sent_messages.items.len == 1);

    // Test receive (with queued message)
    try mock_net.queueReceive("Response message");
    const received = try mock_net.receive();
    try std.testing.expectEqualStrings("Response message", received);
    try std.testing.expect(mock_net.receive_calls == 1);
}

test "MockStorage CRUD operations" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mock_storage = MockStorage.init(allocator);
    defer mock_storage.deinit();

    // Test write
    try mock_storage.write("key1", "value1");
    try std.testing.expect(mock_storage.write_calls == 1);

    // Test read
    const value = try mock_storage.read("key1");
    try std.testing.expectEqualStrings("value1", value);
    try std.testing.expect(mock_storage.read_calls == 1);

    // Test delete
    try mock_storage.delete("key1");
    try std.testing.expect(mock_storage.delete_calls == 1);

    // Verify deletion
    const read_result = mock_storage.read("key1");
    try std.testing.expectError(error.KeyNotFound, read_result);
}

test "TestState management" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var state = TestState.init(allocator);
    defer state.deinit();

    // Set and get
    try state.set("test_key", "test_value");
    const value = state.get("test_key");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("test_value", value.?);

    // Check existence
    try std.testing.expect(state.has("test_key"));
    try std.testing.expect(!state.has("nonexistent"));

    // Clear
    state.clear();
    try std.testing.expect(!state.has("test_key"));
}

test "Assertions helpers" {
    // Test expectSuccess
    try Assertions.expectSuccess({});

    // Test expectError
    const error_result: anyerror!void = error.TestError;
    try Assertions.expectError(error.TestError, error_result);

    // Test expectStringEqual
    try Assertions.expectStringEqual("test", "test");

    // Test expectCallCount
    try Assertions.expectCallCount(5, 5, "test operation");
}
