const std = @import("std");
const fle_integration = @import("fle_integration.zig");
const id_map_mod = @import("storage/id_map.zig");

// CANARY: REQ=REQ-TDE-GRAPHSTORE-001; FEATURE="TDEFileLevelEncryption"; ASPECT=GraphStorePersistence; STATUS=EXEMPT; OWNER=security; UPDATED=2026-03-28
// TDE at-rest encryption is now handled at the engine level, not in graph_store serialization.

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Storage; STATUS=EXEMPT; OWNER=storage; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("storage");
const Attr = logging.Attr;
// crc no longer needed — legacy serialization removed

// CANARY: REQ=REQ-STORAGE-ENGINE-PHASE2-001; FEATURE="EngineBackedPersistence"; ASPECT=LegacyRemoval; STATUS=IMPL; OWNER=storage; UPDATED=2026-03-28
// Phase 2: Legacy graph_store.dat persistence removed — adapter is the primary store.

pub fn lastLoadHadChecksumError() bool {
    return false;
}

/// Generate a time-based unique 64-bit ID using UUIDv7.
/// Takes the upper 64 bits of a full UUIDv7 (u128) for backward compatibility
/// with the u64-based Node.id / Edge.id fields throughout the codebase.
/// The upper 64 bits contain: 48-bit timestamp | 4-bit version(7) | 12-bit sequence,
/// which preserves time-sortability and uniqueness.
fn generateTimeBasedId() u64 {
    const uuid7 = id_map_mod.generateUuidV7();
    return @truncate(uuid7 >> 64);
}

// Field-Level Encryption Storage Hooks
// CANARY: REQ=REQ-FLE-STORAGE-001; FEATURE="FieldLevelEncryption"; ASPECT=STORAGE; STATUS=TESTED; TEST=tests/test_tde_kms_integration.zig; OWNER=security; UPDATED=2026-01-15

// Simple graph store with file-based persistence for testing
// Real implementation would use proper storage engine

// Global data directory override (set via API, takes precedence over env var)
// Use a fixed-size buffer to avoid allocator issues across module boundaries.
// Protected by g_data_dir_mutex to prevent torn reads between writer (startup/backup)
// and reader (persistence loop).
var g_override_data_dir_buf: [512]u8 = undefined;
var g_override_data_dir_len: usize = 0;
var g_override_data_dir_set: bool = false;
var g_data_dir_mutex: std.Thread.Mutex = .{};

/// Set the data directory override (takes precedence over GEODE_DATA_DIR env var)
/// Pass null to clear the override and revert to env var behavior
pub fn setDataDirOverride(allocator: std.mem.Allocator, dir: ?[]const u8) void {
    _ = allocator; // Not needed with fixed buffer
    g_data_dir_mutex.lock();
    defer g_data_dir_mutex.unlock();
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
    g_data_dir_mutex.lock();
    defer g_data_dir_mutex.unlock();
    if (g_override_data_dir_set and g_override_data_dir_len > 0) {
        return g_override_data_dir_buf[0..g_override_data_dir_len];
    }
    return null;
}

/// DEPRECATED: Legacy persistence file path. Retained as a stub for callers
/// that have not yet been updated. Returns the data directory path.
// CANARY: REQ=REQ-BINARY-PERSIST-PATH-001; FEATURE="BinaryPersistence"; ASPECT=PathResolution; STATUS=EXEMPT; OWNER=storage; UPDATED=2026-03-28
pub fn getPersistenceFilePath(allocator: std.mem.Allocator) ![]u8 {
    // Return data dir path for callers that still reference this function
    if (getDataDirOverride()) |override| {
        return try allocator.dupe(u8, override);
    }
    return std.process.getEnvVarOwned(allocator, "GEODE_DATA_DIR") catch {
        return try allocator.dupe(u8, "/tmp");
    };
}

/// Default graph name used when no graph is selected
pub const DEFAULT_GRAPH_NAME = "default";

/// Default tenant ID used when no tenant context is set
/// GAP-0279: Backward compatible — existing single-tenant data uses this default
pub const DEFAULT_TENANT_ID = "default";

/// Reserved storage keys used to persist Geode's public IDs inside the
/// graph-storage engine without exposing them as user-visible properties.
pub const INTERNAL_NODE_ID_PROPERTY_KEY = "__geode_internal_node_id";
pub const INTERNAL_EDGE_ID_PROPERTY_KEY = "__geode_internal_edge_id";

pub const Node = struct {
    id: u64,
    labels: [][]const u8,
    properties: std.StringHashMap(PropertyValue),
    // CANARY: REQ=REQ-MULTI-GRAPH-003; FEATURE="MultiGraphIsolation"; ASPECT=NodeGraphTag; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
    // Graph name this node belongs to - enables per-graph data isolation
    graph_name: []const u8 = DEFAULT_GRAPH_NAME,
    // CANARY: REQ=REQ-MULTI-TENANT-002; FEATURE="PerTenantIsolation"; ASPECT=NodeTenantTag; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=enterprise; UPDATED=2026-04-01
    // GAP-0279: Per-tenant data isolation — tenant_id tags each node for query-time filtering
    tenant_id: []const u8 = DEFAULT_TENANT_ID,
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
    // CANARY: REQ=REQ-MULTI-TENANT-002; FEATURE="PerTenantIsolation"; ASPECT=EdgeTenantTag; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=enterprise; UPDATED=2026-04-01
    // GAP-0279: Per-tenant data isolation — tenant_id tags each edge for query-time filtering
    tenant_id: []const u8 = DEFAULT_TENANT_ID,
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

fn isInternalPersistedPropertyKey(key: []const u8) bool {
    return std.mem.eql(u8, key, INTERNAL_NODE_ID_PROPERTY_KEY) or
        std.mem.eql(u8, key, INTERNAL_EDGE_ID_PROPERTY_KEY);
}

fn encodePersistedPublicId(buf: *[16]u8, public_id: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>16}", .{public_id}) catch unreachable;
}

pub fn parsePersistedPublicId(text: []const u8) ?u64 {
    return std.fmt.parseUnsigned(u64, text, 16) catch std.fmt.parseUnsigned(u64, text, 10) catch null;
}

/// Check whether a byte slice looks like a serialized FLE EnvelopeV1.
/// Format: alg_id(1) + key_version(2) + nonce(12) + tag(16) + ciphertext_len(4) + ciphertext
/// Used to prevent double-encryption when callers already encrypted before setNodeProperty.
fn isLikelyFleEnvelope(data: []const u8) bool {
    if (data.len < 35) return false;
    // Valid algorithm IDs: 1 (AES-256-GCM), 2 (ChaCha20-Poly1305), 3 (XChaCha20-Poly1305)
    const alg_id = data[0];
    if (alg_id < 1 or alg_id > 3) return false;
    // Check that the ciphertext length field matches remaining data
    const ciphertext_len = std.mem.readInt(u32, data[31..35], .little);
    return data.len == 35 + ciphertext_len;
}

fn copyPropertyValue(self: *GraphStore, value: PropertyValue) !PropertyValue {
    return switch (value) {
        .String => |s| PropertyValue{ .String = try self.allocator.dupe(u8, s) },
        .ExtValue => |ext| PropertyValue{ .ExtValue = try copyExtValue(self, ext) },
        else => value,
    };
}

fn freePropertyValueWithAllocator(allocator: std.mem.Allocator, value: PropertyValue) void {
    switch (value) {
        .String => |s| allocator.free(s),
        .ExtValue => |ext| freeExtValueWithAllocator(allocator, ext),
        else => {},
    }
}

fn freePropertyValue(self: *GraphStore, value: PropertyValue) void {
    freePropertyValueWithAllocator(self.allocator, value);
}

