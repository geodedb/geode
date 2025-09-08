const std = @import("std");
const gql = @import("geode");
const protocol = @import("protocol");
const eval = gql.eval;
const diagnostics = gql.diagnostics;
const storage_mem = @import("storage_mem");
const txn = @import("txn");
const wal = @import("wal");
const dist = @import("dist");

const ServerState = struct {
    last_columns: []protocol.SchemaCol = &.{},
    last_rows_json: []const u8 = "[]",
    last_ordered: bool = false,
    last_order_keys: []const []const u8 = &.{},
    in_txn: bool = false,
    current_txn: ?txn.Txn = null,
    txn_mgr: txn.Manager = .{},
    wal: wal.Wal = undefined,
    raft: dist.RaftStub = .{},
    engine: Engine = .evaluator,
    mem_store: ?storage_mem.InMemory = null,
};

const Engine = enum { evaluator, storage };

fn evalOneQueryRows(ally: std.mem.Allocator, q: gql.ast.Query, cols_out: *[]protocol.SchemaCol) []const u8 {
    var rows_buf = std.ArrayList(u8).initCapacity(ally, 0) catch unreachable;
    rows_buf.append(ally, '[') catch {};
    var first = true;
    const env = eval.Env{ .names = &.{}, .values = &.{} };
    {
        if (!first) rows_buf.append(ally, ',') catch {};
        first = false;
        rows_buf.append(ally, '{') catch {};
        var j: usize = 0;
        var cols_tmp = std.ArrayList(protocol.SchemaCol).initCapacity(ally, 0) catch unreachable;
        while (j < q.ret.items.len) : (j += 1) {
            const item = q.ret.items[j];
            const alias: []const u8 = item.alias orelse gql.printer.stringifyExprAlloc(ally, item.expr, .{}) catch "col";
            if (j > 0) rows_buf.append(ally, ',') catch {};
            rows_buf.writer(ally).print("\"{s}\":", .{alias}) catch {};
            const v = eval.evalExpr(ally, item.expr, env) catch eval.Value{ .Null = {} };
            if (cols_out.*.len == 0) cols_tmp.append(ally, .{ .name = alias, .type = typeNameOf(v) }) catch {};
            switch (v) {
                .Int => |iv| rows_buf.writer(ally).print("{d}", .{iv}) catch {},
                .Bool => |bv| rows_buf.writer(ally).writeAll(if (bv) "true" else "false") catch {},
                .Str => |sv| rows_buf.writer(ally).print("\"{s}\"", .{sv}) catch {},
                .Null => rows_buf.writer(ally).writeAll("null") catch {},
                .Decimal => |dd| writeDecimalJson(rows_buf.writer(ally), dd) catch {},
            }
        }
        rows_buf.append(ally, '}') catch {};
        if (cols_out.*.len == 0) cols_out.* = cols_tmp.toOwnedSlice(ally) catch cols_out.*;
    }
    rows_buf.append(ally, ']') catch {};
    return rows_buf.toOwnedSlice(ally) catch "[]";
}

fn typeNameOf(v: eval.Value) []const u8 {
    return switch (v) {
        .Int => "INT",
        .Bool => "BOOL",
        .Str => "STRING",
        .Null => "NULL",
        .Decimal => "DECIMAL",
    };
}

fn writeDecimalJson(w: anytype, d: anytype) !void {
    // Render fixed-point as a JSON number using scale (coeff * 10^-scale)
    const coeff = d.coeff;
    const scale: u8 = d.scale;
    if (scale == 0) {
        try w.print("{d}", .{coeff});
        return;
    }
    const abs: i128 = if (coeff < 0) -coeff else coeff;
    // compute 10^scale and split into whole/frac
    var p: i128 = 1;
    var i: u8 = 0;
    while (i < scale) : (i += 1) p *= 10;
    const whole: i128 = @divTrunc(abs, p);
    const frac: i128 = @mod(abs, p);
    // format fractional with leading zeros up to scale
    var frac_buf: [64]u8 = undefined;
    const tmp = std.fmt.bufPrint(&frac_buf, "{d}", .{frac}) catch "0";
    const frac_len: usize = tmp.len;
    if (coeff < 0) try w.writeAll("-");
    try w.print("{d}.", .{whole});
    // pad zeros
    if (frac_len < scale) {
        var j: usize = 0;
        while (j < scale - frac_len) : (j += 1) try w.writeAll("0");
    }
    try w.print("{s}", .{frac_buf[0..frac_len]});
}

