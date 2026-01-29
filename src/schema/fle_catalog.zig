const std = @import("std");
const annotations = @import("annotations.zig");
const tde = @import("../storage/tde_file_encryption.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Schema; STATUS=EXEMPT; OWNER=schema; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("schema");
const Attr = logging.Attr;

// CANARY: REQ=REQ-TDE-FILELEVEL-001; FEATURE="TDEFileLevelEncryption"; ASPECT=FLECatalog; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28

// Global Schema Metadata Catalog
// CANARY: REQ=REQ-FLE-CATALOG-001; FEATURE="FieldLevelEncryption"; ASPECT=SCHEMA; STATUS=TESTED; TEST=tests/test_tde_kms_integration.zig; OWNER=security; UPDATED=2026-01-15

/// Thread-safe global schema catalog for field-level encryption metadata
pub const SchemaCatalog = struct {
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,
    schemas: std.StringHashMap(*annotations.TypeMetadata),

    /// Initialize a new schema catalog
    pub fn init(allocator: std.mem.Allocator) SchemaCatalog {
        return .{
            .allocator = allocator,
            .schemas = std.StringHashMap(*annotations.TypeMetadata).init(allocator),
        };
    }

    /// Clean up catalog resources
    pub fn deinit(self: *SchemaCatalog) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.schemas.iterator();
        while (it.next()) |entry| {
            // Free the key (stored type name)
            self.allocator.free(entry.key_ptr.*);
            // Free the value (TypeMetadata)
            var type_meta = entry.value_ptr.*;
            type_meta.deinit();
            self.allocator.destroy(type_meta);
        }
        self.schemas.deinit();
    }

    /// Register a new type with its field metadata
    /// Takes ownership of the TypeMetadata
    /// Thread-safe operation
    pub fn registerType(
        self: *SchemaCatalog,
        type_name: []const u8,
        type_meta: annotations.TypeMetadata,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if type already exists
        if (self.schemas.contains(type_name)) {
            return error.TypeAlreadyExists;
        }

        // Duplicate the type name for storage
        const stored_name = try self.allocator.dupe(u8, type_name);
        errdefer self.allocator.free(stored_name);

        // Allocate and store pointer
        const type_meta_ptr = try self.allocator.create(annotations.TypeMetadata);
        type_meta_ptr.* = type_meta;

        try self.schemas.put(stored_name, type_meta_ptr);
    }

    /// Get type metadata by name
    /// Returns pointer to type metadata, null if type not found
    /// Thread-safe read operation
    /// Note: Caller must not modify the returned pointer
    pub fn getType(self: *SchemaCatalog, type_name: []const u8) ?*const annotations.TypeMetadata {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.schemas.get(type_name)) |type_meta_ptr| {
            return type_meta_ptr;
        }
        return null;
    }

    /// Check if a field in a type is encrypted
    /// Thread-safe operation
    pub fn isFieldEncrypted(
        self: *SchemaCatalog,
        type_name: []const u8,
        field_name: []const u8,
    ) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.schemas.get(type_name)) |type_meta_ptr| {
            return type_meta_ptr.isFieldEncrypted(field_name);
        }
        return false;
    }

    /// Check if a field in a type is searchable (has blind index)
    /// Thread-safe operation
    pub fn isFieldSearchable(
        self: *SchemaCatalog,
        type_name: []const u8,
        field_name: []const u8,
    ) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.schemas.get(type_name)) |type_meta_ptr| {
            return type_meta_ptr.isFieldSearchable(field_name);
        }
        return false;
    }

    /// Get field metadata for a specific field
    /// Thread-safe operation
    pub fn getFieldMetadata(
        self: *SchemaCatalog,
        type_name: []const u8,
        field_name: []const u8,
    ) ?annotations.FieldMetadata {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.schemas.get(type_name)) |type_meta_ptr| {
            return type_meta_ptr.getField(field_name);
        }
        return null;
    }

    /// Remove a type from the catalog
    /// Thread-safe operation
    pub fn removeType(self: *SchemaCatalog, type_name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.schemas.fetchRemove(type_name)) |kv| {
            self.allocator.free(kv.key);
            var type_meta_ptr = kv.value;
            type_meta_ptr.deinit();
            self.allocator.destroy(type_meta_ptr);
        } else {
            return error.TypeNotFound;
        }
    }

    /// Grant READ_PLAINTEXT privilege to a role for a specific field
    /// Thread-safe operation
    pub fn grantPlaintextAccess(
        self: *SchemaCatalog,
        type_name: []const u8,
        field_name: []const u8,
        role: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Get the type metadata (mutable)
        const type_meta_ptr = self.schemas.getPtr(type_name) orelse return error.TypeNotFound;
        const type_meta = type_meta_ptr.*;

        // Get the field metadata
        const field_meta_ptr = type_meta.fields.getPtr(field_name) orelse return error.FieldNotFound;

        // Check if role already exists
        for (field_meta_ptr.visibility.to_roles) |existing_role| {
            if (std.mem.eql(u8, existing_role, role)) {
                return; // Role already has access
            }
        }

        // Add the role to the visibility list
        const new_roles = try self.allocator.alloc([]const u8, field_meta_ptr.visibility.to_roles.len + 1);
        if (field_meta_ptr.visibility.to_roles.len > 0) {
            @memcpy(new_roles[0..field_meta_ptr.visibility.to_roles.len], field_meta_ptr.visibility.to_roles);
            // Free old roles array if it was allocated
            if (field_meta_ptr.visibility.to_roles.len > 0) {
                self.allocator.free(field_meta_ptr.visibility.to_roles);
            }
        }
        new_roles[field_meta_ptr.visibility.to_roles.len] = try self.allocator.dupe(u8, role);

        field_meta_ptr.visibility.to_roles = new_roles;

        // Save catalog after grant
        saveCatalog(self) catch |err| {
            log.err("CRITICAL: Failed to persist catalog after plaintext access grant (security config lost on restart)", &.{
                Attr.err("error", err),
            });
        };
    }

    /// Revoke READ_PLAINTEXT privilege from a role for a specific field
    /// Thread-safe operation
    pub fn revokePlaintextAccess(
        self: *SchemaCatalog,
        type_name: []const u8,
        field_name: []const u8,
        role: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Get the type metadata (mutable)
        const type_meta_ptr = self.schemas.getPtr(type_name) orelse return error.TypeNotFound;
        const type_meta = type_meta_ptr.*;

        // Get the field metadata
        const field_meta_ptr = type_meta.fields.getPtr(field_name) orelse return error.FieldNotFound;

        // Find and remove the role
        var found_index: ?usize = null;
        for (field_meta_ptr.visibility.to_roles, 0..) |existing_role, i| {
            if (std.mem.eql(u8, existing_role, role)) {
                found_index = i;
                break;
            }
        }

        if (found_index == null) {
            return; // Role doesn't have access, nothing to revoke
        }

        // Create new roles array without the removed role
        if (field_meta_ptr.visibility.to_roles.len == 1) {
            // Last role being removed
            self.allocator.free(field_meta_ptr.visibility.to_roles[0]);
            self.allocator.free(field_meta_ptr.visibility.to_roles);
            field_meta_ptr.visibility.to_roles = &.{};
        } else {
            const new_roles = try self.allocator.alloc([]const u8, field_meta_ptr.visibility.to_roles.len - 1);
            var new_idx: usize = 0;
            for (field_meta_ptr.visibility.to_roles, 0..) |existing_role, i| {
                if (i != found_index.?) {
                    new_roles[new_idx] = existing_role;
                    new_idx += 1;
                } else {
                    self.allocator.free(existing_role);
                }
            }
            self.allocator.free(field_meta_ptr.visibility.to_roles);
            field_meta_ptr.visibility.to_roles = new_roles;
        }

        // Save catalog after revoke
        saveCatalog(self) catch |err| {
            log.err("CRITICAL: Failed to persist catalog after plaintext access revoke (security config lost on restart)", &.{
                Attr.err("error", err),
            });
        };
    }

    /// Get count of registered types
    pub fn count(self: *SchemaCatalog) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.schemas.count();
    }
};

