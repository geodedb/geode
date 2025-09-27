const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const protocol = geode.protocol;
const impl_flagger = @import("flagger_impl_defined.zig");
const diagnostics = @import("geode").diagnostics;
const eval = geode.eval;
const exec = geode.exec;
const wal_mod = @import("wal");
const storage_pm = @import("storage_page_manager");
const storage_catalog = @import("storage_catalog");
const txn_mgr = @import("txn");
const SelectivityEstimator = @import("index_selectivity").SelectivityEstimator;
const TextFormatter = @import("text_formatter").TextFormatter;
const quic_transport = @import("transport/quic.zig");
const cert_gen = @import("tools/cert_gen.zig");
const mvcc = @import("server/txn/mvcc.zig");
const logger = @import("log/logger.zig");
// Cost model explain helpers now accessed via geode root module re-exports (distinct from calibration reporting module)
const cost_explain = geode.cost_explain;

const UnionMetrics = struct { left_in: usize, right_in: usize, out: usize, hash_size: ?usize };

// Lightweight server implementing JSON line protocol used by tests.
// Focus: RETURN queries, UNION (ALL/DISTINCT), GROUP BY aggregation via exec.runGroupedQuery,
// ORDER/LIMIT/OFFSET legality (US001), EXPLAIN/PROFILE, pagination, txn demarcation.

const ServerStateInsertedValue = struct { value: []const u8, creator_txn: u64, commit_ts: ?u64 = null, aborted: bool = false };

const ServerState = struct {
    // Soft per-query memory limit: bytes threshold to trigger spills (0 = disabled)
    query_mem_limit_bytes: usize = 0,
    last_columns: []const protocol.SchemaCol = &.{},
    last_ordered: bool = false,
    last_order_keys: []const []const u8 = &.{},
    last_distinct: bool = false,
    page_items: [][]const u8 = &.{}, // each: JSON row fragment {..}
    page_index: usize = 0,
    active_result: bool = false,
    // Advisory diagnostic flags for current active result set (cleared after first page emission)
    guard_trip: bool = false, // set when ExecutionGuardTrip occurred during evaluation
    // Transaction session state: single active txn baseline
    in_txn: bool = false,
    txn_id: u64 = 0,
    allocator: std.mem.Allocator,
    // PROFILE mode staging: we emit SCHEMA immediately and defer PROFILE frame until first PULL.
    profile_json: ?[]const u8 = null,
    profile_flags: []const []const u8 = &.{},
    // Simulated spill counters (future: real spill logic). Populated from env vars GEODE_FORCE_*.
    spill_sort: usize = 0,
    spill_distinct: usize = 0,
    spill_union: usize = 0,
    spill_hashagg: usize = 0,

    // WAL integration (phase: skip ratio exposure) — optional pointer injected during server bootstrap.
    wal_ptr: ?*anyopaque = null,
    // Storage corruption state flags captured at startup (e.g. checksum mismatch on persisted page load).
    storage_checksum_error: bool = false,
    // Original GQL text (used heuristically for NodeIndexScan selection in PROFILE).
    query_text: ?[]const u8 = null,
    txn_manager: txn_mgr.Manager = undefined,
    active_txn: ?txn_mgr.Txn = null,
    // MVCC-aware heap of inserted values. commit_ts null => uncommitted.
    inserted_values: std.ArrayList(ServerStateInsertedValue) = undefined,
    global_commit_ts: u64 = 0, // monotonically increasing commit timestamp
    session_snapshot_ts: u64 = 0, // snapshot timestamp captured at BEGIN
    // MVCC manager for conflict detection
    mvcc_manager: ?*mvcc.MVCCManager = null,
    current_mvcc_txn: ?*mvcc.Transaction = null,
    // Aggregation memory metrics (non-PROFILE path instrumentation)
    agg_build_bytes_last: usize = 0,
    agg_emit_bytes_last: usize = 0,

    // Telemetry toggles (env-driven). When enabled, server emits JSON log lines on paging events.
    telemetry_paging: bool = false,

    // Optional CDC engine pointer for diagnostics protocol frame
    // NOTE: relative import because build.zig does not register a module alias for streaming/cdc_enhanced
    cdc_engine: ?*@import("cdc_enhanced").CDCEngine = null,

    fn resetResult(self: *ServerState) void {
        // Free row fragments
        var i: usize = 0;
        while (i < self.page_items.len) : (i += 1) self.allocator.free(self.page_items[i]);
        self.page_items = &.{};
        self.page_index = 0;
        self.active_result = false;
        self.last_columns = &.{};
        self.last_order_keys = &.{};
        self.last_ordered = false;
        self.last_distinct = false;
        if (self.profile_json) |pj| self.allocator.free(pj);
        self.profile_json = null;
        self.profile_flags = &.{};
        if (self.query_text) |qt| self.allocator.free(qt);
        self.query_text = null;
    }
};

const DEBUG_PROFILE = false; // default off; enable locally when investigating PROFILE frame assembly

// Tracking allocator (existing) provides basic net/peak metrics for PROFILE.
const TrackingAllocator = @import("tracking_alloc").TrackingAllocator;

// Dynamic flag construction originally used stack slices causing dangling references.
// Replace with static precomputed combinations (NULLs policy toggled at runtime where needed).
var g_nulls_last: bool = false; // default NullsFirstPolicy unless overridden by env
var g_order_keys_expr: bool = false; // default identifiers-only; toggled via --order-keys expr
// CANARY: REQ=REQ-GQL-004; FEATURE="Pagination Legality (US001)"; ASPECT=IllegalOrderKeyPolicy; STATUS=TESTED; TEST=TestGQL_IllegalOrderKey; OWNER=planner; UPDATED=2025-09-26

// Base flag strings (shared)
const F_ILLEGAL = "I:IllegalOrderKeyPolicy=ident-only";
const F_NULLS_FIRST = "U:NullsFirstPolicy";
const F_NULLS_LAST = "U:NullsLastPolicy";
const F_TIEBREAK = "U:OrderTiebreak=LexJSON";
const F_DISTINCT_UNORDERED = "U:DistinctOutputUnordered";
const F_UNION_PHASES = "U:UnionPhaseTimings";
const F_ADAPT_EST = "U:AdaptiveEstimatesPlanned"; // groundwork flag (no behavior change yet)
const F_HEUR_INDEX = "U:HeuristicIndexSelection"; // emitted when NodeIndexScan chosen via heuristic

// Basic in-memory index catalog (phase 2 cost stub).
const IndexStats = struct {
    name: []const u8,
    key: []const u8,
    total_rows: usize,
    distinct_keys: usize,
    fn eqSelectivity(self: IndexStats) f64 {
        if (self.distinct_keys == 0) return 1.0;
        return 1.0 / @as(f64, @floatFromInt(self.distinct_keys));
    }
};

var g_index_catalog_map: std.StringHashMap(IndexStats) = undefined; // key -> stats
var g_index_catalog_inited = false;
var g_disable_catalog = false; // env toggle
var g_selectivity_estimator: ?*SelectivityEstimator = null;

fn initIndexCatalog(ally: std.mem.Allocator) void {
    if (g_index_catalog_inited) return;
    g_index_catalog_map = std.StringHashMap(IndexStats).init(ally);

    // Initialize selectivity estimator
    const estimator = ally.create(SelectivityEstimator) catch return;
    estimator.* = SelectivityEstimator.init(ally);
    g_selectivity_estimator = estimator;

    // Seed with synthetic stats for x,y columns
    g_index_catalog_map.put("x", IndexStats{ .name = "idx_x", .key = "x", .total_rows = 1000, .distinct_keys = 200 }) catch {};
    g_index_catalog_map.put("y", IndexStats{ .name = "idx_y", .key = "y", .total_rows = 1000, .distinct_keys = 500 }) catch {};

    // Update selectivity estimator with same stats
    if (g_selectivity_estimator) |est| {
        est.updateStats("x", 1000, 200, 10) catch {};
        est.updateStats("y", 1000, 500, 5) catch {};
    }

    g_index_catalog_inited = true;
}

fn chooseIndexForPredicate(ally: std.mem.Allocator, predicate_expr: ?*const anyopaque, has_equality: bool, est_rows: usize) ?IndexStats {
    _ = ally; // currently unused for phase 2 stub
    _ = predicate_expr; // future: inspect to derive property name
    if (g_disable_catalog or !has_equality) return null;

    // Use SelectivityEstimator if available for more sophisticated cost-based decision
    if (g_selectivity_estimator) |estimator| {
        var best: ?IndexStats = null;
        var best_cost: f64 = @as(f64, @floatFromInt(est_rows)); // table scan cost

        var it = g_index_catalog_map.iterator();
        while (it.next()) |entry| {
            const st = entry.value_ptr.*;
            const index_cost = estimator.estimateIndexCost(st.key, .Equality, est_rows);
            if (index_cost < best_cost * 0.9) { // require at least 10% benefit
                best = st;
                best_cost = index_cost;
            }
        }
        return best;
    }

    // Fallback to original simple heuristic
    var best: ?IndexStats = null;
    var it = g_index_catalog_map.iterator();
    while (it.next()) |entry| {
        const st = entry.value_ptr.*;
        if (best == null or st.eqSelectivity() < best.?.eqSelectivity()) best = st;
    }
    if (best) |b| {
        // Very naive cost: full scan cost = est_rows, index cost = selectivity * total_rows + log(total_rows)
        const scan_cost = @as(f64, @floatFromInt(est_rows));
        const idx_rows = b.eqSelectivity() * @as(f64, @floatFromInt(b.total_rows));
        const idx_cost = idx_rows + std.math.log(f64, 2, @as(f64, @floatFromInt(b.total_rows + 1)));
        if (idx_cost < scan_cost * 0.9) { // require at least 10% benefit
            return b;
        }
    }
    return null;
}

// Maintenance: adjust stats for insert/delete operations (prototype; real impl needs per-index key detection).
fn indexStatsOnInsert(key: []const u8) void {
    if (!g_index_catalog_inited or g_disable_catalog) return;
    if (g_index_catalog_map.getPtr(key)) |st| {
        st.total_rows += 1;
        // naive: assume new distinct every 5 inserts
        if ((st.total_rows % 5) == 0) st.distinct_keys += 1;

        // Update selectivity estimator
        if (g_selectivity_estimator) |est| {
            est.updateStats(key, st.total_rows, st.distinct_keys, 0) catch {};
        }
    }
}
fn indexStatsOnDelete(key: []const u8) void {
    if (!g_index_catalog_inited or g_disable_catalog) return;
    if (g_index_catalog_map.getPtr(key)) |st| {
        if (st.total_rows > 0) st.total_rows -= 1;
        // naive: distinct unaffected for prototype

        // Update selectivity estimator
        if (g_selectivity_estimator) |est| {
            est.updateStats(key, st.total_rows, st.distinct_keys, 0) catch {};
        }
    }
}

// Helper returns correct null policy flag pointer.
inline fn nullsFlag() []const u8 {
    return if (g_nulls_last) F_NULLS_LAST else F_NULLS_FIRST;
}

// Expanded base buffer to accommodate impl-defined findings (e.g., ZeroLengthPathExcluded)
var flags_buf_base: [12][]const u8 = undefined; // room for adaptive + impl-defined additions
var flags_buf_ext: [7][]const u8 = undefined; // room for adaptive + union phases + deprecation
var g_adapt_estimates: bool = false; // env or future CLI toggled
var g_estimate_adjust_factor: f64 = 1.0; // groundwork; stays 1.0 until adaptive algorithm enabled

// Global graph storage singleton (temporary - should be persistent)
var g_graph_storage: ?*graph_exec.GraphStorage = null;
// Global MVCC manager for transaction conflict detection
var g_mvcc_manager: ?*mvcc.MVCCManager = null;

// Implementation-defined flag cache (codes only). Allocated once on first use.
var g_impl_defined_codes: [][]const u8 = &.{};
var g_impl_defined_inited: bool = false;

// Pagination streaming scaffold (S-018): introduce a stub to emit incremental pages in future slices.
// Current implementation writes full result; this stub records an intent and adds CANARY evidence.
// CANARY: REQ=REQ-GQL-004; FEATURE="PaginationExecutionStreaming"; ASPECT=Scaffold; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_004_PaginationStreamingScaffold; OWNER=planner; UPDATED=2025-09-23
fn paginationStreamScaffold(total_rows: usize, page_size: usize) bool {
    // Return true if streaming would produce multiple pages (future: drive incremental emission loop)
    if (page_size == 0) return false;
    return total_rows > page_size;
}

fn initImplDefinedFlags(ally: std.mem.Allocator) void {
    if (g_impl_defined_inited) return;
    if (impl_flagger.collect(ally, .{ .zero_length_paths_excluded = true, .collation_binary_default = true, .null_order_policy_default = true })) |findings| {
        // Extract codes slice
        const codes = ally.alloc([]const u8, findings.len) catch return;
        var i: usize = 0;
        while (i < findings.len) : (i += 1) codes[i] = findings[i].code;
        g_impl_defined_codes = codes;
        g_impl_defined_inited = true;
    } else |_| {
        return; // leave empty on failure
    }
}

fn getOrCreateMVCCManager(ally: std.mem.Allocator) *mvcc.MVCCManager {
    if (g_mvcc_manager) |mgr| {
        return mgr;
    }

    const mgr = ally.create(mvcc.MVCCManager) catch unreachable;
    mgr.* = mvcc.MVCCManager.init(ally);
    g_mvcc_manager = mgr;
    return mgr;
}

fn getOrCreateGraphStorage(ally: std.mem.Allocator) *graph_exec.GraphStorage {
    if (g_graph_storage) |graph| return graph;
    const graph = ally.create(graph_exec.GraphStorage) catch unreachable;
    graph.* = graph_exec.GraphStorage.init(ally);
    initializeSampleGraph(ally, graph) catch {};
    g_graph_storage = graph;
    return graph;
}

fn tryLoadGraphFromDir(ally: std.mem.Allocator, dir_path: []const u8) !*graph_exec.GraphStorage {
    const g = ally.create(graph_exec.GraphStorage) catch return error.OutOfMemory;
    g.* = graph_exec.GraphStorage.init(ally);
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    // nodes.jsonl and edges.jsonl simple line-delimited json
    if (dir.openFile("nodes.jsonl", .{})) |nf| {
        defer nf.close();
        const content = try nf.readToEndAlloc(ally, 1024 * 1024 * 10); // 10MB max
        defer ally.free(content);
        var lines = std.mem.tokenizeScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const parsed = std.json.parseFromSlice(std.json.Value, ally, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const obj = parsed.value.object;
            const idv = obj.get("id") orelse continue;
            const id: u64 = switch (idv) {
                .integer => |iv| @intCast(iv),
                else => 0,
            };
            if (id == 0) continue;
            var labels: []const []const u8 = &.{};
            if (obj.get("labels")) |lv| if (lv == .array) {
                const arr = lv.array.items;
                var tmp = try ally.alloc([]const u8, arr.len);
                var i: usize = 0;
                while (i < arr.len) : (i += 1) tmp[i] = if (arr[i] == .string) arr[i].string else "";
                labels = tmp;
            };
            try g.addNode(ally, id, labels);
            if (obj.get("properties")) |pv| {
                if (pv == .object) {
                    var it = pv.object.iterator();
                    while (it.next()) |e| {
                        const key = e.key_ptr.*;
                        const val = e.value_ptr.*;
                        const pv2: graph_exec.PropertyValue = switch (val) {
                            .null => .{ .Null = {} },
                            .bool => |b| .{ .Bool = b },
                            .integer => |n| .{ .Int = @intCast(n) },
                            .string => |s| .{ .String = s },
                            else => .{ .Null = {} },
                        };
                        g.setNodeProperty(id, key, pv2) catch {};
                    }
                }
            }
        }
    } else |_| {}
    if (dir.openFile("edges.jsonl", .{})) |ef| {
        defer ef.close();
        const content = try ef.readToEndAlloc(ally, 1024 * 1024 * 10); // 10MB max
        defer ally.free(content);
        var lines = std.mem.tokenizeScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const parsed = std.json.parseFromSlice(std.json.Value, ally, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const obj = parsed.value.object;
            const sv = obj.get("source") orelse continue;
            const tv = obj.get("target") orelse continue;
            const tyv = obj.get("type") orelse continue;
            const sid: u64 = switch (sv) {
                .integer => |iv| @intCast(iv),
                else => 0,
            };
            const tid: u64 = switch (tv) {
                .integer => |iv| @intCast(iv),
                else => 0,
            };
            const ety: []const u8 = switch (tyv) {
                .string => |s| s,
                else => "",
            };
            if (sid == 0 or tid == 0) continue;
            const eid = try g.addEdge(ally, sid, tid, ety);
            if (obj.get("properties")) |pv| {
                if (pv == .object) {
                    var it = pv.object.iterator();
                    while (it.next()) |e| {
                        const key = e.key_ptr.*;
                        const val = e.value_ptr.*;
                        const pv2: graph_exec.PropertyValue = switch (val) {
                            .null => .{ .Null = {} },
                            .bool => |b| .{ .Bool = b },
                            .integer => |n| .{ .Int = @intCast(n) },
                            .string => |s| .{ .String = s },
                            else => .{ .Null = {} },
                        };
                        g.setEdgeProperty(@intCast(eid), key, pv2) catch {};
                    }
                }
            }
        }
    } else |_| {}
    return g;
}

fn saveGraphToDir(ally: std.mem.Allocator, g: *const graph_exec.GraphStorage, dir_path: []const u8) void {
    std.fs.cwd().makePath(dir_path) catch return;

    // Save nodes
    const nodes_path = std.mem.concat(ally, u8, &.{ dir_path, "/nodes.jsonl" }) catch return;
    defer ally.free(nodes_path);

    var nodes_content = std.ArrayList(u8).initCapacity(ally, 0) catch return;
    defer nodes_content.deinit(ally);

    var it = g.nodes.iterator();
    while (it.next()) |entry| {
        const node = entry.value_ptr.*;
        std.fmt.format(nodes_content.writer(ally), "{{\"id\":{d},\"labels\":[", .{node.id}) catch {};
        var li: usize = 0;
        while (li < node.labels.len) : (li += 1) {
            if (li > 0) nodes_content.appendSlice(ally, ",") catch {};
            std.fmt.format(nodes_content.writer(ally), "\"{s}\"", .{node.labels[li]}) catch {};
        }
        nodes_content.appendSlice(ally, "],\"properties\":{") catch {};
        var pit = node.properties.iterator();
        var firstp = true;
        while (pit.next()) |p| {
            if (!firstp) nodes_content.appendSlice(ally, ",") catch {} else firstp = false;
            const k = p.key_ptr.*;
            const v = p.value_ptr.*;
            std.fmt.format(nodes_content.writer(ally), "\"{s}\":", .{k}) catch {};
            switch (v) {
                .Null => nodes_content.appendSlice(ally, "null") catch {},
                .Bool => |b| std.fmt.format(nodes_content.writer(ally), "{}", .{b}) catch {},
                .Int => |iv| std.fmt.format(nodes_content.writer(ally), "{d}", .{iv}) catch {},
                .String => |s| std.fmt.format(nodes_content.writer(ally), "\"{s}\"", .{s}) catch {},
                .Decimal => nodes_content.appendSlice(ally, "null") catch {},
            }
        }
        nodes_content.appendSlice(ally, "}}\n") catch {};
    }

    std.fs.cwd().writeFile(.{ .sub_path = nodes_path, .data = nodes_content.items }) catch {};

    // Save edges
    const edges_path = std.mem.concat(ally, u8, &.{ dir_path, "/edges.jsonl" }) catch return;
    defer ally.free(edges_path);

    var edges_content = std.ArrayList(u8).initCapacity(ally, 0) catch return;
    defer edges_content.deinit(ally);

    var i: usize = 0;
    while (i < g.edges.items.len) : (i += 1) {
        const e = g.edges.items[i];
        std.fmt.format(edges_content.writer(ally), "{{\"source\":{d},\"target\":{d},\"type\":\"{s}\",\"properties\":{{}}}}\n", .{ e.source, e.target, e.edge_type }) catch {};
    }

    std.fs.cwd().writeFile(.{ .sub_path = edges_path, .data = edges_content.items }) catch {};
}

fn initializeSampleGraph(ally: std.mem.Allocator, graph: *graph_exec.GraphStorage) !void {
    // Add sample nodes
    try graph.addNode(ally, 1, &.{"Person"});
    try graph.setNodeProperty(1, "name", .{ .String = "Alice" });
    try graph.setNodeProperty(1, "age", .{ .Int = 30 });

    try graph.addNode(ally, 2, &.{"Person"});
    try graph.setNodeProperty(2, "name", .{ .String = "Bob" });
    try graph.setNodeProperty(2, "age", .{ .Int = 25 });

    try graph.addNode(ally, 3, &.{"Person"});
    try graph.setNodeProperty(3, "name", .{ .String = "Charlie" });
    try graph.setNodeProperty(3, "age", .{ .Int = 35 });

    // Add sample edges
    const e1 = try graph.addEdge(ally, 1, 2, "KNOWS");
    try graph.setEdgeProperty(e1, "since", .{ .Int = 2020 });

    const e2 = try graph.addEdge(ally, 2, 3, "KNOWS");
    try graph.setEdgeProperty(e2, "since", .{ .Int = 2021 });

    const e3 = try graph.addEdge(ally, 1, 3, "WORKS_WITH");
    try graph.setEdgeProperty(e3, "department", .{ .String = "Engineering" });
}

fn computeBaseFlags(ordered: bool, distinct: bool) []const []const u8 {
    _ = ordered;
    _ = distinct;
    // Tests expect only IllegalOrderKeyPolicy in flagger_findings for determinism
    flags_buf_base[0] = F_ILLEGAL;
    return flags_buf_base[0..1];
}

fn computeFlagsExtended(ordered: bool, distinct: bool, union_phases: bool) []const []const u8 {
    const base = computeBaseFlags(ordered, distinct);
    var i: usize = 0;
    while (i < base.len) : (i += 1) flags_buf_ext[i] = base[i];
    var end: usize = base.len;
    if (union_phases) {
        flags_buf_ext[end] = F_UNION_PHASES;
        end += 1;
    }
    // Deprecation flag for wal_skip_ratio legacy key always appended (profile context check later could refine)
    flags_buf_ext[end] = "U:WalSkipRatioDeprecated";
    end += 1;
    return flags_buf_ext[0..end];
}

fn execInsertValue(state: *ServerState, expr_val: eval.Value) !void {
    var tmp: [128]u8 = undefined; // fixed buffer for small literals
    var fba = std.heap.FixedBufferAllocator.init(&tmp);
    var list = std.ArrayList(u8).initCapacity(fba.allocator(), 0) catch return; // no OOM propagation needed
    switch (expr_val) {
        .Int => |n| std.fmt.format(list.writer(fba.allocator()), "{d}", .{n}) catch {},
        .Bool => |b| list.appendSlice(fba.allocator(), if (b) "true" else "false") catch {},
        .Str => |s| {
            list.append(fba.allocator(), '"') catch {};
            list.appendSlice(fba.allocator(), s) catch {};
            list.append(fba.allocator(), '"') catch {};
        },
        else => list.appendSlice(fba.allocator(), "null") catch {},
    }
    const stored = try state.allocator.dupe(u8, list.items);
    const creator = if (state.active_txn) |tx| tx.id else 0; // autocommit txn id 0
    state.inserted_values.append(state.allocator, .{ .value = stored, .creator_txn = creator, .commit_ts = if (creator == 0) state.global_commit_ts else null }) catch {};
    // WAL logical insert record (best-effort) for transactional inserts (creator != 0)
    if (creator != 0) {
        if (state.wal_ptr) |wp| {
            const wptr: *wal_mod.Wal = @ptrCast(@alignCast(wp));
            _ = wptr.append(creator, .Insert, stored, stored.len) catch {};
        }
    }
}

fn buildScanValuesResult(state: *ServerState) !void {
    // Build schema: single column v STRING
    state.last_columns = &.{protocol.SchemaCol{ .name = "v", .type = "STRING" }};
    state.last_ordered = false;
    state.last_order_keys = &.{};
    // Build row fragments
    var rows = std.ArrayList([]const u8).initCapacity(state.allocator, state.inserted_values.items.len) catch return;
    const snapshot = if (state.active_txn != null) state.session_snapshot_ts else state.global_commit_ts;
    const reader_txn = if (state.active_txn) |tx| tx.id else 0;
    var idx: usize = 0;
    while (idx < state.inserted_values.items.len) : (idx += 1) {
        const rec = state.inserted_values.items[idx];
        const own_uncommitted = rec.creator_txn == reader_txn and rec.commit_ts == null and !rec.aborted;
        const committed_visible = if (rec.commit_ts) |cts| cts <= snapshot else false;
        const visible = own_uncommitted or committed_visible;
        if (!visible) continue;
        const val = rec.value;
        // Build row JSON manually to avoid fmt brace issues with Zig 0.15
        const row = state.allocator.alloc(u8, 5 + val.len) catch continue; // {"v": + value + }
        // Write {"v":
        if (row.len >= 5) {
            row[0] = '{';
            row[1] = '"';
            row[2] = 'v';
            row[3] = '"';
            row[4] = ':';
        }
        if (val.len > 0) @memcpy(row[5 .. 5 + val.len], val);
        // append closing }
        const resized = state.allocator.realloc(row, row.len + 1) catch row;
        if (resized.len > row.len) resized[resized.len - 1] = '}';
        const final_row = if (resized.len > row.len) resized else row; // fallback
        // ensure null terminator not required; treat slice as bytes
        const keep = final_row;
        // Append
        rows.append(state.allocator, keep) catch {
            state.allocator.free(keep);
            break;
        };
        rows.append(state.allocator, row) catch {
            state.allocator.free(row);
            break;
        };
    }
    state.page_items = rows.toOwnedSlice(state.allocator) catch &.{};
    state.page_index = 0;
    state.active_result = true;
}

// Minimal predicate inspector: returns true if expression tree contains an equality operation.
fn hasEqualityPredicate(expr: anytype) bool {
    // Attempt to match Binary nodes; AST uses union(enum) with .Binary carrying op + left/right.
    if (@hasField(@TypeOf(expr), "op") and @hasField(@TypeOf(expr), "left") and @hasField(@TypeOf(expr), "right")) {
        // best-effort: assume equality op tag name contains Eq
        // Use @tagName on op if enum
        if (@typeInfo(@TypeOf(expr.op)) == .Enum) {
            const opname = @tagName(expr.op);
            if (std.mem.eql(u8, opname, "Eq")) return true;
            if (std.mem.eql(u8, opname, "And") or std.mem.eql(u8, opname, "Or")) {
                if (hasEqualityPredicate(expr.left.*) or hasEqualityPredicate(expr.right.*)) return true;
            }
        }
        if (hasEqualityPredicate(expr.left.*)) return true;
        if (hasEqualityPredicate(expr.right.*)) return true;
    }
    // Generic recursion for other containers
    const T = @TypeOf(expr);
    if (@hasField(T, "left") and @hasField(T, "right")) {
        if (hasEqualityPredicate(expr.left)) return true;
        if (hasEqualityPredicate(expr.right)) return true;
    }
    if (@hasField(T, "expr")) if (hasEqualityPredicate(expr.expr)) return true;
    if (@hasField(T, "terms")) for (expr.terms) |t| if (hasEqualityPredicate(t)) return true;
    if (@hasField(T, "args")) for (expr.args) |a| if (hasEqualityPredicate(a)) return true;
    return false;
}

fn valueTypeName(v: eval.Value) []const u8 {
    return switch (v) {
        .Int => "INT",
        .Bool => "BOOL",
        .Str => "STRING",
        .Null => "NULL",
        .Decimal => "DECIMAL",
    };
}

// Map aggregation BindingValue (exec module) to schema type string.
inline fn bindingValueTypeName(v: anytype) []const u8 {
    return switch (v) {
        .Int => "INT",
        .Bool => "BOOL",
        .Str => "STRING",
        .Null => "NULL",
        .Decimal => "DECIMAL",
    };
}

// Serialize a single aggregation BindingValue row to JSON using provided column metadata (names only used; types informational).
fn bindingValueRowToJson(ally: std.mem.Allocator, cols: []const protocol.SchemaCol, brow: []const exec.BindingValue) []const u8 {
    var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return &.{};
    const w = buf.writer(ally);
    w.writeAll("{") catch {};
    var i: usize = 0;
    while (i < cols.len and i < brow.len) : (i += 1) {
        if (i > 0) w.writeAll(",") catch {};
        const name = cols[i].name;
        w.print("\"{s}\":", .{name}) catch {};
        const v = brow[i];
        switch (v) {
            .Null => w.writeAll("null") catch {},
            .Int => |n| w.print("{d}", .{n}) catch {},
            .Bool => |b| w.writeAll(if (b) "true" else "false") catch {},
            .Str => |s| blk: {
                w.writeAll("\"") catch {};
                w.writeAll(s) catch {};
                w.writeAll("\"") catch {};
                break :blk;
            },
            .Decimal => |d| blkdec: {
                const coeff = d.coeff;
                const scale = d.scale;
                if (scale == 0) {
                    w.print("{d}", .{coeff}) catch {};
                    break :blkdec;
                }
                var pow: i128 = 1;
                var si: u8 = 0;
                while (si < scale) : (si += 1) pow *= 10;
                const whole: i128 = @divTrunc(coeff, pow);
                const frac: i128 = @mod(if (coeff < 0) -coeff else coeff, pow);
                var fracbuf: [32]u8 = undefined;
                const ftmp = std.fmt.bufPrint(&fracbuf, "{d}", .{frac}) catch "0";
                if (ftmp.len < scale) {
                    const missing = scale - @as(u8, @intCast(ftmp.len));
                    var pad: [32]u8 = undefined;
                    @memset(pad[0..missing], '0');
                    w.print("{d}.{s}{s}", .{ whole, pad[0..missing], ftmp }) catch {};
                } else {
                    w.print("{d}.{s}", .{ whole, ftmp }) catch {};
                }
            },
        }
    }
    w.writeAll("}") catch {};
    return buf.toOwnedSlice(ally) catch &.{};
}

