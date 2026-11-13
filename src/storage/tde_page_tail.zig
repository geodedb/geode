//! SONNY-6452: find and repair the records that graph_storage <= 0.4.11 lost
//! from page-encrypted stores (SONNY-6441, fixed in graph_storage 0.4.12).
//!
//! The old pager wrote the 16-byte AES-GCM tag over the LAST 16 bytes of
//! every encrypted page body (the "legacy envelope"); whatever a layout kept
//! there never reached the disk. 0.4.12 writes the tag into the page header
//! and sets `PageFlags.encrypted` on the page; it still reads a legacy page
//! (flag clear) and zeroes its last 16 body bytes. A legacy page therefore
//! stays recognisable on disk, without the key, until its next write: the
//! flag is clear and its header checksum does not match its body (a
//! plaintext page always carries the CRC32C of its body).
//!
//! What the tail held, per store file:
//!   - nodes: the record in each slot whose bytes reach the tail (slot 169
//!     of 170 at 8 KiB pages): `label_count`, `flags`, `_pad`, `txn_stamp`.
//!     After 0.4.12 it reads live (flags 0) with label_count 0, or as an
//!     empty slot when the rest of its record (heads) is zero too.
//!   - in_dir (`adj_in_dir.store`): the last two incoming-chain heads of a
//!     page (dst 1018/1019 of 1020 at 8 KiB) read as "no head".
//!   - adj_out / adj_in / in_idx chain blocks (v1/v2/v3 entry formats): an
//!     entry whose bytes reach the tail (the last v1 entry at 8 KiB, the
//!     last v3 entry at 4 KiB). Slab blocks, props and var reserve the tail.
//!
//! `scan` reads the store files directly (never opens the store, so it
//! writes nothing and cannot move a page to the new envelope before it has
//! been reported). `repair` opens the store through a `StorageAdapter` and
//! uses only graph_storage's public engine API: `getNode`/`putNodeTxn`, the
//! label block (`label_store.getLabels`), and `migrateColocateInEdges`, the
//! library's rebuild of a shard's incoming-edge directory from its outgoing
//! edges.

const std = @import("std");
const gs = @import("graph_storage");
const graph_storage_adapter = @import("graph_storage_adapter.zig");

const Allocator = std.mem.Allocator;
const PAGE_HEADER_SIZE: usize = gs.page.PAGE_HEADER_SIZE;
const TAG_SIZE: usize = gs.encryption.TAG_SIZE;
const NodeRec = gs.node.NodeRec;

/// The creation stamp geode writes into every node record
/// (`StorageAdapter.createNode`); graph_storage reads it only to tell a
/// written slot from an empty one.
pub const geode_node_txn_stamp: u64 = 1;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// The store files whose pages go through the (encrypting) pager.
pub const paged_files = [_]gs.FileId{ .nodes, .adj_out, .adj_in, .props, .var_store, .in_idx, .in_dir };
const paged_names = [_][]const u8{ "nodes", "adj_out", "adj_in", "props", "var", "in_idx", "in_dir" };

fn pagedIndex(fid: gs.FileId) usize {
    for (paged_files, 0..) |f, i| if (f == fid) return i;
    unreachable;
}

pub const Envelope = enum { unwritten, plaintext, header_tag, legacy };

/// How a page read straight from disk was written. Needs no key.
pub fn classify(page: []const u8) Envelope {
    const header = page[0..PAGE_HEADER_SIZE];
    const body = page[PAGE_HEADER_SIZE..];
    if (std.mem.allEqual(u8, header, 0) and std.mem.allEqual(u8, body, 0)) return .unwritten;
    if (page[gs.page.FLAGS_OFFSET] & gs.page.FLAG_HEADER_TAG != 0) return .header_tag;
    const stored = std.mem.readInt(u32, page[16..20], .little);
    if (stored == gs.page.computeChecksum(body)) return .plaintext;
    return .legacy;
}

pub const AdjEntry = struct {
    file: gs.FileId,
    page: u64,
    slot: u32,
    edge_id: u64,
    neighbor: u64,
};

