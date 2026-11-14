// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6550: geode-client-zig v0.3.17 reads DSN credentials by the rules
// of geode's src/client/dsn_credentials.zig (SONNY-6544) and exposes them as
// `config.redact`. geode follows up:
//
// - `geode.dsn_credentials` is the library's implementation, not a second
//   copy of the same rules (the copies could drift, and geode's
//   `percentDecode` decoded into a buffer the size of the input and then
//   `realloc`ed it, which can free a copy of the credential that nobody
//   zeroes);
// - a Config built in code with port 0 is refused by `GeodeClient.connect`
//   (the CLI and backup build their Config in code), so geode's own port-0
//   check in the MCP endpoint parser is gone;
// - `endpointErrorMessage` names an out-of-range timeout and a fragment;
// - the CLI's `--dsn` percent-decodes the graph path like the library
//   (`/g%5F6550` binds graph `g_6550`), against a real server.
//
// CANARY: REQ=REQ-SONNY-6550-DSN-RULES; FEATURE="DSN credentials"; ASPECT=OneImplementation; STATUS=TESTED; TEST=tests/test_sonny6550_dsn_rules.zig; OWNER=cli; UPDATED=2026-11-14

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const util = @import("proto_test_util.zig");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const dsn_credentials = geode.dsn_credentials;
const zig_client = geode.zig_client;
const redact = zig_client.config.redact;
const bridge = geode.zig_quic_bridge;

/// The same function: same type and same address.
fn sameFn(a: anytype, b: anytype) bool {
    if (@TypeOf(a) != @TypeOf(b)) return false;
    return a == b;
}

test "SONNY-6550: geode.dsn_credentials is geode-client-zig's config.redact" {
    try testing.expect(dsn_credentials.Credentials == redact.Credentials);
    try testing.expect(dsn_credentials.Authority == redact.Authority);
    try testing.expect(dsn_credentials.Redacted == redact.Redacted);
    try testing.expect(sameFn(&dsn_credentials.splitAuthority, &redact.splitAuthority));
    try testing.expect(sameFn(&dsn_credentials.decodeUserinfo, &redact.decodeUserinfo));
    try testing.expect(sameFn(&dsn_credentials.percentDecode, &redact.percentDecode));
    try testing.expect(sameFn(&dsn_credentials.redacted, &redact.redacted));
    try testing.expect(sameFn(&dsn_credentials.isSecretKey, &redact.isSecretKey));
    try testing.expectEqualStrings(redact.redacted_marker, dsn_credentials.redacted_marker);
}

/// Counts what an allocation sequence does, over `testing.allocator`.
const Recorder = struct {
    backing: std.mem.Allocator,
    allocs: usize = 0,
    last_alloc_len: usize = 0,
    resizes: usize = 0,
    frees: usize = 0,

    fn allocator(self: *Recorder) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        self.last_alloc_len = len;
        return self.backing.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.resizes += 1;
        return self.backing.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.resizes += 1;
        return self.backing.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.backing.rawFree(memory, alignment, ra);
    }
};

test "SONNY-6550: decoding a credential allocates it once at its exact size and frees no copy" {
    for ([_]struct { []const u8, []const u8 }{
        .{ "p%40ss%3Aword", "p@ss:word" },
        .{ "%e2%9c%93", "\u{2713}" },
        .{ "plain", "plain" },
    }) |c| {
        var rec: Recorder = .{ .backing = testing.allocator };
        const out = try dsn_credentials.percentDecode(rec.allocator(), c[0]);
        const allocs = rec.allocs;
        const resizes = rec.resizes;
        const frees = rec.frees;
        const alloc_len = rec.last_alloc_len;
        const ok = std.mem.eql(u8, c[1], out);
        std.crypto.secureZero(u8, out);
        rec.allocator().free(out);
        try testing.expect(ok);
        testing.expect(allocs == 1 and resizes == 0 and frees == 0 and alloc_len == c[1].len) catch |err| {
            std.debug.print("percentDecode(\"{s}\"): {d} allocs (last {d} bytes), {d} resizes, {d} frees; want 1 alloc of {d} bytes\n", .{ c[0], allocs, alloc_len, resizes, frees, c[1].len });
            return err;
        };
    }

    // A malformed escape allocates nothing at all.
    var rec: Recorder = .{ .backing = testing.allocator };
    try testing.expectError(error.InvalidPercentEncoding, dsn_credentials.percentDecode(rec.allocator(), "s3cret%G0"));
    try testing.expectEqual(@as(usize, 0), rec.allocs);
}

