// SONNY-2441: the KMSProvider remote path (src/security/kms.zig
// wrapRemoteKMS / unwrapRemoteKMS and the connection reuse from eb3f13d7)
// and `createRemoteKMSTDE` (src/security/tde_kms_integration.zig) were
// exercised by compilation only, and the CANARY markers claiming TESTED
// cited tests/test_kms_provider.zig and tests/test_tde_kms_integration.zig,
// which no build step compiled.
//
// The remote path cannot be wired as written: `wrapRemoteKMS` ignores the
// key it is asked to wrap and returns a fresh key the remote KMS generated
// (the remote protocol has GENERATE and UNWRAP, no WRAP), so
// unwrap(wrap(k)) != k and anything encrypted under k would be lost. It has
// no caller (lib.zig does not export it; no server path builds a
// remote_kms provider). The ticket's second option applies: delete the
// remote path and make the CANARYs true. The remote KMS client itself
// (src/security/kms_remote.zig) stays; test-remote-kms drives it.
//
// Checked here, by the provider's own type: every provider type
// KMSProvider offers either round-trips the caller's key or refuses as
// unsupported, and remote_kms is not one of them; and the two KMS test
// files are built and run (test-kms-provider, test-tde-kms-integration).
//
// CANARY: REQ=REQ-SONNY-2441-KMS-REMOTE-PATH; FEATURE="KMSProviderSystem"; ASPECT=NoDeadRemotePath; STATUS=TESTED; TEST=tests/test_sonny2441_kms_provider_paths.zig; OWNER=security; UPDATED=2026-11-12
const std = @import("std");
const tde_kms = @import("security/tde_kms_integration");
const kms = tde_kms.kms;
const options = @import("sonny2441_options");

const testing = std.testing;

test "SONNY-2441 KMSProvider offers no remote_kms provider and tde_kms_integration no createRemoteKMSTDE" {
    try testing.expect(!@hasField(kms.KMSProviderType, "remote_kms"));
    try testing.expect(!@hasDecl(kms, "remoteKMSProvider"));
    try testing.expect(!@hasDecl(tde_kms, "createRemoteKMSTDE"));
}

test "SONNY-2441 every provider type KMSProvider offers round-trips the caller's key or refuses" {
    const allocator = testing.allocator;
    const key = [_]u8{0x5A} ** 32;
    inline for (std.meta.fields(kms.KMSProviderType)) |f| {
        const t: kms.KMSProviderType = @enumFromInt(f.value);
        var provider = kms.KMSProvider.init(allocator, .{ .provider_type = t, .seed = 0xC0FFEE }) catch |err| {
            // A release build refuses non-production providers at init.
            try testing.expectEqual(error.UnsafeKMSProvider, err);
            continue;
        };
        defer provider.deinit();
        if (provider.wrapDataKey(&key)) |wrapped_const| {
            var wrapped = wrapped_const;
            defer wrapped.deinit(allocator);
            const back = try provider.unwrapDataKey(wrapped);
            defer allocator.free(back);
            testing.expectEqualSlices(u8, &key, back) catch |e| {
                std.debug.print("SONNY-2441: provider {s} does not round-trip the caller's key\n", .{f.name});
                return e;
            };
        } else |err| {
            testing.expectEqual(error.UnsupportedProvider, err) catch |e| {
                std.debug.print("SONNY-2441: provider {s}: wrapDataKey failed with {s}\n", .{ f.name, @errorName(err) });
                return e;
            };
        }
    }
}

test "SONNY-2441 the KMS provider and TDE-KMS tests are built and run" {
    const allocator = testing.allocator;
    const path = try std.fs.path.join(allocator, &.{ options.repo_root, "build.zig" });
    defer allocator.free(path);
    const build_src = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(16 << 20));
    defer allocator.free(build_src);
    var bad: usize = 0;
    for ([_][]const u8{ "tests/test_kms_provider.zig", "tests/test_tde_kms_integration.zig" }) |rel| {
        const reg = try std.fmt.allocPrint(allocator, "b.path(\"{s}\")", .{rel});
        defer allocator.free(reg);
        if (std.mem.indexOf(u8, build_src, reg) == null) {
            bad += 1;
            std.debug.print("SONNY-2441: {s} is compiled by no build step\n", .{rel});
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}
