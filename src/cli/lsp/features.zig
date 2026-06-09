// Module implementation
// CANARY: REQ=REQ-LSP-METADATA-001; FEATURE="MetadataIntegration"; ASPECT=Completions; STATUS=EXEMPT; OWNER=lsp; UPDATED=2026-01-03
// Language features implementation for GQL/Geode LSP

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const Document = @import("document.zig").Document;
const geode = @import("geode");
const semantic = @import("semantic.zig");
const language_metadata = geode.language_metadata;
const context_mod = @import("context.zig");

/// GAP-0818: caller identity threaded into every feature provider.
pub const LspContext = context_mod.LspContext;

// GAP-0818 re-exports so out-of-tree test modules (rooted at this file as
// the `lsp_features` named module) can construct the provider inputs
// without registering `protocol.zig` / `document.zig` /
// `schema_provider.zig` as separate modules — which would trip Zig
// 0.16's "file exists in modules X and X0" diamond.
pub const Protocol = protocol;
pub const DocumentType = Document;
pub const SchemaProviderType = @import("schema_provider.zig").SchemaProvider;

/// Formatting options for the GQL formatter
pub const FormattingOptions = struct {
    /// Number of spaces for indentation (default: 4)
    indent_size: u32 = 4,
    /// Whether to fold property maps onto multiple lines (default: true)
    fold_property_maps: bool = true,
    /// Maximum line length before folding (default: 80)
    max_line_length: u32 = 80,
    /// Minimum number of properties to trigger folding (default: 2)
    min_properties_to_fold: u32 = 2,
};

// CANARY: REQ=REQ-LSP-METADATA-002; FEATURE="MetadataIntegration"; ASPECT=ComptimeLists; STATUS=EXEMPT; OWNER=lsp; UPDATED=2026-01-03
// GQL Keywords, Functions, and Types derived from unified language_metadata.zig
// This ensures the LSP completions stay in sync with the lexer and documentation
const GQL_KEYWORDS = language_metadata.getKeywordNames();
const GQL_FUNCTIONS = language_metadata.getFunctionNames();
const GQL_TYPES = language_metadata.getTypeNames();

// CANARY: REQ=REQ-LSP-SCHEMA-COMPLETION-001; FEATURE="LspPermissionAwareCompletion"; ASPECT=PrefixFilter; STATUS=TESTED; TEST=src/cli/lsp/features_test.zig:"provideCompletion filters static keywords by prefix"; OWNER=lsp; UPDATED=2026-05-14
/// Case-insensitive prefix match. Returns true if `s` starts with `p`,
/// comparing ASCII letters case-insensitively. Empty `p` always matches.
/// Used by `provideCompletion` to filter static keyword/function/type/
/// procedure lists by what the user has typed so far.
pub fn startsWithCI(s: []const u8, p: []const u8) bool {
    if (s.len < p.len) return false;
    for (p, 0..) |c, i| if (std.ascii.toLower(s[i]) != std.ascii.toLower(c)) return false;
    return true;
}

// CANARY: REQ=REQ-LSP-SCHEMA-DIAG-001; FEATURE="LspPermissionAwareCompletion"; ASPECT=UnknownLabel; STATUS=TESTED; TEST=src/cli/lsp/features_test.zig:"diagnostics flag unknown labels with hint"; OWNER=lsp; UPDATED=2026-05-14
// CANARY: REQ=REQ-LSP-SCHEMA-DIAG-002; FEATURE="LspPermissionAwareCompletion"; ASPECT=UnknownEdgeType; STATUS=TESTED; TEST=src/cli/lsp/features_test.zig:"diagnostics flag unknown edge types with hint"; OWNER=lsp; UPDATED=2026-05-14
// CANARY: REQ=REQ-LSP-CALLER-IDENTITY-001; FEATURE="LspCallerIdentity"; ASPECT=DiagnosticsTenantGate; STATUS=TESTED; TEST=tests/test_gap0818_lsp_context.zig:"GAP-0818 diagnostics for tenant A does not leak tenant B label in hint"; OWNER=lsp; UPDATED=2026-06-09
pub fn provideDiagnostics(
    allocator: Allocator,
    doc: *const Document,
    schema: ?*SchemaProviderType,
    caller: LspContext,
) ![]protocol.Diagnostic {
    var diagnostics = std.ArrayList(protocol.Diagnostic).initCapacity(allocator, 10) catch return error.OutOfMemory;
    errdefer diagnostics.deinit(allocator);

    // Parse the document using outcome to get better error info.
    // ParseOutcome owns its own memory (Ok arena, Err msg) — defer
    // deinit so the duped Err.msg returned after the parser arena is
    // freed (lib.zig parseGqlOutcome) gets released.
    var outcome = try geode.parseGqlOutcome(doc.text, allocator, .{});
    defer outcome.deinit();

    switch (outcome) {
        .Err => |err_info| {
            // Check for double-dash comments (Geode extension - supported but non-standard)
            if (err_info.has_double_dash_comment) {
                const info_diag = protocol.Diagnostic{
                    .range = .{
                        .start = .{ .line = 0, .character = 0 },
                        .end = .{ .line = 0, .character = 0 },
                    },
                    .severity = .Information,
                    .source = "geode",
                    .message = try allocator.dupe(u8, "Double-dash (--) comments are a Geode extension and may not be supported by other GQL databases."),
                };
                try diagnostics.append(allocator, info_diag);
            }

            // Check for UNWIND (not standard GQL - Cypher/openCypher syntax)
            if (err_info.has_unwind) {
                var uw_line: u32 = 0;
                var uw_col: u32 = 0;
                if (doc.findIdentifierPosition("UNWIND")) |pos| {
                    uw_line = pos.line;
                    uw_col = pos.character;
                }
                const uw_diag = protocol.Diagnostic{
                    .range = .{
                        .start = .{ .line = uw_line, .character = uw_col },
                        .end = .{ .line = uw_line, .character = uw_col + 6 },
                    },
                    .severity = .Error,
                    .source = "geode",
                    .message = try allocator.dupe(u8, "UNWIND is not standard GQL (ISO/IEC 39075:2024). Use FOR ... IN ... instead."),
                };
                try diagnostics.append(allocator, uw_diag);
            }

            // Then show the parse error at the actual location
            const diag = protocol.Diagnostic{
                .range = .{
                    .start = .{ .line = err_info.line, .character = err_info.column },
                    .end = .{ .line = err_info.line, .character = err_info.column + 1 },
                },
                .severity = .Error,
                .source = "geode",
                .message = try allocator.dupe(u8, err_info.msg),
            };
            try diagnostics.append(allocator, diag);
        },
        .Ok => |result| {
            // Arena cleanup is handled by the top-level
            // `defer outcome.deinit()` above, which routes to
            // ParseResult.deinit() for the .Ok variant.

            // Check for double-dash comments (Geode extension - supported but non-standard)
            if (result.has_double_dash_comment) {
                const diag = protocol.Diagnostic{
                    .range = .{
                        .start = .{ .line = 0, .character = 0 },
                        .end = .{ .line = 0, .character = 0 },
                    },
                    .severity = .Information,
                    .source = "geode",
                    .message = try allocator.dupe(u8, "Double-dash (--) comments are a Geode extension and may not be supported by other GQL databases."),
                };
                try diagnostics.append(allocator, diag);
            }

            // Check for UNWIND (not standard GQL - Cypher/openCypher syntax)
            if (result.has_unwind) {
                var uw_line: u32 = 0;
                var uw_col: u32 = 0;
                if (doc.findIdentifierPosition("UNWIND")) |pos| {
                    uw_line = pos.line;
                    uw_col = pos.character;
                }
                const uw_diag = protocol.Diagnostic{
                    .range = .{
                        .start = .{ .line = uw_line, .character = uw_col },
                        .end = .{ .line = uw_line, .character = uw_col + 6 },
                    },
                    .severity = .Error,
                    .source = "geode",
                    .message = try allocator.dupe(u8, "UNWIND is not standard GQL (ISO/IEC 39075:2024). Use FOR ... IN ... instead."),
                };
                try diagnostics.append(allocator, uw_diag);
            }

            // Check for parser errors
            if (result.last_error) |last_err| {
                const diag = protocol.Diagnostic{
                    .range = .{
                        .start = .{ .line = 0, .character = 0 },
                        .end = .{ .line = 0, .character = 0 },
                    },
                    .severity = .Error,
                    .source = "geode",
                    .message = try allocator.dupe(u8, last_err),
                };
                try diagnostics.append(allocator, diag);
            }

            // Perform semantic analysis for undefined variable detection
            var analyzer = semantic.SemanticAnalyzer.init(allocator);
            defer analyzer.deinit();

            const sem_errors = analyzer.analyze(result.program) catch {
                // If semantic analysis fails, return existing diagnostics
                return diagnostics.toOwnedSlice(allocator);
            };

            for (sem_errors) |sem_err| {
                // Try to find the position of the undefined variable in the document
                var line = sem_err.line;
                var column = sem_err.column;
                var end_column = sem_err.column + 1;

                // Extract variable name from error message like "Undefined variable: xyz"
                const prefix = "Undefined variable: ";
                if (std.mem.startsWith(u8, sem_err.message, prefix)) {
                    const var_name = sem_err.message[prefix.len..];
                    if (doc.findIdentifierPosition(var_name)) |pos| {
                        line = pos.line;
                        column = pos.character;
                        end_column = pos.character + @as(u32, @intCast(var_name.len));
                    }
                }

                const diag = protocol.Diagnostic{
                    .range = .{
                        .start = .{ .line = line, .character = column },
                        .end = .{ .line = line, .character = end_column },
                    },
                    .severity = .Error,
                    .source = "geode",
                    .message = try allocator.dupe(u8, sem_err.message),
                };
                try diagnostics.append(allocator, diag);
            }

            // Run recommendation engine for context-aware suggestions
            var rec_engine = geode.recommendations.RecommendationEngine.init(allocator);
            defer rec_engine.deinit();
            const suggestions = rec_engine.analyze(result.program) catch &[_]geode.recommendations.Recommendation{};
            for (suggestions) |suggestion| {
                const rec_diag = protocol.Diagnostic{
                    .range = .{
                        .start = .{ .line = suggestion.line, .character = suggestion.column },
                        .end = .{ .line = suggestion.line, .character = suggestion.column },
                    },
                    .severity = switch (suggestion.severity) {
                        .information => .Information,
                        .hint => .Hint,
                    },
                    .source = "geode",
                    .message = try allocator.dupe(u8, suggestion.message),
                };
                try diagnostics.append(allocator, rec_diag);
            }
        },
    }

    // Schema-aware label validation. Scan the document text for node-pattern
    // label tokens (`(var:Label` shapes) and warn on labels the user's schema
    // doesn't know about, with a Levenshtein-based "did you mean" hint when a
    // close match exists. Skipped when no schema is wired (e.g. --no-auth
    // stdio or tests). Memory: each `.message` is allocPrint'd and owned by
    // the caller (matches the parse/semantic branches above).
    //
    // GAP-0818: gate the tenant-scoped schema scan on caller tenant identity
    // (same shadow as completion/hover). On a mismatch we null out the
    // provider so a tenant-B label name can never leak into a tenant-A
    // "Unknown label `X`. Did you mean `Beta`?" hint via closestLabel.
    const schema_for_caller: ?*SchemaProviderType =
        if (schema) |sp| (if (caller.schemaTenantMatches(sp.ctx.tenant_id)) sp else null) else null;
    if (schema_for_caller) |sp| {
        const known = sp.getLabels() catch &[_][]const u8{};
        const text = doc.text;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] != '(') continue;
            var j = i + 1;
            while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
            // skip optional variable identifier
            while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) : (j += 1) {}
            while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
            if (j >= text.len or text[j] != ':') continue;
            j += 1;
            while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
            const lbl_start = j;
            while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) : (j += 1) {}
            const lbl = text[lbl_start..j];
            if (lbl.len == 0) continue;

            var is_known = false;
            for (known) |l| {
                if (std.mem.eql(u8, l, lbl)) {
                    is_known = true;
                    break;
                }
            }
            if (is_known) continue;

            const hint = closestLabel(lbl, known);
            const msg = if (hint) |h|
                try std.fmt.allocPrint(allocator, "Unknown label `{s}`. Did you mean `{s}`?", .{ lbl, h })
            else
                try std.fmt.allocPrint(allocator, "Unknown label `{s}`.", .{lbl});

            const start_pos = offsetToLineCol(text, lbl_start);
            const end_pos = offsetToLineCol(text, j);
            try diagnostics.append(allocator, .{
                .range = .{ .start = start_pos, .end = end_pos },
                .severity = .Warning,
                .source = "geode-lsp",
                .message = msg,
            });
        }

        // Task 24: edge-type scan — mirror of the label scan above, but
        // anchored on `[` (the relationship-pattern opener) so it can't
        // false-positive on `(var:Label)`. Same memory contract: each
        // `.message` is allocPrint'd and owned by the caller.
        const known_types = sp.getEdgeTypes() catch &[_][]const u8{};
        var t_i: usize = 0;
        const t_text = doc.text;
        while (t_i < t_text.len) : (t_i += 1) {
            if (t_text[t_i] != '[') continue;
            var k = t_i + 1;
            while (k < t_text.len and std.ascii.isWhitespace(t_text[k])) : (k += 1) {}
            // skip optional variable identifier
            while (k < t_text.len and (std.ascii.isAlphanumeric(t_text[k]) or t_text[k] == '_')) : (k += 1) {}
            while (k < t_text.len and std.ascii.isWhitespace(t_text[k])) : (k += 1) {}
            if (k >= t_text.len or t_text[k] != ':') continue;
            k += 1;
            while (k < t_text.len and std.ascii.isWhitespace(t_text[k])) : (k += 1) {}
            const t_start = k;
            while (k < t_text.len and (std.ascii.isAlphanumeric(t_text[k]) or t_text[k] == '_')) : (k += 1) {}
            const et = t_text[t_start..k];
            if (et.len == 0) continue;

            var et_known = false;
            for (known_types) |kt| {
                if (std.mem.eql(u8, kt, et)) {
                    et_known = true;
                    break;
                }
            }
            if (et_known) continue;

            const hint = closestLabel(et, known_types);
            const msg = if (hint) |h|
                try std.fmt.allocPrint(allocator, "Unknown edge type `{s}`. Did you mean `{s}`?", .{ et, h })
            else
                try std.fmt.allocPrint(allocator, "Unknown edge type `{s}`.", .{et});

            const start_pos = offsetToLineCol(t_text, t_start);
            const end_pos = offsetToLineCol(t_text, k);
            try diagnostics.append(allocator, .{
                .range = .{ .start = start_pos, .end = end_pos },
                .severity = .Warning,
                .source = "geode-lsp",
                .message = msg,
            });
        }
    }

    return diagnostics.toOwnedSlice(allocator);
}

