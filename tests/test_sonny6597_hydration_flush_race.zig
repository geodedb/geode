// SONNY-6597: a hydration scan running while a checkpoint writes the shard's
// dirty pages reads every page as the buffer pool holds it, never the older
// image on disk.
//
// `hydration_scan.scanShard` reads store pages straight from the pager and
// routes through the buffer pool only the pages its dirty snapshot
// (`DirtySet.collect`, under the pool mutex) finds dirty. A checkpoint flush
// (graph-storage `flushAllParallel`, `writeFrameBytes`, a dirty eviction)
// clears a frame's dirty flag under the pool mutex, then DROPS the mutex for
// the write. A snapshot taken in that window saw the page clean and the scan
// read the image on disk, which the write had not yet replaced:
//   * a node created since the last checkpoint was missing, so the shard
//     held fewer live records than its manifest counts and the scan failed
//     with DataCorruption -- the graph was quarantined ("58000
//     DataCorruption ... records the storage engine counts are missing or
//     inconsistent"), seen in test-sonny6591-fts-write-paths after a restart,
//     where the periodic WAL-triggered light checkpoints run during the lazy
//     first-read hydration;
//   * a property SET since the last checkpoint hydrated with its OLD value
//     and the read answered OK (no check catches that one).
//
// The window is held open deterministically with real engine code: the
// graph's shared engine thread pool runs the checkpoint's page writes, so
// every worker is kept busy until the scan has run; the checkpoint has then
// cleared the dirty flags and waits for writes that cannot start.
//
// CANARY: REQ=REQ-SONNY-6597-HYDRATION-FLUSH-RACE; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6597_hydration_flush_race.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const gsa = geode.graph_storage_adapter;

const Engine = @typeInfo(@FieldType(gsa.ManagedGraph, "engine")).pointer.child;
const ThreadPool = @typeInfo(@FieldType(Engine, "shared_thread_pool")).pointer.child;
const TaskFn = @typeInfo(@TypeOf(ThreadPool.submit)).@"fn".params[1].type.?;
const TaskCtxPtr = @typeInfo(@typeInfo(TaskFn).pointer.child).@"fn".params[1].type.?;

const io = std.Io.Threaded.global_single_threaded.io();

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const opts: gsa.hydration_scan.ScanOptions = .{
    .include_edges = true,
    .resident_mode = true,
    .internal_id_key = graph_store.INTERNAL_NODE_ID_PROPERTY_KEY,
};

