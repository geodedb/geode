// GAP-0884: MFA step-up operation classification.
//
// requireStepUp() previously used substring checks ("admin"/"write" anywhere
// in the action string) to decide whether a privileged action demands a fresh
// MFA step-up. That misclassifies in both directions:
//   - a read-only operation whose name merely CONTAINS "admin"
//     (e.g. "read_admin_dashboard_summary") was forced to step up;
//   - a privileged operation with a bland name (e.g. the FLE catalog
//     mutator "geode.fle.configureField") required NO step-up at all.
//
// These tests pin the explicit OperationClass-based classification:
// real operation identifiers (procedure names, auth DDL handler names,
// legacy session-action ids) map to read / write / admin / security_admin,
// and unknown identifiers fail closed (classified as write => step-up).
//
// CANARY: REQ=REQ-SEC-MFA-STEPUP-CLASS-001; FEATURE="MFA step-up operation classification"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_gap0884_stepup_classification.zig; OWNER=security; UPDATED=2026-06-10

const std = @import("std");
const auth = @import("geode_auth");

fn makeSession(sm: *auth.SecurityManager) ![]const u8 {
    // geodeSecure passphrase policy: >=20 chars, >=3 words, upper+lower.
    const uid = try sm.createUser("gap0884", "gap0884@example.com", "Gap Stepup Classification Passphrase");
    return try sm.createSession(uid);
}

test "GAP-0884 negative: read-only op containing 'admin' must NOT require step-up" {
    const alloc = std.testing.allocator;
    // initEmpty: skip default-admin bootstrap (its auto-generated lowercase-hex
    // password fails the uppercase policy in a clean test env; see inline
    // "deinit releases hydrated runtime state" test for the same pattern).
    var sm = try auth.SecurityManager.initEmpty(alloc);
    defer sm.deinit();
    const token = try makeSession(&sm);

    // Substring logic flagged this as privileged because it contains "admin".
    try std.testing.expect(!sm.requireStepUp(token, "read_admin_dashboard_summary"));
    // Plain read identifiers stay step-up free.
    try std.testing.expect(!sm.requireStepUp(token, "read_graph"));
}

test "GAP-0884 negative: privileged op with bland name MUST require step-up" {
    const alloc = std.testing.allocator;
    // initEmpty: skip default-admin bootstrap (its auto-generated lowercase-hex
    // password fails the uppercase policy in a clean test env; see inline
    // "deinit releases hydrated runtime state" test for the same pattern).
    var sm = try auth.SecurityManager.initEmpty(alloc);
    defer sm.deinit();
    const token = try makeSession(&sm);

    // FLE catalog mutation — no "admin"/"write" substring, but security-admin class.
    try std.testing.expect(sm.requireStepUp(token, "geode.fle.configureField"));
    // Auth DDL handlers (the real geode.auth.* dispatch names).
    try std.testing.expect(sm.requireStepUp(token, "geode.auth.user_create"));
    try std.testing.expect(sm.requireStepUp(token, "geode.auth.grant"));
    try std.testing.expect(sm.requireStepUp(token, "geode.auth.mfa_disable"));
    try std.testing.expect(sm.requireStepUp(token, "geode.auth.apikey_create"));
}

test "GAP-0884: read-only procedures never require step-up" {
    const alloc = std.testing.allocator;
    // initEmpty: skip default-admin bootstrap (its auto-generated lowercase-hex
    // password fails the uppercase policy in a clean test env; see inline
    // "deinit releases hydrated runtime state" test for the same pattern).
    var sm = try auth.SecurityManager.initEmpty(alloc);
    defer sm.deinit();
    const token = try makeSession(&sm);

    try std.testing.expect(!sm.requireStepUp(token, "geode.fts.search"));
    try std.testing.expect(!sm.requireStepUp(token, "geode.ts.range"));
    try std.testing.expect(!sm.requireStepUp(token, "geode.auth.user_list"));
    try std.testing.expect(!sm.requireStepUp(token, "geode.fle.listEncryptedFields"));
    try std.testing.expect(!sm.requireStepUp(token, "db.labels"));
}

