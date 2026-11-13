// SONNY-6449 regression: the ownership of a member read (`n.p`) and of the
// row values every projection path builds from it.
//
// SONNY-6327 made a member read of a stored string go through the field
// level encryption (FLE) read policy, which returns the stored bytes or, for
// an encrypted field, the decrypted (or "[REDACTED]") string it allocated.
// The projection paths treat a member read as borrowed (the store's bytes):
// the legacy RETURN projection, the WITH stage, the WITH ORDER BY comparator
// and VALUES ... MATCH keep it in rows they do not free, so the allocated
// form leaked once per row (and per comparison) on an embedded caller, the
// one without a per-request scratch arena; a caller that freed it would have
// freed the store's bytes for a plain field.
//
// Every projection path is driven through the real executor with a real FLE
// catalog and key, for a plain string field, an encrypted field read in
// plaintext (role `pii`), an encrypted field read redacted (no role), a list
// field, and list comprehensions. Each query runs on a counting allocator
// over `std.testing.allocator` (a double free or an invalid free fails the
// test), with and without a scratch arena installed as the transports
// install one, and its result is checked: a value that came from freed
// memory would not read back as the stored or decrypted string. No mocks.
//
// CANARY: REQ=REQ-SONNY-6449-MEMBER-READ-OWNERSHIP; FEATURE="ExpressionEvaluator"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6449_projection_value_ownership.zig; OWNER=eval; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const logging = @import("logging");

const graph_store = geode.graph_store;
const execution = geode.execution;
const index_manager = geode.index_manager;
const fle_integration = geode.fle_integration;
const fle_catalog = fle_integration.catalog_mod;
const query_arena = geode.query_arena;
const node_scan_stream = geode.node_scan_stream;
const Value = geode.value_types.Value;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const master_key = "6449a6449a6449a6449a6449a6449a6449a6449a6449a6449a6449a6449a6449";

const SavedEnv = struct {
    name: [:0]const u8,
    value: ?[:0]u8,

    fn take(name: [:0]const u8) !SavedEnv {
        const v: ?[:0]u8 = if (std.c.getenv(name.ptr)) |p| try testing.allocator.dupeZ(u8, std.mem.span(p)) else null;
        return .{ .name = name, .value = v };
    }

    fn restore(self: SavedEnv) void {
        if (self.value) |v| {
            _ = setenv(self.name.ptr, v.ptr, 1);
            testing.allocator.free(v);
        } else _ = unsetenv(self.name.ptr);
    }
};

/// Where the graph lives: in memory (the executor's paths), or persisted in
/// a data directory, where the storage adapter and the planned read runtime
/// serve reads.
const Store = enum { memory, persisted };

