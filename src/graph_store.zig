const std = @import("std");
const fle_integration = @import("fle_integration.zig");
const uuid = @import("uuid.zig");

// CANARY: REQ=REQ-TDE-GRAPHSTORE-001; FEATURE="TDEFileLevelEncryption"; ASPECT=GraphStorePersistence; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
const tde = @import("storage/tde_file_encryption.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Storage; STATUS=EXEMPT; OWNER=storage; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("storage");
const Attr = logging.Attr;
const crc = std.hash.crc;

const PERSIST_VERSION: u32 = 3;
const HEADER_LEN: usize = 60; // magic(8) + version(4) + reserved(4) + ids/counts(40) + checksum(4)

var last_checksum_error: bool = false;

pub fn lastLoadHadChecksumError() bool {
    return last_checksum_error;
}

/// Generate a time-based unique 64-bit ID (UUIDv7-compatible lower 64 bits)
/// Structure: 48-bit timestamp (ms) | 16-bit counter/random
/// This provides time-sortable, unique IDs without changing the NodeId type
fn generateTimeBasedId() u64 {
    // Use atomic counter to ensure uniqueness even when called within same millisecond.
    // Use u32 for the counter to ensure 32-bit ARM compatibility (native atomic support).
    // NOTE: The previous implementation XOR'd the counter with a non-thread-safe PRNG
    // (std.Random.DefaultPrng), which caused data races under concurrent test execution
    // and could produce duplicate IDs. The counter alone guarantees uniqueness for up to
    // 65536 IDs per millisecond, which is sufficient for all workloads.
    const State = struct {
        var counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
    };

    const timestamp_ms: u64 = @intCast(std.time.milliTimestamp());
    const counter_val = State.counter.fetchAdd(1, .monotonic);
    // Combine: 48-bit timestamp | 16-bit counter (unique within same millisecond)
    return (timestamp_ms << 16) | @as(u64, @as(u16, @truncate(counter_val)));
}

// Field-Level Encryption Storage Hooks
// CANARY: REQ=REQ-FLE-STORAGE-001; FEATURE="FieldLevelEncryption"; ASPECT=STORAGE; STATUS=TESTED; TEST=tests/test_tde_kms_integration.zig; OWNER=security; UPDATED=2026-01-15

// Simple graph store with file-based persistence for testing
// Real implementation would use proper storage engine

// Global data directory override (set via API, takes precedence over env var)
// Use a fixed-size buffer to avoid allocator issues across module boundaries
var g_override_data_dir_buf: [512]u8 = undefined;
var g_override_data_dir_len: usize = 0;
var g_override_data_dir_set: bool = false;

/// Set the data directory override (takes precedence over GEODE_DATA_DIR env var)
/// Pass null to clear the override and revert to env var behavior
pub fn setDataDirOverride(allocator: std.mem.Allocator, dir: ?[]const u8) void {
    _ = allocator; // Not needed with fixed buffer
    if (dir) |path| {
        const copy_len = @min(path.len, g_override_data_dir_buf.len);
        @memcpy(g_override_data_dir_buf[0..copy_len], path[0..copy_len]);
        g_override_data_dir_len = copy_len;
        g_override_data_dir_set = true;
    } else {
        g_override_data_dir_len = 0;
        g_override_data_dir_set = false;
    }
}

/// Get the current data directory override (or null if using env var)
pub fn getDataDirOverride() ?[]const u8 {
    if (g_override_data_dir_set and g_override_data_dir_len > 0) {
        return g_override_data_dir_buf[0..g_override_data_dir_len];
    }
    return null;
}

/// Get the persistence file path, respecting GEODE_DATA_DIR environment variable
/// Returns an allocated path that must be freed by the caller
// CANARY: REQ=REQ-BINARY-PERSIST-PATH-001; FEATURE="BinaryPersistence"; ASPECT=PathResolution; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-02
pub fn getPersistenceFilePath(allocator: std.mem.Allocator) ![]u8 {
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

    // Check for data directory override first (set via API), then env var
    const data_dir_owned: ?[]u8 = if (getDataDirOverride()) |override|
        try allocator.dupe(u8, override)
    else
        std.process.getEnvVarOwned(allocator, "GEODE_DATA_DIR") catch |err| {
            // If not set or error, use platform-specific temp directory
            if (err == error.EnvironmentVariableNotFound) {
                return try getFallbackPath(allocator);
            }
            return err;
        };

    const data_dir = data_dir_owned orelse return try getFallbackPath(allocator);
    defer allocator.free(data_dir);

    // Try to create the directory - if it fails, fall back to temp directory
    std.fs.cwd().makePath(data_dir) catch |err| {
        log.warn("Failed to create graph store directory, using temp directory instead", &.{
            Attr.string("data_dir", data_dir),
            Attr.string("error", @errorName(err)),
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
            Attr.string("error", @errorName(err)),
        });
        return try getFallbackPath(allocator);
    };
    test_file.close();
    std.fs.cwd().deleteFile(test_path) catch {};

    // Directory is valid and writable, use it
    return try std.fmt.allocPrint(allocator, "{s}{s}graph_store.dat", .{ data_dir, sep });
}

/// Default graph name used when no graph is selected
pub const DEFAULT_GRAPH_NAME = "default";

pub const Node = struct {
    id: u64,
    labels: [][]const u8,
    properties: std.StringHashMap(PropertyValue),
    // CANARY: REQ=REQ-MULTI-GRAPH-003; FEATURE="MultiGraphIsolation"; ASPECT=NodeGraphTag; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
    // Graph name this node belongs to - enables per-graph data isolation
    graph_name: []const u8 = DEFAULT_GRAPH_NAME,
};

pub const Edge = struct {
    id: u64,
    from_id: u64,
    to_id: u64,
    label: []const u8,
    properties: std.StringHashMap(PropertyValue),
    // CANARY: REQ=REQ-MULTI-GRAPH-003; FEATURE="MultiGraphIsolation"; ASPECT=EdgeGraphTag; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
    // Graph name this edge belongs to - enables per-graph data isolation
    graph_name: []const u8 = DEFAULT_GRAPH_NAME,
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

// CANARY: REQ=REQ-GQL-PATH-UTIL-001; FEATURE="GraphStorePathOps"; ASPECT=Traversal; STATUS=IMPL; TEST=tests/integration/test_variable_paths.zig; OWNER=engine; UPDATED=2026-02-03
pub const PathOptions = struct {
    min_length: ?u32 = null,
    max_length: ?u32 = null,
    exact_length: ?u32 = null,
};

pub const ExpandOptions = struct {
    max_depth: u32 = 5,
};

pub const Path = struct {
    nodes: []u64,
    edges: []u64,
};

pub const PathFilter = struct {
    node_predicate: ?*const fn (*const Node) bool = null,
    edge_predicate: ?*const fn (*const Edge) bool = null,
};

fn copyPropertyValue(self: *GraphStore, value: PropertyValue) !PropertyValue {
    return switch (value) {
        .String => |s| PropertyValue{ .String = try self.allocator.dupe(u8, s) },
        .ExtValue => |ext| PropertyValue{ .ExtValue = try copyExtValue(self, ext) },
        else => value,
    };
}

fn freePropertyValue(self: *GraphStore, value: PropertyValue) void {
    switch (value) {
        .String => |s| self.allocator.free(s),
        .ExtValue => |ext| freeExtValue(self, ext),
        else => {},
    }
}

fn copyExtValue(self: *GraphStore, value: @import("eval_extended.zig").ExtValue) !@import("eval_extended.zig").ExtValue {
    const ext_eval = @import("eval_extended.zig");
    const bitstring_mod = @import("types/bitstring.zig");
    const jsonb_mod = @import("types/jsonb.zig");
    const xml_mod = @import("types/xml.zig");
    const url_mod = @import("types/url.zig");
    const heap_mod = @import("storage/heap.zig");

    return switch (value) {
        .Null => ext_eval.ExtValue{ .Null = {} },
        .Int => |v| ext_eval.ExtValue{ .Int = v },
        .Bool => |v| ext_eval.ExtValue{ .Bool = v },
        .Decimal => |v| ext_eval.ExtValue{ .Decimal = v },
        .IpAddr => |v| ext_eval.ExtValue{ .IpAddr = v },
        .Subnet => |v| ext_eval.ExtValue{ .Subnet = v },
        .Mac => |v| ext_eval.ExtValue{ .Mac = v },
        .Currency => |v| ext_eval.ExtValue{ .Currency = v },
        .LatLon => |v| ext_eval.ExtValue{ .LatLon = v },
        .LatLonAlt => |v| ext_eval.ExtValue{ .LatLonAlt = v },
        .Temperature => |v| ext_eval.ExtValue{ .Temperature = v },
        .Pressure => |v| ext_eval.ExtValue{ .Pressure = v },
        .Date => |v| ext_eval.ExtValue{ .Date = v },
        .Time => |v| ext_eval.ExtValue{ .Time = v },
        .TimestampTZ => |v| ext_eval.ExtValue{ .TimestampTZ = v },
        .Interval => |v| ext_eval.ExtValue{ .Interval = v },
        .UUID => |v| ext_eval.ExtValue{ .UUID = v },
        .Enum => |v| ext_eval.ExtValue{ .Enum = v },
        .IntRange => |v| ext_eval.ExtValue{ .IntRange = v },
        .Str => |s| ext_eval.ExtValue{ .Str = try self.allocator.dupe(u8, s) },
        .Bytea => |b| ext_eval.ExtValue{ .Bytea = try self.allocator.dupe(u8, b) },
        .Json => |j| ext_eval.ExtValue{ .Json = try self.allocator.dupe(u8, j) },
        .Geometry => |g| ext_eval.ExtValue{ .Geometry = .{ .wkb = try self.allocator.dupe(u8, g.wkb) } },
        .LanguageTag => |lt| ext_eval.ExtValue{ .LanguageTag = .{ .tag = try self.allocator.dupe(u8, lt.tag) } },
        .VectorF32 => |vec| ext_eval.ExtValue{ .VectorF32 = .{
            .dim = vec.dim,
            .data = try self.allocator.dupe(f32, vec.data),
        } },
        .VectorI32 => |vec| ext_eval.ExtValue{ .VectorI32 = .{
            .dim = vec.dim,
            .data = try self.allocator.dupe(i32, vec.data),
        } },
        .Hash => |h| ext_eval.ExtValue{ .Hash = heap_mod.Hash{
            .alg = h.alg,
            .digest = try self.allocator.dupe(u8, h.digest),
            .salt = if (h.salt) |s| try self.allocator.dupe(u8, s) else null,
            .params = h.params,
        } },
        .Url => |u| ext_eval.ExtValue{ .Url = url_mod.Url{
            .scheme = try self.allocator.dupe(u8, u.scheme),
            .host = try self.allocator.dupe(u8, u.host),
            .port = u.port,
            .path = try self.allocator.dupe(u8, u.path),
            .query = if (u.query) |q| try self.allocator.dupe(u8, q) else null,
            .fragment = if (u.fragment) |f| try self.allocator.dupe(u8, f) else null,
        } },
        .Domain => |d| blk: {
            const labels_copy = try self.allocator.alloc([]const u8, d.labels.len);
            for (d.labels, 0..) |label, i| {
                labels_copy[i] = try self.allocator.dupe(u8, label);
            }
            break :blk ext_eval.ExtValue{ .Domain = url_mod.Domain{ .labels = labels_copy } };
        },
        .Jsonb => |doc| ext_eval.ExtValue{ .Jsonb = jsonb_mod.JsonbDocument{
            .data = try self.allocator.dupe(u8, doc.data),
            .allocator = self.allocator,
        } },
        .Xml => |doc| ext_eval.ExtValue{ .Xml = xml_mod.XmlDocument{
            .data = try self.allocator.dupe(u8, doc.data),
        } },
        .BitString => |bs| ext_eval.ExtValue{ .BitString = bitstring_mod.BitString{
            .bytes = try self.allocator.dupe(u8, bs.bytes),
            .bit_length = bs.bit_length,
        } },
        .VarBit => |bs| ext_eval.ExtValue{ .VarBit = bitstring_mod.BitString{
            .bytes = try self.allocator.dupe(u8, bs.bytes),
            .bit_length = bs.bit_length,
        } },
        .List => |list| blk: {
            const copied = try self.allocator.alloc(ext_eval.ExtValue, list.len);
            for (list, 0..) |item, i| {
                copied[i] = try copyExtValue(self, item);
            }
            break :blk ext_eval.ExtValue{ .List = copied };
        },
    };
}

fn freeExtValue(self: *GraphStore, value: @import("eval_extended.zig").ExtValue) void {
    const bitstring_mod = @import("types/bitstring.zig");
    const jsonb_mod = @import("types/jsonb.zig");
    const url_mod = @import("types/url.zig");

    switch (value) {
        .Str => |s| self.allocator.free(s),
        .Bytea => |b| self.allocator.free(b),
        .Json => |j| self.allocator.free(j),
        .Geometry => |g| self.allocator.free(g.wkb),
        .LanguageTag => |lt| self.allocator.free(lt.tag),
        .VectorF32 => |vec| self.allocator.free(vec.data),
        .VectorI32 => |vec| self.allocator.free(vec.data),
        .Hash => |h| {
            self.allocator.free(h.digest);
            if (h.salt) |s| self.allocator.free(s);
        },
        .Url => |u| {
            self.allocator.free(u.scheme);
            self.allocator.free(u.host);
            self.allocator.free(u.path);
            if (u.query) |q| self.allocator.free(q);
            if (u.fragment) |f| self.allocator.free(f);
        },
        .Domain => |d| url_mod.Domain.deinit(d, self.allocator),
        .Jsonb => |doc| jsonb_mod.JsonbDocument.deinit(doc),
        .Xml => |doc| self.allocator.free(doc.data),
        .BitString => |bs| bitstring_mod.BitString.deinit(bs, self.allocator),
        .VarBit => |bs| bitstring_mod.BitString.deinit(bs, self.allocator),
        .List => |list| {
            for (list) |item| {
                freeExtValue(self, item);
            }
            self.allocator.free(list);
        },
        else => {},
    }
}

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
    // CANARY: REQ=REQ-MULTI-GRAPH-008; FEATURE="GraphRegistry"; ASPECT=GraphNames; STATUS=IMPL; OWNER=storage; UPDATED=2026-02-03
    // Track known graph names (including empty graphs)
    graphs: std.StringHashMap(void),
    // CANARY: REQ=REQ-PERF-LABEL-INDEX-001; FEATURE="LabelBasedIndex"; ASPECT=NodeLookup; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-28
    // Issue #391: Label-based index for O(1) node lookups instead of O(n) full table scans
    // Maps "graph_name:label" composite key to list of node IDs
    label_index: std.StringHashMap(std.ArrayList(u64)),
    // CANARY: REQ=REQ-PERF-EDGE-ADJ-001; FEATURE="EdgeAdjacencyIndex"; ASPECT=EdgeLookup; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-28
    // Issue #392: Adjacency lists for fast edge lookups during DELETE DETACH
    outgoing_edges: std.AutoHashMap(u64, std.ArrayList(u64)), // from_node_id -> edge_ids
    incoming_edges: std.AutoHashMap(u64, std.ArrayList(u64)), // to_node_id -> edge_ids
    /// Optional CSR adjacency for fast traversal (if built elsewhere)
    csr: ?*const anyopaque = null,
    // CANARY: REQ=REQ-BINARY-PERSIST-DIRTY-001; FEATURE="BinaryPersistence"; ASPECT=DirtyTracking; STATUS=IMPL; OWNER=storage; UPDATED=2026-02-02
    // Track if store has unsaved changes - avoids O(n²) persistence during batch operations
    dirty: bool = false,

    /// Initialize GraphStore with default tenant
    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!GraphStore {
        return initWithTenant(allocator, "default", "default");
    }

    /// Initialize GraphStore with specific tenant and schema
    pub fn initWithTenant(allocator: std.mem.Allocator, tenant_id: []const u8, schema_name: []const u8) error{OutOfMemory}!GraphStore {
        var store = GraphStore{
            .allocator = allocator,
            .nodes = std.AutoHashMap(u64, Node).init(allocator),
            .edges = std.AutoHashMap(u64, Edge).init(allocator),
            .next_node_id = 1,
            .next_edge_id = 1,
            .tenant_id = tenant_id,
            .schema_name = schema_name,
            .graphs = std.StringHashMap(void).init(allocator),
            // Issue #391, #392: Initialize performance optimization indexes
            .label_index = std.StringHashMap(std.ArrayList(u64)).init(allocator),
            .outgoing_edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
            .incoming_edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
        };
        // Register default graph name
        const default_name = try allocator.dupe(u8, "default");
        try store.graphs.put(default_name, {});
        return store;
    }

    /// Pre-allocate storage for nodes/edges to avoid rehash churn during bulk loads.
    pub fn reserve(self: *GraphStore, node_capacity: usize, edge_capacity: usize) !void {
        try self.nodes.ensureTotalCapacity(@intCast(node_capacity));
        try self.edges.ensureTotalCapacity(@intCast(edge_capacity));
        try self.outgoing_edges.ensureTotalCapacity(@intCast(edge_capacity));
        try self.incoming_edges.ensureTotalCapacity(@intCast(edge_capacity));
        try self.label_index.ensureTotalCapacity(@intCast(node_capacity));
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

        // Clean up graph registry
        var graph_iter = self.graphs.iterator();
        while (graph_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.graphs.deinit();

        // Issue #391: Clean up label index
        var label_iter = self.label_index.iterator();
        while (label_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.label_index.deinit();

        // Issue #392: Clean up adjacency indexes
        var out_iter = self.outgoing_edges.iterator();
        while (out_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.outgoing_edges.deinit();

        var in_iter = self.incoming_edges.iterator();
        while (in_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.incoming_edges.deinit();
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
                // Free property values (including ExtValue)
                freePropertyValue(self, prop_entry.value_ptr.*);
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
                // Free property values (including ExtValue)
                freePropertyValue(self, prop_entry.value_ptr.*);
            }
            entry.value_ptr.properties.deinit();
        }
        self.edges.clearRetainingCapacity();

        self.next_node_id = 1;
        self.next_edge_id = 1;

        // Reset graph registry to default
        var graph_iter = self.graphs.iterator();
        while (graph_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.graphs.deinit();
        self.graphs = std.StringHashMap(void).init(self.allocator);
        const default_name = self.allocator.dupe(u8, "default") catch @panic("OOM: failed to allocate default graph name during clearNodes");
        self.graphs.put(default_name, {}) catch @panic("OOM: failed to register default graph during clearNodes");

        // Reset label index
        var label_iter = self.label_index.iterator();
        while (label_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.label_index.deinit();
        self.label_index = std.StringHashMap(std.ArrayList(u64)).init(self.allocator);

        // Reset adjacency indexes
        var out_iter = self.outgoing_edges.iterator();
        while (out_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.outgoing_edges.deinit();
        self.outgoing_edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(self.allocator);

        var in_iter = self.incoming_edges.iterator();
        while (in_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.incoming_edges.deinit();
        self.incoming_edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(self.allocator);
    }

    /// Clear the graph registry (removes all graph names, for test isolation)
    pub fn clearGraphRegistry(self: *GraphStore) void {
        var graph_iter = self.graphs.iterator();
        while (graph_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.graphs.deinit();
        self.graphs = std.StringHashMap(void).init(self.allocator);
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
            self.deleteNodeNoSave(node_id);
        }

        // Remove any remaining edges tagged with this graph (defensive cleanup)
        var edges_to_remove = std.ArrayList(u64).initCapacity(self.allocator, 0) catch return;
        defer edges_to_remove.deinit(self.allocator);

        var edge_iter = self.edges.iterator();
        while (edge_iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.graph_name, graph_name)) {
                edges_to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (edges_to_remove.items) |edge_id| {
            self.deleteEdgeNoSave(edge_id);
        }
    }

    // CANARY: REQ=REQ-MULTI-GRAPH-008; FEATURE="GraphRegistry"; ASPECT=GraphHelpers; STATUS=IMPL; OWNER=storage; UPDATED=2026-02-03
    fn ensureGraph(self: *GraphStore, graph_name: []const u8) !void {
        try self.ensureGraphNoDirty(graph_name);
        self.dirty = true;
    }

    fn ensureGraphNoDirty(self: *GraphStore, graph_name: []const u8) !void {
        if (self.graphs.contains(graph_name)) return;
        const name_copy = try self.allocator.dupe(u8, graph_name);
        try self.graphs.put(name_copy, {});
    }

    pub fn graphExists(self: *const GraphStore, graph_name: []const u8) bool {
        return self.graphs.contains(graph_name);
    }

    pub fn listGraphNames(self: *const GraphStore, allocator: std.mem.Allocator) ![]const []const u8 {
        var names = try allocator.alloc([]const u8, self.graphs.count());
        var i: usize = 0;
        var it = self.graphs.iterator();
        while (it.next()) |entry| {
            names[i] = try allocator.dupe(u8, entry.key_ptr.*);
            i += 1;
        }
        return names;
    }

    pub fn createGraph(self: *GraphStore, graph_name: []const u8) !void {
        if (self.graphs.contains(graph_name)) {
            return error.GraphAlreadyExists;
        }
        const name_copy = try self.allocator.dupe(u8, graph_name);
        try self.graphs.put(name_copy, {});
        self.dirty = true;
    }

    pub fn dropGraph(self: *GraphStore, graph_name: []const u8) !void {
        if (std.mem.eql(u8, graph_name, "default")) {
            return error.CannotDropDefaultGraph;
        }
        if (!self.graphs.contains(graph_name)) {
            return error.GraphNotFound;
        }
        self.clearNodesForGraph(graph_name);
        if (self.graphs.fetchRemove(graph_name)) |kv| {
            self.allocator.free(kv.key);
        }
        self.dirty = true;
    }

    // CANARY: REQ=REQ-MULTI-GRAPH-004; FEATURE="MultiGraphIsolation"; ASPECT=CreateNode; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
    // Create node with optional graph name for per-graph data isolation
    pub fn createNodeWithGraph(self: *GraphStore, labels: [][]const u8, graph_name: []const u8) !u64 {
        try self.ensureGraph(graph_name);
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

        // CANARY: REQ=REQ-PERF-LABEL-INDEX-002; FEATURE="LabelBasedIndex"; ASPECT=IndexMaintenance; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-28
        // Issue #391: Maintain label index for fast MERGE lookups
        for (labels) |label| {
            try self.addToLabelIndex(graph_name, label, id);
        }

        // CANARY: REQ=REQ-BINARY-PERSIST-NODE-002; FEATURE="BinaryPersistence"; ASPECT=DirtyTracking; STATUS=IMPL; OWNER=storage; UPDATED=2026-02-02
        // Mark store as dirty - persistence happens at query completion, not per-node
        // This avoids O(n²) serialization overhead during batch operations
        self.dirty = true;
        log.debug("Node created, dirty=true", &.{
            Attr.int("node_id", @intCast(id)),
            Attr.int("total_nodes", @intCast(self.nodes.count())),
        });

        // WAL notification: CreateNode
        notifyMutation(.create_node, id, 0, 0, if (labels.len > 0) labels[0] else null, null, null, graph_name);

        return id;
    }

    fn createNodeWithIdInternal(self: *GraphStore, node_id: u64, labels: [][]const u8, graph_name: []const u8, mark_dirty: bool) !void {
        try self.ensureGraph(graph_name);
        if (self.nodes.contains(node_id)) return error.NodeAlreadyExists;

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

        for (labels) |label| {
            try self.addToLabelIndex(graph_name, label, node_id);
        }

        if (node_id >= self.next_node_id) {
            self.next_node_id = node_id + 1;
        }

        if (mark_dirty) {
            self.dirty = true;
        }
    }

    /// Create a node with a specified ID (used for replication/2PC).
    pub fn createNodeWithId(self: *GraphStore, node_id: u64, labels: [][]const u8, graph_name: []const u8) !void {
        return self.createNodeWithIdInternal(node_id, labels, graph_name, true);
    }

    /// Create a node with a specified ID without marking dirty (used for rollback).
    pub fn createNodeWithIdNoSave(self: *GraphStore, node_id: u64, labels: [][]const u8, graph_name: []const u8) !void {
        return self.createNodeWithIdInternal(node_id, labels, graph_name, false);
    }

    // Issue #391: Helper to add node to label index
    // Issue #451: Use stack-allocated bufPrint to probe for existing key before heap alloc
    fn addToLabelIndex(self: *GraphStore, graph_name: []const u8, label: []const u8, node_id: u64) !void {
        // Probe with stack-allocated key first to avoid heap alloc when key exists
        var buf: [512]u8 = undefined;
        const probe_key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ graph_name, label }) catch {
            // Key too long for stack buffer — fall back to heap alloc
            const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, label });
            const result = try self.label_index.getOrPut(key);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(u64).empty;
            } else {
                self.allocator.free(key);
            }
            try result.value_ptr.append(self.allocator, node_id);
            return;
        };

        if (self.label_index.getPtr(probe_key)) |list| {
            // Key already exists — no heap allocation needed
            try list.append(self.allocator, node_id);
        } else {
            // New key — heap-allocate for map ownership
            const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, label });
            const result = try self.label_index.getOrPut(key);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(u64).empty;
            } else {
                self.allocator.free(key);
            }
            try result.value_ptr.append(self.allocator, node_id);
        }
    }

    fn removeFromLabelIndex(self: *GraphStore, graph_name: []const u8, label: []const u8, node_id: u64) void {
        const key = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, label }) catch return;
        defer self.allocator.free(key);

        if (self.label_index.getPtr(key)) |list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i] == node_id) {
                    _ = list.orderedRemove(i);
                    break;
                }
                i += 1;
            }
            if (list.items.len == 0) {
                if (self.label_index.fetchRemove(key)) |kv| {
                    self.allocator.free(kv.key);
                    var list_copy = kv.value;
                    list_copy.deinit(self.allocator);
                }
            }
        }
    }

    // CANARY: REQ=REQ-PERF-LABEL-INDEX-003; FEATURE="LabelBasedIndex"; ASPECT=NodeLookup; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-28
    // Issue #391: Get nodes by label and graph (O(1) lookup instead of O(n) scan)
    pub fn getNodesByLabel(self: *const GraphStore, graph_name: []const u8, label: []const u8) ?[]const u64 {
        // Create composite key "graph_name:label"
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ graph_name, label }) catch return null;

        if (self.label_index.get(key)) |list| {
            return list.items;
        }
        return null;
    }

    // Issue #391: Get nodes that have ALL specified labels in a graph
    pub fn getNodesByLabels(self: *const GraphStore, graph_name: []const u8, labels: []const []const u8) !std.ArrayList(u64) {
        var result = std.ArrayList(u64).empty;

        if (labels.len == 0) {
            return result;
        }

        // Start with nodes that have the first label
        const first_nodes = self.getNodesByLabel(graph_name, labels[0]) orelse return result;

        // For each candidate node, check if it has all other labels
        for (first_nodes) |node_id| {
            if (self.nodes.get(node_id)) |node| {
                var has_all = true;
                for (labels[1..]) |required_label| {
                    var found = false;
                    for (node.labels) |node_label| {
                        if (std.mem.eql(u8, required_label, node_label)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        has_all = false;
                        break;
                    }
                }
                if (has_all) {
                    try result.append(self.allocator, node_id);
                }
            }
        }

        return result;
    }

    fn rebuildIndexes(self: *GraphStore) !void {
        // Reset label index
        var label_iter = self.label_index.iterator();
        while (label_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.label_index.deinit();
        self.label_index = std.StringHashMap(std.ArrayList(u64)).init(self.allocator);

        // Reset adjacency indexes
        var out_iter = self.outgoing_edges.iterator();
        while (out_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.outgoing_edges.deinit();
        self.outgoing_edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(self.allocator);

        var in_iter = self.incoming_edges.iterator();
        while (in_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.incoming_edges.deinit();
        self.incoming_edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(self.allocator);

        // Rebuild label index and ensure graph registry entries for nodes
        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr;
            try self.ensureGraphNoDirty(node.graph_name);
            for (node.labels) |label| {
                try self.addToLabelIndex(node.graph_name, label, node.id);
            }
        }

        // Rebuild adjacency index and ensure graph registry entries for edges
        var edge_iter = self.edges.iterator();
        while (edge_iter.next()) |entry| {
            const edge = entry.value_ptr;
            try self.ensureGraphNoDirty(edge.graph_name);
            try self.addToAdjacencyIndex(edge.from_id, edge.to_id, edge.id);
        }
    }

    // Backward-compatible createNode that uses "default" graph
    pub fn createNode(self: *GraphStore, labels: [][]const u8) !u64 {
        return self.createNodeWithGraph(labels, "default");
    }

    pub fn setNodeProperty(self: *GraphStore, node_id: u64, key: []const u8, value: PropertyValue) !void {
        if (self.nodes.getPtr(node_id)) |node| {
            // Note: Encryption is now handled by the caller (execution.zig) before calling setNodeProperty
            // This ensures consistent parameters (schema, record_id) between encryption and decryption
            const value_copy = try copyPropertyValue(self, value);
            errdefer freePropertyValue(self, value_copy);

            // Use getOrPut to avoid memory leak - only allocate key if it doesn't exist
            const result = try node.properties.getOrPut(key);
            if (!result.found_existing) {
                // Key doesn't exist, allocate a copy
                result.key_ptr.* = try self.allocator.dupe(u8, key);
            } else {
                // Key exists, free old value
                freePropertyValue(self, result.value_ptr.*);
            }
            result.value_ptr.* = value_copy;

            // Mark as dirty - persistence happens at query completion
            self.dirty = true;

            // WAL notification: SetNodeProperty
            notifyMutation(.set_node_property, node_id, 0, 0, null, key, value, null);
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
            if (node.properties.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                freePropertyValue(self, kv.value);
            }
            // Mark as dirty - persistence happens at query completion
            self.dirty = true;

            // WAL notification: RemoveNodeProperty
            notifyMutation(.remove_node_property, node_id, 0, 0, null, key, null, null);
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

            // Maintain label index
            try self.addToLabelIndex(node.graph_name, label, node_id);

            // Mark as dirty - persistence happens at query completion
            self.dirty = true;

            // WAL notification: AddNodeLabel
            notifyMutation(.add_node_label, node_id, 0, 0, label, null, null, null);
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
                const removed_label = node.labels[index];
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

                // Remove label from index and free label memory
                self.removeFromLabelIndex(node.graph_name, label, node_id);
                self.allocator.free(removed_label);

                // Mark as dirty - persistence happens at query completion
                self.dirty = true;

                // WAL notification: RemoveNodeLabel
                notifyMutation(.remove_node_label, node_id, 0, 0, label, null, null, null);
            }
        }
    }

    pub fn getAllNodes(self: *const GraphStore, allocator: std.mem.Allocator) ![]u64 {
        var result = try allocator.alloc(u64, self.nodes.count());
        var iter = self.nodes.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| {
            result[i] = entry.key_ptr.*;
            i += 1;
        }
        return result;
    }

    pub fn getNodeCount(self: *GraphStore) usize {
        return self.nodes.count();
    }

    pub fn getEdgeCount(self: *GraphStore) usize {
        return self.edges.count();
    }

    pub fn isDirty(self: *const GraphStore) bool {
        return self.dirty;
    }

    pub fn getNodePtr(self: *const GraphStore, node_id: u64) ?*const Node {
        return self.nodes.getPtr(node_id);
    }

    pub fn getEdgePtr(self: *const GraphStore, edge_id: u64) ?*const Edge {
        return self.edges.getPtr(edge_id);
    }

    pub fn getOutgoingEdgeIds(self: *const GraphStore, node_id: u64) ?[]const u64 {
        return if (self.outgoing_edges.get(node_id)) |list| list.items else null;
    }

    pub fn getIncomingEdgeIds(self: *const GraphStore, node_id: u64) ?[]const u64 {
        return if (self.incoming_edges.get(node_id)) |list| list.items else null;
    }

    pub fn getOutgoingEdges(self: *const GraphStore, allocator: std.mem.Allocator, node_id: u64) ![]Edge {
        var result = std.ArrayList(Edge).init(allocator);
        if (self.outgoing_edges.get(node_id)) |outgoing| {
            for (outgoing.items) |edge_id| {
                if (self.edges.get(edge_id)) |edge| {
                    try result.append(allocator, edge.*);
                }
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn getIncomingEdges(self: *const GraphStore, allocator: std.mem.Allocator, node_id: u64) ![]Edge {
        var result = std.ArrayList(Edge).init(allocator);
        if (self.incoming_edges.get(node_id)) |incoming| {
            for (incoming.items) |edge_id| {
                if (self.edges.get(edge_id)) |edge| {
                    try result.append(allocator, edge.*);
                }
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn getNeighbors(self: *const GraphStore, allocator: std.mem.Allocator, node_id: u64) ![]u64 {
        var result = std.ArrayList(u64).init(allocator);
        if (self.outgoing_edges.get(node_id)) |outgoing| {
            for (outgoing.items) |edge_id| {
                if (self.edges.get(edge_id)) |edge| {
                    try result.append(allocator, edge.to_id);
                }
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn getIncomingNodes(self: *const GraphStore, allocator: std.mem.Allocator, node_id: u64) ![]u64 {
        var result = std.ArrayList(u64).init(allocator);
        if (self.incoming_edges.get(node_id)) |incoming| {
            for (incoming.items) |edge_id| {
                if (self.edges.get(edge_id)) |edge| {
                    try result.append(allocator, edge.from_id);
                }
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn getOutgoingNodes(self: *const GraphStore, allocator: std.mem.Allocator, node_id: u64) ![]u64 {
        var result = std.ArrayList(u64).init(allocator);
        if (self.outgoing_edges.get(node_id)) |outgoing| {
            for (outgoing.items) |edge_id| {
                if (self.edges.get(edge_id)) |edge| {
                    try result.append(allocator, edge.to_id);
                }
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn getOutDegree(self: *const GraphStore, node_id: u64) usize {
        return if (self.outgoing_edges.get(node_id)) |outgoing| outgoing.items.len else 0;
    }

    pub fn hasEdge(self: *const GraphStore, source: u64, target: u64) bool {
        if (self.outgoing_edges.get(source)) |outgoing| {
            for (outgoing.items) |edge_id| {
                if (self.edges.get(edge_id)) |edge| {
                    if (edge.to_id == target) return true;
                }
            }
        }
        return false;
    }

    pub fn freePath(self: *const GraphStore, path: Path) void {
        self.allocator.free(path.nodes);
        self.allocator.free(path.edges);
    }

    pub fn freePaths(self: *const GraphStore, paths: []Path) void {
        for (paths) |path| {
            self.freePath(path);
        }
        self.allocator.free(paths);
    }

    pub fn findPaths(self: *GraphStore, start: u64, end: u64, options: PathOptions) ![]Path {
        const bounds = self.resolvePathBounds(options);
        var paths = std.ArrayList(Path).init(self.allocator);
        errdefer paths.deinit(self.allocator);

        var path_nodes = std.ArrayList(u64).init(self.allocator);
        defer path_nodes.deinit(self.allocator);
        var path_edges = std.ArrayList(u64).init(self.allocator);
        defer path_edges.deinit(self.allocator);

        try path_nodes.append(self.allocator, start);
        try self.collectPaths(start, end, bounds.min, bounds.max, false, null, &path_nodes, &path_edges, &paths);

        return paths.toOwnedSlice(self.allocator);
    }

    pub fn findPathsBidirectional(self: *GraphStore, start: u64, end: u64, options: PathOptions) ![]Path {
        const bounds = self.resolvePathBounds(options);
        var paths = std.ArrayList(Path).init(self.allocator);
        errdefer paths.deinit(self.allocator);

        var path_nodes = std.ArrayList(u64).init(self.allocator);
        defer path_nodes.deinit(self.allocator);
        var path_edges = std.ArrayList(u64).init(self.allocator);
        defer path_edges.deinit(self.allocator);

        try path_nodes.append(self.allocator, start);
        try self.collectPaths(start, end, bounds.min, bounds.max, true, null, &path_nodes, &path_edges, &paths);

        return paths.toOwnedSlice(self.allocator);
    }

    pub fn findPathsFiltered(self: *GraphStore, start: u64, end: u64, options: PathOptions, filter: PathFilter) ![]Path {
        const bounds = self.resolvePathBounds(options);
        var paths = std.ArrayList(Path).init(self.allocator);
        errdefer paths.deinit(self.allocator);

        var path_nodes = std.ArrayList(u64).init(self.allocator);
        defer path_nodes.deinit(self.allocator);
        var path_edges = std.ArrayList(u64).init(self.allocator);
        defer path_edges.deinit(self.allocator);

        try path_nodes.append(self.allocator, start);
        try self.collectPaths(start, end, bounds.min, bounds.max, false, &filter, &path_nodes, &path_edges, &paths);

        return paths.toOwnedSlice(self.allocator);
    }

    pub fn shortestPath(self: *GraphStore, start: u64, end: u64) !?Path {
        if (start == end) {
            return Path{
                .nodes = try self.allocator.dupe(u64, &[_]u64{start}),
                .edges = try self.allocator.alloc(u64, 0),
            };
        }

        var visited = std.AutoHashMap(u64, void).init(self.allocator);
        defer visited.deinit();
        var parent = std.AutoHashMap(u64, struct { node: u64, edge: u64 }).init(self.allocator);
        defer parent.deinit();

        var queue = std.ArrayList(u64).init(self.allocator);
        defer queue.deinit();

        try queue.append(self.allocator, start);
        try visited.put(start, {});

        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const current = queue.items[head];
            if (current == end) break;

            if (self.outgoing_edges.get(current)) |outgoing| {
                for (outgoing.items) |edge_id| {
                    if (self.edges.get(edge_id)) |edge| {
                        const next = edge.to_id;
                        if (visited.contains(next)) continue;
                        try visited.put(next, {});
                        try parent.put(next, .{ .node = current, .edge = edge_id });
                        try queue.append(self.allocator, next);
                    }
                }
            }
        }

        if (!parent.contains(end)) return null;

        var nodes_rev = std.ArrayList(u64).init(self.allocator);
        var edges_rev = std.ArrayList(u64).init(self.allocator);
        defer nodes_rev.deinit(self.allocator);
        defer edges_rev.deinit(self.allocator);

        var current = end;
        try nodes_rev.append(self.allocator, current);
        while (current != start) {
            const info = parent.get(current) orelse break;
            try edges_rev.append(self.allocator, info.edge);
            current = info.node;
            try nodes_rev.append(self.allocator, current);
        }

        std.mem.reverse(u64, nodes_rev.items);
        std.mem.reverse(u64, edges_rev.items);

        return Path{
            .nodes = try self.allocator.dupe(u64, nodes_rev.items),
            .edges = try self.allocator.dupe(u64, edges_rev.items),
        };
    }

    pub fn allShortestPaths(self: *GraphStore, start: u64, end: u64) ![]Path {
        if (start == end) {
            var only = std.ArrayList(Path).init(self.allocator);
            try only.append(self.allocator, .{
                .nodes = try self.allocator.dupe(u64, &[_]u64{start}),
                .edges = try self.allocator.alloc(u64, 0),
            });
            return only.toOwnedSlice(self.allocator);
        }

        var distance = std.AutoHashMap(u64, u32).init(self.allocator);
        defer distance.deinit();
        var parents = std.AutoHashMap(u64, std.ArrayList(struct { node: u64, edge: u64 })).init(self.allocator);
        defer {
            var it = parents.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            parents.deinit();
        }

        var queue = std.ArrayList(u64).init(self.allocator);
        defer queue.deinit();

        try queue.append(self.allocator, start);
        try distance.put(start, 0);

        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const current = queue.items[head];
            const current_dist = distance.get(current) orelse 0;
            if (self.outgoing_edges.get(current)) |outgoing| {
                for (outgoing.items) |edge_id| {
                    if (self.edges.get(edge_id)) |edge| {
                        const next = edge.to_id;
                        const next_dist = current_dist + 1;
                        if (distance.get(next)) |existing| {
                            if (next_dist == existing) {
                                const entry = try parents.getOrPut(next);
                                if (!entry.found_existing) {
                                    entry.value_ptr.* = std.ArrayList(struct { node: u64, edge: u64 }).init(self.allocator);
                                }
                                try entry.value_ptr.append(self.allocator, .{ .node = current, .edge = edge_id });
                            }
                            continue;
                        }
                        try distance.put(next, next_dist);
                        const entry = try parents.getOrPut(next);
                        if (!entry.found_existing) {
                            entry.value_ptr.* = std.ArrayList(struct { node: u64, edge: u64 }).init(self.allocator);
                        }
                        try entry.value_ptr.append(self.allocator, .{ .node = current, .edge = edge_id });
                        try queue.append(self.allocator, next);
                    }
                }
            }
        }

        if (!distance.contains(end)) {
            return self.allocator.alloc(Path, 0);
        }

        var results = std.ArrayList(Path).init(self.allocator);
        errdefer {
            for (results.items) |path| self.freePath(path);
            results.deinit(self.allocator);
        }

        var nodes_stack = std.ArrayList(u64).init(self.allocator);
        defer nodes_stack.deinit(self.allocator);
        var edges_stack = std.ArrayList(u64).init(self.allocator);
        defer edges_stack.deinit(self.allocator);

        try nodes_stack.append(self.allocator, end);
        try self.backtrackShortestPaths(start, end, &parents, &nodes_stack, &edges_stack, &results);

        return results.toOwnedSlice(self.allocator);
    }

    pub fn kShortestPaths(self: *GraphStore, start: u64, end: u64, k: usize) ![]Path {
        const max_len: u32 = if (self.nodes.count() == 0) 0 else @intCast(self.nodes.count());
        var all_paths = try self.findPaths(start, end, .{ .max_length = max_len });

        if (all_paths.len <= k) return all_paths;

        std.sort.block(Path, all_paths, {}, struct {
            fn less(_: void, a: Path, b: Path) bool {
                return a.edges.len < b.edges.len;
            }
        }.less);

        for (all_paths[k..]) |path| {
            self.freePath(path);
        }

        const out = try self.allocator.alloc(Path, k);
        std.mem.copyForwards(Path, out, all_paths[0..k]);
        self.allocator.free(all_paths);
        return out;
    }

    pub fn expandFromNode(self: *GraphStore, start: u64, options: ExpandOptions) ![]u64 {
        var visited = std.AutoHashMap(u64, void).init(self.allocator);
        defer visited.deinit();

        var queue = std.ArrayList(struct { node: u64, depth: u32 }).init(self.allocator);
        defer queue.deinit();

        var result = std.ArrayList(u64).init(self.allocator);
        errdefer result.deinit(self.allocator);

        try queue.append(self.allocator, .{ .node = start, .depth = 0 });
        try visited.put(start, {});
        try result.append(self.allocator, start);

        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const current = queue.items[head];
            if (current.depth >= options.max_depth) continue;

            if (self.outgoing_edges.get(current.node)) |outgoing| {
                for (outgoing.items) |edge_id| {
                    if (self.edges.get(edge_id)) |edge| {
                        const next = edge.to_id;
                        if (visited.contains(next)) continue;
                        try visited.put(next, {});
                        try result.append(self.allocator, next);
                        try queue.append(self.allocator, .{ .node = next, .depth = current.depth + 1 });
                    }
                }
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn resolvePathBounds(self: *GraphStore, options: PathOptions) struct { min: u32, max: u32 } {
        _ = self;
        if (options.exact_length) |exact| {
            return .{ .min = exact, .max = exact };
        }
        const min_len: u32 = options.min_length orelse 1;
        const max_len: u32 = options.max_length orelse min_len + 10;
        return .{ .min = min_len, .max = max_len };
    }

    fn collectPaths(
        self: *GraphStore,
        current: u64,
        end: u64,
        min_len: u32,
        max_len: u32,
        bidirectional: bool,
        filter: ?*const PathFilter,
        path_nodes: *std.ArrayList(u64),
        path_edges: *std.ArrayList(u64),
        results: *std.ArrayList(Path),
    ) !void {
        const depth: u32 = @intCast(path_edges.items.len);

        if (depth >= min_len and current == end) {
            const nodes_copy = try self.allocator.dupe(u64, path_nodes.items);
            const edges_copy = try self.allocator.dupe(u64, path_edges.items);
            try results.append(self.allocator, .{ .nodes = nodes_copy, .edges = edges_copy });
        }

        if (depth >= max_len) return;

        const visit = struct {
            fn shouldSkip(nodes: []const u64, next: u64, target: u64) bool {
                if (next == target) return false;
                for (nodes) |node| {
                    if (node == next) return true;
                }
                return false;
            }
        }.shouldSkip;

        if (self.outgoing_edges.get(current)) |outgoing| {
            for (outgoing.items) |edge_id| {
                if (self.edges.getPtr(edge_id)) |edge| {
                    const next = edge.to_id;
                    if (visit(path_nodes.items, next, end)) continue;
                    if (filter) |flt| {
                        if (flt.edge_predicate) |pred| {
                            if (!pred(edge)) continue;
                        }
                        if (flt.node_predicate) |pred| {
                            if (self.nodes.getPtr(next)) |node_ptr| {
                                if (!pred(node_ptr)) continue;
                            } else continue;
                        }
                    }

                    try path_nodes.append(self.allocator, next);
                    try path_edges.append(self.allocator, edge_id);
                    try self.collectPaths(next, end, min_len, max_len, bidirectional, filter, path_nodes, path_edges, results);
                    _ = path_nodes.pop();
                    _ = path_edges.pop();
                }
            }
        }

        if (bidirectional) {
            if (self.incoming_edges.get(current)) |incoming| {
                for (incoming.items) |edge_id| {
                    if (self.edges.getPtr(edge_id)) |edge| {
                        const next = edge.from_id;
                        if (visit(path_nodes.items, next, end)) continue;
                        if (filter) |flt| {
                            if (flt.edge_predicate) |pred| {
                                if (!pred(edge)) continue;
                            }
                            if (flt.node_predicate) |pred| {
                                if (self.nodes.getPtr(next)) |node_ptr| {
                                    if (!pred(node_ptr)) continue;
                                } else continue;
                            }
                        }

                        try path_nodes.append(self.allocator, next);
                        try path_edges.append(self.allocator, edge_id);
                        try self.collectPaths(next, end, min_len, max_len, bidirectional, filter, path_nodes, path_edges, results);
                        _ = path_nodes.pop();
                        _ = path_edges.pop();
                    }
                }
            }
        }
    }

    fn backtrackShortestPaths(
        self: *GraphStore,
        start: u64,
        current: u64,
        parents: *std.AutoHashMap(u64, std.ArrayList(struct { node: u64, edge: u64 })),
        nodes_stack: *std.ArrayList(u64),
        edges_stack: *std.ArrayList(u64),
        results: *std.ArrayList(Path),
    ) !void {
        if (current == start) {
            const nodes_copy = try self.allocator.dupe(u64, nodes_stack.items);
            const edges_copy = try self.allocator.dupe(u64, edges_stack.items);
            std.mem.reverse(u64, nodes_copy);
            std.mem.reverse(u64, edges_copy);
            try results.append(self.allocator, .{ .nodes = nodes_copy, .edges = edges_copy });
            return;
        }

        if (parents.get(current)) |plist| {
            for (plist.items) |info| {
                try edges_stack.append(self.allocator, info.edge);
                try nodes_stack.append(self.allocator, info.node);
                try self.backtrackShortestPaths(start, info.node, parents, nodes_stack, edges_stack, results);
                _ = edges_stack.pop();
                _ = nodes_stack.pop();
            }
        }
    }

    // CANARY: REQ=REQ-MULTI-GRAPH-005; FEATURE="MultiGraphIsolation"; ASPECT=CreateEdge; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
    // Create edge with optional graph name for per-graph data isolation
    pub fn createEdgeWithGraph(self: *GraphStore, from_id: u64, to_id: u64, edge_type: []const u8, graph_name: []const u8) !u64 {
        try self.ensureGraph(graph_name);
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

        // CANARY: REQ=REQ-PERF-EDGE-ADJ-002; FEATURE="EdgeAdjacencyIndex"; ASPECT=IndexMaintenance; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-28
        // Issue #392: Maintain adjacency indexes for fast DELETE DETACH
        try self.addToAdjacencyIndex(from_id, to_id, id);

        // CANARY: REQ=REQ-BINARY-PERSIST-EDGE-001; FEATURE="BinaryPersistence"; ASPECT=DirtyTracking; STATUS=IMPL; OWNER=storage; UPDATED=2026-02-02
        // Mark store as dirty - persistence happens at query completion, not per-edge
        self.dirty = true;

        // WAL notification: CreateEdge
        notifyMutation(.create_edge, id, from_id, to_id, edge_type, null, null, graph_name);

        return id;
    }

    fn createEdgeWithIdInternal(
        self: *GraphStore,
        edge_id: u64,
        from_id: u64,
        to_id: u64,
        edge_type: []const u8,
        graph_name: []const u8,
        mark_dirty: bool,
    ) !void {
        try self.ensureGraph(graph_name);
        if (self.edges.contains(edge_id)) return error.EdgeAlreadyExists;

        const edge_type_copy = try self.allocator.dupe(u8, edge_type);
        const graph_name_copy = try self.allocator.dupe(u8, graph_name);

        const edge = Edge{
            .id = edge_id,
            .from_id = from_id,
            .to_id = to_id,
            .label = edge_type_copy,
            .properties = std.StringHashMap(PropertyValue).init(self.allocator),
            .graph_name = graph_name_copy,
        };

        try self.edges.put(edge_id, edge);
        try self.addToAdjacencyIndex(from_id, to_id, edge_id);

        if (edge_id >= self.next_edge_id) {
            self.next_edge_id = edge_id + 1;
        }

        if (mark_dirty) {
            self.dirty = true;
        }
    }

    /// Create an edge with a specified ID (used for replication/2PC).
    pub fn createEdgeWithId(
        self: *GraphStore,
        edge_id: u64,
        from_id: u64,
        to_id: u64,
        edge_type: []const u8,
        graph_name: []const u8,
    ) !void {
        return self.createEdgeWithIdInternal(edge_id, from_id, to_id, edge_type, graph_name, true);
    }

    /// Create an edge with a specified ID without marking dirty (used for rollback).
    pub fn createEdgeWithIdNoSave(
        self: *GraphStore,
        edge_id: u64,
        from_id: u64,
        to_id: u64,
        edge_type: []const u8,
        graph_name: []const u8,
    ) !void {
        return self.createEdgeWithIdInternal(edge_id, from_id, to_id, edge_type, graph_name, false);
    }

    // Issue #392: Helper to maintain adjacency indexes
    fn addToAdjacencyIndex(self: *GraphStore, from_id: u64, to_id: u64, edge_id: u64) !void {
        // Add to outgoing edges for from_id
        const out_result = try self.outgoing_edges.getOrPut(from_id);
        if (!out_result.found_existing) {
            out_result.value_ptr.* = std.ArrayList(u64).empty;
        }
        try out_result.value_ptr.append(self.allocator, edge_id);

        // Add to incoming edges for to_id
        const in_result = try self.incoming_edges.getOrPut(to_id);
        if (!in_result.found_existing) {
            in_result.value_ptr.* = std.ArrayList(u64).empty;
        }
        try in_result.value_ptr.append(self.allocator, edge_id);
    }

    fn removeFromAdjacencyIndex(self: *GraphStore, from_id: u64, to_id: u64, edge_id: u64) void {
        if (self.outgoing_edges.getPtr(from_id)) |list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i] == edge_id) {
                    _ = list.swapRemove(i);
                    break;
                }
                i += 1;
            }
            if (list.items.len == 0) {
                if (self.outgoing_edges.fetchRemove(from_id)) |kv| {
                    var list_copy = kv.value;
                    list_copy.deinit(self.allocator);
                }
            }
        }

        if (self.incoming_edges.getPtr(to_id)) |list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i] == edge_id) {
                    _ = list.swapRemove(i);
                    break;
                }
                i += 1;
            }
            if (list.items.len == 0) {
                if (self.incoming_edges.fetchRemove(to_id)) |kv| {
                    var list_copy = kv.value;
                    list_copy.deinit(self.allocator);
                }
            }
        }
    }

    // CANARY: REQ=REQ-PERF-EDGE-ADJ-003; FEATURE="EdgeAdjacencyIndex"; ASPECT=EdgeLookup; STATUS=TESTED; OWNER=perf; UPDATED=2026-02-12
    // Issue #392: Get all edges connected to a node (O(1) lookup instead of O(edges) scan)
    // Issue #450: Use HashSet for O(1) deduplication instead of O(m*n) linear scan
    pub fn getEdgesForNode(self: *const GraphStore, node_id: u64) std.ArrayList(u64) {
        var result = std.ArrayList(u64).empty;
        var seen = std.AutoHashMap(u64, void).init(self.allocator);
        defer seen.deinit();

        // Get outgoing edges
        if (self.outgoing_edges.get(node_id)) |outgoing| {
            for (outgoing.items) |edge_id| {
                seen.put(edge_id, {}) catch continue;
                result.append(self.allocator, edge_id) catch continue;
            }
        }

        // Get incoming edges — deduplicate self-loops via HashSet (#450)
        if (self.incoming_edges.get(node_id)) |incoming| {
            for (incoming.items) |edge_id| {
                if (!seen.contains(edge_id)) {
                    seen.put(edge_id, {}) catch continue;
                    result.append(self.allocator, edge_id) catch continue;
                }
            }
        }

        return result;
    }

    // Backward-compatible createEdge that uses "default" graph
    pub fn createEdge(self: *GraphStore, from_id: u64, to_id: u64, edge_type: []const u8) !u64 {
        return self.createEdgeWithGraph(from_id, to_id, edge_type, "default");
    }

    pub fn setEdgeProperty(self: *GraphStore, edge_id: u64, key: []const u8, value: PropertyValue) !void {
        if (self.edges.getPtr(edge_id)) |edge| {
            // Note: Encryption is now handled by the caller (execution.zig) before calling setEdgeProperty
            // This ensures consistent parameters (schema, record_id) between encryption and decryption
            const value_copy = try copyPropertyValue(self, value);
            errdefer freePropertyValue(self, value_copy);

            // Use getOrPut to avoid memory leak - only allocate key if it doesn't exist
            const result = try edge.properties.getOrPut(key);
            if (!result.found_existing) {
                // Key doesn't exist, allocate a copy
                result.key_ptr.* = try self.allocator.dupe(u8, key);
            } else {
                // Key exists, free old value
                freePropertyValue(self, result.value_ptr.*);
            }
            result.value_ptr.* = value_copy;

            // Mark as dirty - persistence happens at query completion
            self.dirty = true;

            // WAL notification: SetEdgeProperty
            notifyMutation(.set_edge_property, edge_id, 0, 0, null, key, value, null);
        }
    }

    pub fn removeEdgeProperty(self: *GraphStore, edge_id: u64, key: []const u8) void {
        if (self.edges.getPtr(edge_id)) |edge| {
            if (edge.properties.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                freePropertyValue(self, kv.value);
            }
            self.dirty = true;

            // WAL notification: RemoveEdgeProperty
            notifyMutation(.remove_edge_property, edge_id, 0, 0, null, key, null, null);
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
        var result = std.ArrayList(Edge){};
        if (self.outgoing_edges.get(node_id)) |outgoing| {
            for (outgoing.items) |edge_id| {
                if (self.edges.get(edge_id)) |edge| {
                    result.append(self.allocator, edge) catch continue;
                }
            }
        }
        return result.toOwnedSlice(self.allocator) catch &.{};
    }

    pub fn getEdgesTo(self: *GraphStore, node_id: u64) []Edge {
        var result = std.ArrayList(Edge){};
        if (self.incoming_edges.get(node_id)) |incoming| {
            for (incoming.items) |edge_id| {
                if (self.edges.get(edge_id)) |edge| {
                    result.append(self.allocator, edge) catch continue;
                }
            }
        }
        return result.toOwnedSlice(self.allocator) catch &.{};
    }

    /// Write an ExtValue to any writer with CRC hashing.
    /// Generic version of the old writeExtValue (which used ArrayList).
    fn writeExtValueToWriter(_: *GraphStore, writer: anytype, hasher: *crc.Crc32, ext: @import("eval_extended.zig").ExtValue) !void {
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
        hasher.update(&[1]u8{sub_type});
        try writer.writeAll(&[1]u8{sub_type});

        switch (ext) {
            .Null => {},
            .Int => |i| {
                var buf: [8]u8 = undefined;
                std.mem.writeInt(i64, &buf, i, .little);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .Bool => |b| {
                const byte = [1]u8{if (b) 1 else 0};
                hasher.update(&byte);
                try writer.writeAll(&byte);
            },
            .Str => |s| {
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(s.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(s);
                try writer.writeAll(s);
            },
            .Decimal => |d| {
                var buf: [17]u8 = undefined;
                std.mem.writeInt(i128, buf[0..16], d.coeff, .little);
                buf[16] = d.scale;
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .IpAddr => |ip| {
                const is_v6: u8 = if (ip == .v6) 1 else 0;
                hasher.update(&[1]u8{is_v6});
                try writer.writeAll(&[1]u8{is_v6});
                if (ip == .v4) {
                    hasher.update(&ip.v4);
                    try writer.writeAll(&ip.v4);
                } else {
                    hasher.update(&ip.v6);
                    try writer.writeAll(&ip.v6);
                }
            },
            .Subnet => |subnet| {
                const is_v6: u8 = if (subnet.addr == .v6) 1 else 0;
                hasher.update(&[1]u8{is_v6});
                try writer.writeAll(&[1]u8{is_v6});
                if (subnet.addr == .v4) {
                    hasher.update(&subnet.addr.v4);
                    try writer.writeAll(&subnet.addr.v4);
                } else {
                    hasher.update(&subnet.addr.v6);
                    try writer.writeAll(&subnet.addr.v6);
                }
                hasher.update(&[1]u8{subnet.prefix_len});
                try writer.writeAll(&[1]u8{subnet.prefix_len});
            },
            .Mac => |mac| {
                hasher.update(&mac.bytes);
                try writer.writeAll(&mac.bytes);
            },
            .LatLon => |ll| {
                var buf: [16]u8 = undefined;
                std.mem.writeInt(u64, buf[0..8], @bitCast(ll.lat), .little);
                std.mem.writeInt(u64, buf[8..16], @bitCast(ll.lon), .little);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .LatLonAlt => |lla| {
                var buf: [25]u8 = undefined;
                std.mem.writeInt(u64, buf[0..8], @bitCast(lla.lat), .little);
                std.mem.writeInt(u64, buf[8..16], @bitCast(lla.lon), .little);
                std.mem.writeInt(u64, buf[16..24], @bitCast(lla.alt), .little);
                buf[24] = @intFromEnum(lla.ref);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .Geometry => |geom| {
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(geom.wkb.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(geom.wkb);
                try writer.writeAll(geom.wkb);
            },
            .Currency => |cur| {
                hasher.update(&cur.code);
                try writer.writeAll(&cur.code);
            },
            .VectorF32 => |vec| {
                var dim_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &dim_buf, vec.dim, .little);
                hasher.update(&dim_buf);
                try writer.writeAll(&dim_buf);
                for (vec.data) |f| {
                    var f_buf: [4]u8 = undefined;
                    std.mem.writeInt(u32, &f_buf, @bitCast(f), .little);
                    hasher.update(&f_buf);
                    try writer.writeAll(&f_buf);
                }
            },
            .VectorI32 => |vec| {
                var dim_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &dim_buf, vec.dim, .little);
                hasher.update(&dim_buf);
                try writer.writeAll(&dim_buf);
                for (vec.data) |i| {
                    var i_buf: [4]u8 = undefined;
                    std.mem.writeInt(i32, &i_buf, i, .little);
                    hasher.update(&i_buf);
                    try writer.writeAll(&i_buf);
                }
            },
            .Hash => |hash| {
                const alg_byte = [1]u8{@intFromEnum(hash.alg)};
                hasher.update(&alg_byte);
                try writer.writeAll(&alg_byte);
                var digest_len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &digest_len_buf, @intCast(hash.digest.len), .little);
                hasher.update(&digest_len_buf);
                try writer.writeAll(&digest_len_buf);
                hasher.update(hash.digest);
                try writer.writeAll(hash.digest);
                if (hash.salt) |salt| {
                    hasher.update(&[1]u8{1});
                    try writer.writeAll(&[1]u8{1});
                    var salt_len_buf: [4]u8 = undefined;
                    std.mem.writeInt(u32, &salt_len_buf, @intCast(salt.len), .little);
                    hasher.update(&salt_len_buf);
                    try writer.writeAll(&salt_len_buf);
                    hasher.update(salt);
                    try writer.writeAll(salt);
                } else {
                    hasher.update(&[1]u8{0});
                    try writer.writeAll(&[1]u8{0});
                }
            },
            .LanguageTag => |lt| {
                var tag_len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &tag_len_buf, @intCast(lt.tag.len), .little);
                hasher.update(&tag_len_buf);
                try writer.writeAll(&tag_len_buf);
                hasher.update(lt.tag);
                try writer.writeAll(lt.tag);
            },
            .Temperature => |temp| {
                var buf: [9]u8 = undefined;
                std.mem.writeInt(u64, buf[0..8], @bitCast(temp.value_K), .little);
                buf[8] = @intFromEnum(temp.unit_in);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .Pressure => |pres| {
                var buf: [9]u8 = undefined;
                std.mem.writeInt(u64, buf[0..8], @bitCast(pres.value_Pa), .little);
                buf[8] = @intFromEnum(pres.unit_in);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .Date => |date| {
                var buf: [4]u8 = undefined;
                std.mem.writeInt(i32, &buf, date.days_since_epoch, .little);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .Time => |time| {
                var buf: [8]u8 = undefined;
                std.mem.writeInt(i64, &buf, time.micros_since_midnight, .little);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .TimestampTZ => |ts| {
                var buf: [8]u8 = undefined;
                std.mem.writeInt(i64, &buf, ts.micros_since_epoch_utc, .little);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .Interval => |iv| {
                var buf: [16]u8 = undefined;
                std.mem.writeInt(i32, buf[0..4], iv.months, .little);
                std.mem.writeInt(i32, buf[4..8], iv.days, .little);
                std.mem.writeInt(i64, buf[8..16], iv.micros, .little);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .UUID => |uuid_val| {
                var buf: [16]u8 = undefined;
                @memcpy(&buf, &uuid_val.bytes);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .Url => |url_val| {
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(url_val.scheme.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(url_val.scheme);
                try writer.writeAll(url_val.scheme);

                std.mem.writeInt(u32, &len_buf, @intCast(url_val.host.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(url_val.host);
                try writer.writeAll(url_val.host);

                const has_port: u8 = if (url_val.port != null) 1 else 0;
                hasher.update(&[1]u8{has_port});
                try writer.writeAll(&[1]u8{has_port});
                if (url_val.port) |p| {
                    var p_buf: [2]u8 = undefined;
                    std.mem.writeInt(u16, &p_buf, p, .little);
                    hasher.update(&p_buf);
                    try writer.writeAll(&p_buf);
                }

                std.mem.writeInt(u32, &len_buf, @intCast(url_val.path.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(url_val.path);
                try writer.writeAll(url_val.path);

                const has_query: u8 = if (url_val.query != null) 1 else 0;
                hasher.update(&[1]u8{has_query});
                try writer.writeAll(&[1]u8{has_query});
                if (url_val.query) |q| {
                    std.mem.writeInt(u32, &len_buf, @intCast(q.len), .little);
                    hasher.update(&len_buf);
                    try writer.writeAll(&len_buf);
                    hasher.update(q);
                    try writer.writeAll(q);
                }

                const has_fragment: u8 = if (url_val.fragment != null) 1 else 0;
                hasher.update(&[1]u8{has_fragment});
                try writer.writeAll(&[1]u8{has_fragment});
                if (url_val.fragment) |f| {
                    std.mem.writeInt(u32, &len_buf, @intCast(f.len), .little);
                    hasher.update(&len_buf);
                    try writer.writeAll(&len_buf);
                    hasher.update(f);
                    try writer.writeAll(f);
                }
            },
            .Domain => |domain| {
                var count_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &count_buf, @intCast(domain.labels.len), .little);
                hasher.update(&count_buf);
                try writer.writeAll(&count_buf);
                for (domain.labels) |label| {
                    var len_buf: [4]u8 = undefined;
                    std.mem.writeInt(u32, &len_buf, @intCast(label.len), .little);
                    hasher.update(&len_buf);
                    try writer.writeAll(&len_buf);
                    hasher.update(label);
                    try writer.writeAll(label);
                }
            },
            .Bytea => |b| {
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(b.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(b);
                try writer.writeAll(b);
            },
            .Json => |j| {
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(j.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(j);
                try writer.writeAll(j);
            },
            .Jsonb => |doc| {
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(doc.data.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(doc.data);
                try writer.writeAll(doc.data);
            },
            .Xml => |doc| {
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(doc.data.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(doc.data);
                try writer.writeAll(doc.data);
            },
            .BitString => |bs| {
                var bit_len_buf: [8]u8 = undefined;
                std.mem.writeInt(u64, &bit_len_buf, @intCast(bs.bit_length), .little);
                hasher.update(&bit_len_buf);
                try writer.writeAll(&bit_len_buf);
                var byte_len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &byte_len_buf, @intCast(bs.bytes.len), .little);
                hasher.update(&byte_len_buf);
                try writer.writeAll(&byte_len_buf);
                hasher.update(bs.bytes);
                try writer.writeAll(bs.bytes);
            },
            .VarBit => |bs| {
                var bit_len_buf: [8]u8 = undefined;
                std.mem.writeInt(u64, &bit_len_buf, @intCast(bs.bit_length), .little);
                hasher.update(&bit_len_buf);
                try writer.writeAll(&bit_len_buf);
                var byte_len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &byte_len_buf, @intCast(bs.bytes.len), .little);
                hasher.update(&byte_len_buf);
                try writer.writeAll(&byte_len_buf);
                hasher.update(bs.bytes);
                try writer.writeAll(bs.bytes);
            },
            .IntRange => |range_val| {
                var buf: [9]u8 = undefined;
                std.mem.writeInt(i32, buf[0..4], range_val.lower orelse 0, .little);
                std.mem.writeInt(i32, buf[4..8], range_val.upper orelse 0, .little);
                buf[8] = @intFromEnum(range_val.bounds);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .Enum => |enum_val| {
                var buf: [8]u8 = undefined;
                std.mem.writeInt(u32, buf[0..4], enum_val.type_id, .little);
                std.mem.writeInt(u32, buf[4..8], enum_val.value_ordinal, .little);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .List => |list| {
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(list.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
            },
        }
    }

    fn readExtValue(self: *GraphStore, reader: anytype) !@import("eval_extended.zig").ExtValue {
        const ext_eval = @import("eval_extended.zig");
        const heap_mod = @import("storage/heap.zig");
        const jsonb_mod = @import("types/jsonb.zig");
        const xml_mod = @import("types/xml.zig");
        const bitstring_mod = @import("types/bitstring.zig");
        const url_mod = @import("types/url.zig");
        const range_mod = @import("types/range.zig");

        var sub_type_buf: [1]u8 = undefined;
        if ((try reader.readAll(&sub_type_buf)) < 1) return ext_eval.ExtValue{ .Null = {} };

        return switch (sub_type_buf[0]) {
            0 => ext_eval.ExtValue{ .Null = {} },
            1 => blk: {
                var buf: [8]u8 = undefined;
                if ((try reader.readAll(&buf)) < 8) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Int = std.mem.readInt(i64, &buf, .little) };
            },
            2 => blk: {
                var buf: [1]u8 = undefined;
                if ((try reader.readAll(&buf)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Bool = buf[0] != 0 };
            },
            3 => blk: {
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const len = std.mem.readInt(u32, &len_buf, .little);
                const str_data = try self.allocator.alloc(u8, len);
                if ((try reader.readAll(str_data)) < len) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Str = str_data };
            },
            4 => blk: {
                var buf: [17]u8 = undefined;
                if ((try reader.readAll(&buf)) < 17) break :blk ext_eval.ExtValue{ .Null = {} };
                const coeff = std.mem.readInt(i128, buf[0..16], .little);
                const scale = buf[16];
                break :blk ext_eval.ExtValue{ .Decimal = .{ .coeff = coeff, .scale = scale } };
            },
            5 => blk: {
                var is_v6_buf: [1]u8 = undefined;
                if ((try reader.readAll(&is_v6_buf)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                const is_v6 = is_v6_buf[0] != 0;
                if (is_v6) {
                    var addr_buf: [16]u8 = undefined;
                    if ((try reader.readAll(&addr_buf)) < 16) break :blk ext_eval.ExtValue{ .Null = {} };
                    break :blk ext_eval.ExtValue{ .IpAddr = .{ .v6 = addr_buf } };
                } else {
                    var addr_buf: [4]u8 = undefined;
                    if ((try reader.readAll(&addr_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                    break :blk ext_eval.ExtValue{ .IpAddr = .{ .v4 = addr_buf } };
                }
            },
            6 => blk: {
                var is_v6_buf: [1]u8 = undefined;
                if ((try reader.readAll(&is_v6_buf)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                const is_v6 = is_v6_buf[0] != 0;
                const addr = if (is_v6) blk2: {
                    var addr_buf: [16]u8 = undefined;
                    if ((try reader.readAll(&addr_buf)) < 16) break :blk ext_eval.ExtValue{ .Null = {} };
                    break :blk2 heap_mod.IpAddr{ .v6 = addr_buf };
                } else blk2: {
                    var addr_buf: [4]u8 = undefined;
                    if ((try reader.readAll(&addr_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                    break :blk2 heap_mod.IpAddr{ .v4 = addr_buf };
                };
                var prefix_len_buf: [1]u8 = undefined;
                if ((try reader.readAll(&prefix_len_buf)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Subnet = .{ .addr = addr, .prefix_len = prefix_len_buf[0] } };
            },
            7 => blk: {
                var mac_buf: [6]u8 = undefined;
                if ((try reader.readAll(&mac_buf)) < 6) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Mac = .{ .bytes = mac_buf } };
            },
            8 => blk: {
                var alg_buf: [1]u8 = undefined;
                if ((try reader.readAll(&alg_buf)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const len = std.mem.readInt(u32, &len_buf, .little);
                const digest = try self.allocator.alloc(u8, len);
                if ((try reader.readAll(digest)) < len) break :blk ext_eval.ExtValue{ .Null = {} };
                var salt_flag: [1]u8 = undefined;
                if ((try reader.readAll(&salt_flag)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                var salt: ?[]const u8 = null;
                if (salt_flag[0] != 0) {
                    if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                    const salt_len = std.mem.readInt(u32, &len_buf, .little);
                    const salt_data = try self.allocator.alloc(u8, salt_len);
                    if ((try reader.readAll(salt_data)) < salt_len) break :blk ext_eval.ExtValue{ .Null = {} };
                    salt = salt_data;
                }
                break :blk ext_eval.ExtValue{ .Hash = .{
                    .alg = @enumFromInt(alg_buf[0]),
                    .digest = digest,
                    .salt = salt,
                } };
            },
            9 => blk: {
                var code_buf: [3]u8 = undefined;
                if ((try reader.readAll(&code_buf)) < 3) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Currency = .{ .code = code_buf } };
            },
            10 => blk: {
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const len = std.mem.readInt(u32, &len_buf, .little);
                const tag = try self.allocator.alloc(u8, len);
                if ((try reader.readAll(tag)) < len) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .LanguageTag = .{ .tag = tag } };
            },
            11 => blk: {
                var buf: [16]u8 = undefined;
                if ((try reader.readAll(&buf)) < 16) break :blk ext_eval.ExtValue{ .Null = {} };
                const lat_bits = std.mem.readInt(u64, buf[0..8], .little);
                const lon_bits = std.mem.readInt(u64, buf[8..16], .little);
                break :blk ext_eval.ExtValue{ .LatLon = .{ .lat = @bitCast(lat_bits), .lon = @bitCast(lon_bits) } };
            },
            12 => blk: {
                var buf: [25]u8 = undefined;
                if ((try reader.readAll(&buf)) < 25) break :blk ext_eval.ExtValue{ .Null = {} };
                const lat_bits = std.mem.readInt(u64, buf[0..8], .little);
                const lon_bits = std.mem.readInt(u64, buf[8..16], .little);
                const alt_bits = std.mem.readInt(u64, buf[16..24], .little);
                const ref: heap_mod.AltRef = @enumFromInt(buf[24]);
                break :blk ext_eval.ExtValue{ .LatLonAlt = .{ .lat = @bitCast(lat_bits), .lon = @bitCast(lon_bits), .alt = @bitCast(alt_bits), .ref = ref } };
            },
            13 => blk: {
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const len = std.mem.readInt(u32, &len_buf, .little);
                const wkb_data = try self.allocator.alloc(u8, len);
                if ((try reader.readAll(wkb_data)) < len) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Geometry = .{ .wkb = wkb_data } };
            },
            14 => blk: {
                var buf: [9]u8 = undefined;
                if ((try reader.readAll(&buf)) < 9) break :blk ext_eval.ExtValue{ .Null = {} };
                const value_bits = std.mem.readInt(u64, buf[0..8], .little);
                const unit: heap_mod.TempUnit = @enumFromInt(buf[8]);
                break :blk ext_eval.ExtValue{ .Temperature = .{ .value_K = @bitCast(value_bits), .unit_in = unit } };
            },
            15 => blk: {
                var buf: [9]u8 = undefined;
                if ((try reader.readAll(&buf)) < 9) break :blk ext_eval.ExtValue{ .Null = {} };
                const value_bits = std.mem.readInt(u64, buf[0..8], .little);
                const unit: heap_mod.PressureUnit = @enumFromInt(buf[8]);
                break :blk ext_eval.ExtValue{ .Pressure = .{ .value_Pa = @bitCast(value_bits), .unit_in = unit } };
            },
            16 => blk: {
                var dim_buf: [2]u8 = undefined;
                if ((try reader.readAll(&dim_buf)) < 2) break :blk ext_eval.ExtValue{ .Null = {} };
                const dim = std.mem.readInt(u16, &dim_buf, .little);
                const vec_data = try self.allocator.alloc(f32, dim);
                for (0..dim) |i| {
                    var f_buf: [4]u8 = undefined;
                    if ((try reader.readAll(&f_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                    vec_data[i] = @bitCast(std.mem.readInt(u32, &f_buf, .little));
                }
                break :blk ext_eval.ExtValue{ .VectorF32 = .{ .dim = dim, .data = vec_data } };
            },
            17 => blk: {
                var buf: [4]u8 = undefined;
                if ((try reader.readAll(&buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Date = .{ .days_since_epoch = std.mem.readInt(i32, &buf, .little) } };
            },
            18 => blk: {
                var buf: [8]u8 = undefined;
                if ((try reader.readAll(&buf)) < 8) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Time = .{ .micros_since_midnight = std.mem.readInt(i64, &buf, .little) } };
            },
            19 => blk: {
                var buf: [8]u8 = undefined;
                if ((try reader.readAll(&buf)) < 8) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .TimestampTZ = .{ .micros_since_epoch_utc = std.mem.readInt(i64, &buf, .little) } };
            },
            20 => blk: {
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const len = std.mem.readInt(u32, &len_buf, .little);
                _ = len;
                break :blk ext_eval.ExtValue{ .List = &.{} };
            },
            21 => blk: {
                var dim_buf: [2]u8 = undefined;
                if ((try reader.readAll(&dim_buf)) < 2) break :blk ext_eval.ExtValue{ .Null = {} };
                const dim = std.mem.readInt(u16, &dim_buf, .little);
                const vec_data = try self.allocator.alloc(i32, dim);
                for (0..dim) |i| {
                    var i_buf: [4]u8 = undefined;
                    if ((try reader.readAll(&i_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                    vec_data[i] = std.mem.readInt(i32, &i_buf, .little);
                }
                break :blk ext_eval.ExtValue{ .VectorI32 = .{ .dim = dim, .data = vec_data } };
            },
            22 => blk: {
                var buf: [16]u8 = undefined;
                if ((try reader.readAll(&buf)) < 16) break :blk ext_eval.ExtValue{ .Null = {} };
                const months = std.mem.readInt(i32, buf[0..4], .little);
                const days = std.mem.readInt(i32, buf[4..8], .little);
                const micros = std.mem.readInt(i64, buf[8..16], .little);
                break :blk ext_eval.ExtValue{ .Interval = .{ .months = months, .days = days, .micros = micros } };
            },
            23 => blk: {
                var buf: [16]u8 = undefined;
                if ((try reader.readAll(&buf)) < 16) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .UUID = .{ .bytes = buf } };
            },
            24 => blk: {
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const s_len = std.mem.readInt(u32, &len_buf, .little);
                const scheme = try self.allocator.alloc(u8, s_len);
                if ((try reader.readAll(scheme)) < s_len) break :blk ext_eval.ExtValue{ .Null = {} };
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const h_len = std.mem.readInt(u32, &len_buf, .little);
                const host = try self.allocator.alloc(u8, h_len);
                if ((try reader.readAll(host)) < h_len) break :blk ext_eval.ExtValue{ .Null = {} };
                var flag_buf: [1]u8 = undefined;
                if ((try reader.readAll(&flag_buf)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                const port = if (flag_buf[0] != 0) blk2: {
                    var p_buf: [2]u8 = undefined;
                    if ((try reader.readAll(&p_buf)) < 2) break :blk ext_eval.ExtValue{ .Null = {} };
                    break :blk2 std.mem.readInt(u16, &p_buf, .little);
                } else null;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const p_len = std.mem.readInt(u32, &len_buf, .little);
                const path = try self.allocator.alloc(u8, p_len);
                if ((try reader.readAll(path)) < p_len) break :blk ext_eval.ExtValue{ .Null = {} };
                if ((try reader.readAll(&flag_buf)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                const query = if (flag_buf[0] != 0) blk2: {
                    if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                    const q_len = std.mem.readInt(u32, &len_buf, .little);
                    const q_data = try self.allocator.alloc(u8, q_len);
                    if ((try reader.readAll(q_data)) < q_len) break :blk ext_eval.ExtValue{ .Null = {} };
                    break :blk2 q_data;
                } else null;
                if ((try reader.readAll(&flag_buf)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                const fragment = if (flag_buf[0] != 0) blk2: {
                    if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                    const f_len = std.mem.readInt(u32, &len_buf, .little);
                    const f_data = try self.allocator.alloc(u8, f_len);
                    if ((try reader.readAll(f_data)) < f_len) break :blk ext_eval.ExtValue{ .Null = {} };
                    break :blk2 f_data;
                } else null;
                break :blk ext_eval.ExtValue{ .Url = url_mod.Url{ .scheme = scheme, .host = host, .port = port, .path = path, .query = query, .fragment = fragment } };
            },
            25 => blk: {
                var count_buf: [4]u8 = undefined;
                if ((try reader.readAll(&count_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const count = std.mem.readInt(u32, &count_buf, .little);
                var domain_labels = try self.allocator.alloc([]const u8, count);
                for (0..count) |i| {
                    var len_buf: [4]u8 = undefined;
                    if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                    const len = std.mem.readInt(u32, &len_buf, .little);
                    const label = try self.allocator.alloc(u8, len);
                    if ((try reader.readAll(label)) < len) break :blk ext_eval.ExtValue{ .Null = {} };
                    domain_labels[i] = label;
                }
                break :blk ext_eval.ExtValue{ .Domain = url_mod.Domain{ .labels = domain_labels } };
            },
            26 => blk: {
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const len = std.mem.readInt(u32, &len_buf, .little);
                const bytea_data = try self.allocator.alloc(u8, len);
                if ((try reader.readAll(bytea_data)) < len) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Bytea = bytea_data };
            },
            27 => blk: {
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const len = std.mem.readInt(u32, &len_buf, .little);
                const json_data = try self.allocator.alloc(u8, len);
                if ((try reader.readAll(json_data)) < len) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Json = json_data };
            },
            28 => blk: {
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const len = std.mem.readInt(u32, &len_buf, .little);
                const jsonb_data = try self.allocator.alloc(u8, len);
                if ((try reader.readAll(jsonb_data)) < len) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Jsonb = jsonb_mod.JsonbDocument{ .data = jsonb_data, .allocator = self.allocator } };
            },
            29 => blk: {
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const len = std.mem.readInt(u32, &len_buf, .little);
                const xml_data = try self.allocator.alloc(u8, len);
                if ((try reader.readAll(xml_data)) < len) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Xml = xml_mod.XmlDocument{ .data = xml_data } };
            },
            30 => blk: {
                var bit_len_buf: [8]u8 = undefined;
                if ((try reader.readAll(&bit_len_buf)) < 8) break :blk ext_eval.ExtValue{ .Null = {} };
                var byte_len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&byte_len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const byte_len = std.mem.readInt(u32, &byte_len_buf, .little);
                const bytes = try self.allocator.alloc(u8, byte_len);
                if ((try reader.readAll(bytes)) < byte_len) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .BitString = bitstring_mod.BitString{ .bytes = bytes, .bit_length = @intCast(std.mem.readInt(u64, &bit_len_buf, .little)) } };
            },
            31 => blk: {
                var bit_len_buf: [8]u8 = undefined;
                if ((try reader.readAll(&bit_len_buf)) < 8) break :blk ext_eval.ExtValue{ .Null = {} };
                var byte_len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&byte_len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const byte_len = std.mem.readInt(u32, &byte_len_buf, .little);
                const bytes = try self.allocator.alloc(u8, byte_len);
                if ((try reader.readAll(bytes)) < byte_len) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .VarBit = bitstring_mod.BitString{ .bytes = bytes, .bit_length = @intCast(std.mem.readInt(u64, &bit_len_buf, .little)) } };
            },
            32 => blk: {
                var buf: [9]u8 = undefined;
                if ((try reader.readAll(&buf)) < 9) break :blk ext_eval.ExtValue{ .Null = {} };
                const lower = std.mem.readInt(i32, buf[0..4], .little);
                const upper = std.mem.readInt(i32, buf[4..8], .little);
                const bounds: range_mod.IntRange.Bounds = @enumFromInt(buf[8]);
                break :blk ext_eval.ExtValue{ .IntRange = range_mod.IntRange{ .lower = lower, .upper = upper, .bounds = bounds } };
            },
            33 => blk: {
                var buf: [8]u8 = undefined;
                if ((try reader.readAll(&buf)) < 8) break :blk ext_eval.ExtValue{ .Null = {} };
                const type_id = std.mem.readInt(u32, buf[0..4], .little);
                const value_ordinal = std.mem.readInt(u32, buf[4..8], .little);
                break :blk ext_eval.ExtValue{ .Enum = .{ .type_id = type_id, .value_ordinal = value_ordinal } };
            },
            else => ext_eval.ExtValue{ .Null = {} },
        };
    }

    // CANARY: REQ=REQ-TDE-GRAPHSTORE-002; FEATURE="TDEFileLevelEncryption"; ASPECT=GraphStoreSave; STATUS=TESTED; OWNER=security; UPDATED=2026-02-25
    // CANARY: REQ=REQ-STREAM-SERIALIZE-001; FEATURE="StreamingSerialization"; ASPECT=SaveToFile; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-25
    // Streaming file-based persistence — serializes directly to a temp file,
    // then applies CRC + optional TDE encryption + atomic rename.
    // Eliminates the in-memory serialization buffer that caused OOM on large graphs (#538).
    pub fn saveToFile(self: *GraphStore) !void {
        const file_path = try getPersistenceFilePath(self.allocator);
        defer self.allocator.free(file_path);

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{file_path});
        defer self.allocator.free(tmp_path);

        try self.serializeToTempFile(tmp_path);
        try finalizeTempFile(self.allocator, tmp_path, file_path);

        // Clear dirty flag after successful save
        self.dirty = false;
    }

    /// Serialize graph state directly to a temp file using streaming I/O.
    /// Computes CRC32 incrementally as data is written — no in-memory buffer.
    /// Callers must hold the store lock for the duration of this call.
    // CANARY: REQ=REQ-STREAM-SERIALIZE-002; FEATURE="StreamingSerialization"; ASPECT=StreamToFile; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-25
    pub fn serializeToTempFile(self: *GraphStore, tmp_path: []const u8) !void {
        const file = std.fs.cwd().createFile(tmp_path, .{}) catch |err| {
            log.err("failed to create temp file for serialization", &.{
                Attr.string("path", tmp_path),
                Attr.string("error", @errorName(err)),
            });
            return err;
        };
        defer file.close();

        var hasher = crc.Crc32.init();
        var writer = file.deprecatedWriter();

        // Write header placeholder (CRC patched after payload is written)
        var header: [HEADER_LEN]u8 = [_]u8{0} ** HEADER_LEN;
        @memcpy(header[0..8], "GEODGST1");
        std.mem.writeInt(u32, header[8..12], PERSIST_VERSION, .little);
        std.mem.writeInt(u32, header[12..16], 0, .little);
        std.mem.writeInt(u64, header[16..24], self.next_node_id, .little);
        std.mem.writeInt(u64, header[24..32], self.next_edge_id, .little);
        std.mem.writeInt(u64, header[32..40], self.graphs.count(), .little);
        std.mem.writeInt(u64, header[40..48], self.nodes.count(), .little);
        std.mem.writeInt(u64, header[48..56], self.edges.count(), .little);
        try writer.writeAll(&header);
        // Note: header is NOT included in CRC (matches existing format)

        // Serialize payload (graphs, nodes, edges) — feeds hasher incrementally
        try self.serializePayload(writer, &hasher);

        // Seek back and patch CRC into header at offset 56
        const checksum = hasher.final();
        try file.seekTo(56);
        var crc_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_buf, checksum, .little);
        try file.writeAll(&crc_buf);
    }

    /// Finalize a temp file: apply TDE encryption if enabled, then atomically
    /// rename to the final path. Does NOT require the store lock.
    // CANARY: REQ=REQ-STREAM-SERIALIZE-003; FEATURE="StreamingSerialization"; ASPECT=AtomicRename; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-25
    fn finalizeTempFile(allocator: std.mem.Allocator, tmp_path: []const u8, final_path: []const u8) !void {
        if (tde.isEnabled(allocator)) {
            // TDE enabled: read plaintext temp file, encrypt, write to final path.
            // This still allocates memory for encryption but avoids holding the
            // serialization buffer AND encrypted copy simultaneously with the store lock.
            const plaintext = std.fs.cwd().readFileAlloc(allocator, tmp_path, 1 << 30) catch |err| {
                log.err("failed to read temp file for TDE encryption", &.{
                    Attr.string("path", tmp_path),
                    Attr.string("error", @errorName(err)),
                });
                return err;
            };
            defer allocator.free(plaintext);

            try tde.writeEncryptedFile(allocator, final_path, plaintext);

            // Remove temp file after successful encryption
            std.fs.cwd().deleteFile(tmp_path) catch {};
        } else {
            // No TDE: atomic rename — zero extra memory
            std.fs.cwd().rename(tmp_path, final_path) catch |err| {
                log.err("failed to rename temp file to final path", &.{
                    Attr.string("tmp", tmp_path),
                    Attr.string("final", final_path),
                    Attr.string("error", @errorName(err)),
                });
                return err;
            };
        }
    }

    /// Generic payload serialization — writes graph registry, nodes, and edges
    /// to any writer while feeding data to the CRC hasher.
    /// Used by both serializeToTempFile (file writer) and serializeToBuffer (ArrayList writer).
    fn serializePayload(self: *GraphStore, writer: anytype, hasher: *crc.Crc32) !void {
        // Write graph registry
        var graph_iter = self.graphs.iterator();
        while (graph_iter.next()) |entry| {
            const name = entry.key_ptr.*;
            if (name.len > std.math.maxInt(u32)) return error.GraphNameTooLong;
            var name_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &name_len_buf, @intCast(name.len), .little);
            hasher.update(&name_len_buf);
            try writer.writeAll(&name_len_buf);
            hasher.update(name);
            try writer.writeAll(name);
        }

        // Write each node
        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr;
            // Write node ID
            var id_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &id_buf, node.id, .little);
            hasher.update(&id_buf);
            try writer.writeAll(&id_buf);

            // Write label count
            var label_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &label_count_buf, @intCast(node.labels.len), .little);
            hasher.update(&label_count_buf);
            try writer.writeAll(&label_count_buf);

            // Write each label
            for (node.labels) |label| {
                if (label.len > std.math.maxInt(u32)) {
                    return error.LabelTooLong;
                }
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @as(u32, @intCast(label.len)), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(label);
                try writer.writeAll(label);
            }

            // Write property count
            var prop_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &prop_count_buf, @intCast(node.properties.count()), .little);
            hasher.update(&prop_count_buf);
            try writer.writeAll(&prop_count_buf);

            // Write each property
            var prop_iter = node.properties.iterator();
            while (prop_iter.next()) |prop| {
                try writePropertyToWriter(self, writer, hasher, prop.key_ptr.*, prop.value_ptr.*);
            }

            // CANARY: REQ=REQ-MULTI-GRAPH-006; FEATURE="MultiGraphIsolation"; ASPECT=NodeGraphNamePersistence; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-24
            // Write graph_name length and graph_name for multi-graph isolation
            var graph_name_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &graph_name_len_buf, @intCast(node.graph_name.len), .little);
            hasher.update(&graph_name_len_buf);
            try writer.writeAll(&graph_name_len_buf);
            hasher.update(node.graph_name);
            try writer.writeAll(node.graph_name);
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
            hasher.update(&edge_buf);
            try writer.writeAll(&edge_buf);

            // Write label
            var label_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &label_len_buf, @intCast(edge.label.len), .little);
            hasher.update(&label_len_buf);
            try writer.writeAll(&label_len_buf);
            hasher.update(edge.label);
            try writer.writeAll(edge.label);

            // Write property count
            var prop_count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &prop_count_buf, @intCast(edge.properties.count()), .little);
            hasher.update(&prop_count_buf);
            try writer.writeAll(&prop_count_buf);

            // Write each property
            var prop_iter = edge.properties.iterator();
            while (prop_iter.next()) |prop| {
                try writePropertyToWriter(self, writer, hasher, prop.key_ptr.*, prop.value_ptr.*);
            }

            // CANARY: REQ=REQ-MULTI-GRAPH-007; FEATURE="MultiGraphIsolation"; ASPECT=EdgeGraphNamePersistence; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-24
            // Write graph_name length and graph_name for multi-graph isolation
            var graph_name_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &graph_name_len_buf, @intCast(edge.graph_name.len), .little);
            hasher.update(&graph_name_len_buf);
            try writer.writeAll(&graph_name_len_buf);
            hasher.update(edge.graph_name);
            try writer.writeAll(edge.graph_name);
        }
    }

    /// Write a single property (key + value) to any writer with CRC hashing.
    fn writePropertyToWriter(self: *GraphStore, writer: anytype, hasher: *crc.Crc32, key: []const u8, value: PropertyValue) !void {
        // Write key length and key
        var key_len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &key_len_buf, @intCast(key.len), .little);
        hasher.update(&key_len_buf);
        try writer.writeAll(&key_len_buf);
        hasher.update(key);
        try writer.writeAll(key);

        // Write value type and value
        const val_type: u8 = switch (value) {
            .String => 0,
            .Int => 1,
            .Float => 2,
            .Bool => 3,
            .Null => 4,
            .ExtValue => 5,
            .Decimal => 6,
        };
        hasher.update(&[1]u8{val_type});
        try writer.writeAll(&[1]u8{val_type});

        switch (value) {
            .String => |s| {
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(s.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(s);
                try writer.writeAll(s);
            },
            .Int => |i| {
                var int_buf: [8]u8 = undefined;
                std.mem.writeInt(i64, &int_buf, i, .little);
                hasher.update(&int_buf);
                try writer.writeAll(&int_buf);
            },
            .Float => |f| {
                var float_buf: [8]u8 = undefined;
                std.mem.writeInt(u64, &float_buf, @bitCast(f), .little);
                hasher.update(&float_buf);
                try writer.writeAll(&float_buf);
            },
            .Bool => |b| {
                const byte = [1]u8{if (b) 1 else 0};
                hasher.update(&byte);
                try writer.writeAll(&byte);
            },
            .Null => {},
            .ExtValue => |ext| {
                try writeExtValueToWriter(self, writer, hasher, ext);
            },
            .Decimal => |d| {
                var buf: [17]u8 = undefined;
                std.mem.writeInt(i128, buf[0..16], d.coeff, .little);
                buf[16] = d.scale;
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
        }
    }

    /// Serialize graph state into an in-memory buffer (nodes, edges, properties).
    /// Callers must hold the store lock for the duration of this call.
    /// The returned buffer owns its memory and has no references back to the graph.
    /// NOTE: Prefer serializeToTempFile() for large graphs to avoid OOM (#538).
    pub fn serializeToBuffer(self: *GraphStore) !std.ArrayList(u8) {
        // Pre-allocate based on last known size to avoid reallocation churn.
        const estimated_size = @max(
            @as(usize, 4096),
            self.nodes.count() * 200 + self.edges.count() * 150 + HEADER_LEN,
        );
        var buffer = try std.ArrayList(u8).initCapacity(self.allocator, estimated_size);

        // Write header placeholder
        var header: [HEADER_LEN]u8 = [_]u8{0} ** HEADER_LEN;
        @memcpy(header[0..8], "GEODGST1");
        std.mem.writeInt(u32, header[8..12], PERSIST_VERSION, .little);
        std.mem.writeInt(u32, header[12..16], 0, .little);
        std.mem.writeInt(u64, header[16..24], self.next_node_id, .little);
        std.mem.writeInt(u64, header[24..32], self.next_edge_id, .little);
        std.mem.writeInt(u64, header[32..40], self.graphs.count(), .little);
        std.mem.writeInt(u64, header[40..48], self.nodes.count(), .little);
        std.mem.writeInt(u64, header[48..56], self.edges.count(), .little);
        try buffer.appendSlice(self.allocator, &header);

        // Serialize payload using generic writer, computing CRC
        var hasher = crc.Crc32.init();
        try self.serializePayload(buffer.writer(self.allocator), &hasher);

        // Patch CRC into header
        const checksum = hasher.final();
        std.mem.writeInt(u32, buffer.items[56..60], checksum, .little);

        return buffer;
    }

    /// Finalize a serialized buffer (CRC, encrypt, write to disk).
    /// Does NOT require the store lock — operates only on the standalone buffer.
    /// DEPRECATED: Use serializeToTempFile + finalizeTempFile instead.
    fn finalizeAndWriteBuffer(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), file_path: []const u8) !void {
        // Compute checksum over payload (after header) and fill header slot
        if (buffer.items.len >= HEADER_LEN) {
            const checksum = crc.Crc32.hash(buffer.items[HEADER_LEN..]);
            std.mem.writeInt(u32, buffer.items[56..60], checksum, .little);
        }

        // Encrypt and write to file using TDE
        try tde.writeEncryptedFile(allocator, file_path, buffer.items);
    }

    // CANARY: REQ=REQ-BINARY-PERSIST-DIRTY-002; FEATURE="BinaryPersistence"; ASPECT=ConditionalSave; STATUS=IMPL; OWNER=storage; UPDATED=2026-02-02
    /// Save to file only if there are unsaved changes (dirty flag is set)
    /// This should be called after query completion, not after every individual mutation
    pub fn saveIfDirty(self: *GraphStore) void {
        const file_path = getPersistenceFilePath(self.allocator) catch "/tmp/geode_graph_store.dat";
        defer if (file_path.len > 0 and file_path.ptr != "/tmp/geode_graph_store.dat".ptr) self.allocator.free(file_path);
        log.debug("saveIfDirty called", &.{
            Attr.string("dirty", if (self.dirty) "true" else "false"),
            Attr.int("node_count", @intCast(self.nodes.count())),
            Attr.string("path", file_path),
        });
        if (self.dirty) {
            log.debug("saving graph store", &.{
                Attr.string("path", file_path),
            });
            self.saveToFile() catch |err| {
                log.err("failed to persist graph store", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.string("path", file_path),
                });
            };
            log.debug("save completed", &.{
                Attr.string("dirty", if (self.dirty) "true" else "false"),
            });
        }
    }

    // CANARY: REQ=REQ-TDE-GRAPHSTORE-003; FEATURE="TDEFileLevelEncryption"; ASPECT=GraphStoreLoad; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
    // CANARY: REQ=REQ-BINARY-PERSIST-LOAD-001; FEATURE="BinaryPersistence"; ASPECT=LoadFromFile; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-02
    pub fn loadFromFile(self: *GraphStore) !void {
        const file_path = try getPersistenceFilePath(self.allocator);
        defer self.allocator.free(file_path);

        // Check if file exists first
        std.fs.cwd().access(file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };

        // Read and decrypt file using TDE
        const data = try tde.readDecryptedFile(self.allocator, file_path);
        defer self.allocator.free(data);

        // Create stream to read from decrypted data
        var stream = std.io.fixedBufferStream(data);
        var reader = stream.reader();

        // Reset current state before loading
        self.clearNodes();
        last_checksum_error = false;

        if (data.len < HEADER_LEN) return error.InvalidHeader;
        if (!std.mem.eql(u8, data[0..8], "GEODGST1")) {
            last_checksum_error = true;
            return error.InvalidMagic;
        }

        const version = std.mem.readInt(u32, data[8..12], .little);
        if (version != PERSIST_VERSION) {
            return error.UnsupportedVersion;
        }
        const checksum_stored = std.mem.readInt(u32, data[56..60], .little);
        const checksum_actual = crc.Crc32.hash(data[HEADER_LEN..]);
        if (checksum_actual != checksum_stored) {
            last_checksum_error = true;
            return error.ChecksumMismatch;
        }

        var node_count: u64 = 0;
        var edge_count: u64 = 0;
        self.next_node_id = std.mem.readInt(u64, data[16..24], .little);
        self.next_edge_id = std.mem.readInt(u64, data[24..32], .little);
        const graph_count = std.mem.readInt(u64, data[32..40], .little);
        node_count = std.mem.readInt(u64, data[40..48], .little);
        edge_count = std.mem.readInt(u64, data[48..56], .little);

        // Reset graph registry and load from file
        var graph_iter = self.graphs.iterator();
        while (graph_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.graphs.deinit();
        self.graphs = std.StringHashMap(void).init(self.allocator);

        // Advance reader past header
        stream.pos = HEADER_LEN;

        var graphs_read: u64 = 0;
        while (graphs_read < graph_count) : (graphs_read += 1) {
            var name_len_buf: [4]u8 = undefined;
            if ((try reader.readAll(&name_len_buf)) < 4) break;
            const name_len = std.mem.readInt(u32, &name_len_buf, .little);

            const name_data = try self.allocator.alloc(u8, name_len);
            if ((try reader.readAll(name_data)) < name_len) {
                self.allocator.free(name_data);
                break;
            }
            try self.graphs.put(name_data, {});
        }

        if (self.graphs.count() == 0) {
            const default_name = try self.allocator.dupe(u8, "default");
            try self.graphs.put(default_name, {});
        }

        // Read nodes
        var nodes_read: u64 = 0;
        while (nodes_read < node_count) : (nodes_read += 1) {
            // Read node ID
            var id_buf: [8]u8 = undefined;
            if ((try reader.readAll(&id_buf)) < 8) break;
            const node_id = std.mem.readInt(u64, &id_buf, .little);

            // Read label count
            var label_count_buf: [4]u8 = undefined;
            if ((try reader.readAll(&label_count_buf)) < 4) break;
            const label_count = std.mem.readInt(u32, &label_count_buf, .little);

            // Read labels
            var labels = try self.allocator.alloc([]const u8, label_count);
            for (0..label_count) |i| {
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break;
                const label_len = std.mem.readInt(u32, &len_buf, .little);

                const label_data = try self.allocator.alloc(u8, label_len);
                if ((try reader.readAll(label_data)) < label_len) break;
                labels[i] = label_data;
            }

            // Read property count
            var prop_count_buf: [4]u8 = undefined;
            if ((try reader.readAll(&prop_count_buf)) < 4) break;
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
                if ((try reader.readAll(&key_len_buf)) < 4) break;
                const key_len = std.mem.readInt(u32, &key_len_buf, .little);

                const key_data = try self.allocator.alloc(u8, key_len);
                if ((try reader.readAll(key_data)) < key_len) break;

                // Read value type
                var val_type_buf: [1]u8 = undefined;
                if ((try reader.readAll(&val_type_buf)) < 1) break;
                const val_type = val_type_buf[0];

                // Read value based on type
                const value = switch (val_type) {
                    0 => blk: { // String
                        var len_buf: [4]u8 = undefined;
                        if ((try reader.readAll(&len_buf)) < 4) break :blk PropertyValue{ .String = "" };
                        const str_len = std.mem.readInt(u32, &len_buf, .little);

                        const str_data = try self.allocator.alloc(u8, str_len);
                        if ((try reader.readAll(str_data)) < str_len) break :blk PropertyValue{ .String = "" };
                        break :blk PropertyValue{ .String = str_data };
                    },
                    1 => blk: { // Int
                        var int_buf: [8]u8 = undefined;
                        if ((try reader.readAll(&int_buf)) < 8) break :blk PropertyValue{ .Int = 0 };
                        break :blk PropertyValue{ .Int = std.mem.readInt(i64, &int_buf, .little) };
                    },
                    2 => blk: { // Float
                        var float_buf: [8]u8 = undefined;
                        if ((try reader.readAll(&float_buf)) < 8) break :blk PropertyValue{ .Float = 0.0 };
                        const bits = std.mem.readInt(u64, &float_buf, .little);
                        break :blk PropertyValue{ .Float = @bitCast(bits) };
                    },
                    3 => blk: { // Bool
                        var bool_buf: [1]u8 = undefined;
                        if ((try reader.readAll(&bool_buf)) < 1) break :blk PropertyValue{ .Bool = false };
                        break :blk PropertyValue{ .Bool = bool_buf[0] != 0 };
                    },
                    4 => PropertyValue{ .Null = {} }, // Null
                    5 => PropertyValue{ .ExtValue = try self.readExtValue(reader) },
                    6 => blk: { // Decimal
                        var buf: [17]u8 = undefined;
                        if ((try reader.readAll(&buf)) < 17) break :blk PropertyValue{ .Decimal = .{ .coeff = 0, .scale = 0 } };
                        const coeff = std.mem.readInt(i128, buf[0..16], .little);
                        const scale = buf[16];
                        break :blk PropertyValue{ .Decimal = .{ .coeff = coeff, .scale = scale } };
                    },
                    else => PropertyValue{ .String = "" },
                };

                try node.properties.put(key_data, value);
            }

            // CANARY: REQ=REQ-MULTI-GRAPH-006; FEATURE="MultiGraphIsolation"; ASPECT=NodeGraphNameLoad; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-24
            // Read graph_name for multi-graph isolation
            var graph_name_len_buf: [4]u8 = undefined;
            if ((try reader.readAll(&graph_name_len_buf)) < 4) break;
            const graph_name_len = std.mem.readInt(u32, &graph_name_len_buf, .little);

            const graph_name_data = try self.allocator.alloc(u8, graph_name_len);
            if ((try reader.readAll(graph_name_data)) < graph_name_len) {
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
            if ((try reader.readAll(&edge_buf)) < 24) break;
            const edge_id = std.mem.readInt(u64, edge_buf[0..8], .little);
            const from_id = std.mem.readInt(u64, edge_buf[8..16], .little);
            const to_id = std.mem.readInt(u64, edge_buf[16..24], .little);

            // Read label
            var label_len_buf: [4]u8 = undefined;
            if ((try reader.readAll(&label_len_buf)) < 4) break;
            const label_len = std.mem.readInt(u32, &label_len_buf, .little);

            const label_data = try self.allocator.alloc(u8, label_len);
            if ((try reader.readAll(label_data)) < label_len) break;

            // Read property count
            var prop_count_buf: [4]u8 = undefined;
            if ((try reader.readAll(&prop_count_buf)) < 4) break;
            const prop_count = std.mem.readInt(u32, &prop_count_buf, .little);

            // Create edge with properties HashMap
            var properties = std.StringHashMap(PropertyValue).init(self.allocator);

            // Read each property
            var props_read: u32 = 0;
            while (props_read < prop_count) : (props_read += 1) {
                // Read key length and key
                var key_len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&key_len_buf)) < 4) break;
                const key_len = std.mem.readInt(u32, &key_len_buf, .little);

                const key_data = try self.allocator.alloc(u8, key_len);
                if ((try reader.readAll(key_data)) < key_len) break;

                // Read value type
                var val_type_buf: [1]u8 = undefined;
                if ((try reader.readAll(&val_type_buf)) < 1) break;
                const val_type = val_type_buf[0];

                // Read value based on type
                const value = switch (val_type) {
                    0 => blk: { // String
                        var len_buf: [4]u8 = undefined;
                        if ((try reader.readAll(&len_buf)) < 4) break :blk PropertyValue{ .String = "" };
                        const str_len = std.mem.readInt(u32, &len_buf, .little);
                        const str_data = try self.allocator.alloc(u8, str_len);
                        if ((try reader.readAll(str_data)) < str_len) break :blk PropertyValue{ .String = "" };
                        break :blk PropertyValue{ .String = str_data };
                    },
                    1 => blk: { // Int
                        var int_buf: [8]u8 = undefined;
                        if ((try reader.readAll(&int_buf)) < 8) break :blk PropertyValue{ .Int = 0 };
                        break :blk PropertyValue{ .Int = std.mem.readInt(i64, &int_buf, .little) };
                    },
                    2 => blk: { // Float
                        var float_buf: [8]u8 = undefined;
                        if ((try reader.readAll(&float_buf)) < 8) break :blk PropertyValue{ .Float = 0.0 };
                        const bits = std.mem.readInt(u64, &float_buf, .little);
                        break :blk PropertyValue{ .Float = @bitCast(bits) };
                    },
                    3 => blk: { // Bool
                        var bool_buf: [1]u8 = undefined;
                        if ((try reader.readAll(&bool_buf)) < 1) break :blk PropertyValue{ .Bool = false };
                        break :blk PropertyValue{ .Bool = bool_buf[0] != 0 };
                    },
                    4 => PropertyValue{ .Null = {} }, // Null
                    5 => PropertyValue{ .ExtValue = try self.readExtValue(reader) },
                    6 => blk: { // Decimal
                        var buf: [17]u8 = undefined;
                        if ((try reader.readAll(&buf)) < 17) break :blk PropertyValue{ .Decimal = .{ .coeff = 0, .scale = 0 } };
                        const coeff = std.mem.readInt(i128, buf[0..16], .little);
                        const scale = buf[16];
                        break :blk PropertyValue{ .Decimal = .{ .coeff = coeff, .scale = scale } };
                    },
                    else => PropertyValue{ .String = "" },
                };

                try properties.put(key_data, value);
            }

            // CANARY: REQ=REQ-MULTI-GRAPH-007; FEATURE="MultiGraphIsolation"; ASPECT=EdgeGraphNameLoad; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-24
            // Read graph_name for multi-graph isolation
            var graph_name_len_buf: [4]u8 = undefined;
            if ((try reader.readAll(&graph_name_len_buf)) < 4) break;
            const graph_name_len = std.mem.readInt(u32, &graph_name_len_buf, .little);

            const graph_name_data = try self.allocator.alloc(u8, graph_name_len);
            if ((try reader.readAll(graph_name_data)) < graph_name_len) {
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

        // Rebuild indexes after load
        try self.rebuildIndexes();
        self.dirty = false;
    }

    // CANARY: REQ=REQ-TXN-UNDO-002; FEATURE="TransactionUndoLog"; ASPECT=NoSaveOperations; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
    // NoSave versions of mutation methods for transaction undo/redo operations
    // These methods modify the store without triggering auto-save to disk

    /// Delete a node without saving (used during rollback)
    pub fn deleteNodeNoSave(self: *GraphStore, node_id: u64) void {
        const node_ptr = self.nodes.getPtr(node_id) orelse return;

        // Collect connected edges first
        var edge_ids = std.ArrayList(u64){};
        defer edge_ids.deinit(self.allocator);

        if (self.outgoing_edges.get(node_id)) |outgoing| {
            edge_ids.appendSlice(self.allocator, outgoing.items) catch {};
        }
        if (self.incoming_edges.get(node_id)) |incoming| {
            for (incoming.items) |edge_id| {
                var exists = false;
                for (edge_ids.items) |existing| {
                    if (existing == edge_id) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) {
                    edge_ids.append(self.allocator, edge_id) catch {};
                }
            }
        }

        // Remove connected edges
        for (edge_ids.items) |edge_id| {
            self.deleteEdgeNoSave(edge_id);
        }

        // Remove node from label index
        for (node_ptr.labels) |label| {
            self.removeFromLabelIndex(node_ptr.graph_name, label, node_id);
        }

        // Free labels
        for (node_ptr.labels) |label| {
            self.allocator.free(label);
        }
        self.allocator.free(node_ptr.labels);
        // Free graph_name
        if (node_ptr.graph_name.len > 0) {
            self.allocator.free(node_ptr.graph_name);
        }
        // Free properties
        var prop_iter = node_ptr.properties.iterator();
        while (prop_iter.next()) |prop_entry| {
            self.allocator.free(prop_entry.key_ptr.*);
            freePropertyValue(self, prop_entry.value_ptr.*);
        }
        node_ptr.properties.deinit();
        _ = self.nodes.remove(node_id);

        // Remove adjacency lists for this node
        if (self.outgoing_edges.fetchRemove(node_id)) |kv| {
            var list_copy = kv.value;
            list_copy.deinit(self.allocator);
        }
        if (self.incoming_edges.fetchRemove(node_id)) |kv| {
            var list_copy = kv.value;
            list_copy.deinit(self.allocator);
        }
    }

    /// Delete an edge without saving (used during rollback)
    pub fn deleteEdgeNoSave(self: *GraphStore, edge_id: u64) void {
        if (self.edges.fetchRemove(edge_id)) |kv| {
            var edge = kv.value;

            self.removeFromAdjacencyIndex(edge.from_id, edge.to_id, edge_id);

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
                freePropertyValue(self, prop_entry.value_ptr.*);
            }
            edge.properties.deinit();
        }
    }

    /// Delete a node and mark store dirty
    pub fn deleteNode(self: *GraphStore, node_id: u64) void {
        // Capture graph_name before deletion for WAL notification
        const gn = if (self.nodes.get(node_id)) |n| n.graph_name else "";
        self.deleteNodeNoSave(node_id);
        self.dirty = true;
        // WAL notification: DeleteNode
        notifyMutation(.delete_node, node_id, 0, 0, null, null, null, gn);
    }

    /// Delete an edge and mark store dirty
    pub fn deleteEdge(self: *GraphStore, edge_id: u64) void {
        // Capture graph_name before deletion for WAL notification
        const gn = if (self.edges.get(edge_id)) |e| e.graph_name else "";
        self.deleteEdgeNoSave(edge_id);
        self.dirty = true;
        // WAL notification: DeleteEdge
        notifyMutation(.delete_edge, edge_id, 0, 0, null, null, null, gn);
    }

    /// Set a node property without saving (used during rollback)
    pub fn setNodePropertyNoSave(self: *GraphStore, node_id: u64, key: []const u8, value: PropertyValue) !void {
        if (self.nodes.getPtr(node_id)) |node| {
            const value_copy = try copyPropertyValue(self, value);
            errdefer freePropertyValue(self, value_copy);

            const result = try node.properties.getOrPut(key);
            if (!result.found_existing) {
                result.key_ptr.* = try self.allocator.dupe(u8, key);
            } else {
                freePropertyValue(self, result.value_ptr.*);
            }
            result.value_ptr.* = value_copy;
        }
    }

    /// Remove a node property without saving (used during rollback)
    pub fn removeNodePropertyNoSave(self: *GraphStore, node_id: u64, key: []const u8) void {
        if (self.nodes.getPtr(node_id)) |node| {
            if (node.properties.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                freePropertyValue(self, kv.value);
            }
        }
    }

    /// Set an edge property without saving (used during rollback)
    pub fn setEdgePropertyNoSave(self: *GraphStore, edge_id: u64, key: []const u8, value: PropertyValue) !void {
        if (self.edges.getPtr(edge_id)) |edge| {
            const value_copy = try copyPropertyValue(self, value);
            errdefer freePropertyValue(self, value_copy);

            const result = try edge.properties.getOrPut(key);
            if (!result.found_existing) {
                result.key_ptr.* = try self.allocator.dupe(u8, key);
            } else {
                freePropertyValue(self, result.value_ptr.*);
            }
            result.value_ptr.* = value_copy;
        }
    }

    /// Remove an edge property without saving (used during rollback)
    pub fn removeEdgePropertyNoSave(self: *GraphStore, edge_id: u64, key: []const u8) void {
        if (self.edges.getPtr(edge_id)) |edge| {
            if (edge.properties.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                freePropertyValue(self, kv.value);
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

        try self.ensureGraph(graph_name);
        for (labels) |label| {
            try self.addToLabelIndex(graph_name, label, node_id);
        }
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

        try self.ensureGraph(graph_name);
        try self.addToAdjacencyIndex(from_id, to_id, edge_id);
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

            try self.addToLabelIndex(node.graph_name, label, node_id);
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

                self.removeFromLabelIndex(node.graph_name, label, node_id);
            }
        }
    }
};

// Global instance that persists across queries
var global_store: ?GraphStore = null;
var global_arena: ?std.heap.ArenaAllocator = null;
var initialized = false;
var last_data_dir: ?[]u8 = null;

/// GAP-0259/0260: RwLock replaces Mutex so query threads (shared readers) don't
/// block each other — only the persistence thread takes an exclusive write lock.
/// CANARY: REQ=REQ-GAP-0259-RWLOCK-001; FEATURE="AsyncPersistence"; ASPECT=RwLockMigration; STATUS=IMPL; OWNER=storage; UPDATED=2026-02-13
var g_store_rwlock: std.Thread.RwLock = .{};

// CANARY: REQ=REQ-PERF-PLAN-LIFECYCLE-006; FEATURE="PlanCacheLifecycle"; ASPECT=SchemaEpoch; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
/// Issue #452: Schema epoch counter for plan cache invalidation.
/// Incremented on DDL operations (CREATE/DROP INDEX, schema changes).
/// Plan cache entries created at an older epoch are treated as stale.
var g_schema_epoch: u64 = 0;

/// Get the current schema epoch (for plan cache invalidation checks)
pub fn getSchemaEpoch() u64 {
    return g_schema_epoch;
}

/// Increment the schema epoch (called on DDL: CREATE/DROP INDEX, etc.)
pub fn bumpSchemaEpoch() void {
    g_schema_epoch += 1;
}

// CANARY: REQ=REQ-PERF-WAL-002; FEATURE="WriteAheadLog"; ASPECT=MutationCallback; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-17
// Issue #445: Mutation notification callback for WAL integration.
// Instead of instrumenting every mutation call site, the store's mutation functions
// call this callback after each successful mutation. The WAL installs a callback
// to emit WAL records. A guard flag prevents re-emission during WAL replay.
pub const MutationOp = enum(u8) {
    create_node = 1,
    create_edge = 2,
    set_node_property = 3,
    remove_node_property = 4,
    set_edge_property = 5,
    remove_edge_property = 6,
    delete_node = 7,
    delete_edge = 8,
    add_node_label = 9,
    remove_node_label = 10,
};

/// Callback signature for mutation notifications.
/// Parameters: op, id1 (node/edge), id2 (to_id for edges, 0 otherwise),
/// label/key (context string), value (for property ops), graph_name
pub const MutationNotifyFn = *const fn (
    op: MutationOp,
    id1: u64,
    id2: u64,
    id3: u64,
    label: ?[]const u8,
    key: ?[]const u8,
    value: ?PropertyValue,
    graph_name: ?[]const u8,
) void;

var g_mutation_notify: ?MutationNotifyFn = null;
var g_mutation_notify_inhibit: bool = false;

/// Set the mutation notification callback (used by WAL to capture mutations)
pub fn setMutationNotify(f: ?MutationNotifyFn) void {
    g_mutation_notify = f;
}

/// Inhibit/enable mutation notifications (set during WAL replay to prevent re-emission)
pub fn setMutationNotifyInhibit(inhibit: bool) void {
    g_mutation_notify_inhibit = inhibit;
}

/// Invoke the mutation callback if installed and not inhibited
inline fn notifyMutation(op: MutationOp, id1: u64, id2: u64, id3: u64, label: ?[]const u8, key: ?[]const u8, value: ?PropertyValue, graph_name: ?[]const u8) void {
    if (g_mutation_notify) |notify| {
        if (!g_mutation_notify_inhibit) {
            notify(op, id1, id2, id3, label, key, value, graph_name);
        }
    }
}

// CANARY: REQ=REQ-PERF-WAL-003; FEATURE="WriteAheadLog"; ASPECT=PersistenceHooks; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-17
// Issue #445: WAL persistence hooks — function pointers set by wal.zig to avoid circular imports.
// The persistence loop calls these instead of always doing a full saveToFile().
pub const WalSyncFn = *const fn () void;
pub const WalNeedsCheckpointFn = *const fn () bool;
pub const WalCheckpointFn = *const fn (*GraphStore) void;

var g_wal_sync_fn: ?WalSyncFn = null;
var g_wal_needs_checkpoint_fn: ?WalNeedsCheckpointFn = null;
var g_wal_checkpoint_fn: ?WalCheckpointFn = null;

/// Set WAL persistence hooks (called by wal.zig during initialization)
pub fn setWalPersistenceHooks(
    sync_fn: ?WalSyncFn,
    needs_checkpoint_fn: ?WalNeedsCheckpointFn,
    checkpoint_fn: ?WalCheckpointFn,
) void {
    g_wal_sync_fn = sync_fn;
    g_wal_needs_checkpoint_fn = needs_checkpoint_fn;
    g_wal_checkpoint_fn = checkpoint_fn;
}

/// Condition variable + mutex pair for signalling the persistence thread
/// instead of sleep-polling.
var g_persist_cond: std.Thread.Condition = .{};
var g_persist_cond_mutex: std.Thread.Mutex = .{};

/// Atomic dirty flag so query threads can set it without holding any lock.
/// CANARY: REQ=REQ-GAP-0260-ATOMIC-DIRTY-001; FEATURE="AsyncPersistence"; ASPECT=AtomicDirty; STATUS=IMPL; OWNER=storage; UPDATED=2026-02-13
var g_atomic_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Acquire the global store lock (shared — for read-only query handlers).
/// GAP-0001: Mutation operations must use acquireStoreWriteLock() instead
/// to prevent concurrent HashMap rehash races (CWE-362, CWE-416).
pub fn acquireStoreLock() void {
    g_store_rwlock.lockShared();
}

/// Release the global store lock (shared)
pub fn releaseStoreLock() void {
    g_store_rwlock.unlockShared();
}

/// Acquire exclusive write lock (for mutations and persistence thread)
pub fn acquireStoreWriteLock() void {
    g_store_rwlock.lock();
}

/// Release exclusive write lock
pub fn releaseStoreWriteLock() void {
    g_store_rwlock.unlock();
}

/// Signal the background persistence thread to wake up and flush.
/// Call this instead of saveIfDirty() in hot paths (commit/rollback).
/// CANARY: REQ=REQ-GAP-0260-SIGNAL-001; FEATURE="AsyncPersistence"; ASPECT=SignalPersistence; STATUS=IMPL; OWNER=storage; UPDATED=2026-02-13
pub fn signalPersistence() void {
    g_atomic_dirty.store(true, .release);
    g_persist_cond_mutex.lock();
    defer g_persist_cond_mutex.unlock();
    g_persist_cond.signal();
}

/// P2-3: Global allocator for persistent graph store data (better than page_allocator)
var global_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var global_allocator_init = false;

// GAP-0260: Background persistence thread for write coalescing
// CANARY: REQ=REQ-GAP-0260-PERSIST-001; FEATURE="DeferredPersistence"; ASPECT=WriteCoalescing; STATUS=IMPL; OWNER=storage; UPDATED=2026-02-09
var g_persist_thread: ?std.Thread = null;
var g_persist_shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var g_persist_interval_ms: u64 = 100;

/// Start the background persistence thread that periodically flushes dirty data
pub fn startPersistenceThread(interval_ms: u64) void {
    g_persist_interval_ms = interval_ms;
    g_persist_shutdown.store(false, .release);
    g_persist_thread = std.Thread.spawn(.{}, persistenceLoop, .{}) catch |err| {
        log.warn("failed to start persistence thread", &.{
            Attr.string("error", @errorName(err)),
        });
        return;
    };
}

/// Stop the background persistence thread and perform a final flush
pub fn stopPersistenceThread(allocator: std.mem.Allocator) void {
    g_persist_shutdown.store(true, .release);
    // Wake the persistence thread so it sees the shutdown flag
    g_persist_cond_mutex.lock();
    g_persist_cond.signal();
    g_persist_cond_mutex.unlock();

    if (g_persist_thread) |thread| {
        thread.join();
        g_persist_thread = null;
    }
    // Final flush on shutdown to ensure no data loss
    if (global_store) |*store| {
        _ = allocator;
        store.saveIfDirty();
    }
}

/// GAP-0259/0260: Persistence loop uses condition variable instead of sleep-polling.
/// Wakes on signalPersistence() or every g_persist_interval_ms (fallback).
/// Uses tryLock to avoid blocking query handlers — if the write lock can't be
/// acquired (queries are in progress), retries briefly since signalPersistence()
/// is typically called just before the shared lock is released.
///
/// CANARY: REQ=REQ-PERF-WAL-004; FEATURE="WriteAheadLog"; ASPECT=PersistenceLoop; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-17
/// Issue #445: When WAL is enabled, the persistence loop syncs the WAL (fsync) on every
/// wake instead of doing a full saveToFile(). Full checkpoints (saveToFile + WAL truncate)
/// happen only when the WAL byte threshold or time threshold is exceeded. This reduces
/// I/O from O(N) per commit to O(delta) per commit with periodic O(N) checkpoints.
fn persistenceLoop() void {
    while (!g_persist_shutdown.load(.acquire)) {
        // Wait for signal or timeout
        g_persist_cond_mutex.lock();
        g_persist_cond.timedWait(
            &g_persist_cond_mutex,
            g_persist_interval_ms * std.time.ns_per_ms,
        ) catch {};
        g_persist_cond_mutex.unlock();

        // Check if dirty — use atomic flag first (cheap), then check store.dirty
        // as safety net in case any code path sets store.dirty without signalPersistence()
        const atomic_dirty = g_atomic_dirty.load(.acquire);
        const store_dirty = if (global_store) |*store| store.dirty else false;
        if (!atomic_dirty and !store_dirty) continue;

        // If WAL is enabled, sync WAL first (ensures durability without full save)
        if (g_wal_sync_fn) |sync_fn| {
            sync_fn();
        }

        // Check if a full checkpoint is needed
        const needs_checkpoint = if (g_wal_needs_checkpoint_fn) |cp_fn| cp_fn() else true;

        if (needs_checkpoint) {
            // Try to acquire exclusive write lock. signalPersistence() is called while
            // the QUIC handler still holds a shared lock, so the first tryLock() often
            // fails. Retry a few times with brief sleeps to let the handler release it.
            var locked = false;
            for (0..10) |_| {
                if (g_store_rwlock.tryLock()) {
                    locked = true;
                    break;
                }
                std.Thread.sleep(5 * std.time.ns_per_ms);
            }
            if (!locked) continue;

            if (global_store) |*store| {
                if (store.dirty) {
                    if (g_wal_checkpoint_fn) |checkpoint_fn| {
                        // WAL mode: checkpoint (saveToFile + truncate WAL)
                        checkpoint_fn(store);
                        g_store_rwlock.unlock();
                    } else {
                        // Legacy mode: stream-serialize to temp file under lock,
                        // then release lock before TDE/rename (#538 OOM fix).
                        const file_path = getPersistenceFilePath(store.allocator) catch {
                            g_store_rwlock.unlock();
                            continue;
                        };
                        const tmp_path = std.fmt.allocPrint(store.allocator, "{s}.tmp", .{file_path}) catch {
                            store.allocator.free(file_path);
                            g_store_rwlock.unlock();
                            continue;
                        };
                        store.serializeToTempFile(tmp_path) catch |err| {
                            store.allocator.free(tmp_path);
                            store.allocator.free(file_path);
                            g_store_rwlock.unlock();
                            log.err("background serialize to temp file failed", &.{
                                Attr.string("error", @errorName(err)),
                            });
                            continue;
                        };
                        store.dirty = false;
                        g_store_rwlock.unlock();

                        // TDE encryption and atomic rename happen outside the lock
                        defer store.allocator.free(tmp_path);
                        defer store.allocator.free(file_path);
                        GraphStore.finalizeTempFile(store.allocator, tmp_path, file_path) catch |err| {
                            log.err("background save finalize failed", &.{
                                Attr.string("error", @errorName(err)),
                            });
                        };
                    }
                    // Clear atomic dirty after successful save/checkpoint
                    g_atomic_dirty.store(false, .release);
                } else {
                    g_store_rwlock.unlock();
                }
            } else {
                g_store_rwlock.unlock();
            }
        } else {
            // WAL sync was sufficient — no checkpoint needed yet.
            // Clear atomic dirty since WAL has captured all mutations.
            g_atomic_dirty.store(false, .release);
        }
    }
}

pub fn getGlobalStore(allocator: std.mem.Allocator) *GraphStore {
    // P2-3: Initialize global allocator on first use
    if (!global_allocator_init) {
        global_allocator_init = true;
    }

    // Check if data directory has changed since last initialization
    // Priority: API override > environment variable
    const current_data_dir: ?[]u8 = if (getDataDirOverride()) |override|
        allocator.dupe(u8, override) catch null
    else
        std.process.getEnvVarOwned(allocator, "GEODE_DATA_DIR") catch null;
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
        global_store = GraphStore.init(global_arena.?.allocator()) catch @panic("OOM: failed to initialize global graph store");
        // Try to load existing data from the new location
        global_store.?.loadFromFile() catch |err| {
            log.warn("Failed to load graph store from file (starting fresh)", &.{
                Attr.string("error", @errorName(err)),
            });
        };
        initialized = true;
    }
    return &global_store.?;
}

/// Get the current global store without initializing (returns null if not initialized)
pub fn getCurrentGlobalStore() ?*GraphStore {
    if (initialized and global_store != null) {
        return &global_store.?;
    }
    return null;
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

// Unit tests for label index functionality
// CANARY: REQ=REQ-PERF-LABEL-INDEX-005; FEATURE="LabelBasedIndex"; ASPECT=UnitTests; STATUS=TESTED; TEST=TestLabelIndexBasic; OWNER=perf; UPDATED=2026-01-28

const testing = std.testing;

test "TestLabelIndexBasic" {
    // Issue #391: Test that label index is maintained during node creation
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create a node with label "Person"
    var labels = [_][]const u8{"Person"};
    const node_id = try store.createNodeWithGraph(&labels, "test_graph");

    // Verify we can look up by label
    const result = store.getNodesByLabel("test_graph", "Person");
    try testing.expect(result != null);
    try testing.expect(result.?.len == 1);
    try testing.expect(result.?[0] == node_id);
}

test "TestLabelIndexMultipleNodes" {
    // Issue #391: Test index with multiple nodes having same label
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Person"};
    const node1 = try store.createNodeWithGraph(&labels, "test_graph");
    const node2 = try store.createNodeWithGraph(&labels, "test_graph");
    const node3 = try store.createNodeWithGraph(&labels, "test_graph");

    const result = store.getNodesByLabel("test_graph", "Person");
    try testing.expect(result != null);
    try testing.expect(result.?.len == 3);

    // Check all nodes are present
    var found1 = false;
    var found2 = false;
    var found3 = false;
    for (result.?) |id| {
        if (id == node1) found1 = true;
        if (id == node2) found2 = true;
        if (id == node3) found3 = true;
    }
    try testing.expect(found1 and found2 and found3);
}

test "TestLabelIndexDifferentGraphs" {
    // Issue #391: Test that label index respects graph isolation
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Person"};
    _ = try store.createNodeWithGraph(&labels, "graph1");
    _ = try store.createNodeWithGraph(&labels, "graph2");
    _ = try store.createNodeWithGraph(&labels, "graph1");

    // Query graph1 - should have 2 nodes
    const result1 = store.getNodesByLabel("graph1", "Person");
    try testing.expect(result1 != null);
    try testing.expect(result1.?.len == 2);

    // Query graph2 - should have 1 node
    const result2 = store.getNodesByLabel("graph2", "Person");
    try testing.expect(result2 != null);
    try testing.expect(result2.?.len == 1);
}

test "TestGetNodesByLabels" {
    // Issue #391: Test getting nodes with multiple labels
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create node with multiple labels
    var labels1 = [_][]const u8{ "Person", "Employee" };
    const node1 = try store.createNodeWithGraph(&labels1, "test_graph");

    // Create node with only Person label
    var labels2 = [_][]const u8{"Person"};
    _ = try store.createNodeWithGraph(&labels2, "test_graph");

    // Query for nodes with both Person AND Employee
    var query_labels = [_][]const u8{ "Person", "Employee" };
    var result = try store.getNodesByLabels("test_graph", &query_labels);
    defer result.deinit(testing.allocator);

    try testing.expect(result.items.len == 1);
    try testing.expect(result.items[0] == node1);
}

test "TestEdgeAdjacencyIndex" {
    // Issue #392: Test edge adjacency index for DELETE DETACH optimization
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Node"};
    const node1 = try store.createNodeWithGraph(&labels, "test_graph");
    const node2 = try store.createNodeWithGraph(&labels, "test_graph");
    const node3 = try store.createNodeWithGraph(&labels, "test_graph");

    // Create edges
    _ = try store.createEdgeWithGraph(node1, node2, "CONNECTS", "test_graph");
    _ = try store.createEdgeWithGraph(node1, node3, "CONNECTS", "test_graph");
    _ = try store.createEdgeWithGraph(node2, node3, "LINKS", "test_graph");

    // Test outgoing edges from node1
    const outgoing1 = store.outgoing_edges.get(node1);
    try testing.expect(outgoing1 != null);
    try testing.expect(outgoing1.?.items.len == 2);

    // Test incoming edges to node3
    const incoming3 = store.incoming_edges.get(node3);
    try testing.expect(incoming3 != null);
    try testing.expect(incoming3.?.items.len == 2);

    // Test getEdgesForNode
    var edges_for_node1 = store.getEdgesForNode(node1);
    defer edges_for_node1.deinit(testing.allocator);
    try testing.expect(edges_for_node1.items.len == 2);
}

// ============================================================================
// Streaming serialization tests (Issue #538 OOM fix)
// ============================================================================

test "streaming serialization matches buffer serialization" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    setDataDirOverride(allocator, dir_path);
    defer setDataDirOverride(allocator, null);

    // Build a graph with nodes, edges, and properties
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    var labels_a = [_][]const u8{"Person"};
    var labels_b = [_][]const u8{ "Person", "Employee" };
    const n1 = try store.createNode(&labels_a);
    const n2 = try store.createNode(&labels_b);
    const n3 = try store.createNode(&labels_a);

    try store.setNodeProperty(n1, "name", .{ .String = "Alice" });
    try store.setNodeProperty(n1, "age", .{ .Int = 30 });
    try store.setNodeProperty(n2, "name", .{ .String = "Bob" });
    try store.setNodeProperty(n2, "active", .{ .Bool = true });
    try store.setNodeProperty(n3, "score", .{ .Float = 3.14 });

    _ = try store.createEdge(n1, n2, "KNOWS");
    const e2 = try store.createEdge(n2, n3, "MANAGES");
    try store.setEdgeProperty(e2, "since", .{ .Int = 2024 });

    // Serialize to buffer (old method)
    var buffer = try store.serializeToBuffer();
    defer buffer.deinit(allocator);

    // Serialize to temp file (new streaming method)
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}/stream_test.tmp", .{dir_path});
    defer allocator.free(tmp_path);
    try store.serializeToTempFile(tmp_path);

    // Read temp file back
    const file_data = try std.fs.cwd().readFileAlloc(allocator, tmp_path, 1 << 30);
    defer allocator.free(file_data);

    // Both should produce identical bytes
    try std.testing.expectEqual(buffer.items.len, file_data.len);
    try std.testing.expectEqualSlices(u8, buffer.items, file_data);
}

test "streaming serialization CRC integrity" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    setDataDirOverride(allocator, dir_path);
    defer setDataDirOverride(allocator, null);

    var store = try GraphStore.init(allocator);
    defer store.deinit();

    var labels = [_][]const u8{"TestNode"};
    const n1 = try store.createNode(&labels);
    try store.setNodeProperty(n1, "value", .{ .String = "test-data" });

    // Serialize to temp file
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}/crc_test.tmp", .{dir_path});
    defer allocator.free(tmp_path);
    try store.serializeToTempFile(tmp_path);

    // Read file and verify CRC
    const data = try std.fs.cwd().readFileAlloc(allocator, tmp_path, 1 << 30);
    defer allocator.free(data);

    try std.testing.expect(data.len >= HEADER_LEN);
    try std.testing.expect(std.mem.eql(u8, data[0..8], "GEODGST1"));

    const stored_crc = std.mem.readInt(u32, data[56..60], .little);
    const computed_crc = crc.Crc32.hash(data[HEADER_LEN..]);
    try std.testing.expectEqual(computed_crc, stored_crc);
}

test "streaming serialization roundtrip with loadFromFile" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    setDataDirOverride(allocator, dir_path);
    defer setDataDirOverride(allocator, null);

    // Create and populate a store
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    var labels_a = [_][]const u8{"City"};
    const c1 = try store.createNode(&labels_a);
    const c2 = try store.createNode(&labels_a);
    try store.setNodeProperty(c1, "name", .{ .String = "Seattle" });
    try store.setNodeProperty(c1, "pop", .{ .Int = 750000 });
    try store.setNodeProperty(c2, "name", .{ .String = "Portland" });
    try store.setNodeProperty(c2, "pop", .{ .Int = 650000 });

    const e1 = try store.createEdge(c1, c2, "CONNECTED_BY");
    try store.setEdgeProperty(e1, "distance_km", .{ .Float = 280.0 });

    // Save using streaming serialization
    try store.saveToFile();

    // Load into a new store
    var store2 = try GraphStore.init(allocator);
    defer store2.deinit();
    try store2.loadFromFile();

    // Verify data survived
    try std.testing.expectEqual(store.nodes.count(), store2.nodes.count());
    try std.testing.expectEqual(store.edges.count(), store2.edges.count());

    // Verify node properties
    const loaded_node = store2.nodes.get(c1);
    try std.testing.expect(loaded_node != null);
    const name_val = loaded_node.?.properties.get("name");
    try std.testing.expect(name_val != null);
    try std.testing.expectEqualStrings("Seattle", name_val.?.String);
}

test "streaming serialization large graph bounded memory" {
    // Verify that serializeToTempFile works for a graph with many nodes
    // without allocating a large in-memory buffer.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    setDataDirOverride(allocator, dir_path);
    defer setDataDirOverride(allocator, null);

    var store = try GraphStore.init(allocator);
    defer store.deinit();

    // Create 1000 nodes with properties
    var labels = [_][]const u8{"BulkNode"};
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const nid = try store.createNode(&labels);
        // Use Int property (no heap allocation needed for value)
        try store.setNodeProperty(nid, "idx", .{ .Int = @intCast(i) });
    }

    // Create edges between consecutive nodes
    i = 0;
    while (i < 999) : (i += 1) {
        _ = try store.createEdge(@intCast(i + 1), @intCast(i + 2), "NEXT");
    }

    // Streaming serialize — should succeed without OOM
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}/large_test.tmp", .{dir_path});
    defer allocator.free(tmp_path);
    try store.serializeToTempFile(tmp_path);

    // Verify file is valid by loading it
    try store.saveToFile();
    var store2 = try GraphStore.init(allocator);
    defer store2.deinit();
    try store2.loadFromFile();
    try std.testing.expectEqual(@as(usize, 1000), store2.nodes.count());
    try std.testing.expectEqual(@as(usize, 999), store2.edges.count());
}
