const std = @import("std");

const annotations = @import("annotations.zig");
const tde = @import("../storage/tde_file_encryption.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Schema; STATUS=EXEMPT; OWNER=schema; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("schema");
const Attr = logging.Attr;
const global_allocator = std.heap.smp_allocator;

// CANARY: REQ=REQ-TDE-FILELEVEL-001; FEATURE="TDEFileLevelEncryption"; ASPECT=FLECatalog; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28

// Global Schema Metadata Catalog
// CANARY: REQ=REQ-FLE-CATALOG-001; FEATURE="FieldLevelEncryption"; ASPECT=SCHEMA; STATUS=TESTED; TEST=tests/test_tde_kms_integration.zig; OWNER=security; UPDATED=2026-01-15

/// Thread-safe global schema catalog for field-level encryption metadata
///
/// SONNY-6324: the catalog owns every string it holds: the type names (the
/// map keys, also `TypeMetadata.type_name`), the field names (the field map
/// keys, also `FieldMetadata.field_name`), the role lists and their strings,
/// and the classification tags. A list is allocated exactly when it is not
/// empty.
pub const SchemaCatalog = struct {
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    allocator: std.mem.Allocator,
    schemas: std.StringHashMap(*annotations.TypeMetadata),
    /// SONNY-6324: memory holds a revoke that a save could not write (a
    /// revoke stays applied when its save fails: it fails closed). Until a
    /// save succeeds, every change, a no-op one included, saves the catalog.
    unsaved: bool = false,
    /// SONNY-6327: the process-global instance (`globalCatalog`). When it
    /// gains a field it raises `global_has_fields`, the lock-free "is any
    /// field encrypted at all" answer the read and write paths check first.
    is_global: bool = false,

    /// Initialize a new schema catalog
    pub fn init(allocator: std.mem.Allocator) SchemaCatalog {
        return .{
            .allocator = allocator,
            .schemas = std.StringHashMap(*annotations.TypeMetadata).init(allocator),
        };
    }

    /// Clean up catalog resources
    pub fn deinit(self: *SchemaCatalog) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        self.clearSchemasLocked();
    }

    /// Reset catalog contents while keeping the same instance pointer.
    /// This avoids invalidating outstanding references during concurrent tests.
    pub fn reset(self: *SchemaCatalog) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        self.clearSchemasLocked();
        self.schemas = std.StringHashMap(*annotations.TypeMetadata).init(self.allocator);
        self.unsaved = false;
    }

    fn clearSchemasLocked(self: *SchemaCatalog) void {
        // Each key is its type's own name copy (`type_name`).
        freeSchemaMap(self.allocator, &self.schemas);
    }

    /// Register a new type with its field metadata.
    /// SONNY-6324: the catalog stores its own copy of every field; the
    /// caller keeps ownership of `type_meta` (it used to be adopted with
    /// borrowed field names and roles, which the catalog then could not
    /// free). Thread-safe operation.
    pub fn registerType(
        self: *SchemaCatalog,
        type_name: []const u8,
        type_meta: annotations.TypeMetadata,
    ) !void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        // Check if type already exists
        if (self.schemas.contains(type_name)) {
            return error.TypeAlreadyExists;
        }

        const type_meta_ptr = try newTypeMeta(self.allocator, type_name);
        errdefer {
            const name = type_meta_ptr.type_name;
            destroyTypeMeta(self.allocator, type_meta_ptr);
            self.allocator.free(name);
        }
        var it = type_meta.fields.valueIterator();
        while (it.next()) |field| {
            const owned = try dupeFieldMeta(self.allocator, field.*);
            type_meta_ptr.fields.put(owned.field_name, owned) catch |err| {
                freeFieldMeta(self.allocator, owned);
                return err;
            };
        }
        try self.schemas.put(type_meta_ptr.type_name, type_meta_ptr);
        self.noteFieldsLocked();
    }

    /// SONNY-6327: the global catalog now holds a field (caller holds the
    /// mutex). Never lowered except by `resetGlobalCatalog`.
    fn noteFieldsLocked(self: *SchemaCatalog) void {
        if (self.is_global and self.schemas.count() > 0) global_has_fields.store(true, .release);
    }

    // CANARY: REQ=REQ-SONNY-6327-FLE-CATALOG-READS-UNDER-LOCK; FEATURE="FieldLevelEncryption"; ASPECT=NoBorrowedReads; STATUS=TESTED; TEST=tests/test_sonny6327_fle_read_gaps.zig; OWNER=security; UPDATED=2026-11-11
    // SONNY-6327: every read answers its question while it holds the mutex
    // and returns values, or a copy the caller owns. `getType` (a pointer
    // into the catalog) and `getFieldMetadata` (a struct of borrowed field
    // name and role slices) handed out catalog memory after unlocking; a
    // reconfigure frees the old field copy and a grant or revoke frees the
    // old role list, so a reader then read freed memory, in the plaintext
    // authorization decision too. Nothing here allocates under the mutex
    // except the explicit copies, and nothing blocks.

    fn fieldLocked(self: *SchemaCatalog, type_name: []const u8, field_name: []const u8) ?*const annotations.FieldMetadata {
        const type_meta_ptr = self.schemas.get(type_name) orelse return null;
        return type_meta_ptr.fields.getPtr(field_name);
    }

    /// What the catalog says about one field, by value.
    pub const FieldPolicy = struct {
        encrypted: bool,
        searchable: bool,
        algorithm: annotations.EncryptionConfig.Algorithm,
    };

    /// The field's policy, or null when the type or the field is not in the
    /// catalog. Thread-safe; returns no catalog memory.
    pub fn fieldPolicy(
        self: *SchemaCatalog,
        type_name: []const u8,
        field_name: []const u8,
    ) ?FieldPolicy {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const field = self.fieldLocked(type_name, field_name) orelse return null;
        return .{
            .encrypted = field.isEncrypted(),
            .searchable = field.isSearchable(),
            .algorithm = field.encryption.algorithm,
        };
    }

    /// May `role` read the field in plaintext? Decided under the mutex.
    /// A field the catalog does not list is not FLE-protected (true); an
    /// encrypted field with no visibility roles is readable by nobody; no
    /// role reads nothing that lists roles (fail closed).
    pub fn canReadPlaintext(
        self: *SchemaCatalog,
        type_name: []const u8,
        field_name: []const u8,
        role: ?[]const u8,
    ) bool {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const field = self.fieldLocked(type_name, field_name) orelse return true;
        return canReadLocked(field, role);
    }

    fn canReadLocked(field: *const annotations.FieldMetadata, role: ?[]const u8) bool {
        if (field.visibility.to_roles.len == 0) return !field.isEncrypted();
        const r = role orelse return false;
        for (field.visibility.to_roles) |allowed| {
            if (std.mem.eql(u8, r, allowed)) return true;
        }
        return false;
    }

    /// Everything a read of the field needs, in one lock acquisition.
    pub const ReadDecision = struct {
        encrypted: bool = false,
        searchable: bool = false,
        plaintext_allowed: bool = true,
    };

    pub fn readDecision(
        self: *SchemaCatalog,
        type_name: []const u8,
        field_name: []const u8,
        role: ?[]const u8,
    ) ReadDecision {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const field = self.fieldLocked(type_name, field_name) orelse return .{};
        return .{
            .encrypted = field.isEncrypted(),
            .searchable = field.isSearchable(),
            .plaintext_allowed = canReadLocked(field, role),
        };
    }

    /// Is `role` listed in the field's visibility roles?
    pub fn hasVisibilityRole(
        self: *SchemaCatalog,
        type_name: []const u8,
        field_name: []const u8,
        role: []const u8,
    ) bool {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const field = self.fieldLocked(type_name, field_name) orelse return false;
        for (field.visibility.to_roles) |allowed| {
            if (std.mem.eql(u8, role, allowed)) return true;
        }
        return false;
    }

    /// Is the type in the catalog?
    pub fn hasType(self: *SchemaCatalog, type_name: []const u8) bool {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.schemas.contains(type_name);
    }

    /// A copy of one field's metadata (its name, roles and tags) that the
    /// caller owns: free it with `freeFieldCopy` and the same allocator.
    pub fn copyFieldMetadata(
        self: *SchemaCatalog,
        allocator: std.mem.Allocator,
        type_name: []const u8,
        field_name: []const u8,
    ) !?annotations.FieldMetadata {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const field = self.fieldLocked(type_name, field_name) orelse return null;
        return try dupeFieldMeta(allocator, field.*);
    }

    /// Copies of every field of a type, or null when the type is not in the
    /// catalog. The caller owns them: free with `freeFieldCopies`.
    pub fn copyTypeFields(
        self: *SchemaCatalog,
        allocator: std.mem.Allocator,
        type_name: []const u8,
    ) !?[]annotations.FieldMetadata {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const type_meta_ptr = self.schemas.get(type_name) orelse return null;
        const out = try allocator.alloc(annotations.FieldMetadata, type_meta_ptr.fields.count());
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |f| freeFieldMeta(allocator, f);
            allocator.free(out);
        }
        var it = type_meta_ptr.fields.valueIterator();
        while (it.next()) |field| {
            out[filled] = try dupeFieldMeta(allocator, field.*);
            filled += 1;
        }
        return out;
    }

    /// Check if a field in a type is encrypted
    /// Thread-safe operation
    pub fn isFieldEncrypted(
        self: *SchemaCatalog,
        type_name: []const u8,
        field_name: []const u8,
    ) bool {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.schemas.get(type_name)) |type_meta_ptr| {
            return type_meta_ptr.isFieldEncrypted(field_name);
        }
        return false;
    }

    /// SONNY-6362: is `field_name` encrypted in any type? (MERGE refuses to
    /// match on such a field, `fle_integration.fieldEncryptedInAnyType`.)
    pub fn isFieldEncryptedInAnyType(self: *SchemaCatalog, field_name: []const u8) bool {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        var it = self.schemas.valueIterator();
        while (it.next()) |type_meta_ptr| {
            if (type_meta_ptr.*.isFieldEncrypted(field_name)) return true;
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
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.schemas.get(type_name)) |type_meta_ptr| {
            return type_meta_ptr.isFieldSearchable(field_name);
        }
        return false;
    }

    /// Remove a type from the catalog
    /// Thread-safe operation
    pub fn removeType(self: *SchemaCatalog, type_name: []const u8) !void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.schemas.fetchRemove(type_name)) |kv| {
            destroyTypeMeta(self.allocator, kv.value);
            self.allocator.free(kv.key);
        } else {
            return error.TypeNotFound;
        }
    }

    // CANARY: REQ=REQ-SONNY-6324-FLE-CATALOG-FAIL-CLOSED; FEATURE="FieldLevelEncryption"; ASPECT=SaveFailureIsAnError; STATUS=TESTED; TEST=tests/test_sonny6324_fle_catalog_fail_closed.zig; OWNER=security; UPDATED=2026-11-11
    /// SONNY-6324: save the catalog after a change. Caller holds the mutex.
    /// A memory-only catalog (no data directory) saves nothing and succeeds.
    fn persistLocked(self: *SchemaCatalog) !void {
        saveCatalog(self) catch |err| {
            log.err("FLE catalog save failed; the change is not durable", &.{
                Attr.string("error", @errorName(err)),
            });
            return err;
        };
        self.unsaved = false;
    }

    /// SONNY-6324: a change that changes nothing still saves a pending
    /// (unsaved) revoke, so a retried revoke, or any other change, makes it
    /// durable. Caller holds the mutex.
    fn persistPendingLocked(self: *SchemaCatalog, comptime failure: anyerror) !void {
        if (!self.unsaved) return;
        self.persistLocked() catch return failure;
    }

    /// Configure a field for encryption
    /// Creates the type if it doesn't exist, adds or updates the field if it does
    /// Thread-safe operation
    ///
    /// SONNY-6324: the change is saved before this returns. If the save
    /// fails the change is undone (the field is as it was: unconfigured, or
    /// configured as before) and `error.FleCatalogNotPersisted` is returned,
    /// so memory matches disk and the caller is told nothing changed. The
    /// mutex is held from the change to the save or the undo, so no write
    /// can encrypt (or not) a value under a configuration that is then
    /// undone. It used to log the failed save and return success: a field
    /// the operator was told is encrypted was not encrypted after a restart.
    /// CANARY: REQ=REQ-FLE-CATALOG-002; FEATURE="FLECatalog"; ASPECT=ConfigureField; STATUS=TESTED; OWNER=security; UPDATED=2026-11-11
    pub fn configureField(
        self: *SchemaCatalog,
        type_name: []const u8,
        field_meta: annotations.FieldMetadata,
    ) !void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        // Deep-copy the field metadata so the catalog owns all strings.
        // The caller's strings (e.g. AST nodes) may be freed after this call.
        const owned = try dupeFieldMeta(self.allocator, field_meta);

        if (self.schemas.get(type_name)) |type_meta_ptr| {
            if (type_meta_ptr.fields.getEntry(field_meta.field_name)) |entry| {
                // Update: swap in the new copy, keep the old one until saved.
                const old = entry.value_ptr.*;
                entry.key_ptr.* = owned.field_name;
                entry.value_ptr.* = owned;
                self.persistLocked() catch {
                    entry.key_ptr.* = old.field_name;
                    entry.value_ptr.* = old;
                    freeFieldMeta(self.allocator, owned);
                    return error.FleCatalogNotPersisted;
                };
                // The old key is the old copy's field name.
                freeFieldMeta(self.allocator, old);
                self.noteFieldsLocked();
                return;
            }
            type_meta_ptr.fields.put(owned.field_name, owned) catch |err| {
                freeFieldMeta(self.allocator, owned);
                return err;
            };
            self.persistLocked() catch {
                _ = type_meta_ptr.fields.remove(owned.field_name);
                freeFieldMeta(self.allocator, owned);
                return error.FleCatalogNotPersisted;
            };
            self.noteFieldsLocked();
            return;
        }

        const type_meta_ptr = newTypeMeta(self.allocator, type_name) catch |err| {
            freeFieldMeta(self.allocator, owned);
            return err;
        };
        if (insertNewType(self, type_meta_ptr, owned)) |_| {} else |err| {
            const name = type_meta_ptr.type_name;
            destroyTypeMeta(self.allocator, type_meta_ptr); // frees `owned` if it went in
            self.allocator.free(name);
            if (err == error.FieldNotInserted) freeFieldMeta(self.allocator, owned);
            return error.OutOfMemory;
        }
        self.persistLocked() catch {
            _ = self.schemas.remove(type_meta_ptr.type_name);
            const name = type_meta_ptr.type_name;
            destroyTypeMeta(self.allocator, type_meta_ptr);
            self.allocator.free(name);
            return error.FleCatalogNotPersisted;
        };
        self.noteFieldsLocked();
    }

    /// Put `owned` into the new type and the type into the catalog. On
    /// `FieldNotInserted` nothing went in; on `TypeNotInserted` the field is
    /// in the type, which is not in the catalog.
    fn insertNewType(self: *SchemaCatalog, type_meta_ptr: *annotations.TypeMetadata, owned: annotations.FieldMetadata) error{ FieldNotInserted, TypeNotInserted }!void {
        type_meta_ptr.fields.put(owned.field_name, owned) catch return error.FieldNotInserted;
        self.schemas.put(type_meta_ptr.type_name, type_meta_ptr) catch return error.TypeNotInserted;
    }

    /// Grant READ_PLAINTEXT privilege to a role for a specific field
    /// Thread-safe operation
    ///
    /// SONNY-6324: saved before this returns; if the save fails the grant is
    /// undone and `error.FleCatalogNotPersisted` returned (it used to be
    /// logged and reported as granted, and lost at the next start).
    pub fn grantPlaintextAccess(
        self: *SchemaCatalog,
        type_name: []const u8,
        field_name: []const u8,
        role: []const u8,
    ) !void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        // Get the type metadata (mutable)
        const type_meta = self.schemas.get(type_name) orelse return error.TypeNotFound;

        // Get the field metadata
        const field_meta_ptr = type_meta.fields.getPtr(field_name) orelse return error.FieldNotFound;

        // Check if role already exists
        for (field_meta_ptr.visibility.to_roles) |existing_role| {
            if (std.mem.eql(u8, existing_role, role)) {
                // Role already has access
                return self.persistPendingLocked(error.FleCatalogNotPersisted);
            }
        }

        // Add the role to the visibility list
        const old_roles = field_meta_ptr.visibility.to_roles;
        const role_copy = try self.allocator.dupe(u8, role);
        const new_roles = self.allocator.alloc([]const u8, old_roles.len + 1) catch |err| {
            self.allocator.free(role_copy);
            return err;
        };
        @memcpy(new_roles[0..old_roles.len], old_roles);
        new_roles[old_roles.len] = role_copy;
        field_meta_ptr.visibility.to_roles = new_roles;

        self.persistLocked() catch {
            field_meta_ptr.visibility.to_roles = old_roles;
            self.allocator.free(new_roles);
            self.allocator.free(role_copy);
            return error.FleCatalogNotPersisted;
        };
        if (old_roles.len > 0) self.allocator.free(old_roles);
    }

    /// Revoke READ_PLAINTEXT privilege from a role for a specific field
    /// Thread-safe operation
    ///
    /// SONNY-6324: fails CLOSED. The role loses access in memory at once; if
    /// the save then fails the revoke stays applied (undoing it would hand
    /// the access back) and `error.FleRevokeNotPersisted` tells the caller
    /// it is not durable: the role has it back at the next start unless a
    /// later change of the catalog (a retried revoke included) is saved. It
    /// used to be logged and reported as revoked, and the reader regained
    /// plaintext access at the next start.
    pub fn revokePlaintextAccess(
        self: *SchemaCatalog,
        type_name: []const u8,
        field_name: []const u8,
        role: []const u8,
    ) !void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        // Get the type metadata (mutable)
        const type_meta = self.schemas.get(type_name) orelse return error.TypeNotFound;

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

        const index = found_index orelse {
            // Role doesn't have access in memory. A revoke that could not be
            // saved earlier is saved now.
            return self.persistPendingLocked(error.FleRevokeNotPersisted);
        };

        // Build the shorter list first: an allocation failure changes nothing.
        const old_roles = field_meta_ptr.visibility.to_roles;
        const new_roles: [][]const u8 = if (old_roles.len == 1) &.{} else blk: {
            const roles = try self.allocator.alloc([]const u8, old_roles.len - 1);
            var new_idx: usize = 0;
            for (old_roles, 0..) |existing_role, i| {
                if (i == index) continue;
                roles[new_idx] = existing_role;
                new_idx += 1;
            }
            break :blk roles;
        };
        self.allocator.free(old_roles[index]);
        self.allocator.free(old_roles);
        field_meta_ptr.visibility.to_roles = new_roles;

        self.persistLocked() catch {
            self.unsaved = true;
            return error.FleRevokeNotPersisted;
        };
    }

    /// Get count of registered types
    pub fn count(self: *SchemaCatalog) usize {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        return self.schemas.count();
    }
};

