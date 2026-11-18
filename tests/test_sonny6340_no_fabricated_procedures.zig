// CANARY: REQ=REQ-SONNY-6340-NO-FABRICATED-PROCEDURES; FEATURE="AuditProcedures"; ASPECT=NoFabricatedResults; STATUS=TESTED; TEST=tests/test_sonny6340_no_fabricated_procedures.zig; OWNER=security; UPDATED=2026-11-12
//
// SONNY-6340: audit.* and tde.* procedures returned results they never
// produced. `audit.compliance_verification` answered `compliant` with no
// check, `audit.export_for_verification` / `prepare_forensic_package` /
// `generate_compliance_report` named /tmp files they never wrote,
// `audit.log_lifecycle_event` said `logged=true` and logged nothing, the
// SIEM/anomaly/threat procedures counted hard-coded patterns, and
// `tde.create_encrypted_backup` / `tde.restore_with_keys` reported a backup
// (and 1000 restored records) of random bytes that were never written or
// read. `audit.get_merkle_digests` hashed a fixed /etc/geode path unrelated
// to the server's audit log (SONNY-6346 item 4), and the diagnostic audit
// logger was given the query's allocator although it lives for the process.
//
// The contract:
//   - a procedure that cannot do what it reports fails with
//     error.Unsupported (SQLSTATE 0A000), never a made-up row;
//   - `audit.get_merkle_digests` hashes the server's audit log (the file the
//     process-global logger writes) and refuses when there is none;
//   - `tde.test_encryption` / `tde.test_decryption` report success=false
//     when no encryption happened (TDE off or no key);
//   - the diagnostic logger never keeps the query's allocator.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const test_scratch = @import("test_scratch.zig");

const ast = geode.ast;
const Value = geode.value_types.Value;
const audit_dispatch = geode.audit_dispatch;
const storage_dispatch = geode.storage_dispatch;
const audit = geode.security.audit;
const runtime_flags = geode.util_feature_flags;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const tde_key_hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Every procedure under test runs with the working directory and the data
/// directory inside this process's scratch root: before the fix several of
/// them wrote files (audit_config.json, audit_*.jsonl, their keys) into the
/// working directory.
var sandbox_ready = false;
var data_dir_buf: [256]u8 = undefined;
var data_dir_len: usize = 0;

var root_z_buf: [256:0]u8 = undefined;
var root_z: [:0]const u8 = "";

/// Enter the sandbox: the working directory becomes the scratch root until
/// `leaveSandbox` (the test runner itself works relative to the original
/// one). Returns the data directory.
fn sandbox() ![]const u8 {
    if (!sandbox_ready) {
        const root = try test_scratch.processRoot();
        root_z = try std.fmt.bufPrintZ(&root_z_buf, "{s}", .{root});
        const dd = try std.fmt.bufPrint(&data_dir_buf, "{s}/data", .{root});
        try std.Io.Dir.cwd().createDirPath(fsIo(), dd);
        data_dir_len = dd.len;
        geode.graph_store.setDataDirOverride(testing.allocator, dd);
        sandbox_ready = true;
    }
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    if (@as(isize, @bitCast(n)) <= 0) return error.GetCwdFailed;
    const len = std.mem.indexOfScalar(u8, &cwd_buf, 0) orelse return error.GetCwdFailed;
    saved_cwd = try std.fmt.bufPrintZ(&saved_cwd_buf, "{s}", .{cwd_buf[0..len]});
    if (std.os.linux.chdir(root_z.ptr) != 0) return error.ChdirFailed;
    return data_dir_buf[0..data_dir_len];
}

var saved_cwd_buf: [std.fs.max_path_bytes:0]u8 = undefined;
var saved_cwd: [:0]const u8 = "";

fn leaveSandbox() void {
    _ = std.os.linux.chdir(saved_cwd.ptr);
}

fn noArgCall(arena: std.mem.Allocator, name: []const u8) !ast.CallProcedure {
    const callee = try arena.create(ast.Expr);
    callee.* = .{ .Ident = .{ .orig = name, .cnf = name } };
    return .{ .procedure = .{ .Call = .{ .callee = callee, .args = &.{} } } };
}

fn colIndex(columns: [][]const u8, name: []const u8) ?usize {
    for (columns, 0..) |c, i| if (std.mem.eql(u8, c, name)) return i;
    return null;
}

/// Free what a dispatch handler allocated for its result: column names,
/// string cells and the row arrays.
fn freeResult(allocator: std.mem.Allocator, res: geode.execution.ExecutionResult) void {
    for (res.columns) |c| allocator.free(c);
    allocator.free(res.columns);
    for (res.rows) |row| {
        for (row) |v| switch (v) {
            .Str => |s| allocator.free(s),
            else => {},
        };
        allocator.free(row);
    }
    allocator.free(res.rows);
    var flags = res.flags;
    flags.deinit(allocator);
}

