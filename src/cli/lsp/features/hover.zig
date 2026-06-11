// Hover provider for the GQL/Geode LSP.
// Split out of features.zig (#806, QUALITY_GAP_ANALYSIS) — features.zig
// remains the public facade re-exporting `provideHover`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("../protocol.zig");
const Document = @import("../document.zig").Document;
const geode = @import("geode");
const language_metadata = geode.language_metadata;

/// GAP-0818: caller identity threaded into every feature provider.
const LspContext = @import("../context.zig").LspContext;
const SchemaProviderType = @import("../schema_provider.zig").SchemaProvider;

// CANARY: REQ=REQ-LSP-METADATA-003; FEATURE="MetadataIntegration"; ASPECT=Hover; STATUS=EXEMPT; OWNER=lsp; UPDATED=2026-01-03
// CANARY: REQ=REQ-LSP-SCHEMA-HOVER-001; FEATURE="LspPermissionAwareCompletion"; ASPECT=HoverLabel; STATUS=TESTED; TEST=src/cli/lsp/features_test.zig:"hover on label shows property list"; OWNER=lsp; UPDATED=2026-05-14
// CANARY: REQ=REQ-LSP-SCHEMA-HOVER-002; FEATURE="LspPermissionAwareCompletion"; ASPECT=HoverEdgeType; STATUS=TESTED; TEST=src/cli/lsp/features_test.zig:"hover on edge type shows usage hint"; OWNER=lsp; UPDATED=2026-05-14
// CANARY: REQ=REQ-LSP-SCHEMA-HOVER-003; FEATURE="LspPermissionAwareCompletion"; ASPECT=HoverProperty; STATUS=TESTED; TEST=src/cli/lsp/features_test.zig:"hover on property shows owning label"; OWNER=lsp; UPDATED=2026-05-14
// CANARY: REQ=REQ-LSP-CALLER-IDENTITY-001; FEATURE="LspCallerIdentity"; ASPECT=HoverTenantGate; STATUS=TESTED; TEST=tests/test_gap0818_lsp_context.zig:"GAP-0818 hover for tenant A does not leak tenant B label card"; OWNER=lsp; UPDATED=2026-06-09
pub fn provideHover(
    allocator: Allocator,
    doc: *const Document,
    line: u32,
    character: u32,
    schema: ?*SchemaProviderType,
    caller: LspContext,
) !?protocol.Hover {
    const offset = doc.getOffset(line, character) orelse return null;
    const word = doc.getWordAt(offset) orelse return null;

    // GAP-0818: gate the tenant-scoped schema hover branches on caller
    // tenant identity. On a mismatch we null out the provider so only the
    // static (tenant-independent) keyword/function/type/procedure hover
    // metadata below can fire — a tenant-B label can never render a hover
    // card for a tenant-A request.
    const schema_for_caller: ?*SchemaProviderType =
        if (schema) |sp| (if (caller.schemaTenantMatches(sp.ctx.tenant_id)) sp else null) else null;

    // Schema-aware label hover: if the hovered word is a node label visible
    // to this user/tenant, render the label + its observed property keys as
    // markdown. The static metadata fallback below still handles keywords,
    // functions, types, and procedures. Edge-type / property hover land in
    // Task 22.
    //
    // Memory contract: the returned `contents.value` is allocated from
    // `allocator` and owned by the caller (matches the keyword/function
    // branches below). `sp.getLabels()` / `sp.getPropertiesFor()` slices
    // are borrowed from the SchemaProvider cache — we read them inline and
    // copy what we need into the buffer, so no caller-side free of those.
    if (schema_for_caller) |sp| {
        const labels = sp.getLabels() catch &[_][]const u8{};
        for (labels) |lbl| {
            if (!std.mem.eql(u8, lbl, word)) continue;
            const props = sp.getPropertiesFor(lbl) catch &[_][]const u8{};
            var buf = std.ArrayList(u8).empty;
            errdefer buf.deinit(allocator);
            try buf.appendSlice(allocator, "**Label `");
            try buf.appendSlice(allocator, lbl);
            try buf.appendSlice(allocator, "`** *(Node)*\n\nProperties:\n");
            if (props.len == 0) {
                try buf.appendSlice(allocator, "_(none observed)_\n");
            } else {
                for (props) |p| {
                    try buf.appendSlice(allocator, "- `");
                    try buf.appendSlice(allocator, p);
                    try buf.appendSlice(allocator, "`\n");
                }
            }
            const owned = try buf.toOwnedSlice(allocator);
            return protocol.Hover{
                .contents = .{
                    .kind = .markdown,
                    .value = owned,
                },
            };
        }
        // Edge type hover — render a usage skeleton when the hovered word
        // matches an edge type the schema knows about. Memory contract
        // mirrors the label branch above: `contents.value` is allocPrint'd
        // and owned by the caller; the `t` slice is borrowed from the
        // SchemaProvider cache (copied into the format buffer by `{s}`).
        const types = sp.getEdgeTypes() catch &[_][]const u8{};
        for (types) |t| {
            if (!std.mem.eql(u8, t, word)) continue;
            return protocol.Hover{
                .contents = .{
                    .kind = .markdown,
                    .value = try std.fmt.allocPrint(
                        allocator,
                        "**Edge type `{s}`**\n\nUse in: `()-[r:{s}]->()`",
                        .{ t, t },
                    ),
                },
            };
        }

        // Property hover — only when the hovered word's left neighbour is
        // `.` AND the variable to the left of the dot resolves (via
        // `completion_context.resolveVarLabel`) to a known label.
        //
        // `getOffset` returns the cursor position, and `getWordAt` scans
        // back/forward from it to span the surrounding identifier. So
        // `offset` may sit anywhere inside `word` — we have to re-scan
        // back to locate the word's true start before checking the
        // preceding `.`. Falls through (no early return) when the word
        // isn't dot-prefixed or no label resolves, so the legacy
        // keyword/function/type fallback below still runs.
        var word_start: usize = offset;
        while (word_start > 0 and
            (std.ascii.isAlphanumeric(doc.text[word_start - 1]) or doc.text[word_start - 1] == '_')) : (word_start -= 1)
        {}
        if (word_start >= 1 and doc.text[word_start - 1] == '.') {
            const dot_pos = word_start - 1;
            var k: usize = dot_pos;
            while (k > 0 and
                (std.ascii.isAlphanumeric(doc.text[k - 1]) or doc.text[k - 1] == '_')) : (k -= 1)
            {}
            const var_name = doc.text[k..dot_pos];
            if (var_name.len > 0) {
                const ctx_mod = @import("../completion_context.zig");
                if (ctx_mod.resolveVarLabel(doc.text, var_name)) |lbl| {
                    return protocol.Hover{
                        .contents = .{
                            .kind = .markdown,
                            .value = try std.fmt.allocPrint(
                                allocator,
                                "**Property `{s}.{s}`**\n\nOn label `{s}`",
                                .{ var_name, word, lbl },
                            ),
                        },
                    };
                }
            }
        }
    }

    // Check if it's a function (case-sensitive) - check before keywords to avoid
    // false matches like "count" matching keyword "COUNT" instead of function "count"
    if (language_metadata.findFunction(word)) |fn_info| {
        const doc_text = try formatFunctionHover(allocator, fn_info);
        return protocol.Hover{
            .contents = .{
                .kind = .markdown,
                .value = doc_text,
            },
        };
    }

    // Check if it's a keyword (case-insensitive)
    if (language_metadata.findKeyword(word)) |kw_info| {
        const doc_text = try formatKeywordHover(allocator, kw_info);
        return protocol.Hover{
            .contents = .{
                .kind = .markdown,
                .value = doc_text,
            },
        };
    }

    // Check if it's a type (case-insensitive)
    if (language_metadata.findType(word)) |type_info| {
        const doc_text = try formatTypeHover(allocator, type_info);
        return protocol.Hover{
            .contents = .{
                .kind = .markdown,
                .value = doc_text,
            },
        };
    }

    // Check if it's a procedure
    if (language_metadata.findProcedure(word)) |proc_info| {
        const doc_text = try formatProcedureHover(allocator, proc_info);
        return protocol.Hover{
            .contents = .{
                .kind = .markdown,
                .value = doc_text,
            },
        };
    }

    return null;
}

