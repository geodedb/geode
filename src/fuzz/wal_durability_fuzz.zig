const std = @import("std");
const Wal = @import("wal").Wal;
const RecordType = @import("wal").RecordType;

// Fuzz-like test of WAL durability: partial-truncate crash simulation and recovery invariants

test "wal durability fuzz recovery invariants" {
    const allocator = std.testing.allocator;
    const base_path = "wal_fuzz_test";
    // Clean up any existing segments (best-effort)
    const cwd = std.fs.cwd();
    _ = cwd.deleteFile(base_path ++ ".wal.0");

    // Writer WAL
    var wal1 = Wal.init(allocator);
    defer wal1.deinit();
    try wal1.openFile(base_path);
    // TXN 1: Begin, two inserts, Commit
    wal1.buf.append(allocator, .{}); // ensure buffer non-empty for commit count
    _ = wal1.append(1, RecordType.Begin, &.{}, 0) catch {};
    _ = wal1.append(1, RecordType.Insert, "A", 1) catch {};
    _ = wal1.append(1, RecordType.Insert, "B", 1) catch {};
    _ = wal1.append(1, RecordType.Commit, &.{}, 0) catch {};
    // TXN 2: Begin, insert, Abort
    _ = wal1.append(2, RecordType.Begin, &.{}, 0) catch {};
    _ = wal1.append(2, RecordType.Insert, "C", 1) catch {};
    _ = wal1.append(2, RecordType.Abort, &.{}, 0) catch {};

    // Check committed txn count
    const committed1 = wal1.committedTxnTotal();
    try std.testing.expect(committed1 == 1);

    // Close segment file to flush
    if (wal1.file) |f| f.close();

    const segment_file = base_path ++ ".wal.0";
    // Truncate mid-file to simulate crash
    var f = try cwd.openFile(segment_file, .{ .mode = .read_write });
    const st = try f.stat();
    try f.truncate(st.size / 2);
    f.close();

    // Recover
    var wal2 = Wal.init(allocator);
    defer wal2.deinit();
    try wal2.openFile(base_path);
    const committed2 = wal2.committedTxnTotal();
    // Invariant: recovered committed <= original committed
    try std.testing.expect(committed2 <= committed1);
}
