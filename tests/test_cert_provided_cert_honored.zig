// CANARY: REQ=REQ-CLUSTER-CERT-PROVIDED-HONORED; FEATURE="DistributedClusterTLS"; ASPECT=ExplicitCertNotDiscarded; STATUS=TESTED; TEST=tests/test_cert_provided_cert_honored.zig; OWNER=distributed; UPDATED=2026-06-04
//
// Regression for docs/bugs/2026-06-04-cluster-cert-provided-cert-discarded-containerized.md
//
// geode silently discarded an explicitly-provided --cert/--key and self-signed
// when containerized, which broke 3-node Kubernetes cluster TLS (every node
// presented a different self-signed cert on the Raft port → HandshakeError →
// no leader). Two distinct defects:
//
//   Defect 1 (logic): `ensureCertificatesAtPath` treated an operator-provided
//     --cert the same as the default/auto cert — i.e. "generate-if-missing".
//     A missing provided cert was SILENTLY self-signed (a security downgrade),
//     and a read-only provided path fell back to a throwaway /tmp self-signed
//     cert. An explicit --cert must be loaded as-is and the server must fail
//     loud if it can't be read.
//
//   Defect 2 (probe): the existence probe used
//     `std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), ...)`
//     (the `.failing` allocator) under a bare `catch {}` that swallowed ALL
//     errors and regenerated, making the outcome environment-sensitive
//     (PVC-vs-emptyDir data-dir, pipe-vs-file stdout all flipped it).
//
// The fix:
//   - cert_gen.certFileReadable: allocation-free, Io-independent readability
//     check via a raw openat() syscall (no global_single_threaded, no .failing
//     allocator).
//   - cert_gen.requireExistingCertificates: verify an operator-provided pair is
//     readable; never generate, never fall back, fail loud otherwise.
//   - main.zig branches: explicit --cert/--key => requireExistingCertificates
//     (load-as-is + fail loud); only the auto path keeps generate-if-missing.
//
// Tests in this file (the doc prescribes a subprocess test whose stdout is a
// PIPE — the in-process cluster tests always ran on writable cwd with file
// stdio and so missed this):
//
//   C. e2e (subprocess, stdout=PIPE): `geode serve --cert=<MISSING>` must
//      REFUSE to start (non-zero exit) and must NOT print "Generated
//      self-signed certificates" and must NOT create /tmp/geode-server.crt.
//   D. e2e (subprocess, stdout=PIPE): `geode serve --cert=<EXISTING provided>`
//      must LOAD the provided cert (prints the "operator-provided TLS
//      certificate" marker), must NOT self-sign, must NOT create /tmp cert,
//      and must leave the provided cert byte-for-byte unchanged.
//
// Unit tests for cert_gen.certFileReadable / requireExistingCertificates live
// alongside these once the helpers exist (see the bottom of this file).
//
// Skip semantics: SKIP (never silently pass) when the geode binary is missing
// (run `zig build` first) or when openssl is unavailable for fixture creation.

const std = @import("std");
const builtin = @import("builtin");
const cert_gen = @import("cert_gen");

const BINARY_PATH = "./zig-out/bin/geode";

// ---------------------------------------------------------------------------
// Zig 0.16 compat helpers (mirrored from tests/test_cluster_3node_subprocess.zig)
// ---------------------------------------------------------------------------

fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

fn nowMillis() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    if (comptime builtin.os.tag == .linux) {
        const req = std.os.linux.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
    } else {
        const req = std.c.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
    }
}

fn setNonBlocking(file: std.Io.File) !void {
    if (comptime builtin.os.tag != .linux) return;
    const fd = file.handle;
    const flags = std.os.linux.fcntl(fd, std.posix.F.GETFL, 0);
    if (@as(isize, @bitCast(flags)) < 0) return error.FcntlGetFailed;
    const new_flags = flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }));
    const rc = std.os.linux.fcntl(fd, std.posix.F.SETFL, new_flags);
    if (@as(isize, @bitCast(rc)) < 0) return error.FcntlSetFailed;
}

fn binaryPresent() bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, BINARY_PATH, .{}) catch return false;
    return true;
}

/// Remove any stale /tmp self-signed cert so we can detect a fresh one being
/// generated by the child during this test.
fn clearTmpSelfSigned(io: std.Io) void {
    std.Io.Dir.cwd().deleteFile(io, "/tmp/geode-server.crt") catch {};
    std.Io.Dir.cwd().deleteFile(io, "/tmp/geode-server.key") catch {};
}

fn tmpSelfSignedExists(io: std.Io) bool {
    std.Io.Dir.cwd().access(io, "/tmp/geode-server.crt", .{}) catch return false;
    return true;
}