/// An executor with FLE configured on `S6449P.ssn` and `S6449W.ssn`,
/// readable in plaintext by role `pii` only.
const Fixture = struct {
    tmp: ?std.testing.TmpDir,
    data_dir: ?[]u8,
    env_data_dir: SavedEnv,
    env_key: SavedEnv,
    arena: std.heap.ArenaAllocator,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    fn init(self: *Fixture, store: Store) !void {
        logging.init(.{ .level = .fatal });
        logging.setLevel(.fatal);
        self.env_data_dir = try SavedEnv.take("GEODE_DATA_DIR");
        self.env_key = try SavedEnv.take("GEODE_MASTER_KEY");
        _ = unsetenv("GEODE_DATA_DIR");
        fle_catalog.setDataDirOverride(null);
        fle_catalog.resetGlobalCatalog(testing.allocator);
        fle_integration.setHasEncryptedFields(false);
        fle_integration.resetGlobalKeyStateForTesting();
        _ = setenv("GEODE_MASTER_KEY", master_key, 1);
        const catalog = try fle_catalog.globalCatalog(testing.allocator);
        var roles = [_][]const u8{"pii"};
        try catalog.configureField("S6449P", .{ .field_name = "ssn", .encryption = .{ .enabled = true }, .visibility = .{ .to_roles = &roles } });
        try catalog.configureField("S6449W", .{ .field_name = "ssn", .encryption = .{ .enabled = true }, .visibility = .{ .to_roles = &roles } });

        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        self.tmp = null;
        self.data_dir = null;
        if (store == .persisted) {
            self.tmp = std.testing.tmpDir(.{});
            self.data_dir = try tmpDirRealpathAlloc(testing.allocator, &self.tmp.?.sub_path);
            graph_store.setDataDirOverride(testing.allocator, self.data_dir.?);
        }
        _ = graph_store.getGlobalStore(testing.allocator);
        if (store == .persisted and graph_store.getGlobalAdapter() == null) return error.ExpectedPersistedAdapter;
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.session = execution.SessionState.init(testing.allocator);
        self.ctx = .{ .catalog = try execution.ensureCatalogInstance(testing.allocator) };
        self.ctx.session_state = &self.session;

        // Three nodes, so a DISTINCT, a GROUP BY and an ORDER BY have work:
        // i = 0, 1, 2 hold the values of key 0, 1, 0.
        for (0..3) |i| {
            const k = i % 2;
            const q = try std.fmt.allocPrint(self.arena.allocator(), "CREATE (:S6449P {{i: {d}, s: 'plain-{d}', ssn: 'secret-{d}', v: ['a', 'b{d}']}})", .{ i, k, k, k });
            var r = try self.exec(self.arena.allocator(), "pii", q);
            r.deinit(self.arena.allocator());
        }
    }

    fn deinit(self: *Fixture) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        if (self.data_dir) |d| testing.allocator.free(d);
        if (self.tmp) |*t| t.cleanup();
        self.arena.deinit();
        fle_catalog.setDataDirOverride(null);
        fle_catalog.resetGlobalCatalog(testing.allocator);
        fle_integration.setHasEncryptedFields(false);
        fle_integration.resetGlobalKeyStateForTesting();
        self.env_key.restore();
        self.env_data_dir.restore();
    }

    fn exec(self: *Fixture, allocator: std.mem.Allocator, role: ?[]const u8, query: []const u8) !execution.ExecutionResult {
        self.ctx.fle_role = role;
        fle_integration.setCurrentUserRole(role);
        defer fle_integration.clearCurrentThreadState();
        var parsed = try geode.parseGqlOptions(query, self.arena.allocator(), .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(allocator, parsed.program.statements[0], self.ctx);
    }
};

/// How a field reads back: its value for key 0, key 1 and the written key.
const Field = struct {
    name: []const u8,
    role: ?[]const u8,
    v0: []const u8,
    v1: []const u8,
    vw: []const u8,
    /// The literal a CREATE writes.
    write: []const u8,
};

const fields = [_]Field{
    .{ .name = "s", .role = null, .v0 = "plain-0", .v1 = "plain-1", .vw = "plain-w", .write = "plain-w" },
    .{ .name = "ssn", .role = "pii", .v0 = "secret-0", .v1 = "secret-1", .vw = "secret-w", .write = "secret-w" },
    .{ .name = "ssn", .role = null, .v0 = "[REDACTED]", .v1 = "[REDACTED]", .vw = "[REDACTED]", .write = "secret-w" },
};

/// A projection path: `{f}` is the field, `{w}` the written literal; the
/// first column of the result, sorted, is `want` with `0`, `1`, `w` read as
/// the field's values for those keys.
/// `distinct`: the rows are one per distinct value (a redacted field reads
/// the same for every key).
const Case = struct { q: []const u8, want: []const u8, distinct: bool = false };

