const std = @import("std");
const GqlLexer = @import("gql/lexer.zig");
const GqlParser = @import("gql/parser.zig");
const heap = @import("storage/heap.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-001; FEATURE="External Library Migration"; ASPECT=JSONEncoding; STATUS=TESTED; OWNER=core; UPDATED=2026-01-24
// External JSON library - RFC 8259 compliant with JSON Schema 2020-12 support
// Provides enhanced parsing, schema validation, SIMD acceleration, and type-safe encoding
const json_lib = @import("json");

// ============================================================================
// PROTOCOL RESPONSE TYPES - Type-safe JSON encoding for wire protocol frames
// ============================================================================

/// SCHEMA response frame - sent when query returns column metadata
pub const SchemaResponse = struct {
    status_class: []const u8 = "00000",
    result: SchemaResult,

    pub const SchemaResult = struct {
        type: []const u8 = "SCHEMA",
        columns: []const SchemaCol,
        additional_statuses: ?[]const []const u8 = null,
        flagger_findings: ?[]const []const u8 = null,
    };
};

/// BINDINGS response frame - sent when query returns row data
/// Note: The 'rows' field contains pre-encoded JSON and must be handled specially
pub const BindingsResponse = struct {
    status_class: []const u8 = "00000",
    result: BindingsResult,

    pub const BindingsResult = struct {
        type: []const u8 = "BINDINGS",
        ordered: bool,
        order_keys: []const []const u8,
        // rows is handled separately as raw JSON
        final: bool,
        additional_statuses: ?[]const []const u8 = null,
        flagger_findings: ?[]const []const u8 = null,
    };
};

/// EXPLAIN response frame - sent for EXPLAIN queries
pub const ExplainResponse = struct {
    status_class: []const u8 = "00000",
    result: ExplainResult,

    pub const ExplainResult = struct {
        type: []const u8 = "EXPLAIN",
        // json payload is handled separately as raw JSON
        flagger_findings: ?[]const []const u8 = null,
    };
};

/// PROFILE response frame - sent for PROFILE queries
pub const ProfileResponse = struct {
    status_class: []const u8 = "00000",
    result: ProfileResult,

    pub const ProfileResult = struct {
        type: []const u8 = "PROFILE",
        // json payload is handled separately as raw JSON
        flagger_findings: ?[]const []const u8 = null,
    };
};

/// CDC_DIAGNOSTICS response frame
pub const CdcDiagnosticsResponse = struct {
    status_class: []const u8 = "00000",
    result: CdcDiagnosticsResult,

    pub const CdcDiagnosticsResult = struct {
        type: []const u8 = "CDC_DIAGNOSTICS",
        // json payload is handled separately as raw JSON
    };
};

/// CDC_CONTROL response frame
pub const CdcControlResponse = struct {
    status_class: []const u8 = "00000",
    result: CdcControlResult,

    pub const CdcControlResult = struct {
        type: []const u8 = "CDC_CONTROL",
        action: []const u8,
        status: []const u8,
        guardrail_epoch: u64,
    };
};

/// ERROR response frame
pub const ErrorResponse = struct {
    status_class: []const u8,
    status_subclass: ?[]const u8 = null,
    result: ErrorResult,

    pub const ErrorResult = struct {
        type: []const u8 = "ERROR",
        code: []const u8,
        message: []const u8,
        anchor: []const u8,
        additional_statuses: ?[]const []const u8 = null,
        flagger_findings: ?[]const []const u8 = null,
    };
};

// CANARY: REQ=REQ-GQL-005; FEATURE="Binary Protocol Core"; ASPECT=Wire; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_005_HelloRoundTrip; OWNER=wire; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=CDCDiagnosticsProtocol; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_DiagnosticsProtocol; OWNER=wire; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=CDCControlProtocol; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_ControlReset; OWNER=wire; UPDATED=2025-09-20

// Debug instrumentation toggle for protocol frame builders.
// Set true locally when investigating length arithmetic or corruption.
const PROTOCOL_DEBUG = false;

pub const MessageType = enum { HELLO, RUN_GQL, PULL, BEGIN, COMMIT, ROLLBACK, SAVEPOINT, ROLLBACK_TO, PING, CDC_DIAGNOSTICS, CDC_CONTROL, BACKUP, RESTORE, UPLOAD_BACKUP };

pub const Hello = struct {
    client_name: []const u8,
    client_ver: []const u8,
    wanted_conformance: []const u8,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    // CANARY: REQ=REQ-MULTI-TENANT-003; FEATURE="Multi-Tenancy Protocol"; ASPECT=HelloTenant; STATUS=TESTED; TEST=geodetestlab/specs/gql_session_management_comprehensive.yml; OWNER=protocol; UPDATED=2026-01-09
    tenant_id: ?[]const u8 = null, // Optional tenant identifier for multi-tenant deployments
};

pub const RunGql = struct {
    text: []const u8,
    params_json: ?[]const u8 = null, // raw JSON object string of params
};

pub const Pull = struct {
    request_id: u64 = 1,
    page_size: usize = 1000,
};

pub const Backup = struct {
    backup_type: []const u8, // "full" or "incremental"
    parent_id: ?[]const u8 = null, // Required for incremental backups
    compress: bool = false,
};

pub const Restore = struct {
    target_time: ?[]const u8 = null, // Optional timestamp for point-in-time recovery
    confirm: bool = false, // Restore confirmation flag
};

pub const UploadBackup = struct {
    size_bytes: u64, // Size of backup file being uploaded
    checksum: []const u8, // CRC32 checksum for validation
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
    BACKUP: Backup,
    RESTORE: Restore,
    UPLOAD_BACKUP: UploadBackup,
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

// CANARY: REQ=REQ-PROTOCOL-TYPES-001; FEATURE="Protocol Type Definitions"; ASPECT=Protocol; STATUS=TESTED; TEST=geodetestlab/specs/gql_protocol_compliance.yml; OWNER=protocol; UPDATED=2026-01-25
// Type definitions for distributed query coordination (GAP-0053)
pub const BindingValue = union(enum) {
    Null,
    Int: i64,
    Decimal: struct { coeff: i128, scale: u8 },
    Str: []const u8,
    Bool: bool,
    List: []BindingValue,
};

pub const BindingRow = struct {
    cols: []const BindingValue,

    /// Get value at column index, returns Null if out of bounds
    pub fn get(self: BindingRow, idx: usize) BindingValue {
        if (idx < self.cols.len) return self.cols[idx];
        return .{ .Null = {} };
    }
};

pub const ColumnDef = struct {
    name: []const u8,
    data_type: []const u8 = "ANY",
};

pub const Value = union(enum) {
    Null,
    Int: i64,
    Bool: bool,
    Str: []const u8,
    Float: f64,
};

/// Compare two BindingValues with NULL handling according to NULLS FIRST/LAST policy
// CANARY: REQ=REQ-DIST-CMP-001; FEATURE="Distributed Value Comparison"; ASPECT=Distributed; STATUS=TESTED; TEST=geodetestlab/specs/gql_distributed_queries.yml; OWNER=protocol; UPDATED=2026-01-25
pub fn compareBindingValues(a: BindingValue, b: BindingValue, nulls_first: bool) std.math.Order {
    // Handle NULL cases first according to policy
    const a_is_null = (a == .Null);
    const b_is_null = (b == .Null);
    if (a_is_null or b_is_null) {
        if (a_is_null and b_is_null) return .eq;
        if (nulls_first) {
            return if (a_is_null) .lt else .gt;
        } else {
            return if (a_is_null) .gt else .lt;
        }
    }

    // Compare by type rank: Bool < Int < Decimal < Str < List
    const rank = struct {
        fn of(v: BindingValue) u8 {
            return switch (v) {
                .Null => 0,
                .Bool => 1,
                .Int => 2,
                .Decimal => 3,
                .Str => 4,
                .List => 5,
            };
        }
    };
    const ra = rank.of(a);
    const rb = rank.of(b);
    if (ra != rb) {
        return if (ra < rb) .lt else .gt;
    }

    // Same type - compare values
    return switch (a) {
        .Null => .eq,
        .Bool => |av| {
            const bv = b.Bool;
            if (av == bv) return .eq;
            return if (av) .gt else .lt; // false < true
        },
        .Int => |av| {
            const bv = b.Int;
            if (av == bv) return .eq;
            return if (av < bv) .lt else .gt;
        },
        .Decimal => |ad| {
            const bd = b.Decimal;
            // Align scales for comparison
            if (ad.scale == bd.scale) {
                if (ad.coeff == bd.coeff) return .eq;
                return if (ad.coeff < bd.coeff) .lt else .gt;
            }
            // Compare normalized values
            const max_scale = if (ad.scale > bd.scale) ad.scale else bd.scale;
            const a_adj = ad.coeff * std.math.pow(i128, 10, max_scale - ad.scale);
            const b_adj = bd.coeff * std.math.pow(i128, 10, max_scale - bd.scale);
            if (a_adj == b_adj) return .eq;
            return if (a_adj < b_adj) .lt else .gt;
        },
        .Str => |as| {
            const bs = b.Str;
            return std.mem.order(u8, as, bs);
        },
        .List => .eq, // Lists compare as equal for sorting purposes
    };
}

/// Compare two binding rows by specified column indices with order directions
// CANARY: REQ=REQ-DIST-ROW-CMP-001; FEATURE="Distributed Row Comparison"; ASPECT=Distributed; STATUS=TESTED; TEST=geodetestlab/specs/gql_distributed_queries.yml; OWNER=protocol; UPDATED=2026-01-25
pub fn compareBindingRows(
    a: BindingRow,
    b: BindingRow,
    order_col_indices: []const usize,
    order_ascending: []const bool,
    nulls_first: bool,
) std.math.Order {
    for (order_col_indices, 0..) |col_idx, key_idx| {
        const av = a.get(col_idx);
        const bv = b.get(col_idx);
        const cmp = compareBindingValues(av, bv, nulls_first);

        if (cmp == .eq) continue;

        // Apply sort direction
        const ascending = if (key_idx < order_ascending.len) order_ascending[key_idx] else true;
        if (ascending) {
            return cmp;
        } else {
            return if (cmp == .lt) .gt else .lt;
        }
    }
    return .eq;
}

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-002; FEATURE="JSON Library Migration"; ASPECT=SchemaFrame; STATUS=TESTED; OWNER=protocol; UPDATED=2026-01-24
pub fn buildSchemaLine(allocator: std.mem.Allocator, cols: []const SchemaCol, additional: []const []const u8, flags: []const []const u8) ![]u8 {
    const response = SchemaResponse{
        .result = .{
            .columns = cols,
            .additional_statuses = if (additional.len > 0) additional else null,
            .flagger_findings = if (flags.len > 0) flags else null,
        },
    };

    const json_str = try json_lib.encode(allocator, response, .{});
    defer allocator.free(json_str);

    // Append newline for wire protocol
    const result = try allocator.alloc(u8, json_str.len + 1);
    @memcpy(result[0..json_str.len], json_str);
    result[json_str.len] = '\n';
    return result;
}

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-003; FEATURE="JSON Library Migration"; ASPECT=BindingsFrame; STATUS=TESTED; OWNER=protocol; UPDATED=2026-01-24
pub fn buildBindingsLine(allocator: std.mem.Allocator, ordered: bool, order_keys: []const []const u8, rows_json: []const u8, final: bool, additional: []const []const u8, flags: []const []const u8) ![]u8 {
    // Use streaming encoder to handle raw JSON embedding for rows field
    var buf = std.ArrayList(u8).initCapacity(allocator, 256) catch return error.OutOfMemory;
    errdefer buf.deinit(allocator);

    var encoder = json_lib.streamingEncoder(allocator, buf.writer(allocator), .{});
    defer encoder.deinit();

    try encoder.beginObject();

    try encoder.writeKey("status_class");
    try encoder.writeString("00000");

    try encoder.writeKey("result");
    try encoder.beginObject();

    try encoder.writeKey("type");
    try encoder.writeString("BINDINGS");

    try encoder.writeKey("ordered");
    try encoder.writeBool(ordered);

    try encoder.writeKey("order_keys");
    try encoder.beginArray();
    for (order_keys) |key| {
        try encoder.writeString(key);
    }
    try encoder.endArray();

    try encoder.writeKey("rows");
    try encoder.writeRaw(rows_json); // Embed pre-encoded JSON directly

    try encoder.writeKey("final");
    try encoder.writeBool(final);

    if (additional.len > 0) {
        try encoder.writeKey("additional_statuses");
        try encoder.beginArray();
        for (additional) |status| {
            try encoder.writeString(status);
        }
        try encoder.endArray();
    }

    if (flags.len > 0) {
        try encoder.writeKey("flagger_findings");
        try encoder.beginArray();
        for (flags) |flag| {
            try encoder.writeString(flag);
        }
        try encoder.endArray();
    }

    try encoder.endObject(); // result
    try encoder.endObject(); // root

    // Append newline for wire protocol
    try buf.append(allocator, '\n');
    return buf.toOwnedSlice(allocator);
}

/// Enumerate implementation-defined / dependent behavior flags surfaced in protocol frames.
/// These are prefixed with categories:
///  I: Implementation-defined
///  U: Usage / policy toggle
/// Returned slice lifetime: caller owned (single allocation of joined strings).
pub fn collectImplementationFlags(allocator: std.mem.Allocator, lexer_state: ?*const GqlLexer.Lexer, parser_state: ?*const GqlParser.Parser, session_ctx: ?*const SessionContext) ![][]const u8 {
    // Build dynamic list based on runtime state
    var flags = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return error.OutOfMemory;

    // Check if expressions are allowed in ORDER BY (now they are)
    try flags.append(allocator, "I:IllegalOrderKeyPolicy=expr");

    // Check for ORDER tie-break when no explicit ORDER BY
    if (session_ctx != null and session_ctx.?.implicit_order_applied) {
        try flags.append(allocator, "U:OrderTiebreak=LexJSON");
    }

    // Check for double-solidus comment usage
    if (lexer_state != null and lexer_state.?.has_double_solidus_comment) {
        try flags.append(allocator, "GB03:DoubleSolidusComment");
    }

    // Check for ordinal sort keys
    if (parser_state != null and parser_state.?.has_ordinal_sort_key) {
        try flags.append(allocator, "E:OrdinalSortKey");
    }

    // Check for multi-graph catalog
    if (session_ctx != null and session_ctx.?.graph_catalog != null) {
        try flags.append(allocator, "I:GraphCatalog=memory");
    }

    // Static flags
    try flags.append(allocator, "I:PathTieBreak=LengthId");
    try flags.append(allocator, "I:Collation=binary");

    return flags.toOwnedSlice(allocator);
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

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-004; FEATURE="JSON Library Migration"; ASPECT=ExplainFrame; STATUS=TESTED; OWNER=protocol; UPDATED=2026-01-24
pub fn buildExplainLine(allocator: std.mem.Allocator, json_payload: []const u8, flags: []const []const u8) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 256) catch return error.OutOfMemory;
    errdefer buf.deinit(allocator);

    var encoder = json_lib.streamingEncoder(allocator, buf.writer(allocator), .{});
    defer encoder.deinit();

    try encoder.beginObject();

    try encoder.writeKey("status_class");
    try encoder.writeString("00000");

    try encoder.writeKey("result");
    try encoder.beginObject();

    try encoder.writeKey("type");
    try encoder.writeString("EXPLAIN");

    try encoder.writeKey("json");
    try encoder.writeRaw(json_payload); // Embed pre-encoded JSON directly

    if (flags.len > 0) {
        try encoder.writeKey("flagger_findings");
        try encoder.beginArray();
        for (flags) |flag| {
            try encoder.writeString(flag);
        }
        try encoder.endArray();
    }

    try encoder.endObject(); // result
    try encoder.endObject(); // root

    try buf.append(allocator, '\n');
    return buf.toOwnedSlice(allocator);
}

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-005; FEATURE="JSON Library Migration"; ASPECT=ProfileFrame; STATUS=TESTED; OWNER=protocol; UPDATED=2026-01-24
pub fn buildProfileLine(allocator: std.mem.Allocator, json_payload: []const u8, flags: []const []const u8) ![]u8 {
    // Estimate total size for sanity check (preserve overflow protection)
    var estimated_size: usize = 100 + json_payload.len; // base frame overhead
    for (flags) |f| {
        estimated_size += f.len + 3; // quotes + comma
    }

    if (PROTOCOL_DEBUG) std.debug.print("[debug] buildProfileLine payload={d} flags={d} estimated={d}\n", .{ json_payload.len, flags.len, estimated_size });

    // Overflow/corruption guard: if estimated is suspiciously large relative to payload, emit fallback
    if (estimated_size > 1_000_000 and json_payload.len < 10_000) {
        if (PROTOCOL_DEBUG) std.debug.print("[warn] buildProfileLine suspicious estimated={d} payload={d} flags={d}; using fallback minimal profile frame\n", .{ estimated_size, json_payload.len, flags.len });
        const fallback = "{\"status_class\":\"00000\",\"result\":{\"type\":\"PROFILE\",\"json\":{\"profile_version\":2,\"ops\":[],\"totals\":{}}}}\n";
        return try allocator.dupe(u8, fallback);
    }

    var buf = std.ArrayList(u8).initCapacity(allocator, 256) catch return error.OutOfMemory;
    errdefer buf.deinit(allocator);

    var encoder = json_lib.streamingEncoder(allocator, buf.writer(allocator), .{});
    defer encoder.deinit();

    try encoder.beginObject();

    try encoder.writeKey("status_class");
    try encoder.writeString("00000");

    try encoder.writeKey("result");
    try encoder.beginObject();

    try encoder.writeKey("type");
    try encoder.writeString("PROFILE");

    try encoder.writeKey("json");
    try encoder.writeRaw(json_payload); // Embed pre-encoded JSON directly

    if (flags.len > 0) {
        try encoder.writeKey("flagger_findings");
        try encoder.beginArray();
        for (flags) |flag| {
            try encoder.writeString(flag);
        }
        try encoder.endArray();
    }

    try encoder.endObject(); // result
    try encoder.endObject(); // root

    try buf.append(allocator, '\n');
    return buf.toOwnedSlice(allocator);
}

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-006; FEATURE="JSON Library Migration"; ASPECT=CdcDiagnosticsFrame; STATUS=TESTED; OWNER=protocol; UPDATED=2026-01-24
pub fn buildCdcDiagnosticsLine(allocator: std.mem.Allocator, json_payload: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 256) catch return error.OutOfMemory;
    errdefer buf.deinit(allocator);

    var encoder = json_lib.streamingEncoder(allocator, buf.writer(allocator), .{});
    defer encoder.deinit();

    try encoder.beginObject();

    try encoder.writeKey("status_class");
    try encoder.writeString("00000");

    try encoder.writeKey("result");
    try encoder.beginObject();

    try encoder.writeKey("type");
    try encoder.writeString("CDC_DIAGNOSTICS");

    try encoder.writeKey("json");
    try encoder.writeRaw(json_payload);

    try encoder.endObject(); // result
    try encoder.endObject(); // root

    try buf.append(allocator, '\n');
    return buf.toOwnedSlice(allocator);
}

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-007; FEATURE="JSON Library Migration"; ASPECT=CdcControlFrame; STATUS=TESTED; OWNER=protocol; UPDATED=2026-01-24
pub fn buildCdcControlLine(allocator: std.mem.Allocator, action: []const u8, status: []const u8, epoch: u64) ![]u8 {
    const response = CdcControlResponse{
        .result = .{
            .action = action,
            .status = status,
            .guardrail_epoch = epoch,
        },
    };

    const json_str = try json_lib.encode(allocator, response, .{});
    defer allocator.free(json_str);

    // Append newline for wire protocol
    const result = try allocator.alloc(u8, json_str.len + 1);
    @memcpy(result[0..json_str.len], json_str);
    result[json_str.len] = '\n';
    return result;
}

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-008; FEATURE="JSON Library Migration"; ASPECT=ErrorFrame; STATUS=TESTED; OWNER=protocol; UPDATED=2026-01-24
pub fn buildErrorLine(allocator: std.mem.Allocator, code: []const u8, message: []const u8, anchor: []const u8) ![]u8 {
    const response = ErrorResponse{
        .status_class = "02000",
        .status_subclass = code,
        .result = .{
            .code = code,
            .message = message,
            .anchor = anchor,
        },
    };

    const json_str = try json_lib.encode(allocator, response, .{});
    defer allocator.free(json_str);

    // Append newline for wire protocol
    const result = try allocator.alloc(u8, json_str.len + 1);
    @memcpy(result[0..json_str.len], json_str);
    result[json_str.len] = '\n';
    return result;
}

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-009; FEATURE="JSON Library Migration"; ASPECT=ErrorFrameWithFlags; STATUS=TESTED; OWNER=protocol; UPDATED=2026-01-24
pub fn buildErrorLineWithFlags(allocator: std.mem.Allocator, code: []const u8, message: []const u8, anchor: []const u8, additional: []const []const u8, flags: []const []const u8) ![]u8 {
    const response = ErrorResponse{
        .status_class = "02000",
        .status_subclass = code,
        .result = .{
            .code = code,
            .message = message,
            .anchor = anchor,
            .additional_statuses = if (additional.len > 0) additional else null,
            .flagger_findings = if (flags.len > 0) flags else null,
        },
    };

    const json_str = try json_lib.encode(allocator, response, .{});
    defer allocator.free(json_str);

    // Append newline for wire protocol
    const result = try allocator.alloc(u8, json_str.len + 1);
    @memcpy(result[0..json_str.len], json_str);
    result[json_str.len] = '\n';
    return result;
}

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-010; FEATURE="JSON Library Migration"; ASPECT=ErrorFrameCustomStatus; STATUS=TESTED; OWNER=protocol; UPDATED=2026-01-24
pub fn buildErrorLineWithFlagsCustomStatus(allocator: std.mem.Allocator, code: []const u8, message: []const u8, anchor: []const u8, additional: []const []const u8, flags: []const []const u8, status_override: ?[]const u8) ![]u8 {
    const status_class = status_override orelse "02000";

    const response = ErrorResponse{
        .status_class = status_class,
        .status_subclass = code,
        .result = .{
            .code = code,
            .message = message,
            .anchor = anchor,
            .additional_statuses = if (additional.len > 0) additional else null,
            .flagger_findings = if (flags.len > 0) flags else null,
        },
    };

    const json_str = try json_lib.encode(allocator, response, .{});
    defer allocator.free(json_str);

    // Append newline for wire protocol
    const result = try allocator.alloc(u8, json_str.len + 1);
    @memcpy(result[0..json_str.len], json_str);
    result[json_str.len] = '\n';
    return result;
}

