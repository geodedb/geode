// CANARY: REQ=REQ-SONNY-6332-NO-FIXED-PORTS; FEATURE="Test Isolation"; ASPECT=NoFixedListenPorts; STATUS=TESTED; TEST=tests/test_sonny6332_no_fixed_ports.zig; OWNER=transport; UPDATED=2026-11-12
//
// SONNY-6332: tests that start a listener on a fixed port talk to whatever
// else holds it. The QUIC socket binds with SO_REUSEADDR, so a second run of
// the same suite on the host (parallel lanes, the pre-push shards, CI jobs on
// a shared runner) bound the SAME UDP port and the two servers answered each
// other's clients: two concurrent runs of test-remote-kms-hardening failed
// with RemoteError / AuthenticationFailed from the other run's KMS key.
//
// Covered here:
//   (1) no test the build compiles binds a literal port: no
//       `start(<port>)` / `startWithOptions(<port>, ...)`, no
//       `port: u16 = <port>;`, and no `--listen host:<port>` /
//       `--listen-grpc host:<port>` / `--lsp-port=<port>` in a test that
//       spawns geode;
//   (2) `geode serve --listen 127.0.0.1:0` reports the port the kernel bound
//       (it reported the configured 0), and a client reaches it there;
//   (3) the embedded LSP listener, which every `geode serve` opened on TCP
//       3142: the build gives every geode-spawning test GEODE_LSP_PORT=0, the
//       server then opens no LSP listener, GEODE_LSP_PORT=<port> moves it, and
//       `--lsp-port` still wins over the variable. The production default
//       (3142 with neither set) is unchanged.
const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const test_ports = @import("test_ports.zig");
const scratch = @import("test_scratch.zig");

const testing = std.testing;

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

// ---------------------------------------------------------------------------
// (1) source check
// ---------------------------------------------------------------------------

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// A nonzero decimal literal starts at `s[i]`, followed by `end` (one of the
/// listed bytes) after optional spaces. Returns the literal or null.
fn nonzeroLiteralAt(s: []const u8, i: usize, end: []const u8) ?[]const u8 {
    if (i >= s.len or !isDigit(s[i]) or s[i] == '0') return null;
    var j = i;
    while (j < s.len and isDigit(s[j])) j += 1;
    var k = j;
    while (k < s.len and s[k] == ' ') k += 1;
    if (k >= s.len or std.mem.indexOfScalar(u8, end, s[k]) == null) return null;
    return s[i..j];
}

/// Why `line` binds a literal port, or null. `spawns_geode`: the file
/// starts geode, so a literal in a listen flag is a real bind (files that
/// only parse an argv are not flagged).
fn fixedPortReason(line: []const u8, spawns_geode: bool) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, trimmed, "//")) return null;
    for ([_][]const u8{ "startWithOptions(", "start(" }) |call| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, line, from, call)) |at| : (from = at + 1) {
            if (at > 0 and (std.ascii.isAlphanumeric(line[at - 1]) or line[at - 1] == '_')) continue;
            var p = at + call.len;
            while (p < line.len and line[p] == ' ') p += 1;
            if (nonzeroLiteralAt(line, p, ",)") != null) return "a server started on a literal port";
        }
    }
    if (std.mem.indexOf(u8, line, "port: u16 = ")) |at| {
        if (nonzeroLiteralAt(line, at + "port: u16 = ".len, ";") != null) return "a literal port constant";
    }
    if (!spawns_geode) return null;
    for ([_][]const u8{ "\"--listen\", \"", "\"--listen-grpc\", \"" }) |flag| {
        if (std.mem.indexOf(u8, line, flag)) |at| {
            const value_start = at + flag.len;
            const value_end = std.mem.indexOfScalarPos(u8, line, value_start, '"') orelse continue;
            const value = line[value_start..value_end];
            const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse continue;
            if (nonzeroLiteralAt(line, value_start + colon + 1, "\"") != null) return "geode serve on a literal listen port";
        }
    }
    if (std.mem.indexOf(u8, line, "\"--lsp-port=")) |at| {
        if (nonzeroLiteralAt(line, at + "\"--lsp-port=".len, "\"") != null) return "geode serve on a literal LSP port";
    }
    return null;
}

