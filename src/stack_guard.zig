//! How much of the calling thread's stack is left: the guard the GQL parser
//! (SONNY-3133) and the expression evaluator (SONNY-3181) take before they
//! recurse one level deeper, so input that nests past what the thread can
//! hold gets an error instead of a stack overflow.
//!
//! The bounds are read once per thread with `pthread_getattr_np` (glibc and
//! musl). Without libc, off Linux, or on a stack that is not the thread's
//! own (a fiber's), nothing is known and every check passes.
//
// CANARY: REQ=REQ-SONNY-3181-EVAL-STACK-GUARD; FEATURE="ExpressionEvaluator"; ASPECT=StackGuard; STATUS=TESTED; TEST=tests/test_sonny3181_expr_chain_cap.zig; OWNER=eval; UPDATED=2026-09-27

const std = @import("std");
const builtin = @import("builtin");

/// The calling thread's stack bounds, looked up once per thread.
const ThreadStack = struct {
    low: usize = 0,
    high: usize = 0,
    known: bool = false,
    looked: bool = false,
};

threadlocal var t_thread_stack: ThreadStack = .{};

/// glibc and musl both have these; std.c does not declare them.
const pthread_stack = struct {
    extern "c" fn pthread_getattr_np(thread: std.c.pthread_t, attr: *std.c.pthread_attr_t) c_int;
    extern "c" fn pthread_attr_getstack(attr: *const std.c.pthread_attr_t, stackaddr: *?*anyopaque, stacksize: *usize) c_int;
};

fn threadStack() ThreadStack {
    if (t_thread_stack.looked) return t_thread_stack;
    t_thread_stack.looked = true;
    if (comptime builtin.link_libc and builtin.os.tag == .linux) {
        var attr: std.c.pthread_attr_t = undefined;
        if (pthread_stack.pthread_getattr_np(std.c.pthread_self(), &attr) != 0) return t_thread_stack;
        defer _ = std.c.pthread_attr_destroy(&attr);
        var addr: ?*anyopaque = null;
        var size: usize = 0;
        if (pthread_stack.pthread_attr_getstack(&attr, &addr, &size) != 0) return t_thread_stack;
        const low = @intFromPtr(addr orelse return t_thread_stack);
        t_thread_stack = .{ .low = low, .high = low + size, .known = true, .looked = true };
    }
    return t_thread_stack;
}

/// Is more than `reserve` bytes of the calling thread's stack left below the
/// caller's frame? True when the bounds are unknown, or when the frame is not
/// on the thread's stack.
pub inline fn hasRoom(reserve: usize) bool {
    return hasRoomBelow(@frameAddress(), reserve);
}

pub fn hasRoomBelow(frame: usize, reserve: usize) bool {
    const st = threadStack();
    if (!st.known) return true;
    if (frame < st.low or frame >= st.high) return true;
    return frame - st.low > reserve;
}

/// The bytes left below `frame` on the calling thread's stack, or null when
/// the bounds are unknown or `frame` is not on it. For tests and diagnostics.
pub fn remaining(frame: usize) ?usize {
    const st = threadStack();
    if (!st.known) return null;
    if (frame < st.low or frame >= st.high) return null;
    return frame - st.low;
}

test "hasRoom: true on the test thread with a small reserve, false with one past the stack" {
    try std.testing.expect(hasRoom(1024));
    if (remaining(@frameAddress())) |left| {
        try std.testing.expect(!hasRoom(left + 1024 * 1024));
    }
}
