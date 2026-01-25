const std = @import("std");
const fle_integration = @import("fle_integration.zig");
const uuid = @import("uuid.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Storage; STATUS=EXEMPT; OWNER=storage; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("storage");
const Attr = logging.Attr;

/// Generate a time-based unique 64-bit ID (UUIDv7-compatible lower 64 bits)
/// Structure: 48-bit timestamp (ms) | 16-bit random
/// This provides time-sortable, unique IDs without changing the NodeId type
fn generateTimeBasedId() u64 {
    const timestamp_ms: u64 = @intCast(std.time.milliTimestamp());
    // Use nanosecond timestamp as seed for randomness
    const seed: u64 = @intCast(std.time.nanoTimestamp());
    var prng = std.Random.DefaultPrng.init(seed);
    const random_bits: u16 = prng.random().int(u16);
    // Combine: 48-bit timestamp | 16-bit random
    return (timestamp_ms << 16) | @as(u64, random_bits);
}

// Field-Level Encryption Storage Hooks
// CANARY: REQ=REQ-FLE-STORAGE-001; FEATURE="FieldLevelEncryption"; ASPECT=STORAGE; STATUS=TESTED; TEST=tests/test_tde_kms_integration.zig; OWNER=security; UPDATED=2026-01-15

// Simple graph store with file-based persistence for testing
// Real implementation would use proper storage engine

/// Get the persistence file path, respecting GEODE_DATA_DIR environment variable
/// Returns an allocated path that must be freed by the caller
fn getPersistenceFilePath(allocator: std.mem.Allocator) ![]u8 {
    const builtin = @import("builtin");

    // Helper to get fallback temp directory path
    const getFallbackPath = struct {
        fn get(alloc: std.mem.Allocator) ![]u8 {
            if (builtin.os.tag == .windows) {
                const temp = std.process.getEnvVarOwned(alloc, "TEMP") catch
                    std.process.getEnvVarOwned(alloc, "TMP") catch {
                    // Fallback to current directory if no temp env var
                    return try alloc.dupe(u8, "geode_graph_store.dat");
                };
                defer alloc.free(temp);
                return try std.fmt.allocPrint(alloc, "{s}\\geode_graph_store.dat", .{temp});
            } else {
                return try alloc.dupe(u8, "/tmp/geode_graph_store.dat");
            }
        }
    }.get;

    // Check for GEODE_DATA_DIR environment variable
    const data_dir = std.process.getEnvVarOwned(allocator, "GEODE_DATA_DIR") catch |err| {
        // If not set or error, use platform-specific temp directory
        if (err == error.EnvironmentVariableNotFound) {
            return try getFallbackPath(allocator);
        }
        return err;
    };
    defer allocator.free(data_dir);

    // Try to create the directory - if it fails, fall back to temp directory
    std.fs.cwd().makePath(data_dir) catch |err| {
        log.warn("Failed to create graph store directory, using temp directory instead", &.{
            Attr.string("data_dir", data_dir),
            Attr.err("error", err),
        });
        return try getFallbackPath(allocator);
    };

    // Verify we can actually write to the directory by creating a test file
    const sep = if (builtin.os.tag == .windows) "\\" else "/";
    const test_path = try std.fmt.allocPrint(allocator, "{s}{s}.geode_write_test", .{ data_dir, sep });
    defer allocator.free(test_path);

    const test_file = std.fs.cwd().createFile(test_path, .{}) catch |err| {
        log.warn("Cannot write to graph store directory, using temp directory instead", &.{
            Attr.string("data_dir", data_dir),
            Attr.err("error", err),
        });
        return try getFallbackPath(allocator);
    };
    test_file.close();
    std.fs.cwd().deleteFile(test_path) catch {};

    // Directory is valid and writable, use it
    return try std.fmt.allocPrint(allocator, "{s}{s}graph_store.dat", .{ data_dir, sep });
}

pub const Node = struct {
    id: u64,
    labels: [][]const u8,
    properties: std.StringHashMap(PropertyValue),
    // CANARY: REQ=REQ-MULTI-GRAPH-003; FEATURE="MultiGraphIsolation"; ASPECT=NodeGraphTag; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
    // Graph name this node belongs to - enables per-graph data isolation
    graph_name: []const u8 = "default",
};

pub const Edge = struct {
    id: u64,
    from_id: u64,
    to_id: u64,
    label: []const u8,
    properties: std.StringHashMap(PropertyValue),
    // CANARY: REQ=REQ-MULTI-GRAPH-003; FEATURE="MultiGraphIsolation"; ASPECT=EdgeGraphTag; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
    // Graph name this edge belongs to - enables per-graph data isolation
    graph_name: []const u8 = "default",
};

pub const PropertyValue = union(enum) {
    String: []const u8,
    Int: i64,
    Float: f64,
    Bool: bool,
    Null,
    ExtValue: @import("eval_extended.zig").ExtValue,
    // CANARY: REQ=REQ-GQL-DECIMAL-001; FEATURE="DecimalPrecision"; ASPECT=PropertyStorage; STATUS=TESTED; TEST=geodetestlab/specs/gap_analysis_fixes_january_2026.yml; OWNER=core; UPDATED=2026-01-25
    Decimal: struct { coeff: i128, scale: u8 },
};

// CANARY: REQ=REQ-MULTI-TENANT-001; FEATURE="MultiTenancy"; ASPECT=GraphStore; STATUS=TESTED; TEST=geodetestlab/specs/gql_session_management_comprehensive.yml; OWNER=enterprise; UPDATED=2026-01-09
pub const GraphStore = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMap(u64, Node),
    edges: std.AutoHashMap(u64, Edge),
    next_node_id: u64,
    next_edge_id: u64,
    // Multi-tenancy: tenant_id scopes all data operations
    tenant_id: []const u8,
    schema_name: []const u8,

    /// Initialize GraphStore with default tenant
    pub fn init(allocator: std.mem.Allocator) GraphStore {
        return initWithTenant(allocator, "default", "default");
    }

    /// Initialize GraphStore with specific tenant and schema
    pub fn initWithTenant(allocator: std.mem.Allocator, tenant_id: []const u8, schema_name: []const u8) GraphStore {
        return GraphStore{
            .allocator = allocator,
            .nodes = std.AutoHashMap(u64, Node).init(allocator),
            .edges = std.AutoHashMap(u64, Edge).init(allocator),
            .next_node_id = 1,
            .next_edge_id = 1,
            .tenant_id = tenant_id,
            .schema_name = schema_name,
        };
    }

    /// Set tenant ID for this graph store (used when context changes)
    pub fn setTenant(self: *GraphStore, tenant_id: []const u8) void {
        self.tenant_id = tenant_id;
    }

    /// Set schema name for this graph store
    pub fn setSchema(self: *GraphStore, schema_name: []const u8) void {
        self.schema_name = schema_name;
    }

    /// Get current tenant ID
    pub fn getTenantId(self: *const GraphStore) []const u8 {
        return self.tenant_id;
    }

    pub fn deinit(self: *GraphStore) void {
        // Clear nodes and edges (which also frees memory)
        self.clearNodes();
        // Deinit the hashmaps
        self.nodes.deinit();
        self.edges.deinit();
    }

    pub fn clearNodes(self: *GraphStore) void {
        // Free and clear all nodes
        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            // Free each label string
            for (entry.value_ptr.labels) |label| {
                self.allocator.free(label);
            }
            // Free the labels array itself
            self.allocator.free(entry.value_ptr.labels);
            // Free the graph_name (always allocated via create functions)
            if (entry.value_ptr.graph_name.len > 0) {
                self.allocator.free(entry.value_ptr.graph_name);
            }
            // Free the properties hashmap
            var prop_iter = entry.value_ptr.properties.iterator();
            while (prop_iter.next()) |prop_entry| {
                // Free the key
                self.allocator.free(prop_entry.key_ptr.*);
                // Free string values
                switch (prop_entry.value_ptr.*) {
                    .String => |s| self.allocator.free(s),
                    else => {},
                }
            }
            entry.value_ptr.properties.deinit();
        }
        self.nodes.clearRetainingCapacity();

        // Free and clear all edges
        var edge_iter = self.edges.iterator();
        while (edge_iter.next()) |entry| {
            // Free the label string
            self.allocator.free(entry.value_ptr.label);
            // Free the graph_name (always allocated via create functions)
            if (entry.value_ptr.graph_name.len > 0) {
                self.allocator.free(entry.value_ptr.graph_name);
            }
            // Free the properties hashmap
            var prop_iter = entry.value_ptr.properties.iterator();
            while (prop_iter.next()) |prop_entry| {
                // Free the key
                self.allocator.free(prop_entry.key_ptr.*);
                // Free string values
                switch (prop_entry.value_ptr.*) {
                    .String => |s| self.allocator.free(s),
                    else => {},
                }
            }
            entry.value_ptr.properties.deinit();
        }
        self.edges.clearRetainingCapacity();

        self.next_node_id = 1;
        self.next_edge_id = 1;
    }

    // Clear only nodes and edges for a specific graph
    // CANARY: REQ=REQ-MULTI-GRAPH-005; FEATURE="MultiGraphIsolation"; ASPECT=ClearGraphNodes; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-23
    pub fn clearNodesForGraph(self: *GraphStore, graph_name: []const u8) void {
        // Collect node IDs to remove (can't modify while iterating)
        var nodes_to_remove = std.ArrayList(u64).initCapacity(self.allocator, 0) catch return;
        defer nodes_to_remove.deinit(self.allocator);

        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.graph_name, graph_name)) {
                nodes_to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        // Remove and free the nodes
        for (nodes_to_remove.items) |node_id| {
            if (self.nodes.fetchRemove(node_id)) |kv| {
                var node = kv.value;
                // Free each label string
                for (node.labels) |label| {
                    self.allocator.free(label);
                }
                // Free the labels array itself
                self.allocator.free(node.labels);
                // Free the graph_name
                if (node.graph_name.len > 0) {
                    self.allocator.free(node.graph_name);
                }
                // Free the properties hashmap
                var prop_iter = node.properties.iterator();
                while (prop_iter.next()) |prop_entry| {
                    self.allocator.free(prop_entry.key_ptr.*);
                    switch (prop_entry.value_ptr.*) {
                        .String => |s| self.allocator.free(s),
                        else => {},
                    }
                }
                node.properties.deinit();
            }
        }

        // Collect edge IDs to remove
        var edges_to_remove = std.ArrayList(u64).initCapacity(self.allocator, 0) catch return;
        defer edges_to_remove.deinit(self.allocator);

        var edge_iter = self.edges.iterator();
        while (edge_iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.graph_name, graph_name)) {
                edges_to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        // Remove and free the edges
        for (edges_to_remove.items) |edge_id| {
            if (self.edges.fetchRemove(edge_id)) |kv| {
                var edge = kv.value;
                self.allocator.free(edge.label);
                if (edge.graph_name.len > 0) {
                    self.allocator.free(edge.graph_name);
                }
                var prop_iter = edge.properties.iterator();
                while (prop_iter.next()) |prop_entry| {
                    self.allocator.free(prop_entry.key_ptr.*);
                    switch (prop_entry.value_ptr.*) {
                        .String => |s| self.allocator.free(s),
                        else => {},
                    }
                }
                edge.properties.deinit();
            }
        }
    }

    // CANARY: REQ=REQ-MULTI-GRAPH-004; FEATURE="MultiGraphIsolation"; ASPECT=CreateNode; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
    // Create node with optional graph name for per-graph data isolation
    pub fn createNodeWithGraph(self: *GraphStore, labels: [][]const u8, graph_name: []const u8) !u64 {
        // Generate UUIDv7-style time-based unique ID
        const id = generateTimeBasedId();

        const labels_copy = try self.allocator.alloc([]const u8, labels.len);
        for (labels, 0..) |label, i| {
            labels_copy[i] = try self.allocator.dupe(u8, label);
        }

        const graph_name_copy = try self.allocator.dupe(u8, graph_name);

        const node = Node{
            .id = id,
            .labels = labels_copy,
            .properties = std.StringHashMap(PropertyValue).init(self.allocator),
            .graph_name = graph_name_copy,
        };

        try self.nodes.put(id, node);
        return id;
    }

    // Backward-compatible createNode that uses "default" graph
    pub fn createNode(self: *GraphStore, labels: [][]const u8) !u64 {
        return self.createNodeWithGraph(labels, "default");
    }

    pub fn setNodeProperty(self: *GraphStore, node_id: u64, key: []const u8, value: PropertyValue) !void {
        if (self.nodes.getPtr(node_id)) |node| {
            // Note: Encryption is now handled by the caller (execution.zig) before calling setNodeProperty
            // This ensures consistent parameters (schema, record_id) between encryption and decryption
            const value_copy = switch (value) {
                .String => |s| PropertyValue{ .String = try self.allocator.dupe(u8, s) },
                else => value,
            };

            // Use getOrPut to avoid memory leak - only allocate key if it doesn't exist
            const result = try node.properties.getOrPut(key);
            if (!result.found_existing) {
                // Key doesn't exist, allocate a copy
                result.key_ptr.* = try self.allocator.dupe(u8, key);
            } else {
                // Key exists, free old value if it was a string
                switch (result.value_ptr.*) {
                    .String => |s| self.allocator.free(s),
                    else => {},
                }
            }
            result.value_ptr.* = value_copy;

            // Save to persistent storage
            self.saveToFile() catch |err| {
                log.err("CRITICAL: Failed to persist graph after node property set", &.{
                    Attr.int("node_id", @intCast(node_id)),
                    Attr.err("error", err),
                });
            };
        }
    }

    pub fn getNodeProperty(self: *GraphStore, node_id: u64, key: []const u8) ?PropertyValue {
        if (self.nodes.get(node_id)) |node| {
            const value = node.properties.get(key) orelse return null;

            // Field-Level Encryption: decrypt string values if encrypted
            switch (value) {
                .String => |s| {
                    // Get node type (primary label) for catalog lookup
                    const type_name = if (node.labels.len > 0) node.labels[0] else "Unknown";

                    // Create encryption context using GraphStore's tenant/schema
                    const fle_ctx = fle_integration.EncryptionContext{
                        .tenant_id = self.tenant_id,
                        .schema_name = self.schema_name,
                        .allocator = self.allocator,
                        .current_user_role = fle_integration.getCurrentUserRole(),
                    };

                    // Format record ID
                    const record_id = std.fmt.allocPrint(self.allocator, "node_{d}", .{node_id}) catch s;
                    defer if (!std.mem.eql(u8, record_id, s)) self.allocator.free(record_id);

                    // Decrypt if field is encrypted
                    const decrypted_value = fle_integration.decryptFieldIfNeeded(
                        fle_ctx,
                        type_name,
                        key,
                        s,
                        record_id,
                        true, // Check RBAC permissions
                    ) catch s; // Fall back to original value on error

                    // If decryption returned a different value, return new PropertyValue
                    if (!std.mem.eql(u8, decrypted_value, s)) {
                        return PropertyValue{ .String = decrypted_value };
                    }

                    return value;
                },
                else => return value,
            }
        }
        return null;
    }

    pub fn removeNodeProperty(self: *GraphStore, node_id: u64, key: []const u8) void {
        if (self.nodes.getPtr(node_id)) |node| {
            _ = node.properties.remove(key);
            // Save to persistent storage
            self.saveToFile() catch |err| {
                log.err("CRITICAL: Failed to persist graph after node property removal", &.{
                    Attr.int("node_id", @intCast(node_id)),
                    Attr.err("error", err),
                });
            };
        }
    }

    pub fn addNodeLabel(self: *GraphStore, node_id: u64, label: []const u8) !void {
        if (self.nodes.getPtr(node_id)) |node| {
            // Check if label already exists
            for (node.labels) |existing_label| {
                if (std.mem.eql(u8, existing_label, label)) {
                    return; // Label already exists, no need to add
                }
            }

            // Add the label to the node's labels array
            const label_copy = try self.allocator.dupe(u8, label);
            const new_labels = try self.allocator.alloc([]const u8, node.labels.len + 1);
            @memcpy(new_labels[0..node.labels.len], node.labels);
            new_labels[node.labels.len] = label_copy;

            // Free old labels array if it was allocated
            if (node.labels.len > 0) {
                self.allocator.free(node.labels);
            }

            node.labels = new_labels;

            // Save to persistent storage
            self.saveToFile() catch |err| {
                log.err("CRITICAL: Failed to persist graph store", &.{
                    Attr.err("error", err),
                });
            };
        }
    }

    pub fn removeNodeLabel(self: *GraphStore, node_id: u64, label: []const u8) !void {
        if (self.nodes.getPtr(node_id)) |node| {
            // Find the label to remove
            var found_index: ?usize = null;
            for (node.labels, 0..) |existing_label, i| {
                if (std.mem.eql(u8, existing_label, label)) {
                    found_index = i;
                    break;
                }
            }

            if (found_index) |index| {
                // Create new labels array without the removed label
                const new_labels = try self.allocator.alloc([]const u8, node.labels.len - 1);
                var new_index: usize = 0;
                for (node.labels, 0..) |existing_label, i| {
                    if (i != index) {
                        new_labels[new_index] = existing_label;
                        new_index += 1;
                    }
                }

                // Free old labels array if it was allocated
                if (node.labels.len > 0) {
                    self.allocator.free(node.labels);
                }

                node.labels = new_labels;

                // Save to persistent storage
                self.saveToFile() catch |err| {
                    log.err("CRITICAL: Failed to persist graph store", &.{
                        Attr.err("error", err),
                    });
                };
            }
        }
    }

    pub fn getAllNodes(self: *GraphStore) []Node {
        var result = self.allocator.alloc(Node, self.nodes.count()) catch return &.{};
        var iter = self.nodes.valueIterator();
        var i: usize = 0;
        while (iter.next()) |node| {
            result[i] = node.*;
            i += 1;
        }
        return result;
    }

    pub fn getNodeCount(self: *GraphStore) usize {
        return self.nodes.count();
    }

    // CANARY: REQ=REQ-MULTI-GRAPH-005; FEATURE="MultiGraphIsolation"; ASPECT=CreateEdge; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
    // Create edge with optional graph name for per-graph data isolation
    pub fn createEdgeWithGraph(self: *GraphStore, from_id: u64, to_id: u64, edge_type: []const u8, graph_name: []const u8) !u64 {
        // Generate UUIDv7-style time-based unique ID
        const id = generateTimeBasedId();

        const edge_type_copy = try self.allocator.dupe(u8, edge_type);
        const graph_name_copy = try self.allocator.dupe(u8, graph_name);

        const edge = Edge{
            .id = id,
            .from_id = from_id,
            .to_id = to_id,
            .label = edge_type_copy,
            .properties = std.StringHashMap(PropertyValue).init(self.allocator),
            .graph_name = graph_name_copy,
        };

        try self.edges.put(id, edge);

        // Save to persistent storage
        self.saveToFile() catch |err| {
            log.err("CRITICAL: Failed to persist graph store", &.{
                Attr.err("error", err),
            });
        };

        return id;
    }

    // Backward-compatible createEdge that uses "default" graph
    pub fn createEdge(self: *GraphStore, from_id: u64, to_id: u64, edge_type: []const u8) !u64 {
        return self.createEdgeWithGraph(from_id, to_id, edge_type, "default");
    }

    pub fn setEdgeProperty(self: *GraphStore, edge_id: u64, key: []const u8, value: PropertyValue) !void {
        if (self.edges.getPtr(edge_id)) |edge| {
            // Note: Encryption is now handled by the caller (execution.zig) before calling setEdgeProperty
            // This ensures consistent parameters (schema, record_id) between encryption and decryption
            const value_copy = switch (value) {
                .String => |s| PropertyValue{ .String = try self.allocator.dupe(u8, s) },
                else => value,
            };

            // Use getOrPut to avoid memory leak - only allocate key if it doesn't exist
            const result = try edge.properties.getOrPut(key);
            if (!result.found_existing) {
                // Key doesn't exist, allocate a copy
                result.key_ptr.* = try self.allocator.dupe(u8, key);
            } else {
                // Key exists, free old value if it was a string
                switch (result.value_ptr.*) {
                    .String => |s| self.allocator.free(s),
                    else => {},
                }
            }
            result.value_ptr.* = value_copy;

            // Save to persistent storage
            self.saveToFile() catch |err| {
                log.err("CRITICAL: Failed to persist graph store", &.{
                    Attr.err("error", err),
                });
            };
        }
    }

    pub fn getEdgesByType(self: *GraphStore, edge_type: []const u8) []Edge {
        var count: usize = 0;
        var iter = self.edges.valueIterator();
        while (iter.next()) |edge| {
            if (std.mem.eql(u8, edge.label, edge_type)) {
                count += 1;
            }
        }

        const result = self.allocator.alloc(Edge, count) catch return &.{};
        var i: usize = 0;
        iter = self.edges.valueIterator();
        while (iter.next()) |edge| {
            if (std.mem.eql(u8, edge.label, edge_type)) {
                result[i] = edge.*;
                i += 1;
            }
        }
        return result;
    }

    pub fn getEdgesFrom(self: *GraphStore, node_id: u64) []Edge {
        var count: usize = 0;
        var iter = self.edges.valueIterator();
        while (iter.next()) |edge| {
            if (edge.from_id == node_id) {
                count += 1;
            }
        }

        const result = self.allocator.alloc(Edge, count) catch return &.{};
        var i: usize = 0;
        iter = self.edges.valueIterator();
        while (iter.next()) |edge| {
            if (edge.from_id == node_id) {
                result[i] = edge.*;
                i += 1;
            }
        }
        return result;
    }

    pub fn getEdgesTo(self: *GraphStore, node_id: u64) []Edge {
        var count: usize = 0;
        var iter = self.edges.valueIterator();
        while (iter.next()) |edge| {
            if (edge.to_id == node_id) {
                count += 1;
            }
        }

        const result = self.allocator.alloc(Edge, count) catch return &.{};
        var i: usize = 0;
        iter = self.edges.valueIterator();
        while (iter.next()) |edge| {
            if (edge.to_id == node_id) {
                result[i] = edge.*;
                i += 1;
            }
        }
        return result;
    }

    // Simple file-based persistence for testing
    pub fn saveToFile(self: *GraphStore) !void {
        const file_path = try getPersistenceFilePath(self.allocator);
        defer self.allocator.free(file_path);
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        // Write header: next_node_id, next_edge_id, node_count, edge_count
        var header: [32]u8 = undefined;
        std.mem.writeInt(u64, header[0..8], self.next_node_id, .little);
        std.mem.writeInt(u64, header[8..16], self.next_edge_id, .little);
        std.mem.writeInt(u64, header[16..24], self.nodes.count(), .little);
        std.mem.writeInt(u64, header[24..32], self.edges.count(), .little);
        _ = try file.write(&header);

        // Write each node
        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr;
            // Write node ID
            var id_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &id_buf, node.id, .little);
            _ = try file.write(&id_buf);

            // Write label count
            var label_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &label_count_buf, @intCast(node.labels.len), .little);
            _ = try file.write(&label_count_buf);

            // Write each label
            for (node.labels) |label| {
                // Validate label length fits in u32 (max ~4GB)
                if (label.len > std.math.maxInt(u32)) {
                    return error.LabelTooLong;
                }
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @as(u32, @intCast(label.len)), .little);
                _ = try file.write(&len_buf);
                _ = try file.write(label);
            }

            // Write property count
            var prop_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &prop_count_buf, @intCast(node.properties.count()), .little);
            _ = try file.write(&prop_count_buf);

            // Write each property
            var prop_iter = node.properties.iterator();
            while (prop_iter.next()) |prop| {
                // Write key length and key
                var key_len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &key_len_buf, @intCast(prop.key_ptr.*.len), .little);
                _ = try file.write(&key_len_buf);
                _ = try file.write(prop.key_ptr.*);

                // Write value type and value
                const val_type: u8 = switch (prop.value_ptr.*) {
                    .String => 0,
                    .Int => 1,
                    .Float => 2,
                    .Bool => 3,
                    .Null => 4,
                    .ExtValue => 5, // ExtValue types
                    .Decimal => 6, // Decimal with preserved precision
                };
                _ = try file.write(&[1]u8{val_type});

                switch (prop.value_ptr.*) {
                    .String => |s| {
                        var len_buf2: [4]u8 = undefined;
                        std.mem.writeInt(u32, &len_buf2, @intCast(s.len), .little);
                        _ = try file.write(&len_buf2);
                        _ = try file.write(s);
                    },
                    .Int => |i| {
                        var int_buf: [8]u8 = undefined;
                        std.mem.writeInt(i64, &int_buf, i, .little);
                        _ = try file.write(&int_buf);
                    },
                    .Float => |f| {
                        var float_buf: [8]u8 = undefined;
                        std.mem.writeInt(u64, &float_buf, @bitCast(f), .little);
                        _ = try file.write(&float_buf);
                    },
                    .Bool => |b| {
                        _ = try file.write(&[1]u8{if (b) 1 else 0});
                    },
                    .Null => {
                        // Nothing to write for null
                    },
                    .ExtValue => |ext| {
                        // Write sub-type byte to distinguish ExtValue variants
                        const sub_type: u8 = switch (ext) {
                            .Null => 0,
                            .Int => 1,
                            .Bool => 2,
                            .Str => 3,
                            .Decimal => 4,
                            .IpAddr => 5,
                            .Subnet => 6,
                            .Mac => 7,
                            .Hash => 8,
                            .Currency => 9,
                            .LanguageTag => 10,
                            .LatLon => 11,
                            .LatLonAlt => 12,
                            .Geometry => 13,
                            .Temperature => 14,
                            .Pressure => 15,
                            .VectorF32 => 16,
                            .Date => 17,
                            .Time => 18,
                            .TimestampTZ => 19,
                            .List => 20,
                            .VectorI32 => 21,
                            .Interval => 22,
                            .UUID => 23,
                            .Url => 24,
                            .Domain => 25,
                            .Bytea => 26,
                            .Json => 27,
                            .Jsonb => 28,
                            .Xml => 29,
                            .BitString => 30,
                            .VarBit => 31,
                            .IntRange => 32,
                            .Enum => 33,
                        };
                        _ = try file.write(&[1]u8{sub_type});

                        // Write the actual data based on sub-type
                        switch (ext) {
                            .Null => {},
                            .Int => |i| {
                                var buf: [8]u8 = undefined;
                                std.mem.writeInt(i64, &buf, i, .little);
                                _ = try file.write(&buf);
                            },
                            .Bool => |b| {
                                _ = try file.write(&[1]u8{if (b) 1 else 0});
                            },
                            .Str => |s| {
                                var len_buf: [4]u8 = undefined;
                                std.mem.writeInt(u32, &len_buf, @intCast(s.len), .little);
                                _ = try file.write(&len_buf);
                                _ = try file.write(s);
                            },
                            .Decimal => |d| {
                                var buf: [17]u8 = undefined;
                                std.mem.writeInt(i128, buf[0..16], d.coeff, .little);
                                buf[16] = d.scale;
                                _ = try file.write(&buf);
                            },
                            .IpAddr => |ip| {
                                const is_v6: u8 = if (ip == .v6) 1 else 0;
                                _ = try file.write(&[1]u8{is_v6});
                                if (ip == .v4) {
                                    _ = try file.write(&ip.v4);
                                } else {
                                    _ = try file.write(&ip.v6);
                                }
                            },
                            .Subnet => |subnet| {
                                // First write the IpAddr
                                const is_v6: u8 = if (subnet.addr == .v6) 1 else 0;
                                _ = try file.write(&[1]u8{is_v6});
                                if (subnet.addr == .v4) {
                                    _ = try file.write(&subnet.addr.v4);
                                } else {
                                    _ = try file.write(&subnet.addr.v6);
                                }
                                // Then write prefix length
                                _ = try file.write(&[1]u8{subnet.prefix_len});
                            },
                            .Mac => |mac| {
                                _ = try file.write(&mac.bytes);
                            },
                            .LatLon => |ll| {
                                var buf: [16]u8 = undefined;
                                std.mem.writeInt(u64, buf[0..8], @bitCast(ll.lat), .little);
                                std.mem.writeInt(u64, buf[8..16], @bitCast(ll.lon), .little);
                                _ = try file.write(&buf);
                            },
                            .LatLonAlt => |lla| {
                                var buf: [25]u8 = undefined;
                                std.mem.writeInt(u64, buf[0..8], @bitCast(lla.lat), .little);
                                std.mem.writeInt(u64, buf[8..16], @bitCast(lla.lon), .little);
                                std.mem.writeInt(u64, buf[16..24], @bitCast(lla.alt), .little);
                                buf[24] = @intFromEnum(lla.ref);
                                _ = try file.write(&buf);
                            },
                            .Geometry => |geom| {
                                var len_buf: [4]u8 = undefined;
                                std.mem.writeInt(u32, &len_buf, @intCast(geom.wkb.len), .little);
                                _ = try file.write(&len_buf);
                                _ = try file.write(geom.wkb);
                            },
                            .Currency => |cur| {
                                _ = try file.write(&cur.code);
                            },
                            .VectorF32 => |vec| {
                                // Write dimension (u16)
                                var dim_buf: [2]u8 = undefined;
                                std.mem.writeInt(u16, &dim_buf, vec.dim, .little);
                                _ = try file.write(&dim_buf);
                                // Write each f32 value
                                for (vec.data) |f| {
                                    var f_buf: [4]u8 = undefined;
                                    std.mem.writeInt(u32, &f_buf, @bitCast(f), .little);
                                    _ = try file.write(&f_buf);
                                }
                            },
                            .VectorI32 => |vec| {
                                // Write dimension (u16)
                                var dim_buf: [2]u8 = undefined;
                                std.mem.writeInt(u16, &dim_buf, vec.dim, .little);
                                _ = try file.write(&dim_buf);
                                // Write each i32 value
                                for (vec.data) |i| {
                                    var i_buf: [4]u8 = undefined;
                                    std.mem.writeInt(i32, &i_buf, i, .little);
                                    _ = try file.write(&i_buf);
                                }
                            },
                            // CANARY: REQ=REQ-TYPE-SERIAL-001; FEATURE="TypeSerialization"; ASPECT=ExtendedTypes; STATUS=EXEMPT; OWNER=storage; UPDATED=2025-12-30
                            .Hash => |hash| {
                                // Write algorithm (u8)
                                _ = try file.write(&[1]u8{@intFromEnum(hash.alg)});
                                // Write digest length and data
                                var digest_len_buf: [4]u8 = undefined;
                                std.mem.writeInt(u32, &digest_len_buf, @intCast(hash.digest.len), .little);
                                _ = try file.write(&digest_len_buf);
                                _ = try file.write(hash.digest);
                                // Write optional salt
                                if (hash.salt) |salt| {
                                    _ = try file.write(&[1]u8{1}); // has salt
                                    var salt_len_buf: [4]u8 = undefined;
                                    std.mem.writeInt(u32, &salt_len_buf, @intCast(salt.len), .little);
                                    _ = try file.write(&salt_len_buf);
                                    _ = try file.write(salt);
                                } else {
                                    _ = try file.write(&[1]u8{0}); // no salt
                                }
                            },
                            .LanguageTag => |lt| {
                                // Write tag length and data
                                var tag_len_buf: [4]u8 = undefined;
                                std.mem.writeInt(u32, &tag_len_buf, @intCast(lt.tag.len), .little);
                                _ = try file.write(&tag_len_buf);
                                _ = try file.write(lt.tag);
                            },
                            .Temperature => |temp| {
                                // Write value_K (f64) and unit (u8)
                                var buf: [9]u8 = undefined;
                                std.mem.writeInt(u64, buf[0..8], @bitCast(temp.value_K), .little);
                                buf[8] = @intFromEnum(temp.unit_in);
                                _ = try file.write(&buf);
                            },
                            .Pressure => |pres| {
                                // Write value_Pa (f64) and unit (u8)
                                var buf: [9]u8 = undefined;
                                std.mem.writeInt(u64, buf[0..8], @bitCast(pres.value_Pa), .little);
                                buf[8] = @intFromEnum(pres.unit_in);
                                _ = try file.write(&buf);
                            },
                            .Date => |date| {
                                // Write days_since_epoch (i32)
                                var buf: [4]u8 = undefined;
                                std.mem.writeInt(i32, &buf, date.days_since_epoch, .little);
                                _ = try file.write(&buf);
                            },
                            .Time => |time| {
                                // Write micros_since_midnight (i64)
                                var buf: [8]u8 = undefined;
                                std.mem.writeInt(i64, &buf, time.micros_since_midnight, .little);
                                _ = try file.write(&buf);
                            },
                            .TimestampTZ => |ts| {
                                // Write micros_since_epoch_utc (i64)
                                var buf: [8]u8 = undefined;
                                std.mem.writeInt(i64, &buf, ts.micros_since_epoch_utc, .little);
                                _ = try file.write(&buf);
                            },
                            .List => |list| {
                                // Write list length
                                var len_buf: [4]u8 = undefined;
                                std.mem.writeInt(u32, &len_buf, @intCast(list.len), .little);
                                _ = try file.write(&len_buf);
                                // Note: Nested list serialization not supported yet
                            },
                            else => {
                                // Other types not yet supported
                            },
                        }
                    },
                    .Decimal => |d| {
                        // Write coefficient (i128 = 16 bytes) and scale (u8 = 1 byte)
                        var buf: [17]u8 = undefined;
                        std.mem.writeInt(i128, buf[0..16], d.coeff, .little);
                        buf[16] = d.scale;
                        _ = try file.write(&buf);
                    },
                }
            }

            // CANARY: REQ=REQ-MULTI-GRAPH-006; FEATURE="MultiGraphIsolation"; ASPECT=NodeGraphNamePersistence; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-24
            // Write graph_name length and graph_name for multi-graph isolation
            var graph_name_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &graph_name_len_buf, @intCast(node.graph_name.len), .little);
            _ = try file.write(&graph_name_len_buf);
            _ = try file.write(node.graph_name);
        }

        // Write each edge
        var edge_iter = self.edges.iterator();
        while (edge_iter.next()) |entry| {
            const edge = entry.value_ptr;
            // Write edge data
            var edge_buf: [24]u8 = undefined;
            std.mem.writeInt(u64, edge_buf[0..8], edge.id, .little);
            std.mem.writeInt(u64, edge_buf[8..16], edge.from_id, .little);
            std.mem.writeInt(u64, edge_buf[16..24], edge.to_id, .little);
            _ = try file.write(&edge_buf);

            // Write label
            var label_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &label_len_buf, @intCast(edge.label.len), .little);
            _ = try file.write(&label_len_buf);
            _ = try file.write(edge.label);

            // Write property count
            var prop_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &prop_count_buf, @intCast(edge.properties.count()), .little);
            _ = try file.write(&prop_count_buf);

            // Write each property
            var prop_iter = edge.properties.iterator();
            while (prop_iter.next()) |prop| {
                // Write key length and key
                var key_len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &key_len_buf, @intCast(prop.key_ptr.*.len), .little);
                _ = try file.write(&key_len_buf);
                _ = try file.write(prop.key_ptr.*);

                // Write value type and value
                const val_type: u8 = switch (prop.value_ptr.*) {
                    .String => 0,
                    .Int => 1,
                    .Float => 2,
                    .Bool => 3,
                    .Null => 4,
                    .ExtValue => 5,
                    .Decimal => 6,
                };
                _ = try file.write(&[1]u8{val_type});

                switch (prop.value_ptr.*) {
                    .String => |s| {
                        var len_buf2: [4]u8 = undefined;
                        std.mem.writeInt(u32, &len_buf2, @intCast(s.len), .little);
                        _ = try file.write(&len_buf2);
                        _ = try file.write(s);
                    },
                    .Int => |i| {
                        var int_buf: [8]u8 = undefined;
                        std.mem.writeInt(i64, &int_buf, i, .little);
                        _ = try file.write(&int_buf);
                    },
                    .Float => |f| {
                        var float_buf: [8]u8 = undefined;
                        std.mem.writeInt(u64, &float_buf, @bitCast(f), .little);
                        _ = try file.write(&float_buf);
                    },
                    .Bool => |b| {
                        _ = try file.write(&[1]u8{if (b) 1 else 0});
                    },
                    .Null => {
                        // Nothing to write for null
                    },
                    // CANARY: REQ=REQ-TYPE-SERIAL-002; FEATURE="TypeSerialization"; ASPECT=EdgeExtValue; STATUS=EXEMPT; OWNER=storage; UPDATED=2025-12-30
                    .ExtValue => |ext| {
                        // Write ExtValue sub-type tag and data (same as node serialization)
                        const ext_type: u8 = switch (ext) {
                            .Hash => 0x20,
                            .LanguageTag => 0x21,
                            .Temperature => 0x22,
                            .Pressure => 0x23,
                            .Date => 0x24,
                            .Time => 0x25,
                            .TimestampTZ => 0x26,
                            .List => 0x27,
                            .VectorF32 => 0x28,
                            .VectorI32 => 0x29,
                            else => 0xFF,
                        };
                        _ = try file.write(&[1]u8{ext_type});

                        switch (ext) {
                            .Date => |date| {
                                var buf: [4]u8 = undefined;
                                std.mem.writeInt(i32, &buf, date.days_since_epoch, .little);
                                _ = try file.write(&buf);
                            },
                            .Time => |time| {
                                var buf: [8]u8 = undefined;
                                std.mem.writeInt(i64, &buf, time.micros_since_midnight, .little);
                                _ = try file.write(&buf);
                            },
                            .TimestampTZ => |ts| {
                                var buf: [8]u8 = undefined;
                                std.mem.writeInt(i64, &buf, ts.micros_since_epoch_utc, .little);
                                _ = try file.write(&buf);
                            },
                            .Temperature => |temp| {
                                var buf: [9]u8 = undefined;
                                std.mem.writeInt(u64, buf[0..8], @bitCast(temp.value_K), .little);
                                buf[8] = @intFromEnum(temp.unit_in);
                                _ = try file.write(&buf);
                            },
                            .Pressure => |pres| {
                                var buf: [9]u8 = undefined;
                                std.mem.writeInt(u64, buf[0..8], @bitCast(pres.value_Pa), .little);
                                buf[8] = @intFromEnum(pres.unit_in);
                                _ = try file.write(&buf);
                            },
                            else => {},
                        }
                    },
                    .Decimal => |d| {
                        // Write coefficient (i128 = 16 bytes) and scale (u8 = 1 byte)
                        var buf: [17]u8 = undefined;
                        std.mem.writeInt(i128, buf[0..16], d.coeff, .little);
                        buf[16] = d.scale;
                        _ = try file.write(&buf);
                    },
                }
            }

            // CANARY: REQ=REQ-MULTI-GRAPH-007; FEATURE="MultiGraphIsolation"; ASPECT=EdgeGraphNamePersistence; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-24
            // Write graph_name length and graph_name for multi-graph isolation
            var graph_name_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &graph_name_len_buf, @intCast(edge.graph_name.len), .little);
            _ = try file.write(&graph_name_len_buf);
            _ = try file.write(edge.graph_name);
        }
    }

    fn loadFromFile(self: *GraphStore) !void {
        const file_path = try getPersistenceFilePath(self.allocator);
        defer self.allocator.free(file_path);
        const file = std.fs.cwd().openFile(file_path, .{}) catch return;
        defer file.close();

        // Read header
        var header: [32]u8 = undefined;
        const bytes_read = try file.read(&header);
        if (bytes_read < 32) return;

        self.next_node_id = std.mem.readInt(u64, header[0..8], .little);
        self.next_edge_id = std.mem.readInt(u64, header[8..16], .little);
        const node_count = std.mem.readInt(u64, header[16..24], .little);
        const edge_count = std.mem.readInt(u64, header[24..32], .little);

        // Read nodes
        var nodes_read: u64 = 0;
        while (nodes_read < node_count) : (nodes_read += 1) {
            // Read node ID
            var id_buf: [8]u8 = undefined;
            if ((try file.read(&id_buf)) < 8) break;
            const node_id = std.mem.readInt(u64, &id_buf, .little);

            // Read label count
            var label_count_buf: [4]u8 = undefined;
            if ((try file.read(&label_count_buf)) < 4) break;
            const label_count = std.mem.readInt(u32, &label_count_buf, .little);

            // Read labels
            var labels = try self.allocator.alloc([]const u8, label_count);
            for (0..label_count) |i| {
                var len_buf: [4]u8 = undefined;
                if ((try file.read(&len_buf)) < 4) break;
                const label_len = std.mem.readInt(u32, &len_buf, .little);

                const label_data = try self.allocator.alloc(u8, label_len);
                if ((try file.read(label_data)) < label_len) break;
                labels[i] = label_data;
            }

            // Read property count
            var prop_count_buf: [4]u8 = undefined;
            if ((try file.read(&prop_count_buf)) < 4) break;
            const prop_count = std.mem.readInt(u32, &prop_count_buf, .little);

            // Create node
            var node = Node{
                .id = node_id,
                .labels = labels,
                .properties = std.StringHashMap(PropertyValue).init(self.allocator),
            };

            // Read properties
            var props_read: u32 = 0;
            while (props_read < prop_count) : (props_read += 1) {
                // Read key
                var key_len_buf: [4]u8 = undefined;
                if ((try file.read(&key_len_buf)) < 4) break;
                const key_len = std.mem.readInt(u32, &key_len_buf, .little);

                const key_data = try self.allocator.alloc(u8, key_len);
                if ((try file.read(key_data)) < key_len) break;

                // Read value type
                var val_type_buf: [1]u8 = undefined;
                if ((try file.read(&val_type_buf)) < 1) break;
                const val_type = val_type_buf[0];

                // Read value based on type
                const value = switch (val_type) {
                    0 => blk: { // String
                        var len_buf: [4]u8 = undefined;
                        if ((try file.read(&len_buf)) < 4) break :blk PropertyValue{ .String = "" };
                        const str_len = std.mem.readInt(u32, &len_buf, .little);

                        const str_data = try self.allocator.alloc(u8, str_len);
                        if ((try file.read(str_data)) < str_len) break :blk PropertyValue{ .String = "" };
                        break :blk PropertyValue{ .String = str_data };
                    },
                    1 => blk: { // Int
                        var int_buf: [8]u8 = undefined;
                        if ((try file.read(&int_buf)) < 8) break :blk PropertyValue{ .Int = 0 };
                        break :blk PropertyValue{ .Int = std.mem.readInt(i64, &int_buf, .little) };
                    },
                    2 => blk: { // Float
                        var float_buf: [8]u8 = undefined;
                        if ((try file.read(&float_buf)) < 8) break :blk PropertyValue{ .Float = 0.0 };
                        const bits = std.mem.readInt(u64, &float_buf, .little);
                        break :blk PropertyValue{ .Float = @bitCast(bits) };
                    },
                    3 => blk: { // Bool
                        var bool_buf: [1]u8 = undefined;
                        if ((try file.read(&bool_buf)) < 1) break :blk PropertyValue{ .Bool = false };
                        break :blk PropertyValue{ .Bool = bool_buf[0] != 0 };
                    },
                    4 => PropertyValue{ .Null = {} }, // Null
                    5 => blk: { // ExtValue
                        const ext_eval = @import("eval_extended.zig");
                        const heap_mod = @import("storage/heap.zig");

                        // Read sub-type byte
                        var sub_type_buf: [1]u8 = undefined;
                        if ((try file.read(&sub_type_buf)) < 1) break :blk PropertyValue{ .Null = {} };
                        const sub_type = sub_type_buf[0];

                        const ext_value = switch (sub_type) {
                            0 => ext_eval.ExtValue{ .Null = {} },
                            1 => blk2: { // Int
                                var buf: [8]u8 = undefined;
                                if ((try file.read(&buf)) < 8) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const val = std.mem.readInt(i64, &buf, .little);
                                break :blk2 ext_eval.ExtValue{ .Int = val };
                            },
                            2 => blk2: { // Bool
                                var buf: [1]u8 = undefined;
                                if ((try file.read(&buf)) < 1) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                break :blk2 ext_eval.ExtValue{ .Bool = buf[0] != 0 };
                            },
                            3 => blk2: { // Str
                                var len_buf: [4]u8 = undefined;
                                if ((try file.read(&len_buf)) < 4) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const len = std.mem.readInt(u32, &len_buf, .little);
                                const str_data = try self.allocator.alloc(u8, len);
                                if ((try file.read(str_data)) < len) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                break :blk2 ext_eval.ExtValue{ .Str = str_data };
                            },
                            4 => blk2: { // Decimal
                                var buf: [17]u8 = undefined;
                                if ((try file.read(&buf)) < 17) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const coeff = std.mem.readInt(i128, buf[0..16], .little);
                                const scale = buf[16];
                                break :blk2 ext_eval.ExtValue{ .Decimal = .{ .coeff = coeff, .scale = scale } };
                            },
                            5 => blk2: { // IpAddr
                                var is_v6_buf: [1]u8 = undefined;
                                if ((try file.read(&is_v6_buf)) < 1) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const is_v6 = is_v6_buf[0] != 0;

                                if (is_v6) {
                                    var addr_buf: [16]u8 = undefined;
                                    if ((try file.read(&addr_buf)) < 16) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                    break :blk2 ext_eval.ExtValue{ .IpAddr = .{ .v6 = addr_buf } };
                                } else {
                                    var addr_buf: [4]u8 = undefined;
                                    if ((try file.read(&addr_buf)) < 4) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                    break :blk2 ext_eval.ExtValue{ .IpAddr = .{ .v4 = addr_buf } };
                                }
                            },
                            6 => blk2: { // Subnet
                                var is_v6_buf: [1]u8 = undefined;
                                if ((try file.read(&is_v6_buf)) < 1) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const is_v6 = is_v6_buf[0] != 0;

                                const addr = if (is_v6) blk3: {
                                    var addr_buf: [16]u8 = undefined;
                                    if ((try file.read(&addr_buf)) < 16) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                    break :blk3 heap_mod.IpAddr{ .v6 = addr_buf };
                                } else blk3: {
                                    var addr_buf: [4]u8 = undefined;
                                    if ((try file.read(&addr_buf)) < 4) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                    break :blk3 heap_mod.IpAddr{ .v4 = addr_buf };
                                };

                                var prefix_len_buf: [1]u8 = undefined;
                                if ((try file.read(&prefix_len_buf)) < 1) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const prefix_len = prefix_len_buf[0];

                                break :blk2 ext_eval.ExtValue{ .Subnet = .{ .addr = addr, .prefix_len = prefix_len } };
                            },
                            7 => blk2: { // Mac
                                var mac_buf: [6]u8 = undefined;
                                if ((try file.read(&mac_buf)) < 6) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                break :blk2 ext_eval.ExtValue{ .Mac = .{ .bytes = mac_buf } };
                            },
                            11 => blk2: { // LatLon
                                var buf: [16]u8 = undefined;
                                if ((try file.read(&buf)) < 16) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const lat_bits = std.mem.readInt(u64, buf[0..8], .little);
                                const lon_bits = std.mem.readInt(u64, buf[8..16], .little);
                                break :blk2 ext_eval.ExtValue{ .LatLon = .{ .lat = @bitCast(lat_bits), .lon = @bitCast(lon_bits) } };
                            },
                            12 => blk2: { // LatLonAlt
                                var buf: [25]u8 = undefined;
                                if ((try file.read(&buf)) < 25) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const lat_bits = std.mem.readInt(u64, buf[0..8], .little);
                                const lon_bits = std.mem.readInt(u64, buf[8..16], .little);
                                const alt_bits = std.mem.readInt(u64, buf[16..24], .little);
                                const ref = @as(heap_mod.AltRef, @enumFromInt(buf[24]));
                                break :blk2 ext_eval.ExtValue{ .LatLonAlt = .{ .lat = @bitCast(lat_bits), .lon = @bitCast(lon_bits), .alt = @bitCast(alt_bits), .ref = ref } };
                            },
                            13 => blk2: { // Geometry
                                var len_buf: [4]u8 = undefined;
                                if ((try file.read(&len_buf)) < 4) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const len = std.mem.readInt(u32, &len_buf, .little);
                                const wkb_data = try self.allocator.alloc(u8, len);
                                if ((try file.read(wkb_data)) < len) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                break :blk2 ext_eval.ExtValue{ .Geometry = .{ .wkb = wkb_data } };
                            },
                            9 => blk2: { // Currency
                                var code_buf: [3]u8 = undefined;
                                if ((try file.read(&code_buf)) < 3) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                break :blk2 ext_eval.ExtValue{ .Currency = .{ .code = code_buf } };
                            },
                            16 => blk2: { // VectorF32
                                // Read dimension (u16)
                                var dim_buf: [2]u8 = undefined;
                                if ((try file.read(&dim_buf)) < 2) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const dim = std.mem.readInt(u16, &dim_buf, .little);

                                // Allocate and read f32 data
                                const data = try self.allocator.alloc(f32, dim);
                                for (data) |*f| {
                                    var f_buf: [4]u8 = undefined;
                                    if ((try file.read(&f_buf)) < 4) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                    f.* = @bitCast(std.mem.readInt(u32, &f_buf, .little));
                                }

                                break :blk2 ext_eval.ExtValue{ .VectorF32 = .{ .dim = dim, .data = data } };
                            },
                            22 => blk2: { // Interval
                                var buf: [16]u8 = undefined;
                                if ((try file.read(&buf)) < 16) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const months = std.mem.readInt(i32, buf[0..4], .little);
                                const days = std.mem.readInt(i32, buf[4..8], .little);
                                const micros = std.mem.readInt(i64, buf[8..16], .little);
                                break :blk2 ext_eval.ExtValue{ .Interval = .{ .months = months, .days = days, .micros = micros } };
                            },
                            23 => blk2: { // UUID
                                var buf: [16]u8 = undefined;
                                if ((try file.read(&buf)) < 16) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                break :blk2 ext_eval.ExtValue{ .UUID = .{ .bytes = buf } };
                            },
                            24 => blk2: { // Url
                                // Scheme
                                var len_buf: [4]u8 = undefined;
                                if ((try file.read(&len_buf)) < 4) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const s_len = std.mem.readInt(u32, &len_buf, .little);
                                const scheme = try self.allocator.alloc(u8, s_len);
                                if ((try file.read(scheme)) < s_len) break :blk2 ext_eval.ExtValue{ .Null = {} };

                                // Host
                                if ((try file.read(&len_buf)) < 4) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const h_len = std.mem.readInt(u32, &len_buf, .little);
                                const host = try self.allocator.alloc(u8, h_len);
                                if ((try file.read(host)) < h_len) break :blk2 ext_eval.ExtValue{ .Null = {} };

                                // Port
                                var flag_buf: [1]u8 = undefined;
                                if ((try file.read(&flag_buf)) < 1) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                var port: ?u16 = null;
                                if (flag_buf[0] == 1) {
                                    var p_buf: [2]u8 = undefined;
                                    if ((try file.read(&p_buf)) < 2) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                    port = std.mem.readInt(u16, &p_buf, .little);
                                }

                                // Path
                                if ((try file.read(&len_buf)) < 4) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const p_len = std.mem.readInt(u32, &len_buf, .little);
                                const path = try self.allocator.alloc(u8, p_len);
                                if ((try file.read(path)) < p_len) break :blk2 ext_eval.ExtValue{ .Null = {} };

                                // Query
                                if ((try file.read(&flag_buf)) < 1) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                var query: ?[]const u8 = null;
                                if (flag_buf[0] == 1) {
                                    if ((try file.read(&len_buf)) < 4) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                    const q_len = std.mem.readInt(u32, &len_buf, .little);
                                    const q_data = try self.allocator.alloc(u8, q_len);
                                    if ((try file.read(q_data)) < q_len) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                    query = q_data;
                                }

                                // Fragment
                                if ((try file.read(&flag_buf)) < 1) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                var fragment: ?[]const u8 = null;
                                if (flag_buf[0] == 1) {
                                    if ((try file.read(&len_buf)) < 4) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                    const f_len = std.mem.readInt(u32, &len_buf, .little);
                                    const f_data = try self.allocator.alloc(u8, f_len);
                                    if ((try file.read(f_data)) < f_len) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                    fragment = f_data;
                                }

                                // Need to import Url type
                                const url_mod = @import("types/url.zig");
                                break :blk2 ext_eval.ExtValue{ .Url = url_mod.Url{ .scheme = scheme, .host = host, .port = port, .path = path, .query = query, .fragment = fragment } };
                            },
                            25 => blk2: { // Domain
                                var count_buf: [4]u8 = undefined;
                                if ((try file.read(&count_buf)) < 4) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const count = std.mem.readInt(u32, &count_buf, .little);
                                const domain_labels = try self.allocator.alloc([]const u8, count);
                                for (0..count) |i| {
                                    var len_buf: [4]u8 = undefined;
                                    if ((try file.read(&len_buf)) < 4) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                    const len = std.mem.readInt(u32, &len_buf, .little);
                                    const label = try self.allocator.alloc(u8, len);
                                    if ((try file.read(label)) < len) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                    domain_labels[i] = label;
                                }
                                const url_mod = @import("types/url.zig");
                                break :blk2 ext_eval.ExtValue{ .Domain = url_mod.Domain{ .labels = domain_labels } };
                            },
                            26 => blk2: { // Bytea
                                var len_buf: [4]u8 = undefined;
                                if ((try file.read(&len_buf)) < 4) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const len = std.mem.readInt(u32, &len_buf, .little);
                                const data = try self.allocator.alloc(u8, len);
                                if ((try file.read(data)) < len) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                break :blk2 ext_eval.ExtValue{ .Bytea = data };
                            },
                            27 => blk2: { // Json
                                var len_buf: [4]u8 = undefined;
                                if ((try file.read(&len_buf)) < 4) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const len = std.mem.readInt(u32, &len_buf, .little);
                                const data = try self.allocator.alloc(u8, len);
                                if ((try file.read(data)) < len) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                break :blk2 ext_eval.ExtValue{ .Json = data };
                            },
                            28 => blk2: { // Jsonb
                                var len_buf: [4]u8 = undefined;
                                if ((try file.read(&len_buf)) < 4) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const len = std.mem.readInt(u32, &len_buf, .little);
                                const data = try self.allocator.alloc(u8, len);
                                if ((try file.read(data)) < len) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const jsonb_mod = @import("types/jsonb.zig");
                                break :blk2 ext_eval.ExtValue{ .Jsonb = jsonb_mod.JsonbDocument{ .data = data, .allocator = self.allocator } };
                            },
                            29 => blk2: { // Xml
                                // Similar to Jsonb
                                var len_buf: [4]u8 = undefined;
                                if ((try file.read(&len_buf)) < 4) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const len = std.mem.readInt(u32, &len_buf, .little);
                                const data = try self.allocator.alloc(u8, len);
                                if ((try file.read(data)) < len) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const xml_mod = @import("types/xml.zig");
                                break :blk2 ext_eval.ExtValue{ .Xml = xml_mod.XmlDocument{ .data = data } };
                            },
                            30 => blk2: { // BitString
                                var bit_len_buf: [8]u8 = undefined;
                                if ((try file.read(&bit_len_buf)) < 8) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const bit_len = std.mem.readInt(u64, &bit_len_buf, .little);
                                var byte_len_buf: [4]u8 = undefined;
                                if ((try file.read(&byte_len_buf)) < 4) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const byte_len = std.mem.readInt(u32, &byte_len_buf, .little);
                                const bytes = try self.allocator.alloc(u8, byte_len);
                                if ((try file.read(bytes)) < byte_len) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const bitstring_mod = @import("types/bitstring.zig");
                                break :blk2 ext_eval.ExtValue{ .BitString = bitstring_mod.BitString{ .bytes = bytes, .bit_length = @intCast(bit_len) } };
                            },
                            31 => blk2: { // VarBit
                                var bit_len_buf: [8]u8 = undefined;
                                if ((try file.read(&bit_len_buf)) < 8) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const bit_len = std.mem.readInt(u64, &bit_len_buf, .little);
                                var byte_len_buf: [4]u8 = undefined;
                                if ((try file.read(&byte_len_buf)) < 4) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const byte_len = std.mem.readInt(u32, &byte_len_buf, .little);
                                const bytes = try self.allocator.alloc(u8, byte_len);
                                if ((try file.read(bytes)) < byte_len) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const bitstring_mod = @import("types/bitstring.zig");
                                break :blk2 ext_eval.ExtValue{ .VarBit = bitstring_mod.BitString{ .bytes = bytes, .bit_length = @intCast(bit_len) } };
                            },
                            32 => blk2: { // IntRange
                                var buf: [17]u8 = undefined;
                                if ((try file.read(&buf)) < 17) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const lower_val = std.mem.readInt(i64, buf[0..8], .little);
                                const upper_val = std.mem.readInt(i64, buf[8..16], .little);
                                const flags = buf[16];
                                const lower_inclusive = (flags & 1) != 0;
                                const upper_inclusive = (flags & 2) != 0;
                                const infinite_lower = (flags & 4) != 0;
                                const infinite_upper = (flags & 8) != 0;
                                const range_mod = @import("types/range.zig");
                                // Convert flags to Bounds enum
                                const bounds: range_mod.IntRange.Bounds = if (lower_inclusive and upper_inclusive)
                                    .inclusive_inclusive
                                else if (lower_inclusive and !upper_inclusive)
                                    .inclusive_exclusive
                                else if (!lower_inclusive and upper_inclusive)
                                    .exclusive_inclusive
                                else
                                    .exclusive_exclusive;
                                const lower: ?i32 = if (infinite_lower) null else @intCast(lower_val);
                                const upper: ?i32 = if (infinite_upper) null else @intCast(upper_val);
                                break :blk2 ext_eval.ExtValue{ .IntRange = range_mod.IntRange{ .lower = lower, .upper = upper, .bounds = bounds } };
                            },
                            33 => blk2: { // Enum
                                var buf: [8]u8 = undefined;
                                if ((try file.read(&buf)) < 8) break :blk2 ext_eval.ExtValue{ .Null = {} };
                                const type_id = std.mem.readInt(u32, buf[0..4], .little);
                                const value_ordinal = std.mem.readInt(u32, buf[4..8], .little);
                                break :blk2 ext_eval.ExtValue{ .Enum = .{ .type_id = type_id, .value_ordinal = value_ordinal } };
                            },
                            else => ext_eval.ExtValue{ .Null = {} },
                        };

                        break :blk PropertyValue{ .ExtValue = ext_value };
                    },
                    else => PropertyValue{ .String = "" },
                };

                try node.properties.put(key_data, value);
            }

            // CANARY: REQ=REQ-MULTI-GRAPH-006; FEATURE="MultiGraphIsolation"; ASPECT=NodeGraphNameLoad; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-24
            // Read graph_name for multi-graph isolation
            var graph_name_len_buf: [4]u8 = undefined;
            if ((try file.read(&graph_name_len_buf)) < 4) break;
            const graph_name_len = std.mem.readInt(u32, &graph_name_len_buf, .little);

            const graph_name_data = try self.allocator.alloc(u8, graph_name_len);
            if ((try file.read(graph_name_data)) < graph_name_len) {
                self.allocator.free(graph_name_data);
                break;
            }
            node.graph_name = graph_name_data;

            try self.nodes.put(node_id, node);
        }

        // Read edges
        var edges_read: u64 = 0;
        while (edges_read < edge_count) : (edges_read += 1) {
            // Read edge data
            var edge_buf: [24]u8 = undefined;
            if ((try file.read(&edge_buf)) < 24) break;
            const edge_id = std.mem.readInt(u64, edge_buf[0..8], .little);
            const from_id = std.mem.readInt(u64, edge_buf[8..16], .little);
            const to_id = std.mem.readInt(u64, edge_buf[16..24], .little);

            // Read label
            var label_len_buf: [4]u8 = undefined;
            if ((try file.read(&label_len_buf)) < 4) break;
            const label_len = std.mem.readInt(u32, &label_len_buf, .little);

            const label_data = try self.allocator.alloc(u8, label_len);
            if ((try file.read(label_data)) < label_len) break;

            // Read property count
            var prop_count_buf: [4]u8 = undefined;
            if ((try file.read(&prop_count_buf)) < 4) break;
            const prop_count = std.mem.readInt(u32, &prop_count_buf, .little);

            // Create edge with properties HashMap
            var properties = std.StringHashMap(PropertyValue).init(self.allocator);

            // Read each property
            var props_read: u32 = 0;
            while (props_read < prop_count) : (props_read += 1) {
                // Read key length and key
                var key_len_buf: [4]u8 = undefined;
                if ((try file.read(&key_len_buf)) < 4) break;
                const key_len = std.mem.readInt(u32, &key_len_buf, .little);

                const key_data = try self.allocator.alloc(u8, key_len);
                if ((try file.read(key_data)) < key_len) break;

                // Read value type
                var val_type_buf: [1]u8 = undefined;
                if ((try file.read(&val_type_buf)) < 1) break;
                const val_type = val_type_buf[0];

                // Read value based on type
                const value = switch (val_type) {
                    0 => blk: { // String
                        var len_buf: [4]u8 = undefined;
                        if ((try file.read(&len_buf)) < 4) break :blk PropertyValue{ .String = "" };
                        const str_len = std.mem.readInt(u32, &len_buf, .little);
                        const str_data = try self.allocator.alloc(u8, str_len);
                        if ((try file.read(str_data)) < str_len) break :blk PropertyValue{ .String = "" };
                        break :blk PropertyValue{ .String = str_data };
                    },
                    1 => blk: { // Int
                        var int_buf: [8]u8 = undefined;
                        if ((try file.read(&int_buf)) < 8) break :blk PropertyValue{ .Int = 0 };
                        break :blk PropertyValue{ .Int = std.mem.readInt(i64, &int_buf, .little) };
                    },
                    2 => blk: { // Float
                        var float_buf: [8]u8 = undefined;
                        if ((try file.read(&float_buf)) < 8) break :blk PropertyValue{ .Float = 0.0 };
                        const bits = std.mem.readInt(u64, &float_buf, .little);
                        break :blk PropertyValue{ .Float = @bitCast(bits) };
                    },
                    3 => blk: { // Bool
                        var bool_buf: [1]u8 = undefined;
                        if ((try file.read(&bool_buf)) < 1) break :blk PropertyValue{ .Bool = false };
                        break :blk PropertyValue{ .Bool = bool_buf[0] != 0 };
                    },
                    4 => PropertyValue{ .Null = {} }, // Null
                    5 => PropertyValue{ .Null = {} }, // ExtValue (skip for now)
                    else => PropertyValue{ .Null = {} },
                };

                try properties.put(key_data, value);
            }

            // CANARY: REQ=REQ-MULTI-GRAPH-007; FEATURE="MultiGraphIsolation"; ASPECT=EdgeGraphNameLoad; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-24
            // Read graph_name for multi-graph isolation
            var graph_name_len_buf: [4]u8 = undefined;
            if ((try file.read(&graph_name_len_buf)) < 4) break;
            const graph_name_len = std.mem.readInt(u32, &graph_name_len_buf, .little);

            const graph_name_data = try self.allocator.alloc(u8, graph_name_len);
            if ((try file.read(graph_name_data)) < graph_name_len) {
                self.allocator.free(graph_name_data);
                break;
            }

            const edge = Edge{
                .id = edge_id,
                .from_id = from_id,
                .to_id = to_id,
                .label = label_data,
                .properties = properties,
                .graph_name = graph_name_data,
            };

            try self.edges.put(edge_id, edge);
        }
    }

    // CANARY: REQ=REQ-TXN-UNDO-002; FEATURE="TransactionUndoLog"; ASPECT=NoSaveOperations; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
    // NoSave versions of mutation methods for transaction undo/redo operations
    // These methods modify the store without triggering auto-save to disk

    /// Delete a node without saving (used during rollback)
    pub fn deleteNodeNoSave(self: *GraphStore, node_id: u64) void {
        if (self.nodes.getPtr(node_id)) |node| {
            // Free labels
            for (node.labels) |label| {
                self.allocator.free(label);
            }
            self.allocator.free(node.labels);
            // Free graph_name
            if (node.graph_name.len > 0) {
                self.allocator.free(node.graph_name);
            }
            // Free properties
            var prop_iter = node.properties.iterator();
            while (prop_iter.next()) |prop_entry| {
                self.allocator.free(prop_entry.key_ptr.*);
                switch (prop_entry.value_ptr.*) {
                    .String => |s| self.allocator.free(s),
                    else => {},
                }
            }
            node.properties.deinit();
        }
        _ = self.nodes.remove(node_id);
    }

    /// Delete an edge without saving (used during rollback)
    pub fn deleteEdgeNoSave(self: *GraphStore, edge_id: u64) void {
        if (self.edges.getPtr(edge_id)) |edge| {
            // Free label
            self.allocator.free(edge.label);
            // Free graph_name
            if (edge.graph_name.len > 0) {
                self.allocator.free(edge.graph_name);
            }
            // Free properties
            var prop_iter = edge.properties.iterator();
            while (prop_iter.next()) |prop_entry| {
                self.allocator.free(prop_entry.key_ptr.*);
                switch (prop_entry.value_ptr.*) {
                    .String => |s| self.allocator.free(s),
                    else => {},
                }
            }
            edge.properties.deinit();
        }
        _ = self.edges.remove(edge_id);
    }

    /// Set a node property without saving (used during rollback)
    pub fn setNodePropertyNoSave(self: *GraphStore, node_id: u64, key: []const u8, value: PropertyValue) !void {
        if (self.nodes.getPtr(node_id)) |node| {
            const value_copy = switch (value) {
                .String => |s| PropertyValue{ .String = try self.allocator.dupe(u8, s) },
                else => value,
            };

            const result = try node.properties.getOrPut(key);
            if (!result.found_existing) {
                result.key_ptr.* = try self.allocator.dupe(u8, key);
            } else {
                switch (result.value_ptr.*) {
                    .String => |s| self.allocator.free(s),
                    else => {},
                }
            }
            result.value_ptr.* = value_copy;
        }
    }

    /// Remove a node property without saving (used during rollback)
    pub fn removeNodePropertyNoSave(self: *GraphStore, node_id: u64, key: []const u8) void {
        if (self.nodes.getPtr(node_id)) |node| {
            if (node.properties.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                switch (kv.value) {
                    .String => |s| self.allocator.free(s),
                    else => {},
                }
            }
        }
    }

    /// Set an edge property without saving (used during rollback)
    pub fn setEdgePropertyNoSave(self: *GraphStore, edge_id: u64, key: []const u8, value: PropertyValue) !void {
        if (self.edges.getPtr(edge_id)) |edge| {
            const value_copy = switch (value) {
                .String => |s| PropertyValue{ .String = try self.allocator.dupe(u8, s) },
                else => value,
            };

            const result = try edge.properties.getOrPut(key);
            if (!result.found_existing) {
                result.key_ptr.* = try self.allocator.dupe(u8, key);
            } else {
                switch (result.value_ptr.*) {
                    .String => |s| self.allocator.free(s),
                    else => {},
                }
            }
            result.value_ptr.* = value_copy;
        }
    }

    /// Remove an edge property without saving (used during rollback)
    pub fn removeEdgePropertyNoSave(self: *GraphStore, edge_id: u64, key: []const u8) void {
        if (self.edges.getPtr(edge_id)) |edge| {
            if (edge.properties.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                switch (kv.value) {
                    .String => |s| self.allocator.free(s),
                    else => {},
                }
            }
        }
    }

    /// Restore a deleted node without saving (used during rollback)
    pub fn restoreNodeNoSave(self: *GraphStore, node_id: u64, labels: []const []const u8, graph_name: []const u8) !void {
        // Copy labels
        const labels_copy = try self.allocator.alloc([]const u8, labels.len);
        for (labels, 0..) |label, i| {
            labels_copy[i] = try self.allocator.dupe(u8, label);
        }

        const graph_name_copy = try self.allocator.dupe(u8, graph_name);

        const node = Node{
            .id = node_id,
            .labels = labels_copy,
            .properties = std.StringHashMap(PropertyValue).init(self.allocator),
            .graph_name = graph_name_copy,
        };

        try self.nodes.put(node_id, node);
    }

    /// Restore a deleted edge without saving (used during rollback)
    pub fn restoreEdgeNoSave(self: *GraphStore, edge_id: u64, from_id: u64, to_id: u64, label: []const u8, graph_name: []const u8) !void {
        const label_copy = try self.allocator.dupe(u8, label);
        const graph_name_copy = try self.allocator.dupe(u8, graph_name);

        const edge = Edge{
            .id = edge_id,
            .from_id = from_id,
            .to_id = to_id,
            .label = label_copy,
            .properties = std.StringHashMap(PropertyValue).init(self.allocator),
            .graph_name = graph_name_copy,
        };

        try self.edges.put(edge_id, edge);
    }

    /// Add a label to a node without saving (used during rollback)
    pub fn addNodeLabelNoSave(self: *GraphStore, node_id: u64, label: []const u8) !void {
        if (self.nodes.getPtr(node_id)) |node| {
            // Check if label already exists
            for (node.labels) |existing_label| {
                if (std.mem.eql(u8, existing_label, label)) {
                    return;
                }
            }

            const label_copy = try self.allocator.dupe(u8, label);
            const new_labels = try self.allocator.alloc([]const u8, node.labels.len + 1);
            @memcpy(new_labels[0..node.labels.len], node.labels);
            new_labels[node.labels.len] = label_copy;

            if (node.labels.len > 0) {
                self.allocator.free(node.labels);
            }

            node.labels = new_labels;
        }
    }

    /// Remove a label from a node without saving (used during rollback)
    pub fn removeNodeLabelNoSave(self: *GraphStore, node_id: u64, label: []const u8) !void {
        if (self.nodes.getPtr(node_id)) |node| {
            var found_index: ?usize = null;
            for (node.labels, 0..) |existing_label, i| {
                if (std.mem.eql(u8, existing_label, label)) {
                    found_index = i;
                    break;
                }
            }

            if (found_index) |index| {
                // Free the label being removed
                self.allocator.free(node.labels[index]);

                const new_labels = try self.allocator.alloc([]const u8, node.labels.len - 1);
                var new_index: usize = 0;
                for (node.labels, 0..) |existing_label, i| {
                    if (i != index) {
                        new_labels[new_index] = existing_label;
                        new_index += 1;
                    }
                }

                if (node.labels.len > 0) {
                    self.allocator.free(node.labels);
                }

                node.labels = new_labels;
            }
        }
    }
};

