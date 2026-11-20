const std = @import("std");
const graph_store = @import("../graph_store.zig");
const GraphStore = graph_store.GraphStore;
const cluster_replication = @import("cluster_replication.zig");
const graph_storage_adapter = @import("../storage/graph_storage_adapter.zig");
const StorageAdapter = graph_storage_adapter.StorageAdapter;
const graph_archive = @import("../storage/graph_archive.zig");

// CANARY: REQ=REQ-GQL-RAFT-SNAPSHOT; FEATURE="Raft Snapshot Persistence"; ASPECT=SnapshotCreation; STATUS=TESTED; TEST=tests/test_sonny6636_server_snapshot.zig; OWNER=distributed; UPDATED=2026-11-16
// CANARY: REQ=REQ-GQL-RAFT-SNAPSHOT; FEATURE="Raft Snapshot Persistence"; ASPECT=SnapshotInstallation; STATUS=TESTED; TEST=tests/test_sonny6636_durable_snapshot_restore.zig; OWNER=distributed; UPDATED=2026-11-16
//
// The Raft snapshot of the durable store (GRS3): the storage engine's files
// of every user graph, checked with a CRC32. SONNY-6636: the JSON-lines
// snapshot (GRS2) that converted the store, lossily, was removed.

const Crc32 = std.hash.crc.Crc32;

// CANARY: REQ=REQ-SONNY-6636-DURABLE-SNAPSHOT; FEATURE="Raft Snapshot Persistence"; ASPECT=LosslessEngineFileSnapshot; STATUS=TESTED; TEST=tests/test_sonny6636_durable_snapshot_restore.zig; OWNER=distributed; UPDATED=2026-11-16
/// SONNY-6636 (1, 6): the snapshot of a durable store: the storage engine's
/// own files of every graph but `__geode_security` (whose contents are each
/// node's own), byte for byte (`graph_archive`), so every property value
/// (an `ExtValue` too), label, edge, tenant tag, empty graph and per-graph
/// index (fulltext, exact property) arrives exactly. (The JSON-lines form,
/// GRS2, wrote every `ExtValue` as "<ext>" and no empty graph; it was
/// removed.)
///
///   "GRS3" | u32 CRC32 of the rest (big-endian) | u32 graph count |
///   per graph: u16 name length | name | [16]u8 uuid |
///   u64 archive length | archive (each graph's files under "<uuid hex>/") |
///   idempotency table (`IdempotencyDedup.serialize`)
///
/// Under at-rest encryption the files stay sealed: the nodes must share the
/// key (graph-storage derives a graph's keys from it and the graph's uuid,
/// which a restored graph keeps).
pub const durable_snapshot_magic = "GRS3";

pub fn isDurableSnapshot(payload: []const u8) bool {
    return payload.len >= 4 and std.mem.eql(u8, payload[0..4], durable_snapshot_magic);
}

/// Hook run after a durable restore, per restored graph, with no lock held
/// (the server rebuilds its vector indexes there:
/// `index_manager.rebuildVectorIndexesForRestoredGraph`).
pub const GraphRestoredHook = *const fn (graph_name: []const u8) void;
var g_graph_restored_hook: ?GraphRestoredHook = null;

pub fn setGraphRestoredHook(hook: ?GraphRestoredHook) void {
    g_graph_restored_hook = hook;
}

/// The durable snapshot of `adapter`'s store: every graph checkpointed, then
/// its files archived. The caller keeps the store's replicated writers
/// paused across the call (the Raft node holds its applies), so the files
/// reflect one Raft index. Each graph's files are read under its read lock
/// and its `replicated_apply_mutex` (`StorageAdapter.holdGraphForSnapshot`),
/// so no checkpoint, local writer or label interning writes them meanwhile;
/// with no writer mid-operation the files are a consistent image of the
/// engine. Never under the Raft node's `inner_mutex`. The caller frees it.
pub fn encodeDurableSnapshot(allocator: std.mem.Allocator, adapter: *StorageAdapter, dedup: ?*const cluster_replication.IdempotencyDedup) ![]u8 {
    try adapter.checkpointAll();
    const graphs = try adapter.snapshotGraphs(allocator);
    defer StorageAdapter.freeRestoreSources(allocator, graphs);
    var archive = try graph_archive.Builder.init(allocator);
    errdefer archive.deinit(allocator);
    for (graphs) |g| {
        const dir = try adapter.graphDirFor(allocator, g.uuid);
        defer allocator.free(dir);
        const hex = std.fmt.bytesToHex(g.uuid, .lower);
        var hold = try adapter.holdGraphForSnapshot(g.name);
        defer hold.release();
        _ = try archive.appendTree(allocator, dir, &hex);
    }
    const bytes = try archive.finish(allocator);
    defer allocator.free(bytes);
    return assembleDurableSnapshot(allocator, graphs, bytes, dedup);
}

