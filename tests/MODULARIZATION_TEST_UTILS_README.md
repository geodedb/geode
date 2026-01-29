# Modularization Test Utilities

## Overview

This directory contains test utilities specifically designed to support the Geode codebase modularization effort. These utilities make it easier to test modules in isolation, manage dependencies, and verify module behavior during refactoring.

## Files

### Core Utilities

- **`modularization_test_util.zig`** - Main test utilities library
- **`modularization_sample_test.zig`** - Example tests demonstrating usage
- **`MODULARIZATION_TEST_UTILS_README.md`** - This file

## Components

### 1. Test Context Management (`TestContext`)

Provides isolated test environments for module testing:

```zig
const mod_test = @import("modularization_test_util.zig");

test "example" {
    var ctx = try mod_test.TestContext.init(testing.allocator);
    defer ctx.deinit();

    // Create temporary directory for test data
    const temp_dir = try ctx.createTempDir();

    // Use arena allocator for test allocations
    const alloc = ctx.arenaAllocator();
}
```

**Features**:

- Automatic cleanup of resources
- Temporary directory creation
- Arena allocator for test-scoped allocations

### 2. Memory Tracking (`TrackedAllocator`)

Tracks allocations to detect memory leaks during testing:

```zig
test "memory tracking" {
    var tracked = try mod_test.TrackedAllocator.init(testing.allocator);
    defer tracked.deinit();

    const alloc = tracked.allocator();

    const ptr = try alloc.alloc(u8, 100);
    defer alloc.free(ptr);

    // Verify no leaks
    try tracked.checkLeaks();

    // Get statistics
    const stats = tracked.getStats();
    // stats.total_allocated, stats.peak_memory, etc.
}
```

**Features**:

- Tracks all allocations and frees
- Detects memory leaks
- Provides memory usage statistics
- Thread-safe tracking

### 3. Dependency Injection (`DependencyInterface`)

Framework for injecting dependencies during testing:

```zig
// Define interface
const StorageInterface = struct {
    writeFn: *const fn(*anyopaque, []const u8, []const u8) anyerror!void,
    readFn: *const fn(*anyopaque, []const u8) anyerror![]const u8,
};

// Real implementation
const RealStorage = struct {
    pub fn write(ctx: *anyopaque, key: []const u8, value: []const u8) anyerror!void {
        // Implementation
    }

    pub fn read(ctx: *anyopaque, key: []const u8) anyerror![]const u8 {
        // Implementation
    }

    pub fn interface(self: *RealStorage) mod_test.DependencyInterface(StorageInterface) {
        return mod_test.DependencyInterface(StorageInterface).init(self);
    }
};

// Mock implementation for testing
const MockStorage = struct {
    pub fn write(ctx: *anyopaque, key: []const u8, value: []const u8) anyerror!void {
        // Mock implementation
    }

    pub fn read(ctx: *anyopaque, key: []const u8) anyerror![]const u8 {
        return "mock_value";
    }

    pub fn interface(self: *MockStorage) mod_test.DependencyInterface(StorageInterface) {
        return mod_test.DependencyInterface(StorageInterface).init(self);
    }
};

test "with dependency injection" {
    var ctx = try mod_test.TestContext.init(testing.allocator);
    defer ctx.deinit();

    // Use mock in tests
    var mock = MockStorage.init(ctx.arenaAllocator());
    var storage_iface = mock.interface();

    // Module under test uses the interface
    try storage_iface.vtable.writeFn(storage_iface.ptr, "key", "value");
}
```

**Features**:

- Type-safe dependency injection
- Easy mocking for tests
- Interface verification

### 4. Test Fixtures (`Fixture`)

Manage test data and configuration:

```zig
test "with fixtures" {
    var ctx = try mod_test.TestContext.init(testing.allocator);
    defer ctx.deinit();

    var fixture = mod_test.Fixture.init(&ctx);
    defer fixture.deinit();

    // Set up test data
    try fixture.set("api_key", "test_key_123");
    try fixture.set("endpoint", "http://localhost:3141");

    // Use in test
    const api_key = fixture.get("api_key");
}
```

**Features**:

- Key-value fixture storage
- Automatic memory management
- Easy setup/teardown

### 5. State Verification (`StateVerifier`)

Verify module state after operations:

