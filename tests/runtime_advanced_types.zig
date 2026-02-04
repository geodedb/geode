const std = @import("std");
const geode = @import("geode");
const value_types = geode.value_types;
const heap = geode.heap;
const eval = geode.eval;
const uuid = geode.types.uuid;
const url = geode.types.url;
const datetime = geode.types.datetime;
const type_promotion = geode.type_promotion;

test "Advanced Types Roundtrip" {
    // UUID
    const u = uuid.UUID.v4();
    const val_uuid = value_types.Value{ .UUID = u };
    const heap_uuid = type_promotion.evalValueToHeapValue(val_uuid);
    // heap.Value should be UUID
    switch (heap_uuid) {
        .UUID => |hu| try std.testing.expect(uuid.UUID.equal(u, hu)),
        else => return error.TestExpectedUUID,
    }
    const val_back = type_promotion.heapValueToEvalValue(heap_uuid);
    switch (val_back) {
        .UUID => |vu| try std.testing.expect(uuid.UUID.equal(u, vu)),
        else => return error.TestExpectedUUID,
    }

    // URL
    const url_val = try url.Url.parse("https://example.com");
    const val_url = value_types.Value{ .Url = url_val };
    const heap_url = type_promotion.evalValueToHeapValue(val_url);
    switch (heap_url) {
        .Url => |hu| try std.testing.expectEqualStrings(url_val.string, hu.string),
        else => return error.TestExpectedUrl,
    }

    // Equality Check (Eval)
    const eq = try eval.eqVals(val_uuid, val_back);
    try std.testing.expect(eq);

    // Date
    const d = datetime.Date{ .days_since_epoch = 100 };
    const val_date = value_types.Value{ .Date = d };
    const heap_date = type_promotion.evalValueToHeapValue(val_date);
    switch (heap_date) {
        .Date => |hd| try std.testing.expectEqual(d.days_since_epoch, hd.days_since_epoch),
        else => return error.TestExpectedDate,
    }
}
