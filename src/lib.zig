const std = @import("std");
const Lexer = @import("gql/lexer.zig").Lexer;
const Parser = @import("gql/parser.zig").Parser;
pub const ast = @import("gql/ast.zig");

/// GAP-0115 DOCUMENTATION: Memory Allocation Error Handling
// CANARY: REQ=REQ-MEMORY-SAFETY-001; FEATURE="MemorySafetyDocumentation"; ASPECT=Core; STATUS=TESTED; OWNER=core; UPDATED=2026-01-12
///
/// ## Memory Allocation Patterns
///
/// Geode uses Zig's arena allocators for query parsing and execution. The codebase contains
/// approximately 580+ instances of `catch unreachable` for allocation operations. This is
/// intentional for the following reasons:
///
/// ### Design Rationale
/// 1. **Arena Allocator Semantics**: Most allocations use arena allocators where individual
///    allocation failures are uncommon - the arena either has memory or the entire system
///    is under severe memory pressure.
///
/// 2. **Performance**: Error handling on every small allocation adds overhead that impacts
///    query parsing and execution performance.
///
/// 3. **Practical Considerations**: In practice, OOM during query parsing indicates a system-level
///    problem that cannot be gracefully recovered by the query processor.
///
/// ### Production Recommendations
/// For production deployments:
/// 1. Configure adequate system memory for expected query complexity
/// 2. Use resource limits (memory cgroups) to fail fast on resource exhaustion
/// 3. Monitor memory usage to detect issues before OOM occurs
///
/// ### Future Work
/// The codebase may be enhanced to use error-returning allocation patterns in critical paths.
/// See the CANARY markers with `REQ-MEMORY-*` for tracking this work.
///

// GQL module namespace
pub const gql = struct {
    pub const ast = @import("gql/ast.zig");
    pub const token = @import("gql_lib").token;
    pub const status = @import("gql_lib").status;
    pub const parser = @import("gql/parser.zig");
    pub const lexer = @import("gql/lexer.zig");
};

// CANARY: REQ=REQ-METADATA-LIB-001; FEATURE="MetadataIntegration"; ASPECT=LibExport; STATUS=EXEMPT; OWNER=lib; UPDATED=2026-01-03
// Export language metadata for LSP and other consumers
pub const language_metadata = @import("gql/language_metadata.zig");

// CANARY: REQ=REQ-M5.2-LIB-EXPORT-001; FEATURE="Circular Dependency Resolution"; ASPECT=ValueTypesExport; STATUS=EXEMPT; OWNER=lib; UPDATED=2025-11-13
// Phase 5 M5.2: Export value_types module for external access
pub const value_types = @import("value_types.zig");

pub const ParseResult = struct {
    program: ast.Program,
    arena: std.heap.ArenaAllocator,
    last_error: ?[]const u8 = null,
    has_double_solidus_comment: bool = false,
    has_double_dash_comment: bool = false,
    has_unwind: bool = false,

    pub fn deinit(self: *ParseResult) void {
        self.arena.deinit();
    }
};

pub const ParseOptions = struct {
    strict_order_keys: bool = false,
    ident_order_only: bool = false,
    forbid_orderby_calls: bool = false,
    forbid_orderby_paths: bool = false,
    ts_extensions: bool = false,
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8, options: ParseOptions) !ParseResult {
    _ = options;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var lexer = Lexer{ .src = source };
    var parser = Parser{ .lx = &lexer, .arena = &arena, .cur = lexer.next() };

    const program = try parser.parseProgram();

    return ParseResult{
        .program = program,
        .arena = arena,
        .has_double_solidus_comment = lexer.has_double_solidus_comment,
        .has_double_dash_comment = lexer.has_double_dash_comment,
        .has_unwind = parser.has_unwind,
    };
}

// Context-aware GQL recommendation engine for LSP/MCP diagnostics
pub const recommendations = @import("gql/recommendations.zig");

