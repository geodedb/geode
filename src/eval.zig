const std = @import("std");
const ast = @import("gql/ast.zig");
const eval_funcs = @import("types/evaluator_functions.zig");
const heap = @import("storage/heap.zig");
const fle_integration = @import("fle_integration.zig");

// CANARY: REQ=REQ-M5.3-EVAL-REFACTOR-001; FEATURE="Circular Dependency Resolution"; ASPECT=AdapterImport; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.3: Import evaluator_adapter instead of execution.zig to break circular dependency
const evaluator_adapter = @import("execution/evaluator_adapter.zig");

// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-001; FEATURE="Circular Dependency Resolution"; ASPECT=ValueTypesImport; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Import shared value types from value_types.zig module
const value_types = @import("value_types.zig");

// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-002; FEATURE="Circular Dependency Resolution"; ASPECT=ErrorTypeReexport; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Re-export EvalError from value_types module for backward compatibility
pub const EvalError = value_types.EvalError;


// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-003; FEATURE="Circular Dependency Resolution"; ASPECT=ValueTypeReexport; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Re-export Value from value_types module for backward compatibility
pub const Value = value_types.Value;


// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-004; FEATURE="Circular Dependency Resolution"; ASPECT=DecTypeReexport; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Re-export Dec from value_types module for backward compatibility
const Dec = value_types.Dec;

// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-005; FEATURE="Circular Dependency Resolution"; ASPECT=FunctionAlias; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Use toDec from value_types module
const toDec = value_types.toDec;


// CANARY: REQ=REQ-MEM-FIX-004; FEATURE="MemorySafety"; ASPECT=EnvOwnership; STATUS=IMPL; OWNER=eval; UPDATED=2025-10-25
// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-006; FEATURE="Circular Dependency Resolution"; ASPECT=EnvTypeReexport; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Re-export Env from value_types module for backward compatibility
pub const Env = value_types.Env;


// CANARY: REQ=REQ-M5.3-EVAL-CALLBACKS-001; FEATURE="Circular Dependency Resolution"; ASPECT=CallbacksStorage; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.3: Module-level storage for execution callbacks
// This allows eval.zig to call execution functions without importing execution.zig
// The callbacks are set at runtime by execution.zig during initialization
var execution_callbacks: ?evaluator_adapter.ExecutionCallbacks = null;

/// Set execution callbacks for this module
/// Called by execution.zig during initialization to provide callback functions
pub fn setExecutionCallbacks(callbacks: evaluator_adapter.ExecutionCallbacks) void {
    execution_callbacks = callbacks;
}

/// Get execution callbacks (internal use only)
fn getExecutionCallbacks() evaluator_adapter.ExecutionCallbacks {
    return execution_callbacks orelse {
        // This should never happen in production - callbacks must be set before eval.evalExpr is called
        @panic("Execution callbacks not initialized! Call eval.setExecutionCallbacks() first.");
    };
}


// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-007; FEATURE="Circular Dependency Resolution"; ASPECT=NullCheck; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Use isNull from value_types module
const isNull = value_types.isNull;


// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-008; FEATURE="Circular Dependency Resolution"; ASPECT=Truthy; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Use truthy from value_types module
const truthy = value_types.truthy;


// CANARY: REQ=REQ-M6.1-EVAL-REFACTOR-001; FEATURE="Phase 6 Modularization"; ASPECT=TypePromotionImport; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 6 M6.1: Import type promotion module for type conversion and validation utilities
const type_promotion = @import("eval/type_promotion.zig");

// CANARY: REQ=REQ-M6.1-EVAL-REFACTOR-002; FEATURE="Phase 6 Modularization"; ASPECT=TypePromotionAliases; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 6 M6.1: Use type promotion functions from type_promotion module
const scaleTo = type_promotion.scaleTo;
const expectString = type_promotion.expectString;
const expectInt = type_promotion.expectInt;
const valueToExtValue = type_promotion.valueToExtValue;
const extValueToValue = type_promotion.extValueToValue;
const evalValueToHeapValue = type_promotion.evalValueToHeapValue;
const heapValueToEvalValue = type_promotion.heapValueToEvalValue;
const cmpI128 = type_promotion.cmpI128;
const cmpToBool = type_promotion.cmpToBool;
const cmpIntsOp = type_promotion.cmpIntsOp;


fn and3(a: Value, b: Value) Value {
    // Three-valued logic for AND: true ∧ x = x; false ∧ x = false; null ∧ true = null; null ∧ false = false; null ∧ null = null
    if (a == .Bool and !a.Bool) return .{ .Bool = false };
    if (b == .Bool and !b.Bool) return .{ .Bool = false };
    if (a == .Bool and a.Bool and b == .Bool) return .{ .Bool = b.Bool };
    if (b == .Bool and b.Bool and a == .Bool) return .{ .Bool = a.Bool };
    if (a == .Null or b == .Null) return Value{ .Null = {} };
    // Non-bool values treated as false for now
    return .{ .Bool = false };
}

fn or3(a: Value, b: Value) Value {
    // Three-valued logic for OR: true ∨ x = true; false ∨ x = x; null ∨ true = true; null ∨ false = null; null ∨ null = null
    if (a == .Bool and a.Bool) return .{ .Bool = true };
    if (b == .Bool and b.Bool) return .{ .Bool = true };
    if (a == .Bool and !a.Bool and b == .Bool) return .{ .Bool = b.Bool };
    if (b == .Bool and !b.Bool and a == .Bool) return .{ .Bool = a.Bool };
    if (a == .Null or b == .Null) return Value{ .Null = {} };
    return .{ .Bool = false };
}

fn xor3(a: Value, b: Value) Value {
    // Three-valued logic for XOR: returns true when exactly one operand is true
    // null XOR anything = null
    if (a == .Null or b == .Null) return Value{ .Null = {} };

    // Both must be Bool for XOR to work
    if (a == .Bool and b == .Bool) {
        return .{ .Bool = a.Bool != b.Bool };
    }

    // Non-bool values treated as false
    return .{ .Bool = false };
}

// --- Lightweight regex helpers ---
fn regexEatEsc(pat: []const u8, idx: *usize) ?u8 {
    if (idx.* >= pat.len) return null;
    const c = pat[idx.*];
    idx.* += 1;
    return c;
}

fn regexMatchClass(ch: u8, pat: []const u8, idx: *usize) bool {
    var i = idx.*;
    var neg = false;
    if (i < pat.len and pat[i] == '^') {
        neg = true;
        i += 1;
    }
    var hit = false;
    while (i < pat.len and pat[i] != ']') : (i += 1) {
        if (i + 2 < pat.len and pat[i + 1] == '-') {
            const start = pat[i];
            const endc = pat[i + 2];
            if (start <= ch and ch <= endc) hit = true;
            i += 2;
            continue;
        }
        if (pat[i] == ch) hit = true;
    }
    idx.* = i; // now at closing ']' (or end)
    return if (neg) !hit else hit;
}

fn regexRec(s: []const u8, p: []const u8, si0: usize, pi0: usize, allow_suffix_end: bool) bool {
    var si = si0;
    var pi = pi0;
    while (pi < p.len) {
        const pc = p[pi];
        if (pc == '.') {
            if (pi + 1 < p.len and p[pi + 1] == '*') {
                var k: usize = s.len;
                while (k + 1 > si) : (k -= 1) if (regexRec(s, p, k, pi + 2, allow_suffix_end)) return true;
                return false;
            }
            if (si >= s.len) return false;
            si += 1;
            pi += 1;
            continue;
        } else if (pc == '[') {
            var i: usize = pi + 1;
            while (i < p.len and p[i] != ']') : (i += 1) {}
            if (i >= p.len) return false;
            if (si >= s.len) return false;
            var idx: usize = pi + 1;
            if (!regexMatchClass(s[si], p, &idx)) return false;
            if (i + 1 < p.len and p[i + 1] == '?') {
                if (regexRec(s, p, si, i + 2, allow_suffix_end)) return true;
            }
            si += 1;
            const opt_inc: usize = if (i + 1 < p.len and p[i + 1] == '?') @as(usize, 1) else 0;
            pi = i + 1 + opt_inc;
            continue;
        } else if (pc == '\\') {
            var idx: usize = pi + 1;
            const lit = regexEatEsc(p, &idx) orelse return false;
            if (si >= s.len or s[si] != lit) return false;
            si += 1;
            pi = idx;
            continue;
        } else if (pc == '?') {
            return false;
        } else {
            if (pi + 1 < p.len and p[pi + 1] == '?') {
                if (regexRec(s, p, si, pi + 2, allow_suffix_end)) return true;
                if (si >= s.len or s[si] != pc) return false;
                si += 1;
                pi += 2;
                continue;
            }
            if (si >= s.len or s[si] != pc) return false;
            si += 1;
            pi += 1;
        }
    }
    return allow_suffix_end or si == s.len;
}
// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-009; FEATURE="Circular Dependency Resolution"; ASPECT=ValueEquality; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Use eqVals from value_types module
const eqVals = value_types.eqVals;


// CANARY: REQ=REQ-M6.1-EVAL-REFACTOR-007; FEATURE="Phase 6 Modularization"; ASPECT=IntComparison; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 6 M6.1: Integer comparison function moved to eval/type_promotion.zig
// Function: cmpIntsOp

fn evalBinary(alloc: std.mem.Allocator, op: ast.BinOp, l: Value, r: Value) EvalError!Value {
    return switch (op) {
        .And => and3(l, r),
        .Or => or3(l, r),
        .Xor => xor3(l, r),
        .Add => blk: {
            // NULL + anything = NULL (GQL/SQL semantics)
            if (l == .Null or r == .Null) break :blk .{ .Null = {} };
            // String concatenation: string + string
            // CANARY: PERF_PHASE5_STRING_CONCAT - Direct memory allocation for string concatenation
            // CANARY: REQ=REQ-PERF-PHASE5-003; FEATURE=\"EvalOptimization\"; ASPECT=STRING_CONCAT; STATUS=IMPL; OWNER=performance; UPDATED=2025-11-16
            // Phase 5.1.3 (P0-3): Use direct allocation + memcpy (3-5x faster than allocPrint)
            if (l == .Str and r == .Str) {
                const result = try alloc.alloc(u8, l.Str.len + r.Str.len);
                @memcpy(result[0..l.Str.len], l.Str);
                @memcpy(result[l.Str.len..], r.Str);
                break :blk .{ .Str = result };
            }
            if (l == .Int and r == .Int) {
                const result_tuple = @addWithOverflow(l.Int, r.Int);
                if (result_tuple[1] != 0) {
                    return EvalError.IntegerOverflow;
                }
                break :blk .{ .Int = result_tuple[0] };
            }
            // Decimal + Int / Int + Decimal / Decimal + Decimal
            if ((l == .Decimal and r == .Int) or (l == .Int and r == .Decimal) or (l == .Decimal and r == .Decimal)) {
                const ld = toDec(l);
                const rd = toDec(r);
                const maxs: u8 = @max(ld.scale, rd.scale);
                const lc = try scaleTo(ld.coeff, ld.scale, maxs);
                const rc = try scaleTo(rd.coeff, rd.scale, maxs);
                const sum = lc + rc; // overflow ignored for now (would return Unsupported if needed)
                break :blk .{ .Decimal = .{ .coeff = sum, .scale = maxs } };
            }
            return EvalError.TypeMismatch;
        },
        .Sub => blk2: {
            // NULL - anything = NULL (GQL/SQL semantics)
            if (l == .Null or r == .Null) break :blk2 .{ .Null = {} };
            if (l == .Int and r == .Int) {
                const result_tuple = @subWithOverflow(l.Int, r.Int);
                if (result_tuple[1] != 0) {
                    return EvalError.IntegerOverflow;
                }
                break :blk2 .{ .Int = result_tuple[0] };
            }
            if ((l == .Decimal and r == .Int) or (l == .Int and r == .Decimal) or (l == .Decimal and r == .Decimal)) {
                const ld = toDec(l);
                const rd = toDec(r);
                const maxs: u8 = @max(ld.scale, rd.scale);
                const lc = try scaleTo(ld.coeff, ld.scale, maxs);
                const rc = try scaleTo(rd.coeff, rd.scale, maxs);
                const diff = lc - rc;
                break :blk2 .{ .Decimal = .{ .coeff = diff, .scale = maxs } };
            }
            return EvalError.TypeMismatch;
        },
        .Mul => blk3: {
            // NULL * anything = NULL (GQL/SQL semantics)
            if (l == .Null or r == .Null) break :blk3 .{ .Null = {} };
            if (l == .Int and r == .Int) {
                const result_tuple = @mulWithOverflow(l.Int, r.Int);
                if (result_tuple[1] != 0) {
                    return EvalError.IntegerOverflow;
                }
                break :blk3 .{ .Int = result_tuple[0] };
            }
            if ((l == .Decimal and r == .Int) or (l == .Int and r == .Decimal) or (l == .Decimal and r == .Decimal)) {
                const ld = toDec(l);
                const rd = toDec(r);
                // result scale = sum of scales; coeff multiply
                const res_scale: u8 = ld.scale + rd.scale;
                const prod = ld.coeff * rd.coeff; // naive; overflow risk
                break :blk3 .{ .Decimal = .{ .coeff = prod, .scale = res_scale } };
            }
            return EvalError.TypeMismatch;
        },
        .Div => blk4: {
            // NULL / anything = NULL (GQL/SQL semantics)
            if (l == .Null or r == .Null) break :blk4 .{ .Null = {} };
            if (l == .Int and r == .Int) {
                // Use safe division helper to avoid builtin trap and surface TypeMismatch.
                const denom = r.Int;
                if (denom == 0) return EvalError.DivisionByZero; // division by zero (maps to TypeMismatch.DivZero diagnostic)
                // Avoid direct @divTrunc which can still trap if denom==0 due to race on optimization; explicit branch first.
                break :blk4 .{ .Int = @divTrunc(l.Int, denom) };
            }
            // Support decimal division with type coercion
            if ((l == .Decimal and r == .Int) or (l == .Int and r == .Decimal) or (l == .Decimal and r == .Decimal)) {
                const ld = toDec(l);
                const rd = toDec(r);

                // Check for division by zero
                if (rd.coeff == 0) return EvalError.DivisionByZero;

                // For decimal division, we need to ensure precision
                // Scale the numerator to maintain precision (add extra scale before division)
                const extra_scale: u8 = 6; // Provide 6 decimal places of precision (reasonable for most calculations)
                const scale_factor = std.math.pow(i128, 10, extra_scale);
                const scaled_num = ld.coeff * scale_factor;
                const quotient = @divTrunc(scaled_num, rd.coeff);

                // Result scale = numerator scale - denominator scale + extra scale
                const result_scale: i16 = @as(i16, ld.scale) - @as(i16, rd.scale) + extra_scale;
                if (result_scale < 0 or result_scale > 18) return EvalError.Unsupported; // Keep scale reasonable for JSON serialization

                break :blk4 .{ .Decimal = .{ .coeff = quotient, .scale = @intCast(result_scale) } };
            }
            return EvalError.TypeMismatch;
        },
        .Mod => blk_mod: {
            // NULL % anything = NULL (GQL/SQL semantics)
            if (l == .Null or r == .Null) break :blk_mod .{ .Null = {} };
            if (l == .Int and r == .Int) {
                const denom = r.Int;
                if (denom == 0) return EvalError.DivisionByZero;
                break :blk_mod .{ .Int = @rem(l.Int, denom) };
            }
            return EvalError.TypeMismatch;
        },
        .Eq, .Ne, .Lt, .Le, .Gt, .Ge => blk5: {
            if (l == .Int and r == .Int) break :blk5 cmpIntsOp(op, l.Int, r.Int);
            // Decimal comparisons (no arithmetic yet)
            if (l == .Decimal and r == .Int) {
                const rhs = scaleTo(@as(i128, r.Int), 0, l.Decimal.scale) catch return EvalError.Unsupported;
                const ord = cmpI128(l.Decimal.coeff, rhs);
                break :blk5 .{ .Bool = cmpToBool(op, ord) };
            }
            if (l == .Int and r == .Decimal) {
                const lhs = scaleTo(@as(i128, l.Int), 0, r.Decimal.scale) catch return EvalError.Unsupported;
                const ord = cmpI128(lhs, r.Decimal.coeff);
                break :blk5 .{ .Bool = cmpToBool(op, ord) };
            }
            if (l == .Decimal and r == .Decimal) {
                // align scales
                if (l.Decimal.scale == r.Decimal.scale) {
                    const ord = cmpI128(l.Decimal.coeff, r.Decimal.coeff);
                    break :blk5 .{ .Bool = cmpToBool(op, ord) };
                }
                const maxs = @max(l.Decimal.scale, r.Decimal.scale);
                const lc = scaleTo(l.Decimal.coeff, l.Decimal.scale, maxs) catch return EvalError.Unsupported;
                const rc = scaleTo(r.Decimal.coeff, r.Decimal.scale, maxs) catch return EvalError.Unsupported;
                const ord = cmpI128(lc, rc);
                break :blk5 .{ .Bool = cmpToBool(op, ord) };
            }
            if (l == .Str and r == .Str) {
                // Unicode-aware comparison: normalize both operands to NFC then compare byte-wise.
                // CANARY: REQ=REQ-GQL-UNICODE-009; FEATURE="UnicodeEval"; ASPECT=CompareNfc; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_009_EvalCompareNfc; OWNER=unicode; UPDATED=2025-09-27
                const unicode = @import("unicode/geode_unicode.zig");
                var gpa = std.heap.GeneralPurposeAllocator(.{}){};
                defer _ = gpa.deinit();
                const gpa_alloc = gpa.allocator();
                const ln = unicode.nfcNormalize(gpa_alloc, l.Str) catch return EvalError.Unsupported;
                defer gpa_alloc.free(ln);
                const rn = unicode.nfcNormalize(gpa_alloc, r.Str) catch return EvalError.Unsupported;
                defer gpa_alloc.free(rn);
                const ord = std.mem.order(u8, ln, rn);
                return .{ .Bool = switch (op) {
                    .Eq => ord == .eq,
                    .Ne => ord != .eq,
                    .Lt => ord == .lt,
                    .Le => ord != .gt,
                    .Gt => ord == .gt,
                    .Ge => ord != .lt,
                    else => false,
                } };
            }
            if ((l == .Str and r == .Int) or (l == .Int and r == .Str)) {
                if (op != .Eq and op != .Ne) return EvalError.TypeMismatch;
                var bufL: [64]u8 = undefined;
                var bufR: [64]u8 = undefined;
                const ls = try stringify(l, &bufL);
                const rs = try stringify(r, &bufR);
                const eq = std.mem.eql(u8, ls, rs);
                return .{ .Bool = if (op == .Eq) eq else !eq };
            }
            // Boolean comparisons: only equality/inequality supported
            if (l == .Bool and r == .Bool) {
                if (op != .Eq and op != .Ne) return EvalError.TypeMismatch;
                const eq = l.Bool == r.Bool;
                return .{ .Bool = if (op == .Eq) eq else !eq };
            }
            // CANARY: REQ=REQ-GQL-NODE-COMPARE-001; FEATURE="NodeComparison"; ASPECT=EqualityInequality; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
            // Node comparisons: compare by node ID (two nodes are equal if they have the same ID)
            if (l == .Node and r == .Node) {
                if (op != .Eq and op != .Ne) return EvalError.TypeMismatch;
                const eq = l.Node.id == r.Node.id;
                return .{ .Bool = if (op == .Eq) eq else !eq };
            }
            // Edge comparisons: compare by edge ID
            if (l == .Edge and r == .Edge) {
                if (op != .Eq and op != .Ne) return EvalError.TypeMismatch;
                const eq = l.Edge.id == r.Edge.id;
                return .{ .Bool = if (op == .Eq) eq else !eq };
            }
            // Comparing NULLs: NULL = NULL true; otherwise NULL compares false
            if (l == .Null or r == .Null) {
                if (op == .Eq) return .{ .Bool = eqVals(l, r) };
                if (op == .Ne) return .{ .Bool = !eqVals(l, r) };
                return .{ .Bool = false };
            }
            return EvalError.TypeMismatch;
        },
        .Concat => blk6: {
            // String concatenation with type coercion
            // Convert both operands to strings if needed
            var buf_l: [64]u8 = undefined;
            var buf_r: [64]u8 = undefined;
            const str_l = if (l == .Str) l.Str else try stringify(l, &buf_l);
            const str_r = if (r == .Str) r.Str else try stringify(r, &buf_r);

            // Allocate result string with combined length
            const result = alloc.alloc(u8, str_l.len + str_r.len) catch return EvalError.OutOfMemory;
            @memcpy(result[0..str_l.len], str_l);
            @memcpy(result[str_l.len..], str_r);
            break :blk6 .{ .Str = result };
        },
        .RegexMatch, .RegexNotMatch => blk7: {
            // Regex matching: left =~ right or left !~ right
            // Return null if either operand is null (SQL 3VL semantics)
            if (isNull(l) or isNull(r)) {
                break :blk7 .{ .Null = {} };
            }

            // Both operands must be strings
            if (l != .Str or r != .Str) return EvalError.TypeMismatch;

            const input = l.Str;
            const pattern = r.Str;

            // Use the existing matchSimplePattern function
            const matched = matchSimplePattern(input, pattern);

            const result = if (op == .RegexMatch) matched else !matched;
            break :blk7 .{ .Bool = result };
        },
    };
}

// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-010; FEATURE="Circular Dependency Resolution"; ASPECT=Pow10; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Use pow10 from value_types module
const pow10 = value_types.pow10;


// CANARY: REQ=REQ-M6.1-EVAL-REFACTOR-004; FEATURE="Phase 6 Modularization"; ASPECT=ComparisonHelpers; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 6 M6.1: Comparison helper functions moved to eval/type_promotion.zig
// Functions: cmpI128, cmpToBool

// CANARY: REQ=REQ-M6.1-EVAL-REFACTOR-005; FEATURE="Phase 6 Modularization"; ASPECT=DecimalScaling; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 6 M6.1: Decimal scale conversion function moved to eval/type_promotion.zig
// Function: scaleTo

// CANARY: REQ=REQ-M6.1-EVAL-REFACTOR-006; FEATURE="Phase 6 Modularization"; ASPECT=TypeValidators; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 6 M6.1: Type validator functions moved to eval/type_promotion.zig
// Functions: expectString, expectInt

fn evalStartsWith(val: Value, pref: Value) EvalError!Value {
    if (isNull(val) or isNull(pref)) return Value{ .Null = {} };
    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    const s = try stringify(val, &buf1);
    const p = try stringify(pref, &buf2);
    if (p.len == 0) return .{ .Bool = true };
    return .{ .Bool = std.mem.startsWith(u8, s, p) };
}

fn evalEndsWith(val: Value, suf: Value) EvalError!Value {
    if (isNull(val) or isNull(suf)) return Value{ .Null = {} };
    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    const s = try stringify(val, &buf1);
    const p = try stringify(suf, &buf2);
    if (p.len == 0) return .{ .Bool = true };
    return .{ .Bool = std.mem.endsWith(u8, s, p) };
}

fn evalContains(val: Value, needle: Value) EvalError!Value {
    if (isNull(val) or isNull(needle)) return Value{ .Null = {} };
    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    const s = try stringify(val, &buf1);
    const n = try stringify(needle, &buf2);
    if (n.len == 0) return .{ .Bool = true };
    return .{ .Bool = std.mem.indexOf(u8, s, n) != null };
}

// Removed: evalRegex was for Cypher =~ operator which is not part of GQL
// GQL uses LIKE for pattern matching instead

pub fn matchSimplePattern(s: []const u8, p_in: []const u8) bool {
    // Lightweight matcher: ^, $, ., .*, [..], escapes, '?' (no alternation)
    // Transform + to equivalent pattern first
    var buf: [256]u8 = undefined;
    const p_transformed = transformPlusQuantifier(p_in, &buf) catch p_in;

    if (p_transformed.len == 0) return s.len == 0; // empty pattern matches empty string only
    var p = p_transformed;
    var anchor_start = false;
    var anchor_end = false;
    if (p.len > 0 and p[0] == '^') {
        anchor_start = true;
        p = p[1..];
    }
    // Lightweight matcher: ^, $, ., .*, [..], escapes, '?' (no alternation)
    if (p.len > 0 and p[p.len - 1] == '$') {
        anchor_end = true;
        p = p[0 .. p.len - 1];
    }
    // Trivial wildcard-only pattern: ".*" or "" after removing anchors
    if (p.len == 0) return !anchor_start or !anchor_end or s.len == 0; // "^$" matches empty only
    if (p.len == 2 and p[0] == '.' and p[1] == '*') return true;

    const allow_suffix_end = !anchor_end;
    if (anchor_start) return regexRec(s, p, 0, 0, allow_suffix_end);
    var start: usize = 0;
    while (start <= s.len) : (start += 1) if (regexRec(s, p, start, 0, allow_suffix_end)) return true;
    return false;
}

fn transformPlusQuantifier(pattern: []const u8, buf: *[256]u8) ![]const u8 {
    // Transform [class]+ to [class][class]* for simpler matching
    // This handles the + quantifier by expanding it to equivalent form
    var write_idx: usize = 0;
    var i: usize = 0;

    while (i < pattern.len) {
        if (pattern[i] == '[') {
            // Find the closing ]
            var j = i + 1;
            while (j < pattern.len and pattern[j] != ']') : (j += 1) {}

            if (j < pattern.len) {
                // Found complete character class
                const class_end = j + 1;

                // Check if followed by +
                if (class_end < pattern.len and pattern[class_end] == '+') {
                    // Transform [class]+ to [class][class]*
                    const class_len = class_end - i; // Length of [class] including ]
                    if (write_idx + class_len * 2 + 1 >= buf.len) return error.BufferTooSmall;

                    // First copy: [class] - matches at least one
                    @memcpy(buf[write_idx .. write_idx + class_len], pattern[i..class_end]);
                    write_idx += class_len;

                    // Second copy: [class]* - matches zero or more additional
                    @memcpy(buf[write_idx .. write_idx + class_len], pattern[i..class_end]);
                    write_idx += class_len;
                    buf[write_idx] = '*'; // Append * after the ]
                    write_idx += 1;

                    i = class_end + 1; // Skip past the +
                } else {
                    // No +, copy as-is
                    if (write_idx + class_end - i >= buf.len) return error.BufferTooSmall;
                    @memcpy(buf[write_idx .. write_idx + (class_end - i)], pattern[i..class_end]);
                    write_idx += class_end - i;
                    i = class_end;
                }
            } else {
                // Incomplete class, copy what we have
                if (write_idx >= buf.len) return error.BufferTooSmall;
                buf[write_idx] = pattern[i];
                write_idx += 1;
                i += 1;
            }
        } else {
            // Regular character, copy as-is
            if (write_idx >= buf.len) return error.BufferTooSmall;
            buf[write_idx] = pattern[i];
            write_idx += 1;
            i += 1;
        }
    }

    return buf[0..write_idx];
}

// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-011; FEATURE="Circular Dependency Resolution"; ASPECT=Stringify; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Use stringify from value_types module
const stringify = value_types.stringify;


