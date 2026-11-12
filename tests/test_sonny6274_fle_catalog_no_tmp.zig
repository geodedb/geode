// SONNY-6274 regression: where the field-level-encryption (FLE) catalog
// lives.
//
// The FLE catalog records which (type, field) pairs are encrypted, with what
// algorithm and key scope, which are blind-indexed, and which roles may read
// them in plaintext. It holds no key material. It was saved to and loaded
// from `{GEODE_DATA_DIR or /tmp}/geode_fle_catalog.dat`:
//
//   (1) With no data directory every session, test and process shared
//       /tmp/geode_fle_catalog.dat, so a fresh session took its set of
//       encrypted fields from whatever an earlier run left there, and wrote
//       its own encryption metadata to a shared, world-traversable path. With
//       no data directory the FLE catalog is now in memory, as the index
//       catalog (`Catalog.isPersisted`) and the store are.
//   (2) Only GEODE_DATA_DIR counted, so a store given its data directory the
//       way the server does it (`--data-dir` -> `graph_store.setDataDirOverride`)
//       still kept the FLE catalog in /tmp. It now lives in that directory.
//   (3) The file was opened O_CREAT | O_TRUNC with the default mode (0644
//       under the usual umask), and a symbolic link planted at the path was
//       followed on both read and write. It is now written to a new 0600 file
//       renamed over the path, and a link at the path is refused on read.
//
// Robust to /tmp/geode_fle_catalog.dat already existing with foreign content:
// it is never loaded, modified or deleted. When it does not exist the test
// plants one (a catalog naming a foreign encrypted field) for the duration,
// and removes only that.
//
// Real catalog load/save and the real `CALL geode.fle.configureField`
// dispatch; no mocks.
//
// CANARY: REQ=REQ-SONNY-6274-FLE-CATALOG-NO-TMP; FEATURE="FieldLevelEncryption"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6274_fle_catalog_no_tmp.zig; OWNER=security; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const fle_integration = geode.fle_integration;
const fle_catalog = fle_integration.catalog_mod;
const storage_dispatch = geode.storage_dispatch;
const ast = geode.gql.ast;

const FieldMetadata = @typeInfo(@TypeOf(fle_catalog.SchemaCatalog.configureField)).@"fn".params[2].type.?;

const shared_tmp_path = "/tmp/geode_fle_catalog.dat";
const catalog_file_name = "geode_fle_catalog.dat";
const foreign_type = "Sonny6274ForeignType";
const foreign_field = "foreign_secret";

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn umask(mask: c_uint) c_uint;

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

/// A serialized FLE catalog (the on-disk format, unencrypted) with one type
/// and one encrypted field.
fn foreignCatalogBytes(allocator: std.mem.Allocator, type_name: []const u8, field_name: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var w: [4]u8 = undefined;
    std.mem.writeInt(u32, &w, 1, .little); // type count
    try buf.appendSlice(allocator, &w);
    std.mem.writeInt(u32, &w, @intCast(type_name.len), .little);
    try buf.appendSlice(allocator, &w);
    try buf.appendSlice(allocator, type_name);
    std.mem.writeInt(u32, &w, 1, .little); // field count
    try buf.appendSlice(allocator, &w);
    std.mem.writeInt(u32, &w, @intCast(field_name.len), .little);
    try buf.appendSlice(allocator, &w);
    try buf.appendSlice(allocator, field_name);
    try buf.appendSlice(allocator, &[_]u8{ 1, 0, 0 }); // encrypted, aes256_gcm, field scope
    try buf.appendSlice(allocator, &[_]u8{0}); // not searchable
    std.mem.writeInt(u32, &w, 0, .little); // no plaintext roles
    try buf.appendSlice(allocator, &w);
    return buf.toOwnedSlice(allocator);
}

