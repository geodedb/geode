# Complete Storage Engine Migration

**Date:** 2026-03-28
**Status:** Design
**Scope:** Replace legacy `graph_store.zig` entirely with per-graph storage engine, rewrite all consumers

## 1. Problem Statement

Geode has two storage systems running in parallel:

1. **Legacy (`graph_store.zig`)**: 4000+ line file with in-memory HashMaps (`nodes`, `edges`, `outgoing_edges`, `incoming_edges`, `label_index`, `graphs`) serialized to monolithic `graph_store.dat`. All reads come from HashMap lookups. Persistence is a full re-serialization of the entire store on every cycle.

2. **Per-graph engine (`graph_storage` library + `StorageAdapter`)**: Page-based storage with buffer pool, WAL, adjacency stores, property stores, label indexes, and manifest-based crash recovery. Each graph gets its own directory with isolated files.

The dual-write between them is broken (ID mismatch: UUIDv7 vs sequential), the legacy store is the sole source of truth, and the per-graph engine's native capabilities (lazy iterators, type-filtered traversal, per-graph isolation, buffer pool caching) are completely unused by the execution engine.

### Goals

- **Remove** `graph_store.zig` entirely (4000+ lines deleted)
- **Remove** `graph_store.dat` / `.tmp` persistence format
- **Remove** all dual-write code
- **Replace** with per-graph storage engine as sole source of truth
- **Rewrite** all 169+ direct HashMap access sites in execution engine
- **Leverage** native engine capabilities: lazy iterators, type-filtered edge traversal, per-graph isolation, buffer pool
- **Wire** query planner to real storage statistics
- **Maintain** UUIDv7 IDs throughout (security + portability)
- **Achieve** 100% geodetestlab pass rate + all unit tests passing

### Non-Goals

- Migration from `graph_store.dat` format (start fresh)
- Backwards compatibility with legacy ID space
- Keeping any part of `graph_store.zig`

## 2. Architecture

```
Execution Engine
  ├── match_operations.zig   ─┐
  ├── graph_algorithms.zig    │
  ├── crud_operations.zig     ├── All use GraphStore (new) API
  ├── aggregation_eval.zig    │   with native iterators + UUIDv7
  ├── recursion_handler.zig   │
  └── centrality_algorithms  ─┘
            │
            ▼
      GraphStore (NEW src/graph_store.zig — complete rewrite)
      ├── UUIDv7 generation + ID mapping (UUIDv7 ↔ engine slot)
      ├── Engine-aware caching layer
      │   ├── Node cache (LRU, pointer-stable for Value.Node)
      │   ├── Edge cache (LRU, pointer-stable for Value.Edge)
      │   ├── Adjacency cache (lazy-populated from engine iterators)
      │   └── Label index cache (populated from engine scanLabel)
      ├── Write-through to StorageAdapter on every mutation
      └── Statistics export for query planner
            │
            ▼
      StorageAdapter (enhanced)
      ├── Edge property support
      ├── Full node/edge iteration
      ├── Statistics API
      └── Native iterator exposure
            │
            ▼
      GraphEngine (per-graph, unchanged internally)
      ├── nodes.store (dense slot addressing)
      ├── adj_out.store / adj_in.store
      ├── props.store + var.store
      ├── manifest.a / manifest.b
      └── wal/graph.wal
```

## 3. New GraphStore Design

The new `src/graph_store.zig` is a complete rewrite. It provides a clean API for the execution engine while internally delegating to the per-graph storage engine via StorageAdapter.

### 3.1 ID Strategy

**External IDs (UUIDv7):** All node and edge IDs visible to queries, clients, and the execution engine are UUIDv7 values. UUIDv7 provides:

- Time-ordered uniqueness (no collisions across graphs or instances)
- Security (no enumeration attacks possible with sequential IDs)
- Portability (IDs are globally unique, enabling future federation/replication)

**Internal IDs (dense slots):** The graph-storage engine uses sequential slot IDs for page addressing (`node_id / nodes_per_page`). Sparse UUIDv7 values cannot be used directly as page indices.

**Mapping:** Each graph maintains a persistent bidirectional map:

- `UUIDv7 → slot_id` (for writes and lookups)
- `slot_id → UUIDv7` (for iteration and edge resolution)

Persisted in `graphs/<uuid>/id_map.dat` alongside other graph files. Loaded on startup, updated on create/delete, flushed on checkpoint.

