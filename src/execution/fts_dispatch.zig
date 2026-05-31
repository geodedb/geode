/// Full-Text Search Dispatch Module
///
/// Handles routing for the `geode.fts.*` procedure family. The single procedure
/// today is `geode.fts.search(index, query [, max])` which yields a `(node,
/// score)` binding table via the ISO/IEC 39075:2024 `CALL <proc>(args) YIELD …`
/// surface.
///
/// This REPLACES the prior (non-GQL) scalar `fulltext_search(...)` value
/// function that returned a `List` of `Map` records the caller had to `UNWIND`.
/// `UNWIND` is a Cypher construct, not ISO GQL — the standard exposes a row set
/// ONLY through `CALL … YIELD` (see `.migration/GQL-SPEC-set-return.md`). This
/// dispatcher returns an ordinary `ExecutionResult{ columns = {"node","score"},
/// rows }` that flows over the same in-process / QUIC / gRPC result encoder as
/// every other procedure — no client or transport change.
///
/// `node` is yielded as the node id (`Value.Int`). The FTS facade returns
/// `SearchResult{ doc_id: u64, score: f64 }` where `doc_id == node_id` by
/// construction; there is no allocator-free path from a procedure handler to
/// materialize a full Node value (the store node accessor needs a live read
/// snapshot the dispatcher does not own), so we yield the stable node id. A
/// consumer can bind it into a subsequent `MATCH (n) WHERE id(n) = node …`
/// pattern. The column is named `node` (not `node_id`) to match the
/// spec-recommended `YIELD node, score` surface.
const std = @import("std");
const ast = @import("../gql/ast.zig");
const graph_store = @import("../graph_store.zig");
const value_types = @import("../value_types.zig");

const execution = @import("../execution.zig");
const execution_helpers = @import("execution_helpers.zig");
const filterYieldColumns = execution_helpers.filterYieldColumns;
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;

const Value = value_types.Value;

/// Default cap on returned hits when the optional `max` argument is omitted.
const DEFAULT_MAX_RESULTS: usize = 100;

/// Execute a `geode.fts.*` procedure. Returns null if the procedure name is not
/// recognized by this dispatcher (the router falls through to UnknownProcedure).
///
/// `proc_name` is the ASCII-lowercased, dotted procedure name (e.g.
/// "geode.fts.search") produced by `procedure_registry.extractNormalizedProcName`.
pub fn execute(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    call_stmt: ast.CallProcedure,
    context: ExecutionContext,
) !?ExecutionResult {
    _ = context;
    if (std.mem.eql(u8, proc_name, "geode.fts.search")) {
        return try handleFtsSearch(allocator, call_stmt);
    }
    return null;
}

/// `geode.fts.search(index_name, query [, max])` → rows of `(node, score)`.
///
///   - arg[0] index_name : string literal (the named fulltext index)
///   - arg[1] query      : string literal (the search text)
///   - arg[2] max        : optional non-negative integer literal (default 100)
///
/// Errors:
///   - `error.InvalidArgs`  — wrong arity, missing args, or negative max.
///   - `error.TypeMismatch` — an argument was not the expected literal type.
///   - `error.Unsupported`  — the adapter/graph/index does not exist (a clear
///                            failure rather than a silent empty result, matching
///                            the prior scalar surface's contract).
fn handleFtsSearch(
    allocator: std.mem.Allocator,
    call_stmt: ast.CallProcedure,
) !ExecutionResult {
    const args = switch (call_stmt.procedure) {
        .Call => |call| call.args,
        else => return error.InvalidArgs,
    };
    if (args.len < 2 or args.len > 3) return error.InvalidArgs;

    const index_name = try literalString(args[0]);
    const query_text = try literalString(args[1]);

    var max_results: usize = DEFAULT_MAX_RESULTS;
    if (args.len == 3) {
        if (args[2].* != .Int) return error.TypeMismatch;
        const n = args[2].Int;
        if (n < 0) return error.InvalidArgs;
        max_results = @intCast(n);
    }

    // Resolve the named fulltext facade on the DEFAULT graph (mirrors the
    // resolver the prior scalar function used; the in-process / CLI graph has no
    // per-context graph dimension here). A missing adapter, graph, or index is a
    // hard failure so the client gets a clear error, not a silent empty set.
    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
    const facade = adapter.getFulltextIndexNamed(graph_store.DEFAULT_GRAPH_NAME, index_name) orelse
        return error.Unsupported;

    // FullTextIndex.search(query, max) → []SearchResult{ doc_id, score }.
    // OWNERSHIP: the facade allocates the returned slice with its OWN stored
    // allocator (`facade.allocator`, the global-store allocator — see
    // FullTextIndex.search: `self.allocator.alloc(SearchResult, n)`), NOT the
    // per-request `allocator` passed to this handler. It must therefore be freed
    // with `facade.allocator`; freeing it with the request allocator is an
    // invalid free that crashes over the wire (the request and global allocators
    // differ on the server; they only coincide in the in-process test harness).
    const hits = facade.search(query_text, max_results) catch return error.Unsupported;
    defer facade.allocator.free(hits);

    // Build the (node, score) binding table. Column names are dupe'd so they own
    // their lifetime alongside the result spine (matches algo_dispatch's
    // allocTwoColumns ownership; ExecutionResult.deinit frees columns + rows).
    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "node");
    columns[1] = try allocator.dupe(u8, "score");

    const rows = try allocator.alloc([]Value, hits.len);
    for (hits, 0..) |hit, i| {
        const row = try allocator.alloc(Value, 2);
        // FullTextIndex.SearchResult fields are `doc_id: u64` (== node id) and
        // `score: f64` (already widened from the engine's f32 in the facade).
        row[0] = Value{ .Int = @intCast(hit.doc_id) };
        row[1] = Value{ .Double = hit.score };
        rows[i] = row;
    }

    var result = ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };

    // Project the YIELD columns when present (e.g. `YIELD score` only). The
    // YIELD names must match the result columns case-insensitively; here the
    // canonical columns are `node` and `score`.
    if (call_stmt.yield_items) |yield_items| {
        result = try filterYieldColumns(allocator, result, yield_items);
    }
    return result;
}

/// Extract a string literal argument. Accepts the AST `.String` literal node
/// (the form a quoted GQL string parses to). Returns `error.TypeMismatch` for
/// any other expression kind.
fn literalString(expr: *const ast.Expr) ![]const u8 {
    return switch (expr.*) {
        .String => |s| s,
        else => error.TypeMismatch,
    };
}
