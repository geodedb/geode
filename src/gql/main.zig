const std = @import("std");
const builtin = @import("builtin");
const gql = @import("geode");
const exec = gql.exec;
const planner = gql.planner;
const temporal = gql.temporal;
const eval = gql.eval;
const diagnostics = gql.diagnostics;
const ast = gql.ast;
const status = gql.gql.status;

pub fn main() !void {
    // P2-3: Use GeneralPurposeAllocator instead of page_allocator
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len < 2) {
        std.debug.print("usage: gql [--strict-order-keys] [--ident-order-only] [--forbid-orderby-calls] [--forbid-orderby-paths] [--normalize-temporals] [--clamp-frac <n>] [--session-offset <Z|+HH[:MM]|-HH[:MM]>] [--ast|--ast-json|--ast-json-verbose|--conformance-json] [--demo-sort|--demo-setops|--bench-setops|--demo-eval|--demo-diagnostics|--demo-agg] <file>\n", .{});
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
    var demo_setops = false;
    var bench_setops = false;
    var bench_eval = false;
    var demo_eval = false;
    var demo_diagnostics = false;
    var demo_agg = false;
    // Collect parameters from --param name=value occurrences
    var param_names = std.ArrayList([]const u8).initCapacity(gpa, 0) catch @panic("OOM");
    defer param_names.deinit(gpa);
    var param_values = std.ArrayList(eval.Value).initCapacity(gpa, 0) catch @panic("OOM");
    defer param_values.deinit(gpa);
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
            session_offset = (gql.temporal.parseOffsetMinutes(val) catch {
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
        } else if (std.mem.eql(u8, args[idx], "--demo-setops")) {
            demo_setops = true;
            idx += 1;
        } else if (std.mem.eql(u8, args[idx], "--bench-setops")) {
            bench_setops = true;
            idx += 1;
        } else if (std.mem.eql(u8, args[idx], "--bench-eval")) {
            bench_eval = true;
            idx += 1;
        } else if (std.mem.eql(u8, args[idx], "--demo-eval")) {
            demo_eval = true;
            idx += 1;
        } else if (std.mem.eql(u8, args[idx], "--demo-diagnostics")) {
            demo_diagnostics = true;
            idx += 1;
        } else if (std.mem.eql(u8, args[idx], "--demo-agg")) {
            demo_agg = true;
            idx += 1;
        } else if (std.mem.eql(u8, args[idx], "--param")) {
            if (idx + 1 >= args.len) {
                std.debug.print("error: --param requires name=value\n", .{});
                std.process.exit(2);
            }
            const nv = args[idx + 1];
            if (std.mem.indexOfScalar(u8, nv, '=') == null) {
                std.debug.print("error: --param expects name=value, got '{s}'\n", .{nv});
                std.process.exit(2);
            }
            const pos = std.mem.indexOfScalar(u8, nv, '=').?;
            const name = nv[0..pos];
            const val = nv[pos + 1 ..];
            // Simple heuristic: if digits only -> Int, else strip optional quotes -> Str
            var is_num = val.len > 0;
            var k: usize = 0;
            while (k < val.len) : (k += 1) {
                if (val[k] < '0' or val[k] > '9') {
                    is_num = false;
                    break;
                }
            }
            try param_names.append(gpa, name);
            if (is_num) {
                const n = std.fmt.parseInt(i64, val, 10) catch 0;
                try param_values.append(gpa, .{ .Int = n });
            } else if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "false")) {
                try param_values.append(gpa, .{ .Bool = std.mem.eql(u8, val, "true") });
            } else if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
                try param_values.append(gpa, .{ .Str = val[1 .. val.len - 1] });
            } else if (std.mem.eql(u8, val, "null")) {
                try param_values.append(gpa, .{ .Null = {} });
            } else {
                try param_values.append(gpa, .{ .Str = val });
            }
            idx += 2;
        } else break;
    }
    if (idx >= args.len) {
        std.debug.print("usage: gql [--strict-order-keys] [--ident-order-only] [--forbid-orderby-calls] [--forbid-orderby-paths] [--normalize-temporals] [--clamp-frac <n>] [--session-offset <Z|+HH[:MM]|-HH[:MM]>] [--ast|--ast-json|--ast-json-verbose|--conformance-json] [--demo-sort|--demo-setops|--bench-setops|--demo-eval|--demo-diagnostics|--demo-agg] <file>\n", .{});
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
            // Output structured JSON diagnostic to stderr
            const stderr_file = if (builtin.os.tag == .windows) std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch unreachable } else std.fs.File{ .handle = std.posix.STDERR_FILENO };
            const stderr = stderr_file.deprecatedWriter();
            const gql_status = status.syntaxError(pe.msg, pe.line, pe.column, @tagName(pe.token));
            try status.writeJson(stderr, gql_status);
            try stderr.writeByte('\n');
            std.process.exit(2);
        },
    };
    defer res.deinit();
    if (conformance_json) {
        const conf = gql.conformance;
        const prof: conf.Profile = .{ .features = .{} };
        {
            const stdout_file = if (builtin.os.tag == .windows)
                std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
            else if (builtin.os.tag == .windows) std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable } else std.fs.File{ .handle = std.posix.STDOUT_FILENO };
            const w = stdout_file.deprecatedWriter();
            try conf.writeConformanceJson(w, prof);
        }
    } else if (print_ast or print_ast_json) {
        const printer = gql.printer;
        if (print_ast_json) {
            if (ast_json_verbose) {
                {
                    const out_file = if (builtin.os.tag == .windows) std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable } else std.fs.File{ .handle = std.posix.STDOUT_FILENO };
                    const w = out_file.deprecatedWriter();
                    // P2-3: Pass allocator to printProgramJsonWith
                    try printer.printProgramJsonWith(gpa, w, res.program, .{ .verbose_temporals = true, .session_offset_minutes = session_offset });
                }
            } else {
                {
                    const out_file = if (builtin.os.tag == .windows) std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable } else std.fs.File{ .handle = std.posix.STDOUT_FILENO };
                    const w = out_file.deprecatedWriter();
                    // P2-3: Pass allocator to printProgramJsonWith
                    try printer.printProgramJsonWith(gpa, w, res.program, .{ .session_offset_minutes = session_offset });
                }
            }
        } else {
            // P2-3: Add allocator to PrintOptions for temporal formatting
            const popts = printer.PrintOptions{ .normalize_temporals = normalize_temporals, .clamp_frac_digits = clamp_frac_digits, .allocator = gpa };
            {
                const out_file = if (builtin.os.tag == .windows) std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable } else std.fs.File{ .handle = std.posix.STDOUT_FILENO };
                const w = out_file.deprecatedWriter();
                try printer.printProgramHumanWith(w, res.program, popts);
            }
        }
    } else {
        if (demo_sort) {
            // Minimal demo: use the parsed ORDER BY settings and session offset to sort sample temporal rows.
            // P2-3: Use main GPA instead of page_allocator
            const ally = gpa;
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
                    // GAP-0220 FIX: Use try for proper error propagation
                    var out = try std.ArrayList(u8).initCapacity(ally, 0);
                    defer out.deinit(ally);
                    try out.appendSlice(ally, "demo-sort: session_offset_minutes=");
                    try out.writer(ally).print("{d}", .{so});
                    try out.appendSlice(ally, "; order= ");
                    try out.writer(ally).print("{s}", .{if (k0.desc) "DESC" else "ASC"});
                    try out.appendSlice(ally, "; nulls=");
                    const np = switch (k0.nulls) {
                        .default => "default",
                        .first => "first",
                        .last => "last",
                    };
                    try out.writer(ally).print("{s}\n", .{np});
                    try out.appendSlice(ally, "sorted rows (id -> key):\n");
                    for (rows) |r| {
                        const s = try pr.stringifyExprAlloc(ally, r.key, .{});
                        defer ally.free(s);
                        try out.writer(ally).print("  {d} -> {s}\n", .{ r.id, s });
                    }
                    // Write once
                    const outf = if (builtin.os.tag == .windows) std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable } else std.fs.File{ .handle = std.posix.STDOUT_FILENO };
                    _ = try outf.write(out.items);
                },
                else => {
                    std.debug.print("demo-sort: first statement is not a Query\n", .{});
                    return;
                },
            }
        } else if (demo_setops) {
            // Demonstrate UNION/INTERSECT/EXCEPT semantics on sample binding rows
            // P2-3: Use main GPA instead of page_allocator
            const ally = gpa;
            const A0 = [_]exec.BindingValue{ .{ .Int = 1 }, .{ .Str = "a" } };
            const A1 = [_]exec.BindingValue{ .{ .Null = {} }, .{ .Str = "x" } };
            const A2 = [_]exec.BindingValue{ .{ .Int = 1 }, .{ .Str = "a" } };
            const B0 = [_]exec.BindingValue{ .{ .Int = 1 }, .{ .Str = "a" } };
            const B1 = [_]exec.BindingValue{ .{ .Null = {} }, .{ .Str = "x" } };
            const B2 = [_]exec.BindingValue{ .{ .Null = {} }, .{ .Str = "x" } };
            var a0 = A0;
            var a1 = A1;
            var a2 = A2;
            var b0 = B0;
            var b1 = B1;
            var b2 = B2;
            const A: []const []exec.BindingValue = &.{ a0[0..], a1[0..], a2[0..] };
            const B: []const []exec.BindingValue = &.{ b0[0..], b1[0..], b2[0..] };
            const ud = try exec.unionDistinctRows(ally, A, B);
            defer ally.free(ud);
            const ua = try exec.unionAllRows(ally, A, B);
            defer ally.free(ua);
            const ia = try exec.intersectAllRows(ally, A, B);
            defer ally.free(ia);
            const id = try exec.intersectDistinctRows(ally, A, B);
            defer ally.free(id);
            const ea = try exec.exceptAllRows(ally, A, B);
            defer ally.free(ea);
            const ed = try exec.exceptDistinctRows(ally, A, B);
            defer ally.free(ed);
            const w = (if (builtin.os.tag == .windows) std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable } else std.fs.File{ .handle = std.posix.STDOUT_FILENO }).deprecatedWriter();
            try w.print("demo-setops:\n  A = 3 rows, B = 3 rows\n", .{});
            try w.print("  UNION ALL: {d} rows (stable-left)\n", .{ua.len});
            try w.print("  UNION DISTINCT: {d} rows (sorted)\n", .{ud.len});
            try w.print("  INTERSECT ALL: {d} rows (stable-left)\n", .{ia.len});
            try w.print("  INTERSECT DISTINCT: {d} rows (sorted)\n", .{id.len});
            try w.print("  EXCEPT ALL: {d} rows (stable-left)\n", .{ea.len});
            try w.print("  EXCEPT DISTINCT: {d} rows (sorted)\n", .{ed.len});
        } else if (bench_setops) {
            // Tiny microbenchmark: UNION DISTINCT on synthetic data and optimized path
            // P2-3: Use main GPA instead of page_allocator
            const ally = gpa;
            const N: usize = 10_000;
            var a_rows = try ally.alloc([]const exec.BindingValue, N);
            defer ally.free(a_rows);
            var b_rows = try ally.alloc([]const exec.BindingValue, N);
            defer ally.free(b_rows);
            var i: usize = 0;
            while (i < N) : (i += 1) {
                // Mix of ints and strings to stress sorting/hashing
                const bv: exec.BindingValue = if ((i % 4) == 0) .{ .Int = @intCast(i) } else .{ .Str = "s" };
                a_rows[i] = &.{bv};
                b_rows[i] = &.{if ((i % 5) == 0) .{ .Int = @intCast(i) } else .{ .Str = "t" }};
            }
            const t0 = std.time.nanoTimestamp();
            const ud1 = try exec.unionDistinctRows(ally, a_rows, b_rows);
            defer ally.free(ud1);
            const t1 = std.time.nanoTimestamp();
            const ud2 = try exec.unionDistinctRowsOptimized(ally, a_rows, b_rows, exec.SetOpsTuning.union_distinct_hash_threshold);
            defer ally.free(ud2);
            const t2 = std.time.nanoTimestamp();
            const w = (if (builtin.os.tag == .windows) std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable } else std.fs.File{ .handle = std.posix.STDOUT_FILENO }).deprecatedWriter();
            try w.print("bench-setops: N={d}\n  unionDistinctRows    => {d} ns\n  unionDistinct(opt)   => {d} ns\n  same cardinality?     {s}\n", .{ N, t1 - t0, t2 - t1, if (ud1.len == ud2.len) "yes" else "no" });
        } else if (bench_eval) {
            // Micro-bench: regex =~ and IN/NOT IN evaluation
            // P2-3: Use main GPA instead of page_allocator
            const ally = gpa;
            const w = (if (builtin.os.tag == .windows) std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable } else std.fs.File{ .handle = std.posix.STDOUT_FILENO }).deprecatedWriter();
            // Regex benchmark
            const samples = [_][]const u8{ "Alice.", "Bob", "Carol123", "Z", "Alic", "Alice." };
            const pats = [_][]const u8{ "^A.*$", "A[il]ice\\.", "^[^B].*$", "Z?$", "Al?ice\\." };
            const R: usize = 50_000;
            var cnt: usize = 0;
            const t0 = std.time.nanoTimestamp();
            var i: usize = 0;
            while (i < R) : (i += 1) {
                const s = samples[i % samples.len];
                const p = pats[i % pats.len];
                if (eval.matchSimplePattern(s, p)) cnt += 1;
            }
            const t1 = std.time.nanoTimestamp();
            try w.print("bench-eval: regex =~ R={d} -> {d} matches in {d} ns\n", .{ R, cnt, t1 - t0 });
            // IN/NOT IN benchmark using evaluator
            const names = &.{ "a", "s" };
            const env = eval.Env{ .names = names, .values = &.{ .{ .Int = 42 }, .{ .Str = "42" } }, .allocator = ally };
            var a_ident = ast.Expr{ .Ident = .{ .orig = "a", .cnf = "A" } };
            var lit41 = ast.Expr{ .String = "41" };
            var lit42 = ast.Expr{ .String = "42" };
            var lit43 = ast.Expr{ .Int = 43 };
            var arr: [3]*ast.Expr = .{ &lit41, &lit42, &lit43 };
            const inx = ast.Expr{ .In = .{ .value = &a_ident, .set = arr[0..] } };
            const ninx = ast.Expr{ .NotIn = .{ .value = &a_ident, .set = arr[0..] } };
            const R2: usize = 100_000;
            var t_in: usize = 0;
            var t_nin: usize = 0;
            var j: usize = 0;
            // IN loop
            const ta0 = std.time.nanoTimestamp();
            while (j < R2) : (j += 1) {
                const v: eval.Value = eval.evalExpr(ally, inx, env) catch eval.Value{ .Null = {} };
                if (v == .Bool and v.Bool) t_in += 1;
            }
            const ta1 = std.time.nanoTimestamp();
            // NOT IN loop
            j = 0;
            const tb0 = std.time.nanoTimestamp();
            while (j < R2) : (j += 1) {
                const v: eval.Value = eval.evalExpr(ally, ninx, env) catch eval.Value{ .Null = {} };
                if (v == .Bool and v.Bool) t_nin += 1;
            }
            const tb1 = std.time.nanoTimestamp();
            try w.print("bench-eval: IN R={d} -> {d} trues in {d} ns; NOT IN -> {d} trues in {d} ns\n", .{ R2, t_in, ta1 - ta0, t_nin, tb1 - tb0 });
        } else if (demo_eval) {
            // Demo: evaluate WHERE and RETURN using the evaluator over a small synthetic rowset {a:int, s:str}
            // P2-3: Use main GPA instead of page_allocator
            const ally = gpa;

            // GAP-004: Initialize Time-Series Store
            var ts_store = gql.timeseries.Store.init(ally);
            defer ts_store.deinit();

            if (res.program.statements.len == 0) {
                std.debug.print("demo-eval: no statements in file\n", .{});
                return;
            }
            const st = res.program.statements[0];
            switch (st) {
                .Query => |q| {
                    const names = &.{ "a", "s" };
                    const w = (if (builtin.os.tag == .windows) std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable } else std.fs.File{ .handle = std.posix.STDOUT_FILENO }).deprecatedWriter();
                    const pr = gql.printer;
                    if (q.group_by != null) {
                        // Validate GROUP BY semantics first; surface diagnostics
                        // P2-3: Pass allocator to planQuery
                        _ = planner.planQuery(ally, q, .{}) catch |e| {
                            std.debug.print("demo-eval(grouped): planner error {s}\n", .{@errorName(e)});
                            return;
                        };
                        // Run grouped executor on a tiny table of (a:int, s:str)
                        var r0 = [_]eval.Value{ .{ .Int = -1 }, .{ .Str = "Alice" } };
                        var r1 = [_]eval.Value{ .{ .Int = 0 }, .{ .Str = "Bob" } };
                        var r2 = [_]eval.Value{ .{ .Int = 1 }, .{ .Str = "Alice" } };
                        var r3 = [_]eval.Value{ .{ .Null = {} }, .{ .Str = "Carol" } };
                        var r4 = [_]eval.Value{ .{ .Int = 2 }, .{ .Null = {} } };
                        const rows: []const []eval.Value = &.{ r0[0..], r1[0..], r2[0..], r3[0..], r4[0..] };
                        // GAP-004: Pass ts_store to executor
                        const out = exec.runGroupedQuery(ally, q, names, rows, param_names.items, param_values.items, null, &ts_store) catch |e| {
                            std.debug.print("demo-eval(grouped): error {s}\n", .{@errorName(e)});
                            return;
                        };
                        defer ally.free(out);
                        // Header from RETURN
                        try w.print("demo-eval(grouped): projected RETURN columns\n", .{});
                        for (q.ret.items, 0..) |it, i| {
                            const label = blk: {
                                if (it.alias) |al| break :blk al;
                                const s = pr.stringifyExprAlloc(ally, it.expr, .{}) catch "";
                                defer if (s.len > 0) ally.free(s);
                                break :blk if (s.len > 0) s else "expr";
                            };
                            if (i > 0) try w.print("\t", .{});
                            try w.print("{s}", .{label});
                        }
                        try w.print("\n", .{});
                        for (out) |r| {
                            for (r, 0..) |v, j| {
                                if (j > 0) try w.print("\t", .{});
                                switch (v) {
                                    .Null => try w.print("NULL", .{}),
                                    .Int => |n| try w.print("{d}", .{n}),
                                    .Bool => |b| try w.print("{s}", .{if (b) "true" else "false"}),
                                    .Str => |sval| try w.print("\"{s}\"", .{sval}),
                                    .Decimal => |_| try w.print("<dec>", .{}),
                                    .List => |_| try w.print("<list>", .{}),
                                    // GAP-0045: Handle complex graph types in output
                                    .Node => |_| try w.print("<node>", .{}),
                                    .Edge => |_| try w.print("<edge>", .{}),
                                    .Path => |_| try w.print("<path>", .{}),
                                    .Map => |_| try w.print("<map>", .{}),
                                    .ExtValue => |_| try w.print("<ext>", .{}),
                                }
                            }
                            try w.print("\n", .{});
                        }
                    } else {
                        // Original flat evaluator demo
                        const Avals = [_]eval.Value{ .{ .Int = -1 }, .{ .Int = 0 }, .{ .Int = 1 }, .{ .Null = {} }, .{ .Int = 2 } };
                        const Svals = [_]eval.Value{ .{ .Str = "Alice" }, .{ .Str = "Bob" }, .{ .Str = "" }, .{ .Str = "Carol" }, .{ .Null = {} } };
                        try w.print("demo-eval: rows where WHERE predicate (if present) holds; columns are RETURN items.\n", .{});
                        try w.print("row\t", .{});
                        for (q.ret.items, 0..) |it, i| {
                            const label = blk: {
                                if (it.alias) |al| break :blk al;
                                const s = pr.stringifyExprAlloc(ally, it.expr, .{}) catch "";
                                defer if (s.len > 0) ally.free(s);
                                break :blk if (s.len > 0) s else "expr";
                            };
                            if (i > 0) try w.print("\t", .{});
                            try w.print("{s}", .{label});
                        }
                        try w.print("\n", .{});
                        var i: usize = 0;
                        while (i < Avals.len and i < Svals.len) : (i += 1) {
                            const env = eval.Env{ .names = names, .values = &.{ Avals[i], Svals[i] }, .param_names = param_names.items, .param_values = param_values.items, .allocator = ally, .timeseries_store = &ts_store };
                            var pass = true;
                            if (q.where_clause) |wc| {
                                const v = eval.evalExpr(ally, wc, env) catch |e| {
                                    if (diagnostics.mapEvalError(e)) |code| {
                                        try w.print("diagnostic: {s} (eval WHERE on row {d})\n", .{ diagnostics.codeName(code), i });
                                    } else {
                                        try w.print("error evaluating WHERE on row {d}: {s}\n", .{ i, @errorName(e) });
                                    }
                                    continue;
                                };
                                pass = (v == .Bool and v.Bool);
                            }
                            if (!pass) continue;
                            try w.print("{d}\t", .{i});
                            for (q.ret.items, 0..) |it, j| {
                                const v = eval.evalExpr(ally, it.expr, env) catch |e| {
                                    if (diagnostics.mapEvalError(e)) |code| {
                                        try w.print("<diag:{s}>", .{diagnostics.codeName(code)});
                                    } else {
                                        try w.print("<err:{s}>", .{@errorName(e)});
                                    }
                                    continue;
                                };
                                if (j > 0) try w.print("\t", .{});
                                switch (v) {
                                    .Null => try w.print("NULL", .{}),
                                    .Int => |n| try w.print("{d}", .{n}),
                                    .Bool => |b| try w.print("{s}", .{if (b) "true" else "false"}),
                                    .Str => |sval| try w.print("\"{s}\"", .{sval}),
                                    .Decimal => |_| try w.print("<dec>", .{}),
                                    .List => |_| try w.print("<list>", .{}),
                                    .Node => |_| try w.print("<node>", .{}),
                                    .Edge => |_| try w.print("<edge>", .{}),
                                    .Map => |_| try w.print("<map>", .{}),
                                    .ExtValue => |_| try w.print("<extvalue>", .{}),
                                    .Path => |_| try w.print("<path>", .{}),
                                    else => try w.print("<unknown>", .{}),
                                }
                            }
                            try w.print("\n", .{});
                        }
                    }
                },
                else => {
                    std.debug.print("demo-eval: first statement is not a Query\n", .{});
                },
            }
        } else if (demo_diagnostics) {
            // Demo: run planner and print diagnostic codes on errors
            if (res.program.statements.len == 0) {
                std.debug.print("demo-diagnostics: no statements in file\n", .{});
                return;
            }
            const st = res.program.statements[0];
            switch (st) {
                .Query => |q| {
                    // P2-3: Pass allocator to planQuery
                    const plan = planner.planQuery(gpa, q, .{ .attempt_pushdown = true }) catch |e| {
                        if (diagnostics.mapPlannerError(e)) |code| {
                            std.debug.print("diagnostic: {s} ({s})\n", .{ diagnostics.codeName(code), @errorName(e) });
                        } else {
                            std.debug.print("planner error: {s}\n", .{@errorName(e)});
                        }
                        return;
                    };
                    _ = plan;
                    std.debug.print("no diagnostics (planning succeeded)\n", .{});
                },
                else => std.debug.print("demo-diagnostics: first statement is not a Query\n", .{}),
            }
        } else if (demo_agg) {
            // Demo: run GROUP BY aggregates over a tiny synthetic table (name:str, val:int|null)
            if (res.program.statements.len == 0) {
                std.debug.print("demo-agg: no statements in file\n", .{});
                return;
            }
            const st = res.program.statements[0];
            switch (st) {
                .Query => |q| {
                    if (q.group_by == null) {
                        std.debug.print("demo-agg: query has no GROUP BY\n", .{});
                        return;
                    }
                    // Build Agg list from RETURN items and HAVING (COUNT/COUNT(*), SUM/MIN/MAX/AVG); numeric args operate on column index 1 (val)
                    // GAP-0220 FIX: Use try for proper error propagation
                    var aggs = try std.ArrayList(exec.Agg).initCapacity(gpa, 0);
                    defer aggs.deinit(gpa);
                    // GAP-0220 FIX: Use try for proper error propagation
                    var v_idxs = try std.ArrayList(usize).initCapacity(gpa, 0);
                    defer v_idxs.deinit(gpa);
                    // Header labels
                    var labels = std.ArrayList([]const u8).initCapacity(gpa, 0) catch @panic("OOM");
                    defer labels.deinit(gpa);
                    // Collect aggregates helper
                    const addAggFromCall = struct {
                        fn go(ally_inner: std.mem.Allocator, aggs_out: *std.ArrayList(exec.Agg), v_idxs_out: *std.ArrayList(usize), labels_out: *std.ArrayList([]const u8), call_expr: ast.Expr) void {
                            if (call_expr != .Call) return;
                            const c = call_expr.Call;
                            switch (c.callee.*) {
                                .Ident => |id| {
                                    if (std.ascii.eqlIgnoreCase(id.orig, "count")) {
                                        if (c.args.len == 0) {
                                            aggs_out.append(ally_inner, .CountStar) catch {};
                                            v_idxs_out.append(ally_inner, 0) catch {};
                                            labels_out.append(ally_inner, "COUNT(*)") catch {};
                                        } else {
                                            aggs_out.append(ally_inner, .Count) catch {};
                                            v_idxs_out.append(ally_inner, 1) catch {};
                                            labels_out.append(ally_inner, "COUNT") catch {};
                                        }
                                    } else if (std.ascii.eqlIgnoreCase(id.orig, "sum")) {
                                        aggs_out.append(ally_inner, .Sum) catch {};
                                        v_idxs_out.append(ally_inner, 1) catch {};
                                        labels_out.append(ally_inner, "SUM") catch {};
                                    } else if (std.ascii.eqlIgnoreCase(id.orig, "min")) {
                                        aggs_out.append(ally_inner, .Min) catch {};
                                        v_idxs_out.append(ally_inner, 1) catch {};
                                        labels_out.append(ally_inner, "MIN") catch {};
                                    } else if (std.ascii.eqlIgnoreCase(id.orig, "max")) {
                                        aggs_out.append(ally_inner, .Max) catch {};
                                        v_idxs_out.append(ally_inner, 1) catch {};
                                        labels_out.append(ally_inner, "MAX") catch {};
                                    } else if (std.ascii.eqlIgnoreCase(id.orig, "avg")) {
                                        aggs_out.append(ally_inner, .Avg) catch {};
                                        v_idxs_out.append(ally_inner, 1) catch {};
                                        labels_out.append(ally_inner, "AVG") catch {};
                                    }
                                },
                                else => {},
                            }
                        }
                    }.go;
                    for (q.ret.items) |it| switch (it.expr) {
                        .Call => |_| addAggFromCall(gpa, &aggs, &v_idxs, &labels, it.expr),
                        else => {},
                    };
                    if (q.having) |hv| {
                        // Walk HAVING and add any missing aggregates
                        const walk = struct {
                            fn go(ally_inner: std.mem.Allocator, aggs_out: *std.ArrayList(exec.Agg), v_idxs_out: *std.ArrayList(usize), labels_out: *std.ArrayList([]const u8), e: ast.Expr) void {
                                switch (e) {
                                    .Call => |_| addAggFromCall(ally_inner, aggs_out, v_idxs_out, labels_out, e),
                                    .Unary => |u| go(ally_inner, aggs_out, v_idxs_out, labels_out, u.expr.*),
                                    .Binary => |b| {
                                        go(ally_inner, aggs_out, v_idxs_out, labels_out, b.left.*);
                                        go(ally_inner, aggs_out, v_idxs_out, labels_out, b.right.*);
                                    },
                                    else => {},
                                }
                            }
                        }.go;
                        walk(gpa, &aggs, &v_idxs, &labels, hv);
                    }
                    if (aggs.items.len == 0) {
                        // Default to COUNT if none present
                        try aggs.append(gpa, .CountStar);
                        try v_idxs.append(gpa, 0);
                        try labels.append(gpa, "COUNT(*)");
                    }
                    const spec = exec.GroupSpec{ .key_idxs = &.{0}, .aggs = aggs.items };
                    // Sample rows: (name, val)
                    var r0 = [_]exec.BindingValue{ .{ .Str = "a" }, .{ .Int = 1 } };
                    var r1 = [_]exec.BindingValue{ .{ .Str = "a" }, .{ .Int = 2 } };
                    var r2 = [_]exec.BindingValue{ .{ .Str = "b" }, .{ .Null = {} } };
                    const rows: []const []exec.BindingValue = &.{ r0[0..], r1[0..], r2[0..] };
                    const out_rows = exec.groupAndAggregate(gpa, rows, spec, v_idxs.items) catch |e| {
                        std.debug.print("demo-agg: runtime error: {s}\n", .{@errorName(e)});
                        return;
                    };
                    defer gpa.free(out_rows);
                    // Prepare HAVING evaluation: build maps (group key -> index, agg signature -> rel index)
                    var key_map = std.StringHashMap(usize).init(gpa);
                    defer key_map.deinit();
                    // For demo, single key at index 0 corresponds to the actual GROUP BY key expr string
                    // We stringify the first GROUP BY key for mapping
                    const pr = gql.printer;
                    const gb_key_s = pr.stringifyExprAlloc(gpa, q.group_by.?.keys[0], .{}) catch "";
                    defer if (gb_key_s.len > 0) gpa.free(gb_key_s);
                    if (gb_key_s.len > 0) {
                        _ = key_map.put(gb_key_s, 0) catch {};
                    }
                    var agg_map = std.StringHashMap(usize).init(gpa);
                    defer agg_map.deinit();
                    // Build mapping for each aggregate in the spec
                    var ai: usize = 0;
                    while (ai < aggs.items.len) : (ai += 1) {
                        const a = aggs.items[ai];
                        // GAP-0220 FIX: Use try for proper error propagation
                        var sig_buf = try std.ArrayList(u8).initCapacity(gpa, 0);
                        defer sig_buf.deinit(gpa);
                        switch (a) {
                            .CountStar => {
                                try sig_buf.appendSlice(gpa, "count(*)");
                            },
                            .Count => {
                                try sig_buf.appendSlice(gpa, "count(");
                                try sig_buf.appendSlice(gpa, gb_key_s);
                                try sig_buf.append(gpa, ')');
                            },
                            .CountDistinct => {
                                // Demo harness does not yet distinguish argument; reuse group key for signature context.
                                try sig_buf.appendSlice(gpa, "countdistinct(");
                                try sig_buf.appendSlice(gpa, gb_key_s);
                                try sig_buf.append(gpa, ')');
                            },
                            .Sum => {
                                try sig_buf.appendSlice(gpa, "sum(");
                                try sig_buf.appendSlice(gpa, gb_key_s);
                                try sig_buf.append(gpa, ')');
                            },
                            .Min => {
                                try sig_buf.appendSlice(gpa, "min(");
                                try sig_buf.appendSlice(gpa, gb_key_s);
                                try sig_buf.append(gpa, ')');
                            },
                            .Max => {
                                try sig_buf.appendSlice(gpa, "max(");
                                try sig_buf.appendSlice(gpa, gb_key_s);
                                try sig_buf.append(gpa, ')');
                            },
                            .Avg => {
                                try sig_buf.appendSlice(gpa, "avg(");
                                try sig_buf.appendSlice(gpa, gb_key_s);
                                try sig_buf.append(gpa, ')');
                            },
                        }
                        _ = agg_map.put(sig_buf.items, ai) catch {};
                    }
                    // Print header
                    const w = (if (builtin.os.tag == .windows) std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable } else std.fs.File{ .handle = std.posix.STDOUT_FILENO }).deprecatedWriter();
                    try w.print("demo-agg: groups over (name, val)\n", .{});
                    try w.print("group\t", .{});
                    for (labels.items, 0..) |lab, i| {
                        if (i > 0) try w.print("\t", .{});
                        try w.print("{s}", .{lab});
                    }
                    try w.print("\n", .{});
                    // Emit rows with HAVING evaluation by rewriting expression
                    for (out_rows) |r| {
                        if (q.having) |hv| {
                            const rewritten = exec.rewriteExprWithAggregates(gpa, hv, &key_map, &agg_map, r, spec.key_idxs.len) catch ast.Expr{ .Null = {} };
                            const v = eval.evalExpr(
                                gpa,
                                rewritten,
                                eval.Env{ .names = &.{}, .values = &.{}, .param_names = &.{}, .param_values = &.{}, .allocator = gpa },
                            ) catch eval.Value{ .Null = {} };
                            if (!(v == .Bool and v.Bool)) continue;
                        }
                        // key
                        switch (r[0]) {
                            .Str => |sname| try w.print("{s}", .{sname}),
                            else => try w.print("(?)", .{}),
                        }
                        // aggs
                        var a: usize = 0;
                        while (a < aggs.items.len) : (a += 1) {
                            const v = r[spec.key_idxs.len + a];
                            try w.print("\t", .{});
                            switch (v) {
                                .Null => try w.print("NULL", .{}),
                                .Int => |n| try w.print("{d}", .{n}),
                                .List => |_| try w.print("<list>", .{}),
                                .Decimal => |d| {
                                    const abs: i128 = if (d.coeff < 0) -d.coeff else d.coeff;
                                    var scale_p: i128 = 1;
                                    var i: u8 = 0;
                                    while (i < d.scale) : (i += 1) scale_p *= 10;
                                    const whole = @divTrunc(abs, scale_p);
                                    const frac = @mod(abs, scale_p);
                                    if (d.scale == 0) {
                                        if (d.coeff < 0) try w.print("-{d}", .{whole}) else try w.print("{d}", .{whole});
                                    } else {
                                        var fb_buf: [64]u8 = undefined;
                                        var fbi: usize = 0;
                                        var tmp = frac;
                                        // write fractional digits in reverse
                                        var k: u8 = 0;
                                        while (k < d.scale) : (k += 1) {
                                            const digit: u8 = @intCast(@mod(tmp, 10));
                                            fb_buf[fbi] = digit + '0';
                                            fbi += 1;
                                            tmp = @divTrunc(tmp, 10);
                                        }
                                        // reverse to correct order
                                        var j: usize = 0;
                                        var t: u8 = 0;
                                        while (j < fbi / 2) : (j += 1) {
                                            t = fb_buf[j];
                                            fb_buf[j] = fb_buf[fbi - 1 - j];
                                            fb_buf[fbi - 1 - j] = t;
                                        }
                                        if (d.coeff < 0) try w.print("-{d}.{s}", .{ whole, fb_buf[0..fbi] }) else try w.print("{d}.{s}", .{ whole, fb_buf[0..fbi] });
                                    }
                                },
                                .Str => |sval| try w.print("\"{s}\"", .{sval}),
                                .Bool => |b| try w.print("{s}", .{if (b) "true" else "false"}),
                                // GAP-0045: Handle complex graph types in aggregate output
                                .Node => |_| try w.print("<node>", .{}),
                                .Edge => |_| try w.print("<edge>", .{}),
                                .Path => |_| try w.print("<path>", .{}),
                                .Map => |_| try w.print("<map>", .{}),
                                .ExtValue => |_| try w.print("<ext>", .{}),
                            }
                        }
                        try w.print("\n", .{});
                    }
                },
                else => std.debug.print("demo-agg: first statement is not a Query\n", .{}),
            }
        } else {
            std.debug.print("{any}\n", .{res.program});
        }
    }
}
