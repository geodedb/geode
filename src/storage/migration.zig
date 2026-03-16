const std = @import("std");
const geode = @import("geode");
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

/// Migrate from the monolithic graph_store.dat to per-graph UUID-named files.
///
/// Precondition: `graph_store.setDataDirOverride` has already been called with
/// `data_dir` so that `GraphStore.init` + `loadFromFile` will find the monolithic
/// file automatically.
///
/// On success the monolithic file is renamed to graph_store.dat.migrated.
pub fn migrateToPerGraph(data_dir: []const u8, allocator: std.mem.Allocator) !MigrationResult {
    const gs = geode.graph_store;
    const GraphHandle = geode.GraphHandle;
    const GraphRegistry = geode.GraphRegistry;
    const UuidV7 = geode.UuidV7;

    log.info("Starting monolithic → per-graph storage migration", &.{
        Attr.string("data_dir", data_dir),
    });

    // Load the monolithic store.  We must NOT set data_dir on this temporary store
    // because loadFromFile() checks data_dir for a registry first; if it finds one
    // it would try to load per-graph files (which don't exist yet).  Instead we
    // set data_dir to empty so loadFromFile falls back to getPersistenceFilePath(),
    // which uses the global setDataDirOverride to locate graph_store.dat.
    var store = try gs.GraphStore.init(allocator);
    defer store.deinit();
    store.data_dir = ""; // ensure loadFromFile uses monolithic path, not per-graph
    try store.loadFromFile();

    // Create graphs/ directory.
    const graphs_dir = try std.fmt.allocPrint(allocator, "{s}/graphs", .{data_dir});
    defer allocator.free(graphs_dir);
    try std.fs.cwd().makePath(graphs_dir);

    // Build registry and per-graph files.
    var reg = GraphRegistry.init(allocator);
    defer reg.deinit();
    reg.next_node_id = store.next_node_id;
    reg.next_edge_id = store.next_edge_id;

    var graphs_migrated: u64 = 0;
    var total_nodes: u64 = 0;
    var total_edges: u64 = 0;

    // Iterate over known graph names from the monolithic store.
    var graph_iter = store.graphs.iterator();
    while (graph_iter.next()) |entry| {
        const graph_name = entry.key_ptr.*;

        // Register the graph and obtain its UUID.
        const uuid_bytes = try reg.addGraph(graph_name);

        // Create a temporary handle to hold this graph's data.
        // We use `allocator` here; nodes/edges inserted below are SHALLOW copies
        // of the struct value (the inner slices point into the monolithic store's
        // memory).  We must NOT call handle.deinit() at the end because that
        // would free memory owned by `store`.  Instead we manually clear the
        // hashmaps without freeing the element values.
        const handle = try GraphHandle.init(allocator, graph_name, uuid_bytes);

        // Populate nodes for this graph.
        var node_iter = store.nodes.iterator();
        while (node_iter.next()) |n| {
            const node = n.value_ptr.*;
            if (std.mem.eql(u8, node.graph_name, graph_name)) {
                try handle.nodes.put(node.id, node);
            }
        }

        // Populate edges for this graph.
        var edge_iter = store.edges.iterator();
        while (edge_iter.next()) |e| {
            const edge = e.value_ptr.*;
            if (std.mem.eql(u8, edge.graph_name, graph_name)) {
                try handle.edges.put(edge.id, edge);
            }
        }

        // Rebuild in-memory indexes (label_index, adjacency lists).
        try handle.rebuildIndexes();

        const node_count = handle.nodeCount();
        const edge_count = handle.edgeCount();

        // Build the per-graph file path from UUID string.
        var uuid_str_buf: [36]u8 = undefined;
        const uuid_v7 = UuidV7.fromBytes(uuid_bytes);
        const uuid_str = try uuid_v7.toStringBuf(&uuid_str_buf);
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.dat", .{ graphs_dir, uuid_str });
        defer allocator.free(file_path);

        // Serialize via the existing GraphStore method.
        try store.saveGraphHandleToFile(handle, file_path);

        // Update registry counts.
        for (reg.entries.items) |*entry_reg| {
            if (std.mem.eql(u8, entry_reg.name, graph_name)) {
                entry_reg.node_count = node_count;
                entry_reg.edge_count = edge_count;
                break;
            }
        }

        log.info("Migrated graph", &.{
            Attr.string("graph", graph_name),
            Attr.int("nodes", @intCast(node_count)),
            Attr.int("edges", @intCast(edge_count)),
        });

        total_nodes += node_count;
        total_edges += edge_count;
        graphs_migrated += 1;

        // Release the handle without deep-freeing values (they belong to `store`).
        releaseHandleShallow(allocator, handle);
    }

    // Persist the registry.
    const reg_path = try std.fmt.allocPrint(allocator, "{s}/graph_registry.dat", .{data_dir});
    defer allocator.free(reg_path);
    try reg.saveToFile(reg_path);

    // Rename legacy file to sentinel so we know migration completed.
    const legacy_path = try std.fmt.allocPrint(allocator, "{s}/graph_store.dat", .{data_dir});
    defer allocator.free(legacy_path);
    const migrated_path = try std.fmt.allocPrint(allocator, "{s}/graph_store.dat.migrated", .{data_dir});
    defer allocator.free(migrated_path);
    try std.fs.cwd().rename(legacy_path, migrated_path);

    log.info("Migration complete", &.{
        Attr.int("graphs", @intCast(graphs_migrated)),
        Attr.int("total_nodes", @intCast(total_nodes)),
        Attr.int("total_edges", @intCast(total_edges)),
    });

    return MigrationResult{
        .graphs_migrated = graphs_migrated,
        .total_nodes = total_nodes,
        .total_edges = total_edges,
    };
}

