// SONNY-2656 regression: the engine-direct node scan leaked the clone of every
// typed extended property value (Text, Json, Bytea, Char, Varchar, Url, ...)
// that it projected or filtered on.
//
// `.Member` hands back a fresh clone of an extended value
// (`propertyValueToProjectedValue`). Two places dropped that clone unfreed:
//   * row side: page teardown freed cells with `value_utilities.freeValue`,
//     which frees only strings, lists and maps, so a projected `n.v` of any
//     other extended kind leaked with every row;
//   * predicate side: `IS NULL` and the comparisons evaluate `n.v` and drop
//     it, so `WHERE n.v IS NOT NULL` leaked one clone per node the scan
//     checked, in the paging loop, the filtered count's tally and the slot
//     collection of a `WHERE ... LIMIT` scan. These run on the server's main
//     allocator.
//
// One `:K<kind>` label per memory-owning extended kind, each with three nodes
// holding a value of that kind in `v`. For every kind the stream projects
// `n.v` (the schema-frame sample prefetched, as both transports do) and checks
// each cell against the executor's answer, and filters on `n.v` at all three
// predicate sites, with `IS NOT NULL` and with a comparison. Every stream runs
// on a counting wrapper over `std.testing.allocator`, so a leak is reported
// per kind and site, and the whole test is leak-checked as well.
//
// CANARY: REQ=REQ-SONNY-2656-EXTENDED-VALUE-LEAKS; FEATURE="EngineDirectExtendedValueOwnership"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2656_extended_value_leaks.zig; OWNER=engine; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const Value = geode.value_types.Value;
const ExtValue = geode.property_value_codec.ExtValue;

const Kind = struct {
    /// Label suffix: the nodes are `:K<name>`.
    name: []const u8,
    /// GQL expression that builds the value.
    ctor: []const u8,
    /// The kind `n.v` projects to.
    tag: std.meta.Tag(Value),
    /// For an `.ExtValue` projection, the extended kind inside it.
    ext: ?std.meta.Tag(ExtValue) = null,
};

const kinds = [_]Kind{
    .{ .name = "Text", .ctor = "Text('hello')", .tag = .Text },
    .{ .name = "Char", .ctor = "Char('ab', 5)", .tag = .Char },
    .{ .name = "Varchar", .ctor = "Varchar('ab', 5)", .tag = .Varchar },
    .{ .name = "Bytea", .ctor = "Bytea('\\\\x0102ff')", .tag = .Bytea },
    .{ .name = "Json", .ctor = "Json('{\"a\": 1}')", .tag = .Json },
    .{ .name = "Jsonb", .ctor = "Jsonb('{\"a\": 1}')", .tag = .Jsonb },
    .{ .name = "Xml", .ctor = "Xml('<a>1</a>')", .tag = .Xml },
    .{ .name = "Url", .ctor = "Url('https://example.com/p?q=1#f')", .tag = .Url },
    .{ .name = "Domain", .ctor = "Domain('www.example.com')", .tag = .Domain },
    .{ .name = "Bit", .ctor = "Bit('1010')", .tag = .BitString },
    .{ .name = "VarBit", .ctor = "VarBit('101')", .tag = .VarBit },
    .{ .name = "Lang", .ctor = "LanguageTag('en-US')", .tag = .ExtValue, .ext = .LanguageTag },
    .{ .name = "Geom", .ctor = "GeometryFromText('POINT(1 2)')", .tag = .ExtValue, .ext = .Geometry },
    .{ .name = "VecF", .ctor = "vectorf32([1.0, 2.0])", .tag = .ExtValue, .ext = .VectorF32 },
    .{ .name = "VecI", .ctor = "vectori32([1, 2])", .tag = .ExtValue, .ext = .VectorI32 },
    .{ .name = "Hash", .ctor = "Hash('SHA3-256', 'a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3')", .tag = .ExtValue, .ext = .Hash },
    .{ .name = "List", .ctor = "['a', 'b']", .tag = .List },
};

/// Nodes per kind.
const per_kind: usize = 3;

/// `per_kind` `:K<kind>` nodes per kind, s = 'k0'.., v = the kind's value.
fn seedKinds(h: *harness.Harness) !void {
    const aa = h.arena.allocator();
    for (kinds) |kind| {
        for (0..per_kind) |i| {
            const q = try std.fmt.allocPrint(aa, "CREATE (:K{s} {{s: 'k{d}', v: {s}}})", .{ kind.name, i, kind.ctor });
            var r = h.run(q) catch |err| {
                std.debug.print("seeding {s} failed: {s}\n", .{ q, @errorName(err) });
                return err;
            };
            r.deinit(aa);
        }
    }
}

