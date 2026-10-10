// SONNY-3131 regression: a checkpoint of a graph dropped while it waited
// does not write the graph back into the registry, and one registry entry
// whose files are gone does not stop the registry from being saved.
//
// Since SONNY-3028 a graph-scoped checkpoint (`checkpointGraph`) pins its
// graph and returns success when the graph was dropped while it waited for
// the graph's lock. It then upserted the graph into the registry, with no
// `isDropped()` check (`checkpointAllEx` has one). The dropped graph's files
// are deleted, so from then on every registry save failed: the header's next
// ids are read from each unloaded entry's manifest
// (`refreshRegistryHeaderNextIdsLocked`), and that one's was gone. Each
// failure was only a warning. Review probes:
// - R12-X5b: after the race CREATE GRAPH gz answered 42P07 while the graph
//   was gone;
// - R12-X5c: a graph created after the race reported success, and it and its
//   data were gone after a restart.
//
// Now the checkpoint skips the registry for a dropped graph, and a registry
// save skips (and logs at error level) an entry whose manifest cannot be
// read, keeping the header's next ids from going down.
//
// CANARY: REQ=REQ-SONNY-3131-CHECKPOINT-DROPPED-GRAPH; FEATURE="MultiGraphIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3131_checkpoint_dropped_graph.zig; OWNER=storage; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;
const execution = geode.execution;
const txn_undo_log = geode.txn_undo_log;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;

/// A graph-scoped checkpoint of `graph` on its own thread.
const GraphCheckpoint = struct {
    graph: []const u8,
    started: std.atomic.Value(bool) = .init(false),
    err: ?anyerror = null,

    fn run(self: *GraphCheckpoint) void {
        const ad = graph_store.getGlobalAdapter().?;
        self.started.store(true, .release);
        ad.checkpointGraph(self.graph) catch |e| {
            self.err = e;
        };
    }
};

/// Hold `graph`'s write lock, start a checkpoint of it (which pins it and
/// waits for the lock), drop the graph under the lock as DROP GRAPH does, and
/// let go: the checkpoint finds its graph dropped.
fn checkpointRacingDrop(st: *graph_store.GraphStore, graph: []const u8) !void {
    const lock = graph_store.acquireGraphWriteLock(graph);
    var cp: GraphCheckpoint = .{ .graph = graph };
    const t = try std.Thread.spawn(.{}, GraphCheckpoint.run, .{&cp});
    while (!cp.started.load(.acquire)) fx.sleepMs(1);
    fx.sleepMs(100);
    st.dropGraph(graph) catch |err| {
        graph_store.releaseGraphLock(lock);
        t.join();
        return err;
    };
    graph_store.releaseGraphLock(lock);
    t.join();
}

test "SONNY-3131: a graph-scoped checkpoint of a graph dropped while it waited does not write it back into the registry; CREATE GRAPH of the name runs (R12-X5b)" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("x5b");
    try f.st.createGraph("gz");
    try fx.expectRuns(ga, s, "USE GRAPH gz; CREATE (:Z {v: 1})");
    try fx.expectRuns(ga, s, "USE GRAPH default");
    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;

    try checkpointRacingDrop(f.st, "gz");
    try testing.expect(!ad.graphExists("gz"));
    try testing.expect(!f.st.graphExists("gz"));

    // The name is free: CREATE GRAPH runs, and the new graph is empty.
    try fx.expectRuns(ga, s, "CREATE GRAPH gz");
    try fx.expectRuns(ga, s, "USE GRAPH gz");
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "gz", "Z"));
}

fn tmpDataDir(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return harness.tmpDirRealpathAlloc(allocator, &tmp.sub_path);
}

/// Open the global store on `data_dir` with a gRPC session store, run
/// `body`, and close the store, as a server start and stop do.
fn withStore(allocator: std.mem.Allocator, data_dir: []const u8, comptime body: anytype, args: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();
    txn_undo_log.deinitGlobalUndoLog();
    graph_store.setDataDirOverride(allocator, data_dir);
    const st = try graph_store.initGlobalStore(aa, data_dir);
    defer {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        txn_undo_log.deinitGlobalUndoLog();
    }
    _ = try execution.ensureCatalogInstance(aa);
    _ = txn_undo_log.getGlobalUndoLog(aa);
    var sessions = grpc.SessionStore.init(aa, .{});
    defer sessions.deinit();
    grpc.setSessionStore(&sessions);
    defer grpc.setSessionStore(null);
    const s = try sessions.createSession("x5c", "", null, null, null, false, 0);
    try @call(.auto, body, .{ aa, st, s } ++ args);
}

const AuthOff = struct {
    auth_was: bool,
    allow_was: bool,

    fn set() AuthOff {
        const a: AuthOff = .{ .auth_was = user_mgmt.isAuthEnabled(), .allow_was = gps.isInsecureAllowAll() };
        user_mgmt.setAuthEnabled(false);
        gps.setInsecureAllowAll(true);
        return a;
    }

    fn restore(self: AuthOff) void {
        user_mgmt.setAuthEnabled(self.auth_was);
        gps.setInsecureAllowAll(self.allow_was);
    }
};