const cases = [_]Case{
    // Plain RETURN, RETURN DISTINCT, GROUP BY key (implicit and explicit),
    // ORDER BY key (item and expression).
    .{ .q = "MATCH (n:S6449P) RETURN n.{f} AS x", .want = "001" },
    .{ .q = "MATCH (n:S6449P) RETURN DISTINCT n.{f} AS x", .want = "01", .distinct = true },
    .{ .q = "MATCH (n:S6449P) RETURN n.{f} AS x, count(*) AS c GROUP BY x", .want = "01", .distinct = true },
    .{ .q = "MATCH (n:S6449P) RETURN n.{f} AS x ORDER BY x", .want = "001" },
    .{ .q = "MATCH (n:S6449P) RETURN n.{f} AS x ORDER BY n.{f} DESC", .want = "001" },
    .{ .q = "MATCH (n:S6449P) RETURN n.{f} AS x ORDER BY n.i", .want = "001" },
    // WITH, WITH DISTINCT, WITH ORDER BY, a GROUP BY after WITH.
    .{ .q = "MATCH (n:S6449P) WITH n.{f} AS x RETURN x", .want = "001" },
    .{ .q = "MATCH (n:S6449P) WITH DISTINCT n.{f} AS x RETURN x", .want = "01", .distinct = true },
    .{ .q = "MATCH (n:S6449P) WITH n ORDER BY n.{f} RETURN n.{f} AS x", .want = "001" },
    .{ .q = "MATCH (n:S6449P) WITH n.{f} AS x ORDER BY x RETURN x", .want = "001" },
    .{ .q = "MATCH (n:S6449P) WITH n.{f} AS x ORDER BY x LIMIT 2 RETURN x", .want = "00" },
    .{ .q = "MATCH (n:S6449P) WITH n.{f} AS x RETURN x, count(*) AS c GROUP BY x", .want = "01", .distinct = true },
    .{ .q = "MATCH (n:S6449P) WITH n, n.{f} AS y RETURN n.{f} AS x", .want = "001" },
    // VALUES ... MATCH.
    .{ .q = "VALUES (0), (1) AS (k) MATCH (n:S6449P) WHERE n.i = k RETURN n.{f} AS x", .want = "01" },
    // CALL ... YIELD ... RETURN.
    .{ .q = "MATCH (n:S6449P {i: 1}) CALL db.labels() YIELD label RETURN n.{f} AS x, label ORDER BY label LIMIT 1", .want = "1" },
    // CREATE ... RETURN, MERGE ... RETURN.
    .{ .q = "CREATE (n:S6449W {{{f}: '{w}'}}) RETURN n.{f} AS x", .want = "w" },
    .{ .q = "MERGE (n:S6449P {i: 1}) RETURN n.{f} AS x", .want = "1" },
    .{ .q = "MATCH (n:S6449P {i: 1}) MERGE (m:S6449W {k: 1}) RETURN n.{f} AS x", .want = "1" },
    // A list comprehension over the member read.
    .{ .q = "MATCH (n:S6449P) RETURN [y IN [n.{f}] | y][0] AS x", .want = "001" },
    .{ .q = "MATCH (n:S6449P) WITH [y IN [n.{f}, n.{f}] WHERE y IS NOT NULL | y] AS l RETURN l[0] AS x", .want = "001" },
};

