const std = @import("std");
const ast = @import("gql/ast.zig");

pub const EvalError = error{
    TypeMismatch,
    Unsupported,
    RegexCompile,
};

pub const Value = union(enum) {
    Null,
    Int: i64,
    Bool: bool,
    Str: []const u8,
};

pub const Env = struct {
    // Simple linear env for tests/demos
    names: []const []const u8,
    values: []const Value,

    pub fn get(self: Env, name: []const u8) ?Value {
        var i: usize = 0;
        while (i < self.names.len) : (i += 1) if (std.mem.eql(u8, self.names[i], name)) return self.values[i];
        return null;
    }
};

fn isNull(v: Value) bool {
    return v == .Null;
}

fn truthy(v: Value) bool {
    return switch (v) {
        .Bool => |b| b,
        .Null => false,
        else => false,
    };
}

fn eqVals(a: Value, b: Value) bool {
    return switch (a) {
        .Null => b == .Null,
        .Int => |ai| b == .Int and ai == b.Int,
        .Bool => |ab| b == .Bool and ab == b.Bool,
        .Str => |as| b == .Str and std.mem.eql(u8, as, b.Str),
    };
}

fn cmpIntsOp(op: ast.BinOp, a: i64, b: i64) Value {
    return .{ .Bool = switch (op) {
        .Eq => a == b,
        .Ne => a != b,
        .Lt => a < b,
        .Le => a <= b,
        .Gt => a > b,
        .Ge => a >= b,
        else => false,
    } };
}

