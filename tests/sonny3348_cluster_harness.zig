// The in-process 3-node Raft cluster and the gRPC statement runner of the
// SONNY-3348 round 19 regression (tests/test_sonny3348_cluster_batch.zig),
// shared with the regressions that need a cluster leader (SONNY-2726,
// SONNY-3246). A helper, not a test file: it declares no tests, so a test
// that imports it runs only its own.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
pub const fx = @import("sonny738_r12_grpc_fixture.zig");

const eval = geode.eval;
const cluster_mod = geode.distributed.cluster;
const ClusterCoordinator = cluster_mod.ClusterCoordinator;
const raft_lib = geode.distributed.raft;
const raft_apply = geode.distributed.raft_apply;

// ---------------------------------------------------------------------------
// The cluster: three coordinators, the in-process transport, a driver thread.
// ---------------------------------------------------------------------------

pub const Cluster = struct {
    a: std.mem.Allocator,
    coords: [3]*ClusterCoordinator = undefined,
    alive: usize = 0,
    ipt: raft_lib.InProcessTransport,
    running: std.atomic.Value(bool) = .init(true),
    driver: ?std.Thread = null,
    leader: *ClusterCoordinator = undefined,

    pub fn init(self: *Cluster, a: std.mem.Allocator) !void {
        self.* = .{ .a = a, .ipt = raft_lib.InProcessTransport.init(a) };
        const port_base: u16 = 22400;
        const ports = [_]u16{ port_base, port_base + 1, port_base + 2 };
        var peer_lists: [3][2]ClusterCoordinator.PeerConfig = undefined;
        inline for (0..3) |i| {
            var pi: usize = 0;
            inline for (0..3) |j| {
                if (i == j) continue;
                peer_lists[i][pi] = .{ .id = j + 1, .address = "127.0.0.1", .port = ports[j] };
                pi += 1;
            }
        }
        errdefer self.deinit();
        for (0..3) |i| {
            const cfg = ClusterCoordinator.Config{
                .peers = peer_lists[i][0..],
                .listen_address = "127.0.0.1",
                .cluster_port = ports[i],
                .cluster_token = "test-sonny3348-batch",
                .cluster_name = "test-cluster",
                .election_timeout_ms = 250,
            };
            const c = try a.create(ClusterCoordinator);
            c.* = ClusterCoordinator.init(a, @intCast(i + 1), cfg) catch |err| {
                a.destroy(c);
                return err;
            };
            self.coords[i] = c;
            self.alive += 1;
        }
        for (1..4) |id| try self.ipt.register(id);
        const transport = self.ipt.transport();
        for (self.coords) |c| c.raft.setInnerTransport(transport);

        self.driver = try std.Thread.spawn(.{}, drive, .{self});
        const deadline = nowMs() + 15_000;
        while (nowMs() < deadline) : (fx.sleepMs(10)) {
            var leaders: usize = 0;
            var found: ?*ClusterCoordinator = null;
            for (self.coords) |c| if (c.role() == .leader) {
                leaders += 1;
                found = c;
            };
            if (leaders == 1) {
                self.leader = found.?;
                return;
            }
        }
        return error.NoLeader;
    }

    pub fn deinit(self: *Cluster) void {
        self.running.store(false, .release);
        if (self.driver) |t| t.join();
        self.driver = null;
        for (self.coords[0..self.alive]) |c| {
            c.deinit();
            self.a.destroy(c);
        }
        self.alive = 0;
        self.ipt.deinit();
    }

    /// Ticks every node and delivers its messages, until stopped. The
    /// transport is touched on this thread only (a propose appends to the
    /// leader's log, and only a tick or a step sends).
    fn drive(self: *Cluster) void {
        while (self.running.load(.acquire)) {
            for (self.coords) |c| c.raft.tick() catch {};
            for (1..4) |id| {
                const msgs = self.ipt.drain(@intCast(id), self.a) catch continue;
                defer self.a.free(msgs);
                for (msgs) |msg| {
                    self.coords[id - 1].raft.stepInner(inferSender(msg, @intCast(id)), msg) catch {};
                    freeMsgPayload(self.a, msg);
                }
            }
            fx.sleepMs(5);
        }
    }

    /// The leader's committed index, once every node applied it.
    pub fn settle(self: *Cluster) !u64 {
        const deadline = nowMs() + 10_000;
        while (nowMs() < deadline) : (fx.sleepMs(5)) {
            const committed = self.leader.raft.committedIndex();
            var all = true;
            for (self.coords) |c| if (c.raft.appliedIndex() < committed) {
                all = false;
            };
            if (all) return committed;
        }
        return error.ApplyTimeout;
    }
};

