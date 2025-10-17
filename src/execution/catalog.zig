const std = @import("std");

// CANARY: PERF_PHASE3_RWLOCK - RwLock for concurrent catalog access
// CANARY: REQ=REQ-PERF-PHASE3-001; FEATURE="ConcurrencyOptimization"; ASPECT=CATALOG_LOCK; STATUS=IMPL; OWNER=performance; UPDATED=2025-10-16
// Global catalog for tracking schemas, graphs, and indexes
// Phase 3 optimization: RwLock allows concurrent reads (2-3x concurrent query throughput)
pub var catalog_rwlock = std.Thread.RwLock{};
pub var catalog_initialized = false;
pub var last_catalog_data_dir: ?[]u8 = null;

// IndexInfo stores metadata about an index
// CANARY: REQ=REQ-INDEX-001; FEATURE="IndexManagement"; ASPECT=Catalog; STATUS=IMPLEMENTED; OWNER=storage; UPDATED=2025-10-14
pub const IndexInfo = struct {
    name: []const u8, // Index name (user-provided)
    index_type: []const u8, // btree, hash, fulltext, etc.
    table_name: []const u8, // Label/table name
    columns: [][]const u8, // Property names
};

/// Generate a scoped index key for catalog storage
/// Format: "label:index_name" to allow same index name on different labels
/// This follows database best practices where indexes are scoped per table/label
pub fn getScopedIndexKey(allocator: std.mem.Allocator, label: []const u8, index_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ label, index_name });
}

pub var catalog: struct {
    schemas: std.StringHashMap(void),
    graphs: std.StringHashMap(void),
    indexes: std.StringHashMap(IndexInfo),
} = undefined;

pub fn initCatalog() void {
    const allocator = std.heap.page_allocator;

    // Check if GEODE_DATA_DIR has changed
    const current_data_dir = std.process.getEnvVarOwned(allocator, "GEODE_DATA_DIR") catch |err| blk: {
        if (err == error.EnvironmentVariableNotFound) {
            break :blk allocator.dupe(u8, "/tmp") catch "/tmp";
        }
        break :blk "/tmp";
    };

    // Phase 3: Write lock for catalog initialization/modification
    catalog_rwlock.lock();
    defer catalog_rwlock.unlock();

    // Check if we need to reinitialize due to data dir change
    var needs_reinit = !catalog_initialized;
    if (last_catalog_data_dir) |last_dir| {
        if (!std.mem.eql(u8, current_data_dir, last_dir)) {
            needs_reinit = true;
            // Clean up old catalog
            if (catalog_initialized) {
                catalog.schemas.deinit();
                catalog.graphs.deinit();
                catalog.indexes.deinit();
                catalog_initialized = false;
            }
            allocator.free(last_dir);
        }
    } else {
        needs_reinit = true;
    }

    if (needs_reinit) {
        catalog.schemas = std.StringHashMap(void).init(allocator);
        catalog.graphs = std.StringHashMap(void).init(allocator);
        catalog.indexes = std.StringHashMap(IndexInfo).init(allocator);
        catalog_initialized = true;

        // Update last data dir
        if (last_catalog_data_dir) |last_dir| {
            allocator.free(last_dir);
        }
        last_catalog_data_dir = allocator.dupe(u8, current_data_dir) catch null;

        // Load persisted catalog if it exists
        loadCatalog() catch |err| {
            std.log.warn("Failed to load catalog from disk: {any}", .{err});
        };
    } else {
        allocator.free(current_data_dir);
    }
}

pub fn saveCatalog() !void {
    const allocator = std.heap.page_allocator;

    // Get catalog path from GEODE_DATA_DIR or use default
    const data_dir = std.process.getEnvVarOwned(allocator, "GEODE_DATA_DIR") catch |err| blk: {
        if (err == error.EnvironmentVariableNotFound) {
            break :blk try allocator.dupe(u8, "/tmp");
        }
        return err;
    };
    defer allocator.free(data_dir);

    const catalog_path = try std.fmt.allocPrint(allocator, "{s}/geode_catalog.dat", .{data_dir});
    defer allocator.free(catalog_path);

    const file = try std.fs.cwd().createFile(catalog_path, .{});
    defer file.close();

    // Write header: schema_count, graph_count, index_count
    var header: [12]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(catalog.schemas.count()), .little);
    std.mem.writeInt(u32, header[4..8], @intCast(catalog.graphs.count()), .little);
    std.mem.writeInt(u32, header[8..12], @intCast(catalog.indexes.count()), .little);
    _ = try file.write(&header);

    // Write schemas (just names)
    var schema_iter = catalog.schemas.iterator();
    while (schema_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(name.len), .little);
        _ = try file.write(&len_buf);
        _ = try file.write(name);
    }

    // Write graphs (just names)
    var graph_iter = catalog.graphs.iterator();
    while (graph_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(name.len), .little);
        _ = try file.write(&len_buf);
        _ = try file.write(name);
    }

    // Write indexes
    var index_iter = catalog.indexes.iterator();
    while (index_iter.next()) |entry| {
        const index_info = entry.value_ptr.*;

        // Write index name
        var name_len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &name_len_buf, @intCast(index_info.name.len), .little);
        _ = try file.write(&name_len_buf);
        _ = try file.write(index_info.name);

        // Write index type
        var type_len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &type_len_buf, @intCast(index_info.index_type.len), .little);
        _ = try file.write(&type_len_buf);
        _ = try file.write(index_info.index_type);

        // Write table name
        var table_len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &table_len_buf, @intCast(index_info.table_name.len), .little);
        _ = try file.write(&table_len_buf);
        _ = try file.write(index_info.table_name);

        // Write column count and columns
        var col_count_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &col_count_buf, @intCast(index_info.columns.len), .little);
        _ = try file.write(&col_count_buf);

        for (index_info.columns) |col| {
            var col_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &col_len_buf, @intCast(col.len), .little);
            _ = try file.write(&col_len_buf);
            _ = try file.write(col);
        }
    }
}

