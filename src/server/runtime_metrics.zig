// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Runtime metrics helper: a small append-only registry of named
//! `*std.atomic.Value(u64)` counters plus a snapshot helper. Used to
//! surface coordinator throughput, lock-wait timing, and allocator
//! usage during heavy-load reproductions.

const std = @import("std");

/// `name` must outlive the registry — the registry stores the slice
/// by reference. Use string literals or otherwise-static memory.
/// `ptr` likewise must outlive the registry; the counter's owner is
/// responsible for keeping the atomic value alive while it's registered.
pub const Counter = struct {
    name: []const u8,
    ptr: *std.atomic.Value(u64),
};

/// `name` must outlive the registry. `callback` is invoked at snapshot
/// time and must be cheap (no I/O, no allocations, no locks held longer
/// than a single field read). Returns the current value as a u64.
pub const Gauge = struct {
    name: []const u8,
    callback: *const fn (ctx: *anyopaque) u64,
    ctx: *anyopaque,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    counters: std.ArrayList(Counter),
    gauges: std.ArrayList(Gauge),
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    pub fn init(allocator: std.mem.Allocator) !*Registry {
        const self = try allocator.create(Registry);
        self.* = .{
            .allocator = allocator,
            .counters = std.ArrayList(Counter).empty,
            .gauges = std.ArrayList(Gauge).empty,
        };
        return self;
    }

    pub fn deinit(self: *Registry) void {
        self.counters.deinit(self.allocator);
        self.gauges.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn register(self: *Registry, name: []const u8, ptr: *std.atomic.Value(u64)) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.counters.append(self.allocator, .{ .name = name, .ptr = ptr });
    }

    pub fn registerGauge(
        self: *Registry,
        name: []const u8,
        callback: *const fn (ctx: *anyopaque) u64,
        ctx: *anyopaque,
    ) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.gauges.append(self.allocator, .{
            .name = name,
            .callback = callback,
            .ctx = ctx,
        });
    }

    pub fn snapshotInto(
        self: *Registry,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
    ) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var first = true;
        for (self.counters.items) |c| {
            if (!first) try out.append(allocator, ' ');
            first = false;

            // Format: "name=value"
            try out.appendSlice(allocator, c.name);
            try out.append(allocator, '=');
            const val = c.ptr.load(.acquire);
            const str = try std.fmt.allocPrint(allocator, "{d}", .{val});
            defer allocator.free(str);
            try out.appendSlice(allocator, str);
        }
        for (self.gauges.items) |g| {
            if (!first) try out.append(allocator, ' ');
            first = false;

            try out.appendSlice(allocator, g.name);
            try out.append(allocator, '=');
            const val = g.callback(g.ctx);
            const str = try std.fmt.allocPrint(allocator, "{d}", .{val});
            defer allocator.free(str);
            try out.appendSlice(allocator, str);
        }
    }
};

/// Process-global registry; nullable so tests can swap one in without
/// the periodic-emit task. Initialised by the server `main` at startup.
var g_registry: ?*Registry = null;

pub fn globalRegistry() ?*Registry {
    return g_registry;
}

/// Must only be called before any thread can call `globalRegistry()`,
/// or after all such threads have stopped (e.g., server startup before
/// the metrics-emit task is spawned, and shutdown after it joins).
/// `g_registry` is not protected by an atomic; concurrent calls during
/// active read traffic are a data race.
pub fn setGlobalRegistry(r: ?*Registry) void {
    g_registry = r;
}
