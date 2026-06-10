// CANARY: REQ=REQ-LSP-CALLER-IDENTITY-001; FEATURE="LspCallerIdentity"; ASPECT=VerifiedPrincipalGate; STATUS=TESTED; TEST=tests/test_gap0818_gate.zig:1; OWNER=lsp; UPDATED=2026-06-10
//
// GAP-0818 enforcement gate (security tracker: "MCP-LSP RLS pre-condition").
//
// The LSP tenant is CLIENT-ASSERTED (`initializeOptions.geode.tenant`) —
// token verification establishes the username/role but does NOT verify
// the asserted tenant (that derivation is the GAP-0818 residual). The
// enforcement gate this file pins is the weaker but mandatory
// pre-condition: when auth provides NO VERIFIED principal, the LSP must
// not serve tenant-scoped schema / RLS-filtered data — it serves only
// public/unscoped data or refuses outright.
//
// Three chokepoints, three pins:
//
//   1. `Server.callerContext()` — the identity every feature provider
//      (completion / hover / definition / diagnostics) enforces its
//      tenant gate against. For an UNVERIFIED AuthState it must
//      collapse to the anonymous stdio context (null tenant / user /
//      session), never echoing a client-asserted tenant. A null-tenant
//      caller only matches a null-tenant SchemaProvider
//      (`LspContext.schemaTenantMatches`), so tenant-scoped schema is
//      unreachable.
//
//   2. `Server.publishVerifiedState()` — the only place a per-session
//      SchemaProvider + ExecutionContext (both tenant-carrying) are
//      built. It must REFUSE an unverified AuthState so a future
//      caller/refactor cannot publish a tenant-scoped session that
//      never passed `AuthState.verify`.
//
//   3. The request gate (`isMethodAllowed`) — re-pinned here for the
//      data-serving methods so the refusal posture (-32002 before any
//      provider runs) stays load-bearing alongside the data gate.
//
// The MCP side of the bridge needs no code gate: the four MCP-LSP
// bridge tools (`validate`/`complete`/`hover`/`diagnostics`,
// src/mcp/lsp.zig) are static parser/metadata lookups that consult no
// SchemaProvider and no graph store, and the per-server MCP Principal
// is derived with `tenant_id = null` always
// (src/mcp/server.zig:deriveMcpPrincipal) — pinned by
// tests/test_gps_mcp_principal.zig. The data-bearing MCP tools
// (query/schema/...) proxy to the QUIC server, whose own auth applies.
//
// Build step: `zig build test-gap0818-gate`

const std = @import("std");
const testing = std.testing;
const lsp_server = @import("lsp_server");
const auth = lsp_server.auth_mod_export;
const features = lsp_server.features_mod;
const schema_provider_mod = lsp_server.schema_provider_mod_export;
const geode = @import("geode");
const graph_store = geode.graph_store;
const user_management = geode.user_management;

test "GAP-0818 gate: callerContext for an unverified principal exposes no tenant" {
    const alloc = testing.allocator;
    var srv = try lsp_server.Server.init(alloc);
    defer srv.deinit();

    // Simulate the state right after `fromInitializeOptions` parsed a
    // client-asserted tenant but BEFORE (or without) `verify` ever
    // succeeding. The data gate must not echo the asserted tenant.
    var st = auth.AuthState{
        .token = try alloc.dupe(u8, "never-verified-token"),
        .user = try alloc.dupe(u8, "mallory"),
        .tenant_id = try alloc.dupe(u8, "tenant-asserted"),
        .verified = false,
    };
    st.deriveSessionHandle();
    srv.auth = st; // Server.deinit releases it.

    const ctx = srv.callerContext();
    try testing.expect(ctx.tenant_id == null);
    try testing.expect(ctx.user_id == null);
    try testing.expect(ctx.session_id == null);
    // And the anonymous context can never match a tenant-scoped provider.
    try testing.expect(!ctx.schemaTenantMatches("tenant-asserted"));
}

