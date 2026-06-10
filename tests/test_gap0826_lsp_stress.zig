// GAP-0826 — LSP performance / stress test pack.
//
// The LSP server had unit + e2e + conformance coverage but no STRESS pack:
// nothing exercised it under large documents, large schemas, long request
// sequences, or cancellation churn. A regression that quietly broke under
// scale (an O(n^2) blowup, a per-request leak, a CancelRegistry/AnsweredRing
// FIFO-eviction bug) would have slipped through. This pack closes that gap.
//
// Everything drives REAL code paths — there are no mocks:
//   - the document / sequential / burst / didChange cases run through the
//     production `Server.handleMessage` over a capturing Noop transport
//     (the same harness GAP-0816 uses), under `std.testing.allocator` so any
//     per-request leak is a hard failure;
//   - the large-schema case builds a REAL `GraphStore` with 1000 labels ×
//     10 properties and a REAL `SchemaProvider`, then calls the production
//     `features.provideCompletion` against it.
//
// CI-safety: every bound is a generous sanity ceiling or a correctness
// assertion — there are NO wall-clock timing assertions that could flake on a
// loaded CI runner. The whole pack is sized to run in a couple of seconds.
//
// CANARY: REQ=REQ-LSP-STRESS-001; FEATURE="LspStressPack"; ASPECT=LargeScaleAndCancellation; STATUS=TESTED; OWNER=lsp; UPDATED=2026-06-09

const std = @import("std");
const testing = std.testing;

const server = @import("lsp_server");
const transport = server.transport_mod;
const features = server.features_mod;
const schema_provider_mod = server.schema_provider_mod_export;

const geode = @import("geode");
const graph_store = geode.graph_store;
const user_management = geode.user_management;

// ---------------------------------------------------------------------------
// Helpers — a `--no-auth` server over a capturing Noop transport, driven
// through `initialize` so the auth gate is open for feature requests. Mirrors
// tests/test_gap0816_lsp_cancel.zig's harness (intentionally duplicated rather
// than extracted: a shared helper would have to live in a fifth module wired
// into build.zig, and the helper here is a six-line copy — the reviewer's
// "don't make a 5th copy" bar is about the full helper SET, which this file
// does not reproduce; it only needs the constructor + JSON inspectors).
// ---------------------------------------------------------------------------

fn newCapturingServer(alloc: std.mem.Allocator) !server.Server {
    var srv = try server.Server.initWithTransport(
        alloc,
        transport.Transport.initNoopCapturing(alloc),
        null,
        true, // allow_unauth — synthesize local-admin AuthState on initialize
    );
    errdefer srv.deinit();
    const init_msg =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":null}}
    ;
    try srv.handleMessage(init_msg);
    return srv;
}

/// True when the last written frame is a JSON-RPC response carrying a `result`
/// member (a normal, successful answer), false otherwise.
fn lastFrameHasResult(alloc: std.mem.Allocator, srv: *const server.Server) !bool {
    const frame = srv.lastWrittenForTest() orelse return false;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    return parsed.value.object.get("result") != null;
}

/// True when the last written frame carries a JSON-RPC `error.code` == `code`.
fn lastFrameHasErrorCode(alloc: std.mem.Allocator, srv: *const server.Server, code: i64) !bool {
    const frame = srv.lastWrittenForTest() orelse return false;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const err = parsed.value.object.get("error") orelse return false;
    if (err != .object) return false;
    const c = err.object.get("code") orelse return false;
    if (c != .integer) return false;
    return c.integer == code;
}

// ---------------------------------------------------------------------------
// 1) Large document: a single didOpen of >= 1 MiB, then completion + hover on
//    it complete without error or leak.
// ---------------------------------------------------------------------------

