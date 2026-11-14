//! SONNY-6525 item 1: correlated and uncorrelated IN / NOT IN subqueries.
//!
//! A subquery inside an expression (`x IN (MATCH ... RETURN ...)`) runs on
//! the incoming working record of the expression around it: an outer
//! variable it names is that row's value (ISO/IEC 39075:2024 20.12 SR 8), so
//! it runs once per outer row. One that names no variable of the row (an
//! uncorrelated subquery) has the same result for every row; within a
//! statement that changes nothing it runs once, and every row reads that
//! result (`Cache`).
//!
//! Which names a subquery may read from the row: every text anywhere in its
//! AST (`mentionedNames`): identifiers, property owners, pattern element
//! names, and also literals and labels. A literal that happens to spell an
//! outer variable only makes the subquery run per row; a name it reads is
//! never missed, so a cached result is never one a row would answer
//! differently.
//!
//! CANARY: REQ=REQ-SONNY-6525-CORRELATED-SUBQUERY; FEATURE="SubqueryEvaluation"; ASPECT=Correlation; STATUS=TESTED; TEST=tests/test_sonny6525_correlated_subquery.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const ast = @import("../gql/ast.zig");
const value_types = @import("../value_types.zig");
const execution = @import("../execution.zig");

const Value = value_types.Value;

/// The uncorrelated subquery results of one statement that changes nothing
/// (installed by `execution.executeProgramWithContext` per statement), and
/// what each subquery mentions.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    /// The statement's own parameters (the request's): constant over it.
    request_param_names: []const []const u8,
    request_param_values: []const Value,
    entries: std.AutoHashMapUnmanaged(*const ast.Query, Entry) = .empty,

    const Entry = struct {
        names: Names,
        result: ?execution.ExecutionResult = null,
    };

    pub fn init(allocator: std.mem.Allocator, request_param_names: []const []const u8, request_param_values: []const Value) Cache {
        return .{ .allocator = allocator, .request_param_names = request_param_names, .request_param_values = request_param_values };
    }

    pub fn deinit(c: *Cache) void {
        var it = c.entries.valueIterator();
        while (it.next()) |e| {
            e.names.deinit(c.allocator);
            if (e.result) |*r| r.deinit(c.allocator);
        }
        c.entries.deinit(c.allocator);
    }

    /// The entry of `q`, its names collected on first use.
    pub fn entry(c: *Cache, q: *const ast.Query) error{OutOfMemory}!*Entry {
        const gop = try c.entries.getOrPut(c.allocator, q);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .names = mentionedNames(c.allocator, q) catch |err| {
                c.entries.removeByPtr(gop.key_ptr);
                return err;
            } };
        }
        return gop.value_ptr;
    }

    /// Whether `name` is a request parameter whose value is `value` (the
    /// same value, not one a nested scope bound over it).
    pub fn isRequestParam(c: *const Cache, name: []const u8, value: Value) bool {
        for (c.request_param_names, c.request_param_values) |n, v| {
            if (std.mem.eql(u8, n, name)) return sameValue(v, value);
        }
        return false;
    }
};

threadlocal var t_cache: ?*Cache = null;
threadlocal var t_runs: u64 = 0;

/// Install `c` for the statement this thread runs; returns the one before.
pub fn install(c: ?*Cache) ?*Cache {
    const prev = t_cache;
    t_cache = c;
    return prev;
}

pub fn restore(prev: ?*Cache) void {
    t_cache = prev;
}

pub fn current() ?*Cache {
    return t_cache;
}

/// How many times this thread ran an expression subquery (tests: an
/// uncorrelated one runs once per statement, not once per row).
pub fn runCount() u64 {
    return t_runs;
}

pub fn noteRun() void {
    t_runs +%= 1;
}

/// Two values that are the same bits (a parameter not rebound). A value
/// that differs only in padding counts as different, which only makes a
/// subquery run per row.
pub fn sameValue(a: Value, b: Value) bool {
    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
}

/// The texts a query holds.
pub const Names = struct {
    set: std.StringHashMapUnmanaged(void) = .empty,
    /// The names its own parts bind (pattern elements, UNWIND, FOR, LET,
    /// a path variable), outside its expressions.
    bound: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(n: *Names, allocator: std.mem.Allocator) void {
        n.set.deinit(allocator);
        n.bound.deinit(allocator);
    }

    pub fn has(n: *const Names, name: []const u8) bool {
        return n.set.contains(name);
    }

    pub fn binds(n: *const Names, name: []const u8) bool {
        return n.bound.contains(name);
    }
};

