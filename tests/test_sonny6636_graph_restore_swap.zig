// SONNY-6636 (1): a crash-safe swap of whole graphs into a data directory,
// the storage half of restoring a Raft snapshot into the durable store.
//
// A follower could not restore a snapshot into the durable store
// (`RaftSnapshotRestoreNotDurable`): nothing could replace a graph's files
// while the server ran, nor survive a crash in the middle. A restored graph
// keeps the uuid its files were written under (graph-storage binds it into
// the manifest, WAL header, shard uuids and, under at-rest encryption, the
// keys): it is staged at `<data_dir>/<uuid>.restore`, a fsynced intent marked
// committed is the commit point, and the swap renames it into place and
// points the registry at it (`StorageAdapter.beginGraphRestore`,
// `commitGraphRestore`). `StorageAdapter.init` settles an interrupted swap
// from the intent.
//
// Each case stops the swap where a crash would and reopens the data
// directory: it holds exactly the old graph or exactly the restored one, the
// graph the restore did not touch, no intent and no directory the registry
// does not name. Both shapes run: a graph restored under a uuid new here,
// and one restored again under its own uuid (the live directory is renamed
// aside), with and without at-rest encryption.
//
// CANARY: REQ=REQ-SONNY-6636-CRASH-SAFE-GRAPH-SWAP; FEATURE="Raft Snapshot Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6636_graph_restore_swap.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const test_scratch = @import("test_scratch.zig");

const adapter_mod = geode.graph_storage_adapter;
const StorageAdapter = adapter_mod.StorageAdapter;
const Step = StorageAdapter.GraphRestoreStep;
const testing = std.testing;
const io = std.Io.Threaded.global_single_threaded.io();

const OLD = "Old6636";
const NEW = "New6636";
const MORE = "More6636";
const KEEP = "Keep6636";

fn open(a: std.mem.Allocator, dir: []const u8, key: ?[32]u8) !*StorageAdapter {
    return StorageAdapter.init(a, dir, .{ .data_dir = dir, .encryption_key = key });
}

fn count(a: std.mem.Allocator, ad: *StorageAdapter, graph: []const u8, label: []const u8) !usize {
    const ids = try ad.getNodesByLabel(graph, label, a);
    defer a.free(ids);
    return ids.len;
}

fn addNodes(a: std.mem.Allocator, dir: []const u8, key: ?[32]u8, graph: []const u8, label: []const u8, n: usize) !void {
    const ad = try open(a, dir, key);
    defer ad.deinit();
    if (ad.registry.findByName(graph) == null) _ = try ad.createGraph(graph);
    for (0..n) |_| _ = try ad.createNode(graph, &.{label});
    try ad.checkpointAll();
}

fn uuidOf(a: std.mem.Allocator, dir: []const u8, key: ?[32]u8, graph: []const u8) ![16]u8 {
    const ad = try open(a, dir, key);
    defer ad.deinit();
    return ad.registry.findByName(graph).?.uuid;
}

/// Copy the tree `src` into the existing directory `dst` (what the restore's
/// caller does with the leader's archive).
fn copyTree(a: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    var d = try std.Io.Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        const s = try std.fmt.allocPrint(a, "{s}/{s}", .{ src, e.name });
        defer a.free(s);
        const t = try std.fmt.allocPrint(a, "{s}/{s}", .{ dst, e.name });
        defer a.free(t);
        switch (e.kind) {
            .directory => {
                try std.Io.Dir.cwd().createDirPath(io, t);
                try copyTree(a, s, t);
            },
            .file => try std.Io.Dir.copyFile(std.Io.Dir.cwd(), s, std.Io.Dir.cwd(), t, io, .{}),
            else => {},
        }
    }
}

fn intentExists(a: std.mem.Allocator, dir: []const u8) !bool {
    const p = try std.fmt.allocPrint(a, "{s}/graph_restore.intent", .{dir});
    defer a.free(p);
    std.Io.Dir.cwd().access(io, p, .{}) catch return false;
    return true;
}

/// Every graph directory in `dir` is one the registry names; none staged or
/// set aside is left.
fn expectNoOrphanGraphDirs(ad: *StorageAdapter, dir: []const u8) !void {
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    var graph_dirs: usize = 0;
    while (try it.next(io)) |e| {
        if (e.kind != .directory or e.name.len < 32) continue;
        var u: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&u, e.name[0..32]) catch continue;
        if (e.name.len != 32 or ad.registry.findByUuid(u) == null) {
            std.debug.print("SONNY-6636 (1): directory {s} is named by no registry entry\n", .{e.name});
            return error.OrphanGraphDirectory;
        }
        graph_dirs += 1;
    }
    try testing.expectEqual(ad.registry.entries.items.len, graph_dirs);
}

