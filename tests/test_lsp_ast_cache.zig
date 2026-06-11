// LSP-F-02 / #770 — per-document AST cache regression suite.
//
// Verifies the LSP AST cache keystone: parsing feature providers consult a
// per-session, per-document cache keyed by (uri, version, parse-options,
// text) instead of re-parsing the document on every request.
//
// Coverage:
//   - direct cache: miss → hit on the same (uri, version); pointer-stable
//     outcome; counters exposed via stats()
//   - version bump / text change → stale entry replaced (miss, re-parse)
//   - explicit invalidate() → re-parse
//   - bounded size with LRU eviction
//   - parse-ERROR outcomes are cached too (broken buffers are the common
//     mid-edit state and the most diagnostics-hammered)
//   - provider fallback: no active cache → caller-owned direct parse
//   - real server request path: two successive textDocument/definition
//     computations on the same doc version = 1 parse + 1 cache hit;
//     didChange driven through the real handleMessage notification path
//     invalidates and forces exactly one re-parse
//
// Note on the task's "two successive hovers" phrasing: `provideHover` is a
// metadata/schema lookup and never parses the document — the providers
// that parse are diagnostics, definition, and documentSymbols. The
// request-path dedup assertion below therefore drives definition (via the
// public `computeDefinition` helper, same provider path handleDefinition
// uses).
//
// Module wiring: like tests/test_lsp_embedded_e2e.zig, this file reaches
// the LSP through a single `lsp_server` named module rooted at
// src/cli/lsp/server.zig (Zig 0.16 forbids `@import("../src/...")` from a
// tests/ module root). `ast_cache` / `Document` / `Transport` are reached
// through server.zig's pub re-exports + `@TypeOf` on the transport field
// so no second module roots at any LSP source file.
//
// CANARY: REQ=REQ-LSP-AST-CACHE-001; FEATURE="LspAstCache"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_lsp_ast_cache.zig; OWNER=lsp; UPDATED=2026-06-11

const std = @import("std");
const testing = std.testing;
const lsp = @import("lsp_server");
const ast_cache = lsp.ast_cache;
const Document = ast_cache.Document;
const Server = lsp.Server;
const TransportT = @TypeOf(@as(Server, undefined).transport);

/// Noop-transport server: tests only assert on cache counters and
/// computed locations, never on wire bytes (and a stray LSP frame on
/// stdout corrupts the `zig build test --listen=-` runner pipe).
fn newServer(alloc: std.mem.Allocator) !Server {
    return try Server.initWithTransport(alloc, TransportT.initNoop(alloc), null, false);
}

test "LSP-F-02: miss then hit on same (uri, version), counters exposed" {
    const a = testing.allocator;
    var cache = ast_cache.LspAstCache.init(a, 4);
    defer cache.deinit();

    const doc = try Document.init(a, "file:///a.gql", "MATCH (n) RETURN n", 1);
    defer doc.deinit();

    const o1 = try cache.getOrParse(doc, .{});
    try testing.expect(o1.* == .Ok);
    var st = cache.stats();
    try testing.expectEqual(@as(u64, 0), st.hits);
    try testing.expectEqual(@as(u64, 1), st.misses);

    const o2 = try cache.getOrParse(doc, .{});
    // Same document version → the exact same cached outcome, no re-parse.
    try testing.expectEqual(o1, o2);
    st = cache.stats();
    try testing.expectEqual(@as(u64, 1), st.hits);
    try testing.expectEqual(@as(u64, 1), st.misses);
}

test "LSP-F-02: version/text change is a miss (stale entry replaced)" {
    const a = testing.allocator;
    var cache = ast_cache.LspAstCache.init(a, 4);
    defer cache.deinit();

    const doc = try Document.init(a, "file:///b.gql", "MATCH (n) RETURN n", 1);
    defer doc.deinit();

    _ = try cache.getOrParse(doc, .{});
    try doc.update("MATCH (m) RETURN m", 2);
    const o2 = try cache.getOrParse(doc, .{});
    try testing.expect(o2.* == .Ok);

    const st = cache.stats();
    try testing.expectEqual(@as(u64, 0), st.hits);
    try testing.expectEqual(@as(u64, 2), st.misses);
}