/// Levenshtein edit distance between two byte slices. Cap inputs at 64
/// chars (typical labels are 4-16); longer slices return maxInt(usize)
/// so the caller treats them as "no close match". Allocation-free —
/// uses two 65-cell stack rows for the dynamic-programming table.
fn levenshtein(a: []const u8, b: []const u8) usize {
    if (a.len > 64 or b.len > 64) return std.math.maxInt(usize);
    var prev: [65]usize = undefined;
    var curr: [65]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        curr[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            curr[j + 1] = @min(@min(curr[j] + 1, prev[j + 1] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], curr[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// Find the closest label to `target` from `labels` under Levenshtein
/// distance, returning null when the best candidate is more than 2 edits
/// away (the threshold beyond which a "did you mean" hint becomes more
/// confusing than helpful).
fn closestLabel(target: []const u8, labels: []const []const u8) ?[]const u8 {
    var best_dist: usize = std.math.maxInt(usize);
    var best: ?[]const u8 = null;
    for (labels) |l| {
        const d = levenshtein(target, l);
        if (d < best_dist) {
            best_dist = d;
            best = l;
        }
    }
    return if (best_dist <= 2) best else null;
}

/// Convert a byte offset in `text` to an LSP Position (zero-indexed line
/// + UTF-16 character — we approximate as byte column, which matches the
/// `completion_context.lineColToOffset` ASCII convention used elsewhere
/// in this LSP).
fn offsetToLineCol(text: []const u8, offset: usize) protocol.Position {
    var line: u32 = 0;
    var col: u32 = 0;
    var i: usize = 0;
    while (i < offset and i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .character = col };
}

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
                const ctx_mod = @import("completion_context.zig");
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
    const ctx_mod = @import("completion_context.zig");
    const ctx = ctx_mod.analyze(doc.text, .{ .line = line, .character = character });

    var items = std.ArrayList(protocol.CompletionItem).initCapacity(allocator, 200) catch return error.OutOfMemory;
    errdefer items.deinit(allocator);

    // GAP-0818: only consult the SchemaProvider's tenant-scoped data when
    // the caller's tenant matches the provider's tenant. A mismatch
    // (mis-wired / reused provider) drops us to the static, tenant-
    // independent language metadata so we never surface another tenant's
    // labels / edge types / properties. Static keyword/function/type/
    // procedure completion below is tenant-independent and always served.
    const schema_for_caller: ?*@import("schema_provider.zig").SchemaProvider =
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

// GAP-0056: LSP Go-To-Definition Implementation
// CANARY: REQ=REQ-LSP-GOTODEF-001; FEATURE="GoToDefinition"; ASPECT=VariableLookup; STATUS=TESTED; OWNER=lsp; UPDATED=2026-05-06
// CANARY: REQ=REQ-LSP-CALLER-IDENTITY-001; FEATURE="LspCallerIdentity"; ASPECT=DefinitionContext; STATUS=TESTED; TEST=tests/test_gap0818_lsp_context.zig:"GAP-0818 definition is tenant-independent variable lookup"; OWNER=lsp; UPDATED=2026-06-09
pub fn provideDefinition(allocator: Allocator, doc: *const Document, line: u32, character: u32, caller: LspContext) !?protocol.Location {
    // GAP-0818: go-to-definition resolves an in-document variable
    // declaration (a pattern variable like `(n:...)`), which is purely a
    // function of the open document text and carries no tenant-scoped
    // schema lookup. The caller identity is threaded for parity with the
    // other providers (audit / telemetry attribution) but does not change
    // the resolution — there is nothing tenant-scoped to leak here.
    _ = caller;
    const offset = doc.getOffset(line, character) orelse return null;
    const word = doc.getWordAt(offset) orelse return null;

    // Skip if the word is a keyword, function, or type - they don't have definitions in user code
    if (language_metadata.findKeyword(word) != null) return null;
    if (language_metadata.findFunction(word) != null) return null;
    if (language_metadata.findType(word) != null) return null;

    // Try parsing the document to find variable definitions
    const outcome = geode.parseGqlOutcome(doc.text, allocator, .{}) catch return null;

    switch (outcome) {
        .Ok => |result| {
            defer {
                var res = result;
                res.deinit();
            }

            // Search for variable definition in the AST
            if (findVariableDefinition(allocator, result.program, word)) |def_info| {
                // Convert text offset to line/column using document
                if (findPositionOfDefinition(doc, def_info.pattern_type, word)) |pos| {
                    return protocol.Location{
                        .uri = doc.uri,
                        .range = .{
                            .start = pos,
                            .end = .{
                                .line = pos.line,
                                .character = pos.character + @as(u32, @intCast(word.len)),
                            },
                        },
                    };
                }
            }
        },
        .Err => {
            // Even with parse errors, try text-based search for patterns
        },
    }

    // Fallback: text-based search for variable patterns like (varname or [varname
    if (findVariablePatternPosition(doc.text, word)) |pos| {
        return protocol.Location{
            .uri = doc.uri,
            .range = .{
                .start = pos,
                .end = .{
                    .line = pos.line,
                    .character = pos.character + @as(u32, @intCast(word.len)),
                },
            },
        };
    }

    return null;
}

/// Definition info from AST analysis
const DefinitionInfo = struct {
    pattern_type: PatternType,
    name: []const u8,
};

const PatternType = enum {
    node_pattern, // (varname) or (varname:Label)
    rel_pattern, // [varname] or [varname:TYPE]
    with_alias, // WITH expr AS varname
    let_binding, // LET varname = expr
    return_alias, // RETURN expr AS varname
};

/// Search AST for variable definitions
fn findVariableDefinition(allocator: Allocator, program: anytype, target: []const u8) ?DefinitionInfo {
    _ = allocator;

    for (program.statements) |stmt| {
        switch (stmt) {
            .Query => |query| {
                if (findVarInQuery(query, target)) |info| {
                    return info;
                }
            },
            .Union => |union_q| {
                if (findVarInQuery(union_q.first, target)) |info| {
                    return info;
                }
                for (union_q.tails) |part| {
                    if (findVarInQuery(part.query, target)) |info| {
                        return info;
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

fn findVarInQuery(query: anytype, target: []const u8) ?DefinitionInfo {
    // Check LET bindings
    for (query.let_bindings) |binding| {
        if (std.mem.eql(u8, binding.variable, target)) {
            return DefinitionInfo{ .pattern_type = .let_binding, .name = target };
        }
    }
    for (query.inline_let_bindings) |binding| {
        if (std.mem.eql(u8, binding.variable, target)) {
            return DefinitionInfo{ .pattern_type = .let_binding, .name = target };
        }
    }

    // Check MATCH pattern for node and relationship variables
    for (query.match.chains) |chain| {
        // Check chain name (path variable)
        if (chain.name) |name| {
            if (std.mem.eql(u8, name, target)) {
                return DefinitionInfo{ .pattern_type = .node_pattern, .name = target };
            }
        }

        // Check head node pattern
        if (chain.head) |head| {
            if (head.name) |name| {
                if (std.mem.eql(u8, name, target)) {
                    return DefinitionInfo{ .pattern_type = .node_pattern, .name = target };
                }
            }
        }

        // Check hops
        for (chain.hops) |hop| {
            if (hop.left.name) |name| {
                if (std.mem.eql(u8, name, target)) {
                    return DefinitionInfo{ .pattern_type = .node_pattern, .name = target };
                }
            }
            if (hop.rel.name) |name| {
                if (std.mem.eql(u8, name, target)) {
                    return DefinitionInfo{ .pattern_type = .rel_pattern, .name = target };
                }
            }
            if (hop.right.name) |name| {
                if (std.mem.eql(u8, name, target)) {
                    return DefinitionInfo{ .pattern_type = .node_pattern, .name = target };
                }
            }
        }
    }

    // Check WITH clause aliases
    if (query.with_clause) |with| {
        for (with.items) |item| {
            if (item.alias) |alias| {
                if (std.mem.eql(u8, alias, target)) {
                    return DefinitionInfo{ .pattern_type = .with_alias, .name = target };
                }
            }
        }
    }

    // Check RETURN aliases (for definitions later referenced)
    for (query.ret.items) |item| {
        if (item.alias) |alias| {
            if (std.mem.eql(u8, alias, target)) {
                return DefinitionInfo{ .pattern_type = .return_alias, .name = target };
            }
        }
    }

    // Check next_query for chained queries
    if (query.next_query) |next| {
        if (findVarInQuery(next.*, target)) |info| {
            return info;
        }
    }

    return null;
}

/// Find position of a variable definition based on pattern type
fn findPositionOfDefinition(doc: *const Document, pattern_type: PatternType, name: []const u8) ?protocol.Position {
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;

    while (i < doc.text.len) {
        // Track newlines
        if (doc.text[i] == '\n') {
            line += 1;
            line_start = i + 1;
            i += 1;
            continue;
        }

        // Skip string literals
        if (doc.text[i] == '\'' or doc.text[i] == '"') {
            const quote = doc.text[i];
            i += 1;
            while (i < doc.text.len and doc.text[i] != quote) {
                if (doc.text[i] == '\n') {
                    line += 1;
                    line_start = i + 1;
                }
                i += 1;
            }
            if (i < doc.text.len) i += 1;
            continue;
        }

        // Look for pattern based on type
        const found = switch (pattern_type) {
            .node_pattern => findNodePatternStart(doc.text, i, name),
            .rel_pattern => findRelPatternStart(doc.text, i, name),
            .with_alias => findAliasPosition(doc.text, i, name, "AS"),
            .let_binding => findLetBindingPosition(doc.text, i, name),
            .return_alias => findAliasPosition(doc.text, i, name, "AS"),
        };

        if (found) |offset| {
            return protocol.Position{
                .line = line,
                .character = @intCast(offset - line_start),
            };
        }

        i += 1;
    }

    return null;
}

fn findNodePatternStart(text: []const u8, pos: usize, name: []const u8) ?usize {
    // Look for (name or (name: or (name)
    if (pos >= text.len or text[pos] != '(') return null;
    if (pos + 1 + name.len > text.len) return null;

    const start = pos + 1;
    // Skip whitespace
    var i = start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) {
        i += 1;
    }

    if (i + name.len > text.len) return null;

    // Check for name match
    if (std.mem.eql(u8, text[i .. i + name.len], name)) {
        const end = i + name.len;
        // Must be followed by ) or : or whitespace
        if (end >= text.len) return null;
        const next = text[end];
        if (next == ')' or next == ':' or next == ' ' or next == '\t' or next == '{') {
            return i;
        }
    }
    return null;
}

fn findRelPatternStart(text: []const u8, pos: usize, name: []const u8) ?usize {
    // Look for [name or [name: or [name]
    if (pos >= text.len or text[pos] != '[') return null;
    if (pos + 1 + name.len > text.len) return null;

    const start = pos + 1;
    var i = start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) {
        i += 1;
    }

    if (i + name.len > text.len) return null;

    if (std.mem.eql(u8, text[i .. i + name.len], name)) {
        const end = i + name.len;
        if (end >= text.len) return null;
        const next = text[end];
        if (next == ']' or next == ':' or next == ' ' or next == '\t' or next == '{' or next == '*') {
            return i;
        }
    }
    return null;
}

fn findAliasPosition(text: []const u8, pos: usize, name: []const u8, keyword: []const u8) ?usize {
    // Look for "AS name" pattern
    if (pos + keyword.len + 1 + name.len > text.len) return null;

    // Check for AS keyword (case insensitive)
    if (!std.ascii.eqlIgnoreCase(text[pos .. pos + keyword.len], keyword)) return null;

    var i = pos + keyword.len;
    // Skip whitespace
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) {
        i += 1;
    }

    if (i + name.len > text.len) return null;

    if (std.mem.eql(u8, text[i .. i + name.len], name)) {
        const end = i + name.len;
        // Must be at end or followed by non-identifier char
        if (end >= text.len or !std.ascii.isAlphanumeric(text[end])) {
            return i;
        }
    }
    return null;
}

fn findLetBindingPosition(text: []const u8, pos: usize, name: []const u8) ?usize {
    // Look for "LET name" or "LET $name" pattern
    if (pos + 3 > text.len) return null;

    if (!std.ascii.eqlIgnoreCase(text[pos .. pos + 3], "LET")) return null;

    var i = pos + 3;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) {
        i += 1;
    }

    // Skip $ prefix if present
    if (i < text.len and text[i] == '$') {
        i += 1;
    }

    if (i + name.len > text.len) return null;

    if (std.mem.eql(u8, text[i .. i + name.len], name)) {
        const end = i + name.len;
        if (end >= text.len or !std.ascii.isAlphanumeric(text[end])) {
            return i;
        }
    }
    return null;
}

/// Fallback text-based search for variable patterns
fn findVariablePatternPosition(text: []const u8, name: []const u8) ?protocol.Position {
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;

    while (i < text.len) {
        if (text[i] == '\n') {
            line += 1;
            line_start = i + 1;
            i += 1;
            continue;
        }

        // Check for (name pattern
        if (text[i] == '(' and i + 1 + name.len <= text.len) {
            const start = i + 1;
            if (std.mem.eql(u8, text[start .. start + name.len], name)) {
                const end = start + name.len;
                if (end >= text.len or text[end] == ')' or text[end] == ':' or text[end] == ' ' or text[end] == '{') {
                    return protocol.Position{
                        .line = line,
                        .character = @intCast(start - line_start),
                    };
                }
            }
        }

        // Check for [name pattern
        if (text[i] == '[' and i + 1 + name.len <= text.len) {
            const start = i + 1;
            if (std.mem.eql(u8, text[start .. start + name.len], name)) {
                const end = start + name.len;
                if (end >= text.len or text[end] == ']' or text[end] == ':' or text[end] == ' ' or text[end] == '{' or text[end] == '*') {
                    return protocol.Position{
                        .line = line,
                        .character = @intCast(start - line_start),
                    };
                }
            }
        }

        i += 1;
    }

    return null;
}

// ============================================================================
// Document Symbols Provider
// CANARY: REQ=REQ-LSP-SYMBOLS-001; FEATURE="DocumentSymbols"; ASPECT=OutlineView; STATUS=IMPL; OWNER=lsp; UPDATED=2026-01-27
// ============================================================================

/// Provide document symbols for outline view
pub fn provideDocumentSymbols(allocator: Allocator, doc: *const Document) ![]protocol.DocumentSymbol {
    var symbols = std.ArrayList(protocol.DocumentSymbol).initCapacity(allocator, 16) catch return error.OutOfMemory;
    errdefer symbols.deinit(allocator);

    // Try to parse the document
    const outcome = geode.parseGqlOutcome(doc.text, allocator, .{}) catch {
        // Fall back to text-based symbol extraction on parse errors
        return try extractSymbolsFromText(allocator, doc);
    };

    switch (outcome) {
        .Ok => |result| {
            defer {
                var res = result;
                res.deinit();
            }

            // Extract symbols from the AST
            for (result.program.statements) |stmt| {
                try extractSymbolsFromStatement(allocator, &symbols, doc, stmt);
            }
        },
        .Err => {
            // Fall back to text-based extraction
            return try extractSymbolsFromText(allocator, doc);
        },
    }

    return symbols.toOwnedSlice(allocator);
}

fn extractSymbolsFromStatement(allocator: Allocator, symbols: *std.ArrayList(protocol.DocumentSymbol), doc: *const Document, stmt: anytype) !void {
    switch (stmt) {
        .Query => |query| {
            try extractSymbolsFromQuery(allocator, symbols, doc, query);
        },
        .Union => |union_q| {
            try extractSymbolsFromQuery(allocator, symbols, doc, union_q.first);
            for (union_q.tails) |part| {
                try extractSymbolsFromQuery(allocator, symbols, doc, part.query);
            }
        },
        else => {},
    }
}

fn extractSymbolsFromQuery(allocator: Allocator, symbols: *std.ArrayList(protocol.DocumentSymbol), doc: *const Document, query: anytype) !void {
    // Extract from LET bindings
    for (query.let_bindings) |binding| {
        if (findSymbolPosition(doc.text, binding.variable, .let_binding)) |pos| {
            try symbols.append(allocator, .{
                .name = binding.variable,
                .detail = "LET binding",
                .kind = .Variable,
                .range = pos.range,
                .selectionRange = pos.selectionRange,
            });
        }
    }

    for (query.inline_let_bindings) |binding| {
        if (findSymbolPosition(doc.text, binding.variable, .let_binding)) |pos| {
            try symbols.append(allocator, .{
                .name = binding.variable,
                .detail = "LET binding",
                .kind = .Variable,
                .range = pos.range,
                .selectionRange = pos.selectionRange,
            });
        }
    }

    // Extract from MATCH patterns
    for (query.match.chains) |chain| {
        // Path variable
        if (chain.name) |name| {
            if (findSymbolPosition(doc.text, name, .path_pattern)) |pos| {
                try symbols.append(allocator, .{
                    .name = name,
                    .detail = "Path variable",
                    .kind = .Variable,
                    .range = pos.range,
                    .selectionRange = pos.selectionRange,
                });
            }
        }

        // Head node
        if (chain.head) |head| {
            if (head.name) |name| {
                const label_detail = if (head.labels.len > 0)
                    head.labels[0]
                else
                    "Node";
                if (findSymbolPosition(doc.text, name, .node_pattern)) |pos| {
                    try symbols.append(allocator, .{
                        .name = name,
                        .detail = label_detail,
                        .kind = .Variable,
                        .range = pos.range,
                        .selectionRange = pos.selectionRange,
                    });
                }
            }
        }

        // Hops (relationships and nodes)
        for (chain.hops) |hop| {
            // Left node
            if (hop.left.name) |name| {
                const label_detail = if (hop.left.labels.len > 0)
                    hop.left.labels[0]
                else
                    "Node";
                if (findSymbolPosition(doc.text, name, .node_pattern)) |pos| {
                    try symbols.append(allocator, .{
                        .name = name,
                        .detail = label_detail,
                        .kind = .Variable,
                        .range = pos.range,
                        .selectionRange = pos.selectionRange,
                    });
                }
            }

            // Relationship
            if (hop.rel.name) |name| {
                const type_detail = if (hop.rel.types.len > 0)
                    hop.rel.types[0]
                else
                    "Relationship";
                if (findSymbolPosition(doc.text, name, .rel_pattern)) |pos| {
                    try symbols.append(allocator, .{
                        .name = name,
                        .detail = type_detail,
                        .kind = .Property,
                        .range = pos.range,
                        .selectionRange = pos.selectionRange,
                    });
                }
            }

            // Right node
            if (hop.right.name) |name| {
                const label_detail = if (hop.right.labels.len > 0)
                    hop.right.labels[0]
                else
                    "Node";
                if (findSymbolPosition(doc.text, name, .node_pattern)) |pos| {
                    try symbols.append(allocator, .{
                        .name = name,
                        .detail = label_detail,
                        .kind = .Variable,
                        .range = pos.range,
                        .selectionRange = pos.selectionRange,
                    });
                }
            }
        }
    }

    // Extract from WITH clause aliases
    if (query.with_clause) |with| {
        for (with.items) |item| {
            if (item.alias) |alias| {
                if (findSymbolPosition(doc.text, alias, .with_alias)) |pos| {
                    try symbols.append(allocator, .{
                        .name = alias,
                        .detail = "WITH alias",
                        .kind = .Variable,
                        .range = pos.range,
                        .selectionRange = pos.selectionRange,
                    });
                }
            }
        }
    }

    // Extract from RETURN aliases
    for (query.ret.items) |item| {
        if (item.alias) |alias| {
            if (findSymbolPosition(doc.text, alias, .return_alias)) |pos| {
                try symbols.append(allocator, .{
                    .name = alias,
                    .detail = "RETURN alias",
                    .kind = .Variable,
                    .range = pos.range,
                    .selectionRange = pos.selectionRange,
                });
            }
        }
    }

    // Recurse into next query
    if (query.next_query) |next| {
        try extractSymbolsFromQuery(allocator, symbols, doc, next.*);
    }
}

const SymbolSearchType = enum {
    node_pattern,
    rel_pattern,
    path_pattern,
    with_alias,
    return_alias,
    let_binding,
};

const SymbolPositionResult = struct {
    range: protocol.Range,
    selectionRange: protocol.Range,
};

fn findSymbolPosition(text: []const u8, name: []const u8, search_type: SymbolSearchType) ?SymbolPositionResult {
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    var in_string = false;
    var string_char: u8 = 0;

    while (i < text.len) {
        // Track newlines
        if (text[i] == '\n') {
            line += 1;
            line_start = i + 1;
            i += 1;
            continue;
        }

        // Skip strings
        if (!in_string and (text[i] == '\'' or text[i] == '"')) {
            in_string = true;
            string_char = text[i];
            i += 1;
            continue;
        }
        if (in_string) {
            if (text[i] == string_char and (i == 0 or text[i - 1] != '\\')) {
                in_string = false;
            }
            i += 1;
            continue;
        }

        // Check for pattern based on type
        const found_pos: ?usize = switch (search_type) {
            .node_pattern => findNodePatternForSymbol(text, i, name),
            .rel_pattern => findRelPatternForSymbol(text, i, name),
            .path_pattern => findPathPatternForSymbol(text, i, name),
            .with_alias, .return_alias => findAliasPatternForSymbol(text, i, name),
            .let_binding => findLetPatternForSymbol(text, i, name),
        };

        if (found_pos) |pos| {
            const char_start: u32 = @intCast(pos - line_start);
            const char_end: u32 = char_start + @as(u32, @intCast(name.len));
            return SymbolPositionResult{
                .range = .{
                    .start = .{ .line = line, .character = char_start },
                    .end = .{ .line = line, .character = char_end },
                },
                .selectionRange = .{
                    .start = .{ .line = line, .character = char_start },
                    .end = .{ .line = line, .character = char_end },
                },
            };
        }

        i += 1;
    }

    return null;
}

fn findNodePatternForSymbol(text: []const u8, pos: usize, name: []const u8) ?usize {
    if (pos >= text.len or text[pos] != '(') return null;
    var i = pos + 1;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    if (i + name.len > text.len) return null;
    if (!std.mem.eql(u8, text[i .. i + name.len], name)) return null;
    const end = i + name.len;
    if (end >= text.len) return null;
    const next = text[end];
    if (next == ')' or next == ':' or next == ' ' or next == '\t' or next == '{') return i;
    return null;
}

fn findRelPatternForSymbol(text: []const u8, pos: usize, name: []const u8) ?usize {
    if (pos >= text.len or text[pos] != '[') return null;
    var i = pos + 1;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    if (i + name.len > text.len) return null;
    if (!std.mem.eql(u8, text[i .. i + name.len], name)) return null;
    const end = i + name.len;
    if (end >= text.len) return null;
    const next = text[end];
    if (next == ']' or next == ':' or next == ' ' or next == '\t' or next == '{' or next == '*') return i;
    return null;
}

fn findPathPatternForSymbol(text: []const u8, pos: usize, name: []const u8) ?usize {
    // Look for "name = (" pattern
    if (pos + name.len + 3 > text.len) return null;
    if (!std.mem.eql(u8, text[pos .. pos + name.len], name)) return null;
    var i = pos + name.len;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    if (i >= text.len or text[i] != '=') return null;
    i += 1;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    if (i >= text.len or text[i] != '(') return null;
    // Check word boundary before name
    if (pos > 0 and std.ascii.isAlphanumeric(text[pos - 1])) return null;
    return pos;
}

fn findAliasPatternForSymbol(text: []const u8, pos: usize, name: []const u8) ?usize {
    // Look for "AS name" pattern
    if (pos + 2 > text.len) return null;
    if (!std.ascii.eqlIgnoreCase(text[pos .. pos + 2], "AS")) return null;
    var i = pos + 2;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    if (i + name.len > text.len) return null;
    if (!std.mem.eql(u8, text[i .. i + name.len], name)) return null;
    const end = i + name.len;
    if (end < text.len and std.ascii.isAlphanumeric(text[end])) return null;
    return i;
}

fn findLetPatternForSymbol(text: []const u8, pos: usize, name: []const u8) ?usize {
    if (pos + 3 > text.len) return null;
    if (!std.ascii.eqlIgnoreCase(text[pos .. pos + 3], "LET")) return null;
    var i = pos + 3;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    // Skip $ if present
    if (i < text.len and text[i] == '$') i += 1;
    if (i + name.len > text.len) return null;
    if (!std.mem.eql(u8, text[i .. i + name.len], name)) return null;
    const end = i + name.len;
    if (end < text.len and std.ascii.isAlphanumeric(text[end])) return null;
    return i;
}

/// Fallback text-based symbol extraction when parsing fails
fn extractSymbolsFromText(allocator: Allocator, doc: *const Document) ![]protocol.DocumentSymbol {
    var symbols = std.ArrayList(protocol.DocumentSymbol).initCapacity(allocator, 16) catch return error.OutOfMemory;
    errdefer symbols.deinit(allocator);

    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    var in_string = false;
    var string_char: u8 = 0;

    while (i < doc.text.len) {
        if (doc.text[i] == '\n') {
            line += 1;
            line_start = i + 1;
            i += 1;
            continue;
        }

        // Skip strings
        if (!in_string and (doc.text[i] == '\'' or doc.text[i] == '"')) {
            in_string = true;
            string_char = doc.text[i];
            i += 1;
            continue;
        }
        if (in_string) {
            if (doc.text[i] == string_char and (i == 0 or doc.text[i - 1] != '\\')) {
                in_string = false;
            }
            i += 1;
            continue;
        }

        // Look for (varname pattern
        if (doc.text[i] == '(' and i + 1 < doc.text.len) {
            var j = i + 1;
            while (j < doc.text.len and (doc.text[j] == ' ' or doc.text[j] == '\t')) j += 1;
            if (j < doc.text.len and (std.ascii.isAlphabetic(doc.text[j]) or doc.text[j] == '_')) {
                const name_start = j;
                while (j < doc.text.len and (std.ascii.isAlphanumeric(doc.text[j]) or doc.text[j] == '_')) j += 1;
                const name = doc.text[name_start..j];
                if (name.len > 0 and j < doc.text.len and (doc.text[j] == ')' or doc.text[j] == ':' or doc.text[j] == ' ' or doc.text[j] == '{')) {
                    const char_start: u32 = @intCast(name_start - line_start);
                    const char_end: u32 = char_start + @as(u32, @intCast(name.len));
                    try symbols.append(allocator, .{
                        .name = name,
                        .detail = "Node",
                        .kind = .Variable,
                        .range = .{
                            .start = .{ .line = line, .character = char_start },
                            .end = .{ .line = line, .character = char_end },
                        },
                        .selectionRange = .{
                            .start = .{ .line = line, .character = char_start },
                            .end = .{ .line = line, .character = char_end },
                        },
                    });
                }
            }
        }

        // Look for [varname pattern
        if (doc.text[i] == '[' and i + 1 < doc.text.len) {
            var j = i + 1;
            while (j < doc.text.len and (doc.text[j] == ' ' or doc.text[j] == '\t')) j += 1;
            if (j < doc.text.len and (std.ascii.isAlphabetic(doc.text[j]) or doc.text[j] == '_')) {
                const name_start = j;
                while (j < doc.text.len and (std.ascii.isAlphanumeric(doc.text[j]) or doc.text[j] == '_')) j += 1;
                const name = doc.text[name_start..j];
                if (name.len > 0 and j < doc.text.len and (doc.text[j] == ']' or doc.text[j] == ':' or doc.text[j] == ' ' or doc.text[j] == '{' or doc.text[j] == '*')) {
                    const char_start: u32 = @intCast(name_start - line_start);
                    const char_end: u32 = char_start + @as(u32, @intCast(name.len));
                    try symbols.append(allocator, .{
                        .name = name,
                        .detail = "Relationship",
                        .kind = .Property,
                        .range = .{
                            .start = .{ .line = line, .character = char_start },
                            .end = .{ .line = line, .character = char_end },
                        },
                        .selectionRange = .{
                            .start = .{ .line = line, .character = char_start },
                            .end = .{ .line = line, .character = char_end },
                        },
                    });
                }
            }
        }

        i += 1;
    }

    return symbols.toOwnedSlice(allocator);
}

// ============================================================================
// Signature Help Provider
// CANARY: REQ=REQ-LSP-SIGHEP-001; FEATURE="SignatureHelp"; ASPECT=FunctionParams; STATUS=IMPL; OWNER=lsp; UPDATED=2026-01-27
// ============================================================================

/// Provide signature help for function calls
pub fn provideSignatureHelp(allocator: Allocator, doc: *const Document, line: u32, character: u32) !?protocol.SignatureHelp {
    const offset = doc.getOffset(line, character) orelse return null;

    // Find the opening parenthesis and function name
    var paren_depth: i32 = 0;
    var comma_count: u32 = 0;
    var paren_pos: ?usize = null;
    var i: usize = offset;
    var in_string = false;
    var string_char: u8 = 0;

    // Scan backwards to find the opening paren
    while (i > 0) {
        i -= 1;
        const c = doc.text[i];

        // Handle strings (scanning backwards)
        if (!in_string and (c == '\'' or c == '"')) {
            // Check if this is the end of a string
            var quote_count: usize = 0;
            var j = i;
            while (j > 0 and doc.text[j] == c) {
                quote_count += 1;
                j -= 1;
            }
            if (quote_count % 2 == 1) {
                in_string = true;
                string_char = c;
            }
            continue;
        }
        if (in_string and c == string_char) {
            in_string = false;
            continue;
        }
        if (in_string) continue;

        if (c == ')') {
            paren_depth += 1;
        } else if (c == '(') {
            if (paren_depth == 0) {
                paren_pos = i;
                break;
            }
            paren_depth -= 1;
        } else if (c == ',' and paren_depth == 0) {
            comma_count += 1;
        }
    }

    const open_paren = paren_pos orelse return null;

    // Find function name before the paren
    var name_end = open_paren;
    while (name_end > 0 and (doc.text[name_end - 1] == ' ' or doc.text[name_end - 1] == '\t')) {
        name_end -= 1;
    }

    var name_start = name_end;
    while (name_start > 0 and (std.ascii.isAlphanumeric(doc.text[name_start - 1]) or doc.text[name_start - 1] == '_')) {
        name_start -= 1;
    }

    if (name_start == name_end) return null;

    const func_name = doc.text[name_start..name_end];

    // Look up function in metadata
    const fn_info = language_metadata.findFunction(func_name) orelse return null;

    // Build parameter list
    var params = std.ArrayList(protocol.ParameterInformation).initCapacity(allocator, 8) catch return error.OutOfMemory;
    defer params.deinit(allocator);

    for (fn_info.params) |param| {
        var param_label = std.ArrayList(u8).initCapacity(allocator, 64) catch return error.OutOfMemory;
        defer param_label.deinit(allocator);

        try param_label.appendSlice(allocator, param.name);
        try param_label.appendSlice(allocator, ": ");
        try param_label.appendSlice(allocator, param.type_name);
        if (param.optional) {
            try param_label.append(allocator, '?');
        }

        try params.append(allocator, .{
            .label = try allocator.dupe(u8, param_label.items),
            .documentation = null,
        });
    }

    // Build signature label
    var sig_label = std.ArrayList(u8).initCapacity(allocator, 128) catch return error.OutOfMemory;
    defer sig_label.deinit(allocator);

    try sig_label.appendSlice(allocator, fn_info.name);
    try sig_label.append(allocator, '(');
    for (fn_info.params, 0..) |param, idx| {
        if (idx > 0) try sig_label.appendSlice(allocator, ", ");
        try sig_label.appendSlice(allocator, param.name);
        try sig_label.appendSlice(allocator, ": ");
        try sig_label.appendSlice(allocator, param.type_name);
        if (param.optional) try sig_label.append(allocator, '?');
    }
    try sig_label.appendSlice(allocator, ") → ");
    try sig_label.appendSlice(allocator, fn_info.return_type);

    // Create signature
    const signatures = try allocator.alloc(protocol.SignatureInformation, 1);
    signatures[0] = .{
        .label = try allocator.dupe(u8, sig_label.items),
        .documentation = .{
            .kind = .plaintext,
            .value = fn_info.doc,
        },
        .parameters = try allocator.dupe(protocol.ParameterInformation, params.items),
        .activeParameter = if (comma_count < fn_info.params.len) comma_count else null,
    };

    return protocol.SignatureHelp{
        .signatures = signatures,
        .activeSignature = 0,
        .activeParameter = if (comma_count < fn_info.params.len) comma_count else null,
    };
}

// ============================================================================
// References Provider
// CANARY: REQ=REQ-LSP-REFS-001; FEATURE="References"; ASPECT=FindAllRefs; STATUS=IMPL; OWNER=lsp; UPDATED=2026-01-27
// ============================================================================

/// Find all references to a symbol in the document
pub fn provideReferences(allocator: Allocator, doc: *const Document, line: u32, character: u32, include_declaration: bool) ![]protocol.Location {
    _ = include_declaration; // We always include declarations in our simple implementation

    const offset = doc.getOffset(line, character) orelse return &[_]protocol.Location{};
    const word = doc.getWordAt(offset) orelse return &[_]protocol.Location{};

    // Skip if it's a keyword, function, or type
    if (language_metadata.findKeyword(word) != null) return &[_]protocol.Location{};
    if (language_metadata.findFunction(word) != null) return &[_]protocol.Location{};
    if (language_metadata.findType(word) != null) return &[_]protocol.Location{};

    var locations = std.ArrayList(protocol.Location).initCapacity(allocator, 16) catch return error.OutOfMemory;
    errdefer locations.deinit(allocator);

    // Text-based search for all occurrences
    var current_line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    var in_string = false;
    var string_char: u8 = 0;

    while (i < doc.text.len) {
        if (doc.text[i] == '\n') {
            current_line += 1;
            line_start = i + 1;
            i += 1;
            continue;
        }

        // Skip strings
        if (!in_string and (doc.text[i] == '\'' or doc.text[i] == '"')) {
            in_string = true;
            string_char = doc.text[i];
            i += 1;
            continue;
        }
        if (in_string) {
            if (doc.text[i] == string_char and (i == 0 or doc.text[i - 1] != '\\')) {
                in_string = false;
            }
            i += 1;
            continue;
        }

        // Skip comments
        if (i + 1 < doc.text.len) {
            if ((doc.text[i] == '-' and doc.text[i + 1] == '-') or
                (doc.text[i] == '/' and doc.text[i + 1] == '/'))
            {
                while (i < doc.text.len and doc.text[i] != '\n') i += 1;
                continue;
            }
            if (doc.text[i] == '/' and doc.text[i + 1] == '*') {
                i += 2;
                while (i + 1 < doc.text.len and !(doc.text[i] == '*' and doc.text[i + 1] == '/')) {
                    if (doc.text[i] == '\n') {
                        current_line += 1;
                        line_start = i + 1;
                    }
                    i += 1;
                }
                i += 2;
                continue;
            }
        }

        // Check for word boundary and match
        if (i + word.len <= doc.text.len) {
            const at_word_start = i == 0 or !std.ascii.isAlphanumeric(doc.text[i - 1]) and doc.text[i - 1] != '_';
            if (at_word_start and std.mem.eql(u8, doc.text[i .. i + word.len], word)) {
                const end_pos = i + word.len;
                const at_word_end = end_pos >= doc.text.len or (!std.ascii.isAlphanumeric(doc.text[end_pos]) and doc.text[end_pos] != '_');

                if (at_word_end) {
                    try locations.append(allocator, .{
                        .uri = doc.uri,
                        .range = .{
                            .start = .{
                                .line = current_line,
                                .character = @intCast(i - line_start),
                            },
                            .end = .{
                                .line = current_line,
                                .character = @intCast(end_pos - line_start),
                            },
                        },
                    });
                    i = end_pos;
                    continue;
                }
            }
        }

        i += 1;
    }

    return locations.toOwnedSlice(allocator);
}

// ============================================================================
// Semantic Tokens Provider
// CANARY: REQ=REQ-LSP-SEMTOK-001; FEATURE="SemanticTokens"; ASPECT=SyntaxHighlight; STATUS=IMPL; OWNER=lsp; UPDATED=2026-01-27
// ============================================================================

/// Token types for semantic highlighting
const TokenType = enum(u32) {
    keyword = 0,
    function = 1,
    variable = 2,
    parameter = 3,
    type_ = 4,
    property = 5,
    string = 6,
    number = 7,
    comment = 8,
    operator = 9,
    label = 10,
};

/// Token modifiers for semantic highlighting
const TokenModifier = enum(u32) {
    definition = 0,
    defaultLibrary = 1,
    readonly = 2,
};

/// Provide semantic tokens for syntax highlighting
pub fn provideSemanticTokensFull(allocator: Allocator, doc: *const Document) !protocol.SemanticTokens {
    var tokens = std.ArrayList(u32).initCapacity(allocator, 256) catch return error.OutOfMemory;
    errdefer tokens.deinit(allocator);

    var prev_line: u32 = 0;
    var prev_char: u32 = 0;
    var current_line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;

    // Track defined variables for definition modifier
    var defined_vars = std.StringHashMap(void).init(allocator);
    defer defined_vars.deinit();

    while (i < doc.text.len) {
        if (doc.text[i] == '\n') {
            current_line += 1;
            line_start = i + 1;
            i += 1;
            continue;
        }

        // Handle comments
        if (i + 1 < doc.text.len) {
            if ((doc.text[i] == '-' and doc.text[i + 1] == '-') or
                (doc.text[i] == '/' and doc.text[i + 1] == '/'))
            {
                const start_char: u32 = @intCast(i - line_start);
                const comment_start = i;
                while (i < doc.text.len and doc.text[i] != '\n') i += 1;
                const comment_len: u32 = @intCast(i - comment_start);

                try addToken(allocator, &tokens, current_line, start_char, comment_len, .comment, 0, &prev_line, &prev_char);
                continue;
            }
            if (doc.text[i] == '/' and doc.text[i + 1] == '*') {
                const start_line = current_line;
                const start_char: u32 = @intCast(i - line_start);
                const comment_start = i;
                i += 2;
                while (i + 1 < doc.text.len and !(doc.text[i] == '*' and doc.text[i + 1] == '/')) {
                    if (doc.text[i] == '\n') {
                        current_line += 1;
                        line_start = i + 1;
                    }
                    i += 1;
                }
                if (i + 1 < doc.text.len) i += 2;

                // For multi-line comments, only emit one token for first line
                if (start_line == current_line) {
                    const comment_len: u32 = @intCast(i - comment_start);
                    try addToken(allocator, &tokens, start_line, start_char, comment_len, .comment, 0, &prev_line, &prev_char);
                }
                continue;
            }
        }

        // Handle strings
        if (doc.text[i] == '\'' or doc.text[i] == '"') {
            const quote = doc.text[i];
            const start_char: u32 = @intCast(i - line_start);
            const string_start = i;
            i += 1;
            while (i < doc.text.len and doc.text[i] != quote) {
                if (doc.text[i] == '\\' and i + 1 < doc.text.len) {
                    i += 2;
                } else if (doc.text[i] == '\n') {
                    // Multi-line string - emit token for current line only
                    const string_len: u32 = @intCast(i - string_start);
                    try addToken(allocator, &tokens, current_line, start_char, string_len, .string, 0, &prev_line, &prev_char);
                    current_line += 1;
                    line_start = i + 1;
                    i += 1;
                    continue;
                } else {
                    i += 1;
                }
            }
            if (i < doc.text.len) i += 1;
            const string_len: u32 = @intCast(i - string_start);
            try addToken(allocator, &tokens, current_line, start_char, string_len, .string, 0, &prev_line, &prev_char);
            continue;
        }

        // Handle parameters ($name)
        if (doc.text[i] == '$') {
            const start_char: u32 = @intCast(i - line_start);
            const param_start = i;
            i += 1;
            while (i < doc.text.len and (std.ascii.isAlphanumeric(doc.text[i]) or doc.text[i] == '_')) {
                i += 1;
            }
            const param_len: u32 = @intCast(i - param_start);
            if (param_len > 1) {
                try addToken(allocator, &tokens, current_line, start_char, param_len, .parameter, 0, &prev_line, &prev_char);
            }
            continue;
        }

        // Handle numbers
        if (std.ascii.isDigit(doc.text[i]) or (doc.text[i] == '.' and i + 1 < doc.text.len and std.ascii.isDigit(doc.text[i + 1]))) {
            const start_char: u32 = @intCast(i - line_start);
            const num_start = i;
            // Integer or float
            while (i < doc.text.len and (std.ascii.isDigit(doc.text[i]) or doc.text[i] == '.' or doc.text[i] == 'e' or doc.text[i] == 'E' or doc.text[i] == '-' or doc.text[i] == '+')) {
                i += 1;
            }
            const num_len: u32 = @intCast(i - num_start);
            try addToken(allocator, &tokens, current_line, start_char, num_len, .number, 0, &prev_line, &prev_char);
            continue;
        }

        // Handle identifiers
        if (std.ascii.isAlphabetic(doc.text[i]) or doc.text[i] == '_') {
            const start_char: u32 = @intCast(i - line_start);
            const id_start = i;
            while (i < doc.text.len and (std.ascii.isAlphanumeric(doc.text[i]) or doc.text[i] == '_')) {
                i += 1;
            }
            const identifier = doc.text[id_start..i];
            const id_len: u32 = @intCast(identifier.len);

            // Check if it's a label (preceded by colon in node/rel pattern)
            var is_label = false;
            if (id_start > 0) {
                var j = id_start - 1;
                while (j > 0 and (doc.text[j] == ' ' or doc.text[j] == '\t')) j -= 1;
                if (doc.text[j] == ':') {
                    // Check if we're in a node or relationship pattern
                    var k = j;
                    while (k > 0) {
                        k -= 1;
                        if (doc.text[k] == '(' or doc.text[k] == '[') {
                            is_label = true;
                            break;
                        }
                        if (doc.text[k] == ')' or doc.text[k] == ']' or doc.text[k] == '\n') {
                            break;
                        }
                    }
                }
            }

            if (is_label) {
                try addToken(allocator, &tokens, current_line, start_char, id_len, .label, 0, &prev_line, &prev_char);
            } else if (language_metadata.findFunction(identifier) != null) {
                // Function - check if followed by (
                var j = i;
                while (j < doc.text.len and (doc.text[j] == ' ' or doc.text[j] == '\t')) j += 1;
                if (j < doc.text.len and doc.text[j] == '(') {
                    try addToken(allocator, &tokens, current_line, start_char, id_len, .function, 1 << @intFromEnum(TokenModifier.defaultLibrary), &prev_line, &prev_char);
                } else {
                    // Could be a variable named same as function
                    try addToken(allocator, &tokens, current_line, start_char, id_len, .variable, 0, &prev_line, &prev_char);
                }
            } else if (language_metadata.findKeyword(identifier) != null) {
                try addToken(allocator, &tokens, current_line, start_char, id_len, .keyword, 0, &prev_line, &prev_char);
            } else if (language_metadata.findType(identifier) != null) {
                try addToken(allocator, &tokens, current_line, start_char, id_len, .type_, 0, &prev_line, &prev_char);
            } else {
                // Check if this is a variable definition (in node/rel pattern or after AS)
                var is_definition = false;
                if (id_start > 0) {
                    var j = id_start - 1;
                    while (j > 0 and (doc.text[j] == ' ' or doc.text[j] == '\t')) j -= 1;
                    if (doc.text[j] == '(' or doc.text[j] == '[') {
                        is_definition = !defined_vars.contains(identifier);
                    }
                }

                // Check if it's a property access (preceded by .)
                var is_property = false;
                if (id_start > 0) {
                    var j = id_start - 1;
                    while (j > 0 and (doc.text[j] == ' ' or doc.text[j] == '\t')) j -= 1;
                    if (doc.text[j] == '.') {
                        is_property = true;
                    }
                }

                if (is_property) {
                    try addToken(allocator, &tokens, current_line, start_char, id_len, .property, 0, &prev_line, &prev_char);
                } else {
                    const modifier: u32 = if (is_definition) 1 << @intFromEnum(TokenModifier.definition) else 0;
                    if (is_definition) {
                        try defined_vars.put(identifier, {});
                    }
                    try addToken(allocator, &tokens, current_line, start_char, id_len, .variable, modifier, &prev_line, &prev_char);
                }
            }
            continue;
        }

        i += 1;
    }

    return protocol.SemanticTokens{
        .data = try tokens.toOwnedSlice(allocator),
    };
}

fn addToken(
    allocator: Allocator,
    tokens: *std.ArrayList(u32),
    line: u32,
    char: u32,
    length: u32,
    token_type: TokenType,
    modifiers: u32,
    prev_line: *u32,
    prev_char: *u32,
) !void {
    const delta_line = line - prev_line.*;
    const delta_char = if (delta_line == 0) char - prev_char.* else char;

    try tokens.append(allocator, delta_line);
    try tokens.append(allocator, delta_char);
    try tokens.append(allocator, length);
    try tokens.append(allocator, @intFromEnum(token_type));
    try tokens.append(allocator, modifiers);

    prev_line.* = line;
    prev_char.* = char;
}

/// Format a GQL document with proper keyword casing, indentation, and spacing.
/// If options is null, uses default options (which enables property map folding).
pub fn provideFormatting(allocator: Allocator, doc: *const Document) !?[]const u8 {
    return provideFormattingWithOptions(allocator, doc, .{});
}

/// Format a GQL document with custom formatting options.
pub fn provideFormattingWithOptions(allocator: Allocator, doc: *const Document, options: FormattingOptions) !?[]const u8 {
    const text = doc.text;
    if (text.len == 0) return null;

    // First pass: basic formatting (keyword casing, newlines before clauses, statement separation)
    const basic_formatted = try formatBasic(allocator, text) orelse return null;
    defer allocator.free(basic_formatted);

    // Second pass: fold property maps if enabled
    const folded = if (options.fold_property_maps)
        try foldPropertyMaps(allocator, basic_formatted, options)
    else
        try allocator.dupe(u8, basic_formatted);
    defer allocator.free(folded);

    // Third pass: apply proper indentation (CASE/WHEN, multi-line RETURN, subqueries)
    return try applyIndentation(allocator, folded, options.indent_size);
}

/// Fold property maps onto multiple lines for better readability.
fn foldPropertyMaps(allocator: Allocator, text: []const u8, options: FormattingOptions) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, text.len * 2);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    var current_indent: usize = 0;
    var in_string = false;
    var string_char: u8 = 0;

    while (i < text.len) {
        const c = text[i];

        // Track indentation at start of lines
        if (i == 0 or (i > 0 and text[i - 1] == '\n')) {
            current_indent = 0;
            var j = i;
            while (j < text.len and text[j] == ' ') : (j += 1) {
                current_indent += 1;
            }
        }

        // Handle string literals
        if (!in_string and (c == '\'' or c == '"')) {
            in_string = true;
            string_char = c;
            try result.append(allocator, c);
            i += 1;
            continue;
        }

        if (in_string) {
            try result.append(allocator, c);
            if (c == string_char and (i == 0 or text[i - 1] != '\\')) {
                in_string = false;
            }
            i += 1;
            continue;
        }

        // Handle property maps
        if (c == '{') {
            // Find matching closing brace
            const brace_end = findMatchingBrace(text, i);
            if (brace_end) |end| {
                const property_map = text[i .. end + 1];
                const property_count = countProperties(property_map);

                // Check if we should fold this property map
                const should_fold = property_count >= options.min_properties_to_fold or
                    (result.items.len > 0 and getLineLength(result.items) + property_map.len > options.max_line_length);

                if (should_fold and property_count > 0) {
                    // Fold the property map
                    try foldPropertyMap(allocator, &result, property_map, current_indent, options);
                    i = end + 1;
                    continue;
                }
            }
        }

        try result.append(allocator, c);
        i += 1;
    }

    return try result.toOwnedSlice(allocator);
}

/// Find the matching closing brace for an opening brace.
fn findMatchingBrace(text: []const u8, start: usize) ?usize {
    if (start >= text.len or text[start] != '{') return null;

    var depth: usize = 0;
    var i = start;
    var in_string = false;
    var string_char: u8 = 0;

    while (i < text.len) {
        const c = text[i];

        if (!in_string and (c == '\'' or c == '"')) {
            in_string = true;
            string_char = c;
        } else if (in_string and c == string_char and (i == 0 or text[i - 1] != '\\')) {
            in_string = false;
        } else if (!in_string) {
            if (c == '{') depth += 1;
            if (c == '}') {
                depth -= 1;
                if (depth == 0) return i;
            }
        }
        i += 1;
    }
    return null;
}

/// Count the number of properties in a property map.
fn countProperties(property_map: []const u8) usize {
    if (property_map.len < 2) return 0;

    var count: usize = 0;
    var in_string = false;
    var string_char: u8 = 0;
    var depth: usize = 0;
    var has_content = false;

    for (property_map, 0..) |c, i| {
        if (!in_string and (c == '\'' or c == '"')) {
            in_string = true;
            string_char = c;
            has_content = true;
        } else if (in_string and c == string_char and (i == 0 or property_map[i - 1] != '\\')) {
            in_string = false;
        } else if (!in_string) {
            if (c == '{' or c == '[' or c == '(') depth += 1;
            if (c == '}' or c == ']' or c == ')') {
                if (depth > 0) depth -= 1;
            }
            if (c == ',' and depth == 1) {
                count += 1;
            }
            if (c == ':' and depth == 1) {
                has_content = true;
            }
        }
    }

    // If we have content but no commas, that's one property
    if (has_content and count == 0) return 1;
    // Otherwise, count + 1 for the last property
    return if (count > 0) count + 1 else 0;
}

/// Get the length of the current line (from the last newline to end).
fn getLineLength(items: []const u8) usize {
    var len: usize = 0;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        if (items[i] == '\n') break;
        len += 1;
    }
    return len;
}

/// Fold a property map onto multiple lines.
fn foldPropertyMap(allocator: Allocator, result: *std.ArrayList(u8), property_map: []const u8, base_indent: usize, options: FormattingOptions) !void {
    const indent_str = "    "; // 4 spaces per level
    const prop_indent = options.indent_size;

    // Opening brace
    try result.append(allocator, '{');
    try result.append(allocator, '\n');

    // Add base indent + one level for properties
    for (0..base_indent) |_| {
        try result.append(allocator, ' ');
    }
    for (0..prop_indent) |_| {
        try result.append(allocator, ' ');
    }
    _ = indent_str;

    // Parse and add each property on its own line
    var in_string = false;
    var string_char: u8 = 0;
    var depth: usize = 0;
    var i: usize = 1; // Skip opening brace
    var prop_start: usize = 1;

    while (i < property_map.len) {
        const c = property_map[i];

        if (!in_string and (c == '\'' or c == '"')) {
            in_string = true;
            string_char = c;
        } else if (in_string and c == string_char and (i == 0 or property_map[i - 1] != '\\')) {
            in_string = false;
        } else if (!in_string) {
            if (c == '{' or c == '[' or c == '(') depth += 1;
            if (c == '}' or c == ']' or c == ')') {
                if (depth > 0) {
                    depth -= 1;
                } else {
                    // End of property map - add last property
                    const prop = std.mem.trim(u8, property_map[prop_start..i], " \t\n\r");
                    if (prop.len > 0) {
                        try result.appendSlice(allocator, prop);
                        try result.append(allocator, '\n');
                    }
                    // Add closing brace with base indent
                    for (0..base_indent) |_| {
                        try result.append(allocator, ' ');
                    }
                    try result.append(allocator, '}');
                    return;
                }
            }
            if (c == ',' and depth == 0) {
                // Property separator - add this property
                const prop = std.mem.trim(u8, property_map[prop_start..i], " \t\n\r");
                if (prop.len > 0) {
                    try result.appendSlice(allocator, prop);
                    try result.append(allocator, ',');
                    try result.append(allocator, '\n');
                    // Add indent for next property
                    for (0..base_indent) |_| {
                        try result.append(allocator, ' ');
                    }
                    for (0..prop_indent) |_| {
                        try result.append(allocator, ' ');
                    }
                }
                prop_start = i + 1;
            }
        }
        i += 1;
    }
}

/// Apply proper indentation to formatted GQL code.
/// Handles CASE/WHEN/ELSE/END, multi-line RETURN items, and subqueries.
fn applyIndentation(allocator: Allocator, text: []const u8, indent_size: u32) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, text.len * 2);
    errdefer result.deinit(allocator);

    const indent_str = "    "; // 4 spaces per level
    _ = indent_size; // Use fixed 4 spaces for now

    const base_indent: usize = 0;
    var case_depth: usize = 0;
    var brace_depth: usize = 0;
    var paren_depth: usize = 0;
    var in_return_list = false;
    var in_string = false;
    var string_char: u8 = 0;

    // Process line by line
    var line_start: usize = 0;
    var pos: usize = 0;

    while (pos <= text.len) {
        // Find end of current line
        const is_end = pos == text.len;
        const is_newline = !is_end and text[pos] == '\n';

        if (is_newline or is_end) {
            const line = text[line_start..pos];
            const trimmed = std.mem.trim(u8, line, " \t");

            // Skip empty lines
            if (trimmed.len == 0) {
                try result.append(allocator, '\n');
                line_start = pos + 1;
                pos += 1;
                continue;
            }

            // Check for keywords that affect indentation
            var upper_buf: [64]u8 = undefined;
            const check_len = @min(trimmed.len, 10);
            var first_word_end: usize = 0;
            for (trimmed[0..check_len], 0..) |c, idx| {
                if (!std.ascii.isAlphabetic(c) and c != '_') {
                    first_word_end = idx;
                    break;
                }
                upper_buf[idx] = std.ascii.toUpper(c);
                first_word_end = idx + 1;
            }
            const first_word = upper_buf[0..first_word_end];

            // Adjust indent before writing the line
            var this_line_indent = base_indent;

            // WHEN/ELSE get extra indent inside CASE
            if (case_depth > 0 and (std.mem.eql(u8, first_word, "WHEN") or std.mem.eql(u8, first_word, "ELSE"))) {
                this_line_indent = base_indent + 1;
            }

            // Continuation lines (lines starting with comma-separated items after RETURN)
            if (in_return_list and !isClauseKeyword(first_word) and trimmed.len > 0 and trimmed[0] != '-') {
                this_line_indent = base_indent + 1;
            }

            // Lines inside braces (subqueries)
            if (brace_depth > 0 and trimmed[0] != '}') {
                this_line_indent = base_indent + brace_depth;
            }

            // Write indentation
            for (0..this_line_indent) |_| {
                try result.appendSlice(allocator, indent_str);
            }

            // Write the line content
            try result.appendSlice(allocator, trimmed);
            try result.append(allocator, '\n');

            // Update state for next line
            var i: usize = 0;
            in_string = false;
            while (i < trimmed.len) {
                const c = trimmed[i];

                // Handle strings
                if (!in_string and (c == '\'' or c == '"')) {
                    in_string = true;
                    string_char = c;
                    i += 1;
                    continue;
                }
                if (in_string) {
                    if (c == string_char and (i == 0 or trimmed[i - 1] != '\\')) {
                        in_string = false;
                    }
                    i += 1;
                    continue;
                }

                // Track braces and parens
                if (c == '{') brace_depth += 1;
                if (c == '}' and brace_depth > 0) brace_depth -= 1;
                if (c == '(') paren_depth += 1;
                if (c == ')' and paren_depth > 0) paren_depth -= 1;

                // Check for CASE keyword
                if (i + 4 <= trimmed.len and std.ascii.eqlIgnoreCase(trimmed[i .. i + 4], "CASE")) {
                    if (i + 4 >= trimmed.len or !std.ascii.isAlphanumeric(trimmed[i + 4])) {
                        case_depth += 1;
                    }
                }

                // Check for END keyword
                if (i + 3 <= trimmed.len and std.ascii.eqlIgnoreCase(trimmed[i .. i + 3], "END")) {
                    if ((i == 0 or !std.ascii.isAlphanumeric(trimmed[i - 1])) and
                        (i + 3 >= trimmed.len or !std.ascii.isAlphanumeric(trimmed[i + 3])))
                    {
                        if (case_depth > 0) case_depth -= 1;
                    }
                }

                i += 1;
            }

            // Track RETURN clause for multi-line items
            if (std.mem.eql(u8, first_word, "RETURN") or std.mem.eql(u8, first_word, "WITH")) {
                const last_char = if (trimmed.len > 0) trimmed[trimmed.len - 1] else ' ';
                in_return_list = (last_char == ',');
            } else if (isClauseKeyword(first_word)) {
                in_return_list = false;
            } else if (in_return_list) {
                const last_char = if (trimmed.len > 0) trimmed[trimmed.len - 1] else ' ';
                in_return_list = (last_char == ',');
            }

            line_start = pos + 1;
        }

        if (is_end) break;
        pos += 1;
    }

    // Trim trailing newlines except for one
    while (result.items.len > 1 and
        result.items[result.items.len - 1] == '\n' and
        result.items[result.items.len - 2] == '\n')
    {
        _ = result.pop();
    }

    return try result.toOwnedSlice(allocator);
}

/// Suppress unused variable warning
fn suppressUnused(x: anytype) void {
    _ = x;
}

fn isClauseKeyword(word: []const u8) bool {
    // GQL clause-starting keywords (ISO/IEC 39075:2024)
    const clause_keywords = [_][]const u8{
        "MATCH",    "CREATE",    "INSERT", "DELETE",
        "RETURN",   "WHERE",     "WITH",   "SET",
        "ORDER",    "GROUP",     "HAVING", "LIMIT",
        "OFFSET",   "UNION",     "EXCEPT", "CALL",
        "USE",      "DROP",      "SHOW",   "DETACH",
        "OPTIONAL", "INTERSECT", "LET",    "FOR",
        "FILTER",   "NEXT",
    };
    for (clause_keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

/// Basic formatting: keyword casing and newlines before clause keywords.
fn formatBasic(allocator: Allocator, text: []const u8) !?[]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, text.len);
    errdefer result.deinit(allocator);

    // Keywords that should start on a new line (clause starters)
    const line_start_keywords = std.StaticStringMap(void).initComptime(.{
        .{ "MATCH", {} },
        .{ "CREATE", {} },
        .{ "MERGE", {} },
        .{ "DELETE", {} },
        .{ "INSERT", {} },
        .{ "RETURN", {} },
        .{ "WHERE", {} },
        .{ "WITH", {} },
        .{ "SET", {} },
        .{ "REMOVE", {} },
        .{ "ORDER", {} },
        .{ "GROUP", {} },
        .{ "HAVING", {} },
        .{ "LIMIT", {} },
        .{ "SKIP", {} },
        .{ "OFFSET", {} },
        .{ "UNION", {} },
        .{ "INTERSECT", {} },
        .{ "EXCEPT", {} },
        .{ "OPTIONAL", {} },
        .{ "CALL", {} },
        .{ "UNWIND", {} },
        .{ "USE", {} },
        .{ "DROP", {} },
        .{ "SHOW", {} },
        .{ "EXPLAIN", {} },
        .{ "PROFILE", {} },
        .{ "DETACH", {} },
    });

    var i: usize = 0;
    var line_start = true;
    var in_string = false;
    var string_char: u8 = 0;
    var last_was_newline = true;
    var last_was_space = false;
    var last_was_comment = false; // Track if previous line was a comment (for comment groups)

    while (i < text.len) {
        const c = text[i];

        // Handle string literals
        if (!in_string and (c == '\'' or c == '"')) {
            in_string = true;
            string_char = c;
            try result.append(allocator, c);
            last_was_space = false;
            last_was_newline = false;
            i += 1;
            continue;
        }

        if (in_string) {
            try result.append(allocator, c);
            if (c == string_char and (i == 0 or text[i - 1] != '\\')) {
                in_string = false;
            }
            if (c == '\n') {
                last_was_newline = true;
                last_was_space = false;
            } else {
                last_was_newline = false;
                last_was_space = false;
            }
            i += 1;
            continue;
        }

        // Handle comments
        if (i + 1 < text.len) {
            // Single-line comment
            if ((c == '-' and text[i + 1] == '-') or (c == '/' and text[i + 1] == '/')) {
                // Add blank line before comment if:
                // - Not at start of file
                // - Previous line was NOT a comment (keep comment groups together)
                // - Not already preceded by blank line
                if (result.items.len > 0 and !last_was_comment) {
                    if (!last_was_newline) {
                        // Trim trailing space before adding newlines
                        while (result.items.len > 0 and result.items[result.items.len - 1] == ' ') {
                            _ = result.pop();
                        }
                        try result.append(allocator, '\n');
                        try result.append(allocator, '\n');
                    } else {
                        // Check if we already have a blank line (double newline)
                        const has_blank_line = result.items.len >= 2 and
                            result.items[result.items.len - 1] == '\n' and
                            result.items[result.items.len - 2] == '\n';
                        if (!has_blank_line) {
                            try result.append(allocator, '\n');
                        }
                    }
                }
                // Copy until newline
                while (i < text.len and text[i] != '\n') {
                    try result.append(allocator, text[i]);
                    i += 1;
                }
                if (i < text.len) {
                    try result.append(allocator, '\n');
                    i += 1;
                    last_was_newline = true;
                    last_was_space = false;
                    last_was_comment = true; // Mark that we just processed a comment
                    line_start = true;
                }
                continue;
            }
            // Multi-line comment
            if (c == '/' and text[i + 1] == '*') {
                // Add blank line before comment if:
                // - Not at start of file
                // - Previous line was NOT a comment (keep comment groups together)
                // - Not already preceded by blank line
                if (result.items.len > 0 and !last_was_comment) {
                    if (!last_was_newline) {
                        while (result.items.len > 0 and result.items[result.items.len - 1] == ' ') {
                            _ = result.pop();
                        }
                        try result.append(allocator, '\n');
                        try result.append(allocator, '\n');
                    } else {
                        const has_blank_line = result.items.len >= 2 and
                            result.items[result.items.len - 1] == '\n' and
                            result.items[result.items.len - 2] == '\n';
                        if (!has_blank_line) {
                            try result.append(allocator, '\n');
                        }
                    }
                }
                try result.append(allocator, '/');
                try result.append(allocator, '*');
                i += 2;
                while (i + 1 < text.len) {
                    if (text[i] == '*' and text[i + 1] == '/') {
                        try result.append(allocator, '*');
                        try result.append(allocator, '/');
                        i += 2;
                        break;
                    }
                    try result.append(allocator, text[i]);
                    i += 1;
                }
                last_was_space = false;
                last_was_newline = false;
                last_was_comment = true; // Mark that we just processed a comment
                continue;
            }
        }

        // Handle newlines
        if (c == '\n') {
            // Avoid multiple consecutive blank lines
            if (!last_was_newline or result.items.len == 0) {
                try result.append(allocator, '\n');
            }
            last_was_newline = true;
            last_was_space = false;
            line_start = true;
            i += 1;
            continue;
        }

        // Handle whitespace
        if (std.ascii.isWhitespace(c)) {
            if (!last_was_space and !last_was_newline and result.items.len > 0) {
                try result.append(allocator, ' ');
                last_was_space = true;
            }
            i += 1;
            continue;
        }

        // Handle identifiers and keywords
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = i;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) {
                i += 1;
            }
            const word = text[start..i];

            // Check if it's a keyword
            var upper_buf: [64]u8 = undefined;
            const upper_len = @min(word.len, 64);
            for (word[0..upper_len], 0..) |ch, j| {
                upper_buf[j] = std.ascii.toUpper(ch);
            }
            const upper_word = upper_buf[0..upper_len];

            // Check if this word is a known function (case-sensitive check)
            const is_known_function = for (GQL_FUNCTIONS) |func| {
                if (std.mem.eql(u8, word, func)) break true;
            } else false;

            // Check if it's a keyword only if it's NOT a known function name
            // This ensures that functions like count(), all(), any() don't get uppercased
            // even when they match keyword patterns like "ALL" for "UNION ALL"
            const is_keyword = if (is_known_function)
                false
            else for (GQL_KEYWORDS) |kw| {
                if (std.mem.eql(u8, upper_word, kw)) break true;
            } else false;

            // Check if this is a clause-starting keyword that needs a newline before it
            var needs_newline = line_start_keywords.get(upper_word) != null;

            // Suppress newline if this is part of a compound keyword (e.g., OPTIONAL MATCH, DETACH DELETE)
            // Look back in result buffer to see if previous word was a compound prefix
            if (needs_newline and result.items.len > 0) {
                // Check for "OPTIONAL " before MATCH
                if (std.mem.eql(u8, upper_word, "MATCH") and result.items.len >= 9) {
                    const suffix = result.items[result.items.len - 9 ..];
                    if (std.mem.eql(u8, suffix, "OPTIONAL ")) {
                        needs_newline = false;
                    }
                }
                // Check for "DETACH " before DELETE
                if (std.mem.eql(u8, upper_word, "DELETE") and result.items.len >= 7) {
                    const suffix = result.items[result.items.len - 7 ..];
                    if (std.mem.eql(u8, suffix, "DETACH ")) {
                        needs_newline = false;
                    }
                }
            }

            if (needs_newline and !last_was_newline and result.items.len > 0) {
                // Trim trailing space before newline
                while (result.items.len > 0 and result.items[result.items.len - 1] == ' ') {
                    _ = result.pop();
                }
                try result.append(allocator, '\n');
                last_was_newline = true;
                last_was_space = false;
            }

            if (is_keyword) {
                // Output uppercase keyword
                try result.appendSlice(allocator, upper_word);
            } else {
                // Preserve original case for non-keywords
                try result.appendSlice(allocator, word);
            }

            last_was_space = false;
            last_was_newline = false;
            last_was_comment = false; // Reset comment flag when processing non-comment content
            line_start = false;
            continue;
        }

        // Handle other characters (punctuation, operators, etc.)
        try result.append(allocator, c);
        last_was_space = false;
        last_was_newline = (c == '\n');

        // Add blank line after semicolon to separate statements
        if (c == ';') {
            try result.append(allocator, '\n');
            // Skip whitespace and newlines to find next meaningful content
            var peek = i + 1;
            while (peek < text.len and (text[peek] == ' ' or text[peek] == '\t' or text[peek] == '\r' or text[peek] == '\n')) {
                peek += 1;
            }
            // Add blank line unless next thing is a comment (comments provide their own separation)
            // or we've reached end of file
            if (peek < text.len and
                !(peek + 1 < text.len and text[peek] == '-' and text[peek + 1] == '-') and
                !(peek + 1 < text.len and text[peek] == '/' and text[peek + 1] == '/'))
            {
                try result.append(allocator, '\n');
            }
            last_was_newline = true;
            line_start = true;
        }

        i += 1;
    }

    // Trim trailing whitespace
    while (result.items.len > 0 and std.ascii.isWhitespace(result.items[result.items.len - 1])) {
        _ = result.pop();
    }

    // Ensure file ends with newline
    if (result.items.len > 0) {
        try result.append(allocator, '\n');
    }

    return try result.toOwnedSlice(allocator);
}

