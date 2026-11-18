// SONNY-6321 (last part): the FLE admin commands (REQ-FLE-ADMIN-001,
// src/admin/fle_commands.zig) and `geode fle migrate-encrypt`
// (REQ-FLE-MIGRATE-CLI-001, src/cli/fle_cli.zig) had no test that executes
// them, so their markers were IMPL.
//
//   (1) `fle_commands.migrateEncrypt` and `geode fle migrate-encrypt`
//       reported a finished migration ("Migration Complete", "Records
//       migrated: 0", exit 0) without reading or encrypting a value: no
//       build sets the storage it migrates through (`setStorageCallback`),
//       so an operator was told the field's existing plaintext was
//       encrypted while it stayed plaintext on disk. In process
//       `migrateEncrypt` now refuses (error.Unsupported) once the schema and
//       field are validated; the CLI sends the migration to the server
//       (SONNY-6688, tests/test_sonny6688_fle_migrate_encrypt.zig) and,
//       with no server to reach, fails without claiming a migration.
//   (2) The admin command dispatcher (`fle_commands.executeCommand`):
//       grant-plaintext and revoke-plaintext change the persisted FLE
//       catalog (seen by a catalog loaded from disk, as a restarted server
//       loads it), show-policy and show-rotation report it, unknown
//       schemas, fields, commands and short argument lists are errors, and
//       rotate-key and migrate-encrypt are refused as unsupported.
//   (3) The `geode fle` binary: grant-plaintext writes the server's catalog
//       in GEODE_DATA_DIR (and is refused without one), show-policy prints
//       the field and the granted role.
//
// Real catalog load/save, the real command functions, the real geode
// binary. No mocks.
//
// CANARY: REQ=REQ-SONNY-6321-FLE-ADMIN-CLI; FEATURE="FieldLevelEncryption"; ASPECT=AdminCommandsAndMigrateRefusal; STATUS=TESTED; TEST=tests/test_sonny6321_fle_admin_cli.zig; OWNER=security; UPDATED=2026-11-16

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const fle_integration = geode.fle_integration;
const fle_catalog = fle_integration.catalog_mod;
const fle_commands = geode.fle_commands;
const geode_binary = geode_test_bin.geode_exe;

const FieldMetadata = @typeInfo(@TypeOf(fle_catalog.SchemaCatalog.configureField)).@"fn".params[2].type.?;

const master_key = "sonny6321-fle-master-key-0123456789abcdef";

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

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

/// A data directory holding an FLE catalog in which `type_name`.ssn is
/// encrypted (no TDE key: the catalog file is plaintext), with the
/// process-global catalog reset and GEODE_MASTER_KEY set.
const Fixture = struct {
    root: test_scratch.ScratchDir,
    env_data_dir: SavedEnv,
    env_tde: SavedEnv,
    env_master: SavedEnv,

    fn init(tag: []const u8, type_name: []const u8) !Fixture {
        const env_data_dir = try SavedEnv.take("GEODE_DATA_DIR");
        errdefer env_data_dir.restore();
        const env_tde = try SavedEnv.take("GEODE_TDE_KEY");
        errdefer env_tde.restore();
        const env_master = try SavedEnv.take("GEODE_MASTER_KEY");
        errdefer env_master.restore();
        _ = unsetenv("GEODE_DATA_DIR");
        _ = unsetenv("GEODE_TDE_KEY");
        _ = setenv("GEODE_MASTER_KEY", master_key, 1);

        var root = try test_scratch.ScratchDir.create(tag);
        errdefer root.remove();
        fle_catalog.setDataDirOverride(root.path());
        resetGlobal();
        const catalog = try fle_catalog.globalCatalog(testing.allocator);
        try catalog.configureField(type_name, FieldMetadata{ .field_name = "ssn", .encryption = .{ .enabled = true } });
        return .{ .root = root, .env_data_dir = env_data_dir, .env_tde = env_tde, .env_master = env_master };
    }

    fn deinit(self: *Fixture) void {
        fle_catalog.setDataDirOverride(null);
        resetGlobal();
        self.root.remove();
        self.env_master.restore();
        self.env_tde.restore();
        self.env_data_dir.restore();
    }

    fn path(self: *const Fixture) []const u8 {
        return self.root.path();
    }
};

fn resetGlobal() void {
    fle_catalog.resetGlobalCatalog(testing.allocator);
    fle_integration.setHasEncryptedFields(false);
}

