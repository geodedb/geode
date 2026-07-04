// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! GAP hydration fast-scan — SEQUENTIAL per-shard store streaming for the
//! loop2 first-access hydration (`loadOneGraphFromAdapterFull`).
//!
//! The legacy hydration walks the graph PER NODE through the engine read
//! path: every node costs several buffer-pool page-chain walks (props slab /
//! legacy chain, var.store label chain, adjacency chain, per-edge property
//! chains). At 14.27M nodes against a 368 GB store with an 8 GB pool this
//! degenerates into random 8 KB reads at ~7 MB/s effective (measured
//! 13 h 09 m on 2026-07-04).
//!
//! This module replaces the I/O pattern ONLY. Each shard's store files are
//! read a small number of times, each as a (near-)linear file scan in
//! ascending page order:
//!
//!   pass 1  nodes.store   — every allocated page; live NodeRec slots.
//!   pass 2  adj_out.store — every allocated page; edge blocks parsed by
//!                           their own entry_format (v1/v2 read-both), then
//!                           per-node chains resolved IN MEMORY (no I/O).
//!   pass 3  props.store   — only the pages referenced by node prop_heads
//!                           (slab pages dedup many nodes) and edge
//!                           prop_heads, in ascending order; blobs decoded.
//!   pass 4  var.store     — only label-chain pages, ascending; label id
//!                           blobs decoded (multi-page chains resolved with
//!                           follow-up rounds, still ascending per round).
//!
//! WHY direct pager reads instead of buffer-pool pins (design decision,
//! recorded for review): the scan is ONE-SHOT and the store is far larger
//! than the pool, so pinning every page would (a) serialize on the pool's
//! structural mutex per miss, (b) evict the pool's entire useful content,
//! and (c) cache 368 GB of pages that will never be read again. The pager
//! (`gs.pager.Pager.readPage`) already performs the exact per-page
//! decryption (TDE) and CRC32C validation the pool's miss path uses, so a
//! direct positional read is byte-identical to a pool miss. Correctness
//! versus DIRTY pool pages is handled explicitly: before scanning, each
//! shard snapshots its pool's dirty (file, page) set under the pool mutex
//! and routes exactly those pages through `buffer_pool.pin` (the set is
//! empty in practice: engine open ends with recovery flush + fresh
//! checkpoint, and geode's write paths hydrate a graph BEFORE its first
//! write, so no write can dirty this graph's pages while its hydration
//! scan runs — `ensureGraphHydrated`'s entry mutex serializes them).
//!
//! The module produces per-shard accumulations (`ShardAccum`) that the
//! GraphStore merges single-threaded, issuing the SAME product-insert calls
//! in the SAME per-shard, ascending-slot order as the legacy scan — the
//! 0021 hydration-guard/0012 no-double-count disciplines live entirely in
//! the merge (graph_store.zig) and are unchanged.

const std = @import("std");
const gs = @import("graph_storage");

const Allocator = std.mem.Allocator;
const PAGE_HEADER_SIZE = gs.page.PAGE_HEADER_SIZE;

/// Adjacency-chain / prop-chain / var-chain hop guard. Mirrors
/// `gs.adj_store.MAX_CHAIN_HOPS` (and the identical private constants in
/// prop_store/var_store) so a corrupt circular chain fails with the same
/// error the legacy pool-walk raised.
const MAX_CHAIN_HOPS: u32 = 100_000;

// Legacy property-page metadata layout (gs/src/prop_store.zig, stable on-disk
// format): [PageHeader 32B][next_page u64][entry_count u32][entries...],
// with a key-hash directory growing backward from the LOGICAL page end
// (ignored by the linear entry walk, exactly like gs's PropIterator).
const PROP_META_SIZE: u32 = 12;
const PROP_DATA_OFFSET: u32 = PAGE_HEADER_SIZE + PROP_META_SIZE;
const PROP_DIR_COUNT_SIZE: u32 = 2;
const PROP_DIR_ENTRY_SIZE: u32 = 4;

