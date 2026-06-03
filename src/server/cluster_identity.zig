// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// CANARY: REQ=REQ-GAP-0838-CLUSTER-IDENTITY; FEATURE="DistributedMode"; ASPECT=IdentityContractDiagnostic; STATUS=TESTED; TEST=src/server/cluster_identity.zig; OWNER=core; UPDATED=2026-06-02
//
//! Cluster identity-contract self-diagnostic.
//!
//! GAP-0838 / 2026-06-02 k8s cluster bug (Bug B hardening): a Geode cluster
//! derives every peer's raft node_id from its 1-based POSITION in the shared
//! `GEODE_PEERS` list, and each node stamps its OWN `GEODE_NODE_ID` as the
//! `from` field on the raft frames it sends. For a node's RequestVote
//! responses to be counted, its `GEODE_NODE_ID` MUST equal the position every
//! other node assigned it. When peers are loopback IPs the bootstrap can
//! self-identify by (host, port); but with Kubernetes headless DNS names
//! (`geode-0.geode`) the host-based self-skip never fires, so correctness
//! rests entirely on `GEODE_NODE_ID` matching position.
//!
//! When that invariant is violated the symptoms are SILENT: peers connect,
//! the TLS handshake completes, no transport error is logged, but every
//! RequestVote response is dropped as "from a non-voter" inside the raft
//! library, so the cluster spins forever at `state=candidate term=0`.
//!
//! This module is the pure, std-only core of a boot-time diagnostic that
//! detects the known silent misconfigurations and lets the bootstrap log a
//! loud, actionable message before the (doomed) election even starts.

const std = @import("std");

/// The documented loopback aliases the host-based self-skip matches.
pub const loopback_aliases = [_][]const u8{ "127.0.0.1", "0.0.0.0", "localhost", "::1" };

pub fn isLoopbackAlias(host: []const u8) bool {
    for (loopback_aliases) |a| {
        if (std.mem.eql(u8, host, a)) return true;
    }
    return false;
}

/// The leading DNS label of a host (`geode-0.geode` -> `geode-0`). Used to
/// match a StatefulSet pod's `$HOSTNAME` (e.g. `geode-0`) against a peer
/// entry's FQDN.
pub fn hostLabel(host: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, host, '.') orelse return host;
    return host[0..dot];
}

/// True when `peer_host` refers to the same node as `our_hostname` — either an
/// exact match or a leading-label match (FQDN vs short pod name).
pub fn hostMatchesSelf(peer_host: []const u8, our_hostname: []const u8) bool {
    if (our_hostname.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(peer_host, our_hostname)) return true;
    return std.ascii.eqlIgnoreCase(hostLabel(peer_host), our_hostname);
}

/// How the configured peer list resolved on this node, plus what we could
/// independently infer about our own identity from `$HOSTNAME`.
pub const PeerResolution = struct {
    /// The `GEODE_NODE_ID` this process was given.
    node_id: u64,
    /// Number of entries in the configured peer list (INCLUDING the self
    /// entry that a StatefulSet ships to every pod).
    total_entries: usize,
    /// How many entries the bootstrap dropped as self-references.
    self_skips: usize,
    /// Peers remaining after self-skip (the raft voter set minus self).
    resulting_peers: usize,
    /// At least one peer host is NOT a loopback alias (i.e. a DNS name), so
    /// the host-based self-skip could not fire for those entries.
    any_dns_peer: bool,
    /// The 1-based position whose host matched `$HOSTNAME`, if any. This is
    /// the position other nodes will assign this node, so it is what
    /// `node_id` MUST equal.
    self_position_by_hostname: ?usize,
};

pub const Severity = enum { info, warn, err };

pub const Code = enum {
    /// `node_id` whose host we matched by hostname is not equal to the
    /// position-derived id every peer will use -> votes silently dropped.
    hostname_position_mismatch,
    /// `node_id` is 0 (raft InvalidId) or larger than the cluster size.
    node_id_out_of_range,
    /// A non-empty peer list contained no self entry to skip -> likely
    /// `node_id` does not match any position (self ends up in its own
    /// voter set, or this node is invisible to itself).
    self_not_skipped,
    /// More than one entry was skipped as self -> duplicate/self-id collision.
    multiple_self_skips,
    /// Peers use DNS names: the node_id<->position contract is load-bearing.
    /// Informational reminder, emitted even for healthy DNS clusters.
    dns_identity_contract,
};

pub const Finding = struct {
    severity: Severity,
    code: Code,
};

/// Static, human-readable remediation text for a finding. The caller attaches
/// the concrete node_id / position values as structured log attributes.
pub fn message(code: Code) []const u8 {
    return switch (code) {
        .hostname_position_mismatch => "GEODE_NODE_ID does not match this host's 1-based position in GEODE_PEERS. " ++
            "Peers derive each node's raft id from its position, so every RequestVote " ++
            "response this node sends will be silently dropped as a non-voter and the " ++
            "cluster will hang at 'state=candidate term=0'. Set GEODE_NODE_ID to the " ++
            "position shown.",
        .node_id_out_of_range => "GEODE_NODE_ID is 0 or greater than the number of peers; it must be a " ++
            "1-based index into GEODE_PEERS (1..N).",
        .self_not_skipped => "No entry in GEODE_PEERS was recognized as this node, so this node may be " ++
            "in its own voter set or invisible to itself. With DNS peer names this " ++
            "usually means GEODE_NODE_ID does not match this node's position.",
        .multiple_self_skips => "More than one GEODE_PEERS entry was treated as this node — duplicate peer " ++
            "entries or a node_id/position collision.",
        .dns_identity_contract => "Cluster peers use DNS names; GEODE_NODE_ID must equal this node's 1-based " ++
            "position in the GEODE_PEERS list, identical on every node.",
    };
}

