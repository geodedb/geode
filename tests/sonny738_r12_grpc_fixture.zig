// SONNY-738 round 12: the in-process gRPC fixture the round's regression
// tests share (SONNY-3026 .. SONNY-3038). The real gRPC handlers through the
// SONNY-1560 shim, a persisted store (so the storage adapter and its engines
// exist), and helpers that read what the engine and the session hold.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");

const graph_store = geode.graph_store;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const execution = geode.execution;
const index_manager = geode.index_manager;

pub fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

pub fn encodeProto(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    return allocator.dupe(u8, aw.written());
}

pub fn decodeProto(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !T {
    var reader: std.Io.Reader = .fixed(bytes);
    return protobuf.decode(T, &reader, allocator);
}

pub fn execute(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !schema.ExecutionResponse {
    const req = try encodeProto(ga, schema.ExecuteRequest{ .session_id = session_id, .query = query, .params = .empty });
    return decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
}

/// The SQLSTATE a request was refused with, or null when it ran.
pub fn outcome(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !?[]const u8 {
    const resp = try execute(ga, session_id, query);
    return switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| e.code,
        else => null,
    };
}

pub fn expectRuns(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !void {
    const resp = try execute(ga, session_id, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("{s}: {s} {s}\n", .{ query, e.code, e.message });
            return error.QueryFailed;
        },
        else => {},
    }
}

pub fn expectRefused(ga: std.mem.Allocator, session_id: []const u8, query: []const u8, code: []const u8) !schema.Error {
    const resp = try execute(ga, session_id, query);
    const err = switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| e,
        else => {
            std.debug.print("{s}: ran; expected {s}\n", .{ query, code });
            return error.ExpectedRefusal;
        },
    };
    if (!std.mem.eql(u8, code, err.code)) std.debug.print("{s}: {s} {s}\n", .{ query, err.code, err.message });
    try testing.expectEqualStrings(code, err.code);
    return err;
}

pub fn begin(ga: std.mem.Allocator, session_id: []const u8) !void {
    const req = try encodeProto(ga, schema.BeginRequest{ .session_id = session_id });
    const resp = try decodeProto(schema.BeginResponse, ga, try grpc.handleBegin(req, ga));
    if (resp.tx_id.len == 0) return error.BeginRefused;
}

pub fn commit(ga: std.mem.Allocator, session_id: []const u8) !bool {
    const req = try encodeProto(ga, schema.CommitRequest{ .session_id = session_id });
    return (try decodeProto(schema.CommitResponse, ga, try grpc.handleCommit(req, ga))).success;
}

pub fn rollback(ga: std.mem.Allocator, session_id: []const u8) !bool {
    const req = try encodeProto(ga, schema.RollbackRequest{ .session_id = session_id });
    return (try decodeProto(schema.RollbackResponse, ga, try grpc.handleRollback(req, ga))).success;
}

pub fn countLabel(st: *graph_store.GraphStore, graph: []const u8, label: []const u8) usize {
    const ids = st.getNodesByLabel(graph, label) orelse return 0;
    return ids.len;
}

/// Engine transactions open in `graph`, over all its shards (0 when the
/// graph has no engine).
pub fn engineActive(graph: []const u8) usize {
    const ad = graph_store.getGlobalAdapter() orelse return 0;
    const mg = ad.engines.get(graph) orelse return 0;
    var n: usize = 0;
    for (mg.engine.shards) |eng| n += eng.txn_manager.active_txns.count();
    return n;
}

/// Holds `graph`'s lock for `hold_ms`, then lets go. `letting_go` is set just
/// before the lock is released.
pub const Holder = struct {
    graph: []const u8,
    hold_ms: u64 = 400,
    write: bool = false,
    held: std.atomic.Value(bool) = .init(false),
    letting_go: std.atomic.Value(bool) = .init(false),

    fn go(self: *Holder) void {
        const lock = if (self.write) graph_store.acquireGraphWriteLock(self.graph) else graph_store.acquireGraphReadLock(self.graph);
        self.held.store(true, .release);
        sleepMs(self.hold_ms);
        self.letting_go.store(true, .release);
        graph_store.releaseGraphLock(lock);
    }

    pub fn start(self: *Holder) !std.Thread {
        const t = try std.Thread.spawn(.{}, go, .{self});
        while (!self.held.load(.acquire)) sleepMs(1);
        return t;
    }
};

/// An in-process gRPC server: sessions, a persisted store with graphs g1 and
/// g2, and authorization out of the way.
pub const Fixture = struct {
    h: harness.Harness,
    arena: std.heap.ArenaAllocator,
    sessions: grpc.SessionStore,
    st: *graph_store.GraphStore,
    auth_was_enabled: bool,
    allow_all_was: bool,

    /// SONNY-738 round 15: how the store is set up.
    pub const Options = struct {
        /// The node, edge and adjacency caches BOUNDED, as `initGlobalStore`
        /// sets them in production (it installs their hydrate hooks). The
        /// harness leaves them unbounded by default (the in-memory, or
        /// GEODE_*_CACHE_ENTRIES=0, mode), which takes other code paths:
        /// the IdMap walks, the bounded append and reservation paths. The
        /// round 14 review's races (F2, F3) were found with bounded caches.
        bounded_caches: bool = false,
    };

    pub fn init(self: *Fixture) !void {
        return self.initWith(.{});
    }

    pub fn initWith(self: *Fixture, opts: Options) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        self.st = graph_store.getGlobalStore(testing.allocator);
        if (opts.bounded_caches) {
            self.st.installNodeCacheHydrate();
            self.st.installAdjCacheHydrate();
            self.st.installEdgeCacheHydrate();
        }
        // The undo log is created by its first user, with that user's
        // allocator; BEGIN would create it with the requests' arena.
        _ = geode.txn_undo_log.getGlobalUndoLog(testing.allocator);
        // SONNY-3379: the same for the process-wide index manager: the first
        // CREATE INDEX would create it with the requests' arena, which
        // `deinit` frees (the HNSW pool's workers then run on freed memory
        // and the catalog cleanup calls into it).
        _ = try index_manager.ensureGlobalIndexManager(testing.allocator);
        errdefer index_manager.cleanupGlobalIndexManager();
        try self.st.createGraph("g1");
        try self.st.createGraph("g2");
        self.auth_was_enabled = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(false);
        self.allow_all_was = gps.isInsecureAllowAll();
        gps.setInsecureAllowAll(true);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
    }

    pub fn deinit(self: *Fixture) void {
        grpc.setSessionStore(null);
        self.sessions.deinit();
        // SONNY-3379: the catalog (whose cleanup calls into the index
        // manager), then the index manager (joining its HNSW workers), and
        // only then the request arena and the store.
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        self.arena.deinit();
        gps.setInsecureAllowAll(self.allow_all_was);
        user_mgmt.setAuthEnabled(self.auth_was_enabled);
        geode.txn_undo_log.setThreadTxnId(0);
        self.h.deinit();
    }

    pub fn ga(self: *Fixture) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn session(self: *Fixture, name: []const u8) ![]const u8 {
        return self.sessions.createSession(name, "", null, null, null, false, 0);
    }
};