pub const ShardReport = struct {
    uuid: [16]u8,
    page_size: u32,
    /// Pages per store file still in the legacy envelope.
    old_pages: [paged_files.len]u64 = [_]u64{0} ** paged_files.len,
    /// Pages per store file in the header-tag envelope.
    new_pages: [paged_files.len]u64 = [_]u64{0} ** paged_files.len,
    /// Node records that lost label_count/flags/txn_stamp: present, but
    /// whether the node had been deleted is not recorded anywhere else.
    nodes_liveness_unknown: std.ArrayList(u64) = .empty,
    /// Allocated node ids whose whole record was the lost tail: they read
    /// as empty slots, and whether they existed is not derivable.
    nodes_lost: std.ArrayList(u64) = .empty,
    /// Destination ids whose incoming-chain head was in the lost tail.
    in_dir_lost_heads: std.ArrayList(u64) = .empty,
    /// Chain-block entries whose bytes reached the lost tail.
    adjacency: std.ArrayList(AdjEntry) = .empty,

    fn deinit(self: *ShardReport, allocator: Allocator) void {
        self.nodes_liveness_unknown.deinit(allocator);
        self.nodes_lost.deinit(allocator);
        self.in_dir_lost_heads.deinit(allocator);
        self.adjacency.deinit(allocator);
    }

    pub fn damaged(self: *const ShardReport) bool {
        return self.nodes_liveness_unknown.items.len != 0 or self.nodes_lost.items.len != 0 or
            self.in_dir_lost_heads.items.len != 0 or self.adjacency.items.len != 0;
    }

    fn adjacencyIn(self: *const ShardReport, fid: gs.FileId) usize {
        var n: usize = 0;
        for (self.adjacency.items) |e| {
            if (e.file == fid) n += 1;
        }
        return n;
    }
};

pub const GraphReport = struct {
    uuid: [16]u8,
    /// The registry's name for the graph; null when the registry has none.
    name: ?[]u8,
    shards: std.ArrayList(ShardReport) = .empty,
};

pub const Report = struct {
    allocator: Allocator,
    key_supplied: bool,
    /// Legacy pages hold records but no key was given to read them.
    needs_key: bool = false,
    graphs: std.ArrayList(GraphReport) = .empty,

    pub fn deinit(self: *Report) void {
        for (self.graphs.items) |*g| {
            for (g.shards.items) |*s| s.deinit(self.allocator);
            g.shards.deinit(self.allocator);
            if (g.name) |n| self.allocator.free(n);
        }
        self.graphs.deinit(self.allocator);
    }

    pub fn ok(self: *const Report) bool {
        if (self.needs_key) return false;
        for (self.graphs.items) |g| {
            for (g.shards.items) |*s| if (s.damaged()) return false;
        }
        return true;
    }

    fn sumPages(self: *const Report, comptime field: []const u8) u64 {
        var n: u64 = 0;
        for (self.graphs.items) |g| {
            for (g.shards.items) |s| {
                for (@field(s, field)) |p| n += p;
            }
        }
        return n;
    }

    /// One JSON object (no trailing newline).
    pub fn writeJson(self: *const Report, w: *std.Io.Writer, data_dir: []const u8) !void {
        try w.writeAll("{\"check\":\"tde-page-tail\",\"data_dir\":");
        try std.json.Stringify.encodeJsonString(data_dir, .{}, w);
        try w.print(",\"tde_page_tail_ok\":{s},\"key_supplied\":{s},\"needs_key\":{s},\"old_format_pages\":{d},\"header_tag_pages\":{d},\"graphs\":[", .{ jsonBool(self.ok()), jsonBool(self.key_supplied), jsonBool(self.needs_key), self.sumPages("old_pages"), self.sumPages("new_pages") });
        for (self.graphs.items, 0..) |g, gi| {
            if (gi != 0) try w.writeByte(',');
            try w.writeAll("{\"graph\":");
            if (g.name) |n| try std.json.Stringify.encodeJsonString(n, .{}, w) else try w.writeAll("null");
            try w.print(",\"uuid\":\"{s}\",\"shards\":[", .{&std.fmt.bytesToHex(g.uuid, .lower)});
            for (g.shards.items, 0..) |s, si| {
                if (si != 0) try w.writeByte(',');
                try w.print("{{\"shard\":\"{s}\",\"page_size\":{d},\"old_format_pages\":{{", .{ &std.fmt.bytesToHex(s.uuid, .lower), s.page_size });
                for (paged_names, 0..) |name, i| {
                    if (i != 0) try w.writeByte(',');
                    try w.print("\"{s}\":{d}", .{ name, s.old_pages[i] });
                }
                try w.writeAll("},\"nodes_liveness_unknown\":");
                try writeIds(w, s.nodes_liveness_unknown.items);
                try w.writeAll(",\"nodes_lost\":");
                try writeIds(w, s.nodes_lost.items);
                try w.writeAll(",\"in_dir_lost_heads\":");
                try writeIds(w, s.in_dir_lost_heads.items);
                try w.writeAll(",\"adjacency_entries\":[");
                for (s.adjacency.items, 0..) |e, ei| {
                    if (ei != 0) try w.writeByte(',');
                    try w.print("{{\"file\":\"{s}\",\"page\":{d},\"slot\":{d},\"edge_id\":{d},\"neighbor\":{d}}}", .{ paged_names[pagedIndex(e.file)], e.page, e.slot, e.edge_id, e.neighbor });
                }
                try w.writeAll("]}");
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]}");
    }
};