Edge IDs follow the same pattern: external UUIDv7, internal engine edge ID, persistent mapping.

### 3.2 Caching Layer

The caching layer is engine-aware, not a HashMap mirror of all data.

**Node Cache:**

- LRU cache of recently accessed `Node` structs
- Provides pointer stability for `Value.Node` (`*const Node`)
- Populated on demand from engine `getNode()` + `getAllProperties()`
- Eviction returns memory; re-access reads from engine
- Configurable capacity (default: 64K entries per graph)

**Edge Cache:**

- LRU cache of recently accessed `Edge` structs
- Same pointer stability guarantee for `Value.Edge`
- Populated from adjacency iterators
- Configurable capacity (default: 256K entries per graph)

**Adjacency Cache:**

- Per-node outgoing/incoming edge ID lists
- Lazy-populated: first access loads from engine `expandOut`/`expandIn`
- Invalidated on edge create/delete for affected nodes
- Optional: execution engine can bypass cache and use native iterators directly

**Label Index Cache:**

- Maps `label_string → ArrayList(UUIDv7)` per graph
- Populated from engine `scanLabel()` on first access per label
- Invalidated on node create/delete/label change

### 3.3 Public API

```zig
pub const GraphStore = struct {
    // === Lifecycle ===
    pub fn init(allocator: Allocator, data_dir: []const u8) !*GraphStore
    pub fn deinit(self: *GraphStore) void
    pub fn checkpoint(self: *GraphStore) !void

    // === Graph Management ===
    pub fn createGraph(self: *GraphStore, name: []const u8) !void
    pub fn dropGraph(self: *GraphStore, name: []const u8) !void
    pub fn graphExists(self: *GraphStore, name: []const u8) bool
    pub fn listGraphs(self: *GraphStore, allocator: Allocator) ![][]const u8

    // === Node CRUD (all UUIDv7 IDs) ===
    pub fn createNodeWithGraph(self: *GraphStore, labels: [][]const u8, graph: []const u8) !u64
    pub fn deleteNode(self: *GraphStore, node_id: u64, graph: []const u8) !void
    pub fn getNode(self: *GraphStore, node_id: u64) ?*const Node
    pub fn getNodePtr(self: *GraphStore, node_id: u64) ?*Node

    // === Edge CRUD ===
    pub fn createEdgeWithGraph(self: *GraphStore, from: u64, to: u64, label: []const u8, graph: []const u8) !u64
    pub fn deleteEdge(self: *GraphStore, from: u64, to: u64, edge_id: u64, graph: []const u8) !void
    pub fn getEdge(self: *GraphStore, edge_id: u64) ?*const Edge

    // === Properties ===
    pub fn setNodeProperty(self: *GraphStore, node_id: u64, key: []const u8, value: PropertyValue) !void
    pub fn getNodeProperty(self: *GraphStore, node_id: u64, key: []const u8) ?PropertyValue
    pub fn getNodePropertyValue(self: *GraphStore, node_id: u64, key: []const u8) !Value
    pub fn removeNodeProperty(self: *GraphStore, node_id: u64, key: []const u8) !void
    pub fn setEdgeProperty(self: *GraphStore, edge_id: u64, key: []const u8, value: PropertyValue) !void
    pub fn getEdgeProperty(self: *GraphStore, edge_id: u64, key: []const u8) ?PropertyValue

    // === Labels ===
    pub fn addNodeLabel(self: *GraphStore, node_id: u64, label: []const u8) !void
    pub fn removeNodeLabel(self: *GraphStore, node_id: u64, label: []const u8) !void
    pub fn getNodesByLabel(self: *GraphStore, label: []const u8) []u64
    pub fn getNodesByLabels(self: *GraphStore, graph: []const u8, labels: [][]const u8) !ArrayList(u64)

    // === Edge Traversal (native iterators) ===
    pub fn getEdgesFrom(self: *GraphStore, node_id: u64) []Edge  // cached slice
    pub fn getEdgesTo(self: *GraphStore, node_id: u64) []Edge    // cached slice
    pub fn getOutgoingEdgeIds(self: *GraphStore, node_id: u64) ?[]u64
    pub fn getIncomingEdgeIds(self: *GraphStore, node_id: u64) ?[]u64
    pub fn expandOut(self: *GraphStore, node_id: u64, rel_type: ?[]const u8) !EdgeIterator  // native lazy
    pub fn expandIn(self: *GraphStore, node_id: u64, rel_type: ?[]const u8) !EdgeIterator   // native lazy

    // === Iteration ===
    pub fn nodeIterator(self: *GraphStore) NodeIterator         // graph-scoped
    pub fn edgeIterator(self: *GraphStore) EdgeIterator
    pub fn nodeIteratorForGraph(self: *GraphStore, graph: []const u8) !NodeIterator

    // === Counts ===
    pub fn getNodeCount(self: *GraphStore) u64          // O(1) from manifest
    pub fn getEdgeCount(self: *GraphStore) u64          // O(1) from manifest
    pub fn getNodeCountForGraph(self: *GraphStore, graph: []const u8) u64

    // === Statistics (for query planner) ===
    pub fn getStoreStats(self: *GraphStore) StoreStats
    pub fn getGraphStats(self: *GraphStore, graph: []const u8) ?GraphStats

    // === Transactions ===
    pub fn beginTransaction(self: *GraphStore, graph: []const u8) !u64
    pub fn commitTransaction(self: *GraphStore, graph: []const u8, txn_id: u64) !void
    pub fn abortTransaction(self: *GraphStore, graph: []const u8, txn_id: u64) !void

    // === Global singleton ===
    pub fn getGlobalStore(allocator: Allocator) *GraphStore     // same pattern as before
    pub fn initGlobalStore(allocator: Allocator, data_dir: []const u8) !*GraphStore
    pub fn deinitGlobalStore() void
};
```