fn evalBinary(op: ast.BinOp, l: Value, r: Value) EvalError!Value {
    return switch (op) {
        .And => .{ .Bool = truthy(l) and truthy(r) },
        .Or => .{ .Bool = truthy(l) or truthy(r) },
        .Add => blk: {
            if (l == .Int and r == .Int) break :blk .{ .Int = l.Int + r.Int };
            return EvalError.TypeMismatch;
        },
        .Sub => blk2: {
            if (l == .Int and r == .Int) break :blk2 .{ .Int = l.Int - r.Int };
            return EvalError.TypeMismatch;
        },
        .Mul => blk3: {
            if (l == .Int and r == .Int) break :blk3 .{ .Int = l.Int * r.Int };
            return EvalError.TypeMismatch;
        },
        .Div => blk4: {
            if (l == .Int and r == .Int) break :blk4 .{ .Int = @divTrunc(l.Int, r.Int) };
            return EvalError.TypeMismatch;
        },
        .Eq, .Ne, .Lt, .Le, .Gt, .Ge => blk5: {
            if (l == .Int and r == .Int) break :blk5 cmpIntsOp(op, l.Int, r.Int);
            if (l == .Str and r == .Str) {
                const ord = std.mem.order(u8, l.Str, r.Str);
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
            // Comparing NULLs: NULL = NULL true; otherwise NULL compares false
            if (l == .Null or r == .Null) {
                if (op == .Eq) return .{ .Bool = eqVals(l, r) };
                if (op == .Ne) return .{ .Bool = !eqVals(l, r) };
                return .{ .Bool = false };
            }
            return EvalError.TypeMismatch;
        },
    };
}

fn expectString(v: Value) EvalError![]const u8 {
    return switch (v) {
        .Str => |s| s,
        .Null => return EvalError.TypeMismatch,
        else => return EvalError.TypeMismatch,
    };
}

fn expectInt(v: Value) EvalError!i64 {
    return switch (v) {
        .Int => |n| n,
        else => return EvalError.TypeMismatch,
    };
}

fn evalStartsWith(val: Value, pref: Value) EvalError!Value {
    if (isNull(val) or isNull(pref)) return Value{ .Null = {} };
    const s = try expectString(val);
    const p = try expectString(pref);
    if (p.len == 0) return .{ .Bool = true };
    return .{ .Bool = std.mem.startsWith(u8, s, p) };
}

fn evalEndsWith(val: Value, suf: Value) EvalError!Value {
    if (isNull(val) or isNull(suf)) return Value{ .Null = {} };
    const s = try expectString(val);
    const p = try expectString(suf);
    if (p.len == 0) return .{ .Bool = true };
    return .{ .Bool = std.mem.endsWith(u8, s, p) };
}

fn evalContains(val: Value, needle: Value) EvalError!Value {
    if (isNull(val) or isNull(needle)) return Value{ .Null = {} };
    const s = try expectString(val);
    const n = try expectString(needle);
    if (n.len == 0) return .{ .Bool = true };
    return .{ .Bool = std.mem.indexOf(u8, s, n) != null };
}

fn matchSimplePattern(s: []const u8, p_in: []const u8) bool {
    // Supports: anchors ^ and $, and wildcard ".*" between literal segments.
    if (p_in.len == 0) return s.len == 0; // empty pattern matches empty string only
    var p = p_in;
    var anchor_start = false;
    var anchor_end = false;
    if (p.len > 0 and p[0] == '^') {
        anchor_start = true;
        p = p[1..];
    }
    if (p.len > 0 and p[p.len - 1] == '$') {
        anchor_end = true;
        p = p[0 .. p.len - 1];
    }
    // Trivial wildcard-only pattern: ".*" or "" after removing anchors
    if (p.len == 0) return !anchor_start or !anchor_end or s.len == 0; // "^$" matches empty only
    if (p.len == 2 and p[0] == '.' and p[1] == '*') return true;

    var pat_i: usize = 0;
    var s_pos: usize = 0;
    var first_seg = true;
    while (pat_i < p.len) {
        // find next wildcard position
        var k = pat_i;
        while (k + 1 < p.len and !(p[k] == '.' and p[k + 1] == '*')) : (k += 1) {}
        const seg = p[pat_i..k];
        if (seg.len > 0) {
            if (first_seg and anchor_start) {
                if (!(s_pos == 0 and std.mem.startsWith(u8, s, seg))) return false;
                s_pos = seg.len;
            } else {
                const idx = std.mem.indexOfPos(u8, s, s_pos, seg) orelse return false;
                s_pos = idx + seg.len;
            }
        }
        first_seg = false;
        if (k + 1 < p.len) {
            // skip wildcard
            pat_i = k + 2;
        } else {
            // last segment handled; break
            pat_i = p.len;
        }
    }
    if (anchor_end) {
        // Ensure the last literal segment ends at end of s when pattern does not end with wildcard
        if (!(p.len >= 2 and p[p.len - 2] == '.' and p[p.len - 1] == '*')) {
            // Find last segment
            var j: usize = p.len;
            while (j > 0 and !(j >= 2 and p[j - 2] == '.' and p[j - 1] == '*')) : (j -= 1) {}
            const last_seg = p[j..];
            if (last_seg.len == 0) return true;
            if (!std.mem.endsWith(u8, s, last_seg)) return false;
            const start = s.len - last_seg.len;
            if (start < s_pos) return false;
        }
    }
    return true;
}

fn evalRegex(val: Value, pat: Value, ally: std.mem.Allocator) EvalError!Value {
    if (isNull(val) or isNull(pat)) return Value{ .Null = {} };
    const s = try expectString(val);
    const p = try expectString(pat);
    _ = ally; // not used
    return .{ .Bool = matchSimplePattern(s, p) };
}

pub fn evalExpr(ally: std.mem.Allocator, e: ast.Expr, env: Env) EvalError!Value {
    return switch (e) {
        .Null => Value{ .Null = {} },
        .Int => |n| .{ .Int = n },
        .Bool => |b| .{ .Bool = b },
        .String => |s| .{ .Str = s },
        .Ident => |name| env.get(name) orelse Value{ .Null = {} },
        .Unary => |u| blk: {
            const v = try evalExpr(ally, u.expr.*, env);
            switch (u.op) {
                .Not => break :blk .{ .Bool = !truthy(v) },
                .Neg => break :blk .{ .Int = -(try expectInt(v)) },
            }
        },
        .Binary => |b| blk2: {
            const l = try evalExpr(ally, b.left.*, env);
            const r = try evalExpr(ally, b.right.*, env);
            break :blk2 try evalBinary(b.op, l, r);
        },
        .StartsWith => |sp| blk3: {
            const v = try evalExpr(ally, sp.value.*, env);
            const p = try evalExpr(ally, sp.prefix.*, env);
            break :blk3 try evalStartsWith(v, p);
        },
        .EndsWith => |ep| blk4: {
            const v = try evalExpr(ally, ep.value.*, env);
            const p = try evalExpr(ally, ep.suffix.*, env);
            break :blk4 try evalEndsWith(v, p);
        },
        .Contains => |cp| blk5: {
            const v = try evalExpr(ally, cp.value.*, env);
            const n = try evalExpr(ally, cp.needle.*, env);
            break :blk5 try evalContains(v, n);
        },
        .RegexMatch => |rm| {
            const v = try evalExpr(ally, rm.value.*, env);
            const p = try evalExpr(ally, rm.pattern.*, env);
            return try evalRegex(v, p, ally);
        },
        .Case => |c| {
            // Simple CASE: operand present => compare equality to WHEN exprs
            if (c.operand) |op_ptr| {
                const opv = try evalExpr(ally, op_ptr.*, env);
                for (c.whens) |w| {
                    const whenv = try evalExpr(ally, w.when.*, env);
                    if (eqVals(opv, whenv)) {
                        return evalExpr(ally, w.then_expr.*, env);
                    }
                }
            } else {
                // Searched CASE: evaluate WHEN as boolean
                for (c.whens) |w| {
                    const cond = try evalExpr(ally, w.when.*, env);
                    if (truthy(cond)) return evalExpr(ally, w.then_expr.*, env);
                }
            }
            if (c.else_expr) |ep| return evalExpr(ally, ep.*, env);
            return Value{ .Null = {} };
        },
        // Unimplemented in evaluator: treat these as null for now
        else => Value{ .Null = {} },
    };
}

test "eval: CASE searched produces expected values" {
    const ally = std.testing.allocator;
    const env = Env{ .names = &.{"a"}, .values = &.{Value{ .Int = 1 }} };
    var a_expr = ast.Expr{ .Ident = "a" };
    var zero = ast.Expr{ .Int = 0 };
    var pred = ast.Expr{ .Binary = .{ .op = .Gt, .left = &a_expr, .right = &zero } };
    var p = ast.Expr{ .String = "p" };
    var n = ast.Expr{ .String = "n" };
    var whs: [1]ast.CaseWhen = .{.{ .when = &pred, .then_expr = &p }};
    const cse = ast.Expr{ .Case = .{ .operand = null, .whens = whs[0..], .else_expr = &n } };
    const out = try evalExpr(ally, cse, env);
    try std.testing.expect(out == .Str and std.mem.eql(u8, out.Str, "p"));
}

test "eval: string predicates and regex basic" {
    const ally = std.testing.allocator;
    const env = Env{ .names = &.{"s"}, .values = &.{Value{ .Str = "Alice" }} };
    var s = ast.Expr{ .Ident = "s" };
    var al = ast.Expr{ .String = "Al" };
    var z = ast.Expr{ .String = "Z" };
    var ice = ast.Expr{ .String = "ice" };
    var re_pat = ast.Expr{ .String = "^A.*" };
    const sw = ast.Expr{ .StartsWith = .{ .value = &s, .prefix = &al } };
    const ew = ast.Expr{ .EndsWith = .{ .value = &s, .suffix = &z } };
    const ct = ast.Expr{ .Contains = .{ .value = &s, .needle = &ice } };
    const rx = ast.Expr{ .RegexMatch = .{ .value = &s, .pattern = &re_pat } };
    const v1 = try evalExpr(ally, sw, env);
    const v2 = try evalExpr(ally, ew, env);
    const v3 = try evalExpr(ally, ct, env);
    const v4 = try evalExpr(ally, rx, env);
    try std.testing.expect(v1 == .Bool and v1.Bool == true);
    try std.testing.expect(v2 == .Bool and v2.Bool == false);
    try std.testing.expect(v3 == .Bool and v3.Bool == true);
    try std.testing.expect(v4 == .Bool and v4.Bool == true);
}

test "eval: empty and NULL edge cases for string predicates" {
    const ally = std.testing.allocator;
    const env = Env{ .names = &.{}, .values = &.{} };
    var s = ast.Expr{ .String = "" };
    var pref = ast.Expr{ .String = "" };
    const sw = ast.Expr{ .StartsWith = .{ .value = &s, .prefix = &pref } };
    const out1 = try evalExpr(ally, sw, env);
    try std.testing.expect(out1 == .Bool and out1.Bool == true);
    // NULL arg yields NULL
    const null_v = Value{ .Null = {} };
    const e2 = try evalStartsWith(null_v, .{ .Str = "x" });
    try std.testing.expect(e2 == .Null);
}
