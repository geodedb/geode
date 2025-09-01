const std = @import("std");
const ast = @import("ast.zig");
const temporal = @import("../temporal.zig");

pub const PrintOptions = struct {
    normalize_temporals: bool = false,
    clamp_frac_digits: ?u8 = null,
};

pub fn printProgramHuman(w: anytype, prog: ast.Program) !void {
    return printProgramHumanWith(w, prog, .{});
}

pub fn printProgramHumanWith(w: anytype, prog: ast.Program, opts: PrintOptions) !void {
    try w.print("Program:\n", .{});
    for (prog.statements, 0..) |st, i| {
        try w.print("  [{d}] {s}\n", .{ i, tagName(st) });
        switch (st) {
            .Query => |q| try printQueryWith(w, q, 4, opts),
            .Union => |u| {
                try w.print("    Union:\n", .{});
                try w.print("      First ->\n", .{});
                try printQueryWith(w, u.first, 8, opts);
                for (u.tails, 0..) |p, j| {
                    try w.print("      Tail[{d}] all={any} distinct={any} ->\n", .{ j, p.all, p.distinct });
                    try printQueryWith(w, p.query, 8, opts);
                }
            },
            else => {},
        }
    }
}

pub const PrintJsonOptions = struct { verbose_temporals: bool = false, session_offset_minutes: ?i16 = null };

pub fn printProgramJson(w: anytype, prog: ast.Program) !void {
    return printProgramJsonWith(w, prog, .{});
}