### 3.4 Types

```zig
pub const Node = struct {
    id: u64,                                    // UUIDv7
    labels: [][]const u8,
    properties: std.StringHashMap(PropertyValue),
    graph_name: []const u8,
};

pub const Edge = struct {
    id: u64,                                    // UUIDv7
    from_id: u64,                               // UUIDv7
    to_id: u64,                                 // UUIDv7
    label: []const u8,
    properties: std.StringHashMap(PropertyValue),
    graph_name: []const u8,
};

// PropertyValue unchanged — same union type
pub const PropertyValue = union(enum) {
    String: []const u8,
    Int: i64,
    Float: f64,
    Bool: bool,
    Null,
    ExtValue: @import("eval_extended.zig").ExtValue,
    Decimal: struct { coeff: i128, scale: u8 },
};

pub const StoreStats = struct {
    node_count: u64,
    edge_count: u64,
    label_counts: std.StringHashMap(u64),    // label → node count
    graph_count: u64,
    pages_used: u64,                          // from manifest
    buffer_pool_hit_rate: f64,
};

pub const EdgeIterator = struct {
    // Wraps engine's AdjEdgeIterator with UUIDv7 translation
    pub fn next(self: *EdgeIterator) !?Edge
    pub fn deinit(self: *EdgeIterator) void
};

pub const NodeIterator = struct {
    // Wraps engine's node scan with UUIDv7 translation + property loading
    pub fn next(self: *NodeIterator) !?*const Node
    pub fn deinit(self: *NodeIterator) void
};
```

## 4. StorageAdapter Enhancements

### 4.1 New Methods

| Method | Purpose |
|--------|---------|
| `createNodeWithId(graph, slot_id, labels)` | Accept pre-allocated slot ID (for ID map coordination) |
| `setEdgeProperty(graph, edge_id, key, value)` | Edge property support via engine's PropStore |
| `getEdgeProperty(graph, edge_id, key)` | Edge property retrieval |
| `getAllEdgeProperties(graph, edge_id)` | Edge property iteration |
| `scanAllNodes(graph, callback)` | Full node iteration via engine's `NodeStore.scanAll()` |
| `getStoreStats(graph) -> GraphStats` | Manifest statistics export |
| `expandOutNative(graph, slot_id, rel_type?) -> AdjEdgeIterator` | Expose engine iterator directly |
| `expandInNative(graph, slot_id, rel_type?) -> AdjEdgeIterator` | Expose engine iterator directly |
| `getAllNodeProperties(graph, slot_id) -> PropIterator` | Lazy property iteration |

### 4.2 Edge Property Storage

Engine's `EdgeEntry.prop_head` field exists but is unused. Wire it up:

```
createEdge:
  entry.prop_head = 0  (no properties initially)

setEdgeProperty(edge_id, key, value):
  1. Find edge in adjacency store (scan out-adj of source node)
  2. Get current prop_head from EdgeEntry
  3. engine.putProperty(prop_head, key, value) → new_prop_head
  4. Update EdgeEntry.prop_head in adjacency page
```

