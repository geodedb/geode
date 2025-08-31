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

pub const PlanError = error{ OffsetPushdownRequiresOrder, GroupByIllegal };

pub fn planQuery(q: ast.Query, opts: PlannerOptions) PlanError!Plan {
    const ordered = q.order_by != null;
    // Policy: do not allow OFFSET pushdown without an explicit order (US001)
    if (opts.attempt_pushdown and q.offset != null and !ordered) {
        return PlanError.OffsetPushdownRequiresOrder;
    }
    // Validate GROUP BY legality (phase 1)
    try validateGroupBy(q);
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

fn isAggregateCall(e: ast.Expr) bool {
    return switch (e) {
        .Call => |c| blk: {
            const callee = c.callee.*;
            const name = switch (callee) {
                .Ident => |s| s,
                else => break :blk false,
            };
            if (std.ascii.eqlIgnoreCase(name, "count")) break :blk true;
            if (std.ascii.eqlIgnoreCase(name, "sum")) break :blk true;
            if (std.ascii.eqlIgnoreCase(name, "avg")) break :blk true;
            if (std.ascii.eqlIgnoreCase(name, "min")) break :blk true;
            if (std.ascii.eqlIgnoreCase(name, "max")) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn validateGroupBy(q: ast.Query) PlanError!void {
    if (q.group_by == null) return;
    const gb = q.group_by.?;
    // Collect allowed identifiers from group-by keys (ident-only for phase 1)
    var allowed = std.AutoHashMap([]const u8, void).init(std.heap.page_allocator);
    defer allowed.deinit();
    for (gb.keys) |k| {
        if (k == .Ident) {
            _ = allowed.put(k.Ident, {}) catch {};
        }
    }
    // Require at least one allowed key if group_by present (simplify phase 1)
    if (allowed.count() == 0) return PlanError.GroupByIllegal;
    // Return items must be either aggregate calls or identifiers from allowed set (phase 1)
    for (q.ret.items) |it| {
        const e = it.expr;
        if (isAggregateCall(e)) continue;
        if (e == .Ident) {
            if (allowed.contains(e.Ident)) continue;
        }
        return PlanError.GroupByIllegal;
    }
    // HAVING, if present, must be an aggregate predicate or refer only to grouped identifiers (phase 1)
    if (q.having) |hv| {
        if (!exprAllowedInGroup(hv, &allowed)) return PlanError.GroupByIllegal;
    }
}

fn exprAllowedInGroup(e: ast.Expr, allowed: *std.AutoHashMap([]const u8, void)) bool {
    return switch (e) {
        .Int, .Bool, .Null, .String => true,
        .Ident => |s| allowed.contains(s),
        .Call => isAggregateCall(e),
        .Unary => |u| exprAllowedInGroup(u.expr.*, allowed),
        .Binary => |b| exprAllowedInGroup(b.left.*, allowed) and exprAllowedInGroup(b.right.*, allowed),
        else => false, // phase 1: be strict
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

test "planner: group by legality basic" {
    var q: ast.Query = undefined;
    q.optional_match = false;
    q.match = .{ .chains = &.{} };
    q.where_clause = null;
    q.with_clause = null;
    q.order_by = null;
    q.limit = null;
    q.offset = null;
    // GROUP BY n, RETURN n is legal
    var keys: [1]ast.Expr = .{.{ .Ident = "n" }};
    q.group_by = .{ .keys = keys[0..] };
    var items: [1]ast.ReturnItem = .{.{ .expr = .{ .Ident = "n" }, .alias = null }};
    q.ret = .{ .items = items[0..], .distinct = false };
    _ = try planQuery(q, .{});
    // Illegal: RETURN m (not grouped) without aggregate
    items[0] = .{ .expr = .{ .Ident = "m" }, .alias = null };
    q.ret = .{ .items = items[0..], .distinct = false };
    try std.testing.expectError(PlanError.GroupByIllegal, planQuery(q, .{}));
    // Legal: RETURN count(m)
    var callee = ast.Expr{ .Ident = "count" };
    var arg = ast.Expr{ .Ident = "m" };
    const call = ast.Expr{ .Call = .{ .callee = &callee, .args = &.{&arg} } };
    items[0] = .{ .expr = call, .alias = null };
    q.ret = .{ .items = items[0..], .distinct = false };
    _ = try planQuery(q, .{});
}

test "planner: having legality" {
    var q: ast.Query = undefined;
    q.optional_match = false;
    q.match = .{ .chains = &.{} };
    q.where_clause = null;
    q.with_clause = null;
    q.order_by = null;
    q.limit = null;
    q.offset = null;
    var keys: [1]ast.Expr = .{.{ .Ident = "n" }};
    q.group_by = .{ .keys = keys[0..] };
    var items: [1]ast.ReturnItem = .{.{ .expr = .{ .Ident = "n" }, .alias = null }};
    q.ret = .{ .items = items[0..], .distinct = false };
    // HAVING count(m) > 1 allowed
    var callee = ast.Expr{ .Ident = "count" };
    var arg = ast.Expr{ .Ident = "m" };
    var one = ast.Expr{ .Int = 1 };
    const call = ast.Expr{ .Call = .{ .callee = &callee, .args = &.{&arg} } };
    const pred = ast.Expr{ .Binary = .{ .op = .Gt, .left = &call, .right = &one } };
    q.having = pred;
    _ = try planQuery(q, .{});
    // HAVING m (non-grouped identifier) illegal
    q.having = .{ .Ident = "m" };
    try std.testing.expectError(PlanError.GroupByIllegal, planQuery(q, .{}));
}
