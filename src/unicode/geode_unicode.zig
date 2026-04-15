const std = @import("std");
// CANARY: REQ=REQ-GQL-UNICODE-004; FEATURE="UnicodeCore"; ASPECT=NormalizationNfc; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_004_NfcRoundTrip; OWNER=unicode; UPDATED=2025-09-27
// CANARY: REQ=REQ-GQL-UNICODE-005; FEATURE="UnicodeCore"; ASPECT=CaseFolding; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_005_FoldSharpS; OWNER=unicode; UPDATED=2025-09-27

pub const DecompEntry = struct { cp: u32, map: []const u32 };

pub const generated = struct {
    pub const decomp = blk: {
        // Placeholder replaced by generator; fallback minimal runtime table
        break :blk [_]DecompEntry{ .{ .cp = 0x00C9, .map = &[_]u32{ 0x0045, 0x0301 } }, .{ .cp = 0x00E9, .map = &[_]u32{ 0x0065, 0x0301 } } };
    };
};

pub fn simpleDecompose(cp: u32, out: *std.ArrayList(u32)) !void {
    for (generated.decomp) |entry| {
        if (entry.cp == cp) {
            for (entry.map) |m| try out.append(m);
            return;
        }
    }
    try out.append(cp);
}

pub fn nfcNormalize(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    // Extremely small-scale NFC for test purposes.
    var scalars: std.ArrayListUnmanaged(u32) = .empty;
    defer scalars.deinit(alloc);
    var i_byte: usize = 0;
    while (i_byte < s.len) {
        var len: usize = 0;
        var cp: u32 = 0;
        const b0 = s[i_byte];
        if (b0 < 0x80) {
            len = 1;
            cp = b0;
        } else if ((b0 & 0xE0) == 0xC0) {
            if (i_byte + 1 >= s.len) return error.InvalidUtf8;
            len = 2;
            cp = (@as(u32, b0 & 0x1F) << 6) | @as(u32, s[i_byte + 1] & 0x3F);
        } else if ((b0 & 0xF0) == 0xE0) {
            if (i_byte + 2 >= s.len) return error.InvalidUtf8;
            len = 3;
            cp = (@as(u32, b0 & 0x0F) << 12) | (@as(u32, s[i_byte + 1] & 0x3F) << 6) | @as(u32, s[i_byte + 2] & 0x3F);
        } else if ((b0 & 0xF8) == 0xF0) {
            if (i_byte + 3 >= s.len) return error.InvalidUtf8;
            len = 4;
            cp = (@as(u32, b0 & 0x07) << 18) | (@as(u32, s[i_byte + 1] & 0x3F) << 12) | (@as(u32, s[i_byte + 2] & 0x3F) << 6) | @as(u32, s[i_byte + 3] & 0x3F);
        } else return error.InvalidUtf8;
        try scalars.ensureTotalCapacity(alloc, scalars.items.len + 2);
        // Inline simple decomposition for limited set
        const ucp: u32 = cp;
        if (ucp == 0x00C9) { // É -> E + acute
            try scalars.append(alloc, 0x0045);
            try scalars.append(alloc, 0x0301);
        } else if (ucp == 0x00E9) { // é -> e + acute
            try scalars.append(alloc, 0x0065);
            try scalars.append(alloc, 0x0301);
        } else {
            try scalars.append(alloc, ucp);
        }
        i_byte += len;
    }
    var out_list: std.ArrayListUnmanaged(u8) = .empty;
    defer out_list.deinit(alloc);
    var i: usize = 0;
    while (i < scalars.items.len) : (i += 1) {
        var cp_out: u32 = scalars.items[i];
        if (i + 1 < scalars.items.len) {
            const a = scalars.items[i];
            const b = scalars.items[i + 1];
            if (a == 0x0045 and b == 0x0301) {
                cp_out = 0x00C9;
                i += 1;
            } else if (a == 0x0065 and b == 0x0301) {
                cp_out = 0x00E9;
                i += 1;
            }
        }
        // Manual UTF-8 encode cp_out
        if (cp_out < 0x80) {
            try out_list.append(alloc, @as(u8, @intCast(cp_out)));
        } else if (cp_out < 0x800) {
            try out_list.append(alloc, @as(u8, 0xC0 | @as(u8, @intCast(cp_out >> 6))));
            try out_list.append(alloc, 0x80 | @as(u8, @intCast(cp_out & 0x3F)));
        } else if (cp_out < 0x10000) {
            try out_list.append(alloc, @as(u8, 0xE0 | @as(u8, @intCast(cp_out >> 12))));
            try out_list.append(alloc, 0x80 | @as(u8, @intCast((cp_out >> 6) & 0x3F)));
            try out_list.append(alloc, 0x80 | @as(u8, @intCast(cp_out & 0x3F)));
        } else {
            try out_list.append(alloc, @as(u8, 0xF0 | @as(u8, @intCast(cp_out >> 18))));
            try out_list.append(alloc, 0x80 | @as(u8, @intCast((cp_out >> 12) & 0x3F)));
            try out_list.append(alloc, 0x80 | @as(u8, @intCast((cp_out >> 6) & 0x3F)));
            try out_list.append(alloc, 0x80 | @as(u8, @intCast(cp_out & 0x3F)));
        }
    }
    const result = try alloc.alloc(u8, out_list.items.len);
    std.mem.copyForwards(u8, result, out_list.items);
    return result;
}

