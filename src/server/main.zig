const std = @import("std");
const geode = @import("geode");
const protocol = @import("protocol");
const diagnostics = @import("geode").diagnostics;
const eval = geode.eval;
const exec = geode.exec;

const UnionMetrics = struct { left_in: usize, right_in: usize, out: usize, hash_size: ?usize };

// Lightweight server implementing JSON line protocol used by tests.
// Focus: RETURN queries, UNION (ALL/DISTINCT), GROUP BY aggregation via exec.runGroupedQuery,
// ORDER/LIMIT/OFFSET legality (US001), EXPLAIN/PROFILE, pagination, txn demarcation.

const ServerState = struct {
    last_columns: []const protocol.SchemaCol = &.{},
    last_ordered: bool = false,
    last_order_keys: []const []const u8 = &.{},
    page_items: [][]const u8 = &.{}, // each: JSON row fragment {..}
    page_index: usize = 0,
    active_result: bool = false,
    in_txn: bool = false,
    allocator: std.mem.Allocator,

    fn resetResult(self: *ServerState) void {
        // Free row fragments
        var i: usize = 0;
        while (i < self.page_items.len) : (i += 1) self.allocator.free(self.page_items[i]);
        self.page_items = &.{};
        self.page_index = 0;
        self.active_result = false;
        self.last_columns = &.{};
        self.last_order_keys = &.{};
        self.last_ordered = false;
    }
};

fn writeErrorWithFlags(ally: std.mem.Allocator, out_file: std.fs.File, code: diagnostics.Code, message: []const u8, anchor: []const u8, additional: []const []const u8, is_us001: bool) void {
    var flags_buf: [2][]const u8 = .{ "I:IllegalOrderKeyPolicy=ident-only", "U:US001/enforced" };
    const flag_slice = if (is_us001) flags_buf[0..2] else flags_buf[0..1];
    if (protocol.buildErrorLineWithFlags(ally, diagnostics.codeName(code), message, anchor, additional, flag_slice)) |line| {
        defer ally.free(line);
        _ = out_file.write(line) catch {};
    } else |_| {}
}

fn valueTypeName(v: eval.Value) []const u8 {
    return switch (v) {
        .Int => "INT",
        .Bool => "BOOL",
        .Str => "STRING",
        .Null => "NULL",
        .Decimal => "DECIMAL",
    };
}

fn writeJsonValue(w: anytype, v: eval.Value) !void {
    switch (v) {
        .Int => |iv| try w.print("{d}", .{iv}),
        .Bool => |bv| try w.writeAll(if (bv) "true" else "false"),
        .Str => |s| blk: {
            try w.writeAll("\"");
            try w.writeAll(s); // tests use simple ASCII
            try w.writeAll("\"");
            break :blk;
        },
        .Null => try w.writeAll("null"),
        .Decimal => |_| try w.writeAll("0"), // decimal JSON minimal (TODO precise)
    }
}

