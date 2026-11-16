const std = @import("std");

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const Lexer = @import("gql/lexer.zig").Lexer;
const Parser = @import("gql/parser.zig").Parser;
pub const ast = @import("gql/ast.zig");
const confusable_check = @import("gql/confusable_check.zig");

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
    const om = @import("otel_metrics");
    const gql_obs = @import("gql_lib").observability;
    const duration = om.DurationTimer.start();
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    // GQL parser span — emits when gql lib is built with -Dwith_otel=true
    // and otel_metrics.bindLibraryGlobals has wired the seam at server
    // startup. Both gates collapse to comptime no-ops otherwise.
    const _parse_span = gql_obs.startQueryExecutionSpan("PARSE", null);
    defer gql_obs.endQueryExecutionSpan(_parse_span, true, 0);

    var lexer = Lexer{ .src = source };
    var parser = Parser{ .lx = &lexer, .arena = &arena, .cur = lexer.next() };

    const program = parser.parseProgram() catch |err| {
        const dur_s = duration.seconds();
        om.recordQueryParse(dur_s, .error_, @errorName(err));
        om.recordQueryParseError(@errorName(err));
        return err;
    };
    const dur_s_ok = duration.seconds();
    om.recordQueryParse(dur_s_ok, .success, null);

    // ISO/IEC 39075:2024 RQ-0012: reject programs containing visually
    // confusable identifiers (e.g., Latin a vs Cyrillic а). The skeleton
    // algorithm lives in src/unicode/confusables.zig and is invoked here
    // so every parser entry point — CLI, REPL, QUIC handler, gRPC handler
    // — gets the protection automatically.
    confusable_check.checkProgram(allocator, &program) catch |err| switch (err) {
        confusable_check.Error.ConfusableIdentifier => return error.ConfusableIdentifier,
        confusable_check.Error.OutOfMemory => return error.OutOfMemory,
    };

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
// SONNY-3181, SONNY-3191: the thread-stack guard and the server's request
// thread stack size.
pub const stack_guard = @import("stack_guard.zig");
// GAP-0875: exported for the residual-stubs regression suite (test-gap0875)
pub const memory_mapped_io = @import("performance/memory_mapped_io.zig");
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
pub const temporal = @import("temporal.zig");
// Query analysis helpers (EXPLAIN/PROFILE traits)
pub const query_traits = @import("query/query_traits.zig");
pub const planned_read_runtime = @import("execution/planned_read_runtime.zig");
pub const graph_storage_adapter = @import("storage/graph_storage_adapter.zig");
/// SONNY-6636: the GEODBAK1 file archive (backups, durable Raft snapshots).
pub const graph_archive = @import("storage/graph_archive.zig");
// SONNY-6524: opening a graph whose shard label dictionaries disagree.
pub const label_dict_divergence = @import("storage/label_dict_divergence.zig");
// Task 19: per-graph group-commit coordinator.
pub const group_commit = @import("storage/group_commit.zig");
// Graph-sharding Phase 1: N-way sharded HashMap wrapper (foundation for
// per-shard locking in Phase 2).  Lives in the graph_storage library
// (v0.2.0+) as a reusable primitive; re-exported here so Geode callers
// can reach it via `geode.sharded_store` uniformly with the other
// re-exports.
pub const sharded_store = @import("graph_storage").sharded_store;

// Re-export the thread-pool wrapper so tests and internal code can reach
// the preferred parallelism primitive via `geode.pooled` (per project
// convention, threading goes through the gitlab.com/devnw/zig/thread-pool
// library; see memory/feedback_thread_pool_first.md).
pub const pooled = @import("transport/thread_pool");
// Re-export evaluator for expression tests and demos
pub const eval = @import("eval.zig");
/// SONNY-6637: the shared function operand-count table.
pub const function_arity = @import("eval/function_arity.zig");
pub const diagnostics = @import("diagnostics.zig");
// Re-export type promotion utilities for advanced types roundtrip tests
pub const type_promotion = @import("eval/type_promotion.zig");
pub const index_manager = @import("index/index_manager.zig");
pub const advanced_types_optimizer = @import("optimizer/advanced_types_optimizer.zig");
// Re-export the official Zig client package for internal consumers migrating
// off the legacy in-repo client implementations.
pub const zig_client = @import("geode_client_zig");
pub const zig_quic_bridge = @import("client/zig_quic_bridge.zig");
/// SONNY-6487: the one host:port grammar (docs/DSN.md) every address uses.
pub const host_port = @import("client/host_port.zig");
/// SONNY-6544: DSN userinfo (last '@', percent-decoded) and the one
/// redaction every printed address or DSN goes through.
pub const dsn_credentials = @import("client/dsn_credentials.zig");
/// SONNY-6554/6569: the one strict DSN parser (CLI --dsn and the MCP endpoint).
pub const dsn_params = @import("client/dsn_params.zig");
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
    pub const decimal_text = @import("types/decimal_text.zig");
    pub const narrowing = @import("types/narrowing.zig");
    pub const datetime = @import("types/datetime.zig");
    pub const jsonb = @import("types/jsonb.zig");
    pub const xml = @import("types/xml.zig");
    pub const url = @import("types/url.zig");
    pub const public_suffix = @import("types/public_suffix.zig");
    pub const wkt = @import("types/wkt.zig");
    pub const uuid = @import("uuid");
    pub const arrays = @import("types/arrays.zig");
    pub const bitstring = @import("types/bitstring.zig");
    pub const range = @import("types/range.zig");
    pub const extended = @import("types/extended.zig");
    pub const extended_functions = @import("types/extended_functions.zig");
    pub const numeric_promotion = @import("types/numeric_promotion.zig");
    pub const vector = @import("types/vector.zig");
    pub const geographic = @import("types/geographic.zig");
    pub const cryptographic = @import("types/cryptographic.zig");
};