test "GAP-0884: unknown operations fail closed (step-up required)" {
    const alloc = std.testing.allocator;
    // initEmpty: skip default-admin bootstrap (its auto-generated lowercase-hex
    // password fails the uppercase policy in a clean test env; see inline
    // "deinit releases hydrated runtime state" test for the same pattern).
    var sm = try auth.SecurityManager.initEmpty(alloc);
    defer sm.deinit();
    const token = try makeSession(&sm);

    // Never-seen identifier, no privileged-looking words at all.
    try std.testing.expect(sm.requireStepUp(token, "frobnicate_widgets"));
    // Unknown dotted procedure namespace.
    try std.testing.expect(sm.requireStepUp(token, "geode.mystery.op"));
    // Unknown session token always demands step-up / re-auth.
    try std.testing.expect(sm.requireStepUp("no-such-session", "read_graph"));
}

test "GAP-0884: elevation window still suppresses step-up, expiry restores it" {
    const alloc = std.testing.allocator;
    // initEmpty: skip default-admin bootstrap (its auto-generated lowercase-hex
    // password fails the uppercase policy in a clean test env; see inline
    // "deinit releases hydrated runtime state" test for the same pattern).
    var sm = try auth.SecurityManager.initEmpty(alloc);
    defer sm.deinit();
    const token = try makeSession(&sm);

    try std.testing.expect(sm.requireStepUp(token, "geode.fle.configureField"));
    try sm.markStepUp(token, 60_000);
    try std.testing.expect(!sm.requireStepUp(token, "geode.fle.configureField"));

    // Force elevation expiry (no clock mock available; epoch 1ms is always past).
    var sess = sm.sessions.getPtr(token).?;
    sess.elevation_expires_at = 1;
    try std.testing.expect(sm.requireStepUp(token, "geode.fle.configureField"));
}

test "GAP-0884: classifyOperation maps real identifiers to explicit classes" {
    // read
    try std.testing.expectEqual(auth.OperationClass.read, auth.classifyOperation("geode.fts.search"));
    try std.testing.expectEqual(auth.OperationClass.read, auth.classifyOperation("geode.ts.sample_by"));
    try std.testing.expectEqual(auth.OperationClass.read, auth.classifyOperation("geode.auth.role_list"));
    try std.testing.expectEqual(auth.OperationClass.read, auth.classifyOperation("read_admin_dashboard_summary"));
    // case-insensitive (storage_dispatch lowercases FLE read names)
    try std.testing.expectEqual(auth.OperationClass.read, auth.classifyOperation("geode.fle.getfieldconfig"));

    // write
    try std.testing.expectEqual(auth.OperationClass.write, auth.classifyOperation("geode.ts.insert"));
    try std.testing.expectEqual(auth.OperationClass.write, auth.classifyOperation("geode.ts.insert_many"));

    // admin (legacy session-action identifiers)
    try std.testing.expectEqual(auth.OperationClass.admin, auth.classifyOperation("admin_panel"));
    try std.testing.expectEqual(auth.OperationClass.admin, auth.classifyOperation("admin_delete_user"));

    // security_admin (auth DDL / FLE / RLS / TDE namespaces)
    try std.testing.expectEqual(auth.OperationClass.security_admin, auth.classifyOperation("geode.fle.configureField"));
    try std.testing.expectEqual(auth.OperationClass.security_admin, auth.classifyOperation("geode.auth.user_create"));
    try std.testing.expectEqual(auth.OperationClass.security_admin, auth.classifyOperation("geode.auth.revoke"));
    try std.testing.expectEqual(auth.OperationClass.security_admin, auth.classifyOperation("geode.rls.create_deny_policy"));
    try std.testing.expectEqual(auth.OperationClass.security_admin, auth.classifyOperation("tde.rotate_master_key"));

    // unknown => fail-closed write
    try std.testing.expectEqual(auth.OperationClass.write, auth.classifyOperation("frobnicate_widgets"));
    try std.testing.expectEqual(auth.OperationClass.write, auth.classifyOperation(""));
}

test "GAP-0884: step-up policy per class (read exempt, everything else steps up)" {
    try std.testing.expect(!auth.operationRequiresStepUp(.read));
    try std.testing.expect(auth.operationRequiresStepUp(.write));
    try std.testing.expect(auth.operationRequiresStepUp(.admin));
    try std.testing.expect(auth.operationRequiresStepUp(.security_admin));
}
