// Completion provider for the GQL/Geode LSP.
// Split out of features.zig (#806, QUALITY_GAP_ANALYSIS) — features.zig
// remains the public facade re-exporting `provideCompletion`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("../protocol.zig");
const Document = @import("../document.zig").Document;
const geode = @import("geode");
const language_metadata = geode.language_metadata;
const startsWithCI = @import("common.zig").startsWithCI;

/// GAP-0818: caller identity threaded into every feature provider.
const LspContext = @import("../context.zig").LspContext;
const SchemaProviderType = @import("../schema_provider.zig").SchemaProvider;

// CANARY: REQ=REQ-LSP-METADATA-004; FEATURE="MetadataIntegration"; ASPECT=Completions; STATUS=EXEMPT; OWNER=lsp; UPDATED=2026-01-03
// CANARY: REQ=REQ-LSP-SCHEMA-COMPLETION-001; FEATURE="LspPermissionAwareCompletion"; ASPECT=SchemaBranches; STATUS=TESTED; TEST=src/cli/lsp/features_test.zig:"provideCompletion offers labels after (n:"; OWNER=lsp; UPDATED=2026-05-14
//
// Task 18 of the LSP permission-aware completion plan. Cursor-context
// analysis (`completion_context.analyze`) drives schema-aware branches
// for `Kind.label`, `Kind.edge_type`, and `Kind.property`. The
// `keyword`/`parameter`/`variable` kinds fall through to the existing
// static keyword/function/type/procedure lists.
//
// Memory ownership: the schema-derived branches borrow label/edge-type/
// property slices from the SchemaProvider TTL cache without duping —
// the LSP serializer copies them before the cache could expire. The
// per-item `.detail` for the property branch is allocPrint'd and
// freeable via the same allocator the caller supplied; the label and
// edge-type branches use a static literal detail (no free needed).
// `insertText` is intentionally aliased to `label` so the existing
// "skip free when insertText == label" cleanup convention holds.
//
// CANARY: REQ=REQ-LSP-CALLER-IDENTITY-001; FEATURE="LspCallerIdentity"; ASPECT=CompletionTenantGate; STATUS=TESTED; TEST=tests/test_gap0818_lsp_context.zig:"GAP-0818 completion for tenant A does not leak tenant B labels"; OWNER=lsp; UPDATED=2026-06-09
pub fn provideCompletion(
    allocator: Allocator,
    doc: *const Document,
    line: u32,
    character: u32,
    schema: ?*SchemaProviderType,
    caller: LspContext,
) ![]protocol.CompletionItem {
    const ctx_mod = @import("../completion_context.zig");
    const ctx = ctx_mod.analyze(doc.text, .{ .line = line, .character = character });

    var items = std.ArrayList(protocol.CompletionItem).initCapacity(allocator, 200) catch return error.OutOfMemory;
    errdefer items.deinit(allocator);

    // GAP-0818: only consult the SchemaProvider's tenant-scoped data when
    // the caller's tenant matches the provider's tenant. A mismatch
    // (mis-wired / reused provider) drops us to the static, tenant-
    // independent language metadata so we never surface another tenant's
    // labels / edge types / properties. Static keyword/function/type/
    // procedure completion below is tenant-independent and always served.
    const schema_for_caller: ?*SchemaProviderType =
        if (schema) |sp| (if (caller.schemaTenantMatches(sp.ctx.tenant_id)) sp else null) else null;

    if (schema_for_caller) |sp| {
        switch (ctx.kind) {
            .label => {
                const labels = sp.getLabels() catch &[_][]const u8{};
                for (labels) |lbl| {
                    if (ctx.prefix.len > 0 and !std.mem.startsWith(u8, lbl, ctx.prefix)) continue;
                    try items.append(allocator, .{
                        .label = lbl,
                        .kind = .Class,
                        .detail = "Node label",
                        .documentation = null,
                        .insertText = lbl,
                    });
                }
                // GAP-0344: when the schema has no node labels yet (fresh
                // database) the client still needs *some* suggestion so the
                // completion popup is not empty. Surface the language's
                // built-in type names — every type is a syntactically
                // valid label identifier and the popup is a useful
                // discovery surface for new users learning the type
                // system.
                if (items.items.len == 0) {
                    for (language_metadata.types) |typ| {
                        if (ctx.prefix.len > 0 and !startsWithCI(typ.name, ctx.prefix)) continue;
                        try items.append(allocator, .{
                            .label = typ.name,
                            .kind = .Class,
                            .detail = "Built-in type (no labels yet)",
                            .documentation = typ.doc,
                            .insertText = typ.name,
                        });
                    }
                }
                return items.toOwnedSlice(allocator);
            },
            .edge_type => {
                const types = sp.getEdgeTypes() catch &[_][]const u8{};
                for (types) |t| {
                    if (ctx.prefix.len > 0 and !std.mem.startsWith(u8, t, ctx.prefix)) continue;
                    try items.append(allocator, .{
                        .label = t,
                        .kind = .Reference,
                        .detail = "Edge type",
                        .documentation = null,
                        .insertText = t,
                    });
                }
                // GAP-0344: same fall-back as the label branch — empty
                // schema should still yield non-empty completions.
                if (items.items.len == 0) {
                    for (language_metadata.types) |typ| {
                        if (ctx.prefix.len > 0 and !startsWithCI(typ.name, ctx.prefix)) continue;
                        try items.append(allocator, .{
                            .label = typ.name,
                            .kind = .Reference,
                            .detail = "Built-in type (no edge types yet)",
                            .documentation = typ.doc,
                            .insertText = typ.name,
                        });
                    }
                }
                return items.toOwnedSlice(allocator);
            },
            .property => {
                const var_name = ctx.var_name orelse return items.toOwnedSlice(allocator);
                const label_opt = ctx_mod.resolveVarLabel(doc.text, var_name);
                const lbl = label_opt orelse return items.toOwnedSlice(allocator);
                const props = sp.getPropertiesFor(lbl) catch &[_][]const u8{};
                for (props) |p| {
                    if (ctx.prefix.len > 0 and !std.mem.startsWith(u8, p, ctx.prefix)) continue;
                    try items.append(allocator, .{
                        .label = p,
                        .kind = .Field,
                        .detail = try std.fmt.allocPrint(allocator, "Property of {s}", .{lbl}),
                        .documentation = null,
                        .insertText = p,
                    });
                }
                return items.toOwnedSlice(allocator);
            },
            .keyword, .parameter, .variable => {
                // Fall through to static items below.
            },
        }
    }

    // Add keywords with metadata documentation
    for (language_metadata.keywords) |kw| {
        if (ctx.prefix.len > 0 and !startsWithCI(kw.name, ctx.prefix)) continue;
        const compliance_str = switch (kw.compliance) {
            .iso_gql => " (ISO GQL)",
            .geode_extension => " (Geode)",
            .cypher_compat => " (Cypher)",
        };
        try items.append(allocator, .{
            .label = kw.name,
            .kind = .Keyword,
            .detail = try std.fmt.allocPrint(allocator, "{s}{s}", .{ @tagName(kw.category), compliance_str }),
            .documentation = kw.doc,
            .insertText = kw.name,
        });
    }

    // Add functions with metadata documentation
    for (language_metadata.functions) |func| {
        if (ctx.prefix.len > 0 and !startsWithCI(func.name, ctx.prefix)) continue;
        try items.append(allocator, .{
            .label = func.name,
            .kind = .Function,
            .detail = try std.fmt.allocPrint(allocator, "({s}) → {s}", .{ @tagName(func.category), func.return_type }),
            .documentation = func.doc,
            .insertText = try std.fmt.allocPrint(allocator, "{s}()", .{func.name}),
        });
    }

    // Add types with metadata documentation
    for (language_metadata.types) |typ| {
        if (ctx.prefix.len > 0 and !startsWithCI(typ.name, ctx.prefix)) continue;
        const compliance_str = switch (typ.compliance) {
            .iso_gql => "ISO GQL Type",
            .geode_extension => "Geode Type",
            .cypher_compat => "Cypher Type",
        };
        try items.append(allocator, .{
            .label = typ.name,
            .kind = .Class,
            .detail = compliance_str,
            .documentation = typ.doc,
            .insertText = typ.name,
        });
    }

    // Add procedures with metadata documentation
    for (language_metadata.procedures) |proc| {
        if (ctx.prefix.len > 0 and !startsWithCI(proc.name, ctx.prefix)) continue;
        try items.append(allocator, .{
            .label = proc.name,
            .kind = .Method,
            .detail = try std.fmt.allocPrint(allocator, "CALL {s}()", .{proc.name}),
            .documentation = proc.doc,
            .insertText = try std.fmt.allocPrint(allocator, "CALL {s}() YIELD", .{proc.name}),
        });
    }

    return items.toOwnedSlice(allocator);
}
