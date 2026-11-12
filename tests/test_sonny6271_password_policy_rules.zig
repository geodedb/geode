// SONNY-6271: `geode user reset-password geode --new-password resetpass12345`
// answered "password does not meet policy requirements (min 8 chars, letters
// and numbers)". `resetpass12345` has 14 characters, letters and numbers, so
// the message contradicted itself: the check it reported was the unified
// passphrase policy (docs/USER_AUTH.md section 2, `PasswordPolicy.validate`:
// at least 20 characters, upper and lower case, at least 3 space-separated
// words), which the offline CLI adopted in d8709a2a (2026-07-31, bug 731)
// without updating its five error messages. The CLI now names the rule that
// failed and never echoes the password.
//
// Also pinned: `--generate-password` on `reset-password` / `password` was
// checked against the passphrase policy, which a generated 32-character hex
// secret can never satisfy (no uppercase, one word), so the documented
// escape hatch refused the password it had just generated. `user create
// --generate-password` never applied the policy to its generated secret; the
// other two subcommands now match it.
//
// The table pins the documented policy, rule by rule. The subprocess cases
// drive the geode this build emitted (SONNY-2697) against an empty data dir.
const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const PasswordPolicy = @import("geode_auth").PasswordPolicy;
const scratch = @import("test_scratch.zig");

const too_short = "Password too short (minimum 20 characters)";
const too_long = "Password too long (maximum 256 characters)";
const no_upper = "Password must contain at least one uppercase letter";
const no_lower = "Password must contain at least one lowercase letter";
const too_few_words = "Password must be a passphrase with at least 3 words";

const compliant = "Reset Breadcrumb Test Passphrase";

fn getenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

/// The table assumes the documented defaults (20 characters, 3 words).
fn policyOverridden() bool {
    return getenv("GEODE_PASSWORD_MIN_LENGTH") != null or getenv("GEODE_PASSWORD_MIN_WORDS") != null;
}

const Case = struct { password: []const u8, rule: ?[]const u8 };

const cases = [_]Case{
    // The password test-first-boot-admin-breadcrumb used: short, then also
    // lower case only and one word. The first failing rule is reported.
    .{ .password = "resetpass12345", .rule = too_short },
    .{ .password = "", .rule = too_short },
    .{ .password = "abc12345", .rule = too_short },
    .{ .password = "Two Words", .rule = too_short },
    .{ .password = "Nineteen chars long", .rule = too_short },
    .{ .password = ("Abcd " ** 52), .rule = too_long },
    .{ .password = "resetpass12345 with more words", .rule = no_upper },
    .{ .password = "correct horse battery staple", .rule = no_upper },
    .{ .password = "CORRECT HORSE BATTERY STAPLE", .rule = no_lower },
    .{ .password = "Supercalifragilistic", .rule = too_few_words },
    .{ .password = "Supercalifragilistic Expialidocious", .rule = too_few_words },
    // The format `--generate-password` produces (32 lower-case hex digits).
    .{ .password = "0123456789abcdef0123456789abcdef", .rule = no_upper },
    // Accepted: digits and symbols are allowed, not required.
    .{ .password = "Correct horse battery staple", .rule = null },
    .{ .password = "Correct Horse Battery Staple 42", .rule = null },
    .{ .password = "Twenty Chars Exactly", .rule = null },
    .{ .password = compliant, .rule = null },
};

