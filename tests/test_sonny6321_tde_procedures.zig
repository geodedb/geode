// SONNY-6321: CANARY markers for the TDE self-test procedures and for the
// field-level-encryption pieces cited tests/test_tde_kms_integration.zig as
// their TESTED evidence. That file (built since SONNY-2441 as
// test-tde-kms-integration) tests TDEKeyManager only: it calls no tde.*
// procedure and no FLE code, so none of those claims had a test.
//
// Checked here:
//   (1) the TDE self-test procedures, through the executor's TDE dispatch
//       (storage_dispatch.executeTde, the path CALL takes): with TDE on and
//       a key loaded each reports real success (its success flags true, its
//       sizes non-zero); with TDE off none that uses the TDE key claims
//       success (the KMS attestation self test signs with a throwaway
//       Ed25519 key pair and needs no TDE key);
//   (2) no CANARY marker outside the KMS/TDEKeyManager modules cites
//       tests/test_tde_kms_integration.zig.
//
// CANARY: REQ=REQ-SONNY-6321-TDE-FLE-CANARY-EVIDENCE; FEATURE="TDEProcedures"; ASPECT=SelfTestProceduresAndHonestMarkers; STATUS=TESTED; TEST=tests/test_sonny6321_tde_procedures.zig; OWNER=tde; UPDATED=2026-11-12
const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const options = @import("sonny6321_options");

const ast = geode.ast;
const storage_dispatch = geode.storage_dispatch;
const runtime_flags = geode.util_feature_flags;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const tde_key_hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn noArgCall(arena: std.mem.Allocator, name: []const u8) !ast.CallProcedure {
    const callee = try arena.create(ast.Expr);
    callee.* = .{ .Ident = .{ .orig = name, .cnf = name } };
    return .{ .procedure = .{ .Call = .{ .callee = callee, .args = &.{} } } };
}

const Expect = struct {
    name: []const u8,
    /// Bool columns that report the self test's success.
    flags: []const []const u8,
    /// Int columns that must be non-zero when the self test ran.
    sizes: []const []const u8 = &.{},
    /// The self test uses the server's TDE key (false: it signs and
    /// verifies with a throwaway Ed25519 key pair, so it runs with TDE off).
    uses_tde_key: bool = true,
};

const procedures = [_]Expect{
    .{ .name = "tde.test_encryption", .flags = &.{"success"}, .sizes = &.{"bytes_encrypted"} },
    .{ .name = "tde.test_decryption", .flags = &.{"success"}, .sizes = &.{"bytes_decrypted"} },
    .{ .name = "tde.encrypt_page_test", .flags = &.{"integrity_check"}, .sizes = &.{"page_size_encrypted"} },
    .{ .name = "tde.encrypt_backup_test", .flags = &.{"integrity_verified"}, .sizes = &.{"backup_size"} },
    .{ .name = "tde.roundtrip_test", .flags = &.{"roundtrip_success"} },
    .{ .name = "tde.measure_overhead", .flags = &.{}, .sizes = &.{ "baseline_ops_per_sec", "encrypted_ops_per_sec" } },
    .{ .name = "tde.test_kms_wrap_unwrap", .flags = &.{ "wrap_success", "unwrap_success", "roundtrip_verified" } },
    .{ .name = "tde.test_kms_attestation", .flags = &.{ "attestation_valid", "signature_verified", "ed25519_verification", "tamper_detected" }, .uses_tde_key = false },
};

fn column(res: anytype, name: []const u8) ?usize {
    for (res.columns, 0..) |c, i| {
        if (std.mem.eql(u8, c, name)) return i;
    }
    return null;
}

fn intOf(v: anytype) ?i64 {
    return switch (v) {
        .Int => |i| i,
        else => null,
    };
}

test "SONNY-6321 (1) the TDE self-test procedures succeed through the executor with TDE on and a key loaded" {
    runtime_flags.global().tde.enableForTests();
    _ = setenv("GEODE_TDE_KEY", tde_key_hex, 1);
    defer {
        _ = unsetenv("GEODE_TDE_KEY");
        runtime_flags.global().tde.disableForTests();
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bad: usize = 0;
    for (procedures) |p| {
        const res = (try storage_dispatch.executeTde(arena, p.name, try noArgCall(arena, p.name))) orelse return error.ProcedureNotRecognized;
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        const row = res.rows[0];
        for (p.flags) |f| {
            const i = column(res, f) orelse return error.MissingColumn;
            if (row[i] != .Bool or !row[i].Bool) {
                bad += 1;
                std.debug.print("SONNY-6321: {s}: {s} is not true with TDE on\n", .{ p.name, f });
            }
        }
        for (p.sizes) |s| {
            const i = column(res, s) orelse return error.MissingColumn;
            const n = intOf(row[i]) orelse {
                bad += 1;
                std.debug.print("SONNY-6321: {s}: {s} is not a number\n", .{ p.name, s });
                continue;
            };
            if (n <= 0) {
                bad += 1;
                std.debug.print("SONNY-6321: {s}: {s}={d} with TDE on\n", .{ p.name, s, n });
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6321 (1) with TDE off no TDE self-test procedure claims success" {
    runtime_flags.global().tde.disableForTests();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bad: usize = 0;
    for (procedures) |p| {
        if (!p.uses_tde_key) continue;
        const maybe = storage_dispatch.executeTde(arena, p.name, try noArgCall(arena, p.name)) catch continue; // refused: no claim
        const res = maybe orelse return error.ProcedureNotRecognized;
        for (res.rows) |row| {
            for (p.flags) |f| {
                const i = column(res, f) orelse return error.MissingColumn;
                if (row[i] == .Bool and row[i].Bool) {
                    bad += 1;
                    std.debug.print("SONNY-6321: {s}: {s}=true with TDE off\n", .{ p.name, f });
                }
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6321 (2) no CANARY outside the KMS/TDEKeyManager modules cites tests/test_tde_kms_integration.zig" {
    const allocator = testing.allocator;
    const src_abs = try std.fs.path.join(allocator, &.{ options.repo_root, "src" });
    defer allocator.free(src_abs);
    var dir = try std.Io.Dir.cwd().openDir(io(), src_abs, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var bad: usize = 0;
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, "security/tde_kms_integration.zig") or std.mem.eql(u8, entry.path, "security/kms.zig")) continue;
        const text = dir.readFileAlloc(io(), entry.path, allocator, .limited(64 << 20)) catch continue;
        defer allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            n += 1;
            if (std.mem.indexOf(u8, line, "CANARY:") == null) continue;
            if (std.mem.indexOf(u8, line, "tests/test_tde_kms_integration.zig") != null) {
                bad += 1;
                std.debug.print("SONNY-6321: src/{s}:{d} cites tests/test_tde_kms_integration.zig, which does not exercise it\n", .{ entry.path, n });
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}
