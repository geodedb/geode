// CANARY: REQ=REQ-SONNY-6346-NO-SILENT-DEGRADE; FEATURE="Server Startup"; ASPECT=TenantRegistryDurableOrRefuse; STATUS=TESTED; TEST=tests/test_sonny6346_silent_degrade_audit_housekeeping.zig; OWNER=security; UPDATED=2026-11-12
//
// SONNY-6346: three silent degradations.
//   (1) When `<data dir>/tenants` could not be created, the tenant registry
//       logged a warning and ran in memory: every tenant created after that
//       was gone at the next restart. Since SONNY-6339 the server has one
//       resolved data directory and refuses to start without durable auth
//       state; the tenant registry is durable state too, so startup refuses.
//   (2) An audit record with more than 32 detail keys was written without
//       the extra keys (rls_core keys_buffer[32]): the record on disk, and
//       its hash, silently lost data. Every key is written.
//   (3) cleanupOldLogs scanned the WORKING directory for `audit.jsonl.<ts>`,
//       so the audit log's own rotated files were never removed, a log not
//       named audit.jsonl was never cleaned, and files in the working
//       directory could be deleted. It scans the log's own directory for
//       `<log file name>.<ms>`.
// (Item 4, the fixed /etc/geode/geode_audit.jsonl of audit.get_merkle_digests,
// is covered by tests/test_sonny6340_no_fabricated_procedures.zig.)

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const test_ports = @import("test_ports.zig");

const linux = std.os.linux;
const posix = std.posix;
const audit = geode.security.audit;
const tenant_registry = geode.tenant_registry;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn join(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

fn sleepMs(ms: u64) void {
    fsIo().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

fn pathExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(fsIo(), path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(fsIo(), path, .{});
    defer f.close(fsIo());
    try f.writeStreamingAll(fsIo(), bytes);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(fsIo(), path, allocator, .limited(16 << 20));
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

// ===========================================================================
// (1) the tenant registry is durable or startup refuses
// ===========================================================================

test "SONNY-6346 (1) a tenant registry whose <data dir>/tenants cannot be created is an error, not an in-memory registry" {
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6346-registry");
    defer root.remove();
    // A regular file where the registry directory must go.
    const tenants = try join(allocator, root.path(), "tenants");
    defer allocator.free(tenants);
    try writeFile(tenants, "not a directory\n");

    if (tenant_registry.TenantRegistry.initWithDataDir(allocator, root.path())) |reg_const| {
        var reg = reg_const;
        const durable = reg.dir_path != null;
        reg.deinit();
        std.debug.print("SONNY-6346: initWithDataDir returned a registry (durable={}) although {s} cannot be created\n", .{ durable, tenants });
        return error.TestUnexpectedResult;
    } else |_| {}
}

const Run = struct {
    code: ?u8,
    output: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.output);
    }
};

/// Run the geode binary until it exits or `timeout_s` passes (then it is
/// killed and `code` is null), output to a file.
fn runGeode(root: []const u8, argv: []const []const u8, timeout_s: i64) !Run {
    const allocator = testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const home = try join(allocator, root, "home");
    defer allocator.free(home);
    const tmp = try join(allocator, root, "tmp");
    defer allocator.free(tmp);
    const cwd = try join(allocator, root, "cwd");
    defer allocator.free(cwd);
    try std.Io.Dir.cwd().createDirPath(fsIo(), home);
    try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);
    try std.Io.Dir.cwd().createDir(fsIo(), tmp, std.Io.File.Permissions.fromMode(0o700));

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("HOME", home);
    try env.put("TMPDIR", tmp);
    try env.put("GEODE_ADMIN_PASSWORD", "Sonny6346-Admin-pw1x");

    const out_path = try join(allocator, root, "run.out");
    defer allocator.free(out_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
    defer out.close(fsIo());
    const child = try std.process.spawn(threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .{ .file = out },
        .stderr = .{ .file = out },
    });
    const pid = child.id.?;
    var status: u32 = 0;
    var exited = false;
    var waited_ms: i64 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        if (rc == @as(usize, @intCast(pid))) {
            exited = true;
            break;
        }
        if (waited_ms >= timeout_s * 1000) {
            posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            break;
        }
        sleepMs(100);
        waited_ms += 100;
    }
    const code: ?u8 = if (exited and (status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else null;
    return .{ .code = code, .output = try readFileAlloc(allocator, out_path) };
}

test "SONNY-6346 (1) a server whose tenant registry directory cannot be created refuses to start" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6346-server");
    defer root.remove();
    const data = try join(allocator, root.path(), "X");
    defer allocator.free(data);
    try std.Io.Dir.cwd().createDirPath(fsIo(), data);
    const tenants = try join(allocator, data, "tenants");
    defer allocator.free(tenants);
    try writeFile(tenants, "not a directory\n");

    var addr_buf: [32]u8 = undefined;
    const addr = try std.fmt.bufPrint(&addr_buf, "127.0.0.1:{d}", .{try test_ports.freeUdpPort()});
    const run = try runGeode(root.path(), &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data }, 60);
    defer run.deinit();
    const refused = run.code != null and run.code.? != 0;
    const named = std.ascii.indexOfIgnoreCase(run.output, "tenant") != null;
    if (!refused or !named) {
        std.debug.print("SONNY-6346: the server {s} with an uncreatable {s} (exit={?d}, output names the tenant registry: {}); output tail:\n{s}\n", .{
            if (run.code == null) "kept running (killed after 60 s)" else "exited",
            tenants,
            run.code,
            named,
            run.output[run.output.len -| 3000..],
        });
        return error.TestUnexpectedResult;
    }
    // Still a regular file: nothing replaced it.
    const st = try std.Io.Dir.cwd().statFile(fsIo(), tenants, .{ .follow_symlinks = false });
    try testing.expect(st.kind == .file);
}

