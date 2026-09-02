// CANARY: REQ=REQ-EVAL-REFACTOR-009; FEATURE="EvalExpr Refactoring"; ASPECT=QuantifierCallHandlers; STATUS=TESTED; TEST=src/eval/quantifier_call_handlers.zig; OWNER=eval; UPDATED=2026-06-11
// GAP-0537: dedicated handler module for the quantified list predicates
// `all()` / `any()` and the fixed-length `char(str, N)` constructor,
// extracted from the eval.zig fallback `.Call` branch (follows the
// src/eval/call_handlers.zig module pattern).
//
// Contents (all previously inline in eval.zig):
// - evalQuantifierFunction() - all(x IN list WHERE cond) / any(x IN list
//   WHERE cond) list-comprehension forms, plus the all(list) / any(list)
//   truthiness fallbacks
// - evalCharFunction()       - char(str, N) fixed-length char with length
//   validation (CharLengthExceeded) and space padding
//
// Every handler returns `null` when the function name is not its concern so
// the eval.zig fallback chain can keep dispatching.

const std = @import("std");
const ast = @import("../gql/ast.zig");
const value_types = @import("../value_types.zig");

pub const Value = value_types.Value;
pub const EvalError = value_types.EvalError;
pub const Env = value_types.Env;

// Recursive evaluation lives in eval.zig
const eval = @import("../eval.zig");
const evalExpr = eval.evalExpr;

// CANARY: REQ=REQ-FN-DISPATCH-PARITY; FEATURE="ListComprehension"; ASPECT=NoneAndSingleQuantifiers; STATUS=TESTED; TEST=tests/test_fn_dispatch_parity.zig; OWNER=eval; UPDATED=2026-08-25
/// The four advertised list quantifiers. `none` and `single` are advertised by
/// SHOW FUNCTIONS and src/gql/language_metadata.zig alongside `all`/`any`;
/// before FN-DISPATCH-PARITY neither the grammar (src/gql/parser.zig) nor this
/// handler knew them, so the documented spelling was a syntax error.
const Quantifier = enum {
    all,
    any,
    none,
    single,

    fn fromName(function_name: []const u8) ?Quantifier {
        if (std.ascii.eqlIgnoreCase(function_name, "all")) return .all;
        if (std.ascii.eqlIgnoreCase(function_name, "any")) return .any;
        if (std.ascii.eqlIgnoreCase(function_name, "none")) return .none;
        if (std.ascii.eqlIgnoreCase(function_name, "single")) return .single;
        return null;
    }

    /// The answer when NO element matched the predicate (or the list was empty
    /// / not a list): `all` and `none` are vacuously true, `any` and `single`
    /// need at least one match.
    fn vacuous(self: Quantifier) bool {
        return switch (self) {
            .all, .none => true,
            .any, .single => false,
        };
    }
};

