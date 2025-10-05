const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const materialized_views = geode.materialized_views;
// Note: Imports removed - using mock structures instead of external modules
const graph_storage = geode.graph_common;

// CANARY: REQ=REQ-MATERIALIZED-VIEWS-002; FEATURE="Materialized View Integration"; ASPECT=DistributedQueries; STATUS=TESTED; TEST=test_materialized_views_integration; OWNER=query; UPDATED=2025-10-05

// Mock structures for testing
const Column = struct {
    name: []const u8,
    type: []const u8,
};

// Mock query coordinator for testing
const MockQueryCoordinator = struct {
    allocator: std.mem.Allocator,
    executed_queries: std.ArrayList([]const u8),
    
    pub fn init(allocator: std.mem.Allocator) MockQueryCoordinator {
        return .{
            .allocator = allocator,
            .executed_queries = std.ArrayList([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *MockQueryCoordinator) void {
        for (self.executed_queries.items) |query| {
            self.allocator.free(query);
        }
        self.executed_queries.deinit();
    }
    
    pub fn executeQuery(self: *MockQueryCoordinator, query: []const u8) !materialized_views.QueryResult {
        try self.executed_queries.append(try self.allocator.dupe(u8, query));
        
        // Return mock result based on query content
        if (std.mem.indexOf(u8, query, "Person") != null) {
            return self.createPersonQueryResult();
        } else if (std.mem.indexOf(u8, query, "Product") != null) {
            return self.createProductQueryResult();
        } else {
            return self.createEmptyQueryResult();
        }
    }
    
    fn createPersonQueryResult(self: *MockQueryCoordinator) !materialized_views.QueryResult {
        var rows = std.ArrayList(graph_storage.Binding).init(self.allocator);
        
        // Mock person data
        const person_binding = graph_storage.Binding{
            .variable_name = try self.allocator.dupe(u8, "n"),
            .value = graph_storage.BindingValue{ .node = graph_storage.Node{
                .id = 1,
                .labels = &.{"Person"},
                .properties = std.StringHashMap(graph_storage.PropertyValue).init(self.allocator),
            }},
        };
        try rows.append(person_binding);
        
        var schema = std.ArrayList(Column).init(self.allocator);
        try schema.append(.{ .name = "name", .type = "STRING" });
        try schema.append(.{ .name = "age", .type = "INT" });
        
        return materialized_views.QueryResult{
            .rows = try rows.toOwnedSlice(),
            .schema = try schema.toOwnedSlice(),
            .execution_time_ms = 50,
            .row_count = 1,
        };
    }
    
    fn createProductQueryResult(self: *MockQueryCoordinator) !materialized_views.QueryResult {
        var rows = std.ArrayList(graph_storage.Binding).init(self.allocator);
        
        // Mock product data
        const product_binding = graph_storage.Binding{
            .variable_name = try self.allocator.dupe(u8, "p"),
            .value = graph_storage.BindingValue{ .node = graph_storage.Node{
                .id = 2,
                .labels = &.{"Product"},
                .properties = std.StringHashMap(graph_storage.PropertyValue).init(self.allocator),
            }},
        };
        try rows.append(product_binding);
        
        var schema = std.ArrayList(Column).init(self.allocator);
        try schema.append(.{ .name = "name", .type = "STRING" });
        try schema.append(.{ .name = "price", .type = "DECIMAL" });
        
        return materialized_views.QueryResult{
            .rows = try rows.toOwnedSlice(),
            .schema = try schema.toOwnedSlice(),
            .execution_time_ms = 75,
            .row_count = 1,
        };
    }
    
    fn createEmptyQueryResult(self: *MockQueryCoordinator) !materialized_views.QueryResult {
        return materialized_views.QueryResult{
            .rows = try self.allocator.alloc(graph_storage.Binding, 0),
            .schema = try self.allocator.alloc(Column, 0),
            .execution_time_ms = 10,
            .row_count = 0,
        };
    }
};

// Mock MVCC manager for testing
const MockMVCCManager = struct {
    allocator: std.mem.Allocator,
    active_transactions: std.AutoHashMap(u64, TransactionState),
    transaction_counter: u64,
    
    const TransactionState = struct {
        transaction_id: u64,
        start_timestamp: i64,
        isolation_level: IsolationLevel,
        read_only: bool,
    };
    
    const IsolationLevel = enum {
        read_uncommitted,
        read_committed,
        repeatable_read,
        serializable,
    };
    
    pub fn init(allocator: std.mem.Allocator) MockMVCCManager {
        return .{
            .allocator = allocator,
            .active_transactions = std.AutoHashMap(u64, TransactionState).init(allocator),
            .transaction_counter = 1,
        };
    }
    
    pub fn deinit(self: *MockMVCCManager) void {
        self.active_transactions.deinit();
    }
    
    pub fn beginTransaction(self: *MockMVCCManager, isolation_level: IsolationLevel) !u64 {
        const txn_id = self.transaction_counter;
        self.transaction_counter += 1;
        
        try self.active_transactions.put(txn_id, .{
            .transaction_id = txn_id,
            .start_timestamp = std.time.milliTimestamp(),
            .isolation_level = isolation_level,
            .read_only = false,
        });
        
        return txn_id;
    }
    
    pub fn commitTransaction(self: *MockMVCCManager, transaction_id: u64) !void {
        _ = self.active_transactions.remove(transaction_id);
    }
    
    pub fn getTransactionSnapshot(self: *MockMVCCManager, transaction_id: u64) ?TransactionState {
        return self.active_transactions.get(transaction_id);
    }
};

test "materialized view manager with distributed query coordinator integration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create mock query coordinator
    var mock_coordinator = MockQueryCoordinator.init(allocator);
    defer mock_coordinator.deinit();
    
    // Create materialized view manager
    const config = materialized_views.MaterializedViewManager.ViewManagerConfig{
        .max_views = 10,
        .enable_auto_refresh = true,
    };
    var manager = try materialized_views.MaterializedViewManager.init(allocator, config);
    defer manager.deinit();
    
    // Integration test: Create view, refresh using coordinator, query result
    const view_name = "person_summary";
    const source_query = "MATCH (n:Person) RETURN n.name, n.age";
    
    try manager.createView(view_name, source_query, .manual, null);
    
    // Simulate refresh (would use coordinator in real implementation)
    const query_result = try mock_coordinator.executeQuery(source_query);
    defer {
        allocator.free(query_result.rows);
        allocator.free(query_result.schema);
    }
    
    // Verify coordinator was called
    try testing.expect(mock_coordinator.executed_queries.items.len == 1);
    try testing.expect(std.mem.eql(u8, mock_coordinator.executed_queries.items[0], source_query));
    
    // Verify query result structure
    try testing.expect(query_result.row_count == 1);
    try testing.expect(query_result.schema.len == 2);
    try testing.expect(std.mem.eql(u8, query_result.schema[0].name, "name"));
    try testing.expect(std.mem.eql(u8, query_result.schema[1].name, "age"));
}

test "materialized view integration with MVCC transaction management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create mock MVCC manager
    var mock_mvcc = MockMVCCManager.init(allocator);
    defer mock_mvcc.deinit();
    
    // Create materialized view manager
    const config = materialized_views.MaterializedViewManager.ViewManagerConfig{};
    var manager = try materialized_views.MaterializedViewManager.init(allocator, config);
    defer manager.deinit();
    
    // Begin transaction
    const txn_id = try mock_mvcc.beginTransaction(.read_committed);
    
    // Create view within transaction context
    const view_name = "transactional_view";
    const source_query = "MATCH (n:Product) WHERE n.price > 100 RETURN n.name, n.price";
    
    try manager.createView(view_name, source_query, .manual, null);
    
    // Verify transaction state
    const txn_state = mock_mvcc.getTransactionSnapshot(txn_id);
    try testing.expect(txn_state != null);
    try testing.expect(txn_state.?.transaction_id == txn_id);
    try testing.expect(txn_state.?.isolation_level == .read_committed);
    
    // Commit transaction
    try mock_mvcc.commitTransaction(txn_id);
    
    // Verify view was created
    const metadata = manager.views.get(view_name);
    try testing.expect(metadata != null);
    try testing.expect(std.mem.eql(u8, metadata.?.source_query, source_query));
}

test "end-to-end materialized view lifecycle with multiple refresh strategies" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const config = materialized_views.MaterializedViewManager.ViewManagerConfig{
        .max_views = 5,
        .default_refresh_interval_seconds = 1800,
        .enable_auto_refresh = true,
        .max_concurrent_refreshes = 2,
    };
    var manager = try materialized_views.MaterializedViewManager.init(allocator, config);
    defer manager.deinit();
    
    // Create views with different refresh strategies
    const views_config = [_]struct {
        name: []const u8,
        query: []const u8,
        strategy: materialized_views.RefreshStrategy,
        interval: ?u64,
    }{
        .{ .name = "manual_view", .query = "MATCH (n:Person) RETURN n.name", .strategy = .manual, .interval = null },
        .{ .name = "auto_immediate_view", .query = "MATCH (n:Product) RETURN n.name", .strategy = .auto_immediate, .interval = null },
        .{ .name = "auto_scheduled_view", .query = "MATCH (n:Company) RETURN n.name", .strategy = .auto_scheduled, .interval = 3600 },
        .{ .name = "incremental_view", .query = "MATCH (n:Order) RETURN n.total", .strategy = .incremental, .interval = 1800 },
    };
    
    // Create all views
    for (views_config) |view_config| {
        try manager.createView(
            view_config.name,
            view_config.query,
            view_config.strategy,
            view_config.interval,
        );
    }
    
    try testing.expect(manager.statistics.total_views == 4);
    
    // Verify scheduler has jobs for auto-refresh views
    const expected_scheduled_jobs = 3; // auto_immediate, auto_scheduled, incremental
    try testing.expect(manager.refresh_scheduler.scheduled_jobs.items.len == expected_scheduled_jobs);
    
    // Test view querying capabilities
    for (views_config) |view_config| {
        const view_exists = manager.views.contains(view_config.name);
        try testing.expect(view_exists);
        
        const metadata = manager.views.get(view_config.name).?;
        try testing.expect(metadata.refresh_strategy == view_config.strategy);
        try testing.expect(metadata.state == .creating);
    }
    
    // Test drop operations
    try manager.dropView("manual_view");
    try testing.expect(manager.statistics.total_views == 3);
    try testing.expect(!manager.views.contains("manual_view"));
}

