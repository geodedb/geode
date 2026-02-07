const std = @import("std");
const schema = @import("schema");
const spice_wrapper = @import("parallel/spice");
// Use relative imports since this file is part of the geode module
const value_types = @import("../value_types.zig");
const execution = @import("../execution.zig");
const graph_store = @import("../graph_store.zig");
const type_helpers = @import("../eval/type_helpers.zig");
const eval_extended = @import("../eval_extended.zig");

pub const ParamBindings = struct {
    names: []const []const u8,
    values: []const value_types.Value,
};

pub const ErrorInfo = struct {
    code: []const u8,
    message: []const u8,
};

pub fn parseParams(allocator: std.mem.Allocator, params: []const schema.Param) !ParamBindings {
    if (params.len == 0) {
        return .{ .names = &.{}, .values = &.{} };
    }

    var names = try allocator.alloc([]const u8, params.len);
    errdefer allocator.free(names);
    var values = try allocator.alloc(value_types.Value, params.len);
    errdefer allocator.free(values);

    for (params, 0..) |param, i| {
        names[i] = try allocator.dupe(u8, param.name);
        if (param.value) |val| {
            values[i] = try protoValueToValue(allocator, val, 0);
        } else {
            values[i] = .Null;
        }
    }

    return .{ .names = names, .values = values };
}

pub fn freeParamBindings(allocator: std.mem.Allocator, bindings: ParamBindings) void {
    for (bindings.names) |name| allocator.free(name);
    for (bindings.values) |val| freeParamValue(allocator, val);
    allocator.free(bindings.names);
    allocator.free(bindings.values);
}

pub fn protoValueToValue(allocator: std.mem.Allocator, value: schema.Value, depth: usize) !value_types.Value {
    if (depth > 64) return error.ParamsTooDeep;
    const kind = value.kind orelse return .Null;
    return switch (kind) {
        .null_val => .Null,
        .bool_val => |b| .{ .Bool = b },
        .int_val => |iv| switch (iv.kind) {
            .INT => .{ .Int = iv.value },
            .SMALLINT => .{ .SmallInt = @intCast(iv.value) },
            .BIGINT => .{ .BigInt = iv.value },
            else => .{ .Int = iv.value },
        },
        .double_val => |dv| switch (dv.kind) {
            .REAL => .{ .Real = @floatCast(dv.value) },
            .DOUBLE => .{ .Double = dv.value },
            else => .{ .Double = dv.value },
        },
        .string_val => |sv| switch (sv.kind) {
            .CHAR => .{ .Char = .{ .data = try allocator.dupe(u8, sv.value), .n = @intCast(sv.value.len) } },
            .VARCHAR => .{ .Varchar = .{ .data = try allocator.dupe(u8, sv.value), .n = @intCast(sv.value.len) } },
            .TEXT => .{ .Text = try allocator.dupe(u8, sv.value) },
            else => .{ .Str = try allocator.dupe(u8, sv.value) },
        },
        .decimal_val => |dec| blk: {
            const coeff = std.fmt.parseInt(i128, dec.coeff, 10) catch return error.InvalidParams;
            const orig_repr = if (dec.orig_repr.len > 0)
                try allocator.dupe(u8, dec.orig_repr)
            else
                null;
            break :blk .{ .Decimal = .{
                .coeff = coeff,
                .scale = @intCast(dec.scale),
                .orig_scale = @intCast(dec.orig_scale),
                .orig_repr = orig_repr,
            } };
        },
        .bytes_val => |bv| .{ .Bytea = try allocator.dupe(u8, bv.value) },
        .list_val => |lv| blk: {
            const list = try allocator.alloc(value_types.Value, lv.values.items.len);
            for (lv.values.items, 0..) |item, idx| {
                list[idx] = try protoValueToValue(allocator, item, depth + 1);
            }
            break :blk .{ .List = list };
        },
        .map_val => |mv| blk: {
            var map = std.StringHashMap(value_types.Value).init(allocator);
            errdefer map.deinit();
            for (mv.entries.items) |entry| {
                const key = try allocator.dupe(u8, entry.key);
                const val = if (entry.value) |v|
                    try protoValueToValue(allocator, v, depth + 1)
                else
                    value_types.Value.Null;
                try map.put(key, val);
            }
            break :blk .{ .Map = map };
        },
        .ext_val => return error.UnsupportedParamType,
        .node_val, .edge_val, .path_val => return error.UnsupportedParamType,
    };
}

