const std = @import("std");
const schema = @import("schema");
const explain_payload = @import("../server/explain_payload.zig");
const profile_payload = @import("../server/profile_payload.zig");
const transport_response = @import("../cli/transport_response.zig");

pub const ColumnInfo = transport_response.ColumnInfo;
pub const QueryResultKind = transport_response.QueryResultKind;
pub const TransportResponseView = transport_response.TransportResponseView;

const TextMode = enum { display, dot, mermaid };

pub const CaptureSummary = struct {
    schema_received: bool = false,
    saw_page: bool = false,
    page_final: bool = false,
};

pub const ResultAccumulator = struct {
    allocator: std.mem.Allocator,
    format: []const u8,
    wants_json: bool,
    wants_dot: bool,
    wants_mermaid: bool,
    columns: std.ArrayList(ColumnInfo),
    result_kind: QueryResultKind = .rows,
    result_payload: ?[]u8 = null,
    rows_text: ?std.ArrayList(std.ArrayList([]const u8)) = null,
    rows_json: ?std.ArrayList(std.ArrayList(std.json.Value)) = null,
    ordered: bool = false,
    order_keys: std.ArrayList([]const u8),
    status_class: []const u8,
    status_subclass: []const u8 = "",
    status_subclass_owned: bool = false,
    additional_statuses: std.ArrayList([]const u8),
    flagger_findings: std.ArrayList([]const u8),
    status_captured: bool = false,
    has_error: bool = false,
    error_message: []const u8 = "",
    error_status: []const u8 = "58000",
    error_message_allocated: bool = false,
    error_status_allocated: bool = false,
    /// SONNY-2822: the statement's update counts, from its final page
    /// (null from a server that predates them).
    update_counts: ?schema.UpdateCounts = null,

    pub fn init(allocator: std.mem.Allocator, format: []const u8) !ResultAccumulator {
        const wants_json = std.mem.eql(u8, format, "json");
        const wants_dot = std.mem.eql(u8, format, "dot");
        const wants_mermaid = std.mem.eql(u8, format, "mermaid");
        var result = ResultAccumulator{
            .allocator = allocator,
            .format = try allocator.dupe(u8, format),
            .wants_json = wants_json,
            .wants_dot = wants_dot,
            .wants_mermaid = wants_mermaid,
            .columns = try std.ArrayList(ColumnInfo).initCapacity(allocator, 16),
            .order_keys = std.ArrayList([]const u8).empty,
            .status_class = try allocator.dupe(u8, "00000"),
            .additional_statuses = std.ArrayList([]const u8).empty,
            .flagger_findings = std.ArrayList([]const u8).empty,
        };
        if (wants_json) {
            result.rows_json = try std.ArrayList(std.ArrayList(std.json.Value)).initCapacity(allocator, 64);
        } else {
            result.rows_text = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 64);
        }
        return result;
    }

    pub fn deinit(self: *ResultAccumulator) void {
        self.allocator.free(self.format);

        for (self.columns.items) |col| {
            self.allocator.free(col.name);
            self.allocator.free(col.type);
        }
        self.columns.deinit(self.allocator);

        if (self.result_payload) |payload| {
            self.allocator.free(payload);
            self.result_payload = null;
        }

        if (self.rows_text) |*rows| {
            for (rows.items) |*row| {
                for (row.items) |cell| {
                    self.allocator.free(cell);
                }
                row.deinit(self.allocator);
            }
            rows.deinit(self.allocator);
            self.rows_text = null;
        }

        if (self.rows_json) |*rows| {
            for (rows.items) |*row| {
                for (row.items) |val| {
                    freeJsonValue(self.allocator, val);
                }
                row.deinit(self.allocator);
            }
            rows.deinit(self.allocator);
            self.rows_json = null;
        }

        for (self.order_keys.items) |key| {
            self.allocator.free(key);
        }
        self.order_keys.deinit(self.allocator);

        self.allocator.free(self.status_class);
        if (self.status_subclass_owned) {
            self.allocator.free(self.status_subclass);
        }

        for (self.additional_statuses.items) |item| {
            self.allocator.free(item);
        }
        self.additional_statuses.deinit(self.allocator);

        for (self.flagger_findings.items) |item| {
            self.allocator.free(item);
        }
        self.flagger_findings.deinit(self.allocator);

        if (self.error_message_allocated) {
            self.allocator.free(self.error_message);
        }
        if (self.error_status_allocated) {
            self.allocator.free(self.error_status);
        }
    }

    pub fn captureExecutionResponse(self: *ResultAccumulator, exec_resp: schema.ExecutionResponse) !CaptureSummary {
        try self.captureStatus(exec_resp.status);
        if (exec_resp.payload) |payload| {
            return try self.capturePayload(payload);
        }
        return .{};
    }

    pub fn render(self: *ResultAccumulator, stdout: anytype, stderr: anytype) !bool {
        // SONNY-6560: a graph format draws a successful row result. An error
        // and an EXPLAIN/PROFILE plan render below as in every other format
        // (the error on stderr, the plan on stdout); they used to print an
        // empty graph and drop the error message and the plan.
        if ((self.wants_dot or self.wants_mermaid) and !self.indicatesFailure() and self.result_kind == .rows) {
            const kind: GraphKind = if (self.wants_dot) .dot else .mermaid;
            const rows: []const std.ArrayList([]const u8) = if (self.rows_text) |r| r.items else &.{};
            const left_out = try renderGraph(kind, self.allocator, rows, stdout);
            if (left_out > 0) {
                const io = std.Io.Threaded.global_single_threaded.io();
                var err_out = if (@TypeOf(stderr) == std.Io.File) transport_response.Stream.init(stderr, io) else stderr;
                var buf: [192]u8 = undefined;
                const note = std.fmt.bufPrint(&buf, "Note: --format {s} draws nodes, relationships and paths; {d} value(s) that are none of these are not shown\n", .{ @tagName(kind), left_out }) catch unreachable;
                err_out.writeAll(note) catch {};
            }
            return false;
        }

        return transport_response.renderTransportResponseWithStreams(
            self.allocator,
            stdout,
            stderr,
            self.format,
            if (self.rows_text) |*rows| rows else null,
            if (self.rows_json) |*rows| rows else null,
            self.view(),
        );
    }

    pub fn view(self: *const ResultAccumulator) TransportResponseView {
        return .{
            .columns = self.columns.items,
            .ordered = self.ordered,
            .order_keys = self.order_keys.items,
            .status_class = self.status_class,
            .status_subclass = self.status_subclass,
            .additional_statuses = self.additional_statuses.items,
            .flagger_findings = self.flagger_findings.items,
            .has_error = self.has_error,
            .error_message = self.error_message,
            .error_status = self.error_status,
            .result_kind = self.result_kind,
            .result_payload = self.result_payload,
        };
    }

    pub fn rowCount(self: *const ResultAccumulator) usize {
        if (self.rows_text) |rows| return rows.items.len;
        if (self.rows_json) |rows| return rows.items.len;
        return 0;
    }

    pub fn indicatesFailure(self: *const ResultAccumulator) bool {
        if (self.has_error) return true;
        return self.status_class.len >= 2 and !std.mem.startsWith(u8, self.status_class, "00");
    }

    pub fn statusCaptured(self: *const ResultAccumulator) bool {
        return self.status_captured;
    }

    fn captureStatus(self: *ResultAccumulator, status_opt: ?schema.Status) !void {
        if (self.status_captured) return;
        if (status_opt == null) return;

        const status = status_opt.?;
        self.status_captured = true;
        self.allocator.free(self.status_class);
        self.status_class = try self.allocator.dupe(u8, status.status_class);

        if (self.status_subclass_owned) {
            self.allocator.free(self.status_subclass);
            self.status_subclass_owned = false;
        }
        if (status.status_subclass.len > 0) {
            self.status_subclass = try self.allocator.dupe(u8, status.status_subclass);
            self.status_subclass_owned = true;
        } else {
            self.status_subclass = "";
        }

        for (status.additional_statuses.items) |item| {
            try self.additional_statuses.append(self.allocator, try self.allocator.dupe(u8, item));
        }
        for (status.flagger_findings.items) |item| {
            try self.flagger_findings.append(self.allocator, try self.allocator.dupe(u8, item));
        }
    }

    fn capturePayload(self: *ResultAccumulator, payload: schema.ExecutionResponseUnion) !CaptureSummary {
        return switch (payload) {
            .schema => |schema_def| blk: {
                for (schema_def.columns.items) |col| {
                    try self.columns.append(self.allocator, .{
                        .name = try self.allocator.dupe(u8, col.name),
                        .type = if (col.type.len > 0)
                            try self.allocator.dupe(u8, col.type)
                        else
                            try self.allocator.dupe(u8, "ANY"),
                    });
                }
                break :blk .{ .schema_received = true };
            },
            .page => |page| blk: {
                try self.captureOrderMeta(page);
                if (page.update_counts) |counts| self.update_counts = counts;
                if (self.wants_json) {
                    if (self.rows_json) |*rows| try appendPageJson(self.allocator, page, rows);
                } else if (self.rows_text) |*rows| {
                    const mode: TextMode = if (self.wants_dot)
                        .dot
                    else if (self.wants_mermaid)
                        .mermaid
                    else
                        .display;
                    try appendPageText(self.allocator, page, rows, mode);
                }
                break :blk .{ .saw_page = true, .page_final = page.final };
            },
            .@"error" => |exec_error| blk: {
                self.has_error = true;
                self.error_message = try self.allocator.dupe(u8, exec_error.message);
                self.error_message_allocated = true;
                if (exec_error.code.len > 0) {
                    self.error_status = try self.allocator.dupe(u8, exec_error.code);
                    self.error_status_allocated = true;
                }
                break :blk .{};
            },
            .explain => |payload_value| blk: {
                self.result_kind = .explain;
                if (self.result_payload) |prev| self.allocator.free(prev);
                self.result_payload = try explain_payload.explainPayloadToJson(self.allocator, payload_value);
                break :blk .{ .schema_received = true };
            },
            .profile => |payload_value| blk: {
                self.result_kind = .profile;
                if (self.result_payload) |prev| self.allocator.free(prev);
                self.result_payload = try profile_payload.profilePayloadToJson(self.allocator, payload_value);
                break :blk .{ .schema_received = true };
            },
            .metrics, .heartbeat => .{},
        };
    }

    fn captureOrderMeta(self: *ResultAccumulator, page: schema.DataPage) !void {
        if (page.ordered) self.ordered = true;
        if (self.order_keys.items.len == 0 and page.order_keys.items.len > 0) {
            for (page.order_keys.items) |key| {
                try self.order_keys.append(self.allocator, try self.allocator.dupe(u8, key));
            }
        }
    }
};

