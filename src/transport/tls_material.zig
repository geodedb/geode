//! SONNY-6325: auto-generated TLS material — the self-signed certificate and
//! private key a server makes for itself when the operator supplies none.
//!
//! Shared by the `geode serve` startup path (tools/cert_gen.zig) and the QUIC
//! listener's own fallback (transport/quic.zig). A module of its own because
//! cert_gen.zig is compiled into several modules and a file may belong to only
//! one module per compilation (the same reason as spawn_io).
//!
//! The rules:
//!   - nothing is written to a fixed shared path: the caller passes paths in
//!     the data directory or GEODE_CERT_DIR;
//!   - openssl writes into a private staging directory (random name, 0700)
//!     inside the key's directory, and the key and certificate are then
//!     installed with O_CREAT | O_EXCL | O_NOFOLLOW (key 0600, certificate
//!     0644): a file or a symbolic link already at either path is never
//!     followed, truncated or replaced;
//!   - an existing auto key is used only when it is a regular file (not a
//!     symbolic link) owned by the server's user with no group or other
//!     permission bits (`checkAutoKey`). It is never chmod-ed.
//!
//! An operator-PROVIDED --cert/--key is not checked here: it is loaded as-is
//! (cert_gen.requireExistingCertificates), mounted secrets are often links.

const std = @import("std");
const builtin = @import("builtin");
const spawn_io = @import("spawn_io");

const linux = std.os.linux;

pub const KeyState = enum {
    /// Nothing at the key path.
    absent,
    /// A regular file owned by this user, mode without group/other bits.
    usable,
};

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn effectiveUid() u32 {
    return if (comptime builtin.os.tag == .linux) linux.geteuid() else std.c.geteuid();
}

/// Whether anything (a file, a directory, a symbolic link, dangling or not)
/// is at `path`.
pub fn pathPresent(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(fsIo(), path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

/// Check an existing auto-generated key before it is used. Never follows a
/// symbolic link and never changes the file.
pub fn checkAutoKey(path: []const u8) error{ TlsKeyIsSymlink, TlsKeyNotRegularFile, TlsKeyForeignOwner, TlsKeyGroupOrWorldAccessible, TlsKeyUnreadable }!KeyState {
    if (comptime builtin.os.tag == .linux) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return error.TlsKeyUnreadable;
        var st: linux.Statx = undefined;
        const rc = linux.statx(linux.AT.FDCWD, z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &st);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .NOENT => return .absent,
            else => return error.TlsKeyUnreadable,
        }
        const kind = st.mode & linux.S.IFMT;
        if (kind == linux.S.IFLNK) return error.TlsKeyIsSymlink;
        if (kind != linux.S.IFREG) return error.TlsKeyNotRegularFile;
        if (st.uid != effectiveUid()) return error.TlsKeyForeignOwner;
        if (st.mode & 0o077 != 0) return error.TlsKeyGroupOrWorldAccessible;
        return .usable;
    }
    const st = std.Io.Dir.cwd().statFile(fsIo(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => return error.TlsKeyUnreadable,
    };
    switch (st.kind) {
        .sym_link => return error.TlsKeyIsSymlink,
        .file => {},
        else => return error.TlsKeyNotRegularFile,
    }
    if (comptime builtin.os.tag != .windows) {
        if (st.permissions.toMode() & 0o077 != 0) return error.TlsKeyGroupOrWorldAccessible;
    }
    return .usable;
}

/// What a key check failure means, for the operator.
pub fn describeKeyError(err: anyerror) []const u8 {
    return switch (err) {
        error.TlsKeyIsSymlink => "is a symbolic link",
        error.TlsKeyNotRegularFile => "is not a regular file",
        error.TlsKeyForeignOwner => "is owned by another user",
        error.TlsKeyGroupOrWorldAccessible => "is readable or writable by group or others (want mode 0600)",
        error.TlsKeyUnreadable => "cannot be inspected",
        error.IncompleteTlsMaterial => "has no matching certificate (or the certificate has no key)",
        else => "cannot be used",
    };
}

fn fillRandom(buf: []u8) void {
    if (comptime builtin.os.tag == .linux) {
        _ = linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

/// Create `<parent>/.geode-tls-<random>` mode 0700, exclusively. Caller frees
/// the path and removes the directory.
fn makeStagingDir(allocator: std.mem.Allocator, parent: []const u8) ![]u8 {
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        var rnd: [8]u8 = undefined;
        fillRandom(&rnd);
        const path = try std.fmt.allocPrint(allocator, "{s}/.geode-tls-{x}", .{ parent, std.mem.readInt(u64, &rnd, .little) });
        errdefer allocator.free(path);
        std.Io.Dir.cwd().createDir(fsIo(), path, std.Io.File.Permissions.fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                if (attempt < 8) continue;
                return err;
            },
            else => return err,
        };
        return path;
    }
}

/// Create `path` with O_CREAT | O_EXCL | O_NOFOLLOW and `mode` (set again on
/// the open file, so no umask changes it) and write `bytes`. Fails with
/// error.TlsFileExists, writing nothing, when anything is at `path`. A file it
/// cannot complete is removed.
fn installExclusive(path: []const u8, bytes: []const u8, mode: u32) !void {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, @intCast(mode)) catch |err| switch (err) {
        error.PathAlreadyExists => return error.TlsFileExists,
        else => return err,
    };
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(fsIo());
    errdefer std.Io.Dir.cwd().deleteFile(fsIo(), path) catch {};
    try file.setPermissions(fsIo(), std.Io.File.Permissions.fromMode(@intCast(mode)));
    try file.writeStreamingAll(fsIo(), bytes);
    try file.sync(fsIo());
}