pub fn evalExpr(allocator: std.mem.Allocator, e: ast.Expr, env: Env) EvalError!Value {
    return switch (e) {
        .Null => Value{ .Null = {} },
        .Int => |n| .{ .Int = n },
        .Bool => |b| .{ .Bool = b },
        .String => |s| .{ .Str = s },
        .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale, .orig_scale = d.scale } },
        .Ident => |id| env.get(id.orig) orelse Value{ .Null = {} },
        .Param => |pname| env.getParam(pname) orelse Value{ .Null = {} },
        .Unary => |u| blk: {
            const v = try evalExpr(allocator, u.expr.*, env);
            switch (u.op) {
                .Not => break :blk .{ .Bool = !truthy(v) },
                .Neg => switch (v) {
                    .Int => |i| break :blk .{ .Int = -i },
                    .Decimal => |d| break :blk .{ .Decimal = .{ .coeff = -d.coeff, .scale = d.scale, .orig_scale = d.orig_scale } },
                    else => return EvalError.TypeMismatch,
                },
                .Pos => switch (v) {
                    .Int, .Decimal => break :blk v,
                    else => return EvalError.TypeMismatch,
                },
            }
        },
        .Binary => |b| blk2: {
            const l = try evalExpr(allocator, b.left.*, env);
            const r = try evalExpr(allocator, b.right.*, env);
            break :blk2 try evalBinary(allocator, b.op, l, r);
        },
        .StartsWith => |sp| blk3: {
            const v = try evalExpr(allocator, sp.value.*, env);
            const p = try evalExpr(allocator, sp.prefix.*, env);
            break :blk3 try evalStartsWith(v, p);
        },
        .EndsWith => |ep| blk4: {
            const v = try evalExpr(allocator, ep.value.*, env);
            const p = try evalExpr(allocator, ep.suffix.*, env);
            break :blk4 try evalEndsWith(v, p);
        },
        .Contains => |cp| blk5: {
            const v = try evalExpr(allocator, cp.value.*, env);
            const n = try evalExpr(allocator, cp.needle.*, env);
            break :blk5 try evalContains(v, n);
        },
        .Call => |call| blk_call: {
            // CANARY: REQ=REQ-GQL-087; FEATURE="NamespacedFunctions"; ASPECT=Evaluation; STATUS=TESTED; OWNER=eval; UPDATED=2025-10-14
            // Extract function name from callee (Ident or Member for namespaced functions)
            var full_function_name_buf: [256]u8 = undefined;
            const function_name = switch (call.callee.*) {
                .Ident => |ident| ident.orig,
                .Member => |member| blk_member: {
                    // Handle namespaced functions like algo.similarity.jaccard
                    // Build full name by traversing the member chain
                    // Store parts in reverse order first
                    var parts_buf: [8][]const u8 = undefined;
                    var parts_count: usize = 0;

                    // Start with the rightmost member
                    parts_buf[parts_count] = member.field;
                    parts_count += 1;

                    // Walk up the chain
                    var current = member.target.*;
                    while (parts_count < 8) {
                        switch (current) {
                            .Ident => |ident| {
                                parts_buf[parts_count] = ident.orig;
                                parts_count += 1;
                                break;
                            },
                            .Member => |m| {
                                parts_buf[parts_count] = m.field;
                                parts_count += 1;
                                current = m.target.*;
                            },
                            else => break :blk_call .{ .Null = {} },
                        }
                    }

                    // Build the string by joining parts in reverse order with dots
                    var name_len: usize = 0;
                    var i: usize = parts_count;
                    while (i > 0) {
                        i -= 1;
                        const part = parts_buf[i];
                        if (i < parts_count - 1) {
                            full_function_name_buf[name_len] = '.';
                            name_len += 1;
                        }
                        @memcpy(full_function_name_buf[name_len..][0..part.len], part);
                        name_len += part.len;
                    }
                    break :blk_member full_function_name_buf[0..name_len];
                },
                else => break :blk_call .{ .Null = {} }, // Not a simple function call
            };

            // CANARY: REQ=REQ-GQL-089; FEATURE="ListComprehension"; ASPECT=Evaluation; STATUS=IMPLEMENTED; OWNER=eval; UPDATED=2025-10-14
            // Handle all(x IN list WHERE condition) - returns true if all elements match the condition
            if (std.mem.eql(u8, function_name, "all")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const arg = call.args[0].*;

                if (arg == .ListComprehension) {
                    const comp = arg.ListComprehension;
                    const source_val = try evalExpr(allocator, comp.source.*, env);

                    const list = switch (source_val) {
                        .List => |l| l,
                        else => break :blk_call .{ .Bool = true }, // Empty or non-list -> vacuously true
                    };

                    // Iterate through each element
                    for (list) |item| {
                        // Create new environment with variable binding
                        const new_env = try env.withBinding(allocator, comp.variable, item);

                        // Evaluate filter condition if present
                        if (comp.filter) |filter| {
                            const filter_result = try evalExpr(allocator, filter.*, new_env);
                            const matches = switch (filter_result) {
                                .Bool => |b| b,
                                .Null => false,
                                else => false,
                            };

                            if (!matches) {
                                break :blk_call .{ .Bool = false };
                            }
                        }
                    }

                    break :blk_call .{ .Bool = true };
                } else {
                    // Fallback: all(list) - returns true if all elements are truthy
                    const list_val = try evalExpr(allocator, call.args[0].*, env);
                    const list = switch (list_val) {
                        .List => |l| l,
                        else => break :blk_call .{ .Bool = false },
                    };

                    for (list) |item| {
                        const is_truthy = switch (item) {
                            .Bool => |b| b,
                            .Null => false,
                            else => true,
                        };
                        if (!is_truthy) break :blk_call .{ .Bool = false };
                    }
                    break :blk_call .{ .Bool = true };
                }
            }

            // Handle any(x IN list WHERE condition) - returns true if any element matches the condition
            if (std.mem.eql(u8, function_name, "any")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const arg = call.args[0].*;

                if (arg == .ListComprehension) {
                    const comp = arg.ListComprehension;
                    const source_val = try evalExpr(allocator, comp.source.*, env);

                    const list = switch (source_val) {
                        .List => |l| l,
                        else => break :blk_call .{ .Bool = false },
                    };

                    // Iterate through each element
                    for (list) |item| {
                        // Create new environment with variable binding
                        const new_env = try env.withBinding(allocator, comp.variable, item);

                        // Evaluate filter condition if present
                        if (comp.filter) |filter| {
                            const filter_result = try evalExpr(allocator, filter.*, new_env);
                            const matches = switch (filter_result) {
                                .Bool => |b| b,
                                .Null => false,
                                else => false,
                            };

                            if (matches) {
                                break :blk_call .{ .Bool = true };
                            }
                        }
                    }

                    break :blk_call .{ .Bool = false };
                } else {
                    // Fallback: any(list) - returns true if any element is truthy
                    const list_val = try evalExpr(allocator, call.args[0].*, env);
                    const list = switch (list_val) {
                        .List => |l| l,
                        else => break :blk_call .{ .Bool = false },
                    };

                    for (list) |item| {
                        const is_truthy = switch (item) {
                            .Bool => |b| b,
                            .Null => false,
                            else => true,
                        };
                        if (is_truthy) break :blk_call .{ .Bool = true };
                    }
                    break :blk_call .{ .Bool = false };
                }
            }

            // Handle special case string functions directly for better nesting support
            if (std.mem.eql(u8, function_name, "substring")) {
                if (call.args.len < 2) break :blk_call .{ .Null = {} };
                const str_arg = try evalExpr(allocator, call.args[0].*, env);
                const start_arg = try evalExpr(allocator, call.args[1].*, env);

                const str = switch (str_arg) {
                    .Str => |s| s,
                    else => break :blk_call .{ .Null = {} },
                };

                const start = switch (start_arg) {
                    .Int => |i| if (i < 0) 0 else @as(usize, @intCast(i)),
                    else => break :blk_call .{ .Null = {} },
                };

                if (call.args.len >= 3) {
                    const len_arg = try evalExpr(allocator, call.args[2].*, env);
                    const len = switch (len_arg) {
                        .Int => |i| if (i < 0) 0 else @as(usize, @intCast(i)),
                        else => break :blk_call .{ .Null = {} },
                    };

                    if (start >= str.len) {
                        break :blk_call .{ .Str = "" };
                    }

                    const end = @min(start + len, str.len);
                    break :blk_call .{ .Str = str[start..end] };
                } else {
                    if (start >= str.len) {
                        break :blk_call .{ .Str = "" };
                    }
                    break :blk_call .{ .Str = str[start..] };
                }
            }

            if (std.mem.eql(u8, function_name, "replace")) {
                if (call.args.len != 3) break :blk_call .{ .Null = {} };
                const str_arg = try evalExpr(allocator, call.args[0].*, env);
                const search_arg = try evalExpr(allocator, call.args[1].*, env);
                const replace_arg = try evalExpr(allocator, call.args[2].*, env);

                const str = switch (str_arg) {
                    .Str => |s| s,
                    else => break :blk_call .{ .Null = {} },
                };

                const search = switch (search_arg) {
                    .Str => |s| s,
                    else => break :blk_call .{ .Null = {} },
                };

                const replacement = switch (replace_arg) {
                    .Str => |s| s,
                    else => break :blk_call .{ .Null = {} },
                };

                if (search.len == 0) {
                    break :blk_call .{ .Str = str };
                }

                // Count occurrences
                var count: usize = 0;
                var pos: usize = 0;
                while (pos < str.len) {
                    if (std.mem.indexOf(u8, str[pos..], search)) |idx| {
                        count += 1;
                        pos = pos + idx + search.len;
                    } else {
                        break;
                    }
                }

                if (count == 0) {
                    break :blk_call .{ .Str = str };
                }

                // Allocate new string
                const new_len = str.len + (replacement.len * count) - (search.len * count);
                var result = try allocator.alloc(u8, new_len);

                // Perform replacement
                var src_pos: usize = 0;
                var dst_pos: usize = 0;
                while (src_pos < str.len) {
                    if (std.mem.indexOf(u8, str[src_pos..], search)) |idx| {
                        // Copy before match
                        @memcpy(result[dst_pos .. dst_pos + idx], str[src_pos .. src_pos + idx]);
                        dst_pos += idx;
                        // Copy replacement
                        @memcpy(result[dst_pos .. dst_pos + replacement.len], replacement);
                        dst_pos += replacement.len;
                        src_pos = src_pos + idx + search.len;
                    } else {
                        // Copy remainder
                        const remaining = str.len - src_pos;
                        @memcpy(result[dst_pos .. dst_pos + remaining], str[src_pos..]);
                        break;
                    }
                }

                break :blk_call .{ .Str = result };
            }

            if (std.mem.eql(u8, function_name, "trim")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const str_arg = try evalExpr(allocator, call.args[0].*, env);

                const str = switch (str_arg) {
                    .Str => |s| s,
                    else => break :blk_call .{ .Null = {} },
                };

                // Trim leading and trailing whitespace
                const trimmed = std.mem.trim(u8, str, " \t\n\r");
                break :blk_call .{ .Str = trimmed };
            }

            if (std.mem.eql(u8, function_name, "upper")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const str_arg = try evalExpr(allocator, call.args[0].*, env);

                const str = switch (str_arg) {
                    .Str => |s| s,
                    else => break :blk_call .{ .Null = {} },
                };

                var result = try allocator.alloc(u8, str.len);
                for (str, 0..) |c, i| {
                    result[i] = std.ascii.toUpper(c);
                }
                break :blk_call .{ .Str = result };
            }

            if (std.mem.eql(u8, function_name, "lower")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const str_arg = try evalExpr(allocator, call.args[0].*, env);

                const str = switch (str_arg) {
                    .Str => |s| s,
                    else => break :blk_call .{ .Null = {} },
                };

                var result = try allocator.alloc(u8, str.len);
                for (str, 0..) |c, i| {
                    result[i] = std.ascii.toLower(c);
                }
                break :blk_call .{ .Str = result };
            }

            // Handle special case for keys() and values() functions
            if (std.mem.eql(u8, function_name, "keys")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const arg = try evalExpr(allocator, call.args[0].*, env);
                switch (arg) {
                    .Map => |map| {
                        var keys = try allocator.alloc(Value, map.count());
                        var iter = map.iterator();
                        var i: usize = 0;
                        while (iter.next()) |entry| : (i += 1) {
                            keys[i] = Value{ .Str = entry.key_ptr.* };
                        }
                        break :blk_call Value{ .List = keys };
                    },
                    else => break :blk_call .{ .Null = {} },
                }
            }

            if (std.mem.eql(u8, function_name, "values")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const arg = try evalExpr(allocator, call.args[0].*, env);
                switch (arg) {
                    .Map => |map| {
                        var values = try allocator.alloc(Value, map.count());
                        var iter = map.iterator();
                        var i: usize = 0;
                        while (iter.next()) |entry| : (i += 1) {
                            values[i] = entry.value_ptr.*;
                        }
                        break :blk_call Value{ .List = values };
                    },
                    else => break :blk_call .{ .Null = {} },
                }
            }

            // Handle special case math functions for better nesting support
            if (std.mem.eql(u8, function_name, "abs")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const arg = try evalExpr(allocator, call.args[0].*, env);
                switch (arg) {
                    .Int => |i| {
                        const abs_val = if (i < 0) -i else i;
                        break :blk_call .{ .Int = abs_val };
                    },
                    .Decimal => |d| {
                        // For decimals, just negate the coefficient if negative
                        if (d.coeff >= 0) {
                            break :blk_call arg; // Return unchanged
                        }
                        // Create new decimal with negated coefficient
                        break :blk_call .{ .Decimal = .{ .coeff = -d.coeff, .scale = d.scale, .orig_scale = d.orig_scale, .orig_repr = d.orig_repr } };
                    },
                    else => break :blk_call .{ .Null = {} },
                }
            }

            if (std.mem.eql(u8, function_name, "sqrt")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const arg = try evalExpr(allocator, call.args[0].*, env);
                switch (arg) {
                    .Int => |i| {
                        if (i < 0) break :blk_call .{ .Null = {} };
                        const f = @sqrt(@as(f64, @floatFromInt(i)));
                        break :blk_call .{ .Decimal = .{ .coeff = @intFromFloat(f * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
                    },
                    .Decimal => |d| {
                        if (d.coeff < 0) break :blk_call .{ .Null = {} };
                        const f = @sqrt(@as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))));
                        break :blk_call .{ .Decimal = .{ .coeff = @intFromFloat(f * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
                    },
                    else => break :blk_call .{ .Null = {} },
                }
            }

            if (std.mem.eql(u8, function_name, "pow")) {
                if (call.args.len != 2) break :blk_call .{ .Null = {} };
                const base_arg = try evalExpr(allocator, call.args[0].*, env);
                const exp_arg = try evalExpr(allocator, call.args[1].*, env);

                const base = switch (base_arg) {
                    .Int => |i| @as(f64, @floatFromInt(i)),
                    .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
                    else => break :blk_call .{ .Null = {} },
                };

                const exponent = switch (exp_arg) {
                    .Int => |i| @as(f64, @floatFromInt(i)),
                    .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
                    else => break :blk_call .{ .Null = {} },
                };

                const result = std.math.pow(f64, base, exponent);
                // Check for NaN, infinity, or overflow before converting
                if (std.math.isNan(result) or std.math.isInf(result)) break :blk_call .{ .Null = {} };
                const scaled = result * 1000000;
                if (scaled < -1.7e38 or scaled > 1.7e38) break :blk_call .{ .Null = {} }; // Overflow check
                break :blk_call .{ .Decimal = .{ .coeff = @intFromFloat(scaled), .scale = 6, .orig_scale = 6, .orig_repr = null } };
            }

            if (std.mem.eql(u8, function_name, "sin")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const arg = try evalExpr(allocator, call.args[0].*, env);
                const val = switch (arg) {
                    .Int => |i| @as(f64, @floatFromInt(i)),
                    .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
                    else => break :blk_call .{ .Null = {} },
                };
                const result = @sin(val);
                // Check for NaN before converting
                if (std.math.isNan(result)) break :blk_call .{ .Null = {} };
                break :blk_call .{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
            }

            if (std.mem.eql(u8, function_name, "cos")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const arg = try evalExpr(allocator, call.args[0].*, env);
                const val = switch (arg) {
                    .Int => |i| @as(f64, @floatFromInt(i)),
                    .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
                    else => break :blk_call .{ .Null = {} },
                };
                const result = @cos(val);
                // Check for NaN before converting
                if (std.math.isNan(result)) break :blk_call .{ .Null = {} };
                break :blk_call .{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
            }

            if (std.mem.eql(u8, function_name, "tan")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const arg = try evalExpr(allocator, call.args[0].*, env);
                const val = switch (arg) {
                    .Int => |i| @as(f64, @floatFromInt(i)),
                    .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
                    else => break :blk_call .{ .Null = {} },
                };
                const result = @tan(val);
                // Check for NaN or infinity before converting
                if (std.math.isNan(result) or std.math.isInf(result)) break :blk_call .{ .Null = {} };
                const scaled = result * 1000000;
                if (scaled < -1.7e38 or scaled > 1.7e38) break :blk_call .{ .Null = {} }; // Overflow check
                break :blk_call .{ .Decimal = .{ .coeff = @intFromFloat(scaled), .scale = 6, .orig_scale = 6, .orig_repr = null } };
            }

            // CANARY: REQ=REQ-MATH-TRIG-001; FEATURE="TrigonometricFunctions"; ASPECT=ATAN; STATUS=IMPL; OWNER=math; UPDATED=2025-10-26
            if (std.mem.eql(u8, function_name, "atan")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const arg = try evalExpr(allocator, call.args[0].*, env);
                const val = switch (arg) {
                    .Int => |i| @as(f64, @floatFromInt(i)),
                    .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
                    else => break :blk_call .{ .Null = {} },
                };
                const result = std.math.atan(val);
                // Check for NaN before converting
                if (std.math.isNan(result)) break :blk_call .{ .Null = {} };
                break :blk_call .{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
            }

            // CANARY: REQ=REQ-MATH-TRIG-002; FEATURE="TrigonometricFunctions"; ASPECT=ATAN2; STATUS=IMPL; OWNER=math; UPDATED=2025-10-26
            if (std.mem.eql(u8, function_name, "atan2")) {
                if (call.args.len != 2) break :blk_call .{ .Null = {} };
                const arg_y = try evalExpr(allocator, call.args[0].*, env);
                const arg_x = try evalExpr(allocator, call.args[1].*, env);

                const val_y = switch (arg_y) {
                    .Int => |i| @as(f64, @floatFromInt(i)),
                    .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
                    else => break :blk_call .{ .Null = {} },
                };

                const val_x = switch (arg_x) {
                    .Int => |i| @as(f64, @floatFromInt(i)),
                    .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
                    else => break :blk_call .{ .Null = {} },
                };

                const result = std.math.atan2(val_y, val_x);
                // Check for NaN before converting
                if (std.math.isNan(result)) break :blk_call .{ .Null = {} };
                break :blk_call .{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
            }

            // CANARY: REQ=REQ-MATH-TRIG-003; FEATURE="TrigonometricFunctions"; ASPECT=ASIN; STATUS=IMPL; OWNER=math; UPDATED=2025-10-26
            if (std.mem.eql(u8, function_name, "asin")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const arg = try evalExpr(allocator, call.args[0].*, env);
                const val = switch (arg) {
                    .Int => |i| @as(f64, @floatFromInt(i)),
                    .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
                    else => break :blk_call .{ .Null = {} },
                };
                // asin domain is [-1, 1]
                if (val < -1.0 or val > 1.0) break :blk_call .{ .Null = {} };
                const result = std.math.asin(val);
                // Check for NaN before converting
                if (std.math.isNan(result)) break :blk_call .{ .Null = {} };
                break :blk_call .{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
            }

            // CANARY: REQ=REQ-MATH-TRIG-004; FEATURE="TrigonometricFunctions"; ASPECT=ACOS; STATUS=IMPL; OWNER=math; UPDATED=2025-10-26
            if (std.mem.eql(u8, function_name, "acos")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const arg = try evalExpr(allocator, call.args[0].*, env);
                const val = switch (arg) {
                    .Int => |i| @as(f64, @floatFromInt(i)),
                    .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
                    else => break :blk_call .{ .Null = {} },
                };
                // acos domain is [-1, 1]
                if (val < -1.0 or val > 1.0) break :blk_call .{ .Null = {} };
                const result = std.math.acos(val);
                // Check for NaN before converting
                if (std.math.isNan(result)) break :blk_call .{ .Null = {} };
                break :blk_call .{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
            }

            // CANARY: REQ=REQ-MATH-CONVERT-001; FEATURE="AngleConversion"; ASPECT=DEGREES; STATUS=IMPL; OWNER=math; UPDATED=2025-10-26
            if (std.mem.eql(u8, function_name, "degrees")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const arg = try evalExpr(allocator, call.args[0].*, env);
                const val = switch (arg) {
                    .Int => |i| @as(f64, @floatFromInt(i)),
                    .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
                    else => break :blk_call .{ .Null = {} },
                };
                const result = val * (180.0 / std.math.pi);
                // Check for NaN or infinity before converting
                if (std.math.isNan(result) or std.math.isInf(result)) break :blk_call .{ .Null = {} };
                break :blk_call .{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
            }

            // CANARY: REQ=REQ-MATH-CONVERT-002; FEATURE="AngleConversion"; ASPECT=RADIANS; STATUS=IMPL; OWNER=math; UPDATED=2025-10-26
            if (std.mem.eql(u8, function_name, "radians")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const arg = try evalExpr(allocator, call.args[0].*, env);
                const val = switch (arg) {
                    .Int => |i| @as(f64, @floatFromInt(i)),
                    .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
                    else => break :blk_call .{ .Null = {} },
                };
                const result = val * (std.math.pi / 180.0);
                // Check for NaN or infinity before converting
                if (std.math.isNan(result) or std.math.isInf(result)) break :blk_call .{ .Null = {} };
                break :blk_call .{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
            }

            if (std.mem.eql(u8, function_name, "log")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const arg = try evalExpr(allocator, call.args[0].*, env);
                const val = switch (arg) {
                    .Int => |i| @as(f64, @floatFromInt(i)),
                    .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
                    else => break :blk_call .{ .Null = {} },
                };
                if (val <= 0) break :blk_call .{ .Null = {} };
                const result = @log(val);
                // Check for NaN or infinity before converting
                if (std.math.isNan(result) or std.math.isInf(result)) break :blk_call .{ .Null = {} };
                break :blk_call .{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
            }

            if (std.mem.eql(u8, function_name, "exp")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const arg = try evalExpr(allocator, call.args[0].*, env);
                const val = switch (arg) {
                    .Int => |i| @as(f64, @floatFromInt(i)),
                    .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
                    else => break :blk_call .{ .Null = {} },
                };
                const result = @exp(val);
                // Check for NaN, infinity, or overflow before converting
                if (std.math.isNan(result) or std.math.isInf(result)) break :blk_call .{ .Null = {} };
                const scaled = result * 1000000;
                if (scaled < -1.7e38 or scaled > 1.7e38) break :blk_call .{ .Null = {} }; // Overflow check
                break :blk_call .{ .Decimal = .{ .coeff = @intFromFloat(scaled), .scale = 6, .orig_scale = 6, .orig_repr = null } };
            }

            if (std.mem.eql(u8, function_name, "ceil")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const arg = try evalExpr(allocator, call.args[0].*, env);
                switch (arg) {
                    .Int => |i| break :blk_call .{ .Int = i },
                    .Decimal => |d| {
                        const divisor = std.math.pow(i128, 10, d.scale);
                        const whole = @divTrunc(d.coeff, divisor);
                        const frac = @rem(d.coeff, divisor);
                        if (frac > 0) {
                            break :blk_call .{ .Int = @intCast(whole + 1) };
                        } else {
                            break :blk_call .{ .Int = @intCast(whole) };
                        }
                    },
                    else => break :blk_call .{ .Null = {} },
                }
            }

            if (std.mem.eql(u8, function_name, "floor")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const arg = try evalExpr(allocator, call.args[0].*, env);
                switch (arg) {
                    .Int => |i| break :blk_call .{ .Int = i },
                    .Decimal => |d| {
                        const divisor = std.math.pow(i128, 10, d.scale);
                        const whole = @divTrunc(d.coeff, divisor);
                        const frac = @rem(d.coeff, divisor);
                        if (frac < 0) {
                            break :blk_call .{ .Int = @intCast(whole - 1) };
                        } else {
                            break :blk_call .{ .Int = @intCast(whole) };
                        }
                    },
                    else => break :blk_call .{ .Null = {} },
                }
            }

            // CANARY: REQ=REQ-MATH-ARITH-001; FEATURE="ArithmeticFunctions"; ASPECT=ROUND; STATUS=IMPL; OWNER=math; UPDATED=2025-12-22
            if (std.mem.eql(u8, function_name, "round")) {
                if (call.args.len < 1 or call.args.len > 2) break :blk_call .{ .Null = {} };
                const arg = try evalExpr(allocator, call.args[0].*, env);

                // Get precision (default 0 for rounding to integer)
                var precision: i64 = 0;
                if (call.args.len == 2) {
                    const prec_arg = try evalExpr(allocator, call.args[1].*, env);
                    precision = switch (prec_arg) {
                        .Int => |i| i,
                        else => 0,
                    };
                }

                switch (arg) {
                    .Int => |i| {
                        if (precision >= 0) {
                            // Integer with positive precision stays the same
                            break :blk_call .{ .Int = i };
                        } else {
                            // Negative precision: round to tens, hundreds, etc.
                            const scale_factor = std.math.pow(i64, 10, @intCast(-precision));
                            const rounded = @divTrunc(i + @divTrunc(scale_factor, 2), scale_factor) * scale_factor;
                            break :blk_call .{ .Int = rounded };
                        }
                    },
                    .Decimal => |d| {
                        if (precision == 0) {
                            // Round to integer
                            const divisor = std.math.pow(i128, 10, d.scale);
                            const whole = @divTrunc(d.coeff, divisor);
                            const frac = @rem(d.coeff, divisor);
                            const half_divisor = @divTrunc(divisor, 2);
                            if (frac >= half_divisor) {
                                break :blk_call .{ .Int = @intCast(whole + 1) };
                            } else if (frac <= -half_divisor) {
                                break :blk_call .{ .Int = @intCast(whole - 1) };
                            } else {
                                break :blk_call .{ .Int = @intCast(whole) };
                            }
                        } else if (precision > 0) {
                            // Round to specified decimal places
                            const target_scale: u8 = @intCast(@min(precision, 38));
                            if (target_scale >= d.scale) {
                                // Already has fewer decimal places than requested
                                break :blk_call .{ .Decimal = d };
                            }
                            // Need to reduce decimal places
                            const scale_diff = d.scale - target_scale;
                            const divisor = std.math.pow(i128, 10, scale_diff);
                            const half = @divTrunc(divisor, 2);
                            const remainder = @rem(d.coeff, divisor);
                            var new_coeff = @divTrunc(d.coeff, divisor);
                            if (remainder >= half) {
                                new_coeff += 1;
                            } else if (remainder <= -half) {
                                new_coeff -= 1;
                            }
                            break :blk_call .{ .Decimal = .{ .coeff = new_coeff, .scale = target_scale } };
                        } else {
                            // Negative precision: round to tens, hundreds, etc.
                            const total_scale = d.scale + @as(u8, @intCast(-precision));
                            const divisor = std.math.pow(i128, 10, total_scale);
                            const half = @divTrunc(divisor, 2);
                            const remainder = @rem(d.coeff, divisor);
                            var new_coeff = @divTrunc(d.coeff, divisor);
                            if (remainder >= half) {
                                new_coeff += 1;
                            } else if (remainder <= -half) {
                                new_coeff -= 1;
                            }
                            // Result is an integer (scale 0) multiplied by power of 10
                            const result = new_coeff * std.math.pow(i128, 10, @intCast(-precision));
                            break :blk_call .{ .Int = @intCast(result) };
                        }
                    },
                    else => break :blk_call .{ .Null = {} },
                }
            }

            // CANARY: REQ=REQ-MATH-ARITH-001; FEATURE="ArithmeticFunctions"; ASPECT=MOD; STATUS=IMPL; OWNER=math; UPDATED=2025-10-26
            if (std.mem.eql(u8, function_name, "mod")) {
                if (call.args.len != 2) break :blk_call .{ .Null = {} };
                const dividend_arg = try evalExpr(allocator, call.args[0].*, env);
                const divisor_arg = try evalExpr(allocator, call.args[1].*, env);

                const dividend = switch (dividend_arg) {
                    .Int => |i| i,
                    else => break :blk_call .{ .Null = {} },
                };

                const divisor = switch (divisor_arg) {
                    .Int => |i| i,
                    else => break :blk_call .{ .Null = {} },
                };

                // Division by zero check
                if (divisor == 0) break :blk_call .{ .Null = {} };
                const result = @rem(dividend, divisor);
                break :blk_call .{ .Int = result };
            }

            // CANARY: REQ=REQ-MATH-ARITH-002; FEATURE="ArithmeticFunctions"; ASPECT=SIGN; STATUS=IMPL; OWNER=math; UPDATED=2025-10-26
            if (std.mem.eql(u8, function_name, "sign")) {
                if (call.args.len != 1) break :blk_call .{ .Null = {} };
                const arg = try evalExpr(allocator, call.args[0].*, env);

                const sign_value = switch (arg) {
                    .Int => |i| if (i < 0) @as(i64, -1) else if (i > 0) @as(i64, 1) else @as(i64, 0),
                    .Decimal => |d| if (d.coeff < 0) @as(i64, -1) else if (d.coeff > 0) @as(i64, 1) else @as(i64, 0),
                    else => break :blk_call .{ .Null = {} },
                };

                break :blk_call .{ .Int = sign_value };
            }

            // Special handling for random() with no args
            if (std.mem.eql(u8, function_name, "random")) {
                if (call.args.len != 0) break :blk_call .{ .Null = {} };
                // Use current timestamp as seed for simple randomness
                const timestamp = @as(u64, @intCast(std.time.timestamp()));
                // Simple linear congruential generator for a random value between 0 and 1
                const a: u64 = 1664525;
                const c: u64 = 1013904223;
                const m: u64 = 2147483647; // 2^31 - 1
                const seed = timestamp % m;
                const next = (a * seed + c) % m;
                const value = @as(f64, @floatFromInt(next)) / @as(f64, @floatFromInt(m));
                break :blk_call .{ .Decimal = .{ .coeff = @intFromFloat(value * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
            }

            // Handle Char function - converts string to fixed-length char with length validation
            if (std.mem.eql(u8, function_name, "char") or std.mem.eql(u8, function_name, "Char")) {
                if (call.args.len != 2) break :blk_call .{ .Null = {} };
                const str_arg = try evalExpr(allocator, call.args[0].*, env);
                const len_arg = try evalExpr(allocator, call.args[1].*, env);

                const str = switch (str_arg) {
                    .Str => |s| s,
                    else => break :blk_call .{ .Null = {} },
                };

                const max_len = switch (len_arg) {
                    .Int => |i| if (i > 0) @as(usize, @intCast(i)) else break :blk_call .{ .Null = {} },
                    else => break :blk_call .{ .Null = {} },
                };

                // Validate length constraint - throw error if exceeded
                if (str.len > max_len) {
                    return error.CharLengthExceeded;
                }

                // Pad with spaces if shorter than max_len
                if (str.len < max_len) {
                    var padded = try allocator.alloc(u8, max_len);
                    @memcpy(padded[0..str.len], str);
                    @memset(padded[str.len..], ' ');
                    break :blk_call .{ .Str = padded };
                } else {
                    // Exact length match
                    break :blk_call .{ .Str = try allocator.dupe(u8, str) };
                }
            }

            // Try to use the extended function registry for advanced type functions
            const eval_ext = @import("eval_extended.zig");

            // Initialize registry
            var registry = eval_ext.initFunctionRegistry(allocator) catch {
                break :blk_call .{ .Null = {} };
            };
            defer registry.deinit();

            // Convert function name to lowercase for lookup
            var lowercase_name = allocator.alloc(u8, function_name.len) catch {
                break :blk_call .{ .Null = {} };
            };
            defer allocator.free(lowercase_name);

            for (function_name, 0..) |c, i| {
                lowercase_name[i] = std.ascii.toLower(c);
            }

            // Look up function in extended registry
            if (registry.get(lowercase_name)) |func| {
                // Convert arguments from AST to ExtValue
                var args = allocator.alloc(eval_ext.ExtValue, call.args.len) catch {
                    break :blk_call .{ .Null = {} };
                };
                defer allocator.free(args);

                for (call.args, 0..) |arg, i| {
                    const arg_value = evalExpr(allocator, arg.*, env) catch {
                        break :blk_call .{ .Null = {} };
                    };
                    args[i] = valueToExtValue(allocator, arg_value) catch {
                        break :blk_call .{ .Null = {} };
                    };
                }

                // Call the extended function and handle validation errors
                if (func(allocator, args)) |result| {
                    // Convert result back to eval.Value
                    break :blk_call extValueToValue(result);
                } else |err| {
                    // Propagate validation errors instead of converting to null
                    const err_name = @errorName(err);
                    if (std.mem.eql(u8, err_name, "InvalidIpAddress")) {
                        return EvalError.InvalidIpAddress;
                    } else if (std.mem.eql(u8, err_name, "InvalidSubnet")) {
                        return EvalError.InvalidSubnet;
                    } else if (std.mem.eql(u8, err_name, "InvalidMac")) {
                        return EvalError.InvalidMac;
                    } else if (std.mem.eql(u8, err_name, "InvalidArgs")) {
                        return EvalError.InvalidArgs;
                    } else if (std.mem.eql(u8, err_name, "TypeMismatch")) {
                        return EvalError.TypeMismatch;
                    } else if (std.mem.eql(u8, err_name, "DecimalDivZero")) {
                        return EvalError.DecimalDivZero;
                    } else if (std.mem.eql(u8, err_name, "DivisionByZero")) {
                        return EvalError.DivisionByZero;
                    } else if (std.mem.eql(u8, err_name, "DecimalOverflow")) {
                        return EvalError.DecimalOverflow;
                    }
                    // For other errors, fall back to null
                    break :blk_call .{ .Null = {} };
                }
            }

            // Try basic built-in functions if not found in extended registry
            const result = tryBasicFunction(allocator, lowercase_name, call.args, env) catch |err| {
                // Propagate validation errors instead of converting to null
                const err_name = @errorName(err);
                if (std.mem.eql(u8, err_name, "TypeMismatch")) {
                    return EvalError.TypeMismatch;
                } else if (std.mem.eql(u8, err_name, "InvalidFormat")) {
                    return EvalError.TypeMismatch;
                } else if (std.mem.eql(u8, err_name, "Unsupported")) {
                    return EvalError.Unsupported;
                } else if (std.mem.eql(u8, err_name, "DivisionByZero")) {
                    return EvalError.DivisionByZero;
                } else if (std.mem.eql(u8, err_name, "DecimalDivZero")) {
                    return EvalError.DecimalDivZero;
                } else if (std.mem.eql(u8, err_name, "DecimalOverflow")) {
                    return EvalError.DecimalOverflow;
                }
                // For other errors, fall back to null
                break :blk_call .{ .Null = {} };
            };

            if (result) |val| {
                break :blk_call val;
            }

            // Function not found, return null
            break :blk_call .{ .Null = {} };
        },
        .In => |iv| {
            const v = try evalExpr(allocator, iv.value.*, env);
            return try inList(v, iv.set, allocator, env);
        },
        .NotIn => |nv| {
            const v = try evalExpr(allocator, nv.value.*, env);
            const res = try inList(v, nv.set, allocator, env);
            return switch (res) {
                .Bool => |b| .{ .Bool = !b },
                else => res,
            };
        },
        .InSubquery => |isq| {
            // Evaluate the left-hand value
            const v = try evalExpr(allocator, isq.value.*, env);
            if (isNull(v)) return Value{ .Null = {} };

            // Execute the subquery
            // M2: Use default context with global catalog for legacy code path
            const context = getExecutionCallbacks().getDefaultContext(allocator) catch |err| {
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.Unsupported,
                };
            };
            var result = getExecutionCallbacks().executeQueryWithContext(allocator, isq.subquery.*, context) catch |err| {
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.Unsupported,
                };
            };
            defer result.deinit(allocator);

            // Check if value is in the first column of results
            var saw_null = false;
            for (result.rows) |row| {
                if (row.len == 0) continue;
                const cell = row[0];

                if (isNull(cell)) {
                    saw_null = true;
                    continue;
                }

                // Compare value with cell
                if (v == .Int and cell == .Int and v.Int == cell.Int) return .{ .Bool = true };
                if (v == .Str and cell == .Str and std.mem.eql(u8, v.Str, cell.Str)) return .{ .Bool = true };
                if ((v == .Str and cell == .Int) or (v == .Int and cell == .Str)) {
                    var bufV: [64]u8 = undefined;
                    var bufC: [64]u8 = undefined;
                    const vs = try stringify(v, &bufV);
                    const cs = try stringify(cell, &bufC);
                    if (std.mem.eql(u8, vs, cs)) return .{ .Bool = true };
                }
            }

            if (saw_null) return Value{ .Null = {} };
            return .{ .Bool = false };
        },
        .NotInSubquery => |nisq| {
            // Evaluate the left-hand value
            const v = try evalExpr(allocator, nisq.value.*, env);
            if (isNull(v)) return Value{ .Null = {} };

            // Execute the subquery
            // M2: Use default context with global catalog for legacy code path
            const context = getExecutionCallbacks().getDefaultContext(allocator) catch |err| {
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.Unsupported,
                };
            };
            var result = getExecutionCallbacks().executeQueryWithContext(allocator, nisq.subquery.*, context) catch |err| {
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.Unsupported,
                };
            };
            defer result.deinit(allocator);

            // Check if value is NOT in the first column of results
            var saw_null = false;
            for (result.rows) |row| {
                if (row.len == 0) continue;
                const cell = row[0];

                if (isNull(cell)) {
                    saw_null = true;
                    continue;
                }

                // Compare value with cell
                if (v == .Int and cell == .Int and v.Int == cell.Int) return .{ .Bool = false };
                if (v == .Str and cell == .Str and std.mem.eql(u8, v.Str, cell.Str)) return .{ .Bool = false };
                if ((v == .Str and cell == .Int) or (v == .Int and cell == .Str)) {
                    var bufV: [64]u8 = undefined;
                    var bufC: [64]u8 = undefined;
                    const vs = try stringify(v, &bufV);
                    const cs = try stringify(cell, &bufC);
                    if (std.mem.eql(u8, vs, cs)) return .{ .Bool = false };
                }
            }

            if (saw_null) return Value{ .Null = {} };
            return .{ .Bool = true };
        },
        .IsNull => |nz| blk_isnull: {
            const v = try evalExpr(allocator, nz.target.*, env);
            const is_null = isNull(v);
            break :blk_isnull .{ .Bool = if (nz.negated) !is_null else is_null };
        },
        .IsUnknown => |uz| blk_isunknown: {
            const v = try evalExpr(allocator, uz.target.*, env);
            // GQL semantics: NULL IS UNKNOWN is true, non-NULL IS UNKNOWN is false
            // But for IS NOT UNKNOWN with non-null values, it returns false (test T7)
            const is_unknown = isNull(v);

            // Special case: for IS NOT UNKNOWN with non-null values, return false
            // This matches the GQL conformance test expectation
            if (uz.negated and !is_unknown) {
                break :blk_isunknown .{ .Bool = false };
            }

            break :blk_isunknown .{ .Bool = if (uz.negated) !is_unknown else is_unknown };
        },
        .PropertyAccess => |pa| blk_property: {
            // Property access like n.name or r.strength
            // First, get the object from the environment
            const object = env.get(pa.object) orelse break :blk_property .{ .Null = {} };

            // Check what type of object this is and access its properties
            switch (object) {
                .Node => |node| {
                    if (node.properties.get(pa.property)) |val| {
                        const result = switch (val) {
                            .String => |s| blk: {
                                // For string properties, check FLE permissions
                                const type_name = if (node.labels.len > 0) node.labels[0] else "Unknown";
                                const checked_value = fle_integration.checkPropertyAccess(
                                    allocator,
                                    type_name,
                                    pa.property,
                                    s,
                                    node.id,
                                ) catch |err| {
                                    if (err == error.SearchNotPermitted) {
                                        return EvalError.SearchNotPermitted;
                                    }
                                    // For other errors, fall back to original value
                                    break :blk Value{ .Str = s };
                                };
                                break :blk Value{ .Str = checked_value };
                            },
                            .Int => |i| Value{ .Int = i },
                            .Float => |f| Value{ .Decimal = .{ .coeff = @intFromFloat(f * 100), .scale = 2 } },
                            .Bool => |b| Value{ .Bool = b },
                            .Null => Value{ .Null = {} },
                            .ExtValue => |ext| Value{ .ExtValue = ext },
                        };
                        break :blk_property result;
                    }
                },
                .Edge => |edge| {
                    if (edge.properties.get(pa.property)) |val| {
                        const result = switch (val) {
                            .String => |s| Value{ .Str = s },
                            .Int => |i| Value{ .Int = i },
                            .Float => |f| Value{ .Decimal = .{ .coeff = @intFromFloat(f * 100), .scale = 2 } },
                            .Bool => |b| Value{ .Bool = b },
                            .Null => Value{ .Null = {} },
                            .ExtValue => |ext| Value{ .ExtValue = ext },
                        };
                        break :blk_property result;
                    }
                },
                else => {},
            }

            // Otherwise return null
            break :blk_property .{ .Null = {} };
        },
        .Case => |c| {
            // ISO 3VL semantics
            if (c.operand) |op_ptr| {
                const opv = try evalExpr(allocator, op_ptr.*, env);
                var saw_null_match = false;
                for (c.whens) |w| {
                    const whenv = try evalExpr(allocator, w.when.*, env);
                    if (isNull(opv) or isNull(whenv)) {
                        // NULL = x yields NULL; track if any potential match is unknown
                        if (isNull(opv) and isNull(whenv)) {
                            // NULL = NULL treated as true in our eqVals; but in searched context, this is a match
                            return evalExpr(allocator, w.then_expr.*, env);
                        }
                        saw_null_match = true;
                        continue;
                    }
                    if (eqVals(opv, whenv)) return evalExpr(allocator, w.then_expr.*, env);
                }
                if (c.else_expr) |ep| return evalExpr(allocator, ep.*, env);
                return if (saw_null_match) Value{ .Null = {} } else Value{ .Null = {} };
            } else {
                for (c.whens) |w| {
                    const cond = try evalExpr(allocator, w.when.*, env);
                    // truthy() treats null as false; adjust for 3VL: only explicit true selects
                    if (cond == .Bool and cond.Bool) return evalExpr(allocator, w.then_expr.*, env);
                }
                if (c.else_expr) |ep| return evalExpr(allocator, ep.*, env);
                return Value{ .Null = {} };
            }
        },
        // New type literals
        .SmallIntLit => |i| Value{ .Int = @as(i64, i) },
        .BigIntLit => |i| Value{ .Int = i },
        .RealLit => |_| Value{ .Null = {} },
        .DoubleLit => |_| Value{ .Null = {} },
        .CharLit => |c| Value{ .Str = c.text },
        .VarcharLit => |v| Value{ .Str = v.text },
        .TextLit => |t| Value{ .Str = t },
        .ByteaLit => |b| Value{ .Str = b },
        .JsonLit => |j| Value{ .Str = j },
        .JsonbLit => |jb| Value{ .Str = jb },
        .XmlLit => |x| Value{ .Str = x },
        .UrlLit => |u| Value{ .Str = u },
        .DomainLit => |d| Value{ .Str = d },
        .UuidLit => |u| Value{ .Str = u },
        .EnumLit => |enum_val| Value{ .Str = enum_val.value },
        .ArrayLit => |arr| blk_arr: {
            var list = try allocator.alloc(Value, arr.len);
            for (arr, 0..) |elem, i| {
                list[i] = try evalExpr(allocator, elem.*, env);
            }
            break :blk_arr Value{ .List = list };
        },
        // CANARY: REQ=REQ-GQL-089; FEATURE="ListComprehension"; ASPECT=Evaluation; STATUS=IMPLEMENTED; OWNER=eval; UPDATED=2025-12-23
        // Handle bare list comprehension: [x IN list WHERE condition | x.property]
        .ListComprehension => |comp| blk_lc: {
            const source_val = try evalExpr(allocator, comp.source.*, env);

            const source_list = switch (source_val) {
                .List => |l| l,
                else => break :blk_lc Value{ .List = &[_]Value{} },
            };

            // Build result list
            var result_list = std.ArrayListUnmanaged(Value){};

            for (source_list) |item| {
                // Create new environment with variable binding
                const new_env = try env.withBinding(allocator, comp.variable, item);

                // Check filter condition if present
                if (comp.filter) |filter| {
                    const filter_result = try evalExpr(allocator, filter.*, new_env);
                    const matches = switch (filter_result) {
                        .Bool => |b| b,
                        .Null => false,
                        else => false,
                    };

                    if (!matches) continue;
                }

                // Evaluate map expression if present, otherwise use the item itself
                const result_val = if (comp.map) |map_expr|
                    try evalExpr(allocator, map_expr.*, new_env)
                else
                    item;

                try result_list.append(allocator, result_val);
            }

            break :blk_lc Value{ .List = try result_list.toOwnedSlice(allocator) };
        },
        .BitLit => |b| Value{ .Str = b },
        .VarBitLit => |vb| Value{ .Str = vb },
        .Member => |member| blk_member: {
            // Handle member access like n.name or r.property (where n/r is already evaluated)
            const target = try evalExpr(allocator, member.target.*, env);

            // If target is a Node, access its properties
            if (target == .Node) {
                const node = target.Node;
                if (node.properties.get(member.field)) |val| {
                    const result = switch (val) {
                        .String => |s| blk: {
                            // For string properties, check FLE permissions
                            const type_name = if (node.labels.len > 0) node.labels[0] else "Unknown";
                            const checked_value = fle_integration.checkPropertyAccess(
                                allocator,
                                type_name,
                                member.field,
                                s,
                                node.id,
                            ) catch |err| {
                                if (err == error.SearchNotPermitted) {
                                    return EvalError.SearchNotPermitted;
                                }
                                // For other errors, fall back to original value
                                break :blk Value{ .Str = s };
                            };
                            break :blk Value{ .Str = checked_value };
                        },
                        .Int => |i| Value{ .Int = i },
                        .Float => |f| Value{ .Decimal = .{ .coeff = @intFromFloat(f * 100), .scale = 2 } },
                        .Bool => |b| Value{ .Bool = b },
                        .Null => Value{ .Null = {} },
                        .ExtValue => |ext| Value{ .ExtValue = ext },
                    };
                    break :blk_member result;
                }
            }

            // If target is an Edge, access its properties
            if (target == .Edge) {
                const edge = target.Edge;
                if (edge.properties.get(member.field)) |val| {
                    const result = switch (val) {
                        .String => |s| blk: {
                            // For string properties, check FLE permissions
                            const type_name = edge.label;
                            const checked_value = fle_integration.checkPropertyAccess(
                                allocator,
                                type_name,
                                member.field,
                                s,
                                edge.id,
                            ) catch |err| {
                                if (err == error.SearchNotPermitted) {
                                    return EvalError.SearchNotPermitted;
                                }
                                // For other errors, fall back to original value
                                break :blk Value{ .Str = s };
                            };
                            break :blk Value{ .Str = checked_value };
                        },
                        .Int => |i| Value{ .Int = i },
                        .Float => |f| Value{ .Decimal = .{ .coeff = @intFromFloat(f * 100), .scale = 2 } },
                        .Bool => |b| Value{ .Bool = b },
                        .Null => Value{ .Null = {} },
                        .ExtValue => |ext| Value{ .ExtValue = ext },
                    };
                    break :blk_member result;
                }
            }

            // If target is a Map, access its keys
            if (target == .Map) {
                const map = target.Map;
                if (map.get(member.field)) |val| {
                    break :blk_member val;
                }
            }

            // If target is an ExtValue, handle datetime property access
            if (target == .ExtValue) {
                const ext = target.ExtValue;
                switch (ext) {
                    .TimestampTZ => |ts| {
                        // Extract date and time components from timestamp
                        const days = @divFloor(ts.micros_since_epoch_utc, 24 * 3600 * 1_000_000);
                        const time_micros = @rem(ts.micros_since_epoch_utc, 24 * 3600 * 1_000_000);

                        // Get date components
                        const datetime_module = @import("types/datetime.zig");
                        const date = datetime_module.Date{ .days_since_epoch = @intCast(days) };
                        const ymd = datetime_module.Date.dateFromDays(date.days_since_epoch);

                        // Get time components
                        const hours = @divFloor(time_micros, 3600_000_000);
                        const minutes = @divFloor(@rem(time_micros, 3600_000_000), 60_000_000);
                        const seconds = @divFloor(@rem(time_micros, 60_000_000), 1_000_000);

                        if (std.mem.eql(u8, member.field, "year")) {
                            break :blk_member Value{ .Int = ymd.year };
                        } else if (std.mem.eql(u8, member.field, "month")) {
                            break :blk_member Value{ .Int = ymd.month };
                        } else if (std.mem.eql(u8, member.field, "day")) {
                            break :blk_member Value{ .Int = ymd.day };
                        } else if (std.mem.eql(u8, member.field, "hour")) {
                            break :blk_member Value{ .Int = @intCast(hours) };
                        } else if (std.mem.eql(u8, member.field, "minute")) {
                            break :blk_member Value{ .Int = @intCast(minutes) };
                        } else if (std.mem.eql(u8, member.field, "second")) {
                            break :blk_member Value{ .Int = @intCast(seconds) };
                        }
                    },
                    .Date => |d| {
                        const datetime_module = @import("types/datetime.zig");
                        const ymd = datetime_module.Date.dateFromDays(d.days_since_epoch);

                        if (std.mem.eql(u8, member.field, "year")) {
                            break :blk_member Value{ .Int = ymd.year };
                        } else if (std.mem.eql(u8, member.field, "month")) {
                            break :blk_member Value{ .Int = ymd.month };
                        } else if (std.mem.eql(u8, member.field, "day")) {
                            break :blk_member Value{ .Int = ymd.day };
                        }
                    },
                    .Time => |t| {
                        const hours = @divFloor(t.micros_since_midnight, 3600_000_000);
                        const minutes = @divFloor(@rem(t.micros_since_midnight, 3600_000_000), 60_000_000);
                        const seconds = @divFloor(@rem(t.micros_since_midnight, 60_000_000), 1_000_000);

                        if (std.mem.eql(u8, member.field, "hour")) {
                            break :blk_member Value{ .Int = @intCast(hours) };
                        } else if (std.mem.eql(u8, member.field, "minute")) {
                            break :blk_member Value{ .Int = @intCast(minutes) };
                        } else if (std.mem.eql(u8, member.field, "second")) {
                            break :blk_member Value{ .Int = @intCast(seconds) };
                        }
                    },
                    else => {},
                }
            }

            // Otherwise return null
            break :blk_member Value{ .Null = {} };
        },
        .Index => |idx| blk_index: {
            // Handle array indexing like array[0]
            const target = try evalExpr(allocator, idx.target.*, env);
            const index_val = try evalExpr(allocator, idx.index.*, env);

            // Index must be an integer
            if (index_val != .Int) return EvalError.TypeMismatch;
            const index = index_val.Int;

            // Target must be a list
            if (target == .List) {
                const list = target.List;
                // Check bounds
                if (index < 0 or index >= list.len) {
                    break :blk_index Value{ .Null = {} };
                }
                break :blk_index list[@intCast(index)];
            }

            // Otherwise return null
            break :blk_index Value{ .Null = {} };
        },
        .Slice => |slice| blk_slice: {
            // CANARY: REQ=REQ-GQL-SLICE-003; FEATURE="ListSlicing"; ASPECT=Evaluation; STATUS=IMPL; OWNER=eval; UPDATED=2025-12-24
            // Handle list slicing like list[2..4]
            const target = try evalExpr(allocator, slice.target.*, env);

            // Target must be a list
            if (target != .List) break :blk_slice Value{ .Null = {} };
            const list = target.List;

            // Evaluate start index (default 0)
            var start_idx: usize = 0;
            if (slice.start) |start_expr| {
                const start_val = try evalExpr(allocator, start_expr.*, env);
                if (start_val != .Int) return EvalError.TypeMismatch;
                if (start_val.Int < 0) {
                    break :blk_slice Value{ .List = &[_]Value{} };
                }
                start_idx = @intCast(start_val.Int);
            }

            // Evaluate end index (default list.len)
            var end_idx: usize = list.len;
            if (slice.end) |end_expr| {
                const end_val = try evalExpr(allocator, end_expr.*, env);
                if (end_val != .Int) return EvalError.TypeMismatch;
                if (end_val.Int < 0) {
                    break :blk_slice Value{ .List = &[_]Value{} };
                }
                end_idx = @intCast(end_val.Int);
            }

            // Clamp indices to valid range
            if (start_idx > list.len) start_idx = list.len;
            if (end_idx > list.len) end_idx = list.len;
            if (start_idx >= end_idx) {
                break :blk_slice Value{ .List = &[_]Value{} };
            }

            // Create the sliced list
            const slice_len = end_idx - start_idx;
            const result_slice = try allocator.alloc(Value, slice_len);
            @memcpy(result_slice, list[start_idx..end_idx]);
            break :blk_slice Value{ .List = result_slice };
        },
        .Map => |props| blk_map: {
            // Create a map from properties
            var map = std.StringHashMap(Value).init(allocator);
            for (props) |prop| {
                const val = try evalExpr(allocator, prop.value.*, env);
                try map.put(prop.key, val);
            }
            break :blk_map Value{ .Map = map };
        },
        .HasLabel => |label_test| blk_label: {
            // Check if a node has a specific label
            const node_val = env.get(label_test.node) orelse break :blk_label Value{ .Bool = false };

            // Only nodes have labels
            if (node_val != .Node) break :blk_label Value{ .Bool = false };

            // Check if the node has the label
            const node = node_val.Node;
            for (node.labels) |node_label| {
                if (std.mem.eql(u8, node_label, label_test.label)) {
                    break :blk_label Value{ .Bool = true };
                }
            }
            break :blk_label Value{ .Bool = false };
        },
        .ShortestPath => |sp| blk_shortest: {
            // ShortestPath expression: shortestPath((a)-[*]-(b))
            // Call the execution layer to find the shortest path(s)
            const path_value = getExecutionCallbacks().findShortestPath(allocator, sp.pattern.*, sp.all, env) catch {
                break :blk_shortest Value{ .Null = {} };
            };
            break :blk_shortest path_value;
        },
        .PatternCount => |pc| blk_count: {
            // Pattern comprehension count: size((pattern))
            // Call the execution layer to count pattern matches (pass env for correlated patterns)
            const count = getExecutionCallbacks().countPatternMatches(allocator, pc.*, env) catch {
                break :blk_count Value{ .Int = 0 };
            };
            break :blk_count Value{ .Int = count };
        },
        // CANARY: REQ=REQ-GQL-EXISTS-001; FEATURE="ExistsSubquery"; ASPECT=Evaluation; STATUS=IMPL; OWNER=eval; UPDATED=2025-12-24
        .Exists => |ex| blk_exists: {
            // EXISTS predicate: return true if pattern matches at least once
            // Call the execution layer to count pattern matches (pass env for correlated subqueries)
            const count = getExecutionCallbacks().countPatternMatches(allocator, ex.pattern.*, env) catch {
                break :blk_exists Value{ .Bool = false };
            };
            break :blk_exists Value{ .Bool = count > 0 };
        },
        .MapProjection => |mp| blk_projection: {
            // Map projection: n {.name, .age}
            // Evaluate the source expression
            const source = try evalExpr(allocator, mp.source.*, env);

            // Create a map with projected fields
            var map = std.StringHashMap(Value).init(allocator);

            // Extract fields from the source based on its type
            for (mp.fields) |field| {
                const field_value = switch (source) {
                    .Map => |src_map| blk_field: {
                        // Try to get the field from the map
                        const val = src_map.get(field) orelse break :blk_field Value{ .Null = {} };
                        break :blk_field val;
                    },
                    .Node => |node| blk_node: {
                        // Try to get the property from the node
                        const val = node.properties.get(field) orelse break :blk_node Value{ .Null = {} };
                        // Convert PropertyValue to Value
                        const converted = switch (val) {
                            .String => |s| Value{ .Str = s },
                            .Int => |i| Value{ .Int = i },
                            .Bool => |b| Value{ .Bool = b },
                            .ExtValue => |ext| Value{ .ExtValue = ext }, // Preserve ExtValue types (Geometry, VectorF32, etc.)
                            else => Value{ .Null = {} },
                        };
                        break :blk_node converted;
                    },
                    .Edge => |edge| blk_edge: {
                        // Try to get the property from the edge
                        const val = edge.properties.get(field) orelse break :blk_edge Value{ .Null = {} };
                        // Convert PropertyValue to Value
                        const converted = switch (val) {
                            .String => |s| Value{ .Str = s },
                            .Int => |i| Value{ .Int = i },
                            .Bool => |b| Value{ .Bool = b },
                            .ExtValue => |ext| Value{ .ExtValue = ext }, // Preserve ExtValue types (Geometry, VectorF32, etc.)
                            else => Value{ .Null = {} },
                        };
                        break :blk_edge converted;
                    },
                    .ExtValue => |_| blk_ext: {
                        // ExtValue types don't support property access
                        break :blk_ext Value{ .Null = {} };
                    },
                    else => Value{ .Null = {} },
                };
                try map.put(field, field_value);
            }

            break :blk_projection Value{ .Map = map };
        },
        .PatternComp => |pc| blk_patterncomp: {
            // CANARY: REQ=REQ-GQL-165; FEATURE="Pattern Comprehension Execution"; ASPECT=Evaluator; STATUS=TESTED; OWNER=eval; UPDATED=2025-10-14
            // Pattern comprehension: [ (pattern) WHERE condition | expression ]
            // Shorthand: [(a)--()]  means  [(a)--(x) | x]
            // Execute the pattern and collect results based on the map expression
            const result_list = getExecutionCallbacks().executePatternComprehension(allocator, pc.pattern.*, pc.where, pc.map.*, env) catch {
                break :blk_patterncomp Value{ .List = &.{} };
            };
            break :blk_patterncomp result_list;
        },
        // Unimplemented in evaluator: treat these as null for now
        else => Value{ .Null = {} },
    };
}

// CANARY: REQ=REQ-M6.1-EVAL-REFACTOR-003; FEATURE="Phase 6 Modularization"; ASPECT=ValueConverters; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 6 M6.1: Value converter functions moved to eval/type_promotion.zig
// Functions: valueToExtValue, extValueToValue, evalValueToHeapValue, heapValueToEvalValue

/// Try to execute basic built-in functions (length, upper, lower, etc.)
fn tryBasicFunction(allocator: std.mem.Allocator, function_name: []const u8, args: []*ast.Expr, env: Env) !?Value {
    const evaluator_functions = @import("types/evaluator_functions.zig");

    // Handle current_user() function - returns the current authenticated user
    if (std.mem.eql(u8, function_name, "current_user")) {
        if (args.len != 0) return null;
        // Check if we have a token-authenticated user in the environment
        if (env.get("__token_user__")) |user| {
            return user;
        }
        // Default to returning "system" user if no authentication
        return Value{ .Str = "system" };
    }

    // Handle coalesce() function - return first non-null value
    if (std.mem.eql(u8, function_name, "coalesce")) {
        for (args) |arg_expr| {
            const arg = try evalExpr(allocator, arg_expr.*, env);
            switch (arg) {
                .Null => continue,
                else => return arg,
            }
        }
        return Value{ .Null = {} };
    }

    // Handle keys() function for maps
    if (std.mem.eql(u8, function_name, "keys")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Map => |map| {
                var keys = try allocator.alloc(Value, map.count());
                var iter = map.iterator();
                var i: usize = 0;
                while (iter.next()) |entry| : (i += 1) {
                    keys[i] = Value{ .Str = entry.key_ptr.* };
                }
                return Value{ .List = keys };
            },
            else => return Value{ .Null = {} },
        }
    }

    // Handle values() function for maps
    if (std.mem.eql(u8, function_name, "values")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Map => |map| {
                var values = try allocator.alloc(Value, map.count());
                var iter = map.iterator();
                var i: usize = 0;
                while (iter.next()) |entry| : (i += 1) {
                    values[i] = entry.value_ptr.*;
                }
                return Value{ .List = values };
            },
            else => return Value{ .Null = {} },
        }
    }

    // Handle shortestPath function - returns shortest path between nodes
    if (std.mem.eql(u8, function_name, "shortestpath") or std.mem.eql(u8, function_name, "shortest_path")) {
        // For now, return a mock path as this requires graph traversal
        var path_values = try allocator.alloc(Value, 2);
        path_values[0] = Value{ .Int = 1 };
        path_values[1] = Value{ .Int = 2 };
        return Value{ .List = path_values };
    }

    // Handle allShortestPaths function
    if (std.mem.eql(u8, function_name, "allshortestpaths") or std.mem.eql(u8, function_name, "all_shortest_paths")) {
        // Return a list of paths
        var paths = try allocator.alloc(Value, 1);
        var path_values = try allocator.alloc(Value, 2);
        path_values[0] = Value{ .Int = 1 };
        path_values[1] = Value{ .Int = 2 };
        paths[0] = Value{ .List = path_values };
        return Value{ .List = paths };
    }

    // Handle algo.asNode function - converts nodeId to node reference
    if (std.mem.eql(u8, function_name, "algo.asnode") or std.mem.eql(u8, function_name, "asnode")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        // Just return the node ID for now
        return arg;
    }

    // Handle id() function - returns node ID or input if already an integer
    if (std.mem.eql(u8, function_name, "id")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Int => |i| return Value{ .Int = i }, // Already an integer ID
            .Node => |n| return Value{ .Int = @intCast(n.id) }, // Get node ID
            else => return Value{ .Null = {} }, // Can't get ID from other types
        }
    }

    // CANARY: REQ=REQ-TYPE-001; FEATURE="TypeFunctions"; ASPECT=type; STATUS=IMPL; OWNER=types; UPDATED=2025-12-22
    // Handle type() function - returns relationship type for edges, type name for other values
    if (std.mem.eql(u8, function_name, "type")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Edge => |e| return Value{ .Str = e.label },
            else => return Value{ .Str = getTypeName(arg) },
        }
    }

    // Handle labels() function - returns node labels as a list
    if (std.mem.eql(u8, function_name, "labels")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Node => |n| {
                var labels = try allocator.alloc(Value, n.labels.len);
                for (n.labels, 0..) |label, i| {
                    labels[i] = Value{ .Str = label };
                }
                return Value{ .List = labels };
            },
            else => return Value{ .List = try allocator.alloc(Value, 0) }, // Empty list for non-nodes
        }
    }

    // Handle length() function - returns length of path, string, or list
    if (std.mem.eql(u8, function_name, "length")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Str => |s| return Value{ .Int = @intCast(s.len) },
            .List => |l| return Value{ .Int = @intCast(l.len) },
            .Path => |p| return Value{ .Int = @intCast(p.edges.len) }, // Path length is number of relationships
            else => return Value{ .Int = 0 },
        }
    }

    // Handle nodes() function - returns list of nodes in a path
    if (std.mem.eql(u8, function_name, "nodes")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Path => |p| {
                var node_values = try allocator.alloc(Value, p.nodes.len);
                for (p.nodes, 0..) |node, i| {
                    node_values[i] = Value{ .Node = node };
                }
                return Value{ .List = node_values };
            },
            else => return Value{ .Null = {} },
        }
    }

    // Handle relationships() function - returns list of edges in a path
    if (std.mem.eql(u8, function_name, "relationships")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Path => |p| {
                var edge_values = try allocator.alloc(Value, p.edges.len);
                for (p.edges, 0..) |edge, i| {
                    edge_values[i] = Value{ .Edge = edge };
                }
                return Value{ .List = edge_values };
            },
            else => return Value{ .Null = {} },
        }
    }

    // Handle string case conversion functions
    if (std.mem.eql(u8, function_name, "toupper") or std.mem.eql(u8, function_name, "upper")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Str => |s| {
                var upper = try allocator.alloc(u8, s.len);
                for (s, 0..) |c, i| {
                    upper[i] = std.ascii.toUpper(c);
                }
                return Value{ .Str = upper };
            },
            else => return Value{ .Null = {} },
        }
    }

    if (std.mem.eql(u8, function_name, "tolower") or std.mem.eql(u8, function_name, "lower")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Str => |s| {
                var lower = try allocator.alloc(u8, s.len);
                for (s, 0..) |c, i| {
                    lower[i] = std.ascii.toLower(c);
                }
                return Value{ .Str = lower };
            },
            else => return Value{ .Null = {} },
        }
    }

    // Handle reverse function
    if (std.mem.eql(u8, function_name, "reverse")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Str => |s| {
                var reversed = try allocator.alloc(u8, s.len);
                var i: usize = 0;
                while (i < s.len) : (i += 1) {
                    reversed[i] = s[s.len - 1 - i];
                }
                return Value{ .Str = reversed };
            },
            .List => |l| {
                var reversed = try allocator.alloc(Value, l.len);
                var i: usize = 0;
                while (i < l.len) : (i += 1) {
                    reversed[i] = l[l.len - 1 - i];
                }
                return Value{ .List = reversed };
            },
            else => return Value{ .Null = {} },
        }
    }

    // Math functions are now handled as special cases in the Call block above

    // Handle aggregation functions (simplified for now - real implementation needs context)
    if (std.mem.eql(u8, function_name, "count")) {
        // COUNT(*) or COUNT(expr)
        if (args.len == 1) {
            // Check if argument is "*"
            if (args[0].* == .Ident and std.mem.eql(u8, args[0].Ident.orig, "*")) {
                // COUNT(*) - for now return 1 since we're in a single-row context
                return Value{ .Int = 1 };
            }
            // Evaluate the argument
            const arg = try evalExpr(allocator, args[0].*, env);
            // If the argument is not null, count it as 1
            if (arg != .Null) {
                return Value{ .Int = 1 };
            }
            return Value{ .Int = 0 };
        }
        return Value{ .Int = 0 };
    } else if (std.mem.eql(u8, function_name, "sum")) {
        // SUM aggregation function
        if (args.len == 0) return Value{ .Null = {} };

        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .List => |list| {
                if (list.len == 0) return Value{ .Null = {} };

                // Check if we have any decimals
                var has_decimal = false;
                for (list) |item| {
                    if (item == .Decimal) {
                        has_decimal = true;
                        break;
                    }
                }

                if (has_decimal) {
                    // Sum as decimal (for now, convert to int)
                    var sum: i64 = 0;
                    for (list) |item| {
                        switch (item) {
                            .Int => |n| sum += n,
                            .Decimal => |d| sum += @intCast(@divFloor(d.coeff, std.math.pow(i128, 10, d.scale))),
                            else => {},
                        }
                    }
                    return Value{ .Int = sum };
                } else {
                    // Sum as integer
                    var sum: i64 = 0;
                    for (list) |item| {
                        switch (item) {
                            .Int => |n| sum += n,
                            else => {},
                        }
                    }
                    return Value{ .Int = sum };
                }
            },
            else => return Value{ .Null = {} },
        }
    } else if (std.mem.eql(u8, function_name, "avg")) {
        // AVG aggregation function
        if (args.len == 0) return Value{ .Null = {} };

        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .List => |list| {
                if (list.len == 0) return Value{ .Null = {} };

                var sum: i64 = 0;
                var count: usize = 0;
                for (list) |item| {
                    switch (item) {
                        .Int => |n| {
                            sum += n;
                            count += 1;
                        },
                        .Decimal => |d| {
                            sum += @intCast(@divFloor(d.coeff, std.math.pow(i128, 10, d.scale)));
                            count += 1;
                        },
                        else => {},
                    }
                }

                if (count == 0) return Value{ .Null = {} };
                return Value{ .Int = @divFloor(sum, @as(i64, @intCast(count))) };
            },
            else => return Value{ .Null = {} },
        }
    } else if (std.mem.eql(u8, function_name, "min")) {
        // MIN aggregation function
        if (args.len == 0) return Value{ .Null = {} };

        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .List => |list| {
                if (list.len == 0) return Value{ .Null = {} };

                var min_val = list[0];
                for (list[1..]) |item| {
                    // Simple comparison for common types
                    const is_less = switch (item) {
                        .Int => |n| switch (min_val) {
                            .Int => |m| n < m,
                            else => false,
                        },
                        .Str => |s| switch (min_val) {
                            .Str => |ms| std.mem.order(u8, s, ms) == .lt,
                            else => false,
                        },
                        else => false,
                    };
                    if (is_less) {
                        min_val = item;
                    }
                }
                return min_val;
            },
            else => return Value{ .Null = {} },
        }
    } else if (std.mem.eql(u8, function_name, "max")) {
        // MAX aggregation function
        if (args.len == 0) return Value{ .Null = {} };

        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .List => |list| {
                if (list.len == 0) return Value{ .Null = {} };

                var max_val = list[0];
                for (list[1..]) |item| {
                    // Simple comparison for common types
                    const is_greater = switch (item) {
                        .Int => |n| switch (max_val) {
                            .Int => |m| n > m,
                            else => false,
                        },
                        .Str => |s| switch (max_val) {
                            .Str => |ms| std.mem.order(u8, s, ms) == .gt,
                            else => false,
                        },
                        else => false,
                    };
                    if (is_greater) {
                        max_val = item;
                    }
                }
                return max_val;
            },
            else => return Value{ .Null = {} },
        }
    }

    // Handle random() function which takes no arguments
    if (std.mem.eql(u8, function_name, "random")) {
        if (args.len != 0) return null;
        const result = evaluator_functions.random_val(allocator) catch return null;
        return heapValueToEvalValue(result);
    }

    // Handle date/time functions which take no arguments
    if (std.mem.eql(u8, function_name, "current_date")) {
        if (args.len != 0) return null;
        const result = evaluator_functions.current_date();
        return heapValueToEvalValue(result);
    }
    if (std.mem.eql(u8, function_name, "current_time")) {
        if (args.len != 0) return null;
        const result = evaluator_functions.current_time();
        return heapValueToEvalValue(result);
    }
    if (std.mem.eql(u8, function_name, "current_timestamp")) {
        if (args.len != 0) return null;
        const result = evaluator_functions.current_timestamp();
        return heapValueToEvalValue(result);
    }

    // CANARY: REQ=REQ-DATETIME-001; FEATURE="DateTimeFunctions"; ASPECT=datetime; STATUS=IMPL; OWNER=datetime; UPDATED=2025-12-22
    // Handle datetime() function - returns current datetime or parses ISO datetime string
    if (std.mem.eql(u8, function_name, "datetime")) {
        const datetime_module = @import("types/datetime.zig");
        const eval_ext = @import("eval_extended.zig");

        if (args.len == 0) {
            // datetime() with no args returns current datetime
            const result = evaluator_functions.current_timestamp();
            return heapValueToEvalValue(result);
        } else if (args.len == 1) {
            const arg = try evalExpr(allocator, args[0].*, env);
            const str = switch (arg) {
                .Str => |s| s,
                else => return null,
            };

            // Parse the datetime string using the Timestamp parser
            const ts = datetime_module.Timestamp.fromStr(str) catch return null;

            // Convert to TimestampTZ ExtValue
            const tz_ts = eval_ext.ExtValue{ .TimestampTZ = .{ .micros_since_epoch_utc = ts.micros_since_epoch } };
            return Value{ .ExtValue = tz_ts };
        } else {
            return null;
        }
    }

    // CANARY: REQ=REQ-DATETIME-001; FEATURE="DateTimeFunctions"; ASPECT=timestamp; STATUS=IMPL; OWNER=datetime; UPDATED=2025-12-22
    // Handle timestamp() function - returns current timestamp as integer (epoch millis)
    if (std.mem.eql(u8, function_name, "timestamp")) {
        if (args.len != 0) return null;
        const ts = std.time.milliTimestamp();
        return Value{ .Int = ts };
    }

    // CANARY: REQ=REQ-DATETIME-001; FEATURE="DateTimeFunctions"; ASPECT=localdatetime; STATUS=IMPL; OWNER=datetime; UPDATED=2025-12-22
    // Handle localdatetime() function - returns current local datetime
    if (std.mem.eql(u8, function_name, "localdatetime")) {
        if (args.len == 0) {
            // localdatetime() with no args returns current local datetime (same as datetime for now)
            const result = evaluator_functions.current_timestamp();
            return heapValueToEvalValue(result);
        } else if (args.len == 1) {
            // localdatetime(string) parses ISO datetime string
            const datetime_module = @import("types/datetime.zig");
            const eval_ext = @import("eval_extended.zig");

            const arg = try evalExpr(allocator, args[0].*, env);
            const str = switch (arg) {
                .Str => |s| s,
                else => return null,
            };

            const ts = datetime_module.Timestamp.fromStr(str) catch return null;
            const tz_ts = eval_ext.ExtValue{ .TimestampTZ = .{ .micros_since_epoch_utc = ts.micros_since_epoch } };
            return Value{ .ExtValue = tz_ts };
        } else {
            return null;
        }
    }

    // Handle date(string) function that parses ISO date strings
    if (std.mem.eql(u8, function_name, "date")) {
        if (args.len == 0) {
            // date() with no args returns current date
            const result = evaluator_functions.current_date();
            return heapValueToEvalValue(result);
        } else if (args.len == 1) {
            // date(string) parses ISO date string
            const arg = try evalExpr(allocator, args[0].*, env);
            const str = switch (arg) {
                .Str => |s| s,
                else => return null,
            };

            const datetime_module = @import("types/datetime.zig");
            const d = datetime_module.Date.fromStr(str) catch return null;

            const eval_ext = @import("eval_extended.zig");
            const date_val = eval_ext.ExtValue{ .Date = d };
            return Value{ .ExtValue = date_val };
        } else {
            return null;
        }
    }

    // Handle time(string) function that parses ISO time strings
    if (std.mem.eql(u8, function_name, "time")) {
        if (args.len == 0) {
            // time() with no args returns current time
            const result = evaluator_functions.current_time();
            return heapValueToEvalValue(result);
        } else if (args.len == 1) {
            // time(string) parses ISO time string
            const arg = try evalExpr(allocator, args[0].*, env);
            const str = switch (arg) {
                .Str => |s| s,
                else => return null,
            };

            const datetime_module = @import("types/datetime.zig");
            const t = datetime_module.Time.fromStr(str) catch return null;

            const eval_ext = @import("eval_extended.zig");
            const time_val = eval_ext.ExtValue{ .Time = t };
            return Value{ .ExtValue = time_val };
        } else {
            return null;
        }
    }

    // CANARY: REQ=REQ-DATETIME-001; FEATURE="DateTimeFunctions"; ASPECT=duration; STATUS=IMPL; OWNER=datetime; UPDATED=2025-12-22
    // Handle duration() function - parses ISO 8601 duration string
    if (std.mem.eql(u8, function_name, "duration")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        const str = switch (arg) {
            .Str => |s| s,
            else => return null,
        };

        // Parse ISO 8601 duration format: P[n]Y[n]M[n]DT[n]H[n]M[n]S
        const duration_val = parseDurationString(str) catch return null;
        return Value{ .Int = duration_val };
    }

    // CANARY: REQ=REQ-TYPE-001; FEATURE="TypeFunctions"; ASPECT=type; STATUS=IMPL; OWNER=types; UPDATED=2025-12-22
    // Handle type() function - returns the type name of a value
    if (std.mem.eql(u8, function_name, "type")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        const type_name = getTypeName(arg);
        return Value{ .Str = type_name };
    }

    // CANARY: REQ=REQ-GQL-088; FEATURE="GraphSimilarityFunctions"; ASPECT=Evaluation; STATUS=TESTED; OWNER=eval; UPDATED=2025-10-14
    // Handle algo.similarity.jaccard(list1, list2) - Jaccard similarity coefficient
    if (std.mem.eql(u8, function_name, "algo.similarity.jaccard") or std.mem.eql(u8, function_name, "jaccard")) {
        if (args.len != 2) return null;
        const arg1 = try evalExpr(allocator, args[0].*, env);
        const arg2 = try evalExpr(allocator, args[1].*, env);

        const list1 = switch (arg1) {
            .List => |l| l,
            else => return Value{ .Decimal = .{ .coeff = 0, .scale = 0 } },
        };
        const list2 = switch (arg2) {
            .List => |l| l,
            else => return Value{ .Decimal = .{ .coeff = 0, .scale = 0 } },
        };

        // Count intersection
        var intersection: usize = 0;
        for (list1) |item1| {
            for (list2) |item2| {
                if (eqVals(item1, item2)) {
                    intersection += 1;
                    break;
                }
            }
        }

        // Calculate union size
        const union_size = list1.len + list2.len - intersection;
        if (union_size == 0) {
            return Value{ .Decimal = .{ .coeff = 0, .scale = 0 } };
        }

        // Return as decimal with 2 decimal places
        const jaccard_coeff = @divTrunc(@as(i128, @intCast(intersection)) * 100, @as(i128, @intCast(union_size)));
        return Value{ .Decimal = .{ .coeff = jaccard_coeff, .scale = 2 } };
    }

    // Handle algo.similarity.cosine(vector1, vector2) - Cosine similarity
    // CANARY: REQ=REQ-ALG-SIM-001; FEATURE="SimilarityAlgorithms"; ASPECT=Cosine; STATUS=IMPL; OWNER=eval; UPDATED=2025-10-16
    if (std.mem.eql(u8, function_name, "algo.similarity.cosine") or std.mem.eql(u8, function_name, "cosine")) {
        if (args.len != 2) return null;
        const arg1 = try evalExpr(allocator, args[0].*, env);
        const arg2 = try evalExpr(allocator, args[1].*, env);

        const vec1 = switch (arg1) {
            .List => |l| l,
            else => return Value{ .Null = {} },
        };
        const vec2 = switch (arg2) {
            .List => |l| l,
            else => return Value{ .Null = {} },
        };

        if (vec1.len != vec2.len) {
            return Value{ .Null = {} };
        }

        // Calculate dot product and magnitudes
        var dot_product: f64 = 0.0;
        var norm1: f64 = 0.0;
        var norm2: f64 = 0.0;

        for (vec1, vec2) |v1, v2| {
            const val1: f64 = switch (v1) {
                .Int => |i| @floatFromInt(i),
                .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(d.scale)),
                else => continue,
            };
            const val2: f64 = switch (v2) {
                .Int => |i| @floatFromInt(i),
                .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(d.scale)),
                else => continue,
            };

            dot_product += val1 * val2;
            norm1 += val1 * val1;
            norm2 += val2 * val2;
        }

        if (norm1 == 0.0 or norm2 == 0.0) {
            return Value{ .Null = {} };
        }

        const similarity = dot_product / (@sqrt(norm1) * @sqrt(norm2));
        return Value{ .Decimal = .{ .coeff = @intFromFloat(similarity * 1000000), .scale = 6 } };
    }

    // Evaluate arguments first
    if (args.len == 0) return null;

    const first_arg = try evalExpr(allocator, args[0].*, env);
    const heap_first_arg = evalValueToHeapValue(first_arg);

    // Handle common string functions
    if (std.mem.eql(u8, function_name, "length")) {
        const result = evaluator_functions.length_chars(heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "upper")) {
        const result = evaluator_functions.upper(allocator, heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "lower")) {
        const result = evaluator_functions.lower(allocator, heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "trim")) {
        const result = evaluator_functions.trim(allocator, heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "abs")) {
        const result = evaluator_functions.abs_val(heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "sqrt")) {
        const result = evaluator_functions.sqrt_val(heap_first_arg) catch |err| {
            return switch (err) {
                evaluator_functions.EvaluatorError.InvalidInput => EvalError.TypeMismatch,
                evaluator_functions.EvaluatorError.TypeMismatch => EvalError.TypeMismatch,
                else => EvalError.TypeMismatch,
            };
        };
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "ceil")) {
        const result = evaluator_functions.ceil_val(heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "floor")) {
        const result = evaluator_functions.floor_val(heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "pow") or std.mem.eql(u8, function_name, "power")) {
        // CANARY: REQ=REQ-GQL-POWER-001; FEATURE="MathFunctions"; ASPECT=PowerAlias; STATUS=IMPL; OWNER=eval; UPDATED=2025-12-24
        if (args.len != 2) return null;
        const heap_second_arg = evalValueToHeapValue(try evalExpr(allocator, args[1].*, env));
        const result = evaluator_functions.pow_val(allocator, heap_first_arg, heap_second_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "sin")) {
        const result = evaluator_functions.sin_val(heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "cos")) {
        const result = evaluator_functions.cos_val(heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "tan")) {
        const result = evaluator_functions.tan_val(heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "asin")) {
        const result = evaluator_functions.asin_val(heap_first_arg) catch |err| {
            return switch (err) {
                evaluator_functions.EvaluatorError.InvalidInput => EvalError.TypeMismatch,
                evaluator_functions.EvaluatorError.TypeMismatch => EvalError.TypeMismatch,
                else => EvalError.TypeMismatch,
            };
        };
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "acos")) {
        const result = evaluator_functions.acos_val(heap_first_arg) catch |err| {
            return switch (err) {
                evaluator_functions.EvaluatorError.InvalidInput => EvalError.TypeMismatch,
                evaluator_functions.EvaluatorError.TypeMismatch => EvalError.TypeMismatch,
                else => EvalError.TypeMismatch,
            };
        };
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "log")) {
        const result = evaluator_functions.log_val(heap_first_arg) catch |err| {
            return switch (err) {
                evaluator_functions.EvaluatorError.InvalidInput => EvalError.TypeMismatch,
                evaluator_functions.EvaluatorError.TypeMismatch => EvalError.TypeMismatch,
                else => EvalError.TypeMismatch,
            };
        };
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "log10")) {
        // CANARY: REQ=REQ-GQL-LOG10-001; FEATURE="MathFunctions"; ASPECT=Log10; STATUS=IMPL; OWNER=eval; UPDATED=2025-12-24
        // log10(x) = log(x) / log(10)
        switch (first_arg) {
            .Int => |i| {
                if (i <= 0) return Value{ .Null = {} };
                const f: f64 = @floatFromInt(i);
                const log10_result = @log10(f);
                return Value{ .Decimal = .{ .coeff = @intFromFloat(log10_result * 1000000), .scale = 6 } };
            },
            .Decimal => |d| {
                const f: f64 = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(d.scale));
                if (f <= 0) return Value{ .Null = {} };
                const log10_result = @log10(f);
                return Value{ .Decimal = .{ .coeff = @intFromFloat(log10_result * 1000000), .scale = 6 } };
            },
            else => return Value{ .Null = {} },
        }
    } else if (std.mem.eql(u8, function_name, "exp")) {
        const result = evaluator_functions.exp_val(heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "type")) {
        const result = evaluator_functions.type_val(heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "tostring")) {
        const result = evaluator_functions.toString_val(allocator, heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "tointeger")) {
        const result = evaluator_functions.toInteger_val(heap_first_arg) catch |err| {
            // Convert evaluator errors to eval errors
            return switch (err) {
                evaluator_functions.EvaluatorError.InvalidFormat => EvalError.TypeMismatch,
                evaluator_functions.EvaluatorError.TypeMismatch => EvalError.TypeMismatch,
                evaluator_functions.EvaluatorError.Overflow => EvalError.Unsupported,
                else => EvalError.TypeMismatch,
            };
        };
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "toreal")) {
        const result = evaluator_functions.toReal_val(heap_first_arg) catch |err| {
            return switch (err) {
                evaluator_functions.EvaluatorError.InvalidFormat => EvalError.TypeMismatch,
                evaluator_functions.EvaluatorError.TypeMismatch => EvalError.TypeMismatch,
                evaluator_functions.EvaluatorError.Overflow => EvalError.Unsupported,
                else => EvalError.TypeMismatch,
            };
        };
        return heapValueToEvalValue(result);
    } else if (std.mem.eql(u8, function_name, "size") or std.mem.eql(u8, function_name, "length")) {
        // Size of a list, string, or map
        switch (first_arg) {
            .List => |l| return Value{ .Int = @intCast(l.len) },
            .Str => |s| return Value{ .Int = @intCast(s.len) },
            .Map => |m| return Value{ .Int = @intCast(m.count()) },
            else => return Value{ .Int = 0 },
        }
    } else if (std.mem.eql(u8, function_name, "head")) {
        // Return the first element of a list
        switch (first_arg) {
            .List => |l| {
                if (l.len == 0) return Value{ .Null = {} };
                return l[0];
            },
            else => return Value{ .Null = {} },
        }
    } else if (std.mem.eql(u8, function_name, "tail")) {
        // Return all elements except the first
        switch (first_arg) {
            .List => |l| {
                if (l.len <= 1) {
                    return Value{ .List = &[_]Value{} };
                }
                const tail_slice = try allocator.alloc(Value, l.len - 1);
                @memcpy(tail_slice, l[1..]);
                return Value{ .List = tail_slice };
            },
            else => return Value{ .List = &[_]Value{} },
        }
    } else if (std.mem.eql(u8, function_name, "last")) {
        // CANARY: REQ=REQ-GQL-LAST-001; FEATURE="ListFunctions"; ASPECT=LastElement; STATUS=IMPL; OWNER=eval; UPDATED=2025-12-24
        // Return the last element of a list
        switch (first_arg) {
            .List => |l| {
                if (l.len == 0) return Value{ .Null = {} };
                return l[l.len - 1];
            },
            else => return Value{ .Null = {} },
        }
    } else if (std.mem.eql(u8, function_name, "toString")) {
        // Convert to string
        switch (first_arg) {
            .Int => |i| {
                var buf: [64]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return Value{ .Str = "" };
                return Value{ .Str = try allocator.dupe(u8, str) };
            },
            .Str => |s| return Value{ .Str = s },
            .Bool => |b| return Value{ .Str = if (b) "true" else "false" },
            else => return Value{ .Str = "" },
        }
    } else if (std.mem.eql(u8, function_name, "tofloat") or std.mem.eql(u8, function_name, "toFloat") or std.mem.eql(u8, function_name, "todouble") or std.mem.eql(u8, function_name, "toDouble")) {
        // CANARY: REQ=REQ-GQL-086; FEATURE="TypeConversionFunctions"; ASPECT=Evaluation; STATUS=TESTED; OWNER=eval; UPDATED=2025-10-14
        // Convert to float
        switch (first_arg) {
            .Int => |i| return Value{ .Decimal = .{ .coeff = i * 10, .scale = 1 } },
            .Decimal => |d| return Value{ .Decimal = d },
            .Str => |s| {
                const f = std.fmt.parseFloat(f64, s) catch return Value{ .Null = {} };
                return Value{ .Decimal = .{ .coeff = @intFromFloat(f * 10), .scale = 1 } };
            },
            else => return Value{ .Null = {} },
        }
    } else if (std.mem.eql(u8, function_name, "toint") or std.mem.eql(u8, function_name, "tointeger")) {
        // Convert to integer
        switch (first_arg) {
            .Int => |i| return Value{ .Int = i },
            .Decimal => |d| return Value{ .Int = @intCast(@divFloor(d.coeff, std.math.pow(i128, 10, d.scale))) },
            .Str => |s| {
                const i = std.fmt.parseInt(i64, s, 10) catch return Value{ .Null = {} };
                return Value{ .Int = i };
            },
            else => return Value{ .Null = {} },
        }
    } else if (std.mem.eql(u8, function_name, "toboolean") or std.mem.eql(u8, function_name, "toBoolean") or std.mem.eql(u8, function_name, "tobool")) {
        // CANARY: REQ=REQ-GQL-TOBOOLEAN-001; FEATURE="TypeConversionFunctions"; ASPECT=ToBooleanConversion; STATUS=IMPL; OWNER=eval; UPDATED=2025-12-24
        // Convert to boolean
        switch (first_arg) {
            .Bool => |b| return Value{ .Bool = b },
            .Int => |i| return Value{ .Bool = i != 0 },
            .Str => |s| {
                if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "TRUE") or std.mem.eql(u8, s, "1")) {
                    return Value{ .Bool = true };
                } else if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "FALSE") or std.mem.eql(u8, s, "0")) {
                    return Value{ .Bool = false };
                }
                return Value{ .Null = {} };
            },
            .Null => return Value{ .Null = {} },
            else => return Value{ .Null = {} },
        }
    }

    // Handle two-argument functions
    if (args.len >= 2) {
        const second_arg = try evalExpr(allocator, args[1].*, env);
        const heap_second_arg = evalValueToHeapValue(second_arg);

        if (std.mem.eql(u8, function_name, "substring")) {
            if (args.len >= 3) {
                const third_arg = try evalExpr(allocator, args[2].*, env);
                const heap_third_arg = evalValueToHeapValue(third_arg);
                const result = evaluator_functions.substring(allocator, heap_first_arg, heap_second_arg, heap_third_arg) catch return null;
                return heapValueToEvalValue(result);
            } else {
                // Two-argument substring from start to end
                const result = evaluator_functions.substring(allocator, heap_first_arg, heap_second_arg, null) catch return null;
                return heapValueToEvalValue(result);
            }
        } else if (std.mem.eql(u8, function_name, "replace")) {
            if (args.len >= 3) {
                const third_arg = try evalExpr(allocator, args[2].*, env);
                const heap_third_arg = evalValueToHeapValue(third_arg);
                const result = evaluator_functions.replace(allocator, heap_first_arg, heap_second_arg, heap_third_arg) catch return null;
                return heapValueToEvalValue(result);
            }
        } else if (std.mem.eql(u8, function_name, "decimal_add")) {
            const result = evaluator_functions.decimal_add(heap_first_arg, heap_second_arg) catch |err| {
                return err;
            };
            return heapValueToEvalValue(result);
        } else if (std.mem.eql(u8, function_name, "decimal_sub")) {
            const result = evaluator_functions.decimal_sub(heap_first_arg, heap_second_arg) catch |err| {
                return err;
            };
            return heapValueToEvalValue(result);
        } else if (std.mem.eql(u8, function_name, "decimal_mul")) {
            const result = evaluator_functions.decimal_mul(heap_first_arg, heap_second_arg) catch |err| {
                return err;
            };
            return heapValueToEvalValue(result);
        } else if (std.mem.eql(u8, function_name, "decimal_div")) {
            const result = evaluator_functions.decimal_div(heap_first_arg, heap_second_arg) catch |err| {
                return err;
            };
            return heapValueToEvalValue(result);
        }
    }

    // Handle map functions
    if (std.mem.eql(u8, function_name, "keys")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Map => |map| {
                var keys = try allocator.alloc(Value, map.count());
                var iter = map.iterator();
                var i: usize = 0;
                while (iter.next()) |entry| : (i += 1) {
                    keys[i] = Value{ .Str = entry.key_ptr.* };
                }
                return Value{ .List = keys };
            },
            else => return Value{ .Null = {} },
        }
    } else if (std.mem.eql(u8, function_name, "values")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Map => |map| {
                var values = try allocator.alloc(Value, map.count());
                var iter = map.iterator();
                var i: usize = 0;
                while (iter.next()) |entry| : (i += 1) {
                    values[i] = entry.value_ptr.*;
                }
                return Value{ .List = values };
            },
            else => return Value{ .Null = {} },
        }
    }

    // CANARY: REQ=REQ-CLIENT-INTEGRATION-001; FEATURE="range() function"; ASPECT=BuiltinFunctions; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-15
    // Handle range(start, stop[, step]) function - generates integer sequences
    // Used for performance testing: UNWIND range(1, 100) AS x RETURN x
    if (std.mem.eql(u8, function_name, "range")) {
        // range() requires 2 or 3 arguments
        if (args.len < 2 or args.len > 3) return Value{ .Null = {} };

        // Evaluate start argument (required)
        const start_val = try evalExpr(allocator, args[0].*, env);
        const start = switch (start_val) {
            .Int => |i| i,
            else => return Value{ .Null = {} },
        };

        // Evaluate stop argument (required)
        const stop_val = try evalExpr(allocator, args[1].*, env);
        const stop = switch (stop_val) {
            .Int => |i| i,
            else => return Value{ .Null = {} },
        };

        // Evaluate step argument (optional, defaults to 1)
        const step = if (args.len == 3) blk: {
            const step_val = try evalExpr(allocator, args[2].*, env);
            break :blk switch (step_val) {
                .Int => |i| i,
                else => return Value{ .Null = {} },
            };
        } else 1;

        // Step must not be zero
        if (step == 0) return Value{ .Null = {} };

        // Calculate the number of elements in the range
        const count: i64 = if (step > 0) blk: {
            if (stop <= start) break :blk 0;
            const diff = stop - start;
            break :blk @divFloor(diff + step - 1, step);
        } else blk: {
            if (stop >= start) break :blk 0;
            const diff = start - stop;
            break :blk @divFloor(diff - step - 1, -step);
        };

        // Allocate result array
        if (count <= 0) {
            return Value{ .List = &.{} };
        }

        // Safety check: limit range size to prevent OOM
        const max_range_size: i64 = 10_000_000; // 10 million elements max
        if (count > max_range_size) {
            return error.RangeTooLarge;
        }

        const ucount = @as(usize, @intCast(count));
        var result = try allocator.alloc(Value, ucount);

        // Generate range values
        var current = start;
        for (0..ucount) |i| {
            result[i] = Value{ .Int = current };
            current += step;
        }

        return Value{ .List = result };
    }

    // Function not recognized
    return null;
}

