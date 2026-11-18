// CANARY: REQ=REQ-EVAL-REFACTOR-001; FEATURE="EvalExpr Refactoring"; ASPECT=CallHandlers; STATUS=TESTED; OWNER=eval; UPDATED=2026-01-30
// Extract function call handlers from evalExpr to reduce function size
//
// This module contains helper functions for evaluating function calls in GQL expressions.
// The goal is to reduce evalExpr from ~2043 lines to under 500 lines by extracting
// logical blocks into well-named helper functions.
//
// Contents:
// - evalMathFunction() - handles math functions (abs, sqrt, ceil, floor, round, sin, cos, etc.)
// - evalStringFunction() - handles string functions (substring, trim, upper, lower, replace, etc.)
// - evalTypeCastFunction() - handles CAST and type conversion functions
// - evalCollectionFunction() - handles collection functions (keys, values, size, head, tail, etc.)
// - evalAggregateFunction() - handles aggregate functions (count, sum, avg, min, max)

const std = @import("std");
const builtin = @import("builtin");
const value_types = @import("../value_types.zig");
const ast = @import("../gql/ast.zig");
const evaluator_functions = @import("../types/evaluator_functions.zig");
const datetime = @import("../types/datetime.zig");
const bitstring = @import("../types/bitstring.zig");
const public_suffix = @import("../types/public_suffix.zig");
const type_promotion = @import("type_promotion.zig");
const decimal128 = @import("../types/decimal128.zig");
const narrowing = @import("../types/narrowing.zig");
const decimal_text = @import("../types/decimal_text.zig");
const array_functions = @import("array_functions.zig");

pub const Value = value_types.Value;
pub const EvalError = value_types.EvalError;
pub const Env = value_types.Env;

const evalValueToHeapValue = type_promotion.evalValueToHeapValue;
const heapValueToEvalValue = type_promotion.heapValueToEvalValue;

// Forward declaration for recursive evalExpr call
const eval = @import("../eval.zig");

// CANARY: REQ=REQ-SONNY-2739-CHECKED-NARROWING; FEATURE="NumericNarrowing"; ASPECT=MathAndCastFunctions; STATUS=TESTED; TEST=tests/test_sonny2739_float_narrowing.zig; OWNER=eval; UPDATED=2026-09-25
/// A float as a scale-6 Decimal coefficient, rounded to the nearest, or
/// DecimalOverflow (22003) for NaN, an infinity or a magnitude past the 38
/// digits. SONNY-2739: degrees(), radians() and toFloat() narrowed it with a
/// bare `@intFromFloat`, which aborts the server past i128 (`degrees(1e33)`,
/// `toFloat('1e400')`) and turns NaN into a garbage coefficient.
pub fn roundedScale6(f: f64) EvalError!i128 {
    return decimal128.checkedScaledCoeff(@round(f * 1_000_000), 1.0);
}

// CANARY: REQ=REQ-SONNY-6730-TYPE-FUNCTIONS; FEATURE="BuiltinFunctions"; ASPECT=RealDoubleOfDecimal; STATUS=TESTED; TEST=tests/test_sonny6730_type_function_constructors.zig; OWNER=eval; UPDATED=2026-11-17
/// A decimal as the nearest REAL (f32) or DOUBLE (f64): its exact text read
/// as the float type, so the rounding is the correct one, not a division of
/// two rounded numbers. SONNY-6731: a numeric literal with a fraction
/// (`3.14159`) is a decimal, which `Real(value)` / `Double(value)` did not
/// take (22G03). A value no float of the type holds is 22003.
fn decimalAsFloat(comptime T: type, allocator: std.mem.Allocator, coeff: i128, scale: u8) EvalError!T {
    const text = try decimal_text.alloc(allocator, coeff, scale);
    defer allocator.free(text);
    const f = std.fmt.parseFloat(T, text) catch return EvalError.InvalidCast;
    if (!std.math.isFinite(f)) return EvalError.IntegerOverflow;
    return f;
}

pub fn mapEvaluatorError(err: evaluator_functions.EvaluatorError) EvalError {
    return switch (err) {
        evaluator_functions.EvaluatorError.TypeMismatch => EvalError.TypeMismatch,
        evaluator_functions.EvaluatorError.DivisionByZero => EvalError.DivisionByZero,
        // SONNY-2769: a heap function's overflow is 22003, not 0A000.
        evaluator_functions.EvaluatorError.Overflow => EvalError.IntegerOverflow,
        // SONNY-6518 item 2: text that is not a literal of the target (20.8 GR
        // g ii, i ii): invalid character value for cast, 22018 (was 22G03).
        evaluator_functions.EvaluatorError.InvalidFormat => EvalError.InvalidCast,
        evaluator_functions.EvaluatorError.InvalidInput => EvalError.TypeMismatch,
        evaluator_functions.EvaluatorError.OutOfMemory => EvalError.OutOfMemory,
        evaluator_functions.EvaluatorError.CharLengthExceeded => EvalError.CharLengthExceeded,
        evaluator_functions.EvaluatorError.HexFormatError => EvalError.HexFormatError,
        evaluator_functions.EvaluatorError.JsonInvalid => EvalError.JsonInvalid,
        evaluator_functions.EvaluatorError.XmlNotWellFormed => EvalError.XmlNotWellFormed,
        evaluator_functions.EvaluatorError.UrlParseError => EvalError.UrlParseError,
        evaluator_functions.EvaluatorError.DomainSyntaxError => EvalError.DomainSyntaxError,
        evaluator_functions.EvaluatorError.UuidParseError => EvalError.UuidParseError,
        evaluator_functions.EvaluatorError.EnumTypeError => EvalError.EnumTypeError,
        evaluator_functions.EvaluatorError.EnumValueError => EvalError.EnumValueError,
        evaluator_functions.EvaluatorError.IndexOutOfBounds => EvalError.IndexOutOfBounds,
        evaluator_functions.EvaluatorError.BitParseError => EvalError.BitParseError,
        evaluator_functions.EvaluatorError.RangeBoundsError => EvalError.RangeBoundsError,
        evaluator_functions.EvaluatorError.FloatNaN => EvalError.FloatNaN,
        evaluator_functions.EvaluatorError.TimeParse => EvalError.TimeParse,
        evaluator_functions.EvaluatorError.DecimalOverflow => EvalError.DecimalOverflow,
        evaluator_functions.EvaluatorError.DecimalDivZero => EvalError.DecimalDivZero,
        evaluator_functions.EvaluatorError.IdnaError => EvalError.IdnaError,
        // ENG-3922(b): the over-cap vector keeps its identity through this
        // mapper too, rather than joining the InvalidFormat -> TypeMismatch arm.
        evaluator_functions.EvaluatorError.VectorTooLarge => EvalError.VectorTooLarge,
    };
}

/// SONNY-6587 item 4: an exact integer argument of range().
fn rangeInt(value: Value) ?i64 {
    return switch (value) {
        .Int => |i| i,
        .SmallInt => |i| i,
        .BigInt => |i| i,
        else => null,
    };
}

fn textLike(value: Value) ?[]const u8 {
    return switch (value) {
        .Str => |s| s,
        .Text => |s| s,
        .Char => |c| c.data,
        .Varchar => |v| v.data,
        .Json => |j| j,
        else => null,
    };
}

/// SONNY-6518 item 5: the byte offset of the `n`-th character (0-based) of
/// `s`, or `s.len` past its last. A byte that starts no UTF-8 sequence counts
/// as one character.
fn charOffset(s: []const u8, n: usize) usize {
    var at: usize = 0;
    var seen: usize = 0;
    while (at < s.len and seen < n) : (seen += 1) {
        const width = std.unicode.utf8ByteSequenceLength(s[at]) catch 1;
        at = @min(s.len, at + width);
    }
    return at;
}

/// SONNY-6555 item 4: the number of characters of `s` (4.16.3), counted
/// as `charOffset` steps: a byte that starts no UTF-8 sequence is one.
fn charCount(s: []const u8) usize {
    var at: usize = 0;
    var seen: usize = 0;
    while (at < s.len) : (seen += 1) {
        const width = std.unicode.utf8ByteSequenceLength(s[at]) catch 1;
        at = @min(s.len, at + width);
    }
    return seen;
}

/// SONNY-6555 item 4: whether an operand is the null value; the function's
/// result is then the null value (NULL in is NULL out), not the heap
/// function's 22G03 for a value of no type it takes.
fn anyNull(values: []const Value) bool {
    for (values) |v| {
        if (v == .Null) return true;
    }
    return false;
}

/// SONNY-6518: a text argument of a constructor: null for the null value
/// (the result is then null); a value that is no text is 22G03 (it was
/// NULL).
fn textArg(value: Value) EvalError!?[]const u8 {
    if (value == .Null) return null;
    return textLike(value) orelse EvalError.TypeMismatch;
}

fn intLike(value: Value) ?i64 {
    return switch (value) {
        .Int => |i| i,
        .SmallInt => |i| i,
        .BigInt => |i| i,
        else => null,
    };
}

fn stringifyValueForConstructor(allocator: std.mem.Allocator, value: Value) !?[]u8 {
    if (textLike(value)) |text| {
        return try allocator.dupe(u8, text);
    }

    return switch (value) {
        .Bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .Int => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .SmallInt => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .BigInt => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .Real => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .Double => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .Decimal => |d| try std.fmt.allocPrint(
            allocator,
            "{d}",
            .{@as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale)))},
        ),
        else => null,
    };
}

fn parseOffsetSeconds(value: Value) ?i32 {
    return switch (value) {
        .Int => |i| if (i >= std.math.minInt(i32) and i <= std.math.maxInt(i32)) @intCast(i) else null,
        .SmallInt => |i| i,
        .BigInt => |i| if (i >= std.math.minInt(i32) and i <= std.math.maxInt(i32)) @intCast(i) else null,
        else => blk: {
            const text = textLike(value) orelse break :blk null;
            if (std.mem.eql(u8, text, "Z")) break :blk 0;
            if (text.len != 6 or text[3] != ':') break :blk null;
            if (text[0] != '+' and text[0] != '-') break :blk null;

            const hours = std.fmt.parseInt(i32, text[1..3], 10) catch break :blk null;
            const mins = std.fmt.parseInt(i32, text[4..6], 10) catch break :blk null;
            const sign: i32 = if (text[0] == '-') -1 else 1;
            break :blk sign * (hours * 3600 + mins * 60);
        },
    };
}

fn normalizeBitLiteral(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, text, "B'") and std.mem.endsWith(u8, text, "'")) {
        return allocator.dupe(u8, text);
    }
    return std.fmt.allocPrint(allocator, "B'{s}'", .{text});
}

// ============================================================================
// Math Functions
// ============================================================================

