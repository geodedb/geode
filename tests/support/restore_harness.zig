const std = @import("std");
const testing = std.testing;
const graph_store = @import("geode").graph_store;

// Real storage only: the backup has one node, the live store has two. A
// refused restore must leave both the resident state and its next reopen intact.
pub const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    live: []u8,
    backups: []u8,
    store: graph_store.GraphStore,

    pub fn init() !Fixture {
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

    pub fn deinit(self: *Fixture) void {
        self.store.deinit();
        graph_store.deinitGlobalAdapter();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.backups);
        testing.allocator.free(self.live);
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    pub fn assertLiveAfterReopen(self: *Fixture) !void {
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