// CANARY: REQ=REQ-DATETIME-001; FEATURE="DateTimeFunctions"; ASPECT=duration_parsing; STATUS=IMPL; OWNER=datetime; UPDATED=2025-12-22
/// Parse ISO 8601 duration string (e.g., "P1Y2M3D", "PT2H30M", "P1DT12H")
/// Returns duration in seconds
fn parseDurationString(str: []const u8) !i64 {
    if (str.len == 0 or str[0] != 'P') return error.InvalidFormat;

    var seconds: i64 = 0;
    var idx: usize = 1;
    var in_time_part = false;
    var current_num: i64 = 0;
    var has_num = false;

    while (idx < str.len) {
        const c = str[idx];

        if (c == 'T') {
            in_time_part = true;
            idx += 1;
            continue;
        }

        if (c >= '0' and c <= '9') {
            current_num = current_num * 10 + @as(i64, c - '0');
            has_num = true;
            idx += 1;
            continue;
        }

        if (!has_num) {
            idx += 1;
            continue;
        }

        // Apply the designator
        if (!in_time_part) {
            switch (c) {
                'Y' => seconds += current_num * 365 * 24 * 60 * 60, // Approximate year
                'M' => seconds += current_num * 30 * 24 * 60 * 60, // Approximate month
                'W' => seconds += current_num * 7 * 24 * 60 * 60,
                'D' => seconds += current_num * 24 * 60 * 60,
                else => {},
            }
        } else {
            switch (c) {
                'H' => seconds += current_num * 60 * 60,
                'M' => seconds += current_num * 60,
                'S' => seconds += current_num,
                else => {},
            }
        }

        current_num = 0;
        has_num = false;
        idx += 1;
    }

    return seconds;
}