/// Global singleton schema catalog instance
var global_catalog: ?*SchemaCatalog = null;
var global_catalog_mutex: std.Thread.Mutex = .{};

/// Get or create the global schema catalog
/// Thread-safe singleton access
pub fn globalCatalog(allocator: std.mem.Allocator) !*SchemaCatalog {
    global_catalog_mutex.lock();
    defer global_catalog_mutex.unlock();

    if (global_catalog == null) {
        const catalog = try allocator.create(SchemaCatalog);
        catalog.* = SchemaCatalog.init(allocator);

        // Load persisted catalog if it exists
        loadCatalog(catalog) catch |err| {
            log.warn("Failed to load persisted catalog (starting with empty catalog)", &.{
                Attr.err("error", err),
            });
        };

        global_catalog = catalog;
    }

    return global_catalog.?;
}

/// Reset global catalog (for testing)
pub fn resetGlobalCatalog(allocator: std.mem.Allocator) void {
    _ = allocator; // Unused, kept for API compatibility
    global_catalog_mutex.lock();
    defer global_catalog_mutex.unlock();

    if (global_catalog) |catalog| {
        const catalog_allocator = catalog.allocator;
        catalog.deinit();
        catalog_allocator.destroy(catalog);
        global_catalog = null;
    }
}

/// Save catalog to disk with TDE encryption
pub fn saveCatalog(catalog: *SchemaCatalog) !void {
    const allocator = catalog.allocator;

    // Get catalog path from GEODE_DATA_DIR or use default
    const data_dir = std.process.getEnvVarOwned(allocator, "GEODE_DATA_DIR") catch |err| blk: {
        if (err == error.EnvironmentVariableNotFound) {
            break :blk try allocator.dupe(u8, "/tmp");
        }
        return err;
    };
    defer allocator.free(data_dir);

    const catalog_path = try std.fmt.allocPrint(allocator, "{s}/geode_fle_catalog.dat", .{data_dir});
    defer allocator.free(catalog_path);

    // Buffer all data to memory first for TDE encryption
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer buffer.deinit(allocator);

    // Write type count
    var type_count_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &type_count_buf, @intCast(catalog.schemas.count()), .little);
    try buffer.appendSlice(allocator, &type_count_buf);

    // Write each type
    var type_iter = catalog.schemas.iterator();
    while (type_iter.next()) |entry| {
        const type_name = entry.key_ptr.*;
        const type_meta = entry.value_ptr.*;

        // Write type name
        var type_name_len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &type_name_len_buf, @intCast(type_name.len), .little);
        try buffer.appendSlice(allocator, &type_name_len_buf);
        try buffer.appendSlice(allocator, type_name);

        // Write field count
        var field_count_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &field_count_buf, @intCast(type_meta.fields.count()), .little);
        try buffer.appendSlice(allocator, &field_count_buf);

        // Write each field
        var field_iter = type_meta.fields.iterator();
        while (field_iter.next()) |field_entry| {
            const field_name = field_entry.key_ptr.*;
            const field_meta = field_entry.value_ptr.*;

            // Write field name
            var field_name_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &field_name_len_buf, @intCast(field_name.len), .little);
            try buffer.appendSlice(allocator, &field_name_len_buf);
            try buffer.appendSlice(allocator, field_name);

            // Write encryption config
            try buffer.appendSlice(allocator, &[_]u8{@intFromBool(field_meta.encryption.enabled)});
            if (field_meta.encryption.enabled) {
                try buffer.appendSlice(allocator, &[_]u8{@intFromEnum(field_meta.encryption.algorithm)});
                try buffer.appendSlice(allocator, &[_]u8{@intFromEnum(field_meta.encryption.key_scope)});
            }

            // Write search config
            try buffer.appendSlice(allocator, &[_]u8{@intFromBool(field_meta.search.enabled)});
            if (field_meta.search.enabled) {
                try buffer.appendSlice(allocator, &[_]u8{@intFromEnum(field_meta.search.index_type)});
            }

            // Write visibility config (role count and roles)
            var role_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &role_count_buf, @intCast(field_meta.visibility.to_roles.len), .little);
            try buffer.appendSlice(allocator, &role_count_buf);

            for (field_meta.visibility.to_roles) |role| {
                var role_len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &role_len_buf, @intCast(role.len), .little);
                try buffer.appendSlice(allocator, &role_len_buf);
                try buffer.appendSlice(allocator, role);
            }
        }
    }

    // Encrypt and write to file
    try tde.writeEncryptedFile(allocator, catalog_path, buffer.items);
}

