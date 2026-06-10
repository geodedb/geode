const std = @import("std");
const txn = @import("txn");
const FuzzCtx = struct {};

// Zig 0.16: std.testing.fuzz hands the test a *Smith generator instead of a
// raw byte slice.  Draw a fuzzer-controlled byte slice from the Smith and
// feed it to the original byte-driven harness.
fn fuzz_txn(context: FuzzCtx, smith: *std.testing.Smith) anyerror!void {
    var buf: [1024]u8 = undefined;
    const len = smith.slice(&buf);
    try fuzz_txn_bytes(context, buf[0..len]);
}

fn fuzz_txn_bytes(context: FuzzCtx, data: []const u8) anyerror!void {
    _ = context;
    var mgr: txn.Manager = undefined;
    mgr.init(std.testing.allocator);
    defer mgr.deinit();

    var cur: ?txn.Txn = null;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        const op = data[i] % 4;
        switch (op) {
            0 => {
                cur = mgr.begin();
            },
            1 => if (cur) |*t| {
                _ = mgr.commit(t) catch {};
                cur = null;
            },
            2 => if (cur) |*t| {
                mgr.rollback(t);
                cur = null;
            },
            3 => if (cur) |*t| {
                _ = mgr.acquireWrite("k", t, std.testing.allocator) catch {};
                mgr.recordWrite("k", t);
            },
            else => {},
        }
    }
    if (cur) |*t| {
        _ = mgr.commit(t) catch {
            mgr.rollback(t);
        };
        if (t.state == .Committed) {}
    }
}

test "fuzz txn sequence" {
    try std.testing.fuzz(FuzzCtx{}, fuzz_txn, .{});
    std.debug.print("fuzzing: completed\n", .{});
}