// Var-store page layout (gs/src/var_store.zig, stable on-disk format):
// [PageHeader 32B][next_page u64][data_len u32][data...].
const VAR_META_SIZE: u32 = 12;

/// One decoded property entry. `key` and any string/ext payload in `value`
/// are owned by the accumulation arena.
pub const PropEntry = struct {
    key: []const u8,
    value: gs.types.PropertyValue,
};

/// One outgoing edge of a node, in chain order (head block first, entries in
/// block order — identical to the legacy `AdjEdgeIterator` order).
pub const EdgeRow = struct {
    entry: gs.edge.EdgeEntry,
    /// Decoded edge property entries (ALL keys, including internal ones;
    /// the merge splits/filters). Empty when `entry.prop_head == 0`.
    props: []PropEntry = &.{},
};

/// One live node slot of the shard, ascending slot order.
pub const NodeRow = struct {
    slot: u64,
    prop_head: u64,
    label_head: u64,
    out_head: u64,
    /// Resident-mode only: the node's property blob was structurally corrupt
    /// BEFORE the internal-id entry was reached — the legacy loop1 skipped
    /// exactly this class of node (torn page tolerated per-node, 2026-05-22)
    /// and never read it again in loop2. The merge counts it as a skipped
    /// mapping and excludes it from every product.
    corrupt_skip: bool = false,
    /// Decoded node property entries (ALL keys, including internal ones).
    props: []PropEntry = &.{},
    /// Raw label ids from the var.store label blob (dictionary resolution
    /// happens in the merge — workers never touch the shared label dict).
    label_ids: []u32 = &.{},
    edges: []EdgeRow = &.{},
};

/// Per-shard accumulation. Everything inside is owned by `arena`.
pub const ShardAccum = struct {
    arena: std.heap.ArenaAllocator,
    rows: []NodeRow = &.{},

    pub fn deinit(self: *ShardAccum) void {
        self.arena.deinit();
    }
};

pub const ScanOptions = struct {
    /// False when the caller's edge-side products are fully covered by
    /// snapshots (P3 `skip_edge_scan`): passes 2 and the edge part of pass 3
    /// are skipped entirely.
    include_edges: bool,
    /// True when the IdMap is being scan-rebuilt (loop1 fallback). Controls
    /// the corrupt-node-blob semantics (skip node vs fail hydration) so the
    /// streaming scan is failure-mode-identical to the legacy per-node walk.
    resident_mode: bool,
    /// `graph_store.INTERNAL_NODE_ID_PROPERTY_KEY` (passed in to keep this
    /// module free of geode-side imports).
    internal_id_key: []const u8,
};

const DirtyKey = u64;

fn dirtyKey(file_id: gs.types.FileId, page_id: u64) DirtyKey {
    return (@as(u64, @intFromEnum(file_id)) << 56) | (page_id & ((@as(u64, 1) << 56) - 1));
}

/// Snapshot of one shard pool's DIRTY (file, page) set, taken once under the
/// pool mutex before the scan passes. See the module doc for why this is
/// sound (no writer can dirty this graph's pages mid-hydration).
const DirtySet = struct {
    map: std.AutoHashMapUnmanaged(DirtyKey, void) = .empty,

    fn collect(self: *DirtySet, alloc: Allocator, pool: *gs.buffer_pool.BufferPool) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        pool.mutex.lockUncancelable(io);
        defer pool.mutex.unlock(io);
        for (pool.frames[0..pool.capacity]) |*frame| {
            if (!frame.valid) continue;
            if (!frame.dirty) continue;
            try self.map.put(alloc, dirtyKey(frame.file_id, frame.page_id), {});
        }
    }

    fn contains(self: *const DirtySet, file_id: gs.types.FileId, page_id: u64) bool {
        if (self.map.size == 0) return false;
        return self.map.contains(dirtyKey(file_id, page_id));
    }
};

