// SONNY-6689: TDE residuals of SONNY-6635.
//
// (1) With `data_dir.identity` deleted, a registry sealed under
//     graph-storage's shared `SEAL_UUID` (the SONNY-6616 build's layout) was
//     read as that build's and adopted, so a registry from any other data
//     directory under the key could be substituted. After the one-time
//     upgrade a sealed marker (`data_dir.seal`, readable without the
//     identity) records it: with the identity gone the directory is refused,
//     and an identity that is not the one the marker names (a donor's,
//     copied in with its registry) is refused too.
// (2) The graph-restore intent (SONNY-6636) and `txn_undo.wal` (SONNY-2979)
//     were sealed under `SEAL_UUID`, so either could be moved between data
//     directories that share a key. They are sealed under the directory's
//     identity; a file an earlier build sealed under `SEAL_UUID` is read (and
//     the undo log resealed) once, in the open that records the marker, and
//     refused after.
//
// Real StorageAdapter, real files, a fresh key per test.
//
// CANARY: REQ=REQ-SONNY-6689-DATA-DIR-TRANSPLANT; FEATURE="TDEFileLevelEncryption"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6689_data_dir_transplant.zig; OWNER=security; UPDATED=2026-11-16

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const gs = @import("graph_storage");

const StorageAdapter = geode.graph_storage_adapter.StorageAdapter;
const durable = geode.txn_durable_undo;

const marker_file = "data_dir.seal";
const intent_file = "graph_restore.intent";
const intent_kind = gs.side_file_crypto.Kind.consumer(3);

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

fn deleteIfPresent(path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io(), path) catch {};
}

fn tmpPath(aa: std.mem.Allocator, tmp: *const testing.TmpDir) ![]const u8 {
    return std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

fn in(aa: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(aa, "{s}/{s}", .{ dir, name });
}

/// A keyed data directory with graph `name` (one node, checkpointed) and a
/// dropped graph.
fn makeStore(path: []const u8, key: [32]u8, name: []const u8) !void {
    const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
    defer adapter.deinit();
    _ = try adapter.createNode(name, &.{"L6689"});
    const dropped = try std.fmt.allocPrint(testing.allocator, "{s}_dropped", .{name});
    defer testing.allocator.free(dropped);
    _ = try adapter.createNode(dropped, &.{"L6689"});
    try adapter.dropGraph(dropped);
    try adapter.checkpointAll();
}

fn graphUuid(path: []const u8, key: [32]u8, name: []const u8) ![16]u8 {
    const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
    defer adapter.deinit();
    return adapter.getGraphUuid(name).?;
}

/// Open and close the data directory, expecting success.
fn reopen(path: []const u8, key: [32]u8) !void {
    const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
    adapter.deinit();
}

/// Opening `path` under `key` fails with `want` (an adapter that opens is
/// closed again).
fn expectOpenRefused(path: []const u8, key: [32]u8, want: []const u8) !void {
    if (StorageAdapter.init(testing.allocator, path, tdeConfig(key))) |adapter| {
        adapter.deinit();
        std.debug.print("SONNY-6689: {s} opened; expected {s}\n", .{ path, want });
        return error.OpenNotRefused;
    } else |err| try testing.expectEqualStrings(want, @errorName(err));
}

/// `raw`, a sealed side file of `dir`, opened under whichever cipher this
/// build sealed it with (the directory's identity, else `SEAL_UUID`).
fn openSideFile(aa: std.mem.Allocator, dir: []const u8, key: [32]u8, kind: gs.side_file_crypto.Kind, name: []const u8, raw: []const u8) ![]u8 {
    if (try gs.registry.DataDirIdentity.load(aa, dir, key)) |id| {
        var c = id.cipher(key).?;
        defer c.deinit();
        if (c.open(aa, kind, name, raw)) |plain| return plain else |_| {}
    }
    var legacy = gs.side_file_crypto.Cipher.init(key, gs.registry.SEAL_UUID);
    defer legacy.deinit();
    return legacy.open(aa, kind, name, raw);
}

/// A restore intent left in `dir` by a restore that never committed.
fn leaveRestoreIntent(dir: []const u8, key: [32]u8) !void {
    const adapter = try StorageAdapter.init(testing.allocator, dir, tdeConfig(key));
    defer adapter.deinit();
    var r = try adapter.beginGraphRestore(&.{.{ .name = "restored6689", .uuid = [_]u8{0x89} ** 16 }});
    r.deinit();
}

// ---------------------------------------------------------------------------
// (1) the registry after the upgrade
// ---------------------------------------------------------------------------

test "SONNY-6689 (1): after the upgrade, a SEAL_UUID-sealed registry with the identity file deleted is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(aa, &tmp);
    const key = randomKey();
    try makeStore(path, key, "victim6689");
    const uuid = try graphUuid(path, key, "victim6689");

    // A registry in the SONNY-6616 layout (any directory under the key could
    // have written it) renaming the graph, and the identity file gone.
    {
        var reg = gs.registry.GraphRegistry.init(testing.allocator);
        defer reg.deinit();
        try reg.addGraph("renamed6689", uuid);
        var legacy = gs.side_file_crypto.Cipher.init(key, gs.registry.SEAL_UUID);
        defer legacy.deinit();
        try reg.saveToFileWith(try in(aa, path, "graph_registry.dat"), &legacy);
    }
    deleteIfPresent(try in(aa, path, "data_dir.identity"));

    if (StorageAdapter.init(testing.allocator, path, tdeConfig(key))) |adapter| {
        defer adapter.deinit();
        std.debug.print("SONNY-6689 (1): a SEAL_UUID registry was adopted after the upgrade (renamed6689 known: {})\n", .{adapter.getGraphUuid("renamed6689") != null});
        return error.LegacyRegistryAdopted;
    } else |err| try testing.expectEqualStrings("DataDirIdentityMissing", @errorName(err));
    try testing.expectError(error.DataDirIdentityMissing, geode.graph_storage_adapter.graphRegisteredOnDisk(testing.allocator, path, "renamed6689", key));
}