fn jsonBool(b: bool) []const u8 {
    return if (b) "true" else "false";
}

fn writeIds(w: *std.Io.Writer, ids: []const u64) !void {
    try w.writeByte('[');
    for (ids, 0..) |id, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{d}", .{id});
    }
    try w.writeByte(']');
}

fn parseUuidDir(name: []const u8) ?[16]u8 {
    if (name.len != 32) return null;
    var out: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, name) catch return null;
    return out;
}

/// Sorted uuid-named subdirectories of `path` (a missing dir has none).
fn uuidDirs(allocator: Allocator, path: []const u8) ![][16]u8 {
    var list: std.ArrayList([16]u8) = .empty;
    errdefer list.deinit(allocator);
    var dir = std.Io.Dir.cwd().openDir(fsIo(), path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return list.toOwnedSlice(allocator),
        else => return e,
    };
    defer dir.close(fsIo());
    var it = dir.iterate();
    while (try it.next(fsIo())) |entry| {
        if (entry.kind != .directory) continue;
        if (parseUuidDir(entry.name)) |u| try list.append(allocator, u);
    }
    std.mem.sort([16]u8, list.items, {}, struct {
        fn lt(_: void, a: [16]u8, b: [16]u8) bool {
            return std.mem.order(u8, &a, &b) == .lt;
        }
    }.lt);
    return list.toOwnedSlice(allocator);
}

fn pathExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(fsIo(), path, .{}) catch return false;
    return true;
}

const ShardMeta = struct { page_size: u32, next_node_id: u64 };
/// `next_node_id` when no manifest could be read: lost slots are not
/// reported (an empty slot cannot be told from a never-allocated one).
const unknown_next = std.math.maxInt(u64);

fn readShardMeta(allocator: Allocator, shard_dir: []const u8, key: ?[32]u8) ShardMeta {
    const fallback: ShardMeta = .{ .page_size = 8192, .next_node_id = unknown_next };
    var picked: [2]?gs.manifest.Manifest = .{ null, null };
    for ([_][]const u8{ "manifest.a", "manifest.b" }, 0..) |name, i| {
        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ shard_dir, name }) catch return fallback;
        defer allocator.free(path);
        picked[i] = gs.manifest.Manifest.readFromFileWithKey(allocator, path, key) catch
            (gs.manifest.Manifest.readFromFileWithKey(allocator, path, null) catch null);
    }
    const m = gs.manifest.Manifest.selectManifest(picked[0], picked[1]) catch return fallback;
    return .{ .page_size = m.page_size, .next_node_id = m.next_node_id };
}

