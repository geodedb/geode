const std = @import("std");
const graph_exec = @import("graph/exec.zig");
const audit = @import("../security/audit.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-013; FEATURE="Structured Logging"; ASPECT=GraphStorageManager; STATUS=EXEMPT; OWNER=server; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("server");
const Attr = logging.Attr;

// CANARY: REQ=REQ-SERVER-REFACTOR-005; FEATURE="ServerRefactoring"; ASPECT=GRAPH_STORAGE; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-11-12
// CANARY: REQ=REQ-MULTI-GRAPH-002; FEATURE="MultiGraphSupport"; ASPECT=PerGraphStorage; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-20
// Phase 3 M3.1 - Graph Storage Management Module (Incremental Extraction)
// Extended to support multiple named graphs with per-graph storage

/// Default graph name used when no graph is selected
pub const DEFAULT_GRAPH_NAME = "default";

/// Global graph storage singleton (legacy - now points to default graph)
var g_graph_storage: ?*graph_exec.GraphStorage = null;
/// Global data directory for persistence
var g_data_dir: ?[]const u8 = null;
/// Per-graph storage map (graph_name -> GraphStorage)
var g_graph_storages: ?std.StringHashMap(*graph_exec.GraphStorage) = null;
/// Allocator for graph storage map
var g_allocator: ?std.mem.Allocator = null;
/// Global audit logger (optional)
var g_audit_logger: ?*audit.AuditLogger = null;

/// Set the global audit logger for new graph storages
pub fn setAuditLogger(logger: *audit.AuditLogger) void {
    g_audit_logger = logger;
}

/// Get or create the global graph storage instance
/// Attempts to load from persistent storage if data directory is set
/// Falls back to creating new graph with sample data
pub fn getOrCreateGraphStorage(allocator: std.mem.Allocator) *graph_exec.GraphStorage {
    log.debug("getOrCreateGraphStorage called", &.{Attr.string("g_graph_storage", if (g_graph_storage == null) "null" else "set")});
    if (g_graph_storage) |graph| {
        log.debug("Returning existing graph", &.{Attr.int("nodes", @intCast(graph.nodes.count()))});
        return graph;
    }

    // Try to load from persistent data first if data directory is available
    if (g_data_dir) |data_dir| {
        if (tryLoadGraphFromDir(allocator, data_dir)) |loaded_graph| {
            log.debug("Loaded graph from persistent data", &.{ Attr.int("nodes", @intCast(loaded_graph.nodes.count())), Attr.int("edges", @intCast(loaded_graph.edges.items.len)) });
            g_graph_storage = loaded_graph;
            return loaded_graph;
        } else |err| {
            log.debug("Failed to load graph from persistent data", &.{Attr.string("error", @errorName(err))});
            // Loading failed, continue to create new graph
        }
    } else {
        log.debug("No data directory available for persistence", &.{});
    }

    // Create new graph and initialize with sample data if no persistent data
    const graph = allocator.create(graph_exec.GraphStorage) catch unreachable;
    graph.* = graph_exec.GraphStorage.init(allocator, g_audit_logger);
    initializeSampleGraph(allocator, graph) catch {};
    g_graph_storage = graph;
    return graph;
}

/// Get the next available node ID by finding max existing ID + 1
pub fn getNextNodeId(graph: *graph_exec.GraphStorage) graph_exec.NodeId {
    var max_id: graph_exec.NodeId = 0;
    var iterator = graph.nodes.iterator();
    while (iterator.next()) |entry| {
        if (entry.key_ptr.* > max_id) {
            max_id = entry.key_ptr.*;
        }
    }
    return max_id + 1;
}

/// Try to load graph from persistent storage directory
/// Reads nodes.jsonl and edges.jsonl in JSON Lines format
/// Returns newly allocated GraphStorage on success
pub fn tryLoadGraphFromDir(allocator: std.mem.Allocator, dir_path: []const u8) !*graph_exec.GraphStorage {
    const g = allocator.create(graph_exec.GraphStorage) catch return error.OutOfMemory;
    g.* = graph_exec.GraphStorage.init(allocator, g_audit_logger);
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    // nodes.jsonl and edges.jsonl simple line-delimited json
    // GAP-0117 SECURITY FIX: JSON parsing with proper limits and error logging
    const json_max_depth: usize = 32;

    if (dir.openFile("nodes.jsonl", .{})) |nf| {
        defer nf.close();
        const content = try nf.readToEndAlloc(allocator, 1024 * 1024 * 10); // 10MB max
        defer allocator.free(content);
        var lines = std.mem.tokenizeScalar(u8, content, '\n');
        while (lines.next()) |line| {
            // GAP-0117: Add depth limit and log parse errors instead of silent continue
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
                .max_depth = json_max_depth,
            }) catch |err| {
                log.warn("JSON parse error in nodes.jsonl", &.{Attr.string("error", @errorName(err))});
                continue;
            };
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const obj = parsed.value.object;
            const idv = obj.get("id") orelse continue;
            const id: u64 = switch (idv) {
                .integer => |iv| @intCast(iv),
                else => 0,
            };
            if (id == 0) continue;
            var labels: []const []const u8 = &.{};
            if (obj.get("labels")) |lv| if (lv == .array) {
                const arr = lv.array.items;
                var tmp = try allocator.alloc([]const u8, arr.len);
                var i: usize = 0;
                while (i < arr.len) : (i += 1) tmp[i] = if (arr[i] == .string) arr[i].string else "";
                labels = tmp;
            };
            try g.addNode(allocator, id, labels);
            if (obj.get("properties")) |pv| {
                if (pv == .object) {
                    var it = pv.object.iterator();
                    while (it.next()) |e| {
                        const key = e.key_ptr.*;
                        const val = e.value_ptr.*;
                        const pv2: graph_exec.PropertyValue = switch (val) {
                            .null => .{ .Null = {} },
                            .bool => |b| .{ .Bool = b },
                            .integer => |n| .{ .Int = @intCast(n) },
                            .string => |s| .{ .String = allocator.dupe(u8, s) catch s },
                            else => .{ .Null = {} },
                        };
                        g.setNodeProperty(allocator, id, key, pv2) catch {};
                    }
                }
            }
        }
    } else |_| {}
    if (dir.openFile("edges.jsonl", .{})) |ef| {
        defer ef.close();
        const content = try ef.readToEndAlloc(allocator, 1024 * 1024 * 10); // 10MB max
        defer allocator.free(content);
        var lines = std.mem.tokenizeScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const obj = parsed.value.object;
            const sv = obj.get("source") orelse continue;
            const tv = obj.get("target") orelse continue;
            const tyv = obj.get("type") orelse continue;
            const sid: u64 = switch (sv) {
                .integer => |iv| @intCast(iv),
                else => 0,
            };
            const tid: u64 = switch (tv) {
                .integer => |iv| @intCast(iv),
                else => 0,
            };
            const ety: []const u8 = switch (tyv) {
                .string => |s| s,
                else => "",
            };
            if (sid == 0 or tid == 0) continue;
            const eid = try g.addEdge(allocator, sid, tid, ety);
            if (obj.get("properties")) |pv| {
                if (pv == .object) {
                    var it = pv.object.iterator();
                    while (it.next()) |e| {
                        const key = e.key_ptr.*;
                        const val = e.value_ptr.*;
                        const pv2: graph_exec.PropertyValue = switch (val) {
                            .null => .{ .Null = {} },
                            .bool => |b| .{ .Bool = b },
                            .integer => |n| .{ .Int = @intCast(n) },
                            .string => |s| .{ .String = allocator.dupe(u8, s) catch s },
                            else => .{ .Null = {} },
                        };
                        g.setEdgeProperty(allocator, @intCast(eid), key, pv2) catch {};
                    }
                }
            }
        }
    } else |_| {}
    return g;
}