/// SONNY-6324: a catalog-owned copy of `meta` (field name, roles,
/// classification tags). Free it with `freeFieldMeta`.
fn dupeFieldMeta(allocator: std.mem.Allocator, meta: annotations.FieldMetadata) !annotations.FieldMetadata {
    const name = try allocator.dupe(u8, meta.field_name);
    errdefer allocator.free(name);
    const roles = try dupeStringList(allocator, meta.visibility.to_roles);
    errdefer freeStringList(allocator, roles);
    const tags = try dupeStringList(allocator, meta.classification.tags);
    var owned = meta;
    owned.field_name = name;
    owned.visibility = .{ .to_roles = roles };
    owned.classification = .{ .tags = tags };
    return owned;
}

fn freeFieldMeta(allocator: std.mem.Allocator, meta: annotations.FieldMetadata) void {
    allocator.free(meta.field_name);
    freeStringList(allocator, meta.visibility.to_roles);
    freeStringList(allocator, meta.classification.tags);
}

/// SONNY-6327: free a `copyFieldMetadata` result.
pub fn freeFieldCopy(allocator: std.mem.Allocator, meta: annotations.FieldMetadata) void {
    freeFieldMeta(allocator, meta);
}

/// SONNY-6327: free a `copyTypeFields` result.
pub fn freeFieldCopies(allocator: std.mem.Allocator, fields: []annotations.FieldMetadata) void {
    for (fields) |f| freeFieldMeta(allocator, f);
    allocator.free(fields);
}

