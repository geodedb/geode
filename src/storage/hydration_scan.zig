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
//! GraphStore merges (core inserts shard-major on one thread, independent
//! product families on their own threads — see graph_store.zig
//! FamilyPipeline), issuing the SAME product-insert calls in the SAME
//! per-shard, ascending-slot order as the legacy scan — the 0021
//! hydration-guard/0012 no-double-count disciplines live entirely in the
//! merge (graph_store.zig) and are unchanged. Each accumulation is split
//! into a node-side and an edge-side arena so the merge frees each side
//! incrementally (T2b: the at-scale merge OOMed holding every shard's full
//! decoded copy while the global maps grew to full size).

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

// GAP-0062: var-store SLAB block layout (gs/src/var_store.zig, stable on-disk
// format; the layout constants there are private, mirrored here exactly like
// the legacy VAR_META_SIZE above — the marker/next_page checks below are the
// same defense-in-depth gs's readSlabBlockHeader uses, so a legacy page can
// never be misread as a slab block or vice versa):
//   [PageHeader 32B][VarSlab header 16B][byte runs → ...gap... ← slot dir][tail]
//   VarSlab header: next_page u64 (==0), marker u32 (==VAR_SLAB_MARKER),
//                   slot_count u32. Slot dir entries are 8B (offset u32,
//                   byte_len u32) growing backward from (page end - tail).
const VAR_SLAB_HEADER_SIZE: u32 = 16;
const VAR_SLAB_RUNS_OFFSET: u32 = PAGE_HEADER_SIZE + VAR_SLAB_HEADER_SIZE;
const VAR_SLAB_DIR_ENTRY_SIZE: u32 = 8;
const VAR_SLAB_SLOT_TOMBSTONE: u32 = 0xFFFF_FFFF;
const VAR_SLAB_MARKER: u32 = 0x5641_5253;

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

/// Per-shard accumulation, split into two independently-releasable arenas so
/// the merge can free each side INCREMENTALLY (T2b memory fix — the at-scale
/// merge OOMed holding every shard's full decoded copy alive while the global
/// resident maps grew to full size):
///
///   * `node_arena` — node-side payloads only: node `PropEntry` slices (keys +
///     decoded values) and `label_ids`. The merge's NODE phase is its only
///     consumer; `releaseNodeSide()` frees it the moment that shard's node
///     products are built.
///   * `edge_arena` — the `rows` array itself plus everything the EDGE phase
///     needs: `EdgeRow` slices and edge `PropEntry` payloads. Freed by
///     `deinit()` once the edge phase consumed the shard.
///
/// Scan-internal scaffolding (page buffers, adjacency block maps, chain
/// bookkeeping, var-store chunks) lives in a scratch arena local to
/// `scanShard` and is freed before it returns — it never survives into the
/// accumulation.
pub const ShardAccum = struct {
    node_arena: std.heap.ArenaAllocator,
    edge_arena: std.heap.ArenaAllocator,
    rows: []NodeRow = &.{},
    node_side_released: bool = false,
    released: bool = false,

    /// Free the node-side payloads (props + label ids) once the merge's node
    /// phase has consumed this shard. Also clears every row's node-side
    /// slices so a late reader can never dangle into the freed arena.
    /// Idempotent.
    pub fn releaseNodeSide(self: *ShardAccum) void {
        if (self.node_side_released) return;
        self.node_side_released = true;
        for (self.rows) |*row| {
            row.props = &.{};
            row.label_ids = &.{};
        }
        self.node_arena.deinit();
    }

    /// Idempotent full release (safe under the caller's blanket cleanup even
    /// after an explicit per-shard deinit during the merge).
    pub fn deinit(self: *ShardAccum) void {
        if (self.released) return;
        self.releaseNodeSide();
        self.released = true;
        self.rows = &.{};
        self.edge_arena.deinit();
    }
};

/// Kill switch for the scan-vs-manifest live-node check in `scanShard`:
/// GEODE_DISABLE_HYDRATION_LIVE_COUNT_CHECK=1 lets an operator hydrate a store
/// whose manifest counts are known to be wrong (e.g. to salvage what is left
/// of a damaged graph). Read per shard scan, a cold path.
fn liveCountCheckDisabled() bool {
    const raw_z = std.c.getenv("GEODE_DISABLE_HYDRATION_LIVE_COUNT_CHECK") orelse return false;
    const raw = std.mem.span(raw_z);
    return std.mem.eql(u8, raw, "1") or std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "yes");
}

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

/// Allocator routing for one shard scan (T2b memory fix):
///   * `node` — durable node-side payloads (node props, label ids); freed
///     first by the merge via `ShardAccum.releaseNodeSide()`.
///   * `edge` — durable edge-side payloads (rows array, EdgeRow slices, edge
///     props); freed by `ShardAccum.deinit()`.
///   * `scratch` — scan-internal scaffolding (page buffer, adjacency block
///     map, chain bookkeeping, var chunks, growth-churn ArrayLists); freed
///     before `scanShard` returns, so it never inflates the held accumulation.
const ScanAllocs = struct {
    node: Allocator,
    edge: Allocator,
    scratch: Allocator,
};