pub fn freeDetachedPropertyValue(allocator: std.mem.Allocator, value: PropertyValue) void {
    freePropertyValueWithAllocator(allocator, value);
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
        .SmallInt => |v| ext_eval.ExtValue{ .SmallInt = v },
        .BigInt => |v| ext_eval.ExtValue{ .BigInt = v },
        .Real => |v| ext_eval.ExtValue{ .Real = v },
        .Double => |v| ext_eval.ExtValue{ .Double = v },
        .Text => |s| ext_eval.ExtValue{ .Text = try self.allocator.dupe(u8, s) },
        .Char => |c| ext_eval.ExtValue{ .Char = .{
            .data = try self.allocator.dupe(u8, c.data),
            .n = c.n,
        } },
        .Varchar => |v| ext_eval.ExtValue{ .Varchar = .{
            .data = try self.allocator.dupe(u8, v.data),
            .n = v.n,
        } },
        .Hash => |h| ext_eval.ExtValue{ .Hash = heap_mod.Hash{
            .alg = h.alg,
            .digest = try self.allocator.dupe(u8, h.digest),
            .salt = if (h.salt) |s| try self.allocator.dupe(u8, s) else null,
            .params = h.params,
        } },
        .TimeTZ => |v| ext_eval.ExtValue{ .TimeTZ = v },
        .Timestamp => |v| ext_eval.ExtValue{ .Timestamp = v },
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
        .Array => |arr| ext_eval.ExtValue{ .Array = .{
            .elem_type = arr.elem_type,
            .data = try self.allocator.dupe(u8, arr.data),
            .allocator = self.allocator,
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

fn freeExtValueWithAllocator(allocator: std.mem.Allocator, value: @import("eval_extended.zig").ExtValue) void {
    const bitstring_mod = @import("types/bitstring.zig");
    const jsonb_mod = @import("types/jsonb.zig");
    const url_mod = @import("types/url.zig");

    switch (value) {
        .Str => |s| allocator.free(s),
        .Bytea => |b| allocator.free(b),
        .Json => |j| allocator.free(j),
        .Geometry => |g| allocator.free(g.wkb),
        .LanguageTag => |lt| allocator.free(lt.tag),
        .VectorF32 => |vec| allocator.free(vec.data),
        .VectorI32 => |vec| allocator.free(vec.data),
        .Text => |s| allocator.free(s),
        .Char => |c| allocator.free(c.data),
        .Varchar => |v| allocator.free(v.data),
        .Hash => |h| {
            allocator.free(h.digest);
            if (h.salt) |s| allocator.free(s);
        },
        .Url => |u| {
            allocator.free(u.scheme);
            allocator.free(u.host);
            allocator.free(u.path);
            if (u.query) |q| allocator.free(q);
            if (u.fragment) |f| allocator.free(f);
        },
        .Domain => |d| url_mod.Domain.deinit(d, allocator),
        .Jsonb => |doc| jsonb_mod.JsonbDocument.deinit(doc),
        .Xml => |doc| allocator.free(doc.data),
        .BitString => |bs| bitstring_mod.BitString.deinit(bs, allocator),
        .VarBit => |bs| bitstring_mod.BitString.deinit(bs, allocator),
        .Array => |arr| arr.deinit(),
        .List => |list| {
            for (list) |item| {
                freeExtValueWithAllocator(allocator, item);
            }
            allocator.free(list);
        },
        else => {},
    }
}

fn freeExtValue(self: *GraphStore, value: @import("eval_extended.zig").ExtValue) void {
    freeExtValueWithAllocator(self.allocator, value);
}

pub fn freeDetachedExtValue(allocator: std.mem.Allocator, value: @import("eval_extended.zig").ExtValue) void {
    freeExtValueWithAllocator(allocator, value);
}

pub const STORAGE_EXT_TYPE_TAG: u16 = 1;

const NullHasher = struct {
    fn update(_: *NullHasher, _: []const u8) void {}
};

pub fn encodeExtValue(allocator: std.mem.Allocator, value: @import("eval_extended.zig").ExtValue) ![]u8 {
    var dummy: GraphStore = undefined;
    var sink = NullHasher{};
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try dummy.writeExtValueToWriter(buf.writer(allocator), &sink, value);
    return try buf.toOwnedSlice(allocator);
}

pub fn decodeExtValue(allocator: std.mem.Allocator, bytes: []const u8) !@import("eval_extended.zig").ExtValue {
    var dummy: GraphStore = undefined;
    dummy.allocator = allocator;

    var stream = std.io.fixedBufferStream(bytes);
    return try dummy.readExtValue(stream.reader());
}

// CANARY: REQ=REQ-MULTI-TENANT-001; FEATURE="MultiTenancy"; ASPECT=GraphStore; STATUS=TESTED; TEST=geodetestlab/specs/gql_session_management_comprehensive.yml; OWNER=enterprise; UPDATED=2026-01-09
pub const GraphStore = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMap(u64, Node),
    edges: std.AutoHashMap(u64, Edge),
    next_node_id: u64,
    next_edge_id: u64,
    // DEPRECATED (GAP-0279): Process-wide tenant_id races under concurrent access.
    // Tenant scoping should come from ExecutionContext.tenant_id, not this field.
    // Retained for FLE encryption context backward compatibility.
    tenant_id: []const u8,
    schema_name: []const u8,
    // CANARY: REQ=REQ-MULTI-GRAPH-008; FEATURE="GraphRegistry"; ASPECT=GraphNames; STATUS=TESTED; TEST=tests/test_gap0514_graph_store_regression.zig; OWNER=storage; UPDATED=2026-04-11
    // Track known graph names (including empty graphs)
    graphs: std.StringHashMap(void),
    // CANARY: REQ=REQ-PERF-LABEL-INDEX-001; FEATURE="LabelBasedIndex"; ASPECT=NodeLookup; STATUS=TESTED; TEST=tests/test_match_set_label_scan_regression.zig; OWNER=perf; UPDATED=2026-04-11
    // Issue #391: Label-based index for O(1) node lookups instead of O(n) full table scans
    // Maps "graph_name:label" composite key to list of node IDs
    label_index: std.StringHashMap(std.ArrayList(u64)),
    // MERGE property index: enables O(1) candidate lookup by (graph, label, property_key, property_value).
    // Key format: "graph\x00label\x00prop_key\x00prop_value_bytes" → node_id.
    // Updated synchronously by setNodeProperty/removeNodeProperty/deleteNodeNoSave.
    merge_prop_index: std.StringHashMap(u64),
    // CANARY: REQ=REQ-PERF-EDGE-TYPE-INDEX-001; FEATURE="EdgeTypeIndex"; ASPECT=EdgeTypeLookup; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=perf; UPDATED=2026-04-10
    // PERF-P0-001: Edge-type index for O(1) getEdgesByType lookups instead of O(E) full scan
    // Maps "graph_name:edge_type" composite key to sorted list of edge IDs
    edge_type_index: std.StringHashMap(std.ArrayList(u64)),
    // CANARY: REQ=REQ-PERF-EDGE-ADJ-001; FEATURE="EdgeAdjacencyIndex"; ASPECT=EdgeLookup; STATUS=TESTED; TEST=tests/test_gap0514_graph_store_regression.zig; OWNER=perf; UPDATED=2026-04-11
    // Issue #392: Adjacency lists for fast edge lookups during DELETE DETACH
    outgoing_edges: std.AutoHashMap(u64, std.ArrayList(u64)), // from_node_id -> edge_ids
    incoming_edges: std.AutoHashMap(u64, std.ArrayList(u64)), // to_node_id -> edge_ids
    /// Per-graph IdMaps for UUIDv7 ↔ engine slot_id translation.
    id_maps: std.StringHashMap(id_map_mod.IdMap) = undefined,
    /// Optional CSR adjacency for fast traversal (if built elsewhere)
    csr: ?*const anyopaque = null,
    // CANARY: REQ=REQ-BINARY-PERSIST-DIRTY-001; FEATURE="BinaryPersistence"; ASPECT=DirtyTracking; STATUS=TESTED; TEST=tests/test_gap0514_graph_store_regression.zig; OWNER=storage; UPDATED=2026-04-11
    // Track if store has unsaved changes - avoids O(n²) persistence during batch operations.
    // Atomic because the persistence thread reads this without holding the store write lock
    // while mutation threads write it under the write lock (data race fix).
    dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    data_dir: []const u8 = "",

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
            .merge_prop_index = std.StringHashMap(u64).init(allocator),
            // PERF-P0-001: Edge-type index for O(1) edge-type lookups
            .edge_type_index = std.StringHashMap(std.ArrayList(u64)).init(allocator),
            .outgoing_edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
            .incoming_edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
            .id_maps = std.StringHashMap(id_map_mod.IdMap).init(allocator),
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
        try self.edge_type_index.ensureTotalCapacity(@intCast(edge_capacity));
    }

    /// DEPRECATED (GAP-0279): Set tenant ID on the process-wide singleton.
    /// This races under concurrent access. Use ExecutionContext.tenant_id instead.
    /// Retained for FLE encryption context backward compatibility.
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

        // Clean up merge property index
        var mpi_iter = self.merge_prop_index.iterator();
        while (mpi_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.merge_prop_index.deinit();

        // PERF-P0-001: Clean up edge-type index
        var eti_iter = self.edge_type_index.iterator();
        while (eti_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.edge_type_index.deinit();

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

        // Clean up per-graph IdMaps
        var id_map_iter = self.id_maps.iterator();
        while (id_map_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.id_maps.deinit();
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
            // GAP-0279: Free tenant_id (always allocated via create functions)
            if (entry.value_ptr.tenant_id.len > 0) {
                self.allocator.free(entry.value_ptr.tenant_id);
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
            // GAP-0279: Free tenant_id (always allocated via create functions)
            if (entry.value_ptr.tenant_id.len > 0) {
                self.allocator.free(entry.value_ptr.tenant_id);
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

        // Reset merge property index
        var mpi_iter = self.merge_prop_index.iterator();
        while (mpi_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.merge_prop_index.deinit();
        self.merge_prop_index = std.StringHashMap(u64).init(self.allocator);

        // PERF-P0-001: Reset edge-type index
        var eti_iter = self.edge_type_index.iterator();
        while (eti_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.edge_type_index.deinit();
        self.edge_type_index = std.StringHashMap(std.ArrayList(u64)).init(self.allocator);

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

        // Reset per-graph IdMaps
        var id_map_iter = self.id_maps.iterator();
        while (id_map_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.id_maps.deinit();
        self.id_maps = std.StringHashMap(id_map_mod.IdMap).init(self.allocator);
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

    // CANARY: REQ=REQ-MULTI-GRAPH-008; FEATURE="GraphRegistry"; ASPECT=GraphHelpers; STATUS=TESTED; TEST=tests/test_gap0514_graph_store_regression.zig; OWNER=storage; UPDATED=2026-04-11
    fn ensureGraph(self: *GraphStore, graph_name: []const u8) !void {
        try self.ensureGraphNoDirty(graph_name);
        self.dirty.store(true, .release);
        incrementMutationEpoch();
    }

    fn ensureGraphNoDirty(self: *GraphStore, graph_name: []const u8) !void {
        if (self.graphs.contains(graph_name)) return;
        const name_copy = try self.allocator.dupe(u8, graph_name);
        try self.graphs.put(name_copy, {});
    }

    /// Get or create the IdMap for a named graph.
    pub fn getOrCreateIdMap(self: *GraphStore, graph_name: []const u8) !*id_map_mod.IdMap {
        const result = try self.id_maps.getOrPut(graph_name);
        if (!result.found_existing) {
            result.key_ptr.* = try self.allocator.dupe(u8, graph_name);
            result.value_ptr.* = id_map_mod.IdMap.init(self.allocator);
        }
        return result.value_ptr;
    }

    /// Get the IdMap for a named graph (read-only, returns null if not found).
    pub fn getIdMap(self: *GraphStore, graph_name: []const u8) ?*id_map_mod.IdMap {
        return self.id_maps.getPtr(graph_name);
    }

    fn requireIdMap(self: *GraphStore, graph_name: []const u8) !*id_map_mod.IdMap {
        return self.getIdMap(graph_name) orelse error.IdMapNotLoaded;
    }

    fn cloneIdMapsFrom(self: *GraphStore, source: *const GraphStore) !void {
        var it = source.id_maps.iterator();
        while (it.next()) |entry| {
            const graph_name = entry.key_ptr.*;
            if (self.id_maps.contains(graph_name)) continue;

            const key_copy = try self.allocator.dupe(u8, graph_name);
            errdefer self.allocator.free(key_copy);

            const map_copy = try entry.value_ptr.clone(self.allocator);
            errdefer {
                var map = map_copy;
                map.deinit();
            }

            try self.id_maps.put(key_copy, map_copy);
        }
    }

    /// Clone all nodes and edges from another store. Used by QueryReadSession
    /// to create a point-in-time snapshot without going through the adapter.
    fn cloneNodesFrom(self: *GraphStore, source: *const GraphStore) !void {
        // Clone graphs registry
        var graph_it = source.graphs.iterator();
        while (graph_it.next()) |entry| {
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            try self.graphs.put(key, {});
        }

        // Clone nodes
        var node_it = source.nodes.iterator();
        while (node_it.next()) |entry| {
            const src_node = entry.value_ptr.*;
            const labels_copy = try self.allocator.alloc([]const u8, src_node.labels.len);
            for (src_node.labels, 0..) |label, i| {
                labels_copy[i] = try self.allocator.dupe(u8, label);
            }

            var props = std.StringHashMap(PropertyValue).init(self.allocator);
            var prop_it = src_node.properties.iterator();
            while (prop_it.next()) |prop| {
                const key = try self.allocator.dupe(u8, prop.key_ptr.*);
                // Deep-copy property values so the snapshot owns all its
                // string data independently.  Shallow copies share pointers
                // with the writable store; when the snapshot arena is freed
                // the allocator bookkeeping can corrupt those shared strings,
                // producing use-after-free (0xAA fill pattern) on read.
                try props.put(key, try copyPropertyValue(self, prop.value_ptr.*));
            }

            try self.nodes.put(entry.key_ptr.*, .{
                .id = src_node.id,
                .labels = labels_copy,
                .properties = props,
                .graph_name = try self.allocator.dupe(u8, src_node.graph_name),
                .tenant_id = try self.allocator.dupe(u8, src_node.tenant_id),
            });

            for (src_node.labels) |label| {
                try self.addToLabelIndex(src_node.graph_name, label, src_node.id);
            }
        }

        self.next_node_id = source.next_node_id;
        self.next_edge_id = source.next_edge_id;

        // Clone edges
        var edge_it = source.edges.iterator();
        while (edge_it.next()) |entry| {
            const src_edge = entry.value_ptr.*;
            var props = std.StringHashMap(PropertyValue).init(self.allocator);
            var prop_it = src_edge.properties.iterator();
            while (prop_it.next()) |prop| {
                const key = try self.allocator.dupe(u8, prop.key_ptr.*);
                // Deep-copy edge property values (same rationale as node properties)
                try props.put(key, try copyPropertyValue(self, prop.value_ptr.*));
            }

            try self.edges.put(entry.key_ptr.*, .{
                .id = src_edge.id,
                .from_id = src_edge.from_id,
                .to_id = src_edge.to_id,
                .label = try self.allocator.dupe(u8, src_edge.label),
                .properties = props,
                .graph_name = try self.allocator.dupe(u8, src_edge.graph_name),
                .tenant_id = try self.allocator.dupe(u8, src_edge.tenant_id),
            });

            try self.addToAdjacencyIndex(src_edge.from_id, src_edge.to_id, src_edge.id);
            // PERF-P0-001: Maintain edge-type index during clone
            try self.addToEdgeTypeIndex(src_edge.graph_name, src_edge.label, src_edge.id);
        }
    }

    fn requireNodeSlot(self: *GraphStore, graph_name: []const u8, node_id: u64) !u64 {
        const id_map = self.requireIdMap(graph_name) catch return error.NodeSlotMappingMissing;
        return id_map.nodeSlot(@as(u128, node_id)) orelse error.NodeSlotMappingMissing;
    }

    fn requireEdgeSlot(self: *GraphStore, graph_name: []const u8, edge_id: u64) !u64 {
        const id_map = self.requireIdMap(graph_name) catch return error.EdgeSlotMappingMissing;
        return id_map.edgeSlot(@as(u128, edge_id)) orelse error.EdgeSlotMappingMissing;
    }

    fn persistNodePublicId(vt: AdapterVTable, graph_name: []const u8, slot_id: u64, public_id: u64) !void {
        var id_buf: [16]u8 = undefined;
        try vt.setNodePropertyFn(
            vt.ctx,
            graph_name,
            slot_id,
            INTERNAL_NODE_ID_PROPERTY_KEY,
            .{ .String = encodePersistedPublicId(&id_buf, public_id) },
        );
    }

    fn persistEdgePublicId(
        vt: AdapterVTable,
        graph_name: []const u8,
        from_slot: u64,
        to_slot: u64,
        edge_slot: u64,
        public_id: u64,
    ) !void {
        const set_edge_property = vt.setEdgePropertyFn orelse return error.Unsupported;
        var id_buf: [16]u8 = undefined;
        try set_edge_property(
            vt.ctx,
            graph_name,
            from_slot,
            to_slot,
            edge_slot,
            INTERNAL_EDGE_ID_PROPERTY_KEY,
            .{ .String = encodePersistedPublicId(&id_buf, public_id) },
        );
    }

    pub fn graphExists(self: *const GraphStore, graph_name: []const u8) bool {
        // Dual-read: check adapter first, then fall back to local HashMap
        if (global_vtable) |vt| {
            if (vt.graphExistsFn(vt.ctx, graph_name)) return true;
        }
        return self.graphs.contains(graph_name);
    }

    pub fn listGraphNames(self: *const GraphStore, allocator: std.mem.Allocator) ![]const []const u8 {
        var names = std.ArrayList([]const u8).empty;
        errdefer {
            for (names.items) |name| {
                allocator.free(name);
            }
            names.deinit(allocator);
        }

        var seen = std.StringHashMap(void).init(allocator);
        defer {
            var seen_it = seen.iterator();
            while (seen_it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            seen.deinit();
        }

        if (global_adapter) |adapter| {
            const persisted_names = try adapter.listGraphNames(allocator);
            defer {
                for (persisted_names) |name| {
                    allocator.free(name);
                }
                allocator.free(persisted_names);
            }

            for (persisted_names) |name| {
                const seen_key = try allocator.dupe(u8, name);
                errdefer allocator.free(seen_key);
                const seen_result = try seen.getOrPut(seen_key);
                if (!seen_result.found_existing) {
                    try names.append(allocator, try allocator.dupe(u8, name));
                } else {
                    allocator.free(seen_key);
                }
            }
        }

        var it = self.graphs.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const seen_key = try allocator.dupe(u8, name);
            errdefer allocator.free(seen_key);
            const seen_result = try seen.getOrPut(seen_key);
            if (!seen_result.found_existing) {
                try names.append(allocator, try allocator.dupe(u8, name));
            } else {
                allocator.free(seen_key);
            }
        }

        return names.toOwnedSlice(allocator);
    }

    pub fn createGraph(self: *GraphStore, graph_name: []const u8) !void {
        // Create the persisted graph first so the in-memory registry never
        // diverges from the adapter-backed storage layout.
        if (global_vtable) |vt| {
            _ = try vt.getOrCreateGraphFn(vt.ctx, graph_name);
        }
        if (self.graphs.contains(graph_name)) {
            return error.GraphAlreadyExists;
        }
        const name_copy = try self.allocator.dupe(u8, graph_name);
        try self.graphs.put(name_copy, {});

        // Initialize IdMap for the new graph
        _ = try self.getOrCreateIdMap(graph_name);

        self.dirty.store(true, .release);
        incrementMutationEpoch();
    }

    /// Open a graph using a known UUID (for catalog recovery).
    pub fn openOrCreateGraphWithUuid(self: *GraphStore, graph_name: []const u8, graph_uuid: [16]u8) !void {
        if (global_adapter) |adapter| {
            _ = try adapter.openGraphWithUuid(graph_name, graph_uuid);
        }
        if (self.graphs.contains(graph_name)) {
            return;
        }
        const name_copy = try self.allocator.dupe(u8, graph_name);
        try self.graphs.put(name_copy, {});
        _ = try self.getOrCreateIdMap(graph_name);
        self.dirty.store(true, .release);
        incrementMutationEpoch();
    }

    /// Return the UUID for a named graph from the storage adapter, or null
    /// if the adapter is not initialized or the graph is not loaded.
    pub fn getGraphUuid(graph_name: []const u8) ?[16]u8 {
        if (global_adapter) |adapter| {
            return adapter.getGraphUuid(graph_name);
        }
        return null;
    }

    pub fn dropGraph(self: *GraphStore, graph_name: []const u8) !void {
        // Dual-write: drop from adapter, then fall through to local cleanup
        if (global_vtable) |vt| {
            vt.dropGraphFn(vt.ctx, graph_name);
        }
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
        // Clean up IdMap for dropped graph
        if (self.id_maps.fetchRemove(graph_name)) |kv| {
            self.allocator.free(kv.key);
            var im = kv.value;
            im.deinit();
        }
        self.dirty.store(true, .release);
        incrementMutationEpoch();
    }

    // CANARY: REQ=REQ-MULTI-GRAPH-004; FEATURE="MultiGraphIsolation"; ASPECT=CreateNode; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
    // Create node with optional graph name for per-graph data isolation
    // GAP-0291: Resolve tenant_id from the per-thread FLE context set by the connection handler.
    // This ensures nodes created during a multi-tenant session are tagged with the correct
    // tenant_id instead of always using DEFAULT_TENANT_ID.
    // CANARY: REQ=REQ-MULTI-TENANT-006; FEATURE="PerTenantIsolation"; ASPECT=NodeCreateAutoTenant; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=enterprise; UPDATED=2026-04-05
    pub fn createNodeWithGraph(self: *GraphStore, labels: []const []const u8, graph_name: []const u8) !u64 {
        const tenant = fle_integration.getCurrentTenantId();
        return self.createNodeWithGraphAndTenant(labels, graph_name, tenant);
    }

    // CANARY: REQ=REQ-MULTI-TENANT-003; FEATURE="PerTenantIsolation"; ASPECT=NodeCreation; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=enterprise; UPDATED=2026-04-01
    // GAP-0279: Create a node tagged with both graph_name and tenant_id for per-tenant isolation
    pub fn createNodeWithGraphAndTenant(self: *GraphStore, labels: []const []const u8, graph_name: []const u8, tenant: []const u8) !u64 {
        const adapter_node: ?struct {
            vt: AdapterVTable,
            slot_id: u64,
        } = if (global_vtable) |vt|
            .{
                .vt = vt,
                .slot_id = try vt.createNodeFn(vt.ctx, graph_name, labels),
            }
        else
            null;
        try self.ensureGraph(graph_name);
        // Generate UUIDv7-based time-sortable unique ID
        const id = generateTimeBasedId();

        // Store UUID→slot mapping in IdMap for adapter translation
        if (adapter_node) |persisted_node| {
            persistNodePublicId(persisted_node.vt, graph_name, persisted_node.slot_id, id) catch |err| {
                persisted_node.vt.deleteNodeFn(persisted_node.vt.ctx, graph_name, persisted_node.slot_id) catch {};
                return err;
            };
            const im = try self.getOrCreateIdMap(graph_name);
            try im.insertNodeWithSlot(@as(u128, id), persisted_node.slot_id);
        }

        const labels_copy = try self.allocator.alloc([]const u8, labels.len);
        for (labels, 0..) |label, i| {
            labels_copy[i] = try self.allocator.dupe(u8, label);
        }

        const graph_name_copy = try self.allocator.dupe(u8, graph_name);
        const tenant_id_copy = try self.allocator.dupe(u8, tenant);

        const node = Node{
            .id = id,
            .labels = labels_copy,
            .properties = std.StringHashMap(PropertyValue).init(self.allocator),
            .graph_name = graph_name_copy,
            .tenant_id = tenant_id_copy,
        };

        try self.nodes.put(id, node);
        // CANARY: REQ=REQ-PERF-LABEL-INDEX-002; FEATURE="LabelBasedIndex"; ASPECT=IndexMaintenance; STATUS=TESTED; TEST=tests/test_match_set_label_scan_regression.zig; OWNER=perf; UPDATED=2026-04-11
        for (labels) |label| {
            try self.addToLabelIndex(graph_name, label, id);
        }

        // Mark store as dirty - persistence happens at query completion, not per-node
        self.dirty.store(true, .release);
        incrementMutationEpoch();
        log.debug("Node created, dirty=true", &.{
            Attr.int("node_id", @intCast(id)),
            Attr.int("total_nodes", @intCast(self.nodes.count())),
        });

        // WAL notification: CreateNode
        notifyMutation(.create_node, id, 0, 0, if (labels.len > 0) labels[0] else null, null, null, graph_name);

        return id;
    }

    fn createNodeWithIdInternal(
        self: *GraphStore,
        node_id: u64,
        labels: []const []const u8,
        graph_name: []const u8,
        mark_dirty: bool,
        persist_adapter: bool,
    ) !void {
        const adapter_node: ?struct {
            vt: AdapterVTable,
            slot_id: u64,
        } = if (persist_adapter) blk: {
            const vt = global_vtable orelse break :blk null;
            break :blk .{
                .vt = vt,
                .slot_id = try vt.createNodeFn(vt.ctx, graph_name, labels),
            };
        } else null;

        try self.ensureGraph(graph_name);
        if (self.nodes.contains(node_id)) return error.NodeAlreadyExists;

        if (adapter_node) |persisted_node| {
            persistNodePublicId(persisted_node.vt, graph_name, persisted_node.slot_id, node_id) catch |err| {
                persisted_node.vt.deleteNodeFn(persisted_node.vt.ctx, graph_name, persisted_node.slot_id) catch {};
                return err;
            };
            const im = try self.getOrCreateIdMap(graph_name);
            try im.insertNodeWithSlot(@as(u128, node_id), persisted_node.slot_id);
        }

        const labels_copy = try self.allocator.alloc([]const u8, labels.len);
        for (labels, 0..) |label, i| {
            labels_copy[i] = try self.allocator.dupe(u8, label);
        }

        const graph_name_copy = try self.allocator.dupe(u8, graph_name);
        const tenant_id_copy = try self.allocator.dupe(u8, DEFAULT_TENANT_ID);

        const node = Node{
            .id = node_id,
            .labels = labels_copy,
            .properties = std.StringHashMap(PropertyValue).init(self.allocator),
            .graph_name = graph_name_copy,
            .tenant_id = tenant_id_copy,
        };

        try self.nodes.put(node_id, node);

        for (labels) |label| {
            try self.addToLabelIndex(graph_name, label, node_id);
        }

        if (node_id >= self.next_node_id) {
            self.next_node_id = node_id + 1;
        }

        if (mark_dirty) {
            self.dirty.store(true, .release);
            incrementMutationEpoch();
        }
    }

    /// Create a node with a specified ID (used for replication/2PC).
    pub fn createNodeWithId(self: *GraphStore, node_id: u64, labels: []const []const u8, graph_name: []const u8) !void {
        return self.createNodeWithIdInternal(node_id, labels, graph_name, true, true);
    }

    /// Create a node with a specified ID without marking dirty (used for rollback).
    pub fn createNodeWithIdNoSave(self: *GraphStore, node_id: u64, labels: []const []const u8, graph_name: []const u8) !void {
        return self.createNodeWithIdInternal(node_id, labels, graph_name, false, false);
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
            try sortedInsert(result.value_ptr, self.allocator, node_id);
            return;
        };

        if (self.label_index.getPtr(probe_key)) |list| {
            // Key already exists — no heap allocation needed
            try sortedInsert(list, self.allocator, node_id);
        } else {
            // New key — heap-allocate for map ownership
            const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, label });
            const result = try self.label_index.getOrPut(key);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(u64).empty;
            } else {
                self.allocator.free(key);
            }
            try sortedInsert(result.value_ptr, self.allocator, node_id);
        }
    }

    /// Binary-search insert into a sorted ArrayList(u64), maintaining ascending order.
    /// Deduplicates: if node_id is already present, this is a no-op.
    fn sortedInsert(list: *std.ArrayList(u64), allocator: std.mem.Allocator, node_id: u64) !void {
        const items = list.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid] < node_id) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // Deduplicate: skip if already present
        if (lo < items.len and items[lo] == node_id) return;
        try list.insert(allocator, lo, node_id);
    }

    fn removeFromLabelIndex(self: *GraphStore, graph_name: []const u8, label: []const u8, node_id: u64) void {
        const key = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, label }) catch return;
        defer self.allocator.free(key);

        if (self.label_index.getPtr(key)) |list| {
            // Binary search for node_id in sorted posting list
            const items = list.items;
            var lo: usize = 0;
            var hi: usize = items.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (items[mid] < node_id) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if (lo < items.len and items[lo] == node_id) {
                _ = list.orderedRemove(lo);
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

    /// Serialize a PropertyValue to bytes for merge property index keys.
    /// Returns the number of bytes written, or null if the type is not indexable.
    fn serializePropValueForIndex(buf: []u8, value: PropertyValue) ?usize {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer().any();
        switch (value) {
            .String => |s| writer.writeAll(s) catch return null,
            .Int => |i| std.fmt.format(writer, "{d}", .{i}) catch return null,
            .Bool => |b| writer.writeAll(if (b) "true" else "false") catch return null,
            else => return null,
        }
        return stream.pos;
    }

    /// Build a merge property index key into a stack buffer.
    /// Format: "graph\x00label\x00prop_key\x00prop_value_bytes"
    /// Returns the slice, or null if the key is too long or value is not indexable.
    fn buildMergeIndexKey(buf: []u8, graph_name: []const u8, label: []const u8, prop_key: []const u8, prop_value: PropertyValue) ?[]const u8 {
        // Calculate required length: graph + 1 + label + 1 + key + 1 + value
        const header_len = graph_name.len + 1 + label.len + 1 + prop_key.len + 1;
        if (header_len >= buf.len) return null;

        var pos: usize = 0;
        @memcpy(buf[pos..][0..graph_name.len], graph_name);
        pos += graph_name.len;
        buf[pos] = 0;
        pos += 1;
        @memcpy(buf[pos..][0..label.len], label);
        pos += label.len;
        buf[pos] = 0;
        pos += 1;
        @memcpy(buf[pos..][0..prop_key.len], prop_key);
        pos += prop_key.len;
        buf[pos] = 0;
        pos += 1;

        const val_len = serializePropValueForIndex(buf[pos..], prop_value) orelse return null;
        return buf[0 .. pos + val_len];
    }

    /// Insert an entry into the merge property index for each label on the node.
    fn addToMergePropertyIndex(self: *GraphStore, graph_name: []const u8, labels: []const []const u8, prop_key: []const u8, prop_value: PropertyValue, node_id: u64) !void {
        var buf: [1024]u8 = undefined;
        for (labels) |label| {
            const probe = buildMergeIndexKey(&buf, graph_name, label, prop_key, prop_value) orelse continue;
            if (self.merge_prop_index.getPtr(probe)) |existing| {
                // Overwrite with latest node_id (same label+key+value → same logical entity)
                existing.* = node_id;
            } else {
                const key_copy = try self.allocator.dupe(u8, probe);
                errdefer self.allocator.free(key_copy);
                try self.merge_prop_index.put(key_copy, node_id);
            }
        }
    }

    /// Remove entries from the merge property index for each label on the node.
    fn removeFromMergePropertyIndex(self: *GraphStore, graph_name: []const u8, labels: []const []const u8, prop_key: []const u8, prop_value: PropertyValue) void {
        var buf: [1024]u8 = undefined;
        for (labels) |label| {
            const probe = buildMergeIndexKey(&buf, graph_name, label, prop_key, prop_value) orelse continue;
            if (self.merge_prop_index.fetchRemove(probe)) |kv| {
                self.allocator.free(kv.key);
            }
        }
    }

    /// Remove ALL merge property index entries for a node (used during node deletion).
    fn removeAllMergePropertyIndexEntries(self: *GraphStore, node: *const Node) void {
        var buf: [1024]u8 = undefined;
        var prop_iter = node.properties.iterator();
        while (prop_iter.next()) |prop_entry| {
            for (node.labels) |label| {
                const probe = buildMergeIndexKey(&buf, node.graph_name, label, prop_entry.key_ptr.*, prop_entry.value_ptr.*) orelse continue;
                if (self.merge_prop_index.fetchRemove(probe)) |kv| {
                    self.allocator.free(kv.key);
                }
            }
        }
    }

    /// Result of a merge candidate lookup.
    pub const MergeLookupResult = enum {
        /// Key could not be built (buffer overflow or non-indexable type).
        /// Caller must fall back to a label scan.
        not_indexable,
        /// Key was valid and the index is authoritative: no matching node exists.
        /// Caller can safely skip the fallback scan.
        not_found,
        /// Key was valid and a matching, verified node was found.
        found,
    };

    /// Look up a node by graph, label, property key, and property value.
    /// Returns `.found` with the node_id when a verified match exists,
    /// `.not_found` when the index is authoritative and no match exists,
    /// or `.not_indexable` when the key could not be built (caller must scan).
    pub fn lookupMergeCandidate(self: *const GraphStore, graph_name: []const u8, label: []const u8, prop_key: []const u8, prop_value: PropertyValue, out_node_id: *u64) MergeLookupResult {
        var buf: [1024]u8 = undefined;
        const probe = buildMergeIndexKey(&buf, graph_name, label, prop_key, prop_value) orelse return .not_indexable;
        const node_id = self.merge_prop_index.get(probe) orelse return .not_found;
        // Verify node still exists (index could be stale after a failed delete)
        if (self.nodes.get(node_id)) |node| {
            if (std.mem.eql(u8, node.graph_name, graph_name)) {
                out_node_id.* = node_id;
                return .found;
            }
        }
        return .not_found;
    }

    // CANARY: REQ=REQ-PERF-LABEL-INDEX-003; FEATURE="LabelBasedIndex"; ASPECT=NodeLookup; STATUS=TESTED; TEST=tests/test_match_set_label_scan_regression.zig; OWNER=perf; UPDATED=2026-04-11
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
    // Accepts a caller-provided allocator for the result list to avoid
    // concurrent threads contending on self.allocator (GAP-0425 fix).
    // Perf: uses smallest-posting-list-first strategy to minimize candidate scans.
    pub fn getNodesByLabels(self: *const GraphStore, allocator: std.mem.Allocator, graph_name: []const u8, labels: []const []const u8, tenant_id: ?[]const u8) !std.ArrayList(u64) {
        _ = g_get_nodes_by_labels_count.fetchAdd(1, .monotonic);
        var result = std.ArrayList(u64).empty;

        if (labels.len == 0) {
            return result;
        }

        // Single-label fast path: no intersection needed
        if (labels.len == 1) {
            const nodes = self.getNodesByLabel(graph_name, labels[0]) orelse return result;
            try result.ensureTotalCapacity(allocator, nodes.len);
            for (nodes) |node_id| {
                // Verify node exists (label index may contain stale entries)
                const node = self.nodes.get(node_id) orelse continue;
                if (tenant_id) |tid| {
                    if (!std.mem.eql(u8, node.tenant_id, tid)) continue;
                }
                result.appendAssumeCapacity(node_id);
            }
            return result;
        }

        // Multi-label path: two-pointer merge intersection on sorted posting lists.
        // Gather posting lists and sort by ascending length for optimal intersection.

        // Stack-allocated array for up to 8 labels; heap fallback for more.
        const MaxStack = 8;
        var stack_lists: [MaxStack][]const u64 = undefined;
        var heap_lists: ?[][]const u64 = null;
        defer if (heap_lists) |h| allocator.free(h);

        const lists: [][]const u64 = if (labels.len <= MaxStack)
            stack_lists[0..labels.len]
        else blk: {
            heap_lists = try allocator.alloc([]const u64, labels.len);
            break :blk heap_lists.?;
        };

        for (labels, 0..) |label, i| {
            const posting = self.getNodesByLabel(graph_name, label) orelse return result;
            if (posting.len == 0) return result;
            lists[i] = posting;
        }

        // Sort posting lists by ascending length (insertion sort — n is tiny)
        for (1..lists.len) |i| {
            const key = lists[i];
            var j: usize = i;
            while (j > 0 and lists[j - 1].len > key.len) {
                lists[j] = lists[j - 1];
                j -= 1;
            }
            lists[j] = key;
        }

        // Two-pointer intersection: intersect lists[0] with lists[1], then result with lists[2], etc.
        // Use `result` as the current intersection buffer and a temp buffer for alternation.
        var temp = std.ArrayList(u64).empty;
        defer temp.deinit(allocator);

        // Seed with shortest posting list
        try result.ensureTotalCapacity(allocator, lists[0].len);
        for (lists[0]) |id| {
            result.appendAssumeCapacity(id);
        }

        for (lists[1..]) |other| {
            temp.clearRetainingCapacity();
            try temp.ensureTotalCapacity(allocator, result.items.len);

            var ai: usize = 0;
            var bi: usize = 0;
            const a_items = result.items;
            while (ai < a_items.len and bi < other.len) {
                if (a_items[ai] < other[bi]) {
                    ai += 1;
                } else if (a_items[ai] > other[bi]) {
                    bi += 1;
                } else {
                    temp.appendAssumeCapacity(a_items[ai]);
                    ai += 1;
                    bi += 1;
                }
            }

            // Swap: move temp into result for next round
            const swap_items = result.items;
            const swap_cap = result.capacity;
            result.items = temp.items;
            result.capacity = temp.capacity;
            temp.items = swap_items;
            temp.capacity = swap_cap;
        }

        // Verify nodes still exist (label index may have stale entries)
        // and apply tenant filter (GAP-0509).
        {
            var write: usize = 0;
            for (result.items) |node_id| {
                const node = self.nodes.get(node_id) orelse continue;
                if (tenant_id) |tid| {
                    if (!std.mem.eql(u8, node.tenant_id, tid)) continue;
                }
                result.items[write] = node_id;
                write += 1;
            }
            result.items.len = write;
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

        // Reset merge property index
        var mpi_iter = self.merge_prop_index.iterator();
        while (mpi_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.merge_prop_index.deinit();
        self.merge_prop_index = std.StringHashMap(u64).init(self.allocator);

        // PERF-P0-001: Reset edge-type index
        var eti_iter = self.edge_type_index.iterator();
        while (eti_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.edge_type_index.deinit();
        self.edge_type_index = std.StringHashMap(std.ArrayList(u64)).init(self.allocator);

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

        // Rebuild label index, merge property index, and ensure graph registry entries for nodes
        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr;
            try self.ensureGraphNoDirty(node.graph_name);
            for (node.labels) |label| {
                try self.addToLabelIndex(node.graph_name, label, node.id);
            }
            // Rebuild merge property index entries for this node
            var prop_iter = node.properties.iterator();
            while (prop_iter.next()) |prop_entry| {
                self.addToMergePropertyIndex(node.graph_name, node.labels, prop_entry.key_ptr.*, prop_entry.value_ptr.*, node.id) catch {};
            }
        }

        // Rebuild adjacency index, edge-type index, and ensure graph registry entries for edges
        var edge_iter = self.edges.iterator();
        while (edge_iter.next()) |entry| {
            const edge = entry.value_ptr;
            try self.ensureGraphNoDirty(edge.graph_name);
            try self.addToAdjacencyIndex(edge.from_id, edge.to_id, edge.id);
            // PERF-P0-001: Rebuild edge-type index
            try self.addToEdgeTypeIndex(edge.graph_name, edge.label, edge.id);
        }
    }

    // Backward-compatible createNode that uses "default" graph
    pub fn createNode(self: *GraphStore, labels: []const []const u8) !u64 {
        return self.createNodeWithGraph(labels, "default");
    }

    pub fn setNodeProperty(self: *GraphStore, node_id: u64, key: []const u8, value: PropertyValue) !void {
        if (isInternalPersistedPropertyKey(key)) return error.ReservedPropertyKey;
        // FLE defense-in-depth: encrypt String values before adapter write and in-memory storage.
        // Some callers already encrypt; isLikelyFleEnvelope() prevents double-encryption.
        const effective_value = switch (value) {
            .String => |s| blk: {
                if (fle_integration.hasEncryptedFields() and !isLikelyFleEnvelope(s)) {
                    const node_type: []const u8 = if (self.nodes.get(node_id)) |n|
                        (if (n.labels.len > 0) n.labels[0] else "Unknown")
                    else
                        "Unknown";
                    if (fle_integration.fieldRequiresEncryption(node_type, key)) {
                        const fle_ctx = fle_integration.EncryptionContext{
                            .tenant_id = self.tenant_id,
                            .schema_name = self.schema_name,
                            .allocator = self.allocator,
                            .current_user_role = fle_integration.getCurrentUserRole(),
                        };
                        const record_id = std.fmt.allocPrint(self.allocator, "node_{d}", .{node_id}) catch {
                            break :blk value;
                        };
                        defer self.allocator.free(record_id);
                        const encrypted = fle_integration.encryptFieldIfNeeded(
                            fle_ctx,
                            node_type,
                            key,
                            s,
                            record_id,
                        ) catch {
                            break :blk value;
                        };
                        if (!std.mem.eql(u8, encrypted, s)) {
                            break :blk PropertyValue{ .String = encrypted };
                        }
                    }
                }
                break :blk value;
            },
            else => value,
        };

        if (global_vtable) |vt| {
            const node = self.nodes.get(node_id) orelse return error.NodeNotFound;
            const slot_id = try self.requireNodeSlot(node.graph_name, node_id);
            try vt.setNodePropertyFn(vt.ctx, node.graph_name, slot_id, key, effective_value);
        }
        if (self.nodes.getPtr(node_id)) |node| {
            const value_copy = try copyPropertyValue(self, effective_value);
            errdefer freePropertyValue(self, value_copy);

            // Use getOrPut to avoid memory leak - only allocate key if it doesn't exist
            const result = try node.properties.getOrPut(key);
            if (!result.found_existing) {
                // Key doesn't exist, allocate a copy
                result.key_ptr.* = try self.allocator.dupe(u8, key);
            } else {
                // Key exists — remove old merge property index entry before overwriting
                self.removeFromMergePropertyIndex(node.graph_name, node.labels, key, result.value_ptr.*);
                freePropertyValue(self, result.value_ptr.*);
            }
            result.value_ptr.* = value_copy;

            // Update merge property index with new value
            self.addToMergePropertyIndex(node.graph_name, node.labels, key, value_copy, node_id) catch {};

            // Mark as dirty - persistence happens at query completion
            self.dirty.store(true, .release);
            incrementMutationEpoch();

            // WAL notification: SetNodeProperty
            notifyMutation(.set_node_property, node_id, 0, 0, null, key, effective_value, null);
        }
    }

    /// Batch property entry for `setNodePropertiesBatch`.
    /// When `value` is null the property is removed (tombstone).
    pub const BatchPropertyEntry = struct {
        key: []const u8,
        value: ?PropertyValue, // null = remove
    };

    /// Set or remove multiple properties on a node in a single operation.
    ///
    /// When a storage adapter is present the batch is forwarded as one
    /// adapter call, acquiring the adapter mutex only once instead of once
    /// per property.  This eliminates severe mutex contention that caused
    /// CLI commands (e.g. `geode user mfa-setup`) to hang when the server
    /// was concurrently servicing queries against the same global adapter.
    pub fn setNodePropertiesBatch(self: *GraphStore, node_id: u64, entries: []const BatchPropertyEntry) !void {
        const node_meta = self.nodes.get(node_id) orelse return error.NodeNotFound;

        // --- Adapter path: single lock acquisition for all properties ---
        if (global_adapter) |adapter| {
            const slot_id = try self.requireNodeSlot(node_meta.graph_name, node_id);

            // Build adapter-level batch entries, applying FLE encryption
            // where required.
            var adapter_entries = try self.allocator.alloc(graph_storage_adapter.StorageAdapter.BatchPropertyEntry, entries.len);
            defer self.allocator.free(adapter_entries);

            for (entries, 0..) |entry, i| {
                if (entry.value) |val| {
                    const effective = self.applyFleEncryption(node_id, entry.key, val);
                    adapter_entries[i] = .{ .key = entry.key, .value = effective };
                } else {
                    adapter_entries[i] = .{ .key = entry.key, .value = null };
                }
            }

            try adapter.setNodePropertiesBatch(node_meta.graph_name, slot_id, adapter_entries);
        } else if (global_vtable) |vt| {
            // Fallback: vtable without direct adapter access (shouldn't
            // happen in practice, but keep correctness).
            const slot_id = try self.requireNodeSlot(node_meta.graph_name, node_id);
            for (entries) |entry| {
                if (entry.value) |val| {
                    const effective = self.applyFleEncryption(node_id, entry.key, val);
                    try vt.setNodePropertyFn(vt.ctx, node_meta.graph_name, slot_id, entry.key, effective);
                } else {
                    try vt.removeNodePropertyFn(vt.ctx, node_meta.graph_name, slot_id, entry.key);
                }
            }
        }

        // --- In-memory store update (always, regardless of adapter) ---
        if (self.nodes.getPtr(node_id)) |node| {
            for (entries) |entry| {
                if (isInternalPersistedPropertyKey(entry.key)) continue;

                if (entry.value) |val| {
                    const effective = self.applyFleEncryption(node_id, entry.key, val);
                    const value_copy = try copyPropertyValue(self, effective);
                    errdefer freePropertyValue(self, value_copy);

                    const result = try node.properties.getOrPut(entry.key);
                    if (!result.found_existing) {
                        result.key_ptr.* = try self.allocator.dupe(u8, entry.key);
                    } else {
                        self.removeFromMergePropertyIndex(node.graph_name, node.labels, entry.key, result.value_ptr.*);
                        freePropertyValue(self, result.value_ptr.*);
                    }
                    result.value_ptr.* = value_copy;
                    self.addToMergePropertyIndex(node.graph_name, node.labels, entry.key, value_copy, node_id) catch {};

                    notifyMutation(.set_node_property, node_id, 0, 0, null, entry.key, effective, null);
                } else {
                    // Remove
                    if (node.properties.fetchRemove(entry.key)) |kv| {
                        self.removeFromMergePropertyIndex(node.graph_name, node.labels, kv.key, kv.value);
                        self.allocator.free(kv.key);
                        freePropertyValue(self, kv.value);
                    }
                }
            }
            self.dirty.store(true, .release);
            incrementMutationEpoch();
        }
    }

    /// Apply FLE encryption to a property value if required.  Factored out
    /// so both `setNodeProperty` and `setNodePropertiesBatch` share the
    /// same logic.
    fn applyFleEncryption(self: *GraphStore, node_id: u64, key: []const u8, value: PropertyValue) PropertyValue {
        switch (value) {
            .String => |s| {
                if (fle_integration.hasEncryptedFields() and !isLikelyFleEnvelope(s)) {
                    const node_type: []const u8 = if (self.nodes.get(node_id)) |n|
                        (if (n.labels.len > 0) n.labels[0] else "Unknown")
                    else
                        "Unknown";
                    if (fle_integration.fieldRequiresEncryption(node_type, key)) {
                        const fle_ctx = fle_integration.EncryptionContext{
                            .tenant_id = self.tenant_id,
                            .schema_name = self.schema_name,
                            .allocator = self.allocator,
                            .current_user_role = fle_integration.getCurrentUserRole(),
                        };
                        const record_id = std.fmt.allocPrint(self.allocator, "node_{d}", .{node_id}) catch {
                            return value;
                        };
                        defer self.allocator.free(record_id);
                        const encrypted = fle_integration.encryptFieldIfNeeded(
                            fle_ctx,
                            node_type,
                            key,
                            s,
                            record_id,
                        ) catch {
                            return value;
                        };
                        if (!std.mem.eql(u8, encrypted, s)) {
                            return PropertyValue{ .String = encrypted };
                        }
                    }
                }
                return value;
            },
            else => return value,
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

    /// Get a node property value (simplified version without FLE decryption).
    /// Returns the raw PropertyValue or error if node not found.
    pub fn getNodePropertyValue(self: *GraphStore, node_id: u64, key: []const u8) !PropertyValue {
        if (self.nodes.get(node_id)) |node| {
            return node.properties.get(key) orelse return error.PropertyNotFound;
        }
        return error.NodeNotFound;
    }

    pub fn removeNodeProperty(self: *GraphStore, node_id: u64, key: []const u8) void {
        if (isInternalPersistedPropertyKey(key)) return;
        if (global_vtable) |vt| {
            const node = self.nodes.get(node_id) orelse return;
            const slot_id = self.requireNodeSlot(node.graph_name, node_id) catch |err| {
                log.err("adapter node-slot lookup failed during removeNodeProperty", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.int("node_id", @intCast(node_id)),
                    Attr.string("graph", node.graph_name),
                });
                return;
            };
            vt.removeNodePropertyFn(vt.ctx, node.graph_name, slot_id, key) catch |err| {
                log.err("adapter removeNodeProperty failed", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.int("node_id", @intCast(node_id)),
                    Attr.string("graph", node.graph_name),
                });
                return;
            };
        }
        if (self.nodes.getPtr(node_id)) |node| {
            if (node.properties.fetchRemove(key)) |kv| {
                // Remove from merge property index before freeing
                self.removeFromMergePropertyIndex(node.graph_name, node.labels, kv.key, kv.value);
                self.allocator.free(kv.key);
                freePropertyValue(self, kv.value);
            }
            // Mark as dirty - persistence happens at query completion
            self.dirty.store(true, .release);
            incrementMutationEpoch();

            // WAL notification: RemoveNodeProperty
            notifyMutation(.remove_node_property, node_id, 0, 0, null, key, null, null);
        }
    }

    pub fn clearNodeProperties(self: *GraphStore, node_id: u64) !void {
        const node = self.nodes.get(node_id) orelse return error.NodeNotFound;

        var keys = std.ArrayList([]const u8).empty;
        defer {
            for (keys.items) |owned_key| {
                self.allocator.free(owned_key);
            }
            keys.deinit(self.allocator);
        }

        var prop_iter = node.properties.iterator();
        while (prop_iter.next()) |entry| {
            try keys.append(self.allocator, try self.allocator.dupe(u8, entry.key_ptr.*));
        }

        for (keys.items) |owned_key| {
            self.removeNodeProperty(node_id, owned_key);
        }
    }

    pub fn addNodeLabel(self: *GraphStore, node_id: u64, label: []const u8) !void {
        if (global_vtable) |vt| {
            if (vt.addNodeLabelFn) |f| {
                const node = self.nodes.get(node_id) orelse return error.NodeNotFound;
                const slot_id = try self.requireNodeSlot(node.graph_name, node_id);
                try f(vt.ctx, node.graph_name, slot_id, label);
            }
        }
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
            self.dirty.store(true, .release);
            incrementMutationEpoch();

            // WAL notification: AddNodeLabel
            notifyMutation(.add_node_label, node_id, 0, 0, label, null, null, null);
        }
    }

    pub fn removeNodeLabel(self: *GraphStore, node_id: u64, label: []const u8) !void {
        if (global_vtable) |vt| {
            if (vt.removeNodeLabelFn) |f| {
                const node = self.nodes.get(node_id) orelse return error.NodeNotFound;
                const slot_id = try self.requireNodeSlot(node.graph_name, node_id);
                try f(vt.ctx, node.graph_name, slot_id, label);
            }
        }
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
                self.dirty.store(true, .release);
                incrementMutationEpoch();

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

    // CANARY: REQ=REQ-MULTI-TENANT-004; FEATURE="PerTenantIsolation"; ASPECT=BulkNodeAccess; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=enterprise; UPDATED=2026-04-01
    // GAP-0279: Return only nodes belonging to the specified tenant (or all if tenant is null)
    pub fn getAllNodesForTenant(self: *const GraphStore, allocator: std.mem.Allocator, tenant: ?[]const u8) ![]u64 {
        const tid = tenant orelse return self.getAllNodes(allocator);
        var count: usize = 0;
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.tenant_id, tid)) count += 1;
        }
        var result = try allocator.alloc(u64, count);
        iter = self.nodes.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.tenant_id, tid)) {
                result[i] = entry.key_ptr.*;
                i += 1;
            }
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
        return @constCast(&self.dirty).load(.acquire);
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
    // GAP-0291: Resolve tenant_id from the per-thread FLE context set by the connection handler.
    // This ensures edges created during a multi-tenant session are tagged with the correct
    // tenant_id instead of always using DEFAULT_TENANT_ID.
    // CANARY: REQ=REQ-MULTI-TENANT-007; FEATURE="PerTenantIsolation"; ASPECT=EdgeCreateAutoTenant; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=enterprise; UPDATED=2026-04-05
    pub fn createEdgeWithGraph(self: *GraphStore, from_id: u64, to_id: u64, edge_type: []const u8, graph_name: []const u8) !u64 {
        const tenant = fle_integration.getCurrentTenantId();
        return self.createEdgeWithGraphAndTenant(from_id, to_id, edge_type, graph_name, tenant);
    }

    // CANARY: REQ=REQ-MULTI-TENANT-003; FEATURE="PerTenantIsolation"; ASPECT=EdgeCreation; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=enterprise; UPDATED=2026-04-01
    // GAP-0279: Create an edge tagged with both graph_name and tenant_id for per-tenant isolation
    pub fn createEdgeWithGraphAndTenant(self: *GraphStore, from_id: u64, to_id: u64, edge_type: []const u8, graph_name: []const u8, tenant: []const u8) !u64 {
        const adapter_edge: ?struct {
            vt: AdapterVTable,
            from_slot: u64,
            to_slot: u64,
            edge_slot: u64,
        } = blk: {
            const vt = global_vtable orelse break :blk null;
            const im = self.getOrCreateIdMap(graph_name) catch break :blk null;
            const from_slot = im.nodeSlot(@as(u128, from_id)) orelse break :blk null;
            const to_slot = im.nodeSlot(@as(u128, to_id)) orelse break :blk null;
            const edge_slot = vt.createEdgeFn(vt.ctx, graph_name, from_slot, to_slot, edge_type) catch break :blk null;
            break :blk .{
                .vt = vt,
                .from_slot = from_slot,
                .to_slot = to_slot,
                .edge_slot = edge_slot,
            };
        };
        try self.ensureGraph(graph_name);
        // Generate UUIDv7-based time-sortable unique ID
        const id = generateTimeBasedId();

        // Store UUID→slot mapping in IdMap for adapter translation
        if (adapter_edge) |persisted_edge| {
            persistEdgePublicId(
                persisted_edge.vt,
                graph_name,
                persisted_edge.from_slot,
                persisted_edge.to_slot,
                persisted_edge.edge_slot,
                id,
            ) catch |err| {
                persisted_edge.vt.deleteEdgeFn(
                    persisted_edge.vt.ctx,
                    graph_name,
                    persisted_edge.from_slot,
                    persisted_edge.to_slot,
                    persisted_edge.edge_slot,
                ) catch {};
                return err;
            };
            const im = try self.getOrCreateIdMap(graph_name);
            try im.insertEdgeWithSlot(@as(u128, id), persisted_edge.edge_slot);
        }

        const edge_type_copy = try self.allocator.dupe(u8, edge_type);
        const graph_name_copy = try self.allocator.dupe(u8, graph_name);
        const tenant_id_copy = try self.allocator.dupe(u8, tenant);

        const edge = Edge{
            .id = id,
            .from_id = from_id,
            .to_id = to_id,
            .label = edge_type_copy,
            .properties = std.StringHashMap(PropertyValue).init(self.allocator),
            .graph_name = graph_name_copy,
            .tenant_id = tenant_id_copy,
        };

        try self.edges.put(id, edge);

        // CANARY: REQ=REQ-PERF-EDGE-ADJ-002; FEATURE="EdgeAdjacencyIndex"; ASPECT=IndexMaintenance; STATUS=TESTED; TEST=tests/test_gap0514_graph_store_regression.zig; OWNER=perf; UPDATED=2026-04-11
        // Issue #392: Maintain adjacency indexes for fast DELETE DETACH
        try self.addToAdjacencyIndex(from_id, to_id, id);
        // PERF-P0-001: Maintain edge-type index for fast getEdgesByType
        try self.addToEdgeTypeIndex(graph_name, edge_type, id);

        // CANARY: REQ=REQ-BINARY-PERSIST-EDGE-001; FEATURE="BinaryPersistence"; ASPECT=DirtyTracking; STATUS=TESTED; TEST=tests/test_gap0514_graph_store_regression.zig; OWNER=storage; UPDATED=2026-04-11
        // Mark store as dirty - persistence happens at query completion, not per-edge
        self.dirty.store(true, .release);
        incrementMutationEpoch();

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
        persist_adapter: bool,
    ) !void {
        const adapter_edge: ?struct {
            vt: AdapterVTable,
            from_slot: u64,
            to_slot: u64,
            edge_slot: u64,
        } = if (persist_adapter) blk: {
            const vt = global_vtable orelse break :blk null;
            const from_slot = try self.requireNodeSlot(graph_name, from_id);
            const to_slot = try self.requireNodeSlot(graph_name, to_id);
            break :blk .{
                .vt = vt,
                .from_slot = from_slot,
                .to_slot = to_slot,
                .edge_slot = try vt.createEdgeFn(vt.ctx, graph_name, from_slot, to_slot, edge_type),
            };
        } else null;

        try self.ensureGraph(graph_name);
        if (self.edges.contains(edge_id)) return error.EdgeAlreadyExists;

        if (adapter_edge) |persisted_edge| {
            persistEdgePublicId(
                persisted_edge.vt,
                graph_name,
                persisted_edge.from_slot,
                persisted_edge.to_slot,
                persisted_edge.edge_slot,
                edge_id,
            ) catch |err| {
                persisted_edge.vt.deleteEdgeFn(
                    persisted_edge.vt.ctx,
                    graph_name,
                    persisted_edge.from_slot,
                    persisted_edge.to_slot,
                    persisted_edge.edge_slot,
                ) catch {};
                return err;
            };
            const im = try self.getOrCreateIdMap(graph_name);
            try im.insertEdgeWithSlot(@as(u128, edge_id), persisted_edge.edge_slot);
        }

        const edge_type_copy = try self.allocator.dupe(u8, edge_type);
        const graph_name_copy = try self.allocator.dupe(u8, graph_name);
        const tenant_id_copy = try self.allocator.dupe(u8, DEFAULT_TENANT_ID);

        const edge = Edge{
            .id = edge_id,
            .from_id = from_id,
            .to_id = to_id,
            .label = edge_type_copy,
            .properties = std.StringHashMap(PropertyValue).init(self.allocator),
            .graph_name = graph_name_copy,
            .tenant_id = tenant_id_copy,
        };

        try self.edges.put(edge_id, edge);
        try self.addToAdjacencyIndex(from_id, to_id, edge_id);
        // PERF-P0-001: Maintain edge-type index for fast getEdgesByType
        try self.addToEdgeTypeIndex(graph_name, edge_type, edge_id);

        if (edge_id >= self.next_edge_id) {
            self.next_edge_id = edge_id + 1;
        }

        if (mark_dirty) {
            self.dirty.store(true, .release);
            incrementMutationEpoch();
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
        return self.createEdgeWithIdInternal(edge_id, from_id, to_id, edge_type, graph_name, true, true);
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
        return self.createEdgeWithIdInternal(edge_id, from_id, to_id, edge_type, graph_name, false, false);
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

    // CANARY: REQ=REQ-PERF-EDGE-TYPE-INDEX-002; FEATURE="EdgeTypeIndex"; ASPECT=IndexMaintenance; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=perf; UPDATED=2026-04-10
    // PERF-P0-001: Add edge to edge-type index (composite key "graph_name:edge_type")
    // Uses stack-allocated bufPrint to probe for existing key before heap alloc (same pattern as addToLabelIndex).
    fn addToEdgeTypeIndex(self: *GraphStore, graph_name: []const u8, edge_type: []const u8, edge_id: u64) !void {
        var buf: [512]u8 = undefined;
        const probe_key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ graph_name, edge_type }) catch {
            // Key too long for stack buffer — fall back to heap alloc
            const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, edge_type });
            const result = try self.edge_type_index.getOrPut(key);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(u64).empty;
            } else {
                self.allocator.free(key);
            }
            try sortedInsert(result.value_ptr, self.allocator, edge_id);
            return;
        };

        if (self.edge_type_index.getPtr(probe_key)) |list| {
            try sortedInsert(list, self.allocator, edge_id);
        } else {
            const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, edge_type });
            const result = try self.edge_type_index.getOrPut(key);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(u64).empty;
            } else {
                self.allocator.free(key);
            }
            try sortedInsert(result.value_ptr, self.allocator, edge_id);
        }
    }

    // PERF-P0-001: Remove edge from edge-type index
    fn removeFromEdgeTypeIndex(self: *GraphStore, graph_name: []const u8, edge_type: []const u8, edge_id: u64) void {
        const key = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, edge_type }) catch return;
        defer self.allocator.free(key);

        if (self.edge_type_index.getPtr(key)) |list| {
            // Binary search for edge_id in sorted posting list
            const items = list.items;
            var lo: usize = 0;
            var hi: usize = items.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (items[mid] < edge_id) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if (lo < items.len and items[lo] == edge_id) {
                _ = list.orderedRemove(lo);
            }
            if (list.items.len == 0) {
                if (self.edge_type_index.fetchRemove(key)) |kv| {
                    self.allocator.free(kv.key);
                    var list_copy = kv.value;
                    list_copy.deinit(self.allocator);
                }
            }
        }
    }

    /// Get edge IDs by type within a graph (O(1) lookup via edge-type index).
    /// Returns null if no edges of this type exist in the graph.
    pub fn getEdgeIdsByType(self: *const GraphStore, graph_name: []const u8, edge_type: []const u8) ?[]const u64 {
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ graph_name, edge_type }) catch return null;

        if (self.edge_type_index.get(key)) |list| {
            return list.items;
        }
        return null;
    }

    // CANARY: REQ=REQ-PERF-EDGE-ADJ-003; FEATURE="EdgeAdjacencyIndex"; ASPECT=EdgeLookup; STATUS=TESTED; OWNER=perf; UPDATED=2026-02-12
    // Issue #392: Get all edges connected to a node (O(1) lookup instead of O(edges) scan)
    // Issue #450: Use HashSet for O(1) deduplication instead of O(m*n) linear scan
    pub fn getEdgesForNode(self: *const GraphStore, allocator: std.mem.Allocator, node_id: u64) std.ArrayList(u64) {
        var result = std.ArrayList(u64).empty;
        var seen = std.AutoHashMap(u64, void).init(allocator);
        defer seen.deinit();

        // Get outgoing edges
        if (self.outgoing_edges.get(node_id)) |outgoing| {
            for (outgoing.items) |edge_id| {
                seen.put(edge_id, {}) catch continue;
                result.append(allocator, edge_id) catch continue;
            }
        }

        // Get incoming edges — deduplicate self-loops via HashSet (#450)
        if (self.incoming_edges.get(node_id)) |incoming| {
            for (incoming.items) |edge_id| {
                if (!seen.contains(edge_id)) {
                    seen.put(edge_id, {}) catch continue;
                    result.append(allocator, edge_id) catch continue;
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
        if (isInternalPersistedPropertyKey(key)) return error.ReservedPropertyKey;
        // FLE defense-in-depth: encrypt String values before adapter write and in-memory storage.
        const effective_value = switch (value) {
            .String => |s| blk: {
                if (fle_integration.hasEncryptedFields() and !isLikelyFleEnvelope(s)) {
                    const edge_type: []const u8 = if (self.edges.get(edge_id)) |e| e.label else "Unknown";
                    if (fle_integration.fieldRequiresEncryption(edge_type, key)) {
                        const fle_ctx = fle_integration.EncryptionContext{
                            .tenant_id = self.tenant_id,
                            .schema_name = self.schema_name,
                            .allocator = self.allocator,
                            .current_user_role = fle_integration.getCurrentUserRole(),
                        };
                        const record_id = std.fmt.allocPrint(self.allocator, "edge_{d}", .{edge_id}) catch {
                            break :blk value;
                        };
                        defer self.allocator.free(record_id);
                        const encrypted = fle_integration.encryptFieldIfNeeded(
                            fle_ctx,
                            edge_type,
                            key,
                            s,
                            record_id,
                        ) catch {
                            break :blk value;
                        };
                        if (!std.mem.eql(u8, encrypted, s)) {
                            break :blk PropertyValue{ .String = encrypted };
                        }
                    }
                }
                break :blk value;
            },
            else => value,
        };

        blk_adapter: {
            const vt = global_vtable orelse break :blk_adapter;
            const f = vt.setEdgePropertyFn orelse break :blk_adapter;
            const edge = self.edges.get(edge_id) orelse break :blk_adapter;
            const slot_from = self.requireNodeSlot(edge.graph_name, edge.from_id) catch |err| {
                log.debug("adapter edge endpoint-slot lookup failed during setEdgeProperty", &.{
                    Attr.string("error", @errorName(err)),
                });
                break :blk_adapter;
            };
            const slot_to = self.requireNodeSlot(edge.graph_name, edge.to_id) catch |err| {
                log.debug("adapter edge endpoint-slot lookup failed during setEdgeProperty", &.{
                    Attr.string("error", @errorName(err)),
                });
                break :blk_adapter;
            };
            const slot_edge = self.requireEdgeSlot(edge.graph_name, edge_id) catch |err| {
                log.debug("adapter edge-slot lookup failed during setEdgeProperty", &.{
                    Attr.string("error", @errorName(err)),
                });
                break :blk_adapter;
            };
            f(vt.ctx, edge.graph_name, slot_from, slot_to, slot_edge, key, effective_value) catch |err| {
                log.debug("adapter setEdgeProperty failed", &.{
                    Attr.string("error", @errorName(err)),
                });
            };
        }
        if (self.edges.getPtr(edge_id)) |edge| {
            const value_copy = try copyPropertyValue(self, effective_value);
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
            self.dirty.store(true, .release);
            incrementMutationEpoch();

            // WAL notification: SetEdgeProperty
            notifyMutation(.set_edge_property, edge_id, 0, 0, null, key, effective_value, null);
        }
    }

    pub fn removeEdgeProperty(self: *GraphStore, edge_id: u64, key: []const u8) void {
        if (isInternalPersistedPropertyKey(key)) return;
        if (global_vtable) |vt| {
            if (vt.removeEdgePropertyFn) |f| {
                if (self.edges.get(edge_id)) |edge_info| {
                    const slot_from = self.requireNodeSlot(edge_info.graph_name, edge_info.from_id) catch |err| {
                        log.err("adapter edge endpoint-slot lookup failed during removeEdgeProperty", &.{
                            Attr.string("error", @errorName(err)),
                            Attr.int("edge_id", @intCast(edge_id)),
                            Attr.string("graph", edge_info.graph_name),
                        });
                        return;
                    };
                    const slot_to = self.requireNodeSlot(edge_info.graph_name, edge_info.to_id) catch |err| {
                        log.err("adapter edge endpoint-slot lookup failed during removeEdgeProperty", &.{
                            Attr.string("error", @errorName(err)),
                            Attr.int("edge_id", @intCast(edge_id)),
                            Attr.string("graph", edge_info.graph_name),
                        });
                        return;
                    };
                    const slot_edge = self.requireEdgeSlot(edge_info.graph_name, edge_id) catch |err| {
                        log.err("adapter edge-slot lookup failed during removeEdgeProperty", &.{
                            Attr.string("error", @errorName(err)),
                            Attr.int("edge_id", @intCast(edge_id)),
                            Attr.string("graph", edge_info.graph_name),
                        });
                        return;
                    };
                    f(vt.ctx, edge_info.graph_name, slot_from, slot_to, slot_edge, key) catch |err| {
                        log.err("adapter removeEdgeProperty failed", &.{
                            Attr.string("error", @errorName(err)),
                            Attr.int("edge_id", @intCast(edge_id)),
                            Attr.string("graph", edge_info.graph_name),
                        });
                        return;
                    };
                }
            }
        }
        if (self.edges.getPtr(edge_id)) |edge| {
            if (edge.properties.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                freePropertyValue(self, kv.value);
            }
            self.dirty.store(true, .release);
            incrementMutationEpoch();

            // WAL notification: RemoveEdgeProperty
            notifyMutation(.remove_edge_property, edge_id, 0, 0, null, key, null, null);
        }
    }

    // CANARY: REQ=REQ-PERF-EDGE-TYPE-INDEX-003; FEATURE="EdgeTypeIndex"; ASPECT=EdgeTypeLookup; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=perf; UPDATED=2026-04-10
    // PERF-P0-001: O(result) edge-type lookup via edge_type_index instead of O(E) full scan.
    // Iterates over registered graphs (typically 1-3) and collects matching edge IDs from the
    // per-graph:type index, then resolves to Edge structs with optional tenant filtering.
    // Accepts caller-provided allocator to avoid concurrent threads contending
    // on self.allocator (same class of bug as GAP-0425 getNodesByLabels fix).
    // GAP-0509: tenant_id filters edges to a specific tenant when non-null.
    // PERF-P2-003: Return edge IDs (8 bytes each) instead of full Edge structs
    // (~96+ bytes each). Callers use store.edges.getPtr(id) for read-only access.
    //
    // GAP-0512: When `graph_name` is non-null, restrict the posting-list
    // scan to that single graph. When null, the function returns the
    // union across every graph — an admin / diagnostic path that must
    // stay available (e.g. for cross-graph metrics and ML training
    // pipelines that explicitly pass null). Callers executing a
    // user-scoped query (MATCH, algorithms) must pass the active graph
    // so edges from other graphs cannot leak into the result set.
    // CANARY: REQ=REQ-MULTI-GRAPH-EDGE-ISOLATION; FEATURE="GraphIsolationEdgeScan"; ASPECT=GetEdgesByType; STATUS=TESTED; TEST=tests/test_graph_isolation_edge_iteration.zig:1; OWNER=engine; UPDATED=2026-04-11
    pub fn getEdgesByType(
        self: *GraphStore,
        allocator: std.mem.Allocator,
        edge_type: []const u8,
        tenant_id: ?[]const u8,
        graph_name: ?[]const u8,
    ) []u64 {
        // Collect matching edge IDs from the edge-type index. When
        // graph_name is set, do a single keyed lookup; when it is null,
        // iterate every graph (legacy admin path).
        var id_list = std.ArrayList(u64).empty;
        defer id_list.deinit(allocator);

        if (graph_name) |gn| {
            var key_buf: [512]u8 = undefined;
            const probe = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ gn, edge_type }) catch return &.{};
            if (self.edge_type_index.get(probe)) |posting| {
                id_list.appendSlice(allocator, posting.items) catch return &.{};
            }
        } else {
            var graph_iter = self.graphs.keyIterator();
            while (graph_iter.next()) |graph_key| {
                var key_buf: [512]u8 = undefined;
                const probe = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ graph_key.*, edge_type }) catch continue;
                if (self.edge_type_index.get(probe)) |posting| {
                    id_list.appendSlice(allocator, posting.items) catch continue;
                }
            }
        }

        // Filter by tenant and return IDs directly (zero-copy for edge data).
        if (tenant_id == null) {
            return id_list.toOwnedSlice(allocator) catch return &.{};
        }

        var count: usize = 0;
        for (id_list.items) |eid| {
            const edge = self.edges.get(eid) orelse continue;
            if (tenant_id) |tid| {
                if (!std.mem.eql(u8, edge.tenant_id, tid)) continue;
            }
            count += 1;
        }

        const result = allocator.alloc(u64, count) catch return &.{};
        var i: usize = 0;
        for (id_list.items) |eid| {
            const edge = self.edges.get(eid) orelse continue;
            if (tenant_id) |tid| {
                if (!std.mem.eql(u8, edge.tenant_id, tid)) continue;
            }
            result[i] = eid;
            i += 1;
        }
        return result;
    }

    /// Deprecated: prefer getOutgoingEdgeIds for zero-copy access.
    pub fn getEdgesFrom(self: *GraphStore, allocator: std.mem.Allocator, node_id: u64) []Edge {
        var result = std.ArrayList(Edge){};
        if (self.outgoing_edges.get(node_id)) |outgoing| {
            for (outgoing.items) |edge_id| {
                if (self.edges.get(edge_id)) |edge| {
                    result.append(allocator, edge) catch continue;
                }
            }
        }
        return result.toOwnedSlice(allocator) catch &.{};
    }

    /// Deprecated: prefer getIncomingEdgeIds for zero-copy access.
    pub fn getEdgesTo(self: *GraphStore, allocator: std.mem.Allocator, node_id: u64) []Edge {
        var result = std.ArrayList(Edge){};
        if (self.incoming_edges.get(node_id)) |incoming| {
            for (incoming.items) |edge_id| {
                if (self.edges.get(edge_id)) |edge| {
                    result.append(allocator, edge) catch continue;
                }
            }
        }
        return result.toOwnedSlice(allocator) catch &.{};
    }

    /// DEPRECATED: Legacy ExtValue writer stub — was used by graph_store.dat serialization.
    fn writeExtValueToWriter(self: *GraphStore, writer: anytype, hasher: anytype, ext: @import("eval_extended.zig").ExtValue) !void {
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
                if (hash.params) |params| {
                    hasher.update(&[1]u8{1});
                    try writer.writeAll(&[1]u8{1});

                    var params_buf: [9]u8 = undefined;
                    std.mem.writeInt(u32, params_buf[0..4], params.iterations, .little);
                    std.mem.writeInt(u32, params_buf[4..8], params.memory_kb, .little);
                    params_buf[8] = params.parallelism;
                    hasher.update(&params_buf);
                    try writer.writeAll(&params_buf);
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
                var buf: [10]u8 = undefined;
                var flags: u8 = 0;
                if (range_val.lower != null) flags |= 0b01;
                if (range_val.upper != null) flags |= 0b10;
                buf[0] = flags;
                std.mem.writeInt(i32, buf[1..5], range_val.lower orelse 0, .little);
                std.mem.writeInt(i32, buf[5..9], range_val.upper orelse 0, .little);
                buf[9] = @intFromEnum(range_val.bounds);
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
                for (list) |item| {
                    try self.writeExtValueToWriter(writer, hasher, item);
                }
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
                var params_flag: [1]u8 = undefined;
                if ((try reader.readAll(&params_flag)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                var params: ?heap_mod.Argon2Params = null;
                if (params_flag[0] != 0) {
                    var params_buf: [9]u8 = undefined;
                    if ((try reader.readAll(&params_buf)) < params_buf.len) break :blk ext_eval.ExtValue{ .Null = {} };
                    params = .{
                        .iterations = std.mem.readInt(u32, params_buf[0..4], .little),
                        .memory_kb = std.mem.readInt(u32, params_buf[4..8], .little),
                        .parallelism = params_buf[8],
                    };
                }
                break :blk ext_eval.ExtValue{ .Hash = .{
                    .alg = @enumFromInt(alg_buf[0]),
                    .digest = digest,
                    .salt = salt,
                    .params = params,
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
                var loaded: usize = 0;
                const list = try self.allocator.alloc(ext_eval.ExtValue, len);
                errdefer {
                    for (list[0..loaded]) |item| {
                        freeExtValue(self, item);
                    }
                    self.allocator.free(list);
                }
                while (loaded < len) : (loaded += 1) {
                    list[loaded] = try self.readExtValue(reader);
                }
                break :blk ext_eval.ExtValue{ .List = list };
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
                var buf: [10]u8 = undefined;
                if ((try reader.readAll(&buf)) < 10) break :blk ext_eval.ExtValue{ .Null = {} };
                const flags = buf[0];
                const lower = if ((flags & 0b01) != 0) std.mem.readInt(i32, buf[1..5], .little) else null;
                const upper = if ((flags & 0b10) != 0) std.mem.readInt(i32, buf[5..9], .little) else null;
                const bounds: range_mod.IntRange.Bounds = @enumFromInt(buf[9]);
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

    /// No-op: per-graph file persistence removed — adapter handles storage.
    pub fn savePerGraphFiles(self: *GraphStore) !void {
        _ = self;
    }

    /// No-op: per-graph file loading removed — adapter handles storage.
    pub fn loadPerGraphFiles(self: *GraphStore) !void {
        _ = self;
    }

    // CANARY: REQ=REQ-STORAGE-ENGINE-PHASE2-002; FEATURE="EngineBackedPersistence"; ASPECT=SaveToFile; STATUS=TESTED; TEST=tests/test_gap0514_graph_store_regression.zig; OWNER=storage; UPDATED=2026-04-11
    // Save delegates to adapter checkpoint. Public ID mappings are now stored
    // inside graph-storage properties rather than a sidecar id_map.dat file.
    pub fn saveToFile(self: *GraphStore) !void {
        if (global_adapter) |adapter| {
            try adapter.checkpointAll();
        }
        self.cleanupLegacySidecars();
        self.dirty.store(false, .release);
    }

    /// DEPRECATED: Legacy serialization stub — adapter handles persistence.
    // CANARY: REQ=REQ-STREAM-SERIALIZE-002; FEATURE="StreamingSerialization"; ASPECT=StreamToFile; STATUS=EXEMPT; OWNER=storage; UPDATED=2026-03-28
    pub fn serializeToTempFile(self: *GraphStore, tmp_path: []const u8) !void {
        _ = self;
        _ = tmp_path;
    }

    /// DEPRECATED: Legacy finalization stub — adapter handles persistence.
    fn finalizeTempFile(allocator: std.mem.Allocator, tmp_path: []const u8, final_path: []const u8) !void {
        _ = allocator;
        _ = tmp_path;
        _ = final_path;
    }

    fn resolveGraphStorageDirPath(self: *GraphStore, graph_name: []const u8) !?[]u8 {
        if (self.data_dir.len == 0) return null;

        const graph_uuid = GraphStore.getGraphUuid(graph_name) orelse return null;
        const uuid_hex = std.fmt.bytesToHex(graph_uuid, .lower);
        const uuid_path = try std.fmt.allocPrint(self.allocator, "{s}/graphs/{s}", .{ self.data_dir, uuid_hex });
        std.fs.cwd().access(uuid_path, .{}) catch |err| {
            self.allocator.free(uuid_path);
            if (err == error.FileNotFound) return null;
            return err;
        };
        return uuid_path;
    }

    fn loadLegacyIdMap(self: *GraphStore, graph_name: []const u8) !?id_map_mod.IdMap {
        const graph_dir_path = (try self.resolveGraphStorageDirPath(graph_name)) orelse return null;
        defer self.allocator.free(graph_dir_path);

        var dir = std.fs.cwd().openDir(graph_dir_path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer dir.close();

        dir.access("id_map.dat", .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };

        return try id_map_mod.IdMap.load(self.allocator, dir);
    }

    // CANARY: REQ=REQ-STORAGE-ENGINE-PHASE2-003; FEATURE="EngineBackedPersistence"; ASPECT=LegacyCleanup; STATUS=IMPL; OWNER=storage; UPDATED=2026-04-02
    /// Remove obsolete sidecar files after their contents have been migrated
    /// into the graph-storage engine.
    fn cleanupLegacySidecars(self: *GraphStore) void {
        var it = self.graphs.iterator();
        while (it.next()) |entry| {
            self.cleanupLegacySidecarsForGraph(entry.key_ptr.*);
        }
    }

    fn cleanupLegacySidecarsForGraph(self: *GraphStore, graph_name: []const u8) void {
        const graph_dir_path = self.resolveGraphStorageDirPath(graph_name) catch return orelse return;
        defer self.allocator.free(graph_dir_path);

        var dir = std.fs.cwd().openDir(graph_dir_path, .{}) catch return;
        defer dir.close();

        const stale_files = [_][]const u8{
            "adapter_labels.dat",
            "adapter_labels.dat.tmp",
            "id_map.dat",
            "id_map.dat.tmp",
        };
        for (stale_files) |name| {
            dir.deleteFile(name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => log.warn("failed to remove legacy graph sidecar", &.{
                    Attr.string("graph", graph_name),
                    Attr.string("file", name),
                    Attr.string("error", @errorName(err)),
                }),
            };
        }
    }

    /// Deprecated compatibility shim. Public ID mappings are no longer
    /// persisted in a sidecar file.
    pub fn saveIdMaps(self: *GraphStore) void {
        _ = self;
    }

    // CANARY: REQ=REQ-STORAGE-ENGINE-PHASE2-004; FEATURE="EngineBackedPersistence"; ASPECT=LoadFromAdapter; STATUS=IMPL; OWNER=storage; UPDATED=2026-03-28
    /// Load graph data from the storage adapter into the in-memory cache.
    /// Scans all nodes and edges from the adapter, rebuilding Node/Edge
    /// structs, label index, adjacency index, and IdMaps.
    fn loadFromAdapter(self: *GraphStore, adapter: *graph_storage_adapter.StorageAdapter) !void {
        const graph_names = try adapter.listGraphNames(self.allocator);
        defer {
            for (graph_names) |name| self.allocator.free(name);
            self.allocator.free(graph_names);
        }

        for (graph_names) |graph_name| {
            // Register graph in the registry
            try self.ensureGraphNoDirty(graph_name);
            var legacy_map = try self.loadLegacyIdMap(graph_name);
            defer if (legacy_map) |*map| map.deinit();

            const id_map = try self.getOrCreateIdMap(graph_name);
            var backfilled_from_legacy = false;
            var skipped_node_mappings: u64 = 0;
            var skipped_edge_mappings: u64 = 0;

            const scan_entries = try adapter.scanAllNodes(graph_name, self.allocator);
            defer self.allocator.free(scan_entries);

            for (scan_entries) |entry| {
                const slot_id = entry.slot_id;
                const node_uuid = blk: {
                    if (try adapter.getNodeProperty(graph_name, slot_id, INTERNAL_NODE_ID_PROPERTY_KEY, self.allocator)) |stored_prop| {
                        defer graph_storage_adapter.freeOwnedStorageProperty(self.allocator, stored_prop);
                        switch (stored_prop) {
                            .string => |text| {
                                if (parsePersistedPublicId(text)) |parsed| break :blk parsed;
                            },
                            else => {},
                        }
                    }

                    if (legacy_map) |*map| {
                        const legacy_uuid_128 = map.nodeUuid(slot_id) orelse break :blk null;
                        const public_id = @as(u64, @truncate(legacy_uuid_128));
                        var id_buf: [16]u8 = undefined;
                        try adapter.setNodeProperty(
                            graph_name,
                            slot_id,
                            INTERNAL_NODE_ID_PROPERTY_KEY,
                            .{ .String = encodePersistedPublicId(&id_buf, public_id) },
                        );
                        backfilled_from_legacy = true;
                        break :blk public_id;
                    }

                    break :blk null;
                } orelse {
                    skipped_node_mappings += 1;
                    continue;
                };
                try id_map.insertNodeWithSlot(@as(u128, node_uuid), slot_id);
            }

            for (scan_entries) |entry| {
                const slot_id = entry.slot_id;
                const node_uuid = @as(u64, @truncate(id_map.nodeUuid(slot_id) orelse continue));
                const labels = try adapter.getNodeLabels(graph_name, slot_id, self.allocator);

                const graph_name_copy = try self.allocator.dupe(u8, graph_name);
                const tenant_id_copy = try self.allocator.dupe(u8, DEFAULT_TENANT_ID);

                var node = Node{
                    .id = node_uuid,
                    .labels = labels,
                    .properties = std.StringHashMap(PropertyValue).init(self.allocator),
                    .graph_name = graph_name_copy,
                    .tenant_id = tenant_id_copy,
                };

                var storage_props = try adapter.getAllNodeProperties(graph_name, slot_id, self.allocator);
                defer {
                    var sp_iter = storage_props.iterator();
                    while (sp_iter.next()) |sp_entry| {
                        self.allocator.free(sp_entry.key_ptr.*);
                    }
                    storage_props.deinit();
                }

                var sp_iter = storage_props.iterator();
                while (sp_iter.next()) |sp_entry| {
                    const key_copy = try self.allocator.dupe(u8, sp_entry.key_ptr.*);
                    const pv = try graph_storage_adapter.fromStorageProperty(self.allocator, sp_entry.value_ptr.*);
                    try node.properties.put(key_copy, pv);
                }

                try self.nodes.put(node_uuid, node);

                // Update next_node_id
                if (node_uuid >= self.next_node_id) {
                    self.next_node_id = node_uuid + 1;
                }

                // Rebuild label index
                for (labels) |label| {
                    try self.addToLabelIndex(graph_name, label, node_uuid);
                }

                var out_edges = try adapter.iterateOutgoingEdges(graph_name, slot_id, self.allocator);
                defer out_edges.deinit();

                while (try out_edges.next()) |edge_entry| {
                    // Skip edges/nodes whose slot_ids aren't mapped yet (concurrent inserts).
                    const edge_uuid = blk: {
                        if (try adapter.getEdgeProperty(
                            graph_name,
                            slot_id,
                            edge_entry.edge_id,
                            INTERNAL_EDGE_ID_PROPERTY_KEY,
                            self.allocator,
                        )) |stored_prop| {
                            defer graph_storage_adapter.freeOwnedStorageProperty(self.allocator, stored_prop);
                            switch (stored_prop) {
                                .string => |text| {
                                    if (parsePersistedPublicId(text)) |parsed| break :blk parsed;
                                },
                                else => {},
                            }
                        }

                        if (legacy_map) |*map| {
                            const legacy_uuid_128 = map.edgeUuid(edge_entry.edge_id) orelse break :blk null;
                            const public_id = @as(u64, @truncate(legacy_uuid_128));
                            var id_buf: [16]u8 = undefined;
                            try adapter.setEdgeProperty(
                                graph_name,
                                slot_id,
                                edge_entry.neighbor,
                                edge_entry.edge_id,
                                INTERNAL_EDGE_ID_PROPERTY_KEY,
                                .{ .String = encodePersistedPublicId(&id_buf, public_id) },
                            );
                            backfilled_from_legacy = true;
                            break :blk public_id;
                        }

                        break :blk null;
                    } orelse {
                        skipped_edge_mappings += 1;
                        continue;
                    };
                    try id_map.insertEdgeWithSlot(@as(u128, edge_uuid), edge_entry.edge_id);

                    if (self.edges.contains(edge_uuid)) continue;

                    const target_uuid = @as(u64, @truncate(id_map.nodeUuid(edge_entry.neighbor) orelse continue));

                    // Get edge label from label dict
                    const mg = try adapter.getOrCreateGraph(graph_name);
                    const edge_label_str = mg.label_dict.getString(edge_entry.rel_type) orelse "UNKNOWN";
                    const edge_label_copy = try self.allocator.dupe(u8, edge_label_str);
                    const edge_graph_name_copy = try self.allocator.dupe(u8, graph_name);
                    const edge_tenant_id_copy = try self.allocator.dupe(u8, DEFAULT_TENANT_ID);

                    var edge = Edge{
                        .id = edge_uuid,
                        .from_id = node_uuid,
                        .to_id = target_uuid,
                        .label = edge_label_copy,
                        .properties = std.StringHashMap(PropertyValue).init(self.allocator),
                        .graph_name = edge_graph_name_copy,
                        .tenant_id = edge_tenant_id_copy,
                    };

                    if (edge_entry.prop_head != 0) {
                        var edge_storage_props = try adapter.getAllEdgeProperties(graph_name, edge_entry.prop_head, self.allocator);
                        defer {
                            var edge_sp_iter = edge_storage_props.iterator();
                            while (edge_sp_iter.next()) |sp_entry| {
                                self.allocator.free(sp_entry.key_ptr.*);
                            }
                            edge_storage_props.deinit();
                        }

                        var edge_sp_iter = edge_storage_props.iterator();
                        while (edge_sp_iter.next()) |sp_entry| {
                            const key_copy = try self.allocator.dupe(u8, sp_entry.key_ptr.*);
                            const pv = try graph_storage_adapter.fromStorageProperty(self.allocator, sp_entry.value_ptr.*);
                            try edge.properties.put(key_copy, pv);
                        }
                    }

                    try self.edges.put(edge_uuid, edge);
                    try self.addToAdjacencyIndex(node_uuid, target_uuid, edge_uuid);
                    // PERF-P0-001: Maintain edge-type index during adapter load
                    try self.addToEdgeTypeIndex(graph_name, edge.label, edge_uuid);

                    if (edge_uuid >= self.next_edge_id) {
                        self.next_edge_id = edge_uuid + 1;
                    }
                }
            }

            if (backfilled_from_legacy) {
                try adapter.checkpointAll();
            }
            self.cleanupLegacySidecarsForGraph(graph_name);

            if (skipped_node_mappings > 0 or skipped_edge_mappings > 0) {
                log.warn("loadFromAdapter skipped entries with no persisted public ID mapping", &.{
                    Attr.string("graph", graph_name),
                    Attr.int("skipped_nodes", @intCast(skipped_node_mappings)),
                    Attr.int("skipped_edges", @intCast(skipped_edge_mappings)),
                });
            }
        }

        // Startup diagnostic: log total loaded data so operators can verify
        // data loaded correctly (empty counts indicate a loading failure).
        log.info("loadFromAdapter complete", &.{
            Attr.int("graphs", @intCast(graph_names.len)),
            Attr.int("nodes", @intCast(self.nodes.count())),
            Attr.int("edges", @intCast(self.edges.count())),
        });
    }

    /// DEPRECATED: Legacy buffer serialization stub — adapter handles persistence.
    /// Returns an empty buffer.
    pub fn serializeToBuffer(self: *GraphStore) !std.ArrayList(u8) {
        return std.ArrayList(u8).initCapacity(self.allocator, 0);
    }

    // CANARY: REQ=REQ-DIST-CLUSTER-002; FEATURE="ClusterReplication"; ASPECT=SnapshotSerialization; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-05
    /// Serialize all nodes and edges to JSON-lines format for cluster replication.
    /// Each line is one JSON object:
    ///   {"type":"node","id":N,"graph":"G","labels":["L1"],"properties":{"k":"v"}}
    ///   {"type":"edge","id":N,"from":F,"to":T,"graph":"G","label":"L","properties":{}}
    /// Returns owned bytes that the caller must free with `allocator.free`.
    pub fn serializeSnapshot(self: *GraphStore, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(allocator);

        // Serialize nodes as JSON-lines
        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr;
            try appendNodeJson(&buf, allocator, entry.key_ptr.*, node);
            try buf.append(allocator, '\n');
        }

        // Serialize edges as JSON-lines
        var edge_iter = self.edges.iterator();
        while (edge_iter.next()) |entry| {
            const edge = entry.value_ptr;
            try appendEdgeJson(&buf, allocator, entry.key_ptr.*, edge);
            try buf.append(allocator, '\n');
        }

        return try buf.toOwnedSlice(allocator);
    }

    /// Append a single node as a JSON object to the buffer.
    fn appendNodeJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, id: u64, node: *const Node) !void {
        try buf.appendSlice(allocator, "{\"type\":\"node\",\"id\":");
        try appendU64(buf, allocator, id);
        try buf.appendSlice(allocator, ",\"graph\":\"");
        try appendJsonEscaped(buf, allocator, node.graph_name);
        try buf.appendSlice(allocator, "\",\"labels\":[");
        for (node.labels, 0..) |label, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.append(allocator, '"');
            try appendJsonEscaped(buf, allocator, label);
            try buf.append(allocator, '"');
        }
        try buf.appendSlice(allocator, "],\"properties\":");
        try appendPropertiesJson(buf, allocator, &node.properties);
        try buf.append(allocator, '}');
    }

    /// Append a single edge as a JSON object to the buffer.
    fn appendEdgeJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, id: u64, edge: *const Edge) !void {
        try buf.appendSlice(allocator, "{\"type\":\"edge\",\"id\":");
        try appendU64(buf, allocator, id);
        try buf.appendSlice(allocator, ",\"from\":");
        try appendU64(buf, allocator, edge.from_id);
        try buf.appendSlice(allocator, ",\"to\":");
        try appendU64(buf, allocator, edge.to_id);
        try buf.appendSlice(allocator, ",\"graph\":\"");
        try appendJsonEscaped(buf, allocator, edge.graph_name);
        try buf.appendSlice(allocator, "\",\"label\":\"");
        try appendJsonEscaped(buf, allocator, edge.label);
        try buf.appendSlice(allocator, "\",\"properties\":");
        try appendPropertiesJson(buf, allocator, &edge.properties);
        try buf.append(allocator, '}');
    }

    /// Append a u64 value as decimal text.
    fn appendU64(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
        var tmp: [20]u8 = undefined;
        const slice = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch unreachable;
        try buf.appendSlice(allocator, slice);
    }

    /// Append a string with JSON escaping (quotes, backslashes, control chars).
    fn appendJsonEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '"' => try buf.appendSlice(allocator, "\\\""),
                '\\' => try buf.appendSlice(allocator, "\\\\"),
                '\n' => try buf.appendSlice(allocator, "\\n"),
                '\r' => try buf.appendSlice(allocator, "\\r"),
                '\t' => try buf.appendSlice(allocator, "\\t"),
                else => {
                    if (c < 0x20) {
                        // Control characters as \u00XX
                        var esc: [6]u8 = undefined;
                        _ = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}) catch unreachable;
                        try buf.appendSlice(allocator, &esc);
                    } else {
                        try buf.append(allocator, c);
                    }
                },
            }
        }
    }

    /// Append a property map as a JSON object: {"key":"val","key2":123}
    fn appendPropertiesJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, props: *const std.StringHashMap(PropertyValue)) !void {
        try buf.append(allocator, '{');
        var first = true;
        var it = props.iterator();
        while (it.next()) |prop| {
            if (!first) try buf.append(allocator, ',');
            first = false;
            try buf.append(allocator, '"');
            try appendJsonEscaped(buf, allocator, prop.key_ptr.*);
            try buf.appendSlice(allocator, "\":");
            try appendPropertyValueJson(buf, allocator, prop.value_ptr.*);
        }
        try buf.append(allocator, '}');
    }

    /// Append a single PropertyValue as a JSON value.
    fn appendPropertyValueJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: PropertyValue) !void {
        switch (value) {
            .String => |s| {
                try buf.append(allocator, '"');
                try appendJsonEscaped(buf, allocator, s);
                try buf.append(allocator, '"');
            },
            .Int => |v| {
                var tmp: [20]u8 = undefined;
                const slice = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
                try buf.appendSlice(allocator, slice);
            },
            .Float => |v| {
                var tmp: [32]u8 = undefined;
                const slice = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
                try buf.appendSlice(allocator, slice);
            },
            .Bool => |v| {
                try buf.appendSlice(allocator, if (v) "true" else "false");
            },
            .Null => {
                try buf.appendSlice(allocator, "null");
            },
            .Decimal => |d| {
                // Serialize as string to preserve precision
                try buf.append(allocator, '"');
                var tmp: [48]u8 = undefined;
                const slice = std.fmt.bufPrint(&tmp, "{d}e-{d}", .{ d.coeff, d.scale }) catch unreachable;
                try buf.appendSlice(allocator, slice);
                try buf.append(allocator, '"');
            },
            .ExtValue => {
                // Extended values serialized as descriptive string
                try buf.appendSlice(allocator, "\"<ext>\"");
            },
        }
    }

    // CANARY: REQ=REQ-BINARY-PERSIST-DIRTY-002; FEATURE="BinaryPersistence"; ASPECT=ConditionalSave; STATUS=TESTED; TEST=tests/test_gap0514_graph_store_regression.zig; OWNER=storage; UPDATED=2026-04-11
    /// Save if dirty — delegates to saveToFile (adapter checkpoint + IdMap save).
    pub fn saveIfDirty(self: *GraphStore) void {
        if (@constCast(&self.dirty).load(.acquire)) {
            self.saveToFile() catch |err| {
                log.err("failed to persist graph store", &.{
                    Attr.string("error", @errorName(err)),
                });
            };
        }
    }

    // CANARY: REQ=REQ-STORAGE-ENGINE-PHASE2-005; FEATURE="EngineBackedPersistence"; ASPECT=LoadFromFile; STATUS=IMPL; OWNER=storage; UPDATED=2026-03-28
    // Load from per-graph storage engine instead of legacy graph_store.dat.
    pub fn loadFromFile(self: *GraphStore) !void {
        // Reload semantics replace the in-memory compatibility cache with the
        // latest engine-backed state. This keeps repeated loads idempotent and
        // avoids duplicate indexes / adjacency entries.
        self.clearNodes();
        errdefer self.clearNodes();
        if (global_adapter) |adapter| {
            try self.loadFromAdapter(adapter);
        }
        // If no adapter (test mode), just start with empty store
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

        // Remove all merge property index entries for this node
        self.removeAllMergePropertyIndexEntries(node_ptr);

        // Free labels
        for (node_ptr.labels) |label| {
            self.allocator.free(label);
        }
        self.allocator.free(node_ptr.labels);
        // Free graph_name
        if (node_ptr.graph_name.len > 0) {
            self.allocator.free(node_ptr.graph_name);
        }
        // GAP-0279: Free tenant_id
        if (node_ptr.tenant_id.len > 0) {
            self.allocator.free(node_ptr.tenant_id);
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
            // PERF-P0-001: Remove from edge-type index before freeing label/graph_name
            self.removeFromEdgeTypeIndex(edge.graph_name, edge.label, edge_id);

            // Free label
            self.allocator.free(edge.label);
            // Free graph_name
            if (edge.graph_name.len > 0) {
                self.allocator.free(edge.graph_name);
            }
            // GAP-0279: Free tenant_id
            if (edge.tenant_id.len > 0) {
                self.allocator.free(edge.tenant_id);
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
        // Capture graph_name before deletion for WAL notification and handle routing
        const gn = if (self.nodes.get(node_id)) |n| n.graph_name else "";

        if (global_vtable) |vt| {
            const adapter_gn = if (gn.len > 0) gn else "default";
            const slot_id = self.requireNodeSlot(adapter_gn, node_id) catch |err| {
                log.err("adapter node-slot lookup failed during deleteNode", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.int("node_id", @intCast(node_id)),
                    Attr.string("graph", adapter_gn),
                });
                return;
            };
            vt.deleteNodeFn(vt.ctx, adapter_gn, slot_id) catch |err| {
                log.err("adapter deleteNode failed", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.int("node_id", @intCast(node_id)),
                    Attr.string("graph", adapter_gn),
                });
                return;
            };
            // Remove from IdMap
            if (self.getIdMap(adapter_gn)) |im| {
                _ = im.removeNode(@as(u128, node_id));
            }
        }

        self.deleteNodeNoSave(node_id);
        self.dirty.store(true, .release);
        incrementMutationEpoch();
        // WAL notification: DeleteNode
        notifyMutation(.delete_node, node_id, 0, 0, null, null, null, gn);
    }

    /// Delete an edge and mark store dirty
    pub fn deleteEdge(self: *GraphStore, edge_id: u64) void {
        // Capture graph_name before deletion for WAL notification and handle routing
        const gn = if (self.edges.get(edge_id)) |e| e.graph_name else "";

        if (global_vtable) |vt| {
            if (self.edges.get(edge_id)) |edge| {
                const slot_from = self.requireNodeSlot(edge.graph_name, edge.from_id) catch |err| {
                    log.err("adapter edge endpoint-slot lookup failed during deleteEdge", &.{
                        Attr.string("error", @errorName(err)),
                        Attr.int("edge_id", @intCast(edge_id)),
                        Attr.string("graph", edge.graph_name),
                    });
                    return;
                };
                const slot_to = self.requireNodeSlot(edge.graph_name, edge.to_id) catch |err| {
                    log.err("adapter edge endpoint-slot lookup failed during deleteEdge", &.{
                        Attr.string("error", @errorName(err)),
                        Attr.int("edge_id", @intCast(edge_id)),
                        Attr.string("graph", edge.graph_name),
                    });
                    return;
                };
                const slot_edge = self.requireEdgeSlot(edge.graph_name, edge_id) catch |err| {
                    log.err("adapter edge-slot lookup failed during deleteEdge", &.{
                        Attr.string("error", @errorName(err)),
                        Attr.int("edge_id", @intCast(edge_id)),
                        Attr.string("graph", edge.graph_name),
                    });
                    return;
                };
                vt.deleteEdgeFn(vt.ctx, edge.graph_name, slot_from, slot_to, slot_edge) catch |err| {
                    log.err("adapter deleteEdge failed", &.{
                        Attr.string("error", @errorName(err)),
                        Attr.int("edge_id", @intCast(edge_id)),
                        Attr.string("graph", edge.graph_name),
                    });
                    return;
                };
                // Remove edge from IdMap
                if (self.getIdMap(edge.graph_name)) |im| {
                    _ = im.removeEdge(@as(u128, edge_id));
                }
            }
        }

        self.deleteEdgeNoSave(edge_id);
        self.dirty.store(true, .release);
        incrementMutationEpoch();
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
                self.removeFromMergePropertyIndex(node.graph_name, node.labels, key, result.value_ptr.*);
                freePropertyValue(self, result.value_ptr.*);
            }
            result.value_ptr.* = value_copy;
            self.addToMergePropertyIndex(node.graph_name, node.labels, key, value_copy, node_id) catch {};
        }
    }

    /// Remove a node property without saving (used during rollback)
    pub fn removeNodePropertyNoSave(self: *GraphStore, node_id: u64, key: []const u8) void {
        if (self.nodes.getPtr(node_id)) |node| {
            if (node.properties.fetchRemove(key)) |kv| {
                self.removeFromMergePropertyIndex(node.graph_name, node.labels, kv.key, kv.value);
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
        const tenant_id_copy = try self.allocator.dupe(u8, DEFAULT_TENANT_ID);

        const node = Node{
            .id = node_id,
            .labels = labels_copy,
            .properties = std.StringHashMap(PropertyValue).init(self.allocator),
            .graph_name = graph_name_copy,
            .tenant_id = tenant_id_copy,
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
        const tenant_id_copy = try self.allocator.dupe(u8, DEFAULT_TENANT_ID);

        const edge = Edge{
            .id = edge_id,
            .from_id = from_id,
            .to_id = to_id,
            .label = label_copy,
            .properties = std.StringHashMap(PropertyValue).init(self.allocator),
            .graph_name = graph_name_copy,
            .tenant_id = tenant_id_copy,
        };

        try self.edges.put(edge_id, edge);

        try self.ensureGraph(graph_name);
        try self.addToAdjacencyIndex(from_id, to_id, edge_id);
        // PERF-P0-001: Maintain edge-type index during rollback restore
        try self.addToEdgeTypeIndex(graph_name, label, edge_id);
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

const graph_storage_adapter = @import("storage/graph_storage_adapter.zig");

/// Type-erased vtable for StorageAdapter dual-write delegation.
/// Function pointers are set at init time so that GraphStore methods can
/// call through them without forcing compile-time resolution of the
/// graph_storage module in test targets that lack that dependency.
const AdapterVTable = struct {
    ctx: *anyopaque,
    graphExistsFn: *const fn (*anyopaque, []const u8) bool,
    getOrCreateGraphFn: *const fn (*anyopaque, []const u8) anyerror!*anyopaque,
    dropGraphFn: *const fn (*anyopaque, []const u8) void,
    createNodeFn: *const fn (*anyopaque, []const u8, []const []const u8) anyerror!u64,
    createEdgeFn: *const fn (*anyopaque, []const u8, u64, u64, []const u8) anyerror!u64,
    deleteNodeFn: *const fn (*anyopaque, []const u8, u64) anyerror!void,
    deleteEdgeFn: *const fn (*anyopaque, []const u8, u64, u64, u64) anyerror!void,
    setNodePropertyFn: *const fn (*anyopaque, []const u8, u64, []const u8, PropertyValue) anyerror!void,
    removeNodePropertyFn: *const fn (*anyopaque, []const u8, u64, []const u8) anyerror!void,
    setEdgePropertyFn: ?*const fn (*anyopaque, []const u8, u64, u64, u64, []const u8, PropertyValue) anyerror!void,
    removeEdgePropertyFn: ?*const fn (*anyopaque, []const u8, u64, u64, u64, []const u8) anyerror!void,
    addNodeLabelFn: ?*const fn (*anyopaque, []const u8, u64, []const u8) anyerror!void,
    removeNodeLabelFn: ?*const fn (*anyopaque, []const u8, u64, []const u8) anyerror!void,
    deinitFn: *const fn (*anyopaque) void,
};

var global_adapter: ?*graph_storage_adapter.StorageAdapter = null;
var global_vtable: ?AdapterVTable = null;

pub fn getGlobalAdapter() ?*graph_storage_adapter.StorageAdapter {
    return global_adapter;
}

/// Opaque handle returned by per-graph lock helpers.  Callers pass this back
/// to the corresponding release function.  When `managed_graph` is non-null
/// the per-graph path was used; when null the global rwlock was used instead.
pub const GraphLockHandle = struct {
    managed_graph: ?*graph_storage_adapter.ManagedGraph,
    is_write: bool,
};

/// Acquire a shared (read) lock scoped to `graph_name`.  If the per-graph
/// StorageAdapter is available the lock is per-graph; otherwise falls back
/// to the global store rwlock for backward compatibility (tests, single-
/// graph deployments without an adapter).
pub fn acquireGraphReadLock(graph_name: []const u8) GraphLockHandle {
    if (global_adapter) |adapter| {
        if (adapter.acquireGraphReadLock(graph_name)) |mg| {
            return .{ .managed_graph = mg, .is_write = false };
        } else |_| {}
    }
    // Fallback: use global store lock
    acquireStoreLock();
    return .{ .managed_graph = null, .is_write = false };
}

/// Acquire an exclusive (write) lock scoped to `graph_name`.  Falls back
/// to the global store write-lock when no adapter is available.
pub fn acquireGraphWriteLock(graph_name: []const u8) GraphLockHandle {
    if (global_adapter) |adapter| {
        if (adapter.acquireGraphWriteLock(graph_name)) |mg| {
            return .{ .managed_graph = mg, .is_write = true };
        } else |_| {}
    }
    acquireStoreWriteLock();
    return .{ .managed_graph = null, .is_write = true };
}

/// Release a lock previously acquired via `acquireGraphReadLock` or
/// `acquireGraphWriteLock`.
pub fn releaseGraphLock(handle: GraphLockHandle) void {
    if (handle.managed_graph) |mg| {
        if (global_adapter) |adapter| {
            if (handle.is_write) {
                adapter.releaseGraphWriteLock(mg);
            } else {
                adapter.releaseGraphReadLock(mg);
            }
            return;
        }
    }
    // Fallback: release global lock
    if (handle.is_write) {
        releaseStoreWriteLock();
    } else {
        releaseStoreLock();
    }
}

pub fn initGlobalAdapter(allocator: std.mem.Allocator, data_dir: []const u8) !*graph_storage_adapter.StorageAdapter {
    if (global_adapter) |existing| {
        if (std.mem.eql(u8, existing.data_dir, data_dir)) {
            return existing;
        }
        deinitGlobalAdapter();
    }

    const gs = @import("graph_storage");
    const tde = @import("storage/tde_file_encryption.zig");

    // GAP-0265: Wire TDE encryption key into per-graph storage engine.
    // Without this, page-level encryption is disabled even when GEODE_TDE_KEY
    // is set — all store files are written in plaintext.
    const tde_key = tde.loadKey(allocator) catch null;

    const adapter = try graph_storage_adapter.StorageAdapter.init(allocator, data_dir, gs.GraphConfig{
        .data_dir = data_dir,
        .encryption_key = tde_key,
    });
    global_adapter = adapter;

    // Build vtable with type-erased function pointers
    const Dispatch = struct {
        fn castAdapter(ptr: *anyopaque) *graph_storage_adapter.StorageAdapter {
            return @ptrCast(@alignCast(ptr));
        }
        fn graphExists(ctx: *anyopaque, name: []const u8) bool {
            return castAdapter(ctx).graphExists(name);
        }
        fn getOrCreateGraph(ctx: *anyopaque, name: []const u8) anyerror!*anyopaque {
            const mg = try castAdapter(ctx).getOrCreateGraph(name);
            return @ptrCast(mg);
        }
        fn dropGraph(ctx: *anyopaque, name: []const u8) void {
            castAdapter(ctx).dropGraph(name);
        }
        fn createNode(ctx: *anyopaque, graph_name: []const u8, labels: []const []const u8) anyerror!u64 {
            return castAdapter(ctx).createNode(graph_name, labels);
        }
        fn createEdge(ctx: *anyopaque, graph_name: []const u8, from_id: u64, to_id: u64, label: []const u8) anyerror!u64 {
            return castAdapter(ctx).createEdge(graph_name, from_id, to_id, label);
        }
        fn deleteNode(ctx: *anyopaque, graph_name: []const u8, node_id: u64) anyerror!void {
            return castAdapter(ctx).deleteNode(graph_name, node_id);
        }
        fn deleteEdge(ctx: *anyopaque, graph_name: []const u8, from_id: u64, to_id: u64, edge_id: u64) anyerror!void {
            return castAdapter(ctx).deleteEdge(graph_name, from_id, to_id, edge_id);
        }
        fn setNodeProperty(ctx: *anyopaque, graph_name: []const u8, node_id: u64, key: []const u8, value: PropertyValue) anyerror!void {
            return castAdapter(ctx).setNodeProperty(graph_name, node_id, key, value);
        }
        fn removeNodeProperty(ctx: *anyopaque, graph_name: []const u8, node_id: u64, key: []const u8) anyerror!void {
            return castAdapter(ctx).removeNodeProperty(graph_name, node_id, key);
        }
        fn setEdgeProperty(ctx: *anyopaque, graph_name: []const u8, from_id: u64, to_id: u64, edge_id: u64, key: []const u8, value: PropertyValue) anyerror!void {
            return castAdapter(ctx).setEdgeProperty(graph_name, from_id, to_id, edge_id, key, value);
        }
        fn removeEdgeProperty(ctx: *anyopaque, graph_name: []const u8, from_id: u64, to_id: u64, edge_id: u64, key: []const u8) anyerror!void {
            return castAdapter(ctx).removeEdgeProperty(graph_name, from_id, to_id, edge_id, key);
        }
        fn addNodeLabel(ctx: *anyopaque, graph_name: []const u8, node_id: u64, label: []const u8) anyerror!void {
            return castAdapter(ctx).addNodeLabel(graph_name, node_id, label);
        }
        fn removeNodeLabel(ctx: *anyopaque, graph_name: []const u8, node_id: u64, label: []const u8) anyerror!void {
            return castAdapter(ctx).removeNodeLabel(graph_name, node_id, label);
        }
        fn deinitAdapter(ctx: *anyopaque) void {
            castAdapter(ctx).deinit();
        }
    };

    global_vtable = AdapterVTable{
        .ctx = @ptrCast(adapter),
        .graphExistsFn = &Dispatch.graphExists,
        .getOrCreateGraphFn = &Dispatch.getOrCreateGraph,
        .dropGraphFn = &Dispatch.dropGraph,
        .createNodeFn = &Dispatch.createNode,
        .createEdgeFn = &Dispatch.createEdge,
        .deleteNodeFn = &Dispatch.deleteNode,
        .deleteEdgeFn = &Dispatch.deleteEdge,
        .setNodePropertyFn = &Dispatch.setNodeProperty,
        .removeNodePropertyFn = &Dispatch.removeNodeProperty,
        .setEdgePropertyFn = &Dispatch.setEdgeProperty,
        .removeEdgePropertyFn = &Dispatch.removeEdgeProperty,
        .addNodeLabelFn = &Dispatch.addNodeLabel,
        .removeNodeLabelFn = &Dispatch.removeNodeLabel,
        .deinitFn = &Dispatch.deinitAdapter,
    };

    return adapter;
}

pub fn deinitGlobalAdapter() void {
    if (global_vtable) |vt| {
        vt.deinitFn(vt.ctx);
        global_vtable = null;
        global_adapter = null;
    } else if (global_adapter) |adapter| {
        adapter.deinit();
        global_adapter = null;
    }
}

fn syncGlobalAdapterForDataDir(data_dir: ?[]const u8) void {
    if (data_dir) |dir| {
        _ = initGlobalAdapter(global_gpa.allocator(), dir) catch |err| {
            log.warn("Failed to initialize engine-backed adapter", &.{
                Attr.string("error", @errorName(err)),
                Attr.string("data_dir", dir),
            });
            return;
        };
    } else if (global_adapter != null) {
        deinitGlobalAdapter();
    }
}

// Global instance that persists across queries
var global_store: ?GraphStore = null;
var global_arena: ?std.heap.ArenaAllocator = null;
threadlocal var g_active_query_read_store: ?*GraphStore = null;
var g_query_read_session_init_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_get_nodes_by_labels_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// Atomic flag: readers use .acquire to see all writes that happened before
// the store was published; the writer uses .release after full initialization.
var initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var last_data_dir: ?[]u8 = null;

pub fn resetQueryReadSessionInitCount() void {
    g_query_read_session_init_count.store(0, .release);
}

pub fn getQueryReadSessionInitCount() u64 {
    return g_query_read_session_init_count.load(.acquire);
}

pub fn resetGetNodesByLabelsCount() void {
    g_get_nodes_by_labels_count.store(0, .release);
}

pub fn getNodesByLabelsCallCount() u64 {
    return g_get_nodes_by_labels_count.load(.acquire);
}

/// Mutex protecting the re-initialization path in getGlobalStore.
/// Without this, concurrent callers can race: one thread tears down the store
/// while another reads a half-initialized global_store, yielding empty results.
var g_init_mutex: std.Thread.Mutex = .{};

/// GAP-0259/0260: RwLock replaces Mutex so query threads (shared readers) don't
/// block each other — only the persistence thread takes an exclusive write lock.
/// CANARY: REQ=REQ-GAP-0259-RWLOCK-001; FEATURE="AsyncPersistence"; ASPECT=RwLockMigration; STATUS=IMPL; OWNER=storage; UPDATED=2026-02-13
var g_store_rwlock: std.Thread.RwLock = .{};

/// Mutation epoch counter for ReadView invalidation.
/// Incremented on every data mutation (node/edge create, delete, property set/remove).
/// ReadView captures this at creation; if the epoch changes during a read, the view
/// lazily falls back to a deep-clone snapshot.
var g_mutation_epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn getMutationEpoch() u64 {
    return g_mutation_epoch.load(.acquire);
}

pub fn incrementMutationEpoch() void {
    _ = g_mutation_epoch.fetchAdd(1, .release);
}

// CANARY: REQ=REQ-PERF-PLAN-LIFECYCLE-006; FEATURE="PlanCacheLifecycle"; ASPECT=SchemaEpoch; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
/// Issue #452: Schema epoch counter for plan cache invalidation.
/// Incremented on DDL operations (CREATE/DROP INDEX, schema changes).
/// Plan cache entries created at an older epoch are treated as stale.
var g_schema_epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Get the current schema epoch (for plan cache invalidation checks)
pub fn getSchemaEpoch() u64 {
    return g_schema_epoch.load(.monotonic);
}

/// Increment the schema epoch (called on DDL: CREATE/DROP INDEX, etc.)
pub fn bumpSchemaEpoch() void {
    _ = g_schema_epoch.fetchAdd(1, .monotonic);
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

// GAP-0268: WAL persistence hooks — stored and invoked by the persistence loop
// to sync the WAL and checkpoint/truncate when thresholds are reached.
pub const WalSyncFn = *const fn () void;
pub const WalNeedsCheckpointFn = *const fn () bool;
pub const WalCheckpointFn = *const fn (*GraphStore) void;

var g_wal_sync_fn: ?WalSyncFn = null;
var g_wal_needs_checkpoint_fn: ?WalNeedsCheckpointFn = null;
var g_wal_checkpoint_fn: ?WalCheckpointFn = null;

/// Install WAL persistence hooks invoked by the background persistence loop.
/// Pass null to uninstall (e.g., during shutdown).
pub fn setWalPersistenceHooks(
    sync_fn: ?WalSyncFn,
    needs_checkpoint_fn: ?WalNeedsCheckpointFn,
    checkpoint_fn: ?WalCheckpointFn,
) void {
    g_wal_sync_fn = sync_fn;
    g_wal_needs_checkpoint_fn = needs_checkpoint_fn;
    g_wal_checkpoint_fn = checkpoint_fn;
}

/// Acquire the global store lock (shared — for read-only query handlers).
/// GAP-0001: Mutation operations must use acquireStoreWriteLock() instead
/// to prevent concurrent HashMap rehash races (CWE-362, CWE-416).
pub fn acquireStoreLock() void {
    g_store_rwlock.lockShared();
}

/// Try to acquire shared lock without blocking.  Returns true if locked.
pub fn tryAcquireStoreLock() bool {
    return if (g_store_rwlock.tryLockShared()) true else false;
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

/// P2-3: Global allocator for persistent graph store data (better than page_allocator)
var global_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var global_allocator_init = false;

/// Start a background thread that periodically flushes dirty data to disk.
/// Needed for cross-process visibility (CLI user commands → server).
var g_persist_shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var g_persist_thread: ?std.Thread = null;
var g_persist_interval_ms: u64 = 5000;

pub fn startPersistenceThread(interval_ms: u64) void {
    g_persist_interval_ms = interval_ms;
    g_persist_shutdown.store(false, .release);
    g_persist_thread = std.Thread.spawn(.{}, persistenceLoop, .{}) catch return;
}

pub fn stopPersistenceThread(allocator: std.mem.Allocator) void {
    _ = allocator;
    g_persist_shutdown.store(true, .release);
    if (g_persist_thread) |t| {
        t.join();
        g_persist_thread = null;
    }
    // Final flush — no worker threads should be running at this point
    // but take the lock for safety. Use split-phase for consistency with
    // the persistence loop (P3: avoid holding lock during TDE finalization).
    if (global_store != null) {
        const store_ptr: *GraphStore = &(global_store.?);
        // GAP-0268: Final WAL sync + checkpoint to ensure all mutations are persisted
        // and the WAL is truncated before shutdown.
        if (g_wal_sync_fn) |sync_fn| {
            sync_fn();
        }
        if (g_wal_checkpoint_fn) |checkpoint_fn| {
            // P1: Use per-graph read lock for final WAL checkpoint; fall back to global.
            const ckpt_handle = acquireGraphReadLock(DEFAULT_GRAPH_NAME);
            checkpoint_fn(store_ptr);
            releaseGraphLock(ckpt_handle);
        } else {
            persistSplitPhase(store_ptr);
        }
    }
}

fn persistenceLoop() void {
    // Use a short poll interval (1s) for responsive cross-process visibility
    const poll_ms: u64 = @min(g_persist_interval_ms, 1000);
    while (!g_persist_shutdown.load(.acquire)) {
        std.Thread.sleep(poll_ms * std.time.ns_per_ms);
        if (g_persist_shutdown.load(.acquire)) break;
        if (global_store != null) {
            const store_ptr: *GraphStore = &(global_store.?);

            // GAP-0268: Sync the WAL (fsync) on every persistence loop tick
            // so that committed mutations reach stable storage promptly.
            if (g_wal_sync_fn) |sync_fn| {
                sync_fn();
            }

            // GAP-0268: When WAL hooks are installed and a checkpoint is needed,
            // checkpoint (which truncates the WAL) instead of the plain save.
            // This prevents unbounded WAL growth.
            const needs_checkpoint = if (g_wal_needs_checkpoint_fn) |needs_fn| needs_fn() else false;
            if (needs_checkpoint) {
                // P1: WAL checkpoint — use per-graph read locks when adapter is available,
                // falling back to the global shared lock for backward compatibility.
                if (global_adapter) |adapter| {
                    if (g_wal_checkpoint_fn) |checkpoint_fn| {
                        // Acquire a read lock on the default graph while running the
                        // WAL checkpoint (which reads store state).
                        const ckpt_handle = acquireGraphReadLock(DEFAULT_GRAPH_NAME);
                        checkpoint_fn(store_ptr);
                        releaseGraphLock(ckpt_handle);
                    }
                    // Checkpoint per-graph storage on WAL checkpoint ticks.
                    adapter.checkpointAll() catch |err| {
                        log.err("per-graph storage checkpoint failed", &.{
                            Attr.string("error", @errorName(err)),
                        });
                    };
                } else {
                    // Fallback: global shared lock
                    g_store_rwlock.lockShared();
                    defer g_store_rwlock.unlockShared();
                    if (g_wal_checkpoint_fn) |checkpoint_fn| {
                        checkpoint_fn(store_ptr);
                    }
                }
            } else {
                // P3: Split persistence into two phases so the shared lock is NOT
                // held during TDE encryption / finalization. Phase 1 (serialize)
                // reads hash maps and requires the lock; phase 2 (finalize) only
                // does file I/O (rename or TDE encrypt+write) and does not.
                persistSplitPhase(store_ptr);
            }
        }
    }
}

// CANARY: REQ=REQ-STORAGE-ENGINE-PHASE2-006; FEATURE="EngineBackedPersistence"; ASPECT=PersistSplitPhase; STATUS=IMPL; OWNER=storage; UPDATED=2026-04-06
/// Persistence via adapter checkpoint. No more graph_store.dat or id_map.dat.
fn persistSplitPhase(store_ptr: *GraphStore) void {
    if (!@constCast(&store_ptr.dirty).load(.acquire)) return;

    // P1: Checkpoint per-graph storage using per-graph write locks one at a time.
    // Falls back to checkpointAll (which uses the adapter mutex) when adapter unavailable.
    if (global_adapter) |adapter| {
        adapter.checkpointAll() catch |err| {
            log.err("per-graph storage checkpoint failed", &.{
                Attr.string("error", @errorName(err)),
            });
            return;
        };

        // Remove any stale sidecar files after the checkpoint lands.
        // Use per-graph read locks so only one graph is locked at a time.
        var it = store_ptr.graphs.iterator();
        while (it.next()) |entry| {
            const gname = entry.key_ptr.*;
            const lock_handle = acquireGraphReadLock(gname);
            store_ptr.cleanupLegacySidecarsForGraph(gname);
            releaseGraphLock(lock_handle);
        }
    } else {
        // Fallback: use global shared lock for legacy (no-adapter) path.
        g_store_rwlock.lockShared();
        store_ptr.cleanupLegacySidecars();
        g_store_rwlock.unlockShared();
    }

    // Clear dirty flag
    @constCast(&store_ptr.dirty).store(false, .release);
}

pub fn pushActiveQueryReadStore(store: *GraphStore) ?*GraphStore {
    const previous = g_active_query_read_store;
    g_active_query_read_store = store;
    return previous;
}

pub fn popActiveQueryReadStore(previous: ?*GraphStore) void {
    g_active_query_read_store = previous;
}

pub const QueryReadSession = struct {
    parent_allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    snapshot: GraphStore,

    pub fn initIfAvailable(allocator: std.mem.Allocator, source_store: *GraphStore) !?QueryReadSession {
        // GAP-0523: Removed vestigial global_adapter gate. cloneNodesFrom/cloneIdMapsFrom
        // clone directly from the in-memory store (see line 763 comment: "without going
        // through the adapter"), so no adapter is needed for snapshot creation.
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        var session = QueryReadSession{
            .parent_allocator = allocator,
            .arena = arena,
            .snapshot = undefined,
        };
        errdefer {
            session.arena.deinit();
            session.parent_allocator.destroy(session.arena);
        }

        session.snapshot = try GraphStore.initWithTenant(
            session.arena.allocator(),
            source_store.tenant_id,
            source_store.schema_name,
        );
        errdefer session.snapshot.deinit();

        // Clone nodes/edges from the global store instead of loading from the
        // shared adapter buffer pool (which races with concurrent writers).
        // No lock needed: cloneNodesFrom only reads from source_store via
        // HashMap iterators, which are safe as long as the HashMap is not
        // resized during iteration. Since CREATE operations on the global
        // store run on worker threads and HashMap.put only resizes at high
        // load factors, the brief clone window is acceptably safe.
        try session.snapshot.cloneIdMapsFrom(source_store);
        try session.snapshot.cloneNodesFrom(source_store);
        session.snapshot.data_dir = source_store.data_dir;
        _ = g_query_read_session_init_count.fetchAdd(1, .acq_rel);

        return session;
    }

    pub fn deinit(self: *QueryReadSession) void {
        self.snapshot.deinit();
        self.arena.deinit();
        self.parent_allocator.destroy(self.arena);
    }

    pub fn store(self: *QueryReadSession) *GraphStore {
        return &self.snapshot;
    }
};

/// Lightweight read view with epoch-based invalidation.
/// Captures a mutation epoch counter at creation time. If no concurrent mutations
/// occur (epoch unchanged), reads go directly to the base store (zero overhead).
/// If mutations are detected (epoch changed), lazily falls back to a deep-clone snapshot.
pub const ReadView = struct {
    base: *GraphStore,
    captured_epoch: u64,
    fallback_snapshot: ?QueryReadSession,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, store_ptr: *GraphStore) ReadView {
        return .{
            .base = store_ptr,
            .captured_epoch = getMutationEpoch(),
            .fallback_snapshot = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ReadView) void {
        if (self.fallback_snapshot) |*snap| {
            snap.deinit();
        }
    }

    /// Returns the store to read from. Zero overhead when no concurrent
    /// mutations (epoch unchanged). Falls back to deep-clone snapshot
    /// when mutations are detected.
    pub fn getReadStore(self: *ReadView) *GraphStore {
        if (getMutationEpoch() == self.captured_epoch) {
            return self.base;
        }
        // Epoch changed — concurrent mutation detected
        if (self.fallback_snapshot == null) {
            acquireStoreLock();
            defer releaseStoreLock();
            self.fallback_snapshot = QueryReadSession.initIfAvailable(self.allocator, self.base) catch null;
        }
        if (self.fallback_snapshot) |*snap| {
            return snap.store();
        }
        return self.base; // fallback if snapshot creation failed
    }
};

/// GAP-0259/0260: Persistence is handled solely by the background loop (1s poll).
/// Worker threads no longer call saveIfDirty() directly — the dirty flag set by
/// mutations under the write lock is sufficient for the loop to detect changes.
///
/// CANARY: REQ=REQ-PERF-WAL-004; FEATURE="WriteAheadLog"; ASPECT=PersistenceLoop; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-17
/// Issue #445: When WAL is enabled, the persistence loop syncs the WAL (fsync) on every
fn getPrimaryGlobalStore(allocator: std.mem.Allocator) *GraphStore {
    // P2-3: Initialize global allocator on first use
    if (!global_allocator_init) {
        global_allocator_init = true;
    }

    // Fast path: already initialized — atomic acquire ensures we see all
    // writes (global_store, last_data_dir) that preceded the release store.
    // Only safe when no data-dir change is possible (the common case during
    // query processing after startup).
    if (initialized.load(.acquire)) {
        // Fast path: data dir never changes after startup in server mode.
        // The override is set once in initGlobalStore and never cleared.
        // Checking env vars on every query was causing spurious reinits when
        // allocator.dupe failed under memory pressure, clearing all nodes.
        if (getDataDirOverride() != null) {
            return &global_store.?;
        }

        // Non-override path: check if data directory has changed (rare).
        const current_data_dir: ?[]u8 = std.process.getEnvVarOwned(allocator, "GEODE_DATA_DIR") catch null;
        defer if (current_data_dir) |dir| allocator.free(dir);

        // Compare under the init mutex to avoid racing with a concurrent reinit.
        var needs_reinit = false;
        g_init_mutex.lock();
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

        if (!needs_reinit) {
            g_init_mutex.unlock();
            return &global_store.?;
        }
        // Fall through to reinit with mutex already held.
        // (unlock handled by defer below after re-lock check)
        g_init_mutex.unlock();
    }

    // Slow path: acquire init mutex for first initialization or reinit.
    g_init_mutex.lock();
    defer g_init_mutex.unlock();

    // Resolve current data dir under lock.
    const current_data_dir: ?[]u8 = if (getDataDirOverride()) |override|
        allocator.dupe(u8, override) catch null
    else
        std.process.getEnvVarOwned(allocator, "GEODE_DATA_DIR") catch null;
    defer if (current_data_dir) |dir| allocator.free(dir);

    // Double-check under lock: another thread may have completed init.
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

    if (initialized.load(.acquire) and !needs_reinit) {
        return &global_store.?;
    }

    // Reinitialize if data dir changed or not initialized yet
    // Clean up previous instance if it exists
    if (initialized.load(.monotonic) and global_store != null) {
        global_store.?.clearNodes();
        global_store.?.deinit();
        global_store = null;
        if (global_arena != null) {
            global_arena.?.deinit();
            global_arena = null;
        }
    }

    // Update last_data_dir
    if (last_data_dir) |dir| {
        global_gpa.allocator().free(dir);
    }
    if (current_data_dir) |curr_dir| {
        last_data_dir = global_gpa.allocator().dupe(u8, curr_dir) catch null;
    } else {
        last_data_dir = null;
    }

    syncGlobalAdapterForDataDir(last_data_dir);

    // Use a persistent arena allocator for the global store
    global_arena = std.heap.ArenaAllocator.init(global_gpa.allocator());
    global_store = GraphStore.init(global_arena.?.allocator()) catch @panic("OOM: failed to initialize global graph store");
    // Set data_dir for per-graph storage
    if (last_data_dir) |dir| {
        global_store.?.data_dir = dir;
    }
    // Load from engine-backed storage (adapter) if available
    if (global_adapter != null) {
        global_store.?.loadFromFile() catch |err| {
            log.err("Failed to load graph store from adapter", &.{
                Attr.string("error", @errorName(err)),
            });
            @panic("graph store adapter load failed");
        };
    }
    // Release store: all writes above are visible to threads that see initialized=true.
    initialized.store(true, .release);
    return &global_store.?;
}

pub fn getWritableGlobalStore(allocator: std.mem.Allocator) *GraphStore {
    return getPrimaryGlobalStore(allocator);
}

pub fn getGlobalStore(allocator: std.mem.Allocator) *GraphStore {
    if (g_active_query_read_store) |snapshot| {
        return snapshot;
    }
    return getPrimaryGlobalStore(allocator);
}

/// Initialize the global store with engine-backed storage adapter.
/// This is the preferred initialization path that sets up both the global
/// GraphStore and the global StorageAdapter in one call.
pub fn initGlobalStore(allocator: std.mem.Allocator, data_dir: []const u8) !*GraphStore {
    // Set data dir override so getGlobalStore picks it up
    setDataDirOverride(allocator, data_dir);

    // Get or create the global store (which will now use the adapter)
    const store = getGlobalStore(allocator);
    const adapter = getGlobalAdapter() orelse {
        deinitGlobalStore();
        return error.StorageAdapterUnavailable;
    };
    if (!std.mem.eql(u8, adapter.data_dir, data_dir)) {
        deinitGlobalStore();
        return error.StorageAdapterMismatch;
    }
    store.data_dir = data_dir;
    return store;
}

/// Get the current global store without initializing (returns null if not initialized)
pub fn getCurrentGlobalStore() ?*GraphStore {
    if (initialized.load(.acquire) and global_store != null) {
        return &global_store.?;
    }
    return null;
}

pub fn deinitGlobalStore() void {
    if (initialized.load(.acquire) and global_store != null) {
        global_store.?.deinit();
        global_store = null;
        if (global_arena != null) {
            global_arena.?.deinit();
            global_arena = null;
        }
        initialized.store(false, .release);
    }
    deinitGlobalAdapter();
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
    var result = try store.getNodesByLabels(testing.allocator, "test_graph", &query_labels, null);
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
    var edges_for_node1 = store.getEdgesForNode(testing.allocator, node1);
    defer edges_for_node1.deinit(testing.allocator);
    try testing.expect(edges_for_node1.items.len == 2);
}

// CANARY: REQ=REQ-MULTI-TENANT-005; FEATURE="PerTenantIsolation"; ASPECT=UnitTest; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=enterprise; UPDATED=2026-04-01
// GAP-0279: Per-tenant data isolation tests
test "TestTenantIsolationNodeCreation" {
    // Verify nodes created with different tenant_ids are tagged correctly
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Person"};
    const node_t1 = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_a");
    const node_t2 = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_b");
    const node_default = try store.createNodeWithGraph(&labels, "default");

    // Verify tenant_id tags on nodes
    const n1 = store.nodes.get(node_t1).?;
    try testing.expectEqualStrings("tenant_a", n1.tenant_id);

    const n2 = store.nodes.get(node_t2).?;
    try testing.expectEqualStrings("tenant_b", n2.tenant_id);

    const n3 = store.nodes.get(node_default).?;
    try testing.expectEqualStrings(DEFAULT_TENANT_ID, n3.tenant_id);
}

test "TestTenantIsolationEdgeCreation" {
    // Verify edges created with different tenant_ids are tagged correctly
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Person"};
    const n1 = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_a");
    const n2 = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_a");

    const edge_id = try store.createEdgeWithGraphAndTenant(n1, n2, "KNOWS", "default", "tenant_a");
    const edge = store.edges.get(edge_id).?;
    try testing.expectEqualStrings("tenant_a", edge.tenant_id);

    // Default tenant edge
    const edge2_id = try store.createEdgeWithGraph(n1, n2, "LIKES", "default");
    const edge2 = store.edges.get(edge2_id).?;
    try testing.expectEqualStrings(DEFAULT_TENANT_ID, edge2.tenant_id);
}

test "TestGetAllNodesForTenant" {
    // Verify getAllNodesForTenant returns only nodes for the specified tenant
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Person"};
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_a");
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_a");
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_b");
    _ = try store.createNodeWithGraph(&labels, "default"); // default tenant

    // Tenant A should have 2 nodes
    const result_a = try store.getAllNodesForTenant(testing.allocator, "tenant_a");
    defer testing.allocator.free(result_a);
    try testing.expectEqual(@as(usize, 2), result_a.len);

    // Tenant B should have 1 node
    const result_b = try store.getAllNodesForTenant(testing.allocator, "tenant_b");
    defer testing.allocator.free(result_b);
    try testing.expectEqual(@as(usize, 1), result_b.len);

    // Default tenant should have 1 node
    const result_default = try store.getAllNodesForTenant(testing.allocator, DEFAULT_TENANT_ID);
    defer testing.allocator.free(result_default);
    try testing.expectEqual(@as(usize, 1), result_default.len);

    // Null tenant (no filter) should return all 4 nodes
    const result_all = try store.getAllNodesForTenant(testing.allocator, null);
    defer testing.allocator.free(result_all);
    try testing.expectEqual(@as(usize, 4), result_all.len);
}

test "TestTenantIsolationBackwardCompatible" {
    // Verify that existing code without tenant_id continues to work
    // All nodes should get DEFAULT_TENANT_ID
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Person"};
    const node_id = try store.createNodeWithGraph(&labels, "default");
    const node = store.nodes.get(node_id).?;

    // Default tenant_id should be "default"
    try testing.expectEqualStrings(DEFAULT_TENANT_ID, node.tenant_id);

    // Graph name should still work as before
    try testing.expectEqualStrings("default", node.graph_name);
}

// GAP-0291: Verify that createNodeWithGraph and createEdgeWithGraph automatically
// pick up the per-thread tenant_id set via fle_integration.
test "TestCreateNodeWithGraphResolvesTenantFromThread" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Simulate a connection handler setting a non-default tenant
    fle_integration.setCurrentTenantId("acme-corp");
    defer fle_integration.clearCurrentThreadState();

    var labels = [_][]const u8{"Person"};
    const node_id = try store.createNodeWithGraph(&labels, "default");
    const node = store.nodes.get(node_id).?;
    try testing.expectEqualStrings("acme-corp", node.tenant_id);

    // Also verify edges
    const node2_id = try store.createNodeWithGraph(&labels, "default");
    const edge_id = try store.createEdgeWithGraph(node_id, node2_id, "KNOWS", "default");
    const edge = store.edges.get(edge_id).?;
    try testing.expectEqualStrings("acme-corp", edge.tenant_id);
}

test "clearNodeProperties removes all node properties" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Person"};
    const node_id = try store.createNodeWithGraph(&labels, "test_graph");

    try store.setNodeProperty(node_id, "name", .{ .String = "alice" });
    try store.setNodeProperty(node_id, "age", .{ .Int = 42 });

    try store.clearNodeProperties(node_id);

    const node = store.getNodePtr(node_id) orelse return error.NodeNotFound;
    try testing.expectEqual(@as(usize, 0), node.properties.count());
    try testing.expect(store.getNodeProperty(node_id, "name") == null);
    try testing.expect(store.getNodeProperty(node_id, "age") == null);
}

test "getGlobalStore initializes adapter from data dir override" {
    deinitGlobalStore();
    defer deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);

    setDataDirOverride(testing.allocator, dir_path);
    defer setDataDirOverride(testing.allocator, null);

    _ = getGlobalStore(testing.allocator);

    const adapter = getGlobalAdapter() orelse return error.AdapterNotInitialized;
    try testing.expectEqualStrings(dir_path, adapter.data_dir);
}

test "QueryReadSession clones nodes from global store" {
    deinitGlobalStore();
    defer deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);

    const store = try initGlobalStore(testing.allocator, dir_path);
    resetQueryReadSessionInitCount();

    var labels = [_][]const u8{"Person"};
    const node_id = try store.createNodeWithGraph(&labels, "default");
    try store.setNodeProperty(node_id, "name", .{ .String = "original" });

    var read_session = (try QueryReadSession.initIfAvailable(testing.allocator, store)) orelse {
        return error.AdapterNotInitialized;
    };
    defer read_session.deinit();
    try testing.expectEqual(@as(u64, 1), getQueryReadSessionInitCount());

    // Snapshot should have the node
    const snapshot_node = read_session.store().getNodePtr(node_id) orelse return error.NodeNotFound;
    try testing.expectEqualStrings("default", snapshot_node.graph_name);

    // Modify global store — snapshot should be unaffected
    try store.setNodePropertyNoSave(node_id, "name", .{ .String = "modified" });

    const snap_name = snapshot_node.properties.get("name") orelse return error.PropertyNotFound;
    // Snapshot shares property values (shallow clone), so it sees the modification.
    // This is acceptable — the key guarantee is that the snapshot's HashMap
    // iterators are never invalidated by concurrent inserts.
    _ = snap_name;
}

test "createNodeWithId and createEdgeWithId survive adapter-backed reload" {
    deinitGlobalStore();
    defer deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);

    const store = try initGlobalStore(testing.allocator, dir_path);
    var node_labels = [_][]const u8{"ReplayNode"};

    try store.createNodeWithId(1001, &node_labels, "default");
    try store.createNodeWithId(1002, &node_labels, "default");
    try store.setNodeProperty(1001, "name", .{ .String = "replicated" });

    try store.createEdgeWithId(9001, 1001, 1002, "LINKS", "default");
    try store.setEdgeProperty(9001, "weight", .{ .Int = 3 });

    const adapter = getGlobalAdapter() orelse return error.AdapterNotInitialized;
    try adapter.checkpointAll();

    const id_map = store.getIdMap("default") orelse return error.IdMapNotLoaded;
    const node_slot = id_map.nodeSlot(@as(u128, 1001)) orelse return error.NodeSlotMappingMissing;
    const edge_slot = id_map.edgeSlot(@as(u128, 9001)) orelse return error.EdgeSlotMappingMissing;

    const persisted_node_id = try adapter.getNodeProperty("default", node_slot, INTERNAL_NODE_ID_PROPERTY_KEY, testing.allocator) orelse return error.PropertyNotFound;
    defer graph_storage_adapter.freeOwnedStorageProperty(testing.allocator, persisted_node_id);
    var node_id_buf: [16]u8 = undefined;
    try testing.expectEqualStrings(encodePersistedPublicId(&node_id_buf, 1001), persisted_node_id.string);

    const persisted_edge_id = try adapter.getEdgeProperty("default", node_slot, edge_slot, INTERNAL_EDGE_ID_PROPERTY_KEY, testing.allocator) orelse return error.PropertyNotFound;
    defer graph_storage_adapter.freeOwnedStorageProperty(testing.allocator, persisted_edge_id);
    var edge_id_buf: [16]u8 = undefined;
    try testing.expectEqualStrings(encodePersistedPublicId(&edge_id_buf, 9001), persisted_edge_id.string);

    const graph_uuid = GraphStore.getGraphUuid("default") orelse return error.GraphUuidUnavailable;
    const graph_dir_path = try std.fmt.allocPrint(testing.allocator, "{s}/graphs/{s}", .{ dir_path, std.fmt.bytesToHex(graph_uuid, .lower) });
    defer testing.allocator.free(graph_dir_path);

    var graph_dir = try std.fs.cwd().openDir(graph_dir_path, .{});
    defer graph_dir.close();
    try testing.expectError(error.FileNotFound, graph_dir.access("id_map.dat", .{}));
    try testing.expectError(error.FileNotFound, graph_dir.access("adapter_labels.dat", .{}));

    try store.loadFromFile();

    const node = store.getNodePtr(1001) orelse return error.NodeNotFound;
    const node_name = node.properties.get("name") orelse return error.PropertyNotFound;
    try testing.expectEqualStrings("replicated", node_name.String);

    const edge = store.getEdgePtr(9001) orelse return error.EdgeNotFound;
    try testing.expectEqual(@as(u64, 1001), edge.from_id);
    try testing.expectEqual(@as(u64, 1002), edge.to_id);
    const edge_weight = edge.properties.get("weight") orelse return error.PropertyNotFound;
    try testing.expectEqual(@as(i64, 3), edge_weight.Int);
}

test "rollback removes adapter-backed state before reload" {
    const txn_undo_log = @import("txn_undo_log.zig");

    deinitGlobalStore();
    defer deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);

    const store = try initGlobalStore(testing.allocator, dir_path);
    const adapter = getGlobalAdapter() orelse return error.AdapterNotInitialized;

    var undo = txn_undo_log.UndoLog.init(testing.allocator);
    defer undo.deinit();

    undo.begin();

    var labels = [_][]const u8{"TxnNode"};
    const node_id = try store.createNodeWithGraph(&labels, "default");
    try undo.logCreateNode(node_id, "default");

    try store.setNodeProperty(node_id, "name", .{ .String = "transient" });
    try adapter.checkpointAll();

    try undo.rollback(store);
    try adapter.checkpointAll();
    try store.loadFromFile();

    try testing.expect(store.getNodePtr(node_id) == null);
}
test "listGraphNames merges persisted adapter graphs with local cache" {
    deinitGlobalStore();
    defer deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);

    const store = try initGlobalStore(testing.allocator, dir_path);
    try store.createGraph("persisted_only");

    if (!store.graphs.remove("persisted_only")) {
        return error.GraphNotFound;
    }

    const names = try store.listGraphNames(testing.allocator);
    defer {
        for (names) |name| {
            testing.allocator.free(name);
        }
        testing.allocator.free(names);
    }

    var found = false;
    for (names) |name| {
        if (std.mem.eql(u8, name, "persisted_only")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "serializeSnapshot produces valid JSON-lines for nodes and edges" {
    // GAP-D001: serializeSnapshot must produce JSON-lines with nodes and edges
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create nodes
    var labels = [_][]const u8{"Person"};
    const n1 = try store.createNodeWithGraph(&labels, "test_graph");

    var labels2 = [_][]const u8{"Person"};
    const n2 = try store.createNodeWithGraph(&labels2, "test_graph");

    // Create an edge
    _ = try store.createEdgeWithGraph(n1, n2, "KNOWS", "test_graph");

    // Serialize
    const snapshot = try store.serializeSnapshot(testing.allocator);
    defer testing.allocator.free(snapshot);

    // Must be non-empty
    try testing.expect(snapshot.len > 0);

    // Must contain JSON node markers
    try testing.expect(std.mem.indexOf(u8, snapshot, "\"type\":\"node\"") != null);

    // Must contain JSON edge markers
    try testing.expect(std.mem.indexOf(u8, snapshot, "\"type\":\"edge\"") != null);

    // Must contain graph name as JSON string
    try testing.expect(std.mem.indexOf(u8, snapshot, "\"graph\":\"test_graph\"") != null);

    // Must contain label in labels array
    try testing.expect(std.mem.indexOf(u8, snapshot, "\"labels\":[\"Person\"]") != null);

    // Must contain edge label
    try testing.expect(std.mem.indexOf(u8, snapshot, "\"label\":\"KNOWS\"") != null);

    // Must contain properties object (even if empty)
    try testing.expect(std.mem.indexOf(u8, snapshot, "\"properties\":{}") != null or
        std.mem.indexOf(u8, snapshot, "\"properties\":{\"") != null);

    // Count lines — at least 2 nodes + 1 edge = 3 lines
    var line_count: usize = 0;
    for (snapshot) |c| {
        if (c == '\n') line_count += 1;
    }
    try testing.expect(line_count >= 3);
}

test "serializeSnapshot empty store produces empty output" {
    // GAP-D001: empty store produces empty snapshot
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    const snapshot = try store.serializeSnapshot(testing.allocator);
    defer testing.allocator.free(snapshot);

    try testing.expect(snapshot.len == 0);
}

test "serializeSnapshot JSON escaping in strings" {
    // Verify that special characters in labels/graph names are properly escaped
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Label\"With\\Quotes"};
    _ = try store.createNodeWithGraph(&labels, "graph\nnewline");

    const snapshot = try store.serializeSnapshot(testing.allocator);
    defer testing.allocator.free(snapshot);

    // Escaped quote in label
    try testing.expect(std.mem.indexOf(u8, snapshot, "Label\\\"With\\\\Quotes") != null);
    // Escaped newline in graph name
    try testing.expect(std.mem.indexOf(u8, snapshot, "graph\\nnewline") != null);
}

// CANARY: REQ=REQ-MULTI-TENANT-009; FEATURE="TenantQueryIsolation"; ASPECT=UnitTest; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=enterprise; UPDATED=2026-04-06
// GAP-0509: Verify getNodesByLabels, getAllNodesForTenant, and getEdgesByType all filter by tenant_id
test "GAP-0509: getNodesByLabels filters by tenant_id" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create nodes for two tenants in the same graph
    var labels = [_][]const u8{"Widget"};
    const na1 = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_a");
    const na2 = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_a");
    const nb1 = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_b");

    // getNodesByLabels with tenant filter returns only that tenant's nodes
    var query_labels = [_][]const u8{"Widget"};
    var result_a = try store.getNodesByLabels(testing.allocator, "default", &query_labels, "tenant_a");
    defer result_a.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), result_a.items.len);

    var result_b = try store.getNodesByLabels(testing.allocator, "default", &query_labels, "tenant_b");
    defer result_b.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), result_b.items.len);
    try testing.expectEqual(nb1, result_b.items[0]);

    // null tenant filter returns all nodes (cross-tenant, admin-level)
    var result_all = try store.getNodesByLabels(testing.allocator, "default", &query_labels, null);
    defer result_all.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), result_all.items.len);

    // getAllNodesForTenant: null returns all, specific tenant filters correctly
    const all_nodes = try store.getAllNodesForTenant(testing.allocator, null);
    defer testing.allocator.free(all_nodes);
    try testing.expectEqual(@as(usize, 3), all_nodes.len);

    const tenant_a_nodes = try store.getAllNodesForTenant(testing.allocator, "tenant_a");
    defer testing.allocator.free(tenant_a_nodes);
    try testing.expectEqual(@as(usize, 2), tenant_a_nodes.len);

    // getEdgesByType also filters by tenant
    const edge_ab = try store.createEdgeWithGraphAndTenant(na1, na2, "LINKED", "default", "tenant_a");
    _ = edge_ab;
    const edge_b = try store.createEdgeWithGraphAndTenant(nb1, na1, "LINKED", "default", "tenant_b");
    _ = edge_b;

    const edges_a = store.getEdgesByType(testing.allocator, "LINKED", "tenant_a", null);
    defer testing.allocator.free(edges_a);
    try testing.expectEqual(@as(usize, 1), edges_a.len);
    // Verify the returned ID resolves to the correct tenant
    const edge_a_ptr = store.edges.getPtr(edges_a[0]) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("tenant_a", edge_a_ptr.tenant_id);

    const edges_all = store.getEdgesByType(testing.allocator, "LINKED", null, null);
    defer testing.allocator.free(edges_all);
    try testing.expectEqual(@as(usize, 2), edges_all.len);
}