/// A copy of `list` and its strings; the empty list is not allocated.
fn dupeStringList(allocator: std.mem.Allocator, list: []const []const u8) ![][]const u8 {
    if (list.len == 0) return &.{};
    const out = try allocator.alloc([]const u8, list.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |s| allocator.free(s);
        allocator.free(out);
    }
    for (list) |s| {
        out[filled] = try allocator.dupe(u8, s);
        filled += 1;
    }
    return out;
}

fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    if (list.len == 0) return;
    for (list) |s| allocator.free(s);
    allocator.free(list);
}

/// A new, empty, catalog-owned type whose `type_name` is its own copy (the
/// catalog uses it as the map key).
fn newTypeMeta(allocator: std.mem.Allocator, type_name: []const u8) !*annotations.TypeMetadata {
    const name = try allocator.dupe(u8, type_name);
    errdefer allocator.free(name);
    const type_meta_ptr = try allocator.create(annotations.TypeMetadata);
    type_meta_ptr.* = annotations.TypeMetadata.init(allocator, name);
    return type_meta_ptr;
}

/// Free a catalog-owned type: its fields (each key is its field's own name
/// copy), the map and the struct. The type name is left to the caller (it
/// is the catalog map's key).
fn destroyTypeMeta(allocator: std.mem.Allocator, type_meta_ptr: *annotations.TypeMetadata) void {
    var it = type_meta_ptr.fields.valueIterator();
    while (it.next()) |field| freeFieldMeta(allocator, field.*);
    type_meta_ptr.deinit();
    allocator.destroy(type_meta_ptr);
}

