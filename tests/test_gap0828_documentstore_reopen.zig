// GAP-0828: DocumentStore reopen/deinit leak regression.
//
// The LSP DocumentStore (`src/cli/lsp/document.zig`) owns one heap `*Document`
// per open URI; each Document owns duped `uri` and `text` slices. The reopen
// path (a `textDocument/didOpen` for a URI that is already open — which real
// editors do emit, e.g. on a reload-from-disk or a split-view re-open) must
// free the previous Document before installing the replacement, or the old
// `uri` + `text` + struct leak.
//
// Every test runs under `std.testing.allocator`, which fails the test if any
// allocation outlives the store. That is the regression guard: if the reopen
// path ever drops a Document on the floor again, these tests go red.
//
// CANARY: REQ=REQ-QUALITY-GAP-0828; FEATURE="DocumentStoreReopenNoLeak"; ASPECT=MemorySafety; STATUS=TESTED; OWNER=lsp; UPDATED=2026-06-09

const std = @import("std");
const testing = std.testing;
const document = @import("lsp_document");

test "GAP-0828: open -> close -> reopen same URI -> deinit leaves no leak" {
    const allocator = testing.allocator;

    var store = document.DocumentStore.init(allocator);
    defer store.deinit();

    const uri = "file:///reopen.gql";
    try store.open(uri, "MATCH (n) RETURN n", 1);
    store.close(uri);
    // Reopen after an explicit close — the canonical clean lifecycle.
    try store.open(uri, "MATCH (m) RETURN m", 2);

    const doc = store.get(uri) orelse return error.MissingDocument;
    try testing.expectEqualStrings("MATCH (m) RETURN m", doc.text);
    try testing.expectEqual(@as(i32, 2), doc.version);
    // No explicit close here — `store.deinit()` must free the live Document.
}

test "GAP-0828: reopen WITHOUT close (didOpen for an already-open URI) leaves no leak" {
    const allocator = testing.allocator;

    var store = document.DocumentStore.init(allocator);
    defer store.deinit();

    const uri = "file:///already-open.gql";
    // First didOpen.
    try store.open(uri, "first body", 1);
    // Second didOpen for the SAME URI without an intervening close — this is
    // the acknowledged leak scenario. The store must free the first Document
    // (uri + text + struct) before installing the second, otherwise the
    // testing allocator reports a leak at deinit.
    try store.open(uri, "second body replaces first", 2);

    const doc = store.get(uri) orelse return error.MissingDocument;
    try testing.expectEqualStrings("second body replaces first", doc.text);
    try testing.expectEqual(@as(i32, 2), doc.version);

    // Exactly one live document for the URI.
    try testing.expectEqual(@as(usize, 1), store.documents.count());
}

test "GAP-0828: many open/close cycles do not grow or leak" {
    const allocator = testing.allocator;

    var store = document.DocumentStore.init(allocator);
    defer store.deinit();

    const uri = "file:///churn.gql";
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        var buf: [64]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf, "body revision {d}", .{i});
        try store.open(uri, body, @intCast(i));
        // The store must never accumulate more than one entry for the URI.
        try testing.expectEqual(@as(usize, 1), store.documents.count());
        if (i % 2 == 0) store.close(uri);
    }
    // Whatever the final open/close parity, deinit must release everything.
}

test "GAP-0828: many distinct URIs open then bulk deinit leaves no leak" {
    const allocator = testing.allocator;

    var store = document.DocumentStore.init(allocator);
    defer store.deinit();

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var uri_buf: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&uri_buf, "file:///doc-{d}.gql", .{i});
        try store.open(uri, "RETURN 1", @intCast(i));
        // Reopen each one once, without closing, to exercise the replace path
        // across many distinct keys.
        try store.open(uri, "RETURN 2", @intCast(i + 1000));
    }

    try testing.expectEqual(@as(usize, 64), store.documents.count());
    // `store.deinit()` (deferred) frees all 64 live Documents — no leak.
}

test "GAP-0828: update after reopen does not leak the prior text" {
    const allocator = testing.allocator;

    var store = document.DocumentStore.init(allocator);
    defer store.deinit();

    const uri = "file:///update.gql";
    try store.open(uri, "v1", 1);
    try store.update(uri, "v2 longer body to force a distinct allocation", 2);
    // Reopen replaces the whole Document — must free the v2 text + uri.
    try store.open(uri, "v3 after reopen", 3);
    try store.update(uri, "v4", 4);

    const doc = store.get(uri) orelse return error.MissingDocument;
    try testing.expectEqualStrings("v4", doc.text);
    try testing.expectEqual(@as(i32, 4), doc.version);
}