// Re-export server graph common types
pub const graph_common = @import("types/graph_common.zig");
// GAP-0876: enhanced materialized view manager (exact-match query rewrite,
// API level). Standalone subsystem — not yet consulted by the execution
// path; exported so the named regression test
// (tests/test_materialized_views_enhanced.zig) reaches it via `geode`.
pub const enhanced_materialized_views = @import("query/enhanced_materialized_views.zig");

// Test harness is not exported from production modules; tests import it directly.

// CANARY: REQ=REQ-TXN-UNDO-003; FEATURE="TransactionUndoLog"; ASPECT=LibExport; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
// Re-export transaction undo log for CLI rollback support
pub const txn_undo_log = @import("txn_undo_log.zig");
/// SONNY-3348 (round 18): the statement undo record.
pub const statement_undo = @import("statement_undo.zig");

// Machine Learning and Analytics
pub const ml = struct {
    pub const graph_embeddings = @import("ml/graph_embeddings.zig");
};

// Real-time Analytics and Streaming
pub const analytics = struct {
    pub const real_time = @import("analytics/real_time.zig");
};

// CDC / streaming sinks (webhook, Kafka, file, memory). Exposed for the
// GAP-0855 sink regressions and any embedder wiring a custom sink.
pub const streaming = struct {
    pub const cdc_sinks = @import("streaming/cdc_sinks.zig");
    pub const cdc_enhanced = @import("streaming/cdc_enhanced.zig");
    pub const sinks = struct {
        pub const webhook_sink = @import("streaming/sinks/webhook_sink.zig");
        pub const kafka_sink = @import("streaming/sinks/kafka_sink.zig");
        pub const kafka_wire = @import("streaming/sinks/kafka_wire.zig");
    };
};
// Re-export server state for unified binary
pub const server_state = @import("server/server_state.zig");
pub const capability_gate = @import("server/capability_gate.zig");
pub const node_scan_stream = @import("server/node_scan_stream.zig");
// Note: query_ast_cache is imported directly by server files to avoid circular dependency
// (it needs ParseOptions/ParseResult which are defined in this file)
// Re-export query_plan_cache for unified binary
pub const query_plan_cache = @import("server/query_plan_cache.zig");
// GAP-0755: Per-query arena pool for executor scratch.
pub const query_arena = @import("server/query_arena.zig");
// Re-export server_flags for unified binary
pub const server_flags = @import("server/server_flags.zig");
// Re-export backup_manager for unified binary
pub const backup_manager = @import("server/backup_manager.zig");
// Re-export proto_util for unified binary
pub const proto_util = @import("server/proto_util.zig");
// Re-export fd_limit helper so tests can exercise the startup hook directly.
pub const fd_limit = @import("server/fd_limit.zig");
// Re-export explain/profile payload builders for server handlers and tests
pub const explain_payload = @import("server/explain_payload.zig");
pub const profile_payload = @import("server/profile_payload.zig");
// Per-mutation wall-clock timing instrumentation (opt-in via GEODE_MUTATION_TIMING_LOG=1).
pub const mutation_timing = @import("server/mutation_timing.zig");
// Runtime metrics registry: named atomic counters for throughput, lock-wait, and allocator diagnostics.
// Phase C1: imported as a named module (single canonical instance) so the OTLP
// bridge in otel_metrics.zig can share the SAME `runtime_metrics.Registry` type
// without the file belonging to two modules ("file exists in two modules").
pub const runtime_metrics = @import("runtime_metrics");
// Bulk-ingest pattern detection for the msft-graph hot-path CREATE / MATCH+CREATE
// forms (Task 10 + Task 11 of the enterprise-ingest-throughput plan).
pub const bulk_ingest = @import("execution/bulk_ingest.zig");
// Re-exported so the server's bulk fast-path can reach the property codec via
// the 'geode' module (avoids putting the file in two modules at once — see
// Zig-0.16 "file exists in modules" error).
pub const property_value_codec = @import("property_value_codec.zig");
// Re-export heap for test_integration and other modules
pub const heap = @import("storage/heap.zig");
// Re-export catalog for tests
pub const catalog = @import("schema/catalog.zig");
// Re-export tde_file_encryption for tests
pub const tde_file_encryption = @import("storage/tde_file_encryption.zig");
// SONNY-6452: detect/repair stores written in the pre-0.4.12 TDE page envelope.
pub const tde_page_tail = @import("storage/tde_page_tail.zig");

// Benchmark modules (variance envelopes)
pub const benchmarks = struct {
    // Shared variance configuration helper
    pub const variance_config = @import("benchmarks/variance_config.zig");
};
// Time-series module
pub const timeseries = @import("timeseries/timeseries.zig");