/// Scan ONE shard engine's store files sequentially and accumulate decoded
/// rows. Read-only against the engine (the only pool interaction is pinning
/// pages from the dirty snapshot, normally none). Thread-safe versus other
/// shards: touches only this shard's files/pool.
pub fn scanShard(
    base_allocator: Allocator,
    engine: *gs.engine.GraphEngine,
    opts: ScanOptions,
) !ShardAccum {
    var accum = ShardAccum{
        .node_arena = std.heap.ArenaAllocator.init(base_allocator),
        .edge_arena = std.heap.ArenaAllocator.init(base_allocator),
    };
    errdefer accum.deinit();

    // Scan-internal scaffolding arena: freed on return (success or error).
    var scratch_arena = std.heap.ArenaAllocator.init(base_allocator);
    defer scratch_arena.deinit();

    const allocs = ScanAllocs{
        .node = accum.node_arena.allocator(),
        .edge = accum.edge_arena.allocator(),
        .scratch = scratch_arena.allocator(),
    };

    var dirty = DirtySet{};
    try dirty.collect(allocs.scratch, &engine.buffer_pool);

    const page_size = engine.buffer_pool.page_size;
    const page_buf = try allocs.scratch.alloc(u8, page_size);

    // ---- pass 1: nodes.store ------------------------------------------------
    // Rows accumulate in SCRATCH (ArrayList doubling leaves dead capacity
    // behind in an arena) and are copied exact-size into the edge arena at the
    // end — the edge phase is the last consumer of the rows array.
    var rows: std.ArrayList(NodeRow) = .empty;
    const durable_live_before = @atomicLoad(u64, &engine.manifest.node_count, .monotonic);
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
                    try rows.append(allocs.scratch, .{
                        .slot = first_node + slot,
                        .prop_head = rec.prop_head,
                        .label_head = rec.label_head,
                        .out_head = rec.out_head,
                    });
                }
            }
        }
    }

    // CANARY: REQ=REQ-GQL-028; FEATURE="SnapshotCompaction"; ASPECT=ZeroedPageRebuildFailClosed; STATUS=TESTED; TEST=tests/canary_recovery_corrupt_latency.zig; OWNER=storage; UPDATED=2026-10-19
    // REQ-GQL-028 fail-closed: the pager reads a zeroed page (torn write,
    // zeroed sectors) as a FRESH page, so its node records look empty and
    // pass 1 skips them. Hydration then built the graph's indexes without
    // those nodes, and every read answered OK with them missing (0 of 300
    // rows). The shard manifest's live-node count is maintained on every
    // create and delete and persisted at checkpoint (WAL replay heals it), so
    // finding fewer live records than it promises means lost node data. Fail
    // the scan: the graph is quarantined and its reads fail closed. The
    // smaller of the counts read before and after the pass is used, so a
    // concurrent delete can never look like a loss.
    const durable_live = @min(durable_live_before, @atomicLoad(u64, &engine.manifest.node_count, .monotonic));
    if (rows.items.len < durable_live and !liveCountCheckDisabled()) {
        std.log.scoped(.hydration_scan).warn("hydration scan found {d} live node record(s) but the shard manifest counts {d}: node pages lost or zeroed -- refusing to hydrate from partial data", .{ rows.items.len, durable_live });
        return error.DataCorruption;
    }

    // ---- pass 2: adj_out.store (sequential read + in-memory chain walk) -----
    if (opts.include_edges) {
        try scanAdjacency(allocs, engine, &dirty, page_buf, rows.items);
    }

    // ---- pass 3: props.store (node blobs + edge blobs, ascending pages) -----
    try scanProps(allocs, engine, &dirty, page_buf, rows.items, opts);

    // ---- pass 4: var.store label chains (ascending pages per round) ---------
    try scanLabels(allocs, engine, &dirty, page_buf, rows.items, opts);

    accum.rows = try allocs.edge.dupe(NodeRow, rows.items);
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
    allocs: ScanAllocs,
    engine: *gs.engine.GraphEngine,
    dirty: *const DirtySet,
    page_buf: []u8,
    rows: []NodeRow,
) !void {
    var reader = try makeReader(engine, .adj_out, dirty, page_buf);
    const page_size = engine.buffer_pool.page_size;
    const block_header_size: u32 = @sizeOf(gs.edge.EdgeBlockHeader);
    // Slab slot directories grow backward from `page_size - tail_reserve`
    // (the at-rest-encryption tag tail), exactly as gs's AdjStore slab helpers
    // subtract it — so the streaming reader must use the SAME reserve.
    const tail_reserve = engine.adj_out.tail_reserve;

    // The block map (a full decoded copy of the adjacency store) is SCRATCH:
    // the per-row chain walk below copies each entry by value into the exact-
    // size edge-arena rows, so nothing references the blocks afterwards.
    var blocks: std.AutoHashMapUnmanaged(u64, AdjBlock) = .empty;
    // GAP-0062: adjacency SLAB packing (gs v0.2.34 `adjacency_slab_packing`,
    // default ON). A node with a SMALL out-edge chain (e.g. the
    // `__geode_security` graph's one HAS_ROLE edge per user) has its edge run
    // packed as a SLOT in a shared slab block (entry_format = ENTRY_FORMAT_SLAB)
    // and its `out_head` becomes a bit-63-tagged (block, slot) head ref. Slab
    // runs are decoded here keyed by the canonical bit-63-tagged head ref
    // (`encodeSlabHead(page, slot)`, i.e. exactly the node's `out_head`); the
    // per-node walk resolves a slab head against this map. Before this, the sweep
    // rejected `entry_format == ENTRY_FORMAT_SLAB` as DataCorruption (2 >
    // ENTRY_FORMAT_V2) and the per-node walk could not resolve a tagged head —
    // quarantining any small-chain graph (the security-graph auth lockout).
    var slab_runs: std.AutoHashMapUnmanaged(u64, []gs.edge.EdgeEntry) = .empty;

    // Sequential read of every allocated adjacency page. Every reachable
    // chain/slab block is allocated, so this covers all chains; unreachable
    // allocated blocks (none in a healthy store) are parsed and ignored,
    // exactly as the legacy walk never visited them.
    const total_pages = engine.free_space_adj_out.total_pages;
    var page_id: u64 = 1; // page 0 is the FSM-reserved metadata page
    while (page_id < total_pages) : (page_id += 1) {
        if (!engine.free_space_adj_out.isAllocated(page_id)) continue;
        const data = try reader.read(page_id);

        // Parse the block by ITS entry_format (GAP-ENT-0024 read-both),
        // mirroring gs.adj_store.readBlockHeader / readSlabBlockHeader.
        const bh_bytes = data[PAGE_HEADER_SIZE..][0..@sizeOf(gs.edge.EdgeBlockHeader)];
        const bh: gs.edge.EdgeBlockHeader = @bitCast(bh_bytes.*);

        // SLAB block (GAP-0062): decode each LIVE slot's run keyed by (page,
        // slot). Slot validation is deferred to the per-node lookup exactly as
        // gs's `resolveSlabRun` validates only the slot a live head references:
        // a tombstoned/out-of-range/overrunning slot is simply not inserted, so
        // a live head that resolves to it MISSES the map and raises
        // DataCorruption below, while an unreachable dead slot is ignored — the
        // same reachability semantics as the legacy per-node engine walk.
        if (bh.entry_format == gs.edge.ENTRY_FORMAT_SLAB or
            bh.entry_format == gs.edge.ENTRY_FORMAT_SLAB_V3)
        {
            try parseSlabBlock(allocs, data, page_id, tail_reserve, bh, &slab_runs);
            continue;
        }

        // Chain block. GAP-0060 read-both: v1 (24B), v2 (32B) and v3 (40B, wide
        // u64 prop_head) are all valid chain formats. Any OTHER value (SLAB /
        // SLAB_V3 handled above) is a genuinely unknown format — real corruption.
        if (bh.entry_format != gs.edge.ENTRY_FORMAT_V1 and
            bh.entry_format != gs.edge.ENTRY_FORMAT_V2 and
            bh.entry_format != gs.edge.ENTRY_FORMAT_V3) return error.DataCorruption;
        if (bh.count > gs.edge.entriesPerBlock(page_size, bh.entry_format)) return error.DataCorruption;

        const stride = gs.edge.entrySize(bh.entry_format);
        const entries = try allocs.scratch.alloc(gs.edge.EdgeEntry, bh.count);
        var i: u16 = 0;
        while (i < bh.count) : (i += 1) {
            const off = PAGE_HEADER_SIZE + block_header_size + @as(u32, i) * stride;
            // gs.edge.decodeEntry is the versioned wire codec that replaced the
            // extern-struct @bitCast in gs v0.2.35: it handles v1/v2/v3, widening
            // a legacy head losslessly (hi=0) and reading the full u64 head from
            // a v3 record.
            entries[i] = gs.edge.decodeEntry(data[off..][0..stride], bh.entry_format);
        }
        try blocks.put(allocs.scratch, page_id, .{ .next = bh.next_block, .entries = entries });
    }

    // In-memory chain walk per node: head block first, entries in block
    // order, then overflow blocks — identical to AdjEdgeIterator order.
    // Two-pass per node (count, then fill) so the durable edge arena holds
    // an EXACT-size slice — no ArrayList doubling waste surviving the scan.
    for (rows) |*row| {
        if (row.out_head == 0) continue;

        // GAP-0062: a bit-63-tagged slab head references a SINGLE contiguous
        // run in one slab block (never a chain). Mirror gs `AdjEdgeIterator`'s
        // slab mode + `expand`'s F1 guard (a tagged head decoding to page 0 is
        // corruption) + `resolveSlabRun` (a live head to a missing/dead slot is
        // corruption).
        if (gs.adj_store.isSlabHead(row.out_head)) {
            if (gs.adj_store.slabHeadPageId(row.out_head) == 0) return error.DataCorruption;
            const run = slab_runs.get(row.out_head) orelse return error.DataCorruption;
            const edge_rows = try allocs.edge.alloc(EdgeRow, run.len);
            for (run, 0..) |e, idx| edge_rows[idx] = .{ .entry = e };
            row.edges = edge_rows;
            continue;
        }

        var total: usize = 0;
        var current = row.out_head;
        var hops: u32 = 0;
        while (current != 0) : (hops += 1) {
            if (hops >= MAX_CHAIN_HOPS) return error.CircularChainDetected;
            // A chain pointer to a page the sequential scan did not see means
            // the chain escapes the allocated file — the legacy pool walk
            // would have failed the pin/read on that page.
            const block = blocks.get(current) orelse return error.DataCorruption;
            total += block.entries.len;
            current = block.next;
        }
        const edge_rows = try allocs.edge.alloc(EdgeRow, total);
        var idx: usize = 0;
        current = row.out_head;
        while (current != 0) {
            const block = blocks.get(current).?; // validated by the count pass
            for (block.entries) |e| {
                edge_rows[idx] = .{ .entry = e };
                idx += 1;
            }
            current = block.next;
        }
        row.edges = edge_rows;
    }
}

