//! Shared fixture for the row-visibility regressions of SONNY-2686 (MERGE),
//! SONNY-2691 (indegree()/outdegree()) and SONNY-2692 (knn()): one engine
//! session that a label-deny policy, an expression policy or a tenant scope
//! restricts, driven through the real parser and executor. No mocks.
//!
//! Every mode runs on a persisted store (a temporary data directory), as a
//! server does, so the planned read and the node-scan fast path both decline a
//! restricted session and the legacy executor serves it.
//!
//! `Session.run` executes one statement WITHOUT installing its context as the
//! active one, the stricter of the two ways a statement reaches the executor:
//! a statement must evaluate row visibility under its own context rather than
//! rely on its caller to install it.
//!
//! A test module that imports this file also needs the `geode`, `logging`,
//! `rls` and `rls_types` modules.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls = @import("rls");
const rls_types = @import("rls_types");
const scan_harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
pub const Value = geode.value_types.Value;

pub const silenceEngineLogs = scan_harness.silenceEngineLogs;

pub const Mode = enum {
    /// No policy and no tenant scope: the control. Nothing is hidden, and every
    /// fix must leave this session's answers exactly as they were.
    no_policy,
    /// A label-deny policy for the session user (label chosen by `restrict`).
    label_policy,
    /// An expression policy on `:Doc`: a row is visible iff `cls <> 'secret'`.
    expr_policy,
    /// Session tenant `tenant_a`: `tenant_b`'s rows are foreign.
    tenant_scoped,
};

pub const tenant_a = "tenant_a";
pub const tenant_b = "tenant_b";
pub const session_user = "bob";

// The expression policy's bytecode: `row.cls <> 'secret'`
// (load_row 0; push_const 1; neq; ret), the same program SONNY-2679 pins.
const expr_constants = [_]rls.Value{ .{ .string = "cls" }, .{ .string = "secret" } };
const expr_bytecode = [_]u8{ 0x10, 0x00, 0x01, 0x01, 0x21, 0xFF };
// An edge type's expression policy (`restrictEdgeType`): `row.x <> 'topsecret'`
// over the edge's own properties, the program SONNY-2679 pins for SECRET.
const edge_expr_constants = [_]rls.Value{ .{ .string = "x" }, .{ .string = "topsecret" } };

