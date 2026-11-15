// SONNY-6590: with TDE on (an at-rest key), the files that hold label,
// relationship-type and property-key names or indexed values are sealed, a
// store written before that is upgraded at open, a graph whose sealed files
// cannot be read under the key is refused on its own with an operator
// message, and time-series data is encrypted whenever GEODE_TDE_KEY is set.
//
// graph-storage 0.4.17 seals its side files (`labels.dict`, `props.idx`,
// `ordered_propidx.snap`, `props.catalog`, `propidx_*.btree`); geode seals
// its own exact property index (`prop_exact.idx`, `prop_rev.idx`) with the
// same envelope (`side_file_crypto.Cipher`, bound to the graph's uuid and
// the file name). Real engine, real adapter, real `geode serve` processes;
// every key is generated per test.
//
// In process (StorageAdapter, timeseries Store):
//   * the exact-index files are sealed, hold no name or value, and a clean
//     reopen reloads them; a crash reopen reconciles the WAL tail into them
//     exactly as a rebuild would;
//   * files in the plaintext layout (what geode wrote before SONNY-6590,
//     `setPlaintextExactIndexForTest`) are deleted at open, the index is
//     rebuilt and saved sealed;
//   * a sealed exact-index file copied from another graph, or modified, is
//     not served: the index is rebuilt and answers correctly;
//   * a graph-storage side file that fails authentication, is plaintext in a
//     sealed store, or is opened without the key refuses that graph with
//     SideFileAuthFailed / SideFileNotSealed / SideFileEncrypted (58000, no
//     key material in the message); the other graph keeps working;
//   * GEODE_TDE_KEY alone turns time-series encryption on; an empty
//     plaintext time-series store is replaced by an encrypted one; one
//     holding data is refused (TimeseriesNotEncrypted) and left intact.
//
// Real server:
//   * a data directory in the layout geode + graph-storage <= 0.4.16 left
//     under TDE (side files and exact index in plaintext, manifests at
//     format_version 4, time-series stores in plaintext) opens, every name,
//     value and index reads back, and afterwards no file holds a name or a
//     value; the manifests say format_version 5;
//   * a graph whose labels.dict fails authentication, or is plaintext, is
//     refused with 58000 SideFileAuthFailed / SideFileNotSealed while the
//     server keeps serving its other graph, and opens again once the file is
//     restored;
//   * a server-wide time-series store written in plaintext and holding data
//     stops startup under GEODE_TDE_KEY (TimeseriesNotEncrypted), keeps its
//     data, and is readable with the explicit GEODE_TS_TDE=0 opt-out.
//
// CANARY: REQ=REQ-SONNY-6590-EXACT-INDEX-SEALED; FEATURE="TDEFileLevelEncryption"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6590_tde_side_files.zig; OWNER=security; UPDATED=2026-11-15

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const gs = @import("graph_storage");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");

const adapter_mod = geode.graph_storage_adapter;
const StorageAdapter = adapter_mod.StorageAdapter;
const PropertyValue = geode.graph_store.PropertyValue;
const ts = geode.timeseries;
const crypto = gs.side_file_crypto;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn randomKey() [32]u8 {
    var k: [32]u8 = undefined;
    io().random(&k);
    return k;
}

fn randomHex(aa: std.mem.Allocator, comptime n: usize) ![]u8 {
    var raw: [n]u8 = undefined;
    io().random(&raw);
    return std.fmt.allocPrint(aa, "{x}", .{&raw});
}

/// Positive, and wide enough that no other 8 bytes match by chance.
fn randomWideInt() i64 {
    var raw: [8]u8 = undefined;
    io().random(&raw);
    return @intCast((std.mem.readInt(u64, &raw, .little) >> 2) | (1 << 60));
}

fn tdeConfig(key: ?[32]u8) gs.GraphConfig {
    return .{ .page_size = 4096, .buffer_pool_pages = 64, .encryption_key = key };
}

/// Per-test secrets the scans look for.
const Needles = struct {
    label: []const u8,
    key: []const u8,
    value: []const u8,
    number: i64,
    number_le: [8]u8,

    fn make(aa: std.mem.Allocator) !Needles {
        const n = randomWideInt();
        var le: [8]u8 = undefined;
        std.mem.writeInt(i64, &le, n, .little);
        return .{
            .label = try std.fmt.allocPrint(aa, "Sonny6590L{s}", .{try randomHex(aa, 6)}),
            .key = try std.fmt.allocPrint(aa, "sonny6590k{s}", .{try randomHex(aa, 6)}),
            .value = try std.fmt.allocPrint(aa, "sonny6590-secret-{s}", .{try randomHex(aa, 12)}),
            .number = n,
            .number_le = le,
        };
    }

    fn list(self: *const Needles) [4][]const u8 {
        return .{ self.label, self.key, self.value, &self.number_le };
    }
};

/// Files under `root` holding any of `needles`, as "path: needle#i".
fn scan(aa: std.mem.Allocator, root: []const u8, needles: []const []const u8) ![]const []const u8 {
    const gpa = testing.allocator;
    var hits: std.ArrayList([]const u8) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file) continue;
        const bytes = entry.dir.readFileAlloc(io(), entry.basename, gpa, .limited(1 << 30)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer gpa.free(bytes);
        for (needles, 0..) |n, i| {
            if (std.mem.indexOf(u8, bytes, n) != null)
                try hits.append(aa, try std.fmt.allocPrint(aa, "{s}: needle {d}", .{ entry.path, i }));
        }
    }
    for (hits.items) |h| std.debug.print("[SONNY-6590] plaintext: {s}/{s}\n", .{ root, h });
    return hits.items;
}

