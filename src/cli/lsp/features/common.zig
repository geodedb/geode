// Shared helpers for the LSP feature provider modules.
// Split out of features.zig (#806, QUALITY_GAP_ANALYSIS) — features.zig
// remains the public facade; import these through it from out-of-tree code.

const std = @import("std");
const geode = @import("geode");
const language_metadata = geode.language_metadata;

// CANARY: REQ=REQ-LSP-METADATA-002; FEATURE="MetadataIntegration"; ASPECT=ComptimeLists; STATUS=EXEMPT; OWNER=lsp; UPDATED=2026-01-03
// GQL Keywords, Functions, and Types derived from unified language_metadata.zig
// This ensures the LSP completions stay in sync with the lexer and documentation
pub const GQL_KEYWORDS = language_metadata.getKeywordNames();
pub const GQL_FUNCTIONS = language_metadata.getFunctionNames();
pub const GQL_TYPES = language_metadata.getTypeNames();

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