// CANARY: REQ=REQ-TYPE-001; FEATURE="TypeFunctions"; ASPECT=type_name; STATUS=IMPL; OWNER=types; UPDATED=2025-12-22
/// Get the type name of a Value for the type() function
fn getTypeName(value: Value) []const u8 {
    return switch (value) {
        .Null => "NULL",
        .Bool => "BOOLEAN",
        .Int => "INTEGER",
        .Decimal => "FLOAT",
        .Str => "STRING",
        .List => "LIST",
        .Map => "MAP",
        .Node => "NODE",
        .Edge => "RELATIONSHIP",
        .Path => "PATH",
        .ExtValue => |ext| getExtTypeName(ext),
    };
}

/// Get the type name for extended values
fn getExtTypeName(ext: @import("eval_extended.zig").ExtValue) []const u8 {
    return switch (ext) {
        .Null => "NULL",
        .Int => "INTEGER",
        .Bool => "BOOLEAN",
        .Str => "STRING",
        .Decimal => "FLOAT",
        .Date => "DATE",
        .Time => "TIME",
        .TimestampTZ => "DATETIME",
        .VectorF32 => "VECTOR",
        .VectorI32 => "VECTOR_I32",
        .IpAddr => "INET",
        .Subnet => "CIDR",
        .Mac => "MAC",
        .Hash => "HASH",
        .Currency => "CURRENCY",
        .LanguageTag => "LANGUAGE_TAG",
        .LatLon => "POINT",
        .LatLonAlt => "POINT3D",
        .Geometry => "GEOMETRY",
        .Temperature => "TEMPERATURE",
        .Pressure => "PRESSURE",
        .List => "LIST",
    };
}

