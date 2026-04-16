// CANARY: REQ=REQ-DIST-REGISTRY-001; FEATURE="Node Registry"; ASPECT=NodeLookup; STATUS=TESTED; TEST=TestCANARY_REQ_DIST_REGISTRY_001_NodeCRUD; OWNER=distributed; UPDATED=2026-04-06

//! Unit tests for NodeRegistry — the hashmap-based node tracking component of
//! query_transport.zig. NodeRegistry has no QUIC or protobuf dependencies, so it
//! is extracted here for isolated, standalone testing (GAP-0513).

const std = @import("std");

fn compat_sleep(ns: u64) void {
    const req = std.os.linux.timespec{ .sec = 0, .nsec = @intCast(ns) };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

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
const testing = std.testing;

// ---------------------------------------------------------------------------
// Inline copy of NodeRegistry from src/distributed/query_transport.zig.
// Kept in sync with the source; only std is needed.
// ---------------------------------------------------------------------------

const NodeStatus = enum {
    active,
    inactive,
    unknown,
};

const NodeInfo = struct {
    node_id: u32,
    host: []const u8,
    port: u16,
    status: NodeStatus,
    last_heartbeat: i64,
};

const NodeRegistry = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMap(u32, NodeInfo),

    pub fn init(allocator: std.mem.Allocator) !NodeRegistry {
        return NodeRegistry{
            .allocator = allocator,
            .nodes = std.AutoHashMap(u32, NodeInfo).init(allocator),
        };
    }

    pub fn deinit(self: *NodeRegistry) void {
        self.nodes.deinit();
    }

    pub fn registerNode(self: *NodeRegistry, node_id: u32, host: []const u8, port: u16) !void {
        try self.nodes.put(node_id, NodeInfo{
            .node_id = node_id,
            .host = host,
            .port = port,
            .status = .active,
            .last_heartbeat = compat_milliTimestamp(),
        });
    }

    pub fn getNodeInfo(self: *NodeRegistry, node_id: u32) ?NodeInfo {
        return self.nodes.get(node_id);
    }

    pub fn updateHeartbeat(self: *NodeRegistry, node_id: u32) void {
        if (self.nodes.getPtr(node_id)) |info| {
            info.last_heartbeat = compat_milliTimestamp();
            info.status = .active;
        }
    }

    pub fn markInactive(self: *NodeRegistry, node_id: u32) void {
        if (self.nodes.getPtr(node_id)) |info| {
            info.status = .inactive;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-DIST-REGISTRY-001; FEATURE="Node Registry"; ASPECT=NodeLookup; STATUS=TESTED; TEST=TestCANARY_REQ_DIST_REGISTRY_001_NodeCRUD; OWNER=distributed; UPDATED=2026-04-06
test "TestCANARY_REQ_DIST_REGISTRY_001_NodeCRUD" {
    var registry = try NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    // Unknown node returns null
    try testing.expect(registry.getNodeInfo(99) == null);

    // Register a node; it should be retrievable and active
    try registry.registerNode(1, "node1.cluster.local", 3141);
    const info = registry.getNodeInfo(1);
    try testing.expect(info != null);
    try testing.expectEqual(@as(u32, 1), info.?.node_id);
    try testing.expectEqualStrings("node1.cluster.local", info.?.host);
    try testing.expectEqual(@as(u16, 3141), info.?.port);
    try testing.expectEqual(NodeStatus.active, info.?.status);

    // updateHeartbeat keeps status active and updates timestamp
    const before = info.?.last_heartbeat;
    compat_sleep(1 * std.time.ns_per_ms); // ensure clock advances
    registry.updateHeartbeat(1);
    const after = registry.getNodeInfo(1).?;
    try testing.expectEqual(NodeStatus.active, after.status);
    try testing.expect(after.last_heartbeat >= before);

    // markInactive flips status
    registry.markInactive(1);
    try testing.expectEqual(NodeStatus.inactive, registry.getNodeInfo(1).?.status);

    // Operations on missing node are no-ops (don't panic)
    registry.updateHeartbeat(999);
    registry.markInactive(999);
    try testing.expect(registry.getNodeInfo(999) == null);
}

// CANARY: REQ=REQ-DIST-REGISTRY-001; FEATURE="Node Registry"; ASPECT=MultiNode; STATUS=TESTED; TEST=TestCANARY_REQ_DIST_REGISTRY_001_MultipleNodes; OWNER=distributed; UPDATED=2026-04-06
test "TestCANARY_REQ_DIST_REGISTRY_001_MultipleNodes" {
    var registry = try NodeRegistry.init(testing.allocator);
    defer registry.deinit();

    try registry.registerNode(10, "node-a.cluster.local", 3141);
    try registry.registerNode(20, "node-b.cluster.local", 3142);
    try registry.registerNode(30, "node-c.cluster.local", 3143);

    const a = registry.getNodeInfo(10);
    const b = registry.getNodeInfo(20);
    const c = registry.getNodeInfo(30);

    try testing.expect(a != null);
    try testing.expect(b != null);
    try testing.expect(c != null);

    try testing.expectEqualStrings("node-a.cluster.local", a.?.host);
    try testing.expectEqual(@as(u16, 3142), b.?.port);
    try testing.expectEqual(@as(u32, 30), c.?.node_id);

    // All start active
    try testing.expectEqual(NodeStatus.active, a.?.status);
    try testing.expectEqual(NodeStatus.active, b.?.status);
    try testing.expectEqual(NodeStatus.active, c.?.status);

    // Marking one inactive does not affect others
    registry.markInactive(20);
    try testing.expectEqual(NodeStatus.active, registry.getNodeInfo(10).?.status);
    try testing.expectEqual(NodeStatus.inactive, registry.getNodeInfo(20).?.status);
    try testing.expectEqual(NodeStatus.active, registry.getNodeInfo(30).?.status);
}
