# Graph Execution API Documentation

## Overview

The Geode graph execution engine provides comprehensive support for ISO/IEC 39075:2024 (GQL) graph pattern matching, including OPTIONAL MATCH, variable-length paths, and advanced MVCC transaction management.

## Core Components

### 1. Pattern Matching

#### MATCH Operator
```zig
pub fn executeMatch(
    allocator: std.mem.Allocator,
    graph: *const GraphStorage,
    pattern: geode.ast.GraphPattern,
    where_clause: ?geode.ast.Expr,
) ![]Binding
```
Executes basic graph pattern matching with WHERE clause filtering.

#### OPTIONAL MATCH Operator
```zig
pub fn executeOptionalMatch(
    allocator: std.mem.Allocator,
    graph: *const GraphStorage,
    base_bindings: []const Binding,
    pattern: geode.ast.GraphPattern,
    where_clause: ?geode.ast.Expr,
) ![]Binding
```
Implements left-outer join semantics, preserving base bindings with NULL values for unmatched patterns.

**Example:**
```gql
MATCH (n:Person)
OPTIONAL MATCH (n)-[r:KNOWS]->(m:Person)
RETURN n.name, m.name
```
Returns all persons, with NULL for m.name when no KNOWS relationship exists.

### 2. Variable-Length Path Traversal

#### PathExpand Operator
```zig
pub fn pathExpand(
    allocator: std.mem.Allocator,
    graph: *const GraphStorage,
    bindings: []const Binding,
    source_var: []const u8,
    edge_types: []const []const u8,
    direction: geode.ast.RelDir,
    min_hops: u32,
    max_hops: u32,
    target_var: ?[]const u8,
    path_var: ?[]const u8,
) ![]Binding
```

Performs bounded breadth-first search for variable-length paths.

**Features:**
- Configurable min/max hop counts
- Cycle detection and prevention
- Efficient memory management
- Support for directed and undirected traversal

**Example:**
```gql
MATCH (a:Node)-[:NEXT*1..3]->(b:Node)
RETURN a, b
```
Returns all paths from a to b with 1 to 3 NEXT relationships.

#### Path Tie-Breaking Policy
```zig
pub fn applyPathTieBreaking(
    allocator: std.mem.Allocator,
    paths: []const BindingValue,
) !BindingValue
```

Implements deterministic path selection (UA005/UA006):
1. Shortest path length
2. Lexicographically smallest start node ID
3. Lexicographically smallest end node ID
4. Lexicographically smallest intermediate node IDs

### 3. Binding Values

```zig
pub const BindingValue = union(enum) {
    Node: NodeId,
    Edge: EdgeId,
    Path: []const NodeId,
    Value: PropertyValue,
    Null,  // For OPTIONAL MATCH
};
```

Extended to support NULL values for OPTIONAL MATCH results.

## Transaction Management

### MVCC Conflict Detection

#### Conflict Types
```zig
pub const ConflictType = enum {
    WriteWrite,     // Two transactions writing same resource
    WriteRead,      // Write-read conflict (dirty read prevention)
    ReadWrite,      // Read-write conflict (lost update prevention)
    PhantomRead,    // Phantom read conflict
    Deadlock,       // Deadlock detected
};
```

#### Conflict Detection
```zig
pub fn detectConflict(
    self: *MVCCManager,
    txn: *Transaction,
    resource_id: u64,
    operation: enum { Read, Write }
) !?ConflictInfo
```

Comprehensive conflict detection matrix checking:
- Write-write conflicts between concurrent transactions
- Read-write conflicts for lost update prevention
- Write-read conflicts for dirty read prevention
- Phantom read detection for serializable isolation

#### Error Mapping
```zig
pub fn conflictToError(conflict: ConflictInfo) !protocol.DiagnosticInfo
```

Maps conflicts to ISO SQL error code 40001 (serialization failure) with detailed diagnostics.

### Transaction Validation
```zig
pub fn validateTransaction(
    self: *MVCCManager,
    txn: *Transaction
) !bool
```

Validates transactions at commit time:
- Snapshot isolation: checks for write-write conflicts
- Serializable: additional phantom read validation
- Returns false if conflicts detected, triggering rollback

## Storage Persistence

### Graph Metadata
```zig
const GraphMetadata = struct {
    node_count: u64,
    edge_count: u64,
    max_node_id: u64,
    max_edge_id: u64,
    nodes_page_id: u32,
    edges_page_id: u32,
    adjacency_page_id: u32,
    properties_page_id: u32,
    created_at: i64,
    modified_at: i64,
};
```

### Persistence Operations

#### Save Graph Metadata
```zig
pub fn saveGraphMetadata(
    self: *StorageCatalog,
    node_count: u64,
    edge_count: u64,
    max_node_id: u64,
    max_edge_id: u64
) !void
```

#### Page Management
```zig
pub fn writeGraphPage(
    self: *StorageCatalog,
    page_type: enum { Nodes, Edges, Adjacency, Properties },
    data: []const u8
) !void

pub fn readGraphPage(
    self: *StorageCatalog,
    page_type: enum { Nodes, Edges, Adjacency, Properties }
) ![]const u8
```

### Integration with --data_dir

The server automatically persists and loads graph data when started with `--data_dir`:

```bash
# Start with persistent storage
./geoded --data_dir /path/to/data

# Graph is automatically loaded on startup
# Graph is automatically saved on shutdown
```

Fallback to JSONL format ensures compatibility with existing data formats.

## Usage Examples

### Complete Example: Social Network Query

```gql
-- Find friends and optional friends-of-friends
MATCH (person:Person {name: 'Alice'})
OPTIONAL MATCH (person)-[:KNOWS]->(friend:Person)
OPTIONAL MATCH (friend)-[:KNOWS*1..2]->(fof:Person)
WHERE fof.name <> 'Alice'
RETURN person.name, friend.name, fof.name
ORDER BY friend.name, fof.name
```

This query:
1. Finds Alice
2. Optionally matches direct friends
3. Optionally finds friends-of-friends up to 2 hops
4. Filters out Alice from results
5. Returns ordered results with NULLs for missing relationships

### Transaction Example

```gql
BEGIN;

MATCH (a:Account {id: 1})
SET a.balance = a.balance - 100;

MATCH (b:Account {id: 2})
SET b.balance = b.balance + 100;

COMMIT;
```

If concurrent transactions modify the same accounts, MVCC conflict detection will:
1. Detect write-write conflicts
2. Return ISO 40001 error
3. Automatically rollback the conflicting transaction

## Performance Considerations

### Memory Management
- BFS traversal uses queue-based approach for memory efficiency
- Path storage optimized with ArrayList for dynamic growth
- Cycle detection uses HashMap for O(1) lookups

### Optimization Strategies
- CSR adjacency structure for efficient graph traversal
- Page-based storage for large graphs
- Conflict detection matrix for fast validation

### Scalability
- Bounded path traversal prevents unbounded memory growth
- Configurable spill thresholds for large result sets
- Persistent storage enables graphs larger than memory

## Error Handling

All operations return proper ISO GQL error codes:
- **40001**: Serialization failure (conflicts)
- **US001**: Unordered pagination error
- **IllegalOrderKey**: Invalid ORDER BY expression
- **GroupByIllegal**: Invalid GROUP BY usage

Errors include detailed diagnostics with:
- Status class and subclass
- Human-readable message
- Source location anchors
- Additional context for debugging