```zig
test "state verification" {
    var verifier = mod_test.StateVerifier.init(testing.allocator);
    defer verifier.deinit();

    // Perform operations
    // ...

    // Add verification checks
    try verifier.addCheck("key1 exists", true, "value found");
    try verifier.addCheck("key1 correct", condition, "value matches");

    // Verify all checks
    try verifier.verify(); // Fails if any check failed
}
```

**Features**:

- Multiple check accumulation
- Detailed failure messages
- Visual output for debugging

### 6. Module Testing Helper (`moduleTest`)

Convenience wrapper for module tests:

```zig
const testModuleX = mod_test.moduleTest("Module X", testModuleXImpl);

fn testModuleXImpl(ctx: *mod_test.TestContext) !void {
    // Test implementation
}
```

**Features**:

- Automatic context setup/teardown
- Named tests for better output
- Cleaner test organization

## Usage Patterns

### Pattern 1: Testing Module in Isolation

```zig
test "module isolation" {
    var ctx = try mod_test.TestContext.init(testing.allocator);
    defer ctx.deinit();

    // Create module with test allocator
    var module = MyModule.init(ctx.arenaAllocator());
    defer module.deinit();

    // Test module behavior
    try module.someOperation();

    // Verify state
    try testing.expect(module.someCondition());
}
```

### Pattern 2: Testing with Mock Dependencies

```zig
test "with mocks" {
    var ctx = try mod_test.TestContext.init(testing.allocator);
    defer ctx.deinit();

    // Create mocks
    var mock_storage = MockStorage.init(ctx.arenaAllocator());
    var mock_network = MockNetwork.init(ctx.arenaAllocator());

    // Create module with mocks
    var module = MyModule.init(
        ctx.arenaAllocator(),
        mock_storage.interface(),
        mock_network.interface()
    );
    defer module.deinit();

    // Test
    try module.processData();

    // Verify mocks were called correctly
    try testing.expect(mock_storage.wasCalled(.write));
}
```

### Pattern 3: Memory Leak Detection

```zig
test "no memory leaks" {
    var tracked = try mod_test.TrackedAllocator.init(testing.allocator);
    defer tracked.deinit();

    const alloc = tracked.allocator();

    // Create and use module
    var module = MyModule.init(alloc);
    defer module.deinit();

    try module.doWork();

    // Verify no leaks
    try tracked.checkLeaks();
}
```

## Running Tests

To run the modularization test utilities:

```bash
# Run modularization utils tests
zig test tests/modularization_test_util.zig

# Run sample tests
zig test tests/modularization_sample_test.zig

# Run specific test
zig test tests/modularization_test_util.zig --test-filter "TestContext"
```

## Integration with Modularization Phases

These utilities are designed to support the modularization phases:

### Phase 1: Extract Mixed Concerns

- Use `TestContext` for isolated module testing
- Use `DependencyInterface` to separate logic from I/O

### Phase 2-4: Decompose Large Modules

- Use `TrackedAllocator` to detect memory leaks during refactoring
- Use `StateVerifier` to ensure functionality preserved

### Phase 5: Resolve Circular Dependencies

- Use `DependencyInterface` to break circular dependencies
- Use mocks to test modules independently

### Phase 6-8: Final Refactoring

- Use full suite for comprehensive module testing
- Use `Fixture` for complex test scenarios

## Best Practices

1. **Always use TestContext** for module tests
   - Provides cleanup guarantees
   - Isolates test resources

2. **Track memory in refactoring tests**
   - Use `TrackedAllocator` during major refactoring
   - Helps catch leaks early

3. **Mock external dependencies**
   - Use `DependencyInterface` for testability
   - Makes tests faster and more reliable

4. **Verify state explicitly**
   - Use `StateVerifier` for complex state
   - Makes test failures clearer

5. **Use fixtures for complex setups**
   - Centralize test data
   - Makes tests more maintainable

## Examples

See `modularization_sample_test.zig` for complete working examples of:

- Module testing with TestContext
- Dependency injection with real and mock implementations
- Memory leak detection
- Fixture management
- State verification

## Support

For questions or issues with test utilities:

- Check example tests in `modularization_sample_test.zig`
- Review modularization plan in `docs/MODULARIZATION_PLAN.md`
- See status in `docs/MODULARIZATION_STATUS.md`

## Version

**Version**: 1.0
**Created**: 2025-11-12
**Phase**: Phase 0, M0.3 - Create Test Utilities
**Status**: Complete