fn appendPageText(
    allocator: std.mem.Allocator,
    page: schema.DataPage,
    rows_list: *std.ArrayList(std.ArrayList([]const u8)),
    mode: TextMode,
) !void {
    if (page.rows.items.len == 0) return;

    for (page.rows.items) |row| {
        var row_values = try std.ArrayList([]const u8).initCapacity(allocator, row.values.items.len);
        errdefer {
            for (row_values.items) |cell| allocator.free(cell);
            row_values.deinit(allocator);
        }

        for (row.values.items) |value| {
            try row_values.append(allocator, try valueToText(allocator, value, mode));
        }
        try rows_list.append(allocator, row_values);
    }
}

fn appendPageJson(
    allocator: std.mem.Allocator,
    page: schema.DataPage,
    rows_list: *std.ArrayList(std.ArrayList(std.json.Value)),
) !void {
    if (page.rows.items.len == 0) return;

    for (page.rows.items) |row| {
        var row_values = try std.ArrayList(std.json.Value).initCapacity(allocator, row.values.items.len);
        errdefer {
            for (row_values.items) |val| freeJsonValue(allocator, val);
            row_values.deinit(allocator);
        }

        for (row.values.items) |value| {
            try row_values.append(allocator, try protoValueToJson(allocator, value));
        }
        try rows_list.append(allocator, row_values);
    }
}

