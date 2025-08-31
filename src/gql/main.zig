const std = @import("std");
const gql = @import("geode");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len < 2) {
        std.debug.print("usage: gql [--strict-order-keys] [--ident-order-only] [--forbid-orderby-calls] [--forbid-orderby-paths] [--normalize-temporals] [--clamp-frac <n>] [--ast|--ast-json|--ast-json-verbose] <file>\n", .{});
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
        } else break;
    }
    if (idx >= args.len) {
        std.debug.print("usage: gql [--strict-order-keys] [--ident-order-only] [--forbid-orderby-calls] [--forbid-orderby-paths] [--normalize-temporals] [--clamp-frac <n>] [--ast|--ast-json|--ast-json-verbose] <file>\n", .{});
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
    if (print_ast or print_ast_json) {
        const printer = gql.printer;
        if (print_ast_json) {
            if (ast_json_verbose) {
                try printer.printProgramJsonWith(std.io.getStdOut().writer(), res.program, .{ .verbose_temporals = true });
            } else {
                try printer.printProgramJson(std.io.getStdOut().writer(), res.program);
            }
        } else {
            const popts = printer.PrintOptions{ .normalize_temporals = normalize_temporals, .clamp_frac_digits = clamp_frac_digits };
            try printer.printProgramHumanWith(std.io.getStdOut().writer(), res.program, popts);
        }
    } else {
        std.debug.print("{any}\n", .{res.program});
    }
}
