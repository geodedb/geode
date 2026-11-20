// SONNY-6430 (6, 8): two offline CLI commands that reported success on the
// wrong thing.
//   (6) `geode storage verify` used `graph_store.getGlobalStore`, which with
//       no GEODE_DATA_DIR is an empty in-memory store, and ignored any
//       --data-dir: it "verified" nothing and printed PASS (the verbose form
//       also exited 0 when the check failed).
//   (8) `geode migrate create` with no HMAC key wrote an unsigned migration
//       and exited 0, although its help says the key is required and the
//       file is signed unless --no-sign is given (SEC-MIG-03: "Unauthenticated
//       calls exit with an error message").
//
// The contract:
//   (6) verify checks the data directory the server would open (--data-dir,
//       else GEODE_DATA_DIR, else the per-user default) and names it; a
//       directory it cannot open, or a failed check, exits non-zero.
//   (8) without a key, migrate create refuses and writes nothing; --no-sign
//       is the explicit way to create an unsigned file.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const logging = @import("logging");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const graph_store = geode.graph_store;
const geode_binary = geode_test_bin.geode_exe;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn pathExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(fsIo(), path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn entryCount(dir_path: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), dir_path, .{ .iterate = true });
    defer dir.close(fsIo());
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(fsIo())) |_| n += 1;
    return n;
}

const Env = struct { name: []const u8, value: []const u8 };

const Run = struct {
    code: ?u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }

    fn says(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.stdout, needle) != null or std.mem.indexOf(u8, self.stderr, needle) != null;
    }

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6430 {s}: exit={?d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ what, self.code, self.stdout, self.stderr });
    }
};

/// Runs the geode CLI with only PATH/LD_LIBRARY_PATH from the test's
/// environment, HOME set to `home`, and `extra`.
fn runGeode(argv: []const []const u8, cwd: []const u8, home: []const u8, extra: []const Env) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("HOME", home);
    for (extra) |e| try env.put(e.name, e.value);
    const result = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(180), .clock = .awake } },
    });
    const code: ?u8 = switch (result.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

/// A store with `n` nodes at `data_dir`, written through the real engine.
fn seedStore(allocator: std.mem.Allocator, data_dir: []const u8, n: usize) !void {
    logging.init(.{ .level = .fatal });
    logging.setLevel(.fatal);
    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    const labels = [_][]const u8{"Sonny6430"};
    for (0..n) |_| _ = try store.createNode(&labels);
    try store.saveToFile();
}

fn nodeCount(out: []const u8) ?u64 {
    const tag = "\"node_count\":";
    const at = std.mem.indexOf(u8, out, tag) orelse return null;
    const rest = out[at + tag.len ..];
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
}

test "SONNY-6430 (6) geode storage verify checks the data directory the server would open (--data-dir, GEODE_DATA_DIR, the per-user default), and exits 1 when it cannot" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6430-storage-verify");
    defer root.remove();
    const home = try std.fmt.allocPrint(allocator, "{s}/home", .{root.path()});
    defer allocator.free(home);
    try std.Io.Dir.cwd().createDirPath(fsIo(), home);
    const default_dir = try std.fmt.allocPrint(allocator, "{s}/.local/state/geode", .{home});
    defer allocator.free(default_dir);

    // A data directory that cannot be opened (its parent is a file): exit 1
    // in both forms, never PASS / graph_store_ok.
    const blocker = try std.fmt.allocPrint(allocator, "{s}/not-a-directory", .{root.path()});
    defer allocator.free(blocker);
    {
        const f = try std.Io.Dir.cwd().createFile(fsIo(), blocker, .{});
        f.close(fsIo());
    }
    const bad_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{blocker});
    defer allocator.free(bad_dir);
    for ([_]bool{ true, false }) |json| {
        const argv: []const []const u8 = if (json)
            &.{ geode_binary, "storage", "verify", "--check", "graph_store", "--data-dir", bad_dir }
        else
            &.{ geode_binary, "storage", "verify", "--data-dir", bad_dir };
        const r = try runGeode(argv, root.path(), home, &.{});
        defer r.deinit();
        const ok = r.code != null and r.code.? != 0 and !r.says("\"graph_store_ok\":true") and !r.says("PASS") and r.says(bad_dir);
        if (!ok) r.dump("(6) verify an unopenable data directory");
        try testing.expect(ok);
    }

    // A real store at --data-dir, at GEODE_DATA_DIR and at the default: each
    // is the one verified (its node count, not an empty store's 0).
    const flag_dir = try std.fmt.allocPrint(allocator, "{s}/flagged", .{root.path()});
    defer allocator.free(flag_dir);
    try seedStore(allocator, flag_dir, 3);
    const env_dir = try std.fmt.allocPrint(allocator, "{s}/from-env", .{root.path()});
    defer allocator.free(env_dir);
    try seedStore(allocator, env_dir, 5);
    try seedStore(allocator, default_dir, 7);

    const Case = struct { what: []const u8, argv_extra: []const []const u8, env: []const Env, want: u64 };
    const cases = [_]Case{
        .{ .what = "--data-dir", .argv_extra = &.{ "--data-dir", flag_dir }, .env = &.{}, .want = 3 },
        .{ .what = "GEODE_DATA_DIR", .argv_extra = &.{}, .env = &.{.{ .name = "GEODE_DATA_DIR", .value = env_dir }}, .want = 5 },
        .{ .what = "default", .argv_extra = &.{}, .env = &.{}, .want = 7 },
    };
    for (cases) |c| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{ geode_binary, "storage", "verify", "--check", "graph_store" });
        try argv.appendSlice(allocator, c.argv_extra);
        const r = try runGeode(argv.items, root.path(), home, c.env);
        defer r.deinit();
        const got = nodeCount(r.stdout);
        const ok = r.code == @as(?u8, 0) and r.says("\"graph_store_ok\":true") and got == c.want and r.says(switch (c.want) {
            3 => flag_dir,
            5 => env_dir,
            else => default_dir,
        });
        if (!ok) {
            std.debug.print("SONNY-6430 (6) {s}: want node_count {d}, got {?d}\n", .{ c.what, c.want, got });
            r.dump("(6) verify a real store");
        }
        try testing.expect(ok);
    }
}

