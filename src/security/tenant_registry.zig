// CANARY: REQ=REQ-TENANT-LIFECYCLE-001; FEATURE="TenantRegistry"; ASPECT=DurableRegistry; STATUS=TESTED; TEST=tests/test_gap0839_tenant_lifecycle.zig; OWNER=security; UPDATED=2026-06-08
//
// GAP-0839: a first-class, DURABLE tenant lifecycle registry.
//
// Before this, a tenant only "existed" implicitly by data being tagged with its
// `tenant_id`. There was no create/list/show/drop surface, no place to record a
// tenant's parent (for the GAP-0838 HierarchyManager), and no production seam to
// configure per-tenant quotas (GAP-0289 `setQuota` was tests-only). This module
// is the missing registry: a process-wide, file-backed set of known tenants that
// SURVIVES RESTART.
//
// PERSISTENCE MECHANISM (chosen): a single append-on-mutate JSON-lines file,
// `{data_dir}/tenants/registry.jsonl`, one JSON object per tenant, rewritten
// atomically (temp file + rename) whenever the registry mutates. This is the
// SIMPLEST durable mechanism that fits (the task explicitly allows a durable
// file-backed registry): no WAL, no HMAC chain, no second graph to hydrate. It
// mirrors how the timeseries Store persists under `{data_dir}/timeseries`. The
// registry is small (one line per tenant, onboard/offboard cadence), so a full
// atomic rewrite per mutation is correct and cheap. If `data_dir` is null
// (CLI/test/in-memory server), the registry runs in-memory only and logs that it
// is non-durable — it is NOT silently in-memory (per the GAP-0839 scope guard).
//
// Thread-safety: `mu` (a leaf-level std.Io.Mutex) guards the `tenants` map and
// the persistence file. It is never held while acquiring any other geode lock,
// matching the tenant_quota leaf-lock posture.

const std = @import("std");

const logging = @import("logging");
const log = logging.scoped("tenant_registry");
const Attr = logging.Attr;

/// GAP-0848 follow-up: the implicit/sentinel tenant id used when a request has
/// no concrete tenant scope. This MUST equal `graph_store.DEFAULT_TENANT_ID`
/// (the constant `tenancy.isConcreteScope` compares against) — `hasNonDefaultTenant`
/// excludes exactly this id so the multi-tenant signal matches the strict-tenancy
/// resolver's notion of "no concrete scope". The two definitions are kept in sync
/// by a `comptime` assertion in `src/execution/tenancy.zig` (which has both this
/// module and graph_store in scope) rather than importing the heavy graph_store
/// module into this leaf registry. `tenant_registry.zig` is built standalone by
/// the `test-tenant-registry` target and intentionally depends only on `logging`.
pub const DEFAULT_TENANT_ID = "default";

/// Zig 0.16 compat: std.time.milliTimestamp was removed. Wall-clock millis.
fn nowMillis() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// The threaded single-threaded Io handle used for all registry file IO
/// (matches graph_storage_adapter's timeseries mkdir path).
fn registryIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const RegistryError = error{
    TenantAlreadyExists,
    TenantNotFound,
    InvalidTenantId,
    TenantHasChildren,
    TenantReserved,
    /// SONNY-6567 (4): the parent is being dropped (`markDropping`).
    TenantDropping,
};

/// One persisted tenant record. `quota` is optional: a null quota means the
/// tenant resolves to the default quota in tenant_quota (no override row).
pub const TenantRecord = struct {
    // Owned by the registry (duped on register, freed on drop/deinit).
    tenant_id: []const u8,
    parent: ?[]const u8 = null,
    created_at_ms: i64 = 0,
    active: bool = true,
    // Quota override. When present, the four fields mirror tenant_quota.TenantQuota.
    has_quota: bool = false,
    max_connections: u32 = 0,
    max_concurrent_queries: u32 = 0,
    max_graphs: u32 = 0,
    max_nodes_per_graph: u64 = 0,
};

