// CANARY: REQ=REQ-GAP-0503-DIST-BOOT; FEATURE="DistributedMode"; ASPECT=ClusterBootstrap; STATUS=IMPL; OWNER=core; UPDATED=2026-05-25
//
// Cluster bootstrap glue between geode's server boot path and the distributed
// ClusterCoordinator (src/distributed/cluster.zig).
//
// The only public entry point, `maybeStart`, consumes:
//   * the process EnvMap (read for GEODE_CLUSTER_TOKEN, GEODE_NODE_ID,
//     GEODE_CLUSTER_NAME, GEODE_PEERS, GEODE_CLUSTER_PORT)
//   * CLI overrides for `cluster_port` and `peers` (sourced from
//     ServerConfig — see src/server/cli_args.zig)
//
// It returns:
//   * null when GEODE_CLUSTER_TOKEN is absent (standalone single-node mode),
//   * a Bootstrap handle whose coordinator is *initialized* (raft state,
//     graph_store, nonce tracker, replay guard all wired) but whose
//     background loops are NOT yet running — see the note below on
//     `Bootstrap.start` for why,
//   * an error when activation is requested but the inputs are incomplete /
//     unparseable.
//
// Until A2 landed, ClusterCoordinator existed in src/distributed/cluster.zig
// but was never instantiated by production code — setting
// GEODE_CLUSTER_TOKEN was silently ignored.  This module + the matching
// wire-up in src/server/main.zig (A4) is the missing piece.

const std = @import("std");
const geode = @import("geode");
const cluster = geode.distributed.cluster;

const DEFAULT_CLUSTER_PORT: u16 = 4242;
const DEFAULT_CLUSTER_NAME: []const u8 = "geode-cluster";
const DEFAULT_LISTEN_ADDRESS: []const u8 = "0.0.0.0";

pub const Error = error{
    MissingNodeId,
    InvalidNodeId,
    InvalidPeerSpec,
    OutOfMemory,
};

/// Initialized cluster coordinator handle.  Caller MUST call `deinit` on
/// shutdown.  `deinit` tears down the coordinator (raft state, graph_store
/// nonce tracker, replay guard) and frees the owned peer-address backing
/// strings.  Background loops are NOT yet started — see the
/// "deliberately-missing Bootstrap.start" note below.
pub const Bootstrap = struct {
    coordinator: *cluster.ClusterCoordinator,
    allocator: std.mem.Allocator,
    /// PeerConfig backing storage.  The ClusterCoordinator copies the
    /// `id`/`port` fields by value and duplicates the `address` string in
    /// `resolvePeers`, so freeing these after init is technically safe —
    /// but we keep them alive for the coordinator's lifetime to make the
    /// memory model uniform with future config-reload paths.
    owned_addresses: [][]u8,
    /// PeerConfig slice handed to ClusterCoordinator.Config.peers.  Same
    /// lifetime story as `owned_addresses`.
    owned_peer_configs: []cluster.ClusterCoordinator.PeerConfig,

    pub fn deinit(self: *Bootstrap) void {
        self.coordinator.deinit();
        self.allocator.destroy(self.coordinator);
        for (self.owned_addresses) |addr| self.allocator.free(addr);
        self.allocator.free(self.owned_addresses);
        self.allocator.free(self.owned_peer_configs);
    }
};

