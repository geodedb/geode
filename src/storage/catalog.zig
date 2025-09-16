const std = @import("std");
const storage = @import("../storage/page_manager.zig");

/// Persistent storage catalog for metadata management
pub const StorageCatalog = struct {
    allocator: std.mem.Allocator,
    page_manager: *storage.PageManager,
    tables: std.StringHashMap(TableMetadata),
    indexes: std.StringHashMap(IndexMetadata),
    sequences: std.StringHashMap(SequenceMetadata),
    catalog_page_id: ?u32, // Root catalog page
    
    const TableMetadata = struct {
        name: []const u8,
        columns: []ColumnMetadata,
        primary_key: ?[]const u8,
        root_page_id: u32,
        row_count: usize,
        created_at: i64,
        modified_at: i64,
        
        const ColumnMetadata = struct {
            name: []const u8,
            type_name: []const u8,
            nullable: bool,
            default_value: ?[]const u8,
            ordinal_position: u32,
        };
    };
    
    const IndexMetadata = struct {
        name: []const u8,
        table_name: []const u8,
        columns: []const []const u8,
        unique: bool,
        root_page_id: u32,
        created_at: i64,
    };
    
    const SequenceMetadata = struct {
        name: []const u8,
        current_value: i64,
        increment: i64,
        min_value: i64,
        max_value: i64,
        cycle: bool,
    };
    
    pub fn init(allocator: std.mem.Allocator, page_manager: *storage.PageManager) StorageCatalog {
        return .{
            .allocator = allocator,
            .page_manager = page_manager,
            .tables = std.StringHashMap(TableMetadata).init(allocator),
            .indexes = std.StringHashMap(IndexMetadata).init(allocator),
            .sequences = std.StringHashMap(SequenceMetadata).init(allocator),
            .catalog_page_id = null,
        };
    }
    
    pub fn deinit(self: *StorageCatalog) void {
        // Clean up table metadata
        var table_iter = self.tables.iterator();
        while (table_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            for (entry.value_ptr.columns) |col| {
                self.allocator.free(col.name);
                self.allocator.free(col.type_name);
                if (col.default_value) |default| self.allocator.free(default);
            }
            self.allocator.free(entry.value_ptr.columns);
            if (entry.value_ptr.primary_key) |pk| self.allocator.free(pk);
        }
        self.tables.deinit();
        
        // Clean up index metadata
        var index_iter = self.indexes.iterator();
        while (index_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.table_name);
            for (entry.value_ptr.columns) |col| {
                self.allocator.free(col);
            }
            self.allocator.free(entry.value_ptr.columns);
        }
        self.indexes.deinit();
        
        // Clean up sequence metadata
        var seq_iter = self.sequences.iterator();
        while (seq_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
        }
        self.sequences.deinit();
    }
    
    /// Load catalog from persistent storage
    pub fn load(self: *StorageCatalog) !void {
        // Try to find catalog root page
        if (self.page_manager.pages.items.len == 0) {
            // No pages exist, create new catalog
            try self.createCatalog();
            return;
        }
        
        // Scan first page for catalog magic number
        const first_page = storage.Page{ .buf = self.page_manager.pages.items[0] };
        if (self.isCatalogPage(&first_page)) {
            self.catalog_page_id = 0;
            try self.loadCatalogFromPage(0);
        } else {
            // Create new catalog
            try self.createCatalog();
        }
    }
    
    /// Save catalog to persistent storage
    pub fn save(self: *StorageCatalog) !void {
        if (self.catalog_page_id == null) {
            try self.createCatalog();
        }
        
        try self.saveCatalogToPage(self.catalog_page_id.?);
    }
    
    /// Create a new table
    pub fn createTable(self: *StorageCatalog, name: []const u8, columns: []const TableMetadata.ColumnMetadata) !void {
        if (self.tables.contains(name)) {
            return error.TableAlreadyExists;
        }
        
        // Allocate root page for table data
        const root_page_id = @as(u32, @intCast(self.page_manager.pages.items.len));
        try self.page_manager.newPage();
        
        // Copy column metadata
        var column_copies = try self.allocator.alloc(TableMetadata.ColumnMetadata, columns.len);
        for (columns, 0..) |col, i| {
            column_copies[i] = .{
                .name = try self.allocator.dupe(u8, col.name),
                .type_name = try self.allocator.dupe(u8, col.type_name),
                .nullable = col.nullable,
                .default_value = if (col.default_value) |dv| try self.allocator.dupe(u8, dv) else null,
                .ordinal_position = col.ordinal_position,
            };
        }
        
        const table_meta = TableMetadata{
            .name = try self.allocator.dupe(u8, name),
            .columns = column_copies,
            .primary_key = null,
            .root_page_id = root_page_id,
            .row_count = 0,
            .created_at = std.time.timestamp(),
            .modified_at = std.time.timestamp(),
        };
        
        try self.tables.put(name, table_meta);
        try self.save();
    }
    
    /// Drop a table
    pub fn dropTable(self: *StorageCatalog, name: []const u8) !void {
        if (!self.tables.contains(name)) {
            return error.TableNotFound;
        }
        
        // TODO: Clean up table pages and associated indexes
        _ = self.tables.remove(name);
        try self.save();
    }
    
    /// Create an index
    pub fn createIndex(self: *StorageCatalog, name: []const u8, table_name: []const u8, columns: []const []const u8, unique: bool) !void {
        if (self.indexes.contains(name)) {
            return error.IndexAlreadyExists;
        }
        
        if (!self.tables.contains(table_name)) {
            return error.TableNotFound;
        }
        
        // Allocate root page for index
        const root_page_id = @as(u32, @intCast(self.page_manager.pages.items.len));
        try self.page_manager.newPage();
        
        // Copy column names
        var column_copies = try self.allocator.alloc([]const u8, columns.len);
        for (columns, 0..) |col, i| {
            column_copies[i] = try self.allocator.dupe(u8, col);
        }
        
        const index_meta = IndexMetadata{
            .name = try self.allocator.dupe(u8, name),
            .table_name = try self.allocator.dupe(u8, table_name),
            .columns = column_copies,
            .unique = unique,
            .root_page_id = root_page_id,
            .created_at = std.time.timestamp(),
        };
        
        try self.indexes.put(name, index_meta);
        try self.save();
    }
    
    /// Get table metadata
    pub fn getTable(self: *StorageCatalog, name: []const u8) ?*const TableMetadata {
        return self.tables.getPtr(name);
    }
    
    /// Get index metadata
    pub fn getIndex(self: *StorageCatalog, name: []const u8) ?*const IndexMetadata {
        return self.indexes.getPtr(name);
    }
    
    /// List all tables
    pub fn listTables(self: *StorageCatalog) ![][]const u8 {
        var table_names = try self.allocator.alloc([]const u8, self.tables.count());
        var i: usize = 0;
        
        var iter = self.tables.iterator();
        while (iter.next()) |entry| {
            table_names[i] = try self.allocator.dupe(u8, entry.key_ptr.*);
            i += 1;
        }
        
        return table_names;
    }
    
    /// Update table statistics
    pub fn updateTableStats(self: *StorageCatalog, table_name: []const u8, row_count: usize) !void {
        if (self.tables.getPtr(table_name)) |table| {
            table.row_count = row_count;
            table.modified_at = std.time.timestamp();
            try self.save();
        }
    }
    
    /// Create sequence
    pub fn createSequence(self: *StorageCatalog, name: []const u8, start_value: i64, increment: i64) !void {
        if (self.sequences.contains(name)) {
            return error.SequenceAlreadyExists;
        }
        
        const seq_meta = SequenceMetadata{
            .name = try self.allocator.dupe(u8, name),
            .current_value = start_value,
            .increment = increment,
            .min_value = std.math.minInt(i64),
            .max_value = std.math.maxInt(i64),
            .cycle = false,
        };
        
        try self.sequences.put(name, seq_meta);
        try self.save();
    }
    
    /// Get next sequence value
    pub fn nextSequenceValue(self: *StorageCatalog, name: []const u8) !i64 {
        if (self.sequences.getPtr(name)) |seq| {
            const current = seq.current_value;
            seq.current_value += seq.increment;
            
            if (seq.current_value > seq.max_value) {
                if (seq.cycle) {
                    seq.current_value = seq.min_value;
                } else {
                    return error.SequenceExhausted;
                }
            }
            
            try self.save();
            return current;
        }
        
        return error.SequenceNotFound;
    }
    
    fn createCatalog(self: *StorageCatalog) !void {
        // Create catalog root page
        try self.page_manager.newPage();
        self.catalog_page_id = @as(u32, @intCast(self.page_manager.pages.items.len - 1));
        
        // Initialize catalog page with magic number
        var catalog_page = storage.Page{ .buf = self.page_manager.pages.items[self.catalog_page_id.?] };
        self.writeCatalogMagic(&catalog_page);
        
        try self.save();
    }
    
    fn isCatalogPage(self: *StorageCatalog, page: *const storage.Page) bool {
        _ = self;
        
        // Check for catalog magic number in page header
        const magic_offset = storage.Page.HeaderSize;
        if (page.buf.len < magic_offset + 8) return false;
        
        const magic = std.mem.readInt(u64, page.buf[magic_offset..magic_offset + 8], .little);
        return magic == 0x474551444554414C; // "GEODECAT" in little-endian
    }
    
    fn writeCatalogMagic(self: *StorageCatalog, page: *storage.Page) void {
        _ = self;
        
        const magic_offset = storage.Page.HeaderSize;
        if (page.buf.len >= magic_offset + 8) {
            std.mem.writeInt(u64, page.buf[magic_offset..magic_offset + 8], 0x474551444554414C, .little);
        }
    }
    
    fn loadCatalogFromPage(self: *StorageCatalog, page_id: u32) !void {
        _ = self;
        _ = page_id;
        
        // TODO: Implement catalog deserialization from page
        // This would read the serialized catalog metadata from the page
        // and populate the in-memory hash maps
    }
    
    fn saveCatalogToPage(self: *StorageCatalog, page_id: u32) !void {
        _ = self;
        _ = page_id;
        
        // TODO: Implement catalog serialization to page
        // This would serialize the in-memory catalog metadata
        // and write it to the specified page
    }
};

