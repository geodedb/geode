# Geode Module Testing Guide

**Created**: 2025-11-14
**Purpose**: Guide for testing modularized components in the Geode codebase
**Framework**: `tests/module_test_framework.zig`

---

## Overview

This guide explains how to test modularized components in Geode using the module testing framework. The framework provides utilities for isolated module testing, dependency injection, and mock I/O interfaces.

### Key Principles

1. **Test modules in isolation** - Each module should be testable independently
2. **Use dependency injection** - Inject dependencies rather than using globals
3. **Mock I/O only, never business logic** - Only mock file, network, and storage operations
4. **Verify module boundaries** - Ensure interfaces are correctly implemented
5. **Track memory usage** - Detect memory leaks in module tests

---

## Quick Start

### Basic Module Test

```zig
const std = @import("std");
const testing = std.testing;
const framework = @import("module_test_framework.zig");

test "schema_manager creates schema" {
    // 1. Create test allocator
    var test_alloc = framework.TestAllocator.init();
    defer test_alloc.deinit() catch unreachable;
    const allocator = test_alloc.allocator();

    // 2. Initialize module
    const schema = @import("../src/schema/schema_manager.zig");
    var manager = try schema.SchemaManager.init(allocator, "/tmp/test");
    defer manager.deinit();

    // 3. Test module operation
    try manager.createSchema("test_schema");

    // 4. Verify result
    try testing.expect(manager.schemaExists("test_schema"));
}
```

---

## Framework Components

### 1. Test Allocator

`TestAllocator` tracks allocations and detects memory leaks.

**Usage**:
```zig
var test_alloc = framework.TestAllocator.init();
defer test_alloc.deinit() catch unreachable; // Will fail if memory leaked
const allocator = test_alloc.allocator();

// Use allocator in tests
const data = try allocator.alloc(u8, 100);
defer allocator.free(data);
```

**Benefits**:
- Automatic leak detection
- Allocation tracking
- Clear error messages on leaks

---

### 2. Dependency Injection

#### DependencyContainer

Manages dependencies for module testing.

**Example - Testing TransactionManager**:
```zig
test "transaction_manager with injected dependencies" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create dependency container
    var deps = framework.DependencyContainer(void).init(allocator);
    defer deps.deinit();

    // Register mock WAL
    var mock_wal = MockWalHandle{};
    try deps.register("wal", @ptrCast(&mock_wal));

    // Test with injected dependencies
    const transactions = @import("../src/transactions/transaction_manager.zig");
    var manager = try transactions.TransactionManager.init(allocator, false, false);
    defer manager.deinit();

    // Register WAL dependency
    if (deps.get(MockWalHandle, "wal")) |wal| {
        manager.registerWalHandle(wal);
    }

    // Test operations
    const txn_id = try manager.begin();
    try manager.commit(txn_id);
}
```

#### Factory Pattern

Create module instances with consistent initialization.

**Example**:
```zig
const SchemaManagerFactory = framework.Factory(schema.SchemaManager);

fn createSchemaManager(allocator: std.mem.Allocator) !*schema.SchemaManager {
    const mgr = try allocator.create(schema.SchemaManager);
    mgr.* = try schema.SchemaManager.init(allocator, "/tmp/test");
    return mgr;
}

test "factory pattern for schema manager" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var factory = SchemaManagerFactory.init(allocator, createSchemaManager);
    const manager = try factory.create();
    defer {
        manager.deinit();
        allocator.destroy(manager);
    }

    // Test with factory-created instance
    try manager.createSchema("test");
    try testing.expect(manager.schemaExists("test"));
}
```

---

### 3. Mock I/O Interfaces

#### MockFileSystem

Mock file operations for testing without disk I/O.

