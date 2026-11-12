// SONNY-6324 regression: the field-level-encryption (FLE) catalog fails
// closed.
//
// The FLE catalog records which (type, field) pairs are encrypted and which
// roles may read them in plaintext (src/schema/fle_catalog.zig). It failed
// open in three ways:
//
//   (1) configureField, grantPlaintextAccess and revokePlaintextAccess
//       logged a failed save ("CRITICAL") and reported success. The change
//       was lost at the next start: a field the operator was told is
//       encrypted was not encrypted after a restart, and a revoked reader got
//       plaintext access back. Now a failed save is an error (58030) and:
//         * configureField and a grant are rolled back in memory, so memory
//           matches disk and the operator is told nothing changed;
//         * a revoke stays applied in memory (fail closed: the reader loses
//           access now) and the error says it is not saved; the next change
//           of the catalog (a retried revoke included) saves it.
//       With no data directory the catalog is memory-only: nothing to save,
//       and the three succeed.
//   (2) A catalog file that could not be loaded (corrupt, truncated, wrong
//       GEODE_TDE_KEY, a symbolic link) gave an EMPTY catalog: fields
//       configured as encrypted were treated as unencrypted, so new writes
//       went to disk in plaintext. Now the load failure is an error, every
//       use of the catalog is refused until it is resolved, a string
//       property write (FLE encrypts strings only) is refused, and a read of
//       a string property is refused. An absent file is a fresh store: an
//       empty catalog, as before.
//   (3) SchemaCatalog leaked field names and role lists on deinit / reset,
//       configureField on an existing field leaked, loadCatalog leaked on
//       its error paths. Everything here runs under std.testing.allocator,
//       including allocation-failure sweeps.
//
// Real catalog load/save, the real `CALL geode.fle.*` dispatch, the real
// `geode fle revoke-plaintext` command function and the real executor; the
// save failures are real (a read-only data directory). No mocks.
//
// CANARY: REQ=REQ-SONNY-6324-FLE-CATALOG-FAIL-CLOSED; FEATURE="FieldLevelEncryption"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6324_fle_catalog_fail_closed.zig; OWNER=security; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const index_manager = geode.index_manager;
const fle_integration = geode.fle_integration;
const fle_catalog = fle_integration.catalog_mod;
const storage_dispatch = geode.storage_dispatch;
const fle_commands = geode.fle_commands;
const proto_util = geode.proto_util;
const tde = geode.tde_file_encryption;
const ast = geode.gql.ast;

const FieldMetadata = @typeInfo(@TypeOf(fle_catalog.SchemaCatalog.configureField)).@"fn".params[2].type.?;

const catalog_file_name = "geode_fle_catalog.dat";

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn setMode(path: []const u8, mode: c_uint) !void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    if (chmod(buf[0..path.len :0], mode) != 0) return error.ChmodFailed;
}

/// Saves and restores an environment variable.
const SavedEnv = struct {
    name: [:0]const u8,
    value: ?[:0]u8,

    fn take(name: [:0]const u8) !SavedEnv {
        const v: ?[:0]u8 = if (std.c.getenv(name.ptr)) |p| try testing.allocator.dupeZ(u8, std.mem.span(p)) else null;
        return .{ .name = name, .value = v };
    }

    fn restore(self: SavedEnv) void {
        if (self.value) |v| {
            _ = setenv(self.name.ptr, v.ptr, 1);
            testing.allocator.free(v);
        } else _ = unsetenv(self.name.ptr);
    }
};

