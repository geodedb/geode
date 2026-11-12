// SONNY-6430 (5, 7): two storage opens that degraded instead of failing.
//   (5) `StorageAdapter.initAuditForGraph` returned null on any error other
//       than an unusable audit key pair, so an audit log that could not be
//       opened (EACCES, a tampered tail, ...) let `__geode_security` open
//       with no audit logger: auth changes were made unaudited.
//   (7) `StorageAdapter.init` only logged a warning when graph_registry.dat
//       existed but could not be read or parsed, and started with no graphs:
//       every graph of the data directory was gone until the next restart
//       that happened to read the file, and the first CREATE GRAPH rewrote
//       the registry without them.
//
// The contract: the security graph does not open without its audit logger,
// whatever the reason; a registry file that exists but cannot be loaded is
// an error (the server refuses to start). A missing registry is a fresh data
// directory and still opens.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const logging = @import("logging");
const test_scratch = @import("test_scratch.zig");

const graph_store = geode.graph_store;

extern "c" fn geteuid() c_uint;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn quiet() void {
    logging.init(.{ .level = .fatal });
    logging.setLevel(.fatal);
}

/// The first file named `name` under `root` (depth-first), or null.
fn findFile(allocator: std.mem.Allocator, root: []const u8, name: []const u8) !?[]u8 {
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), root, .{ .iterate = true });
    defer dir.close(fsIo());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(fsIo())) |entry| {
        if (entry.kind == .file and std.mem.eql(u8, entry.basename, name)) {
            return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.path });
        }
    }
    return null;
}

fn chmod(path: []const u8, mode: u32) !void {
    const z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(z);
    if (std.os.linux.errno(std.os.linux.chmod(z, mode)) != .SUCCESS) return error.ChmodFailed;
}

test "SONNY-6430 (5) __geode_security does not open without its audit logger when the audit log cannot be opened (EACCES)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (geteuid() == 0) return error.SkipZigTest; // root ignores the mode
    quiet();
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6430-sec-audit");
    defer root.remove();

    // A security graph with its audit log.
    {
        const adapter = try graph_store.initGlobalAdapter(allocator, root.path());
        defer graph_store.deinitGlobalAdapter();
        const mg = try adapter.getOrCreateGraph("__geode_security");
        try testing.expect(mg.audit_logger != null);
    }
    const log_path = (try findFile(allocator, root.path(), "audit.jsonl")) orelse return error.AuditLogNotWritten;
    defer allocator.free(log_path);
    try chmod(log_path, 0o000);
    defer chmod(log_path, 0o600) catch {};

    const adapter = try graph_store.initGlobalAdapter(allocator, root.path());
    defer graph_store.deinitGlobalAdapter();
    if (adapter.getOrCreateGraph("__geode_security")) |mg| {
        std.debug.print("SONNY-6430 (5): __geode_security opened with audit_logger={s} although {s} is unreadable\n", .{ if (mg.audit_logger == null) "null (unaudited)" else "set", log_path });
        return error.TestExpectedError;
    } else |err| {
        try testing.expectEqual(@as(anyerror, error.AccessDenied), @as(anyerror, err));
    }
}

test "SONNY-6430 (5) __geode_security does not open without its audit logger when the audit directory cannot be written" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (geteuid() == 0) return error.SkipZigTest;
    quiet();
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6430-sec-audit-dir");
    defer root.remove();
    {
        const adapter = try graph_store.initGlobalAdapter(allocator, root.path());
        defer graph_store.deinitGlobalAdapter();
        _ = try adapter.getOrCreateGraph("__geode_security");
    }
    // Remove the log and make its directory read-only: it cannot be created.
    const log_path = (try findFile(allocator, root.path(), "audit.jsonl")) orelse return error.AuditLogNotWritten;
    defer allocator.free(log_path);
    try std.Io.Dir.cwd().deleteFile(fsIo(), log_path);
    const graph_dir = std.fs.path.dirname(log_path).?;
    try chmod(graph_dir, 0o500);
    defer chmod(graph_dir, 0o700) catch {};

    const adapter = graph_store.initGlobalAdapter(allocator, root.path()) catch |err| {
        // Refusing earlier (the engine cannot write either) is also closed.
        std.debug.print("SONNY-6430 (5): the adapter refused to open: {s}\n", .{@errorName(err)});
        return;
    };
    defer graph_store.deinitGlobalAdapter();
    if (adapter.getOrCreateGraph("__geode_security")) |mg| {
        if (mg.audit_logger == null) {
            std.debug.print("SONNY-6430 (5): __geode_security opened unaudited (its audit log cannot be created)\n", .{});
            return error.TestExpectedError;
        }
        // The graph may not open at all with a read-only directory; it must
        // never open without the logger.
    } else |_| {}
}

