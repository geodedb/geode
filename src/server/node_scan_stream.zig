const std = @import("std");
const schema = @import("schema");
const gs = @import("graph_storage");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const execution = @import("../execution.zig");
// SONNY-3321: the compile-time field allowlist (`onlyFields`).
const write_shape = @import("../execution/write_shape.zig");
const graph_store = @import("../graph_store.zig");
const graph_storage_adapter = @import("../storage/graph_storage_adapter.zig");
const stored_property_equality = @import("../execution/stored_property_equality.zig");
const property_value_codec = @import("../property_value_codec.zig");
const value_types = @import("../value_types.zig");
const result_utils = @import("../execution/result_utils.zig");
const type_helpers = @import("../eval/type_helpers.zig");
// SONNY-1221 (GEO-UP-008): the executor path's schema typing
// (`buildSchemaDefinition`), so this path's schema frame types a projection
// column exactly the way the executor's does.
const proto_util = @import("proto_util.zig");
// SONNY-1229 (GEO-UP-002): the shared strict-tenancy / tenant-scope decision.
// Same leaf module `crud_operations.tenantFilterFromContext`,
// `match_operations.getSessionTenantFilter` and
// `planned_read_runtime.buildPlanIfSupported` delegate to, so this path's
// "can I serve it?" answer is derived from the SAME resolution as the
// executor's "what may it see?" answer.
const tenancy = @import("../execution/tenancy.zig");
// SONNY-2656: `hasEncryptedFields` decides whether a WHERE may run on the
// per-node scratch arena (see `predicateAllocator`).
const fle_integration = @import("../fle_integration.zig");

const ExecutionContext = execution.ExecutionContext;
const ExecutionResult = execution.ExecutionResult;
const OwnedGraphEntities = execution.OwnedGraphEntities;
const Value = value_types.Value;
const Env = value_types.Env;

pub const default_inline_rows: usize = 64;
pub const default_page_rows: usize = 128;

/// Number of nodes materialized+evaluated per per-graph SHARED read-lock hold
/// in `buildNextPage`'s WHERE/projection scan loop.
///
/// CHUNKING (where-scan-writer-progress): the materialize/evaluate loop runs
/// under the per-graph SHARED read lock (`graph_store.acquireGraphReadLock`,
/// taken HERE per batch — previously held by the transport handler across the
/// whole `buildNextPage`). A SPARSE non-indexed predicate (e.g. rank='species')
/// must materialize+evaluate MANY nodes before finding LIMIT matches, so an
/// unbroken SHARED hold spanned the whole O(scanned) scan. The periodic
/// checkpoint takes `mg.rwlock` EXCLUSIVE via the writer-PREFERRED
/// `lockUncancelable` (graph_storage_adapter.zig); once it is pending behind the
/// long SHARED hold, writer-preference parks every new SHARED acquirer behind
/// it — including the ingest apply's SHARED acquire — so ingest stalls to ~0
/// ops/s for the scan's duration. Acquiring + releasing the SHARED lock per
/// batch lets the pending EXCLUSIVE (and the writers parked behind it)
/// interleave (it waits at most one batch).
///
/// Correctness (same contract as the slot-collection chunking, commit
/// 1525e5e3): the `slot_ids` snapshot is IMMUTABLE and the `next_index` cursor
/// is MONOTONIC, so releasing + reacquiring between batches never re-collects or
/// duplicates. A node deleted across the gap simply fails `materializeNode` and
/// is skipped by the existing catch-continue (it would be skipped anyway). We
/// NEVER release mid-node: each node is fully materialized + evaluated + its row
/// built under one contiguous SHARED hold, so no torn read is exposed. LIMIT
/// early-termination is unchanged (the loop condition is unchanged). 512 bounds
/// the hold to a few hundred microseconds of page reads while amortising the
/// lock acquire/release across the batch.
const materialize_batch_nodes: usize = 512;

/// Test-observability counter: total nodes materialized by the streaming
/// path (lazy per-page `materializeNode`). Bounded scans materialize
/// O(result); count(label) materializes ZERO (served from the label index).
var g_nodes_materialized_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn resetNodesMaterializedTotal() void {
    g_nodes_materialized_total.store(0, .monotonic);
}

pub fn getNodesMaterializedTotal() u64 {
    return g_nodes_materialized_total.load(.monotonic);
}

/// FIX #1 (scan cancellation): absolute CLOCK_MONOTONIC now (ns), exposed so
/// transports without their own mono clock (e.g. the gRPC server) can anchor a
/// scan's `deadline_mono_ns`.
pub fn monoNanosNowForDeadline() u64 {
    return graph_store.monoNanosNowPub();
}

/// What the stream projects per matched node.
///   - .node     → a single bare-variable column (`RETURN n`)
///   - .projection→ one or more projected expressions (`RETURN n.a, n.b AS x`)
///   - .count     → a single aggregate row (`RETURN count(n)`), O(1) when
///                  unfiltered, O(scanned) when a predicate is present
const ProjectionMode = enum { node, projection, count };