fn readAll(aa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io(), path, aa, .limited(1 << 30));
}

fn writeAll(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = path, .data = data });
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io(), path, .{}) catch return false;
    return true;
}

/// Rewrite every sealed side file under `root` in its plaintext layout (the
/// envelope's own decryption, keyed by the uuid its directory is named
/// after), as graph-storage <= 0.4.16 and geode before SONNY-6590 left it.
fn unsealTree(aa: std.mem.Allocator, root: []const u8, key: [32]u8) !usize {
    var n: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file) continue;
        const bytes = try entry.dir.readFileAlloc(io(), entry.basename, aa, .limited(1 << 30));
        if (!crypto.isSealed(bytes) or bytes.len < crypto.OVERHEAD) continue;
        const kind = std.enums.fromInt(crypto.Kind, bytes[9]) orelse continue;
        const parent = std.fs.path.basename(std.fs.path.dirname(entry.path) orelse continue);
        if (parent.len != 32) continue;
        var uuid: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&uuid, parent) catch continue;
        var c = crypto.Cipher.init(key, uuid);
        defer c.deinit();
        const plain = try c.open(aa, kind, entry.basename, bytes);
        try entry.dir.writeFile(io(), .{ .sub_path = entry.basename, .data = plain });
        n += 1;
    }
    return n;
}

/// Set every graph-storage manifest under `root` to `version`.
fn setManifestVersions(aa: std.mem.Allocator, root: []const u8, key: [32]u8, version: u32) !usize {
    var n: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "manifest.a") and !std.mem.eql(u8, entry.basename, "manifest.b")) continue;
        const p = try std.fmt.allocPrint(aa, "{s}/{s}", .{ root, entry.path });
        var m = (gs.manifest.Manifest.readFromFileWithKey(aa, p, key) catch continue) orelse continue;
        m.format_version = version;
        try m.writeToFileWithKey(aa, p, key);
        n += 1;
    }
    return n;
}

/// The lowest manifest format_version of every graph-storage store under
/// `root` (the newer slot of each pair).
fn minManifestVersion(aa: std.mem.Allocator, root: []const u8, key: [32]u8) !u32 {
    var lowest: u32 = std.math.maxInt(u32);
    var dir = try std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, "manifest.a")) continue;
        const dir_rel = std.fs.path.dirname(entry.path) orelse ".";
        var best: ?gs.manifest.Manifest = null;
        for ([_][]const u8{ "manifest.a", "manifest.b" }) |slot| {
            const p = try std.fmt.allocPrint(aa, "{s}/{s}/{s}", .{ root, dir_rel, slot });
            const m = (gs.manifest.Manifest.readFromFileWithKey(aa, p, key) catch continue) orelse continue;
            if (best == null or m.counter >= best.?.counter) best = m;
        }
        if (best) |m| lowest = @min(lowest, m.format_version);
    }
    return lowest;
}

fn tmpPath(aa: std.mem.Allocator, tmp: *const testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

fn graphDir(aa: std.mem.Allocator, root: []const u8, uuid: [16]u8) ![]u8 {
    const hex = std.fmt.bytesToHex(uuid, .lower);
    return std.fmt.allocPrint(aa, "{s}/{s}", .{ root, &hex });
}

const N: usize = 32;

/// `N` nodes labelled `needles.label` with the string and number property.
fn seed(adapter: *StorageAdapter, graph: []const u8, needles: Needles) !void {
    for (0..N) |i| {
        const id = try adapter.createNode(graph, &.{needles.label});
        try adapter.setNodeProperty(graph, id, needles.key, .{ .String = needles.value });
        try adapter.setNodeProperty(graph, id, "uid", .{ .Int = @intCast(i) });
        try adapter.setNodeProperty(graph, id, "num", .{ .Int = needles.number });
    }
}

/// `expectIndexedOnce`, retried while the exact index is being built (a read
/// then answers `ExactIndexBusy` at once and the executor falls back to a
/// scan, SONNY-6362; here the answer must come from the index).
fn expectIndexed(adapter: *StorageAdapter, graph: []const u8, needles: Needles) !void {
    var tries: usize = 0;
    while (true) : (tries += 1) {
        expectIndexedOnce(adapter, graph, needles) catch |err| {
            if (err != error.ExactIndexBusy or tries >= 1200) return err;
            io().sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
            continue;
        };
        return;
    }
}

fn expectIndexedOnce(adapter: *StorageAdapter, graph: []const u8, needles: Needles) !void {
    const got = try adapter.getCandidateNodesByLabelAndProperty(graph, needles.label, needles.key, .{ .String = needles.value }, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(N, got.len);
    try testing.expectEqual(@as(usize, 1), try adapter.countCandidateNodesByLabelAndProperty(graph, needles.label, "uid", .{ .Int = 7 }));
    try testing.expectEqual(N, try adapter.countCandidateNodesByLabelAndProperty(graph, needles.label, "num", .{ .Int = needles.number }));
}

// ===========================================================================
// geode's exact-index files
// ===========================================================================

test "SONNY-6590: under TDE prop_exact.idx and prop_rev.idx are sealed, hold no name or value, and a clean reopen reloads them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(aa, &tmp);
    const key = randomKey();
    const needles = try Needles.make(aa);
    const graph = "g6590";

    var gdir: []u8 = undefined;
    {
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
        defer adapter.deinit();
        try seed(adapter, graph, needles);
        try expectIndexed(adapter, graph, needles);
        try adapter.checkpointAll();
        gdir = try graphDir(aa, path, (try adapter.lookupManagedGraph(graph)).uuid);
    }
    for ([_][]const u8{ "prop_exact.idx", "prop_rev.idx" }) |name| {
        const bytes = try readAll(aa, try std.fmt.allocPrint(aa, "{s}/{s}", .{ gdir, name }));
        try testing.expect(crypto.isSealed(bytes));
    }
    const nl = needles.list();
    try testing.expectEqual(@as(usize, 0), (try scan(aa, path, &nl)).len);

    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
    defer adapter.deinit();
    _ = try adapter.getOrCreateGraph(graph);
    try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexReloadedForTesting());
    try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());
    try expectIndexed(adapter, graph, needles);
}

