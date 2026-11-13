// CANARY: REQ=REQ-DIST-RAFT-DRAINREADY-DISPATCH; FEATURE="Raft Wrapper Transport Dispatch"; ASPECT=BridgeAndDrainReady; STATUS=TESTED; TEST=tests/test_drainready_dispatch.zig; OWNER=distributed; UPDATED=2026-05-25
// Task A5b (2026-05-25 distributed cluster testing plan):
// drainReady-and-bridge dispatch test.
//
// What this test exercises:
//   * RaftNode.setTransport installs the RaftLibTransportBridge into the
//     inner raft library so outbound raft messages reach peers via the
//     wrapper Transport (production = QUIC+TLS).  Before A5b the wrapper
//     transport field existed but was never wired to the inner node, so
//     the inner library silently dropped every message it tried to send.
//   * A mocked Transport (using Transport.send_override) captures the
//     (peer, from, term, msg) tuple of each outbound dispatch.
//   * Forcing an inner.step with a vote request from a peer drives the
//     candidate-state response path; the bridge fires sendImpl which
//     converts the raft_lib.Message to a geode Message and hands it to
//     the captured mock.
//
// What this test does NOT exercise (deferred):
//   * AppendEntries entries payload (raft_schema.AppendEntries.entries
//     is still TODO — see comment in messageToProto).  Vote messages
//     have no entries so the mock observes them faithfully.
//   * The wire encode/decode round-trip — covered by separate frame tests.

const std = @import("std");
const geode = @import("geode");

const raft_consensus = geode.distributed.raft_consensus;
const raft_lib = geode.distributed.raft;

const RaftNode = raft_consensus.RaftNode;
const Transport = raft_consensus.Transport;
const Peer = raft_consensus.Peer;
const Message = raft_consensus.Message;

/// Capture of one outbound (peer.id, from, term, msg_tag) tuple.
const Captured = struct {
    peer_id: u64,
    from: u64,
    term: u64,
    msg_tag: std.meta.Tag(Message),
    granted: ?bool = null,
};

const Sink = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Captured) = .empty,

    fn deinit(self: *Sink) void {
        self.items.deinit(self.allocator);
    }

    fn captureSend(
        t: *Transport,
        peer: Peer,
        from: u64,
        term: u64,
        msg: Message,
    ) anyerror!void {
        const ctx_ptr = t.send_override_ctx orelse return error.MissingCtx;
        const self: *Sink = @ptrCast(@alignCast(ctx_ptr));
        const granted: ?bool = switch (msg) {
            .request_vote_response => |rvr| rvr.vote_granted,
            else => null,
        };
        try self.items.append(self.allocator, .{
            .peer_id = peer.id,
            .from = from,
            .term = term,
            .msg_tag = std.meta.activeTag(msg),
            .granted = granted,
        });
    }
};

test "drainReady-and-bridge: wrapper transport receives RequestVoteResponse from inner step" {
    const a = std.testing.allocator;

    // Build a 2-node cluster from node 1's perspective.  Peer 2 is the
    // only other node — we'll feed node 1 a vote request from peer 2 and
    // expect node 1's response to be dispatched back through the bridge.
    var peers = try a.alloc(Peer, 1);
    defer a.free(peers);
    // RaftNode.deinit doesn't free peer endpoints; this test owns the slice
    // so we keep the endpoint as a static string literal (no allocation
    // needed for the bridge lookup to succeed).
    peers[0] = .{
        .id = 2,
        .endpoint = "127.0.0.1",
        .port = 21001,
        .last_contact = 0,
    };

    var node = try RaftNode.init(a, 1, peers, 200);
    defer {
        node.deinit();
        a.destroy(node);
    }

    // Mocked transport: capture each outbound send instead of routing
    // through the QUIC stub.  send_override_ctx points at the sink so the
    // override can recover it without static globals.
    var sink = Sink{ .allocator = a };
    defer sink.deinit();

    var transport = Transport.init(a);
    defer transport.deinit();
    transport.send_override = Sink.captureSend;
    transport.send_override_ctx = @ptrCast(&sink);

    // Wire the bridge: from this point on, inner.sendMsg(to, msg) routes
    // through transport.send(peer, from, term, geode_msg) via the bridge.
    node.setTransport(&transport);

    // Sanity: the bridge has been installed.  We can't observe `inner.transport`
    // directly (it's a private field on raft_lib.RaftNode), but we can confirm
    // the wrapper holds the transport pointer it was given.
    try std.testing.expect(node.transport == &transport);

    // Feed node 1 a vote request from peer 2.  Inner raft will respond
    // with a request_vote_response back to candidate_id=2.  raft-0.1.3
    // emits the response via the transport vtable immediately during
    // step() — our bridge picks it up and routes through the mock.
    const vote_req = raft_lib.Message{ .request_vote = .{
        .term = 5,
        .candidate_id = 2,
        .last_log_index = 0,
        .last_log_term = 0,
        .pre_vote = false,
    } };
    try node.stepInner(2, vote_req);

    // Expect at least one captured send to peer 2.  A vote response is
    // always emitted on receipt of a valid RequestVote (granted or not).
    try std.testing.expect(sink.items.items.len >= 1);

    var saw_response = false;
    for (sink.items.items) |c| {
        if (c.msg_tag == .request_vote_response and c.peer_id == 2) {
            saw_response = true;
            // The response should carry node 1's current term — bumped to 5
            // by the incoming request — and be addressed to peer 2.
            try std.testing.expectEqual(@as(u64, 1), c.from);
            try std.testing.expectEqual(@as(u64, 5), c.term);
        }
    }
    try std.testing.expect(saw_response);
}

test "raft outbox dispatch drops queued sends after shutdown is requested" {
    const a = std.testing.allocator;

    var sink = Sink{ .allocator = a };
    defer sink.deinit();

    var transport = Transport.init(a);
    defer transport.deinit();
    transport.send_override = Sink.captureSend;
    transport.send_override_ctx = @ptrCast(&sink);

    const peer = Peer{
        .id = 2,
        .endpoint = "127.0.0.1",
        .port = 21001,
        .last_contact = 0,
    };
    const msg = Message{ .request_vote_response = .{
        .term = 7,
        .vote_granted = true,
        .voter_id = 1,
        .pre_vote = false,
    } };

    try transport.enqueueOutbound(peer, 1, 7, msg);
    var snap = transport.snapshotOutbox();

    transport.outbox_shutdown.store(true, .release);
    transport.dispatchOutbox(&snap);

    try std.testing.expectEqual(@as(usize, 0), sink.items.items.len);
}

test "drainReady fallback: empty rd.messages with no transport is a no-op" {
    const a = std.testing.allocator;

    // Single-node cluster: no peers.  Without a transport set, drainReady
    // must not crash and must not attempt any dispatch.  This guards the
    // production-config path where setTransport hasn't been called yet
    // (e.g. during early startup).
    const peers = try a.alloc(Peer, 0);
    defer a.free(peers);

    var node = try RaftNode.init(a, 1, peers, 200);
    defer {
        node.deinit();
        a.destroy(node);
    }

    // No transport, no inner transport — just tick the node.  Since
    // raft-0.1.3 never populates rd.messages, this exercises only the
    // committed_entries / hard_state paths, but it also confirms the new
    // drainReady code doesn't dereference a null transport pointer.
    try node.tick();
    try node.tick();
    try node.tick();
}
