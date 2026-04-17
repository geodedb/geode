const std = @import("std");
const builtin = @import("builtin");

// Simple self-signed certificate generator for development/testing
// In production, use proper CA-signed certificates

pub fn generateSelfSignedCert(allocator: std.mem.Allocator, hostname: []const u8, cert_path: []const u8, key_path: []const u8) !void {
    _ = allocator;
    // Extract directory from cert_path
    const cert_dir = std.fs.path.dirname(cert_path) orelse ".";

    // Zig 0.16 note: the stdlib's `global_single_threaded` Threaded instance
    // ships with `.allocator = .failing`, so any `std.process.run` through it
    // OOMs immediately inside `spawnPosix`'s internal arena. Build a local
    // Threaded backed by `page_allocator` so the fork/exec path can allocate
    // argv/env buffers.
    const spawn_gpa = std.heap.page_allocator;
    var local_threaded = std.Io.Threaded.init(spawn_gpa, .{});
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

pub fn ensureCertificatesAtPath(allocator: std.mem.Allocator, cert_path: []const u8, key_path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    // Check if certificates already exist
    std.Io.Dir.cwd().access(io, cert_path, .{}) catch {
        // Generate new certificates
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
    };
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try ensureCertificates(allocator);
    std.debug.print("TLS certificates ready\n", .{});
}