/// Save graph to persistent storage directory
/// Writes nodes.jsonl and edges.jsonl in JSON Lines format
pub fn saveGraphToDir(allocator: std.mem.Allocator, g: *const graph_exec.GraphStorage, dir_path: []const u8) void {
    // Create directory with error handling
    std.fs.cwd().makePath(dir_path) catch |err| {
        log.warn("Failed to create directory", &.{ Attr.string("path", dir_path), Attr.string("error", @errorName(err)) });
        return;
    };

    // Save nodes with comprehensive error handling
    const nodes_path = std.mem.concat(allocator, u8, &.{ dir_path, "/nodes.jsonl" }) catch {
        log.warn("Failed to allocate nodes path", &.{});
        return;
    };
    defer allocator.free(nodes_path);

    var nodes_content = std.ArrayList(u8).initCapacity(allocator, 0) catch {
        log.warn("Failed to allocate nodes content buffer", &.{});
        return;
    };
    defer nodes_content.deinit(allocator);

    var node_count: usize = 0;
    var it = g.nodes.iterator();
    while (it.next()) |entry| {
        node_count += 1;
        const node = entry.value_ptr.*;

        // Validate node structure before processing
        if (node_count > 10000) {
            log.warn("Too many nodes, stopping save", &.{Attr.int("node_count", @intCast(node_count))});
            break;
        }

        std.fmt.format(nodes_content.writer(allocator), "{{\"id\":{d},\"labels\":[", .{node.id}) catch continue;

        // Safe label processing with validation
        if (node.labels.len > 0 and node.labels.len < 100) { // Reasonable label count limit
            for (node.labels, 0..) |label, li| {
                if (li > 0) nodes_content.appendSlice(allocator, ",") catch continue;

                // Validate label string
                if (label.len > 0 and label.len < 256) { // Reasonable label length
                    std.fmt.format(nodes_content.writer(allocator), "\"{s}\"", .{label}) catch {
                        nodes_content.appendSlice(allocator, "\"\"") catch continue;
                    };
                } else {
                    nodes_content.appendSlice(allocator, "\"\"") catch continue;
                }
            }
        }
        nodes_content.appendSlice(allocator, "],\"properties\":{") catch {};
        var pit = node.properties.iterator();
        var firstp = true;
        while (pit.next()) |p| {
            if (!firstp) nodes_content.appendSlice(allocator, ",") catch {} else firstp = false;
            const k = p.key_ptr.*;
            const v = p.value_ptr.*;
            std.fmt.format(nodes_content.writer(allocator), "\"{s}\":", .{k}) catch {};
            switch (v) {
                .Null => nodes_content.appendSlice(allocator, "null") catch {},
                .Bool => |b| std.fmt.format(nodes_content.writer(allocator), "{}", .{b}) catch {},
                .Int => |iv| std.fmt.format(nodes_content.writer(allocator), "{d}", .{iv}) catch {},
                .String => |s| std.fmt.format(nodes_content.writer(allocator), "\"{s}\"", .{s}) catch {},
                .Decimal => nodes_content.appendSlice(allocator, "null") catch {},
                .VectorF32 => |vec| std.fmt.format(nodes_content.writer(allocator), "\"[vector:{d}x{d}]\"", .{ vec.dim, vec.data.len }) catch {},
            }
        }
        nodes_content.appendSlice(allocator, "}}\n") catch {};
    }

    std.fs.cwd().writeFile(.{ .sub_path = nodes_path, .data = nodes_content.items }) catch {};

    // Save edges
    const edges_path = std.mem.concat(allocator, u8, &.{ dir_path, "/edges.jsonl" }) catch return;
    defer allocator.free(edges_path);

    var edges_content = std.ArrayList(u8).initCapacity(allocator, 0) catch return;
    defer edges_content.deinit(allocator);

    var i: usize = 0;
    while (i < g.edges.items.len) : (i += 1) {
        const e = g.edges.items[i];
        std.fmt.format(edges_content.writer(allocator), "{{\"source\":{d},\"target\":{d},\"type\":\"{s}\",\"properties\":{{}}}}\n", .{ e.source, e.target, e.edge_type }) catch {};
    }

    std.fs.cwd().writeFile(.{ .sub_path = edges_path, .data = edges_content.items }) catch {};
}

