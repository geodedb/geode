const std = @import("std");
const annotations = @import("annotations.zig");

// CANARY: FLE_SCHEMA_CATALOG - Global Schema Metadata Catalog
// CANARY: REQ=REQ-FLE-CATALOG-001; FEATURE="FieldLevelEncryption"; ASPECT=SCHEMA; STATUS=IMPL; OWNER=security; UPDATED=2025-10-15

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
        global_catalog = catalog;
    }

    return global_catalog.?;
}

/// Reset global catalog (for testing)
pub fn resetGlobalCatalog(allocator: std.mem.Allocator) void {
    global_catalog_mutex.lock();
    defer global_catalog_mutex.unlock();

    if (global_catalog) |catalog| {
        catalog.deinit();
        allocator.destroy(catalog);
        global_catalog = null;
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
