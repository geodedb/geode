// CANARY: REQ=REQ-BACKUP-RESTORE-002; FEATURE="Backup Restore"; ASPECT=LocalRestoreWritesAndVerifies; STATUS=TESTED; TEST=tests/test_sonny6280_cli_restore_writes_data.zig; OWNER=cli; UPDATED=2026-11-11
//
// SONNY-6280: `geode restore <local file>` must write the backup into the
// data directory the caller names and report success only once the restored
// directory has been written and verified. It used to check the archive,
// write nothing, and print "Full backup restore completed" with exit 0.
//
// Each case spawns the geode this build emitted (SONNY-2697): `geode backup
// create --local` makes the backup, `geode restore` restores it, and the
// restored directory is then opened cold in this process and read through
// the executor (nodes, edges and typed property values, default graph and a
// named graph). The failure cases (corrupt, truncated, missing source,
// encrypted with the wrong or no key, unsafe archive entry names, unwritable
// or non-empty target, no target, remote URI) must exit non-zero, print no
// success line, and leave no restored or half-restored directory behind.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const backup = @import("storage/backup");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const graph_store = geode.graph_store;
const execution = geode.execution;

const geode_binary = geode_test_bin.geode_exe;
const named_graph = "sonny6280";
const success_line = "Restore completed successfully";
const tde_key_a = "a1a2a3a4a5a6a7a8b1b2b3b4b5b6b7b8c1c2c3c4c5c6c7c8d1d2d3d4d5d6d7d8";
const tde_key_b = "0f0e0d0c0b0a09080706050403020100ffeeddccbbaa99887766554433221100";

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Session = struct {
    arena: std.heap.ArenaAllocator,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    fn open(allocator: std.mem.Allocator, data_dir: []const u8) !Session {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        _ = try graph_store.initGlobalStore(allocator, data_dir);
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .session = execution.SessionState.init(allocator),
            .ctx = .{ .catalog = catalog },
        };
    }

    fn close(self: *Session, allocator: std.mem.Allocator) void {
        self.session.deinit();
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    fn resetSession(self: *Session, allocator: std.mem.Allocator) void {
        self.session.deinit();
        self.session = execution.SessionState.init(allocator);
    }

    fn exec(self: *Session, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn run(self: *Session, query: []const u8) !void {
        var r = try self.exec(query);
        r.deinit(self.arena.allocator());
    }

    fn count(self: *Session, query: []const u8) !i64 {
        var r = try self.exec(query);
        defer r.deinit(self.arena.allocator());
        try testing.expectEqual(@as(usize, 1), r.rows.len);
        return switch (r.rows[0][0]) {
            .Int => |c| c,
            else => error.UnexpectedValueTag,
        };
    }
};

/// Default graph: 3 :Person, 2 :City, 3 edges. Named graph: 2 :Item, 1 edge.
fn seed(s: *Session) !void {
    try s.run("INSERT (:Person {name: 'Alice', age: 30, score: 1.5, active: true})");
    try s.run("INSERT (:Person {name: 'Bob', age: 25, score: 2.25, active: false})");
    try s.run("INSERT (:Person {name: 'Carol', age: 41, score: 3.0, active: true})");
    try s.run("INSERT (:City {name: 'Oslo'})");
    try s.run("INSERT (:City {name: 'Lima'})");
    try s.run("MATCH (a:Person {name: 'Alice'}), (c:City {name: 'Oslo'}) CREATE (a)-[:LIVES_IN {since: 2019}]->(c)");
    try s.run("MATCH (a:Person {name: 'Bob'}), (c:City {name: 'Lima'}) CREATE (a)-[:LIVES_IN {since: 2021}]->(c)");
    try s.run("MATCH (a:Person {name: 'Alice'}), (b:Person {name: 'Carol'}) CREATE (a)-[:KNOWS {weight: 0.75}]->(b)");

    try s.run("CREATE GRAPH " ++ named_graph);
    try s.run("USE GRAPH " ++ named_graph);
    try s.run("INSERT (:Item {sku: 'A-1', qty: 7})");
    try s.run("INSERT (:Item {sku: 'B-2', qty: 9})");
    try s.run("MATCH (a:Item {sku: 'A-1'}), (b:Item {sku: 'B-2'}) CREATE (a)-[:PAIRS {rank: 1}]->(b)");
}

/// Exactly the seeded data, read through the executor (hydrating reads).
fn expectGraphData(allocator: std.mem.Allocator, s: *Session) !void {
    s.resetSession(allocator);
    try s.run("USE GRAPH " ++ named_graph);
    try testing.expectEqual(@as(i64, 2), try s.count("MATCH (n) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 1), try s.count("MATCH ()-[e]->() RETURN count(e) AS c"));
    try testing.expectEqual(@as(i64, 1), try s.count("MATCH (:Item {sku: 'A-1', qty: 7})-[e:PAIRS {rank: 1}]->(:Item {sku: 'B-2', qty: 9}) RETURN count(e) AS c"));

    s.resetSession(allocator);
    try testing.expectEqual(@as(i64, 5), try s.count("MATCH (n) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 3), try s.count("MATCH (n:Person) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 2), try s.count("MATCH (n:City) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 3), try s.count("MATCH ()-[e]->() RETURN count(e) AS c"));
    try testing.expectEqual(@as(i64, 1), try s.count("MATCH (:Person {name: 'Bob'})-[e:LIVES_IN {since: 2021}]->(:City {name: 'Lima'}) RETURN count(e) AS c"));
    try testing.expectEqual(@as(i64, 1), try s.count("MATCH (n:Person) WHERE n.age = 30 AND n.score = 1.5 AND n.active = true AND n.name = 'Alice' RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 1), try s.count("MATCH (n:Person) WHERE n.age = 25 AND n.score = 2.25 AND n.active = false RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 1), try s.count("MATCH ()-[e:KNOWS]->() WHERE e.weight = 0.75 RETURN count(e) AS c"));
    try testing.expectEqual(@as(i64, 1), try s.count("MATCH (n:Person) WHERE n.score = 3.0 AND n.age = 41 RETURN count(n) AS c"));
    {
        var r = try s.exec("MATCH (n:Person {name: 'Carol'}) RETURN n.age AS age, n.active AS active, n.name AS name");
        defer r.deinit(s.arena.allocator());
        try testing.expectEqual(@as(usize, 1), r.rows.len);
        try testing.expectEqual(@as(i64, 41), r.rows[0][0].Int);
        try testing.expectEqual(true, r.rows[0][1].Bool);
        try testing.expectEqualStrings("Carol", r.rows[0][2].Str);
    }

    const store = graph_store.getGlobalStore(allocator);
    const ids = try store.getAllNodes(allocator);
    defer allocator.free(ids);
    try testing.expectEqual(@as(usize, 7), ids.len);
}

fn seedDataDir(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    var s = try Session.open(allocator, data_dir);
    defer s.close(allocator);
    try seed(&s);
}

fn expectRestoredDir(allocator: std.mem.Allocator, dir: []const u8) !void {
    var s = try Session.open(allocator, dir);
    defer s.close(allocator);
    try expectGraphData(allocator, &s);
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
        std.debug.print("SONNY-6280 {s}: exit={?d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ what, self.code, self.stdout, self.stderr });
    }
};

/// Runs geode with PATH and HOME from the parent plus `extra_env`, in `cwd`
/// (so a restore that writes relative to its working directory is caught).
fn runGeode(argv: []const []const u8, extra_env: []const [2][]const u8, cwd: []const u8) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    for (extra_env) |kv| try env.put(kv[0], kv[1]);

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

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(fsIo(), path, .{}) catch return false;
    return true;
}

fn join(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

fn dirEntryCount(path: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), path, .{ .iterate = true });
    defer dir.close(fsIo());
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(fsIo())) |_| n += 1;
    return n;
}

/// The names in `parent`, so a failure case can assert nothing new appeared
/// (no target, no staging sibling).
fn expectDirNames(parent: []const u8, expected: []const []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), parent, .{ .iterate = true });
    defer dir.close(fsIo());
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(fsIo())) |entry| {
        var known = false;
        for (expected) |name| {
            if (std.mem.eql(u8, name, entry.name)) known = true;
        }
        if (!known) std.debug.print("SONNY-6280: unexpected entry left in {s}: {s}\n", .{ parent, entry.name });
        try testing.expect(known);
        n += 1;
    }
    try testing.expectEqual(expected.len, n);
}

