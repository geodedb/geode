//! GAP-0856: distributed EXPLAIN / PROFILE scope contract.
//!
//! EXPLAIN and PROFILE are **node-local only** in Geode. On the wire they are
//! NOT row-shaped — the server returns dedicated `ExplainPayload` /
//! `ProfilePayload` protobuf submessages (rich, structured plan trees with
//! per-operator totals, calibration, memory curves, planner estimates, …). The
//! federated/distributed transport carries `QueryResults`, which is strictly
//! `rows + schema`; it has no field able to represent a plan payload.
//!
//! Beyond the wire shape, there is no coherent merge semantics for combining N
//! independent remote plan trees (one per shard/remote node) into a single
//! authoritative EXPLAIN/PROFILE result: each remote optimizes against its own
//! local statistics, so a merged tree would be misleading. We therefore reject
//! distributed EXPLAIN/PROFILE with a single, self-documenting error rather than
//! the opaque `error.Unsupported`, and document the node-local scope in
//! `docs/DISTRIBUTED_QUERY_COORDINATION.md`.
//!
//! Clients that need a plan must issue EXPLAIN/PROFILE directly against the node
//! that owns the data (node-local execution), where the full structured payload
//! is produced.

const std = @import("std");

/// The structured, documented error returned when a remote/federated execution
/// yields an EXPLAIN or PROFILE payload. Distinct from the opaque
/// `error.Unsupported` so callers and operators can branch on / surface a clear
/// "node-local only" message. The error name is part of the contract.
pub const DistributedExplainError = error{
    DistributedExplainUnsupported,
};

/// Human-readable message naming the limitation and the supported path. Stable
/// string; asserted by the GAP-0856 regression test.
pub const unsupported_message =
    "EXPLAIN/PROFILE are node-local only: distributed/federated query transport " ++
    "cannot serialize or merge remote plan payloads. Issue EXPLAIN/PROFILE directly " ++
    "against the node that owns the data.";

/// Which structured payload variant the remote returned. Used purely for the
/// classifier's documentation/branching; both map to the same scope error.
pub const PlanPayloadKind = enum { explain, profile };

/// Single choke point every distributed result consumer calls when it sees an
/// `.explain` / `.profile` wire payload. Returns the documented structured
/// error instead of `error.Unsupported`. Pure (no allocation, no I/O), so it is
/// unit-testable in isolation without QUIC/protobuf dependencies.
pub fn rejectDistributedPlanPayload(kind: PlanPayloadKind) DistributedExplainError {
    _ = kind;
    return DistributedExplainError.DistributedExplainUnsupported;
}

test "rejectDistributedPlanPayload returns the documented structured error for explain" {
    try std.testing.expectEqual(
        DistributedExplainError.DistributedExplainUnsupported,
        rejectDistributedPlanPayload(.explain),
    );
}

test "rejectDistributedPlanPayload returns the documented structured error for profile" {
    try std.testing.expectEqual(
        DistributedExplainError.DistributedExplainUnsupported,
        rejectDistributedPlanPayload(.profile),
    );
}

test "unsupported_message names the node-local limitation" {
    try std.testing.expect(std.mem.indexOf(u8, unsupported_message, "node-local") != null);
    try std.testing.expect(std.mem.indexOf(u8, unsupported_message, "EXPLAIN/PROFILE") != null);
}
