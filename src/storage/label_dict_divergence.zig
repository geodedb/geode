// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! SONNY-6524: opening a graph whose shard label dictionaries disagree.
//!
//! Each of a graph's 16 shards keeps its own `labels.dict`. graph-storage
//! 0.4.15 compares them with shard 0's when it opens the graph: a shard that
//! is only missing names, or names an id none of its records use, is
//! rewritten from shard 0; a shard whose records use an id it names
//! differently from shard 0 makes the open fail with
//! `error.LabelDictionaryDiverged` (nothing is written), unless the caller
//! sets `GraphConfig.label_dict_divergence = .adopt_shard0`.
//!
//! Which id geode wrote. Every label id geode has put in a record (a node's
//! labels, an edge's type, an ordered index) on any shard is shard 0's: the
//! adapter names labels through `mg.label_dict`, a view of shard 0's
//! dictionary (since the move to `ShardedGraphEngine`, 2026-04-25), or
//! through `ShardedGraphEngine.getOrAssignLabel`, which has returned shard
//! 0's id since it was added. geode reads names through shard 0's dictionary
//! only. So shard 0's dictionary is what every record means, as long as shard
//! 0 has not lost a name.
//!
//! The shapes on disk.
//!   * Shift (shard k is shard 0's dictionary with some of shard 0's names
//!     left out, the rest in the same order): geode's old ORDER BY path named
//!     a label in shard 0's dictionary only, so every later name got a lower
//!     id on shards 1..15; before 2026-05-29 every name was given that way;
//!     a broadcast that failed part-way on 0.4.14 left the later shards
//!     without the name. Adopting shard 0's dictionary gives every record the
//!     name it was written with.
//!   * Shard 0 lost a name another shard kept: graph-storage <= 0.4.13 wrote
//!     `labels.dict` only at checkpoint, and `ShardedGraphEngine.checkpoint`
//!     went on to the next shard after one failed, so a shard 0 checkpoint
//!     error followed by a crash (2026-05-29..2026-07-10, before geode wrote
//!     every shard's dictionary on first sight of a name) left shard 0
//!     without a name shards 1..15 kept, and shard 0 later gave its id to
//!     another name. Adopting shard 0 drops the name the other shards kept.
//!     geode detects it when shard k names a label shard 0 does not name, or
//!     names two labels in the opposite order. It cannot be told from a shift
//!     when shard 0 reused the id for a name only shard 0 knows and later
//!     named the lost label again: the dictionaries are then those of a
//!     shift, and so are the records' ids.
//!
//! Because of that last case geode does not adopt by itself: a graph refused
//! with `LabelDictionaryDiverged` stays closed (its reads and writes fail;
//! other graphs are unaffected) and the log says which shape it is. The
//! operator may name the graph in `GEODE_LABEL_DICT_ADOPT_SHARD0` (a comma
//! separated list of graph names) to have a shift adopted from shard 0; the
//! other shapes are refused even then.

const std = @import("std");
const gs = @import("graph_storage");
const structured_logging = @import("logging");

// geode's structured logger: std.log warn/info are compiled out of release
// servers, and so are graph-storage's own warnings about the disagreement.
const slog = structured_logging.scoped("storage");
const SAttr = structured_logging.Attr;

pub const adopt_env = "GEODE_LABEL_DICT_ADOPT_SHARD0";

const SHARD_COUNT = gs.sharded_engine.SHARD_COUNT;

/// A label name copied out of a dictionary (truncated to 64 bytes).
pub const Name = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    fn of(s: []const u8) Name {
        var n: Name = .{ .len = @min(s.len, 64) };
        @memcpy(n.buf[0..n.len], s[0..n.len]);
        return n;
    }

    pub fn slice(n: *const Name) []const u8 {
        return n.buf[0..n.len];
    }
};

