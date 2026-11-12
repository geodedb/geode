const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;
const backup = @import("storage/backup");
const s3 = @import("s3_backup");

// Real storage only: the backup has one node, the live store has two. A
// refused restore must leave both the resident state and its next reopen intact.
const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    live: []u8,
    backups: []u8,
    store: graph_store.GraphStore,

    fn init() !Fixture {
        const a = testing.allocator;
        const io = std.Io.Threaded.global_single_threaded.io();
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(io, &buf);
        const root = try a.dupe(u8, buf[0..len]);
        errdefer a.free(root);
        const live = try std.fmt.allocPrint(a, "{s}/live", .{root});
        errdefer a.free(live);
        const backups = try std.fmt.allocPrint(a, "{s}/backups", .{root});
        errdefer a.free(backups);
        graph_store.deinitGlobalStore();
        graph_store.deinitGlobalAdapter();
        graph_store.setDataDirOverride(a, live);
        errdefer graph_store.setDataDirOverride(a, null);
        _ = try graph_store.initGlobalAdapter(a, live);
        errdefer graph_store.deinitGlobalAdapter();
        var store = try graph_store.GraphStore.init(a);
        errdefer store.deinit();
        store.data_dir = live;
        _ = try store.createNode(&.{"BeforeBackup"});
        try store.saveToFile();
        return .{ .tmp = tmp, .root = root, .live = live, .backups = backups, .store = store };
    }

    fn deinit(self: *Fixture) void {
        self.store.deinit();
        graph_store.deinitGlobalAdapter();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.backups);
        testing.allocator.free(self.live);
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn assertLiveAfterReopen(self: *Fixture) !void {
        try testing.expectEqual(@as(usize, 2), self.store.nodes.count());
        graph_store.deinitGlobalAdapter();
        _ = try graph_store.initGlobalAdapter(testing.allocator, self.live);
        var reopened = try graph_store.GraphStore.init(testing.allocator);
        defer reopened.deinit();
        reopened.data_dir = self.live;
        try reopened.loadFromFile();
        reopened.ensureGraphHydrated("default");
        try testing.expectEqual(@as(usize, 2), reopened.nodes.count());
    }
};

fn checkRefusal(alias: bool, empty_store_path: bool) !void {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var mgr = try backup.BackupManager.init(testing.allocator, fixture.backups, .{}, &fixture.store);
    defer mgr.deinit();
    const meta = try mgr.createFullBackup();
    _ = try fixture.store.createNode(&.{"AfterBackup"});
    try fixture.store.saveToFile();
    const target = try std.fmt.allocPrint(testing.allocator, "{s}{s}", .{ fixture.live, if (alias) "/." else "" });
    defer testing.allocator.free(target);
    // The global adapter also owns the live directory. A lightweight facade's
    // optional data_dir must not bypass the guard.
    if (empty_store_path) fixture.store.data_dir = "";
    defer fixture.store.data_dir = fixture.live;
    try testing.expectError(error.LiveRestoreRequiresRestart, mgr.restoreToPointInTime(target, meta.timestamp + 1));
    fixture.store.data_dir = fixture.live;
    try fixture.assertLiveAfterReopen();
}

test "SONNY-6300 direct live restore is refused without losing resident or durable data" {
    try checkRefusal(false, false);
}

test "SONNY-6300 canonical path alias cannot bypass live restore refusal" {
    try checkRefusal(true, false);
}

test "SONNY-6300 global adapter protects live data even with a pathless facade" {
    try checkRefusal(true, true);
}

test "SONNY-6300 S3 live target is refused before any network request" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    _ = try fixture.store.createNode(&.{"AfterBackup"});
    try fixture.store.saveToFile();
    var mgr = try s3.S3BackupManager.init(testing.allocator, .{
        .bucket = "not-contacted",
        .prefix = "test",
        .access_key_id = "test",
        .secret_access_key = "test",
        .endpoint = "127.0.0.1:1",
        .use_ssl = false,
        .max_retries = 1,
    }, .{});
    defer mgr.deinit();
    try testing.expectError(error.LiveRestoreRequiresRestart, mgr.restore(1, fixture.live, &fixture.store));
    try fixture.assertLiveAfterReopen();
}

test "SONNY-6300 live fixture preserves real data through reopen without a restore" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    _ = try fixture.store.createNode(&.{"AfterBackup"});
    try fixture.store.saveToFile();
    try fixture.assertLiveAfterReopen();
}

fn appendEntry(payload: *std.ArrayList(u8), name: []const u8, data: []const u8) !void {
    const a = testing.allocator;
    try payload.appendSlice(a, &std.mem.toBytes(@as(u32, @intCast(name.len))));
    try payload.appendSlice(a, name);
    try payload.appendSlice(a, &std.mem.toBytes(@as(u64, @intCast(data.len))));
    try payload.appendSlice(a, data);
}

fn registerPayload(mgr: *backup.BackupManager, payload: []const u8) !backup.BackupMetadata {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(testing.allocator);
    const header = backup.BackupHeader{
        .magic = backup.BACKUP_MAGIC,
        .version = backup.BACKUP_VERSION,
        .backup_type = .full,
        .timestamp = 1,
        .compression = .none,
        .payload_len = payload.len,
        .checksum = std.hash.crc.Crc32.hash(payload),
    };
    try bytes.appendSlice(testing.allocator, &std.mem.toBytes(header));
    try bytes.appendSlice(testing.allocator, payload);
    return mgr.ingestUploadedBackup(bytes.items, null);
}