/// A durable, process-wide registry of known tenants.
pub const TenantRegistry = struct {
    allocator: std.mem.Allocator,
    tenants: std.StringHashMapUnmanaged(TenantRecord),
    mu: std.Io.Mutex,
    /// Owned copy of `{data_dir}/tenants` (null => in-memory only / non-durable).
    dir_path: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) TenantRegistry {
        return .{
            .allocator = allocator,
            .tenants = .empty,
            .mu = .init,
            .dir_path = null,
        };
    }

    // CANARY: REQ=REQ-SONNY-6346-NO-SILENT-DEGRADE; FEATURE="TenantRegistry"; ASPECT=DurableOrError; STATUS=TESTED; TEST=tests/test_sonny6346_silent_degrade_audit_housekeeping.zig; OWNER=security; UPDATED=2026-11-12
    /// Initialize a durable registry rooted at `{data_dir}/tenants`. Creates the
    /// directory if missing and hydrates any previously persisted tenants. A
    /// null `data_dir` yields the in-memory (non-durable) variant.
    /// SONNY-6346: a directory that cannot be created, or a registry file that
    /// cannot be read, is an error. It fell back to an in-memory registry with
    /// a warning (an unreadable file hydrated nothing), so the tenants created
    /// afterwards, or all of them, were gone at the next restart.
    pub fn initWithDataDir(allocator: std.mem.Allocator, data_dir: ?[]const u8) !TenantRegistry {
        var self = TenantRegistry.init(allocator);
        errdefer self.deinit();
        if (data_dir) |dd| {
            const dir_path = try std.fmt.allocPrint(allocator, "{s}/tenants", .{dd});
            std.Io.Dir.cwd().createDirPath(registryIo(), dir_path) catch |err| {
                log.err("tenant_registry.makepath_failed", &.{
                    Attr.string("dir", dir_path),
                    Attr.string("error", @errorName(err)),
                });
                allocator.free(dir_path);
                return error.TenantRegistryUnavailable;
            };
            self.dir_path = dir_path;
            try self.hydrate();
        } else {
            log.warn("tenant_registry.non_durable_no_data_dir", &.{});
        }
        return self;
    }

    pub fn deinit(self: *TenantRegistry) void {
        var it = self.tenants.iterator();
        while (it.next()) |entry| {
            self.freeRecord(entry.value_ptr);
        }
        self.tenants.deinit(self.allocator);
        if (self.dir_path) |dp| self.allocator.free(dp);
    }

    fn freeRecord(self: *TenantRegistry, rec: *TenantRecord) void {
        self.allocator.free(rec.tenant_id);
        if (rec.parent) |p| self.allocator.free(p);
    }

    fn validId(id: []const u8) bool {
        if (id.len == 0 or id.len > 256) return false;
        // No control chars, no whitespace, no quotes/braces that would corrupt
        // the JSONL line. Conservative allow-list keeps persistence trivial.
        for (id) |c| {
            if (c < 0x20 or c == '"' or c == '\\' or c == '{' or c == '}' or c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                return false;
            }
        }
        return true;
    }

    // ── Mutations ─────────────────────────────────────────────────────────

    /// Register a new tenant. `tenant_id` and `parent` are BORROWED (the
    /// registry dupes what it owns). If `parent` is set it must already exist.
    /// Persists the updated registry before returning.
    pub fn create(self: *TenantRegistry, tenant_id: []const u8, parent: ?[]const u8) !void {
        if (!validId(tenant_id)) return RegistryError.InvalidTenantId;
        if (parent) |p| if (!validId(p)) return RegistryError.InvalidTenantId;

        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.tenants.contains(tenant_id)) return RegistryError.TenantAlreadyExists;
        if (parent) |p| {
            const prec = self.tenants.get(p) orelse return RegistryError.TenantNotFound;
            // SONNY-6567 (4): no child under a tenant being dropped (its
            // cascade has snapshotted its children already).
            if (!prec.active) return RegistryError.TenantDropping;
        }

        const owned_id = try self.allocator.dupe(u8, tenant_id);
        errdefer self.allocator.free(owned_id);
        var owned_parent: ?[]const u8 = null;
        if (parent) |p| {
            owned_parent = try self.allocator.dupe(u8, p);
        }
        errdefer if (owned_parent) |op| self.allocator.free(op);

        try self.tenants.put(self.allocator, owned_id, .{
            .tenant_id = owned_id,
            .parent = owned_parent,
            .created_at_ms = nowMillis(),
            .active = true,
            .has_quota = false,
        });

        // CANARY: REQ=REQ-SONNY-6567-TENANT-DROP-FAILURES; FEATURE="TenantRegistry"; ASPECT=PersistOrRestore; STATUS=TESTED; TEST=tests/test_sonny6567_tenant_drop_failures.zig; OWNER=security; UPDATED=2026-11-15
        // SONNY-6567 (4): a write of the file that fails fails the create and
        // takes the record back out. It was logged and the create reported
        // success: the tenant was gone at the next restart.
        self.persist() catch |err| {
            self.logPersistFailed("create", tenant_id, err);
            _ = self.tenants.remove(owned_id);
            return err;
        };
    }

    fn logPersistFailed(_: *TenantRegistry, op: []const u8, tenant_id: []const u8, err: anyerror) void {
        log.err("tenant_registry.persist_failed: the change was not made", &.{
            Attr.string("op", op),
            Attr.string("tenant", tenant_id),
            Attr.string("error", @errorName(err)),
        });
    }

    /// SONNY-6567 (4): mark `tenant_id` as being dropped (`active = false`),
    /// written to the file before it returns, or not marked and an error. A
    /// tenant DROP marks the tenant before it removes anything, so a drop
    /// that fails part-way leaves it registered and visibly inactive
    /// (`geode.tenant.list` / `show`), across a restart, until a retry
    /// finishes; no child tenant can be created under it meanwhile.
    pub fn markDropping(self: *TenantRegistry, tenant_id: []const u8) !void {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        if (std.mem.eql(u8, tenant_id, DEFAULT_TENANT_ID)) return RegistryError.TenantReserved;
        const rec = self.tenants.getPtr(tenant_id) orelse return RegistryError.TenantNotFound;
        if (!rec.active) return;
        rec.active = false;
        self.persist() catch |err| {
            self.logPersistFailed("mark_dropping", tenant_id, err);
            rec.active = true;
            return err;
        };
    }

    /// Drop a tenant from the registry. Returns TenantNotFound if absent.
    /// Note: this removes the lifecycle record only; it does NOT delete the
    /// tenant's data rows (that is a separate, heavier operation deferred here).
    ///
    /// GAP-0847 follow-up — two registry-side safety guards independent of any
    /// external engine being wired:
    ///   • The reserved `DEFAULT_TENANT_ID` ("default") can NEVER be dropped
    ///     (`TenantReserved`). It is the sentinel scope for every untagged row;
    ///     cascading it would delete the whole store.
    ///   • A tenant that any OTHER registry record lists as its `parent` cannot
    ///     be dropped (`TenantHasChildren`). This closes the seam where the
    ///     expr-RLS hierarchy engine (the tenant_dispatch child guard) is not
    ///     wired: the durable registry's parent links are the source of truth
    ///     for the hierarchy, so we refuse to orphan descendants here too.
    pub fn drop(self: *TenantRegistry, tenant_id: []const u8) !void {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        if (std.mem.eql(u8, tenant_id, DEFAULT_TENANT_ID)) return RegistryError.TenantReserved;

        // Refuse if any other record names this tenant as its parent.
        var it = self.tenants.valueIterator();
        while (it.next()) |rec| {
            if (rec.parent) |p| {
                if (std.mem.eql(u8, p, tenant_id)) return RegistryError.TenantHasChildren;
            }
        }

        const entry = self.tenants.fetchRemove(tenant_id) orelse return RegistryError.TenantNotFound;
        // SONNY-6567 (4): the record is freed only once the file no longer
        // has it. A write that fails puts it back (the slot `fetchRemove`
        // freed is still there) and fails the drop; it was logged and the
        // drop reported success, and the tenant came back at the next
        // restart.
        self.persist() catch |err| {
            self.logPersistFailed("drop", tenant_id, err);
            self.tenants.putAssumeCapacity(entry.key, entry.value);
            return err;
        };
        var rec = entry.value;
        self.freeRecord(&rec);
    }

    /// Set (or replace) a tenant's quota override. Returns TenantNotFound if the
    /// tenant is not registered. Persists before returning.
    pub fn setQuota(
        self: *TenantRegistry,
        tenant_id: []const u8,
        max_connections: u32,
        max_concurrent_queries: u32,
        max_graphs: u32,
        max_nodes_per_graph: u64,
    ) !void {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        const rec = self.tenants.getPtr(tenant_id) orelse return RegistryError.TenantNotFound;
        const before = rec.*;
        rec.has_quota = true;
        rec.max_connections = max_connections;
        rec.max_concurrent_queries = max_concurrent_queries;
        rec.max_graphs = max_graphs;
        rec.max_nodes_per_graph = max_nodes_per_graph;

        // SONNY-6567 (4): as `create` (it reported success and the quota
        // was gone at the next restart).
        self.persist() catch |err| {
            self.logPersistFailed("set_quota", tenant_id, err);
            rec.* = before;
            return err;
        };
    }

    // ── Reads ─────────────────────────────────────────────────────────────

    /// SONNY-6607 (4): is `tenant_id` registered and marked as being dropped
    /// (a drop that failed part-way, `markDropping`)? Its sessions are
    /// refused (`tenancy.refuseDroppingTenant`).
    pub fn isDropping(self: *TenantRegistry, tenant_id: []const u8) bool {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        const rec = self.tenants.get(tenant_id) orelse return false;
        return !rec.active;
    }

    pub fn contains(self: *TenantRegistry, tenant_id: []const u8) bool {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.tenants.contains(tenant_id);
    }

    pub fn count(self: *TenantRegistry) usize {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.tenants.count();
    }

    // CANARY: REQ=REQ-GAP-0848-TENANCY-DEFAULT-001; FEATURE="StrictTenancyAutoDefault"; ASPECT=MultiTenantSignal; STATUS=TESTED; TEST=tests/test_gap0848_tenancy_default.zig; OWNER=security; UPDATED=2026-06-09
    /// GAP-0848: the "this deployment is multi-tenant" signal. Returns true when
    /// the registry holds at least one tenant whose id is NOT the implicit
    /// `DEFAULT_TENANT_ID` sentinel. A registered non-default tenant is the most
    /// truthful O(n) signal that an operator has provisioned real tenants (via
    /// `CALL geode.tenant.create`, which is the only way a record lands here), so
    /// permissive (null=all-tenants) resolution would be a cross-tenant leak.
    /// The `DEFAULT_TENANT_ID` tenant is excluded so that a single-tenant
    /// deployment that happened to register `"default"` does not flip the signal.
    /// `DEFAULT_TENANT_ID` mirrors `graph_store.DEFAULT_TENANT_ID`, the same
    /// constant `tenancy.isConcreteScope` compares against (drift is caught by a
    /// comptime assertion in `src/execution/tenancy.zig`).
    pub fn hasNonDefaultTenant(self: *TenantRegistry) bool {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        var it = self.tenants.iterator();
        while (it.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, DEFAULT_TENANT_ID)) return true;
        }
        return false;
    }

    /// Copy a tenant's record into `out` (caller-owned dupes of id/parent). The
    /// caller must free `out.tenant_id` and `out.parent` (if non-null) with
    /// `caller_allocator`. Returns TenantNotFound if absent.
    pub fn get(self: *TenantRegistry, caller_allocator: std.mem.Allocator, tenant_id: []const u8) !TenantRecord {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        const rec = self.tenants.get(tenant_id) orelse return RegistryError.TenantNotFound;
        return try dupeRecord(caller_allocator, rec);
    }

    /// Snapshot all tenant records into a caller-owned slice. Each record's
    /// `tenant_id`/`parent` are duped with `caller_allocator`; free with
    /// `freeRecordSlice`.
    pub fn list(self: *TenantRegistry, caller_allocator: std.mem.Allocator) ![]TenantRecord {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        const out = try caller_allocator.alloc(TenantRecord, self.tenants.count());
        errdefer caller_allocator.free(out);
        var i: usize = 0;
        var it = self.tenants.iterator();
        while (it.next()) |entry| : (i += 1) {
            out[i] = try dupeRecord(caller_allocator, entry.value_ptr.*);
        }
        return out;
    }

    pub fn freeRecordSlice(caller_allocator: std.mem.Allocator, recs: []TenantRecord) void {
        for (recs) |rec| {
            caller_allocator.free(rec.tenant_id);
            if (rec.parent) |p| caller_allocator.free(p);
        }
        caller_allocator.free(recs);
    }

    fn dupeRecord(a: std.mem.Allocator, rec: TenantRecord) !TenantRecord {
        var copy = rec;
        copy.tenant_id = try a.dupe(u8, rec.tenant_id);
        errdefer a.free(copy.tenant_id);
        copy.parent = if (rec.parent) |p| try a.dupe(u8, p) else null;
        return copy;
    }

    // ── Persistence ───────────────────────────────────────────────────────

    /// Atomically rewrite the on-disk registry from the in-memory map. No-op
    /// when non-durable (dir_path == null). Caller must hold `mu`.
    fn persist(self: *TenantRegistry) !void {
        const dir_path = self.dir_path orelse return;

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;

        var it = self.tenants.iterator();
        while (it.next()) |entry| {
            const rec = entry.value_ptr.*;
            try w.print("{{\"tenant_id\":\"{s}\"", .{rec.tenant_id});
            if (rec.parent) |p| {
                try w.print(",\"parent\":\"{s}\"", .{p});
            } else {
                try w.writeAll(",\"parent\":null");
            }
            try w.print(",\"created_at_ms\":{d},\"active\":{s}", .{
                rec.created_at_ms,
                if (rec.active) "true" else "false",
            });
            if (rec.has_quota) {
                try w.print(
                    ",\"has_quota\":true,\"max_connections\":{d},\"max_concurrent_queries\":{d},\"max_graphs\":{d},\"max_nodes_per_graph\":{d}",
                    .{ rec.max_connections, rec.max_concurrent_queries, rec.max_graphs, rec.max_nodes_per_graph },
                );
            } else {
                try w.writeAll(",\"has_quota\":false");
            }
            try w.writeAll("}\n");
        }

        // Atomic write: temp file + rename.
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}/registry.jsonl.tmp", .{dir_path});
        defer self.allocator.free(tmp_path);
        const final_path = try std.fmt.allocPrint(self.allocator, "{s}/registry.jsonl", .{dir_path});
        defer self.allocator.free(final_path);

        const io = registryIo();
        {
            const f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
            defer f.close(io);
            try f.writeStreamingAll(io, aw.written());
            // error-policy: C — fsync before rename is the durability point of
            // the atomic-write protocol; swallowing the error could publish an
            // empty/partial registry after a crash. Callers log persist failures.
            try f.sync(io);
        }
        try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), final_path, io);
    }

    /// Load persisted tenants from disk into the in-memory map. No-op when
    /// non-durable or the file is missing. Called once at init (no lock needed —
    /// init runs before the registry is published).
    fn hydrate(self: *TenantRegistry) !void {
        const dir_path = self.dir_path orelse return;
        const final_path = try std.fmt.allocPrint(self.allocator, "{s}/registry.jsonl", .{dir_path});
        defer self.allocator.free(final_path);

        const data = std.Io.Dir.cwd().readFileAlloc(
            registryIo(),
            final_path,
            self.allocator,
            std.Io.Limit.limited(16 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => return,
            else => {
                // SONNY-6346: an unreadable registry is an error, not an
                // empty one.
                log.err("tenant_registry.hydrate_read_failed", &.{Attr.string("error", @errorName(err))});
                return error.TenantRegistryUnavailable;
            },
        };
        defer self.allocator.free(data);

        // CANARY: REQ=REQ-SONNY-6348-TENANT-REGISTRY-CORRUPT; FEATURE="TenantRegistry"; ASPECT=CorruptLineRefused; STATUS=TESTED; TEST=tests/test_sonny6348_readonly_restore_checks_registry.zig; OWNER=security; UPDATED=2026-11-12
        // SONNY-6348: a line that cannot become a tenant (not JSON, not an
        // object, no valid string tenant_id, a parent that is not a string,
        // a repeated id) is an error. It was skipped with a warning, so that
        // tenant was silently gone. The file is rewritten whole on every
        // change (temp file + rename), so a bad line is corruption.
        var hydrated: usize = 0;
        var line_no: usize = 0;
        var line_it = std.mem.splitScalar(u8, data, '\n');
        while (line_it.next()) |line| {
            line_no += 1;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, trimmed, .{}) catch |err| {
                return corruptLine(line_no, @errorName(err));
            };
            defer parsed.deinit();
            const obj = switch (parsed.value) {
                .object => |o| o,
                else => return corruptLine(line_no, "not a JSON object"),
            };
            const id_v = obj.get("tenant_id") orelse return corruptLine(line_no, "no tenant_id");
            const id_str = switch (id_v) {
                .string => |s| s,
                else => return corruptLine(line_no, "tenant_id is not a string"),
            };
            if (!validId(id_str)) return corruptLine(line_no, "tenant_id is not a valid tenant id");
            if (self.tenants.contains(id_str)) return corruptLine(line_no, "tenant_id repeats an earlier line");
            if (obj.get("parent")) |pv| switch (pv) {
                .string, .null => {},
                else => return corruptLine(line_no, "parent is not a string"),
            };

            const owned_id = try self.allocator.dupe(u8, id_str);
            errdefer self.allocator.free(owned_id);

            var owned_parent: ?[]const u8 = null;
            if (obj.get("parent")) |pv| {
                switch (pv) {
                    .string => |ps| owned_parent = try self.allocator.dupe(u8, ps),
                    else => {},
                }
            }
            errdefer if (owned_parent) |op| self.allocator.free(op);

            var rec = TenantRecord{
                .tenant_id = owned_id,
                .parent = owned_parent,
                .created_at_ms = if (obj.get("created_at_ms")) |v| (switch (v) {
                    .integer => |n| n,
                    else => 0,
                }) else 0,
                .active = if (obj.get("active")) |v| (switch (v) {
                    .bool => |b| b,
                    else => true,
                }) else true,
            };
            if (obj.get("has_quota")) |hv| {
                if (hv == .bool and hv.bool) {
                    rec.has_quota = true;
                    rec.max_connections = jsonU32(obj, "max_connections");
                    rec.max_concurrent_queries = jsonU32(obj, "max_concurrent_queries");
                    rec.max_graphs = jsonU32(obj, "max_graphs");
                    rec.max_nodes_per_graph = jsonU64(obj, "max_nodes_per_graph");
                }
            }

            try self.tenants.put(self.allocator, owned_id, rec);
            hydrated += 1;
        }

        if (hydrated > 0) {
            log.info("tenant_registry.hydrated", &.{Attr.int("count", @intCast(hydrated))});
        }
    }

    fn corruptLine(line_no: usize, why: []const u8) error{TenantRegistryCorrupt} {
        log.err("tenant_registry.hydrate_corrupt_line", &.{
            Attr.uint("line", @intCast(line_no)),
            Attr.string("reason", why),
        });
        return error.TenantRegistryCorrupt;
    }

    fn jsonU32(obj: std.json.ObjectMap, key: []const u8) u32 {
        if (obj.get(key)) |v| {
            if (v == .integer and v.integer >= 0 and v.integer <= std.math.maxInt(u32)) {
                return @intCast(v.integer);
            }
        }
        return 0;
    }

    fn jsonU64(obj: std.json.ObjectMap, key: []const u8) u64 {
        if (obj.get(key)) |v| {
            if (v == .integer and v.integer >= 0) return @intCast(v.integer);
        }
        return 0;
    }
};

