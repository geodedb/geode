const std = @import("std");
const builtin = @import("builtin");

// Simple self-signed certificate generator for development/testing
// In production, use proper CA-signed certificates

pub fn generateSelfSignedCert(allocator: std.mem.Allocator, hostname: []const u8, cert_path: []const u8, key_path: []const u8) !void {
    // Extract directory from cert_path
    const cert_dir = std.fs.path.dirname(cert_path) orelse ".";

    // Create certificate directory if it doesn't exist
    std.fs.cwd().makePath(cert_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Use OpenSSL to generate self-signed ECDSA P-256 certificate
    // This is a development utility - production should use proper certificates
    // Using ECDSA P-256 for compatibility with TLS 1.3 signature schemes
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "openssl",   "req",    "-x509",    "-newkey",
            "ec",        "-pkeyopt", "ec_paramgen_curve:prime256v1",
            "-keyout",   key_path, "-out",     cert_path,
            "-days",     "365",    "-nodes",   "-subj",
            try std.fmt.allocPrint(allocator, "/CN={s}", .{hostname}),
            "-addext",
            try std.fmt.allocPrint(allocator, "subjectAltName=DNS:{s},DNS:localhost,IP:127.0.0.1,IP:::1", .{hostname}),
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
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
    // Check if certificates already exist
    std.fs.cwd().access(cert_path, .{}) catch {
        // Generate new certificates
        try generateSelfSignedCert(allocator, "geode.local", cert_path, key_path);
        std.debug.print("Generated self-signed certificates at {s} and {s}\n", .{ cert_path, key_path });
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try ensureCertificates(allocator);
    std.debug.print("TLS certificates ready\n", .{});
}