test "SONNY-6430 (7) StorageAdapter.init refuses a graph registry that exists but cannot be loaded, instead of starting with no graphs" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    quiet();
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6430-registry");
    defer root.remove();
    {
        const adapter = try graph_store.initGlobalAdapter(allocator, root.path());
        defer graph_store.deinitGlobalAdapter();
        _ = try adapter.getOrCreateGraph("sonny6430_g");
    }
    const reg_path = try std.fmt.allocPrint(allocator, "{s}/graph_registry.dat", .{root.path()});
    defer allocator.free(reg_path);
    const good = try std.Io.Dir.cwd().readFileAlloc(fsIo(), reg_path, allocator, .limited(1 << 20));
    defer allocator.free(good);

    // A clean registry reopens with the graph in it.
    {
        const adapter = try graph_store.initGlobalAdapter(allocator, root.path());
        defer graph_store.deinitGlobalAdapter();
        try testing.expect(adapter.registry.findByName("sonny6430_g") != null);
    }

    const Damage = enum { flipped_byte, truncated, garbage, unreadable };
    for ([_]Damage{ .flipped_byte, .truncated, .garbage, .unreadable }) |d| {
        switch (d) {
            .flipped_byte => {
                const bad = try allocator.dupe(u8, good);
                defer allocator.free(bad);
                bad[bad.len / 2] ^= 0xff;
                try std.Io.Dir.cwd().writeFile(fsIo(), .{ .sub_path = reg_path, .data = bad });
            },
            .truncated => try std.Io.Dir.cwd().writeFile(fsIo(), .{ .sub_path = reg_path, .data = good[0 .. good.len / 2] }),
            .garbage => try std.Io.Dir.cwd().writeFile(fsIo(), .{ .sub_path = reg_path, .data = "not a geode graph registry, just text that is long enough" }),
            .unreadable => {
                if (geteuid() == 0) continue;
                try std.Io.Dir.cwd().writeFile(fsIo(), .{ .sub_path = reg_path, .data = good });
                try chmod(reg_path, 0o000);
            },
        }
        defer chmod(reg_path, 0o600) catch {};
        if (graph_store.initGlobalAdapter(allocator, root.path())) |adapter| {
            const graphs = adapter.registry.entries.items.len;
            graph_store.deinitGlobalAdapter();
            std.debug.print("SONNY-6430 (7): the adapter opened a {s} graph registry with {d} graphs\n", .{ @tagName(d), graphs });
            return error.TestExpectedError;
        } else |_| {}
    }

    // Restored, it opens again with the graph (nothing was rewritten).
    try std.Io.Dir.cwd().writeFile(fsIo(), .{ .sub_path = reg_path, .data = good });
    const adapter = try graph_store.initGlobalAdapter(allocator, root.path());
    defer graph_store.deinitGlobalAdapter();
    try testing.expect(adapter.registry.findByName("sonny6430_g") != null);
}

test "SONNY-6430 (7) a data directory without a graph registry still opens" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    quiet();
    var root = try test_scratch.ScratchDir.create("sonny6430-registry-fresh");
    defer root.remove();
    const adapter = try graph_store.initGlobalAdapter(testing.allocator, root.path());
    defer graph_store.deinitGlobalAdapter();
    try testing.expectEqual(@as(usize, 0), adapter.registry.entries.items.len);
}