pub const NodeScanStream = struct {
    allocator: std.mem.Allocator,
    /// Arena holding all stream-lifetime metadata that must outlive the
    /// request that produced it (the stream is stored on the session for
    /// subsequent PULL pages).  The cloned RETURN items, WHERE expression,
    /// parameter bindings, and the variable name all live here.
    arena: *std.heap.ArenaAllocator,
    graph_name: []const u8,
    /// The single output column name for the bare-node / count shapes; for
    /// projections the names come from `columns`.
    column_name: []const u8,
    /// Variable bound to the scanned node (e.g. "n").  Used to build the
    /// per-row evaluation environment so `eval.evalExpr` resolves `n` and
    /// `n.prop` exactly as the snapshot executor does.
    var_name: []const u8,
    slot_ids: []u64,
    next_index: usize = 0,
    /// Where `prepare` started the cursor: the OFFSET when there is no WHERE
    /// (slot collection is bounded by OFFSET+LIMIT, so the cursor skips the
    /// first OFFSET slots), else 0. `rewind` returns here (SONNY-1221).
    first_index: usize = 0,
    flags: [][]const u8,

    mode: ProjectionMode,
    /// Cloned RETURN items (projection mode only); evaluated per matched node
    /// with `eval.evalExpr` against the materialized node's environment.
    ret_items: []ast.ReturnItem = &.{},
    /// Pre-computed output column names (projection mode), identical to the
    /// snapshot executor's `generateUniqueColumnNames`.
    columns: [][]const u8 = &.{},
    /// Optional WHERE / FILTER predicate evaluated per matched node.  When
    /// present, non-matching nodes are skipped (LIMIT applies to matched rows).
    where_expr: ?ast.Expr = null,
    /// Cap on total MATCHED rows emitted across all pages. When a WHERE
    /// predicate is present, LIMIT applies to matched rows (not scanned
    /// slots), so the slot list is collected unbounded and this cap enforces
    /// LIMIT during paging. `maxInt` means no cap.
    row_limit: usize = std.math.maxInt(usize),
    rows_emitted: usize = 0,
    /// OFFSET over MATCHED rows (used only with a WHERE predicate; without a
    /// predicate, OFFSET is applied at the slot level via `next_index`).
    row_offset: usize = 0,
    rows_skipped: usize = 0,
    /// Cloned parameter bindings (stream-lifetime), used by predicate /
    /// projection evaluation for `$param` references.
    param_names: [][]const u8 = &.{},
    param_values: []Value = &.{},
    exec_context: ExecutionContext,

    /// GAP-0902 (selective scan): the exact set of node property keys the
    /// predicate + projection reference. When non-null, the per-node read
    /// materializes ONLY these keys (engine-direct per-key `getNodeProperty`,
    /// which uses a per-page directory-hash lookup — far cheaper than decoding +
    /// duping EVERY persisted property via `getAllNodeProperties`). null means
    /// "materialize the full node" — required when the bare node value escapes
    /// (`RETURN n`, or a projection that returns `n` itself), where downstream
    /// code may read any property. Owned on the stream arena.
    needed_keys: ?[][]const u8 = null,

    /// count mode: O(1) precomputed cardinality (unfiltered count).  When a
    /// predicate is present this is unused and the count is streamed.
    count_precomputed: ?usize = null,
    count_emitted: bool = false,

    // Scratch storage for the single-binding environment so makeEnv hands out
    // stable slices. Reset per call; the stream is single-threaded per page.
    env_names: [1][]const u8 = .{""},
    env_value: [1]Value = .{.{ .Null = {} }},

    /// FIX #1 (scan cancellation): optional pointer to a per-connection cancel
    /// flag, set by the transport layer when the driving client's stream /
    /// connection closes. The scan loop checks it at every batch boundary and
    /// short-circuits (releases the per-graph SHARED read lock, returns a FINAL
    /// page) so a scan whose client has gone away stops burning CPU + lock churn
    /// instead of running the whole O(N) scan to completion. `null` means "not
    /// bound to a stream" (standalone / legacy callers) and disables the check.
    cancel_token: ?*std.atomic.Value(bool) = null,

    /// FIX #1 (scan cancellation): optional absolute CLOCK_MONOTONIC deadline in
    /// ns. When non-zero and exceeded, the scan short-circuits at the next batch
    /// boundary exactly like a set `cancel_token`. `0` means "no deadline".
    deadline_mono_ns: u64 = 0,

    /// SONNY-1221: rows built BEFORE the schema frame (`prefetchSchemaSample`),
    /// so the frame can type each projection column from real values.
    /// `buildNextPage` serves them first, in order, before it scans on, so no
    /// row is dropped, repeated or reordered. null once all have been served.
    prefetched: ?Prefetched = null,
    /// SONNY-1221: set by `prefetchSchemaSample`. `buildSchema` asserts it for
    /// a projection, so a call site that skips the prefetch fails loudly in a
    /// safe build instead of silently typing every column NULL.
    prefetch_attempted: bool = false,

    const Prefetched = struct {
        result: ExecutionResult,
        /// Index of the first row not yet moved to a page.
        next: usize = 0,
        /// The allocator `result` was built with. It is also the one passed to
        /// `buildNextPage`, whose pages free the rows they are handed.
        allocator: std.mem.Allocator,
    };

    pub fn deinit(self: *NodeScanStream) void {
        self.dropPrefetched();
        self.allocator.free(self.slot_ids);
        for (self.flags) |flag| {
            self.allocator.free(flag);
        }
        self.allocator.free(self.flags);
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn hasRemaining(self: *const NodeScanStream) bool {
        if (self.mode == .count) return !self.count_emitted;
        return self.prefetched != null or self.scanRemaining();
    }

    /// True while the slot scan can still produce rows (cursor not exhausted,
    /// LIMIT not reached). Rows already prefetched are not counted here.
    fn scanRemaining(self: *const NodeScanStream) bool {
        return self.next_index < self.slot_ids.len and self.rows_emitted < self.row_limit;
    }

    /// FIX #1 (scan cancellation): true when the driving client's stream has
    /// closed (`cancel_token` set) OR the query deadline has passed. The scan
    /// loops consult this at batch boundaries and short-circuit when it returns
    /// true, releasing the per-graph SHARED read lock and ending the stream so a
    /// lingering scan stops consuming CPU + lock churn after its client is gone.
    pub fn isCanceled(self: *const NodeScanStream) bool {
        if (self.cancel_token) |tok| {
            if (tok.load(.acquire)) return true;
        }
        if (self.deadline_mono_ns != 0) {
            if (graph_store.monoNanosNowPub() >= self.deadline_mono_ns) return true;
        }
        return false;
    }

    // CANARY: REQ=REQ-SONNY-1221-FAST-PATH-SCHEMA; FEATURE="EngineDirectProjectionSchema"; ASPECT=SchemaFrameTyping; STATUS=TESTED; TEST=tests/test_sonny1221_fast_path_schema.zig; OWNER=engine; UPDATED=2026-09-24
    /// SONNY-1221: build, BEFORE the schema frame is sent, the rows the frame's
    /// projection column types are inferred from: the first
    /// `proto_util.column_type_sample_rows` rows of this stream's result, the
    /// executor path's sample. The rows stay on the stream and `buildNextPage`
    /// serves them first, so the scan does no extra work and the page
    /// boundaries a caller asks for are unchanged. `allocator` must be the one
    /// later passed to `buildNextPage` (the pages that serve these rows free
    /// them). Node and count columns have fixed types, so only a projection
    /// prefetches. Call once, before `buildSchema` and before any page.
    pub fn prefetchSchemaSample(self: *NodeScanStream, allocator: std.mem.Allocator) !void {
        self.prefetch_attempted = true;
        if (self.mode != .projection or self.prefetched != null) return;
        const page = try self.buildNextPage(allocator, proto_util.column_type_sample_rows);
        var result = page.result;
        if (result.rows.len == 0) {
            result.deinit(allocator);
            return;
        }
        self.prefetched = .{ .result = result, .allocator = allocator };
    }

    /// Restart from the first row: drop any prefetched rows and reset the scan
    /// cursor (to where `prepare` put it, which honours a no-WHERE OFFSET), the
    /// LIMIT/OFFSET counters and the count flag. Only for a stream that has not
    /// sent a single row yet (the QUIC inline path re-serves the whole result
    /// over PULL when its FIRST inline page fails to build).
    pub fn rewind(self: *NodeScanStream) void {
        self.dropPrefetched();
        self.next_index = self.first_index;
        self.rows_emitted = 0;
        self.rows_skipped = 0;
        self.count_emitted = false;
    }

    pub fn buildSchema(self: *const NodeScanStream, allocator: std.mem.Allocator) !schema.SchemaDefinition {
        switch (self.mode) {
            .node => {
                var cols = try std.ArrayList(schema.ColumnDefinition).initCapacity(allocator, 1);
                try cols.append(allocator, .{
                    .name = try allocator.dupe(u8, self.column_name),
                    .type = try allocator.dupe(u8, "NODE"),
                });
                return .{ .columns = cols };
            },
            .count => {
                var cols = try std.ArrayList(schema.ColumnDefinition).initCapacity(allocator, 1);
                try cols.append(allocator, .{
                    .name = try allocator.dupe(u8, self.column_name),
                    .type = try allocator.dupe(u8, "INTEGER"),
                });
                return .{ .columns = cols };
            },
            .projection => {
                // SONNY-1221: a projection's column types depend on its values.
                // Type them with the executor path's own inference
                // (`proto_util.buildSchemaDefinition`: the first non-null value
                // among the first `column_type_sample_rows` rows) over the rows
                // `prefetchSchemaSample` built -- exactly the rows this stream
                // serves first -- so both paths report the same type for the
                // same rows, and NULL only when every sampled value is null or
                // no row matched. This used to hard-code NULL for every column.
                // Without the prefetch there are no rows to type from, and
                // every column would silently come out NULL.
                std.debug.assert(self.prefetch_attempted);
                const sample: [][]Value = if (self.prefetched) |pre| pre.result.rows[pre.next..] else &.{};
                const view = ExecutionResult{
                    .columns = self.columns,
                    .rows = sample,
                    .flags = std.ArrayList([]const u8).empty,
                };
                return proto_util.buildSchemaDefinition(allocator, &view);
            },
        }
    }

    pub const Page = struct {
        result: ExecutionResult,
        final: bool,
    };

    pub fn buildNextPage(self: *NodeScanStream, allocator: std.mem.Allocator, page_size: usize) !Page {
        if (self.mode == .count) return self.buildCountPage(allocator);

        const page_len = if (page_size == 0) default_page_rows else page_size;
        if (self.prefetched == null and !self.scanRemaining()) {
            return .{
                .result = try self.emptyResult(allocator),
                .final = true,
            };
        }

        var rows = try std.ArrayList([]Value).initCapacity(allocator, @min(page_len, 256));
        errdefer {
            for (rows.items) |row| {
                for (row) |val| property_value_codec.freeValue(allocator, val);
                allocator.free(row);
            }
            rows.deinit(allocator);
        }

        var owned_entities = try OwnedGraphEntities.init(allocator);
        // CANARY: REQ=REQ-SONNY-2463-BARE-NODE-LEAK; FEATURE="EngineDirectNodeOwnership"; ASPECT=PageFreesReturnedNode; STATUS=TESTED; TEST=tests/test_sonny2463_bare_node_leak.zig; OWNER=engine; UPDATED=2026-09-25
        // SONNY-2463: a node this page returns owns its whole interior (see
        // "Node ownership" at `destroyNode`), so page teardown frees all of it.
        owned_entities.destroy_node = destroyNode;
        errdefer owned_entities.deinit();

        // SONNY-1221: rows built for the schema frame are served first. When
        // they fill the page, or nothing is left to scan, no scan runs.
        try self.takePrefetched(allocator, &rows, owned_entities, page_len);
        if (rows.items.len >= page_len or !self.scanRemaining()) {
            const result = try self.finishResult(allocator, rows, owned_entities);
            return .{
                .result = result,
                .final = self.prefetched == null and !self.scanRemaining(),
            };
        }

        // Materialization reads node pages, so it runs under the per-graph
        // SHARED read lock — but CHUNKED: acquire + release per
        // `materialize_batch_nodes` slots so a writer-preferred EXCLUSIVE
        // checkpoint (and the ingest writers parked behind it) can interleave
        // between batches instead of starving for the whole O(scanned) scan.
        // See `materialize_batch_nodes` for the correctness contract. The lock
        // is the streaming counterpart of the per-shard SHARED hold the
        // slot-collection scan already chunks; the transport handlers no longer
        // wrap `buildNextPage` in an outer read lock.
        var lock = graph_store.acquireGraphReadLockTagged(self.graph_name, .misc);
        var lock_held = true;
        errdefer if (lock_held) graph_store.releaseGraphLock(lock);
        var batch_count: usize = 0;
        // SONNY-2656: each node's WHERE runs on this arena, reset after it.
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();

        // Fill the page up to `page_len` MATCHED rows. With a predicate this
        // may scan more slots than rows produced (O(scanned)); LIMIT still
        // bounds the matched rows via `slot_ids` when no predicate is present,
        // and via early-termination here when a predicate is.
        // FIX #1: a client that has already gone away before the first batch —
        // short-circuit before touching any node.
        if (self.isCanceled()) {
            graph_store.releaseGraphLock(lock);
            lock_held = false;
            return self.cancelledPage(allocator, rows, owned_entities);
        }
        while (rows.items.len < page_len and self.next_index < self.slot_ids.len and self.rows_emitted < self.row_limit) {
            // Batch boundary: drop and reacquire the SHARED lock so a pending
            // EXCLUSIVE apply/checkpoint interleaves. Done BETWEEN nodes (never
            // mid-node), so a node is always fully read under one contiguous
            // hold — no torn read. The immutable slot_ids snapshot + monotonic
            // cursor make the release/reacquire gap safe (no re-collect, no
            // duplicate; a node deleted in the gap fails materializeNode below).
            if (batch_count == materialize_batch_nodes) {
                graph_store.releaseGraphLock(lock);
                // FIX #1 (scan cancellation): the batch boundary is the natural
                // cancellation point — the lock is already dropped and the
                // cursor is at a node boundary. If the client's stream has
                // closed (or the deadline passed), STOP here instead of
                // reacquiring and scanning the rest of the O(N) slot list. We
                // return whatever rows we already built with final=true so the
                // handler tears the stream down; the client is gone, so a short
                // page is harmless and a lingering scan is avoided.
                if (self.isCanceled()) {
                    lock_held = false;
                    return self.cancelledPage(allocator, rows, owned_entities);
                }
                lock = graph_store.acquireGraphReadLockTagged(self.graph_name, .misc);
                batch_count = 0;
            }
            batch_count += 1;

            const slot_id = self.slot_ids[self.next_index];
            self.next_index += 1;

            // Skip nodes that vanished due to concurrent modification (e.g.
            // active ingest adding/removing nodes). This avoids failing the
            // entire page when a single slot becomes stale. GAP-0902: when the
            // query references only specific keys (no bare-node escape), read
            // ONLY those keys (cheap per-key directory lookup) instead of
            // decoding+duping every persisted property.
            const node = if (self.needed_keys) |keys|
                materializeNodeProjected(allocator, self.graph_name, slot_id, keys) catch |err| {
                    if (eval.isResourceLimitError(err)) return err; // SONNY-3349
                    continue;
                }
            else
                materializeNode(allocator, self.graph_name, slot_id) catch |err| {
                    if (eval.isResourceLimitError(err)) return err; // SONNY-3349
                    continue;
                };
            var node_tracked = false;
            errdefer if (!node_tracked) destroyNode(allocator, node);

            if (self.where_expr) |where_expr| {
                const passes = try self.evalPredicate(&scratch, allocator, where_expr, node);
                if (!passes) {
                    destroyNode(allocator, node);
                    continue;
                }
                // OFFSET over matched rows (predicate path only).
                if (self.rows_skipped < self.row_offset) {
                    self.rows_skipped += 1;
                    destroyNode(allocator, node);
                    continue;
                }
            }

            const row = try self.buildRow(allocator, node, owned_entities, &node_tracked);
            try rows.append(allocator, row);
            self.rows_emitted += 1;
        }
        graph_store.releaseGraphLock(lock);
        lock_held = false;

        const result = try self.finishResult(allocator, rows, owned_entities);
        return .{
            .result = result,
            .final = self.next_index >= self.slot_ids.len or self.rows_emitted >= self.row_limit,
        };
    }

    fn buildRow(
        self: *NodeScanStream,
        allocator: std.mem.Allocator,
        node: *graph_store.Node,
        owned_entities: *OwnedGraphEntities,
        node_tracked: *bool,
    ) ![]Value {
        switch (self.mode) {
            .node => {
                try owned_entities.trackNode(node);
                node_tracked.* = true;
                const row = try allocator.alloc(Value, 1);
                row[0] = .{ .Node = node };
                return row;
            },
            .projection => {
                const env = self.makeEnv(allocator, node);
                const row = try allocator.alloc(Value, self.ret_items.len);
                // Track how many entries are initialized so a mid-loop error
                // only frees real values (never uninitialized slots). The node
                // is still owned by the caller's `node_tracked` errdefer on the
                // error path, so we don't free it here.
                var produced: usize = 0;
                errdefer {
                    for (row[0..produced]) |val| property_value_codec.freeValue(allocator, val);
                    allocator.free(row);
                }
                var produced_node_value = false;
                for (self.ret_items, 0..) |item, i| {
                    // SONNY-6449: nothing lent from the scratch arena, so a
                    // cell is either the node's (copied below) or
                    // `allocator`'s, which the result frees.
                    const value = try eval.evalExprNothingLent(allocator, item.expr, env);
                    // SONNY-2472 / SONNY-2464: the cell never shares memory
                    // with the node (see "Node ownership" at `destroyNode`).
                    // It is set before `produced` counts it, so the errdefer
                    // frees only cells that own what they hold.
                    row[i] = try detachFromNode(allocator, node, value);
                    produced = i + 1;
                    if (row[i] == .Node) produced_node_value = true;
                }
                // If any projected column is the bare node itself, the node
                // must be kept alive for the lifetime of the page; track it.
                if (produced_node_value) {
                    try owned_entities.trackNode(node);
                    node_tracked.* = true;
                } else {
                    // No reference to the node escapes the row, and no cell
                    // points into it: free all of it now.
                    destroyNode(allocator, node);
                    node_tracked.* = true;
                }
                return row;
            },
            .count => unreachable,
        }
    }

    fn finishResult(
        self: *NodeScanStream,
        allocator: std.mem.Allocator,
        rows: std.ArrayList([]Value),
        owned_entities: *OwnedGraphEntities,
    ) !ExecutionResult {
        var rows_mut = rows;
        const columns = try self.buildColumns(allocator);
        const owned = owned_entities.nodes.items.len > 0 or owned_entities.edges.items.len > 0;
        const result = ExecutionResult{
            .columns = columns,
            .rows = try rows_mut.toOwnedSlice(allocator),
            .flags = std.ArrayList([]const u8).empty,
            // A projection cell owns what it holds: `detachFromNode` copies
            // any string that still points into its node, so freeing every
            // cell here never frees node memory (SONNY-2472, SONNY-2464).
            // freeValue is a no-op for .Node, which is owned by
            // owned_graph_entities, so a mixed row is freed once too.
            .owns_value_memory = self.mode == .projection,
            // SONNY-2656: every other cell is a fresh clone of the kind it
            // projects (Text, Json, Bytea, ...), so free every kind.
            .free_value = property_value_codec.freeValue,
            .owned_graph_entities = if (owned) owned_entities else null,
        };
        if (!owned) owned_entities.deinit();
        return result;
    }

    /// SONNY-1221: move prefetched rows, in order, onto `rows` until it holds
    /// `page_len`. A row that projects the bare node carries that node, and the
    /// node moves with the row to `owned_entities`, so the serving page keeps it
    /// alive exactly as it would a node it had materialized itself. Space is
    /// reserved before anything moves, so an allocation failure leaves every
    /// row and node owned by exactly one side.
    fn takePrefetched(
        self: *NodeScanStream,
        allocator: std.mem.Allocator,
        rows: *std.ArrayList([]Value),
        owned_entities: *OwnedGraphEntities,
        page_len: usize,
    ) !void {
        const pre = if (self.prefetched) |*p| p else return;
        while (rows.items.len < page_len and pre.next < pre.result.rows.len) {
            const row = pre.result.rows[pre.next];
            try rows.ensureUnusedCapacity(allocator, 1);
            // Only rows that projected a bare node carry one to move.
            if (pre.result.owned_graph_entities != null) {
                try owned_entities.nodes.ensureUnusedCapacity(owned_entities.allocator, row.len);
            }
            rows.appendAssumeCapacity(row);
            // Leave an empty slice behind: the prefetched result's deinit then
            // frees only the rows it still owns (freeing a zero-length slice is
            // a no-op).
            pre.result.rows[pre.next] = row[0..0];
            pre.next += 1;
            if (pre.result.owned_graph_entities) |from| {
                for (row) |val| {
                    if (val != .Node) continue;
                    for (from.nodes.items, 0..) |node, idx| {
                        if (node != val.Node) continue;
                        owned_entities.nodes.appendAssumeCapacity(from.nodes.swapRemove(idx));
                        break;
                    }
                }
            }
        }
        if (pre.next == pre.result.rows.len) self.dropPrefetched();
    }

    /// Free whatever the prefetched rows still own.
    fn dropPrefetched(self: *NodeScanStream) void {
        if (self.prefetched) |*pre| {
            pre.result.deinit(pre.allocator);
            self.prefetched = null;
        }
    }

    fn emptyResult(self: *NodeScanStream, allocator: std.mem.Allocator) !ExecutionResult {
        const columns = try self.buildColumns(allocator);
        return .{
            .columns = columns,
            .rows = try allocator.alloc([]Value, 0),
            .flags = std.ArrayList([]const u8).empty,
            .owns_value_memory = self.mode == .projection,
            .free_value = property_value_codec.freeValue,
        };
    }

    /// FIX #1 (scan cancellation): build a FINAL page from whatever rows were
    /// collected before cancellation, and advance the cursor to the end so
    /// `hasRemaining()` is false (any further PULL gets a clean empty final
    /// page). The caller MUST have already released the per-graph SHARED read
    /// lock. The client's stream has closed (or the deadline passed), so a
    /// short/partial page is harmless — what matters is that we STOP scanning.
    fn cancelledPage(
        self: *NodeScanStream,
        allocator: std.mem.Allocator,
        rows: std.ArrayList([]Value),
        owned_entities: *OwnedGraphEntities,
    ) !Page {
        self.next_index = self.slot_ids.len;
        self.rows_emitted = self.row_limit;
        const result = try self.finishResult(allocator, rows, owned_entities);
        return .{ .result = result, .final = true };
    }

    fn buildColumns(self: *NodeScanStream, allocator: std.mem.Allocator) ![][]const u8 {
        switch (self.mode) {
            .node, .count => {
                var columns = try allocator.alloc([]const u8, 1);
                errdefer allocator.free(columns);
                columns[0] = try allocator.dupe(u8, self.column_name);
                return columns;
            },
            .projection => {
                var columns = try allocator.alloc([]const u8, self.columns.len);
                errdefer {
                    for (columns, 0..) |c, i| {
                        if (i < self.columns.len) allocator.free(c);
                    }
                    allocator.free(columns);
                }
                for (self.columns, 0..) |name, i| {
                    columns[i] = try allocator.dupe(u8, name);
                }
                return columns;
            },
        }
    }

    fn buildCountPage(self: *NodeScanStream, allocator: std.mem.Allocator) !Page {
        if (self.count_emitted) {
            var columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, self.column_name);
            return .{
                .result = .{
                    .columns = columns,
                    .rows = try allocator.alloc([]Value, 0),
                    .flags = std.ArrayList([]const u8).empty,
                },
                .final = true,
            };
        }

        const n: usize = if (self.count_precomputed) |c| c else blk: {
            // Filtered count, no O(1) precompute available.
            if (self.where_expr) |where_expr| {
                // A WHERE predicate is present: stream the matching slots,
                // materialize each node, evaluate the predicate, and tally
                // matches. O(scanned), no clone. (Inline `{prop: val}` filters,
                // if any, were already applied during slot collection.)
                //
                // Same CHUNKING as the row/projection scan: materialization runs
                // under the per-graph SHARED read lock, acquired + released per
                // `materialize_batch_nodes` slots so a writer-preferred EXCLUSIVE
                // checkpoint/apply interleaves instead of starving for the whole
                // O(scanned) tally. Released between nodes only (no torn read);
                // the immutable slot_ids snapshot makes the gap safe.
                var matched: usize = 0;
                var lock = graph_store.acquireGraphReadLockTagged(self.graph_name, .misc);
                var count_lock_held = true;
                errdefer if (count_lock_held) graph_store.releaseGraphLock(lock);
                var batch_count: usize = 0;
                // SONNY-2656: each node's WHERE runs on this arena, reset
                // after it.
                var scratch = std.heap.ArenaAllocator.init(allocator);
                defer scratch.deinit();
                for (self.slot_ids) |slot_id| {
                    if (batch_count == materialize_batch_nodes) {
                        graph_store.releaseGraphLock(lock);
                        // FIX #1 (scan cancellation): same batch-boundary bail as
                        // buildNextPage. If the client's stream has closed (or
                        // the deadline passed), STOP tallying and return the
                        // partial count — the client is gone, so completeness is
                        // moot; what matters is not lingering on the O(N) tally.
                        if (self.isCanceled()) {
                            count_lock_held = false;
                            break;
                        }
                        lock = graph_store.acquireGraphReadLockTagged(self.graph_name, .misc);
                        batch_count = 0;
                    }
                    batch_count += 1;
                    // GAP-0902: a filtered count needs ONLY the predicate's keys
                    // (no projection, no node escape), so read just those keys.
                    const node = if (self.needed_keys) |keys|
                        materializeNodeProjected(allocator, self.graph_name, slot_id, keys) catch |err| {
                            if (eval.isResourceLimitError(err)) return err; // SONNY-3349
                            continue;
                        }
                    else
                        materializeNode(allocator, self.graph_name, slot_id) catch |err| {
                            if (eval.isResourceLimitError(err)) return err; // SONNY-3349
                            continue;
                        };
                    defer destroyNode(allocator, node);
                    if (try self.evalPredicate(&scratch, allocator, where_expr, node)) matched += 1;
                }
                // Released already if we bailed at a batch boundary on cancel.
                if (count_lock_held) graph_store.releaseGraphLock(lock);
                break :blk matched;
            }
            // No WHERE predicate but no O(1) precompute either → inline
            // `{prop: val}`-filtered count. Every collected slot already passed
            // the inline-property filter in `collectMatchingSlotIds`, so the
            // tally is exactly the number of matching slots. O(matched), no
            // per-node materialization, no clone.
            break :blk self.slot_ids.len;
        };

        self.count_emitted = true;

        var columns = try allocator.alloc([]const u8, 1);
        errdefer allocator.free(columns);
        columns[0] = try allocator.dupe(u8, self.column_name);

        var row = try allocator.alloc(Value, 1);
        errdefer allocator.free(row);
        row[0] = Value{ .Int = @intCast(n) };

        var rows = try allocator.alloc([]Value, 1);
        rows[0] = row;

        return .{
            .result = .{
                .columns = columns,
                .rows = rows,
                .flags = std.ArrayList([]const u8).empty,
            },
            .final = true,
        };
    }

    fn makeEnv(self: *NodeScanStream, allocator: std.mem.Allocator, node: *graph_store.Node) Env {
        return Env{
            .names = self.env_names[0..1],
            .values = blk: {
                self.env_value[0] = .{ .Node = node };
                break :blk self.env_value[0..1];
            },
            .param_names = self.param_names,
            .param_values = self.param_values,
            .allocator = allocator,
            .exec_context = @ptrCast(@constCast(&self.exec_context)),
        };
    }

    /// Whether `node` passes `where_expr`. The evaluation runs on `scratch`
    /// (see `predicateAllocator`), which is reset before this returns. An
    /// evaluation error is a miss, as it always was, except a limit
    /// (SONNY-3251, round 15: 54001, 53200, 57014), which fails the read:
    /// this stream is served outside the statement chokepoint that fails a
    /// statement on a limit it swallowed.
    fn evalPredicate(self: *NodeScanStream, scratch: *std.heap.ArenaAllocator, allocator: std.mem.Allocator, where_expr: ast.Expr, node: *graph_store.Node) !bool {
        defer _ = scratch.reset(.retain_capacity);
        const eval_allocator = predicateAllocator(scratch, allocator);
        const env = self.makeEnv(eval_allocator, node);
        const where_result = eval.evalExpr(eval_allocator, where_expr, env) catch |err| {
            if (eval.isResourceLimitError(err)) return err;
            return false;
        };
        return predicateHolds(where_result);
    }
};