test "SONNY-6340 the diagnostic audit logger does not keep the query's allocator" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    _ = try sandbox();
    defer leaveSandbox();
    // A query's allocator: everything it hands out must be returned once the
    // result is freed. Before the fix the diagnostic logger, which lives for
    // the process, was created with it (its digest buffer, its key paths).
    const qa = query_gpa.allocator();
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const call = try noArgCall(arena_state.allocator(), "audit.test_auth_categories");
        const res = (try audit_dispatch.execute(qa, "audit.test_auth_categories", call)) orelse return error.ProcedureNotRecognized;
        const ok_i = colIndex(res.columns, "success") orelse return error.MissingColumn;
        for (res.rows) |row| try testing.expect(row[ok_i] == .Bool and row[ok_i].Bool);
        freeResult(qa, res);
    }
    // Leaks are counted without tearing the allocator down: a logger that
    // kept it must not be left with freed memory for the rest of the run.
    const leaked = query_gpa.detectLeaks();
    if (leaked != 0) {
        std.debug.print("SONNY-6340: {d} allocation(s) from the query allocator outlived the procedure (the diagnostic logger kept it)\n", .{leaked});
        return error.TestUnexpectedResult;
    }
    _ = query_gpa.deinit();
}

/// The query allocator of the last test; process-global so a logger that
/// wrongly keeps it never points at freed allocator state.
var query_gpa: std.heap.DebugAllocator(.{}) = .init;

const refused_audit = [_][]const u8{
    "audit.configure",
    "audit.log_auth_event",
    "audit.log_lifecycle_event",
    "audit.get_recent_events",
    "audit.verify_hash_chain",
    "audit.comprehensive_integrity_check",
    "audit.test_command_categories",
    "audit.test_data_access_categories",
    "audit.configure_rotation",
    "audit.simulate_windows_eventlog",
    "audit.simulate_syslog_output",
    "audit.test_combined_output",
    "audit.test_siem_correlation",
    "audit.test_siem_alerts",
    "audit.generate_compliance_report",
    "audit.test_powershell_compatibility",
    "audit.test_rotation_continuity",
    "audit.configure_retention",
    "audit.detect_anomalies",
    "audit.extract_threat_indicators",
    "audit.detect_privilege_escalation",
    "audit.performance_test",
    "audit.memory_usage_test",
    "audit.concurrent_access_test",
    "audit.test_disk_space_handling",
    "audit.test_corruption_handling",
    "audit.test_invalid_config",
    "audit.export_for_verification",
    "audit.prepare_forensic_package",
    "audit.compliance_verification",
};

const refused_tde_backup = [_][]const u8{
    "tde.create_encrypted_backup",
    "tde.restore_with_keys",
    "tde.backup_encrypted",
    "tde.encrypt_backup",
    "tde.verify_backup_encryption",
    "tde.generate_key_manifest",
    "tde.restore_with_historical_keys",
};

