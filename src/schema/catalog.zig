const std = @import("std");
const graph_storage_manager = @import("../server/graph_storage_manager.zig");

// PERF: PHASE3_RWLOCK - RwLock for concurrent catalog access
// CANARY: REQ=REQ-PERF-PHASE3-001; FEATURE="ConcurrencyOptimization"; ASPECT=CATALOG_LOCK; STATUS=EXEMPT; OWNER=performance; UPDATED=2025-10-17
// CANARY: REQ=REQ-ARCH-M2-FIX; FEATURE="DependencyInjection"; ASPECT=CATALOG; STATUS=EXEMPT; OWNER=core; UPDATED=2025-10-17
// Phase 3 optimization: RwLock allows concurrent reads (2-3x concurrent query throughput)
// M2 Fix: Refactored from global mutable state to dependency injection pattern

// IndexInfo stores metadata about an index
// CANARY: REQ=REQ-INDEX-001; FEATURE="IndexManagement"; ASPECT=Catalog; STATUS=TESTED; OWNER=storage; UPDATED=2025-10-14
pub const IndexInfo = struct {
    name: []const u8, // Index name (user-provided)
    index_type: []const u8, // btree, hash, fulltext, etc.
    table_name: []const u8, // Label/table name
    columns: [][]const u8, // Property names
};

// CANARY: REQ=REQ-CONSTRAINT-001; FEATURE="ConstraintManagement"; ASPECT=Catalog; STATUS=TESTED; TEST=geodetestlab/specs/gql_catalog_operations_comprehensive.yml; OWNER=schema; UPDATED=2026-01-09
// ConstraintInfo stores metadata about a schema constraint
pub const ConstraintInfo = struct {
    name: []const u8, // Constraint name (user-provided)
    constraint_type: ConstraintType, // Type of constraint
    label: []const u8, // Node/edge label
    properties: [][]const u8, // Property names involved
    is_enforced: bool, // Whether constraint is currently enforced

    pub const ConstraintType = enum {
        unique, // IS UNIQUE - single property uniqueness
        node_key, // IS NODE KEY - composite key (implies unique + not null)
        not_null, // IS NOT NULL - property must be present
        exists, // EXISTS - legacy syntax, same as not_null
    };
};

/// Generate a scoped index key for catalog storage
/// Format: "label:index_name" to allow same index name on different labels
/// This follows database best practices where indexes are scoped per table/label
pub fn getScopedIndexKey(allocator: std.mem.Allocator, label: []const u8, index_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ label, index_name });
}