fn faultArchive(traversal: bool) !void {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var mgr = try backup.BackupManager.init(testing.allocator, fixture.backups, .{}, &fixture.store);
    defer mgr.deinit();
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(testing.allocator);
    try payload.appendSlice(testing.allocator, "GEODBAK1");
    try payload.appendSlice(testing.allocator, &std.mem.toBytes(@as(u32, 1)));
    try payload.appendSlice(testing.allocator, &std.mem.toBytes(@as(u32, 2)));
    try appendEntry(&payload, "first.txt", "must not be published");
    try appendEntry(&payload, if (traversal) "../escaped.txt" else "last.txt", "second");
    if (!traversal) payload.items.len -= 1; // Valid outer checksum, malformed inner entry.
    const meta = try registerPayload(&mgr, payload.items);
    const target = try std.fmt.allocPrint(testing.allocator, "{s}/restored", .{fixture.root});
    defer testing.allocator.free(target);
    const expected = if (traversal) error.InvalidBackupPath else error.InvalidBackupFile;
    try testing.expectError(expected, mgr.restoreToPointInTime(target, meta.timestamp + 1));
    const io = std.Io.Threaded.global_single_threaded.io();
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.access(io, "restored", .{}));
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.access(io, "escaped.txt", .{}));
    var it = fixture.tmp.dir.iterate();
    while (try it.next(io)) |entry| {
        try testing.expect(!std.mem.startsWith(u8, entry.name, ".geode-restore-"));
    }
}

test "SONNY-6300 malformed later entries leave no partial restore directory" {
    try faultArchive(false);
}

test "SONNY-6300 traversal is refused before writing any archive entry" {
    try faultArchive(true);
}

test "SONNY-6300 existing target contents are preserved instead of merged" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var mgr = try backup.BackupManager.init(testing.allocator, fixture.backups, .{}, &fixture.store);
    defer mgr.deinit();
    const meta = try mgr.createFullBackup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try fixture.tmp.dir.createDir(io, "restored", .default_dir);
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "restored/marker", .data = "original" });
    const target = try std.fmt.allocPrint(testing.allocator, "{s}/restored", .{fixture.root});
    defer testing.allocator.free(target);
    try testing.expectError(error.RestoreTargetNotEmpty, mgr.restoreToPointInTime(target, meta.timestamp + 1));
    const marker = try fixture.tmp.dir.readFileAlloc(io, "restored/marker", testing.allocator, .limited(100));
    defer testing.allocator.free(marker);
    try testing.expectEqualStrings("original", marker);
    var dir = try fixture.tmp.dir.openDir(io, "restored", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    const only_entry = (try it.next(io)).?;
    try testing.expectEqualStrings("marker", only_entry.name);
    try testing.expect((try it.next(io)) == null);
}

test "SONNY-6300 offline restore opens real saved data without replacing live adapter" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var mgr = try backup.BackupManager.init(testing.allocator, fixture.backups, .{}, &fixture.store);
    defer mgr.deinit();
    const meta = try mgr.createFullBackup();
    _ = try fixture.store.createNode(&.{"AfterBackup"});
    try fixture.store.saveToFile();
    const live_adapter = graph_store.getGlobalAdapter().?;
    const target = try std.fmt.allocPrint(testing.allocator, "{s}/restored", .{fixture.root});
    defer testing.allocator.free(target);
    try mgr.restoreToPointInTime(target, meta.timestamp + 1);
    try testing.expect(live_adapter == graph_store.getGlobalAdapter().?);
    const restored = try geode.graph_storage_adapter.StorageAdapter.init(testing.allocator, target, .{});
    defer restored.deinit();
    try testing.expectEqual(@as(u64, 1), try restored.nodeCount("default"));
    try testing.expectEqual(@as(usize, 2), fixture.store.nodes.count());
}

test "SONNY-6300 bad graph registry is not published as a successful empty store" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var mgr = try backup.BackupManager.init(testing.allocator, fixture.backups, .{}, &fixture.store);
    defer mgr.deinit();
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(testing.allocator);
    try payload.appendSlice(testing.allocator, "GEODBAK1");
    try payload.appendSlice(testing.allocator, &std.mem.toBytes(@as(u32, 1)));
    try payload.appendSlice(testing.allocator, &std.mem.toBytes(@as(u32, 1)));
    try appendEntry(&payload, "graph_registry.dat", "not a graph registry");
    const meta = try registerPayload(&mgr, payload.items);
    const target = try std.fmt.allocPrint(testing.allocator, "{s}/restored", .{fixture.root});
    defer testing.allocator.free(target);
    try testing.expectError(error.RestoreVerificationFailed, mgr.restoreToPointInTime(target, meta.timestamp + 1));
    const io = std.Io.Threaded.global_single_threaded.io();
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.access(io, "restored", .{}));
    var it = fixture.tmp.dir.iterate();
    while (try it.next(io)) |entry| {
        try testing.expect(!std.mem.startsWith(u8, entry.name, ".geode-restore-"));
    }
}

test "SONNY-6300 snapshot verification must not import metadata into the live process" {
    graph_store.setLeanIndexingForTest(true);
    defer graph_store.setLeanIndexingForTest(false);
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const io = std.Io.Threaded.global_single_threaded.io();
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "live/merge_index_keys.dat", .data = "snapshot_only_key\n" });
    var mgr = try backup.BackupManager.init(testing.allocator, fixture.backups, .{}, &fixture.store);
    defer mgr.deinit();
    const meta = try mgr.createFullBackup();
    try testing.expect(!graph_store.shouldIndexProperty("snapshot_only_key"));
    const target = try std.fmt.allocPrint(testing.allocator, "{s}/restored", .{fixture.root});
    defer testing.allocator.free(target);
    try mgr.restoreToPointInTime(target, meta.timestamp + 1);
    try testing.expect(!graph_store.shouldIndexProperty("snapshot_only_key"));
}
