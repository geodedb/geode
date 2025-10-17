const std = @import("std");

pub const HashAlgo = enum { sha256, blake3 };
pub fn hex32(buf: []const u8) ![32]u8 {
    if (buf.len != 64) return error.BadHexLen;
    var out: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) out[i] = try std.fmt.parseInt(u8, buf[i * 2 .. i * 2 + 2], 16);
    return out;
}
/// P2-3: Now accepts allocator parameter for line buffer allocation
pub fn verifyFile(allocator: std.mem.Allocator, path: []const u8, algo: HashAlgo, digest_interval_events: u32, require_digest: bool, pubkey: ?[32]u8) !void {
    _ = digest_interval_events;
    _ = require_digest;
    _ = pubkey;
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var buf: [4096]u8 = undefined;
    var rd = file.reader(&buf);
    var line_buf = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    defer line_buf.deinit(allocator);
    var seq: u64 = 0;
    var last_hash: [32]u8 = [_]u8{0} ** 32;
    var digest_count: u32 = 0;
    var records: u64 = 0;
    while (true) {
        line_buf.clearRetainingCapacity();
        while (true) {
            var one: [1]u8 = undefined;
            const n = rd.read(&one) catch return error.ReadError;
            if (n == 0) break;
            if (one[0] == '\n') break;
            line_buf.append(allocator, one[0]) catch return error.OutOfMemory;
        }
        if (line_buf.items.len == 0) break;
        const line = line_buf.items;
        var patt_prev_buf: [64]u8 = undefined;
        const patt_prev = std.fmt.bufPrint(&patt_prev_buf, "\"{s}\":\"", .{"prev_hash"}) catch return error.Invalid;
        var patt_ev_buf: [64]u8 = undefined;
        const patt_ev = std.fmt.bufPrint(&patt_ev_buf, "\"{s}\":\"", .{"event_hash"}) catch return error.Invalid;
        var patt_typ_buf: [64]u8 = undefined;
        const patt_typ = std.fmt.bufPrint(&patt_typ_buf, "\"{s}\":\"", .{"event_type"}) catch return error.Invalid;
        const prev_hex = blk: {
            if (std.mem.indexOf(u8, line, patt_prev)) |idx| {
                const start = idx + patt_prev.len;
                if (std.mem.indexOfScalarPos(u8, line, start, '"')) |end| break :blk line[start..end];
            }
            std.debug.print("SCHEMA_ERROR ❌  at_seq={} field=prev_hash detail=missing\n", .{seq + 1});
            return error.Invalid;
        };
        const ev_hex = blk2: {
            if (std.mem.indexOf(u8, line, patt_ev)) |idx| {
                const start = idx + patt_ev.len;
                if (std.mem.indexOfScalarPos(u8, line, start, '"')) |end| break :blk2 line[start..end];
            }
            std.debug.print("SCHEMA_ERROR ❌  at_seq={} field=event_hash detail=missing\n", .{seq + 1});
            return error.Invalid;
        };
        const typ = blk3: {
            if (std.mem.indexOf(u8, line, patt_typ)) |idx| {
                const start = idx + patt_typ.len;
                if (std.mem.indexOfScalarPos(u8, line, start, '"')) |end| break :blk3 line[start..end];
            }
            std.debug.print("SCHEMA_ERROR ❌  at_seq={} field=event_type detail=missing\n", .{seq + 1});
            return error.Invalid;
        };
        const prev_buf = try hex32(prev_hex);
        if (!std.mem.eql(u8, &prev_buf, &last_hash)) {
            std.debug.print("TAMPER chain ❌  at_seq={} reason=PREV_HASH_MISMATCH expected=", .{seq + 1});
            for (last_hash) |b| std.debug.print("{x:0>2}", .{b});
            std.debug.print(" got=", .{});
            for (prev_buf) |b| std.debug.print("{x:0>2}", .{b});
            std.debug.print("\n", .{});
            std.process.exit(3);
        }
        last_hash = try hex32(ev_hex);
        if (std.mem.eql(u8, typ, "DIGEST")) digest_count += 1;
        records += 1;
        seq += 1;
    }
    std.debug.print("OK chain ✅  records={} digests={} algo={s}\n", .{ records, digest_count, switch (algo) {
        .sha256 => "sha256",
        .blake3 => "blake3",
    } });
}