// NOTE: Old documentation functions removed in favor of metadata-based formatXXXHover functions
// See formatKeywordHover, formatFunctionHover, formatTypeHover, formatProcedureHover above

// ============================================================================
// Unit Tests for Formatting
// ============================================================================

test "provideFormatting - keyword uppercasing" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "match (n) return n", 1);
    defer doc.deinit();

    const result = try provideFormatting(allocator, doc);
    defer if (result) |r| allocator.free(r);

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("MATCH (n)\nRETURN n\n", result.?);
}

test "provideFormatting - preserves string literals" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "match (n {name: 'match me'}) return n", 1);
    defer doc.deinit();

    const result = try provideFormatting(allocator, doc);
    defer if (result) |r| allocator.free(r);

    try std.testing.expect(result != null);
    // Keywords should be uppercased but 'match me' inside string should be preserved
    try std.testing.expect(std.mem.indexOf(u8, result.?, "'match me'") != null);
}

test "provideFormatting - preserves comments" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "-- comment here\nmatch (n) return n", 1);
    defer doc.deinit();

    const result = try provideFormatting(allocator, doc);
    defer if (result) |r| allocator.free(r);

    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "-- comment here") != null);
}

test "provideFormatting - multiline comment preserved" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "/* block\ncomment */ match (n) return n", 1);
    defer doc.deinit();

    const result = try provideFormatting(allocator, doc);
    defer if (result) |r| allocator.free(r);

    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "/* block") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "comment */") != null);
}

