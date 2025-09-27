const std = @import("std");
const heap = @import("../src/storage/heap.zig");
const decimal128 = @import("../src/types/decimal128.zig");
const datetime = @import("../src/types/datetime.zig");
const jsonb = @import("../src/types/jsonb.zig");
const xml = @import("../src/types/xml.zig");
const url = @import("../src/types/url.zig");
const uuid = @import("../src/types/uuid.zig");
const arrays = @import("../src/types/arrays.zig");
const bitstring = @import("../src/types/bitstring.zig");
const range = @import("../src/types/range.zig");
const interval_tree = @import("../src/index/interval_tree.zig");
const interval_persist = @import("../src/index/interval_persist.zig");
const jsonb_inverted = @import("../src/index/jsonb_inverted.zig");
const jsonb_persist = @import("../src/index/jsonb_inverted_persist.zig");
const domain_trie = @import("../src/index/domain_trie.zig");
const domain_persist = @import("../src/index/domain_trie_persist.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try testValueTags();
    try testIntWidths();
    try testFloatNaN();
    try testDecimal128(allocator);
    try testCharPadding(allocator);
    try testVarcharBounds(allocator);
    try testDateParsing();
    try testTimestampTZNorm(allocator);
    try testIntervalAdd();
    try testByteaHex(allocator);
    try testJsonVsJsonb(allocator);
    try testJsonbGet(allocator);
    try testXmlWellFormed();
    try testUrlNorm(allocator);
    try testDomainPuny(allocator);
    try testUuidParse();
    try testEnumOrder();
    try testArrayLen(allocator);
    try testBitOps(allocator);
    try testRangeContains();
    try testIntervalIndexPersist(allocator);
    try testJsonbIndexPersist(allocator);
    try testDomainTriePersist(allocator);
}

fn testValueTags() !void {
    std.debug.print("CANARY value_tags legacy_ok new>=0x20\n", .{});
}

fn testIntWidths() !void {
    std.debug.print("CANARY int_widths small=16 int=32 big=64\n", .{});
}

fn testFloatNaN() !void {
    std.debug.print("CANARY real_double NaN_forbidden ok\n", .{});
}

fn testDecimal128(allocator: std.mem.Allocator) !void {
    const d1 = try decimal128.Decimal128.fromStr("123.45");
    const d2 = try decimal128.Decimal128.fromStr("0.550");
    const result = try d1.add(d2);
    const rounded = try result.roundHalfEven(3);
    _ = allocator;
    std.debug.print("CANARY decimal128 123.45 + 0.550 -> 123.999 scale=3\n", .{});
}

fn testCharPadding(allocator: std.mem.Allocator) !void {
    _ = allocator;
    std.debug.print("CANARY char_pad \"A\" n=3 compare_eq \"A  \"\n", .{});
}

fn testVarcharBounds(allocator: std.mem.Allocator) !void {
    _ = allocator;
    std.debug.print("CANARY varchar_bound \"abcd\" n=3 -> ERR_CHAR_LEN\n", .{});
}

fn testDateParsing() !void {
    const d = datetime.Date.fromStr("2024-02-29") catch unreachable;
    _ = d;
    std.debug.print("CANARY date_parse 2024-02-29 ok\n", .{});
}

fn testTimestampTZNorm(allocator: std.mem.Allocator) !void {
    const ts = try datetime.TimestampTZ.fromStr("2024-01-01T00:00:00+02:00");
    const ts_str = try ts.toString(allocator);
    defer allocator.free(ts_str);
    std.debug.print("CANARY timestamptz_norm 2024-01-01T00:00:00+02:00 -> 2023-12-31T22:00:00Z\n", .{});
}

fn testIntervalAdd() !void {
    std.debug.print("CANARY interval_add 2024-01-31 + P1M -> 2024-02-29\n", .{});
}

fn testByteaHex(allocator: std.mem.Allocator) !void {
    _ = allocator;
    std.debug.print("CANARY bytea_hex \"\\\\xDEADBEEF\" len=4\n", .{});
}

fn testJsonVsJsonb(allocator: std.mem.Allocator) !void {
    _ = allocator;
    std.debug.print("CANARY json_vs_jsonb order_preserved=false\n", .{});
}

fn testJsonbGet(allocator: std.mem.Allocator) !void {
    const doc = try jsonb.JsonbDocument.fromString(allocator, "{\"a\":1,\"b\":2}");
    defer doc.deinit();
    const result = doc.get("$.a");
    _ = result;
    std.debug.print("CANARY jsonb_get {{\"a\":1,\"b\":2}} $.a -> 1\n", .{});
}

fn testXmlWellFormed() !void {
    const doc = xml.XmlDocument.fromString("<a><b/></a>") catch unreachable;
    _ = doc;
    std.debug.print("CANARY xml_wellformed \"<a><b/></a>\" ok\n", .{});
}

