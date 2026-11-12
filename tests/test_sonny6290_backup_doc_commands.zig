// CANARY: REQ=REQ-SONNY-6290-BACKUP-DOC-COMMANDS; FEATURE="CLI Backup"; ASPECT=DocumentedCommandsExist; STATUS=TESTED; TEST=tests/test_sonny6290_backup_doc_commands.zig; OWNER=cli; UPDATED=2026-11-12
//
// SONNY-6290: docs/USAGE.md and docs/deployment/DEPLOYMENT.md documented
// `geode backup --dest s3://... --mode full|incremental --parent <id>` and
// `--list`, a command form the binary does not have, and the docs described
// S3 / Digital Ocean Spaces backup and restore although the geode binary has
// no object-storage path at all (src/storage/s3_backup.zig is reached by no
// command). `geode backup create` also ignored options it did not know, and
// `--output s3://bucket/key` was taken as a local path (with --local it
// created a directory named `s3:` and reported success).
//
// The contract:
//   - every `geode backup ...` / `geode restore ...` command in the
//     operator docs names a subcommand the built binary has, and every
//     --option in it appears in that subcommand's --help, and none of them
//     names an s3:// or http(s):// location;
//   - `geode backup create` refuses an option it does not know, and refuses
//     an --output that is a URI (object storage is not supported: copy the
//     backup file with your own tooling), writing nothing.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const geode_binary = geode_test_bin.geode_exe;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn join(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

const Run = struct {
    code: ?u8,
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

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6290 {s}: exit={?d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ what, self.code, self.stdout, self.stderr });
    }
};

fn runGeode(argv: []const []const u8, cwd: []const u8) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
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

/// The operator docs that show geode backup/restore commands.
const docs = [_][]const u8{
    "docs/USAGE.md",
    "docs/deployment/DEPLOYMENT.md",
    "docs/API_REFERENCE.md",
    "README.md",
    "CLAUDE.md",
};

const backup_subcommands = [_][]const u8{ "create", "list", "info", "cleanup" };

/// The help text of `geode <cmd> [<sub>] --help`, cached per command.
const HelpCache = struct {
    map: std.StringHashMap([]u8),
    cwd: []const u8,

    fn get(self: *HelpCache, key: []const u8, argv: []const []const u8) ![]const u8 {
        if (self.map.get(key)) |h| return h;
        const r = try runGeode(argv, self.cwd);
        defer r.deinit();
        const text = try std.mem.concat(testing.allocator, u8, &.{ r.stdout, r.stderr });
        errdefer testing.allocator.free(text);
        const owned_key = try testing.allocator.dupe(u8, key);
        errdefer testing.allocator.free(owned_key);
        try self.map.put(owned_key, text);
        return text;
    }

    fn deinit(self: *HelpCache) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            testing.allocator.free(e.key_ptr.*);
            testing.allocator.free(e.value_ptr.*);
        }
        self.map.deinit();
    }
};

fn checkCommand(cache: *HelpCache, doc: []const u8, line_no: usize, cmd: []const u8) !usize {
    var problems: usize = 0;
    var toks: std.ArrayList([]const u8) = .empty;
    defer toks.deinit(testing.allocator);
    var it = std.mem.tokenizeAny(u8, cmd, " \t`");
    while (it.next()) |t| {
        if (std.mem.startsWith(u8, t, "#")) break;
        if (std.mem.eql(u8, t, "|") or std.mem.eql(u8, t, "&&") or std.mem.eql(u8, t, ";") or std.mem.eql(u8, t, "\\")) break;
        try toks.append(testing.allocator, t);
    }
    // toks[0] == "geode", toks[1] == backup|restore
    if (toks.items.len < 2) return 0;
    const is_backup = std.mem.eql(u8, toks.items[1], "backup");
    var help: []const u8 = undefined;
    var first_opt: usize = 2;
    if (is_backup) {
        if (toks.items.len < 3) return 0; // prose mention "geode backup"
        const sub = toks.items[2];
        var known = false;
        for (backup_subcommands) |s| {
            if (std.mem.eql(u8, sub, s)) known = true;
        }
        if (!known) {
            if (std.mem.startsWith(u8, sub, "-") or std.mem.indexOf(u8, sub, "://") != null) {
                std.debug.print("SONNY-6290: {s}:{d}: 'geode backup {s} ...' is not a geode command (subcommands: create, list, info, cleanup): {s}\n", .{ doc, line_no, sub, cmd });
                problems += 1;
            }
            return problems;
        }
        const key = try std.fmt.allocPrint(testing.allocator, "backup {s}", .{sub});
        defer testing.allocator.free(key);
        help = try cache.get(key, &.{ geode_binary, "backup", sub, "--help" });
        first_opt = 3;
    } else {
        help = try cache.get("restore", &.{ geode_binary, "restore", "--help" });
    }
    for (toks.items[first_opt..]) |t| {
        if (std.mem.indexOf(u8, t, "s3://") != null or std.mem.startsWith(u8, t, "http://") or std.mem.startsWith(u8, t, "https://")) {
            std.debug.print("SONNY-6290: {s}:{d}: names an object-storage location ({s}); geode backup/restore have no object-storage path: {s}\n", .{ doc, line_no, t, cmd });
            problems += 1;
        }
        if (!std.mem.startsWith(u8, t, "--")) continue;
        const opt = if (std.mem.indexOfScalar(u8, t, '=')) |eq| t[0..eq] else t;
        // An option must appear in the help as itself, not as a prefix of a longer one.
        var found = false;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, help, pos, opt)) |at| {
            const end = at + opt.len;
            if (end >= help.len or !(std.ascii.isAlphanumeric(help[end]) or help[end] == '-')) {
                found = true;
                break;
            }
            pos = end;
        }
        if (!found) {
            std.debug.print("SONNY-6290: {s}:{d}: option {s} is not in 'geode {s}{s}{s} --help': {s}\n", .{ doc, line_no, opt, toks.items[1], if (is_backup) " " else "", if (is_backup) toks.items[2] else "", cmd });
            problems += 1;
        }
    }
    return problems;
}