pub fn loadCatalog() !void {
    const allocator = std.heap.page_allocator;

    // Get catalog path from GEODE_DATA_DIR or use default
    const data_dir = std.process.getEnvVarOwned(allocator, "GEODE_DATA_DIR") catch |err| blk: {
        if (err == error.EnvironmentVariableNotFound) {
            break :blk try allocator.dupe(u8, "/tmp");
        }
        return err;
    };
    defer allocator.free(data_dir);

    const catalog_path = try std.fmt.allocPrint(allocator, "{s}/geode_catalog.dat", .{data_dir});
    defer allocator.free(catalog_path);

    const file = std.fs.cwd().openFile(catalog_path, .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer file.close();

    // Read header
    var header: [12]u8 = undefined;
    const bytes_read = try file.read(&header);
    if (bytes_read < 12) return error.InvalidCatalogFile;

    const schema_count = std.mem.readInt(u32, header[0..4], .little);
    const graph_count = std.mem.readInt(u32, header[4..8], .little);
    const index_count = std.mem.readInt(u32, header[8..12], .little);

    // Read schemas
    var i: u32 = 0;
    while (i < schema_count) : (i += 1) {
        var len_buf: [4]u8 = undefined;
        if ((try file.read(&len_buf)) < 4) return error.InvalidCatalogFile;
        const name_len = std.mem.readInt(u32, &len_buf, .little);

        const name = try allocator.alloc(u8, name_len);
        if ((try file.read(name)) < name_len) return error.InvalidCatalogFile;

        try catalog.schemas.put(name, {});
    }

    // Read graphs
    i = 0;
    while (i < graph_count) : (i += 1) {
        var len_buf: [4]u8 = undefined;
        if ((try file.read(&len_buf)) < 4) return error.InvalidCatalogFile;
        const name_len = std.mem.readInt(u32, &len_buf, .little);

        const name = try allocator.alloc(u8, name_len);
        if ((try file.read(name)) < name_len) return error.InvalidCatalogFile;

        try catalog.graphs.put(name, {});
    }

    // Read indexes
    i = 0;
    while (i < index_count) : (i += 1) {
        // Read index name
        var name_len_buf: [4]u8 = undefined;
        if ((try file.read(&name_len_buf)) < 4) return error.InvalidCatalogFile;
        const name_len = std.mem.readInt(u32, &name_len_buf, .little);
        const name = try allocator.alloc(u8, name_len);
        if ((try file.read(name)) < name_len) return error.InvalidCatalogFile;

        // Read index type
        var type_len_buf: [4]u8 = undefined;
        if ((try file.read(&type_len_buf)) < 4) return error.InvalidCatalogFile;
        const type_len = std.mem.readInt(u32, &type_len_buf, .little);
        const index_type = try allocator.alloc(u8, type_len);
        if ((try file.read(index_type)) < type_len) return error.InvalidCatalogFile;

        // Read table name
        var table_len_buf: [4]u8 = undefined;
        if ((try file.read(&table_len_buf)) < 4) return error.InvalidCatalogFile;
        const table_len = std.mem.readInt(u32, &table_len_buf, .little);
        const table_name = try allocator.alloc(u8, table_len);
        if ((try file.read(table_name)) < table_len) return error.InvalidCatalogFile;

        // Read column count
        var col_count_buf: [4]u8 = undefined;
        if ((try file.read(&col_count_buf)) < 4) return error.InvalidCatalogFile;
        const col_count = std.mem.readInt(u32, &col_count_buf, .little);

        // Read columns
        const columns = try allocator.alloc([]const u8, col_count);
        var col_idx: u32 = 0;
        while (col_idx < col_count) : (col_idx += 1) {
            var col_len_buf: [4]u8 = undefined;
            if ((try file.read(&col_len_buf)) < 4) return error.InvalidCatalogFile;
            const col_len = std.mem.readInt(u32, &col_len_buf, .little);
            const col = try allocator.alloc(u8, col_len);
            if ((try file.read(col)) < col_len) return error.InvalidCatalogFile;
            columns[col_idx] = col;
        }

        const index_info = IndexInfo{
            .name = name,
            .index_type = index_type,
            .table_name = table_name,
            .columns = columns,
        };

        // Reconstruct scoped key: "label:index_name"
        // This ensures compatibility with new scoped key format
        const scoped_key = try getScopedIndexKey(allocator, table_name, name);
        try catalog.indexes.put(scoped_key, index_info);
    }
}
