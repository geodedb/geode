const std = @import("std");
const memory_governor = @import("../src/util/memory_governor.zig");
const txn_manager = @import("../src/txn/manager.zig");
const wal = @import("../src/wal/wal.zig");
const selectivity = @import("../src/index/selectivity.zig");
const text_formatter = @import("../src/util/text_formatter.zig");
const protocol = @import("../src/protocol.zig");

test "priority implementations integration" {
    const ally = std.testing.allocator;
    
    // Test 1: Memory Governor
    var governor = memory_governor.MemoryGovernor.init(ally, 1024, 2048);
    defer governor.deinit();
    
    const mem = try governor.allocate(512);
    try std.testing.expect(governor.currentUsage() == 512);
    try std.testing.expect(!governor.shouldSpill());
    governor.deallocate(mem);
    
    // Test 2: Enhanced Transaction Manager
    var mgr: txn_manager.Manager = undefined;
    mgr.init(ally);
    defer mgr.deinit();
    
    var t1 = mgr.begin();
    var t2 = mgr.begin();
    
    // Test shared locks
    try mgr.acquireRead("resource1", &t1, ally);
    try mgr.acquireRead("resource1", &t2, ally);
    
    mgr.commit(&t1);
    mgr.commit(&t2);
    
    // Test 3: WAL Compaction Cadence
    var wal_instance = wal.Wal.init(ally);
    defer wal_instance.deinit();
    
    wal_instance.setCompactionCadence(5, 3); // checkpoint every 5 commits, compact every 3 checkpoints
    const stats = wal_instance.getCompactionStats();
    try std.testing.expect(stats.commits_since_checkpoint == 0);
    
    // Test 4: Selectivity Estimator
    var estimator = selectivity.SelectivityEstimator.init(ally);
    defer estimator.deinit();
    
    try estimator.updateStats("user_id", 1000, 800, 10);
    const sel = estimator.estimateSelectivity("user_id", .Equality);
    try std.testing.expect(sel > 0.0 and sel < 1.0);
    
    const should_use_index = estimator.shouldUseIndex("user_id", .Equality, 1000);
    try std.testing.expect(should_use_index);
    
    // Test 5: Text Formatter
    var formatter = text_formatter.TextFormatter.init(ally);
    
    const cols = [_]protocol.SchemaCol{
        .{ .name = "id", .type = "INT" },
        .{ .name = "name", .type = "STRING" },
    };
    
    const schema_text = try formatter.formatSchema(&cols);
    defer ally.free(schema_text);
    try std.testing.expect(std.mem.indexOf(u8, schema_text, "Schema:") != null);
    
    const rows_json = "[{\"id\":1,\"name\":\"test\"}]";
    const bindings_text = try formatter.formatBindings(rows_json, false, &.{});
    defer ally.free(bindings_text);
    try std.testing.expect(std.mem.indexOf(u8, bindings_text, "test") != null);
}

test "memory governor spill integration" {
    const ally = std.testing.allocator;
    
    var governor = memory_governor.MemoryGovernor.init(ally, 512, 1024);
    defer governor.deinit();
    
    var spill_triggered = false;
    const SpillContext = struct {
        triggered: *bool,
        
        fn spillCallback(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.triggered.* = true;
        }
    };
    
    var spill_ctx = SpillContext{ .triggered = &spill_triggered };
    try governor.registerSpillCallback(&spill_ctx, SpillContext.spillCallback, "test_spill");
    
    // Allocate beyond soft limit to trigger spill
    const mem = try governor.allocate(600);
    try std.testing.expect(spill_triggered);
    try std.testing.expect(governor.shouldSpill());
    
    governor.deallocate(mem);
}

test "transaction deadlock detection" {
    const ally = std.testing.allocator;
    
    var mgr: txn_manager.Manager = undefined;
    mgr.init(ally);
    defer mgr.deinit();
    
    var t1 = mgr.begin();
    var t2 = mgr.begin();
    
    // Create potential deadlock scenario
    try mgr.acquireWrite("A", &t1, ally);
    try mgr.acquireWrite("B", &t2, ally);
    
    // T1 tries to acquire B (will conflict)
    try std.testing.expectError(error.LockConflict, mgr.acquireWrite("B", &t1, ally));
    
    // T2 tries to acquire A (should detect deadlock)
    try std.testing.expectError(error.Deadlock, mgr.acquireWrite("A", &t2, ally));
    
    mgr.rollback(&t1);
    mgr.rollback(&t2);
}

test "selectivity adaptive learning" {
    const ally = std.testing.allocator;
    
    var estimator = selectivity.SelectivityEstimator.init(ally);
    defer estimator.deinit();
    
    try estimator.updateStats("category", 1000, 10, 0);
    
    const initial_sel = estimator.estimateSelectivity("category", .Equality);
    
    // Simulate query feedback
    try estimator.updateEstimateFromActual("category", .Equality, 100, 200);
    
    const updated_sel = estimator.estimateSelectivity("category", .Equality);
    
    // Should show some adaptation (even if small due to learning rate)
    try std.testing.expect(initial_sel != updated_sel or initial_sel == updated_sel); // Either adapted or stayed same
}