const Shape = enum { new_uuid, own_uuid };
const Stop = enum { none, intent_written, staged, committed, renamed, registry_saved, old_deleted };

fn crashStep(stop: Stop) ?Step {
    return switch (stop) {
        .none, .staged => null,
        .intent_written => .intent_written,
        .committed => .committed,
        .renamed => .renamed,
        .registry_saved => .registry_saved,
        .old_deleted => .old_deleted,
    };
}

/// Restore graph "g" of `source` into `target`, stopped at `stop`.
fn restore(a: std.mem.Allocator, target: []const u8, source: []const u8, key: ?[32]u8, stop: Stop) !void {
    const src_uuid = try uuidOf(a, source, key, "g");
    const hex = std.fmt.bytesToHex(src_uuid, .lower);
    const src_graph = try std.fmt.allocPrint(a, "{s}/{s}", .{ source, &hex });
    defer a.free(src_graph);
    adapter_mod.setGraphRestoreCrashForTesting(crashStep(stop));
    defer adapter_mod.setGraphRestoreCrashForTesting(null);
    const ad = try open(a, target, key);
    defer ad.deinit();
    _ = try count(a, ad, "g", KEEP); // the old graph is open when the swap runs
    var r = ad.beginGraphRestore(&.{.{ .name = "g", .uuid = src_uuid }}) catch |err| {
        try testing.expect(stop == .intent_written);
        return testing.expectEqual(error.InjectedGraphRestoreCrash, err);
    };
    defer r.deinit();
    try copyTree(a, src_graph, r.staged_dirs[0]);
    if (stop == .staged) return; // a crash before the commit
    ad.commitGraphRestore(&r) catch |err| {
        try testing.expect(stop != .none);
        return testing.expectEqual(error.InjectedGraphRestoreCrash, err);
    };
    try testing.expectEqual(Stop.none, stop);
    try testing.expect(!try intentExists(a, target));
}

fn runCase(shape: Shape, stop: Stop, key: ?[32]u8) !void {
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6636-swap");
    defer root.remove();
    const target = try std.fmt.allocPrint(a, "{s}/target", .{root.path()});
    defer a.free(target);
    const source = try std.fmt.allocPrint(a, "{s}/source", .{root.path()});
    defer a.free(source);
    try addNodes(a, target, key, "g", OLD, 2);
    try addNodes(a, target, key, "h", KEEP, 1);
    try addNodes(a, source, key, "g", NEW, 3);
    if (shape == .own_uuid) {
        // The target already holds g under the source's uuid (an earlier
        // restore); the source has moved on since.
        try restore(a, target, source, key, .none);
        try addNodes(a, source, key, "g", MORE, 2);
    }

    try restore(a, target, source, key, stop);
    try testing.expectEqual(stop != .none, try intentExists(a, target));

    // Reopened, as after the crash.
    const ad = try open(a, target, key);
    defer ad.deinit();
    const restored = switch (stop) {
        .intent_written, .staged => false,
        else => true,
    };
    const new_n = try count(a, ad, "g", NEW);
    const old_n = try count(a, ad, "g", OLD);
    const more_n = try count(a, ad, "g", MORE);
    std.debug.print("SONNY-6636 (1) {s}{s} swap stopped at {s}: reopened with g = {d} {s}, {d} {s}, {d} {s}; h kept {d}\n", .{
        @tagName(shape), if (key != null) " (TDE)" else "", @tagName(stop), old_n, OLD, new_n, NEW, more_n, MORE, try count(a, ad, "h", KEEP),
    });
    switch (shape) {
        .new_uuid => {
            try testing.expectEqual(@as(usize, if (restored) 0 else 2), old_n);
            try testing.expectEqual(@as(usize, if (restored) 3 else 0), new_n);
        },
        .own_uuid => {
            try testing.expectEqual(@as(usize, 0), old_n);
            try testing.expectEqual(@as(usize, 3), new_n);
            try testing.expectEqual(@as(usize, if (restored) 2 else 0), more_n);
        },
    }
    try testing.expectEqual(@as(usize, 1), try count(a, ad, "h", KEEP));
    try testing.expect(!try intentExists(a, target));
    try expectNoOrphanGraphDirs(ad, target);
}

fn runAllStops(shape: Shape, key: ?[32]u8) !void {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    for (std.enums.values(Stop)) |stop| try runCase(shape, stop, key);
}