pub fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn inferSender(msg: raft_lib.Message, recipient_id: u64) u64 {
    return switch (msg) {
        .request_vote => |rv| rv.candidate_id,
        .append_entries => |ae| ae.leader_id,
        .install_snapshot => |is| is.leader_id,
        .request_vote_response, .append_entries_response, .install_snapshot_response => blk: {
            var i: u64 = 1;
            while (i <= 3) : (i += 1) {
                if (i != recipient_id) break :blk i;
            }
            break :blk recipient_id;
        },
    };
}

fn freeMsgPayload(allocator: std.mem.Allocator, msg: raft_lib.Message) void {
    switch (msg) {
        .append_entries => |ae| if (ae.entries.len > 0) allocator.free(ae.entries),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Statements through the gRPC handler, on a thread with a big stack.
// ---------------------------------------------------------------------------

pub const Run = struct {
    ga: std.mem.Allocator,
    session: []const u8,
    query: []const u8,
    force: ?eval.EvalError = null,
    code: ?[]const u8 = null,
    rows: usize = 0,
    err: ?anyerror = null,

    fn go(self: *Run) void {
        eval.test_force_limit_error = self.force;
        defer eval.test_force_limit_error = null;
        self.run() catch |e| {
            self.err = e;
        };
    }

    fn run(self: *Run) !void {
        const resp = try fx.execute(self.ga, self.session, self.query);
        switch (resp.payload orelse return error.MissingPayload) {
            .@"error" => |e| {
                self.code = e.code;
                return;
            },
            .schema => {},
            else => return,
        }
        const req = try fx.encodeProto(self.ga, schema.PullRequest{ .session_id = self.session, .page_size = 64 });
        const pull = try fx.decodeProto(schema.PullResponse, self.ga, try grpc.handlePull(req, self.ga));
        const presp = pull.response orelse return error.MissingPayload;
        switch (presp.payload orelse return error.MissingPayload) {
            .page => |p| self.rows = p.rows.items.len,
            .@"error" => |e| self.code = e.code,
            else => return error.UnexpectedPayload,
        }
    }
};

pub fn runOn(ga: std.mem.Allocator, session: []const u8, query: []const u8, force: ?eval.EvalError) !Run {
    var r: Run = .{ .ga = ga, .session = session, .query = query, .force = force };
    const t = try std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, Run.go, .{&r});
    t.join();
    return r;
}

pub fn rowsOf(ga: std.mem.Allocator, session: []const u8, query: []const u8) !usize {
    const r = try runOn(ga, session, query, null);
    if (r.err) |e| return e;
    if (r.code) |c| {
        std.debug.print("SONNY-3348 r19: {s} refused {s}\n", .{ query, c });
        return error.QueryFailed;
    }
    return r.rows;
}

pub fn expectRan(ga: std.mem.Allocator, s: []const u8, query: []const u8) !void {
    const r = try runOn(ga, s, query, null);
    if (r.err != null or r.code != null) {
        std.debug.print("SONNY-3348 r19: {s} failed: code={s} err={s}\n", .{ query, r.code orelse "-", if (r.err) |e| @errorName(e) else "-" });
        return error.QueryFailed;
    }
}

pub const Harness = struct {
    f: fx.Fixture = undefined,
    cl: Cluster = undefined,
    s: []const u8 = "",

    /// The fixture, `seed` run standalone, then the cluster with its leader
    /// installed.
    pub fn init(self: *Harness, seed: []const []const u8) !void {
        try self.f.init();
        errdefer self.f.deinit();
        const alloc = self.f.ga();
        self.s = try self.f.session("r19c");
        for (seed) |q| try fx.expectRuns(alloc, self.s, q);
        raft_apply.setGlobalStore(self.f.st);
        errdefer raft_apply.resetGlobalStore();
        try self.cl.init(testing.allocator);
        // The leader's own first entry (its term's no-op) commits before the
        // statements count theirs.
        const deadline = nowMs() + 10_000;
        while (self.cl.leader.raft.committedIndex() == 0) : (fx.sleepMs(5)) {
            if (nowMs() > deadline) return error.NoCommit;
        }
        _ = try self.cl.settle();
        cluster_mod.setGlobalClusterCoordinator(self.cl.leader);
    }

    pub fn deinit(self: *Harness) void {
        cluster_mod.clearGlobalClusterCoordinator();
        self.cl.deinit();
        raft_apply.resetGlobalStore();
        self.f.deinit();
    }

    pub fn ga(self: *Harness) std.mem.Allocator {
        return self.f.ga();
    }
};