/// Catalog manages database metadata (schemas, graphs, indexes, constraints)
/// Thread-safe via RwLock for concurrent access
pub const Catalog = struct {
    allocator: std.mem.Allocator,
    rwlock: std.Thread.RwLock,
    schemas: std.StringHashMap(void),
    graphs: std.StringHashMap(void),
    indexes: std.StringHashMap(IndexInfo),
    constraints: std.StringHashMap(ConstraintInfo),
    data_dir: []const u8,

    /// Initialize a new catalog with dependency injection
    /// Takes ownership of data_dir string
    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8) !*Catalog {
        var self = try allocator.create(Catalog);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .rwlock = .{},
            .schemas = std.StringHashMap(void).init(allocator),
            .graphs = std.StringHashMap(void).init(allocator),
            .indexes = std.StringHashMap(IndexInfo).init(allocator),
            .constraints = std.StringHashMap(ConstraintInfo).init(allocator),
            .data_dir = try allocator.dupe(u8, data_dir),
        };

        // Load persisted catalog if it exists
        self.load() catch |err| {
            std.log.warn("Failed to load catalog from disk: {any}", .{err});
        };

        return self;
    }

    /// Clean up catalog resources
    /// NOTE: Should only be called when no other threads are accessing the catalog
    pub fn deinit(self: *Catalog) void {
        // No locking needed - this should only be called during cleanup when no other threads access catalog

        // Free all allocated memory properly
        // Note: In tests, this must be called with the same allocator that created the catalog

        // Free HashMap keys and values
        {
            var iter = self.schemas.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.schemas.deinit();
        }

        {
            var iter = self.graphs.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.graphs.deinit();
        }

        {
            var iter = self.indexes.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                const info = entry.value_ptr.*;
                self.allocator.free(info.name);
                self.allocator.free(info.index_type);
                self.allocator.free(info.table_name);
                for (info.columns) |col| {
                    self.allocator.free(col);
                }
                self.allocator.free(info.columns);
            }
            self.indexes.deinit();
        }

        // Free constraint entries
        {
            var iter = self.constraints.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                const info = entry.value_ptr.*;
                self.allocator.free(info.name);
                self.allocator.free(info.label);
                for (info.properties) |prop| {
                    self.allocator.free(prop);
                }
                self.allocator.free(info.properties);
            }
            self.constraints.deinit();
        }

        self.allocator.free(self.data_dir);
        // Caller is responsible for destroying the Catalog struct itself
    }

    /// Save catalog to disk
    /// NOTE: Caller must hold rwlock (either shared or exclusive) before calling
    pub fn save(self: *Catalog) !void {
        // No locking - caller must hold rwlock
        // This is necessary because save() is typically called while holding a write lock

        const catalog_path = try std.fmt.allocPrint(self.allocator, "{s}/geode_catalog.dat", .{self.data_dir});
        defer self.allocator.free(catalog_path);

        const file = try std.fs.cwd().createFile(catalog_path, .{});
        defer file.close();

        // Write header: schema_count, graph_count, index_count, constraint_count
        var header: [16]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intCast(self.schemas.count()), .little);
        std.mem.writeInt(u32, header[4..8], @intCast(self.graphs.count()), .little);
        std.mem.writeInt(u32, header[8..12], @intCast(self.indexes.count()), .little);
        std.mem.writeInt(u32, header[12..16], @intCast(self.constraints.count()), .little);
        _ = try file.write(&header);

        // Write schemas (just names)
        var schema_iter = self.schemas.iterator();
        while (schema_iter.next()) |entry| {
            const name = entry.key_ptr.*;
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @intCast(name.len), .little);
            _ = try file.write(&len_buf);
            _ = try file.write(name);
        }

        // Write graphs (just names)
        var graph_iter = self.graphs.iterator();
        while (graph_iter.next()) |entry| {
            const name = entry.key_ptr.*;
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @intCast(name.len), .little);
            _ = try file.write(&len_buf);
            _ = try file.write(name);
        }

        // Write indexes
        var index_iter = self.indexes.iterator();
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

        // Write constraints
        var constraint_iter = self.constraints.iterator();
        while (constraint_iter.next()) |entry| {
            const constraint_info = entry.value_ptr.*;

            // Write constraint name
            var name_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &name_len_buf, @intCast(constraint_info.name.len), .little);
            _ = try file.write(&name_len_buf);
            _ = try file.write(constraint_info.name);

            // Write constraint type (as u8)
            const type_byte: [1]u8 = .{@intFromEnum(constraint_info.constraint_type)};
            _ = try file.write(&type_byte);

            // Write label
            var label_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &label_len_buf, @intCast(constraint_info.label.len), .little);
            _ = try file.write(&label_len_buf);
            _ = try file.write(constraint_info.label);

            // Write is_enforced flag
            const enforced_byte: [1]u8 = .{if (constraint_info.is_enforced) 1 else 0};
            _ = try file.write(&enforced_byte);

            // Write property count and properties
            var prop_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &prop_count_buf, @intCast(constraint_info.properties.len), .little);
            _ = try file.write(&prop_count_buf);

            for (constraint_info.properties) |prop| {
                var prop_len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &prop_len_buf, @intCast(prop.len), .little);
                _ = try file.write(&prop_len_buf);
                _ = try file.write(prop);
            }
        }
    }

    /// Load catalog from disk
    pub fn load(self: *Catalog) !void {
        const catalog_path = try std.fmt.allocPrint(self.allocator, "{s}/geode_catalog.dat", .{self.data_dir});
        defer self.allocator.free(catalog_path);

        const file = std.fs.cwd().openFile(catalog_path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        // Lock for modifying catalog state
        self.rwlock.lock();
        defer self.rwlock.unlock();

        // Read header (supports both old 12-byte and new 16-byte format)
        var header: [16]u8 = undefined;
        const bytes_read = try file.read(&header);
        if (bytes_read < 12) return error.InvalidCatalogFile;

        const schema_count = std.mem.readInt(u32, header[0..4], .little);
        const graph_count = std.mem.readInt(u32, header[4..8], .little);
        const index_count = std.mem.readInt(u32, header[8..12], .little);
        // Constraint count only available in new format (16-byte header)
        const constraint_count: u32 = if (bytes_read >= 16) std.mem.readInt(u32, header[12..16], .little) else 0;

        // Read schemas
        var i: u32 = 0;
        while (i < schema_count) : (i += 1) {
            var len_buf: [4]u8 = undefined;
            if ((try file.read(&len_buf)) < 4) return error.InvalidCatalogFile;
            const name_len = std.mem.readInt(u32, &len_buf, .little);

            const name = try self.allocator.alloc(u8, name_len);
            errdefer self.allocator.free(name);
            if ((try file.read(name)) < name_len) return error.InvalidCatalogFile;

            try self.schemas.put(name, {});
        }

        // Read graphs
        i = 0;
        while (i < graph_count) : (i += 1) {
            var len_buf: [4]u8 = undefined;
            if ((try file.read(&len_buf)) < 4) return error.InvalidCatalogFile;
            const name_len = std.mem.readInt(u32, &len_buf, .little);

            const name = try self.allocator.alloc(u8, name_len);
            errdefer self.allocator.free(name);
            if ((try file.read(name)) < name_len) return error.InvalidCatalogFile;

            try self.graphs.put(name, {});
        }

        // Read indexes
        i = 0;
        while (i < index_count) : (i += 1) {
            // Read index name
            var name_len_buf: [4]u8 = undefined;
            if ((try file.read(&name_len_buf)) < 4) return error.InvalidCatalogFile;
            const name_len = std.mem.readInt(u32, &name_len_buf, .little);
            const name = try self.allocator.alloc(u8, name_len);
            errdefer self.allocator.free(name);
            if ((try file.read(name)) < name_len) return error.InvalidCatalogFile;

            // Read index type
            var type_len_buf: [4]u8 = undefined;
            if ((try file.read(&type_len_buf)) < 4) return error.InvalidCatalogFile;
            const type_len = std.mem.readInt(u32, &type_len_buf, .little);
            const index_type = try self.allocator.alloc(u8, type_len);
            errdefer self.allocator.free(index_type);
            if ((try file.read(index_type)) < type_len) return error.InvalidCatalogFile;

            // Read table name
            var table_len_buf: [4]u8 = undefined;
            if ((try file.read(&table_len_buf)) < 4) return error.InvalidCatalogFile;
            const table_len = std.mem.readInt(u32, &table_len_buf, .little);
            const table_name = try self.allocator.alloc(u8, table_len);
            errdefer self.allocator.free(table_name);
            if ((try file.read(table_name)) < table_len) return error.InvalidCatalogFile;

            // Read column count
            var col_count_buf: [4]u8 = undefined;
            if ((try file.read(&col_count_buf)) < 4) return error.InvalidCatalogFile;
            const col_count = std.mem.readInt(u32, &col_count_buf, .little);

            // Read columns
            const columns = try self.allocator.alloc([]const u8, col_count);
            errdefer self.allocator.free(columns);
            var col_idx: u32 = 0;
            while (col_idx < col_count) : (col_idx += 1) {
                var col_len_buf: [4]u8 = undefined;
                if ((try file.read(&col_len_buf)) < 4) return error.InvalidCatalogFile;
                const col_len = std.mem.readInt(u32, &col_len_buf, .little);
                const col = try self.allocator.alloc(u8, col_len);
                errdefer self.allocator.free(col);
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
            const scoped_key = try getScopedIndexKey(self.allocator, table_name, name);
            try self.indexes.put(scoped_key, index_info);
        }

        // Read constraints (if present in catalog file)
        i = 0;
        while (i < constraint_count) : (i += 1) {
            // Read constraint name
            var name_len_buf: [4]u8 = undefined;
            if ((try file.read(&name_len_buf)) < 4) return error.InvalidCatalogFile;
            const name_len = std.mem.readInt(u32, &name_len_buf, .little);
            const name = try self.allocator.alloc(u8, name_len);
            errdefer self.allocator.free(name);
            if ((try file.read(name)) < name_len) return error.InvalidCatalogFile;

            // Read constraint type
            var type_byte: [1]u8 = undefined;
            if ((try file.read(&type_byte)) < 1) return error.InvalidCatalogFile;
            const constraint_type: ConstraintInfo.ConstraintType = @enumFromInt(type_byte[0]);

            // Read label
            var label_len_buf: [4]u8 = undefined;
            if ((try file.read(&label_len_buf)) < 4) return error.InvalidCatalogFile;
            const label_len = std.mem.readInt(u32, &label_len_buf, .little);
            const label = try self.allocator.alloc(u8, label_len);
            errdefer self.allocator.free(label);
            if ((try file.read(label)) < label_len) return error.InvalidCatalogFile;

            // Read is_enforced flag
            var enforced_byte: [1]u8 = undefined;
            if ((try file.read(&enforced_byte)) < 1) return error.InvalidCatalogFile;
            const is_enforced = enforced_byte[0] != 0;

            // Read property count
            var prop_count_buf: [4]u8 = undefined;
            if ((try file.read(&prop_count_buf)) < 4) return error.InvalidCatalogFile;
            const prop_count = std.mem.readInt(u32, &prop_count_buf, .little);

            // Read properties
            const properties = try self.allocator.alloc([]const u8, prop_count);
            errdefer self.allocator.free(properties);
            var prop_idx: u32 = 0;
            while (prop_idx < prop_count) : (prop_idx += 1) {
                var prop_len_buf: [4]u8 = undefined;
                if ((try file.read(&prop_len_buf)) < 4) return error.InvalidCatalogFile;
                const prop_len = std.mem.readInt(u32, &prop_len_buf, .little);
                const prop = try self.allocator.alloc(u8, prop_len);
                errdefer self.allocator.free(prop);
                if ((try file.read(prop)) < prop_len) return error.InvalidCatalogFile;
                properties[prop_idx] = prop;
            }

            const constraint_info = ConstraintInfo{
                .name = name,
                .constraint_type = constraint_type,
                .label = label,
                .properties = properties,
                .is_enforced = is_enforced,
            };

            // Use scoped key: "label:constraint_name"
            const scoped_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ label, name });
            try self.constraints.put(scoped_key, constraint_info);
        }
    }

    // CANARY: REQ=REQ-CONSTRAINT-002; FEATURE="ConstraintManagement"; ASPECT=CatalogMethods; STATUS=TESTED; TEST=geodetestlab/specs/gql_catalog_operations_comprehensive.yml; OWNER=schema; UPDATED=2026-01-09
    /// Add a constraint to the catalog
    pub fn addConstraint(self: *Catalog, info: ConstraintInfo) !void {
        self.rwlock.lock();
        defer self.rwlock.unlock();

        // Create scoped key
        const scoped_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ info.label, info.name });
        errdefer self.allocator.free(scoped_key);

        // Check if constraint already exists
        if (self.constraints.contains(scoped_key)) {
            self.allocator.free(scoped_key);
            return error.ConstraintAlreadyExists;
        }

        // Duplicate strings for catalog ownership
        const owned_name = try self.allocator.dupe(u8, info.name);
        errdefer self.allocator.free(owned_name);

        const owned_label = try self.allocator.dupe(u8, info.label);
        errdefer self.allocator.free(owned_label);

        const owned_props = try self.allocator.alloc([]const u8, info.properties.len);
        errdefer self.allocator.free(owned_props);

        for (info.properties, 0..) |prop, idx| {
            owned_props[idx] = try self.allocator.dupe(u8, prop);
        }

        const owned_info = ConstraintInfo{
            .name = owned_name,
            .constraint_type = info.constraint_type,
            .label = owned_label,
            .properties = owned_props,
            .is_enforced = info.is_enforced,
        };

        try self.constraints.put(scoped_key, owned_info);
        try self.save();
    }

    /// Remove a constraint from the catalog
    pub fn removeConstraint(self: *Catalog, label: []const u8, name: []const u8) !void {
        self.rwlock.lock();
        defer self.rwlock.unlock();

        const scoped_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ label, name });
        defer self.allocator.free(scoped_key);

        const entry = self.constraints.fetchRemove(scoped_key) orelse return error.ConstraintNotFound;

        // Free the stored values
        self.allocator.free(entry.key);
        self.allocator.free(entry.value.name);
        self.allocator.free(entry.value.label);
        for (entry.value.properties) |prop| {
            self.allocator.free(prop);
        }
        self.allocator.free(entry.value.properties);

        try self.save();
    }

    /// Get a constraint by label and name
    pub fn getConstraint(self: *Catalog, label: []const u8, name: []const u8) !?ConstraintInfo {
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();

        var key_buf: [512]u8 = undefined;
        const scoped_key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ label, name }) catch return null;

        return self.constraints.get(scoped_key);
    }

    /// Get all constraints for a label
    pub fn getConstraintsForLabel(self: *Catalog, label: []const u8) ![]ConstraintInfo {
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();

        var result = std.ArrayList(ConstraintInfo).init(self.allocator);
        errdefer result.deinit();

        var iter = self.constraints.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.label, label)) {
                try result.append(entry.value_ptr.*);
            }
        }

        return result.toOwnedSlice();
    }

    // CANARY: REQ=REQ-GRAPH-META-001; FEATURE="GraphMetadataPersistence"; ASPECT=AddGraph; STATUS=EXEMPT; OWNER=catalog; UPDATED=2026-01-09
    /// Add a graph to the catalog and persist
    pub fn addGraph(self: *Catalog, name: []const u8) !void {
        self.rwlock.lock();
        defer self.rwlock.unlock();

        // Check if graph already exists
        if (self.graphs.contains(name)) {
            return error.GraphAlreadyExists;
        }

        // Duplicate name for ownership
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        try self.graphs.put(owned_name, {});
        try self.save();
    }

    // CANARY: REQ=REQ-GRAPH-META-002; FEATURE="GraphMetadataPersistence"; ASPECT=RemoveGraph; STATUS=EXEMPT; OWNER=catalog; UPDATED=2026-01-09
    /// Remove a graph from the catalog and persist
    pub fn removeGraph(self: *Catalog, name: []const u8) !void {
        self.rwlock.lock();
        defer self.rwlock.unlock();

        const entry = self.graphs.fetchRemove(name) orelse return error.GraphNotFound;

        // Free the stored key
        self.allocator.free(entry.key);

        try self.save();
    }

    // CANARY: REQ=REQ-GRAPH-META-003; FEATURE="GraphMetadataPersistence"; ASPECT=GraphExists; STATUS=EXEMPT; OWNER=catalog; UPDATED=2026-01-09
    /// Check if a graph exists in the catalog
    pub fn graphExists(self: *Catalog, name: []const u8) bool {
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();

        return self.graphs.contains(name);
    }

    // GAP-0139: SHOW INDEXES implementation
    // CANARY: REQ=REQ-SHOW-INDEXES-001; FEATURE="SHOW INDEXES"; ASPECT=CatalogList; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=catalog; UPDATED=2026-01-13
    /// List all indexes in the catalog
    /// Returns a dynamically allocated slice of IndexInfo. Caller owns the returned slice.
    pub fn listAllIndexes(self: *Catalog, allocator: std.mem.Allocator) ![]IndexInfo {
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();

        var result = std.ArrayList(IndexInfo).init(allocator);
        errdefer result.deinit();

        var iter = self.indexes.iterator();
        while (iter.next()) |entry| {
            try result.append(entry.value_ptr.*);
        }

        return result.toOwnedSlice();
    }

    // GAP-0139: SHOW CONSTRAINTS implementation
    // CANARY: REQ=REQ-SHOW-CONSTRAINTS-001; FEATURE="SHOW CONSTRAINTS"; ASPECT=CatalogList; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=catalog; UPDATED=2026-01-13
    /// List all constraints in the catalog
    /// Returns a dynamically allocated slice of ConstraintInfo. Caller owns the returned slice.
    pub fn listAllConstraints(self: *Catalog, allocator: std.mem.Allocator) ![]ConstraintInfo {
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();

        var result = std.ArrayList(ConstraintInfo).init(allocator);
        errdefer result.deinit();

        var iter = self.constraints.iterator();
        while (iter.next()) |entry| {
            try result.append(entry.value_ptr.*);
        }

        return result.toOwnedSlice();
    }

    // GAP-0139: SHOW SCHEMAS implementation
    // CANARY: REQ=REQ-SHOW-SCHEMAS-001; FEATURE="SHOW SCHEMAS"; ASPECT=CatalogList; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=catalog; UPDATED=2026-01-13
    /// List all schemas in the catalog
    /// Returns a dynamically allocated slice of schema names. Caller owns the returned slice.
    pub fn listAllSchemas(self: *Catalog, allocator: std.mem.Allocator) ![][]const u8 {
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();

        var result = std.ArrayList([]const u8).init(allocator);
        errdefer result.deinit();

        var iter = self.schemas.iterator();
        while (iter.next()) |entry| {
            try result.append(entry.key_ptr.*);
        }

        return result.toOwnedSlice();
    }
};

