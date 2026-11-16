// SONNY-6636 (1): a crash-safe swap of whole graphs into a data directory,
// the storage half of restoring a Raft snapshot into the durable store.
//
// A follower could not restore a snapshot into the durable store
// (`RaftSnapshotRestoreNotDurable`): nothing could replace a graph's files
// while the server ran, nor survive a crash in the middle. The adapter keeps
// each graph under `<data_dir>/<uuid>` and maps names to uuids in the graph
// registry, so a restore writes each graph into a new uuid directory and
// commits with one registry rewrite (`StorageAdapter.beginGraphRestore`,
// `commitGraphRestore`, `finishGraphRestore`). A fsynced intent
// (`graph_restore.intent`) names every directory involved; the next open
// deletes the ones the registry does not name.
//
// Each case stops the swap where a crash would (after the intent, after the
// staged files, after the registry commit, after the old directories are
// deleted), reopens the data directory and checks that it holds exactly the
// old graph or exactly the restored one, no intent, no directory the
// registry does not name, and the graph the restore did not touch.
//
// CANARY: REQ=REQ-SONNY-6636-CRASH-SAFE-GRAPH-SWAP; FEATURE="Raft Snapshot Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6636_graph_restore_swap.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const test_scratch = @import("test_scratch.zig");

const adapter_mod = geode.graph_storage_adapter;
const StorageAdapter = adapter_mod.StorageAdapter;
const testing = std.testing;
const io = std.Io.Threaded.global_single_threaded.io();

const OLD = "Old6636";
const NEW = "New6636";
const KEEP = "Keep6636";

fn open(a: std.mem.Allocator, dir: []const u8) !*StorageAdapter {
    return StorageAdapter.init(a, dir, .{ .data_dir = dir, .encryption_key = null });
}

fn count(a: std.mem.Allocator, ad: *StorageAdapter, graph: []const u8, label: []const u8) !usize {
    const ids = try ad.getNodesByLabel(graph, label, a);
    defer a.free(ids);
    return ids.len;
}

/// `dir`: graph "g" with two OLD nodes, graph "h" with one KEEP node.
fn seedTarget(a: std.mem.Allocator, dir: []const u8) !void {
    const ad = try open(a, dir);
    defer ad.deinit();
    _ = try ad.createGraph("g");
    _ = try ad.createGraph("h");
    for (0..2) |_| _ = try ad.createNode("g", &.{OLD});
    _ = try ad.createNode("h", &.{KEEP});
    try ad.checkpointAll();
}

/// `dir`: graph "g" with three NEW nodes, closed; returns its directory.
fn seedSource(a: std.mem.Allocator, dir: []const u8) ![]u8 {
    const ad = try open(a, dir);
    defer ad.deinit();
    _ = try ad.createGraph("g");
    for (0..3) |_| _ = try ad.createNode("g", &.{NEW});
    try ad.checkpointAll();
    const hex = std.fmt.bytesToHex(ad.registry.findByName("g").?.uuid, .lower);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, &hex });
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

/// Every `<uuid>` directory in `dir` is one the registry names.
fn expectNoOrphanGraphDirs(ad: *StorageAdapter, dir: []const u8) !void {
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    var graph_dirs: usize = 0;
    while (try it.next(io)) |e| {
        if (e.kind != .directory or e.name.len != 32) continue;
        var u: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&u, e.name) catch continue;
        graph_dirs += 1;
        if (ad.registry.findByUuid(u) == null) {
            std.debug.print("SONNY-6636 (1): graph directory {s} is named by no registry entry\n", .{e.name});
            return error.OrphanGraphDirectory;
        }
    }
    try testing.expectEqual(ad.registry.entries.items.len, graph_dirs);
}

const Stop = enum { none, intent_written, staged, committed, old_deleted };