// Global instance that persists across queries
var global_store: ?GraphStore = null;
var global_arena: ?std.heap.ArenaAllocator = null;
var initialized = false;
var last_data_dir: ?[]u8 = null;

/// P2-3: Global allocator for persistent graph store data (better than page_allocator)
var global_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var global_allocator_init = false;

pub fn getGlobalStore(allocator: std.mem.Allocator) *GraphStore {
    // P2-3: Initialize global allocator on first use
    if (!global_allocator_init) {
        global_allocator_init = true;
    }

    // Check if GEODE_DATA_DIR has changed since last initialization
    const current_data_dir = std.process.getEnvVarOwned(allocator, "GEODE_DATA_DIR") catch null;
    defer if (current_data_dir) |dir| allocator.free(dir);

    var needs_reinit = false;
    if (current_data_dir) |curr_dir| {
        if (last_data_dir) |last_dir| {
            if (!std.mem.eql(u8, curr_dir, last_dir)) {
                needs_reinit = true;
            }
        } else {
            needs_reinit = true;
        }
    } else if (last_data_dir != null) {
        needs_reinit = true;
    }

    // Reinitialize if data dir changed or not initialized yet
    if (!initialized or needs_reinit) {
        // Clean up previous instance if it exists
        if (initialized and global_store != null) {
            global_store.?.clearNodes(); // Clear all data before reinitializing
            global_store.?.deinit();
            global_store = null;
            if (global_arena != null) {
                global_arena.?.deinit();
                global_arena = null;
            }
        }

        // Update last_data_dir
        // P2-3: Use global allocator instead of page_allocator
        if (last_data_dir) |dir| {
            global_gpa.allocator().free(dir);
        }
        if (current_data_dir) |curr_dir| {
            last_data_dir = global_gpa.allocator().dupe(u8, curr_dir) catch null;
        } else {
            last_data_dir = null;
        }

        // Use a persistent arena allocator for the global store
        // P2-3: Use global allocator instead of page_allocator
        global_arena = std.heap.ArenaAllocator.init(global_gpa.allocator());
        global_store = GraphStore.init(global_arena.?.allocator());
        // Try to load existing data from the new location
        global_store.?.loadFromFile() catch |err| {
            log.warn("Failed to load graph store from file (starting fresh)", &.{
                Attr.err("error", err),
            });
        };
        initialized = true;
    }
    return &global_store.?;
}

pub fn deinitGlobalStore() void {
    if (initialized and global_store != null) {
        global_store.?.deinit();
        global_store = null;
        if (global_arena != null) {
            global_arena.?.deinit();
            global_arena = null;
        }
        initialized = false;
    }
}
