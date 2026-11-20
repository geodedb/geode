//! Process-resource support shared by the SONNY-738 write regressions.
//! Keep memory accounting and child limits identical in the isolated tests
//! and the broader write suite.

const std = @import("std");
const geode = @import("geode");
const h = @import("sonny738_write_harness.zig");
const execution = h.execution;
const stmt_alloc = std.heap.page_allocator;

pub fn runProgram(s: *h.Session, allocator: std.mem.Allocator, query: []const u8) !execution.ExecutionResult {
    var parsed = try geode.parseGql(query, s.arena.allocator());
    defer parsed.deinit();
    const prev = execution.pushActiveContext(&s.ctx);
    defer execution.popActiveContext(prev);
    return execution.executeProgramWithContext(allocator, &parsed.program, s.ctx);
}

pub fn openSession(mode: h.Mode) !h.Session {
    var s = try h.Session.init(mode);
    errdefer s.deinit();
    _ = geode.txn_undo_log.getGlobalUndoLog(stmt_alloc);
    try s.seed();
    return s;
}

pub fn monoMillis() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// The data segment the process holds now, in bytes (VmData).
fn dataSegmentBytes() usize {
    var buf: [8192]u8 = undefined;
    const fd = std.c.open("/proc/self/status", .{});
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    const got = std.c.read(fd, &buf, buf.len);
    if (got <= 0) return 0;
    const n: usize = @intCast(got);
    var lines = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "VmData:")) continue;
        var parts = std.mem.tokenizeAny(u8, line[7..], " \tkB");
        const kb = std.fmt.parseInt(usize, parts.next() orelse return 0, 10) catch return 0;
        return kb * 1024;
    }
    return 0;
}

/// Linux can reset VmHWM. Darwin's kernel peak is lifetime-wide, so retaining
/// it is conservative: an earlier peak can fail the bound, never hide growth.
pub fn resetPeakRss() void {
    if (comptime @import("builtin").os.tag.isDarwin()) return;
    const fd = std.c.open("/proc/self/clear_refs", .{ .ACCMODE = .WRONLY });
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    _ = std.c.write(fd, "5", 1);
}

pub fn statusBytes(field: []const u8) usize {
    if (comptime @import("builtin").os.tag.isDarwin()) {
        const memory = darwinMemory() catch @panic("could not measure Darwin process memory");
        if (std.mem.eql(u8, field, "VmRSS")) return memory.resident;
        if (std.mem.eql(u8, field, "VmHWM")) return memory.peak;
        @panic("unsupported Darwin process memory field");
    }
    var buf: [8192]u8 = undefined;
    const fd = std.c.open("/proc/self/status", .{});
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    const got = std.c.read(fd, &buf, buf.len);
    if (got <= 0) return 0;
    const n: usize = @intCast(got);
    var lines = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, field)) continue;
        var parts = std.mem.tokenizeAny(u8, line[field.len..], " \t:kB");
        const kb = std.fmt.parseInt(usize, parts.next() orelse return 0, 10) catch return 0;
        return kb * 1024;
    }
    return 0;
}

const ResidentMemory = struct { resident: usize, peak: usize };

fn darwinMemory() !ResidentMemory {
    var info: std.c.task_vm_info_data_t = std.mem.zeroes(std.c.task_vm_info_data_t);
    var count: std.c.mach_msg_type_number_t = std.c.TASK.VM.INFO_COUNT;
    const result = std.c.task_info(std.c.mach_task_self(), std.c.TASK.VM.INFO, @ptrCast(&info), &count);
    if (result != 0) {
        std.debug.print("Darwin memory measurement: task_info returned {d}\n", .{result});
        return error.MemoryMeasurementFailed;
    }
    const required = (@offsetOf(std.c.task_vm_info_data_t, "resident_size_peak") + @sizeOf(u64)) / @sizeOf(std.c.natural_t);
    if (count < required or info.resident_size == 0) {
        std.debug.print("Darwin memory measurement: count={d} required={d} resident={d} peak={d}\n", .{ count, required, info.resident_size, info.resident_size_peak });
        return error.MemoryMeasurementFailed;
    }
    // SONNY-6830: the kernel's recorded peak can lag the live resident size
    // (resident 33865728, peak 33849344 in CI); the true peak is never below
    // the current resident size, so that is the peak until the record catches up.
    return .{ .resident = @intCast(info.resident_size), .peak = @intCast(@max(info.resident_size_peak, info.resident_size)) };
}

/// Keep runaway regressions inside the forked child's memory allowance.
/// Linux bounds anonymous allocations with RLIMIT_DATA. Darwin does not have
/// Linux's VmData accounting: monitor the real kernel resident peak instead,
/// including a final check so an allocation freed between samples is caught.
pub const ChildMemoryGuard = struct {
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    limit: usize = 0,

    pub fn start(self: *@This(), allowance: usize) !void {
        if (comptime @import("builtin").os.tag == .linux) {
            const have = dataSegmentBytes();
            if (have == 0) return error.MemoryMeasurementFailed;
            const cap = try std.math.add(usize, have, allowance);
            try std.posix.setrlimit(.DATA, .{ .cur = cap, .max = cap });
        } else if (comptime @import("builtin").os.tag.isDarwin()) {
            self.limit = try std.math.add(usize, (try darwinMemory()).resident, allowance);
            self.thread = try std.Thread.spawn(.{}, watch, .{self});
        } else return error.UnsupportedMemoryGuardPlatform;
    }

    fn check(self: *@This()) void {
        const memory = darwinMemory() catch std.c._exit(8);
        if (memory.peak > self.limit) {
            std.debug.print("child resident peak {d} exceeds memory limit {d}\n", .{ memory.peak, self.limit });
            std.c._exit(9);
        }
    }

    fn watch(self: *@This()) void {
        while (!self.done.load(.acquire)) {
            self.check();
            std.Io.Threaded.global_single_threaded.io().sleep(.fromMilliseconds(1), .awake) catch {};
        }
    }

    pub fn stop(self: *@This()) void {
        if (comptime @import("builtin").os.tag.isDarwin()) {
            self.done.store(true, .release);
            self.thread.?.join();
            self.check();
        }
    }
};
