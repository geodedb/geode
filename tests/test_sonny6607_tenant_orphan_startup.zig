// SONNY-6607 (4): a server whose tenant registry holds a tenant with an
// unregistered parent refuses to start.
//
// At startup the tenant hierarchy is rebuilt from the registry, parents
// first (`main.zig` `rehydrateTenantDerivedState`). A tenant whose parent is
// not registered cannot be placed; that was a warning and the server ran
// with the tenant outside the hierarchy (its parent did not see its rows; a
// cascade drop of the parent missed it). The registry never writes such a
// record, so it is damage, and startup now fails closed, naming the tenant.
//
// A real `geode serve` (the built binary) on a data directory whose
// `tenants/registry.jsonl` holds one healthy tenant and one orphan.
//
// CANARY: REQ=REQ-SONNY-6607-TENANT-ORPHAN-STARTUP; FEATURE="TenantLifecycle"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6607_tenant_orphan_startup.zig; OWNER=security; UPDATED=2026-11-15

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const test_ports = @import("test_ports.zig");
const util = @import("proto_test_util.zig");

const linux = std.os.linux;
const posix = std.posix;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn sleepMs(ms: u64) void {
    fsIo().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

const Run = struct { code: ?u8, output: []u8 };

/// Run `argv` with output to a scratch file; kill it at `timeout_s` (code
/// null: still running, i.e. the server started).
fn runGeode(argv: []const []const u8, cwd: []const u8, timeout_s: i64) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("GEODE_ADMIN_PASSWORD", util.DefaultAuth.password);
    var rnd: [8]u8 = undefined;
    _ = linux.getrandom(&rnd, rnd.len, 0);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out_path = try std.fmt.bufPrint(&name_buf, "{s}/run6607-{x}.out", .{ try test_scratch.processRoot(), std.mem.readInt(u64, &rnd, .little) });
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .exclusive = true });
    defer {
        out.close(fsIo());
        std.Io.Dir.cwd().deleteFile(fsIo(), out_path) catch {};
    }
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
    const text = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, testing.allocator, .limited(8 << 20));
    return .{ .code = code, .output = text };
}

test "SONNY-6607 (4): a tenant registry with an orphan parent refuses startup, naming the tenant" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const root = try test_scratch.processRoot();
    var rnd: [8]u8 = undefined;
    _ = linux.getrandom(&rnd, rnd.len, 0);
    const data_dir = try std.fmt.allocPrint(testing.allocator, "{s}/orphan6607-{x}", .{ root, std.mem.readInt(u64, &rnd, .little) });
    defer testing.allocator.free(data_dir);
    defer std.Io.Dir.cwd().deleteTree(fsIo(), data_dir) catch {};
    const tenants_dir = try std.fmt.allocPrint(testing.allocator, "{s}/tenants", .{data_dir});
    defer testing.allocator.free(tenants_dir);
    try std.Io.Dir.cwd().createDirPath(fsIo(), tenants_dir);
    const reg_path = try std.fmt.allocPrint(testing.allocator, "{s}/registry.jsonl", .{tenants_dir});
    defer testing.allocator.free(reg_path);
    {
        const f = try std.Io.Dir.cwd().createFile(fsIo(), reg_path, .{});
        defer f.close(fsIo());
        var buf: [512]u8 = undefined;
        var w = f.writer(fsIo(), &buf);
        try w.interface.writeAll(
            "{\"tenant_id\":\"healthy6607\",\"parent\":null,\"created_at_ms\":1,\"active\":true,\"has_quota\":false}\n" ++
                "{\"tenant_id\":\"orphan6607\",\"parent\":\"gone6607\",\"created_at_ms\":2,\"active\":true,\"has_quota\":false}\n",
        );
        try w.interface.flush();
    }
    const addr = try util.formatAddr(testing.allocator, try test_ports.freeUdpPort());
    defer testing.allocator.free(addr);
    const r = try runGeode(&.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, root, 60);
    defer testing.allocator.free(r.output);
    const refused = r.code != null and r.code.? != 0;
    const named = std.mem.indexOf(u8, r.output, "orphan6607") != null;
    if (!refused or !named) std.debug.print("SONNY-6607 (4) orphan parent: exit={?d} (null: still running at 60 s)\n{s}\n", .{ r.code, r.output[0..@min(r.output.len, 4000)] });
    try testing.expect(refused);
    try testing.expect(named);
}