/// A data directory for the FLE catalog (no GEODE_DATA_DIR, no TDE key: the
/// file is plaintext unless a test sets one), with the process-global
/// catalog reset. `restore` puts everything back.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,
    path: []u8,
    env_data_dir: SavedEnv,
    env_tde: SavedEnv,

    fn init() !Fixture {
        const env_data_dir = try SavedEnv.take("GEODE_DATA_DIR");
        errdefer env_data_dir.restore();
        const env_tde = try SavedEnv.take("GEODE_TDE_KEY");
        errdefer env_tde.restore();
        _ = unsetenv("GEODE_DATA_DIR");
        _ = unsetenv("GEODE_TDE_KEY");

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
        errdefer testing.allocator.free(dir);
        const path = try std.fs.path.join(testing.allocator, &.{ dir, catalog_file_name });
        errdefer testing.allocator.free(path);

        fle_catalog.setDataDirOverride(dir);
        resetGlobal();
        return .{ .tmp = tmp, .dir = dir, .path = path, .env_data_dir = env_data_dir, .env_tde = env_tde };
    }

    fn deinit(self: *Fixture) void {
        setMode(self.dir, 0o700) catch {};
        fle_catalog.setDataDirOverride(null);
        resetGlobal();
        testing.allocator.free(self.path);
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
        self.env_tde.restore();
        self.env_data_dir.restore();
    }

    /// Every save into the directory fails: the temporary file the save
    /// renames over the catalog cannot be created.
    fn makeReadOnly(self: *Fixture) !void {
        try setMode(self.dir, 0o500);
    }

    fn makeWritable(self: *Fixture) !void {
        try setMode(self.dir, 0o700);
    }

    fn writeFile(self: *Fixture, bytes: []const u8) !void {
        std.Io.Dir.cwd().deleteFile(io(), self.path) catch {};
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = self.path, .data = bytes });
    }

    fn readFile(self: *Fixture) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(io(), self.path, testing.allocator, .limited(1 << 20));
    }
};

fn resetGlobal() void {
    fle_catalog.resetGlobalCatalog(testing.allocator);
    fle_integration.setHasEncryptedFields(false);
}

/// A catalog loaded from disk the way a restarted process loads it.
fn restarted() !fle_catalog.SchemaCatalog {
    var catalog = fle_catalog.SchemaCatalog.init(testing.allocator);
    errdefer catalog.deinit();
    try fle_catalog.loadCatalog(&catalog);
    return catalog;
}

fn hasRole(catalog: *fle_catalog.SchemaCatalog, type_name: []const u8, field: []const u8, role: []const u8) bool {
    const meta = catalog.getFieldMetadata(type_name, field) orelse return false;
    for (meta.visibility.to_roles) |r| {
        if (std.mem.eql(u8, r, role)) return true;
    }
    return false;
}

fn encryptedField(name: []const u8) FieldMetadata {
    return .{ .field_name = name, .encryption = .{ .enabled = true } };
}

/// `CALL <proc>(args...)` through the real FLE procedure dispatch.
fn callFle(arena: std.mem.Allocator, normalized: []const u8, args_in: []const []const u8) !void {
    var exprs: [3]ast.Expr = undefined;
    var ptrs: [3]*ast.Expr = undefined;
    for (args_in, 0..) |a, i| {
        exprs[i] = .{ .String = a };
        ptrs[i] = &exprs[i];
    }
    var callee = ast.Expr{ .String = normalized };
    const proc_expr = ast.Expr{ .Call = .{ .callee = &callee, .args = ptrs[0..args_in.len] } };
    const call_stmt = ast.CallProcedure{ .procedure = proc_expr };
    const result = try storage_dispatch.executeFle(arena, normalized, call_stmt);
    try testing.expect(result != null);
}

fn configureViaCall(arena: std.mem.Allocator, type_name: []const u8, field: []const u8) !void {
    try callFle(arena, "geode.fle.configurefield", &.{ type_name, field });
}

fn grantViaCall(arena: std.mem.Allocator, type_name: []const u8, field: []const u8, role: []const u8) !void {
    try callFle(arena, "geode.fle.grantplaintext", &.{ type_name, field, role });
}

fn expectCode(err: anyerror, code: []const u8) !void {
    const info = proto_util.mapError(err);
    if (!std.mem.eql(u8, info.code, code)) {
        std.debug.print("{s} maps to {s} ({s}); expected {s}\n", .{ @errorName(err), info.code, info.message, code });
        return error.WrongSqlstate;
    }
}