## 5. Execution Engine Rewrite

### 5.1 Direct HashMap Access Elimination

**169+ sites** currently access `store.nodes`, `store.edges`, `store.outgoing_edges`, `store.incoming_edges`, `store.label_index`, `store.graphs` directly.

All are replaced with GraphStore method calls:

| Old Pattern | New Pattern | Count |
|-------------|-------------|-------|
| `store.nodes.get(id)` | `store.getNode(id)` | 10+ |
| `store.nodes.getPtr(id)` | `store.getNodePtr(id)` | 50+ |
| `store.nodes.iterator()` | `store.nodeIterator()` or `store.nodeIteratorForGraph(g)` | 20+ |
| `store.nodes.valueIterator()` | `store.nodeIterator()` | 1+ |
| `store.nodes.count()` | `store.getNodeCount()` | 3+ |
| `store.edges.get(id)` | `store.getEdge(id)` | 5+ |
| `store.edges.getPtr(id)` | `store.getEdge(id)` | 10+ |
| `store.edges.iterator()` | `store.edgeIterator()` | 15+ |
| `store.edges.count()` | `store.getEdgeCount()` | 2+ |
| `store.outgoing_edges.get(id)` | `store.getOutgoingEdgeIds(id)` | 6+ |
| `store.incoming_edges.get(id)` | `store.getIncomingEdgeIds(id)` | 6+ |
| `store.graphs.contains(name)` | `store.graphExists(name)` | 5+ |
| `store.graphs.put(name, {})` | `store.createGraph(name)` | 4+ |
| `store.graphs.remove(name)` | `store.dropGraph(name)` | 4+ |
| `store.getEdgesFrom(id)` | `store.expandOut(id, null)` (lazy iterator) | 23+ |
| `store.getEdgesTo(id)` | `store.expandIn(id, null)` (lazy iterator) | 23+ |

### 5.2 Performance Upgrades in Execution

**Edge traversal** (23+ sites in match_operations.zig):

- Before: `getEdgesFrom()` allocates ArrayList, copies all edges, returns owned slice
- After: `expandOut(node_id, rel_type)` returns lazy iterator, zero-copy, with built-in type filtering

**Graph isolation** (every MATCH/CREATE path):

- Before: Iterate all nodes, post-filter with `if (!std.mem.eql(u8, node.graph_name, target_graph)) continue`
- After: `nodeIteratorForGraph(graph)` iterates only the target graph's engine — no cross-graph data touched

**Type-filtered traversal** (match_operations.zig pattern matching):

- Before: Get all edges, loop, `if (!std.mem.eql(u8, edge.label, rt)) continue`
- After: `expandOut(node_id, "KNOWS")` — engine filters at adjacency store level

**Variable-length paths** (match_operations.zig VLCR at line 5132+):

- Before: Direct adjacency HashMap access, edge-by-edge materialization
- After: Native `expandOut`/`expandIn` iterators, no intermediate allocations

### 5.3 Files Modified

| File | Changes |
|------|---------|
| `src/execution/match_operations.zig` | 72+ access replacements, iterator upgrades, graph isolation |
| `src/execution/graph_algorithms.zig` | 20+ replacements, iterator upgrades |
| `src/execution/aggregation_evaluation.zig` | 11+ replacements, graph-scoped counts |
| `src/execution/crud_operations.zig` | Write-through paths, UUIDv7 IDs |
| `src/execution/recursion_handler.zig` | 5 edge iterator replacements |
| `src/execution/statement_dispatcher.zig` | 7 graph registry replacements |
| `src/execution/centrality_algorithms.zig` | Adjacency access via API |
| `src/execution/statement_handlers.zig` | 1 replacement |
| `src/execution/expression_eval.zig` | Property access patterns |
| `src/ml/integration_enhanced.zig` | 13 adjacency replacements |
| `src/schema/catalog.zig` | Graph registry via store API |
| `src/value_types.zig` | Node/Edge types from new graph_store |
| `src/eval.zig` | Edge iterator replacements |
| `src/temporal/time_travel.zig` | Snapshot access replacements |
| `src/graph/builtin_algorithms.zig` | 50+ neighbor query replacements |
| `src/wal.zig` | Checkpoint integration |

