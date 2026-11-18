// CANARY: REQ=REQ-SONNY-6325-NO-FIXED-TMP; FEATURE="Secret File Hygiene"; ASPECT=NoFixedSharedPaths; STATUS=TESTED; TEST=tests/test_sonny6325_no_fixed_tmp_paths.zig; OWNER=security; UPDATED=2026-11-11
//
// SONNY-6325: production code used fixed paths under the shared, world-writable
// /tmp:
//   (1) the auto-generated TLS certificate and PRIVATE KEY fell back to
//       /tmp/geode-server.crt and /tmp/geode-server.key: whenever the server
//       ran without --data-dir (GEODE_DATA_DIR or the per-user default only)
//       and whenever the data/cert directory could not be written. A key
//       already at the path was reused whoever planted it, a symbolic link was
//       followed by openssl, and an existing key of any mode was accepted;
//   (2) S3 restore staged into the predictable /tmp/geode_s3_restore_<id>;
//   (3) the audit diagnostic procedures wrote, truncated and deleted fixed
//       /tmp files (and /etc/geode/geode_audit.jsonl);
//   (4) `geode backup list` scanned /tmp;
//   (5) the last-resort per-user data directory /tmp/geode-<uid> was used
//       without checking it is a real directory owned by the user, mode 0700;
//   (6) createFullBackup used /tmp as the DATA directory when none was set,
//       archiving every top-level entry of /tmp.
//
// The contract: no key is read from or written to a fixed shared path; a
// generated key is created exclusive, no-follow, 0600 in the data directory
// (or GEODE_CERT_DIR); an existing auto key is used only when it is a regular
// file owned by the server's user with no group/other bits; temp directories
// are private (random name, 0700); a pre-existing per-user tmp data directory
// that is not ours or not 0700 is refused, never chmod-ed.
//
// This file never reads, writes or deletes /tmp/geode-server.{crt,key} (which
// may exist on the host); it only compares their metadata before and after.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const backup = @import("storage/backup");
const cert_gen = @import("cert_gen");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const test_ports = @import("test_ports.zig");
const util = @import("proto_test_util.zig");

const linux = std.os.linux;
const posix = std.posix;
const geode_binary = geode_test_bin.geode_exe;
const admin_pw = util.DefaultAuth.password;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn join(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

fn sleepMs(ms: u64) void {
    fsIo().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

fn writeFile(path: []const u8, bytes: []const u8, mode_bits: u32) !void {
    const f = try std.Io.Dir.cwd().createFile(fsIo(), path, .{ .permissions = std.Io.File.Permissions.fromMode(@intCast(mode_bits)) });
    defer f.close(fsIo());
    try f.setPermissions(fsIo(), std.Io.File.Permissions.fromMode(@intCast(mode_bits)));
    try f.writeStreamingAll(fsIo(), bytes);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(fsIo(), path, allocator, .limited(1 << 20));
}

fn chmodPath(path: []const u8, mode_bits: u32) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    if (linux.errno(linux.fchmodat(linux.AT.FDCWD, z, @intCast(mode_bits))) != .SUCCESS) return error.ChmodFailed;
}

/// lstat (never follows a symbolic link). Null when nothing is at `path`.
fn lstatx(path: []const u8) ?linux.Statx {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return null;
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true, .INO = true, .SIZE = true, .MTIME = true }, &st);
    if (linux.errno(rc) != .SUCCESS) return null;
    return st;
}

fn isRegular(st: linux.Statx) bool {
    return (st.mode & linux.S.IFMT) == linux.S.IFREG;
}
fn isSymlink(st: linux.Statx) bool {
    return (st.mode & linux.S.IFMT) == linux.S.IFLNK;
}
fn isDir(st: linux.Statx) bool {
    return (st.mode & linux.S.IFMT) == linux.S.IFDIR;
}
fn permBits(st: linux.Statx) u32 {
    return st.mode & 0o7777;
}

/// The file is a regular file owned by this user with exactly `want` mode.
fn expectPrivateFile(path: []const u8, want: u32) !void {
    const st = lstatx(path) orelse {
        std.debug.print("SONNY-6325: expected {s} to exist\n", .{path});
        return error.TestUnexpectedResult;
    };
    if (!isRegular(st) or st.uid != linux.getuid() or permBits(st) != want) {
        std.debug.print("SONNY-6325: {s}: regular={} uid={d} (want {d}) mode={o} (want {o})\n", .{ path, isRegular(st), st.uid, linux.getuid(), permBits(st), want });
        return error.TestUnexpectedResult;
    }
}

