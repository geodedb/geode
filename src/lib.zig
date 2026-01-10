const std = @import("std");
const Lexer = @import("gql/lexer.zig").Lexer;
const Parser = @import("gql/parser.zig").Parser;
pub const ast = @import("gql/ast.zig");

// GQL module namespace
pub const gql = struct {
    pub const ast = @import("gql/ast.zig");
    pub const token = @import("gql/token.zig");
    pub const status = @import("gql/status.zig");
    pub const parser = @import("gql/parser.zig");
    pub const lexer = @import("gql/lexer.zig");
};

// CANARY: REQ=REQ-METADATA-LIB-001; FEATURE="MetadataIntegration"; ASPECT=LibExport; STATUS=IMPL; OWNER=lib; UPDATED=2026-01-03
// Export language metadata for LSP and other consumers
pub const language_metadata = @import("gql/language_metadata.zig");

// CANARY: REQ=REQ-M5.2-LIB-EXPORT-001; FEATURE="Circular Dependency Resolution"; ASPECT=ValueTypesExport; STATUS=IMPL; OWNER=lib; UPDATED=2025-11-13
// Phase 5 M5.2: Export value_types module for external access
pub const value_types = @import("value_types.zig");

pub const ParseResult = struct {
    program: ast.Program,
    arena: std.heap.ArenaAllocator,
    last_error: ?[]const u8 = null,
    has_double_solidus_comment: bool = false,
    has_double_dash_comment: bool = false,

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
    };
}

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
// Re-export evaluator for expression tests and demos
pub const eval = @import("eval.zig");
pub const diagnostics = @import("diagnostics.zig");
// Re-export type promotion utilities for advanced types roundtrip tests
pub const type_promotion = @import("eval/type_promotion.zig");
// Re-export unicode utilities (normalization, case folding, UTF-16/WTF-8 helpers)
pub const unicode = @import("unicode/geode_unicode.zig");
pub const unicode_tables = @import("unicode/unicode_tables.zig");
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
    pub const uuid = @import("types/uuid.zig");
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

// Re-export test harness for CLI integration
pub const test_harness = @import("test_harness.zig");

// CANARY: REQ=REQ-TXN-UNDO-003; FEATURE="TransactionUndoLog"; ASPECT=LibExport; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
// Re-export transaction undo log for CLI rollback support
pub const txn_undo_log = @import("txn_undo_log.zig");

// CANARY: REQ=REQ-MULTI-GRAPH-030; FEATURE="MultiGraphIsolation"; ASPECT=GraphStorageManagerExport; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-22
// Re-export graph storage manager for multi-graph isolation support
pub const graph_storage_manager = @import("server/graph_storage_manager.zig");

// Machine Learning and Analytics
pub const ml = struct {
    pub const graph_embeddings = @import("ml/graph_embeddings.zig");
};

// Real-time Analytics and Streaming
pub const analytics = struct {
    pub const real_time = @import("analytics/real_time.zig");
};
// Re-export server graph executor for tests needing internal MATCH primitives
// Benchmark modules (variance envelopes)
pub const benchmarks = struct {
    // Pagination ordered variance benchmark (exposed for variance runner)
    pub const pagination = @import("benchmarks/pagination_variance.zig");
    // Pagination execution (streaming page) variance benchmark
    pub const pagination_execution = @import("benchmarks/pagination_execution_variance.zig");
    // Shared variance configuration helper
    pub const variance_config = @import("benchmarks/variance_config.zig");
};
// Time-series module (initial in-memory scaffold)
pub const timeseries = @import("timeseries/timeseries.zig");
// Re-export storage submodules needed across server modules (CSR adjacency)
pub const storage = struct {
    // Note: CSR is available to the server binary via build.zig module injection; tests import it directly.
    pub const csr = @import("storage/csr_adjacency.zig");
    pub const heap = @import("storage/heap.zig");
    // pub const constraints = @import("storage/constraints.zig");

    // Core storage components for CLI/tools
    // Note: These must be imported as modules injected by build.zig to avoid file-in-multiple-modules errors
    pub const wal = @import("wal");
    pub const page_manager = @import("storage_page_manager");
};