pub fn parseClientMessage(allocator: std.mem.Allocator, line: []const u8) !ClientMessage {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) {
        return error.Invalid;
    }
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
        const cn = try allocator.dupe(u8, cnv.string);
        const cv = try allocator.dupe(u8, cvv.string);
        const wc = try allocator.dupe(u8, wcv.string);

        // Extract optional authentication fields
        var username: ?[]const u8 = null;
        var password: ?[]const u8 = null;
        var tenant_id: ?[]const u8 = null;
        if (obj.get("username")) |unv| {
            if (unv == .string) {
                username = try allocator.dupe(u8, unv.string);
            }
        }
        if (obj.get("password")) |pwv| {
            if (pwv == .string) {
                password = try allocator.dupe(u8, pwv.string);
            }
        }
        // CANARY: REQ=REQ-MULTI-TENANT-004; FEATURE="Multi-Tenancy Protocol"; ASPECT=HelloParsing; STATUS=TESTED; TEST=geodetestlab/specs/gql_session_management_comprehensive.yml; OWNER=protocol; UPDATED=2026-01-09
        if (obj.get("tenant_id")) |tid| {
            if (tid == .string) {
                tenant_id = try allocator.dupe(u8, tid.string);
            }
        }

        return .{ .HELLO = .{ .client_name = cn, .client_ver = cv, .wanted_conformance = wc, .username = username, .password = password, .tenant_id = tenant_id } };
    } else if (std.mem.eql(u8, typ, "RUN_GQL")) {
        const txtv = obj.get("text") orelse return error.Invalid;
        if (txtv != .string) return error.Invalid;
        // Duplicate text to avoid use-after-free of parsed JSON buffer
        const txt = try allocator.dupe(u8, txtv.string);
        const params_val = obj.get("params");
        var params_json: ?[]const u8 = null;
        if (params_val) |pv| {
            // Allocate JSON string for params that outlives the parser
            params_json = std.fmt.allocPrint(allocator, "{any}", .{std.json.fmt(pv, .{})}) catch {
                return error.OutOfMemory;
            };
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
        const name = try allocator.dupe(u8, nv.string);
        return .{ .SAVEPOINT = .{ .name = name } };
    } else if (std.mem.eql(u8, typ, "ROLLBACK_TO")) {
        const nv = obj.get("name") orelse return error.Invalid;
        if (nv != .string) return error.Invalid;
        const name = try allocator.dupe(u8, nv.string);
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
            const act = try allocator.dupe(u8, aval.string);
            return .{ .CDC_CONTROL = .{ .action = act } };
        } else {
            const empty = try allocator.dupe(u8, "");
            return .{ .CDC_CONTROL = .{ .action = empty } };
        }
    } else if (std.mem.eql(u8, typ, "BACKUP")) {
        const btv = obj.get("backup_type") orelse return error.Invalid;
        if (btv != .string) return error.Invalid;
        const backup_type = try allocator.dupe(u8, btv.string);

        const parent_id = if (obj.get("parent_id")) |pv| blk: {
            if (pv != .string) return error.Invalid;
            break :blk try allocator.dupe(u8, pv.string);
        } else null;

        const compress = if (obj.get("compress")) |cv|
            cv == .bool and cv.bool
        else
            false;

        return .{ .BACKUP = .{ .backup_type = backup_type, .parent_id = parent_id, .compress = compress } };
    } else if (std.mem.eql(u8, typ, "RESTORE")) {
        const target_time = if (obj.get("target_time")) |tv| blk: {
            if (tv != .string) return error.Invalid;
            break :blk try allocator.dupe(u8, tv.string);
        } else null;

        const confirm = if (obj.get("confirm")) |cv|
            cv == .bool and cv.bool
        else
            false;

        return .{ .RESTORE = .{ .target_time = target_time, .confirm = confirm } };
    } else if (std.mem.eql(u8, typ, "UPLOAD_BACKUP")) {
        const sbv = obj.get("size_bytes") orelse return error.Invalid;
        const csv = obj.get("checksum") orelse return error.Invalid;
        if (sbv != .integer or csv != .string) return error.Invalid;

        const size_bytes = @as(u64, @intCast(sbv.integer));
        const checksum = try allocator.dupe(u8, csv.string);

        return .{ .UPLOAD_BACKUP = .{ .size_bytes = size_bytes, .checksum = checksum } };
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
        // First-class types
        .IpAddr => |ip| {
            try writer.writeAll("\"");
            switch (ip) {
                .v4 => |octets| try std.fmt.format(writer, "{}.{}.{}.{}", .{ octets[0], octets[1], octets[2], octets[3] }),
                .v6 => |bytes| {
                    // RFC 5952 canonical representation
                    var words: [8]u16 = undefined;
                    for (0..8) |i| {
                        words[i] = (@as(u16, bytes[i * 2]) << 8) | bytes[i * 2 + 1];
                    }
                    // Find longest run of zeros for compression
                    var max_start: usize = 0;
                    var max_len: usize = 0;
                    var curr_start: usize = 0;
                    var curr_len: usize = 0;
                    var in_zeros = false;
                    for (words, 0..) |word, i| {
                        if (word == 0) {
                            if (!in_zeros) {
                                curr_start = i;
                                curr_len = 1;
                                in_zeros = true;
                            } else {
                                curr_len += 1;
                            }
                        } else {
                            if (in_zeros and curr_len > max_len) {
                                max_start = curr_start;
                                max_len = curr_len;
                            }
                            in_zeros = false;
                        }
                    }
                    if (in_zeros and curr_len > max_len) {
                        max_start = curr_start;
                        max_len = curr_len;
                    }
                    // Format with compression
                    if (max_len > 1) {
                        for (0..max_start) |i| {
                            if (i > 0) try writer.writeByte(':');
                            try std.fmt.format(writer, "{x}", .{words[i]});
                        }
                        try writer.writeAll("::");
                        for ((max_start + max_len)..8) |i| {
                            if (i > max_start + max_len) try writer.writeByte(':');
                            try std.fmt.format(writer, "{x}", .{words[i]});
                        }
                    } else {
                        for (words, 0..) |word, i| {
                            if (i > 0) try writer.writeByte(':');
                            try std.fmt.format(writer, "{x}", .{word});
                        }
                    }
                },
            }
            try writer.writeAll("\"");
        },
        .Subnet => |subnet| {
            try writer.writeAll("\"");
            switch (subnet.addr) {
                .v4 => |octets| try std.fmt.format(writer, "{}.{}.{}.{}/{}", .{ octets[0], octets[1], octets[2], octets[3], subnet.prefix_len }),
                .v6 => |bytes| {
                    // Format IPv6 address part using same logic as above
                    var words: [8]u16 = undefined;
                    for (0..8) |i| {
                        words[i] = (@as(u16, bytes[i * 2]) << 8) | bytes[i * 2 + 1];
                    }
                    // Find longest run of zeros for compression
                    var max_start: usize = 0;
                    var max_len: usize = 0;
                    var curr_start: usize = 0;
                    var curr_len: usize = 0;
                    var in_zeros = false;
                    for (words, 0..) |word, i| {
                        if (word == 0) {
                            if (!in_zeros) {
                                curr_start = i;
                                curr_len = 1;
                                in_zeros = true;
                            } else {
                                curr_len += 1;
                            }
                        } else {
                            if (in_zeros and curr_len > max_len) {
                                max_start = curr_start;
                                max_len = curr_len;
                            }
                            in_zeros = false;
                        }
                    }
                    if (in_zeros and curr_len > max_len) {
                        max_start = curr_start;
                        max_len = curr_len;
                    }
                    // Format with compression
                    if (max_len > 1) {
                        for (0..max_start) |i| {
                            if (i > 0) try writer.writeByte(':');
                            try std.fmt.format(writer, "{x}", .{words[i]});
                        }
                        try writer.writeAll("::");
                        for ((max_start + max_len)..8) |i| {
                            if (i > max_start + max_len) try writer.writeByte(':');
                            try std.fmt.format(writer, "{x}", .{words[i]});
                        }
                    } else {
                        for (words, 0..) |word, i| {
                            if (i > 0) try writer.writeByte(':');
                            try std.fmt.format(writer, "{x}", .{word});
                        }
                    }
                    try std.fmt.format(writer, "/{}", .{subnet.prefix_len});
                },
            }
            try writer.writeAll("\"");
        },
        .Mac => |mac| {
            try std.fmt.format(writer, "\"{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}\"", .{ mac.bytes[0], mac.bytes[1], mac.bytes[2], mac.bytes[3], mac.bytes[4], mac.bytes[5] });
        },
        .Hash => |hash| {
            try writer.writeAll("\"");
            const alg_name = switch (hash.alg) {
                .SHA3_256 => "SHA3-256",
                .SHA3_512 => "SHA3-512",
                .BLAKE3 => "BLAKE3",
                .BLAKE2B_256 => "BLAKE2b-256",
                .BLAKE2B_512 => "BLAKE2b-512",
                .BLAKE2S_256 => "BLAKE2s-256",
                .ARGON2ID => "Argon2id",
            };
            try writer.writeAll(alg_name);
            try writer.writeAll(":");
            for (hash.digest) |byte| {
                try std.fmt.format(writer, "{x:0>2}", .{byte});
            }
            // For Argon2, also include salt and params if present
            if (hash.salt) |salt| {
                try writer.writeAll("$salt:");
                for (salt) |byte| {
                    try std.fmt.format(writer, "{x:0>2}", .{byte});
                }
            }
            if (hash.params) |params| {
                try std.fmt.format(writer, "$t:{d}$m:{d}$p:{d}", .{
                    params.iterations,
                    params.memory_kb,
                    params.parallelism,
                });
            }
            try writer.writeAll("\"");
        },
        .Currency => |cur| {
            try std.fmt.format(writer, "\"{}{}{}\"", .{ cur.code[0], cur.code[1], cur.code[2] });
        },
        .LanguageTag => |lang| {
            try std.fmt.format(writer, "\"{s}\"", .{lang.tag});
        },
        .LatLon => |ll| {
            try std.fmt.format(writer, "{{\"lat\":{d},\"lon\":{d}}}", .{ ll.lat, ll.lon });
        },
        .LatLonAlt => |lla| {
            const ref_str = switch (lla.ref) {
                .ellipsoid => "ellipsoid",
                .geoid => "geoid",
            };
            try std.fmt.format(writer, "{{\"lat\":{d},\"lon\":{d},\"alt\":{d},\"ref\":\"{s}\"}}", .{ lla.lat, lla.lon, lla.alt, ref_str });
        },
        .Geometry => |geom| {
            // Assume WKB is stored and we output as GeoJSON
            // For simplicity, output the raw WKB as hex for now
            try writer.writeAll("\"WKB:");
            for (geom.wkb) |byte| {
                try std.fmt.format(writer, "{x:0>2}", .{byte});
            }
            try writer.writeAll("\"");
        },
        .Temperature => |temp| {
            const unit_str = switch (temp.unit_in) {
                .K => "K",
                .C => "C",
                .F => "F",
            };
            try std.fmt.format(writer, "{{\"value\":{d},\"unit\":\"{s}\"}}", .{ temp.value_K, unit_str });
        },
        .Pressure => |press| {
            const unit_str = switch (press.unit_in) {
                .Pa => "Pa",
                .kPa => "kPa",
                .bar => "bar",
                .atm => "atm",
            };
            try std.fmt.format(writer, "{{\"value\":{d},\"unit\":\"{s}\"}}", .{ press.value_Pa, unit_str });
        },
        .VectorF32 => |vec| {
            try writer.writeAll("[");
            for (vec.data, 0..) |val, i| {
                if (i > 0) try writer.writeAll(",");
                try std.fmt.format(writer, "{d}", .{val});
            }
            try writer.writeAll("]");
        },
    }
}