test "LSP-F-02: explicit invalidate forces re-parse" {
    const a = testing.allocator;
    var cache = ast_cache.LspAstCache.init(a, 4);
    defer cache.deinit();

    const doc = try Document.init(a, "file:///c.gql", "RETURN 1", 1);
    defer doc.deinit();

    _ = try cache.getOrParse(doc, .{});
    cache.invalidate(doc.uri);
    var st = cache.stats();
    try testing.expectEqual(@as(u64, 1), st.invalidations);

    _ = try cache.getOrParse(doc, .{});
    st = cache.stats();
    try testing.expectEqual(@as(u64, 2), st.misses);
    try testing.expectEqual(@as(u64, 0), st.hits);

    // Invalidating an unknown URI is a counted no-op-safe operation.
    cache.invalidate("file:///never-cached.gql");
    try testing.expectEqual(@as(u64, 1), cache.stats().invalidations);
}

test "LSP-F-02: bounded size evicts the least-recently-used entry" {
    const a = testing.allocator;
    var cache = ast_cache.LspAstCache.init(a, 2);
    defer cache.deinit();

    const doc_a = try Document.init(a, "file:///lru-a.gql", "RETURN 1", 1);
    defer doc_a.deinit();
    const doc_b = try Document.init(a, "file:///lru-b.gql", "RETURN 2", 1);
    defer doc_b.deinit();
    const doc_c = try Document.init(a, "file:///lru-c.gql", "RETURN 3", 1);
    defer doc_c.deinit();

    _ = try cache.getOrParse(doc_a, .{}); // tick 1
    _ = try cache.getOrParse(doc_b, .{}); // tick 2
    _ = try cache.getOrParse(doc_a, .{}); // tick 3 — A is now most recent
    _ = try cache.getOrParse(doc_c, .{}); // full → evicts LRU = B

    var st = cache.stats();
    try testing.expectEqual(@as(u64, 1), st.evictions);

    // A survived (hit); B was evicted (miss).
    _ = try cache.getOrParse(doc_a, .{});
    st = cache.stats();
    try testing.expectEqual(@as(u64, 2), st.hits);
    _ = try cache.getOrParse(doc_b, .{});
    st = cache.stats();
    try testing.expectEqual(@as(u64, 4), st.misses); // a, b, c, b-again
}

test "LSP-F-02: parse-error outcomes are cached (mid-edit hot path)" {
    const a = testing.allocator;
    var cache = ast_cache.LspAstCache.init(a, 4);
    defer cache.deinit();

    const doc = try Document.init(a, "file:///broken.gql", "MATCH (", 1);
    defer doc.deinit();

    const o1 = try cache.getOrParse(doc, .{});
    try testing.expect(o1.* == .Err);
    const o2 = try cache.getOrParse(doc, .{});
    try testing.expectEqual(o1, o2);

    const st = cache.stats();
    try testing.expectEqual(@as(u64, 1), st.hits);
    try testing.expectEqual(@as(u64, 1), st.misses);
}

test "LSP-F-02: parseDocument falls back to caller-owned parse with no active cache" {
    const a = testing.allocator;
    ast_cache.setActive(null);

    const doc = try Document.init(a, "file:///nocache.gql", "MATCH (n) RETURN n", 1);
    defer doc.deinit();

    var dp = try ast_cache.parseDocument(a, doc, .{});
    defer dp.deinit();
    try testing.expect(dp == .owned);
    try testing.expect(dp.outcome().* == .Ok);
}

