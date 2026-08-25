// ENG-3913 — date_part() used a different calendar from member access, and in
// practice could not be called at all.
//
// VERIFIED READ-ONLY AGAINST v0.8.5 / 13836738 BEFORE THE FIX — TWO defects, one
// stacked on the other:
//
//   (1) THE BRIDGE.  src/eval_extended.zig's `toBuiltin` mapped every temporal
//       ExtValue through its `else => Null` catch-all, so the second argument
//       arrived at fn_date_part as NULL and the function bailed out:
//
//           RETURN date_part('year', date('2024-12-31'))        -> error.TypeMismatch
//           RETURN date_part('month', date('2024-12-31'))       -> error.TypeMismatch
//           RETURN time_part('hour', time('10:11:12'))          -> error.TypeMismatch
//
//       date_part / time_part were unreachable from GQL for their entire
//       documented input domain. Only the in-module unit test, which builds a
//       BuiltinValue directly, ever exercised them.
//
//   (2) THE ARITHMETIC.  src/types/extended_functions.zig:129 derived the
//       components as `1970 + days/365` with 30-day months:
//
//           year  = 1970 + days/365
//           month = (days % 365)/30 + 1        <- can reach 13
//           day   = (days % 365)%30 + 1
//
//       while member access (`date('2024-12-31').month`) already went through
//       the calendar-exact datetime.Date.dateFromDays and answered 12 / 31.
//       Two different calendars for the same value, disagreeing by days at every
//       leap year and by a whole month by December.
//
// WHAT THESE TESTS PIN (contract, not implementation):
//
//   date_part('year'|'month'|'day', d) == d.year | d.month | d.day, for the same
//   `d`, on boundary dates — the last day of a leap year, the leap day itself,
//   the day either side of a year boundary, the epoch, and a pre-epoch date.
//   The member-access result is the reference because it was already correct;
//   the test compares the TWO ENGINE ANSWERS rather than hard-coded constants,
//   so the two can never drift apart again.
//
// CANARY: REQ=REQ-ENG-3913-DATE-PART-EXACT-CALENDAR; FEATURE="ExtendedBuiltins"; ASPECT=FUNCTION_DATE_PART; STATUS=TESTED; TEST=tests/test_eng3913_date_part_calendar.zig; OWNER=engine; UPDATED=2026-08-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .session = execution.SessionState.init(allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.arena.deinit();
        self.tmp.cleanup();
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    pub fn scalarInt(self: *Harness, query: []const u8) !i64 {
        const res = try self.exec(query);
        if (res.rows.len == 0 or res.rows[0].len == 0) return error.NoRows;
        return switch (res.rows[0][0]) {
            .Int => |i| i,
            else => |v| {
                std.debug.print("\n[ENG-3913] {s} returned {s}, expected Int\n", .{ query, @tagName(v) });
                return error.NotAnInt;
            },
        };
    }
};

/// Boundary dates chosen so that the OLD 365-day-year / 30-day-month arithmetic
/// is wrong on every single one of them.
const boundary_dates = [_][]const u8{
    "1970-01-01", // the epoch itself
    "1970-12-31", // last day of the epoch year
    "1971-01-01", // first day after a full year
    "2000-02-29", // leap day in a century-leap year
    "2023-12-31", // last day of a common year
    "2024-01-01", // first day of a leap year
    "2024-02-28", // day before the leap day
    "2024-02-29", // the leap day
    "2024-03-01", // day after the leap day
    "2024-12-31", // last day of a leap year — 366 days in
    "2025-01-01", // first day after a leap year
    "2100-03-01", // 2100 is NOT a leap year (century rule)
};

test "ENG-3913: date_part agrees with member access on boundary dates" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    _ = try h.exec("CREATE GRAPH eng3913");
    _ = try h.exec("USE GRAPH eng3913");

    // Accumulate every mismatch so one RED run enumerates the whole calendar
    // disagreement instead of stopping at the first date.
    var failures: std.ArrayListUnmanaged([]const u8) = .empty;

    const parts = [_][]const u8{ "year", "month", "day" };
    for (boundary_dates) |date_lit| {
        for (parts) |part| {
            const via_fn = try std.fmt.allocPrint(
                gpa,
                "RETURN date_part('{s}', date('{s}'))",
                .{ part, date_lit },
            );
            const via_member = try std.fmt.allocPrint(
                gpa,
                "RETURN date('{s}').{s}",
                .{ date_lit, part },
            );

            const want = h.scalarInt(via_member) catch |err| {
                try failures.append(gpa, try std.fmt.allocPrint(
                    gpa,
                    "reference (member access) failed with {s}: {s}",
                    .{ @errorName(err), via_member },
                ));
                continue;
            };
            const got = h.scalarInt(via_fn) catch |err| {
                try failures.append(gpa, try std.fmt.allocPrint(
                    gpa,
                    "date_part failed with {s}: {s} (member access says {d})",
                    .{ @errorName(err), via_fn, want },
                ));
                continue;
            };
            if (got != want) {
                try failures.append(gpa, try std.fmt.allocPrint(
                    gpa,
                    "calendar disagreement on {s}: date_part('{s}') = {d} but date('{s}').{s} = {d}",
                    .{ date_lit, part, got, date_lit, part, want },
                ));
            }
        }
    }

    if (failures.items.len != 0) {
        std.debug.print("\n[ENG-3913] {d} date_part calendar violation(s):\n", .{failures.items.len});
        for (failures.items) |f| std.debug.print("  - {s}\n", .{f});
        return error.DatePartCalendarMismatch;
    }
}