// ============================================================================
// JSON LIBRARY MIGRATION TESTS
// ============================================================================

test "TestCANARY_REQ_LIB_MIGRATION_JSON_002_SchemaLineFormat" {
    const cols = [_]SchemaCol{
        .{ .name = "id", .type = "INT" },
        .{ .name = "name", .type = "STRING" },
    };
    const line = try buildSchemaLine(std.testing.allocator, &cols, &.{}, &.{});
    defer std.testing.allocator.free(line);

    // Verify it's valid JSON by parsing it
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line[0 .. line.len - 1], .{});
    defer parsed.deinit();

    // Check structure
    try std.testing.expectEqualStrings("00000", parsed.value.object.get("status_class").?.string);
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("SCHEMA", result.get("type").?.string);
    try std.testing.expectEqual(@as(usize, 2), result.get("columns").?.array.items.len);
}

test "TestCANARY_REQ_LIB_MIGRATION_JSON_003_BindingsLineFormat" {
    const order_keys = [_][]const u8{"col1"};
    const line = try buildBindingsLine(std.testing.allocator, true, &order_keys, "[{\"x\":1}]", true, &.{}, &.{});
    defer std.testing.allocator.free(line);

    // Verify it's valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line[0 .. line.len - 1], .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("00000", parsed.value.object.get("status_class").?.string);
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("BINDINGS", result.get("type").?.string);
    try std.testing.expect(result.get("ordered").?.bool);
    try std.testing.expect(result.get("final").?.bool);
    try std.testing.expectEqual(@as(usize, 1), result.get("rows").?.array.items.len);
}

