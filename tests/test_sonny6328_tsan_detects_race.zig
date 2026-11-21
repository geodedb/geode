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
// SONNY-6916: on a host with high ASLR entropy the TSan runtime re-executes
// itself with ASLR disabled, and Docker's default seccomp profile refuses
// that, so TSan cannot start at all (exit 66, "unable to disable ASLR").
// That runner cannot host ThreadSanitizer, so the check skips and says why;
// every other outcome without a data-race report still fails.
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
    switch (classify(code, result.stderr)) {
        .detected => return,
        .tsan_cannot_start => {
            std.debug.print("SONNY-6916: skipped: ThreadSanitizer could not start on this runner (it could not disable ASLR, as under Docker's default seccomp profile); nothing about the companions was checked.\n", .{});
            return error.SkipZigTest;
        },
        .undetected => {},
    }
    const reported = std.mem.indexOf(u8, result.stderr, data_race_report) != null;
    std.debug.print(
        "SONNY-6328: the race fixture built like the TSan companions ended with {any} and {s} a ThreadSanitizer data-race report; the companion steps detect nothing.\nstderr:\n{s}\n",
        .{ result.term, if (reported) "with" else "without", result.stderr },
    );
    return error.TestUnexpectedResult;
}

const data_race_report = "WARNING: ThreadSanitizer: data race";
const aslr_fatal = "FATAL: ThreadSanitizer: encountered an incompatible memory layout but was unable to disable ASLR";

const Outcome = enum { detected, tsan_cannot_start, undetected };

/// SONNY-6916: what one run of the race fixture showed.
fn classify(code: ?u8, stderr: []const u8) Outcome {
    if (code == 66 and std.mem.indexOf(u8, stderr, data_race_report) != null) return .detected;
    if (code == 66 and std.mem.indexOf(u8, stderr, aslr_fatal) != null) return .tsan_cannot_start;
    return .undetected;
}

test "SONNY-6916: classify separates a detected race, a TSan that cannot start, and a missed race" {
    // The stderr TSan printed on the shadowfax runner (job 18249327096).
    const ci_stderr =
        \\FATAL: ThreadSanitizer: encountered an incompatible memory layout but was unable to disable ASLR (perhaps sandboxing is enabled?).
        \\FATAL: Please rerun with lower ASLR entropy, ASLR disabled, and/or sandboxing disabled.
        \\
    ;
    try testing.expectEqual(Outcome.tsan_cannot_start, classify(66, ci_stderr));
    try testing.expectEqual(Outcome.detected, classify(66, "==================\nWARNING: ThreadSanitizer: data race (pid=1)\n"));
    try testing.expectEqual(Outcome.undetected, classify(0, ""));
    try testing.expectEqual(Outcome.undetected, classify(0, ci_stderr));
    try testing.expectEqual(Outcome.undetected, classify(66, "some other failure\n"));
    try testing.expectEqual(Outcome.undetected, classify(null, ci_stderr));
}