test "SONNY-6332 (1) the fixed-port detector flags binds and leaves argv parsing and port 0 alone" {
    try testing.expect(fixedPortReason("    try server.startWithOptions(8876, tls.startOptions());", false) != null);
    try testing.expect(fixedPortReason("    try server.start(44555);", false) != null);
    try testing.expect(fixedPortReason("    const port: u16 = 13051;", false) != null);
    try testing.expect(fixedPortReason("    .{ geode_exe, \"serve\", \"--listen\", \"127.0.0.1:3181\" }", true) != null);
    try testing.expect(fixedPortReason("    \"--listen-grpc\", \"127.0.0.1:50051\",", true) != null);
    try testing.expect(fixedPortReason("    \"--lsp-port=3142\",", true) != null);

    try testing.expect(fixedPortReason("    try server.startWithOptions(0, tls.startOptions());", false) == null);
    try testing.expect(fixedPortReason("    const port: u16 = try test_ports.freeUdpPort();", false) == null);
    try testing.expect(fixedPortReason("    \"geode\", \"serve\", \"--listen\", \"0.0.0.0:3141\",", false) == null);
    try testing.expect(fixedPortReason("    \"--lsp-port=0\",", true) == null);
    try testing.expect(fixedPortReason("    // try server.start(44555);", false) == null);
    try testing.expect(fixedPortReason("    try restart(5);", false) == null);
}

/// The test sources the build compiles: every `b.path("tests/....zig")` in
/// build.zig, plus every `.zig` file under tests/ they import, transitively.
fn compiledTestSources(allocator: std.mem.Allocator, root: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    const build_path = try std.fs.path.join(allocator, &.{ root, "build.zig" });
    defer allocator.free(build_path);
    const build_src = try std.Io.Dir.cwd().readFileAlloc(io(), build_path, allocator, .limited(16 << 20));
    defer allocator.free(build_src);

    const marker = "b.path(\"tests/";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, build_src, from, marker)) |at| {
        from = at + marker.len;
        const start = at + "b.path(\"".len;
        const end = std.mem.indexOfScalarPos(u8, build_src, start, '"') orelse continue;
        const rel = build_src[start..end];
        if (!std.mem.endsWith(u8, rel, ".zig")) continue;
        if (seen.contains(rel)) continue;
        const owned = try allocator.dupe(u8, rel);
        try out.append(allocator, owned);
        try seen.put(allocator, owned, {});
    }

    var i: usize = 0;
    while (i < out.items.len) : (i += 1) {
        const rel = out.items[i];
        const abs = try std.fs.path.join(allocator, &.{ root, rel });
        defer allocator.free(abs);
        const src = std.Io.Dir.cwd().readFileAlloc(io(), abs, allocator, .limited(16 << 20)) catch continue;
        defer allocator.free(src);
        const dir = std.fs.path.dirname(rel) orelse "tests";
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, src, pos, "@import(\"")) |at| {
            pos = at + "@import(\"".len;
            const end = std.mem.indexOfScalarPos(u8, src, pos, '"') orelse continue;
            const name = src[pos..end];
            if (!std.mem.endsWith(u8, name, ".zig")) continue;
            const joined = try std.fs.path.resolve(allocator, &.{ dir, name });
            if (!std.mem.startsWith(u8, joined, "tests/") or seen.contains(joined)) {
                allocator.free(joined);
                continue;
            }
            try out.append(allocator, joined);
            try seen.put(allocator, joined, {});
        }
    }
    return out;
}