fn valueToText(allocator: std.mem.Allocator, value: schema.Value, mode: TextMode) ![]const u8 {
    if (value.kind) |kind| {
        return switch (kind) {
            .string_val => |str| try allocator.dupe(u8, str.value),
            .int_val => |v| try std.fmt.allocPrint(allocator, "{d}", .{v.value}),
            .double_val => |v| try std.fmt.allocPrint(allocator, "{d}", .{v.value}),
            .bool_val => |v| try allocator.dupe(u8, if (v) "true" else "false"),
            .null_val => try allocator.dupe(u8, "null"),
            .decimal_val => |v| blk: {
                const repr = if (v.orig_repr.len > 0) v.orig_repr else v.coeff;
                break :blk try allocator.dupe(u8, repr);
            },
            .bytes_val => |v| blk: {
                const out = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(v.value.len));
                _ = std.base64.standard.Encoder.encode(out, v.value);
                break :blk out;
            },
            else => blk: {
                if (mode == .dot or mode == .mermaid) {
                    break :blk try valueToJsonString(allocator, value);
                }
                const json_val = try protoValueToJson(allocator, value);
                defer freeJsonValue(allocator, json_val);
                break :blk try formatJsonValueCompact(allocator, json_val);
            },
        };
    }
    return allocator.dupe(u8, "null");
}

