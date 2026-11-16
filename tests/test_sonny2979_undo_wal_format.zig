// SONNY-2979: the durable transaction undo log's format and file
// (`src/txn_durable_undo.zig`, `txn_undo.wal`): every undo entry kind
// round-trips through a record, plain and sealed under an at-rest key (a
// sealed record holds no plaintext value); a torn last record ends the log
// at every cut and a corrupt one by its CRC; recovery's losers are the
// transactions with no COMMITTED or ROLLED_BACK record, newest entry first,
// told apart per boot; a sealed log needs its key and a key refuses a
// plaintext log; and the file keeps an open transaction's records and is
// emptied once none is open. Real files, no mocks.

const std = @import("std");
const geode = @import("geode");
const du = geode.txn_durable_undo;
const txn_undo_log = geode.txn_undo_log;
const UndoEntry = txn_undo_log.UndoEntry;
const SerializedProperty = txn_undo_log.SerializedProperty;
const RecordKind = du.RecordKind;
const encodeEntry = du.encodeEntry;
const appendRecord = du.appendRecord;
const parse = du.parse;
const losersNewestFirst = du.losersNewestFirst;
const Log = du.Log;

fn sampleEntries(allocator: std.mem.Allocator) ![3]UndoEntry {
    const labels = try allocator.alloc([]const u8, 2);
    labels[0] = try allocator.dupe(u8, "A");
    labels[1] = try allocator.dupe(u8, "B");
    const props = try allocator.alloc(SerializedProperty, 2);
    props[0] = try SerializedProperty.fromPropertyValue(allocator, "s", .{ .String = "secret" });
    props[1] = try SerializedProperty.fromPropertyValue(allocator, "f", .{ .Float = 1.5 });
    return .{
        .{ .CreateNode = .{ .node_id = 42, .graph_name = try allocator.dupe(u8, "g") } },
        .{ .SetNodeProperty = .{ .node_id = 7, .key = try allocator.dupe(u8, "p"), .had_old_value = true, .old_value = try SerializedProperty.fromPropertyValue(allocator, "p", .{ .Int = -3 }) } },
        .{ .DeleteNode = .{ .node_id = 9, .labels = labels, .properties = props, .graph_name = try allocator.dupe(u8, "g"), .tenant_id = try allocator.dupe(u8, "t1") } },
    };
}

test "SONNY-2979: undo entries round-trip through the record codec, plain and sealed" {
    const a = std.testing.allocator;
    const entries = try sampleEntries(a);
    defer for (entries) |e| txn_undo_log.freeEntryWith(a, e);
    var key: [32]u8 = undefined;
    @memset(&key, 0x29);
    var cipher = du.cipherForKey(key).?;
    defer cipher.deinit();
    for ([_]?*const du.Cipher{ null, &cipher }) |c| {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(a);
        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(a);
        for (entries) |e| {
            payload.clearRetainingCapacity();
            try encodeEntry(a, &payload, e);
            try appendRecord(a, &out, c, .entry, 5, 11, payload.items);
        }
        try appendRecord(a, &out, c, .committed, 5, 12, &.{});
        // Sealed records hold no plaintext value.
        try std.testing.expectEqual(c == null, std.mem.indexOf(u8, out.items, "secret") != null);
        var p = try parse(a, c, out.items);
        defer p.deinit(a);
        try std.testing.expectEqual(@as(usize, 4), p.records.items.len);
        try std.testing.expectEqual(out.items.len, p.valid_len);
        try std.testing.expectEqual(@as(u64, 42), p.records.items[0].entry.?.CreateNode.node_id);
        try std.testing.expectEqual(@as(i64, -3), p.records.items[1].entry.?.SetNodeProperty.old_value.int_value);
        const d = p.records.items[2].entry.?.DeleteNode;
        try std.testing.expectEqualStrings("B", d.labels[1]);
        try std.testing.expectEqualStrings("secret", d.properties[0].string_value.?);
        try std.testing.expectEqual(@as(f64, 1.5), d.properties[1].float_value);
        try std.testing.expectEqualStrings("t1", d.tenant_id);
        try std.testing.expectEqual(RecordKind.committed, p.records.items[3].kind);
    }
}

