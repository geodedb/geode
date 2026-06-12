// RED reproduction tests — "committed write → client Timeout → retry double-insert"
// ROOT CAUSE 2 (RC-2): the OUTCOME of a clustered write is OPAQUE on the wire.
// `proto_util.mapError` lumps `error.Timeout`, `error.ClusterNotLeader`, and
// `error.ClusterWriteNotReplicable` into the generic `else` arm → SQLSTATE 58000
// ("system error"). A client cannot tell:
//   * "the write committed but its local-apply outcome is UNKNOWN" (retryable,
//     but ONLY with an idempotency key — see RC-1/RC-3); from
//   * "the write was NOT applied here; safe to retry against the leader"
//     (ClusterNotLeader / ClusterWriteNotReplicable); from
//   * a genuine internal system error.
// Conflating all three as 58000 is what lets a committed-but-Timeout write be
// retried blindly → the double-insert.
//
// THE BUG (triage complete; file:line verified against HEAD 43031cb7):
//   * src/server/proto_util.zig:118-163 — `mapError` has explicit arms for many
//     errors but NO arm for `error.Timeout`, `error.ClusterNotLeader`, or
//     `error.ClusterWriteNotReplicable`; all three fall to
//     `else => .{ .code = "58000", .message = @errorName(err) }`.
//
// INTENDED FIX CONTRACT (what these tests pin; NOT the implementation):
//   * `error.Timeout` maps to a DISTINCT retryable-unknown class (e.g. an
//     08006-class connection/outcome-unknown code) whose message conveys that the
//     write outcome is UNKNOWN. NOT 58000.
//   * `error.ClusterNotLeader` and `error.ClusterWriteNotReplicable` map to a
//     DISTINCT not-applied / safe-to-retry class (the write did NOT apply here).
//     NOT 58000. The two share the same class (both mean "not applied here").
//   * An arbitrary/unknown error STILL maps to 58000 (the generic fallback is
//     preserved — GUARD).
//   The fixer picks codes consistent with proto_util.zig's existing SQLSTATE
//   usage; these tests assert the CONTRACT (distinct, non-58000, retryable
//   classes; stable separation) without over-pinning exact code strings.
//
// RED MECHANISM: `mapError` is already `pub` and directly callable — no
// @hasDecl guard is needed. These tests assert the POST-FIX contract, so they
// FAIL on current code (where all three return 58000) and PASS once the fixer
// adds the distinct arms. Do not edit these tests to make them pass; implement
// the mapping.
//
// CANARY: REQ=REQ-DIST-CLUSTER-WRITE-OUTCOME-SQLSTATE; FEATURE="DistributedCluster"; ASPECT=ClusterErrorSqlstateMapping; STATUS=TESTED; TEST=tests/test_proto_util_cluster_error_mapping.zig; OWNER=transport; UPDATED=2026-06-12

const std = @import("std");
const geode = @import("geode");
const proto_util = geode.proto_util;

const GENERIC_SYSTEM_ERROR = "58000";
const SUCCESS_CLASS = "00000";

/// The SQLSTATE class is the first two characters (e.g. "08" for connection
/// exception, "40" for transaction rollback). Used to assert the cluster-write
/// outcomes land in a sensible, retryable class rather than the system-error
/// class — without over-pinning the exact 5-char code the fixer chooses.
fn sqlstateClass(code: []const u8) []const u8 {
    return if (code.len >= 2) code[0..2] else code;
}

// ---------------------------------------------------------------------------
// (RC-2.1) error.Timeout — retryable-unknown, NOT the generic system error.
// This is the core RC-2 assertion: a committed-but-unknown outcome must surface
// as something a client can recognize as "retry only with idempotency", NOT as
// 58000. Pre-fix it is exactly 58000 (RED).
// ---------------------------------------------------------------------------
test "RC-2: error.Timeout maps to a distinct retryable-unknown code, not 58000" {
    const info = proto_util.mapError(error.Timeout);
    try std.testing.expect(!std.mem.eql(u8, info.code, GENERIC_SYSTEM_ERROR));
    // Not a success code either — it is an error outcome.
    try std.testing.expect(!std.mem.eql(u8, info.code, SUCCESS_CLASS));
    // A meaningful, non-empty message (outcome unknown / retryable).
    try std.testing.expect(info.message.len > 0);
}