// CANARY: REQ=REQ-GQL-089; FEATURE="ListComprehension"; ASPECT=Evaluation; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=eval; UPDATED=2026-08-25
/// Handle all/any/none/single(x IN list WHERE condition).
/// all():    true only if every element matches the condition;
/// any():    true if at least one element matches;
/// none():   true if no element matches;
/// single(): true if exactly one element matches.
/// Fallback forms all(list) / any(list) / none(list) / single(list) test
/// element truthiness.
/// Returns null when the function name is not one of the four.
pub fn evalQuantifierFunction(
    allocator: std.mem.Allocator,
    function_name: []const u8,
    args: []*ast.Expr,
    env: Env,
) EvalError!?Value {
    const quantifier = Quantifier.fromName(function_name) orelse return null;

    if (args.len != 1) return @as(?Value, .{ .Null = {} });
    const arg = args[0].*;

    if (arg == .ListComprehension) {
        const comp = arg.ListComprehension;
        const source_val = try evalExpr(allocator, comp.source.*, env);

        const list = switch (source_val) {
            .List => |l| l,
            // Empty or non-list: nothing matched.
            else => return @as(?Value, .{ .Bool = quantifier.vacuous() }),
        };

        // `x IN list` with no WHERE keeps its pre-existing answer: there is no
        // predicate to satisfy, so nothing matched.
        const filter = comp.filter orelse
            return @as(?Value, .{ .Bool = quantifier.vacuous() });

        // `single` cannot short-circuit on its first match — it has to see a
        // possible second one — so the loop counts matches for every
        // quantifier and the early exits are per-quantifier.
        var matches: usize = 0;
        for (list) |item| {
            // Create new environment with variable binding
            const new_env = try env.withBinding(allocator, comp.variable, item);
            // OWNERSHIP (REQ-EVAL-ENV-OWNERSHIP-004): free the per-iteration
            // binding arrays `withBinding` allocates. `defer` fires on every
            // exit path, including the early `return`s below for the various
            // quantifiers.
            defer {
                allocator.free(new_env.names);
                allocator.free(new_env.values);
            }

            const filter_result = try evalExpr(allocator, filter.*, new_env);
            const item_matches = switch (filter_result) {
                .Bool => |b| b,
                .Null => false,
                else => false,
            };
            if (!item_matches) {
                // `all` fails on the first element that does not match.
                if (quantifier == .all) return @as(?Value, .{ .Bool = false });
                continue;
            }
            matches += 1;

            switch (quantifier) {
                .any => return @as(?Value, .{ .Bool = true }),
                .none => return @as(?Value, .{ .Bool = false }),
                .single => if (matches > 1) return @as(?Value, .{ .Bool = false }),
                .all => {},
            }
        }

        return @as(?Value, .{
            .Bool = switch (quantifier) {
                // Every element matched (a failing element returned false above).
                .all => true,
                // No element matched.
                .any => false,
                .none => true,
                .single => matches == 1,
            },
        });
    }

    // Fallback: all(list) / any(list) / none(list) / single(list) - element
    // truthiness.
    const list_val = try evalExpr(allocator, args[0].*, env);
    const list = switch (list_val) {
        .List => |l| l,
        else => return @as(?Value, .{ .Bool = false }),
    };

    var truthy: usize = 0;
    for (list) |item| {
        const is_truthy = switch (item) {
            .Bool => |b| b,
            .Null => false,
            else => true,
        };
        if (is_truthy) truthy += 1;
    }
    return @as(?Value, .{ .Bool = switch (quantifier) {
        .all => truthy == list.len,
        .any => truthy > 0,
        .none => truthy == 0,
        .single => truthy == 1,
    } });
}

/// Handle char(str, N) - converts string to fixed-length char with length
/// validation: errors with CharLengthExceeded when str is longer than N,
/// pads with spaces when shorter. Returns a FRESH allocation in all
/// .Str-producing paths. Returns null when the function name is not char.
pub fn evalCharFunction(
    allocator: std.mem.Allocator,
    function_name: []const u8,
    args: []*ast.Expr,
    env: Env,
) EvalError!?Value {
    if (!std.ascii.eqlIgnoreCase(function_name, "char")) return null;

    if (args.len != 2) return @as(?Value, .{ .Null = {} });
    const str_arg = try evalExpr(allocator, args[0].*, env);
    const len_arg = try evalExpr(allocator, args[1].*, env);

    const str = switch (str_arg) {
        .Str => |s| s,
        else => return @as(?Value, .{ .Null = {} }),
    };

    const max_len = switch (len_arg) {
        .Int => |i| if (i > 0) @as(usize, @intCast(i)) else return @as(?Value, .{ .Null = {} }),
        else => return @as(?Value, .{ .Null = {} }),
    };

    // Validate length constraint - throw error if exceeded
    if (str.len > max_len) {
        return EvalError.CharLengthExceeded;
    }

    // Pad with spaces if shorter than max_len
    if (str.len < max_len) {
        var padded = try allocator.alloc(u8, max_len);
        @memcpy(padded[0..str.len], str);
        @memset(padded[str.len..], ' ');
        return @as(?Value, .{ .Str = padded });
    }
    // Exact length match
    return @as(?Value, .{ .Str = try allocator.dupe(u8, str) });
}

