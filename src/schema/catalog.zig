const std = @import("std");
const graph_store = @import("../graph_store.zig");
const tde = @import("../storage/tde_file_encryption.zig");


// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Schema; STATUS=EXEMPT; OWNER=schema; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("schema");
const Attr = logging.Attr;

// CANARY: REQ=REQ-TDE-FILELEVEL-001; FEATURE="TDEFileLevelEncryption"; ASPECT=SchemaCatalog; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28

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

// CANARY: REQ=REQ-AUTO-INDEX-002; FEATURE="AutoIdIndex"; ASPECT=Detection; STATUS=TESTED; OWNER=schema; UPDATED=2026-02-07
/// Check if an index name follows the auto-index naming convention (auto_idx_*_id)
pub fn isAutoIndex(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "auto_idx_") and std.mem.endsWith(u8, name, "_id");
}

fn isZeroUuid(uuid: [16]u8) bool {
    for (uuid) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

/// Catalog manages database metadata (schemas, graphs, indexes, constraints)
/// Thread-safe via RwLock for concurrent access
pub const Catalog = struct {
    allocator: std.mem.Allocator,
    rwlock: std.Io.RwLock,
    schemas: std.StringHashMap(void),
    graphs: std.StringHashMap([16]u8),
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
            .rwlock = std.Io.RwLock.init,
            .schemas = std.StringHashMap(void).init(allocator),
            .graphs = std.StringHashMap([16]u8).init(allocator),
            .indexes = std.StringHashMap(IndexInfo).init(allocator),
            .constraints = std.StringHashMap(ConstraintInfo).init(allocator),
            .data_dir = try allocator.dupe(u8, data_dir),
        };

        try self.load();

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

        // Buffer all data to memory first for TDE encryption
        var buffer = try std.ArrayList(u8).initCapacity(self.allocator, 4096);
        defer buffer.deinit(self.allocator);

        // Write header: schema_count, graph_count, index_count, constraint_count
        var header: [16]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intCast(self.schemas.count()), .little);
        std.mem.writeInt(u32, header[4..8], @intCast(self.graphs.count()), .little);
        std.mem.writeInt(u32, header[8..12], @intCast(self.indexes.count()), .little);
        std.mem.writeInt(u32, header[12..16], @intCast(self.constraints.count()), .little);
        try buffer.appendSlice(self.allocator, &header);

        // Write schemas (just names)
        var schema_iter = self.schemas.iterator();
        while (schema_iter.next()) |entry| {
            const name = entry.key_ptr.*;
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @intCast(name.len), .little);
            try buffer.appendSlice(self.allocator, &len_buf);
            try buffer.appendSlice(self.allocator, name);
        }

        // Write graphs (name + 16-byte UUID)
        var graph_iter = self.graphs.iterator();
        while (graph_iter.next()) |entry| {
            const name = entry.key_ptr.*;
            const uuid = entry.value_ptr.*;
            if (isZeroUuid(uuid)) return error.GraphUuidUnavailable;
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @intCast(name.len), .little);
            try buffer.appendSlice(self.allocator, &len_buf);
            try buffer.appendSlice(self.allocator, name);
            try buffer.appendSlice(self.allocator, &uuid);
        }

        // Write indexes
        var index_iter = self.indexes.iterator();
        while (index_iter.next()) |entry| {
            const index_info = entry.value_ptr.*;

            // Write index name
            var name_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &name_len_buf, @intCast(index_info.name.len), .little);
            try buffer.appendSlice(self.allocator, &name_len_buf);
            try buffer.appendSlice(self.allocator, index_info.name);

            // Write index type
            var type_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &type_len_buf, @intCast(index_info.index_type.len), .little);
            try buffer.appendSlice(self.allocator, &type_len_buf);
            try buffer.appendSlice(self.allocator, index_info.index_type);

            // Write table name
            var table_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &table_len_buf, @intCast(index_info.table_name.len), .little);
            try buffer.appendSlice(self.allocator, &table_len_buf);
            try buffer.appendSlice(self.allocator, index_info.table_name);

            // Write column count and columns
            var col_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &col_count_buf, @intCast(index_info.columns.len), .little);
            try buffer.appendSlice(self.allocator, &col_count_buf);

            for (index_info.columns) |col| {
                var col_len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &col_len_buf, @intCast(col.len), .little);
                try buffer.appendSlice(self.allocator, &col_len_buf);
                try buffer.appendSlice(self.allocator, col);
            }
        }

        // Write constraints
        var constraint_iter = self.constraints.iterator();
        while (constraint_iter.next()) |entry| {
            const constraint_info = entry.value_ptr.*;

            // Write constraint name
            var name_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &name_len_buf, @intCast(constraint_info.name.len), .little);
            try buffer.appendSlice(self.allocator, &name_len_buf);
            try buffer.appendSlice(self.allocator, constraint_info.name);

            // Write constraint type (as u8)
            const type_byte: [1]u8 = .{@intFromEnum(constraint_info.constraint_type)};
            try buffer.appendSlice(self.allocator, &type_byte);

            // Write label
            var label_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &label_len_buf, @intCast(constraint_info.label.len), .little);
            try buffer.appendSlice(self.allocator, &label_len_buf);
            try buffer.appendSlice(self.allocator, constraint_info.label);

            // Write is_enforced flag
            const enforced_byte: [1]u8 = .{if (constraint_info.is_enforced) 1 else 0};
            try buffer.appendSlice(self.allocator, &enforced_byte);

            // Write property count and properties
            var prop_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &prop_count_buf, @intCast(constraint_info.properties.len), .little);
            try buffer.appendSlice(self.allocator, &prop_count_buf);

            for (constraint_info.properties) |prop| {
                var prop_len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &prop_len_buf, @intCast(prop.len), .little);
                try buffer.appendSlice(self.allocator, &prop_len_buf);
                try buffer.appendSlice(self.allocator, prop);
            }
        }

        // Encrypt and write to file
        try tde.writeEncryptedFile(self.allocator, catalog_path, buffer.items);
    }

    /// Load catalog from disk
    pub fn load(self: *Catalog) !void {
        const catalog_path = try std.fmt.allocPrint(self.allocator, "{s}/geode_catalog.dat", .{self.data_dir});
        defer self.allocator.free(catalog_path);

        // Check if file exists first
        std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), catalog_path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };

        // Read and decrypt file using TDE
        const data = try tde.readDecryptedFile(self.allocator, catalog_path);
        defer self.allocator.free(data);

        // Lock for modifying catalog state
        self.rwlock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());

        // Create stream to read from decrypted data
        var reader: std.Io.Reader = .fixed(data);

        // Read header
        var header: [16]u8 = undefined;
        const bytes_read = reader.readSliceShort(&header) catch 0;
        if (bytes_read < 16) return error.InvalidCatalogFile;

        const schema_count = std.mem.readInt(u32, header[0..4], .little);
        const graph_count = std.mem.readInt(u32, header[4..8], .little);
        const index_count = std.mem.readInt(u32, header[8..12], .little);
        const constraint_count = std.mem.readInt(u32, header[12..16], .little);

        // Read schemas
        var i: u32 = 0;
        while (i < schema_count) : (i += 1) {
            var len_buf: [4]u8 = undefined;
            if ((try reader.readSliceShort(&len_buf)) < 4) return error.InvalidCatalogFile;
            const name_len = std.mem.readInt(u32, &len_buf, .little);

            const name = try self.allocator.alloc(u8, name_len);
            errdefer self.allocator.free(name);
            if ((try reader.readSliceShort(name)) < name_len) return error.InvalidCatalogFile;

            try self.schemas.put(name, {});
        }

        // Read graphs (name + 16-byte UUID).
        i = 0;
        while (i < graph_count) : (i += 1) {
            var len_buf: [4]u8 = undefined;
            if ((try reader.readSliceShort(&len_buf)) < 4) return error.InvalidCatalogFile;
            const name_len = std.mem.readInt(u32, &len_buf, .little);

            const name = try self.allocator.alloc(u8, name_len);
            errdefer self.allocator.free(name);
            if ((try reader.readSliceShort(name)) < name_len) return error.InvalidCatalogFile;

            var uuid: [16]u8 = .{0} ** 16;
            if ((try reader.readSliceShort(&uuid)) < 16) return error.InvalidCatalogFile;
            if (isZeroUuid(uuid)) return error.GraphUuidUnavailable;

            try self.graphs.put(name, uuid);
        }

        // Ensure catalog graphs exist in GraphStore registry using the stored
        // UUIDs so the correct graph-storage directories are reopened.
        const store = graph_store.getGlobalStore(self.allocator);
        var graph_iter = self.graphs.iterator();
        while (graph_iter.next()) |entry| {
            const graph_name = entry.key_ptr.*;
            const uuid = entry.value_ptr.*;
            if (!store.graphExists(graph_name)) {
                try store.openOrCreateGraphWithUuid(graph_name, uuid);
            }
        }

        // Reload the in-memory compatibility cache from the now-opened engines.
        try store.loadFromFile();

        // Read indexes
        i = 0;
        while (i < index_count) : (i += 1) {
            // Read index name
            var name_len_buf: [4]u8 = undefined;
            if ((try reader.readSliceShort(&name_len_buf)) < 4) return error.InvalidCatalogFile;
            const name_len = std.mem.readInt(u32, &name_len_buf, .little);
            const name = try self.allocator.alloc(u8, name_len);
            errdefer self.allocator.free(name);
            if ((try reader.readSliceShort(name)) < name_len) return error.InvalidCatalogFile;

            // Read index type
            var type_len_buf: [4]u8 = undefined;
            if ((try reader.readSliceShort(&type_len_buf)) < 4) return error.InvalidCatalogFile;
            const type_len = std.mem.readInt(u32, &type_len_buf, .little);
            const index_type = try self.allocator.alloc(u8, type_len);
            errdefer self.allocator.free(index_type);
            if ((try reader.readSliceShort(index_type)) < type_len) return error.InvalidCatalogFile;

            // Read table name
            var table_len_buf: [4]u8 = undefined;
            if ((try reader.readSliceShort(&table_len_buf)) < 4) return error.InvalidCatalogFile;
            const table_len = std.mem.readInt(u32, &table_len_buf, .little);
            const table_name = try self.allocator.alloc(u8, table_len);
            errdefer self.allocator.free(table_name);
            if ((try reader.readSliceShort(table_name)) < table_len) return error.InvalidCatalogFile;

            // Read column count
            var col_count_buf: [4]u8 = undefined;
            if ((try reader.readSliceShort(&col_count_buf)) < 4) return error.InvalidCatalogFile;
            const col_count = std.mem.readInt(u32, &col_count_buf, .little);

            // Read columns
            const columns = try self.allocator.alloc([]const u8, col_count);
            errdefer self.allocator.free(columns);
            var col_idx: u32 = 0;
            while (col_idx < col_count) : (col_idx += 1) {
                var col_len_buf: [4]u8 = undefined;
                if ((try reader.readSliceShort(&col_len_buf)) < 4) return error.InvalidCatalogFile;
                const col_len = std.mem.readInt(u32, &col_len_buf, .little);
                const col = try self.allocator.alloc(u8, col_len);
                errdefer self.allocator.free(col);
                if ((try reader.readSliceShort(col)) < col_len) return error.InvalidCatalogFile;
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
            if ((try reader.readSliceShort(&name_len_buf)) < 4) return error.InvalidCatalogFile;
            const name_len = std.mem.readInt(u32, &name_len_buf, .little);
            const name = try self.allocator.alloc(u8, name_len);
            errdefer self.allocator.free(name);
            if ((try reader.readSliceShort(name)) < name_len) return error.InvalidCatalogFile;

            // Read constraint type
            var type_byte: [1]u8 = undefined;
            if ((try reader.readSliceShort(&type_byte)) < 1) return error.InvalidCatalogFile;
            const constraint_type: ConstraintInfo.ConstraintType = @enumFromInt(type_byte[0]);

            // Read label
            var label_len_buf: [4]u8 = undefined;
            if ((try reader.readSliceShort(&label_len_buf)) < 4) return error.InvalidCatalogFile;
            const label_len = std.mem.readInt(u32, &label_len_buf, .little);
            const label = try self.allocator.alloc(u8, label_len);
            errdefer self.allocator.free(label);
            if ((try reader.readSliceShort(label)) < label_len) return error.InvalidCatalogFile;

            // Read is_enforced flag
            var enforced_byte: [1]u8 = undefined;
            if ((try reader.readSliceShort(&enforced_byte)) < 1) return error.InvalidCatalogFile;
            const is_enforced = enforced_byte[0] != 0;

            // Read property count
            var prop_count_buf: [4]u8 = undefined;
            if ((try reader.readSliceShort(&prop_count_buf)) < 4) return error.InvalidCatalogFile;
            const prop_count = std.mem.readInt(u32, &prop_count_buf, .little);

            // Read properties
            const properties = try self.allocator.alloc([]const u8, prop_count);
            errdefer self.allocator.free(properties);
            var prop_idx: u32 = 0;
            while (prop_idx < prop_count) : (prop_idx += 1) {
                var prop_len_buf: [4]u8 = undefined;
                if ((try reader.readSliceShort(&prop_len_buf)) < 4) return error.InvalidCatalogFile;
                const prop_len = std.mem.readInt(u32, &prop_len_buf, .little);
                const prop = try self.allocator.alloc(u8, prop_len);
                errdefer self.allocator.free(prop);
                if ((try reader.readSliceShort(prop)) < prop_len) return error.InvalidCatalogFile;
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
        self.rwlock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());

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
        self.rwlock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());

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
        self.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());

        var key_buf: [512]u8 = undefined;
        const scoped_key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ label, name }) catch return null;

        return self.constraints.get(scoped_key);
    }

    /// Get all constraints for a label
    pub fn getConstraintsForLabel(self: *Catalog, label: []const u8) ![]ConstraintInfo {
        self.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());

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

    /// Add a schema to the catalog and persist
    pub fn addSchema(self: *Catalog, name: []const u8) !void {
        self.rwlock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.schemas.contains(name)) {
            return error.DuplicateSchema;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        try self.schemas.put(owned_name, {});
        try self.save();
    }

    /// Remove a schema from the catalog and persist
    pub fn removeSchema(self: *Catalog, name: []const u8) !void {
        self.rwlock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());

        const entry = self.schemas.fetchRemove(name) orelse return error.SchemaNotFound;
        self.allocator.free(entry.key);
        try self.save();
    }

    /// Check if schema exists in the catalog
    pub fn hasSchema(self: *Catalog, name: []const u8) bool {
        self.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());

        return self.schemas.contains(name);
    }

    // CANARY: REQ=REQ-GRAPH-META-001; FEATURE="GraphMetadataPersistence"; ASPECT=AddGraph; STATUS=EXEMPT; OWNER=catalog; UPDATED=2026-03-29
    /// Add a graph to the catalog without persisting it yet. Call
    /// `updateGraphUuid()` or `addGraphWithUuid()` before saving.
    pub fn addGraph(self: *Catalog, name: []const u8) !void {
        self.rwlock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());

        // Check if graph already exists
        if (self.graphs.contains(name)) {
            return error.GraphAlreadyExists;
        }

        // Duplicate name for ownership
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        try self.graphs.put(owned_name, .{0} ** 16);
    }

    /// Add a graph to the catalog with its assigned storage UUID and persist it.
    pub fn addGraphWithUuid(self: *Catalog, name: []const u8, uuid: [16]u8) !void {
        self.rwlock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());

        if (isZeroUuid(uuid)) return error.GraphUuidUnavailable;
        if (self.graphs.contains(name)) return error.GraphAlreadyExists;

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        try self.graphs.put(owned_name, uuid);
        try self.save();
    }

    /// Update the stored UUID for a graph after the storage adapter has
    /// created the engine.
    pub fn updateGraphUuid(self: *Catalog, name: []const u8, uuid: [16]u8) !void {
        if (isZeroUuid(uuid)) return error.GraphUuidUnavailable;

        self.rwlock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.graphs.getPtr(name)) |ptr| {
            ptr.* = uuid;
            try self.save();
            return;
        }
        return error.GraphNotFound;
    }

    // CANARY: REQ=REQ-GRAPH-META-002; FEATURE="GraphMetadataPersistence"; ASPECT=RemoveGraph; STATUS=EXEMPT; OWNER=catalog; UPDATED=2026-01-09
    /// Remove a graph from the catalog and persist
    pub fn removeGraph(self: *Catalog, name: []const u8) !void {
        self.rwlock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());

        const entry = self.graphs.fetchRemove(name) orelse return error.GraphNotFound;

        // Free the stored key
        self.allocator.free(entry.key);

        try self.save();
    }

    // CANARY: REQ=REQ-GRAPH-META-003; FEATURE="GraphMetadataPersistence"; ASPECT=GraphExists; STATUS=EXEMPT; OWNER=catalog; UPDATED=2026-01-09
    /// Check if a graph exists in the catalog
    pub fn graphExists(self: *Catalog, name: []const u8) bool {
        self.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());

        return self.graphs.contains(name);
    }

    /// Alias for graphExists (schema manager compatibility)
    pub fn hasGraph(self: *Catalog, name: []const u8) bool {
        return self.graphExists(name);
    }

    /// List all graphs in the catalog
    /// Returns an owned slice of graph names. Caller must free each name and the slice.
    pub fn listGraphs(self: *Catalog, allocator: std.mem.Allocator) ![][]const u8 {
        self.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());

        var result = std.ArrayList([]const u8).empty;
        errdefer {
            for (result.items) |name| {
                allocator.free(name);
            }
            result.deinit(allocator);
        }

        var iter = self.graphs.iterator();
        while (iter.next()) |entry| {
            const name_copy = try allocator.dupe(u8, entry.key_ptr.*);
            try result.append(allocator, name_copy);
        }

        return result.toOwnedSlice(allocator);
    }

    // CANARY: REQ=REQ-AUTO-INDEX-001; FEATURE="AutoIdIndex"; ASPECT=CatalogMethod; STATUS=TESTED; OWNER=schema; UPDATED=2026-02-07
    /// Auto-create a btree index on the `id` property for a label if one doesn't exist.
    /// Uses IF NOT EXISTS semantics - safe to call repeatedly.
    pub fn ensureAutoIdIndex(self: *Catalog, label: []const u8) !void {
        const index_name = try std.fmt.allocPrint(self.allocator, "auto_idx_{s}_id", .{label});
        const scoped_key = try getScopedIndexKey(self.allocator, label, index_name);

        self.rwlock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.indexes.contains(scoped_key)) {
            self.allocator.free(scoped_key);
            self.allocator.free(index_name);
            return; // Already exists
        }

        // Create owned copies for catalog storage
        const owned_type = try self.allocator.dupe(u8, "btree");
        errdefer self.allocator.free(owned_type);
        const owned_table = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_table);
        const cols = try self.allocator.alloc([]const u8, 1);
        errdefer self.allocator.free(cols);
        cols[0] = try self.allocator.dupe(u8, "id");

        const info = IndexInfo{
            .name = index_name,
            .index_type = owned_type,
            .table_name = owned_table,
            .columns = cols,
        };

        try self.indexes.put(scoped_key, info);
        self.save() catch |err| {
            log.warn("Failed to persist auto-index", &.{
                Attr.string("index", index_name),
                Attr.string("error", @errorName(err)),
            });
        };
    }

    /// Add an index to the catalog and persist
    pub fn addIndex(self: *Catalog, info: IndexInfo) !void {
        self.rwlock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());

        const scoped_key = try getScopedIndexKey(self.allocator, info.table_name, info.name);
        errdefer self.allocator.free(scoped_key);

        if (self.indexes.contains(scoped_key)) {
            self.allocator.free(scoped_key);
            return error.DuplicateIndex;
        }

        const owned_name = try self.allocator.dupe(u8, info.name);
        errdefer self.allocator.free(owned_name);
        const owned_type = try self.allocator.dupe(u8, info.index_type);
        errdefer self.allocator.free(owned_type);
        const owned_table = try self.allocator.dupe(u8, info.table_name);
        errdefer self.allocator.free(owned_table);

        const owned_cols = try self.allocator.alloc([]const u8, info.columns.len);
        errdefer self.allocator.free(owned_cols);
        for (info.columns, 0..) |col, idx| {
            owned_cols[idx] = try self.allocator.dupe(u8, col);
        }

        const owned_info = IndexInfo{
            .name = owned_name,
            .index_type = owned_type,
            .table_name = owned_table,
            .columns = owned_cols,
        };

        try self.indexes.put(scoped_key, owned_info);
        try self.save();
    }

    /// Get index metadata by label and name (scoped key)
    pub fn getIndex(self: *Catalog, label: []const u8, index_name: []const u8) !?IndexInfo {
        self.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());

        var key_buf: [512]u8 = undefined;
        const scoped_key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ label, index_name }) catch {
            const owned = try getScopedIndexKey(self.allocator, label, index_name);
            defer self.allocator.free(owned);
            return self.indexes.get(owned);
        };
        return self.indexes.get(scoped_key);
    }

    // GAP-0139: SHOW INDEXES implementation
    // CANARY: REQ=REQ-SHOW-INDEXES-001; FEATURE="SHOW INDEXES"; ASPECT=CatalogList; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=catalog; UPDATED=2026-01-13
    /// List all indexes in the catalog
    /// Returns a dynamically allocated slice of IndexInfo. Caller owns the returned slice.
    pub fn listAllIndexes(self: *Catalog, allocator: std.mem.Allocator) ![]IndexInfo {
        self.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());

        var result = std.ArrayList(IndexInfo).empty;
        errdefer result.deinit(allocator);

        var iter = self.indexes.iterator();
        while (iter.next()) |entry| {
            try result.append(allocator, entry.value_ptr.*);
        }

        return result.toOwnedSlice(allocator);
    }

    // GAP-0139: SHOW CONSTRAINTS implementation
    // CANARY: REQ=REQ-SHOW-CONSTRAINTS-001; FEATURE="SHOW CONSTRAINTS"; ASPECT=CatalogList; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=catalog; UPDATED=2026-01-13
    /// List all constraints in the catalog
    /// Returns a dynamically allocated slice of ConstraintInfo. Caller owns the returned slice.
    pub fn listAllConstraints(self: *Catalog, allocator: std.mem.Allocator) ![]ConstraintInfo {
        self.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());

        var result = std.ArrayList(ConstraintInfo).empty;
        errdefer result.deinit(allocator);

        var iter = self.constraints.iterator();
        while (iter.next()) |entry| {
            try result.append(allocator, entry.value_ptr.*);
        }

        return result.toOwnedSlice(allocator);
    }

    // GAP-0139: SHOW SCHEMAS implementation
    // CANARY: REQ=REQ-SHOW-SCHEMAS-001; FEATURE="SHOW SCHEMAS"; ASPECT=CatalogList; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=catalog; UPDATED=2026-01-13
    /// List all schemas in the catalog
    /// Returns a dynamically allocated slice of schema names. Caller owns the returned slice.
    pub fn listAllSchemas(self: *Catalog, allocator: std.mem.Allocator) ![][]const u8 {
        self.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());

        var result = std.ArrayList([]const u8).empty;
        errdefer {
            for (result.items) |name| {
                allocator.free(name);
            }
            result.deinit(allocator);
        }

        var iter = self.schemas.iterator();
        while (iter.next()) |entry| {
            const name_copy = try allocator.dupe(u8, entry.key_ptr.*);
            try result.append(allocator, name_copy);
        }

        return result.toOwnedSlice(allocator);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