/// Load catalog from disk with TDE decryption
pub fn loadCatalog(catalog: *SchemaCatalog) !void {
    const allocator = catalog.allocator;

    // Get catalog path from GEODE_DATA_DIR or use default
    const data_dir = std.process.getEnvVarOwned(allocator, "GEODE_DATA_DIR") catch |err| blk: {
        if (err == error.EnvironmentVariableNotFound) {
            break :blk try allocator.dupe(u8, "/tmp");
        }
        return err;
    };
    defer allocator.free(data_dir);

    const catalog_path = try std.fmt.allocPrint(allocator, "{s}/geode_fle_catalog.dat", .{data_dir});
    defer allocator.free(catalog_path);

    // Check if file exists first
    std.fs.cwd().access(catalog_path, .{}) catch |err| {
        if (err == error.FileNotFound) return; // No catalog file yet
        return err;
    };

    // Read and decrypt file using TDE
    const data = try tde.readDecryptedFile(allocator, catalog_path);
    defer allocator.free(data);

    // Create stream to read from decrypted data
    var stream = std.io.fixedBufferStream(data);
    var reader = stream.reader();

    // Read type count
    var type_count_buf: [4]u8 = undefined;
    const bytes_read = try reader.readAll(&type_count_buf);
    if (bytes_read != 4) return error.CorruptedCatalog;
    const type_count = std.mem.readInt(u32, &type_count_buf, .little);
    if (type_count > 10000) return error.CorruptedCatalog; // Sanity check

    // Read each type
    var i: usize = 0;
    while (i < type_count) : (i += 1) {
        // Read type name
        var type_name_len_buf: [4]u8 = undefined;
        const name_len_bytes = try reader.readAll(&type_name_len_buf);
        if (name_len_bytes != 4) return error.CorruptedCatalog;
        const type_name_len = std.mem.readInt(u32, &type_name_len_buf, .little);
        if (type_name_len > 1024) return error.CorruptedCatalog; // Sanity check

        const type_name = try allocator.alloc(u8, type_name_len);
        const name_bytes = try reader.readAll(type_name);
        if (name_bytes != type_name_len) return error.CorruptedCatalog;

        // Create type metadata
        var type_meta = annotations.TypeMetadata.init(allocator, type_name);

        // Read field count
        var field_count_buf: [4]u8 = undefined;
        const field_count_bytes = try reader.readAll(&field_count_buf);
        if (field_count_bytes != 4) return error.CorruptedCatalog;
        const field_count = std.mem.readInt(u32, &field_count_buf, .little);
        if (field_count > 1000) return error.CorruptedCatalog; // Sanity check

        // Read each field
        var j: usize = 0;
        while (j < field_count) : (j += 1) {
            // Read field name
            var field_name_len_buf: [4]u8 = undefined;
            const fname_len_bytes = try reader.readAll(&field_name_len_buf);
            if (fname_len_bytes != 4) return error.CorruptedCatalog;
            const field_name_len = std.mem.readInt(u32, &field_name_len_buf, .little);
            if (field_name_len > 1024) return error.CorruptedCatalog; // Sanity check

            const field_name = try allocator.alloc(u8, field_name_len);
            const fname_bytes = try reader.readAll(field_name);
            if (fname_bytes != field_name_len) return error.CorruptedCatalog;

            var field_meta = annotations.FieldMetadata{
                .field_name = field_name,
            };

            // Read encryption config
            var enc_enabled_buf: [1]u8 = undefined;
            _ = try reader.readAll(&enc_enabled_buf);
            field_meta.encryption.enabled = enc_enabled_buf[0] != 0;

            if (field_meta.encryption.enabled) {
                var alg_buf: [1]u8 = undefined;
                _ = try reader.readAll(&alg_buf);
                field_meta.encryption.algorithm = @enumFromInt(alg_buf[0]);

                var scope_buf: [1]u8 = undefined;
                _ = try reader.readAll(&scope_buf);
                field_meta.encryption.key_scope = @enumFromInt(scope_buf[0]);
            }

            // Read search config
            var search_enabled_buf: [1]u8 = undefined;
            _ = try reader.readAll(&search_enabled_buf);
            field_meta.search.enabled = search_enabled_buf[0] != 0;

            if (field_meta.search.enabled) {
                var idx_type_buf: [1]u8 = undefined;
                _ = try reader.readAll(&idx_type_buf);
                field_meta.search.index_type = @enumFromInt(idx_type_buf[0]);
            }

            // Read visibility config
            var role_count_buf: [4]u8 = undefined;
            const role_count_bytes = try reader.readAll(&role_count_buf);
            if (role_count_bytes != 4) return error.CorruptedCatalog;
            const role_count = std.mem.readInt(u32, &role_count_buf, .little);
            if (role_count > 100) return error.CorruptedCatalog; // Sanity check

            if (role_count > 0) {
                const roles = try allocator.alloc([]const u8, role_count);
                var k: usize = 0;
                while (k < role_count) : (k += 1) {
                    var role_len_buf: [4]u8 = undefined;
                    const rlen_bytes = try reader.readAll(&role_len_buf);
                    if (rlen_bytes != 4) return error.CorruptedCatalog;
                    const role_len = std.mem.readInt(u32, &role_len_buf, .little);
                    if (role_len > 256) return error.CorruptedCatalog; // Sanity check

                    const role = try allocator.alloc(u8, role_len);
                    const role_bytes = try reader.readAll(role);
                    if (role_bytes != role_len) return error.CorruptedCatalog;
                    roles[k] = role;
                }
                field_meta.visibility.to_roles = roles;
            }

            try type_meta.fields.put(field_name, field_meta);
        }

        // Register the type
        const type_name_dup = try allocator.dupe(u8, type_name);
        const type_meta_ptr = try allocator.create(annotations.TypeMetadata);
        type_meta_ptr.* = type_meta;
        try catalog.schemas.put(type_name_dup, type_meta_ptr);

        allocator.free(type_name);
    }
}

