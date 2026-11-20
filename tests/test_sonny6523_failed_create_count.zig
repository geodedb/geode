// SONNY-6523 (2): a node create that fails after the engine allocated its
// slot leaves the store as it was.
//
// `StorageAdapter.createNode`, `bulkInsertNodeWithReservedIdGraphLocked` and
// `createNodesBatch` allocate the slot first (`GraphEngine.allocNode`: the
// shard manifest's live-node count goes up by one), then write the record,
// its labels and properties in an engine transaction. On an error they
// aborted the transaction and returned, and the allocation stayed: an abort
// discards the transaction's WAL records but neither returns the slot nor
// restores the pages it wrote. The count stayed one ahead of the records
// (or a half-written record, with no geode node over it, stayed in the
// page and was flushed by the next checkpoint).
//
// The failure is a real one: a node with a label never seen before makes
// graph-storage write the shard's label dictionary durably
// (`getOrAssignLabel`, SONNY-6491), and a directory at every shard's
// `labels.dict.tmp` makes that write fail (EISDIR). Each create path is
// driven through it, then the obstruction is removed, the store is closed
// cleanly (a checkpoint persists the counts) and reopened. The live-count
// check (`scanAllNodes`, REQ-GQL-028) must pass, every node read back must
// be one that was created, and new creates must work.
//
// CANARY: REQ=REQ-SONNY-6523-FAILED-CREATE-COUNT; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6523_failed_create_count.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const query_arena = geode.query_arena;

const G = "g6523fc";
const SEED: usize = 24;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Put (or remove) a directory at `labels.dict.tmp` beside every shard's
/// `labels.dict`. Returns how many.
fn obstructLabelDict(allocator: std.mem.Allocator, data_dir: []const u8, on: bool) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io(), data_dir, .{ .iterate = true });
    defer dir.close(io());
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    {
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io())) |entry| {
            if (on and entry.kind == .file and std.mem.eql(u8, entry.basename, "labels.dict")) {
                try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}.tmp", .{ data_dir, entry.path }));
            }
            if (!on and entry.kind == .directory and std.mem.eql(u8, entry.basename, "labels.dict.tmp")) {
                try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, entry.path }));
            }
        }
    }
    for (paths.items) |p| {
        if (on) try std.Io.Dir.cwd().createDirPath(io(), p) else try std.Io.Dir.cwd().deleteTree(io(), p);
    }
    return paths.items.len;
}

/// Every live node record of G (the live-count check runs in the scan).
fn scanCount(allocator: std.mem.Allocator) !usize {
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const entries = try adapter.scanAllNodes(G, allocator);
    defer allocator.free(entries);
    return entries.len;
}

fn queryCount(allocator: std.mem.Allocator, session: *execution.SessionState, q: []const u8) !i64 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const prev_scratch = query_arena.pushScratchAllocator(scratch.allocator());
    defer query_arena.popScratchAllocator(prev_scratch);
    var parsed = try geode.parseGql(q, allocator);
    defer parsed.deinit();
    const catalog = try execution.ensureCatalogInstance(allocator);
    var result = try execution.executeProgramWithContext(allocator, &parsed.program, .{ .catalog = catalog, .session_state = session });
    defer result.deinit(allocator);
    if (result.rows.len != 1 or result.rows[0].len != 1) return error.UnexpectedRows;
    return switch (result.rows[0][0]) {
        .Int => |v| v,
        else => error.UnexpectedValue,
    };
}

fn runQuery(allocator: std.mem.Allocator, session: *execution.SessionState, q: []const u8) !void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const prev_scratch = query_arena.pushScratchAllocator(scratch.allocator());
    defer query_arena.popScratchAllocator(prev_scratch);
    var parsed = try geode.parseGql(q, allocator);
    defer parsed.deinit();
    const catalog = try execution.ensureCatalogInstance(allocator);
    var result = try execution.executeProgramWithContext(allocator, &parsed.program, .{ .catalog = catalog, .session_state = session });
    result.deinit(allocator);
}

const Path = enum { create_node, bulk_reserved_id, nodes_batch, statement };