// Node ownership on the engine-direct scan (SONNY-2472, SONNY-2464,
// SONNY-2463).
//
// Every node this file materializes (`materializeNode`,
// `materializeNodeProjected`) owns ALL of its memory, on the allocator it was
// built with: the struct, the label slice and each label, the graph name, every
// property key and value, and the property map's entry slice. Two rules make
// every one of those allocations, and every row cell, freed exactly once:
//
//   1. A row never shares memory with a node. `.Member` evaluation hands a cell
//      the node's own string, not a copy; `detachFromNode` replaces such a cell
//      with a copy before the row keeps it. So a cell owns exactly what it
//      holds, and the page frees it (`owns_value_memory`), however many cells
//      read the same property (SONNY-2472). Every other value a cell can hold
//      is a fresh clone, of any extended kind, so the page frees cells with
//      `property_value_codec.freeValue`, which frees every kind (SONNY-2656).
//   2. A node has exactly one owner, which frees all of it once with
//      `destroyNode`. That is the code that materialized it, straight after
//      use, whenever no row returns the node itself: a WHERE miss, an OFFSET
//      skip, a filtered count's tally, `slotMatchesPredicate`'s check, and a
//      projection row that only reads properties. So a value is freed whether
//      or not a row read it (SONNY-2464). A node that a row returns (`RETURN
//      n`, or a bare `n` column) belongs to the page's `OwnedGraphEntities`
//      instead, which `buildNextPage` creates with `destroy_node =
//      destroyNode`, so page teardown frees it in full, after the rows that
//      point at it (SONNY-2463). A prefetched row's node moves with its row
//      from one such tracker to another, and is never in two.
//
// No arena is involved, so nothing is released in bulk and no cell can be left
// pointing at memory released under it.

// CANARY: REQ=REQ-SONNY-2472-DUPLICATE-PROJECTION; FEATURE="EngineDirectProjectionOwnership"; ASPECT=CellOwnsItsString; STATUS=TESTED; TEST=tests/test_sonny2472_duplicate_projection.zig; OWNER=engine; UPDATED=2026-09-25
/// Rule 1 of "Node ownership": `value`, made independent of `node`. A string
/// that points into one of the node's string values is replaced by a copy.
/// Only a `.Str` can point into the node: every other value `.Member` or
/// `.PropertyAccess` yields is a fresh allocation (a `.PropertyAccess` string,
/// a projected list or extended value, a decrypted field) or holds no memory
/// (a scalar, or `.Node`, which is the node itself and belongs to its owner).
/// If the copy cannot be made, `value` still belongs to the node, so the caller
/// has nothing of its own to free.
fn detachFromNode(allocator: std.mem.Allocator, node: *const graph_store.Node, value: Value) !Value {
    const s = switch (value) {
        .Str => |s| s,
        else => return value,
    };
    // An empty slice owns no memory, so freeing it is a no-op either way.
    if (s.len == 0 or !nodeHoldsBytes(node, s)) return value;
    return .{ .Str = try allocator.dupe(u8, s) };
}

/// True when `bytes` starts inside one of `node`'s string property values.
fn nodeHoldsBytes(node: *const graph_store.Node, bytes: []const u8) bool {
    const at = @intFromPtr(bytes.ptr);
    var props = node.properties.iterator();
    while (props.next()) |entry| {
        const owned = switch (entry.value_ptr.*) {
            .String => |owned| owned,
            else => continue,
        };
        const start = @intFromPtr(owned.ptr);
        if (at >= start and at < start + owned.len) return true;
    }
    return false;
}

// CANARY: REQ=REQ-SONNY-2464-STRING-VALUE-LEAKS; FEATURE="EngineDirectNodeOwnership"; ASPECT=DeepNodeDestroy; STATUS=TESTED; TEST=tests/test_sonny2464_string_value_leaks.zig; OWNER=engine; UPDATED=2026-09-25
/// Rule 2 of "Node ownership": free everything `node` owns, then the node.
/// Safe whatever the rows hold, because no row cell points into a node (rule
/// 1). Frees exactly what `materializeNode` / `materializeNodeProjected`
/// allocate; `graph_store.freeNodeValue` would also free `tenant_id`, which
/// these nodes leave at its static default.
fn destroyNode(allocator: std.mem.Allocator, node: *graph_store.Node) void {
    var props = node.properties.iterator();
    while (props.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        property_value_codec.freePropertyValue(allocator, entry.value_ptr.*);
    }
    node.properties.deinit();
    allocator.free(node.graph_name);
    for (node.labels) |label| allocator.free(label);
    allocator.free(node.labels);
    allocator.destroy(node);
}

const Eligibility = struct {
    pattern: ast.NodePattern,
    column_name: []const u8,
    mode: ProjectionMode,
};

// CANARY: REQ=REQ-SONNY-1218-INMEM-SCAN; FEATURE="EngineDirectNodeScanDecline"; ASPECT=AdapterGuard; STATUS=TESTED; TEST=tests/test_sonny1218_in_memory_node_scan.zig; OWNER=engine; UPDATED=2026-09-13
/// SONNY-1218 (GEO-UP-006): the single "can this stream serve a scan at all?"
/// guard, shared by `prepare` (every projection mode) and `isEligible`.
///
/// This whole path is ENGINE-DIRECT: every row it can ever produce comes from
/// the persisted storage adapter (`collectMatchingSlotIds` →
/// `getNodesByLabelCapped` / `scanAllNodes`, then the lazy per-page
/// `materializeNode`). It never consults the in-memory `GraphStore`. On an
/// IN-MEMORY deployment — `geode serve` without `--data-dir`, so
/// `global_adapter` is null (see the comment at graph_store.zig:1788) — the
/// adapter has nothing to read, and `collectMatchingSlotIds` returns an empty
/// slot slice.
///
/// The bug this closes: `prepare` used to accept that empty slot slice for the
/// `.node` / `.projection` modes (and for a FILTERED `.count`, which skips the
/// unfiltered precompute's `else return null`) and render it as a SUCCESSFUL
/// (`status_class 00000`) ZERO-row response — a silent wrong answer, because
/// the correct rows were sitting in the in-memory store the executor reads.
/// "Cannot serve" must mean DECLINE, never "the answer is no rows".
///
/// `isEligible` consults the same guard so the transports' snapshot-clone-SKIP
/// decision (`quic_connection_handler.readServedEngineDirect`,
/// `grpc_server.readServedEngineDirect`) can never claim a shape this stream
/// will then refuse — if the two disagreed, the executor fallback would run
/// without the snapshot it needs and the bug would simply move.
///
/// Mirrors the guards `planned_read_runtime.executeIfSupported` and both
/// transports' `readWillStreamEngineSide` already apply. Reads one global
/// pointer: no I/O, no locks, safe to call before acquiring anything.
fn adapterCanServeEngineDirect() bool {
    return graph_store.getGlobalAdapter() != null;
}

// CANARY: REQ=REQ-SONNY-1229-ENGINE-DIRECT-TENANCY; FEATURE="EngineDirectTenantScope"; ASPECT=TenantGuard; STATUS=TESTED; TEST=tests/test_sonny1229_strict_tenancy_read.zig; OWNER=security; UPDATED=2026-09-13
/// SONNY-1229 (GEO-UP-002) — P0 cross-tenant READ leak. Fail-closed tenant
/// gate for the engine-direct scan, shared by `prepare` and `isEligible`.
///
/// This path has NO tenant logic of its own: `collectMatchingSlotIds` walks the
/// storage adapter's label posting / slot range and `materializeNode` reads the
/// slot's properties — neither consults `node.tenant_id`, neither calls
/// `match_operations.passesTenantFilterSlice`, and neither knows about the
/// GAP-0846 tenant HIERARCHY (`canAccessTenantSafe`, ancestor-or-self). It
/// therefore cannot enforce exact-match isolation OR hierarchy access, and the
/// transports gated it only on `rls_active` — so a session bound to a concrete
/// tenant was served EVERY tenant's rows for `MATCH (n:L) RETURN n.p`,
/// `RETURN n` and `count(n)`, and a session bound to an UNREGISTERED tenant read
/// everything (verified end-to-end against 0.8.15 by the Go driver lane).
///
/// The decision is derived from `tenancy.resolveTenantFilter` — the SAME shared
/// resolution `crud_operations.tenantFilterFromContext`,
/// `match_operations.getSessionTenantFilter` and
/// `planned_read_runtime.buildPlanIfSupported` use — so this gate can never
/// drift from what the executor would enforce:
///
///   * CONCRETE scope (a real tenant id) -> DECLINE. The executor applies the
///     hierarchy-aware `passesTenantFilter` at every read site.
///   * strict tenancy ON, no concrete scope -> `error.TenantScopeRequired`, so
///     DECLINE; the executor re-resolves and surfaces GQLSTATE 42501 on the
///     normal wire-error path. Serving here would answer a request the engine
///     is contractually required to REFUSE.
///   * no scope, strict OFF (the single-tenant deployment this fast path
///     exists for) -> the filter is `null` = all-tenants, which is exactly what
///     this path already does. ALLOW, zero behaviour change.
///
/// Declining, rather than filtering in-path, is deliberate for this P0:
/// correctness first. Applying the filter here would mean reading each slot's
/// tenant tag engine-direct AND reproducing `hierarchyForFilter` +
/// `canAccessTenantSafe` in a second place — a second copy of an isolation
/// control is exactly how this class of defect recurs. See the SONNY-1229
/// report for the performance consequence (tenant-scoped reads pay the executor
/// path until a per-slot tenant filter is added here).
///
/// Pure: one atomic load + (at most) one string compare. No I/O, no locks, safe
/// to call before acquiring anything.
pub fn tenantScopePermitsEngineDirect(session_tenant_id: ?[]const u8) bool {
    const resolved = tenancy.resolveTenantFilter(session_tenant_id) catch return false;
    return resolved == null;
}