/// Read the store files under `data_dir` (`<graph uuid>/graphs/<shard uuid>/`)
/// and report every legacy-envelope page and the records it damaged.
/// Writes nothing. `key` is needed only to read the records of legacy pages.
pub fn scan(allocator: Allocator, data_dir: []const u8, key: ?[32]u8) !Report {
    var report: Report = .{ .allocator = allocator, .key_supplied = key != null };
    errdefer report.deinit();

    var registry = gs.registry.GraphRegistry.init(allocator);
    defer registry.deinit();
    {
        const reg_path = try std.fmt.allocPrint(allocator, "{s}/graph_registry.dat", .{data_dir});
        defer allocator.free(reg_path);
        if (pathExists(reg_path)) try registry.loadFromFile(reg_path);
    }

    const graph_uuids = try uuidDirs(allocator, data_dir);
    defer allocator.free(graph_uuids);
    for (graph_uuids) |guuid| {
        const ghex = std.fmt.bytesToHex(guuid, .lower);
        const shards_root = try std.fmt.allocPrint(allocator, "{s}/{s}/graphs", .{ data_dir, &ghex });
        defer allocator.free(shards_root);
        const shard_uuids = try uuidDirs(allocator, shards_root);
        defer allocator.free(shard_uuids);

        // Shard directories that hold a store; the graph's highest node id
        // bounds the directory heads worth reporting.
        var metas: std.ArrayList(ShardMeta) = .empty;
        defer metas.deinit(allocator);
        var dirs: std.ArrayList([]u8) = .empty;
        defer {
            for (dirs.items) |d| allocator.free(d);
            dirs.deinit(allocator);
        }
        var uuids: std.ArrayList([16]u8) = .empty;
        defer uuids.deinit(allocator);
        var graph_next: u64 = 0;
        for (shard_uuids) |suuid| {
            const shard_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ shards_root, &std.fmt.bytesToHex(suuid, .lower) });
            errdefer allocator.free(shard_dir);
            const nodes_path = try std.fmt.allocPrint(allocator, "{s}/nodes.store", .{shard_dir});
            defer allocator.free(nodes_path);
            if (!pathExists(nodes_path)) {
                allocator.free(shard_dir);
                continue;
            }
            const meta = readShardMeta(allocator, shard_dir, key);
            if (meta.next_node_id != unknown_next) graph_next = @max(graph_next, meta.next_node_id);
            try dirs.append(allocator, shard_dir);
            try metas.append(allocator, meta);
            try uuids.append(allocator, suuid);
        }
        if (dirs.items.len == 0) continue;
        if (graph_next == 0) graph_next = unknown_next;

        var g: GraphReport = .{ .uuid = guuid, .name = null };
        errdefer {
            for (g.shards.items) |*s| s.deinit(allocator);
            g.shards.deinit(allocator);
            if (g.name) |n| allocator.free(n);
        }
        if (registry.findByUuid(guuid)) |entry| g.name = try allocator.dupe(u8, entry.name);
        for (dirs.items, metas.items, uuids.items) |shard_dir, meta, suuid| {
            var s: ShardReport = .{ .uuid = suuid, .page_size = meta.page_size };
            errdefer s.deinit(allocator);
            try scanShard(allocator, &report, &s, shard_dir, meta, graph_next, key);
            try g.shards.append(allocator, s);
        }
        try report.graphs.append(allocator, g);
    }
    return report;
}

fn scanShard(allocator: Allocator, report: *Report, s: *ShardReport, shard_dir: []const u8, meta: ShardMeta, graph_next: u64, key: ?[32]u8) !void {
    const ps: usize = meta.page_size;
    if (ps <= PAGE_HEADER_SIZE + TAG_SIZE) return error.InvalidPageSize;
    const raw = try allocator.alloc(u8, ps);
    defer allocator.free(raw);
    const frame = try allocator.alloc(u8, ps);
    defer allocator.free(frame);
    const tail_start = ps - TAG_SIZE;
    // A sharded store allocates node ids at a fixed stride in one residue
    // class per shard (graph_storage `allocNode`): an id outside it was
    // never this shard's.
    const stride: u64 = gs.sharded_store.SHARD_COUNT;
    const residue = meta.next_node_id % stride;

    for (paged_files, 0..) |fid, fi| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ shard_dir, gs.file_manager.FILE_NAMES[@intFromEnum(fid)] });
        defer allocator.free(path);
        const file = std.Io.Dir.cwd().openFile(fsIo(), path, .{}) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };
        defer file.close(fsIo());
        var pager = gs.pager.Pager.init(file, meta.page_size);
        if (key) |k| pager.encryption = gs.encryption.PageEncryption.init(k);
        pager.file_id = fid;
        const pages = (try file.length(fsIo())) / ps;
        var pid: u64 = 0;
        while (pid < pages) : (pid += 1) {
            if (try file.readPositionalAll(fsIo(), raw, pid * ps) != ps) break;
            switch (classify(raw)) {
                .unwritten, .plaintext => continue,
                .header_tag => {
                    s.new_pages[fi] += 1;
                    continue;
                },
                .legacy => s.old_pages[fi] += 1,
            }
            // props and var reserve the tail; nothing there to lose.
            if (fid == .props or fid == .var_store) continue;
            if (key == null) {
                report.needs_key = true;
                continue;
            }
            // The library's own read of the page (legacy envelope: the
            // tail comes back zero), i.e. exactly what the engine sees.
            try pager.readPage(pid, frame);
            switch (fid) {
                .nodes => {
                    const npp: u64 = gs.node.nodesPerPage(meta.page_size);
                    var slot: u64 = 0;
                    while (slot < npp) : (slot += 1) {
                        const off = PAGE_HEADER_SIZE + slot * @sizeOf(NodeRec);
                        if (off + @sizeOf(NodeRec) <= tail_start) continue;
                        const id = pid * npp + slot;
                        const rec = std.mem.bytesToValue(NodeRec, frame[off..][0..@sizeOf(NodeRec)]);
                        if (!gs.node.isEmpty(&rec)) {
                            try s.nodes_liveness_unknown.append(allocator, id);
                        } else if (meta.next_node_id != unknown_next and id < meta.next_node_id and id % stride == residue) {
                            try s.nodes_lost.append(allocator, id);
                        }
                    }
                },
                .in_dir => {
                    const hpp: u64 = gs.in_head_dir.headsPerPage(meta.page_size);
                    var slot: u64 = 0;
                    while (slot < hpp) : (slot += 1) {
                        if (PAGE_HEADER_SIZE + (slot + 1) * 8 <= tail_start) continue;
                        const dst = pid * hpp + slot;
                        if (dst < graph_next) try s.in_dir_lost_heads.append(allocator, dst);
                    }
                },
                .adj_out, .adj_in, .in_idx => try scanChainBlock(allocator, s, fid, pid, frame, meta.page_size),
                else => {},
            }
        }
    }
}