/// What is at /tmp/geode_fle_catalog.dat before the test, so the test can
/// prove it neither read nor touched it.
const SharedFile = struct {
    planted: bool,
    bytes: []u8,
    inode: std.Io.File.INode,
    mtime: std.Io.Timestamp,

    fn snapshot(allocator: std.mem.Allocator) !SharedFile {
        var planted = false;
        const existing = std.Io.Dir.cwd().statFile(io(), shared_tmp_path, .{ .follow_symlinks = false });
        if (existing) |_| {} else |err| switch (err) {
            error.FileNotFound => {
                const bytes = try foreignCatalogBytes(allocator, foreign_type, foreign_field);
                defer allocator.free(bytes);
                const file = try std.Io.Dir.cwd().createFile(io(), shared_tmp_path, .{ .exclusive = true });
                defer file.close(io());
                try file.writeStreamingAll(io(), bytes);
                planted = true;
            },
            else => return err,
        }
        const st = try std.Io.Dir.cwd().statFile(io(), shared_tmp_path, .{ .follow_symlinks = false });
        const bytes = if (st.kind == .file)
            try std.Io.Dir.cwd().readFileAlloc(io(), shared_tmp_path, allocator, .limited(64 << 20))
        else
            try allocator.dupe(u8, "");
        return .{ .planted = planted, .bytes = bytes, .inode = st.inode, .mtime = st.mtime };
    }

    fn expectUntouched(self: SharedFile, allocator: std.mem.Allocator) !void {
        const st = std.Io.Dir.cwd().statFile(io(), shared_tmp_path, .{ .follow_symlinks = false }) catch |err| {
            std.debug.print("{s} was removed: {s}\n", .{ shared_tmp_path, @errorName(err) });
            return error.SharedFileRemoved;
        };
        try testing.expectEqual(self.inode, st.inode);
        try testing.expectEqual(self.mtime.nanoseconds, st.mtime.nanoseconds);
        if (st.kind == .file) {
            const now = try std.Io.Dir.cwd().readFileAlloc(io(), shared_tmp_path, allocator, .limited(64 << 20));
            defer allocator.free(now);
            try testing.expectEqualSlices(u8, self.bytes, now);
        }
    }

    fn deinit(self: SharedFile, allocator: std.mem.Allocator) void {
        if (self.planted) {
            // Remove only the file this test planted, and only if it is still
            // the one it planted.
            if (std.Io.Dir.cwd().statFile(io(), shared_tmp_path, .{ .follow_symlinks = false })) |st| {
                if (st.inode == self.inode) std.Io.Dir.cwd().deleteFile(io(), shared_tmp_path) catch {};
            } else |_| {}
        }
        allocator.free(self.bytes);
    }
};

/// No data directory anywhere: no store override, no GEODE_DATA_DIR. Puts
/// back what was there on `restore`.
const NoDataDir = struct {
    saved_env: ?[:0]u8,

    fn enter(allocator: std.mem.Allocator) !NoDataDir {
        const saved: ?[:0]u8 = if (std.c.getenv("GEODE_DATA_DIR")) |p| try allocator.dupeZ(u8, std.mem.span(p)) else null;
        _ = unsetenv("GEODE_DATA_DIR");
        graph_store.setDataDirOverride(allocator, null);
        return .{ .saved_env = saved };
    }

    fn restore(self: NoDataDir, allocator: std.mem.Allocator) void {
        graph_store.setDataDirOverride(allocator, null);
        if (self.saved_env) |s| {
            _ = setenv("GEODE_DATA_DIR", s.ptr, 1);
            allocator.free(s);
        } else _ = unsetenv("GEODE_DATA_DIR");
    }
};

fn encryptedField(name: []const u8) FieldMetadata {
    return .{ .field_name = name, .encryption = .{ .enabled = true } };
}

/// A fresh catalog loaded the way a new process loads it (`globalCatalog`
/// calls `loadCatalog` on a new instance).
fn freshLoaded(allocator: std.mem.Allocator) !fle_catalog.SchemaCatalog {
    var catalog = fle_catalog.SchemaCatalog.init(allocator);
    errdefer catalog.deinit();
    try fle_catalog.loadCatalog(&catalog);
    return catalog;
}

// Drive the real `CALL geode.fle.configureField(type, field)` dispatch, which
// configures the process-global FLE catalog the storage layer reads.
fn configureFleField(arena: std.mem.Allocator, type_name: []const u8, field_name: []const u8) !void {
    var type_expr = ast.Expr{ .String = type_name };
    var field_expr = ast.Expr{ .String = field_name };
    var args = [_]*ast.Expr{ &type_expr, &field_expr };
    var callee = ast.Expr{ .String = "geode.fle.configureField" };
    const proc_expr = ast.Expr{ .Call = .{ .callee = &callee, .args = &args } };
    const call_stmt = ast.CallProcedure{ .procedure = proc_expr };
    const result = try storage_dispatch.executeFle(arena, "geode.fle.configurefield", call_stmt);
    try testing.expect(result != null);
}

fn modeOf(path: []const u8) !u32 {
    const st = try std.Io.Dir.cwd().statFile(io(), path, .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.file, st.kind);
    return @intCast(st.permissions.toMode() & 0o777);
}