const Dump = []StorageAdapter.ExactIndexPostingDump;

fn freeDump(d: Dump) void {
    for (d) |e| {
        testing.allocator.free(e.key);
        testing.allocator.free(e.nodes);
    }
    testing.allocator.free(d);
}

test "SONNY-6590: under TDE a crash reopen reconciles the WAL tail into the sealed exact index exactly as a rebuild" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(aa, &tmp);
    const key = randomKey();
    const needles = try Needles.make(aa);
    const graph = "crash6590";

    var changed: u64 = 0;
    {
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
        try seed(adapter, graph, needles);
        try adapter.checkpointAll();
        // A committed tail past the checkpoint: a change, a delete, an insert.
        changed = (try adapter.getCandidateNodesByLabelAndProperty(graph, needles.label, "uid", .{ .Int = 3 }, aa))[0];
        try adapter.setNodeProperty(graph, changed, "uid", .{ .Int = 1_000_003 });
        const deleted = (try adapter.getCandidateNodesByLabelAndProperty(graph, needles.label, "uid", .{ .Int = 4 }, aa))[0];
        try adapter.deleteNode(graph, deleted);
        const inserted = try adapter.createNode(graph, &.{needles.label});
        try adapter.setNodeProperty(graph, inserted, "uid", .{ .Int = 1_000_000 });
        adapter.simulateCrashForTesting();
    }
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    adapter_mod.resetExactIndexReconcileCountersForTesting();
    const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
    defer adapter.deinit();
    _ = try adapter.getOrCreateGraph(graph);
    try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexReconciledForTesting());
    try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

    try testing.expectEqual(@as(usize, 1), try adapter.countCandidateNodesByLabelAndProperty(graph, needles.label, "uid", .{ .Int = 1_000_003 }));
    try testing.expectEqual(@as(usize, 0), try adapter.countCandidateNodesByLabelAndProperty(graph, needles.label, "uid", .{ .Int = 3 }));
    try testing.expectEqual(@as(usize, 0), try adapter.countCandidateNodesByLabelAndProperty(graph, needles.label, "uid", .{ .Int = 4 }));
    try testing.expectEqual(@as(usize, 1), try adapter.countCandidateNodesByLabelAndProperty(graph, needles.label, "uid", .{ .Int = 1_000_000 }));

    const reconciled = try adapter.dumpExactIndexPostingsForTesting(graph, testing.allocator);
    defer freeDump(reconciled);
    try adapter.rebuildExactPropertyIndexForTesting(graph);
    const rebuilt = try adapter.dumpExactIndexPostingsForTesting(graph, testing.allocator);
    defer freeDump(rebuilt);
    try testing.expectEqual(rebuilt.len, reconciled.len);
    for (reconciled, rebuilt) |a, b| {
        try testing.expectEqualSlices(u8, a.key, b.key);
        try testing.expectEqualSlices(u64, a.nodes, b.nodes);
    }
    const nl = needles.list();
    try testing.expectEqual(@as(usize, 0), (try scan(aa, path, &nl)).len);
}

test "SONNY-6590: exact-index files written in plaintext before SONNY-6590 are deleted at open, rebuilt and saved sealed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(aa, &tmp);
    const key = randomKey();
    const needles = try Needles.make(aa);
    const graph = "upgrade6590";
    const nl = needles.list();

    var gdir: []u8 = undefined;
    {
        // What geode wrote before SONNY-6590: the exact index in plaintext
        // beside graph-storage's sealed files.
        adapter_mod.setPlaintextExactIndexForTest(true);
        defer adapter_mod.setPlaintextExactIndexForTest(false);
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
        defer adapter.deinit();
        try seed(adapter, graph, needles);
        try expectIndexed(adapter, graph, needles);
        try adapter.checkpointAll();
        gdir = try graphDir(aa, path, (try adapter.lookupManagedGraph(graph)).uuid);
    }
    const exact_path = try std.fmt.allocPrint(aa, "{s}/prop_exact.idx", .{gdir});
    const rev_path = try std.fmt.allocPrint(aa, "{s}/prop_rev.idx", .{gdir});
    try testing.expect(!crypto.isSealed(try readAll(aa, exact_path)));
    // The old layout: the property key name is in both files.
    const before = try scan(aa, path, &nl);
    try testing.expect(before.len >= 2);
    for (before) |h| try testing.expect(std.mem.indexOf(u8, h, "prop_exact.idx") != null or std.mem.indexOf(u8, h, "prop_rev.idx") != null);

    adapter_mod.resetExactIndexReloadCountersForTesting();
    {
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
        defer adapter.deinit();
        _ = try adapter.getOrCreateGraph(graph);
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactIndexReloadedForTesting());
        // Gone as soon as the graph opened, before any checkpoint.
        try testing.expect(!fileExists(exact_path));
        try testing.expect(!fileExists(rev_path));
        try expectIndexed(adapter, graph, needles);
        try adapter.checkpointAll();
    }
    try testing.expect(crypto.isSealed(try readAll(aa, exact_path)));
    try testing.expect(crypto.isSealed(try readAll(aa, rev_path)));
    try testing.expectEqual(@as(usize, 0), (try scan(aa, path, &nl)).len);

    adapter_mod.resetExactIndexReloadCountersForTesting();
    const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
    defer adapter.deinit();
    _ = try adapter.getOrCreateGraph(graph);
    try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexReloadedForTesting());
    try expectIndexed(adapter, graph, needles);
}

