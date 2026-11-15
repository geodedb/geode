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
        .mutation_type = fd(2, .{ .@"enum" = {} }),
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
        .operation = fd(1, .{ .@"enum" = {} }),
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
        .change_type = fd(1, .{ .@"enum" = {} }),
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

// RaftCommand is the protobuf submessage carried by RaftLogEntry.command.
//
// Modeled as a struct-of-optionals (protobuf "oneof" semantics: exactly one
// field is non-null at a time) rather than a `union(enum)`.  The in-tree
// protobuf-0.1.3 library cannot model a `union(enum)` as a `.submessage`
// (see `protobuf.zig:713` / `wire.zig:704` — those reflection helpers
// require `@typeInfo(T) == .@"struct"`).  Using a struct keeps the wire
// format identical (same field numbers) while letting the protobuf
// reflection machinery walk the fields the same way it walks every other
// message type.
//
// Construct one of:
//   * `RaftCommand{}` — empty, no variant set; `active() == null`.
//   * `RaftCommand{ .noop = .{} }` — direct literal.
//   * `RaftCommand.ofNoop(.{})` — convenience constructor (one per variant).
//
// Read with `cmd.active()` (returns `ActiveVariant` enum, or `null` if zero
// or multiple fields are set — the latter would be a protocol violation).
pub const RaftCommand = struct {
    noop: ?Noop = null,
    write: ?WriteCommand = null,
    graph_mutation: ?GraphMutation = null,
    schema_change: ?SchemaChange = null,
    config_change: ?ConfigChange = null,
    snapshot_pointer: ?SnapshotPointer = null,
    txn_prepare: ?TxnPrepare = null,
    txn_decide: ?TxnDecide = null,

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

    pub const ActiveVariant = enum {
        noop,
        write,
        graph_mutation,
        schema_change,
        config_change,
        snapshot_pointer,
        txn_prepare,
        txn_decide,
    };

    /// Returns the active variant tag, or null if no variant is set, or if
    /// more than one variant is set (protocol violation — callers should
    /// reject such frames).
    pub fn active(self: *const RaftCommand) ?ActiveVariant {
        var count: u8 = 0;
        var which: ?ActiveVariant = null;
        if (self.noop != null) {
            count += 1;
            which = .noop;
        }
        if (self.write != null) {
            count += 1;
            which = .write;
        }
        if (self.graph_mutation != null) {
            count += 1;
            which = .graph_mutation;
        }
        if (self.schema_change != null) {
            count += 1;
            which = .schema_change;
        }
        if (self.config_change != null) {
            count += 1;
            which = .config_change;
        }
        if (self.snapshot_pointer != null) {
            count += 1;
            which = .snapshot_pointer;
        }
        if (self.txn_prepare != null) {
            count += 1;
            which = .txn_prepare;
        }
        if (self.txn_decide != null) {
            count += 1;
            which = .txn_decide;
        }
        return if (count == 1) which else null;
    }

    pub fn ofNoop(v: Noop) RaftCommand {
        return .{ .noop = v };
    }
    pub fn ofWrite(v: WriteCommand) RaftCommand {
        return .{ .write = v };
    }
    pub fn ofGraphMutation(v: GraphMutation) RaftCommand {
        return .{ .graph_mutation = v };
    }
    pub fn ofSchemaChange(v: SchemaChange) RaftCommand {
        return .{ .schema_change = v };
    }
    pub fn ofConfigChange(v: ConfigChange) RaftCommand {
        return .{ .config_change = v };
    }
    pub fn ofSnapshotPointer(v: SnapshotPointer) RaftCommand {
        return .{ .snapshot_pointer = v };
    }
    pub fn ofTxnPrepare(v: TxnPrepare) RaftCommand {
        return .{ .txn_prepare = v };
    }
    pub fn ofTxnDecide(v: TxnDecide) RaftCommand {
        return .{ .txn_decide = v };
    }

    pub fn deinit(self: *RaftCommand, allocator: std.mem.Allocator) void {
        if (self.noop) |*v| v.deinit(allocator);
        if (self.write) |*v| v.deinit(allocator);
        if (self.graph_mutation) |*v| v.deinit(allocator);
        if (self.schema_change) |*v| v.deinit(allocator);
        if (self.config_change) |*v| v.deinit(allocator);
        if (self.snapshot_pointer) |*v| v.deinit(allocator);
        if (self.txn_prepare) |*v| v.deinit(allocator);
        if (self.txn_decide) |*v| v.deinit(allocator);
    }
};