/// Build a child Environ.Map carrying enough of the parent env that the child
/// can run (PATH/HOME for openssl, LD_LIBRARY_PATH for shared libs) plus an
/// admin password so auth bootstrap never blocks.
fn buildChildEnv(aa: std.mem.Allocator) !*std.process.Environ.Map {
    const env_ptr = try aa.create(std.process.Environ.Map);
    env_ptr.* = std.process.Environ.Map.init(aa);
    try env_ptr.put("GEODE_ADMIN_PASSWORD", "GeodeTestPassword123!");
    if (posixGetenv("PATH")) |p| try env_ptr.put("PATH", p);
    if (posixGetenv("HOME")) |p| try env_ptr.put("HOME", p);
    if (posixGetenv("LD_LIBRARY_PATH")) |p| try env_ptr.put("LD_LIBRARY_PATH", p);
    return env_ptr;
}

fn runOpenssl(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(gpa, io, .{ .argv = argv });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.OpensslFailed;
}

/// Generate a self-signed EC P-256 leaf (CN=geode-provided, SAN localhost) that
/// stands in for an operator-provided cert. Returns paths under a fresh temp dir.
const Provided = struct { dir: []const u8, crt: []const u8, key: []const u8 };

fn makeProvidedCert(aa: std.mem.Allocator) !Provided {
    const spawn_gpa = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(spawn_gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    runOpenssl(spawn_gpa, io, &.{ "openssl", "version" }) catch return error.SkipZigTest;

    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-cert-honored-{d}", .{std.os.linux.getpid()});
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const crt = try std.fmt.allocPrint(aa, "{s}/provided.crt", .{dir});
    const key = try std.fmt.allocPrint(aa, "{s}/provided.key", .{dir});

    try runOpenssl(spawn_gpa, io, &.{
        "openssl",            "req",                          "-x509",                                     "-newkey", "ec",
        "-pkeyopt",           "ec_paramgen_curve:prime256v1", "-keyout",                                   key,       "-out",
        crt,                  "-days",                        "1",                                         "-nodes",  "-subj",
        "/CN=geode-provided", "-addext",                      "subjectAltName=DNS:localhost,IP:127.0.0.1",
    });
    return .{ .dir = dir, .crt = crt, .key = key };
}

/// Read a small file (e.g. a PEM cert) into `out`, returning the slice of bytes
/// actually read. Used to prove the provided cert is left byte-for-byte intact.
fn readSmallFile(io: std.Io, path: []const u8, out: []u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const n = try f.readPositionalAll(io, out, 0);
    return out[0..n];
}

// ---------------------------------------------------------------------------
// C. Missing explicit --cert must REFUSE to start (not silently self-sign).
// ---------------------------------------------------------------------------

test "explicit --cert pointing at a missing file refuses to start (no silent self-sign)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (!binaryPresent()) {
        std.debug.print("geode binary missing at {s}; run `zig build` first\n", .{BINARY_PATH});
        return error.SkipZigTest;
    }
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var spawn_threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer spawn_threaded.deinit();
    const io = spawn_threaded.io();

    clearTmpSelfSigned(io);

    const data_dir = try std.fmt.allocPrint(aa, "/tmp/geode-cert-honored-c-{d}", .{nowMillis()});
    std.Io.Dir.cwd().createDirPath(io, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    const missing_crt = try std.fmt.allocPrint(aa, "{s}/does-not-exist.crt", .{data_dir});
    const missing_key = try std.fmt.allocPrint(aa, "{s}/does-not-exist.key", .{data_dir});

    const data_arg = try std.fmt.allocPrint(aa, "--data-dir={s}", .{data_dir});
    const cert_arg = try std.fmt.allocPrint(aa, "--cert={s}", .{missing_crt});
    const key_arg = try std.fmt.allocPrint(aa, "--key={s}", .{missing_key});
    const args = [_][]const u8{
        BINARY_PATH,
        "serve",
        "--listen=127.0.0.1:31581",
        data_arg,
        cert_arg,
        key_arg,
    };
    const env_ptr = try buildChildEnv(aa);

    // stdout/stderr = PIPE (the exact launch context that flipped the bug).
    // A correct server REFUSES and exits; a buggy server silently self-signs
    // and keeps running, which we detect as "no EOF before the deadline".
    var child = try std.process.spawn(io, .{
        .argv = &args,
        .environ_map = env_ptr,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var reaped = false;
    defer if (!reaped) child.kill(io);

    try setNonBlocking(child.stdout.?);
    try setNonBlocking(child.stderr.?);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(gpa);

    var buf: [4096]u8 = undefined;
    const deadline = nowMillis() + 15_000;
    var eof_out = false;
    var eof_err = false;
    var self_signed = false;
    while (nowMillis() < deadline and !(eof_out and eof_err)) {
        var progressed = false;
        if (!eof_out) {
            const n = child.stdout.?.readStreaming(io, &.{&buf}) catch |err| switch (err) {
                error.WouldBlock => @as(usize, 0),
                error.EndOfStream => blk: {
                    eof_out = true;
                    break :blk @as(usize, 0);
                },
                else => @as(usize, 0),
            };
            if (n > 0) {
                progressed = true;
                try captured.appendSlice(gpa, buf[0..n]);
            }
        }
        if (!eof_err) {
            const n = child.stderr.?.readStreaming(io, &.{&buf}) catch |err| switch (err) {
                error.WouldBlock => @as(usize, 0),
                error.EndOfStream => blk: {
                    eof_err = true;
                    break :blk @as(usize, 0);
                },
                else => @as(usize, 0),
            };
            if (n > 0) {
                progressed = true;
                try captured.appendSlice(gpa, buf[0..n]);
            }
        }
        if (std.mem.indexOf(u8, captured.items, "Generated self-signed") != null) {
            self_signed = true;
            break;
        }
        if (!progressed) sleepMs(50);
    }

    const child_exited = eof_out and eof_err;

    // A silently self-signed cert is the security-downgrade footgun.
    if (self_signed) {
        if (child_exited) {
            _ = child.wait(io) catch {};
        } else {
            child.kill(io);
        }
        reaped = true;
        std.debug.print(
            "FAIL: geode self-signed instead of refusing a missing explicit --cert.\ncaptured:\n{s}\n",
            .{captured.items},
        );
        return error.ExplicitMissingCertSelfSigned;
    }

    // Still running at the deadline => it started serving instead of refusing.
    if (!child_exited) {
        child.kill(io);
        reaped = true;
        std.debug.print(
            "FAIL: geode serve did not refuse a missing explicit --cert; still running.\ncaptured:\n{s}\n",
            .{captured.items},
        );
        return error.ExplicitMissingCertNotRefused;
    }

    // It exited — confirm it was a non-zero (fail-loud) exit, not a clean start.
    const term = child.wait(io) catch |err| {
        std.debug.print("child.wait failed: {s}\n", .{@errorName(err)});
        reaped = true;
        return err;
    };
    reaped = true;
    switch (term) {
        .exited => |code| {
            if (code == 0) {
                std.debug.print(
                    "FAIL: geode serve exited 0 with a missing explicit --cert.\ncaptured:\n{s}\n",
                    .{captured.items},
                );
                return error.ExplicitMissingCertNotRefused;
            }
        },
        // A non-exited terminal status (signal/unknown) still means it did not
        // start serving with a self-signed cert; treat as "refused".
        else => {},
    }

    // Must NOT have fallen back to a throwaway /tmp cert.
    try std.testing.expect(!tmpSelfSignedExists(io));
}

// ---------------------------------------------------------------------------
// D. Existing explicit --cert must be LOADED as-is (never discarded/self-signed).
// ---------------------------------------------------------------------------

test "explicit --cert pointing at a real cert is loaded as-is (not discarded)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (!binaryPresent()) {
        std.debug.print("geode binary missing at {s}; run `zig build` first\n", .{BINARY_PATH});
        return error.SkipZigTest;
    }
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var spawn_threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer spawn_threaded.deinit();
    const io = spawn_threaded.io();

    const provided = makeProvidedCert(aa) catch |err| {
        if (err == error.SkipZigTest) return error.SkipZigTest;
        return err;
    };
    defer std.Io.Dir.cwd().deleteTree(io, provided.dir) catch {};

    // Snapshot the provided cert up front so we can prove it is left untouched.
    var before_buf: [64 * 1024]u8 = undefined;
    var after_buf: [64 * 1024]u8 = undefined;
    const before = try readSmallFile(io, provided.crt, &before_buf);

    clearTmpSelfSigned(io);

    const data_dir = try std.fmt.allocPrint(aa, "/tmp/geode-cert-honored-d-{d}", .{nowMillis()});
    std.Io.Dir.cwd().createDirPath(io, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    const data_arg = try std.fmt.allocPrint(aa, "--data-dir={s}", .{data_dir});
    const cert_arg = try std.fmt.allocPrint(aa, "--cert={s}", .{provided.crt});
    const key_arg = try std.fmt.allocPrint(aa, "--key={s}", .{provided.key});
    const args = [_][]const u8{
        BINARY_PATH,
        "serve",
        "--listen=127.0.0.1:31582",
        data_arg,
        cert_arg,
        key_arg,
    };
    const env_ptr = try buildChildEnv(aa);

    var child = try std.process.spawn(io, .{
        .argv = &args,
        .environ_map = env_ptr,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var killed = false;
    defer if (!killed) child.kill(io);

    try setNonBlocking(child.stdout.?);
    try setNonBlocking(child.stderr.?);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(gpa);

    var buf: [4096]u8 = undefined;
    const deadline = nowMillis() + 20_000;
    var loaded_marker = false;
    var self_signed = false;
    var child_exited = false;
    while (nowMillis() < deadline) {
        var progressed = false;
        inline for (.{ child.stdout, child.stderr }) |maybe_stream| {
            if (maybe_stream) |stream| {
                const n = stream.readStreaming(io, &.{&buf}) catch |err| switch (err) {
                    error.WouldBlock => @as(usize, 0),
                    error.EndOfStream => blk: {
                        child_exited = true;
                        break :blk @as(usize, 0);
                    },
                    else => @as(usize, 0),
                };
                if (n > 0) {
                    progressed = true;
                    try captured.appendSlice(gpa, buf[0..n]);
                }
            }
        }
        if (std.mem.indexOf(u8, captured.items, "operator-provided TLS certificate") != null) {
            loaded_marker = true;
        }
        if (std.mem.indexOf(u8, captured.items, "Generated self-signed") != null) {
            self_signed = true;
        }
        // Success as soon as we see the provided cert was loaded AND the
        // listener is up.
        if (loaded_marker and std.mem.indexOf(u8, captured.items, "\"status\":\"listening\"") != null) break;
        if (self_signed) break;
        if (child_exited and !progressed) break;
        if (!progressed) sleepMs(50);
    }

    child.kill(io);
    killed = true;

    if (self_signed) {
        std.debug.print(
            "FAIL: geode self-signed/discarded an explicitly-provided --cert.\ncaptured:\n{s}\n",
            .{captured.items},
        );
        return error.ProvidedCertDiscarded;
    }
    if (!loaded_marker) {
        std.debug.print(
            "FAIL: geode never logged that it loaded the operator-provided cert.\ncaptured:\n{s}\n",
            .{captured.items},
        );
        return error.ProvidedCertNotLoaded;
    }

    // The provided cert must be left byte-for-byte unchanged.
    const after = try readSmallFile(io, provided.crt, &after_buf);
    try std.testing.expectEqualSlices(u8, before, after);

    // No throwaway /tmp cert must have been generated.
    try std.testing.expect(!tmpSelfSignedExists(io));
}

// ---------------------------------------------------------------------------
// A/B. Unit tests for the cert_gen helpers (deterministic, no subprocess).
// ---------------------------------------------------------------------------

test "certFileReadable: true for an existing file, false for a missing path" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try std.fmt.allocPrint(std.testing.allocator, "/tmp/geode-certreadable-{d}", .{std.os.linux.getpid()});
    defer std.testing.allocator.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const present = try std.fmt.allocPrint(std.testing.allocator, "{s}/present.pem", .{dir});
    defer std.testing.allocator.free(present);
    const missing = try std.fmt.allocPrint(std.testing.allocator, "{s}/missing.pem", .{dir});
    defer std.testing.allocator.free(missing);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = present, .data = "x" });

    try std.testing.expect(cert_gen.certFileReadable(present));
    try std.testing.expect(!cert_gen.certFileReadable(missing));
}