test "LSP-F-02: parseDocument borrows from the active cache" {
    const a = testing.allocator;
    var cache = ast_cache.LspAstCache.init(a, 4);
    defer cache.deinit();
    ast_cache.setActive(&cache);
    defer ast_cache.setActive(null);

    const doc = try Document.init(a, "file:///active.gql", "MATCH (n) RETURN n", 1);
    defer doc.deinit();

    var dp1 = try ast_cache.parseDocument(a, doc, .{});
    defer dp1.deinit();
    try testing.expect(dp1 == .cached);
    var dp2 = try ast_cache.parseDocument(a, doc, .{});
    defer dp2.deinit();
    try testing.expect(dp2 == .cached);

    const st = cache.stats();
    try testing.expectEqual(@as(u64, 1), st.hits);
    try testing.expectEqual(@as(u64, 1), st.misses);
}

test "LSP-F-02: server path — repeat definition requests parse once; didChange invalidates" {
    const a = testing.allocator;
    var srv = try newServer(a);
    defer srv.deinit();

    const uri = "file:///server-cache.gql";
    const text = "MATCH (n) RETURN n";
    try srv.documents.open(uri, text, 1);

    // First request on (uri, v1): parses and populates the cache.
    const loc1 = try srv.computeDefinition(uri, 0, 17);
    try testing.expect(loc1 != null);
    var st = srv.ast_cache.stats();
    try testing.expectEqual(@as(u64, 1), st.misses);
    try testing.expectEqual(@as(u64, 0), st.hits);

    // Second request on the SAME doc version: cache hit, zero re-parse,
    // and an identical answer (correctness equivalence under caching).
    const loc2 = try srv.computeDefinition(uri, 0, 17);
    try testing.expect(loc2 != null);
    try testing.expectEqual(loc1.?.range.start.line, loc2.?.range.start.line);
    try testing.expectEqual(loc1.?.range.start.character, loc2.?.range.start.character);
    st = srv.ast_cache.stats();
    try testing.expectEqual(@as(u64, 1), st.misses);
    try testing.expectEqual(@as(u64, 1), st.hits);

    // didChange through the REAL notification path (handleMessage →
    // handleDidChange). Notifications are lifecycle-gated, not
    // auth-gated — flip the lifecycle flag the way a completed
    // `initialize` would.
    srv.initialize_received = true;
    const did_change =
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///server-cache.gql","version":2},"contentChanges":[{"text":"MATCH (m) RETURN m"}]}}
    ;
    try srv.handleMessage(did_change);
    st = srv.ast_cache.stats();
    try testing.expectEqual(@as(u64, 1), st.invalidations);

    // Next request re-parses the new content exactly once...
    const loc3 = try srv.computeDefinition(uri, 0, 17);
    try testing.expect(loc3 != null);
    st = srv.ast_cache.stats();
    try testing.expectEqual(@as(u64, 2), st.misses);
    try testing.expectEqual(@as(u64, 1), st.hits);

    // ...and the version-2 AST is served from cache thereafter.
    _ = try srv.computeDefinition(uri, 0, 17);
    st = srv.ast_cache.stats();
    try testing.expectEqual(@as(u64, 2), st.misses);
    try testing.expectEqual(@as(u64, 2), st.hits);
}

test "LSP-F-02: didClose through the real path frees the cached AST" {
    const a = testing.allocator;
    var srv = try newServer(a);
    defer srv.deinit();

    const uri = "file:///close-me.gql";
    try srv.documents.open(uri, "MATCH (n) RETURN n", 1);
    _ = try srv.computeDefinition(uri, 0, 17);
    try testing.expectEqual(@as(u64, 1), srv.ast_cache.stats().misses);

    srv.initialize_received = true;
    const did_close =
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///close-me.gql"}}}
    ;
    try srv.handleMessage(did_close);
    try testing.expectEqual(@as(u64, 1), srv.ast_cache.stats().invalidations);
    // testing.allocator's leak check at test exit proves the entry's
    // text copy + outcome were released.
}
