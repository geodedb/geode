const std = @import("std");
const ast = @import("../gql/ast.zig");
const graph_store = @import("../graph_store.zig");
const index_manager = @import("../index/index_manager.zig");

// GAP-0717 / issue #717 (2026-04-16): deleted a 1,114-LOC stale clone of
// executeStatementWithContext plus its private resolveLimitParam helper and
// ~15 dead execution.*/fle_*/value_types imports.  The live dispatcher lives
// in src/execution.zig (line ~919).  The three helpers below are the only
// exports still called from elsewhere (execution.zig:1264 and 1353).

pub fn toRuntimeAdvancedIndexType(index_type: ast.IndexType) ?index_manager.IndexManager.IndexType {
    return switch (index_type) {
        .vector_f32 => .vector_f32,
        .spatial_geographic => .spatial_geographic,
        .network_cidr => .network_cidr,
        .signature_crypto => .signature_crypto,
        .interval_tree => .interval_tree,
        .jsonb_inverted => .jsonb_inverted,
        .domain_trie => .domain_trie,
        else => null,
    };
}

pub fn runtimeAdvancedIndexTypeFromCatalog(type_name: []const u8) ?index_manager.IndexManager.IndexType {
    if (std.mem.eql(u8, type_name, "vector_f32")) return .vector_f32;
    if (std.mem.eql(u8, type_name, "spatial_geographic")) return .spatial_geographic;
    if (std.mem.eql(u8, type_name, "network_cidr")) return .network_cidr;
    if (std.mem.eql(u8, type_name, "signature_crypto")) return .signature_crypto;
    if (std.mem.eql(u8, type_name, "interval_tree") or std.mem.eql(u8, type_name, "IntervalTree")) return .interval_tree;
    if (std.mem.eql(u8, type_name, "jsonb_inverted") or std.mem.eql(u8, type_name, "JsonbInverted")) return .jsonb_inverted;
    if (std.mem.eql(u8, type_name, "domain_trie") or std.mem.eql(u8, type_name, "DomainTrie")) return .domain_trie;
    return null;
}

pub fn ensureAdvancedRuntimeIndex(
    allocator: std.mem.Allocator,
    index_name: []const u8,
    label: []const u8,
    properties: [][]const u8,
    index_type: ast.IndexType,
) !void {
    const runtime_type = toRuntimeAdvancedIndexType(index_type) orelse return;
    if (properties.len != 1) return error.Unsupported;

    const manager = try index_manager.ensureGlobalIndexManager(allocator);
    switch (runtime_type) {
        .vector_f32 => try manager.createAdvancedVectorIndex(index_name, 0, .l2),
        .spatial_geographic => try manager.createAdvancedSpatialIndex(index_name),
        .network_cidr => try manager.createAdvancedNetworkIndex(index_name),
        .signature_crypto => try manager.createAdvancedSignatureIndex(index_name),
        .interval_tree => try manager.createAdvancedIntervalIndex(index_name),
        .jsonb_inverted => try manager.createAdvancedJsonbIndex(index_name),
        .domain_trie => try manager.createAdvancedDomainIndex(index_name),
        else => return,
    }
    try manager.registerAdvancedPropertyIndex(index_name, label, properties[0], runtime_type);
    try manager.rebuildAdvancedIndex(graph_store.getGlobalStore(allocator), index_name);
}
