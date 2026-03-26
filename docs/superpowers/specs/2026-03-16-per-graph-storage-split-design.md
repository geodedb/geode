# Per-Graph Storage Split Design

**Date**: 2026-03-16
**Status**: Approved
**Author**: Claude + Benji

## Problem

Geode stores all graph data in a single monolithic `graph_store.dat` file. With multiple large graphs, this causes:

- **Performance**: Every save serializes ALL graphs, even if only one changed
- **Scalability**: File size grows linearly with total data across all graphs
- **Blast radius**: Corruption in the file affects all graphs
- **I/O waste**: Loading the server reads all graphs into memory even if only one is queried

## Solution

Split `graph_store.dat` into per-graph files stored in a `graphs/` subdirectory. A registry file maps graph names to opaque UUIDv7 filenames (no data exposure from filenames). Automatic migration from the monolithic format on first startup.

## Data Directory Layout

```
/var/lib/geode/
  graph_registry.dat       # Graph name -> UUID mapping + global counters
  geode_catalog.dat        # Existing catalog (schemas, indexes, constraints)
  geode_wal.log            # Existing WAL (already has graph_name per record)
  .geode_hmac_key          # Existing HMAC key
  server.crt / server.key  # Existing TLS certs
  graphs/                  # Per-graph data directory
    <uuid1>.dat            # All nodes/edges for one graph
    <uuid2>.dat            # All nodes/edges for another graph
    ...
```

## File Formats

### Graph Registry (`graph_registry.dat`)

CRC32 covers the entire file (header fields + all graph entries).

```
[Header - 44 bytes]
  Magic: "GEODREG1" (8 bytes)
  Version: u32 = 1
  Reserved: u32 = 0
  next_node_id: u64          # Global counter (shared across all graphs)
  next_edge_id: u64          # Global counter
  graph_count: u64
  CRC32: u32                 # Covers header fields + all entries below

[Graph Entries]
  For each graph:
    name_len: u32
    name: [name_len]u8
    uuid: [16]u8             # 128-bit UUIDv7 (time-sortable)
    node_count: u64          # Per-graph stats
    edge_count: u64
```

### Per-Graph File (`graphs/<uuid>.dat`)

CRC32 covers the entire file (header fields + all node/edge data).

```
[Header - 36 bytes]
  Magic: "GEODGRF1" (8 bytes)
  Version: u32 = 1
  Reserved: u32 = 0
  node_count: u64
  edge_count: u64
  CRC32: u32                 # Covers header fields + all data below

[Nodes]
  Same serialization as current graph_store.zig but WITHOUT graph_name field
  (graph membership is implicit from the file)

[Edges]
  Same serialization but WITHOUT graph_name field
```

## In-Memory Architecture

### GraphHandle

New struct representing a single graph's data:

```zig
pub const GraphHandle = struct {
    allocator: std.mem.Allocator,
    uuid: [16]u8,
    name: []const u8,
    dirty: bool = false,
    available: bool = true,       // false if graph file missing/corrupt on load
    nodes: std.AutoHashMap(u64, Node),
    edges: std.AutoHashMap(u64, Edge),
    label_index: std.StringHashMap(std.ArrayList(u64)),
    outgoing_edges: std.AutoHashMap(u64, std.ArrayList(u64)),
    incoming_edges: std.AutoHashMap(u64, std.ArrayList(u64)),
    node_count: u64 = 0,
    edge_count: u64 = 0,
    rwlock: std.Thread.RwLock = .{},  // Per-graph lock
};
```

### Node/Edge `graph_name` Field

The in-memory `Node` and `Edge` structs **retain** the `graph_name` field for backward compatibility with the many code paths that read `node.graph_name`. During deserialization from a per-graph file, the `graph_name` is populated from the parent `GraphHandle.name`. During serialization to a per-graph file, the `graph_name` field is skipped (implicit from file identity).

This avoids a massive refactor of every caller that reads `node.graph_name` while still saving disk space.

### GraphStore Changes

```zig
// Before (monolithic)
graphs: std.StringHashMap(void),
nodes: std.AutoHashMap(u64, Node),
edges: std.AutoHashMap(u64, Edge),

// After (per-graph)
graph_handles: std.StringHashMap(*GraphHandle),
graph_handles_mutex: std.Thread.Mutex = .{},  // Protects graph_handles map itself
// Global counters remain on GraphStore
next_node_id: u64,
next_edge_id: u64,
data_dir: []const u8,  // Base path for graphs/ directory
```

