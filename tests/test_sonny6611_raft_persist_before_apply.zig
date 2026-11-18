// SONNY-6611 (7): a committed Raft entry is in durable storage before the
// state machine applies it.
//
// `RaftNode.drainReady` (src/distributed/raft_consensus.zig) ran the apply
// callback over `Ready.committed_entries` first and only then called the
// raft library's `advance()`, which writes the Ready's unstable entries and
// hard state to storage. A follower that receives an entry and its commit in
// one AppendEntries holds it only in the in-memory unstable log at that
// point, so geode applied a graph mutation whose log entry a crash a moment
// later would lose: the node restarts with the mutation in its graph store
// and no entry for it, and replays (or is sent) the entry again.
//
// SONNY-6592 (3): the follower's AppendEntries reply acknowledges the same
// entries (match_index); it must not reach the network before they are
// durable either.
//
// Drives the production wiring: `RaftNode.initWithStorageDir` (the raft
// library's FileStorage), `stepInner` -> `drainReady`, the apply callback,
// and `setTransport` with a test network (`send_override`). At the moment of
// apply and of send the test asks the node's own storage what it holds.
//
// CANARY: REQ=REQ-SONNY-6611-RAFT-PERSIST-BEFORE-APPLY; FEATURE="Raft Consensus Persistence"; ASPECT=EntriesDurableBeforeApplyAndReply; STATUS=TESTED; TEST=tests/test_sonny6611_raft_persist_before_apply.zig; OWNER=distributed; UPDATED=2026-11-15

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");

const raft_consensus = geode.distributed.raft_consensus;
const raft_lib = geode.distributed.raft;

const RaftNode = raft_consensus.RaftNode;
const Transport = raft_consensus.Transport;
const Peer = raft_consensus.Peer;
const Message = raft_consensus.Message;
const Command = raft_consensus.Command;

const io = std.Io.Threaded.global_single_threaded.io();

const payload = "sonny6611-committed-entry";

/// What the node's storage held for `index` when asked.
const Seen = struct {
    last_index: u64 = 0,
    data_matches: bool = false,
};

fn storageOf(node: *RaftNode) raft_lib.Storage {
    return switch (node.storage_backing) {
        inline else => |p| p.storage(),
    };
}

fn look(node: *RaftNode, index: u64) Seen {
    const s = storageOf(node);
    const last = s.lastIndex() catch 0;
    if (last < index) return .{ .last_index = last };
    const got = s.entries(index, index + 1) catch return .{ .last_index = last };
    defer {
        for (got) |e| if (e.data.len > 0) std.testing.allocator.free(e.data);
        if (got.len > 0) std.testing.allocator.free(got);
    }
    const want = raft_consensus.serializeCommand(std.testing.allocator, .{ .write = payload }) catch return .{ .last_index = last };
    defer std.testing.allocator.free(want);
    return .{ .last_index = last, .data_matches = got.len == 1 and std.mem.eql(u8, got[0].data, want) };
}

/// The apply callback has no context argument; the node under test.
var g_node: ?*RaftNode = null;
var g_applied: usize = 0;
var g_at_apply: Seen = .{};
var g_apply_index: u64 = 0;

fn apply(allocator: std.mem.Allocator, cmd: Command, raft_index: u64) anyerror![]u8 {
    if (cmd == .write and std.mem.eql(u8, cmd.write, payload)) {
        g_applied += 1;
        g_apply_index = raft_index;
        g_at_apply = look(g_node.?, raft_index);
    }
    return allocator.alloc(u8, 0);
}

const Network = struct {
    node: ?*RaftNode = null,
    replies: usize = 0,
    match_index: u64 = 0,
    at_reply: Seen = .{},

    fn send(t: *Transport, _: Peer, _: u64, _: u64, msg: Message) anyerror!void {
        const self: *Network = @ptrCast(@alignCast(t.send_override_ctx orelse return error.MissingCtx));
        switch (msg) {
            .append_entries_response => |r| if (r.success and r.match_index > 0) {
                self.replies += 1;
                self.match_index = r.match_index;
                self.at_reply = look(self.node.?, r.match_index);
            },
            else => {},
        }
    }
};