// Re-export index modules for specialized data types
pub const index = struct {
    pub const patricia = @import("index/patricia.zig");
    pub const rtree = @import("rtree_lib");
    pub const hnsw = @import("hnsw_lib");
    pub const interval_tree = @import("index/interval_tree.zig");
    pub const jsonb_inverted = @import("index/jsonb_inverted.zig");
    pub const domain_trie = @import("index/domain_trie.zig");
    pub const fulltext = @import("index/fulltext.zig");
    /// The fts-storage adapter that backs the `fulltext` facade. Re-exported so
    /// callers/tests can construct a `FtsStorageAdapter` + named index and wrap
    /// it via `fulltext.FullTextIndex.initBacked` (the facade has no standalone
    /// in-memory `init` after the fts-storage migration).
    pub const fts_storage_adapter = @import("storage/fts_storage_adapter.zig");
    /// Standalone full-text tokenizer producing fts_storage TermPostings.
    /// Re-exported so the unit suite can reach it through the geode module.
    pub const fts_tokenizer = @import("index/fts_tokenizer.zig");
    /// The external fts-storage library (TermPosting etc). Re-exported so tests
    /// reaching the tokenizer through `geode` can also name its return type.
    pub const fts_storage = @import("fts_storage_lib");
    pub const IndexManager = @import("index/index_manager.zig").IndexManager;
    pub const vector_index = @import("index/vector_index.zig");
    pub const spatial_index = @import("index/spatial_index.zig");
    pub const advanced_types_index = @import("index/advanced_types_index.zig");
};

// Re-export wire-neutral protocol value types for distributed coordination.
pub const protocol = @import("protocol.zig");

// LSP-SEC-008: shared loopback-bind classification (single source of truth
// for the LSP standalone listener and the MCP HTTP transport bind policy).
pub const net_policy = @import("net_policy.zig");

