// CANARY: REQ=REQ-SONNY-6342-TDE-NO-STUB-PROCEDURES; FEATURE="TDEProcedures"; ASPECT=NoFabricatedKeyManagement; STATUS=TESTED; TEST=tests/test_sonny6342_tde_stub_procedures.zig; OWNER=security; UPDATED=2026-11-12
//
// SONNY-6342: the tde.* key-management procedures were stubs that returned
// constants. `CALL tde.rotate_keys()` answered success=true with
// new_master_key_id "mk-00000002" and nothing rotated;
// `tde.initialize_key_hierarchy` answered "mk-00000001";
// `tde.get_encryption_status` answered enabled=true with TDE off;
// `tde.configure_kms` / `configure_external_kms` reported a configured,
// connection-verified KMS without contacting one; `tde.zeroize_keys`,
// `cleanup_key_hierarchy` and `test_key_zeroization` reported zeroized keys
// that were never the server's; `tde.audit_plaintext_keys` reported 0
// plaintext keys and 5 encrypted ones as constants; the rotation-schedule,
// access-control, KMS-failure and corrupted-key procedures returned
// hard-coded verdicts. Real key management is SONNY-6303.
//
// The contract:
//   - every such procedure fails with error.Unsupported (SQLSTATE 0A000),
//     with TDE on and a key loaded as well as with TDE off;
//   - the procedures that do run real cryptography on the server's TDE key
//     (encrypt_page, the round-trip, escrow, wrap/unwrap and attestation
//     self-tests) still answer (SONNY-6442: not measure_overhead);
//   - the dead fle_integration.computeBlindIndex (it called a nonexistent
//     BlindIndex.computeHash) and its only caller, the unreferenced
//     planner/rewrite.zig performFLERewrite, are gone (a source check).

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const ast = geode.ast;
const storage_dispatch = geode.storage_dispatch;
const runtime_flags = geode.util_feature_flags;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const tde_key_hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn noArgCall(arena: std.mem.Allocator, name: []const u8) !ast.CallProcedure {
    const callee = try arena.create(ast.Expr);
    callee.* = .{ .Ident = .{ .orig = name, .cnf = name } };
    return .{ .procedure = .{ .Call = .{ .callee = callee, .args = &.{} } } };
}

const refused_tde = [_][]const u8{
    "tde.initialize_key_hierarchy",
    "tde.rotate_keys",
    "tde.get_encryption_status",
    "tde.configure_kms",
    "tde.verify_encrypted_state",
    "tde.benchmark_encryption",
    "tde.test_key_rotation",
    "tde.configure_key_provider",
    "tde.configure_mock_kms",
    "tde.derive_data_key",
    "tde.derive_backup_key",
    "tde.test_roundtrip",
    "tde.zeroize_keys",
    "tde.verify_no_plaintext",
    "tde.test_access_control",
    "tde.configure_rotation_schedule",
    "tde.test_rotation_state_persistence",
    "tde.configure_adaptive_rotation",
    "tde.validate_overhead",
    "tde.benchmark_aead",
    "tde.simulate_oltp",
    "tde.test_kms_unavailable",
    "tde.test_corrupted_key",
    "tde.configure_provider",
    "tde.get_rotation_state",
    "tde.configure_rotation",
    "tde.test_key_zeroization",
    "tde.audit_plaintext_keys",
    "tde.test_key_access_control",
    "tde.configure_external_kms",
    "tde.test_privileged_unwrap",
    "tde.test_key_recovery",
    "tde.evaluate_rotation_schedule",
    "tde.test_kms_failure",
    "tde.test_corrupted_key_handling",
    "tde.cleanup_key_hierarchy",
    "tde.measure_overhead", // SONNY-6442: a memcpy-vs-AEAD timing
};

/// Procedures that run real cryptography on the server's TDE key.
const real_tde = [_][]const u8{
    "tde.test_encryption",
    "tde.test_decryption",
    "tde.test_key_escrow",
    "tde.test_transparent_encryption",
    "tde.encrypt_page_test",
    "tde.encrypt_backup_test",
    "tde.roundtrip_test",
    "tde.test_kms_wrap_unwrap",
    "tde.test_kms_attestation",
};

fn checkRefused(tde_on: bool) !usize {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bad: usize = 0;
    for (refused_tde) |name| {
        const call = try noArgCall(arena, name);
        if (storage_dispatch.executeTde(arena, name, call)) |maybe| {
            if (maybe) |res| {
                std.debug.print("SONNY-6342 (TDE {s}): {s} answered {d} row(s) instead of refusing\n", .{ if (tde_on) "on" else "off", name, res.rows.len });
            } else {
                std.debug.print("SONNY-6342: {s} is not a known procedure (want a clear unsupported error)\n", .{name});
            }
            bad += 1;
        } else |err| if (err != error.Unsupported) {
            std.debug.print("SONNY-6342 (TDE {s}): {s} failed with {s}, want Unsupported\n", .{ if (tde_on) "on" else "off", name, @errorName(err) });
            bad += 1;
        }
    }
    return bad;
}

test "SONNY-6342 tde key-management stubs are refused as unsupported with TDE on and a key loaded" {
    runtime_flags.global().tde.enableForTests();
    _ = setenv("GEODE_TDE_KEY", tde_key_hex, 1);
    defer {
        _ = unsetenv("GEODE_TDE_KEY");
        runtime_flags.global().tde.disableForTests();
    }
    try testing.expectEqual(@as(usize, 0), try checkRefused(true));
}

test "SONNY-6342 tde key-management stubs are refused as unsupported with TDE off" {
    runtime_flags.global().tde.disableForTests();
    try testing.expectEqual(@as(usize, 0), try checkRefused(false));
}

test "SONNY-6342 the tde procedures that run real cryptography on the server's key still answer" {
    runtime_flags.global().tde.enableForTests();
    _ = setenv("GEODE_TDE_KEY", tde_key_hex, 1);
    defer {
        _ = unsetenv("GEODE_TDE_KEY");
        runtime_flags.global().tde.disableForTests();
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (real_tde) |name| {
        const call = try noArgCall(arena, name);
        const res = (storage_dispatch.executeTde(arena, name, call) catch |err| {
            std.debug.print("SONNY-6342: {s} failed with {s}\n", .{ name, @errorName(err) });
            return err;
        }) orelse return error.ProcedureNotRecognized;
        try testing.expectEqual(@as(usize, 1), res.rows.len);
    }
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(fsIo(), path, allocator, .limited(16 << 20));
}

test "SONNY-6342 the dead blind-index predicate rewrite is removed" {
    const allocator = testing.allocator;
    var ok = true;
    for ([_]struct { path: []const u8, decl: []const u8 }{
        .{ .path = "src/fle_integration.zig", .decl = "fn computeBlindIndex(" },
        .{ .path = "src/planner/rewrite.zig", .decl = "fn performFLERewrite(" },
        .{ .path = "src/planner/rewrite.zig", .decl = "fn walkExprForFLE(" },
    }) |c| {
        // SONNY-6511 deleted src/planner/rewrite.zig entirely: a missing
        // file defines nothing.
        const src = readFileAlloc(allocator, c.path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(src);
        if (std.mem.indexOf(u8, src, c.decl) != null) {
            std.debug.print("SONNY-6342: {s} still defines `{s}` (dead: nothing calls it and it does not compile)\n", .{ c.path, c.decl });
            ok = false;
        }
    }
    try testing.expect(ok);
}