/// A failed restore: non-zero exit, no success line, a named error.
fn expectRestoreFailed(r: Run, code: u8, needle: []const u8) !void {
    if (r.code != @as(?u8, code) or r.output(success_line) or r.output("restore completed") or !r.output(needle)) {
        r.dump("restore expected to fail");
    }
    try testing.expectEqual(@as(?u8, code), r.code);
    try testing.expect(!r.output(success_line));
    try testing.expect(!r.output("Full backup restore completed"));
    try testing.expect(!r.output("Point-in-time restore completed"));
    try testing.expect(r.output(needle));
}

const Fixture = struct {
    root: test_scratch.ScratchDir,
    data: []u8,
    cwd: []u8,
    backup_file: []u8,

    /// Seeds a data dir in this process and backs it up with the CLI's
    /// documented local form (`backup create --local --data-dir`).
    fn init(allocator: std.mem.Allocator, tag: []const u8, compress: bool) !Fixture {
        var root = try test_scratch.ScratchDir.create(tag);
        errdefer root.remove();
        const data = try join(allocator, root.path(), "data");
        errdefer allocator.free(data);
        const cwd = try join(allocator, root.path(), "cwd");
        errdefer allocator.free(cwd);
        const backup_file = try join(allocator, root.path(), "out/full.backup");
        errdefer allocator.free(backup_file);
        try std.Io.Dir.cwd().createDirPath(fsIo(), data);
        try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);
        const out_dir = try join(allocator, root.path(), "out");
        defer allocator.free(out_dir);
        try std.Io.Dir.cwd().createDirPath(fsIo(), out_dir);

        try seedDataDir(allocator, data);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{ geode_binary, "backup", "create", "--local", "--data-dir", data, "--output", backup_file });
        if (compress) try argv.append(allocator, "--compress");
        const r = try runGeode(argv.items, &.{}, cwd);
        defer r.deinit();
        if (r.code != @as(?u8, 0)) r.dump("backup create --local");
        try testing.expectEqual(@as(?u8, 0), r.code);
        try testing.expect(pathExists(backup_file));

        return .{ .root = root, .data = data, .cwd = cwd, .backup_file = backup_file };
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.free(self.cwd);
        allocator.free(self.backup_file);
        self.root.remove();
    }

    fn path(self: *Fixture, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        return join(allocator, self.root.path(), name);
    }

    /// The restore never writes into its working directory.
    fn expectCwdEmpty(self: *Fixture) !void {
        try testing.expectEqual(@as(usize, 0), try dirEntryCount(self.cwd));
    }
};

