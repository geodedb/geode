// test_gap0890_rotation_policy.zig
//
// GAP-0890 regression: RotationPolicy is ENFORCED, not decorative.
//   (a) rotateNowAt() refuses with error.RotationPolicyRefused while the
//       active key is younger than policy.min_interval_secs, and the refusal
//       is audit-logged.
//   (b) max_age_secs forces rotation even when min_interval_secs has not
//       elapsed (deadline beats floor).
//   (c) rotateIfDue() — the operator-invoked scheduler tick with an injected
//       clock (now_epoch) — rotates exactly when scheduleRotation() says the
//       key is due, and marks the event method as .scheduled.
//   (d) The lazy re-wrap path is real crypto: a page encrypted under the old
//       key is re-encrypted by reencryptPage() and decrypts under the new
//       active key (AES-256-GCM round-trip), proving rotation + lazy
//       re-encryption work end to end. There is NO eager full-scan
//       re-encrypt — that residual is documented in docs/KMS_PROVIDER_SYSTEM.md.
//
// CANARY: REQ=REQ-KEY-ROTATION-002; FEATURE="SecureKeyRotation"; ASPECT=PolicyEnforcement; STATUS=TESTED; TEST=tests/test_gap0890_rotation_policy.zig; OWNER=security; UPDATED=2026-06-10
// CANARY: REQ=REQ-GQL-SEC-KEYROT-002; FEATURE="KeyRotationScheduling"; ASPECT=SchedulerTick; STATUS=TESTED; TEST=tests/test_gap0890_rotation_policy.zig; OWNER=security; UPDATED=2026-06-10

const std = @import("std");
const keyrot = @import("geode").security.key_rotation;

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

test "GAP-0890: rotateNowAt refuses before min_interval_secs and audit-logs the refusal" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var reg = keyrot.KeyRegistry.init(gpa.allocator());
    defer reg.deinit();

    const policy: keyrot.RotationPolicy = .{ .min_interval_secs = 100, .max_age_secs = 1000 };
    const k1 = try reg.loadActiveDataKey();
    const t0 = k1.created_unix_epoch;

    // Age 50 < min_interval 100 (and < max_age): refused.
    try std.testing.expectError(error.RotationPolicyRefused, reg.rotateNowAt(policy, t0 + 50));
    // No new key was created; active key unchanged.
    try std.testing.expectEqual(@as(usize, 1), reg.history.items.len);
    try std.testing.expectEqual(k1.id, reg.active.?.id);
    // Refusal is audit-logged as a failed rotation.
    try std.testing.expect(reg.audit_log.items.len >= 1);
    const last = reg.audit_log.items[reg.audit_log.items.len - 1];
    try std.testing.expectEqual(keyrot.RotationAuditEntry.AuditEventType.rotation_failed, last.event_type);
    try std.testing.expectEqual(keyrot.RotationAuditEntry.RotationStatus.failed, last.status);
}

test "GAP-0890: rotateNowAt rotates once min_interval_secs has elapsed" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var reg = keyrot.KeyRegistry.init(gpa.allocator());
    defer reg.deinit();

    const policy: keyrot.RotationPolicy = .{ .min_interval_secs = 100, .max_age_secs = 1000 };
    const k1 = try reg.loadActiveDataKey();
    const t0 = k1.created_unix_epoch;

    const ev = try reg.rotateNowAt(policy, t0 + 100);
    try std.testing.expectEqual(k1.id, ev.old_id);
    try std.testing.expectEqual(k1.id + 1, ev.new_id);
    try std.testing.expectEqual(keyrot.RotationEvent.Method.manual, ev.method);
    try std.testing.expectEqual(@as(usize, 2), reg.history.items.len);
    try std.testing.expectEqual(ev.new_id, reg.active.?.id);
    // New key material differs from the old key's.
    try std.testing.expect(!std.mem.eql(u8, &k1.material, &reg.active.?.material));
    // Success is audit-logged.
    const last = reg.audit_log.items[reg.audit_log.items.len - 1];
    try std.testing.expectEqual(keyrot.RotationAuditEntry.AuditEventType.rotation_completed, last.event_type);
}

test "GAP-0890: max_age_secs forces rotation even when min_interval has not elapsed" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var reg = keyrot.KeyRegistry.init(gpa.allocator());
    defer reg.deinit();

    // Misconfigured floor larger than deadline: the deadline wins.
    const policy: keyrot.RotationPolicy = .{ .min_interval_secs = 1000, .max_age_secs = 100 };
    const k1 = try reg.loadActiveDataKey();
    const t0 = k1.created_unix_epoch;

    // Age 50 < both: still refused.
    try std.testing.expectError(error.RotationPolicyRefused, reg.rotateNowAt(policy, t0 + 50));
    // Age 100 >= max_age: rotation proceeds despite min_interval = 1000.
    const ev = try reg.rotateNowAt(policy, t0 + 100);
    try std.testing.expectEqual(k1.id + 1, ev.new_id);
}