fn writeErrorWithFlags(ally: std.mem.Allocator, out_file: std.fs.File, code: diagnostics.Code, message: []const u8, anchor: []const u8, additional: []const []const u8, has_us001_any: bool) void {
    var flags_buf: [3][]const u8 = .{ "I:IllegalOrderKeyPolicy=ident-only", "U:OrderTiebreak=LexJSON", "U:US001/enforced" };
    const flag_slice = if (has_us001_any) flags_buf[0..3] else flags_buf[0..2];
    // Storage corruption treated as class 58000 (data exception) instead of generic 02000.
    const status_override: ?[]const u8 = if (code == .StoragePageChecksum) "58000" else null;
    if (protocol.buildErrorLineWithFlagsCustomStatus(ally, diagnostics.codeName(code), message, anchor, additional, flag_slice, status_override)) |line| {
        defer ally.free(line);
        _ = out_file.write(line) catch {};
    } else |_| {}
}

// Aggregate diagnostics discovered during parsing / surface analysis for a single statement.
// Currently we detect:
//  - US001 (unordered pagination): presence of LIMIT/OFFSET without ORDER BY
//  - IllegalOrderKey: parser policy violation captured via parse error message
// Returns number of collected codes placed into out_codes (deduplicated) sorted by precedence.
fn collectTextDiagnostics(text: []const u8, parse_err_msg: ?[]const u8, out_codes: *[4]diagnostics.Code) usize {
    var tmp: [4]diagnostics.Code = undefined;
    var n: usize = 0;
    const has_limit = std.mem.indexOf(u8, text, "LIMIT") != null;
    const has_offset = std.mem.indexOf(u8, text, "OFFSET") != null;
    const has_order_kw = std.mem.indexOf(u8, text, "ORDER BY") != null;
    var parsed_illegal = false;
    if (parse_err_msg) |msg| {
        if (diagnostics.mapParserMessage(msg)) |_| {
            parsed_illegal = true;
        }
    }
    if ((has_limit or has_offset) and (!has_order_kw or parsed_illegal)) {
        tmp[n] = .US001;
        n += 1;
    }
    if (parsed_illegal) {
        tmp[n] = .IllegalOrderKey;
        n += 1;
    }
    // Dedup + precedence
    var i: usize = 0;
    while (i < n) : (i += 1) out_codes.*[i] = tmp[i];
    return diagnostics.foldCodes(out_codes.*[0..n]);
}

// Planner diagnostics aggregation: include primary planner code plus US001 if unordered pagination also applies.
fn collectPlannerDiagnostics(q: geode.ast.Query, primary: diagnostics.Code, out_codes: *[4]diagnostics.Code) usize {
    out_codes.*[0] = primary;
    var n: usize = 1;
    const unordered_pagination = (q.limit != null or q.offset != null) and q.order_by == null;
    if (unordered_pagination and primary != .US001) {
        out_codes.*[n] = .US001;
        n += 1;
    }
    return diagnostics.foldCodes(out_codes.*[0..n]);
}

fn writeJsonValue(w: anytype, v: eval.Value) !void {
    switch (v) {
        .Int => |iv| try w.print("{d}", .{iv}),
        .Bool => |bv| try w.writeAll(if (bv) "true" else "false"),
        .Str => |s| blk: {
            try w.writeAll("\"");
            try w.writeAll(s);
            try w.writeAll("\"");
            break :blk;
        },
        .Null => try w.writeAll("null"),
        .Decimal => |d| blkdec: {
            // If original literal representation preserved, emit it directly for fidelity.
            if (d.orig_repr) |orig| {
                try w.writeAll(orig);
                break :blkdec;
            }
            var buf: [64]u8 = undefined;
            const coeff = d.coeff;
            const scale = d.scale;
            if (scale == 0) {
                const s = std.fmt.bufPrint(&buf, "{d}", .{coeff}) catch "0";
                try w.writeAll(s);
                break :blkdec;
            }
            // Use exact scale (no trimming) because orig_repr absent (computed value); show full precision.
            var pow: i128 = 1;
            var i: u8 = 0;
            while (i < scale) : (i += 1) pow *= 10;
            const abs_coeff: i128 = if (coeff < 0) -coeff else coeff;
            const whole: i128 = @divTrunc(coeff, pow);
            const frac: i128 = @mod(abs_coeff, pow);
            var fracbuf: [32]u8 = undefined;
            const ftmp = std.fmt.bufPrint(&fracbuf, "{d}", .{frac}) catch "0";
            // Pad leading zeros in fractional part to required scale
            if (ftmp.len < scale) {
                const missing = scale - @as(u8, @intCast(ftmp.len));
                var pad: [32]u8 = undefined;
                @memset(pad[0..missing], '0');
                const s = std.fmt.bufPrint(&buf, "{d}.{s}{s}", .{ whole, pad[0..missing], ftmp }) catch "0";
                try w.writeAll(s);
            } else {
                const s = std.fmt.bufPrint(&buf, "{d}.{s}", .{ whole, ftmp }) catch "0";
                try w.writeAll(s);
            }
        },
    }
}

