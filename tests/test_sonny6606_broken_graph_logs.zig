// SONNY-6606 (3): a graph whose manifest cannot be read was logged again at
// every registry save ("graph registry entry has no readable manifest", at
// each graph open and every ~30 s save) and at every full checkpoint ("full
// checkpoint: could not load graph ... to persist its exact index"), though
// nothing about it had changed. Each is now logged once per boot (the
// checkpoint skips a graph whose open already failed and was logged).
//
// Same real-server setup as tests/test_sonny6589_broken_graph_open.zig.
//
// CANARY: REQ=REQ-SONNY-6606-BROKEN-GRAPH-LOG-ONCE; FEATURE="StorageIntegrity"; ASPECT=UnreadableGraphLoggedOnce; STATUS=TESTED; TEST=tests/test_sonny6606_broken_graph_logs.zig; OWNER=storage; UPDATED=2026-11-15
const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const scratch = @import("test_scratch.zig");

const testing = std.testing;

const manifest_log = "graph registry entry has no readable manifest";
const checkpoint_log = "full checkpoint: could not load graph";
const broken = "brk6606";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Server = struct {
    handle: util.ServerHandle,
    addr: []u8,
    log_path: []u8,

    /// `geode serve` on `data_dir`, stdout and stderr in `log_name` there.
    fn start(allocator: std.mem.Allocator, root: []const u8, data_dir: []const u8, log_name: []const u8) !Server {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        const log_path = try std.fs.path.join(allocator, &.{ root, log_name });
        errdefer allocator.free(log_path);

        var map = try std.Io.Threaded.global_single_threaded.environ.process_environ.createMap(allocator);
        errdefer map.deinit();
        try map.put("GEODE_ADMIN_USERNAME", util.DefaultAuth.username);
        try map.put("GEODE_ADMIN_PASSWORD", util.DefaultAuth.password);
        try map.put("GEODE_LSP_PORT", "0");

        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        errdefer threaded.deinit();
        const log_file = try std.Io.Dir.cwd().createFile(io(), log_path, .{});
        defer log_file.close(io());
        const child = try std.process.spawn(threaded.io(), .{
            .argv = &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir, "--log-level=info" },
            .environ_map = &map,
            .stdin = .ignore,
            .stdout = .{ .file = log_file },
            .stderr = .{ .file = log_file },
        });
        var self: Server = .{
            .handle = .{ .allocator = allocator, .threaded = threaded, .child = child, .env_map = map },
            .addr = addr,
            .log_path = log_path,
        };
        errdefer self.handle.deinit();
        try util.waitForServerReady(allocator, addr, 60_000);
        return self;
    }

    /// SIGTERM and wait: the shutdown checkpoint runs.
    fn stop(self: *Server, allocator: std.mem.Allocator) void {
        if (self.handle.child.id) |pid| {
            std.posix.kill(pid, std.posix.SIG.TERM) catch {};
            _ = self.handle.child.wait(self.handle.threaded.io()) catch {};
            self.handle.child.id = null;
        }
        self.handle.deinit();
        allocator.free(self.addr);
        allocator.free(self.log_path);
    }

    fn connect(self: *Server, allocator: std.mem.Allocator) !util.QuicProtoClient {
        var client = try util.QuicProtoClient.connect(allocator, self.addr);
        errdefer client.deinit();
        var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(allocator);
        if (!h.success) return error.HelloFailed;
        return client;
    }
};

/// The error code of `q` (null on success), after `USE GRAPH g` when given.
fn run(allocator: std.mem.Allocator, client: *util.QuicProtoClient, g: ?[]const u8, q: []const u8) !?[5]u8 {
    if (g) |name| {
        var qb: [96]u8 = undefined;
        if (try run(allocator, client, null, try std.fmt.bufPrint(&qb, "USE GRAPH {s}", .{name}))) |code| return code;
    }
    var r = try client.executeAndCollect(allocator, q, util.emptyParams(), 100);
    defer r.deinit(allocator);
    const code = r.error_code orelse return null;
    var out: [5]u8 = .{ '?', '?', '?', '?', '?' };
    @memcpy(out[0..@min(5, code.len)], code[0..@min(5, code.len)]);
    return out;
}

/// The uuid directories of `data_dir` (32 hex characters).
fn graphDirs(allocator: std.mem.Allocator, data_dir: []const u8) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |d| allocator.free(d);
        out.deinit(allocator);
    }
    var dir = try std.Io.Dir.cwd().openDir(io(), data_dir, .{ .iterate = true });
    defer dir.close(io());
    var it = dir.iterate();
    while (try it.next(io())) |entry| {
        if (entry.kind != .directory or entry.name.len != 32) continue;
        try out.append(allocator, try allocator.dupe(u8, entry.name));
    }
    return out;
}