test "SONNY-6590: a sealed exact index copied from another graph, or modified, is rebuilt instead of served" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(aa, &tmp);
    const key = randomKey();
    const na = try Needles.make(aa);
    const nb = try Needles.make(aa);

    var dir_a: []u8 = undefined;
    var dir_b: []u8 = undefined;
    {
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
        defer adapter.deinit();
        try seed(adapter, "ga", na);
        try seed(adapter, "gb", nb);
        try expectIndexed(adapter, "ga", na);
        try expectIndexed(adapter, "gb", nb);
        try adapter.checkpointAll();
        dir_a = try graphDir(aa, path, (try adapter.lookupManagedGraph("ga")).uuid);
        dir_b = try graphDir(aa, path, (try adapter.lookupManagedGraph("gb")).uuid);
    }
    // gb gets ga's files (same key, same file names, another graph's uuid).
    for ([_][]const u8{ "prop_exact.idx", "prop_rev.idx" }) |name| {
        const bytes = try readAll(aa, try std.fmt.allocPrint(aa, "{s}/{s}", .{ dir_a, name }));
        try writeAll(try std.fmt.allocPrint(aa, "{s}/{s}", .{ dir_b, name }), bytes);
    }
    // ga's own file gets one flipped ciphertext byte.
    const a_exact = try std.fmt.allocPrint(aa, "{s}/prop_exact.idx", .{dir_a});
    const a_bytes = try readAll(aa, a_exact);
    a_bytes[crypto.HEADER_SIZE + 3] ^= 0x01;
    try writeAll(a_exact, a_bytes);

    adapter_mod.resetExactIndexReloadCountersForTesting();
    const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
    defer adapter.deinit();
    _ = try adapter.getOrCreateGraph("gb");
    _ = try adapter.getOrCreateGraph("ga");
    try testing.expectEqual(@as(u64, 0), adapter_mod.getExactIndexReloadedForTesting());
    try expectIndexed(adapter, "gb", nb);
    try expectIndexed(adapter, "ga", na);
    try testing.expectEqual(@as(usize, 0), try adapter.countCandidateNodesByLabelAndProperty("gb", na.label, na.key, .{ .String = na.value }));
}

// ===========================================================================
// graph-storage side files: refusal of one graph, operator messages
// ===========================================================================

/// The shard directories of `gdir` (`<gdir>/graphs/<shard uuid>`).
fn firstShardLabelsDict(aa: std.mem.Allocator, gdir: []const u8) !struct { path: []const u8, uuid: [16]u8 } {
    const shards = try std.fmt.allocPrint(aa, "{s}/graphs", .{gdir});
    var dir = try std.Io.Dir.cwd().openDir(io(), shards, .{ .iterate = true });
    defer dir.close(io());
    var it = dir.iterate();
    while (try it.next(io())) |e| {
        if (e.kind != .directory or e.name.len != 32) continue;
        const p = try std.fmt.allocPrint(aa, "{s}/{s}/labels.dict", .{ shards, e.name });
        if (!fileExists(p)) continue;
        var uuid: [16]u8 = undefined;
        _ = try std.fmt.hexToBytes(&uuid, e.name);
        return .{ .path = p, .uuid = uuid };
    }
    return error.NoLabelsDict;
}

fn expectOperatorMessage(err: anyerror, key: [32]u8) !void {
    const info = geode.proto_util.mapError(err);
    try testing.expectEqualStrings("58000", info.code);
    try testing.expect(std.mem.startsWith(u8, info.message, @errorName(err)));
    try testing.expect(std.mem.indexOf(u8, info.message, "GEODE_TDE_KEY") != null or err == error.SideFileNotSealed);
    const hex = std.fmt.bytesToHex(key, .lower);
    try testing.expect(std.mem.indexOf(u8, info.message, hex[0..16]) == null);
    try testing.expect(geode.proto_util.statementErrorInfo(err) != null);
}

