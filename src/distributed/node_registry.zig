// CANARY: REQ=REQ-DIST-REGISTRY-001; FEATURE="Node Registry"; ASPECT=NodeLookup; STATUS=TESTED; TEST=TestCANARY_REQ_DIST_REGISTRY_001_NodeCRUD; OWNER=distributed; UPDATED=2026-06-11

//! Canonical NodeRegistry — hashmap-based node tracking for the distributed
//! query transport. Extracted from query_transport.zig (GAP-0889) so the
//! standalone unit tests (test_query_transport_node_registry.zig) exercise
//! the REAL type instead of a drift-prone inline copy. stdlib-only: no QUIC
//! or protobuf dependencies.

const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp was removed.
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

/// Node registry for distributed cluster - tracks node addresses
pub const NodeRegistry = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMap(u32, NodeInfo),

    pub const NodeInfo = struct {
        node_id: u32,
        host: []const u8,
        port: u16,
        status: NodeStatus,
        last_heartbeat: i64,
    };

    pub const NodeStatus = enum {
        active,
        inactive,
        unknown,
    };

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

test "NodeRegistry: re-registering a node overwrites its address and reactivates it (GAP-0889)" {
    var registry = try NodeRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerNode(7, "old-host.cluster.local", 3141);
    registry.markInactive(7);
    try std.testing.expectEqual(NodeRegistry.NodeStatus.inactive, registry.getNodeInfo(7).?.status);

    // Re-register: address moves, status returns to active (this is the
    // behavior a node restart with a new endpoint relies on).
    try registry.registerNode(7, "new-host.cluster.local", 4242);
    const info = registry.getNodeInfo(7).?;
    try std.testing.expectEqualStrings("new-host.cluster.local", info.host);
    try std.testing.expectEqual(@as(u16, 4242), info.port);
    try std.testing.expectEqual(NodeRegistry.NodeStatus.active, info.status);
}