/// A chain block (v1/v2/v3 entries after the 16-byte block header): report
/// the entries whose bytes reach the tail. Slab blocks reserve the tail.
fn scanChainBlock(allocator: Allocator, s: *ShardReport, fid: gs.FileId, pid: u64, frame: []const u8, page_size: u32) !void {
    const hdr_size = @sizeOf(gs.edge.EdgeBlockHeader);
    const bh = std.mem.bytesToValue(gs.edge.EdgeBlockHeader, frame[PAGE_HEADER_SIZE..][0..hdr_size]);
    const fmt = bh.entry_format;
    if (fmt != gs.edge.ENTRY_FORMAT_V1 and fmt != gs.edge.ENTRY_FORMAT_V2 and fmt != gs.edge.ENTRY_FORMAT_V3) return;
    if (bh.count == 0 or bh.count > gs.edge.entriesPerBlock(page_size, fmt)) return;
    const esz: usize = gs.edge.entrySize(fmt);
    const tail_start = page_size - TAG_SIZE;
    var slot: usize = 0;
    while (slot < bh.count) : (slot += 1) {
        const off = PAGE_HEADER_SIZE + hdr_size + slot * esz;
        if (off + esz <= tail_start) continue;
        const e = gs.edge.decodeEntry(frame[off..][0..esz], fmt);
        try s.adjacency.append(allocator, .{ .file = fid, .page = pid, .slot = @intCast(slot), .edge_id = e.edge_id, .neighbor = e.neighbor });
    }
}

pub const RepairSummary = struct {
    /// Slot-169 records given back their label_count (from the label block)
    /// and txn_stamp, and so rewritten in the current envelope.
    nodes_repaired: u64 = 0,
    /// Pages holding a lost record moved to the current envelope by
    /// rewriting a live record on them unchanged (the lost record stays absent).
    lost_pages_rewritten: u64 = 0,
    /// Lost records left on a legacy page (no live record on it to rewrite).
    lost_pages_left: u64 = 0,
    /// Shards whose incoming-edge directory was rebuilt from outgoing edges.
    in_dir_rebuilt_shards: u64 = 0,
    /// Shards whose directory was NOT rebuilt because their outgoing
    /// adjacency is itself damaged (a rebuild would copy the damage over the
    /// incoming side's intact copy). Needs a graph_storage API.
    in_dir_blocked_shards: u64 = 0,
    /// Damaged chain entries left as they are (no graph_storage API rewrites
    /// one entry of an adjacency block).
    adjacency_entries_unrepaired: u64 = 0,
    /// Graph directories on disk the registry does not name (not opened).
    graphs_skipped: u64 = 0,

    pub fn writeJson(self: RepairSummary, w: *std.Io.Writer) !void {
        try w.print("{{\"nodes_repaired\":{d},\"lost_pages_rewritten\":{d},\"lost_pages_left\":{d},\"in_dir_rebuilt_shards\":{d},\"in_dir_blocked_shards\":{d},\"adjacency_entries_unrepaired\":{d},\"graphs_skipped\":{d}}}", .{
            self.nodes_repaired,        self.lost_pages_rewritten,         self.lost_pages_left, self.in_dir_rebuilt_shards,
            self.in_dir_blocked_shards, self.adjacency_entries_unrepaired, self.graphs_skipped,
        });
    }
};