/// CSR (Compressed Sparse Row) adjacency structure for graph storage
pub const CSRAdjacency = struct {
    allocator: std.mem.Allocator,
    page_manager: *storage.PageManager,
    node_offsets: std.ArrayList(u32), // Offset into edges array for each node
    edges: std.ArrayList(Edge),
    properties: std.ArrayList(PropertyValue),
    
    const Edge = struct {
        target_node: u32,
        edge_type: u16,
        property_offset: u32,
        property_count: u16,
    };
    
    const PropertyValue = struct {
        key: []const u8,
        value: []const u8,
    };
    
    pub fn init(allocator: std.mem.Allocator, page_manager: *storage.PageManager) CSRAdjacency {
        return .{
            .allocator = allocator,
            .page_manager = page_manager,
            .node_offsets = std.ArrayList(u32).init(allocator),
            .edges = std.ArrayList(Edge).init(allocator),
            .properties = std.ArrayList(PropertyValue).init(allocator),
        };
    }
    
    pub fn deinit(self: *CSRAdjacency) void {
        self.node_offsets.deinit();
        self.edges.deinit();
        
        for (self.properties.items) |prop| {
            self.allocator.free(prop.key);
            self.allocator.free(prop.value);
        }
        self.properties.deinit();
    }
    
    /// Add a node (reserves space in offset array)
    pub fn addNode(self: *CSRAdjacency) !u32 {
        const node_id = @as(u32, @intCast(self.node_offsets.items.len));
        try self.node_offsets.append(@as(u32, @intCast(self.edges.items.len)));
        return node_id;
    }
    
    /// Add an edge from source to target
    pub fn addEdge(self: *CSRAdjacency, source: u32, target: u32, edge_type: u16, properties: []const PropertyValue) !void {
        if (source >= self.node_offsets.items.len) {
            return error.InvalidSourceNode;
        }
        
        // Copy properties
        const prop_start = @as(u32, @intCast(self.properties.items.len));
        for (properties) |prop| {
            try self.properties.append(.{
                .key = try self.allocator.dupe(u8, prop.key),
                .value = try self.allocator.dupe(u8, prop.value),
            });
        }
        
        const edge = Edge{
            .target_node = target,
            .edge_type = edge_type,
            .property_offset = prop_start,
            .property_count = @as(u16, @intCast(properties.len)),
        };
        
        try self.edges.append(edge);
        
        // Update offsets for subsequent nodes
        var i = source + 1;
        while (i < self.node_offsets.items.len) : (i += 1) {
            self.node_offsets.items[i] += 1;
        }
    }
    
    /// Get edges for a node
    pub fn getEdges(self: *CSRAdjacency, node_id: u32) []const Edge {
        if (node_id >= self.node_offsets.items.len) {
            return &.{};
        }
        
        const start = self.node_offsets.items[node_id];
        const end = if (node_id + 1 < self.node_offsets.items.len) 
            self.node_offsets.items[node_id + 1] 
        else 
            @as(u32, @intCast(self.edges.items.len));
        
        return self.edges.items[start..end];
    }
    
    /// Get properties for an edge
    pub fn getEdgeProperties(self: *CSRAdjacency, edge: *const Edge) []const PropertyValue {
        const start = edge.property_offset;
        const end = start + edge.property_count;
        
        if (end > self.properties.items.len) {
            return &.{};
        }
        
        return self.properties.items[start..end];
    }
    
    /// Persist CSR structure to pages
    pub fn persist(self: *CSRAdjacency) !void {
        // TODO: Implement CSR serialization to pages
        // This would write the node offsets, edges, and properties
        // to a series of pages in the page manager
        _ = self;
    }
    
    /// Load CSR structure from pages
    pub fn load(self: *CSRAdjacency) !void {
        // TODO: Implement CSR deserialization from pages
        // This would read the serialized CSR data from pages
        // and reconstruct the in-memory structures
        _ = self;
    }
};