/// The single "can this stream serve a scan for THIS session at all?" predicate.
/// `prepare` and `isEligible` both route through it so the transports'
/// snapshot-clone-skip / will-stream decisions can never claim a shape
/// `prepare` will refuse.
fn canServeEngineDirect(session_tenant_id: ?[]const u8) bool {
    return adapterCanServeEngineDirect() and tenantScopePermitsEngineDirect(session_tenant_id);
}

// CANARY: REQ=REQ-PERF-UNORDERED-STREAM-001; FEATURE="UnorderedNodeScanStreaming"; ASPECT=TransportFastPath; STATUS=IMPL; OWNER=engine; UPDATED=2026-06-19
pub fn prepare(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    param_names: []const []const u8,
    param_values: []const Value,
    flags: []const []const u8,
) !?NodeScanStream {
    // SONNY-1218: no persisted adapter ⇒ this path can produce NOTHING.
    // SONNY-1229: a concrete tenant scope (or effective strict tenancy) ⇒ this
    // path cannot enforce tenant isolation, so it must not answer at all.
    // Decline for EVERY mode (.node / .projection / .count) so the query falls
    // through to the executor, which reads the in-memory store and applies the
    // hierarchy-aware tenant filter — both answers are correct there.
    if (!canServeEngineDirect(context.tenant_id)) return null;

    const eligibility = eligibleQuery(q) orelse return null;
    const variable_name = eligibility.pattern.name orelse return null;

    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const graph_name = try aa.dupe(u8, resolveGraphName(context));
    // REQ-GQL-028 fail-closed: this engine-direct path skips the executor's
    // statement gate, so refuse a quarantined graph here (no hydration: the
    // stream reads the engine, not the resident indexes).
    if (graph_store.quarantineErrorForGraph(allocator, graph_name)) |err| return err;
    const var_name = try aa.dupe(u8, variable_name);

    // Clone parameter bindings into the stream arena so PULL pages can
    // re-evaluate predicates/projections after the request scope ends.
    var owned_param_names = try aa.alloc([]const u8, param_names.len);
    for (param_names, 0..) |name, i| owned_param_names[i] = try aa.dupe(u8, name);
    var owned_param_values = try aa.alloc(Value, param_values.len);
    for (param_values, 0..) |val, i| owned_param_values[i] = try cloneValue(aa, val);

    // Clone the WHERE / FILTER predicate (eligible subset only) into the
    // arena. An un-cloneable shape means we cannot stream correctly: bail to
    // the snapshot path (return null) rather than risk wrong results.
    var where_expr: ?ast.Expr = null;
    if (q.where_clause orelse q.filter_clause) |w| {
        where_expr = cloneExpr(aa, w) catch return null;
    }

    // count mode: O(1) cardinality when TRULY unfiltered.
    //
    // The O(1) count is correct ONLY when there is no per-node filter of any
    // kind. A WHERE/FILTER predicate is one filter; inline `{prop: val}`
    // patterns on the matched node are ANOTHER. `eligibleQuery` accepts
    // inline-prop count (it is streamable), but those props must be applied
    // per node — an O(1) count here would count EVERY node of the label and
    // silently ignore the `{prop: val}` filter (over-count). So gate the O(1)
    // precompute on having NO inline props as well; inline-prop counts fall
    // through to the streamed slot-tally path below.
    //
    // SOURCE (2026-07-05 live regression at 14.27M): the single-label count
    // MUST read the AUTHORITATIVE in-memory maintained refcount
    // (`GraphStore.countNodesByLabel`, tenantless arm = `countGraphLabel`,
    // guarded by the `ensureGraphHydrated` chokepoint) — NEVER
    // `adapter.countNodesByLabel`, which sums the storage ENGINE's per-shard
    // `label_index`. That engine index is a DEFERRED derived structure
    // (graph-storage Phase A): empty/partial after a catalog-mediated reopen
    // until an accessor materializes it, never filled by the in-memory
    // streaming hydration, and it retains deleted slots (over-count). Live
    // capture: this precompute returned 0 for a graph whose in-memory
    // refcount held 14,270,791 — after the query had already blocked on the
    // hydration latch. Tenant scope: this engine-direct path has never
    // applied a tenant filter (the adapter count had no tenant parameter),
    // so `tenant = null` preserves the path's semantics exactly; tenant- and
    // RLS-scoped counts are handled by the in-memory fast paths / legacy
    // executor before the handler falls through to this stream.
    // Regression: tests/test_startup_lazy_hydrate.zig "engine-direct
    // single-label count serves the in-memory refcount".
    const has_inline_props = eligibility.pattern.props != null;
    var count_precomputed: ?usize = null;
    if (eligibility.mode == .count and where_expr == null and !has_inline_props) {
        if (graph_store.getGlobalAdapter()) |adapter| {
            if (eligibility.pattern.labels.len == 1) {
                count_precomputed = graph_store.getGlobalStore(allocator).countNodesByLabel(graph_name, eligibility.pattern.labels[0], null);
            } else if (eligibility.pattern.labels.len == 0) {
                // Unlabeled count: scan the engine node store (no clone). The
                // node store is a PRIMARY structure — complete irrespective of
                // the deferred derived-index state — so it is safe to source.
                const entries = adapter.scanAllNodes(graph_name, aa) catch return null;
                count_precomputed = entries.len;
            }
            // labels.len > 1: NO precompute — a multi-label conjunction must
            // fall through to the slot-tally path, whose per-slot
            // `nodeMatchesPattern` verifies the FULL label set. (The previous
            // `scanAllNodes` arm counted EVERY node in the graph for
            // multi-label patterns — silent over-count.)
        } else {
            // SONNY-1218: now redundant — prepare's shared
            // `adapterCanServeEngineDirect` guard declined before we got here.
            // Kept as a local invariant so this arm can never render a null
            // adapter as a count of 0.
            return null;
        }
    }

    // GAP-ENT-0055: O(1) FILTERED count for `MATCH (n:L) WHERE n.<indexed> =
    // '<ascii>' RETURN count(n)`. The exact node-property index posting LENGTH
    // for (label, key, value) IS the answer, so serve it O(1) instead of
    // collecting + materializing + re-evaluating every matching slot in
    // `buildCountPage` (O(matching): 88 s at 7 M for `source='col'`). Gated on a
    // SINGLE seekable equality, one label, no inline props, no FILTER clause —
    // any other shape falls through to the streaming tally (still correct).
    // Tenant/RLS-scoped counts never reach this engine-direct stream (handled by
    // the in-memory fast paths / legacy executor upstream), so — like the
    // unfiltered precompute above — the posting length (all-tenant) is exact here.
    if (count_precomputed == null and eligibility.mode == .count and
        !has_inline_props and eligibility.pattern.labels.len == 1 and
        q.filter_clause == null)
    {
        if (q.where_clause) |wc| {
            if (seekableEqCountWhere(wc, var_name)) |seek| {
                if (graph_store.getGlobalAdapter()) |adapter| {
                    if (adapter.countCandidateNodesByLabelAndProperty(
                        graph_name,
                        eligibility.pattern.labels[0],
                        seek.key,
                        graph_store.PropertyValue{ .String = seek.value },
                    )) |posting_len| {
                        count_precomputed = posting_len;
                    } else |_| {}
                }
            }
        }
    }

    // Clone RETURN items (projection mode) into the arena.
    var ret_items: []ast.ReturnItem = &.{};
    var columns: [][]const u8 = &.{};
    if (eligibility.mode == .projection) {
        ret_items = cloneReturnItems(aa, q.ret.items) catch return null;
        columns = try result_utils.generateUniqueColumnNames(aa, ret_items);
    }

    // For count mode we never page node slots; for node/projection we collect
    // matching slot ids. When NO WHERE predicate is present, slot-level
    // matches equal row-level matches (inline `{prop:val}` filters are applied
    // during slot collection), so LIMIT/OFFSET are applied at the slot level
    // for early termination. When a WHERE predicate IS present, it is evaluated
    // per node during paging, so LIMIT/OFFSET must apply to MATCHED rows: the
    // slot list is collected unbounded and the row_limit/row_offset enforce the
    // window over matched rows.
    const offset = resolveWindowValue(q.offset, q.offset_param, param_names, param_values) orelse 0;
    const limit = resolveWindowValue(q.limit, q.limit_param, param_names, param_values);

    var slot_ids: []u64 = &.{};
    var start_index: usize = 0;
    var row_limit: usize = std.math.maxInt(usize);
    var row_offset: usize = 0;

    if (count_precomputed != null) {
        // O(1) count: no slots needed.
    } else if (eligibility.mode == .count) {
        // Filtered count (inline `{prop: val}` and/or WHERE): collect every
        // pattern-matching slot UNBOUNDED — LIMIT on a count query does not
        // bound the inner scan (the result is a single row regardless), so we
        // must not pass `required` here. Inline-prop filters are applied during
        // collection; a WHERE predicate (if any) is re-evaluated per node in
        // `buildCountPage`'s tally. The tally counts matched slots (no clone).
        slot_ids = try collectMatchingSlotIds(allocator, graph_name, eligibility.pattern, null, null, owned_param_names, owned_param_values, context, where_expr);
    } else if (where_expr != null) {
        // Predicate-filtered rows/projection: LIMIT/OFFSET apply to MATCHED rows.
        row_offset = offset;
        if (limit) |l| {
            row_limit = l;
            // H1 (where-limit-lazy): a LIMIT is present, so push the predicate
            // into slot collection and STOP enumerating once `offset+limit`
            // predicate matches are found (the labeled-scan branch enumerates in
            // lock-safe per-shard chunks). `match_cap` includes OFFSET because
            // paging still slices the first `row_offset` matched rows; saturating
            // add guards a pathological `offset+limit` overflow.
            const pushdown = WherePushdown{
                .where_expr = where_expr.?,
                .var_name = var_name,
                .match_cap = offset +| l,
            };
            slot_ids = try collectMatchingSlotIds(allocator, graph_name, eligibility.pattern, null, pushdown, owned_param_names, owned_param_values, context, where_expr);
        } else {
            // No LIMIT: the window is unbounded, so collect every pattern-matching
            // slot (today's behavior); paging evaluates the predicate per row.
            slot_ids = try collectMatchingSlotIds(allocator, graph_name, eligibility.pattern, null, null, owned_param_names, owned_param_values, context, where_expr);
        }
    } else {
        // No predicate: matched == scanned, so bound slot collection by
        // OFFSET+LIMIT and start paging at OFFSET.
        const required = resolveRequiredRows(q, param_names, param_values);
        slot_ids = try collectMatchingSlotIds(allocator, graph_name, eligibility.pattern, required, null, owned_param_names, owned_param_values, context, where_expr);
        start_index = @min(offset, slot_ids.len);
    }
    errdefer if (slot_ids.len > 0) allocator.free(slot_ids);

    var owned_flags = try allocator.alloc([]const u8, flags.len);
    errdefer {
        for (owned_flags[0..flags.len]) |flag| {
            if (flag.len > 0) allocator.free(flag);
        }
        allocator.free(owned_flags);
    }
    for (owned_flags) |*flag| flag.* = "";
    for (flags, 0..) |flag, i| {
        owned_flags[i] = try allocator.dupe(u8, flag);
    }

    // GAP-0902 (selective scan): compute the exact node property keys the
    // predicate + projection read, so the per-node materialize fetches ONLY
    // those (cheap per-key directory lookup) instead of decoding+duping EVERY
    // persisted property. null ⇒ materialize the full node (required when the
    // bare node value escapes — `.node` mode, or a projection that returns `n`
    // itself — because downstream may read any property). Built on the stream
    // arena so it lives for the stream's PULL lifetime.
    const needed_keys: ?[][]const u8 = blk: {
        switch (eligibility.mode) {
            // Bare `RETURN n` / `RETURN n LIMIT k`: the node escapes — full.
            .node => break :blk null,
            // count: only the WHERE predicate's keys are read (no projection,
            // no escape). Unfiltered count never materializes (precomputed or
            // slot tally), so an empty set is fine there too.
            .count => {
                var keys = std.ArrayList([]const u8).empty;
                errdefer keys.deinit(aa);
                if (where_expr) |w| try collectExprPropertyKeys(aa, w, var_name, &keys);
                break :blk try keys.toOwnedSlice(aa);
            },
            // projection: keys from every projected expr + the WHERE predicate.
            // If any projected item is the bare node (or otherwise needs the
            // whole node), fall back to full materialize.
            .projection => {
                for (ret_items) |item| {
                    if (returnItemNeedsWholeNode(item.expr, var_name)) break :blk null;
                }
                var keys = std.ArrayList([]const u8).empty;
                errdefer keys.deinit(aa);
                for (ret_items) |item| try collectExprPropertyKeys(aa, item.expr, var_name, &keys);
                if (where_expr) |w| try collectExprPropertyKeys(aa, w, var_name, &keys);
                break :blk try keys.toOwnedSlice(aa);
            },
        }
    };

    return NodeScanStream{
        .allocator = allocator,
        .arena = arena,
        .graph_name = graph_name,
        .column_name = eligibility.column_name,
        .var_name = var_name,
        .slot_ids = slot_ids,
        .next_index = start_index,
        .first_index = start_index,
        .flags = owned_flags,
        .mode = eligibility.mode,
        .ret_items = ret_items,
        .columns = columns,
        .where_expr = where_expr,
        .row_limit = row_limit,
        .row_offset = row_offset,
        .param_names = owned_param_names,
        .param_values = owned_param_values,
        .exec_context = context,
        .needed_keys = needed_keys,
        .count_precomputed = count_precomputed,
        .env_names = .{var_name},
    };
}

/// GAP-0902: true if a RETURN item needs the WHOLE node materialized (so the
/// selective per-key read must be disabled). This is the bare scanned variable
/// (`RETURN n`) or any shape that yields the node value itself. Property
/// accesses (`n.k`) and member access (`n.k`) do NOT need the whole node.
fn returnItemNeedsWholeNode(expr: ast.Expr, variable_name: []const u8) bool {
    return switch (expr) {
        .Ident => |id| std.ascii.eqlIgnoreCase(id.orig, variable_name) or std.ascii.eqlIgnoreCase(id.cnf, variable_name),
        // PropertyAccess / Member read a single key — handled by collectExprPropertyKeys.
        .PropertyAccess, .Member => false,
        // Any other expression kind: be conservative and materialize fully.
        // (eligibleQuery already restricts projections to property/ident shapes,
        // so this arm is effectively unreachable, but it keeps us safe if the
        // eligibility set is ever broadened.)
        else => true,
    };
}

