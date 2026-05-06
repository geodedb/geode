// MCP input guards
// Pure helpers that bound the size and shape of GQL strings sent
// through the MCP LSP-bridge entry points (validate, complete, hover,
// diagnostics).
//
// CANARY: REQ=REQ-MCP-SEC-007; FEATURE="QueryLengthCap"; ASPECT=DoSGuard; STATUS=TESTED; OWNER=mcp; UPDATED=2026-05-06
// CANARY: REQ=REQ-MCP-GAP-0819; FEATURE="GqlInputChokepoint"; ASPECT=Sanitization; STATUS=TESTED; OWNER=mcp; UPDATED=2026-05-06
//
// LSP-SEC-007: bound MCP-bridge query payloads at 1 MiB. Rejects
// requests above the cap before any lexer/parser work runs. Real GQL
// queries are well under 100 KiB; the cap leaves an order of magnitude
// of headroom for legitimate machine-generated queries.
//
// GAP-0819: layered chokepoint that runs the same length cap, plus
// UTF-8 validity, embedded-NUL rejection, and minimal sanitization
// (nested /* */ comment stripping for normalization).

const std = @import("std");

pub const InputError = error{
    QueryTooLarge,
    QueryEmpty,
    InvalidUtf8,
    EmbeddedNul,
    NestedCommentTooDeep,
};

/// LSP-SEC-007: maximum size of a GQL query accepted on any MCP tool.
/// Real workloads (machine-generated joins, large IN lists) max out
/// well under 100 KiB; 1 MiB leaves an order of magnitude of headroom
/// while still bounding worst-case parser work.
pub const MAX_GQL_TEXT: usize = 1 * 1024 * 1024;

/// GAP-0819: maximum nested-comment depth tolerated. Real queries
/// almost never nest more than 2 deep; 64 is overkill but cheap.
pub const MAX_COMMENT_NEST: usize = 64;

/// LSP-SEC-007: reject if `query` is over `MAX_GQL_TEXT` bytes.
/// Returns the input unchanged if accepted; returns
/// `InputError.QueryTooLarge` otherwise.
pub fn rejectIfOversized(query: []const u8) InputError![]const u8 {
    if (query.len > MAX_GQL_TEXT) return InputError.QueryTooLarge;
    return query;
}

/// GAP-0819: chokepoint validator. Runs the LSP-SEC-007 length cap,
/// then rejects empty input, invalid UTF-8, embedded NUL bytes, and
/// pathologically nested `/* /* */ */` comments. Returns the input
/// slice unchanged on success — callers may continue parsing safely.
///
/// Sanitization (comment stripping) is intentionally NOT done here:
/// the GQL parser already handles legitimate comments correctly, and
/// stripping them would change reported error positions. We only
/// REJECT pathological depth.
pub fn validateAndSanitizeGqlInput(query: []const u8) InputError![]const u8 {
    if (query.len == 0) return InputError.QueryEmpty;
    if (query.len > MAX_GQL_TEXT) return InputError.QueryTooLarge;
    if (!std.unicode.utf8ValidateSlice(query)) return InputError.InvalidUtf8;

    // Disallow embedded NULs even inside string literals; nothing in
    // legitimate GQL needs them, and they're a classic protocol-confusion
    // vector when results round-trip through C-string consumers.
    for (query) |b| {
        if (b == 0) return InputError.EmbeddedNul;
    }

    // Pathological nested-comment depth check. We do NOT mutate the
    // input — only reject if the nest depth ever exceeds MAX_COMMENT_NEST.
    var depth: usize = 0;
    var i: usize = 0;
    var in_string: bool = false;
    while (i + 1 < query.len) : (i += 1) {
        const c = query[i];
        if (in_string) {
            if (c == '\\' and i + 1 < query.len) {
                i += 1;
                continue;
            }
            if (c == '\'' or c == '"') in_string = false;
            continue;
        }
        if (c == '\'' or c == '"') {
            in_string = true;
            continue;
        }
        if (c == '/' and query[i + 1] == '*') {
            depth += 1;
            if (depth > MAX_COMMENT_NEST) return InputError.NestedCommentTooDeep;
            i += 1;
        } else if (c == '*' and query[i + 1] == '/') {
            if (depth > 0) depth -= 1;
            i += 1;
        }
    }

    return query;
}