// ===========================================================================
// (2) every detail key of an audit record is written
// ===========================================================================

test "SONNY-6346 (2) an audit record with more than 32 detail keys is written with every key" {
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6346-details");
    defer root.remove();
    const log_path = try join(allocator, root.path(), "audit.jsonl");
    defer allocator.free(log_path);

    const n_keys = 40;
    {
        var logger = try audit.AuditLogger.init(allocator, .{ .enabled = true, .file_path = log_path });
        defer logger.deinit();
        var details = std.StringHashMap([]const u8).init(allocator);
        defer {
            var it = details.iterator();
            while (it.next()) |e| {
                allocator.free(e.key_ptr.*);
                allocator.free(e.value_ptr.*);
            }
            details.deinit();
        }
        for (0..n_keys) |i| {
            const k = try std.fmt.allocPrint(allocator, "k{d:0>2}", .{i});
            errdefer allocator.free(k);
            const v = try std.fmt.allocPrint(allocator, "v{d}", .{i});
            errdefer allocator.free(v);
            try details.put(k, v);
        }
        var ev = audit.AuditEvent{
            .timestamp = 1_700_000_000_000,
            .event_type = .configuration_change,
            .severity = .info,
            .user_id = 1,
            .session_id = "s",
            .resource = .{ .type = "graph", .id = "g", .name = "g", .graph = "g", .table = null },
            .action = "MANY_DETAILS",
            .result = .success,
            .details = details,
        };
        try logger.appendAuditEvent(&ev);
    }

    const content = try readFileAlloc(allocator, log_path);
    defer allocator.free(content);
    var found = false;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "MANY_DETAILS") == null) continue;
        found = true;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const d = parsed.value.object.get("details") orelse return error.MissingDetails;
        const written = d.object.count();
        if (written != n_keys) {
            std.debug.print("SONNY-6346: the record was written with {d} of its {d} detail keys\n", .{ written, n_keys });
            return error.TestUnexpectedResult;
        }
        // Canonical order: sorted keys.
        var prev: []const u8 = "";
        for (d.object.keys()) |k| {
            try testing.expect(std.mem.lessThan(u8, prev, k));
            prev = k;
        }
    }
    try testing.expect(found);
}