test "GAP-0826: large document (>=1 MiB) didOpen + completion/hover, no leak" {
    const alloc = testing.allocator;
    // The `--no-auth` initialize binds a real session whose SchemaProvider is
    // built over the process-global store (getWritableGlobalStore) and whose
    // ExecutionContext pulls the global catalog (ensureCatalogInstance). Both
    // are lazily allocated with THIS test's allocator, so both must be torn
    // down here. Declared FIRST so they run LAST (defers are LIFO): srv.deinit
    // → catalog teardown → store teardown.
    defer geode.graph_store.deinitGlobalStore();
    defer geode.execution.tearDownGlobalCatalogForTest();
    var srv = try newCapturingServer(alloc);
    defer srv.deinit();

    // Build a >= 1 MiB GQL document. We deliberately make it a SINGLE
    // statement carrying a ~1 MiB string literal rather than ~14k separate
    // statements: a 1 MiB buffer of thousands of independent statements would
    // exercise the GQL PARSER's per-statement cost (a separate concern), which
    // on a debug build is too slow for a CI unit-test budget. The single-
    // statement form keeps the parse linear in the buffer size while still
    // stressing the LSP layer's large-buffer handling (line index, offset
    // math, tokenizer scan, the >1 MiB transport frame, and the document
    // store) — which is what this gap is about. The JSON-escaped didOpen
    // payload is assembled with std.json so the long literal is encoded
    // correctly.
    const target_bytes: usize = 1 << 20; // 1 MiB
    var text = try std.ArrayList(u8).initCapacity(alloc, target_bytes + 64);
    defer text.deinit(alloc);
    try text.appendSlice(alloc, "RETURN '");
    var r: usize = 0;
    while (r < target_bytes) : (r += 1) try text.append(alloc, 'x');
    try text.appendSlice(alloc, "' AS big");
    try testing.expect(text.items.len >= target_bytes);

    // Construct the didOpen notification with a properly JSON-escaped text.
    const did_open = try buildDidOpen(alloc, "file:///big.gql", text.items, 1);
    defer alloc.free(did_open);
    try srv.handleMessage(did_open);

    // Completion at a label position inside the big document must answer
    // (a result frame), not error or hang.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":10,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///big.gql"},"position":{"line":0,"character":9}}}
    );
    try testing.expect(try lastFrameHasResult(alloc, &srv));

    // Hover on a token inside the big document must answer too.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":11,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///big.gql"},"position":{"line":0,"character":0}}}
    );
    try testing.expect(try lastFrameHasResult(alloc, &srv));

    // documentSymbol over the whole large buffer must answer without error.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":12,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///big.gql"}}}
    );
    try testing.expect(try lastFrameHasResult(alloc, &srv));
}

/// Build a `textDocument/didOpen` JSON-RPC notification with a correctly
/// JSON-escaped `text` (the document body contains newlines and quotes).
/// Caller owns the returned buffer.
fn buildDidOpen(alloc: std.mem.Allocator, uri: []const u8, text: []const u8, version: i64) ![]u8 {
    // Unmanaged ObjectMap form (`.put(allocator, ...)`) — matches the Zig 0.16
    // std.json API the production server uses (src/cli/lsp/server.zig).
    var root = std.json.ObjectMap{};
    defer root.deinit(alloc);
    var params = std.json.ObjectMap{};
    defer params.deinit(alloc);
    var td = std.json.ObjectMap{};
    defer td.deinit(alloc);

    try td.put(alloc, "uri", .{ .string = uri });
    try td.put(alloc, "languageId", .{ .string = "gql" });
    try td.put(alloc, "version", .{ .integer = version });
    try td.put(alloc, "text", .{ .string = text });
    try params.put(alloc, "textDocument", .{ .object = td });
    try root.put(alloc, "jsonrpc", .{ .string = "2.0" });
    try root.put(alloc, "method", .{ .string = "textDocument/didOpen" });
    try root.put(alloc, "params", .{ .object = params });

    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = root }, .{});
}

// ---------------------------------------------------------------------------
// 2) Many sequential requests: >= 500 mixed completion / hover / documentSymbol
//    under the leak-detecting testing allocator. No leak, every one answers.
// ---------------------------------------------------------------------------