/// A durable snapshot of the given parts (`encodeDurableSnapshot`; tests
/// build damaged ones with it).
pub fn assembleDurableSnapshot(allocator: std.mem.Allocator, graphs: []const StorageAdapter.RestoreSource, archive: []const u8, dedup: ?*const cluster_replication.IdempotencyDedup) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, durable_snapshot_magic);
    try out.appendNTimes(allocator, 0, 4); // CRC, below
    var b4: [4]u8 = undefined;
    std.mem.writeInt(u32, &b4, @intCast(graphs.len), .big);
    try out.appendSlice(allocator, &b4);
    for (graphs) |g| {
        if (g.name.len == 0 or g.name.len > std.math.maxInt(u16)) return error.InvalidSnapshot;
        var b2: [2]u8 = undefined;
        std.mem.writeInt(u16, &b2, @intCast(g.name.len), .big);
        try out.appendSlice(allocator, &b2);
        try out.appendSlice(allocator, g.name);
        try out.appendSlice(allocator, &g.uuid);
    }
    var b8: [8]u8 = undefined;
    std.mem.writeInt(u64, &b8, archive.len, .big);
    try out.appendSlice(allocator, &b8);
    try out.appendSlice(allocator, archive);
    if (dedup) |d| {
        try d.serialize(&out, allocator);
    } else {
        try out.appendNTimes(allocator, 0, 4);
    }
    std.mem.writeInt(u32, out.items[4..8], Crc32.hash(out.items[8..]), .big);
    return out.toOwnedSlice(allocator);
}

/// SONNY-6636 (b): the idempotency table a durable snapshot carries (a
/// node restarting on its own snapshot takes it back: the compacted log no
/// longer holds the entries that recorded its keys). Borrows `payload`.
pub fn durableSnapshotDedupTable(allocator: std.mem.Allocator, payload: []const u8) ![]const u8 {
    var snap = try parseDurableSnapshot(allocator, payload);
    defer snap.deinit(allocator);
    return snap.dedup;
}

const DurableSnapshot = struct {
    graphs: []StorageAdapter.RestoreSource,
    archive: []const u8,
    dedup: []const u8,

    fn deinit(self: *DurableSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.graphs);
    }

    fn has(self: DurableSnapshot, name: []const u8) bool {
        for (self.graphs) |g| if (std.mem.eql(u8, g.name, name)) return true;
        return false;
    }
};

/// Check a durable snapshot whole before anything is written: magic, CRC,
/// the graph list (no `__geode_security`, distinct names and uuids, none
/// zero), the archive (every name safe and under a listed graph's uuid).
/// The graph names borrow `payload`.
fn parseDurableSnapshot(allocator: std.mem.Allocator, payload: []const u8) !DurableSnapshot {
    if (payload.len < 12 or !isDurableSnapshot(payload)) return error.InvalidSnapshot;
    if (Crc32.hash(payload[8..]) != std.mem.readInt(u32, payload[4..8], .big)) return error.ChecksumMismatch;
    const count = std.mem.readInt(u32, payload[8..12], .big);
    if (count > 1 << 16) return error.InvalidSnapshot;
    const graphs = try allocator.alloc(StorageAdapter.RestoreSource, count);
    errdefer allocator.free(graphs);
    var pos: usize = 12;
    for (graphs, 0..) |*g, i| {
        if (payload.len - pos < 2) return error.InvalidSnapshot;
        const len = std.mem.readInt(u16, payload[pos..][0..2], .big);
        pos += 2;
        if (len == 0 or payload.len - pos < @as(usize, len) + 16) return error.InvalidSnapshot;
        g.* = .{ .name = payload[pos..][0..len], .uuid = payload[pos + len ..][0..16].* };
        pos += @as(usize, len) + 16;
        if (std.mem.eql(u8, g.name, graph_store.SECURITY_GRAPH_NAME)) return error.SnapshotNamesSecurityGraph;
        if (std.mem.allEqual(u8, &g.uuid, 0)) return error.InvalidSnapshot;
        for (graphs[0..i]) |o| {
            if (std.mem.eql(u8, o.name, g.name) or std.mem.eql(u8, &o.uuid, &g.uuid)) return error.InvalidSnapshot;
        }
    }
    if (payload.len - pos < 8) return error.InvalidSnapshot;
    const archive_len = std.mem.readInt(u64, payload[pos..][0..8], .big);
    pos += 8;
    if (archive_len > payload.len - pos) return error.InvalidSnapshot;
    const archive = payload[pos..][0..@intCast(archive_len)];
    _ = try graph_archive.validateArchive(allocator, archive);
    var it = try graph_archive.ArchiveIterator.init(archive);
    while (try it.next()) |entry| {
        const slash = std.mem.indexOfScalar(u8, entry.name, '/') orelse return error.InvalidSnapshot;
        var u: [16]u8 = undefined;
        if (slash != 32) return error.InvalidSnapshot;
        _ = std.fmt.hexToBytes(&u, entry.name[0..32]) catch return error.InvalidSnapshot;
        const listed = for (graphs) |g| {
            if (std.mem.eql(u8, &g.uuid, &u)) break true;
        } else false;
        if (!listed) return error.InvalidSnapshot;
    }
    return .{ .graphs = graphs, .archive = archive, .dedup = payload[pos + archive.len ..] };
}