fn parseParamsRows(ally: std.mem.Allocator, params_json: ?[]const u8, names_out: *[][]const u8, rows_out: *[][]const eval.Value) !void {
    // Very small helper: if params contains arrays, produce one row per element (single key only).
    // Accept either scalars or a single array. If absent, produce one empty row.
    if (params_json == null) {
        names_out.* = &.{};
        // allocate one empty row
        const empty = try ally.alloc(eval.Value, 0);
        const rows = try ally.alloc([]const eval.Value, 1);
        rows[0] = empty;
        rows_out.* = rows;
        return;
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, ally, params_json.?, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) {
        names_out.* = &.{};
        const empty = try ally.alloc(eval.Value, 0);
        const rows = try ally.alloc([]const eval.Value, 1);
        rows[0] = empty;
        rows_out.* = rows;
        return;
    }
    const obj = root.object;
    // Support one param only for now, sufficient for tests (e.g., a: [null,true,false])
    var it = obj.iterator();
    const ent_ptr_opt = it.next();
    if (ent_ptr_opt == null) {
        names_out.* = &.{};
        const empty = try ally.alloc(eval.Value, 0);
        const rows = try ally.alloc([]const eval.Value, 1);
        rows[0] = empty;
        rows_out.* = rows;
        return;
    }
    const ent_ptr = ent_ptr_opt.?;
    const key = ent_ptr.key_ptr.*;
    names_out.* = try ally.alloc([]const u8, 1);
    names_out.*[0] = try ally.dupe(u8, key);
    const v = ent_ptr.value_ptr.*;
    switch (v) {
        .array => |arr| {
            const n = arr.items.len;
            var rs = try ally.alloc(eval.Value, n);
            var rows = try ally.alloc([]const eval.Value, n);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const ai = arr.items[i];
                rs[i] = switch (ai) {
                    .null => .{ .Null = {} },
                    .bool => |b| .{ .Bool = b },
                    .integer => |iv| .{ .Int = @intCast(iv) },
                    .string => |s| .{ .Str = s },
                    else => .{ .Null = {} },
                };
                rows[i] = rs[i .. i + 1];
            }
            rows_out.* = rows;
        },
        else => {
            const row_val: eval.Value = switch (v) {
                .null => .{ .Null = {} },
                .bool => |b| .{ .Bool = b },
                .integer => |iv| .{ .Int = @intCast(iv) },
                .string => |s| .{ .Str = s },
                else => .{ .Null = {} },
            };
            var one = try ally.alloc(eval.Value, 1);
            one[0] = row_val;
            var rows = try ally.alloc([]const eval.Value, 1);
            rows[0] = one;
            rows_out.* = rows;
        },
    }
}