### Key Behavioral Changes

- `saveIfDirty()` iterates all GraphHandles, saves only dirty ones (acquires per-graph read lock)
- `saveGraph(handle)` writes single `graphs/<uuid>.dat`
- `saveRegistry()` writes `graph_registry.dat` (only on graph create/drop)
- Label index keys simplify from `"graph:label"` to just `"label"` (scoped per GraphHandle)
- `getNodesByLabel(graph, label)` looks up GraphHandle by graph name, searches its local label index
- Node/edge creation routes to the correct GraphHandle
- Queries against an unavailable graph (`available == false`) return error `"Graph unavailable: file missing or corrupt"`

## Concurrency

### Locking Strategy

Replace the current single `g_store_rwlock` with a two-level locking scheme:

1. **`graph_handles_mutex`** (Mutex): Protects the `graph_handles` map itself. Held briefly during CREATE/DROP GRAPH and during graph handle lookups. Not held during data operations.

2. **Per-graph `rwlock`** (RwLock on each GraphHandle): Protects the graph's data (nodes, edges, indexes). Multiple readers can query the same graph concurrently. Writers (mutations, persistence) acquire exclusive access to only the affected graph.

### Persistence Thread

The persistence thread iterates `graph_handles` (acquiring `graph_handles_mutex` briefly to snapshot the handle list), then for each dirty handle:
1. Acquire the handle's write lock
2. Serialize and write the per-graph file
3. Clear dirty flag
4. Release write lock

This allows queries against other graphs to proceed unblocked during persistence.

## Migration

### Trigger

On startup, detect state and act:

- `graph_store.dat` exists, `graph_registry.dat` does NOT exist → run migration
- `graph_store.dat.migrated` exists alongside `graph_registry.dat` → normal start (post-migration state, log that backup can be cleaned up)
- `graph_store.dat` exists AND `graph_registry.dat` exists (no `.migrated`) → previous migration was interrupted; delete partial `graphs/` directory and re-run migration
- Only `graph_registry.dat` exists → normal per-graph load

### Flow

1. Load monolithic `graph_store.dat` into memory (existing `loadFromFile`)
2. Create `graphs/` directory
3. For each graph in the in-memory registry:
   a. Generate UUIDv7
   b. Extract nodes/edges belonging to that graph
   c. Write per-graph file to `graphs/<uuid>.dat` with CRC32
4. Write `graph_registry.dat` with all mappings and global counters
5. Rename `graph_store.dat` to `graph_store.dat.migrated` (backup)
6. Log migration summary to stderr (graph count, node/edge counts per graph)

### Interrupted Migration Recovery

If `graph_store.dat` + `graph_registry.dat` both exist (no `.migrated`), the previous migration wrote the registry but didn't finish renaming the old file. Delete `graph_registry.dat` and the `graphs/` directory, then re-run migration from the original monolithic file.

## Graph Operations

### CREATE GRAPH "foo"

1. Generate UUIDv7
2. Create GraphHandle with allocator, initialize empty data structures
3. Acquire `graph_handles_mutex`, insert handle
4. Write empty `graphs/<uuid>.dat`
5. Update and persist `graph_registry.dat`
6. Update catalog

### DROP GRAPH "foo"

1. Acquire `graph_handles_mutex`, remove handle
2. Acquire handle's write lock, free all resources
3. Delete `graphs/<uuid>.dat` from disk
4. Update and persist `graph_registry.dat`
5. Update catalog

### USE GRAPH "foo"

No change — sets session graph name. All subsequent queries route to the matching GraphHandle.

## WAL Integration

The WAL already stores `graph_name` per record. During replay:

- Look up GraphHandle by `graph_name`
- Apply mutation to that handle's data structures
- No WAL format changes needed

### Checkpoint Flow

1. Snapshot the list of dirty GraphHandles (acquire `graph_handles_mutex` briefly)
2. For each dirty handle: save its per-graph file (acquires per-graph write lock)
3. Update `graph_registry.dat` if any graph stats changed
4. Record the checkpoint LSN
5. Truncate WAL records only up to the minimum LSN across all graphs — if a graph was skipped (not dirty), its WAL records must be preserved

This ensures no WAL records are lost for graphs that haven't been checkpointed yet.

## TDE Integration

Each per-graph file is encrypted/decrypted independently using the same TDE key. No change to the encryption API — it operates on file byte contents.