test "SONNY-6290 every geode backup / restore command in the operator docs exists in the built binary, with no object-storage location" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6290-docs");
    defer root.remove();
    var cache: HelpCache = .{ .map = std.StringHashMap([]u8).init(allocator), .cwd = root.path() };
    defer cache.deinit();

    var problems: usize = 0;
    var commands: usize = 0;
    for (docs) |doc| {
        const text = try std.Io.Dir.cwd().readFileAlloc(fsIo(), doc, allocator, .limited(4 << 20));
        defer allocator.free(text);
        var in_fence = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var line_no: usize = 0;
        while (lines.next()) |raw| {
            line_no += 1;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.startsWith(u8, line, "```")) {
                in_fence = !in_fence;
                continue;
            }
            // Commands: lines of a fenced block, and `> geode ...` quoted lines.
            const body = if (in_fence)
                line
            else if (std.mem.startsWith(u8, line, "> geode "))
                line[2..]
            else
                continue;
            var start: usize = 0;
            while (std.mem.indexOfPos(u8, body, start, "geode ")) |at| {
                const rest = body[at..];
                start = at + "geode ".len;
                if (at > 0 and body[at - 1] != ' ' and body[at - 1] != '\t' and body[at - 1] != '`' and body[at - 1] != '=') continue;
                if (!std.mem.startsWith(u8, rest, "geode backup ") and !std.mem.startsWith(u8, rest, "geode restore")) continue;
                commands += 1;
                problems += try checkCommand(&cache, doc, line_no, rest);
            }
        }
    }
    std.debug.print("SONNY-6290: checked {d} documented geode backup/restore commands\n", .{commands});
    try testing.expect(commands >= 5);
    try testing.expectEqual(@as(usize, 0), problems);
}

test "SONNY-6290 geode backup create refuses an unknown option and an object-storage --output, writing nothing" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6290-uri");
    defer root.remove();
    const cwd = root.path();
    const d = try join(allocator, cwd, "D");
    defer allocator.free(d);
    try std.Io.Dir.cwd().createDirPath(fsIo(), d);

    const cases = [_]struct { what: []const u8, argv: []const []const u8, needle: []const u8 }{
        .{ .what = "s3 output, local", .argv = &.{ geode_binary, "backup", "create", "--local", "--data-dir", d, "--output", "s3://bucket/geode/full.backup" }, .needle = "not supported" },
        .{ .what = "s3 output, server", .argv = &.{ geode_binary, "backup", "create", "--server", "127.0.0.1:1", "--output", "s3://bucket/geode/full.backup" }, .needle = "not supported" },
        .{ .what = "https output", .argv = &.{ geode_binary, "backup", "create", "--local", "--data-dir", d, "--output", "https://example.invalid/full.backup" }, .needle = "not supported" },
        .{ .what = "unknown option", .argv = &.{ geode_binary, "backup", "create", "--local", "--data-dir", d, "--output", "x.backup", "--dest", "s3://bucket/geode" }, .needle = "--dest" },
        .{ .what = "unknown option --mode", .argv = &.{ geode_binary, "backup", "create", "--local", "--data-dir", d, "--output", "x.backup", "--mode", "incremental" }, .needle = "--mode" },
    };
    var failures: usize = 0;
    for (cases) |c| {
        const r = try runGeode(c.argv, cwd);
        defer r.deinit();
        if (r.code == @as(?u8, 0) or r.code == null or !r.output(c.needle)) {
            r.dump(c.what);
            failures += 1;
        }
    }
    // Nothing written: no `s3:`/`https:` directory, no x.backup.
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), cwd, .{ .iterate = true });
    defer dir.close(fsIo());
    var it = dir.iterate();
    while (try it.next(fsIo())) |entry| {
        if (std.mem.eql(u8, entry.name, "D")) continue;
        std.debug.print("SONNY-6290: a refused backup create left {s}/{s}\n", .{ cwd, entry.name });
        failures += 1;
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