fn formatJsonValueCompact(allocator: std.mem.Allocator, val: std.json.Value) ![]u8 {
    return switch (val) {
        .null => try allocator.dupe(u8, "null"),
        .bool => |v| try allocator.dupe(u8, if (v) "true" else "false"),
        .integer => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .float => |v| try std.fmt.allocPrint(allocator, "{d:.6}", .{v}),
        .string => |v| try allocator.dupe(u8, v),
        .array => try allocator.dupe(u8, "[...]"),
        .object => |obj| blk: {
            if (obj.get("labels")) |labels_val| {
                if (labels_val == .array and labels_val.array.items.len > 0 and labels_val.array.items[0] == .string) {
                    break :blk try std.fmt.allocPrint(allocator, "({s})", .{labels_val.array.items[0].string});
                }
                break :blk try allocator.dupe(u8, "(node)");
            }
            if (obj.get("label")) |type_val| {
                if (type_val == .string) break :blk try std.fmt.allocPrint(allocator, "[:{s}]", .{type_val.string});
                break :blk try allocator.dupe(u8, "[rel]");
            }
            if (obj.get("type")) |type_val| {
                if (type_val == .string) break :blk try std.fmt.allocPrint(allocator, "[:{s}]", .{type_val.string});
                break :blk try allocator.dupe(u8, "[rel]");
            }
            break :blk try allocator.dupe(u8, "{...}");
        },
        .number_string => |v| try allocator.dupe(u8, v),
    };
}

fn jsonNumberFromU64(allocator: std.mem.Allocator, value: u64) !std.json.Value {
    if (value <= @as(u64, std.math.maxInt(i64))) {
        return .{ .integer = @intCast(value) };
    }
    return .{ .number_string = try std.fmt.allocPrint(allocator, "{d}", .{value}) };
}

fn base64Encode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(out, bytes);
    return out;
}

fn protoMapEntriesToJson(allocator: std.mem.Allocator, entries: []const schema.MapEntry) !std.json.ObjectMap {
    var obj: std.json.ObjectMap = .empty;
    for (entries) |entry| {
        try obj.put(allocator, try allocator.dupe(u8, entry.key), if (entry.value) |v| try protoValueToJson(allocator, v) else std.json.Value.null);
    }
    return obj;
}

fn protoNodeToJson(allocator: std.mem.Allocator, node: schema.NodeValue) !std.json.Value {
    var obj = @as(std.json.ObjectMap, .empty);
    try obj.put(allocator, try allocator.dupe(u8, "id"), try jsonNumberFromU64(allocator, node.id));

    var labels = std.json.Array.init(allocator);
    for (node.labels.items) |label| {
        try labels.append(.{ .string = try allocator.dupe(u8, label) });
    }
    try obj.put(allocator, try allocator.dupe(u8, "labels"), .{ .array = labels });
    try obj.put(allocator, try allocator.dupe(u8, "properties"), .{ .object = try protoMapEntriesToJson(allocator, node.properties.items) });
    return .{ .object = obj };
}