// Re-export printer module so binaries can import through the geode module
pub const printer = @import("gql/print.zig");
// Re-export conformance profile helpers for CLI/tools
pub const conformance = @import("conformance.zig");
// Re-export selected runtime helpers so binaries can import via the geode package
pub const exec = @import("exec.zig");
pub const planner = @import("planner.zig");
pub const gpu_planner_ops = @import("planner/gpu_ops.zig");
// Expose cost model seed & variance auto-calibration modules for tests (avoid relative imports)
pub const cost_seed = @import("planner/cost_seed.zig");
pub const cost_model_calibration = @import("planner/calibration.zig");
// Re-export cost explain JSON builders (distinct from calibration reporting)
pub const cost_explain = @import("planner/cost_explain.zig");
// Expose pagination auto-calibration helpers
pub const pagination_calibration = @import("pagination/calibration.zig");
// Expose structural key utilities for benchmarks (PathCache related)
pub const planner_structural_key = @import("planner/structural_key.zig");
// Expose planner pipeline orchestration (synthetic phases + selection integration)
pub const planner_pipeline = @import("planner/pipeline.zig");
pub const temporal = @import("temporal.zig");
// Query analysis helpers (EXPLAIN/PROFILE traits)
pub const query_traits = @import("query/query_traits.zig");
pub const planned_read_runtime = @import("execution/planned_read_runtime.zig");
// Re-export evaluator for expression tests and demos
pub const eval = @import("eval.zig");
pub const diagnostics = @import("diagnostics.zig");
// Re-export type promotion utilities for advanced types roundtrip tests
pub const type_promotion = @import("eval/type_promotion.zig");
// Re-export unicode utilities (normalization, case folding, UTF-16/WTF-8 helpers)
pub const unicode = @import("unicode/geode_unicode.zig");
pub const unicode_tables = @import("unicode/unicode_tables.zig");
pub const confusables = @import("unicode/confusables.zig");
// Re-export extended evaluation registry and extended types for CANARY tests
pub const eval_ext = @import("eval_extended.zig");
pub const ext_types = @import("types/extended.zig");

// Re-export type system modules
pub const types = struct {
    pub const evaluator_functions = @import("types/evaluator_functions.zig");
    pub const network = @import("types/network.zig");
    pub const decimal128 = @import("types/decimal128.zig");
    pub const datetime = @import("types/datetime.zig");
    pub const jsonb = @import("types/jsonb.zig");
    pub const xml = @import("types/xml.zig");
    pub const url = @import("types/url.zig");
    pub const uuid = @import("uuid");
    pub const arrays = @import("types/arrays.zig");
    pub const bitstring = @import("types/bitstring.zig");
    pub const range = @import("types/range.zig");
    pub const extended = @import("types/extended.zig");
    pub const extended_functions = @import("types/extended_functions.zig");
    pub const numeric_promotion = @import("types/numeric_promotion.zig");
    pub const int256 = @import("types/i256.zig");
    pub const hash = @import("types/hash.zig");
    pub const vector = @import("types/vector.zig");
    pub const geographic = @import("types/geographic.zig");
    pub const cryptographic = @import("types/cryptographic.zig");
};

// Re-export server graph common types
pub const graph_common = @import("types/graph_common.zig");
// Re-export materialized views
pub const materialized_views = @import("query/materialized_views.zig");

// Test harness is not exported from production modules; tests import it directly.

// CANARY: REQ=REQ-TXN-UNDO-003; FEATURE="TransactionUndoLog"; ASPECT=LibExport; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
// Re-export transaction undo log for CLI rollback support
pub const txn_undo_log = @import("txn_undo_log.zig");

// Machine Learning and Analytics
pub const ml = struct {
    pub const graph_embeddings = @import("ml/graph_embeddings.zig");
};

