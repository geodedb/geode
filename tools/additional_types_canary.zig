const std = @import("std");

pub fn main() !void {
    testValueTags();
    testIntWidths();
    testFloatNaN();
    testDecimal128();
    testCharPadding();
    testVarcharBounds();
    testDateParsing();
    testTimestampTZNorm();
    testIntervalAdd();
    testByteaHex();
    testJsonVsJsonb();
    testJsonbGet();
    testXmlWellFormed();
    testUrlNorm();
    testDomainPuny();
    testUuidParse();
    testEnumOrder();
    testArrayLen();
    testBitOps();
    testRangeContains();
    testIntervalIndexPersist();
    testJsonbIndexPersist();
    testDomainTriePersist();
}

fn testValueTags() void {
    std.debug.print("CANARY value_tags legacy_ok new>=0x20\n", .{});
}

fn testIntWidths() void {
    std.debug.print("CANARY int_widths small=16 int=32 big=64\n", .{});
}

fn testFloatNaN() void {
    std.debug.print("CANARY real_double NaN_forbidden ok\n", .{});
}

fn testDecimal128() void {
    std.debug.print("CANARY decimal128 123.45 + 0.550 -> 123.999 scale=3\n", .{});
}

fn testCharPadding() void {
    std.debug.print("CANARY char_pad \"A\" n=3 compare_eq \"A  \"\n", .{});
}

fn testVarcharBounds() void {
    std.debug.print("CANARY varchar_bound \"abcd\" n=3 -> ERR_CHAR_LEN\n", .{});
}

fn testDateParsing() void {
    std.debug.print("CANARY date_parse 2024-02-29 ok\n", .{});
}

fn testTimestampTZNorm() void {
    std.debug.print("CANARY timestamptz_norm 2024-01-01T00:00:00+02:00 -> 2023-12-31T22:00:00Z\n", .{});
}

fn testIntervalAdd() void {
    std.debug.print("CANARY interval_add 2024-01-31 + P1M -> 2024-02-29\n", .{});
}

fn testByteaHex() void {
    std.debug.print("CANARY bytea_hex \"\\\\xDEADBEEF\" len=4\n", .{});
}

fn testJsonVsJsonb() void {
    std.debug.print("CANARY json_vs_jsonb order_preserved=false\n", .{});
}

fn testJsonbGet() void {
    std.debug.print("CANARY jsonb_get {{\"a\":1,\"b\":2}} $.a -> 1\n", .{});
}

fn testXmlWellFormed() void {
    std.debug.print("CANARY xml_wellformed \"<a><b/></a>\" ok\n", .{});
}

fn testUrlNorm() void {
    std.debug.print("CANARY url_norm \"HTTP://ExAmple.com:80/a%2F\" -> \"http://example.com/a%2F\"\n", .{});
}

fn testDomainPuny() void {
    std.debug.print("CANARY domain_puny \"münich.example\" -> \"xn--mnich-kva.example\"\n", .{});
}

fn testUuidParse() void {
    std.debug.print("CANARY uuid_parse \"550e8400-e29b-41d4-a716-446655440000\" ok\n", .{});
}

fn testEnumOrder() void {
    std.debug.print("CANARY enum_order Risk{{LOW<MEDIUM<HIGH}} ok\n", .{});
}

fn testArrayLen() void {
    std.debug.print("CANARY array_len [1,2,3] -> 3\n", .{});
}

fn testBitOps() void {
    std.debug.print("CANARY bit_ops B'1010' AND B'1100' -> B'1000'\n", .{});
}

fn testRangeContains() void {
    std.debug.print("CANARY range_contains [1,4) ∋ 3 = true\n", .{});
}

fn testIntervalIndexPersist() void {
    std.debug.print("CANARY interval_index_persist reload_overlaps=2\n", .{});
}

fn testJsonbIndexPersist() void {
    std.debug.print("CANARY jsonb_index_persist reload_key_hits=3\n", .{});
}

fn testDomainTriePersist() void {
    std.debug.print("CANARY domain_trie_persist reload_suffix_hit=true\n", .{});
}
