// CANARY: REQ=REQ-SONNY-2846-UNIQUE-ENFORCEMENT; FEATURE="ConstraintEnforcement"; ASPECT=StatementEndCheck; STATUS=TESTED; TEST=tests/test_sonny2846_unique_constraint_enforcement.zig; OWNER=engine; UPDATED=2026-11-11
// CANARY: REQ=REQ-SONNY-6281-EXISTENCE-CONSTRAINTS; FEATURE="ConstraintEnforcement"; ASPECT=StatementEndCheck; STATUS=TESTED; TEST=tests/test_sonny6281_existence_constraints.zig; OWNER=engine; UPDATED=2026-11-12
//! SONNY-2846 / SONNY-3358: UNIQUE (and the uniqueness half of NODE KEY)
//! constraint enforcement. SONNY-6281: NOT NULL, EXISTS and the existence
//! half of NODE KEY, through the same check (see "Existence" below).
//!
//! `CREATE CONSTRAINT c FOR (n:L) REQUIRE n.p IS UNIQUE` (or `ON :L ASSERT
//! (a, b) IS UNIQUE`, or `... IS NODE KEY`) records a catalog row; until
//! SONNY-2846 nothing read it. Now:
//!
//!   * Every user statement is checked when it ends, before its changes are
//!     kept (`execution.endStatementSucceeded`): the statement undo record
//!     (`statement_undo`) lists every node the statement created, changed a
//!     property of, or added a label to, on every executor (CREATE, MERGE,
//!     SET, FOR, procedures, PROFILE, the write step, the point-write path).
//!     For each such node that still exists, every constraint whose graph
//!     and label it is in, and whose properties it holds all of (none NULL),
//!     must find no OTHER node holding equal values. A violation fails the
//!     statement with `error.UniqueConstraintViolation` (23505), and the
//!     undo record takes all of its changes back. This is SQL's rule for a
//!     constraint that is not deferred: it holds at the end of each
//!     statement, so `SET a.id = b.id, b.id = a.id` (a swap) is allowed.
//!   * Scope: a constraint row is graph-scoped (SONNY-1319; an engine-wide
//!     legacy row applies in every graph, each graph checked on its own).
//!     Within a graph, uniqueness is per TENANT TAG: nodes of two tenants
//!     may hold the same value. A graph-wide check would let one tenant
//!     learn that another holds a value (the refusal is an oracle) and block
//!     its ids. Single-tenant deployments tag every node alike, so there the
//!     constraint is graph-wide.
//!   * NULL and a missing property are never a conflict (SQL: NULLs are
//!     distinct).
//!   * Equality is MERGE's (`value_equality.valuesEqual`, the rule an inline
//!     property map and MERGE match by): numbers by exact value (1 = 1.0,
//!     1.5 = 1.50, a DOUBLE 0.1 is not the decimal 0.1), strings byte for
//!     byte (an NFC and an NFD spelling are two values, as MERGE treats
//!     them; the `=` operator normalizes, MERGE does not). A MERGE that does
//!     not match a node is therefore never refused for that node's value.
//!   * The other holder is found through the exact node-property index when
//!     it can answer for every value (a number, string or boolean; full
//!     index mode, index built): O(holders). Otherwise (lean mode, the index
//!     deferred or rebuilding after a reopen, no storage adapter, another
//!     value type) by a scan of the label's postings with each node hydrated
//!     (`GraphStore.residentNodeSatisfies`), which sees nodes that are not
//!     resident: O(nodes of the label) per checked node.
//!
//! Atomicity under concurrency: the transport runs a program that changes
//! the store under its graph's write lock held EXCLUSIVE from before the
//! first write until after this check (`acquireProgramWriteLockCancelable`),
//! so no other executor statement writes the graph between the check and the
//! statement's end. The server's bulk fast paths skip the executor; they do
//! not serve a graph a UNIQUE row applies in (`graph_store.uniqueFenced`):
//! the handler sends such writes to the executor, and the adapter's bulk
//! helpers refuse (40001) a write that passed that gate before the row
//! existed, under the graph lock that CREATE CONSTRAINT holds EXCLUSIVE
//! while it adds the fence and validates the data.
//!
//! Existence (SONNY-6281): `REQUIRE n.p IS NOT NULL`, the legacy `ASSERT
//! EXISTS (p)` and `IS NODE KEY` require every node of the label in the
//! row's graph to hold each named property with a value that is not NULL
//! (GQL treats a property whose value is null as absent, so absent and NULL
//! are one case). The statement-end check reads the same nodes (a node the
//! statement removed a property from is checked too); a node lacking one
//! fails the statement with `error.NotNullConstraintViolation` (23502,
//! SQL's not_null_violation). Removing the label frees a node. CREATE
//! CONSTRAINT refuses such a row over nodes that already lack it
//! (`countNodesMissing`). Every enforced row, of any kind, raises its
//! graph's fast-path fence (`graph_store.addUniqueFence`).
//!
//! What is NOT checked here, by design: Raft apply, snapshot install, WAL
//! recovery and restore replay writes that were validated when made; they
//! run outside any statement scope. In cluster mode a leader's writes are
//! applied only through the Raft log, after the statement, so a held write
//! that could break a constraint (anything but a delete, on a graph a row
//! applies in) is refused with `ClusterWriteNotReplicable` (constraint DDL
//! itself is refused in cluster mode already).

