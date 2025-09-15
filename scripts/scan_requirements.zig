const std = @import("std");

pub const ReqScanResult = struct {
    ids: std.ArrayListUnmanaged([]const u8),
    duplicates: std.ArrayListUnmanaged([]const u8),
    gaps: []u16,
    has_issues: bool,
};

pub const ReqScanner = struct {
    allocator: std.mem.Allocator,
    unique: std.StringHashMap(void),
    freq: std.StringHashMap(u32),
    ordered: std.ArrayListUnmanaged([]const u8) = .{},
    dups: std.ArrayListUnmanaged([]const u8) = .{},
    presence: [1000]bool = [_]bool{false} ** 1000,
    min_seen: ?u16 = null,
    max_seen: ?u16 = null,

    pub fn init(allocator: std.mem.Allocator) ReqScanner {
        return .{
            .allocator = allocator,
            .unique = std.StringHashMap(void).init(allocator),
            .freq = std.StringHashMap(u32).init(allocator),
        };
    }

    pub fn deinit(self: *ReqScanner) void {
        for (self.ordered.items) |s| self.allocator.free(s);
        for (self.dups.items) |s| self.allocator.free(s);
        self.unique.deinit();
        self.freq.deinit();
        self.ordered.deinit(self.allocator);
        self.dups.deinit(self.allocator);
    }

    pub fn scanPaths(self: *ReqScanner, paths: []const []const u8) !void {
        for (paths) |p| try self.walkRecursive(p);
        std.sort.block([]const u8, self.ordered.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
    }

    fn walkRecursive(self: *ReqScanner, path: []const u8) !void {
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (true) {
            const next = it.next() catch break;
            if (next == null) break;
            const ent = next.?;
            if (ent.kind == .directory) {
                const sub = try std.fs.path.join(self.allocator, &.{ path, ent.name });
                defer self.allocator.free(sub);
                try self.walkRecursive(sub);
            } else if (ent.kind == .file) {
                if (!std.mem.endsWith(u8, ent.name, ".md") and !std.mem.endsWith(u8, ent.name, ".zig")) continue;
                const full = try std.fs.path.join(self.allocator, &.{ path, ent.name });
                const data = std.fs.cwd().readFileAlloc(self.allocator, full, 1 << 20) catch {
                    self.allocator.free(full);
                    continue;
                };
                self.scanBuffer(data);
                self.allocator.free(data);
                self.allocator.free(full);
            }
        }
    }

    fn scanBuffer(self: *ReqScanner, hay: []const u8) void {
        const needle = "REQ-GQL-";
        var idx: usize = 0;
        while (idx < hay.len) {
            const found = std.mem.indexOfPos(u8, hay, idx, needle) orelse break;
            if (found + needle.len + 3 > hay.len) break;
            const digits = hay[found + needle.len .. found + needle.len + 3];
            if (std.ascii.isDigit(digits[0]) and std.ascii.isDigit(digits[1]) and std.ascii.isDigit(digits[2])) {
                var id_buf: [11]u8 = undefined; // REQ-GQL- + 3 digits
                std.mem.copyForwards(u8, id_buf[0..needle.len], needle);
                std.mem.copyForwards(u8, id_buf[needle.len .. needle.len + 3], digits);
                const slice = self.allocator.dupe(u8, id_buf[0 .. needle.len + 3]) catch return;
                self.record(slice) catch return;
            }
            idx = found + needle.len;
        }
    }

    fn record(self: *ReqScanner, id: []const u8) !void {
        if (self.unique.contains(id)) {
            try self.dups.append(self.allocator, self.allocator.dupe(u8, id) catch return);
            const gop = try self.freq.getOrPut(id);
            if (!gop.found_existing) {
                gop.value_ptr.* = 2; // original + this duplicate
            } else {
                gop.value_ptr.* += 1;
            }
            // free the passed-in id slice since we already have originals + duplicates stored
            self.allocator.free(id);
        } else {
            try self.unique.put(id, {});
            try self.ordered.append(self.allocator, id);
            const gop = try self.freq.getOrPut(id);
            if (!gop.found_existing) gop.value_ptr.* = 1;
            const num = try std.fmt.parseInt(u16, id[id.len - 3 ..], 10);
            self.presence[num] = true;
            if (self.min_seen == null or num < self.min_seen.?) self.min_seen = num;
            if (self.max_seen == null or num > self.max_seen.?) self.max_seen = num;
        }
    }

    pub fn finalize(self: *ReqScanner, allocator: std.mem.Allocator) !ReqScanResult {
        var gaps_buf = try allocator.alloc(u16, 0);
        if (self.min_seen) |minv| {
            if (self.max_seen) |maxv| {
                var i = minv;
                while (i <= maxv) : (i += 1) {
                    if (!self.presence[i]) {
                        const new_len = gaps_buf.len + 1;
                        gaps_buf = try allocator.realloc(gaps_buf, new_len);
                        gaps_buf[new_len - 1] = i;
                    }
                }
            }
        }
        return ReqScanResult{ .ids = self.ordered, .duplicates = self.dups, .gaps = gaps_buf, .has_issues = (self.dups.items.len > 0) or (gaps_buf.len > 0) };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var scanner = ReqScanner.init(alloc);
    defer scanner.deinit();
    try scanner.scanPaths(&.{ "docs", "src" });
    const res = try scanner.finalize(alloc);
    defer alloc.free(res.gaps);
    var stdout = std.io.getStdOut().writer();
    try stdout.print("total={d} dups={d} gaps={d}\n", .{ res.ids.items.len, res.duplicates.items.len, res.gaps.len });
}