/// `value` as text, enough to tell two values of one extended kind apart.
fn render(aa: std.mem.Allocator, value: Value) ![]const u8 {
    return switch (value) {
        .Text => |s| aa.dupe(u8, s),
        .Char => |c| std.fmt.allocPrint(aa, "{s}/{d}", .{ c.data, c.n }),
        .Varchar => |c| std.fmt.allocPrint(aa, "{s}/{d}", .{ c.data, c.n }),
        .Bytea => |b| std.fmt.allocPrint(aa, "{x}", .{b}),
        .Json => |j| aa.dupe(u8, j),
        .Jsonb => |d| std.fmt.allocPrint(aa, "{x}", .{d.data}),
        .Xml => |d| aa.dupe(u8, d.data),
        .Url => |u| std.fmt.allocPrint(aa, "{s}|{s}|{d}|{s}|{s}|{s}", .{ u.scheme, u.host, u.port orelse 0, u.path, u.query orelse "", u.fragment orelse "" }),
        .Domain => |d| std.mem.join(aa, ".", d.labels),
        .BitString, .VarBit => |b| std.fmt.allocPrint(aa, "{d}:{x}", .{ b.bit_length, b.bytes }),
        .List => |items| blk: {
            var out: std.ArrayList(u8) = .empty;
            for (items) |item| {
                try out.appendSlice(aa, try render(aa, item));
                try out.append(aa, ',');
            }
            break :blk out.toOwnedSlice(aa);
        },
        .Str => |s| aa.dupe(u8, s),
        .ExtValue => |ext| switch (ext) {
            .LanguageTag => |t| aa.dupe(u8, t.tag),
            .Geometry => |g| std.fmt.allocPrint(aa, "{x}", .{g.wkb}),
            .VectorF32 => |v| std.fmt.allocPrint(aa, "{any}", .{v.data}),
            .VectorI32 => |v| std.fmt.allocPrint(aa, "{any}", .{v.data}),
            .Hash => |x| std.fmt.allocPrint(aa, "{t}:{x}", .{ x.alg, x.digest }),
            else => error.UnexpectedExtendedKind,
        },
        else => error.UnexpectedCellKind,
    };
}

/// The executor's `n.v` per node (`n.s` 'kI' at index I), rendered.
fn executorValues(h: *harness.Harness, kind: Kind) ![per_kind][]const u8 {
    const aa = h.arena.allocator();
    var result = try h.run(try std.fmt.allocPrint(aa, "MATCH (n:K{s}) RETURN n.s, n.v", .{kind.name}));
    defer result.deinit(aa);
    try testing.expectEqual(per_kind, result.rows.len);
    var out: [per_kind][]const u8 = undefined;
    for (result.rows) |row| out[try nodeIndex(row[0])] = try render(aa, row[1]);
    return out;
}

fn nodeIndex(s: Value) !usize {
    return std.fmt.parseInt(usize, s.Str[1..], 10);
}

/// What one stream returned.
const Drained = struct {
    rows: usize,
    /// Allocations the stream and its pages made and never freed.
    leaked: usize,
};

/// Open a stream for `query` on a counting wrapper over the test allocator,
/// prefetch its schema-frame sample (a no-op unless it projects), page it to
/// its end two rows at a time, and pass each row to `check`.
fn drain(h: *harness.Harness, qa: *std.heap.ArenaAllocator, query: []const u8, ctx: anytype, comptime check: fn (@TypeOf(ctx), []const Value) anyerror!void) !Drained {
    var counting = std.testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = counting.allocator();
    var rows: usize = 0;
    {
        var stream = try harness.openStream(h, allocator, qa, query);
        defer stream.deinit();
        try stream.prefetchSchemaSample(allocator);
        var pages: usize = 0;
        while (true) : (pages += 1) {
            if (pages > per_kind + 2) return error.NeverFinal;
            var page = try stream.buildNextPage(allocator, 2);
            defer page.result.deinit(allocator);
            for (page.result.rows) |row| try check(ctx, row);
            rows += page.result.rows.len;
            if (page.final) break;
        }
    }
    return .{ .rows = rows, .leaked = counting.allocations - counting.deallocations };
}

const ProjectionCheck = struct {
    h: *harness.Harness,
    kind: Kind,
    want: [per_kind][]const u8,
    seen: *[per_kind]bool,
};