fn skipIfRoot() !void {
    // Root writes through a read-only mode: nothing to test.
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// (1) a failed save is an error, and memory matches what the operator is told
// ---------------------------------------------------------------------------

test "SONNY-6324 (1): CALL geode.fle.configureField whose save fails is refused and leaves the field unconfigured, before and after a restart" {
    try skipIfRoot();
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try configureViaCall(aa, "Sonny6324T", "kept");
    const global = try fle_catalog.globalCatalog(testing.allocator);
    try testing.expect(global.isFieldEncrypted("Sonny6324T", "kept"));

    try f.makeReadOnly();
    // A new field of a known type, a field of a new type, and a change of a
    // configured field: each refused, none applied.
    const new_field = configureViaCall(aa, "Sonny6324T", "ssn");
    try testing.expectError(error.FleCatalogNotPersisted, new_field);
    try expectCode(error.FleCatalogNotPersisted, "58030");
    try testing.expect(!global.isFieldEncrypted("Sonny6324T", "ssn"));

    const new_type = configureViaCall(aa, "Sonny6324New", "card");
    try testing.expectError(error.FleCatalogNotPersisted, new_type);
    try testing.expect(global.getType("Sonny6324New") == null);
    try testing.expect(!global.isFieldEncrypted("Sonny6324New", "card"));

    try testing.expectError(error.FleCatalogNotPersisted, global.configureField("Sonny6324T", .{
        .field_name = "kept",
        .encryption = .{ .enabled = true, .algorithm = .chacha20_poly1305 },
    }));
    try testing.expect(global.getFieldMetadata("Sonny6324T", "kept").?.encryption.algorithm == .aes256_gcm);
    try f.makeWritable();

    var after = try restarted();
    defer after.deinit();
    try testing.expect(after.isFieldEncrypted("Sonny6324T", "kept"));
    try testing.expect(!after.isFieldEncrypted("Sonny6324T", "ssn"));
    try testing.expect(after.getType("Sonny6324New") == null);
    try testing.expect(after.getFieldMetadata("Sonny6324T", "kept").?.encryption.algorithm == .aes256_gcm);

    // Writable again, the same statement runs and is saved.
    try configureViaCall(aa, "Sonny6324T", "ssn");
    var later = try restarted();
    defer later.deinit();
    try testing.expect(later.isFieldEncrypted("Sonny6324T", "ssn"));
}

test "SONNY-6324 (1): CALL geode.fle.grantPlaintext whose save fails is refused and grants nothing, before and after a restart" {
    try skipIfRoot();
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try configureViaCall(aa, "Sonny6324G", "ssn");
    const global = try fle_catalog.globalCatalog(testing.allocator);

    try f.makeReadOnly();
    const granted = grantViaCall(aa, "Sonny6324G", "ssn", "analyst");
    try testing.expectError(error.FleCatalogNotPersisted, granted);
    try testing.expect(!hasRole(global, "Sonny6324G", "ssn", "analyst"));
    try f.makeWritable();

    var after = try restarted();
    defer after.deinit();
    try testing.expect(!hasRole(&after, "Sonny6324G", "ssn", "analyst"));

    try grantViaCall(aa, "Sonny6324G", "ssn", "analyst");
    try testing.expect(hasRole(global, "Sonny6324G", "ssn", "analyst"));
    var later = try restarted();
    defer later.deinit();
    try testing.expect(hasRole(&later, "Sonny6324G", "ssn", "analyst"));
}

test "SONNY-6324 (1): a revoke whose save fails is reported and stays applied in memory (fail closed); a retry saves it" {
    try skipIfRoot();
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try configureViaCall(aa, "Sonny6324R", "ssn");
    try grantViaCall(aa, "Sonny6324R", "ssn", "analyst");
    try grantViaCall(aa, "Sonny6324R", "ssn", "auditor");
    const global = try fle_catalog.globalCatalog(testing.allocator);

    try f.makeReadOnly();
    const revoked = fle_commands.revokePlaintext(testing.allocator, .{ .schema_name = "Sonny6324R", .field_name = "ssn", .role = "analyst" });
    try testing.expectError(error.FleRevokeNotPersisted, revoked);
    try expectCode(error.FleRevokeNotPersisted, "58030");
    // Fail closed: the reader has lost access in this process.
    try testing.expect(!hasRole(global, "Sonny6324R", "ssn", "analyst"));
    try testing.expect(hasRole(global, "Sonny6324R", "ssn", "auditor"));

    // What the operator was told: the revoke is not saved. A restart now
    // would find the role (the file was never written).
    {
        try f.makeWritable();
        var on_disk = try restarted();
        defer on_disk.deinit();
        try testing.expect(hasRole(&on_disk, "Sonny6324R", "ssn", "analyst"));
        try f.makeReadOnly();
    }

    // A retry while the directory is still read-only: still not saved, and
    // still reported, though memory already has no such role.
    try testing.expectError(error.FleRevokeNotPersisted, global.revokePlaintextAccess("Sonny6324R", "ssn", "analyst"));
    try f.makeWritable();

    // The retry, once the directory is writable, saves the revoke.
    try fle_commands.revokePlaintext(testing.allocator, .{ .schema_name = "Sonny6324R", .field_name = "ssn", .role = "analyst" });
    var after = try restarted();
    defer after.deinit();
    try testing.expect(!hasRole(&after, "Sonny6324R", "ssn", "analyst"));
    try testing.expect(hasRole(&after, "Sonny6324R", "ssn", "auditor"));
}

test "SONNY-6324 (1): a revoke that failed to save is saved by the next successful change of the catalog" {
    try skipIfRoot();
    var f = try Fixture.init();
    defer f.deinit();

    var catalog = try restarted();
    defer catalog.deinit();
    try catalog.configureField("Sonny6324N", encryptedField("ssn"));
    try catalog.grantPlaintextAccess("Sonny6324N", "ssn", "analyst");
    try catalog.grantPlaintextAccess("Sonny6324N", "ssn", "keeper");

    try f.makeReadOnly();
    try testing.expectError(error.FleRevokeNotPersisted, catalog.revokePlaintextAccess("Sonny6324N", "ssn", "analyst"));
    // A grant already in place changes nothing, but memory holds an unsaved
    // revoke: it tries to save it, and reports that it cannot.
    try testing.expectError(error.FleCatalogNotPersisted, catalog.grantPlaintextAccess("Sonny6324N", "ssn", "keeper"));
    try testing.expect(!hasRole(&catalog, "Sonny6324N", "ssn", "analyst"));
    try f.makeWritable();
    try catalog.grantPlaintextAccess("Sonny6324N", "ssn", "keeper");

    var after = try restarted();
    defer after.deinit();
    try testing.expect(!hasRole(&after, "Sonny6324N", "ssn", "analyst"));
    try testing.expect(hasRole(&after, "Sonny6324N", "ssn", "keeper"));
}

test "SONNY-6324 (1): a pending revoke rides on the next saved change" {
    try skipIfRoot();
    var f = try Fixture.init();
    defer f.deinit();

    var catalog = try restarted();
    defer catalog.deinit();
    try catalog.configureField("Sonny6324P", encryptedField("ssn"));
    try catalog.grantPlaintextAccess("Sonny6324P", "ssn", "analyst");

    try f.makeReadOnly();
    try testing.expectError(error.FleRevokeNotPersisted, catalog.revokePlaintextAccess("Sonny6324P", "ssn", "analyst"));
    try f.makeWritable();
    try catalog.configureField("Sonny6324P", encryptedField("dob"));

    var after = try restarted();
    defer after.deinit();
    try testing.expect(!hasRole(&after, "Sonny6324P", "ssn", "analyst"));
    try testing.expect(after.isFieldEncrypted("Sonny6324P", "dob"));
}

test "SONNY-6324 (1): with no data directory the catalog is memory-only and the three changes succeed" {
    const env_data_dir = try SavedEnv.take("GEODE_DATA_DIR");
    defer env_data_dir.restore();
    _ = unsetenv("GEODE_DATA_DIR");
    fle_catalog.setDataDirOverride(null);
    try testing.expect(!fle_catalog.isPersisted());

    var catalog = fle_catalog.SchemaCatalog.init(testing.allocator);
    defer catalog.deinit();
    try catalog.configureField("Sonny6324M", encryptedField("ssn"));
    try catalog.grantPlaintextAccess("Sonny6324M", "ssn", "analyst");
    try testing.expect(hasRole(&catalog, "Sonny6324M", "ssn", "analyst"));
    try catalog.revokePlaintextAccess("Sonny6324M", "ssn", "analyst");
    try testing.expect(!hasRole(&catalog, "Sonny6324M", "ssn", "analyst"));
}

// ---------------------------------------------------------------------------
// (2) a catalog that cannot be loaded is never an empty catalog
// ---------------------------------------------------------------------------

/// The serialized catalog of one type with an encrypted field (plaintext:
/// no TDE key set), written by the real save path.
fn validCatalogBytes(f: *Fixture) ![]u8 {
    var catalog = fle_catalog.SchemaCatalog.init(testing.allocator);
    defer catalog.deinit();
    try catalog.configureField("Sonny6324L", encryptedField("ssn"));
    try catalog.grantPlaintextAccess("Sonny6324L", "ssn", "analyst");
    return f.readFile();
}

/// The global catalog (the server's, loaded on first use) cannot load the
/// file: an error, every time, and no empty catalog in its place.
fn expectGlobalUnavailable() !void {
    resetGlobal();
    const first = fle_catalog.globalCatalog(testing.allocator);
    if (first) |c| {
        std.debug.print("a catalog that could not be loaded gave a catalog of {d} type(s)\n", .{c.count()});
        return error.LoadFailureGaveACatalog;
    } else |err| try testing.expectEqual(error.FleCatalogUnavailable, err);
    try testing.expectError(error.FleCatalogUnavailable, fle_catalog.globalCatalog(testing.allocator));
    try expectCode(error.FleCatalogUnavailable, "58030");
    // Fail closed: the engine cannot tell which fields are encrypted, so it
    // treats every string field as one that must be.
    try testing.expect(fle_integration.hasEncryptedFields());
    try testing.expect(fle_integration.fieldRequiresEncryption("Sonny6324L", "ssn"));
    try testing.expect(fle_integration.fieldRequiresEncryption("AnyLabel", "any_field"));
}

test "SONNY-6324 (2): an absent catalog file is a fresh store: an empty catalog" {
    var f = try Fixture.init();
    defer f.deinit();
    const global = try fle_catalog.globalCatalog(testing.allocator);
    try testing.expectEqual(@as(usize, 0), global.count());
    var fresh = try restarted();
    defer fresh.deinit();
    try testing.expectEqual(@as(usize, 0), fresh.count());
}

test "SONNY-6324 (2): corrupt and truncated catalog files are load errors, never an empty catalog" {
    var f = try Fixture.init();
    defer f.deinit();
    const good = try validCatalogBytes(&f);
    defer testing.allocator.free(good);

    // Garbage.
    try f.writeFile("this is not an FLE catalog at all, it is just some bytes");
    try expectGlobalUnavailable();

    // Every truncation of a valid file: an error, and the catalog it was
    // loading into is left empty and leak-free.
    var len: usize = 0;
    while (len < good.len) : (len += 1) {
        try f.writeFile(good[0..len]);
        var catalog = fle_catalog.SchemaCatalog.init(testing.allocator);
        defer catalog.deinit();
        if (fle_catalog.loadCatalog(&catalog)) |_| {
            std.debug.print("a catalog truncated to {d} of {d} bytes loaded\n", .{ len, good.len });
            return error.TruncatedCatalogLoaded;
        } else |_| {}
        try testing.expectEqual(@as(usize, 0), catalog.count());
    }
    try f.writeFile(good[0 .. good.len / 2]);
    try expectGlobalUnavailable();

    // The whole file loads.
    try f.writeFile(good);
    resetGlobal();
    const global = try fle_catalog.globalCatalog(testing.allocator);
    try testing.expect(global.isFieldEncrypted("Sonny6324L", "ssn"));
    try testing.expect(hasRole(global, "Sonny6324L", "ssn", "analyst"));
}

test "SONNY-6324 (2): a catalog encrypted with another GEODE_TDE_KEY, or with none set, is a load error" {
    var f = try Fixture.init();
    defer f.deinit();
    const good = try validCatalogBytes(&f);
    defer testing.allocator.free(good);

    const key_a = [_]u8{0x11} ** 32;
    const sealed = try tde.encryptWithKey(testing.allocator, good, key_a);
    defer testing.allocator.free(sealed);
    try f.writeFile(sealed);

    // Another key.
    _ = setenv("GEODE_TDE_KEY", "2222222222222222222222222222222222222222222222222222222222222222", 1);
    try expectGlobalUnavailable();
    // No key.
    _ = unsetenv("GEODE_TDE_KEY");
    try expectGlobalUnavailable();
    // The right key.
    _ = setenv("GEODE_TDE_KEY", "1111111111111111111111111111111111111111111111111111111111111111", 1);
    resetGlobal();
    const global = try fle_catalog.globalCatalog(testing.allocator);
    try testing.expect(global.isFieldEncrypted("Sonny6324L", "ssn"));
    _ = unsetenv("GEODE_TDE_KEY");
}

test "SONNY-6324 (2): a symbolic link at the catalog path is a load error, never an empty catalog" {
    var f = try Fixture.init();
    defer f.deinit();
    const good = try validCatalogBytes(&f);
    defer testing.allocator.free(good);

    const victim = try std.fs.path.join(testing.allocator, &.{ f.dir, "victim.dat" });
    defer testing.allocator.free(victim);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = victim, .data = good });
    std.Io.Dir.cwd().deleteFile(io(), f.path) catch {};
    try std.Io.Dir.cwd().symLink(io(), victim, f.path, .{});
    try expectGlobalUnavailable();
}