test "ENG-3913: date_part returns the exact calendar components (absolute values)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3913_abs");
    _ = try h.exec("USE GRAPH eng3913_abs");

    // Absolute pins, independent of the member-access reference, so a fix that
    // broke BOTH sides in the same direction cannot pass the agreement test
    // above silently.
    //
    // Under the OLD arithmetic 2024-12-31 (epoch day 20088) produced
    // year=1970+20088/365=2025, month=(20088%365)/30+1=13, day=(20088%365)%30+1=6.
    try testing.expectEqual(@as(i64, 2024), try h.scalarInt("RETURN date_part('year', date('2024-12-31'))"));
    try testing.expectEqual(@as(i64, 12), try h.scalarInt("RETURN date_part('month', date('2024-12-31'))"));
    try testing.expectEqual(@as(i64, 31), try h.scalarInt("RETURN date_part('day', date('2024-12-31'))"));
    try testing.expectEqual(@as(i64, 366), try h.scalarInt("RETURN date_part('doy', date('2024-12-31'))"));

    try testing.expectEqual(@as(i64, 2024), try h.scalarInt("RETURN date_part('year', date('2024-02-29'))"));
    try testing.expectEqual(@as(i64, 2), try h.scalarInt("RETURN date_part('month', date('2024-02-29'))"));
    try testing.expectEqual(@as(i64, 29), try h.scalarInt("RETURN date_part('day', date('2024-02-29'))"));
    try testing.expectEqual(@as(i64, 60), try h.scalarInt("RETURN date_part('doy', date('2024-02-29'))"));

    // A common year has 365 days; the leap year above has 366. If the two ever
    // agree, the leap rule has been lost again.
    try testing.expectEqual(@as(i64, 365), try h.scalarInt("RETURN date_part('doy', date('2023-12-31'))"));

    // The epoch.
    try testing.expectEqual(@as(i64, 1970), try h.scalarInt("RETURN date_part('year', date('1970-01-01'))"));
    try testing.expectEqual(@as(i64, 1), try h.scalarInt("RETURN date_part('month', date('1970-01-01'))"));
    try testing.expectEqual(@as(i64, 1), try h.scalarInt("RETURN date_part('day', date('1970-01-01'))"));
    try testing.expectEqual(@as(i64, 1), try h.scalarInt("RETURN date_part('doy', date('1970-01-01'))"));

    // 2100 is a century year that is NOT a leap year — the rule the "/365"
    // approximation could never express.
    try testing.expectEqual(@as(i64, 3), try h.scalarInt("RETURN date_part('month', date('2100-03-01'))"));
    try testing.expectEqual(@as(i64, 1), try h.scalarInt("RETURN date_part('day', date('2100-03-01'))"));
}

test "ENG-3913: time_part is reachable from GQL and reports exact clock components" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3913_time");
    _ = try h.exec("USE GRAPH eng3913_time");

    // time_part shared defect (1) with date_part — the temporal bridge nulled
    // its argument, so every call raised TypeMismatch. Its arithmetic was
    // already exact, so these pin only that it is REACHABLE and still correct.
    try testing.expectEqual(@as(i64, 10), try h.scalarInt("RETURN time_part('hour', time('10:11:12'))"));
    try testing.expectEqual(@as(i64, 11), try h.scalarInt("RETURN time_part('minute', time('10:11:12'))"));
    try testing.expectEqual(@as(i64, 12), try h.scalarInt("RETURN time_part('second', time('10:11:12'))"));

    // Midnight and the last second of the day — the wrap-around boundaries.
    try testing.expectEqual(@as(i64, 0), try h.scalarInt("RETURN time_part('hour', time('00:00:00'))"));
    try testing.expectEqual(@as(i64, 23), try h.scalarInt("RETURN time_part('hour', time('23:59:59'))"));
    try testing.expectEqual(@as(i64, 59), try h.scalarInt("RETURN time_part('minute', time('23:59:59'))"));
    try testing.expectEqual(@as(i64, 59), try h.scalarInt("RETURN time_part('second', time('23:59:59'))"));
}