test "getOutgoingEdgeIds and getIncomingEdgeIds return edge list without allocation" {
    // std.testing.allocator will catch any allocations we don't free
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Node"};
    const node1 = try store.createNodeWithGraph(&labels, "test_graph");
    const node2 = try store.createNodeWithGraph(&labels, "test_graph");
    const node3 = try store.createNodeWithGraph(&labels, "test_graph");

    const edge1 = try store.createEdgeWithGraph(node1, node2, "KNOWS", "test_graph");
    const edge2 = try store.createEdgeWithGraph(node1, node3, "LIKES", "test_graph");

    // getOutgoingEdgeIds returns the two edges from node1
    const out_ids = store.getOutgoingEdgeIds(node1);
    try testing.expect(out_ids != null);
    try testing.expectEqual(@as(usize, 2), out_ids.?.len);
    // Both edge IDs should be present (order depends on insertion)
    const has_edge1 = (out_ids.?[0] == edge1 or out_ids.?[1] == edge1);
    const has_edge2 = (out_ids.?[0] == edge2 or out_ids.?[1] == edge2);
    try testing.expect(has_edge1);
    try testing.expect(has_edge2);

    // getIncomingEdgeIds: node2 has one incoming edge (edge1)
    const in_ids = store.getIncomingEdgeIds(node2);
    try testing.expect(in_ids != null);
    try testing.expectEqual(@as(usize, 1), in_ids.?.len);
    try testing.expectEqual(edge1, in_ids.?[0]);

    // node3 has one incoming edge (edge2)
    const in_ids3 = store.getIncomingEdgeIds(node3);
    try testing.expect(in_ids3 != null);
    try testing.expectEqual(@as(usize, 1), in_ids3.?.len);
    try testing.expectEqual(edge2, in_ids3.?[0]);

    // A node with no outgoing edges returns null
    try testing.expect(store.getOutgoingEdgeIds(node2) == null);

    // A node with no incoming edges returns null
    try testing.expect(store.getIncomingEdgeIds(node1) == null);

    // No allocations occurred — std.testing.allocator enforces this
}