fn freeParamValue(allocator: std.mem.Allocator, value: value_types.Value) void {
    switch (value) {
        .Str => |s| allocator.free(s),
        .Text => |s| allocator.free(s),
        .Char => |c| allocator.free(c.data),
        .Varchar => |v| allocator.free(v.data),
        .Bytea => |b| allocator.free(b),
        .Json => |j| allocator.free(j),
        .Decimal => |d| if (d.orig_repr) |repr| allocator.free(repr),
        .List => |list| {
            for (list) |item| freeParamValue(allocator, item);
            allocator.free(list);
        },
        .Map => |map_const| {
            var map = map_const;
            var iter = map.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeParamValue(allocator, entry.value_ptr.*);
            }
            map.deinit();
        },
        else => {},
    }
}

pub fn mapError(err: anyerror) ErrorInfo {
    return switch (err) {
        error.GroupingError => .{ .code = "42000", .message = "grouping error: non-aggregated expression not in GROUP BY" },
        error.UnorderedPagination => .{ .code = "US001", .message = "OFFSET requires ORDER BY clause" },
        error.TransactionAlreadyActive => .{ .code = "25001", .message = "Transaction already active" },
        error.NoActiveTransaction => .{ .code = "25000", .message = "No active transaction" },
        error.UnionColumnCountMismatch => .{ .code = "42601", .message = "UNION column count mismatch" },
        error.DuplicateGraph => .{ .code = "42P07", .message = "Duplicate graph name" },
        error.GraphNotFound => .{ .code = "3F000", .message = "Graph does not exist" },
        error.DuplicateSchema => .{ .code = "42P07", .message = "Duplicate schema name" },
        error.SchemaNotFound => .{ .code = "3F000", .message = "Schema does not exist" },
        error.DuplicateIndex => .{ .code = "42P07", .message = "Duplicate index name" },
        error.IncompatibleIndexDataType => .{ .code = "42804", .message = "Incompatible index data type" },
        error.InvalidTypeConversion => .{ .code = "22003", .message = "Invalid type conversion" },
        error.StringDataRightTruncation => .{ .code = "22001", .message = "String data right truncation" },
        error.InvalidKeyProvider => .{ .code = "42704", .message = "Invalid TDE key provider" },
        error.InvalidGuardrailConfiguration => .{ .code = "42704", .message = "Invalid CDC guardrail configuration" },
        error.UnknownProcedure => .{ .code = "42883", .message = "Unknown procedure" },
        error.Unauthenticated => .{ .code = "28000", .message = "Authentication required" },
        error.Unauthorized => .{ .code = "42501", .message = "Permission denied" },
        error.SearchNotPermitted => .{ .code = "42501", .message = "Access denied: READ_PLAINTEXT privilege required for encrypted searchable field" },
        error.InvalidIpAddress => .{ .code = "22P02", .message = "Invalid IP address format" },
        error.InvalidMac, error.InvalidMacFormat, error.InvalidMacTag => .{ .code = "22P02", .message = "Invalid MAC address format" },
        error.DivisionByZero => .{ .code = "22012", .message = "Division by zero" },
        error.NotImplemented, error.Unsupported => .{ .code = "0A000", .message = @errorName(err) },
        else => .{ .code = "58000", .message = @errorName(err) },
    };
}

pub fn buildStatus(allocator: std.mem.Allocator, status_class: []const u8, flagger_findings: []const []const u8) !schema.Status {
    return buildStatusFull(allocator, status_class, &.{}, flagger_findings);
}

pub fn buildStatusFull(
    allocator: std.mem.Allocator,
    status_class: []const u8,
    additional_statuses: []const []const u8,
    flagger_findings: []const []const u8,
) !schema.Status {
    var flags = std.ArrayList([]const u8).initCapacity(allocator, flagger_findings.len) catch return error.OutOfMemory;
    for (flagger_findings) |flag| {
        try flags.append(allocator, try allocator.dupe(u8, flag));
    }

    var additional = std.ArrayList([]const u8).initCapacity(allocator, additional_statuses.len) catch return error.OutOfMemory;
    for (additional_statuses) |status| {
        try additional.append(allocator, try allocator.dupe(u8, status));
    }

    return .{
        .status_class = try allocator.dupe(u8, status_class),
        .status_subclass = "",
        .additional_statuses = additional,
        .flagger_findings = flags,
    };
}