// Real-time Analytics and Streaming
pub const analytics = struct {
    pub const real_time = @import("analytics/real_time.zig");
};
// Re-export server graph executor for tests needing internal MATCH primitives
pub const graph_exec = @import("server/graph/exec.zig");
// Re-export server state for unified binary
pub const server_state = @import("server/server_state.zig");
// Re-export server txn/mvcc for unified binary
pub const server_mvcc = @import("server/txn/mvcc.zig");
// Note: query_ast_cache is imported directly by server files to avoid circular dependency
// (it needs ParseOptions/ParseResult which are defined in this file)
// Re-export query_plan_cache for unified binary
pub const query_plan_cache = @import("server/query_plan_cache.zig");
// Re-export server_flags for unified binary
pub const server_flags = @import("server/server_flags.zig");
// Re-export backup_manager for unified binary
pub const backup_manager = @import("server/backup_manager.zig");
// Re-export impl_flagger for unified binary
pub const impl_flagger = @import("server/flagger_impl_defined.zig");
// Re-export proto_util for unified binary
pub const proto_util = @import("server/proto_util.zig");
// Re-export explain/profile payload builders for server handlers and tests
pub const explain_payload = @import("server/explain_payload.zig");
pub const profile_payload = @import("server/profile_payload.zig");
// Re-export heap for test_integration and other modules
pub const heap = @import("storage/heap.zig");
// Re-export catalog for tests
pub const catalog = @import("schema/catalog.zig");
// Re-export tde_file_encryption for tests
pub const tde_file_encryption = @import("storage/tde_file_encryption.zig");

// Benchmark modules (variance envelopes)
pub const benchmarks = struct {
    // Pagination ordered variance benchmark (exposed for variance runner)
    pub const pagination = @import("benchmarks/pagination_variance.zig");
    // Pagination execution (streaming page) variance benchmark
    pub const pagination_execution = @import("benchmarks/pagination_execution_variance.zig");
    // Shared variance configuration helper
    pub const variance_config = @import("benchmarks/variance_config.zig");
};
// Time-series module
pub const timeseries = @import("timeseries_lib");

// Re-export index modules for specialized data types
pub const index = struct {
    pub const patricia = @import("index/patricia.zig");
    pub const rtree = @import("rtree_lib");
    pub const hnsw = @import("hnsw_lib");
    pub const interval_tree = @import("index/interval_tree.zig");
    pub const interval_persist = @import("index/interval_persist.zig");
    pub const jsonb_inverted = @import("index/jsonb_inverted.zig");
    pub const jsonb_inverted_persist = @import("index/jsonb_inverted_persist.zig");
    pub const domain_trie = @import("index/domain_trie.zig");
    pub const domain_trie_persist = @import("index/domain_trie_persist.zig");
    pub const fulltext = @import("index/fulltext.zig");
    pub const IndexManager = @import("index/index_manager.zig").IndexManager;
    pub const vector_index = @import("index/vector_index.zig");
    pub const spatial_index = @import("index/spatial_index.zig");
    pub const advanced_types_index = @import("index/advanced_types_index.zig");
};

// Re-export wire-neutral protocol value types for distributed coordination.
pub const protocol = @import("protocol.zig");

// Distributed systems modules
pub const distributed = struct {
    pub const raft_consensus = @import("distributed/raft_consensus.zig");
    pub const txn_coordinator = @import("distributed/txn_coordinator.zig");
    pub const cluster = @import("distributed/cluster.zig");
    pub const raft = @import("raft");
    pub const query_planner = @import("distributed/query_planner.zig");
};

