const std = @import("std");
const testing = std.testing;

// GAP-0862: Restore data-integrity regression.
//
// Drives the REAL backup engine (src/storage/backup.zig BackupManager) against
// the REAL GraphStore: backs up a graph with a known set of nodes, edges, and
// properties, restores into a fresh directory, and asserts that node + edge
// counts and sampled property values round-trip exactly. This is the
// evidence-based replacement for the legacy backup shell tests that accepted
// `NotImplemented` as a PASS and therefore proved nothing about the advertised
// backup/restore surface.
//
// CANARY: REQ=REQ-BACKUP-REAL-DATA-001; FEATURE="BackupRealData"; ASPECT=RestoreDataIntegrity; STATUS=TESTED; TEST=tests/test_gap0862_backup_integrity.zig; OWNER=backup; UPDATED=2026-06-10

const backup = @import("storage/backup");
const graph_store = @import("geode").graph_store;
const PropertyValue = graph_store.PropertyValue;

// Zig 0.16 compat: std.fs.cwd()/realpathAlloc are removed in this build's std;
// the backup engine itself uses std.Io.Dir + std.Io.Threaded for file IO, so
// the test mirrors that. Temp dirs live under .zig-cache/tmp with a unique
// nanosecond suffix per call.
// Zig 0.16 compat: std.time.nanoTimestamp removed; use clock_gettime directly
// for a monotonically-unique temp-dir suffix.
fn uniqueNanos() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

fn cwdAbsAlloc(allocator: std.mem.Allocator) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return allocator.dupe(u8, cwd_buf[0..actual_len]);
}

fn makeTempDir(allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
    const base = try cwdAbsAlloc(allocator);
    defer allocator.free(base);
    const path = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/gap0862_{s}_{d}", .{ base, suffix, uniqueNanos() });
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().createDirPath(io, path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return path;
}

fn cleanupTempDir(allocator: std.mem.Allocator, dir: []const u8) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    allocator.free(dir);
}

fn initAdapterForDir(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    graph_store.deinitGlobalStore();
    graph_store.deinitGlobalAdapter();
    graph_store.setDataDirOverride(allocator, data_dir);
    _ = try graph_store.initGlobalAdapter(allocator, data_dir);
}

fn resetGlobalStorage(allocator: std.mem.Allocator) void {
    graph_store.deinitGlobalStore();
    graph_store.deinitGlobalAdapter();
    graph_store.setDataDirOverride(allocator, null);
}

const EdgeFixture = struct {
    id: u64,
    from: u64,
    to: u64,
    label: []const u8,
    since: i64,
};

const SeededGraph = struct {
    user_alice: u64,
    user_bob: u64,
    user_carol: u64,
    post_hello: u64,
    post_graphs: u64,
    edges: [3]EdgeFixture,
};

/// Seed a known graph: 3 User nodes, 2 Post nodes, 3 typed edges, each with
/// sampled scalar properties (String + Int on nodes, Int on edges).
fn seedKnownGraph(store: *graph_store.GraphStore) !SeededGraph {
    const alice = try store.createNode(&.{"User"});
    try store.setNodeProperty(alice, "name", .{ .String = "Alice" });
    try store.setNodeProperty(alice, "age", .{ .Int = 30 });

    const bob = try store.createNode(&.{"User"});
    try store.setNodeProperty(bob, "name", .{ .String = "Bob" });
    try store.setNodeProperty(bob, "age", .{ .Int = 25 });

    const carol = try store.createNode(&.{"User"});
    try store.setNodeProperty(carol, "name", .{ .String = "Carol" });
    try store.setNodeProperty(carol, "age", .{ .Int = 41 });

    const hello = try store.createNode(&.{"Post"});
    try store.setNodeProperty(hello, "title", .{ .String = "Hello World" });

    const graphs = try store.createNode(&.{"Post"});
    try store.setNodeProperty(graphs, "title", .{ .String = "Graph Databases" });

    const e0 = try store.createEdge(alice, hello, "AUTHORED");
    try store.setEdgeProperty(e0, "since", .{ .Int = 2024 });
    const e1 = try store.createEdge(bob, graphs, "AUTHORED");
    try store.setEdgeProperty(e1, "since", .{ .Int = 2025 });
    const e2 = try store.createEdge(carol, hello, "LIKES");
    try store.setEdgeProperty(e2, "since", .{ .Int = 2026 });

    try store.saveToFile();

    return .{
        .user_alice = alice,
        .user_bob = bob,
        .user_carol = carol,
        .post_hello = hello,
        .post_graphs = graphs,
        .edges = .{
            .{ .id = e0, .from = alice, .to = hello, .label = "AUTHORED", .since = 2024 },
            .{ .id = e1, .from = bob, .to = graphs, .label = "AUTHORED", .since = 2025 },
            .{ .id = e2, .from = carol, .to = hello, .label = "LIKES", .since = 2026 },
        },
    };
}