fn freeDirs(allocator: std.mem.Allocator, dirs: *std.ArrayList([]u8)) void {
    for (dirs.items) |d| allocator.free(d);
    dirs.deinit(allocator);
}

test "SONNY-6606 (3): a graph with an unreadable manifest is reported once per boot, not at every registry save and checkpoint" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var root = try scratch.ScratchDir.create("sonny6606-logs");
    defer root.remove();
    const data_dir = try std.fs.path.join(allocator, &.{ root.path(), "data" });
    defer allocator.free(data_dir);
    try std.Io.Dir.cwd().createDirPath(io(), data_dir);

    // Boot 1: a healthy graph next to the one that will be broken.
    var before: std.ArrayList([]u8) = .empty;
    defer freeDirs(allocator, &before);
    {
        var server = try Server.start(allocator, root.path(), data_dir, "boot1.log");
        defer server.stop(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        for ([_][]const u8{ "CREATE GRAPH ok6606", "USE GRAPH ok6606", "CREATE (:Ok6606)" }) |q| {
            if (try run(allocator, &client, null, q)) |code| {
                std.debug.print("SONNY-6606 setup '{s}': {s}\n", .{ q, &code });
                return error.SetupFailed;
            }
        }
        before = try graphDirs(allocator, data_dir);
        for ([_][]const u8{ "CREATE GRAPH " ++ broken, "USE GRAPH " ++ broken, "CREATE (:A6606 {x: 1})" }) |q| {
            if (try run(allocator, &client, null, q)) |code| {
                std.debug.print("SONNY-6606 setup '{s}': {s}\n", .{ q, &code });
                return error.SetupFailed;
            }
        }
    }

    // The broken graph's directory is the one boot 1 added last.
    var after = try graphDirs(allocator, data_dir);
    defer freeDirs(allocator, &after);
    var broken_dir: ?[]const u8 = null;
    for (after.items) |d| {
        var seen = false;
        for (before.items) |b| {
            if (std.mem.eql(u8, b, d)) seen = true;
        }
        if (!seen) broken_dir = d;
    }
    const uuid_dir = broken_dir orelse return error.BrokenGraphDirNotFound;
    const manifest = try std.fmt.allocPrint(allocator, "{s}/{s}/shard_manifest.json", .{ data_dir, uuid_dir });
    defer allocator.free(manifest);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = manifest, .data = "not a manifest" });

    // Boot 2: three reads of the broken graph, one of the healthy one.
    {
        var server = try Server.start(allocator, root.path(), data_dir, "boot2.log");
        var stopped = false;
        defer if (!stopped) server.stop(allocator);
        for (0..3) |i| {
            var client = try server.connect(allocator);
            defer client.deinit();
            const code = try run(allocator, &client, broken, "MATCH (n) RETURN count(n) AS c");
            if (code == null or !std.mem.eql(u8, &code.?, "58000")) {
                const got: []const u8 = if (code) |*c| c else "success";
                std.debug.print("SONNY-6606: read {d} of the broken graph answered {s} (want 58000)\n", .{ i, got });
                return error.TestUnexpectedResult;
            }
        }
        {
            var client = try server.connect(allocator);
            defer client.deinit();
            if (try run(allocator, &client, "ok6606", "MATCH (n:Ok6606) RETURN count(n) AS c")) |code| {
                std.debug.print("SONNY-6606: the healthy graph answered {s}\n", .{&code});
                return error.TestUnexpectedResult;
            }
        }
        const log_path = try allocator.dupe(u8, server.log_path);
        defer allocator.free(log_path);
        server.stop(allocator);
        stopped = true;

        const text = try std.Io.Dir.cwd().readFileAlloc(io(), log_path, allocator, .limited(64 << 20));
        defer allocator.free(text);
        const manifest_logs = std.mem.count(u8, text, manifest_log);
        const checkpoint_logs = std.mem.count(u8, text, checkpoint_log);
        if (manifest_logs != 1 or checkpoint_logs != 0) {
            std.debug.print("SONNY-6606: \"{s}\" logged {d} times (want 1), \"{s}\" {d} times (want 0); log:\n{s}\n", .{ manifest_log, manifest_logs, checkpoint_log, checkpoint_logs, text });
            return error.TestUnexpectedResult;
        }
    }
}