/// Sequential page reader for one store file of one shard. Reads via the
/// pager (decrypt + checksum, byte-identical to a pool miss) except for
/// pages present in the dirty snapshot, which are copied through the pool.
const PageReader = struct {
    pager: *gs.pager.Pager,
    pool: *gs.buffer_pool.BufferPool,
    file_id: gs.types.FileId,
    dirty: *const DirtySet,
    buf: []u8, // page_size bytes, reused across reads

    /// Read `page_id` into `buf` and return it. The returned slice is only
    /// valid until the next call.
    fn read(self: *PageReader, page_id: u64) ![]u8 {
        if (self.dirty.contains(self.file_id, page_id)) {
            const frame = try self.pool.pin(self.file_id, page_id);
            defer self.pool.unpin(self.pool.frameIndex(frame), false);
            @memcpy(self.buf, frame.dataSlice());
            return self.buf;
        }
        self.pager.readPage(page_id, self.buf) catch |err| switch (err) {
            // Allocated-but-never-written page (e.g. the FSM-reserved page 0
            // of a shard whose id stripe never touched it): the buffer pool's
            // miss path zero-fills exactly this case — mirror it so parsers
            // see the same all-zero page the legacy pin-walk saw.
            error.PageNotFound => @memset(self.buf, 0),
            else => return err,
        };
        return self.buf;
    }
};

fn makeReader(
    engine: *gs.engine.GraphEngine,
    file_id: gs.types.FileId,
    dirty: *const DirtySet,
    buf: []u8,
) !PageReader {
    const pager = engine.file_manager.getPager(file_id) orelse return error.FileNotFound;
    return .{
        .pager = pager,
        .pool = &engine.buffer_pool,
        .file_id = file_id,
        .dirty = dirty,
        .buf = buf,
    };
}

/// Scan ONE shard engine's store files sequentially and accumulate decoded
/// rows. Read-only against the engine (the only pool interaction is pinning
/// pages from the dirty snapshot, normally none). Thread-safe versus other
/// shards: touches only this shard's files/pool.
pub fn scanShard(
    base_allocator: Allocator,
    engine: *gs.engine.GraphEngine,
    opts: ScanOptions,
) !ShardAccum {
    var accum = ShardAccum{ .arena = std.heap.ArenaAllocator.init(base_allocator) };
    errdefer accum.deinit();
    const arena = accum.arena.allocator();

    var dirty = DirtySet{};
    try dirty.collect(arena, &engine.buffer_pool);

    const page_size = engine.buffer_pool.page_size;
    const page_buf = try arena.alloc(u8, page_size);

    // ---- pass 1: nodes.store ------------------------------------------------
    var rows: std.ArrayList(NodeRow) = .empty;
    {
        var reader = try makeReader(engine, .nodes, &dirty, page_buf);
        const npp = gs.node.nodesPerPage(page_size);
        const max_node_id = engine.manifest.next_node_id;
        if (max_node_id > 0) {
            const last_page = (max_node_id - 1) / npp;
            var page_id: u64 = 0;
            while (page_id <= last_page) : (page_id += 1) {
                if (!engine.free_space_nodes.isAllocated(page_id)) continue;
                const data = try reader.read(page_id);
                const first_node = page_id * npp;
                const remaining = max_node_id - first_node;
                const slots: u32 = if (remaining >= npp) npp else @intCast(remaining);
                var slot: u32 = 0;
                while (slot < slots) : (slot += 1) {
                    const off = PAGE_HEADER_SIZE + slot * @sizeOf(gs.node.NodeRec);
                    const rec = std.mem.bytesToValue(gs.node.NodeRec, data[off..][0..@sizeOf(gs.node.NodeRec)]);
                    if (gs.node.isEmpty(&rec)) continue;
                    if (gs.node.isDeleted(&rec)) continue;
                    try rows.append(arena, .{
                        .slot = first_node + slot,
                        .prop_head = rec.prop_head,
                        .label_head = rec.label_head,
                        .out_head = rec.out_head,
                    });
                }
            }
        }
    }

    // ---- pass 2: adj_out.store (sequential read + in-memory chain walk) -----
    if (opts.include_edges) {
        try scanAdjacency(arena, engine, &dirty, page_buf, rows.items);
    }

    // ---- pass 3: props.store (node blobs + edge blobs, ascending pages) -----
    try scanProps(arena, engine, &dirty, page_buf, rows.items, opts);

    // ---- pass 4: var.store label chains (ascending pages per round) ---------
    try scanLabels(arena, engine, &dirty, page_buf, rows.items, opts);

    accum.rows = rows.items;
    return accum;
}

