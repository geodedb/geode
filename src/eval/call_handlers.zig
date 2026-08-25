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

pub const Value = value_types.Value;
pub const EvalError = value_types.EvalError;
pub const Env = value_types.Env;

const evalValueToHeapValue = type_promotion.evalValueToHeapValue;
const heapValueToEvalValue = type_promotion.heapValueToEvalValue;

// Forward declaration for recursive evalExpr call
const eval = @import("../eval.zig");

fn mapEvaluatorError(err: evaluator_functions.EvaluatorError) EvalError {
    return switch (err) {
        evaluator_functions.EvaluatorError.TypeMismatch => EvalError.TypeMismatch,
        evaluator_functions.EvaluatorError.DivisionByZero => EvalError.DivisionByZero,
        evaluator_functions.EvaluatorError.Overflow => EvalError.Unsupported,
        evaluator_functions.EvaluatorError.InvalidFormat => EvalError.TypeMismatch,
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
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Int => |i| {
                const abs_val = if (i < 0) -i else i;
                return Value{ .Int = abs_val };
            },
            .Decimal => |d| {
                if (d.coeff >= 0) {
                    return arg;
                }
                return Value{ .Decimal = .{ .coeff = -d.coeff, .scale = d.scale, .orig_scale = d.orig_scale, .orig_repr = d.orig_repr } };
            },
            else => return Value{ .Null = {} },
        }
    }

    // sqrt(x)
    if (std.mem.eql(u8, function_name, "sqrt")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Int => |i| {
                if (i < 0) return Value{ .Null = {} };
                const f = @sqrt(@as(f64, @floatFromInt(i)));
                return Value{ .Decimal = .{ .coeff = @intFromFloat(f * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
            },
            .Decimal => |d| {
                if (d.coeff < 0) return Value{ .Null = {} };
                const f = @sqrt(@as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))));
                return Value{ .Decimal = .{ .coeff = @intFromFloat(f * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
            },
            else => return Value{ .Null = {} },
        }
    }

    // pow(base, exp)
    if (std.mem.eql(u8, function_name, "pow")) {
        if (args.len != 2) return Value{ .Null = {} };
        const base_arg = try eval.evalExpr(allocator, args[0].*, env);
        const exp_arg = try eval.evalExpr(allocator, args[1].*, env);

        const base = switch (base_arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            else => return Value{ .Null = {} },
        };

        const exponent = switch (exp_arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            else => return Value{ .Null = {} },
        };

        const result = std.math.pow(f64, base, exponent);
        if (std.math.isNan(result) or std.math.isInf(result)) return Value{ .Null = {} };
        const scaled = result * 1000000;
        if (scaled < -1.7e38 or scaled > 1.7e38) return Value{ .Null = {} };
        return Value{ .Decimal = .{ .coeff = @intFromFloat(scaled), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // sin(x)
    if (std.mem.eql(u8, function_name, "sin")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            else => return Value{ .Null = {} },
        };
        const result = @sin(val);
        if (std.math.isNan(result)) return Value{ .Null = {} };
        return Value{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // cos(x)
    if (std.mem.eql(u8, function_name, "cos")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            else => return Value{ .Null = {} },
        };
        const result = @cos(val);
        if (std.math.isNan(result)) return Value{ .Null = {} };
        return Value{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // tan(x)
    if (std.mem.eql(u8, function_name, "tan")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            else => return Value{ .Null = {} },
        };
        const result = @tan(val);
        if (std.math.isNan(result) or std.math.isInf(result)) return Value{ .Null = {} };
        const scaled = result * 1000000;
        if (scaled < -1.7e38 or scaled > 1.7e38) return Value{ .Null = {} };
        return Value{ .Decimal = .{ .coeff = @intFromFloat(scaled), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // CANARY: REQ=REQ-MATH-TRIG-001; FEATURE="TrigonometricFunctions"; ASPECT=ATAN; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_math_algorithms.yml; OWNER=math; UPDATED=2025-10-26
    // atan(x)
    if (std.mem.eql(u8, function_name, "atan")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            else => return Value{ .Null = {} },
        };
        const result = std.math.atan(val);
        if (std.math.isNan(result)) return Value{ .Null = {} };
        return Value{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // CANARY: REQ=REQ-MATH-TRIG-002; FEATURE="TrigonometricFunctions"; ASPECT=ATAN2; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_math_algorithms.yml; OWNER=math; UPDATED=2025-10-26
    // atan2(y, x)
    if (std.mem.eql(u8, function_name, "atan2")) {
        if (args.len != 2) return Value{ .Null = {} };
        const arg_y = try eval.evalExpr(allocator, args[0].*, env);
        const arg_x = try eval.evalExpr(allocator, args[1].*, env);

        const val_y = switch (arg_y) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            else => return Value{ .Null = {} },
        };

        const val_x = switch (arg_x) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            else => return Value{ .Null = {} },
        };

        const result = std.math.atan2(val_y, val_x);
        if (std.math.isNan(result)) return Value{ .Null = {} };
        return Value{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // CANARY: REQ=REQ-MATH-TRIG-003; FEATURE="TrigonometricFunctions"; ASPECT=ASIN; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_math_algorithms.yml; OWNER=math; UPDATED=2025-10-26
    // asin(x)
    if (std.mem.eql(u8, function_name, "asin")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            else => return Value{ .Null = {} },
        };
        if (val < -1.0 or val > 1.0) return Value{ .Null = {} };
        const result = std.math.asin(val);
        if (std.math.isNan(result)) return Value{ .Null = {} };
        return Value{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // CANARY: REQ=REQ-MATH-TRIG-004; FEATURE="TrigonometricFunctions"; ASPECT=ACOS; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_math_algorithms.yml; OWNER=math; UPDATED=2025-10-26
    // acos(x)
    if (std.mem.eql(u8, function_name, "acos")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            else => return Value{ .Null = {} },
        };
        if (val < -1.0 or val > 1.0) return Value{ .Null = {} };
        const result = std.math.acos(val);
        if (std.math.isNan(result)) return Value{ .Null = {} };
        return Value{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // CANARY: REQ=REQ-MATH-CONVERT-001; FEATURE="AngleConversion"; ASPECT=DEGREES; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_math_algorithms.yml; OWNER=math; UPDATED=2025-12-27
    // degrees(radians)
    if (std.mem.eql(u8, function_name, "degrees")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            else => return Value{ .Null = {} },
        };
        const result = val * (180.0 / std.math.pi);
        if (std.math.isNan(result) or std.math.isInf(result)) return Value{ .Null = {} };
        return Value{ .Decimal = .{ .coeff = @intFromFloat(@round(result * 1000000)), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // CANARY: REQ=REQ-MATH-CONVERT-002; FEATURE="AngleConversion"; ASPECT=RADIANS; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_math_algorithms.yml; OWNER=math; UPDATED=2025-12-27
    // radians(degrees)
    if (std.mem.eql(u8, function_name, "radians")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            else => return Value{ .Null = {} },
        };
        const result = val * (std.math.pi / 180.0);
        if (std.math.isNan(result) or std.math.isInf(result)) return Value{ .Null = {} };
        return Value{ .Decimal = .{ .coeff = @intFromFloat(@round(result * 1000000)), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // log(x)
    if (std.mem.eql(u8, function_name, "log")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            else => return Value{ .Null = {} },
        };
        if (val <= 0) return Value{ .Null = {} };
        const result = @log(val);
        if (std.math.isNan(result) or std.math.isInf(result)) return Value{ .Null = {} };
        return Value{ .Decimal = .{ .coeff = @intFromFloat(result * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // exp(x)
    if (std.mem.eql(u8, function_name, "exp")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const val = switch (arg) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            else => return Value{ .Null = {} },
        };
        const result = @exp(val);
        if (std.math.isNan(result) or std.math.isInf(result)) return Value{ .Null = {} };
        const scaled = result * 1000000;
        if (scaled < -1.7e38 or scaled > 1.7e38) return Value{ .Null = {} };
        return Value{ .Decimal = .{ .coeff = @intFromFloat(scaled), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    }

    // ceil(x)
    if (std.mem.eql(u8, function_name, "ceil")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Int => |i| return Value{ .Int = i },
            .Decimal => |d| {
                const divisor = std.math.pow(i128, 10, d.scale);
                const whole = @divTrunc(d.coeff, divisor);
                const frac = @rem(d.coeff, divisor);
                if (frac > 0) {
                    return Value{ .Int = @intCast(whole + 1) };
                } else {
                    return Value{ .Int = @intCast(whole) };
                }
            },
            else => return Value{ .Null = {} },
        }
    }

    // floor(x)
    if (std.mem.eql(u8, function_name, "floor")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Int => |i| return Value{ .Int = i },
            .Decimal => |d| {
                const divisor = std.math.pow(i128, 10, d.scale);
                const whole = @divTrunc(d.coeff, divisor);
                const frac = @rem(d.coeff, divisor);
                if (frac < 0) {
                    return Value{ .Int = @intCast(whole - 1) };
                } else {
                    return Value{ .Int = @intCast(whole) };
                }
            },
            else => return Value{ .Null = {} },
        }
    }

    // CANARY: REQ=REQ-MATH-ARITH-001; FEATURE="ArithmeticFunctions"; ASPECT=ROUND; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=math; UPDATED=2025-12-22
    // round(x [, precision])
    if (std.mem.eql(u8, function_name, "round")) {
        if (args.len < 1 or args.len > 2) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);

        var precision: i64 = 0;
        if (args.len == 2) {
            const prec_arg = try eval.evalExpr(allocator, args[1].*, env);
            precision = switch (prec_arg) {
                .Int => |i| i,
                else => 0,
            };
        }

        switch (arg) {
            .Int => |i| {
                if (precision >= 0) {
                    return Value{ .Int = i };
                } else {
                    const scale_factor = std.math.pow(i64, 10, @intCast(-precision));
                    const rounded = @divTrunc(i + @divTrunc(scale_factor, 2), scale_factor) * scale_factor;
                    return Value{ .Int = rounded };
                }
            },
            .Decimal => |d| {
                if (precision == 0) {
                    const divisor = std.math.pow(i128, 10, d.scale);
                    const whole = @divTrunc(d.coeff, divisor);
                    const frac = @rem(d.coeff, divisor);
                    const half_divisor = @divTrunc(divisor, 2);
                    if (frac >= half_divisor) {
                        return Value{ .Int = @intCast(whole + 1) };
                    } else if (frac <= -half_divisor) {
                        return Value{ .Int = @intCast(whole - 1) };
                    } else {
                        return Value{ .Int = @intCast(whole) };
                    }
                } else if (precision > 0) {
                    const target_scale: u8 = @intCast(@min(precision, 38));
                    if (target_scale >= d.scale) {
                        return Value{ .Decimal = d };
                    }
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
                    return Value{ .Decimal = .{ .coeff = new_coeff, .scale = target_scale } };
                } else {
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
                    const result = new_coeff * std.math.pow(i128, 10, @intCast(-precision));
                    return Value{ .Int = @intCast(result) };
                }
            },
            else => return Value{ .Null = {} },
        }
    }

    // CANARY: REQ=REQ-MATH-ARITH-001; FEATURE="ArithmeticFunctions"; ASPECT=MOD; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=math; UPDATED=2025-10-26
    // mod(dividend, divisor)
    if (std.mem.eql(u8, function_name, "mod")) {
        if (args.len != 2) return Value{ .Null = {} };
        const dividend_arg = try eval.evalExpr(allocator, args[0].*, env);
        const divisor_arg = try eval.evalExpr(allocator, args[1].*, env);

        const dividend = switch (dividend_arg) {
            .Int => |i| i,
            else => return Value{ .Null = {} },
        };

        const divisor = switch (divisor_arg) {
            .Int => |i| i,
            else => return Value{ .Null = {} },
        };

        if (divisor == 0) return Value{ .Null = {} };
        const result = @rem(dividend, divisor);
        return Value{ .Int = result };
    }

    // CANARY: REQ=REQ-MATH-ARITH-002; FEATURE="ArithmeticFunctions"; ASPECT=SIGN; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=math; UPDATED=2025-10-26
    // sign(x)
    if (std.mem.eql(u8, function_name, "sign")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);

        const sign_value = switch (arg) {
            .Int => |i| if (i < 0) @as(i64, -1) else if (i > 0) @as(i64, 1) else @as(i64, 0),
            .Decimal => |d| if (d.coeff < 0) @as(i64, -1) else if (d.coeff > 0) @as(i64, 1) else @as(i64, 0),
            else => return Value{ .Null = {} },
        };

        return Value{ .Int = sign_value };
    }

    // random() — returns decimal in [0, 1) using cryptographically secure source
    if (std.mem.eql(u8, function_name, "random")) {
        if (args.len != 0) return Value{ .Null = {} };
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
    // substring(str, start [, length])
    if (std.mem.eql(u8, function_name, "substring")) {
        if (args.len < 2) return Value{ .Null = {} };
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);
        const start_arg = try eval.evalExpr(allocator, args[1].*, env);

        const str = switch (str_arg) {
            .Str => |s| s,
            else => return Value{ .Null = {} },
        };

        // GQL/SQL uses 1-based indexing for substring
        const start = switch (start_arg) {
            .Int => |i| if (i < 1) 0 else @as(usize, @intCast(i - 1)),
            else => return Value{ .Null = {} },
        };

        if (args.len >= 3) {
            const len_arg = try eval.evalExpr(allocator, args[2].*, env);
            const len = switch (len_arg) {
                .Int => |i| if (i < 0) 0 else @as(usize, @intCast(i)),
                else => return Value{ .Null = {} },
            };

            if (start >= str.len) {
                return Value{ .Str = "" };
            }

            const end = @min(start + len, str.len);
            return Value{ .Str = str[start..end] };
        } else {
            if (start >= str.len) {
                return Value{ .Str = "" };
            }
            return Value{ .Str = str[start..] };
        }
    }

    // replace(str, search, replacement)
    if (std.mem.eql(u8, function_name, "replace")) {
        if (args.len != 3) return Value{ .Null = {} };
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);
        const search_arg = try eval.evalExpr(allocator, args[1].*, env);
        const replace_arg = try eval.evalExpr(allocator, args[2].*, env);

        const str = switch (str_arg) {
            .Str => |s| s,
            else => return Value{ .Null = {} },
        };

        const search = switch (search_arg) {
            .Str => |s| s,
            else => return Value{ .Null = {} },
        };

        const replacement = switch (replace_arg) {
            .Str => |s| s,
            else => return Value{ .Null = {} },
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
        if (args.len != 1) return Value{ .Null = {} };
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);

        const str = switch (str_arg) {
            .Str => |s| s,
            else => return Value{ .Null = {} },
        };

        const trimmed = std.mem.trim(u8, str, " \t\n\r");
        return Value{ .Str = trimmed };
    }

    // CANARY: REQ=REQ-GQL-STRING-FUNCTIONS-001; FEATURE="StringFunctions"; ASPECT=LTrim; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-27
    // ltrim(str)
    if (std.mem.eql(u8, function_name, "ltrim")) {
        if (args.len != 1) return Value{ .Null = {} };
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);

        const str = switch (str_arg) {
            .Str => |s| s,
            else => return Value{ .Null = {} },
        };

        const trimmed = std.mem.trimStart(u8, str, " \t\n\r");
        return Value{ .Str = trimmed };
    }

    // CANARY: REQ=REQ-GQL-STRING-FUNCTIONS-002; FEATURE="StringFunctions"; ASPECT=RTrim; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-27
    // rtrim(str)
    if (std.mem.eql(u8, function_name, "rtrim")) {
        if (args.len != 1) return Value{ .Null = {} };
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);

        const str = switch (str_arg) {
            .Str => |s| s,
            else => return Value{ .Null = {} },
        };

        const trimmed = std.mem.trimEnd(u8, str, " \t\n\r");
        return Value{ .Str = trimmed };
    }

    // CANARY: REQ=REQ-GQL-STRING-FUNCTIONS-003; FEATURE="StringFunctions"; ASPECT=Left; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-27
    // left(str, count)
    if (std.mem.eql(u8, function_name, "left")) {
        if (args.len != 2) return Value{ .Null = {} };
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);
        const len_arg = try eval.evalExpr(allocator, args[1].*, env);

        const str = switch (str_arg) {
            .Str => |s| s,
            else => return Value{ .Null = {} },
        };

        const count = switch (len_arg) {
            .Int => |i| if (i < 0) @as(usize, 0) else @as(usize, @intCast(i)),
            else => return Value{ .Null = {} },
        };

        const result_len = @min(count, str.len);
        return Value{ .Str = str[0..result_len] };
    }

    // CANARY: REQ=REQ-GQL-STRING-FUNCTIONS-004; FEATURE="StringFunctions"; ASPECT=Right; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-27
    // right(str, count)
    if (std.mem.eql(u8, function_name, "right")) {
        if (args.len != 2) return Value{ .Null = {} };
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);
        const len_arg = try eval.evalExpr(allocator, args[1].*, env);

        const str = switch (str_arg) {
            .Str => |s| s,
            else => return Value{ .Null = {} },
        };

        const count = switch (len_arg) {
            .Int => |i| if (i < 0) @as(usize, 0) else @as(usize, @intCast(i)),
            else => return Value{ .Null = {} },
        };

        const result_len = @min(count, str.len);
        const start = str.len - result_len;
        return Value{ .Str = str[start..] };
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
        if (args.len != 2) return Value{ .Null = {} };
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);
        const delim_arg = try eval.evalExpr(allocator, args[1].*, env);

        const str = switch (str_arg) {
            .Str => |s| s,
            else => return Value{ .Null = {} },
        };
        const delim = switch (delim_arg) {
            .Str => |s| s,
            else => return Value{ .Null = {} },
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
        if (args.len != 1) return Value{ .Null = {} };
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);

        const str = switch (str_arg) {
            .Str => |s| s,
            else => return Value{ .Null = {} },
        };

        var result = try allocator.alloc(u8, str.len);
        for (str, 0..) |c, i| {
            result[i] = std.ascii.toUpper(c);
        }
        return Value{ .Str = result };
    }

    // lower(str) / tolower(str)
    if (std.mem.eql(u8, function_name, "lower") or std.mem.eql(u8, function_name, "tolower")) {
        if (args.len != 1) return Value{ .Null = {} };
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);

        const str = switch (str_arg) {
            .Str => |s| s,
            else => return Value{ .Null = {} },
        };

        var result = try allocator.alloc(u8, str.len);
        for (str, 0..) |c, i| {
            result[i] = std.ascii.toLower(c);
        }
        return Value{ .Str = result };
    }

    // icontains(str, substr) - case-insensitive CONTAINS
    if (std.mem.eql(u8, function_name, "icontains")) {
        if (args.len != 2) return Value{ .Null = {} };
        const str_arg = try eval.evalExpr(allocator, args[0].*, env);
        const needle_arg = try eval.evalExpr(allocator, args[1].*, env);

        const str_val = switch (str_arg) {
            .Str => |s| s,
            else => return Value{ .Null = {} },
        };
        const needle_val = switch (needle_arg) {
            .Str => |s| s,
            else => return Value{ .Null = {} },
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
        if (args.len != 2) return Value{ .Null = {} };

        const value_arg = try eval.evalExpr(allocator, args[0].*, env);
        const type_arg = try eval.evalExpr(allocator, args[1].*, env);

        if (value_arg == .Null) return Value{ .Null = {} };

        const target_type = switch (type_arg) {
            .Str => |s| s,
            else => return Value{ .Null = {} },
        };

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
                .Int => |i| {
                    var coeff = @as(i128, i);
                    var s: u8 = 0;
                    while (s < target_scale) : (s += 1) {
                        coeff *= 10;
                    }
                    return Value{ .Decimal = .{ .coeff = coeff, .scale = target_scale } };
                },
                .Decimal => |d| {
                    var coeff = d.coeff;
                    var current_scale = d.scale;
                    while (current_scale < target_scale) : (current_scale += 1) {
                        coeff *= 10;
                    }
                    while (current_scale > target_scale) : (current_scale -= 1) {
                        coeff = @divTrunc(coeff, 10);
                    }
                    return Value{ .Decimal = .{ .coeff = coeff, .scale = target_scale } };
                },
                .Str => |s| {
                    if (std.mem.indexOf(u8, s, ".")) |dot_idx| {
                        const int_part = s[0..dot_idx];
                        const frac_part = s[dot_idx + 1 ..];
                        // GAP-0921: invalid character / overflow are errors, not silent NULL.
                        const int_val = std.fmt.parseInt(i128, int_part, 10) catch |e| return castParseError(e);
                        const frac_val = std.fmt.parseInt(i128, frac_part, 10) catch |e| return castParseError(e);
                        var coeff = int_val;
                        const frac_len = frac_part.len;
                        var mult: i128 = 1;
                        var k: usize = 0;
                        while (k < frac_len) : (k += 1) {
                            mult *= 10;
                        }
                        coeff = coeff * mult + frac_val;
                        var current_scale: u8 = @intCast(frac_len);
                        while (current_scale < target_scale) : (current_scale += 1) {
                            coeff *= 10;
                        }
                        while (current_scale > target_scale) : (current_scale -= 1) {
                            coeff = @divTrunc(coeff, 10);
                        }
                        return Value{ .Decimal = .{ .coeff = coeff, .scale = target_scale } };
                    } else {
                        const int_val = std.fmt.parseInt(i128, s, 10) catch |e| return castParseError(e);
                        var coeff = int_val;
                        var sc: u8 = 0;
                        while (sc < target_scale) : (sc += 1) {
                            coeff *= 10;
                        }
                        return Value{ .Decimal = .{ .coeff = coeff, .scale = target_scale } };
                    }
                },
                // GAP-0921: an unconvertible source value is a cast error.
                else => return EvalError.InvalidCast,
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
                    if (std.mem.indexOf(u8, s, ".")) |dot_idx| {
                        const int_part = s[0..dot_idx];
                        const val = std.fmt.parseInt(i64, int_part, 10) catch |e| return castParseError(e);
                        return Value{ .Int = val };
                    } else {
                        const val = std.fmt.parseInt(i64, s, 10) catch |e| return castParseError(e);
                        return Value{ .Int = val };
                    }
                },
                .Bool => |b| return Value{ .Int = if (b) 1 else 0 },
                // GAP-0921: an unconvertible source value is a cast error.
                else => return EvalError.InvalidCast,
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
                    if (d.scale == 0) {
                        const str = try std.fmt.allocPrint(allocator, "{d}", .{d.coeff});
                        return Value{ .Str = str };
                    } else {
                        var divisor: i128 = 1;
                        var sc = d.scale;
                        while (sc > 0) : (sc -= 1) {
                            divisor *= 10;
                        }
                        const int_part = @divTrunc(d.coeff, divisor);
                        const frac_part_signed = @rem(d.coeff, divisor);
                        const frac_part = if (frac_part_signed < 0) -frac_part_signed else frac_part_signed;
                        var frac_buf: [32]u8 = undefined;
                        const frac_str = std.fmt.bufPrint(&frac_buf, "{d}", .{frac_part}) catch return Value{ .Null = {} };
                        const frac_len = frac_str.len;
                        const zeros_needed: usize = if (d.scale > frac_len) d.scale - @as(u8, @intCast(frac_len)) else 0;
                        var int_buf: [32]u8 = undefined;
                        const int_str = std.fmt.bufPrint(&int_buf, "{d}", .{int_part}) catch return Value{ .Null = {} };
                        const total_len = int_str.len + 1 + zeros_needed + frac_len;
                        const result = allocator.alloc(u8, total_len) catch return Value{ .Null = {} };
                        var pos: usize = 0;
                        @memcpy(result[pos..][0..int_str.len], int_str);
                        pos += int_str.len;
                        result[pos] = '.';
                        pos += 1;
                        @memset(result[pos..][0..zeros_needed], '0');
                        pos += zeros_needed;
                        @memcpy(result[pos..][0..frac_len], frac_str);
                        return Value{ .Str = result };
                    }
                },
                .Bool => |b| return Value{ .Str = if (b) "true" else "false" },
                .Str => |s| return Value{ .Str = s },
                else => return Value{ .Null = {} },
            }
        }

        // FLOAT/DOUBLE/REAL conversion
        if (std.mem.eql(u8, upper_type, "FLOAT") or std.mem.eql(u8, upper_type, "DOUBLE") or std.mem.eql(u8, upper_type, "REAL")) {
            switch (value_arg) {
                .Int => |i| {
                    const coeff = @as(i128, i) * 1000000;
                    return Value{ .Decimal = .{ .coeff = coeff, .scale = 6 } };
                },
                .Decimal => |d| return Value{ .Decimal = d },
                .Str => |s| {
                    // GAP-0921: non-numeric string is a cast error, not NULL.
                    const f = std.fmt.parseFloat(f64, s) catch return EvalError.InvalidCast;
                    const coeff = @as(i128, @intFromFloat(f * 1000000));
                    return Value{ .Decimal = .{ .coeff = coeff, .scale = 6 } };
                },
                else => return EvalError.InvalidCast,
            }
        }

        // BOOLEAN/BOOL conversion
        if (std.mem.eql(u8, upper_type, "BOOLEAN") or std.mem.eql(u8, upper_type, "BOOL")) {
            switch (value_arg) {
                .Bool => |b| return Value{ .Bool = b },
                .Int => |i| return Value{ .Bool = i != 0 },
                .Str => |s| {
                    if (std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1")) {
                        return Value{ .Bool = true };
                    } else if (std.ascii.eqlIgnoreCase(s, "false") or std.mem.eql(u8, s, "0")) {
                        return Value{ .Bool = false };
                    } else {
                        // GAP-0921: an unrecognized boolean string is a cast error.
                        return EvalError.InvalidCast;
                    }
                },
                else => return EvalError.InvalidCast,
            }
        }

        // DATE conversion
        if (std.mem.eql(u8, upper_type, "DATE")) {
            switch (value_arg) {
                .Str => |s| {
                    const datetime_module = @import("../types/datetime.zig");
                    // GAP-0921: a non-date string is a cast error, not NULL.
                    const date = datetime_module.Date.fromStr(s) catch return EvalError.InvalidCast;
                    return Value{ .Date = date };
                },
                .Date => return value_arg,
                .Timestamp => |ts| {
                    const datetime_module = @import("../types/datetime.zig");
                    const days: i32 = @intCast(@divFloor(ts.micros_since_epoch, 24 * 3600 * 1_000_000));
                    return Value{ .Date = datetime_module.Date{ .days_since_epoch = days } };
                },
                else => return EvalError.InvalidCast,
            }
        }

        // TIME conversion
        if (std.mem.eql(u8, upper_type, "TIME")) {
            switch (value_arg) {
                .Str => |s| {
                    const datetime_module = @import("../types/datetime.zig");
                    // GAP-0921: a non-time string is a cast error, not NULL.
                    const time = datetime_module.Time.fromStr(s) catch return EvalError.InvalidCast;
                    return Value{ .Time = time };
                },
                .Time => return value_arg,
                .Timestamp => |ts| {
                    const datetime_module = @import("../types/datetime.zig");
                    const micros = @rem(ts.micros_since_epoch, 24 * 3600 * @as(i64, 1_000_000));
                    return Value{ .Time = datetime_module.Time{ .micros_since_midnight = if (micros < 0) micros + 24 * 3600 * 1_000_000 else micros } };
                },
                else => return EvalError.InvalidCast,
            }
        }

        // DATETIME/TIMESTAMP conversion
        if (std.mem.eql(u8, upper_type, "DATETIME") or std.mem.eql(u8, upper_type, "TIMESTAMP")) {
            switch (value_arg) {
                .Str => |s| {
                    const datetime_module = @import("../types/datetime.zig");
                    // GAP-0921: a non-timestamp string is a cast error.
                    const ts = datetime_module.Timestamp.fromStr(s) catch return EvalError.InvalidCast;
                    return Value{ .Timestamp = ts };
                },
                .Timestamp => return value_arg,
                .Date => |d| {
                    return Value{ .Timestamp = .{ .micros_since_epoch = @as(i64, d.days_since_epoch) * 24 * 3600 * 1_000_000 } };
                },
                else => return EvalError.InvalidCast,
            }
        }

        // GAP-0921: an unknown/unsupported target type is not a silent NULL —
        // it is a "feature not supported" error (SQLSTATE 0A000). (A missing
        // type name entirely is already a parse-time 42000.)
        return EvalError.UnsupportedCastTarget;
    }

    // CANARY: REQ=REQ-GQL-086; FEATURE="TypeConversionFunctions"; ASPECT=Evaluation; STATUS=TESTED; OWNER=eval; UPDATED=2025-10-14
    // toFloat/toDouble(x)
    if (std.mem.eql(u8, function_name, "tofloat") or std.mem.eql(u8, function_name, "todouble")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const float_scale: u8 = 6;
        const float_multiplier: i128 = 1000000;
        switch (arg) {
            .Int => |i| return Value{ .Decimal = .{ .coeff = i * float_multiplier, .scale = float_scale } },
            .Decimal => |d| return Value{ .Decimal = d },
            .Str => |s| {
                const f = std.fmt.parseFloat(f64, s) catch return Value{ .Null = {} };
                const scaled: i128 = @intFromFloat(@round(f * @as(f64, @floatFromInt(float_multiplier))));
                return Value{ .Decimal = .{ .coeff = scaled, .scale = float_scale } };
            },
            else => return Value{ .Null = {} },
        }
    }

    // toInteger/toInt(x)
    if (std.mem.eql(u8, function_name, "tointeger") or std.mem.eql(u8, function_name, "toint")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Int => |i| return Value{ .Int = i },
            .Decimal => |d| return Value{ .Int = @intCast(@divFloor(d.coeff, std.math.pow(i128, 10, d.scale))) },
            .Bool => |b| return Value{ .Int = if (b) 1 else 0 },
            .Str => |s| {
                const i = std.fmt.parseInt(i64, s, 10) catch return Value{ .Null = {} };
                return Value{ .Int = i };
            },
            else => return Value{ .Null = {} },
        }
    }

    // CANARY: REQ=REQ-GQL-TOBOOLEAN-001; FEATURE="TypeConversionFunctions"; ASPECT=ToBooleanConversion; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system_comprehensive.yml; OWNER=eval; UPDATED=2025-12-24
    // toBoolean/toBool(x)
    if (std.mem.eql(u8, function_name, "toboolean") or std.mem.eql(u8, function_name, "tobool")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
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

    // toString(x)
    if (std.mem.eql(u8, function_name, "tostring")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Int => |i| {
                var buf: [64]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return Value{ .Str = "" };
                return Value{ .Str = try allocator.dupe(u8, str) };
            },
            .Decimal => |d| {
                const float_val = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(d.scale));
                const str = std.fmt.allocPrint(allocator, "{d}", .{float_val}) catch return Value{ .Str = "" };
                return Value{ .Str = str };
            },
            .Str => |s| return Value{ .Str = s },
            .Bool => |b| return Value{ .Str = if (b) "true" else "false" },
            .Null => return Value{ .Str = "null" },
            else => return Value{ .Str = "" },
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
        if (args.len != 1) return Value{ .Null = {} };
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
        if (args.len != 1) return Value{ .Null = {} };
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
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .List => |l| return Value{ .Int = @intCast(l.len) },
            .Str => |s| return Value{ .Int = @intCast(s.len) },
            .Map => |m| return Value{ .Int = @intCast(m.count()) },
            .Path => |p| return Value{ .Int = @intCast(p.edges.len) },
            // CANARY: REQ=REQ-FN-SIZE-OF-VECTOR; FEATURE="SizeFunction"; ASPECT=VectorDimension; STATUS=TESTED; TEST=tests/test_fn_dispatch_parity.zig; OWNER=eval; UPDATED=2026-08-25
            // FN-DISPATCH-PARITY: a VECTOR is a sized collection, so size()/length() must
            // report its dimension. The old `else => Int 0` arm answered 0 for
            // every stored embedding — a silent lie that read as "empty".
            // `data.len` (not the u16 `dim` field) is authoritative so an
            // overflow-stored vector reports its real element count.
            .ExtValue => |ext| switch (ext) {
                .List => |l| return Value{ .Int = @intCast(l.len) },
                .VectorF32 => |v| return Value{ .Int = @intCast(v.data.len) },
                .VectorI32 => |v| return Value{ .Int = @intCast(v.data.len) },
                else => return Value{ .Int = 0 },
            },
            else => return Value{ .Int = 0 },
        }
    }

    // CANARY: REQ=REQ-GQL-HEAD-001; FEATURE="ListFunctions"; ASPECT=HeadElement; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2026-01-09
    // head(list)
    if (std.mem.eql(u8, function_name, "head")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .List => |l| {
                if (l.len == 0) return Value{ .Null = {} };
                return l[0];
            },
            else => return Value{ .Null = {} },
        }
    }

    // CANARY: REQ=REQ-GQL-TAIL-001; FEATURE="ListFunctions"; ASPECT=TailElements; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2026-01-09
    // tail(list)
    if (std.mem.eql(u8, function_name, "tail")) {
        if (args.len != 1) return Value{ .Null = {} };
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
            else => return Value{ .List = &[_]Value{} },
        }
    }

    // CANARY: REQ=REQ-GQL-LAST-001; FEATURE="ListFunctions"; ASPECT=LastElement; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-24
    // last(list)
    if (std.mem.eql(u8, function_name, "last")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .List => |l| {
                if (l.len == 0) return Value{ .Null = {} };
                return l[l.len - 1];
            },
            else => return Value{ .Null = {} },
        }
    }

    // reverse(list/string)
    if (std.mem.eql(u8, function_name, "reverse")) {
        if (args.len != 1) return Value{ .Null = {} };
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

        const start_val = try eval.evalExpr(allocator, args[0].*, env);
        const start = switch (start_val) {
            .Int => |i| i,
            else => return Value{ .Null = {} },
        };

        const stop_val = try eval.evalExpr(allocator, args[1].*, env);
        const stop = switch (stop_val) {
            .Int => |i| i,
            else => return Value{ .Null = {} },
        };

        const step = if (args.len == 3) blk: {
            const step_val = try eval.evalExpr(allocator, args[2].*, env);
            break :blk switch (step_val) {
                .Int => |i| i,
                else => return Value{ .Null = {} },
            };
        } else 1;

        if (step == 0) return Value{ .Null = {} };

        const count: i64 = if (step > 0) blk: {
            if (stop <= start) break :blk 0;
            const diff = stop - start;
            break :blk @divFloor(diff + step - 1, step);
        } else blk: {
            if (stop >= start) break :blk 0;
            const diff = start - stop;
            break :blk @divFloor(diff - step - 1, -step);
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

        var current = start;
        for (0..ucount) |i| {
            result[i] = Value{ .Int = current };
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
        if (args.len == 0) return Value{ .Null = {} };

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

                if (has_decimal) {
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
    }

    // avg(list)
    if (std.mem.eql(u8, function_name, "avg")) {
        if (args.len == 0) return Value{ .Null = {} };

        const arg = try eval.evalExpr(allocator, args[0].*, env);
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
    }

    // min(list)
    if (std.mem.eql(u8, function_name, "min")) {
        if (args.len == 0) return Value{ .Null = {} };

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
        if (args.len == 0) return Value{ .Null = {} };

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
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const result = evaluator_functions.SmallInt(evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "bigint")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const result = evaluator_functions.BigInt(evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "real")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const result = evaluator_functions.Real(evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "double")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const result = evaluator_functions.Double(evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "int")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        return switch (arg) {
            .Int => arg,
            .SmallInt => |i| Value{ .Int = i },
            .BigInt => |i| Value{ .Int = i },
            .Bool => |b| Value{ .Int = if (b) 1 else 0 },
            else => blk: {
                const text = textLike(arg) orelse break :blk Value{ .Null = {} };
                const parsed = std.fmt.parseInt(i64, text, 10) catch break :blk Value{ .Null = {} };
                break :blk Value{ .Int = parsed };
            },
        };
    }

    if (std.mem.eql(u8, function_name, "bool")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        return switch (arg) {
            .Bool => arg,
            .Int => |i| Value{ .Bool = i != 0 },
            .SmallInt => |i| Value{ .Bool = i != 0 },
            .BigInt => |i| Value{ .Bool = i != 0 },
            else => blk: {
                const text = textLike(arg) orelse break :blk Value{ .Null = {} };
                if (std.ascii.eqlIgnoreCase(text, "true") or std.mem.eql(u8, text, "1")) break :blk Value{ .Bool = true };
                if (std.ascii.eqlIgnoreCase(text, "false") or std.mem.eql(u8, text, "0")) break :blk Value{ .Bool = false };
                break :blk Value{ .Null = {} };
            },
        };
    }

    if (std.mem.eql(u8, function_name, "decimal")) {
        if (args.len < 1 or args.len > 2) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const value_text = (try stringifyValueForConstructor(allocator, arg)) orelse return Value{ .Null = {} };
        defer allocator.free(value_text);

        const scale = if (args.len == 2) blk: {
            const scale_arg = try eval.evalExpr(allocator, args[1].*, env);
            const scale_value = intLike(scale_arg) orelse return Value{ .Null = {} };
            break :blk @as(i16, @intCast(scale_value));
        } else null;

        const result = evaluator_functions.Decimal(allocator, value_text, scale) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "char")) {
        if (args.len != 2) return Value{ .Null = {} };
        const value_arg = try eval.evalExpr(allocator, args[0].*, env);
        const len_arg = try eval.evalExpr(allocator, args[1].*, env);
        const text = textLike(value_arg) orelse return Value{ .Null = {} };
        const n = intLike(len_arg) orelse return Value{ .Null = {} };
        const result = evaluator_functions.Char(allocator, text, @intCast(n)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "varchar")) {
        if (args.len != 2) return Value{ .Null = {} };
        const value_arg = try eval.evalExpr(allocator, args[0].*, env);
        const len_arg = try eval.evalExpr(allocator, args[1].*, env);
        const text = textLike(value_arg) orelse return Value{ .Null = {} };
        const n = intLike(len_arg) orelse return Value{ .Null = {} };
        const result = evaluator_functions.Varchar(allocator, text, @intCast(n)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "text")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = textLike(arg) orelse return Value{ .Null = {} };
        return Value{ .Text = try allocator.dupe(u8, text) };
    }

    if (std.mem.eql(u8, function_name, "date")) {
        if (args.len != 1) return null;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = textLike(arg) orelse return Value{ .Null = {} };
        const result = evaluator_functions.Date(text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "time")) {
        if (args.len != 1) return null;
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = textLike(arg) orelse return Value{ .Null = {} };
        return Value{ .Time = datetime.Time.fromStr(text) catch return EvalError.TimeParse };
    }

    if (std.mem.eql(u8, function_name, "timetz")) {
        if (args.len != 1 and args.len != 2) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = textLike(arg) orelse return Value{ .Null = {} };

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
        const text = textLike(arg) orelse return Value{ .Null = {} };
        const result = evaluator_functions.Timestamp(text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "timestamptz")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = textLike(arg) orelse return Value{ .Null = {} };
        const result = evaluator_functions.TimestampTZ(text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "interval")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = textLike(arg) orelse return Value{ .Null = {} };
        return Value{ .Interval = datetime.Interval.fromStr(text) catch return EvalError.TimeParse };
    }

    if (std.mem.eql(u8, function_name, "makeinterval")) {
        if (args.len != 3) return Value{ .Null = {} };
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
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = textLike(arg) orelse return Value{ .Null = {} };
        const result = evaluator_functions.Bytea(allocator, text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "json")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = textLike(arg) orelse return Value{ .Null = {} };
        const result = evaluator_functions.Json(allocator, text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "jsonb")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = textLike(arg) orelse return Value{ .Null = {} };
        const result = evaluator_functions.Jsonb(allocator, text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "xml")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = textLike(arg) orelse return Value{ .Null = {} };
        const result = evaluator_functions.Xml(allocator, text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "url")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = textLike(arg) orelse return Value{ .Null = {} };
        const result = evaluator_functions.Url(allocator, text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "domain")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = textLike(arg) orelse return Value{ .Null = {} };
        const result = evaluator_functions.Domain(allocator, text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "uuid")) {
        if (args.len == 0) {
            return heapValueToEvalValue(evaluator_functions.uuid_v4());
        }
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = textLike(arg) orelse return Value{ .Null = {} };
        const result = evaluator_functions.UUID(text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "bit")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = textLike(arg) orelse return Value{ .Null = {} };
        const wrapped = try normalizeBitLiteral(allocator, text);
        defer allocator.free(wrapped);
        return Value{ .BitString = bitstring.BitString.fromString(allocator, wrapped) catch return EvalError.BitParseError };
    }

    if (std.mem.eql(u8, function_name, "varbit")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const text = textLike(arg) orelse return Value{ .Null = {} };
        const wrapped = try normalizeBitLiteral(allocator, text);
        defer allocator.free(wrapped);
        const result = evaluator_functions.VarBit(allocator, wrapped) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "range")) {
        if (args.len != 4) return Value{ .Null = {} };
        const base_arg = try eval.evalExpr(allocator, args[0].*, env);
        const lower_arg = try eval.evalExpr(allocator, args[1].*, env);
        const upper_arg = try eval.evalExpr(allocator, args[2].*, env);
        const bounds_arg = try eval.evalExpr(allocator, args[3].*, env);
        const base_type = textLike(base_arg) orelse return Value{ .Null = {} };
        const bounds = textLike(bounds_arg) orelse return Value{ .Null = {} };

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
        if (args.len != 4) return Value{ .Null = {} };
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
        if (args.len != 2) return Value{ .Null = {} };
        const doc = try eval.evalExpr(allocator, args[0].*, env);
        const path = try eval.evalExpr(allocator, args[1].*, env);
        const path_text = textLike(path) orelse return Value{ .Null = {} };
        const result = evaluator_functions.jsonb_get(evalValueToHeapValue(doc), path_text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "jsonb_exists")) {
        if (args.len != 2) return Value{ .Null = {} };
        const doc = try eval.evalExpr(allocator, args[0].*, env);
        const key = try eval.evalExpr(allocator, args[1].*, env);
        const key_text = textLike(key) orelse return Value{ .Null = {} };
        const result = evaluator_functions.jsonb_exists(evalValueToHeapValue(doc), key_text) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "xml_is_well_formed")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        return heapValueToEvalValue(evaluator_functions.xml_is_well_formed(evalValueToHeapValue(arg)));
    }

    if (std.mem.eql(u8, function_name, "url_host")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const result = evaluator_functions.url_host(evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "url_scheme")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const result = evaluator_functions.url_scheme(evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "url_path")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const result = evaluator_functions.url_path(evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "url_query")) {
        if (args.len != 1) return Value{ .Null = {} };
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
        if (args.len != 1) return Value{ .Null = {} };
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
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const result = evaluator_functions.domain_labels(allocator, evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "domain_root")) {
        if (args.len != 1) return Value{ .Null = {} };
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
        if (args.len != 0) return Value{ .Null = {} };
        return heapValueToEvalValue(evaluator_functions.uuid_v4());
    }

    if (std.mem.eql(u8, function_name, "uuid_v7")) {
        if (args.len != 0) return Value{ .Null = {} };
        return heapValueToEvalValue(evaluator_functions.uuid_v7());
    }

    if (std.mem.eql(u8, function_name, "uuid_equal")) {
        if (args.len != 2) return Value{ .Null = {} };
        const lhs = try eval.evalExpr(allocator, args[0].*, env);
        const rhs = try eval.evalExpr(allocator, args[1].*, env);
        const result = evaluator_functions.uuid_equal(evalValueToHeapValue(lhs), evalValueToHeapValue(rhs)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "to_hex")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const result = evaluator_functions.to_hex(allocator, evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "from_hex")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const result = evaluator_functions.from_hex(allocator, evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "array_length")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const result = evaluator_functions.array_length(evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "array_contains")) {
        if (args.len != 2) return Value{ .Null = {} };
        const array_arg = try eval.evalExpr(allocator, args[0].*, env);
        const value_arg = try eval.evalExpr(allocator, args[1].*, env);
        const result = evaluator_functions.array_contains(evalValueToHeapValue(array_arg), evalValueToHeapValue(value_arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "bit_and")) {
        if (args.len != 2) return Value{ .Null = {} };
        const lhs = try eval.evalExpr(allocator, args[0].*, env);
        const rhs = try eval.evalExpr(allocator, args[1].*, env);
        const result = evaluator_functions.bit_and(allocator, evalValueToHeapValue(lhs), evalValueToHeapValue(rhs)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "bit_count")) {
        if (args.len != 1) return Value{ .Null = {} };
        const arg = try eval.evalExpr(allocator, args[0].*, env);
        const result = evaluator_functions.bit_count(evalValueToHeapValue(arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "range_contains")) {
        if (args.len != 2) return Value{ .Null = {} };
        const range_arg = try eval.evalExpr(allocator, args[0].*, env);
        const element_arg = try eval.evalExpr(allocator, args[1].*, env);
        const result = evaluator_functions.range_contains(evalValueToHeapValue(range_arg), evalValueToHeapValue(element_arg)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "range_overlaps")) {
        if (args.len != 2) return Value{ .Null = {} };
        const lhs = try eval.evalExpr(allocator, args[0].*, env);
        const rhs = try eval.evalExpr(allocator, args[1].*, env);
        const result = evaluator_functions.range_overlaps(evalValueToHeapValue(lhs), evalValueToHeapValue(rhs)) catch |err| return mapEvaluatorError(err);
        return heapValueToEvalValue(result);
    }

    if (std.mem.eql(u8, function_name, "domain_suffix_match")) {
        if (args.len != 2) return Value{ .Null = {} };
        const domain_arg = try eval.evalExpr(allocator, args[0].*, env);
        const suffix_arg = try eval.evalExpr(allocator, args[1].*, env);
        const suffix_text = textLike(suffix_arg) orelse return Value{ .Null = {} };
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
