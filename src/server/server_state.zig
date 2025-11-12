const std = @import("std");

// CANARY: REQ=REQ-SERVER-REFACTOR-001; FEATURE="ServerRefactoring"; ASPECT=SERVER_STATE; STATUS=PARTIAL; OWNER=refactor; UPDATED=2025-11-12
// Phase 3 M3.1 - Server State Management Module (Incremental Extraction)
// Extracting support types first, ServerState struct extraction requires resolving dependency issues

/// Value inserted during a transaction with MVCC tracking
pub const ServerStateInsertedValue = struct {
    value: []const u8,
    creator_txn: u64,
    commit_ts: ?u64 = null,
    aborted: bool = false,
};

/// Catalog schema definition for managing database schemas
pub const CatalogSchema = struct {
    name: []const u8,
    created_at: i64,
    created_by: []const u8 = "system",
    description: ?[]const u8 = null,
};

/// Catalog graph definition for managing database graphs
pub const CatalogGraph = struct {
    name: []const u8,
    schema_name: ?[]const u8 = null,
    property_graph: bool = true,
    created_at: i64,
    created_by: []const u8 = "system",
    description: ?[]const u8 = null,
    node_count: u64 = 0,
    edge_count: u64 = 0,
};

// NOTE: ServerState struct extraction deferred due to complex dependency issues discovered:
// 1. ServerState references mvcc.MVCCManager but mvcc import is commented out in main.zig (line 20)
// 2. ServerState references query_plan_cache.QueryOptimizer but import is commented out (line 22)
// 3. ServerState uses late-bound imports like @import("cdc_enhanced") at field level
// 4. ServerState depends on SessionConfiguration which has extensive methods
//
// These issues require careful resolution before safe extraction.
// Following "incremental approach mandatory" - extracting simple types first.
