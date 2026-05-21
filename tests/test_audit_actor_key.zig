// CANARY: REQ=REQ-AUDIT-ACTOR-001; FEATURE="Audit Actor Canonical Key"; ASPECT=ActorFieldPresent; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
//
// Regression test for docs/audit-actor-key.md (filed against a Go server,
// reinterpreted here as Zig-side audit hardening). Pins the canonical
// `actor` field in writeCanonicalJson — the Geode-Zig audit emitter ALREADY
// uses a single canonical `actor` key (no `user`/`sub`/`actor` divergence).
//
// This test exists so that any future refactor of the canonical JSON writer
// that drops or renames the `actor` field will fail loudly.

const std = @import("std");
const testing = std.testing;
const rls = @import("rls");

const AuditEvent = rls.AuditLogger.AuditEvent;

// CANARY: REQ=REQ-AUDIT-ACTOR-001; FEATURE="Audit Actor Canonical Key"; ASPECT=ActorFieldPresent; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "writeCanonicalJson emits actor field with canonical \"user:<id>\" shape" {
    const allocator = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var ev = AuditEvent{
        .timestamp = 1700000000000,
        .event_type = .access_granted,
        .severity = .info,
        .tenant_id = null,
        .user_id = 1001,
        .session_id = null,
        .resource = .{ .type = "data", .id = "n1", .name = "n1", .graph = null, .table = null },
        .action = "read",
        .result = .success,
        .reason = null,
        .policy_id = null,
        .ip_address = null,
        .query_hash = null,
        .additional_context = null,
        .details = null,
        .seq_no = 42,
    };

    try AuditEvent.writeCanonicalJson(&aw.writer, "geode", &ev);

    const json = aw.written();
    // Canonical actor field is present, prefixed with "user:".
    try testing.expect(std.mem.indexOf(u8, json, "\"actor\":\"user:1001\"") != null);
}

// CANARY: REQ=REQ-AUDIT-ACTOR-001; FEATURE="Audit Actor Canonical Key"; ASPECT=NoLegacyAlias; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "writeCanonicalJson does NOT emit legacy aliases (user, sub) for the actor" {
    const allocator = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var ev = AuditEvent{
        .timestamp = 1700000000000,
        .event_type = .access_denied,
        .severity = .warning,
        .tenant_id = null,
        .user_id = 7,
        .session_id = null,
        .resource = .{ .type = "data", .id = "n1", .name = "n1", .graph = null, .table = null },
        .action = "write",
        .result = .failure,
        .reason = "policy_match_deny",
        .policy_id = null,
        .ip_address = null,
        .query_hash = null,
        .additional_context = null,
        .details = null,
        .seq_no = 1,
    };

    try AuditEvent.writeCanonicalJson(&aw.writer, "geode", &ev);

    const json = aw.written();
    // No legacy aliases — the bug doc forbids divergence across `user`/`sub`/`actor`.
    // The canonical writer must only emit `actor`, never `"user":` or `"sub":`
    // as the principal identifier. ("user:" inside the actor value is fine.)
    try testing.expect(std.mem.indexOf(u8, json, "\"user\":\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"sub\":") == null);
    // And actor IS present.
    try testing.expect(std.mem.indexOf(u8, json, "\"actor\":\"user:7\"") != null);
}
