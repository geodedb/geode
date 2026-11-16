// SONNY-6635: the data directory's own files under at-rest encryption (TDE).
//
// (1) Copied registry. `graph_registry.dat` and `dropped_graphs.dat` were
//     sealed under graph-storage's `registry.SEAL_UUID`, the same in every
//     data directory, so either file copied from another data directory
//     under the same key authenticated. They are sealed under the
//     directory's own identity now (graph-storage's `DataDirIdentity`,
//     `data_dir.identity`).
// (2) Plaintext registry. `loadRegistry` read a plaintext registry under a
//     key (the one-time upgrade of a store written before SONNY-6616) at
//     every open, so anyone who could write the directory could substitute
//     one: rename graphs, swap two graphs' names, hide graphs. Once a
//     registry has been sealed, a plaintext one is refused. Recorded twice,
//     both authenticated: the sealed identity file's "registry bound" flag,
//     and - surviving the identity file's deletion - any graph manifest at
//     format_version 5 (sealed side files), which no build that left the
//     registry plaintext ever released. A store from such a build (V4
//     manifests, plaintext registry) still upgrades once.
//
// Real StorageAdapter, real files; every key is generated per test.
//
// CANARY: REQ=REQ-SONNY-6635-REGISTRY-BINDING; FEATURE="TDEFileLevelEncryption"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6635_registry_binding.zig; OWNER=security; UPDATED=2026-11-15

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

fn tdeConfig(key: ?[32]u8) gs.GraphConfig {
    return .{ .page_size = 4096, .buffer_pool_pages = 64, .encryption_key = key };
}

fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io(), path, .{}) catch return false;
    return true;
}

fn readAll(aa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io(), path, aa, .limited(1 << 30));
}

fn writeAll(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = path, .data = data });
}

fn tmpPath(aa: std.mem.Allocator, tmp: *const testing.TmpDir) ![]const u8 {
    return std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

/// A keyed data directory with graph `name` (one node, checkpointed) and,
/// when `dropped` is set, a dropped graph of that name.
fn makeStore(path: []const u8, key: [32]u8, name: []const u8, dropped: ?[]const u8) !void {
    const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
    defer adapter.deinit();
    _ = try adapter.createNode(name, &.{"L6635"});
    if (dropped) |d| {
        _ = try adapter.createNode(d, &.{"L6635"});
        try adapter.dropGraph(d);
    }
    try adapter.checkpointAll();
}

/// A plaintext registry (the layout every build before SONNY-6616 wrote)
/// naming `uuid` `name`.
fn writePlaintextRegistry(path: []const u8, name: []const u8, uuid: [16]u8) !void {
    var reg = gs.registry.GraphRegistry.init(testing.allocator);
    defer reg.deinit();
    try reg.addGraph(name, uuid);
    try reg.saveToFile(path);
}

/// Rewrite every manifest slot under `root` at format_version 4, under
/// `key`: what graph-storage <= 0.4.16 wrote under a key (before side files,
/// and so the registry, were sealed).
fn manifestsToV4(aa: std.mem.Allocator, root: []const u8, key: [32]u8) !usize {
    var n: usize = 0;
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
    for (paths.items) |p| {
        var m = (try gs.manifest.Manifest.readFromFileWithKey(aa, p, key)) orelse continue;
        m.format_version = gs.manifest.MANIFEST_VERSION;
        try m.writeToFileWithKey(aa, p, key);
        n += 1;
    }
    return n;
}

fn deleteIfPresent(path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io(), path) catch {};
}

