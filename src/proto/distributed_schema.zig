const std = @import("std");
const protobuf = @import("protobuf");
const schema = @import("schema");

const fd = protobuf.fd;

// Cluster envelope message types.
pub const ClusterMessageType = enum(i32) {
    CLUSTER_MESSAGE_TYPE_UNSPECIFIED = 0,
    APPEND_ENTRIES = 1,
    APPEND_ENTRIES_RESPONSE = 2,
    REQUEST_VOTE = 3,
    REQUEST_VOTE_RESPONSE = 4,
    INSTALL_SNAPSHOT = 5,
    INSTALL_SNAPSHOT_RESPONSE = 6,
    HEARTBEAT = 7,
    CLIENT_REQUEST = 8,
    CLIENT_RESPONSE = 9,
};

pub const ClusterMessage = struct {
    msg_type: ClusterMessageType = .CLUSTER_MESSAGE_TYPE_UNSPECIFIED,
    source_node: u32 = 0,
    dest_node: u32 = 0,
    term: u64 = 0,
    payload: []const u8 = "",

    pub const _desc_table = .{
        .msg_type = fd(1, .{ .scalar = .@"enum" }),
        .source_node = fd(2, .{ .scalar = .uint32 }),
        .dest_node = fd(3, .{ .scalar = .uint32 }),
        .term = fd(4, .{ .scalar = .uint64 }),
        .payload = fd(5, .{ .scalar = .bytes }),
    };

    pub fn deinit(self: *ClusterMessage, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

// Two-phase commit protocol
pub const TwoPhaseMessageType = enum(i32) {
    TWO_PHASE_MESSAGE_TYPE_UNSPECIFIED = 0,
    PREPARE = 1,
    PREPARE_RESPONSE = 2,
    COMMIT = 3,
    COMMIT_RESPONSE = 4,
    ABORT = 5,
    ABORT_RESPONSE = 6,
    RECOVERY_REQUEST = 7,
    RECOVERY_RESPONSE = 8,
};

pub const TwoPhaseVote = enum(i32) {
    TWO_PHASE_VOTE_UNSPECIFIED = 0,
    VOTE_COMMIT = 1,
    VOTE_ABORT = 2,
    VOTE_TIMEOUT = 3,
};

pub const OperationType = enum(i32) {
    OPERATION_TYPE_UNSPECIFIED = 0,
    CREATE = 1,
    UPDATE = 2,
    DELETE = 3,
};

pub const NodeOperation = struct {
    op_type: OperationType = .OPERATION_TYPE_UNSPECIFIED,
    node_id: u64 = 0,
    label: []const u8 = "",
    graph_name: []const u8 = "",
    properties: std.ArrayList(schema.MapEntry),

    pub const _desc_table = .{
        .op_type = fd(1, .{ .scalar = .@"enum" }),
        .node_id = fd(2, .{ .scalar = .uint64 }),
        .label = fd(3, .{ .scalar = .string }),
        .graph_name = fd(4, .{ .scalar = .string }),
        .properties = fd(5, .{ .repeated = .{ .submessage = {} } }),
    };

    pub fn deinit(self: *NodeOperation, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const EdgeOperation = struct {
    op_type: OperationType = .OPERATION_TYPE_UNSPECIFIED,
    edge_id: u64 = 0,
    source_id: u64 = 0,
    target_id: u64 = 0,
    edge_type: []const u8 = "",
    graph_name: []const u8 = "",
    properties: std.ArrayList(schema.MapEntry),

    pub const _desc_table = .{
        .op_type = fd(1, .{ .scalar = .@"enum" }),
        .edge_id = fd(2, .{ .scalar = .uint64 }),
        .source_id = fd(3, .{ .scalar = .uint64 }),
        .target_id = fd(4, .{ .scalar = .uint64 }),
        .edge_type = fd(5, .{ .scalar = .string }),
        .graph_name = fd(6, .{ .scalar = .string }),
        .properties = fd(7, .{ .repeated = .{ .submessage = {} } }),
    };

    pub fn deinit(self: *EdgeOperation, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const TwoPhaseOperation = union(enum) {
    node_op: NodeOperation,
    edge_op: EdgeOperation,

    pub const _desc_table = .{
        .node_op = fd(1, .{ .submessage = {} }),
        .edge_op = fd(2, .{ .submessage = {} }),
    };

    pub fn deinit(self: *TwoPhaseOperation, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*case| case.deinit(allocator),
        }
    }
};

pub const TwoPhaseMessage = struct {
    msg_type: TwoPhaseMessageType = .TWO_PHASE_MESSAGE_TYPE_UNSPECIFIED,
    transaction_id: []const u8 = "",
    coordinator_id: []const u8 = "",
    timestamp: i64 = 0,
    operations: std.ArrayList(TwoPhaseOperation),
    auth_token: []const u8 = "",
    /// SEC-D009: Cryptographic nonce for replay protection.
    nonce: u64 = 0,

    pub const _desc_table = .{
        .msg_type = fd(1, .{ .scalar = .@"enum" }),
        .transaction_id = fd(2, .{ .scalar = .string }),
        .coordinator_id = fd(3, .{ .scalar = .string }),
        .timestamp = fd(4, .{ .scalar = .int64 }),
        .operations = fd(5, .{ .repeated = .{ .submessage = {} } }),
        .auth_token = fd(6, .{ .scalar = .string }),
        .nonce = fd(7, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *TwoPhaseMessage, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const TwoPhaseResponse = struct {
    msg_type: TwoPhaseMessageType = .TWO_PHASE_MESSAGE_TYPE_UNSPECIFIED,
    transaction_id: []const u8 = "",
    participant_id: []const u8 = "",
    vote: TwoPhaseVote = .TWO_PHASE_VOTE_UNSPECIFIED,
    timestamp: i64 = 0,

    pub const _desc_table = .{
        .msg_type = fd(1, .{ .scalar = .@"enum" }),
        .transaction_id = fd(2, .{ .scalar = .string }),
        .participant_id = fd(3, .{ .scalar = .string }),
        .vote = fd(4, .{ .scalar = .@"enum" }),
        .timestamp = fd(5, .{ .scalar = .int64 }),
    };

    pub fn deinit(self: *TwoPhaseResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

// Distributed query messages
pub const QueryMessageType = enum(i32) {
    QUERY_MESSAGE_TYPE_UNSPECIFIED = 0,
    EXECUTE_FRAGMENT = 1,
    FRAGMENT_RESULT = 2,
    QUERY_CANCEL = 3,
    SHARD_HEARTBEAT = 4,
    SHARD_REGISTRATION = 5,
    QUERY_PLAN_REQUEST = 6,
    QUERY_PLAN_RESPONSE = 7,
    CROSS_SHARD_JOIN = 8,
    AGGREGATE_PARTIAL = 9,
    COORDINATOR_MERGE = 10,
};

pub const QueryPriority = enum(i32) {
    QUERY_PRIORITY_UNSPECIFIED = 0,
    LOW = 1,
    NORMAL = 2,
    HIGH = 3,
    CRITICAL = 4,
};

pub const IsolationLevel = enum(i32) {
    ISOLATION_LEVEL_UNSPECIFIED = 0,
    READ_UNCOMMITTED = 1,
    READ_COMMITTED = 2,
    REPEATABLE_READ = 3,
    SERIALIZABLE = 4,
};

pub const QueryStatus = enum(i32) {
    QUERY_STATUS_UNSPECIFIED = 0,
    SUCCESS = 1,
    FAILED = 2,
    TIMEOUT = 3,
    CANCELLED = 4,
};

pub const QueryMetadata = struct {
    estimated_rows: u64 = 0,
    memory_limit_mb: u64 = 0,
    timeout_ms: u64 = 0,
    priority: QueryPriority = .QUERY_PRIORITY_UNSPECIFIED,
    requires_transaction: bool = false,
    isolation_level: IsolationLevel = .ISOLATION_LEVEL_UNSPECIFIED,

    pub const _desc_table = .{
        .estimated_rows = fd(1, .{ .scalar = .uint64 }),
        .memory_limit_mb = fd(2, .{ .scalar = .uint64 }),
        .timeout_ms = fd(3, .{ .scalar = .uint64 }),
        .priority = fd(4, .{ .scalar = .@"enum" }),
        .requires_transaction = fd(5, .{ .scalar = .bool }),
        .isolation_level = fd(6, .{ .scalar = .@"enum" }),
    };

    pub fn deinit(self: *QueryMetadata, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const QueryFragment = struct {
    fragment_id: u64 = 0,
    shard_id: u64 = 0,
    query_text: []const u8 = "",
    dependencies: std.ArrayList(u64),
    result_schema: []const u8 = "",
    estimated_rows: u64 = 0,

    pub const _desc_table = .{
        .fragment_id = fd(1, .{ .scalar = .uint64 }),
        .shard_id = fd(2, .{ .scalar = .uint64 }),
        .query_text = fd(3, .{ .scalar = .string }),
        .dependencies = fd(4, .{ .repeated = .{ .scalar = .uint64 } }),
        .result_schema = fd(5, .{ .scalar = .string }),
        .estimated_rows = fd(6, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *QueryFragment, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const QueryResult = struct {
    query_id: u64 = 0,
    fragment_id: u64 = 0,
    shard_id: u64 = 0,
    status: QueryStatus = .QUERY_STATUS_UNSPECIFIED,
    page: ?schema.DataPage = null,
    error_message: ?[]const u8 = null,
    execution_time_ms: u64 = 0,
    rows_returned: u64 = 0,

    pub const _desc_table = .{
        .query_id = fd(1, .{ .scalar = .uint64 }),
        .fragment_id = fd(2, .{ .scalar = .uint64 }),
        .shard_id = fd(3, .{ .scalar = .uint64 }),
        .status = fd(4, .{ .scalar = .@"enum" }),
        .page = fd(5, .{ .submessage = {} }),
        .error_message = fd(6, .{ .scalar = .string }),
        .execution_time_ms = fd(7, .{ .scalar = .uint64 }),
        .rows_returned = fd(8, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *QueryResult, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const QueryMessage = struct {
    msg_type: QueryMessageType = .QUERY_MESSAGE_TYPE_UNSPECIFIED,
    query_id: u64 = 0,
    fragment_id: u64 = 0,
    shard_id: u64 = 0,
    timestamp: i64 = 0,
    fragment: ?QueryFragment = null,
    result: ?QueryResult = null,
    metadata: ?QueryMetadata = null,
    cancel_reason: ?[]const u8 = null,

    pub const _desc_table = .{
        .msg_type = fd(1, .{ .scalar = .@"enum" }),
        .query_id = fd(2, .{ .scalar = .uint64 }),
        .fragment_id = fd(3, .{ .scalar = .uint64 }),
        .shard_id = fd(4, .{ .scalar = .uint64 }),
        .timestamp = fd(5, .{ .scalar = .int64 }),
        .fragment = fd(6, .{ .submessage = {} }),
        .result = fd(7, .{ .submessage = {} }),
        .metadata = fd(8, .{ .submessage = {} }),
        .cancel_reason = fd(9, .{ .scalar = .string }),
    };

    pub fn deinit(self: *QueryMessage, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};
