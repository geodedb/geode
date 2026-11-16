// SONNY-6642: a graph whose write-ahead log is damaged in the middle (a bad
// record with valid records after it) is refused as `WalCorrupted`, with an
// operator message; it was the generic `GraphQuarantined`.
//
// graph-storage >= 0.4.20 (wal >= 0.1.24) no longer truncates a log it cannot
// read: a corrupt record followed by valid ones is not a torn tail, so the
// open fails with `WalCorrupted` and leaves the file as it is. Geode
// quarantined the graph with the cause `unknown` (`QuarantineCause.of` did
// not list the error), so every statement on it answered 58000
// "GraphQuarantined: the graph's indexes could not be loaded ..." and never
// said the log was damaged or what to do.
//
// A real `geode serve` writes to a graph and is killed (SIGKILL: no shutdown,
// no checkpoint), so the graph's shard logs still hold the records. One
// record in the middle of the longest log has a payload byte flipped (its
// CRC fails; the records after it are intact). The restarted server must
// refuse the graph with 58000 `WalCorrupted` and serve every other graph.
//
// CANARY: REQ=REQ-SONNY-6642-WAL-CORRUPTED-QUARANTINE; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6642_wal_corrupted_quarantine.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const QuicServer = struct {
    handle: util.ServerHandle,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8) !QuicServer {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var handle = try util.spawnServer(
            allocator,
            // No persistence tick (so no checkpoint) before the kill.
            &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir, "--persist-interval", "86400000" },
            null,
        );
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .handle = handle, .addr = addr };
    }

    /// SIGKILL: no clean shutdown, no checkpoint.
    fn kill(self: *QuicServer, allocator: std.mem.Allocator) void {
        self.handle.deinit();
        allocator.free(self.addr);
    }

    fn connect(self: *QuicServer, allocator: std.mem.Allocator) !util.QuicProtoClient {
        var client = try util.QuicProtoClient.connect(allocator, self.addr);
        errdefer client.deinit();
        client.watchServerLiveness(self.handle.child.id orelse return error.NoServerPid);
        var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(allocator);
        if (!h.success) return error.HelloFailed;
        return client;
    }
};

fn quicOk(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !void {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
}

/// The top-level directories of `data_dir` (one per graph, among others).
fn topDirs(allocator: std.mem.Allocator, data_dir: []const u8) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |n| allocator.free(n);
        out.deinit(allocator);
    }
    var dir = try std.Io.Dir.cwd().openDir(io(), data_dir, .{ .iterate = true });
    defer dir.close(io());
    var it = dir.iterate();
    while (try it.next(io())) |entry| {
        if (entry.kind != .directory) continue;
        try out.append(allocator, try allocator.dupe(u8, entry.name));
    }
    return out;
}

fn freeNames(allocator: std.mem.Allocator, names: *std.ArrayList([]u8)) void {
    for (names.items) |n| allocator.free(n);
    names.deinit(allocator);
}

fn contains(names: []const []u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

const Record = struct { off: usize, payload_len: usize };

/// The plaintext wal record framing: [lsn u64][payload_len u32][payload][crc u32].
fn records(allocator: std.mem.Allocator, bytes: []const u8) !std.ArrayList(Record) {
    var out: std.ArrayList(Record) = .empty;
    errdefer out.deinit(allocator);
    var off: usize = 0;
    while (off + 16 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[off + 8 ..][0..4], .little);
        if (off + 16 + len > bytes.len) break;
        try out.append(allocator, .{ .off = off, .payload_len = len });
        off += 16 + len;
    }
    return out;
}

