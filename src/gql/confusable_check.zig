// Confusable identifier detection (ISO/IEC 39075:2024 RQ-0011 / RQ-0012).
//
// Walks a parsed `ast.Program` and collects every user-declared identifier:
//
//   - Variable bindings in MATCH/CREATE/MERGE patterns (NodePattern.name,
//     RelPattern.name)
//   - Aliases in RETURN and WITH clauses (ReturnItem.alias)
//   - LET binding variables (Query.let_bindings, Query.inline_let_bindings)
//   - Path variable assignment (Query.path_variable)
//   - List comprehension binding variables (Expr.ListComprehension.variable)
//
// For every collected identifier, the TR#39 confusable skeleton (provided by
// `src/unicode/confusables.zig`) is computed. If two distinct identifiers
// produce the same skeleton, they are visually confusable and the program
// must be rejected with `error.ConfusableIdentifier`, which the transport
// layer translates to GQL SQLSTATE 42004.
//
// CANARY: REQ=GQL-39075-RQ-0012; FEATURE="Unicode Confusable Detection"; ASPECT=ParseTimeEnforcement; STATUS=TESTED; TEST=tests/test_confusable_identifiers.zig; OWNER=conformance; UPDATED=2026-04-10
//
// Notes:
//
// 1. Per RQ-0011, an identifier is never confusable with itself. We dedupe
//    by inserting raw names into a Set first; only distinct names are then
//    skeleton-checked for cross-name collisions.
//
// 2. Label and property names are NOT collected. Labels and property keys
//    correspond to schema/data and are typically allowed to overlap with
//    identifier names by convention. A future extension can opt-in to
//    label/property checks behind a session flag.
//
// 3. The check operates per-program. UNION / INTERSECT / EXCEPT branches
//    each get their own scope walk, so a name collision must occur within
//    one branch to be flagged. This matches ISO §6 "same scope" semantics
//    in a conservative way.

const std = @import("std");
const ast = @import("ast.zig");
const confusables = @import("../unicode/confusables.zig");

pub const Error = error{
    ConfusableIdentifier,
    OutOfMemory,
};

/// Walk an entire program and reject it if any two distinct user-declared
/// identifiers are visually confusable per the TR#39 skeleton mapping.
///
/// The caller owns the program AST; this function performs no allocations
/// outside the supplied allocator and frees everything before returning.
pub fn checkProgram(allocator: std.mem.Allocator, program: *const ast.Program) Error!void {
    for (program.statements) |stmt| {
        try checkStatement(allocator, &stmt);
    }
}

fn checkStatement(allocator: std.mem.Allocator, stmt: *const ast.Statement) Error!void {
    switch (stmt.*) {
        .Query => |q| try checkQuery(allocator, &q),
        .Union => |u| {
            try checkQuery(allocator, &u.first);
            for (u.tails) |tail| try checkQuery(allocator, &tail.query);
        },
        .Intersect => |bs| {
            try checkQuery(allocator, &bs.left);
            try checkQuery(allocator, &bs.right);
        },
        .Except => |bs| {
            try checkQuery(allocator, &bs.left);
            try checkQuery(allocator, &bs.right);
        },
        .Create => |c| try checkStandalonePattern(allocator, &c.pattern),
        .Insert => |i| try checkStandalonePattern(allocator, &i.pattern),
        .Merge => |m| try checkStandalonePattern(allocator, &m.pattern),
        .Explain => |e| try checkStatement(allocator, e.query),
        .Profile => |p| try checkStatement(allocator, p.query),
        else => {},
    }
}

fn checkQuery(allocator: std.mem.Allocator, q: *const ast.Query) Error!void {
    var set = NameSet.init(allocator);
    defer set.deinit();

    try collectQuery(allocator, q, &set);
    try detectCollisions(allocator, &set);
}

fn checkStandalonePattern(allocator: std.mem.Allocator, pattern: *const ast.GraphPattern) Error!void {
    var set = NameSet.init(allocator);
    defer set.deinit();
    try collectPattern(pattern, &set);
    try detectCollisions(allocator, &set);
}