**Example - Testing Audit Module**:
```zig
test "audit module writes to mock filesystem" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create mock filesystem
    var mock_fs = framework.MockFileSystem.init(allocator);
    defer mock_fs.deinit();

    // Test audit write
    const audit = @import("../src/security/audit.zig");
    // Inject mock filesystem into audit module
    // (requires audit module to support dependency injection)

    // Write audit event
    try mock_fs.writeFile("/var/log/audit.log", "User login event");

    // Verify write occurred
    try framework.Assertions.expectCallCount(1, mock_fs.write_calls, "writeFile");

    // Verify content
    const content = try mock_fs.readFile("/var/log/audit.log");
    try framework.Assertions.expectStringEqual("User login event", content);
}
```

**API**:
- `writeFile(path, content)` - Mock file write
- `readFile(path)` - Mock file read
- `exists(path)` - Check if file exists
- `resetCallCounts()` - Reset operation counters
- `write_calls`, `read_calls` - Operation counts

#### MockNetwork

Mock network operations for protocol testing.

**Example - Testing Protocol Handler**:
```zig
test "protocol handler sends correct response" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mock_net = framework.MockNetwork.init(allocator);
    defer mock_net.deinit();

    // Queue a request message
    try mock_net.queueReceive("HELLO{\"client\":\"test\"}");

    // Process request (with mocked network)
    const request = try mock_net.receive();
    try testing.expectEqualStrings("HELLO{\"client\":\"test\"}", request);

    // Send response
    try mock_net.send("OK{\"status\":\"connected\"}");

    // Verify send occurred
    try framework.Assertions.expectCallCount(1, mock_net.send_calls, "send");
    try testing.expect(mock_net.sent_messages.items.len == 1);
}
```

**API**:
- `send(message)` - Mock sending a message
- `receive()` - Mock receiving a message
- `queueReceive(message)` - Configure message to be received
- `resetCallCounts()` - Reset operation counters
- `send_calls`, `receive_calls` - Operation counts

#### MockStorage

Mock storage operations for testing without database.

**Example - Testing Storage Manager**:
```zig
test "graph_storage_manager with mock storage" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mock_storage = framework.MockStorage.init(allocator);
    defer mock_storage.deinit();

    // Test write
    try mock_storage.write("node:1", "{\"id\":1,\"label\":\"Person\"}");
    try framework.Assertions.expectCallCount(1, mock_storage.write_calls, "write");

    // Test read
    const data = try mock_storage.read("node:1");
    try framework.Assertions.expectStringEqual("{\"id\":1,\"label\":\"Person\"}", data);

    // Test delete
    try mock_storage.delete("node:1");
    try framework.Assertions.expectCallCount(1, mock_storage.delete_calls, "delete");

    // Verify deletion
    const read_result = mock_storage.read("node:1");
    try framework.Assertions.expectError(error.KeyNotFound, read_result);
}
```

**API**:
- `write(key, value)` - Mock storage write
- `read(key)` - Mock storage read
- `delete(key)` - Mock storage delete
- `resetCallCounts()` - Reset operation counters
- `write_calls`, `read_calls`, `delete_calls` - Operation counts

---

### 4. Module Test Harness

`ModuleTestHarness` provides structured setup/execute/teardown pattern.

**Example - Testing Query Executor**:
```zig
test "query_executor module harness" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const QueryExecutor = @import("../src/server/query_executor.zig").QueryExecutor;
    var harness = framework.ModuleTestHarness(QueryExecutor).init(allocator);
    defer harness.deinit();

    // Setup
    try harness.setup(QueryExecutor.init);

    // Execute test
    try harness.execute(struct {
        fn testFn(executor: *QueryExecutor) !void {
            // Test query execution
            const result = try executor.evaluateSimpleQuery(...);
            try testing.expect(result != null);
        }
    }.testFn);

    // Teardown
    harness.teardown(QueryExecutor.deinit);
}
```

**Benefits**:
- Automatic setup/teardown tracking
- Warns if teardown not called
- Clean resource management
- Structured test flow

---

### 5. Interface Verification