test "SONNY-6635 (2): a plaintext registry substituted in a sealed data directory is refused, with or without the identity file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(aa, &tmp);
    const key = randomKey();
    try makeStore(path, key, "victim6635", null);
    const uuid = blk: {
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
        defer adapter.deinit();
        break :blk adapter.getGraphUuid("victim6635").?;
    };
    const reg_path = try std.fmt.allocPrint(aa, "{s}/graph_registry.dat", .{path});
    const sealed = try readAll(aa, reg_path);

    // Someone with write access to the directory renames the graph.
    try writePlaintextRegistry(reg_path, "renamed6635", uuid);
    if (StorageAdapter.init(testing.allocator, path, tdeConfig(key))) |adapter| {
        defer adapter.deinit();
        std.debug.print("SONNY-6635 (2): a plaintext registry was accepted under the key in a sealed data directory (renamed6635 known: {})\n", .{adapter.getGraphUuid("renamed6635") != null});
        return error.PlaintextRegistryAccepted;
    } else |err| try testing.expectEqual(error.SideFileNotSealed, err);

    // Deleting the identity file does not reopen the upgrade path: the
    // graph's manifests (format_version 5, authenticated) say this
    // directory was written by a build that seals the registry.
    // SONNY-6689: the upgrade marker refuses first (the identity is gone);
    // with the marker deleted too, the manifests still do.
    deleteIfPresent(try std.fmt.allocPrint(aa, "{s}/data_dir.identity", .{path}));
    try testing.expectError(error.DataDirIdentityMissing, StorageAdapter.init(testing.allocator, path, tdeConfig(key)));
    deleteIfPresent(try std.fmt.allocPrint(aa, "{s}/data_dir.seal", .{path}));
    try testing.expectError(error.SideFileNotSealed, StorageAdapter.init(testing.allocator, path, tdeConfig(key)));
    try testing.expectError(error.SideFileNotSealed, geode.graph_storage_adapter.graphRegisteredOnDisk(testing.allocator, path, "renamed6635", key));

    // The sealed registry put back (with the identity file gone it cannot
    // authenticate: refused, never adopted).
    try writeAll(reg_path, sealed);
    try testing.expect(std.meta.isError(StorageAdapter.init(testing.allocator, path, tdeConfig(key))));
}

test "SONNY-6635 (1): a sealed registry or dropped-graph list copied from another data directory under the same key does not authenticate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp_a = testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = testing.tmpDir(.{});
    defer tmp_b.cleanup();
    const dir_a = try tmpPath(aa, &tmp_a);
    const dir_b = try tmpPath(aa, &tmp_b);
    const key = randomKey();
    try makeStore(dir_a, key, "a6635", "a_dropped6635");
    try makeStore(dir_b, key, "b6635", "b_dropped6635");

    for ([_][]const u8{ "graph_registry.dat", "dropped_graphs.dat" }) |name| {
        const from = try std.fmt.allocPrint(aa, "{s}/{s}", .{ dir_a, name });
        const to = try std.fmt.allocPrint(aa, "{s}/{s}", .{ dir_b, name });
        const own = try readAll(aa, to);
        try writeAll(to, try readAll(aa, from));
        if (StorageAdapter.init(testing.allocator, dir_b, tdeConfig(key))) |adapter| {
            defer adapter.deinit();
            std.debug.print("SONNY-6635 (1): {s} copied from another data directory authenticated (a6635 known: {}, a_dropped6635 dropped: {})\n", .{ name, adapter.getGraphUuid("a6635") != null, adapter.dropped_graph_names.contains("a_dropped6635") });
            return error.CopiedFileAuthenticated;
        } else |err| try testing.expectEqual(error.SideFileAuthFailed, err);
        try writeAll(to, own);
    }
    // B's own files open B.
    const adapter = try StorageAdapter.init(testing.allocator, dir_b, tdeConfig(key));
    defer adapter.deinit();
    try testing.expect(adapter.getGraphUuid("b6635") != null);
    try testing.expect(adapter.dropped_graph_names.contains("b_dropped6635"));
}