test "SONNY-6590: a graph whose sealed labels.dict fails authentication, is plaintext, or has no key is refused alone with a 58000 operator message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(aa, &tmp);
    const key = randomKey();
    const nok = try Needles.make(aa);
    const nbad = try Needles.make(aa);

    var bad_dir: []u8 = undefined;
    {
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
        defer adapter.deinit();
        try seed(adapter, "okg", nok);
        try seed(adapter, "badg", nbad);
        try adapter.checkpointAll();
        bad_dir = try graphDir(aa, path, (try adapter.lookupManagedGraph("badg")).uuid);
    }
    const dict = try firstShardLabelsDict(aa, bad_dir);
    const sealed = try readAll(aa, dict.path);
    try testing.expect(crypto.isSealed(sealed));

    const Case = struct { what: []const u8, bytes: []const u8, key: ?[32]u8, want: anyerror };
    const tampered = try aa.dupe(u8, sealed);
    tampered[crypto.HEADER_SIZE + 1] ^= 0x01;
    var c = crypto.Cipher.init(key, dict.uuid);
    defer c.deinit();
    const plain = try c.open(aa, .label_dict, "labels.dict", sealed);
    const cases = [_]Case{
        .{ .what = "modified", .bytes = tampered, .key = key, .want = error.SideFileAuthFailed },
        .{ .what = "plaintext in a sealed store", .bytes = plain, .key = key, .want = error.SideFileNotSealed },
    };
    // (Another key is caught before any side file: graph-storage
    // authenticates the manifests with an HMAC under the key, and a manifest
    // that fails it reads as absent, `NoManifest`. One key serves every graph,
    // so on a server the security graph refuses startup first.)
    for (cases) |cs| {
        try writeAll(dict.path, cs.bytes);
        defer writeAll(dict.path, sealed) catch {};
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(cs.key));
        defer adapter.deinit();
        const got = adapter.getOrCreateGraph("badg");
        std.debug.print("[SONNY-6590] labels.dict {s}: {any}\n", .{ cs.what, got });
        try testing.expectError(cs.want, got);
        try testing.expectError(cs.want, adapter.createNode("badg", &.{"X"}));
        try expectOperatorMessage(cs.want, key);
        // The other graph is untouched.
        try expectIndexed(adapter, "okg", nok);
    }

    // No key at all: the sealed side files cannot be read.
    {
        const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(null));
        defer adapter.deinit();
        const got = adapter.getOrCreateGraph("okg");
        std.debug.print("[SONNY-6590] no key: {any}\n", .{got});
        try testing.expectError(error.SideFileEncrypted, got);
        try expectOperatorMessage(error.SideFileEncrypted, key);
    }

    // The original file back: the graph opens and answers.
    const adapter = try StorageAdapter.init(testing.allocator, path, tdeConfig(key));
    defer adapter.deinit();
    try expectIndexed(adapter, "badg", nbad);
    try expectIndexed(adapter, "okg", nok);
}

// ===========================================================================
// Time-series
// ===========================================================================

const ts_key = ts.SeriesKey{ .device_id = 6590, .metric = "sonny6590" };

test "SONNY-6590: GEODE_TDE_KEY alone turns time-series encryption on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const key = randomKey();
    const hex = std.fmt.bytesToHex(key, .lower);
    const hex_z = try arena.allocator().dupeZ(u8, &hex);
    defer _ = unsetenv("GEODE_TDE_KEY");
    defer _ = unsetenv("GEODE_TS_TDE");

    _ = unsetenv("GEODE_TDE_KEY");
    _ = unsetenv("GEODE_TS_TDE");
    try testing.expectEqual(@as(?[32]u8, null), try ts.encryptionKeyFromEnv());
    _ = setenv("GEODE_TDE_KEY", hex_z, 1);
    try testing.expectEqual(@as(?[32]u8, key), try ts.encryptionKeyFromEnv());
    _ = setenv("GEODE_TS_TDE", "1", 1);
    try testing.expectEqual(@as(?[32]u8, key), try ts.encryptionKeyFromEnv());
    _ = setenv("GEODE_TS_TDE", "true", 1);
    try testing.expectEqual(@as(?[32]u8, key), try ts.encryptionKeyFromEnv());
}

test "SONNY-6590: an empty plaintext time-series store is replaced by an encrypted one; one holding data is refused and kept" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const key = randomKey();
    const value = randomWideInt();
    var value_le: [8]u8 = undefined;
    std.mem.writeInt(i64, &value_le, value, .little);

    // Empty plaintext store (what every graph got before SONNY-6590).
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tmpPath(aa, &tmp);
        {
            var st = try ts.Store.initWithConfig(testing.allocator, .{ .data_dir = path });
            st.deinit();
        }
        {
            var st = try ts.Store.initWithConfig(testing.allocator, .{ .data_dir = path, .encryption_key = key });
            defer st.deinit();
            try st.insertMany(ts_key, &.{.{ .ts = 1000, .value = value }});
            try st.sync();
        }
        try testing.expectEqual(@as(usize, 0), (try scan(aa, path, &.{&value_le})).len);
        // Encrypted: reads back under the key.
        var st = try ts.Store.initWithConfig(testing.allocator, .{ .data_dir = path, .encryption_key = key });
        defer st.deinit();
        const pts = try st.queryRange(ts_key, 1000, 1000, testing.allocator);
        defer testing.allocator.free(pts);
        try testing.expectEqual(@as(usize, 1), pts.len);
        try testing.expectEqual(value, pts[0].value);
    }

    // Plaintext store holding a point.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tmpPath(aa, &tmp);
        {
            var st = try ts.Store.initWithConfig(testing.allocator, .{ .data_dir = path });
            defer st.deinit();
            try st.insertMany(ts_key, &.{.{ .ts = 1000, .value = value }});
            try st.sync();
        }
        try testing.expect((try scan(aa, path, &.{&value_le})).len > 0);
        try testing.expectError(error.TimeseriesNotEncrypted, ts.Store.initWithConfig(testing.allocator, .{ .data_dir = path, .encryption_key = key }));
        try testing.expectError(error.TimeseriesNotEncrypted, ts.Store.initWithConfig(testing.allocator, .{ .data_dir = path, .encryption_key = key, .durability = .best_effort }));
        try testing.expect((try scan(aa, path, &.{&value_le})).len > 0);
        var st = try ts.Store.initWithConfig(testing.allocator, .{ .data_dir = path });
        defer st.deinit();
        const pts = try st.queryRange(ts_key, 1000, 1000, testing.allocator);
        defer testing.allocator.free(pts);
        try testing.expectEqual(@as(usize, 1), pts.len);
        try testing.expectEqual(value, pts[0].value);
    }
}