`InterfaceVerifier` ensures modules implement expected interfaces.

**Example - Verifying SchemaManager Interface**:
```zig
test "schema_manager implements required interface" {
    const schema = @import("../src/schema/schema_manager.zig");
    const SchemaManager = schema.SchemaManager;

    const verifier = framework.InterfaceVerifier(SchemaManager);

    // Verify required methods exist
    try testing.expect(verifier.hasMethod("init"));
    try testing.expect(verifier.hasMethod("deinit"));
    try testing.expect(verifier.hasMethod("createSchema"));
    try testing.expect(verifier.hasMethod("schemaExists"));
    try testing.expect(verifier.hasMethod("createGraph"));
    try testing.expect(verifier.hasMethod("graphExists"));

    // Verify required fields exist
    try testing.expect(verifier.hasField("allocator"));
    try testing.expect(verifier.hasField("db_catalog"));
    try testing.expect(verifier.hasField("fle_catalog"));
}
```

**Use Cases**:
- Contract verification
- API completeness checking
- Interface compliance testing
- Module boundary validation

---

### 6. Test State Management

`TestState` helps manage complex test scenarios with multiple steps.

**Example - Multi-Step Transaction Test**:
```zig
test "complex transaction workflow" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var state = framework.TestState.init(allocator);
    defer state.deinit();

    const transactions = @import("../src/transactions/transaction_manager.zig");
    var manager = try transactions.TransactionManager.init(allocator, false, false);
    defer manager.deinit();

    // Step 1: Begin transaction
    const txn_id = try manager.begin();
    try state.set("txn_id", try std.fmt.allocPrint(allocator, "{d}", .{txn_id}));

    // Step 2: Acquire locks
    try manager.acquireLock(txn_id, "key1", .Exclusive);
    try state.set("locked_key", "key1");

    // Step 3: Verify state
    try testing.expect(state.has("txn_id"));
    try testing.expect(state.has("locked_key"));

    // Step 4: Commit
    try manager.commit(txn_id);
    try state.set("committed", "true");

    // Verify final state
    try testing.expectEqualStrings("true", state.get("committed").?);
}
```

---

### 7. Enhanced Assertions

`Assertions` provides module-specific assertion helpers.

**API**:

#### expectSuccess
```zig
// Verify operation succeeded
const result = module.someOperation();
try framework.Assertions.expectSuccess(result);
```

#### expectError
```zig
// Verify specific error was returned
const result = module.failingOperation();
try framework.Assertions.expectError(error.ExpectedError, result);
```

#### expectStringEqual
```zig
// String comparison with detailed diff
const expected = "Hello, World!";
const actual = module.getMessage();
try framework.Assertions.expectStringEqual(expected, actual);
```

#### expectCallCount
```zig
// Verify mock was called expected number of times
try framework.Assertions.expectCallCount(3, mock_fs.write_calls, "writeFile");
```

---

## Testing Patterns

### Pattern 1: Isolated Module Testing

Test a single module without dependencies.

```zig
test "type_promotion module isolated test" {
    var test_alloc = framework.TestAllocator.init();
    defer test_alloc.deinit() catch unreachable;
    const allocator = test_alloc.allocator();

    const type_promotion = @import("../src/eval/type_promotion.zig");

    // Test type promotion logic in isolation
    const result = try type_promotion.promoteTypes(.Int, .Float);
    try testing.expectEqual(.Float, result);
}
```

**Benefits**:
- Fast test execution
- Clear failure localization
- Easy debugging
- No external dependencies

### Pattern 2: Module Integration Testing

Test interactions between modules.

