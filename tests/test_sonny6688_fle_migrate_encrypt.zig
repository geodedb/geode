// SONNY-6688: migrate the values a field held before it was configured as
// FLE-encrypted.
//
// `geode.fle.configureField` encrypts the values written after it; nothing
// encrypted the ones already stored (`geode fle migrate-encrypt` refused as
// unsupported after SONNY-6321: no build set the storage it migrated
// through). `CALL geode.fle.migrateEncrypt(type, field [, batch_size [,
// tenant [, graph]]])` and `geode fle migrate-encrypt` now write every
// plaintext value of the field back through the graph store, which seals it
// under the one FLE record identity:
//
//   (1) in process, through the executor: the values are encrypted at rest
//       afterwards (no file of the data directory holds them), readable in
//       plaintext by a role the field is visible to and "[REDACTED]" for any
//       other; edges too; a second run changes nothing; a run stopped after
//       a batch (as a crash would) is finished by running it again; records
//       of another tenant are left alone; a field not configured as
//       encrypted, a bad batch size, a foreign tenant and an explicit
//       transaction are refused; it is audited;
//   (2) a real `geode serve`: `geode fle migrate-encrypt` against it, then
//       the values read back through QUIC for the permitted role, and none
//       is in the data directory after the server stops.
//
// Real executor, real store, real binary. No mocks.
//
// CANARY: REQ=REQ-SONNY-6688-FLE-MIGRATE-ENCRYPT; FEATURE="FieldLevelEncryption"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6688_fle_migrate_encrypt.zig; OWNER=security; UPDATED=2026-11-16

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const fx = @import("sonny738_r12_grpc_fixture.zig");
const util = @import("proto_test_util.zig");

const execution = geode.execution;
const fle_integration = geode.fle_integration;
const fle_catalog = fle_integration.catalog_mod;
const proto_util = geode.proto_util;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const master_key = "6688a6688a6688a6688a6688a6688a6688a6688a6688a6688a6688a6688a6688";
const secrets = [_][]const u8{ "SSN-6688-SECRET-ONE", "SSN-6688-SECRET-TWO", "SSN-6688-SECRET-THREE" };
const edge_secret = "NOTE-6688-SECRET-EDGE";

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
            std.debug.print("'{s}' is in {s}\n", .{ needle, entry.path });
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

    /// `CALL geode.fle.migrateEncrypt(...)`: the (column, value) pairs of
    /// its one row.
    fn migrate(self: *Env, tenant: ?[]const u8, call: []const u8) !Counts {
        const res = self.exec("pii", tenant, call) catch |err| {
            std.debug.print("{s}: {s}\n", .{ call, @errorName(err) });
            return err;
        };
        if (res.rows.len != 1) return error.UnexpectedRows;
        var c: Counts = .{};
        for (res.columns, res.rows[0]) |name, v| {
            const n: i64 = switch (v) {
                .Int => |i| i,
                .Bool => |b| @intFromBool(b),
                else => continue,
            };
            if (std.mem.eql(u8, name, "encrypted")) c.encrypted = n;
            if (std.mem.eql(u8, name, "already_encrypted")) c.already = n;
            if (std.mem.eql(u8, name, "skipped_tenant")) c.skipped_tenant = n;
            if (std.mem.eql(u8, name, "batches")) c.batches = n;
            if (std.mem.eql(u8, name, "complete")) c.complete = n == 1;
        }
        return c;
    }

    fn encrypt(self: *Env, type_name: []const u8, field: []const u8) !void {
        _ = self;
        const catalog = try fle_catalog.globalCatalog(testing.allocator);
        var roles = [_][]const u8{"pii"};
        try catalog.configureField(type_name, .{ .field_name = field, .encryption = .{ .enabled = true }, .visibility = .{ .to_roles = &roles } });
        fle_integration.setHasEncryptedFields(true);
    }

    fn checkpoint(self: *Env) !void {
        _ = self;
        try geode.graph_store.getGlobalAdapter().?.checkpointAll();
    }

    fn anyOnDisk(self: *Env, needles: []const []const u8) !bool {
        try self.checkpoint();
        for (needles) |n| if (try dirContains(testing.allocator, self.f.h.data_dir, n)) return true;
        return false;
    }
};

