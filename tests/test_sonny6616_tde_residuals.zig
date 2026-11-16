// SONNY-6616: residuals of at-rest encryption (TDE) left after SONNY-6590.
//
// Exact-index invalidation. A full checkpoint of a graph whose exact
// property index was never built and that has no nodes left invalidates the
// persisted index (`invalidateExactPropertyIndexFile`). It deleted
// `prop_exact.idx` only and left `prop_rev.idx` - the node -> (label,
// property key, value hash) reverse map of data that no longer exists, with
// the property-key names in it (in plaintext without a key). Both go now.
//
// Graph names. `graph_registry.dat` (every graph's name, uuid and counts)
// and `dropped_graphs.dat` (the names of dropped graphs) were written in
// plaintext under TDE. They are sealed now (graph-storage 0.4.20's
// `GraphRegistry.saveToFileWith`; geode's own file with the side-file
// envelope and a consumer kind), a plaintext pair from an earlier build is
// read once and rewritten sealed, and a sealed pair opened without the key
// refuses the data directory. geode's exact-index files use consumer kinds
// (graph-storage 0.4.20 opened 128..255 to consumers) instead of borrowing
// graph-storage's `prop_chain_index`.
//
// Wrong key. graph-storage 0.4.20 reports a graph whose manifests or WAL do
// not authenticate under the key as `EncryptionKeyMismatch` (it was
// `NoManifest`); geode answers it with 58000 and an operator message.
//
// Real StorageAdapter, real files; every key is generated per test.
//
// CANARY: REQ=REQ-SONNY-6616-EXACT-INDEX-INVALIDATE-PAIR; FEATURE="TDEFileLevelEncryption"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6616_tde_residuals.zig; OWNER=security; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const gs = @import("graph_storage");

const StorageAdapter = geode.graph_storage_adapter.StorageAdapter;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn randomKey() [32]u8 {
    var k: [32]u8 = undefined;
    io().random(&k);
    return k;
}

fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io(), path, .{}) catch return false;
    return true;
}

test "SONNY-6616: invalidating a graph's exact index removes prop_rev.idx with prop_exact.idx" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    for ([_]?[32]u8{ null, randomKey() }) |key| {
        const graph = if (key == null) "plain6616" else "sealed6616";
        const adapter = try StorageAdapter.init(testing.allocator, path, .{ .page_size = 4096, .buffer_pool_pages = 64, .encryption_key = key });
        defer adapter.deinit();
        const id = try adapter.createNode(graph, &.{"L6616"});
        try adapter.setNodeProperty(graph, id, "k6616", .{ .String = "v6616" });
        try adapter.checkpointAll();
        const hex = std.fmt.bytesToHex((try adapter.lookupManagedGraph(graph)).uuid, .lower);
        const exact = try std.fmt.allocPrint(aa, "{s}/{s}/prop_exact.idx", .{ path, &hex });
        const rev = try std.fmt.allocPrint(aa, "{s}/{s}/prop_rev.idx", .{ path, &hex });
        try testing.expect(exists(exact));
        try testing.expect(exists(rev));

        // The production caller is the full checkpoint of an emptied,
        // never-built graph; this is the same function.
        adapter.invalidateExactIndexFileForTesting(graph);
        try testing.expect(!exists(exact));
        if (exists(rev)) {
            std.debug.print("SONNY-6616: {s} survived the invalidation of {s}\n", .{ rev, exact });
            return error.ReverseMapLeftBehind;
        }
    }
}

fn readAll(aa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io(), path, aa, .limited(1 << 30));
}

/// Files under `root` holding `needle`.
fn holders(aa: std.mem.Allocator, root: []const u8, needle: []const u8) !usize {
    var n: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file) continue;
        const bytes = try entry.dir.readFileAlloc(io(), entry.basename, aa, .limited(1 << 30));
        if (std.mem.indexOf(u8, bytes, needle) != null) {
            std.debug.print("SONNY-6616: '{s}' in {s}\n", .{ needle, entry.path });
            n += 1;
        }
    }
    return n;
}

