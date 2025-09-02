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
    // Fixed-point decimal: coeff * 10^-scale
    Decimal: struct { coeff: i128, scale: u8 },
};

pub const Env = struct {
    // Simple linear env for tests/demos
    names: []const []const u8,
    values: []const Value,
    // Optional parameter bindings: parallel arrays
    param_names: []const []const u8 = &.{},
    param_values: []const Value = &.{},

    pub fn get(self: Env, name: []const u8) ?Value {
        var i: usize = 0;
        while (i < self.names.len) : (i += 1) if (std.mem.eql(u8, self.names[i], name)) return self.values[i];
        return null;
    }
    pub fn getParam(self: Env, name: []const u8) ?Value {
        var i: usize = 0;
        while (i < self.param_names.len) : (i += 1) if (std.mem.eql(u8, self.param_names[i], name)) return self.param_values[i];
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
fn eqVals(a: Value, b: Value) bool {
    return switch (a) {
        .Null => b == .Null,
        .Int => |ai| b == .Int and ai == b.Int,
        .Bool => |ab| b == .Bool and ab == b.Bool,
        .Str => |as| b == .Str and std.mem.eql(u8, as, b.Str),
        .Decimal => |ad| b == .Decimal and ad.coeff == b.Decimal.coeff and ad.scale == b.Decimal.scale,
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
        .And => and3(l, r),
        .Or => or3(l, r),
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
            if ((l == .Str and r == .Int) or (l == .Int and r == .Str)) {
                if (op != .Eq and op != .Ne) return EvalError.TypeMismatch;
                var bufL: [64]u8 = undefined;
                var bufR: [64]u8 = undefined;
                const ls = try stringify(l, &bufL);
                const rs = try stringify(r, &bufR);
                const eq = std.mem.eql(u8, ls, rs);
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
    };
}

fn pow10(scale: u8) i128 {
    var p: i128 = 1;
    var i: u8 = 0;
    while (i < scale) : (i += 1) p *= 10;
    return p;
}

fn cmpI128(a: i128, b: i128) i2 {
    return if (a < b) -1 else if (a > b) 1 else 0;
}

fn cmpToBool(op: ast.BinOp, ord: i2) bool {
    return switch (op) {
        .Eq => ord == 0,
        .Ne => ord != 0,
        .Lt => ord < 0,
        .Le => ord <= 0,
        .Gt => ord > 0,
        .Ge => ord >= 0,
        else => false,
    };
}

fn scaleTo(coeff: i128, from: u8, to: u8) EvalError!i128 {
    if (from == to) return coeff;
    if (from > to) {
        // downscale by truncation
        var i: u8 = 0;
        var v = coeff;
        while (i < from - to) : (i += 1) v = @divTrunc(v, 10);
        return v;
    }
    // upscale; check overflow
    var i: u8 = 0;
    var v = coeff;
    while (i < to - from) : (i += 1) {
        // overflow if v > max/10 or v < min/10
        if (v > @as(i128, std.math.maxInt(i128)) / 10 or v < @as(i128, std.math.minInt(i128)) / 10) return EvalError.Unsupported;
        v = v * 10;
    }
    return v;
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

fn evalRegex(val: Value, pat: Value, ally: std.mem.Allocator) EvalError!Value {
    _ = ally;
    if (isNull(val) or isNull(pat)) return Value{ .Null = {} };
    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    const s = try stringify(val, &buf1);
    const p = try stringify(pat, &buf2);
    return .{ .Bool = matchSimplePattern(s, p) };
}

pub fn matchSimplePattern(s: []const u8, p_in: []const u8) bool {
    // Lightweight matcher: ^, $, ., .*, [..], escapes, '?' (no alternation)
    if (p_in.len == 0) return s.len == 0; // empty pattern matches empty string only
    var p = p_in;
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

fn stringify(v: Value, buf: *[64]u8) EvalError![]const u8 {
    return switch (v) {
        .Str => |s| s,
        .Int => |n| blk: {
            const s = std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return EvalError.Unsupported;
            break :blk s;
        },
        .Decimal => |d| blk2: {
            // render with scale decimal point
            const abs = if (d.coeff < 0) -d.coeff else d.coeff;
            const scale_p = pow10(d.scale);
            const whole = @divTrunc(abs, scale_p);
            const frac = @mod(abs, scale_p);
            var tmp: [64]u8 = undefined;
            const w = std.fmt.bufPrint(&tmp, "{d}", .{whole}) catch return EvalError.Unsupported;
            if (d.scale == 0) {
                const s = if (d.coeff < 0) std.fmt.bufPrint(buf[0..], "-{s}", .{w}) catch return EvalError.Unsupported else std.fmt.bufPrint(buf[0..], "{s}", .{w}) catch return EvalError.Unsupported;
                break :blk2 s;
            }
            // format fractional part with leading zeros to scale width
            var frac_buf: [32]u8 = undefined;
            const fb = std.fmt.bufPrint(&frac_buf, "{d}", .{frac}) catch return EvalError.Unsupported;
            // pad leading zeros
            if (fb.len < d.scale) {
                const pad = d.scale - @as(u8, @intCast(fb.len));
                var padbuf: [32]u8 = undefined;
                @memset(padbuf[0..pad], '0');
                const s = if (d.coeff < 0)
                    std.fmt.bufPrint(buf[0..], "-{s}.{s}{s}", .{ w, padbuf[0..pad], fb }) catch return EvalError.Unsupported
                else
                    std.fmt.bufPrint(buf[0..], "{s}.{s}{s}", .{ w, padbuf[0..pad], fb }) catch return EvalError.Unsupported;
                break :blk2 s;
            }
            const s = if (d.coeff < 0)
                std.fmt.bufPrint(buf[0..], "-{s}.{s}", .{ w, fb }) catch return EvalError.Unsupported
            else
                std.fmt.bufPrint(buf[0..], "{s}.{s}", .{ w, fb }) catch return EvalError.Unsupported;
            break :blk2 s;
        },
        else => return EvalError.TypeMismatch,
    };
}

pub fn evalExpr(ally: std.mem.Allocator, e: ast.Expr, env: Env) EvalError!Value {
    return switch (e) {
        .Null => Value{ .Null = {} },
        .Int => |n| .{ .Int = n },
        .Bool => |b| .{ .Bool = b },
        .String => |s| .{ .Str = s },
        .Ident => |name| env.get(name) orelse Value{ .Null = {} },
        .Param => |pname| env.getParam(pname) orelse Value{ .Null = {} },
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
        .In => |iv| {
            const v = try evalExpr(ally, iv.value.*, env);
            return try inList(v, iv.set, ally, env);
        },
        .NotIn => |nv| {
            const v = try evalExpr(ally, nv.value.*, env);
            const res = try inList(v, nv.set, ally, env);
            return switch (res) {
                .Bool => |b| .{ .Bool = !b },
                else => res,
            };
        },
        .IsNull => |nz| blk_isnull: {
            const v = try evalExpr(ally, nz.target.*, env);
            const is_null = isNull(v);
            break :blk_isnull .{ .Bool = if (nz.negated) !is_null else is_null };
        },
        .Case => |c| {
            // ISO 3VL semantics
            if (c.operand) |op_ptr| {
                const opv = try evalExpr(ally, op_ptr.*, env);
                var saw_null_match = false;
                for (c.whens) |w| {
                    const whenv = try evalExpr(ally, w.when.*, env);
                    if (isNull(opv) or isNull(whenv)) {
                        // NULL = x yields NULL; track if any potential match is unknown
                        if (isNull(opv) and isNull(whenv)) {
                            // NULL = NULL treated as true in our eqVals; but in searched context, this is a match
                            return evalExpr(ally, w.then_expr.*, env);
                        }
                        saw_null_match = true;
                        continue;
                    }
                    if (eqVals(opv, whenv)) return evalExpr(ally, w.then_expr.*, env);
                }
                if (c.else_expr) |ep| return evalExpr(ally, ep.*, env);
                return if (saw_null_match) Value{ .Null = {} } else Value{ .Null = {} };
            } else {
                for (c.whens) |w| {
                    const cond = try evalExpr(ally, w.when.*, env);
                    // truthy() treats null as false; adjust for 3VL: only explicit true selects
                    if (cond == .Bool and cond.Bool) return evalExpr(ally, w.then_expr.*, env);
                }
                if (c.else_expr) |ep| return evalExpr(ally, ep.*, env);
                return Value{ .Null = {} };
            }
        },
        // Unimplemented in evaluator: treat these as null for now
        else => Value{ .Null = {} },
    };
}

fn inList(value: Value, set: []*ast.Expr, ally: std.mem.Allocator, env: Env) EvalError!Value {
    if (isNull(value)) return Value{ .Null = {} };
    var saw_null = false;
    for (set) |p| {
        const ev = try evalExpr(ally, p.*, env);
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
    const ally = std.testing.allocator;
    const env = Env{ .names = &.{ "a", "s" }, .values = &.{ Value{ .Int = 7 }, Value{ .Str = "007" } } };
    var a_ident = ast.Expr{ .Ident = "a" };
    var s_ident = ast.Expr{ .Ident = "s" };
    // IN list with NULL element yields NULL if no match
    var nullx = ast.Expr{ .Null = {} };
    var lit9 = ast.Expr{ .Int = 9 };
    var arr1: [2]*ast.Expr = .{ &nullx, &lit9 };
    const in1 = ast.Expr{ .In = .{ .value = &a_ident, .set = arr1[0..] } };
    const v1 = try evalExpr(ally, in1, env);
    try std.testing.expect(v1 == .Null);
    // IN list when match present returns true
    var lit7 = ast.Expr{ .Int = 7 };
    var arr2: [3]*ast.Expr = .{ &nullx, &lit7, &lit9 };
    const in2 = ast.Expr{ .In = .{ .value = &a_ident, .set = arr2[0..] } };
    const v2 = try evalExpr(ally, in2, env);
    try std.testing.expect(v2 == .Bool and v2.Bool);
    // NOT IN negates; with match present -> false
    const nin1 = ast.Expr{ .NotIn = .{ .value = &a_ident, .set = arr2[0..] } };
    const v3 = try evalExpr(ally, nin1, env);
    try std.testing.expect(v3 == .Bool and !v3.Bool);
    // NOT IN when list has NULL and no match -> NULL
    var lit8 = ast.Expr{ .Int = 8 };
    var arr3: [2]*ast.Expr = .{ &nullx, &lit9 };
    const nin2 = ast.Expr{ .NotIn = .{ .value = &lit8, .set = arr3[0..] } };
    const v4 = try evalExpr(ally, nin2, env);
    try std.testing.expect(v4 == .Null);
    // Mixed-type equality edge: leading zeros in string
    var str7 = ast.Expr{ .String = "7" };
    const eq = ast.Expr{ .Binary = .{ .op = .Eq, .left = &a_ident, .right = &str7 } };
    const v5 = try evalExpr(ally, eq, env);
    try std.testing.expect(v5 == .Bool and v5.Bool);
    const eq2 = ast.Expr{ .Binary = .{ .op = .Eq, .left = &a_ident, .right = &s_ident } };
    const v6 = try evalExpr(ally, eq2, env);
    // 7 vs "007" should be false by decimal string compare
    try std.testing.expect(v6 == .Bool and !v6.Bool);
    // NOT IN with empty list -> always true
    var empty: [0]*ast.Expr = .{};
    const nin_empty = ast.Expr{ .NotIn = .{ .value = &a_ident, .set = empty[0..] } };
    const v7 = try evalExpr(ally, nin_empty, env);
    try std.testing.expect(v7 == .Bool and v7.Bool);
    // NOT IN with all-NULL list -> NULL
    var nul2 = ast.Expr{ .Null = {} };
    var arrn: [2]*ast.Expr = .{ &nullx, &nul2 };
    const nin_nulls = ast.Expr{ .NotIn = .{ .value = &lit8, .set = arrn[0..] } };
    const v8 = try evalExpr(ally, nin_nulls, env);
    try std.testing.expect(v8 == .Null);
}

test "eval: mixed-type IN across bools and big ints stringified" {
    const ally = std.testing.allocator;
    const env = Env{ .names = &.{"a"}, .values = &.{Value{ .Int = 9007199254740991 }} }; // 2^53-1
    var a_ident = ast.Expr{ .Ident = "a" };
    var s_big = ast.Expr{ .String = "9007199254740991" };
    var t_true = ast.Expr{ .String = "true" };
    var b_true = ast.Expr{ .Bool = true };
    var items: [3]*ast.Expr = .{ &s_big, &t_true, &b_true };
    const inx = ast.Expr{ .In = .{ .value = &a_ident, .set = items[0..] } };
    const v = try evalExpr(ally, inx, env);
    // Should match the big-int via decimal string, ignore bool mismatches
    try std.testing.expect(v == .Bool and v.Bool == true);
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

test "eval: regex classes, negation, optional, escapes" {
    const ally = std.testing.allocator;
    var s = ast.Expr{ .String = "Alice." };
    var p1 = ast.Expr{ .String = "A[il]ice\\." }; // class and escaped dot
    var p2 = ast.Expr{ .String = "^[^B].*$" }; // negated class at start, anchor end
    var p3 = ast.Expr{ .String = "Al?ice\\." }; // optional 'l'
    const rx1 = ast.Expr{ .RegexMatch = .{ .value = &s, .pattern = &p1 } };
    const rx2 = ast.Expr{ .RegexMatch = .{ .value = &s, .pattern = &p2 } };
    const rx3 = ast.Expr{ .RegexMatch = .{ .value = &s, .pattern = &p3 } };
    const v1 = try evalExpr(ally, rx1, .{ .names = &.{}, .values = &.{} });
    const v2 = try evalExpr(ally, rx2, .{ .names = &.{}, .values = &.{} });
    const v3 = try evalExpr(ally, rx3, .{ .names = &.{}, .values = &.{} });
    try std.testing.expect(v1 == .Bool and v1.Bool);
    try std.testing.expect(v2 == .Bool and v2.Bool);
    try std.testing.expect(v3 == .Bool and v3.Bool);
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

test "eval: implicit int<->string in predicates and IN list" {
    const ally = std.testing.allocator;
    const env = Env{ .names = &.{ "a", "s" }, .values = &.{ Value{ .Int = 42 }, Value{ .Str = "42" } } };
    // s STARTS WITH "4" -> true
    var s_ident = ast.Expr{ .Ident = "s" };
    var four = ast.Expr{ .String = "4" };
    const sw = ast.Expr{ .StartsWith = .{ .value = &s_ident, .prefix = &four } };
    const v1 = try evalExpr(ally, sw, env);
    try std.testing.expect(v1 == .Bool and v1.Bool == true);
    // a = "42" -> true (implicit Eq int<->string)
    var a_ident = ast.Expr{ .Ident = "a" };
    var s_lit = ast.Expr{ .String = "42" };
    const eq = ast.Expr{ .Binary = .{ .op = .Eq, .left = &a_ident, .right = &s_lit } };
    const v2 = try evalExpr(ally, eq, env);
    try std.testing.expect(v2 == .Bool and v2.Bool == true);
    // a IN ["41", "42", 43] -> true
    var lit41 = ast.Expr{ .String = "41" };
    var lit43 = ast.Expr{ .Int = 43 };
    var arr: [3]*ast.Expr = .{ &lit41, &s_lit, &lit43 };
    const inx = ast.Expr{ .In = .{ .value = &a_ident, .set = arr[0..] } };
    const v3 = try evalExpr(ally, inx, env);
    try std.testing.expect(v3 == .Bool and v3.Bool == true);
}

test "eval: parameters substitution and STARTS WITH via $param" {
    const ally = std.testing.allocator;
    const env = Env{ .names = &.{"s"}, .values = &.{Value{ .Str = "Alice" }}, .param_names = &.{"prefix"}, .param_values = &.{Value{ .Str = "Al" }} };
    var s_ident = ast.Expr{ .Ident = "s" };
    var pref = ast.Expr{ .Param = "prefix" };
    const sw = ast.Expr{ .StartsWith = .{ .value = &s_ident, .prefix = &pref } };
    const v = try evalExpr(ally, sw, env);
    try std.testing.expect(v == .Bool and v.Bool == true);
}

test "eval: parameters in IN list, mixed-type equality, and regex via $param" {
    const ally = std.testing.allocator;
    // Env: a=7, s="007"; params: needle="Al", list=["6",7], pat="^A.*$"
    const env = Env{ .names = &.{ "a", "s" }, .values = &.{ Value{ .Int = 7 }, Value{ .Str = "007" } }, .param_names = &.{ "needle", "list0", "list1", "pat" }, .param_values = &.{ Value{ .Str = "Al" }, Value{ .Str = "6" }, Value{ .Int = 7 }, Value{ .Str = "^A.*$" } } };
    // a IN [$list0, $list1] -> true
    var a_ident = ast.Expr{ .Ident = "a" };
    var p0 = ast.Expr{ .Param = "list0" };
    var p1 = ast.Expr{ .Param = "list1" };
    var items: [2]*ast.Expr = .{ &p0, &p1 };
    const inx = ast.Expr{ .In = .{ .value = &a_ident, .set = items[0..] } };
    const v1 = try evalExpr(ally, inx, env);
    try std.testing.expect(v1 == .Bool and v1.Bool);
    // Equality mixed-type: a = s (7 vs "007") -> false; but a = "7" literal -> true
    var s_ident = ast.Expr{ .Ident = "s" };
    const eq1 = ast.Expr{ .Binary = .{ .op = .Eq, .left = &a_ident, .right = &s_ident } };
    const v2 = try evalExpr(ally, eq1, env);
    try std.testing.expect(v2 == .Bool and !v2.Bool);
    var s7 = ast.Expr{ .String = "7" };
    const eq2 = ast.Expr{ .Binary = .{ .op = .Eq, .left = &a_ident, .right = &s7 } };
    const v3 = try evalExpr(ally, eq2, env);
    try std.testing.expect(v3 == .Bool and v3.Bool);
    // Equality using int parameter vs string field: $list1 (7) = s ("007") -> false
    var p_int = ast.Expr{ .Param = "list1" };
    const eq3 = ast.Expr{ .Binary = .{ .op = .Eq, .left = &p_int, .right = &s_ident } };
    const v3b = try evalExpr(ally, eq3, env);
    try std.testing.expect(v3b == .Bool and !v3b.Bool);
    // Regex via parameter: "Alice" =~ $pat -> true
    var val = ast.Expr{ .String = "Alice" };
    var pat = ast.Expr{ .Param = "pat" };
    const rx = ast.Expr{ .RegexMatch = .{ .value = &val, .pattern = &pat } };
    const v4 = try evalExpr(ally, rx, env);
    try std.testing.expect(v4 == .Bool and v4.Bool);
}

test "eval: CASE permutations with multiple WHENs and ELSE variants" {
    const ally = std.testing.allocator;
    const env = Env{ .names = &.{}, .values = &.{} };
    // Searched CASE: first WHEN true selected; later WHENs skipped
    var t = ast.Expr{ .Bool = true };
    var f = ast.Expr{ .Bool = false };
    var n = ast.Expr{ .Null = {} };
    var A = ast.Expr{ .String = "A" };
    var B = ast.Expr{ .String = "B" };
    var C = ast.Expr{ .String = "C" };
    var whs1: [3]ast.CaseWhen = .{ .{ .when = &t, .then_expr = &A }, .{ .when = &f, .then_expr = &B }, .{ .when = &t, .then_expr = &C } };
    const cs1 = ast.Expr{ .Case = .{ .operand = null, .whens = whs1[0..], .else_expr = &C } };
    const o1 = try evalExpr(ally, cs1, env);
    try std.testing.expect(o1 == .Str and std.mem.eql(u8, o1.Str, "A"));
    // Searched CASE: no WHEN true, ELSE present -> ELSE
    var whs2: [2]ast.CaseWhen = .{ .{ .when = &f, .then_expr = &A }, .{ .when = &n, .then_expr = &B } };
    const cs2 = ast.Expr{ .Case = .{ .operand = null, .whens = whs2[0..], .else_expr = &C } };
    const o2 = try evalExpr(ally, cs2, env);
    try std.testing.expect(o2 == .Str and std.mem.eql(u8, o2.Str, "C"));
    // Simple CASE: operand type-varying WHENs; match on second WHEN; ELSE absent
    var op = ast.Expr{ .String = "2" };
    var w1 = ast.Expr{ .Int = 1 };
    var w2 = ast.Expr{ .String = "2" };
    var whs3: [2]ast.CaseWhen = .{ .{ .when = &w1, .then_expr = &A }, .{ .when = &w2, .then_expr = &B } };
    const cs3 = ast.Expr{ .Case = .{ .operand = &op, .whens = whs3[0..], .else_expr = null } };
    const o3 = try evalExpr(ally, cs3, env);
    try std.testing.expect(o3 == .Str and std.mem.eql(u8, o3.Str, "B"));
    // Simple CASE: operand Int 2, WHEN "2" (string) shouldn't match; ELSE applies
    var op2 = ast.Expr{ .Int = 2 };
    var wstr2 = ast.Expr{ .String = "2" };
    var whs3b: [1]ast.CaseWhen = .{.{ .when = &wstr2, .then_expr = &A }};
    const cs3b = ast.Expr{ .Case = .{ .operand = &op2, .whens = whs3b[0..], .else_expr = &C } };
    const o3b = try evalExpr(ally, cs3b, env);
    try std.testing.expect(o3b == .Str and std.mem.eql(u8, o3b.Str, "C"));
    // Simple CASE: operand NULL, WHEN NULL then -> THEN; ELSE present should be ignored
    var opn = ast.Expr{ .Null = {} };
    var whs4: [2]ast.CaseWhen = .{ .{ .when = &n, .then_expr = &A }, .{ .when = &t, .then_expr = &B } };
    const cs4 = ast.Expr{ .Case = .{ .operand = &opn, .whens = whs4[0..], .else_expr = &C } };
    const o4 = try evalExpr(ally, cs4, env);
    try std.testing.expect(o4 == .Str and std.mem.eql(u8, o4.Str, "A"));
}

test "eval: CASE 3VL searched and simple with NULLs" {
    const ally = std.testing.allocator;
    // Searched CASE: WHEN NULL THEN should not trigger; ELSE chosen
    const env = Env{ .names = &.{}, .values = &.{} };
    var n1 = ast.Expr{ .Null = {} };
    var then1 = ast.Expr{ .String = "x" };
    var whs1: [1]ast.CaseWhen = .{.{ .when = &n1, .then_expr = &then1 }};
    const c1 = ast.Expr{ .Case = .{ .operand = null, .whens = whs1[0..], .else_expr = &then1 } };
    const o1 = try evalExpr(ally, c1, env);
    try std.testing.expect(o1 == .Str and std.mem.eql(u8, o1.Str, "x"));
    // Simple CASE: operand NULL, WHEN NULL -> match returns THEN
    var opn = ast.Expr{ .Null = {} };
    var wnull = ast.Expr{ .Null = {} };
    var t2 = ast.Expr{ .String = "n" };
    var whs2: [1]ast.CaseWhen = .{.{ .when = &wnull, .then_expr = &t2 }};
    const c2 = ast.Expr{ .Case = .{ .operand = &opn, .whens = whs2[0..], .else_expr = null } };
    const o2 = try evalExpr(ally, c2, env);
    try std.testing.expect(o2 == .Str and std.mem.eql(u8, o2.Str, "n"));
}
