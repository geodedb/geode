const std = @import("std");
const builtin = @import("builtin");

// Simple self-signed certificate generator for development/testing
// In production, use proper CA-signed certificates

// SONNY-6325: the generator and the auto-key checks live in the tls_material
// module (shared with the QUIC listener): openssl writes into a private
// staging directory and the pair is installed exclusive, no-follow, key 0600.
const tls_material = @import("tls_material");

pub fn generateSelfSignedCert(allocator: std.mem.Allocator, hostname: []const u8, cert_path: []const u8, key_path: []const u8) !void {
    const subj = try std.fmt.allocPrint(allocator, "/CN={s}", .{hostname});
    defer allocator.free(subj);
    const alt_names = try std.fmt.allocPrint(
        allocator,
        "subjectAltName=DNS:{s},DNS:localhost,IP:127.0.0.1,IP:::1",
        .{hostname},
    );
    defer allocator.free(alt_names);
    try tls_material.generateSelfSigned(cert_path, key_path, .{ .subject = subj, .addext = alt_names });
}

// CANARY: REQ=REQ-SONNY-6325-NO-FIXED-TMP; FEATURE="Secret File Hygiene"; ASPECT=CertGenExplicitDir; STATUS=TESTED; TEST=tests/test_sonny6325_no_fixed_tmp_paths.zig; OWNER=security; UPDATED=2026-11-11
/// SONNY-6325: generate `<dir>/server.crt` and `<dir>/server.key` (the
/// cert_gen tool). There is no default directory: the tool used to fall back
/// to the fixed /tmp/geode-server.{crt,key}.
pub fn ensureCertificatesInDir(allocator: std.mem.Allocator, dir: []const u8) !void {
    const cert_path = try std.fmt.allocPrint(allocator, "{s}/server.crt", .{dir});
    defer allocator.free(cert_path);
    const key_path = try std.fmt.allocPrint(allocator, "{s}/server.key", .{dir});
    defer allocator.free(key_path);
    try ensureCertificatesAtPath(allocator, cert_path, key_path);
}

/// Robust, allocation-free readability check for a certificate/key file.
///
/// This deliberately does NOT use `std.Io.Dir.access` over
/// `std.Io.Threaded.global_single_threaded` (whose allocator is `.failing`):
/// that probe was empirically environment-sensitive when geode runs as a
/// container entrypoint (PVC-backed data-dir, stdout = container log pipe), so
/// a perfectly readable operator-provided cert could be misreported as missing
/// and silently regenerated. See
/// docs/bugs/2026-06-04-cluster-cert-provided-cert-discarded-containerized.md.
///
/// Instead we attempt to open the file for reading with a raw `openat`
/// syscall and let the open's result be authoritative. No allocator, no
/// `std.Io.Threaded` cancellation machinery, no dependence on process session,
/// cwd, stdout fd, or the backing filesystem.
pub fn certFileReadable(path: []const u8) bool {
    if (comptime builtin.os.tag == .linux) {
        // AT.FDCWD resolves `path` relative to cwd for relative paths and
        // ignores it for absolute paths — same semantics as the old probe,
        // minus the failing-allocator fragility. `std.posix.close` was
        // removed in Zig 0.16; use the raw linux close.
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return false;
        defer _ = std.os.linux.close(fd);
        return true;
    }
    // Portable fallback (macOS/Windows): open via a LOCAL Threaded backed by a
    // real allocator — never the `.failing` global_single_threaded.
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

/// Verify that an operator-PROVIDED cert+key pair exists and is readable.
///
/// Unlike `ensureCertificatesAtPath`, this NEVER generates, NEVER overwrites,
/// and NEVER falls back to a throwaway self-signed cert. An explicitly-provided
/// `--cert`/`--key` must be loaded exactly as supplied; if it cannot be read,
/// the caller must fail loud (refuse to start) rather than silently self-sign,
/// which would be a security downgrade. See
/// docs/bugs/2026-06-04-cluster-cert-provided-cert-discarded-containerized.md.
pub fn requireExistingCertificates(cert_path: []const u8, key_path: []const u8) error{ ProvidedCertificateUnreadable, ProvidedKeyUnreadable }!void {
    if (!certFileReadable(cert_path)) return error.ProvidedCertificateUnreadable;
    if (!certFileReadable(key_path)) return error.ProvidedKeyUnreadable;
}

// CANARY: REQ=REQ-SONNY-6325-NO-FIXED-TMP; FEATURE="Secret File Hygiene"; ASPECT=AutoKeyChecks; STATUS=TESTED; TEST=tests/test_sonny6325_no_fixed_tmp_paths.zig; OWNER=security; UPDATED=2026-11-11
/// The auto path (no --cert/--key): use the pair at `cert_path`/`key_path`
/// (the data directory or GEODE_CERT_DIR), or generate one when neither file
/// exists.
///
/// SONNY-6325: an existing key is used only when it is a regular file (not a
/// symbolic link) owned by this user with no group/other permission bits
/// (`tls_material.checkAutoKey`); otherwise the server refuses with the
/// reason, and never chmods or replaces it. A key without its certificate, or
/// a certificate without its key, is refused (error.IncompleteTlsMaterial):
/// it used to regenerate both through openssl, which replaced an existing key
/// and followed a symbolic link planted at either path. A new pair is
/// installed exclusive and no-follow, key 0600, certificate 0644.
/// The operator-facing reason for an `ensureCertificatesAtPath` failure.
pub fn describeTlsError(err: anyerror) []const u8 {
    return switch (err) {
        error.TlsKeyIsSymlink,
        error.TlsKeyNotRegularFile,
        error.TlsKeyForeignOwner,
        error.TlsKeyGroupOrWorldAccessible,
        error.TlsKeyUnreadable,
        error.IncompleteTlsMaterial,
        => tls_material.describeKeyError(err),
        error.TlsFileExists => "a file appeared at the key or certificate path while it was being generated",
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => "the directory is not writable by this user",
        error.CertificateGenerationFailed => "openssl could not generate the certificate",
        else => "it could not be generated",
    };
}

pub fn ensureCertificatesAtPath(allocator: std.mem.Allocator, cert_path: []const u8, key_path: []const u8) !void {
    const key_state = try tls_material.checkAutoKey(key_path);
    const cert_present = tls_material.pathPresent(cert_path);
    switch (key_state) {
        .usable => {
            if (cert_present) return;
            return error.IncompleteTlsMaterial;
        },
        .absent => if (cert_present) return error.IncompleteTlsMaterial,
    }
    try generateSelfSignedCert(allocator, "geode.local", cert_path, key_path);
    std.debug.print("Generated self-signed certificates at {s} and {s}\n", .{ cert_path, key_path });
}

pub fn main(proc_init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const argv = proc_init.args.vector;
    const dir: []const u8 = if (argv.len == 2) std.mem.span(argv[1]) else "";
    if (dir.len == 0 or std.mem.startsWith(u8, dir, "-")) {
        std.debug.print("usage: cert_gen <output-dir>\n" ++
            "Writes <output-dir>/server.crt (0644) and <output-dir>/server.key (0600).\n" ++
            "There is no default directory (SONNY-6325).\n", .{});
        std.process.exit(2);
    }
    try ensureCertificatesInDir(allocator, dir);
    std.debug.print("TLS certificates ready\n", .{});
}
