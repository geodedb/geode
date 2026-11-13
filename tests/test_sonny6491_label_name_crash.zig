// SONNY-6491 regression: label names assigned since the last checkpoint
// survive a SIGKILL.
//
// A label or relationship type is stored in records as a numeric id; the name
// lives only in each shard's `labels.dict`, which is not in the WAL. Before
// graph_storage 0.4.14 the engine wrote `labels.dict` only at a checkpoint, so
// a crash lost every name assigned since then: recovery replayed the records
// from the WAL but `MATCH (n:L)` found nothing and `db.labels()` did not list
// `L`. graph_storage 0.4.14 makes a new name durable (fsync, rename, directory
// fsync) before `getOrAssignLabel` returns its id. geode also rewrites the
// shards' dictionaries on first sight of a name (GAP-0915,
// `resolvePersistedLabelId`); this test holds the combined contract.
//
// Every label-creating write shape runs against a real `geode serve` with
// checkpoints disabled: a CREATE with one new label, with two, a single
// CREATE introducing many, the single-MERGE fast path, a `/*+BATCH*/`
// bulk-MERGE program, `SET n:L`, a CREATE inside an explicit transaction and a
// new relationship type. The server is killed (SIGKILL: no shutdown, no
// checkpoint), restarted on the same data directory, and every name is
// counted by label and looked up in `db.labels()`.
//
// CANARY: REQ=REQ-SONNY-6491-LABEL-NAME-CRASH; FEATURE="CrashRecovery"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6491_label_name_crash.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

/// Labels one CREATE introduces in the many-labels case.
const n_batch_labels = 12;

const QuicServer = struct {
    handle: util.ServerHandle,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8, env: []const []const u8) !QuicServer {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var handle = try util.spawnServer(
            allocator,
            &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir },
            env,
        );
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .handle = handle, .addr = addr };
    }

    /// SIGKILL (the harness's teardown): no clean shutdown, no checkpoint.
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

