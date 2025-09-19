const std = @import("std");

// Minimal client for cross-compilation testing
pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 7567,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: Config) Self {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn connect(self: *Self) !void {
        _ = self;
        // Minimal implementation for testing
    }

    pub fn disconnect(self: *Self) void {
        _ = self;
    }

    pub fn execute(self: *Self, query: []const u8) !Result {
        _ = self;
        _ = query;
        return Result{
            .schema = Schema{
                .columns = &[_]Column{
                    Column{ .name = "x", .type_name = "INT" },
                },
            },
        };
    }
};

pub const Schema = struct {
    columns: []const Column,
};

pub const Column = struct {
    name: []const u8,
    type_name: []const u8,
};

pub const Result = struct {
    schema: Schema,

    pub fn deinit(self: *Result) void {
        _ = self;
    }
};