// REPL modules
pub const repl = struct {
    pub const repl_loop = @import("client/repl/repl_loop.zig");
    pub const repl_parse = @import("client/repl/repl_parse.zig");
    pub const repl_history = @import("client/repl/repl_history.zig");
    pub const repl_errors = @import("client/repl/repl_errors.zig");
    pub const repl_render = @import("client/repl/repl_render.zig");
    pub const repl_dispatch = @import("client/repl/repl_dispatch.zig");
    pub const quic_transport = @import("client/repl/quic_transport.zig");
    pub const keymap_emacs = @import("client/repl/keymap_emacs.zig");
    pub const keymap_vi = @import("client/repl/keymap_vi.zig");
    pub const repl_complete = @import("client/repl/repl_complete.zig");
    pub const repl_config = @import("client/repl/repl_config.zig");
    /// CANARY: REQ=REQ-SHELL-SPINNER-002; FEATURE="ShellProcessingIndicator"; ASPECT=ModuleExport; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-30
    pub const spinner = @import("client/repl/spinner.zig");
    /// CANARY: REQ=REQ-SHELL-INTERRUPT-011; FEATURE="SourceInterrupt"; ASPECT=PlatformExport; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-30
    pub const platform = @import("client/repl/platform.zig");
};

// Shared CLI transport response formatter abstraction.
pub const cli_transport_response = @import("cli/transport_response.zig");

// Extend planner module
pub const planner_wcoj = @import("planner/wcoj.zig");

// Graph analytics (lightweight builders and centrality algorithms)
pub const graph = struct {
    pub const builders = @import("graph/builders.zig");
    pub const pagerank = @import("graph/centrality_pagerank.zig");
    pub const eigenvector = @import("graph/centrality_eigenvector.zig");
    pub const betweenness = @import("graph/centrality_betweenness.zig");
    pub const closeness = @import("graph/centrality_closeness.zig");
    pub const bridge_leverage = @import("graph/centrality_bridge_leverage.zig");
    pub const grey_cardinal = @import("graph/centrality_grey_cardinal.zig");
    // Performance-optimized algorithms
    pub const optimized = @import("graph/centrality_optimized.zig");
    pub const dfs_iterative = @import("graph/traversal_dfs_iterative.zig");
    pub const iddfs = @import("graph/traversal_iddfs.zig");
    pub const topo_kahn = @import("graph/topological_sort_kahn.zig");
    pub const topo_dfs = @import("graph/topological_sort_dfs.zig");
    pub const cycle_directed = @import("graph/cycle_detect_directed.zig");
    pub const cycle_undirected = @import("graph/cycle_detect_undirected.zig");
    pub const dag_shortest = @import("graph/shortest_dag_path.zig");
    pub const shortest_dijkstra = @import("graph/shortest_dijkstra.zig");
    pub const shortest_astar = @import("graph/shortest_astar.zig");
    pub const shortest_unweighted = @import("graph/shortest_unweighted_bfs_paths.zig");
    pub const union_find = @import("graph/union_find.zig");
    pub const strongly_connected_components = @import("graph/strongly_connected_components.zig");
    pub const community_louvain = @import("graph/community_louvain.zig");
    pub const community_label_propagation = @import("graph/community_label_propagation.zig");
    pub const traversal_bfs = @import("graph/traversal_bfs.zig");
    pub const leiden = @import("graph/leiden.zig");
    pub const flow = struct {
        pub const edmonds_karp = @import("graph/flow_edmonds_karp.zig");
        pub const dinic = @import("graph/flow_dinic.zig");
        pub const hopcroft_karp = @import("graph/flow_hopcroft_karp.zig");
    };
    pub const containers = struct {
        pub const lru = @import("graph/containers/lru.zig");
        pub const lfu = @import("graph/containers/lfu.zig");
        pub const bloom_filter = @import("graph/containers/bloom_filter.zig");
        pub const count_min_sketch = @import("graph/containers/count_min_sketch.zig");
        pub const skiplist = @import("graph/container_skiplist.zig");
        pub const trie = @import("graph/container_trie.zig");
    };
    pub const string_search = struct {
        pub const kmp = @import("graph/string_search_kmp.zig");
    };
};

// Multitenancy and GPU feature flagger re-exports so tests/benchmarks can import via the geode package
pub const multitenancy = struct {
    pub const registry = @import("multitenancy/registry.zig");
};

pub const gpu = struct {
    pub const flagger = @import("gpu/flagger.zig");
};