/// Global singleton schema catalog instance
var global_catalog: ?*SchemaCatalog = null;
var global_catalog_mutex: std.Io.Mutex = std.Io.Mutex.init;
/// SONNY-6324: why the catalog file could not be loaded. Set, every use of
/// the global catalog is refused (`error.FleCatalogUnavailable`) until
/// `resetGlobalCatalog` (a restart, in a server).
var global_load_failure: ?anyerror = null;
/// The global instance holds the file's contents (`resetGlobalCatalog`
/// empties it and clears this, so the next use loads the file again).
var global_loaded: bool = false;
/// SONNY-6327: the global catalog holds at least one field. Read without a
/// lock (`globalHasFields`), so a deployment with no FLE field configured
/// pays no lock on its string reads and writes.
var global_has_fields: std.atomic.Value(bool) = .init(false);

/// SONNY-6327: does the global catalog hold any field? Lock-free.
pub fn globalHasFields() bool {
    return global_has_fields.load(.acquire);
}

// CANARY: REQ=REQ-SONNY-6324-FLE-CATALOG-FAIL-CLOSED; FEATURE="FieldLevelEncryption"; ASPECT=LoadFailureIsAnError; STATUS=TESTED; TEST=tests/test_sonny6324_fle_catalog_fail_closed.zig; OWNER=security; UPDATED=2026-11-11
/// Get or create the global schema catalog
/// Thread-safe singleton access
///
/// SONNY-6324: a catalog file that exists and cannot be loaded (corrupt,
/// truncated, another or no GEODE_TDE_KEY, a symbolic link, unreadable) is
/// `error.FleCatalogUnavailable`, now and on every later call: the engine
/// cannot tell which fields are encrypted, so nothing that depends on it may
/// proceed. It used to start an EMPTY catalog, so fields configured as
/// encrypted were treated as plaintext and new values were written to disk
/// unencrypted. An absent file is a fresh store (empty catalog). The server
/// loads it at startup (`loadGlobalCatalogAtStartup`) and refuses to start.
pub fn globalCatalog(allocator: std.mem.Allocator) !*SchemaCatalog {
    _ = allocator; // Kept for API compatibility with existing call sites
    global_catalog_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_catalog_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (global_catalog) |catalog| {
        if (global_loaded) return catalog;
    }
    if (global_load_failure != null) return error.FleCatalogUnavailable;

    // The instance outlives a reset (callers may hold it); a reset makes the
    // next use load the file into it again.
    const catalog = global_catalog orelse blk: {
        const created = try global_allocator.create(SchemaCatalog);
        created.* = SchemaCatalog.init(global_allocator);
        created.is_global = true;
        global_catalog = created;
        break :blk created;
    };
    loadCatalog(catalog) catch |err| {
        // Running out of memory says nothing about the file: not sticky.
        if (err == error.OutOfMemory) return err;
        global_load_failure = err;
        logLoadFailure(err);
        return error.FleCatalogUnavailable;
    };
    global_loaded = true;
    if (catalog.count() > 0) global_has_fields.store(true, .release);
    return catalog;
}