fn expectErr(want: anyerror, got: anyerror) !void {
    if (want != got) {
        std.debug.print("SONNY-6325: expected error.{s}, got error.{s}\n", .{ @errorName(want), @errorName(got) });
        return error.TestUnexpectedResult;
    }
}

fn sha256File(path: []const u8) ![32]u8 {
    const bytes = try readFileAlloc(testing.allocator, path);
    defer testing.allocator.free(bytes);
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

// ---------------------------------------------------------------------------
// Fixed /tmp paths this file watches. Metadata only: never read or written.
// ---------------------------------------------------------------------------

const watched_tmp_paths = [_][]const u8{
    "/tmp/geode-server.crt",
    "/tmp/geode-server.key",
    "/tmp/geode_audit_file_output_test.jsonl",
    "/tmp/geode_audit_file_output_test.jsonl.key",
    "/tmp/geode_audit_file_output_test.jsonl.pub",
    "/tmp/geode_audit_auth_categories.jsonl",
    "/tmp/geode_audit_auth_categories.jsonl.key",
    "/tmp/geode_audit_auth_categories.jsonl.pub",
};

const TmpSnap = struct {
    present: [watched_tmp_paths.len]bool = undefined,
    ino: [watched_tmp_paths.len]u64 = undefined,
    size: [watched_tmp_paths.len]u64 = undefined,
    mtime: [watched_tmp_paths.len]i64 = undefined,
    mtime_ns: [watched_tmp_paths.len]u32 = undefined,

    fn take() TmpSnap {
        var s: TmpSnap = .{};
        for (watched_tmp_paths, 0..) |p, i| {
            if (lstatx(p)) |st| {
                s.present[i] = true;
                s.ino[i] = st.ino;
                s.size[i] = st.size;
                s.mtime[i] = st.mtime.sec;
                s.mtime_ns[i] = st.mtime.nsec;
            } else {
                s.present[i] = false;
            }
        }
        return s;
    }

    /// Remove whatever appeared at a watched path during the test (the
    /// product under test made it); an existing file is never touched.
    fn cleanup(self: *const TmpSnap) void {
        for (watched_tmp_paths, 0..) |p, i| {
            if (!self.present[i] and lstatx(p) != null) std.Io.Dir.cwd().deleteFile(fsIo(), p) catch {};
        }
    }

    /// Nothing at a watched path changed. A path that appeared during the
    /// test was created by the product under test and is removed again (an
    /// existing file is never touched).
    fn expectUnchanged(self: *const TmpSnap, what: []const u8) !void {
        var bad = false;
        for (watched_tmp_paths, 0..) |p, i| {
            const now = lstatx(p);
            if (!self.present[i]) {
                if (now != null) {
                    std.debug.print("SONNY-6325 {s}: the product created the fixed shared path {s}\n", .{ what, p });
                    std.Io.Dir.cwd().deleteFile(fsIo(), p) catch {};
                    bad = true;
                }
                continue;
            }
            const st = now orelse {
                std.debug.print("SONNY-6325 {s}: the fixed shared path {s} disappeared\n", .{ what, p });
                bad = true;
                continue;
            };
            if (st.ino != self.ino[i] or st.size != self.size[i] or st.mtime.sec != self.mtime[i] or st.mtime.nsec != self.mtime_ns[i]) {
                std.debug.print("SONNY-6325 {s}: the fixed shared path {s} was modified\n", .{ what, p });
                bad = true;
            }
        }
        if (bad) return error.TestUnexpectedResult;
    }
};

// ---------------------------------------------------------------------------
// Process helpers
// ---------------------------------------------------------------------------

const Run = struct {
    code: ?u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }

    fn output(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.stdout, needle) != null or
            std.mem.indexOf(u8, self.stderr, needle) != null;
    }

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6325 {s}: exit={?d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ what, self.code, self.stdout, self.stderr });
    }
};

/// Run geode to completion in `cwd` with an environment built from scratch
/// (PATH, LD_LIBRARY_PATH and `env` only). A process still running after
/// `timeout_s` is killed and reported with a null exit code.
fn runGeode(argv: []const []const u8, env_kv: []const [2][]const u8, cwd: []const u8, timeout_s: i64) !Run {
    // A hard deadline: a server that keeps logging would keep std.process.run's
    // per-read timeout from ever firing. Output goes to a scratch file.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    for (env_kv) |kv| try env.put(kv[0], kv[1]);
    var rnd: [8]u8 = undefined;
    _ = linux.getrandom(&rnd, rnd.len, 0);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out_path = try std.fmt.bufPrint(&name_buf, "{s}/run-{x}.out", .{ try test_scratch.processRoot(), std.mem.readInt(u64, &rnd, .little) });
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
    errdefer testing.allocator.free(text);
    const note = try testing.allocator.dupe(u8, if (exited) "" else "(killed: still running at the timeout)");
    return .{ .code = code, .stdout = text, .stderr = note };
}