test "SONNY-6340 audit procedures that cannot do what they report are refused as unsupported, never answered with a made-up row" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    _ = try sandbox();
    defer leaveSandbox();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bad: usize = 0;
    for (refused_audit) |name| {
        const call = try noArgCall(arena, name);
        if (audit_dispatch.execute(arena, name, call)) |maybe| {
            if (maybe) |res| {
                std.debug.print("SONNY-6340: {s} answered {d} row(s) instead of refusing\n", .{ name, res.rows.len });
            } else {
                std.debug.print("SONNY-6340: {s} is not a known procedure (want a clear unsupported error)\n", .{name});
            }
            bad += 1;
        } else |err| if (err != error.Unsupported) {
            std.debug.print("SONNY-6340: {s} failed with {s}, want Unsupported\n", .{ name, @errorName(err) });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6340 tde backup and restore procedures that never write or read a backup are refused, even with TDE on and a key loaded" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    _ = try sandbox();
    defer leaveSandbox();
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
    for (refused_tde_backup) |name| {
        const call = try noArgCall(arena, name);
        if (storage_dispatch.executeTde(arena, name, call)) |maybe| {
            if (maybe) |res| {
                std.debug.print("SONNY-6340: {s} answered {d} row(s) instead of refusing\n", .{ name, res.rows.len });
            } else {
                std.debug.print("SONNY-6340: {s} is not a known procedure (want a clear unsupported error)\n", .{name});
            }
            bad += 1;
        } else |err| if (err != error.Unsupported) {
            std.debug.print("SONNY-6340: {s} failed with {s}, want Unsupported\n", .{ name, @errorName(err) });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6340 tde.test_encryption and tde.test_decryption report success=false when nothing was encrypted" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    _ = try sandbox();
    defer leaveSandbox();
    runtime_flags.global().tde.disableForTests();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "tde.test_encryption", "tde.test_decryption" }) |name| {
        const call = try noArgCall(arena, name);
        const res = (try storage_dispatch.executeTde(arena, name, call)) orelse return error.ProcedureNotRecognized;
        const i = colIndex(res.columns, "success") orelse return error.MissingColumn;
        try testing.expect(res.rows.len == 1 and res.rows[0][i] == .Bool);
        if (res.rows[0][i].Bool) {
            std.debug.print("SONNY-6340: {s} reported success=true with TDE disabled (nothing was encrypted)\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

/// The Merkle root `audit.get_merkle_digests` must report for `content`:
/// SHA-256 of each non-empty line as the leaves, pairs hashed level by level,
/// an odd node paired with itself.
fn merkleRoot(allocator: std.mem.Allocator, content: []const u8) !struct { root: [32]u8, leaves: usize } {
    var level: std.ArrayList([32]u8) = .empty;
    defer level.deinit(allocator);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var h: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(line, &h, .{});
        try level.append(allocator, h);
    }
    const leaves = level.items.len;
    if (leaves == 0) return .{ .root = [_]u8{0} ** 32, .leaves = 0 };
    while (level.items.len > 1) {
        var next: std.ArrayList([32]u8) = .empty;
        errdefer next.deinit(allocator);
        var i: usize = 0;
        while (i < level.items.len) : (i += 2) {
            var s = std.crypto.hash.sha2.Sha256.init(.{});
            s.update(&level.items[i]);
            s.update(&level.items[if (i + 1 < level.items.len) i + 1 else i]);
            var h: [32]u8 = undefined;
            s.final(&h);
            try next.append(allocator, h);
        }
        level.deinit(allocator);
        level = next;
    }
    return .{ .root = level.items[0], .leaves = leaves };
}

test "SONNY-6340 audit.get_merkle_digests hashes the server's audit log, and refuses when the server writes none" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const data_dir = try sandbox();
    defer leaveSandbox();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const call = try noArgCall(arena, "audit.get_merkle_digests");

    // No server audit log: nothing to hash.
    audit.setGlobalAuditLogger(null);
    if (audit_dispatch.execute(arena, "audit.get_merkle_digests", call)) |maybe| {
        if (maybe) |res| std.debug.print("SONNY-6340: get_merkle_digests answered {d} row(s) with no server audit log\n", .{res.rows.len});
        return error.TestUnexpectedResult;
    } else |err| try testing.expectEqual(error.Unsupported, err);

    // The server's audit log, as main.zig opens it: <data dir>/audit.jsonl.
    const log_path = try std.fmt.allocPrint(testing.allocator, "{s}/audit.jsonl", .{data_dir});
    defer testing.allocator.free(log_path);
    const logger = try audit.AuditLogger.createHeap(std.heap.smp_allocator, .{ .enabled = true, .file_path = log_path });
    defer {
        audit.setGlobalAuditLogger(null);
        logger.deinit();
        std.heap.smp_allocator.destroy(logger);
    }
    audit.setGlobalAuditLogger(logger);
    for (0..5) |i| {
        var details = std.StringHashMap([]const u8).init(testing.allocator);
        defer details.deinit();
        var nbuf: [16]u8 = undefined;
        try details.put("n", try std.fmt.bufPrint(&nbuf, "{d}", .{i}));
        var ev = audit.AuditEvent{
            .timestamp = 1_700_000_000_000 + @as(i64, @intCast(i)),
            .event_type = .access_granted,
            .severity = .info,
            .user_id = 7,
            .session_id = "s",
            .resource = .{ .type = "graph", .id = "g", .name = "g", .graph = "g", .table = null },
            .action = "READ",
            .result = .success,
            .details = details,
        };
        try logger.appendAuditEvent(&ev);
    }

    const content = try std.Io.Dir.cwd().readFileAlloc(fsIo(), log_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(content);
    const want = try merkleRoot(testing.allocator, content);
    try testing.expect(want.leaves >= 5);

    const res = (try audit_dispatch.execute(arena, "audit.get_merkle_digests", call)) orelse return error.ProcedureNotRecognized;
    const root_i = colIndex(res.columns, "root_hash") orelse return error.MissingColumn;
    const leaves_i = colIndex(res.columns, "leaf_count") orelse return error.MissingColumn;
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    const got_leaves = res.rows[0][leaves_i].Int;
    if (got_leaves != @as(i64, @intCast(want.leaves))) {
        std.debug.print("SONNY-6340: get_merkle_digests hashed {d} lines, the server's audit log {s} has {d}\n", .{ got_leaves, log_path, want.leaves });
        return error.TestUnexpectedResult;
    }
    const want_hex = std.fmt.bytesToHex(want.root, .lower);
    try testing.expectEqualStrings(&want_hex, res.rows[0][root_i].Str);
}