/// GAP-0902: collect every property key referenced on `variable_name` inside
/// `expr` (e.g. `n.rank`, `n.taxon_id`) into `out` (deduplicated, arena-owned
/// dupes). Mirrors the streamable predicate/projection grammar
/// (`isStreamablePredicateExpr` / `isStreamableProjectionExpr`); any unexpected
/// shape is simply skipped (the caller only reaches here for streamable exprs).
fn collectExprPropertyKeys(
    arena: std.mem.Allocator,
    expr: ast.Expr,
    variable_name: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    switch (expr) {
        .PropertyAccess => |pa| {
            if (std.ascii.eqlIgnoreCase(pa.object, variable_name)) try addKeyUnique(arena, pa.property, out);
        },
        .Member => |top| {
            // SONNY-3189: down a member chain with a loop.
            var m = top;
            while (m.target.* == .Member) m = m.target.Member;
            if (m.target.* == .Ident and
                (std.ascii.eqlIgnoreCase(m.target.Ident.orig, variable_name) or std.ascii.eqlIgnoreCase(m.target.Ident.cnf, variable_name)))
            {
                try addKeyUnique(arena, m.field, out);
            } else {
                try collectExprPropertyKeys(arena, m.target.*, variable_name, out);
            }
        },
        .Unary => |u| try collectExprPropertyKeys(arena, u.expr.*, variable_name, out),
        .Binary => |b| {
            // SONNY-3189: a left-deep chain with a loop, not one recursion per
            // operator; keys in the order the recursion found them.
            var rights: std.ArrayList(*const ast.Expr) = .empty;
            try rights.append(arena, b.right);
            var leaf: *const ast.Expr = b.left;
            while (leaf.* == .Binary) : (leaf = leaf.Binary.left) try rights.append(arena, leaf.Binary.right);
            try collectExprPropertyKeys(arena, leaf.*, variable_name, out);
            var i = rights.items.len;
            while (i > 0) {
                i -= 1;
                try collectExprPropertyKeys(arena, rights.items[i].*, variable_name, out);
            }
        },
        .IsNull => |n| try collectExprPropertyKeys(arena, n.target.*, variable_name, out),
        .Call => |c| {
            for (c.args) |arg| try collectExprPropertyKeys(arena, arg.*, variable_name, out);
        },
        else => {},
    }
}

fn addKeyUnique(arena: std.mem.Allocator, key: []const u8, out: *std.ArrayList([]const u8)) !void {
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing, key)) return;
    }
    try out.append(arena, try arena.dupe(u8, key));
}

/// GAP-0900 (scan-no-clone): pure-AST predicate — true iff `prepare` would
/// handle this query through the engine-backed streaming path. Broadened
/// (2026-06) to cover property projections, simple WHERE / inline-property
/// filters on the scanned variable, and `count(n)` over a label — all served
/// in O(result)/O(scanned) with no whole-graph clone. The transport handlers
/// use this to skip the O(graph) `QueryReadSession` deep-clone for shapes the
/// streaming path serves engine-side. It does no I/O (it inspects the parsed
/// query plus one global pointer) and takes no lock, so it is safe to call
/// before acquiring any lock.
///
/// SONNY-1218 / SONNY-1229: this MUST stay in agreement with `prepare` — it
/// shares the same `canServeEngineDirect` guard, so on an in-memory deployment
/// (no `--data-dir`) OR for a session with a concrete tenant scope / under
/// effective strict tenancy it reports NOT eligible for every shape and the
/// transports keep the snapshot the executor fallback needs. The AST-shape half
/// of the decision is `eligibleQuery`, which remains pure.
///
/// `session_tenant_id` is the session's `tenant_id` (`ExecutionContext.tenant_id`
/// / `state.session_config.?.tenant_id`) — the SAME value the caller will pass
/// to `prepare` via the execution context. It is a required parameter, not an
/// ambient lookup, precisely so a transport cannot forget it: there is no
/// active-context to read at the point the transports make this decision.
pub fn isEligible(q: *const ast.Query, session_tenant_id: ?[]const u8) bool {
    if (!canServeEngineDirect(session_tenant_id)) return false;
    return eligibleQuery(q) != null;
}

// CANARY: REQ=REQ-SONNY-3321-STREAM-ALLOWLIST; FEATURE="NodeScanStream"; ASPECT=FieldAllowlist; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4_transport.zig; OWNER=engine; UPDATED=2026-09-28
/// SONNY-3321: the `ast.Query` fields the stream reads. Every other field
/// must hold its empty value (`write_shape.onlyFields`, checked field by
/// field at compile time), so a field added to the AST, or one this path
/// does not apply, makes the statement ineligible instead of being dropped.
/// The hand-written list it replaces missed `let_bindings`: over QUIC and
/// gRPC `LET $x = 1 IN (... SET ...) MATCH (n:G) RETURN count(*)` was
/// answered here before the write-shape validator could refuse it, and
/// `LET $x = 2 MATCH (n:G) WHERE n.i = $x RETURN n` read $x as unbound.
/// SONNY-6383: `match_clauses` is listed and must describe the single plain
/// MATCH (`write_shape.plainMatchClauses`); unlisted, it refused every
/// parsed MATCH once the parser recorded it (0df2ad6a).
const stream_fields = [_][]const u8{
    "match",        "match_clauses", "where_clause", "filter_clause",
    "ret",          "limit",         "offset",       "limit_param",
    "offset_param",
};

fn eligibleQuery(q: *const ast.Query) ?Eligibility {
    if (!write_shape.onlyFields(q.*, &stream_fields)) return null;
    if (!write_shape.plainMatchClauses(q.*)) return null;
    // One predicate: a WHERE and a FILTER together are both to hold, and the
    // stream applies one (`WHERE n.i > 0 FILTER n.i < 3` returned 9 rows).
    if (q.where_clause != null and q.filter_clause != null) return null;
    if (q.optional_match) return null;
    if (q.with_clause != null or q.group_by != null or q.having != null) return null;
    if (q.order_by != null or q.ret.distinct) return null;
    if (q.inline_let_bindings.len != 0) return null;
    if (q.unwind_clause != null or q.create_pattern != null) return null;
    if (q.call_clause != null or q.initial_call_subquery != null) return null;
    if (q.merge_statement != null or q.next_query != null or q.for_statement != null) return null;
    if (q.path_variable != null or q.has_recursive_cte or q.cte_list != null) return null;
    if (q.set_clauses.len != 0 or q.remove_clauses.len != 0 or q.delete_items.len != 0) return null;
    if (q.match.chains.len != 1) return null;

    const chain = q.match.chains[0];
    if (chain.is_optional or chain.is_shortest or chain.path_mode != .walk) return null;
    if (chain.head == null or chain.hops.len != 0) return null;

    const head = chain.head.?;
    const variable_name = head.name orelse return null;

    // Inline property patterns (`{prop: val}`) are evaluated as equality
    // filters in collectMatchingSlotIds; only accept ones whose values are
    // streamable literals/params (no variable references / subqueries).
    if (head.props) |props| {
        for (props) |prop| {
            if (!isStreamablePredicateExpr(prop.value.*)) return null;
        }
    }

    // WHERE / FILTER must be a streamable predicate over the scanned variable.
    if (q.where_clause orelse q.filter_clause) |w| {
        if (!isStreamablePredicateExpr(w)) return null;
        if (!predicateOnlyReferences(w, variable_name)) return null;
    }

    // No RETURN items → bare-variable scan.
    if (q.ret.items.len == 0) {
        return .{ .pattern = head, .column_name = variable_name, .mode = .node };
    }

    // Single `count(n)` / `count(*)` aggregate.
    if (q.ret.items.len == 1) {
        if (countColumn(q.ret.items[0], variable_name)) |col| {
            return .{ .pattern = head, .column_name = col, .mode = .count };
        }
    }

    // Otherwise: a projection of one or more streamable expressions over the
    // scanned variable. Each item must reference only `n` (and params/literals)
    // and must NOT be an aggregate (those need grouping the stream can't do).
    for (q.ret.items) |item| {
        if (isAggregateCall(item.expr)) return null;
        if (!isStreamableProjectionExpr(item.expr, variable_name)) return null;
    }

    // A single bare-variable RETURN is the node shape (preserves the existing
    // column-name behavior: alias orelse ident.orig).
    if (q.ret.items.len == 1) {
        switch (q.ret.items[0].expr) {
            .Ident => |ident| {
                if (std.ascii.eqlIgnoreCase(ident.orig, variable_name) or std.ascii.eqlIgnoreCase(ident.cnf, variable_name)) {
                    return .{
                        .pattern = head,
                        .column_name = q.ret.items[0].alias orelse ident.orig,
                        .mode = .node,
                    };
                }
            },
            else => {},
        }
    }

    return .{ .pattern = head, .column_name = variable_name, .mode = .projection };
}

/// `count(n)` or `count(*)` (case-insensitive), no other args — returns the
/// output column name (alias orelse "count").
fn countColumn(item: ast.ReturnItem, variable_name: []const u8) ?[]const u8 {
    const call = switch (item.expr) {
        .Call => |c| c,
        else => return null,
    };
    if (call.callee.* != .Ident) return null;
    if (!std.ascii.eqlIgnoreCase(call.callee.Ident.orig, "count")) return null;
    if (call.args.len != 1) return null;
    const arg = call.args[0].*;
    const ok = switch (arg) {
        .Ident => |id| std.mem.eql(u8, id.orig, "*") or
            std.ascii.eqlIgnoreCase(id.orig, variable_name) or
            std.ascii.eqlIgnoreCase(id.cnf, variable_name),
        else => false,
    };
    if (!ok) return null;
    return item.alias orelse "count";
}

fn isAggregateCall(expr: ast.Expr) bool {
    switch (expr) {
        .Call => |call| {
            if (call.callee.* == .Ident) {
                const f = call.callee.Ident.orig;
                return std.ascii.eqlIgnoreCase(f, "count") or
                    std.ascii.eqlIgnoreCase(f, "sum") or
                    std.ascii.eqlIgnoreCase(f, "avg") or
                    std.ascii.eqlIgnoreCase(f, "min") or
                    std.ascii.eqlIgnoreCase(f, "max") or
                    std.ascii.eqlIgnoreCase(f, "collect") or
                    std.ascii.eqlIgnoreCase(f, "countDistinct");
            }
            return false;
        },
        else => return false,
    }
}

/// A RETURN item the stream can project: the bare variable, a property access
/// on it, or a literal. Anything that needs cross-row context (subqueries,
/// pattern comprehensions, other variables, function calls) is rejected.
fn isStreamableProjectionExpr(expr: ast.Expr, variable_name: []const u8) bool {
    return switch (expr) {
        .Ident => |id| std.ascii.eqlIgnoreCase(id.orig, variable_name) or std.ascii.eqlIgnoreCase(id.cnf, variable_name),
        .PropertyAccess => |pa| std.ascii.eqlIgnoreCase(pa.object, variable_name),
        .Member => |m| m.target.* == .Ident and
            (std.ascii.eqlIgnoreCase(m.target.Ident.orig, variable_name) or std.ascii.eqlIgnoreCase(m.target.Ident.cnf, variable_name)),
        else => false,
    };
}

/// A predicate expression the stream can evaluate per node: comparisons and
/// AND/OR/NOT over property accesses on the scanned variable and literals/
/// params. Rejects anything referencing other variables or needing cross-row
/// context, so the per-node `eval.evalExpr` is guaranteed identical to the
/// snapshot executor's per-node evaluation.
fn isStreamablePredicateExpr(root: ast.Expr) bool {
    // SONNY-3189: down AND/OR/comparison, NOT and member chains with a loop,
    // not one recursion per link.
    var at: *const ast.Expr = &root;
    while (true) switch (at.*) {
        .Binary => |b| switch (b.op) {
            .And, .Or, .Eq, .Ne, .Lt, .Le, .Gt, .Ge => {
                if (!isStreamablePredicateExpr(b.right.*)) return false;
                at = b.left;
            },
            else => return false,
        },
        .Unary => |u| {
            if (u.op != .Not) return false;
            at = u.expr;
        },
        .Member => |m| at = m.target,
        else => break,
    };
    const expr = at.*;
    return switch (expr) {
        .Bool, .Int, .Null, .String, .Decimal, .Param => true,
        .SmallIntLit, .BigIntLit, .RealLit, .DoubleLit, .TextLit => true,
        .Ident, .PropertyAccess => true,
        .Member => |m| isStreamablePredicateExpr(m.target.*),
        .Unary => |u| u.op == .Not and isStreamablePredicateExpr(u.expr.*),
        .Binary => |b| switch (b.op) {
            .And, .Or, .Eq, .Ne, .Lt, .Le, .Gt, .Ge => isStreamablePredicateExpr(b.left.*) and isStreamablePredicateExpr(b.right.*),
            else => false,
        },
        .IsNull => |n| isStreamablePredicateExpr(n.target.*),
        else => false,
    };
}

/// Every Ident / property-access target inside the predicate references only
/// the scanned variable (or a parameter). Guards against `WHERE m.x = 1`
/// where `m` is some other (unbound here) variable.
fn predicateOnlyReferences(root: ast.Expr, variable_name: []const u8) bool {
    // SONNY-3189: down binary, unary and member chains with a loop.
    var at: *const ast.Expr = &root;
    while (true) switch (at.*) {
        .Binary => |b| {
            if (!predicateOnlyReferences(b.right.*, variable_name)) return false;
            at = b.left;
        },
        .Unary => |u| at = u.expr,
        .Member => |m| at = m.target,
        else => break,
    };
    const expr = at.*;
    return switch (expr) {
        .Bool, .Int, .Null, .String, .Decimal, .Param => true,
        .SmallIntLit, .BigIntLit, .RealLit, .DoubleLit, .TextLit => true,
        // A bare Ident in a predicate position resolves via Env.get; in the
        // scan it can only legitimately be the scanned variable or a param
        // (param fallback in Env.get). Restrict to the variable name to be safe.
        .Ident => |id| std.ascii.eqlIgnoreCase(id.orig, variable_name) or std.ascii.eqlIgnoreCase(id.cnf, variable_name),
        .PropertyAccess => |pa| std.ascii.eqlIgnoreCase(pa.object, variable_name),
        .Member => |m| predicateOnlyReferences(m.target.*, variable_name),
        .Unary => |u| predicateOnlyReferences(u.expr.*, variable_name),
        .Binary => |b| predicateOnlyReferences(b.left.*, variable_name) and predicateOnlyReferences(b.right.*, variable_name),
        .IsNull => |n| predicateOnlyReferences(n.target.*, variable_name),
        else => false,
    };
}

fn resolveGraphName(context: ExecutionContext) []const u8 {
    if (context.session_state) |session| {
        if (session.graph) |graph_name| return graph_name;
    }
    return graph_store.DEFAULT_GRAPH_NAME;
}