fn uniqueDir(allocator: std.mem.Allocator) ![]u8 {
    var rnd: [8]u8 = undefined;
    if (@import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(&rnd, rnd.len, 0);
    } else {
        std.c.arc4random_buf(&rnd, rnd.len);
    }
    return std.fmt.allocPrint(allocator, "/tmp/geode-sonny6611-{x}", .{std.mem.readInt(u64, &rnd, .little)});
}

/// Leader 2 sends follower 1 entry 1 (term 1) and commits it in the same
/// AppendEntries.
fn deliverCommittedEntry(node: *RaftNode) !void {
    const data = try raft_consensus.serializeCommand(std.testing.allocator, .{ .write = payload });
    defer std.testing.allocator.free(data);
    const entries = [_]raft_lib.Entry{.{ .index = 1, .term = 1, .kind = .normal, .data = data }};
    try node.stepInner(2, .{ .append_entries = .{
        .term = 1,
        .leader_id = 2,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &entries,
        .leader_commit = 1,
    } });
}

test "SONNY-6611 (7): a follower applies a committed entry only after it is in durable storage, and acknowledges it only then (SONNY-6592)" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const dir = try uniqueDir(a);
    defer a.free(dir);
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var peers = [_]Peer{
        .{ .id = 2, .endpoint = "127.0.0.1", .port = 21162, .last_contact = 0 },
        .{ .id = 3, .endpoint = "127.0.0.1", .port = 21163, .last_contact = 0 },
    };
    var net = Network{};
    var transport = Transport.init(a);
    defer transport.deinit();
    transport.send_override = Network.send;
    transport.send_override_ctx = @ptrCast(&net);

    var node = try RaftNode.initWithStorageDir(a, 1, &peers, 200, dir);
    defer {
        g_node = null;
        node.deinit();
        a.destroy(node);
    }
    try std.testing.expect(node.storage_backing == .file);
    node.setTransport(&transport);
    net.node = node;
    g_node = node;
    g_applied = 0;
    g_at_apply = .{};
    node.apply_callback = &apply;

    try deliverCommittedEntry(node);

    try std.testing.expectEqual(@as(usize, 1), g_applied);
    try std.testing.expectEqual(@as(u64, 1), g_apply_index);
    if (g_at_apply.last_index < 1 or !g_at_apply.data_matches) {
        std.debug.print("entry 1 was applied while storage held last index {d} (entry present and equal: {})\n", .{ g_at_apply.last_index, g_at_apply.data_matches });
    }
    try std.testing.expect(g_at_apply.last_index >= 1);
    try std.testing.expect(g_at_apply.data_matches);
    try std.testing.expectEqual(@as(u64, 1), node.appliedIndex());

    try std.testing.expectEqual(@as(usize, 1), net.replies);
    try std.testing.expectEqual(@as(u64, 1), net.match_index);
    if (net.at_reply.last_index < 1 or !net.at_reply.data_matches) {
        std.debug.print("the reply acknowledging entry 1 was sent while storage held last index {d}\n", .{net.at_reply.last_index});
    }
    try std.testing.expect(net.at_reply.last_index >= 1);
    try std.testing.expect(net.at_reply.data_matches);
}

test "SONNY-6611 (7): with TDE Raft storage the entry is durable (sealed) before it is applied" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const dir = try uniqueDir(a);
    defer a.free(dir);
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var peers = [_]Peer{
        .{ .id = 2, .endpoint = "127.0.0.1", .port = 21164, .last_contact = 0 },
        .{ .id = 3, .endpoint = "127.0.0.1", .port = 21165, .last_contact = 0 },
    };
    var key: [32]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @intCast((i * 7 + 11) & 0xff);
    var node = try RaftNode.initWithStorageDirKey(a, 1, &peers, 200, dir, key);
    defer {
        g_node = null;
        node.deinit();
        a.destroy(node);
    }
    try std.testing.expect(node.storage_backing == .tde_file);
    g_node = node;
    g_applied = 0;
    g_at_apply = .{};
    node.apply_callback = &apply;

    try deliverCommittedEntry(node);

    try std.testing.expectEqual(@as(usize, 1), g_applied);
    try std.testing.expect(g_at_apply.last_index >= 1);
    try std.testing.expect(g_at_apply.data_matches);
}