fn protoEdgeToJson(allocator: std.mem.Allocator, edge: schema.EdgeValue) !std.json.Value {
    var obj = @as(std.json.ObjectMap, .empty);
    try obj.put(allocator, try allocator.dupe(u8, "id"), try jsonNumberFromU64(allocator, edge.id));
    try obj.put(allocator, try allocator.dupe(u8, "from"), try jsonNumberFromU64(allocator, edge.from_id));
    try obj.put(allocator, try allocator.dupe(u8, "to"), try jsonNumberFromU64(allocator, edge.to_id));
    try obj.put(allocator, try allocator.dupe(u8, "label"), .{ .string = try allocator.dupe(u8, edge.label) });
    try obj.put(allocator, try allocator.dupe(u8, "properties"), .{ .object = try protoMapEntriesToJson(allocator, edge.properties.items) });
    return .{ .object = obj };
}

fn protoPathToJson(allocator: std.mem.Allocator, path: schema.PathValue) !std.json.Value {
    var obj = @as(std.json.ObjectMap, .empty);

    var nodes = std.json.Array.init(allocator);
    for (path.nodes.items) |node| {
        try nodes.append(try protoNodeToJson(allocator, node));
    }
    try obj.put(allocator, try allocator.dupe(u8, "nodes"), .{ .array = nodes });

    var edges = std.json.Array.init(allocator);
    for (path.edges.items) |edge| {
        try edges.append(try protoEdgeToJson(allocator, edge));
    }
    try obj.put(allocator, try allocator.dupe(u8, "edges"), .{ .array = edges });
    return .{ .object = obj };
}

fn protoExtendedToJson(allocator: std.mem.Allocator, ext: schema.ExtendedValue) !std.json.Value {
    var obj = @as(std.json.ObjectMap, .empty);
    if (ext.type_name.len > 0) {
        try obj.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, ext.type_name) });
    }
    if (ext.data) |data| {
        const value: std.json.Value = switch (data) {
            .text => |v| .{ .string = try allocator.dupe(u8, v) },
            .bytes => |v| .{ .string = try base64Encode(allocator, v) },
            .int_val => |v| .{ .integer = v },
            .double_val => |v| .{ .float = v },
            .bool_val => |v| .{ .bool = v },
        };
        try obj.put(allocator, try allocator.dupe(u8, "value"), value);
    }
    return .{ .object = obj };
}

pub fn protoValueToJson(allocator: std.mem.Allocator, value: schema.Value) error{OutOfMemory}!std.json.Value {
    const kind = value.kind orelse return std.json.Value.null;
    return switch (kind) {
        .null_val => std.json.Value.null,
        .int_val => |v| .{ .integer = v.value },
        .double_val => |v| .{ .float = v.value },
        .bool_val => |v| .{ .bool = v },
        .string_val => |v| .{ .string = try allocator.dupe(u8, v.value) },
        .decimal_val => |v| blk: {
            const repr = if (v.orig_repr.len > 0) v.orig_repr else v.coeff;
            break :blk .{ .string = try allocator.dupe(u8, repr) };
        },
        .bytes_val => |v| .{ .string = try base64Encode(allocator, v.value) },
        .list_val => |v| blk: {
            var arr = std.json.Array.init(allocator);
            for (v.values.items) |item| {
                try arr.append(try protoValueToJson(allocator, item));
            }
            break :blk .{ .array = arr };
        },
        .map_val => |v| blk: {
            break :blk .{ .object = try protoMapEntriesToJson(allocator, v.entries.items) };
        },
        .node_val => |v| try protoNodeToJson(allocator, v),
        .edge_val => |v| try protoEdgeToJson(allocator, v),
        .path_val => |v| try protoPathToJson(allocator, v),
        .ext_val => |v| try protoExtendedToJson(allocator, v),
    };
}