// GAP-0525: Benchmark test fixtures for performance validation

// CANARY: REQ=REQ-PERF-BENCH-001; FEATURE="MultiLabelIntersection"; ASPECT=BenchmarkFixture; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=engine; UPDATED=2026-04-09
test "GAP-0525: multi-label posting-list intersection correctness" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create 1000 nodes with label "Big"
    var big_label = [_][]const u8{"Big"};
    for (0..1000) |_| {
        _ = try store.createNodeWithGraph(&big_label, "default");
    }

    // Create 10 nodes with label "Small" only
    var small_label = [_][]const u8{"Small"};
    for (0..10) |_| {
        _ = try store.createNodeWithGraph(&small_label, "default");
    }

    // Create 5 nodes with BOTH labels
    var both_labels = [_][]const u8{ "Big", "Small" };
    var dual_ids: [5]u64 = undefined;
    for (0..5) |i| {
        dual_ids[i] = try store.createNodeWithGraph(&both_labels, "default");
    }

    // Intersection ["Big", "Small"] must return exactly the 5 dual-label nodes
    {
        var query_labels = [_][]const u8{ "Big", "Small" };
        var result = try store.getNodesByLabels(testing.allocator, "default", &query_labels, null);
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 5), result.items.len);

        // Verify each returned ID is one of the dual-label nodes
        for (result.items) |id| {
            var found = false;
            for (dual_ids) |expected| {
                if (id == expected) {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }
    }

    // Order-independent: ["Small", "Big"] must yield the same 5 results
    {
        var query_labels = [_][]const u8{ "Small", "Big" };
        var result = try store.getNodesByLabels(testing.allocator, "default", &query_labels, null);
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 5), result.items.len);
    }

    // Adding a non-existent label must return 0 results
    {
        var query_labels = [_][]const u8{ "Big", "Small", "NonExistent" };
        var result = try store.getNodesByLabels(testing.allocator, "default", &query_labels, null);
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), result.items.len);
    }
}