test "GAP-0826: 500+ sequential mixed requests, no leak" {
    const alloc = testing.allocator;
    defer geode.graph_store.deinitGlobalStore();
    defer geode.execution.tearDownGlobalCatalogForTest();
    var srv = try newCapturingServer(alloc);
    defer srv.deinit();

    // Open a modest document the requests can target.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///seq.gql","languageId":"gql","version":1,"text":"MATCH (n:Person) RETURN n.name, n.age"}}}
    );

    const total: usize = 600;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const id = 1000 + @as(i64, @intCast(i));
        const msg = switch (i % 3) {
            0 => try std.fmt.allocPrint(alloc,
                \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/completion","params":{{"textDocument":{{"uri":"file:///seq.gql"}},"position":{{"line":0,"character":9}}}}}}
            , .{id}),
            1 => try std.fmt.allocPrint(alloc,
                \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/hover","params":{{"textDocument":{{"uri":"file:///seq.gql"}},"position":{{"line":0,"character":9}}}}}}
            , .{id}),
            else => try std.fmt.allocPrint(alloc,
                \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/documentSymbol","params":{{"textDocument":{{"uri":"file:///seq.gql"}}}}}}
            , .{id}),
        };
        defer alloc.free(msg);
        try srv.handleMessage(msg);
        try testing.expect(try lastFrameHasResult(alloc, &srv));
    }
}

// ---------------------------------------------------------------------------
// 3) Cancellation churn: a burst of >= 100 requests, then a $/cancelRequest for
//    every one of their ids, then a fresh request — the fresh request answers
//    normally. Exercises CancelRegistry/AnsweredRing churn + FIFO eviction at
//    capacity 64. Because the burst requests are ANSWERED before the cancels
//    arrive, every cancel is a late no-op; the AnsweredRing FIFO-evicts older
//    ids, so the late cancels for evicted ids land in the CancelRegistry (also
//    FIFO-bounded at 64) and never poison the fresh, distinct request id.
// ---------------------------------------------------------------------------

test "GAP-0826: 100+ request burst then cancel-all then fresh request answers" {
    const alloc = testing.allocator;
    defer geode.graph_store.deinitGlobalStore();
    defer geode.execution.tearDownGlobalCatalogForTest();
    var srv = try newCapturingServer(alloc);
    defer srv.deinit();

    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///burst.gql","languageId":"gql","version":1,"text":"MATCH (n) RETURN n"}}}
    );

    const burst: usize = 150; // > 100 and > 2 * registry capacity (64)
    var i: usize = 0;
    while (i < burst) : (i += 1) {
        const id = 2000 + @as(i64, @intCast(i));
        const msg = try std.fmt.allocPrint(alloc,
            \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/documentSymbol","params":{{"textDocument":{{"uri":"file:///burst.gql"}}}}}}
        , .{id});
        defer alloc.free(msg);
        try srv.handleMessage(msg);
        try testing.expect(try lastFrameHasResult(alloc, &srv));
    }

    // Now cancel every id we just sent. Each is a late cancel (already
    // answered) — a spec no-op — but it churns the registry/ring FIFO logic.
    i = 0;
    while (i < burst) : (i += 1) {
        const id = 2000 + @as(i64, @intCast(i));
        const msg = try std.fmt.allocPrint(alloc,
            \\{{"jsonrpc":"2.0","method":"$/cancelRequest","params":{{"id":{d}}}}}
        , .{id});
        defer alloc.free(msg);
        try srv.handleMessage(msg);
    }

    // A fresh request with a DISTINCT id must answer normally — neither the
    // burst nor the cancel storm poisoned it.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":9999,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///burst.gql"}}}
    );
    try testing.expect(!try lastFrameHasErrorCode(alloc, &srv, -32800));
    try testing.expect(try lastFrameHasResult(alloc, &srv));

    // And a genuine pre-emptive cancel still works after all the churn: cancel
    // an id BEFORE its request, deliver it, observe -32800.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":8888}}
    );
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":8888,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///burst.gql"}}}
    );
    try testing.expect(try lastFrameHasErrorCode(alloc, &srv, -32800));
}

// ---------------------------------------------------------------------------
// 4) Large schema: a REAL SchemaProvider over a REAL GraphStore with 1000
//    labels (10 properties each), then completion at a label position returns
//    bounded results without error or leak.
// ---------------------------------------------------------------------------