/// Decode every LIVE slot of one adjacency SLAB block into `slab_runs`
/// (GAP-0062). Mirrors gs `AdjStore.readSlabBlockHeader` (block-level
/// validation) + `resolveSlabRun` (per-slot bounds) + `readSlabRunEntry`
/// (format-strided run entries: v2 32B or slab-v3 40B). Block- or slot-level validation failures SKIP
/// (insert nothing) rather than fail the whole scan: gs only ever reads the
/// specific slot a live head references, so an unreachable/dead/corrupt slot
/// that no live head points at is invisible to a healthy read — a live head to
/// such a slot instead MISSES `slab_runs` and raises DataCorruption at lookup,
/// matching gs's reachability-scoped failure exactly.
fn parseSlabBlock(
    allocs: ScanAllocs,
    data: []const u8,
    page_id: u64,
    tail_reserve: u32,
    bh: gs.edge.EdgeBlockHeader,
    slab_runs: *std.AutoHashMapUnmanaged(u64, []gs.edge.EdgeEntry),
) !void {
    // Block-level validation (gs readSlabBlockHeader): a slab block is NEVER
    // chained, and its slot directory must fit above the runs region + tail.
    if (bh.next_block != 0) return;
    const dir_bytes: u64 = @as(u64, bh.count) * gs.edge.SLAB_DIR_ENTRY_SIZE;
    if (@as(u64, gs.edge.SLAB_RUNS_OFFSET) + dir_bytes + tail_reserve > data.len) return;

    const dir_start = gs.edge.slabDirStart(data.len, tail_reserve, bh.count);
    var slot: u32 = 0;
    while (slot < bh.count) : (slot += 1) {
        const s = gs.edge.readSlabSlot(data, tail_reserve, slot);
        // Dead slot (chain graduated to a dedicated block chain, or freed) —
        // no live head references it. Skip.
        if (s.offset == gs.edge.SLAB_SLOT_TOMBSTONE) continue;
        if (s.offset < gs.edge.SLAB_RUNS_OFFSET) continue;
        // GAP-0060: slab runs are v2 (32B) OR slab-v3 (40B, wide u64 head)
        // keyed by the block's entry_format (gs slabEntrySize / readSlabRunEntry).
        const run_stride = gs.edge.slabEntrySize(bh.entry_format);
        const run_end = @as(u64, s.offset) + @as(u64, s.entry_count) * @as(u64, run_stride);
        if (run_end > dir_start) continue;

        const entries = try allocs.scratch.alloc(gs.edge.EdgeEntry, s.entry_count);
        var i: u32 = 0;
        while (i < s.entry_count) : (i += 1) {
            const off = @as(usize, s.offset) + @as(usize, i) * @as(usize, run_stride);
            entries[i] = gs.edge.decodeEntry(data[off..][0..run_stride], bh.entry_format);
        }
        // Key by the canonical tagged head so the per-node walk looks up by
        // `row.out_head` directly (== encodeSlabHead(page_id, slot)).
        try slab_runs.put(allocs.scratch, gs.adj_store.encodeSlabHead(page_id, slot), entries);
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
    /// Entry LIST lives in scratch (append churn); the entries' key/value
    /// payloads are decoded straight into the consumer's durable arena. On
    /// chain completion the list is copied exact-size into that same arena.
    entries: std.ArrayList(PropEntry),
};

/// The durable arena a consumer's decoded property payloads belong to:
/// node blobs go to the node arena (released first by the merge), edge
/// blobs to the edge arena.
fn durableFor(allocs: ScanAllocs, consumer: PropConsumer) Allocator {
    return switch (consumer) {
        .node => allocs.node,
        .edge => allocs.edge,
    };
}

fn scanProps(
    allocs: ScanAllocs,
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
    // MANY nodes' blobs — the whole point of the sequential pass. Pure
    // scaffolding: scratch.
    var wanted: std.AutoHashMapUnmanaged(u64, std.ArrayList(PendingChain)) = .empty;

    for (rows, 0..) |*row, ri| {
        if (row.corrupt_skip) continue;
        if (row.prop_head != 0) {
            const page: u64 = if (gs.prop_store.isSlabHead(row.prop_head))
                gs.prop_store.slabPageId(row.prop_head)
            else
                row.prop_head;
            const gop = try wanted.getOrPut(allocs.scratch, page);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocs.scratch, .{
                .consumer = .{ .node = ri },
                .next_page = page,
                .hops = 0,
                .saw_internal_id = false,
                .entries = .empty,
            });
        }
        // Edge-prop consumers register INDEPENDENTLY of the node's blob:
        // a node with prop_head == 0 (no node property blob — reachable once
        // node public ids move inline and a node carries no user props) can
        // still own edges WITH property blobs. The pre-fix loop `continue`d
        // the whole row on prop_head == 0, silently dropping those edges'
        // property decode (latent data loss; the resident-mode public-id
        // recovery separately skips such rows in the merge, but non-resident
        // scans and edge props must not depend on the NODE blob's presence).
        if (opts.include_edges) {
            for (row.edges, 0..) |er, ei| {
                if (er.entry.prop_head == 0) continue;
                // GAP-0060: an edge prop_head may now be a SLAB head (bit 63),
                // exactly like a node's — mirror the node branch above and
                // resolve it to the slab PAGE id. Feeding a raw slab head to the
                // pager reads a bogus (≥2^63) page that zero-fills, which the
                // legacy parser then decodes as "0 properties" — a SILENT drop
                // of every slab-packed edge property (the GAP-0062 failure class,
                // reintroduced for edges by the v0.2.35 edge-prop slab re-pin).
                const ehead = er.entry.prop_head;
                const epage: u64 = if (gs.prop_store.isSlabHead(ehead))
                    gs.prop_store.slabPageId(ehead)
                else
                    ehead;
                const egop = try wanted.getOrPut(allocs.scratch, epage);
                if (!egop.found_existing) egop.value_ptr.* = .empty;
                try egop.value_ptr.append(allocs.scratch, .{
                    .consumer = .{ .edge = .{ .row = ri, .edge = ei } },
                    .next_page = epage,
                    .hops = 0,
                    .saw_internal_id = false,
                    .entries = .empty,
                });
            }
        }
    }

    // Multi-round ascending sweep: each round reads the currently-wanted
    // pages in ascending order; legacy chain continuations enqueue the next
    // page for the following round (multi-page chains are rare — one round
    // suffices for slab stores).
    while (wanted.size != 0) {
        var pages = try std.ArrayList(u64).initCapacity(allocs.scratch, wanted.size);
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
                            try consumeSlabBlob(allocs, logical, row, opts, chain);
                            continue;
                        }
                        try consumeLegacyPage(allocs, logical, chain, rows, opts, &next_wanted);
                    },
                    .edge => |e| {
                        const er = &rows[e.row].edges[e.edge];
                        // GAP-0060: a slab-packed edge prop is a SINGLE slab blob
                        // (hops==0), decoded like the node slab path — NOT the
                        // legacy page-chain parser.
                        if (gs.prop_store.isSlabHead(er.entry.prop_head) and chain.hops == 0) {
                            try consumeEdgeSlabBlob(allocs, logical, er, opts, chain);
                            continue;
                        }
                        try consumeLegacyPage(allocs, logical, chain, rows, opts, &next_wanted);
                    },
                }
            }
        }

        wanted = next_wanted;
    }
}

