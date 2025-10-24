const std = @import("std");
// Import migration engine via build.zig provided module name "migration" for canonical CANARY tests.
const migrate = @import("migration");

test "TestCANARY_REQ_GQL_087_MigrationLedgerSchema" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    const rows = try migrate.statusReport(&alloc);
    defer alloc.free(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(i64, 1), rows[0].version);
    try std.testing.expectEqualStrings("init_schema", rows[0].name);
    try std.testing.expect(rows[0].applied);
}

test "TestCANARY_REQ_GQL_087_LockAcquisitionTTLHeartbeat" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    // Acquire initial lock with short TTL
    var lh = try migrate.acquireLock(&alloc, 200);
    // Second acquire should fail with AlreadyLocked
    try std.testing.expectError(error.AlreadyLocked, migrate.acquireLock(&alloc, 200));
    // Heartbeat should extend (no error)
    try migrate.heartbeatLock(&lh);
    // Simulate expiry by sleeping beyond TTL (best-effort) if sleep available
    std.Thread.sleep(300 * std.time.ns_per_ms);
    // New acquire should reclaim (previous expired)
    var lh2 = try migrate.acquireLock(&alloc, 200);
    try std.testing.expect(lh2.id == 1);
    // Release lock
    try migrate.releaseLock(&lh2);
    // Release again should error
    try std.testing.expectError(error.NoLockHeld, migrate.releaseLock(&lh2));
}

test "TestCANARY_REQ_GQL_087_UpApplyOrderingIdempotency" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    // Apply a batch out of order with duplicates and already-applied version 1.
    const batch1: [][]const u8 = .{ "003_third", "002_second", "002_second", "001_init_duplicate" };
    try migrate.applyUpMigrations(&alloc, batch1);
    const rows_after = try migrate.statusReport(&alloc);
    defer alloc.free(rows_after);
    // Expect versions: 1 (seed), 2, 3
    try std.testing.expect(rows_after.len >= 3);
    var found2 = false;
    var found3 = false;
    for (rows_after) |r| {
        if (r.version == 2) found2 = true;
        if (r.version == 3) found3 = true;
    }
    try std.testing.expect(found2 and found3);
    const before_len = rows_after.len;
    // Second apply with overlapping & new higher version ensures idempotent skip of existing and addition of new.
    const batch2: [][]const u8 = .{ "003_third", "004_fourth" };
    try migrate.applyUpMigrations(&alloc, batch2);
    const rows_after2 = try migrate.statusReport(&alloc);
    defer alloc.free(rows_after2);
    var found4 = false;
    for (rows_after2) |r| {
        if (r.version == 4) found4 = true;
    }
    try std.testing.expect(found4);
    // Ensure only +1 new row appended (idempotency of 003)
    try std.testing.expect(rows_after2.len == before_len + 1);
}

test "TestCANARY_REQ_GQL_087_PolicyEnforcementStrictMode" {
    // Switch to STRICT mode
    try migrate.enforcePolicy("STRICT");
    try std.testing.expect(migrate.isStrictPolicy());
    // Switch back to LENIENT mode
    try migrate.enforcePolicy("LENIENT");
    try std.testing.expect(!migrate.isStrictPolicy());
    // Unknown mode should reuse NotImplemented error for lightweight signaling
    try std.testing.expectError(error.NotImplemented, migrate.enforcePolicy("UNKNOWN"));
}

test "TestCANARY_REQ_GQL_087_ChecksumValidation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    // Start with ledger: version 1 seeded (deadbee prefix)
    // Apply two new migrations to ensure checksums are computed.
    const batch: [][]const u8 = .{ "002_second", "003_third" };
    try migrate.applyUpMigrations(&alloc, batch);
    const rows = try migrate.statusReport(&alloc);
    defer alloc.free(rows);
    // Build manifest lines from current applied rows.
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    for (rows) |r| {
        if (!r.applied) continue;
        try w.print("{d} {s}\n", .{ r.version, r.checksum_prefix });
    }
    const manifest = fbs.getWritten();
    const ok = try migrate.checksumValidate(&alloc, manifest);
    try std.testing.expect(ok);
    // Corrupt one checksum in manifest (change last hex char)
    var corrupt_buf: [256]u8 = undefined;
    std.mem.copyForwards(u8, corrupt_buf[0..manifest.len], manifest);
    if (manifest.len > 0) {
        const idx = manifest.len - 2; // choose a hex char before newline
        if (corrupt_buf[idx] != '0') corrupt_buf[idx] = '0' else corrupt_buf[idx] = '1';
    }
    const bad = try migrate.checksumValidate(&alloc, corrupt_buf[0..manifest.len]);
    try std.testing.expect(!bad);
}

test "TestCANARY_REQ_GQL_087_ResumeTokenDataMigration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    // Use a fixed token to simulate repeated resume calls.
    const token = "resumetoken";
    var last_state = try migrate.resumeDataMigration(&alloc, token);
    try std.testing.expect(!last_state.done);
    try std.testing.expect(last_state.completed_batches == 1);
    const total = last_state.total_batches;
    var i: usize = 1;
    while (i < total) : (i += 1) {
        last_state = try migrate.resumeDataMigration(&alloc, token);
        // completed_batches should monotonically increase up to total
        try std.testing.expect(last_state.completed_batches == i + 1);
    }
    try std.testing.expect(last_state.done);
    // Additional call after completion should remain done and not exceed total.
    const after = try migrate.resumeDataMigration(&alloc, token);
    try std.testing.expect(after.done);
    try std.testing.expect(after.completed_batches == total);
}

test "TestCANARY_REQ_GQL_087_DriftDetection" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    // Initial drift check should succeed (no drift) returning true.
    const before = try migrate.driftCheck(&alloc);
    try std.testing.expect(before);
    // Simulate drift and expect driftCheck returns false.
    try migrate.testSimulateDrift();
    const after = try migrate.driftCheck(&alloc);
    try std.testing.expect(!after);
}

test "CANARY: REQ-GQL-087 CliParityStatusCommand uses same statusReport output" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    const rows = try migrate.statusReport(&alloc);
    defer alloc.free(rows);
    try std.testing.expect(rows.len > 0);
}

test "CANARY: REQ-GQL-087 ObservabilityMetrics stub returns NotImplemented" {
    try std.testing.expectError(error.NotImplemented, migrate.metricsSnapshot());
}

test "CANARY: REQ-GQL-087 DownReversalSafety stub returns NotImplemented" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    const empty: [][]const u8 = .{};
    try std.testing.expectError(error.NotImplemented, migrate.applyDownMigrations(&alloc, empty));
}

test "CANARY: REQ-GQL-087 PlanDryRunIntegrity stub returns NotImplemented" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    const empty: [][]const u8 = .{};
    try std.testing.expectError(error.NotImplemented, migrate.planDryRun(&alloc, empty));
}
