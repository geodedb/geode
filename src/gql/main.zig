const std = @import("std");
const gql = @import("geode");
const exec = gql.exec;
const planner = gql.planner;
const temporal = gql.temporal;

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len < 2) {
        std.debug.print("usage: gql [--strict-order-keys] [--ident-order-only] [--forbid-orderby-calls] [--forbid-orderby-paths] [--normalize-temporals] [--clamp-frac <n>] [--session-offset <Z|+HH[:MM]|-HH[:MM]>] [--ast|--ast-json|--ast-json-verbose|--conformance-json] [--demo-sort] <file>\n", .{});
        return;
    }
    var strict = false;
    var ident_only = false;
    var forbid_calls = false;
    var forbid_paths = false;
    var print_ast = false;
    var print_ast_json = false;
    var ast_json_verbose = false;
    var normalize_temporals = false;
    var clamp_frac_digits: ?u8 = null;
    var session_offset: ?i16 = null;
    var conformance_json = false;
    var demo_sort = false;
    var idx: usize = 1;
    while (idx < args.len - 1) {
        if (std.mem.eql(u8, args[idx], "--strict-order-keys")) {
            strict = true;
            idx += 1;
        } else if (std.mem.eql(u8, args[idx], "--ident-order-only")) {
            ident_only = true;
            idx += 1;
        } else if (std.mem.eql(u8, args[idx], "--forbid-orderby-calls")) {
            forbid_calls = true;
            idx += 1;
        } else if (std.mem.eql(u8, args[idx], "--forbid-orderby-paths")) {
            forbid_paths = true;
            idx += 1;
        } else if (std.mem.eql(u8, args[idx], "--normalize-temporals")) {
            normalize_temporals = true;
            idx += 1;
        } else if (std.mem.eql(u8, args[idx], "--clamp-frac")) {
            if (idx + 1 >= args.len) {
                std.debug.print("error: --clamp-frac requires a value 0-9\n", .{});
                std.process.exit(2);
            }
            const val_str = args[idx + 1];
            const parsed = std.fmt.parseInt(u8, val_str, 10) catch {
                std.debug.print("error: --clamp-frac expects integer 0-9, got '{s}'\n", .{val_str});
                std.process.exit(2);
            };
            clamp_frac_digits = parsed;
            idx += 2;
        } else if (std.mem.eql(u8, args[idx], "--session-offset")) {
            if (idx + 1 >= args.len) {
                std.debug.print("error: --session-offset requires value like Z, +HH, +HH:MM, -HH:MM\n", .{});
                std.process.exit(2);
            }
            const val = args[idx + 1];
            session_offset = (@import("../temporal.zig").parseOffsetMinutes(val) catch {
                std.debug.print("error: invalid --session-offset '{s}'\n", .{val});
                std.process.exit(2);
            });
            idx += 2;
        } else if (std.mem.eql(u8, args[idx], "--ast")) {
            print_ast = true;
            idx += 1;
        } else if (std.mem.eql(u8, args[idx], "--ast-json")) {
            print_ast_json = true;
            idx += 1;
        } else if (std.mem.eql(u8, args[idx], "--ast-json-verbose")) {
            print_ast_json = true;
            ast_json_verbose = true;
            idx += 1;
        } else if (std.mem.eql(u8, args[idx], "--conformance-json")) {
            conformance_json = true;
            idx += 1;
        } else if (std.mem.eql(u8, args[idx], "--demo-sort")) {
            demo_sort = true;
            idx += 1;
        } else break;
    }
    if (idx >= args.len) {
        std.debug.print("usage: gql [--strict-order-keys] [--ident-order-only] [--forbid-orderby-calls] [--forbid-orderby-paths] [--normalize-temporals] [--clamp-frac <n>] [--session-offset <Z|+HH[:MM]|-HH[:MM]>] [--ast|--ast-json|--ast-json-verbose|--conformance-json] [--demo-sort] <file>\n", .{});
        return;
    }
    const path = args[idx];
    const src = std.fs.cwd().readFileAlloc(gpa, path, 1 << 20) catch |e| {
        std.debug.print("io error: failed to read {s}: {any}\n", .{ path, e });
        std.process.exit(2);
    };
    defer gpa.free(src);
    const outcome = try gql.parseGqlOutcome(src, gpa, .{ .strict_order_keys = strict, .ident_order_only = ident_only, .forbid_orderby_calls = forbid_calls, .forbid_orderby_paths = forbid_paths });
    var res: gql.ParseResult = switch (outcome) {
        .Ok => |ok| ok,
        .Err => |pe| {
            std.debug.print("parse error: {s} at line {d}, col {d}; token={s}\n", .{ pe.msg, pe.line, pe.column, @tagName(pe.token) });
            std.process.exit(3);
        },
    };
    defer res.deinit();
    if (conformance_json) {
        const conf = gql.conformance;
        const prof: conf.Profile = .{ .features = .{} };
        try conf.writeConformanceJson(std.io.getStdOut().writer(), prof);
    } else if (print_ast or print_ast_json) {
        const printer = gql.printer;
        if (print_ast_json) {
            if (ast_json_verbose) {
                try printer.printProgramJsonWith(std.io.getStdOut().writer(), res.program, .{ .verbose_temporals = true, .session_offset_minutes = session_offset });
            } else {
                try printer.printProgramJsonWith(std.io.getStdOut().writer(), res.program, .{ .session_offset_minutes = session_offset });
            }
        } else {
            const popts = printer.PrintOptions{ .normalize_temporals = normalize_temporals, .clamp_frac_digits = clamp_frac_digits };
            try printer.printProgramHumanWith(std.io.getStdOut().writer(), res.program, popts);
        }
    } else {
        if (demo_sort) {
            // Minimal demo: use the parsed ORDER BY settings and session offset to sort sample temporal rows.
            const ally = std.heap.page_allocator;
            // Expect a single statement query.
            if (res.program.statements.len == 0) {
                std.debug.print("demo-sort: no statements in file\n", .{});
                return;
            }
            const st = res.program.statements[0];
            switch (st) {
                .Query => |q| {
                    if (q.order_by == null) {
                        std.debug.print("demo-sort: query has no ORDER BY\n", .{});
                        return;
                    }
                    const ob = q.order_by.?;
                    if (ob.keys.len == 0) {
                        std.debug.print("demo-sort: ORDER BY has no keys\n", .{});
                        return;
                    }
                    const k0 = ob.keys[0];
                    if (ob.keys.len > 1) {
                        std.debug.print("demo-sort: only first ORDER BY key is used in demo (found {d})\n", .{ob.keys.len});
                    }
                    const so: i16 = session_offset orelse 0;
                    const ctx = planner.SessionContext{ .session_offset_minutes = so };
                    // Build sample rows including NULL and a local datetime to demonstrate session offset.
                    var rows: [5]exec.Row = .{
                        .{ .id = 0, .key = .{ .DateTime = .{ .raw = "2024-01-01T10:00Z", .parsed = try temporal.parseDateTime("2024-01-01T10:00Z", true) } } },
                        .{ .id = 1, .key = .{ .DateTime = .{ .raw = "2024-01-01T11:00+01:00", .parsed = try temporal.parseDateTime("2024-01-01T11:00+01:00", true) } } },
                        .{ .id = 2, .key = .{ .DateTime = .{ .raw = "2024-01-01T09:00Z", .parsed = try temporal.parseDateTime("2024-01-01T09:00Z", true) } } },
                        .{ .id = 3, .key = .{ .LocalDateTime = .{ .raw = "2024-01-01T10:00", .parsed = try temporal.parseDateTime("2024-01-01T10:00", false) } } },
                        .{ .id = 4, .key = .{ .Null = {} } },
                    };
                    try exec.stableOrderByTemporal(&rows, k0.desc, k0.nulls, ctx, ally);
                    // Print results
                    const pr = gql.printer;
                    var out = std.ArrayList(u8).init(ally);
                    defer out.deinit();
                    try out.appendSlice("demo-sort: session_offset_minutes=");
                    try out.writer().print("{d}", .{so});
                    try out.appendSlice("; order= ");
                    try out.writer().print("{s}", .{if (k0.desc) "DESC" else "ASC"});
                    try out.appendSlice("; nulls=");
                    const np = switch (k0.nulls) {
                        .default => "default",
                        .first => "first",
                        .last => "last",
                    };
                    try out.writer().print("{s}\n", .{np});
                    try out.appendSlice("sorted rows (id -> key):\n");
                    for (rows) |r| {
                        const s = try pr.stringifyExprAlloc(ally, r.key, .{});
                        defer ally.free(s);
                        try out.writer().print("  {d} -> {s}\n", .{ r.id, s });
                    }
                    // Write once
                    _ = try std.io.getStdOut().write(out.items);
                },
                else => {
                    std.debug.print("demo-sort: first statement is not a Query\n", .{});
                    return;
                },
            }
        } else {
            std.debug.print("{any}\n", .{res.program});
        }
    }
}