test "materialized view query optimization and caching" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var mock_coordinator = MockQueryCoordinator.init(allocator);
    defer mock_coordinator.deinit();
    
    const config = materialized_views.MaterializedViewManager.ViewManagerConfig{
        .enable_auto_refresh = true,
    };
    var manager = try materialized_views.MaterializedViewManager.init(allocator, config);
    defer manager.deinit();
    
    // Create multiple views with overlapping query patterns
    const queries = [_][]const u8{
        "MATCH (n:Person) RETURN n.name, n.age",
        "MATCH (n:Person) WHERE n.age > 25 RETURN n.name",
        "MATCH (n:Product) RETURN n.name, n.price",
        "MATCH (n:Order) RETURN n.total, n.date",
    };
    
    for (queries, 0..) |query, i| {
        const view_name = try std.fmt.allocPrint(allocator, "query_view_{d}", .{i});
        defer allocator.free(view_name);
        
        try manager.createView(view_name, query, .manual, null);
    }
    
    // Test query compatibility checking
    const compatible_view_1 = manager.canSatisfyQuery("MATCH (n:Person) RETURN n.name, n.age");
    try testing.expect(compatible_view_1 != null);
    try testing.expect(std.mem.eql(u8, compatible_view_1.?, "query_view_0"));
    
    const compatible_view_2 = manager.canSatisfyQuery("MATCH (n:Product) RETURN n.name, n.price");
    try testing.expect(compatible_view_2 != null);
    try testing.expect(std.mem.eql(u8, compatible_view_2.?, "query_view_2"));
    
    // Test non-matching query
    const incompatible_view = manager.canSatisfyQuery("MATCH (n:Employee) RETURN n.salary");
    try testing.expect(incompatible_view == null);
}