// Re-export index modules for specialized data types
pub const index = struct {
    pub const patricia = @import("index/patricia.zig");
    pub const rtree = @import("index/rtree.zig");
    pub const hnsw = @import("index/hnsw.zig");
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

// Re-export wire protocol definitions for tests/benchmarks needing Value / frame types
pub const protocol = @import("protocol.zig");

// Distributed systems modules
pub const distributed = struct {
    pub const raft_consensus = @import("distributed/raft_consensus.zig");
    pub const txn_coordinator = @import("distributed/txn_coordinator.zig");
    pub const cluster = @import("distributed/cluster_simple.zig");
    pub const raft = @import("distributed/raft.zig");
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
    pub const keymap_emacs = @import("client/repl/keymap_emacs.zig");
    pub const keymap_vi = @import("client/repl/keymap_vi.zig");
    pub const repl_complete = @import("client/repl/repl_complete.zig");
    pub const repl_config = @import("client/repl/repl_config.zig");
};

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
    pub const config = @import("audit/config.zig");
    pub const logger = @import("audit/logger.zig");
    pub const system_logger = @import("log/logger.zig");
    pub const events = @import("audit/events.zig");
    pub const time = @import("audit/time.zig");
    pub const syslog = @import("audit/syslog.zig");
};

// Runtime-flag gated scaffold stub re-exports for acceptance tests
pub const tde_stub = @import("security/tde.zig");
pub const mfa_stub = @import("mfa");

// Top-level security module exports for tests
pub const auth = @import("geode_auth");
pub const multi_graph_security = @import("security/multi_graph_security.zig");

// Security modules for enhanced RLS and compliance features
pub const security = struct {
    pub const rls_enhanced = @import("security/rls_enhanced.zig");
    pub const auth = @import("geode_auth");
    pub const multi_graph_security = @import("security/multi_graph_security.zig");
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

// Server functionality for CLI integration - will be implemented in CLI module directly
pub const server = struct {
    pub fn runServerWithArgs(allocator: std.mem.Allocator, args: [][:0]u8) !void {
        // This is a placeholder - the real implementation is in CLI module
        // which has access to the transport/quic module
        _ = allocator;
        _ = args;
        std.debug.print("Error: Server implementation should be called from CLI module\n", .{});
        return error.NotImplemented;
    }
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
    return .{ .program = program, .arena = arena, .last_error = p.last_error, .has_double_solidus_comment = lx.has_double_solidus_comment, .has_double_dash_comment = lx.has_double_dash_comment };
}

pub const ParseOutcome = union(enum) {
    Ok: ParseResult,
    Err: struct { msg: []const u8, line: u32, column: u32, token: @import("gql/token.zig").TokenKind, has_double_dash_comment: bool },
};

// Parse but capture parser error details instead of throwing; allocation errors still throw.
pub fn parseGqlOutcome(src: []const u8, allocator: std.mem.Allocator, opts: ParseOptions) !ParseOutcome {
    //
    var arena = std.heap.ArenaAllocator.init(allocator);
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next(), .strict_order_keys = opts.strict_order_keys, .ident_order_only = opts.ident_order_only, .forbid_orderby_calls = opts.forbid_orderby_calls, .forbid_orderby_paths = opts.forbid_orderby_paths, .ts_extensions = opts.ts_extensions };
    const program = p.parseProgram() catch {
        const msg = p.last_error orelse "parse error";
        const loc = p.cur.loc;
        const kind = p.cur.kind;
        const has_dd = lx.has_double_dash_comment;
        arena.deinit();
        return .{ .Err = .{ .msg = msg, .line = loc.line, .column = loc.column, .token = kind, .has_double_dash_comment = has_dd } };
    };
    return .{ .Ok = .{ .program = program, .arena = arena, .last_error = p.last_error, .has_double_solidus_comment = lx.has_double_solidus_comment, .has_double_dash_comment = lx.has_double_dash_comment } };
}

// Re-export execution and graph_store for integration tests
pub const execution = @import("execution.zig");
pub const graph_store = @import("graph_store.zig");
pub const fle_integration = @import("fle_integration.zig");
pub const fle_commands = @import("admin/fle_commands.zig");
pub const fle_key_manager = @import("fle_key_manager");
pub const fle_key_types = @import("fle_key_types");

// User management and authentication
pub const user_management = @import("security/user_management.zig");
pub const auth_state = @import("security/auth_state.zig");

// QUIC algorithms and connection management
pub const algorithms = @import("algorithms.zig");
pub const connection_manager = @import("transport/connection_manager.zig");

test "lib.parseGql basic" {
    const ally = std.testing.allocator;
    var res = try parseGql("MATCH (a)-[r]->(b) RETURN a", ally);
    defer res.deinit();
    try std.testing.expect(res.program.statements.len == 1);
}