// ── Global singleton ───────────────────────────────────────────────────────
// Mirrors tenant_quota's global-singleton pattern. Set once at server startup;
// read by the geode.tenant.* dispatcher.

var g_global_registry: ?*TenantRegistry = null;

pub fn setGlobalRegistry(reg: ?*TenantRegistry) void {
    g_global_registry = reg;
}

pub fn getGlobalRegistry() ?*TenantRegistry {
    return g_global_registry;
}

// ============================================================================
// Tests (in-file: registry mechanics + durability via a tmp data dir)
// ============================================================================

test "TenantRegistry: create / contains / count in-memory" {
    var reg = TenantRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expect(!reg.contains("acme"));
    try reg.create("acme", null);
    try std.testing.expect(reg.contains("acme"));
    try std.testing.expectEqual(@as(usize, 1), reg.count());

    // Duplicate rejected.
    try std.testing.expectError(RegistryError.TenantAlreadyExists, reg.create("acme", null));
}

test "TenantRegistry: create with unknown parent rejected; known parent accepted" {
    var reg = TenantRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expectError(RegistryError.TenantNotFound, reg.create("child", "ghost"));
    try reg.create("acme", null);
    try reg.create("acme-bu1", "acme");

    const rec = try reg.get(std.testing.allocator, "acme-bu1");
    defer {
        std.testing.allocator.free(rec.tenant_id);
        if (rec.parent) |p| std.testing.allocator.free(p);
    }
    try std.testing.expectEqualStrings("acme", rec.parent.?);
}

