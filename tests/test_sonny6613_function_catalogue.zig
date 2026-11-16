// SONNY-6613 item 5 (catalogue part): the function catalogue names the
// functions the evaluator answers to.
//
// `src/gql/language_metadata.zig` is the catalogue SHOW FUNCTIONS, the LSP
// (completion, hover, signature help) and the MCP server read, and the
// evaluator consults it to tell a wrong number of arguments (42000) from an
// unknown function. `st_point`, `ipaddr` and `url_host` are evaluated (the
// extension registry, `eval_extended.zig`, and the built-ins,
// `eval/call_handlers.zig`) but were not in it. For each, and for `nullif`
// (listed as `nullIf`, found case-insensitively): the catalogue has it, with
// as many parameters as the evaluator takes, and its example evaluates.
//
// Not done here (SONNY-6613 item 5 proper): one comptime arity table read by
// the dispatcher and a bind-time check; see the SONNY-6613 report.
//
// CANARY: REQ=REQ-SONNY-6613-FUNCTION-CATALOGUE; FEATURE="FunctionCatalogue"; ASPECT=EvaluatedFunctionsListed; STATUS=TESTED; TEST=tests/test_sonny6613_function_catalogue.zig; OWNER=gql; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const vs = @import("value_semantics_harness.zig");

const metadata = geode.language_metadata;

const Entry = struct { name: []const u8, arity: usize, call: []const u8, want: []const u8 };

const entries = [_]Entry{
    .{ .name = "st_point", .arity = 2, .call = "RETURN st_x(st_point(1, 2)) AS x", .want = "1.000000m" },
    .{ .name = "ipaddr", .arity = 1, .call = "RETURN ip_family(ipaddr('10.0.0.1')) AS x", .want = "'IPv4'" },
    .{ .name = "url_host", .arity = 1, .call = "RETURN toString(url_host(url('https://example.com/a'))) AS x", .want = "'example.com'" },
    .{ .name = "nullif", .arity = 2, .call = "RETURN nullif(1, 1) AS x", .want = "null" },
};

test "SONNY-6613: st_point, ipaddr, url_host and nullif are in the function catalogue, with their arity" {
    for (entries) |e| {
        const info = metadata.findFunction(e.name) orelse {
            std.debug.print("{s} is not in src/gql/language_metadata.zig\n", .{e.name});
            return error.NotInCatalogue;
        };
        try testing.expectEqual(e.arity, info.params.len);
        try testing.expect(info.example != null);
    }
}

fn checkEvaluated(s: *vs.Session, f: *vs.Failures) !void {
    for (entries) |e| {
        try vs.expectValue(s, f, e.call, &.{}, e.want);
        // One argument too many is the arity error (42000), not "unknown function".
        var buf: [96]u8 = undefined;
        var args: std.ArrayList(u8) = .empty;
        defer args.deinit(testing.allocator);
        for (0..e.arity + 1) |i| try args.appendSlice(testing.allocator, if (i == 0) "1" else ", 1");
        try vs.expectFail(s, f, try std.fmt.bufPrint(&buf, "RETURN {s}({s}) AS x", .{ e.name, args.items }), &.{}, error.WrongArgumentCount);
    }
    // Each catalogue example evaluates.
    for (entries) |e| {
        const info = metadata.findFunction(e.name) orelse {
            try f.add("{s} is not in the catalogue", .{e.name});
            continue;
        };
        var r = s.run(info.example.?, &.{}) catch |err| {
            try f.add("[{s}] example of {s} ({s}): {s}", .{ @tagName(s.mode), e.name, info.example.?, @errorName(err) });
            continue;
        };
        r.deinit(s.arena.allocator());
    }
}

test "SONNY-6613: the catalogued st_point, ipaddr, url_host and nullif evaluate as listed" {
    try vs.inModes("function catalogue", &.{.in_memory}, checkEvaluated);
}