/// A geode server on a free port in its own working directory, environment
/// built from scratch.
const Server = struct {
    threaded: std.Io.Threaded,
    env: std.process.Environ.Map,
    child: std.process.Child,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, cwd: []const u8, extra_args: []const []const u8, env_kv: []const [2][]const u8) !Server {
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        errdefer threaded.deinit();
        var env = std.process.Environ.Map.init(allocator);
        errdefer env.deinit();
        inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
            if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
        }
        for (env_kv) |kv| try env.put(kv[0], kv[1]);

        const addr = try util.formatAddr(allocator, try test_ports.freeUdpPort());
        errdefer allocator.free(addr);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{ geode_binary, "serve", "--listen", addr });
        try argv.appendSlice(allocator, extra_args);
        const inherit = std.c.getenv("GEODE_TEST_INHERIT_SERVER_STDERR") != null;
        const child = try std.process.spawn(threaded.io(), .{
            .argv = argv.items,
            .environ_map = &env,
            .cwd = .{ .path = cwd },
            .stdin = .ignore,
            .stdout = if (inherit) .inherit else .ignore,
            .stderr = if (inherit) .inherit else .ignore,
        });
        var server: Server = .{ .threaded = threaded, .env = env, .child = child, .addr = addr };
        errdefer server.stop(allocator);
        try util.waitForServerReady(allocator, addr, 60_000);
        return server;
    }

    fn stop(self: *Server, allocator: std.mem.Allocator) void {
        if (self.child.id) |pid| {
            posix.kill(pid, .TERM) catch {};
            var waited: u32 = 0;
            while (util.processAlive(pid) and waited < 30_000) : (waited += 100) sleepMs(100);
            if (util.processAlive(pid)) posix.kill(pid, .KILL) catch {};
            _ = self.child.wait(self.threaded.io()) catch {};
        }
        self.threaded.deinit();
        self.env.deinit();
        allocator.free(self.addr);
    }

    fn connect(self: *Server, allocator: std.mem.Allocator) !util.QuicProtoClient {
        var client = try util.QuicProtoClient.connect(allocator, self.addr);
        errdefer client.deinit();
        var h = try client.hello(allocator, util.DefaultAuth.username, admin_pw);
        defer h.deinit(allocator);
        if (!h.success) {
            std.debug.print("SONNY-6325: HELLO failed: {s}\n", .{h.error_message});
            return error.HelloFailed;
        }
        return client;
    }
};

/// A scratch root with a working directory and a fake HOME inside it.
const Fixture = struct {
    root: test_scratch.ScratchDir,
    cwd: []u8,
    home: []u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Fixture {
        var root = try test_scratch.ScratchDir.create(tag);
        errdefer root.remove();
        const cwd = try join(allocator, root.path(), "cwd");
        errdefer allocator.free(cwd);
        const home = try join(allocator, root.path(), "home");
        errdefer allocator.free(home);
        try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);
        try std.Io.Dir.cwd().createDirPath(fsIo(), home);
        return .{ .root = root, .cwd = cwd, .home = home };
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        allocator.free(self.home);
        self.root.remove();
    }

    fn path(self: *Fixture, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        return join(allocator, self.root.path(), name);
    }
};

/// No `certs/` directory (the old gRPC-only default) appeared in `cwd`.
fn expectNoCwdCerts(allocator: std.mem.Allocator, cwd: []const u8) !void {
    const p = try join(allocator, cwd, "certs");
    defer allocator.free(p);
    if (lstatx(p) != null) {
        std.debug.print("SONNY-6325: TLS material was written into the working directory ({s})\n", .{p});
        return error.TestUnexpectedResult;
    }
}

// ===========================================================================
// (1) TLS certificate and key — the auto path (cert_gen.ensureCertificatesAtPath)
// ===========================================================================