fn restoreRoundTrip(compress: bool) !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var fx = try Fixture.init(allocator, "sonny6280-rt", compress);
    defer fx.deinit(allocator);
    const target = try fx.path(allocator, "restored");
    defer allocator.free(target);

    const r = try runGeode(&.{ geode_binary, "restore", fx.backup_file, "--data-dir", target, "--yes" }, &.{}, fx.cwd);
    defer r.deinit();
    if (r.code != @as(?u8, 0) or !r.output(success_line)) r.dump("restore");
    try testing.expectEqual(@as(?u8, 0), r.code);
    try testing.expect(r.output(success_line));
    try fx.expectCwdEmpty();
    try testing.expect(pathExists(target));

    // Opened cold, twice: the restored directory holds exactly the seed.
    try expectRestoredDir(allocator, target);
    try expectRestoredDir(allocator, target);
}

test "SONNY-6280 CLI restore writes every node, edge and typed property into --data-dir (uncompressed)" {
    try restoreRoundTrip(false);
}

test "SONNY-6280 CLI restore writes every node, edge and typed property into --data-dir (gzip)" {
    try restoreRoundTrip(true);
}

test "SONNY-6280 CLI restore takes the target directory from GEODE_DATA_DIR" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var fx = try Fixture.init(allocator, "sonny6280-env", false);
    defer fx.deinit(allocator);
    const target = try fx.path(allocator, "restored");
    defer allocator.free(target);
    // An existing empty directory is an acceptable target.
    try std.Io.Dir.cwd().createDirPath(fsIo(), target);

    const r = try runGeode(&.{ geode_binary, "restore", fx.backup_file, "--yes" }, &.{.{ "GEODE_DATA_DIR", target }}, fx.cwd);
    defer r.deinit();
    if (r.code != @as(?u8, 0)) r.dump("restore (GEODE_DATA_DIR)");
    try testing.expectEqual(@as(?u8, 0), r.code);
    try testing.expect(r.output(success_line));
    try fx.expectCwdEmpty();
    try expectRestoredDir(allocator, target);
}