/// Analyze a resolved peer configuration for the silent misconfigurations
/// that prevent leader election. Pure: no I/O, no logging. Caller owns the
/// returned slice.
pub fn analyze(allocator: std.mem.Allocator, r: PeerResolution) ![]Finding {
    var list: std.ArrayList(Finding) = .empty;
    errdefer list.deinit(allocator);

    // node_id must be a 1-based index into the peer list (raft rejects id 0).
    if (r.total_entries > 0 and (r.node_id == 0 or r.node_id > r.total_entries)) {
        try list.append(allocator, .{ .severity = .err, .code = .node_id_out_of_range });
    }

    // The smoking gun: we matched this node's $HOSTNAME to a peer entry, and
    // the position that entry occupies (what every other node will use as our
    // raft id) is not what GEODE_NODE_ID says.
    if (r.self_position_by_hostname) |pos| {
        if (pos != r.node_id) {
            try list.append(allocator, .{ .severity = .err, .code = .hostname_position_mismatch });
        }
    }

    // A non-empty peer list with no self-skip: this node isn't in its own
    // peer list under the id it claims.
    if (r.total_entries > 0 and r.self_skips == 0) {
        try list.append(allocator, .{ .severity = .warn, .code = .self_not_skipped });
    }

    if (r.self_skips > 1) {
        try list.append(allocator, .{ .severity = .warn, .code = .multiple_self_skips });
    }

    // Informational reminder for any DNS-named cluster (healthy or not).
    if (r.any_dns_peer) {
        try list.append(allocator, .{ .severity = .info, .code = .dns_identity_contract });
    }

    return list.toOwnedSlice(allocator);
}

fn has(findings: []const Finding, code: Code) bool {
    for (findings) |f| if (f.code == code) return true;
    return false;
}

fn severityOf(findings: []const Finding, code: Code) ?Severity {
    for (findings) |f| if (f.code == code) return f.severity;
    return null;
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

test "analyze: healthy loopback cluster has no findings" {
    const a = std.testing.allocator;
    const findings = try analyze(a, .{
        .node_id = 2,
        .total_entries = 3,
        .self_skips = 1,
        .resulting_peers = 2,
        .any_dns_peer = false,
        .self_position_by_hostname = null,
    });
    defer a.free(findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "analyze: healthy k8s DNS cluster only emits the informational contract note" {
    const a = std.testing.allocator;
    // geode-1 with GEODE_NODE_ID=2, hostname matched at position 2 == node_id.
    const findings = try analyze(a, .{
        .node_id = 2,
        .total_entries = 3,
        .self_skips = 1,
        .resulting_peers = 2,
        .any_dns_peer = true,
        .self_position_by_hostname = 2,
    });
    defer a.free(findings);
    try std.testing.expect(!has(findings, .hostname_position_mismatch));
    try std.testing.expect(!has(findings, .node_id_out_of_range));
    try std.testing.expect(!has(findings, .self_not_skipped));
    // The DNS contract reminder is present but only informational.
    try std.testing.expectEqual(@as(?Severity, .info), severityOf(findings, .dns_identity_contract));
}

test "analyze: GEODE_NODE_ID != hostname position is a hard error (the k8s bug)" {
    const a = std.testing.allocator;
    // geode-1 (position 2) misconfigured with GEODE_NODE_ID=1.
    const findings = try analyze(a, .{
        .node_id = 1,
        .total_entries = 3,
        .self_skips = 1,
        .resulting_peers = 2,
        .any_dns_peer = true,
        .self_position_by_hostname = 2,
    });
    defer a.free(findings);
    try std.testing.expect(has(findings, .hostname_position_mismatch));
    try std.testing.expectEqual(@as(?Severity, .err), severityOf(findings, .hostname_position_mismatch));
}

test "analyze: node_id 0 is out of range" {
    const a = std.testing.allocator;
    const findings = try analyze(a, .{
        .node_id = 0,
        .total_entries = 3,
        .self_skips = 0,
        .resulting_peers = 3,
        .any_dns_peer = true,
        .self_position_by_hostname = null,
    });
    defer a.free(findings);
    try std.testing.expectEqual(@as(?Severity, .err), severityOf(findings, .node_id_out_of_range));
}

test "analyze: node_id greater than cluster size is out of range" {
    const a = std.testing.allocator;
    const findings = try analyze(a, .{
        .node_id = 5,
        .total_entries = 3,
        .self_skips = 0,
        .resulting_peers = 3,
        .any_dns_peer = false,
        .self_position_by_hostname = null,
    });
    defer a.free(findings);
    try std.testing.expectEqual(@as(?Severity, .err), severityOf(findings, .node_id_out_of_range));
}

test "analyze: no self entry skipped warns about identity" {
    const a = std.testing.allocator;
    const findings = try analyze(a, .{
        .node_id = 2,
        .total_entries = 3,
        .self_skips = 0,
        .resulting_peers = 3,
        .any_dns_peer = true,
        .self_position_by_hostname = null,
    });
    defer a.free(findings);
    try std.testing.expectEqual(@as(?Severity, .warn), severityOf(findings, .self_not_skipped));
}

test "hostMatchesSelf: matches short pod name against FQDN peer" {
    try std.testing.expect(hostMatchesSelf("geode-0.geode.geode-qa.svc.cluster.local", "geode-0"));
    try std.testing.expect(hostMatchesSelf("geode-0.geode", "geode-0"));
    try std.testing.expect(!hostMatchesSelf("geode-10.geode", "geode-1"));
    try std.testing.expect(!hostMatchesSelf("geode-0.geode", ""));
}
