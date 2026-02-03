const std = @import("std");
const geode = @import("geode");
const graph_exec = geode.graph_exec;
const graph_store = geode.graph_store;
const audit = geode.security.audit;

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-013; FEATURE="Structured Logging"; ASPECT=GraphStorageManager; STATUS=EXEMPT; OWNER=server; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("server");
const Attr = logging.Attr;

// CANARY: REQ=REQ-SERVER-REFACTOR-005; FEATURE="ServerRefactoring"; ASPECT=GRAPH_STORAGE; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-11-12
// CANARY: REQ=REQ-MULTI-GRAPH-002; FEATURE="MultiGraphSupport"; ASPECT=GraphRegistry; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2026-02-03
/// Default graph name used when no graph is selected
pub const DEFAULT_GRAPH_NAME = "default";

/// Allocator for graph storage manager operations
var g_allocator: ?std.mem.Allocator = null;
/// Global data directory for persistence (mirrors GEODE_DATA_DIR)
var g_data_dir: ?[]u8 = null;
/// Dedicated allocator for global state (avoids page_allocator)
var g_state_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var g_state_inited = false;
/// Global audit logger (optional)
var g_audit_logger: ?*audit.AuditLogger = null;

fn getStateAllocator() std.mem.Allocator {
    if (!g_state_inited) {
        g_state_inited = true;
    }
    return g_state_gpa.allocator();
}

fn ensureAllocator() std.mem.Allocator {
    if (g_allocator) |alloc| return alloc;
    const alloc = getStateAllocator();
    g_allocator = alloc;
    return alloc;
}

/// Set the global audit logger for new graph storages
pub fn setAuditLogger(logger: *audit.AuditLogger) void {
    g_audit_logger = logger;
    // GraphStore no longer accepts audit logger directly; keep for API compatibility.
}

/// Set the global data directory for persistence
pub fn setDataDir(dir: ?[]const u8) void {
    const allocator = ensureAllocator();

    if (g_data_dir) |existing| {
        allocator.free(existing);
        g_data_dir = null;
    }

    if (dir) |path| {
        g_data_dir = allocator.dupe(u8, path) catch null;
    }

    // Also set the override in graph_store so persistence uses the correct path
    graph_store.setDataDirOverride(allocator, dir);
}

/// Get the global data directory
pub fn getDataDir() ?[]const u8 {
    return g_data_dir;
}

/// Get or create the global graph storage instance
pub fn getOrCreateGraphStorage(allocator: std.mem.Allocator) *graph_exec.GraphStorage {
    g_allocator = allocator;
    _ = g_audit_logger; // retained for API compatibility
    return graph_store.getGlobalStore(allocator);
}

/// Get the current graph storage instance (always available once initialized)
pub fn getCurrentGraphStorage() ?*graph_exec.GraphStorage {
    const allocator = ensureAllocator();
    return graph_store.getGlobalStore(allocator);
}

/// Clear the global graph storage instance (for testing)
pub fn clearGraphStorage() void {
    // Only clear if there's an existing store - don't create one just to clear it
    if (graph_store.getCurrentGlobalStore()) |store| {
        store.clearNodes();
        store.clearGraphRegistry();
        store.dirty = true;
    }
}

/// Clear the multi-graph storage state (for testing)
/// GraphStore uses a single unified store, so this is equivalent to clearGraphStorage.
pub fn clearMultiGraphStorage() void {
    clearGraphStorage();
}

// ============================================================================
// Multi-Graph Storage Support (GraphStore-backed)
// ============================================================================

/// Initialize the graph storage system
pub fn initMultiGraphStorage(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
    _ = graph_store.getGlobalStore(allocator);
}

/// Get graph storage by name
/// Returns the storage if the graph exists; null otherwise
pub fn getGraphStorageByName(name: ?[]const u8) ?*graph_exec.GraphStorage {
    const allocator = ensureAllocator();
    const graph_name = name orelse DEFAULT_GRAPH_NAME;
    const store = graph_store.getGlobalStore(allocator);
    if (!store.graphExists(graph_name)) return null;
    return store;
}

/// Create a new empty graph with the given name
/// Returns error if graph already exists
pub fn createGraphStorage(allocator: std.mem.Allocator, name: []const u8) !*graph_exec.GraphStorage {
    g_allocator = allocator;
    const store = graph_store.getGlobalStore(allocator);
    try store.createGraph(name);
    return store;
}

/// Check if a graph exists
pub fn graphExists(name: []const u8) bool {
    const allocator = ensureAllocator();
    const store = graph_store.getGlobalStore(allocator);
    return store.graphExists(name);
}

