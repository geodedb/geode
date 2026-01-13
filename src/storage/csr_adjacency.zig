const std = @import("std");
const storage = @import("storage_page_manager");

/// Compressed Sparse Row (CSR) adjacency list storage for graph traversal
pub const CSRAdjacency = struct {
    allocator: std.mem.Allocator,
    page_manager: *storage.PageManager,

    // CSR format: offsets[i] points to start of adjacency list for node i
    // neighbors contains all adjacency data in compressed format
    offsets: std.ArrayList(u64), // Offset into neighbors array for each node
    neighbors: std.ArrayList(EdgeEntry), // Compressed adjacency data
    node_count: u64,
    edge_count: u64,

    // Persistent storage
    metadata_page_id: ?u32,
    offsets_page_id: ?u32,
    neighbors_page_id: ?u32,

    pub const EdgeEntry = struct {
        target_node: u64,
        edge_id: u64,
        edge_type: u32, // Label/type identifier
        properties_offset: u64, // Offset into property storage
    };

    pub const NodeNeighbors = struct {
        node_id: u64,
        neighbors: []const EdgeEntry,
    };

    pub fn init(allocator: std.mem.Allocator, page_manager: *storage.PageManager) CSRAdjacency {
        return .{
            .allocator = allocator,
            .page_manager = page_manager,
            .offsets = std.ArrayList(u64){},
            .neighbors = std.ArrayList(EdgeEntry){},
            .node_count = 0,
            .edge_count = 0,
            .metadata_page_id = null,
            .offsets_page_id = null,
            .neighbors_page_id = null,
        };
    }

    pub fn deinit(self: *CSRAdjacency) void {
        self.offsets.deinit();
        self.neighbors.deinit();
    }

    /// Load CSR data from persistent storage
    pub fn load(self: *CSRAdjacency) !void {
        // Try to load metadata page
        if (self.page_manager.pages.items.len < 3) {
            // Not enough pages for CSR data
            return;
        }

        // Load from reserved pages (1=metadata, 2=offsets, 3=neighbors)
        self.metadata_page_id = 1;
        self.offsets_page_id = 2;
        self.neighbors_page_id = 3;

        try self.loadMetadata();
        try self.loadOffsets();
        try self.loadNeighbors();
    }

    /// Save CSR data to persistent storage
    pub fn save(self: *CSRAdjacency) !void {
        // Allocate pages if needed
        if (self.metadata_page_id == null) {
            self.metadata_page_id = try self.page_manager.allocatePage();
        }
        if (self.offsets_page_id == null) {
            self.offsets_page_id = try self.page_manager.allocatePage();
        }
        if (self.neighbors_page_id == null) {
            self.neighbors_page_id = try self.page_manager.allocatePage();
        }

        try self.saveMetadata();
        try self.saveOffsets();
        try self.saveNeighbors();
    }

    fn loadMetadata(self: *CSRAdjacency) !void {
        const page = try self.page_manager.getPage(self.metadata_page_id.?);

        self.node_count = std.mem.readInt(u64, page[0..8], .little);
        self.edge_count = std.mem.readInt(u64, page[8..16], .little);
    }

    fn saveMetadata(self: *CSRAdjacency) !void {
        const page = try self.page_manager.getPage(self.metadata_page_id.?);

        std.mem.writeInt(u64, page[0..8], self.node_count, .little);
        std.mem.writeInt(u64, page[8..16], self.edge_count, .little);

        try self.page_manager.flushPage(self.metadata_page_id.?);
    }

    fn loadOffsets(self: *CSRAdjacency) !void {
        const page = try self.page_manager.getPage(self.offsets_page_id.?);

        // Read offsets array
        const offsets_size = self.node_count + 1; // +1 for sentinel
        try self.offsets.resize(offsets_size);

        const bytes_per_offset = @sizeOf(u64);
        for (0..offsets_size) |i| {
            const offset = i * bytes_per_offset;
            self.offsets.items[i] = std.mem.readInt(u64, page[offset .. offset + bytes_per_offset], .little);
        }
    }

    fn saveOffsets(self: *CSRAdjacency) !void {
        const page = try self.page_manager.getPage(self.offsets_page_id.?);

        const bytes_per_offset = @sizeOf(u64);
        for (self.offsets.items, 0..) |offset_val, i| {
            const offset = i * bytes_per_offset;
            std.mem.writeInt(u64, page[offset .. offset + bytes_per_offset], offset_val, .little);
        }

        try self.page_manager.flushPage(self.offsets_page_id.?);
    }

    fn loadNeighbors(self: *CSRAdjacency) !void {
        const page = try self.page_manager.getPage(self.neighbors_page_id.?);

        // Read neighbors array
        try self.neighbors.resize(self.edge_count);

        const bytes_per_entry = @sizeOf(EdgeEntry);
        for (0..self.edge_count) |i| {
            const offset = i * bytes_per_entry;
            const entry_bytes = page[offset .. offset + bytes_per_entry];

            self.neighbors.items[i] = EdgeEntry{
                .target_node = std.mem.readInt(u64, entry_bytes[0..8], .little),
                .edge_id = std.mem.readInt(u64, entry_bytes[8..16], .little),
                .edge_type = std.mem.readInt(u32, entry_bytes[16..20], .little),
                .properties_offset = std.mem.readInt(u64, entry_bytes[20..28], .little),
            };
        }
    }

    fn saveNeighbors(self: *CSRAdjacency) !void {
        const page = try self.page_manager.getPage(self.neighbors_page_id.?);

        const bytes_per_entry = @sizeOf(EdgeEntry);
        for (self.neighbors.items, 0..) |entry, i| {
            const offset = i * bytes_per_entry;
            const entry_bytes = page[offset .. offset + bytes_per_entry];

            std.mem.writeInt(u64, entry_bytes[0..8], entry.target_node, .little);
            std.mem.writeInt(u64, entry_bytes[8..16], entry.edge_id, .little);
            std.mem.writeInt(u32, entry_bytes[16..20], entry.edge_type, .little);
            std.mem.writeInt(u64, entry_bytes[20..28], entry.properties_offset, .little);
        }

        try self.page_manager.flushPage(self.neighbors_page_id.?);
    }

    // GAP-0123/GAP-0136: Edge input structure with property offset support
    // CANARY: REQ=REQ-CSR-PROP-001; FEATURE="CSR Property Storage"; ASPECT=DataIntegrity; STATUS=IMPL; UPDATED=2026-01-13
    pub const EdgeInput = struct {
        from: u64,
        to: u64,
        edge_id: u64,
        edge_type: u32,
        properties_offset: u64 = 0, // Default to 0 for backwards compatibility
    };

    /// Build CSR from edge list (typically done during bulk loading)
    /// GAP-0123/GAP-0136: Now correctly stores property offsets
    pub fn buildFromEdges(self: *CSRAdjacency, edges: []const EdgeInput) !void {
        if (edges.len == 0) return;

        // Find max node ID to determine array size
        var max_node: u64 = 0;
        for (edges) |edge| {
            max_node = @max(max_node, @max(edge.from, edge.to));
        }

        self.node_count = max_node + 1;
        self.edge_count = edges.len;

        // Initialize offsets array
        try self.offsets.resize(self.node_count + 1);
        @memset(self.offsets.items, 0);

        // Count outgoing edges per node
        for (edges) |edge| {
            self.offsets.items[edge.from + 1] += 1;
        }

        // Convert counts to offsets (prefix sum)
        for (1..self.offsets.items.len) |i| {
            self.offsets.items[i] += self.offsets.items[i - 1];
        }

        // Build neighbors array
        try self.neighbors.resize(self.edge_count);
        var temp_offsets = try self.allocator.dupe(u64, self.offsets.items);
        defer self.allocator.free(temp_offsets);

        for (edges) |edge| {
            const pos = temp_offsets[edge.from];
            // GAP-0123/GAP-0136: Store actual property offset from input
            // CANARY: REQ=REQ-CSR-PROP-002; FEATURE="CSR Property Offset"; ASPECT=DataIntegrity; STATUS=IMPL; UPDATED=2026-01-13
            self.neighbors.items[pos] = EdgeEntry{
                .target_node = edge.to,
                .edge_id = edge.edge_id,
                .edge_type = edge.edge_type,
                .properties_offset = edge.properties_offset,
            };
            temp_offsets[edge.from] += 1;
        }

        try self.save();
    }

    /// Get neighbors of a node
    pub fn getNeighbors(self: *const CSRAdjacency, node_id: u64) ?NodeNeighbors {
        if (node_id >= self.node_count) return null;

        const start = self.offsets.items[node_id];
        const end = self.offsets.items[node_id + 1];

        return NodeNeighbors{
            .node_id = node_id,
            .neighbors = self.neighbors.items[start..end],
        };
    }

    /// Get degree (number of outgoing edges) of a node
    pub fn getDegree(self: *const CSRAdjacency, node_id: u64) u64 {
        if (node_id >= self.node_count) return 0;

        return self.offsets.items[node_id + 1] - self.offsets.items[node_id];
    }

    /// Add a single edge (less efficient than bulk loading)
    /// GAP-0123/GAP-0136: Now supports properties_offset parameter
    pub fn addEdge(self: *CSRAdjacency, from: u64, to: u64, edge_id: u64, edge_type: u32, properties_offset: u64) !void {
        // For simplicity, rebuild the entire CSR structure
        // In a production system, you'd want incremental updates

        // Collect existing edges - preserving their properties_offset
        // CANARY: REQ=REQ-CSR-PROP-003; FEATURE="CSR Property Preservation"; ASPECT=DataIntegrity; STATUS=IMPL; UPDATED=2026-01-13
        var edges = std.ArrayList(EdgeInput).init(self.allocator);
        defer edges.deinit();

        for (0..self.node_count) |node_id| {
            if (self.getNeighbors(@intCast(node_id))) |neighbors| {
                for (neighbors.neighbors) |neighbor| {
                    try edges.append(.{
                        .from = @intCast(node_id),
                        .to = neighbor.target_node,
                        .edge_id = neighbor.edge_id,
                        .edge_type = neighbor.edge_type,
                        .properties_offset = neighbor.properties_offset, // Preserve existing offset
                    });
                }
            }
        }

        // Add new edge with its properties_offset
        try edges.append(.{ .from = from, .to = to, .edge_id = edge_id, .edge_type = edge_type, .properties_offset = properties_offset });

        // Rebuild CSR
        try self.buildFromEdges(edges.items);
    }

    /// Add a single edge without properties (backwards compatibility)
    pub fn addEdgeSimple(self: *CSRAdjacency, from: u64, to: u64, edge_id: u64, edge_type: u32) !void {
        try self.addEdge(from, to, edge_id, edge_type, 0);
    }
};