// ===========================================================================
// (3) cleanupOldLogs cleans the log's own directory
// ===========================================================================

test "SONNY-6346 (3) cleanupOldLogs deletes the log's own expired rotated files, never files in the working directory" {
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6346-cleanup");
    defer root.remove();
    const logs = try join(allocator, root.path(), "logs");
    defer allocator.free(logs);
    const cwd = try join(allocator, root.path(), "cwd");
    defer allocator.free(cwd);
    try std.Io.Dir.cwd().createDirPath(fsIo(), logs);
    try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);

    const day_ms: i64 = 24 * 60 * 60 * 1000;
    const old_ts = nowMs() - 3 * day_ms;
    const new_ts = nowMs() - 1000;
    const log_path = try join(allocator, logs, "server-audit.jsonl");
    defer allocator.free(log_path);
    const old_rotated = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ log_path, old_ts });
    defer allocator.free(old_rotated);
    const new_rotated = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ log_path, new_ts });
    defer allocator.free(new_rotated);
    const not_ts = try std.fmt.allocPrint(allocator, "{s}.notatimestamp", .{log_path});
    defer allocator.free(not_ts);
    const other_log = try std.fmt.allocPrint(allocator, "{s}/audit.jsonl.{d}", .{ logs, old_ts });
    defer allocator.free(other_log);
    const cwd_decoy = try std.fmt.allocPrint(allocator, "{s}/audit.jsonl.{d}", .{ cwd, old_ts });
    defer allocator.free(cwd_decoy);
    for ([_][]const u8{ old_rotated, new_rotated, not_ts, other_log, cwd_decoy }) |p| try writeFile(p, "{}\n");

    var logger = try audit.AuditLogger.init(allocator, .{ .enabled = true, .file_path = log_path, .retention_days = 1 });
    defer logger.deinit();

    // Run it from `cwd`, the directory it used to scan.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = linux.getcwd(&cwd_buf, cwd_buf.len);
    const saved_len = std.mem.indexOfScalar(u8, &cwd_buf, 0) orelse return error.GetCwdFailed;
    var saved_z_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const saved_z = try std.fmt.bufPrintZ(&saved_z_buf, "{s}", .{cwd_buf[0..saved_len]});
    var cwd_z_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const cwd_z = try std.fmt.bufPrintZ(&cwd_z_buf, "{s}", .{cwd});
    if (linux.chdir(cwd_z.ptr) != 0) return error.ChdirFailed;
    const result = logger.cleanupOldLogs();
    _ = linux.chdir(saved_z.ptr);
    const r = try result;

    var ok = true;
    const expect = [_]struct { path: []const u8, kept: bool, what: []const u8 }{
        .{ .path = old_rotated, .kept = false, .what = "the log's rotated file past retention" },
        .{ .path = new_rotated, .kept = true, .what = "the log's rotated file within retention" },
        .{ .path = not_ts, .kept = true, .what = "a file of the log's name without a timestamp" },
        .{ .path = other_log, .kept = true, .what = "another log's rotated file beside it" },
        .{ .path = cwd_decoy, .kept = true, .what = "a file in the working directory" },
    };
    for (expect) |e| {
        if (pathExists(e.path) != e.kept) {
            std.debug.print("SONNY-6346: cleanupOldLogs {s} {s} ({s})\n", .{ if (e.kept) "deleted" else "kept", e.what, e.path });
            ok = false;
        }
    }
    if (r.files_deleted != 1) {
        std.debug.print("SONNY-6346: cleanupOldLogs reported {d} files deleted, want 1\n", .{r.files_deleted});
        ok = false;
    }
    try testing.expect(ok);
}