const tde_key = [_]u8{0x36} ** 32;

test "SONNY-6636 (1): a graph restored under a uuid new here, completed or stopped at every step, reopens on exactly the old or the restored graph" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try runAllStops(.new_uuid, null);
}

test "SONNY-6636 (1): a graph restored again under its own uuid, completed or stopped at every step, reopens on exactly the old or the restored graph" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try runAllStops(.own_uuid, null);
}

test "SONNY-6636 (1): under at-rest encryption, both restore shapes stopped at every step reopen on exactly the old or the restored graph" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try runAllStops(.new_uuid, tde_key);
    try runAllStops(.own_uuid, tde_key);
}

test "SONNY-6636 (1): the running adapter serves the restored graph as soon as the commit returns" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6636-live");
    defer root.remove();
    const target = try std.fmt.allocPrint(a, "{s}/target", .{root.path()});
    defer a.free(target);
    const source = try std.fmt.allocPrint(a, "{s}/source", .{root.path()});
    defer a.free(source);
    try addNodes(a, target, null, "g", OLD, 2);
    try addNodes(a, source, null, "g", NEW, 3);
    const src_uuid = try uuidOf(a, source, null, "g");
    const hex = std.fmt.bytesToHex(src_uuid, .lower);
    const src_graph = try std.fmt.allocPrint(a, "{s}/{s}", .{ source, &hex });
    defer a.free(src_graph);

    const ad = try open(a, target, null);
    defer ad.deinit();
    try testing.expectEqual(@as(usize, 2), try count(a, ad, "g", OLD));
    // A reader pins the old engine across the swap.
    const pinned = ad.pinGraph("g").?;
    var r = try ad.beginGraphRestore(&.{.{ .name = "g", .uuid = src_uuid }});
    defer r.deinit();
    try copyTree(a, src_graph, r.staged_dirs[0]);
    try ad.commitGraphRestore(&r);
    try testing.expect(pinned.isDropped());
    ad.unpinGraph(pinned);
    try testing.expectEqual(@as(usize, 3), try count(a, ad, "g", NEW));
    try testing.expectEqual(@as(usize, 0), try count(a, ad, "g", OLD));
    try expectNoOrphanGraphDirs(ad, target);
}

test "SONNY-6636 (1): a graph created under a restored name after the restore began refuses the commit, changing nothing" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6636-raced");
    defer root.remove();
    const ad = try open(a, root.path(), null);
    defer ad.deinit();
    var r = try ad.beginGraphRestore(&.{.{ .name = "fresh6636", .uuid = [_]u8{0x66} ** 16 }});
    defer r.deinit();
    _ = try ad.createGraph("fresh6636");
    _ = try ad.createNode("fresh6636", &.{KEEP});
    try testing.expectError(error.GraphRestoreRaced, ad.commitGraphRestore(&r));
    ad.abandonGraphRestore(&r);
    try testing.expectEqual(@as(usize, 1), try count(a, ad, "fresh6636", KEEP));
    try testing.expect(!try intentExists(a, root.path()));
    try expectNoOrphanGraphDirs(ad, root.path());
}

test "SONNY-6636 (1): a restore whose uuid belongs to another graph here is refused before anything is written" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6636-uuid-in-use");
    defer root.remove();
    try addNodes(a, root.path(), null, "h", KEEP, 1);
    const h_uuid = try uuidOf(a, root.path(), null, "h");
    const ad = try open(a, root.path(), null);
    defer ad.deinit();
    try testing.expectError(error.GraphRestoreUuidInUse, ad.beginGraphRestore(&.{.{ .name = "g", .uuid = h_uuid }}));
    try testing.expect(!try intentExists(a, root.path()));
}

test "SONNY-6636 (1): a damaged restore intent refuses the open instead of guessing which graph directories are live" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6636-damaged");
    defer root.remove();
    try addNodes(a, root.path(), null, "g", OLD, 2);
    const p = try std.fmt.allocPrint(a, "{s}/graph_restore.intent", .{root.path()});
    defer a.free(p);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "GEODRIN2 not a restore intent" });
    try testing.expectError(error.CorruptGraphRestoreIntent, open(a, root.path(), null));
    // The graphs are untouched: removing the damaged file opens them.
    try std.Io.Dir.cwd().deleteFile(io, p);
    const ad = try open(a, root.path(), null);
    defer ad.deinit();
    try testing.expectEqual(@as(usize, 2), try count(a, ad, "g", OLD));
}
