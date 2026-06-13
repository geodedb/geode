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
    graph: ?[]const u8 = null,
    role: ?[]const u8 = null, // FLE role for field-level access control

    pub const _desc_table = .{
        .username = fd(1, .{ .scalar = .string }),
        .password = fd(2, .{ .scalar = .string }),
        .tenant_id = fd(3, .{ .scalar = .string }),
        .client_name = fd(4, .{ .scalar = .string }),
        .client_version = fd(5, .{ .scalar = .string }),
        .wanted_conformance = fd(6, .{ .scalar = .string }),
        .graph = fd(7, .{ .scalar = .string }),
        .role = fd(8, .{ .scalar = .string }),
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
    password_reset_required: bool = false,
    graph: ?[]const u8 = null,

    pub const _desc_table = .{
        .success = fd(1, .{ .scalar = .bool }),
        .session_id = fd(2, .{ .scalar = .string }),
        .error_message = fd(3, .{ .scalar = .string }),
        .capabilities = fd(4, .{ .repeated = .{ .scalar = .string } }),
        .password_reset_required = fd(5, .{ .scalar = .bool }),
        .graph = fd(6, .{ .scalar = .string }),
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
    params: std.ArrayList(Param),
    // CANARY: REQ=REQ-GPS-WIRE-001; FEATURE="GPS Wire Principal Forwarding"; ASPECT=ExecuteRequestSchema; STATUS=IMPL; OWNER=security; UPDATED=2026-05-21
    // GPS Phase 7 (Tasks 7-5/7-6): optional serialised principal_envelope blob.
    // Field 4 is reserved for this purpose in both the server-side schema (this
    // file) and the geode-client-zig external library (separate release).
    // When non-null the receiving quic_connection_handler unpacks it via
    // distributed.principal_envelope.deserialize() and overrides the
    // connection-level Principal for that request only.
    // Senders that do not support envelopes simply leave the field null;
    // existing wire frames without field 4 are unchanged (backward-compatible).
    principal_envelope_bytes: ?[]const u8 = null,
    // CANARY: REQ=REQ-DIST-CLUSTER-IDEMPOTENT-RETRY; FEATURE="DistributedCluster"; ASPECT=ExecuteRequestIdempotencyKey; STATUS=TESTED; TEST=tests/test_cluster_write_idempotency.zig; OWNER=distributed; UPDATED=2026-06-12
    // RC-3 ("committed write -> client Timeout -> retry double-insert"): an
    // OPTIONAL client-supplied idempotency key. When a client retries a write
    // after a committed-but-Timeout outcome it resends the SAME key, so the
    // cluster apply path dedups the retry (no duplicate row). Field 5 is additive
    // and backward-compatible: old clients leave it null and the leader generates
    // a per-request key instead (which still dedups internal retries but cannot
    // dedup an EXTERNAL client retry — that needs client adoption of this field).
    // Existing wire frames without field 5 decode unchanged.
    idempotency_key: ?[]const u8 = null,

    pub const _desc_table = .{
        .session_id = fd(1, .{ .scalar = .string }),
        .query = fd(2, .{ .scalar = .string }),
        .params = fd(3, .{ .repeated = .{ .submessage = {} } }),
        .principal_envelope_bytes = fd(4, .{ .scalar = .bytes }),
        .idempotency_key = fd(5, .{ .scalar = .string }),
    };

    pub fn deinit(self: *ExecuteRequest, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const Param = struct {
    name: []const u8 = "",
    value: ?Value = null,

    pub const _desc_table = .{
        .name = fd(1, .{ .scalar = .string }),
        .value = fd(2, .{ .submessage = {} }),
    };

    pub fn deinit(self: *Param, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const PullRequest = struct {
    request_id: u64 = 0,
    page_size: u32 = 0,
    session_id: []const u8 = "",

    pub const _desc_table = .{
        .request_id = fd(1, .{ .scalar = .uint64 }),
        .page_size = fd(2, .{ .scalar = .uint32 }),
        .session_id = fd(3, .{ .scalar = .string }),
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

pub const ExplainOp = struct {
    idx: u32 = 0,
    kind: []const u8 = "",
    est_rows: i64 = 0,
    cost: i64 = 0,

    pub const _desc_table = .{
        .idx = fd(1, .{ .scalar = .uint32 }),
        .kind = fd(2, .{ .scalar = .string }),
        .est_rows = fd(3, .{ .scalar = .int64 }),
        .cost = fd(4, .{ .scalar = .int64 }),
    };

    pub fn deinit(self: *ExplainOp, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ExplainTotals = struct {
    est_rows: i64 = 0,
    cost: i64 = 0,

    pub const _desc_table = .{
        .est_rows = fd(1, .{ .scalar = .int64 }),
        .cost = fd(2, .{ .scalar = .int64 }),
    };

    pub fn deinit(self: *ExplainTotals, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ExplainProperties = struct {
    ordered: bool = false,
    limit: u64 = 0,
    offset: u64 = 0,
    distinct: bool = false,
    union_mode: []const u8 = "",
    union_part_count: u32 = 0,

    pub const _desc_table = .{
        .ordered = fd(1, .{ .scalar = .bool }),
        .limit = fd(2, .{ .scalar = .uint64 }),
        .offset = fd(3, .{ .scalar = .uint64 }),
        .distinct = fd(4, .{ .scalar = .bool }),
        .union_mode = fd(5, .{ .scalar = .string }),
        .union_part_count = fd(6, .{ .scalar = .uint32 }),
    };

    pub fn deinit(self: *ExplainProperties, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ExplainCalibrationEntry = struct {
    idx: u32 = 0,
    est_rows: f64 = 0,
    actual_rows: f64 = 0,

    pub const _desc_table = .{
        .idx = fd(1, .{ .scalar = .uint32 }),
        .est_rows = fd(2, .{ .scalar = .double }),
        .actual_rows = fd(3, .{ .scalar = .double }),
    };

    pub fn deinit(self: *ExplainCalibrationEntry, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ExplainCalibration = struct {
    mape: f64 = 0,
    entries: std.ArrayList(ExplainCalibrationEntry),

    pub const _desc_table = .{
        .mape = fd(1, .{ .scalar = .double }),
        .entries = fd(2, .{ .repeated = .{ .submessage = {} } }),
    };

    pub fn deinit(self: *ExplainCalibration, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ExplainPayload = struct {
    schema: []const u8 = "",
    ops: std.ArrayList(ExplainOp),
    totals: ?ExplainTotals = null,
    properties: ?ExplainProperties = null,
    calibration: ?ExplainCalibration = null,
    profile_version: u32 = 0,

    pub const _desc_table = .{
        .schema = fd(1, .{ .scalar = .string }),
        .ops = fd(2, .{ .repeated = .{ .submessage = {} } }),
        .totals = fd(3, .{ .submessage = {} }),
        .properties = fd(4, .{ .submessage = {} }),
        .calibration = fd(5, .{ .submessage = {} }),
        .profile_version = fd(6, .{ .scalar = .uint32 }),
    };

    pub fn deinit(self: *ExplainPayload, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ProfileOp = struct {
    op: []const u8 = "",
    phase: []const u8 = "",
    id: u32 = 0,
    op_index: u32 = 0,
    input_rows: u64 = 0,
    rows: u64 = 0,
    time_ns: u64 = 0,
    cpu_time_ns: u64 = 0,
    bytes_out: u64 = 0,
    bytes_alloc: u64 = 0,
    estimate_bytes: u64 = 0,
    estimate_vs_actual: u64 = 0,
    percent_peak: u64 = 0,
    percent_net: u64 = 0,
    cumulative_time_ns: u64 = 0,
    freed_bytes: u64 = 0,
    net_after_op: u64 = 0,
    error_bytes: u64 = 0,
    error_abs_pct: u64 = 0,
    index_name: []const u8 = "",
    selectivity_est: f64 = 0,

    pub const _desc_table = .{
        .op = fd(1, .{ .scalar = .string }),
        .phase = fd(2, .{ .scalar = .string }),
        .id = fd(3, .{ .scalar = .uint32 }),
        .op_index = fd(4, .{ .scalar = .uint32 }),
        .input_rows = fd(5, .{ .scalar = .uint64 }),
        .rows = fd(6, .{ .scalar = .uint64 }),
        .time_ns = fd(7, .{ .scalar = .uint64 }),
        .cpu_time_ns = fd(8, .{ .scalar = .uint64 }),
        .bytes_out = fd(9, .{ .scalar = .uint64 }),
        .bytes_alloc = fd(10, .{ .scalar = .uint64 }),
        .estimate_bytes = fd(11, .{ .scalar = .uint64 }),
        .estimate_vs_actual = fd(12, .{ .scalar = .uint64 }),
        .percent_peak = fd(13, .{ .scalar = .uint64 }),
        .percent_net = fd(14, .{ .scalar = .uint64 }),
        .cumulative_time_ns = fd(15, .{ .scalar = .uint64 }),
        .freed_bytes = fd(16, .{ .scalar = .uint64 }),
        .net_after_op = fd(17, .{ .scalar = .uint64 }),
        .error_bytes = fd(18, .{ .scalar = .uint64 }),
        .error_abs_pct = fd(19, .{ .scalar = .uint64 }),
        .index_name = fd(20, .{ .scalar = .string }),
        .selectivity_est = fd(21, .{ .scalar = .double }),
    };

    pub fn deinit(self: *ProfileOp, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ProfilePeakContributor = struct {
    op: []const u8 = "",
    bytes_alloc: u64 = 0,

    pub const _desc_table = .{
        .op = fd(1, .{ .scalar = .string }),
        .bytes_alloc = fd(2, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *ProfilePeakContributor, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ProfileTotals = struct {
    time_ns: u64 = 0,
    peak_bytes: u64 = 0,

    pub const _desc_table = .{
        .time_ns = fd(1, .{ .scalar = .uint64 }),
        .peak_bytes = fd(2, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *ProfileTotals, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ProfileSpills = struct {
    sort_spills: u64 = 0,
    distinct_spills: u64 = 0,
    union_spills: u64 = 0,
    spill_reason: []const u8 = "",
    peak_bytes_at_spill: u64 = 0,
    first_spill_op_index: u32 = 0,

    pub const _desc_table = .{
        .sort_spills = fd(1, .{ .scalar = .uint64 }),
        .distinct_spills = fd(2, .{ .scalar = .uint64 }),
        .union_spills = fd(3, .{ .scalar = .uint64 }),
        .spill_reason = fd(4, .{ .scalar = .string }),
        .peak_bytes_at_spill = fd(5, .{ .scalar = .uint64 }),
        .first_spill_op_index = fd(6, .{ .scalar = .uint32 }),
    };

    pub fn deinit(self: *ProfileSpills, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ProfileMemory = struct {
    net_bytes: u64 = 0,
    peak_bytes: u64 = 0,
    total_alloc_bytes: u64 = 0,

    pub const _desc_table = .{
        .net_bytes = fd(1, .{ .scalar = .uint64 }),
        .peak_bytes = fd(2, .{ .scalar = .uint64 }),
        .total_alloc_bytes = fd(3, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *ProfileMemory, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ProfilePlannerEstimates = struct {
    sum_estimate_bytes: u64 = 0,
    sum_actual_bytes: u64 = 0,
    count_estimated_ops: u32 = 0,
    min_error_abs_pct: f64 = 0,
    max_error_abs_pct: f64 = 0,
    mean_error_abs_pct: f64 = 0,
    median_error_abs_pct: f64 = 0,
    stddev_error_abs_pct: f64 = 0,
    adjusted_estimate_factor: f64 = 0,

    pub const _desc_table = .{
        .sum_estimate_bytes = fd(1, .{ .scalar = .uint64 }),
        .sum_actual_bytes = fd(2, .{ .scalar = .uint64 }),
        .count_estimated_ops = fd(3, .{ .scalar = .uint32 }),
        .min_error_abs_pct = fd(4, .{ .scalar = .double }),
        .max_error_abs_pct = fd(5, .{ .scalar = .double }),
        .mean_error_abs_pct = fd(6, .{ .scalar = .double }),
        .median_error_abs_pct = fd(7, .{ .scalar = .double }),
        .stddev_error_abs_pct = fd(8, .{ .scalar = .double }),
        .adjusted_estimate_factor = fd(9, .{ .scalar = .double }),
    };

    pub fn deinit(self: *ProfilePlannerEstimates, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ProfileMemCurvePoint = struct {
    op_index: u32 = 0,
    net_after_op: u64 = 0,

    pub const _desc_table = .{
        .op_index = fd(1, .{ .scalar = .uint32 }),
        .net_after_op = fd(2, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *ProfileMemCurvePoint, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ProfileSetOp = struct {
    type: []const u8 = "",
    mode: []const u8 = "",
    input_rows: u64 = 0,
    output_rows: u64 = 0,
    hash_dedup_size: u64 = 0,
    distinct_fill_pct: u64 = 0,

    pub const _desc_table = .{
        .type = fd(1, .{ .scalar = .string }),
        .mode = fd(2, .{ .scalar = .string }),
        .input_rows = fd(3, .{ .scalar = .uint64 }),
        .output_rows = fd(4, .{ .scalar = .uint64 }),
        .hash_dedup_size = fd(5, .{ .scalar = .uint64 }),
        .distinct_fill_pct = fd(6, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *ProfileSetOp, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ProfilePayload = struct {
    profile_version: u32 = 0,
    ops: std.ArrayList(ProfileOp),
    peak_contributors: std.ArrayList(ProfilePeakContributor),
    totals: ?ProfileTotals = null,
    total_time_ns: u64 = 0,
    spills: ?ProfileSpills = null,
    memory: ?ProfileMemory = null,
    planner_estimates: ?ProfilePlannerEstimates = null,
    mem_curve: std.ArrayList(ProfileMemCurvePoint),
    setop: ?ProfileSetOp = null,
    hashagg_spills: u64 = 0,
    hashagg_spill_reason: []const u8 = "",
    committed_txns: u64 = 0,
    graph_store_nodes: u64 = 0,
    graph_store_edges: u64 = 0,
    graph_store_dirty: bool = false,
    flagger_findings: std.ArrayList([]const u8),
    compact: bool = false,

    pub const _desc_table = .{
        .profile_version = fd(1, .{ .scalar = .uint32 }),
        .ops = fd(2, .{ .repeated = .{ .submessage = {} } }),
        .peak_contributors = fd(3, .{ .repeated = .{ .submessage = {} } }),
        .totals = fd(4, .{ .submessage = {} }),
        .total_time_ns = fd(5, .{ .scalar = .uint64 }),
        .spills = fd(6, .{ .submessage = {} }),
        .memory = fd(7, .{ .submessage = {} }),
        .planner_estimates = fd(8, .{ .submessage = {} }),
        .mem_curve = fd(9, .{ .repeated = .{ .submessage = {} } }),
        .setop = fd(10, .{ .submessage = {} }),
        .hashagg_spills = fd(11, .{ .scalar = .uint64 }),
        .hashagg_spill_reason = fd(12, .{ .scalar = .string }),
        .committed_txns = fd(13, .{ .scalar = .uint64 }),
        .graph_store_nodes = fd(14, .{ .scalar = .uint64 }),
        .graph_store_edges = fd(15, .{ .scalar = .uint64 }),
        .graph_store_dirty = fd(16, .{ .scalar = .bool }),
        .flagger_findings = fd(17, .{ .repeated = .{ .scalar = .string } }),
        .compact = fd(18, .{ .scalar = .bool }),
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
    session_id: []const u8 = "",

    pub const _desc_table = .{
        .read_only = fd(1, .{ .scalar = .bool }),
        .session_id = fd(2, .{ .scalar = .string }),
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
    session_id: []const u8 = "",

    pub const _desc_table = .{
        .session_id = fd(1, .{ .scalar = .string }),
    };
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
    session_id: []const u8 = "",

    pub const _desc_table = .{
        .session_id = fd(1, .{ .scalar = .string }),
    };
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
    session_id: []const u8 = "",

    pub const _desc_table = .{
        .name = fd(1, .{ .scalar = .string }),
        .session_id = fd(2, .{ .scalar = .string }),
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
    session_id: []const u8 = "",

    pub const _desc_table = .{
        .name = fd(1, .{ .scalar = .string }),
        .session_id = fd(2, .{ .scalar = .string }),
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

pub const CdcDiagnosticsConfig = struct {
    enabled: bool = false,
    malformed_snapshot_interval: u64 = 0,
    malformed_hash_retain: u32 = 0,
    malformed_warn_pct: f64 = 0,
    malformed_abort_pct: f64 = 0,
    flush_interval_ms: u32 = 0,
    batch_size: u32 = 0,
    pending_backpressure_watermark: u64 = 0,

    pub const _desc_table = .{
        .enabled = fd(1, .{ .scalar = .bool }),
        .malformed_snapshot_interval = fd(2, .{ .scalar = .uint64 }),
        .malformed_hash_retain = fd(3, .{ .scalar = .uint32 }),
        .malformed_warn_pct = fd(4, .{ .scalar = .double }),
        .malformed_abort_pct = fd(5, .{ .scalar = .double }),
        .flush_interval_ms = fd(6, .{ .scalar = .uint32 }),
        .batch_size = fd(7, .{ .scalar = .uint32 }),
        .pending_backpressure_watermark = fd(8, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *CdcDiagnosticsConfig, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const CdcDiagnosticsEngine = struct {
    is_running: bool = false,
    last_flush_ms: i64 = 0,
    peak_buffer: u64 = 0,
    current_buffer: u64 = 0,
    dynamic_batch_size: u32 = 0,
    batch_adjustments: u32 = 0,

    pub const _desc_table = .{
        .is_running = fd(1, .{ .scalar = .bool }),
        .last_flush_ms = fd(2, .{ .scalar = .int64 }),
        .peak_buffer = fd(3, .{ .scalar = .uint64 }),
        .current_buffer = fd(4, .{ .scalar = .uint64 }),
        .dynamic_batch_size = fd(5, .{ .scalar = .uint32 }),
        .batch_adjustments = fd(6, .{ .scalar = .uint32 }),
    };

    pub fn deinit(self: *CdcDiagnosticsEngine, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const CdcMalformedSnapshot = struct {
    count: u64 = 0,
    ts_ms: i64 = 0,

    pub const _desc_table = .{
        .count = fd(1, .{ .scalar = .uint64 }),
        .ts_ms = fd(2, .{ .scalar = .int64 }),
    };

    pub fn deinit(self: *CdcMalformedSnapshot, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const CdcMalformedHash = struct {
    count: u64 = 0,
    hash: u64 = 0,
    ts_ms: i64 = 0,
    prefix_hex: []const u8 = "",

    pub const _desc_table = .{
        .count = fd(1, .{ .scalar = .uint64 }),
        .hash = fd(2, .{ .scalar = .uint64 }),
        .ts_ms = fd(3, .{ .scalar = .int64 }),
        .prefix_hex = fd(4, .{ .scalar = .string }),
    };

    pub fn deinit(self: *CdcMalformedHash, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const CdcDiagnosticsResponse = struct {
    malformed_change_records: u64 = 0,
    total_change_attempts: u64 = 0,
    malformed_ratio: f64 = 0,
    guardrail_warn_triggered: bool = false,
    guardrail_abort_triggered: bool = false,
    first_warn_ts_ms: i64 = 0,
    first_abort_ts_ms: i64 = 0,
    guardrail_epoch: u64 = 0,
    uptime_ms: i64 = 0,
    backpressure: bool = false,
    config: ?CdcDiagnosticsConfig = null,
    engine: ?CdcDiagnosticsEngine = null,
    malformed_snapshots: std.ArrayList(CdcMalformedSnapshot),
    malformed_hashes: std.ArrayList(CdcMalformedHash),
    version: []const u8 = "",
    timestamp_ms: i64 = 0,

    pub const _desc_table = .{
        .malformed_change_records = fd(1, .{ .scalar = .uint64 }),
        .total_change_attempts = fd(2, .{ .scalar = .uint64 }),
        .malformed_ratio = fd(3, .{ .scalar = .double }),
        .guardrail_warn_triggered = fd(4, .{ .scalar = .bool }),
        .guardrail_abort_triggered = fd(5, .{ .scalar = .bool }),
        .first_warn_ts_ms = fd(6, .{ .scalar = .int64 }),
        .first_abort_ts_ms = fd(7, .{ .scalar = .int64 }),
        .guardrail_epoch = fd(8, .{ .scalar = .uint64 }),
        .uptime_ms = fd(9, .{ .scalar = .int64 }),
        .backpressure = fd(10, .{ .scalar = .bool }),
        .config = fd(11, .{ .submessage = {} }),
        .engine = fd(12, .{ .submessage = {} }),
        .malformed_snapshots = fd(13, .{ .repeated = .{ .submessage = {} } }),
        .malformed_hashes = fd(14, .{ .repeated = .{ .submessage = {} } }),
        .version = fd(15, .{ .scalar = .string }),
        .timestamp_ms = fd(16, .{ .scalar = .int64 }),
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
    session_id: []const u8 = "",
    compress: bool = false,

    pub const _desc_table = .{
        .backup_type = fd(1, .{ .scalar = .string }),
        .session_id = fd(2, .{ .scalar = .string }),
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

    pub const _desc_table = .{
        .success = fd(1, .{ .scalar = .bool }),
        .message = fd(2, .{ .scalar = .string }),
        .backup_id = fd(3, .{ .scalar = .string }),
        .backup_type = fd(4, .{ .scalar = .string }),
        .size_bytes = fd(5, .{ .scalar = .uint64 }),
        .compression = fd(6, .{ .scalar = .string }),
        .checksum = fd(7, .{ .scalar = .string }),
    };

    pub fn deinit(self: *BackupResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const RestoreRequest = struct {
    target_time: []const u8 = "",
    confirm: bool = false,
    session_id: []const u8 = "",

    pub const _desc_table = .{
        .target_time = fd(1, .{ .scalar = .string }),
        .confirm = fd(2, .{ .scalar = .bool }),
        .session_id = fd(3, .{ .scalar = .string }),
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
    session_id: []const u8 = "",
    /// GAP-0880: the complete backup artifact bytes (BackupHeader + payload,
    /// i.e. the exact bytes streamed by a prior BackupResponse). The server
    /// verifies size/checksum and durably registers the backup before
    /// reporting success; a request without payload bytes is rejected —
    /// there is no metadata-only "upload slot" path.
    payload: []const u8 = "",

    pub const _desc_table = .{
        .size_bytes = fd(1, .{ .scalar = .uint64 }),
        .checksum = fd(2, .{ .scalar = .string }),
        .session_id = fd(3, .{ .scalar = .string }),
        .payload = fd(4, .{ .scalar = .bytes }),
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