test "SONNY-6274: with no data directory the FLE catalog never reads or writes /tmp/geode_fle_catalog.dat" {
    const allocator = testing.allocator;
    // Catalog instances on an arena: SchemaCatalog.deinit does not free its
    // field names or role lists (TypeMetadata.deinit frees only the map), a
    // pre-existing ownership gap outside this regression.
    var cat_arena = std.heap.ArenaAllocator.init(allocator);
    defer cat_arena.deinit();
    const cat_alloc = cat_arena.allocator();

    const env = try NoDataDir.enter(allocator);
    defer env.restore(allocator);

    const shared = try SharedFile.snapshot(allocator);
    defer shared.deinit(allocator);

    // A fresh session does not load the shared file.
    {
        var catalog = try freshLoaded(cat_alloc);
        defer catalog.deinit();
        if (catalog.count() != 0) {
            std.debug.print("a fresh in-memory session loaded {d} FLE type(s) from {s}\n", .{ catalog.count(), shared_tmp_path });
        }
        try testing.expectEqual(@as(usize, 0), catalog.count());
        try testing.expect(!catalog.isFieldEncrypted(foreign_type, foreign_field));
    }

    // Session A configures an encrypted field. Nothing is written to /tmp.
    {
        var a = fle_catalog.SchemaCatalog.init(cat_alloc);
        defer a.deinit();
        try a.configureField("Sonny6274SessionA", encryptedField("ssn"));
        try testing.expect(a.isFieldEncrypted("Sonny6274SessionA", "ssn"));
        try shared.expectUntouched(allocator);
    }

    // Session B, another in-memory session (another process), does not see
    // session A's FLE metadata.
    {
        var b = try freshLoaded(cat_alloc);
        defer b.deinit();
        try testing.expect(!b.isFieldEncrypted("Sonny6274SessionA", "ssn"));
        try testing.expectEqual(@as(usize, 0), b.count());
    }

    try shared.expectUntouched(allocator);
}