pub const Shape = union(enum) {
    /// Every shard's dictionary is shard 0's with some of shard 0's names
    /// left out, the remaining ones in shard 0's id order.
    shift,
    /// Shard `shard` names label id `id` `name`, a name shard 0 does not have.
    missing_on_shard0: struct { shard: usize, id: u32, name: Name },
    /// Shard `shard` gives `first` a lower id than `second`; shard 0 gives it
    /// a higher one.
    order_differs: struct { shard: usize, first: Name, second: Name },
};

const Pair = struct { id_k: u32, id_0: u32, name: []const u8 };

fn byShardId(_: void, a: Pair, b: Pair) bool {
    return a.id_k < b.id_k;
}

/// SONNY-6590: graph-storage 0.4.17 seals `labels.dict` under at-rest
/// encryption (`encryption_key`), bound to the shard's uuid; the plain
/// `loadFromFile` refuses a sealed file. A plaintext file is accepted here
/// only to classify a store the engine itself already opened that far (a
/// store written by <= 0.4.16, upgraded at open): the engine's own read
/// policy refused a plaintext dictionary in a sealed store
/// (`SideFileNotSealed`) before it could report `LabelDictionaryDiverged`,
/// and a repair goes through the engine again.
fn loadShardDict(allocator: std.mem.Allocator, graph_root: []const u8, shard_uuid: [16]u8, encryption_key: ?[32]u8) !gs.label_dict.LabelDictionary {
    const hex = std.fmt.bytesToHex(shard_uuid, .lower);
    const path = try std.fmt.allocPrint(allocator, "{s}/graphs/{s}/labels.dict", .{ graph_root, &hex });
    defer allocator.free(path);
    var cipher = gs.side_file_crypto.Cipher.forKey(encryption_key, shard_uuid);
    defer if (cipher) |*c| c.deinit();
    var dict = gs.label_dict.LabelDictionary.init(allocator);
    errdefer dict.deinit();
    _ = dict.loadFromFileWith(path, .{ .cipher = if (cipher) |*c| c else null, .require_sealed = false }) catch |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };
    return dict;
}

/// Read the graph's 16 `labels.dict` files from disk and say which shape
/// their disagreement has. Reads only. `encryption_key` is the store's
/// at-rest key (`GraphConfig.encryption_key`), null when it has none.
pub fn classify(allocator: std.mem.Allocator, data_dir: []const u8, graph_uuid: [16]u8, encryption_key: ?[32]u8) !Shape {
    const root_hex = std.fmt.bytesToHex(graph_uuid, .lower);
    const graph_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, &root_hex });
    defer allocator.free(graph_root);
    const manifest = try gs.shard_manifest.readFromDir(allocator, graph_root);

    var d0 = try loadShardDict(allocator, graph_root, manifest.per_shard_uuids[0], encryption_key);
    defer d0.deinit();
    var pairs: std.ArrayList(Pair) = .empty;
    defer pairs.deinit(allocator);

    for (1..SHARD_COUNT) |k| {
        var dk = try loadShardDict(allocator, graph_root, manifest.per_shard_uuids[k], encryption_key);
        defer dk.deinit();
        pairs.clearRetainingCapacity();
        var it = dk.name_to_id.iterator();
        while (it.next()) |e| {
            const id_0 = d0.getId(e.key_ptr.*) orelse
                return .{ .missing_on_shard0 = .{ .shard = k, .id = e.value_ptr.*, .name = Name.of(e.key_ptr.*) } };
            try pairs.append(allocator, .{ .id_k = e.value_ptr.*, .id_0 = id_0, .name = e.key_ptr.* });
        }
        std.mem.sort(Pair, pairs.items, {}, byShardId);
        if (pairs.items.len > 1) for (pairs.items[0 .. pairs.items.len - 1], pairs.items[1..]) |a, b| {
            if (a.id_0 >= b.id_0) return .{ .order_differs = .{ .shard = k, .first = Name.of(a.name), .second = Name.of(b.name) } };
        };
    }
    return .shift;
}