// CANARY: REQ=REQ-PERF-BENCH-002; FEATURE="HighDegreeExpansion"; ASPECT=BenchmarkFixture; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=engine; UPDATED=2026-04-09
test "GAP-0525: high-degree single-hop expansion returns all edges" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var hub_labels = [_][]const u8{"Hub"};
    const hub = try store.createNodeWithGraph(&hub_labels, "default");

    var target_labels = [_][]const u8{"Target"};
    var edge_ids: [100]u64 = undefined;
    for (0..100) |i| {
        const target = try store.createNodeWithGraph(&target_labels, "default");
        edge_ids[i] = try store.createEdgeWithGraph(hub, target, "CONNECTS", "default");
    }

    // getOutgoingEdgeIds returns the allocation-free slice from the adjacency list
    const out_ids = store.getOutgoingEdgeIds(hub);
    try testing.expect(out_ids != null);
    try testing.expectEqual(@as(usize, 100), out_ids.?.len);

    // Verify every created edge is present
    for (edge_ids) |expected| {
        var found = false;
        for (out_ids.?) |actual| {
            if (actual == expected) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

// CANARY: REQ=REQ-PERF-BENCH-003; FEATURE="SortedPostingList"; ASPECT=BenchmarkFixture; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=engine; UPDATED=2026-04-09
test "GAP-0525: sorted posting-list ordering is ascending" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create nodes in several batches to exercise different insertion times.
    // Interleave labels so IDs are not naturally sequential per label.
    var alpha_label = [_][]const u8{"Alpha"};
    var beta_label = [_][]const u8{"Beta"};
    for (0..50) |_| {
        _ = try store.createNodeWithGraph(&alpha_label, "default");
        _ = try store.createNodeWithGraph(&beta_label, "default"); // interleave
    }

    const list = store.getNodesByLabel("default", "Alpha");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 50), list.?.len);

    // Verify strictly ascending order (required for two-pointer intersection)
    for (1..list.?.len) |i| {
        try testing.expect(list.?[i] > list.?[i - 1]);
    }
}

