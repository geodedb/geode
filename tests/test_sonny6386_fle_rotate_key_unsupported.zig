// CANARY: REQ=REQ-SONNY-6386-FLE-ROTATE-UNSUPPORTED; FEATURE="FieldLevelEncryption"; ASPECT=RotateKeyRefusedAsUnsupported; STATUS=TESTED; TEST=tests/test_sonny6386_fle_rotate_key_unsupported.zig; OWNER=security; UPDATED=2026-11-12
//
// SONNY-6386 (2): FLE key rotation reported success without rotating
// anything.
//   - `fle_commands.rotateKey` printed "TRK/SK/FEK rotation complete. New key
//     version active." and returned success; it never touched a key.
//   - `geode fle rotate-key` built a throwaway in-memory KeyManager from
//     GEODE_MASTER_KEY, bumped a version in it, printed "Rotated FEK ... to
//     version 2" and exited 0. Nothing was persisted and no field value was
//     re-encrypted; the next process had the same keys as before.
//   - `geode fle show-rotation` printed "Tenant Root Key (TRK): Active" and
//     "Last rotation check: Now", which nothing measured.
//
// Real rotation is story SONNY-6387. Until it lands, rotation is refused as
// unsupported: an error (non-zero exit), a message naming the story, and no
// claim that a key changed.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const fle_commands = geode.fle_commands;
const geode_binary = geode_test_bin.geode_exe;

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

    fn exitedNonZero(self: Run) bool {
        return switch (self.term) {
            .exited => |c| c != 0,
            else => false,
        };
    }

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6386 {s}: term={any}\nstdout:\n{s}\nstderr:\n{s}\n", .{ what, self.term, self.stdout, self.stderr });
    }
};

fn runGeode(argv: []const []const u8, cwd: []const u8) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("GEODE_MASTER_KEY", "sonny6386-fle-master-key-0123456789abcdef");
    try env.put("GEODE_LSP_PORT", "0");
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

fn expectRefused(r: Run, what: []const u8) !void {
    const ok = r.exitedNonZero() and r.output("not supported") and r.output("SONNY-6387") and
        !r.output("Rotated") and !r.output("Rewrapped") and !r.output("rotation complete") and
        !r.output("New key version active");
    if (!ok) r.dump(what);
    try testing.expect(r.exitedNonZero());
    try testing.expect(r.output("not supported"));
    try testing.expect(r.output("SONNY-6387"));
    try testing.expect(!r.output("Rotated"));
    try testing.expect(!r.output("Rewrapped"));
    try testing.expect(!r.output("rotation complete"));
    try testing.expect(!r.output("New key version active"));
}

test "SONNY-6386 (2) geode fle rotate-key refuses every scope as unsupported, exits non-zero, and claims no rotation" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var root = try test_scratch.ScratchDir.create("sonny6386-fle-cli");
    defer root.remove();
    const cases = [_][]const []const u8{
        &.{ geode_binary, "fle", "rotate-key", "default", "fek", "Person", "ssn" },
        &.{ geode_binary, "fle", "rotate-key", "default", "sk", "Person" },
        &.{ geode_binary, "fle", "rotate-key", "default", "trk" },
    };
    for (cases) |argv| {
        const r = try runGeode(argv, root.path());
        defer r.deinit();
        try expectRefused(r, argv[4]);
    }
}

test "SONNY-6386 (2) geode fle help and show-rotation do not advertise or report a rotation" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var root = try test_scratch.ScratchDir.create("sonny6386-fle-help");
    defer root.remove();
    {
        const r = try runGeode(&.{ geode_binary, "fle", "--help" }, root.path());
        defer r.deinit();
        const ok = r.output("rotate-key") and r.output("not supported") and r.output("SONNY-6387");
        if (!ok) r.dump("fle --help");
        try testing.expect(ok);
    }
    {
        const r = try runGeode(&.{ geode_binary, "fle", "show-rotation", "default" }, root.path());
        defer r.deinit();
        const ok = !r.output("Active") and !r.output("Last rotation check: Now") and r.output("not supported");
        if (!ok) r.dump("fle show-rotation");
        try testing.expect(!r.output("Active"));
        try testing.expect(!r.output("Last rotation check: Now"));
        try testing.expect(r.output("not supported"));
    }
}

test "SONNY-6386 (2) fle_commands.rotateKey returns error.Unsupported for every scope" {
    const allocator = testing.allocator;
    defer geode.fle_integration.catalog_mod.resetGlobalCatalog(allocator);
    const cases = [_]fle_commands.KeyRotationArgs{
        .{ .tenant_id = "default", .scope = .trk },
        .{ .tenant_id = "default", .scope = .sk, .schema_name = "Person" },
        .{ .tenant_id = "default", .scope = .fek, .schema_name = "Person", .field_name = "ssn" },
    };
    for (cases) |args| {
        try testing.expectError(error.Unsupported, fle_commands.rotateKey(allocator, args));
    }
    // Missing arguments are still reported as such.
    try testing.expectError(error.InvalidArguments, fle_commands.rotateKey(allocator, .{ .tenant_id = "default", .scope = .sk }));
    try testing.expectError(error.InvalidArguments, fle_commands.rotateKey(allocator, .{ .tenant_id = "default", .scope = .fek, .schema_name = "Person" }));
}