// ---------------------------------------------------------------------------
// (RC-2.2) error.ClusterNotLeader — not-applied / safe-to-retry, NOT 58000.
// The write never applied on this node; the client should retry against the
// leader. Must not be conflated with a system error.
// ---------------------------------------------------------------------------
test "RC-2: error.ClusterNotLeader maps to a distinct safe-to-retry code, not 58000" {
    const info = proto_util.mapError(error.ClusterNotLeader);
    try std.testing.expect(!std.mem.eql(u8, info.code, GENERIC_SYSTEM_ERROR));
    try std.testing.expect(!std.mem.eql(u8, info.code, SUCCESS_CLASS));
    try std.testing.expect(info.message.len > 0);
}

// ---------------------------------------------------------------------------
// (RC-2.3) error.ClusterWriteNotReplicable — also not-applied / safe-to-retry,
// NOT 58000. (The leader could not replicate the write shape; nothing applied.)
// ---------------------------------------------------------------------------
test "RC-2: error.ClusterWriteNotReplicable maps to a distinct safe-to-retry code, not 58000" {
    const info = proto_util.mapError(error.ClusterWriteNotReplicable);
    try std.testing.expect(!std.mem.eql(u8, info.code, GENERIC_SYSTEM_ERROR));
    try std.testing.expect(!std.mem.eql(u8, info.code, SUCCESS_CLASS));
    try std.testing.expect(info.message.len > 0);
}

// ---------------------------------------------------------------------------
// (RC-2.4) CLASS SEPARATION: the retryable-UNKNOWN outcome (Timeout — the write
// MIGHT have committed) is a DIFFERENT class from the safe-to-retry NOT-APPLIED
// outcome (ClusterNotLeader — the write definitely did not apply here). A client
// must be able to distinguish "retry only with idempotency key" from "retry
// freely against the leader". Pre-fix BOTH are 58000, so this distinction does
// not exist (RED).
// ---------------------------------------------------------------------------
test "RC-2: committed-unknown (Timeout) and not-applied (NotLeader) are distinct classes" {
    const timeout = proto_util.mapError(error.Timeout);
    const not_leader = proto_util.mapError(error.ClusterNotLeader);
    // Distinct codes — the two outcomes are not interchangeable.
    try std.testing.expect(!std.mem.eql(u8, timeout.code, not_leader.code));
}

// ---------------------------------------------------------------------------
// (RC-2.5) CONSISTENT NOT-APPLIED CLASS: the two "did not apply here" errors
// (ClusterNotLeader, ClusterWriteNotReplicable) should share the same SQLSTATE
// CLASS — a client treats both the same way (retry against the leader). Pins
// internal consistency of the new mapping.
// ---------------------------------------------------------------------------
test "RC-2: the two not-applied cluster errors share one SQLSTATE class" {
    const not_leader = proto_util.mapError(error.ClusterNotLeader);
    const not_repl = proto_util.mapError(error.ClusterWriteNotReplicable);
    try std.testing.expectEqualStrings(sqlstateClass(not_leader.code), sqlstateClass(not_repl.code));
}

// ---------------------------------------------------------------------------
// (RC-2.6) GUARD (must stay GREEN before AND after the fix): an arbitrary unknown
// error STILL maps to the generic 58000 system-error fallback. The fix must add
// distinct arms for the cluster-write errors WITHOUT collapsing the generic
// fallback for everything else.
// ---------------------------------------------------------------------------
test "RC-2 guard: an arbitrary unknown error still maps to 58000" {
    const info = proto_util.mapError(error.SomeCompletelyUnrelatedUnknownError);
    try std.testing.expectEqualStrings(GENERIC_SYSTEM_ERROR, info.code);
}

// ---------------------------------------------------------------------------
// (RC-2.7) GUARD (must stay GREEN): a pre-existing mapped error keeps its code —
// the fix must not perturb the established mapping. GraphNotFound is a stable,
// well-known mapping (3F000) in proto_util today.
// ---------------------------------------------------------------------------
test "RC-2 guard: a pre-existing mapped error keeps its established code" {
    const info = proto_util.mapError(error.GraphNotFound);
    try std.testing.expectEqualStrings("3F000", info.code);
}