/// A store killed after `value` was accepted: its point is in `ts.wal` only
/// (no flush, so no manifest and no segment). Never deinitialised, like a
/// killed process (the page allocator, as test-ts-durability does).
fn killedStoreWithPoint(path: []const u8, key: ?[32]u8, value: i64) !void {
    const crash_alloc = std.heap.page_allocator;
    const st = try crash_alloc.create(ts.Store);
    st.* = try ts.Store.initWithConfig(crash_alloc, .{ .data_dir = path, .encryption_key = key });
    try st.insertMany(ts_key, &.{.{ .ts = 1000, .value = value }});
}

fn walBytes(aa: std.mem.Allocator, path: []const u8) ![]u8 {
    return readAll(aa, try std.fmt.allocPrint(aa, "{s}/timeseries/ts.wal", .{path}));
}

test "SONNY-6590: a time-series WAL of the other layout is never opened (the engine would truncate it): refused, and the point survives" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const key = randomKey();
    const value = randomWideInt();

    // Plaintext WAL, opened under the key.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tmpPath(aa, &tmp);
        try killedStoreWithPoint(path, null, value);
        const before = try walBytes(aa, path);
        try testing.expect(before.len > 0);
        try testing.expectError(error.TimeseriesNotEncrypted, ts.Store.initWithConfig(testing.allocator, .{ .data_dir = path, .encryption_key = key }));
        try testing.expectEqualSlices(u8, before, try walBytes(aa, path));
        var st = try ts.Store.initWithConfig(testing.allocator, .{ .data_dir = path });
        defer st.deinit();
        const pts = try st.queryRange(ts_key, 1000, 1000, testing.allocator);
        defer testing.allocator.free(pts);
        try testing.expectEqual(@as(usize, 1), pts.len);
        try testing.expectEqual(value, pts[0].value);
    }
    // Encrypted WAL, opened without the key.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tmpPath(aa, &tmp);
        try killedStoreWithPoint(path, key, value);
        const before = try walBytes(aa, path);
        try testing.expect(before.len > 0);
        try testing.expectError(error.TimeseriesNeedsTdeKey, ts.Store.initWithConfig(testing.allocator, .{ .data_dir = path }));
        try testing.expectEqualSlices(u8, before, try walBytes(aa, path));
        try testing.expectEqual(error.TimeseriesNeedsTdeKey, geode.graph_store.GraphQuarantineError.TimeseriesNeedsTdeKey);
        try testing.expectEqualStrings("58000", geode.proto_util.mapError(error.TimeseriesNeedsTdeKey).code);
        var st = try ts.Store.initWithConfig(testing.allocator, .{ .data_dir = path, .encryption_key = key });
        defer st.deinit();
        const pts = try st.queryRange(ts_key, 1000, 1000, testing.allocator);
        defer testing.allocator.free(pts);
        try testing.expectEqual(@as(usize, 1), pts.len);
        try testing.expectEqual(value, pts[0].value);
    }
}

// ===========================================================================
// Real server
// ===========================================================================

const Server = struct {
    handle: util.ServerHandle,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8, env: []const []const u8) !Server {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var handle = try util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir, "--persist-interval", "300" }, env);
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .handle = handle, .addr = addr };
    }

    /// SIGTERM (a clean shutdown checkpoints) and reap.
    fn stop(self: *Server, allocator: std.mem.Allocator) void {
        if (self.handle.child.id) |pid| {
            std.posix.kill(pid, std.posix.SIG.TERM) catch {};
            _ = self.handle.child.wait(self.handle.threaded.io()) catch {};
            self.handle.child.id = null;
        }
        self.handle.deinit();
        allocator.free(self.addr);
    }

    fn connect(self: *Server, allocator: std.mem.Allocator) !util.QuicProtoClient {
        var client = try util.QuicProtoClient.connect(allocator, self.addr);
        errdefer client.deinit();
        client.watchServerLiveness(self.handle.child.id orelse return error.NoServerPid);
        var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(allocator);
        if (!h.success) return error.HelloFailed;
        return client;
    }
};

const Reply = struct {
    int: ?i64 = null,
    failed: bool = false,
    message: [768]u8 = undefined,
    len: usize = 0,

    fn text(r: *const Reply) []const u8 {
        return r.message[0..r.len];
    }
};