test "SONNY-6689 (1): a donor directory's identity, registry and dropped-graph list copied in are refused" {
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
    try makeStore(dir_a, key, "donor6689");
    try makeStore(dir_b, key, "own6689");

    for ([_][]const u8{ "data_dir.identity", "graph_registry.dat", "dropped_graphs.dat" }) |name| {
        try writeAll(try in(aa, dir_b, name), try readAll(aa, try in(aa, dir_a, name)));
    }
    if (StorageAdapter.init(testing.allocator, dir_b, tdeConfig(key))) |adapter| {
        defer adapter.deinit();
        std.debug.print("SONNY-6689 (1): a donor's identity and registry were adopted (donor6689 known: {})\n", .{adapter.getGraphUuid("donor6689") != null});
        return error.DonorIdentityAdopted;
    } else |err| try testing.expectEqualStrings("DataDirIdentityMismatch", @errorName(err));
}

// ---------------------------------------------------------------------------
// (2) the restore intent
// ---------------------------------------------------------------------------

test "SONNY-6689 (2): a graph-restore intent moved from another data directory under the same key is refused" {
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
    try makeStore(dir_a, key, "a6689");
    try makeStore(dir_b, key, "b6689");
    try leaveRestoreIntent(dir_a, key);
    try testing.expect(exists(try in(aa, dir_a, intent_file)));

    try writeAll(try in(aa, dir_b, intent_file), try readAll(aa, try in(aa, dir_a, intent_file)));
    if (StorageAdapter.init(testing.allocator, dir_b, tdeConfig(key))) |adapter| {
        adapter.deinit();
        std.debug.print("SONNY-6689 (2): another directory's restore intent was settled here\n", .{});
        return error.TransplantedIntentAccepted;
    } else |err| try testing.expectEqualStrings("CorruptGraphRestoreIntent", @errorName(err));
    // A's own intent still settles in A.
    try reopen(dir_a, key);
    try testing.expect(!exists(try in(aa, dir_a, intent_file)));
}

test "SONNY-6689 (2): a SEAL_UUID-sealed restore intent settles once in a directory not yet upgraded, and is refused after the upgrade" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(aa, &tmp);
    const key = randomKey();
    try makeStore(path, key, "own6689");
    try leaveRestoreIntent(path, key);
    const intent_path = try in(aa, path, intent_file);

    // The intent as the SONNY-6636 build sealed it (under SEAL_UUID).
    const plain = try openSideFile(aa, path, key, intent_kind, intent_file, try readAll(aa, intent_path));
    var legacy = gs.side_file_crypto.Cipher.init(key, gs.registry.SEAL_UUID);
    defer legacy.deinit();
    const legacy_intent = try legacy.seal(aa, intent_kind, intent_file, plain);

    // Upgraded (the marker records it): refused.
    try writeAll(intent_path, legacy_intent);
    try expectOpenRefused(path, key, "CorruptGraphRestoreIntent");

    // Not yet upgraded (no marker, as the SONNY-6635 build left it): settled.
    deleteIfPresent(try in(aa, path, marker_file));
    try reopen(path, key);
    try testing.expect(!exists(intent_path));
    try testing.expect(exists(try in(aa, path, marker_file)));
}

