// Diagnostics provider for the GQL/Geode LSP.
// Split out of features.zig (#806, QUALITY_GAP_ANALYSIS) — features.zig
// remains the public facade re-exporting `provideDiagnostics`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("../protocol.zig");
const Document = @import("../document.zig").Document;
const geode = @import("geode");
const semantic = @import("../semantic.zig");

/// GAP-0818: caller identity threaded into every feature provider.
const LspContext = @import("../context.zig").LspContext;
const SchemaProviderType = @import("../schema_provider.zig").SchemaProvider;

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