fn opensslAvailable() bool {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const r = std.process.run(std.heap.smp_allocator, threaded.io(), .{ .argv = &.{ "openssl", "version" } }) catch return false;
    std.heap.smp_allocator.free(r.stdout);
    std.heap.smp_allocator.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

test "SONNY-6325 (1) a symbolic link planted at the auto TLS key path is refused and never written through" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (!opensslAvailable()) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6325-tls-symlink");
    defer fx.deinit(allocator);

    const dir = try fx.path(allocator, "data");
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(fsIo(), dir);
    const victim = try fx.path(allocator, "victim.txt");
    defer allocator.free(victim);
    try writeFile(victim, "a file another user owns\n", 0o644);
    const key = try join(allocator, dir, "server.key");
    defer allocator.free(key);
    const crt = try join(allocator, dir, "server.crt");
    defer allocator.free(crt);
    try std.Io.Dir.cwd().symLink(fsIo(), victim, key, .{});

    const before = try sha256File(victim);
    if (cert_gen.ensureCertificatesAtPath(allocator, crt, key)) |_| {
        std.debug.print("SONNY-6325: ensureCertificatesAtPath accepted a symbolic link at the key path\n", .{});
        try testing.expect(false);
    } else |err| {
        std.debug.print("SONNY-6325: refused as expected: {s}\n", .{@errorName(err)});
    }
    // The link target was not written through, and the link is still a link.
    try testing.expectEqual(before, try sha256File(victim));
    try testing.expect(isSymlink(lstatx(key).?));
}

test "SONNY-6325 (1) an existing auto TLS key that is group- or world-accessible is refused, never used or changed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (!opensslAvailable()) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6325-tls-mode");
    defer fx.deinit(allocator);

    const dir = try fx.path(allocator, "data");
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(fsIo(), dir);
    const key = try join(allocator, dir, "server.key");
    defer allocator.free(key);
    const crt = try join(allocator, dir, "server.crt");
    defer allocator.free(crt);
    // A real pair, generated by the product itself.
    try cert_gen.ensureCertificatesAtPath(allocator, crt, key);
    try expectPrivateFile(key, 0o600);

    for ([_]u32{ 0o640, 0o604, 0o660 }) |m| {
        try chmodPath(key, m);
        const before = try sha256File(key);
        if (cert_gen.ensureCertificatesAtPath(allocator, crt, key)) |_| {
            std.debug.print("SONNY-6325: an auto TLS key with mode {o} was accepted\n", .{m});
            try testing.expect(false);
        } else |err| {
            try expectErr(error.TlsKeyGroupOrWorldAccessible, err);
        }
        // Refused without touching it: same bytes, same mode (never chmod-ed).
        try testing.expectEqual(before, try sha256File(key));
        try testing.expectEqual(m, permBits(lstatx(key).?));
    }
}

test "SONNY-6325 (1) a key without its certificate is refused, never regenerated over" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (!opensslAvailable()) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6325-tls-half");
    defer fx.deinit(allocator);

    const dir = try fx.path(allocator, "data");
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(fsIo(), dir);
    const key = try join(allocator, dir, "server.key");
    defer allocator.free(key);
    const crt = try join(allocator, dir, "server.crt");
    defer allocator.free(crt);
    // An attacker-known "key" already in place, owner-only.
    try writeFile(key, "-----BEGIN PRIVATE KEY-----\nplanted\n-----END PRIVATE KEY-----\n", 0o600); // gitleaks:allow
    const before = try sha256File(key);
    if (cert_gen.ensureCertificatesAtPath(allocator, crt, key)) |_| {
        std.debug.print("SONNY-6325: a key without a certificate was accepted (and a certificate made for it, or the key replaced)\n", .{});
        try testing.expect(false);
    } else |err| {
        try expectErr(error.IncompleteTlsMaterial, err);
    }
    try testing.expectEqual(before, try sha256File(key));
    try testing.expect(lstatx(crt) == null);
}

test "SONNY-6325 (1) a generated TLS key is a 0600 regular file of this user, the certificate 0644, and a second call reuses them" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (!opensslAvailable()) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6325-tls-fresh");
    defer fx.deinit(allocator);

    const dir = try fx.path(allocator, "data");
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(fsIo(), dir);
    const key = try join(allocator, dir, "server.key");
    defer allocator.free(key);
    const crt = try join(allocator, dir, "server.crt");
    defer allocator.free(crt);
    try cert_gen.ensureCertificatesAtPath(allocator, crt, key);
    try expectPrivateFile(key, 0o600);
    try expectPrivateFile(crt, 0o644);
    const k1 = try sha256File(key);
    const c1 = try sha256File(crt);
    try cert_gen.ensureCertificatesAtPath(allocator, crt, key);
    try testing.expectEqual(k1, try sha256File(key));
    try testing.expectEqual(c1, try sha256File(crt));

    // Nothing else left in the directory (no staging leftovers).
    var d = try std.Io.Dir.cwd().openDir(fsIo(), dir, .{ .iterate = true });
    defer d.close(fsIo());
    var it = d.iterate();
    var n: usize = 0;
    while (try it.next(fsIo())) |e| {
        if (!std.mem.eql(u8, e.name, "server.key") and !std.mem.eql(u8, e.name, "server.crt")) {
            std.debug.print("SONNY-6325: unexpected entry left beside the TLS material: {s}\n", .{e.name});
            try testing.expect(false);
        }
        n += 1;
    }
    try testing.expectEqual(@as(usize, 2), n);
}

