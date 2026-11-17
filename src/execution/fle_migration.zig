// CANARY: REQ=REQ-SONNY-6688-FLE-MIGRATE-ENCRYPT; FEATURE="FieldLevelEncryption"; ASPECT=MigrateExistingPlaintext; STATUS=TESTED; TEST=tests/test_sonny6688_fle_migrate_encrypt.zig; OWNER=security; UPDATED=2026-11-16
//! SONNY-6688: encrypt the values a field held before it was configured as
//! encrypted (`CALL geode.fle.migrateEncrypt`, `geode fle migrate-encrypt`).
//!
//! `geode.fle.configureField` encrypts values written after it; values
//! already stored stayed plaintext on disk, and nothing migrated them (the
//! storage callback `fle_commands.migrateEncrypt` ran through was never
//! set). This walks the stored records of the field's type through the
//! graph store and writes every plaintext string value back: the store's
//! write primitive seals it under the one FLE record identity
//! (`fle_integration.sealStoredString`, SONNY-6335/6347), the identity every
//! reader decrypts under, so the value reads as before for a permitted role.
//!
//!   * Which records: nodes whose FIRST label is the type (the label a value
//!     is encrypted under) and relationships of the type, in one graph (the
//!     procedure's graph argument, `default` without one; never an internal
//!     graph, and only one the caller may bind).
//!   * Tenancy: only records the session's tenant sees
//!     (`tenant_visibility.passesTenantFilter*`); a tenant named by the
//!     caller must be the session's own when it has one (else 42501).
//!   * RLS: a node the session's row policies hide is not touched (counted
//!     `skipped_rls`); the run then reports `complete = false`.
//!   * Nothing left on disk (SONNY-6692): when the run reports `complete`,
//!     no plaintext of the field is in any file of the data directory.
//!     After the last batch the graph's dead space is overwritten
//!     (graph-storage `scrubDeadSpace`: freed property and var-store pages,
//!     including the spill pages of values larger than a page, and
//!     tombstoned slab blobs, including the copies an update before the
//!     migration left) and the graph is checkpointed in full, which writes
//!     the cleared pages and truncates the WAL that held the old images
//!     (`StorageAdapter.scrubGraphDeadSpace`). It runs under the request's
//!     write lock on the graph (held as it is) or takes it.
//!   * Not left on disk: graph-storage keeps a replaced value's bytes in
//!     the tombstoned slot it moves out of (the undo needs them), so a plain
//!     overwrite left the plaintext in `props.store`. Each value is removed
//!     first (the record's property blob is rewritten in place, shrunk, the
//!     freed bytes zeroed) and then set to its envelope. A value too large
//!     for a property page (spilled to the var store, over a page) keeps
//!     its old pages' bytes until they are reused (docs/FIELD_LEVEL_ENCRYPTION.md).
//!   * Batched: `batch_size` records per batch, each batch journaled ahead
//!     (below). Every write is a durable commit (the WAL is fsynced at each
//!     commit; a store in the opt-in deferred WAL mode is refused,
//!     `MigrationNeedsDurableCommits`). The rewritten pages, and the
//!     truncation of the WAL that still holds the old values, reach the
//!     store files at the next checkpoint (the periodic one, or at
//!     shutdown): the procedure runs under the request's graph lock, which a
//!     checkpoint takes, so it does not checkpoint itself.
//!   * Crash-safe: before a batch changes anything, its envelopes are
//!     written to `<data dir>/fle_migration.journal` (fsynced; it holds
//!     envelopes and record ids, no plaintext) and the journal is removed
//!     once the batch's writes have committed. A crash between a value's removal and
//!     its write is repaired from the journal at the next server start
//!     (`recoverAtStartup`) or the next run.
//!   * Resumable: a value already sealed is recognized (authenticated, not
//!     by shape) and skipped, so a run cut short is finished by running it
//!     again, and running it twice changes nothing. The writes are not part
//!     of the statement's undo: a failure part way keeps the batches done.
//!   * Audited: the caller records the outcome (`fle_admin.auditChange`)
//!     with the counts.
//!
//! Not inside an explicit transaction (refused: the batches commit as they
//! go). A non-string value of the field is left (FLE encrypts strings).

