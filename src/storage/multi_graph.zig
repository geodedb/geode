const std = @import("std");
const Allocator = std.mem.Allocator;
const catalog = @import("catalog.zig");
const storage = @import("interface.zig");

pub const GraphId = u32;

pub const GraphDescriptor = struct {
    id: GraphId,
    name: []const u8,
    owner: []const u8,
    created_at: i64,
    properties: std.StringHashMap([]const u8),
    is_default: bool = false,
};

pub const GraphIsolationLevel = enum {
    read_uncommitted,
    read_committed,
    repeatable_read,
    serializable,
};

pub const GraphNamespace = struct {
    allocator: Allocator,
    id: GraphId,
    name: []u8,
    catalog: *catalog.Catalog,
    storage_backend: storage.StorageBackend,
    isolation_level: GraphIsolationLevel,
    statistics: GraphStatistics,

    const Self = @This();

    pub fn init(
        allocator: Allocator,
        id: GraphId,
        name: []const u8,
        backend: storage.StorageBackend,
    ) !Self {
        const owned_name = try allocator.dupe(u8, name);
        return Self{
            .allocator = allocator,
            .id = id,
            .name = owned_name,
            .catalog = try catalog.Catalog.init(allocator),
            .storage_backend = backend,
            .isolation_level = .read_committed,
            .statistics = GraphStatistics{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
        self.catalog.deinit();
    }

    pub fn getNodeCount(self: *Self) !u64 {
        return self.statistics.node_count;
    }

    pub fn getEdgeCount(self: *Self) !u64 {
        return self.statistics.edge_count;
    }
};

pub const GraphStatistics = struct {
    node_count: u64 = 0,
    edge_count: u64 = 0,
    property_count: u64 = 0,
    label_count: u64 = 0,
    last_updated: i64 = 0,
};

pub const MultiGraphManager = struct {
    allocator: Allocator,
    graphs: std.AutoHashMap(GraphId, *GraphNamespace),
    name_to_id: std.StringHashMap(GraphId),
    next_id: GraphId,
    current_graph: ?GraphId,
    default_graph: ?GraphId,
    metadata_storage: *catalog.Catalog,

    const Self = @This();

    pub fn init(allocator: Allocator, metadata_storage: *catalog.Catalog) !Self {
        return Self{
            .allocator = allocator,
            .graphs = std.AutoHashMap(GraphId, *GraphNamespace).init(allocator),
            .name_to_id = std.StringHashMap(GraphId).init(allocator),
            .next_id = 1,
            .current_graph = null,
            .default_graph = null,
            .metadata_storage = metadata_storage,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.graphs.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.graphs.deinit();
        self.name_to_id.deinit();
    }

    pub fn createGraph(self: *Self, name: []const u8, options: CreateGraphOptions) !GraphId {
        // Check if graph already exists
        if (self.name_to_id.get(name)) |_| {
            return error.GraphAlreadyExists;
        }

        const id = self.next_id;
        self.next_id += 1;

        // Create new graph namespace
        const graph = try self.allocator.create(GraphNamespace);
        graph.* = try GraphNamespace.init(
            self.allocator,
            id,
            name,
            options.storage_backend orelse .inmemory,
        );

        // Set isolation level if specified
        if (options.isolation_level) |level| {
            graph.isolation_level = level;
        }

        // Register graph
        try self.graphs.put(id, graph);
        try self.name_to_id.put(name, id);

        // Set as default if it's the first graph or explicitly requested
        if (self.default_graph == null or options.set_as_default) {
            self.default_graph = id;
        }

        // Persist metadata
        try self.persistGraphMetadata(id, name, options);

        return id;
    }

    pub fn dropGraph(self: *Self, name: []const u8, options: DropGraphOptions) !void {
        const id = self.name_to_id.get(name) orelse return error.GraphNotFound;

        // Prevent dropping the current graph unless forced
        if (self.current_graph) |current| {
            if (current == id and !options.force) {
                return error.CannotDropCurrentGraph;
            }
        }

        // Prevent dropping the default graph unless forced
        if (self.default_graph) |default| {
            if (default == id and !options.force) {
                return error.CannotDropDefaultGraph;
            }
        }

        // Check for dependent objects unless cascade is specified
        if (!options.cascade) {
            const graph = self.graphs.get(id) orelse return error.GraphNotFound;
            if (try graph.getNodeCount() > 0 or try graph.getEdgeCount() > 0) {
                return error.GraphNotEmpty;
            }
        }

        // Remove graph
        if (self.graphs.fetchRemove(id)) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
        }
        _ = self.name_to_id.remove(name);

        // Update current/default if necessary
        if (self.current_graph) |current| {
            if (current == id) {
                self.current_graph = self.default_graph;
            }
        }
        if (self.default_graph) |default| {
            if (default == id) {
                self.default_graph = null;
            }
        }

        // Remove metadata
        try self.removeGraphMetadata(id);
    }

    pub fn useGraph(self: *Self, name: []const u8) !void {
        const id = self.name_to_id.get(name) orelse return error.GraphNotFound;
        self.current_graph = id;
    }

    pub fn getCurrentGraph(self: *Self) !*GraphNamespace {
        const id = self.current_graph orelse self.default_graph orelse return error.NoGraphSelected;
        return self.graphs.get(id) orelse return error.GraphNotFound;
    }

    pub fn getGraph(self: *Self, name: []const u8) !*GraphNamespace {
        const id = self.name_to_id.get(name) orelse return error.GraphNotFound;
        return self.graphs.get(id) orelse return error.GraphNotFound;
    }

    pub fn listGraphs(self: *Self, allocator: Allocator) ![]GraphDescriptor {
        var list = std.ArrayList(GraphDescriptor){};
        defer list.deinit();

        var it = self.graphs.iterator();
        while (it.next()) |entry| {
            const graph = entry.value_ptr.*;
            const descriptor = GraphDescriptor{
                .id = entry.key_ptr.*,
                .name = graph.name,
                .owner = "system", // TODO: implement proper ownership
                .created_at = std.time.milliTimestamp(),
                .properties = std.StringHashMap([]const u8).init(allocator),
                .is_default = self.default_graph == entry.key_ptr.*,
            };
            try list.append(descriptor);
        }

        return list.toOwnedSlice();
    }

    fn persistGraphMetadata(self: *Self, id: GraphId, name: []const u8, options: CreateGraphOptions) !void {
        _ = self;
        _ = id;
        _ = name;
        _ = options;
        // TODO: Persist to catalog
    }

    fn removeGraphMetadata(self: *Self, id: GraphId) !void {
        _ = self;
        _ = id;
        // TODO: Remove from catalog
    }
};

pub const CreateGraphOptions = struct {
    storage_backend: ?storage.StorageBackend = null,
    isolation_level: ?GraphIsolationLevel = null,
    set_as_default: bool = false,
    properties: ?std.StringHashMap([]const u8) = null,
};

pub const DropGraphOptions = struct {
    cascade: bool = false,
    force: bool = false,
};

// GQL statement implementations
pub const CreateGraphStatement = struct {
    name: []const u8,
    if_not_exists: bool = false,
    options: CreateGraphOptions = .{},
};

pub const DropGraphStatement = struct {
    name: []const u8,
    if_exists: bool = false,
    options: DropGraphOptions = .{},
};

pub const UseGraphStatement = struct {
    name: []const u8,
};

pub const ShowGraphsStatement = struct {
    filter: ?[]const u8 = null,
};

test "multi-graph creation and management" {
    const allocator = std.testing.allocator;

    var meta_catalog = try catalog.Catalog.init(allocator);
    defer meta_catalog.deinit();

    var mgr = try MultiGraphManager.init(allocator, &meta_catalog);
    defer mgr.deinit();

    // Create graphs
    const graph1_id = try mgr.createGraph("graph1", .{});
    const graph2_id = try mgr.createGraph("graph2", .{});

    try std.testing.expect(graph1_id != graph2_id);

    // Use graph
    try mgr.useGraph("graph1");
    const current = try mgr.getCurrentGraph();
    try std.testing.expectEqualStrings("graph1", current.name);

    // List graphs
    const graphs = try mgr.listGraphs(allocator);
    defer allocator.free(graphs);
    try std.testing.expect(graphs.len == 2);

    // Drop graph
    try mgr.dropGraph("graph2", .{});

    // Verify graph2 is gone
    try std.testing.expectError(error.GraphNotFound, mgr.getGraph("graph2"));
}

test "graph isolation" {
    const allocator = std.testing.allocator;

    var meta_catalog = try catalog.Catalog.init(allocator);
    defer meta_catalog.deinit();

    var mgr = try MultiGraphManager.init(allocator, &meta_catalog);
    defer mgr.deinit();

    // Create graphs with different isolation levels
    _ = try mgr.createGraph("serializable_graph", .{
        .isolation_level = .serializable,
    });

    _ = try mgr.createGraph("read_committed_graph", .{
        .isolation_level = .read_committed,
    });

    const graph1 = try mgr.getGraph("serializable_graph");
    try std.testing.expectEqual(GraphIsolationLevel.serializable, graph1.isolation_level);

    const graph2 = try mgr.getGraph("read_committed_graph");
    try std.testing.expectEqual(GraphIsolationLevel.read_committed, graph2.isolation_level);
}