/// Decode one slab blob (page already read) into the node row.
fn consumeSlabBlob(
    allocs: ScanAllocs,
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
    parseEntries(allocs, blob[4..], entry_count, opts.internal_id_key, chain) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return nodeBlobCorrupt(row, opts, chain.saw_internal_id, err),
    };
    row.props = try allocs.node.dupe(PropEntry, chain.entries.items);
}

/// Decode one slab blob (page already read) into the EDGE row (GAP-0060).
/// Mirrors `consumeSlabBlob` (node path), but an edge blob has NO resident-mode
/// torn-page tolerance: a corrupt edge blob fails the whole hydration, exactly
/// as the legacy edge read did (`consumeLegacyPage`'s `.edge => return err`) and
/// as `getAllEdgeProperties` did under `try`. Uses the SAME `slabBlobSlice`
/// validator as the node path, so a genuinely-corrupt slab block/slot (bad
/// layout version, out-of-range slot, span past the backward-growing directory)
/// still raises `error.DataCorruption` here rather than being silently accepted.
fn consumeEdgeSlabBlob(
    allocs: ScanAllocs,
    logical: []const u8,
    er: *EdgeRow,
    opts: ScanOptions,
    chain: *PendingChain,
) !void {
    const blob = try slabBlobSlice(logical, er.entry.prop_head);
    if (blob.len < 4) return error.DataCorruption;
    const entry_count = std.mem.readInt(u32, blob[0..4], .little);
    try parseEntries(allocs, blob[4..], entry_count, opts.internal_id_key, chain);
    er.props = try allocs.edge.dupe(PropEntry, chain.entries.items);
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
    allocs: ScanAllocs,
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
        parseEntriesRegion(allocs, logical[PROP_DATA_OFFSET..], entry_count, opts.internal_id_key, chain) catch |err| switch (err) {
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
        const gop = try next_wanted.getOrPut(allocs.scratch, next_page);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        var moved = chain.*;
        moved.next_page = next_page;
        try gop.value_ptr.append(allocs.scratch, moved);
        return;
    }

    const durable = durableFor(allocs, chain.consumer);
    switch (chain.consumer) {
        .node => |ri| rows[ri].props = try durable.dupe(PropEntry, chain.entries.items),
        .edge => |e| rows[e.row].edges[e.edge].props = try durable.dupe(PropEntry, chain.entries.items),
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
    allocs: ScanAllocs,
    region: []const u8,
    entry_count: u32,
    internal_id_key: []const u8,
    chain: *PendingChain,
) !void {
    return parseEntriesRegion(allocs, region, entry_count, internal_id_key, chain);
}

/// Shared entry-region parser (slab blob body / legacy page entry region):
/// entry_count x { key_len u16, key bytes, self-delimiting encoded value }.
/// Duplicate keys keep their first position with the LAST value — the same
/// observable outcome as the legacy StringHashMap.put collection.
///
/// Key/value payloads go straight into the consumer's DURABLE arena (they
/// outlive the scan); the entry list itself appends in scratch and is copied
/// exact-size to the durable arena on chain completion.
fn parseEntriesRegion(
    allocs: ScanAllocs,
    region: []const u8,
    entry_count: u32,
    internal_id_key: []const u8,
    chain: *PendingChain,
) !void {
    const durable = durableFor(allocs, chain.consumer);
    var off: usize = 0;
    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        if (off + 2 > region.len) return error.DataCorruption;
        const key_len = std.mem.bytesToValue(u16, region[off..][0..2]);
        off += 2;
        if (off + key_len > region.len) return error.DataCorruption;
        const key_src = region[off..][0..key_len];
        off += key_len;
        const decoded = gs.property.decode(durable, region[off..]) catch return error.DataCorruption;
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
            const key_copy = try durable.dupe(u8, key_src);
            try chain.entries.append(allocs.scratch, .{ .key = key_copy, .value = decoded.value });
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
    allocs: ScanAllocs,
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
    const tail_reserve = engine.var_store.tail_reserve;

    // Chunk map / rounds / blob assembly are scratch; only the decoded
    // label-id slices (node side) are durable.
    var chunks: std.AutoHashMapUnmanaged(u64, VarChunk) = .empty;
    var round: std.ArrayList(u64) = .empty;
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;

    // GAP-0062: var-store SLAB packing (gs v0.2.34, unconditional). A node
    // whose label blob is small (every node — a handful of label ids) has its
    // label ids packed as a SLOT in a shared var slab block and its
    // `label_head` is a bit-63-tagged (block, slot) ref. `slab_pages` are the
    // slab BLOCK pages to read once (ascending); `var_slab_runs` maps each
    // canonical head (`encodeSlabHead(page, slot)`, i.e. the node's
    // `label_head`) to its decoded run bytes. Before this, `refFirstPage` on a
    // slab head (`head >> 16`) decoded to a bogus page the pager zero-filled,
    // so EVERY node silently hydrated with ZERO labels — the security graph's
    // :User/:Role/:Policy nodes vanished from `getNodesByLabel` (auth lockout).
    var slab_pages: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var var_slab_runs: std.AutoHashMapUnmanaged(u64, []const u8) = .empty;

    for (rows) |row| {
        if (row.label_head == 0) continue;
        if (row.corrupt_skip) continue;
        if (gs.var_store.isSlabHead(row.label_head)) {
            // F1 guard (mirrors VarStore.readSlab): a tagged head decoding to
            // page 0 is corruption, never silently empty.
            if (gs.var_store.slabHeadPageId(row.label_head) == 0) return error.DataCorruption;
            _ = try slab_pages.getOrPut(allocs.scratch, gs.var_store.slabHeadPageId(row.label_head));
            continue;
        }
        const first = gs.var_store.VarStore.refFirstPage(row.label_head);
        // Mirrors VarStore.read: a ref whose first page decodes to 0 is
        // invalid (the legacy getNodeLabels raised the same error).
        if (first == 0) return error.InvalidPageId;
        const gop = try seen.getOrPut(allocs.scratch, first);
        if (!gop.found_existing) try round.append(allocs.scratch, first);
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
            const chunk = try allocs.scratch.dupe(u8, data[PAGE_HEADER_SIZE + VAR_META_SIZE ..][0..data_len]);
            try chunks.put(allocs.scratch, page_id, .{ .next = next, .data = chunk });
            if (next != 0) {
                const gop = try seen.getOrPut(allocs.scratch, next);
                if (!gop.found_existing) try next_round.append(allocs.scratch, next);
            }
        }
        round = next_round;
    }

    // GAP-0062: read each var slab BLOCK page once (ascending) and decode its
    // LIVE slots into `var_slab_runs`. Same reachability-scoped leniency as the
    // adjacency slab parse: a dead/invalid slot no live head references is
    // ignored; a live head to such a slot MISSES the map at resolve and raises
    // DataCorruption — exactly gs `VarStore.resolveSlabRun`'s failure.
    if (slab_pages.size != 0) {
        var pages = try std.ArrayList(u64).initCapacity(allocs.scratch, slab_pages.size);
        var kit = slab_pages.keyIterator();
        while (kit.next()) |k| pages.appendAssumeCapacity(k.*);
        std.sort.pdq(u64, pages.items, {}, std.sort.asc(u64));
        for (pages.items) |page_id| {
            const data = try reader.read(page_id);
            try parseVarSlabBlock(allocs, data, page_id, tail_reserve, &var_slab_runs);
        }
    }

    // Resolve each node's blob and decode the label-id list with
    // LabelStore.getLabels' exact tolerance semantics.
    for (rows) |*row| {
        if (row.label_head == 0) continue;
        if (row.corrupt_skip) continue;

        // GAP-0062: a slab-headed label ref is a SINGLE run (never a chain).
        if (gs.var_store.isSlabHead(row.label_head)) {
            const blob = var_slab_runs.get(row.label_head) orelse return error.DataCorruption;
            row.label_ids = decodeLabelIds(allocs.node, blob) catch return error.DataCorruption;
            continue;
        }

        var blob: std.ArrayList(u8) = .empty;
        var current = gs.var_store.VarStore.refFirstPage(row.label_head);
        var hops: u32 = 0;
        while (current != 0) : (hops += 1) {
            if (hops >= MAX_CHAIN_HOPS) return error.CircularChainDetected;
            const chunk = chunks.get(current) orelse return error.DataCorruption;
            try blob.appendSlice(allocs.scratch, chunk.data);
            current = chunk.next;
        }
        row.label_ids = decodeLabelIds(allocs.node, blob.items) catch return error.DataCorruption;
    }
}