// ---------------------------------------------------------------------------
// pass 2 — adjacency
// ---------------------------------------------------------------------------

const AdjBlock = struct {
    next: u64,
    entries: []gs.edge.EdgeEntry,
};

fn scanAdjacency(
    arena: Allocator,
    engine: *gs.engine.GraphEngine,
    dirty: *const DirtySet,
    page_buf: []u8,
    rows: []NodeRow,
) !void {
    var reader = try makeReader(engine, .adj_out, dirty, page_buf);
    const page_size = engine.buffer_pool.page_size;
    const block_header_size: u32 = @sizeOf(gs.edge.EdgeBlockHeader);

    var blocks: std.AutoHashMapUnmanaged(u64, AdjBlock) = .empty;

    // Sequential read of every allocated adjacency page. Every reachable
    // chain block is allocated, so this covers all chains; unreachable
    // allocated blocks (none in a healthy store) are parsed and ignored,
    // exactly as the legacy walk never visited them.
    const total_pages = engine.free_space_adj_out.total_pages;
    var page_id: u64 = 1; // page 0 is the FSM-reserved metadata page
    while (page_id < total_pages) : (page_id += 1) {
        if (!engine.free_space_adj_out.isAllocated(page_id)) continue;
        const data = try reader.read(page_id);

        // Parse the block by ITS entry_format (GAP-ENT-0024 read-both),
        // mirroring gs.adj_store.readBlockHeader's validation.
        const bh_bytes = data[PAGE_HEADER_SIZE..][0..@sizeOf(gs.edge.EdgeBlockHeader)];
        const bh: gs.edge.EdgeBlockHeader = @bitCast(bh_bytes.*);
        if (bh.entry_format > gs.edge.ENTRY_FORMAT_V2) return error.DataCorruption;
        if (bh.count > gs.edge.entriesPerBlock(page_size, bh.entry_format)) return error.DataCorruption;

        const stride = gs.edge.entrySize(bh.entry_format);
        const entries = try arena.alloc(gs.edge.EdgeEntry, bh.count);
        var i: u16 = 0;
        while (i < bh.count) : (i += 1) {
            const off = PAGE_HEADER_SIZE + block_header_size + @as(u32, i) * stride;
            if (bh.entry_format == gs.edge.ENTRY_FORMAT_V2) {
                const bytes = data[off..][0..gs.edge.ENTRY_SIZE_V2];
                entries[i] = @bitCast(bytes.*);
            } else {
                var e = gs.edge.EdgeEntry{
                    .neighbor = 0,
                    .edge_id = 0,
                    .rel_type = 0,
                    .prop_head = 0,
                    .public_id = 0,
                };
                @memcpy(std.mem.asBytes(&e)[0..gs.edge.ENTRY_SIZE_V1], data[off..][0..gs.edge.ENTRY_SIZE_V1]);
                entries[i] = e;
            }
        }
        try blocks.put(arena, page_id, .{ .next = bh.next_block, .entries = entries });
    }

    // In-memory chain walk per node: head block first, entries in block
    // order, then overflow blocks — identical to AdjEdgeIterator order.
    for (rows) |*row| {
        if (row.out_head == 0) continue;
        var edge_rows: std.ArrayList(EdgeRow) = .empty;
        var current = row.out_head;
        var hops: u32 = 0;
        while (current != 0) : (hops += 1) {
            if (hops >= MAX_CHAIN_HOPS) return error.CircularChainDetected;
            // A chain pointer to a page the sequential scan did not see means
            // the chain escapes the allocated file — the legacy pool walk
            // would have failed the pin/read on that page.
            const block = blocks.get(current) orelse return error.DataCorruption;
            for (block.entries) |e| try edge_rows.append(arena, .{ .entry = e });
            current = block.next;
        }
        row.edges = edge_rows.items;
    }
}