test "Schema catalog basic operations" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var catalog = SchemaCatalog.init(allocator);
    defer catalog.deinit();

    // Create type metadata
    var type_meta = annotations.TypeMetadata.init(allocator, "Person");
    // Note: don't defer type_meta.deinit() because catalog takes ownership

    // Add encrypted field
    try annotations.applyAnnotations(
        allocator,
        &type_meta,
        "ssn",
        "@encrypted(alg:\"AES-256-GCM\")",
    );

    // Register type (catalog takes ownership)
    try catalog.registerType("Person", type_meta);

    // Verify registration
    try testing.expect(catalog.isFieldEncrypted("Person", "ssn"));
    try testing.expect(!catalog.isFieldEncrypted("Person", "name"));
    try testing.expectEqual(@as(usize, 1), catalog.count());
}

test "Schema catalog thread safety" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var catalog = SchemaCatalog.init(allocator);
    defer catalog.deinit();

    // Multiple concurrent reads should work
    const is_encrypted_1 = catalog.isFieldEncrypted("Person", "ssn");
    const is_encrypted_2 = catalog.isFieldEncrypted("Person", "email");

    try testing.expect(!is_encrypted_1); // Not registered yet
    try testing.expect(!is_encrypted_2);
}

test "Schema catalog global singleton" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    defer resetGlobalCatalog(allocator);

    const catalog1 = try globalCatalog(allocator);
    const catalog2 = try globalCatalog(allocator);

    // Should be the same instance
    try testing.expectEqual(catalog1, catalog2);
}