/// The executor harness of tests/test_sonny6270_drop_constraint.zig, in
/// memory (the FLE catalog's own data directory is set apart).
const Exec = struct {
    arena: std.heap.ArenaAllocator,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    fn init() !Exec {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        _ = graph_store.getGlobalStore(testing.allocator);
        const catalog = try execution.ensureCatalogInstance(testing.allocator);
        return .{
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .session = execution.SessionState.init(testing.allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    fn deinit(self: *Exec) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        self.arena.deinit();
    }

    fn exec(self: *Exec, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn run(self: *Exec, query: []const u8) !void {
        _ = self.exec(query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
    }

    fn refused(self: *Exec, query: []const u8) anyerror {
        if (self.exec(query)) |res| {
            std.debug.print("{s}: ran ({d} rows); expected a refusal\n", .{ query, res.rows.len });
            return error.ExpectedRefusal;
        } else |err| return err;
    }
};

test "SONNY-6324 (2): while the catalog cannot be loaded, string property writes and reads are refused; other writes run" {
    var f = try Fixture.init();
    defer f.deinit();

    // Data written while no FLE catalog is in use (memory-only).
    fle_catalog.setDataDirOverride(null);
    resetGlobal();
    var e = try Exec.init();
    defer e.deinit();
    try e.run("CREATE (:Sonny6324W {name: 'before', n: 1})");

    // Now the catalog file is corrupt.
    fle_catalog.setDataDirOverride(f.dir);
    try f.writeFile("corrupt FLE catalog bytes, cannot be parsed in any way");
    resetGlobal();

    const write_err = e.refused("CREATE (:Sonny6324W {name: 'plaintext?'})");
    if (write_err != error.EncryptionRequired and write_err != error.FleCatalogUnavailable) {
        std.debug.print("string write refused with {s}\n", .{@errorName(write_err)});
        return error.WrongRefusal;
    }
    try expectCode(write_err, "58030");
    const set_err = e.refused("MATCH (n:Sonny6324W) SET n.name = 'plaintext?'");
    if (set_err != error.EncryptionRequired and set_err != error.FleCatalogUnavailable) {
        std.debug.print("string SET refused with {s}\n", .{@errorName(set_err)});
        return error.WrongRefusal;
    }
    const read_err = e.refused("MATCH (n:Sonny6324W) RETURN n.name AS name");
    try testing.expectEqual(error.FleCatalogUnavailable, read_err);

    // FLE encrypts strings only: an integer write runs.
    try e.run("CREATE (:Sonny6324W {n: 2})");

    // Resolved (file removed: a fresh store), everything runs again.
    std.Io.Dir.cwd().deleteFile(io(), f.path) catch {};
    resetGlobal();
    try e.run("CREATE (:Sonny6324W {name: 'after'})");
    _ = try e.exec("MATCH (n:Sonny6324W) RETURN n.name AS name");
}

// ---------------------------------------------------------------------------
// (3) no leaks, error paths included
// ---------------------------------------------------------------------------

fn changeSequence(allocator: std.mem.Allocator) !void {
    var catalog = fle_catalog.SchemaCatalog.init(allocator);
    defer catalog.deinit();
    var roles_a = [_][]const u8{ "r1", "r2" };
    var roles_b = [_][]const u8{"r3"};
    try catalog.configureField("Sonny6324X", .{ .field_name = "ssn", .encryption = .{ .enabled = true }, .visibility = .{ .to_roles = &roles_a } });
    // Reconfigure the same field: the old name copy and roles are freed.
    try catalog.configureField("Sonny6324X", .{ .field_name = "ssn", .encryption = .{ .enabled = true }, .visibility = .{ .to_roles = &roles_b } });
    try catalog.configureField("Sonny6324X", encryptedField("dob"));
    try catalog.configureField("Sonny6324Y", encryptedField("card"));
    try catalog.grantPlaintextAccess("Sonny6324X", "ssn", "r4");
    try catalog.grantPlaintextAccess("Sonny6324X", "ssn", "r4");
    try catalog.revokePlaintextAccess("Sonny6324X", "ssn", "r3");
    try catalog.revokePlaintextAccess("Sonny6324X", "ssn", "r4");
    try catalog.grantPlaintextAccess("Sonny6324X", "dob", "r5");
    catalog.reset();
    try catalog.configureField("Sonny6324Z", .{ .field_name = "ssn", .encryption = .{ .enabled = true }, .visibility = .{ .to_roles = &roles_a } });
}

test "SONNY-6324 (3): configure, reconfigure, grant, revoke, reset and deinit free everything, under every allocation failure" {
    const env_data_dir = try SavedEnv.take("GEODE_DATA_DIR");
    defer env_data_dir.restore();
    _ = unsetenv("GEODE_DATA_DIR");
    fle_catalog.setDataDirOverride(null);

    try changeSequence(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, changeSequence, .{});
}

fn loadOnce(allocator: std.mem.Allocator) !void {
    var catalog = fle_catalog.SchemaCatalog.init(allocator);
    defer catalog.deinit();
    try fle_catalog.loadCatalog(&catalog);
    if (!catalog.isFieldEncrypted("Sonny6324L", "ssn")) return error.NotLoaded;
    // The loaded type's name is the catalog's own copy, readable.
    const tm = catalog.getType("Sonny6324L") orelse return error.NotLoaded;
    if (!std.mem.eql(u8, tm.type_name, "Sonny6324L")) return error.TypeNameDangling;
}

test "SONNY-6324 (3): loadCatalog and a save free everything, under every allocation failure" {
    var f = try Fixture.init();
    defer f.deinit();
    const good = try validCatalogBytes(&f);
    defer testing.allocator.free(good);

    try loadOnce(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, loadOnce, .{});
}

test "SONNY-6324 (2)+(3): an out-of-range enum byte is a load error, not a crash" {
    var f = try Fixture.init();
    defer f.deinit();
    const good = try validCatalogBytes(&f);
    defer testing.allocator.free(good);

    // Layout: type count, name len, name, field count, field name len, field
    // name, then the encryption flag and the algorithm byte.
    const alg_at = 4 + 4 + "Sonny6324L".len + 4 + 4 + "ssn".len + 1;
    const bad = try testing.allocator.dupe(u8, good);
    defer testing.allocator.free(bad);
    try testing.expectEqual(@as(u8, 1), bad[alg_at - 1]);
    bad[alg_at] = 0xEE;
    try f.writeFile(bad);

    var catalog = fle_catalog.SchemaCatalog.init(testing.allocator);
    defer catalog.deinit();
    try testing.expectError(error.CorruptedCatalog, fle_catalog.loadCatalog(&catalog));
    try testing.expectEqual(@as(usize, 0), catalog.count());
    try expectGlobalUnavailable();
}