/// List all graph names (caller owns returned strings)
pub fn listGraphNames(allocator: std.mem.Allocator) ![][]const u8 {
    const store = graph_store.getGlobalStore(allocator);
    const names = try store.listGraphNames(allocator);

    var out = try allocator.alloc([]const u8, names.len);
    errdefer {
        for (out) |name| allocator.free(name);
        allocator.free(out);
    }

    for (names, 0..) |name, i| {
        out[i] = try allocator.dupe(u8, name);
    }

    return out;
}

// GAP-0139: SHOW TABLES implementation helper
// CANARY: REQ=REQ-SHOW-TABLES-002; FEATURE="SHOW TABLES"; ASPECT=GraphStorageList; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=engine; UPDATED=2026-01-13
/// List all unique node labels from all graphs
/// In graph databases, node labels serve as the equivalent of "tables"
pub fn listNodeLabels(allocator: std.mem.Allocator) ![][]const u8 {
    var label_set = std.StringHashMap(void).init(allocator);
    defer label_set.deinit();

    const store = graph_store.getGlobalStore(allocator);
    var node_it = store.nodes.iterator();
    while (node_it.next()) |entry| {
        const node = entry.value_ptr.*;
        for (node.labels) |label| {
            const label_copy = try allocator.dupe(u8, label);
            errdefer allocator.free(label_copy);
            const result = try label_set.getOrPut(label_copy);
            if (result.found_existing) {
                allocator.free(label_copy);
            }
        }
    }

    var labels = try std.ArrayList([]const u8).initCapacity(allocator, label_set.count());
    errdefer labels.deinit(allocator);

    var key_it = label_set.keyIterator();
    while (key_it.next()) |key| {
        try labels.append(allocator, key.*);
    }

    return labels.toOwnedSlice(allocator);
}

/// Drop a graph by name
pub fn dropGraphStorage(name: []const u8) !void {
    const allocator = ensureAllocator();
    const store = graph_store.getGlobalStore(allocator);
    try store.dropGraph(name);
}

// ============================================================================
// Graph Store Persistence (Unified)
// ============================================================================

// CANARY: REQ=REQ-GRAPH-PERSIST-001; FEATURE="GraphStorePersistence"; ASPECT=SaveLoad; STATUS=IMPL; OWNER=storage; UPDATED=2026-02-03

/// Get the persistence file path for the graph store
/// Note: graph_name is ignored in the unified GraphStore format
pub fn getGraphDataDir(allocator: std.mem.Allocator, graph_name: []const u8) ![]const u8 {
    _ = graph_name;
    return graph_store.getPersistenceFilePath(allocator);
}

/// Save a named graph's data (unified store persistence)
pub fn saveNamedGraph(allocator: std.mem.Allocator, graph_name: []const u8) !void {
    const store = graph_store.getGlobalStore(allocator);
    if (!store.graphExists(graph_name)) return error.GraphNotFound;
    store.saveIfDirty();
}

/// Load a named graph's data (unified store persistence)
pub fn loadNamedGraph(allocator: std.mem.Allocator, graph_name: []const u8) !*graph_exec.GraphStorage {
    const store = graph_store.getGlobalStore(allocator);
    if (!store.graphExists(graph_name)) return error.GraphNotFound;
    return store;
}

/// Save all graphs (single store file)
pub fn saveAllNamedGraphs(allocator: std.mem.Allocator) void {
    const store = graph_store.getGlobalStore(allocator);
    store.saveIfDirty();
}

/// Ensure all catalog graphs exist in the store
pub fn loadAllNamedGraphs(allocator: std.mem.Allocator, graph_names: []const []const u8) void {
    const store = graph_store.getGlobalStore(allocator);

    for (graph_names) |name| {
        if (!store.graphExists(name)) {
            _ = store.createGraph(name) catch |err| {
                if (err != error.GraphAlreadyExists) {
                    log.err("Failed to ensure graph in store", &.{
                        Attr.string("name", name),
                        Attr.string("error", @errorName(err)),
                    });
                }
            };
        }
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "GraphStorageManager_getGraphDataDir_returns_store_path" {
    const allocator = testing.allocator;

    setDataDir("/tmp/geode_test_data");
    defer setDataDir(null);

    const path = try getGraphDataDir(allocator, "my_test_graph");
    defer allocator.free(path);

    try testing.expect(std.mem.endsWith(u8, path, "graph_store.dat"));
    try testing.expect(std.mem.containsAtLeast(u8, path, 1, "/tmp/geode_test_data"));
}

test "GraphStorageManager_getGraphDataDir_falls_back_when_unset" {
    const allocator = testing.allocator;

    setDataDir(null);

    const path = try getGraphDataDir(allocator, "any_graph");
    defer allocator.free(path);

    try testing.expect(std.mem.endsWith(u8, path, "geode_graph_store.dat"));
}

test "DEFAULT_GRAPH_NAME_is_default" {
    try testing.expectEqualStrings("default", DEFAULT_GRAPH_NAME);
}