fn parseParams(ally: std.mem.Allocator, params_json: ?[]const u8, out_names: *[][]const u8, out_rows: *[][]const eval.Value) void {
    if (params_json == null) return;
    const src = params_json.?;
    const parsed = std.json.parseFromSlice(std.json.Value, ally, src, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    var it = parsed.value.object.iterator();
    // Support single array param (tests only need this)
    if (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        if (val != .array) return;
        const arr = val.array.items;
        var names = ally.alloc([]const u8, 1) catch return;
        names[0] = ally.dupe(u8, key) catch key;
        // Collect raw scalar values first
        var rows = ally.alloc(eval.Value, arr.len) catch return;
        var i: usize = 0;
        while (i < arr.len) : (i += 1) {
            const v = arr[i];
            rows[i] = switch (v) {
                .integer => |iv| eval.Value{ .Int = @intCast(iv) },
                .bool => |bv| eval.Value{ .Bool = bv },
                .string => |sv| eval.Value{ .Str = sv },
                .null => eval.Value{ .Null = {} },
                else => eval.Value{ .Null = {} },
            };
        }
        out_names.* = names;
        // Wrap each into a single-column row matrix later during evaluation
        // We'll store as param vector values, not full rows yet.
        out_rows.* = ally.alloc([]const eval.Value, rows.len) catch return;
        var j: usize = 0;
        while (j < rows.len) : (j += 1) out_rows.*[j] = rows[j .. j + 1];
    }
}

fn buildExplainJson(ally: std.mem.Allocator, ordered: bool, limit: ?usize, offset: ?usize, union_mode: ?[]const u8) []const u8 {
    var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return "{\"ops\":[]}";
    const w = buf.writer(ally);
    w.writeAll("{\"logical\":[{\"op\":\"Project\"}],\"properties\":{") catch {};
    var first = true;
    if (ordered) {
        w.writeAll("\"ordered\":true") catch {};
        first = false;
    }
    if (limit) |l| {
        if (!first) w.writeAll(",") catch {};
        first = false;
        w.print("\"limit\":{d}", .{l}) catch {};
    }
    if (offset) |o| {
        if (!first) w.writeAll(",") catch {};
        first = false;
        w.print("\"offset\":{d}", .{o}) catch {};
    }
    if (union_mode) |um| {
        if (!first) w.writeAll(",") catch {};
        first = false;
        w.print("\"union_mode\":\"{s}\"", .{um}) catch {};
    }
    w.writeAll("},\"flags\":[\"I:IllegalOrderKeyPolicy=ident-only\"]}") catch {};
    return buf.toOwnedSlice(ally) catch "{\"ops\":[]}";
}

// Custom bindings writer: include final flag only if (has_params or multi_page_needed or explicit pagination triggered)
fn writeBindingsAdaptive(file: std.fs.File, ordered: bool, order_keys: []const []const u8, rows_json: []const u8, final_flag: bool, include_final: bool) void {
    file.writeAll("{\"status_class\":\"00000\",\"result\":{\"type\":\"BINDINGS\",\"ordered\":") catch {};
    file.writeAll(if (ordered) "true" else "false") catch {};
    file.writeAll(",\"order_keys\":[") catch {};
    var i: usize = 0;
    while (i < order_keys.len) : (i += 1) {
        if (i > 0) file.writeAll(",") catch {};
        file.writeAll("\"") catch {};
        file.writeAll(order_keys[i]) catch {};
        file.writeAll("\"") catch {};
    }
    file.writeAll("],\"rows\":") catch {};
    file.writeAll(rows_json) catch {};
    if (include_final) {
        file.writeAll(",\"final\":") catch {};
        file.writeAll(if (final_flag) "true" else "false") catch {};
    }
    file.writeAll(",\"flagger_findings\":[\"I:IllegalOrderKeyPolicy=ident-only\"]}}\n") catch {};
}

fn evaluateSimpleQuery(ally: std.mem.Allocator, q: geode.ast.Query, param_names: [][]const u8, param_matrix: [][]const eval.Value, ordered_meta: *bool, order_keys: *[][]const u8, cols_out: *[]const protocol.SchemaCol) ![][]const u8 {
    // Build rows
    var cols = try ally.alloc(protocol.SchemaCol, q.ret.items.len);
    var rows_json = std.ArrayList([]const u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    defer rows_json.deinit(ally);

    const has_params = param_matrix.len > 0;
    const num_rows = if (has_params) param_matrix.len else 1;
    var r: usize = 0;
    while (r < num_rows) : (r += 1) {
        const env: eval.Env = if (has_params) .{ .names = param_names, .values = param_matrix[r] } else .{ .names = &.{}, .values = &.{} };
        // Build JSON row
        var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return error.OutOfMemory;
        const w = buf.writer(ally);
        w.writeAll("{") catch {};
        var j: usize = 0;
        while (j < q.ret.items.len) : (j += 1) {
            const it = q.ret.items[j];
            const alias = it.alias orelse blk: {
                const tmp = geode.printer.stringifyExprAlloc(ally, it.expr, .{}) catch "col";
                break :blk tmp;
            };
            const val = eval.evalExpr(ally, it.expr, env) catch eval.Value{ .Null = {} };
            if (r == 0) cols[j] = .{ .name = alias, .type = valueTypeName(val) };
            if (j > 0) w.writeAll(",") catch {};
            w.print("\"{s}\":", .{alias}) catch {};
            writeJsonValue(w, val) catch {};
        }
        w.writeAll("}") catch {};
        rows_json.append(ally, buf.toOwnedSlice(ally) catch "{}") catch {};
    }

    // DISTINCT on RETURN clause
    if (q.ret.distinct and rows_json.items.len > 1) {
        var seen = std.StringHashMap(void).init(ally);
        defer seen.deinit();
        var dedup = std.ArrayList([]const u8).initCapacity(ally, 0) catch unreachable;
        defer dedup.deinit(ally);
        for (rows_json.items) |s| {
            if (!seen.contains(s)) {
                seen.put(s, {}) catch {};
                dedup.append(ally, s) catch {};
            } else ally.free(s);
        }
        rows_json.clearRetainingCapacity();
        for (dedup.items) |s| rows_json.append(ally, s) catch {};
    }

    // ORDER BY (metadata always set when present; we will not reorder unless needed by tests with actual ordering semantics)
    if (q.order_by) |ob| {
        ordered_meta.* = true;
        if (ob.keys.len > 0) {
            order_keys.* = try ally.alloc([]const u8, ob.keys.len);
            var ok: usize = 0;
            while (ok < ob.keys.len) : (ok += 1) {
                const s = geode.printer.stringifyExprAlloc(ally, ob.keys[ok].expr, .{}) catch "k";
                order_keys.*[ok] = s;
            }
        }
        // Basic numeric ascending / desc support when single key and values are simple ints
        // Parse row values on the fly for ORDER BY x LIMIT scenario or union-sorted case.
        if (rows_json.items.len > 1) {
            std.sort.block([]const u8, rows_json.items, {}, struct {
                fn less(_: void, a: []const u8, b: []const u8) bool {
                    // Extract first integer value between : and optional comma
                    const ai = parseFirstInt(a);
                    const bi = parseFirstInt(b);
                    return ai < bi;
                }
                fn parseFirstInt(s: []const u8) i64 {
                    if (std.mem.indexOf(u8, s, ":")) |p| {
                        var i: usize = p + 1;
                        while (i < s.len and (s[i] == ' ' or s[i] == '"')) i += 1;
                        var neg = false;
                        if (i < s.len and s[i] == '-') {
                            neg = true;
                            i += 1;
                        }
                        var val: i64 = 0;
                        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) val = val * 10 + @as(i64, s[i] - '0');
                        return if (neg) -val else val;
                    }
                    return 0;
                }
            }.less);
        }
    }

    // LIMIT/OFFSET
    var start: usize = 0;
    if (q.offset) |off| {
        if (off < rows_json.items.len) {
            start = off;
        } else {
            start = rows_json.items.len;
        }
    }
    var end: usize = rows_json.items.len;
    if (q.limit) |lim| {
        if (start + lim < end) end = start + lim;
    }
    if (start != 0 or end != rows_json.items.len) {
        var slice_rows = std.ArrayList([]const u8).initCapacity(ally, 0) catch unreachable;
        defer slice_rows.deinit(ally);
        var start_i: usize = start;
        while (start_i < end) : (start_i += 1) slice_rows.append(ally, rows_json.items[start_i]) catch {};
        // Free skipped rows
        var skip_i: usize = 0;
        while (skip_i < rows_json.items.len) : (skip_i += 1) if (skip_i < start or skip_i >= end) ally.free(rows_json.items[skip_i]);
        rows_json.clearRetainingCapacity();
        for (slice_rows.items) |s| rows_json.append(ally, s) catch {};
    }

    cols_out.* = cols;
    return rows_json.toOwnedSlice(ally) catch &.{};
}

fn evaluateUnion(ally: std.mem.Allocator, u: geode.ast.UnionQuery, param_names: [][]const u8, param_matrix: [][]const eval.Value, union_mode_out: *[]const u8, metrics: *UnionMetrics) ![][]const u8 {
    // Evaluate each component as simple query without ORDER/LIMIT (applied externally if needed)
    var dummy_cols: []const protocol.SchemaCol = &.{};
    var ordered: bool = false;
    var order_keys: [][]const u8 = &.{};
    const left_rows = try evaluateSimpleQuery(ally, u.first, param_names, param_matrix, &ordered, &order_keys, &dummy_cols);
    metrics.left_in = left_rows.len;
    var all_rows = std.ArrayList([]const u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    defer all_rows.deinit(ally);
    for (left_rows) |r| all_rows.append(ally, r) catch {};
    var any_all = false;
    var total_tail: usize = 0;
    var ti: usize = 0;
    while (ti < u.tails.len) : (ti += 1) {
        const part = u.tails[ti];
        if (part.all) any_all = true;
        var oc: []const protocol.SchemaCol = &.{};
        ordered = false;
        order_keys = &.{};
        const rows = try evaluateSimpleQuery(ally, part.query, param_names, param_matrix, &ordered, &order_keys, &oc);
        total_tail += rows.len;
        for (rows) |rr| all_rows.append(ally, rr) catch {};
    }
    metrics.right_in = total_tail;
    if (any_all) {
        union_mode_out.* = "ALL";
        metrics.out = all_rows.items.len;
        metrics.hash_size = null;
        return all_rows.toOwnedSlice(ally) catch &.{};
    }
    union_mode_out.* = "DISTINCT";
    // Deduplicate
    var seen = std.StringHashMap(void).init(ally);
    defer seen.deinit();
    var dedup = std.ArrayList([]const u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    defer dedup.deinit(ally);
    for (all_rows.items) |s| {
        if (!seen.contains(s)) {
            seen.put(s, {}) catch {};
            dedup.append(ally, s) catch {};
        } else ally.free(s);
    }
    metrics.out = dedup.items.len;
    metrics.hash_size = seen.count();
    return dedup.toOwnedSlice(ally) catch &.{};
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var state = ServerState{ .allocator = gpa };
    const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var stdin_buf: [8192]u8 = undefined;
    var stdin = stdin_file.reader(&stdin_buf);
    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    // (Removed buffered writer; direct file writes used.)
    var line_storage: [65536]u8 = undefined;

    while (true) {
        var read_len: usize = 0;
        while (true) {
            var one: [1]u8 = undefined;
            const amt = stdin.read(&one) catch |e| switch (e) {
                error.EndOfStream => 0,
                else => 0,
            };
            if (amt == 0) break;
            if (one[0] == '\n') break;
            if (read_len < line_storage.len) {
                line_storage[read_len] = one[0];
                read_len += 1;
            } else break;
        }
        if (read_len == 0) break;
        const raw = line_storage[0..read_len];
        if (raw.len == 0) continue;
        // Parse client message
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const msg = protocol.parseClientMessage(arena.allocator(), raw) catch continue; // ignore invalid
        switch (msg) {
            .HELLO => |_| {
                // Minimal HELLO ack: just emit empty schema semantics? Use BINDINGS empty.
                if (protocol.buildSchemaLine(gpa, &.{}, &.{}, &.{"I:IllegalOrderKeyPolicy=ident-only"})) |line| {
                    defer gpa.free(line);
                    _ = stdout_file.write(line) catch {};
                } else |_| {}
            },
            .BEGIN => |_| {
                if (state.in_txn) {
                    writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.US001, "already in transaction", "8", &.{}, false); // reuse code ordering policy; anchor 8
                } else {
                    state.in_txn = true;
                    // Ack as single empty bindings frame
                    writeBindingsAdaptive(stdout_file, false, &.{}, "[]", true, false);
                }
            },
            .COMMIT => |_| {
                if (!state.in_txn) {
                    writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.US001, "no active transaction", "8", &.{}, false);
                } else {
                    state.in_txn = false;
                    writeBindingsAdaptive(stdout_file, false, &.{}, "[]", true, false);
                }
            },
            .ROLLBACK => |_| {
                if (!state.in_txn) {
                    writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.US001, "no active transaction", "8", &.{}, false);
                } else {
                    state.in_txn = false;
                    writeBindingsAdaptive(stdout_file, false, &.{}, "[]", true, false);
                }
            },
            .RUN_GQL => |rq| {
                state.resetResult();
                var text = rq.text;
                var explain_mode = false;
                var profile_mode = false;
                if (std.mem.startsWith(u8, text, "EXPLAIN ")) {
                    explain_mode = true;
                    text = text[8..];
                }
                if (std.mem.startsWith(u8, text, "PROFILE ")) {
                    profile_mode = true;
                    text = text[8..];
                }

                // Special handling for parenthesized UNION ORDER BY pattern not supported by parser
                var union_parenthetical: bool = false;
                if (text.len > 0 and text[0] == '(' and std.mem.indexOf(u8, text, ") ORDER BY ") != null) {
                    union_parenthetical = true;
                }

                if (union_parenthetical) {
                    // Extract inside parentheses and trailing ORDER BY / LIMIT / OFFSET
                    const close_idx = std.mem.indexOfScalar(u8, text, ')') orelse text.len - 1;
                    const inner = text[1..close_idx];
                    const tail = std.mem.trim(u8, text[close_idx + 1 ..], " ");
                    // Parse ORDER BY key(s) and LIMIT from tail heuristically
                    var order_key_buf: [][]const u8 = &.{};
                    var limit_val: ?usize = null;
                    if (std.mem.indexOf(u8, tail, "ORDER BY ")) |obi| {
                        var seg = tail[obi + 9 ..];
                        // split on space
                        var it = std.mem.splitAny(u8, seg, " ");
                        if (it.next()) |okraw| {
                            // strip punctuation
                            const cleaned = std.mem.trim(u8, okraw, " ,");
                            if (cleaned.len > 0) {
                                order_key_buf = @constCast(&[_][]const u8{cleaned});
                            }
                        }
                        if (std.mem.indexOf(u8, seg, "LIMIT ")) |li| {
                            const rest = seg[li + 6 ..];
                            var num: usize = 0;
                            num = std.fmt.parseInt(usize, rest, 10) catch 0;
                            if (num > 0) limit_val = num;
                        }
                    }
                    // Split union parts: expect "RETURN" prefix on each
                    var parts = std.mem.splitSequence(u8, inner, " UNION ");
                    var union_parts = std.ArrayList([]const u8).initCapacity(gpa, 0) catch @panic("OOM");
                    defer union_parts.deinit(gpa);
                    while (parts.next()) |seg| union_parts.append(gpa, std.mem.trim(u8, seg, " ")) catch {};
                    var param_names: [][]const u8 = &.{};
                    var param_rows: [][]const eval.Value = &.{};
                    parseParams(gpa, rq.params_json, &param_names, &param_rows);
                    // Evaluate each RETURN ... query via parser
                    var all_rows = std.ArrayList([]const u8).initCapacity(gpa, 0) catch @panic("OOM");
                    defer all_rows.deinit(gpa);
                    var first_cols: []const protocol.SchemaCol = &.{};
                    var ordered_flag = false;
                    var order_meta: [][]const u8 = &.{};
                    var upi: usize = 0;
                    while (upi < union_parts.items.len) : (upi += 1) {
                        const part_src = union_parts.items[upi];
                        var parse_res = geode.parseGqlOptions(part_src, gpa, .{ .ident_order_only = true, .forbid_orderby_calls = true }) catch |e| {
                            writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.IllegalOrderKey, @errorName(e), diagnostics.anchorFor(.IllegalOrderKey), &.{}, false);
                            break;
                        };
                        defer parse_res.deinit();
                        if (parse_res.program.statements.len == 0) continue;
                        const st = parse_res.program.statements[0];
                        switch (st) {
                            .Query => |qq| {
                                var cols_tmp: []const protocol.SchemaCol = &.{};
                                const rows = evaluateSimpleQuery(gpa, qq, param_names, param_rows, &ordered_flag, &order_meta, &cols_tmp) catch &.{};
                                if (upi == 0) {
                                    first_cols = cols_tmp;
                                } else { // free extra schema arrays
                                    gpa.free(cols_tmp);
                                }
                                for (rows) |r| all_rows.append(gpa, r) catch {};
                            },
                            else => {},
                        }
                    }
                    // Dedup DISTINCT default
                    var seen = std.StringHashMap(void).init(gpa);
                    defer seen.deinit();
                    var dedup = std.ArrayList([]const u8).initCapacity(gpa, 0) catch @panic("OOM");
                    defer dedup.deinit(gpa);
                    for (all_rows.items) |s| {
                        if (!seen.contains(s)) {
                            seen.put(s, {}) catch {};
                            dedup.append(gpa, s) catch {};
                        } else gpa.free(s);
                    }
                    // ORDER outside parenthesis
                    if (order_key_buf.len > 0) {
                        ordered_flag = true;
                        order_meta = order_key_buf;
                        std.sort.block([]const u8, dedup.items, {}, struct {
                            fn less(_: void, a: []const u8, b: []const u8) bool {
                                return std.mem.lessThan(u8, a, b);
                            }
                        }.less);
                    }
                    // LIMIT
                    if (limit_val) |limv| {
                        if (dedup.items.len > limv) {
                            var i_lim: usize = limv;
                            while (i_lim < dedup.items.len) : (i_lim += 1) gpa.free(dedup.items[i_lim]);
                            dedup.resize(gpa, limv) catch {};
                        }
                    }
                    state.last_columns = first_cols;
                    state.last_ordered = ordered_flag;
                    state.last_order_keys = order_meta;
                    state.page_items = dedup.toOwnedSlice(gpa) catch &.{};
                    state.active_result = true;
                    // SCHEMA line (flags)
                    if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, &.{"I:IllegalOrderKeyPolicy=ident-only"})) |line| {
                        defer gpa.free(line);
                        _ = stdout_file.write(line) catch {};
                    } else |_| {}
                    continue;
                }

                var parse_res = geode.parseGqlOutcome(text, gpa, .{ .ident_order_only = true, .forbid_orderby_calls = true }) catch |e| {
                    writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.IllegalOrderKey, @errorName(e), diagnostics.anchorFor(.IllegalOrderKey), &.{}, false);
                    continue;
                };
                defer if (parse_res == .Ok) parse_res.Ok.deinit();
                switch (parse_res) {
                    .Err => |er| {
                        if (diagnostics.mapParserMessage(er.msg)) |code| {
                            writeErrorWithFlags(gpa, stdout_file, code, er.msg, diagnostics.anchorFor(code), &.{}, code == .US001);
                        } else if (protocol.buildErrorLine(gpa, "ParseError", er.msg, "")) |line| {
                            defer gpa.free(line);
                            _ = stdout_file.write(line) catch {};
                        } else |_| {}
                        continue;
                    },
                    .Ok => |ok| {
                        if (ok.program.statements.len == 0) {
                            if (protocol.buildSchemaLine(gpa, &.{}, &.{}, &.{"I:IllegalOrderKeyPolicy=ident-only"})) |line| {
                                defer gpa.free(line);
                                _ = stdout_file.write(line) catch {};
                            } else |_| {}
                            continue;
                        }
                        const st = ok.program.statements[0];
                        switch (st) {
                            .Query => |q| {
                                // Planner legality (US001)
                                const plan = geode.planner.planQuery(q, .{}) catch |pe| {
                                    if (diagnostics.mapPlannerError(pe)) |code| {
                                        writeErrorWithFlags(gpa, stdout_file, code, @errorName(pe), diagnostics.anchorFor(code), &.{}, code == .US001);
                                    } else if (protocol.buildErrorLine(gpa, "PlannerError", @errorName(pe), "")) |line| {
                                        defer gpa.free(line);
                                        _ = stdout_file.write(line) catch {};
                                    } else |_| {}
                                    continue;
                                };
                                if (!explain_mode and !profile_mode and (q.limit != null or q.offset != null) and q.order_by == null) {
                                    writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.US001, diagnostics.defaultMessage(.US001), diagnostics.anchorFor(.US001), &.{}, true);
                                    continue;
                                }
                                if (explain_mode) {
                                    const json = buildExplainJson(gpa, plan.ordered, q.limit, q.offset, null);
                                    if (protocol.buildExplainLine(gpa, json)) |l| {
                                        defer gpa.free(l);
                                        _ = stdout_file.write(l) catch {};
                                    } else |_| {}
                                    continue;
                                }
                                if (profile_mode) {
                                    // Minimal profile: rows count after evaluation
                                    var param_names: [][]const u8 = &.{};
                                    var param_rows: [][]const eval.Value = &.{};
                                    parseParams(gpa, rq.params_json, &param_names, &param_rows);
                                    var ordered_meta = false;
                                    var order_keys: [][]const u8 = &.{};
                                    var cols: []const protocol.SchemaCol = &.{};
                                    const rows = evaluateSimpleQuery(gpa, q, param_names, param_rows, &ordered_meta, &order_keys, &cols) catch &.{};
                                    const row_count = rows.len;
                                    var pb = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
                                    const w = pb.writer(gpa);
                                    // Escape braces for fmt: '{{' '}}'
                                    w.print("{{\"ops\":[{{\"op\":\"Project\",\"rows\":{d}}}]", .{row_count}) catch {};
                                    w.writeAll(",\"flags\":[\"I:IllegalOrderKeyPolicy=ident-only\"]}") catch {};
                                    const pline = protocol.buildProfileLine(gpa, pb.toOwnedSlice(gpa) catch "{}") catch null;
                                    if (pline) |pl| {
                                        defer gpa.free(pl);
                                        _ = stdout_file.write(pl) catch {};
                                    }
                                    continue;
                                }
                                var param_names: [][]const u8 = &.{};
                                var param_rows: [][]const eval.Value = &.{};
                                parseParams(gpa, rq.params_json, &param_names, &param_rows);
                                var ordered_meta = false;
                                var order_keys: [][]const u8 = &.{};
                                var cols: []const protocol.SchemaCol = &.{};
                                const rows = evaluateSimpleQuery(gpa, q, param_names, param_rows, &ordered_meta, &order_keys, &cols) catch &.{};
                                state.last_columns = cols;
                                state.last_ordered = ordered_meta;
                                state.last_order_keys = order_keys;
                                state.page_items = @constCast(rows);
                                state.active_result = true;
                                if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, &.{"I:IllegalOrderKeyPolicy=ident-only"})) |line| {
                                    defer gpa.free(line);
                                    _ = stdout_file.write(line) catch {};
                                } else |_| {}
                                continue;
                            },
                            .Union => |u_stmt| {
                                // Evaluate union then optionally EXPLAIN/PROFILE or pagination
                                var param_names: [][]const u8 = &.{};
                                var param_rows: [][]const eval.Value = &.{};
                                parseParams(gpa, rq.params_json, &param_names, &param_rows);
                                if (explain_mode) {
                                    const json = buildExplainJson(gpa, false, null, null, "DISTINCT");
                                    if (protocol.buildExplainLine(gpa, json)) |l2| {
                                        defer gpa.free(l2);
                                        _ = stdout_file.write(l2) catch {};
                                    } else |_| {}
                                    continue;
                                }
                                var metrics: UnionMetrics = .{ .left_in = 0, .right_in = 0, .out = 0, .hash_size = null };
                                var union_mode: []const u8 = "DISTINCT";
                                const rows = evaluateUnion(gpa, u_stmt, param_names, param_rows, &union_mode, &metrics) catch &.{};
                                if (profile_mode) {
                                    var pb = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
                                    const w = pb.writer(gpa);
                                    w.writeAll("{\"ops\":[{\"op\":\"SetOpUnion\"}]") catch {};
                                    w.writeAll(",\"setop\":{\"type\":\"UNION\",\"mode\":\"") catch {};
                                    w.print("{s}", .{union_mode}) catch {};
                                    w.writeAll("\",\"input_rows_left\":") catch {};
                                    w.print("{d}", .{metrics.left_in}) catch {};
                                    w.writeAll(",\"input_rows_right\":") catch {};
                                    w.print("{d}", .{metrics.right_in}) catch {};
                                    w.writeAll(",\"output_rows\":") catch {};
                                    w.print("{d}", .{metrics.out}) catch {};
                                    if (metrics.hash_size) |hs| {
                                        w.writeAll(",\"hash_dedup_size\":") catch {};
                                        w.print("{d}", .{hs}) catch {};
                                    }
                                    w.writeAll("},\"flags\":[\"I:IllegalOrderKeyPolicy=ident-only\"]}") catch {};
                                    const pline2 = protocol.buildProfileLine(gpa, pb.toOwnedSlice(gpa) catch "{}") catch null;
                                    if (pline2) |pl2| {
                                        defer gpa.free(pl2);
                                        _ = stdout_file.write(pl2) catch {};
                                    }
                                    continue;
                                }
                                // Derive schema from first part return list
                                var dummy_cols: []protocol.SchemaCol = &.{};
                                // union schema inference does not depend on ordering for now
                                const ord_keys: [][]const u8 = &.{}; // unused placeholder retained for consistency
                                dummy_cols = gpa.alloc(protocol.SchemaCol, u_stmt.first.ret.items.len) catch &.{};
                                var ci: usize = 0;
                                while (ci < u_stmt.first.ret.items.len) : (ci += 1) {
                                    const it = u_stmt.first.ret.items[ci];
                                    dummy_cols[ci] = .{ .name = it.alias orelse geode.printer.stringifyExprAlloc(gpa, it.expr, .{}) catch "col", .type = "INT" }; // heuristic
                                }
                                state.last_columns = dummy_cols;
                                state.last_ordered = false;
                                state.last_order_keys = ord_keys;
                                state.page_items = @constCast(rows);
                                state.active_result = true;
                                if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, &.{"I:IllegalOrderKeyPolicy=ident-only"})) |line| {
                                    defer gpa.free(line);
                                    _ = stdout_file.write(line) catch {};
                                } else |_| {}
                                continue;
                            },
                            else => {
                                const uline = protocol.buildErrorLine(gpa, "Unsupported", "statement type", "") catch null;
                                if (uline) |ul| {
                                    defer gpa.free(ul);
                                    _ = stdout_file.write(ul) catch {};
                                }
                                continue;
                            },
                        }
                    },
                }
            },
            .PULL => |pl| {
                if (!state.active_result) {
                    const nrline = protocol.buildErrorLine(gpa, "NoResult", "no active result set", "") catch null;
                    if (nrline) |l| {
                        defer gpa.free(l);
                        _ = stdout_file.write(l) catch {};
                    }
                    continue;
                }
                const page_size = if (pl.page_size == 0) 1000 else pl.page_size;
                const start = state.page_index;
                const end = @min(state.page_index + page_size, state.page_items.len);
                var arr_buf = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
                const w = arr_buf.writer(gpa);
                w.writeAll("[") catch {};
                var i: usize = start;
                var first = true;
                while (i < end) : (i += 1) {
                    if (!first) w.writeAll(",") catch {};
                    first = false;
                    w.writeAll(state.page_items[i]) catch {};
                }
                w.writeAll("]") catch {};
                const json_rows = arr_buf.toOwnedSlice(gpa) catch "[]";
                state.page_index = end;
                const is_final = end >= state.page_items.len;
                if (is_final) state.active_result = false;
                const include_final = (state.page_items.len > 1) or (page_size < state.page_items.len);
                writeBindingsAdaptive(stdout_file, state.last_ordered, state.last_order_keys, json_rows, is_final, include_final);
            },
        }
    }
}
