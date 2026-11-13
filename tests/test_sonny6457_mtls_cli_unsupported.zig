// SONNY-6457 item 5: `geode mtls` does not claim certificate-to-user
// mappings the server never uses.
//
// `geode mtls map create|delete` and `geode mtls config` wrote
// geode_mtls_state.db in the CLI state directory and printed "Created mTLS
// mapping" / "mTLS configuration updated"; `map list` and `status` read it
// back. Nothing on the server reads that file, and the server's
// certificate-to-user store (src/security/mtls_provider.zig) is never
// populated, so a mapping changed nothing: the user is always the one that
// authenticates in HELLO. Mapping is story SONNY-6458. Until it lands every
// `geode mtls` subcommand is refused as unsupported (like `geode fle
// rotate-key`, SONNY-6386): a non-zero exit, a message naming the story and
// what the server does do, and no state file.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const geode_binary = geode_test_bin.geode_exe;

const Run = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }

    fn output(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.stdout, needle) != null or
            std.mem.indexOf(u8, self.stderr, needle) != null;
    }

    fn exitedWith(self: Run, code: u8) bool {
        return switch (self.term) {
            .exited => |c| c == code,
            else => false,
        };
    }

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6457 {s}: term={any}\nstdout:\n{s}\nstderr:\n{s}\n", .{ what, self.term, self.stdout, self.stderr });
    }
};

fn runGeode(argv: []const []const u8, state_dir: []const u8) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("HOME", state_dir);
    try env.put("GEODE_STATE_DIR", state_dir);
    try env.put("GEODE_LSP_PORT", "0");
    const r = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .cwd = .{ .path = state_dir },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } },
    });
    return .{ .term = r.term, .stdout = r.stdout, .stderr = r.stderr };
}

test "SONNY-6457 (5) every geode mtls subcommand is refused as unsupported and writes no mapping file" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var root = try test_scratch.ScratchDir.create("sonny6457-mtls-cli");
    defer root.remove();
    const cases = [_][]const []const u8{
        &.{ geode_binary, "mtls", "map", "create", "--method", "fingerprint", "--pattern", "SHA256:abc123", "--user", "alice", "--roles", "admin" },
        &.{ geode_binary, "mtls", "map", "list" },
        &.{ geode_binary, "mtls", "map", "delete", "--pattern", "SHA256:abc123" },
        &.{ geode_binary, "mtls", "config", "--strict-mode", "true" },
        &.{ geode_binary, "mtls", "status" },
    };
    var failures: usize = 0;
    for (cases) |argv| {
        const r = try runGeode(argv, root.path());
        defer r.deinit();
        const ok = !r.exitedWith(0) and r.output("not supported") and r.output("SONNY-6458") and
            r.output("GEODE_MTLS_REQUIRED") and
            !r.output("Created mTLS mapping") and !r.output("Deleted mTLS mapping") and
            !r.output("configuration updated") and !r.output("No mTLS mappings configured") and
            !r.output("mTLS Configuration Status");
        if (!ok) {
            failures += 1;
            r.dump(argv[2]);
        }
    }
    var dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), root.path(), .{});
    defer dir.close(std.Io.Threaded.global_single_threaded.io());
    if (dir.access(std.Io.Threaded.global_single_threaded.io(), "geode_mtls_state.db", .{})) |_| {
        failures += 1;
        std.debug.print("SONNY-6457: geode mtls wrote geode_mtls_state.db\n", .{});
    } else |_| {}
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6457 (5) geode mtls --help says mappings are not supported and how mTLS is enabled" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var root = try test_scratch.ScratchDir.create("sonny6457-mtls-help");
    defer root.remove();
    const r = try runGeode(&.{ geode_binary, "mtls", "--help" }, root.path());
    defer r.deinit();
    const ok = r.exitedWith(0) and r.output("not supported") and r.output("SONNY-6458") and
        r.output("GEODE_MTLS_REQUIRED") and r.output("GEODE_MTLS_CLIENT_CA");
    if (!ok) r.dump("mtls --help");
    try testing.expect(ok);
}