pub fn printProgramJsonWith(w: anytype, prog: ast.Program, jopts: PrintJsonOptions) !void {
    var jw = std.json.writeStream(w, .{});
    defer jw.deinit();
    try jw.beginObject();
    if (jopts.session_offset_minutes) |som| {
        try jw.objectField("session_offset_minutes");
        try jw.write(som);
    }
    try jw.objectField("statements");
    try jw.beginArray();
    for (prog.statements) |st| {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write(@tagName(st));
        try jw.endObject();
    }
    try jw.endArray();
    if (jopts.verbose_temporals) {
        try jw.objectField("temporals");
        try jw.beginArray();
        var list = try collectTemporalsList(std.heap.page_allocator, prog);
        defer list.deinit();
        for (list.items) |ent| {
            try jw.beginObject();
            try jw.objectField("kind");
            switch (ent) {
                .Date => try jw.write("Date"),
                .Time => try jw.write("Time"),
                .DateTime => try jw.write("DateTime"),
                .LocalDateTime => try jw.write("LocalDateTime"),
            }
            try jw.objectField("raw");
            switch (ent) {
                .Date => |d| try jw.write(d.raw),
                .Time => |t| try jw.write(t.raw),
                .DateTime => |dt| try jw.write(dt.raw),
                .LocalDateTime => |ldt| try jw.write(ldt.raw),
            }
            try jw.objectField("parsed");
            switch (ent) {
                .Date => |d| {
                    try jw.beginObject();
                    try jw.objectField("y");
                    try jw.write(d.y);
                    try jw.objectField("m");
                    try jw.write(d.m);
                    try jw.objectField("d");
                    try jw.write(d.d);
                    try jw.endObject();
                },
                .Time => |t| {
                    try jw.beginObject();
                    try jw.objectField("h");
                    try jw.write(t.h);
                    try jw.objectField("min");
                    try jw.write(t.min);
                    try jw.objectField("s");
                    try jw.write(t.s);
                    try jw.objectField("has_seconds");
                    try jw.write(t.has_seconds);
                    try jw.objectField("has_fraction");
                    try jw.write(t.has_fraction);
                    try jw.objectField("frac_nanos");
                    try jw.write(t.frac_nanos);
                    try jw.objectField("frac_digits");
                    try jw.write(t.frac_digits);
                    try jw.objectField("offset_minutes");
                    if (t.offset_minutes) |om| try jw.write(om) else try jw.write(null);
                    try jw.endObject();
                },
                .DateTime => |dt| {
                    try jw.beginObject();
                    try jw.objectField("date");
                    try jw.beginObject();
                    try jw.objectField("y");
                    try jw.write(dt.date.y);
                    try jw.objectField("m");
                    try jw.write(dt.date.m);
                    try jw.objectField("d");
                    try jw.write(dt.date.d);
                    try jw.endObject();
                    try jw.objectField("time");
                    try jw.beginObject();
                    try jw.objectField("h");
                    try jw.write(dt.time.h);
                    try jw.objectField("min");
                    try jw.write(dt.time.min);
                    try jw.objectField("s");
                    try jw.write(dt.time.s);
                    try jw.objectField("has_seconds");
                    try jw.write(dt.time.has_seconds);
                    try jw.objectField("has_fraction");
                    try jw.write(dt.time.has_fraction);
                    try jw.objectField("frac_nanos");
                    try jw.write(dt.time.frac_nanos);
                    try jw.objectField("frac_digits");
                    try jw.write(dt.time.frac_digits);
                    try jw.objectField("offset_minutes");
                    if (dt.time.offset_minutes) |om| try jw.write(om) else try jw.write(null);
                    try jw.endObject();
                    try jw.endObject();
                },
                .LocalDateTime => |ldt| {
                    try jw.beginObject();
                    try jw.objectField("date");
                    try jw.beginObject();
                    try jw.objectField("y");
                    try jw.write(ldt.date.y);
                    try jw.objectField("m");
                    try jw.write(ldt.date.m);
                    try jw.objectField("d");
                    try jw.write(ldt.date.d);
                    try jw.endObject();
                    try jw.objectField("time");
                    try jw.beginObject();
                    try jw.objectField("h");
                    try jw.write(ldt.time.h);
                    try jw.objectField("min");
                    try jw.write(ldt.time.min);
                    try jw.objectField("s");
                    try jw.write(ldt.time.s);
                    try jw.objectField("has_seconds");
                    try jw.write(ldt.time.has_seconds);
                    try jw.objectField("has_fraction");
                    try jw.write(ldt.time.has_fraction);
                    try jw.objectField("frac_nanos");
                    try jw.write(ldt.time.frac_nanos);
                    try jw.objectField("frac_digits");
                    try jw.write(ldt.time.frac_digits);
                    try jw.objectField("offset_minutes");
                    if (ldt.time.offset_minutes) |om| try jw.write(om) else try jw.write(null);
                    try jw.endObject();
                    try jw.endObject();
                },
            }
            try jw.endObject();
        }
        try jw.endArray();
    }
    try jw.endObject();
}

fn tagName(st: ast.Statement) []const u8 {
    return switch (st) {
        .Query => "Query",
        .Union => "Union",
        .Intersect => "Intersect",
        .Except => "Except",
        .SessionSet => "SessionSet",
        .SessionReset => "SessionReset",
        .SessionClose => "SessionClose",
        .StartTransaction => "StartTransaction",
        .Commit => "Commit",
        .Rollback => "Rollback",
    };
}

fn indent(w: anytype, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeByte(' ');
}

// no-op placeholder removed: date/time/datetime JSON is written inline from union entries

const TemporalEntry = union(enum) {
    Date: temporal.Date,
    Time: temporal.Time,
    DateTime: temporal.DateTime,
    LocalDateTime: temporal.DateTime,
};