fn expand(allocator: std.mem.Allocator, template: []const u8, field: Field) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (std.mem.startsWith(u8, template[i..], "{f}")) {
            try out.appendSlice(allocator, field.name);
            i += 3;
        } else if (std.mem.startsWith(u8, template[i..], "{w}")) {
            try out.appendSlice(allocator, field.write);
            i += 3;
        } else if (std.mem.startsWith(u8, template[i..], "{{")) {
            try out.append(allocator, '{');
            i += 2;
        } else if (std.mem.startsWith(u8, template[i..], "}}")) {
            try out.append(allocator, '}');
            i += 2;
        } else {
            try out.append(allocator, template[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The first column of `rows` must be `want` (sorted, keys read as
/// `field`'s values).
fn checkStrings(allocator: std.mem.Allocator, rows: []const []Value, want: []const u8, distinct: bool, field: Field, what: []const u8) !void {
    const all = try allocator.alloc([]const u8, want.len);
    for (want, all) |k, *e| e.* = switch (k) {
        '0' => field.v0,
        '1' => field.v1,
        else => field.vw,
    };
    std.mem.sort([]const u8, all, {}, lessThanStr);
    var kept: usize = 0;
    for (all, 0..) |e, i| {
        if (distinct and i > 0 and std.mem.eql(u8, e, all[i - 1])) continue;
        all[kept] = e;
        kept += 1;
    }
    const expected = all[0..kept];
    const got = try allocator.alloc([]const u8, rows.len);
    for (rows, got) |row, *g| g.* = switch (row[0]) {
        .Str => |s| s,
        else => |v| {
            std.debug.print("{s}: a {s} cell\n", .{ what, @tagName(v) });
            return error.UnexpectedValue;
        },
    };
    std.mem.sort([]const u8, got, {}, lessThanStr);
    if (got.len != expected.len) {
        std.debug.print("{s}: {d} rows, expected {d}\n", .{ what, got.len, expected.len });
        return error.WrongRows;
    }
    for (got, expected) |g, e| if (!std.mem.eql(u8, g, e)) {
        std.debug.print("{s}: got '{f}', expected '{s}'\n", .{ what, std.zig.fmtString(g), e });
        return error.WrongValue;
    };
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..cwd_len], tmp_sub_path });
}

const Mode = enum { embedded, scratch };

/// Run `query` on a counting allocator over the testing allocator; return
/// how many of its allocations were never freed after `check` and deinit.
fn leaksOf(
    fx: *Fixture,
    mode: Mode,
    role: ?[]const u8,
    query: []const u8,
    ctx: anytype,
    comptime check: fn (@TypeOf(ctx), []const []Value) anyerror!void,
) !usize {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const prev = if (mode == .scratch) query_arena.pushScratchAllocator(scratch.allocator()) else null;
    defer if (mode == .scratch) query_arena.popScratchAllocator(prev);

    var counting = std.testing.FailingAllocator.init(testing.allocator, .{});
    const ca = counting.allocator();
    var result = fx.exec(ca, role, query) catch |err| {
        std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
        return err;
    };
    {
        // The result is read while the scratch arena is still installed (as
        // a transport encodes it), then freed.
        defer result.deinit(ca);
        try check(ctx, result.rows);
    }
    return counting.allocations - counting.deallocations;
}

const StringCheck = struct { arena: std.mem.Allocator, want: []const u8, distinct: bool, field: Field, what: []const u8 };

fn checkStringCase(c: StringCheck, rows: []const []Value) anyerror!void {
    try checkStrings(c.arena, rows, c.want, c.distinct, c.field, c.what);
}

fn runFieldCases(store: Store, mode: Mode) !void {
    var fx: Fixture = undefined;
    try fx.init(store);
    defer fx.deinit();
    const aa = fx.arena.allocator();

    var failures: usize = 0;
    for (fields) |field| {
        for (cases) |case| {
            const q = try expand(aa, case.q, field);
            const what = try std.fmt.allocPrint(aa, "[{s} {s} {s} role={s}] {s}", .{ @tagName(store), @tagName(mode), field.name, field.role orelse "none", q });
            const leaked = leaksOf(&fx, mode, field.role, q, StringCheck{ .arena = aa, .want = case.want, .distinct = case.distinct, .field = field, .what = what }, checkStringCase) catch |err| {
                std.debug.print("FAIL {s}: {s}\n", .{ what, @errorName(err) });
                failures += 1;
                continue;
            };
            if (leaked != 0) {
                std.debug.print("LEAK {s}: {d} allocations\n", .{ what, leaked });
                failures += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6449: every projection path owns the member reads it returns, plain and FLE: in memory, embedded (no scratch arena)" {
    try runFieldCases(.memory, .embedded);
}

test "SONNY-6449: every projection path owns the member reads it returns, plain and FLE: in memory, with a request scratch arena" {
    try runFieldCases(.memory, .scratch);
}

test "SONNY-6449: every projection path owns the member reads it returns, plain and FLE: persisted, embedded (no scratch arena)" {
    try runFieldCases(.persisted, .embedded);
}

test "SONNY-6449: every projection path owns the member reads it returns, plain and FLE: persisted, with a request scratch arena" {
    try runFieldCases(.persisted, .scratch);
}

/// A list property, and expressions that build lists: the first cell,
/// rendered.
const ListCase = struct { q: []const u8, want: []const []const u8 };

const list_cases = [_]ListCase{
    .{ .q = "MATCH (n:S6449P) RETURN n.v AS x", .want = &.{ "[a,b0]", "[a,b0]", "[a,b1]" } },
    .{ .q = "MATCH (n:S6449P) RETURN DISTINCT n.v AS x", .want = &.{ "[a,b0]", "[a,b1]" } },
    .{ .q = "MATCH (n:S6449P) RETURN n.v AS x, count(*) AS c GROUP BY x", .want = &.{ "[a,b0]", "[a,b1]" } },
    .{ .q = "MATCH (n:S6449P) RETURN n.v AS x ORDER BY x", .want = &.{ "[a,b0]", "[a,b0]", "[a,b1]" } },
    .{ .q = "MATCH (n:S6449P) WITH n.v AS x RETURN x", .want = &.{ "[a,b0]", "[a,b0]", "[a,b1]" } },
    .{ .q = "MATCH (n:S6449P) WITH DISTINCT n.v AS x RETURN x", .want = &.{ "[a,b0]", "[a,b1]" } },
    .{ .q = "MATCH (n:S6449P) WITH n.v AS x ORDER BY x RETURN x", .want = &.{ "[a,b0]", "[a,b0]", "[a,b1]" } },
    .{ .q = "MATCH (n:S6449P) WITH DISTINCT n.v AS v, n.i AS i RETURN count(*) AS x", .want = &.{"3"} },
    .{ .q = "MATCH (n:S6449P) WITH DISTINCT n.v AS v RETURN v AS x, count(*) AS c GROUP BY x", .want = &.{ "[a,b0]", "[a,b1]" } },
    .{ .q = "MATCH (n:S6449P) WITH n.v AS v RETURN count(DISTINCT v) AS x", .want = &.{"2"} },
    .{ .q = "MATCH (n:S6449P) RETURN [y IN n.v | y] AS x", .want = &.{ "[a,b0]", "[a,b0]", "[a,b1]" } },
    .{ .q = "MATCH (n:S6449P) RETURN [y IN n.v WHERE y <> 'a' | y || '!'] AS x", .want = &.{ "[b0!]", "[b0!]", "[b1!]" } },
    .{ .q = "VALUES (['q', 'r']) AS (k) MATCH (n:S6449P {i: 1}) RETURN n.v AS x", .want = &.{"[a,b1]"} },
    .{ .q = "RETURN [x IN [1] | sum([1, 2])] AS x", .want = &.{"[3]"} },
    .{ .q = "RETURN [x IN [1, 2] | [x, x]] AS x", .want = &.{"[[1,1],[2,2]]"} },
    // Values a projection computes from a member read.
    .{ .q = "MATCH (n:S6449P) RETURN n.s || '!' AS x", .want = &.{ "plain-0!", "plain-0!", "plain-1!" } },
    .{ .q = "MATCH (n:S6449P) RETURN DISTINCT n.s || '!' AS x", .want = &.{ "plain-0!", "plain-1!" } },
    .{ .q = "MATCH (n:S6449P) RETURN [n.s, n.ssn] AS x", .want = &.{ "[plain-0,[REDACTED]]", "[plain-0,[REDACTED]]", "[plain-1,[REDACTED]]" } },
    .{ .q = "MATCH (n:S6449P) RETURN n.s AS x ORDER BY upper(n.ssn), n.s || 'z'", .want = &.{ "plain-0", "plain-0", "plain-1" } },
    .{ .q = "MATCH (n:S6449P) WITH n.s || '!' AS x RETURN x", .want = &.{ "plain-0!", "plain-0!", "plain-1!" } },
    .{ .q = "MATCH (n:S6449P) WITH n ORDER BY upper(n.ssn), n.s || 'z' RETURN n.s AS x", .want = &.{ "plain-0", "plain-0", "plain-1" } },
    .{ .q = "MATCH (n:S6449P) WITH [n.s, n.ssn] AS l RETURN l AS x", .want = &.{ "[plain-0,[REDACTED]]", "[plain-0,[REDACTED]]", "[plain-1,[REDACTED]]" } },
    .{ .q = "VALUES ('a' || 'b') AS (k) MATCH (n:S6449P {i: 1}) RETURN n.s || k AS x", .want = &.{"plain-1ab"} },
    .{ .q = "MATCH (n:S6449P {i: 1}) CALL db.labels() YIELD label RETURN [n.s, n.ssn] AS x ORDER BY label LIMIT 1", .want = &.{"[plain-1,[REDACTED]]"} },
    // A call the projection used to adopt as the result's own string.
    .{ .q = "MATCH (n:S6449P) RETURN upper(n.s) AS x", .want = &.{ "PLAIN-0", "PLAIN-0", "PLAIN-1" } },
    .{ .q = "MATCH (n:S6449P) RETURN upper(max(n.s)) AS x", .want = &.{"PLAIN-1"} },
    .{ .q = "MATCH (n:S6449P) RETURN upper(n.s) AS x, count(*) AS c GROUP BY x", .want = &.{ "PLAIN-0", "PLAIN-1" } },
    .{ .q = "MATCH (n:S6449P) WITH upper(n.s) AS x RETURN x", .want = &.{ "PLAIN-0", "PLAIN-0", "PLAIN-1" } },
    .{ .q = "MATCH (n:S6449P) WITH n.s AS s, count(*) AS c RETURN upper(s) || '!' AS x GROUP BY x", .want = &.{ "PLAIN-0!", "PLAIN-1!" } },
    .{ .q = "RETURN upper('a') || lower('B') AS x", .want = &.{"Ab"} },
    .{ .q = "CREATE (n:S6449W {s: 'c'}) RETURN upper(n.s) || '!' AS x", .want = &.{"C!"} },
    .{ .q = "MATCH (n:S6449P) RETURN n.s AS x ORDER BY upper(n.s) || 'z' DESC", .want = &.{ "plain-0", "plain-0", "plain-1" } },
};

fn render(allocator: std.mem.Allocator, out: *std.ArrayList(u8), v: Value) !void {
    switch (v) {
        .Str => |s| try out.appendSlice(allocator, s),
        .Int => |i| try out.print(allocator, "{d}", .{i}),
        .List => |items| {
            try out.append(allocator, '[');
            for (items, 0..) |item, i| {
                if (i > 0) try out.append(allocator, ',');
                try render(allocator, out, item);
            }
            try out.append(allocator, ']');
        },
        else => try out.print(allocator, "<{s}>", .{@tagName(v)}),
    }
}

const ListCheck = struct { arena: std.mem.Allocator, want: []const []const u8, what: []const u8 };

fn checkListCase(c: ListCheck, rows: []const []Value) anyerror!void {
    const got = try c.arena.alloc([]const u8, rows.len);
    for (rows, got) |row, *g| {
        var out: std.ArrayList(u8) = .empty;
        try render(c.arena, &out, row[0]);
        g.* = out.items;
    }
    std.mem.sort([]const u8, got, {}, lessThanStr);
    const want = try c.arena.dupe([]const u8, c.want);
    std.mem.sort([]const u8, want, {}, lessThanStr);
    if (got.len != want.len) {
        std.debug.print("{s}: {d} rows, expected {d}\n", .{ c.what, got.len, want.len });
        return error.WrongRows;
    }
    for (got, want) |g, w| if (!std.mem.eql(u8, g, w)) {
        std.debug.print("{s}: got '{s}', expected '{s}'\n", .{ c.what, g, w });
        return error.WrongValue;
    };
}

fn runListCases(store: Store, mode: Mode) !void {
    var fx: Fixture = undefined;
    try fx.init(store);
    defer fx.deinit();
    const aa = fx.arena.allocator();

    var failures: usize = 0;
    for (list_cases) |case| {
        const what = try std.fmt.allocPrint(aa, "[{s} {s}] {s}", .{ @tagName(store), @tagName(mode), case.q });
        const leaked = leaksOf(&fx, mode, null, case.q, ListCheck{ .arena = aa, .want = case.want, .what = what }, checkListCase) catch |err| {
            std.debug.print("FAIL {s}: {s}\n", .{ what, @errorName(err) });
            failures += 1;
            continue;
        };
        if (leaked != 0) {
            std.debug.print("LEAK {s}: {d} allocations\n", .{ what, leaked });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6449 / SONNY-6437 (1, 2, 6): lists, DISTINCT and GROUP BY over lists, comprehensions, computed values and VALUES ... MATCH: in memory, embedded" {
    try runListCases(.memory, .embedded);
}

test "SONNY-6449 / SONNY-6437 (1, 2, 6): lists, DISTINCT and GROUP BY over lists, comprehensions, computed values and VALUES ... MATCH: in memory, with a request scratch arena" {
    try runListCases(.memory, .scratch);
}

test "SONNY-6449 / SONNY-6437 (1, 2, 6): lists, DISTINCT and GROUP BY over lists, comprehensions, computed values and VALUES ... MATCH: persisted, embedded" {
    try runListCases(.persisted, .embedded);
}

test "SONNY-6449 / SONNY-6437 (1, 2, 6): lists, DISTINCT and GROUP BY over lists, comprehensions, computed values and VALUES ... MATCH: persisted, with a request scratch arena" {
    try runListCases(.persisted, .scratch);
}

/// The engine-direct node scan (`node_scan_stream`) serves a single-label
/// RETURN over QUIC, page by page, with the request's scratch arena
/// installed. It owns every cell it does not copy out of its node and frees
/// it with the page (`property_value_codec.freeValue`), so a member read
/// lent from the scratch arena was freed with the wrong allocator: the
/// server aborted ("Invalid free") on an encrypted field's read
/// (tests/test_sonny6334_fle_authorization.zig, over QUIC).
fn scanColumn0(fx: *Fixture, role: ?[]const u8, src: []const u8) ![]const []const u8 {
    const aa = fx.arena.allocator();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const prev = query_arena.pushScratchAllocator(scratch.allocator());
    defer query_arena.popScratchAllocator(prev);
    fx.ctx.fle_role = role;
    fle_integration.setCurrentUserRole(role);
    defer fle_integration.clearCurrentThreadState();

    var parsed = try geode.parseGqlOptions(src, aa, .{});
    defer parsed.deinit();
    const q = &parsed.program.statements[0].Query;
    var stream = (try node_scan_stream.prepare(testing.allocator, q, fx.ctx, &.{}, &.{}, &.{})) orelse return error.FastPathDeclined;
    defer stream.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    while (true) {
        var page = try stream.buildNextPage(testing.allocator, 0);
        defer page.result.deinit(testing.allocator);
        for (page.result.rows) |row| {
            var text: std.ArrayList(u8) = .empty;
            try render(aa, &text, row[0]);
            try out.append(aa, text.items);
        }
        if (page.final) break;
    }
    std.mem.sort([]const u8, out.items, {}, lessThanStr);
    return out.items;
}

test "SONNY-6449: the engine-direct node scan owns its cells: plain, FLE plaintext, FLE redacted and list properties" {
    var fx: Fixture = undefined;
    try fx.init(.persisted);
    defer fx.deinit();

    const Scan = struct { role: ?[]const u8, q: []const u8, want: []const []const u8 };
    const scans = [_]Scan{
        .{ .role = null, .q = "MATCH (n:S6449P) RETURN n.s AS x", .want = &.{ "plain-0", "plain-0", "plain-1" } },
        .{ .role = "pii", .q = "MATCH (n:S6449P) RETURN n.ssn AS x", .want = &.{ "secret-0", "secret-0", "secret-1" } },
        .{ .role = null, .q = "MATCH (n:S6449P) RETURN n.ssn AS x", .want = &.{ "[REDACTED]", "[REDACTED]", "[REDACTED]" } },
        .{ .role = null, .q = "MATCH (n:S6449P) RETURN n.v AS x", .want = &.{ "[a,b0]", "[a,b0]", "[a,b1]" } },
    };
    var failures: usize = 0;
    for (scans) |scan| {
        const got = scanColumn0(&fx, scan.role, scan.q) catch |err| {
            std.debug.print("FAIL [scan role={s}] {s}: {s}\n", .{ scan.role orelse "none", scan.q, @errorName(err) });
            failures += 1;
            continue;
        };
        const same = got.len == scan.want.len and for (got, scan.want) |g, w| {
            if (!std.mem.eql(u8, g, w)) break false;
        } else true;
        if (!same) {
            std.debug.print("FAIL [scan role={s}] {s}: got {d} rows\n", .{ scan.role orelse "none", scan.q, got.len });
            for (got) |g| std.debug.print("  '{s}'\n", .{g});
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