/// Does the catalog on disk (loaded as a restarted process loads it) give
/// `role` plaintext access to `type_name`.ssn?
fn storedRole(type_name: []const u8, role: []const u8) !bool {
    var catalog = fle_catalog.SchemaCatalog.init(testing.allocator);
    defer catalog.deinit();
    try fle_catalog.loadCatalog(&catalog);
    return catalog.hasVisibilityRole(type_name, "ssn", role);
}

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

    fn exitedZero(self: Run) bool {
        return switch (self.term) {
            .exited => |c| c == 0,
            else => false,
        };
    }

    fn exitedNonZero(self: Run) bool {
        return switch (self.term) {
            .exited => |c| c != 0,
            else => false,
        };
    }

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6321 {s}: term={any}\nstdout:\n{s}\nstderr:\n{s}\n", .{ what, self.term, self.stdout, self.stderr });
    }
};

/// `geode <argv>` with GEODE_MASTER_KEY, and GEODE_DATA_DIR when `data_dir`
/// is given.
fn runGeode(argv: []const []const u8, cwd: []const u8, data_dir: ?[]const u8) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("GEODE_MASTER_KEY", master_key);
    try env.put("GEODE_LSP_PORT", "0");
    if (data_dir) |d| try env.put("GEODE_DATA_DIR", d);
    const r = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } },
    });
    return .{ .term = r.term, .stdout = r.stdout, .stderr = r.stderr };
}

// ---------------------------------------------------------------------------
// (1) migrate-encrypt does not claim a migration it did not perform
// ---------------------------------------------------------------------------

test "SONNY-6321 (1): fle_commands.migrateEncrypt refuses as unsupported instead of reporting a migration it did not perform" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try Fixture.init("sonny6321-migrate", "Sonny6321M");
    defer f.deinit();
    const result = fle_commands.migrateEncrypt(testing.allocator, .{ .tenant_id = "default", .schema_name = "Sonny6321M", .field_name = "ssn" });
    if (result) |_| {
        std.debug.print("SONNY-6321: migrateEncrypt reported success with no storage to migrate through; no value was encrypted\n", .{});
        return error.MigrationClaimedWithoutStorage;
    } else |err| try testing.expectEqual(error.Unsupported, err);
    // The schema and field are still validated first.
    try testing.expectError(error.SchemaNotFound, fle_commands.migrateEncrypt(testing.allocator, .{ .tenant_id = "default", .schema_name = "Sonny6321Missing", .field_name = "ssn" }));
    try testing.expectError(error.FieldNotFound, fle_commands.migrateEncrypt(testing.allocator, .{ .tenant_id = "default", .schema_name = "Sonny6321M", .field_name = "missing" }));
}

test "SONNY-6321 (1): geode fle migrate-encrypt with no server to reach exits non-zero and claims no completed migration" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try Fixture.init("sonny6321-migrate-cli", "Sonny6321MC");
    defer f.deinit();
    resetGlobal();
    // SONNY-6688: it runs in the server; none listens on this port.
    const r = try runGeode(&.{ geode_binary, "fle", "migrate-encrypt", "default", "Sonny6321MC", "ssn", "10", "--server", "127.0.0.1:9", "--insecure", "--timeout", "2" }, f.path(), f.path());
    defer r.deinit();
    const ok = r.exitedNonZero() and !r.output("Migration Complete") and !r.output("Records migrated");
    if (!ok) r.dump("fle migrate-encrypt");
    try testing.expect(r.exitedNonZero());
    try testing.expect(!r.output("Migration Complete"));
    try testing.expect(!r.output("Records migrated"));
    // Its argument checks still run before anything else.
    const bad = try runGeode(&.{ geode_binary, "fle", "migrate-encrypt", "default", "Sonny6321MC", "ssn", "0" }, f.path(), f.path());
    defer bad.deinit();
    if (!bad.exitedNonZero() or !bad.output("batch_size")) bad.dump("fle migrate-encrypt batch 0");
    try testing.expect(bad.exitedNonZero());
    try testing.expect(bad.output("batch_size"));
}

// ---------------------------------------------------------------------------
// (2) the admin command dispatcher
// ---------------------------------------------------------------------------

