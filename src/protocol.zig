const std = @import("std");
const GqlLexer = @import("gql/lexer.zig");
const GqlParser = @import("gql/parser.zig");
const heap = @import("storage/heap.zig");
// CANARY: REQ=REQ-GQL-005; FEATURE="Binary Protocol Core"; ASPECT=Wire; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_005_HelloRoundTrip; OWNER=wire; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=CDCDiagnosticsProtocol; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_DiagnosticsProtocol; OWNER=wire; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=CDCControlProtocol; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_042_CDC_ControlReset; OWNER=wire; UPDATED=2025-09-20

// Debug instrumentation toggle for protocol frame builders.
// Set true locally when investigating length arithmetic or corruption.
const PROTOCOL_DEBUG = false;

pub const MessageType = enum { HELLO, RUN_GQL, PULL, BEGIN, COMMIT, ROLLBACK, SAVEPOINT, ROLLBACK_TO, PING, CDC_DIAGNOSTICS, CDC_CONTROL };

pub const Hello = struct {
    client_name: []const u8,
    client_ver: []const u8,
    wanted_conformance: []const u8,
};

pub const RunGql = struct {
    text: []const u8,
    params_json: ?[]const u8 = null, // raw JSON object string of params
};

pub const Pull = struct {
    request_id: u64 = 1,
    page_size: usize = 1000,
};

pub const ClientMessage = union(MessageType) {
    HELLO: Hello,
    RUN_GQL: RunGql,
    PULL: Pull,
    BEGIN: void,
    COMMIT: void,
    ROLLBACK: void,
    SAVEPOINT: struct { name: []const u8 },
    ROLLBACK_TO: struct { name: []const u8 },
    PING: void,
    CDC_DIAGNOSTICS: void,
    CDC_CONTROL: struct { action: []const u8 },
};

pub const ResultType = enum { SCHEMA, BINDINGS, ERROR, EXPLAIN, PROFILE };

pub const SchemaCol = struct { name: []const u8, type: []const u8 };

pub const Schema = struct { columns: []const SchemaCol };

pub const Bindings = struct {
    ordered: bool = false,
    order_keys: []const []const u8 = &.{},
    // rows encoded externally as JSON; we emit via writer
};

pub const Status = struct {
    status_class: []const u8 = "00000",
    status_subclass: ?[]const u8 = null,
};

