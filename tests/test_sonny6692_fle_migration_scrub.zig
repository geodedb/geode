// SONNY-6692: after `geode.fle.migrateEncrypt` completes, no plaintext of
// the migrated field remains anywhere in the data directory.
//
// SONNY-6688 removed each plaintext value (its record's property blob
// rewritten in place, freed bytes zeroed) and wrote it sealed, but three
// kinds of remnant stayed:
//   (1) props.store pages and the WAL kept the old bytes until the next
//       checkpoint (the procedure runs under the request's graph lock, which
//       a checkpoint takes, so it did not checkpoint);
//   (2) a value larger than a property page spills to the var store, and the
//       spill pages it freed (by the migration, or by an update before it)
//       kept their bytes until reused;
//   (3) an update before the migration that relocated the record's property
//       blob left the old blob, with the old value, in a tombstoned slab
//       slot nothing reaches.
// The whole data directory is read back right after the procedure returns:
// no small or large value, current or superseded, is in any file. In
// process (the procedure takes the graph's write lock for the scrub) and
// against a real `geode serve` through `geode fle migrate-encrypt` (it runs
// under the request's write lock, held as it is), with the server running.
//
// Real executor, real persisted store. No mocks.
//
// CANARY: REQ=REQ-SONNY-6692-FLE-MIGRATION-SCRUB; FEATURE="FieldLevelEncryption"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6692_fle_migration_scrub.zig; OWNER=security; UPDATED=2026-11-17

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const execution = geode.execution;
const fle_integration = geode.fle_integration;
const fle_catalog = fle_integration.catalog_mod;
const proto_util = geode.proto_util;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const master_key = "6692a6692a6692a6692a6692a6692a6692a6692a6692a6692a6692a6692a6692";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn expectSqlstate(err: anyerror, code: []const u8) !void {
    const info = proto_util.mapError(err);
    if (!std.mem.eql(u8, info.code, code)) {
        std.debug.print("{s} maps to {s}; expected {s}\n", .{ @errorName(err), info.code, code });
        return error.WrongSqlstate;
    }
}

/// Does any file under `dir_path` contain `needle`?
fn dirContains(allocator: std.mem.Allocator, dir_path: []const u8, needle: []const u8) !bool {
    var dir = try std.Io.Dir.cwd().openDir(io(), dir_path, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file) continue;
        const data = dir.readFileAlloc(io(), entry.path, allocator, .limited(1 << 30)) catch continue;
        defer allocator.free(data);
        if (std.mem.indexOf(u8, data, needle) != null) {
            std.debug.print("SONNY-6692: '{s}' is in {s}\n", .{ needle, entry.path });
            return true;
        }
    }
    return false;
}

