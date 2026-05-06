// LSP JSON Helpers
// Safe JSON access primitives for LSP message handling.
//
// Two responsibilities:
//   1. LSP-SEC-003: depth-bomb prevention via `checkJsonDepth` — a
//      pre-pass over the raw payload that rejects deeply nested
//      JSON before std.json.parseFromSlice recurses into it.
//   2. LSP-SEC-004 / Q-Sev1: structured-access helpers
//      (getObject, getString, getInteger, getOptionalString) that
//      replace ad-hoc `.?.object.get(...).?.string` chains in
//      handlers, returning typed errors instead of panicking on
//      malformed input.
//
// CANARY: REQ=REQ-LSP-SEC-003; FEATURE="JsonDepthGuard"; ASPECT=DoSGuard; STATUS=TESTED; OWNER=lsp; UPDATED=2026-05-06
// CANARY: REQ=REQ-LSP-SEC-004; FEATURE="JsonHelpers"; ASPECT=SafeUnwrap; STATUS=TESTED; OWNER=lsp; UPDATED=2026-05-06

const std = @import("std");

pub const JsonError = error{
    InvalidParams,
    JsonTooDeep,
    JsonTooLarge,
};

/// LSP-SEC-003: maximum nesting depth a JSON-RPC payload may have before
/// we reject it. Real LSP traffic stays under ~10 levels; 64 leaves plenty
/// of headroom while still bounding parser recursion.
pub const MAX_JSON_DEPTH: usize = 64;

/// LSP-SEC-003: maximum payload size accepted from a single JSON-RPC
/// message. Pairs with the transport-layer `MAX_LSP_MESSAGE` cap; this is
/// re-checked here so that any caller of `parseFromSlice` is protected
/// even if the framing layer ever grows a separate path.
pub const MAX_JSON_PAYLOAD: usize = 16 * 1024 * 1024;

/// LSP-SEC-003: pre-parse depth and size guard.
///
/// Walks `text` byte-by-byte counting `{`/`[` opens minus `}`/`]` closes,
/// while skipping characters inside string literals (so a string like
/// "{{{{{" cannot trigger a false positive). Returns
/// `JsonError.JsonTooDeep` as soon as nesting exceeds `MAX_JSON_DEPTH`.
/// Returns `JsonError.JsonTooLarge` if the buffer exceeds
/// `MAX_JSON_PAYLOAD`. This is O(n) over the input and allocates nothing.
pub fn checkJsonDepth(text: []const u8) JsonError!void {
    if (text.len > MAX_JSON_PAYLOAD) {
        return JsonError.JsonTooLarge;
    }
    var depth: usize = 0;
    var i: usize = 0;
    var in_string = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string) {
            // Honor backslash escape so we don't exit the string on \"
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                if (depth > MAX_JSON_DEPTH) return JsonError.JsonTooDeep;
            },
            '}', ']' => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
    }
}

// =============================================================================
// LSP-SEC-004 / Q-Sev1: Safe accessor helpers
// =============================================================================

/// Get a child object by key, or `error.InvalidParams` if missing or
/// non-object.
pub fn getObject(parent: std.json.Value, key: []const u8) JsonError!std.json.ObjectMap {
    if (parent != .object) return JsonError.InvalidParams;
    const v = parent.object.get(key) orelse return JsonError.InvalidParams;
    if (v != .object) return JsonError.InvalidParams;
    return v.object;
}

/// Get a string value by key, or `error.InvalidParams` if missing or
/// non-string.
pub fn getString(obj: std.json.ObjectMap, key: []const u8) JsonError![]const u8 {
    const v = obj.get(key) orelse return JsonError.InvalidParams;
    if (v != .string) return JsonError.InvalidParams;
    return v.string;
}

/// Get an integer value by key, or `error.InvalidParams` if missing or
/// non-integer.
pub fn getInteger(obj: std.json.ObjectMap, key: []const u8) JsonError!i64 {
    const v = obj.get(key) orelse return JsonError.InvalidParams;
    if (v != .integer) return JsonError.InvalidParams;
    return v.integer;
}

/// Get an optional string value by key. Returns null if absent or
/// json-null; `error.InvalidParams` if present but non-string.
pub fn getOptionalString(obj: std.json.ObjectMap, key: []const u8) JsonError!?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v == .null) return null;
    if (v != .string) return JsonError.InvalidParams;
    return v.string;
}

/// Cast an i64 (the integer type std.json uses) down to i32 with
/// bounds-check. Returns `error.InvalidParams` if the value won't fit.
pub fn castI32(v: i64) JsonError!i32 {
    if (v > std.math.maxInt(i32) or v < std.math.minInt(i32)) {
        return JsonError.InvalidParams;
    }
    return @intCast(v);
}

/// Cast an i64 to u32 with non-negativity and upper-bound check.
pub fn castU32(v: i64) JsonError!u32 {
    if (v < 0 or v > std.math.maxInt(u32)) {
        return JsonError.InvalidParams;
    }
    return @intCast(v);
}