fn collectTemporalsList(ally: std.mem.Allocator, prog: ast.Program) !std.ArrayList(TemporalEntry) {
    var list = std.ArrayList(TemporalEntry).init(ally);
    const self = struct {
        fn walkStmt(dst: *std.ArrayList(TemporalEntry), st: ast.Statement) !void {
            switch (st) {
                .Query => |q| try walkQuery(dst, q),
                .Union => |u| {
                    try walkQuery(dst, u.first);
                    for (u.tails) |p| try walkQuery(dst, p.query);
                },
                else => {},
            }
        }
        fn walkQuery(dst: *std.ArrayList(TemporalEntry), q: ast.Query) !void {
            if (q.where_clause) |e| try walkExpr(dst, e);
            if (q.with_clause) |wth| for (wth.items) |it| try walkExpr(dst, it.expr);
            if (q.group_by) |gb| for (gb.keys) |k| try walkExpr(dst, k);
            if (q.having) |hv| try walkExpr(dst, hv);
            for (q.ret.items) |it| try walkExpr(dst, it.expr);
            if (q.order_by) |ob| for (ob.keys) |k| try walkExpr(dst, k.expr);
        }
        fn walkExpr(dst: *std.ArrayList(TemporalEntry), e: ast.Expr) !void {
            switch (e) {
                .Date => |d| try dst.append(.{ .Date = d.parsed }),
                .Time => |t| try dst.append(.{ .Time = t.parsed }),
                .DateTime => |dt| try dst.append(.{ .DateTime = dt.parsed }),
                .LocalDateTime => |ldt| try dst.append(.{ .LocalDateTime = ldt.parsed }),
                .Unary => |u| try walkExpr(dst, u.expr.*),
                .Binary => |b| {
                    try walkExpr(dst, b.left.*);
                    try walkExpr(dst, b.right.*);
                },
                .Member => |m| try walkExpr(dst, m.target.*),
                .Call => |c| {
                    try walkExpr(dst, c.callee.*);
                    for (c.args) |a| try walkExpr(dst, a.*);
                },
                .List => |items| for (items) |it| try walkExpr(dst, it.*),
                .In => |inn| {
                    try walkExpr(dst, inn.value.*);
                    for (inn.set) |it| try walkExpr(dst, it.*);
                },
                .NotIn => |nin| {
                    try walkExpr(dst, nin.value.*);
                    for (nin.set) |it| try walkExpr(dst, it.*);
                },
                .IsNull => |nz| try walkExpr(dst, nz.target.*),
                .Case => |c| {
                    if (c.operand) |op| try walkExpr(dst, op.*);
                    for (c.whens) |wh| {
                        try walkExpr(dst, wh.when.*);
                        try walkExpr(dst, wh.then_expr.*);
                    }
                    if (c.else_expr) |el| try walkExpr(dst, el.*);
                },
                .PatternComp => |pc| {
                    if (pc.where) |we| try walkExpr(dst, we.*);
                    try walkExpr(dst, pc.map.*);
                },
                else => {},
            }
        }
    };
    for (prog.statements) |st| try self.walkStmt(&list, st);
    return list;
}

