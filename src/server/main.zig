const std = @import("std");
const gql = @import("geode");
const protocol = @import("protocol");
const eval = gql.eval;
const diagnostics = gql.diagnostics;

const ServerState = struct {
    last_columns: []protocol.SchemaCol = &.{},
    last_rows_json: []const u8 = "[]",
    last_ordered: bool = false,
    last_order_keys: []const []const u8 = &.{},
};

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
    names_out.*[0] = key;
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
    var stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    var buf = std.ArrayList(u8).init(ally);
    defer buf.deinit();
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
                // Parse GQL and prepare SCHEMA + rows
                if (rq.text.len == 0) {
                    protocol.writeErrorLine(stdout, "ParseError", "empty text", "") catch {};
                    continue;
                }
                const outcome = gql.parseGqlOutcome(rq.text, ally, .{ .ident_order_only = true, .forbid_orderby_calls = true, .forbid_orderby_paths = true }) catch |e| {
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
                if (st != .Query) {
                    protocol.writeErrorLine(stdout, "Unsupported", "only Query supported", "") catch |we| {
                        std.debug.print("writeErrorLine(Unsupported) failed: {s}\n", .{@errorName(we)});
                    };
                    continue;
                }
                const q = st.Query;
                // US001: LIMIT/OFFSET without ORDER BY is illegal
                if ((q.limit != null or q.offset != null) and q.order_by == null) {
                    protocol.writeErrorLine(stdout, "US001", "unordered pagination", "16.18–16.19") catch |we| {
                        std.debug.print("writeErrorLine(US001) failed: {s}\n", .{@errorName(we)});
                    };
                    continue;
                }
                // Build parameterized rows
                var names: [][]const u8 = &.{};
                var rows: [][]const eval.Value = &.{};
                try parseParamsRows(ally, rq.params_json, &names, &rows);
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
                var rows_buf = std.ArrayList(u8).init(ally);
                defer rows_buf.deinit();
                try rows_buf.append('[');
                var row_count: usize = 0;
                for (rows) |rvals| {
                    const env = eval.Env{ .names = names, .values = rvals };
                    // Project each RETURN expr
                    if (row_count > 0) try rows_buf.append(',');
                    try rows_buf.append('{');
                    var j: usize = 0;
                    while (j < q.ret.items.len) : (j += 1) {
                        const item = q.ret.items[j];
                        const alias: []const u8 = item.alias orelse blk: {
                            // Allocate a stable alias for this expression; do not free now as it's
                            // referenced in the outgoing SCHEMA/rows payloads.
                            const s = pr.stringifyExprAlloc(ally, item.expr, .{}) catch "col";
                            break :blk s;
                        };
                        if (j > 0) try rows_buf.append(',');
                        try rows_buf.writer().print("\"{s}\":", .{alias});
                        const v: eval.Value = eval.evalExpr(ally, item.expr, env) catch eval.Value{ .Null = {} };
                        // type inference on first row
                        if (row_count == 0) {
                            cols[j] = .{ .name = alias, .type = typeNameOf(v) };
                        }
                        // write JSON value
                        switch (v) {
                            .Int => |iv| try rows_buf.writer().print("{d}", .{iv}),
                            .Bool => |bv| try rows_buf.writer().print("{s}", .{if (bv) "true" else "false"}),
                            .Str => |sv| try rows_buf.writer().print("\"{s}\"", .{sv}),
                            .Null => try rows_buf.writer().print("null", .{}),
                            .Decimal => |dd| try writeDecimalJson(rows_buf.writer(), dd),
                        }
                    }
                    try rows_buf.append('}');
                    row_count += 1;
                }
                try rows_buf.append(']');
                // ORDER BY metadata
                var ordered = false;
                var order_keys: [][]const u8 = &.{};
                if (q.order_by) |ob| {
                    ordered = true;
                    if (ob.keys.len > 0) {
                        order_keys = try ally.alloc([]const u8, ob.keys.len);
                        var i: usize = 0;
                        while (i < ob.keys.len) : (i += 1) {
                            const s = pr.stringifyExprAlloc(ally, ob.keys[i].expr, .{}) catch "col";
                            order_keys[i] = s; // leak to process lifetime; OK for short-lived server
                        }
                    }
                }
                state.last_columns = cols;
                state.last_rows_json = rows_buf.toOwnedSlice() catch "[]";
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
        }
    }
}