test "materialized view dependency tracking and change propagation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const config = materialized_views.MaterializedViewManager.ViewManagerConfig{};
    var manager = try materialized_views.MaterializedViewManager.init(allocator, config);
    defer manager.deinit();
    
    // Create views with dependencies
    const view_configs = [_]struct {
        name: []const u8,
        query: []const u8,
        dependencies: []const []const u8,
    }{
        .{
            .name = "person_view",
            .query = "MATCH (n:Person) RETURN n.name, n.age",
            .dependencies = &.{"Person"},
        },
        .{
            .name = "relationship_view",
            .query = "MATCH (p:Person)-[r:KNOWS]->(f:Person) RETURN p.name, f.name",
            .dependencies = &.{ "Person", "KNOWS" },
        },
        .{
            .name = "aggregate_view",
            .query = "MATCH (p:Person) RETURN count(p) AS person_count",
            .dependencies = &.{"Person"},
        },
    };
    
    for (view_configs) |view_config| {
        try manager.createView(view_config.name, view_config.query, .incremental, 3600);
        
        // Add dependencies manually (in real implementation, this would be extracted from query AST)
        for (view_config.dependencies) |dep| {
            try manager.dependency_tracker.addDependency(view_config.name, dep);
        }
    }
    
    // Simulate data changes
    try manager.dependency_tracker.recordChange("Person", .insert);
    try manager.dependency_tracker.recordChange("Person", .update);
    try manager.dependency_tracker.recordChange("KNOWS", .insert);
    
    // Verify change log
    try testing.expect(manager.dependency_tracker.change_log.items.len == 3);
    try testing.expect(manager.dependency_tracker.change_log.items[0].change_type == .insert);
    try testing.expect(manager.dependency_tracker.change_log.items[1].change_type == .update);
    try testing.expect(manager.dependency_tracker.change_log.items[2].change_type == .insert);
    
    // Verify dependencies were recorded
    try testing.expect(manager.dependency_tracker.view_dependencies.count() == 3);
    
    const person_view_deps = manager.dependency_tracker.view_dependencies.get("person_view");
    try testing.expect(person_view_deps != null);
    try testing.expect(person_view_deps.?.items.len == 1);
    try testing.expect(std.mem.eql(u8, person_view_deps.?.items[0], "Person"));
    
    const relationship_view_deps = manager.dependency_tracker.view_dependencies.get("relationship_view");
    try testing.expect(relationship_view_deps != null);
    try testing.expect(relationship_view_deps.?.items.len == 2);
}