fn valueToJsonString(allocator: std.mem.Allocator, value: schema.Value) ![]const u8 {
    const json_val = try protoValueToJson(allocator, value);
    defer freeJsonValue(allocator, json_val);
    return std.json.Stringify.valueAlloc(allocator, json_val, .{});
}

pub fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    freeJsonValueImpl(allocator, value, true);
}

fn freeJsonValueImpl(allocator: std.mem.Allocator, value: std.json.Value, free_keys: bool) void {
    switch (value) {
        .number_string => |v| allocator.free(v),
        .string => |v| allocator.free(v),
        .array => |arr| {
            for (arr.items) |item| {
                freeJsonValueImpl(allocator, item, true);
            }
            var mutable_arr = arr;
            mutable_arr.deinit();
        },
        .object => |obj| {
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                if (free_keys) allocator.free(entry.key_ptr.*);
                freeJsonValueImpl(allocator, entry.value_ptr.*, true);
            }
            var mutable_obj = obj;
            mutable_obj.deinit(allocator);
        },
        else => {},
    }
}

fn getDotIdString(allocator: std.mem.Allocator, val: ?std.json.Value) ?[]const u8 {
    const value = val orelse return null;
    if (value == .string) return allocator.dupe(u8, value.string) catch null;
    if (value == .integer) return std.fmt.allocPrint(allocator, "{d}", .{value.integer}) catch null;
    return null;
}