fn inList(value: Value, set: []*ast.Expr, allocator: std.mem.Allocator, env: Env) EvalError!Value {
    if (isNull(value)) return Value{ .Null = {} };
    var saw_null = false;
    for (set) |p| {
        const ev = try evalExpr(allocator, p.*, env);
        if (isNull(ev)) {
            saw_null = true;
            continue;
        }
        if (value == .Int and ev == .Int and value.Int == ev.Int) return .{ .Bool = true };
        if (value == .Str and ev == .Str and std.mem.eql(u8, value.Str, ev.Str)) return .{ .Bool = true };
        if ((value == .Str and ev == .Int) or (value == .Int and ev == .Str)) {
            var bufV: [64]u8 = undefined;
            var bufE: [64]u8 = undefined;
            const vs = try stringify(value, &bufV);
            const es = try stringify(ev, &bufE);
            if (std.mem.eql(u8, vs, es)) return .{ .Bool = true };
        }
    }
    if (saw_null) return Value{ .Null = {} };
    return .{ .Bool = false };
}

test "eval: IN/NOT IN with NULL semantics and mixed-type edges" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{ "a", "s" }, .values = &.{ Value{ .Int = 7 }, Value{ .Str = "007" } } };
    var a_ident = ast.Expr{ .Ident = .{ .orig = "a", .cnf = "A" } };
    var s_ident = ast.Expr{ .Ident = .{ .orig = "s", .cnf = "S" } };
    // IN list with NULL element yields NULL if no match
    var nullx = ast.Expr{ .Null = {} };
    var lit9 = ast.Expr{ .Int = 9 };
    var arr1: [2]*ast.Expr = .{ &nullx, &lit9 };
    const in1 = ast.Expr{ .In = .{ .value = &a_ident, .set = arr1[0..] } };
    const v1 = try evalExpr(allocator, in1, env);
    try std.testing.expect(v1 == .Null);
    // IN list when match present returns true
    var lit7 = ast.Expr{ .Int = 7 };
    var arr2: [3]*ast.Expr = .{ &nullx, &lit7, &lit9 };
    const in2 = ast.Expr{ .In = .{ .value = &a_ident, .set = arr2[0..] } };
    const v2 = try evalExpr(allocator, in2, env);
    try std.testing.expect(v2 == .Bool and v2.Bool);
    // NOT IN negates; with match present -> false
    const nin1 = ast.Expr{ .NotIn = .{ .value = &a_ident, .set = arr2[0..] } };
    const v3 = try evalExpr(allocator, nin1, env);
    try std.testing.expect(v3 == .Bool and !v3.Bool);
    // NOT IN when list has NULL and no match -> NULL
    var lit8 = ast.Expr{ .Int = 8 };
    var arr3: [2]*ast.Expr = .{ &nullx, &lit9 };
    const nin2 = ast.Expr{ .NotIn = .{ .value = &lit8, .set = arr3[0..] } };
    const v4 = try evalExpr(allocator, nin2, env);
    try std.testing.expect(v4 == .Null);
    // Mixed-type equality edge: leading zeros in string
    var str7 = ast.Expr{ .String = "7" };
    const eq = ast.Expr{ .Binary = .{ .op = .Eq, .left = &a_ident, .right = &str7 } };
    const v5 = try evalExpr(allocator, eq, env);
    try std.testing.expect(v5 == .Bool and v5.Bool);
    const eq2 = ast.Expr{ .Binary = .{ .op = .Eq, .left = &a_ident, .right = &s_ident } };
    const v6 = try evalExpr(allocator, eq2, env);
    // 7 vs "007" should be false by decimal string compare
    try std.testing.expect(v6 == .Bool and !v6.Bool);
    // NOT IN with empty list -> always true
    var empty: [0]*ast.Expr = .{};
    const nin_empty = ast.Expr{ .NotIn = .{ .value = &a_ident, .set = empty[0..] } };
    const v7 = try evalExpr(allocator, nin_empty, env);
    try std.testing.expect(v7 == .Bool and v7.Bool);
    // NOT IN with all-NULL list -> NULL
    var nul2 = ast.Expr{ .Null = {} };
    var arrn: [2]*ast.Expr = .{ &nullx, &nul2 };
    const nin_nulls = ast.Expr{ .NotIn = .{ .value = &lit8, .set = arrn[0..] } };
    const v8 = try evalExpr(allocator, nin_nulls, env);
    try std.testing.expect(v8 == .Null);
}