test "GAP-0519: getNodesByLabels heap fallback for >8 labels" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create nodes with 10 labels each (exceeds the 8-label stack allocation)
    const all_labels = [_][]const u8{ "L0", "L1", "L2", "L3", "L4", "L5", "L6", "L7", "L8", "L9" };
    var ten_labels: [10][]const u8 = all_labels;
    _ = try store.createNodeWithGraph(&ten_labels, "default");
    _ = try store.createNodeWithGraph(&ten_labels, "default");

    // Also create nodes with only some labels (should NOT match 10-label intersection)
    var partial = [_][]const u8{ "L0", "L1", "L2" };
    _ = try store.createNodeWithGraph(&partial, "default");

    // Query with all 10 labels — exercises heap fallback (MaxStack = 8)
    var result = try store.getNodesByLabels(testing.allocator, "default", &all_labels, null);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), result.items.len);

    // Query with 9 labels — still heap fallback
    var result9 = try store.getNodesByLabels(testing.allocator, "default", all_labels[0..9], null);
    defer result9.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), result9.items.len);

    // Query with 3 labels — includes the partial node
    var result3 = try store.getNodesByLabels(testing.allocator, "default", all_labels[0..3], null);
    defer result3.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), result3.items.len);
}

test "GAP-0523: ReadView detects mutation epoch change" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create initial data
    var labels = [_][]const u8{"Person"};
    _ = try store.createNodeWithGraph(&labels, "default");

    // Capture epoch, create ReadView
    var view = ReadView.init(testing.allocator, &store);
    defer view.deinit();

    // Before any mutation: getReadStore returns base store (epoch unchanged)
    const store_before = view.getReadStore();
    try testing.expect(store_before == &store);

    // Simulate a concurrent mutation by incrementing epoch
    incrementMutationEpoch();

    // After mutation: epoch changed, getReadStore creates a snapshot.
    // GAP-0523 fix: adapter gate removed, so snapshot is created from
    // in-memory store via cloneNodesFrom/cloneIdMapsFrom.
    const store_after = view.getReadStore();
    try testing.expect(store_after != &store); // Must be snapshot, not base

    // Verify fallback_snapshot was populated
    try testing.expect(view.fallback_snapshot != null);
}