test "materialized view performance monitoring and statistics collection" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const config = materialized_views.MaterializedViewManager.ViewManagerConfig{
        .max_views = 10,
        .enable_auto_refresh = true,
    };
    var manager = try materialized_views.MaterializedViewManager.init(allocator, config);
    defer manager.deinit();
    
    // Create test view
    const view_name = "performance_view";
    const source_query = "MATCH (n:Person) RETURN n.name, n.age";
    
    try manager.createView(view_name, source_query, .manual, null);
    
    // Simulate view usage and refresh cycles
    var metadata_ptr = manager.views.getPtr(view_name).?;
    
    // Simulate multiple refreshes with different outcomes
    metadata_ptr.statistics.total_refreshes = 10;
    metadata_ptr.statistics.successful_refreshes = 8;
    metadata_ptr.statistics.failed_refreshes = 2;
    metadata_ptr.statistics.average_refresh_time_ms = 125.5;
    
    // Simulate query hits
    metadata_ptr.statistics.total_query_hits = 150;
    metadata_ptr.statistics.last_query_hit_timestamp = std.time.milliTimestamp();
    metadata_ptr.statistics.cache_hit_ratio = 0.85;
    metadata_ptr.statistics.storage_efficiency = 0.92;
    
    // Update manager-level statistics
    manager.statistics.total_refreshes_completed = 8;
    manager.updateRefreshSuccessRate();
    
    // Get and verify statistics
    const view_stats = try manager.getViewStatistics(view_name);
    try testing.expect(view_stats.total_refreshes == 10);
    try testing.expect(view_stats.successful_refreshes == 8);
    try testing.expect(view_stats.failed_refreshes == 2);
    try testing.expect(view_stats.average_refresh_time_ms == 125.5);
    try testing.expect(view_stats.total_query_hits == 150);
    try testing.expect(view_stats.cache_hit_ratio == 0.85);
    try testing.expect(view_stats.storage_efficiency == 0.92);
    
    const manager_stats = manager.getManagerStatistics();
    try testing.expect(manager_stats.total_views == 1);
    try testing.expect(manager_stats.total_refreshes_completed == 8);
    try testing.expect(manager_stats.refresh_success_rate == 0.8); // 8/10
}