test "SONNY-6280 CLI point-in-time restore picks the backup from metadata.json and writes it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var root = try test_scratch.ScratchDir.create("sonny6280-pitr");
    defer root.remove();
    const data = try join(allocator, root.path(), "data");
    defer allocator.free(data);
    const backups = try join(allocator, root.path(), "backups");
    defer allocator.free(backups);
    const cwd = try join(allocator, root.path(), "cwd");
    defer allocator.free(cwd);
    const target = try join(allocator, root.path(), "restored");
    defer allocator.free(target);
    try std.Io.Dir.cwd().createDirPath(fsIo(), data);
    try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);

    var meta: backup.BackupMetadata = undefined;
    {
        var s = try Session.open(allocator, data);
        defer s.close(allocator);
        try seed(&s);
        var mgr = try backup.BackupManager.init(allocator, backups, .{}, graph_store.getGlobalStore(allocator));
        defer mgr.deinit();
        meta = try mgr.createFullBackup();
    }
    const backup_file = try std.fmt.allocPrint(allocator, "{s}/full_{x}.backup", .{ backups, meta.backup_id });
    defer allocator.free(backup_file);

    // A target time before every backup selects nothing: refused.
    {
        const early = try std.fmt.allocPrint(allocator, "{d}", .{meta.timestamp - 60_000});
        defer allocator.free(early);
        const r = try runGeode(&.{ geode_binary, "restore", backup_file, "--target-time", early, "--data-dir", target, "--yes" }, &.{}, cwd);
        defer r.deinit();
        try expectRestoreFailed(r, 1, "error: BackupNotFound");
        try testing.expect(!pathExists(target));
    }

    // An unparsable target time is a usage error, never "restore the latest".
    {
        const r = try runGeode(&.{ geode_binary, "restore", backup_file, "--target-time", "yesterday", "--data-dir", target, "--yes" }, &.{}, cwd);
        defer r.deinit();
        try expectRestoreFailed(r, 2, "--target-time");
        try testing.expect(!pathExists(target));
    }

    const at = try std.fmt.allocPrint(allocator, "{d}", .{meta.timestamp + 1});
    defer allocator.free(at);
    const r = try runGeode(&.{ geode_binary, "restore", backup_file, "--target-time", at, "--data-dir", target, "--yes" }, &.{}, cwd);
    defer r.deinit();
    if (r.code != @as(?u8, 0)) r.dump("restore --target-time");
    try testing.expectEqual(@as(?u8, 0), r.code);
    try testing.expect(r.output(success_line));
    try testing.expectEqual(@as(usize, 0), try dirEntryCount(cwd));
    try expectRestoredDir(allocator, target);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try std.Io.Dir.cwd().openFile(fsIo(), path, .{});
    defer f.close(fsIo());
    const len: usize = @intCast((try f.stat(fsIo())).size);
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    const n = try f.readPositionalAll(fsIo(), buf, 0);
    if (n != len) return error.ShortRead;
    return buf;
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(fsIo(), path, .{});
    defer f.close(fsIo());
    try f.writePositionalAll(fsIo(), bytes, 0);
}

test "SONNY-6280 CLI restore of a corrupt, truncated or missing backup fails and writes nothing" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var fx = try Fixture.init(allocator, "sonny6280-bad", false);
    defer fx.deinit(allocator);
    const target = try fx.path(allocator, "restored");
    defer allocator.free(target);

    const good = try readFileAlloc(allocator, fx.backup_file);
    defer allocator.free(good);

    // One payload byte flipped: the CRC32 check fails.
    const flipped_path = try fx.path(allocator, "out/flipped.backup");
    defer allocator.free(flipped_path);
    {
        const bad = try allocator.dupe(u8, good);
        defer allocator.free(bad);
        bad[@sizeOf(backup.BackupHeader) + (bad.len - @sizeOf(backup.BackupHeader)) / 2] ^= 0xFF;
        try writeFile(flipped_path, bad);
    }
    // Cut to half its length: shorter than its declared payload.
    const truncated_path = try fx.path(allocator, "out/truncated.backup");
    defer allocator.free(truncated_path);
    try writeFile(truncated_path, good[0 .. good.len / 2]);
    const missing_path = try fx.path(allocator, "out/does-not-exist.backup");
    defer allocator.free(missing_path);

    const cases = [_]struct { path: []const u8, err: []const u8 }{
        .{ .path = flipped_path, .err = "error: BackupChecksumMismatch" },
        .{ .path = truncated_path, .err = "error: InvalidBackupFile" },
        .{ .path = missing_path, .err = "error: BackupFileNotFound" },
    };
    for (cases) |c| {
        const r = try runGeode(&.{ geode_binary, "restore", c.path, "--data-dir", target, "--yes" }, &.{}, fx.cwd);
        defer r.deinit();
        try expectRestoreFailed(r, 1, c.err);
        try fx.expectCwdEmpty();
        try expectDirNames(fx.root.path(), &.{ "data", "cwd", "out" });
    }
}

