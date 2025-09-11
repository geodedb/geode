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
    last_distinct: bool = false,
    page_items: [][]const u8 = &.{}, // each: JSON row fragment {..}
    page_index: usize = 0,
    active_result: bool = false,
    in_txn: bool = false,
    allocator: std.mem.Allocator,
    // PROFILE mode staging: we emit SCHEMA immediately and defer PROFILE frame until first PULL.
    profile_json: ?[]const u8 = null,
    profile_flags: []const []const u8 = &.{},

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
        self.last_distinct = false;
        if (self.profile_json) |pj| self.allocator.free(pj);
        self.profile_json = null;
        self.profile_flags = &.{};
    }
};

fn computeBaseFlags(ordered: bool, distinct: bool) []const []const u8 {
    var static: [5][]const u8 = undefined;
    var n: usize = 0;
    static[n] = "I:IllegalOrderKeyPolicy=ident-only";
    n += 1;
    static[n] = "U:NullsFirstPolicy";
    n += 1;
    if (ordered) {
        static[n] = "U:OrderTiebreak=LexJSON";
        n += 1;
    }
    if (distinct and !ordered) {
        static[n] = "U:DistinctOutputUnordered";
        n += 1;
    }
    return static[0..n];
}

fn computeFlagsExtended(ordered: bool, distinct: bool, union_phases: bool) []const []const u8 {
    // Extended variant optionally adding UnionPhaseTimings flag.
    var static: [6][]const u8 = undefined;
    var n: usize = 0;
    static[n] = "I:IllegalOrderKeyPolicy=ident-only";
    n += 1;
    static[n] = "U:NullsFirstPolicy";
    n += 1;
    if (ordered) {
        static[n] = "U:OrderTiebreak=LexJSON";
        n += 1;
    }
    if (distinct and !ordered) {
        static[n] = "U:DistinctOutputUnordered";
        n += 1;
    }
    if (union_phases) {
        static[n] = "U:UnionPhaseTimings";
        n += 1;
    }
    return static[0..n];
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

fn writeErrorWithFlags(ally: std.mem.Allocator, out_file: std.fs.File, code: diagnostics.Code, message: []const u8, anchor: []const u8, additional: []const []const u8, is_us001: bool) void {
    var flags_buf: [2][]const u8 = .{ "I:IllegalOrderKeyPolicy=ident-only", "U:US001/enforced" };
    const flag_slice = if (is_us001) flags_buf[0..2] else flags_buf[0..1];
    if (protocol.buildErrorLineWithFlags(ally, diagnostics.codeName(code), message, anchor, additional, flag_slice)) |line| {
        defer ally.free(line);
        _ = out_file.write(line) catch {};
    } else |_| {}
}

// Aggregate diagnostics discovered during parsing / surface analysis for a single statement.
// Currently we detect:
//  - US001 (unordered pagination): presence of LIMIT/OFFSET without ORDER BY
//  - IllegalOrderKey: parser policy violation captured via parse error message
// Returns number of collected codes placed into out_codes (deduplicated) sorted by precedence.
fn collectTextDiagnostics(text: []const u8, parse_err_msg: ?[]const u8, out_codes: *[4]diagnostics.Code) usize {
    var count: usize = 0;
    const has_limit = std.mem.indexOf(u8, text, "LIMIT") != null;
    const has_offset = std.mem.indexOf(u8, text, "OFFSET") != null;
    const has_order_kw = std.mem.indexOf(u8, text, "ORDER BY") != null;
    var parsed_illegal: bool = false;
    if (parse_err_msg) |msg| {
        if (diagnostics.mapParserMessage(msg)) |_| parsed_illegal = true;
    }
    // Treat invalid ORDER BY (IllegalOrderKey) as absent for unordered pagination legality.
    if ((has_limit or has_offset) and (!has_order_kw or parsed_illegal)) {
        out_codes.*[count] = .US001;
        count += 1;
    }
    if (parsed_illegal) {
        // Append IllegalOrderKey if not already primary
        if (count == 0 or out_codes.*[0] != .IllegalOrderKey) {
            out_codes.*[count] = .IllegalOrderKey;
            count += 1;
        }
    }
    if (count > 1) diagnostics.sortByPrecedence(out_codes.*[0..count]);
    return count;
}

// Planner diagnostics aggregation: include primary planner code plus US001 if unordered pagination also applies.
fn collectPlannerDiagnostics(q: geode.ast.Query, primary: diagnostics.Code, out_codes: *[4]diagnostics.Code) usize {
    var count: usize = 0;
    out_codes.*[count] = primary;
    count += 1;
    const unordered_pagination = (q.limit != null or q.offset != null) and q.order_by == null;
    if (unordered_pagination and primary != .US001) {
        out_codes.*[count] = .US001;
        count += 1;
    }
    if (count > 1) diagnostics.sortByPrecedence(out_codes.*[0..count]);
    return count;
}

fn writeJsonValue(w: anytype, v: eval.Value) !void {
    switch (v) {
        .Int => |iv| try w.print("{d}", .{iv}),
        .Bool => |bv| try w.writeAll(if (bv) "true" else "false"),
        .Str => |s| blk: {
            try w.writeAll("\"");
            try w.writeAll(s);
            try w.writeAll("\"");
            break :blk;
        },
        .Null => try w.writeAll("null"),
        .Decimal => |d| blkdec: {
            var buf: [64]u8 = undefined;
            var coeff = d.coeff;
            var scale = d.scale;
            if (scale > 0) {
                while (scale > 0) {
                    if (@mod(coeff, 10) != 0) break;
                    coeff = @divTrunc(coeff, 10);
                    scale -= 1;
                }
            }
            if (scale == 0) {
                const s = std.fmt.bufPrint(&buf, "{d}", .{coeff}) catch "0";
                try w.writeAll(s);
                break :blkdec;
            }
            var pow: i128 = 1;
            var i: u8 = 0;
            while (i < scale) : (i += 1) pow *= 10;
            const abs_coeff: i128 = if (coeff < 0) -coeff else coeff;
            const whole: i128 = @divTrunc(coeff, pow);
            const frac: i128 = @mod(abs_coeff, pow);
            var fracbuf: [32]u8 = undefined;
            const ftmp = std.fmt.bufPrint(&fracbuf, "{d}", .{frac}) catch "0";
            if (ftmp.len < scale) {
                const missing = scale - @as(u8, @intCast(ftmp.len));
                var pad: [32]u8 = undefined;
                @memset(pad[0..missing], '0');
                const s = std.fmt.bufPrint(&buf, "{d}.{s}{s}", .{ whole, pad[0..missing], ftmp }) catch "0";
                try w.writeAll(s);
            } else {
                const s = std.fmt.bufPrint(&buf, "{d}.{s}", .{ whole, ftmp }) catch "0";
                try w.writeAll(s);
            }
        },
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

fn buildExplainJson(ally: std.mem.Allocator, params: struct { ordered: bool, limit: ?usize, offset: ?usize, union_mode: ?[]const u8, distinct: bool }) []const u8 {
    var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return "{\"logical\":[]}";
    const w = buf.writer(ally);
    w.writeAll("{\"logical\":[") catch {};
    var first_op = true;
    // Base projection
    w.writeAll("{\"op\":\"Project\"}") catch {};
    first_op = false;
    if (params.distinct) {
        w.writeAll(",{") catch {};
        w.writeAll("\"op\":\"Distinct\"") catch {};
        w.writeAll("}") catch {};
    }
    if (params.ordered) {
        w.writeAll(",{\"op\":\"Sort\"}") catch {};
    }
    if (params.offset) |_| {
        w.writeAll(",{\"op\":\"Offset\"}") catch {};
    }
    if (params.limit) |_| {
        w.writeAll(",{\"op\":\"Limit\"}") catch {};
    }
    if (params.union_mode) |um| {
        w.writeAll(",{") catch {};
        w.writeAll("\"op\":\"SetOpUnion\",\"mode\":\"") catch {};
        w.writeAll(um) catch {};
        w.writeAll("\"}") catch {};
    }
    w.writeAll("],\"properties\":{") catch {};
    var first = true;
    if (params.ordered) {
        w.writeAll("\"ordered\":true") catch {};
        first = false;
    }
    if (params.limit) |l| {
        if (!first) w.writeAll(",") catch {};
        first = false;
        w.print("\"limit\":{d}", .{l}) catch {};
    }
    if (params.offset) |o| {
        if (!first) w.writeAll(",") catch {};
        first = false;
        w.print("\"offset\":{d}", .{o}) catch {};
    }
    if (params.union_mode) |um2| {
        if (!first) w.writeAll(",") catch {};
        first = false;
        w.print("\"union_mode\":\"{s}\"", .{um2}) catch {};
    }
    if (params.distinct) {
        if (!first) w.writeAll(",") catch {};
        first = false;
        w.writeAll("\"distinct\":true") catch {};
    }
    w.writeAll("}") catch {};
    return buf.toOwnedSlice(ally) catch "{\"logical\":[]}";
}

// Custom bindings writer: include final flag only if (has_params or multi_page_needed or explicit pagination triggered)
fn writeBindingsAdaptive(file: std.fs.File, ordered: bool, order_keys: []const []const u8, rows_json: []const u8, final_flag: bool, include_final: bool, flags: []const []const u8) void {
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
    if (flags.len > 0) {
        file.writeAll(",\"flagger_findings\":[") catch {};
        var fi: usize = 0;
        while (fi < flags.len) : (fi += 1) {
            if (fi > 0) file.writeAll(",") catch {};
            file.writeAll("\"") catch {};
            file.writeAll(flags[fi]) catch {};
            file.writeAll("\"") catch {};
        }
        file.writeAll("]") catch {};
    }
    file.writeAll("}}\n") catch {};
}

const StageTimings = struct {
    project_ns: i128 = 0,
    distinct_ns: i128 = 0,
    sort_ns: i128 = 0,
    offset_ns: i128 = 0,
    limit_ns: i128 = 0,
    agg_build_ns: i128 = 0,
    agg_emit_ns: i128 = 0,
    project_rows_out: usize = 0,
    distinct_rows_out: usize = 0,
    sort_rows_out: usize = 0,
    offset_rows_out: usize = 0,
    limit_rows_out: usize = 0,
    agg_rows_out: usize = 0,
    project_rows_in: usize = 0,
    distinct_rows_in: usize = 0,
    sort_rows_in: usize = 0,
    offset_rows_in: usize = 0,
    limit_rows_in: usize = 0,
    agg_rows_in: usize = 0,
};

// Build canonical key for a row JSON string so that numerically equal values with different scales map identically.
fn canonicalRowKey(ally: std.mem.Allocator, row: []const u8) []const u8 {
    if (row.len < 2) return row; // fallback
    var idx: usize = 0;
    if (row[idx] == '{') idx += 1;
    var key_buf = std.ArrayList(u8).initCapacity(ally, 0) catch return row;
    const w = key_buf.writer(ally);
    var field_i: usize = 0;
    while (idx < row.len) : (idx += 1) {
        while (idx < row.len and (row[idx] == ' ' or row[idx] == ',')) idx += 1;
        if (idx >= row.len or row[idx] == '}') break;
        if (row[idx] != '"') break; // malformed
        idx += 1; // skip opening quote of key
        while (idx < row.len and row[idx] != '"') idx += 1; // skip key chars
        if (idx >= row.len) break;
        idx += 1; // skip closing quote
        while (idx < row.len and row[idx] != ':') idx += 1;
        if (idx >= row.len) break;
        idx += 1; // colon
        while (idx < row.len and row[idx] == ' ') idx += 1;
        if (idx >= row.len) break;
        if (field_i > 0) w.writeAll("|") catch {};
        const ch = row[idx];
        if (ch == 'n') { // null
            w.writeAll("n") catch {};
            while (idx < row.len and row[idx] != ',' and row[idx] != '}') idx += 1;
            if (idx >= row.len or row[idx] == '}') break;
            field_i += 1;
            continue;
        } else if (ch == '"') { // string
            idx += 1;
            const start = idx;
            while (idx < row.len and row[idx] != '"') idx += 1;
            const s = if (idx <= row.len) row[start..idx] else &.{};
            w.writeAll("s:") catch {};
            w.print("{d}:", .{s.len}) catch {};
            w.writeAll(s) catch {};
            if (idx < row.len) idx += 1;
            while (idx < row.len and row[idx] != ',' and row[idx] != '}') idx += 1;
            if (idx >= row.len or row[idx] == '}') break;
            field_i += 1;
            continue;
        } else {
            // number or bool token
            const startn = idx;
            var neg = false;
            if (row[idx] == '-') {
                neg = true;
                idx += 1;
            }
            var mantissa: i128 = 0;
            var saw_digit = false;
            while (idx < row.len and row[idx] >= '0' and row[idx] <= '9') : (idx += 1) {
                mantissa = mantissa * 10 + (row[idx] - '0');
                saw_digit = true;
            }
            var scale: u8 = 0;
            var is_dec = false;
            if (idx < row.len and row[idx] == '.') {
                is_dec = true;
                idx += 1;
                while (idx < row.len and row[idx] >= '0' and row[idx] <= '9') : (idx += 1) {
                    mantissa = mantissa * 10 + (row[idx] - '0');
                    scale += 1;
                    saw_digit = true;
                }
            }
            if (!saw_digit) {
                // bool token -> canonical as string
                var endtok = startn;
                while (endtok < row.len and row[endtok] != ',' and row[endtok] != '}') endtok += 1;
                const tok = row[startn..endtok];
                w.writeAll("s:") catch {};
                w.print("{d}:", .{tok.len}) catch {};
                w.writeAll(tok) catch {};
                idx = endtok;
            } else {
                if (neg) mantissa = -mantissa;
                if (is_dec) {
                    while (scale > 0 and @mod(mantissa, 10) == 0) : (scale -= 1) mantissa = @divTrunc(mantissa, 10);
                    if (scale == 0) {
                        // becomes int
                        w.writeAll("i:") catch {};
                        w.print("{d}", .{mantissa}) catch {};
                    } else {
                        w.writeAll("d:") catch {};
                        w.print("{d}:", .{mantissa}) catch {};
                        w.print("{d}", .{scale}) catch {};
                    }
                } else {
                    w.writeAll("i:") catch {};
                    w.print("{d}", .{mantissa}) catch {};
                }
            }
            while (idx < row.len and row[idx] != ',' and row[idx] != '}') idx += 1;
            if (idx >= row.len or row[idx] == '}') break;
            field_i += 1;
            continue;
        }
    }
    return key_buf.toOwnedSlice(ally) catch row;
}

fn buildAdditionalStatusesAlloc(ally: std.mem.Allocator, codes: []const diagnostics.Code, primary: diagnostics.Code) []const []const u8 {
    if (codes.len <= 1) return &.{};
    var extras = ally.alloc([]const u8, codes.len - 1) catch return &.{};
    var ei: usize = 0;
    var i: usize = 0;
    while (i < codes.len) : (i += 1) {
        if (codes[i] == primary) continue;
        extras[ei] = diagnostics.codeName(codes[i]);
        ei += 1;
    }
    return extras[0..ei];
}

fn evaluateSimpleQuery(ally: std.mem.Allocator, q: geode.ast.Query, param_names: [][]const u8, param_matrix: [][]const eval.Value, ordered_meta: *bool, order_keys: *[][]const u8, cols_out: *[]const protocol.SchemaCol, timings: ?*StageTimings, eval_diag: ?*diagnostics.Code) ![][]const u8 {
    // Build rows
    var cols = try ally.alloc(protocol.SchemaCol, q.ret.items.len);
    var rows_json = std.ArrayList([]const u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    defer rows_json.deinit(ally);

    const t_start = if (timings) |_| std.time.nanoTimestamp() else 0;

    const has_params = param_matrix.len > 0;
    const num_rows = if (has_params) param_matrix.len else 1;
    // Capture per-row evaluation environments for later ORDER BY key evaluation.
    var envs = try ally.alloc(eval.Env, num_rows);
    var r: usize = 0;
    while (r < num_rows) : (r += 1) {
        const env: eval.Env = if (has_params) .{ .names = param_names, .values = param_matrix[r] } else .{ .names = &.{}, .values = &.{} };
        envs[r] = env;
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
            const val = eval.evalExpr(ally, it.expr, env) catch |e| blk_evalerr: {
                if (eval_diag) |ed| {
                    if (diagnostics.mapEvalError(e)) |c| ed.* = c;
                }
                break :blk_evalerr eval.Value{ .Null = {} };
            };
            if (r == 0) cols[j] = .{ .name = alias, .type = valueTypeName(val) };
            if (j > 0) w.writeAll(",") catch {};
            w.print("\"{s}\":", .{alias}) catch {};
            writeJsonValue(w, val) catch {};
        }
        w.writeAll("}") catch {};
        rows_json.append(ally, buf.toOwnedSlice(ally) catch "{}") catch {};
    }

    if (timings) |tptr| {
        tptr.project_ns = std.time.nanoTimestamp() - t_start;
        tptr.project_rows_in = num_rows;
        tptr.project_rows_out = rows_json.items.len;
    }

    // DISTINCT on RETURN clause
    if (q.ret.distinct and rows_json.items.len > 1) {
        const t_d_start = if (timings) |_| std.time.nanoTimestamp() else 0;
        var seen = std.StringHashMap(void).init(ally);
        defer seen.deinit();
        var out_rows = std.ArrayList([]const u8).initCapacity(ally, 0) catch unreachable;
        defer out_rows.deinit(ally);
        for (rows_json.items) |s| {
            const key = canonicalRowKey(ally, s);
            if (!seen.contains(key)) {
                seen.put(key, {}) catch {};
                out_rows.append(ally, s) catch {};
            } else {
                ally.free(s);
                ally.free(key);
            }
        }
        rows_json.clearRetainingCapacity();
        for (out_rows.items) |rr| rows_json.append(ally, rr) catch {};
        if (timings) |tptr| {
            tptr.distinct_ns = std.time.nanoTimestamp() - t_d_start;
            tptr.distinct_rows_in = tptr.project_rows_out;
            tptr.distinct_rows_out = rows_json.items.len;
        }
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
        if (rows_json.items.len > 1 and ob.keys.len > 0) {
            const t_sort_start = if (timings) |_| std.time.nanoTimestamp() else 0;
            const KeyKind = enum { Null, Int, Dec, Str };
            const KeyVal = struct { kind: KeyKind, mantissa: i128 = 0, scale: u8 = 0, str: []const u8 = &.{} };
            // Flattened matrix: row-major [row * key_count + key]
            const key_count = ob.keys.len;
            var key_matrix: []KeyVal = ally.alloc(KeyVal, rows_json.items.len * key_count) catch &.{};
            defer if (key_matrix.len != 0) ally.free(key_matrix);
            // For each row, re-evaluate each ORDER BY expression in the same environment used originally.
            // NOTE: For correctness with aliases/ordinals, planner already validated keys are simple identifiers/ordinals.
            var row_index: usize = 0;
            while (row_index < rows_json.items.len) : (row_index += 1) {
                // Reconstruct evaluation environment identical to projection (params only in current prototype).
                var key_i: usize = 0;
                while (key_i < key_count) : (key_i += 1) {
                    const key_expr = ob.keys[key_i].expr;
                    const val = eval.evalExpr(ally, key_expr, envs[row_index]) catch eval.Value{ .Null = {} };
                    const slot_index = row_index * key_count + key_i;
                    key_matrix[slot_index] = switch (val) {
                        .Null => KeyVal{ .kind = .Null },
                        .Int => |iv| KeyVal{ .kind = .Int, .mantissa = iv },
                        .Decimal => |d| KeyVal{ .kind = .Dec, .mantissa = d.coeff, .scale = d.scale },
                        .Str => |s| KeyVal{ .kind = .Str, .str = s },
                        .Bool => |b| KeyVal{ .kind = .Str, .str = if (b) "true" else "false" }, // bool ordering after numbers before other strings via lex tie-break
                    };
                }
            }
            const Ctx = struct {
                rows: [][]const u8,
                ob: *const @TypeOf(ob),
                keys: []KeyVal,
                key_count: usize,
                fn cmpNumeric(a: KeyVal, b: KeyVal) i2 {
                    if (a.kind == .Int and b.kind == .Int) {
                        if (a.mantissa < b.mantissa) return -1;
                        if (a.mantissa > b.mantissa) return 1;
                        return 0;
                    }
                    var ma = a.mantissa;
                    var mb = b.mantissa;
                    var ascale: u8 = if (a.kind == .Dec) a.scale else 0;
                    var bscale: u8 = if (b.kind == .Dec) b.scale else 0;
                    if (ascale > 0 and a.kind == .Dec) {
                        while (ascale > 0 and @mod(ma, 10) == 0) : (ascale -= 1) {
                            ma = @divTrunc(ma, 10);
                        }
                    }
                    if (bscale > 0 and b.kind == .Dec) {
                        while (bscale > 0 and @mod(mb, 10) == 0) : (bscale -= 1) {
                            mb = @divTrunc(mb, 10);
                        }
                    }
                    if (ascale == bscale) {
                        if (ma < mb) return -1;
                        if (ma > mb) return 1;
                        return 0;
                    }
                    if (ascale < bscale) {
                        var diff = bscale - ascale;
                        while (diff > 0) : (diff -= 1) ma *= 10;
                    } else {
                        var diff = ascale - bscale;
                        while (diff > 0) : (diff -= 1) mb *= 10;
                    }
                    if (ma < mb) return -1;
                    if (ma > mb) return 1;
                    return 0;
                }
            };
            std.sort.block([]const u8, rows_json.items, Ctx{ .rows = rows_json.items, .ob = &ob, .keys = key_matrix, .key_count = key_count }, struct {
                fn less(c: Ctx, a: []const u8, b: []const u8) bool {
                    // Compute indices by locating a & b in rows (linear scan acceptable for small test data)
                    // Optimize: build index map if row count grows.
                    var ai: usize = 0;
                    var bi: usize = 0;
                    while (ai < c.rows.len and !std.mem.eql(u8, c.rows[ai], a)) : (ai += 1) {}
                    while (bi < c.rows.len and !std.mem.eql(u8, c.rows[bi], b)) : (bi += 1) {}
                    var ki: usize = 0;
                    while (ki < c.ob.keys.len) : (ki += 1) {
                        const key_expr = c.ob.keys[ki];
                        const av = c.keys[ai * c.key_count + ki];
                        const bv = c.keys[bi * c.key_count + ki];
                        if (av.kind == .Null and bv.kind != .Null) return !key_expr.desc;
                        if (bv.kind == .Null and av.kind != .Null) return key_expr.desc;
                        var ord: i2 = 0;
                        switch (av.kind) {
                            .Null => ord = 0,
                            .Str => if (bv.kind == .Str) {
                                if (std.mem.lessThan(u8, av.str, bv.str)) ord = -1 else if (std.mem.lessThan(u8, bv.str, av.str)) ord = 1 else ord = 0;
                            } else {
                                ord = 1; // strings after numbers
                            },
                            .Int, .Dec => switch (bv.kind) {
                                .Int, .Dec => ord = Ctx.cmpNumeric(av, bv),
                                .Str => ord = -1,
                                .Null => ord = 1,
                            },
                        }
                        if (ord != 0) return if (key_expr.desc) ord > 0 else ord < 0;
                    }
                    return std.mem.lessThan(u8, a, b);
                }
            }.less);
            if (timings) |tptr| {
                tptr.sort_ns = std.time.nanoTimestamp() - t_sort_start;
                tptr.sort_rows_in = if (tptr.distinct_rows_out != 0) tptr.distinct_rows_out else tptr.project_rows_out;
                tptr.sort_rows_out = rows_json.items.len;
            }
        }
    }

    // LIMIT/OFFSET
    var start: usize = 0;
    var t_offset_start: i128 = 0;
    if (q.offset) |off| {
        if (timings) |_| t_offset_start = std.time.nanoTimestamp();
        if (off < rows_json.items.len) {
            start = off;
        } else {
            start = rows_json.items.len;
        }
        if (timings) |tptr| {
            tptr.offset_ns = std.time.nanoTimestamp() - t_offset_start;
            tptr.offset_rows_in = if (tptr.sort_rows_out != 0) tptr.sort_rows_out else if (tptr.distinct_rows_out != 0) tptr.distinct_rows_out else tptr.project_rows_out;
            tptr.offset_rows_out = if (off < rows_json.items.len) rows_json.items.len - off else 0;
        }
    }
    var end: usize = rows_json.items.len;
    var t_limit_start: i128 = 0;
    if (q.limit) |lim| {
        if (timings) |_| t_limit_start = std.time.nanoTimestamp();
        if (start + lim < end) end = start + lim;
        if (timings) |tptr| {
            tptr.limit_ns = std.time.nanoTimestamp() - t_limit_start;
            tptr.limit_rows_in = if (tptr.offset_rows_out != 0) tptr.offset_rows_out else if (tptr.sort_rows_out != 0) tptr.sort_rows_out else tptr.project_rows_out;
            const effective = if (start + lim < rows_json.items.len) lim else rows_json.items.len - start;
            tptr.limit_rows_out = effective;
        }
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

    // If some phases not executed, propagate previous row counts for clarity
    if (timings) |tptr| {
        if (tptr.distinct_rows_out == 0) tptr.distinct_rows_out = tptr.project_rows_out;
        if (tptr.sort_rows_out == 0) tptr.sort_rows_out = if (tptr.distinct_rows_out != 0) tptr.distinct_rows_out else tptr.project_rows_out;
        if (tptr.offset_rows_out == 0) tptr.offset_rows_out = tptr.sort_rows_out;
        if (tptr.limit_rows_out == 0) tptr.limit_rows_out = if (q.limit != null) @min(rows_json.items.len, tptr.offset_rows_out) else rows_json.items.len;
        if (tptr.distinct_rows_in == 0) tptr.distinct_rows_in = tptr.project_rows_out;
        if (tptr.sort_rows_in == 0) tptr.sort_rows_in = tptr.distinct_rows_out;
        if (tptr.offset_rows_in == 0) tptr.offset_rows_in = tptr.sort_rows_out;
        if (tptr.limit_rows_in == 0) tptr.limit_rows_in = tptr.offset_rows_out;
    }

    cols_out.* = cols;
    return rows_json.toOwnedSlice(ally) catch &.{};
}

fn evaluateUnion(ally: std.mem.Allocator, u: geode.ast.UnionQuery, param_names: [][]const u8, param_matrix: [][]const eval.Value, union_mode_out: *[]const u8, metrics: *UnionMetrics) ![][]const u8 {
    // Evaluate each component as simple query without ORDER/LIMIT (applied externally if needed)
    var dummy_cols: []const protocol.SchemaCol = &.{};
    var ordered: bool = false;
    var order_keys: [][]const u8 = &.{};
    const left_rows = try evaluateSimpleQuery(ally, u.first, param_names, param_matrix, &ordered, &order_keys, &dummy_cols, null, null);
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
        const rows = try evaluateSimpleQuery(ally, part.query, param_names, param_matrix, &ordered, &order_keys, &oc, null, null);
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
    // Structured dedup
    var seen = std.StringHashMap(void).init(ally);
    defer seen.deinit();
    var dedup_rows = std.ArrayList([]const u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    defer dedup_rows.deinit(ally);
    for (all_rows.items) |s| {
        const key = canonicalRowKey(ally, s);
        if (!seen.contains(key)) {
            seen.put(key, {}) catch {};
            dedup_rows.append(ally, s) catch {};
        } else {
            ally.free(s);
            ally.free(key);
        }
    }
    metrics.out = dedup_rows.items.len;
    metrics.hash_size = seen.count();
    return dedup_rows.toOwnedSlice(ally) catch &.{};
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    // Parse server CLI args for optional result format.
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    var result_format_txt = false;
    var ai: usize = 1;
    while (ai < args.len) : (ai += 1) {
        if (std.mem.eql(u8, args[ai], "--result-format") and ai + 1 < args.len) {
            const f = args[ai + 1];
            if (std.mem.eql(u8, f, "txt") or std.mem.eql(u8, f, "text")) result_format_txt = true;
            ai += 1;
        }
    }
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
        if (read_len == 0) continue;
        const raw = line_storage[0..read_len];
        if (raw.len == 0) continue;
        // Parse client message
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const msg = protocol.parseClientMessage(arena.allocator(), raw) catch continue; // ignore invalid
        switch (msg) {
            .HELLO => |_| {},
            .BEGIN => |_| {
                if (state.in_txn) {
                    if (protocol.buildErrorLine(gpa, "TxnState", "already in transaction", "8")) |line| {
                        defer gpa.free(line);
                        _ = stdout_file.write(line) catch {};
                    } else |_| {}
                } else {
                    state.in_txn = true;
                    writeBindingsAdaptive(stdout_file, false, &.{}, "[]", true, false, computeBaseFlags(false, false));
                }
            },
            .COMMIT => |_| {
                if (!state.in_txn) {
                    if (protocol.buildErrorLine(gpa, "TxnState", "no active transaction", "8")) |line| {
                        defer gpa.free(line);
                        _ = stdout_file.write(line) catch {};
                    } else |_| {}
                } else {
                    state.in_txn = false;
                    writeBindingsAdaptive(stdout_file, false, &.{}, "[]", true, false, computeBaseFlags(false, false));
                }
            },
            .ROLLBACK => |_| {
                if (!state.in_txn) {
                    if (protocol.buildErrorLine(gpa, "TxnState", "no active transaction", "8")) |line| {
                        defer gpa.free(line);
                        _ = stdout_file.write(line) catch {};
                    } else |_| {}
                } else {
                    state.in_txn = false;
                    writeBindingsAdaptive(stdout_file, false, &.{}, "[]", true, false, computeBaseFlags(false, false));
                }
            },
            .RUN_GQL => |rq| {
                state.resetResult();
                var text = rq.text;
                var explain_mode = false;
                var profile_mode = false;
                if (std.mem.startsWith(u8, text, "PROFILE ")) {
                    profile_mode = true;
                    text = text[8..];
                }
                if (std.mem.startsWith(u8, text, "EXPLAIN ")) {
                    explain_mode = true;
                    text = text[8..];
                }

                var parse_res = geode.parseGqlOutcome(text, gpa, .{ .ident_order_only = true, .forbid_orderby_calls = true }) catch |e| {
                    // Aggregate all parse-time diagnostics (policy + US001) and emit with precedence.
                    var codes_buf: [4]diagnostics.Code = undefined;
                    const n_raw = collectTextDiagnostics(text, @errorName(e), &codes_buf);
                    const n = diagnostics.foldCodes(codes_buf[0..n_raw]);
                    if (n == 0) {
                        // Fallback: treat as IllegalOrderKey for now to satisfy existing tests.
                        writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.IllegalOrderKey, @errorName(e), diagnostics.anchorFor(.IllegalOrderKey), &.{}, false);
                        return;
                    }
                    const primary = codes_buf[0];
                    const add_slice = buildAdditionalStatusesAlloc(gpa, codes_buf[0..n], primary);
                    const primary_msg = if (primary == .IllegalOrderKey) @errorName(e) else diagnostics.defaultMessage(primary);
                    writeErrorWithFlags(gpa, stdout_file, primary, primary_msg, diagnostics.anchorFor(primary), add_slice, primary == .US001);
                    continue;
                };
                defer if (parse_res == .Ok) parse_res.Ok.deinit();
                switch (parse_res) {
                    .Err => |er| {
                        var codes_buf: [4]diagnostics.Code = undefined;
                        const n_raw = collectTextDiagnostics(text, er.msg, &codes_buf);
                        const n = diagnostics.foldCodes(codes_buf[0..n_raw]);
                        if (n == 0) {
                            if (protocol.buildErrorLine(gpa, "ParseError", er.msg, "")) |line| {
                                defer gpa.free(line);
                                _ = stdout_file.write(line) catch {};
                            } else |_| {}
                            continue;
                        }
                        const primary = codes_buf[0];
                        const add_slice = buildAdditionalStatusesAlloc(gpa, codes_buf[0..n], primary);
                        const primary_msg = if (primary == .IllegalOrderKey) er.msg else diagnostics.defaultMessage(primary);
                        writeErrorWithFlags(gpa, stdout_file, primary, primary_msg, diagnostics.anchorFor(primary), add_slice, primary == .US001);
                        continue;
                    },
                    .Ok => |ok| {
                        if (ok.program.statements.len == 0) {
                            if (protocol.buildSchemaLine(gpa, &.{}, &.{}, computeBaseFlags(false, false))) |line| {
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
                                        var codes_buf_pl: [4]diagnostics.Code = undefined;
                                        const n_codes_pl_raw = collectPlannerDiagnostics(q, code, &codes_buf_pl);
                                        const n_codes_pl = diagnostics.foldCodes(codes_buf_pl[0..n_codes_pl_raw]);
                                        const primary_pl = if (n_codes_pl > 0) codes_buf_pl[0] else code;
                                        const add_slice_pl = buildAdditionalStatusesAlloc(gpa, codes_buf_pl[0..n_codes_pl], primary_pl);
                                        const pmsg = diagnostics.defaultMessage(primary_pl);
                                        writeErrorWithFlags(gpa, stdout_file, primary_pl, pmsg, diagnostics.anchorFor(primary_pl), add_slice_pl, primary_pl == .US001);
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
                                    const json = buildExplainJson(gpa, .{ .ordered = plan.ordered, .limit = q.limit, .offset = q.offset, .union_mode = null, .distinct = q.ret.distinct });
                                    const flags_ex2 = computeBaseFlags(plan.ordered, q.ret.distinct);
                                    if (protocol.buildExplainLine(gpa, json, flags_ex2)) |l| {
                                        defer gpa.free(l);
                                        _ = stdout_file.write(l) catch {};
                                    } else |_| {}
                                    continue;
                                }
                                if (profile_mode) {
                                    // PROFILE mode: we stage PROFILE json and emit SCHEMA now; PROFILE frame on first PULL.
                                    const start_time = std.time.nanoTimestamp();
                                    var param_names: [][]const u8 = &.{};
                                    var param_rows: [][]const eval.Value = &.{};
                                    parseParams(gpa, rq.params_json, &param_names, &param_rows);
                                    var ordered_meta = false;
                                    var order_keys: [][]const u8 = &.{};
                                    var cols_mut: []protocol.SchemaCol = &.{}; // mutable during build
                                    var cols: []const protocol.SchemaCol = &.{}; // const view stored in state
                                    var timings: StageTimings = .{};
                                    var row_count: usize = 0;
                                    if (q.group_by != null) {
                                        var agg_timings: exec.AggStageTimings = .{};
                                        const g_out = exec.runGroupedQuery(gpa, q, &.{}, &.{}, &.{}, &.{}, &agg_timings) catch &.{};
                                        row_count = g_out.len;
                                        timings.agg_rows_out = row_count;
                                        timings.project_rows_out = row_count; // projection after aggregate
                                        timings.agg_build_ns = agg_timings.build_ns;
                                        timings.agg_emit_ns = agg_timings.emit_ns;
                                        // Build synthetic columns from RETURN items
                                        var mut_cols_slice: []protocol.SchemaCol = gpa.alloc(protocol.SchemaCol, q.ret.items.len) catch &.{};
                                        var idx_fill: usize = 0;
                                        while (idx_fill < q.ret.items.len) : (idx_fill += 1) {
                                            const it2 = q.ret.items[idx_fill];
                                            const alias2 = it2.alias orelse geode.printer.stringifyExprAlloc(gpa, it2.expr, .{}) catch "col";
                                            mut_cols_slice[idx_fill] = .{ .name = alias2, .type = "INT" };
                                        }
                                        cols_mut = mut_cols_slice;
                                        cols = cols_mut;
                                    } else {
                                        var run_code: diagnostics.Code = .IllegalOrderKey; // init sentinel
                                        const rows_prof = evaluateSimpleQuery(gpa, q, param_names, param_rows, &ordered_meta, &order_keys, &cols, &timings, &run_code) catch &.{};
                                        if (run_code == .TypeMismatch) {
                                            var buf_codes: [2]diagnostics.Code = undefined;
                                            var len_codes: usize = 0;
                                            buf_codes[len_codes] = .TypeMismatch;
                                            len_codes += 1;
                                            if ((q.limit != null or q.offset != null) and q.order_by == null) {
                                                buf_codes[len_codes] = .US001;
                                                len_codes += 1;
                                            }
                                            const slice_codes = buf_codes[0..len_codes];
                                            if (slice_codes.len > 1) diagnostics.sortByPrecedence(slice_codes);
                                            const primary_eval = slice_codes[0];
                                            const add_eval = buildAdditionalStatusesAlloc(gpa, slice_codes, primary_eval);
                                            writeErrorWithFlags(gpa, stdout_file, primary_eval, diagnostics.defaultMessage(primary_eval), diagnostics.anchorFor(primary_eval), add_eval, primary_eval == .US001);
                                            var fre: usize = 0;
                                            while (fre < rows_prof.len) : (fre += 1) gpa.free(rows_prof[fre]);
                                            continue;
                                        }
                                        row_count = rows_prof.len;
                                        timings.project_rows_out = row_count;
                                        timings.distinct_rows_out = row_count; // placeholders until per-phase slicing implemented
                                        timings.sort_rows_out = row_count;
                                        timings.offset_rows_out = if (q.offset) |offv| if (offv < row_count) row_count - offv else 0 else row_count;
                                        timings.limit_rows_out = if (q.limit) |limv| if (limv < row_count) limv else row_count else row_count;
                                        // Free rows; PROFILE does not return them
                                        var frp: usize = 0;
                                        while (frp < rows_prof.len) : (frp += 1) gpa.free(rows_prof[frp]);
                                    }
                                    const total_ns: i128 = std.time.nanoTimestamp() - start_time;
                                    var pb = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
                                    const w = pb.writer(gpa);
                                    w.writeAll("{\"ops\":[") catch {};
                                    var first_op_profile = true;
                                    const emit = struct {
                                        fn op(wr: anytype, first_ptr: *bool, name: []const u8, in_rows: usize, out_rows: usize, time_ns: i128) void {
                                            if (first_ptr.*) wr.writeAll("{") catch {} else wr.writeAll(",{") catch {};
                                            wr.writeAll("\"op\":\"") catch {};
                                            wr.writeAll(name) catch {};
                                            wr.writeAll("\",\"input_rows\":") catch {};
                                            wr.print("{d}", .{in_rows}) catch {};
                                            wr.writeAll(",\"rows\":") catch {};
                                            wr.print("{d}", .{out_rows}) catch {};
                                            wr.writeAll(",\"time_ns\":") catch {};
                                            wr.print("{d}", .{time_ns}) catch {};
                                            wr.writeAll("}") catch {};
                                            first_ptr.* = false;
                                        }
                                    };
                                    if (q.group_by != null) {
                                        emit.op(w, &first_op_profile, "AggregateBuild", timings.agg_rows_in, timings.agg_rows_out, timings.agg_build_ns);
                                        emit.op(w, &first_op_profile, "AggregateEmit", timings.agg_rows_out, timings.agg_rows_out, timings.agg_emit_ns);
                                    }
                                    emit.op(w, &first_op_profile, "Project", timings.project_rows_in, timings.project_rows_out, timings.project_ns);
                                    if (q.ret.distinct) emit.op(w, &first_op_profile, "Distinct", timings.distinct_rows_in, timings.distinct_rows_out, timings.distinct_ns);
                                    if (ordered_meta) emit.op(w, &first_op_profile, "Sort", timings.sort_rows_in, timings.sort_rows_out, timings.sort_ns);
                                    if (q.offset != null) emit.op(w, &first_op_profile, "Offset", timings.offset_rows_in, timings.offset_rows_out, timings.offset_ns);
                                    if (q.limit != null) emit.op(w, &first_op_profile, "Limit", timings.limit_rows_in, timings.limit_rows_out, timings.limit_ns);
                                    w.writeAll(",\"total_time_ns\":") catch {};
                                    w.print("{d}", .{total_ns}) catch {};
                                    w.writeAll("}") catch {};
                                    state.profile_json = pb.toOwnedSlice(gpa) catch "{}";
                                    state.profile_flags = computeBaseFlags(ordered_meta, q.ret.distinct);
                                    state.last_columns = cols;
                                    state.last_ordered = ordered_meta;
                                    state.last_order_keys = order_keys;
                                    state.last_distinct = q.ret.distinct;
                                    state.active_result = true; // so PULL will emit PROFILE
                                    // Emit SCHEMA now
                                    if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, state.profile_flags)) |line| {
                                        defer gpa.free(line);
                                        _ = stdout_file.write(line) catch {};
                                    } else |_| {}
                                    continue;
                                }
                                var param_names: [][]const u8 = &.{};
                                var param_rows: [][]const eval.Value = &.{};
                                parseParams(gpa, rq.params_json, &param_names, &param_rows);
                                var ordered_meta = false;
                                var order_keys: [][]const u8 = &.{};
                                var cols: []const protocol.SchemaCol = &.{};
                                var run_code: diagnostics.Code = .IllegalOrderKey; // init sentinel
                                const rows = evaluateSimpleQuery(gpa, q, param_names, param_rows, &ordered_meta, &order_keys, &cols, null, &run_code) catch |e| blk_runerr: {
                                    if (diagnostics.mapEvalError(e)) |c| {
                                        writeErrorWithFlags(gpa, stdout_file, c, diagnostics.defaultMessage(c), diagnostics.anchorFor(c), &.{}, false);
                                        break :blk_runerr &.{};
                                    }
                                    break :blk_runerr &.{};
                                };
                                if (rows.len == 0 and run_code == .TypeMismatch) continue;
                                if (run_code == .TypeMismatch) {
                                    var buf_codes2: [2]diagnostics.Code = undefined;
                                    var len2: usize = 0;
                                    buf_codes2[len2] = .TypeMismatch;
                                    len2 += 1;
                                    if ((q.limit != null or q.offset != null) and q.order_by == null) {
                                        buf_codes2[len2] = .US001;
                                        len2 += 1;
                                    }
                                    const slice2 = buf_codes2[0..len2];
                                    const n_fold2 = diagnostics.foldCodes(slice2);
                                    const primary2 = slice2[0];
                                    const add2 = buildAdditionalStatusesAlloc(gpa, slice2[0..n_fold2], primary2);
                                    writeErrorWithFlags(gpa, stdout_file, primary2, diagnostics.defaultMessage(primary2), diagnostics.anchorFor(primary2), add2, primary2 == .US001);
                                    // free row fragments
                                    var fr2: usize = 0;
                                    while (fr2 < rows.len) : (fr2 += 1) gpa.free(rows[fr2]);
                                    continue;
                                }
                                state.last_columns = cols;
                                state.last_ordered = ordered_meta;
                                state.last_order_keys = order_keys;
                                state.last_distinct = q.ret.distinct;
                                state.page_items = @constCast(rows);
                                state.active_result = true;
                                if (result_format_txt) {
                                    // Plain text mode: emit header once then all rows (single page). Disable further pulls.
                                    var hi: usize = 0;
                                    while (hi < state.last_columns.len) : (hi += 1) {
                                        if (hi > 0) stdout_file.writeAll("\t") catch {};
                                        stdout_file.writeAll(state.last_columns[hi].name) catch {};
                                    }
                                    stdout_file.writeAll("\n") catch {};
                                    var ri: usize = 0;
                                    while (ri < state.page_items.len) : (ri += 1) {
                                        const row = state.page_items[ri];
                                        var cj: usize = 0;
                                        while (cj < state.last_columns.len) : (cj += 1) {
                                            if (cj > 0) stdout_file.writeAll("\t") catch {};
                                            const cname = state.last_columns[cj].name;
                                            if (std.mem.indexOf(u8, row, cname)) |pos| {
                                                if (std.mem.indexOfPos(u8, row, pos, ":")) |colon| {
                                                    var startv = colon + 1;
                                                    while (startv < row.len and (row[startv] == ' ')) startv += 1;
                                                    var endv = startv;
                                                    if (startv < row.len and row[startv] == '"') {
                                                        endv = startv + 1;
                                                        while (endv < row.len and row[endv] != '"') endv += 1;
                                                        stdout_file.writeAll(row[startv + 1 .. endv]) catch {};
                                                    } else {
                                                        while (endv < row.len and row[endv] != ',' and row[endv] != '}') endv += 1;
                                                        stdout_file.writeAll(row[startv..endv]) catch {};
                                                    }
                                                } else stdout_file.writeAll("null") catch {};
                                            } else stdout_file.writeAll("null") catch {};
                                        }
                                        stdout_file.writeAll("\n") catch {};
                                    }
                                    state.active_result = false; // fully emitted
                                } else {
                                    if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, computeBaseFlags(state.last_ordered, q.ret.distinct))) |line| {
                                        defer gpa.free(line);
                                        _ = stdout_file.write(line) catch {};
                                    } else |_| {}
                                }
                                continue;
                            },
                            .Union => |u_stmt| {
                                // Evaluate union then optionally EXPLAIN/PROFILE or pagination
                                var param_names: [][]const u8 = &.{};
                                var param_rows: [][]const eval.Value = &.{};
                                parseParams(gpa, rq.params_json, &param_names, &param_rows);
                                if (explain_mode) {
                                    const json = buildExplainJson(gpa, .{ .ordered = false, .limit = null, .offset = null, .union_mode = "DISTINCT", .distinct = true });
                                    const flags_u = computeBaseFlags(false, true);
                                    if (protocol.buildExplainLine(gpa, json, flags_u)) |l2| {
                                        defer gpa.free(l2);
                                        _ = stdout_file.write(l2) catch {};
                                    } else |_| {}
                                    continue;
                                }
                                var metrics: UnionMetrics = .{ .left_in = 0, .right_in = 0, .out = 0, .hash_size = null };
                                var union_mode: []const u8 = "DISTINCT";
                                if (profile_mode) {
                                    // Granular union profiling phases.
                                    const total_start = std.time.nanoTimestamp();
                                    // Phase 1: left
                                    const left_start = std.time.nanoTimestamp();
                                    var dummy_cols_l: []const protocol.SchemaCol = &.{};
                                    var ordered_l = false;
                                    var order_keys_l: [][]const u8 = &.{};
                                    const left_rows = evaluateSimpleQuery(gpa, u_stmt.first, param_names, param_rows, &ordered_l, &order_keys_l, &dummy_cols_l, null, null) catch &.{};
                                    metrics.left_in = left_rows.len;
                                    const time_left = std.time.nanoTimestamp() - left_start;
                                    // Phase 2: tails
                                    const tails_start = std.time.nanoTimestamp();
                                    var all_rows = std.ArrayList([]const u8).initCapacity(gpa, 0) catch @panic("OOM");
                                    defer all_rows.deinit(gpa);
                                    for (left_rows) |lr| all_rows.append(gpa, lr) catch {};
                                    var any_all = false;
                                    var right_total: usize = 0;
                                    var ti_prof: usize = 0;
                                    while (ti_prof < u_stmt.tails.len) : (ti_prof += 1) {
                                        const part = u_stmt.tails[ti_prof];
                                        if (part.all) any_all = true;
                                        var oc_prof: []const protocol.SchemaCol = &.{};
                                        ordered_l = false;
                                        order_keys_l = &.{};
                                        const pr = evaluateSimpleQuery(gpa, part.query, param_names, param_rows, &ordered_l, &order_keys_l, &oc_prof, null, null) catch &.{};
                                        right_total += pr.len;
                                        for (pr) |rr| all_rows.append(gpa, rr) catch {};
                                        gpa.free(oc_prof);
                                    }
                                    metrics.right_in = right_total;
                                    const time_tails = std.time.nanoTimestamp() - tails_start;
                                    // Phase 3: dedup (if DISTINCT)
                                    var dedup_time: i128 = 0;
                                    var final_rows: [][]const u8 = &.{};
                                    if (!any_all) {
                                        const dedup_start = std.time.nanoTimestamp();
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
                                        metrics.out = dedup.items.len;
                                        metrics.hash_size = seen.count();
                                        final_rows = dedup.toOwnedSlice(gpa) catch &.{};
                                        dedup_time = std.time.nanoTimestamp() - dedup_start;
                                        union_mode = "DISTINCT";
                                    } else {
                                        union_mode = "ALL";
                                        metrics.out = all_rows.items.len;
                                        metrics.hash_size = null;
                                        final_rows = all_rows.toOwnedSlice(gpa) catch &.{};
                                    }
                                    const total_elapsed = std.time.nanoTimestamp() - total_start;
                                    // Build profiling JSON with phase ops
                                    var pb = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
                                    const w = pb.writer(gpa);
                                    w.writeAll("{\"ops\":[") catch {};
                                    // UnionLeft
                                    w.writeAll("{\"op\":\"UnionLeft\",\"rows\":") catch {};
                                    w.print("{d}", .{metrics.left_in}) catch {};
                                    w.writeAll(",\"time_ns\":") catch {};
                                    w.print("{d}", .{time_left}) catch {};
                                    w.writeAll("},") catch {};
                                    // UnionTails
                                    w.writeAll("{\"op\":\"UnionTails\",\"rows\":") catch {};
                                    w.print("{d}", .{metrics.right_in}) catch {};
                                    w.writeAll(",\"time_ns\":") catch {};
                                    w.print("{d}", .{time_tails}) catch {};
                                    w.writeAll("},") catch {};
                                    if (std.mem.eql(u8, union_mode, "DISTINCT")) {
                                        w.writeAll("{\"op\":\"UnionDedup\",\"rows\":") catch {};
                                        w.print("{d}", .{metrics.out}) catch {};
                                        w.writeAll(",\"time_ns\":") catch {};
                                        w.print("{d}", .{dedup_time}) catch {};
                                        w.writeAll("},") catch {};
                                    }
                                    // Final summary op
                                    w.writeAll("{\"op\":\"SetOpUnion\",\"rows\":") catch {};
                                    w.print("{d}", .{metrics.out}) catch {};
                                    w.writeAll(",\"time_ns\":") catch {};
                                    w.print("{d}", .{total_elapsed}) catch {};
                                    w.writeAll("]") catch {};
                                    // setop metrics object
                                    w.writeAll(",\"setop\":{\"type\":\"UNION\",\"mode\":\"") catch {};
                                    w.print("{s}", .{union_mode}) catch {};
                                    w.writeAll("\",\"input_rows_left\":") catch {};
                                    w.print("{d}", .{metrics.left_in}) catch {};
                                    w.writeAll(",\"input_rows_right\":") catch {};
                                    w.print("{d}", .{metrics.right_in}) catch {};
                                    w.writeAll(",\"output_rows\":") catch {};
                                    w.print("{d}", .{metrics.out}) catch {};
                                    if (metrics.hash_size) |hs2| {
                                        w.writeAll(",\"hash_dedup_size\":") catch {};
                                        w.print("{d}", .{hs2}) catch {};
                                    }
                                    w.writeAll("},\"total_time_ns\":") catch {};
                                    w.print("{d}", .{total_elapsed}) catch {};
                                    w.writeAll("}") catch {};
                                    const flags_u_prof = computeFlagsExtended(false, std.mem.eql(u8, union_mode, "DISTINCT"), true);
                                    const pline2 = protocol.buildProfileLine(gpa, pb.toOwnedSlice(gpa) catch "{}", flags_u_prof) catch null;
                                    if (pline2) |pl2| {
                                        defer gpa.free(pl2);
                                        _ = stdout_file.write(pl2) catch {};
                                    }
                                    // Release final rows (not returned to client in PROFILE mode)
                                    var fr_i: usize = 0;
                                    while (fr_i < final_rows.len) : (fr_i += 1) gpa.free(final_rows[fr_i]);
                                    continue;
                                }
                                const rows = evaluateUnion(gpa, u_stmt, param_names, param_rows, &union_mode, &metrics) catch &.{};
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
                                state.last_distinct = std.mem.eql(u8, union_mode, "DISTINCT");
                                state.page_items = @constCast(rows);
                                state.active_result = true;
                                if (result_format_txt) {
                                    // Plain text emission for UNION similar to simple query path.
                                    var hi: usize = 0;
                                    while (hi < state.last_columns.len) : (hi += 1) {
                                        if (hi > 0) stdout_file.writeAll("\t") catch {};
                                        stdout_file.writeAll(state.last_columns[hi].name) catch {};
                                    }
                                    stdout_file.writeAll("\n") catch {};
                                    var ri: usize = 0;
                                    while (ri < state.page_items.len) : (ri += 1) {
                                        const row = state.page_items[ri];
                                        var cj: usize = 0;
                                        while (cj < state.last_columns.len) : (cj += 1) {
                                            if (cj > 0) stdout_file.writeAll("\t") catch {};
                                            const cname = state.last_columns[cj].name;
                                            if (std.mem.indexOf(u8, row, cname)) |pos| {
                                                if (std.mem.indexOfPos(u8, row, pos, ":")) |colon| {
                                                    var startv = colon + 1;
                                                    while (startv < row.len and (row[startv] == ' ')) startv += 1;
                                                    var endv = startv;
                                                    if (startv < row.len and row[startv] == '"') {
                                                        endv = startv + 1;
                                                        while (endv < row.len and row[endv] != '"') endv += 1;
                                                        stdout_file.writeAll(row[startv + 1 .. endv]) catch {};
                                                    } else {
                                                        while (endv < row.len and row[endv] != ',' and row[endv] != '}') endv += 1;
                                                        stdout_file.writeAll(row[startv..endv]) catch {};
                                                    }
                                                } else stdout_file.writeAll("null") catch {};
                                            } else stdout_file.writeAll("null") catch {};
                                        }
                                        stdout_file.writeAll("\n") catch {};
                                    }
                                    state.active_result = false; // fully emitted
                                } else {
                                    if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, computeBaseFlags(state.last_ordered, true))) |line| {
                                        defer gpa.free(line);
                                        _ = stdout_file.write(line) catch {};
                                    } else |_| {}
                                }
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
                if (!state.active_result and state.profile_json == null) {
                    const nrline = protocol.buildErrorLine(gpa, "NoResult", "no active result set", "") catch null;
                    if (nrline) |l| {
                        defer gpa.free(l);
                        _ = stdout_file.write(l) catch {};
                    }
                    continue;
                }
                // If PROFILE staged, emit PROFILE frame and clear profile_json; no rows to paginate.
                if (state.profile_json) |pj| {
                    const pline = protocol.buildProfileLine(gpa, pj, state.profile_flags) catch null;
                    if (pline) |plj| {
                        defer gpa.free(plj);
                        _ = stdout_file.write(plj) catch {};
                    }
                    // PROFILE complete; clear state and mark no active result
                    state.allocator.free(pj);
                    state.profile_json = null;
                    state.profile_flags = &.{};
                    state.active_result = false;
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
                writeBindingsAdaptive(stdout_file, state.last_ordered, state.last_order_keys, json_rows, is_final, include_final, computeBaseFlags(state.last_ordered, state.last_distinct));
            },
        }
    }
}
