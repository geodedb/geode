// CANARY: REQ=REQ-LSP-CALLER-IDENTITY-001; FEATURE="LspCallerIdentity"; ASPECT=LeakRegression; STATUS=TESTED; TEST=tests/test_gap0818_lsp_context.zig:1; OWNER=lsp; UPDATED=2026-06-09
//
// GAP-0818 leak regression: LSP feature providers must enforce the
// caller's tenant identity so that one tenant's completion / hover /
// definition request can never surface another tenant's schema
// (labels, edge types, properties).
//
// Setup: a single GraphStore holds nodes for two tenants:
//   - tenant-a: (:Alpha {a_prop})
//   - tenant-b: (:Beta  {b_prop})
//
// We build a SchemaProvider scoped to tenant-b (as the server would for
// a tenant-b session), then issue provider requests carrying an
// LspContext for tenant-a. The boundary check in the providers must
// refuse to serve tenant-b's schema to the tenant-a caller — completion
// must not list "Beta", and hover over "Beta" must not return the
// schema-derived label card.
//
// Before the fix the providers ignored caller identity entirely and
// served whatever the provided SchemaProvider held, leaking "Beta".

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const features = @import("lsp_features");
const Document = features.DocumentType;
const SchemaProvider = features.SchemaProviderType;
const LspContext = features.LspContext;
const protocol = features.Protocol;
const graph_store = geode.graph_store;
const user_management = geode.user_management;

fn makeDoc(uri: []const u8, text: []const u8) Document {
    return Document{ .uri = uri, .text = text, .version = 1, .allocator = testing.allocator };
}

/// Free completion items produced by the STATIC keyword/function/type/
/// procedure branches of `provideCompletion` (the denied-tenant fallback
/// path). The keyword / function / procedure branches `allocPrint` their
/// `detail`; the TYPE branch sets `detail` to a static string literal
/// (`"ISO GQL Type"` / `"Geode Type"` / `"Cypher Type"`), which must NOT
/// be freed. `insertText` is `allocPrint`'d on all four static branches
/// and never aliases `label` there, so it is always heap-owned.
fn freeStaticCompletionItems(alloc: std.mem.Allocator, items: []protocol.CompletionItem) void {
    for (items) |it| {
        if (it.detail) |d| {
            if (!isStaticTypeDetail(d)) alloc.free(d);
        }
        if (it.insertText) |t| {
            if (t.ptr != it.label.ptr) alloc.free(t);
        }
    }
    alloc.free(items);
}

fn isStaticTypeDetail(d: []const u8) bool {
    return std.mem.eql(u8, d, "ISO GQL Type") or
        std.mem.eql(u8, d, "Geode Type") or
        std.mem.eql(u8, d, "Cypher Type");
}

/// Free completion items produced by the SCHEMA label branch, where
/// `detail` is a static string literal (not freed) and `insertText`
/// aliases the borrowed `label` slice. Matches the cleanup the existing
/// `provideCompletion offers labels after (n:` test in features_test.zig
/// uses (a bare `alloc.free(items)`).
fn freeSchemaCompletionItems(alloc: std.mem.Allocator, items: []protocol.CompletionItem) void {
    alloc.free(items);
}

test "GAP-0818 completion for tenant A does not leak tenant B labels" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();

    const default_graph: []const u8 = "default";
    _ = try store.createNodeWithGraphAndTenant(&.{"Alpha"}, default_graph, "tenant-a");
    _ = try store.createNodeWithGraphAndTenant(&.{"Beta"}, default_graph, "tenant-b");

    // SchemaProvider scoped to tenant-b (the "wrong" provider for an
    // tenant-a caller — simulates a mis-wired/reused provider).
    var sp_b = SchemaProvider.init(alloc, &store, .{
        .user = "bob",
        .tenant_id = "tenant-b",
        .role = user_management.Role.ReadOnly,
        .graph_name = default_graph,
    });
    defer sp_b.deinit();

    // tenant-a caller identity.
    const ctx_a = LspContext{ .tenant_id = "tenant-a", .user_id = "alice", .session_id = "sess-a" };

    // Completion in label position: "MATCH (n:" — kind == .label.
    var doc = makeDoc("file:///t.gql", "MATCH (n:");
    const items = try features.provideCompletion(alloc, &doc, 0, 9, &sp_b, ctx_a);
    defer freeStaticCompletionItems(alloc, items);

    // tenant-b's "Beta" label MUST NOT appear.
    for (items) |it| {
        try testing.expect(!std.mem.eql(u8, it.label, "Beta"));
    }
}