// ---------------------------------------------------------------------------
// (2) txn_undo.wal
// ---------------------------------------------------------------------------

const probe_entry = geode.txn_undo_log.UndoEntry{ .CreateNode = .{ .node_id = 6689, .graph_name = "" } };

/// Records `dir`'s undo log holds, read under the cipher the log opens with.
fn logRecords(dir: []const u8, key: [32]u8) !usize {
    const l = try durable.Log.open(testing.allocator, dir, key);
    defer l.close();
    const raw = try l.readAll();
    defer testing.allocator.free(raw);
    var p = try durable.parse(testing.allocator, if (l.cipher) |*c| c else null, raw);
    defer p.deinit(testing.allocator);
    return p.records.items.len;
}

/// A log holding one entry of an open transaction, sealed under `cipher`.
fn legacyLog(aa: std.mem.Allocator, cipher: *const gs.side_file_crypto.Cipher) ![]u8 {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    try durable.encodeEntry(aa, &payload, probe_entry);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try durable.appendRecord(aa, &out, cipher, .entry, 0x6689, 1, payload.items);
    return out.items;
}

test "SONNY-6689 (2): txn_undo.wal moved from another data directory under the same key is refused" {
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
    try makeStore(dir_a, key, "a6689");
    try makeStore(dir_b, key, "b6689");
    {
        const l = try durable.Log.open(testing.allocator, dir_a, key);
        defer l.close();
        try l.logEntries(1, &.{probe_entry});
    }
    try testing.expectEqual(@as(usize, 1), try logRecords(dir_a, key));

    try writeAll(try in(aa, dir_b, durable.file_name), try readAll(aa, try in(aa, dir_a, durable.file_name)));
    try reopen(dir_b, key);
    if (logRecords(dir_b, key)) |n| {
        std.debug.print("SONNY-6689 (2): another directory's undo log ({d} records) would be undone here\n", .{n});
        return error.TransplantedUndoLogAccepted;
    } else |err| try testing.expectEqualStrings("SideFileAuthFailed", @errorName(err));
}

test "SONNY-6689 (2): a SEAL_UUID-sealed txn_undo.wal is resealed once in a directory not yet upgraded, and refused after the upgrade" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(aa, &tmp);
    const key = randomKey();
    try makeStore(path, key, "own6689");
    var legacy = gs.side_file_crypto.Cipher.init(key, gs.registry.SEAL_UUID);
    defer legacy.deinit();
    const log_path = try in(aa, path, durable.file_name);

    // Upgraded: a SEAL_UUID log (any directory under the key could have
    // written it) is refused.
    try writeAll(log_path, try legacyLog(aa, &legacy));
    try reopen(path, key);
    try testing.expectError(error.SideFileAuthFailed, logRecords(path, key));

    // Not yet upgraded: the open resealed it under the identity; recovery
    // reads the open transaction's entry.
    try writeAll(log_path, try legacyLog(aa, &legacy));
    deleteIfPresent(try in(aa, path, marker_file));
    try reopen(path, key);
    try testing.expectEqual(@as(usize, 1), try logRecords(path, key));
    try testing.expectError(error.SideFileAuthFailed, durable.parse(aa, &legacy, try readAll(aa, log_path)));
}

test "SONNY-6689: without a key nothing changes (no marker, a plaintext undo log)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(aa, &tmp);
    {
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(null));
        defer adapter.deinit();
        _ = try adapter.createNode("plain6689", &.{"L6689"});
    }
    try testing.expect(!exists(try in(aa, path, marker_file)));
    const l = try durable.Log.open(testing.allocator, path, null);
    defer l.close();
    try l.logEntries(1, &.{probe_entry});
    const raw = try l.readAll();
    defer testing.allocator.free(raw);
    var p = try durable.parse(testing.allocator, null, raw);
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), p.records.items.len);
}