// Audit modules for CLI integration
// GAP-0075: Added syslog export for CLI audit integration
pub const audit = struct {
    pub const config = @import("audit_lib").config;
    pub const test_support = @import("audit/test_support.zig");
    pub const logger = @import("audit_lib").logger;
    pub const system_logger = @import("log/logger.zig");
    pub const events = @import("audit_lib").events;
    pub const time = @import("audit_lib").time;
    pub const syslog = @import("audit_lib").syslog;
};

// Runtime-flag gated test-support exports for acceptance tests
pub const tde_stub = @import("security/tde.zig");
pub const mfa_test_support = @import("mfa");

// Top-level security module exports for tests
pub const auth = @import("geode_auth");
pub const multi_graph_security = @import("security/multi_graph_security.zig");
// GAP-0289: Per-tenant resource quota manager
pub const tenant_quota = @import("security/tenant_quota.zig");

// Security modules for enhanced RLS and compliance features
pub const security = struct {
    pub const rls_enhanced = @import("security/rls_enhanced.zig");
    pub const auth = @import("geode_auth");
    pub const multi_graph_security = @import("security/multi_graph_security.zig");
    pub const audit = @import("security/audit.zig");
    pub const tenant_quota = @import("security/tenant_quota.zig");
};
pub const fts_advanced_stub = @import("fts/advanced.zig");
pub const parallel_exec_stub = @import("execution/parallel.zig");
pub const cbo_api_stub = @import("planner/cbo.zig");
pub const graph_algos_stub = @import("graph/algorithms.zig");

// Distributed consensus primitives (Raft) for tests/benchmarks
// (Removed distributed.raft re-export to avoid duplicate module inclusion with separate distributed module import)

// (Note) Streaming and txn modules are added as separate build modules; tests import them directly as needed.

// Lightweight helper to carry parameter bindings across subsystems
pub const ParamBindings = struct {
    names: []const []const u8,
    values: []const eval.Value,
};

/// Construct an eval.Env from identifier bindings and optional ParamBindings
pub fn makeEnv(id_names: []const []const u8, id_values: []const eval.Value, params: ?ParamBindings) eval.Env {
    if (params) |p| {
        return .{ .names = id_names, .values = id_values, .param_names = p.names, .param_values = p.values };
    }
    return .{ .names = id_names, .values = id_values };
}