fn getDotNodeId(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ?[]const u8 {
    if (obj.get("id")) |id| return getDotIdString(allocator, id);
    if (obj.get("_id")) |id| return getDotIdString(allocator, id);
    if (obj.get("element_id")) |id| return getDotIdString(allocator, id);
    return null;
}

// CANARY: REQ=REQ-SONNY-6560-GRAPH-FORMATS; FEATURE="CliOptions"; ASPECT=DotMermaidEveryShape; STATUS=TESTED; TEST=tests/test_sonny6560_cli_unsupported_options.zig; OWNER=cli; UPDATED=2026-11-14
// SONNY-6560: --format dot and mermaid draw the nodes and relationships of
// every cell: a node, a relationship, a path (its nodes and relationships)
// and a list of them. They used to draw only a bare node or relationship
// cell, so a path printed an empty graph, and DOT strings were written
// unescaped (a name holding `"` broke the graph). A cell that holds no graph
// element is counted, and the caller says how many were not shown.

const GraphKind = enum { dot, mermaid };

/// The nodes and relationships of a result, in encounter order, each once.
const GraphElements = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    seen_nodes: std.StringHashMapUnmanaged(void) = .empty,
    seen_edges: std.StringHashMapUnmanaged(void) = .empty,
    /// Cells holding no node, relationship or path.
    left_out: usize = 0,

    const Node = struct {
        id: []const u8,
        labels: []const u8,
        display: ?[]const u8,
    };
    const Edge = struct {
        from: []const u8,
        to: []const u8,
        label: []const u8,
    };

    fn deinit(self: *GraphElements) void {
        const a = self.allocator;
        for (self.nodes.items) |n| {
            a.free(n.labels);
            if (n.display) |d| a.free(d);
        }
        self.nodes.deinit(a);
        for (self.edges.items) |e| {
            a.free(e.from);
            a.free(e.to);
            a.free(e.label);
        }
        self.edges.deinit(a);
        var it = self.seen_nodes.keyIterator();
        while (it.next()) |k| a.free(k.*);
        self.seen_nodes.deinit(a);
        var eit = self.seen_edges.keyIterator();
        while (eit.next()) |k| a.free(k.*);
        self.seen_edges.deinit(a);
    }

    fn addRows(self: *GraphElements, rows: []const std.ArrayList([]const u8)) !void {
        for (rows) |row| {
            for (row.items) |cell| try self.addCell(cell);
        }
    }

    fn addCell(self: *GraphElements, cell: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, cell, .{}) catch {
            self.left_out += 1;
            return;
        };
        defer parsed.deinit();
        if (!try self.walk(parsed.value)) self.left_out += 1;
    }

    /// Adds the graph elements in `value`; false when it holds none.
    fn walk(self: *GraphElements, value: std.json.Value) error{OutOfMemory}!bool {
        switch (value) {
            .array => |arr| {
                var any = false;
                for (arr.items) |item| any = (try self.walk(item)) or any;
                return any;
            },
            .object => |obj| {
                if (obj.get("labels")) |labels_val| return self.addNode(obj, labels_val);
                if (obj.get("nodes")) |nodes_val| {
                    if (nodes_val == .array) {
                        var any = try self.walk(nodes_val);
                        if (obj.get("edges")) |edges_val| any = (try self.walk(edges_val)) or any;
                        return any;
                    }
                }
                if (obj.get("label") orelse obj.get("type")) |type_val| {
                    if (type_val == .string) return self.addEdge(obj, type_val.string);
                }
                return false;
            },
            else => return false,
        }
    }

    fn addNode(self: *GraphElements, obj: std.json.ObjectMap, labels_val: std.json.Value) !bool {
        const a = self.allocator;
        const id = getDotNodeId(a, obj) orelse return false;
        if (self.seen_nodes.contains(id)) {
            a.free(id);
            return true;
        }
        try self.seen_nodes.put(a, id, {});

        var labels: std.ArrayList(u8) = .empty;
        errdefer labels.deinit(a);
        if (labels_val == .array) {
            for (labels_val.array.items, 0..) |label, idx| {
                if (idx > 0) try labels.append(a, ':');
                if (label == .string) try labels.appendSlice(a, label.string);
            }
        }
        var display: ?[]const u8 = null;
        const display_props = [_][]const u8{ "name", "title", "label", "username", "email" };
        if (obj.get("properties")) |props_val| {
            if (props_val == .object) {
                for (display_props) |prop| {
                    if (props_val.object.get(prop)) |val| {
                        if (val == .string and val.string.len > 0) {
                            display = try a.dupe(u8, val.string);
                            break;
                        }
                    }
                }
            }
        }
        errdefer if (display) |d| a.free(d);
        try self.nodes.append(a, .{ .id = id, .labels = try labels.toOwnedSlice(a), .display = display });
        return true;
    }

    fn addEdge(self: *GraphElements, obj: std.json.ObjectMap, label: []const u8) !bool {
        const a = self.allocator;
        const from = getDotIdString(a, obj.get("from")) orelse
            getDotIdString(a, obj.get("start_node")) orelse return false;
        errdefer a.free(from);
        const to = getDotIdString(a, obj.get("to")) orelse
            getDotIdString(a, obj.get("end_node")) orelse {
            a.free(from);
            return false;
        };
        errdefer a.free(to);
        // A relationship met twice (two paths through it) is drawn once.
        if (getDotIdString(a, obj.get("id"))) |edge_id| {
            if (self.seen_edges.contains(edge_id)) {
                a.free(edge_id);
                a.free(from);
                a.free(to);
                return true;
            }
            self.seen_edges.put(a, edge_id, {}) catch |err| {
                a.free(edge_id);
                return err;
            };
        }
        try self.edges.append(a, .{ .from = from, .to = to, .label = try a.dupe(u8, label) });
        return true;
    }
};

/// Write `raw` as the inside of a DOT double-quoted string.
fn writeDotEscaped(out: anytype, raw: []const u8) !void {
    var start: usize = 0;
    for (raw, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "",
            else => null,
        };
        if (esc) |e| {
            try out.writeAll(raw[start..i]);
            try out.writeAll(e);
            start = i + 1;
        }
    }
    try out.writeAll(raw[start..]);
}

/// A Mermaid node id: `n` and the element id, with anything but [A-Za-z0-9_] as `_`.
fn writeMermaidId(out: anytype, id: []const u8) !void {
    try out.writeAll("n");
    for (id) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_';
        try out.writeAll(if (ok) &[_]u8{c} else "_");
    }
}

