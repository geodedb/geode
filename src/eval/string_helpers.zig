// CANARY: REQ=REQ-REFACTOR-EVAL-003; FEATURE="EvalRefactoring"; ASPECT=StringHelpers; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
/// String operation helper functions extracted from eval.zig
/// Contains startsWith, endsWith, contains, and other string utilities
const std = @import("std");
const value_types = @import("../value_types.zig");
const Value = value_types.Value;
const EvalError = value_types.EvalError;
const isNull = value_types.isNull;
const stringify = value_types.stringify;

// ============================================================================
// String Predicate Functions
// ============================================================================

/// Evaluate STARTS WITH predicate
pub fn evalStartsWith(val: Value, pref: Value) EvalError!Value {
    if (isNull(val) or isNull(pref)) return Value{ .Null = {} };
    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    const s = try stringify(val, &buf1);
    const p = try stringify(pref, &buf2);
    if (p.len == 0) return .{ .Bool = true };
    return .{ .Bool = std.mem.startsWith(u8, s, p) };
}

/// Evaluate ENDS WITH predicate
pub fn evalEndsWith(val: Value, suf: Value) EvalError!Value {
    if (isNull(val) or isNull(suf)) return Value{ .Null = {} };
    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    const s = try stringify(val, &buf1);
    const p = try stringify(suf, &buf2);
    if (p.len == 0) return .{ .Bool = true };
    return .{ .Bool = std.mem.endsWith(u8, s, p) };
}

/// Evaluate CONTAINS predicate
pub fn evalContains(val: Value, needle: Value) EvalError!Value {
    if (isNull(val) or isNull(needle)) return Value{ .Null = {} };
    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    const s = try stringify(val, &buf1);
    const n = try stringify(needle, &buf2);
    if (n.len == 0) return .{ .Bool = true };
    return .{ .Bool = std.mem.indexOf(u8, s, n) != null };
}
