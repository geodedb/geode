// SONNY-6348 items 1, 4, 5 and 6 (items 2 and 3 were fixed earlier, in
// 71231a20 and c821008b):
//
//   (1) tde_key_manager.configureKMS returned configured=true for a symbolic
//       GEODE_KMS_URL ('aws', 'azure', 'gcp', 'hashicorp', 'local') after a
//       local AES-GCM round trip with a random key, and the server then
//       logged "KMS configured" without contacting any KMS;
//   (4) inline tests used fixed /tmp names (src/timeseries/timeseries.zig,
//       src/client/repl/repl_complete.zig; the other files the ticket names
//       were removed by SONNY-6298);
//   (5) tde.simulate_oltp_workload ignored concurrent_transactions, and
//       tde.encrypt_page_test / tde.encrypt_backup_test always reported id 1;
//   (6) procedure_access classified seven refused procedures as read-only;
//       fle_integration.lookupEncryptedField / matchesEncryptedField had no
//       caller, and configureField silently dropped `searchable`;
//       src/security/audit.zig imported audit_formatter and audit_sink
//       without using them.
//
// CANARY: REQ=REQ-SONNY-6348-KMS-TMP-SELFTESTS; FEATURE="TDE Procedures"; ASPECT=NoFabricatedKmsSelfTestTruth; STATUS=TESTED; TEST=tests/test_sonny6348_kms_tmp_selftests_stale.zig; OWNER=security; UPDATED=2026-11-12
const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const options = @import("sonny6348_options");
const util = @import("proto_test_util.zig");
const test_ports = @import("test_ports.zig");
const scratch = @import("test_scratch.zig");

const testing = std.testing;
const ast = geode.ast;
const storage_dispatch = geode.storage_dispatch;
const runtime_flags = geode.util_feature_flags;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const tde_key_hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn sleepMs(ms: u64) void {
    io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

fn monoMs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn readRepoFile(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(io(), abs, allocator, .limited(64 << 20));
}

// ---------------------------------------------------------------------------
// (1) symbolic GEODE_KMS_URL
// ---------------------------------------------------------------------------

test "SONNY-6348 (1) configureKMS does not report a symbolic provider name as a configured KMS" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for ([_][]const u8{ "aws", "azure", "gcp", "hashicorp", "local" }) |name| {
        const r = try geode.tde_stub.configureKMS(allocator, name);
        defer allocator.free(r.provider_name);
        defer allocator.free(r.endpoint);
        defer allocator.free(r.test_result);
        if (r.configured or std.mem.startsWith(u8, r.test_result, "SUCCESS")) {
            bad += 1;
            std.debug.print("SONNY-6348 (1): configureKMS(\"{s}\") reports configured={} \"{s}\" without contacting any KMS\n", .{ name, r.configured, r.test_result });
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6348 (1) configureKMS reports a reachable endpoint as reachable only, and an unreachable one as a failure" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    // A real TCP listener on a free loopback port.
    const fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    try testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    var sa = std.posix.sockaddr.in{ .family = std.posix.AF.INET, .port = 0, .addr = std.mem.nativeToBig(u32, 0x7F000001), .zero = .{0} ** 8 };
    try testing.expect(std.c.bind(fd, @ptrCast(&sa), @sizeOf(std.posix.sockaddr.in)) == 0);
    try testing.expect(std.c.listen(fd, 4) == 0);
    var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    try testing.expect(std.c.getsockname(fd, @ptrCast(&sa), &len) == 0);
    const port = std.mem.bigToNative(u16, sa.port);

    var buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{port});
    const r = try geode.tde_stub.configureKMS(allocator, url);
    defer allocator.free(r.provider_name);
    defer allocator.free(r.endpoint);
    defer allocator.free(r.test_result);
    try testing.expect(r.configured);
    try testing.expect(std.mem.indexOf(u8, r.test_result, "reachable") != null);

    _ = std.c.close(fd);
    const r2 = try geode.tde_stub.configureKMS(allocator, url);
    defer allocator.free(r2.provider_name);
    defer allocator.free(r2.endpoint);
    defer allocator.free(r2.test_result);
    try testing.expect(!r2.configured);
}

fn waitExit(pid: std.posix.pid_t, ms: u64) ?u32 {
    const deadline = monoMs() + ms;
    while (monoMs() < deadline) {
        var status: u32 = 0;
        const rc = std.os.linux.wait4(pid, &status, std.os.linux.W.NOHANG, null);
        if (rc == pid) return status;
        sleepMs(50);
    }
    return null;
}

test "SONNY-6348 (1) geode serve with a symbolic GEODE_KMS_URL refuses to start instead of logging 'KMS configured'" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var dir = try scratch.ScratchDir.create("sonny6348");
    defer dir.remove();
    const data_dir = try std.fs.path.join(allocator, &.{ dir.path(), "data" });
    defer allocator.free(data_dir);
    try std.Io.Dir.cwd().createDirPath(io(), data_dir);
    const log_path = try std.fs.path.join(allocator, &.{ dir.path(), "server.log" });
    defer allocator.free(log_path);

    const quic_port = try test_ports.freeUdpPort();
    var listen_buf: [32]u8 = undefined;
    const listen = try std.fmt.bufPrint(&listen_buf, "127.0.0.1:{d}", .{quic_port});
    var map = try std.Io.Threaded.global_single_threaded.environ.process_environ.createMap(allocator);
    try map.put("GEODE_ADMIN_USERNAME", util.DefaultAuth.username);
    try map.put("GEODE_ADMIN_PASSWORD", util.DefaultAuth.password);
    try map.put("GEODE_KMS_URL", "aws");
    const argv = [_][]const u8{ geode_test_bin.geode_exe, "serve", "--listen", listen, "--data-dir", data_dir, "--log-level=info" };

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    const log_file = try std.Io.Dir.cwd().createFile(io(), log_path, .{});
    const child = std.process.spawn(threaded.io(), .{
        .argv = &argv,
        .environ_map = &map,
        .stdin = .ignore,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
    }) catch |err| {
        log_file.close(io());
        map.deinit();
        threaded.deinit();
        return err;
    };
    log_file.close(io());
    var handle: util.ServerHandle = .{ .allocator = allocator, .threaded = threaded, .child = child, .env_map = map };
    defer handle.deinit();

    const pid = handle.child.id.?;
    const status = waitExit(pid, 120_000);
    if (status != null) handle.child.id = null; // reaped
    const text = try std.Io.Dir.cwd().readFileAlloc(io(), log_path, allocator, .limited(64 << 20));
    defer allocator.free(text);

    const exited_nonzero = if (status) |s| !(std.os.linux.W.IFEXITED(s) and std.os.linux.W.EXITSTATUS(s) == 0) else false;
    const claimed = std.mem.indexOf(u8, text, "KMS configured ") != null or std.mem.indexOf(u8, text, "\"KMS configured\"") != null or std.mem.indexOf(u8, text, "msg=\"KMS configured\"") != null;
    const ready = std.mem.indexOf(u8, text, "[startup] server ready") != null;
    if (!exited_nonzero or ready or claimed) {
        std.debug.print("SONNY-6348 (1): GEODE_KMS_URL=aws: exited non-zero: {}, server ready: {}, logged \"KMS configured\": {}\nserver log:\n{s}\n", .{ exited_nonzero, ready, claimed, text });
        return error.TestUnexpectedResult;
    }
}