// ---------------------------------------------------------------------------
// pass 3 — properties
// ---------------------------------------------------------------------------

/// A consumer of property bytes: either a node's blob or one edge's blob.
const PropConsumer = union(enum) {
    node: usize, // rows index
    edge: struct { row: usize, edge: usize },
};

const PendingChain = struct {
    consumer: PropConsumer,
    next_page: u64,
    hops: u32,
    /// True once the internal-id key has been decoded for this consumer
    /// (resident-mode corrupt-skip semantics — see NodeRow.corrupt_skip).
    saw_internal_id: bool,
    entries: std.ArrayList(PropEntry),
};

fn scanProps(
    arena: Allocator,
    engine: *gs.engine.GraphEngine,
    dirty: *const DirtySet,
    page_buf: []u8,
    rows: []NodeRow,
    opts: ScanOptions,
) !void {
    var reader = try makeReader(engine, .props, dirty, page_buf);
    const page_size = engine.buffer_pool.page_size;
    // Slab/legacy directories grow backward from the LOGICAL page end
    // (physical page minus the at-rest-encryption tag tail).
    const logical_len: u32 = page_size - engine.prop_store.tail_reserve;

    // wanted: page -> consumers that start on it. Slab pages typically carry
    // MANY nodes' blobs — the whole point of the sequential pass.
    var wanted: std.AutoHashMapUnmanaged(u64, std.ArrayList(PendingChain)) = .empty;

    for (rows, 0..) |*row, ri| {
        if (row.prop_head == 0) continue;
        if (row.corrupt_skip) continue;
        const page: u64 = if (gs.prop_store.isSlabHead(row.prop_head))
            gs.prop_store.slabPageId(row.prop_head)
        else
            row.prop_head;
        const gop = try wanted.getOrPut(arena, page);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, .{
            .consumer = .{ .node = ri },
            .next_page = page,
            .hops = 0,
            .saw_internal_id = false,
            .entries = .empty,
        });
        if (opts.include_edges) {
            for (row.edges, 0..) |er, ei| {
                if (er.entry.prop_head == 0) continue;
                const epage: u64 = er.entry.prop_head; // edge heads are legacy page ids
                const egop = try wanted.getOrPut(arena, epage);
                if (!egop.found_existing) egop.value_ptr.* = .empty;
                try egop.value_ptr.append(arena, .{
                    .consumer = .{ .edge = .{ .row = ri, .edge = ei } },
                    .next_page = epage,
                    .hops = 0,
                    .saw_internal_id = false,
                    .entries = .empty,
                });
            }
        }
    }
    // Edge consumers for rows whose NODE blob is on a shared slab page but
    // which themselves were registered above; nothing else to add.

    // Multi-round ascending sweep: each round reads the currently-wanted
    // pages in ascending order; legacy chain continuations enqueue the next
    // page for the following round (multi-page chains are rare — one round
    // suffices for slab stores).
    while (wanted.size != 0) {
        var pages = try std.ArrayList(u64).initCapacity(arena, wanted.size);
        var kit = wanted.keyIterator();
        while (kit.next()) |k| pages.appendAssumeCapacity(k.*);
        std.sort.pdq(u64, pages.items, {}, std.sort.asc(u64));

        var next_wanted: std.AutoHashMapUnmanaged(u64, std.ArrayList(PendingChain)) = .empty;

        for (pages.items) |page_id| {
            const consumers = wanted.getPtr(page_id).?;
            const data = try reader.read(page_id);
            const logical = data[0..logical_len];

            for (consumers.items) |*chain| {
                switch (chain.consumer) {
                    .node => |ri| {
                        const row = &rows[ri];
                        if (gs.prop_store.isSlabHead(row.prop_head) and chain.hops == 0) {
                            try consumeSlabBlob(arena, logical, row, opts, chain);
                            continue;
                        }
                        try consumeLegacyPage(arena, logical, chain, rows, opts, &next_wanted);
                    },
                    .edge => try consumeLegacyPage(arena, logical, chain, rows, opts, &next_wanted),
                }
            }
        }

        wanted = next_wanted;
    }
}