pub fn buildSchemaDefinition(allocator: std.mem.Allocator, result: *const execution.ExecutionResult) !schema.SchemaDefinition {
    var cols = std.ArrayList(schema.ColumnDefinition).initCapacity(allocator, result.columns.len) catch return error.OutOfMemory;
    for (result.columns, 0..) |name, idx| {
        const type_name = inferColumnType(result.rows, idx);
        const col = schema.ColumnDefinition{
            .name = try allocator.dupe(u8, name),
            .type = try allocator.dupe(u8, type_name),
        };
        try cols.append(allocator, col);
    }
    return .{ .columns = cols };
}

pub fn buildDataPage(
    allocator: std.mem.Allocator,
    result: *const execution.ExecutionResult,
    start: usize,
    page_size: usize,
    ordered: bool,
    order_keys: []const []const u8,
) !schema.DataPage {
    const page_len = if (page_size == 0) 1000 else page_size;
    if (start >= result.rows.len) {
        return schema.DataPage{
            .rows = std.ArrayList(schema.Row){},
            .final = true,
            .ordered = ordered,
            .order_keys = try dupOrderKeys(allocator, order_keys),
        };
    }

    const end = @min(start + page_len, result.rows.len);
    const row_count = end - start;

    var rows = std.ArrayList(schema.Row).initCapacity(allocator, row_count) catch return error.OutOfMemory;
    try rows.resize(allocator, row_count);

    if (spice_wrapper.shouldUseParallelism(row_count, spice_wrapper.Thresholds.map)) {
        var pool = spice_wrapper.SpicePool.init(allocator, null);
        pool.start();
        defer pool.deinit();

        var ts_alloc = std.heap.ThreadSafeAllocator{ .child_allocator = allocator };
        const safe_alloc = ts_alloc.allocator();

        const RowInput = struct {
            row: []const value_types.Value,
            allocator: std.mem.Allocator,
        };

        const RowResult = struct {
            row: schema.Row,
            err: ?anyerror,
        };

        const items = try allocator.alloc(RowInput, row_count);
        defer allocator.free(items);
        for (start..end, 0..) |row_idx, i| {
            items[i] = .{ .row = result.rows[row_idx], .allocator = safe_alloc };
        }

        const mapFn = struct {
            fn map(_: *spice_wrapper.Task, input: RowInput) RowResult {
                var values = std.ArrayList(schema.Value).initCapacity(input.allocator, input.row.len) catch {
                    return .{ .row = .{ .values = std.ArrayList(schema.Value){} }, .err = error.OutOfMemory };
                };
                for (input.row) |val| {
                    const proto_val = valueToProto(input.allocator, val) catch |err| {
                        values.deinit(input.allocator);
                        return .{ .row = .{ .values = std.ArrayList(schema.Value){} }, .err = err };
                    };
                    values.append(input.allocator, proto_val) catch |err| {
                        values.deinit(input.allocator);
                        return .{ .row = .{ .values = std.ArrayList(schema.Value){} }, .err = err };
                    };
                }
                return .{ .row = .{ .values = values }, .err = null };
            }
        }.map;

        const results = try spice_wrapper.parallelMap(RowInput, RowResult, &pool, items, mapFn, spice_wrapper.Thresholds.map);
        defer allocator.free(results);

        for (results, 0..) |res, i| {
            if (res.err) |err| {
                for (results[0..i]) |prev| {
                    var vals = prev.row.values;
                    vals.deinit(allocator);
                }
                return err;
            }
            rows.items[i] = res.row;
        }
    } else {
        for (start..end, 0..) |row_idx, i| {
            var values = std.ArrayList(schema.Value).initCapacity(allocator, result.rows[row_idx].len) catch return error.OutOfMemory;
            for (result.rows[row_idx]) |val| {
                const proto_val = try valueToProto(allocator, val);
                try values.append(allocator, proto_val);
            }
            rows.items[i] = .{ .values = values };
        }
    }

    return schema.DataPage{
        .rows = rows,
        .final = end == result.rows.len,
        .ordered = ordered,
        .order_keys = try dupOrderKeys(allocator, order_keys),
    };
}