fn ask(client: *util.QuicProtoClient, q: []const u8) !Reply {
    const allocator = testing.allocator;
    var r = try client.executeAndCollect(allocator, q, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    var out: Reply = .{};
    if (r.error_code) |code| {
        out.failed = true;
        const s = std.fmt.bufPrint(&out.message, "{s} {s}", .{ code, r.error_message orelse "" }) catch out.message[0..];
        out.len = s.len;
    } else if (r.rows.len >= 1 and r.rows[0].len > 0) switch (r.rows[0][0]) {
        .int => |v| out.int = v,
        else => {},
    };
    return out;
}

fn mustAsk(client: *util.QuicProtoClient, q: []const u8) !Reply {
    const r = try ask(client, q);
    if (r.failed) {
        std.debug.print("[SONNY-6590] {s} -> {s}\n", .{ q, r.text() });
        return error.QueryFailed;
    }
    return r;
}

/// `USE GRAPH g` then `q` in a fresh session.
fn askOn(server: *Server, g: []const u8, q: []const u8) !Reply {
    var client = try server.connect(testing.allocator);
    defer client.deinit();
    var qb: [160]u8 = undefined;
    const use = try ask(&client, try std.fmt.bufPrint(&qb, "USE GRAPH {s}", .{g}));
    if (use.failed) return use;
    return ask(&client, q);
}

fn serverDataDir(buf: []u8, tag: []const u8) ![]const u8 {
    const d = try std.fmt.bufPrint(buf, "/tmp/geode-sonny6590-{s}-{d}", .{ tag, try util.getRandomPort() });
    try std.Io.Dir.cwd().createDirPath(io(), d);
    return d;
}

fn keyEnv(aa: std.mem.Allocator, key: [32]u8) ![]const u8 {
    const hex = std.fmt.bytesToHex(key, .lower);
    return std.fmt.allocPrint(aa, "GEODE_TDE_KEY={s}", .{&hex});
}

/// The graph data the server tests write and read back.
fn writeGraph(server: *Server, aa: std.mem.Allocator, g: []const u8, n: Needles) !void {
    var client = try server.connect(testing.allocator);
    defer client.deinit();
    _ = try mustAsk(&client, try std.fmt.allocPrint(aa, "CREATE GRAPH {s}", .{g}));
    _ = try mustAsk(&client, try std.fmt.allocPrint(aa, "USE GRAPH {s}", .{g}));
    for (0..8) |i| _ = try mustAsk(&client, try std.fmt.allocPrint(aa, "CREATE (:{s} {{{s}: '{s}', num: {d}, uid: {d}}})", .{ n.label, n.key, n.value, n.number, i }));
    _ = try mustAsk(&client, try std.fmt.allocPrint(aa, "CREATE INDEX {s}_idx ON :{s}({s})", .{ n.key, n.label, n.key }));
    _ = try mustAsk(&client, try std.fmt.allocPrint(aa, "MATCH (n:{s}) RETURN n.{s} AS k ORDER BY k", .{ n.label, n.key }));
    try expectGraph(server, aa, g, n);
}

fn expectGraph(server: *Server, aa: std.mem.Allocator, g: []const u8, n: Needles) !void {
    const qs = [_]struct { q: []const u8, want: i64 }{
        .{ .q = try std.fmt.allocPrint(aa, "MATCH (n:{s}) WHERE n.{s} = '{s}' RETURN count(n) AS c", .{ n.label, n.key, n.value }), .want = 8 },
        .{ .q = try std.fmt.allocPrint(aa, "MATCH (n:{s} {{num: {d}}}) RETURN count(n) AS c", .{ n.label, n.number }), .want = 8 },
        .{ .q = try std.fmt.allocPrint(aa, "MATCH (n:{s}) WHERE n.uid = 5 RETURN n.num AS v", .{n.label}), .want = n.number },
    };
    for (qs) |q| {
        const r = try askOn(server, g, q.q);
        if (r.failed or r.int == null or r.int.? != q.want) {
            std.debug.print("[SONNY-6590] {s}: {s} -> {s}{?d}, want {d}\n", .{ g, q.q, r.text(), r.int, q.want });
            return error.WrongAnswer;
        }
    }
}

test "SONNY-6590: a data directory written under TDE before SONNY-6590 (plaintext side files, format_version 4, plaintext time-series) is upgraded by a real server and keeps nothing in plaintext" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try serverDataDir(&dir_buf, "upgrade");
    defer std.Io.Dir.cwd().deleteTree(io(), data_dir) catch {};
    const key = randomKey();
    const needles = try Needles.make(aa);
    const ts_value = randomWideInt();
    var ts_le: [8]u8 = undefined;
    std.mem.writeInt(i64, &ts_le, ts_value, .little);

    // Written as before SONNY-6590: time-series in plaintext beside the
    // encrypted graph store (GEODE_TDE_KEY without GEODE_TS_TDE did that).
    {
        var server = try Server.start(testing.allocator, data_dir, &.{ try keyEnv(aa, key), "GEODE_TS_TDE=0" });
        defer server.stop(testing.allocator);
        try writeGraph(&server, aa, "g6590", needles);
    }
    // ... and graph-storage <= 0.4.16 / geode's exact index in plaintext.
    const unsealed = try unsealTree(aa, data_dir, key);
    const manifests = try setManifestVersions(aa, data_dir, key, gs.manifest.MANIFEST_VERSION);
    std.debug.print("[SONNY-6590] legacy layout: {d} side files unsealed, {d} manifests at format_version {d}\n", .{ unsealed, manifests, gs.manifest.MANIFEST_VERSION });
    try testing.expect(unsealed >= 16 + 2);
    const nl = needles.list();
    const before = try scan(aa, data_dir, &nl);
    try testing.expect(before.len > 0);

    {
        var server = try Server.start(testing.allocator, data_dir, &.{try keyEnv(aa, key)});
        defer server.stop(testing.allocator);
        try expectGraph(&server, aa, "g6590", needles);
        var client = try server.connect(testing.allocator);
        defer client.deinit();
        _ = try mustAsk(&client, try std.fmt.allocPrint(aa, "CALL geode.ts.insert(6590, 'sonny6590', 1000, {d})", .{ts_value}));
        const r = try mustAsk(&client, "CALL geode.ts.range(6590, 'sonny6590', 1000, 1000) YIELD ts, value RETURN value");
        try testing.expectEqual(@as(?i64, ts_value), r.int);
    }
    const all = [_][]const u8{ nl[0], nl[1], nl[2], nl[3], &ts_le };
    try testing.expectEqual(@as(usize, 0), (try scan(aa, data_dir, &all)).len);
    try testing.expectEqual(gs.manifest.MANIFEST_VERSION_SEALED_SIDE_FILES, try minManifestVersion(aa, data_dir, key));

    // And again after the upgrade, from the sealed layout.
    var server = try Server.start(testing.allocator, data_dir, &.{try keyEnv(aa, key)});
    defer server.stop(testing.allocator);
    try expectGraph(&server, aa, "g6590", needles);
}