test "SONNY-6321 (2): fle_commands.executeCommand grants and revokes plaintext access in the persisted catalog and reports it" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try Fixture.init("sonny6321-admin", "Sonny6321A");
    defer f.deinit();
    const a = testing.allocator;

    try testing.expect(!try storedRole("Sonny6321A", "auditor"));
    try fle_commands.executeCommand(a, &.{ "fle", "grant-plaintext", "Sonny6321A", "ssn", "auditor" });
    const global = try fle_catalog.globalCatalog(a);
    try testing.expect(global.hasVisibilityRole("Sonny6321A", "ssn", "auditor"));
    try testing.expect(try storedRole("Sonny6321A", "auditor"));

    try fle_commands.executeCommand(a, &.{ "fle", "show-policy", "Sonny6321A" });
    try fle_commands.executeCommand(a, &.{ "fle", "show-policy", "Sonny6321Unknown" });
    try fle_commands.executeCommand(a, &.{ "fle", "show-rotation", "default" });

    try fle_commands.executeCommand(a, &.{ "fle", "revoke-plaintext", "Sonny6321A", "ssn", "auditor" });
    try testing.expect(!global.hasVisibilityRole("Sonny6321A", "ssn", "auditor"));
    try testing.expect(!try storedRole("Sonny6321A", "auditor"));

    // What does not exist is an error, and changes nothing.
    try testing.expectError(error.SchemaNotFound, fle_commands.executeCommand(a, &.{ "fle", "grant-plaintext", "Sonny6321Missing", "ssn", "auditor" }));
    try testing.expectError(error.FieldNotFound, fle_commands.executeCommand(a, &.{ "fle", "grant-plaintext", "Sonny6321A", "missing", "auditor" }));
    try testing.expectError(error.SchemaNotFound, fle_commands.executeCommand(a, &.{ "fle", "revoke-plaintext", "Sonny6321Missing", "ssn", "auditor" }));
    try testing.expect(!try storedRole("Sonny6321A", "auditor"));

    // Short argument lists and unknown commands.
    try testing.expectError(error.InvalidArguments, fle_commands.executeCommand(a, &.{"fle"}));
    try testing.expectError(error.InvalidArguments, fle_commands.executeCommand(a, &.{ "fle", "grant-plaintext", "Sonny6321A", "ssn" }));
    try testing.expectError(error.InvalidArguments, fle_commands.executeCommand(a, &.{ "fle", "revoke-plaintext", "Sonny6321A" }));
    try testing.expectError(error.InvalidArguments, fle_commands.executeCommand(a, &.{ "fle", "show-policy" }));
    try testing.expectError(error.InvalidArguments, fle_commands.executeCommand(a, &.{ "fle", "migrate-encrypt", "default", "Sonny6321A" }));
    try testing.expectError(error.UnknownCommand, fle_commands.executeCommand(a, &.{ "fle", "drop-everything" }));
    try testing.expectError(error.InvalidScope, fle_commands.executeCommand(a, &.{ "fle", "rotate-key", "default", "everything", "Sonny6321A" }));

    // Neither rotation nor migration is performed, so neither is claimed.
    try testing.expectError(error.Unsupported, fle_commands.executeCommand(a, &.{ "fle", "rotate-key", "default", "fek", "Sonny6321A", "ssn" }));
    try testing.expectError(error.Unsupported, fle_commands.executeCommand(a, &.{ "fle", "migrate-encrypt", "default", "Sonny6321A", "ssn" }));
}

// ---------------------------------------------------------------------------
// (3) the geode fle binary
// ---------------------------------------------------------------------------

test "SONNY-6321 (3): geode fle grant-plaintext writes the server's catalog in GEODE_DATA_DIR, and show-policy reports the grant" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try Fixture.init("sonny6321-cli", "Sonny6321C");
    defer f.deinit();
    resetGlobal();

    {
        const r = try runGeode(&.{ geode_binary, "fle", "grant-plaintext", "Sonny6321C", "ssn", "auditor" }, f.path(), f.path());
        defer r.deinit();
        if (!r.exitedZero()) r.dump("fle grant-plaintext");
        try testing.expect(r.exitedZero());
    }
    try testing.expect(try storedRole("Sonny6321C", "auditor"));
    {
        const r = try runGeode(&.{ geode_binary, "fle", "show-policy", "Sonny6321C" }, f.path(), f.path());
        defer r.deinit();
        const ok = r.exitedZero() and r.output("ssn") and r.output("auditor");
        if (!ok) r.dump("fle show-policy");
        try testing.expect(ok);
    }
    // A field that does not exist: refused, nothing granted.
    {
        const r = try runGeode(&.{ geode_binary, "fle", "grant-plaintext", "Sonny6321C", "missing", "auditor" }, f.path(), f.path());
        defer r.deinit();
        if (!r.exitedNonZero()) r.dump("fle grant-plaintext missing field");
        try testing.expect(r.exitedNonZero());
    }
    // Without GEODE_DATA_DIR the catalog would be this process's only:
    // refused, and the stored catalog is unchanged.
    {
        const r = try runGeode(&.{ geode_binary, "fle", "grant-plaintext", "Sonny6321C", "ssn", "intruder" }, f.path(), null);
        defer r.deinit();
        const ok = r.exitedNonZero() and r.output("GEODE_DATA_DIR");
        if (!ok) r.dump("fle grant-plaintext without GEODE_DATA_DIR");
        try testing.expect(ok);
    }
    try testing.expect(!try storedRole("Sonny6321C", "intruder"));
    try testing.expect(try storedRole("Sonny6321C", "auditor"));
}