/// Row `n.s, n.v`: `v` is the kind's value, equal to the executor's for the
/// same node, and each node comes back once.
fn checkProjectionRow(c: ProjectionCheck, row: []const Value) anyerror!void {
    const i = try nodeIndex(row[0]);
    try testing.expect(!c.seen[i]);
    c.seen[i] = true;
    const v = row[1];
    try testing.expectEqual(c.kind.tag, std.meta.activeTag(v));
    if (c.kind.ext) |ext| try testing.expectEqual(ext, std.meta.activeTag(v.ExtValue));
    try testing.expectEqualStrings(c.want[i], try render(c.h.arena.allocator(), v));
}

fn ignoreRow(_: void, _: []const Value) anyerror!void {}

/// Print every (kind, site) that leaked, and fail if any did.
fn expectNoLeaks(site_names: []const []const u8, leaks: []const [kinds.len]usize) !void {
    var total: usize = 0;
    for (site_names, leaks) |site, per| {
        for (kinds, per) |kind, n| {
            if (n == 0) continue;
            std.debug.print("{s} {s}: {d} allocations leaked\n", .{ kind.name, site, n });
            total += n;
        }
    }
    try testing.expectEqual(@as(usize, 0), total);
}

test "SONNY-2656: a projected extended value is freed with its row on the node-scan fast path" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seedKinds(&h);
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    var leaks: [1][kinds.len]usize = undefined;
    for (kinds, 0..) |kind, k| {
        var seen = [_]bool{false} ** per_kind;
        const check = ProjectionCheck{ .h = &h, .kind = kind, .want = try executorValues(&h, kind), .seen = &seen };
        const query = try std.fmt.allocPrint(qa.allocator(), "MATCH (n:K{s}) RETURN n.s, n.v", .{kind.name});
        const got = try drain(&h, &qa, query, check, checkProjectionRow);
        try testing.expectEqual(per_kind, got.rows);
        leaks[0][k] = got.leaked;
    }
    try expectNoLeaks(&.{"projection"}, &leaks);
}

test "SONNY-2656: an extended value a WHERE reads is freed at every node-scan predicate site" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seedKinds(&h);
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    const aa = qa.allocator();

    // Each predicate reads `n.v`: `IS NOT NULL` drops it in IS NULL, and
    // `<> 'zz'` drops it in the comparison.
    const predicates = [_][]const u8{ "n.v IS NOT NULL", "n.v <> 'zz'" };
    const site_names = [_][]const u8{
        "IS NOT NULL paging", "IS NOT NULL count", "IS NOT NULL ... LIMIT collection",
        "comparison paging",  "comparison count",  "comparison ... LIMIT collection",
    };
    var leaks: [site_names.len][kinds.len]usize = undefined;
    for (kinds, 0..) |kind, k| {
        for (predicates, 0..) |pred, p| {
            // The executor decides how many nodes pass.
            const base = try std.fmt.allocPrint(aa, "MATCH (n:K{s}) WHERE {s}", .{ kind.name, pred });
            var executor = try h.run(try std.fmt.allocPrint(aa, "{s} RETURN n.s", .{base}));
            const passing = executor.rows.len;
            executor.deinit(h.arena.allocator());
            if (p == 0) try testing.expectEqual(per_kind, passing);

            // The paging loop.
            const paged = try drain(&h, &qa, try std.fmt.allocPrint(aa, "{s} RETURN n.s", .{base}), {}, ignoreRow);
            try testing.expectEqual(passing, paged.rows);
            leaks[p * 3][k] = paged.leaked;

            // The filtered count's tally.
            var counting = std.testing.FailingAllocator.init(testing.allocator, .{});
            {
                const a = counting.allocator();
                var stream = try harness.openStream(&h, a, &qa, try std.fmt.allocPrint(aa, "{s} RETURN count(n)", .{base}));
                defer stream.deinit();
                var page = try stream.buildNextPage(a, 0);
                defer page.result.deinit(a);
                try testing.expect(page.final);
                try testing.expectEqual(@as(i64, @intCast(passing)), page.result.rows[0][0].Int);
            }
            leaks[p * 3 + 1][k] = counting.allocations - counting.deallocations;

            // `WHERE ... LIMIT` collects its slots through the predicate.
            const limited = try drain(&h, &qa, try std.fmt.allocPrint(aa, "{s} RETURN n.s LIMIT 2", .{base}), {}, ignoreRow);
            try testing.expectEqual(@min(passing, 2), limited.rows);
            leaks[p * 3 + 2][k] = limited.leaked;
        }
    }
    try expectNoLeaks(&site_names, &leaks);
}