test "SONNY-6332 (1) no test the build compiles binds a literal port" {
    const allocator = testing.allocator;
    var files = try compiledTestSources(allocator, geode_test_bin.build_root);
    defer {
        for (files.items) |p| allocator.free(p);
        files.deinit(allocator);
    }
    // The scan reached the suites this ticket converted.
    var saw_hardening = false;
    for (files.items) |p| {
        if (std.mem.eql(u8, p, "tests/canary_remote_kms_hardening.zig")) saw_hardening = true;
    }
    try testing.expect(saw_hardening);
    try testing.expect(files.items.len > 100);

    var offenders: usize = 0;
    for (files.items) |rel| {
        // This file's own detector cases are string literals.
        if (std.mem.eql(u8, rel, "tests/test_sonny6332_no_fixed_ports.zig")) continue;
        const abs = try std.fs.path.join(allocator, &.{ geode_test_bin.build_root, rel });
        defer allocator.free(abs);
        const src = std.Io.Dir.cwd().readFileAlloc(io(), abs, allocator, .limited(16 << 20)) catch continue;
        defer allocator.free(src);
        const spawns_geode = std.mem.indexOf(u8, src, "geode_test_bin") != null;
        var lines = std.mem.splitScalar(u8, src, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            n += 1;
            if (fixedPortReason(line, spawns_geode)) |why| {
                offenders += 1;
                std.debug.print("SONNY-6332: {s}:{d}: {s} (take one from tests/test_ports.zig, or start on port 0 and read the bound port): {s}\n", .{ rel, n, why, std.mem.trim(u8, line, " \t") });
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), offenders);
}

// ---------------------------------------------------------------------------
// (2), (3) a real server
// ---------------------------------------------------------------------------

const LoggedServer = struct {
    handle: util.ServerHandle,
    dir: scratch.ScratchDir,
    log_path: []u8,

    /// `geode serve` with stdout and stderr in a file of its scratch dir.
    /// `env` overlays the inherited environment.
    fn start(allocator: std.mem.Allocator, extra_args: []const []const u8, env: []const [2][]const u8) !LoggedServer {
        var dir = try scratch.ScratchDir.create("sonny6332");
        errdefer dir.remove();
        const data_dir = try std.fs.path.join(allocator, &.{ dir.path(), "data" });
        defer allocator.free(data_dir);
        try std.Io.Dir.cwd().createDirPath(io(), data_dir);
        const log_path = try std.fs.path.join(allocator, &.{ dir.path(), "server.log" });
        errdefer allocator.free(log_path);

        var map = try std.Io.Threaded.global_single_threaded.environ.process_environ.createMap(allocator);
        errdefer map.deinit();
        try map.put("GEODE_ADMIN_USERNAME", util.DefaultAuth.username);
        try map.put("GEODE_ADMIN_PASSWORD", util.DefaultAuth.password);
        for (env) |kv| try map.put(kv[0], kv[1]);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{ geode_test_bin.geode_exe, "serve", "--data-dir", data_dir, "--log-level=info" });
        try argv.appendSlice(allocator, extra_args);

        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        errdefer threaded.deinit();
        const log_file = try std.Io.Dir.cwd().createFile(io(), log_path, .{});
        defer log_file.close(io());
        const child = try std.process.spawn(threaded.io(), .{
            .argv = argv.items,
            .environ_map = &map,
            .stdin = .ignore,
            .stdout = .{ .file = log_file },
            .stderr = .{ .file = log_file },
        });
        return .{
            .handle = .{ .allocator = allocator, .threaded = threaded, .child = child, .env_map = map },
            .dir = dir,
            .log_path = log_path,
        };
    }

    fn log(self: *const LoggedServer, allocator: std.mem.Allocator) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(io(), self.log_path, allocator, .limited(64 << 20));
    }

    /// Wait until the log contains `needle`; error.Timeout after `ms`.
    fn waitForLog(self: *const LoggedServer, allocator: std.mem.Allocator, needle: []const u8, ms: u64) !void {
        const deadline = monoMs() + ms;
        while (monoMs() < deadline) {
            const text = try self.log(allocator);
            defer allocator.free(text);
            if (std.mem.indexOf(u8, text, needle) != null) return;
            sleepMs(100);
        }
        if (self.log(allocator)) |text| {
            defer allocator.free(text);
            std.debug.print("SONNY-6332: no \"{s}\" within {d} ms; log:\n{s}\n", .{ needle, ms, text });
        } else |_| {}
        return error.Timeout;
    }

    fn stop(self: *LoggedServer, allocator: std.mem.Allocator) void {
        self.handle.deinit();
        allocator.free(self.log_path);
        self.dir.remove();
    }
};

/// The QUIC port in the transport's JSON startup banner.
fn bannerPort(text: []const u8) ?u16 {
    const banner = "\"transport\":\"quic\",\"tls\":\"true\",\"port\":";
    const at = std.mem.indexOf(u8, text, banner) orelse return null;
    var i = at + banner.len;
    const start = i;
    while (i < text.len and isDigit(text[i])) i += 1;
    return std.fmt.parseUnsigned(u16, text[start..i], 10) catch null;
}