/// Format keyword metadata for hover display
fn formatKeywordHover(allocator: Allocator, info: language_metadata.KeywordInfo) ![]const u8 {
    const compliance = switch (info.compliance) {
        .iso_gql => "ISO/IEC 39075:2024",
        .geode_extension => "Geode Extension",
        .cypher_compat => "Cypher Compatibility",
    };
    const category = @tagName(info.category);

    if (info.extended_doc) |ext| {
        return try std.fmt.allocPrint(allocator,
            \\### `{s}` (Keyword)
            \\
            \\**Category**: {s}
            \\**Compliance**: {s}
            \\
            \\{s}
            \\
            \\---
            \\{s}
        , .{ info.name, category, compliance, info.doc, ext });
    } else {
        return try std.fmt.allocPrint(allocator,
            \\### `{s}` (Keyword)
            \\
            \\**Category**: {s}
            \\**Compliance**: {s}
            \\
            \\{s}
        , .{ info.name, category, compliance, info.doc });
    }
}

/// Format function metadata for hover display
fn formatFunctionHover(allocator: Allocator, info: language_metadata.FunctionInfo) ![]const u8 {
    const category = @tagName(info.category);
    var params_buf = std.ArrayList(u8).initCapacity(allocator, 64) catch return error.OutOfMemory;
    defer params_buf.deinit(allocator);

    // Build parameter list
    for (info.params, 0..) |param, i| {
        if (i > 0) try params_buf.appendSlice(allocator, ", ");
        try params_buf.appendSlice(allocator, param.name);
        try params_buf.appendSlice(allocator, ": ");
        try params_buf.appendSlice(allocator, param.type_name);
        if (param.optional) try params_buf.appendSlice(allocator, "?");
    }

    if (info.example) |example| {
        return try std.fmt.allocPrint(allocator,
            \\### `{s}({s})` → {s}
            \\
            \\**Category**: {s}
            \\
            \\{s}
            \\
            \\**Example**:
            \\```gql
            \\{s}
            \\```
        , .{ info.name, params_buf.items, info.return_type, category, info.doc, example });
    } else {
        return try std.fmt.allocPrint(allocator,
            \\### `{s}({s})` → {s}
            \\
            \\**Category**: {s}
            \\
            \\{s}
        , .{ info.name, params_buf.items, info.return_type, category, info.doc });
    }
}