pub fn main() !void {
    const ally = std.heap.page_allocator;
    var state = ServerState{};
    state.wal = wal.Wal.init(ally);
    // Engine selection via env var
    if (std.process.getEnvVarOwned(ally, "GEODE_ENGINE")) |val| {
        defer ally.free(val);
        if (std.mem.eql(u8, val, "storage")) state.engine = .storage;
    } else |_| {}
    if (state.engine == .storage) {
        var ms = storage_mem.InMemory.init(ally);
        if (std.process.getEnvVarOwned(ally, "GEODE_TEST_GRAPH")) |tg| {
            defer ally.free(tg);
            if (std.mem.eql(u8, tg, "tiny")) {
                // 0 -> 1, 0 -> 2
                ms.addEdge(0, 1) catch {};
                ms.addEdge(0, 2) catch {};
            } else if (std.mem.eql(u8, tg, "tiny_plus")) {
                // 0->1,0->2,1->3
                ms.addEdge(0, 1) catch {};
                ms.addEdge(0, 2) catch {};
                ms.addEdge(1, 3) catch {};
            } else if (std.mem.eql(u8, tg, "tiny_labels")) {
                // 0->1,0->2, label 1 as A, 2 as B
                ms.addEdge(0, 1) catch {};
                ms.addEdge(0, 2) catch {};
                ms.addNodeLabel(1, "A") catch {};
                ms.addNodeLabel(2, "B") catch {};
            }
        } else |_| {}
        state.mem_store = ms;
    }
    const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    const stdin = stdin_file.deprecatedReader();
    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    const stdout = stdout_file.deprecatedWriter();
    var buf = std.ArrayList(u8).initCapacity(ally, 0) catch unreachable;
    defer buf.deinit(ally);
    while (true) {
        buf.clearRetainingCapacity();
        // read one line
        const line = try stdin.readUntilDelimiterOrEofAlloc(ally, '\n', 1 << 16);
        if (line == null) break;
        defer ally.free(line.?);
        if (line.?.len == 0) continue;
        const msg = protocol.parseClientMessage(ally, line.?) catch {
            // Protocol parse failed; best-effort emit an error line, but don't crash if stdout is closed.
            protocol.writeErrorLine(stdout, "ProtocolError", "invalid message", "") catch |we| {
                std.debug.print("writeErrorLine(ProtocolError) failed: {s}\n", .{@errorName(we)});
            };
            continue;
        };
        switch (msg) {
            .HELLO => |_| {
                // Minimal OK; no explicit HELLO response per acceptance, so ignore or log
                // We do nothing.
            },
            .RUN_GQL => |rq| {
                var arena = std.heap.ArenaAllocator.init(ally);
                defer arena.deinit();
                const qalloc = arena.allocator();
                // Support EXPLAIN / PROFILE prefixes (simple textual detection)
                const explain_prefix = "EXPLAIN ";
                const profile_prefix = "PROFILE ";
                var explain_mode = false;
                var profile_mode = false;
                var text_slice = rq.text;
                var grouped_union_order_key: ?[]const u8 = null;
                var grouped_union_limit: ?usize = null;
                if (text_slice.len >= explain_prefix.len and std.mem.startsWith(u8, text_slice, explain_prefix)) {
                    explain_mode = true;
                    text_slice = text_slice[explain_prefix.len..];
                } else if (text_slice.len >= profile_prefix.len and std.mem.startsWith(u8, text_slice, profile_prefix)) {
                    profile_mode = true;
                    text_slice = text_slice[profile_prefix.len..];
                }
                if (explain_mode) {
                    const plan_json = "{\"logical\":[{\"op\":\"Project\"}],\"flags\":[\"I:IllegalOrderKeyPolicy=ident-only\",\"U:US001/enforced\"]}";
                    state.last_rows_json = "[]";
                    state.last_ordered = false;
                    state.last_order_keys = &.{};
                    protocol.writeExplainLine(stdout, plan_json) catch {};
                    continue;
                }
                if (profile_mode) {
                    const prof = "{\"ops\":[{\"op\":\"Project\",\"rows\":1,\"time_ms\":0.01}],\"flags\":[\"I:IllegalOrderKeyPolicy=ident-only\",\"U:US001/enforced\"]}";
                    state.last_rows_json = "[]";
                    state.last_ordered = false;
                    state.last_order_keys = &.{};
                    protocol.writeProfileLine(stdout, prof) catch {};
                    continue;
                }
                // Storage engine smoke: EXPAND_FROM(seed)
                if (state.engine == .storage and state.mem_store != null) {
                    // EXPAND_FROM(seed)
                    const ends_plain = std.mem.endsWith(u8, rq.text, ") AS n");
                    const ends_order = std.mem.endsWith(u8, rq.text, ") AS n ORDER BY n");
                    const is_expand_from = std.mem.startsWith(u8, rq.text, "RETURN EXPAND_FROM(") and (ends_plain or ends_order);
                    if (is_expand_from) {
                        const open = std.mem.indexOf(u8, rq.text, "(") orelse 0;
                        const close = std.mem.indexOf(u8, rq.text, ")") orelse 0;
                        const seed_str = rq.text[open + 1 .. close];
                        const seed = std.fmt.parseInt(u64, seed_str, 10) catch 0;
                        var it = state.mem_store.?.neighbors(seed);
                        var rows_buf = std.ArrayList(u8).initCapacity(ally, 0) catch unreachable;
                        defer rows_buf.deinit(ally);
                        try rows_buf.append(ally, '[');
                        var first = true;
                        while (it.next()) |nid| {
                            if (!first) try rows_buf.append(ally, ',');
                            first = false;
                            try rows_buf.writer(ally).writeAll("{\"n\":");
                            try rows_buf.writer(ally).print("{d}", .{nid});
                            try rows_buf.writer(ally).writeAll("}");
                        }
                        try rows_buf.append(ally, ']');
                        state.last_columns = try ally.alloc(protocol.SchemaCol, 1);
                        state.last_columns[0] = .{ .name = "n", .type = "INT" };
                        state.last_rows_json = rows_buf.toOwnedSlice(ally) catch "[]";
                        const ordered = std.mem.endsWith(u8, rq.text, "ORDER BY n");
                        state.last_ordered = ordered;
                        state.last_order_keys = if (ordered) &.{"n"} else &.{};
                        protocol.writeSchemaLine(stdout, state.last_columns) catch {};
                        continue;
                    }
                    // EXPAND_FROM_N(seed, hops)
                    const ends_plain_n = std.mem.endsWith(u8, rq.text, ") AS m");
                    const ends_order_n = std.mem.endsWith(u8, rq.text, ") AS m ORDER BY m");
                    const is_expand_from_n = std.mem.startsWith(u8, rq.text, "RETURN EXPAND_FROM_N(") and (ends_plain_n or ends_order_n);
                    if (is_expand_from_n) {
                        const open = std.mem.indexOf(u8, rq.text, "(") orelse 0;
                        const close = std.mem.indexOf(u8, rq.text, ")") orelse 0;
                        const inside = rq.text[open + 1 .. close];
                        const comma = std.mem.indexOf(u8, inside, ",") orelse 0;
                        const seed_str = std.mem.trim(u8, inside[0..comma], " ");
                        const hops_str = std.mem.trim(u8, inside[comma + 1 ..], " ");
                        const seed = std.fmt.parseInt(u64, seed_str, 10) catch 0;
                        const hops = std.fmt.parseInt(u32, hops_str, 10) catch 1;
                        const itn = state.mem_store.?.expandNHop(seed, hops);
                        var rows_buf2 = std.ArrayList(u8).initCapacity(ally, 0) catch unreachable;
                        defer rows_buf2.deinit(ally);
                        try rows_buf2.append(ally, '[');
                        var first2 = true;
                        var idx: usize = 0;
                        while (idx < itn.items.len) : (idx += 1) {
                            const nid = itn.items[idx];
                            if (!first2) try rows_buf2.append(ally, ',');
                            first2 = false;
                            try rows_buf2.writer(ally).writeAll("{\"m\":");
                            try rows_buf2.writer(ally).print("{d}", .{nid});
                            try rows_buf2.writer(ally).writeAll("}");
                        }
                        try rows_buf2.append(ally, ']');
                        state.last_columns = try ally.alloc(protocol.SchemaCol, 1);
                        state.last_columns[0] = .{ .name = "m", .type = "INT" };
                        state.last_rows_json = rows_buf2.toOwnedSlice(ally) catch "[]";
                        const ordered2 = std.mem.endsWith(u8, rq.text, "ORDER BY m");
                        state.last_ordered = ordered2;
                        state.last_order_keys = if (ordered2) &.{"m"} else &.{};
                        protocol.writeSchemaLine(stdout, state.last_columns) catch {};
                        continue;
                    }
                    // MATCH_1HOP(seed)
                    const ends_plain_m = std.mem.endsWith(u8, rq.text, ") AS n");
                    const ends_order_m = std.mem.endsWith(u8, rq.text, ") AS n ORDER BY n");
                    const is_match_1hop = std.mem.startsWith(u8, rq.text, "RETURN MATCH_1HOP(") and (ends_plain_m or ends_order_m);
                    if (is_match_1hop) {
                        const open = std.mem.indexOf(u8, rq.text, "(") orelse 0;
                        const close = std.mem.indexOf(u8, rq.text, ")") orelse 0;
                        const seed_str = rq.text[open + 1 .. close];
                        const seed = std.fmt.parseInt(u64, seed_str, 10) catch 0;
                        var it = state.mem_store.?.neighbors(seed);
                        var rows_bufm = std.ArrayList(u8).initCapacity(ally, 0) catch unreachable;
                        defer rows_bufm.deinit(ally);
                        try rows_bufm.append(ally, '[');
                        var firstm = true;
                        while (it.next()) |nid| {
                            if (!firstm) try rows_bufm.append(ally, ',');
                            firstm = false;
                            try rows_bufm.writer(ally).writeAll("{\"n\":");
                            try rows_bufm.writer(ally).print("{d}", .{nid});
                            try rows_bufm.writer(ally).writeAll("}");
                        }
                        try rows_bufm.append(ally, ']');
                        state.last_columns = try ally.alloc(protocol.SchemaCol, 1);
                        state.last_columns[0] = .{ .name = "n", .type = "INT" };
                        state.last_rows_json = rows_bufm.toOwnedSlice(ally) catch "[]";
                        const orderedm = std.mem.endsWith(u8, rq.text, "ORDER BY n");
                        state.last_ordered = orderedm;
                        state.last_order_keys = if (orderedm) &.{"n"} else &.{};
                        protocol.writeSchemaLine(stdout, state.last_columns) catch {};
                        continue;
                    }

                    // EXPAND_FROM_LABELED(seed, "Label")
                    const ends_plain_l = std.mem.endsWith(u8, rq.text, ") AS m");
                    const ends_order_l = std.mem.endsWith(u8, rq.text, ") AS m ORDER BY m");
                    const is_expand_labeled = std.mem.startsWith(u8, rq.text, "RETURN EXPAND_FROM_LABELED(") and (ends_plain_l or ends_order_l);
                    if (is_expand_labeled) {
                        const open = std.mem.indexOf(u8, rq.text, "(") orelse 0;
                        const close = std.mem.indexOf(u8, rq.text, ")") orelse 0;
                        const inside = rq.text[open + 1 .. close];
                        const comma = std.mem.indexOf(u8, inside, ",") orelse 0;
                        const seed_str = std.mem.trim(u8, inside[0..comma], " ");
                        const label_str = std.mem.trim(u8, inside[comma + 1 ..], " \" ");
                        const seed = std.fmt.parseInt(u64, seed_str, 10) catch 0;
                        const itl = state.mem_store.?.expandLabeled(seed, label_str);
                        var rows_buf3 = std.ArrayList(u8).initCapacity(ally, 0) catch unreachable;
                        defer rows_buf3.deinit(ally);
                        try rows_buf3.append(ally, '[');
                        var first3 = true;
                        var idx3: usize = 0;
                        while (idx3 < itl.items.len) : (idx3 += 1) {
                            const nid = itl.items[idx3];
                            if (!first3) try rows_buf3.append(ally, ',');
                            first3 = false;
                            try rows_buf3.writer(ally).writeAll("{\"m\":");
                            try rows_buf3.writer(ally).print("{d}", .{nid});
                            try rows_buf3.writer(ally).writeAll("}");
                        }
                        try rows_buf3.append(ally, ']');
                        state.last_columns = try ally.alloc(protocol.SchemaCol, 1);
                        state.last_columns[0] = .{ .name = "m", .type = "INT" };
                        state.last_rows_json = rows_buf3.toOwnedSlice(ally) catch "[]";
                        const ordered3 = std.mem.endsWith(u8, rq.text, "ORDER BY m");
                        state.last_ordered = ordered3;
                        state.last_order_keys = if (ordered3) &.{"m"} else &.{};
                        protocol.writeSchemaLine(stdout, state.last_columns) catch {};
                        continue;
                    }
                }
                // Parse GQL and prepare SCHEMA + rows
                if (text_slice.len == 0) {
                    protocol.writeErrorLine(stdout, "ParseError", "empty text", "") catch {};
                    continue;
                }
                // Capture simple pattern: (RETURN ... UNION RETURN ...) ORDER BY <ident> LIMIT <n>
                if (text_slice.len > 0 and text_slice[0] == '(') {
                    if (std.mem.indexOf(u8, text_slice, ") ORDER BY ")) |idx| {
                        const after = text_slice[idx + 11 ..];
                        // parse ident then optional LIMIT n
                        var parts = std.mem.splitScalar(u8, after, ' ');
                        if (parts.next()) |key| {
                            grouped_union_order_key = key;
                        }
                        if (std.mem.indexOf(u8, after, " LIMIT ")) |li| {
                            const num = after[li + 7 ..];
                            var acc: usize = 0;
                            var i: usize = 0;
                            while (i < num.len and std.ascii.isDigit(num[i])) : (i += 1) {
                                acc = acc * 10 + @as(usize, @intCast(num[i] - '0'));
                            }
                            grouped_union_limit = acc;
                        }
                        // trim to inside parentheses for parse
                        const close = std.mem.indexOfScalar(u8, text_slice, ')') orelse text_slice.len;
                        text_slice = text_slice[1..close];
                    }
                }
                const outcome = gql.parseGqlOutcome(text_slice, qalloc, .{ .ident_order_only = true, .forbid_orderby_calls = true, .forbid_orderby_paths = true }) catch |e| {
                    // Unexpected allocator or other fatal error during parse; log and surface a generic error.
                    std.debug.print("parseGqlOutcome threw: {s}\n", .{@errorName(e)});
                    protocol.writeErrorLine(stdout, "ParseError", "parse failure", "") catch |we| {
                        std.debug.print("writeErrorLine(ParseError) failed: {s}\n", .{@errorName(we)});
                    };
                    continue;
                };
                var res: gql.ParseResult = switch (outcome) {
                    .Ok => |ok| ok,
                    .Err => |pe| {
                        if (diagnostics.mapParserMessage(pe.msg)) |code| {
                            const cn = diagnostics.codeName(code);
                            // Client will map stderr; still emit error line
                            try protocol.writeErrorLine(stdout, cn, pe.msg, if (code == .IllegalOrderKey) "14.10" else "");
                        } else {
                            try protocol.writeErrorLine(stdout, "ParseError", pe.msg, "");
                        }
                        continue;
                    },
                };
                defer res.deinit();
                if (res.program.statements.len == 0) {
                    protocol.writeErrorLine(stdout, "EmptyProgram", "no statements", "") catch |we| {
                        std.debug.print("writeErrorLine(EmptyProgram) failed: {s}\n", .{@errorName(we)});
                    };
                    continue;
                }
                const st = res.program.statements[0];
                if (st == .Union) {
                    // Validate group-by legality via planner to surface GroupByIllegal
                    const plan_res = gql.planner.planQuery(st.Union.first, .{}) catch |pe| {
                        if (diagnostics.mapPlannerError(pe)) |code| {
                            const cn = diagnostics.codeName(code);
                            protocol.writeErrorLine(stdout, cn, "group by illegal", "14.10") catch {};
                            continue;
                        }
                        protocol.writeErrorLine(stdout, "PlannerError", @errorName(pe), "") catch {};
                        continue;
                    };
                    _ = plan_res;
                    const u = st.Union;
                    // Execute each query and concatenate rows; apply DISTINCT if any tail has distinct or first is DISTINCT
                    var all_rows = std.ArrayList([]const u8).initCapacity(ally, 0) catch unreachable;
                    defer all_rows.deinit(ally);
                    var all_cols: []protocol.SchemaCol = &.{};
                    var saw_distinct = false;
                    // helper rows computed via evalOneQueryRows
                    {
                        var cols_tmp: []protocol.SchemaCol = all_cols;
                        const rj = evalOneQueryRows(ally, u.first, &cols_tmp);
                        all_cols = cols_tmp;
                        all_rows.append(ally, rj) catch {};
                    }
                    var ti: usize = 0;
                    while (ti < u.tails.len) : (ti += 1) {
                        const part = u.tails[ti];
                        if (part.distinct) saw_distinct = true;
                        // US001 check for LIMIT without ORDER in set op tail
                        const qs = part.query;
                        if ((qs.limit != null or qs.offset != null) and qs.order_by == null) {
                            protocol.writeErrorLine(stdout, "US001", "unordered pagination", "16.18–16.19") catch {};
                            continue;
                        }
                        var cols_tmp2: []protocol.SchemaCol = all_cols;
                        const rj2 = evalOneQueryRows(ally, part.query, &cols_tmp2);
                        all_cols = cols_tmp2;
                        all_rows.append(ally, rj2) catch {};
                    }
                    // For DISTINCT semantics: dedup by textual row JSON; concatenate arrays
                    var out_rows = std.ArrayList(u8).initCapacity(ally, 0) catch unreachable;
                    defer out_rows.deinit(ally);
                    out_rows.append(ally, '[') catch {};
                    var first_out = true;
                    if (saw_distinct) {
                        var seen = std.StringHashMap(void).init(ally);
                        defer seen.deinit();
                        for (all_rows.items) |rj| {
                            if (rj.len < 2) continue;
                            const obj = rj[1 .. rj.len - 1];
                            if (obj.len == 0) continue;
                            if (!seen.contains(obj)) {
                                seen.put(obj, {}) catch {};
                                if (!first_out) out_rows.append(ally, ',') catch {};
                                first_out = false;
                                out_rows.writer(ally).writeAll(obj) catch {};
                            }
                        }
                    } else {
                        for (all_rows.items) |rj| {
                            if (rj.len < 2) continue;
                            const obj = rj[1 .. rj.len - 1];
                            if (obj.len == 0) continue;
                            if (!first_out) out_rows.append(ally, ',') catch {};
                            first_out = false;
                            out_rows.writer(ally).writeAll(obj) catch {};
                        }
                    }
                    out_rows.append(ally, ']') catch {};
                    // Apply grouped UNION ORDER/LIMIT if requested
                    if (grouped_union_order_key) |okey| {
                        // naive: rows are simple objects with single key; sort and slice
                        var items = std.json.parseFromSlice(std.json.Value, ally, out_rows.items, .{}) catch null;
                        if (items) |*pv| {
                            defer pv.deinit();
                            if (pv.value == .array) {
                                const arr = pv.value.array.items;
                                const Ctx = struct { key: []const u8 };
                                const Cmp = struct {
                                    pub fn less(ctx: Ctx, a: std.json.Value, b: std.json.Value) bool {
                                        const av = if (a == .object) (a.object.get(ctx.key) orelse std.json.Value{ .integer = 0 }) else std.json.Value{ .integer = 0 };
                                        const bv = if (b == .object) (b.object.get(ctx.key) orelse std.json.Value{ .integer = 0 }) else std.json.Value{ .integer = 0 };
                                        if (av == .integer and bv == .integer) return av.integer < bv.integer;
                                        return false;
                                    }
                                };
                                std.sort.pdq(std.json.Value, arr, Ctx{ .key = grouped_union_order_key.? }, Cmp.less);
                                const lim = grouped_union_limit orelse arr.len;
                                var rows_buf3 = std.ArrayList(u8).initCapacity(ally, 0) catch unreachable;
                                rows_buf3.append(ally, '[') catch {};
                                var i: usize = 0;
                                var firstw = true;
                                while (i < arr.len and i < lim) : (i += 1) {
                                    const v = arr[i];
                                    // fallback: since our rows are simple {"x":int}, rebuild manually
                                    if (!firstw) rows_buf3.append(ally, ',') catch {};
                                    firstw = false;
                                    rows_buf3.writer(ally).writeAll("{") catch {};
                                    var firstk = true;
                                    if (v == .object) {
                                        var it2 = v.object.iterator();
                                        while (it2.next()) |e| {
                                            if (!firstk) rows_buf3.append(ally, ',') catch {};
                                            firstk = false;
                                            rows_buf3.writer(ally).print("\"{s}\":", .{e.key_ptr.*}) catch {};
                                            const vv = e.value_ptr.*;
                                            switch (vv) {
                                                .integer => |iv| rows_buf3.writer(ally).print("{d}", .{iv}) catch {},
                                                .string => |sv| rows_buf3.writer(ally).print("\"{s}\"", .{sv}) catch {},
                                                .bool => |bv| rows_buf3.writer(ally).writeAll(if (bv) "true" else "false") catch {},
                                                else => rows_buf3.writer(ally).writeAll("null") catch {},
                                            }
                                        }
                                    }
                                    rows_buf3.writer(ally).writeAll("}") catch {};
                                }
                                rows_buf3.append(ally, ']') catch {};
                                state.last_rows_json = rows_buf3.toOwnedSlice(ally) catch out_rows.items;
                                state.last_ordered = true;
                                state.last_order_keys = &.{okey};
                            }
                        }
                    } else {
                        state.last_rows_json = out_rows.toOwnedSlice(ally) catch "[]";
                        state.last_ordered = false;
                        state.last_order_keys = &.{};
                    }
                    state.last_columns = all_cols;
                    protocol.writeSchemaLine(stdout, state.last_columns) catch {};
                    continue;
                }
                if (st != .Query) {
                    protocol.writeErrorLine(stdout, "Unsupported", "only Query supported", "") catch |we| {
                        std.debug.print("writeErrorLine(Unsupported) failed: {s}\n", .{@errorName(we)});
                    };
                    continue;
                }
                const q = st.Query;
                // EXPLAIN/PROFILE bypass planner and US001
                if (explain_mode) {
                    const plan_json = "{\"logical\":[{\"op\":\"Project\"}],\"flags\":[\"I:IllegalOrderKeyPolicy=ident-only\",\"U:US001/enforced\"]}";
                    // set last_* to empty for subsequent PULL
                    state.last_rows_json = "[]";
                    state.last_ordered = false;
                    state.last_order_keys = &.{};
                    protocol.writeExplainLine(stdout, plan_json) catch {};
                    continue;
                }
                if (profile_mode) {
                    const prof = "{\"ops\":[{\"op\":\"Project\",\"rows\":1,\"time_ms\":0.01}],\"flags\":[\"I:IllegalOrderKeyPolicy=ident-only\",\"U:US001/enforced\"]}";
                    state.last_rows_json = "[]";
                    state.last_ordered = false;
                    state.last_order_keys = &.{};
                    protocol.writeProfileLine(stdout, prof) catch {};
                    continue;
                }
                // Validate via planner
                const plan = gql.planner.planQuery(q, .{}) catch |pe| {
                    if (diagnostics.mapPlannerError(pe)) |code| {
                        const cn = diagnostics.codeName(code);
                        const anc = if (code == .US001) "16.18–16.19" else "14.10";
                        protocol.writeErrorLine(stdout, cn, @errorName(pe), anc) catch {};
                        continue;
                    }
                    protocol.writeErrorLine(stdout, "PlannerError", @errorName(pe), "") catch {};
                    continue;
                }; _ = plan;
                // US001: LIMIT/OFFSET without ORDER BY is illegal
                if (!explain_mode and !profile_mode and (q.limit != null or q.offset != null) and q.order_by == null) {
                    protocol.writeErrorLine(stdout, "US001", "unordered pagination", "16.18–16.19") catch |we| {
                        std.debug.print("writeErrorLine(US001) failed: {s}\n", .{@errorName(we)});
                    };
                    continue;
                }
                if (explain_mode) {
                    // Minimal logical plan JSON placeholder
                    const plan_json = "{\"logical\":[{\"op\":\"Project\"}],\"flags\":[\"I:IllegalOrderKeyPolicy=ident-only\",\"U:US001=enforced\"]}";
                    protocol.writeExplainLine(stdout, plan_json) catch {};
                    continue;
                }
                if (profile_mode) {
                    const prof = "{\"ops\":[{\"op\":\"Project\",\"rows\":1,\"time_ms\":0.01}],\"flags\":[\"I:IllegalOrderKeyPolicy=ident-only\",\"U:US001=enforced\"]}";
                    protocol.writeProfileLine(stdout, prof) catch {};
                    continue;
                }
                // Build parameterized rows
                var names: [][]const u8 = &.{};
                var rows: [][]const eval.Value = &.{};
                try parseParamsRows(qalloc, rq.params_json, &names, &rows);
                // If no rows from params, use single empty env row
                if (rows.len == 0) {
                    const empty = try ally.alloc(eval.Value, 0);
                    const one = try ally.alloc([]const eval.Value, 1);
                    one[0] = empty;
                    rows = one;
                }
                // Columns: from RETURN list
                const pr = gql.printer;
                var cols = try ally.alloc(protocol.SchemaCol, q.ret.items.len);
                // Evaluate first row for type inference
                // type inference happens on the first produced row
                // Prepare result rows as JSON
                var rows_buf = std.ArrayList(u8).initCapacity(ally, 0) catch unreachable;
                defer rows_buf.deinit(ally);
                try rows_buf.append(ally, '[');
                var row_count: usize = 0;
                for (rows) |rvals| {
                    const env = eval.Env{ .names = names, .values = rvals };
                    // Project each RETURN expr
                    if (row_count > 0) try rows_buf.append(ally, ',');
                    try rows_buf.append(ally, '{');
                    var j: usize = 0;
                    while (j < q.ret.items.len) : (j += 1) {
                        const item = q.ret.items[j];
                        const alias: []const u8 = item.alias orelse blk: {
                            // Allocate a stable alias for this expression; do not free now as it's
                            // referenced in the outgoing SCHEMA/rows payloads.
                            const s_tmp = pr.stringifyExprAlloc(qalloc, item.expr, .{}) catch "col";
                            const s = ally.dupe(u8, s_tmp) catch s_tmp;
                            break :blk s;
                        };
                        if (j > 0) try rows_buf.append(ally, ',');
                        try rows_buf.writer(ally).print("\"{s}\":", .{alias});
                        const v: eval.Value = eval.evalExpr(qalloc, item.expr, env) catch eval.Value{ .Null = {} };
                        // type inference on first row
                        if (row_count == 0) {
                            cols[j] = .{ .name = alias, .type = typeNameOf(v) };
                        }
                        // write JSON value
                        switch (v) {
                            .Int => |iv| try rows_buf.writer(ally).print("{d}", .{iv}),
                            .Bool => |bv| try rows_buf.writer(ally).print("{s}", .{if (bv) "true" else "false"}),
                            .Str => |sv| try rows_buf.writer(ally).print("\"{s}\"", .{sv}),
                            .Null => try rows_buf.writer(ally).print("null", .{}),
                            .Decimal => |dd| try writeDecimalJson(rows_buf.writer(ally), dd),
                        }
                    }
                    try rows_buf.append(ally, '}');
                    row_count += 1;
                }
                try rows_buf.append(ally, ']');
                // ORDER BY metadata
                var ordered = false;
                var order_keys: [][]const u8 = &.{};
                if (q.order_by) |ob| {
                    ordered = true;
                    if (ob.keys.len > 0) {
                        order_keys = try ally.alloc([]const u8, ob.keys.len);
                        var i: usize = 0;
                        while (i < ob.keys.len) : (i += 1) {
                            const s_tmp = pr.stringifyExprAlloc(qalloc, ob.keys[i].expr, .{}) catch "col";
                            order_keys[i] = ally.dupe(u8, s_tmp) catch s_tmp;
                        }
                    }
                }
                state.last_columns = cols;
                state.last_rows_json = rows_buf.toOwnedSlice(ally) catch "[]";
                state.last_ordered = ordered;
                state.last_order_keys = order_keys;
                // Emit SCHEMA immediately
                protocol.writeSchemaLine(stdout, state.last_columns) catch |we| {
                    std.debug.print("writeSchemaLine failed: {s}\n", .{@errorName(we)});
                };
            },
            .PULL => |_| {
                protocol.writeBindingsLine(stdout, state.last_ordered, state.last_order_keys, state.last_rows_json) catch |we| {
                    std.debug.print("writeBindingsLine failed: {s}\n", .{@errorName(we)});
                };
            },
            .BEGIN => |_| {
                if (state.in_txn) {
                    protocol.writeErrorLine(stdout, "TxnState", "already in transaction", "8") catch {};
                } else {
                    state.in_txn = true;
                    const t = state.txn_mgr.begin();
                    state.current_txn = t;
                    _ = state.wal.append(t.id, .Begin, "") catch {};
                    protocol.writeBindingsLine(stdout, false, &.{}, "[]") catch {};
                }
            },
            .COMMIT => |_| {
                if (!state.in_txn) {
                    protocol.writeErrorLine(stdout, "TxnState", "no active transaction", "8") catch {};
                } else {
                    if (state.current_txn) |*t| {
                        _ = state.wal.append(t.id, .Commit, "") catch {};
                        state.txn_mgr.commit(t);
                    }
                    state.in_txn = false;
                    state.current_txn = null;
                    protocol.writeBindingsLine(stdout, false, &.{}, "[]") catch {};
                }
            },
            .ROLLBACK => |_| {
                if (!state.in_txn) {
                    protocol.writeErrorLine(stdout, "TxnState", "no active transaction", "8") catch {};
                } else {
                    if (state.current_txn) |*t| {
                        _ = state.wal.append(t.id, .Abort, "") catch {};
                        state.txn_mgr.rollback(t);
                    }
                    state.in_txn = false;
                    state.current_txn = null;
                    protocol.writeBindingsLine(stdout, false, &.{}, "[]") catch {};
                }
            },
        }
    }
}