/// Initialize graph with sample data (3 Person nodes with relationships)
/// Used when no persistent storage is available
pub fn initializeSampleGraph(allocator: std.mem.Allocator, graph: *graph_exec.GraphStorage) !void {
    // Add sample nodes
    try graph.addNode(allocator, 1, &.{"Person"});
    try graph.setNodeProperty(allocator, 1, "name", .{ .String = "Alice" });
    try graph.setNodeProperty(allocator, 1, "age", .{ .Int = 30 });

    try graph.addNode(allocator, 2, &.{"Person"});
    try graph.setNodeProperty(allocator, 2, "name", .{ .String = "Bob" });
    try graph.setNodeProperty(allocator, 2, "age", .{ .Int = 25 });

    try graph.addNode(allocator, 3, &.{"Person"});
    try graph.setNodeProperty(allocator, 3, "name", .{ .String = "Charlie" });
    try graph.setNodeProperty(allocator, 3, "age", .{ .Int = 35 });

    // Add sample edges
    const e1 = try graph.addEdge(allocator, 1, 2, "KNOWS");
    try graph.setEdgeProperty(allocator, e1, "since", .{ .Int = 2020 });

    const e2 = try graph.addEdge(allocator, 2, 3, "KNOWS");
    try graph.setEdgeProperty(allocator, e2, "since", .{ .Int = 2021 });

    const e3 = try graph.addEdge(allocator, 1, 3, "WORKS_WITH");
    try graph.setEdgeProperty(allocator, e3, "department", .{ .String = "Engineering" });
}