test "TenantRegistry: invalid tenant id rejected" {
    var reg = TenantRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectError(RegistryError.InvalidTenantId, reg.create("", null));
    try std.testing.expectError(RegistryError.InvalidTenantId, reg.create("has space", null));
    try std.testing.expectError(RegistryError.InvalidTenantId, reg.create("has\"quote", null));
}

test "TenantRegistry: setQuota records override; getQuota reflects it" {
    var reg = TenantRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expectError(RegistryError.TenantNotFound, reg.setQuota("acme", 5, 2, 10, 500));
    try reg.create("acme", null);
    try reg.setQuota("acme", 5, 2, 10, 500);

    const rec = try reg.get(std.testing.allocator, "acme");
    defer {
        std.testing.allocator.free(rec.tenant_id);
        if (rec.parent) |p| std.testing.allocator.free(p);
    }
    try std.testing.expect(rec.has_quota);
    try std.testing.expectEqual(@as(u32, 5), rec.max_connections);
    try std.testing.expectEqual(@as(u32, 2), rec.max_concurrent_queries);
    try std.testing.expectEqual(@as(u32, 10), rec.max_graphs);
    try std.testing.expectEqual(@as(u64, 500), rec.max_nodes_per_graph);
}

test "TenantRegistry: drop removes the tenant" {
    var reg = TenantRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.create("acme", null);
    try reg.drop("acme");
    try std.testing.expect(!reg.contains("acme"));
    try std.testing.expectError(RegistryError.TenantNotFound, reg.drop("acme"));
}

