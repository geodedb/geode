const std = @import("std");

// CANARY: REQ=REQ-GQL-052; FEATURE="Federation"; ASPECT=FederationRouter; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_052_FederationRouterUnsupported; OWNER=dist; UPDATED=2025-09-21

pub const RouteStatus = enum {
    ok,
    unsupported,
    err,
};

pub const ShardTarget = struct {
    id: u32,
    addr: []const u8,
};

pub const QueryRoute = struct {
    original: []const u8,
    shards: []ShardTarget,
};

pub const FederationRouter = struct {
    allocator: std.mem.Allocator,
    enabled: bool,

    pub fn init(allocator: std.mem.Allocator, enabled: bool) FederationRouter {
        return .{ .allocator = allocator, .enabled = enabled };
    }

    pub fn deinit(self: *FederationRouter) void {
        _ = self;
    }

    pub fn route(self: *FederationRouter, gql: []const u8) !RouteStatus {
        _ = gql;
        if (!self.enabled) return RouteStatus.unsupported;
        // For now even if enabled we still signal unsupported pending implementation
        return RouteStatus.unsupported;
    }
};
