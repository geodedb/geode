const std = @import("std");
const ast = @import("../gql/ast.zig");

pub const QueryKind = enum { rows, explain, profile };
pub const UnionMode = enum { none, all, distinct, intersect, except };

pub const QueryTraits = struct {
    ordered: bool = false,
    distinct: bool = false,
    has_group_by: bool = false,
    has_union: bool = false,
    union_mode: UnionMode = .none,
    limit: ?usize = null,
    offset: ?usize = null,
    has_where_eq: bool = false,
    has_filter_eq: bool = false,
    has_index_seek: bool = false,
};

pub const ProgramAnalysis = struct {
    kind: QueryKind = .rows,
    traits: QueryTraits = .{},
    target: ?*const ast.Statement = null,
    union_part_count: usize = 0,
};

pub const NormalizedQuery = struct {
    text: []const u8,
    owns_text: bool,
    explain_calibrated: bool,

    pub fn deinit(self: *NormalizedQuery, allocator: std.mem.Allocator) void {
        if (self.owns_text) allocator.free(self.text);
        self.* = .{ .text = &.{}, .owns_text = false, .explain_calibrated = false };
    }
};

pub fn normalizeExplainCalibrated(allocator: std.mem.Allocator, query: []const u8) !NormalizedQuery {
    const trimmed = std.mem.trimLeft(u8, query, " \t\r\n");
    if (!startsWithKeyword(trimmed, "EXPLAIN")) {
        return .{ .text = query, .owns_text = false, .explain_calibrated = false };
    }

    var idx: usize = 0;
    idx += "EXPLAIN".len;
    if (idx < trimmed.len and !std.ascii.isWhitespace(trimmed[idx])) {
        return .{ .text = query, .owns_text = false, .explain_calibrated = false };
    }
    idx = skipWhitespace(trimmed, idx);
    if (!startsWithKeyword(trimmed[idx..], "CALIBRATED")) {
        return .{ .text = query, .owns_text = false, .explain_calibrated = false };
    }
    const after = idx + "CALIBRATED".len;
    if (after < trimmed.len and !std.ascii.isWhitespace(trimmed[after])) {
        return .{ .text = query, .owns_text = false, .explain_calibrated = false };
    }

    const rest_start = skipWhitespace(trimmed, after);
    const rest = trimmed[rest_start..];
    const rebuilt = try std.fmt.allocPrint(allocator, "EXPLAIN {s}", .{rest});
    return .{ .text = rebuilt, .owns_text = true, .explain_calibrated = true };
}

pub fn analyzeProgram(program: *const ast.Program) ProgramAnalysis {
    var analysis = ProgramAnalysis{};
    if (program.statements.len == 0) return analysis;

    var idx: usize = program.statements.len;
    while (idx > 0) : (idx -= 1) {
        const stmt = &program.statements[idx - 1];
        switch (stmt.*) {
            .Explain => |exp| {
                analysis.kind = .explain;
                analysis.target = exp.query;
                analyzeStatement(exp.query, &analysis);
                return analysis;
            },
            .Profile => |prof| {
                analysis.kind = .profile;
                analysis.target = prof.query;
                analyzeStatement(prof.query, &analysis);
                return analysis;
            },
            .Query, .Union => {
                analysis.kind = .rows;
                analysis.target = stmt;
                analyzeStatement(stmt, &analysis);
                return analysis;
            },
            .StartTransaction, .Commit, .Rollback => continue,
            else => continue,
        }
    }
    return analysis;
}

fn analyzeStatement(stmt: *const ast.Statement, analysis: *ProgramAnalysis) void {
    switch (stmt.*) {
        .Query => |q| {
            analysis.traits.ordered = q.order_by != null;
            analysis.traits.limit = if (q.limit) |l| @as(?usize, @intCast(l)) else null;
            analysis.traits.offset = if (q.offset) |o| @as(?usize, @intCast(o)) else null;
            analysis.traits.has_group_by = q.group_by != null;
            analysis.traits.distinct = q.ret.distinct;
            analysis.traits.has_where_eq = hasEqExpr(q.where_clause);
            analysis.traits.has_filter_eq = hasEqExpr(q.filter_clause);
            analysis.traits.has_union = false;
            analysis.union_part_count = 1;
        },
        .Union => |u| {
            analysis.traits.has_union = true;
            analysis.traits.ordered = u.order_by != null;
            analysis.traits.limit = if (u.limit) |l| @as(?usize, @intCast(l)) else null;
            analysis.traits.offset = if (u.offset) |o| @as(?usize, @intCast(o)) else null;
            analysis.union_part_count = u.tails.len + 1;
            analysis.traits.distinct = false;
            var mode: UnionMode = .all;
            var saw_intersect = false;
            var saw_except = false;
            var saw_distinct = false;
            for (u.tails) |part| {
                switch (part.operation) {
                    .intersect => saw_intersect = true,
                    .except => saw_except = true,
                    else => {},
                }
                if (!part.all or part.distinct) saw_distinct = true;
            }
            if (saw_intersect) {
                mode = .intersect;
            } else if (saw_except) {
                mode = .except;
            } else if (saw_distinct or u.tails.len == 0) {
                mode = .distinct;
                analysis.traits.distinct = true;
            } else {
                mode = .all;
            }
            analysis.traits.union_mode = mode;
        },
        else => {},
    }
}

fn hasEqExpr(expr_opt: ?ast.Expr) bool {
    if (expr_opt) |expr| {
        return containsEq(&expr);
    }
    return false;
}

fn containsEq(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .Binary => |b| if (b.op == .Eq) true else containsEq(b.left) or containsEq(b.right),
        .Unary => |u| containsEq(u.expr),
        .In => |in_expr| containsEq(in_expr.value),
        .InListExpr => |in_expr| containsEq(in_expr.value) or containsEq(in_expr.list_expr),
        .NotIn => |in_expr| containsEq(in_expr.value),
        .NotInListExpr => |in_expr| containsEq(in_expr.value) or containsEq(in_expr.list_expr),
        .IsNull => |v| containsEq(v.target),
        .IsUnknown => |v| containsEq(v.target),
        .Call => |call| blk: {
            if (containsEq(call.callee)) break :blk true;
            for (call.args) |arg| if (containsEq(arg)) break :blk true;
            break :blk false;
        },
        .Case => |c| blk: {
            if (c.operand) |op| if (containsEq(op)) break :blk true;
            for (c.whens) |w| {
                if (containsEq(w.when) or containsEq(w.then_expr)) break :blk true;
            }
            if (c.else_expr) |e| if (containsEq(e)) break :blk true;
            break :blk false;
        },
        .PatternComp => |p| containsEq(p.map) or (if (p.where) |w| containsEq(w) else false),
        .Exists => |e| if (e.where) |w| containsEq(w) else false,
        .PatternCount => |p| if (p.where) |w| containsEq(w) else false,
        .ListComprehension => |lc| (if (lc.filter) |f| containsEq(f) else false) or (if (lc.map) |m| containsEq(m) else false),
        .Index => |ix| containsEq(ix.target) or containsEq(ix.index),
        .Member => |m| containsEq(m.target),
        .Slice => |s| containsEq(s.target) or (if (s.start) |st| containsEq(st) else false) or (if (s.end) |en| containsEq(en) else false),
        else => false,
    };
}

fn startsWithKeyword(hay: []const u8, needle: []const u8) bool {
    if (hay.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(hay[0..needle.len], needle);
}

fn skipWhitespace(s: []const u8, start: usize) usize {
    var idx = start;
    while (idx < s.len and std.ascii.isWhitespace(s[idx])) idx += 1;
    return idx;
}
