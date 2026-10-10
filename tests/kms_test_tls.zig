//! Per-server TLS files for the remote-KMS tests (SONNY-2394 review).
//!
//! The aggregate `test` step runs the remote-KMS test binaries concurrently.
//! With the default paths every server self-signed into the SAME gitignored
//! `./certs/server.{crt,key}` pair, so one binary could load a certificate that
//! another was still writing. Each server now gets a private pair in its own
//! tmp dir, self-signed on first listen.

const std = @import("std");
const kms = @import("security/kms_remote"); // module provided by build.zig

pub const TestTls = struct {
    tmp: std.testing.TmpDir,
    cert: []u8,
    key: []u8,

    pub fn init(allocator: std.mem.Allocator) !TestTls {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = try tmpDirPath(allocator, &tmp);
        defer allocator.free(dir);
        const cert = try std.fmt.allocPrint(allocator, "{s}/server.crt", .{dir});
        errdefer allocator.free(cert);
        const key = try std.fmt.allocPrint(allocator, "{s}/server.key", .{dir});
        return .{ .tmp = tmp, .cert = cert, .key = key };
    }

    /// Call only after the server using these files has been deinit'ed.
    pub fn deinit(self: *TestTls, allocator: std.mem.Allocator) void {
        allocator.free(self.cert);
        allocator.free(self.key);
        self.tmp.cleanup();
    }

    /// Start options for a server on this pair. A test fixture, not a
    /// production listener: self-sign the pair whatever the build posture.
    pub fn startOptions(self: *const TestTls) kms.RemoteKmsServer.StartOptions {
        return .{ .cert_path = self.cert, .key_path = self.key, .cert_auto_generate = .always };
    }
};

// Zig 0.16 has no std.Io.Dir realpath: rebuild the absolute tmp-dir path.
fn tmpDirPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var n = cwd_len;
    while (n > 0 and cwd_buf[n - 1] == 0) : (n -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..n], &tmp.sub_path });
}
