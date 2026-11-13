// SONNY-6489 item 5: a QUIC listener that cannot bind frees its TLS
// configuration once.
//
// `geode serve --listen ::1:0` (an IPv6 address without brackets) reached
// `QuicTransport.listen` with the address "::1", which the vendor endpoint
// refuses (InvalidAddress). `listen` had already recorded its heap-allocated
// config in `self.quic_config`; its errdefer freed the config and the
// certificate and key DER it holds, and `QuicTransport.deinit` (the server's
// teardown) freed all three again: three DebugAllocator double frees.
// (Accepting the unbracketed form is SONNY-6487, the address grammar.)
//
// Drives the real transport under `std.testing.allocator`, which reports a
// double free and a leak.
//
// CANARY: REQ=REQ-SONNY-6489-LISTEN-ERROR-FREE; FEATURE="QuicTransport"; ASPECT=ListenErrorOwnership; STATUS=TESTED; TEST=tests/test_sonny6489_listen_error_free.zig; OWNER=transport; UPDATED=2026-11-13

const std = @import("std");
const quic = @import("transport/quic");

fn tmpDirPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var n = cwd_len;
    while (n > 0 and cwd_buf[n - 1] == 0) : (n -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..n], &tmp.sub_path });
}

test "SONNY-6489: a QUIC listener that cannot bind its address frees its TLS configuration once" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpDirPath(a, &tmp);
    defer a.free(dir);
    const cert = try std.fmt.allocPrint(a, "{s}/server.crt", .{dir});
    defer a.free(cert);
    const key = try std.fmt.allocPrint(a, "{s}/server.key", .{dir});
    defer a.free(key);

    var transport = try quic.QuicTransport.init(a, .{
        .address = "::1",
        .port = 0,
        .cert_path = cert,
        .key_path = key,
        .cert_auto_generate = .always,
    });
    defer transport.deinit();
    // The certificate is made and loaded; binding "::1:0" fails.
    if (transport.listen()) |_| {
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.InvalidAddress, err);
    try std.testing.expect(transport.endpoint == null);
}