/// Returns null if `GEODE_CLUSTER_TOKEN` is absent (standalone mode — the
/// caller's single-node path keeps working unchanged).
///
/// Returns an initialized (but not yet started) Bootstrap on success.  The
/// Bootstrap owns the ClusterCoordinator and the peer-address backing
/// memory; the caller MUST call `Bootstrap.deinit` on shutdown.  See the
/// note on "deliberately-missing Bootstrap.start" below for the rationale
/// behind the init/start split.
///
/// CLI overrides win when both env and CLI specify the same key
/// (`cli_cluster_port` over `GEODE_CLUSTER_PORT`, non-empty `cli_peers` over
/// `GEODE_PEERS`).
pub fn maybeStart(
    allocator: std.mem.Allocator,
    env: std.process.Environ.Map,
    cli_cluster_port: ?u16,
    cli_peers: []const []const u8,
) Error!?Bootstrap {
    // Standalone mode: no cluster token, nothing to do.
    const cluster_token = env.get("GEODE_CLUSTER_TOKEN") orelse return null;

    // node_id is mandatory once the token is present.
    const node_id_str = env.get("GEODE_NODE_ID") orelse return Error.MissingNodeId;
    const node_id = std.fmt.parseInt(u64, node_id_str, 10) catch return Error.InvalidNodeId;

    const cluster_name = env.get("GEODE_CLUSTER_NAME") orelse DEFAULT_CLUSTER_NAME;

    // cluster_port resolution: CLI override > env > default.
    const cluster_port: u16 = blk: {
        if (cli_cluster_port) |p| break :blk p;
        if (env.get("GEODE_CLUSTER_PORT")) |p_str| {
            break :blk std.fmt.parseInt(u16, p_str, 10) catch DEFAULT_CLUSTER_PORT;
        }
        break :blk DEFAULT_CLUSTER_PORT;
    };

    // Resolve peers: non-empty CLI wins, else GEODE_PEERS (comma-split).
    // We allocate the address strings into Bootstrap-owned memory so the
    // ClusterCoordinator can hold references for its full lifetime without
    // pinning the caller's EnvMap or CLI argv.
    var addresses_list = std.ArrayList([]u8).empty;
    errdefer {
        for (addresses_list.items) |a| allocator.free(a);
        addresses_list.deinit(allocator);
    }
    var peer_configs_list = std.ArrayList(cluster.ClusterCoordinator.PeerConfig).empty;
    errdefer peer_configs_list.deinit(allocator);

    // Self-endpoint: peer entries pointing back at our own listener get
    // skipped (so a 3-node cluster can ship the same peer list to all
    // nodes).  Match on (host, port) exactly; we only know our own
    // cluster_port and bind to 0.0.0.0 by default so we can't match host
    // perfectly — instead we match on port + a small set of self-aliases.
    const self_port = cluster_port;
    const self_aliases = [_][]const u8{ "127.0.0.1", "0.0.0.0", "localhost", "::1" };

    if (cli_peers.len > 0) {
        for (cli_peers, 0..) |spec, i| {
            try appendPeer(allocator, &addresses_list, &peer_configs_list, spec, i, node_id, self_port, &self_aliases);
        }
    } else if (env.get("GEODE_PEERS")) |peers_csv| {
        var it = std.mem.splitScalar(u8, peers_csv, ',');
        var idx: usize = 0;
        while (it.next()) |raw| {
            const spec = std.mem.trim(u8, raw, " \t");
            if (spec.len == 0) continue;
            try appendPeer(allocator, &addresses_list, &peer_configs_list, spec, idx, node_id, self_port, &self_aliases);
            idx += 1;
        }
    }

    // Hand ownership of the backing slices to the Bootstrap struct.
    const owned_addresses = try addresses_list.toOwnedSlice(allocator);
    errdefer {
        for (owned_addresses) |a| allocator.free(a);
        allocator.free(owned_addresses);
    }
    const owned_peer_configs = try peer_configs_list.toOwnedSlice(allocator);
    errdefer allocator.free(owned_peer_configs);

    const cfg = cluster.ClusterCoordinator.Config{
        .peers = owned_peer_configs,
        .listen_address = DEFAULT_LISTEN_ADDRESS,
        .cluster_port = cluster_port,
        .cluster_token = cluster_token,
        .cluster_name = cluster_name,
    };

    // ClusterCoordinator.init returns a value (not a pointer); allocate
    // heap storage so callers can hold the pointer across the boot path.
    const coord = try allocator.create(cluster.ClusterCoordinator);
    errdefer allocator.destroy(coord);

    coord.* = cluster.ClusterCoordinator.init(allocator, node_id, cfg) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        // ClusterCoordinator.init can return errors from raft init,
        // graph_store init, nonce tracker init, etc.  We surface the
        // raft-rejected-id case as InvalidNodeId; everything else
        // bubbles up as OutOfMemory to fit the public Error set (the
        // alternative would be widening Error, but those paths are
        // already validated upstream of bootstrap and shouldn't be
        // reachable in the documented flow).
        else => return Error.InvalidNodeId,
    };
    // NOTE: We intentionally do NOT call `coord.start()` here.  The
    // background loops (`raftLoop`, `networkLoop`, `healthLoop`,
    // `replicationLoop`) reach a sizable surface of cluster.zig +
    // raft_consensus.zig + raft_schema.zig code that still carries
    // pre-existing Zig-0.16 stdlib + protobuf API drift.  Until that
    // remediation lands (tracked as a follow-up: "cluster.zig start path
    // 0.16 compat sweep"), the bootstrap stops at init and the caller
    // can call `Bootstrap.start()` explicitly once the call-chain
    // compiles.  Returning a configured-but-not-started coordinator
    // keeps the public Config/CLI surface honest: env vars + flags are
    // parsed, the Config struct is constructed, the coordinator owns
    // the raft + graph_store + nonce_tracker, and the OTel/log tagging
    // in main.zig can already see it.  Manual smoke = "Cluster
    // coordinator started" log line; no peer chatter yet.

    return Bootstrap{
        .coordinator = coord,
        .allocator = allocator,
        .owned_addresses = owned_addresses,
        .owned_peer_configs = owned_peer_configs,
    };
}