/// The TCP ports process `pid` listens on: its socket inodes (from
/// /proc/<pid>/fd) matched against the LISTEN rows of /proc/net/tcp{,6}.
/// Read from the kernel rather than the server's log, and without
/// connecting to anything another process may own.
fn listeningTcpPorts(allocator: std.mem.Allocator, pid: std.posix.pid_t) !std.ArrayList(u16) {
    var inodes: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer inodes.deinit(allocator);
    var fd_path_buf: [64]u8 = undefined;
    const fd_dir_path = try std.fmt.bufPrint(&fd_path_buf, "/proc/{d}/fd", .{pid});
    var fd_dir = try std.Io.Dir.cwd().openDir(io(), fd_dir_path, .{ .iterate = true });
    defer fd_dir.close(io());
    var it = fd_dir.iterate();
    while (try it.next(io())) |entry| {
        var link_buf: [128]u8 = undefined;
        const n = fd_dir.readLink(io(), entry.name, &link_buf) catch continue;
        const link = link_buf[0..n];
        const prefix = "socket:[";
        if (!std.mem.startsWith(u8, link, prefix) or link.len < prefix.len + 2) continue;
        const inode = std.fmt.parseUnsigned(u64, link[prefix.len .. link.len - 1], 10) catch continue;
        try inodes.put(allocator, inode, {});
    }

    var ports: std.ArrayList(u16) = .empty;
    errdefer ports.deinit(allocator);
    for ([_][]const u8{ "/proc/net/tcp", "/proc/net/tcp6" }) |table| {
        const text = std.Io.Dir.cwd().readFileAlloc(io(), table, allocator, .limited(64 << 20)) catch continue;
        defer allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        _ = lines.next(); // header
        while (lines.next()) |line| {
            // sl local_address rem_address st tx:rx tr:when retrnsmt uid timeout inode
            var cols = std.mem.tokenizeScalar(u8, line, ' ');
            _ = cols.next() orelse continue;
            const local = cols.next() orelse continue;
            _ = cols.next() orelse continue;
            const state = cols.next() orelse continue;
            for (0..5) |_| _ = cols.next();
            const inode_s = cols.next() orelse continue;
            if (!std.mem.eql(u8, state, "0A")) continue; // TCP_LISTEN
            const inode = std.fmt.parseUnsigned(u64, inode_s, 10) catch continue;
            if (!inodes.contains(inode)) continue;
            const colon = std.mem.lastIndexOfScalar(u8, local, ':') orelse continue;
            const port = std.fmt.parseUnsigned(u16, local[colon + 1 ..], 16) catch continue;
            try ports.append(allocator, port);
        }
    }
    return ports;
}

/// Wait until `pid` listens on TCP `port`.
fn waitListening(allocator: std.mem.Allocator, pid: std.posix.pid_t, port: u16, ms: u64) !bool {
    const deadline = monoMs() + ms;
    while (true) {
        var ports = try listeningTcpPorts(allocator, pid);
        defer ports.deinit(allocator);
        if (std.mem.indexOfScalar(u16, ports.items, port) != null) return true;
        if (monoMs() >= deadline) return false;
        sleepMs(100);
    }
}

fn printPorts(what: []const u8, ports: []const u16) void {
    std.debug.print("SONNY-6332: {s} listens on TCP:", .{what});
    for (ports) |p| std.debug.print(" {d}", .{p});
    std.debug.print("\n", .{});
}