test "SONNY-6430 (8) geode migrate create without an HMAC key refuses and writes nothing; --no-sign creates an unsigned file; with a key it is signed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6430-migrate");
    defer root.remove();
    const mig_dir = try std.fmt.allocPrint(allocator, "{s}/migrations", .{root.path()});
    defer allocator.free(mig_dir);
    try std.Io.Dir.cwd().createDirPath(fsIo(), mig_dir);

    {
        const r = try runGeode(&.{ geode_binary, "migrate", "create", "add_people", "--dir", mig_dir }, root.path(), root.path(), &.{});
        defer r.deinit();
        const ok = r.code != null and r.code.? != 0 and r.says("GEODE_MIGRATION_HMAC_KEY") and r.says("--no-sign") and (try entryCount(mig_dir)) == 0;
        if (!ok) r.dump("(8) migrate create with no key");
        try testing.expect(ok);
    }
    // The help says the same.
    {
        const r = try runGeode(&.{ geode_binary, "migrate", "create", "--help" }, root.path(), root.path(), &.{});
        defer r.deinit();
        const ok = r.code == @as(?u8, 0) and r.says("Requires an HMAC key") and r.says("--no-sign");
        if (!ok) r.dump("(8) migrate create --help");
        try testing.expect(ok);
    }
    // --no-sign: an unsigned file, said so.
    {
        const r = try runGeode(&.{ geode_binary, "migrate", "create", "add_people", "--dir", mig_dir, "--no-sign" }, root.path(), root.path(), &.{});
        defer r.deinit();
        const created = try std.fmt.allocPrint(testing.allocator, "{s}/001_add_people.gql", .{mig_dir});
        defer testing.allocator.free(created);
        const ok = r.code == @as(?u8, 0) and pathExists(created) and r.says("unsigned");
        if (!ok) r.dump("(8) migrate create --no-sign");
        try testing.expect(ok);
    }
    // A key: signed.
    {
        const r = try runGeode(&.{ geode_binary, "migrate", "create", "add_pets", "--dir", mig_dir }, root.path(), root.path(), &.{.{ .name = "GEODE_MIGRATION_HMAC_KEY", .value = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff" }});
        defer r.deinit();
        const ok = r.code == @as(?u8, 0) and r.says("Signed: 002_add_pets.gql");
        if (!ok) r.dump("(8) migrate create with a key");
        try testing.expect(ok);
    }
}
