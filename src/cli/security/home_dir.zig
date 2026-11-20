// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 CodePros
// CANARY: REQ=REQ-SONNY-6544-HOME-ABSOLUTE; FEATURE="CLI home directory"; ASPECT=AbsoluteHomeOnly; STATUS=TESTED; TEST=tests/test_sonny6544_relative_home.zig; OWNER=cli; UPDATED=2026-11-14

//! SONNY-6544: the home directory the CLI keeps session secrets under
//! (`~/.geode/credentials.json`, the state files of `geode session`,
//! `authn`, `apikey`, `mtls`).
//!
//! HOME (USERPROFILE on Windows when HOME is unset) must be an absolute
//! path. A relative or empty HOME is refused, never resolved: resolving it
//! against the current directory would write session secrets wherever the
//! command happens to run, and the `std.Io.Dir.*Absolute` calls assert an
//! absolute path (a Debug build panicked on `HOME=relhome geode query`).
//! An XDG base directory variable that is relative is ignored, as the XDG
//! Base Directory specification requires.
//!
//! Depends only on std.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    /// HOME (and, on Windows, USERPROFILE) is not set.
    HomeNotSet,
    /// HOME is empty or not an absolute path.
    HomeNotAbsolute,
    OutOfMemory,
};

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name.ptr) orelse return null;
    return std.mem.span(value);
}

/// The variable `homeDir` reads: HOME, or USERPROFILE on Windows when HOME
/// is unset. Null when neither is set.
pub fn homeVariable() ?struct { name: []const u8, value: []const u8 } {
    if (getenv("HOME")) |v| return .{ .name = "HOME", .value = v };
    if (builtin.os.tag == .windows) {
        if (getenv("USERPROFILE")) |v| return .{ .name = "USERPROFILE", .value = v };
    }
    return null;
}

/// The home directory, absolute; the caller owns it.
pub fn homeDirAlloc(allocator: std.mem.Allocator) Error![]u8 {
    const home = homeVariable() orelse return error.HomeNotSet;
    if (home.value.len == 0 or !std.fs.path.isAbsolute(home.value)) return error.HomeNotAbsolute;
    return allocator.dupe(u8, home.value);
}

/// `<home>/<parts...>`; the caller owns it.
pub fn homePathAlloc(allocator: std.mem.Allocator, parts: []const []const u8) Error![]u8 {
    const home = try homeDirAlloc(allocator);
    defer allocator.free(home);
    var all: [8][]const u8 = undefined;
    std.debug.assert(parts.len < all.len);
    all[0] = home;
    @memcpy(all[1 .. parts.len + 1], parts);
    return std.fs.path.join(allocator, all[0 .. parts.len + 1]) catch error.OutOfMemory;
}

/// An XDG base directory variable (`XDG_STATE_HOME`, ...) when it is set to
/// an absolute path; null when it is unset, empty or relative (ignored).
pub fn xdgDir(name: [:0]const u8) ?[]const u8 {
    const value = getenv(name) orelse return null;
    if (value.len == 0 or !std.fs.path.isAbsolute(value)) return null;
    return value;
}

/// What is wrong, for an `Error: ...` line; null for an error this module
/// does not return.
pub fn errorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.HomeNotSet => "HOME is not set; geode keeps session credentials and CLI state under HOME: set HOME to your home directory (an absolute path)",
        error.HomeNotAbsolute => "HOME is empty or not an absolute path; geode keeps session credentials and CLI state under HOME and does not resolve a relative HOME against the current directory: set HOME to an absolute path",
        else => null,
    };
}

/// Print `Error: <errorMessage(err)>` on stderr (a generic line otherwise).
pub fn printError(err: anyerror) void {
    std.debug.print("Error: {s}\n", .{errorMessage(err) orelse "cannot determine the home directory"});
}