test "SONNY-6590: a real server refuses a graph whose labels.dict fails authentication or is plaintext, and keeps serving its other graph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try serverDataDir(&dir_buf, "refuse");
    defer std.Io.Dir.cwd().deleteTree(io(), data_dir) catch {};
    const key = randomKey();
    const nok = try Needles.make(aa);
    const nbad = try Needles.make(aa);
    const env = [_][]const u8{try keyEnv(aa, key)};

    {
        var server = try Server.start(testing.allocator, data_dir, &env);
        defer server.stop(testing.allocator);
        try writeGraph(&server, aa, "okg", nok);
        try writeGraph(&server, aa, "badg", nbad);
    }
    // badg's directory: the graph uuid directory holding a labels.dict
    // that names nbad's label.
    const dict = blk: {
        var dir = try std.Io.Dir.cwd().openDir(io(), data_dir, .{ .iterate = true });
        defer dir.close(io());
        var it = dir.iterate();
        while (try it.next(io())) |e| {
            if (e.kind != .directory or e.name.len != 32) continue;
            const gdir = try std.fmt.allocPrint(aa, "{s}/{s}", .{ data_dir, e.name });
            const d = firstShardLabelsDict(aa, gdir) catch continue;
            var c = crypto.Cipher.init(key, d.uuid);
            defer c.deinit();
            const plain = c.open(aa, .label_dict, "labels.dict", try readAll(aa, d.path)) catch continue;
            if (std.mem.indexOf(u8, plain, nbad.label) != null) break :blk .{ .path = d.path, .plain = plain };
        }
        return error.BadGraphNotFound;
    };
    const sealed = try readAll(aa, dict.path);
    const tampered = try aa.dupe(u8, sealed);
    tampered[sealed.len - 1] ^= 0x01;

    const cases = [_]struct { bytes: []const u8, want: []const u8 }{
        .{ .bytes = tampered, .want = "58000 SideFileAuthFailed" },
        .{ .bytes = dict.plain, .want = "58000 SideFileNotSealed" },
    };
    for (cases) |cs| {
        try writeAll(dict.path, cs.bytes);
        var server = try Server.start(testing.allocator, data_dir, &env);
        defer server.stop(testing.allocator);
        const q = try std.fmt.allocPrint(aa, "MATCH (n:{s}) RETURN count(n) AS c", .{nbad.label});
        const r = try askOn(&server, "badg", q);
        std.debug.print("[SONNY-6590] badg ({s}): {s}\n", .{ cs.want, r.text() });
        try testing.expect(r.failed and std.mem.startsWith(u8, r.text(), cs.want));
        try testing.expect(std.mem.indexOf(u8, r.text(), &std.fmt.bytesToHex(key, .lower)) == null);
        const w = try askOn(&server, "badg", try std.fmt.allocPrint(aa, "CREATE (:{s})", .{nbad.label}));
        try testing.expect(w.failed and std.mem.startsWith(u8, w.text(), cs.want));
        try expectGraph(&server, aa, "okg", nok);
        try testing.expect(util.processAlive(server.handle.child.id.?));
    }
    // Restored from "backup": served again.
    try writeAll(dict.path, sealed);
    var server = try Server.start(testing.allocator, data_dir, &env);
    defer server.stop(testing.allocator);
    try expectGraph(&server, aa, "badg", nbad);
    try expectGraph(&server, aa, "okg", nok);
}

test "SONNY-6590: a server-wide time-series store written in plaintext with data stops startup under GEODE_TDE_KEY, keeps the data, and reads with GEODE_TS_TDE=0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try serverDataDir(&dir_buf, "ts");
    defer std.Io.Dir.cwd().deleteTree(io(), data_dir) catch {};
    const key = randomKey();
    const ts_value = randomWideInt();
    var ts_le: [8]u8 = undefined;
    std.mem.writeInt(i64, &ts_le, ts_value, .little);
    const insert = try std.fmt.allocPrint(aa, "CALL geode.ts.insert(6590, 'sonny6590', 1000, {d})", .{ts_value});
    const range = "CALL geode.ts.range(6590, 'sonny6590', 1000, 1000) YIELD ts, value RETURN value";
    const ts_dir = try std.fmt.allocPrint(aa, "{s}/timeseries", .{data_dir});

    {
        var server = try Server.start(testing.allocator, data_dir, &.{ try keyEnv(aa, key), "GEODE_TS_TDE=0" });
        defer server.stop(testing.allocator);
        var client = try server.connect(testing.allocator);
        defer client.deinit();
        _ = try mustAsk(&client, insert);
    }
    try testing.expect((try scan(aa, ts_dir, &.{&ts_le})).len > 0);

    // GEODE_TDE_KEY alone: startup stops, nothing is dropped.
    {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(testing.allocator, port);
        defer testing.allocator.free(addr);
        var handle = try util.spawnServer(testing.allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, &.{try keyEnv(aa, key)});
        defer handle.deinit();
        const pid = handle.child.id.?;
        var waited: usize = 0;
        while (util.processAlive(pid) and waited < 300) : (waited += 1) {
            io().sleep(.fromNanoseconds(100 * std.time.ns_per_ms), .awake) catch {};
        }
        try testing.expect(!util.processAlive(pid));
    }
    try testing.expect((try scan(aa, ts_dir, &.{&ts_le})).len > 0);

    // The explicit opt-out reads it (to export it).
    var server = try Server.start(testing.allocator, data_dir, &.{ try keyEnv(aa, key), "GEODE_TS_TDE=0" });
    defer server.stop(testing.allocator);
    var client = try server.connect(testing.allocator);
    defer client.deinit();
    const r = try mustAsk(&client, range);
    try testing.expectEqual(@as(?i64, ts_value), r.int);
}