// CANARY: REQ=REQ-SONNY-2473-SKIP-WITHOUT-LIMIT; FEATURE="EngineDirectRowWindow"; ASPECT=UnboundedWithoutLimit; STATUS=TESTED; TEST=tests/test_sonny2473_skip_without_limit.zig; OWNER=engine; UPDATED=2026-09-25
/// How many slots a scan with no WHERE must collect (matched == scanned):
/// OFFSET + LIMIT, or null (every slot) when there is no LIMIT.
/// `collectMatchingSlotIds` caps collection at this, and `prepare` starts the
/// cursor at the OFFSET. An OFFSET alone bounds nothing: `SKIP k` returns every
/// row after the first k (SONNY-2473: this answered k+1 for it, so `SKIP k`
/// returned one row).
fn resolveRequiredRows(
    q: *const ast.Query,
    param_names: []const []const u8,
    param_values: []const Value,
) ?usize {
    const limit = resolveWindowValue(q.limit, q.limit_param, param_names, param_values) orelse return null;
    const offset = resolveWindowValue(q.offset, q.offset_param, param_names, param_values) orelse 0;
    return std.math.add(usize, offset, limit) catch std.math.maxInt(usize);
}

fn resolveWindowValue(
    literal: ?usize,
    param_name: ?[]const u8,
    param_names: []const []const u8,
    param_values: []const Value,
) ?usize {
    if (literal) |value| return value;
    if (param_name) |name| {
        for (param_names, param_values) |param, value| {
            if (!std.mem.eql(u8, param, name)) continue;
            return switch (value) {
                .Int => |integer| if (integer >= 0) @as(usize, @intCast(integer)) else null,
                .SmallInt => |integer| if (integer >= 0) @as(usize, @intCast(integer)) else null,
                .BigInt => |integer| if (integer >= 0) @as(usize, @intCast(integer)) else null,
                else => null,
            };
        }
    }
    return null;
}

/// H1 (where-limit-lazy): a WHERE-predicate pushdown for the labeled-scan
/// collection. When present (a WHERE query WITH a LIMIT), the labeled branch
/// enumerates live slots in lock-safe per-shard CHUNKS, evaluates the predicate
/// per slot, and STOPS once `match_cap` (= offset+limit) predicate-matching rows
/// are collected — bounding the scan by MATCHES instead of materializing every
/// live slot. The predicate is re-evaluated in `buildNextPage` (idempotent),
/// where OFFSET/LIMIT are applied over the matched rows. Absent (no LIMIT, or no
/// WHERE), collection keeps its prior behavior (collect all matching slots).
const WherePushdown = struct {
    where_expr: ast.Expr,
    var_name: []const u8,
    match_cap: usize,
};

/// GAP-ENT-0019: the soundness gate deciding whether a WHERE `var.key = <lit>`
/// may be served by the exact node-property SEEK. IDENTICAL to
/// `match_operations.seekableAsciiStringEq` (kept in sync — see its doc-comment
/// for the full argument). WHERE `=` evaluates with `eval` semantics that are
/// BROADER than the raw-hash index in two ways the index cannot see: (1) string
/// equality is NFC-normalized; (2) `=` cross-type stringify-coerces (int 5 ==
/// "5"). A seek is exact — seek-set ⊇ eval-match-set, so it never MISSES a true
/// match — ONLY when BOTH broadenings are provably impossible for the literal:
///   * pure ASCII  → NFC is identity, so string-eq reduces to exact-byte eq;
///   * non-bool, non-numeric → no non-string scalar can stringify-coerce to it.
/// Any other literal returns false and the caller keeps the full label scan.
fn isSeekableAsciiStringLiteral(s: []const u8) bool {
    for (s) |c| {
        if (c >= 0x80) return false;
    }
    if (std.ascii.eqlIgnoreCase(s, "true") or std.ascii.eqlIgnoreCase(s, "false")) return false;
    if (s.len > 0) {
        if (std.fmt.parseInt(i64, s, 10)) |_| return false else |_| {}
        if (std.fmt.parseFloat(f64, s)) |_| return false else |_| {}
    }
    return true;
}

/// If `e` is `var.<prop>` (either `.PropertyAccess` or `.Member` shape) on
/// `var_name`, return the property key; else null.
fn varPropertyKey(e: ast.Expr, var_name: []const u8) ?[]const u8 {
    return switch (e) {
        .PropertyAccess => |pa| if (std.ascii.eqlIgnoreCase(pa.object, var_name)) pa.property else null,
        .Member => |m| if (m.target.* == .Ident and
            (std.ascii.eqlIgnoreCase(m.target.Ident.orig, var_name) or std.ascii.eqlIgnoreCase(m.target.Ident.cnf, var_name)))
            m.field
        else
            null,
        else => null,
    };
}

/// Extract a string literal (`.String` / `.TextLit`) from `e`, else null.
fn stringLiteralValue(e: ast.Expr) ?[]const u8 {
    return switch (e) {
        .String => |s| s,
        .TextLit => |s| s,
        else => null,
    };
}

/// GAP-ENT-0019: walk `where_expr` for seekable `var.key = <string literal>`
/// equalities and append each as a synthetic `ast.Property` (arena-owned) into
/// `out`, for feeding the exact-index seek. Handles a top-level `=` AND every
/// `=` conjunct of a top-level AND tree (so `a = x AND b > 2` still seeks on
/// `a = x`). Each candidate must pass the SAME per-key completeness gate the
/// inline seek uses (`graph_store.shouldIndexProperty`) AND the
/// `isSeekableAsciiStringLiteral` soundness gate. OR / ordering ops / non-string
/// / numeric-looking / non-ASCII literals are skipped (the caller's full scan +
/// the downstream WHERE re-eval remain correct). The synthetic value Expr is a
/// `.String`, so `seekIndexedCandidates`' `eval`+`valueToPropertyValue` yields
/// the same `String` property value the inline `{prop: 'val'}` path produces.
/// GAP-ENT-0055: recognize a WHERE that is EXACTLY a single seekable
/// `var.key = <ascii string literal>` equality (no AND, no other predicate),
/// so a filtered `count(n)` can be served O(1) from the exact-index posting
/// LENGTH instead of streaming + materializing every matching slot
/// (`buildCountPage`'s tally, O(matching) — 88 s on the 7M store's high-
/// cardinality `source='col'` covering 5.4 M nodes).
///
/// This is the SAME provably-exact shape `countFilteredFastPath` (GAP-ENT-0019)
/// serves O(1), but on the path the QUIC handler ACTUALLY routes filtered
/// counts to (readServedEngineDirect → node_scan_stream), which
/// `countFilteredFastPath` never sees. It must be a SINGLE top-level equality:
/// an AND tree (`a=x AND b>2`) would need per-node re-eval, so it is declined
/// (→ the streaming tally, still correct). Reuses the seek soundness gates
/// (`shouldIndexProperty` completeness + `isSeekableAsciiStringLiteral` NFC /
/// cross-type argument), so the posting bucket holds exactly the eval-matches
/// (the same collision-free posting assumption the T1 index-served aggregate
/// path relies on).
const SeekEqCount = struct { key: []const u8, value: []const u8 };
fn seekableEqCountWhere(where_expr: ast.Expr, var_name: []const u8) ?SeekEqCount {
    const b = switch (where_expr) {
        .Binary => |bin| bin,
        else => return null,
    };
    if (b.op != .Eq) return null; // single equality only (AND / ordering → tally)
    var key: ?[]const u8 = null;
    var lit: ?[]const u8 = null;
    if (varPropertyKey(b.left.*, var_name)) |k| {
        key = k;
        lit = stringLiteralValue(b.right.*);
    } else if (varPropertyKey(b.right.*, var_name)) |k| {
        key = k;
        lit = stringLiteralValue(b.left.*);
    }
    const seek_key = key orelse return null;
    const seek_lit = lit orelse return null;
    if (!graph_store.shouldIndexProperty(seek_key)) return null;
    if (!isSeekableAsciiStringLiteral(seek_lit)) return null;
    return .{ .key = seek_key, .value = seek_lit };
}

fn appendSeekableWhereProps(
    arena: std.mem.Allocator,
    where_expr: ast.Expr,
    var_name: []const u8,
    out: *std.ArrayList(ast.Property),
) !void {
    const b = switch (where_expr) {
        .Binary => |bin| bin,
        else => return,
    };
    if (b.op == .And) {
        // SONNY-3189: an AND chain with a loop, not one recursion per AND;
        // conjuncts in the order the recursion appended them.
        var rights: std.ArrayList(*const ast.Expr) = .empty;
        try rights.append(arena, b.right);
        var leaf: *const ast.Expr = b.left;
        while (leaf.* == .Binary and leaf.Binary.op == .And) : (leaf = leaf.Binary.left) try rights.append(arena, leaf.Binary.right);
        try appendSeekableWhereProps(arena, leaf.*, var_name, out);
        var i = rights.items.len;
        while (i > 0) {
            i -= 1;
            try appendSeekableWhereProps(arena, rights.items[i].*, var_name, out);
        }
        return;
    }
    if (b.op != .Eq) return;

    // Accept `var.key = <str>` and `<str> = var.key`.
    var key: ?[]const u8 = null;
    var lit: ?[]const u8 = null;
    if (varPropertyKey(b.left.*, var_name)) |k| {
        key = k;
        lit = stringLiteralValue(b.right.*);
    } else if (varPropertyKey(b.right.*, var_name)) |k| {
        key = k;
        lit = stringLiteralValue(b.left.*);
    }
    const seek_key = key orelse return;
    const seek_lit = lit orelse return;

    if (!graph_store.shouldIndexProperty(seek_key)) return;
    if (!isSeekableAsciiStringLiteral(seek_lit)) return;

    const val_expr = try arena.create(ast.Expr);
    val_expr.* = ast.Expr{ .String = try arena.dupe(u8, seek_lit) };
    try out.append(arena, ast.Property{ .key = try arena.dupe(u8, seek_key), .value = val_expr });
}