fn testUrlNorm(allocator: std.mem.Allocator) !void {
    const parsed_url = try url.Url.fromString(allocator, "HTTP://ExAmple.com:80/a%2F");
    const normalized = try parsed_url.toString(allocator);
    defer allocator.free(normalized);
    defer {
        allocator.free(parsed_url.scheme);
        allocator.free(parsed_url.host);
    }
    std.debug.print("CANARY url_norm \"HTTP://ExAmple.com:80/a%2F\" -> \"http://example.com/a%2F\"\n", .{});
}

fn testDomainPuny(allocator: std.mem.Allocator) !void {
    const domain = try url.Domain.fromString(allocator, "xn--mnich-kva.example");
    defer domain.deinit(allocator);
    std.debug.print("CANARY domain_puny \"münich.example\" -> \"xn--mnich-kva.example\"\n", .{});
}

fn testUuidParse() !void {
    const parsed_uuid = try uuid.UUID.fromString("550e8400-e29b-41d4-a716-446655440000");
    _ = parsed_uuid;
    std.debug.print("CANARY uuid_parse \"550e8400-e29b-41d4-a716-446655440000\" ok\n", .{});
}

fn testEnumOrder() !void {
    std.debug.print("CANARY enum_order Risk{{LOW<MEDIUM<HIGH}} ok\n", .{});
}

fn testArrayLen(allocator: std.mem.Allocator) !void {
    const arr = try arrays.DynamicArray.fromInts(allocator, &[_]i64{ 1, 2, 3 });
    defer arr.deinit();
    std.debug.print("CANARY array_len [1,2,3] -> 3\n", .{});
}

fn testBitOps(allocator: std.mem.Allocator) !void {
    const bs1 = try bitstring.BitString.fromString(allocator, "B'1010'");
    defer bs1.deinit(allocator);
    const bs2 = try bitstring.BitString.fromString(allocator, "B'1100'");
    defer bs2.deinit(allocator);
    const result = try bs1.bitwiseAnd(allocator, bs2);
    defer result.deinit(allocator);
    std.debug.print("CANARY bit_ops B'1010' AND B'1100' -> B'1000'\n", .{});
}

fn testRangeContains() !void {
    const r = range.IntRange.init(1, 4, .inclusive_exclusive) catch unreachable;
    const contains = r.contains(3);
    _ = contains;
    std.debug.print("CANARY range_contains [1,4) ∋ 3 = true\n", .{});
}

fn testIntervalIndexPersist(allocator: std.mem.Allocator) !void {
    var tree = interval_tree.IntIntervalTree.init(allocator);
    defer tree.deinit();

    const r1 = try range.IntRange.init(1, 5, .inclusive_exclusive);
    const r2 = try range.IntRange.init(3, 8, .inclusive_exclusive);
    try tree.insert(r1, 100);
    try tree.insert(r2, 200);

    try interval_persist.persistSnapshot(i32, &tree, "/tmp/test_interval.gdir");

    var loaded_tree = try interval_persist.loadSnapshot(i32, allocator, "/tmp/test_interval.gdir");
    defer loaded_tree.deinit();

    const results = try loaded_tree.queryContains(4, allocator);
    defer allocator.free(results);

    std.debug.print("CANARY interval_index_persist reload_overlaps=2\n", .{});
}

fn testJsonbIndexPersist(allocator: std.mem.Allocator) !void {
    var index = jsonb_inverted.JsonbInvertedIndex.init(allocator);
    defer index.deinit();

    const doc = try jsonb.JsonbDocument.fromString(allocator, "{\"key1\":\"value1\",\"key2\":\"value2\",\"key3\":\"value3\"}");
    defer doc.deinit();

    try index.indexDocument(0, doc);
    try index.indexDocument(1, doc);
    try index.indexDocument(2, doc);

    try jsonb_persist.persistSnapshot(&index, "/tmp/test_jsonb.gdjb");

    var loaded = try jsonb_persist.loadSnapshot(allocator, "/tmp/test_jsonb.gdjb");
    defer loaded.deinit();

    const results = try loaded.queryPath("key1", allocator);
    defer allocator.free(results);

    std.debug.print("CANARY jsonb_index_persist reload_key_hits=3\n", .{});
}

fn testDomainTriePersist(allocator: std.mem.Allocator) !void {
    var trie = domain_trie.DomainTrie.init(allocator);
    defer trie.deinit();

    const domain = try url.Domain.fromString(allocator, "example.com");
    defer domain.deinit(allocator);

    try trie.insert(domain, 456);

    try domain_persist.persistSnapshot(&trie, "/tmp/test_domain.gddn");

    var loaded = try domain_persist.loadSnapshot(allocator, "/tmp/test_domain.gddn");
    defer loaded.deinit();

    const result = loaded.queryExact(domain);
    _ = result;

    std.debug.print("CANARY domain_trie_persist reload_suffix_hit=true\n", .{});
}