/// Set the global data directory for persistence
pub fn setDataDir(dir: ?[]const u8) void {
    g_data_dir = dir;
}

/// Get the global data directory
pub fn getDataDir() ?[]const u8 {
    return g_data_dir;
}

/// Get the current graph storage instance (may be null)
pub fn getCurrentGraphStorage() ?*graph_exec.GraphStorage {
    return g_graph_storage;
}

/// Clear the global graph storage instance (for testing)
pub fn clearGraphStorage() void {
    g_graph_storage = null;
}

// ============================================================================
// Multi-Graph Storage Support
// ============================================================================

/// Initialize the multi-graph storage system
/// Must be called before using getGraphStorageByName or createGraphStorage
pub fn initMultiGraphStorage(allocator: std.mem.Allocator) void {
    if (g_graph_storages == null) {
        g_allocator = allocator;
        g_graph_storages = std.StringHashMap(*graph_exec.GraphStorage).init(allocator);

        // Register the default graph (created by getOrCreateGraphStorage)
        if (g_graph_storage) |default_storage| {
            const name_copy = allocator.dupe(u8, DEFAULT_GRAPH_NAME) catch return;
            g_graph_storages.?.put(name_copy, default_storage) catch {};
        }
    }
}

/// Get graph storage by name
/// Returns the storage for the specified graph, or the default graph if name is null
/// Returns null if the graph doesn't exist
pub fn getGraphStorageByName(name: ?[]const u8) ?*graph_exec.GraphStorage {
    const graph_name = name orelse DEFAULT_GRAPH_NAME;

    // Check multi-graph storage first
    if (g_graph_storages) |storages| {
        if (storages.get(graph_name)) |storage| {
            return storage;
        }
    }

    // Fall back to default for legacy compatibility
    if (std.mem.eql(u8, graph_name, DEFAULT_GRAPH_NAME)) {
        return g_graph_storage;
    }

    return null;
}

/// Create a new empty graph storage with the given name
/// Returns error if graph already exists
pub fn createGraphStorage(allocator: std.mem.Allocator, name: []const u8) !*graph_exec.GraphStorage {
    log.debug("createGraphStorage called", &.{
        Attr.string("name", name),
    });

    // Initialize multi-graph storage if needed
    if (g_graph_storages == null) {
        log.debug("createGraphStorage: initializing multi-graph storage", &.{});
        initMultiGraphStorage(allocator);
    }

    // Check if graph already exists
    if (g_graph_storages) |storages| {
        log.debug("createGraphStorage: checking if graph exists", &.{
            Attr.int("entries", @intCast(storages.count())),
        });
        if (storages.contains(name)) {
            log.debug("createGraphStorage: graph already exists", &.{
                Attr.string("name", name),
            });
            return error.GraphAlreadyExists;
        }
    }

    // Create new empty graph storage
    const graph = try allocator.create(graph_exec.GraphStorage);
    graph.* = graph_exec.GraphStorage.init(allocator, g_audit_logger);

    // Register in multi-graph storage
    if (g_graph_storages) |*storages| {
        const name_copy = try allocator.dupe(u8, name);
        try storages.put(name_copy, graph);
        log.debug("createGraphStorage: added to storage", &.{
            Attr.string("name", name),
            Attr.int("entries", @intCast(storages.count())),
        });
    }

    log.debug("createGraphStorage: SUCCESS", &.{
        Attr.string("name", name),
    });
    return graph;
}

/// Check if a graph exists
pub fn graphExists(name: []const u8) bool {
    if (g_graph_storages) |storages| {
        return storages.contains(name);
    }
    return std.mem.eql(u8, name, DEFAULT_GRAPH_NAME) and g_graph_storage != null;
}