// ===========================================================================
// (1) The server: no --data-dir, GEODE_DATA_DIR only
// ===========================================================================

test "SONNY-6325 (1) a server without --data-dir serves TLS from its data directory (key 0600), reuses its key on restart, and never touches /tmp/geode-server.*" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6325-srv-env");
    defer fx.deinit(allocator);
    const data = try fx.path(allocator, "data");
    defer allocator.free(data);

    const snap = TmpSnap.take();
    defer snap.cleanup();
    const env = [_][2][]const u8{ .{ "HOME", fx.home }, .{ "GEODE_DATA_DIR", data }, .{ "GEODE_ADMIN_PASSWORD", admin_pw } };
    const key = try join(allocator, data, "server.key");
    defer allocator.free(key);
    const crt = try join(allocator, data, "server.crt");
    defer allocator.free(crt);

    var first: [32]u8 = undefined;
    {
        var server = try Server.start(allocator, fx.cwd, &.{}, &env);
        defer server.stop(allocator);
        try expectPrivateFile(key, 0o600);
        try expectPrivateFile(crt, 0o644);
        first = try sha256File(key);
    }
    {
        var server = try Server.start(allocator, fx.cwd, &.{}, &env);
        defer server.stop(allocator);
        try testing.expectEqual(first, try sha256File(key));
        try expectPrivateFile(key, 0o600);
    }
    try expectNoCwdCerts(allocator, fx.cwd);
    try snap.expectUnchanged("server without --data-dir");
}

test "SONNY-6325 (1) a server refuses to start on a group-readable auto TLS key in its data directory" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6325-srv-mode");
    defer fx.deinit(allocator);
    const data = try fx.path(allocator, "data");
    defer allocator.free(data);
    const env = [_][2][]const u8{ .{ "HOME", fx.home }, .{ "GEODE_ADMIN_PASSWORD", admin_pw } };
    const key = try join(allocator, data, "server.key");
    defer allocator.free(key);
    {
        var server = try Server.start(allocator, fx.cwd, &.{ "--data-dir", data }, &env);
        defer server.stop(allocator);
        try expectPrivateFile(key, 0o600);
    }
    try chmodPath(key, 0o640);
    const before = try sha256File(key);
    const addr = try util.formatAddr(allocator, try test_ports.freeUdpPort());
    defer allocator.free(addr);
    const r = try runGeode(&.{ geode_binary, "serve", "--listen", addr, "--data-dir", data }, &env, fx.cwd, 60);
    defer r.deinit();
    if (r.code == null or r.code.? == 0 or !r.output("server.key")) r.dump("group-readable key");
    try testing.expect(r.code != null and r.code.? != 0);
    try testing.expect(r.output("server.key"));
    try testing.expectEqual(before, try sha256File(key));
    try testing.expectEqual(@as(u32, 0o640), permBits(lstatx(key).?));
}

test "SONNY-6325 (1) a cert directory the server cannot write is refused, never replaced by /tmp" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (linux.getuid() == 0) return error.SkipZigTest; // root writes anywhere
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6325-srv-certdir");
    defer fx.deinit(allocator);
    const data = try fx.path(allocator, "data");
    defer allocator.free(data);
    const certs = try fx.path(allocator, "ro-certs");
    defer allocator.free(certs);
    try std.Io.Dir.cwd().createDirPath(fsIo(), certs);
    try chmodPath(certs, 0o500);
    defer chmodPath(certs, 0o700) catch {};

    const snap = TmpSnap.take();
    defer snap.cleanup();
    const env = [_][2][]const u8{ .{ "HOME", fx.home }, .{ "GEODE_CERT_DIR", certs }, .{ "GEODE_ADMIN_PASSWORD", admin_pw } };
    const addr = try util.formatAddr(allocator, try test_ports.freeUdpPort());
    defer allocator.free(addr);
    const r = try runGeode(&.{ geode_binary, "serve", "--listen", addr, "--data-dir", data }, &env, fx.cwd, 60);
    defer r.deinit();
    if (r.code == null or r.code.? == 0) r.dump("unwritable cert dir");
    try testing.expect(r.code != null and r.code.? != 0);
    try snap.expectUnchanged("unwritable cert dir");
}