fn dupOrderKeys(allocator: std.mem.Allocator, keys: []const []const u8) !std.ArrayList([]const u8) {
    var list = std.ArrayList([]const u8).initCapacity(allocator, keys.len) catch return error.OutOfMemory;
    for (keys) |key| {
        try list.append(allocator, try allocator.dupe(u8, key));
    }
    return list;
}

fn inferColumnType(rows: [][]value_types.Value, col_idx: usize) []const u8 {
    for (rows) |row| {
        if (col_idx >= row.len) continue;
        const val = row[col_idx];
        if (val == .Null) continue;
        return type_helpers.getTypeName(val);
    }
    return "NULL";
}

pub fn valueToProto(allocator: std.mem.Allocator, value: value_types.Value) !schema.Value {
    return switch (value) {
        .Null => .{ .kind = .{ .null_val = .{} } },
        .Bool => |b| .{ .kind = .{ .bool_val = b } },
        .Int => |i| .{ .kind = .{ .int_val = .{ .value = i, .kind = .INT } } },
        .SmallInt => |i| .{ .kind = .{ .int_val = .{ .value = i, .kind = .SMALLINT } } },
        .BigInt => |i| .{ .kind = .{ .int_val = .{ .value = i, .kind = .BIGINT } } },
        .Real => |f| .{ .kind = .{ .double_val = .{ .value = @floatCast(f), .kind = .REAL } } },
        .Double => |f| .{ .kind = .{ .double_val = .{ .value = f, .kind = .DOUBLE } } },
        .Str => |s| .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, s), .kind = .STRING } } },
        .Char => |c| .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, c.data), .kind = .CHAR } } },
        .Varchar => |v| .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, v.data), .kind = .VARCHAR } } },
        .Text => |t| .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, t), .kind = .TEXT } } },
        .Decimal => |d| blk: {
            const coeff_str = try std.fmt.allocPrint(allocator, "{d}", .{d.coeff});
            const orig_repr = if (d.orig_repr) |repr| try allocator.dupe(u8, repr) else if (d.scale > 0) try reconstructDecimalRepr(allocator, d.coeff, d.scale) else coeff_str;
            break :blk .{ .kind = .{ .decimal_val = .{
                .coeff = coeff_str,
                .scale = d.scale,
                .orig_scale = d.orig_scale,
                .orig_repr = orig_repr,
            } } };
        },
        .Bytea => |b| .{ .kind = .{ .bytes_val = .{ .value = try allocator.dupe(u8, b), .kind = .BYTEA } } },
        .List => |list| blk: {
            var values = std.ArrayList(schema.Value).initCapacity(allocator, list.len) catch return error.OutOfMemory;
            for (list) |item| {
                try values.append(allocator, try valueToProto(allocator, item));
            }
            break :blk .{ .kind = .{ .list_val = .{ .values = values } } };
        },
        .Map => |map| blk: {
            var entries = std.ArrayList(schema.MapEntry).initCapacity(allocator, map.count()) catch return error.OutOfMemory;
            var it = map.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try valueToProto(allocator, entry.value_ptr.*);
                try entries.append(allocator, .{ .key = key, .value = val });
            }
            break :blk .{ .kind = .{ .map_val = .{ .entries = entries } } };
        },
        .Node => |node| .{ .kind = .{ .node_val = try nodeToProto(allocator, node.*) } },
        .Edge => |edge| .{ .kind = .{ .edge_val = try edgeToProto(allocator, edge.*) } },
        .Path => |path| blk: {
            var nodes = std.ArrayList(schema.NodeValue).initCapacity(allocator, path.nodes.len) catch return error.OutOfMemory;
            for (path.nodes) |n| {
                try nodes.append(allocator, try nodeToProto(allocator, n.*));
            }
            var edges = std.ArrayList(schema.EdgeValue).initCapacity(allocator, path.edges.len) catch return error.OutOfMemory;
            for (path.edges) |e| {
                try edges.append(allocator, try edgeToProto(allocator, e.*));
            }
            break :blk .{ .kind = .{ .path_val = .{ .nodes = nodes, .edges = edges } } };
        },
        .ExtValue => |ext| .{ .kind = .{ .ext_val = try extValueToProto(allocator, ext) } },
        .Date => |d| .{ .kind = .{ .ext_val = try textExt(allocator, "DATE", try d.toString(allocator)) } },
        .Time => |t| .{ .kind = .{ .ext_val = try textExt(allocator, "TIME", try t.toString(allocator)) } },
        .TimeTZ => |t| .{ .kind = .{ .ext_val = try textExt(allocator, "TIMETZ", try t.toString(allocator)) } },
        .Timestamp => |t| .{ .kind = .{ .ext_val = try textExt(allocator, "TIMESTAMP", try t.toString(allocator)) } },
        .TimestampTZ => |t| .{ .kind = .{ .ext_val = try textExt(allocator, "TIMESTAMPTZ", try t.toString(allocator)) } },
        .Interval => |i| .{ .kind = .{ .ext_val = try textExt(allocator, "INTERVAL", try i.toString(allocator)) } },
        .Json => |j| .{ .kind = .{ .ext_val = try textExt(allocator, "JSON", try allocator.dupe(u8, j)) } },
        .Jsonb => |jb| .{ .kind = .{ .ext_val = try textExt(allocator, "JSONB", try allocator.dupe(u8, jb.data)) } },
        .Xml => |x| .{ .kind = .{ .ext_val = try textExt(allocator, "XML", try allocator.dupe(u8, x.data)) } },
        .Url => |u| .{ .kind = .{ .ext_val = try textExt(allocator, "URL", try u.toString(allocator)) } },
        .Domain => |d| .{ .kind = .{ .ext_val = try textExt(allocator, "DOMAIN", try d.toString(allocator)) } },
        .UUID => |u| .{ .kind = .{ .ext_val = try textExt(allocator, "UUID", try u.toString(allocator)) } },
        .BitString => |b| .{ .kind = .{ .ext_val = try textExt(allocator, "BIT", try b.toString(allocator)) } },
        .VarBit => |b| .{ .kind = .{ .ext_val = try textExt(allocator, "VARBIT", try b.toString(allocator)) } },
        .IntRange => |r| .{ .kind = .{ .ext_val = try textExt(allocator, "INT4RANGE", try r.toString(allocator)) } },
        .Enum => |e| .{ .kind = .{ .ext_val = try textExt(allocator, "ENUM", try std.fmt.allocPrint(allocator, "{d}:{d}", .{ e.type_id, e.value_ordinal })) } },
    };
}