test "CSR adjacency: build and query" {
    const allocator = std.testing.allocator;

    // Create mock page manager
    var page_manager = storage.PageManager.init(allocator);
    defer page_manager.deinit();

    var csr = CSRAdjacency.init(allocator, &page_manager);
    defer csr.deinit();

    // GAP-0123/GAP-0136: Build CSR from edge list with property offsets
    const edges = [_]CSRAdjacency.EdgeInput{
        .{ .from = 0, .to = 1, .edge_id = 101, .edge_type = 1, .properties_offset = 1000 },
        .{ .from = 0, .to = 2, .edge_id = 102, .edge_type = 1, .properties_offset = 2000 },
        .{ .from = 1, .to = 2, .edge_id = 103, .edge_type = 2, .properties_offset = 3000 },
        .{ .from = 2, .to = 0, .edge_id = 104, .edge_type = 1, .properties_offset = 4000 },
    };

    try csr.buildFromEdges(&edges);

    // Test neighbor queries
    const neighbors_0 = csr.getNeighbors(0).?;
    try std.testing.expect(neighbors_0.neighbors.len == 2);
    try std.testing.expect(neighbors_0.neighbors[0].target_node == 1);
    try std.testing.expect(neighbors_0.neighbors[1].target_node == 2);
    // GAP-0123/GAP-0136: Verify property offsets are stored correctly
    try std.testing.expect(neighbors_0.neighbors[0].properties_offset == 1000);
    try std.testing.expect(neighbors_0.neighbors[1].properties_offset == 2000);

    const neighbors_1 = csr.getNeighbors(1).?;
    try std.testing.expect(neighbors_1.neighbors.len == 1);
    try std.testing.expect(neighbors_1.neighbors[0].target_node == 2);
    try std.testing.expect(neighbors_1.neighbors[0].properties_offset == 3000);

    // Test degree queries
    try std.testing.expect(csr.getDegree(0) == 2);
    try std.testing.expect(csr.getDegree(1) == 1);
    try std.testing.expect(csr.getDegree(2) == 1);
}