/// Decode every LIVE slot of one var-store SLAB block into `var_slab_runs`
/// (GAP-0062). Mirrors gs `VarStore.readSlabBlockHeader` (marker/next_page/dir
/// validation) + `resolveSlabRun` (per-slot bounds). Block/slot validation
/// failures SKIP (insert nothing) rather than fail the whole scan — a live head
/// to a skipped slot instead MISSES `var_slab_runs` at resolve and raises
/// DataCorruption, matching gs's reachability-scoped failure exactly.
fn parseVarSlabBlock(
    allocs: ScanAllocs,
    data: []const u8,
    page_id: u64,
    tail_reserve: u32,
    var_slab_runs: *std.AutoHashMapUnmanaged(u64, []const u8),
) !void {
    const off = PAGE_HEADER_SIZE;
    const next_page = std.mem.readInt(u64, data[off..][0..8], .little);
    const marker = std.mem.readInt(u32, data[off + 8 ..][0..4], .little);
    const slot_count = std.mem.readInt(u32, data[off + 12 ..][0..4], .little);
    // A tagged head must land on a slab block: a wrong marker (or a chained
    // slab block, or a dir that cannot fit) means this page is not the slab
    // block the head named — skip so the live head misses -> DataCorruption.
    if (marker != VAR_SLAB_MARKER) return;
    if (next_page != 0) return;
    const dir_bytes: u64 = @as(u64, slot_count) * VAR_SLAB_DIR_ENTRY_SIZE;
    if (@as(u64, VAR_SLAB_RUNS_OFFSET) + dir_bytes + tail_reserve > data.len) return;

    const dir_start: u64 = @as(u64, data.len) - tail_reserve - dir_bytes;
    var slot: u32 = 0;
    while (slot < slot_count) : (slot += 1) {
        const base = @as(usize, data.len) - tail_reserve - (@as(usize, slot) + 1) * VAR_SLAB_DIR_ENTRY_SIZE;
        const run_off = std.mem.readInt(u32, data[base..][0..4], .little);
        const byte_len = std.mem.readInt(u32, data[base + 4 ..][0..4], .little);
        if (run_off == VAR_SLAB_SLOT_TOMBSTONE) continue;
        if (run_off < VAR_SLAB_RUNS_OFFSET) continue;
        if (@as(u64, run_off) + @as(u64, byte_len) > dir_start) continue;
        const blob = try allocs.scratch.dupe(u8, data[run_off..][0..byte_len]);
        // Key by the canonical tagged head so the resolve looks up by
        // `row.label_head` directly (== encodeSlabHead(page_id, slot)).
        try var_slab_runs.put(allocs.scratch, gs.var_store.encodeSlabHead(page_id, slot), blob);
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

// ---------------------------------------------------------------------------
// T2c — bounded in-flight shard outputs (scan -> merge backpressure)
// ---------------------------------------------------------------------------

/// T2c: cumulative high-water of COMPLETED-BUT-UNMERGED shard outputs
/// (published by a scan worker, not yet node-side-retired by the merge)
/// across all stream-scan hydrations since the last reset. The at-scale
/// failure this instruments: the scan produced decoded shard outputs at up
/// to ~3.3 GB/s while the merge consumed them far slower, and with no
/// backpressure the completed outputs accumulated unbounded (RSS +5.7 GB/min
/// -> OOM kill at ~8 min on the 368 GB store). Hydration builds are
/// serialized store-wide (`hydration_build_mutex`), so this global is
/// effectively per-run-max-folded, never concurrently torn.
var g_inflight_high_water: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn hydrationInflightShardHighWater() u64 {
    return g_inflight_high_water.load(.acquire);
}

pub fn resetHydrationInflightShardHighWater() void {
    g_inflight_high_water.store(0, .release);
}

fn foldInflightHighWater(now: u64) void {
    var prev = g_inflight_high_water.load(.monotonic);
    while (now > prev) {
        prev = g_inflight_high_water.cmpxchgWeak(prev, now, .monotonic, .monotonic) orelse break;
    }
}

pub const GateError = error{HydrationGatePoisoned};

/// T2c: sliding-window admission gate between the per-shard scan workers and
/// the shard-major merge. Bounds, BY CONSTRUCTION, the number of shard
/// outputs alive at once (being-scanned + completed-but-unmerged) to `limit`:
/// a worker may only BEGIN decoding shard `s` once `s < retired + limit`,
/// and `retired` advances strictly in shard-major order as the merge
/// releases each shard's node side. Because the merge consumes shards in
/// index order and the window always contains the smallest unretired shard,
/// the worker owning that shard is always admitted — no deadlock.
///
/// Error discipline (C1 quarantine interaction): ANY failure — a scan worker
/// erroring on its shard, or the merge/family side erroring mid-consume —
/// must `poison()` the gate. Poisoning wakes every blocked worker (they exit
/// their stripes without publishing) and every merge wait (it returns
/// `error.HydrationGatePoisoned`), so all threads become joinable and the
/// hydration fails cleanly into the existing quarantine path instead of
/// deadlocking on a window that will never slide.
pub const InflightGate = struct {
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    cond: std.Io.Condition = std.Io.Condition.init,
    /// Window width: max shard outputs in flight (scanning + completed-
    /// unmerged). From GEODE_HYDRATION_INFLIGHT_SHARDS, default 3, min 1.
    limit: usize,
    /// Shards whose node side the merge has retired. Retirement is strictly
    /// shard-major (the merge's consume order), so this is a prefix count.
    retired: usize = 0,
    /// Completed-but-unmerged outputs (published, not yet retired).
    inflight_outputs: usize = 0,
    /// Per-shard published flags; slice owned by the caller, len shard_count.
    published: []bool,
    poisoned: bool = false,
    /// CLOCK_MONOTONIC ns of the LAST publish — the scan-phase end stamp
    /// (the scan and merge phases overlap under the gate, so the caller can
    /// no longer derive this from a join point).
    last_publish_ns: u64 = 0,

    /// Scan worker: block until shard `shard_idx` enters the admission
    /// window (or the gate is poisoned).
    pub fn beginShard(g: *InflightGate, shard_idx: usize) GateError!void {
        const io = std.Io.Threaded.global_single_threaded.io();
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        while (!g.poisoned and shard_idx >= g.retired + g.limit) {
            g.cond.waitUncancelable(io, &g.mutex);
        }
        if (g.poisoned) return error.HydrationGatePoisoned;
    }

    /// Scan worker: shard `shard_idx`'s output is complete and visible to
    /// the merge. `now_ns` is the caller's CLOCK_MONOTONIC stamp.
    pub fn publish(g: *InflightGate, shard_idx: usize, now_ns: u64) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        g.published[shard_idx] = true;
        g.inflight_outputs += 1;
        foldInflightHighWater(@intCast(g.inflight_outputs));
        if (now_ns > g.last_publish_ns) g.last_publish_ns = now_ns;
        g.cond.broadcast(io);
    }

    /// Merge: block until shard `shard_idx` is published. Fails immediately
    /// when the gate is poisoned (a worker died — its shard may never
    /// publish; bail into the quarantine path).
    pub fn waitPublished(g: *InflightGate, shard_idx: usize) GateError!void {
        const io = std.Io.Threaded.global_single_threaded.io();
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        while (!g.poisoned and !g.published[shard_idx]) {
            g.cond.waitUncancelable(io, &g.mutex);
        }
        if (g.poisoned) return error.HydrationGatePoisoned;
    }

    /// Merge: the node side of the current head shard has been released —
    /// slide the window so the next scan may begin.
    pub fn retireNext(g: *InflightGate) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        g.retired += 1;
        if (g.inflight_outputs > 0) g.inflight_outputs -= 1;
        g.cond.broadcast(io);
    }

    /// Any-side failure: wake every waiter permanently. Idempotent; called
    /// unconditionally on the hydration's exit path (no-op after success —
    /// all workers have already exited their stripes).
    pub fn poison(g: *InflightGate) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        g.poisoned = true;
        g.cond.broadcast(io);
    }

    pub fn lastPublishNs(g: *InflightGate) u64 {
        const io = std.Io.Threaded.global_single_threaded.io();
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        return g.last_publish_ns;
    }
};

test {
    std.testing.refAllDecls(@This());
}