```zig
test "schema_manager and transaction_manager integration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const schema = @import("../src/schema/schema_manager.zig");
    const transactions = @import("../src/transactions/transaction_manager.zig");

    // Initialize both modules
    var schema_mgr = try schema.SchemaManager.init(allocator, "/tmp/test");
    defer schema_mgr.deinit();

    var txn_mgr = try transactions.TransactionManager.init(allocator, false, false);
    defer txn_mgr.deinit();

    // Test integration
    const txn_id = try txn_mgr.begin();
    try schema_mgr.createSchema("test_schema");
    try txn_mgr.commit(txn_id);

    // Verify
    try testing.expect(schema_mgr.schemaExists("test_schema"));
}
```

**Benefits**:
- Tests real interactions
- Catches integration bugs
- Verifies module boundaries
- Tests complete workflows

### Pattern 3: Mock-Based I/O Testing

Test modules with I/O operations using mocks.

```zig
test "backup_manager with mock filesystem" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mock_fs = framework.MockFileSystem.init(allocator);
    defer mock_fs.deinit();

    // Module would need to accept filesystem interface
    // (This is a design pattern to follow in new code)
    const backup_mgr = @import("../src/server/backup_manager.zig");

    // Test backup operation (writes to mock instead of real disk)
    // Exact implementation depends on backup_manager design
    try mock_fs.writeFile("/backups/backup1.tar.gz", "compressed data");

    // Verify backup was written
    try framework.Assertions.expectCallCount(1, mock_fs.write_calls, "writeFile");
    try testing.expect(mock_fs.exists("/backups/backup1.tar.gz"));
}
```

**Benefits**:
- No disk I/O in tests
- Fast test execution
- Predictable test environment
- Easy failure injection

### Pattern 4: Dependency Injection Pattern

Design modules to accept dependencies.

```zig
// Module design with DI
pub const MyModule = struct {
    allocator: std.mem.Allocator,
    storage: *StorageInterface, // Injected dependency

    pub fn init(allocator: std.mem.Allocator, storage: *StorageInterface) MyModule {
        return .{
            .allocator = allocator,
            .storage = storage,
        };
    }

    pub fn operation(self: *MyModule) !void {
        // Use injected storage
        try self.storage.write("key", "value");
    }
};

// Test with mock
test "my_module with injected mock storage" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mock_storage = framework.MockStorage.init(allocator);
    defer mock_storage.deinit();

    // Inject mock into module
    var module = MyModule.init(allocator, @ptrCast(&mock_storage));

    // Test operation
    try module.operation();

    // Verify mock was called
    try framework.Assertions.expectCallCount(1, mock_storage.write_calls, "write");
}
```

**Benefits**:
- Testable in isolation
- Flexible configuration
- Clear dependencies
- Easy mocking

---

## Best Practices

### 1. Test One Thing Per Test

**Good**:
```zig
test "schema_manager creates schema" {
    var manager = try schema.SchemaManager.init(allocator, "/tmp");
    defer manager.deinit();

    try manager.createSchema("test");
    try testing.expect(manager.schemaExists("test"));
}

test "schema_manager rejects duplicate schema" {
    var manager = try schema.SchemaManager.init(allocator, "/tmp");
    defer manager.deinit();

    try manager.createSchema("test");
    const result = manager.createSchema("test");
    try framework.Assertions.expectError(error.SchemaExists, result);
}
```

**Bad**:
```zig
test "schema_manager everything" {
    // Tests create, delete, list, duplicate, error cases all in one
    // Hard to debug when it fails
}
```

### 2. Use Descriptive Test Names

**Good**:
```zig
test "transaction_manager commits transaction successfully"
test "transaction_manager aborts on deadlock detection"
test "transaction_manager releases locks after commit"
```

**Bad**:
```zig
test "txn test 1"
test "txn test 2"
test "manager works"
```

### 3. Clean Up Resources

**Always use defer**:
```zig
test "proper cleanup" {
    var test_alloc = framework.TestAllocator.init();
    defer test_alloc.deinit() catch unreachable;

    var mock_fs = framework.MockFileSystem.init(allocator);
    defer mock_fs.deinit();

    var manager = try schema.SchemaManager.init(allocator, "/tmp");
    defer manager.deinit();

    // Test code...
}
```