const std = @import("std");
const graph_store = @import("../graph_store.zig");
const fle_integration = @import("../fle_integration.zig");
const tenant_visibility = @import("tenant_visibility.zig");
const match_operations = @import("match_operations.zig");
const statement_undo = @import("../statement_undo.zig");
const txn_undo_log = @import("../txn_undo_log.zig");
const logging = @import("logging");
const log = logging.scoped("fle_migration");
const Attr = logging.Attr;

pub const default_batch_size: usize = 1000;
pub const max_batch_size: usize = 100_000;

pub const Options = struct {
    graph: []const u8 = graph_store.DEFAULT_GRAPH_NAME,
    type_name: []const u8,
    field_name: []const u8,
    batch_size: usize = default_batch_size,
    /// The tenant whose records are migrated (null: every tenant the
    /// session sees, for an unscoped session).
    tenant: ?[]const u8 = null,
};

pub const Report = struct {
    /// Records of the type that hold the field.
    scanned: u64 = 0,
    /// Plaintext values written back encrypted.
    encrypted: u64 = 0,
    /// Values already sealed (an earlier run, or written after configureField).
    already_encrypted: u64 = 0,
    /// Values that are not strings.
    non_string: u64 = 0,
    /// Records of other tenants.
    skipped_tenant: u64 = 0,
    /// Nodes the session's row policies hide.
    skipped_rls: u64 = 0,
    batches: u64 = 0,
    /// SONNY-6692: the graph's dead space was overwritten and checkpointed
    /// (always for a persisted store; an in-memory one writes no files).
    scrubbed: bool = false,
    /// Free pages and dead slab bytes the scrub cleared.
    dead_pages_zeroed: u64 = 0,
    dead_bytes_zeroed: u64 = 0,

    /// Every value the session could migrate is sealed, and nothing of
    /// the old values is left in the data directory.
    pub fn complete(self: Report) bool {
        return self.skipped_rls == 0 and self.scrubbed;
    }
};

pub const Error = error{ FieldNotEncrypted, MigrationInTransaction, InvalidBatchSize };

/// SONNY-6688 test-only: stop with `error.MigrationInterrupted` after this
/// many batches (0: never), as a crash between batches would. Production
/// code never sets it.
pub var stop_after_batches_for_testing: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// SONNY-6688 test-only: the next value replaced stops with
/// `error.MigrationInterrupted` after its removal and before its write, as
/// a crash there would (the journal is left for `recoverJournal`).
/// Production code never sets it.
pub var crash_between_remove_and_write_for_testing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

const Kind = enum(u8) { node = 1, edge = 2 };

/// One value of a batch: its record and its envelope (owned).
const Pending = struct {
    kind: Kind,
    id: u64,
    envelope: []u8,
};

pub const journal_file_name = "fle_migration.journal";
const journal_magic = "GFLEMJ1\n";