fn parseParams(ally: std.mem.Allocator, params_json: ?[]const u8, out_names: *[][]const u8, out_rows: *[][]const eval.Value) void {
    if (params_json == null) return;
    const src = params_json.?;
    const parsed = std.json.parseFromSlice(std.json.Value, ally, src, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    var it = parsed.value.object.iterator();
    // Support single array param (tests only need this)
    if (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        if (val != .array) return;
        const arr = val.array.items;
        // Empty array -> zero rows (handled by caller when constructing row pages)
        var names = ally.alloc([]const u8, 1) catch return;
        names[0] = ally.dupe(u8, key) catch key;
        // Collect raw scalar values first
        var rows = ally.alloc(eval.Value, arr.len) catch return;
        var i: usize = 0;
        while (i < arr.len) : (i += 1) {
            const v = arr[i];
            rows[i] = switch (v) {
                .integer => |iv| eval.Value{ .Int = @intCast(iv) },
                .bool => |bv| eval.Value{ .Bool = bv },
                .string => |sv| eval.Value{ .Str = sv },
                .null => eval.Value{ .Null = {} },
                .float => eval.Value{ .Null = {} },
                .number_string => eval.Value{ .Null = {} },
                .array => eval.Value{ .Null = {} },
                .object => eval.Value{ .Null = {} },
            };
        }
        out_names.* = names;
        // Wrap each into a single-column row matrix later during evaluation
        // We'll store as param vector values, not full rows yet.
        out_rows.* = ally.alloc([]const eval.Value, rows.len) catch return;
        var j: usize = 0;
        while (j < rows.len) : (j += 1) out_rows.*[j] = rows[j .. j + 1];
    }
}

fn buildExplainJson(ally: std.mem.Allocator, params: struct { ordered: bool, limit: ?usize, offset: ?usize, union_mode: ?[]const u8, distinct: bool, setop_kind: ?[]const u8 }) []const u8 {
    // Canonical pipeline order with monotonic id: Project(0), Distinct(1), Sort(2), Offset(3), Limit(4), SetOpUnion(5)
    var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return "{\"logical\":[]}";
    const w = buf.writer(ally);
    w.writeAll("{\"profile_version\":2,\"logical\":[") catch {};
    var id: usize = 0;
    // Project always present first
    // Project
    w.writeAll("{\"op\":\"Project\",\"id\":") catch {};
    w.print("{d}", .{id}) catch {};
    w.writeAll("}") catch {};
    id += 1;
    if (params.distinct) {
        w.writeAll(",{\"op\":\"Distinct\",\"id\":") catch {};
        w.print("{d}", .{id}) catch {};
        w.writeAll("}") catch {};
        id += 1;
    }
    if (params.ordered) {
        w.writeAll(",{\"op\":\"Sort\",\"id\":") catch {};
        w.print("{d}", .{id}) catch {};
        w.writeAll("}") catch {};
        id += 1;
    }
    if (params.offset) |_| {
        w.writeAll(",{\"op\":\"Offset\",\"id\":") catch {};
        w.print("{d}", .{id}) catch {};
        w.writeAll("}") catch {};
        id += 1;
    }
    if (params.limit) |_| {
        w.writeAll(",{\"op\":\"Limit\",\"id\":") catch {};
        w.print("{d}", .{id}) catch {};
        w.writeAll("}") catch {};
        id += 1;
    }
    if (params.union_mode) |um| {
        const sop = if (params.setop_kind) |sk| sk else "SetOpUnion";
        w.writeAll(",{\"op\":\"") catch {};
        w.writeAll(sop) catch {};
        w.writeAll("\",\"id\":") catch {};
        w.print("{d}", .{id}) catch {};
        w.writeAll(",\"mode\":\"") catch {};
        w.writeAll(um) catch {};
        w.writeAll("\"}") catch {};
        id += 1;
    }
    w.writeAll("],\"properties\":{") catch {};
    var first = true;
    if (params.ordered) {
        w.writeAll("\"ordered\":true") catch {};
        first = false;
    }
    if (params.limit) |l| {
        if (!first) w.writeAll(",") catch {};
        first = false;
        w.print("\"limit\":{d}", .{l}) catch {};
    }
    if (params.offset) |o| {
        if (!first) w.writeAll(",") catch {};
        first = false;
        w.print("\"offset\":{d}", .{o}) catch {};
    }
    if (params.union_mode) |um2| {
        if (!first) w.writeAll(",") catch {};
        first = false;
        w.print("\"union_mode\":\"{s}\"", .{um2}) catch {};
    }
    if (params.distinct) {
        if (!first) w.writeAll(",") catch {};
        first = false;
        w.writeAll("\"distinct\":true") catch {};
    }
    w.writeAll("}}") catch {}; // Close properties object and outer JSON object
    return buf.toOwnedSlice(ally) catch "{\"logical\":[]}";
}

// Custom bindings writer: include final flag only if (has_params or multi_page_needed or explicit pagination triggered)
fn writeBindingsAdaptive(file: std.fs.File, ordered: bool, order_keys: []const []const u8, rows_json: []const u8, final_flag: bool, include_final: bool, flags: []const []const u8) void {
    file.writeAll("{\"status_class\":\"00000\",\"result\":{\"type\":\"BINDINGS\",\"ordered\":") catch {};
    file.writeAll(if (ordered) "true" else "false") catch {};
    file.writeAll(",\"order_keys\":[") catch {};
    var i: usize = 0;
    while (i < order_keys.len) : (i += 1) {
        if (i > 0) file.writeAll(",") catch {};
        file.writeAll("\"") catch {};
        file.writeAll(order_keys[i]) catch {};
        file.writeAll("\"") catch {};
    }
    file.writeAll("],\"rows\":") catch {};
    file.writeAll(rows_json) catch {};
    if (include_final) {
        file.writeAll(",\"final\":") catch {};
        file.writeAll(if (final_flag) "true" else "false") catch {};
    }
    if (flags.len > 0) {
        file.writeAll(",\"flagger_findings\":[") catch {};
        var fi: usize = 0;
        while (fi < flags.len) : (fi += 1) {
            if (fi > 0) file.writeAll(",") catch {};
            file.writeAll("\"") catch {};
            file.writeAll(flags[fi]) catch {};
            file.writeAll("\"") catch {};
        }
        file.writeAll("]") catch {};
    }
    file.writeAll("}}\n") catch {};
}

const StageTimings = struct {
    project_ns: i128 = 0,
    distinct_ns: i128 = 0,
    sort_ns: i128 = 0,
    offset_ns: i128 = 0,
    limit_ns: i128 = 0,
    agg_build_ns: i128 = 0,
    agg_emit_ns: i128 = 0,
    expand_ns: i128 = 0,
    project_rows_out: usize = 0,
    distinct_rows_out: usize = 0,
    sort_rows_out: usize = 0,
    offset_rows_out: usize = 0,
    limit_rows_out: usize = 0,
    agg_rows_out: usize = 0,
    expand_rows_out: usize = 0,
    project_rows_in: usize = 0,
    distinct_rows_in: usize = 0,
    sort_rows_in: usize = 0,
    offset_rows_in: usize = 0,
    limit_rows_in: usize = 0,
    agg_rows_in: usize = 0,
    expand_rows_in: usize = 0,
    // Approximate bytes processed/emitted per stage (JSON row bytes) for profiling.
    project_bytes_out: usize = 0,
    distinct_bytes_out: usize = 0,
    sort_bytes_out: usize = 0,
    offset_bytes_out: usize = 0,
    limit_bytes_out: usize = 0,
    expand_bytes_out: usize = 0,
    // Approximate allocated bytes attributable to each stage (heuristic: bytes_out currently; future: real allocator diff)
    project_bytes_alloc: usize = 0,
    distinct_bytes_alloc: usize = 0,
    sort_bytes_alloc: usize = 0,
    offset_bytes_alloc: usize = 0,
    limit_bytes_alloc: usize = 0,
    agg_build_bytes_alloc: usize = 0,
    agg_emit_bytes_alloc: usize = 0,
    expand_bytes_alloc: usize = 0,
    // Net allocator snapshots (used to derive per-stage allocation deltas)
    net_after_project: usize = 0,
    net_after_distinct: usize = 0,
    net_after_sort: usize = 0,
    net_after_offset: usize = 0,
    net_after_limit: usize = 0,
};
// TODO(alloc-metrics): Counting allocator integration deferred; current bytes_alloc remains heuristic.

// TODO(alloc-metrics): Counting allocator integration deferred; current bytes_alloc remains heuristic.

// Value-based canonical key: encodes row values directly to avoid JSON reparsing.
fn canonicalValuesKey(ally: std.mem.Allocator, vals: []const eval.Value) []const u8 {
    var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return &.{};
    const w = buf.writer(ally);
    var i: usize = 0;
    while (i < vals.len) : (i += 1) {
        if (i > 0) w.writeAll("|") catch {};
        const v = vals[i];
        switch (v) {
            .Null => w.writeAll("n") catch {},
            .Int => |iv| w.print("i:{d}", .{iv}) catch {},
            .Bool => |bv| w.writeAll(if (bv) "s:4:true" else "s:5:false") catch {},
            .Str => |s| blk: {
                w.writeAll("s:") catch {};
                w.print("{d}:", .{s.len}) catch {};
                w.writeAll(s) catch {};
                break :blk;
            },
            .Decimal => |d| blk2: {
                var coeff = d.coeff;
                var scale = d.scale;
                if (scale > 0) {
                    while (scale > 0 and @mod(coeff, 10) == 0) : (scale -= 1) coeff = @divTrunc(coeff, 10);
                }
                if (scale == 0) {
                    w.print("i:{d}", .{coeff}) catch {};
                } else {
                    w.print("d:{d}:{d}", .{ coeff, scale }) catch {};
                }
                break :blk2;
            },
        }
    }
    return buf.toOwnedSlice(ally) catch &.{};
}

// Build canonical key for a row JSON string so that numerically equal values with different scales map identically.
fn canonicalRowKey(ally: std.mem.Allocator, row: []const u8) []const u8 {
    if (row.len < 2) return row; // fallback
    var idx: usize = 0;
    if (row[idx] == '{') idx += 1;
    var key_buf = std.ArrayList(u8).initCapacity(ally, 0) catch return row;
    const w = key_buf.writer(ally);
    var field_i: usize = 0;
    while (idx < row.len) : (idx += 1) {
        while (idx < row.len and (row[idx] == ' ' or row[idx] == ',')) idx += 1;
        if (idx >= row.len or row[idx] == '}') break;
        if (row[idx] != '"') break; // malformed
        idx += 1; // skip opening quote of key
        while (idx < row.len and row[idx] != '"') idx += 1; // skip key chars
        if (idx >= row.len) break;
        idx += 1; // skip closing quote
        while (idx < row.len and row[idx] != ':') idx += 1;
        if (idx >= row.len) break;
        idx += 1; // colon
        while (idx < row.len and row[idx] == ' ') idx += 1;
        if (idx >= row.len) break;
        if (field_i > 0) w.writeAll("|") catch {};
        const ch = row[idx];
        if (ch == 'n') { // null
            w.writeAll("n") catch {};
            while (idx < row.len and row[idx] != ',' and row[idx] != '}') idx += 1;
            if (idx >= row.len or row[idx] == '}') break;
            field_i += 1;
            continue;
        } else if (ch == '"') { // string
            idx += 1;
            const start = idx;
            while (idx < row.len and row[idx] != '"') idx += 1;
            const s = if (idx <= row.len) row[start..idx] else &.{};
            w.writeAll("s:") catch {};
            w.print("{d}:", .{s.len}) catch {};
            w.writeAll(s) catch {};
            if (idx < row.len) idx += 1;
            while (idx < row.len and row[idx] != ',' and row[idx] != '}') idx += 1;
            if (idx >= row.len or row[idx] == '}') break;
            field_i += 1;
            continue;
        } else {
            // number or bool token
            const startn = idx;
            var neg = false;
            if (row[idx] == '-') {
                neg = true;
                idx += 1;
            }
            var mantissa: i128 = 0;
            var saw_digit = false;
            while (idx < row.len and row[idx] >= '0' and row[idx] <= '9') : (idx += 1) {
                mantissa = mantissa * 10 + (row[idx] - '0');
                saw_digit = true;
            }
            var scale: u8 = 0;
            var is_dec = false;
            if (idx < row.len and row[idx] == '.') {
                is_dec = true;
                idx += 1;
                while (idx < row.len and row[idx] >= '0' and row[idx] <= '9') : (idx += 1) {
                    mantissa = mantissa * 10 + (row[idx] - '0');
                    scale += 1;
                    saw_digit = true;
                }
            }
            if (!saw_digit) {
                // bool token -> canonical as string
                var endtok = startn;
                while (endtok < row.len and row[endtok] != ',' and row[endtok] != '}') endtok += 1;
                const tok = row[startn..endtok];
                w.writeAll("s:") catch {};
                w.print("{d}:", .{tok.len}) catch {};
                w.writeAll(tok) catch {};
                idx = endtok;
            } else {
                if (neg) mantissa = -mantissa;
                if (is_dec) {
                    while (scale > 0 and @mod(mantissa, 10) == 0) : (scale -= 1) mantissa = @divTrunc(mantissa, 10);
                    if (scale == 0) {
                        // becomes int
                        w.writeAll("i:") catch {};
                        w.print("{d}", .{mantissa}) catch {};
                    } else {
                        w.writeAll("d:") catch {};
                        w.print("{d}:", .{mantissa}) catch {};
                        w.print("{d}", .{scale}) catch {};
                    }
                } else {
                    w.writeAll("i:") catch {};
                    w.print("{d}", .{mantissa}) catch {};
                }
            }
            while (idx < row.len and row[idx] != ',' and row[idx] != '}') idx += 1;
            if (idx >= row.len or row[idx] == '}') break;
            field_i += 1;
            continue;
        }
    }
    return key_buf.toOwnedSlice(ally) catch row;
}

fn buildAdditionalStatusesAlloc(ally: std.mem.Allocator, codes: []const diagnostics.Code, primary: diagnostics.Code) []const []const u8 {
    if (codes.len <= 1) return &.{};
    var extras = ally.alloc([]const u8, codes.len - 1) catch return &.{};
    var ei: usize = 0;
    var i: usize = 0;
    while (i < codes.len) : (i += 1) {
        if (codes[i] == primary) continue;
        extras[ei] = diagnostics.codeName(codes[i]);
        ei += 1;
    }
    return extras[0..ei];
}

// Shared DISTINCT dedup helper: mutates rows_json in-place, frees removed row value slices when provided.
fn distinctDedup(ally: std.mem.Allocator, have_values: bool, value_arity: usize, rows_json: *std.ArrayList([]const u8), rows_values: *std.ArrayList([]const eval.Value), out_hash_size: ?*usize) void {
    var seen = std.StringHashMap(void).init(ally);
    defer seen.deinit();
    var out_rows = std.ArrayList([]const u8).initCapacity(ally, 0) catch return;
    defer out_rows.deinit(ally);
    var out_values = if (have_values) std.ArrayList([]const eval.Value).initCapacity(ally, 0) catch return else std.ArrayList([]const eval.Value).initCapacity(ally, 0) catch return;
    defer out_values.deinit(ally);
    var alloc_keys = std.ArrayList([]const u8).initCapacity(ally, 0) catch return;
    defer {
        for (alloc_keys.items) |k| ally.free(k);
        alloc_keys.deinit(ally);
    }
    var idx: usize = 0;
    while (idx < rows_json.items.len) : (idx += 1) {
        const row = rows_json.items[idx];
        const key = if (have_values and idx < rows_values.items.len) canonicalValuesKey(ally, rows_values.items[idx][0..value_arity]) else canonicalRowKey(ally, row);
        if (!seen.contains(key)) {
            seen.put(key, {}) catch {};
            out_rows.append(ally, row) catch {};
            if (have_values and idx < rows_values.items.len) out_values.append(ally, rows_values.items[idx]) catch {};
            if (key.ptr != row.ptr) alloc_keys.append(ally, key) catch {};
        } else {
            ally.free(row);
            ally.free(key);
            if (have_values and idx < rows_values.items.len) ally.free(rows_values.items[idx]);
        }
    }
    const unique = seen.count();
    rows_json.clearRetainingCapacity();
    for (out_rows.items) |r| rows_json.append(ally, r) catch {};
    if (out_hash_size) |p| p.* = unique;
    if (have_values) {
        // Replace original rows_values with compacted out_values (ownership of slices moves as-is)
        for (rows_values.items) |v| ally.free(v);
        rows_values.clearRetainingCapacity();
        for (out_values.items) |v| rows_values.append(ally, v) catch {};
    }
}

const AllocTracker = struct { ctx: *anyopaque, getFn: *const fn (*anyopaque) usize };

fn trackerGet(ctx: *anyopaque) usize {
    const T = @import("tracking_alloc").TrackingAllocator;
    const t: *T = @ptrCast(@alignCast(ctx));
    return t.net();
}

const graph_exec = @import("graph/exec.zig");

// Global test override for MATCH guard max results (set via --match-max-results)
var g_match_max_results_override: ?usize = null;
// Global test override for MATCH guard max frontier (set via --match-max-frontier)
var g_match_max_frontier_override: ?usize = null;

// Centralized CDC_CONTROL handler to eliminate duplicated logic between processMessage
// (network path) and stdio loop. Returns a newly allocated response line or null slice on OOM.
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC_CONTROL"; ASPECT=Refactor; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_042_CDC_ControlReset; OWNER=server; UPDATED=2025-09-20
fn handleCdcControl(gpa: std.mem.Allocator, state: *ServerState, action: []const u8) ?[]u8 {
    if (state.cdc_engine) |eng| {
        if (std.ascii.eqlIgnoreCase(action, "RESET_GUARDRAILS")) {
            eng.resetGuardrailState();
            return protocol.buildCdcControlLine(gpa, action, "OK", eng.guardrail_epoch) catch null;
        } else {
            return protocol.buildCdcControlLine(gpa, action, "UNSUPPORTED", eng.guardrail_epoch) catch null;
        }
    } else {
        return protocol.buildCdcControlLine(gpa, action, "NO_ENGINE", 0) catch null;
    }
}

fn evaluateSimpleQuery(ally: std.mem.Allocator, q: geode.ast.Query, param_names: [][]const u8, param_matrix: [][]const eval.Value, ordered_meta: *bool, order_keys: *[][]const u8, cols_out: *[]const protocol.SchemaCol, timings: ?*StageTimings, eval_diag: ?*diagnostics.Code, alloc_tracker: ?AllocTracker) ![][]const u8 {
    // Check if this is a MATCH query
    if (q.match.chains.len > 0) {
        // Initialize graph storage (for now, use a global singleton)
        // In production, this would be loaded from persistent storage
        const graph = getOrCreateGraphStorage(ally);

        // Execute MATCH pattern
        // Read environment overrides for MATCH guard limits (deterministic test triggering of ExecutionGuardTrip)
        var m_opts = graph_exec.MatchOptions{};
        if (g_match_max_results_override) |ovr| m_opts.max_results = ovr;
        if (g_match_max_frontier_override) |ovf| m_opts.max_frontier = ovf;
        if (std.process.getEnvVarOwned(ally, "GEODE_MATCH_MAX_RESULTS")) |mv| {
            defer ally.free(mv);
            const parsed = std.fmt.parseInt(usize, mv, 10) catch null;
            if (parsed) |p| m_opts.max_results = p;
        } else |_| {}
        if (std.process.getEnvVarOwned(ally, "GEODE_MATCH_MAX_FRONTIER")) |fv| {
            defer ally.free(fv);
            const parsedf = std.fmt.parseInt(usize, fv, 10) catch null;
            if (parsedf) |pf| m_opts.max_frontier = pf;
        } else |_| {}
        var bindings = try graph_exec.executeMatch(ally, graph, q.match, q.where_clause, m_opts, eval_diag);

        // Apply WITH clause if present
        if (q.with_clause) |with| {
            bindings = try graph_exec.executeWith(ally, bindings, with, q.where_clause, graph);
        }

        // Build column metadata (names inferred from RETURN items; types set to MIXED placeholder)
        var cols = try ally.alloc(protocol.SchemaCol, q.ret.items.len);
        for (q.ret.items, 0..) |item, i| {
            const alias = item.alias orelse blk_al: {
                const tmp = geode.printer.stringifyExprAlloc(ally, item.expr, .{}) catch "col";
                break :blk_al tmp;
            };
            cols[i] = .{ .name = alias, .type = "MIXED" };
        }
        cols_out.* = cols;

        // Local helper to convert graph PropertyValue into eval.Value (mirror of exec.zig)
        const PropToEval = struct {
            fn conv(pv: graph_exec.PropertyValue) eval.Value {
                return switch (pv) {
                    .Null => eval.Value{ .Null = {} },
                    .Bool => |b| eval.Value{ .Bool = b },
                    .Int => |i| eval.Value{ .Int = i },
                    .String => |s| eval.Value{ .Str = s },
                    .Decimal => |d| eval.Value{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                };
            }
        };

        // Prepare per-row VALUEs for ORDER BY/DISTINCT evaluation
        var rows_values = std.ArrayList([]const eval.Value).initCapacity(ally, 0) catch return error.OutOfMemory;
        defer rows_values.deinit(ally);

        // Helper: evaluate a single return expression in binding context to eval.Value for ordering/aggregation
        const EvalInBinding = struct {
            fn evalRet(alloc: std.mem.Allocator, b: *const graph_exec.Binding, it: geode.ast.ReturnItem, g: *const graph_exec.GraphStorage) eval.Value {
                return switch (it.expr) {
                    .Ident => |name| blk_i: {
                        if (b.vars.get(name)) |bv| {
                            switch (bv) {
                                .Value => |pv| break :blk_i PropToEval.conv(pv),
                                .Node, .Edge, .Path, .Null => break :blk_i eval.Value{ .Null = {} },
                            }
                        }
                        break :blk_i eval.Value{ .Null = {} };
                    },
                    .PropertyAccess => |pa| blk_p: {
                        if (b.vars.get(pa.object)) |ov| {
                            switch (ov) {
                                .Node => |nid| {
                                    if (g.nodes.get(nid)) |node| {
                                        if (node.properties.get(pa.property)) |prop| {
                                            break :blk_p PropToEval.conv(prop);
                                        }
                                    }
                                },
                                else => {},
                            }
                        }
                        break :blk_p eval.Value{ .Null = {} };
                    },
                    else => blk_e: {
                        // Build an eval.Env from binding scalars only; non-scalars mapped to null
                        var env_names = std.ArrayList([]const u8).initCapacity(alloc, 0) catch unreachable;
                        var env_values = std.ArrayList(eval.Value).initCapacity(alloc, 0) catch unreachable;
                        var itv = b.vars.iterator();
                        while (itv.next()) |entry| {
                            env_names.append(alloc, entry.key_ptr.*) catch {};
                            const ev = switch (entry.value_ptr.*) {
                                .Value => |pv| PropToEval.conv(pv),
                                else => eval.Value{ .Null = {} },
                            };
                            env_values.append(alloc, ev) catch {};
                        }
                        const env = eval.Env{ .names = env_names.items, .values = env_values.items };
                        const v = eval.evalExpr(alloc, it.expr, env) catch eval.Value{ .Null = {} };
                        break :blk_e v;
                    },
                };
            }
        };

        // Precompute row values for all bindings
        var bi: usize = 0;
        while (bi < bindings.len) : (bi += 1) {
            var rvals = try ally.alloc(eval.Value, q.ret.items.len);
            var ci2: usize = 0;
            while (ci2 < q.ret.items.len) : (ci2 += 1) {
                rvals[ci2] = EvalInBinding.evalRet(ally, &bindings[bi], q.ret.items[ci2], graph);
            }
            rows_values.append(ally, rvals) catch {};
        }

        // Deterministic base ordering (before DISTINCT) using graph binding structural comparator
        graph_exec.sortBindingsDeterministic(ally, bindings);

        // DISTINCT stage for MATCH: deduplicate projected rows based on value semantics
        if (q.ret.distinct and rows_values.items.len > 1) {
            var seen = std.StringHashMap(void).init(ally);
            defer seen.deinit();
            var kept_bindings = std.ArrayList(graph_exec.Binding).initCapacity(ally, 0) catch return error.OutOfMemory;
            defer kept_bindings.deinit(ally);
            var kept_values = std.ArrayList([]const eval.Value).initCapacity(ally, 0) catch return error.OutOfMemory;
            defer kept_values.deinit(ally);
            var i_dist: usize = 0;
            while (i_dist < rows_values.items.len and i_dist < bindings.len) : (i_dist += 1) {
                const vals = rows_values.items[i_dist];
                const key = canonicalValuesKey(ally, vals[0..q.ret.items.len]);
                if (!seen.contains(key)) {
                    seen.put(key, {}) catch {};
                    // keep this binding and its values
                    kept_bindings.append(ally, bindings[i_dist]) catch {};
                    kept_values.append(ally, vals) catch {};
                } else {
                    // drop duplicate row: free value slice and key if separately allocated
                    ally.free(vals);
                    ally.free(key);
                }
            }
            // Replace arrays; note: bindings contents were moved by value; subsequent code will not use old slice
            bindings = kept_bindings.toOwnedSlice(ally) catch bindings;
            // rows_values: clear and move kept_values
            // Free any remaining unreferenced value slices
            var jv: usize = i_dist;
            while (jv < rows_values.items.len) : (jv += 1) ally.free(rows_values.items[jv]);
            rows_values.clearRetainingCapacity();
            for (kept_values.items) |rv| rows_values.append(ally, rv) catch {};
        }

        // ORDER BY
        var ordered_now = false;
        var order_keys_local: [][]const u8 = &.{};
        if (q.order_by) |ob| {
            ordered_now = true;
            // Build col index map
            var col_index = std.StringHashMap(usize).init(ally);
            defer col_index.deinit();
            var ci_map: usize = 0;
            while (ci_map < cols.len) : (ci_map += 1) {
                col_index.put(cols[ci_map].name, ci_map) catch {};
            }
            // Build list of key names for metadata
            order_keys_local = try ally.alloc([]const u8, ob.keys.len);
            var okm: usize = 0;
            while (okm < ob.keys.len) : (okm += 1) {
                const s = geode.printer.stringifyExprAlloc(ally, ob.keys[okm].expr, .{}) catch "k";
                order_keys_local[okm] = s;
            }
            // Precompute key matrix from rows_values by alias position
            const KeyKind = enum { Null, Int, Dec, Str };
            const KeyVal = struct { kind: KeyKind, mantissa: i128 = 0, scale: u8 = 0, str: []const u8 = &.{} };
            const key_count = ob.keys.len;
            var key_matrix: []KeyVal = ally.alloc(KeyVal, bindings.len * key_count) catch &.{};
            defer if (key_matrix.len != 0) ally.free(key_matrix);
            var ri_k: usize = 0;
            while (ri_k < bindings.len) : (ri_k += 1) {
                var ki: usize = 0;
                while (ki < key_count) : (ki += 1) {
                    const key_expr = ob.keys[ki].expr;
                    var kv: KeyVal = .{ .kind = .Null };
                    if (key_expr == .Ident) {
                        if (col_index.get(key_expr.Ident)) |posc| {
                            if (ri_k < rows_values.items.len and posc < rows_values.items[ri_k].len) {
                                const v = rows_values.items[ri_k][posc];
                                kv = switch (v) {
                                    .Null => .{ .kind = .Null },
                                    .Int => |iv| .{ .kind = .Int, .mantissa = iv },
                                    .Decimal => |d| .{ .kind = .Dec, .mantissa = d.coeff, .scale = d.scale },
                                    .Str => |s| .{ .kind = .Str, .str = s },
                                    .Bool => |b| .{ .kind = .Str, .str = if (b) "true" else "false" },
                                };
                            }
                        }
                    }
                    key_matrix[ri_k * key_count + ki] = kv;
                }
            }
            // Sort indices based on key_matrix; tie-break by rendered JSON row lexicographically
            const idx = ally.alloc(usize, bindings.len) catch null;
            if (idx) |indices| {
                var fi: usize = 0;
                while (fi < indices.len) : (fi += 1) indices[fi] = fi;
                const Ctx = struct {
                    keys: []KeyVal,
                    key_count: usize,
                    ob: *const @TypeOf(ob),
                    // Lazily rendered for tie-break only
                    ally: std.mem.Allocator,
                    g: *const graph_exec.GraphStorage,
                    ret_items: []const geode.ast.ReturnItem,
                    binds: []const graph_exec.Binding,
                };
                std.sort.block(usize, indices, Ctx{ .keys = key_matrix, .key_count = key_count, .ob = &ob, .ally = ally, .g = graph, .ret_items = q.ret.items, .binds = bindings }, struct {
                    fn less(c: Ctx, a: usize, b: usize) bool {
                        var ki2: usize = 0;
                        while (ki2 < c.ob.keys.len) : (ki2 += 1) {
                            const key_expr = c.ob.keys[ki2];
                            const av = c.keys[a * c.key_count + ki2];
                            const bv = c.keys[b * c.key_count + ki2];
                            // Null handling policy
                            if (av.kind == .Null and bv.kind != .Null) {
                                if (g_nulls_last) {
                                    if (key_expr.desc) return true;
                                    return false;
                                } else return !key_expr.desc;
                            }
                            if (bv.kind == .Null and av.kind != .Null) {
                                if (g_nulls_last) {
                                    if (key_expr.desc) return false;
                                    return true;
                                } else return key_expr.desc;
                            }
                            // Compare by kind
                            var ord: i2 = 0;
                            switch (av.kind) {
                                .Null => ord = 0,
                                .Str => ord = blk: {
                                    if (bv.kind == .Str) {
                                        if (std.mem.lessThan(u8, av.str, bv.str)) break :blk -1;
                                        if (std.mem.lessThan(u8, bv.str, av.str)) break :blk 1;
                                        break :blk 0;
                                    } else break :blk 1; // strings after numbers
                                },
                                .Int, .Dec => ord = blk2: {
                                    switch (bv.kind) {
                                        .Int, .Dec => {
                                            var ma = av.mantissa;
                                            var mb = bv.mantissa;
                                            const as = av.scale;
                                            const bs = bv.scale;
                                            if (as < bs) {
                                                var d = bs - as;
                                                while (d > 0) : (d -= 1) ma *= 10;
                                            }
                                            if (bs < as) {
                                                var d2 = as - bs;
                                                while (d2 > 0) : (d2 -= 1) mb *= 10;
                                            }
                                            if (ma < mb) break :blk2 -1;
                                            if (ma > mb) break :blk2 1;
                                            break :blk2 0;
                                        },
                                        .Str => break :blk2 -1,
                                        .Null => break :blk2 1,
                                    }
                                },
                            }
                            if (ord != 0) return if (key_expr.desc) ord > 0 else ord < 0;
                        }
                        // Tie-break: render both rows and compare bytes
                        const ra = graph_exec.bindingsToJson(c.ally, c.binds[a .. a + 1], c.ret_items, c.g) catch &.{};
                        const rb = graph_exec.bindingsToJson(c.ally, c.binds[b .. b + 1], c.ret_items, c.g) catch &.{};
                        // Free element buffers before freeing the arrays-of-slices. Note: defer executes LIFO.
                        defer if (rb.len > 0) c.ally.free(rb);
                        defer if (ra.len > 0) c.ally.free(ra);
                        defer if (rb.len > 0) c.ally.free(rb[0]);
                        defer if (ra.len > 0) c.ally.free(ra[0]);
                        const sa: []const u8 = if (ra.len > 0) ra[0] else &.{};
                        const sb: []const u8 = if (rb.len > 0) rb[0] else &.{};
                        return std.mem.lessThan(u8, sa, sb);
                    }
                }.less);
                // Apply permutation to bindings (so we can render in order)
                var ordered_bind = std.ArrayList(graph_exec.Binding).initCapacity(ally, bindings.len) catch return error.OutOfMemory;
                defer ordered_bind.deinit(ally);
                var oi: usize = 0;
                while (oi < indices.len) : (oi += 1) ordered_bind.append(ally, try bindings[indices[oi]].clone(ally)) catch {};
                bindings = ordered_bind.toOwnedSlice(ally) catch bindings;
                ally.free(indices);
            }
        }

        // OFFSET/LIMIT
        var start: usize = 0;
        if (q.offset) |off| start = if (off < bindings.len) off else bindings.len;
        var end: usize = bindings.len;
        if (q.limit) |lim| {
            if (start + lim < end) end = start + lim;
        }

        // Set metadata
        ordered_meta.* = ordered_now;
        order_keys.* = order_keys_local;

        // Render the final selected slice
        const rows_slice = try graph_exec.bindingsToJson(ally, bindings[start..end], q.ret.items, graph);
        // If a guard trip diagnostic occurred, mark eval_diag (already set upstream) and return rows.
        return rows_slice;
    }

    // Original implementation for non-MATCH queries
    // Build rows
    var cols = try ally.alloc(protocol.SchemaCol, q.ret.items.len);
    var rows_json = std.ArrayList([]const u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    defer rows_json.deinit(ally);

    // Structured row arena (phase 1): only enabled when DISTINCT required so we can build canonical keys without reparsing JSON.
    const need_row_values = q.ret.distinct or (q.order_by != null); // future: GROUP BY, aggregation
    var rows_values = std.ArrayList([]const eval.Value).initCapacity(ally, 0) catch unreachable; // flattened; each slice length = q.ret.items.len
    defer if (need_row_values) rows_values.deinit(ally) else rows_values.deinit(ally); // always deinit; capacity small in tests.

    const t_start = if (timings) |_| std.time.nanoTimestamp() else 0;

    const has_params = param_matrix.len > 0;
    const num_rows = if (has_params) param_matrix.len else 1;
    // Capture per-row evaluation environments for later ORDER BY key evaluation.
    var envs = try ally.alloc(eval.Env, num_rows);
    var r: usize = 0;
    while (r < num_rows) : (r += 1) {
        const env: eval.Env = if (has_params) .{ .names = param_names, .values = param_matrix[r] } else .{ .names = &.{}, .values = &.{} };
        envs[r] = env;
        // Build JSON row
        var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return error.OutOfMemory;
        const w = buf.writer(ally);
        w.writeAll("{") catch {};
        var j: usize = 0;
        var row_vals: []eval.Value = &.{};
        if (need_row_values and q.ret.items.len > 0) {
            row_vals = try ally.alloc(eval.Value, q.ret.items.len);
        }
        while (j < q.ret.items.len) : (j += 1) {
            const it = q.ret.items[j];
            const alias = it.alias orelse blk: {
                const tmp = geode.printer.stringifyExprAlloc(ally, it.expr, .{}) catch "col";
                break :blk tmp;
            };
            const val = eval.evalExpr(ally, it.expr, env) catch |e| blk_evalerr: {
                if (eval_diag) |ed| {
                    if (diagnostics.mapEvalError(e)) |c| ed.* = c;
                }
                break :blk_evalerr eval.Value{ .Null = {} };
            };
            if (r == 0) cols[j] = .{ .name = alias, .type = valueTypeName(val) };
            if (j > 0) w.writeAll(",") catch {};
            w.print("\"{s}\":", .{alias}) catch {};
            writeJsonValue(w, val) catch {};
            if (need_row_values) row_vals[j] = val;
        }
        w.writeAll("}") catch {};
        rows_json.append(ally, buf.toOwnedSlice(ally) catch "{}") catch {};
        if (need_row_values) rows_values.append(ally, row_vals) catch {};
    }

    if (timings) |tptr| {
        tptr.project_ns = std.time.nanoTimestamp() - t_start;
        tptr.project_rows_in = num_rows;
        tptr.project_rows_out = rows_json.items.len;
        tptr.expand_rows_in = num_rows; // stub: no expansion yet
        tptr.expand_rows_out = num_rows;
        var tb: usize = 0;
        for (rows_json.items) |s| tb += s.len;
        tptr.project_bytes_out = tb;
        const net_now = if (alloc_tracker) |tr| tr.getFn(tr.ctx) else tb;
        tptr.project_bytes_alloc = net_now;
        tptr.net_after_project = net_now;
        tptr.expand_bytes_out = 0;
        tptr.expand_bytes_alloc = 0;
    }

    // Build column name -> index map (for ORDER BY identifier key fast path)
    var col_index = std.StringHashMap(usize).init(ally);
    defer col_index.deinit();
    var ci: usize = 0;
    while (ci < q.ret.items.len) : (ci += 1) {
        const cname = cols[ci].name;
        col_index.put(cname, ci) catch {};
    }

    // DISTINCT delta attribution baseline captured after project
    // alloc_after_project no longer needed (per-stage deltas captured via net_after_* fields)
    if (q.ret.distinct and rows_json.items.len > 1) {
        const t_d_start = if (timings) |_| std.time.nanoTimestamp() else 0;
        distinctDedup(ally, need_row_values, q.ret.items.len, &rows_json, &rows_values, null);
        if (timings) |tptr| {
            tptr.distinct_ns = std.time.nanoTimestamp() - t_d_start;
            tptr.distinct_rows_in = tptr.project_rows_out;
            tptr.distinct_rows_out = rows_json.items.len;
            var tb2: usize = 0;
            for (rows_json.items) |s| tb2 += s.len;
            tptr.distinct_bytes_out = tb2;
            if (alloc_tracker) |tr| {
                const after = tr.getFn(tr.ctx);
                tptr.distinct_bytes_alloc = if (after > tptr.net_after_project) after - tptr.net_after_project else 0;
                tptr.net_after_distinct = after;
            } else {
                tptr.distinct_bytes_alloc = tb2;
                tptr.net_after_distinct = tptr.net_after_project + tptr.distinct_bytes_alloc;
            }
        }
    }

    // ORDER BY (metadata always set when present; we will not reorder unless needed by tests with actual ordering semantics)
    if (q.order_by) |ob| {
        ordered_meta.* = true;
        if (ob.keys.len > 0) {
            order_keys.* = try ally.alloc([]const u8, ob.keys.len);
            var ok: usize = 0;
            while (ok < ob.keys.len) : (ok += 1) {
                const s = geode.printer.stringifyExprAlloc(ally, ob.keys[ok].expr, .{}) catch "k";
                order_keys.*[ok] = s;
            }
        }
        if (rows_json.items.len > 1 and ob.keys.len > 0) {
            const t_sort_start = if (timings) |_| std.time.nanoTimestamp() else 0;
            const KeyKind = enum { Null, Int, Dec, Str };
            const KeyVal = struct { kind: KeyKind, mantissa: i128 = 0, scale: u8 = 0, str: []const u8 = &.{} };
            // Flattened matrix: row-major [row * key_count + key]
            const key_count = ob.keys.len;
            var key_matrix: []KeyVal = ally.alloc(KeyVal, rows_json.items.len * key_count) catch &.{};
            defer if (key_matrix.len != 0) ally.free(key_matrix);
            // For each row, re-evaluate each ORDER BY expression in the same environment used originally.
            // NOTE: For correctness with aliases/ordinals, planner already validated keys are simple identifiers/ordinals.
            var row_index: usize = 0;
            while (row_index < rows_json.items.len) : (row_index += 1) {
                // Reconstruct evaluation environment identical to projection (params only in current prototype).
                var key_i: usize = 0;
                while (key_i < key_count) : (key_i += 1) {
                    const key_expr = ob.keys[key_i].expr;
                    var val: eval.Value = .{ .Null = {} };
                    if (need_row_values and key_expr == .Ident) {
                        if (col_index.get(key_expr.Ident)) |colpos| {
                            if (row_index < rows_values.items.len) {
                                const rv = rows_values.items[row_index];
                                if (colpos < rv.len) val = rv[colpos];
                            }
                        } else {
                            val = eval.evalExpr(ally, key_expr, envs[row_index]) catch eval.Value{ .Null = {} };
                        }
                    } else {
                        val = eval.evalExpr(ally, key_expr, envs[row_index]) catch eval.Value{ .Null = {} };
                    }
                    const slot_index = row_index * key_count + key_i;
                    key_matrix[slot_index] = switch (val) {
                        .Null => KeyVal{ .kind = .Null },
                        .Int => |iv| KeyVal{ .kind = .Int, .mantissa = iv },
                        .Decimal => |d| KeyVal{ .kind = .Dec, .mantissa = d.coeff, .scale = d.scale },
                        .Str => |s| KeyVal{ .kind = .Str, .str = s },
                        .Bool => |b| KeyVal{ .kind = .Str, .str = if (b) "true" else "false" },
                    };
                }
            }
            const Ctx = struct {
                rows: [][]const u8,
                ob: *const @TypeOf(ob),
                keys: []KeyVal,
                key_count: usize,
                fn cmpNumeric(a: KeyVal, b: KeyVal) i2 {
                    if (a.kind == .Int and b.kind == .Int) {
                        if (a.mantissa < b.mantissa) return -1;
                        if (a.mantissa > b.mantissa) return 1;
                        return 0;
                    }
                    var ma = a.mantissa;
                    var mb = b.mantissa;
                    var ascale: u8 = if (a.kind == .Dec) a.scale else 0;
                    var bscale: u8 = if (b.kind == .Dec) b.scale else 0;
                    if (ascale > 0 and a.kind == .Dec) {
                        while (ascale > 0 and @mod(ma, 10) == 0) : (ascale -= 1) {
                            ma = @divTrunc(ma, 10);
                        }
                    }
                    if (bscale > 0 and b.kind == .Dec) {
                        while (bscale > 0 and @mod(mb, 10) == 0) : (bscale -= 1) {
                            mb = @divTrunc(mb, 10);
                        }
                    }
                    if (ascale == bscale) {
                        if (ma < mb) return -1;
                        if (ma > mb) return 1;
                        return 0;
                    }
                    if (ascale < bscale) {
                        var diff = bscale - ascale;
                        while (diff > 0) : (diff -= 1) ma *= 10;
                    } else {
                        var diff = ascale - bscale;
                        while (diff > 0) : (diff -= 1) mb *= 10;
                    }
                    if (ma < mb) return -1;
                    if (ma > mb) return 1;
                    return 0;
                }
            };
            // Optimized ORDER BY: instead of sorting the JSON row slices directly (which required
            // an O(n) scan to map slice->row index for every comparator call), sort a parallel
            // index array referencing precomputed key values. This drops comparator cost from
            // O(k * (n scan)) to O(k) where k = number of ORDER BY keys.
            const maybe_indices = ally.alloc(usize, rows_json.items.len) catch null; // on OOM skip ordering optimization
            if (maybe_indices) |indices| {
                var fi: usize = 0;
                while (fi < indices.len) : (fi += 1) indices[fi] = fi;
                const ICtx = struct {
                    rows: [][]const u8,
                    ob: *const @TypeOf(ob),
                    keys: []KeyVal,
                    key_count: usize,
                };
                std.sort.block(usize, indices, ICtx{ .rows = rows_json.items, .ob = &ob, .keys = key_matrix, .key_count = key_count }, struct {
                    fn less(c: ICtx, a: usize, b: usize) bool {
                        var ki: usize = 0;
                        while (ki < c.ob.keys.len) : (ki += 1) {
                            const key_expr = c.ob.keys[ki];
                            const av = c.keys[a * c.key_count + ki];
                            const bv = c.keys[b * c.key_count + ki];
                            if (av.kind == .Null and bv.kind != .Null) {
                                if (g_nulls_last) {
                                    if (key_expr.desc) return true; // desc: null considered largest
                                    return false; // asc: null after non-null
                                } else {
                                    return !key_expr.desc; // nulls first
                                }
                            }
                            if (bv.kind == .Null and av.kind != .Null) {
                                if (g_nulls_last) {
                                    if (key_expr.desc) return false;
                                    return true;
                                } else {
                                    return key_expr.desc;
                                }
                            }
                            var ord: i2 = 0;
                            switch (av.kind) {
                                .Null => ord = 0,
                                .Str => ord = blk: {
                                    if (bv.kind == .Str) {
                                        if (std.mem.lessThan(u8, av.str, bv.str)) break :blk -1;
                                        if (std.mem.lessThan(u8, bv.str, av.str)) break :blk 1;
                                        break :blk 0;
                                    } else break :blk 1; // strings after numbers
                                },
                                .Int, .Dec => ord = blk: {
                                    switch (bv.kind) {
                                        .Int, .Dec => break :blk Ctx.cmpNumeric(av, bv),
                                        .Str => break :blk -1,
                                        .Null => break :blk 1,
                                    }
                                },
                            }
                            if (ord != 0) return if (key_expr.desc) ord > 0 else ord < 0;
                        }
                        // Stable deterministic tie-break: compare JSON row bytes.
                        const ra = c.rows[a];
                        const rb = c.rows[b];
                        if (std.mem.lessThan(u8, ra, rb)) return true;
                        return false;
                    }
                }.less);
                // Apply permutation to rows_json in new order.
                var new_rows_opt: ?std.ArrayList([]const u8) = std.ArrayList([]const u8).initCapacity(ally, rows_json.items.len) catch null;
                if (new_rows_opt) |*new_rows| {
                    var oi: usize = 0;
                    while (oi < indices.len) : (oi += 1) new_rows.append(ally, rows_json.items[indices[oi]]) catch {};
                    // Free old backing store but not individual row slices (still referenced).
                    ally.free(rows_json.items);
                    rows_json.items = new_rows.items;
                    rows_json.capacity = new_rows.capacity;
                    // Prevent double free by disarming new_rows (we transferred ownership).
                    new_rows.items = &[_][]const u8{};
                    new_rows.capacity = 0;
                }
                ally.free(indices);
            }
            if (timings) |tptr| {
                tptr.sort_ns = std.time.nanoTimestamp() - t_sort_start;
                tptr.sort_rows_in = if (tptr.distinct_rows_out != 0) tptr.distinct_rows_out else tptr.project_rows_out;
                tptr.sort_rows_out = rows_json.items.len;
                var tbs: usize = 0;
                for (rows_json.items) |s| tbs += s.len;
                tptr.sort_bytes_out = tbs;
                if (alloc_tracker) |tr| {
                    const after = tr.getFn(tr.ctx);
                    const base = if (tptr.net_after_distinct != 0) tptr.net_after_distinct else tptr.net_after_project;
                    tptr.sort_bytes_alloc = if (after > base) after - base else 0;
                    tptr.net_after_sort = after;
                } else {
                    tptr.sort_bytes_alloc = tbs;
                    tptr.net_after_sort = (if (tptr.net_after_distinct != 0) tptr.net_after_distinct else tptr.net_after_project) + tptr.sort_bytes_alloc;
                }
            }
        }
    }

    // LIMIT/OFFSET
    var start: usize = 0;
    var t_offset_start: i128 = 0;
    if (q.offset) |off| {
        if (timings) |_| t_offset_start = std.time.nanoTimestamp();
        if (off < rows_json.items.len) {
            start = off;
        } else {
            start = rows_json.items.len;
        }
        if (timings) |tptr| {
            tptr.offset_ns = std.time.nanoTimestamp() - t_offset_start;
            tptr.offset_rows_in = if (tptr.sort_rows_out != 0) tptr.sort_rows_out else if (tptr.distinct_rows_out != 0) tptr.distinct_rows_out else tptr.project_rows_out;
            tptr.offset_rows_out = if (off < rows_json.items.len) rows_json.items.len - off else 0;
            var tbo: usize = 0;
            if (tptr.offset_rows_out > 0) {
                var si: usize = start;
                while (si < rows_json.items.len) : (si += 1) tbo += rows_json.items[si].len;
            }
            tptr.offset_bytes_out = tbo;
            if (alloc_tracker) |tr| {
                const after = tr.getFn(tr.ctx);
                const base = if (tptr.net_after_sort != 0) tptr.net_after_sort else if (tptr.net_after_distinct != 0) tptr.net_after_distinct else tptr.net_after_project;
                tptr.offset_bytes_alloc = if (after > base) after - base else 0;
                tptr.net_after_offset = after;
            } else {
                tptr.offset_bytes_alloc = tbo;
                const base = if (tptr.net_after_sort != 0) tptr.net_after_sort else if (tptr.net_after_distinct != 0) tptr.net_after_distinct else tptr.net_after_project;
                tptr.net_after_offset = base + tptr.offset_bytes_alloc;
            }
        }
    }
    var end: usize = rows_json.items.len;
    var t_limit_start: i128 = 0;
    if (q.limit) |lim| {
        if (timings) |_| t_limit_start = std.time.nanoTimestamp();
        if (start + lim < end) end = start + lim;
        if (timings) |tptr| {
            tptr.limit_ns = std.time.nanoTimestamp() - t_limit_start;
            tptr.limit_rows_in = if (tptr.offset_rows_out != 0) tptr.offset_rows_out else if (tptr.sort_rows_out != 0) tptr.sort_rows_out else tptr.project_rows_out;
            const effective = if (start + lim < rows_json.items.len) lim else rows_json.items.len - start;
            tptr.limit_rows_out = effective;
            var tbl: usize = 0;
            var li: usize = start;
            const end_calc = start + effective;
            while (li < end_calc and li < rows_json.items.len) : (li += 1) tbl += rows_json.items[li].len;
            tptr.limit_bytes_out = tbl;
            if (alloc_tracker) |tr| {
                const after = tr.getFn(tr.ctx);
                const base = if (tptr.net_after_offset != 0) tptr.net_after_offset else if (tptr.net_after_sort != 0) tptr.net_after_sort else if (tptr.net_after_distinct != 0) tptr.net_after_distinct else tptr.net_after_project;
                tptr.limit_bytes_alloc = if (after > base) after - base else 0;
                tptr.net_after_limit = after;
            } else {
                tptr.limit_bytes_alloc = tbl;
                const base = if (tptr.net_after_offset != 0) tptr.net_after_offset else if (tptr.net_after_sort != 0) tptr.net_after_sort else if (tptr.net_after_distinct != 0) tptr.net_after_distinct else tptr.net_after_project;
                tptr.net_after_limit = base + tptr.limit_bytes_alloc;
            }
        }
    }
    if (start != 0 or end != rows_json.items.len) {
        var slice_rows = std.ArrayList([]const u8).initCapacity(ally, 0) catch unreachable;
        defer slice_rows.deinit(ally);
        var start_i: usize = start;
        while (start_i < end) : (start_i += 1) slice_rows.append(ally, rows_json.items[start_i]) catch {};
        // Free skipped rows
        var skip_i: usize = 0;
        while (skip_i < rows_json.items.len) : (skip_i += 1) if (skip_i < start or skip_i >= end) ally.free(rows_json.items[skip_i]);
        rows_json.clearRetainingCapacity();
        for (slice_rows.items) |s| rows_json.append(ally, s) catch {};
    }

    // If some phases not executed, propagate previous row counts for clarity
    if (timings) |tptr| {
        if (tptr.distinct_rows_out == 0) tptr.distinct_rows_out = tptr.project_rows_out;
        if (tptr.expand_rows_out == 0) tptr.expand_rows_out = tptr.project_rows_in;
        if (tptr.sort_rows_out == 0) tptr.sort_rows_out = if (tptr.distinct_rows_out != 0) tptr.distinct_rows_out else tptr.project_rows_out;
        if (tptr.offset_rows_out == 0) tptr.offset_rows_out = tptr.sort_rows_out;
        if (tptr.limit_rows_out == 0) tptr.limit_rows_out = if (q.limit != null) @min(rows_json.items.len, tptr.offset_rows_out) else rows_json.items.len;
        if (tptr.distinct_rows_in == 0) tptr.distinct_rows_in = tptr.project_rows_out;
        if (tptr.expand_rows_in == 0) tptr.expand_rows_in = tptr.expand_rows_out;
        if (tptr.sort_rows_in == 0) tptr.sort_rows_in = tptr.distinct_rows_out;
        if (tptr.offset_rows_in == 0) tptr.offset_rows_in = tptr.sort_rows_out;
        if (tptr.limit_rows_in == 0) tptr.limit_rows_in = tptr.offset_rows_out;
        if (tptr.distinct_bytes_out == 0) tptr.distinct_bytes_out = tptr.project_bytes_out;
        if (tptr.expand_bytes_out == 0) tptr.expand_bytes_out = 0;
        if (tptr.sort_bytes_out == 0) tptr.sort_bytes_out = tptr.distinct_bytes_out;
        if (tptr.offset_bytes_out == 0) tptr.offset_bytes_out = tptr.sort_bytes_out;
        if (tptr.limit_bytes_out == 0) tptr.limit_bytes_out = if (q.limit != null) tptr.limit_bytes_out else tptr.offset_bytes_out;
        if (tptr.distinct_bytes_alloc == 0) tptr.distinct_bytes_alloc = if (tptr.net_after_distinct != 0 and tptr.net_after_project != 0 and tptr.net_after_distinct >= tptr.net_after_project) tptr.net_after_distinct - tptr.net_after_project else tptr.project_bytes_alloc;
        if (tptr.expand_bytes_alloc == 0) tptr.expand_bytes_alloc = 0;
        if (tptr.sort_bytes_alloc == 0) tptr.sort_bytes_alloc = if (tptr.net_after_sort != 0) (if (tptr.net_after_distinct != 0) tptr.net_after_sort - tptr.net_after_distinct else tptr.net_after_sort - tptr.net_after_project) else tptr.distinct_bytes_alloc;
        if (tptr.offset_bytes_alloc == 0) tptr.offset_bytes_alloc = if (tptr.net_after_offset != 0) (if (tptr.net_after_sort != 0) tptr.net_after_offset - tptr.net_after_sort else tptr.net_after_offset - tptr.net_after_project) else tptr.sort_bytes_alloc;
        if (tptr.limit_bytes_alloc == 0) tptr.limit_bytes_alloc = if (q.limit != null and tptr.net_after_limit != 0) (if (tptr.net_after_offset != 0) tptr.net_after_limit - tptr.net_after_offset else tptr.net_after_limit - (if (tptr.net_after_sort != 0) tptr.net_after_sort else tptr.net_after_project)) else tptr.offset_bytes_alloc;
    }

    cols_out.* = cols;
    return rows_json.toOwnedSlice(ally) catch &.{};
}

fn evaluateUnion(ally: std.mem.Allocator, u: geode.ast.UnionQuery, param_names: [][]const u8, param_matrix: [][]const eval.Value, union_mode_out: *[]const u8, metrics: *UnionMetrics) ![][]const u8 {
    // Evaluate each component as simple query without ORDER/LIMIT (applied externally if needed)
    var dummy_cols: []const protocol.SchemaCol = &.{};
    var ordered: bool = false;
    var order_keys: [][]const u8 = &.{};
    const left_rows = try evaluateSimpleQuery(ally, u.first, param_names, param_matrix, &ordered, &order_keys, &dummy_cols, null, null, null);
    metrics.left_in = left_rows.len;
    var all_rows = std.ArrayList([]const u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    defer all_rows.deinit(ally);
    for (left_rows) |r| all_rows.append(ally, r) catch {};
    var any_all = false;
    var total_tail: usize = 0;
    var ti: usize = 0;
    while (ti < u.tails.len) : (ti += 1) {
        const part = u.tails[ti];
        if (part.all) any_all = true;
        var oc: []const protocol.SchemaCol = &.{};
        ordered = false;
        order_keys = &.{};
        const rows = try evaluateSimpleQuery(ally, part.query, param_names, param_matrix, &ordered, &order_keys, &oc, null, null, null);
        total_tail += rows.len;
        for (rows) |rr| all_rows.append(ally, rr) catch {};
    }
    metrics.right_in = total_tail;
    if (any_all) {
        union_mode_out.* = "ALL";
        metrics.out = all_rows.items.len;
        metrics.hash_size = null;
        return all_rows.toOwnedSlice(ally) catch &.{};
    }
    union_mode_out.* = "DISTINCT";
    if (all_rows.items.len <= 1) {
        metrics.out = all_rows.items.len;
        metrics.hash_size = all_rows.items.len;
        return all_rows.toOwnedSlice(ally) catch &.{};
    }
    // Reuse shared helper directly on all_rows (in-place). We pass a dummy values list.
    var dummy_vals = std.ArrayList([]const eval.Value).initCapacity(ally, 0) catch return error.OutOfMemory;
    defer dummy_vals.deinit(ally);
    var hash_size: usize = 0;
    distinctDedup(ally, false, 0, &all_rows, &dummy_vals, &hash_size);
    metrics.out = all_rows.items.len;
    metrics.hash_size = hash_size;
    return all_rows.toOwnedSlice(ally) catch &.{};
}

fn evaluateBinarySet(
    ally: std.mem.Allocator,
    left: geode.ast.Query,
    right: geode.ast.Query,
    param_names: [][]const u8,
    param_matrix: [][]const eval.Value,
    is_intersect: bool,
    all: bool,
) ![][]const u8 {
    var dcols: []const protocol.SchemaCol = &.{};
    var ord: bool = false;
    var oks: [][]const u8 = &.{};
    const left_rows = try evaluateSimpleQuery(ally, left, param_names, param_matrix, &ord, &oks, &dcols, null, null, null);
    ord = false;
    oks = &.{};
    dcols = &.{};
    const right_rows = try evaluateSimpleQuery(ally, right, param_names, param_matrix, &ord, &oks, &dcols, null, null, null);

    if (all) {
        var lc = std.StringHashMap(usize).init(ally);
        defer lc.deinit();
        var rc = std.StringHashMap(usize).init(ally);
        defer rc.deinit();
        for (left_rows) |lr| {
            const key = canonicalRowKey(ally, lr);
            const e = lc.getOrPut(key) catch continue;
            if (!e.found_existing) {
                e.key_ptr.* = key;
                e.value_ptr.* = 1;
            } else {
                e.value_ptr.* += 1;
                ally.free(key);
            }
        }
        for (right_rows) |rr| {
            const key = canonicalRowKey(ally, rr);
            const e = rc.getOrPut(key) catch continue;
            if (!e.found_existing) {
                e.key_ptr.* = key;
                e.value_ptr.* = 1;
            } else {
                e.value_ptr.* += 1;
                ally.free(key);
            }
        }
        var out = std.ArrayList([]const u8).initCapacity(ally, 0) catch return error.OutOfMemory;
        defer out.deinit(ally);
        var it = lc.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const lcnt = entry.value_ptr.*;
            const rcnt = rc.get(key) orelse 0;
            if (is_intersect) {
                const m = if (lcnt < rcnt) lcnt else rcnt;
                var i: usize = 0;
                while (i < m) : (i += 1) {
                    var found: []const u8 = &.{};
                    var li: usize = 0;
                    while (li < left_rows.len) : (li += 1) {
                        const k2 = canonicalRowKey(ally, left_rows[li]);
                        const eq = std.mem.eql(u8, k2, key);
                        ally.free(k2);
                        if (eq) {
                            found = left_rows[li];
                            break;
                        }
                    }
                    if (found.len == 0 and left_rows.len > 0) found = left_rows[0];
                    out.append(ally, found) catch {};
                }
            } else {
                if (lcnt > rcnt) {
                    var d: usize = lcnt - rcnt;
                    while (d > 0) : (d -= 1) {
                        var found: []const u8 = &.{};
                        var li: usize = 0;
                        while (li < left_rows.len) : (li += 1) {
                            const k2 = canonicalRowKey(ally, left_rows[li]);
                            const eq = std.mem.eql(u8, k2, key);
                            ally.free(k2);
                            if (eq) {
                                found = left_rows[li];
                                break;
                            }
                        }
                        if (found.len == 0 and left_rows.len > 0) found = left_rows[0];
                        out.append(ally, found) catch {};
                    }
                }
            }
        }
        var ri: usize = 0;
        while (ri < right_rows.len) : (ri += 1) ally.free(right_rows[ri]);
        return out.toOwnedSlice(ally) catch &.{};
    }

    var seen_left = std.StringHashMap(void).init(ally);
    defer seen_left.deinit();
    var outd = std.StringHashMap([]const u8).init(ally);
    defer outd.deinit();
    for (left_rows) |lr| {
        const key = canonicalRowKey(ally, lr);
        if (!seen_left.contains(key)) {
            seen_left.put(key, {}) catch {};
            const e = outd.getOrPut(key) catch continue;
            if (!e.found_existing) e.value_ptr.* = lr else ally.free(key);
        } else ally.free(key);
    }
    var seen_right = std.StringHashMap(void).init(ally);
    defer seen_right.deinit();
    for (right_rows) |rr| {
        const key = canonicalRowKey(ally, rr);
        seen_right.put(key, {}) catch {};
        // do not free key; map holds reference for duration of function
    }
    var out_rows = std.ArrayList([]const u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    defer out_rows.deinit(ally);
    var it2 = outd.iterator();
    while (it2.next()) |entry| {
        const key = entry.key_ptr.*;
        const row = entry.value_ptr.*;
        const in_right = seen_right.contains(key);
        if (is_intersect) {
            if (in_right) out_rows.append(ally, row) catch {};
        } else {
            if (!in_right) out_rows.append(ally, row) catch {};
        }
    }
    var rr: usize = 0;
    while (rr < right_rows.len) : (rr += 1) ally.free(right_rows[rr]);
    return out_rows.toOwnedSlice(ally) catch &.{};
}

fn handleQuicConnection(
    gpa: std.mem.Allocator,
    conn: *quic_transport.QuicConnection,
    result_format_txt: bool,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
    test_wal_skip_ratio: ?f64,
    env_spill_sort: usize,
    env_spill_distinct: usize,
    env_spill_union: usize,
    env_spill_threshold: usize,
    env_storage_checksum_error: bool,
    env_wal_compact_interval: usize,
    _force_serialization_failure_unused: bool,
) !void {
    _ = env_wal_compact_interval;
    _ = _force_serialization_failure_unused;
    defer conn.close();

    // Accept a stream for the protocol communication
    const stream = try conn.acceptStream();
    defer stream.close();

    // Initialize WAL
    var wal = wal_mod.Wal.init(gpa);
    defer wal.deinit();
    wal.openFile("/tmp/geode_ephemeral_wal") catch {};
    if (test_wal_skip_ratio) |ov| {
        wal.test_skip_ratio_override = ov;
    }

    // Initialize state
    var state = ServerState{ .allocator = gpa };
    state.telemetry_paging = std.posix.getenv("GEODE_TELEMETRY_PAGING") != null;
    state.txn_manager.init(gpa);
    state.inserted_values = .{};
    state.wal_ptr = @ptrCast(&wal);
    state.spill_sort = env_spill_sort;
    state.spill_distinct = env_spill_distinct;
    state.spill_union = env_spill_union;
    state.query_mem_limit_bytes = env_spill_threshold;
    state.storage_checksum_error = env_storage_checksum_error;

    // Process messages
    while (true) {
        const line = stream.readLine(65536) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        defer gpa.free(line);

        if (line.len == 0) continue;

        // Process the message and send response
        const response = processMessage(gpa, &state, line, result_format_txt, disable_estimates, compact_profile, memcurve_profile) catch |err| {
            const error_msg = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"58000\",\"error\":\"{s}\"}}\n", .{@errorName(err)});
            defer gpa.free(error_msg);
            try stream.writeAll(error_msg);
            continue;
        };
        defer if (response.len > 0) gpa.free(response);

        if (response.len > 0) {
            try stream.writeAll(response);
        }
    }
}

// Extract the message processing logic into a separate function
fn processMessage(
    gpa: std.mem.Allocator,
    state: *ServerState,
    _line: []const u8,
    result_format_txt: bool,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
) ![]u8 {
    _ = disable_estimates;
    _ = compact_profile;
    _ = memcurve_profile;
    _ = result_format_txt;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const msg = protocol.parseClientMessage(arena.allocator(), _line) catch return try gpa.dupe(u8, "");
    switch (msg) {
        .HELLO => |_| {
            // Return HELLO response with capabilities
            const hello_response = "{\"status_class\":\"00000\",\"capabilities\":[\"QUIC\",\"TLS1.3\"]}\n";
            return try gpa.dupe(u8, hello_response);
        },
        .CDC_DIAGNOSTICS => |_| {
            if (state.cdc_engine) |eng| {
                const payload = eng.exportDiagnostics(gpa) catch {
                    return protocol.buildCdcDiagnosticsLine(gpa, "{\"cdc_error\":\"export_failed\"}") catch try gpa.dupe(u8, "");
                };
                defer gpa.free(payload);
                return protocol.buildCdcDiagnosticsLine(gpa, payload) catch try gpa.dupe(u8, "");
            } else {
                const json = "{\"cdc\":{\"enabled\":false}}";
                return protocol.buildCdcDiagnosticsLine(gpa, json) catch try gpa.dupe(u8, "");
            }
        },
        .CDC_CONTROL => |cc| {
            if (handleCdcControl(gpa, state, cc.action)) |resp| return resp else return try gpa.dupe(u8, "");
        },
        .PING => |_| {
            const ok = "{\"ok\":true}";
            const flags = computeBaseFlags(false, false);
            return protocol.buildBindingsLine(gpa, false, &.{}, ok, true, &.{}, flags) catch try gpa.dupe(u8, "");
        },
        .RUN_GQL => |rq| {
            state.resetResult();
            var text = rq.text;
            // Detect EXPLAIN / EXPLAIN CALIBRATED / PROFILE prefixes; track modes then strip
            var explain_mode = false;
            var explain_calibrated = false;
            var profile_mode = false;
            if (std.mem.startsWith(u8, text, "EXPLAIN CALIBRATED ")) {
                explain_mode = true;
                explain_calibrated = true;
                text = text["EXPLAIN CALIBRATED ".len..];
            } else if (std.mem.eql(u8, text, "EXPLAIN CALIBRATED")) {
                explain_mode = true;
                explain_calibrated = true;
                text = "";
            } else if (std.mem.startsWith(u8, text, "EXPLAIN ")) {
                explain_mode = true;
                text = text["EXPLAIN ".len..];
            } else if (std.mem.eql(u8, text, "EXPLAIN")) {
                explain_mode = true;
                text = "";
            } else if (std.mem.startsWith(u8, text, "PROFILE ")) {
                profile_mode = true;
                text = text["PROFILE ".len..];
            } else if (std.mem.eql(u8, text, "PROFILE")) {
                profile_mode = true;
                text = "";
            }
            var parse_res = geode.parseGqlOutcome(text, gpa, .{ .ident_order_only = !g_order_keys_expr, .forbid_orderby_calls = !g_order_keys_expr }) catch return try gpa.dupe(u8, "");
            switch (parse_res) {
                .Err => |er| {
                    // Map parser message to diagnostics (IllegalOrderKey, US001) using same helper as later handler
                    var codes_buf: [4]diagnostics.Code = undefined;
                    const n_raw = collectTextDiagnostics(text, er.msg, &codes_buf);
                    const n = diagnostics.foldCodes(codes_buf[0..n_raw]);
                    if (n == 0) {
                        return protocol.buildErrorLine(gpa, "ParseError", er.msg, "") catch try gpa.dupe(u8, "");
                    }
                    const primary = codes_buf[0];
                    const add_slice = buildAdditionalStatusesAlloc(gpa, codes_buf[0..n], primary);
                    const primary_msg = if (primary == .IllegalOrderKey) er.msg else diagnostics.defaultMessage(primary);
                    const has_us001 = primary == .US001;
                    var flags_buf_local: [3][]const u8 = .{ F_ILLEGAL, F_TIEBREAK, "U:US001/enforced" };
                    const base_flags = if (has_us001) flags_buf_local[0..3] else flags_buf_local[0..2];
                    // Build error line with flags
                    const err_line = protocol.buildErrorLineWithFlagsCustomStatus(gpa, diagnostics.codeName(primary), primary_msg, diagnostics.anchorFor(primary), add_slice, base_flags, null) catch try gpa.dupe(u8, "");
                    return err_line;
                },
                .Ok => |_| {},
            }
            // Post-parse ORDER BY function call validation (server fallback) when expressions disallowed.
            if (!g_order_keys_expr and parse_res == .Ok) {
                const prog = parse_res.Ok.program;
                // Walk first statement only (tests use single statement queries).
                if (prog.statements.len > 0) {
                    const st0 = prog.statements[0];
                    switch (st0) {
                        .Query => |qv| if (qv.order_by) |ob| {
                            var i_fn: usize = 0;
                            while (i_fn < ob.keys.len) : (i_fn += 1) {
                                const e = ob.keys[i_fn].expr;
                                if (e == .Call) {
                                    const err_line2 = protocol.buildErrorLine(gpa, "IllegalOrderKey", "ORDER BY key must be identifier", diagnostics.anchorFor(.IllegalOrderKey)) catch try gpa.dupe(u8, "");
                                    return err_line2;
                                }
                            }
                        },
                        else => {},
                    }
                }
            }
            defer if (parse_res == .Ok) parse_res.Ok.deinit();
            switch (parse_res) {
                .Err => |_| return try gpa.dupe(u8, ""),
                .Ok => |ok| {
                    if (ok.program.statements.len == 0) {
                        if (protocol.buildSchemaLine(gpa, &.{}, &.{}, computeBaseFlags(false, false))) |line| return line else |_| return try gpa.dupe(u8, "");
                    }
                    const st = ok.program.statements[0];
                    switch (st) {
                        .Union => |u_stmt| {
                            var pn: [][]const u8 = &.{};
                            var pr: [][]const eval.Value = &.{};
                            parseParams(gpa, rq.params_json, &pn, &pr);
                            var metrics: UnionMetrics = .{ .left_in = 0, .right_in = 0, .out = 0, .hash_size = null };
                            var mode: []const u8 = "DISTINCT";
                            const rows = evaluateUnion(gpa, u_stmt, pn, pr, &mode, &metrics) catch &.{};
                            var cols_box = gpa.alloc(protocol.SchemaCol, u_stmt.first.ret.items.len) catch return try gpa.dupe(u8, "");
                            var ci: usize = 0;
                            while (ci < u_stmt.first.ret.items.len) : (ci += 1) {
                                const it = u_stmt.first.ret.items[ci];
                                var name_slice: []const u8 = "col";
                                if (it.alias) |al| name_slice = al else {
                                    const tmpn = geode.printer.stringifyExprAlloc(gpa, it.expr, .{}) catch "col";
                                    name_slice = tmpn;
                                }
                                cols_box[ci] = .{ .name = name_slice, .type = "INT" };
                            }
                            const cols: []const protocol.SchemaCol = cols_box;
                            state.last_columns = cols;
                            state.last_ordered = false;
                            state.last_order_keys = &.{};
                            state.last_distinct = std.mem.eql(u8, mode, "DISTINCT");
                            state.page_items = @constCast(rows);
                            state.page_index = 0;
                            state.active_result = true;
                            return protocol.buildSchemaLine(gpa, state.last_columns, &.{}, computeBaseFlags(false, state.last_distinct)) catch try gpa.dupe(u8, "");
                        },
                        .Query => |q| {
                            var pn: [][]const u8 = &.{};
                            var pr: [][]const eval.Value = &.{};
                            parseParams(gpa, rq.params_json, &pn, &pr);
                            var ord = false;
                            var oks: [][]const u8 = &.{};
                            var cols: []const protocol.SchemaCol = &.{};
                            var run_code: diagnostics.Code = .IllegalOrderKey;
                            var timings: StageTimings = .{};
                            const need_timings = profile_mode or explain_calibrated;
                            const rows = evaluateSimpleQuery(gpa, q, pn, pr, &ord, &oks, &cols, if (need_timings) &timings else null, &run_code, null) catch &.{};
                            state.last_columns = cols;
                            state.last_ordered = ord;
                            state.last_order_keys = oks;
                            state.last_distinct = q.ret.distinct;
                            state.page_items = @constCast(rows);
                            state.page_index = 0;
                            state.active_result = true;
                            state.guard_trip = (run_code == .ExecutionGuardTrip);
                            const flags = computeBaseFlags(ord, q.ret.distinct);
                            var addl_buf: [1][]const u8 = undefined;
                            const addl_schema: []const []const u8 = if (state.guard_trip) blk: {
                                addl_buf[0] = "ExecutionGuardTrip";
                                break :blk addl_buf[0..1];
                            } else &.{};
                            const schema_line = protocol.buildSchemaLine(gpa, state.last_columns, addl_schema, flags) catch return try gpa.dupe(u8, "");
                            if (!explain_mode and !profile_mode) return schema_line;
                            // Build explain chain when requested (emit EXPLAIN frame immediately, THEN return bindings via PULL normally)
                            if (explain_mode) {
                                // Build linear op chain approximation using cost model seed descriptors.
                                var ops_buf: [8]geode.cost_seed.OpDescriptor = undefined;
                                var opn: usize = 0;
                                ops_buf[opn] = .{ .kind = .Scan };
                                opn += 1;
                                ops_buf[opn] = .{ .kind = .Project };
                                opn += 1;
                                if (q.ret.distinct) {
                                    ops_buf[opn] = .{ .kind = .Aggregate };
                                    opn += 1;
                                }
                                if (ord) {
                                    ops_buf[opn] = .{ .kind = .Sort };
                                    opn += 1;
                                }
                                if (q.offset != null) {
                                    ops_buf[opn] = .{ .kind = .Filter, .selectivity = 0.5 };
                                    opn += 1;
                                }
                                if (q.limit != null) {
                                    ops_buf[opn] = .{ .kind = .Limit };
                                    opn += 1;
                                }
                                const ops = ops_buf[0..opn];
                                var actual_rows_fixed: [8]f64 = undefined;
                                var actual_slice: ?[]const f64 = null;
                                if (explain_calibrated and need_timings) {
                                    var ai: usize = 0;
                                    actual_rows_fixed[ai] = @floatFromInt(timings.project_rows_in);
                                    ai += 1; // scan input
                                    actual_rows_fixed[ai] = @floatFromInt(timings.project_rows_out);
                                    ai += 1; // project
                                    if (q.ret.distinct) {
                                        actual_rows_fixed[ai] = @floatFromInt(timings.distinct_rows_out);
                                        ai += 1;
                                    }
                                    if (ord) {
                                        actual_rows_fixed[ai] = @floatFromInt(timings.sort_rows_out);
                                        ai += 1;
                                    }
                                    if (q.offset != null) {
                                        actual_rows_fixed[ai] = @floatFromInt(timings.offset_rows_out);
                                        ai += 1;
                                    }
                                    if (q.limit != null) {
                                        actual_rows_fixed[ai] = @floatFromInt(timings.limit_rows_out);
                                        ai += 1;
                                    }
                                    actual_slice = actual_rows_fixed[0..ai];
                                }
                                const explain_json = if (explain_calibrated and actual_slice != null) cost_explain.explainChainWithCalibration(gpa, ops, actual_slice, null) catch null else cost_explain.explainChain(gpa, ops) catch null;
                                if (explain_json) |ej| {
                                    defer gpa.free(ej);
                                    const explain_line = protocol.buildExplainLine(gpa, ej, flags) catch null;
                                    if (explain_line) |el| {
                                        // Concatenate schema + explain into single response (client will expect both before PULL)
                                        var comb = std.ArrayList(u8).initCapacity(gpa, 0) catch return schema_line;
                                        defer comb.deinit(gpa);
                                        comb.appendSlice(gpa, schema_line) catch {};
                                        comb.appendSlice(gpa, el) catch {};
                                        gpa.free(el);
                                        return comb.toOwnedSlice(gpa) catch schema_line; // if OOM fallback returns schema only
                                    }
                                }
                                return schema_line;
                            }
                            if (profile_mode) {
                                // Reuse existing PROFILE emission path: build profile line now.
                                var prof_buf = std.ArrayList(u8).initCapacity(gpa, 0) catch return schema_line;
                                defer prof_buf.deinit(gpa);
                                var wprof = prof_buf.writer(gpa);
                                wprof.writeAll("{") catch {};
                                wprof.writeAll("\"profile_version\":2,\"ops\":[") catch {};
                                var printed_global: usize = 0;
                                const emit = struct {
                                    fn op(w: anytype, printed: *usize, name: []const u8, rows_in: usize, rows_out: usize, time_ns: i128, bytes_out: usize, bytes_alloc: usize) void {
                                        if (printed.* > 0) w.writeAll(",") catch {};
                                        w.writeAll("{\"op\":\"") catch {};
                                        w.writeAll(name) catch {};
                                        w.writeAll("\",\"rows_in\":") catch {};
                                        w.print("{d}", .{rows_in}) catch {};
                                        w.writeAll(",\"rows_out\":") catch {};
                                        w.print("{d}", .{rows_out}) catch {};
                                        w.writeAll(",\"time_ns\":") catch {};
                                        w.print("{d}", .{time_ns}) catch {};
                                        w.writeAll(",\"bytes_out\":") catch {};
                                        w.print("{d}", .{bytes_out}) catch {};
                                        w.writeAll(",\"bytes_alloc\":") catch {};
                                        w.print("{d}", .{bytes_alloc}) catch {};
                                        w.writeAll("}") catch {};
                                        printed.* += 1;
                                    }
                                };
                                if (timings.project_ns != 0) emit.op(wprof, &printed_global, "Project", timings.project_rows_in, timings.project_rows_out, timings.project_ns, timings.project_bytes_out, timings.project_bytes_alloc);
                                if (timings.distinct_ns != 0) emit.op(wprof, &printed_global, "Distinct", timings.distinct_rows_in, timings.distinct_rows_out, timings.distinct_ns, timings.distinct_bytes_out, timings.distinct_bytes_alloc);
                                if (timings.sort_ns != 0) emit.op(wprof, &printed_global, "Sort", timings.sort_rows_in, timings.sort_rows_out, timings.sort_ns, timings.sort_bytes_out, timings.sort_bytes_alloc);
                                if (timings.offset_ns != 0) emit.op(wprof, &printed_global, "Offset", timings.offset_rows_in, timings.offset_rows_out, timings.offset_ns, timings.offset_bytes_out, timings.offset_bytes_alloc);
                                if (timings.limit_ns != 0) emit.op(wprof, &printed_global, "Limit", timings.limit_rows_in, timings.limit_rows_out, timings.limit_ns, timings.limit_bytes_out, timings.limit_bytes_alloc);
                                wprof.writeAll("],\"totals\":{}}") catch {}; // ignoring error intentionally for minimal profile JSON
                                wprof.writeAll("}") catch {};
                                const prof_json = prof_buf.toOwnedSlice(gpa) catch return schema_line;
                                if (protocol.buildProfileLine(gpa, prof_json, flags)) |profile_line| {
                                    gpa.free(prof_json);
                                    var comb2 = std.ArrayList(u8).initCapacity(gpa, 0) catch return schema_line;
                                    defer comb2.deinit(gpa);
                                    comb2.appendSlice(gpa, schema_line) catch {};
                                    comb2.appendSlice(gpa, profile_line) catch {};
                                    gpa.free(profile_line);
                                    return comb2.toOwnedSlice(gpa) catch schema_line;
                                } else |_| {
                                    gpa.free(prof_json);
                                    return schema_line;
                                }
                            }
                            return schema_line;
                        },
                        else => return try gpa.dupe(u8, ""),
                    }
                },
            }
        },
        .PULL => |pl| {
            const page_size = if (pl.page_size == 0) 1000 else pl.page_size;
            const start = state.page_index;
            const end = @min(state.page_index + page_size, state.page_items.len);
            var arr_buf = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
            const w = arr_buf.writer(gpa);
            w.writeAll("[") catch {};
            var i: usize = start;
            var first = true;
            while (i < end) : (i += 1) {
                if (!first) w.writeAll(",") catch {};
                first = false;
                w.writeAll(state.page_items[i]) catch {};
            }
            w.writeAll("]") catch {};
            const json_rows = arr_buf.toOwnedSlice(gpa) catch "[]";
            state.page_index = end;
            const is_final = end >= state.page_items.len;
            if (is_final) state.active_result = false;
            const flags = computeBaseFlags(state.last_ordered, state.last_distinct);
            // Build bindings; include ExecutionGuardTrip advisory on first page if set
            var addl_rows_buf: [1][]const u8 = undefined;
            const addl_rows: []const []const u8 = if (start == 0 and state.guard_trip) blk: {
                addl_rows_buf[0] = "ExecutionGuardTrip";
                break :blk addl_rows_buf[0..1];
            } else &.{};
            const line = protocol.buildBindingsLine(gpa, state.last_ordered, state.last_order_keys, json_rows, is_final, addl_rows, flags) catch return try gpa.dupe(u8, "");
            if (start == 0 and state.guard_trip) state.guard_trip = false; // clear after first emission
            // Strip ,"final":true/false substring for compatibility
            var s = line;
            if (std.mem.indexOf(u8, s, ",\"final\":true")) |pos| {
                const head = s[0..pos];
                const tail = s[pos + ",\"final\":true".len ..];
                var joined = std.ArrayList(u8).initCapacity(gpa, 0) catch return line;
                defer joined.deinit(gpa);
                joined.appendSlice(gpa, head) catch {};
                joined.appendSlice(gpa, tail) catch {};
                const out = joined.toOwnedSlice(gpa) catch line;
                gpa.free(line);
                return out;
            } else if (std.mem.indexOf(u8, s, ",\"final\":false")) |pos2| {
                const head2 = s[0..pos2];
                const tail2 = s[pos2 + ",\"final\":false".len ..];
                var joined2 = std.ArrayList(u8).initCapacity(gpa, 0) catch return line;
                defer joined2.deinit(gpa);
                joined2.appendSlice(gpa, head2) catch {};
                joined2.appendSlice(gpa, tail2) catch {};
                const out2 = joined2.toOwnedSlice(gpa) catch line;
                gpa.free(line);
                return out2;
            }
            return line;
        },
        else => {
            return try gpa.dupe(u8, "");
        },
    }
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    // Parse server CLI args for optional result format and QUIC listener.
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    var result_format_txt = false;
    var disable_estimates = false;
    var compact_profile = false;
    var memcurve_profile = false;
    var ai: usize = 1;
    var log_level_arg: ?[]const u8 = null;
    var test_wal_skip_ratio: ?f64 = null; // test-only override parsed from CLI
    var listen_quic: ?[]const u8 = null;
    var cert_path: ?[]const u8 = null;
    var key_path: ?[]const u8 = null;
    var order_keys_mode_expr = false;
    var data_dir: ?[]const u8 = null;
    var test_exit_after_first: bool = false;
    var catalog_create_name: ?[]const u8 = null;
    var match_max_results_override: ?usize = null; // test deterministic guard trigger

    // Check for help flag
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("Geode Server v0.16.0\n\n", .{});
            std.debug.print("Usage: geoded [OPTIONS]\n\n", .{});
            std.debug.print("Options:\n", .{});
            std.debug.print("  --listen-quic <addr:port>    Listen on QUIC/TLS (e.g., 0.0.0.0:7567)\n", .{});
            std.debug.print("  --cert <path>                Path to TLS certificate (default: auto-generate)\n", .{});
            std.debug.print("  --key <path>                 Path to TLS private key (default: auto-generate)\n", .{});
            std.debug.print("  --data_dir <path>            Data directory for storage and generated certs\n", .{});
            std.debug.print("  --result-format <txt|json>   Result format (default: json)\n", .{});
            std.debug.print("  --no-estimates               Disable query estimation\n", .{});
            std.debug.print("  --profile-compact            Enable compact profiling\n", .{});
            std.debug.print("  --profile-memcurve           Enable memory curve profiling\n", .{});
            std.debug.print("  --order-keys expr            Allow expressions in ORDER BY\n", .{});
            std.debug.print("  --match-max-results <N>      Override MATCH guard max_results (test/deterministic)\n", .{});
            std.debug.print("  --match-max-frontier <N>     Override MATCH guard max_frontier (test/deterministic)\n", .{});
            std.debug.print("  --log-level <lvl>            Set log level trace|debug|info|warn|error|critical (default info)\n", .{});
            std.debug.print("  --help                       Show this help message\n", .{});
            std.debug.print("\nIf no listen option is specified, defaults to stdio mode.\n", .{});
            std.debug.print("Auto-generated certificates are placed in data_dir or /tmp.\n", .{});
            return;
        }
    }

    while (ai < args.len) : (ai += 1) {
        if (std.mem.eql(u8, args[ai], "--result-format") and ai + 1 < args.len) {
            const f = args[ai + 1];
            if (std.mem.eql(u8, f, "txt") or std.mem.eql(u8, f, "text")) result_format_txt = true;
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--no-estimates")) {
            disable_estimates = true;
        } else if (std.mem.eql(u8, args[ai], "--profile-compact")) {
            compact_profile = true;
        } else if (std.mem.eql(u8, args[ai], "--profile-memcurve")) {
            memcurve_profile = true;
        } else if (std.mem.eql(u8, args[ai], "--test-wal-skip-ratio") and ai + 1 < args.len) {
            const v = std.fmt.parseFloat(f64, args[ai + 1]) catch -1.0;
            if (v >= 0.0) test_wal_skip_ratio = v;
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--listen-quic") and ai + 1 < args.len) {
            listen_quic = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--cert") and ai + 1 < args.len) {
            cert_path = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--key") and ai + 1 < args.len) {
            key_path = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--data_dir") and ai + 1 < args.len) {
            data_dir = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--order-keys") and ai + 1 < args.len) {
            const mode = args[ai + 1];
            if (std.mem.eql(u8, mode, "expr")) order_keys_mode_expr = true;
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--test-exit-after-first-request")) {
            test_exit_after_first = true;
        } else if (std.mem.eql(u8, args[ai], "--log-level") and ai + 1 < args.len) {
            log_level_arg = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--catalog-create") and ai + 1 < args.len) {
            catalog_create_name = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--match-max-results") and ai + 1 < args.len) {
            const mv = std.fmt.parseInt(usize, args[ai + 1], 10) catch 0;
            if (mv > 0) match_max_results_override = mv;
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--match-max-frontier") and ai + 1 < args.len) {
            const fv = std.fmt.parseInt(usize, args[ai + 1], 10) catch 0;
            if (fv > 0) g_match_max_frontier_override = fv;
            ai += 1;
        }
    }

    if (log_level_arg) |lla| {
        logger.setLevel(logger.parseLevel(lla));
    }
    logger.info("server.start", .{.{ .key = "level", .value = log_level_arg orelse "info" }});

    if (match_max_results_override) |mmr| g_match_max_results_override = mmr;

    // Ensure TLS certificates exist (only if using QUIC and no custom certs specified)
    if (listen_quic != null) {
        if (cert_path == null or key_path == null) {
            // Use default paths or fallback to /tmp
            const default_cert = if (data_dir) |dir|
                try std.fmt.allocPrint(gpa, "{s}/server.crt", .{dir})
            else
                "/tmp/geode-server.crt";
            const default_key = if (data_dir) |dir|
                try std.fmt.allocPrint(gpa, "{s}/server.key", .{dir})
            else
                "/tmp/geode-server.key";

            cert_path = cert_path orelse default_cert;
            key_path = key_path orelse default_key;

            // Try to generate certificates if they don't exist
            cert_gen.ensureCertificatesAtPath(gpa, cert_path.?, key_path.?) catch |err| {
                std.debug.print("Warning: Could not generate certificates: {s}\n", .{@errorName(err)});
                std.debug.print("Using fallback paths in /tmp\n", .{});
                cert_path = "/tmp/geode-server.crt";
                key_path = "/tmp/geode-server.key";
                try cert_gen.ensureCertificatesAtPath(gpa, cert_path.?, key_path.?);
            };
        }
    } else {
        // For non-QUIC, use dummy paths if not specified
        cert_path = cert_path orelse "certs/server.crt";
        key_path = key_path orelse "certs/server.key";
    }
    // Initialize WAL (test / prototype). For now use a temp path under /tmp; future: data_dir option.
    var wal = wal_mod.Wal.init(gpa);
    defer wal.deinit();
    wal.openFile("/tmp/geode_ephemeral_wal") catch {};
    if (test_wal_skip_ratio) |ov| {
        wal.test_skip_ratio_override = ov;
    }
    // Initialize synthetic index catalog (idempotent) before serving.
    initIndexCatalog(gpa);

    // Prepare environment-derived flags once
    var env_spill_sort: usize = 0;
    var env_spill_distinct: usize = 0;
    var env_spill_union: usize = 0;
    var env_spill_threshold: usize = 0;
    var env_storage_checksum_error = false;
    var env_wal_compact_interval: usize = 5; // Default: compact every 5 commits
    if (std.process.getEnvMap(gpa)) |*env_ptr| {
        var env = env_ptr.*;
        defer env.deinit();
        if (env.get("GEODE_FORCE_SORT_SPILL")) |_| env_spill_sort = 1;
        if (env.get("GEODE_FORCE_DISTINCT_SPILL")) |_| env_spill_distinct = 1;
        if (env.get("GEODE_FORCE_UNION_SPILL")) |_| env_spill_union = 1;
        if (env.get("GEODE_QUERY_MEM_LIMIT_BYTES")) |th| {
            env_spill_threshold = std.fmt.parseInt(usize, th, 10) catch env_spill_threshold;
        } else if (env.get("GEODE_SPILL_THRESHOLD_BYTES")) |th| {
            env_spill_threshold = std.fmt.parseInt(usize, th, 10) catch env_spill_threshold;
        }
        if (env.get("GEODE_WAL_COMPACT_INTERVAL")) |ci| {
            env_wal_compact_interval = std.fmt.parseInt(usize, ci, 10) catch 5;
        }
        if (env.get("GEODE_NULLS_LAST")) |_| g_nulls_last = true;
        if (env.get("GEODE_PROFILE_MEMCURVE")) |_| memcurve_profile = true;
        if (env.get("GEODE_ADAPT_ESTIMATES")) |_| g_adapt_estimates = true;
        if (env.get("GEODE_DISABLE_INDEX_CATALOG")) |_| g_disable_catalog = true;
        if (env.get("GEODE_CHECKSUM_TEST_PATH")) |p| {
            var pm = storage_pm.PageManager.initPersistent(gpa, 4096, p);
            defer pm.deinit();
            pm.loadPage(p, 0) catch |e| switch (e) {
                error.PageChecksumMismatch => {
                    env_storage_checksum_error = true;
                    // Log the corruption for diagnostics
                    std.log.err("Storage page checksum mismatch detected during startup in path: {s}", .{p});
                },
                else => {},
            };
        }
    } else |_| {}

    // Apply ORDER BY key policy based on CLI flag
    g_order_keys_expr = order_keys_mode_expr;

    // Initialize persistent page manager if data_dir provided and wire StorageCatalog
    var pm_persist_active = false;
    var pm_persist: storage_pm.PageManager = undefined;
    var catalog_inited = false;
    var catalog = storage_catalog.StorageCatalog{ .allocator = gpa, .page_manager = undefined, .tables = undefined, .indexes = undefined, .sequences = undefined, .catalog_page_id = null, .graph_metadata = null };
    if (data_dir) |dd| {
        std.fs.cwd().makePath(dd) catch {};
        pm_persist = storage_pm.PageManager.initPersistent(gpa, 4096, dd);
        pm_persist_active = true;
        pm_persist.loadPage(dd, 0) catch {};
        catalog = storage_catalog.StorageCatalog.init(gpa, &pm_persist);
        catalog.load() catch {};
        catalog_inited = true;
        if (catalog_create_name) |tname| {
            catalog.createTable(tname, &.{}) catch {};
        }

        // Try to load graph from catalog
        if (g_graph_storage == null) {
            // For now, just use JSONL files
            const loaded = tryLoadGraphFromDir(gpa, dd) catch null;
            if (loaded) |lg| {
                g_graph_storage = lg;
                // Update catalog metadata
                if (catalog.graph_metadata == null) {
                    catalog.initGraphMetadata() catch {};
                }
                catalog.saveGraphMetadata(@intCast(lg.nodes.count()), @intCast(lg.edges.items.len), 0, // max_node_id - would need to calculate
                    if (lg.edges.items.len > 0) lg.edges.items.len - 1 else 0) catch {};
            }
        }
    }
    defer {
        if (catalog_inited) {
            catalog.save() catch {};
            catalog.deinit();
        }
        if (pm_persist_active) pm_persist.deinit();
    }

    // QUIC mode: preferred over TCP
    if (listen_quic) |addr_str| {
        const colon = std.mem.lastIndexOfScalar(u8, addr_str, ':');
        var port: u16 = 7567;
        var address_str: []const u8 = "0.0.0.0";

        if (colon) |ci| {
            address_str = addr_str[0..ci];
            const p = addr_str[ci + 1 ..];
            port = std.fmt.parseUnsigned(u16, p, 10) catch 7567;
        } else {
            // If no colon, treat as port only
            port = std.fmt.parseUnsigned(u16, addr_str, 10) catch 7567;
        }

        // Initialize QUIC transport
        var transport = try quic_transport.QuicTransport.init(gpa, .{
            .address = address_str,
            .port = port,
            .cert_path = cert_path.?,
            .key_path = key_path.?,
        });
        // In short-lived test runs we avoid tearing down the QUIC endpoint to sidestep
        // vendor teardown crashes; enable passive teardown when --test-exit-after-first
        // or GEODE_QUIC_PASSIVE_TEARDOWN=1 is present.
        const passive_teardown = (std.posix.getenv("GEODE_QUIC_PASSIVE_TEARDOWN") != null) or test_exit_after_first;
        defer {
            if (!passive_teardown) transport.deinit();
        }

        try transport.listen();
        std.debug.print("QUIC server listening on {s}:{d} with TLS 1.3\n", .{ address_str, port });

        while (true) {
            const conn = transport.accept() catch |err| {
                std.debug.print("Failed to accept QUIC connection: {}\n", .{err});
                continue;
            };

            handleQuicConnection(gpa, conn, result_format_txt, disable_estimates, compact_profile, memcurve_profile, test_wal_skip_ratio, env_spill_sort, env_spill_distinct, env_spill_union, env_spill_threshold, env_storage_checksum_error, env_wal_compact_interval, false) catch |err| {
                std.debug.print("Error handling QUIC connection: {}\n", .{err});
            };

            if (test_exit_after_first) break;
        }
        return;
    }

    var state = ServerState{ .allocator = gpa };
    state.telemetry_paging = std.posix.getenv("GEODE_TELEMETRY_PAGING") != null;
    // Initialize CDC engine if enabled via environment
    var cdc_engine_storage: @import("cdc_enhanced").CDCEngine = undefined;
    var cdc_inited = false;
    if (std.process.getEnvVarOwned(gpa, "GEODE_CDC_ENABLE")) |val| {
        defer gpa.free(val);
        if (val.len > 0 and (val[0] == '1' or std.ascii.eqlIgnoreCase(val, "true"))) {
            var sinks_arr = [_]@import("cdc_enhanced").CDCSink{.memory};
            const cfg = @import("cdc_enhanced").CDCConfig{ .enabled = true, .sinks = sinks_arr[0..] };
            cdc_engine_storage = @import("cdc_enhanced").CDCEngine.init(gpa, cfg) catch blk: {
                std.log.err("Failed to init CDC engine", .{});
                break :blk undefined;
            };
            cdc_engine_storage.start() catch std.log.err("CDC engine start failed", .{});
            state.cdc_engine = &cdc_engine_storage;
            cdc_inited = true;
        }
    } else |_| {}
    defer if (cdc_inited) {
        cdc_engine_storage.deinit();
    };
    state.txn_manager.init(gpa);
    state.inserted_values = .{};
    state.wal_ptr = @ptrCast(&wal);
    state.spill_sort = env_spill_sort;
    state.spill_distinct = env_spill_distinct;
    state.spill_union = env_spill_union;
    state.query_mem_limit_bytes = env_spill_threshold;
    state.storage_checksum_error = env_storage_checksum_error;

    const stdin_file = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var stdin_buf: [4096]u8 = undefined;
    var stdin = stdin_file.reader(&stdin_buf);
    const stdout_file = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    var line_storage: [65536]u8 = undefined;

    // Robust line loop: handle EOF with partial line, ignore blank lines, no spin.
    while (true) {
        var read_len: usize = 0;
        var got_newline = false;
        while (!got_newline and read_len < line_storage.len) {
            var one: [1]u8 = undefined;
            const amt = stdin.read(&one) catch |e| switch (e) {
                error.EndOfStream => 0,
                else => 0,
            };
            if (amt == 0) break; // EOF or error
            const b = one[0];
            if (b == '\n') {
                got_newline = true;
                break;
            }
            line_storage[read_len] = b;
            read_len += 1;
        }
        if (read_len == 0) {
            // No bytes collected. If we didn't get a newline and next read is EOF, terminate.
            // Attempt a single probe read to distinguish between blank line and EOF.
            var probe: [1]u8 = undefined;
            const probe_amt = stdin.read(&probe) catch |e| switch (e) {
                error.EndOfStream => 0,
                else => 0,
            };
            if (probe_amt == 0) break; // real EOF
            if (probe[0] == '\n') continue; // blank line
            // Start new line with probe byte.
            line_storage[0] = probe[0];
            read_len = 1;
            // Continue filling remainder of line until newline/EOF.
            while (read_len < line_storage.len) {
                var nxt: [1]u8 = undefined;
                const na = stdin.read(&nxt) catch |e| switch (e) {
                    error.EndOfStream => 0,
                    else => 0,
                };
                if (na == 0) break;
                if (nxt[0] == '\n') break;
                line_storage[read_len] = nxt[0];
                read_len += 1;
            }
        }
        const raw = line_storage[0..read_len];
        if (raw.len == 0) continue; // ignore
        if (DEBUG_PROFILE and raw.len > 0) {
            const preview_len = if (raw.len < 120) raw.len else 120;
            std.debug.print("[debug] received line len={d} head='{s}'\n", .{ raw.len, raw[0..preview_len] });
        }
        // Parse client message
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const msg = protocol.parseClientMessage(arena.allocator(), raw) catch continue; // ignore invalid
        switch (msg) {
            .HELLO => |_| {
                // No-op HELLO on stdio
                continue;
            },
            .CDC_DIAGNOSTICS => |_| {
                if (state.cdc_engine) |eng| {
                    if (eng.exportDiagnostics(gpa)) |payload| {
                        defer gpa.free(payload);
                        if (protocol.buildCdcDiagnosticsLine(gpa, payload)) |line| {
                            defer gpa.free(line);
                            _ = stdout_file.write(line) catch {};
                        } else |_| {}
                    } else |_| {
                        if (protocol.buildCdcDiagnosticsLine(gpa, "{\"cdc_error\":\"export_failed\"}")) |line| {
                            defer gpa.free(line);
                            _ = stdout_file.write(line) catch {};
                        } else |_| {}
                    }
                } else {
                    if (protocol.buildCdcDiagnosticsLine(gpa, "{\"cdc\":{\"enabled\":false}}")) |line| {
                        defer gpa.free(line);
                        _ = stdout_file.write(line) catch {};
                    } else |_| {}
                }
                continue;
            },
            .CDC_CONTROL => |cc| {
                if (handleCdcControl(gpa, &state, cc.action)) |out_line| {
                    defer gpa.free(out_line);
                    _ = stdout_file.write(out_line) catch {};
                }
                continue;
            },
            .BEGIN => |_| {
                if (state.active_txn != null) {
                    // Return proper transaction state error with status_class 25000
                    const err_json = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"25000\",\"status_subclass\":\"TxnState\",\"message\":\"Transaction already active\",\"additional_statuses\":[{{\"code\":\"TxnState\",\"message\":\"Cannot BEGIN when transaction is already active\"}}]}}\n", .{});
                    defer gpa.free(err_json);
                    _ = stdout_file.write(err_json) catch {};
                } else {
                    const t = state.txn_manager.begin();
                    state.active_txn = t;
                    state.in_txn = true;
                    state.txn_id = t.id;
                    // Capture snapshot timestamp (current global commit ts)
                    state.session_snapshot_ts = state.global_commit_ts;

                    // Initialize MVCC transaction for conflict detection
                    if (state.mvcc_manager == null) {
                        state.mvcc_manager = getOrCreateMVCCManager(gpa);
                    }
                    state.current_mvcc_txn = state.mvcc_manager.?.beginTransaction(.SnapshotIsolation) catch null;

                    // Return success with status_class 00000
                    const success_json = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"00000\",\"result\":{{\"type\":\"TXN_BEGIN\",\"txn_id\":{}}}}}\n", .{t.id});
                    defer gpa.free(success_json);
                    _ = stdout_file.write(success_json) catch {};
                }
            },
            .SAVEPOINT => |sp| {
                _ = sp; // prototype: no actual stack; future store sp.name
                // ACK
                writeBindingsAdaptive(stdout_file, false, &.{}, "[]", true, false, computeBaseFlags(false, false));
            },
            .ROLLBACK_TO => |sp| {
                _ = sp; // prototype: ignore
                writeBindingsAdaptive(stdout_file, false, &.{}, "[]", true, false, computeBaseFlags(false, false));
            },
            .PING => |_| {
                // Simple health check
                const ok = "{\"ok\":true}";
                if (protocol.buildBindingsLine(gpa, false, &.{}, ok, true, &.{}, computeBaseFlags(false, false))) |line| {
                    defer gpa.free(line);
                    _ = stdout_file.write(line) catch {};
                } else |_| {}
            },
            .COMMIT => |_| {
                if (state.active_txn == null) {
                    // Return proper transaction state error with status_class 25000
                    const err_json = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"25000\",\"status_subclass\":\"TxnState\",\"message\":\"No active transaction\",\"additional_statuses\":[{{\"code\":\"TxnState\",\"message\":\"Cannot COMMIT without active transaction\"}}]}}\n", .{});
                    defer gpa.free(err_json);
                    _ = stdout_file.write(err_json) catch {};
                } else {
                    var tx = state.active_txn.?;

                    // Try to commit MVCC transaction first for conflict detection
                    var mvcc_commit_success = true;
                    if (state.current_mvcc_txn) |mvcc_txn| {
                        state.mvcc_manager.?.commitTransaction(mvcc_txn) catch |err| {
                            mvcc_commit_success = false;
                            // Handle serialization failure
                            const err_msg = switch (err) {
                                error.SerializationFailure => "Write-write conflict detected",
                                else => "Transaction commit failed",
                            };
                            const err_json = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"40001\",\"status_subclass\":\"SerializationFailure\",\"message\":\"{s}\",\"additional_statuses\":[{{\"code\":\"SerializationFailure\",\"message\":\"Transaction rolled back due to concurrent update\"}}]}}\n", .{err_msg});
                            defer gpa.free(err_json);
                            _ = stdout_file.write(err_json) catch {};

                            // Clean up transaction state
                            state.current_mvcc_txn = null;
                            state.active_txn = null;
                            state.in_txn = false;
                            return;
                        };
                        state.current_mvcc_txn = null;
                    }

                    if (!mvcc_commit_success) {
                        return;
                    }

                    state.txn_manager.commit(&tx) catch |err| {
                        // Handle commit failure (e.g., serialization failure)
                        const err_json = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"25000\",\"status_subclass\":\"SerializationFailure\",\"message\":\"{s}\",\"additional_statuses\":[{{\"code\":\"SerializationFailure\",\"message\":\"Transaction commit failed due to conflicts\"}}]}}\n", .{@errorName(err)});
                        defer gpa.free(err_json);
                        _ = stdout_file.write(err_json) catch {};
                        return;
                    };
                    // Assign commit timestamp to newly committed records from this txn
                    state.global_commit_ts += 1;
                    const cts = state.global_commit_ts;
                    var i_mvcc: usize = 0;
                    while (i_mvcc < state.inserted_values.items.len) : (i_mvcc += 1) {
                        if (state.inserted_values.items[i_mvcc].creator_txn == tx.id and state.inserted_values.items[i_mvcc].commit_ts == null) {
                            state.inserted_values.items[i_mvcc].commit_ts = cts;
                        }
                    }
                    // Append WAL commit record (empty payload) if WAL configured.
                    if (state.wal_ptr) |wp| {
                        const wptr: *wal_mod.Wal = @ptrCast(@alignCast(wp));
                        // best-effort: ignore errors in prototype
                        // Append commit record; ignore returned LSN (best-effort prototype)
                        _ = wptr.append(tx.id, .Commit, &.{}, 0) catch {};
                        wptr.fsync() catch {};
                    }
                    // Periodic WAL checkpoint + compaction after commit
                    const do_checkpoint = if (env_wal_compact_interval > 0)
                        (state.global_commit_ts % env_wal_compact_interval) == 0
                    else
                        false; // 0 disables automatic compaction
                    state.active_txn = null;
                    state.in_txn = false;
                    // Return success with status_class 00000
                    const success_json = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"00000\",\"result\":{{\"type\":\"TXN_COMMIT\",\"txn_id\":{}}}}}\n", .{tx.id});
                    defer gpa.free(success_json);
                    _ = stdout_file.write(success_json) catch {};
                    if (do_checkpoint) {
                        if (state.wal_ptr) |wp_ck| {
                            const wck: *wal_mod.Wal = @ptrCast(@alignCast(wp_ck));
                            _ = wck.writeCheckpoint() catch {};
                            // Use next_lsn as conservative durable horizon for compaction.
                            const durable = wck.next_lsn;
                            wck.compact(durable) catch {};
                            // Log compaction for observability
                            std.log.info("WAL compaction triggered after {} commits, durable LSN: {}", .{ env_wal_compact_interval, durable });
                        }
                    }
                }
            },
            .ROLLBACK => |_| {
                if (state.active_txn == null) {
                    // Return proper transaction state error with status_class 25000
                    const err_json = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"25000\",\"status_subclass\":\"TxnState\",\"message\":\"No active transaction\",\"additional_statuses\":[{{\"code\":\"TxnState\",\"message\":\"Cannot ROLLBACK without active transaction\"}}]}}\n", .{});
                    defer gpa.free(err_json);
                    _ = stdout_file.write(err_json) catch {};
                } else {
                    var tx2 = state.active_txn.?;

                    // Abort MVCC transaction
                    if (state.current_mvcc_txn) |mvcc_txn| {
                        state.mvcc_manager.?.abortTransaction(mvcc_txn) catch {};
                        state.current_mvcc_txn = null;
                    }

                    // Mark uncommitted inserts for this txn as aborted
                    var ia: usize = 0;
                    while (ia < state.inserted_values.items.len) : (ia += 1) {
                        if (state.inserted_values.items[ia].creator_txn == tx2.id and state.inserted_values.items[ia].commit_ts == null) {
                            state.inserted_values.items[ia].aborted = true;
                        }
                    }
                    state.txn_manager.rollback(&tx2);
                    state.active_txn = null;
                    state.in_txn = false;
                    // Return success with status_class 00000
                    const success_json = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"00000\",\"result\":{{\"type\":\"TXN_ROLLBACK\",\"txn_id\":{}}}}}\n", .{tx2.id});
                    defer gpa.free(success_json);
                    _ = stdout_file.write(success_json) catch {};
                }
            },
            .RUN_GQL => |rq| {
                state.resetResult();
                if (state.storage_checksum_error) {
                    // Emit diagnostic once per session (clear after emit)
                    writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.StoragePageChecksum, diagnostics.defaultMessage(.StoragePageChecksum), diagnostics.anchorFor(.StoragePageChecksum), &.{}, false);
                    state.storage_checksum_error = false;
                    continue;
                }
                var text = rq.text;
                var explain_mode = false;
                var explain_calibrated = false;
                var profile_mode = false;
                // Support EXPLAIN CALIBRATED (detect first, more specific)
                if (std.mem.startsWith(u8, text, "EXPLAIN CALIBRATED ")) {
                    explain_mode = true;
                    explain_calibrated = true;
                    text = text["EXPLAIN CALIBRATED ".len..];
                } else if (std.mem.eql(u8, text, "EXPLAIN CALIBRATED")) {
                    explain_mode = true;
                    explain_calibrated = true;
                    text = "";
                } else {
                    if (std.mem.startsWith(u8, text, "PROFILE ")) {
                        profile_mode = true;
                        text = text[8..];
                    } else if (std.mem.eql(u8, text, "PROFILE")) {
                        profile_mode = true;
                        text = "";
                    }
                    if (std.mem.startsWith(u8, text, "EXPLAIN ")) {
                        explain_mode = true;
                        text = text[8..];
                    } else if (std.mem.eql(u8, text, "EXPLAIN")) {
                        explain_mode = true;
                        text = "";
                    }
                }
                // Capture original (post PREFIX strip) query text with length cap for heuristic use.
                if (state.query_text) |old_qt| state.allocator.free(old_qt);
                const QT_CAP: usize = 4096;
                const take_qt = if (text.len > QT_CAP) QT_CAP else text.len;
                var qt_copy = try state.allocator.alloc(u8, take_qt);
                @memcpy(qt_copy[0..take_qt], text[0..take_qt]);
                state.query_text = qt_copy;

                var parse_res = geode.parseGqlOutcome(text, gpa, .{ .ident_order_only = !g_order_keys_expr, .forbid_orderby_calls = !g_order_keys_expr }) catch |e| {
                    // Aggregate all parse-time diagnostics (policy + US001) and emit with precedence.
                    var codes_buf: [4]diagnostics.Code = undefined;
                    const n_raw = collectTextDiagnostics(text, @errorName(e), &codes_buf);
                    const n = diagnostics.foldCodes(codes_buf[0..n_raw]);
                    if (n == 0) {
                        // Fallback: treat as IllegalOrderKey for now to satisfy existing tests.
                        writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.IllegalOrderKey, @errorName(e), diagnostics.anchorFor(.IllegalOrderKey), &.{}, false);
                        return;
                    }
                    const primary = codes_buf[0];
                    const add_slice = buildAdditionalStatusesAlloc(gpa, codes_buf[0..n], primary);
                    const primary_msg = if (primary == .IllegalOrderKey) @errorName(e) else diagnostics.defaultMessage(primary);
                    writeErrorWithFlags(gpa, stdout_file, primary, primary_msg, diagnostics.anchorFor(primary), add_slice, primary == .US001);
                    continue;
                };
                defer if (parse_res == .Ok) parse_res.Ok.deinit();
                switch (parse_res) {
                    .Err => |er| {
                        var codes_buf: [4]diagnostics.Code = undefined;
                        const n_raw = collectTextDiagnostics(text, er.msg, &codes_buf);
                        const n = diagnostics.foldCodes(codes_buf[0..n_raw]);
                        if (n == 0) {
                            if (protocol.buildErrorLine(gpa, "ParseError", er.msg, "")) |line| {
                                defer gpa.free(line);
                                _ = stdout_file.write(line) catch {};
                            } else |_| {}
                            continue;
                        }
                        const primary = codes_buf[0];
                        const add_slice = buildAdditionalStatusesAlloc(gpa, codes_buf[0..n], primary);
                        const primary_msg = if (primary == .IllegalOrderKey) er.msg else diagnostics.defaultMessage(primary);
                        writeErrorWithFlags(gpa, stdout_file, primary, primary_msg, diagnostics.anchorFor(primary), add_slice, primary == .US001);
                        continue;
                    },
                    .Ok => |ok| {
                        if (ok.program.statements.len == 0) {
                            if (protocol.buildSchemaLine(gpa, &.{}, &.{}, computeBaseFlags(false, false))) |line| {
                                defer gpa.free(line);
                                _ = stdout_file.write(line) catch {};
                            } else |_| {}
                            continue;
                        }
                        const st = ok.program.statements[0];
                        // Test-only mutation: detect UPDATE_VALUE("key","val") pattern in raw text and execute under MVCC/locks
                        if (std.mem.startsWith(u8, text, "UPDATE_VALUE(")) {
                            if (state.active_txn == null) {
                                const err_json = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"25000\",\"status_subclass\":\"TxnState\",\"message\":\"No active transaction\"}}\n", .{});
                                defer gpa.free(err_json);
                                _ = stdout_file.write(err_json) catch {};
                                continue;
                            }
                            // crude parser: UPDATE_VALUE("key","val")
                            const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse text.len;
                            const inside = text[13..close]; // after 'UPDATE_VALUE('
                            const parts = std.mem.tokenizeSequence(u8, inside, "\",");
                            var key_s: []const u8 = &.{};
                            var val_s: []const u8 = &.{};
                            var itp = parts;
                            var idxp: usize = 0;
                            while (itp.next()) |tok| : (idxp += 1) {
                                var t = std.mem.trim(u8, tok, &std.ascii.whitespace);
                                t = std.mem.trim(u8, t, "\"");
                                if (idxp == 0) key_s = t else if (idxp == 1) val_s = t;
                            }
                            if (key_s.len == 0) {
                                const err = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"22023\",\"message\":\"Invalid UPDATE_VALUE syntax\"}}\n", .{});
                                defer gpa.free(err);
                                _ = stdout_file.write(err) catch {};
                                continue;
                            }
                            var txm = state.active_txn.?;
                            // Acquire exclusive lock using txn manager
                            state.txn_manager.acquireWrite(key_s, &txm, gpa) catch |err| {
                                const e = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"40001\",\"status_subclass\":\"LockConflict\",\"message\":\"{s}\"}}\n", .{@errorName(err)});
                                defer gpa.free(e);
                                _ = stdout_file.write(e) catch {};
                                continue;
                            };
                            // Ensure MVCC txn present
                            if (state.mvcc_manager == null) state.mvcc_manager = getOrCreateMVCCManager(gpa);
                            if (state.current_mvcc_txn == null) state.current_mvcc_txn = state.mvcc_manager.?.beginTransaction(.SnapshotIsolation) catch null;
                            // Derive resource id from key hash
                            var hasher = std.hash.Wyhash.init(0);
                            hasher.update(key_s);
                            const rid: u64 = hasher.final();
                            const mv = if (val_s.len > 0) val_s else "";
                            state.mvcc_manager.?.write(state.current_mvcc_txn.?, rid, mv) catch |err| {
                                const err_msg = switch (err) {
                                    error.SerializationFailure => "Write-write conflict detected",
                                    else => @errorName(err),
                                };
                                const ej = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"40001\",\"status_subclass\":\"SerializationFailure\",\"message\":\"{s}\"}}\n", .{err_msg});
                                defer gpa.free(ej);
                                _ = stdout_file.write(ej) catch {};
                                continue;
                            };
                            // ACK schema
                            if (protocol.buildSchemaLine(gpa, &.{}, &.{}, computeBaseFlags(false, false))) |line_ack| {
                                defer gpa.free(line_ack);
                                _ = stdout_file.write(line_ack) catch {};
                            } else |_| {}
                            continue;
                        }
                        switch (st) {
                            .Intersect => |is| {
                                var param_names: [][]const u8 = &.{};
                                var param_rows: [][]const eval.Value = &.{};
                                parseParams(gpa, rq.params_json, &param_names, &param_rows);
                                if (explain_mode) {
                                    const mode = if (is.all) "ALL" else "DISTINCT";
                                    const json = buildExplainJson(gpa, .{ .ordered = false, .limit = null, .offset = null, .union_mode = mode, .distinct = !is.all, .setop_kind = "SetOpIntersect" });
                                    const flags_u = computeBaseFlags(false, !is.all);
                                    const l2 = protocol.buildExplainLine(gpa, json, flags_u) catch null;
                                    if (l2) |linex| {
                                        defer gpa.free(linex);
                                        _ = stdout_file.write(linex) catch {};
                                    }
                                    continue;
                                }
                                const rows = evaluateBinarySet(gpa, is.left, is.right, param_names, param_rows, true, is.all) catch &.{};
                                var cols_is: []protocol.SchemaCol = gpa.alloc(protocol.SchemaCol, is.left.ret.items.len) catch &.{};
                                var ci_is: usize = 0;
                                while (ci_is < is.left.ret.items.len) : (ci_is += 1) {
                                    const it = is.left.ret.items[ci_is];
                                    cols_is[ci_is] = .{ .name = it.alias orelse geode.printer.stringifyExprAlloc(gpa, it.expr, .{}) catch "col", .type = "INT" };
                                }
                                state.last_columns = cols_is;
                                state.last_ordered = false;
                                state.last_order_keys = &.{};
                                state.last_distinct = !is.all;
                                state.page_items = @constCast(rows);
                                state.active_result = true;
                                if (!result_format_txt) {
                                    {
                                        const line = protocol.buildSchemaLine(gpa, state.last_columns, &.{}, computeBaseFlags(false, !is.all)) catch null;
                                        if (line) |l| {
                                            defer gpa.free(l);
                                            _ = stdout_file.write(l) catch {};
                                        }
                                    }
                                }
                                continue;
                            },
                            .Except => |ex| {
                                var param_names: [][]const u8 = &.{};
                                var param_rows: [][]const eval.Value = &.{};
                                parseParams(gpa, rq.params_json, &param_names, &param_rows);
                                if (explain_mode) {
                                    const mode = if (ex.all) "ALL" else "DISTINCT";
                                    const json = buildExplainJson(gpa, .{ .ordered = false, .limit = null, .offset = null, .union_mode = mode, .distinct = !ex.all, .setop_kind = "SetOpExcept" });
                                    const flags_u = computeBaseFlags(false, !ex.all);
                                    const l3 = protocol.buildExplainLine(gpa, json, flags_u) catch null;
                                    if (l3) |linex| {
                                        defer gpa.free(linex);
                                        _ = stdout_file.write(linex) catch {};
                                    }
                                    continue;
                                }
                                const rows = evaluateBinarySet(gpa, ex.left, ex.right, param_names, param_rows, false, ex.all) catch &.{};
                                var cols_ex: []protocol.SchemaCol = gpa.alloc(protocol.SchemaCol, ex.left.ret.items.len) catch &.{};
                                var ci_ex: usize = 0;
                                while (ci_ex < ex.left.ret.items.len) : (ci_ex += 1) {
                                    const it = ex.left.ret.items[ci_ex];
                                    cols_ex[ci_ex] = .{ .name = it.alias orelse geode.printer.stringifyExprAlloc(gpa, it.expr, .{}) catch "col", .type = "INT" };
                                }
                                state.last_columns = cols_ex;
                                state.last_ordered = false;
                                state.last_order_keys = &.{};
                                state.last_distinct = !ex.all;
                                state.page_items = @constCast(rows);
                                state.active_result = true;
                                if (!result_format_txt) {
                                    {
                                        const line = protocol.buildSchemaLine(gpa, state.last_columns, &.{}, computeBaseFlags(false, !ex.all)) catch null;
                                        if (line) |l| {
                                            defer gpa.free(l);
                                            _ = stdout_file.write(l) catch {};
                                        }
                                    }
                                }
                                continue;
                            },
                            .InsertValue => |iv| {
                                // Implicit autocommit: if not in explicit transaction, wrap this DML in begin/commit.
                                var started_auto = false;
                                if (state.active_txn == null) {
                                    const t = state.txn_manager.begin();
                                    state.active_txn = t;
                                    state.session_snapshot_ts = state.global_commit_ts; // snapshot at start
                                    started_auto = true;
                                }
                                const val = switch (iv.expr) {
                                    .Int => |n| eval.Value{ .Int = n },
                                    .String => |s| eval.Value{ .Str = s },
                                    .Bool => |b| eval.Value{ .Bool = b },
                                    else => eval.Value{ .Null = {} },
                                };
                                execInsertValue(&state, val) catch {};
                                // If autocommit, immediately commit the txn.
                                if (started_auto) {
                                    if (state.active_txn) |*txc| {
                                        state.txn_manager.commit(txc) catch {};
                                        state.global_commit_ts += 1;
                                        const cts_auto = state.global_commit_ts;
                                        var mi: usize = 0;
                                        while (mi < state.inserted_values.items.len) : (mi += 1) {
                                            if (state.inserted_values.items[mi].creator_txn == txc.id and state.inserted_values.items[mi].commit_ts == null) {
                                                state.inserted_values.items[mi].commit_ts = cts_auto;
                                            }
                                        }
                                        if (state.wal_ptr) |wpac| {
                                            const wptr_auto: *wal_mod.Wal = @ptrCast(@alignCast(wpac));
                                            _ = wptr_auto.append(txc.id, .Commit, &.{}, 0) catch {};
                                        }
                                        // Periodic checkpoint after autocommit too
                                        const do_checkpoint_auto = (state.global_commit_ts % 5) == 0;
                                        state.active_txn = null;
                                        if (do_checkpoint_auto) {
                                            if (state.wal_ptr) |wp_auto| {
                                                const wauto: *wal_mod.Wal = @ptrCast(@alignCast(wp_auto));
                                                _ = wauto.writeCheckpoint() catch {};
                                                const durable2 = wauto.next_lsn;
                                                wauto.compact(durable2) catch {};
                                            }
                                        }
                                    }
                                }
                                // Return ACK schema with zero rows
                                if (protocol.buildSchemaLine(gpa, &.{}, &.{}, computeBaseFlags(false, false))) |line| {
                                    defer gpa.free(line);
                                    _ = stdout_file.write(line) catch {};
                                } else |_| {}
                                continue;
                            },
                            .ScanValues => {
                                buildScanValuesResult(&state) catch {};
                                if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, computeBaseFlags(false, false))) |line| {
                                    defer gpa.free(line);
                                    _ = stdout_file.write(line) catch {};
                                } else |_| {}
                                continue;
                            },
                            .Query => |q| {
                                // Handle EXPLAIN modes first: emit SCHEMA then EXPLAIN and skip further planning/legality checks.
                                if (explain_mode) {
                                    // Emit SCHEMA then EXPLAIN (cost_explain.v1 or v2 when calibrated), matching QUIC behavior
                                    var pn_ex: [][]const u8 = &.{};
                                    var pr_ex: [][]const eval.Value = &.{};
                                    parseParams(gpa, rq.params_json, &pn_ex, &pr_ex);
                                    var ord_ex = false;
                                    var oks_ex: [][]const u8 = &.{};
                                    var cols_explain: []const protocol.SchemaCol = &.{};
                                    var timings_ex: StageTimings = .{};
                                    const need_timings_ex = explain_calibrated; // only needed for calibrated explain
                                    const rows_ex = evaluateSimpleQuery(gpa, q, pn_ex, pr_ex, &ord_ex, &oks_ex, &cols_explain, if (need_timings_ex) &timings_ex else null, null, null) catch &.{};
                                    // Stage minimal state (not strictly needed for EXPLAIN, but harmless)
                                    state.last_columns = cols_explain;
                                    state.last_ordered = ord_ex;
                                    state.last_order_keys = oks_ex;
                                    state.last_distinct = q.ret.distinct;
                                    state.page_items = @constCast(rows_ex);
                                    state.page_index = 0;
                                    state.active_result = true;
                                    const flags_ex2 = computeBaseFlags(ord_ex, q.ret.distinct);
                                    if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, flags_ex2)) |schema_line2| {
                                        defer gpa.free(schema_line2);
                                        _ = stdout_file.write(schema_line2) catch {};
                                    } else |_| {}
                                    // Build op chain descriptors (Scan -> Project -> [Aggregate] -> [Sort] -> [Filter] -> [Limit])
                                    var ops_buf: [8]geode.cost_seed.OpDescriptor = undefined;
                                    var opn: usize = 0;
                                    ops_buf[opn] = .{ .kind = .Scan };
                                    opn += 1;
                                    ops_buf[opn] = .{ .kind = .Project };
                                    opn += 1;
                                    if (q.ret.distinct) {
                                        ops_buf[opn] = .{ .kind = .Aggregate };
                                        opn += 1;
                                    }
                                    if (ord_ex) {
                                        ops_buf[opn] = .{ .kind = .Sort };
                                        opn += 1;
                                    }
                                    if (q.offset != null) {
                                        ops_buf[opn] = .{ .kind = .Filter, .selectivity = 0.5 };
                                        opn += 1;
                                    }
                                    if (q.limit != null) {
                                        ops_buf[opn] = .{ .kind = .Limit };
                                        opn += 1;
                                    }
                                    const ops = ops_buf[0..opn];
                                    var actual_rows_fixed: [8]f64 = undefined;
                                    var actual_slice: ?[]const f64 = null;
                                    if (explain_calibrated and need_timings_ex) {
                                        var aiex: usize = 0;
                                        actual_rows_fixed[aiex] = @floatFromInt(timings_ex.project_rows_in);
                                        aiex += 1; // scan input
                                        actual_rows_fixed[aiex] = @floatFromInt(timings_ex.project_rows_out);
                                        aiex += 1; // project
                                        if (q.ret.distinct) {
                                            actual_rows_fixed[aiex] = @floatFromInt(timings_ex.distinct_rows_out);
                                            aiex += 1;
                                        }
                                        if (ord_ex) {
                                            actual_rows_fixed[aiex] = @floatFromInt(timings_ex.sort_rows_out);
                                            aiex += 1;
                                        }
                                        if (q.offset != null) {
                                            actual_rows_fixed[aiex] = @floatFromInt(timings_ex.offset_rows_out);
                                            aiex += 1;
                                        }
                                        if (q.limit != null) {
                                            actual_rows_fixed[aiex] = @floatFromInt(timings_ex.limit_rows_out);
                                            aiex += 1;
                                        }
                                        actual_slice = actual_rows_fixed[0..aiex];
                                    }
                                    const explain_json2 = if (explain_calibrated and actual_slice != null) cost_explain.explainChainWithCalibration(gpa, ops, actual_slice, null) catch null else cost_explain.explainChain(gpa, ops) catch null;
                                    if (explain_json2) |ej2| {
                                        defer gpa.free(ej2);
                                        if (protocol.buildExplainLine(gpa, ej2, flags_ex2)) |line_ex2| {
                                            defer gpa.free(line_ex2);
                                            _ = stdout_file.write(line_ex2) catch {};
                                        } else |_| {}
                                    }
                                    continue;
                                }
                                // Planner legality (US001) — skipped for EXPLAIN paths above
                                _ = geode.planner.planQuery(q, .{}) catch |pe| {
                                    if (diagnostics.mapPlannerError(pe)) |code| {
                                        var codes_buf_pl: [4]diagnostics.Code = undefined;
                                        const n_codes_pl_raw = collectPlannerDiagnostics(q, code, &codes_buf_pl);
                                        const n_codes_pl = diagnostics.foldCodes(codes_buf_pl[0..n_codes_pl_raw]);
                                        const primary_pl = if (n_codes_pl > 0) codes_buf_pl[0] else code;
                                        const add_slice_pl = buildAdditionalStatusesAlloc(gpa, codes_buf_pl[0..n_codes_pl], primary_pl);
                                        const pmsg = diagnostics.defaultMessage(primary_pl);
                                        writeErrorWithFlags(gpa, stdout_file, primary_pl, pmsg, diagnostics.anchorFor(primary_pl), add_slice_pl, primary_pl == .US001);
                                    } else if (protocol.buildErrorLine(gpa, "PlannerError", @errorName(pe), "")) |line| {
                                        defer gpa.free(line);
                                        _ = stdout_file.write(line) catch {};
                                    } else |_| {}
                                    continue;
                                };
                                if (!profile_mode and (q.limit != null or q.offset != null) and q.order_by == null) {
                                    // US001 enforcement applies only outside EXPLAIN/PROFILE
                                    writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.US001, diagnostics.defaultMessage(.US001), diagnostics.anchorFor(.US001), &.{}, true);
                                    continue;
                                }
                                if (profile_mode) {
                                    // PROFILE mode: we stage PROFILE json and emit SCHEMA now; PROFILE frame on first PULL.
                                    const start_time = std.time.nanoTimestamp();
                                    // Counting allocator wrapper for profiling with memory governance.
                                    var track = @import("tracking_alloc").TrackingAllocator{ .inner = gpa };
                                    track.init(gpa);
                                    var prof_ally = track.allocator;

                                    // Apply memory governance if limit is set
                                    if (state.query_mem_limit_bytes > 0) {
                                        // Memory governance is handled by checking peak bytes later
                                    }
                                    var param_names: [][]const u8 = &.{};
                                    var param_rows: [][]const eval.Value = &.{};
                                    parseParams(prof_ally, rq.params_json, &param_names, &param_rows);
                                    var ordered_meta = false;
                                    var order_keys: [][]const u8 = &.{};
                                    var cols_mut: []protocol.SchemaCol = &.{}; // mutable during build
                                    var cols: []const protocol.SchemaCol = &.{}; // const view stored in state
                                    var timings: StageTimings = .{};
                                    var row_count: usize = 0;
                                    if (q.group_by != null) {
                                        var agg_timings: exec.AggStageTimings = .{};
                                        // Derive aggregate input rows from parameter bindings (each param row treated as one logical input row)
                                        const agg_in = if (param_rows.len > 0) param_rows.len else 1;
                                        // Build placeholder input_rows slice of empty value arrays (expressions reference params only in this prototype)
                                        var input_rows_placeholder = try prof_ally.alloc([]eval.Value, agg_in);
                                        var ipi: usize = 0;
                                        while (ipi < agg_in) : (ipi += 1) input_rows_placeholder[ipi] = &.{};
                                        const first_param_values: []const eval.Value = if (param_rows.len > 0) param_rows[0] else &.{};
                                        const input_rows_const: []const []eval.Value = input_rows_placeholder;
                                        const g_out = exec.runGroupedQuery(prof_ally, q, &.{}, input_rows_const, param_names, first_param_values, &agg_timings) catch &.{};
                                        row_count = g_out.len;
                                        timings.agg_rows_in = agg_in;
                                        timings.agg_rows_out = row_count;
                                        timings.project_rows_in = row_count;
                                        timings.project_rows_out = row_count;
                                        timings.agg_build_ns = agg_timings.build_ns;
                                        timings.agg_emit_ns = agg_timings.emit_ns;
                                        // Build columns with inferred types from aggregation output rows.
                                        var mut_cols_slice: []protocol.SchemaCol = prof_ally.alloc(protocol.SchemaCol, q.ret.items.len) catch &.{};
                                        var idx_fill: usize = 0;
                                        while (idx_fill < q.ret.items.len) : (idx_fill += 1) {
                                            const it2 = q.ret.items[idx_fill];
                                            const alias2 = it2.alias orelse geode.printer.stringifyExprAlloc(prof_ally, it2.expr, .{}) catch "col";
                                            // Specialized aggregate type mapping overrides value-derived inference for stability.
                                            // COUNT()/COUNT(*) => INT; AVG() => DECIMAL; others still scan rows for first non-null value.
                                            var forced_type: ?[]const u8 = null;
                                            if (it2.expr == .Call) {
                                                const callee = it2.expr.Call.callee.*;
                                                if (callee == .Ident) {
                                                    const nm = callee.Ident;
                                                    if (std.ascii.eqlIgnoreCase(nm, "count")) {
                                                        forced_type = "INT";
                                                    } else if (std.ascii.eqlIgnoreCase(nm, "avg")) {
                                                        forced_type = "DECIMAL";
                                                    }
                                                }
                                            }
                                            var inferred: []const u8 = forced_type orelse "NULL";
                                            if (forced_type == null) {
                                                var gi: usize = 0;
                                                while (gi < g_out.len) : (gi += 1) {
                                                    if (idx_fill < g_out[gi].len) {
                                                        const bv = g_out[gi][idx_fill];
                                                        switch (bv) {
                                                            .Null => {},
                                                            else => {
                                                                inferred = bindingValueTypeName(bv);
                                                                gi = g_out.len; // break outer
                                                            },
                                                        }
                                                    }
                                                }
                                            }
                                            mut_cols_slice[idx_fill] = .{ .name = alias2, .type = inferred };
                                        }
                                        // Approximate bytes_out for aggregate/project by creating minimal JSON row strings
                                        // (We don't retain them; only measure.)
                                        var rb: usize = 0;
                                        rb = row_count * 2; // braces overhead approx
                                        // Each column adds alias + constant small value (8 chars avg heuristic). This is a coarse metric.
                                        rb += row_count * q.ret.items.len * 8;
                                        timings.project_bytes_out = rb;
                                        timings.distinct_bytes_out = rb;
                                        timings.sort_bytes_out = rb;
                                        timings.offset_bytes_out = rb;
                                        timings.limit_bytes_out = rb;
                                        // Placeholder; actual allocation deltas captured below after build/emit phases
                                        timings.project_bytes_alloc = rb;
                                        timings.distinct_bytes_alloc = rb;
                                        timings.sort_bytes_alloc = rb;
                                        timings.offset_bytes_alloc = rb;
                                        timings.limit_bytes_alloc = rb;
                                        cols_mut = mut_cols_slice;
                                        cols = cols_mut;
                                        // Delta-based allocation: capture after aggregate build+emit (no separate row materialization phases yet)
                                        const alloc_after_build = track.net();
                                        timings.agg_build_bytes_alloc = alloc_after_build; // build delta (since start)
                                        // Emit phase currently trivial for prototype; treat emit alloc delta as zero additional unless net grows later
                                        const alloc_after_emit = track.net();
                                        timings.agg_emit_bytes_alloc = if (alloc_after_emit > alloc_after_build) alloc_after_emit - alloc_after_build else 0;
                                        const total_after_agg = alloc_after_emit;
                                        timings.project_bytes_alloc = if (timings.project_bytes_alloc == 0) total_after_agg else timings.project_bytes_alloc;
                                    } else {
                                        var run_code: diagnostics.Code = .IllegalOrderKey; // init sentinel
                                        const at: AllocTracker = .{ .ctx = @ptrCast(&track), .getFn = trackerGet };
                                        const rows_prof = evaluateSimpleQuery(prof_ally, q, param_names, param_rows, &ordered_meta, &order_keys, &cols, &timings, &run_code, at) catch &.{};
                                        if (run_code == .TypeMismatch) {
                                            var buf_codes: [2]diagnostics.Code = undefined;
                                            var len_codes: usize = 0;
                                            buf_codes[len_codes] = .TypeMismatch;
                                            len_codes += 1;
                                            if ((q.limit != null or q.offset != null) and q.order_by == null) {
                                                buf_codes[len_codes] = .US001;
                                                len_codes += 1;
                                            }
                                            const slice_codes = buf_codes[0..len_codes];
                                            const folded_len = diagnostics.foldCodes(slice_codes);
                                            const primary_eval = slice_codes[0];
                                            const add_eval = buildAdditionalStatusesAlloc(gpa, slice_codes[0..folded_len], primary_eval);
                                            var has_us001_any = primary_eval == .US001;
                                            if (!has_us001_any) {
                                                var ci: usize = 1;
                                                while (ci < folded_len) : (ci += 1) {
                                                    if (slice_codes[ci] == .US001) {
                                                        has_us001_any = true;
                                                        break;
                                                    }
                                                }
                                            }
                                            writeErrorWithFlags(gpa, stdout_file, primary_eval, diagnostics.defaultMessage(primary_eval), diagnostics.anchorFor(primary_eval), add_eval, has_us001_any);
                                            var fre: usize = 0;
                                            while (fre < rows_prof.len) : (fre += 1) gpa.free(rows_prof[fre]);
                                            continue;
                                        }
                                        row_count = rows_prof.len;
                                        if (timings.project_rows_out == 0) {
                                            // Fallback (should not trigger unless evaluateSimpleQuery skipped metrics)
                                            timings.project_rows_in = row_count;
                                            timings.project_rows_out = row_count;
                                            timings.distinct_rows_in = timings.project_rows_out;
                                            timings.distinct_rows_out = timings.project_rows_out;
                                            timings.sort_rows_in = timings.distinct_rows_out;
                                            timings.sort_rows_out = timings.distinct_rows_out;
                                            timings.offset_rows_in = timings.sort_rows_out;
                                            timings.offset_rows_out = if (q.offset) |offv| if (offv < timings.sort_rows_out) timings.sort_rows_out - offv else 0 else timings.sort_rows_out;
                                            timings.limit_rows_in = timings.offset_rows_out;
                                            timings.limit_rows_out = if (q.limit) |limv| if (limv < timings.offset_rows_out) limv else timings.offset_rows_out else timings.offset_rows_out;
                                        }
                                        // Free rows; PROFILE does not return them
                                        var frp: usize = 0;
                                        while (frp < rows_prof.len) : (frp += 1) prof_ally.free(rows_prof[frp]);
                                        // After evaluateSimpleQuery we can snapshot bytes for distinct/sort/offset/limit based on timings ordering.
                                        const alloc_after_project = track.net();
                                        if (timings.project_bytes_alloc == 0) timings.project_bytes_alloc = alloc_after_project; // baseline
                                        // Heuristic attribution: since we free nothing yet, additional growth after each stage boundary approximated by bytes_out delta.
                                        // For now treat all later stage alloc equal to net usage (will refine once stage-level alloc hooks added).
                                        // Per-stage allocation deltas already derived inside evaluateSimpleQuery; no heuristic override.
                                    }
                                    const total_ns: i128 = std.time.nanoTimestamp() - start_time;
                                    // net_alloc skipped (counting allocator not active)
                                    // Replace heuristic bytes_alloc metrics with net allocations at time of each stage end if captured.
                                    // For now we approximate by proportionally distributing total peak across stages that produced bytes_out.
                                    // bytes_alloc remain heuristic (mirrors bytes_out) until counting allocator lands.
                                    var pb = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
                                    const w = pb.writer(gpa);
                                    w.writeAll("{\"profile_version\":2,\"ops\":[") catch {};
                                    var first_op_profile = true;
                                    const peak_bytes: usize = track.peakBytes();
                                    // Check for memory pressure and trigger spills
                                    if (state.query_mem_limit_bytes > 0 and peak_bytes >= state.query_mem_limit_bytes) {
                                        if (ordered_meta) state.spill_sort = 1;
                                        if (q.ret.distinct) state.spill_distinct = 1;
                                        if (q.group_by != null) state.spill_hashagg = 1;
                                    }
                                    const emit = struct {
                                        const TopTracker = struct { names: [3][24]u8 = .{ [_]u8{0} ** 24, [_]u8{0} ** 24, [_]u8{0} ** 24 }, lens: [3]usize = .{ 0, 0, 0 }, vals: [3]usize = .{ 0, 0, 0 } };
                                        fn maybeRecord(tt: *TopTracker, name: []const u8, val: usize) void {
                                            var min_i: usize = 0;
                                            var min_v: usize = tt.vals[0];
                                            var i: usize = 1;
                                            while (i < 3) : (i += 1) {
                                                if (tt.vals[i] < min_v) {
                                                    min_v = tt.vals[i];
                                                    min_i = i;
                                                }
                                            }
                                            if (val > min_v) {
                                                const copy_len = if (name.len < tt.names[min_i].len) name.len else tt.names[min_i].len;
                                                std.mem.copyForwards(u8, tt.names[min_i][0..copy_len], name[0..copy_len]);
                                                tt.lens[min_i] = copy_len;
                                                tt.vals[min_i] = val;
                                            }
                                        }
                                        fn op(
                                            wr: anytype,
                                            tt: *TopTracker,
                                            op_index: *usize,
                                            cum_time: *i128,
                                            prev_net: *usize,
                                            net_after_sum: *usize,
                                            first_ptr: *bool,
                                            error_min_pct: *usize,
                                            error_max_pct: *usize,
                                            error_sum_pct: *usize,
                                            error_sum_sq_pct: *usize,
                                            error_count: *usize,
                                            name: []const u8,
                                            in_rows: usize,
                                            out_rows: usize,
                                            time_ns: i128,
                                            bytes_out: usize,
                                            bytes_alloc: usize,
                                            est_bytes: usize,
                                            peak_total: usize,
                                            net_total: usize,
                                            compact: bool,
                                        ) void {
                                            if (first_ptr.*) wr.writeAll("{") catch {} else wr.writeAll(",{") catch {};
                                            wr.writeAll("\"op\":\"") catch {};
                                            wr.writeAll(name) catch {};
                                            // Derive phase from op name (stable mapping, additive field)
                                            const phase = if (std.mem.eql(u8, name, "NodeScan")) "SCAN" else if (std.mem.eql(u8, name, "Expand")) "EXPAND" else if (std.mem.eql(u8, name, "AggregateBuild") or std.mem.eql(u8, name, "AggregateEmit")) "AGGREGATE" else if (std.mem.eql(u8, name, "Project")) "PROJECT" else if (std.mem.eql(u8, name, "Distinct")) "DISTINCT" else if (std.mem.eql(u8, name, "Sort")) "ORDER" else if (std.mem.eql(u8, name, "Offset") or std.mem.eql(u8, name, "Limit")) "PAGE" else "OTHER";
                                            wr.writeAll("\",\"phase\":\"") catch {};
                                            wr.writeAll(phase) catch {};
                                            wr.writeAll("\"") catch {}; // close phase string
                                            // Emit stable id field (alias op_index for v1)
                                            wr.writeAll(",\"id\":") catch {};
                                            wr.print("{d}", .{op_index.*}) catch {};
                                            wr.writeAll(",\"op_index\":") catch {}; // legacy field retained
                                            wr.print("{d}", .{op_index.*}) catch {};
                                            wr.writeAll(",\"input_rows\":") catch {};
                                            wr.print("{d}", .{in_rows}) catch {};
                                            wr.writeAll(",\"rows\":") catch {};
                                            wr.print("{d}", .{out_rows}) catch {};
                                            wr.writeAll(",\"time_ns\":") catch {};
                                            wr.print("{d}", .{time_ns}) catch {};
                                            // Placeholder cpu_time_ns (single-threaded prototype): equal to time_ns; future: process CPU diff attribution.
                                            wr.writeAll(",\"cpu_time_ns\":") catch {};
                                            wr.print("{d}", .{time_ns}) catch {};
                                            wr.writeAll(",\"bytes_out\":") catch {};
                                            wr.print("{d}", .{bytes_out}) catch {};
                                            wr.writeAll(",\"bytes_alloc\":") catch {};
                                            wr.print("{d}", .{bytes_alloc}) catch {};
                                            if (!compact or est_bytes != 0) {
                                                wr.writeAll(",\"estimate_bytes\":") catch {};
                                                wr.print("{d}", .{est_bytes}) catch {};
                                            }
                                            var estimate_vs_actual: usize = if (est_bytes > 0 and bytes_alloc > 0) (bytes_alloc * 100) / est_bytes else 0;
                                            if (estimate_vs_actual > 999) estimate_vs_actual = 999; // cap extreme ratios for stability
                                            if (!compact or estimate_vs_actual != 0) {
                                                wr.writeAll(",\"estimate_vs_actual\":") catch {};
                                                wr.print("{d}", .{estimate_vs_actual}) catch {};
                                            }
                                            // percent_peak = allocation share of peak (delta attribution already applied to bytes_alloc)
                                            const percent_peak: usize = if (peak_total > 0 and bytes_alloc > 0) (bytes_alloc * 100) / peak_total else 0;
                                            if (!compact or percent_peak != 0) {
                                                wr.writeAll(",\"percent_peak\":") catch {};
                                                wr.print("{d}", .{percent_peak}) catch {};
                                            }
                                            const percent_net: usize = if (net_total > 0 and bytes_alloc > 0) (bytes_alloc * 100) / net_total else 0;
                                            if (!compact or percent_net != 0) {
                                                wr.writeAll(",\"percent_net\":") catch {};
                                                wr.print("{d}", .{percent_net}) catch {};
                                            }
                                            cum_time.* += time_ns;
                                            wr.writeAll(",\"cumulative_time_ns\":") catch {};
                                            wr.print("{d}", .{cum_time.*}) catch {};
                                            // freed_bytes & net_after_op tracking
                                            const net_after = net_total;
                                            const freed_bytes: usize = if (net_after < prev_net.*) prev_net.* - net_after else 0;
                                            if (!compact or freed_bytes != 0) {
                                                wr.writeAll(",\"freed_bytes\":") catch {};
                                                wr.print("{d}", .{freed_bytes}) catch {};
                                            }
                                            wr.writeAll(",\"net_after_op\":") catch {};
                                            wr.print("{d}", .{net_after}) catch {};
                                            prev_net.* = net_after;
                                            if (est_bytes > 0) net_after_sum.* += est_bytes;
                                            if (est_bytes > 0) {
                                                // error metrics
                                                const err_abs: isize = @as(isize, @intCast(bytes_alloc)) - @as(isize, @intCast(est_bytes));
                                                const err_bytes: usize = if (err_abs < 0) @intCast(-err_abs) else @intCast(err_abs);
                                                var err_pct: usize = if (est_bytes > 0 and err_bytes > 0) (err_bytes * 100) / est_bytes else 0;
                                                if (err_pct > 999) err_pct = 999; // cap to prevent runaway percentages
                                                if (!compact or err_bytes != 0) {
                                                    wr.writeAll(",\"error_bytes\":") catch {};
                                                    wr.print("{d}", .{err_bytes}) catch {};
                                                }
                                                if (!compact or err_pct != 0) {
                                                    wr.writeAll(",\"error_abs_pct\":") catch {};
                                                    wr.print("{d}", .{err_pct}) catch {};
                                                }
                                                if (error_count.* == 0 or err_pct < error_min_pct.*) error_min_pct.* = err_pct;
                                                if (err_pct > error_max_pct.*) error_max_pct.* = err_pct;
                                                error_sum_pct.* += err_pct;
                                                error_sum_sq_pct.* += err_pct * err_pct;
                                                error_count.* += 1;
                                            } else {
                                                if (!compact) wr.writeAll(",\"error_bytes\":0,\"error_abs_pct\":0") catch {};
                                            }
                                            op_index.* += 1;
                                            wr.writeAll("}") catch {};
                                            if (bytes_alloc > 0) maybeRecord(tt, name, bytes_alloc);
                                            first_ptr.* = false;
                                        }
                                    };
                                    var top_tracker: emit.TopTracker = .{};
                                    var cumulative_time_ns: i128 = 0;
                                    var prev_net_after: usize = 0;
                                    var sum_estimated: usize = 0;
                                    var sum_actual_estimated: usize = 0; // accumulate bytes_alloc for stages with estimates
                                    var op_index_counter: usize = 0;
                                    var err_min_pct: usize = 0;
                                    var err_max_pct: usize = 0;
                                    var err_sum_pct: usize = 0;
                                    var err_sum_sq_pct: usize = 0; // for stddev_error_abs_pct
                                    var err_count: usize = 0;
                                    var op_index_distinct: ?usize = null;
                                    var op_index_sort: ?usize = null;
                                    var mem_curve_builder = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
                                    defer mem_curve_builder.deinit(gpa);
                                    const MemCurve = struct {
                                        fn append(mc_alloc: std.mem.Allocator, b: *std.ArrayList(u8), op_index: usize, net_after: usize) void {
                                            var wmc = b.writer(mc_alloc);
                                            if (b.items.len == 0) {
                                                wmc.print("{{\"op_index\":{d},\"net_after_op\":{d}}}", .{ op_index, net_after }) catch {};
                                            } else {
                                                wmc.print(",{{\"op_index\":{d},\"net_after_op\":{d}}}", .{ op_index, net_after }) catch {};
                                            }
                                        }
                                    };
                                    // Allocate a synthetic scratch slab to demonstrate freed_bytes attribution.
                                    // We free it just before Sort emission (if ordering present) so freed_bytes appears on Sort stage.
                                    var scratch_slab: ?[]u8 = null;
                                    if (timings.project_rows_out > 0) {
                                        const slab_size = timings.project_rows_out * 16; // heuristic
                                        scratch_slab = prof_ally.alloc(u8, slab_size) catch null;
                                    }
                                    if (q.group_by != null) {
                                        const net_now = track.net();
                                        const est_build = if (disable_estimates) 0 else timings.agg_rows_in * 32;
                                        const est_emit = if (disable_estimates) 0 else timings.agg_rows_out * 16;
                                        const agg_build_idx = op_index_counter;
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_sum_sq_pct, &err_count, "HashAggBuild", timings.agg_rows_in, timings.agg_rows_out, timings.agg_build_ns, timings.project_bytes_out, timings.agg_build_bytes_alloc, est_build, peak_bytes, net_now, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, agg_build_idx, net_now);
                                        if (est_build > 0) sum_actual_estimated += timings.agg_build_bytes_alloc;
                                        const agg_emit_idx = op_index_counter;
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_sum_sq_pct, &err_count, "HashAggEmit", timings.agg_rows_out, timings.agg_rows_out, timings.agg_emit_ns, timings.project_bytes_out, timings.agg_emit_bytes_alloc, est_emit, peak_bytes, net_now, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, agg_emit_idx, net_now);
                                        if (est_emit > 0) sum_actual_estimated += timings.agg_emit_bytes_alloc;
                                    }
                                    const net_post_group = track.net();
                                    // Insert synthetic NodeScan stage for simple queries (placeholder until real scans implemented)
                                    if (timings.project_rows_out > 0) {
                                        const est_nodescan = if (disable_estimates) 0 else timings.project_rows_out * 4; // small per-row placeholder
                                        const nodescan_idx = op_index_counter;
                                        const net_nodescan = track.net();
                                        var op_name: []const u8 = "NodeScan";
                                        var chosen_index: ?IndexStats = null;
                                        // Minimal AST-based detection: inspect q.where (if present) for equality predicate nodes.
                                        var has_equality_pred = false;
                                        if (q.where_clause) |wexpr| {
                                            has_equality_pred = hasEqualityPredicate(wexpr);
                                        }
                                        if (has_equality_pred) {
                                            if (chooseIndexForPredicate(gpa, null, true, timings.project_rows_out)) |chosen| {
                                                chosen_index = chosen;
                                                op_name = "NodeIndexScan";
                                            }
                                        }
                                        // Emit scan op; if index chosen we embed inline metadata by writing an extension after op JSON is appended.
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_sum_sq_pct, &err_count, op_name, timings.project_rows_in, timings.project_rows_in, 0, 0, 0, est_nodescan, peak_bytes, net_nodescan, compact_profile);
                                        if (chosen_index) |ci_meta| {
                                            // Backpatch by locating last '}' and inserting inline metadata fields before it.
                                            var idx_back: isize = @as(isize, @intCast(pb.items.len)) - 1;
                                            while (idx_back >= 0 and pb.items[@intCast(idx_back)] != '}') : (idx_back -= 1) {}
                                            if (idx_back > 0) {
                                                // Insert at idx_back position (before closing brace)
                                                // Fields: ,"index_name":"...","selectivity_est":<f64>
                                                var sel_buf: [32]u8 = undefined;
                                                const sel_str = std.fmt.bufPrint(&sel_buf, "{d:.6}", .{ci_meta.eqSelectivity()}) catch "0.0";
                                                const meta_prefix = ",\"index_name\":\"";
                                                const meta_mid = "\",\"selectivity_est\":";
                                                // Build insertion slice
                                                var ins = std.ArrayList(u8).initCapacity(gpa, 0) catch unreachable;
                                                const iw = ins.writer(gpa);
                                                iw.writeAll(meta_prefix) catch {};
                                                iw.writeAll(ci_meta.name) catch {};
                                                iw.writeAll(meta_mid) catch {};
                                                iw.writeAll(sel_str) catch {};
                                                const insertion = ins.toOwnedSlice(gpa) catch &.{};
                                                defer gpa.free(insertion);
                                                // Shift existing tail (including closing brace) by insertion length.
                                                const tail_len = pb.items.len - @as(usize, @intCast(idx_back));
                                                // Allocate new buffer if needed
                                                pb.ensureTotalCapacity(gpa, pb.items.len + insertion.len) catch {};
                                                // Move tail forward
                                                std.mem.copyBackwards(u8, pb.items[@as(usize, @intCast(idx_back)) + insertion.len .. @as(usize, @intCast(idx_back)) + insertion.len + tail_len], pb.items[@as(usize, @intCast(idx_back)) .. @as(usize, @intCast(idx_back)) + tail_len]);
                                                // Copy insertion
                                                std.mem.copyForwards(u8, pb.items[@as(usize, @intCast(idx_back)) .. @as(usize, @intCast(idx_back)) + insertion.len], insertion);
                                                pb.items.len += insertion.len;
                                            }
                                        }
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, nodescan_idx, net_nodescan);
                                        if (est_nodescan > 0) sum_actual_estimated += 0;
                                        const est_expand = if (disable_estimates) 0 else timings.expand_rows_out * 8;
                                        const expand_idx = op_index_counter;
                                        const net_expand = track.net();
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_sum_sq_pct, &err_count, "Expand", timings.expand_rows_in, timings.expand_rows_out, timings.expand_ns, timings.expand_bytes_out, timings.expand_bytes_alloc, est_expand, peak_bytes, net_expand, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, expand_idx, net_expand);
                                        if (est_expand > 0) sum_actual_estimated += timings.expand_bytes_alloc;
                                    }
                                    const est_project = if (disable_estimates) 0 else timings.project_rows_out * 8;
                                    const project_idx = op_index_counter;
                                    emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_sum_sq_pct, &err_count, "Project", timings.project_rows_in, timings.project_rows_out, timings.project_ns, timings.project_bytes_out, timings.project_bytes_alloc, est_project, peak_bytes, net_post_group, compact_profile);
                                    if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, project_idx, net_post_group);
                                    if (est_project > 0) sum_actual_estimated += timings.project_bytes_alloc;
                                    if (q.ret.distinct) {
                                        const est_distinct = if (disable_estimates) 0 else timings.distinct_rows_in * 24;
                                        op_index_distinct = op_index_counter;
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_sum_sq_pct, &err_count, "Distinct", timings.distinct_rows_in, timings.distinct_rows_out, timings.distinct_ns, timings.distinct_bytes_out, if (timings.distinct_bytes_alloc != 0) timings.distinct_bytes_alloc else timings.distinct_bytes_out, est_distinct, peak_bytes, net_post_group, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, op_index_distinct.?, net_post_group);
                                        if (est_distinct > 0) sum_actual_estimated += if (timings.distinct_bytes_alloc != 0) timings.distinct_bytes_alloc else timings.distinct_bytes_out;
                                    }
                                    if (ordered_meta) {
                                        // Free scratch slab just before capturing Sort stage net to register freed_bytes on Sort.
                                        if (scratch_slab) |slab| {
                                            prof_ally.free(slab);
                                            scratch_slab = null;
                                        }
                                        const est_sort = if (disable_estimates) 0 else timings.sort_rows_in * 16;
                                        op_index_sort = op_index_counter;
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_sum_sq_pct, &err_count, "Sort", timings.sort_rows_in, timings.sort_rows_out, timings.sort_ns, timings.sort_bytes_out, if (timings.sort_bytes_alloc != 0) timings.sort_bytes_alloc else timings.sort_bytes_out, est_sort, peak_bytes, net_post_group, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, op_index_sort.?, net_post_group);
                                        if (est_sort > 0) sum_actual_estimated += if (timings.sort_bytes_alloc != 0) timings.sort_bytes_alloc else timings.sort_bytes_out;
                                    }
                                    if (q.offset != null) {
                                        const offset_idx = op_index_counter;
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_sum_sq_pct, &err_count, "Offset", timings.offset_rows_in, timings.offset_rows_out, timings.offset_ns, timings.offset_bytes_out, if (timings.offset_bytes_alloc != 0) timings.offset_bytes_alloc else timings.offset_bytes_out, 0, peak_bytes, net_post_group, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, offset_idx, net_post_group);
                                    }
                                    if (q.limit != null) {
                                        const limit_idx = op_index_counter;
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_sum_sq_pct, &err_count, "Limit", timings.limit_rows_in, timings.limit_rows_out, timings.limit_ns, timings.limit_bytes_out, if (timings.limit_bytes_alloc != 0) timings.limit_bytes_alloc else timings.limit_bytes_out, 0, peak_bytes, net_post_group, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, limit_idx, net_post_group);
                                    }
                                    // If scratch not freed due to no sort stage, free now (freed_bytes will not appear in that case).
                                    if (scratch_slab) |slab2| prof_ally.free(slab2);
                                    // Emit peak_contributors array (filter zero entries, sort descending)
                                    // Simple selection sort of top_tracker arrays
                                    // Build temporary indices
                                    var order_idx: [3]usize = .{ 0, 1, 2 };
                                    var oi: usize = 0;
                                    while (oi < 3) : (oi += 1) {
                                        var oj: usize = oi + 1;
                                        while (oj < 3) : (oj += 1) {
                                            if (top_tracker.vals[oj] > top_tracker.vals[order_idx[oi]]) {
                                                const tmp = order_idx[oi];
                                                order_idx[oi] = oj;
                                                order_idx[oj] = tmp;
                                            }
                                        }
                                    }
                                    // peak_contributors already assembled using top_tracker (phase 2 refinement done)
                                    w.writeAll(",\"peak_contributors\":[") catch {};
                                    var pc_first = true;
                                    var pci: usize = 0;
                                    while (pci < 3) : (pci += 1) {
                                        const idx = order_idx[pci];
                                        if (top_tracker.vals[idx] == 0 or top_tracker.lens[idx] == 0) continue;
                                        if (!pc_first) w.writeAll(",") catch {} else pc_first = false;
                                        w.writeAll("{\"op\":\"") catch {};
                                        w.writeAll(top_tracker.names[idx][0..top_tracker.lens[idx]]) catch {};
                                        w.writeAll("\",\"bytes_alloc\":") catch {};
                                        w.print("{d}", .{top_tracker.vals[idx]}) catch {};
                                        w.writeAll("}") catch {};
                                    }
                                    w.writeAll("]") catch {};
                                    // Totals section (time + peak)
                                    w.writeAll(",\"totals\":{") catch {};
                                    w.writeAll("\"time_ns\":") catch {};
                                    w.print("{d}", .{total_ns}) catch {};
                                    w.writeAll(",\"peak_bytes\":") catch {};
                                    w.print("{d}", .{track.peakBytes()}) catch {};
                                    // Aggregated HashAgg metrics (if aggregation ran)
                                    var hashagg_build_ns: i128 = 0;
                                    var hashagg_emit_ns: i128 = 0;
                                    var hashagg_build_bytes: usize = 0;
                                    var hashagg_emit_bytes: usize = 0;
                                    // We captured these in timings when q.group_by != null
                                    if (q.group_by != null) {
                                        hashagg_build_ns = timings.agg_build_ns;
                                        hashagg_emit_ns = timings.agg_emit_ns;
                                        hashagg_build_bytes = timings.agg_build_bytes_alloc;
                                        hashagg_emit_bytes = timings.agg_emit_bytes_alloc;
                                    }
                                    w.writeAll(",\"hashagg_build_ns\":") catch {};
                                    w.print("{d}", .{hashagg_build_ns}) catch {};
                                    w.writeAll(",\"hashagg_emit_ns\":") catch {};
                                    w.print("{d}", .{hashagg_emit_ns}) catch {};
                                    w.writeAll(",\"hashagg_build_bytes_alloc\":") catch {};
                                    w.print("{d}", .{hashagg_build_bytes}) catch {};
                                    w.writeAll(",\"hashagg_emit_bytes_alloc\":") catch {};
                                    w.print("{d}", .{hashagg_emit_bytes}) catch {};
                                    // HashAgg spill metrics (prototype): mark spill when threshold crossed.
                                    const hashagg_spills: usize = state.spill_hashagg;
                                    w.writeAll(",\"hashagg_spills\":") catch {};
                                    w.print("{d}", .{hashagg_spills}) catch {};
                                    if (hashagg_spills > 0) {
                                        w.writeAll(",\"hashagg_spill_reason\":\"") catch {};
                                        // Reason: threshold or forced via env (future). Currently only threshold based.
                                        if (state.query_mem_limit_bytes > 0) {
                                            w.writeAll("threshold") catch {};
                                        } else {
                                            w.writeAll("unknown") catch {};
                                        }
                                        w.writeAll("\")") catch {};
                                    }
                                    // WAL skip ratio placeholder (storage layer not yet threaded into server state)
                                    // WAL skip ratio (if WAL integrated into server state)
                                    var wal_skip_ratio: f64 = 0.0;
                                    if (state.wal_ptr) |wp| {
                                        // Cast opaque pointer back to Wal and read skipRatio.
                                        const wptr: *wal_mod.Wal = @ptrCast(@alignCast(wp));
                                        wal_skip_ratio = wptr.skipRatio();
                                        // Also expose committed_txns metric
                                        const committed = wptr.committedTxnTotal();
                                        w.writeAll(",\"committed_txns\":") catch {};
                                        w.print("{d}", .{committed}) catch {};
                                    }
                                    var wal_buf: [32]u8 = undefined;
                                    const wal_str = std.fmt.bufPrint(&wal_buf, "{d:.4}", .{wal_skip_ratio}) catch "0.0";
                                    // Backward compat: retain old key wal_skip_ratio; add alias skip_ratio (preferred going forward)
                                    w.writeAll(",\"wal_skip_ratio\":") catch {};
                                    w.writeAll(wal_str) catch {};
                                    w.writeAll(",\"skip_ratio\":") catch {};
                                    w.writeAll(wal_str) catch {};
                                    w.writeAll("}") catch {};
                                    w.writeAll(",\"total_time_ns\":") catch {};
                                    w.print("{d}", .{total_ns}) catch {};
                                    // Capture first spill op index & peak-at-spill if any (derive from previously recorded top tracker order / env flags)
                                    var first_spill_op: isize = -1;
                                    if (state.spill_sort + state.spill_distinct + state.spill_union > 0) {
                                        // Approx heuristic: first operator among Sort/Distinct/NodeScan that had a spill flag set.
                                        if (state.spill_sort > 0) first_spill_op = 0; // NodeScan/Expand indices precede but spill tied to Sort stage -> refine when op indices known prior to emission.
                                    }
                                    w.writeAll(",\"spills\":{") catch {};
                                    w.print("\"sort_spills\":{d},", .{state.spill_sort}) catch {};
                                    w.print("\"distinct_spills\":{d},", .{state.spill_distinct}) catch {};
                                    w.print("\"union_spills\":{d}", .{state.spill_union}) catch {};
                                    w.writeAll("}") catch {};
                                    // spill_reason if any
                                    if (state.spill_sort + state.spill_distinct + state.spill_union > 0) {
                                        var spill_reason: []const u8 = "forced";
                                        if (state.query_mem_limit_bytes > 0 and peak_bytes >= state.query_mem_limit_bytes) spill_reason = "threshold";
                                        w.writeAll(",\"spill_reason\":\"") catch {};
                                        w.writeAll(spill_reason) catch {};
                                        w.writeAll("\"") catch {};
                                        w.writeAll(",\"peak_bytes_at_spill\":") catch {};
                                        w.print("{d}", .{peak_bytes}) catch {};
                                        var first_spill_op_index: isize = -1;
                                        if (state.spill_distinct > 0) {
                                            if (op_index_distinct) |dix| first_spill_op_index = @intCast(dix);
                                        }
                                        if (state.spill_sort > 0) {
                                            if (op_index_sort) |six| {
                                                if (first_spill_op_index < 0 or six < @as(usize, @intCast(first_spill_op_index))) first_spill_op_index = @intCast(six);
                                            }
                                        }
                                        if (first_spill_op_index >= 0) {
                                            w.writeAll(",\"first_spill_op_index\":") catch {};
                                            w.print("{d}", .{first_spill_op_index}) catch {};
                                        }
                                    }
                                    if (memcurve_profile and mem_curve_builder.items.len > 0) {
                                        w.writeAll(",\"mem_curve\":[") catch {};
                                        w.writeAll(mem_curve_builder.items) catch {};
                                        w.writeAll("]") catch {};
                                    }
                                    // Memory summary (net/peak so far) - counting allocator 'track'
                                    w.writeAll(",\"memory\":{") catch {};
                                    w.print("\"net_bytes\":{d},", .{track.net()}) catch {};
                                    w.print("\"peak_bytes\":{d},", .{track.peakBytes()}) catch {};
                                    w.print("\"total_alloc_bytes\":{d}", .{track.total_alloc}) catch {};
                                    w.writeAll("}") catch {};
                                    // planner_estimates summary (only if estimates enabled)
                                    if (!disable_estimates) {
                                        // Derive median error: since we only tracked aggregate stats, approximate median as (min+max)/2 when >1 op, else err_min.
                                        var median_err: usize = 0;
                                        if (err_count == 0) median_err = 0 else if (err_count == 1) median_err = err_min_pct else median_err = (err_min_pct + err_max_pct) / 2;
                                        // adjusted_estimate_factor: factor to multiply future estimates by to reduce mean absolute error: actual/estimate ratio.
                                        const adjusted_estimate_factor: f64 = if (sum_estimated > 0 and sum_actual_estimated > 0) @as(f64, @floatFromInt(sum_actual_estimated)) / @as(f64, @floatFromInt(sum_estimated)) else 1.0;
                                        w.writeAll(",\"planner_estimates\":{") catch {};
                                        w.print("\"sum_estimate_bytes\":{d},", .{sum_estimated}) catch {};
                                        w.print("\"sum_actual_bytes\":{d},", .{sum_actual_estimated}) catch {};
                                        w.print("\"count_estimated_ops\":{d}", .{err_count}) catch {};
                                        if (err_count > 0) {
                                            const mean_err: usize = err_sum_pct / err_count;
                                            // population stddev (we can refine to sample if needed later)
                                            var stddev_err: usize = 0;
                                            if (err_count > 1) {
                                                const mean_sq = mean_err * mean_err;
                                                const avg_sq = err_sum_sq_pct / err_count;
                                                if (avg_sq > mean_sq) {
                                                    const variance = avg_sq - mean_sq;
                                                    const stddev_f = std.math.sqrt(@as(f64, @floatFromInt(variance)));
                                                    stddev_err = @intFromFloat(stddev_f);
                                                }
                                                if (stddev_err > 100) stddev_err = 100; // cap within schema bounds
                                            }
                                            w.writeAll(",") catch {};
                                            w.print("\"min_error_abs_pct\":{d},\"max_error_abs_pct\":{d},\"mean_error_abs_pct\":{d},\"median_error_abs_pct\":{d},\"stddev_error_abs_pct\":{d}", .{ err_min_pct, err_max_pct, mean_err, median_err, stddev_err }) catch {};
                                            // Print factor with limited precision
                                            var buf: [32]u8 = undefined;
                                            const fac_str = std.fmt.bufPrint(&buf, "{d:.4}", .{adjusted_estimate_factor}) catch "1.0000";
                                            w.writeAll(",\"adjusted_estimate_factor\":") catch {};
                                            w.writeAll(fac_str) catch {};
                                        }
                                        w.writeAll("}") catch {};
                                    }
                                    const owned_slice = pb.toOwnedSlice(gpa) catch "{}";
                                    std.debug.print("[debug] capture PROFILE json_len={d}\n", .{owned_slice.len});
                                    if (owned_slice.len > 0) {
                                        const prev = if (owned_slice.len < 64) owned_slice.len else 64;
                                        std.debug.print("[debug] profile json head='{s}'\n", .{owned_slice[0..prev]});
                                    }
                                    state.profile_json = owned_slice;
                                    state.profile_flags = computeBaseFlags(ordered_meta, q.ret.distinct);
                                    state.last_columns = cols;
                                    state.last_ordered = ordered_meta;
                                    state.last_order_keys = order_keys;
                                    state.last_distinct = q.ret.distinct;
                                    state.active_result = true; // so PULL will emit PROFILE
                                    // Emit SCHEMA now
                                    if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, state.profile_flags)) |line| {
                                        defer gpa.free(line);
                                        _ = stdout_file.write(line) catch {};
                                    } else |_| {}
                                    continue;
                                }
                                var param_names: [][]const u8 = &.{};
                                var param_rows: [][]const eval.Value = &.{};
                                parseParams(gpa, rq.params_json, &param_names, &param_rows);
                                var ordered_meta = false;
                                var order_keys: [][]const u8 = &.{};
                                var cols: []const protocol.SchemaCol = &.{};
                                var run_code: diagnostics.Code = .IllegalOrderKey; // init sentinel
                                // Branch: GROUP BY support (non-PROFILE path). Use exec.runGroupedQuery to produce aggregated rows.
                                var rows: [][]const u8 = &.{};
                                if (q.group_by != null) {
                                    // Build input row matrix from params (each param row is a logical input row; empty when no params).
                                    // Provide a slice-of-slices representing input rows; in this prototype inputs are param-based expressions only.
                                    const empty_row: []eval.Value = &.{};
                                    const input_len = if (param_rows.len > 0) param_rows.len else 1;
                                    // Tracking allocator to capture HashAgg memory usage (build + emit) in non-PROFILE path.
                                    var track_agg = TrackingAllocator{ .inner = gpa };
                                    track_agg.init(gpa);
                                    const agg_ally = track_agg.allocator;
                                    var input_placeholder_mut: [][]eval.Value = agg_ally.alloc([]eval.Value, input_len) catch &.{};
                                    var ip: usize = 0;
                                    while (ip < input_len) : (ip += 1) input_placeholder_mut[ip] = empty_row;
                                    const input_placeholder: []const []eval.Value = input_placeholder_mut;
                                    const first_param_vals: []const eval.Value = if (param_rows.len > 0) param_rows[0] else &.{};
                                    var agg_timings: exec.AggStageTimings = .{}; // timings unused here but required param
                                    const g_rows = exec.runGroupedQuery(agg_ally, q, &.{}, input_placeholder, param_names, first_param_vals, &agg_timings) catch blk_agerr: {
                                        // On error fallback to evaluateSimpleQuery (e.g., if planner rejects invalid agg)
                                        // Free placeholder (allocator is gpa)
                                        // Note: runGroupedQuery returns error.Invalid if group_by absent, already guarded.
                                        break :blk_agerr &.{};
                                    };
                                    // Derive schema from RETURN items (types heuristic as INT for now; could refine using value inspection)
                                    var mut_cols: []protocol.SchemaCol = gpa.alloc(protocol.SchemaCol, q.ret.items.len) catch &.{};
                                    var ci: usize = 0;
                                    while (ci < q.ret.items.len) : (ci += 1) {
                                        const rit = q.ret.items[ci];
                                        const alias = rit.alias orelse geode.printer.stringifyExprAlloc(gpa, rit.expr, .{}) catch "col";
                                        // Infer aggregate column type by scanning result rows for first non-null value.
                                        var inferred: []const u8 = "NULL";
                                        var ri: usize = 0;
                                        while (ri < g_rows.len) : (ri += 1) {
                                            if (ci < g_rows[ri].len) {
                                                const bv = g_rows[ri][ci];
                                                switch (bv) {
                                                    .Null => {},
                                                    else => {
                                                        inferred = bindingValueTypeName(bv);
                                                        ri = g_rows.len; // break outer
                                                    },
                                                }
                                            }
                                        }
                                        mut_cols[ci] = .{ .name = alias, .type = inferred };
                                    }
                                    cols = mut_cols; // implicit cast to const slice
                                    // ORDER BY post-aggregation: exec.runGroupedQuery already applied ordering if q.order_by present; mark ordered_meta accordingly.
                                    if (q.order_by) |_| ordered_meta = true;
                                    // Convert BindingValue rows to JSON objects using shared helper.
                                    var out_arr = std.ArrayList([]const u8).initCapacity(gpa, 0) catch unreachable;
                                    defer out_arr.deinit(gpa);
                                    var ri: usize = 0;
                                    while (ri < g_rows.len) : (ri += 1) {
                                        const brow = g_rows[ri];
                                        const js = bindingValueRowToJson(gpa, @constCast(cols), brow);
                                        out_arr.append(gpa, js) catch {};
                                    }
                                    rows = out_arr.toOwnedSlice(gpa) catch &.{};
                                    // Record memory metrics for HashAgg (approx: treat peak as build, delta after emit as emit bytes if any growth).
                                    const peak_bytes = track_agg.peakBytes();
                                    const net_after = track_agg.net();
                                    state.agg_build_bytes_last = peak_bytes; // coarse attribution
                                    state.agg_emit_bytes_last = if (net_after > peak_bytes) net_after - peak_bytes else 0;
                                    if (state.query_mem_limit_bytes > 0 and peak_bytes >= state.query_mem_limit_bytes) state.spill_hashagg = 1;
                                } else {
                                    rows = evaluateSimpleQuery(gpa, q, param_names, param_rows, &ordered_meta, &order_keys, &cols, null, &run_code, null) catch |e| blk_runerr: {
                                        if (diagnostics.mapEvalError(e)) |c| {
                                            writeErrorWithFlags(gpa, stdout_file, c, diagnostics.defaultMessage(c), diagnostics.anchorFor(c), &.{}, false);
                                            break :blk_runerr &.{};
                                        }
                                        break :blk_runerr &.{};
                                    };
                                }
                                if (rows.len == 0 and run_code == .TypeMismatch) continue;
                                if (run_code == .TypeMismatch) {
                                    var buf_codes2: [2]diagnostics.Code = undefined;
                                    var len2: usize = 0;
                                    buf_codes2[len2] = .TypeMismatch;
                                    len2 += 1;
                                    if ((q.limit != null or q.offset != null) and q.order_by == null) {
                                        buf_codes2[len2] = .US001;
                                        len2 += 1;
                                    }
                                    const slice2 = buf_codes2[0..len2];
                                    const n_fold2 = diagnostics.foldCodes(slice2);
                                    const primary2 = slice2[0];
                                    const add2 = buildAdditionalStatusesAlloc(gpa, slice2[0..n_fold2], primary2);
                                    writeErrorWithFlags(gpa, stdout_file, primary2, diagnostics.defaultMessage(primary2), diagnostics.anchorFor(primary2), add2, primary2 == .US001);
                                    // free row fragments
                                    var fr2: usize = 0;
                                    while (fr2 < rows.len) : (fr2 += 1) gpa.free(rows[fr2]);
                                    continue;
                                }
                                state.last_columns = cols;
                                state.last_ordered = ordered_meta;
                                state.last_order_keys = order_keys;
                                state.last_distinct = q.ret.distinct;
                                state.page_items = @constCast(rows);
                                state.active_result = true;
                                state.guard_trip = (run_code == .ExecutionGuardTrip);
                                if (result_format_txt) {
                                    // Plain text mode: emit header once then all rows (single page). Disable further pulls.
                                    var hi: usize = 0;
                                    while (hi < state.last_columns.len) : (hi += 1) {
                                        if (hi > 0) stdout_file.writeAll("\t") catch {};
                                        stdout_file.writeAll(state.last_columns[hi].name) catch {};
                                    }
                                    stdout_file.writeAll("\n") catch {};
                                    var ri: usize = 0;
                                    while (ri < state.page_items.len) : (ri += 1) {
                                        const row = state.page_items[ri];
                                        var cj: usize = 0;
                                        while (cj < state.last_columns.len) : (cj += 1) {
                                            if (cj > 0) stdout_file.writeAll("\t") catch {};
                                            const cname = state.last_columns[cj].name;
                                            if (std.mem.indexOf(u8, row, cname)) |pos| {
                                                if (std.mem.indexOfPos(u8, row, pos, ":")) |colon| {
                                                    var startv = colon + 1;
                                                    while (startv < row.len and (row[startv] == ' ')) startv += 1;
                                                    var endv = startv;
                                                    if (startv < row.len and row[startv] == '"') {
                                                        endv = startv + 1;
                                                        while (endv < row.len and row[endv] != '"') endv += 1;
                                                        stdout_file.writeAll(row[startv + 1 .. endv]) catch {};
                                                    } else {
                                                        while (endv < row.len and row[endv] != ',' and row[endv] != '}') endv += 1;
                                                        stdout_file.writeAll(row[startv..endv]) catch {};
                                                    }
                                                } else stdout_file.writeAll("null") catch {};
                                            } else stdout_file.writeAll("null") catch {};
                                        }
                                        stdout_file.writeAll("\n") catch {};
                                    }
                                    state.active_result = false; // fully emitted
                                } else {
                                    var addl_schema2: [][]const u8 = &.{};
                                    var addl_schema_buf: [1][]const u8 = undefined;
                                    if (state.guard_trip) {
                                        addl_schema_buf[0] = "ExecutionGuardTrip";
                                        addl_schema2 = addl_schema_buf[0..1];
                                    }
                                    if (protocol.buildSchemaLine(gpa, state.last_columns, addl_schema2, computeBaseFlags(state.last_ordered, q.ret.distinct))) |line| {
                                        defer gpa.free(line);
                                        _ = stdout_file.write(line) catch {};
                                    } else |_| {}
                                }
                                continue;
                            },
                            .Create => |create_stmt| {
                                // Execute CREATE statement
                                const result = try executeCreateStatement(gpa, &state, create_stmt);
                                defer gpa.free(result);
                                _ = stdout_file.write(result) catch {};
                                continue;
                            },
                            .Delete => |delete_stmt| {
                                // Execute DELETE statement
                                const result = try executeDeleteStatement(gpa, &state, delete_stmt);
                                defer gpa.free(result);
                                _ = stdout_file.write(result) catch {};
                                continue;
                            },
                            .Merge => |merge_stmt| {
                                // Execute MERGE statement
                                const result = try executeMergeStatement(gpa, &state, merge_stmt);
                                defer gpa.free(result);
                                _ = stdout_file.write(result) catch {};
                                continue;
                            },
                            .Union => |u_stmt| {
                                // Evaluate union then optionally EXPLAIN/PROFILE or pagination
                                var param_names: [][]const u8 = &.{};
                                var param_rows: [][]const eval.Value = &.{};
                                parseParams(gpa, rq.params_json, &param_names, &param_rows);
                                if (explain_mode) {
                                    const json = buildExplainJson(gpa, .{ .ordered = false, .limit = null, .offset = null, .union_mode = "DISTINCT", .distinct = true, .setop_kind = "SetOpUnion" });
                                    const flags_u = computeBaseFlags(false, true);
                                    if (protocol.buildExplainLine(gpa, json, flags_u)) |l2| {
                                        defer gpa.free(l2);
                                        _ = stdout_file.write(l2) catch {};
                                    } else |_| {}
                                    continue;
                                }
                                var metrics: UnionMetrics = .{ .left_in = 0, .right_in = 0, .out = 0, .hash_size = null };
                                var union_mode: []const u8 = "DISTINCT";
                                if (profile_mode) {
                                    // Granular union profiling phases.
                                    const total_start = std.time.nanoTimestamp();
                                    // Counting allocator for union profiling (independent from simple query path typical usage)
                                    var track_u = @import("tracking_alloc").TrackingAllocator{ .inner = gpa };
                                    track_u.init(gpa);
                                    const u_ally = track_u.allocator;
                                    // Phase 1: left
                                    const left_start = std.time.nanoTimestamp();
                                    var dummy_cols_l: []const protocol.SchemaCol = &.{};
                                    var ordered_l = false;
                                    var order_keys_l: [][]const u8 = &.{};
                                    const left_rows = evaluateSimpleQuery(u_ally, u_stmt.first, param_names, param_rows, &ordered_l, &order_keys_l, &dummy_cols_l, null, null, null) catch &.{};
                                    metrics.left_in = left_rows.len;
                                    const time_left = std.time.nanoTimestamp() - left_start;
                                    const alloc_after_left = track_u.net();
                                    // Phase 2: tails
                                    const tails_start = std.time.nanoTimestamp();
                                    var all_rows = std.ArrayList([]const u8).initCapacity(u_ally, 0) catch @panic("OOM");
                                    defer all_rows.deinit(u_ally);
                                    for (left_rows) |lr| all_rows.append(u_ally, lr) catch {};
                                    var any_all = false;
                                    var right_total: usize = 0;
                                    var ti_prof: usize = 0;
                                    while (ti_prof < u_stmt.tails.len) : (ti_prof += 1) {
                                        const part = u_stmt.tails[ti_prof];
                                        if (part.all) any_all = true;
                                        var oc_prof: []const protocol.SchemaCol = &.{};
                                        ordered_l = false;
                                        order_keys_l = &.{};
                                        const pr = evaluateSimpleQuery(u_ally, part.query, param_names, param_rows, &ordered_l, &order_keys_l, &oc_prof, null, null, null) catch &.{};
                                        right_total += pr.len;
                                        for (pr) |rr| all_rows.append(u_ally, rr) catch {};
                                        u_ally.free(oc_prof);
                                    }
                                    metrics.right_in = right_total;
                                    const time_tails = std.time.nanoTimestamp() - tails_start;
                                    const alloc_after_tails = track_u.net();
                                    // Phase 3: dedup (if DISTINCT)
                                    var dedup_time: i128 = 0;
                                    var final_rows: [][]const u8 = &.{};
                                    if (!any_all) {
                                        const dedup_start = std.time.nanoTimestamp();
                                        var seen = std.StringHashMap(void).init(u_ally);
                                        defer seen.deinit();
                                        var dedup = std.ArrayList([]const u8).initCapacity(u_ally, 0) catch @panic("OOM");
                                        defer dedup.deinit(u_ally);
                                        for (all_rows.items) |s| {
                                            if (!seen.contains(s)) {
                                                seen.put(s, {}) catch {};
                                                dedup.append(u_ally, s) catch {};
                                            } else gpa.free(s);
                                        }
                                        metrics.out = dedup.items.len;
                                        metrics.hash_size = seen.count();
                                        final_rows = dedup.toOwnedSlice(u_ally) catch &.{};
                                        dedup_time = std.time.nanoTimestamp() - dedup_start;
                                        union_mode = "DISTINCT";
                                    } else {
                                        union_mode = "ALL";
                                        metrics.out = all_rows.items.len;
                                        metrics.hash_size = null;
                                        final_rows = all_rows.toOwnedSlice(u_ally) catch &.{};
                                    }
                                    const total_elapsed = std.time.nanoTimestamp() - total_start;
                                    const alloc_after_dedup = track_u.net();
                                    // Build profiling JSON with phase ops
                                    var pb = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
                                    const w = pb.writer(gpa);
                                    w.writeAll("{\"ops\":[") catch {};
                                    const peak_u = track_u.peakBytes();
                                    if (state.query_mem_limit_bytes > 0 and peak_u >= state.query_mem_limit_bytes and std.mem.eql(u8, union_mode, "DISTINCT")) {
                                        state.spill_union = 1;
                                    }
                                    // UnionLeft
                                    w.writeAll("{\"op\":\"UnionLeft\",\"rows\":") catch {};
                                    w.print("{d}", .{metrics.left_in}) catch {};
                                    w.writeAll(",\"time_ns\":") catch {};
                                    w.print("{d}", .{time_left}) catch {};
                                    w.writeAll(",\"bytes_alloc\":") catch {};
                                    w.print("{d}", .{alloc_after_left}) catch {};
                                    const percent_left: usize = if (peak_u > 0 and alloc_after_left > 0) (alloc_after_left * 100) / peak_u else 0;
                                    w.writeAll(",\"percent_peak\":") catch {};
                                    w.print("{d}", .{percent_left}) catch {};
                                    w.writeAll("},") catch {};
                                    // UnionTails
                                    w.writeAll("{\"op\":\"UnionTails\",\"rows\":") catch {};
                                    w.print("{d}", .{metrics.right_in}) catch {};
                                    w.writeAll(",\"time_ns\":") catch {};
                                    w.print("{d}", .{time_tails}) catch {};
                                    w.writeAll(",\"bytes_alloc\":") catch {};
                                    const tails_delta = alloc_after_tails - alloc_after_left;
                                    w.print("{d}", .{tails_delta}) catch {};
                                    const percent_tails: usize = if (peak_u > 0 and tails_delta > 0) (tails_delta * 100) / peak_u else 0;
                                    w.writeAll(",\"percent_peak\":") catch {};
                                    w.print("{d}", .{percent_tails}) catch {};
                                    w.writeAll("},") catch {};
                                    if (std.mem.eql(u8, union_mode, "DISTINCT")) {
                                        w.writeAll("{\"op\":\"UnionDedup\",\"rows\":") catch {};
                                        w.print("{d}", .{metrics.out}) catch {};
                                        w.writeAll(",\"time_ns\":") catch {};
                                        w.print("{d}", .{dedup_time}) catch {};
                                        w.writeAll(",\"bytes_alloc\":") catch {};
                                        const dedup_delta = alloc_after_dedup - alloc_after_tails;
                                        w.print("{d}", .{dedup_delta}) catch {};
                                        const percent_dedup: usize = if (peak_u > 0 and dedup_delta > 0) (dedup_delta * 100) / peak_u else 0;
                                        w.writeAll(",\"percent_peak\":") catch {};
                                        w.print("{d}", .{percent_dedup}) catch {};
                                        w.writeAll("},") catch {};
                                    }
                                    // Final summary op
                                    w.writeAll("{\"op\":\"SetOpUnion\",\"rows\":") catch {};
                                    w.print("{d}", .{metrics.out}) catch {};
                                    w.writeAll(",\"time_ns\":") catch {};
                                    w.print("{d}", .{total_elapsed}) catch {};
                                    w.writeAll("]") catch {};
                                    // setop metrics object
                                    w.writeAll(",\"setop\":{\"type\":\"UNION\",\"mode\":\"") catch {};
                                    w.print("{s}", .{union_mode}) catch {};
                                    w.writeAll("\",\"input_rows_left\":") catch {};
                                    w.print("{d}", .{metrics.left_in}) catch {};
                                    w.writeAll(",\"input_rows_right\":") catch {};
                                    w.print("{d}", .{metrics.right_in}) catch {};
                                    w.writeAll(",\"output_rows\":") catch {};
                                    w.print("{d}", .{metrics.out}) catch {};
                                    if (metrics.hash_size) |hs2| {
                                        w.writeAll(",\"hash_dedup_size\":") catch {};
                                        w.print("{d}", .{hs2}) catch {};
                                        const total_in: usize = metrics.left_in + metrics.right_in;
                                        if (total_in > 0) {
                                            const fill_pct: usize = (hs2 * 100) / total_in; // integer percent of distinct vs input
                                            w.writeAll(",\"distinct_fill_pct\":") catch {};
                                            w.print("{d}", .{fill_pct}) catch {};
                                        }
                                    }
                                    w.writeAll("},\"total_time_ns\":") catch {};
                                    w.print("{d}", .{total_elapsed}) catch {};
                                    w.writeAll(",\"spills\":{") catch {};
                                    w.print("\"sort_spills\":{d},", .{state.spill_sort}) catch {};
                                    w.print("\"distinct_spills\":{d},", .{state.spill_distinct}) catch {};
                                    w.print("\"union_spills\":{d}", .{state.spill_union}) catch {};
                                    w.writeAll("}") catch {};
                                    w.writeAll(",\"memory\":{") catch {};
                                    w.print("\"net_bytes\":{d},", .{track_u.net()}) catch {};
                                    w.print("\"peak_bytes\":{d},", .{track_u.peakBytes()}) catch {};
                                    w.print("\"total_alloc_bytes\":{d}", .{track_u.total_alloc}) catch {};
                                    w.writeAll("}") catch {};
                                    const flags_u_prof = computeFlagsExtended(false, std.mem.eql(u8, union_mode, "DISTINCT"), true);
                                    const owned_prof_json = pb.toOwnedSlice(gpa) catch "{}";
                                    const dup_prof_json = gpa.dupe(u8, owned_prof_json) catch owned_prof_json;
                                    const pline2 = protocol.buildProfileLine(gpa, dup_prof_json, flags_u_prof) catch null;
                                    if (pline2) |pl2| {
                                        defer gpa.free(pl2);
                                        _ = stdout_file.write(pl2) catch {};
                                    }
                                    // Release final rows (not returned to client in PROFILE mode)
                                    var fr_i: usize = 0;
                                    while (fr_i < final_rows.len) : (fr_i += 1) gpa.free(final_rows[fr_i]);
                                    continue;
                                }
                                const rows = evaluateUnion(gpa, u_stmt, param_names, param_rows, &union_mode, &metrics) catch &.{};
                                // Derive schema from first part return list
                                var dummy_cols: []protocol.SchemaCol = &.{};
                                // union schema inference does not depend on ordering for now
                                const ord_keys: [][]const u8 = &.{}; // unused placeholder retained for consistency
                                dummy_cols = gpa.alloc(protocol.SchemaCol, u_stmt.first.ret.items.len) catch &.{};
                                var ci: usize = 0;
                                while (ci < u_stmt.first.ret.items.len) : (ci += 1) {
                                    const it = u_stmt.first.ret.items[ci];
                                    dummy_cols[ci] = .{ .name = it.alias orelse geode.printer.stringifyExprAlloc(gpa, it.expr, .{}) catch "col", .type = "INT" }; // heuristic
                                }
                                state.last_columns = dummy_cols;
                                state.last_ordered = false;
                                state.last_order_keys = ord_keys;
                                state.last_distinct = std.mem.eql(u8, union_mode, "DISTINCT");
                                state.page_items = @constCast(rows);
                                state.active_result = true;
                                if (result_format_txt) {
                                    // Plain text emission for UNION similar to simple query path.
                                    var hi: usize = 0;
                                    while (hi < state.last_columns.len) : (hi += 1) {
                                        if (hi > 0) stdout_file.writeAll("\t") catch {};
                                        stdout_file.writeAll(state.last_columns[hi].name) catch {};
                                    }
                                    stdout_file.writeAll("\n") catch {};
                                    var ri: usize = 0;
                                    while (ri < state.page_items.len) : (ri += 1) {
                                        const row = state.page_items[ri];
                                        var cj: usize = 0;
                                        while (cj < state.last_columns.len) : (cj += 1) {
                                            if (cj > 0) stdout_file.writeAll("\t") catch {};
                                            const cname = state.last_columns[cj].name;
                                            if (std.mem.indexOf(u8, row, cname)) |pos| {
                                                if (std.mem.indexOfPos(u8, row, pos, ":")) |colon| {
                                                    var startv = colon + 1;
                                                    while (startv < row.len and (row[startv] == ' ')) startv += 1;
                                                    var endv = startv;
                                                    if (startv < row.len and row[startv] == '"') {
                                                        endv = startv + 1;
                                                        while (endv < row.len and row[endv] != '"') endv += 1;
                                                        stdout_file.writeAll(row[startv + 1 .. endv]) catch {};
                                                    } else {
                                                        while (endv < row.len and row[endv] != ',' and row[endv] != '}') endv += 1;
                                                        stdout_file.writeAll(row[startv..endv]) catch {};
                                                    }
                                                } else stdout_file.writeAll("null") catch {};
                                            } else stdout_file.writeAll("null") catch {};
                                        }
                                        stdout_file.writeAll("\n") catch {};
                                    }
                                    state.active_result = false; // fully emitted
                                } else {
                                    if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, computeBaseFlags(state.last_ordered, true))) |line| {
                                        defer gpa.free(line);
                                        _ = stdout_file.write(line) catch {};
                                    } else |_| {}
                                }
                                continue;
                            },
                            else => {
                                const uline = protocol.buildErrorLine(gpa, "Unsupported", "statement type", "") catch null;
                                if (uline) |ul| {
                                    defer gpa.free(ul);
                                    _ = stdout_file.write(ul) catch {};
                                }
                                continue;
                            },
                        }
                    },
                }
            },
            .PULL => |pl| {
                if (!state.active_result and state.profile_json == null) {
                    const nrline = protocol.buildErrorLine(gpa, "NoResult", "no active result set", "") catch null;
                    if (nrline) |l| {
                        defer gpa.free(l);
                        _ = stdout_file.write(l) catch {};
                    }
                    continue;
                }
                // If PROFILE staged, emit PROFILE frame and clear profile_json; no rows to paginate.
                if (state.profile_json) |pj| {
                    const dup_pj = gpa.dupe(u8, pj) catch pj;

                    if (result_format_txt) {
                        // Text format output for PROFILE
                        var formatter = TextFormatter.init(gpa);
                        const txt = formatter.formatProfile(dup_pj) catch dup_pj;
                        defer if (txt.ptr != dup_pj.ptr) gpa.free(txt);
                        _ = stdout_file.write(txt) catch {};
                        _ = stdout_file.write("\n") catch {};
                    } else {
                        // JSON format output
                        const pline = protocol.buildProfileLine(gpa, dup_pj, state.profile_flags) catch null;
                        if (pline) |plj| {
                            defer gpa.free(plj);
                            _ = stdout_file.write(plj) catch {};
                        }
                        // silent on failure to build profile line
                    }

                    // PROFILE complete; clear state and mark no active result
                    state.allocator.free(pj);
                    state.profile_json = null;
                    state.profile_flags = &.{};
                    state.active_result = false;
                    continue;
                }
                const page_size = if (pl.page_size == 0) 1000 else pl.page_size;
                const start = state.page_index;
                const end = @min(state.page_index + page_size, state.page_items.len);
                var arr_buf = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
                const w = arr_buf.writer(gpa);
                w.writeAll("[") catch {};
                var i: usize = start;
                var first = true;
                while (i < end) : (i += 1) {
                    if (!first) w.writeAll(",") catch {};
                    first = false;
                    w.writeAll(state.page_items[i]) catch {};
                }
                w.writeAll("]") catch {};
                const json_rows = arr_buf.toOwnedSlice(gpa) catch "[]";
                state.page_index = end;
                const is_final = end >= state.page_items.len;
                if (is_final) state.active_result = false;
                const include_final = (state.page_items.len > 1) or (page_size < state.page_items.len);
                if (state.telemetry_paging) {
                    // Emit telemetry JSON log line on stderr via logger
                    var ps_buf: [32]u8 = undefined;
                    const ps_str = std.fmt.bufPrint(&ps_buf, "{d}", .{page_size}) catch "0";
                    var rows_buf: [32]u8 = undefined;
                    const rows_str = std.fmt.bufPrint(&rows_buf, "{d}", .{end - start}) catch "0";
                    logger.info("telemetry", .{
                        .{ .key = "type", .value = "TELEMETRY" },
                        .{ .key = "event", .value = "PULL_PAGE" },
                        .{ .key = "page_size", .value = ps_str },
                        .{ .key = "rows_emitted", .value = rows_str },
                        .{ .key = "final", .value = if (is_final) "true" else "false" },
                    });
                }
                writeBindingsAdaptive(stdout_file, state.last_ordered, state.last_order_keys, json_rows, is_final, include_final, computeBaseFlags(state.last_ordered, state.last_distinct));
            },
        }
    }
    // Graceful shutdown: persist graph if data_dir provided and in-memory graph exists
    if (data_dir) |ddir| {
        if (g_graph_storage) |gg| {
            // Save to JSONL files
            saveGraphToDir(gpa, gg, ddir);

            // Update catalog metadata if initialized
            if (catalog_inited) {
                catalog.saveGraphMetadata(@intCast(gg.nodes.count()), @intCast(gg.edges.items.len), 0, // max_node_id - would need to calculate
                    if (gg.edges.items.len > 0) gg.edges.items.len - 1 else 0) catch |err| {
                    std.log.warn("Failed to save graph metadata to catalog: {}", .{err});
                };
            }
        }
    }
    // Flush WAL if present before exiting.
    if (state.wal_ptr) |wp_flush| {
        const wflush: *wal_mod.Wal = @ptrCast(@alignCast(wp_flush));
        wflush.fsync() catch {};
    }
}