test "GAP-0818 gate: callerContext for a verified principal carries its identity" {
    const alloc = testing.allocator;
    var srv = try lsp_server.Server.init(alloc);
    defer srv.deinit();

    var st = auth.AuthState{
        .token = try alloc.dupe(u8, "verified-token"),
        .user = try alloc.dupe(u8, "alice"),
        .tenant_id = try alloc.dupe(u8, "tenant-a"),
        .verified = true,
    };
    st.deriveSessionHandle();
    srv.auth = st;

    const ctx = srv.callerContext();
    try testing.expectEqualStrings("tenant-a", ctx.tenant_id.?);
    try testing.expectEqualStrings("alice", ctx.user_id.?);
    try testing.expect(ctx.session_id != null);
    try testing.expect(ctx.schemaTenantMatches("tenant-a"));
}

test "GAP-0818 gate: publishVerifiedState refuses an unverified principal" {
    const alloc = testing.allocator;
    var srv = try lsp_server.Server.init(alloc);
    defer srv.deinit();

    // Ownership note: publishVerifiedState takes ownership of `state`
    // and deinits it on its error path — no cleanup here.
    const st = auth.AuthState{
        .token = try alloc.dupe(u8, "never-verified-token"),
        .tenant_id = try alloc.dupe(u8, "tenant-asserted"),
        .verified = false,
    };
    try testing.expectError(auth.AuthError.InvalidToken, srv.publishVerifiedState(st));
    // No tenant-scoped session state may have been published.
    try testing.expect(srv.auth == null);
    try testing.expect(srv.schema == null);
    try testing.expect(srv.exec_context == null);
}

test "GAP-0818 gate: unverified session is refused at the request gate" {
    const alloc = testing.allocator;
    var srv = try lsp_server.Server.init(alloc);
    defer srv.deinit();

    var st = auth.AuthState{
        .token = try alloc.dupe(u8, "never-verified-token"),
        .tenant_id = try alloc.dupe(u8, "tenant-asserted"),
        .verified = false,
    };
    st.deriveSessionHandle();
    srv.auth = st;

    try testing.expect(!srv.isMethodAllowed("textDocument/completion"));
    try testing.expect(!srv.isMethodAllowed("textDocument/hover"));
    try testing.expect(!srv.isMethodAllowed("textDocument/definition"));
    try testing.expect(!srv.isMethodAllowed("textDocument/diagnostic"));
}

test "GAP-0818 gate: unverified principal end-to-end - tenant provider serves no tenant schema" {
    const alloc = testing.allocator;
    var srv = try lsp_server.Server.init(alloc);
    defer srv.deinit();

    var store = try graph_store.GraphStore.init(alloc);
    defer store.deinit();
    const default_graph: []const u8 = "default";
    _ = try store.createNodeWithGraphAndTenant(&.{"Beta"}, default_graph, "tenant-b");

    // A tenant-scoped provider exists (as the server would hold for a
    // verified tenant-b session)...
    var sp_b = schema_provider_mod.SchemaProvider.init(alloc, &store, .{
        .user = "bob",
        .tenant_id = "tenant-b",
        .role = user_management.Role.ReadOnly,
        .graph_name = default_graph,
    });
    defer sp_b.deinit();

    // ...but the caller's AuthState is unverified — even one asserting
    // tenant-b itself. The data gate collapses the context to anonymous,
    // and the provider tenant gate then refuses the tenant-b schema.
    var st = auth.AuthState{
        .token = try alloc.dupe(u8, "never-verified-token"),
        .user = try alloc.dupe(u8, "mallory"),
        .tenant_id = try alloc.dupe(u8, "tenant-b"),
        .verified = false,
    };
    st.deriveSessionHandle();
    srv.auth = st;
    const ctx = srv.callerContext();

    var doc = features.DocumentType{
        .uri = "file:///t.gql",
        .text = "MATCH (n:",
        .version = 1,
        .allocator = alloc,
    };
    const items = try features.provideCompletion(alloc, &doc, 0, 9, &sp_b, ctx);
    defer {
        // Denied-tenant fallback serves only the STATIC branches: keyword /
        // function / procedure `detail` strings are allocPrint'd; the TYPE
        // branch `detail` is a static literal and must not be freed.
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

    for (items) |it| {
        try testing.expect(!std.mem.eql(u8, it.label, "Beta"));
    }
}

fn isStaticTypeDetail(d: []const u8) bool {
    return std.mem.eql(u8, d, "ISO GQL Type") or
        std.mem.eql(u8, d, "Geode Type") or
        std.mem.eql(u8, d, "Cypher Type");
}