fn x5cFirstRun(aa: std.mem.Allocator, st: *graph_store.GraphStore, s: []const u8) !void {
    try fx.expectRuns(aa, s, "CREATE GRAPH gz");
    try fx.expectRuns(aa, s, "USE GRAPH gz; CREATE (:Z {v: 1})");
    try fx.expectRuns(aa, s, "USE GRAPH default");
    try checkpointRacingDrop(st, "gz");
    // DROP GRAPH's catalog step (the race dropped through the store).
    const cat = try execution.ensureCatalogInstance(aa);
    try cat.removeGraph("gz");
    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    try testing.expect(!ad.graphExists("gz"));
    // Later DDL and data on another graph.
    try fx.expectRuns(aa, s, "CREATE GRAPH hx");
    try fx.expectRuns(aa, s, "USE GRAPH hx; CREATE (:H {v: 1})");
    try fx.expectRuns(aa, s, "USE GRAPH default");
}

fn expectHxAfterRestart(aa: std.mem.Allocator, st: *graph_store.GraphStore, s: []const u8) !void {
    _ = st;
    _ = s;
    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const hx = ad.graphExists("hx");
    const h_nodes: usize = if (ad.getNodesByLabelCapped("hx", "H", null, aa)) |ids| ids.len else |_| 0;
    std.debug.print("after restart: hx in the registry={} H nodes={d}; gz in the registry={}\n", .{ hx, h_nodes, ad.graphExists("gz") });
    try testing.expect(hx);
    try testing.expectEqual(@as(usize, 1), h_nodes);
    try testing.expect(!ad.graphExists("gz"));
}

test "SONNY-3131: after a checkpoint raced a DROP GRAPH, a graph created later, and its data, are still there after a restart (R12-X5c)" {
    const allocator = testing.allocator;
    harness.silenceEngineLogs();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);
    const auth = AuthOff.set();
    defer auth.restore();
    defer graph_store.setDataDirOverride(allocator, null);

    try withStore(allocator, data_dir, x5cFirstRun, .{});
    try withStore(allocator, data_dir, expectHxAfterRestart, .{});
}

fn graphDir(allocator: std.mem.Allocator, data_dir: []const u8, graph: []const u8) ![]u8 {
    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const uuid = ad.getGraphUuid(graph) orelse return error.GraphUuidUnavailable;
    const hex = std.fmt.bytesToHex(uuid, .lower);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, &hex });
}

/// Does the registry file on disk name `graph`?
fn registryFileNames(data_dir: []const u8, graph: []const u8) !bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/graph_registry.dat", .{data_dir});
    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(16 * 1024 * 1024));
    defer testing.allocator.free(bytes);
    return std.mem.indexOf(u8, bytes, graph) != null;
}

fn lostFirstRun(aa: std.mem.Allocator, st: *graph_store.GraphStore, s: []const u8, dir_out: *?[]u8, data_dir: []const u8) !void {
    _ = st;
    try fx.expectRuns(aa, s, "CREATE GRAPH gl3131");
    try fx.expectRuns(aa, s, "USE GRAPH gl3131; CREATE (:L {v: 1})");
    try fx.expectRuns(aa, s, "USE GRAPH default");
    dir_out.* = try graphDir(testing.allocator, data_dir, "gl3131");
}

fn lostSecondRun(aa: std.mem.Allocator, st: *graph_store.GraphStore, s: []const u8, data_dir: []const u8) !void {
    _ = st;
    // gl3131's files are gone: its entry is in the registry, and it is not
    // open. A graph created now is saved to the registry file.
    try fx.expectRuns(aa, s, "CREATE GRAPH hy3131");
    try fx.expectRuns(aa, s, "USE GRAPH hy3131; CREATE (:H {v: 1})");
    try fx.expectRuns(aa, s, "USE GRAPH default");
    const saved = try registryFileNames(data_dir, "hy3131");
    std.debug.print("registry file names hy3131={}\n", .{saved});
    try testing.expect(saved);
    // The lost graph's entries go, as DROP GRAPH's would, without opening it
    // (a shutdown checkpoint, or DROP GRAPH's lock, would try to open it and
    // log its missing files).
    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    try ad.dropGraph("gl3131");
    const cat = try execution.ensureCatalogInstance(aa);
    try cat.removeGraph("gl3131");
    try testing.expect(!try registryFileNames(data_dir, "gl3131"));
}

fn lostThirdRun(aa: std.mem.Allocator, st: *graph_store.GraphStore, s: []const u8) !void {
    _ = st;
    _ = s;
    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const hy = ad.graphExists("hy3131");
    const h_nodes: usize = if (ad.getNodesByLabelCapped("hy3131", "H", null, aa)) |ids| ids.len else |_| 0;
    std.debug.print("after restart: hy3131 in the registry={} H nodes={d}\n", .{ hy, h_nodes });
    try testing.expect(hy);
    try testing.expectEqual(@as(usize, 1), h_nodes);
    try testing.expect(!ad.graphExists("gl3131"));
}

test "SONNY-3131: a registry entry whose files are gone does not stop the registry from being saved: a graph created later is in the registry file, and survives a restart" {
    const allocator = testing.allocator;
    harness.silenceEngineLogs();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);
    const auth = AuthOff.set();
    defer auth.restore();
    defer graph_store.setDataDirOverride(allocator, null);

    var gl_dir: ?[]u8 = null;
    defer if (gl_dir) |d| allocator.free(d);
    try withStore(allocator, data_dir, lostFirstRun, .{ &gl_dir, data_dir });
    // The graph's files go while the server is down.
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().deleteTree(io, gl_dir.?);
    try withStore(allocator, data_dir, lostSecondRun, .{data_dir});
    try withStore(allocator, data_dir, lostThirdRun, .{});
}