/// The test hook the interruption case uses (`fle_migration`, SONNY-6688).
const has_migration = @hasDecl(geode, "fle_migration");

fn stopAfterBatches(n: u64) void {
    if (comptime has_migration) geode.fle_migration.stop_after_batches_for_testing.store(n, .release);
}

const Counts = struct { encrypted: i64 = -1, already: i64 = -1, skipped_tenant: i64 = -1, batches: i64 = -1, complete: bool = false };

/// Three people and a relationship whose secret fields were written in
/// plaintext, before the fields were configured as encrypted.
fn seedPlaintext(e: *Env) !void {
    try e.run("CREATE (:P6688 {k: 1, ssn: '" ++ secrets[0] ++ "'})-[:R6688 {note: '" ++ edge_secret ++ "'}]->(:P6688 {k: 2, ssn: '" ++ secrets[1] ++ "'})");
    try e.run("CREATE (:P6688 {k: 3, ssn: '" ++ secrets[2] ++ "'})");
}

const all_secrets = secrets ++ [_][]const u8{edge_secret};

test "SONNY-6688 (1): migrateEncrypt encrypts a field's existing plaintext at rest; the permitted role reads it, others read [REDACTED]; a second run changes nothing; audited" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try seedPlaintext(&e);
    try testing.expect(try e.anyOnDisk(&all_secrets));
    try e.encrypt("P6688", "ssn");
    try e.encrypt("R6688", "note");

    const first = e.migrate(null, "CALL geode.fle.migrateEncrypt('P6688', 'ssn', 2)") catch |err| {
        std.debug.print("SONNY-6688: migrateEncrypt failed: {s} (before the fix the procedure did not exist)\n", .{@errorName(err)});
        return err;
    };
    try testing.expectEqual(@as(i64, 3), first.encrypted);
    try testing.expectEqual(@as(i64, 0), first.already);
    try testing.expectEqual(@as(i64, 2), first.batches);
    try testing.expect(first.complete);
    const edges = try e.migrate(null, "CALL geode.fle.migrateEncrypt('R6688', 'note')");
    try testing.expectEqual(@as(i64, 1), edges.encrypted);

    if (try e.anyOnDisk(&all_secrets)) {
        std.debug.print("SONNY-6688: a migrated value is still on disk in plaintext\n", .{});
        return error.PlaintextAtRest;
    }
    // Read back as before for the permitted role; redacted for another.
    const plain = try e.strs("pii", "MATCH (n:P6688) RETURN n.ssn");
    try testing.expectEqual(@as(usize, 3), plain.len);
    for (plain, [_][]const u8{ secrets[0], secrets[2], secrets[1] }) |got, want| try testing.expectEqualStrings(want, got);
    for (try e.strs("other", "MATCH (n:P6688) RETURN n.ssn")) |got| try testing.expectEqualStrings("[REDACTED]", got);
    const note = try e.strs("pii", "MATCH ()-[r:R6688]->() RETURN r.note");
    try testing.expectEqualStrings(edge_secret, note[0]);

    // Idempotent.
    const again = try e.migrate(null, "CALL geode.fle.migrateEncrypt('P6688', 'ssn')");
    try testing.expectEqual(@as(i64, 0), again.encrypted);
    try testing.expectEqual(@as(i64, 3), again.already);
}

test "SONNY-6688 (1): a migration stopped after a batch, as a crash would stop it, is finished by running it again" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try seedPlaintext(&e);
    try e.encrypt("P6688", "ssn");
    if (!has_migration) {
        std.debug.print("SONNY-6688: there is no migration to stop (geode.fle_migration)\n", .{});
        return error.FleMigrationMissing;
    }
    stopAfterBatches(1);
    defer stopAfterBatches(0);
    const stopped = e.refused(null, "CALL geode.fle.migrateEncrypt('P6688', 'ssn', 1)");
    try testing.expectEqualStrings("MigrationInterrupted", @errorName(stopped));
    stopAfterBatches(0);
    // One value is sealed and on disk sealed; the others are not yet.
    const rest = try e.migrate(null, "CALL geode.fle.migrateEncrypt('P6688', 'ssn', 1)");
    try testing.expectEqual(@as(i64, 2), rest.encrypted);
    try testing.expectEqual(@as(i64, 1), rest.already);
    try testing.expect(!try e.anyOnDisk(&secrets));
    try testing.expectEqual(@as(usize, 3), (try e.strs("pii", "MATCH (n:P6688) RETURN n.ssn")).len);
}