/// Decode one slab blob (page already read) into the node row.
fn consumeSlabBlob(
    arena: Allocator,
    logical: []const u8,
    row: *NodeRow,
    opts: ScanOptions,
    chain: *PendingChain,
) !void {
    const blob = slabBlobSlice(logical, row.prop_head) catch |err| {
        return nodeBlobCorrupt(row, opts, chain.saw_internal_id, err);
    };
    if (blob.len < 4) return nodeBlobCorrupt(row, opts, chain.saw_internal_id, error.DataCorruption);
    const entry_count = std.mem.readInt(u32, blob[0..4], .little);
    parseEntries(arena, blob[4..], entry_count, opts.internal_id_key, chain) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return nodeBlobCorrupt(row, opts, chain.saw_internal_id, err),
    };
    row.props = chain.entries.items;
}

/// Validate + slice a slab blob out of a logical slab page. Mirrors
/// gs.prop_store's private `slabBlobSpan` checks (layout version byte, slot
/// bounds, span bounds versus the backward-growing slot directory).
fn slabBlobSlice(logical: []const u8, prop_head: u64) ![]const u8 {
    if (logical.len < gs.prop_store.SLAB_DATA_OFFSET + gs.prop_store.SLAB_SLOT_COUNT_SIZE)
        return error.DataCorruption;
    if (logical[gs.prop_store.SLAB_META_OFFSET] != gs.prop_store.SLAB_LAYOUT_VERSION)
        return error.DataCorruption;
    const slot = gs.prop_store.slabSlot(prop_head);
    const slot_count = gs.prop_store.readSlabSlotCount(logical);
    if (slot >= slot_count) return error.DataCorruption;
    const dir_bytes = gs.prop_store.SLAB_SLOT_COUNT_SIZE +
        @as(u64, slot_count) * gs.prop_store.SLAB_SLOT_SIZE;
    if (dir_bytes + gs.prop_store.SLAB_DATA_OFFSET > logical.len) return error.DataCorruption;
    const span = gs.prop_store.readSlabSlot(logical, slot);
    if (span.offset < gs.prop_store.SLAB_DATA_OFFSET) return error.DataCorruption;
    const end = @as(u64, span.offset) + span.len;
    if (end > logical.len - dir_bytes) return error.DataCorruption;
    return logical[span.offset..][0..span.len];
}