// ===========================================================================
// (2) S3 restore staging directory
// ===========================================================================

test "SONNY-6325 (2) restore staging directories are private: random name, mode 0700, owned by this user, created exclusively" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (comptime !@hasDecl(backup, "makePrivateTempDir")) {
        std.debug.print("SONNY-6325: storage/backup has no private temp directory: S3 restore stages into the predictable /tmp/geode_s3_restore_<id> (src/storage/s3_backup.zig)\n", .{});
        return error.TestUnexpectedResult;
    } else try privateTempDirCase();
}

fn privateTempDirCase() !void {
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6325-s3-stage");
    defer fx.deinit(allocator);
    const parent = try fx.path(allocator, "target-parent");
    defer allocator.free(parent);
    try std.Io.Dir.cwd().createDirPath(fsIo(), parent);

    const a = try backup.makePrivateTempDir(allocator, parent, "s3-restore");
    defer allocator.free(a);
    const b = try backup.makePrivateTempDir(allocator, parent, "s3-restore");
    defer allocator.free(b);
    try testing.expect(!std.mem.eql(u8, a, b));
    for ([_][]const u8{ a, b }) |p| {
        try testing.expect(std.mem.startsWith(u8, p, parent));
        const st = lstatx(p).?;
        try testing.expect(isDir(st));
        try testing.expectEqual(@as(u32, 0o700), permBits(st));
        try testing.expectEqual(linux.getuid(), st.uid);
    }
    // A parent that is not a directory (a planted symbolic link) is refused.
    const victim_dir = try fx.path(allocator, "victim-dir");
    defer allocator.free(victim_dir);
    try std.Io.Dir.cwd().createDirPath(fsIo(), victim_dir);
    const link = try fx.path(allocator, "link-parent");
    defer allocator.free(link);
    try std.Io.Dir.cwd().symLink(fsIo(), victim_dir, link, .{});
    if (backup.makePrivateTempDir(allocator, link, "s3-restore")) |p| {
        allocator.free(p);
        std.debug.print("SONNY-6325: a private temp dir was created through a symbolic link parent\n", .{});
        try testing.expect(false);
    } else |_| {}
    var vd = try std.Io.Dir.cwd().openDir(fsIo(), victim_dir, .{ .iterate = true });
    defer vd.close(fsIo());
    var vit = vd.iterate();
    try testing.expect((try vit.next(fsIo())) == null);
}

// ===========================================================================
// (3) Audit diagnostic procedures
// ===========================================================================