test "provideFormatting - newlines before clause keywords" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "match (n) where n.x > 1 return n", 1);
    defer doc.deinit();

    const result = try provideFormatting(allocator, doc);
    defer if (result) |r| allocator.free(r);

    try std.testing.expect(result != null);
    // WHERE and RETURN should start on new lines
    try std.testing.expect(std.mem.indexOf(u8, result.?, "\nWHERE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "\nRETURN") != null);
}

test "provideFormatting - empty document" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "", 1);
    defer doc.deinit();

    const result = try provideFormatting(allocator, doc);
    try std.testing.expect(result == null);
}

test "provideFormatting - variable names preserved" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "match (myNode:Person) return myNode", 1);
    defer doc.deinit();

    const result = try provideFormatting(allocator, doc);
    defer if (result) |r| allocator.free(r);

    try std.testing.expect(result != null);
    // Variable names should preserve original case
    try std.testing.expect(std.mem.indexOf(u8, result.?, "myNode") != null);
}

// ============================================================================
// Unit Tests for Document Symbols
// ============================================================================

test "provideDocumentSymbols - extracts node variables" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "MATCH (n:Person) RETURN n", 1);
    defer doc.deinit();

    const symbols = try provideDocumentSymbols(allocator, doc);
    defer allocator.free(symbols);

    try std.testing.expect(symbols.len >= 1);
    try std.testing.expectEqualStrings("n", symbols[0].name);
    try std.testing.expect(symbols[0].kind == .Variable);
}