/// Migrate `opts.field_name` of `opts.type_name` in `store`. The caller is
/// an Admin (the procedure gate).
pub fn migrateField(allocator: std.mem.Allocator, store: *graph_store.GraphStore, opts: Options) !Report {
    if (opts.batch_size == 0 or opts.batch_size > max_batch_size) return error.InvalidBatchSize;
    if (txn_undo_log.threadInTxn()) return error.MigrationInTransaction;
    if (std.mem.eql(u8, opts.graph, graph_store.SECURITY_GRAPH_NAME)) return error.InternalGraph;
    if (!fle_integration.fieldRequiresEncryption(opts.type_name, opts.field_name)) return error.FieldNotEncrypted;
    if (graph_store.getGlobalAdapter()) |adapter| {
        if (adapter.config.sync_mode != .sync_each_commit) return error.MigrationNeedsDurableCommits;
    }

    // The batches are their own unit of undo: a failure keeps what is done.
    statement_undo.suspendCapture();
    defer statement_undo.resumeCapture();

    // A batch a crash cut short is finished first.
    _ = try recoverJournal(allocator, store);

    var report: Report = .{};
    var batch: std.ArrayListUnmanaged(Pending) = .empty;
    defer {
        for (batch.items) |p| allocator.free(p.envelope);
        batch.deinit(allocator);
    }
    // Nodes: the ids copied, the writes below change the store.
    const node_ids = blk: {
        const ids = store.getNodesByLabel(opts.graph, opts.type_name) orelse break :blk try allocator.alloc(u64, 0);
        break :blk try allocator.dupe(u64, ids);
    };
    defer allocator.free(node_ids);
    for (node_ids) |id| {
        try collectRecord(allocator, store, .node, id, opts, &report, &batch);
        if (batch.items.len >= opts.batch_size) try runBatch(allocator, store, opts, &report, &batch);
    }
    const edge_ids = try store.getEdgesByType(allocator, opts.type_name, tenant_visibility.storageTenantFilter(opts.tenant), opts.graph);
    defer allocator.free(edge_ids);
    for (edge_ids) |id| {
        try collectRecord(allocator, store, .edge, id, opts, &report, &batch);
        if (batch.items.len >= opts.batch_size) try runBatch(allocator, store, opts, &report, &batch);
    }
    if (batch.items.len > 0) try runBatch(allocator, store, opts, &report, &batch);
    // SONNY-6692: the old values out of the store files and the WAL.
    if (graph_store.getGlobalAdapter()) |adapter| {
        const scrub = try adapter.scrubGraphDeadSpace(opts.graph);
        report.dead_pages_zeroed = scrub.free_pages_zeroed + scrub.orphan_pages_freed;
        report.dead_bytes_zeroed = scrub.slab_bytes_zeroed + scrub.var_slab_bytes_zeroed;
    }
    report.scrubbed = true;
    log.info("FLE migrate-encrypt finished", &.{
        Attr.string("graph", opts.graph),
        Attr.string("type", opts.type_name),
        Attr.string("field", opts.field_name),
        Attr.uint("encrypted", report.encrypted),
        Attr.uint("already_encrypted", report.already_encrypted),
        Attr.uint("skipped_rls", report.skipped_rls),
        Attr.uint("batches", report.batches),
    });
    return report;
}

/// Write the batch's envelopes ahead, scrub and replace each value, then
/// checkpoint and drop the journal.
fn runBatch(allocator: std.mem.Allocator, store: *graph_store.GraphStore, opts: Options, report: *Report, batch: *std.ArrayListUnmanaged(Pending)) !void {
    defer {
        for (batch.items) |p| allocator.free(p.envelope);
        batch.clearRetainingCapacity();
    }
    const data_dir: ?[]const u8 = if (graph_store.getGlobalAdapter()) |a| a.data_dir else null;
    if (data_dir) |dir| try writeJournal(allocator, dir, opts.field_name, batch.items);
    for (batch.items) |p| {
        try replaceValue(store, p.kind, p.id, opts.field_name, p.envelope);
        report.encrypted += 1;
    }
    // Each write committed (fsynced): the journal is no longer needed.
    if (data_dir) |dir| try removeJournal(allocator, dir);
    report.batches += 1;
    const stop = stop_after_batches_for_testing.load(.acquire);
    if (stop != 0 and report.batches >= stop) return error.MigrationInterrupted;
}

/// Remove the value (the record's property blob is rewritten in place,
/// shrunk, so the old bytes are overwritten or zeroed) and write the
/// envelope (kept as it is: the store's write primitive authenticates it).
fn replaceValue(store: *graph_store.GraphStore, kind: Kind, id: u64, field: []const u8, envelope: []const u8) !void {
    switch (kind) {
        .node => store.removeNodeProperty(id, field),
        .edge => store.removeEdgeProperty(id, field),
    }
    if (crash_between_remove_and_write_for_testing.swap(false, .acq_rel)) return error.MigrationInterrupted;
    switch (kind) {
        .node => try store.setNodeProperty(id, field, .{ .String = envelope }),
        .edge => try store.setEdgeProperty(id, field, .{ .String = envelope }),
    }
}