/// SONNY-6635: rewrite every manifest slot under `root` at format_version 4
/// under `key`, as graph-storage <= 0.4.16 wrote them under a key.
fn manifestsToV4(aa: std.mem.Allocator, root: []const u8, key: [32]u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "manifest.a") and !std.mem.eql(u8, entry.basename, "manifest.b")) continue;
        try paths.append(aa, try std.fmt.allocPrint(aa, "{s}/{s}", .{ root, entry.path }));
    }
    var n: usize = 0;
    for (paths.items) |p| {
        var m = (try gs.manifest.Manifest.readFromFileWithKey(aa, p, key)) orelse continue;
        m.format_version = gs.manifest.MANIFEST_VERSION;
        try m.writeToFileWithKey(aa, p, key);
        n += 1;
    }
    return n;
}

fn tdeConfig(key: ?[32]u8) gs.GraphConfig {
    return .{ .page_size = 4096, .buffer_pool_pages = 64, .encryption_key = key };
}

const kept_graph = "Sonny6616KeptGraphName";
const dropped_graph = "Sonny6616DroppedGraphName";

test "SONNY-6616: under TDE graph_registry.dat and dropped_graphs.dat hold no graph name, and a reopen still knows both" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const key = randomKey();
    {
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
        defer adapter.deinit();
        _ = try adapter.createNode(kept_graph, &.{"L6616"});
        _ = try adapter.createNode(dropped_graph, &.{"L6616"});
        try adapter.dropGraph(dropped_graph);
        try adapter.checkpointAll();
    }
    for ([_][]const u8{ "graph_registry.dat", "dropped_graphs.dat" }) |name| {
        const bytes = try readAll(aa, try std.fmt.allocPrint(aa, "{s}/{s}", .{ path, name }));
        try testing.expect(gs.side_file_crypto.isSealed(bytes));
    }
    try testing.expectEqual(@as(usize, 0), try holders(aa, path, kept_graph));
    try testing.expectEqual(@as(usize, 0), try holders(aa, path, dropped_graph));

    const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
    defer adapter.deinit();
    try testing.expect(adapter.getGraphUuid(kept_graph) != null);
    try testing.expect(adapter.dropped_graph_names.contains(dropped_graph));
    try testing.expect(try geode.graph_storage_adapter.graphRegisteredOnDisk(testing.allocator, path, kept_graph, key));
}

test "SONNY-6616: a plaintext registry and dropped-graph list from an earlier build are read under the key and rewritten sealed; without the key a sealed pair refuses the data directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const key = randomKey();
    const reg_path = try std.fmt.allocPrint(aa, "{s}/graph_registry.dat", .{path});
    const drop_path = try std.fmt.allocPrint(aa, "{s}/dropped_graphs.dat", .{path});
    {
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
        defer adapter.deinit();
        _ = try adapter.createNode(kept_graph, &.{"L6616"});
        _ = try adapter.createNode(dropped_graph, &.{"L6616"});
        try adapter.dropGraph(dropped_graph);
        try adapter.checkpointAll();
    }
    // What an earlier build left: both files in the plaintext layout.
    // SONNY-6635: and what else such a build left - manifests at
    // format_version 4 (it did not seal side files) and no data-directory
    // identity; a plaintext registry beside V5 manifests is refused.
    {
        var reg = gs.registry.GraphRegistry.init(testing.allocator);
        defer reg.deinit();
        try geode.graph_storage_adapter.readRegistryOffline(testing.allocator, &reg, path, key);
        try reg.saveToFile(reg_path);
        const id_path = try std.fmt.allocPrint(aa, "{s}/data_dir.identity", .{path});
        var c = (try gs.registry.DataDirIdentity.load(aa, path, key)).?.cipher(key).?;
        defer c.deinit();
        const sealed = try readAll(aa, drop_path);
        const plain = try c.open(aa, geode.graph_storage_adapter.side_kind_dropped_graphs, "dropped_graphs.dat", sealed);
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = drop_path, .data = plain });
        try std.Io.Dir.cwd().deleteFile(io(), id_path);
        try testing.expect(try manifestsToV4(aa, path, key) > 0);
    }
    try testing.expectEqual(@as(usize, 2), try holders(aa, path, kept_graph) + try holders(aa, path, dropped_graph));
    {
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
        defer adapter.deinit();
        try testing.expect(adapter.getGraphUuid(kept_graph) != null);
        try testing.expect(adapter.dropped_graph_names.contains(dropped_graph));
    }
    try testing.expect(gs.side_file_crypto.isSealed(try readAll(aa, reg_path)));
    try testing.expect(gs.side_file_crypto.isSealed(try readAll(aa, drop_path)));
    try testing.expectEqual(@as(usize, 0), try holders(aa, path, kept_graph));
    try testing.expectEqual(@as(usize, 0), try holders(aa, path, dropped_graph));

    try testing.expectError(error.SideFileEncrypted, StorageAdapter.init(testing.allocator, path, tdeConfig(null)));
    try testing.expectError(error.SideFileEncrypted, geode.graph_storage_adapter.graphRegisteredOnDisk(testing.allocator, path, kept_graph, null));
}

