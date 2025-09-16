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
        
        // Load catalog from page 0 (reserved for catalog)
        self.catalog_page_id = 0;
        const catalog_page = try self.page_manager.getPage(0);
        try self.deserializeCatalog(catalog_page);
    }
    
    /// Save catalog to persistent storage
    pub fn save(self: *StorageCatalog) !void {
        if (self.catalog_page_id == null) {
            // Allocate catalog page
            self.catalog_page_id = try self.page_manager.allocatePage();
        }
        
        const catalog_page = try self.page_manager.getPage(self.catalog_page_id.?);
        try self.serializeCatalog(catalog_page);
        try self.page_manager.flushPage(self.catalog_page_id.?);
    }
    
    fn createCatalog(self: *StorageCatalog) !void {
        // Create initial catalog page
        self.catalog_page_id = try self.page_manager.allocatePage();
        try self.save();
    }
    
    fn serializeCatalog(self: *StorageCatalog, page: []u8) !void {
        // Simple serialization format for catalog metadata
        // Format: [table_count:u32][table_entries...][index_count:u32][index_entries...]
        var offset: usize = 0;
        
        // Write table count
        const table_count: u32 = @intCast(self.tables.count());
        std.mem.writeInt(u32, page[offset..offset+4], table_count, .little);
        offset += 4;
        
        // Write table entries (simplified - just names and page IDs for now)
        var table_iter = self.tables.iterator();
        while (table_iter.next()) |entry| {
            const name = entry.value_ptr.name;
            const name_len: u32 = @intCast(name.len);
            
            // Write name length and name
            std.mem.writeInt(u32, page[offset..offset+4], name_len, .little);
            offset += 4;
            @memcpy(page[offset..offset+name.len], name);
            offset += name.len;
            
            // Write root page ID
            std.mem.writeInt(u32, page[offset..offset+4], entry.value_ptr.root_page_id, .little);
            offset += 4;
        }
        
        // Write index count (placeholder)
        const index_count: u32 = @intCast(self.indexes.count());
        std.mem.writeInt(u32, page[offset..offset+4], index_count, .little);
        offset += 4;
        
        // Mark remaining space as unused
        @memset(page[offset..], 0);
    }
    
    fn deserializeCatalog(self: *StorageCatalog, page: []const u8) !void {
        var offset: usize = 0;
        
        // Read table count
        const table_count = std.mem.readInt(u32, page[offset..offset+4], .little);
        offset += 4;
        
        // Read table entries
        for (0..table_count) |_| {
            // Read name length and name
            const name_len = std.mem.readInt(u32, page[offset..offset+4], .little);
            offset += 4;
            
            const name = try self.allocator.dupe(u8, page[offset..offset+name_len]);
            offset += name_len;
            
            // Read root page ID
            const root_page_id = std.mem.readInt(u32, page[offset..offset+4], .little);
            offset += 4;
            
            // Create minimal table metadata
            const table_meta = TableMetadata{
                .name = name,
                .columns = &.{}, // Empty for now
                .primary_key = null,
                .root_page_id = root_page_id,
                .row_count = 0,
                .created_at = 0,
                .modified_at = 0,
            };
            
            try self.tables.put(name, table_meta);
        }
        
        // Read index count (placeholder)
        const index_count = std.mem.readInt(u32, page[offset..offset+4], .little);
        _ = index_count; // Unused for now
    }
    
    /// Create a new table in the catalog
    pub fn createTable(self: *StorageCatalog, name: []const u8, columns: []const TableMetadata.ColumnMetadata) !void {
        if (self.tables.contains(name)) {
            return error.TableAlreadyExists;
        }
        
        const root_page_id = try self.page_manager.allocatePage();
        const table_name = try self.allocator.dupe(u8, name);
        const table_columns = try self.allocator.dupe(TableMetadata.ColumnMetadata, columns);
        
        // Duplicate column metadata strings
        for (table_columns) |*col| {
            col.name = try self.allocator.dupe(u8, col.name);
            col.type_name = try self.allocator.dupe(u8, col.type_name);
            if (col.default_value) |default| {
                col.default_value = try self.allocator.dupe(u8, default);
            }
        }
        
        const table_meta = TableMetadata{
            .name = table_name,
            .columns = table_columns,
            .primary_key = null,
            .root_page_id = root_page_id,
            .row_count = 0,
            .created_at = std.time.timestamp(),
            .modified_at = std.time.timestamp(),
        };
        
        try self.tables.put(table_name, table_meta);
        try self.save();
    }
    
    /// Drop a table from the catalog
    pub fn dropTable(self: *StorageCatalog, name: []const u8) !void {
        if (!self.tables.contains(name)) {
            return error.TableNotFound;
        }
        
        // Get table metadata to free resources
        const table_meta = self.tables.get(name).?;
        
        // Free the table's root page
        try self.page_manager.freePage(table_meta.root_page_id);
        
        // Remove from catalog
        _ = self.tables.remove(name);
        try self.save();
    }
    
    /// Get table metadata
    pub fn getTable(self: *StorageCatalog, name: []const u8) ?TableMetadata {
        return self.tables.get(name);
    }
    
    /// Create an index
    pub fn createIndex(self: *StorageCatalog, name: []const u8, table_name: []const u8, columns: []const []const u8, unique: bool) !void {
        if (self.indexes.contains(name)) {
            return error.IndexAlreadyExists;
        }
        
        if (!self.tables.contains(table_name)) {
            return error.TableNotFound;
        }
        
        const root_page_id = try self.page_manager.allocatePage();
        const index_name = try self.allocator.dupe(u8, name);
        const index_table_name = try self.allocator.dupe(u8, table_name);
        const index_columns = try self.allocator.dupe([]const u8, columns);
        
        // Duplicate column name strings
        for (index_columns) |*col| {
            col.* = try self.allocator.dupe(u8, col.*);
        }
        
        const index_meta = IndexMetadata{
            .name = index_name,
            .table_name = index_table_name,
            .columns = index_columns,
            .unique = unique,
            .root_page_id = root_page_id,
            .created_at = std.time.timestamp(),
        };
        
        try self.indexes.put(index_name, index_meta);
        try self.save();
    }
    
    /// Get index metadata
    pub fn getIndex(self: *StorageCatalog, name: []const u8) ?IndexMetadata {
        return self.indexes.get(name);
    }
};