// CANARY: REQ=REQ-GRAPH-PERSIST-005; FEATURE="NamedGraphPersistence"; ASPECT=CatalogTests; STATUS=TESTED; OWNER=schema; UPDATED=2026-01-29

const testing = std.testing;

const TestCatalog = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    cat: *Catalog,

    pub fn init(allocator: std.mem.Allocator) !TestCatalog {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        const cat = try Catalog.init(allocator, data_dir);
        errdefer {
            cat.deinit();
            allocator.destroy(cat);
        }

        return .{
            .allocator = allocator,
            .tmp = tmp,
            .data_dir = data_dir,
            .cat = cat,
        };
    }

    pub fn deinit(self: *TestCatalog) void {
        self.cat.deinit();
        self.allocator.destroy(self.cat);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }
};

test "GAP384_Catalog_init_creates_empty_catalog" {
    // Issue #384: Test that Catalog initializes with empty graphs map
    const allocator = testing.allocator;

    var ctx = try TestCatalog.init(allocator);
    defer ctx.deinit();
    const cat = ctx.cat;

    try testing.expectEqual(@as(usize, 0), cat.graphs.count());
    try testing.expectEqual(@as(usize, 0), cat.schemas.count());
    try testing.expectEqual(@as(usize, 0), cat.indexes.count());
    try testing.expectEqual(@as(usize, 0), cat.constraints.count());
}

