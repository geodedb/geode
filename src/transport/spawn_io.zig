//! An `std.Io` for spawning a child process from inside a running server
//! (SONNY-2394). Shared by the two paths that spawn `openssl` to self-sign a
//! certificate: `QuicTransport.listen` (transport/quic.zig) and the
//! `geode serve` startup generator (tools/cert_gen.zig). It is a module of its
//! own because cert_gen.zig is compiled into several modules, and a file may
//! belong to only one module per compilation.
//!
//! Two properties matter, and neither of std's ready-made instances has both:
//!
//! * It changes no process-wide signal disposition. `std.Io.Threaded.init`
//!   installs SIGIO/SIGPIPE handlers and restores the ones it saved on deinit,
//!   so a transient instance inside a running server -- concurrently with
//!   another thread's Threaded -- can restore a stale disposition (SIGPIPE back
//!   to "terminate") under a live process (a78b2f29). This starts from
//!   `init_single_threaded`, which never touches signals, and gives it a real
//!   allocator (spawnPosix's argv arena; the stock global instance ships with
//!   `.failing`). No worker threads are needed: waiting for the child and
//!   draining its pipes (`std.process.run`) use blocking syscalls and poll().
//! * It carries the PROCESS environment. `init_single_threaded` starts with an
//!   EMPTY one, and std uses the spawning Io's environment twice: to resolve
//!   argv[0] (its PATH, else the fixed `std.Io.Threaded.default_PATH`,
//!   /usr/local/bin:/bin/:/usr/bin) and, when no `environ_map` is given, as the
//!   child's whole environment. This seeds libc's `environ`, the way std's own
//!   start code seeds its Io, so the binary is found on the process PATH and
//!   the child sees variables such as OPENSSL_CONF. A
//!   `SpawnOptions.environ_map` alone would not fix the lookup: `spawnPosix`
//!   searches the Io's PATH, never the map's.

const std = @import("std");
const builtin = @import("builtin");

/// A spawn-capable Io with the properties above. `deinit` it when done; it
/// restores no signal handler because it installed none.
pub fn threaded() std.Io.Threaded {
    var t: std.Io.Threaded = .init_single_threaded;
    t.allocator = std.heap.smp_allocator;
    if (comptime std.process.Environ.Block == std.process.Environ.PosixBlock and builtin.link_libc) {
        const block: std.process.Environ.Block = .{ .slice = std.mem.span(std.c.environ) };
        t.environ = .{ .process_environ = .{ .block = block } };
        t.environ_initialized = block.isEmpty();
    }
    return t;
}