fn collectRecord(allocator: std.mem.Allocator, store: *graph_store.GraphStore, kind: Kind, id: u64, opts: Options, report: *Report, batch: *std.ArrayListUnmanaged(Pending)) !void {
    // What the record is, copied before any write changes it.
    var tenant_buf: [256]u8 = undefined;
    var tenant: []const u8 = undefined;
    var stored: []u8 = undefined;
    switch (kind) {
        .node => {
            const node = (try store.getNodePtrHydratedChecked(id)) orelse return;
            if (node.labels.len == 0 or !std.mem.eql(u8, node.labels[0], opts.type_name)) return;
            const value = node.properties.get(opts.field_name) orelse return;
            report.scanned += 1;
            if (!tenant_visibility.passesTenantFilter(node.*, opts.tenant)) {
                report.skipped_tenant += 1;
                return;
            }
            if (!match_operations.nodeVisibleUnderSessionRls(allocator, node.*)) {
                report.skipped_rls += 1;
                return;
            }
            if (value != .String) {
                report.non_string += 1;
                return;
            }
            tenant = try copyInto(&tenant_buf, node.tenant_id);
            stored = try allocator.dupe(u8, value.String);
        },
        .edge => {
            const edge = (try store.getEdgePtrHydratedChecked(id)) orelse return;
            if (!std.mem.eql(u8, edge.label, opts.type_name)) return;
            const value = edge.properties.get(opts.field_name) orelse return;
            report.scanned += 1;
            if (!tenant_visibility.passesTenantFilterEdge(edge.*, opts.tenant)) {
                report.skipped_tenant += 1;
                return;
            }
            if (value != .String) {
                report.non_string += 1;
                return;
            }
            tenant = try copyInto(&tenant_buf, edge.tenant_id);
            stored = try allocator.dupe(u8, value.String);
        },
    }
    defer {
        std.crypto.secureZero(u8, stored);
        allocator.free(stored);
    }
    const entity: fle_integration.EntityKind = if (kind == .node) .node else .edge;
    if (try fle_integration.storedStringIsEnvelope(allocator, entity, opts.type_name, opts.field_name, stored, id, tenant)) {
        report.already_encrypted += 1;
        return;
    }
    const sealed = try fle_integration.encryptStoredString(allocator, entity, opts.type_name, opts.field_name, stored, id, tenant);
    // Not encrypted (the field is no longer configured): leave it.
    if (sealed.ptr == stored.ptr) return;
    errdefer allocator.free(sealed);
    try batch.append(allocator, .{ .kind = kind, .id = id, .envelope = @constCast(sealed) });
}

fn copyInto(buf: []u8, s: []const u8) ![]const u8 {
    if (s.len > buf.len) return error.TenantIdTooLong;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

// ---------------------------------------------------------------------------
// The journal
// ---------------------------------------------------------------------------

fn journalPath(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ dir, journal_file_name });
}

/// `magic | field_len u16 | field | count u32 | (kind u8 | id u64 |
/// len u32 | envelope)* | crc32 u32`, written to a temporary file, fsynced,
/// renamed into place and the directory fsynced.
fn writeJournal(allocator: std.mem.Allocator, dir: []const u8, field: []const u8, items: []const Pending) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var w8: [8]u8 = undefined;
    try buf.appendSlice(allocator, journal_magic);
    std.mem.writeInt(u16, w8[0..2], @intCast(field.len), .little);
    try buf.appendSlice(allocator, w8[0..2]);
    try buf.appendSlice(allocator, field);
    std.mem.writeInt(u32, w8[0..4], @intCast(items.len), .little);
    try buf.appendSlice(allocator, w8[0..4]);
    for (items) |p| {
        try buf.append(allocator, @intFromEnum(p.kind));
        std.mem.writeInt(u64, &w8, p.id, .little);
        try buf.appendSlice(allocator, &w8);
        std.mem.writeInt(u32, w8[0..4], @intCast(p.envelope.len), .little);
        try buf.appendSlice(allocator, w8[0..4]);
        try buf.appendSlice(allocator, p.envelope);
    }
    std.mem.writeInt(u32, w8[0..4], std.hash.Crc32.hash(buf.items), .little);
    try buf.appendSlice(allocator, w8[0..4]);

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try journalPath(allocator, dir);
    defer allocator.free(path);
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp);
    {
        const f = try std.Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer f.close(io);
        try f.writeStreamingAll(io, buf.items);
        try f.sync(io);
    }
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io);
    try syncDir(dir);
}