test "TenantRegistry: drop refuses the reserved default tenant" {
    var reg = TenantRegistry.init(std.testing.allocator);
    defer reg.deinit();
    // "default" is never created (it is the implicit sentinel scope), but even if
    // an operator registers it, dropping it is refused.
    try reg.create(DEFAULT_TENANT_ID, null);
    try std.testing.expectError(RegistryError.TenantReserved, reg.drop(DEFAULT_TENANT_ID));
    try std.testing.expect(reg.contains(DEFAULT_TENANT_ID));
}

test "TenantRegistry: drop refuses a parent with children (registry-side hierarchy guard)" {
    var reg = TenantRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.create("acme", null);
    try reg.create("acme-bu1", "acme");

    // Dropping the parent while a child names it as parent is refused — closing
    // the seam where the expr-RLS hierarchy engine is not wired.
    try std.testing.expectError(RegistryError.TenantHasChildren, reg.drop("acme"));
    try std.testing.expect(reg.contains("acme"));
    try std.testing.expect(reg.contains("acme-bu1"));

    // After the child is dropped (it is a leaf), the parent drops cleanly.
    try reg.drop("acme-bu1");
    try reg.drop("acme");
    try std.testing.expect(!reg.contains("acme"));
}

test "TenantRegistry: list snapshots all records" {
    var reg = TenantRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.create("a", null);
    try reg.create("b", null);
    try reg.create("a-c", "a");

    const recs = try reg.list(std.testing.allocator);
    defer TenantRegistry.freeRecordSlice(std.testing.allocator, recs);
    try std.testing.expectEqual(@as(usize, 3), recs.len);
}

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build the absolute path of a
// testing.tmpDir from cwd + its sub_path (mirrors auth_graph_manager's helper).
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