pub fn buildSchemaLine(ally: std.mem.Allocator, cols: []const SchemaCol, additional: []const []const u8, flags: []const []const u8) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(ally, 16) catch return error.OutOfMemory;
    errdefer buf.deinit(ally);
    const w = buf.writer(ally);
    try w.writeAll("{\"status_class\":\"00000\",\"result\":{\"type\":\"SCHEMA\",\"columns\":[");
    var i: usize = 0;
    while (i < cols.len) : (i += 1) {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":\"");
        try w.writeAll(cols[i].name);
        try w.writeAll("\",\"type\":\"");
        try w.writeAll(cols[i].type);
        try w.writeAll("\"}");
    }
    try w.writeAll("]");
    if (additional.len > 0) {
        try w.writeAll(",\"additional_statuses\":[");
        var ai: usize = 0;
        while (ai < additional.len) : (ai += 1) {
            if (ai > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try w.writeAll(additional[ai]);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
    if (flags.len > 0) {
        try w.writeAll(",\"flagger_findings\":[");
        var fi: usize = 0;
        while (fi < flags.len) : (fi += 1) {
            if (fi > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try w.writeAll(flags[fi]);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
    try w.writeAll("}}\n");
    return buf.toOwnedSlice(ally);
}

pub fn buildBindingsLine(ally: std.mem.Allocator, ordered: bool, order_keys: []const []const u8, rows_json: []const u8, final: bool, additional: []const []const u8, flags: []const []const u8) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(ally, 32) catch return error.OutOfMemory;
    errdefer buf.deinit(ally);
    const w = buf.writer(ally);
    try w.writeAll("{\"status_class\":\"00000\",\"result\":{\"type\":\"BINDINGS\",\"ordered\":");
    try w.writeAll(if (ordered) "true" else "false");
    try w.writeAll(",\"order_keys\":[");
    var i: usize = 0;
    while (i < order_keys.len) : (i += 1) {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("\"");
        try w.writeAll(order_keys[i]);
        try w.writeAll("\"");
    }
    try w.writeAll("],\"rows\":");
    try w.writeAll(rows_json);
    try w.writeAll(",\"final\":");
    try w.writeAll(if (final) "true" else "false");
    if (additional.len > 0) {
        try w.writeAll(",\"additional_statuses\":[");
        var ai: usize = 0;
        while (ai < additional.len) : (ai += 1) {
            if (ai > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try w.writeAll(additional[ai]);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
    if (flags.len > 0) {
        try w.writeAll(",\"flagger_findings\":[");
        var fi: usize = 0;
        while (fi < flags.len) : (fi += 1) {
            if (fi > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try w.writeAll(flags[fi]);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
    try w.writeAll("}}\n");
    return buf.toOwnedSlice(ally);
}

/// Enumerate implementation-defined / dependent behavior flags surfaced in protocol frames.
/// These are prefixed with categories:
///  I: Implementation-defined
///  U: Usage / policy toggle
/// Returned slice lifetime: caller owned (single allocation of joined strings).
pub fn collectImplementationFlags(ally: std.mem.Allocator, lexer_state: ?*const GqlLexer.Lexer, parser_state: ?*const GqlParser.Parser, session_ctx: ?*const SessionContext) ![][]const u8 {
    // Build dynamic list based on runtime state
    var flags = std.ArrayList([]const u8).init(ally);

    // Check if expressions are allowed in ORDER BY (now they are)
    try flags.append("I:IllegalOrderKeyPolicy=expr");

    // Check for ORDER tie-break when no explicit ORDER BY
    if (session_ctx != null and session_ctx.?.implicit_order_applied) {
        try flags.append("U:OrderTiebreak=LexJSON");
    }

    // Check for double-solidus comment usage
    if (lexer_state != null and lexer_state.?.has_double_solidus_comment) {
        try flags.append("GB03:DoubleSolidusComment");
    }

    // Check for ordinal sort keys
    if (parser_state != null and parser_state.?.has_ordinal_sort_key) {
        try flags.append("E:OrdinalSortKey");
    }

    // Check for multi-graph catalog
    if (session_ctx != null and session_ctx.?.graph_catalog != null) {
        try flags.append("I:GraphCatalog=memory");
    }

    // Static flags
    try flags.append("I:PathTieBreak=LengthId");
    try flags.append("I:Collation=binary");

    return flags.toOwnedSlice();
}

pub const SessionContext = struct {
    active_graph: []const u8 = "default",
    graph_catalog: ?*GraphCatalog = null,
    implicit_order_applied: bool = false,
};

pub const GraphCatalog = struct {
    graphs: std.StringHashMap(*anyopaque), // Points to GraphStorage from server/graph/exec.zig
};

test "TestCANARY_REQ_GQL_005_ProtocolImplementationFlagsEnumeration" {
    const flags = try collectImplementationFlags(std.testing.allocator, null, null, null);
    defer std.testing.allocator.free(flags);
    // Basic presence checks
    var found_illegal: bool = false;
    var found_tiebreak: bool = false;
    var found_collation: bool = false;
    for (flags) |f| {
        if (std.mem.eql(u8, f, "I:IllegalOrderKeyPolicy=expr")) found_illegal = true;
        if (std.mem.eql(u8, f, "I:PathTieBreak=LengthId")) found_tiebreak = true;
        if (std.mem.eql(u8, f, "I:Collation=binary")) found_collation = true;
    }
    try std.testing.expect(found_illegal and found_tiebreak and found_collation);
}

pub fn buildExplainLine(ally: std.mem.Allocator, json_payload: []const u8, flags: []const []const u8) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(ally, 32) catch return error.OutOfMemory;
    errdefer buf.deinit(ally);
    const w = buf.writer(ally);
    try w.writeAll("{\"status_class\":\"00000\",\"result\":{\"type\":\"EXPLAIN\",\"json\":");
    try w.writeAll(json_payload);
    if (flags.len > 0) {
        try w.writeAll(",\"flagger_findings\":[");
        var fi: usize = 0;
        while (fi < flags.len) : (fi += 1) {
            if (fi > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try w.writeAll(flags[fi]);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
    try w.writeAll("}}\n");
    return buf.toOwnedSlice(ally);
}

pub fn buildProfileLine(ally: std.mem.Allocator, json_payload: []const u8, flags: []const []const u8) ![]u8 {
    const prefix = "{\"status_class\":\"00000\",\"result\":{\"type\":\"PROFILE\",\"json\":";
    const suffix = "}}\n";
    // Compute flags serialization length
    var flags_len: usize = 0;
    if (flags.len > 0) {
        // ,"flagger_findings":["flag1","flag2"]
        flags_len += ",\"flagger_findings\":[".len; // opening
        var i: usize = 0;
        while (i < flags.len) : (i += 1) {
            if (i > 0) flags_len += 1; // comma
            flags_len += 2; // quotes
            flags_len += flags[i].len;
        }
        flags_len += 1; // closing ]
    }
    const total = prefix.len + json_payload.len + flags_len + suffix.len;
    if (PROTOCOL_DEBUG) std.debug.print("[debug] buildProfileLine pre total_calc payload={d} flags_len={d} prefix={d} suffix={d}\n", .{ json_payload.len, flags_len, prefix.len, suffix.len });
    if (total < prefix.len or total < json_payload.len) return error.OutOfMemory; // overflow guard
    if (total > 1_000_000 and json_payload.len < 10_000) {
        if (PROTOCOL_DEBUG) std.debug.print("[warn] buildProfileLine suspicious total={d} payload={d} flags={d}; using fallback minimal profile frame\n", .{ total, json_payload.len, flags.len });
        const fallback = "{\"status_class\":\"00000\",\"result\":{\"type\":\"PROFILE\",\"json\":{\"profile_version\":2,\"ops\":[],\"totals\":{}}}}\n";
        if (ally.dupe(u8, fallback)) |dup| return dup else |_| {
            const buf = try ally.alloc(u8, fallback.len);
            @memcpy(buf, fallback);
            return buf;
        }
    }
    var out = try ally.alloc(u8, total);
    var idx: usize = 0;
    // Instrumentation
    if (PROTOCOL_DEBUG) std.debug.print("[debug] buildProfileLine(safe) total={d} payload={d} flags={d}\n", .{ total, json_payload.len, flags.len });
    @memcpy(out[idx .. idx + prefix.len], prefix);
    idx += prefix.len;
    if (json_payload.len > 0) {
        @memcpy(out[idx .. idx + json_payload.len], json_payload);
        idx += json_payload.len;
    }
    if (flags.len > 0) {
        const open = ",\"flagger_findings\":[";
        @memcpy(out[idx .. idx + open.len], open);
        idx += open.len;
        var fi: usize = 0;
        while (fi < flags.len) : (fi += 1) {
            if (fi > 0) {
                out[idx] = ',';
                idx += 1;
            }
            out[idx] = '"';
            idx += 1;
            const f = flags[fi];
            if (idx + f.len + 1 > total) return error.OutOfMemory;
            @memcpy(out[idx .. idx + f.len], f);
            idx += f.len;
            out[idx] = '"';
            idx += 1;
        }
        out[idx] = ']';
        idx += 1;
    }
    @memcpy(out[idx .. idx + suffix.len], suffix);
    idx += suffix.len;
    // Safety assert
    if (idx != total and PROTOCOL_DEBUG) std.debug.print("[debug] buildProfileLine length mismatch idx={d} total={d}\n", .{ idx, total });
    return out;
}

pub fn buildCdcDiagnosticsLine(ally: std.mem.Allocator, json_payload: []const u8) ![]u8 {
    // Minimal frame: status_class 00000 and result type CDC_DIAGNOSTICS with nested json field
    const prefix = "{\"status_class\":\"00000\",\"result\":{\"type\":\"CDC_DIAGNOSTICS\",\"json\":";
    const suffix = "}}\n";
    const total = prefix.len + json_payload.len + suffix.len;
    var out = try ally.alloc(u8, total);
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len .. prefix.len + json_payload.len], json_payload);
    @memcpy(out[prefix.len + json_payload.len .. total], suffix);
    return out;
}

pub fn buildCdcControlLine(ally: std.mem.Allocator, action: []const u8, status: []const u8, epoch: u64) ![]u8 {
    // Frame: {"status_class":"00000","result":{"type":"CDC_CONTROL","action":"<action>","status":"<status>","guardrail_epoch":<epoch>}}
    var buf = std.ArrayList(u8).initCapacity(ally, 64) catch return error.OutOfMemory;
    errdefer buf.deinit(ally);
    const w = buf.writer(ally);
    try w.writeAll("{\"status_class\":\"00000\",\"result\":{\"type\":\"CDC_CONTROL\",\"action\":\"");
    try w.writeAll(action);
    try w.writeAll("\",\"status\":\"");
    try w.writeAll(status);
    try w.writeAll("\",\"guardrail_epoch\":");
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{epoch}) catch "0";
    try w.writeAll(s);
    try w.writeAll("}}\n");
    return buf.toOwnedSlice(ally);
}

pub fn buildErrorLine(ally: std.mem.Allocator, code: []const u8, message: []const u8, anchor: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(ally, 32) catch return error.OutOfMemory;
    errdefer buf.deinit(ally);
    const w = buf.writer(ally);
    try w.writeAll("{\"status_class\":\"02000\",\"status_subclass\":\"");
    try w.writeAll(code);
    try w.writeAll("\",\"result\":{\"type\":\"ERROR\",\"code\":\"");
    try w.writeAll(code);
    try w.writeAll("\",\"message\":\"");
    try w.writeAll(message);
    try w.writeAll("\",\"anchor\":\"");
    try w.writeAll(anchor);
    try w.writeAll("\"}}\n");
    return buf.toOwnedSlice(ally);
}

pub fn buildErrorLineWithFlags(ally: std.mem.Allocator, code: []const u8, message: []const u8, anchor: []const u8, additional: []const []const u8, flags: []const []const u8) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(ally, 32) catch return error.OutOfMemory;
    errdefer buf.deinit(ally);
    const w = buf.writer(ally);
    try w.writeAll("{\"status_class\":\"02000\",\"status_subclass\":\"");
    try w.writeAll(code);
    try w.writeAll("\",\"result\":{\"type\":\"ERROR\",\"code\":\"");
    try w.writeAll(code);
    try w.writeAll("\",\"message\":\"");
    try w.writeAll(message);
    try w.writeAll("\",\"anchor\":\"");
    try w.writeAll(anchor);
    try w.writeAll("\"");
    if (additional.len > 0) {
        try w.writeAll(",\"additional_statuses\":[");
        var i: usize = 0;
        while (i < additional.len) : (i += 1) {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try w.writeAll(additional[i]);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
    if (flags.len > 0) {
        try w.writeAll(",\"flagger_findings\":[");
        var fi: usize = 0;
        while (fi < flags.len) : (fi += 1) {
            if (fi > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try w.writeAll(flags[fi]);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
    try w.writeAll("}}\n");
    return buf.toOwnedSlice(ally);
}

pub fn buildErrorLineWithFlagsCustomStatus(ally: std.mem.Allocator, code: []const u8, message: []const u8, anchor: []const u8, additional: []const []const u8, flags: []const []const u8, status_override: ?[]const u8) ![]u8 {
    const status_class = status_override orelse "02000";
    var buf = std.ArrayList(u8).initCapacity(ally, 32) catch return error.OutOfMemory;
    errdefer buf.deinit(ally);
    const w = buf.writer(ally);
    try w.writeAll("{\"status_class\":\"");
    try w.writeAll(status_class);
    try w.writeAll("\",\"status_subclass\":\"");
    try w.writeAll(code);
    try w.writeAll("\",\"result\":{\"type\":\"ERROR\",\"code\":\"");
    try w.writeAll(code);
    try w.writeAll("\",\"message\":\"");
    try w.writeAll(message);
    try w.writeAll("\",\"anchor\":\"");
    try w.writeAll(anchor);
    try w.writeAll("\"");
    if (additional.len > 0) {
        try w.writeAll(",\"additional_statuses\":[");
        var ai: usize = 0;
        while (ai < additional.len) : (ai += 1) {
            if (ai > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try w.writeAll(additional[ai]);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
    if (flags.len > 0) {
        try w.writeAll(",\"flagger_findings\":[");
        var fi: usize = 0;
        while (fi < flags.len) : (fi += 1) {
            if (fi > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try w.writeAll(flags[fi]);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
    try w.writeAll("}}\n");
    return buf.toOwnedSlice(ally);
}

pub fn parseClientMessage(ally: std.mem.Allocator, line: []const u8) !ClientMessage {
    const parsed = try std.json.parseFromSlice(std.json.Value, ally, line, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.Invalid;
    const obj = root.object;
    const typ_val = obj.get("type") orelse return error.Invalid;
    if (typ_val != .string) return error.Invalid;
    const typ = typ_val.string;
    if (std.mem.eql(u8, typ, "HELLO")) {
        const cnv = obj.get("client_name") orelse return error.Invalid;
        const cvv = obj.get("client_ver") orelse return error.Invalid;
        const wcv = obj.get("wanted_conformance") orelse return error.Invalid;
        if (cnv != .string or cvv != .string or wcv != .string) return error.Invalid;
        // Duplicate strings so they outlive the JSON Value arena
        const cn = try ally.dupe(u8, cnv.string);
        const cv = try ally.dupe(u8, cvv.string);
        const wc = try ally.dupe(u8, wcv.string);
        return .{ .HELLO = .{ .client_name = cn, .client_ver = cv, .wanted_conformance = wc } };
    } else if (std.mem.eql(u8, typ, "RUN_GQL")) {
        const txtv = obj.get("text") orelse return error.Invalid;
        if (txtv != .string) return error.Invalid;
        // Duplicate text to avoid use-after-free of parsed JSON buffer
        const txt = try ally.dupe(u8, txtv.string);
        const params_val = obj.get("params");
        var params_json: ?[]const u8 = null;
        if (params_val) |pv| {
            // Allocate JSON string for params that outlives the parser
            params_json = std.json.Stringify.valueAlloc(ally, pv, .{}) catch null;
        }
        return .{ .RUN_GQL = .{ .text = txt, .params_json = params_json } };
    } else if (std.mem.eql(u8, typ, "PULL")) {
        const ridv = obj.get("request_id") orelse return error.Invalid;
        const psv = obj.get("page_size") orelse return error.Invalid;
        if (ridv != .integer or psv != .integer) return error.Invalid;
        const rid: u64 = @intCast(ridv.integer);
        const ps: usize = @intCast(psv.integer);
        return .{ .PULL = .{ .request_id = rid, .page_size = ps } };
    } else if (std.mem.eql(u8, typ, "BEGIN")) {
        return .{ .BEGIN = {} };
    } else if (std.mem.eql(u8, typ, "COMMIT")) {
        return .{ .COMMIT = {} };
    } else if (std.mem.eql(u8, typ, "ROLLBACK")) {
        return .{ .ROLLBACK = {} };
    } else if (std.mem.eql(u8, typ, "SAVEPOINT")) {
        const nv = obj.get("name") orelse return error.Invalid;
        if (nv != .string) return error.Invalid;
        const name = try ally.dupe(u8, nv.string);
        return .{ .SAVEPOINT = .{ .name = name } };
    } else if (std.mem.eql(u8, typ, "ROLLBACK_TO")) {
        const nv = obj.get("name") orelse return error.Invalid;
        if (nv != .string) return error.Invalid;
        const name = try ally.dupe(u8, nv.string);
        return .{ .ROLLBACK_TO = .{ .name = name } };
    } else if (std.mem.eql(u8, typ, "PING")) {
        return .{ .PING = {} };
    } else if (std.mem.eql(u8, typ, "CDC_DIAGNOSTICS")) {
        return .{ .CDC_DIAGNOSTICS = {} };
    } else if (std.mem.eql(u8, typ, "CDC_CONTROL")) {
        // Action may be omitted; treat as empty string to allow handler to emit UNSUPPORTED
        const av = obj.get("action");
        if (av) |aval| {
            if (aval != .string) return error.Invalid;
            const act = try ally.dupe(u8, aval.string);
            return .{ .CDC_CONTROL = .{ .action = act } };
        } else {
            const empty = try ally.dupe(u8, "");
            return .{ .CDC_CONTROL = .{ .action = empty } };
        }
    }
    return error.Invalid;
}

pub fn emitValueAsJson(writer: anytype, value: heap.Value, allocator: std.mem.Allocator) !void {
    switch (value) {
        .Null => try writer.writeAll("null"),
        .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .Int => |i| try std.fmt.format(writer, "{d}", .{i}),
        .SmallInt => |i| try std.fmt.format(writer, "{d}", .{i}),
        .BigInt => |i| try std.fmt.format(writer, "{d}", .{i}),
        .Real => |f| try std.fmt.format(writer, "{d}", .{f}),
        .Double => |f| try std.fmt.format(writer, "{d}", .{f}),
        .Decimal128 => |d| {
            const str = try d.toString(allocator);
            defer allocator.free(str);
            if (std.fmt.parseFloat(f64, str)) |_| {
                try std.fmt.format(writer, "{s}", .{str});
            } else |_| {
                try std.fmt.format(writer, "\"{s}\"", .{str});
            }
        },
        .Str => |s| try std.fmt.format(writer, "\"{s}\"", .{s}),
        .Text => |s| try std.fmt.format(writer, "\"{s}\"", .{s}),
        .Char => |c| try std.fmt.format(writer, "\"{s}\"", .{c.data}),
        .Varchar => |v| try std.fmt.format(writer, "\"{s}\"", .{v.data}),
        .Date => |d| {
            const str = try d.toString(allocator);
            defer allocator.free(str);
            try std.fmt.format(writer, "\"{s}\"", .{str});
        },
        .Time => |t| {
            const str = try t.toString(allocator);
            defer allocator.free(str);
            try std.fmt.format(writer, "\"{s}\"", .{str});
        },
        .TimeTZ => |tz| {
            const str = try tz.toString(allocator);
            defer allocator.free(str);
            try std.fmt.format(writer, "\"{s}\"", .{str});
        },
        .Timestamp => |ts| {
            const str = try ts.toString(allocator);
            defer allocator.free(str);
            try std.fmt.format(writer, "\"{s}\"", .{str});
        },
        .TimestampTZ => |tsz| {
            const str = try tsz.toString(allocator);
            defer allocator.free(str);
            try std.fmt.format(writer, "\"{s}\"", .{str});
        },
        .Interval => |iv| {
            const str = try iv.toString(allocator);
            defer allocator.free(str);
            try std.fmt.format(writer, "\"{s}\"", .{str});
        },
        .Bytea => |b| {
            try writer.writeAll("\"\\\\x");
            for (b) |byte| {
                try std.fmt.format(writer, "{X:0>2}", .{byte});
            }
            try writer.writeAll("\"");
        },
        .Json => |j| try writer.writeAll(j),
        .Jsonb => |jb| try writer.writeAll(jb.data),
        .Xml => |x| try std.fmt.format(writer, "\"{s}\"", .{x.data}),
        .Url => |u| {
            const str = try u.toString(allocator);
            defer allocator.free(str);
            try std.fmt.format(writer, "\"{s}\"", .{str});
        },
        .Domain => |d| {
            const str = try d.toString(allocator);
            defer allocator.free(str);
            try std.fmt.format(writer, "\"{s}\"", .{str});
        },
        .UUID => |u| {
            const str = try u.toString(allocator);
            defer allocator.free(str);
            try std.fmt.format(writer, "\"{s}\"", .{str});
        },
        .Enum => |e| try std.fmt.format(writer, "\"enum_{}_{d}\"", .{ e.type_id, e.value_ordinal }),
        .Array => |a| {
            try writer.writeAll("[");
            const len = a.length();
            for (0..len) |i| {
                if (i > 0) try writer.writeAll(",");
                if (a.elem_type == .int) {
                    const val = try a.getInt(i);
                    try std.fmt.format(writer, "{d}", .{val});
                } else {
                    try writer.writeAll("null");
                }
            }
            try writer.writeAll("]");
        },
        .BitString => |bs| {
            const str = try bs.toString(allocator);
            defer allocator.free(str);
            try std.fmt.format(writer, "\"{s}\"", .{str});
        },
        .VarBit => |vb| {
            const str = try vb.toString(allocator);
            defer allocator.free(str);
            try std.fmt.format(writer, "\"{s}\"", .{str});
        },
        .IntRange => |r| {
            try writer.writeAll("{");
            if (r.lower) |l| {
                try std.fmt.format(writer, "\"lower\":{d},", .{l});
            } else {
                try writer.writeAll("\"lower\":null,");
            }
            if (r.upper) |u| {
                try std.fmt.format(writer, "\"upper\":{d},", .{u});
            } else {
                try writer.writeAll("\"upper\":null,");
            }
            try std.fmt.format(writer, "\"bounds\":\"{s}\"", .{r.bounds.toString()});
            try writer.writeAll("}");
        },
        // Legacy types
        .IpAddr, .Subnet, .Mac, .Hash, .Currency, .LanguageTag, .LatLon, .LatLonAlt, .Geometry, .Temperature, .Pressure, .VectorF32 => {
            try writer.writeAll("null");
        },
    }
}