test "SONNY-6688 (1): a crash between a value's removal and its encrypted write is repaired from the journal at the next start" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try seedPlaintext(&e);
    try e.encrypt("P6688", "ssn");
    if (!has_migration) return error.FleMigrationMissing;
    if (comptime has_migration) {
        geode.fle_migration.crash_between_remove_and_write_for_testing.store(true, .release);
        defer geode.fle_migration.crash_between_remove_and_write_for_testing.store(false, .release);
        const stopped = e.refused(null, "CALL geode.fle.migrateEncrypt('P6688', 'ssn', 10)");
        try testing.expectEqualStrings("MigrationInterrupted", @errorName(stopped));
        // One value is gone from the store; its envelope is in the journal.
        const journal = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ e.f.h.data_dir, geode.fle_migration.journal_file_name });
        defer testing.allocator.free(journal);
        std.Io.Dir.cwd().access(io(), journal, .{}) catch return error.NoJournal;
        try testing.expectEqual(@as(usize, 2), (try e.strs("pii", "MATCH (n:P6688) WHERE n.ssn IS NOT NULL RETURN n.ssn")).len);
        // What the server does at start.
        try testing.expectEqual(@as(usize, 3), try geode.fle_migration.recoverJournal(testing.allocator, e.f.st));
        try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io(), journal, .{}));
        const plain = try e.strs("pii", "MATCH (n:P6688) RETURN n.ssn");
        try testing.expectEqual(@as(usize, 3), plain.len);
        for (plain, [_][]const u8{ secrets[0], secrets[2], secrets[1] }) |got, want| try testing.expectEqualStrings(want, got);
        try testing.expect(!try e.anyOnDisk(&secrets));
        const again = try e.migrate(null, "CALL geode.fle.migrateEncrypt('P6688', 'ssn')");
        try testing.expectEqual(@as(i64, 0), again.encrypted);
        try testing.expectEqual(@as(i64, 3), again.already);
    }
}

test "SONNY-6688 (1): only the tenant's own records are migrated, and the arguments are checked" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try seedPlaintext(&e); // tenant "default"
    try e.encrypt("P6688", "ssn");

    // Another tenant's run (an unscoped session naming it) touches none of
    // default's records.
    const other = try e.migrate(null, "CALL geode.fle.migrateEncrypt('P6688', 'ssn', 10, 'acme6688')");
    try testing.expectEqual(@as(i64, 0), other.encrypted);
    try testing.expectEqual(@as(i64, 3), other.skipped_tenant);
    try testing.expect(try e.anyOnDisk(&secrets));
    // A session of tenant acme may not name another tenant.
    try expectSqlstate(e.refused("acme6688", "CALL geode.fle.migrateEncrypt('P6688', 'ssn', 10, 'default')"), "42501");

    try expectSqlstate(e.refused(null, "CALL geode.fle.migrateEncrypt('P6688', 'k')"), "22023");
    try expectSqlstate(e.refused(null, "CALL geode.fle.migrateEncrypt('P6688', 'ssn', 0)"), "22023");
    try expectSqlstate(e.refused(null, "CALL geode.fle.migrateEncrypt('P6688')"), "22023");
    try expectSqlstate(e.refused(null, "CALL geode.fle.migrateEncrypt('P6688', 'ssn', 10, null, '__geode_security')"), "42501");
    _ = try e.exec("pii", null, "START TRANSACTION");
    try expectSqlstate(e.refused(null, "CALL geode.fle.migrateEncrypt('P6688', 'ssn')"), "25000");
    _ = try e.exec("pii", null, "ROLLBACK");
    geode.txn_undo_log.setThreadTxnId(0); // as the transport does after a request

    // The default tenant's own run.
    const own = try e.migrate(null, "CALL geode.fle.migrateEncrypt('P6688', 'ssn', 10, 'default')");
    try testing.expectEqual(@as(i64, 3), own.encrypted);
    try testing.expect(!try e.anyOnDisk(&secrets));
}

