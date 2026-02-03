const std = @import("std");
const protobuf = @import("protobuf");

const fd = protobuf.fd;

// ============================================================================
// Enums
// ============================================================================
pub const IntKind = enum(i32) {
    INT_KIND_UNSPECIFIED = 0,
    INT = 1,
    SMALLINT = 2,
    BIGINT = 3,
};

pub const FloatKind = enum(i32) {
    FLOAT_KIND_UNSPECIFIED = 0,
    DOUBLE = 1,
    REAL = 2,
};

pub const StringKind = enum(i32) {
    STRING_KIND_UNSPECIFIED = 0,
    STRING = 1,
    CHAR = 2,
    VARCHAR = 3,
    TEXT = 4,
};

pub const BytesKind = enum(i32) {
    BYTES_KIND_UNSPECIFIED = 0,
    BYTEA = 1,
    RAW = 2,
};

// ============================================================================
// Authentication (HELLO)
// ============================================================================
pub const HelloRequest = struct {
    username: []const u8 = "",
    password: []const u8 = "",
    tenant_id: ?[]const u8 = null,
    client_name: []const u8 = "",
    client_version: []const u8 = "",
    wanted_conformance: []const u8 = "",

    pub const _desc_table = .{
        .username = fd(1, .{ .scalar = .string }),
        .password = fd(2, .{ .scalar = .string }),
        .tenant_id = fd(3, .{ .scalar = .string }),
        .client_name = fd(4, .{ .scalar = .string }),
        .client_version = fd(5, .{ .scalar = .string }),
        .wanted_conformance = fd(6, .{ .scalar = .string }),
    };

    pub fn deinit(self: *HelloRequest, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const HelloResponse = struct {
    success: bool = false,
    session_id: []const u8 = "",
    error_message: []const u8 = "",
    capabilities: std.ArrayList([]const u8),

    pub const _desc_table = .{
        .success = fd(1, .{ .scalar = .bool }),
        .session_id = fd(2, .{ .scalar = .string }),
        .error_message = fd(3, .{ .scalar = .string }),
        .capabilities = fd(4, .{ .repeated = .{ .scalar = .string } }),
    };

    pub fn deinit(self: *HelloResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

// ============================================================================
// Query Execution (RUN_GQL + PULL)
// ============================================================================
pub const ExecuteRequest = struct {
    session_id: []const u8 = "",
    query: []const u8 = "",
    params_json: []const u8 = "",

    pub const _desc_table = .{
        .session_id = fd(1, .{ .scalar = .string }),
        .query = fd(2, .{ .scalar = .string }),
        .params_json = fd(3, .{ .scalar = .string }),
    };

    pub fn deinit(self: *ExecuteRequest, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const PullRequest = struct {
    request_id: u64 = 0,
    page_size: u32 = 0,

    pub const _desc_table = .{
        .request_id = fd(1, .{ .scalar = .uint64 }),
        .page_size = fd(2, .{ .scalar = .uint32 }),
    };

    pub fn deinit(self: *PullRequest, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const PullResponse = struct {
    response: ?ExecutionResponse = null,

    pub const _desc_table = .{
        .response = fd(1, .{ .submessage = {} }),
    };

    pub fn deinit(self: *PullResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

// ============================================================================
// Execution Responses
// ============================================================================
pub const Status = struct {
    status_class: []const u8 = "",
    status_subclass: []const u8 = "",
    additional_statuses: std.ArrayList([]const u8),
    flagger_findings: std.ArrayList([]const u8),

    pub const _desc_table = .{
        .status_class = fd(1, .{ .scalar = .string }),
        .status_subclass = fd(2, .{ .scalar = .string }),
        .additional_statuses = fd(3, .{ .repeated = .{ .scalar = .string } }),
        .flagger_findings = fd(4, .{ .repeated = .{ .scalar = .string } }),
    };

    pub fn deinit(self: *Status, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ExecutionResponse = struct {
    status: ?Status = null,
    payload: ?ExecutionResponseUnion = null,

    pub const _desc_table = .{
        .status = fd(1, .{ .submessage = {} }),
        .payload = fd(null, .{ .oneof = ExecutionResponseUnion }),
    };

    pub fn deinit(self: *ExecutionResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ExecutionResponseUnion = union(enum) {
    schema: SchemaDefinition,
    page: DataPage,
    @"error": Error,
    metrics: ExecutionMetrics,
    explain: ExplainPayload,
    profile: ProfilePayload,
    heartbeat: Heartbeat,

    pub const _desc_table = .{
        .schema = fd(2, .{ .submessage = {} }),
        .page = fd(3, .{ .submessage = {} }),
        .@"error" = fd(4, .{ .submessage = {} }),
        .metrics = fd(5, .{ .submessage = {} }),
        .explain = fd(6, .{ .submessage = {} }),
        .profile = fd(7, .{ .submessage = {} }),
        .heartbeat = fd(8, .{ .submessage = {} }),
    };
};

pub const SchemaDefinition = struct {
    columns: std.ArrayList(ColumnDefinition),

    pub const _desc_table = .{
        .columns = fd(1, .{ .repeated = .{ .submessage = {} } }),
    };

    pub fn deinit(self: *SchemaDefinition, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ColumnDefinition = struct {
    name: []const u8 = "",
    type: []const u8 = "",

    pub const _desc_table = .{
        .name = fd(1, .{ .scalar = .string }),
        .type = fd(2, .{ .scalar = .string }),
    };

    pub fn deinit(self: *ColumnDefinition, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const DataPage = struct {
    rows: std.ArrayList(Row),
    final: bool = false,
    ordered: bool = false,
    order_keys: std.ArrayList([]const u8),

    pub const _desc_table = .{
        .rows = fd(1, .{ .repeated = .{ .submessage = {} } }),
        .final = fd(2, .{ .scalar = .bool }),
        .ordered = fd(3, .{ .scalar = .bool }),
        .order_keys = fd(4, .{ .repeated = .{ .scalar = .string } }),
    };

    pub fn deinit(self: *DataPage, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const Row = struct {
    values: std.ArrayList(Value),

    pub const _desc_table = .{
        .values = fd(1, .{ .repeated = .{ .submessage = {} } }),
    };

    pub fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

// ----------------------------------------------------------------------------
// Value Encoding
// ----------------------------------------------------------------------------
pub const NullValue = struct {
    pub const _desc_table = .{};
    pub fn deinit(self: *NullValue, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const IntValue = struct {
    value: i64 = 0,
    kind: IntKind = .INT_KIND_UNSPECIFIED,

    pub const _desc_table = .{
        .value = fd(1, .{ .scalar = .int64 }),
        .kind = fd(2, .{ .@"enum" = {} }),
    };

    pub fn deinit(self: *IntValue, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const DoubleValue = struct {
    value: f64 = 0,
    kind: FloatKind = .FLOAT_KIND_UNSPECIFIED,

    pub const _desc_table = .{
        .value = fd(1, .{ .scalar = .double }),
        .kind = fd(2, .{ .@"enum" = {} }),
    };

    pub fn deinit(self: *DoubleValue, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const StringValue = struct {
    value: []const u8 = "",
    kind: StringKind = .STRING_KIND_UNSPECIFIED,

    pub const _desc_table = .{
        .value = fd(1, .{ .scalar = .string }),
        .kind = fd(2, .{ .@"enum" = {} }),
    };

    pub fn deinit(self: *StringValue, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const DecimalValue = struct {
    coeff: []const u8 = "",
    scale: u32 = 0,
    orig_scale: u32 = 0,
    orig_repr: []const u8 = "",

    pub const _desc_table = .{
        .coeff = fd(1, .{ .scalar = .string }),
        .scale = fd(2, .{ .scalar = .uint32 }),
        .orig_scale = fd(3, .{ .scalar = .uint32 }),
        .orig_repr = fd(4, .{ .scalar = .string }),
    };

    pub fn deinit(self: *DecimalValue, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const BytesValue = struct {
    value: []const u8 = "",
    kind: BytesKind = .BYTES_KIND_UNSPECIFIED,

    pub const _desc_table = .{
        .value = fd(1, .{ .scalar = .bytes }),
        .kind = fd(2, .{ .@"enum" = {} }),
    };

    pub fn deinit(self: *BytesValue, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ListValue = struct {
    values: std.ArrayList(Value),

    pub const _desc_table = .{
        .values = fd(1, .{ .repeated = .{ .submessage = {} } }),
    };

    pub fn deinit(self: *ListValue, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const MapEntry = struct {
    key: []const u8 = "",
    value: ?Value = null,

    pub const _desc_table = .{
        .key = fd(1, .{ .scalar = .string }),
        .value = fd(2, .{ .submessage = {} }),
    };

    pub fn deinit(self: *MapEntry, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const MapValue = struct {
    entries: std.ArrayList(MapEntry),

    pub const _desc_table = .{
        .entries = fd(1, .{ .repeated = .{ .submessage = {} } }),
    };

    pub fn deinit(self: *MapValue, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const NodeValue = struct {
    id: u64 = 0,
    labels: std.ArrayList([]const u8),
    properties: std.ArrayList(MapEntry),

    pub const _desc_table = .{
        .id = fd(1, .{ .scalar = .uint64 }),
        .labels = fd(2, .{ .repeated = .{ .scalar = .string } }),
        .properties = fd(3, .{ .repeated = .{ .submessage = {} } }),
    };

    pub fn deinit(self: *NodeValue, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const EdgeValue = struct {
    id: u64 = 0,
    from_id: u64 = 0,
    to_id: u64 = 0,
    label: []const u8 = "",
    properties: std.ArrayList(MapEntry),

    pub const _desc_table = .{
        .id = fd(1, .{ .scalar = .uint64 }),
        .from_id = fd(2, .{ .scalar = .uint64 }),
        .to_id = fd(3, .{ .scalar = .uint64 }),
        .label = fd(4, .{ .scalar = .string }),
        .properties = fd(5, .{ .repeated = .{ .submessage = {} } }),
    };

    pub fn deinit(self: *EdgeValue, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const PathValue = struct {
    nodes: std.ArrayList(NodeValue),
    edges: std.ArrayList(EdgeValue),

    pub const _desc_table = .{
        .nodes = fd(1, .{ .repeated = .{ .submessage = {} } }),
        .edges = fd(2, .{ .repeated = .{ .submessage = {} } }),
    };

    pub fn deinit(self: *PathValue, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ExtendedValue = struct {
    type_name: []const u8 = "",
    data: ?ExtendedValueUnion,

    pub const _desc_table = .{
        .type_name = fd(1, .{ .scalar = .string }),
        .data = fd(null, .{ .oneof = ExtendedValueUnion }),
    };

    pub fn deinit(self: *ExtendedValue, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ExtendedValueUnion = union(enum) {
    text: []const u8,
    bytes: []const u8,
    int_val: i64,
    double_val: f64,
    bool_val: bool,

    pub const _desc_table = .{
        .text = fd(2, .{ .scalar = .string }),
        .bytes = fd(3, .{ .scalar = .bytes }),
        .int_val = fd(4, .{ .scalar = .int64 }),
        .double_val = fd(5, .{ .scalar = .double }),
        .bool_val = fd(6, .{ .scalar = .bool }),
    };
};

pub const Value = struct {
    kind: ?ValueKind = null,

    pub const _desc_table = .{
        .kind = fd(null, .{ .oneof = ValueKind }),
    };

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ValueKind = union(enum) {
    null_val: NullValue,
    int_val: IntValue,
    double_val: DoubleValue,
    bool_val: bool,
    string_val: StringValue,
    decimal_val: DecimalValue,
    bytes_val: BytesValue,
    list_val: ListValue,
    map_val: MapValue,
    node_val: NodeValue,
    edge_val: EdgeValue,
    path_val: PathValue,
    ext_val: ExtendedValue,

    pub const _desc_table = .{
        .null_val = fd(1, .{ .submessage = {} }),
        .int_val = fd(2, .{ .submessage = {} }),
        .double_val = fd(3, .{ .submessage = {} }),
        .bool_val = fd(4, .{ .scalar = .bool }),
        .string_val = fd(5, .{ .submessage = {} }),
        .decimal_val = fd(6, .{ .submessage = {} }),
        .bytes_val = fd(7, .{ .submessage = {} }),
        .list_val = fd(8, .{ .submessage = {} }),
        .map_val = fd(9, .{ .submessage = {} }),
        .node_val = fd(10, .{ .submessage = {} }),
        .edge_val = fd(11, .{ .submessage = {} }),
        .path_val = fd(12, .{ .submessage = {} }),
        .ext_val = fd(13, .{ .submessage = {} }),
    };
};

pub const Error = struct {
    code: []const u8 = "",
    message: []const u8 = "",
    type: []const u8 = "ERROR",
    anchor: []const u8 = "",

    pub const _desc_table = .{
        .code = fd(1, .{ .scalar = .string }),
        .message = fd(2, .{ .scalar = .string }),
        .type = fd(3, .{ .scalar = .string }),
        .anchor = fd(4, .{ .scalar = .string }),
    };

    pub fn deinit(self: *Error, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ExecutionMetrics = struct {
    parse_duration_ns: i64 = 0,
    plan_duration_ns: i64 = 0,
    execute_duration_ns: i64 = 0,
    total_duration_ns: i64 = 0,

    pub const _desc_table = .{
        .parse_duration_ns = fd(1, .{ .scalar = .int64 }),
        .plan_duration_ns = fd(2, .{ .scalar = .int64 }),
        .execute_duration_ns = fd(3, .{ .scalar = .int64 }),
        .total_duration_ns = fd(4, .{ .scalar = .int64 }),
    };

    pub fn deinit(self: *ExecutionMetrics, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ExplainPayload = struct {
    json_payload: []const u8 = "",

    pub const _desc_table = .{
        .json_payload = fd(1, .{ .scalar = .string }),
    };

    pub fn deinit(self: *ExplainPayload, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ProfilePayload = struct {
    json_payload: []const u8 = "",

    pub const _desc_table = .{
        .json_payload = fd(1, .{ .scalar = .string }),
    };

    pub fn deinit(self: *ProfilePayload, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const Heartbeat = struct {
    pub const _desc_table = .{};
    pub fn deinit(self: *Heartbeat, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

// ============================================================================
// Utilities (PING)
// ============================================================================
pub const PingRequest = struct {
    pub const _desc_table = .{};
    pub fn deinit(self: *PingRequest, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const PingResponse = struct {
    ok: bool = false,

    pub const _desc_table = .{
        .ok = fd(1, .{ .scalar = .bool }),
    };

    pub fn deinit(self: *PingResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

// ============================================================================
// Transactions
// ============================================================================
pub const BeginRequest = struct {
    read_only: bool = false,

    pub const _desc_table = .{
        .read_only = fd(1, .{ .scalar = .bool }),
    };

    pub fn deinit(self: *BeginRequest, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const BeginResponse = struct {
    session_id: []const u8 = "",
    tx_id: []const u8 = "",

    pub const _desc_table = .{
        .session_id = fd(1, .{ .scalar = .string }),
        .tx_id = fd(2, .{ .scalar = .string }),
    };

    pub fn deinit(self: *BeginResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const CommitRequest = struct {
    pub const _desc_table = .{};
    pub fn deinit(self: *CommitRequest, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const CommitResponse = struct {
    success: bool = false,

    pub const _desc_table = .{
        .success = fd(1, .{ .scalar = .bool }),
    };

    pub fn deinit(self: *CommitResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const RollbackRequest = struct {
    pub const _desc_table = .{};
    pub fn deinit(self: *RollbackRequest, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const RollbackResponse = struct {
    success: bool = false,

    pub const _desc_table = .{
        .success = fd(1, .{ .scalar = .bool }),
    };

    pub fn deinit(self: *RollbackResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const SavepointRequest = struct {
    name: []const u8 = "",

    pub const _desc_table = .{
        .name = fd(1, .{ .scalar = .string }),
    };

    pub fn deinit(self: *SavepointRequest, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const SavepointResponse = struct {
    success: bool = false,

    pub const _desc_table = .{
        .success = fd(1, .{ .scalar = .bool }),
    };

    pub fn deinit(self: *SavepointResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const RollbackToRequest = struct {
    name: []const u8 = "",

    pub const _desc_table = .{
        .name = fd(1, .{ .scalar = .string }),
    };

    pub fn deinit(self: *RollbackToRequest, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const RollbackToResponse = struct {
    success: bool = false,

    pub const _desc_table = .{
        .success = fd(1, .{ .scalar = .bool }),
    };

    pub fn deinit(self: *RollbackToResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

// ============================================================================
// CDC
// ============================================================================
pub const CdcDiagnosticsRequest = struct {
    pub const _desc_table = .{};
    pub fn deinit(self: *CdcDiagnosticsRequest, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const CdcDiagnosticsResponse = struct {
    json_payload: []const u8 = "",

    pub const _desc_table = .{
        .json_payload = fd(1, .{ .scalar = .string }),
    };

    pub fn deinit(self: *CdcDiagnosticsResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const CdcControlRequest = struct {
    action: []const u8 = "",

    pub const _desc_table = .{
        .action = fd(1, .{ .scalar = .string }),
    };

    pub fn deinit(self: *CdcControlRequest, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const CdcControlResponse = struct {
    success: bool = false,
    status: []const u8 = "",
    guardrail_epoch: u64 = 0,

    pub const _desc_table = .{
        .success = fd(1, .{ .scalar = .bool }),
        .status = fd(2, .{ .scalar = .string }),
        .guardrail_epoch = fd(3, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *CdcControlResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

// ============================================================================
// Backup / Restore
// ============================================================================
pub const BackupRequest = struct {
    backup_type: []const u8 = "",
    parent_id: []const u8 = "",
    compress: bool = false,

    pub const _desc_table = .{
        .backup_type = fd(1, .{ .scalar = .string }),
        .parent_id = fd(2, .{ .scalar = .string }),
        .compress = fd(3, .{ .scalar = .bool }),
    };

    pub fn deinit(self: *BackupRequest, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const BackupResponse = struct {
    success: bool = false,
    message: []const u8 = "",
    backup_id: []const u8 = "",
    backup_type: []const u8 = "",
    size_bytes: u64 = 0,
    compression: []const u8 = "",
    checksum: []const u8 = "",
    start_lsn: u64 = 0,
    end_lsn: u64 = 0,

    pub const _desc_table = .{
        .success = fd(1, .{ .scalar = .bool }),
        .message = fd(2, .{ .scalar = .string }),
        .backup_id = fd(3, .{ .scalar = .string }),
        .backup_type = fd(4, .{ .scalar = .string }),
        .size_bytes = fd(5, .{ .scalar = .uint64 }),
        .compression = fd(6, .{ .scalar = .string }),
        .checksum = fd(7, .{ .scalar = .string }),
        .start_lsn = fd(8, .{ .scalar = .uint64 }),
        .end_lsn = fd(9, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *BackupResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const RestoreRequest = struct {
    target_time: []const u8 = "",
    confirm: bool = false,

    pub const _desc_table = .{
        .target_time = fd(1, .{ .scalar = .string }),
        .confirm = fd(2, .{ .scalar = .bool }),
    };

    pub fn deinit(self: *RestoreRequest, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const RestoreResponse = struct {
    success: bool = false,
    message: []const u8 = "",
    restore_dir: []const u8 = "",
    target_time: []const u8 = "",
    restore_timestamp: u64 = 0,

    pub const _desc_table = .{
        .success = fd(1, .{ .scalar = .bool }),
        .message = fd(2, .{ .scalar = .string }),
        .restore_dir = fd(3, .{ .scalar = .string }),
        .target_time = fd(4, .{ .scalar = .string }),
        .restore_timestamp = fd(5, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *RestoreResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const UploadBackupRequest = struct {
    size_bytes: u64 = 0,
    checksum: []const u8 = "",

    pub const _desc_table = .{
        .size_bytes = fd(1, .{ .scalar = .uint64 }),
        .checksum = fd(2, .{ .scalar = .string }),
    };

    pub fn deinit(self: *UploadBackupRequest, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const UploadBackupResponse = struct {
    success: bool = false,
    message: []const u8 = "",
    upload_path: []const u8 = "",

    pub const _desc_table = .{
        .success = fd(1, .{ .scalar = .bool }),
        .message = fd(2, .{ .scalar = .string }),
        .upload_path = fd(3, .{ .scalar = .string }),
    };

    pub fn deinit(self: *UploadBackupResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

// ============================================================================
// Top-Level Messages (Unions)
// ============================================================================
pub const QuicClientMessage = union(enum) {
    hello: HelloRequest,
    execute: ExecuteRequest,
    pull: PullRequest,
    ping: PingRequest,
    cdc_diag: CdcDiagnosticsRequest,
    cdc_ctrl: CdcControlRequest,
    begin: BeginRequest,
    commit: CommitRequest,
    rollback: RollbackRequest,
    savepoint: SavepointRequest,
    rollback_to: RollbackToRequest,
    backup: BackupRequest,
    restore: RestoreRequest,
    upload_backup: UploadBackupRequest,

    pub const _desc_table = .{
        .hello = fd(1, .{ .submessage = {} }),
        .execute = fd(2, .{ .submessage = {} }),
        .pull = fd(3, .{ .submessage = {} }),
        .ping = fd(4, .{ .submessage = {} }),
        .cdc_diag = fd(5, .{ .submessage = {} }),
        .cdc_ctrl = fd(6, .{ .submessage = {} }),
        .begin = fd(7, .{ .submessage = {} }),
        .commit = fd(8, .{ .submessage = {} }),
        .rollback = fd(9, .{ .submessage = {} }),
        .savepoint = fd(10, .{ .submessage = {} }),
        .rollback_to = fd(11, .{ .submessage = {} }),
        .backup = fd(12, .{ .submessage = {} }),
        .restore = fd(13, .{ .submessage = {} }),
        .upload_backup = fd(14, .{ .submessage = {} }),
    };

    pub fn deinit(self: *QuicClientMessage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*case| case.deinit(allocator),
        }
    }
};

pub const QuicServerMessage = union(enum) {
    hello: HelloResponse,
    execute: ExecutionResponse,
    pull: PullResponse,
    ping: PingResponse,
    cdc_diag: CdcDiagnosticsResponse,
    cdc_ctrl: CdcControlResponse,
    begin: BeginResponse,
    commit: CommitResponse,
    rollback: RollbackResponse,
    savepoint: SavepointResponse,
    rollback_to: RollbackToResponse,
    backup: BackupResponse,
    restore: RestoreResponse,
    upload_backup: UploadBackupResponse,

    pub const _desc_table = .{
        .hello = fd(1, .{ .submessage = {} }),
        .execute = fd(2, .{ .submessage = {} }),
        .pull = fd(3, .{ .submessage = {} }),
        .ping = fd(4, .{ .submessage = {} }),
        .cdc_diag = fd(5, .{ .submessage = {} }),
        .cdc_ctrl = fd(6, .{ .submessage = {} }),
        .begin = fd(7, .{ .submessage = {} }),
        .commit = fd(8, .{ .submessage = {} }),
        .rollback = fd(9, .{ .submessage = {} }),
        .savepoint = fd(10, .{ .submessage = {} }),
        .rollback_to = fd(11, .{ .submessage = {} }),
        .backup = fd(12, .{ .submessage = {} }),
        .restore = fd(13, .{ .submessage = {} }),
        .upload_backup = fd(14, .{ .submessage = {} }),
    };

    pub fn deinit(self: *QuicServerMessage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*case| case.deinit(allocator),
        }
    }
};

pub const ClientPacket = struct {
    quic: ?QuicClientMessage = null,

    pub const _desc_table = .{
        .quic = fd(null, .{ .oneof = QuicClientMessage }),
    };

    pub fn deinit(self: *ClientPacket, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ServerPacket = struct {
    quic: ?QuicServerMessage = null,

    pub const _desc_table = .{
        .quic = fd(null, .{ .oneof = QuicServerMessage }),
    };

    pub fn deinit(self: *ServerPacket, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};