// CANARY: REQ=REQ-SONNY-6527-LABEL-DICT-REPORT; FEATURE="CrashRecovery"; ASPECT=StructuredDivergenceDetail; STATUS=TESTED; TEST=tests/test_sonny6524_label_dict_split.zig; OWNER=storage; UPDATED=2026-11-15
/// SONNY-6527: the receiver geode installs as `GraphConfig.label_dict_report`.
/// graph-storage 0.4.16 hands every shard label-dictionary finding of
/// `ShardedGraphEngine.open` and `getOrAssignLabel` to it (kind, action,
/// shard, id, the shard's and shard 0's names, record and name counts) on the
/// calling thread; its own `std.log.warn` of the same detail is compiled out
/// of a release server. A refusal is logged at ERROR, a repair at WARN, both
/// through the structured logger and with the graph's name. Heap-allocated
/// before the graph's engine opens and owned by its `ManagedGraph` (freed
/// after the engine is closed): `getOrAssignLabel` reports through it for
/// the engine's whole life.
pub const ReportCtx = struct {
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,

    pub fn create(allocator: std.mem.Allocator, graph_name: []const u8) !*ReportCtx {
        const self = try allocator.create(ReportCtx);
        self.* = .{ .name_len = @min(graph_name.len, 256) };
        @memcpy(self.name_buf[0..self.name_len], graph_name[0..self.name_len]);
        return self;
    }

    pub fn report(self: *ReportCtx) gs.config.LabelDictReport {
        return .{ .ctx = self, .func = onDiagnostic };
    }

    fn name(self: *const ReportCtx) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

fn onDiagnostic(ctx: ?*anyopaque, d: *const gs.config.LabelDictDiagnostic) void {
    const self: *const ReportCtx = @ptrCast(@alignCast(ctx orelse return));
    const attrs = [_]SAttr{
        SAttr.string("graph", self.name()),
        SAttr.string("kind", @tagName(d.kind)),
        SAttr.string("action", @tagName(d.action)),
        SAttr.uint("shard", d.shard),
        SAttr.uint("label_id", d.label_id),
        SAttr.uint("shard_label_id", d.shard_label_id),
        SAttr.string("label", d.label),
        SAttr.string("shard0_label", d.shard0_label orelse "(none)"),
        SAttr.string("shard_other_label", d.shard_label orelse "(none)"),
        SAttr.uint("nodes", d.nodes),
        SAttr.uint("edges", d.edges),
        SAttr.uint("indexes", d.indexes),
        SAttr.uint("shard_names", d.shard_names),
        SAttr.uint("shard0_names", d.shard0_names),
    };
    switch (d.action) {
        .refused => slog.err("shard label dictionary disagrees with shard 0's; refused (LabelDictionaryDiverged) and nothing was changed (SONNY-6527)", &attrs),
        .renamed_from_shard0, .rewritten, .rewritten_in_memory => slog.warn("shard label dictionary disagreed with shard 0's and was repaired from it (SONNY-6527)", &attrs),
    }
}

/// The operator named `graph_name` in `GEODE_LABEL_DICT_ADOPT_SHARD0`.
pub fn adoptRequested(graph_name: []const u8) bool {
    const raw = std.c.getenv(adopt_env) orelse return false;
    var it = std.mem.tokenizeScalar(u8, std.mem.span(raw), ',');
    while (it.next()) |tok| {
        if (std.mem.eql(u8, std.mem.trim(u8, tok, " \t"), graph_name)) return true;
    }
    return false;
}

// CANARY: REQ=REQ-SONNY-6524-LABEL-DICT-SPLIT; FEATURE="CrashRecovery"; ASPECT=DivergedLabelDictOpen; STATUS=TESTED; TEST=tests/test_sonny6524_label_dict_split.zig; OWNER=storage; UPDATED=2026-11-13
/// `ShardedGraphEngine.open`, and for a graph refused with
/// `LabelDictionaryDiverged`: log which shape it is and what to do, and open
/// (SONNY-6527: graph-storage reports each shard's finding itself, through
/// `cfg.label_dict_report`; the shape below decides the repair, which needs
/// every name of every shard, so the dictionaries are still read here)
/// it adopting shard 0's dictionary only for a shift the operator named in
/// `GEODE_LABEL_DICT_ADOPT_SHARD0`. Otherwise the error is returned.
pub fn openShardedEngine(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    graph_name: []const u8,
    graph_uuid: [16]u8,
    cfg: gs.GraphConfig,
) !*gs.ShardedGraphEngine {
    return gs.ShardedGraphEngine.open(allocator, data_dir, graph_uuid, cfg) catch |err| {
        if (err != error.LabelDictionaryDiverged) return err;
        const shape = classify(allocator, data_dir, graph_uuid, cfg.encryption_key) catch |cerr| {
            slog.err("graph not opened: its shard label dictionaries disagree (LabelDictionaryDiverged) and reading them failed; its reads and writes fail, other graphs are unaffected (SONNY-6524)", &.{
                SAttr.string("graph", graph_name),
                SAttr.err("read_error", cerr),
            });
            return err;
        };
        switch (shape) {
            .shift => {
                if (adoptRequested(graph_name)) {
                    slog.warn("graph's shards 1..15 disagree with shard 0's label dictionary in the shape geode's old ORDER BY path left; rewriting them from shard 0, as GEODE_LABEL_DICT_ADOPT_SHARD0 asks (SONNY-6524)", &.{
                        SAttr.string("graph", graph_name),
                    });
                    var adopt_cfg = cfg;
                    adopt_cfg.label_dict_divergence = .adopt_shard0;
                    return gs.ShardedGraphEngine.open(allocator, data_dir, graph_uuid, adopt_cfg);
                }
                slog.err("graph not opened: its shard label dictionaries disagree (LabelDictionaryDiverged). Shard 0 names every label the other shards name, in the same order: the shape geode's old ORDER BY path left, in which shard 0's names are the ones the records were written with and the ones geode served. Its reads and writes fail; other graphs are unaffected. Unless this store ran graph-storage 0.4.13 or older and a checkpoint of shard 0 failed before a crash, add the graph to GEODE_LABEL_DICT_ADOPT_SHARD0 and restart: shards 1..15 are rewritten from shard 0 (SONNY-6524)", &.{
                    SAttr.string("graph", graph_name),
                });
            },
            .missing_on_shard0 => |m| slog.err("graph not opened: its shard label dictionaries disagree (LabelDictionaryDiverged). A shard names a label shard 0 does not have: shard 0 lost names that records use, and rewriting the other shards from shard 0 would drop them, so geode will not (GEODE_LABEL_DICT_ADOPT_SHARD0 is ignored for this graph). Its reads and writes fail; other graphs are unaffected. It needs a manual repair: restore it from a backup whose shard dictionaries agree, or rebuild shard 0's dictionary from the other shards' (SONNY-6524)", &.{
                SAttr.string("graph", graph_name),
                SAttr.uint("shard", m.shard),
                SAttr.uint("label_id", m.id),
                SAttr.string("label", m.name.slice()),
            }),
            .order_differs => |o| slog.err("graph not opened: its shard label dictionaries disagree (LabelDictionaryDiverged). A shard orders two labels' ids the other way round from shard 0: shard 0 lost a name and gave its id to another label, and rewriting the other shards from shard 0 would rename records, so geode will not (GEODE_LABEL_DICT_ADOPT_SHARD0 is ignored for this graph). Its reads and writes fail; other graphs are unaffected. It needs a manual repair: restore it from a backup whose shard dictionaries agree (SONNY-6524)", &.{
                SAttr.string("graph", graph_name),
                SAttr.uint("shard", o.shard),
                SAttr.string("first", o.first.slice()),
                SAttr.string("second", o.second.slice()),
            }),
        }
        return err;
    };
}