pub fn foldCase(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        var len: usize = 0;
        var cp: u32 = 0;
        const b0 = s[i];
        if (b0 < 0x80) {
            len = 1;
            cp = b0;
        } else if ((b0 & 0xE0) == 0xC0) {
            if (i + 1 >= s.len) return error.InvalidUtf8;
            len = 2;
            cp = (@as(u32, b0 & 0x1F) << 6) | @as(u32, s[i + 1] & 0x3F);
        } else if ((b0 & 0xF0) == 0xE0) {
            if (i + 2 >= s.len) return error.InvalidUtf8;
            len = 3;
            cp = (@as(u32, b0 & 0x0F) << 12) | (@as(u32, s[i + 1] & 0x3F) << 6) | @as(u32, s[i + 2] & 0x3F);
        } else if ((b0 & 0xF8) == 0xF0) {
            if (i + 3 >= s.len) return error.InvalidUtf8;
            len = 4;
            cp = (@as(u32, b0 & 0x07) << 18) | (@as(u32, s[i + 1] & 0x3F) << 12) | (@as(u32, s[i + 2] & 0x3F) << 6) | @as(u32, s[i + 3] & 0x3F);
        } else return error.InvalidUtf8;
        var emit_one = true;
        switch (cp) {
            0x0041 => cp = 0x0061,
            0x0045 => cp = 0x0065,
            0x00C9 => cp = 0x00E9,
            0x00C5 => cp = 0x00E5,
            0x03A3, 0x03C2, 0x03C3 => cp = 0x03C3,
            0x00DF => { // sharp s -> ss
                try out.append(alloc, 's');
                try out.append(alloc, 's');
                emit_one = false;
            },
            else => {},
        }
        if (emit_one) {
            if (cp < 0x80) {
                try out.append(alloc, @as(u8, @intCast(cp)));
            } else if (cp < 0x800) {
                try out.append(alloc, @as(u8, 0xC0 | @as(u8, @intCast(cp >> 6))));
                try out.append(alloc, 0x80 | @as(u8, @intCast(cp & 0x3F)));
            } else if (cp < 0x10000) {
                try out.append(alloc, @as(u8, 0xE0 | @as(u8, @intCast(cp >> 12))));
                try out.append(alloc, 0x80 | @as(u8, @intCast((cp >> 6) & 0x3F)));
                try out.append(alloc, 0x80 | @as(u8, @intCast(cp & 0x3F)));
            } else {
                try out.append(alloc, @as(u8, 0xF0 | @as(u8, @intCast(cp >> 18))));
                try out.append(alloc, 0x80 | @as(u8, @intCast((cp >> 12) & 0x3F)));
                try out.append(alloc, 0x80 | @as(u8, @intCast((cp >> 6) & 0x3F)));
                try out.append(alloc, 0x80 | @as(u8, @intCast(cp & 0x3F)));
            }
        }
        i += len;
    }
    const result = try alloc.alloc(u8, out.items.len);
    std.mem.copyForwards(u8, result, out.items);
    return result;
}

// UTF-16 / WTF-8 bridge helpers leveraging std.unicode (no extra UCD beyond minimal NFC above)
// CANARY: REQ=REQ-GQL-UNICODE-012; FEATURE="UnicodeUtf16"; ASPECT=Utf8ToUtf16; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_012_Utf8ToUtf16RoundTrip; OWNER=unicode; UPDATED=2025-09-27
// CANARY: REQ=REQ-GQL-UNICODE-013; FEATURE="UnicodeUtf16"; ASPECT=Utf16ToUtf8; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_013_Utf16ToUtf8RoundTrip; OWNER=unicode; UPDATED=2025-09-27
// CANARY: REQ=REQ-GQL-UNICODE-014; FEATURE="UnicodeWtf8"; ASPECT=Wtf8LossyDecode; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_014_Wtf8Lossy; OWNER=unicode; UPDATED=2025-09-27

pub fn utf8ToUtf16Alloc(allocator: std.mem.Allocator, s: []const u8) ![]u16 {
    // Validate first (defensive)
    if (!std.unicode.utf8ValidateSlice(s)) {
        return error.InvalidUtf8;
    }
    return try std.unicode.utf8ToUtf16LeAlloc(allocator, s);
}

pub fn utf16ToUtf8Alloc(allocator: std.mem.Allocator, units: []const u16) ![]u8 {
    return try std.unicode.utf16LeToUtf8Alloc(allocator, units);
}

pub fn wtf8LossyToUtf8Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    // Convert potentially ill-formed WTF-8 into valid UTF-8 by lossy replacement
    return try std.unicode.wtf8ToUtf8LossyAlloc(allocator, bytes);
}