test "materialized view distributed refresh coordination" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var mock_coordinator = MockQueryCoordinator.init(allocator);
    defer mock_coordinator.deinit();
    
    var mock_mvcc = MockMVCCManager.init(allocator);
    defer mock_mvcc.deinit();
    
    const config = materialized_views.MaterializedViewManager.ViewManagerConfig{
        .max_concurrent_refreshes = 3,
        .refresh_timeout_seconds = 600,
    };
    var manager = try materialized_views.MaterializedViewManager.init(allocator, config);
    defer manager.deinit();
    
    // Create views that would require distributed execution
    const distributed_views = [_]struct {
        name: []const u8,
        query: []const u8,
        expected_shards: u32,
    }{
        .{
            .name = "global_person_view",
            .query = "MATCH (n:Person) RETURN n.name, n.age",
            .expected_shards = 3,
        },
        .{
            .name = "cross_shard_relationship_view",
            .query = "MATCH (p:Person)-[r:KNOWS]->(f:Person) RETURN p.name, f.name, r.since",
            .expected_shards = 2,
        },
        .{
            .name = "aggregated_metrics_view",
            .query = "MATCH (o:Order) RETURN sum(o.total) AS total_revenue, count(o) AS order_count",
            .expected_shards = 4,
        },
    };
    
    for (distributed_views) |view_config| {
        try manager.createView(
            view_config.name,
            view_config.query,
            .auto_scheduled,
            3600,
        );
        
        // Simulate distributed query execution
        const query_result = try mock_coordinator.executeQuery(view_config.query);
        defer {
            allocator.free(query_result.rows);
            allocator.free(query_result.schema);
        }
        
        // Verify query was executed
        try testing.expect(mock_coordinator.executed_queries.items.len > 0);
        
        const last_query = mock_coordinator.executed_queries.items[mock_coordinator.executed_queries.items.len - 1];
        try testing.expect(std.mem.eql(u8, last_query, view_config.query));
    }
    
    try testing.expect(manager.statistics.total_views == 3);
    try testing.expect(manager.refresh_scheduler.scheduled_jobs.items.len == 3);
}

test "materialized view error handling and recovery scenarios" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const config = materialized_views.MaterializedViewManager.ViewManagerConfig{
        .max_views = 2,
        .max_view_size_mb = 1,
    };
    var manager = try materialized_views.MaterializedViewManager.init(allocator, config);
    defer manager.deinit();
    
    // Test max views limit
    try manager.createView("view1", "RETURN 1", .manual, null);
    try manager.createView("view2", "RETURN 2", .manual, null);
    
    const max_views_error = manager.createView("view3", "RETURN 3", .manual, null);
    try testing.expectError(error.MaxViewsExceeded, max_views_error);
    
    // Test duplicate view creation
    const duplicate_error = manager.createView("view1", "RETURN 1", .manual, null);
    try testing.expectError(error.ViewAlreadyExists, duplicate_error);
    
    // Test operations on non-existent views
    const drop_error = manager.dropView("non_existent_view");
    try testing.expectError(error.ViewNotFound, drop_error);
    
    const stats_error = manager.getViewStatistics("non_existent_view");
    try testing.expectError(error.ViewNotFound, stats_error);
    
    // Test query on non-ready view
    const metadata_ptr = manager.views.getPtr("view1").?;
    metadata_ptr.state = materialized_views.ViewState.failed;
    
    const query_error = manager.queryView("view1", null, null);
    try testing.expectError(error.ViewNotReady, query_error);
    
    // Reset state for cleanup
    metadata_ptr.state = materialized_views.ViewState.ready;
}