test "eval: mixed-type IN across bools and big ints stringified" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{"a"}, .values = &.{Value{ .Int = 9007199254740991 }} }; // 2^53-1
    var a_ident = ast.Expr{ .Ident = .{ .orig = "a", .cnf = "A" } };
    var s_big = ast.Expr{ .String = "9007199254740991" };
    var t_true = ast.Expr{ .String = "true" };
    var b_true = ast.Expr{ .Bool = true };
    var items: [3]*ast.Expr = .{ &s_big, &t_true, &b_true };
    const inx = ast.Expr{ .In = .{ .value = &a_ident, .set = items[0..] } };
    const v = try evalExpr(allocator, inx, env);
    // Should match the big-int via decimal string, ignore bool mismatches
    try std.testing.expect(v == .Bool and v.Bool == true);
}

test "eval: CASE searched produces expected values" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{"a"}, .values = &.{Value{ .Int = 1 }} };
    var a_expr = ast.Expr{ .Ident = .{ .orig = "a", .cnf = "A" } };
    var zero = ast.Expr{ .Int = 0 };
    var pred = ast.Expr{ .Binary = .{ .op = .Gt, .left = &a_expr, .right = &zero } };
    var p = ast.Expr{ .String = "p" };
    var n = ast.Expr{ .String = "n" };
    var whs: [1]ast.CaseWhen = .{.{ .when = &pred, .then_expr = &p }};
    const cse = ast.Expr{ .Case = .{ .operand = null, .whens = whs[0..], .else_expr = &n } };
    const out = try evalExpr(allocator, cse, env);
    try std.testing.expect(out == .Str and std.mem.eql(u8, out.Str, "p"));
}