pub const Session = struct {
    mode: Mode,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,
    label_engine: ?*rls_types.RLSFilterEngine = null,
    expr_engine: ?*rls.RLSEngine = null,
    compiled: rls.RLSEngine.CompiledExpression = .{ .bytecode = &expr_bytecode, .constants = &expr_constants, .jump_table = &.{} },
    edge_compiled: rls.RLSEngine.CompiledExpression = .{ .bytecode = &expr_bytecode, .constants = &edge_expr_constants, .jump_table = &.{} },

    pub fn init(mode: Mode) !Session {
        // Pattern comprehensions, COUNT {} and EXISTS {} reach
        // graph_algorithms.zig through the evaluator callbacks the server
        // installs at startup, and indegree()/outdegree()/knn() reach the
        // session's row visibility the same way.
        execution.initEvaluator();
        return initWithoutEvaluator(mode);
    }

    /// `init` without installing the evaluator's callbacks, for a test that
    /// pins what a statement does before `execution.initEvaluator` runs. The
    /// callbacks are published once per process and never removed, so a test
    /// binary that uses this must never call `init`.
    pub fn initWithoutEvaluator(mode: Mode) !Session {
        const allocator = testing.allocator;
        silenceEngineLogs();
        execution.cleanupCatalogInstance();
        // The advanced (vector) index registry is process-global and survives
        // the catalog and store teardown.
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try scan_harness.tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);
        if (graph_store.getGlobalAdapter() == null) return error.ExpectedPersistedAdapter;

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .mode = mode,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = .{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Session) void {
        if (self.label_engine) |engine| {
            rls_types.setGlobalRLSFilterEngine(null);
            engine.deinit();
            testing.allocator.destroy(engine);
        }
        if (self.expr_engine) |engine| {
            rls_types.setGlobalExprRLSEngine(null);
            engine.deinit();
            testing.allocator.destroy(engine);
        }
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    /// Run one statement as the session (see the file header).
    pub fn run(self: *Session, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// Run a write as `tenant` (null: unscoped), as the server would: with the
    /// writer's context installed, so what it creates carries its tenant.
    pub fn execAs(self: *Session, tenant: ?[]const u8, query: []const u8) !void {
        const saved = self.ctx.tenant_id;
        defer self.ctx.tenant_id = saved;
        self.ctx.tenant_id = tenant;
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        var r = try self.run(query);
        r.deinit(self.arena.allocator());
    }

    /// The id of the node whose `s` property is `s` (read unscoped, straight
    /// from the store).
    pub fn idOf(self: *Session, s: []const u8) !u64 {
        _ = self;
        const store = graph_store.getGlobalStore(testing.allocator);
        var it = store.nodes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.properties.get("s")) |pv| {
                if (pv == .String and std.mem.eql(u8, pv.String, s)) return entry.key_ptr.*;
            }
        }
        return error.NodeNotFound;
    }

    /// Restrict the session to its mode. `deny_label` is the label the
    /// label-deny policy hides; the other modes ignore it.
    pub fn restrict(self: *Session, deny_label: []const u8) !void {
        switch (self.mode) {
            .no_policy => {},
            .label_policy => {
                const engine = try testing.allocator.create(rls_types.RLSFilterEngine);
                engine.* = rls_types.RLSFilterEngine.init(testing.allocator);
                self.label_engine = engine;
                try engine.addDenyPolicy(graph_store.DEFAULT_GRAPH_NAME, deny_label, session_user);
                rls_types.setGlobalRLSFilterEngine(engine);
                self.ctx.user = session_user;
            },
            .expr_policy => {
                const engine = try testing.allocator.create(rls.RLSEngine);
                engine.* = rls.RLSEngine.init(testing.allocator) catch |err| {
                    testing.allocator.destroy(engine);
                    return err;
                };
                self.expr_engine = engine;
                try engine.createPolicy(.{
                    .id = 2686,
                    .name = "doc_not_secret",
                    .description = "a :Doc row is visible iff cls <> 'secret'",
                    .graph = graph_store.DEFAULT_GRAPH_NAME,
                    .table = "Doc",
                    .operation = .all,
                    .permissive = false,
                    .roles = &.{},
                    .using_expr = .{ .raw = "cls <> 'secret'", .parsed = null, .compiled = &self.compiled, .parameters = &.{} },
                    .check_expr = null,
                    .enabled = true,
                    .created_at = 0,
                    .updated_at = 0,
                    .created_by = 0,
                    .temporal = null,
                    .data_classification = null,
                    .audit_level = .none,
                });
                rls_types.setGlobalExprRLSEngine(@ptrCast(engine));
                self.ctx.user = session_user;
            },
            .tenant_scoped => self.ctx.tenant_id = tenant_a,
        }
    }

    /// Also restrict the edge type `edge_type`, after `restrict`: the
    /// label-deny policy denies the type itself; the expression policy
    /// admits an edge of that type iff its own `x <> 'topsecret'`. The
    /// other modes are unchanged.
    pub fn restrictEdgeType(self: *Session, edge_type: []const u8) !void {
        switch (self.mode) {
            .label_policy => try self.label_engine.?.addDenyPolicy(graph_store.DEFAULT_GRAPH_NAME, edge_type, session_user),
            .expr_policy => try self.expr_engine.?.createPolicy(.{
                .id = 26862,
                .name = "edge_not_topsecret",
                .description = "an edge of this type is visible iff x <> 'topsecret'",
                .graph = graph_store.DEFAULT_GRAPH_NAME,
                .table = edge_type,
                .operation = .all,
                .permissive = false,
                .roles = &.{},
                .using_expr = .{ .raw = "x <> 'topsecret'", .parsed = null, .compiled = &self.edge_compiled, .parameters = &.{} },
                .check_expr = null,
                .enabled = true,
                .created_at = 0,
                .updated_at = 0,
                .created_by = 0,
                .temporal = null,
                .data_classification = null,
                .audit_level = .none,
            }),
            .no_policy, .tenant_scoped => {},
        }
    }
};