pub fn printQueryWith(w: anytype, q: ast.Query, pad: usize, opts: PrintOptions) !void {
    try indent(w, pad);
    try w.print("Match optional={any}\n", .{q.optional_match});
    try printGraphPattern(w, q.match, pad + 2);
    if (q.where_clause) |we| {
        try indent(w, pad);
        try w.print("Where: ", .{});
        try printExprWith(w, we, 0, opts);
        try w.writeByte('\n');
    }
    if (q.with_clause) |wc| {
        try indent(w, pad);
        try w.print("With: ", .{});
        for (wc.items, 0..) |it, i| {
            if (i > 0) try w.print(", ", .{});
            try printExprWith(w, it.expr, 0, opts);
            if (it.alias) |a| try w.print(" AS {s}", .{a});
        }
        try w.writeByte('\n');
    }
    if (q.group_by) |gb| {
        try indent(w, pad);
        try w.print("GroupBy: ", .{});
        for (gb.keys, 0..) |k, i| {
            if (i > 0) try w.print(", ", .{});
            try printExprWith(w, k, 0, opts);
        }
        try w.writeByte('\n');
    }
    if (q.having) |hv| {
        try indent(w, pad);
        try w.print("Having: ", .{});
        try printExprWith(w, hv, 0, opts);
        try w.writeByte('\n');
    }
    try indent(w, pad);
    try w.print("Return{any}: ", .{q.ret.distinct});
    for (q.ret.items, 0..) |it, i| {
        if (i > 0) try w.print(", ", .{});
        try printExprWith(w, it.expr, 0, opts);
        if (it.alias) |a| try w.print(" AS {s}", .{a});
    }
    try w.writeByte('\n');
    if (q.order_by) |ob| {
        try indent(w, pad);
        try w.print("OrderBy: ", .{});
        for (ob.keys, 0..) |k, i| {
            if (i > 0) try w.print(", ", .{});
            try printExprWith(w, k.expr, 0, opts);
            try w.print(" {s}", .{if (k.desc) "DESC" else "ASC"});
            if (k.nulls != .default) {
                try w.print(" NULLS {s}", .{switch (k.nulls) {
                    .first => "FIRST",
                    .last => "LAST",
                    .default => "",
                }});
            }
        }
        try w.writeByte('\n');
    }
    if (q.limit) |lim| {
        try indent(w, pad);
        try w.print("Limit: {d}\n", .{lim});
    }
    if (q.offset) |ofs| {
        try indent(w, pad);
        try w.print("Offset: {d}\n", .{ofs});
    }
}

fn printGraphPattern(w: anytype, gp: ast.GraphPattern, pad: usize) !void {
    try indent(w, pad);
    try w.print("GraphPattern chains={d}\n", .{gp.chains.len});
    for (gp.chains, 0..) |ch, i| {
        try indent(w, pad + 2);
        try w.print("Chain[{d}]{s}{s}\n", .{ i, if (ch.name) |_| ":" else "", if (ch.name) |n| n else "" });
        for (ch.hops, 0..) |hp, j| {
            try indent(w, pad + 4);
            try w.print("Hop[{d}] ", .{j});
            try printNode(w, hp.left);
            try w.print(" -", .{});
            try printRel(w, hp.rel);
            try w.print("-> ", .{});
            try printNode(w, hp.right);
            try w.writeByte('\n');
        }
    }
}

fn printNode(w: anytype, n: ast.NodePattern) !void {
    try w.writeByte('(');
    if (n.name) |nm| try w.print("{s}", .{nm});
    for (n.labels) |l| try w.print(":{s}", .{l});
    if (n.props) |_| try w.print(" {{…}}", .{});
    try w.writeByte(')');
}

fn printRel(w: anytype, r: ast.RelPattern) !void {
    try w.writeByte('[');
    if (r.name) |nm| try w.print("{s}", .{nm});
    for (r.types) |t| try w.print(":{s}", .{t});
    // quantifier
    if (r.min_len != null or r.max_len != null) {
        try w.writeByte('*');
        if (r.min_len) |mn| try w.print("{d}", .{mn});
        if (r.max_len != null and (r.min_len == null or r.max_len.? != r.min_len.?)) {
            try w.print("..", .{});
            if (r.max_len) |mx| try w.print("{d}", .{mx});
        } else if (r.max_len == null and r.min_len != null) {
            try w.print("..", .{});
        }
    }
    if (r.props) |_| try w.print(" {{…}}", .{});
    try w.writeByte(']');
}

pub fn printExpr(w: anytype, e: ast.Expr, prec: u8) !void {
    return printExprWith(w, e, prec, .{});
}

// Helper to stringify a single expression with options, for granular tests and utilities.
pub fn stringifyExprAlloc(ally: std.mem.Allocator, e: ast.Expr, opts: PrintOptions) ![]u8 {
    var buf = std.ArrayList(u8).init(ally);
    errdefer buf.deinit();
    try printExprWith(buf.writer(), e, 0, opts);
    return buf.toOwnedSlice();
}

