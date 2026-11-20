const std = @import("std");
const geode = @import("geode");
const testing = std.testing;

test "backup and restore basic operations" {
    const allocator = std.testing.allocator;

    // Create a temporary directory for testing
    const tmp_dir = try std.fs.cwd().makeOpenPath("test_backup_tmp", .{});
    defer {
        tmp_dir.close();
        std.fs.cwd().deleteTree("test_backup_tmp") catch {};
    }

    const backup_path = "test_backup_tmp/test.bak";

    // Create backup manager
    var backup_mgr = geode.backup.BackupManager.init(allocator);
    defer backup_mgr.deinit();

    // Create some test data
    var graph = try geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    // Add nodes
    const node1 = try graph.createNode(&.{});
    try graph.setNodeProperty(node1, "name", .{ .String = "Alice" });
    try graph.setNodeProperty(node1, "age", .{ .String = "30" });

    const node2 = try graph.createNode(&.{});
    try graph.setNodeProperty(node2, "name", .{ .String = "Bob" });
    try graph.setNodeProperty(node2, "age", .{ .String = "25" });

    // Add edge
    const edge = try graph.createEdge(node1, node2, "KNOWS");
    try graph.setEdgeProperty(edge, "type", .{ .String = "KNOWS" });

    // Perform backup
    try backup_mgr.backup(&graph, backup_path);

    // Verify backup file exists
    const file = try std.fs.cwd().openFile(backup_path, .{});
    defer file.close();

    const file_stat = try file.stat();
    try testing.expect(file_stat.size > 0);

    // Clear graph
    graph.clear();

    // Restore from backup
    try backup_mgr.restore(&graph, backup_path, null);

    // Verify data was restored
    const nodes = try graph.getAllNodes(allocator);
    defer allocator.free(nodes);

    try testing.expect(nodes.len == 2);

    // Check properties were restored
    const name1 = (try graph.getNodePropertyOrError(nodes[0], "name"));
    try testing.expect(name1 != null);
}

test "backup with indexes" {
    const allocator = std.testing.allocator;

    const tmp_dir = try std.fs.cwd().makeOpenPath("test_backup_idx", .{});
    defer {
        tmp_dir.close();
        std.fs.cwd().deleteTree("test_backup_idx") catch {};
    }

    const backup_path = "test_backup_idx/indexed.bak";

    var backup_mgr = geode.backup.BackupManager.init(allocator);
    defer backup_mgr.deinit();

    var index_mgr = geode.index.IndexManager.init(allocator);
    defer index_mgr.deinit();

    // Create indexes
    try index_mgr.createPropertyIndex("name_idx", "Person", "name", .btree, true);
    try index_mgr.createPropertyIndex("age_idx", "Person", "age", .hash, false);

    // Add some entries
    try index_mgr.insertIntoPropertyIndex("name_idx", "Alice", 1);
    try index_mgr.insertIntoPropertyIndex("name_idx", "Bob", 2);
    try index_mgr.insertIntoPropertyIndex("age_idx", "30", 1);
    try index_mgr.insertIntoPropertyIndex("age_idx", "25", 2);

    // Backup with indexes
    var graph = try geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    try backup_mgr.backupWithIndexes(&graph, &index_mgr, backup_path);

    // Clear everything
    index_mgr.deinit();
    index_mgr = geode.index.IndexManager.init(allocator);

    // Restore
    try backup_mgr.restoreWithIndexes(&graph, &index_mgr, backup_path, null);

    // Verify indexes were restored
    const result = try index_mgr.lookupPropertyIndex("name_idx", "Alice");
    try testing.expect(result != null);
    try testing.expect(result.? == 1);
}

test "incremental backup" {
    const allocator = std.testing.allocator;

    const tmp_dir = try std.fs.cwd().makeOpenPath("test_backup_incr", .{});
    defer {
        tmp_dir.close();
        std.fs.cwd().deleteTree("test_backup_incr") catch {};
    }

    var backup_mgr = geode.backup.BackupManager.init(allocator);
    defer backup_mgr.deinit();

    var graph = try geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    // Initial data
    const node1 = try graph.createNode(&.{});
    try graph.setNodeProperty(node1, "version", .{ .String = "1" });

    // Full backup
    const full_backup = "test_backup_incr/full.bak";
    try backup_mgr.backup(&graph, full_backup);

    // Add more data
    const node2 = try graph.createNode(&.{});
    try graph.setNodeProperty(node2, "version", .{ .String = "2" });

    // Incremental backup
    const incr_backup = "test_backup_incr/incr1.bak";
    try backup_mgr.incrementalBackup(&graph, full_backup, incr_backup);

    // Verify incremental backup is smaller
    const full_file = try std.fs.cwd().openFile(full_backup, .{});
    defer full_file.close();
    const full_size = (try full_file.stat()).size;

    const incr_file = try std.fs.cwd().openFile(incr_backup, .{});
    defer incr_file.close();
    const incr_size = (try incr_file.stat()).size;

    // Incremental should contain only changes
    try testing.expect(incr_size <= full_size);
}