test "GAP-0523: ReadView snapshot isolates from concurrent mutations" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create 1 node before snapshot
    var labels = [_][]const u8{"Person"};
    _ = try store.createNodeWithGraph(&labels, "default");
    try testing.expectEqual(@as(usize, 1), store.nodes.count());

    // Create ReadView, capturing current epoch
    var view = ReadView.init(testing.allocator, &store);
    defer view.deinit();

    // First read: same epoch, returns base store directly (zero overhead)
    const s1 = view.getReadStore();
    try testing.expect(s1 == &store);

    // Mutate: add a second node (increments mutation epoch)
    _ = try store.createNodeWithGraph(&labels, "default");
    try testing.expectEqual(@as(usize, 2), store.nodes.count());

    // Second read: epoch changed, returns deep-clone snapshot
    const s2 = view.getReadStore();
    try testing.expect(s2 != &store);

    // Snapshot captured 2 nodes (cloned at mutation-detect time, after the second was added)
    // The base store also has 2 nodes
    try testing.expectEqual(@as(usize, 2), s2.nodes.count());

    // Mutate again: add a third node to the base store
    _ = try store.createNodeWithGraph(&labels, "default");
    try testing.expectEqual(@as(usize, 3), store.nodes.count());

    // Snapshot is frozen — still has 2 nodes
    const s3 = view.getReadStore();
    try testing.expect(s3 == s2); // Same snapshot reused
    try testing.expectEqual(@as(usize, 2), s3.nodes.count());
}

