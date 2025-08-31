const std = @import("std");
const ast = @import("ast.zig");

pub fn printProgramHuman(w: anytype, prog: ast.Program) !void {
    try w.print("Program:\n", .{});
    for (prog.statements, 0..) |st, i| {
        try w.print("  [{d}] {s}\n", .{ i, tagName(st) });
        switch (st) {
            .Query => |q| try printQuery(w, q, 4),
            .Union => |u| {
                try w.print("    Union:\n", .{});
                try w.print("      First ->\n", .{});
                try printQuery(w, u.first, 8);
                for (u.tails, 0..) |p, j| {
                    try w.print("      Tail[{d}] all={any} distinct={any} ->\n", .{ j, p.all, p.distinct });
                    try printQuery(w, p.query, 8);
                }
            },
            else => {},
        }
    }
}

pub fn printProgramJson(w: anytype, prog: ast.Program) !void {
    var jw = std.json.writeStream(w, .{});
    defer jw.deinit();
    try jw.beginObject();
    try jw.objectField("statements");
    try jw.beginArray();
    for (prog.statements) |st| {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write(@tagName(st));
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

fn tagName(st: ast.Statement) []const u8 {
    return switch (st) {
        .Query => "Query",
        .Union => "Union",
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

fn printQuery(w: anytype, q: ast.Query, pad: usize) !void {
    try indent(w, pad);
    try w.print("Match optional={any}\n", .{q.optional_match});
    try printGraphPattern(w, q.match, pad + 2);
    if (q.where_clause) |we| {
        try indent(w, pad);
        try w.print("Where: ", .{});
        try printExpr(w, we, 0);
        try w.writeByte('\n');
    }
    if (q.with_clause) |wc| {
        try indent(w, pad);
        try w.print("With: ", .{});
        for (wc.items, 0..) |it, i| {
            if (i > 0) try w.print(", ", .{});
            try printExpr(w, it.expr, 0);
            if (it.alias) |a| try w.print(" AS {s}", .{a});
        }
        try w.writeByte('\n');
    }
    if (q.group_by) |gb| {
        try indent(w, pad);
        try w.print("GroupBy: ", .{});
        for (gb.keys, 0..) |k, i| {
            if (i > 0) try w.print(", ", .{});
            try printExpr(w, k, 0);
        }
        try w.writeByte('\n');
    }
    try indent(w, pad);
    try w.print("Return{any}: ", .{q.ret.distinct});
    for (q.ret.items, 0..) |it, i| {
        if (i > 0) try w.print(", ", .{});
        try printExpr(w, it.expr, 0);
        if (it.alias) |a| try w.print(" AS {s}", .{a});
    }
    try w.writeByte('\n');
    if (q.order_by) |ob| {
        try indent(w, pad);
        try w.print("OrderBy: ", .{});
        for (ob.keys, 0..) |k, i| {
            if (i > 0) try w.print(", ", .{});
            try printExpr(w, k.expr, 0);
            try w.print(" {s}", .{if (k.desc) "DESC" else "ASC"});
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

fn printExpr(w: anytype, e: ast.Expr, prec: u8) !void {
    _ = prec;
    switch (e) {
        .Ident => |s| try w.print("{s}", .{s}),
        .String => |s| try w.print("\"{s}\"", .{s}),
        .Int => |n| try w.print("{d}", .{n}),
        .Bool => |b| try w.print("{any}", .{b}),
        .Null => try w.print("null", .{}),
        .Member => |m| {
            try printExpr(w, m.target.*, 0);
            try w.print(".{s}", .{m.field});
        },
        .Unary => |u| {
            switch (u.op) {
                .Not => try w.print("NOT ", .{}),
                .Neg => try w.print("-", .{}),
            }
            try printExpr(w, u.expr.*, 0);
        },
        .Binary => |b| {
            try printExpr(w, b.left.*, 0);
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
            try printExpr(w, b.right.*, 0);
        },
        .Call => |c| {
            try printExpr(w, c.callee.*, 0);
            try w.writeByte('(');
            for (c.args, 0..) |a, i| {
                if (i > 0) try w.print(", ", .{});
                try printExpr(w, a.*, 0);
            }
            try w.writeByte(')');
        },
        .List => |items| {
            try w.writeByte('[');
            for (items, 0..) |it, i| {
                if (i > 0) try w.print(", ", .{});
                try printExpr(w, it.*, 0);
            }
            try w.writeByte(']');
        },
        .In => |inn| {
            try printExpr(w, inn.value.*, 0);
            try w.print(" IN ", .{});
            try w.writeByte('[');
            for (inn.set, 0..) |it, i| {
                if (i > 0) try w.print(", ", .{});
                try printExpr(w, it.*, 0);
            }
            try w.writeByte(']');
        },
        .IsNull => |nz| {
            try printExpr(w, nz.target.*, 0);
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
                try printExpr(w, we.*, 0);
            }
            try w.print(" | ", .{});
            try printExpr(w, pc.map.*, 0);
            try w.writeByte(']');
        },
    }
}