test "provideDocumentSymbols - extracts relationship variables" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "MATCH (a)-[r:KNOWS]->(b) RETURN r", 1);
    defer doc.deinit();

    const symbols = try provideDocumentSymbols(allocator, doc);
    defer allocator.free(symbols);

    // Should have at least a, r, b
    try std.testing.expect(symbols.len >= 2);
}

test "provideDocumentSymbols - multiple node patterns" {
    const allocator = std.testing.allocator;
    // Valid GQL with multiple nodes
    const doc = try Document.init(allocator, "file:///test.gql", "MATCH (a:Person)-[r]->(b:Company) RETURN a, b", 1);
    defer doc.deinit();

    const symbols = try provideDocumentSymbols(allocator, doc);
    defer allocator.free(symbols);

    // Should extract multiple symbols
    try std.testing.expect(symbols.len >= 2);
}

// ============================================================================
// Unit Tests for Signature Help
// ============================================================================

test "provideSignatureHelp - function with params" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "RETURN count(", 1);
    defer doc.deinit();

    const sig = try provideSignatureHelp(allocator, doc, 0, 13);

    if (sig) |s| {
        defer {
            for (s.signatures) |si| {
                allocator.free(si.label);
                if (si.parameters) |ps| {
                    for (ps) |p| allocator.free(p.label);
                    allocator.free(ps);
                }
            }
            allocator.free(s.signatures);
        }

        try std.testing.expect(s.signatures.len == 1);
        try std.testing.expect(std.mem.startsWith(u8, s.signatures[0].label, "count("));
    } else {
        try std.testing.expect(false); // Should have returned signature
    }
}