fn nodeToProto(allocator: std.mem.Allocator, node: graph_store.Node) !schema.NodeValue {
    var labels = std.ArrayList([]const u8).initCapacity(allocator, node.labels.len) catch return error.OutOfMemory;
    for (node.labels) |label| {
        try labels.append(allocator, try allocator.dupe(u8, label));
    }
    var props = std.ArrayList(schema.MapEntry).initCapacity(allocator, node.properties.count()) catch return error.OutOfMemory;
    var it = node.properties.iterator();
    while (it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        const val = try propertyValueToProto(allocator, entry.value_ptr.*);
        try props.append(allocator, .{ .key = key, .value = val });
    }
    return .{
        .id = node.id,
        .labels = labels,
        .properties = props,
    };
}

fn edgeToProto(allocator: std.mem.Allocator, edge: graph_store.Edge) !schema.EdgeValue {
    var props = std.ArrayList(schema.MapEntry).initCapacity(allocator, edge.properties.count()) catch return error.OutOfMemory;
    var it = edge.properties.iterator();
    while (it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        const val = try propertyValueToProto(allocator, entry.value_ptr.*);
        try props.append(allocator, .{ .key = key, .value = val });
    }
    return .{
        .id = edge.id,
        .from_id = edge.from_id,
        .to_id = edge.to_id,
        .label = try allocator.dupe(u8, edge.label),
        .properties = props,
    };
}

fn propertyValueToProto(allocator: std.mem.Allocator, value: graph_store.PropertyValue) !schema.Value {
    return switch (value) {
        .Null => .{ .kind = .{ .null_val = .{} } },
        .Bool => |b| .{ .kind = .{ .bool_val = b } },
        .Int => |i| .{ .kind = .{ .int_val = .{ .value = i, .kind = .INT } } },
        .Float => |f| .{ .kind = .{ .double_val = .{ .value = f, .kind = .DOUBLE } } },
        .String => |s| .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, s), .kind = .STRING } } },
        .Decimal => |d| blk: {
            const coeff_str = try std.fmt.allocPrint(allocator, "{d}", .{d.coeff});
            const repr = if (d.scale > 0) try reconstructDecimalRepr(allocator, d.coeff, d.scale) else coeff_str;
            break :blk .{ .kind = .{ .decimal_val = .{
                .coeff = coeff_str,
                .scale = d.scale,
                .orig_scale = d.scale,
                .orig_repr = repr,
            } } };
        },
        .ExtValue => |ext| .{ .kind = .{ .ext_val = try extValueToProto(allocator, ext) } },
    };
}