/// Every text in `q`, and the names its parts bind. Iterative over
/// expressions and queries (an expression may be thousands of links deep).
pub fn mentionedNames(allocator: std.mem.Allocator, q: *const ast.Query) error{OutOfMemory}!Names {
    var c = Collector{ .alloc = allocator };
    defer c.stack.deinit(allocator);
    errdefer c.names.deinit(allocator);
    try c.bindParts(q);
    try c.stack.append(allocator, .{ .query = q });
    while (c.stack.pop()) |item| switch (item) {
        .query => |qq| try c.visit(ast.Query, qq),
        .expr => |e| switch (e.*) {
            inline else => |*p| try c.visit(@TypeOf(p.*), p),
        },
        .stmt => |s| switch (s.*) {
            inline else => |*p| try c.visit(@TypeOf(p.*), p),
        },
    };
    return c.names;
}

const Collector = struct {
    alloc: std.mem.Allocator,
    names: Names = .{},
    stack: std.ArrayList(Item) = .empty,

    const Item = union(enum) { query: *const ast.Query, expr: *const ast.Expr, stmt: *const ast.Statement };

    fn add(c: *Collector, s: []const u8) error{OutOfMemory}!void {
        try c.names.set.put(c.alloc, s, {});
    }

    fn bind(c: *Collector, s: []const u8) error{OutOfMemory}!void {
        try c.names.bound.put(c.alloc, s, {});
    }

    fn bindPattern(c: *Collector, p: ast.GraphPattern) error{OutOfMemory}!void {
        for (p.chains) |ch| {
            if (ch.name) |n| try c.bind(n);
            if (ch.head) |h| if (h.name) |n| try c.bind(n);
            for (ch.hops) |hop| {
                if (hop.left.name) |n| try c.bind(n);
                if (hop.rel.name) |n| try c.bind(n);
                if (hop.right.name) |n| try c.bind(n);
            }
        }
    }

    /// The names the parts of `head` bind (its chain, a CALL { } before a
    /// part, a FOR's body), outside expressions.
    fn bindParts(c: *Collector, head: *const ast.Query) error{OutOfMemory}!void {
        var todo: std.ArrayList(*const ast.Query) = .empty;
        defer todo.deinit(c.alloc);
        try todo.append(c.alloc, head);
        while (todo.pop()) |q| {
            try c.bindPattern(q.match);
            if (q.create_pattern) |p| try c.bindPattern(p);
            if (q.merge_statement) |m| try c.bindPattern(m.pattern);
            if (q.path_variable) |p| try c.bind(p);
            if (q.unwind_clause) |u| try c.bind(u.variable);
            for (q.inline_let_bindings) |b| try c.bind(b.variable);
            if (q.for_statement) |f| {
                try c.bind(f.variable);
                if (f.ordinality_var) |v| try c.bind(v);
                if (f.offset_var) |v| try c.bind(v);
                for (f.nested) |loop| {
                    try c.bind(loop.variable);
                    if (loop.ordinality_var) |v| try c.bind(v);
                    if (loop.offset_var) |v| try c.bind(v);
                }
                if (f.body) |b| try todo.append(c.alloc, b);
            }
            if (q.initial_call_subquery) |s| try todo.append(c.alloc, s);
            if (q.next_query) |n| try todo.append(c.alloc, n);
        }
    }

    fn visit(c: *Collector, comptime T: type, v: *const T) error{OutOfMemory}!void {
        @setEvalBranchQuota(200_000);
        if (T == ast.Expr) return c.stack.append(c.alloc, .{ .expr = v });
        if (T == ast.Statement) return c.stack.append(c.alloc, .{ .stmt = v });
        if (T == []const u8 or T == []u8) return c.add(v.*);
        switch (@typeInfo(T)) {
            .@"struct" => |s| inline for (s.fields) |field| try c.visit(field.type, &@field(v.*, field.name)),
            .@"union" => |u| {
                if (u.tag_type == null) @compileError("subquery_cache: an untagged union " ++ @typeName(T) ++ " in the AST");
                switch (v.*) {
                    inline else => |*p| try c.visit(@TypeOf(p.*), p),
                }
            },
            .optional => |o| if (v.*) |*inner| try c.visit(o.child, inner),
            .pointer => |p| switch (p.size) {
                .one => {
                    if (p.child == ast.Query) return c.stack.append(c.alloc, .{ .query = v.* });
                    try c.visit(p.child, v.*);
                },
                .slice => for (v.*) |*elem| try c.visit(p.child, elem),
                else => @compileError("subquery_cache: a " ++ @typeName(T) ++ " in the AST"),
            },
            .array => |a| for (v) |*elem| try c.visit(a.child, elem),
            .int, .float, .bool, .@"enum", .void => {},
            else => @compileError("subquery_cache: a " ++ @typeName(T) ++ " in the AST"),
        }
    }
};
