// SONNY-6480 (4): QuicClientStream.readLineWithInterrupt allocated a
// `max_size` buffer on every call, before it knew whether a byte would
// arrive. A caller polling a quiet stream (the KMS client and the shell retry
// on WouldBlock) paid an 8 KiB allocation and free per retry; on
// page_allocator that is an mmap/munmap pair (571k of 640k calls in the KMS
// test were such retries). A call now allocates only for a line it returns.
//
// A real QUIC stream to a real remote-KMS server, as tests/canary_remote_kms.zig
// drives readLine; the stream's allocator is wrapped to count allocations.
//
// CANARY: REQ=REQ-SONNY-6480-READLINE-NO-ALLOC; FEATURE="QuicClient"; ASPECT=ReadLineAllocatesOnlyForALine; STATUS=TESTED; TEST=tests/test_sonny6480_readline_alloc.zig; OWNER=transport; UPDATED=2026-11-13

const std = @import("std");
const kms = @import("security/kms_remote");
const kms_tls = @import("kms_test_tls.zig");

/// Counts the allocations made through it.
const Counting = struct {
    parent: std.mem.Allocator,
    allocs: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        return self.parent.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.parent.rawResize(m, a, n, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.parent.rawRemap(m, a, n, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(m, a, ra);
    }
};

test "SONNY-6480: readLine on a quiet stream and an interrupted readLine allocate nothing" {
    // An arena over page_allocator, as tests/canary_remote_kms.zig (the
    // pinned TLS/QUIC libraries leak handshake allocations).
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var server = try kms.RemoteKmsServer.init(a, 0x6480);
    var tls = try kms_tls.TestTls.init(a);
    defer tls.deinit(a);
    try server.startWithOptions(0, tls.startOptions());
    try server.server.setAuthToken("TOKEN6480");
    var t = try std.Thread.spawn(.{}, struct {
        fn run(s: *kms.RemoteKmsServer) void {
            s.serveUntil(1, 30) catch {};
        }
    }.run, .{&server});
    defer t.join();

    var client = kms.RemoteKmsClient.init(a);
    client.ca_cert_path = tls.caPath();
    try client.connect("127.0.0.1", server.port);

    var stream = try client.quic_client.?.getStream();
    defer stream.close();
    var counting: Counting = .{ .parent = stream.allocator };
    stream.allocator = counting.allocator();
    defer stream.allocator = counting.parent;

    // The server never writes unprompted: WouldBlock, every time.
    for (0..50) |_| {
        try std.testing.expectError(error.WouldBlock, stream.readLine(8192));
    }
    const armed = struct {
        fn f() bool {
            return true;
        }
    }.f;
    for (0..50) |_| {
        try std.testing.expectError(error.Interrupted, stream.readLineWithInterrupt(8192, &armed));
    }
    try std.testing.expectEqual(@as(usize, 0), counting.allocs);
}