fn failOnce(allocator: std.mem.Allocator, session: *execution.SessionState, store: *graph_store.GraphStore, path: Path, label: []const u8) !void {
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const labels = [_][]const u8{label};
    const r: anyerror!void = switch (path) {
        .create_node => if (store.createNodeWithGraph(&labels, G)) |_| {} else |e| e,
        .bulk_reserved_id => if (adapter.bulkInsertNodeWithReservedId(G, store.reserveNodeId(), &labels, &.{})) |_| {} else |e| e,
        .nodes_batch => if (store.createNodesBatch(&labels, G, 3)) |ids| store.allocator.free(ids) else |e| e,
        .statement => blk: {
            var qb: [160]u8 = undefined;
            // A node with a known label first, in the same statement.
            break :blk runQuery(allocator, session, try std.fmt.bufPrint(&qb, "USE GRAPH {s}; CREATE (:A {{k: 1}}), (:{s} {{k: 2}})", .{ G, label }));
        },
    };
    if (r) |_| {
        std.debug.print("{s}: the create with the label dictionary obstructed succeeded\n", .{@tagName(path)});
        return error.InjectionDidNotFail;
    } else |err| {
        std.debug.print("SONNY-6523 (2) {s}: create failed as injected: {s}\n", .{ @tagName(path), @errorName(err) });
    }
}

test "SONNY-6523 (2): a create that fails after its slot was allocated leaves the count and the records as they were" {
    const allocator = std.testing.allocator;
    var failures: usize = 0;
    for ([_]Path{ .create_node, .bulk_reserved_id, .nodes_batch, .statement }) |path| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        defer allocator.free(data_dir);
        defer graph_store.setDataDirOverride(allocator, null);

        {
            const store = try graph_store.initGlobalStore(allocator, data_dir);
            defer graph_store.deinitGlobalStore();
            defer execution.cleanupCatalogInstance();
            var session = execution.SessionState.init(allocator);
            defer session.deinit();
            try store.createGraph(G);
            const labels = [_][]const u8{"A"};
            for (0..SEED) |_| _ = try store.createNodeWithGraph(&labels, G);

            try std.testing.expect(try obstructLabelDict(allocator, data_dir, true) > 0);
            try failOnce(allocator, &session, store, path, "Fresh");
            _ = try obstructLabelDict(allocator, data_dir, false);

            const live = scanCount(allocator) catch |err| {
                std.debug.print("SONNY-6523 (2) {s}: after the failed create the scan fails: {s}\n", .{ @tagName(path), @errorName(err) });
                failures += 1;
                continue;
            };
            if (live != SEED) {
                std.debug.print("SONNY-6523 (2) {s}: {d} live node records after the failed create, want {d}\n", .{ @tagName(path), live, SEED });
                failures += 1;
            }
            // New creates work, the label included.
            _ = try store.createNodeWithGraph(&labels, G);
            const fresh = [_][]const u8{"Fresh"};
            _ = try store.createNodeWithGraph(&fresh, G);
        }

        // Clean close (a checkpoint persisted the counts), reopen.
        {
            const store = try graph_store.initGlobalStore(allocator, data_dir);
            defer graph_store.deinitGlobalStore();
            defer execution.cleanupCatalogInstance();
            try store.loadFromFile();
            var session = execution.SessionState.init(allocator);
            defer session.deinit();
            const want: usize = SEED + 2;
            const live = scanCount(allocator) catch |err| {
                std.debug.print("SONNY-6523 (2) {s}: after the restart the scan fails: {s}\n", .{ @tagName(path), @errorName(err) });
                failures += 1;
                continue;
            };
            var qb: [96]u8 = undefined;
            const unlabeled = queryCount(allocator, &session, try std.fmt.bufPrint(&qb, "USE GRAPH {s}; MATCH (n) RETURN count(n) AS c", .{G})) catch |err| blk: {
                std.debug.print("SONNY-6523 (2) {s}: after the restart count(n) fails: {s}\n", .{ @tagName(path), @errorName(err) });
                failures += 1;
                break :blk -1;
            };
            std.debug.print("SONNY-6523 (2) {s}: after the restart {d} live records, count(n) {d}; want {d}\n", .{ @tagName(path), live, unlabeled, want });
            if (live != want or unlabeled != @as(i64, @intCast(want))) failures += 1;
        }
    }
    if (failures > 0) return error.FailedCreateLeftStoreChanged;
}
