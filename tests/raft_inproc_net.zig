// SONNY-6633 (5): the raft library's messages between in-process nodes,
// each delivered with its real sender.
//
// `raft_lib.InProcessTransport` queues a message per recipient with no
// sender, and the in-process cluster tests guessed it (`inferSender`): a
// response was attributed to the lowest id other than the recipient, so in
// a three-node cluster node 3's votes and acks reached the leader as node
// 2's. Here every node sends through its own endpoint (`transportFor`), and
// `drain` returns `{ from, msg }`.
//
// Every message is copied when sent, AppendEntries entry data and
// InstallSnapshot chunk data and configuration included: the library frees
// them when `send` returns (`InProcessTransport` copies only the entries,
// so an in-process snapshot was read after it was freed). Thread-safe: a
// proposer and the driver thread may send at once.
//
// A helper, not a test file: it declares no tests.

const std = @import("std");
const geode = @import("geode");
const raft_lib = geode.distributed.raft;

pub const max_nodes = 8;

pub const Delivery = struct { from: u64, msg: raft_lib.Message };

pub const RaftNet = struct {
    const Pending = struct { from: u64, to: u64, msg: raft_lib.Message };
    const Endpoint = struct { net: *RaftNet, id: u64 };
    const vtable = raft_lib.Transport.VTable{ .send = &send };

    a: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    endpoints: [max_nodes + 1]Endpoint = undefined,
    queue: std.ArrayList(Pending) = .empty,

    pub fn init(a: std.mem.Allocator) RaftNet {
        return .{ .a = a };
    }

    pub fn deinit(self: *RaftNet) void {
        for (self.queue.items) |p| freeMessage(self.a, p.msg);
        self.queue.deinit(self.a);
    }

    /// The transport node `id` sends through. `self` must not move after.
    pub fn transportFor(self: *RaftNet, id: u64) raft_lib.Transport {
        std.debug.assert(id >= 1 and id <= max_nodes);
        self.endpoints[id] = .{ .net = self, .id = id };
        return .{ .ptr = @ptrCast(&self.endpoints[id]), .vtable = &vtable };
    }

    /// The messages queued for `to`, in send order, with their senders.
    /// Free each with `freeMessage`, then the slice with `a`.
    pub fn drain(self: *RaftNet, to: u64, a: std.mem.Allocator) ![]Delivery {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var out: std.ArrayList(Delivery) = .empty;
        errdefer out.deinit(a);
        var i: usize = 0;
        while (i < self.queue.items.len) {
            const p = self.queue.items[i];
            if (p.to != to) {
                i += 1;
                continue;
            }
            try out.append(a, .{ .from = p.from, .msg = p.msg });
            _ = self.queue.orderedRemove(i);
        }
        return out.toOwnedSlice(a);
    }

    fn send(ptr: *anyopaque, to: u64, msg: raft_lib.Message) void {
        const ep: *Endpoint = @ptrCast(@alignCast(ptr));
        const net = ep.net;
        const copy = dupeMessage(net.a, msg) catch return; // dropped: Raft retries
        const io = std.Io.Threaded.global_single_threaded.io();
        net.mutex.lockUncancelable(io);
        defer net.mutex.unlock(io);
        net.queue.append(net.a, .{ .from = ep.id, .to = to, .msg = copy }) catch freeMessage(net.a, copy);
    }
};

pub fn dupeMessage(a: std.mem.Allocator, msg: raft_lib.Message) !raft_lib.Message {
    return switch (msg) {
        .append_entries => |ae| blk: {
            var c = ae;
            c.entries = try raft_lib.dupeEntries(a, ae.entries);
            break :blk .{ .append_entries = c };
        },
        .install_snapshot => |is| blk: {
            var c = is;
            c.data = try a.dupe(u8, is.data);
            errdefer a.free(c.data);
            c.config.voters = try a.dupe(u64, is.config.voters);
            errdefer a.free(c.config.voters);
            c.config.voters_outgoing = try a.dupe(u64, is.config.voters_outgoing);
            break :blk .{ .install_snapshot = c };
        },
        else => msg,
    };
}

pub fn freeMessage(a: std.mem.Allocator, msg: raft_lib.Message) void {
    switch (msg) {
        .append_entries => |ae| raft_lib.freeEntries(a, ae.entries),
        .install_snapshot => |is| {
            a.free(is.data);
            a.free(is.config.voters);
            a.free(is.config.voters_outgoing);
        },
        else => {},
    }
}
