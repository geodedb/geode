// CANARY: REQ=REQ-SONNY-6422-CLI-DATA-DIR-FAIL-CLOSED; FEATURE="DataDir"; ASPECT=NoInMemoryFallback; STATUS=TESTED; TEST=tests/test_sonny6422_cli_data_dir_fail_closed.zig; OWNER=storage; UPDATED=2026-11-12
//
// SONNY-6422 (6): a CLI path that reaches the store through
// `graph_store.getGlobalStore` with a data directory (GEODE_DATA_DIR or the
// override) and no `initGlobalStore` opened the engine-backed adapter in
// `syncGlobalAdapterForDataDir`; when that failed it logged a warning and
// carried on with an empty in-memory store. `geode storage verify --check
// graph_store` then reported `{"graph_store_ok":true,"node_count":0}` for a
// data directory it never opened. `initCliAuthManager` (every offline
// auth/apikey/tenant command) fell back the same way when `initGlobalStore`
// failed.
//
// The contract: a command asked to operate on a data directory that cannot
// be opened fails (non-zero exit, the directory and the reason named) and
// never reports results from an empty in-memory store.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const geode_binary = geode_test_bin.geode_exe;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

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
};

fn runGeode(argv: []const []const u8, cwd: []const u8, data_dir: []const u8) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("GEODE_DATA_DIR", data_dir);
    const result = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(120), .clock = .awake } },
    });
    const code: ?u8 = switch (result.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

test "SONNY-6422 (6) geode storage verify fails on a data directory it cannot open instead of verifying an empty in-memory store" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6422-cli-datadir");
    defer root.remove();

    // The data directory's parent is a regular file: it cannot be created.
    const blocker = try std.fmt.allocPrint(allocator, "{s}/not-a-directory", .{root.path()});
    defer allocator.free(blocker);
    {
        const f = try std.Io.Dir.cwd().createFile(fsIo(), blocker, .{});
        f.close(fsIo());
    }
    const data_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{blocker});
    defer allocator.free(data_dir);

    const r = try runGeode(&.{ geode_binary, "storage", "verify", "--check", "graph_store" }, root.path(), data_dir);
    defer r.deinit();
    const ok = r.code != null and r.code.? != 0 and !r.says("\"graph_store_ok\":true") and r.says(data_dir);
    if (!ok) std.debug.print("SONNY-6422 (6): storage verify on an unopenable data dir: exit={?d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ r.code, r.stdout, r.stderr });
    try testing.expect(ok);
}

test "SONNY-6422 (6) geode storage verify still verifies a data directory it can open" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6422-cli-datadir-ok");
    defer root.remove();
    const data_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{root.path()});
    defer allocator.free(data_dir);
    const r = try runGeode(&.{ geode_binary, "storage", "verify", "--check", "graph_store" }, root.path(), data_dir);
    defer r.deinit();
    const ok = r.code == @as(?u8, 0) and r.says("\"graph_store_ok\":true");
    if (!ok) std.debug.print("SONNY-6422 (6): storage verify on a fresh data dir: exit={?d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ r.code, r.stdout, r.stderr });
    try testing.expect(ok);
}