### 4. Test Error Paths

Don't just test the happy path:

```zig
test "schema_manager handles initialization failure" {
    const result = schema.SchemaManager.init(allocator, "/invalid/path");
    try framework.Assertions.expectError(error.PathNotFound, result);
}

test "transaction_manager handles commit after abort" {
    var manager = try transactions.TransactionManager.init(allocator, false, false);
    defer manager.deinit();

    const txn_id = try manager.begin();
    try manager.abort(txn_id);

    const result = manager.commit(txn_id);
    try framework.Assertions.expectError(error.TransactionAborted, result);
}
```

### 5. Use Mocks for I/O Only

**Good - Mock I/O**:
```zig
var mock_fs = framework.MockFileSystem.init(allocator);
try mock_fs.writeFile("/audit.log", "event");
```

**Bad - Mock Business Logic**:
```zig
// DON'T DO THIS
var mock_schema_manager = MockSchemaManager.init();
mock_schema_manager.setResponse("schema_exists", true); // Mocking business logic!
```

### 6. Verify Module Boundaries

```zig
test "schema_manager interface compliance" {
    const SchemaManager = @import("../src/schema/schema_manager.zig").SchemaManager;
    const verifier = framework.InterfaceVerifier(SchemaManager);

    // Verify all required methods exist
    try testing.expect(verifier.hasMethod("init"));
    try testing.expect(verifier.hasMethod("createSchema"));
    try testing.expect(verifier.hasMethod("createGraph"));
    // ... etc
}
```

---

## Examples by Module

### Schema Manager

```zig
test "schema_manager full workflow" {
    var test_alloc = framework.TestAllocator.init();
    defer test_alloc.deinit() catch unreachable;
    const allocator = test_alloc.allocator();

    const schema = @import("../src/schema/schema_manager.zig");
    var manager = try schema.SchemaManager.init(allocator, "/tmp/test");
    defer manager.deinit();

    // Create schema
    try manager.createSchema("test_schema");
    try testing.expect(manager.schemaExists("test_schema"));

    // Create graph in schema
    try manager.createGraph("test_graph");
    try testing.expect(manager.graphExists("test_graph"));

    // Create index
    const index_info = schema.IndexInfo{
        .name = "test_index",
        .label = "Person",
        .property = "name",
        .index_type = "btree",
    };
    try manager.createIndex(index_info);

    // Verify index
    const retrieved = try manager.getIndex("Person", "test_index");
    try testing.expect(retrieved != null);
}
```

### Transaction Manager

```zig
test "transaction_manager isolation" {
    var test_alloc = framework.TestAllocator.init();
    defer test_alloc.deinit() catch unreachable;
    const allocator = test_alloc.allocator();

    const transactions = @import("../src/transactions/transaction_manager.zig");
    var manager = try transactions.TransactionManager.init(allocator, false, true);
    defer manager.deinit();

    // Begin two transactions
    const txn1 = try manager.begin();
    const txn2 = try manager.begin();

    // Acquire conflicting locks
    try manager.acquireLock(txn1, "key1", .Exclusive);

    // Second transaction should be blocked
    const lock_result = manager.acquireLock(txn2, "key1", .Exclusive);
    try testing.expectError(error.LockConflict, lock_result);

    // Clean up
    try manager.abort(txn2);
    try manager.commit(txn1);
}
```

### Query Executor

```zig
test "query_executor with mock dependencies" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mock_storage = framework.MockStorage.init(allocator);
    defer mock_storage.deinit();

    // Set up test data
    try mock_storage.write("node:1", "{\"id\":1,\"name\":\"Alice\"}");
    try mock_storage.write("node:2", "{\"id\":2,\"name\":\"Bob\"}");

    // Test query execution
    // (Actual query executor would need to accept storage interface)
    const executor = @import("../src/server/query_executor.zig");

    // Verify reads
    try framework.Assertions.expectCallCount(2, mock_storage.write_calls, "setup writes");
}
```

