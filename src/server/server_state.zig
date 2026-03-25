const std = @import("std");

// CANARY: REQ=REQ-SERVER-REFACTOR-001; FEATURE="ServerRefactoring"; ASPECT=SERVER_STATE; STATUS=EXEMPT; OWNER=refactor; UPDATED=2026-01-09
// Phase 3 M3.1 - Server State Management Module (Complete)
// Extracted types: ServerState, SessionConfiguration, CatalogSchema, CatalogGraph, UnionMetrics

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

// CANARY: REQ=REQ-GRAPH-TYPE-REGISTRY-001; FEATURE="GraphTypeRegistry"; ASPECT=TypeDefinition; STATUS=EXEMPT; OWNER=catalog; UPDATED=2026-01-10
/// Graph type definition for CREATE GRAPH TYPE persistence
pub const GraphTypeDefinition = struct {
    name: []const u8,
    property_graph: bool = true,
    created_at: i64,
    created_by: []const u8 = "system",
    description: ?[]const u8 = null,
    /// Node type definitions (label -> property constraints)
    node_types: ?[]const NodeTypeSpec = null,
    /// Edge type definitions (label -> property constraints, source/target types)
    edge_types: ?[]const EdgeTypeSpec = null,
};

/// Node type specification for graph type definitions
pub const NodeTypeSpec = struct {
    label: []const u8,
    properties: ?[]const PropertySpec = null,
};

/// Edge type specification for graph type definitions
pub const EdgeTypeSpec = struct {
    label: []const u8,
    source_label: ?[]const u8 = null,
    target_label: ?[]const u8 = null,
    properties: ?[]const PropertySpec = null,
};

/// Property specification for node/edge types
pub const PropertySpec = struct {
    name: []const u8,
    type_name: []const u8 = "STRING",
    required: bool = false,
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

    // CANARY: REQ=REQ-MULTI-TENANT-002; FEATURE="Multi-Tenancy Session"; ASPECT=TenantId; STATUS=TESTED; TEST=geodetestlab/specs/gql_session_management_comprehensive.yml; OWNER=session; UPDATED=2026-01-09
    // Multi-tenancy settings
    tenant_id: ?[]const u8 = null, // Default tenant if not specified in handshake

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
        if (self.tenant_id) |tenant| {
            self.allocator.free(tenant);
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

// Additional imports needed for ServerState (use relative imports since this file is part of geode module)
const execution = @import("../execution.zig");
const mvcc = @import("txn/mvcc.zig");
const query_plan_cache = @import("query_plan_cache.zig");
// Note: query_ast_cache type reference is opaque to avoid circular dependency with lib.zig
// The actual type is query_ast_cache.SharedAstCache but we use *anyopaque here
const txn_mgr = @import("txn");
// CANARY: REQ=REQ-ABAC-WIRE-001; FEATURE="ABAC Enforcement"; ASPECT=ServerIntegration; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
// GAP-0165: Wire ABAC enforcement into server execution paths
const geode_auth = @import("geode_auth");

/// Main server state structure managing all server-side state
/// Extracted from main.zig in Phase 3 M3.2 to enable better modularization
pub const ServerState = struct {
    // Soft per-query memory limit: bytes threshold to trigger spills (0 = disabled)
    query_mem_limit_bytes: usize = 0,
    // Whether to return results inline in RUN_GQL response (vs separate PULL)
    inline_results_enabled: bool = false,
    // Maximum rows to return inline (0 = no limit)
    inline_results_max_rows: usize = 0,
    result_ordered: bool = false,
    result_order_keys: []const []const u8 = &.{},
    result_page_index: usize = 0,
    active_result: bool = false,
    // Optional value-backed result set for protobuf paging.
    active_result_values: ?execution.ExecutionResult = null,
    // Transaction session state: single active txn baseline
    in_txn: bool = false,
    txn_id: u64 = 0,
    allocator: std.mem.Allocator,
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
    // Execution session state (SESSION SET/RESET/CLOSE)
    exec_session: ?execution.SessionState = null,

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
    // Issue #460: Changed from per-connection QueryOptimizer to shared cross-connection optimizer
    query_optimizer: ?*query_plan_cache.SharedQueryOptimizer = null,
    // Query optimizer gating flag (profile/explain always enables it)
    query_optimizer_enabled: bool = false,
    // Parsed AST cache for hot-path query reuse (shared across connections)
    // Type is query_ast_cache.SharedAstCache but we use opaque pointer to avoid circular dependency
    query_ast_cache: ?*anyopaque = null,

    // Distributed query planner for federation-aware optimization
    // Types are DistributedQueryPlanner/FederationManager but we use opaque to avoid circular dep
    distributed_planner: ?*anyopaque = null,
    federation_manager: ?*anyopaque = null,

    // Catalog management for schemas and graphs
    catalog_schemas: std.HashMap([]const u8, CatalogSchema, std.hash_map.StringContext, std.hash_map.default_max_load_percentage) = undefined,
    catalog_graphs: std.HashMap([]const u8, CatalogGraph, std.hash_map.StringContext, std.hash_map.default_max_load_percentage) = undefined,

    // CANARY: REQ=REQ-GRAPH-TYPE-REGISTRY-001; FEATURE="GraphTypeRegistry"; ASPECT=TypeManagement; STATUS=EXEMPT; OWNER=catalog; UPDATED=2026-01-10
    // Graph type registry for CREATE/DROP GRAPH TYPE persistence
    graph_types: std.HashMap([]const u8, GraphTypeDefinition, std.hash_map.StringContext, std.hash_map.default_max_load_percentage) = undefined,

    // CANARY: REQ=REQ-ABAC-WIRE-002; FEATURE="ABAC Enforcement"; ASPECT=SecurityManager; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
    // GAP-0165: Security management for RBAC/ABAC - wired into server execution paths
    security_manager: ?*geode_auth.SecurityManager = null,
    current_user_id: ?geode_auth.UserId = null,

    // Authentication state for current session (set by HELLO message handler)
    authenticated_user: ?[]const u8 = null,
    authenticated_password: ?[]const u8 = null,
    // Type is user_management.Role but we use u8 enum value to avoid circular dep
    authenticated_role: ?u8 = null,
    // Whether the authenticated user must change their password before running queries
    password_reset_required: bool = false,

    // CANARY: REQ=REQ-MULTI-GRAPH-004; FEATURE="MultiGraphSupport"; ASPECT=SessionGraph; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-20
    // Current graph for this session (set by USE GRAPH command)
    current_graph: ?[]const u8 = null,

    // CANARY: REQ=REQ-DSN-GRAPH-BIND-001; FEATURE="DSNGraphBinding"; ASPECT=SessionGraphBound; STATUS=IMPL; OWNER=engine; UPDATED=2026-03-25
    // When true, this session was bound to a graph via DSN/HELLO and USE GRAPH is rejected
    graph_bound: bool = false,

    pub fn resetResult(self: *ServerState) void {
        if (self.active_result_values) |*res| {
            res.deinit(self.allocator);
            self.active_result_values = null;
        }
        for (self.result_order_keys) |key| {
            self.allocator.free(key);
        }
        self.result_order_keys = &.{};
        self.result_ordered = false;
        self.result_page_index = 0;
        self.active_result = false;
        if (self.query_text) |qt| self.allocator.free(qt);
        self.query_text = null;
    }
};

// CANARY: REQ=REQ-SERVER-REFACTOR-001B; FEATURE="ServerRefactoring"; ASPECT=SERVER_STATE_STRUCT; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-11-14
// Phase 3 M3.2 - ServerState struct extraction from main.zig
// Extracted complete ServerState struct with all dependencies resolved