test "GAP-0818 hover for tenant A does not leak tenant B label card" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();

    const default_graph: []const u8 = "default";
    _ = try store.createNodeWithGraphAndTenant(&.{"Beta"}, default_graph, "tenant-b");

    var sp_b = SchemaProvider.init(alloc, &store, .{
        .user = "bob",
        .tenant_id = "tenant-b",
        .role = user_management.Role.ReadOnly,
        .graph_name = default_graph,
    });
    defer sp_b.deinit();

    const ctx_a = LspContext{ .tenant_id = "tenant-a", .user_id = "alice", .session_id = "sess-a" };

    // Hover over the word "Beta" — a tenant-b label. Since "Beta" is not
    // a static keyword/function/type/procedure either, the result must
    // be null (no schema card leaked).
    var doc = makeDoc("file:///t.gql", "MATCH (n:Beta)");
    const hover = try features.provideHover(alloc, &doc, 0, 10, &sp_b, ctx_a);
    if (hover) |h| {
        alloc.free(h.contents.value);
        try testing.expect(false); // should have been null
    }
}

test "GAP-0818 diagnostics for tenant A does not leak tenant B label in hint" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();

    const default_graph: []const u8 = "default";
    _ = try store.createNodeWithGraphAndTenant(&.{"Beta"}, default_graph, "tenant-b");

    // SchemaProvider scoped to tenant-b, but the diagnostics request below
    // carries a tenant-a caller. The tenant gate must null out the provider
    // so the "did you mean" hint can never echo tenant-b's "Beta" label.
    var sp_b = SchemaProvider.init(alloc, &store, .{
        .user = "bob",
        .tenant_id = "tenant-b",
        .role = user_management.Role.ReadOnly,
        .graph_name = default_graph,
    });
    defer sp_b.deinit();

    const ctx_a = LspContext{ .tenant_id = "tenant-a", .user_id = "alice", .session_id = "sess-a" };

    // "Beto" is Levenshtein-distance 1 from "Beta": without the tenant gate,
    // closestLabel would surface "Beta" in the hint, leaking the other
    // tenant's label name.
    var doc = makeDoc("file:///t.gql", "MATCH (n:Beto) RETURN n");
    const diags = try features.provideDiagnostics(alloc, &doc, &sp_b, ctx_a);
    defer {
        for (diags) |d| alloc.free(d.message);
        alloc.free(diags);
    }

    // No diagnostic may contain the tenant-B label name "Beta".
    for (diags) |d| {
        try testing.expect(std.mem.indexOf(u8, d.message, "Beta") == null);
    }
}

test "GAP-0818 matching tenant still gets its own schema" {
    const alloc = testing.allocator;
    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();

    const default_graph: []const u8 = "default";
    _ = try store.createNodeWithGraphAndTenant(&.{"Alpha"}, default_graph, "tenant-a");

    var sp_a = SchemaProvider.init(alloc, &store, .{
        .user = "alice",
        .tenant_id = "tenant-a",
        .role = user_management.Role.ReadOnly,
        .graph_name = default_graph,
    });
    defer sp_a.deinit();

    const ctx_a = LspContext{ .tenant_id = "tenant-a", .user_id = "alice", .session_id = "sess-a" };

    var doc = makeDoc("file:///t.gql", "MATCH (n:");
    const items = try features.provideCompletion(alloc, &doc, 0, 9, &sp_a, ctx_a);
    defer freeSchemaCompletionItems(alloc, items);

    var found = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "Alpha")) found = true;
    }
    try testing.expect(found);
}

test "GAP-0818 schemaTenantMatches gate" {
    // exact non-null match
    try testing.expect((LspContext{ .tenant_id = "t1" }).schemaTenantMatches("t1"));
    // non-null mismatch
    try testing.expect(!(LspContext{ .tenant_id = "t1" }).schemaTenantMatches("t2"));
    // caller tenant set, schema null -> deny
    try testing.expect(!(LspContext{ .tenant_id = "t1" }).schemaTenantMatches(null));
    // caller null, schema null -> single-tenant allow
    try testing.expect((LspContext{}).schemaTenantMatches(null));
    // caller null, schema set -> deny (don't serve a tenant's data to anon)
    try testing.expect(!(LspContext{}).schemaTenantMatches("t1"));
}

test "GAP-0818 definition is tenant-independent variable lookup" {
    const alloc = testing.allocator;
    const ctx_a = LspContext{ .tenant_id = "tenant-a", .user_id = "alice", .session_id = "sess-a" };
    // Definition resolves an in-document variable; it carries the context
    // for audit/telemetry parity but does not consult tenant schema.
    var doc = makeDoc("file:///t.gql", "MATCH (n:Alpha) RETURN n");
    const loc = try features.provideDefinition(alloc, &doc, 0, 23, ctx_a);
    // `n` is defined at the pattern; a Location should resolve.
    try testing.expect(loc != null);
}
