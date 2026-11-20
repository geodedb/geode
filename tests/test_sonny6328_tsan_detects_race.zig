// SONNY-6328: the ThreadSanitizer companion steps (`test-*-tsan`) passed
// without detecting anything. With Zig 0.16 a Debug x86_64 build uses the
// self-hosted backend, which ignores `sanitize_thread`: the binary has no
// TSan instrumentation and no runtime, so a deliberate race passed too.
//
// tests/sonny6328_tsan_race_fixture.zig holds a deliberate data race, built
// the way build.zig builds every TSan companion. This test runs that binary
// and requires ThreadSanitizer to report the race (exit 66, a "data race"
// warning). It fails while the companions are uninstrumented.
//
// CANARY: REQ=REQ-SONNY-6328-TSAN-INSTRUMENTED; FEATURE="Race Detection"; ASPECT=TsanCompanionsInstrumented; STATUS=TESTED; TEST=tests/test_sonny6328_tsan_detects_race.zig; OWNER=build; UPDATED=2026-11-12
const std = @import("std");
const builtin = @import("builtin");
const options = @import("sonny6328_options");

const testing = std.testing;

test "SONNY-6328: a TSan companion build reports a deliberate data race" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const result = try std.process.run(allocator, io, .{
        .argv = &.{options.race_fixture},
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(4 << 20),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const code: ?u8 = switch (result.term) {
        .exited => |c| c,
        else => null,
    };
    const reported = std.mem.indexOf(u8, result.stderr, "WARNING: ThreadSanitizer: data race") != null;
    if (code != 66 or !reported) {
        std.debug.print(
            "SONNY-6328: the race fixture built like the TSan companions ended with {any} and {s} a ThreadSanitizer data-race report; the companion steps detect nothing.\nstderr:\n{s}\n",
            .{ result.term, if (reported) "with" else "without", result.stderr },
        );
        return error.TestUnexpectedResult;
    }
}