---

## Running Tests

### Single Test

```bash
zig test tests/module_test_framework.zig
```

### All Tests

```bash
zig build test --summary all
```

### With Verbose Output

```bash
zig test tests/module_test_framework.zig --test-filter "schema_manager"
```

### Test Coverage

```bash
zig test tests/module_test_framework.zig --test-coverage
```

---

## Troubleshooting

### Memory Leaks

**Problem**: `TestAllocator.deinit()` fails with memory leak

**Solution**:
1. Check all allocations have matching `defer free()`
2. Verify all modules call `deinit()`
3. Look for early returns that skip cleanup
4. Use the allocation tracking in TestAllocator

```zig
var test_alloc = framework.TestAllocator.init();
// At end of test, check:
std.debug.print("Allocations: {}\n", .{test_alloc.allocations});
std.debug.print("Deallocations: {}\n", .{test_alloc.deallocations});
```

### Test Hangs

**Problem**: Test never completes

**Solution**:
1. Check for infinite loops in module code
2. Verify mock I/O returns expected values
3. Add timeouts to network operations
4. Use `--test-filter` to isolate hanging test

### Mock Not Called

**Problem**: `expectCallCount` fails, mock shows 0 calls

**Solution**:
1. Verify module is using injected mock, not real I/O
2. Check mock is registered with dependency container
3. Confirm module operation actually reached I/O code
4. Add debug prints to track execution flow

---

## Advanced Topics

### Custom Mock Interfaces

Create module-specific mocks:

```zig
pub const MockQueryPlanner = struct {
    plan_calls: usize = 0,
    plans: std.ArrayList(QueryPlan),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MockQueryPlanner {
        return .{
            .plans = std.ArrayList(QueryPlan).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MockQueryPlanner) void {
        for (self.plans.items) |plan| {
            plan.deinit(self.allocator);
        }
        self.plans.deinit();
    }

    pub fn createPlan(self: *MockQueryPlanner, query: []const u8) !QueryPlan {
        self.plan_calls += 1;
        // Return pre-configured plan
        return QueryPlan.init(self.allocator);
    }
};
```

### Performance Testing

Use framework for performance regression tests:

```zig
test "schema_manager performance baseline" {
    var test_alloc = framework.TestAllocator.init();
    defer test_alloc.deinit() catch unreachable;
    const allocator = test_alloc.allocator();

    var manager = try schema.SchemaManager.init(allocator, "/tmp");
    defer manager.deinit();

    const start = std.time.nanoTimestamp();

    // Create 1000 schemas
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const name = try std.fmt.allocPrint(allocator, "schema_{}", .{i});
        defer allocator.free(name);
        try manager.createSchema(name);
    }

    const end = std.time.nanoTimestamp();
    const duration_ms = @divTrunc(end - start, 1_000_000);

    std.debug.print("Created 1000 schemas in {}ms\n", .{duration_ms});

    // Assert performance baseline (adjust as needed)
    try testing.expect(duration_ms < 1000); // Should be under 1 second
}
```

---

## Conclusion

The module testing framework provides comprehensive tools for testing Geode's modularized architecture. Follow the patterns and best practices in this guide to write effective, maintainable module tests.

### Key Takeaways

1. **Test in isolation** - Use dependency injection and mocks
2. **Mock I/O only** - Never mock business logic
3. **Clean up resources** - Always use defer for cleanup
4. **Test error paths** - Don't just test the happy path
5. **Verify boundaries** - Ensure modules implement expected interfaces

### Resources

- Framework Source: `tests/module_test_framework.zig`
- Architecture Doc: `docs/architecture/MODULARIZATION_ARCHITECTURE.md`
- Modularization Status: `docs/MODULARIZATION_STATUS.md`

---

**Last Updated**: 2025-11-14
**Framework Version**: 1.0
**Status**: Production Ready
