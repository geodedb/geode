const std = @import("std");
const testing = std.testing;

// Mock types for testing
const GraphIsolationLevel = enum {
    read_committed,
    repeatable_read,
    serializable,
};

const GraphOptions = struct {
    isolation_level: GraphIsolationLevel = .read_committed,
    set_as_default: bool = false,
};

const DropOptions = struct {
    force: bool = false,
};

const GraphInfo = struct {
    id: u64,
    name: []const u8,
    catalog: *Catalog,
    isolation_level: GraphIsolationLevel,
    is_default: bool,
};

const Catalog = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Catalog {
        return Catalog{ .allocator = allocator };
    }

    pub fn deinit(self: *Catalog) void {
        _ = self;
    }
};

const MultiGraphManager = struct {
    allocator: std.mem.Allocator,
    meta_catalog: *Catalog,
    graphs: std.StringHashMap(GraphInfo),
    current_graph: ?[]const u8,
    next_id: u64,

    pub fn init(allocator: std.mem.Allocator, meta_catalog: *Catalog) !MultiGraphManager {
        return MultiGraphManager{
            .allocator = allocator,
            .meta_catalog = meta_catalog,
            .graphs = std.StringHashMap(GraphInfo).init(allocator),
            .current_graph = null,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *MultiGraphManager) void {
        self.graphs.deinit();
    }

    pub fn createGraph(self: *MultiGraphManager, name: []const u8, options: GraphOptions) !u64 {
        const id = self.next_id;
        self.next_id += 1;

        const graph_catalog = try self.allocator.create(Catalog);
        graph_catalog.* = try Catalog.init(self.allocator);

        try self.graphs.put(name, GraphInfo{
            .id = id,
            .name = name,
            .catalog = graph_catalog,
            .isolation_level = options.isolation_level,
            .is_default = options.set_as_default,
        });

        return id;
    }

    pub fn useGraph(self: *MultiGraphManager, name: []const u8) !void {
        if (!self.graphs.contains(name)) {
            return error.GraphNotFound;
        }
        self.current_graph = name;
    }

    pub fn getCurrentGraph(self: *MultiGraphManager) !GraphInfo {
        if (self.current_graph) |name| {
            return self.graphs.get(name) orelse error.GraphNotFound;
        }
        return error.NoGraphSelected;
    }

    pub fn dropGraph(self: *MultiGraphManager, name: []const u8, options: DropOptions) !void {
        if (self.current_graph) |current| {
            if (std.mem.eql(u8, current, name) and !options.force) {
                return error.CannotDropCurrentGraph;
            }
        }

        if (self.graphs.fetchRemove(name)) |kv| {
            kv.value.catalog.deinit();
            self.allocator.destroy(kv.value.catalog);

            if (self.current_graph) |current| {
                if (std.mem.eql(u8, current, name)) {
                    // Find another graph to switch to
                    var iter = self.graphs.iterator();
                    if (iter.next()) |entry| {
                        self.current_graph = entry.key_ptr.*;
                    } else {
                        self.current_graph = null;
                    }
                }
            }
        } else {
            return error.GraphNotFound;
        }
    }

    pub fn getGraph(self: *MultiGraphManager, name: []const u8) !GraphInfo {
        return self.graphs.get(name) orelse error.GraphNotFound;
    }

    pub fn listGraphs(self: *MultiGraphManager, allocator: std.mem.Allocator) ![]GraphInfo {
        var list = try allocator.alloc(GraphInfo, self.graphs.count());
        var i: usize = 0;
        var iter = self.graphs.iterator();
        while (iter.next()) |entry| : (i += 1) {
            list[i] = entry.value_ptr.*;
        }
        return list;
    }
};

test "E2E: CREATE GRAPH and USE GRAPH" {
    const allocator = testing.allocator;

    var meta_catalog = try Catalog.init(allocator);
    defer meta_catalog.deinit();

    var mgr = try MultiGraphManager.init(allocator, &meta_catalog);
    defer mgr.deinit();

    // CREATE GRAPH social_network
    const social_id = try mgr.createGraph("social_network", .{});

    // CREATE GRAPH analytics
    const analytics_id = try mgr.createGraph("analytics", .{
        .isolation_level = .serializable,
    });

    try testing.expect(social_id != analytics_id);

    // USE GRAPH social_network
    try mgr.useGraph("social_network");
    const current = try mgr.getCurrentGraph();
    try testing.expectEqualStrings("social_network", current.name);

    // USE GRAPH analytics
    try mgr.useGraph("analytics");
    const analytics = try mgr.getCurrentGraph();
    try testing.expectEqual(GraphIsolationLevel.serializable, analytics.isolation_level);
}

test "E2E: DROP GRAPH with isolation" {
    const allocator = testing.allocator;

    var meta_catalog = try Catalog.init(allocator);
    defer meta_catalog.deinit();

    var mgr = try MultiGraphManager.init(allocator, &meta_catalog);
    defer mgr.deinit();

    // Create two graphs
    _ = try mgr.createGraph("temp_graph_1", .{});
    _ = try mgr.createGraph("temp_graph_2", .{});

    // Use temp_graph_1
    try mgr.useGraph("temp_graph_1");

    // Try to drop current graph without force
    try testing.expectError(error.CannotDropCurrentGraph, mgr.dropGraph("temp_graph_1", .{}));

    // Drop with force
    try mgr.dropGraph("temp_graph_1", .{ .force = true });

    // Verify graph is gone
    try testing.expectError(error.GraphNotFound, mgr.getGraph("temp_graph_1"));

    // Current should switch to temp_graph_2 or null
    const current = mgr.getCurrentGraph() catch |err| {
        try testing.expectEqual(error.NoGraphSelected, err);
        return;
    };
    try testing.expectEqualStrings("temp_graph_2", current.name);
}

test "E2E: Graph isolation via DSN selection" {
    const allocator = testing.allocator;

    var meta_catalog = try Catalog.init(allocator);
    defer meta_catalog.deinit();

    var mgr = try MultiGraphManager.init(allocator, &meta_catalog);
    defer mgr.deinit();

    // Create multiple graphs with different data
    _ = try mgr.createGraph("production", .{});
    _ = try mgr.createGraph("staging", .{});
    _ = try mgr.createGraph("development", .{});

    // Simulate DSN-based graph selection
    // DSN: "geode://localhost:7567/production"
    try mgr.useGraph("production");
    const prod_graph = try mgr.getCurrentGraph();

    // DSN: "geode://localhost:7567/staging"
    try mgr.useGraph("staging");
    const staging_graph = try mgr.getCurrentGraph();

    // Verify graphs are isolated
    try testing.expect(prod_graph.id != staging_graph.id);
    try testing.expect(prod_graph.catalog != staging_graph.catalog);
}

test "E2E: SHOW GRAPHS listing" {
    const allocator = testing.allocator;

    var meta_catalog = try Catalog.init(allocator);
    defer meta_catalog.deinit();

    var mgr = try MultiGraphManager.init(allocator, &meta_catalog);
    defer mgr.deinit();

    // Create several graphs
    _ = try mgr.createGraph("customers", .{});
    _ = try mgr.createGraph("products", .{});
    _ = try mgr.createGraph("orders", .{ .set_as_default = true });

    // List all graphs
    const graphs = try mgr.listGraphs(allocator);
    defer allocator.free(graphs);

    try testing.expectEqual(@as(usize, 3), graphs.len);

    // Find default graph
    var found_default = false;
    for (graphs) |g| {
        if (g.is_default) {
            try testing.expectEqualStrings("orders", g.name);
            found_default = true;
        }
    }
    try testing.expect(found_default);
}