/// Server functionality for library mode embedding
/// GAP-0122 FIX: Added clear documentation and recommended patterns for embedding use cases
// CANARY: REQ=REQ-LIBRARY-EMBEDDING-001; FEATURE="LibraryModeEmbedding"; ASPECT=ML; STATUS=TESTED; OWNER=library; UPDATED=2026-01-12
///
/// ## Library Mode Embedding Guide
///
/// Geode can be embedded in applications in two modes:
///
/// ### 1. Query-Only Mode (Recommended for most use cases)
/// Use `parse()`, `parseGql()`, and `execute()` functions directly to:
/// - Parse and validate GQL queries
/// - Execute queries against an in-process graph storage
/// - No network stack required
///
/// Example:
/// ```zig
/// const geode = @import("geode");
/// const allocator = std.heap.page_allocator;
///
/// // Parse a query
/// var result = try geode.parse(allocator, "MATCH (n:Person) RETURN n", .{});
/// defer result.deinit();
///
/// // Execute against local storage
/// var storage = geode.graph_store.GraphStore.init(allocator);
/// defer storage.deinit();
///
/// const exec_result = try geode.execute(allocator, result.program, &storage);
/// ```
///
/// ### 2. Client Mode (For distributed deployments)
/// Connect to a running Geode server via QUIC transport:
/// - Use the CLI binary as a subprocess for server management
/// - Use the `transport.quic` module for client connections
///
/// Example (recommended pattern):
/// ```zig
/// // Start server as subprocess
/// const server_proc = try std.process.Child.init(&.{
///     "geode", "serve", "--listen", "0.0.0.0:3141"
/// }, allocator);
///
/// // Connect client using QUIC
/// const client = try geode.transport.quic.Client.connect("localhost:3141");
/// defer client.disconnect();
///
/// const response = try client.query("MATCH (n) RETURN n");
/// ```
///
/// ### 3. Full Server Mode (Advanced)
/// For embedded server scenarios requiring full QUIC transport:
/// - Use the CLI module directly (requires transport dependencies)
/// - Or spawn the geode binary as a managed subprocess
///
/// Note: The `runServerWithArgs()` function returns `NotImplemented` because
/// the server requires the full transport stack which is not exposed in the
/// library interface to keep dependencies minimal.
///
/// See docs/API_REFERENCE.md for complete embedding examples.
pub const server = struct {
    /// Server embedding error types
    pub const EmbeddingError = error{
        /// Server functionality requires CLI module or subprocess
        NotImplemented,
        /// Server initialization failed
        InitializationFailed,
    };

    /// Attempts to run a server with the given arguments.
    /// NOTE: This returns `NotImplemented` - see the embedding guide above for recommended patterns.
    /// For embedded server functionality, use one of these approaches:
    /// 1. Query-only mode using parse() and execute() directly
    /// 2. Client mode connecting to a running server
    /// 3. Subprocess mode spawning the geode binary
    pub fn runServerWithArgs(allocator: std.mem.Allocator, args: [][:0]u8) EmbeddingError!void {
        _ = allocator;
        _ = args;
        std.debug.print(
            \\Geode Library Mode: Server embedding not directly supported.
            \\
            \\Recommended patterns:
            \\  1. Query-only: Use geode.parse() and geode.execute() for in-process queries
            \\  2. Client mode: Connect to a running geode server via QUIC
            \\  3. Subprocess: Spawn 'geode serve' as a managed child process
            \\
            \\See src/lib.zig documentation or docs/API_REFERENCE.md for examples.
            \\
        , .{});
        return EmbeddingError.NotImplemented;
    }

    /// Check if server mode is available (always false for library embedding)
    pub fn isServerModeAvailable() bool {
        return false;
    }

    /// Get recommended embedding pattern based on use case
    pub fn getRecommendedPattern(use_case: EmbeddingUseCase) []const u8 {
        return switch (use_case) {
            .local_queries => "Query-only mode: Use parse() and execute() directly",
            .distributed_queries => "Client mode: Connect to geode server via QUIC",
            .embedded_server => "Subprocess mode: Spawn 'geode serve' as child process",
            .testing => "Query-only mode: Use parse() for syntax validation",
        };
    }

    pub const EmbeddingUseCase = enum {
        local_queries,
        distributed_queries,
        embedded_server,
        testing,
    };

    // Note: connection_handler imported directly by server files to avoid circular dependency
};

pub fn parseGql(src: []const u8, allocator: std.mem.Allocator) !ParseResult {
    // Enforce ident-only ORDER BY keys and forbid function calls unless explicitly relaxed
    const allow_expr = if (std.process.getEnvVarOwned(allocator, "GEODE_ORDER_KEYS_EXPR")) |v| blk: {
        defer allocator.free(v);
        break :blk true;
    } else |_| false;
    const opts: ParseOptions = if (allow_expr) .{} else .{ .ident_order_only = true, .forbid_orderby_calls = true };
    return parseGqlOptions(src, allocator, opts);
}
// CANARY: REQ=REQ-GQL-004; FEATURE="Pagination Legality (US001)"; ASPECT=IllegalOrderKeyPolicy; STATUS=TESTED; TEST=TestGQL_IllegalOrderKey; OWNER=planner; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-004; FEATURE="Pagination Legality (US001)"; ASPECT=OrderKeyExprOverrideEnv; STATUS=TESTED; TEST=TestGQL_IllegalOrderKey; OWNER=planner; UPDATED=2025-09-27