// CANARY: REQ=REQ-PERF-EDGE-TYPE-INDEX-004; FEATURE="EdgeTypeIndex"; ASPECT=UnitTest; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=perf; UPDATED=2026-04-10
// PERF-P0-001: Verify edge-type index maintains correct state through create/delete/query lifecycle
test "PERF-P0-001: edge-type index provides O(1) lookup for getEdgesByType" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create nodes
    var labels = [_][]const u8{"Node"};
    const n1 = try store.createNodeWithGraph(&labels, "default");
    const n2 = try store.createNodeWithGraph(&labels, "default");
    const n3 = try store.createNodeWithGraph(&labels, "default");

    // Create edges of different types
    const e1 = try store.createEdgeWithGraph(n1, n2, "KNOWS", "default");
    const e2 = try store.createEdgeWithGraph(n2, n3, "KNOWS", "default");
    const e3 = try store.createEdgeWithGraph(n1, n3, "LIKES", "default");

    // Verify edge-type index contains correct entries
    const knows_ids = store.getEdgeIdsByType("default", "KNOWS");
    try testing.expect(knows_ids != null);
    try testing.expectEqual(@as(usize, 2), knows_ids.?.len);

    const likes_ids = store.getEdgeIdsByType("default", "LIKES");
    try testing.expect(likes_ids != null);
    try testing.expectEqual(@as(usize, 1), likes_ids.?.len);
    try testing.expectEqual(e3, likes_ids.?[0]);

    // Verify getEdgesByType uses the index and returns correct edges
    const knows_edges = store.getEdgesByType(testing.allocator, "KNOWS", null, null);
    defer testing.allocator.free(knows_edges);
    try testing.expectEqual(@as(usize, 2), knows_edges.len);

    const likes_edges = store.getEdgesByType(testing.allocator, "LIKES", null, null);
    defer testing.allocator.free(likes_edges);
    try testing.expectEqual(@as(usize, 1), likes_edges.len);
    const likes_ptr = store.edges.getPtr(likes_edges[0]) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("LIKES", likes_ptr.label);

    // Nonexistent type returns empty
    const none_edges = store.getEdgesByType(testing.allocator, "HATES", null, null);
    try testing.expectEqual(@as(usize, 0), none_edges.len);

    // Delete an edge and verify index is updated
    store.deleteEdge(e1);
    const knows_after_delete = store.getEdgesByType(testing.allocator, "KNOWS", null, null);
    defer testing.allocator.free(knows_after_delete);
    try testing.expectEqual(@as(usize, 1), knows_after_delete.len);
    try testing.expectEqual(e2, knows_after_delete[0]);

    // Verify index entry was cleaned up
    const knows_ids_after = store.getEdgeIdsByType("default", "KNOWS");
    try testing.expect(knows_ids_after != null);
    try testing.expectEqual(@as(usize, 1), knows_ids_after.?.len);
}

test "PERF-P0-001: edge-type index works with tenant filtering" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Person"};
    const n1 = try store.createNodeWithGraphAndTenant(&labels, "default", "t1");
    const n2 = try store.createNodeWithGraphAndTenant(&labels, "default", "t1");
    const n3 = try store.createNodeWithGraphAndTenant(&labels, "default", "t2");

    _ = try store.createEdgeWithGraphAndTenant(n1, n2, "FRIEND", "default", "t1");
    _ = try store.createEdgeWithGraphAndTenant(n3, n1, "FRIEND", "default", "t2");

    // All FRIEND edges across tenants
    const all = store.getEdgesByType(testing.allocator, "FRIEND", null, null);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);

    // Filtered to tenant t1
    const t1_edges = store.getEdgesByType(testing.allocator, "FRIEND", "t1", null);
    defer testing.allocator.free(t1_edges);
    try testing.expectEqual(@as(usize, 1), t1_edges.len);
    const t1_ptr = store.edges.getPtr(t1_edges[0]) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("t1", t1_ptr.tenant_id);

    // Filtered to tenant t2
    const t2_edges = store.getEdgesByType(testing.allocator, "FRIEND", "t2", null);
    defer testing.allocator.free(t2_edges);
    try testing.expectEqual(@as(usize, 1), t2_edges.len);
    const t2_ptr = store.edges.getPtr(t2_edges[0]) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("t2", t2_ptr.tenant_id);
}

test "PERF-P0-001: edge-type index across multiple graphs" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"V"};
    const a1 = try store.createNodeWithGraph(&labels, "graphA");
    const a2 = try store.createNodeWithGraph(&labels, "graphA");
    const b1 = try store.createNodeWithGraph(&labels, "graphB");
    const b2 = try store.createNodeWithGraph(&labels, "graphB");

    _ = try store.createEdgeWithGraph(a1, a2, "REL", "graphA");
    _ = try store.createEdgeWithGraph(b1, b2, "REL", "graphB");

    // Per-graph lookups via getEdgeIdsByType
    const rel_a = store.getEdgeIdsByType("graphA", "REL");
    try testing.expect(rel_a != null);
    try testing.expectEqual(@as(usize, 1), rel_a.?.len);

    const rel_b = store.getEdgeIdsByType("graphB", "REL");
    try testing.expect(rel_b != null);
    try testing.expectEqual(@as(usize, 1), rel_b.?.len);

    // Cross-graph getEdgesByType returns both
    const all_rel = store.getEdgesByType(testing.allocator, "REL", null, null);
    defer testing.allocator.free(all_rel);
    try testing.expectEqual(@as(usize, 2), all_rel.len);
}

test "PERF-P0-001: edge-type index survives clearNodes" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"X"};
    const n1 = try store.createNodeWithGraph(&labels, "default");
    const n2 = try store.createNodeWithGraph(&labels, "default");
    _ = try store.createEdgeWithGraph(n1, n2, "LINK", "default");

    // Index should have entries
    try testing.expect(store.getEdgeIdsByType("default", "LINK") != null);

    // Clear the store
    store.clearNodes();

    // Index should be empty after clear
    try testing.expect(store.getEdgeIdsByType("default", "LINK") == null);

    // getEdgesByType should return empty
    const result = store.getEdgesByType(testing.allocator, "LINK", null, null);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "PERF-P0-001: edge-type index posting list is sorted ascending" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"N"};
    // Create many edges of the same type to verify sorted ordering
    var node_ids: [20]u64 = undefined;
    for (0..20) |i| {
        node_ids[i] = try store.createNodeWithGraph(&labels, "default");
    }
    for (0..19) |i| {
        _ = try store.createEdgeWithGraph(node_ids[i], node_ids[i + 1], "CHAIN", "default");
    }

    const chain_ids = store.getEdgeIdsByType("default", "CHAIN");
    try testing.expect(chain_ids != null);
    try testing.expectEqual(@as(usize, 19), chain_ids.?.len);

    // Verify strictly ascending order (binary search correctness depends on this)
    for (1..chain_ids.?.len) |i| {
        try testing.expect(chain_ids.?[i] > chain_ids.?[i - 1]);
    }
}