fn assertRestoredIntegrity(restored: *graph_store.GraphStore, seed: SeededGraph) !void {
    // Node and edge counts must match the seeded graph exactly.
    try testing.expectEqual(@as(usize, 5), restored.nodes.count());
    try testing.expectEqual(@as(usize, 3), restored.edges.count());

    // Sampled node property round-trip (String + Int).
    const alice_name = restored.getNodeProperty(seed.user_alice, "name") orelse return error.NodePropertyMissing;
    try testing.expectEqualStrings("Alice", alice_name.String);
    const alice_age = restored.getNodeProperty(seed.user_alice, "age") orelse return error.NodePropertyMissing;
    try testing.expectEqual(@as(i64, 30), alice_age.Int);

    const carol_name = restored.getNodeProperty(seed.user_carol, "name") orelse return error.NodePropertyMissing;
    try testing.expectEqualStrings("Carol", carol_name.String);
    const carol_age = restored.getNodeProperty(seed.user_carol, "age") orelse return error.NodePropertyMissing;
    try testing.expectEqual(@as(i64, 41), carol_age.Int);

    const hello_title = restored.getNodeProperty(seed.post_hello, "title") orelse return error.NodePropertyMissing;
    try testing.expectEqualStrings("Hello World", hello_title.String);

    // Sampled edge round-trip: topology (from/to/label) + property.
    for (seed.edges) |ef| {
        const edge_ptr = restored.edges.getPtr(ef.id) orelse return error.EdgeMissing;
        try testing.expectEqual(ef.from, edge_ptr.from_id);
        try testing.expectEqual(ef.to, edge_ptr.to_id);
        try testing.expectEqualStrings(ef.label, edge_ptr.label);
        const since = edge_ptr.properties.get("since") orelse return error.EdgePropertyMissing;
        try testing.expectEqual(ef.since, since.Int);
    }
}

// Full backup -> restore round-trip with multi-node/edge data-integrity checks.
// Default BackupConfig path (which requests .zstd — see the compression test
// for why that lands as .none on disk).
test "GAP-0862 restore preserves node/edge counts and properties" {
    const allocator = testing.allocator;
    defer resetGlobalStorage(allocator);

    const data_dir = try makeTempDir(allocator, "data");
    defer cleanupTempDir(allocator, data_dir);
    try initAdapterForDir(allocator, data_dir);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    store.data_dir = data_dir;
    const seed = try seedKnownGraph(&store);

    const backup_dir = try makeTempDir(allocator, "backups");
    defer cleanupTempDir(allocator, backup_dir);

    var mgr = try backup.BackupManager.init(allocator, backup_dir, .{}, &store);
    defer mgr.deinit();

    const meta = try mgr.createFullBackup();
    try testing.expect(meta.size_bytes > 0);
    try testing.expectEqual(backup.BackupType.full, meta.backup_type);

    const restore_dir = try makeTempDir(allocator, "restore");
    defer cleanupTempDir(allocator, restore_dir);
    try mgr.restoreToPointInTime(restore_dir, meta.timestamp + 1);

    // Re-open a fresh adapter + store on the restored directory and assert
    // the graph round-tripped intact.
    try initAdapterForDir(allocator, restore_dir);
    var restored = try graph_store.GraphStore.init(allocator);
    defer restored.deinit();
    restored.data_dir = restore_dir;
    try restored.loadFromFile();

    try assertRestoredIntegrity(&restored, seed);
}

// GAP-0862 -> GAP-0880: there is no zstd encoder in this toolchain. The
// GAP-0862 fix made a `.zstd` request silently degrade to `.none` with a
// truthful header; GAP-0880 hardened that further — a codec the engine cannot
// apply is now REJECTED loudly (error.UnsupportedCompression) instead of
// silently storing something other than what was requested. Real compression
// is available via `.gzip` (see tests/test_gap0880_backup_upload.zig for the
// gzip round-trip + magic-byte verification).
test "GAP-0862 zstd request is rejected with UnsupportedCompression" {
    const allocator = testing.allocator;
    defer resetGlobalStorage(allocator);

    const data_dir = try makeTempDir(allocator, "cdata");
    defer cleanupTempDir(allocator, data_dir);
    try initAdapterForDir(allocator, data_dir);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    store.data_dir = data_dir;
    _ = try seedKnownGraph(&store);

    const backup_dir = try makeTempDir(allocator, "cbackups");
    defer cleanupTempDir(allocator, backup_dir);

    var mgr = try backup.BackupManager.init(allocator, backup_dir, .{ .compression = .zstd }, &store);
    defer mgr.deinit();

    try testing.expectError(error.UnsupportedCompression, mgr.createFullBackup());
}

// A corrupted backup payload must be rejected by checksum verification rather
// than silently restoring garbage. Proves the integrity guard is real.
test "GAP-0862 corrupted backup payload is rejected on restore" {
    const allocator = testing.allocator;
    defer resetGlobalStorage(allocator);

    const data_dir = try makeTempDir(allocator, "xdata");
    defer cleanupTempDir(allocator, data_dir);
    try initAdapterForDir(allocator, data_dir);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    store.data_dir = data_dir;
    _ = try seedKnownGraph(&store);

    const backup_dir = try makeTempDir(allocator, "xbackups");
    defer cleanupTempDir(allocator, backup_dir);

    var mgr = try backup.BackupManager.init(allocator, backup_dir, .{}, &store);
    defer mgr.deinit();

    const meta = try mgr.createFullBackup();

    // Flip a byte deep in the payload (past the header) to simulate corruption.
    const backup_path = try std.fmt.allocPrint(allocator, "{s}/full_{x}.backup", .{ backup_dir, meta.backup_id });
    defer allocator.free(backup_path);
    {
        const io = std.Io.Threaded.global_single_threaded.io();
        var file = try std.Io.Dir.cwd().openFile(io, backup_path, .{ .mode = .read_write });
        defer file.close(io);
        const corrupt_offset: u64 = @sizeOf(backup.BackupHeader) + 4;
        var byte: [1]u8 = undefined;
        _ = try file.readPositionalAll(io, &byte, corrupt_offset);
        byte[0] ^= 0xFF;
        try file.writePositionalAll(io, &byte, corrupt_offset);
    }

    const restore_dir = try makeTempDir(allocator, "xrestore");
    defer cleanupTempDir(allocator, restore_dir);

    const result = mgr.restoreToPointInTime(restore_dir, meta.timestamp + 1);
    try testing.expectError(error.BackupChecksumMismatch, result);
}