/// Keeps every worker of a graph's shared engine thread pool busy until
/// `open` is called.
const PoolGate = struct {
    release: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(usize) = .init(0),
    workers: usize = 0,

    fn run(ctx: *anyopaque, _: TaskCtxPtr) void {
        const self: *PoolGate = @ptrCast(@alignCast(ctx));
        _ = self.started.fetchAdd(1, .acq_rel);
        while (!self.release.load(.acquire)) io.sleep(.fromMilliseconds(1), .awake) catch {};
    }

    fn close(self: *PoolGate, pool: *ThreadPool) !void {
        self.workers = pool.core.workers.len;
        for (0..self.workers) |_| _ = try pool.submit(run, @ptrCast(self), .{});
        var waited: usize = 0;
        while (self.started.load(.acquire) < self.workers) : (waited += 1) {
            if (waited > 10_000) return error.PoolGateTimeout;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    fn open(self: *PoolGate) void {
        self.release.store(true, .release);
    }
};

const CheckpointThread = struct {
    adapter: *gsa.StorageAdapter,
    graph: []const u8,
    done: std.atomic.Value(bool) = .init(false),
    err: ?anyerror = null,

    fn run(self: *CheckpointThread) void {
        self.adapter.checkpointGraph(self.graph) catch |e| {
            self.err = e;
        };
        self.done.store(true, .release);
    }
};

/// Dirty frames across every shard pool of the graph.
fn dirtyFrames(mg: *gsa.ManagedGraph) usize {
    var n: usize = 0;
    for (mg.engine.shards) |shard| {
        const pool = &shard.buffer_pool;
        pool.mutex.lockUncancelable(io);
        defer pool.mutex.unlock(io);
        for (pool.frames[0..pool.capacity]) |*frame| {
            if (frame.valid and @atomicLoad(bool, &frame.dirty, .acquire)) n += 1;
        }
    }
    return n;
}

const ScanResult = struct {
    found: usize = 0,
    corrupt: usize = 0,
    other: usize = 0,
    /// The string value of property `key` on the scanned nodes (last one wins).
    value: [64]u8 = undefined,
    value_len: usize = 0,
};

fn scanAll(adapter: *gsa.StorageAdapter, graph: []const u8, key: []const u8) ScanResult {
    var r: ScanResult = .{};
    const shards = adapter.hydrationStreamShardCount(graph) catch {
        r.other += 1;
        return r;
    };
    for (0..shards) |i| {
        var acc = adapter.hydrationStreamScanShard(graph, i, std.testing.allocator, opts) catch |err| {
            if (err == error.DataCorruption) r.corrupt += 1 else r.other += 1;
            continue;
        };
        defer acc.deinit();
        r.found += acc.rows.len;
        for (acc.rows) |row| for (row.props) |p| {
            if (!std.mem.eql(u8, p.key, key)) continue;
            switch (p.value) {
                .string => |s| {
                    const n = @min(s.len, r.value.len);
                    @memcpy(r.value[0..n], s[0..n]);
                    r.value_len = n;
                },
                else => {},
            }
        };
    }
    return r;
}

/// Runs `scanAll` while a checkpoint of `graph` has cleared the dirty flags
/// of the pages it writes and the writes have not started.
fn scanDuringCheckpointWrite(adapter: *gsa.StorageAdapter, graph: []const u8, key: []const u8) !ScanResult {
    const mg = try adapter.lookupManagedGraph(graph);
    try std.testing.expect(dirtyFrames(mg) > 0);

    var gate: PoolGate = .{};
    try gate.close(mg.engine.shared_thread_pool);
    var gate_open = false;
    defer if (!gate_open) gate.open();

    var cp: CheckpointThread = .{ .adapter = adapter, .graph = graph };
    const thread = try std.Thread.spawn(.{}, CheckpointThread.run, .{&cp});
    defer thread.join();

    // The checkpoint has taken every dirty page for writing.
    var waited: usize = 0;
    while (dirtyFrames(mg) != 0) : (waited += 1) {
        if (cp.done.load(.acquire)) return error.CheckpointFinishedBeforeWindow;
        if (waited > 10_000) return error.WindowTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }

    const r = scanAll(adapter, graph, key);

    // The window was still open when the scan ran: the writes had not started.
    try std.testing.expect(!cp.done.load(.acquire));
    gate.open();
    gate_open = true;
    return r;
}

const Fixture = struct {
    store: *graph_store.GraphStore,
    adapter: *gsa.StorageAdapter,
    data_dir: []u8,
    tmp: std.testing.TmpDir,

    fn init(graph: []const u8) !Fixture {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
        try store.createGraph(graph);
        return .{ .store = store, .adapter = adapter, .data_dir = data_dir, .tmp = tmp };
    }

    fn deinit(self: *Fixture) void {
        graph_store.deinitGlobalStore();
        execution.cleanupCatalogInstance();
        graph_store.setDataDirOverride(std.testing.allocator, null);
        std.testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }
};

test "SONNY-6597: a node created since the last checkpoint is found by a hydration scan during the checkpoint's page writes" {
    const G = "g6597create";
    var fx = try Fixture.init(G);
    defer fx.deinit();
    const labels = [_][]const u8{"Doc"};

    // Durable, then one node whose pages are dirty only in the buffer pool.
    const before = try fx.adapter.createNodesBatch(G, &labels, 8, std.testing.allocator);
    std.testing.allocator.free(before);
    try fx.adapter.checkpointGraph(G);
    _ = try fx.adapter.createNode(G, &labels);

    const r = try scanDuringCheckpointWrite(fx.adapter, G, "body");
    std.debug.print("SONNY-6597 (create): scan during the checkpoint's writes found {d} of 9 node(s); {d} shard scan(s) reported DataCorruption, {d} another error\n", .{ r.found, r.corrupt, r.other });
    try std.testing.expectEqual(@as(usize, 0), r.corrupt);
    try std.testing.expectEqual(@as(usize, 0), r.other);
    try std.testing.expectEqual(@as(usize, 9), r.found);

    // Quiescent: the count is exact.
    const q = scanAll(fx.adapter, G, "body");
    try std.testing.expectEqual(@as(usize, 0), q.corrupt + q.other);
    try std.testing.expectEqual(@as(usize, 9), q.found);
}

test "SONNY-6597: a property SET since the last checkpoint hydrates with its new value during the checkpoint's page writes" {
    const G = "g6597set";
    var fx = try Fixture.init(G);
    defer fx.deinit();
    const labels = [_][]const u8{"Doc"};

    const id = try fx.adapter.createNode(G, &labels);
    try fx.adapter.setNodeProperty(G, id, "body", .{ .String = "old value" });
    try fx.adapter.checkpointGraph(G);
    try fx.adapter.setNodeProperty(G, id, "body", .{ .String = "new value" });

    const r = try scanDuringCheckpointWrite(fx.adapter, G, "body");
    std.debug.print("SONNY-6597 (SET): scan during the checkpoint's writes found {d} node(s), body = '{s}'; {d} DataCorruption, {d} another error\n", .{ r.found, r.value[0..r.value_len], r.corrupt, r.other });
    try std.testing.expectEqual(@as(usize, 0), r.corrupt + r.other);
    try std.testing.expectEqual(@as(usize, 1), r.found);
    try std.testing.expectEqualStrings("new value", r.value[0..r.value_len]);

    const q = scanAll(fx.adapter, G, "body");
    try std.testing.expectEqualStrings("new value", q.value[0..q.value_len]);
}