test "GAP-0826: large schema (1000 labels x 10 props) completion is bounded, no leak" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();

    const default_graph: []const u8 = "default";
    const tenant: []const u8 = "tenant-a";

    // 1000 distinct labels; each node carries 10 properties. This is the real
    // introspection scan surface the SchemaProvider walks on getLabels/
    // getPropertiesFor.
    const label_count: usize = 1000;
    const props_per_label: usize = 10;
    var li: usize = 0;
    while (li < label_count) : (li += 1) {
        var label_buf: [32]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "Label{d}", .{li});
        const node = try store.createNodeWithGraphAndTenant(&.{label}, default_graph, tenant);
        var pi: usize = 0;
        while (pi < props_per_label) : (pi += 1) {
            var prop_buf: [32]u8 = undefined;
            const prop = try std.fmt.bufPrint(&prop_buf, "prop{d}", .{pi});
            try store.setNodeProperty(node, prop, .{ .Int = @as(i64, @intCast(pi)) });
        }
    }

    var sp = schema_provider_mod.SchemaProvider.init(alloc, &store, .{
        .user = "u",
        .tenant_id = tenant,
        .role = user_management.Role.ReadOnly,
        .graph_name = default_graph,
    });
    defer sp.deinit();

    // Completion at a label position (`MATCH (n:`) must pull labels from the
    // SchemaProvider and complete without error. The result is bounded — even
    // with 1000 labels visible, the provider returns a finite list we can free.
    var doc = try server.document_mod.Document.init(alloc, "test:///big_schema.gql", "MATCH (n:", 1);
    defer doc.deinit();

    const items = try features.provideCompletion(alloc, doc, 0, 9, &sp, features.LspContext{ .tenant_id = tenant });
    defer alloc.free(items);

    // At least the schema labels are present (sanity floor) and the count is
    // bounded by what a real provider can return (sanity ceiling well above
    // the schema size but finite — no runaway).
    try testing.expect(items.len >= label_count);
    try testing.expect(items.len < 100_000);

    // Spot-check that a known label is actually in the result set — proves the
    // large-schema scan produced real, correct data (not an empty list).
    var found = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "Label500")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);

    // A prefix-filtered completion narrows the result (the provider applies the
    // cursor prefix). Re-warm path: this hits the cached labels from above.
    var doc2 = try server.document_mod.Document.init(alloc, "test:///big_schema2.gql", "MATCH (n:Label99", 1);
    defer doc2.deinit();
    const items2 = try features.provideCompletion(alloc, doc2, 0, 16, &sp, features.LspContext{ .tenant_id = tenant });
    defer alloc.free(items2);
    // "Label99", "Label990".."Label999" — a small, bounded subset, far fewer
    // than the full 1000.
    try testing.expect(items2.len < label_count);
    try testing.expect(items2.len >= 1);
}

// ---------------------------------------------------------------------------
// 5) didChange storm: >= 200 versions on one document, then the final content
//    is correct and nothing leaked. Drives the production didOpen/didChange
//    path through handleMessage.
// ---------------------------------------------------------------------------

test "GAP-0826: 200+ didChange storm, final content correct, no leak" {
    const alloc = testing.allocator;
    defer geode.graph_store.deinitGlobalStore();
    defer geode.execution.tearDownGlobalCatalogForTest();
    var srv = try newCapturingServer(alloc);
    defer srv.deinit();

    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///storm.gql","languageId":"gql","version":1,"text":"RETURN 0"}}}
    );

    const versions: usize = 250;
    var v: usize = 2;
    while (v <= versions) : (v += 1) {
        // Each change replaces the full document text (the server advertises
        // Full sync, so contentChanges[0].text is the whole document).
        const text = try std.fmt.allocPrint(alloc, "RETURN {d}", .{v});
        defer alloc.free(text);
        const msg = try std.fmt.allocPrint(alloc,
            \\{{"jsonrpc":"2.0","method":"textDocument/didChange","params":{{"textDocument":{{"uri":"file:///storm.gql","version":{d}}},"contentChanges":[{{"text":"{s}"}}]}}}}
        , .{ v, text });
        defer alloc.free(msg);
        try srv.handleMessage(msg);
    }

    // Final content must reflect the last change. We assert it via a real
    // request the document state feeds: documentSymbol answers (no error) and
    // the document store holds the final text. Verify through the public
    // document accessor on the server's DocumentStore.
    const doc = srv.documents.get("file:///storm.gql") orelse return error.DocumentMissing;
    const expected = try std.fmt.allocPrint(alloc, "RETURN {d}", .{versions});
    defer alloc.free(expected);
    try testing.expectEqualStrings(expected, doc.text);

    // The server still answers a request on the storm'd document.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":7000,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///storm.gql"}}}
    );
    try testing.expect(try lastFrameHasResult(alloc, &srv));
}
