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
        var tmp = testing.tmpDir(.{});
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
