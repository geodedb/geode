const std = @import("std");
const geode = @import("geode");
const advanced_types = geode.index.advanced_types_index;
const jsonb = geode.types.jsonb;
const url = geode.types.url;
const range = geode.types.range;
const heap = @import("../src/storage/heap.zig");

test "Advanced Types Index Persistence Integration" {
    const allocator = std.testing.allocator;
    const test_dir = "test_persistence";

    // Cleanup previous run
    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makeDir(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    {
        var manager = advanced_types.AdvancedIndexManager.init(allocator);
        defer manager.deinit();

        // 1. Create Indexes
        try manager.createIntervalIndex("intervals");
        try manager.createJsonbIndex("docs");
        try manager.createDomainIndex("domains");

        // 2. Insert Data
        // Interval
        try manager.insertInterval("intervals", 10, 20, 1);
        try manager.insertInterval("intervals", 5, 15, 2);

        // Jsonb
        var doc = try jsonb.JsonbDocument.fromString(allocator, "{\"type\": \"user\", \"name\": \"Alice\"}");
        defer doc.deinit();
        try manager.insertJsonb("docs", 100, doc); // Does this take ownership? No, indexDocument parses. Wait, doc is passed by value but holds ptr.
        // `indexDocument` in jsonb_inverted.zig doesn't seem to take ownership of `JsonbDocument` content for storage, it copies paths.

        // Domain
        var domain = try url.Domain.fromString(allocator, "example.com");
        defer domain.deinit(allocator);
        try manager.insertDomain("domains", domain, 200);

        // 3. Persist
        try manager.persistAll(test_dir);
    }

    {
        var manager = advanced_types.AdvancedIndexManager.init(allocator);
        defer manager.deinit();

        // 4. Load
        try manager.loadAll(test_dir);

        // 5. Verify Data

        // Interval
        if (manager.interval_indexes.get("intervals")) |idx| {
            // Need a way to query. IntervalIndexWrapper exposes `tree`.
            const results = try idx.tree.queryContains(12, allocator);
            defer allocator.free(results);
            try std.testing.expectEqual(@as(usize, 2), results.len); // Both [10,20) and [5,15) contain 12?
            // [10, 20) contains 12.
            // [5, 15) contains 12.
            // Yes.
        } else return error.IntervalIndexMissing;

        // Jsonb
        if (manager.jsonb_indexes.get("docs")) |idx| {
            const results = try idx.queryPath("type:string:user", allocator);
            defer allocator.free(results);
            try std.testing.expectEqual(@as(usize, 1), results.len);
            try std.testing.expectEqual(@as(usize, 100), results[0]);
        } else return error.JsonbIndexMissing;

        // Domain
        if (manager.domain_indexes.get("domains")) |idx| {
            var domain = try url.Domain.fromString(allocator, "example.com");
            defer domain.deinit(allocator);
            const result = idx.queryExact(domain);
            try std.testing.expectEqual(@as(usize, 200), result.?);
        } else return error.DomainIndexMissing;
    }
}
