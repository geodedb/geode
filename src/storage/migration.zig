const std = @import("std");
const logging = @import("logging");
const log = logging.scoped("migration");
const Attr = logging.Attr;

// CANARY: REQ=REQ-STORAGE-MIGRATION-001; FEATURE="PerGraphStorageMigration"; ASPECT=DetectAndMigrate; STATUS=IMPL; OWNER=storage; UPDATED=2026-03-16

/// Describes the on-disk storage state detected at startup.
pub const StorageState = enum {
    /// No data files exist — fresh database.
    fresh,
    /// graph_store.dat exists but no registry — legacy monolithic format.
    legacy_monolithic,
    /// graph_registry.dat exists and no partial migration in progress — per-graph format.
    per_graph,
    /// Both graph_store.dat AND graph_registry.dat exist with no .migrated sentinel —
    /// indicates an interrupted migration that must be recovered.
    interrupted,
};

/// Inspect the data directory and return the current storage state.
pub fn detectStorageState(data_dir: []const u8, allocator: std.mem.Allocator) !StorageState {
    const legacy_path = try std.fmt.allocPrint(allocator, "{s}/graph_store.dat", .{data_dir});
    defer allocator.free(legacy_path);

    const registry_path = try std.fmt.allocPrint(allocator, "{s}/graph_registry.dat", .{data_dir});
    defer allocator.free(registry_path);

    const migrated_path = try std.fmt.allocPrint(allocator, "{s}/graph_store.dat.migrated", .{data_dir});
    defer allocator.free(migrated_path);

    const has_legacy = fileExists(legacy_path);
    const has_registry = fileExists(registry_path);
    const has_migrated = fileExists(migrated_path);

    if (has_registry and (has_migrated or !has_legacy)) {
        return .per_graph;
    }
    if (has_legacy and has_registry) {
        // Both exist without a .migrated sentinel — interrupted migration.
        return .interrupted;
    }
    if (has_legacy) {
        return .legacy_monolithic;
    }
    return .fresh;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Counts and timing summary returned from a successful migration.
pub const MigrationResult = struct {
    graphs_migrated: u64,
    total_nodes: u64,
    total_edges: u64,
};

/// Legacy monolithic-to-per-graph migration.
///
/// The old file-based persistence (graph_handle.zig, graph_registry.zig) has been
/// removed. Storage is now handled by the adapter layer. This function is retained
/// as a no-op stub so that server_init.zig callers compile without changes; it
/// logs a warning and returns a zero-count result.
pub fn migrateToPerGraph(data_dir: []const u8, _: std.mem.Allocator) !MigrationResult {
    log.warn("Legacy file migration is no longer supported — persistence is adapter-based", &.{
        Attr.string("data_dir", data_dir),
    });
    return MigrationResult{ .graphs_migrated = 0, .total_nodes = 0, .total_edges = 0 };
}

/// Recover from an interrupted migration (stub — see migrateToPerGraph).
pub fn recoverInterruptedMigration(data_dir: []const u8, allocator: std.mem.Allocator) !MigrationResult {
    log.warn("Legacy migration recovery is no longer supported — persistence is adapter-based", &.{
        Attr.string("data_dir", data_dir),
    });
    _ = allocator;
    return MigrationResult{ .graphs_migrated = 0, .total_nodes = 0, .total_edges = 0 };
}

// ============================================================================
// Unit Tests
// ============================================================================

test "detectStorageState - fresh" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(dir_path);

    const state = try detectStorageState(dir_path, allocator);
    try std.testing.expectEqual(StorageState.fresh, state);
}

test "detectStorageState - legacy_monolithic" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(dir_path);

    // Create a graph_store.dat file (content irrelevant for state detection).
    const f = try tmp.dir.createFile("graph_store.dat", .{});
    f.close();

    const state = try detectStorageState(dir_path, allocator);
    try std.testing.expectEqual(StorageState.legacy_monolithic, state);
}

test "detectStorageState - per_graph" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(dir_path);

    // Create only a graph_registry.dat file.
    const f = try tmp.dir.createFile("graph_registry.dat", .{});
    f.close();

    const state = try detectStorageState(dir_path, allocator);
    try std.testing.expectEqual(StorageState.per_graph, state);
}

test "detectStorageState - interrupted" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(dir_path);

    // Create both graph_store.dat and graph_registry.dat (no .migrated sentinel).
    const f1 = try tmp.dir.createFile("graph_store.dat", .{});
    f1.close();
    const f2 = try tmp.dir.createFile("graph_registry.dat", .{});
    f2.close();

    const state = try detectStorageState(dir_path, allocator);
    try std.testing.expectEqual(StorageState.interrupted, state);
}

test "detectStorageState - post_migration" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(dir_path);

    // Post-migration state: registry + .migrated sentinel (no original graph_store.dat).
    const f1 = try tmp.dir.createFile("graph_registry.dat", .{});
    f1.close();
    const f2 = try tmp.dir.createFile("graph_store.dat.migrated", .{});
    f2.close();

    const state = try detectStorageState(dir_path, allocator);
    try std.testing.expectEqual(StorageState.per_graph, state);
}