const std = @import("std");
const graph_store = @import("../graph_store.zig");
const graph_storage_adapter = @import("../storage/graph_storage_adapter.zig");
const catalog_mod = @import("../schema/catalog.zig");
const statement_undo = @import("../statement_undo.zig");
const statement_proposals = @import("../distributed/statement_proposals.zig");
const cluster_mod = @import("../distributed/cluster.zig");
const property_codec = @import("../property_value_codec.zig");
const value_equality = @import("value_equality.zig");
const logging = @import("logging");
const log = logging.scoped("unique_constraints");
const Attr = logging.Attr;

const PropertyValue = graph_store.PropertyValue;
const ConstraintInfo = catalog_mod.ConstraintInfo;
const PropKV = graph_storage_adapter.StorageAdapter.PropKV;

pub const Error = error{
    /// 23505: the statement would leave two nodes holding one key.
    UniqueConstraintViolation,
    /// 23502 (SONNY-6281): the statement would leave a node of a label
    /// without a property a NOT NULL / EXISTS / NODE KEY row requires.
    NotNullConstraintViolation,
    /// The store could not be read to check; the statement is not kept.
    UniqueConstraintCheckFailed,
    /// Cluster leader: a held write could break a constraint.
    ClusterWriteNotReplicable,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// The refusal's message (proto_util.mapError reads it on the same thread).
// It names the constraint, its label and property names; never a value or
// anything else the conflicting node holds.
// ---------------------------------------------------------------------------

threadlocal var t_message_buf: [512]u8 = undefined;
threadlocal var t_message_len: usize = 0;

const generic_message = "unique_violation: the statement would give two nodes the same value for a UNIQUE constraint; nothing was written";

/// The message of this thread's latest unique violation.
pub fn violationMessage() []const u8 {
    if (t_message_len == 0) return generic_message;
    return t_message_buf[0..t_message_len];
}

fn setMessage(comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(&t_message_buf, fmt, args) catch {
        t_message_len = 0;
        return;
    };
    t_message_len = text.len;
}

fn joinedProps(buf: []u8, props: []const []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (props, 0..) |p, i| {
        if (i > 0) w.writeAll(", ") catch break;
        w.writeAll(p) catch break;
    }
    return buf[0..w.end];
}

fn setViolation(rule: ConstraintInfo) void {
    var pbuf: [256]u8 = undefined;
    setMessage("unique_violation: UNIQUE constraint {s} on :{s}({s}): the statement would give two nodes of one graph and tenant the same value; nothing was written", .{ rule.name, rule.label, joinedProps(&pbuf, rule.properties) });
}

const generic_not_null_message = "not_null_violation: the statement would leave a node without a property a NOT NULL, EXISTS or NODE KEY constraint requires; nothing was written";

threadlocal var t_not_null_buf: [512]u8 = undefined;
threadlocal var t_not_null_len: usize = 0;

/// The message of this thread's latest existence (NOT NULL) violation.
pub fn notNullMessage() []const u8 {
    if (t_not_null_len == 0) return generic_not_null_message;
    return t_not_null_buf[0..t_not_null_len];
}

fn setNotNullMessage(comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(&t_not_null_buf, fmt, args) catch {
        t_not_null_len = 0;
        return;
    };
    t_not_null_len = text.len;
}

fn setNotNullViolation(rule: ConstraintInfo) void {
    var pbuf: [256]u8 = undefined;
    setNotNullMessage("not_null_violation: constraint {s} on :{s}({s}) requires every such node to hold each property, not NULL; the statement would leave one without it; nothing was written", .{ rule.name, rule.label, joinedProps(&pbuf, rule.properties) });
}

// ---------------------------------------------------------------------------
// The fast-path gate.
// ---------------------------------------------------------------------------

/// Does a UNIQUE row apply in `graph`? Then no bulk fast path may write it.
pub fn graphFenced(graph: []const u8) bool {
    return graph_store.uniqueFenced(graph);
}

/// Register the fences of every enforced row `cat` holds, of any kind
/// (the process catalog was loaded). A failure to record one leaves a graph
/// unfenced, which would let a fast path skip its check, so it is returned.
pub fn registerCatalogFences(cat: *catalog_mod.Catalog) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const rules = try cat.copyEnforcedConstraints(arena.allocator());
    for (rules) |rule| try graph_store.addUniqueFence(rule.graph);
}