test "requireExistingCertificates: ok for a real pair, error when missing, never writes /tmp" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    clearTmpSelfSigned(io);

    const dir = try std.fmt.allocPrint(std.testing.allocator, "/tmp/geode-requirecert-{d}", .{std.os.linux.getpid()});
    defer std.testing.allocator.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const crt = try std.fmt.allocPrint(std.testing.allocator, "{s}/server.crt", .{dir});
    defer std.testing.allocator.free(crt);
    const key = try std.fmt.allocPrint(std.testing.allocator, "{s}/server.key", .{dir});
    defer std.testing.allocator.free(key);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = crt, .data = "cert" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = key, .data = "key" });

    // Real pair => ok.
    try cert_gen.requireExistingCertificates(crt, key);

    // Missing cert => fail loud.
    const missing = try std.fmt.allocPrint(std.testing.allocator, "{s}/nope.crt", .{dir});
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.ProvidedCertificateUnreadable, cert_gen.requireExistingCertificates(missing, key));

    // Missing key => fail loud.
    const missing_key = try std.fmt.allocPrint(std.testing.allocator, "{s}/nope.key", .{dir});
    defer std.testing.allocator.free(missing_key);
    try std.testing.expectError(error.ProvidedKeyUnreadable, cert_gen.requireExistingCertificates(crt, missing_key));

    // None of the above ever fabricated a throwaway /tmp cert.
    try std.testing.expect(!tmpSelfSignedExists(io));
}