/// SONNY-6324: why the global catalog could not be loaded, or null.
pub fn globalLoadFailure() ?anyerror {
    global_catalog_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_catalog_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    return global_load_failure;
}

/// SONNY-6324: what an operator is told about a catalog file that cannot be
/// loaded. Names a class of cause, never key material.
pub fn loadFailureReason(err: anyerror) []const u8 {
    return switch (err) {
        error.SymLinkLoop => "the path is a symbolic link, which is refused",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.DecryptionFailed => "it cannot be decrypted: GEODE_TDE_KEY is not the key it was written with, or the file is damaged",
        error.KeyRequired => "it is TDE-encrypted and GEODE_TDE_KEY is not set",
        error.InvalidKey => "GEODE_TDE_KEY is not 64 hexadecimal characters",
        error.CorruptedFile, error.CorruptedCatalog, error.EndOfStream => "it is corrupt or truncated",
        error.IsDir => "the path is a directory",
        else => "it could not be read",
    };
}

fn logLoadFailure(err: anyerror) void {
    const path = catalogFilePath(std.heap.smp_allocator) catch null;
    defer if (path) |p| std.heap.smp_allocator.free(p);
    log.err("FLE catalog cannot be loaded; field-level encryption is unavailable and writes that depend on it are refused", &.{
        Attr.string("path", path orelse "?"),
        Attr.string("reason", loadFailureReason(err)),
        Attr.string("error", @errorName(err)),
    });
}