test "SONNY-6332 (3) the build gives geode-spawning tests GEODE_LSP_PORT=0" {
    const v = std.c.getenv("GEODE_LSP_PORT") orelse {
        std.debug.print("SONNY-6332: GEODE_LSP_PORT is not set in this test process (build.zig disableEmbeddedLspForTestServers)\n", .{});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("0", std.mem.span(v));
}

test "SONNY-6332 (2) serve on port 0 reports the bound port and answers there; (3) with GEODE_LSP_PORT=0 it opens no LSP listener" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var srv = try LoggedServer.start(allocator, &.{ "--listen", "127.0.0.1:0" }, &.{.{ "GEODE_LSP_PORT", "0" }});
    defer srv.stop(allocator);
    try srv.waitForLog(allocator, "[startup] server ready", 120_000);

    const text = try srv.log(allocator);
    defer allocator.free(text);
    const port = bannerPort(text) orelse {
        std.debug.print("SONNY-6332: no QUIC banner port in the log:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    };
    if (port == 0) {
        std.debug.print("SONNY-6332: the server reported port 0, not the port it bound\n", .{});
        return error.TestUnexpectedResult;
    }
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    try util.waitForServerReady(allocator, addr, 60_000);

    // Ready and answering, and it listens on no TCP port at all (no metrics
    // port is configured, no gRPC listener, no LSP listener). Before the fix
    // the embedded LSP listener took TCP 3142.
    var ports = try listeningTcpPorts(allocator, srv.handle.child.id.?);
    defer ports.deinit(allocator);
    if (ports.items.len != 0) {
        printPorts("a server with GEODE_LSP_PORT=0", ports.items);
        return error.TestUnexpectedResult;
    }
}

test "SONNY-6332 (3) GEODE_LSP_PORT moves the LSP listener and --lsp-port wins over it: two servers at once, each on its own LSP port" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    const q1 = try test_ports.freeUdpPort();
    const q2 = try test_ports.freeUdpPortExcept(&.{q1});
    const l1 = try test_ports.freeTcpPortExcept(&.{ q1, q2 });
    const l2 = try test_ports.freeTcpPortExcept(&.{ q1, q2, l1 });
    const decoy = try test_ports.freeTcpPortExcept(&.{ q1, q2, l1, l2 });

    var a1: [32]u8 = undefined;
    var a2: [32]u8 = undefined;
    var f2: [32]u8 = undefined;
    var e1: [8]u8 = undefined;
    var e2: [8]u8 = undefined;
    const addr1 = try std.fmt.bufPrint(&a1, "127.0.0.1:{d}", .{q1});
    const addr2 = try std.fmt.bufPrint(&a2, "127.0.0.1:{d}", .{q2});
    const flag2 = try std.fmt.bufPrint(&f2, "--lsp-port={d}", .{l2});
    const env1 = try std.fmt.bufPrint(&e1, "{d}", .{l1});
    const env2 = try std.fmt.bufPrint(&e2, "{d}", .{decoy});

    // Server 1: the variable alone. Server 2: the flag and a different
    // variable; the flag wins.
    var s1 = try LoggedServer.start(allocator, &.{ "--listen", addr1 }, &.{.{ "GEODE_LSP_PORT", env1 }});
    defer s1.stop(allocator);
    var s2 = try LoggedServer.start(allocator, &.{ "--listen", addr2, flag2 }, &.{.{ "GEODE_LSP_PORT", env2 }});
    defer s2.stop(allocator);
    try s1.waitForLog(allocator, "[startup] server ready", 120_000);
    try s2.waitForLog(allocator, "[startup] server ready", 120_000);

    const pid1 = s1.handle.child.id.?;
    const pid2 = s2.handle.child.id.?;
    if (!try waitListening(allocator, pid1, l1, 30_000)) {
        var ports = try listeningTcpPorts(allocator, pid1);
        defer ports.deinit(allocator);
        printPorts("the server with GEODE_LSP_PORT set", ports.items);
        std.debug.print("SONNY-6332: GEODE_LSP_PORT={d}: the server does not listen there\n", .{l1});
        return error.TestUnexpectedResult;
    }
    if (!try waitListening(allocator, pid2, l2, 30_000)) {
        var ports = try listeningTcpPorts(allocator, pid2);
        defer ports.deinit(allocator);
        printPorts("the server with --lsp-port", ports.items);
        std.debug.print("SONNY-6332: --lsp-port={d}: the server does not listen there\n", .{l2});
        return error.TestUnexpectedResult;
    }
    var ports2 = try listeningTcpPorts(allocator, pid2);
    defer ports2.deinit(allocator);
    if (std.mem.indexOfScalar(u16, ports2.items, decoy) != null) {
        std.debug.print("SONNY-6332: GEODE_LSP_PORT={d} won over --lsp-port={d}\n", .{ decoy, l2 });
        return error.TestUnexpectedResult;
    }
}