test "SONNY-6271: the documented password policy, rule by rule" {
    if (policyOverridden()) return error.SkipZigTest;
    const policy = PasswordPolicy.geodeSecure();
    var failed: usize = 0;
    for (cases) |c| {
        const got = policy.validate(c.password);
        const ok = if (c.rule) |want| (got != null and std.mem.eql(u8, got.?, want)) else got == null;
        if (!ok) {
            failed += 1;
            std.debug.print("policy case \"{s}\": want {?s}, got {?s}\n", .{ c.password, c.rule, got });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

const CliRun = struct {
    output: []const u8,
    exit_code: ?u8,
};

/// Runs `geode <args...> --data-dir <empty scratch dir>` with a clean env
/// (no GEODE_* variables) and returns stdout+stderr and the exit code.
fn runCli(aa: std.mem.Allocator, io: std.Io, args: []const []const u8) !CliRun {
    var dir = try scratch.ScratchDir.create("sonny6271");
    defer dir.remove();

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(aa, geode_test_bin.geode_exe);
    try argv.appendSlice(aa, args);
    try argv.appendSlice(aa, &.{ "--data-dir", dir.path() });

    var env = std.process.Environ.Map.init(aa);
    if (getenv("PATH")) |p| try env.put("PATH", p);
    if (getenv("HOME")) |p| try env.put("HOME", p);
    if (getenv("LD_LIBRARY_PATH")) |p| try env.put("LD_LIBRARY_PATH", p);

    const result = try std.process.run(aa, io, .{
        .argv = argv.items,
        .environ_map = &env,
        .stdout_limit = .limited(1 << 16),
        .stderr_limit = .limited(1 << 16),
    });
    const output = try std.mem.concat(aa, u8, &.{ result.stdout, result.stderr });
    const code: ?u8 = switch (result.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .output = output, .exit_code = code };
}

fn expectContains(output: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, output, needle) == null) {
        std.debug.print("expected output to contain \"{s}\"; output:\n{s}\n", .{ needle, output });
        return error.TestExpectedSubstring;
    }
}

fn expectAbsent(output: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, output, needle) != null) {
        std.debug.print("output must not contain \"{s}\"; output:\n{s}\n", .{ needle, output });
        return error.TestUnexpectedSubstring;
    }
}

fn expectFailedExit(run: CliRun) !void {
    if (run.exit_code) |c| if (c == 0) {
        std.debug.print("expected a nonzero exit; output:\n{s}\n", .{run.output});
        return error.TestExpectedFailureExit;
    };
}

test "SONNY-6271: reset-password names the policy rule a weak password breaks, without echoing it" {
    if (builtin.os.tag != .linux or policyOverridden()) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();

    const run = try runCli(arena.allocator(), threaded.io(), &.{ "user", "reset-password", "geode", "--new-password", "resetpass12345" });
    try expectContains(run.output, "password does not meet policy requirements");
    try expectContains(run.output, too_short);
    try expectAbsent(run.output, "min 8 chars");
    try expectAbsent(run.output, "resetpass12345");
    try expectFailedExit(run);
}

test "SONNY-6271: user create names the policy rule a weak password breaks" {
    if (builtin.os.tag != .linux or policyOverridden()) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();

    const run = try runCli(arena.allocator(), threaded.io(), &.{ "user", "create", "alice", "alice@example.com", "--password", "correct horse battery staple" });
    try expectContains(run.output, "password does not meet policy requirements");
    try expectContains(run.output, no_upper);
    try expectAbsent(run.output, "min 8 chars");
    try expectAbsent(run.output, "correct horse battery staple");
    try expectFailedExit(run);
}

test "SONNY-6271: a compliant password passes the policy and reset-password then reports the missing user" {
    if (builtin.os.tag != .linux or policyOverridden()) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();

    const run = try runCli(arena.allocator(), threaded.io(), &.{ "user", "reset-password", "geode", "--new-password", compliant });
    try expectAbsent(run.output, "policy requirements");
    try expectContains(run.output, "password NOT reset");
    try expectFailedExit(run);
}

test "SONNY-6271: reset-password --generate-password is not refused by the passphrase policy" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();

    // The data dir is empty, so the user lookup fails; what matters is that
    // the command gets that far instead of refusing its own generated secret.
    const run = try runCli(arena.allocator(), threaded.io(), &.{ "user", "reset-password", "geode", "--generate-password" });
    try expectAbsent(run.output, "policy requirements");
    try expectContains(run.output, "password NOT reset");
    try expectFailedExit(run);
}