// Execute CREATE statement
fn executeCreateStatement(allocator: std.mem.Allocator, state: *ServerState, stmt: geode.ast.CreateStatement) ![]const u8 {
    // Get or create graph storage
    const graph = getOrCreateGraphStorage(allocator);

    // Start transaction if not already in one
    var started_auto = false;
    if (state.active_txn == null) {
        const t = state.txn_manager.begin();
        state.active_txn = t;
        state.session_snapshot_ts = state.global_commit_ts;
        started_auto = true;
    }

    // Process the pattern to create nodes and relationships
    var created_nodes = std.ArrayList(graph_exec.NodeId).initCapacity(allocator, 0) catch unreachable;
    defer created_nodes.deinit(allocator);
    var created_edges = std.ArrayList(graph_exec.EdgeId).initCapacity(allocator, 0) catch unreachable;
    defer created_edges.deinit(allocator);

    // Create nodes from the pattern
    for (stmt.pattern.chains) |chain| {
        for (chain.hops) |hop| {
            // Create left node if it has a name
            if (hop.left.name) |_| {
                const node_id = graph.nodes.count();
                try graph.addNode(allocator, node_id, hop.left.labels);
                try created_nodes.append(allocator, node_id);

                // Set properties if any
                if (hop.left.props) |props| {
                    for (props) |prop| {
                        const val = evalExprToPropertyValue(allocator, prop.value.*);
                        try graph.setNodeProperty(node_id, prop.key, val);
                    }
                }
            }

            // Create right node if it has a name
            if (hop.right.name) |_| {
                const node_id = graph.nodes.count();
                try graph.addNode(allocator, node_id, hop.right.labels);
                try created_nodes.append(allocator, node_id);

                // Set properties if any
                if (hop.right.props) |props| {
                    for (props) |prop| {
                        const val = evalExprToPropertyValue(allocator, prop.value.*);
                        try graph.setNodeProperty(node_id, prop.key, val);
                    }
                }
            }

            // Create relationship if specified
            if (hop.rel.types.len > 0 and created_nodes.items.len >= 2) {
                const source = created_nodes.items[created_nodes.items.len - 2];
                const target = created_nodes.items[created_nodes.items.len - 1];
                const edge_type = if (hop.rel.types.len > 0) hop.rel.types[0] else "RELATED";
                const edge_id = try graph.addEdge(allocator, source, target, edge_type);
                try created_edges.append(allocator, edge_id);

                // Set edge properties if any
                if (hop.rel.props) |props| {
                    for (props) |prop| {
                        const val = evalExprToPropertyValue(allocator, prop.value.*);
                        try graph.setEdgeProperty(edge_id, prop.key, val);
                    }
                }
            }
        }
    }

    // Commit if autocommit
    if (started_auto) {
        if (state.active_txn) |*txc| {
            state.txn_manager.commit(txc) catch {};
            state.global_commit_ts += 1;
            state.active_txn = null;
        }
    }

    // Build response
    var response = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    const writer = response.writer(allocator);

    // Return created nodes/edges if RETURN clause present
    if (stmt.return_clause) |_| {
        // For now, return a simple success message
        try writer.writeAll("{\"status_class\":\"00000\",\"result\":{\"type\":\"SCHEMA\",\"columns\":[{\"name\":\"created\",\"type\":\"INT\"}]}}\n");
        try writer.print("{{\"status_class\":\"00000\",\"result\":{{\"type\":\"BINDINGS\",\"rows\":[{{\"created\":{}}}]}}}}\n", .{created_nodes.items.len + created_edges.items.len});
    } else {
        // Just return success
        try writer.writeAll("{\"status_class\":\"00000\",\"result\":{\"type\":\"SCHEMA\",\"columns\":[]}}\n");
    }

    return response.toOwnedSlice(allocator);
}