test "provideSignatureHelp - returns null for non-function" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "RETURN n", 1);
    defer doc.deinit();

    const sig = try provideSignatureHelp(allocator, doc, 0, 7);
    try std.testing.expect(sig == null);
}

// ============================================================================
// Unit Tests for References
// ============================================================================

test "provideReferences - finds all variable occurrences" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "MATCH (n) WHERE n.age > 21 RETURN n", 1);
    defer doc.deinit();

    // Position at first 'n' (offset ~7)
    const refs = try provideReferences(allocator, doc, 0, 7, true);
    defer allocator.free(refs);

    // Should find 'n' 3 times
    try std.testing.expect(refs.len == 3);
}

test "provideReferences - skips keywords" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "MATCH (n) RETURN n", 1);
    defer doc.deinit();

    // Position at 'MATCH' keyword
    const refs = try provideReferences(allocator, doc, 0, 0, true);
    defer allocator.free(refs);

    // Should return empty for keywords
    try std.testing.expect(refs.len == 0);
}

// ============================================================================
// Unit Tests for Semantic Tokens
// ============================================================================

test "provideSemanticTokensFull - basic tokens" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "MATCH (n) RETURN n", 1);
    defer doc.deinit();

    const tokens = try provideSemanticTokensFull(allocator, doc);
    defer allocator.free(tokens.data);

    // Should have tokens - data is delta-encoded in groups of 5
    try std.testing.expect(tokens.data.len > 0);
    try std.testing.expect(tokens.data.len % 5 == 0);
}

test "provideSemanticTokensFull - parameters" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "RETURN $param", 1);
    defer doc.deinit();

    const tokens = try provideSemanticTokensFull(allocator, doc);
    defer allocator.free(tokens.data);

    // Should have at least 2 tokens (RETURN keyword, $param parameter)
    try std.testing.expect(tokens.data.len >= 10);
}

test "provideSemanticTokensFull - comments" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "// comment\nRETURN 1", 1);
    defer doc.deinit();

    const tokens = try provideSemanticTokensFull(allocator, doc);
    defer allocator.free(tokens.data);

    // Should have tokens for comment and RETURN keyword
    try std.testing.expect(tokens.data.len >= 10);
}