// ---------------------------------------------------------------------------
// (2) a real server and the CLI
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

test "SONNY-6688 (2): geode fle migrate-encrypt against a real server encrypts the stored values; the permitted role reads them over QUIC, and none is on disk after the server stops" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var dir_buf: [64]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-6688-{d}", .{std.os.linux.getpid()});
    std.Io.Dir.cwd().deleteTree(io(), data_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io(), data_dir);
    defer std.Io.Dir.cwd().deleteTree(io(), data_dir) catch {};

    {
        var server = try Server.start(data_dir);
        var stopped = false;
        defer if (!stopped) server.stop();
        var a = try server.admin("admin");
        var a_open = true;
        defer if (a_open) a.deinit();
        try quicOk(&a, "CREATE (:Person6688 {k: 1, ssn: '" ++ secrets[0] ++ "'}), (:Person6688 {k: 2, ssn: '" ++ secrets[1] ++ "'})");
        try quicOk(&a, "CALL geode.fle.configureField('Person6688', 'ssn', { algorithm: 'AES-256-GCM', visibility: ['admin'] })");
        try quicOk(&a, "CALL geode.fle.grantRole('geode', 'admin')");

        {
            var threaded = std.Io.Threaded.init(testing.allocator, .{});
            defer threaded.deinit();
            // SONNY-6782: a release build refuses --insecure without GEODE_ALLOW_INSECURE_TLS=1.
            var env = try std.Io.Threaded.global_single_threaded.environ.process_environ.createMap(testing.allocator);
            defer env.deinit();
            try env.put("GEODE_ALLOW_INSECURE_TLS", "1");
            const res = try std.process.run(testing.allocator, threaded.io(), .{
                .environ_map = &env,
                .argv = &.{ geode_test_bin.geode_exe, "fle", "migrate-encrypt", "default", "Person6688", "ssn", "1", "--server", server.addr, "--insecure", "--user", util.defaultUsername(), "--password", util.defaultPassword() },
                .stdout_limit = .limited(1 << 20),
                .stderr_limit = .limited(1 << 20),
            });
            defer testing.allocator.free(res.stdout);
            defer testing.allocator.free(res.stderr);
            const ok = switch (res.term) {
                .exited => |c| c == 0,
                else => false,
            };
            if (!ok) {
                std.debug.print("SONNY-6688 (2): geode fle migrate-encrypt: {any}\nstdout: {s}\nstderr: {s}\n", .{ res.term, res.stdout, res.stderr });
                return error.CliFailed;
            }
        }
        const plain = try quicStrs(aa, &a, "MATCH (n:Person6688) RETURN n.ssn");
        try testing.expectEqual(@as(usize, 2), plain.len);
        try testing.expectEqualStrings(secrets[0], plain[0]);
        try testing.expectEqualStrings(secrets[1], plain[1]);
        {
            var o = try server.admin("other6688");
            defer o.deinit();
            for (try quicStrs(aa, &o, "MATCH (n:Person6688) RETURN n.ssn")) |got| try testing.expectEqualStrings("[REDACTED]", got);
        }
        a_open = false;
        a.deinit();
        stopped = true;
        try server.stopClean();
    }
    // The server stopped (and checkpointed): no file holds a migrated value.
    for (secrets[0..2]) |s| {
        if (try dirContains(testing.allocator, data_dir, s)) {
            std.debug.print("SONNY-6688 (2): '{s}' is in the data directory after the migration\n", .{s});
            return error.PlaintextAtRest;
        }
    }
    // A restarted server reads them back.
    var server = try Server.start(data_dir);
    defer server.stop();
    var a = try server.admin("admin");
    defer a.deinit();
    try testing.expectEqual(@as(usize, 2), (try quicStrs(aa, &a, "MATCH (n:Person6688) RETURN n.ssn")).len);
}
