// CANARY: REQ=REQ-LSP-CALLER-IDENTITY-001; FEATURE="LspCallerIdentity"; ASPECT=ContextStruct; STATUS=TESTED; TEST=tests/test_gap0818_lsp_context.zig:"completion for tenant A does not leak tenant B labels"; OWNER=lsp; UPDATED=2026-06-09
//
// GAP-0818: caller identity threaded through the LSP feature providers.
//
// Prior to this gap, `provideCompletion` / `provideHover` /
// `provideDefinition` took a bare `*SchemaProvider` and trusted that
// the server had constructed it with the correct per-session tenant /
// user / role. The SchemaProvider DOES carry an
// `IntrospectionContext` (user / tenant / role / graph) and the storage
// layer (`graph_store.listNodeLabels(..., filter_tenant)`) is genuinely
// tenant-scoped — but nothing at the provider boundary asserted that the
// provider it was handed actually belongs to the caller making the
// request. A mis-wired or reused provider could surface another tenant's
// labels / properties through completion or hover.
//
// `LspContext` makes the caller identity explicit at the provider
// boundary and lets each provider enforce, as a defense-in-depth check,
// that the SchemaProvider it consults was built for the SAME tenant the
// request is for. When the tenants disagree the provider declines to
// serve schema-derived (tenant-scoped) results and falls back to the
// static, tenant-independent language metadata. This guarantees that
// even if the server hands a provider scoped to tenant B to a request
// from tenant A, tenant B's labels / edge types / properties never leak.
//
// Field nullability:
//   - `tenant_id`  — null for single-tenant / unauthenticated stdio. A
//     null caller tenant only matches a SchemaProvider whose tenant is
//     also null (single-tenant store) — see `schemaTenantMatches`.
//   - `user_id`    — null for unauthenticated stdio (local filesystem
//     user). Carried for audit / future per-user gating; the per-user
//     RLS label filter already lives inside `schema_introspection`.
//   - `session_id` — null for stdio; the embedded-TCP path binds one.
//     Carried so providers and their telemetry can attribute a request
//     to a session without reaching back into Server state.

const std = @import("std");

pub const LspContext = struct {
    /// Tenant the request is being made on behalf of. `null` means
    /// single-tenant / unauthenticated stdio. A null caller tenant only
    /// matches a single-tenant (null-tenant) SchemaProvider.
    tenant_id: ?[]const u8 = null,

    /// Authenticated username, or `null` for unauthenticated stdio.
    user_id: ?[]const u8 = null,

    /// Bound session identifier, or `null` for stdio.
    session_id: ?[]const u8 = null,

    /// The unauthenticated single-tenant stdio default: no tenant, no
    /// user, no session. Schema-derived results are still served because
    /// a null caller tenant matches a null-tenant SchemaProvider.
    pub const stdio: LspContext = .{};

    /// Defense-in-depth tenant gate. Returns `true` when a SchemaProvider
    /// scoped to `schema_tenant` is allowed to serve results for this
    /// caller. The match is exact: a null caller tenant matches only a
    /// null schema tenant, and a non-null caller tenant matches only an
    /// identical non-null schema tenant. Any mismatch (including
    /// null-vs-non-null in either direction) is denied so a provider
    /// built for one tenant can never surface another tenant's schema.
    pub fn schemaTenantMatches(self: LspContext, schema_tenant: ?[]const u8) bool {
        if (self.tenant_id) |caller_tid| {
            const sch = schema_tenant orelse return false;
            return std.mem.eql(u8, caller_tid, sch);
        }
        // Caller has no tenant (single-tenant / stdio): only a
        // null-tenant provider is a legitimate match.
        return schema_tenant == null;
    }
};