/// Format type metadata for hover display
fn formatTypeHover(allocator: Allocator, info: language_metadata.TypeInfo) ![]const u8 {
    const compliance = switch (info.compliance) {
        .iso_gql => "ISO/IEC 39075:2024",
        .geode_extension => "Geode Extension",
        .cypher_compat => "Cypher Compatibility",
    };
    if (info.example) |example| {
        return try std.fmt.allocPrint(allocator,
            \\### `{s}` (Type)
            \\
            \\**Compliance**: {s}
            \\
            \\{s}
            \\
            \\**Example**: `{s}`
        , .{ info.name, compliance, info.doc, example });
    } else {
        return try std.fmt.allocPrint(allocator,
            \\### `{s}` (Type)
            \\
            \\**Compliance**: {s}
            \\
            \\{s}
        , .{ info.name, compliance, info.doc });
    }
}

/// Format procedure metadata for hover display
fn formatProcedureHover(allocator: Allocator, info: language_metadata.ProcedureInfo) ![]const u8 {
    const category = @tagName(info.category);
    var yields_buf = std.ArrayList(u8).initCapacity(allocator, 64) catch return error.OutOfMemory;
    defer yields_buf.deinit(allocator);

    // Build yield columns list
    for (info.columns, 0..) |col, i| {
        if (i > 0) try yields_buf.appendSlice(allocator, ", ");
        try yields_buf.appendSlice(allocator, col.name);
        try yields_buf.appendSlice(allocator, ": ");
        try yields_buf.appendSlice(allocator, col.type_name);
    }

    return try std.fmt.allocPrint(allocator,
        \\### `CALL {s}()` → YIELD {s}
        \\
        \\**Category**: {s}
        \\
        \\{s}
    , .{ info.name, yields_buf.items, category, info.doc });
}