/// CANARY: REQ=REQ-CLI-DOT-003; FEATURE="DotFormat"; ASPECT=RowBasedOutput; STATUS=TESTED; TEST=tests/test_sonny6560_cli_unsupported_options.zig; OWNER=cli; UPDATED=2026-11-15
/// Render `rows` as a DOT digraph or a Mermaid flowchart; returns how many
/// cells held no graph element (not drawn).
fn renderGraph(kind: GraphKind, allocator: std.mem.Allocator, rows: []const std.ArrayList([]const u8), stdout: anytype) !usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    var out = if (@TypeOf(stdout) == std.Io.File) transport_response.Stream.init(stdout, io) else stdout;

    var graph: GraphElements = .{ .allocator = allocator };
    defer graph.deinit();
    try graph.addRows(rows);

    switch (kind) {
        .dot => {
            try out.writeAll("digraph G {\n");
            try out.writeAll("  rankdir=LR;\n");
            try out.writeAll("  node [shape=ellipse, style=filled, fillcolor=lightblue];\n");
            try out.writeAll("  edge [fontsize=10];\n\n");
            for (graph.nodes.items) |n| {
                try out.writeAll("  \"");
                try writeDotEscaped(out, n.id);
                try out.writeAll("\" [label=\"");
                if (n.labels.len == 0 and n.display == null) {
                    try writeDotEscaped(out, n.id);
                } else {
                    try writeDotEscaped(out, n.labels);
                    if (n.display) |d| {
                        try out.writeAll("\\n");
                        try writeDotEscaped(out, d);
                    }
                }
                try out.writeAll("\"];\n");
            }
            for (graph.edges.items) |e| {
                try out.writeAll("  \"");
                try writeDotEscaped(out, e.from);
                try out.writeAll("\" -> \"");
                try writeDotEscaped(out, e.to);
                try out.writeAll("\" [label=\"");
                try writeDotEscaped(out, e.label);
                try out.writeAll("\"];\n");
            }
            try out.writeAll("}\n");
        },
        .mermaid => {
            try out.writeAll("flowchart LR\n");
            for (graph.nodes.items) |n| {
                var raw: std.ArrayList(u8) = .empty;
                defer raw.deinit(allocator);
                if (n.labels.len == 0 and n.display == null) {
                    try raw.appendSlice(allocator, n.id);
                } else {
                    try raw.appendSlice(allocator, n.labels);
                    if (n.display) |d| {
                        try raw.appendSlice(allocator, "<br/>");
                        try raw.appendSlice(allocator, d);
                    }
                }
                const label = try escapeMermaidLabel(allocator, raw.items);
                defer allocator.free(label);
                try out.writeAll("  ");
                try writeMermaidId(out, n.id);
                try out.writeAll("[\"");
                try out.writeAll(label);
                try out.writeAll("\"]\n");
            }
            for (graph.edges.items) |e| {
                const escaped_type = try escapeMermaidLabel(allocator, e.label);
                defer allocator.free(escaped_type);
                try out.writeAll("  ");
                try writeMermaidId(out, e.from);
                try out.writeAll(" -->|\"");
                try out.writeAll(escaped_type);
                try out.writeAll("\"| ");
                try writeMermaidId(out, e.to);
                try out.writeAll("\n");
            }
        },
    }
    return graph.left_out;
}

pub fn outputDotFormatFromRows(
    allocator: std.mem.Allocator,
    rows: []const std.ArrayList([]const u8),
    stdout: anytype,
) !void {
    _ = try renderGraph(.dot, allocator, rows, stdout);
}

pub fn outputMermaidFormatFromRows(
    allocator: std.mem.Allocator,
    rows: []const std.ArrayList([]const u8),
    stdout: anytype,
) !void {
    _ = try renderGraph(.mermaid, allocator, rows, stdout);
}

fn escapeMermaidLabel(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, raw.len);
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        switch (c) {
            '<' => {
                if (i + 4 < raw.len and std.mem.eql(u8, raw[i .. i + 5], "<br/>")) {
                    try out.appendSlice(allocator, "<br/>");
                    i += 4;
                } else {
                    try out.appendSlice(allocator, "&lt;");
                }
            },
            '&' => try out.appendSlice(allocator, "&amp;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            else => try out.append(allocator, c),
        }
    }

    return try out.toOwnedSlice(allocator);
}
