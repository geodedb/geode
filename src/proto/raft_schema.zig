const std = @import("std");
const protobuf = @import("protobuf");

const fd = protobuf.fd;

pub const MutationType = enum(i32) {
    MUTATION_TYPE_UNSPECIFIED = 0,
    CREATE = 1,
    UPDATE = 2,
    DELETE = 3,
    MERGE = 4,
};

pub const SchemaChangeOperation = enum(i32) {
    SCHEMA_OP_UNSPECIFIED = 0,
    CREATE_GRAPH = 1,
    DROP_GRAPH = 2,
    ALTER_GRAPH = 3,
};

pub const ConfigChangeType = enum(i32) {
    CONFIG_CHANGE_UNSPECIFIED = 0,
    ADD_SERVER = 1,
    REMOVE_SERVER = 2,
    UPDATE_SERVER = 3,
};

pub const Noop = struct {
    pub const _desc_table = .{};

    pub fn deinit(self: *Noop, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

pub const WriteCommand = struct {
    data: []const u8 = "",

    pub const _desc_table = .{
        .data = fd(1, .{ .scalar = .bytes }),
    };

    pub fn deinit(self: *WriteCommand, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const GraphMutation = struct {
    graph: []const u8 = "",
    mutation_type: MutationType = .MUTATION_TYPE_UNSPECIFIED,
    data: []const u8 = "",
    txn_id: ?u64 = null,

    pub const _desc_table = .{
        .graph = fd(1, .{ .scalar = .string }),
        .mutation_type = fd(2, .{ .scalar = .@"enum" }),
        .data = fd(3, .{ .scalar = .bytes }),
        .txn_id = fd(4, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *GraphMutation, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const SchemaChange = struct {
    operation: SchemaChangeOperation = .SCHEMA_OP_UNSPECIFIED,
    graph: []const u8 = "",
    schema: []const u8 = "",

    pub const _desc_table = .{
        .operation = fd(1, .{ .scalar = .@"enum" }),
        .graph = fd(2, .{ .scalar = .string }),
        .schema = fd(3, .{ .scalar = .string }),
    };

    pub fn deinit(self: *SchemaChange, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const ConfigChange = struct {
    change_type: ConfigChangeType = .CONFIG_CHANGE_UNSPECIFIED,
    server_id: u64 = 0,
    server_endpoint: ?[]const u8 = null,
    server_port: ?u32 = null,

    pub const _desc_table = .{
        .change_type = fd(1, .{ .scalar = .@"enum" }),
        .server_id = fd(2, .{ .scalar = .uint64 }),
        .server_endpoint = fd(3, .{ .scalar = .string }),
        .server_port = fd(4, .{ .scalar = .uint32 }),
    };

    pub fn deinit(self: *ConfigChange, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const SnapshotPointer = struct {
    last_included_index: u64 = 0,
    last_included_term: u64 = 0,
    size_bytes: u64 = 0,
    checksum: u64 = 0,

    pub const _desc_table = .{
        .last_included_index = fd(1, .{ .scalar = .uint64 }),
        .last_included_term = fd(2, .{ .scalar = .uint64 }),
        .size_bytes = fd(3, .{ .scalar = .uint64 }),
        .checksum = fd(4, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *SnapshotPointer, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const TxnPrepare = struct {
    xid: u64 = 0,
    shard_id: u64 = 0,
    write_set: []const u8 = "",
    metadata: []const u8 = "",

    pub const _desc_table = .{
        .xid = fd(1, .{ .scalar = .uint64 }),
        .shard_id = fd(2, .{ .scalar = .uint64 }),
        .write_set = fd(3, .{ .scalar = .bytes }),
        .metadata = fd(4, .{ .scalar = .bytes }),
    };

    pub fn deinit(self: *TxnPrepare, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const TxnDecide = struct {
    xid: u64 = 0,
    commit: bool = false,

    pub const _desc_table = .{
        .xid = fd(1, .{ .scalar = .uint64 }),
        .commit = fd(2, .{ .scalar = .bool }),
    };

    pub fn deinit(self: *TxnDecide, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const RaftCommand = union(enum) {
    noop: Noop,
    write: WriteCommand,
    graph_mutation: GraphMutation,
    schema_change: SchemaChange,
    config_change: ConfigChange,
    snapshot_pointer: SnapshotPointer,
    txn_prepare: TxnPrepare,
    txn_decide: TxnDecide,

    pub const _desc_table = .{
        .noop = fd(1, .{ .submessage = {} }),
        .write = fd(2, .{ .submessage = {} }),
        .graph_mutation = fd(3, .{ .submessage = {} }),
        .schema_change = fd(4, .{ .submessage = {} }),
        .config_change = fd(5, .{ .submessage = {} }),
        .snapshot_pointer = fd(6, .{ .submessage = {} }),
        .txn_prepare = fd(7, .{ .submessage = {} }),
        .txn_decide = fd(8, .{ .submessage = {} }),
    };

    pub fn deinit(self: *RaftCommand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*case| case.deinit(allocator),
        }
    }
};

pub const RaftLogEntry = struct {
    term: u64 = 0,
    index: u64 = 0,
    timestamp: i64 = 0,
    client_id: ?u64 = null,
    serial_number: ?u64 = null,
    command: ?RaftCommand = null,

    pub const _desc_table = .{
        .term = fd(1, .{ .scalar = .uint64 }),
        .index = fd(2, .{ .scalar = .uint64 }),
        .timestamp = fd(3, .{ .scalar = .int64 }),
        .client_id = fd(4, .{ .scalar = .uint64 }),
        .serial_number = fd(5, .{ .scalar = .uint64 }),
        .command = fd(6, .{ .submessage = {} }),
    };

    pub fn deinit(self: *RaftLogEntry, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const RequestVote = struct {
    term: u64 = 0,
    candidate_id: u64 = 0,
    last_log_index: u64 = 0,
    last_log_term: u64 = 0,
    pre_vote: bool = false,

    pub const _desc_table = .{
        .term = fd(1, .{ .scalar = .uint64 }),
        .candidate_id = fd(2, .{ .scalar = .uint64 }),
        .last_log_index = fd(3, .{ .scalar = .uint64 }),
        .last_log_term = fd(4, .{ .scalar = .uint64 }),
        .pre_vote = fd(5, .{ .scalar = .bool }),
    };

    pub fn deinit(self: *RequestVote, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const RequestVoteResponse = struct {
    term: u64 = 0,
    vote_granted: bool = false,
    voter_id: u64 = 0,

    pub const _desc_table = .{
        .term = fd(1, .{ .scalar = .uint64 }),
        .vote_granted = fd(2, .{ .scalar = .bool }),
        .voter_id = fd(3, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *RequestVoteResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const AppendEntries = struct {
    term: u64 = 0,
    leader_id: u64 = 0,
    prev_log_index: u64 = 0,
    prev_log_term: u64 = 0,
    entries: std.ArrayList(RaftLogEntry),
    leader_commit: u64 = 0,

    pub const _desc_table = .{
        .term = fd(1, .{ .scalar = .uint64 }),
        .leader_id = fd(2, .{ .scalar = .uint64 }),
        .prev_log_index = fd(3, .{ .scalar = .uint64 }),
        .prev_log_term = fd(4, .{ .scalar = .uint64 }),
        .entries = fd(5, .{ .repeated = .{ .submessage = {} } }),
        .leader_commit = fd(6, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *AppendEntries, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const AppendEntriesResponse = struct {
    term: u64 = 0,
    success: bool = false,
    match_index: u64 = 0,

    pub const _desc_table = .{
        .term = fd(1, .{ .scalar = .uint64 }),
        .success = fd(2, .{ .scalar = .bool }),
        .match_index = fd(3, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *AppendEntriesResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const InstallSnapshot = struct {
    term: u64 = 0,
    leader_id: u64 = 0,
    last_included_index: u64 = 0,
    last_included_term: u64 = 0,
    offset: u64 = 0,
    data: []const u8 = "",
    done: bool = false,

    pub const _desc_table = .{
        .term = fd(1, .{ .scalar = .uint64 }),
        .leader_id = fd(2, .{ .scalar = .uint64 }),
        .last_included_index = fd(3, .{ .scalar = .uint64 }),
        .last_included_term = fd(4, .{ .scalar = .uint64 }),
        .offset = fd(5, .{ .scalar = .uint64 }),
        .data = fd(6, .{ .scalar = .bytes }),
        .done = fd(7, .{ .scalar = .bool }),
    };

    pub fn deinit(self: *InstallSnapshot, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const InstallSnapshotResponse = struct {
    term: u64 = 0,

    pub const _desc_table = .{
        .term = fd(1, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *InstallSnapshotResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

pub const RaftMessage = union(enum) {
    request_vote: RequestVote,
    request_vote_response: RequestVoteResponse,
    append_entries: AppendEntries,
    append_entries_response: AppendEntriesResponse,
    install_snapshot: InstallSnapshot,
    install_snapshot_response: InstallSnapshotResponse,

    pub const _desc_table = .{
        .request_vote = fd(1, .{ .submessage = {} }),
        .request_vote_response = fd(2, .{ .submessage = {} }),
        .append_entries = fd(3, .{ .submessage = {} }),
        .append_entries_response = fd(4, .{ .submessage = {} }),
        .install_snapshot = fd(5, .{ .submessage = {} }),
        .install_snapshot_response = fd(6, .{ .submessage = {} }),
    };

    pub fn deinit(self: *RaftMessage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*case| case.deinit(allocator),
        }
    }
};

pub const RaftEnvelope = struct {
    term: u64 = 0,
    from: u64 = 0,
    /// SEC-D009: Cryptographic nonce for replay protection.
    /// Each frame carries a random nonce; receivers reject frames with previously-seen nonces.
    nonce: u64 = 0,
    message: ?RaftMessage = null,
    auth_token: []const u8 = "",

    pub const _desc_table = .{
        .term = fd(1, .{ .scalar = .uint64 }),
        .from = fd(2, .{ .scalar = .uint64 }),
        .nonce = fd(10, .{ .scalar = .uint64 }),
        .message = fd(null, .{ .oneof = RaftMessage }),
        .auth_token = fd(11, .{ .scalar = .string }),
    };

    pub fn deinit(self: *RaftEnvelope, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};