test "point-in-time recovery" {
    const allocator = std.testing.allocator;

    const tmp_dir = try std.fs.cwd().makeOpenPath("test_backup_pitr", .{});
    defer {
        tmp_dir.close();
        std.fs.cwd().deleteTree("test_backup_pitr") catch {};
    }

    var backup_mgr = geode.backup.BackupManager.init(allocator);
    defer backup_mgr.deinit();

    var graph = try geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    // Create timeline of changes
    const timestamps = std.ArrayList(i64).init(allocator);
    defer timestamps.deinit();

    // Time 1: Initial state
    const node1 = try graph.createNode(&.{});
    try graph.setNodeProperty(node1, "state", .{ .String = "initial" });
    const time1 = std.time.timestamp();
    try timestamps.append(time1);
    try backup_mgr.backup(&graph, "test_backup_pitr/backup1.bak");

    // Wait a moment
    std.time.sleep(100_000_000); // 100ms

    // Time 2: Modified state
    try graph.setNodeProperty(node1, "state", .{ .String = "modified" });
    const time2 = std.time.timestamp();
    try timestamps.append(time2);
    try backup_mgr.backup(&graph, "test_backup_pitr/backup2.bak");

    // Wait a moment
    std.time.sleep(100_000_000); // 100ms

    // Time 3: Final state
    try graph.setNodeProperty(node1, "state", .{ .String = "final" });
    const time3 = std.time.timestamp();
    try timestamps.append(time3);
    try backup_mgr.backup(&graph, "test_backup_pitr/backup3.bak");

    // Restore to time2
    graph.clear();
    try backup_mgr.restore(&graph, "test_backup_pitr/backup2.bak", time2);

    // Verify we got the modified state
    const state = (try graph.getNodePropertyOrError(node1, "state"));
    try testing.expect(state != null);
    if (state) |val| switch (val) {
        .String => |s| try testing.expect(std.mem.eql(u8, s, "modified")),
        else => try testing.expect(false),
    };
}

test "backup compression" {
    const allocator = std.testing.allocator;

    const tmp_dir = try std.fs.cwd().makeOpenPath("test_backup_compress", .{});
    defer {
        tmp_dir.close();
        std.fs.cwd().deleteTree("test_backup_compress") catch {};
    }

    var backup_mgr = geode.backup.BackupManager.init(allocator);
    defer backup_mgr.deinit();

    var graph = try geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    // Create repetitive data (good for compression)
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const node = try graph.createNode(&.{});
        try graph.setNodeProperty(node, "type", .{ .String = "TestNode" });
        try graph.setNodeProperty(node, "data", .{ .String = "AAAAAAAAAA" }); // Repetitive
    }

    // Backup without compression
    try backup_mgr.backup(&graph, "test_backup_compress/uncompressed.bak");

    // Backup with compression
    backup_mgr.enableCompression(.gzip);
    try backup_mgr.backup(&graph, "test_backup_compress/compressed.bak.gz");

    // Compare sizes
    const uncompressed = try std.fs.cwd().openFile("test_backup_compress/uncompressed.bak", .{});
    defer uncompressed.close();
    const uncompressed_size = (try uncompressed.stat()).size;

    const compressed = try std.fs.cwd().openFile("test_backup_compress/compressed.bak.gz", .{});
    defer compressed.close();
    const compressed_size = (try compressed.stat()).size;

    // Compressed should be smaller
    try testing.expect(compressed_size < uncompressed_size);

    // Restore from compressed backup
    graph.clear();
    try backup_mgr.restore(&graph, "test_backup_compress/compressed.bak.gz", null);

    // Verify data integrity
    const nodes = try graph.getAllNodes(allocator);
    defer allocator.free(nodes);
    try testing.expect(nodes.len == 100);
}

test "REQ-GQL-BACKUP-RESTORE validation" {
    // CANARY: REQ=REQ-GQL-BACKUP-RESTORE; FEATURE="BackupRestore"; ASPECT=Core; STATUS=IMPL; TEST=test_backup_restore.zig; OWNER=team; UPDATED=2026-11-14
    const allocator = std.testing.allocator;

    const tmp_dir = try std.fs.cwd().makeOpenPath("test_backup_canary", .{});
    defer {
        tmp_dir.close();
        std.fs.cwd().deleteTree("test_backup_canary") catch {};
    }

    // Complete backup/restore workflow
    var backup_mgr = geode.backup.BackupManager.init(allocator);
    defer backup_mgr.deinit();

    var graph = try geode.graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    var index_mgr = geode.index.IndexManager.init(allocator);
    defer index_mgr.deinit();

    // Create complex graph with indexes
    const alice = try graph.createNode(&.{});
    try graph.setNodeProperty(alice, "name", .{ .String = "Alice" });
    try graph.addNodeLabel(alice, "Person");

    const bob = try graph.createNode(&.{});
    try graph.setNodeProperty(bob, "name", .{ .String = "Bob" });
    try graph.addNodeLabel(bob, "Person");

    const edge = try graph.createEdge(alice, bob, "KNOWS");
    try graph.setEdgeProperty(edge, "since", .{ .String = "2020" });

    try index_mgr.createPropertyIndex("person_name", "Person", "name", .btree, true);
    try index_mgr.insertIntoPropertyIndex("person_name", "Alice", alice);
    try index_mgr.insertIntoPropertyIndex("person_name", "Bob", bob);

    // Backup everything
    const backup_path = "test_backup_canary/complete.bak";
    try backup_mgr.backupComplete(&graph, &index_mgr, backup_path);

    // Clear and restore
    graph.clear();
    index_mgr.deinit();
    index_mgr = geode.index.IndexManager.init(allocator);

    try backup_mgr.restoreComplete(&graph, &index_mgr, backup_path);

    // Verify complete restoration
    const alice_id = try index_mgr.lookupPropertyIndex("person_name", "Alice");
    try testing.expect(alice_id != null);

    const alice_name = (try graph.getNodePropertyOrError(alice_id.?, "name"));
    try testing.expect(alice_name != null);
    if (alice_name) |val| switch (val) {
        .String => |s| try testing.expect(std.mem.eql(u8, s, "Alice")),
        else => try testing.expect(false),
    };
}