/// A property of an edge, read unscoped straight from the store.
pub fn storedEdgeString(edge_id: u64, key: []const u8) ?[]const u8 {
    const store = graph_store.getGlobalStore(testing.allocator);
    const edge = (store.getEdgeHydratedChecked(edge_id) catch @panic("SONNY-6621: unexpected read failure")) orelse return null;
    const pv = edge.properties.get(key) orelse return null;
    return if (pv == .String) pv.String else null;
}

/// The ids of the `label` edges from `from` to `to`, in adjacency order
/// (every graph and tenant, straight from the store).
pub fn edgeIds(aa: std.mem.Allocator, from: u64, to: u64, label: []const u8) ![]u64 {
    const store = graph_store.getGlobalStore(testing.allocator);
    var out: std.ArrayList(u64) = .empty;
    const ids = (try store.getOutgoingEdgeIdsOrError(from)) orelse return out.toOwnedSlice(aa);
    for (ids) |eid| {
        const e = (try store.getEdgeHydratedChecked(eid)) orelse continue;
        if (e.to_id == to and std.mem.eql(u8, e.label, label)) try out.append(aa, eid);
    }
    return out.toOwnedSlice(aa);
}

/// Does any edge incident to `id` carry the property `key`?
pub fn anyIncidentEdgeHas(id: u64, key: []const u8) bool {
    const store = graph_store.getGlobalStore(testing.allocator);
    for ([_]?[]const u64{ (store.getOutgoingEdgeIdsOrError(id) catch @panic("SONNY-6621: unexpected read failure")), (store.getIncomingEdgeIdsOrError(id) catch @panic("SONNY-6621: unexpected read failure")) }) |maybe_ids| {
        const ids = maybe_ids orelse continue;
        for (ids) |eid| {
            const e = (store.getEdgeHydratedChecked(eid) catch @panic("SONNY-6621: unexpected read failure")) orelse continue;
            if (e.properties.get(key) != null) return true;
        }
    }
    return false;
}

/// How many nodes the store holds (every graph and tenant).
pub fn nodeCount() usize {
    const store = graph_store.getGlobalStore(testing.allocator);
    var n: usize = 0;
    var it = store.nodes.iterator();
    while (it.next()) |_| n += 1;
    return n;
}

/// A string property of a node, read unscoped straight from the store.
pub fn storedString(id: u64, key: []const u8) ?[]const u8 {
    const store = graph_store.getGlobalStore(testing.allocator);
    const node = store.nodes.get(id) orelse return null;
    const pv = node.properties.get(key) orelse return null;
    return if (pv == .String) pv.String else null;
}

/// How many nodes (in any graph or tenant) have `s` = `s`.
pub fn countWithS(s: []const u8) usize {
    const store = graph_store.getGlobalStore(testing.allocator);
    var n: usize = 0;
    var it = store.nodes.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*.properties.get("s")) |pv| {
            if (pv == .String and std.mem.eql(u8, pv.String, s)) n += 1;
        }
    }
    return n;
}

/// How many edges start or end at `id` (every graph and tenant).
pub fn incidentEdges(id: u64) usize {
    const store = graph_store.getGlobalStore(testing.allocator);
    const out = if ((store.getOutgoingEdgeIdsOrError(id) catch @panic("SONNY-6621: unexpected read failure"))) |ids| ids.len else 0;
    const in = if ((store.getIncomingEdgeIdsOrError(id) catch @panic("SONNY-6621: unexpected read failure"))) |ids| ids.len else 0;
    return out + in;
}