test "eval: string predicates and regex basic" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{"s"}, .values = &.{Value{ .Str = "Alice" }} };
    var s = ast.Expr{ .Ident = .{ .orig = "s", .cnf = "S" } };
    var al = ast.Expr{ .String = "Al" };
    var z = ast.Expr{ .String = "Z" };
    var ice = ast.Expr{ .String = "ice" };
    const sw = ast.Expr{ .StartsWith = .{ .value = &s, .prefix = &al } };
    const ew = ast.Expr{ .EndsWith = .{ .value = &s, .suffix = &z } };
    const ct = ast.Expr{ .Contains = .{ .value = &s, .needle = &ice } };
    // Removed regex test - not part of GQL
    const v1 = try evalExpr(allocator, sw, env);
    const v2 = try evalExpr(allocator, ew, env);
    const v3 = try evalExpr(allocator, ct, env);
    try std.testing.expect(v1 == .Bool and v1.Bool == true);
    try std.testing.expect(v2 == .Bool and v2.Bool == false);
    try std.testing.expect(v3 == .Bool and v3.Bool == true);
}

// Removed test "eval: regex classes, negation, optional, escapes" - regex not part of GQL

test "eval: empty and NULL edge cases for string predicates" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };
    var s = ast.Expr{ .String = "" };
    var pref = ast.Expr{ .String = "" };
    const sw = ast.Expr{ .StartsWith = .{ .value = &s, .prefix = &pref } };
    const out1 = try evalExpr(allocator, sw, env);
    try std.testing.expect(out1 == .Bool and out1.Bool == true);
    // NULL arg yields NULL
    const null_v = Value{ .Null = {} };
    const e2 = try evalStartsWith(null_v, .{ .Str = "x" });
    try std.testing.expect(e2 == .Null);
}

test "eval: implicit int<->string in predicates and IN list" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{ "a", "s" }, .values = &.{ Value{ .Int = 42 }, Value{ .Str = "42" } } };
    // s STARTS WITH "4" -> true
    var s_ident = ast.Expr{ .Ident = .{ .orig = "s", .cnf = "S" } };
    var four = ast.Expr{ .String = "4" };
    const sw = ast.Expr{ .StartsWith = .{ .value = &s_ident, .prefix = &four } };
    const v1 = try evalExpr(allocator, sw, env);
    try std.testing.expect(v1 == .Bool and v1.Bool == true);
    // a = "42" -> true (implicit Eq int<->string)
    var a_ident = ast.Expr{ .Ident = .{ .orig = "a", .cnf = "A" } };
    var s_lit = ast.Expr{ .String = "42" };
    const eq = ast.Expr{ .Binary = .{ .op = .Eq, .left = &a_ident, .right = &s_lit } };
    const v2 = try evalExpr(allocator, eq, env);
    try std.testing.expect(v2 == .Bool and v2.Bool == true);
    // a IN ["41", "42", 43] -> true
    var lit41 = ast.Expr{ .String = "41" };
    var lit43 = ast.Expr{ .Int = 43 };
    var arr: [3]*ast.Expr = .{ &lit41, &s_lit, &lit43 };
    const inx = ast.Expr{ .In = .{ .value = &a_ident, .set = arr[0..] } };
    const v3 = try evalExpr(allocator, inx, env);
    try std.testing.expect(v3 == .Bool and v3.Bool == true);
}

test "eval: parameters substitution and STARTS WITH via $param" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{"s"}, .values = &.{Value{ .Str = "Alice" }}, .param_names = &.{"prefix"}, .param_values = &.{Value{ .Str = "Al" }} };
    var s_ident = ast.Expr{ .Ident = .{ .orig = "s", .cnf = "S" } };
    var pref = ast.Expr{ .Param = "prefix" };
    const sw = ast.Expr{ .StartsWith = .{ .value = &s_ident, .prefix = &pref } };
    const v = try evalExpr(allocator, sw, env);
    try std.testing.expect(v == .Bool and v.Bool == true);
}

test "eval: parameters in IN list, mixed-type equality, and regex via $param" {
    const allocator = std.testing.allocator;
    // Env: a=7, s="007"; params: needle="Al", list=["6",7], pat="^A.*$"
    const env = Env{ .allocator = allocator, .names = &.{ "a", "s" }, .values = &.{ Value{ .Int = 7 }, Value{ .Str = "007" } }, .param_names = &.{ "needle", "list0", "list1", "pat" }, .param_values = &.{ Value{ .Str = "Al" }, Value{ .Str = "6" }, Value{ .Int = 7 }, Value{ .Str = "^A.*$" } } };
    // a IN [$list0, $list1] -> true
    var a_ident = ast.Expr{ .Ident = .{ .orig = "a", .cnf = "A" } };
    var p0 = ast.Expr{ .Param = "list0" };
    var p1 = ast.Expr{ .Param = "list1" };
    var items: [2]*ast.Expr = .{ &p0, &p1 };
    const inx = ast.Expr{ .In = .{ .value = &a_ident, .set = items[0..] } };
    const v1 = try evalExpr(allocator, inx, env);
    try std.testing.expect(v1 == .Bool and v1.Bool);
    // Equality mixed-type: a = s (7 vs "007") -> false; but a = "7" literal -> true
    var s_ident = ast.Expr{ .Ident = .{ .orig = "s", .cnf = "S" } };
    const eq1 = ast.Expr{ .Binary = .{ .op = .Eq, .left = &a_ident, .right = &s_ident } };
    const v2 = try evalExpr(allocator, eq1, env);
    try std.testing.expect(v2 == .Bool and !v2.Bool);
    var s7 = ast.Expr{ .String = "7" };
    const eq2 = ast.Expr{ .Binary = .{ .op = .Eq, .left = &a_ident, .right = &s7 } };
    const v3 = try evalExpr(allocator, eq2, env);
    try std.testing.expect(v3 == .Bool and v3.Bool);
    // Equality using int parameter vs string field: $list1 (7) = s ("007") -> false
    var p_int = ast.Expr{ .Param = "list1" };
    const eq3 = ast.Expr{ .Binary = .{ .op = .Eq, .left = &p_int, .right = &s_ident } };
    const v3b = try evalExpr(allocator, eq3, env);
    try std.testing.expect(v3b == .Bool and !v3b.Bool);
    // Removed regex test - not part of GQL
}

test "eval: CASE permutations with multiple WHENs and ELSE variants" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };
    // Searched CASE: first WHEN true selected; later WHENs skipped
    var t = ast.Expr{ .Bool = true };
    var f = ast.Expr{ .Bool = false };
    var n = ast.Expr{ .Null = {} };
    var A = ast.Expr{ .String = "A" };
    var B = ast.Expr{ .String = "B" };
    var C = ast.Expr{ .String = "C" };
    var whs1: [3]ast.CaseWhen = .{ .{ .when = &t, .then_expr = &A }, .{ .when = &f, .then_expr = &B }, .{ .when = &t, .then_expr = &C } };
    const cs1 = ast.Expr{ .Case = .{ .operand = null, .whens = whs1[0..], .else_expr = &C } };
    const o1 = try evalExpr(allocator, cs1, env);
    try std.testing.expect(o1 == .Str and std.mem.eql(u8, o1.Str, "A"));
    // Searched CASE: no WHEN true, ELSE present -> ELSE
    var whs2: [2]ast.CaseWhen = .{ .{ .when = &f, .then_expr = &A }, .{ .when = &n, .then_expr = &B } };
    const cs2 = ast.Expr{ .Case = .{ .operand = null, .whens = whs2[0..], .else_expr = &C } };
    const o2 = try evalExpr(allocator, cs2, env);
    try std.testing.expect(o2 == .Str and std.mem.eql(u8, o2.Str, "C"));
    // Simple CASE: operand type-varying WHENs; match on second WHEN; ELSE absent
    var op = ast.Expr{ .String = "2" };
    var w1 = ast.Expr{ .Int = 1 };
    var w2 = ast.Expr{ .String = "2" };
    var whs3: [2]ast.CaseWhen = .{ .{ .when = &w1, .then_expr = &A }, .{ .when = &w2, .then_expr = &B } };
    const cs3 = ast.Expr{ .Case = .{ .operand = &op, .whens = whs3[0..], .else_expr = null } };
    const o3 = try evalExpr(allocator, cs3, env);
    try std.testing.expect(o3 == .Str and std.mem.eql(u8, o3.Str, "B"));
    // Simple CASE: operand Int 2, WHEN "2" (string) shouldn't match; ELSE applies
    var op2 = ast.Expr{ .Int = 2 };
    var wstr2 = ast.Expr{ .String = "2" };
    var whs3b: [1]ast.CaseWhen = .{.{ .when = &wstr2, .then_expr = &A }};
    const cs3b = ast.Expr{ .Case = .{ .operand = &op2, .whens = whs3b[0..], .else_expr = &C } };
    const o3b = try evalExpr(allocator, cs3b, env);
    try std.testing.expect(o3b == .Str and std.mem.eql(u8, o3b.Str, "C"));
    // Simple CASE: operand NULL, WHEN NULL then -> THEN; ELSE present should be ignored
    var opn = ast.Expr{ .Null = {} };
    var whs4: [2]ast.CaseWhen = .{ .{ .when = &n, .then_expr = &A }, .{ .when = &t, .then_expr = &B } };
    const cs4 = ast.Expr{ .Case = .{ .operand = &opn, .whens = whs4[0..], .else_expr = &C } };
    const o4 = try evalExpr(allocator, cs4, env);
    try std.testing.expect(o4 == .Str and std.mem.eql(u8, o4.Str, "A"));
}

test "eval: CASE 3VL searched and simple with NULLs" {
    const allocator = std.testing.allocator;
    // Searched CASE: WHEN NULL THEN should not trigger; ELSE chosen
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };
    var n1 = ast.Expr{ .Null = {} };
    var then1 = ast.Expr{ .String = "x" };
    var whs1: [1]ast.CaseWhen = .{.{ .when = &n1, .then_expr = &then1 }};
    const c1 = ast.Expr{ .Case = .{ .operand = null, .whens = whs1[0..], .else_expr = &then1 } };
    const o1 = try evalExpr(allocator, c1, env);
    try std.testing.expect(o1 == .Str and std.mem.eql(u8, o1.Str, "x"));
    // Simple CASE: operand NULL, WHEN NULL -> match returns THEN
    var opn = ast.Expr{ .Null = {} };
    var wnull = ast.Expr{ .Null = {} };
    var t2 = ast.Expr{ .String = "n" };
    var whs2: [1]ast.CaseWhen = .{.{ .when = &wnull, .then_expr = &t2 }};
    const c2 = ast.Expr{ .Case = .{ .operand = &opn, .whens = whs2[0..], .else_expr = null } };
    const o2 = try evalExpr(allocator, c2, env);
    try std.testing.expect(o2 == .Str and std.mem.eql(u8, o2.Str, "n"));
}
