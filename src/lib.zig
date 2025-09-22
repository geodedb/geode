const std = @import("std");
const Lexer = @import("gql/lexer.zig").Lexer;
const Parser = @import("gql/parser.zig").Parser;
pub const ast = @import("gql/ast.zig");

pub const ParseResult = struct {
    program: ast.Program,
    arena: std.heap.ArenaAllocator,
    last_error: ?[]const u8 = null,

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

// Re-export printer module so binaries can import through the geode module
pub const printer = @import("gql/print.zig");
// Re-export conformance profile helpers for CLI/tools
pub const conformance = @import("conformance.zig");
// Re-export selected runtime helpers so binaries can import via the geode package
pub const exec = @import("exec.zig");
pub const planner = @import("planner.zig");
pub const temporal = @import("temporal.zig");
// Re-export evaluator for expression tests and demos
pub const eval = @import("eval.zig");
pub const diagnostics = @import("diagnostics.zig");
// Benchmark modules (variance envelopes)
pub const benchmarks = struct {
    // Pagination ordered variance benchmark (exposed for variance runner)
    pub const pagination = @import("benchmarks/pagination_variance.zig");
    // Pagination execution (streaming page) variance benchmark
    pub const pagination_execution = @import("benchmarks/pagination_execution_variance.zig");
};
// Time-series module (initial in-memory scaffold)
pub const timeseries = @import("timeseries/timeseries.zig");
// Re-export storage submodules needed across server modules (CSR adjacency)
pub const storage = struct {
    // Note: CSR is available to the server binary via build.zig module injection; tests import it directly.
    pub const csr = @import("storage/csr_adjacency.zig");
    // pub const constraints = @import("storage/constraints.zig");
};

// Re-export wire protocol definitions for tests/benchmarks needing Value / frame types

// Graph analytics (lightweight builders and centrality algorithms)
pub const graph = struct {
    pub const builders = @import("graph/builders.zig");
    pub const pagerank = @import("graph/centrality_pagerank.zig");
    pub const eigenvector = @import("graph/centrality_eigenvector.zig");
    pub const betweenness = @import("graph/centrality_betweenness.zig");
    pub const closeness = @import("graph/centrality_closeness.zig");
    pub const bridge_leverage = @import("graph/centrality_bridge_leverage.zig");
    pub const grey_cardinal = @import("graph/centrality_grey_cardinal.zig");
    pub const dfs_iterative = @import("graph/traversal_dfs_iterative.zig");
    pub const iddfs = @import("graph/traversal_iddfs.zig");
    pub const topo_kahn = @import("graph/topological_sort_kahn.zig");
    pub const topo_dfs = @import("graph/topological_sort_dfs.zig");
    pub const cycle_directed = @import("graph/cycle_detect_directed.zig");
    pub const cycle_undirected = @import("graph/cycle_detect_undirected.zig");
    pub const dag_shortest = @import("graph/shortest_dag_path.zig");
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

// Distributed consensus primitives (Raft) for tests/benchmarks
pub const distributed = struct {
    pub const raft = @import("distributed/raft_consensus.zig");
};

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

pub fn parseGql(src: []const u8, allocator: std.mem.Allocator) !ParseResult {
    return parseGqlOptions(src, allocator, .{});
}

pub fn parseGqlOptions(src: []const u8, allocator: std.mem.Allocator, opts: ParseOptions) !ParseResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next(), .strict_order_keys = opts.strict_order_keys, .ident_order_only = opts.ident_order_only, .forbid_orderby_calls = opts.forbid_orderby_calls, .forbid_orderby_paths = opts.forbid_orderby_paths, .ts_extensions = opts.ts_extensions };
    const program = try p.parseProgram();
    return .{ .program = program, .arena = arena, .last_error = p.last_error };
}

pub const ParseOutcome = union(enum) {
    Ok: ParseResult,
    Err: struct { msg: []const u8, line: u32, column: u32, token: @import("gql/token.zig").TokenKind },
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
        arena.deinit();
        return .{ .Err = .{ .msg = msg, .line = loc.line, .column = loc.column, .token = kind } };
    };
    return .{ .Ok = .{ .program = program, .arena = arena, .last_error = p.last_error } };
}

test "lib.parseGql basic" {
    const ally = std.testing.allocator;
    var res = try parseGql("MATCH (a)-[r]->(b) RETURN a", ally);
    defer res.deinit();
    try std.testing.expect(res.program.statements.len == 1);
}