// ---------------------------------------------------------------------------
// Unit tests (GAP-0537)
// ---------------------------------------------------------------------------

test "quantifier_call_handlers: non-matching names are not handled" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };
    try std.testing.expect((try evalQuantifierFunction(allocator, "upper", &.{}, env)) == null);
    try std.testing.expect((try evalCharFunction(allocator, "upper", &.{}, env)) == null);
}

test "quantifier_call_handlers: all(list) truthiness fallback" {
    // GAP-0888 review follow-up: this test had never actually run (the file
    // was not rooted by any step) and bit-rotted in two ways:
    //  - the parser emits list literals as `.ArrayLit`, not the (parser-dead)
    //    `.List` AST variant — evalExpr only evaluates `.ArrayLit`;
    //  - evaluating the list allocates a temporary the handler does not free
    //    (its documented contract is the per-request arena, GAP-0755), so
    //    evaluate under an arena here.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };

    var t = ast.Expr{ .Bool = true };
    var f = ast.Expr{ .Bool = false };
    var all_true_elems = [_]*ast.Expr{ &t, &t };
    var mixed_elems = [_]*ast.Expr{ &t, &f };

    var all_true_list = ast.Expr{ .ArrayLit = all_true_elems[0..] };
    var args1 = [_]*ast.Expr{&all_true_list};
    const r1 = try evalQuantifierFunction(allocator, "all", args1[0..], env);
    try std.testing.expect(r1 != null and r1.? == .Bool and r1.?.Bool);

    var mixed_list = ast.Expr{ .ArrayLit = mixed_elems[0..] };
    var args2 = [_]*ast.Expr{&mixed_list};
    const r2 = try evalQuantifierFunction(allocator, "ALL", args2[0..], env);
    try std.testing.expect(r2 != null and r2.? == .Bool and !r2.?.Bool);
}

test "quantifier_call_handlers: any(list) truthiness fallback" {
    // GAP-0888 review follow-up: same rebuild as the all(list) test above
    // (.ArrayLit + arena).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };

    var t = ast.Expr{ .Bool = true };
    var f = ast.Expr{ .Bool = false };
    var mixed_elems = [_]*ast.Expr{ &f, &t };
    var all_false_elems = [_]*ast.Expr{ &f, &f };

    var mixed_list = ast.Expr{ .ArrayLit = mixed_elems[0..] };
    var args1 = [_]*ast.Expr{&mixed_list};
    const r1 = try evalQuantifierFunction(allocator, "any", args1[0..], env);
    try std.testing.expect(r1 != null and r1.? == .Bool and r1.?.Bool);

    var all_false_list = ast.Expr{ .ArrayLit = all_false_elems[0..] };
    var args2 = [_]*ast.Expr{&all_false_list};
    const r2 = try evalQuantifierFunction(allocator, "ANY", args2[0..], env);
    try std.testing.expect(r2 != null and r2.? == .Bool and !r2.?.Bool);
}

test "quantifier_call_handlers: char pads, dupes, and validates length" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };

    var s = ast.Expr{ .String = "ab" };
    var n4 = ast.Expr{ .Int = 4 };
    var args_pad = [_]*ast.Expr{ &s, &n4 };
    const padded = try evalCharFunction(allocator, "char", args_pad[0..], env);
    try std.testing.expect(padded != null and padded.? == .Str);
    defer allocator.free(padded.?.Str);
    try std.testing.expectEqualStrings("ab  ", padded.?.Str);

    var n2 = ast.Expr{ .Int = 2 };
    var args_exact = [_]*ast.Expr{ &s, &n2 };
    const exact = try evalCharFunction(allocator, "CHAR", args_exact[0..], env);
    try std.testing.expect(exact != null and exact.? == .Str);
    defer allocator.free(exact.?.Str);
    try std.testing.expectEqualStrings("ab", exact.?.Str);

    var n1 = ast.Expr{ .Int = 1 };
    var args_long = [_]*ast.Expr{ &s, &n1 };
    try std.testing.expectError(
        EvalError.CharLengthExceeded,
        evalCharFunction(allocator, "char", args_long[0..], env),
    );
}
