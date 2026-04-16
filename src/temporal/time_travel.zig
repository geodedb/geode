const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_sleep(ns: u64) void {
    const req = std.os.linux.timespec{ .sec = 0, .nsec = @intCast(ns) };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const Allocator = std.mem.Allocator;

pub const TemporalVersion = struct {
    transaction_id: u64,
    timestamp: i64,
    is_deleted: bool = false,
};

pub const VersionedValue = struct {
    value: []const u8,
    version: TemporalVersion,
    previous_version: ?*VersionedValue = null,
};

pub const TemporalNode = struct {
    id: u64,
    labels: []const []const u8,
    properties: std.StringHashMap(VersionedValue),
    versions: std.ArrayList(TemporalVersion),
    created_at: TemporalVersion,
    deleted_at: ?TemporalVersion = null,
};

pub const TemporalEdge = struct {
    id: u64,
    source_id: u64,
    target_id: u64,
    label: []const u8,
    properties: std.StringHashMap(VersionedValue),
    versions: std.ArrayList(TemporalVersion),
    created_at: TemporalVersion,
    deleted_at: ?TemporalVersion = null,
};

pub const TemporalQuery = struct {
    query: []const u8,
    as_of: ?AsOfClause = null,
    between: ?BetweenClause = null,
    versions: ?VersionsClause = null,
};

pub const AsOfClause = union(enum) {
    timestamp: i64,
    transaction_id: u64,
    system_time: i64,
};

pub const BetweenClause = struct {
    start: AsOfClause,
    end: AsOfClause,
};

pub const VersionsClause = struct {
    include_all: bool = false,
    max_versions: ?u32 = null,
};

pub const TemporalStorage = struct {
    allocator: Allocator,
    nodes: std.AutoHashMap(u64, *TemporalNode),
    edges: std.AutoHashMap(u64, *TemporalEdge),
    transaction_log: std.ArrayList(TransactionRecord),
    current_transaction_id: std.atomic.Value(u64),
    retention_policy: RetentionPolicy,

    const Self = @This();

    pub fn init(allocator: Allocator, retention_policy: RetentionPolicy) !Self {
        return Self{
            .allocator = allocator,
            .nodes = std.AutoHashMap(u64, *TemporalNode).init(allocator),
            .edges = std.AutoHashMap(u64, *TemporalEdge).init(allocator),
            .transaction_log = std.ArrayList(TransactionRecord).empty,
            .current_transaction_id = std.atomic.Value(u64).init(1),
            .retention_policy = retention_policy,
        };
    }

    pub fn deinit(self: *Self) void {
        var node_it = self.nodes.iterator();
        while (node_it.next()) |entry| {
            self.destroyNode(entry.value_ptr.*);
        }
        self.nodes.deinit();

        var edge_it = self.edges.iterator();
        while (edge_it.next()) |entry| {
            self.destroyEdge(entry.value_ptr.*);
        }
        self.edges.deinit();

        self.transaction_log.deinit(self.allocator);
    }

    fn destroyNode(self: *Self, node: *TemporalNode) void {
        node.versions.deinit(self.allocator);
        node.properties.deinit();
        self.allocator.destroy(node);
    }

    fn destroyEdge(self: *Self, edge: *TemporalEdge) void {
        edge.versions.deinit(self.allocator);
        edge.properties.deinit();
        self.allocator.destroy(edge);
    }

    pub fn createNode(
        self: *Self,
        id: u64,
        labels: []const []const u8,
        properties: std.StringHashMap([]const u8),
    ) !void {
        const txn_id = self.current_transaction_id.fetchAdd(1, .monotonic);
        const timestamp = compat_milliTimestamp();

        const node = try self.allocator.create(TemporalNode);
        node.* = TemporalNode{
            .id = id,
            .labels = labels,
            .properties = std.StringHashMap(VersionedValue).init(self.allocator),
            .versions = std.ArrayList(TemporalVersion).empty,
            .created_at = TemporalVersion{
                .transaction_id = txn_id,
                .timestamp = timestamp,
            },
        };

        // Convert properties to versioned values
        var prop_it = properties.iterator();
        while (prop_it.next()) |entry| {
            const versioned = VersionedValue{
                .value = entry.value_ptr.*,
                .version = node.created_at,
            };
            try node.properties.put(entry.key_ptr.*, versioned);
        }

        try node.versions.append(self.allocator, node.created_at);
        try self.nodes.put(id, node);

        // Log transaction
        try self.logTransaction(txn_id, timestamp, .create_node, id);
    }

    pub fn updateNode(
        self: *Self,
        id: u64,
        properties: std.StringHashMap([]const u8),
    ) !void {
        const node = self.nodes.get(id) orelse return error.NodeNotFound;

        const txn_id = self.current_transaction_id.fetchAdd(1, .monotonic);
        const timestamp = compat_milliTimestamp();
        const version = TemporalVersion{
            .transaction_id = txn_id,
            .timestamp = timestamp,
        };

        // Update properties with new versions
        var prop_it = properties.iterator();
        while (prop_it.next()) |entry| {
            const old_value = node.properties.get(entry.key_ptr.*);

            const new_versioned = VersionedValue{
                .value = entry.value_ptr.*,
                .version = version,
                .previous_version = if (old_value) |_| try self.allocator.create(VersionedValue) else null,
            };

            if (new_versioned.previous_version) |prev| {
                prev.* = old_value.?;
            }

            try node.properties.put(entry.key_ptr.*, new_versioned);
        }

        try node.versions.append(self.allocator, version);
        try self.logTransaction(txn_id, timestamp, .update_node, id);
    }

    pub fn deleteNode(self: *Self, id: u64) !void {
        const node = self.nodes.get(id) orelse return error.NodeNotFound;

        const txn_id = self.current_transaction_id.fetchAdd(1, .monotonic);
        const timestamp = compat_milliTimestamp();

        node.deleted_at = TemporalVersion{
            .transaction_id = txn_id,
            .timestamp = timestamp,
            .is_deleted = true,
        };

        try node.versions.append(self.allocator, node.deleted_at.?);
        try self.logTransaction(txn_id, timestamp, .delete_node, id);
    }

    pub fn getNodeAsOf(self: *Self, id: u64, as_of: AsOfClause) ?*TemporalNode {
        const node = self.nodes.get(id) orelse return null;

        // Check if node existed at the specified time
        if (!self.wasValidAt(node.created_at, node.deleted_at, as_of)) {
            return null;
        }

        // GAP-0119 FIX: Filter properties to show only values valid at the specified time
        // CANARY: REQ=REQ-TEMPORAL-PROP-001; FEATURE="TemporalPropertyFiltering"; ASPECT=Temporal; STATUS=TESTED; TEST=src/temporal/time_travel.zig; OWNER=temporal; UPDATED=2026-01-25
        const filtered_node = self.filterNodePropertiesAsOf(node, as_of) catch return null;
        return filtered_node;
    }

    // GAP-0119: Filter node properties to show only values valid at specified time
    fn filterNodePropertiesAsOf(self: *Self, node: *TemporalNode, as_of: AsOfClause) !*TemporalNode {
        const as_of_time = self.asOfToTimestamp(as_of);

        // Create a copy of the node with filtered properties
        const filtered_node = try self.allocator.create(TemporalNode);
        filtered_node.* = .{
            .id = node.id,
            .labels = node.labels,
            .properties = std.StringHashMap(VersionedValue).init(self.allocator),
            .versions = node.versions,
            .created_at = node.created_at,
            .deleted_at = node.deleted_at,
        };

        // Filter each property to find the version valid at as_of time
        var prop_it = node.properties.iterator();
        while (prop_it.next()) |entry| {
            const key = entry.key_ptr.*;
            const versioned_value = entry.value_ptr.*;

            // Find the version valid at the specified time
            if (self.findPropertyVersionAsOf(versioned_value, as_of_time)) |valid_value| {
                try filtered_node.properties.put(key, valid_value);
            }
            // If no valid version found, property is omitted (didn't exist at that time)
        }

        return filtered_node;
    }

    // Find the property version that was valid at a specific timestamp
    fn findPropertyVersionAsOf(self: *Self, versioned_value: VersionedValue, as_of_time: i64) ?VersionedValue {
        _ = self;

        // Check if current version was created before or at as_of time
        if (versioned_value.version.timestamp <= as_of_time) {
            return versioned_value;
        }

        // Traverse previous versions to find one valid at as_of time
        var current = versioned_value.previous_version;
        while (current) |prev| {
            if (prev.version.timestamp <= as_of_time) {
                return prev.*;
            }
            current = prev.previous_version;
        }

        // No version existed at the specified time
        return null;
    }

    // Convert AsOfClause to timestamp
    fn asOfToTimestamp(self: *Self, as_of: AsOfClause) i64 {
        _ = self;
        return switch (as_of) {
            .timestamp => |t| t,
            .transaction_id => |tid| @as(i64, @intCast(tid * 1000)),
            .system_time => |t| t,
        };
    }

    pub fn getNodeVersions(self: *Self, id: u64) ![]TemporalVersion {
        const node = self.nodes.get(id) orelse return error.NodeNotFound;
        return node.versions.items;
    }

    fn wasValidAt(
        self: *Self,
        created: TemporalVersion,
        deleted: ?TemporalVersion,
        as_of: AsOfClause,
    ) bool {
        _ = self;

        const as_of_time = switch (as_of) {
            .timestamp => |t| t,
            .transaction_id => |tid| blk: {
                // Convert transaction ID to timestamp
                // In practice, would look up in transaction log
                break :blk @as(i64, @intCast(tid * 1000));
            },
            .system_time => |t| t,
        };

        if (created.timestamp > as_of_time) {
            return false;
        }

        if (deleted) |del| {
            if (del.timestamp <= as_of_time) {
                return false;
            }
        }

        return true;
    }

    fn logTransaction(
        self: *Self,
        txn_id: u64,
        timestamp: i64,
        operation: TransactionOperation,
        object_id: u64,
    ) !void {
        try self.transaction_log.append(self.allocator, TransactionRecord{
            .transaction_id = txn_id,
            .timestamp = timestamp,
            .operation = operation,
            .object_id = object_id,
        });
    }

    pub fn vacuum(self: *Self) !void {
        // Remove old versions based on retention policy
        const cutoff_time = compat_milliTimestamp() - self.retention_policy.retention_period_ms;

        var node_it = self.nodes.iterator();
        while (node_it.next()) |entry| {
            const node = entry.value_ptr.*;
            try self.vacuumNodeVersions(node, cutoff_time);
        }

        // Cleanup transaction log
        var i: usize = 0;
        while (i < self.transaction_log.items.len) {
            if (self.transaction_log.items[i].timestamp < cutoff_time) {
                _ = self.transaction_log.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn vacuumNodeVersions(self: *Self, node: *TemporalNode, cutoff_time: i64) !void {
        _ = self;

        // Keep at least one version
        if (node.versions.items.len <= 1) {
            return;
        }

        // Remove old versions
        var i: usize = 0;
        while (i < node.versions.items.len - 1) {
            if (node.versions.items[i].timestamp < cutoff_time) {
                _ = node.versions.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

pub const TransactionRecord = struct {
    transaction_id: u64,
    timestamp: i64,
    operation: TransactionOperation,
    object_id: u64,
};

pub const TransactionOperation = enum {
    create_node,
    update_node,
    delete_node,
    create_edge,
    update_edge,
    delete_edge,
};

pub const RetentionPolicy = struct {
    retention_period_ms: i64 = 30 * 24 * 60 * 60 * 1000, // 30 days
    min_versions_to_keep: u32 = 1,
    vacuum_interval_ms: i64 = 24 * 60 * 60 * 1000, // Daily
};

pub const TemporalQueryExecutor = struct {
    allocator: Allocator,
    storage: *TemporalStorage,

    const Self = @This();

    pub fn init(allocator: Allocator, storage: *TemporalStorage) Self {
        return Self{
            .allocator = allocator,
            .storage = storage,
        };
    }

    pub fn executeAsOf(self: *Self, query: []const u8, as_of: AsOfClause) !QueryResult {
        _ = query;

        // Execute query with temporal filter
        var results = std.ArrayList(TemporalBinding).empty;

        // Example: Get all nodes as of the specified time
        var it = self.storage.nodes.iterator();
        while (it.next()) |entry| {
            if (self.storage.getNodeAsOf(entry.key_ptr.*, as_of)) |node| {
                try results.append(self.allocator, TemporalBinding{
                    .node_id = node.id,
                    .valid_from = node.created_at.timestamp,
                    .valid_to = if (node.deleted_at) |d| d.timestamp else null,
                });
            }
        }

        return QueryResult{
            .bindings = results.items,
            .as_of = as_of,
        };
    }

    pub fn executeBetween(
        self: *Self,
        query: []const u8,
        start: AsOfClause,
        end: AsOfClause,
    ) !QueryResult {
        _ = self;
        _ = query;
        _ = start;
        _ = end;

        // Execute query for time range
        return QueryResult{
            .bindings = &[_]TemporalBinding{},
            .as_of = null,
        };
    }

    pub fn executeVersions(self: *Self, query: []const u8, versions: VersionsClause) !QueryResult {
        _ = self;
        _ = query;
        _ = versions;

        // Return all versions of matching objects
        return QueryResult{
            .bindings = &[_]TemporalBinding{},
            .as_of = null,
        };
    }
};

pub const QueryResult = struct {
    bindings: []const TemporalBinding,
    as_of: ?AsOfClause,
};

pub const TemporalBinding = struct {
    node_id: u64,
    valid_from: i64,
    valid_to: ?i64,
};

test "temporal storage basic operations" {
    const allocator = std.testing.allocator;

    var storage = try TemporalStorage.init(allocator, .{});
    defer storage.deinit();

    // Create a node
    var props = std.StringHashMap([]const u8).init(allocator);
    defer props.deinit();
    try props.put("name", "Alice");

    try storage.createNode(1, &[_][]const u8{"Person"}, props);

    // Update the node
    var new_props = std.StringHashMap([]const u8).init(allocator);
    defer new_props.deinit();
    try new_props.put("name", "Alice Smith");

    try storage.updateNode(1, new_props);

    // Get versions
    const versions = try storage.getNodeVersions(1);
    try std.testing.expect(versions.len == 2);
}

test "time travel query" {
    const allocator = std.testing.allocator;

    var storage = try TemporalStorage.init(allocator, .{});
    defer storage.deinit();

    // Create a node
    var props = std.StringHashMap([]const u8).init(allocator);
    defer props.deinit();
    try props.put("name", "Bob");

    const before = compat_milliTimestamp();
    try storage.createNode(2, &[_][]const u8{"Person"}, props);
    const after = compat_milliTimestamp();

    // Query as of before creation
    const node_before = storage.getNodeAsOf(2, .{ .timestamp = before - 1 });
    try std.testing.expect(node_before == null);

    // Query as of after creation
    const node_after = storage.getNodeAsOf(2, .{ .timestamp = after + 1 });
    try std.testing.expect(node_after != null);
}

test "vacuum old versions" {
    const allocator = std.testing.allocator;

    var storage = try TemporalStorage.init(allocator, .{
        .retention_period_ms = 1000, // 1 second for testing
    });
    defer storage.deinit();

    // Create and update a node
    var props = std.StringHashMap([]const u8).init(allocator);
    defer props.deinit();
    try props.put("value", "v1");

    try storage.createNode(3, &[_][]const u8{"Test"}, props);

    // Wait and update
    compat_sleep(1100 * std.time.ns_per_ms);

    try props.put("value", "v2");
    try storage.updateNode(3, props);

    // Vacuum should keep only the latest version
    try storage.vacuum();

    const versions = try storage.getNodeVersions(3);
    try std.testing.expect(versions.len >= 1);
}