## Backup System

The S3 backup system (`src/server/backup_manager.zig`, `src/cli/backup_cli.zig`) currently backs up `graph_store.dat` as a single file. Changes needed:

- Backup must now archive `graph_registry.dat` + all files in `graphs/` directory
- Restore must recreate the `graphs/` directory and all per-graph files
- Incremental backup can skip unchanged graph files (based on modification time or dirty tracking)

## CSR Adjacency Structure

The current `GraphStore` has an optional `csr` field (Compressed Sparse Row) for fast graph algorithm traversal. With per-graph storage, the CSR must be built per-graph. The `GraphHandle` should hold its own optional CSR, built on demand when graph algorithms execute against that graph.

## Multi-Tenancy

The current `GraphStore` has `tenant_id` and `schema_name` fields. For this design, tenant isolation remains at the session/query level. Two tenants with a graph named "foo" would map to different entries in the registry (the graph name would be qualified by tenant context at the session layer, e.g., `tenant1:foo` vs `tenant2:foo`). The per-graph file split does not change tenant isolation semantics.

## Error Handling

- **Partial write**: Each file has its own CRC32 — corruption is isolated to one graph
- **Missing graph file**: Log error, set `handle.available = false`, continue serving other graphs. Queries against unavailable graphs return a clear error message.
- **Registry/file mismatch**: Validate on startup — if registry lists a UUID with no file, log warning and mark unavailable. If `graphs/` contains files not in registry, log warning and ignore.

## Testing Plan

### Unit Tests

- `graph_registry.zig`: serialization/deserialization round-trip, CRC validation, corrupt data handling, UUIDv7 generation
- Per-graph file I/O: write nodes/edges without graph_name, read back with graph_name populated from handle, verify
- Migration logic: create monolithic format in memory, run migration, verify per-graph files and registry
- GraphHandle: CRUD operations, label index, dirty tracking, concurrency (multi-threaded read/write)
- Interrupted migration recovery: simulate partial migration, verify re-run succeeds

### Integration Tests (geodetestlab)

- Multi-graph creation + data isolation (create data in graph A, verify not visible in graph B)
- Server restart persistence (create data, restart, verify data survives per-graph)
- DROP GRAPH file cleanup (drop graph, verify UUID file deleted)
- Migration from monolithic format (start with old-format data, verify auto-migration)
- Unavailable graph error handling (corrupt a graph file, verify server starts and serves other graphs)

### Updated Existing Specs

Any spec that creates graphs or relies on data persistence needs verification against the new storage layout.

## Files to Create/Modify

### New Files

- `src/graph_registry.zig` — Registry file I/O, UUIDv7 generation, mapping
- `src/storage/migration.zig` — Monolithic-to-split migration logic
- `src/graph_handle.zig` — Per-graph data container with locking

### Modified Files (Core)

- `src/graph_store.zig` — Replace monolithic storage with per-graph GraphHandles
- `src/server/server_init.zig` — Migration detection, new loading flow
- `src/server/main.zig` — Updated initialization sequence
- `src/wal.zig` — Per-graph checkpoint, WAL replay routing

### Modified Files (Query Execution)

- `src/execution/match_operations.zig` — Route queries through GraphHandle
- `src/execution/crud_operations.zig` — Route mutations through GraphHandle
- `src/execution/statement_dispatcher.zig` — CREATE/DROP GRAPH updates
- `src/execution/statement_handlers.zig` — Graph operation handlers
- `src/execution/query_execution.zig` — Graph context resolution
- `src/execution/procedure_registry.zig` — Built-in procedure graph access
- `src/execution/graph_algorithms.zig` — Per-graph CSR and algorithm execution

### Modified Files (Evaluation)

- `src/execution.zig` — Graph store access patterns
- `src/eval.zig` — Expression evaluation graph access

### Modified Files (Server/Transport)

- `src/server/quic_connection_handler.zig` — Per-connection graph resolution
- `src/server/backup_manager.zig` — Multi-file backup/restore
- `src/transport/grpc_server.zig` — gRPC handler graph access

### Modified Files (Other)

- `src/schema/catalog.zig` — Ensure catalog stays in sync with registry
- `src/txn_undo_log.zig` — Transaction undo routing to correct GraphHandle
- `src/cli/backup_cli.zig` — CLI backup command updates
- `src/distributed/cluster.zig` — Cluster replication graph routing