/// The persisted in-process store, authentication off (the FLE role list
/// decides), an FLE master key.
const Env = struct {
    f: fx.Fixture,
    session: execution.SessionState,
    arena: std.heap.ArenaAllocator,

    fn init(self: *Env) !void {
        try self.f.init();
        errdefer self.f.deinit();
        _ = setenv("GEODE_MASTER_KEY", master_key, 1);
        fle_integration.resetGlobalKeyStateForTesting();
        fle_catalog.resetGlobalCatalog(testing.allocator);
        fle_integration.setHasEncryptedFields(false);
        self.session = execution.SessionState.init(testing.allocator);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
    }

    fn deinit(self: *Env) void {
        fle_integration.clearCurrentThreadState();
        self.arena.deinit();
        self.session.deinit();
        fle_catalog.resetGlobalCatalog(testing.allocator);
        fle_integration.setHasEncryptedFields(false);
        fle_integration.resetGlobalKeyStateForTesting();
        _ = unsetenv("GEODE_MASTER_KEY");
        self.f.deinit();
    }

    fn exec(self: *Env, fle_role: ?[]const u8, tenant: ?[]const u8, query: []const u8) !execution.ExecutionResult {
        const catalog = try execution.ensureCatalogInstance(testing.allocator);
        const ctx = execution.ExecutionContext{
            .catalog = catalog,
            .session_state = &self.session,
            .fle_role = fle_role,
            .tenant_id = tenant,
        };
        var parsed = try geode.parseGqlOptions(query, self.arena.allocator(), .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.arena.allocator(), parsed.program.statements[0], ctx);
    }

    fn run(self: *Env, query: []const u8) !void {
        _ = self.exec("pii", null, query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
    }

    fn refused(self: *Env, tenant: ?[]const u8, query: []const u8) anyerror {
        if (self.exec("pii", tenant, query)) |_| {
            std.debug.print("{s}: ran; expected a refusal\n", .{query});
            return error.ExpectedRefusal;
        } else |err| return err;
    }

    /// The first column of every row, as strings, sorted.
    fn strs(self: *Env, fle_role: ?[]const u8, query: []const u8) ![]const []const u8 {
        const res = self.exec(fle_role, null, query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
        const out = try self.arena.allocator().alloc([]const u8, res.rows.len);
        for (res.rows, 0..) |row, i| out[i] = switch (row[0]) {
            .Str => |s| s,
            else => return error.UnexpectedValue,
        };
        std.mem.sort([]const u8, out, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        return out;
    }

    fn encrypt(self: *Env, type_name: []const u8, field: []const u8) !void {
        _ = self;
        const catalog = try fle_catalog.globalCatalog(testing.allocator);
        var roles = [_][]const u8{"pii"};
        try catalog.configureField(type_name, .{ .field_name = field, .encryption = .{ .enabled = true }, .visibility = .{ .to_roles = &roles } });
        fle_integration.setHasEncryptedFields(true);
    }
};

/// A value larger than any property page (it spills to the var store).
fn big(comptime marker: []const u8) []const u8 {
    return marker ++ ("v" ** 20000);
}

const small_before = "SSN-6692-SMALL-BEFORE-UPDATE";
const small_after = "SSN-6692-SMALL-AFTER-UPDATE-LONGER-VALUE";
const big_before_marker = "SSN-6692-BIG-BEFORE-UPDATE";
const big_after_marker = "SSN-6692-BIG-AFTER-UPDATE";
const all_markers = [_][]const u8{ small_before, small_after, big_before_marker, big_after_marker };

test "SONNY-6692: after migrateEncrypt returns, no plaintext of the field is in any file of the data directory (large spilled values, values superseded by an update before the migration)" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();

    // Written in plaintext, then updated, before the field is encrypted.
    try e.run("CREATE (:P6692 {k: 1, ssn: '" ++ small_before ++ "'})");
    try e.run("MATCH (n:P6692 {k: 1}) SET n.ssn = '" ++ small_after ++ "', n.note = 'grown'");
    try e.run("CREATE (:P6692 {k: 2, ssn: '" ++ comptime big(big_before_marker) ++ "'})");
    try e.run("MATCH (n:P6692 {k: 2}) SET n.ssn = '" ++ comptime big(big_after_marker) ++ "'");
    // On disk before the migration (the precondition the test relies on).
    try geode.graph_store.getGlobalAdapter().?.checkpointAll();
    var before: usize = 0;
    for (all_markers) |m| {
        if (try dirContains(testing.allocator, e.f.h.data_dir, m)) before += 1;
    }
    try testing.expect(before > 0);

    try e.encrypt("P6692", "ssn");
    _ = e.exec("pii", null, "CALL geode.fle.migrateEncrypt('P6692', 'ssn', 1)") catch |err| {
        std.debug.print("SONNY-6692: migrateEncrypt failed: {s}\n", .{@errorName(err)});
        return err;
    };

    // Right after the procedure returned: nothing of the field in clear.
    var found: usize = 0;
    for (all_markers) |m| {
        if (try dirContains(testing.allocator, e.f.h.data_dir, m)) found += 1;
    }
    if (found != 0) {
        std.debug.print("SONNY-6692: {d} of {d} plaintext values of the migrated field are still in the data directory\n", .{ found, all_markers.len });
        return error.PlaintextRemains;
    }

    // And the values still read for the permitted role.
    const small = try e.strs("pii", "MATCH (n:P6692 {k: 1}) RETURN n.ssn");
    try testing.expectEqualStrings(small_after, small[0]);
    const large = try e.strs("pii", "MATCH (n:P6692 {k: 2}) RETURN n.ssn");
    try testing.expectEqualStrings(comptime big(big_after_marker), large[0]);
}

// ---------------------------------------------------------------------------
// A real server, through the CLI
// ---------------------------------------------------------------------------

fn quicOk(client: *util.QuicProtoClient, query: []const u8) !void {
    var r = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 100);
    defer r.deinit(testing.allocator);
    if (r.error_code) |c| {
        std.debug.print("{s}: {s} {?s}\n", .{ query, c, r.error_message });
        return error.UnexpectedStatus;
    }
}

/// The first column of every row as strings, sorted (the caller frees with
/// the arena).
fn quicStrs(aa: std.mem.Allocator, client: *util.QuicProtoClient, query: []const u8) ![]const []const u8 {
    var r = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 100);
    defer r.deinit(testing.allocator);
    if (r.error_code) |c| {
        std.debug.print("{s}: {s} {?s}\n", .{ query, c, r.error_message });
        return error.UnexpectedStatus;
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (r.rows) |row| try out.append(aa, switch (row[0]) {
        .string => |s| try aa.dupe(u8, s),
        else => "",
    });
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.items;
}

const Server = struct {
    handle: util.ServerHandle,
    addr: []u8,

    fn start(data_dir: []const u8) !Server {
        const allocator = testing.allocator;
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var handle = try util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, &.{"GEODE_MASTER_KEY=" ++ master_key});
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .handle = handle, .addr = addr };
    }

    fn stop(self: *Server) void {
        self.handle.deinit();
        testing.allocator.free(self.addr);
    }

    /// SIGTERM: the server's own shutdown, whose checkpoint writes the
    /// pages and truncates the WAL.
    fn stopClean(self: *Server) !void {
        const outcome = self.handle.stopGracefully(60_000);
        testing.allocator.free(self.addr);
        if (outcome != .exited) return error.ServerDidNotStopCleanly;
    }

    fn admin(self: *Server, fle_role: []const u8) !util.QuicProtoClient {
        var c = try util.QuicProtoClient.connect(testing.allocator, self.addr);
        errdefer c.deinit();
        var h = try c.helloAs(testing.allocator, util.defaultUsername(), util.defaultPassword(), fle_role);
        defer h.deinit(testing.allocator);
        if (!h.success) return error.HelloRefused;
        return c;
    }
};