/// SONNY-6324: the server loads the FLE catalog at startup, once its data
/// directory is set, so a catalog file that cannot be loaded stops the
/// server before it serves a request instead of being found mid-request.
/// The error names the file and the class of cause (no key material).
pub fn loadGlobalCatalogAtStartup() !void {
    _ = globalCatalog(global_allocator) catch |err| {
        const path = catalogFilePath(std.heap.smp_allocator) catch null;
        defer if (path) |p| std.heap.smp_allocator.free(p);
        const reason = if (globalLoadFailure()) |cause| loadFailureReason(cause) else @errorName(err);
        std.debug.print("[startup] FATAL: the field-level-encryption catalog {s} cannot be loaded: {s}. Refusing to start: without it the fields configured as encrypted would be written in plaintext. Restore the file (or the GEODE_TDE_KEY it was written with), or move it aside only if no field is encrypted.\n", .{ path orelse "(unknown path)", reason });
        return err;
    };
    warnIfLegacyTmpCatalog();
}

/// SONNY-6274 upgrade: a server run with `--data-dir` and no GEODE_DATA_DIR
/// kept its FLE catalog in /tmp. When the data directory has none and that
/// file exists, say so. It is not read (it may be another process's: the
/// reason it moved) and is no reason to refuse to start: it is not proof
/// that this store has encrypted data.
fn warnIfLegacyTmpCatalog() void {
    const legacy_path = "/tmp/" ++ catalog_file_name;
    const path = (catalogFilePath(std.heap.smp_allocator) catch return) orelse return;
    defer std.heap.smp_allocator.free(path);
    if (std.mem.eql(u8, path, legacy_path)) return;
    const io = std.Io.Threaded.global_single_threaded.io();
    if (std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false })) |_| return else |_| {}
    if (std.Io.Dir.cwd().statFile(io, legacy_path, .{ .follow_symlinks = false })) |_| {
        log.warn("No FLE catalog in the data directory, but " ++ legacy_path ++ " exists: before SONNY-6274 a server started with --data-dir and no GEODE_DATA_DIR kept its FLE catalog there. If it is this server's, stop the server and copy it into the data directory, or the fields it configures are not encrypted", &.{
            Attr.string("data_dir_catalog", path),
        });
        std.debug.print("[startup] WARNING: no FLE catalog at {s}, but {s} exists. Before SONNY-6274 a server started with --data-dir and no GEODE_DATA_DIR kept its FLE catalog there; if it is this server's, stop the server and copy it to {s}.\n", .{ path, legacy_path, path });
    } else |_| {}
}

/// Reset global catalog (for testing)
pub fn resetGlobalCatalog(allocator: std.mem.Allocator) void {
    _ = allocator; // Unused, kept for API compatibility
    global_catalog_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_catalog_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    global_load_failure = null;
    global_loaded = false;
    if (global_catalog) |catalog| {
        catalog.reset();
    }
    global_has_fields.store(false, .release);
}

pub const catalog_file_name = "geode_fle_catalog.dat";