test "GAP-0890: first rotation with no active key is always allowed" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var reg = keyrot.KeyRegistry.init(gpa.allocator());
    defer reg.deinit();

    const policy: keyrot.RotationPolicy = .{ .min_interval_secs = 100, .max_age_secs = 1000 };
    const ev = try reg.rotateNowAt(policy, 12345);
    try std.testing.expectEqual(@as(u64, 0), ev.old_id);
    try std.testing.expectEqual(@as(u64, 1), ev.new_id);
}

test "GAP-0890: rotateIfDue scheduler tick rotates exactly when due (injected clock)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var reg = keyrot.KeyRegistry.init(gpa.allocator());
    defer reg.deinit();

    const policy: keyrot.RotationPolicy = .{ .min_interval_secs = 10, .max_age_secs = 100 };
    const k1 = try reg.loadActiveDataKey();
    const t0 = k1.created_unix_epoch;

    // Predicate parity (kept from the original schedule test).
    try std.testing.expect(!reg.scheduleRotation(policy, t0 + 5));
    try std.testing.expect(reg.scheduleRotation(policy, t0 + 11));

    // Tick before the interval: nothing happens.
    try std.testing.expect((try reg.rotateIfDue(policy, t0 + 5)) == null);
    try std.testing.expectEqual(@as(usize, 1), reg.history.items.len);

    // Tick after the interval: rotation fires, marked .scheduled.
    const ev = (try reg.rotateIfDue(policy, t0 + 11)) orelse return error.TestExpectedRotation;
    try std.testing.expectEqual(keyrot.RotationEvent.Method.scheduled, ev.method);
    try std.testing.expectEqual(k1.id + 1, ev.new_id);

    // Immediately after rotating, the fresh key is not due again.
    try std.testing.expect((try reg.rotateIfDue(policy, t0 + 12)) == null);
    try std.testing.expectEqual(@as(usize, 2), reg.history.items.len);
}

test "GAP-0890: lazy re-wrap is real AES-256-GCM - page decrypts under the new key after reencryptPage" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var reg = keyrot.KeyRegistry.init(alloc);
    defer reg.deinit();

    const aes_gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
    const old_key = try reg.loadActiveDataKey();

    // Encrypt a page under the OLD key in the registry's wire layout:
    // nonce(12) || ciphertext || tag(16).
    const plaintext = "GAP-0890 rotation policy round-trip page payload";
    const page = try alloc.alloc(u8, aes_gcm.nonce_length + plaintext.len + aes_gcm.tag_length);
    defer alloc.free(page);
    var nonce: [aes_gcm.nonce_length]u8 = undefined;
    compat_fillRandom(&nonce);
    @memcpy(page[0..aes_gcm.nonce_length], &nonce);
    var tag: [aes_gcm.tag_length]u8 = undefined;
    aes_gcm.encrypt(page[aes_gcm.nonce_length .. page.len - aes_gcm.tag_length], &tag, plaintext, "", nonce, old_key.material);
    @memcpy(page[page.len - aes_gcm.tag_length ..], &tag);

    // Rotate (forced) so the registry has [old, new] in history.
    const ev = try reg.rotateNowAt(.{ .min_interval_secs = 0 }, old_key.created_unix_epoch + 1);
    try std.testing.expectEqual(old_key.id + 1, ev.new_id);

    // Lazy re-wrap the page; it must now decrypt under the NEW active key.
    try reg.reencryptPage(7, page);

    const new_key = reg.active.?;
    const new_nonce = page[0..aes_gcm.nonce_length].*;
    const ct = page[aes_gcm.nonce_length .. page.len - aes_gcm.tag_length];
    const new_tag = page[page.len - aes_gcm.tag_length ..][0..aes_gcm.tag_length].*;
    const out = try alloc.alloc(u8, ct.len);
    defer alloc.free(out);
    try aes_gcm.decrypt(out, ct, new_tag, "", new_nonce, new_key.material);
    try std.testing.expectEqualStrings(plaintext, out);

    // And it must NOT decrypt under the old key any more.
    const out2 = try alloc.alloc(u8, ct.len);
    defer alloc.free(out2);
    try std.testing.expectError(error.AuthenticationFailed, aes_gcm.decrypt(out2, ct, new_tag, "", new_nonce, old_key.material));
}
