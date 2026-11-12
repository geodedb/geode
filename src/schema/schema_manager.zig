// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-001; FEATURE="Phase 7 Modularization"; ASPECT=SchemaManager; STATUS=TESTED; TEST=tests/test_user_management_comprehensive.zig; OWNER=schema; UPDATED=2026-01-15
// Phase 7 M7.1: Unified schema management interface
//
// This module provides a centralized interface for all schema-related operations,
// consolidating access to:
// - Database metadata catalog (schemas, graphs, indexes)
// - FLE (Field-Level Encryption) schema catalog
// - Type annotations
// - Constraint management
//
// By providing a single entry point, this module improves:
// - Code organization and discoverability
// - Maintainability through clear boundaries
// - Testability via unified interface

const std = @import("std");
const catalog = @import("catalog.zig");
const fle_catalog = @import("fle_catalog.zig");
const annotations = @import("annotations.zig");
const constraint_manager = @import("constraint_manager.zig");
const graph_store = @import("../graph_store.zig");

// ============================================================================
// Re-export core types for convenience
// ============================================================================

/// Database metadata catalog (schemas, graphs, indexes)
/// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-002; FEATURE="Catalog Re-export"; ASPECT=Core; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
pub const Catalog = catalog.Catalog;
pub const IndexInfo = catalog.IndexInfo;

/// FLE schema catalog for encryption metadata
/// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-003; FEATURE="FLE Catalog Re-export"; ASPECT=Core; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
pub const SchemaCatalog = fle_catalog.SchemaCatalog;

/// Type metadata and annotations
/// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-004; FEATURE="Annotations Re-export"; ASPECT=Core; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
pub const TypeMetadata = annotations.TypeMetadata;
pub const FieldMetadata = annotations.FieldMetadata;
pub const EncryptionAlgorithm = annotations.EncryptionAlgorithm;

/// Constraint management
/// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-005; FEATURE="Constraints Re-export"; ASPECT=Core; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
pub const ConstraintManager = constraint_manager.ConstraintManager;
pub const Constraint = constraint_manager.Constraint;

// ============================================================================
// Unified Schema Manager
// ============================================================================

