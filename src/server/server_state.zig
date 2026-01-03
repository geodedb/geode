const std = @import("std");

// CANARY: REQ=REQ-SERVER-REFACTOR-001; FEATURE="ServerRefactoring"; ASPECT=SERVER_STATE; STATUS=PARTIAL; OWNER=refactor; UPDATED=2025-11-12
// Phase 3 M3.1 - Server State Management Module (Incremental Extraction)
// Extracting support types and session management types

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

/// Session parameter value types for session configuration
pub const SessionParameterValue = union(enum) {
    String: []const u8,
    Graph: []const u8,
    BindingTable: []const u8,
    Value: []const u8,
    Integer: i64,
    Float: f64,
    Boolean: bool,
};

/// Session reset type specifying what to reset in session configuration
pub const SessionResetType = union(enum) {
    AllParameters,
    AllCharacteristics,
    Schema,
    Graph,
    TimeZone,
    Parameter: []const u8,
};

/// Session configuration managing schema, graph, timezone and parameters
pub const SessionConfiguration = struct {
    // Schema settings
    current_schema: ?[]const u8 = null,

    // Graph settings
    current_graph: ?[]const u8 = null,
    property_graph_default: bool = true,

    // Time zone settings
    time_zone: ?[]const u8 = null,

    // Session parameters (key-value pairs)
    parameters: std.StringHashMap(SessionParameterValue),

    // Allocator for parameter storage
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SessionConfiguration {
        return .{
            .parameters = std.StringHashMap(SessionParameterValue).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionConfiguration) void {
        // Free all parameter keys and values
        var iterator = self.parameters.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .String => |s| self.allocator.free(s),
                .Graph => |g| self.allocator.free(g),
                .BindingTable => |bt| self.allocator.free(bt),
                else => {},
            }
        }
        self.parameters.deinit();

        // Free schema and graph names if allocated
        if (self.current_schema) |schema| {
            self.allocator.free(schema);
        }
        if (self.current_graph) |graph| {
            self.allocator.free(graph);
        }
        if (self.time_zone) |tz| {
            self.allocator.free(tz);
        }
    }

    pub fn setParameter(self: *SessionConfiguration, name: []const u8, value: SessionParameterValue) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        try self.parameters.put(owned_name, value);
    }

    pub fn getParameter(self: *SessionConfiguration, name: []const u8) ?SessionParameterValue {
        return self.parameters.get(name);
    }

    pub fn removeParameter(self: *SessionConfiguration, name: []const u8) void {
        if (self.parameters.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            switch (kv.value) {
                .String => |s| self.allocator.free(s),
                .Graph => |g| self.allocator.free(g),
                .BindingTable => |bt| self.allocator.free(bt),
                else => {},
            }
        }
    }

    pub fn reset(self: *SessionConfiguration, reset_type: SessionResetType) void {
        switch (reset_type) {
            .AllParameters => {
                // Clear all parameters
                var iterator = self.parameters.iterator();
                while (iterator.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    switch (entry.value_ptr.*) {
                        .String => |s| self.allocator.free(s),
                        .Graph => |g| self.allocator.free(g),
                        .BindingTable => |bt| self.allocator.free(bt),
                        else => {},
                    }
                }
                self.parameters.clearAndFree();
            },
            .AllCharacteristics => {
                // Reset all session characteristics (schema, graph, time zone, etc.)
                if (self.current_schema) |schema| {
                    self.allocator.free(schema);
                    self.current_schema = null;
                }
                if (self.current_graph) |graph| {
                    self.allocator.free(graph);
                    self.current_graph = null;
                }
                if (self.time_zone) |tz| {
                    self.allocator.free(tz);
                    self.time_zone = null;
                }
                self.property_graph_default = true;
            },
            .Schema => {
                if (self.current_schema) |schema| {
                    self.allocator.free(schema);
                    self.current_schema = null;
                }
            },
            .Graph => {
                if (self.current_graph) |graph| {
                    self.allocator.free(graph);
                    self.current_graph = null;
                }
                self.property_graph_default = true;
            },
            .TimeZone => {
                if (self.time_zone) |tz| {
                    self.allocator.free(tz);
                    self.time_zone = null;
                }
            },
            .Parameter => |param_name| {
                self.removeParameter(param_name);
            },
        }
    }
};

/// Union operation metrics tracking input/output rows and hash table size
pub const UnionMetrics = struct {
    left_in: usize,
    right_in: usize,
    out: usize,
    hash_size: ?usize,
};

// Additional imports needed for ServerState (use geode module instead of relative imports)
const geode = @import("geode");
const protocol = geode.protocol;
const mvcc = @import("txn/mvcc.zig");
const query_plan_cache = @import("query_plan_cache.zig");
const txn_mgr = @import("txn");

/// Main server state structure managing all server-side state
/// Extracted from main.zig in Phase 3 M3.2 to enable better modularization
pub const ServerState = struct {
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
    cdc_engine: ?*@import("../streaming/cdc_enhanced.zig").CDCEngine = null,

    // Session management state
    session_config: ?SessionConfiguration = null,

    // Index manager for managing database indexes
    index_manager_ptr: ?*anyopaque = null,

    // Index optimizer for query planning
    index_optimizer_ptr: ?*anyopaque = null,

    // Index statistics manager for cost estimation
    index_stats_manager: ?*anyopaque = null,

    // Backup manager for backup/restore operations
    backup_manager: ?*anyopaque = null,

    // Graph state for tracking nodes and edges
    graph_state: ?*struct {
        node_count: u64,
        edge_count: u64,
    } = null,

    // Distributed query planner for federation-aware optimization
    distributed_query_planner: ?*anyopaque = null,

    // Query plan cache and optimizer for performance optimization
    query_optimizer: ?*query_plan_cache.QueryOptimizer = null,

    // Distributed query planner for federation-aware optimization
    distributed_planner: ?*geode.distributed.query_planner.DistributedQueryPlanner = null,
    federation_manager: ?*geode.distributed.query_planner.FederationManager = null,

    // Catalog management for schemas and graphs
    catalog_schemas: std.HashMap([]const u8, CatalogSchema, std.hash_map.StringContext, std.hash_map.default_max_load_percentage) = undefined,
    catalog_graphs: std.HashMap([]const u8, CatalogGraph, std.hash_map.StringContext, std.hash_map.default_max_load_percentage) = undefined,

    // Security management for RBAC/ABAC - comment out for now to avoid import issues
    // security_manager: ?*SecurityManager = null,
    // current_user_id: ?UserId = null,

    // Authentication state for current session (set by HELLO message handler)
    authenticated_user: ?[]const u8 = null,
    authenticated_role: ?geode.user_management.Role = null,

    // CANARY: REQ=REQ-MULTI-GRAPH-004; FEATURE="MultiGraphSupport"; ASPECT=SessionGraph; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-20
    // Current graph for this session (set by USE GRAPH command)
    current_graph: ?[]const u8 = null,

    pub fn resetResult(self: *ServerState) void {
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

// CANARY: REQ=REQ-SERVER-REFACTOR-001B; FEATURE="ServerRefactoring"; ASPECT=SERVER_STATE_STRUCT; STATUS=IMPL; OWNER=refactor; UPDATED=2025-11-14
// Phase 3 M3.2 - ServerState struct extraction from main.zig
// Extracted complete ServerState struct with all dependencies resolved