pub fn printExprWith(w: anytype, e: ast.Expr, prec: u8, opts: PrintOptions) !void {
    _ = prec;
    switch (e) {
        .Ident => |s| try w.print("{s}", .{s}),
        .String => |s| try w.print("\"{s}\"", .{s}),
        .Int => |n| try w.print("{d}", .{n}),
        .Decimal => |d| blk_dec: {
            // Render as standard fixed-point decimal with scale digits after the dot
            const neg = d.coeff < 0;
            const abs: i128 = if (neg) -d.coeff else d.coeff;
            var whole: i128 = abs;
            var frac: i128 = 0;
            if (d.scale > 0) {
                var i: u8 = 0;
                var p: i128 = 1;
                while (i < d.scale) : (i += 1) p *= 10;
                whole = @divTrunc(abs, p);
                frac = @mod(abs, p);
            }
            // write whole
            try w.print("{s}{d}", .{ if (neg) "-" else "", whole });
            if (d.scale > 0) {
                try w.writeByte('.');
                // pad frac with leading zeros to exactly scale digits
                var buf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{frac}) catch unreachable;
                if (s.len < d.scale) {
                    var pad_i: u8 = 0;
                    while (pad_i < d.scale - s.len) : (pad_i += 1) try w.writeByte('0');
                }
                try w.print("{s}", .{s});
            }
            break :blk_dec;
        },
        .Bool => |b| try w.print("{any}", .{b}),
        .Null => try w.print("null", .{}),
        .Date => |d| if (!opts.normalize_temporals) {
            try w.print("DATE\"{s}\"", .{d.raw});
        } else {
            var buf = std.ArrayList(u8).init(std.heap.page_allocator);
            defer buf.deinit();
            try temporal.formatDate(buf.writer(), d.parsed);
            try w.print("DATE\"{s}\"", .{buf.items});
        },
        .DateTime => |dt| if (!opts.normalize_temporals) {
            try w.print("DATETIME\"{s}\"", .{dt.raw});
        } else {
            var buf = std.ArrayList(u8).init(std.heap.page_allocator);
            defer buf.deinit();
            try temporal.formatDateTime(buf.writer(), dt.parsed, .{ .clamp_frac_digits = opts.clamp_frac_digits });
            try w.print("DATETIME\"{s}\"", .{buf.items});
        },
        .Time => |t| if (!opts.normalize_temporals) {
            try w.print("TIME\"{s}\"", .{t.raw});
        } else {
            var buf = std.ArrayList(u8).init(std.heap.page_allocator);
            defer buf.deinit();
            try temporal.formatTime(buf.writer(), t.parsed, .{ .clamp_frac_digits = opts.clamp_frac_digits });
            try w.print("TIME\"{s}\"", .{buf.items});
        },
        .LocalDateTime => |ldt| if (!opts.normalize_temporals) {
            try w.print("LOCAL DATETIME\"{s}\"", .{ldt.raw});
        } else {
            var buf = std.ArrayList(u8).init(std.heap.page_allocator);
            defer buf.deinit();
            try temporal.formatDateTime(buf.writer(), ldt.parsed, .{ .clamp_frac_digits = opts.clamp_frac_digits });
            try w.print("LOCAL DATETIME\"{s}\"", .{buf.items});
        },
        .StartsWith => |sw| {
            try printExprWith(w, sw.value.*, 0, opts);
            try w.print(" STARTS WITH ", .{});
            try printExprWith(w, sw.prefix.*, 0, opts);
        },
        .EndsWith => |ew| {
            try printExprWith(w, ew.value.*, 0, opts);
            try w.print(" ENDS WITH ", .{});
            try printExprWith(w, ew.suffix.*, 0, opts);
        },
        .Contains => |co| {
            try printExprWith(w, co.value.*, 0, opts);
            try w.print(" CONTAINS ", .{});
            try printExprWith(w, co.needle.*, 0, opts);
        },
        .RegexMatch => |rm| {
            try printExprWith(w, rm.value.*, 0, opts);
            try w.print(" =~ ", .{});
            try printExprWith(w, rm.pattern.*, 0, opts);
        },
        .Param => |pname| {
            try w.print("${s}", .{pname});
        },
        .Case => |c| {
            try w.print("CASE ", .{});
            if (c.operand) |op| {
                try printExprWith(w, op.*, 0, opts);
                try w.writeByte(' ');
            }
            for (c.whens) |wh| {
                try w.print("WHEN ", .{});
                try printExprWith(w, wh.when.*, 0, opts);
                try w.print(" THEN ", .{});
                try printExprWith(w, wh.then_expr.*, 0, opts);
                try w.writeByte(' ');
            }
            if (c.else_expr) |el| {
                try w.print("ELSE ", .{});
                try printExprWith(w, el.*, 0, opts);
                try w.writeByte(' ');
            }
            try w.print("END", .{});
        },
        .Member => |m| {
            try printExprWith(w, m.target.*, 0, opts);
            try w.print(".{s}", .{m.field});
        },
        .Unary => |u| {
            switch (u.op) {
                .Not => try w.print("NOT ", .{}),
                .Neg => try w.print("-", .{}),
            }
            try printExprWith(w, u.expr.*, 0, opts);
        },
        .Binary => |b| {
            try printExprWith(w, b.left.*, 0, opts);
            const op = switch (b.op) {
                .And => " AND ",
                .Or => " OR ",
                .Eq => " = ",
                .Ne => " <> ",
                .Lt => " < ",
                .Le => " <= ",
                .Gt => " > ",
                .Ge => " >= ",
                .Add => " + ",
                .Sub => " - ",
                .Mul => " * ",
                .Div => " / ",
            };
            try w.print("{s}", .{op});
            try printExprWith(w, b.right.*, 0, opts);
        },
        .Call => |c| {
            try printExprWith(w, c.callee.*, 0, opts);
            try w.writeByte('(');
            for (c.args, 0..) |a, i| {
                if (i > 0) try w.print(", ", .{});
                try printExprWith(w, a.*, 0, opts);
            }
            try w.writeByte(')');
        },
        .List => |items| {
            try w.writeByte('[');
            for (items, 0..) |it, i| {
                if (i > 0) try w.print(", ", .{});
                try printExprWith(w, it.*, 0, opts);
            }
            try w.writeByte(']');
        },
        .In => |inn| {
            try printExprWith(w, inn.value.*, 0, opts);
            try w.print(" IN ", .{});
            try w.writeByte('[');
            for (inn.set, 0..) |it, i| {
                if (i > 0) try w.print(", ", .{});
                try printExprWith(w, it.*, 0, opts);
            }
            try w.writeByte(']');
        },
        .NotIn => |nin| {
            try printExprWith(w, nin.value.*, 0, opts);
            try w.print(" NOT IN ", .{});
            try w.writeByte('[');
            for (nin.set, 0..) |it, i| {
                if (i > 0) try w.print(", ", .{});
                try printExprWith(w, it.*, 0, opts);
            }
            try w.writeByte(']');
        },
        .IsNull => |nz| {
            try printExprWith(w, nz.target.*, 0, opts);
            if (nz.negated) {
                try w.print(" IS NOT NULL", .{});
            } else {
                try w.print(" IS NULL", .{});
            }
        },
        .Map => |_| try w.print("{{…}}", .{}),
        .PatternComp => |pc| {
            if (pc.alias) |al| try w.print("{s} = ", .{al});
            try w.writeByte('[');
            try printGraphPattern(w, pc.pattern.*, 0);
            if (pc.where) |we| {
                try w.print(" WHERE ", .{});
                try printExprWith(w, we.*, 0, opts);
            }
            try w.print(" | ", .{});
            try printExprWith(w, pc.map.*, 0, opts);
            try w.writeByte(']');
        },
    }
}