pub fn parseGqlOptions(src: []const u8, allocator: std.mem.Allocator, opts: ParseOptions) !ParseResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next(), .strict_order_keys = opts.strict_order_keys, .ident_order_only = opts.ident_order_only, .forbid_orderby_calls = opts.forbid_orderby_calls, .forbid_orderby_paths = opts.forbid_orderby_paths, .ts_extensions = opts.ts_extensions };
    const program = try p.parseProgram();
    return .{ .program = program, .arena = arena, .last_error = p.last_error, .has_double_solidus_comment = lx.has_double_solidus_comment, .has_double_dash_comment = lx.has_double_dash_comment, .has_unwind = p.has_unwind };
}

pub const ParseOutcome = union(enum) {
    Ok: ParseResult,
    Err: struct { msg: []const u8, line: u32, column: u32, token: @import("gql_lib").token.TokenKind, has_double_dash_comment: bool, has_unwind: bool = false },
};

// Parse but capture parser error details instead of throwing; allocation errors still throw.
pub fn parseGqlOutcome(src: []const u8, allocator: std.mem.Allocator, opts: ParseOptions) !ParseOutcome {
    var arena = std.heap.ArenaAllocator.init(allocator);
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next(), .strict_order_keys = opts.strict_order_keys, .ident_order_only = opts.ident_order_only, .forbid_orderby_calls = opts.forbid_orderby_calls, .forbid_orderby_paths = opts.forbid_orderby_paths, .ts_extensions = opts.ts_extensions };
    const program = p.parseProgram() catch {
        const msg = p.last_error orelse "parse error";
        const loc = p.cur.loc;
        const kind = p.cur.kind;
        const has_dd = lx.has_double_dash_comment;
        const has_uw = p.has_unwind;
        arena.deinit();
        return .{ .Err = .{ .msg = msg, .line = loc.line, .column = loc.column, .token = kind, .has_double_dash_comment = has_dd, .has_unwind = has_uw } };
    };
    return .{ .Ok = .{ .program = program, .arena = arena, .last_error = p.last_error, .has_double_solidus_comment = lx.has_double_solidus_comment, .has_double_dash_comment = lx.has_double_dash_comment, .has_unwind = p.has_unwind } };
}

// Re-export execution and graph_store for integration tests
pub const execution = @import("execution.zig");
pub const graph_store = @import("graph_store.zig");
pub const uuid = @import("uuid");
// CANARY: REQ=REQ-PERF-WAL-006; FEATURE="WriteAheadLog"; ASPECT=LibExport; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-17
// Re-export WAL for server initialization and tests
pub const wal = @import("wal.zig");
pub const fle_integration = @import("fle_integration.zig");
pub const fle_commands = @import("admin/fle_commands.zig");
pub const fle_key_manager = @import("fle_key_manager");
pub const fle_key_types = @import("fle_key_types");

// User management and authentication
pub const user_management = @import("security/user_management.zig");
pub const api_keys = @import("auth_lib").api_keys;
pub const mtls_provider = @import("security/mtls_provider.zig");

// HMAC chain integrity module for internal auth storage
pub const auth_hmac = @import("auth_lib").hmac;

// Auth graph manager module is available as a separate build module import:
// @import("auth_graph_manager") — see build.zig for module registration.
// It depends on geode (root_mod) so it cannot be re-exported here without a cycle.

// GAP-0280: RLS types are available as a separate build module: @import("rls_types").
// Do NOT re-export here -- rls_types.zig is its own module to avoid dual-module conflicts.

// QUIC algorithms and connection management
pub const algorithms = @import("algorithms.zig");
pub const connection_manager = @import("transport/connection_manager.zig");

test "lib.parseGql basic" {
    const ally = std.testing.allocator;
    var res = try parseGql("MATCH (a)-[r]->(b) RETURN a", ally);
    defer res.deinit();
    try std.testing.expect(res.program.statements.len == 1);
}