// CANARY: REQ=REQ-EVAL-REFACTOR-002; FEATURE="EvalExpr Refactoring"; ASPECT=MathFunctions; STATUS=TESTED; OWNER=eval; UPDATED=2026-01-30
/// Evaluate math functions: abs, sqrt, ceil, floor, round, sin, cos, tan, etc.
/// Returns null if the function is not a math function.
pub fn evalMathFunction(
    allocator: std.mem.Allocator,
    function_name: []const u8,
    args: []*ast.Expr,
    env: Env,
) EvalError!?Value {
    // abs(x)
    if (std.mem.eql(u8, function_name, "abs")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            // SONNY-2769: abs(minInt) does not fit; the negation aborted
            // the server.
            .Int => |i| {
                const abs_val = if (i < 0) std.math.negate(i) catch return EvalError.IntegerOverflow else i;
                return Value{ .Int = abs_val };
            },
            .Decimal => |d| {
                if (d.coeff >= 0) {
                    return arg;
                }
                const coeff = std.math.negate(d.coeff) catch return EvalError.DecimalOverflow;
                return Value{ .Decimal = .{ .coeff = coeff, .scale = d.scale, .orig_scale = d.orig_scale, .orig_repr = d.orig_repr } };
            },
            .Double => |x| return Value{ .Double = @abs(x) },
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        }
    }

    // sqrt(x)
    if (std.mem.eql(u8, function_name, "sqrt")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Int => |i| {
                if (i < 0) return EvalError.InvalidPowerArgument;
                const f = @sqrt(@as(f64, @floatFromInt(i)));
                return Value{ .Decimal = .{ .coeff = @intFromFloat(f * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
            },
            .Decimal => |d| {
                if (d.coeff < 0) return EvalError.InvalidPowerArgument;
                const f = @sqrt(@as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))));
                return Value{ .Decimal = .{ .coeff = @intFromFloat(f * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
            },
            .Double => |x| {
                if (x < 0) return EvalError.InvalidPowerArgument;
                return Value{ .Decimal = .{ .coeff = try roundedScale6(@sqrt(x)), .scale = 6, .orig_scale = 6, .orig_repr = null } };
            },
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        }
    }

    // pow(base, exp)
    if (std.mem.eql(u8, function_name, "pow")) {
        if (args.len != 2) return EvalError.WrongArgumentCount;
        const base_arg = try eval.evalExpr(allocator, args[0].*, env);
        const exp_arg = try eval.evalExpr(allocator, args[1].*, env);

        const base = switch (base_arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            .Double => |x| x,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        const exponent = switch (exp_arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            .Double => |x| x,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        // SONNY-6518: ISO/IEC 39075:2024 20.22 GR 11 b), e): 0 to a negative
        // power, and a negative base to a power that is not a whole number,
        // are 2201F (they answered NULL).
        if (base == 0 and exponent < 0) return EvalError.InvalidPowerArgument;
        if (base < 0 and exponent != @trunc(exponent)) return EvalError.InvalidPowerArgument;
        const result = std.math.pow(f64, base, exponent);
        if (std.math.isNan(result) or std.math.isInf(result)) return EvalError.NumericOutOfRange;
        const scaled = result * 1000000;
        if (scaled < -1.7e38 or scaled > 1.7e38) return EvalError.NumericOutOfRange;
        return Value{ .Decimal = .{ .coeff = @intFromFloat(scaled), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // sin(x)
    if (std.mem.eql(u8, function_name, "sin")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            .Double => |x| x,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };
        const result = @sin(val);
        if (std.math.isNan(result)) return EvalError.NumericOutOfRange;
        return Value{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // cos(x)
    if (std.mem.eql(u8, function_name, "cos")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            .Double => |x| x,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };
        const result = @cos(val);
        if (std.math.isNan(result)) return EvalError.NumericOutOfRange;
        return Value{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // tan(x)
    if (std.mem.eql(u8, function_name, "tan")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            .Double => |x| x,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };
        const result = @tan(val);
        if (std.math.isNan(result) or std.math.isInf(result)) return EvalError.NumericOutOfRange;
        const scaled = result * 1000000;
        if (scaled < -1.7e38 or scaled > 1.7e38) return EvalError.NumericOutOfRange;
        return Value{ .Decimal = .{ .coeff = @intFromFloat(scaled), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // CANARY: REQ=REQ-MATH-TRIG-001; FEATURE="TrigonometricFunctions"; ASPECT=ATAN; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_math_algorithms.yml; OWNER=math; UPDATED=2025-10-26
    // atan(x)
    if (std.mem.eql(u8, function_name, "atan")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            .Double => |x| x,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };
        const result = std.math.atan(val);
        if (std.math.isNan(result)) return EvalError.NumericOutOfRange;
        return Value{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // CANARY: REQ=REQ-MATH-TRIG-002; FEATURE="TrigonometricFunctions"; ASPECT=ATAN2; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_math_algorithms.yml; OWNER=math; UPDATED=2025-10-26
    // atan2(y, x)
    if (std.mem.eql(u8, function_name, "atan2")) {
        if (args.len != 2) return EvalError.WrongArgumentCount;
        const arg_y = try eval.evalExpr(allocator, args[0].*, env);
        const arg_x = try eval.evalExpr(allocator, args[1].*, env);

        const val_y = switch (arg_y) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            .Double => |x| x,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        const val_x = switch (arg_x) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            .Double => |x| x,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        const result = std.math.atan2(val_y, val_x);
        if (std.math.isNan(result)) return EvalError.NumericOutOfRange;
        return Value{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // CANARY: REQ=REQ-MATH-TRIG-003; FEATURE="TrigonometricFunctions"; ASPECT=ASIN; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_math_algorithms.yml; OWNER=math; UPDATED=2025-10-26
    // asin(x)
    if (std.mem.eql(u8, function_name, "asin")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            .Double => |x| x,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };
        if (val < -1.0 or val > 1.0) return EvalError.NumericOutOfRange;
        const result = std.math.asin(val);
        if (std.math.isNan(result)) return EvalError.NumericOutOfRange;
        return Value{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // CANARY: REQ=REQ-MATH-TRIG-004; FEATURE="TrigonometricFunctions"; ASPECT=ACOS; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_math_algorithms.yml; OWNER=math; UPDATED=2025-10-26
    // acos(x)
    if (std.mem.eql(u8, function_name, "acos")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            .Double => |x| x,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };
        if (val < -1.0 or val > 1.0) return EvalError.NumericOutOfRange;
        const result = std.math.acos(val);
        if (std.math.isNan(result)) return EvalError.NumericOutOfRange;
        return Value{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // CANARY: REQ=REQ-FN-DISPATCH-PARITY; FEATURE="MathConstants"; ASPECT=PiAndE; STATUS=TESTED; TEST=tests/test_fn_dispatch_parity.zig; OWNER=math; UPDATED=2026-08-25
    // FN-DISPATCH-PARITY: pi() and e() are advertised by
    // src/gql/language_metadata.zig (and `degrees(pi())` is the documented
    // example of degrees() right below), but neither was dispatched anywhere —
    // both were error.UnknownFunction. They are exact, unambiguous constants,
    // so they are implemented rather than un-advertised. The Decimal scale-6
    // shape is the same one every other fractional result in this module uses
    // (an f64 Double would not compose with degrees()/radians(), which accept
    // Int and Decimal only).
    if (std.mem.eql(u8, function_name, "pi")) {
        if (args.len != 0) return EvalError.WrongArgumentCount;
        return Value{ .Decimal = .{ .coeff = @intFromFloat(@round(std.math.pi * 1000000)), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    if (std.mem.eql(u8, function_name, "e")) {
        if (args.len != 0) return EvalError.WrongArgumentCount;
        return Value{ .Decimal = .{ .coeff = @intFromFloat(@round(std.math.e * 1000000)), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // CANARY: REQ=REQ-MATH-CONVERT-001; FEATURE="AngleConversion"; ASPECT=DEGREES; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_math_algorithms.yml; OWNER=math; UPDATED=2025-12-27
    // degrees(radians)
    if (std.mem.eql(u8, function_name, "degrees")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            .Double => |x| x,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };
        const result = val * (180.0 / std.math.pi);
        if (std.math.isNan(result) or std.math.isInf(result)) return EvalError.NumericOutOfRange;
        return Value{ .Decimal = .{ .coeff = try roundedScale6(result), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // CANARY: REQ=REQ-MATH-CONVERT-002; FEATURE="AngleConversion"; ASPECT=RADIANS; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_math_algorithms.yml; OWNER=math; UPDATED=2025-12-27
    // radians(degrees)
    if (std.mem.eql(u8, function_name, "radians")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            .Double => |x| x,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };
        const result = val * (std.math.pi / 180.0);
        if (std.math.isNan(result) or std.math.isInf(result)) return EvalError.NumericOutOfRange;
        return Value{ .Decimal = .{ .coeff = try roundedScale6(result), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // log(x)
    if (std.mem.eql(u8, function_name, "log")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            .Double => |x| x,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };
        if (val <= 0) return EvalError.InvalidLogArgument;
        const result = @log(val);
        if (std.math.isNan(result) or std.math.isInf(result)) return EvalError.NumericOutOfRange;
        return Value{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // exp(x)
    if (std.mem.eql(u8, function_name, "exp")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            .Double => |x| x,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };
        const result = @exp(val);
        if (std.math.isNan(result) or std.math.isInf(result)) return EvalError.NumericOutOfRange;
        const scaled = result * 1000000;
        if (scaled < -1.7e38 or scaled > 1.7e38) return EvalError.NumericOutOfRange;
        return Value{ .Decimal = .{ .coeff = @intFromFloat(scaled), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // ceil(x)
    if (std.mem.eql(u8, function_name, "ceil")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Int => |i| return Value{ .Int = i },
            // SONNY-2739: exact, and IntegerOverflow (22003) past i64; the
            // `@intCast` aborted the server (`ceil(9223372036854775807.5)`), and
            // `std.math.pow(i128, 10, scale)` did past scale 38.
            .Decimal => |d| return Value{ .Int = try narrowing.decimalToInt(d.coeff, d.scale, .ceil) },
            // 20.22 GR 13 b) ii): an approximate number's is a whole approximate number.
            .Double => |x| return Value{ .Double = @ceil(x) },
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        }
    }

    // floor(x)
    if (std.mem.eql(u8, function_name, "floor")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Int => |i| return Value{ .Int = i },
            // SONNY-2739: see ceil.
            .Decimal => |d| return Value{ .Int = try narrowing.decimalToInt(d.coeff, d.scale, .floor) },
            // 20.22 GR 12 b) ii).
            .Double => |x| return Value{ .Double = @floor(x) },
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        }
    }

    // CANARY: REQ=REQ-MATH-ARITH-001; FEATURE="ArithmeticFunctions"; ASPECT=ROUND; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=math; UPDATED=2025-12-22
    // round(x [, precision])
    if (std.mem.eql(u8, function_name, "round")) {
        if (args.len < 1 or args.len > 2) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);

        var precision: i64 = 0;
        if (args.len == 2) {
            const prec_arg = try eval.evalExpr(allocator, args[1].*, env);
            precision = switch (prec_arg) {
                .Int => |i| i,
                .Null => return Value{ .Null = {} },
                else => return EvalError.TypeMismatch,
            };
        }

        // SONNY-2739: every step is exact and checked. `std.math.pow(i64 or
        // i128, 10, n)` aborted the server past 10^18 or 10^38 (`round(5, -19)`,
        // a scale-60 decimal), `@intCast` past i64 (`round(1e30)`) or u8
        // (`round(1.5, -300)`). A result past i64 is IntegerOverflow (22003).
        // The rounding itself is unchanged: an Int rounds half up
        // (`(i + 10^k / 2) / 10^k`, truncated), a Decimal half away from zero.
        switch (arg) {
            .Int => |i| {
                if (precision >= 0) return Value{ .Int = i };
                // |i| < 10^19, so past 10^38 the quotient is 0.
                const k = @abs(precision);
                const factor = if (k <= 38) narrowing.pow10(@intCast(k)).? else return Value{ .Int = 0 };
                const rounded = @divTrunc(@as(i128, i) + @divTrunc(factor, 2), factor) * factor;
                return Value{ .Int = std.math.cast(i64, rounded) orelse return EvalError.IntegerOverflow };
            },
            .Decimal => |d| {
                if (precision == 0) {
                    return Value{ .Int = try narrowing.decimalToInt(d.coeff, d.scale, .half_away_from_zero) };
                } else if (precision > 0) {
                    const target_scale: u8 = @intCast(@min(precision, 38));
                    if (target_scale >= d.scale) {
                        return Value{ .Decimal = d };
                    }
                    const new_coeff = narrowing.decimalRound(d.coeff, d.scale - target_scale, .half_away_from_zero);
                    return Value{ .Decimal = .{ .coeff = new_coeff, .scale = target_scale } };
                } else {
                    // Round to a multiple of 10^k: past 10^38 in all, the
                    // quotient is 0 (every |coeff| < 10^39).
                    const k = @abs(precision);
                    const total = @min(@as(u64, d.scale) + k, 64);
                    const quotient = narrowing.decimalRound(d.coeff, @intCast(total), .half_away_from_zero);
                    if (quotient == 0) return Value{ .Int = 0 };
                    const result = std.math.mul(i128, quotient, narrowing.pow10(@intCast(k)).?) catch return EvalError.IntegerOverflow;
                    return Value{ .Int = std.math.cast(i64, result) orelse return EvalError.IntegerOverflow };
                }
            },
            // SONNY-6596: an approximate number rounds to an approximate
            // number (as floor and ceil, 20.22 GR 12/13 b ii), half away from
            // zero at 10^-precision.
            .Double => |x| {
                if (precision == 0) return Value{ .Double = @round(x) };
                const p = std.math.cast(i32, precision) orelse return Value{ .Double = if (precision > 0) x else 0 };
                const factor = std.math.pow(f64, 10.0, @floatFromInt(p));
                if (!std.math.isFinite(factor) or factor == 0) return Value{ .Double = if (precision > 0) x else 0 };
                const rounded = @round(x * factor) / factor;
                return Value{ .Double = if (std.math.isFinite(rounded)) rounded else x };
            },
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        }
    }

    // CANARY: REQ=REQ-MATH-ARITH-001; FEATURE="ArithmeticFunctions"; ASPECT=MOD; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=math; UPDATED=2025-10-26
    // mod(dividend, divisor)
    if (std.mem.eql(u8, function_name, "mod")) {
        if (args.len != 2) return EvalError.WrongArgumentCount;
        const dividend_arg = try eval.evalExpr(allocator, args[0].*, env);
        const divisor_arg = try eval.evalExpr(allocator, args[1].*, env);

        const dividend = switch (dividend_arg) {
            .Int => |i| i,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        const divisor = switch (divisor_arg) {
            .Int => |i| i,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        if (divisor == 0) return EvalError.DivisionByZero;
        // SONNY-2769: x mod -1 is 0; @rem(minInt, -1) was a hardware division
        // trap (SIGFPE) that killed the server.
        if (divisor == -1) return Value{ .Int = 0 };
        const result = @rem(dividend, divisor);
        return Value{ .Int = result };
    }

    // CANARY: REQ=REQ-MATH-ARITH-002; FEATURE="ArithmeticFunctions"; ASPECT=SIGN; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=math; UPDATED=2025-10-26
    // sign(x)
    if (std.mem.eql(u8, function_name, "sign")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);

        const sign_value = switch (arg) {
            .Int => |i| if (i < 0) @as(i64, -1) else if (i > 0) @as(i64, 1) else @as(i64, 0),
            .Decimal => |d| if (d.coeff < 0) @as(i64, -1) else if (d.coeff > 0) @as(i64, 1) else @as(i64, 0),
            .Double => |x| if (x < 0) @as(i64, -1) else if (x > 0) @as(i64, 1) else @as(i64, 0),
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        return Value{ .Int = sign_value };
    }

    // random() — returns decimal in [0, 1) using cryptographically secure source
    if (std.mem.eql(u8, function_name, "random")) {
        if (args.len != 0) return EvalError.WrongArgumentCount;
        var rand_bytes: [8]u8 = undefined;
        // fips-exempt: non-security GQL random() function (query evaluation, not cryptographic)
        // Zig 0.16: std.posix.getrandom removed; branch on OS.
        if (comptime builtin.os.tag == .linux) {
            const rc = std.os.linux.getrandom(&rand_bytes, rand_bytes.len, 0);
            if (@as(isize, @bitCast(rc)) < 0) return Value{ .Null = {} };
        } else {
            // macOS / BSD: arc4random_buf returns void and cannot fail.
            std.c.arc4random_buf(&rand_bytes, rand_bytes.len);
        }
        const rand_u64 = std.mem.readInt(u64, &rand_bytes, .little);
        const value = @as(f64, @floatFromInt(rand_u64 >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
        return Value{ .Decimal = .{ .coeff = @intFromFloat(value * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // Not a math function
    return null;
}

// ============================================================================
// String Functions
// ============================================================================

// CANARY: REQ=REQ-EVAL-REFACTOR-003; FEATURE="EvalExpr Refactoring"; ASPECT=StringFunctions; STATUS=TESTED; OWNER=eval; UPDATED=2026-01-30
/// Evaluate string functions: substring, trim, upper, lower, replace, etc.
/// Returns null if the function is not a string function.
pub fn evalStringFunction(
    allocator: std.mem.Allocator,
    function_name: []const u8,
    args: []*ast.Expr,
    env: Env,
) EvalError!?Value {
    // CANARY: REQ=REQ-SONNY-6518-SUBSTRING-POSITIONS; FEATURE="StringFunctions"; ASPECT=CharacterPositions; STATUS=TESTED; TEST=tests/test_sonny6518_substring_positions.zig; OWNER=eval; UPDATED=2026-11-13
    // substring(str, start [, length]): a Geode extension (ISO/IEC 39075:2024
    // has LEFT and RIGHT only, 20.24), 1-based as documented. SONNY-6518 item
    // 5: the characters at positions start .. start + length - 1 that the
    // string has, as SQL's <character substring function> (ISO/IEC 9075-2)
    // defines them: a start of 0 or less counts its positions before the
    // first character (substring('abc', 0, 1) is '': it was 'a'), a
    // negative length is a substring error (22011: it was ''), and positions
    // are characters, not bytes.
    if (std.mem.eql(u8, function_name, "substring")) {
        if (args.len < 2 or args.len > 3) return EvalError.WrongArgumentCount;
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);
        const start_arg = try eval.evalExpr(allocator, args[1].*, env);
        const len_arg: ?Value = if (args.len == 3) try eval.evalExpr(allocator, args[2].*, env) else null;

        const str = switch (str_arg) {
            .Str, .Text => |s| s,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };
        const start: i64 = switch (start_arg) {
            .Int => |i| i,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };
        // The position after the last one taken (exclusive), if a length is given.
        const end: ?i64 = if (len_arg) |la| switch (la) {
            .Int => |l| if (l < 0) return EvalError.IndexOutOfBounds else start +| l,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        } else null;
        const first: i64 = @max(start, 1);
        if (end) |e| {
            if (e <= first) return Value{ .Str = "" };
        }
        const from = charOffset(str, @intCast(first - 1));
        const to = if (end) |e| charOffset(str, @intCast(e - 1)) else str.len;
        return Value{ .Str = str[from..@max(from, to)] };
    }

    // replace(str, search, replacement)
    if (std.mem.eql(u8, function_name, "replace")) {
        if (args.len != 3) return EvalError.WrongArgumentCount;
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);
        const search_arg = try eval.evalExpr(allocator, args[1].*, env);
        const replace_arg = try eval.evalExpr(allocator, args[2].*, env);

        const str = switch (str_arg) {
            .Str, .Text => |s| s,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        const search = switch (search_arg) {
            .Str, .Text => |s| s,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        const replacement = switch (replace_arg) {
            .Str, .Text => |s| s,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        if (search.len == 0) {
            return Value{ .Str = str };
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
            return Value{ .Str = str };
        }

        // Allocate new string
        const new_len = str.len + (replacement.len * count) - (search.len * count);
        var result = try allocator.alloc(u8, new_len);

        // Perform replacement
        var src_pos: usize = 0;
        var dst_pos: usize = 0;
        while (src_pos < str.len) {
            if (std.mem.indexOf(u8, str[src_pos..], search)) |idx| {
                @memcpy(result[dst_pos .. dst_pos + idx], str[src_pos .. src_pos + idx]);
                dst_pos += idx;
                @memcpy(result[dst_pos .. dst_pos + replacement.len], replacement);
                dst_pos += replacement.len;
                src_pos = src_pos + idx + search.len;
            } else {
                const remaining = str.len - src_pos;
                @memcpy(result[dst_pos .. dst_pos + remaining], str[src_pos..]);
                break;
            }
        }

        return Value{ .Str = result };
    }

    // trim(str)
    if (std.mem.eql(u8, function_name, "trim")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);

        const str = switch (str_arg) {
            .Str, .Text => |s| s,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        const trimmed = std.mem.trim(u8, str, " \t\n\r");
        return Value{ .Str = trimmed };
    }

    // CANARY: REQ=REQ-GQL-STRING-FUNCTIONS-001; FEATURE="StringFunctions"; ASPECT=LTrim; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-27
    // ltrim(str)
    if (std.mem.eql(u8, function_name, "ltrim")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);

        const str = switch (str_arg) {
            .Str, .Text => |s| s,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        const trimmed = std.mem.trimStart(u8, str, " \t\n\r");
        return Value{ .Str = trimmed };
    }

    // CANARY: REQ=REQ-GQL-STRING-FUNCTIONS-002; FEATURE="StringFunctions"; ASPECT=RTrim; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-27
    // rtrim(str)
    if (std.mem.eql(u8, function_name, "rtrim")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);

        const str = switch (str_arg) {
            .Str, .Text => |s| s,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        const trimmed = std.mem.trimEnd(u8, str, " \t\n\r");
        return Value{ .Str = trimmed };
    }

    // CANARY: REQ=REQ-GQL-STRING-FUNCTIONS-003; FEATURE="StringFunctions"; ASPECT=Left; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-27
    // left(str, count)
    if (std.mem.eql(u8, function_name, "left")) {
        if (args.len != 2) return EvalError.WrongArgumentCount;
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);
        const len_arg = try eval.evalExpr(allocator, args[1].*, env);

        const str = switch (str_arg) {
            .Str, .Text => |s| s,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        const count = switch (len_arg) {
            // SONNY-6518: ISO/IEC 39075:2024 20.24 GR 1 d): a negative length
            // is a substring error (22011); it answered ''.
            .Int => |i| if (i < 0) return EvalError.IndexOutOfBounds else @as(usize, @intCast(i)),
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        // SONNY-6518 item 5: the first NC characters (20.24 GR 1 e, f ii); it
        // took bytes.
        return Value{ .Str = str[0..charOffset(str, count)] };
    }

    // CANARY: REQ=REQ-GQL-STRING-FUNCTIONS-004; FEATURE="StringFunctions"; ASPECT=Right; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-27
    // right(str, count)
    if (std.mem.eql(u8, function_name, "right")) {
        if (args.len != 2) return EvalError.WrongArgumentCount;
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);
        const len_arg = try eval.evalExpr(allocator, args[1].*, env);

        const str = switch (str_arg) {
            .Str, .Text => |s| s,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        const count = switch (len_arg) {
            // SONNY-6518: ISO/IEC 39075:2024 20.24 GR 1 d): a negative length
            // is a substring error (22011); it answered ''.
            .Int => |i| if (i < 0) return EvalError.IndexOutOfBounds else @as(usize, @intCast(i)),
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        // SONNY-6518 item 5: the last NC characters (20.24 GR 1 e, f iii); it
        // took bytes.
        const chars = std.unicode.utf8CountCodepoints(str) catch str.len;
        return Value{ .Str = str[charOffset(str, chars - @min(count, chars))..] };
    }

    // CANARY: REQ=REQ-FN-DISPATCH-PARITY; FEATURE="StringFunctions"; ASPECT=Split; STATUS=TESTED; TEST=tests/test_fn_dispatch_parity.zig; OWNER=eval; UPDATED=2026-08-25
    // split(str, delimiter) -> LIST of STRING
    //
    // FN-DISPATCH-PARITY: `split` was advertised by BOTH SHOW FUNCTIONS
    // (src/execution/statement_handlers.zig) and the language metadata
    // (src/gql/language_metadata.zig) but never dispatched — every call raised
    // UnknownFunction. Implemented here rather than un-advertised because the
    // List plumbing is the same one keys()/values()/range() already use.
    //
    // Element slices alias `str`, exactly as left()/right()/substring() do; the
    // caller's allocator owns only the Value array.
    if (std.mem.eql(u8, function_name, "split")) {
        if (args.len != 2) return EvalError.WrongArgumentCount;
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);
        const delim_arg = try eval.evalExpr(allocator, args[1].*, env);

        const str = switch (str_arg) {
            .Str, .Text => |s| s,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };
        const delim = switch (delim_arg) {
            .Str, .Text => |s| s,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        // An empty delimiter has no well-defined split point; return the whole
        // string as a single element rather than looping forever or exploding
        // into one element per byte (which would break UTF-8 anyway).
        if (delim.len == 0) {
            const single = try allocator.alloc(Value, 1);
            single[0] = Value{ .Str = str };
            return Value{ .List = single };
        }

        var count: usize = 1;
        var counter = std.mem.splitSequence(u8, str, delim);
        _ = counter.first();
        while (counter.next() != null) count += 1;

        const parts = try allocator.alloc(Value, count);
        var it = std.mem.splitSequence(u8, str, delim);
        var i: usize = 0;
        while (it.next()) |part| : (i += 1) {
            parts[i] = Value{ .Str = part };
        }
        return Value{ .List = parts };
    }

    // upper(str) / toupper(str)
    if (std.mem.eql(u8, function_name, "upper") or std.mem.eql(u8, function_name, "toupper")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);

        const str = switch (str_arg) {
            .Str, .Text => |s| s,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        var result = try allocator.alloc(u8, str.len);
        for (str, 0..) |c, i| {
            result[i] = std.ascii.toUpper(c);
        }
        return Value{ .Str = result };
    }

    // lower(str) / tolower(str)
    if (std.mem.eql(u8, function_name, "lower") or std.mem.eql(u8, function_name, "tolower")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);

        const str = switch (str_arg) {
            .Str, .Text => |s| s,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        var result = try allocator.alloc(u8, str.len);
        for (str, 0..) |c, i| {
            result[i] = std.ascii.toLower(c);
        }
        return Value{ .Str = result };
    }

    // icontains(str, substr) - case-insensitive CONTAINS
    if (std.mem.eql(u8, function_name, "icontains")) {
        if (args.len != 2) return EvalError.WrongArgumentCount;
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);
        const needle_arg = try eval.evalExpr(allocator, args[1].*, env);

        const str_val = switch (str_arg) {
            .Str, .Text => |s| s,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };
        const needle_val = switch (needle_arg) {
            .Str, .Text => |s| s,
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        };

        if (needle_val.len == 0) return Value{ .Bool = true };

        // Convert both to lowercase for comparison
        var lower_str = try allocator.alloc(u8, str_val.len);
        for (str_val, 0..) |c, i| {
            lower_str[i] = std.ascii.toLower(c);
        }
        var lower_needle = try allocator.alloc(u8, needle_val.len);
        for (needle_val, 0..) |c, i| {
            lower_needle[i] = std.ascii.toLower(c);
        }

        return Value{ .Bool = std.mem.indexOf(u8, lower_str, lower_needle) != null };
    }

    // Not a string function
    return null;
}

// ============================================================================
// Type Cast Functions
// ============================================================================

/// CAST(`source` AS `target_type`) (ISO/IEC 39075:2024 20.8): the
/// conversion `cast` and, SONNY-6518 item 2, the conversion functions
/// (toFloat, toInteger, toBoolean, toString) run.
pub fn castValue(allocator: std.mem.Allocator, source: Value, target_type: []const u8) EvalError!Value {
    const value_arg = castSource(source);
    if (value_arg == .Null) return Value{ .Null = {} };

    // Parse precision and scale from type string if present
    var base_type = target_type;
    var precision: ?u8 = null;
    var scale: ?u8 = null;
    if (std.mem.indexOf(u8, target_type, "(")) |paren_idx| {
        base_type = target_type[0..paren_idx];
        const rest = target_type[paren_idx + 1 ..];
        if (std.mem.indexOf(u8, rest, ")")) |end_paren| {
            const params = rest[0..end_paren];
            if (std.mem.indexOf(u8, params, ",")) |comma_idx| {
                precision = std.fmt.parseInt(u8, params[0..comma_idx], 10) catch null;
                scale = std.fmt.parseInt(u8, params[comma_idx + 1 ..], 10) catch null;
            } else {
                precision = std.fmt.parseInt(u8, params, 10) catch null;
            }
        }
    }

    // SONNY-6499: a source type with no conversion to the target (ISO
    // 20.8 Table 4 "N"; GR 7 d ii for a dynamically typed value) is
    // TypeMismatch, 22G03 invalid value type; text that is not a literal
    // of the target is InvalidCast, 22018 (GR g ii, i ii), or for a
    // datetime target TimeParse, 22007 (GR k i, l i).

    // Normalize base type to uppercase
    var upper_buf: [32]u8 = undefined;
    const type_len = @min(base_type.len, upper_buf.len);
    for (base_type[0..type_len], 0..) |c, i| {
        upper_buf[i] = std.ascii.toUpper(c);
    }
    const upper_type = upper_buf[0..type_len];

    // DECIMAL/NUMERIC conversion
    if (std.mem.eql(u8, upper_type, "DECIMAL") or std.mem.eql(u8, upper_type, "NUMERIC")) {
        const target_scale: u8 = scale orelse 0;
        switch (value_arg) {
            // SONNY-2769: every rescale is checked; `coeff *= 10` and the
            // fraction's `mult *= 10` aborted the server past i128
            // (`CAST(9223372036854775807 AS DECIMAL(38, 30))`, a string
            // with 40 fraction digits), and `@intCast` past 255 of them.
            .Int => |i| return Value{ .Decimal = .{ .coeff = try rescaleDecimal(i, 0, target_scale), .scale = target_scale } },
            .Decimal => |d| return Value{ .Decimal = .{ .coeff = try rescaleDecimal(d.coeff, d.scale, target_scale), .scale = target_scale } },
            .Str => |s| {
                // SONNY-6499: trimmed, exponent read (ISO 20.8 GR g ii).
                const parsed = try parseExactNumericText(castTrim(s));
                return Value{ .Decimal = .{ .coeff = try rescaleDecimal(parsed.coeff, parsed.scale, target_scale), .scale = target_scale } };
            },
            .Double => |x| return Value{ .Decimal = .{ .coeff = try doubleToDecimal(x, target_scale), .scale = target_scale } },
            // GAP-0921: an unconvertible source value is a cast error.
            else => return EvalError.TypeMismatch,
        }
    }

    // INTEGER/INT/BIGINT conversion
    if (std.mem.eql(u8, upper_type, "INTEGER") or std.mem.eql(u8, upper_type, "INT") or std.mem.eql(u8, upper_type, "BIGINT")) {
        switch (value_arg) {
            .Int => |i| return Value{ .Int = i },
            .Decimal => |d| {
                var coeff = d.coeff;
                var sc = d.scale;
                while (sc > 0) : (sc -= 1) {
                    coeff = @divTrunc(coeff, 10);
                }
                // GAP-0905: the i128 -> i64 narrowing was an unchecked @intCast
                // and panicked for values beyond i64 (e.g. CAST(9.9e30 AS INTEGER)).
                const as_i64 = std.math.cast(i64, coeff) orelse return EvalError.IntegerOverflow;
                return Value{ .Int = as_i64 };
            },
            .Str => |s| {
                // SONNY-6499: trimmed, exponent read, truncated (ISO
                // 20.8 GR g ii; IA005).
                const parsed = try parseExactNumericText(castTrim(s));
                return Value{ .Int = try narrowing.decimalToInt(parsed.coeff, parsed.scale, .trunc) };
            },
            // SONNY-6499: truncated (IA005); 22003 out of range (GR g i).
            .Double => |x| {
                if (!std.math.isFinite(x)) return EvalError.IntegerOverflow;
                const t = @trunc(x);
                if (t < -9223372036854775808.0 or t >= 9223372036854775808.0) return EvalError.IntegerOverflow;
                return Value{ .Int = @intFromFloat(t) };
            },
            // Geode extension (Table 4: BOOLEAN to a number is not valid).
            .Bool => |b| return Value{ .Int = if (b) 1 else 0 },
            // GAP-0921: an unconvertible source value is a cast error.
            else => return EvalError.TypeMismatch,
        }
    }

    // STRING/VARCHAR/TEXT conversion
    if (std.mem.eql(u8, upper_type, "STRING") or std.mem.eql(u8, upper_type, "VARCHAR") or std.mem.eql(u8, upper_type, "TEXT")) {
        switch (value_arg) {
            .Int => |i| {
                const str = try std.fmt.allocPrint(allocator, "{d}", .{i});
                return Value{ .Str = str };
            },
            .Decimal => |d| {
                // SONNY-2769: the text of a decimal at any scale. The
                // hand-rolled `divisor *= 10` overflowed past scale 38 and
                // aborted the server; past 32 digits the text came out
                // NULL, and a value between -1 and 0 lost its sign
                // (-0.5 was '0.5').
                return Value{ .Str = try decimal_text.alloc(allocator, d.coeff, d.scale) };
            },
            // SONNY-6499: ISO 20.8 GR j v: 'TRUE' / 'FALSE'.
            .Bool => |b| return Value{ .Str = if (b) "TRUE" else "FALSE" },
            .Str => |s| return Value{ .Str = s },
            // SONNY-6499: GR j ii; it was NULL.
            .Double => |x| return Value{ .Str = try approximateText(allocator, x) },
            // SONNY-6489: a datetime or duration casts to the character
            // form of its literal (20.8; ISO 8601), the form it renders
            // in, which reads back as the same value. It was NULL.
            .Date, .Time, .TimeTZ, .Timestamp, .TimestampTZ, .Interval => {
                var buf: [64]u8 = undefined;
                const text = try value_types.stringify(value_arg, &buf);
                return Value{ .Str = try allocator.dupe(u8, text) };
            },
            // SONNY-6499: a list, record, reference or extension value
            // has no character form here (ISO 20.8 Table 4); refused, it
            // was NULL.
            else => return EvalError.TypeMismatch,
        }
    }

    // FLOAT/DOUBLE/REAL conversion
    if (std.mem.eql(u8, upper_type, "FLOAT") or std.mem.eql(u8, upper_type, "DOUBLE") or std.mem.eql(u8, upper_type, "REAL")) {
        switch (value_arg) {
            // SONNY-6499: an approximate target gives a DOUBLE (ISO 20.8
            // GR i); it gave a DECIMAL at scale 6.
            .Int => |i| return Value{ .Double = @floatFromInt(i) },
            .Decimal => |d| {
                // Correctly rounded: the exact text, read as a double.
                const text = try decimal_text.alloc(allocator, d.coeff, d.scale);
                defer allocator.free(text);
                return Value{ .Double = std.fmt.parseFloat(f64, text) catch return EvalError.InvalidCast };
            },
            .Double => |x| return Value{ .Double = x },
            .Str => |s| {
                // GR i ii: the trimmed text of a <signed numeric
                // literal>, else 22018 ('nan', 'inf', '1_000' were read).
                const t = castTrim(s);
                if (!isNumericLiteralText(t)) return EvalError.InvalidCast;
                const f = std.fmt.parseFloat(f64, t) catch return EvalError.InvalidCast;
                // GR i i 2: no double holds it.
                if (!std.math.isFinite(f)) return EvalError.NumericOutOfRange;
                return Value{ .Double = f };
            },
            else => return EvalError.TypeMismatch,
        }
    }

    // BOOLEAN/BOOL conversion
    if (std.mem.eql(u8, upper_type, "BOOLEAN") or std.mem.eql(u8, upper_type, "BOOL")) {
        switch (value_arg) {
            .Bool => |b| return Value{ .Bool = b },
            .Int => |i| return Value{ .Bool = i != 0 },
            .Str => |raw| {
                // SONNY-6499: trimmed (21.2 <boolean literal>).
                const s = castTrim(raw);
                if (std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1")) {
                    return Value{ .Bool = true };
                } else if (std.ascii.eqlIgnoreCase(s, "false") or std.mem.eql(u8, s, "0")) {
                    return Value{ .Bool = false };
                } else {
                    // GAP-0921: an unrecognized boolean string is a cast error.
                    return EvalError.InvalidCast;
                }
            },
            else => return EvalError.TypeMismatch,
        }
    }

    // DATE conversion
    if (std.mem.eql(u8, upper_type, "DATE")) {
        switch (value_arg) {
            .Str => |s| {
                const datetime_module = @import("../types/datetime.zig");
                // GAP-0921: a non-date string is a cast error, not NULL.
                const date = datetime_module.Date.fromStr(castTrim(s)) catch return EvalError.TimeParse;
                return Value{ .Date = date };
            },
            .Date => return value_arg,
            .Timestamp => |ts| {
                const datetime_module = @import("../types/datetime.zig");
                const days: i32 = @intCast(@divFloor(ts.micros_since_epoch, 24 * 3600 * 1_000_000));
                return Value{ .Date = datetime_module.Date{ .days_since_epoch = days } };
            },
            else => return EvalError.TypeMismatch,
        }
    }

    // TIME conversion
    if (std.mem.eql(u8, upper_type, "TIME")) {
        switch (value_arg) {
            .Str => |s| {
                const datetime_module = @import("../types/datetime.zig");
                // GAP-0921: a non-time string is a cast error, not NULL.
                const time = datetime_module.Time.fromStr(castTrim(s)) catch return EvalError.TimeParse;
                return Value{ .Time = time };
            },
            .Time => return value_arg,
            .Timestamp => |ts| {
                const datetime_module = @import("../types/datetime.zig");
                const micros = @rem(ts.micros_since_epoch, 24 * 3600 * @as(i64, 1_000_000));
                return Value{ .Time = datetime_module.Time{ .micros_since_midnight = if (micros < 0) micros + 24 * 3600 * 1_000_000 else micros } };
            },
            else => return EvalError.TypeMismatch,
        }
    }

    // DATETIME/TIMESTAMP conversion
    if (std.mem.eql(u8, upper_type, "DATETIME") or std.mem.eql(u8, upper_type, "TIMESTAMP")) {
        switch (value_arg) {
            .Str => |s| {
                const datetime_module = @import("../types/datetime.zig");
                // GAP-0921: a non-timestamp string is a cast error.
                const ts = datetime_module.Timestamp.fromStr(castTrim(s)) catch return EvalError.TimeParse;
                return Value{ .Timestamp = ts };
            },
            .Timestamp => return value_arg,
            .Date => |d| {
                return Value{ .Timestamp = .{ .micros_since_epoch = @as(i64, d.days_since_epoch) * 24 * 3600 * 1_000_000 } };
            },
            else => return EvalError.TypeMismatch,
        }
    }

    // GAP-0921: an unknown/unsupported target type is not a silent NULL —
    // it is a "feature not supported" error (SQLSTATE 0A000). (A missing
    // type name entirely is already a parse-time 42000.)
    return EvalError.UnsupportedCastTarget;
}

// CANARY: REQ=REQ-GAP-0921-CAST-SEMANTIC-VALIDATION; FEATURE="TypeCasting"; ASPECT=SemanticValidation; STATUS=TESTED; TEST=tests/test_gap0921_cast_validation.zig; OWNER=eval; UPDATED=2026-07-10
/// GAP-0921: map a numeric parse failure inside CAST to a typed error —
/// out-of-range → IntegerOverflow (SQLSTATE 22003), any other invalid
/// character → InvalidCast (22018). Both replace the former silent NULL.
fn castParseError(e: anyerror) EvalError {
    return switch (e) {
        error.Overflow => EvalError.IntegerOverflow,
        else => EvalError.InvalidCast,
    };
}

/// `coeff` * 10^-`from` at scale `to`: scaled up exactly (DecimalOverflow
/// past i128) or truncated down (SONNY-2769).
fn rescaleDecimal(coeff: i128, from: u8, to: u8) EvalError!i128 {
    if (to >= from) {
        if (coeff == 0) return 0;
        const factor = narrowing.pow10(to - from) orelse return EvalError.DecimalOverflow;
        return std.math.mul(i128, coeff, factor) catch EvalError.DecimalOverflow;
    }
    return narrowing.decimalRound(coeff, from - to, .trunc);
}

/// A decimal string ("-12.345", "7") as coefficient and scale, exactly, with
/// fraction digits past `max_scale` truncated, as the rescale to it would
/// (SONNY-2769). GAP-0921: an invalid character is a cast error; a value past
/// 38 digits is DecimalOverflow. The sign now applies to the fraction too:
/// "-1.5" was -0.5 and "-0.5" was 0.5.
fn parseDecimalText(s: []const u8, max_scale: u8) EvalError!struct { coeff: i128, scale: u8 } {
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse
        return .{ .coeff = std.fmt.parseInt(i128, s, 10) catch |e| return castParseError(e), .scale = 0 };
    const int_part = s[0..dot];
    const frac_all = s[dot + 1 ..];
    const int_val = std.fmt.parseInt(i128, int_part, 10) catch |e| return castParseError(e);
    if (frac_all.len == 0) return EvalError.InvalidCast;
    for (frac_all) |c| {
        if (!std.ascii.isDigit(c)) return EvalError.InvalidCast;
    }
    const frac_part = frac_all[0..@min(frac_all.len, max_scale)];
    const scale: u8 = @intCast(frac_part.len);
    const frac_val = if (frac_part.len == 0) 0 else std.fmt.parseInt(i128, frac_part, 10) catch return EvalError.DecimalOverflow;
    const whole = if (int_val == 0) 0 else std.math.mul(i128, int_val, narrowing.pow10(scale) orelse return EvalError.DecimalOverflow) catch
        return EvalError.DecimalOverflow;
    const negative = int_part.len > 0 and int_part[0] == '-';
    const coeff = (if (negative) std.math.sub(i128, whole, frac_val) else std.math.add(i128, whole, frac_val)) catch
        return EvalError.DecimalOverflow;
    return .{ .coeff = coeff, .scale = scale };
}

/// SONNY-6499: the value CAST converts. A value stored on a node is read
/// back as an extended value (a DOUBLE, a datetime); the integer and
/// approximate kinds convert as INTEGER and DOUBLE do; a TEXT, CHAR or
/// VARCHAR as a STRING.
fn castSource(v: Value) Value {
    return switch (v) {
        .SmallInt => |i| .{ .Int = i },
        .BigInt => |i| .{ .Int = i },
        .Real => |r| .{ .Double = r },
        .Text => |t| .{ .Str = t },
        .Char => |c| .{ .Str = c.data },
        .Varchar => |c| .{ .Str = c.data },
        .ExtValue => |e| switch (e) {
            .Int, .BigInt => |i| .{ .Int = i },
            .SmallInt => |i| .{ .Int = i },
            .Bool => |b| .{ .Bool = b },
            .Str, .Text => |t| .{ .Str = t },
            .Char => |c| .{ .Str = c.data },
            .Varchar => |c| .{ .Str = c.data },
            .Decimal => |dec| .{ .Decimal = .{ .coeff = dec.coeff, .scale = dec.scale } },
            .Double => |x| .{ .Double = x },
            .Real => |x| .{ .Double = x },
            .Date => |x| .{ .Date = x },
            .Time => |x| .{ .Time = x },
            .TimeTZ => |x| .{ .TimeTZ = x },
            .Timestamp => |x| .{ .Timestamp = x },
            .TimestampTZ => |x| .{ .TimestampTZ = x },
            .Interval => |x| .{ .Interval = x },
            .Null => .{ .Null = {} },
            else => v,
        },
        else => v,
    };
}

/// SONNY-6499: whether `t` is a <signed numeric literal> (ISO/IEC 39075
/// 21.2) in decimal notation: an optional sign, digits with an optional
/// period, an optional exponent. ISO 20.8 GR g ii, h ii and i ii make any
/// other text 22018; `std.fmt.parse*` also accepted 'nan', 'inf', '1_000'
/// and hexadecimal.
fn isNumericLiteralText(t: []const u8) bool {
    var i: usize = 0;
    if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
    var digits: usize = 0;
    while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) digits += 1;
    if (i < t.len and t[i] == '.') {
        i += 1;
        while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) digits += 1;
    }
    if (digits == 0) return false;
    if (i < t.len and (t[i] == 'e' or t[i] == 'E')) {
        i += 1;
        if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
        const start = i;
        while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
        if (i == start) return false;
    }
    return i == t.len;
}

/// SONNY-6499: ISO 20.8 GR g ii, i ii, k i: the source text with leading
/// and trailing <truncating whitespace> removed.
fn castTrim(t: []const u8) []const u8 {
    return std.mem.trim(u8, t, " \t\r\n");
}

/// SONNY-6499: the exact value of a <signed numeric literal>, exponent
/// included. Fraction digits past what the coefficient holds (or past
/// scale 38) are truncated, as the rescale to any DECIMAL would; an integer
/// part past it is 22003.
fn parseExactNumericText(text: []const u8) EvalError!struct { coeff: i128, scale: u8 } {
    if (!isNumericLiteralText(text)) return EvalError.InvalidCast;
    var i: usize = 0;
    var negative = false;
    if (text[0] == '+' or text[0] == '-') {
        negative = text[0] == '-';
        i = 1;
    }
    var coeff: i128 = 0;
    var scale: i64 = 0;
    var in_fraction = false;
    var full = false;
    while (i < text.len and text[i] != 'e' and text[i] != 'E') : (i += 1) {
        if (text[i] == '.') {
            in_fraction = true;
            continue;
        }
        if (in_fraction and (full or scale == 38)) continue;
        const next = std.math.mul(i128, coeff, 10) catch null;
        const with_digit = if (next) |n| std.math.add(i128, n, text[i] - '0') catch null else null;
        if (with_digit) |v| {
            coeff = v;
            if (in_fraction) scale += 1;
        } else if (in_fraction) {
            full = true;
        } else return EvalError.IntegerOverflow;
    }
    const exp: i64 = if (i < text.len) std.fmt.parseInt(i64, text[i + 1 ..], 10) catch return EvalError.IntegerOverflow else 0;
    if (negative) coeff = -coeff;
    scale = std.math.sub(i64, scale, exp) catch return EvalError.IntegerOverflow;
    if (scale < 0) {
        if (coeff == 0) return .{ .coeff = 0, .scale = 0 };
        const factor = narrowing.pow10(std.math.cast(u8, -scale) orelse return EvalError.IntegerOverflow) orelse return EvalError.IntegerOverflow;
        return .{ .coeff = std.math.mul(i128, coeff, factor) catch return EvalError.IntegerOverflow, .scale = 0 };
    }
    if (scale > 38) {
        const drop = scale - 38;
        const kept = if (drop > 38) 0 else narrowing.decimalRound(coeff, @intCast(drop), .trunc);
        return .{ .coeff = kept, .scale = 38 };
    }
    return .{ .coeff = coeff, .scale = @intCast(scale) };
}

/// SONNY-6499: ISO 20.8 GR j ii: the character form of an approximate
/// number, the shortest <approximate numeric literal> whose mantissa is one
/// non-zero digit, a period and an unsigned integer ('1.5E0', '1.0E-1'),
/// '0E0' for zero. It reads back as the same DOUBLE. NaN and the
/// infinities have no literal: 22003.
fn approximateText(allocator: std.mem.Allocator, x: f64) EvalError![]const u8 {
    if (!std.math.isFinite(x)) return EvalError.NumericOutOfRange;
    if (x == 0) return "0E0";
    var buf: [64]u8 = undefined;
    const sci = std.fmt.bufPrint(&buf, "{e}", .{x}) catch return EvalError.Unsupported;
    const e_at = std.mem.indexOfScalar(u8, sci, 'e') orelse return EvalError.Unsupported;
    const mant = sci[0..e_at];
    const exp = sci[e_at + 1 ..];
    const point: []const u8 = if (std.mem.indexOfScalar(u8, mant, '.') == null) ".0" else "";
    return std.fmt.allocPrint(allocator, "{s}{s}E{s}", .{ mant, point, exp }) catch EvalError.OutOfMemory;
}

/// SONNY-6499: ISO 20.8 GR g i: a DOUBLE as an exact number at `scale`,
/// truncated (IA005); 22003 past the target. Through its shortest decimal
/// form, which reads back as the same DOUBLE.
fn doubleToDecimal(x: f64, scale: u8) EvalError!i128 {
    if (!std.math.isFinite(x)) return EvalError.IntegerOverflow;
    var buf: [400]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{x}) catch return EvalError.IntegerOverflow;
    const parsed = try parseDecimalText(text, 38);
    return rescaleDecimal(parsed.coeff, parsed.scale, scale);
}

// CANARY: REQ=REQ-EVAL-REFACTOR-004; FEATURE="EvalExpr Refactoring"; ASPECT=TypeCastFunctions; STATUS=TESTED; OWNER=eval; UPDATED=2026-01-30
// CANARY: REQ=REQ-GQL-CAST-001; FEATURE="TypeCasting"; ASPECT=Evaluation; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2026-01-25
/// Evaluate type cast functions: cast, toString, toInteger, toFloat, toBoolean
/// Returns null if the function is not a type cast function.
pub fn evalTypeCastFunction(
    allocator: std.mem.Allocator,
    function_name: []const u8,
    args: []*ast.Expr,
    env: Env,
) EvalError!?Value {
    // cast(value, type_name)
    if (std.mem.eql(u8, function_name, "cast")) {
        if (args.len != 2) return EvalError.WrongArgumentCount;

        const value_arg = try eval.evalExpr(allocator, args[0].*, env);
        const type_arg = try eval.evalExpr(allocator, args[1].*, env);

        const target_type = switch (type_arg) {
            .Str => |s| s,
            else => return Value{ .Null = {} },
        };
        return try castValue(allocator, value_arg, target_type);
    }

    // CANARY: REQ=REQ-GQL-086; FEATURE="TypeConversionFunctions"; ASPECT=Evaluation; STATUS=TESTED; OWNER=eval; UPDATED=2025-10-14
    // CANARY: REQ=REQ-GQL-TOBOOLEAN-001; FEATURE="TypeConversionFunctions"; ASPECT=ToBooleanConversion; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system_comprehensive.yml; OWNER=eval; UPDATED=2025-12-24
    // CANARY: REQ=REQ-ENG-3916-TOSTRING-NULL-PROPAGATION; FEATURE="StringFunctions"; ASPECT=ToStringNullPropagation; STATUS=TESTED; TEST=tests/test_eng3916_edge_id_projection.zig; OWNER=eval; UPDATED=2026-08-25
    // CANARY: REQ=REQ-SONNY-6518-CONVERSION-FUNCTIONS; FEATURE="TypeConversionFunctions"; ASPECT=SameAsCast; STATUS=TESTED; TEST=tests/test_sonny6518_conversion_functions.zig; OWNER=eval; UPDATED=2026-11-13
    // SONNY-6518 item 2: toFloat / toDouble, toInteger / toInt, toBoolean /
    // toBool and toString are CAST(x AS FLOAT / INTEGER / BOOLEAN / STRING)
    // (ISO/IEC 39075:2024 20.8): the same result and the same exception.
    // None is documented as a lenient "try" conversion. Before: toFloat
    // answered a DECIMAL at scale 6; toInteger floored a fraction (CAST
    // truncates, IA005), read TRUE as 1 and answered NULL for text that is
    // no integer and for any other type; toBoolean read a non-zero integer
    // as TRUE and answered NULL for other text and types; toString answered
    // 'true' / 'false' (CAST: 'TRUE' / 'FALSE', GR j v) and '' for every
    // other type; ENG-3916: a NULL argument is NULL (as CAST).
    const conversions = [_]struct { names: []const []const u8, target: []const u8 }{
        .{ .names = &.{ "tofloat", "todouble" }, .target = "FLOAT" },
        .{ .names = &.{ "tointeger", "toint" }, .target = "INTEGER" },
        .{ .names = &.{ "toboolean", "tobool" }, .target = "BOOLEAN" },
        .{ .names = &.{"tostring"}, .target = "STRING" },
    };
    for (conversions) |conv| {
        for (conv.names) |name| {
            if (!std.mem.eql(u8, function_name, name)) continue;
            if (args.len != 1) return EvalError.WrongArgumentCount;
            const arg = try eval.evalExpr(allocator, args[0].*, env);
            return try castValue(allocator, arg, conv.target);
        }
    }

    // Not a type cast function
    return null;
}

// ============================================================================
// Collection Functions
// ============================================================================

// CANARY: REQ=REQ-EVAL-REFACTOR-005; FEATURE="EvalExpr Refactoring"; ASPECT=CollectionFunctions; STATUS=TESTED; OWNER=eval; UPDATED=2026-01-30
/// Evaluate collection functions: keys, values, size, head, tail, last, range, reverse
/// Returns null if the function is not a collection function.
pub fn evalCollectionFunction(
    allocator: std.mem.Allocator,
    function_name: []const u8,
    args: []*ast.Expr,
    env: Env,
) EvalError!?Value {
    // CANARY: REQ=REQ-GQL-KEYS-002; FEATURE="KeysFunction"; ASPECT=NodeEdgeMapKeys; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system_comprehensive.yml; OWNER=eval; UPDATED=2025-12-28
    // keys(map/node/edge)
    if (std.mem.eql(u8, function_name, "keys")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
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
            .Node => |node| {
                var keys = try allocator.alloc(Value, node.properties.count());
                var iter = node.properties.iterator();
                var i: usize = 0;
                while (iter.next()) |entry| : (i += 1) {
                    keys[i] = Value{ .Str = entry.key_ptr.* };
                }
                return Value{ .List = keys };
            },
            .Edge => |edge| {
                var keys = try allocator.alloc(Value, edge.properties.count());
                var iter = edge.properties.iterator();
                var i: usize = 0;
                while (iter.next()) |entry| : (i += 1) {
                    keys[i] = Value{ .Str = entry.key_ptr.* };
                }
                return Value{ .List = keys };
            },
            else => return Value{ .Null = {} },
        }
    }

    // values(map)
    if (std.mem.eql(u8, function_name, "values")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
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

    // CANARY: REQ=REQ-GQL-SIZE-001; FEATURE="SizeFunction"; ASPECT=ListPropertySize; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-27
    // size/length(list/string/map)
    if (std.mem.eql(u8, function_name, "size") or std.mem.eql(u8, function_name, "length")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        // CANARY: REQ=REQ-SONNY-6555-NULL-ARGUMENTS; FEATURE="SizeFunction"; ASPECT=NullAndCharacterLength; STATUS=TESTED; TEST=tests/test_sonny6555_null_arguments.zig; OWNER=eval; UPDATED=2026-11-14
        // SONNY-6555 item 4: ISO/IEC 39075:2024 20.22 GR 1 b), 3 b), 4 e):
        // the length or cardinality of the null value is the null value (it
        // was 0); GR 1 a) and NOTE 331: a character string's length is its
        // number of characters (it was its bytes). A value of no sized type
        // is 22G03 (it was 0).
        if (arg == .Null) return Value{ .Null = {} };
        if (textLike(arg)) |s| return Value{ .Int = @intCast(charCount(s)) };
        switch (arg) {
            .List => |l| return Value{ .Int = @intCast(l.len) },
            .Map => |m| return Value{ .Int = @intCast(m.count()) },
            .Path => |p| return Value{ .Int = @intCast(p.edges.len) },
            // CANARY: REQ=REQ-FN-SIZE-OF-VECTOR; FEATURE="SizeFunction"; ASPECT=VectorDimension; STATUS=TESTED; TEST=tests/test_fn_dispatch_parity.zig; OWNER=eval; UPDATED=2026-08-25
            // FN-DISPATCH-PARITY: a VECTOR is a sized collection, so size()/length() must
            // report its dimension. The old `else => Int 0` arm answered 0 for
            // every stored embedding — a silent lie that read as "empty".
            // `data.len` (not the u16 `dim` field) is authoritative so an
            // overflow-stored vector reports its real element count.
            // BYTE_LENGTH (GR 2 a): a byte string's length is its bytes.
            .Bytea => |b| return Value{ .Int = @intCast(b.len) },
            .ExtValue => |ext| switch (ext) {
                .Null => return Value{ .Null = {} },
                .List => |l| return Value{ .Int = @intCast(l.len) },
                .Str, .Text => |t| return Value{ .Int = @intCast(charCount(t)) },
                .Char => |t| return Value{ .Int = @intCast(charCount(t.data)) },
                .Varchar => |t| return Value{ .Int = @intCast(charCount(t.data)) },
                .Bytea => |b| return Value{ .Int = @intCast(b.len) },
                .VectorF32 => |v| return Value{ .Int = @intCast(v.data.len) },
                .VectorI32 => |v| return Value{ .Int = @intCast(v.data.len) },
                else => return EvalError.TypeMismatch,
            },
            else => return EvalError.TypeMismatch,
        }
    }

    // CANARY: REQ=REQ-GQL-HEAD-001; FEATURE="ListFunctions"; ASPECT=HeadElement; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2026-01-09
    // head(list)
    if (std.mem.eql(u8, function_name, "head")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .List => |l| {
                if (l.len == 0) return Value{ .Null = {} };
                return l[0];
            },
            // SONNY-6587 item 3: NULL in is NULL out, and a value that is no
            // list is 22G03, as tail's (SONNY-6555 item 4); it was NULL.
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        }
    }

    // CANARY: REQ=REQ-GQL-TAIL-001; FEATURE="ListFunctions"; ASPECT=TailElements; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2026-01-09
    // tail(list)
    if (std.mem.eql(u8, function_name, "tail")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .List => |l| {
                if (l.len <= 1) {
                    return Value{ .List = &[_]Value{} };
                }
                const tail_slice = try allocator.alloc(Value, l.len - 1);
                @memcpy(tail_slice, l[1..]);
                return Value{ .List = tail_slice };
            },
            // SONNY-6555 item 4: NULL in is NULL out, and a value that is no
            // list is 22G03 (both were the empty list).
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        }
    }

    // CANARY: REQ=REQ-GQL-LAST-001; FEATURE="ListFunctions"; ASPECT=LastElement; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-24
    // last(list)
    if (std.mem.eql(u8, function_name, "last")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .List => |l| {
                if (l.len == 0) return Value{ .Null = {} };
                return l[l.len - 1];
            },
            // SONNY-6587 item 3: NULL in is NULL out, and a value that is no
            // list is 22G03, as tail's (SONNY-6555 item 4); it was NULL.
            .Null => return Value{ .Null = {} },
            else => return EvalError.TypeMismatch,
        }
    }

    // reverse(list/string)
    if (std.mem.eql(u8, function_name, "reverse")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
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

    // CANARY: REQ=REQ-CLIENT-INTEGRATION-001; FEATURE="range() function"; ASPECT=BuiltinFunctions; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2025-11-15
    // range(start, stop [, step])
    if (std.mem.eql(u8, function_name, "range")) {
        // Let the GA advanced-type constructor Range(base_type, lower, upper, bounds)
        // fall through to evalAdvancedTypeFunction.
        if (args.len < 2 or args.len > 3) return null;

        // CANARY: REQ=REQ-SONNY-6587-LIST-FUNCTION-ARGS; FEATURE="ListFunctions"; ASPECT=RangeArguments; STATUS=TESTED; TEST=tests/test_sonny6587_list_functions.zig; OWNER=eval; UPDATED=2026-11-15
        // SONNY-6587 item 4: NULL in is NULL out; a value that is not an
        // integer is 22G03 and a zero step 22023 (both answered NULL). The
        // end stays exclusive, as documented (SONNY-6466).
        const start_val = try eval.evalExpr(allocator, args[0].*, env);
        const stop_val = try eval.evalExpr(allocator, args[1].*, env);
        const step_val: Value = if (args.len == 3) try eval.evalExpr(allocator, args[2].*, env) else .{ .Int = 1 };
        if (start_val == .Null or stop_val == .Null or step_val == .Null) return Value{ .Null = {} };
        const start = rangeInt(start_val) orelse return EvalError.TypeMismatch;
        const stop = rangeInt(stop_val) orelse return EvalError.TypeMismatch;
        const step = rangeInt(step_val) orelse return EvalError.TypeMismatch;

        if (step == 0) return EvalError.InvalidArgs;

        // SONNY-2769: in i128, so a span or a step at the edge of i64
        // (`range(minInt, maxInt)`, a step of minInt) no longer overflows
        // and aborts the server; every element still fits i64.
        const count: i128 = if (step > 0) blk: {
            if (stop <= start) break :blk 0;
            break :blk @divFloor(@as(i128, stop) - start + step - 1, step);
        } else blk: {
            if (stop >= start) break :blk 0;
            break :blk @divFloor(@as(i128, start) - stop - step - 1, -@as(i128, step));
        };

        if (count <= 0) {
            return Value{ .List = &.{} };
        }

        const max_range_size: i64 = 10_000_000;
        if (count > max_range_size) {
            return error.RangeTooLarge;
        }

        const ucount = @as(usize, @intCast(count));
        var result = try allocator.alloc(Value, ucount);

        // i128: the step past the last element may leave i64.
        var current: i128 = start;
        for (0..ucount) |i| {
            result[i] = Value{ .Int = @intCast(current) };
            current += step;
        }

        return Value{ .List = result };
    }

    // Not a collection function
    return null;
}

// ============================================================================
// Aggregate Functions
// ============================================================================

// CANARY: REQ=REQ-EVAL-REFACTOR-006; FEATURE="EvalExpr Refactoring"; ASPECT=AggregateFunctions; STATUS=TESTED; OWNER=eval; UPDATED=2026-01-30
/// Evaluate aggregate functions: count, sum, avg, min, max
/// These are simplified implementations for single-row context.
/// Returns null if the function is not an aggregate function.
pub fn evalAggregateFunction(
    allocator: std.mem.Allocator,
    function_name: []const u8,
    args: []*ast.Expr,
    env: Env,
) EvalError!?Value {
    // count(expr)
    if (std.mem.eql(u8, function_name, "count")) {
        if (args.len == 1) {
            // Check if argument is "*"
            if (args[0].* == .Ident and std.mem.eql(u8, args[0].Ident.orig, "*")) {
                return Value{ .Int = 1 };
            }
            const arg = try eval.evalExpr(allocator, args[0].*, env);
            if (arg != .Null) {
                return Value{ .Int = 1 };
            }
            return Value{ .Int = 0 };
        }
        return Value{ .Int = 0 };
    }

    // sum(list)
    if (std.mem.eql(u8, function_name, "sum")) {
        if (args.len == 0) return EvalError.WrongArgumentCount;

        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .List => |list| {
                if (list.len == 0) return Value{ .Null = {} };

                var has_decimal = false;
                for (list) |item| {
                    if (item == .Decimal) {
                        has_decimal = true;
                        break;
                    }
                }

                // SONNY-2739: a decimal is narrowed (to its floor, as
                // before) exactly and checked, and the sum is checked: the
                // `@intCast`, `std.math.pow` and `+=` aborted the server
                // (`sum([9223372036854775808.0])`, `sum([9223372036854775807,
                // 1])`). A sum past i64 is IntegerOverflow (22003).
                if (has_decimal) {
                    var sum: i64 = 0;
                    for (list) |item| {
                        const addend = switch (item) {
                            .Int => |v| v,
                            .Decimal => |d| try narrowing.decimalToInt(d.coeff, d.scale, .floor),
                            else => continue,
                        };
                        sum = std.math.add(i64, sum, addend) catch return EvalError.IntegerOverflow;
                    }
                    return Value{ .Int = sum };
                } else {
                    var sum: i64 = 0;
                    for (list) |item| {
                        switch (item) {
                            .Int => |n| sum = std.math.add(i64, sum, n) catch return EvalError.IntegerOverflow,
                            else => {},
                        }
                    }
                    return Value{ .Int = sum };
                }
            },
            else => return Value{ .Null = {} },
        }
    }

    // avg(list)
    if (std.mem.eql(u8, function_name, "avg")) {
        if (args.len == 0) return EvalError.WrongArgumentCount;

        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .List => |list| {
                if (list.len == 0) return Value{ .Null = {} };

                var sum: i64 = 0;
                var count: usize = 0;
                // SONNY-2739: see sum(list).
                for (list) |item| {
                    const addend = switch (item) {
                        .Int => |v| v,
                        .Decimal => |d| try narrowing.decimalToInt(d.coeff, d.scale, .floor),
                        else => continue,
                    };
                    sum = std.math.add(i64, sum, addend) catch return EvalError.IntegerOverflow;
                    count += 1;
                }

                if (count == 0) return Value{ .Null = {} };
                return Value{ .Int = @divFloor(sum, @as(i64, @intCast(count))) };
            },
            else => return Value{ .Null = {} },
        }
    }

    // min(list)
    if (std.mem.eql(u8, function_name, "min")) {
        if (args.len == 0) return EvalError.WrongArgumentCount;

        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .List => |list| {
                if (list.len == 0) return Value{ .Null = {} };

                var min_val = list[0];
                for (list[1..]) |item| {
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
    }

    // max(list)
    if (std.mem.eql(u8, function_name, "max")) {
        if (args.len == 0) return EvalError.WrongArgumentCount;

        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .List => |list| {
                if (list.len == 0) return Value{ .Null = {} };

                var max_val = list[0];
                for (list[1..]) |item| {
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

    // Not an aggregate function
    return null;
}

// ============================================================================
// Advanced Type Functions
// ============================================================================

/// Evaluate documented advanced constructors and built-ins that are not handled
/// by the simpler string/math/collection dispatchers.
pub fn evalAdvancedTypeFunction(
    allocator: std.mem.Allocator,
    function_name: []const u8,
    args: []*ast.Expr,
    env: Env,
) EvalError!?Value {
    if (std.mem.eql(u8, function_name, "smallint")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        // SONNY-6645 item 4: a NULL operand is NULL (ISO/IEC 39075:2024
        // 20.22 GR 1 b); it was 22G03.
        if (arg == .Null) return Value{ .Null = {} };
        const result = evaluator_functions.SmallInt(evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "bigint")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        // SONNY-6645 item 4: a NULL operand is NULL (ISO/IEC 39075:2024
        // 20.22 GR 1 b); it was 22G03.
        if (arg == .Null) return Value{ .Null = {} };
        const result = evaluator_functions.BigInt(evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "real")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        // SONNY-6645 item 4: a NULL operand is NULL (ISO/IEC 39075:2024
        // 20.22 GR 1 b); it was 22G03.
        if (arg == .Null) return Value{ .Null = {} };
        if (arg == .Decimal) return Value{ .Real = try decimalAsFloat(f32, allocator, arg.Decimal.coeff, arg.Decimal.scale) };
        const result = evaluator_functions.Real(evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "double")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        // SONNY-6645 item 4: a NULL operand is NULL (ISO/IEC 39075:2024
        // 20.22 GR 1 b); it was 22G03.
        if (arg == .Null) return Value{ .Null = {} };
        if (arg == .Decimal) return Value{ .Double = try decimalAsFloat(f64, allocator, arg.Decimal.coeff, arg.Decimal.scale) };
        const result = evaluator_functions.Double(evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "int")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        return switch (arg) {
            .Int => arg,
            .SmallInt => |i| Value{ .Int = i },
            .BigInt => |i| Value{ .Int = i },
            .Bool => |b| Value{ .Int = if (b) 1 else 0 },
            else => blk: {
                const text = (try textArg(arg)) orelse break :blk Value{ .Null = {} };
                const parsed = std.fmt.parseInt(i64, text, 10) catch break :blk Value{ .Null = {} };
                break :blk Value{ .Int = parsed };
            },
        };
    }

    if (std.mem.eql(u8, function_name, "bool")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        return switch (arg) {
            .Bool => arg,
            .Int => |i| Value{ .Bool = i != 0 },
            .SmallInt => |i| Value{ .Bool = i != 0 },
            .BigInt => |i| Value{ .Bool = i != 0 },
            else => blk: {
                const text = (try textArg(arg)) orelse break :blk Value{ .Null = {} };
                if (std.ascii.eqlIgnoreCase(text, "true") or std.mem.eql(u8, text, "1")) break :blk Value{ .Bool = true };
                if (std.ascii.eqlIgnoreCase(text, "false") or std.mem.eql(u8, text, "0")) break :blk Value{ .Bool = false };
                break :blk Value{ .Null = {} };
            },
        };
    }

    if (std.mem.eql(u8, function_name, "decimal")) {
        if (args.len < 1 or args.len > 2) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const value_text = (try stringifyValueForConstructor(allocator, arg)) orelse return Value{ .Null = {} };
        defer allocator.free(value_text);

        const scale = if (args.len == 2) blk: {
            const scale_arg = try eval.evalExpr(allocator, args[1].*, env);
            const scale_value = intLike(scale_arg) orelse return Value{ .Null = {} };
            // SONNY-2769: the cast aborted the server past i16.
            break :blk std.math.cast(i16, scale_value) orelse return EvalError.DecimalOverflow;
        } else null;

        const result = evaluator_functions.Decimal(allocator, value_text, scale) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "char")) {
        if (args.len != 2) return EvalError.WrongArgumentCount;
        const value_arg = try eval.evalExpr(allocator, args[0].*, env);
        const len_arg = try eval.evalExpr(allocator, args[1].*, env);
        const text = (try textArg(value_arg)) orelse return Value{ .Null = {} };
        const n = intLike(len_arg) orelse return Value{ .Null = {} };
        // SONNY-2769: a length outside 0..65535 aborted the server in the cast.
        const len = std.math.cast(u16, n) orelse return EvalError.InvalidArgs;
        const result = evaluator_functions.Char(allocator, text, len) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "varchar")) {
        if (args.len != 2) return EvalError.WrongArgumentCount;
        const value_arg = try eval.evalExpr(allocator, args[0].*, env);
        const len_arg = try eval.evalExpr(allocator, args[1].*, env);
        const text = (try textArg(value_arg)) orelse return Value{ .Null = {} };
        const n = intLike(len_arg) orelse return Value{ .Null = {} };
        // SONNY-2769: see char().
        const len = std.math.cast(u16, n) orelse return EvalError.InvalidArgs;
        const result = evaluator_functions.Varchar(allocator, text, len) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "text")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = (try textArg(arg)) orelse return Value{ .Null = {} };
        return Value{ .Text = try allocator.dupe(u8, text) };
    }

    if (std.mem.eql(u8, function_name, "date")) {
        if (args.len != 1) return null;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = (try textArg(arg)) orelse return Value{ .Null = {} };
        const result = evaluator_functions.Date(text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "time")) {
        if (args.len != 1) return null;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = (try textArg(arg)) orelse return Value{ .Null = {} };
        // SONNY-2808: a time string with a zone ('10:00:00+01:00',
        // '10:00:00Z') is a zoned time and keeps its displacement (ISO/IEC
        // 39075 ZONED_TIME); the offset was dropped. One without is a local
        // time. Anything else is TimeParse.
        if (datetime.Time.fromStr(text)) |t| return Value{ .Time = t } else |_| {}
        return Value{ .TimeTZ = datetime.TimeTZ.fromStr(text) catch return EvalError.TimeParse };
    }

    if (std.mem.eql(u8, function_name, "timetz")) {
        if (args.len != 1 and args.len != 2) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = (try textArg(arg)) orelse return Value{ .Null = {} };

        if (args.len == 1) {
            return Value{ .TimeTZ = datetime.TimeTZ.fromStr(text) catch return EvalError.TimeParse };
        }

        const offset_arg = try eval.evalExpr(allocator, args[1].*, env);
        const offset_seconds = parseOffsetSeconds(offset_arg) orelse return Value{ .Null = {} };
        const time = datetime.Time.fromStr(text) catch return EvalError.TimeParse;
        return Value{ .TimeTZ = .{ .time = time, .offset_seconds = offset_seconds } };
    }

    if (std.mem.eql(u8, function_name, "timestamp")) {
        if (args.len != 1) return null;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = (try textArg(arg)) orelse return Value{ .Null = {} };
        const result = evaluator_functions.Timestamp(text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "timestamptz")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = (try textArg(arg)) orelse return Value{ .Null = {} };
        const result = evaluator_functions.TimestampTZ(text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "interval")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = (try textArg(arg)) orelse return Value{ .Null = {} };
        // SONNY-6489: invalid duration format (22G0H), 20.29 GR 1c.
        return Value{
            .Interval = datetime.Interval.fromStr(text) catch |e| return switch (e) {
                // SONNY-6499: a component past its range is 22015.
                error.IntervalFieldOverflow => EvalError.IntervalFieldOverflow,
                else => EvalError.DurationParse,
            },
        };
    }

    if (std.mem.eql(u8, function_name, "makeinterval")) {
        if (args.len != 3) return EvalError.WrongArgumentCount;
        const months_arg = try eval.evalExpr(allocator, args[0].*, env);
        const days_arg = try eval.evalExpr(allocator, args[1].*, env);
        const micros_arg = try eval.evalExpr(allocator, args[2].*, env);
        const months = intLike(months_arg) orelse return Value{ .Null = {} };
        const days = intLike(days_arg) orelse return Value{ .Null = {} };
        const micros = intLike(micros_arg) orelse return Value{ .Null = {} };
        // GAP-0907: the i64 -> i32 narrowing was an unchecked @intCast and
        // panicked for arguments beyond i32 (e.g. MakeInterval(2147483648, 1, 1)).
        const months_i32 = std.math.cast(i32, months) orelse return EvalError.IntegerOverflow;
        const days_i32 = std.math.cast(i32, days) orelse return EvalError.IntegerOverflow;
        return Value{ .Interval = .{
            .months = months_i32,
            .days = days_i32,
            .micros = micros,
        } };
    }

    if (std.mem.eql(u8, function_name, "bytea")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = (try textArg(arg)) orelse return Value{ .Null = {} };
        const result = evaluator_functions.Bytea(allocator, text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "json")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = (try textArg(arg)) orelse return Value{ .Null = {} };
        const result = evaluator_functions.Json(allocator, text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "jsonb")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = (try textArg(arg)) orelse return Value{ .Null = {} };
        const result = evaluator_functions.Jsonb(allocator, text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "xml")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = (try textArg(arg)) orelse return Value{ .Null = {} };
        const result = evaluator_functions.Xml(allocator, text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "url")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = (try textArg(arg)) orelse return Value{ .Null = {} };
        const result = evaluator_functions.Url(allocator, text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "domain")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = (try textArg(arg)) orelse return Value{ .Null = {} };
        const result = evaluator_functions.Domain(allocator, text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "uuid")) {
        if (args.len == 0) {
            return heapValueToEvalValue(evaluator_functions.uuid_v4());
        }
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = (try textArg(arg)) orelse return Value{ .Null = {} };
        const result = evaluator_functions.UUID(text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "bit")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = (try textArg(arg)) orelse return Value{ .Null = {} };
        const wrapped = try normalizeBitLiteral(allocator, text);
        defer allocator.free(wrapped);
        return Value{ .BitString = bitstring.BitString.fromString(allocator, wrapped) catch return EvalError.BitParseError };
    }

    if (std.mem.eql(u8, function_name, "varbit")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = (try textArg(arg)) orelse return Value{ .Null = {} };
        const wrapped = try normalizeBitLiteral(allocator, text);
        defer allocator.free(wrapped);
        const result = evaluator_functions.VarBit(allocator, wrapped) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "range")) {
        if (args.len != 4) return EvalError.WrongArgumentCount;
        const base_arg = try eval.evalExpr(allocator, args[0].*, env);
        const lower_arg = try eval.evalExpr(allocator, args[1].*, env);
        const upper_arg = try eval.evalExpr(allocator, args[2].*, env);
        const bounds_arg = try eval.evalExpr(allocator, args[3].*, env);
        const base_type = (try textArg(base_arg)) orelse return Value{ .Null = {} };
        const bounds = (try textArg(bounds_arg)) orelse return Value{ .Null = {} };

        const result = evaluator_functions.RangeValue(
            allocator,
            base_type,
            if (lower_arg == .Null) null else evalValueToHeapValue(lower_arg),
            if (upper_arg == .Null) null else evalValueToHeapValue(upper_arg),
            bounds,
        ) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    // IntRange(lower, upper, include_lower, include_upper) constructor
    if (std.mem.eql(u8, function_name, "intrange")) {
        if (args.len != 4) return EvalError.WrongArgumentCount;
        const lower_arg = try eval.evalExpr(allocator, args[0].*, env);
        const upper_arg = try eval.evalExpr(allocator, args[1].*, env);
        const inc_lower_arg = try eval.evalExpr(allocator, args[2].*, env);
        const inc_upper_arg = try eval.evalExpr(allocator, args[3].*, env);

        const inc_lower = if (inc_lower_arg == .Bool) inc_lower_arg.Bool else true;
        const inc_upper = if (inc_upper_arg == .Bool) inc_upper_arg.Bool else false;

        const bounds_str: []const u8 = if (inc_lower and inc_upper) "[]" else if (inc_lower and !inc_upper) "[)" else if (!inc_lower and inc_upper) "(]" else "()";

        const result = evaluator_functions.RangeValue(
            allocator,
            "int4",
            if (lower_arg == .Null) null else evalValueToHeapValue(lower_arg),
            if (upper_arg == .Null) null else evalValueToHeapValue(upper_arg),
            bounds_str,
        ) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "jsonb_get")) {
        if (args.len != 2) return EvalError.WrongArgumentCount;
        const doc = try eval.evalExpr(allocator, args[0].*, env);
        const path = try eval.evalExpr(allocator, args[1].*, env);
        if (anyNull(&.{ doc, path })) return Value{ .Null = {} };
        const path_text = (try textArg(path)) orelse return Value{ .Null = {} };
        const result = evaluator_functions.jsonb_get(allocator, evalValueToHeapValue(doc), path_text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "jsonb_typeof")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        // A NULL operand is NULL (ISO/IEC 39075:2024 20.22 GR 1 b).
        if (arg == .Null) return Value{ .Null = {} };
        const result = evaluator_functions.jsonb_typeof(allocator, evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "jsonb_exists")) {
        if (args.len != 2) return EvalError.WrongArgumentCount;
        const doc = try eval.evalExpr(allocator, args[0].*, env);
        const key = try eval.evalExpr(allocator, args[1].*, env);
        if (anyNull(&.{ doc, key })) return Value{ .Null = {} };
        const key_text = (try textArg(key)) orelse return Value{ .Null = {} };
        const result = evaluator_functions.jsonb_exists(evalValueToHeapValue(doc), key_text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "xml_is_well_formed")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        // SONNY-6555 item 4: NULL in is NULL out (it was false).
        if (arg == .Null) return Value{ .Null = {} };
        return heapValueToEvalValue(evaluator_functions.xml_is_well_formed(evalValueToHeapValue(arg)));
    }

    if (std.mem.eql(u8, function_name, "url_host")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        if (anyNull(&.{arg})) return Value{ .Null = {} };
        const result = evaluator_functions.url_host(evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "url_scheme")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        if (anyNull(&.{arg})) return Value{ .Null = {} };
        const result = evaluator_functions.url_scheme(evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "url_path")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        if (anyNull(&.{arg})) return Value{ .Null = {} };
        const result = evaluator_functions.url_path(evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "url_query")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        return switch (arg) {
            .Url => |u| Value{ .Text = if (u.query) |q| q else "" },
            .ExtValue => |ext| switch (ext) {
                .Url => |u| Value{ .Text = if (u.query) |q| q else "" },
                else => Value{ .Null = {} },
            },
            else => Value{ .Null = {} },
        };
    }

    if (std.mem.eql(u8, function_name, "url_origin")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        return switch (arg) {
            .Url => |u| Value{ .Text = try u.getOrigin(allocator) },
            .ExtValue => |ext| switch (ext) {
                .Url => |u| Value{ .Text = try u.getOrigin(allocator) },
                else => Value{ .Null = {} },
            },
            else => Value{ .Null = {} },
        };
    }

    if (std.mem.eql(u8, function_name, "domain_labels")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        if (anyNull(&.{arg})) return Value{ .Null = {} };
        const result = evaluator_functions.domain_labels(allocator, evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "domain_root")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const domain = switch (arg) {
            .Domain => |d| d,
            .ExtValue => |ext| switch (ext) {
                .Domain => |d| d,
                else => return Value{ .Null = {} },
            },
            else => return Value{ .Null = {} },
        };
        // GAP-0877: real eTLD+1 via the bundled public-suffix snapshot
        // (multi-label suffixes like co.uk, wildcard and exception rules;
        // unknown TLDs fall back to the last two labels). A domain that IS a
        // public suffix has no registrable part and returns Null.
        const root = try public_suffix.registrableDomain(allocator, domain.labels);
        if (root) |r| return Value{ .Text = r };
        return Value{ .Null = {} };
    }

    if (std.mem.eql(u8, function_name, "uuid_v4")) {
        if (args.len != 0) return EvalError.WrongArgumentCount;
        return heapValueToEvalValue(evaluator_functions.uuid_v4());
    }

    if (std.mem.eql(u8, function_name, "uuid_v7")) {
        if (args.len != 0) return EvalError.WrongArgumentCount;
        return heapValueToEvalValue(evaluator_functions.uuid_v7());
    }

    if (std.mem.eql(u8, function_name, "uuid_equal")) {
        if (args.len != 2) return EvalError.WrongArgumentCount;
        const lhs = try eval.evalExpr(allocator, args[0].*, env);
        const rhs = try eval.evalExpr(allocator, args[1].*, env);
        if (anyNull(&.{ lhs, rhs })) return Value{ .Null = {} };
        const result = evaluator_functions.uuid_equal(evalValueToHeapValue(lhs), evalValueToHeapValue(rhs)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "to_hex")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        if (anyNull(&.{arg})) return Value{ .Null = {} };
        const result = evaluator_functions.to_hex(allocator, evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "from_hex")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        if (anyNull(&.{arg})) return Value{ .Null = {} };
        const result = evaluator_functions.from_hex(allocator, evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "array")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        // The array is NULL as a whole, or not at all.
        if (arg == .Null) return Value{ .Null = {} };
        return switch (arg) {
            .List => |items| try array_functions.arrayFromList(allocator, items),
            else => EvalError.TypeMismatch,
        };
    }

    if (std.mem.eql(u8, function_name, "array_length")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        if (anyNull(&.{arg})) return Value{ .Null = {} };
        // SONNY-6732: an array, or the list a literal (`[1, 2, 3]`) is.
        if (array_functions.lengthOf(arg)) |n| return Value{ .Int = @intCast(n) };
        const result = evaluator_functions.array_length(evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "array_contains")) {
        if (args.len != 2) return EvalError.WrongArgumentCount;
        const array_arg = try eval.evalExpr(allocator, args[0].*, env);
        const value_arg = try eval.evalExpr(allocator, args[1].*, env);
        if (anyNull(&.{ array_arg, value_arg })) return Value{ .Null = {} };
        const result = evaluator_functions.array_contains(evalValueToHeapValue(array_arg), evalValueToHeapValue(value_arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "bit_and")) {
        if (args.len != 2) return EvalError.WrongArgumentCount;
        const lhs = try eval.evalExpr(allocator, args[0].*, env);
        const rhs = try eval.evalExpr(allocator, args[1].*, env);
        if (anyNull(&.{ lhs, rhs })) return Value{ .Null = {} };
        const result = evaluator_functions.bit_and(allocator, evalValueToHeapValue(lhs), evalValueToHeapValue(rhs)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "bit_count")) {
        if (args.len != 1) return EvalError.WrongArgumentCount;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        if (anyNull(&.{arg})) return Value{ .Null = {} };
        const result = evaluator_functions.bit_count(evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "range_contains")) {
        if (args.len != 2) return EvalError.WrongArgumentCount;
        const range_arg = try eval.evalExpr(allocator, args[0].*, env);
        const element_arg = try eval.evalExpr(allocator, args[1].*, env);
        if (anyNull(&.{ range_arg, element_arg })) return Value{ .Null = {} };
        const result = evaluator_functions.range_contains(evalValueToHeapValue(range_arg), evalValueToHeapValue(element_arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "range_overlaps")) {
        if (args.len != 2) return EvalError.WrongArgumentCount;
        const lhs = try eval.evalExpr(allocator, args[0].*, env);
        const rhs = try eval.evalExpr(allocator, args[1].*, env);
        if (anyNull(&.{ lhs, rhs })) return Value{ .Null = {} };
        const result = evaluator_functions.range_overlaps(evalValueToHeapValue(lhs), evalValueToHeapValue(rhs)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "domain_suffix_match")) {
        if (args.len != 2) return EvalError.WrongArgumentCount;
        const domain_arg = try eval.evalExpr(allocator, args[0].*, env);
        const suffix_arg = try eval.evalExpr(allocator, args[1].*, env);
        if (anyNull(&.{ domain_arg, suffix_arg })) return Value{ .Null = {} };
        const suffix_text = (try textArg(suffix_arg)) orelse return Value{ .Null = {} };
        const result = evaluator_functions.domain_suffix_match(evalValueToHeapValue(domain_arg), suffix_text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "evalMathFunction: abs" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };

    // Create an expression for abs(-5)
    var int_expr = ast.Expr{ .Int = -5 };
    const arg_ptr: *ast.Expr = &int_expr;
    var args_arr: [1]*ast.Expr = .{arg_ptr};
    const args = args_arr[0..];

    const result = try evalMathFunction(allocator, "abs", args, env);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .Int);
    try std.testing.expectEqual(@as(i64, 5), result.?.Int);
}

test "evalStringFunction: upper" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };

    var str_expr = ast.Expr{ .String = "hello" };
    const arg_ptr: *ast.Expr = &str_expr;
    var args_arr: [1]*ast.Expr = .{arg_ptr};
    const args = args_arr[0..];

    const result = try evalStringFunction(allocator, "upper", args, env);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .Str);
    try std.testing.expectEqualStrings("HELLO", result.?.Str);

    // Clean up allocated string
    allocator.free(result.?.Str);
}

test "evalCollectionFunction: size" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };

    var str_expr = ast.Expr{ .String = "hello" };
    const arg_ptr: *ast.Expr = &str_expr;
    var args_arr: [1]*ast.Expr = .{arg_ptr};
    const args = args_arr[0..];

    const result = try evalCollectionFunction(allocator, "size", args, env);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .Int);
    try std.testing.expectEqual(@as(i64, 5), result.?.Int);
}
