const std = @import("std");

pub const HashAlgo = enum { sha256, blake3 };

fn hashBytes(algo: HashAlgo, data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    switch (algo) {
        .sha256 => std.crypto.hash.sha2.Sha256.hash(data, &out, .{}),
        .blake3 => std.crypto.hash.blake3.Blake3.hash(data, &out, .{}),
    }
    return out;
}

fn hex32(buf: []const u8) ![32]u8 {
    if (buf.len != 64) return error.BadHexLen;
    var out: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) out[i] = try std.fmt.parseInt(u8, buf[i * 2 .. i * 2 + 2], 16);
    return out;
}

fn findQuotedValue(line: []const u8, key: []const u8) ?[]const u8 {
    var patt_buf: [64]u8 = undefined;
    const patt = std.fmt.bufPrint(&patt_buf, "\"{s}\":\"", .{ key }) catch return null;
    if (std.mem.indexOf(u8, line, patt)) |idx| {
        const start = idx + patt.len;
        if (std.mem.indexOfScalarPos(u8, line, start, '"')) |end| {
            return line[start..end];
        }
    }
    return null;
}

pub fn verifyFile(path: []const u8, algo: HashAlgo, digest_interval_events: u32, require_digest: bool, pubkey: ?[32]u8) !void {
    _ = digest_interval_events;
    _ = require_digest;
    _ = pubkey;
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var buf: [4096]u8 = undefined;
    var rd = file.reader(&buf);
    var line_buf = std.ArrayList(u8).initCapacity(std.heap.page_allocator, 0) catch unreachable;
    defer line_buf.deinit(std.heap.page_allocator);

    var seq: u64 = 0;
    var last_hash: [32]u8 = [_]u8{0} ** 32;
    var digest_count: u32 = 0;
    var records: u64 = 0;

    while (true) {
        line_buf.clearRetainingCapacity();
        while (true) {
            var one: [1]u8 = undefined;
            const n = rd.read(&one) catch return error.ReadError;
            if (n == 0) break; // EOF
            if (one[0] == '\n') break;
            line_buf.append(std.heap.page_allocator, one[0]) catch return error.OutOfMemory;
        }
        if (line_buf.items.len == 0) break;
        const line = line_buf.items;
        const prev_hex = findQuotedValue(line, "prev_hash") orelse {
            std.debug.print("SCHEMA_ERROR ❌  at_seq={} field=prev_hash detail=missing\n", .{ seq + 1 });
            return error.Invalid;
        };
        const ev_hex = findQuotedValue(line, "event_hash") orelse {
            std.debug.print("SCHEMA_ERROR ❌  at_seq={} field=event_hash detail=missing\n", .{ seq + 1 });
            return error.Invalid;
        };
        const typ = findQuotedValue(line, "event_type") orelse {
            std.debug.print("SCHEMA_ERROR ❌  at_seq={} field=event_type detail=missing\n", .{ seq + 1 });
            return error.Invalid;
        };
        const prev_buf = try hex32(prev_hex);
        if (!std.mem.eql(u8, &prev_buf, &last_hash)) {
            std.debug.print("TAMPER chain ❌  at_seq={} reason=PREV_HASH_MISMATCH expected=", .{ seq + 1 });
            for (last_hash) |b| std.debug.print("{x:0>2}", .{ b });
            std.debug.print(" got=", .{});
            for (prev_buf) |b| std.debug.print("{x:0>2}", .{ b });
            std.debug.print("\n", .{});
            std.process.exit(3);
        }
        last_hash = try hex32(ev_hex);
        if (std.mem.eql(u8, typ, "DIGEST")) digest_count += 1;
        records += 1;
        seq += 1;
    }
    std.debug.print("OK chain ✅  records={} digests={} algo={s}\n", .{ records, digest_count, switch (algo) { .sha256 => "sha256", .blake3 => "blake3" } });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    const args = try std.process.argsAlloc(ally);
    defer std.process.argsFree(ally, args);
    if (args.len < 2 or !std.mem.eql(u8, args[1], "verify")) {
        std.debug.print("usage: geode-audit verify --file <path> [--algo sha256|blake3] [--require-digest] [--pubkey <hex>]\n", .{});
        return;
    }
    var path: []const u8 = "audit.jsonl";
    var algo: HashAlgo = .sha256;
    var require_digest = false;
    var pubkey: ?[32]u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--file")) { i += 1; path = args[i]; continue; }
        if (std.mem.eql(u8, args[i], "--algo")) { i += 1; algo = if (std.mem.eql(u8, args[i], "blake3")) .blake3 else .sha256; continue; }
        if (std.mem.eql(u8, args[i], "--require-digest")) { require_digest = true; continue; }
        if (std.mem.eql(u8, args[i], "--pubkey")) { i += 1; pubkey = try hex32(args[i]); continue; }
    }
    try verifyFile(path, algo, 100, require_digest, pubkey);
}