/// Reconstruct a decimal string from coefficient and scale.
/// e.g., coeff=1999, scale=2 → "19.99"; coeff=5, scale=2 → "0.05"
fn reconstructDecimalRepr(allocator: std.mem.Allocator, coeff: i128, scale: u8) ![]const u8 {
    const is_negative = coeff < 0;
    const abs_coeff: u128 = if (is_negative) @intCast(-coeff) else @intCast(coeff);
    const digits = try std.fmt.allocPrint(allocator, "{d}", .{abs_coeff});
    defer allocator.free(digits);

    if (scale == 0 or digits.len == 0) {
        if (is_negative) return try std.fmt.allocPrint(allocator, "-{s}", .{digits});
        return try allocator.dupe(u8, digits);
    }

    // Pre-compute exact size to avoid ArrayList capacity mismatch on free
    const neg_len: usize = if (is_negative) 1 else 0;
    const total_len = if (digits.len <= scale)
        neg_len + 2 + (scale - digits.len) + digits.len // "-" + "0." + padding zeros + digits
    else
        neg_len + digits.len + 1; // "-" + integer part + "." + fractional part

    const buf = try allocator.alloc(u8, total_len);
    var pos: usize = 0;

    if (is_negative) {
        buf[pos] = '-';
        pos += 1;
    }

    if (digits.len <= scale) {
        // e.g., coeff=5, scale=2 → "0.05"
        buf[pos] = '0';
        buf[pos + 1] = '.';
        pos += 2;
        const pad = scale - digits.len;
        @memset(buf[pos .. pos + pad], '0');
        pos += pad;
        @memcpy(buf[pos .. pos + digits.len], digits);
    } else {
        // e.g., coeff=1999, scale=2 → "19.99"
        const int_end = digits.len - scale;
        @memcpy(buf[pos .. pos + int_end], digits[0..int_end]);
        pos += int_end;
        buf[pos] = '.';
        pos += 1;
        @memcpy(buf[pos .. pos + scale], digits[int_end..]);
    }
    return buf;
}

fn extValueToProto(allocator: std.mem.Allocator, ext: eval_extended.ExtValue) !schema.ExtendedValue {
    const type_name = type_helpers.getExtTypeName(ext);
    return switch (ext) {
        .Null => .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = "null" } },
        .Int => |i| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .int_val = i } },
        .Bool => |b| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .bool_val = b } },
        .Str => |s| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try allocator.dupe(u8, s) } },
        .Decimal => |d| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = if (d.scale > 0) try reconstructDecimalRepr(allocator, d.coeff, d.scale) else try std.fmt.allocPrint(allocator, "{d}", .{d.coeff}) } },
        .Bytea => |b| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .bytes = try allocator.dupe(u8, b) } },
        .Json => |j| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try allocator.dupe(u8, j) } },
        .Jsonb => |jb| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try allocator.dupe(u8, jb.data) } },
        .Xml => |x| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try allocator.dupe(u8, x.data) } },
        .Date => |d| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try d.toString(allocator) } },
        .Time => |t| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try t.toString(allocator) } },
        .TimestampTZ => |t| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try t.toString(allocator) } },
        .Interval => |i| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try i.toString(allocator) } },
        .UUID => |u| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try u.toString(allocator) } },
        .Url => |u| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try u.toString(allocator) } },
        .Domain => |d| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try d.toString(allocator) } },
        .BitString => |b| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try b.toString(allocator) } },
        .VarBit => |b| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try b.toString(allocator) } },
        .IntRange => |r| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try r.toString(allocator) } },
        else => .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try std.fmt.allocPrint(allocator, "{any}", .{ext}) } },
    };
}

fn textExt(allocator: std.mem.Allocator, type_name: []const u8, text: []const u8) !schema.ExtendedValue {
    return .{
        .type_name = try allocator.dupe(u8, type_name),
        .data = .{ .text = text },
    };
}
