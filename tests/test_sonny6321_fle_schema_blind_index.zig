// SONNY-6321 (remaining parts), FLE schema annotations and the blind index:
//
//   (6) the annotation texts of a CREATE GRAPH TYPE field (as the parser
//       yields them, see tests/test_sonny6321_tde_fle_cases.zig (5)) apply
//       to the field's encryption, search and visibility metadata
//       (REQ-FLE-SCHEMA-001), and an unknown algorithm is refused;
//   (7) the blind index stores HMAC tokens under a key, normalizes case and
//       whitespace, looks up and removes (REQ-FLE-BI-002).
//   (9) both markers are TESTED and cite this file.
//
// These modules are compiled into the geode module too, so they get a test
// binary of their own.
//
// CANARY: REQ=REQ-SONNY-6321-FLE-SCHEMA-BI; FEATURE="FieldLevelEncryption"; ASPECT=AnnotationsBlindIndexEvidence; STATUS=TESTED; TEST=tests/test_sonny6321_fle_schema_blind_index.zig; OWNER=security; UPDATED=2026-11-12
const std = @import("std");
const testing = std.testing;
const fle_annotations = @import("fle_annotations");
const fle_blind_index = @import("fle_blind_index");
const options = @import("sonny6321c_options");

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "SONNY-6321 (6) the parsed annotation texts apply to the field's encryption, search and visibility metadata" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The annotation texts the parser yields for the field (asserted by
    // test-sonny6321-tde-fle-cases (5)).
    const text = "@encrypted(alg:\"AES-256-GCM\", key_scope:\"field\") @searchable(index:\"blind-hmac-sha256\") @visible(to_roles:[\"admin\",\"auditor\"])";

    var meta = fle_annotations.TypeMetadata.init(arena, "S6321Person");
    defer meta.deinit();
    try fle_annotations.applyAnnotations(arena, &meta, "ssn", text);
    try testing.expect(meta.isFieldEncrypted("ssn"));
    try testing.expect(meta.isFieldSearchable("ssn"));
    const fm = meta.getField("ssn") orelse return error.NoField;
    try testing.expectEqual(fle_annotations.EncryptionConfig.Algorithm.aes256_gcm, fm.algorithm().?);
    try testing.expectEqual(@as(usize, 2), fm.visibility.to_roles.len);
    try testing.expect(!meta.isFieldEncrypted("id"));
    // An unknown algorithm is refused, not defaulted.
    var meta2 = fle_annotations.TypeMetadata.init(arena, "S6321Bad");
    defer meta2.deinit();
    try testing.expectError(error.InvalidAlgorithm, fle_annotations.applyAnnotations(arena, &meta2, "x", "@encrypted(alg:\"ROT13\")"));
}

test "SONNY-6321 (7) the blind index stores HMAC tokens, normalizes, looks up and removes" {
    const allocator = testing.allocator;
    var index = fle_blind_index.BlindIndex.init(allocator);
    defer index.deinit();
    var bik: [32]u8 = undefined;
    io().random(&bik);
    var other: [32]u8 = undefined;
    io().random(&other);

    try index.put("Person", "email", bik, "  Alice@EXAMPLE.com ", "p1");
    try index.put("Person", "email", bik, "alice@example.com", "p2");
    try index.put("Person", "email", bik, "bob@example.com", "p3");
    {
        const r = (try index.lookup("Person", "email", bik, "ALICE@example.com")) orelse return error.NotFound;
        try testing.expectEqual(@as(usize, 2), r.len);
    }
    // Another key derives other tokens: nothing matches.
    try testing.expect((try index.lookup("Person", "email", other, "alice@example.com")) == null);
    try index.remove("Person", "email", "p1");
    {
        const r = (try index.lookup("Person", "email", bik, "alice@example.com")) orelse return error.NotFound;
        try testing.expectEqual(@as(usize, 1), r.len);
        try testing.expectEqualStrings("p2", r[0]);
    }
}

fn readRepoFile(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(io(), abs, allocator, .limited(64 << 20));
}

test "SONNY-6321 (9) REQ-FLE-SCHEMA-001 and REQ-FLE-BI-002 are TESTED and cite this file" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for ([_][2][]const u8{
        .{ "src/schema/annotations.zig", "REQ=REQ-FLE-SCHEMA-001;" },
        .{ "src/index/blind_index.zig", "REQ=REQ-FLE-BI-002;" },
    }) |b| {
        const src = try readRepoFile(allocator, b[0]);
        defer allocator.free(src);
        const at = std.mem.indexOf(u8, src, b[1]) orelse return error.NoMarker;
        const end = std.mem.indexOfScalarPos(u8, src, at, '\n') orelse src.len;
        const line = src[at..end];
        if (std.mem.indexOf(u8, line, "STATUS=TESTED") == null or std.mem.indexOf(u8, line, "tests/test_sonny6321_fle_schema_blind_index.zig") == null) {
            bad += 1;
            std.debug.print("SONNY-6321 (9): {s}: {s}\n", .{ b[0], line });
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}