test "SONNY-2979: a torn last record ends the log; every shorter prefix parses" {
    const a = std.testing.allocator;
    const entries = try sampleEntries(a);
    defer for (entries) |e| txn_undo_log.freeEntryWith(a, e);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(a);
    var ends: [3]usize = undefined;
    for (entries, 0..) |e, i| {
        payload.clearRetainingCapacity();
        try encodeEntry(a, &payload, e);
        try appendRecord(a, &out, null, .entry, 1, 1, payload.items);
        ends[i] = out.items.len;
    }
    var cut: usize = 0;
    while (cut <= out.items.len) : (cut += 1) {
        var p = try parse(a, null, out.items[0..cut]);
        defer p.deinit(a);
        var want: usize = 0;
        for (ends) |e| {
            if (e <= cut) want += 1;
        }
        try std.testing.expectEqual(want, p.records.items.len);
    }
    // A flipped byte in the last record is a torn tail too (CRC).
    out.items[out.items.len - 1] ^= 0xFF;
    var p = try parse(a, null, out.items);
    defer p.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), p.records.items.len);
}

test "SONNY-2979: losers are the transactions with neither COMMITTED nor ROLLED_BACK, newest entry first, per boot" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(a);
    const Step = struct { kind: RecordKind, boot: u64, txn: u64, id: u64 };
    const steps = [_]Step{
        .{ .kind = .entry, .boot = 1, .txn = 1, .id = 10 }, // 0: loser (boot 1 txn 1 never ends)
        .{ .kind = .entry, .boot = 1, .txn = 2, .id = 20 }, // 1: committed
        .{ .kind = .entry, .boot = 2, .txn = 1, .id = 30 }, // 2: same txn id, other boot: rolled back
        .{ .kind = .entry, .boot = 1, .txn = 1, .id = 11 }, // 3: loser
        .{ .kind = .committed, .boot = 1, .txn = 2, .id = 0 },
        .{ .kind = .rolled_back, .boot = 2, .txn = 1, .id = 0 },
        .{ .kind = .entry, .boot = 1, .txn = 3, .id = 40 }, // 6: loser
    };
    for (steps) |s| {
        payload.clearRetainingCapacity();
        if (s.kind == .entry) try encodeEntry(a, &payload, .{ .CreateNode = .{ .node_id = s.id, .graph_name = "" } });
        try appendRecord(a, &out, null, s.kind, s.boot, s.txn, payload.items);
    }
    var p = try parse(a, null, out.items);
    defer p.deinit(a);
    const order = try losersNewestFirst(a, &p);
    defer a.free(order);
    try std.testing.expectEqualSlices(usize, &.{ 6, 3, 0 }, order);
}

test "SONNY-2979: a sealed log needs its key, and a key refuses a plaintext log" {
    const a = std.testing.allocator;
    var key: [32]u8 = undefined;
    @memset(&key, 0x79);
    var cipher = du.cipherForKey(key).?;
    defer cipher.deinit();
    var other_key = key;
    other_key[0] ^= 1;
    var other = du.cipherForKey(other_key).?;
    defer other.deinit();
    var sealed: std.ArrayListUnmanaged(u8) = .empty;
    defer sealed.deinit(a);
    try appendRecord(a, &sealed, &cipher, .committed, 1, 1, &.{});
    var plain: std.ArrayListUnmanaged(u8) = .empty;
    defer plain.deinit(a);
    try appendRecord(a, &plain, null, .committed, 1, 1, &.{});
    try std.testing.expectError(error.TxnUndoLogEncrypted, parse(a, null, sealed.items));
    try std.testing.expectError(error.TxnUndoLogNotSealed, parse(a, &cipher, plain.items));
    try std.testing.expectError(error.SideFileAuthFailed, parse(a, &other, sealed.items));
}

test "SONNY-2979: the log file: entries, then an end record, empties it once no transaction is open" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(dir);
    const l = try Log.open(a, dir, null);
    defer l.close();
    try l.logEntries(1, &.{.{ .CreateNode = .{ .node_id = 1, .graph_name = "" } }});
    try l.logEntries(2, &.{.{ .CreateNode = .{ .node_id = 2, .graph_name = "" } }});
    try l.markEnded(1, .committed);
    // Transaction 2 is open: nothing is dropped.
    const raw = try l.readAll();
    defer a.free(raw);
    var p = try parse(a, null, raw);
    defer p.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), p.records.items.len);
    const order = try losersNewestFirst(a, &p);
    defer a.free(order);
    try std.testing.expectEqualSlices(usize, &.{1}, order);
    try l.markEnded(2, .rolled_back);
    try std.testing.expectEqual(@as(u64, 0), try l.file.length(io));
    // A transaction that logged nothing needs no record.
    try l.markEnded(3, .committed);
    try std.testing.expectEqual(@as(u64, 0), try l.file.length(io));
}