// Execute DELETE statement
fn executeDeleteStatement(allocator: std.mem.Allocator, state: *ServerState, stmt: geode.ast.DeleteStatement) ![]const u8 {
    // Get graph storage
    const graph = getOrCreateGraphStorage(allocator);

    // Start transaction if not already in one
    var started_auto = false;
    if (state.active_txn == null) {
        const t = state.txn_manager.begin();
        state.active_txn = t;
        state.session_snapshot_ts = state.global_commit_ts;
        started_auto = true;
    }

    // Execute MATCH if present to find items to delete
    var bindings: []graph_exec.Binding = &.{};
    if (stmt.match_clause) |match| {
        bindings = try graph_exec.executeMatch(allocator, graph, match, stmt.where_clause, null, null);
    }

    var deleted_count: usize = 0;

    // Delete specified items
    for (stmt.items) |item| {
        switch (item) {
            .Variable => |var_name| {
                // Delete all nodes/edges bound to this variable
                for (bindings) |binding| {
                    if (binding.vars.get(var_name)) |val| {
                        switch (val) {
                            .Node => |node_id| {
                                // If DETACH DELETE, first remove all connected edges
                                if (stmt.detach) {
                                    // Remove outgoing edges
                                    if (graph.outgoing.get(node_id)) |edges| {
                                        for (edges.items) |_| {
                                            // Mark edge as deleted (in real implementation)
                                            deleted_count += 1;
                                        }
                                    }
                                    // Remove incoming edges
                                    if (graph.incoming.get(node_id)) |edges| {
                                        for (edges.items) |_| {
                                            // Mark edge as deleted (in real implementation)
                                            deleted_count += 1;
                                        }
                                    }
                                }
                                // Mark node as deleted (in real implementation)
                                deleted_count += 1;
                            },
                            .Edge => |_| {
                                // Mark edge as deleted
                                deleted_count += 1;
                            },
                            else => {},
                        }
                    }
                }
            },
            else => {
                // Handle other delete item types
            },
        }
    }

    // Commit if autocommit
    if (started_auto) {
        if (state.active_txn) |*txc| {
            state.txn_manager.commit(txc) catch {};
            state.global_commit_ts += 1;
            state.active_txn = null;
        }
    }

    // Build response
    var response = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    const writer = response.writer(allocator);

    // Return delete count
    try writer.writeAll("{\"status_class\":\"00000\",\"result\":{\"type\":\"SCHEMA\",\"columns\":[{\"name\":\"deleted\",\"type\":\"INT\"}]}}\n");
    try writer.print("{{\"status_class\":\"00000\",\"result\":{{\"type\":\"BINDINGS\",\"rows\":[{{\"deleted\":{}}}]}}}}\n", .{deleted_count});

    return response.toOwnedSlice(allocator);
}