fn callRow(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !util.ExecResult {
    const r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    if (r.error_code) |code| {
        std.debug.print("SONNY-6325: {s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
    }
    return r;
}

fn stringCell(r: *const util.ExecResult, column: []const u8) ?[]const u8 {
    for (r.columns, 0..) |c, i| {
        if (std.mem.eql(u8, c, column) and r.rows.len > 0) {
            return switch (r.rows[0][i]) {
                .string => |s| s,
                else => null,
            };
        }
    }
    return null;
}

test "SONNY-6325 (3) audit diagnostic procedures write only private files in the data directory, never fixed /tmp paths, and never follow a planted link" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6325-audit-diag");
    defer fx.deinit(allocator);
    const data = try fx.path(allocator, "data");
    defer allocator.free(data);
    const snap = TmpSnap.take();
    defer snap.cleanup();
    const env = [_][2][]const u8{ .{ "HOME", fx.home }, .{ "GEODE_ADMIN_PASSWORD", admin_pw } };

    var server = try Server.start(allocator, fx.cwd, &.{ "--data-dir", data }, &env);
    defer server.stop(allocator);
    var client = try server.connect(allocator);
    defer client.deinit();

    {
        var r = try callRow(&client, allocator, "CALL audit.test_file_output() YIELD success, file_path, events_written RETURN success, file_path, events_written");
        defer r.deinit(allocator);
        try testing.expect(r.error_code == null);
        const fp = stringCell(&r, "file_path") orelse return error.TestUnexpectedResult;
        if (!std.mem.startsWith(u8, fp, data)) {
            std.debug.print("SONNY-6325: audit.test_file_output wrote {s}, outside the data directory {s}\n", .{ fp, data });
            try testing.expect(false);
        }
        try expectPrivateFile(fp, 0o600);
        const dir = std.fs.path.dirname(fp).?;
        const st = lstatx(dir).?;
        try testing.expect(isDir(st));
        try testing.expectEqual(@as(u32, 0o700), permBits(st));

        // A symbolic link planted where the procedure writes is not followed.
        try std.Io.Dir.cwd().deleteFile(fsIo(), fp);
        const victim = try fx.path(allocator, "audit-victim.txt");
        defer allocator.free(victim);
        try writeFile(victim, "do not overwrite\n", 0o644);
        try std.Io.Dir.cwd().symLink(fsIo(), victim, fp, .{});
        const before = try sha256File(victim);
        var r2 = try callRow(&client, allocator, "CALL audit.test_file_output() YIELD success RETURN success");
        defer r2.deinit(allocator);
        try testing.expectEqual(before, try sha256File(victim));
        try testing.expect(isSymlink(lstatx(fp).?));
    }
    {
        var r = try callRow(&client, allocator, "CALL audit.test_auth_categories() YIELD category, events_logged, success RETURN category, events_logged, success");
        defer r.deinit(allocator);
        try testing.expect(r.error_code == null);
    }
    {
        var r = try callRow(&client, allocator, "CALL audit.cleanup_test_artifacts() YIELD files_cleaned RETURN files_cleaned");
        defer r.deinit(allocator);
        try testing.expect(r.error_code == null);
    }
    try snap.expectUnchanged("audit diagnostic procedures");
}

// ===========================================================================
// (4) geode backup list
// ===========================================================================

test "SONNY-6325 (4) geode backup list does not scan /tmp" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6325-backup-list");
    defer fx.deinit(allocator);

    // A uniquely named file directly in /tmp, created exclusively by this
    // test and removed by it: a backup listing must not show it.
    var rnd: [8]u8 = undefined;
    _ = linux.getrandom(&rnd, rnd.len, 0);
    var name_buf: [96]u8 = undefined;
    const planted = try std.fmt.bufPrint(&name_buf, "/tmp/geode_backup_sonny6325_{d}_{x}.gz", .{ linux.getpid(), std.mem.readInt(u64, &rnd, .little) });
    {
        const f = try std.Io.Dir.cwd().createFile(fsIo(), planted, .{ .exclusive = true });
        f.close(fsIo());
    }
    defer std.Io.Dir.cwd().deleteFile(fsIo(), planted) catch {};

    const r = try runGeode(&.{ geode_binary, "backup", "list" }, &.{.{ "HOME", fx.home }}, fx.cwd, 60);
    defer r.deinit();
    if (r.output("/tmp")) {
        r.dump("backup list");
        std.debug.print("SONNY-6325: geode backup list scanned /tmp\n", .{});
        try testing.expect(false);
    }
}

// ===========================================================================
// (5) The per-user last-resort data directory
// ===========================================================================

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
const c_setenv = setenv;

const EnvSave = struct {
    names: []const [:0]const u8,
    saved: [8]?[]u8 = .{null} ** 8,

    fn save(names: []const [:0]const u8) EnvSave {
        var s: EnvSave = .{ .names = names };
        for (names, 0..) |n, i| {
            s.saved[i] = if (std.c.getenv(n)) |v| testing.allocator.dupe(u8, std.mem.span(v)) catch null else null;
        }
        return s;
    }

    /// Values are only ever overwritten in place, never removed: unsetenv
    /// shifts libc's environ array under Zig's cached copy of it (a null
    /// entry inside its length), which crashed std.debug.print. An empty
    /// value is what the code under test treats as unset.
    fn restore(self: *EnvSave) void {
        for (self.names, 0..) |n, i| {
            const v = self.saved[i] orelse "";
            const z = testing.allocator.dupeZ(u8, v) catch continue;
            defer testing.allocator.free(z);
            _ = c_setenv(n, z, 1);
            if (self.saved[i]) |owned| testing.allocator.free(owned);
        }
    }
};

fn setenvZ(name: [:0]const u8, value: []const u8) !void {
    const z = try testing.allocator.dupeZ(u8, value);
    defer testing.allocator.free(z);
    if (c_setenv(name, z, 1) != 0) return error.SetenvFailed;
}