// Distributed systems modules
pub const distributed = struct {
    pub const raft_consensus = @import("distributed/raft_consensus.zig");
    pub const raft_snapshot_manager = @import("distributed/raft_snapshot_manager.zig");
    pub const raft_apply = @import("distributed/raft_apply.zig");
    pub const cluster_replication = @import("distributed/cluster_replication.zig");
    /// SONNY-3348 (round 19): a statement's replicated writes, one entry.
    pub const statement_proposals = @import("distributed/statement_proposals.zig");
    pub const txn_coordinator = @import("distributed/txn_coordinator.zig");
    pub const cluster = @import("distributed/cluster.zig");
    /// SEC-INFRA-03: shared cluster bearer-token validator (dual-token
    /// rotation). Exported so transport-layer federation auth (QUIC + gRPC
    /// handlers, which live in the exe module) can delegate without a
    /// file-path import that would split cluster_auth.zig across modules.
    pub const cluster_auth = @import("distributed/cluster_auth.zig");
    pub const raft = @import("raft");
    /// GPS Phase 6 Task 6-3: Principal identity envelope for cluster RPCs.
    pub const principal_envelope = @import("distributed/principal_envelope.zig");
    /// SEC-D009: the Raft frame replay check (SONNY-6600 regression).
    pub const nonce_tracker = @import("distributed/nonce_tracker.zig");
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
pub const query_result_accumulator = @import("client/query_result_accumulator.zig");
pub const quic_query_runner = @import("client/quic_query_runner.zig");
pub const query_runner = @import("client/query_runner.zig");
pub const query_scope = @import("client/query_scope.zig");
pub const grpc_query_transport = @import("client/grpc_query_transport.zig");
// SONNY-6647: JSON to wire values, for geode query --param and the MCP query tool.
pub const param_json = @import("client/param_json.zig");
// SONNY-6593: the gRPC RPCs the server registers (geode.proto's service).
pub const grpc_service_methods = @import("transport/grpc_service_methods.zig");
// Bug 731 (#2): HELLO-response decode seam shared with src/cli/main.zig so the
// CLI login ownership contract is reachable from a test binary.
pub const hello_decode = @import("client/hello_decode.zig");

// An LFU cache; only tests use it (fuzz/targets/lfu_cache_fuzz.zig).
// SONNY-6511 removed the rest of src/graph/ (37 files no build compiled or
// ran). SONNY-6540 item 10 removed its standalone Louvain and label
// propagation, which only tests/e2e_graph_algos_new.zig called: the
// algo.louvain and algo.labelPropagation procedures run
// src/execution/centrality_algorithms.zig.
pub const graph = struct {
    pub const containers = struct {
        pub const lfu = @import("graph/containers/lfu.zig");
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
// GAP-0839: Durable tenant lifecycle registry
pub const tenant_registry = @import("security/tenant_registry.zig");

// Security modules for RLS and compliance features
pub const security = struct {
    // GAP-0890: policy-enforced key-rotation registry (rotateNow refuses
    // under min_interval; rotateIfDue is the operator-invoked scheduler tick).
    pub const key_rotation = @import("security/key_rotation.zig");
    pub const auth = @import("geode_auth");
    pub const multi_graph_security = @import("security/multi_graph_security.zig");
    pub const audit = @import("security/audit.zig");
    // SONNY-3045: the Windows Event Log, syslog and JSON audit exporters.
    pub const audit_formatter = @import("security/audit_formatter.zig");
    pub const tenant_quota = @import("security/tenant_quota.zig");
    // GAP-0839: Durable tenant lifecycle registry
    pub const tenant_registry = @import("security/tenant_registry.zig");
    // GPS Phase 1: canonical Principal type and authentication result type
    pub const principal = @import("security/principal.zig");
    pub const authn = @import("security/authn.zig");
    // GPS Phase 2: decision types and central decide() entry point
    pub const gps = @import("security/gps.zig");
    // SONNY-6341: the FLE roles each user may act under.
    pub const fle_role_grants = @import("security/fle_role_grants.zig");
    // GPS Phase 2 (Task 2-2): transport-agnostic Principal builder
    pub const principal_derive = @import("security/principal_derive.zig");
    // GPS Phase 4 (Task 4-1): graph-based role resolution (authRoleFromRecord + resolveRoleFromGraph).
    // Exposed as a named build module ("role_resolver") because role_resolver.zig imports
    // user_storage, which itself imports geode — making a direct relative import circular.
    pub const role_resolver = @import("role_resolver");
    // GPS Phase 4 (Task 4-2): in-memory policy catalog (Policy type + CRUD).
    pub const policy_catalog = @import("security/policy_catalog.zig");
    /// SONNY-6329: one auth / policy DDL operation at a time.
    pub const auth_ddl_lock = @import("security/auth_ddl_lock.zig");
    // SONNY-6586: the per-graph grant rule (online GRANT and offline geode grant).
    pub const graph_grant_rules = @import("security/graph_grant_rules.zig");
    // GPS Phase 5 (Task 5-4): minimal expression compiler for GPS policy predicates.
    pub const policy_expression = @import("security/policy_expression.zig");
    // GPS Phase 6 (Task 6-1): global monotonic policy version counter for cache invalidation.
    pub const policy_version = @import("security/policy_version.zig");
    // GPS Phase 7 (Task 7-1): bounded LRU decision cache keyed by (auth_version, policy_version, action, resource_hash).
    pub const decision_cache = @import("security/decision_cache.zig");
    // NOTE: policy_persistence.zig is NOT exported from lib.zig because it imports
    // auth_graph_manager, which imports geode (circular).  Consumers that need it
    // (server_init.zig, tests) import it as a named build module ("policy_persistence").
};
// SONNY-6499: `fts_advanced` (src/fts/advanced.zig: analyzers, stemming,
// fuzzy, soundex, synonyms) and src/fts/bm25.zig were removed: nothing
// reached them and they did not compile (LanguageAnalyzer.analyze used the
// removed managed ArrayList API). Full-text search is fts-storage behind
// FullTextIndex (src/index/fulltext.zig), with the tokenizer in
// src/index/fts_tokenizer.zig.
pub const parallel_exec_stub = @import("execution/parallel.zig");
// GAP-0867 (2026-06-10): renamed from `cbo_api_stub` — the stub APIs were
// deleted; what remains (StatsRegistry, explainEstimateJSON) is real.
pub const cbo = @import("planner/cbo.zig");

// Distributed consensus primitives (Raft) for tests/benchmarks
// (Removed distributed.raft re-export to avoid duplicate module inclusion with separate distributed module import)

// (Note) Streaming and txn modules are added as separate build modules; tests import them directly as needed.

// Lightweight helper to carry parameter bindings across subsystems
pub const ParamBindings = struct {
    names: []const []const u8,
    values: []const eval.Value,
};

/// Construct an eval.Env from identifier bindings and optional ParamBindings.
/// Requires an allocator for the Env's memory-management hooks (value_types.Env
/// added a `.allocator` field for GAP / C4 ownership tracking — see
/// src/value_types.zig:147).
pub fn makeEnv(allocator: std.mem.Allocator, id_names: []const []const u8, id_values: []const eval.Value, params: ?ParamBindings) eval.Env {
    if (params) |p| {
        return .{
            .names = id_names,
            .values = id_values,
            .param_names = p.names,
            .param_values = p.values,
            .allocator = allocator,
        };
    }
    return .{ .names = id_names, .values = id_values, .allocator = allocator };
}

/// Server functionality for library mode embedding
/// GAP-0122 FIX: Added clear documentation and recommended patterns for embedding use cases
// CANARY: REQ=REQ-LIBRARY-EMBEDDING-001; FEATURE="LibraryModeEmbedding"; ASPECT=ML; STATUS=TESTED; OWNER=library; UPDATED=2026-01-12
///
/// ## Library Mode Embedding Guide
///
/// Geode can be embedded in applications in two supported modes — query-only
/// (in-process) and client (talking to a separate server over QUIC). Hosting an
/// in-process server is NOT supported (see the GAP-0857 note below).
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
/// ### Embedded server mode is NOT supported (GAP-0857)
/// The library does not expose an in-process server runner. Running a server
/// requires the full QUIC + TLS transport stack, which is intentionally kept out
/// of the library interface so embedders do not inherit those dependencies.
/// `server.runServerWithArgs()` therefore always fails with the documented
/// `server.EmbeddingError.EmbeddedServerUnsupported` error and never starts a
/// server. To run a server, use one of the supported alternatives instead:
///   1. Subprocess: spawn the `geode serve` binary as a managed child process
///      and talk to it over QUIC (see Client Mode above).
///   2. CLI module: link the `geode` CLI entry point directly in an application
///      that is willing to pull in the full transport stack.
///   3. Query-only mode: for in-process needs that do not require a network
///      server, use `geode.parse()` / `geode.execute()` directly (see above).
///
/// See docs/API_REFERENCE.md for complete embedding examples.
pub const server = struct {
    /// Server embedding error types.
    pub const EmbeddingError = error{
        /// The library cannot host an in-process server: the QUIC+TLS transport
        /// stack is not exposed through the library interface. Returned by
        /// `runServerWithArgs`. The error name is part of the public contract —
        /// callers may branch on it to fall back to a supported alternative
        /// (subprocess `geode serve`, the CLI module, or query-only mode).
        EmbeddedServerUnsupported,
        /// Server initialization failed.
        InitializationFailed,
    };

    /// Embedded server mode is not supported by the library (GAP-0857).
    ///
    /// This function NEVER starts a server. It always returns
    /// `EmbeddingError.EmbeddedServerUnsupported`. Use a supported alternative:
    ///   1. Subprocess: spawn the `geode serve` binary as a managed child process.
    ///   2. CLI module: link the `geode` CLI entry point directly.
    ///   3. Query-only mode: use `geode.parse()` and `geode.execute()` in-process.
    ///
    /// `isServerModeAvailable()` returns `false` so callers can detect this
    /// without triggering the error.
    pub fn runServerWithArgs(allocator: std.mem.Allocator, args: [][:0]u8) EmbeddingError!void {
        _ = allocator;
        _ = args;
        return EmbeddingError.EmbeddedServerUnsupported;
    }

    /// Whether the library can host an in-process server. Always `false`: see
    /// `runServerWithArgs` and the GAP-0857 note above for supported alternatives.
    pub fn isServerModeAvailable() bool {
        return false;
    }

    /// Get the recommended embedding pattern for a given use case. Embedded
    /// server hosting is not offered; the `embedded_server` case points at the
    /// supported subprocess alternative.
    pub fn getRecommendedPattern(use_case: EmbeddingUseCase) []const u8 {
        return switch (use_case) {
            .local_queries => "Query-only mode: Use parse() and execute() directly",
            .distributed_queries => "Client mode: Connect to geode server via QUIC",
            .embedded_server => "Embedded server unsupported: spawn 'geode serve' as a subprocess instead",
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

// CANARY: REQ=REQ-SONNY-6351-PARSE-GQL-DEFAULT; FEATURE="Pagination Legality (US001)"; ASPECT=EmbeddedOrderKeyDefault; STATUS=TESTED; TEST=tests/test_sonny6351_labels_parse_default.zig; OWNER=planner; UPDATED=2026-11-12
/// Parse `src` with the server's default ORDER BY key policy: a sort key is
/// any value expression (ISO/IEC 39075:2024 16.16 <order by clause>).
/// `GEODE_ORDER_KEYS_EXPR` set to anything but empty, `1`, `true` or `on`
/// selects the opt-in identifier-only policy, read as the server reads it
/// (`server_init.zig`). SONNY-6351 item 3: the embedded default was the
/// identifier-only policy unless the variable was set (to any value), so
/// `ORDER BY n.prop` was a syntax error to an embedded caller and accepted by
/// the server.
pub fn parseGql(src: []const u8, allocator: std.mem.Allocator) !ParseResult {
    const allow_expr = if (getEnvVarOwned(allocator, "GEODE_ORDER_KEYS_EXPR")) |v| blk: {
        defer allocator.free(v);
        break :blk v.len == 0 or std.ascii.eqlIgnoreCase(v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "on");
    } else |_| true;
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
    Err: struct {
        msg: []const u8,
        line: u32,
        column: u32,
        token: @import("gql_lib").token.TokenKind,
        has_double_dash_comment: bool,
        has_unwind: bool = false,
        /// SQLSTATE for the refusal (`parseErrorCode`): 42000 for a syntax
        /// error, 54000 / 54001 for a parser limit (SONNY-3190, SONNY-3244).
        code: []const u8 = "42000",
        // Outer allocator that owns `msg`. Set when `parseGqlOutcome`
        // duped the message out of the (now-freed) parser arena;
        // null when `msg` is a static literal.
        msg_allocator: ?std.mem.Allocator = null,
    },

    /// Free any memory owned by this outcome. Safe to call on both
    /// variants. Mirrors `ParseResult.deinit`.
    pub fn deinit(self: *ParseOutcome) void {
        switch (self.*) {
            .Ok => |*ok| ok.deinit(),
            .Err => |*err| {
                if (err.msg_allocator) |a| a.free(err.msg);
                err.msg_allocator = null;
            },
        }
    }
};

// CANARY: REQ=REQ-SONNY-3244-PARSE-LIMITS; FEATURE="ParseLimits"; ASPECT=WireCode; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=parser; UPDATED=2026-09-28
/// SONNY-3244: the SQLSTATE a transport answers a refused parse with. A
/// parser limit is class 54 (program limit exceeded): too many write clauses
/// in a part (SONNY-3190), too many statements in a request, or more parser
/// memory than the request may take are 54000; queries nested too deep are
/// 54001 (statement too complex). An undirected edge pattern is 0A000
/// (feature not supported, SONNY-6433). Every other refusal is a syntax
/// error, 42000. The limits' own messages name them (`Parser.max_*`).
pub fn parseErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.TooManyWriteClauses, error.TooManyStatements, error.ParseMemoryLimit => "54000",
        error.QueryNestingTooDeep => "54001",
        // SONNY-6433: an undirected edge pattern (Feature GH02) is a feature
        // Geode does not support, not a syntax error.
        error.UndirectedEdgeNotSupported => "0A000",
        // SONNY-6343: a query shape the parser refuses as unsupported (a
        // NEXT with no result table to continue from, an inline CALL form);
        // the parser's message names it.
        error.UnsupportedQueryShape => "0A000",
        else => "42000",
    };
}

// Parse but capture parser error details instead of throwing; allocation errors still throw.
// CANARY: REQ=REQ-SONNY-6543-PARSE-REFUSAL-STATUS; FEATURE="GQLStatus"; ASPECT=CliParseRefusalCode; STATUS=TESTED; TEST=tests/conformance_tests.zig; OWNER=parser; UPDATED=2026-11-16
/// SONNY-6543: the GQL status a parse refusal is reported with outside the
/// wire (the gql CLI's JSON diagnostic): the refusal's own SQLSTATE (`code`:
/// 42000 for a syntax error, 54000 / 54001 for a parser limit), the code the
/// QUIC and gRPC front ends send, with its message, position and token. The
/// CLI reported every refusal with the gql library's `syntaxError` code,
/// 42601 before gql v0.1.22.
pub fn parseErrorStatus(pe: @FieldType(ParseOutcome, "Err")) gql.status.GqlStatus {
    var st = gql.status.syntaxError(pe.msg, pe.line, pe.column, @tagName(pe.token));
    if (pe.code.len == st.sqlstate.len) @memcpy(&st.sqlstate, pe.code);
    return st;
}

pub fn parseGqlOutcome(src: []const u8, allocator: std.mem.Allocator, opts: ParseOptions) !ParseOutcome {
    var arena = std.heap.ArenaAllocator.init(allocator);
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next(), .strict_order_keys = opts.strict_order_keys, .ident_order_only = opts.ident_order_only, .forbid_orderby_calls = opts.forbid_orderby_calls, .forbid_orderby_paths = opts.forbid_orderby_paths, .ts_extensions = opts.ts_extensions };
    const program = p.parseProgram() catch |parse_err| {
        // CANARY: REQ=REQ-SONNY-6517-PARSE-OOM; FEATURE="ParserErrors"; ASPECT=OutOfMemoryIdentity; STATUS=TESTED; TEST=tests/test_sonny6517_parse_oom.zig; OWNER=parser; UPDATED=2026-11-13
        // SONNY-6517 item 1: an allocation failure is OutOfMemory for the
        // caller (a server answers it as one; the LSP fails the request),
        // never a refused statement: `parseErrorCode` gave it 42000.
        if (parse_err == error.OutOfMemory) {
            arena.deinit();
            return error.OutOfMemory;
        }
        const raw_msg = p.last_error orelse "parse error";
        const loc = p.cur.loc;
        const kind = p.cur.kind;
        const has_dd = lx.has_double_dash_comment;
        const has_uw = p.has_unwind;
        // CRITICAL: dupe msg to the OUTER allocator BEFORE arena.deinit().
        // The parser's `last_error` is allocated via
        // `self.arena.allocator()` (see Parser.expect / unexpected), so
        // freeing the arena while returning a slice into it produces a
        // use-after-free that segfaults the moment the caller reads
        // `msg` (e.g. LSP provideDiagnostics doing
        // `try allocator.dupe(u8, err_info.msg)`).
        const has_dynamic_msg = p.last_error != null;
        const owned_msg: []const u8 = if (has_dynamic_msg)
            try allocator.dupe(u8, raw_msg)
        else
            raw_msg; // static literal "parse error" — safe across deinit.
        arena.deinit();
        return .{ .Err = .{
            .msg = owned_msg,
            .line = loc.line,
            .column = loc.column,
            .token = kind,
            .has_double_dash_comment = has_dd,
            .has_unwind = has_uw,
            .code = parseErrorCode(parse_err),
            .msg_allocator = if (has_dynamic_msg) allocator else null,
        } };
    };
    return .{ .Ok = .{ .program = program, .arena = arena, .last_error = p.last_error, .has_double_solidus_comment = lx.has_double_solidus_comment, .has_double_dash_comment = lx.has_double_dash_comment, .has_unwind = p.has_unwind } };
}

// CANARY: REQ=REQ-PERF-QPS-0810; FEATURE="ParseCacheWrapper"; ASPECT=PublicSurface; STATUS=TESTED; TEST=tests/test_gap0810_parse_cache_wrapper.zig; OWNER=performance; UPDATED=2026-04-20
// GAP-0810: re-export the server-side AST parse cache on the public `geode`
// module so in-process callers (benches, materialized-view refresh,
// distributed coordinator) can amortize the parser cost without reaching
// into `src/server/*` directly. Parser is ~100x more expensive than the
// planner per docs/performance/2026-04-20-query-bench/FINAL.md §6.
const query_ast_cache = @import("query_ast_cache");
pub const SharedAstCache = query_ast_cache.SharedAstCache;
pub const AstHandle = query_ast_cache.AstHandle;
pub const AstParseOutcome = query_ast_cache.AstParseOutcome;

/// Cached variant of `parseGqlOutcome`. Returns an `AstHandle` outcome whose
/// caller MUST call `.release()` on the `.Ok` payload; the underlying
/// `ParseResult` is owned by the cache and shared across callers for the
/// same `(query_text, opts)` key.
///
/// Rationale: the parser is ~100x more expensive than the planner. Any
/// in-process caller that executes the same query shape in a loop (bench
/// harness, materialized-view refresh, distributed coordinator) should use
/// this wrapper instead of `parseGqlOutcome` directly.
pub fn parseGqlCached(
    cache: *SharedAstCache,
    query_text: []const u8,
    opts: ParseOptions,
) !AstParseOutcome {
    return cache.getOrParse(query_text, opts);
}

// Re-export execution and graph_store for integration tests
pub const execution = @import("execution.zig");
/// The exact order and keys of numbers, durations and zoned times (SONNY-2675).
pub const value_order = @import("execution/value_order.zig");
pub const graph_store = @import("graph_store.zig");
// GAP (write-path OOM, 2026-07-04): legacy write-executor working-set budget —
// re-exported so tests can install tiny budgets via setBudgetBytesForTest.
pub const write_budget = @import("write_budget.zig");
// GAP-ENT-0044/0045 (T5): read-executor working-set budget + cancel-on-
// disconnect — re-exported for the budget/cancel regression tests.
pub const read_budget = @import("read_budget.zig");
// CANARY: REQ=REQ-AUTH-GRAPH-PERSIST-030; FEATURE="AuthDDLPersistence"; ASPECT=LibExport; STATUS=IMPL; OWNER=security; UPDATED=2026-05-12
// Re-export auth_dispatch so server_init can install callbacks without needing a
// separate module import (auth_dispatch is part of root_mod, not a standalone module).
pub const auth_dispatch = @import("execution/auth_dispatch.zig");
// CANARY: REQ=REQ-GPS-METADATA-001; FEATURE="GPS Metadata Isolation"; ASPECT=LibExportMetaDispatch; STATUS=TESTED; TEST=tests/test_gps_metadata_filtering.zig; OWNER=security; UPDATED=2026-05-20
// Re-export meta_dispatch so tests can call the executeDb*ForTest helpers without a
// relative cross-module @import (which Zig 0.16 rejects for files outside the module path).
pub const meta_dispatch = @import("execution/meta_dispatch.zig");
// CANARY: REQ=REQ-TDE-PROC-015; FEATURE="PerTenantTDEKeys"; ASPECT=LibExportStorageDispatch; STATUS=TESTED; TEST=tests/test_gap0843_tenant_tde.zig; OWNER=security; UPDATED=2026-06-08
// GAP-0843: re-export storage_dispatch so the page-encryption round-trip test can
// drive executeTde("tde.encrypt_page", ...) directly, and util/feature_flags so it
// can flip the TDE feature flag deterministically without mutating real env.
pub const storage_dispatch = @import("execution/storage_dispatch.zig");
// SONNY-6340: re-export audit_dispatch so the regression test drives the
// audit.* procedure handlers directly.
pub const audit_dispatch = @import("execution/audit_dispatch.zig");
pub const util_feature_flags = @import("feature_flags");
// CANARY: REQ=REQ-MULTI-TENANT-STRICT-001; FEATURE="StrictTenancyMode"; ASPECT=LibExport; STATUS=TESTED; TEST=tests/test_gap0840_strict_tenancy.zig; OWNER=security; UPDATED=2026-06-08
// GAP-0840: re-export the strict-tenancy decision module so server startup can
// set the process flag and integration tests can exercise resolveTenantFilter
// directly (the two tenant-filter entry points delegate to it).
pub const tenancy = @import("execution/tenancy.zig");
// CANARY: REQ=REQ-LSP-SCHEMA-PROVIDER-001; FEATURE="LspPermissionAwareCompletion"; ASPECT=LibExportSchemaChangeNotifier; STATUS=TESTED; TEST=src/cli/lsp/schema_provider_test.zig; OWNER=lsp; UPDATED=2026-05-14
// Re-export schema_change_notifier so the LSP SchemaProvider can reach it via
// the `geode` named module. Registering it as a separate build module would
// trigger Zig 0.16's "file exists in modules X and X0" diamond because
// execution.zig + auth_dispatch.zig already pull it via relative @import for
// the notify() call sites.
pub const schema_change_notifier = @import("execution/schema_change_notifier.zig");
pub const uuid = @import("uuid");
// CANARY: REQ=REQ-WAL-HOOKS-001; FEATURE="WAL Persistence Hooks"; ASPECT=LibExport; STATUS=TESTED; TEST=tests/test_wal.zig; OWNER=storage; UPDATED=2026-11-12
// Re-export the persistence-loop hooks for server initialization and tests
pub const wal = @import("wal.zig");
pub const fle_integration = @import("fle_integration.zig");
pub const fle_commands = @import("admin/fle_commands.zig");
pub const fle_key_manager = @import("fle_key_manager");
// SONNY-6442: the GEODE_MASTER_KEY check-value helper every FLE key path uses.
pub const fle_master_key_check = @import("keys/master_key_check.zig");
pub const fle_key_types = @import("fle_key_types");

// User management and authentication
pub const user_management = @import("security/user_management.zig");
pub const api_keys = @import("auth_lib").api_keys;
pub const mtls_provider = @import("security/mtls_provider.zig");
// CANARY: REQ=REQ-LSP-AUTH-GATE-001; FEATURE="LspPermissionAwareCompletion"; ASPECT=LibExportAuthn; STATUS=IMPL; OWNER=lsp; UPDATED=2026-05-23
//
// `security/authn.zig` is the unified AuthProvider chain.  It already
// compiles against Zig 0.16 via the `compat_fillRandom` /
// `compat_*Timestamp` shims at the top of authn.zig (landed in commit
// bd5b8c52, 2026-05-22) — and is re-exported as
// `geode.security.authn` at line 447 above.  Note for future
// readers: the LSP path reaches it through the
// `lsp_auth.verifierFromAuthProvider` adapter (cli/lsp/auth.zig).  The
// embedded-TCP listener in `geode serve` now bootstraps a process-global
// AuthProvider and installs the adapter so embedded LSP clients can
// authenticate against the same store the QUIC handler uses (Task 28
// of docs/superpowers/plans/2026-05-14-lsp-permission-aware-completion.md).
// Stdio LSP remains fail-closed by default; `--no-auth` opts out for
// development workflows.

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

// Quality #733 (2026-06-11): test-reference root for the hot-path inline
// test backfill. Zig 0.16 only discovers `test` decls in the test ROOT file
// plus files referenced from analyzed test blocks — a plain runtime
// `@import` does NOT pull inline tests in (same rationale as the
// `test { _ = ts_call_handlers; }` block in src/eval.zig). The block is
// NAMED with the "#733" prefix so the `zig build test-quality733` filter
// keeps it analyzed; without the name it would be filtered out and the
// imports below would never enter test discovery.
test "#733 hot-path inline test roots" {
    _ = @import("gql/parser.zig");
    _ = @import("execution.zig");
    _ = @import("execution/match_operations.zig");
}

// SONNY-2689: the same kind of root for src/execution/tenant_visibility.zig's
// inline tests, run by `zig build test-tenant-visibility` and the aggregate.
// Its name carries that step's "tenant_visibility:" filter prefix, so the
// filter keeps it analyzed and the import below enters test discovery.
test "tenant_visibility: inline test root" {
    _ = @import("execution/tenant_visibility.zig");
}

// SONNY-2799: the undo log's inline tests (src/txn_undo_log.zig) entered no
// test binary. Named so `zig build test-txn-undo-log-inline` (filters "undo
// log", "savepoint") keeps this block, and with it the file, in discovery.
test "SONNY-2799 undo log inline test roots" {
    _ = @import("txn_undo_log.zig");
}

// SONNY-6342: src/security/authn.zig's AuthProvider inline tests entered no
// test binary (one leaked its API-key result). Named with the
// "AuthProvider:" filter of `zig build test-sonny6342-authn-inline`, so the
// filter keeps this block, and with it the file, in discovery.
test "SONNY-6342 AuthProvider: authn inline test root" {
    _ = @import("security/authn.zig");
}

// SONNY-6460: src/exec.zig's inline tests entered no test binary. Named with
// the "exec.zig:" filter of `zig build test-sonny6460-exec-inline`, so the
// filter keeps this block, and with it the file, in discovery.
test "exec.zig: inline test root" {
    _ = @import("exec.zig");
}

// SONNY-6494: src/gql/recommendations.zig's inline tests entered no test
// binary. Named with the "recommendations:" filter of `zig build
// test-sonny6494-recommendations-inline`, so the filter keeps this block,
// and with it the file, in discovery.
test "recommendations: inline test root" {
    _ = @import("gql/recommendations.zig");
}

// SONNY-6494: src/client/repl/repl_dispatch.zig's inline tests did not
// compile on Zig 0.16, and they and repl_parse.zig's ("repl_parse:")
// entered no test binary. Named with the "repl_dispatch:" filter of
// `zig build test-sonny6494-inline`.
test "repl_dispatch: inline test root" {
    _ = @import("client/repl/repl_dispatch.zig");
    _ = @import("client/repl/repl_parse.zig");
}

// SONNY-6494: files of the geode module whose inline tests no step ran (the
// lib-module steps filter to other names). Named with the "sonny6494-lib:"
// filter of `zig build test-sonny6494-lib-inline`, which also names each
// file's tests by their fully qualified prefix (`<path>.test.`).
// SONNY-6511: the inline tests of geode-module files that did not compile
// on Zig 0.16 (or ran in no step) and whose code is live or reached by a
// running test. Named with the "sonny6511-lib:" filter of
// `zig build test-sonny6511-lib-inline`, which also names each file's tests
// by their fully qualified prefix (`<path>.test.`).
test "sonny6511-lib: inline test roots" {
    _ = @import("security/multi_graph_security.zig");
    _ = @import("client/quic_query_runner.zig");
    _ = @import("client/repl/spinner.zig");
    _ = @import("performance/memory_mapped_io.zig");
    _ = @import("ml/graph_embeddings.zig");
    _ = @import("graph/containers/lfu.zig");
    // SONNY-6517 item 3: the planner's own inline tests.
    _ = @import("planner.zig");
}

test "sonny6494-lib: inline test roots" {
    _ = @import("client/repl/repl_errors.zig");
    _ = @import("client/repl/repl_history.zig");
    _ = @import("client/repl/repl_render.zig");
    _ = @import("client/query_scope.zig");
    _ = @import("transport/connection_manager.zig");
    _ = @import("gql/confusable_check.zig");
    _ = @import("types/numeric_promotion.zig");
    _ = @import("unicode/confusables.zig");
    _ = @import("algorithms/drr.zig");
    _ = @import("algorithms/congestion_newreno.zig");
    _ = @import("algorithms/loss_recovery.zig");
    _ = @import("algorithms/timer_heap.zig");
    _ = @import("algorithms/sharding.zig");
    _ = @import("client/repl/line_text.zig");
    _ = @import("distributed/distributed_explain.zig");
    _ = @import("protocol.zig");
    _ = @import("optimizer/advanced_types_optimizer.zig");
    _ = @import("server/server_flags.zig");
    _ = @import("execution/bulk_ingest.zig");
    _ = @import("net_policy.zig");
    _ = @import("gpu/flagger.zig");
    _ = @import("admin/fle_commands.zig");
    _ = @import("planner/cost_seed.zig");
    _ = @import("planner/gpu_ops.zig");
    _ = @import("planner/calibration.zig");
    _ = @import("log/logger.zig");
    _ = @import("security/key_rotation.zig");
    _ = @import("pagination/calibration.zig");
}
