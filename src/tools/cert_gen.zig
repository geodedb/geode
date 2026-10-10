const std = @import("std");
const builtin = @import("builtin");
// SONNY-2394: the signal-safe, environment-carrying Io openssl is spawned with
// (shared with transport/quic.zig).
const spawn_io = @import("spawn_io");

// Simple self-signed certificate generator for development/testing
// In production, use proper CA-signed certificates

pub fn generateSelfSignedCert(allocator: std.mem.Allocator, hostname: []const u8, cert_path: []const u8, key_path: []const u8) !void {
    _ = allocator;
    // Extract directory from cert_path
    const cert_dir = std.fs.path.dirname(cert_path) orelse ".";

    // Zig 0.16 note: the stdlib's `global_single_threaded` Threaded instance
    // ships with `.allocator = .failing`, so any `std.process.run` through it
    // OOMs immediately inside `spawnPosix`'s internal arena. SONNY-2394: nor
    // `std.Io.Threaded.init(gpa, .{})`, which this used to be: it swaps
    // process-wide SIGIO/SIGPIPE handlers, and its environment is EMPTY, so
    // openssl was found only on std's fixed default PATH and never saw
    // OPENSSL_CONF. `spawn_io` has a real allocator, installs no handler, and
    // carries the process environment. `smp_allocator` also backs the argv
    // strings and captured output below (the governance gate forbids
    // `page_allocator` in src/).
    const spawn_gpa = std.heap.smp_allocator;
    var local_threaded = spawn_io.threaded();
    defer local_threaded.deinit();
    const io = local_threaded.io();

    // Create certificate directory if it doesn't exist
    std.Io.Dir.cwd().createDirPath(io, cert_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Use OpenSSL to generate self-signed ECDSA P-256 certificate.

    const subj = try std.fmt.allocPrint(spawn_gpa, "/CN={s}", .{hostname});
    defer spawn_gpa.free(subj);
    const alt_names = try std.fmt.allocPrint(
        spawn_gpa,
        "subjectAltName=DNS:{s},DNS:localhost,IP:127.0.0.1,IP:::1",
        .{hostname},
    );
    defer spawn_gpa.free(alt_names);

    const result = try std.process.run(spawn_gpa, io, .{
        .argv = &[_][]const u8{
            "openssl",                      "req",
            "-x509",                        "-newkey",
            "ec",                           "-pkeyopt",
            "ec_paramgen_curve:prime256v1", "-keyout",
            key_path,                       "-out",
            cert_path,                      "-days",
            "365",                          "-nodes",
            "-subj",                        subj,
            "-addext",                      alt_names,
        },
    });
    defer spawn_gpa.free(result.stdout);
    defer spawn_gpa.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("Failed to generate certificate: {s}\n", .{result.stderr});
        return error.CertificateGenerationFailed;
    }
}

pub fn ensureCertificates(allocator: std.mem.Allocator) !void {
    ensureCertificatesAtPath(allocator, "certs/server.crt", "certs/server.key") catch |err| {
        // If certs directory fails, try /tmp as fallback
        if (err == error.AccessDenied or err == error.FileNotFound) {
            try ensureCertificatesAtPath(allocator, "/tmp/geode-server.crt", "/tmp/geode-server.key");
        } else {
            return err;
        }
    };
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
/// and NEVER falls back to a throwaway `/tmp` cert. An explicitly-provided
/// `--cert`/`--key` must be loaded exactly as supplied; if it cannot be read,
/// the caller must fail loud (refuse to start) rather than silently self-sign,
/// which would be a security downgrade. See
/// docs/bugs/2026-06-04-cluster-cert-provided-cert-discarded-containerized.md.
pub fn requireExistingCertificates(cert_path: []const u8, key_path: []const u8) error{ ProvidedCertificateUnreadable, ProvidedKeyUnreadable }!void {
    if (!certFileReadable(cert_path)) return error.ProvidedCertificateUnreadable;
    if (!certFileReadable(key_path)) return error.ProvidedKeyUnreadable;
}

pub fn ensureCertificatesAtPath(allocator: std.mem.Allocator, cert_path: []const u8, key_path: []const u8) !void {
    // Only (re)generate when the cert is genuinely absent. The previous
    // implementation probed via `std.Io.Dir.access` over the `.failing`
    // global_single_threaded Io under a bare `catch {}` that swallowed ALL
    // errors and regenerated — environment-sensitive and a silent footgun.
    // `certFileReadable` is allocation-free and deterministic.
    if (!certFileReadable(cert_path)) {
        // Generate new certificates
        const io = std.Io.Threaded.global_single_threaded.io();
        try generateSelfSignedCert(allocator, "geode.local", cert_path, key_path);

        // Harden file permissions:
        //   server.key  → 0600 (owner-only read/write)
        //   server.crt  → 0644 (world-readable public cert)
        if (builtin.os.tag != .windows) {
            if (std.Io.Dir.cwd().openFile(io, key_path, .{})) |f| {
                defer f.close(io);
                f.setPermissions(io, std.Io.File.Permissions.fromMode(0o600)) catch {};
            } else |_| {}
            if (std.Io.Dir.cwd().openFile(io, cert_path, .{})) |f| {
                defer f.close(io);
                f.setPermissions(io, std.Io.File.Permissions.fromMode(0o644)) catch {};
            } else |_| {}
        }

        std.debug.print("Generated self-signed certificates at {s} and {s}\n", .{ cert_path, key_path });
    }
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try ensureCertificates(allocator);
    std.debug.print("TLS certificates ready\n", .{});
}