/// Decode the entry region of one LEGACY property page for `chain`'s
/// consumer, then either finish (next_page == 0) or enqueue the
/// continuation page for the next round.
fn consumeLegacyPage(
    arena: Allocator,
    logical: []const u8,
    chain: *PendingChain,
    rows: []NodeRow,
    opts: ScanOptions,
    next_wanted: *std.AutoHashMapUnmanaged(u64, std.ArrayList(PendingChain)),
) !void {
    if (chain.hops >= MAX_CHAIN_HOPS) return error.CircularChainDetected;
    chain.hops += 1;

    const parse_err: ?anyerror = blk: {
        if (logical.len < PROP_DATA_OFFSET + PROP_DIR_COUNT_SIZE) break :blk error.DataCorruption;
        const entry_count = std.mem.bytesToValue(u32, logical[PAGE_HEADER_SIZE + 8 ..][0..4]);
        // Mirror gs readEntryCountChecked: min entry 3 bytes + 4 dir bytes.
        const capacity = @as(u32, @intCast(logical.len)) - PROP_DATA_OFFSET - PROP_DIR_COUNT_SIZE;
        if (entry_count > capacity / (3 + PROP_DIR_ENTRY_SIZE)) break :blk error.DataCorruption;
        parseEntriesRegion(arena, logical[PROP_DATA_OFFSET..], entry_count, opts.internal_id_key, chain) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => break :blk err,
        };
        break :blk null;
    };

    if (parse_err) |err| {
        switch (chain.consumer) {
            .node => |ri| return nodeBlobCorrupt(&rows[ri], opts, chain.saw_internal_id, err),
            // Edge property chains: the legacy walk read them under `try`
            // (getAllEdgeProperties / the internal-id fallback read) — a
            // corrupt page always failed the whole hydration.
            .edge => return err,
        }
    }

    const next_page = std.mem.bytesToValue(u64, logical[PAGE_HEADER_SIZE..][0..8]);
    if (next_page != 0) {
        const gop = try next_wanted.getOrPut(arena, next_page);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        var moved = chain.*;
        moved.next_page = next_page;
        try gop.value_ptr.append(arena, moved);
        return;
    }

    switch (chain.consumer) {
        .node => |ri| rows[ri].props = chain.entries.items,
        .edge => |e| rows[e.row].edges[e.edge].props = chain.entries.items,
    }
}

/// Resident-mode torn-page tolerance: a node blob that fails BEFORE its
/// internal-id entry was decoded is skipped per-node (matching the legacy
/// loop1 catch of DataCorruption/CircularChainDetected on the id read: the
/// node never entered the IdMap, so loop2 skipped it without reading
/// further). Any other structural failure fails hydration, exactly like the
/// legacy `try getAllNodeProperties` in loop2.
fn nodeBlobCorrupt(row: *NodeRow, opts: ScanOptions, saw_internal_id: bool, err: anyerror) anyerror!void {
    if (opts.resident_mode and !saw_internal_id) {
        row.corrupt_skip = true;
        row.props = &.{};
        return;
    }
    return err;
}

/// Parse `entry_count` property entries out of a slab blob's entry region.
fn parseEntries(
    arena: Allocator,
    region: []const u8,
    entry_count: u32,
    internal_id_key: []const u8,
    chain: *PendingChain,
) !void {
    return parseEntriesRegion(arena, region, entry_count, internal_id_key, chain);
}

/// Shared entry-region parser (slab blob body / legacy page entry region):
/// entry_count x { key_len u16, key bytes, self-delimiting encoded value }.
/// Duplicate keys keep their first position with the LAST value — the same
/// observable outcome as the legacy StringHashMap.put collection.
fn parseEntriesRegion(
    arena: Allocator,
    region: []const u8,
    entry_count: u32,
    internal_id_key: []const u8,
    chain: *PendingChain,
) !void {
    var off: usize = 0;
    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        if (off + 2 > region.len) return error.DataCorruption;
        const key_len = std.mem.bytesToValue(u16, region[off..][0..2]);
        off += 2;
        if (off + key_len > region.len) return error.DataCorruption;
        const key_src = region[off..][0..key_len];
        off += key_len;
        const decoded = gs.property.decode(arena, region[off..]) catch return error.DataCorruption;
        off += decoded.bytes_read;

        if (std.mem.eql(u8, key_src, internal_id_key)) chain.saw_internal_id = true;

        // Last-wins dedupe, preserving first-seen position.
        var replaced = false;
        for (chain.entries.items) |*existing| {
            if (std.mem.eql(u8, existing.key, key_src)) {
                existing.value = decoded.value;
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            const key_copy = try arena.dupe(u8, key_src);
            try chain.entries.append(arena, .{ .key = key_copy, .value = decoded.value });
        }
    }
}