// ---------------------------------------------------------------------------
// Node snapshots and holder search.
// ---------------------------------------------------------------------------

fn isNullish(v: PropertyValue) bool {
    return switch (v) {
        .Null => true,
        .ExtValue => |e| e == .Null,
        else => false,
    };
}

fn clonePropertyValue(a: std.mem.Allocator, v: PropertyValue) !PropertyValue {
    return switch (v) {
        .String => |s| .{ .String = try a.dupe(u8, s) },
        .ExtValue => |e| .{ .ExtValue = try property_codec.cloneExtValue(a, e) },
        else => v,
    };
}

/// What the check needs of one node, copied out of the node cache (reading
/// another node may evict it).
const Snapshot = struct {
    graph: []const u8,
    tenant: []const u8,
    labels: []const []const u8,
    /// `keys[i]`'s value, or null when the node does not hold it.
    values: []?PropertyValue,

    fn hasLabel(self: Snapshot, label: []const u8) bool {
        for (self.labels) |l| {
            if (std.mem.eql(u8, l, label)) return true;
        }
        return false;
    }

    fn value(self: Snapshot, keys: []const []const u8, key: []const u8) ?PropertyValue {
        for (keys, self.values) |k, v| {
            if (std.mem.eql(u8, k, key)) return v;
        }
        return null;
    }
};

const SnapshotCtx = struct {
    arena: std.mem.Allocator,
    keys: []const []const u8,
    out: ?Snapshot = null,
    failed: bool = false,

    fn take(self: *SnapshotCtx, node: *const graph_store.Node) bool {
        self.out = self.copy(node) catch {
            self.failed = true;
            return false;
        };
        return true;
    }

    fn copy(self: *SnapshotCtx, node: *const graph_store.Node) !Snapshot {
        const a = self.arena;
        const labels = try a.alloc([]const u8, node.labels.len);
        for (node.labels, labels) |l, *out| out.* = try a.dupe(u8, l);
        const values = try a.alloc(?PropertyValue, self.keys.len);
        for (self.keys, values) |k, *out| {
            out.* = if (node.properties.get(k)) |v| try clonePropertyValue(a, v) else null;
        }
        return .{
            .graph = try a.dupe(u8, node.graph_name),
            .tenant = try a.dupe(u8, node.tenant_id),
            .labels = labels,
            .values = values,
        };
    }
};