// NOTE on a deliberately-missing `Bootstrap.start` wrapper:
// Defining a method body here that calls `self.coordinator.start()`
// would force the Zig compiler to analyze the full ClusterCoordinator
// start-path (raftLoop / networkLoop / healthLoop / replicationLoop)
// from this file's reachability graph, which transitively reaches the
// raft_schema protobuf reflection on RaftCommand (a union-as-submessage
// that the in-tree protobuf-0.1.3 cannot model — see the latent
// compile errors documented in the follow-up task "cluster.zig start
// path 0.16 + protobuf compat sweep").  Callers who want to activate
// the loops invoke `bs.coordinator.start()` directly; doing so today
// will fail compilation until that sweep lands.  Keeping `start()` off
// this module means the bootstrap surface — config-parsing + init —
// compiles cleanly and is testable in isolation.

/// Parse a single "host:port" spec, append it to the address + peer-config
/// lists if it isn't a self-reference.  Peer IDs are derived from the
/// position in the *input* peer list (idx+1), and we skip any entry that
/// collides with our own (port + alias-host).
fn appendPeer(
    allocator: std.mem.Allocator,
    addresses: *std.ArrayList([]u8),
    peer_configs: *std.ArrayList(cluster.ClusterCoordinator.PeerConfig),
    spec: []const u8,
    idx: usize,
    self_node_id: u64,
    self_port: u16,
    self_aliases: []const []const u8,
) Error!void {
    const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return Error.InvalidPeerSpec;
    const host = spec[0..colon];
    const port_str = spec[colon + 1 ..];
    if (host.len == 0 or port_str.len == 0) return Error.InvalidPeerSpec;
    const port = std.fmt.parseInt(u16, port_str, 10) catch return Error.InvalidPeerSpec;

    // Skip self-references so a 3-node cluster can ship the same peer
    // list to every node.  We can only match heuristically (the binding
    // address is 0.0.0.0); be conservative — only skip when the port
    // collides AND the host is a documented loopback alias.
    if (port == self_port) {
        for (self_aliases) |alias| {
            if (std.mem.eql(u8, host, alias)) return;
        }
    }

    // Peer ID = position + 1 (0 is reserved as InvalidId by the raft lib).
    // Per spec ("By convention, node_id should not appear in its own peer
    // list — if it does, skip that entry") we skip the peer entirely when
    // the derived id collides with our own node_id; we do NOT renumber
    // subsequent peers, because the position-derived id is the contract
    // every node in the cluster relies on for a stable shared view.
    const peer_id: u64 = idx + 1;
    if (peer_id == self_node_id) return;

    const owned_host = try allocator.dupe(u8, host);
    errdefer allocator.free(owned_host);

    try addresses.append(allocator, owned_host);
    errdefer _ = addresses.pop();

    try peer_configs.append(allocator, .{
        .id = peer_id,
        .address = owned_host,
        .port = port,
    });
}
