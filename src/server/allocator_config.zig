// Copyright 2024-2026 CodePros
// SPDX-License-Identifier: Apache-2.0
//
// Server top-level allocator selection.
//
// PROBLEM (fixed by this module):
// std.heap.GeneralPurposeAllocator(.{}){}  defaults never_unmap=true and
// retain_metadata=true in Debug and ReleaseSafe builds.  Freed pages remain
// mapped so the allocator can detect use-after-free.  Under sustained QUIC
// load the server's RSS grows ~19MB per connection and eventually trips
// process memory limits, manifesting as "server hung" in geodetestlab.
//
// SOLUTION:
// Default to std.heap.smp_allocator — a thread-safe allocator that uses
// mmap/munmap for large allocations and properly returns freed memory to
// the OS.  Developers who need leak detection can opt in to GPA with
// `zig build -Denable-gpa-debug`.
//
// LIFETIME NOTE:
// The `.gpa_debug` branch heap-allocates the GeneralPurposeAllocator so that
// `Handle.allocator` can keep a stable pointer to it.  Stack-allocating the
// GPA inside init() and returning the Handle by value would leave the
// caller's `allocator` field pointing at a defunct stack frame.  Because
// heap allocation can fail, `Handle.init()` returns `!Handle`.

const std = @import("std");
const build_options = @import("build_options");

/// Top-level server allocator.  The concrete choice is driven by the
/// `enable-gpa-debug` build option.
pub const Mode = enum {
    /// std.heap.smp_allocator — production default.  Returns memory to OS.
    smp,
    /// GeneralPurposeAllocator with default safety settings.  Retains pages
    /// for UAF detection; only use for local leak investigations.
    gpa_debug,
};

pub const mode: Mode = if (build_options.enable_gpa_debug) .gpa_debug else .smp;

/// Owned allocator handle.  For the smp mode this is a zero-cost wrapper
/// around the process-wide smp allocator; for the gpa_debug mode it owns
/// a heap-allocated GeneralPurposeAllocator instance that must be
/// deinitialised on exit.
pub const Handle = struct {
    gpa_ptr: ?*std.heap.GeneralPurposeAllocator(.{}) = null,
    allocator: std.mem.Allocator,

    pub fn init() !Handle {
        switch (mode) {
            .smp => return .{ .allocator = std.heap.smp_allocator },
            .gpa_debug => {
                const gpa_ptr = try std.heap.page_allocator.create(std.heap.GeneralPurposeAllocator(.{}));
                gpa_ptr.* = std.heap.GeneralPurposeAllocator(.{}){};
                return .{
                    .gpa_ptr = gpa_ptr,
                    .allocator = gpa_ptr.allocator(),
                };
            },
        }
    }

    pub fn deinit(self: *Handle) void {
        if (self.gpa_ptr) |gpa_ptr| {
            if (gpa_ptr.deinit() == .leak) {
                std.log.warn("allocator_config: GeneralPurposeAllocator reported memory leaks at shutdown", .{});
            }
            std.heap.page_allocator.destroy(gpa_ptr);
        }
    }
};