// ---------------------------------------------------------------------------
// pass 4 — var.store label chains
// ---------------------------------------------------------------------------

const VarChunk = struct {
    next: u64,
    data: []const u8,
};

fn scanLabels(
    arena: Allocator,
    engine: *gs.engine.GraphEngine,
    dirty: *const DirtySet,
    page_buf: []u8,
    rows: []NodeRow,
    opts: ScanOptions,
) !void {
    _ = opts;
    var reader = try makeReader(engine, .var_store, dirty, page_buf);
    const page_size = engine.buffer_pool.page_size;
    const cap: u32 = page_size - PAGE_HEADER_SIZE - VAR_META_SIZE;

    var chunks: std.AutoHashMapUnmanaged(u64, VarChunk) = .empty;
    var round: std.ArrayList(u64) = .empty;
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;

    for (rows) |row| {
        if (row.label_head == 0) continue;
        if (row.corrupt_skip) continue;
        const first = gs.var_store.VarStore.refFirstPage(row.label_head);
        // Mirrors VarStore.read: a ref whose first page decodes to 0 is
        // invalid (the legacy getNodeLabels raised the same error).
        if (first == 0) return error.InvalidPageId;
        const gop = try seen.getOrPut(arena, first);
        if (!gop.found_existing) try round.append(arena, first);
    }

    // Ascending sweep per round; multi-page label chains (>4052 bytes of
    // label ids — essentially never) enqueue continuations for round n+1.
    while (round.items.len != 0) {
        std.sort.pdq(u64, round.items, {}, std.sort.asc(u64));
        var next_round: std.ArrayList(u64) = .empty;
        for (round.items) |page_id| {
            const data = try reader.read(page_id);
            const next = std.mem.bytesToValue(u64, data[PAGE_HEADER_SIZE..][0..8]);
            const data_len = std.mem.bytesToValue(u32, data[PAGE_HEADER_SIZE + 8 ..][0..4]);
            if (data_len > cap) return error.DataCorruption;
            const chunk = try arena.dupe(u8, data[PAGE_HEADER_SIZE + VAR_META_SIZE ..][0..data_len]);
            try chunks.put(arena, page_id, .{ .next = next, .data = chunk });
            if (next != 0) {
                const gop = try seen.getOrPut(arena, next);
                if (!gop.found_existing) try next_round.append(arena, next);
            }
        }
        round = next_round;
    }

    // Resolve each node's blob from the chunk map and decode the label-id
    // list with LabelStore.getLabels' exact tolerance semantics.
    for (rows) |*row| {
        if (row.label_head == 0) continue;
        if (row.corrupt_skip) continue;
        var blob: std.ArrayList(u8) = .empty;
        var current = gs.var_store.VarStore.refFirstPage(row.label_head);
        var hops: u32 = 0;
        while (current != 0) : (hops += 1) {
            if (hops >= MAX_CHAIN_HOPS) return error.CircularChainDetected;
            const chunk = chunks.get(current) orelse return error.DataCorruption;
            try blob.appendSlice(arena, chunk.data);
            current = chunk.next;
        }
        row.label_ids = decodeLabelIds(arena, blob.items) catch return error.DataCorruption;
    }
}

/// gs.label_store.LabelStore.getLabels decode semantics: short/truncated
/// blobs yield an EMPTY label set (never an error).
fn decodeLabelIds(arena: Allocator, data: []const u8) ![]u32 {
    if (data.len < 2) return try arena.alloc(u32, 0);
    const count = std.mem.readInt(u16, data[0..2], .little);
    const needed = 2 + @as(usize, count) * 4;
    if (data.len < needed) return try arena.alloc(u32, 0);
    const result = try arena.alloc(u32, count);
    for (0..count) |i| {
        result[i] = std.mem.readInt(u32, data[2 + i * 4 ..][0..4], .little);
    }
    return result;
}

test {
    std.testing.refAllDecls(@This());
}