test "SONNY-6616: geode's exact-index files are sealed with consumer kinds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(randomKey()));
    defer adapter.deinit();
    const id = try adapter.createNode("kinds6616", &.{"L6616"});
    try adapter.setNodeProperty("kinds6616", id, "k6616", .{ .String = "v6616" });
    try adapter.checkpointAll();
    const hex = std.fmt.bytesToHex((try adapter.lookupManagedGraph("kinds6616")).uuid, .lower);
    const kinds = [_]struct { name: []const u8, kind: gs.side_file_crypto.Kind }{
        .{ .name = "prop_exact.idx", .kind = geode.graph_storage_adapter.side_kind_prop_exact },
        .{ .name = "prop_rev.idx", .kind = geode.graph_storage_adapter.side_kind_prop_rev },
    };
    for (kinds) |k| {
        const bytes = try readAll(aa, try std.fmt.allocPrint(aa, "{s}/{s}/{s}", .{ path, &hex, k.name }));
        try testing.expect(gs.side_file_crypto.isSealed(bytes));
        try testing.expect(!gs.side_file_crypto.Kind.isLibrary(k.kind));
        try testing.expectEqual(@intFromEnum(k.kind), bytes[9]);
    }
}

test "SONNY-6616: a graph opened under another key is refused with EncryptionKeyMismatch and a 58000 operator message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const key = randomKey();
    {
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
        defer adapter.deinit();
        _ = try adapter.createNode("wrongkey6616", &.{"L6616"});
        try adapter.checkpointAll();
    }
    // The registry and the dropped list are sealed under the data
    // directory's key too, so the graph store is opened under a key whose
    // registry cipher matches but whose graph-storage key does not: rewrite
    // the registry under the other key, as a data directory moved between
    // servers with different keys would look graph by graph.
    // SONNY-6635: the data-directory identity (sealed under the key) too.
    const other = randomKey();
    {
        const reg_path = try std.fmt.allocPrint(aa, "{s}/graph_registry.dat", .{path});
        var reg = gs.registry.GraphRegistry.init(testing.allocator);
        defer reg.deinit();
        try geode.graph_storage_adapter.readRegistryOffline(testing.allocator, &reg, path, key);
        const id = (try gs.registry.DataDirIdentity.load(aa, path, key)).?;
        try id.save(aa, path, other);
        var c2 = id.cipher(other).?;
        defer c2.deinit();
        try reg.saveToFileWith(reg_path, &c2);
    }
    const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(other));
    defer adapter.deinit();
    try testing.expectError(error.EncryptionKeyMismatch, adapter.getOrCreateGraph("wrongkey6616"));
    const info = geode.proto_util.mapError(error.EncryptionKeyMismatch);
    try testing.expectEqualStrings("58000", info.code);
    try testing.expect(std.mem.startsWith(u8, info.message, "EncryptionKeyMismatch"));
    try testing.expect(std.mem.indexOf(u8, info.message, "GEODE_TDE_KEY") != null);
    try testing.expect(geode.proto_util.statementErrorInfo(error.EncryptionKeyMismatch) != null);
}