// GAP-0131: Global catalog state maintained for backward compatibility
// CANARY: REQ=REQ-CATALOG-DEPRECATION-001; FEATURE="Legacy Global Catalog"; ASPECT=BackwardCompatibility; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-13
// WARNING: These globals are DEPRECATED. New code should use Catalog instance methods.
// Migration path: Replace initCatalog() with Catalog.init(allocator) and use instance methods
// Callers to migrate: execution.zig (5 call sites)
// Target removal: After all callers migrated to instance-based API
pub var catalog_rwlock = std.Thread.RwLock{};
pub var catalog_initialized = false;
pub var last_catalog_data_dir: ?[]u8 = null;

/// P2-3: Global allocator for catalog operations (better than page_allocator)
var catalog_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var catalog_allocator_init = false;

pub var catalog: struct {
    schemas: std.StringHashMap(void),
    graphs: std.StringHashMap(void),
    indexes: std.StringHashMap(IndexInfo),
} = undefined;

pub fn initCatalog() void {
    // P2-3: Initialize global allocator on first use
    if (!catalog_allocator_init) {
        catalog_allocator_init = true;
    }
    const allocator = catalog_gpa.allocator();

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
    // P2-3: Use catalog global allocator instead of page_allocator
    const allocator = catalog_gpa.allocator();

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
    // P2-3: Use catalog global allocator instead of page_allocator
    const allocator = catalog_gpa.allocator();

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

        // CRITICAL: Also register with graph storage manager so DROP GRAPH works
        _ = graph_storage_manager.createGraphStorage(allocator, name) catch {
            // If storage creation fails (e.g., already exists), that's OK
        };
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
