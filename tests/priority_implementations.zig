const std = @import("std");
const txn_manager = @import("../src/transactions/manager.zig");
const selectivity = @import("../src/index/selectivity.zig");
const text_formatter = @import("../src/util/text_formatter.zig");
const protocol = @import("../src/protocol.zig");

test "priority implementations integration" {
    const ally = std.testing.allocator;

    // Test 1: Enhanced Transaction Manager
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

    // Test 2: Selectivity Estimator
    var estimator = selectivity.SelectivityEstimator.init(ally);
    defer estimator.deinit();

    try estimator.updateStats("user_id", 1000, 800, 10);
    const sel = estimator.estimateSelectivity("user_id", .Equality);
    try std.testing.expect(sel > 0.0 and sel < 1.0);

    const should_use_index = estimator.shouldUseIndex("user_id", .Equality, 1000);
    try std.testing.expect(should_use_index);

    // Test 3: Text Formatter
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
    try std.testing.expect(initial_sel != updated_sel);
}