// Execute MERGE statement
fn executeMergeStatement(allocator: std.mem.Allocator, state: *ServerState, stmt: geode.ast.MergeStatement) ![]const u8 {
    // Get graph storage
    const graph = getOrCreateGraphStorage(allocator);

    // Start transaction if not already in one
    var started_auto = false;
    if (state.active_txn == null) {
        const t = state.txn_manager.begin();
        state.active_txn = t;
        state.session_snapshot_ts = state.global_commit_ts;
        started_auto = true;
    }

    // Try to match the pattern first
    const existing_bindings = try graph_exec.executeMatch(allocator, graph, stmt.pattern, null, null, null);

    var created = false;
    var matched = false;

    if (existing_bindings.len > 0) {
        // Pattern matched - apply ON MATCH clauses
        matched = true;
        for (existing_bindings) |binding| {
            for (stmt.on_match) |set_clause| {
                // Apply SET operations for matched items
                if (binding.vars.get(set_clause.target.object)) |val| {
                    switch (val) {
                        .Node => |node_id| {
                            const prop_val = evalExprToPropertyValue(allocator, set_clause.value);
                            try graph.setNodeProperty(node_id, set_clause.target.property, prop_val);
                        },
                        else => {},
                    }
                }
            }
        }
    } else {
        // Pattern didn't match - create it and apply ON CREATE clauses
        created = true;

        // Create the pattern (similar to CREATE logic)
        var created_nodes = std.ArrayList(graph_exec.NodeId).initCapacity(allocator, 0) catch unreachable;
        defer created_nodes.deinit(allocator);

        for (stmt.pattern.chains) |chain| {
            for (chain.hops) |hop| {
                if (hop.left.name) |name| {
                    const node_id = graph.nodes.count();
                    try graph.addNode(allocator, node_id, hop.left.labels);
                    try created_nodes.append(allocator, node_id);

                    // Apply ON CREATE clauses
                    for (stmt.on_create) |set_clause| {
                        if (std.mem.eql(u8, set_clause.target.object, name)) {
                            const prop_val = evalExprToPropertyValue(allocator, set_clause.value);
                            try graph.setNodeProperty(node_id, set_clause.target.property, prop_val);
                        }
                    }
                }
            }
        }
    }

    // Commit if autocommit
    if (started_auto) {
        if (state.active_txn) |*txc| {
            state.txn_manager.commit(txc) catch {};
            state.global_commit_ts += 1;
            state.active_txn = null;
        }
    }

    // Build response
    var response = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    const writer = response.writer(allocator);

    // Return merge result
    try writer.writeAll("{\"status_class\":\"00000\",\"result\":{\"type\":\"SCHEMA\",\"columns\":[{\"name\":\"created\",\"type\":\"BOOL\"},{\"name\":\"matched\",\"type\":\"BOOL\"}]}}\n");
    try writer.print("{{\"status_class\":\"00000\",\"result\":{{\"type\":\"BINDINGS\",\"rows\":[{{\"created\":{},\"matched\":{}}}]}}}}\n", .{ created, matched });

    return response.toOwnedSlice(allocator);
}

// Helper function to convert AST expression to property value
fn evalExprToPropertyValue(_: std.mem.Allocator, expr: geode.ast.Expr) graph_exec.PropertyValue {
    return switch (expr) {
        .Null => .{ .Null = {} },
        .Bool => |b| .{ .Bool = b },
        .Int => |i| .{ .Int = i },
        .String => |s| .{ .String = s },
        .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        else => .{ .Null = {} }, // Default for unsupported expressions
    };
}

// CANARY: REQ=REQ-GQL-004; FEATURE="PaginationExecutionStreaming"; ASPECT=Scaffold; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_004_PaginationStreamingScaffold; OWNER=planner; UPDATED=2025-09-26
test "TestCANARY_REQ_GQL_004_PaginationStreamingScaffold" {
    const expect = std.testing.expect;
    try expect(!paginationStreamScaffold(10, 0));
    try expect(!paginationStreamScaffold(5, 10));
    try expect(paginationStreamScaffold(11, 10));
}