/// Flip one payload byte of the middle record of the longest shard log under
/// `graph_dir` (`graphs/<shard>/wal/graph.wal`). Returns that log's path.
fn damageMiddleRecord(allocator: std.mem.Allocator, graph_dir: []const u8) ![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io(), graph_dir, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var best: ?[]u8 = null;
    errdefer if (best) |b| allocator.free(b);
    var best_records: usize = 0;
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, "graph.wal")) continue;
        const path = try std.fs.path.join(allocator, &.{ graph_dir, entry.path });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io(), path, allocator, .limited(64 << 20)) catch |err| {
            allocator.free(path);
            return err;
        };
        defer allocator.free(bytes);
        var recs = try records(allocator, bytes);
        defer recs.deinit(allocator);
        if (recs.items.len > best_records) {
            if (best) |b| allocator.free(b);
            best = path;
            best_records = recs.items.len;
        } else allocator.free(path);
    }
    const path = best orelse return error.NoGraphWal;
    // A middle record needs valid records on both sides.
    if (best_records < 3) return error.GraphWalTooShort;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io(), path, allocator, .limited(64 << 20));
    defer allocator.free(bytes);
    var recs = try records(allocator, bytes);
    defer recs.deinit(allocator);
    const mid = recs.items[recs.items.len / 2];
    if (mid.payload_len == 0) return error.EmptyMiddleRecord;
    bytes[mid.off + 12 + mid.payload_len / 2] ^= 0xFF;
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = path, .data = bytes });
    return path;
}

test "SONNY-6642: WalCorrupted answers 58000 with its own operator message" {
    const info = geode.proto_util.mapError(error.WalCorrupted);
    try testing.expectEqualStrings("58000", info.code);
    try testing.expect(std.mem.startsWith(u8, info.message, "WalCorrupted: "));
    try testing.expect(geode.proto_util.statementErrorInfo(error.WalCorrupted) != null);
}

test "SONNY-6642: a graph whose WAL is damaged mid-log is refused as WalCorrupted after a crash, other graphs serve" {
    const allocator = testing.allocator;
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny6642-{d}", .{try util.getRandomPort()});
    std.Io.Dir.cwd().createDirPath(io(), data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io(), data_dir) catch {};

    var before = blk: {
        var server = try QuicServer.start(allocator, data_dir);
        defer server.kill(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        try quicOk(&client, allocator, "CREATE GRAPH other6642");
        try quicOk(&client, allocator, "USE GRAPH other6642");
        try quicOk(&client, allocator, "CREATE (:O6642 {i: 1})");
        var names = try topDirs(allocator, data_dir);
        errdefer freeNames(allocator, &names);
        try quicOk(&client, allocator, "CREATE GRAPH w6642");
        try quicOk(&client, allocator, "USE GRAPH w6642");
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            try quicOk(&client, allocator, "UNWIND range(1, 48) AS i CREATE (:W6642 {i: i, s: 'payload-6642'})");
        }
        break :blk names;
    };
    defer freeNames(allocator, &before);

    // Killed: the graph's logs hold every record. Damage one mid-log.
    var after = try topDirs(allocator, data_dir);
    defer freeNames(allocator, &after);
    var damaged: ?[]u8 = null;
    defer if (damaged) |d| allocator.free(d);
    for (after.items) |name| {
        if (contains(before.items, name)) continue;
        const graph_dir = try std.fs.path.join(allocator, &.{ data_dir, name });
        defer allocator.free(graph_dir);
        damaged = damageMiddleRecord(allocator, graph_dir) catch |err| switch (err) {
            error.FileNotFound, error.NoGraphWal => continue,
            else => return err,
        };
        break;
    }
    if (damaged == null) return error.GraphDirectoryNotFound;

    var server = try QuicServer.start(allocator, data_dir);
    defer server.kill(allocator);
    var client = try server.connect(allocator);
    defer client.deinit();

    // The other graph is unaffected.
    try quicOk(&client, allocator, "USE GRAPH other6642");
    try quicOk(&client, allocator, "MATCH (n:O6642) RETURN count(n) AS c");

    var code: ?[]const u8 = null;
    var message: []const u8 = "";
    var r_use = try client.executeAndCollect(allocator, "USE GRAPH w6642", util.emptyParams(), 1000);
    defer r_use.deinit(allocator);
    var r = try client.executeAndCollect(allocator, "MATCH (n:W6642) RETURN count(n) AS c", util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r_use.error_code) |c| {
        code = c;
        message = r_use.error_message orelse "";
    } else if (r.error_code) |c| {
        code = c;
        message = r.error_message orelse "";
    }
    std.debug.print("SONNY-6642: damaged {s}; the graph answered {s} {s}\n", .{ damaged.?, code orelse "OK", message });
    try testing.expectEqualStrings("58000", code orelse return error.DamagedGraphServed);
    try testing.expect(std.mem.startsWith(u8, message, "WalCorrupted: "));
}