test "SONNY-6692: geode fle migrate-encrypt against a running server leaves no plaintext of the field in the data directory when it returns" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var dir_buf: [64]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-6692-{d}", .{std.os.linux.getpid()});
    std.Io.Dir.cwd().deleteTree(io(), data_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io(), data_dir);
    defer std.Io.Dir.cwd().deleteTree(io(), data_dir) catch {};

    var server = try Server.start(data_dir);
    defer server.stop();
    var a = try server.admin("admin");
    defer a.deinit();
    try quicOk(&a, "CREATE (:S6692 {k: 1, ssn: '" ++ small_before ++ "'})");
    try quicOk(&a, "MATCH (n:S6692 {k: 1}) SET n.ssn = '" ++ small_after ++ "', n.note = 'grown'");
    try quicOk(&a, "CREATE (:S6692 {k: 2, ssn: '" ++ comptime big(big_before_marker) ++ "'})");
    try quicOk(&a, "MATCH (n:S6692 {k: 2}) SET n.ssn = '" ++ comptime big(big_after_marker) ++ "'");
    try quicOk(&a, "CALL geode.fle.configureField('S6692', 'ssn', { algorithm: 'AES-256-GCM', visibility: ['admin'] })");
    try quicOk(&a, "CALL geode.fle.grantRole('geode', 'admin')");

    {
        var threaded = std.Io.Threaded.init(testing.allocator, .{});
        defer threaded.deinit();
        const res = try std.process.run(testing.allocator, threaded.io(), .{
            .argv = &.{ geode_test_bin.geode_exe, "fle", "migrate-encrypt", "default", "S6692", "ssn", "1", "--server", server.addr, "--insecure-tls-skip-verify", "--user", util.defaultUsername(), "--password", util.defaultPassword() },
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(1 << 20),
        });
        defer testing.allocator.free(res.stdout);
        defer testing.allocator.free(res.stderr);
        const ok = switch (res.term) {
            .exited => |c| c == 0,
            else => false,
        };
        if (!ok or std.mem.indexOf(u8, res.stdout, "true") == null) {
            std.debug.print("SONNY-6692: geode fle migrate-encrypt: {any}\nstdout: {s}\nstderr: {s}\n", .{ res.term, res.stdout, res.stderr });
            return error.CliFailed;
        }
    }
    // The server is still running: the procedure itself left nothing.
    var found: usize = 0;
    for (all_markers) |m| {
        if (try dirContains(testing.allocator, data_dir, m)) found += 1;
    }
    if (found != 0) {
        std.debug.print("SONNY-6692: {d} plaintext values of the migrated field are in the running server's data directory\n", .{found});
        return error.PlaintextRemains;
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const vals = try quicStrs(arena.allocator(), &a, "MATCH (n:S6692) RETURN n.ssn");
    try testing.expectEqual(@as(usize, 2), vals.len);
}