fn runCase(stop: Stop) !void {
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6636-swap");
    defer root.remove();
    const target = try std.fmt.allocPrint(a, "{s}/target", .{root.path()});
    defer a.free(target);
    const source = try std.fmt.allocPrint(a, "{s}/source", .{root.path()});
    defer a.free(source);
    try seedTarget(a, target);
    const src_graph = try seedSource(a, source);
    defer a.free(src_graph);

    adapter_mod.setGraphRestoreCrashForTesting(switch (stop) {
        .intent_written => .intent_written,
        .committed => .committed,
        .old_deleted => .old_deleted,
        .none, .staged => null,
    });
    defer adapter_mod.setGraphRestoreCrashForTesting(null);
    {
        const ad = try open(a, target);
        defer ad.deinit();
        // The old graph is open (and pinned by nothing) when the swap runs.
        try testing.expectEqual(@as(usize, 2), try count(a, ad, "g", OLD));
        run: {
            var r = ad.beginGraphRestore(&.{"g"}) catch |err| {
                try testing.expect(stop == .intent_written);
                try testing.expectEqual(error.InjectedGraphRestoreCrash, err);
                break :run;
            };
            defer r.deinit();
            try copyTree(a, src_graph, r.staged_dirs[0]);
            if (stop == .staged) break :run; // a crash before the commit
            ad.commitGraphRestore(&r) catch |err| {
                try testing.expect(stop == .committed);
                try testing.expectEqual(error.InjectedGraphRestoreCrash, err);
                break :run;
            };
            ad.finishGraphRestore(&r);
            if (stop == .none) {
                // The running adapter serves the restored graph at once.
                try testing.expectEqual(@as(usize, 3), try count(a, ad, "g", NEW));
                try testing.expectEqual(@as(usize, 0), try count(a, ad, "g", OLD));
                try testing.expect(!try intentExists(a, target));
            }
        }
    }
    adapter_mod.setGraphRestoreCrashForTesting(null);
    // A stopped swap left its intent for the reopen to act on.
    try testing.expectEqual(stop != .none, try intentExists(a, target));

    // Reopened, as after the crash.
    const ad = try open(a, target);
    defer ad.deinit();
    const restored = switch (stop) {
        .intent_written, .staged => false,
        .committed, .old_deleted, .none => true,
    };
    const new_n = try count(a, ad, "g", NEW);
    const old_n = try count(a, ad, "g", OLD);
    std.debug.print("SONNY-6636 (1) swap stopped at {s}: reopened with g = {d} restored, {d} old nodes; h kept {d}; intent left={}\n", .{
        @tagName(stop), new_n, old_n, try count(a, ad, "h", KEEP), try intentExists(a, target),
    });
    try testing.expectEqual(@as(usize, if (restored) 3 else 0), new_n);
    try testing.expectEqual(@as(usize, if (restored) 0 else 2), old_n);
    try testing.expectEqual(@as(usize, 1), try count(a, ad, "h", KEEP));
    try testing.expect(!try intentExists(a, target));
    try expectNoOrphanGraphDirs(ad, target);
}

test "SONNY-6636 (1): a graph restore swap completes, and the running adapter serves the restored graph" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    try runCase(.none);
}

test "SONNY-6636 (1): a crash after the restore intent is written reopens on the old graph" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    try runCase(.intent_written);
}

test "SONNY-6636 (1): a crash after the graph is staged, before the commit, reopens on the old graph" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    try runCase(.staged);
}

test "SONNY-6636 (1): a crash right after the registry commit reopens on the restored graph" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    try runCase(.committed);
}

test "SONNY-6636 (1): a crash after the old directory is deleted, before the intent is removed, reopens on the restored graph" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    try runCase(.old_deleted);
}

test "SONNY-6636 (1): a graph created under a restored name after the restore began refuses the commit, changing nothing" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6636-raced");
    defer root.remove();
    const ad = try open(a, root.path());
    defer ad.deinit();
    var r = try ad.beginGraphRestore(&.{"fresh6636"});
    defer r.deinit();
    _ = try ad.createGraph("fresh6636");
    _ = try ad.createNode("fresh6636", &.{KEEP});
    try testing.expectError(error.GraphRestoreRaced, ad.commitGraphRestore(&r));
    ad.abandonGraphRestore(&r);
    try testing.expectEqual(@as(usize, 1), try count(a, ad, "fresh6636", KEEP));
    try testing.expect(!try intentExists(a, root.path()));
    try expectNoOrphanGraphDirs(ad, root.path());
}

test "SONNY-6636 (1): a damaged restore intent refuses the open instead of guessing which graph directories are live" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6636-damaged");
    defer root.remove();
    try seedTarget(a, root.path());
    const p = try std.fmt.allocPrint(a, "{s}/graph_restore.intent", .{root.path()});
    defer a.free(p);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "GEODRIN1 not a restore intent" });
    try testing.expectError(error.CorruptGraphRestoreIntent, open(a, root.path()));
    // The graphs are untouched: removing the damaged file opens them.
    try std.Io.Dir.cwd().deleteFile(io, p);
    const ad = try open(a, root.path());
    defer ad.deinit();
    try testing.expectEqual(@as(usize, 2), try count(a, ad, "g", OLD));
}

test "SONNY-6636 (1): under at-rest encryption a graph restore is refused before anything is written" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6636-tde");
    defer root.remove();
    const ad = try StorageAdapter.init(a, root.path(), .{ .data_dir = root.path(), .encryption_key = [_]u8{0x36} ** 32 });
    defer ad.deinit();
    try testing.expectError(error.GraphRestoreUnderTdeNotSupported, ad.beginGraphRestore(&.{"g"}));
    try testing.expect(!try intentExists(a, root.path()));
}