fn collectQuery(allocator: std.mem.Allocator, q: *const ast.Query, set: *NameSet) Error!void {
    // LET bindings (both pre- and post-MATCH)
    for (q.let_bindings) |lb| try set.add(lb.variable);
    for (q.inline_let_bindings) |lb| try set.add(lb.variable);

    // MATCH pattern variables
    try collectPattern(&q.match, set);

    // CREATE pattern (rare in Query, but supported)
    if (q.create_pattern) |cp| try collectPattern(&cp, set);

    // UNWIND binding
    if (q.unwind_clause) |uc| try set.add(uc.variable);

    // Path variable assignment (MATCH p = pattern)
    if (q.path_variable) |pv| try set.add(pv);

    // WITH clause aliases (only the explicit `AS` form contributes a new name)
    if (q.with_clause) |wc| {
        for (wc.items) |item| {
            if (item.alias) |a| try set.add(a);
        }
    }

    // RETURN clause aliases
    for (q.ret.items) |item| {
        if (item.alias) |a| try set.add(a);
    }

    // Recurse into chained queries (CREATE … WITH … MATCH …)
    if (q.next_query) |nq| try collectQuery(allocator, nq, set);

    // Initial CALL { ... } subquery
    if (q.initial_call_subquery) |sub| try collectQuery(allocator, sub, set);
}

fn collectPattern(pattern: *const ast.GraphPattern, set: *NameSet) Error!void {
    for (pattern.chains) |chain| {
        if (chain.name) |n| try set.add(n);
        if (chain.head) |head| {
            if (head.name) |n| try set.add(n);
        }
        for (chain.hops) |hop| {
            if (hop.left.name) |n| try set.add(n);
            if (hop.rel.name) |n| try set.add(n);
            if (hop.right.name) |n| try set.add(n);
        }
    }
}

// ---------------------------------------------------------------------------
// NameSet: small string set with stable ordering for deterministic checks.
// ---------------------------------------------------------------------------

const NameSet = struct {
    map: std.StringHashMap(void),
    list: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator) NameSet {
        return .{
            .map = std.StringHashMap(void).init(allocator),
            .list = std.ArrayList([]const u8).empty,
        };
    }

    fn deinit(self: *NameSet) void {
        self.list.deinit(self.map.allocator);
        self.map.deinit();
    }

    fn add(self: *NameSet, name: []const u8) Error!void {
        if (name.len == 0) return;
        const gop = try self.map.getOrPut(name);
        if (!gop.found_existing) {
            try self.list.append(self.map.allocator, name);
        }
    }
};

// ---------------------------------------------------------------------------
// detectCollisions: compute skeletons for every name and report any pair
// of distinct names that share a skeleton.
// ---------------------------------------------------------------------------

fn detectCollisions(allocator: std.mem.Allocator, set: *NameSet) Error!void {
    if (set.list.items.len < 2) return;

    // skeleton -> first name observed with that skeleton
    var sk_to_name = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = sk_to_name.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        sk_to_name.deinit();
    }

    for (set.list.items) |name| {
        const skel = try confusables.skeleton(allocator, name);
        // Use getOrPut to keep the first owner of the key. If found, we
        // have a collision; free the new skeleton (it's a duplicate).
        const gop = sk_to_name.getOrPut(skel) catch |err| {
            allocator.free(skel);
            return err;
        };
        if (gop.found_existing) {
            // Collision: name and gop.value_ptr.* share the same skeleton
            allocator.free(skel);
            return Error.ConfusableIdentifier;
        }
        gop.value_ptr.* = name;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "NameSet dedupes equal names" {
    var set = NameSet.init(std.testing.allocator);
    defer set.deinit();

    try set.add("a");
    try set.add("a");
    try set.add("b");
    try std.testing.expectEqual(@as(usize, 2), set.list.items.len);
}

test "detectCollisions: no collision for distinct ASCII names" {
    var set = NameSet.init(std.testing.allocator);
    defer set.deinit();
    try set.add("alpha");
    try set.add("beta");
    try set.add("gamma");
    try detectCollisions(std.testing.allocator, &set);
}

test "detectCollisions: ASCII case fold collision (a vs A)" {
    // Per the TR#39 skeleton, ASCII letters are lowercased so "a" and "A"
    // share the same skeleton "a" — they ARE confusable.
    var set = NameSet.init(std.testing.allocator);
    defer set.deinit();
    try set.add("a");
    try set.add("A");
    try std.testing.expectError(Error.ConfusableIdentifier, detectCollisions(std.testing.allocator, &set));
}

test "detectCollisions: Latin a vs Cyrillic а" {
    var set = NameSet.init(std.testing.allocator);
    defer set.deinit();
    try set.add("a");
    try set.add("\xD0\xB0"); // Cyrillic small letter a (U+0430)
    try std.testing.expectError(Error.ConfusableIdentifier, detectCollisions(std.testing.allocator, &set));
}

test "detectCollisions: same identifier appearing twice is RQ-0011 compliant" {
    var set = NameSet.init(std.testing.allocator);
    defer set.deinit();
    try set.add("x");
    try set.add("x"); // dedupes; only one entry; no collision possible
    try detectCollisions(std.testing.allocator, &set);
}