test "SONNY-6325 (5) the per-user tmp data directory honours TMPDIR, is created 0700, and a planted link or a non-private directory is refused, never chmod-ed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6325-tmp-datadir");
    defer fx.deinit(allocator);

    const env_names = [_][:0]const u8{ "XDG_STATE_HOME", "HOME", "TMPDIR" };
    var saved = EnvSave.save(&env_names);
    defer saved.restore();
    try setenvZ("XDG_STATE_HOME", "");
    try setenvZ("HOME", "");
    const tmp = try fx.path(allocator, "faketmp");
    defer allocator.free(tmp);
    try std.Io.Dir.cwd().createDirPath(fsIo(), tmp);
    try setenvZ("TMPDIR", tmp);

    var want_buf: [std.fs.max_path_bytes]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "{s}/geode-{d}", .{ tmp, linux.getuid() });

    // Absent: created, a private directory.
    {
        const got = try geode.graph_store.defaultDataDir(allocator);
        defer allocator.free(got);
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print("SONNY-6325: the last-resort data directory is {s}, not under TMPDIR ({s})\n", .{ got, want });
            return error.TestUnexpectedResult;
        }
        const st = lstatx(want) orelse {
            std.debug.print("SONNY-6325: {s} was not created\n", .{want});
            return error.TestUnexpectedResult;
        };
        try testing.expect(isDir(st));
        try testing.expectEqual(@as(u32, 0o700), permBits(st));
        try testing.expectEqual(linux.getuid(), st.uid);
        // Ours and private: reused.
        const again = try geode.graph_store.defaultDataDir(allocator);
        allocator.free(again);
    }
    // A directory with group/other bits: refused, mode untouched.
    {
        try chmodPath(want, 0o755);
        if (geode.graph_store.defaultDataDir(allocator)) |got| {
            allocator.free(got);
            std.debug.print("SONNY-6325: a 0755 per-user tmp data directory was accepted\n", .{});
            try testing.expect(false);
        } else |err| try expectErr(error.UnsafeDefaultDataDir, err);
        try testing.expectEqual(@as(u32, 0o755), permBits(lstatx(want).?));
        try std.Io.Dir.cwd().deleteTree(fsIo(), want);
    }
    // A symbolic link planted at the path: refused, the target untouched.
    {
        const target = try fx.path(allocator, "attacker-dir");
        defer allocator.free(target);
        try std.Io.Dir.cwd().createDirPath(fsIo(), target);
        try chmodPath(target, 0o700);
        try std.Io.Dir.cwd().symLink(fsIo(), target, want, .{});
        if (geode.graph_store.defaultDataDir(allocator)) |got| {
            allocator.free(got);
            std.debug.print("SONNY-6325: a symbolic link at the per-user tmp data directory was accepted\n", .{});
            try testing.expect(false);
        } else |err| try expectErr(error.UnsafeDefaultDataDir, err);
        try testing.expect(isSymlink(lstatx(want).?));
    }
    // XDG_STATE_HOME still wins when set (ENG-3921 order unchanged).
    {
        const xdg = try fx.path(allocator, "xdg");
        defer allocator.free(xdg);
        try setenvZ("XDG_STATE_HOME", xdg);
        const got = try geode.graph_store.defaultDataDir(allocator);
        defer allocator.free(got);
        const want_xdg = try join(allocator, xdg, "geode");
        defer allocator.free(want_xdg);
        try testing.expectEqualStrings(want_xdg, got);
    }
}

// ===========================================================================
// (6) createFullBackup without a data directory
// ===========================================================================

test "SONNY-6325 (6) a backup with no data directory configured is refused, never a backup of /tmp" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (comptime !@hasDecl(backup, "backupSourceDataDir")) {
        std.debug.print("SONNY-6325: storage/backup has no checked data-directory resolution: createFullBackup archives /tmp when no data directory is set (src/storage/backup.zig createFullBackup)\n", .{});
        return error.TestUnexpectedResult;
    } else try backupNoDataDirCase();
}

fn backupNoDataDirCase() !void {
    const allocator = testing.allocator;
    const env_names = [_][:0]const u8{"GEODE_DATA_DIR"};
    var saved = EnvSave.save(&env_names);
    defer saved.restore();
    try setenvZ("GEODE_DATA_DIR", "");
    geode.graph_store.setDataDirOverride(allocator, null);
    try testing.expectError(error.BackupDataDirUnknown, backup.backupSourceDataDir(allocator));

    var fx = try Fixture.init(allocator, "sonny6325-backup-nodir");
    defer fx.deinit(allocator);
    const bdir = try fx.path(allocator, "backups");
    defer allocator.free(bdir);
    var store = try geode.graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var mgr = try backup.BackupManager.init(allocator, bdir, .{}, &store);
    defer mgr.deinit();
    try testing.expectError(error.BackupDataDirUnknown, mgr.createFullBackup());
}
