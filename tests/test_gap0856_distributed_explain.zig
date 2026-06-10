// CANARY: REQ=REQ-GAP-0856-DIST-EXPLAIN; FEATURE="DistributedExplainScope"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0856_distributed_explain.zig:1; OWNER=distributed; UPDATED=2026-06-10
//
// Regression tests for GAP-0856: "Distributed/federated query transport returns
// error.Unsupported for EXPLAIN and PROFILE."
//
// Decision (see src/distributed/distributed_explain.zig and
// docs/DISTRIBUTED_QUERY_COORDINATION.md): EXPLAIN/PROFILE are node-local only.
// On the wire they are dedicated ExplainPayload/ProfilePayload submessages, not
// row-shaped, and the federated QueryResults type (rows + schema) cannot carry
// them; there is also no coherent way to merge N independent remote plan trees.
// So the three distributed result consumers (federation.zig + the two
// query_transport.zig consumers) now reject a remote .explain/.profile payload
// with the structured, self-documenting DistributedExplainUnsupported error
// instead of the opaque error.Unsupported.
//
// This test pins the contract of the shared choke point those consumers call.
// It is stdlib-only (no QUIC/protobuf), mirroring the isolation strategy of
// src/distributed/test_query_transport_node_registry.zig.

const std = @import("std");
const de = @import("distributed_explain");

test "GAP-0856: explain payload is rejected with the documented structured error (not error.Unsupported)" {
    const result = de.rejectDistributedPlanPayload(.explain);
    try std.testing.expectEqual(
        de.DistributedExplainError.DistributedExplainUnsupported,
        result,
    );
}

test "GAP-0856: profile payload is rejected with the documented structured error" {
    const result = de.rejectDistributedPlanPayload(.profile);
    try std.testing.expectEqual(
        de.DistributedExplainError.DistributedExplainUnsupported,
        result,
    );
}

test "GAP-0856: the error name is part of the contract" {
    // If anyone renames the error, this fails to compile / mismatches —
    // intentional, the name is advertised in the docs and to operators.
    const E = de.DistributedExplainError;
    const e: E = E.DistributedExplainUnsupported;
    try std.testing.expectEqualStrings("DistributedExplainUnsupported", @errorName(e));
}

test "GAP-0856: unsupported_message names the node-local limitation and the EXPLAIN/PROFILE surface" {
    try std.testing.expect(std.mem.indexOf(u8, de.unsupported_message, "node-local") != null);
    try std.testing.expect(std.mem.indexOf(u8, de.unsupported_message, "EXPLAIN/PROFILE") != null);
}

test "GAP-0856: both plan payload kinds map to the same scope error" {
    try std.testing.expectEqual(
        de.rejectDistributedPlanPayload(.explain),
        de.rejectDistributedPlanPayload(.profile),
    );
}