## 6. Query Planner Integration

### 6.1 Statistics Provider

Wire `StorageStatsProvider` vtable in `src/planner/cbo.zig` to real engine data:

```zig
const EngineStatsProvider = struct {
    store: *GraphStore,

    fn getRowCount(ctx: *anyopaque, table: []const u8) u64 {
        const self = @as(*EngineStatsProvider, @ptrCast(@alignCast(ctx)));
        // "table" is graph name for node counts, or "edges:<graph>" for edge counts
        return self.store.getNodeCountForGraph(table);
    }

    fn getPageCount(ctx: *anyopaque, table: []const u8) u64 {
        const self = @as(*EngineStatsProvider, @ptrCast(@alignCast(ctx)));
        const stats = self.store.getGraphStats(table) orelse return 0;
        return stats.pages_used;
    }

    fn getDistinctCount(ctx: *anyopaque, table: []const u8, column: []const u8) u64 {
        // For "label" column: number of distinct labels
        // For property columns: estimated distinct values
        ...
    }
};
```

### 6.2 Statistics Refresh

On each `checkpoint()` cycle, update the `StatsRegistry` with fresh statistics from each graph engine's manifest. This provides the CBO's `CardinalityEstimator` with real cardinality data instead of defaults/assumptions.

### 6.3 Plan Cache Invalidation

When `createGraph`, `dropGraph`, `createNode`, `deleteNode` change graph structure, increment the `invalidation_epoch` on the plan cache so stale plans are evicted.

### 6.4 Scan Strategy Selection

The planner's `ScanStrategy` enum (`full_scan | index_scan | label_scan`) maps to:

- `full_scan` → `store.nodeIteratorForGraph(graph)`
- `label_scan` → `store.getNodesByLabels(graph, labels)`
- `index_scan` → future: property index integration

## 7. ID Map Format

### 7.1 File: `graphs/<uuid>/id_map.dat`

Binary format:

```
Header (32 bytes):
  magic: "GIDM" (4 bytes)
  version: u32 (4 bytes)
  node_count: u64 (8 bytes)
  edge_count: u64 (8 bytes)
  crc32: u32 (4 bytes)
  reserved: u32 (4 bytes)

Node entries (16 bytes each, sorted by slot_id):
  uuid7: u64 (8 bytes)
  slot_id: u64 (8 bytes)

Edge entries (16 bytes each, sorted by engine_edge_id):
  uuid7: u64 (8 bytes)
  engine_edge_id: u64 (8 bytes)
```

### 7.2 Persistence

- Written atomically via temp file + rename (same pattern as manifest)
- Flushed on every `checkpoint()` call
- On startup: loaded into in-memory HashMaps for O(1) lookup

### 7.3 UUIDv7 Generation

Use existing `src/uuid.zig` with proper UUIDv7 implementation:

- 48-bit Unix timestamp (milliseconds)
- 4-bit version (7)
- 12-bit random
- 2-bit variant
- 62-bit random

Monotonic within same millisecond via atomic counter.

## 8. Persistence Model

### 8.1 Write Path

Every mutation writes through to the engine immediately:

1. Caller invokes `store.createNodeWithGraph(labels, graph)`
2. GraphStore generates UUIDv7, calls `adapter.createNode()` → gets slot_id
3. Updates ID map (in-memory + marks dirty)
4. Updates caches (node cache, label index cache)
5. Returns UUIDv7

No deferred writes. No dirty flags on the store itself. The engine's buffer pool handles page-level dirty tracking and flushing.

### 8.2 Checkpoint

`store.checkpoint()` does:

1. `adapter.checkpointAll()` — flushes all engine buffer pools, writes manifests
2. Persist ID maps for each dirty graph → `id_map.dat`
3. Persist label dictionaries (already handled by engine)

### 8.3 Background Persistence Loop

Replace old `persistenceLoop()` with:

```zig
fn persistenceLoop() void {
    while (!shutdown.load(.acquire)) {
        Thread.sleep(1 * ns_per_s);
        if (global_store) |store| {
            store.checkpoint() catch |err| {
                log.err("checkpoint failed: {s}", .{@errorName(err)});
            };
        }
    }
}
```

### 8.4 Crash Recovery

On startup:

1. Engine opens each graph directory, reads manifest (A/B), replays WAL
2. GraphStore loads `id_map.dat` per graph
3. Caches are lazily populated on first access (not at startup)