fn collectMatchingSlotIds(
    allocator: std.mem.Allocator,
    graph_name: []const u8,
    pattern: ast.NodePattern,
    required_rows: ?usize,
    where_pushdown: ?WherePushdown,
    param_names: []const []const u8,
    param_values: []const Value,
    context: ExecutionContext,
    // GAP-ENT-0019: the (arena-cloned) WHERE/FILTER predicate for this scan, if
    // any. Used ONLY to extract a seekable `var.key = <literal>` equality to feed
    // the exact-index seek below (narrowing, never a substitute for the full
    // WHERE re-eval done by the caller's tally/paging). null when absent.
    where_expr: ?ast.Expr,
) ![]u64 {
    // SONNY-1218: UNREACHABLE with a null adapter — `prepare` declines the
    // whole path before it gets here (`adapterCanServeEngineDirect`), which is
    // where "the engine cannot serve this" is turned into a DECLINE instead of
    // an empty (silently wrong) row set. Kept as a defensive floor.
    const adapter = graph_store.getGlobalAdapter() orelse return try allocator.alloc(u64, 0);
    if (!adapter.graphExists(graph_name)) {
        return try allocator.alloc(u64, 0);
    }

    const row_cap = required_rows orelse std.math.maxInt(usize);
    var result = try std.ArrayList(u64).initCapacity(allocator, if (required_rows) |cap| @min(cap, 1024) else 256);
    errdefer result.deinit(allocator);

    // KNOWN BUG #1 fix: inline-property equality reads on an INDEXED property
    // (the unique MERGE key or any key the exact node-property index covers)
    // must seek the index (O(matching)) instead of full-scanning the label
    // (O(graph)). `seekIndexedCandidates` returns the candidate slot ids from
    // the exact index, or null when no inline equality predicate targets an
    // indexed, seekable scalar (in which case we fall back to the scan below).
    //
    // Correctness: the index seek only NARROWS the candidate set. Every
    // returned candidate is then re-verified by the unchanged
    // `nodeMatchesPattern` (full label-set + ALL inline-property equality,
    // tolerating hash collisions), so a NON-EMPTY seek's result set is
    // byte-for-byte identical to the full-scan path.
    //
    // SEEK SOUNDNESS (correctness-critical): the seek (whether it returns rows
    // or empty) is trustworthy ONLY when the exact node-property index is
    // guaranteed COMPLETE for the key — i.e. it contains an entry for EVERY live
    // node carrying that key. Completeness is enforced PER-KEY by
    // `seekIndexedCandidates`, which only seeks a key for which
    // `graph_store.shouldIndexProperty(key)` is true:
    //   - lean OFF (default server): true for EVERY key — every property is
    //     indexed on every write and re-indexed by the reopen rebuild.
    //   - lean ON (GEODE_INDEX_MERGE_KEYS_ONLY=1): true only for REGISTERED merge
    //     keys. The exact index is complete for those because (a) live writes
    //     index them and (b) the LEAN-MERGE-KEY-SEEK fix persists the registered
    //     merge-key set and re-registers it in StorageAdapter.init — BEFORE any
    //     graph opens and thus before the reopen exact-index rebuild — so the
    //     rebuild indexes the merge keys' values for ALL existing nodes.
    // A key that is NOT seek-complete (a non-merge key in lean mode) is never
    // seeked: `seekIndexedCandidates` skips it, and if NO inline key is seekable
    // the call returns null and we fall through to the lock-safe full scan
    // below (correct, just not O(1)). The earlier blanket "lean ⇒ no seek" gate
    // is therefore no longer needed; completeness is now decided per-key.
    //
    // GAP-ENT-0019 (WHERE-clause indexed equality): the seek predicate is drawn
    // from TWO sources, merged into one seek pattern so `seekIndexedCandidates`
    // picks the most-selective across both:
    //   (a) INLINE `{prop: val}` on the node (the KNOWN BUG #1 fix above) —
    //       sound by design (re-verified per candidate by `nodeMatchesPattern`).
    //   (b) WHERE-clause `var.key = <string literal>` conjuncts (top-level `=`,
    //       or any `=` conjunct inside an AND tree). Extracted by
    //       `appendSeekableWhereProps` UNDER THE SAME soundness gate the
    //       filtered-count seek uses (`isSeekableAsciiStringLiteral`, identical
    //       to `match_operations.seekableAsciiStringEq`): eval `=` is broader
    //       than the raw-hash index (NFC + cross-type coercion), so ONLY a
    //       pure-ASCII, non-bool, non-numeric string literal on an indexed key is
    //       seek-exact (seek-set ⊇ eval-match-set — never MISSES a match). A
    //       numeric/non-ASCII/coercible literal is dropped and this scan falls
    //       back to the full label scan below.
    // CORRECTNESS: the seek only NARROWS candidates. `nodeMatchesPattern`
    // re-verifies the FULL pattern (labels + inline props) per candidate, and the
    // WHERE predicate itself is STILL re-applied downstream (buildCountPage tally
    // / buildNextPage paging / the pushdown branch) — so narrowing on ONE WHERE
    // conjunct is safe even when the WHERE has other, non-seekable conjuncts, and
    // the result set is byte-for-byte identical to the full-scan path.
    if (pattern.labels.len > 0) {
        var seek_arena = std.heap.ArenaAllocator.init(allocator);
        defer seek_arena.deinit();
        const sa = seek_arena.allocator();
        var seek_props: std.ArrayList(ast.Property) = .empty;
        if (pattern.props) |inline_props| {
            for (inline_props) |p| try seek_props.append(sa, p);
        }
        if (where_expr) |we| {
            try appendSeekableWhereProps(sa, we, pattern.name orelse "", &seek_props);
        }
        if (seek_props.items.len > 0) {
            var seek_pattern = pattern;
            seek_pattern.props = seek_props.items;
            if (try seekIndexedCandidates(allocator, adapter, graph_name, seek_pattern, param_names, param_values, context)) |candidates| {
                defer allocator.free(candidates);
                for (candidates) |slot_id| {
                    // Re-verify against the REAL pattern (NOT seek_pattern): the
                    // synthetic WHERE props are seek-only; the WHERE predicate is
                    // re-applied by the caller's tally/paging.
                    if (!try nodeMatchesPattern(allocator, adapter, graph_name, slot_id, pattern, param_names, param_values, context)) continue;
                    try result.append(allocator, slot_id);
                    if (result.items.len >= row_cap) break;
                }
                return try result.toOwnedSlice(allocator);
            }
        }
    }

    if (pattern.labels.len > 0) {
        // H1 (where-limit-lazy): with a WHERE predicate AND a LIMIT, bound the
        // enumeration by predicate MATCHES — not the whole label. Enumerate live
        // slots in lock-safe per-shard CHUNKS (each shard under its SHARED lock
        // via `appendLabelScanShard` -> `appendLiveNodesForLabelShard`, the SAME
        // lock-safe path `getNodesByLabelCapped` uses — NEVER the unlocked lazy
        // fan-out cursor that crashed under concurrent reader+writer load),
        // evaluate the predicate per slot (lock-free: re-reads the node by id,
        // exactly like the paging path's per-row materialize+evaluate), and STOP
        // once `match_cap` (= offset+limit) matches are collected. Early
        // termination happens at shard/chunk boundaries — BETWEEN locked
        // enumerations — never via an unlocked cursor. Shard order + per-shard
        // posting order match `getNodesByLabelCapped`, so the matched-row window
        // is byte-for-byte identical to the unbounded path; a predicate that
        // matches fewer than `match_cap` rows simply enumerates every shard
        // (correct: 0-match returns none, selective-near-end still scans most).
        if (where_pushdown) |wp| {
            if (try adapter.beginLabelScan(graph_name, pattern.labels[0])) |cursor| {
                // SONNY-2656: each candidate's WHERE runs on this arena,
                // reset after it.
                var scratch = std.heap.ArenaAllocator.init(allocator);
                defer scratch.deinit();
                var shard_idx: usize = 0;
                outer: while (shard_idx < cursor.shard_count) : (shard_idx += 1) {
                    var chunk = std.ArrayList(u64).empty;
                    defer chunk.deinit(allocator);
                    try adapter.appendLabelScanShard(cursor, shard_idx, allocator, &chunk);
                    for (chunk.items) |slot_id| {
                        // Verify the full pattern (extra labels / inline props)
                        // first — cheaper than predicate eval — then the WHERE
                        // predicate. Only predicate-passing slots count toward
                        // `match_cap`; capping on raw slots would under-return.
                        if (!try nodeMatchesPattern(allocator, adapter, graph_name, slot_id, pattern, param_names, param_values, context)) continue;
                        if (!try slotMatchesPredicate(allocator, &scratch, graph_name, slot_id, wp.where_expr, wp.var_name, param_names, param_values, context)) continue;
                        try result.append(allocator, slot_id);
                        if (result.items.len >= wp.match_cap) break :outer;
                    }
                }
            }
            return try result.toOwnedSlice(allocator);
        }

        // CRASH FIX (read-stress): collect the label's live slot ids via the
        // LOCK-SAFE `getNodesByLabelCapped` (each shard materialized under its
        // SHARED read lock) instead of the lazy `iterateNodesByLabel` fan-out,
        // whose per-shard `LabelIndex.scan` ran with NO shard lock and raced a
        // concurrent ingest `addNode` into an out-of-bounds PANIC. The early
        // cap is safe to push down ONLY when there is no per-slot filter
        // (`pattern.props == null`), because then collected == matched. With
        // inline props the per-slot `nodeMatchesPattern` filter decides matches,
        // so we collect ALL slots (cap = null) and let the `row_cap` break below
        // bound the matched rows — capping slot collection would under-return.
        const collect_cap: ?usize = if (pattern.props == null and required_rows != null) row_cap else null;
        const slots = try adapter.getNodesByLabelCapped(graph_name, pattern.labels[0], collect_cap, allocator);
        defer allocator.free(slots);

        for (slots) |slot_id| {
            if (!try nodeMatchesPattern(allocator, adapter, graph_name, slot_id, pattern, param_names, param_values, context)) continue;
            try result.append(allocator, slot_id);
            if (result.items.len >= row_cap) break;
        }
    } else {
        const entries = try adapter.scanAllNodes(graph_name, allocator);
        defer allocator.free(entries);

        for (entries) |entry| {
            if (!try nodeMatchesPattern(allocator, adapter, graph_name, entry.slot_id, pattern, param_names, param_values, context)) continue;
            try result.append(allocator, entry.slot_id);
            if (result.items.len >= row_cap) break;
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// KNOWN BUG #1 fix: when an inline `{prop: val}` equality targets an INDEXED
/// property, return the exact-index candidate slot ids (the caller re-verifies
/// each against the full pattern). Returns `null` when no inline equality
/// predicate targets an indexed, seekable scalar value — the caller then falls
/// back to the full label scan.
///
/// Selection: the most selective indexed equality wins. We probe the posting
/// length for every indexed inline prop and seek on the shortest one (fewest
/// candidates to verify). Ties / single-prop reduce to one seek. This keeps the
/// hot path O(matching) for the unique MERGE key (source_id) while remaining
/// correct for multi-property inline patterns (the non-seeked props are checked
/// by `nodeMatchesPattern`).
fn seekIndexedCandidates(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    pattern: ast.NodePattern,
    param_names: []const []const u8,
    param_values: []const Value,
    context: ExecutionContext,
) !?[]u64 {
    const props = pattern.props orelse return null;
    if (props.len == 0 or pattern.labels.len == 0) return null;

    const env = Env{
        .names = &.{},
        .values = &.{},
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
        .exec_context = @constCast(&context),
    };

    // Pick the most selective indexed equality prop: smallest posting length.
    // `best_pv` (when set) is owned here and freed before every return below.
    var best_key: ?[]const u8 = null;
    var best_pv: ?graph_store.PropertyValue = null;
    var best_len: usize = std.math.maxInt(usize);

    for (props) |prop| {
        // Only equality on a key the exact index actually covers is seekable.
        if (!graph_store.shouldIndexProperty(prop.key)) continue;

        // Evaluate the inline value to a concrete scalar. Eligibility already
        // restricted inline values to streamable literals/params, so this is a
        // pure constant fold. A failure or a non-scalar (e.g. NULL / list /
        // node ref) means we cannot seek on this prop — skip it.
        // SONNY-3316 (round 16, I4): a limit (54001, 53200, a budget or a
        // cancel) fails the read; only a value that cannot be sought skips.
        const expected = eval.evalExpr(allocator, prop.value.*, env) catch |err| {
            if (eval.isResourceLimitError(err)) {
                if (best_pv) |b| property_value_codec.freePropertyValue(allocator, b);
                return err;
            }
            continue;
        };
        // SONNY-2806: the index hashes a duration or a zoned time by its
        // representation, and two equal ones can differ (P1D and PT24H,
        // 01:00+14:00 and 11:00+00:00), so a seek could miss one. Such a
        // property is matched by the scan, which compares by value. (A number
        // hashes by its value; see graph_storage_adapter.hashStorageProperty.)
        if (expected == .Interval or expected == .TimeTZ) continue;
        const pv = property_value_codec.valueToPropertyValue(allocator, expected) catch |err| {
            if (eval.isResourceLimitError(err)) {
                if (best_pv) |b| property_value_codec.freePropertyValue(allocator, b);
                return err;
            }
            continue;
        };
        // NULL inline equality never matches via the index path the same way
        // (`{p: null}` is unusual); leave it to the scan/verify path.
        if (pv == .Null) {
            property_value_codec.freePropertyValue(allocator, pv);
            continue;
        }

        const posting_len = adapter.countCandidateNodesByLabelAndProperty(
            graph_name,
            pattern.labels[0],
            prop.key,
            pv,
        ) catch {
            property_value_codec.freePropertyValue(allocator, pv);
            continue;
        };

        if (posting_len < best_len) {
            if (best_pv) |old| property_value_codec.freePropertyValue(allocator, old);
            best_len = posting_len;
            best_key = prop.key;
            best_pv = pv;
            // A unique-key hit (<=1 candidate) cannot be beaten; stop probing.
            if (posting_len <= 1) break;
        } else {
            property_value_codec.freePropertyValue(allocator, pv);
        }
    }

    const key = best_key orelse return null;
    const pv = best_pv orelse return null;
    defer property_value_codec.freePropertyValue(allocator, pv);

    // SONNY-6362 item 6: a build of the index in flight -> scan instead.
    return adapter.getCandidateNodesByLabelAndProperty(
        graph_name,
        pattern.labels[0],
        key,
        pv,
        allocator,
    ) catch |err| switch (err) {
        error.ExactIndexBusy => null,
        // SONNY-6347: an index over an encrypted field cannot answer.
        error.IndexOverEncryptedField => null,
        else => err,
    };
}

fn nodeMatchesPattern(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    slot_id: u64,
    pattern: ast.NodePattern,
    param_names: []const []const u8,
    param_values: []const Value,
    context: ExecutionContext,
) !bool {
    if (pattern.labels.len > 0 or pattern.props != null) {
        const labels = try adapter.getNodeLabels(graph_name, slot_id, allocator);
        defer {
            for (labels) |label| allocator.free(label);
            allocator.free(labels);
        }
        if (!labelsContainAll(labels, pattern.labels)) {
            return false;
        }
    }

    if (pattern.props == null) return true;

    var props = try adapter.getAllNodeProperties(graph_name, slot_id, allocator);
    defer freeStoragePropertyMap(allocator, &props);

    const env = Env{
        .names = &.{},
        .values = &.{},
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
        .exec_context = @constCast(&context),
    };

    for (pattern.props.?) |prop| {
        // SONNY-3316 (round 16, I4): a limit fails the read, not the row.
        const expected = eval.evalExpr(allocator, prop.value.*, env) catch |err| {
            if (eval.isResourceLimitError(err)) return err;
            return false;
        };
        const actual = props.get(prop.key) orelse return false;
        // SONNY-2806: by value, as the executor compares (a decimal by
        // representation and every extended value never, a DOUBLE included).
        // A stored value that cannot be decoded fails the read.
        if (!try stored_property_equality.matches(allocator, expected, actual)) {
            return false;
        }
    }
    return true;
}

/// H1 (where-limit-lazy): evaluate a WHERE predicate against a single live slot
/// during chunked label-scan collection. Lock-free — it re-reads the node by
/// slot id (`materializeNode`), exactly like the paging path's per-row
/// materialize+evaluate, so no shard lock is held during predicate eval. Mirrors
/// `NodeScanStream.evalPredicate`'s coercion (Bool→value, Null→false,
/// Int→nonzero, else→false). A materialize failure (node vanished via a
/// concurrent delete) or an eval error counts as NO match — identical to the
/// paging path's catch-skip — so the bounded set never includes a stale slot.
fn slotMatchesPredicate(
    allocator: std.mem.Allocator,
    scratch: *std.heap.ArenaAllocator,
    graph_name: []const u8,
    slot_id: u64,
    where_expr: ast.Expr,
    var_name: []const u8,
    param_names: []const []const u8,
    param_values: []const Value,
    context: ExecutionContext,
) !bool {
    const node = materializeNode(allocator, graph_name, slot_id) catch |err| {
        if (eval.isResourceLimitError(err)) return err; // SONNY-3349
        return false;
    };
    defer destroyNode(allocator, node);
    // SONNY-2656: as in `evalPredicate`, the evaluation runs on `scratch`,
    // reset before this returns.
    defer _ = scratch.reset(.retain_capacity);
    const eval_allocator = predicateAllocator(scratch, allocator);
    var names = [_][]const u8{var_name};
    var values = [_]Value{.{ .Node = node }};
    const env = Env{
        .names = names[0..1],
        .values = values[0..1],
        .param_names = param_names,
        .param_values = param_values,
        .allocator = eval_allocator,
        .exec_context = @constCast(&context),
    };
    // SONNY-3251 (round 15, F6): a limit fails the read; any other error is
    // a miss.
    const where_result = eval.evalExpr(eval_allocator, where_expr, env) catch |err| {
        if (eval.isResourceLimitError(err)) return err;
        return false;
    };
    return predicateHolds(where_result);
}

/// The snapshot executor's label-scan WHERE coercion, exactly
/// (match_operations.zig generateCombinations): a row passes only when the
/// condition is the Boolean True (SONNY-6425: ISO/IEC 39075 19.1 GR2; a
/// non-zero Int counted as true).
fn predicateHolds(where_result: Value) bool {
    return switch (where_result) {
        .Bool => |b| b,
        .Null => false,
        else => false,
    };
}

// CANARY: REQ=REQ-SONNY-2656-EXTENDED-VALUE-LEAKS; FEATURE="EngineDirectExtendedValueOwnership"; ASPECT=PredicateScratchArena; STATUS=TESTED; TEST=tests/test_sonny2656_extended_value_leaks.zig; OWNER=engine; UPDATED=2026-09-25
/// The allocator a WHERE runs on for one node (SONNY-2656). A WHERE yields
/// only a Bool, but what it reads along the way is allocated: `.Member`
/// hands back a fresh clone of an extended value (Text, Json, Bytea, a list,
/// ...), and `IS NULL` and the comparisons drop it unfreed. So the WHERE runs
/// on `scratch`, which its caller resets after each node, and the clones go
/// with it. The one exception is a deployment with encrypted fields:
/// decrypting one can create the process-wide FLE key manager on the
/// evaluation allocator, and that must never be an arena that is reset. There
/// the WHERE runs on `allocator`, as it always did.
fn predicateAllocator(scratch: *std.heap.ArenaAllocator, allocator: std.mem.Allocator) std.mem.Allocator {
    if (fle_integration.hasEncryptedFields()) return allocator;
    return scratch.allocator();
}

// CANARY: REQ=REQ-SONNY-3349-PROFILE-RELAY; FEATURE="NodeScanStream"; ASPECT=MaterializeLimitFails; STATUS=TESTED; TEST=tests/test_sonny3349_profile_relay.zig; OWNER=server; UPDATED=2026-09-28
/// SONNY-3349 (round 17): a test seam. When set on a thread, `materializeNode`
/// and `materializeNodeProjected` fail with it, as an allocation or a node
/// deleted under the scan would. Never set outside tests.
///
/// The scan skips a node it cannot materialize, which a concurrent delete
/// explains; a resource limit (out of memory) is not a missing node, and
/// fails the query (the paging scan, the filtered count, and the WHERE +
/// LIMIT enumeration). It became a row the query did not return.
pub threadlocal var test_materialize_error: ?error{ OutOfMemory, NodeNotFound } = null;

fn materializeNode(allocator: std.mem.Allocator, graph_name: []const u8, slot_id: u64) !*graph_store.Node {
    if (test_materialize_error) |err| return err;
    _ = g_nodes_materialized_total.fetchAdd(1, .monotonic);
    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
    const node = try newNode(allocator, adapter, graph_name, slot_id);
    // SONNY-2463: the node owns everything put into it from here on, so a
    // failure part way frees all of it (see "Node ownership" at `destroyNode`).
    errdefer destroyNode(allocator, node);

    var props = try adapter.getAllNodeProperties(graph_name, slot_id, allocator);
    defer freeStoragePropertyMap(allocator, &props);

    var iter = props.iterator();
    while (iter.next()) |entry| {
        try putProperty(allocator, node, entry.key_ptr.*, entry.value_ptr.*);
    }

    return node;
}

/// The node for `slot_id` with its id, labels and graph name, and no
/// properties yet. It owns what it holds, so `destroyNode` frees it whatever
/// is later put into it. On failure, nothing is left allocated.
fn newNode(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    slot_id: u64,
) !*graph_store.Node {
    const store = graph_store.getGlobalStore(allocator);
    const external_id = try resolveExternalNodeId(allocator, adapter, store, graph_name, slot_id);

    const labels = try adapter.getNodeLabels(graph_name, slot_id, allocator);
    errdefer {
        for (labels) |label| allocator.free(label);
        allocator.free(labels);
    }
    const owned_graph_name = try allocator.dupe(u8, graph_name);
    errdefer allocator.free(owned_graph_name);

    const node = try allocator.create(graph_store.Node);
    node.* = .{
        .id = external_id,
        .labels = labels,
        .properties = graph_store.CompactPropertyMap.init(allocator),
        .graph_name = owned_graph_name,
    };
    return node;
}

// CANARY: REQ=REQ-SONNY-2463-MATERIALIZE-OOM; FEATURE="EngineDirectNodeOwnership"; ASPECT=PartialNodeFreed; STATUS=TESTED; TEST=tests/test_sonny2463_materialize_oom.zig; OWNER=engine; UPDATED=2026-09-25
/// Put a copy of `key` = `value` (a storage read) into `node`. `node` owns the
/// copies once the put succeeds. If a copy or the put itself fails, the copies
/// made so far are freed here, and the node is unchanged (a failed put leaves
/// the map as it was).
fn putProperty(allocator: std.mem.Allocator, node: *graph_store.Node, key: []const u8, value: gs.PropertyValue) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    const decoded = try graph_storage_adapter.fromStorageProperty(allocator, value);
    errdefer property_value_codec.freePropertyValue(allocator, decoded);
    try node.properties.put(owned_key, decoded);
}

/// Test-only (SONNY-2463): build the node for `slot_id` exactly as the scan
/// does, from `needed_keys` when given (`materializeNodeProjected`), else in
/// full (`materializeNode`), so a test can drive it under a failing
/// allocator. Free the result with `destroyNodeForTest`.
pub fn materializeNodeForTest(allocator: std.mem.Allocator, graph_name: []const u8, slot_id: u64, needed_keys: ?[]const []const u8) !*graph_store.Node {
    if (needed_keys) |keys| return materializeNodeProjected(allocator, graph_name, slot_id, keys);
    return materializeNode(allocator, graph_name, slot_id);
}

/// SONNY-3350 (round 17): a test seam: `resolveExternalNodeId`.
pub fn resolveExternalNodeIdForTest(allocator: std.mem.Allocator, graph_name: []const u8, slot_id: u64) !u64 {
    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
    return resolveExternalNodeId(allocator, adapter, graph_store.getGlobalStore(allocator), graph_name, slot_id);
}

/// Test-only (SONNY-2463): `destroyNode`, for a node `materializeNodeForTest`
/// built.
pub fn destroyNodeForTest(allocator: std.mem.Allocator, node: *graph_store.Node) void {
    destroyNode(allocator, node);
}

/// GAP-0902 (selective scan): materialize a node reading ONLY `needed_keys` —
/// the keys the predicate + projection reference. Per-key `adapter.getNodeProperty`
/// uses a per-page directory-hash lookup (graph_storage PERF-0023), so for the
/// 1-2 keys typical of a filtered/projected scan this is far cheaper than
/// `getAllNodeProperties` (no full property-chain decode, no dupe of every
/// persisted key) — turning an O(N) full-node-hydration scan into O(N) cheap
/// per-key reads. Labels are still read (cheap; some projections/predicates
/// reference labels indirectly and the row builder expects them). Returned node
/// is owned by `allocator` and freed by `destroyNode`, identical to
/// `materializeNode`. Engine-direct: never touches the node cache.
fn materializeNodeProjected(
    allocator: std.mem.Allocator,
    graph_name: []const u8,
    slot_id: u64,
    needed_keys: []const []const u8,
) !*graph_store.Node {
    if (test_materialize_error) |err| return err; // SONNY-3349
    _ = g_nodes_materialized_total.fetchAdd(1, .monotonic);
    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
    const node = try newNode(allocator, adapter, graph_name, slot_id);
    // SONNY-2463: as in `materializeNode`, a failure part way (an allocation,
    // or a later key's read finding the node deleted) frees all of it.
    errdefer destroyNode(allocator, node);

    for (needed_keys) |key| {
        const maybe_val = adapter.getNodeProperty(graph_name, slot_id, key, allocator) catch |err| switch (err) {
            error.NodeNotFound => return error.NodeNotFound,
            else => return err,
        };
        const val = maybe_val orelse continue;
        defer freeStoragePropertyValue(allocator, val);
        // `needed_keys` is deduplicated by `addKeyUnique`, so no key repeats —
        // a plain put is correct (no duplicate to reconcile).
        try putProperty(allocator, node, key, val);
    }

    return node;
}

fn labelsContainAll(actual: []const []const u8, required: []const []const u8) bool {
    for (required) |required_label| {
        var found = false;
        for (actual) |actual_label| {
            if (std.mem.eql(u8, actual_label, required_label)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Resolve the external (public) node ID for a given adapter slot.
/// First checks the in-memory IdMap; if missing, falls back to reading the
/// persisted `__geode_internal_node_id` property from the adapter and
/// back-fills the IdMap so subsequent lookups are O(1).
fn resolveExternalNodeId(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    store: *graph_store.GraphStore,
    graph_name: []const u8,
    slot_id: u64,
) !u64 {
    // Fast path: IdMap already has the mapping. SONNY-3350: read with the
    // map pinned (`GraphStore.idMapNodeId`).
    if (store.idMapNodeId(graph_name, slot_id)) |id| return id;

    // Slow path: read the persisted public ID property from the adapter.
    // SONNY-3348 round 18 (review M1): a resource limit fails the query (it
    // was swallowed, and the slot used as the id: a wrong row).
    // SONNY-3348 round 19 (review m4): only a node or graph that is gone
    // is skipped; any other read error (an engine I/O error) fails the
    // query instead of dropping the row silently.
    const stored = adapter.getNodeProperty(graph_name, slot_id, graph_store.INTERNAL_NODE_ID_PROPERTY_KEY, allocator) catch |err| switch (err) {
        error.NodeNotFound, error.GraphNotFound => return error.NodeNotFound,
        else => return err,
    };
    if (stored) |stored_prop| {
        defer freeStoragePropertyValue(allocator, stored_prop);
        const public_id: ?u64 = switch (stored_prop) {
            .string => |text| graph_store.parsePersistedPublicId(text),
            .int => |n| if (n >= 0) @as(u64, @intCast(n)) else null,
            else => null,
        };
        if (public_id) |pid| {
            // Back-fill the IdMap for future lookups (SONNY-3350: pinned).
            store.idMapBackfillNode(graph_name, pid, slot_id);
            return pid;
        }
    }

    // Neither the IdMap nor the persisted property has a public id for this
    // slot: the node is gone (a DROP GRAPH, or a delete, after the scan read
    // the slot). SONNY-3348 round 18 (review M1): the caller skips it. The
    // slot was returned as the node's id, a row with an id no node has.
    return error.NodeNotFound;
}

/// Free a value the storage adapter read for this file (`getNodeProperty`,
/// `getAllNodeProperties`). The engine's decode copies both a string and an
/// extended value's bytes onto the caller's allocator (SONNY-2464: the
/// extended value's bytes used to leak on every read).
fn freeStoragePropertyValue(allocator: std.mem.Allocator, value: gs.PropertyValue) void {
    switch (value) {
        .string => |text| allocator.free(text),
        .ext => |ext| allocator.free(ext.data),
        else => {},
    }
}

fn freeStoragePropertyMap(allocator: std.mem.Allocator, map: *std.StringHashMap(gs.PropertyValue)) void {
    var iter = map.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        freeStoragePropertyValue(allocator, entry.value_ptr.*);
    }
    map.deinit();
}

// ===========================================================================
// Focused AST / Value cloning into the stream arena.
//
// Only the eligible-subset expression kinds are clonable; anything else
// returns error.Unsupported so `prepare` bails to the snapshot path. This
// keeps the clone bounded and guarantees we never stream a shape we cannot
// evaluate identically.
// ===========================================================================

const CloneError = error{ OutOfMemory, Unsupported };

fn cloneReturnItems(arena: std.mem.Allocator, items: []const ast.ReturnItem) CloneError![]ast.ReturnItem {
    const out = try arena.alloc(ast.ReturnItem, items.len);
    for (items, 0..) |item, i| {
        out[i] = .{
            .expr = try cloneExpr(arena, item.expr),
            .alias = if (item.alias) |a| try arena.dupe(u8, a) else null,
        };
    }
    return out;
}

fn cloneExprPtr(arena: std.mem.Allocator, e: *const ast.Expr) CloneError!*ast.Expr {
    const p = try arena.create(ast.Expr);
    p.* = try cloneExpr(arena, e.*);
    return p;
}

fn cloneIdent(arena: std.mem.Allocator, id: ast.IdentRepr) CloneError!ast.IdentRepr {
    return .{ .orig = try arena.dupe(u8, id.orig), .cnf = try arena.dupe(u8, id.cnf) };
}

/// SONNY-3189: copy a chain of member accesses and binary operators with a
/// loop: down the member targets and left operands, each copied link's child
/// slot filled by the next link; right operands and the innermost operand
/// through `cloneExprPtr`.
fn cloneChain(arena: std.mem.Allocator, e: ast.Expr) CloneError!ast.Expr {
    var result: ast.Expr = undefined;
    var slot: *ast.Expr = &result;
    var src: *const ast.Expr = &e;
    while (true) {
        switch (src.*) {
            .Member => |m| {
                const child = try arena.create(ast.Expr);
                slot.* = .{ .Member = .{ .target = child, .field = try arena.dupe(u8, m.field) } };
                slot = child;
                src = m.target;
            },
            .Binary => |b| {
                const child = try arena.create(ast.Expr);
                slot.* = .{ .Binary = .{ .op = b.op, .left = child, .right = try cloneExprPtr(arena, b.right) } };
                slot = child;
                src = b.left;
            },
            else => {
                slot.* = try cloneExpr(arena, src.*);
                return result;
            },
        }
    }
}

fn cloneExpr(arena: std.mem.Allocator, e: ast.Expr) CloneError!ast.Expr {
    return switch (e) {
        .Null => .Null,
        .Int => |n| .{ .Int = n },
        .Bool => |b| .{ .Bool = b },
        .String => |s| .{ .String = try arena.dupe(u8, s) },
        .TextLit => |s| .{ .TextLit = try arena.dupe(u8, s) },
        .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        .SmallIntLit => |v| .{ .SmallIntLit = v },
        .BigIntLit => |v| .{ .BigIntLit = v },
        .RealLit => |v| .{ .RealLit = v },
        .DoubleLit => |v| .{ .DoubleLit = v },
        .Param => |p| .{ .Param = try arena.dupe(u8, p) },
        .Ident => |id| .{ .Ident = try cloneIdent(arena, id) },
        .PropertyAccess => |pa| .{ .PropertyAccess = .{
            .object = try arena.dupe(u8, pa.object),
            .property = try arena.dupe(u8, pa.property),
        } },
        // SONNY-3189: member and binary chains are copied with a loop
        // (`cloneChain`), not one recursion per link.
        .Member, .Binary => cloneChain(arena, e),
        .Unary => |u| .{ .Unary = .{
            .op = u.op,
            .expr = try cloneExprPtr(arena, u.expr),
        } },
        .IsNull => |n| .{ .IsNull = .{
            .target = try cloneExprPtr(arena, n.target),
            .negated = n.negated,
        } },
        .Call => |c| blk: {
            const callee = try cloneExprPtr(arena, c.callee);
            const args = try arena.alloc(*ast.Expr, c.args.len);
            for (c.args, 0..) |arg, i| args[i] = try cloneExprPtr(arena, arg);
            break :blk .{ .Call = .{ .callee = callee, .args = args } };
        },
        else => return CloneError.Unsupported,
    };
}

fn cloneValue(arena: std.mem.Allocator, v: Value) CloneError!Value {
    return switch (v) {
        .Str => |s| .{ .Str = try arena.dupe(u8, s) },
        .Text => |s| .{ .Text = try arena.dupe(u8, s) },
        // Scalars and other shallow values copy by value; complex reference
        // types (Node/Edge/List/Map/Path) are not valid bound parameters for
        // a streamed scan predicate — but if present they are shared, not
        // owned, so a shallow copy is the same semantics the executor sees.
        else => v,
    };
}