test "SONNY-6635 (2): a store from a build that never sealed the registry upgrades once; then plaintext is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(aa, &tmp);
    const key = randomKey();
    try makeStore(path, key, "old6635", "old_dropped6635");
    const uuid = blk: {
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
        defer adapter.deinit();
        break :blk adapter.getGraphUuid("old6635").?;
    };
    const reg_path = try std.fmt.allocPrint(aa, "{s}/graph_registry.dat", .{path});
    const drop_path = try std.fmt.allocPrint(aa, "{s}/dropped_graphs.dat", .{path});
    const id_path = try std.fmt.allocPrint(aa, "{s}/data_dir.identity", .{path});

    // What a build before SONNY-6616 left: V4 manifests, a plaintext
    // registry and dropped-graph list, no identity file.
    try testing.expect(try manifestsToV4(aa, path, key) > 0);
    try writePlaintextRegistry(reg_path, "old6635", uuid);
    {
        var dropped: std.ArrayList(u8) = .empty;
        try dropped.appendSlice(aa, "GEODROP1"); // the adapter's dropped-graphs magic
        try dropped.appendSlice(aa, &std.mem.toBytes(std.mem.nativeToLittle(u32, 1)));
        const nm = "old_dropped6635";
        try dropped.appendSlice(aa, &std.mem.toBytes(std.mem.nativeToLittle(u16, nm.len)));
        try dropped.appendSlice(aa, nm);
        try writeAll(drop_path, dropped.items);
    }
    deleteIfPresent(id_path);
    deleteIfPresent(try std.fmt.allocPrint(aa, "{s}/data_dir.seal", .{path})); // SONNY-6689: nor the marker
    {
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
        defer adapter.deinit();
        try testing.expect(adapter.getGraphUuid("old6635") != null);
        try testing.expect(adapter.dropped_graph_names.contains("old_dropped6635"));
    }
    // Upgraded: both sealed, and the identity recorded (sealed).
    try testing.expect(gs.side_file_crypto.isSealed(try readAll(aa, reg_path)));
    try testing.expect(gs.side_file_crypto.isSealed(try readAll(aa, drop_path)));
    if (!exists(id_path)) {
        std.debug.print("SONNY-6635 (2): the upgrade recorded no data-directory identity\n", .{});
        return error.NoIdentityRecorded;
    }
    try testing.expect(gs.side_file_crypto.isSealed(try readAll(aa, id_path)));

    // From now on a plaintext registry is refused, even though no graph has
    // been opened since (its manifests are still V4): the identity says so.
    const sealed = try readAll(aa, reg_path);
    try writePlaintextRegistry(reg_path, "old6635", uuid);
    try testing.expectError(error.SideFileNotSealed, StorageAdapter.init(testing.allocator, path, tdeConfig(key)));
    try writeAll(reg_path, sealed);
    {
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
        defer adapter.deinit();
        try testing.expect(adapter.getGraphUuid("old6635") != null);
        try testing.expect(try geode.graph_storage_adapter.graphRegisteredOnDisk(testing.allocator, path, "old6635", key));
    }
}

test "SONNY-6635 (1): a registry sealed by graph-storage 0.4.20-0.4.25 (under SEAL_UUID) is read once and resealed under the identity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(aa, &tmp);
    const key = randomKey();
    try makeStore(path, key, "v21_6635", null);
    const uuid = blk: {
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
        defer adapter.deinit();
        break :blk adapter.getGraphUuid("v21_6635").?;
    };
    const reg_path = try std.fmt.allocPrint(aa, "{s}/graph_registry.dat", .{path});
    const id_path = try std.fmt.allocPrint(aa, "{s}/data_dir.identity", .{path});

    // The registry as the SONNY-6616 build sealed it, no identity file.
    var legacy_cipher = gs.side_file_crypto.Cipher.init(key, gs.registry.SEAL_UUID);
    defer legacy_cipher.deinit();
    {
        var reg = gs.registry.GraphRegistry.init(testing.allocator);
        defer reg.deinit();
        try reg.addGraph("v21_6635", uuid);
        try reg.saveToFileWith(reg_path, &legacy_cipher);
    }
    const legacy = try readAll(aa, reg_path);
    deleteIfPresent(id_path);
    deleteIfPresent(try std.fmt.allocPrint(aa, "{s}/data_dir.seal", .{path})); // SONNY-6689: nor the marker
    {
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
        defer adapter.deinit();
        try testing.expect(adapter.getGraphUuid("v21_6635") != null);
    }
    try testing.expect(exists(id_path));
    // Resealed: the legacy cipher no longer opens it ...
    var reg = gs.registry.GraphRegistry.init(testing.allocator);
    defer reg.deinit();
    try testing.expectError(error.SideFileAuthFailed, reg.loadFromFileWith(reg_path, .{ .cipher = &legacy_cipher, .require_sealed = true }));
    // ... and a SEAL_UUID-sealed registry (one any data directory under the
    // key could have written) is refused from now on.
    try writeAll(reg_path, legacy);
    try testing.expectError(error.SideFileAuthFailed, StorageAdapter.init(testing.allocator, path, tdeConfig(key)));
}

test "SONNY-6635: without a key nothing changes (plaintext registry, no identity file)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(aa, &tmp);
    {
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(null));
        defer adapter.deinit();
        _ = try adapter.createNode("plain6635", &.{"L6635"});
        try adapter.checkpointAll();
    }
    const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(null));
    defer adapter.deinit();
    try testing.expect(adapter.getGraphUuid("plain6635") != null);
    try testing.expect(!gs.side_file_crypto.isSealed(try readAll(aa, try std.fmt.allocPrint(aa, "{s}/graph_registry.dat", .{path}))));
    try testing.expect(!exists(try std.fmt.allocPrint(aa, "{s}/data_dir.identity", .{path})));
}