## 9. Files Deleted

| File/Code | Reason |
|-----------|--------|
| `src/graph_store.zig` (entire file, 4000+ lines) | Replaced by complete rewrite |
| `graph_store.dat` format and persistence | Replaced by engine persistence |
| `src/storage/migration.zig` | No migration support |
| All dual-write code paths | Single write path through engine |

## 10. Files Created

| File | ~Lines | Purpose |
|------|--------|---------|
| `src/graph_store.zig` (new) | 2500 | Complete rewrite — cache + API over StorageAdapter |
| `src/storage/id_map.zig` | 500 | Persistent bidirectional UUIDv7 ↔ slot mapping with serialization |
| `tests/test_graph_cache.zig` | 1000 | Unit tests: CRUD, caching, ID mapping, consistency |
| `tests/test_id_map.zig` | 400 | Unit tests: serialization, crash recovery, concurrent access |
| `tests/test_storage_integration.zig` | 600 | Integration tests: write-through, checkpoint, restart |

## 11. Files Modified

| File | Changes |
|------|---------|
| `src/storage/graph_storage_adapter.zig` | Edge properties, iteration, stats, native iterators |
| `src/execution/match_operations.zig` | 72+ replacements, native iterators, graph isolation |
| `src/execution/graph_algorithms.zig` | 20+ replacements, native iterators |
| `src/execution/aggregation_evaluation.zig` | 11+ replacements, graph-scoped counts |
| `src/execution/crud_operations.zig` | Write-through, UUIDv7 IDs |
| `src/execution/recursion_handler.zig` | 5 iterator replacements |
| `src/execution/statement_dispatcher.zig` | 7 graph registry replacements |
| `src/execution/centrality_algorithms.zig` | Adjacency via API |
| `src/execution/statement_handlers.zig` | 1 replacement |
| `src/execution/expression_eval.zig` | Property access |
| `src/ml/integration_enhanced.zig` | 13 adjacency replacements |
| `src/schema/catalog.zig` | Graph registry via store API |
| `src/value_types.zig` | Import from new graph_store |
| `src/server/server_init.zig` | Init new GraphStore |
| `src/server/quic_connection_handler.zig` | Import changes |
| `src/planner/cbo.zig` | Wire StorageStatsProvider |
| `src/planner/cost_model.zig` | Real statistics integration |
| `src/server/query_plan_cache.zig` | StoreStats from engine |
| `src/graph/builtin_algorithms.zig` | 50+ neighbor query replacements |
| `src/wal.zig` | Checkpoint integration |
| `src/eval.zig` | Edge iterator replacements |
| `src/temporal/time_travel.zig` | Snapshot access replacements |
| `src/fuzz/graphstore_durability_fuzz.zig` | New GraphStore API |

## 12. Testing Strategy

### 12.1 Unit Tests

- `zig build test` must pass with zero failures
- New test files cover: GraphStore CRUD, ID mapping, cache consistency, checkpoint/recovery, edge properties, native iterators

### 12.2 Integration Tests (geodetestlab)

- Full suite: 193 specs, ~3844 tests
- Target: **100% pass rate**
- Run via: `cd ../geode-test-harness && make test`

### 12.3 Load Tests

- Run `make loadtest-compare` against baseline
- No QPS regression > 20%
- No p50 latency regression > 20%

## 13. Risk Assessment

| Risk | Mitigation |
|------|------------|
| Pointer stability for `Value.Node` / `Value.Edge` | LRU cache provides stable pointers; no eviction during query execution (pin mechanism) |
| ID map corruption on crash | Atomic write via temp+rename; engine WAL replay recovers slot allocations |
| Performance regression from ID translation | O(1) HashMap lookup; amortized by reduced memory allocation from native iterators |
| Large scope (30+ files modified) | Phased implementation; unit tests at each phase; geodetestlab validation after each major phase |
| Buffer pool sizing | Configurable; default 64K pages per graph; auto-grow based on manifest page counts |

## 14. Success Criteria

1. `graph_store.dat` does not exist anywhere in the codebase or on disk
2. `zig build test` passes with zero failures
3. `make geodetestlab-comprehensive` achieves 100% pass rate
4. `make loadtest-compare` shows no regressions
5. All node/edge IDs are UUIDv7 format
6. Per-graph directories contain all persistent state
7. No in-memory-only data paths (everything persisted through engine)