/// Repair what `report` (a `scan` taken BEFORE the store was opened) found,
/// through `adapter` (the same data directory, opened with the key). The
/// caller holds the data-directory lock and checkpoints afterwards.
pub fn repair(allocator: Allocator, adapter: *graph_storage_adapter.StorageAdapter, report: *const Report) !RepairSummary {
    var summary: RepairSummary = .{};
    for (report.graphs.items) |g| {
        var any = false;
        for (g.shards.items) |*s| any = any or s.damaged() or s.old_pages[pagedIndex(.in_dir)] != 0;
        if (!any) continue;
        const name = g.name orelse {
            summary.graphs_skipped += 1;
            continue;
        };
        const mg = try adapter.getOrCreateGraph(name);
        if (!std.mem.eql(u8, &mg.uuid, &g.uuid)) return error.GraphUuidMismatch;
        for (g.shards.items) |*s| {
            const shard = for (mg.engine.shards) |sh| {
                if (std.mem.eql(u8, &sh.graph_dir.graph_uuid, &s.uuid)) break sh;
            } else return error.ShardNotFound;
            try repairShard(allocator, shard, s, &summary);
        }
        try mg.engine.checkpoint();
    }
    return summary;
}

fn repairShard(allocator: Allocator, shard: *gs.GraphEngine, s: *const ShardReport, summary: *RepairSummary) !void {
    // 1. Node records: label_count is the label block's count (the block
    //    lives in var.store and was not in the tail); txn_stamp is the stamp
    //    geode writes at creation. flags stay 0: whether the node had been
    //    deleted is recorded nowhere else (the label index keeps deleted
    //    nodes' postings, deleteNode keeps every head), so it is reported.
    for (s.nodes_liveness_unknown.items) |id| {
        var rec = (try shard.getNode(id)) orelse continue;
        const labels = try shard.label_store.getLabels(rec.label_head, allocator);
        defer allocator.free(labels);
        rec.label_count = @intCast(labels.len);
        rec.txn_stamp = geode_node_txn_stamp;
        const txn = try shard.beginTxn();
        errdefer shard.abortTxn(txn) catch {};
        try shard.putNodeTxn(id, rec, txn);
        try shard.commitTxn(txn);
        summary.nodes_repaired += 1;
    }
    // 2. Pages with a lost record: nothing to restore; rewrite a live record
    //    of the same page unchanged so the page moves to the current
    //    envelope (the lost slot stays empty, as the engine already reads it).
    const npp: u64 = shard.node_store.nodes_per_page;
    const stride: u64 = gs.sharded_store.SHARD_COUNT;
    for (s.nodes_lost.items) |lost| {
        const first = (lost / npp) * npp;
        var id = first + (lost % stride + stride - first % stride) % stride;
        const done = while (id < first + npp) : (id += stride) {
            if (id == lost) continue;
            const rec = (try shard.getNode(id)) orelse continue;
            const txn = try shard.beginTxn();
            errdefer shard.abortTxn(txn) catch {};
            try shard.putNodeTxn(id, rec, txn);
            try shard.commitTxn(txn);
            break true;
        } else false;
        if (done) summary.lost_pages_rewritten += 1 else summary.lost_pages_left += 1;
    }
    // 3. The incoming-edge directory and chains (in_dir + in_idx): rebuilt
    //    from this shard's outgoing edges, the authoritative copy, rewriting
    //    every directory page. Not when an outgoing chain entry is itself
    //    damaged: the rebuild would copy that damage over the incoming
    //    side's copy of the entry.
    const out_damaged = s.adjacencyIn(.adj_out) != 0;
    if (s.in_dir_lost_heads.items.len != 0 or s.old_pages[pagedIndex(.in_dir)] != 0 or s.adjacencyIn(.in_idx) != 0) {
        if (out_damaged) {
            summary.in_dir_blocked_shards += 1;
            summary.adjacency_entries_unrepaired += s.adjacencyIn(.in_idx);
        } else {
            try shard.migrateColocateInEdges();
            summary.in_dir_rebuilt_shards += 1;
        }
    }
    // No graph_storage API rewrites a single entry of an adjacency block.
    summary.adjacency_entries_unrepaired += s.adjacencyIn(.adj_out) + s.adjacencyIn(.adj_in);
    try shard.checkpoint();
}