test "GAP384_Catalog_register_graph_works" {
    // Issue #384: Test that registerGraph adds a graph to the catalog
    const allocator = testing.allocator;

    var ctx = try TestCatalog.init(allocator);
    defer ctx.deinit();
    const cat = ctx.cat;

    try cat.addGraph("test_graph");

    try testing.expectEqual(@as(usize, 1), cat.graphs.count());
    try testing.expect(cat.graphs.contains("test_graph"));
}

test "GAP384_Catalog_register_multiple_graphs" {
    // Issue #384: Test multiple graph registration
    const allocator = testing.allocator;

    var ctx = try TestCatalog.init(allocator);
    defer ctx.deinit();
    const cat = ctx.cat;

    try cat.addGraph("graph1");
    try cat.addGraph("graph2");
    try cat.addGraph("graph3");

    try testing.expectEqual(@as(usize, 3), cat.graphs.count());
    try testing.expect(cat.graphs.contains("graph1"));
    try testing.expect(cat.graphs.contains("graph2"));
    try testing.expect(cat.graphs.contains("graph3"));
}

test "GAP384_Catalog_drop_graph_works" {
    // Issue #384: Test that dropGraph removes a graph from the catalog
    const allocator = testing.allocator;

    var ctx = try TestCatalog.init(allocator);
    defer ctx.deinit();
    const cat = ctx.cat;

    try cat.addGraph("temp_graph");
    try testing.expect(cat.graphs.contains("temp_graph"));

    try cat.removeGraph("temp_graph");
    try testing.expect(!cat.graphs.contains("temp_graph"));
}