// CANARY: REQ=REQ-SONNY-6636-DURABLE-SNAPSHOT; FEATURE="Raft Snapshot Persistence"; ASPECT=DurableRestore; STATUS=TESTED; TEST=tests/test_sonny6636_durable_snapshot_restore.zig; OWNER=distributed; UPDATED=2026-11-16
/// SONNY-6636 (1, 3): replace the durable store's graphs with a durable
/// snapshot's (`encodeDurableSnapshot`), taken at Raft `point`. Never under
/// the Raft node's `inner_mutex` (file I/O; graph locks): the node runs it
/// on its restore thread while it stays paused.
///
/// 1. The snapshot is checked whole (`parseDurableSnapshot`, the
///    idempotency table) before anything is written.
/// 2. Each graph is staged beside the data (`beginGraphRestoreAt`: the
///    intent, fsynced, carries `point`) and written and verified there;
///    nothing a reader sees changes yet.
/// 3. Under the store's write lock (no request reads or writes meanwhile)
///    each graph's resident state is dropped (`forgetGraphBeforeRestore`),
///    the swap is committed (`commitGraphRestore`: the commit point, then
///    the renames; finishing it records `point` as the Raft index the store
///    reflects), each graph is registered for a build from its new files
///    (`resetGraphAfterRestore`), and each graph the snapshot does not
///    carry is dropped (never the default graph or `__geode_security`).
/// 4. The idempotency table is replaced, then the restored-graph hook runs.
///
/// A crash before the commit point reopens on the old graphs, after it on
/// the restored ones (`StorageAdapter.init` settles the intent); a crash
/// before the drops leaves graphs the snapshot lacks until the leader sends
/// the snapshot again (the Raft snapshot is persisted only after this
/// returns).
pub fn restoreDurableSnapshot(
    allocator: std.mem.Allocator,
    store: *GraphStore,
    adapter: *StorageAdapter,
    payload: []const u8,
    point: graph_storage_adapter.RaftPoint,
    dedup: ?*cluster_replication.IdempotencyDedup,
) !void {
    var snap = try parseDurableSnapshot(allocator, payload);
    defer snap.deinit(allocator);
    {
        var check = cluster_replication.IdempotencyDedup.init(allocator);
        defer check.deinit();
        try check.replaceFrom(snap.dedup);
    }

    if (snap.graphs.len > 0) {
        var r = try adapter.beginGraphRestoreAt(snap.graphs, point);
        defer r.deinit();
        errdefer if (!r.committed) adapter.abandonGraphRestore(&r);
        for (snap.graphs, r.staged_dirs) |g, dir| {
            const hex = std.fmt.bytesToHex(g.uuid, .lower);
            _ = try graph_archive.writeTree(allocator, dir, snap.archive, &hex, true);
            _ = try graph_archive.verifyTree(allocator, dir, snap.archive, &hex);
        }

        graph_storage_adapter.beginReplicatedRestore();
        defer graph_storage_adapter.endReplicatedRestore();
        graph_store.acquireStoreWriteLock();
        defer graph_store.releaseStoreWriteLock();
        // SONNY-6749: requests take no store lock; no first touch builds
        // these graphs from the old files until they are reset, also when
        // the restore stops before that.
        defer for (snap.graphs) |g| store.endGraphRestore(g.name);
        // Nothing of the old graphs stays resident across the swap (and no
        // checkpoint writes their products into the restored directories).
        for (snap.graphs) |g| try store.forgetGraphBeforeRestore(g.name);
        try adapter.commitGraphRestore(&r);
        for (snap.graphs) |g| try store.resetGraphAfterRestore(g.name);
        try dropGraphsNotIn(allocator, store, adapter, snap);
    } else {
        graph_storage_adapter.beginReplicatedRestore();
        defer graph_storage_adapter.endReplicatedRestore();
        graph_store.acquireStoreWriteLock();
        defer graph_store.releaseStoreWriteLock();
        try dropGraphsNotIn(allocator, store, adapter, snap);
        try adapter.recordStoreRaftIndex(point);
    }
    if (dedup) |d| try d.replaceFrom(snap.dedup);
    if (g_graph_restored_hook) |hook| for (snap.graphs) |g| hook(g.name);
}

fn dropGraphsNotIn(allocator: std.mem.Allocator, store: *GraphStore, adapter: *StorageAdapter, snap: DurableSnapshot) !void {
    const local = try adapter.snapshotGraphs(allocator);
    defer StorageAdapter.freeRestoreSources(allocator, local);
    for (local) |l| {
        if (snap.has(l.name) or std.mem.eql(u8, l.name, graph_store.DEFAULT_GRAPH_NAME)) continue;
        store.dropGraph(l.name) catch |err| switch (err) {
            error.GraphNotFound => {},
            else => return err,
        };
    }
}