test "CSR adjacency: persistence" {
    const allocator = std.testing.allocator;

    // Create mock page manager with enough pages
    var page_manager = storage.PageManager.init(allocator);
    defer page_manager.deinit();

    // Allocate pages for CSR storage
    _ = try page_manager.allocatePage(); // page 0
    _ = try page_manager.allocatePage(); // page 1 (metadata)
    _ = try page_manager.allocatePage(); // page 2 (offsets)
    _ = try page_manager.allocatePage(); // page 3 (neighbors)

    var csr = CSRAdjacency.init(allocator, &page_manager);
    defer csr.deinit();

    // GAP-0123/GAP-0136: Build and save CSR with property offsets
    const edges = [_]CSRAdjacency.EdgeInput{
        .{ .from = 0, .to = 1, .edge_id = 101, .edge_type = 1, .properties_offset = 5000 },
        .{ .from = 1, .to = 0, .edge_id = 102, .edge_type = 1, .properties_offset = 6000 },
    };

    try csr.buildFromEdges(&edges);

    // Create new CSR instance and load from storage
    var csr2 = CSRAdjacency.init(allocator, &page_manager);
    defer csr2.deinit();

    try csr2.load();

    // Verify loaded data
    try std.testing.expect(csr2.node_count == csr.node_count);
    try std.testing.expect(csr2.edge_count == csr.edge_count);

    const neighbors_0 = csr2.getNeighbors(0).?;
    try std.testing.expect(neighbors_0.neighbors.len == 1);
    try std.testing.expect(neighbors_0.neighbors[0].target_node == 1);
}