// CANARY: REQ=REQ-SONNY-6274-FLE-CATALOG-NO-TMP; FEATURE="FieldLevelEncryption"; ASPECT=CatalogPath; STATUS=TESTED; TEST=tests/test_sonny6274_fle_catalog_no_tmp.zig; OWNER=security; UPDATED=2026-11-11
// SONNY-6274: the catalog file lives in the data directory: the store's
// override (`graph_store.setDataDirOverride`, which forwards it here; this
// module cannot import graph_store) or else GEODE_DATA_DIR. With neither the
// session is in memory and so is the FLE catalog, as the index catalog
// (`Catalog.isPersisted`). It fell back to /tmp, so every such session in
// every process shared /tmp/geode_fle_catalog.dat and a fresh one took its
// encrypted-field set from whatever an earlier run left there; a server
// started with --data-dir but no GEODE_DATA_DIR also kept it there.
var g_data_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
var g_data_dir_len: usize = 0;
var g_data_dir_mutex: std.Io.Mutex = std.Io.Mutex.init;

/// Set (or with null, clear) the data directory the catalog file lives in.
pub fn setDataDirOverride(dir: ?[]const u8) void {
    g_data_dir_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_data_dir_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const path = dir orelse "";
    const n = @min(path.len, g_data_dir_buf.len);
    @memcpy(g_data_dir_buf[0..n], path[0..n]);
    g_data_dir_len = n;
}

/// The data-directory override as it was when `saveDataDirOverride` ran.
/// The override is process-global: a test that sets one restores the
/// previous value with `restore` (SONNY-6336), or a later test in the same
/// binary saves its catalog into a directory that no longer exists.
pub const DataDirOverrideSnapshot = struct {
    buf: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,

    pub fn restore(self: *const DataDirOverrideSnapshot) void {
        setDataDirOverride(if (self.len > 0) self.buf[0..self.len] else null);
    }
};

pub fn saveDataDirOverride() DataDirOverrideSnapshot {
    g_data_dir_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_data_dir_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    var snap: DataDirOverrideSnapshot = .{ .len = g_data_dir_len };
    @memcpy(snap.buf[0..g_data_dir_len], g_data_dir_buf[0..g_data_dir_len]);
    return snap;
}

/// The catalog file path, or null when the catalog is memory-only (no data
/// directory). The caller frees the path.
pub fn catalogFilePath(allocator: std.mem.Allocator) !?[]u8 {
    {
        g_data_dir_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer g_data_dir_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        if (g_data_dir_len > 0) {
            return try std.fs.path.join(allocator, &.{ g_data_dir_buf[0..g_data_dir_len], catalog_file_name });
        }
    }
    // No copy of the variable: a memory-only catalog allocates nothing to
    // learn that it saves nothing (SONNY-6324: so a save there cannot fail).
    const env_ptr = std.c.getenv("GEODE_DATA_DIR") orelse return null;
    const env = std.mem.span(env_ptr);
    if (env.len == 0) return null;
    return try std.fs.path.join(allocator, &.{ env, catalog_file_name });
}

/// Whether the catalog is saved to and loaded from a file.
pub fn isPersisted() bool {
    const path = catalogFilePath(std.heap.smp_allocator) catch return true;
    if (path) |p| {
        std.heap.smp_allocator.free(p);
        return true;
    }
    return false;
}

/// Save catalog to disk with TDE encryption. A memory-only catalog (no data
/// directory) saves nothing.
pub fn saveCatalog(catalog: *SchemaCatalog) !void {
    const allocator = catalog.allocator;

    const catalog_path = (try catalogFilePath(allocator)) orelse return;
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

    // Encrypt and write to file: a new 0600 file, then renamed over the
    // catalog (never written through a link planted at the path).
    try tde.writeEncryptedFilePrivate(allocator, catalog_path, buffer.items);
}

/// Load catalog from disk with TDE decryption. A memory-only catalog (no
/// data directory) loads nothing. A symbolic link at the path is refused.
///
/// SONNY-6324: only an absent file (ENOENT) is "nothing to load". Any other
/// failure (unreadable, a link, a TDE error, corrupt or truncated contents,
/// an out-of-range enum byte) is returned, and `catalog` is left as it was:
/// the file is parsed into a map of its own, which replaces the catalog's
/// contents only once all of it has been read. It used to fill the catalog
/// as it read, leak what it had read on an error, leave each type's
/// `type_name` pointing at freed memory, and panic on a bad enum byte.
pub fn loadCatalog(catalog: *SchemaCatalog) !void {
    const allocator = catalog.allocator;

    const catalog_path = (try catalogFilePath(allocator)) orelse return;
    defer allocator.free(catalog_path);

    // Read and decrypt file using TDE
    const data = tde.readDecryptedFileNoFollow(allocator, catalog_path) catch |err| switch (err) {
        error.FileNotFound => return, // No catalog file yet
        else => return err,
    };
    defer allocator.free(data);

    var parsed = std.StringHashMap(*annotations.TypeMetadata).init(allocator);
    errdefer freeSchemaMap(allocator, &parsed);
    try parseCatalog(allocator, data, &parsed);

    catalog.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer catalog.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    catalog.clearSchemasLocked();
    catalog.schemas = parsed;
    catalog.unsaved = false;
}

/// Free a type map whose types and keys the catalog owns.
fn freeSchemaMap(allocator: std.mem.Allocator, map: *std.StringHashMap(*annotations.TypeMetadata)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        destroyTypeMeta(allocator, entry.value_ptr.*);
        allocator.free(entry.key_ptr.*);
    }
    map.deinit();
}