test "SONNY-6280 CLI restore refuses a non-empty, unwritable or missing target" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var fx = try Fixture.init(allocator, "sonny6280-target", false);
    defer fx.deinit(allocator);

    // Non-empty target: refused, its contents untouched, nothing merged in.
    {
        const target = try fx.path(allocator, "occupied");
        defer allocator.free(target);
        try std.Io.Dir.cwd().createDirPath(fsIo(), target);
        const keep = try join(allocator, target, "keep.txt");
        defer allocator.free(keep);
        try writeFile(keep, "operator data");

        const r = try runGeode(&.{ geode_binary, "restore", fx.backup_file, "--data-dir", target, "--yes" }, &.{}, fx.cwd);
        defer r.deinit();
        try expectRestoreFailed(r, 1, "not empty");
        try expectDirNames(target, &.{"keep.txt"});
        const kept = try readFileAlloc(allocator, keep);
        defer allocator.free(kept);
        try testing.expectEqualStrings("operator data", kept);
        try expectDirNames(fx.root.path(), &.{ "data", "cwd", "out", "occupied" });
    }

    // A target whose parent cannot be written: fails, nothing left behind.
    if (std.os.linux.geteuid() != 0) {
        const parent = try fx.path(allocator, "readonly");
        defer allocator.free(parent);
        try std.Io.Dir.cwd().createDirPath(fsIo(), parent);
        try std.Io.Dir.cwd().setFilePermissions(fsIo(), parent, std.Io.File.Permissions.fromMode(0o555), .{});
        defer std.Io.Dir.cwd().setFilePermissions(fsIo(), parent, std.Io.File.Permissions.fromMode(0o755), .{}) catch {};
        const target = try join(allocator, parent, "restored");
        defer allocator.free(target);

        const r = try runGeode(&.{ geode_binary, "restore", fx.backup_file, "--data-dir", target, "--yes" }, &.{}, fx.cwd);
        defer r.deinit();
        try expectRestoreFailed(r, 1, "error: ");
        try testing.expectEqual(@as(usize, 0), try dirEntryCount(parent));
    }

    // No target at all: a usage error, and nothing is written relative to
    // the working directory (the old code wrote to ./data/restore).
    {
        const r = try runGeode(&.{ geode_binary, "restore", fx.backup_file, "--yes" }, &.{}, fx.cwd);
        defer r.deinit();
        try expectRestoreFailed(r, 2, "--data-dir");
        try fx.expectCwdEmpty();
    }
}

test "SONNY-6280 CLI restore of a backup from a remote URI fails closed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var root = try test_scratch.ScratchDir.create("sonny6280-uri");
    defer root.remove();
    const target = try join(allocator, root.path(), "restored");
    defer allocator.free(target);

    for ([_][]const u8{ "s3://bucket/backup-1", "https://example.invalid/full.backup" }) |uri| {
        const r = try runGeode(&.{ geode_binary, "restore", "--source", uri, "--data-dir", target, "--yes", "--server", "127.0.0.1:1" }, &.{}, root.path());
        defer r.deinit();
        try expectRestoreFailed(r, 1, "not supported");
        try expectDirNames(root.path(), &.{});
    }
}

/// A hand-built backup whose archive holds one entry named `entry_name`.
fn writeArchiveBackup(allocator: std.mem.Allocator, path: []const u8, entry_name: []const u8) !void {
    var archive: std.ArrayList(u8) = .empty;
    defer archive.deinit(allocator);
    try archive.appendSlice(allocator, "GEODBAK1");
    try archive.appendSlice(allocator, &std.mem.toBytes(@as(u32, 1)));
    try archive.appendSlice(allocator, &std.mem.toBytes(@as(u32, 1)));
    const data = "escaped";
    try archive.appendSlice(allocator, &std.mem.toBytes(@as(u32, @intCast(entry_name.len))));
    try archive.appendSlice(allocator, entry_name);
    try archive.appendSlice(allocator, &std.mem.toBytes(@as(u64, data.len)));
    try archive.appendSlice(allocator, data);

    const header = backup.BackupHeader{
        .magic = backup.BACKUP_MAGIC,
        .version = backup.BACKUP_VERSION,
        .backup_type = .full,
        .timestamp = 1,
        .compression = .none,
        .encrypted = false,
        .payload_len = archive.items.len,
        .checksum = std.hash.crc.Crc32.hash(archive.items),
    };
    const f = try std.Io.Dir.cwd().createFile(fsIo(), path, .{});
    defer f.close(fsIo());
    try f.writePositionalAll(fsIo(), std.mem.asBytes(&header), 0);
    try f.writePositionalAll(fsIo(), archive.items, @sizeOf(backup.BackupHeader));
}

