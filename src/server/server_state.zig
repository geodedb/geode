const std = @import("std");
const txn_undo_log = @import("../txn_undo_log.zig");
const gsa = @import("../storage/graph_storage_adapter.zig");

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
const node_scan_stream = @import("node_scan_stream.zig");
const query_plan_cache = @import("query_plan_cache.zig");
// Note: query_ast_cache type reference is opaque to avoid circular dependency with lib.zig
// The actual type is query_ast_cache.SharedAstCache but we use *anyopaque here
// CANARY: REQ=REQ-ABAC-WIRE-001; FEATURE="ABAC Enforcement"; ASPECT=ServerIntegration; STATUS=IMPL; OWNER=security; UPDATED=2026-11-12
// GAP-0165: Wire ABAC enforcement into server execution paths
const geode_auth = @import("geode_auth");

/// Main server state structure managing all server-side state
/// Extracted from main.zig in Phase 3 M3.2 to enable better modularization
pub const ServerState = struct {
    // Soft per-query memory limit: bytes threshold to trigger spills (0 = disabled)
    query_mem_limit_bytes: usize = 0,
    // Whether to return results inline in RUN_GQL response (vs separate PULL)
    inline_results_enabled: bool = false,
    // Maximum rows to return inline (0 disables the cap; default keeps
    // large row payloads streaming instead of blocking on one huge page)
    inline_results_max_rows: usize = node_scan_stream.default_inline_rows,
    result_ordered: bool = false,
    result_order_keys: []const []const u8 = &.{},
    result_page_index: usize = 0,
    active_result: bool = false,
    // Optional value-backed result set for protobuf paging.
    active_result_values: ?execution.ExecutionResult = null,
    active_node_scan_stream: ?node_scan_stream.NodeScanStream = null,
    // Pointer to the shared connection state for cross-stream PULL fallback.
    // Set during stream handler init; null for standalone (non-multiplexed) usage.
    shared_conn: ?*anyopaque = null,
    // SONNY-1835: true when this ServerState drives an ADDITIONAL (sibling) QUIC
    // stream rather than the connection's first/handshake stream. Set at sibling
    // handler init. Used to refuse a sibling that reaches execute with no graph
    // binding (neither inherited from the connection HELLO nor established by its
    // own per-stream HELLO) instead of silently querying the default graph and
    // returning zero rows.
    additional_stream: bool = false,
    // SONNY-1835: set true once this stream has processed its own HELLO. A
    // sibling that never HELLOs and never inherits a binding is refused at
    // execute time; first/handshake streams are never gated on this.
    own_hello_seen: bool = false,
    // Transaction session state: single active txn baseline
    in_txn: bool = false,
    txn_id: u64 = 0,
    // CANARY: REQ=REQ-SONNY-3348-ABORTED-TXN; FEATURE="TransactionManagement"; ASPECT=SessionState; STATUS=TESTED; TEST=tests/test_sonny3348_statement_undo.zig; OWNER=engine; UPDATED=2026-09-29
    // SONNY-3348 (round 18, I2): a statement failed inside the session's
    // explicit transaction, which was rolled back. Until the client ends it
    // (ROLLBACK, or a COMMIT that fails), every statement is refused (25P02,
    // `query_traits.abortedTxnVerdict`). The session left the transaction
    // silently and ran the client's next statements in autocommit.
    txn_aborted: bool = false,
    // SONNY-3348 (round 19, m3): the rollback of the session's transaction
    // could not undo every change (`UndoLog.rollback`'s
    // `error.RollbackIncomplete`). The client's ROLLBACK or COMMIT that ends
    // the transaction reports it (40003), then it is cleared.
    txn_rollback_incomplete: bool = false,
    // CANARY: REQ=REQ-SONNY-2776-TXN-ONE-GRAPH; FEATURE="StatementAuthorization"; ASPECT=TxnGraph; STATUS=TESTED; TEST=tests/test_sonny2776_session_graph_uses.zig; OWNER=security; UPDATED=2026-09-26
    // SONNY-2776: the graph the open transaction changes, owned by
    // `allocator`; null until its first change. A transaction changes one
    // graph: the handlers refuse a change of another (0A000), and COMMIT,
    // ROLLBACK, ROLLBACK TO SAVEPOINT and the teardown take this graph's
    // write lock. They used to take `current_graph`'s, which gRPC never
    // set (so always `default`'s) and QUIC set to the session's latest graph.
    txn_graph: ?[]const u8 = null,
    // CANARY: REQ=REQ-SONNY-2823-SESSION-ENGINE-TXN; FEATURE="TransactionManagement"; ASPECT=SessionState; STATUS=TESTED; TEST=tests/test_sonny2823_session_engine_txn.zig; OWNER=storage; UPDATED=2026-09-26
    // SONNY-2823: the session's engine transaction (R9), opened by the
    // executor on the transaction's first change in a program and committed
    // when that program returns (a ROLLBACK aborts it first). On a thread
    // only while a request of the session runs there (`enterSessionTxn`). It
    // lived in a thread-local until the Geode transaction's COMMIT, which on
    // gRPC and as a statement never ended it, and the next session on the
    // thread joined it. See `graph_storage_adapter.SessionEngineTxn`.
    session_engine_txn: gsa.SessionEngineTxn = .{},
    allocator: std.mem.Allocator,
    // Storage corruption state flags captured at startup (e.g. checksum mismatch on persisted page load).
    storage_checksum_error: bool = false,
    // Original GQL text of the current request.
    query_text: ?[]const u8 = null,
    // MVCC-aware heap of inserted values. commit_ts null => uncommitted.
    inserted_values: std.ArrayList(ServerStateInsertedValue) = undefined,
    global_commit_ts: u64 = 0, // monotonically increasing commit timestamp
    session_snapshot_ts: u64 = 0, // snapshot timestamp captured at BEGIN
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

    // Catalog management for schemas and graphs
    catalog_schemas: std.HashMap([]const u8, CatalogSchema, std.hash_map.StringContext, std.hash_map.default_max_load_percentage) = undefined,
    catalog_graphs: std.HashMap([]const u8, CatalogGraph, std.hash_map.StringContext, std.hash_map.default_max_load_percentage) = undefined,

    // CANARY: REQ=REQ-GRAPH-TYPE-REGISTRY-001; FEATURE="GraphTypeRegistry"; ASPECT=TypeManagement; STATUS=EXEMPT; OWNER=catalog; UPDATED=2026-01-10
    // Graph type registry for CREATE/DROP GRAPH TYPE persistence
    graph_types: std.HashMap([]const u8, GraphTypeDefinition, std.hash_map.StringContext, std.hash_map.default_max_load_percentage) = undefined,

    // CANARY: REQ=REQ-ABAC-WIRE-002; FEATURE="ABAC Enforcement"; ASPECT=SecurityManager; STATUS=IMPL; OWNER=security; UPDATED=2026-11-12
    // GAP-0165: Security management for RBAC/ABAC - wired into server execution paths
    security_manager: ?*geode_auth.SecurityManager = null,
    current_user_id: ?geode_auth.UserId = null,

    // Authentication state for current session (set by HELLO message handler)
    authenticated_user: ?[]const u8 = null,
    authenticated_password: ?[]const u8 = null,
    // Type is user_management.Role but we use u8 enum value to avoid circular dep
    authenticated_role: ?u8 = null,
    authenticated_auth_version: u64 = 0,
    authenticated_auth_validation_epoch: u64 = 0,
    // Whether the authenticated user must change their password before running queries
    password_reset_required: bool = false,
    // Per-session FLE role requested during HELLO. Owned by ServerState so
    // worker-thread handoff can re-install the role without borrowing from
    // the decoded protobuf packet.
    fle_user_role: ?[]const u8 = null,

    // CANARY: REQ=REQ-MULTI-GRAPH-004; FEATURE="MultiGraphSupport"; ASPECT=SessionGraph; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-20
    // Current graph for this session (set by USE GRAPH command)
    current_graph: ?[]const u8 = null,

    // CANARY: REQ=REQ-DSN-GRAPH-BIND-001; FEATURE="DSNGraphBinding"; ASPECT=SessionGraphBound; STATUS=IMPL; OWNER=engine; UPDATED=2026-03-25
    // When true, this session was bound to a graph via DSN/HELLO and USE GRAPH is rejected
    graph_bound: bool = false,

    /// SONNY-2776: note that the open transaction changes `graph`; its first
    /// change fixes the transaction's graph.
    ///
    /// SONNY-3134: the transaction graph is held (`holdGraphForTxn`) until
    /// `clearTxnGraph`: DROP GRAPH of it is refused (55006), from any
    /// session. The handlers call this while the request holds the graph's
    /// write lock.
    pub fn noteTxnWrite(self: *ServerState, graph: []const u8) std.mem.Allocator.Error!void {
        if (self.txn_graph != null) return;
        const graph_store_mod = @import("../graph_store.zig");
        const owned = try self.allocator.dupe(u8, graph);
        errdefer self.allocator.free(owned);
        try graph_store_mod.holdGraphForTxn(owned);
        self.txn_graph = owned;
    }

    /// SONNY-2776: would a change of `graph` make the open transaction change
    /// a second graph?
    pub fn txnWouldSpanGraphs(self: *const ServerState, graph: []const u8) bool {
        if (!self.in_txn) return false;
        const txn_graph = self.txn_graph orelse return false;
        return !std.mem.eql(u8, txn_graph, graph);
    }

    /// SONNY-2776: the graph whose write lock ends the transaction: the graph
    /// it changed, or `fallback` (the session's graph) when it changed none.
    pub fn txnLockGraph(self: *const ServerState, fallback: []const u8) []const u8 {
        return self.txn_graph orelse fallback;
    }

    pub fn clearTxnGraph(self: *ServerState) void {
        if (self.txn_graph) |g| {
            // SONNY-3134: the transaction no longer holds its graph.
            @import("../graph_store.zig").releaseGraphForTxn(g);
            self.allocator.free(g);
        }
        self.txn_graph = null;
    }

    /// SONNY-2776: the transaction is over: no transaction id, no graph.
    /// SONNY-3348 (round 19, m3): was the rollback of the transaction the
    /// client now ends incomplete? Cleared.
    pub fn takeRollbackIncomplete(self: *ServerState) bool {
        const incomplete = self.txn_rollback_incomplete;
        self.txn_rollback_incomplete = false;
        return incomplete;
    }

    pub fn endTransaction(self: *ServerState) void {
        self.in_txn = false;
        self.txn_id = 0;
        self.clearTxnGraph();
    }

    /// SONNY-2799, SONNY-2823: what `enterSessionTxn` changed on the thread.
    pub const SessionTxnScope = struct {
        engine: gsa.SessionEngineTxnScope,
        /// The thread's undo-log transaction before (0 for none; another
        /// session's when this one's teardown runs inside that session's
        /// request). `leaveSessionTxn` puts it back.
        prev_undo_txn: u64 = 0,
        /// SONNY-3191 (N-4): the hold release the thread had installed
        /// before (`graph_store.setThreadTxnHoldRelease`).
        prev_hold_release: ?@import("../graph_store.zig").TxnHoldRelease = null,
    };

    /// SONNY-3191 (N-4): the executor ended the transaction with a COMMIT or
    /// ROLLBACK statement (`graph_store.releaseThreadTxnHold`): its graph
    /// hold goes now, so the rest of the program can drop the graph.
    fn releaseTxnHoldThunk(ctx: *anyopaque) void {
        const self: *ServerState = @ptrCast(@alignCast(ctx));
        self.clearTxnGraph();
    }

    // CANARY: REQ=REQ-SONNY-2799-SESSION-UNDO-TXN; FEATURE="TransactionUndoLog"; ASPECT=PerSession; STATUS=TESTED; TEST=tests/test_sonny2805_txn_sessions.zig; OWNER=engine; UPDATED=2026-09-26
    // CANARY: REQ=REQ-SONNY-2823-SESSION-ENGINE-TXN; FEATURE="TransactionManagement"; ASPECT=PerRequestInstall; STATUS=TESTED; TEST=tests/test_sonny2823_session_engine_txn.zig; OWNER=storage; UPDATED=2026-09-26
    /// Make the session's transactions this thread's for one request:
    /// - SONNY-2799: its undo-log transaction (`txn_id`, 0 for none). The
    ///   undo log records each change under the calling thread's
    ///   transaction, and a session's requests run on any worker thread.
    /// - SONNY-2823: its engine transaction (`session_engine_txn`), which
    ///   the executor opens on the transaction's first change in a program
    ///   and commits when that program returns, under the request's lock.
    /// `leaveSessionTxn` takes them back, and gives the thread back what it
    /// held before. Entering again inside the session's own request (a
    /// rollback there) changes nothing.
    pub fn enterSessionTxn(self: *ServerState) SessionTxnScope {
        const engine = gsa.enterSessionEngineTxn(&self.session_engine_txn);
        if (engine.nested) return .{ .engine = engine };
        const prev_undo_txn = txn_undo_log.currentThreadTxnId();
        txn_undo_log.setThreadTxnId(self.txn_id);
        // SONNY-3191 (N-4): a COMMIT or ROLLBACK statement lets the hold go.
        const prev_hold_release = @import("../graph_store.zig").setThreadTxnHoldRelease(.{ .ctx = self, .release = releaseTxnHoldThunk });
        return .{ .engine = engine, .prev_undo_txn = prev_undo_txn, .prev_hold_release = prev_hold_release };
    }

    /// After a request, the session's transaction is whatever the undo log's
    /// transaction on this thread is now (a START TRANSACTION, COMMIT or
    /// ROLLBACK in the request moves it); the thread is left with neither of
    /// the session's transactions, for the next session it serves.
    pub fn leaveSessionTxn(self: *ServerState, scope: SessionTxnScope) void {
        self.txn_id = txn_undo_log.currentThreadTxnId();
        if (!scope.engine.nested) {
            txn_undo_log.setThreadTxnId(scope.prev_undo_txn);
            _ = @import("../graph_store.zig").setThreadTxnHoldRelease(scope.prev_hold_release);
            // The handler's transaction and the undo log's agree after every
            // request. A transaction the undo log no longer has is over. One
            // the handler never took up (a request that failed after its
            // START TRANSACTION ran) is not the session's: its changes stand,
            // as autocommit changes, and its entries go.
            if (self.in_txn and self.txn_id == 0) {
                self.endTransaction();
            } else if (!self.in_txn and self.txn_id != 0) {
                txn_undo_log.getGlobalUndoLog(self.allocator).discardTxn(self.txn_id);
                self.txn_id = 0;
            }
        }
        // SONNY-2823: and no engine transaction outlives the request.
        // SONNY-3027: one still open here outlived the request's write lock:
        // it is aborted, and the transaction it belongs to failed. It is
        // rolled back (under its graph's write lock), so its COMMIT reports
        // the failure rather than keeping changes that were never committed.
        if (gsa.leaveSessionEngineTxn(&self.session_engine_txn, scope.engine) and self.in_txn) {
            self.rollBackTransaction(self.sessionGraph());
            // SONNY-3348 (round 19, m2): and the session is in the aborted
            // transaction until the client ends it; it fell back to
            // autocommit, silently.
            self.txn_aborted = true;
        }
    }

    /// SONNY-2823: commit the session's engine transaction, where its undo
    /// transaction commits (the COMMIT RPC). The program that opened it
    /// committed it already; this is the backstop. Called inside the
    /// session's request. SONNY-3031: before the undo transaction commits,
    /// and a failure, or one an earlier request's program left unreported,
    /// fails the COMMIT (`settleThreadSessionTxn`).
    pub fn commitEngineTxn(self: *ServerState) error{SessionCommitFailed}!void {
        _ = self;
        try gsa.settleThreadSessionTxn();
    }

    // CANARY: REQ=REQ-SONNY-2823-SESSION-ENGINE-TXN; FEATURE="TransactionManagement"; ASPECT=RollBack; STATUS=TESTED; TEST=tests/test_sonny2823_session_engine_txn.zig; OWNER=storage; UPDATED=2026-09-26
    /// SONNY-2799: undo the session's transaction (`txn_id`) and end it,
    /// under the write lock of the graph it changed (`fallback_graph` when it
    /// changed none). The caller holds no graph lock.
    ///
    /// SONNY-2823: the session's engine transaction is aborted first, from
    /// any thread and outside a request too (a session's teardown). It was
    /// the thread's, so gRPC could not abort it at all. With no store left
    /// (a teardown after the store's), the transaction is forgotten.
    pub fn rollBackTransaction(self: *ServerState, fallback_graph: []const u8) void {
        const graph_store_mod = @import("../graph_store.zig");
        if (self.txn_id != 0 or self.session_engine_txn.open) {
            if (graph_store_mod.getCurrentGlobalStore() != null) {
                const lock = graph_store_mod.acquireGraphWriteLock(self.txnLockGraph(fallback_graph));
                defer graph_store_mod.releaseGraphLock(lock);
                const scope = self.enterSessionTxn();
                defer self.leaveSessionTxn(scope);
                txn_undo_log.getGlobalUndoLog(self.allocator).rollback(graph_store_mod.getWritableGlobalStore(self.allocator)) catch |err| {
                    // SONNY-3348 (round 19, m3): reported to the client at
                    // its ROLLBACK or COMMIT (`txn_rollback_incomplete`).
                    @import("logging").scoped("server_state").err("transaction rollback could not undo every change", &.{@import("logging").Attr.string("error", @errorName(err))});
                    self.txn_rollback_incomplete = true;
                };
                // SONNY-6529: the session's engine transaction (open when a
                // teardown ends the session mid-request) is ended AFTER the
                // undo, under the lock: the undo's changes joined it and
                // commit with the writes they undo. SONNY-2823 aborted it
                // first; graph-storage 0.4.16's abort undoes the writes,
                // which the store's in-memory copy keeps, and the undo then
                // undid them a second time.
                gsa.endThreadSessionTxn();
            } else {
                txn_undo_log.getGlobalUndoLog(self.allocator).discardTxn(self.txn_id);
                self.session_engine_txn.open = false;
            }
        }
        self.endTransaction();
    }

    /// SONNY-2776: the session's graph: the executor session's, or
    /// `current_graph` (the copy QUIC syncs; gRPC never sets it).
    // CANARY: REQ=REQ-SONNY-6334-FLE-REQUEST-CONTEXT; FEATURE="FieldLevelEncryption"; ASPECT=OneRequestContextForQuicAndGrpc; STATUS=TESTED; TEST=tests/test_sonny6334_fle_authorization.zig; OWNER=security; UPDATED=2026-11-11
    /// SONNY-6334: the session's request context on this thread, for the
    /// FLE reads made outside the executor's active context (the result
    /// encoding) and for audit events: the tenant (GAP-0281/0282), the FLE
    /// role its HELLO named, and the GPS decrypt_field gate for its
    /// authenticated principal, asked live (policy changes and USE GRAPH
    /// count). QUIC and gRPC both install it at the start of every request
    /// that runs or encodes a statement, and `clearRequestThreadState` on
    /// every exit, so a pooled thread never carries one request's role into
    /// the next. `self` must outlive the request (both keep the session's
    /// state for its lifetime).
    pub fn installRequestThreadState(self: *const ServerState) void {
        const fle_integration = @import("../fle_integration.zig");
        const audit_mod = @import("../security/audit.zig");
        const tenant = if (self.session_config) |cfg| cfg.tenant_id else null;
        fle_integration.setCurrentTenantId(tenant);
        audit_mod.setCurrentAuditTenantId(tenant);
        fle_integration.setCurrentUserRole(self.effectiveFleRole());
        fle_integration.setCurrentPlaintextGate(.{ .ctx = self, .allows = sessionAllowsDecrypt });
    }

    // CANARY: REQ=REQ-SONNY-6341-FLE-ROLE-BINDING; FEATURE="FieldLevelEncryption"; ASPECT=FleRoleBoundToPrincipal; STATUS=TESTED; TEST=tests/test_sonny6341_fle_role_binding.zig; OWNER=security; UPDATED=2026-11-12
    /// SONNY-6341: the FLE role this session's requests act under: the one
    /// its HELLO named, when the authenticated user holds it (an Admin's
    /// `CALL geode.fle.grantRole`, `security/fle_role_grants.zig`); else
    /// none, and encrypted fields read as for a role not in their list.
    /// Asked for every request, so a grant or revoke counts from the next
    /// one. With authentication off every session is an implicit admin and
    /// keeps the role it named; `--insecure-allow-all` bypasses this as it
    /// bypasses all authorization. The Admin builtin role holds no FLE role
    /// implicitly: an Admin grants one to itself, audited, like to anyone.
    pub fn effectiveFleRole(self: *const ServerState) ?[]const u8 {
        const role = self.fle_user_role orelse return null;
        const user_mgmt = @import("../security/user_management.zig");
        const gps = @import("../security/gps.zig");
        const fle_role_grants = @import("../security/fle_role_grants.zig");
        if (!user_mgmt.isAuthEnabled() or gps.isInsecureAllowAll()) return role;
        const user = self.authenticated_user orelse return null;
        if (fle_role_grants.holds(user, role)) return role;
        return null;
    }

    /// SONNY-6341: at HELLO, a named FLE role the user does not hold is an
    /// `access_denied` audit event (user, requested role); the session goes
    /// on with no FLE role, so a client that always sends one still
    /// connects. Called once per HELLO by both transports.
    pub fn auditUnheldFleRole(self: *const ServerState) void {
        const requested = self.fle_user_role orelse return;
        if (self.effectiveFleRole() != null) return;
        const audit_mod = @import("../security/audit.zig");
        var buf: [192]u8 = undefined;
        const details = std.fmt.bufPrint(&buf, "fle role not held: {s}", .{requested}) catch "fle role not held";
        audit_mod.logSecurityGraphEvent(self.allocator, .{
            .event_type = .access_denied,
            .action = "fle_role",
            .username = self.authenticated_user orelse "",
            .details = details,
            .result_failure = true,
        });
        @import("logging").scoped("server_state").warn("HELLO named an FLE role the user does not hold; the session has no FLE role", &.{@import("logging").Attr.string("user", self.authenticated_user orelse "")});
    }

    /// SONNY-6334: undoes `installRequestThreadState`.
    pub fn clearRequestThreadState() void {
        const fle_integration = @import("../fle_integration.zig");
        const audit_mod = @import("../security/audit.zig");
        fle_integration.clearCurrentThreadState();
        audit_mod.setCurrentAuditTenantId(null);
    }

    /// GPS decrypt_field for the session's authenticated principal on its
    /// graph. With authentication off every session is an implicit admin;
    /// with it on, an unauthenticated session is refused.
    fn sessionAllowsDecrypt(ctx: ?*const anyopaque) bool {
        const fle_integration = @import("../fle_integration.zig");
        const user_mgmt = @import("../security/user_management.zig");
        const principal_derive = @import("../security/principal_derive.zig");
        const self: *const ServerState = @ptrCast(@alignCast(ctx orelse return false));
        if (!user_mgmt.isAuthEnabled()) return true;
        const username = self.authenticated_user orelse return false;
        const role_raw = self.authenticated_role orelse return false;
        const role_names = [_][]const u8{@tagName(@as(user_mgmt.Role, @enumFromInt(role_raw)))};
        const graph = self.sessionGraph();
        const principal = principal_derive.derivePrincipal(.{
            .username = username,
            .role_names = &role_names,
            .tenant_id = if (self.session_config) |cfg| cfg.tenant_id else null,
            .active_graph = graph,
            .auth_version = self.authenticated_auth_version,
            .auth_method = .password,
            .source = .internal_service,
        });
        return fle_integration.decryptAllowedFor(&principal, graph);
    }

    pub fn sessionGraph(self: *const ServerState) []const u8 {
        const graph_store_mod = @import("../graph_store.zig");
        if (self.exec_session) |*sess| return sess.graph orelse graph_store_mod.DEFAULT_GRAPH_NAME;
        return self.current_graph orelse graph_store_mod.DEFAULT_GRAPH_NAME;
    }

    pub fn resetResult(self: *ServerState) void {
        if (self.active_result_values) |*res| {
            res.deinit(self.allocator);
            self.active_result_values = null;
        }
        if (self.active_node_scan_stream) |*stream| {
            stream.deinit();
            self.active_node_scan_stream = null;
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

    // R3 (2026-04-22): teardown hook for the QUIC stream-close path.
    //
    // A QUIC stream may close with an in-flight transaction (client
    // disconnects mid-chunk during the 16-worker ingest workload, or a
    // spurious FIN from the QUIC library).  Without this hook,
    // `state.in_txn` stays true and the process-global undo log keeps
    // the orphaned entries — a subsequent BEGIN on a reused session sees
    // "transaction already in progress" and a later `begin()` from any
    // session would wipe them (aliased with R1).
    //
    // Contract:
    //   - If `in_txn`, roll back the undo log against the caller's
    //     `store` honouring the mutex tier order (per-graph write lock
    //     first, per CLAUDE.md's lock ordering table).  When the store
    //     is null (no adapter wired up, e.g. in unit tests), skip the
    //     store-side rollback but still clear the undo log entries that
    //     belong to this session's thread so they don't leak.
    //   - Clear `in_txn` / `txn_id`.
    //   - Log an audit warning (`orphan-txn rolled back on stream close`).
    //   - Safe to call when no transaction is in flight — returns
    //     cleanly without side effects.
    //
    // The hook is driven from every QUIC stream-close path: the handler
    // cleanup in `handleAdditionalStream`, the per-stream cleanup in
    // `handleQuicConnection`, and `invalidateAuthenticatedSession` in
    // `quic_connection_handler.zig`.
    pub fn tearDownForStreamClose(
        self: *ServerState,
        store: ?*@import("../graph_store.zig").GraphStore,
    ) !void {
        if (!self.in_txn and !self.session_engine_txn.open) return;

        const orphan_txn_id = self.txn_id;
        // SONNY-2776: the graph the transaction changed.
        std.log.warn("orphan-txn rolled back on stream close (txn_id={d}, graph={s})", .{
            orphan_txn_id,
            self.txnLockGraph(self.sessionGraph()),
        });

        if (store == null) {
            // No store — just purge the undo entries that belong to the
            // orphaned transaction so they don't leak or get picked up
            // by a peer transaction's rollback.
            // SONNY-2799: this transaction's entries only (`txn_id` is its
            // undo-log id); `clear()` wiped every session's.
            txn_undo_log.getGlobalUndoLog(self.allocator).discardTxn(orphan_txn_id);
            self.session_engine_txn.open = false;
            self.endTransaction();
            return;
        }
        // SONNY-2823: through `rollBackTransaction`, which also aborts the
        // session's engine transaction (the teardown left it open on the
        // stream's pooled thread) and takes the transaction graph's write
        // lock (lock tier 1 before the undo log).
        self.rollBackTransaction(self.sessionGraph());
    }
};

// CANARY: REQ=REQ-SERVER-REFACTOR-001B; FEATURE="ServerRefactoring"; ASPECT=SERVER_STATE_STRUCT; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-11-14
// Phase 3 M3.2 - ServerState struct extraction from main.zig
// Extracted complete ServerState struct with all dependencies resolved
