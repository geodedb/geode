const std = @import("std");

pub const MessageType = enum { HELLO, RUN_GQL, PULL, BEGIN, COMMIT, ROLLBACK };

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
    var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return error.OutOfMemory;
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
    var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return error.OutOfMemory;
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

pub fn buildExplainLine(ally: std.mem.Allocator, json_payload: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    errdefer buf.deinit(ally);
    const w = buf.writer(ally);
    try w.writeAll("{\"status_class\":\"00000\",\"result\":{\"type\":\"EXPLAIN\",\"json\":");
    try w.writeAll(json_payload);
    try w.writeAll("}}\n");
    return buf.toOwnedSlice(ally);
}

pub fn buildProfileLine(ally: std.mem.Allocator, json_payload: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    errdefer buf.deinit(ally);
    const w = buf.writer(ally);
    try w.writeAll("{\"status_class\":\"00000\",\"result\":{\"type\":\"PROFILE\",\"json\":");
    try w.writeAll(json_payload);
    try w.writeAll("}}\n");
    return buf.toOwnedSlice(ally);
}

pub fn buildErrorLine(ally: std.mem.Allocator, code: []const u8, message: []const u8, anchor: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    errdefer buf.deinit(ally);
    const w = buf.writer(ally);
    try w.writeAll("{\"status_class\":\"02000\",\"result\":{\"type\":\"ERROR\",\"code\":\"");
    try w.writeAll(code);
    try w.writeAll("\",\"message\":\"");
    try w.writeAll(message);
    try w.writeAll("\",\"anchor\":\"");
    try w.writeAll(anchor);
    try w.writeAll("\"}}\n");
    return buf.toOwnedSlice(ally);
}

pub fn buildErrorLineWithFlags(ally: std.mem.Allocator, code: []const u8, message: []const u8, anchor: []const u8, additional: []const []const u8, flags: []const []const u8) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    errdefer buf.deinit(ally);
    const w = buf.writer(ally);
    try w.writeAll("{\"status_class\":\"02000\",\"result\":{\"type\":\"ERROR\",\"code\":\"");
    try w.writeAll(code);
    try w.writeAll("\",\"message\":\"");
    try w.writeAll(message);
    try w.writeAll("\",\"anchor\":\"");
    try w.writeAll(anchor);
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
    } else {
        try w.writeAll("\"");
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
    }
    return error.Invalid;
}