pub const RaftLogEntry = struct {
    term: u64 = 0,
    index: u64 = 0,
    timestamp: i64 = 0,
    client_id: ?u64 = null,
    serial_number: ?u64 = null,
    command: ?RaftCommand = null,
    // Field 7 (command_bytes): the canonical tag-prefixed command encoding
    // produced by raft_consensus.serializeCommand / consumed by
    // deserializeCommand.  This is the wire carrier the cluster bridge
    // actually uses for AppendEntries log replication: it round-trips
    // byte-exactly through serialize∘deserialize for every Command variant
    // (noop / write / graph_mutation / schema_change / config_change /
    // snapshot_pointer / txn_prepare / txn_decide), so it avoids the
    // structured-RaftCommand mapping while guaranteeing the leader's log
    // entry is replicated verbatim.  The structured `command` submessage
    // (field 6) is retained for schema compatibility but left unset on the
    // replication path.
    command_bytes: []const u8 = "",

    pub const _desc_table = .{
        .term = fd(1, .{ .scalar = .uint64 }),
        .index = fd(2, .{ .scalar = .uint64 }),
        .timestamp = fd(3, .{ .scalar = .int64 }),
        .client_id = fd(4, .{ .scalar = .uint64 }),
        .serial_number = fd(5, .{ .scalar = .uint64 }),
        .command = fd(6, .{ .submessage = {} }),
        .command_bytes = fd(7, .{ .scalar = .bytes }),
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
    /// A6d: pre-vote phase echo bit.  Pre-vote is enabled by default in
    /// the embedded raft library (node.zig:43); the candidate counts
    /// only responses whose pre_vote bit matches its current phase, so
    /// the response MUST carry it through to avoid stalling election.
    pre_vote: bool = false,

    pub const _desc_table = .{
        .term = fd(1, .{ .scalar = .uint64 }),
        .vote_granted = fd(2, .{ .scalar = .bool }),
        .voter_id = fd(3, .{ .scalar = .uint64 }),
        .pre_vote = fd(4, .{ .scalar = .bool }),
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
    /// SONNY-6622: a rejection's backtracking hint (raft v0.2.2). New
    /// fields: a peer that does not send them reads as 0, a rejection
    /// without a hint, which the leader backs off from as before.
    conflict_index: u64 = 0,
    conflict_term: u64 = 0,

    pub const _desc_table = .{
        .term = fd(1, .{ .scalar = .uint64 }),
        .success = fd(2, .{ .scalar = .bool }),
        .match_index = fd(3, .{ .scalar = .uint64 }),
        .conflict_index = fd(4, .{ .scalar = .uint64 }),
        .conflict_term = fd(5, .{ .scalar = .uint64 }),
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
    // A6d (2026-05-25): two interacting protobuf-0.1.3 decoder quirks
    // combined to drop every inbound RaftEnvelope on the floor:
    //
    //   1. Several RaftEnvelope scalar fields shared a wire field number
    //      with one of the inner RaftMessage oneof variants (RaftMessage
    //      uses field numbers 1..6):
    //        term  = fd(1) collided with request_vote          = fd(1)
    //        from  = fd(2) collided with request_vote_response = fd(2)
    //      The decoder walks the parent's _desc_table fields in order
    //      and, on a wire tag of (say) field 1 LEN, matched against
    //      `term` (varint) first and tripped the wire-type guard at
    //      wire.zig:729 with error.InvalidInput.
    //
    //   2. The decoder's `inline for` over _desc_table fields uses a
    //      `comptime break` at the end of every iteration.  When it
    //      reaches the `.oneof` field and the inner desc table holds no
    //      match for the current tag, the oneof switch's
    //      `else skipField(...)` consumes the wire bytes and the
    //      comptime break exits the loop — so any subsequent _desc_table
    //      field whose field_number matched the tag would never be
    //      processed.
    //
    // Both quirks are addressed by:
    //
    //   * Renumbering ALL scalar fields out of the 1..6 range so they
    //     can never collide with a current or future RaftMessage oneof
    //     variant.  Specifically: term -> 12, from -> 13, nonce keeps
    //     10, auth_token keeps 11.  Field numbers 7..9 are intentionally
    //     reserved for future RaftMessage oneof variants (e.g.
    //     install_snapshot_chunk, transfer_leader, pre_vote, ...).
    //   * Reordering _desc_table so the `message` oneof is the LAST
    //     entry.  This way the decoder's inline-for visits every
    //     concrete scalar field before falling through to the oneof's
    //     catch-all skipField branch.
    //
    // This is a wire-incompatible change but the protocol has only ever
    // been spoken between geode peers built from the same source tree,
    // and the 3-node subprocess test in tests/test_cluster_3node_subprocess.zig
    // exercises both encode and decode of every envelope shape end-to-end.
    term: u64 = 0,
    from: u64 = 0,
    /// SEC-D009: Cryptographic nonce for replay protection.
    /// Each frame carries a random nonce; receivers reject frames with previously-seen nonces.
    nonce: u64 = 0,
    auth_token: []const u8 = "",
    message: ?RaftMessage = null,

    pub const _desc_table = .{
        .term = fd(12, .{ .scalar = .uint64 }),
        .from = fd(13, .{ .scalar = .uint64 }),
        .nonce = fd(10, .{ .scalar = .uint64 }),
        .auth_token = fd(11, .{ .scalar = .string }),
        .message = fd(null, .{ .oneof = RaftMessage }),
    };

    pub fn deinit(self: *RaftEnvelope, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};