test "SONNY-6550: a client Config built in code with port 0 is refused by connect" {
    // The CLI (--server / --dsn), backup and the REPL build their Config in
    // code through zig_quic_bridge, not through parseDSN.
    var client = try bridge.initClient(testing.allocator, "127.0.0.1", 0, .{ .insecure = true }, null, null);
    defer client.deinit();
    try testing.expectError(error.InvalidPort, client.connect());
}

test "SONNY-6550: endpointErrorMessage names an out-of-range timeout and a fragment" {
    const timeout_msg = bridge.endpointErrorMessage(error.TimeoutOutOfRange) orelse return error.TimeoutOutOfRangeUnmapped;
    try testing.expect(std.mem.startsWith(u8, timeout_msg, "Invalid Geode endpoint DSN: the timeout is out of range"));
    const fragment_msg = bridge.endpointErrorMessage(error.DsnFragment) orelse return error.DsnFragmentUnmapped;
    try testing.expect(std.mem.startsWith(u8, fragment_msg, "Invalid Geode endpoint DSN: a fragment"));

    // The library's strict parser refuses connect_timeout seconds whose
    // milliseconds overflow (it panicked before v0.3.17); the message does
    // not hold the DSN.
    try testing.expectError(error.TimeoutOutOfRange, zig_client.config.parseDSNStrict(testing.allocator, "quic://u:s3cret@h:1?connect_timeout=5000000"));
    try testing.expect(std.mem.indexOf(u8, timeout_msg, "s3cret") == null);
}

// --- the CLI's --dsn graph path, against a real server -----------------

const password = "Oscar6550 Papa6550 Quebec6550 Romeo6550";
const password_encoded = "Oscar6550%20Papa6550%20Quebec6550%20Romeo6550";

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Run = struct {
    code: ?u8,
    output: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.output);
    }

    fn has(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.output, needle) != null;
    }

    fn dump(self: Run, label: []const u8) void {
        std.debug.print("\nSONNY-6550 {s}: exit={?d}\n--- output ---\n{s}\n--- end ---\n", .{ label, self.code, self.output });
    }
};

/// Run `argv` (HOME is a scratch dir, stdin closed); past `timeout_s` the
/// child is killed (code null).
fn runGeode(argv: []const []const u8, timeout_s: i64) !Run {
    const linux = std.os.linux;
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();

    var dir = try test_scratch.ScratchDir.create("sonny6550-dsn");
    defer dir.remove();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("HOME", dir.path());
    try env.put("GEODE_LSP_PORT", "0");

    const out_path = try std.fmt.allocPrint(a, "{s}/run.out", .{dir.path()});
    defer a.free(out_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
    defer out.close(fsIo());

    const child = try std.process.spawn(threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
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
            std.posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            break;
        }
        fsIo().sleep(.fromNanoseconds(100 * std.time.ns_per_ms), .awake) catch {};
        waited_ms += 100;
    }
    const code: ?u8 = if (exited and linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else null;
    return .{ .code = code, .output = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, a, .limited(16 << 20)) };
}

test "SONNY-6550: geode query --dsn percent-decodes the graph path like the client library" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var data = try test_scratch.ScratchDir.create("sonny6550-dsn-data");
    defer data.remove();
    var data_env_buf: [256]u8 = undefined;
    const data_env = try std.fmt.bufPrint(&data_env_buf, "GEODE_DATA_DIR={s}", .{data.path()});
    var server = try util.spawnServerRandom(a, &.{
        "GEODE_ADMIN_USERNAME=geode",
        "GEODE_ADMIN_PASSWORD=" ++ password,
        "GEODE_DEFAULT_PASSWORD=" ++ password,
        data_env,
    });
    defer server.deinit();

    // `%5F` is '_': the session binds (and, for an admin, creates) g_6550.
    const dsn = try std.fmt.allocPrint(a, "quic://geode:" ++ password_encoded ++ "@{s}/g%5F6550", .{server.getAddr()});
    defer a.free(dsn);
    const r = try runGeode(&.{
        geode_test_bin.geode_exe,     "query",              "--dsn",     dsn,
        "--insecure-tls-skip-verify", "--no-saved-session", "--timeout", "10",
        "SHOW GRAPHS",
    }, 60);
    defer r.deinit();
    if (r.code == null or r.code.? != 0 or !r.has("g_6550") or r.has("g%5F6550") or r.has("Oscar6550")) {
        r.dump("query --dsn .../g%5F6550 SHOW GRAPHS");
        return error.TestUnexpectedResult;
    }
}