/// List all graph names
pub fn listGraphNames(allocator: std.mem.Allocator) ![][]const u8 {
    log.debug("listGraphNames called", &.{});
    var names = try std.ArrayList([]const u8).initCapacity(allocator, 32);
    errdefer names.deinit(allocator);

    if (g_graph_storages) |storages| {
        log.debug("listGraphNames: has entries", &.{
            Attr.int("count", @intCast(storages.count())),
        });
        var it = storages.keyIterator();
        while (it.next()) |key| {
            log.debug("listGraphNames: listing", &.{
                Attr.string("name", key.*),
            });
            try names.append(allocator, try allocator.dupe(u8, key.*));
        }
    } else if (g_graph_storage != null) {
        log.debug("listGraphNames: using default", &.{});
        try names.append(allocator, try allocator.dupe(u8, DEFAULT_GRAPH_NAME));
    } else {
        log.debug("listGraphNames: no storages", &.{});
    }

    log.debug("listGraphNames returning", &.{
        Attr.int("count", @intCast(names.items.len)),
    });
    return names.toOwnedSlice(allocator);
}

// GAP-0139: SHOW TABLES implementation helper
// CANARY: REQ=REQ-SHOW-TABLES-002; FEATURE="SHOW TABLES"; ASPECT=GraphStorageList; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=engine; UPDATED=2026-01-13
/// List all unique node labels from all graphs
/// In graph databases, node labels serve as the equivalent of "tables"
pub fn listNodeLabels(allocator: std.mem.Allocator) ![][]const u8 {
    var label_set = std.StringHashMap(void).init(allocator);
    defer label_set.deinit();

    // Collect labels from all graphs
    if (g_graph_storages) |storages| {
        var it = storages.valueIterator();
        while (it.next()) |storage_ptr| {
            // Dereference the pointer to GraphStorage
            const storage = storage_ptr.*;
            // Iterate over all nodes in this graph storage
            var node_it = storage.nodes.iterator();
            while (node_it.next()) |entry| {
                const node = entry.value_ptr.*;
                for (node.labels) |label| {
                    // Use put to track unique labels
                    const label_copy = try allocator.dupe(u8, label);
                    errdefer allocator.free(label_copy);
                    const result = try label_set.getOrPut(label_copy);
                    if (result.found_existing) {
                        // Already have this label, free the copy
                        allocator.free(label_copy);
                    }
                }
            }
        }
    } else if (g_graph_storage) |storage| {
        var node_it = storage.nodes.iterator();
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
    }

    // Convert label set to array
    var labels = try std.ArrayList([]const u8).initCapacity(allocator, label_set.count());
    errdefer labels.deinit(allocator);

    var key_it = label_set.keyIterator();
    while (key_it.next()) |key| {
        try labels.append(allocator, key.*);
    }

    return labels.toOwnedSlice(allocator);
}

/// Drop a graph storage by name
pub fn dropGraphStorage(name: []const u8) !void {
    log.debug("dropGraphStorage called", &.{
        Attr.string("name", name),
        Attr.int("len", @intCast(name.len)),
    });

    if (std.mem.eql(u8, name, DEFAULT_GRAPH_NAME)) {
        log.debug("dropGraphStorage: refusing to drop default graph", &.{});
        return error.CannotDropDefaultGraph;
    }

    if (g_graph_storages) |*storages| {
        log.debug("dropGraphStorage: checking storages", &.{
            Attr.int("entries", @intCast(storages.count())),
        });
        var it = storages.keyIterator();
        while (it.next()) |key| {
            log.debug("dropGraphStorage: stored key", &.{
                Attr.string("key", key.*),
                Attr.int("len", @intCast(key.*.len)),
            });
        }

        if (storages.fetchRemove(name)) |entry| {
            // Free the graph storage
            const alloc = g_allocator orelse return;
            entry.value.deinit();
            alloc.destroy(entry.value);
            alloc.free(entry.key);
            log.debug("dropGraphStorage: SUCCESS", &.{
                Attr.string("name", name),
            });
        } else {
            log.debug("dropGraphStorage: fetchRemove returned null", &.{
                Attr.string("name", name),
            });
            return error.GraphNotFound;
        }
    } else {
        log.debug("dropGraphStorage: g_graph_storages is null", &.{});
        return error.GraphNotFound;
    }
}
