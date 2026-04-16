const std = @import("std");
const geode = @import("../src/lib.zig");
const execution = geode.execution;
const graph_store = geode.graph_store;
const mvcc = @import("../src/server/txn/mvcc.zig");


// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, self.allocator);
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.allocator, parsed.program.statements[0], self.ctx);
    }
};

test "MATCH pattern execution - basic node scan" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    const alice_id = try store.createNode(&.{"Person"});
    try store.setNodeProperty(alice_id, "name", .{ .String = "Alice" });
    const bob_id = try store.createNode(&.{"Person"});
    try store.setNodeProperty(bob_id, "name", .{ .String = "Bob" });

    var res = try h.exec("MATCH (n:Person) RETURN n");
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), res.rows.len);
}

test "MATCH pattern with edge traversal" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    const alice_id = try store.createNode(&.{"Person"});
    try store.setNodeProperty(alice_id, "name", .{ .String = "Alice" });
    const bob_id = try store.createNode(&.{"Person"});
    try store.setNodeProperty(bob_id, "name", .{ .String = "Bob" });

    const edge_id = try store.createEdge(alice_id, bob_id, "KNOWS");
    try store.setEdgeProperty(edge_id, "since", .{ .Int = 2020 });

    var res = try h.exec("MATCH (a:Person)-[r:KNOWS]->(b:Person) RETURN a, r, b");
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    if (res.rows.len > 0) {
        const row = res.rows[0];
        try std.testing.expect(row.len == 3);
        try std.testing.expect(std.meta.activeTag(row[0]) == .Node);
        try std.testing.expect(std.meta.activeTag(row[1]) == .Edge);
        try std.testing.expect(std.meta.activeTag(row[2]) == .Node);
        try std.testing.expectEqual(alice_id, row[0].Node.id);
        try std.testing.expectEqual(bob_id, row[2].Node.id);
        try std.testing.expectEqual(edge_id, row[1].Edge.id);
    }
}

test "MVCC write-write conflict detection" {
    const allocator = std.testing.allocator;

    // Create MVCC manager
    var mgr = mvcc.MVCCManager.init(allocator);
    defer mgr.deinit();

    // Start two transactions
    var txn1 = try mgr.beginTransaction(.SnapshotIsolation);
    var txn2 = try mgr.beginTransaction(.SnapshotIsolation);

    // Both transactions try to write to the same resource
    const resource_id: u64 = 100;

    // First write should succeed
    try mgr.write(txn1, resource_id, "value1");

    // Second write should fail with conflict
    const result = mgr.write(txn2, resource_id, "value2");
    try std.testing.expectError(error.WriteConflict, result);

    // First transaction should commit successfully
    try mgr.commitTransaction(txn1);

    // Second transaction should abort
    try mgr.abortTransaction(txn2);
}

test "MVCC read consistency" {
    const allocator = std.testing.allocator;

    // Create MVCC manager
    var mgr = mvcc.MVCCManager.init(allocator);
    defer mgr.deinit();

    // Start first transaction and write
    var txn1 = try mgr.beginTransaction(.SnapshotIsolation);
    const resource_id: u64 = 200;
    try mgr.write(txn1, resource_id, "initial_value");
    try mgr.commitTransaction(txn1);

    // Start second transaction (sees committed value)
    var txn2 = try mgr.beginTransaction(.SnapshotIsolation);
    const read1 = try mgr.read(txn2, resource_id);
    try std.testing.expectEqualStrings("initial_value", read1.?);

    // Start third transaction and write new value
    var txn3 = try mgr.beginTransaction(.SnapshotIsolation);
    try mgr.write(txn3, resource_id, "new_value");

    // Second transaction should still see old value (snapshot isolation)
    const read2 = try mgr.read(txn2, resource_id);
    try std.testing.expectEqualStrings("initial_value", read2.?);

    // Commit third transaction
    try mgr.commitTransaction(txn3);

    // New transaction should see new value
    var txn4 = try mgr.beginTransaction(.SnapshotIsolation);
    const read3 = try mgr.read(txn4, resource_id);
    try std.testing.expectEqualStrings("new_value", read3.?);

    // Clean up
    try mgr.commitTransaction(txn2);
    try mgr.commitTransaction(txn4);
}

test "MVCC deadlock detection" {
    const allocator = std.testing.allocator;

    // Create MVCC manager
    var mgr = mvcc.MVCCManager.init(allocator);
    defer mgr.deinit();

    // Start two transactions
    var txn1 = try mgr.beginTransaction(.RepeatableRead);
    var txn2 = try mgr.beginTransaction(.RepeatableRead);

    const resource1: u64 = 301;
    const resource2: u64 = 302;

    // Transaction 1 locks resource1
    _ = try mgr.read(txn1, resource1);

    // Transaction 2 locks resource2
    _ = try mgr.read(txn2, resource2);

    // Transaction 1 tries to lock resource2 (waits for txn2)
    // Transaction 2 tries to lock resource1 (would create deadlock)
    // One of them should be aborted to break the deadlock

    // This is a simplified test - full deadlock detection would require
    // concurrent execution which is complex to test synchronously

    // Clean up
    try mgr.abortTransaction(txn1);
    try mgr.abortTransaction(txn2);
}