fn quicCount(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !i64 {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
    if (r.rows.len != 1) return error.UnexpectedRows;
    return switch (r.rows[0][0]) {
        .int => |v| v,
        else => error.UnexpectedValue,
    };
}

/// A name the writes introduce and how many records must carry it.
const Expect = struct {
    name: []const u8,
    count: i64,
    /// A relationship type (counted over relationships, not in db.labels()).
    rel: bool = false,
};

const batch_names = blk: {
    var out: [n_batch_labels][]const u8 = undefined;
    for (0..n_batch_labels) |i| out[i] = std.fmt.comptimePrint("L6491batch{d}", .{i});
    break :blk out;
};

const expects = [_]Expect{
    .{ .name = "L6491create", .count = 2 },
    .{ .name = "L6491multiA", .count = 1 },
    .{ .name = "L6491multiB", .count = 1 },
    .{ .name = "L6491merge", .count = 1 },
    .{ .name = "L6491bulk", .count = 3 },
    .{ .name = "L6491anchor", .count = 1 },
    .{ .name = "L6491setlabel", .count = 1 },
    .{ .name = "L6491txn", .count = 2 },
    .{ .name = "L6491relsrc", .count = 1 },
    .{ .name = "L6491reldst", .count = 1 },
    .{ .name = "L6491reltype", .count = 1, .rel = true },
} ++ blk: {
    var out: [n_batch_labels]Expect = undefined;
    for (batch_names, 0..) |n, i| out[i] = .{ .name = n, .count = 1 };
    break :blk out;
};

/// Node records the writes create (an unlabeled count separates a lost record
/// from a lost name).
const total_nodes: i64 = 2 + 1 + 1 + 3 + 1 + 2 + 2 + n_batch_labels;

fn writeAll(client: *util.QuicProtoClient, allocator: std.mem.Allocator) !void {
    // A new label on the single-node CREATE path, then a second node of it.
    try quicOk(client, allocator, "CREATE (:L6491create {k: 1})");
    try quicOk(client, allocator, "CREATE (:L6491create {k: 2})");
    // Two new labels on one node.
    try quicOk(client, allocator, "CREATE (:L6491multiA:L6491multiB {k: 1})");
    // Many new labels in one statement (bulk ingest of a new schema).
    {
        var s: std.ArrayList(u8) = .empty;
        defer s.deinit(allocator);
        try s.appendSlice(allocator, "CREATE ");
        for (batch_names, 0..) |n, i| {
            try s.print(allocator, "(:{s} {{k: {d}}})", .{ n, i });
            if (i + 1 < batch_names.len) try s.appendSlice(allocator, ", ");
        }
        try quicOk(client, allocator, s.items);
    }
    // The single-MERGE fast path, and a /*+BATCH*/ bulk-MERGE program.
    try quicOk(client, allocator, "MERGE (:L6491merge {k: 1})");
    try quicOk(client, allocator, "/*+BATCH*/ MERGE (:L6491bulk {k: 1}); MERGE (:L6491bulk {k: 2}); MERGE (:L6491bulk {k: 3})");
    // A new label added to an existing node.
    try quicOk(client, allocator, "CREATE (:L6491anchor {k: 1})");
    try quicOk(client, allocator, "MATCH (n:L6491anchor) SET n:L6491setlabel");
    // A new label first seen inside an explicit transaction.
    try quicOk(client, allocator, "START TRANSACTION; CREATE (:L6491txn {k: 1}); CREATE (:L6491txn {k: 2}); COMMIT");
    // A new relationship type (and two new endpoint labels).
    try quicOk(client, allocator, "CREATE (:L6491relsrc {k: 1})-[:L6491reltype]->(:L6491reldst {k: 1})");
}

fn countName(client: *util.QuicProtoClient, allocator: std.mem.Allocator, e: Expect) !i64 {
    var qb: [160]u8 = undefined;
    const q = if (e.rel)
        try std.fmt.bufPrint(&qb, "MATCH ()-[r:{s}]->() RETURN count(r) AS c", .{e.name})
    else
        try std.fmt.bufPrint(&qb, "MATCH (n:{s}) RETURN count(n) AS c", .{e.name});
    return quicCount(client, allocator, q);
}

/// The names `CALL db.labels()` lists, owned by the caller.
fn dbLabels(client: *util.QuicProtoClient, allocator: std.mem.Allocator) !std.ArrayList([]u8) {
    var r = try client.executeAndCollect(allocator, "CALL db.labels() YIELD label RETURN label", util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("db.labels(): {s} {s}\n", .{ code, r.error_message orelse "" });
        return error.QueryFailed;
    }
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    for (r.rows) |row| switch (row[0]) {
        .string => |s| try out.append(allocator, try allocator.dupe(u8, s)),
        else => return error.UnexpectedValue,
    };
    return out;
}

fn listed(names: []const []u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

const Observed = struct {
    counts: [expects.len]i64,
    in_db_labels: [expects.len]bool,
    unlabeled: i64,
};

fn observe(client: *util.QuicProtoClient, allocator: std.mem.Allocator) !Observed {
    var o: Observed = undefined;
    for (expects, 0..) |e, i| o.counts[i] = try countName(client, allocator, e);
    var names = try dbLabels(client, allocator);
    defer {
        for (names.items) |s| allocator.free(s);
        names.deinit(allocator);
    }
    for (expects, 0..) |e, i| o.in_db_labels[i] = e.rel or listed(names.items, e.name);
    o.unlabeled = try quicCount(client, allocator, "MATCH (n) RETURN count(n) AS c");
    return o;
}

test "SONNY-6491: label names assigned since the last checkpoint survive a kill" {
    const allocator = testing.allocator;
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny6491-{d}", .{try util.getRandomPort()});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    // No checkpoint before the kill: a checkpoint used to write labels.dict
    // and would hide a name that was never made durable when assigned.
    const env: []const []const u8 = &.{ "GEODE_CHECKPOINT_INTERVAL_MS=86400000", "GEODE_CHECKPOINT_OPS=1000000000" };

    var before: Observed = undefined;
    {
        var server = try QuicServer.start(allocator, data_dir, env);
        defer server.kill(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        try quicOk(&client, allocator, "CREATE GRAPH s6491");
        try quicOk(&client, allocator, "USE GRAPH s6491");
        try writeAll(&client, allocator);
        before = try observe(&client, allocator);
    }

    // Killed (SIGKILL); restarted on the same data directory.
    var server = try QuicServer.start(allocator, data_dir, env);
    defer server.kill(allocator);
    var client = try server.connect(allocator);
    defer client.deinit();
    try quicOk(&client, allocator, "USE GRAPH s6491");
    const after = try observe(&client, allocator);

    var wrong: usize = 0;
    for (expects, 0..) |e, i| {
        const ok = before.counts[i] == e.count and after.counts[i] == e.count and
            before.in_db_labels[i] and after.in_db_labels[i];
        std.debug.print("SONNY-6491 {s:<14} {s}: {d} before the kill, {d} after it, want {d}; db.labels() {s}/{s}{s}\n", .{
            e.name,
            if (e.rel) "rel " else "node",
            before.counts[i],
            after.counts[i],
            e.count,
            if (e.rel) "n/a" else if (before.in_db_labels[i]) "listed" else "MISSING",
            if (e.rel) "n/a" else if (after.in_db_labels[i]) "listed" else "MISSING",
            if (ok) "" else "  <-- WRONG",
        });
        if (!ok) wrong += 1;
    }
    std.debug.print("SONNY-6491 unlabeled MATCH (n): {d} before the kill, {d} after it, want {d}\n", .{ before.unlabeled, after.unlabeled, total_nodes });
    if (before.unlabeled != total_nodes or after.unlabeled != total_nodes) wrong += 1;
    if (wrong > 0) return error.LabelNameLostByTheKill;
}