pub const SelfSignedOptions = struct {
    /// openssl `-subj`, e.g. "/CN=geode.local".
    subject: []const u8,
    /// openssl `-addext` (e.g. a subjectAltName), when not null.
    addext: ?[]const u8 = null,
};

/// Generate a self-signed ECDSA P-256 certificate and key and install them
/// at `cert_path` (0644) and `key_path` (0600), exclusively. Nothing already
/// at either path is touched (error.TlsFileExists). The key bytes are never
/// logged and are zeroed after use.
pub fn generateSelfSigned(cert_path: []const u8, key_path: []const u8, opts: SelfSignedOptions) !void {
    const gpa = std.heap.smp_allocator;
    var threaded = spawn_io.threaded();
    defer threaded.deinit();
    const io = threaded.io();

    if (pathPresent(key_path) or pathPresent(cert_path)) return error.TlsFileExists;

    const key_dir = std.fs.path.dirname(key_path) orelse ".";
    if (std.fs.path.dirname(cert_path)) |cert_dir| {
        std.Io.Dir.cwd().createDirPath(io, cert_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    std.Io.Dir.cwd().createDirPath(io, key_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const staging = try makeStagingDir(gpa, key_dir);
    defer gpa.free(staging);
    defer std.Io.Dir.cwd().deleteTree(fsIo(), staging) catch {};
    const staged_key = try std.fmt.allocPrint(gpa, "{s}/key.pem", .{staging});
    defer gpa.free(staged_key);
    const staged_cert = try std.fmt.allocPrint(gpa, "{s}/cert.pem", .{staging});
    defer gpa.free(staged_cert);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        "openssl",    "req",                          "-x509",   "-newkey",  "ec",
        "-pkeyopt",   "ec_paramgen_curve:prime256v1", "-keyout", staged_key, "-out",
        staged_cert,  "-days",                        "365",     "-nodes",   "-subj",
        opts.subject,
    });
    if (opts.addext) |ext| try argv.appendSlice(gpa, &.{ "-addext", ext });

    const result = try std.process.run(gpa, io, .{ .argv = argv.items });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("Failed to generate certificate: {s}\n", .{result.stderr});
        return error.CertificateGenerationFailed;
    }

    const key_bytes = try std.Io.Dir.cwd().readFileAlloc(fsIo(), staged_key, gpa, .limited(64 * 1024));
    defer {
        std.crypto.secureZero(u8, key_bytes);
        gpa.free(key_bytes);
    }
    const cert_bytes = try std.Io.Dir.cwd().readFileAlloc(fsIo(), staged_cert, gpa, .limited(64 * 1024));
    defer gpa.free(cert_bytes);

    try installExclusive(key_path, key_bytes, 0o600);
    errdefer std.Io.Dir.cwd().deleteFile(fsIo(), key_path) catch {};
    try installExclusive(cert_path, cert_bytes, 0o644);
}