test "TenantRegistry: durable round-trip (persist + hydrate after reopen)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(std.testing.allocator, &tmp.sub_path);
    defer std.testing.allocator.free(data_dir);

    {
        var reg = try TenantRegistry.initWithDataDir(std.testing.allocator, data_dir);
        defer reg.deinit();
        try reg.create("acme", null);
        try reg.create("acme-bu1", "acme");
        try reg.setQuota("acme-bu1", 7, 3, 11, 999);
        // Exercise drop-persistence on a throwaway LEAF tenant (the parent "acme"
        // can no longer be dropped while "acme-bu1" names it as parent — see the
        // registry-side hierarchy guard). create/drop must both rewrite the file.
        try reg.create("scratch", null);
        try reg.drop("scratch");
    }

    // Reopen: a fresh registry must hydrate the persisted tenants.
    {
        var reg2 = try TenantRegistry.initWithDataDir(std.testing.allocator, data_dir);
        defer reg2.deinit();
        try std.testing.expect(reg2.contains("acme"));
        try std.testing.expect(reg2.contains("acme-bu1"));

        const rec = try reg2.get(std.testing.allocator, "acme-bu1");
        defer {
            std.testing.allocator.free(rec.tenant_id);
            if (rec.parent) |p| std.testing.allocator.free(p);
        }
        try std.testing.expectEqualStrings("acme", rec.parent.?);
        try std.testing.expect(rec.has_quota);
        try std.testing.expectEqual(@as(u32, 7), rec.max_connections);
        try std.testing.expectEqual(@as(u64, 999), rec.max_nodes_per_graph);
    }
}