fn removeJournal(allocator: std.mem.Allocator, dir: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try journalPath(allocator, dir);
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try syncDir(dir);
}

fn syncDir(dir_path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    try (std.Io.File{ .handle = dir.handle, .flags = .{ .nonblocking = false } }).sync(io);
}

/// Finish the batch a crash cut short: every journaled record whose field
/// is missing (removed, not yet rewritten) or not its envelope gets the
/// envelope; then the journal goes. Returns the values rewritten. No
/// journal (or no persisted store): nothing to do. A journal that does not
/// parse is an error (the start is refused rather than a value lost).
pub fn recoverJournal(allocator: std.mem.Allocator, store: *graph_store.GraphStore) !usize {
    const adapter = graph_store.getGlobalAdapter() orelse return 0;
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try journalPath(allocator, adapter.data_dir);
    defer allocator.free(path);
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 34)) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer allocator.free(raw);
    if (raw.len < journal_magic.len + 2 + 4 + 4 or !std.mem.eql(u8, raw[0..journal_magic.len], journal_magic)) return error.CorruptFleMigrationJournal;
    if (std.mem.readInt(u32, raw[raw.len - 4 ..][0..4], .little) != std.hash.Crc32.hash(raw[0 .. raw.len - 4])) return error.CorruptFleMigrationJournal;
    const body = raw[0 .. raw.len - 4];
    var pos: usize = journal_magic.len;
    const field_len = std.mem.readInt(u16, body[pos..][0..2], .little);
    pos += 2;
    if (body.len - pos < field_len + 4) return error.CorruptFleMigrationJournal;
    const field = body[pos..][0..field_len];
    pos += field_len;
    const count = std.mem.readInt(u32, body[pos..][0..4], .little);
    pos += 4;

    statement_undo.suspendCapture();
    defer statement_undo.resumeCapture();
    var rewritten: usize = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (body.len - pos < 13) return error.CorruptFleMigrationJournal;
        const kind = std.enums.fromInt(Kind, body[pos]) orelse return error.CorruptFleMigrationJournal;
        const id = std.mem.readInt(u64, body[pos + 1 ..][0..8], .little);
        const len = std.mem.readInt(u32, body[pos + 9 ..][0..4], .little);
        pos += 13;
        if (body.len - pos < len) return error.CorruptFleMigrationJournal;
        const envelope = body[pos..][0..len];
        pos += len;
        const current: ?graph_store.PropertyValue = switch (kind) {
            .node => try store.getNodePropertyOrError(id, field),
            .edge => if (try store.getEdgePtrHydratedChecked(id)) |e| e.properties.get(field) else continue,
        };
        // Recovery runs before any write after the crash (at server start,
        // or first in the next run), so the field is the envelope (done),
        // missing (removed, not rewritten) or the old value (not reached).
        if (current) |v| {
            if (v == .String and std.mem.eql(u8, v.String, envelope)) continue;
        }
        if (current == null) {
            switch (kind) {
                .node => try store.setNodeProperty(id, field, .{ .String = envelope }),
                .edge => try store.setEdgeProperty(id, field, .{ .String = envelope }),
            }
        } else {
            try replaceValue(store, kind, id, field, envelope);
        }
        rewritten += 1;
    }
    // Each write committed (fsynced; checkpointing here could wait on the
    // request's own graph lock).
    try removeJournal(allocator, adapter.data_dir);
    if (rewritten > 0) log.info("FLE migrate-encrypt: finished a batch a crash cut short", &.{Attr.uint("values", rewritten)});
    return rewritten;
}

/// At server start, after the store opened: `recoverJournal`.
pub fn recoverAtStartup(allocator: std.mem.Allocator, store: *graph_store.GraphStore) !void {
    _ = try recoverJournal(allocator, store);
}