test "TestCANARY_REQ_LIB_MIGRATION_JSON_007_CdcControlLineFormat" {
    const line = try buildCdcControlLine(std.testing.allocator, "reset", "success", 12345);
    defer std.testing.allocator.free(line);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line[0 .. line.len - 1], .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("CDC_CONTROL", result.get("type").?.string);
    try std.testing.expectEqualStrings("reset", result.get("action").?.string);
    try std.testing.expectEqualStrings("success", result.get("status").?.string);
    try std.testing.expectEqual(@as(i64, 12345), result.get("guardrail_epoch").?.integer);
}

test "TestCANARY_REQ_LIB_MIGRATION_JSON_008_ErrorLineFormat" {
    const line = try buildErrorLine(std.testing.allocator, "42000", "Syntax error", "line 1");
    defer std.testing.allocator.free(line);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line[0 .. line.len - 1], .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("02000", parsed.value.object.get("status_class").?.string);
    try std.testing.expectEqualStrings("42000", parsed.value.object.get("status_subclass").?.string);

    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("ERROR", result.get("type").?.string);
    try std.testing.expectEqualStrings("42000", result.get("code").?.string);
    try std.testing.expectEqualStrings("Syntax error", result.get("message").?.string);
    try std.testing.expectEqualStrings("line 1", result.get("anchor").?.string);
}

test "TestCANARY_REQ_LIB_MIGRATION_JSON_009_ErrorLineWithFlagsFormat" {
    const additional = [_][]const u8{"01000"};
    const flags = [_][]const u8{"I:TestFlag"};
    const line = try buildErrorLineWithFlags(std.testing.allocator, "42000", "Test error", "pos:0", &additional, &flags);
    defer std.testing.allocator.free(line);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line[0 .. line.len - 1], .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(@as(usize, 1), result.get("additional_statuses").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.get("flagger_findings").?.array.items.len);
}
