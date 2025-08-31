const std = @import("std");
const ast = @import("gql/ast.zig");
const temporal = @import("temporal.zig");

pub const PlannerOptions = struct {
    attempt_pushdown: bool = true,
};

pub const Plan = struct {
    ordered: bool,
    note: []const u8 = "",
};

pub const PlanError = error{OffsetPushdownRequiresOrder};

pub fn planQuery(q: ast.Query, opts: PlannerOptions) PlanError!Plan {
    const ordered = q.order_by != null;
    // Policy: do not allow OFFSET pushdown without an explicit order (US001)
    if (opts.attempt_pushdown and q.offset != null and !ordered) {
        return PlanError.OffsetPushdownRequiresOrder;
    }
    return .{ .ordered = ordered };
}

// Session context used for temporal comparison policies (e.g., how to interpret local datetimes)
pub const SessionContext = struct {
    // Offset applied when attaching to local datetimes for comparisons against zoned values.
    session_offset_minutes: i16 = 0,
};

pub const CompareError = temporal.TemporalError;

// Compare two temporal literal expressions for ORDER BY or filter semantics.
// Returns negative/zero/positive like strcmp: -1 if a<b, 0 if equal, 1 if a>b.
// Only handles DATE, TIME, DATETIME/LOCAL DATETIME literals; otherwise returns error.Invalid.
pub fn compareTemporalForOrder(a: ast.Expr, b: ast.Expr, ctx: SessionContext) CompareError!i8 {
    return switch (a) {
        .Date => |da| switch (b) {
            .Date => |db| temporal.compareDateParsed(da.parsed, db.parsed),
            else => CompareError.Invalid,
        },
        .Time => |ta| switch (b) {
            .Time => |tb| temporal.compareTimeParsed(ta.parsed, tb.parsed),
            else => CompareError.Invalid,
        },
        .DateTime => |dta| switch (b) {
            .DateTime => |dtb| blk: {
                const a_has = dta.parsed.time.offset_minutes != null;
                const b_has = dtb.parsed.time.offset_minutes != null;
                if (a_has and b_has) break :blk try temporal.compareDateTimeParsed(dta.parsed, dtb.parsed);
                if (!a_has and !b_has) break :blk try temporal.compareDateTimeParsed(dta.parsed, dtb.parsed);
                // Mismatch: attach session offset to the local one and compare
                if (!a_has and b_has) {
                    const a_att = temporal.attachSessionOffset(dta.parsed, ctx.session_offset_minutes);
                    break :blk try temporal.compareDateTimeParsed(a_att, dtb.parsed);
                } else if (a_has and !b_has) {
                    const b_att = temporal.attachSessionOffset(dtb.parsed, ctx.session_offset_minutes);
                    break :blk try temporal.compareDateTimeParsed(dta.parsed, b_att);
                }
                return CompareError.Invalid;
            },
            .LocalDateTime => |ldb| blk2: {
                const a_has = dta.parsed.time.offset_minutes != null;
                if (!a_has) {
                    // Both local; compare as local
                    break :blk2 try temporal.compareDateTimeParsed(dta.parsed, ldb.parsed);
                }
                // a is zoned, b is local: attach session offset to b
                const b_att = temporal.attachSessionOffset(ldb.parsed, ctx.session_offset_minutes);
                break :blk2 try temporal.compareDateTimeParsed(dta.parsed, b_att);
            },
            else => CompareError.Invalid,
        },
        .LocalDateTime => |lda| switch (b) {
            .LocalDateTime => |ldb| temporal.compareDateTimeParsed(lda.parsed, ldb.parsed),
            .DateTime => |dtb| blk3: {
                const b_has = dtb.parsed.time.offset_minutes != null;
                if (!b_has) break :blk3 try temporal.compareDateTimeParsed(lda.parsed, dtb.parsed);
                const a_att = temporal.attachSessionOffset(lda.parsed, ctx.session_offset_minutes);
                break :blk3 try temporal.compareDateTimeParsed(a_att, dtb.parsed);
            },
            else => CompareError.Invalid,
        },
        else => CompareError.Invalid,
    };
}

test "planner: temporal compare across timezones and local attach" {
    const ctx = SessionContext{ .session_offset_minutes = 0 };
    const dt1 = .{ .DateTime = .{ .raw = "2024-08-12T10:15Z", .parsed = try temporal.parseDateTime("2024-08-12T10:15Z", true) } };
    const dt2 = .{ .DateTime = .{ .raw = "2024-08-12T11:15+01", .parsed = try temporal.parseDateTime("2024-08-12T11:15+01", true) } };
    try std.testing.expect((try compareTemporalForOrder(dt1, dt2, ctx)) == 0);
    // Local vs zoned with session offset
    const ldt = .{ .LocalDateTime = .{ .raw = "2024-08-12T10:15", .parsed = try temporal.parseDateTime("2024-08-12T10:15", false) } };
    try std.testing.expect((try compareTemporalForOrder(ldt, dt1, ctx)) == 0);
}

test "planner: time compare invalid across zone mismatch" {
    const ctx = SessionContext{};
    const t1 = .{ .Time = .{ .raw = "10:15Z", .parsed = try temporal.parseTime("10:15Z", true) } };
    const t2 = .{ .Time = .{ .raw = "10:15", .parsed = try temporal.parseTime("10:15", true) } };
    try std.testing.expectError(CompareError.Invalid, compareTemporalForOrder(t1, t2, ctx));
}

test "planner: offset pushdown rejected without order" {
    var q: ast.Query = undefined;
    q.optional_match = false;
    q.match = .{ .chains = &.{} };
    q.where_clause = null;
    q.with_clause = null;
    q.group_by = null;
    q.ret = .{ .items = &.{}, .distinct = false };
    q.order_by = null;
    q.limit = null;
    q.offset = 5;
    try std.testing.expectError(PlanError.OffsetPushdownRequiresOrder, planQuery(q, .{ .attempt_pushdown = true }));
}

test "planner: offset allowed with explicit order" {
    var q: ast.Query = undefined;
    q.optional_match = false;
    q.match = .{ .chains = &.{} };
    q.where_clause = null;
    q.with_clause = null;
    q.group_by = null;
    q.ret = .{ .items = &.{}, .distinct = false };
    var keys: [1]ast.OrderBy.OrderKey = undefined;
    keys[0] = .{ .expr = .{ .Ident = "n" }, .desc = false };
    q.order_by = .{ .keys = keys[0..] };
    q.limit = null;
    q.offset = 5;
    const plan = try planQuery(q, .{ .attempt_pushdown = true });
    try std.testing.expect(plan.ordered);
}