fn nodeName(n: *const graph_store.Node) []const u8 {
    if (n.properties.get("s")) |pv| {
        if (pv == .String) return pv.String;
    }
    return "?";
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// A cell as text: a node as `(s)`, a list as its items in order.
pub fn render(aa: std.mem.Allocator, v: Value) anyerror![]const u8 {
    return switch (v) {
        .Str, .Text => |s| s,
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Bool => |b| if (b) "true" else "false",
        .Null => "null",
        .Node => |n| try std.fmt.allocPrint(aa, "({s})", .{nodeName(n)}),
        .Edge => |e| try std.fmt.allocPrint(aa, "[{s}]", .{e.label}),
        .List => |items| blk: {
            const parts = try aa.alloc([]const u8, items.len);
            for (items, parts) |item, *part| part.* = try render(aa, item);
            break :blk try std.fmt.allocPrint(aa, "[{s}]", .{try std.mem.join(aa, ",", parts)});
        },
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(v)}),
    };
}

/// Every failed check of one test, reported together so a red run shows the
/// whole picture rather than the first difference.
pub const Failures = struct {
    items: std.ArrayList([]const u8) = .empty,

    pub fn add(self: *Failures, aa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(aa, try std.fmt.allocPrint(aa, fmt, args));
    }

    pub fn finish(self: *Failures, title: []const u8) !void {
        if (self.items.items.len == 0) return;
        std.debug.print("\n{s}: {d} failed check(s):\n", .{ title, self.items.items.len });
        for (self.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.RowVisibilityWrong;
    }
};

/// The rows of `query` as `a|b` strings, sorted, or the error it raised.
pub fn rowsOf(s: *Session, query: []const u8) anyerror![]const []const u8 {
    const aa = s.arena.allocator();
    var result = try s.run(query);
    defer result.deinit(aa);
    const got = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, got) |row, *g| {
        const cells = try aa.alloc([]const u8, row.len);
        for (row, cells) |cell, *c| c.* = try render(aa, cell);
        g.* = try std.mem.join(aa, "|", cells);
    }
    std.mem.sort([]const u8, got, {}, lessThan);
    return got;
}

/// `query` returns exactly `want` (in any order).
pub fn expectRows(s: *Session, f: *Failures, query: []const u8, want: []const []const u8) !void {
    const aa = s.arena.allocator();
    const got = rowsOf(s, query) catch |err| {
        try f.add(aa, "[{s}] {s}: expected {{{s}}}, got error {s}", .{ @tagName(s.mode), query, try std.mem.join(aa, ",", want), @errorName(err) });
        return;
    };
    const exp = try aa.dupe([]const u8, want);
    std.mem.sort([]const u8, exp, {}, lessThan);
    const same = got.len == exp.len and for (got, exp) |g, w| {
        if (!std.mem.eql(u8, g, w)) break false;
    } else true;
    if (!same) {
        try f.add(aa, "[{s}] {s}: expected {{{s}}}, got {{{s}}}", .{ @tagName(s.mode), query, try std.mem.join(aa, ",", exp), try std.mem.join(aa, ",", got) });
    }
}

/// `query` fails with `want`.
pub fn expectError(s: *Session, f: *Failures, query: []const u8, want: anyerror) !void {
    const aa = s.arena.allocator();
    if (rowsOf(s, query)) |got| {
        try f.add(aa, "[{s}] {s}: expected error {s}, got {{{s}}}", .{ @tagName(s.mode), query, @errorName(want), try std.mem.join(aa, ",", got) });
    } else |err| {
        if (err != want) try f.add(aa, "[{s}] {s}: expected error {s}, got error {s}", .{ @tagName(s.mode), query, @errorName(want), @errorName(err) });
    }
}