test "SONNY-6280 CLI restore rejects archive entries that would escape the target" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var root = try test_scratch.ScratchDir.create("sonny6280-traversal");
    defer root.remove();
    const work = try join(allocator, root.path(), "work");
    defer allocator.free(work);
    try std.Io.Dir.cwd().createDirPath(fsIo(), work);
    const target = try join(allocator, work, "restored");
    defer allocator.free(target);
    const backup_file = try join(allocator, root.path(), "evil.backup");
    defer allocator.free(backup_file);
    const escape_abs = try join(allocator, root.path(), "escaped-abs.txt");
    defer allocator.free(escape_abs);

    const names = [_][]const u8{ "../escaped.txt", "graphs/../../escaped.txt", escape_abs, "" };
    for (names) |name| {
        try writeArchiveBackup(allocator, backup_file, name);
        const r = try runGeode(&.{ geode_binary, "restore", backup_file, "--data-dir", target, "--yes" }, &.{}, work);
        defer r.deinit();
        try expectRestoreFailed(r, 1, "error: ");
        try expectDirNames(work, &.{});
        try expectDirNames(root.path(), &.{ "work", "evil.backup" });
    }
}

test "SONNY-6280 CLI restore of an encrypted backup needs the right key" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var root = try test_scratch.ScratchDir.create("sonny6280-enc");
    defer root.remove();
    const data = try join(allocator, root.path(), "data");
    defer allocator.free(data);
    const backups = try join(allocator, root.path(), "backups");
    defer allocator.free(backups);
    const cwd = try join(allocator, root.path(), "cwd");
    defer allocator.free(cwd);
    const target = try join(allocator, root.path(), "restored");
    defer allocator.free(target);
    try std.Io.Dir.cwd().createDirPath(fsIo(), data);
    try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);

    // The deployment this models runs with GEODE_TDE_KEY set throughout: the
    // store's pages and the backup payload are both keyed by it.
    try testing.expectEqual(@as(c_int, 0), setenv("GEODE_TDE_KEY", tde_key_a, 1));
    defer _ = unsetenv("GEODE_TDE_KEY");

    var meta: backup.BackupMetadata = undefined;
    {
        var s = try Session.open(allocator, data);
        defer s.close(allocator);
        try seed(&s);
        var mgr = try backup.BackupManager.init(allocator, backups, .{ .encryption = true }, graph_store.getGlobalStore(allocator));
        defer mgr.deinit();
        meta = try mgr.createFullBackup();
        try testing.expect(meta.encrypted);
    }
    const backup_file = try std.fmt.allocPrint(allocator, "{s}/full_{x}.backup", .{ backups, meta.backup_id });
    defer allocator.free(backup_file);

    {
        const r = try runGeode(&.{ geode_binary, "restore", backup_file, "--data-dir", target, "--yes" }, &.{.{ "GEODE_TDE_KEY", tde_key_b }}, cwd);
        defer r.deinit();
        try expectRestoreFailed(r, 1, "error: DecryptionFailed");
        try testing.expect(!r.output(tde_key_a));
        try testing.expect(!r.output(tde_key_b));
        try expectDirNames(root.path(), &.{ "data", "backups", "cwd" });
    }
    {
        const r = try runGeode(&.{ geode_binary, "restore", backup_file, "--data-dir", target, "--yes" }, &.{}, cwd);
        defer r.deinit();
        try expectRestoreFailed(r, 1, "error: MissingEncryptionKey");
        try expectDirNames(root.path(), &.{ "data", "backups", "cwd" });
    }

    const r = try runGeode(&.{ geode_binary, "restore", backup_file, "--data-dir", target, "--yes" }, &.{.{ "GEODE_TDE_KEY", tde_key_a }}, cwd);
    defer r.deinit();
    if (r.code != @as(?u8, 0)) r.dump("restore (encrypted, right key)");
    try testing.expectEqual(@as(?u8, 0), r.code);
    try testing.expect(r.output(success_line));
    try testing.expect(!r.output(tde_key_a));
    try testing.expectEqual(@as(usize, 0), try dirEntryCount(cwd));
    try expectRestoredDir(allocator, target);
}