/// SchemaManager provides a unified interface for all schema operations
/// Coordinates between database catalog, FLE catalog, annotations, and constraints
///
/// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-006; FEATURE="Unified Schema Manager"; ASPECT=Core; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
pub const SchemaManager = struct {
    allocator: std.mem.Allocator,
    db_catalog: *Catalog,
    fle_catalog: SchemaCatalog,
    constraint_mgr: *ConstraintManager,

    /// Initialize schema manager with all components
    ///
    /// Parameters:
    /// - allocator: Memory allocator for schema operations
    /// - data_dir: Directory for persisting catalog data
    ///
    /// Returns: Initialized SchemaManager or error
    ///
    /// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-007; FEATURE="Schema Manager Init"; ASPECT=Core; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8) !SchemaManager {
        const db_catalog_inst = try Catalog.init(allocator, data_dir);
        errdefer db_catalog_inst.deinit();
        errdefer allocator.destroy(db_catalog_inst);

        const fle_catalog_inst = SchemaCatalog.init(allocator);

        const constraint_mgr_inst = try allocator.create(ConstraintManager);
        errdefer allocator.destroy(constraint_mgr_inst);
        constraint_mgr_inst.* = ConstraintManager.init(allocator);

        return .{
            .allocator = allocator,
            .db_catalog = db_catalog_inst,
            .fle_catalog = fle_catalog_inst,
            .constraint_mgr = constraint_mgr_inst,
        };
    }

    /// Clean up schema manager resources
    ///
    /// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-008; FEATURE="Schema Manager Cleanup"; ASPECT=Core; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
    pub fn deinit(self: *SchemaManager) void {
        self.db_catalog.deinit();
        self.allocator.destroy(self.db_catalog);

        self.fle_catalog.deinit();

        self.constraint_mgr.deinit();
        self.allocator.destroy(self.constraint_mgr);
    }

    // ========================================================================
    // Database Catalog Operations
    // ========================================================================

    /// Create a new schema
    ///
    /// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-009; FEATURE="Schema Creation"; ASPECT=Core; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
    pub fn createSchema(self: *SchemaManager, schema_name: []const u8) !void {
        try self.db_catalog.addSchema(schema_name);
    }

    /// Check if schema exists
    ///
    /// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-010; FEATURE="Schema Existence Check"; ASPECT=Core; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
    pub fn schemaExists(self: *SchemaManager, schema_name: []const u8) bool {
        return self.db_catalog.hasSchema(schema_name);
    }

    /// Create a new graph
    ///
    /// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-011; FEATURE="Graph Creation"; ASPECT=Graph; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
    pub fn createGraph(self: *SchemaManager, graph_name: []const u8) !void {
        const store = graph_store.getGlobalStore(self.allocator);
        try store.createGraph(graph_name);
        errdefer store.dropGraph(graph_name) catch {};
        const uuid = graph_store.GraphStore.getGraphUuid(graph_name) orelse return error.GraphUuidUnavailable;
        try self.db_catalog.addGraphWithUuid(graph_name, uuid);
    }

    /// Check if graph exists
    ///
    /// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-012; FEATURE="Graph Existence Check"; ASPECT=Graph; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
    pub fn graphExists(self: *SchemaManager, graph_name: []const u8) bool {
        return self.db_catalog.hasGraph(graph_name);
    }

    /// Create an index
    ///
    /// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-013; FEATURE="Index Creation"; ASPECT=Index; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
    pub fn createIndex(self: *SchemaManager, index_info: IndexInfo) !void {
        try self.db_catalog.addIndex(index_info);
    }

    /// Get index information
    ///
    /// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-014; FEATURE="Index Retrieval"; ASPECT=Index; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
    pub fn getIndex(self: *SchemaManager, label: []const u8, index_name: []const u8) !?IndexInfo {
        return self.db_catalog.getIndex(label, index_name);
    }

    // ========================================================================
    // FLE Catalog Operations
    // ========================================================================

    /// Register a type with encryption metadata
    ///
    /// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-015; FEATURE="FLE Type Registration"; ASPECT=Types; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
    pub fn registerEncryptedType(
        self: *SchemaManager,
        type_name: []const u8,
        type_meta: TypeMetadata,
    ) !void {
        try self.fle_catalog.registerType(type_name, type_meta);
    }

    /// Get encryption metadata for one field, by value.
    /// SONNY-6327: it returned a pointer into the catalog after unlocking
    /// (a reconfigure frees what it pointed at).
    ///
    /// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-016; FEATURE="FLE Metadata Retrieval"; ASPECT=Core; STATUS=EXEMPT; OWNER=core; UPDATED=2026-11-11
    pub fn getEncryptionMetadata(self: *SchemaManager, type_name: []const u8, field_name: []const u8) ?SchemaCatalog.FieldPolicy {
        return self.fle_catalog.fieldPolicy(type_name, field_name);
    }

    // ========================================================================
    // Constraint Operations
    // ========================================================================

    /// Add a constraint
    ///
    /// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-017; FEATURE="Constraint Addition"; ASPECT=Core; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
    pub fn addConstraint(self: *SchemaManager, constraint: Constraint) !void {
        try self.constraint_mgr.addConstraint(constraint);
    }

    /// Get constraints for a label
    ///
    /// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-018; FEATURE="Constraint Retrieval"; ASPECT=Core; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
    pub fn getConstraintsForLabel(self: *SchemaManager, label: []const u8) []const Constraint {
        return self.constraint_mgr.getConstraintsForLabel(label);
    }

    /// Validate data against constraints
    ///
    /// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-019; FEATURE="Constraint Validation"; ASPECT=Core; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
    pub fn validateConstraints(
        self: *SchemaManager,
        label: []const u8,
        properties: anytype,
    ) !void {
        try self.constraint_mgr.validateConstraints(label, properties);
    }

    // ========================================================================
    // Utility Functions
    // ========================================================================

    /// Get scoped index key (label:index_name)
    ///
    /// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-020; FEATURE="Scoped Index Key"; ASPECT=Index; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
    pub fn getScopedIndexKey(
        self: *SchemaManager,
        label: []const u8,
        index_name: []const u8,
    ) ![]const u8 {
        return catalog.getScopedIndexKey(self.allocator, label, index_name);
    }

    /// Persist all schema state to disk
    ///
    /// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-021; FEATURE="Schema Persistence"; ASPECT=Core; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
    pub fn saveAll(self: *SchemaManager) !void {
        self.db_catalog.rwlock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.db_catalog.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());

        try self.db_catalog.save();
        // Note: FLE catalog and constraints are typically in-memory only
        // Add persistence if needed in the future
    }

    /// Reload schema state from disk
    ///
    /// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-022; FEATURE="Schema Reload"; ASPECT=Core; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
    pub fn reload(self: *SchemaManager) !void {
        self.db_catalog.rwlock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.db_catalog.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());

        try self.db_catalog.load();
    }
};

// ============================================================================
// Convenience Functions
// ============================================================================

/// Create a new SchemaManager instance
///
/// This is the recommended way to initialize schema management for the database.
///
/// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-023; FEATURE="Schema Manager Factory"; ASPECT=Core; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
pub fn createSchemaManager(allocator: std.mem.Allocator, data_dir: []const u8) !SchemaManager {
    return SchemaManager.init(allocator, data_dir);
}

// ============================================================================
// Re-export utility functions
// ============================================================================

/// Generate scoped index key (utility function)
/// CANARY: REQ=REQ-M7.1-SCHEMA-MANAGER-024; FEATURE="Utility Re-export"; ASPECT=Core; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-17
pub const getScopedIndexKey = catalog.getScopedIndexKey;