/// Recover from an interrupted migration by deleting partial outputs and re-running.
pub fn recoverInterruptedMigration(data_dir: []const u8, allocator: std.mem.Allocator) !MigrationResult {
    log.warn("Recovering interrupted migration — removing partial outputs", &.{
        Attr.string("data_dir", data_dir),
    });

    // Remove partial registry.
    const reg_path = try std.fmt.allocPrint(allocator, "{s}/graph_registry.dat", .{data_dir});
    defer allocator.free(reg_path);
    std.fs.cwd().deleteFile(reg_path) catch |err| {
        if (err != error.FileNotFound) {
            log.warn("Could not remove partial registry", &.{
                Attr.string("error", @errorName(err)),
            });
        }
    };

    // Remove partial graphs/ directory.
    const graphs_dir = try std.fmt.allocPrint(allocator, "{s}/graphs", .{data_dir});
    defer allocator.free(graphs_dir);
    std.fs.cwd().deleteTree(graphs_dir) catch |err| {
        if (err != error.FileNotFound) {
            log.warn("Could not remove partial graphs directory", &.{
                Attr.string("error", @errorName(err)),
            });
        }
    };

    // Re-run migration from scratch.
    return migrateToPerGraph(data_dir, allocator);
}

/// Release a GraphHandle without deep-freeing the Node/Edge values it contains.
/// This is used after migration where the values are owned by a separate GraphStore.
/// Only the handle's own HashMaps and the name slice (duped by GraphHandle.init)
/// are freed here.
fn releaseHandleShallow(allocator: std.mem.Allocator, handle: anytype) void {
    // Clear maps without freeing values (values owned by the source GraphStore).
    handle.nodes.deinit();
    handle.edges.deinit();

    // label_index entries: keys are allocator.dupe'd by rebuildIndexes, values are ArrayLists.
    var label_iter = handle.label_index.iterator();
    while (label_iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    handle.label_index.deinit();

    // Adjacency lists are owned by the handle (created in rebuildIndexes).
    var out_iter = handle.outgoing_edges.iterator();
    while (out_iter.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    handle.outgoing_edges.deinit();

    var in_iter = handle.incoming_edges.iterator();
    while (in_iter.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    handle.incoming_edges.deinit();

    // Free the name duped by GraphHandle.init.
    allocator.free(handle.name);
    allocator.destroy(handle);
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