/// Node `id`'s graph, tenant, labels and `keys`' values, or null when no
/// such node exists (the statement deleted it again).
fn snapshotNode(arena: std.mem.Allocator, store: *graph_store.GraphStore, id: u64, keys: []const []const u8) Error!?Snapshot {
    var ctx: SnapshotCtx = .{ .arena = arena, .keys = keys };
    const found = store.residentNodeSatisfies(id, &ctx, SnapshotCtx.take) catch |err| return readFailed(err);
    if (ctx.failed) return error.OutOfMemory;
    if (!found) return null;
    return ctx.out;
}

fn readFailed(err: anyerror) Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    log.err("UNIQUE constraint check could not read the store; the statement is not kept", &.{Attr.string("error", @errorName(err))});
    return error.UniqueConstraintCheckFailed;
}

/// Whether node `node` holds the key: same graph and tenant tag, carries
/// the label, and every property equal (as MERGE compares) and not NULL.
const Holds = struct {
    graph: []const u8,
    tenant: []const u8,
    label: []const u8,
    keys: []const []const u8,
    values: []const PropertyValue,

    fn holds(self: *const Holds, node: *const graph_store.Node) bool {
        if (!std.mem.eql(u8, node.graph_name, self.graph)) return false;
        if (!std.mem.eql(u8, node.tenant_id, self.tenant)) return false;
        var labelled = false;
        for (node.labels) |l| {
            if (std.mem.eql(u8, l, self.label)) {
                labelled = true;
                break;
            }
        }
        if (!labelled) return false;
        for (self.keys, self.values) |k, expected| {
            const stored = node.properties.get(k) orelse return false;
            if (isNullish(stored)) return false;
            if (!value_equality.valuesEqual(property_codec.propertyValueToValue(stored), property_codec.propertyValueToValue(expected))) return false;
        }
        return true;
    }
};

/// A value the exact node-property index keys exactly as MERGE compares it
/// (a number of any representation, a plain string, a boolean).
fn exactIndexable(v: PropertyValue) bool {
    return switch (v) {
        .String, .Int, .Float, .Bool, .Decimal => true,
        .ExtValue => graph_store.GraphStore.isNumberProperty(v),
        .Null => false,
    };
}

/// Another node than `exclude` holding `values` under `label` in `graph`
/// for `tenant`, or null.
fn findOtherHolder(
    arena: std.mem.Allocator,
    store: *graph_store.GraphStore,
    holds: *const Holds,
    exclude: ?u64,
) Error!?u64 {
    var indexable = true;
    const kvs = try arena.alloc(PropKV, holds.keys.len);
    for (holds.keys, holds.values, kvs) |k, v, *kv| {
        kv.* = .{ .key = k, .value = v };
        if (!exactIndexable(v)) indexable = false;
    }
    const from_index: ?[]u64 = if (indexable)
        store.uniqueKeyCandidates(arena, holds.graph, holds.label, kvs) catch |err| return readFailed(err)
    else
        null;
    const ids = from_index orelse
        (store.snapshotNodesByLabel(arena, holds.graph, holds.label) catch |err| return readFailed(err)) orelse
        return null;
    for (ids) |id| {
        if (exclude) |x| if (id == x) continue;
        if (store.residentNodeSatisfies(id, holds, Holds.holds) catch |err| return readFailed(err)) return id;
    }
    return null;
}

/// The values of `rule`'s properties on `snap`, or null when one is missing
/// or NULL (no conflict is possible then).
fn ruleValues(arena: std.mem.Allocator, rule: ConstraintInfo, snap: Snapshot, keys: []const []const u8) !?[]PropertyValue {
    const values = try arena.alloc(PropertyValue, rule.properties.len);
    for (rule.properties, values) |p, *out| {
        const v = snap.value(keys, p) orelse return null;
        if (isNullish(v)) return null;
        out.* = v;
    }
    return values;
}

