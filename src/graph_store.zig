const std = @import("std");

// Simple graph store with file-based persistence for testing
// Real implementation would use proper storage engine

pub const Node = struct {
    id: u64,
    labels: [][]const u8,
    properties: std.StringHashMap(PropertyValue),
};

pub const Edge = struct {
    id: u64,
    from_id: u64,
    to_id: u64,
    label: []const u8,
    properties: std.StringHashMap(PropertyValue),
};

pub const PropertyValue = union(enum) {
    String: []const u8,
    Int: i64,
    Float: f64,
    Bool: bool,
    Null,
};

pub const GraphStore = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMap(u64, Node),
    edges: std.AutoHashMap(u64, Edge),
    next_node_id: u64,
    next_edge_id: u64,

    pub fn init(allocator: std.mem.Allocator) GraphStore {
        var store = GraphStore{
            .allocator = allocator,
            .nodes = std.AutoHashMap(u64, Node).init(allocator),
            .edges = std.AutoHashMap(u64, Edge).init(allocator),
            .next_node_id = 1,
            .next_edge_id = 1,
        };
        // Load persistent data on initialization
        store.loadFromFile() catch {};
        return store;
    }

    pub fn deinit(self: *GraphStore) void {
        // Free all nodes
        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            entry.value_ptr.properties.deinit();
            self.allocator.free(entry.value_ptr.labels);
        }
        self.nodes.deinit();
        
        // Free all edges
        var edge_iter = self.edges.iterator();
        while (edge_iter.next()) |entry| {
            entry.value_ptr.properties.deinit();
        }
        self.edges.deinit();
    }
    
    pub fn clearNodes(self: *GraphStore) void {
        // Clear all nodes - don't free memory since we don't know which allocator was used
        self.nodes.clearRetainingCapacity();
        self.next_node_id = 1;
    }

    pub fn createNode(self: *GraphStore, labels: [][]const u8) !u64 {
        const id = self.next_node_id;
        self.next_node_id += 1;
        
        const labels_copy = try self.allocator.alloc([]const u8, labels.len);
        for (labels, 0..) |label, i| {
            labels_copy[i] = try self.allocator.dupe(u8, label);
        }
        
        const node = Node{
            .id = id,
            .labels = labels_copy,
            .properties = std.StringHashMap(PropertyValue).init(self.allocator),
        };
        
        try self.nodes.put(id, node);
        
        // Save to persistent storage
        self.saveToFile() catch {};
        
        return id;
    }
    
    pub fn setNodeProperty(self: *GraphStore, node_id: u64, key: []const u8, value: PropertyValue) !void {
        if (self.nodes.getPtr(node_id)) |node| {
            const key_copy = try self.allocator.dupe(u8, key);
            // Also duplicate string values to ensure they persist
            const value_copy = switch (value) {
                .String => |s| PropertyValue{ .String = try self.allocator.dupe(u8, s) },
                else => value,
            };
            try node.properties.put(key_copy, value_copy);
            
            // Save to persistent storage
            self.saveToFile() catch {};
        }
    }
    
    pub fn getNodeProperty(self: *GraphStore, node_id: u64, key: []const u8) ?PropertyValue {
        if (self.nodes.get(node_id)) |node| {
            return node.properties.get(key);
        }
        return null;
    }

    pub fn getAllNodes(self: *GraphStore) []Node {
        var result = self.allocator.alloc(Node, self.nodes.count()) catch return &.{};
        var iter = self.nodes.valueIterator();
        var i: usize = 0;
        while (iter.next()) |node| {
            result[i] = node.*;
            i += 1;
        }
        return result;
    }

    pub fn getNodeCount(self: *GraphStore) usize {
        return self.nodes.count();
    }
    
    // Simple file-based persistence for testing
    fn saveToFile(self: *GraphStore) !void {
        const file = try std.fs.cwd().createFile("/tmp/geode_graph_store.dat", .{});
        defer file.close();
        
        // Simple format: just save node count and next_id
        var buf: [16]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], self.next_node_id, .little);
        std.mem.writeInt(u64, buf[8..16], self.nodes.count(), .little);
        _ = try file.write(&buf);
    }
    
    fn loadFromFile(self: *GraphStore) !void {
        const file = std.fs.cwd().openFile("/tmp/geode_graph_store.dat", .{}) catch return;
        defer file.close();
        
        // Read saved state
        var buf: [16]u8 = undefined;
        const bytes_read = try file.read(&buf);
        if (bytes_read < 16) return;
        
        const saved_next_id = std.mem.readInt(u64, buf[0..8], .little);
        const saved_node_count = std.mem.readInt(u64, buf[8..16], .little);
        
        // Recreate nodes with empty labels for now (simple persistence)
        self.next_node_id = saved_next_id;
        var i: u64 = 1;
        while (i < saved_next_id) : (i += 1) {
            if (self.nodes.count() >= saved_node_count) break;
            
            const node = Node{
                .id = i,
                .labels = try self.allocator.alloc([]const u8, 0),
                .properties = std.StringHashMap(PropertyValue).init(self.allocator),
            };
            try self.nodes.put(i, node);
        }
    }
};

// Global instance that persists across queries
var global_store: ?GraphStore = null;
var global_arena: ?std.heap.ArenaAllocator = null;
var initialized = false;

pub fn getGlobalStore(allocator: std.mem.Allocator) *GraphStore {
    _ = allocator;
    // Initialize once with a persistent allocator
    if (!initialized) {
        // Use a persistent arena allocator for the global store
        global_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        global_store = GraphStore.init(global_arena.?.allocator());
        initialized = true;
    }
    return &global_store.?;
}

pub fn deinitGlobalStore() void {
    if (initialized and global_store != null) {
        global_store.?.deinit();
        global_store = null;
        if (global_arena != null) {
            global_arena.?.deinit();
            global_arena = null;
        }
        initialized = false;
    }
}