// CANARY: REQ=REQ-SONNY-6586-PARAM-JSON-NO-LEAK; FEATURE="CliOptions"; ASPECT=ParamConversionFreesOnFailure; STATUS=TESTED; TEST=tests/test_sonny6586_param_json_alloc.zig; OWNER=cli; UPDATED=2026-11-15
//
// SONNY-6586 follow-up: `geode query --param <name> <json>` converts the
// JSON to a wire value (src/client/param_json.zig, which the MCP query
// tool uses too since SONNY-6647). A list or map that failed
// part-way (an allocation, or a value nested past PARAM_MAX_DEPTH) leaked
// the elements, keys and backing arrays built before the failure: there
// was no errdefer.
//
// Strategy: fail from allocation n = 0, 1, 2, ... of a nested list/map
// conversion (std.testing.FailingAllocator fails allocation n and every one
// after it) until one runs with no failure induced, each over its own
// DebugAllocator so a leak names the index; and a value too deep, after
// siblings were built.
const std = @import("std");
const testing = std.testing;
const param_json = @import("param_json");

const nested =
    \\{"name":"alice","tags":["a","b",{"k":"v","n":[1,2.5,null,true]}],"meta":{"x":{"y":["z"]}}}
;

test "SONNY-6586: a --param conversion that fails at any allocation frees what it built" {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, nested, .{});
    defer parsed.deinit();

    var leaked = std.ArrayList(usize).empty;
    defer leaked.deinit(testing.allocator);
    var clean = false;
    var n: usize = 0;
    while (n < 512) : (n += 1) {
        var backing = std.heap.DebugAllocator(.{}){};
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = n });
        const a = failing.allocator();
        const ok = blk: {
            var value = param_json.jsonToProtoValue(a, parsed.value, 0) catch |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                break :blk false;
            };
            value.deinit(a);
            break :blk true;
        };
        const induced = failing.has_induced_failure;
        if (backing.deinit() == .leak) try leaked.append(testing.allocator, n);
        if (ok and !induced) {
            clean = true;
            break;
        }
    }
    try testing.expect(clean);
    if (leaked.items.len != 0) {
        std.debug.print("SONNY-6586: --param conversion leaked when allocation {any} failed\n", .{leaked.items});
        return error.TestUnexpectedResult;
    }
}

test "SONNY-6586: a --param value nested too deep frees the siblings built before it" {
    // ["s", {"k":"v"}, [[[ ... 70 deep ... ]]]]: the string and the map are
    // built, then the third element is refused.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "[\"s\",{\"k\":\"v\"},");
    for (0..70) |_| try text.append(testing.allocator, '[');
    for (0..70) |_| try text.append(testing.allocator, ']');
    try text.append(testing.allocator, ']');
    // std.testing.allocator reports anything left behind.
    try testing.expectError(error.ParamsTooDeep, param_json.parseParamValue(testing.allocator, text.items));
}