fn readU32(reader: *std.Io.Reader) !u32 {
    const bytes = reader.takeArray(4) catch return error.CorruptedCatalog;
    return std.mem.readInt(u32, bytes, .little);
}

fn readByte(reader: *std.Io.Reader) !u8 {
    return reader.takeByte() catch return error.CorruptedCatalog;
}

/// `len` bytes, borrowed from the decrypted file.
fn readBytes(reader: *std.Io.Reader, len: usize) ![]const u8 {
    return reader.take(len) catch return error.CorruptedCatalog;
}

fn readEnum(comptime E: type, reader: *std.Io.Reader) !E {
    const v = try readByte(reader);
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (field.value == v) return @field(E, field.name);
    }
    return error.CorruptedCatalog;
}

/// Parse a decrypted catalog into `out` (catalog-owned copies). On an error
/// `out` holds what was parsed so far, owned: the caller frees it.
fn parseCatalog(allocator: std.mem.Allocator, data: []const u8, out: *std.StringHashMap(*annotations.TypeMetadata)) !void {
    var reader = std.Io.Reader.fixed(data);

    const type_count = try readU32(&reader);
    if (type_count > 10000) return error.CorruptedCatalog; // Sanity check

    var i: usize = 0;
    while (i < type_count) : (i += 1) {
        const type_name_len = try readU32(&reader);
        if (type_name_len > 1024) return error.CorruptedCatalog; // Sanity check
        const type_name = try readBytes(&reader, type_name_len);
        if (out.contains(type_name)) return error.CorruptedCatalog;

        const type_meta_ptr = try newTypeMeta(allocator, type_name);
        out.put(type_meta_ptr.type_name, type_meta_ptr) catch |err| {
            const name = type_meta_ptr.type_name;
            destroyTypeMeta(allocator, type_meta_ptr);
            allocator.free(name);
            return err;
        };

        const field_count = try readU32(&reader);
        if (field_count > 1000) return error.CorruptedCatalog; // Sanity check

        var j: usize = 0;
        while (j < field_count) : (j += 1) {
            const field_name_len = try readU32(&reader);
            if (field_name_len > 1024) return error.CorruptedCatalog; // Sanity check
            var field_meta = annotations.FieldMetadata{
                .field_name = try readBytes(&reader, field_name_len),
            };
            if (type_meta_ptr.fields.contains(field_meta.field_name)) return error.CorruptedCatalog;

            // Read encryption config
            field_meta.encryption.enabled = (try readByte(&reader)) != 0;
            if (field_meta.encryption.enabled) {
                field_meta.encryption.algorithm = try readEnum(annotations.EncryptionConfig.Algorithm, &reader);
                field_meta.encryption.key_scope = try readEnum(annotations.EncryptionConfig.KeyScope, &reader);
            }

            // Read search config
            field_meta.search.enabled = (try readByte(&reader)) != 0;
            if (field_meta.search.enabled) {
                field_meta.search.index_type = try readEnum(annotations.SearchConfig.IndexType, &reader);
            }

            // Read visibility config (borrowed from `data` until copied)
            const role_count = try readU32(&reader);
            if (role_count > 100) return error.CorruptedCatalog; // Sanity check
            var roles: [100][]const u8 = undefined;
            for (roles[0..role_count]) |*role| {
                const role_len = try readU32(&reader);
                if (role_len > 256) return error.CorruptedCatalog; // Sanity check
                role.* = try readBytes(&reader, role_len);
            }
            field_meta.visibility.to_roles = roles[0..role_count];

            const owned = try dupeFieldMeta(allocator, field_meta);
            type_meta_ptr.fields.put(owned.field_name, owned) catch |err| {
                freeFieldMeta(allocator, owned);
                return err;
            };
        }
    }
}

test "Schema catalog basic operations" {
    const testing = std.testing;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var catalog = SchemaCatalog.init(allocator);
    defer catalog.deinit();

    // Create type metadata
    var type_meta = annotations.TypeMetadata.init(allocator, "Person");
    // SONNY-6324: the catalog stores its own copy; this one stays ours.
    defer type_meta.deinit();

    // Add encrypted field
    try annotations.applyAnnotations(
        allocator,
        &type_meta,
        "ssn",
        "@encrypted(alg:\"AES-256-GCM\")",
    );

    // Register type (the catalog copies it)
    try catalog.registerType("Person", type_meta);

    // Verify registration
    try testing.expect(catalog.isFieldEncrypted("Person", "ssn"));
    try testing.expect(!catalog.isFieldEncrypted("Person", "name"));
    try testing.expectEqual(@as(usize, 1), catalog.count());
}

test "Schema catalog thread safety" {
    const testing = std.testing;
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    defer resetGlobalCatalog(allocator);

    const catalog1 = try globalCatalog(allocator);
    const catalog2 = try globalCatalog(allocator);

    // Should be the same instance
    try testing.expectEqual(catalog1, catalog2);
}