test "GAP384_Catalog_drop_nonexistent_graph_returns_false" {
    // Issue #384: Test that dropping non-existent graph returns false
    const allocator = testing.allocator;

    var ctx = try TestCatalog.init(allocator);
    defer ctx.deinit();
    const cat = ctx.cat;

    const result = cat.removeGraph("nonexistent_graph");
    try testing.expectError(error.GraphNotFound, result);
}

test "GAP384_Catalog_list_graphs_returns_all_graphs" {
    // Issue #384: Test that listGraphs returns all registered graphs
    const allocator = testing.allocator;

    var ctx = try TestCatalog.init(allocator);
    defer ctx.deinit();
    const cat = ctx.cat;

    try cat.addGraph("alpha");
    try cat.addGraph("beta");

    const graphs = try cat.listGraphs(allocator);
    defer {
        for (graphs) |name| allocator.free(name);
        allocator.free(graphs);
    }

    try testing.expectEqual(@as(usize, 2), graphs.len);
    // Note: Order may vary due to hash map iteration
}

// CANARY: REQ=REQ-AUTO-INDEX-001; FEATURE="AutoIdIndex"; ASPECT=CatalogTests; STATUS=TESTED; OWNER=schema; UPDATED=2026-02-07

test "ensureAutoIdIndex creates index" {
    const allocator = testing.allocator;

    var ctx = try TestCatalog.init(allocator);
    defer ctx.deinit();
    const cat = ctx.cat;

    try cat.ensureAutoIdIndex("Person");

    // Verify index was created
    const idx = try cat.getIndex("Person", "auto_idx_Person_id");
    try testing.expect(idx != null);
    try testing.expectEqualStrings("btree", idx.?.index_type);
    try testing.expectEqualStrings("Person", idx.?.table_name);
    try testing.expectEqual(@as(usize, 1), idx.?.columns.len);
    try testing.expectEqualStrings("id", idx.?.columns[0]);
}

test "ensureAutoIdIndex is idempotent" {
    const allocator = testing.allocator;

    var ctx = try TestCatalog.init(allocator);
    defer ctx.deinit();
    const cat = ctx.cat;

    try cat.ensureAutoIdIndex("Person");
    try cat.ensureAutoIdIndex("Person"); // Should not error or duplicate

    try testing.expectEqual(@as(usize, 1), cat.indexes.count());
}

test "isAutoIndex recognizes auto-indexes" {
    try testing.expect(isAutoIndex("auto_idx_Person_id"));
    try testing.expect(isAutoIndex("auto_idx_Company_id"));
    try testing.expect(isAutoIndex("auto_idx_KNOWS_id"));
}

test "isAutoIndex rejects regular indexes" {
    try testing.expect(!isAutoIndex("idx_Person_name"));
    try testing.expect(!isAutoIndex("auto_idx_Person_name"));
    try testing.expect(!isAutoIndex("my_index"));
    try testing.expect(!isAutoIndex(""));
}
