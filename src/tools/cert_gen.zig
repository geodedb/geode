const std = @import("std");
const builtin = @import("builtin");

// Simple self-signed certificate generator for development/testing
// In production, use proper CA-signed certificates

pub fn generateSelfSignedCert(allocator: std.mem.Allocator, hostname: []const u8, cert_path: []const u8, key_path: []const u8) !void {
    // Create certs directory if it doesn't exist
    std.fs.cwd().makeDir("certs") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Use OpenSSL to generate self-signed certificate
    // This is a development utility - production should use proper certificates
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "openssl",                                                                                                  "req",    "-x509", "-newkey",                                                 "rsa:4096",
            "-keyout",                                                                                                  key_path, "-out",  cert_path,                                                 "-days",
            "365",                                                                                                      "-nodes", "-subj", try std.fmt.allocPrint(allocator, "/CN={s}", .{hostname}), "-addext",
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
    const cert_path = "certs/server.crt";
    const key_path = "certs/server.key";

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