// ---------------------------------------------------------------------------
// (4) fixed /tmp names in inline tests
// ---------------------------------------------------------------------------

test "SONNY-6348 (4) the inline tests use no fixed /tmp path" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for ([_][]const u8{ "src/timeseries/timeseries.zig", "src/client/repl/repl_complete.zig" }) |rel| {
        const src = try readRepoFile(allocator, rel);
        defer allocator.free(src);
        var lines = std.mem.splitScalar(u8, src, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            n += 1;
            if (std.mem.indexOf(u8, line, "\"/tmp") != null) {
                bad += 1;
                std.debug.print("SONNY-6348 (4): {s}:{d}: fixed /tmp path: {s}\n", .{ rel, n, std.mem.trim(u8, line, " ") });
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

// ---------------------------------------------------------------------------
// (5) the TDE self-test procedures report what they ran
// ---------------------------------------------------------------------------

fn callWith(arena: std.mem.Allocator, name: []const u8, ints: []const i64) !ast.CallProcedure {
    const callee = try arena.create(ast.Expr);
    callee.* = .{ .Ident = .{ .orig = name, .cnf = name } };
    const args = try arena.alloc(*ast.Expr, ints.len);
    for (ints, 0..) |v, i| {
        args[i] = try arena.create(ast.Expr);
        args[i].* = .{ .Int = v };
    }
    return .{ .procedure = .{ .Call = .{ .callee = callee, .args = args } } };
}

fn column(res: anytype, name: []const u8) ?usize {
    for (res.columns, 0..) |c, i| {
        if (std.mem.eql(u8, c, name)) return i;
    }
    return null;
}

fn enableTde() void {
    runtime_flags.global().tde.enableForTests();
    _ = setenv("GEODE_TDE_KEY", tde_key_hex, 1);
}

fn disableTde() void {
    _ = unsetenv("GEODE_TDE_KEY");
    runtime_flags.global().tde.clearTestOverride();
}

test "SONNY-6348 (5) tde.simulate_oltp_workload runs the requested number of concurrent transactions and refuses an out-of-range count" {
    enableTde();
    defer disableTde();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const name = "tde.simulate_oltp_workload";

    for ([_]i64{ 1, 4 }) |n| {
        const res = (try storage_dispatch.executeTde(arena, name, try callWith(arena, name, &.{ 2, n }))) orelse return error.ProcedureNotRecognized;
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        const row = res.rows[0];
        const ci = column(res, "concurrent_transactions") orelse {
            std.debug.print("SONNY-6348 (5): {s} reports no concurrent_transactions column (it ignored the argument)\n", .{name});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(n, row[ci].Int);
        const ti = column(res, "transactions") orelse return error.MissingColumn;
        try testing.expectEqual(@as(i64, 20), row[ti].Int); // duration_seconds * 10
        const tps = column(res, "tps_with_encryption") orelse return error.MissingColumn;
        try testing.expect(row[tps].Int > 0);
    }
    for ([_]i64{ 0, 65 }) |n| {
        try testing.expectError(error.InvalidArgs, storage_dispatch.executeTde(arena, name, try callWith(arena, name, &.{ 1, n })));
    }
}

test "SONNY-6348 (5) tde.encrypt_page_test and tde.encrypt_backup_test give each run its own id" {
    enableTde();
    defer disableTde();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][2][]const u8{ .{ "tde.encrypt_page_test", "page_id" }, .{ "tde.encrypt_backup_test", "backup_id" } }) |pc| {
        var ids: [3]i64 = undefined;
        for (&ids) |*id| {
            const res = (try storage_dispatch.executeTde(arena, pc[0], try callWith(arena, pc[0], &.{}))) orelse return error.ProcedureNotRecognized;
            const i = column(res, pc[1]) orelse return error.MissingColumn;
            id.* = res.rows[0][i].Int;
        }
        if (ids[0] == ids[1] or ids[1] == ids[2] or ids[0] == ids[2]) {
            std.debug.print("SONNY-6348 (5): {s} reported {s} {d}, {d}, {d} for three runs\n", .{ pc[0], pc[1], ids[0], ids[1], ids[2] });
            return error.TestUnexpectedResult;
        }
    }
}

// ---------------------------------------------------------------------------
// (6) stale and dead code
// ---------------------------------------------------------------------------

test "SONNY-6348 (6) the refused procedures are not classified read-only" {
    const allocator = testing.allocator;
    const src = try readRepoFile(allocator, "src/execution/procedure_access.zig");
    defer allocator.free(src);
    var bad: usize = 0;
    for ([_][]const u8{
        "audit.get_recent_events",
        "audit.verify_hash_chain",
        "audit.comprehensive_integrity_check",
        "tde.get_encryption_status",
        "tde.verify_encrypted_state",
        "tde.get_rotation_state",
        "tde.audit_plaintext_keys",
    }) |name| {
        const quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{name});
        defer allocator.free(quoted);
        if (std.mem.indexOf(u8, src, quoted) != null) {
            bad += 1;
            std.debug.print("SONNY-6348 (6): procedure_access lists the refused procedure {s} as read-only\n", .{name});
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6348 (6) the dead FLE lookups and unused audit imports are gone" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    const fle = try readRepoFile(allocator, "src/fle_integration.zig");
    defer allocator.free(fle);
    for ([_][]const u8{ "fn lookupEncryptedField", "fn matchesEncryptedField" }) |needle| {
        if (std.mem.indexOf(u8, fle, needle) != null) {
            bad += 1;
            std.debug.print("SONNY-6348 (6): src/fle_integration.zig still defines {s} (no caller)\n", .{needle});
        }
    }
    const audit = try readRepoFile(allocator, "src/security/audit.zig");
    defer allocator.free(audit);
    for ([_][]const u8{ "@import(\"audit_formatter.zig\")", "@import(\"audit_sink.zig\")" }) |needle| {
        if (std.mem.indexOf(u8, audit, needle) != null) {
            bad += 1;
            std.debug.print("SONNY-6348 (6): src/security/audit.zig still has the unused {s}\n", .{needle});
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6348 (6) geode.fle.configureField refuses searchable: true instead of dropping it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const name = "geode.fle.configurefield";
    const callee = try arena.create(ast.Expr);
    callee.* = .{ .Ident = .{ .orig = name, .cnf = name } };
    const t = try arena.create(ast.Expr);
    t.* = .{ .String = "Sonny6348" };
    const f = try arena.create(ast.Expr);
    f.* = .{ .String = "ssn" };
    const yes = try arena.create(ast.Expr);
    yes.* = .{ .Bool = true };
    const props = try arena.alloc(ast.Property, 1);
    props[0] = .{ .key = "searchable", .value = yes };
    const cfg = try arena.create(ast.Expr);
    cfg.* = .{ .Map = props };
    const args = try arena.alloc(*ast.Expr, 3);
    args[0] = t;
    args[1] = f;
    args[2] = cfg;
    const call: ast.CallProcedure = .{ .procedure = .{ .Call = .{ .callee = callee, .args = args } } };
    try testing.expectError(error.SearchableFieldsUnsupported, storage_dispatch.executeFle(arena, name, call));
}
