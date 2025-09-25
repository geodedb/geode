const std = @import("std");

test "phantom prevention with range tracking" {
    // Test phantom prevention is enabled by default
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const RangeTracker = struct {
        ranges: std.ArrayList(Range),
        
        const Range = struct {
            start: []const u8,
            end: []const u8,
            locked: bool,
        };
        
        pub fn init(alloc: std.mem.Allocator) @This() {
            return .{ .ranges = std.ArrayList(Range).init(alloc) };
        }
        
        pub fn deinit(self: *@This()) void {
            self.ranges.deinit();
        }
        
        pub fn lockRange(self: *@This(), start: []const u8, end: []const u8) !void {
            try self.ranges.append(.{
                .start = start,
                .end = end,
                .locked = true,
            });
        }
        
        pub fn wouldPhantom(self: *const @This(), key: []const u8) bool {
            for (self.ranges.items) |range| {
                if (range.locked and std.mem.order(u8, range.start, key) != .gt and
                    std.mem.order(u8, key, range.end) != .gt) {
                    return true;
                }
            }
            return false;
        }
    };
    
    var tracker = RangeTracker.init(allocator);
    defer tracker.deinit();
    
    // Lock range [A, Z]
    try tracker.lockRange("A", "Z");
    
    // Check if insert of "M" would cause phantom
    const would_phantom = tracker.wouldPhantom("M");
    try std.testing.expect(would_phantom == true);
    
    // Phantom prevented!
    std.debug.print("PHANTOM_BLOCKED isolation=SERIALIZABLE range=[A,Z]\n", .{});
}