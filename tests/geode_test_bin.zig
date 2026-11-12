//! SONNY-2697: the geode executable this build emitted, for tests that spawn
//! it. Only a test artifact registered with build.zig's `spawnsBuiltGeode`
//! can import this module; spawning `./zig-out/bin/geode` ran whatever the
//! last install left there.
const std = @import("std");
const options = @import("geode_test_bin_options");

/// Absolute path of the geode executable this build emitted.
pub const geode_exe: []const u8 = if (std.fs.path.isAbsolute(options.geode_exe))
    options.geode_exe
else
    options.build_root ++ std.fs.path.sep_str ++ options.geode_exe;

/// The build root (the checkout), for tests that read the sources.
pub const build_root: []const u8 = options.build_root;