test "SONNY-6274: CALL geode.fle.configureField with no data directory stays in memory" {
    const allocator = testing.allocator;
    // Catalog instances on an arena: SchemaCatalog.deinit does not free its
    // field names or role lists (TypeMetadata.deinit frees only the map), a
    // pre-existing ownership gap outside this regression.
    var cat_arena = std.heap.ArenaAllocator.init(allocator);
    defer cat_arena.deinit();
    const cat_alloc = cat_arena.allocator();

    const env = try NoDataDir.enter(allocator);
    defer env.restore(allocator);

    const shared = try SharedFile.snapshot(allocator);
    defer shared.deinit(allocator);

    fle_integration.catalog_mod.resetGlobalCatalog(allocator);
    fle_integration.setHasEncryptedFields(false);
    defer {
        fle_integration.catalog_mod.resetGlobalCatalog(allocator);
        fle_integration.setHasEncryptedFields(false);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try configureFleField(arena.allocator(), "Sonny6274Dispatch", "card");

    const global = try fle_catalog.globalCatalog(allocator);
    try testing.expect(global.isFieldEncrypted("Sonny6274Dispatch", "card"));
    try shared.expectUntouched(allocator);

    var other = try freshLoaded(cat_alloc);
    defer other.deinit();
    try testing.expect(!other.isFieldEncrypted("Sonny6274Dispatch", "card"));
}

test "SONNY-6274: the store's data directory holds the FLE catalog, mode 0600, across a restart" {
    const allocator = testing.allocator;
    // Catalog instances on an arena: SchemaCatalog.deinit does not free its
    // field names or role lists (TypeMetadata.deinit frees only the map), a
    // pre-existing ownership gap outside this regression.
    var cat_arena = std.heap.ArenaAllocator.init(allocator);
    defer cat_arena.deinit();
    const cat_alloc = cat_arena.allocator();

    const env = try NoDataDir.enter(allocator);
    defer env.restore(allocator);

    const shared = try SharedFile.snapshot(allocator);
    defer shared.deinit(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    const catalog_path = try std.fs.path.join(allocator, &.{ data_dir, catalog_file_name });
    defer allocator.free(catalog_path);

    // The way the server configures it: `--data-dir` -> setDataDirOverride,
    // no GEODE_DATA_DIR. A permissive umask must not widen the file mode.
    graph_store.setDataDirOverride(allocator, data_dir);
    const old_umask = umask(0);
    defer _ = umask(old_umask);

    {
        var catalog = try freshLoaded(cat_alloc);
        defer catalog.deinit();
        try testing.expectEqual(@as(usize, 0), catalog.count());
        try catalog.configureField("Sonny6274Persisted", encryptedField("ssn"));
    }

    const mode = modeOf(catalog_path) catch |err| {
        std.debug.print("no FLE catalog at {s}: {s}\n", .{ catalog_path, @errorName(err) });
        return err;
    };
    try testing.expectEqual(@as(u32, 0o600), mode);
    try shared.expectUntouched(allocator);

    // Restart: a new process loads it from the data directory.
    {
        var catalog = try freshLoaded(cat_alloc);
        defer catalog.deinit();
        try testing.expect(catalog.isFieldEncrypted("Sonny6274Persisted", "ssn"));
        // A second save rewrites it, still 0600.
        try catalog.configureField("Sonny6274Persisted", encryptedField("dob"));
    }
    try testing.expectEqual(@as(u32, 0o600), try modeOf(catalog_path));
    {
        var catalog = try freshLoaded(cat_alloc);
        defer catalog.deinit();
        try testing.expect(catalog.isFieldEncrypted("Sonny6274Persisted", "ssn"));
        try testing.expect(catalog.isFieldEncrypted("Sonny6274Persisted", "dob"));
    }

    // Clearing the data directory makes the next session in memory again.
    graph_store.setDataDirOverride(allocator, null);
    {
        var catalog = try freshLoaded(cat_alloc);
        defer catalog.deinit();
        try testing.expect(!catalog.isFieldEncrypted("Sonny6274Persisted", "ssn"));
    }

    // GEODE_DATA_DIR alone still selects the data directory.
    const data_dir_z = try allocator.dupeZ(u8, data_dir);
    defer allocator.free(data_dir_z);
    _ = setenv("GEODE_DATA_DIR", data_dir_z.ptr, 1);
    {
        var catalog = try freshLoaded(cat_alloc);
        defer catalog.deinit();
        try testing.expect(catalog.isFieldEncrypted("Sonny6274Persisted", "ssn"));
    }
}

test "SONNY-6274: a symbolic link planted at the catalog path is neither read nor written through" {
    const allocator = testing.allocator;
    // Catalog instances on an arena: SchemaCatalog.deinit does not free its
    // field names or role lists (TypeMetadata.deinit frees only the map), a
    // pre-existing ownership gap outside this regression.
    var cat_arena = std.heap.ArenaAllocator.init(allocator);
    defer cat_arena.deinit();
    const cat_alloc = cat_arena.allocator();

    const env = try NoDataDir.enter(allocator);
    defer env.restore(allocator);

    const shared = try SharedFile.snapshot(allocator);
    defer shared.deinit(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    const catalog_path = try std.fs.path.join(allocator, &.{ data_dir, catalog_file_name });
    defer allocator.free(catalog_path);
    const victim_path = try std.fs.path.join(allocator, &.{ data_dir, "victim.dat" });
    defer allocator.free(victim_path);

    // The victim holds a valid catalog, so following the link would load it.
    const victim_bytes = try foreignCatalogBytes(allocator, foreign_type, foreign_field);
    defer allocator.free(victim_bytes);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = victim_path, .data = victim_bytes });
    try std.Io.Dir.cwd().symLink(io(), victim_path, catalog_path, .{});

    graph_store.setDataDirOverride(allocator, data_dir);

    var catalog = fle_catalog.SchemaCatalog.init(cat_alloc);
    defer catalog.deinit();
    if (fle_catalog.loadCatalog(&catalog)) |_| {} else |_| {}
    try testing.expect(!catalog.isFieldEncrypted(foreign_type, foreign_field));

    try catalog.configureField("Sonny6274Link", encryptedField("ssn"));

    // The victim is unchanged; the path is now a 0600 regular file.
    const victim_now = try std.Io.Dir.cwd().readFileAlloc(io(), victim_path, allocator, .limited(1 << 20));
    defer allocator.free(victim_now);
    try testing.expectEqualSlices(u8, victim_bytes, victim_now);
    try testing.expectEqual(@as(u32, 0o600), try modeOf(catalog_path));

    var reloaded = try freshLoaded(cat_alloc);
    defer reloaded.deinit();
    try testing.expect(reloaded.isFieldEncrypted("Sonny6274Link", "ssn"));
    try testing.expect(!reloaded.isFieldEncrypted(foreign_type, foreign_field));
    try shared.expectUntouched(allocator);
}
