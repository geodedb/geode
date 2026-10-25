//! How much of the calling thread's stack is left: the guard the GQL parser
//! (SONNY-3133) and the expression evaluator (SONNY-3181) take before they
//! recurse one level deeper, so input that nests past what the thread can
//! hold gets an error instead of a stack overflow.
//!
//! The bounds are read once per thread using the native pthread APIs on
//! Linux and Darwin. Without libc, on other platforms, or on a stack that
//! is not the thread's own (a fiber's), nothing is known and checks pass.
//
// CANARY: REQ=REQ-SONNY-3181-EVAL-STACK-GUARD; FEATURE="ExpressionEvaluator"; ASPECT=StackGuard; STATUS=TESTED; TEST=tests/test_sonny3181_expr_chain_cap.zig; OWNER=eval; UPDATED=2026-09-27

const std = @import("std");
const builtin = @import("builtin");

/// SONNY-3191 (N-5): the stack a server thread that runs a request gets: the
/// QUIC workers (GAP-0333) and the first-stream owners. The QUIC connection
/// admission threads, which run a connection's first stream themselves when
/// the stream pool refuses it or no stream reactor is installed, had 1 MiB,
/// where a plain MATCH got "nesting too deep" from the parser's guard, and
/// overflowed in a Debug build; they now size their own (16 MiB in Debug,
/// 8 MiB in a release build: SONNY-3253, `default_quic_admission_stack_mb` in
/// server/main.zig). Reserved, not committed: a thread touches only the pages
/// it uses.
pub const request_thread_stack_bytes: usize = 16 * 1024 * 1024;

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
    extern "c" fn pthread_get_stackaddr_np(thread: std.c.pthread_t) ?*anyopaque;
    extern "c" fn pthread_get_stacksize_np(thread: std.c.pthread_t) usize;
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
    } else if (comptime builtin.link_libc and builtin.os.tag.isDarwin()) {
        // Darwin reports the high address of the stack, unlike Linux's
        // pthread_attr_getstack. Its size includes the caller-owned stack
        // supplied by pthread_attr_setstack, which the nesting probes use.
        const thread = std.c.pthread_self();
        const high = @intFromPtr(pthread_stack.pthread_get_stackaddr_np(thread) orelse return t_thread_stack);
        const size = pthread_stack.pthread_get_stacksize_np(thread);
        if (size == 0 or size > high) return t_thread_stack;
        t_thread_stack = .{ .low = high - size, .high = high, .known = true, .looked = true };
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
    if (comptime builtin.link_libc and (builtin.os.tag == .linux or builtin.os.tag.isDarwin())) {
        try std.testing.expect(remaining(@frameAddress()) != null);
    }
    if (remaining(@frameAddress())) |left| {
        try std.testing.expect(!hasRoom(left + 1024 * 1024));
    }
}

test "stack bounds are known on both request thread stack sizes" {
    if (comptime builtin.link_libc and (builtin.os.tag == .linux or builtin.os.tag.isDarwin())) {
        const Probe = struct {
            left: ?usize = null,
            refuses_excess: bool = false,

            fn run(self: *@This()) void {
                self.left = remaining(@frameAddress());
                if (self.left) |left| self.refuses_excess = !hasRoomBelow(@frameAddress(), left + 1);
            }
        };
        for ([_]usize{ 8 << 20, 16 << 20 }) |size| {
            var probe: Probe = .{};
            const thread = try std.Thread.spawn(.{ .stack_size = size }, Probe.run, .{&probe});
            thread.join();
            try std.testing.expect(probe.left != null);
            try std.testing.expect(probe.left.? > 1 << 20);
            std.debug.print("stack request={d} remaining={d}\n", .{ size, probe.left.? });
            try std.testing.expect(probe.left.? <= size);
            try std.testing.expect(probe.refuses_excess);
        }
    }
}