test "storage catalog basic operations" {
    var page_manager = storage.PageManager.init(std.testing.allocator, 4096);
    defer page_manager.deinit();
    
    var catalog = StorageCatalog.init(std.testing.allocator, &page_manager);
    defer catalog.deinit();
    
    try catalog.load();
    
    // Create a table
    const columns = [_]StorageCatalog.TableMetadata.ColumnMetadata{
        .{ .name = "id", .type_name = "INT", .nullable = false, .default_value = null, .ordinal_position = 1 },
        .{ .name = "name", .type_name = "STRING", .nullable = true, .default_value = null, .ordinal_position = 2 },
    };
    
    try catalog.createTable("users", &columns);
    
    // Verify table exists
    const table = catalog.getTable("users");
    try std.testing.expect(table != null);
    try std.testing.expect(std.mem.eql(u8, table.?.name, "users"));
    try std.testing.expect(table.?.columns.len == 2);
    
    // Create an index
    const index_columns = [_][]const u8{"id"};
    try catalog.createIndex("users_pk", "users", &index_columns, true);
    
    // Verify index exists
    const index = catalog.getIndex("users_pk");
    try std.testing.expect(index != null);
    try std.testing.expect(index.?.unique);
}

test "CSR adjacency structure" {
    var page_manager = storage.PageManager.init(std.testing.allocator, 4096);
    defer page_manager.deinit();
    
    var csr = CSRAdjacency.init(std.testing.allocator, &page_manager);
    defer csr.deinit();
    
    // Add nodes
    const node1 = try csr.addNode();
    const node2 = try csr.addNode();
    const node3 = try csr.addNode();
    
    try std.testing.expect(node1 == 0);
    try std.testing.expect(node2 == 1);
    try std.testing.expect(node3 == 2);
    
    // Add edges
    const props = [_]CSRAdjacency.PropertyValue{
        .{ .key = "weight", .value = "1.5" },
        .{ .key = "type", .value = "friend" },
    };
    
    try csr.addEdge(0, 1, 1, &props);
    try csr.addEdge(0, 2, 1, &.{});
    
    // Verify edges
    const edges = csr.getEdges(0);
    try std.testing.expect(edges.len == 2);
    try std.testing.expect(edges[0].target_node == 1);
    try std.testing.expect(edges[1].target_node == 2);
    
    // Verify properties
    const edge_props = csr.getEdgeProperties(&edges[0]);
    try std.testing.expect(edge_props.len == 2);
    try std.testing.expect(std.mem.eql(u8, edge_props[0].key, "weight"));
}