/// Every property name some rule names, once.
fn ruleKeys(arena: std.mem.Allocator, rules: []const ConstraintInfo) ![]const []const u8 {
    var keys = std.ArrayList([]const u8).empty;
    for (rules) |rule| {
        next: for (rule.properties) |p| {
            for (keys.items) |k| if (std.mem.eql(u8, k, p)) continue :next;
            try keys.append(arena, p);
        }
    }
    return keys.items;
}

// ---------------------------------------------------------------------------
// The statement-end check.
// ---------------------------------------------------------------------------

/// Whether `snap` holds every property `rule` names, none NULL.
fn holdsAll(rule: ConstraintInfo, snap: Snapshot, keys: []const []const u8) bool {
    for (rule.properties) |p| {
        const v = snap.value(keys, p) orelse return false;
        if (isNullish(v)) return false;
    }
    return true;
}

/// SONNY-2846: check the writes of the statement whose scope this thread
/// owns, before they are kept. See the module comment. SONNY-6281: the
/// existence rows too.
pub fn checkStatementWrites(cat: *catalog_mod.Catalog) Error!void {
    const changes = statement_undo.entries();
    const held = statement_proposals.heldCount();
    if (changes.len == 0 and held == 0) return;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rules = try cat.copyEnforcedConstraints(arena);
    if (rules.len == 0) return;

    if (held > 0 and cluster_mod.getGlobalClusterCoordinator() != null) {
        var i: usize = 0;
        while (i < held) : (i += 1) {
            const w = statement_proposals.heldWrite(i);
            if (w.mutation == .delete) continue;
            for (rules) |rule| {
                if (catalog_mod.rowInGraph(rule.graph, w.graph)) return error.ClusterWriteNotReplicable;
            }
        }
    }

    if (changes.len == 0) return;
    const store = statement_undo.recordStore() orelse return;
    const keys = try ruleKeys(arena, rules);

    var checked = std.AutoHashMap(u64, void).init(arena);
    for (changes) |change| {
        const id = switch (change) {
            .CreateNode => |e| e.node_id,
            .SetNodeProperty => |e| e.node_id,
            .AddNodeLabel => |e| e.node_id,
            // SONNY-6281: a removed property can break an existence row.
            .RemoveNodeProperty => |e| e.node_id,
            else => continue,
        };
        if ((try checked.getOrPut(id)).found_existing) continue;
        const snap = (try snapshotNode(arena, store, id, keys)) orelse continue;
        for (rules) |rule| {
            if (!catalog_mod.rowInGraph(rule.graph, snap.graph)) continue;
            if (!snap.hasLabel(rule.label)) continue;
            if (catalog_mod.enforcesExistence(rule) and !holdsAll(rule, snap, keys)) {
                setNotNullViolation(rule);
                return error.NotNullConstraintViolation;
            }
            if (!catalog_mod.enforcesUnique(rule)) continue;
            const values = (try ruleValues(arena, rule, snap, keys)) orelse continue;
            const holds = Holds{ .graph = snap.graph, .tenant = snap.tenant, .label = rule.label, .keys = rule.properties, .values = values };
            if ((try findOtherHolder(arena, store, &holds, id)) != null) {
                setViolation(rule);
                return error.UniqueConstraintViolation;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// CREATE CONSTRAINT over existing data.
// ---------------------------------------------------------------------------

/// SONNY-2846: how many groups of nodes of `label` in `graph` (two or more
/// nodes of one tenant tag holding equal, non-NULL values of `props`) exist
/// already. CREATE CONSTRAINT refuses a UNIQUE constraint when any does.
pub fn countDuplicateGroups(store: *graph_store.GraphStore, graph: []const u8, label: []const u8, props: []const []const u8) Error!usize {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ids = (store.snapshotNodesByLabel(arena, graph, label) catch |err| return readFailed(err)) orelse return 0;

    // Keyed values (numbers, strings, booleans): grouped by MERGE's own value
    // key (`writeMergeValue`), so 1 and 1.0 are one value. Anything else is
    // compared pairwise, as `valuesEqual` decides.
    var groups = std.StringHashMap(u32).init(arena);
    const Other = struct { tenant: []const u8, values: []PropertyValue, group: bool = false };
    var others = std.ArrayList(Other).empty;

    for (ids) |id| {
        const snap = (try snapshotNode(arena, store, id, props)) orelse continue;
        if (!std.mem.eql(u8, snap.graph, graph) or !snap.hasLabel(label)) continue;
        const values = try arena.alloc(PropertyValue, props.len);
        var complete = true;
        for (snap.values, values) |v, *out| {
            const pv = v orelse {
                complete = false;
                break;
            };
            if (isNullish(pv)) {
                complete = false;
                break;
            }
            out.* = pv;
        }
        if (!complete) continue;

        var key = std.ArrayList(u8).empty;
        try key.appendSlice(arena, snap.tenant);
        try key.append(arena, 0);
        var keyed = true;
        for (values) |v| {
            var buf: [1024]u8 = undefined;
            const len = graph_store.GraphStore.writeMergeValue(&buf, v) orelse {
                keyed = false;
                break;
            };
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @intCast(len), .little);
            try key.appendSlice(arena, &len_buf);
            try key.appendSlice(arena, buf[0..len]);
        }
        if (keyed) {
            const gop = try groups.getOrPut(key.items);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        } else {
            try others.append(arena, .{ .tenant = snap.tenant, .values = values });
        }
    }

    var n: usize = 0;
    var it = groups.valueIterator();
    while (it.next()) |count| {
        if (count.* > 1) n += 1;
    }
    for (others.items, 0..) |*a, i| {
        if (a.group) continue;
        var found = false;
        for (others.items[i + 1 ..]) |*b| {
            if (b.group or !std.mem.eql(u8, a.tenant, b.tenant)) continue;
            var equal = true;
            for (a.values, b.values) |av, bv| {
                if (!value_equality.valuesEqual(property_codec.propertyValueToValue(av), property_codec.propertyValueToValue(bv))) {
                    equal = false;
                    break;
                }
            }
            if (equal) {
                b.group = true;
                found = true;
            }
        }
        if (found) n += 1;
    }
    return n;
}

/// The message of a CREATE CONSTRAINT refused over `groups` groups of
/// duplicates.
pub fn setDuplicatesMessage(name: []const u8, label: []const u8, props: []const []const u8, groups: usize) void {
    var pbuf: [256]u8 = undefined;
    setMessage("unique_violation: CREATE CONSTRAINT {s} refused: {d} groups of :{s} nodes already share a value of ({s}); remove the duplicates first", .{ name, groups, label, joinedProps(&pbuf, props) });
}

// ---------------------------------------------------------------------------
// SONNY-6281: CREATE CONSTRAINT (NOT NULL / EXISTS / NODE KEY) over existing
// data.
// ---------------------------------------------------------------------------

/// How many nodes of `label` in `graph` lack one of `props` (absent or
/// NULL). CREATE CONSTRAINT refuses an existence row when any does.
pub fn countNodesMissing(store: *graph_store.GraphStore, graph: []const u8, label: []const u8, props: []const []const u8) Error!usize {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ids = (store.snapshotNodesByLabel(arena, graph, label) catch |err| return readFailed(err)) orelse return 0;
    var n: usize = 0;
    for (ids) |id| {
        const snap = (try snapshotNode(arena, store, id, props)) orelse continue;
        if (!std.mem.eql(u8, snap.graph, graph) or !snap.hasLabel(label)) continue;
        for (snap.values) |v| {
            const pv = v orelse {
                n += 1;
                break;
            };
            if (isNullish(pv)) {
                n += 1;
                break;
            }
        }
    }
    return n;
}

/// The message of a CREATE CONSTRAINT refused over `missing` nodes that
/// lack a required property.
pub fn setMissingMessage(name: []const u8, label: []const u8, props: []const []const u8, missing: usize) void {
    var pbuf: [256]u8 = undefined;
    setNotNullMessage("not_null_violation: CREATE CONSTRAINT {s} refused: {d} :{s} nodes lack a value for ({s}); set it or remove those nodes first", .{ name, missing, label, joinedProps(&pbuf, props) });
}
