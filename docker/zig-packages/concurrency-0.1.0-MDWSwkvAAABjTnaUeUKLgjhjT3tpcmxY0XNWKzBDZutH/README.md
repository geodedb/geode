# concurrency

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.15.1+-orange.svg)](https://ziglang.org/)

A high-performance thread pool and lock-free bounded MPMC queue for Zig.

## Features

- **Lock-Free MPMC Queue**: Vyukov-style bounded queue with per-slot sequence counters
- **Thread Pool**: Configurable worker pool with non-blocking and blocking submission
- **Zero Dependencies**: Pure Zig standard library only
- **Cross-Platform**: Linux, macOS, Windows support
- **Well Tested**: Unit, integration, and concurrent stress tests

## Installation

### Using Zig Package Manager

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .concurrency = .{
        .url = "https://gitlab.com/devnw/zig/concurrency/-/archive/v0.1.0/concurrency-v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const concurrency = b.dependency("concurrency", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("concurrency", concurrency.module("concurrency"));
```

## Quick Start

```zig
const std = @import("std");
const concurrency = @import("concurrency");

pub fn main() !void {
    const pool = try concurrency.ThreadPool.init(
        std.heap.page_allocator,
        .{ .num_threads = 4 },
    );
    defer pool.deinit();

    // Submit work items to the pool.
    _ = pool.submit(.{
        .context = @ptrCast(&my_ctx),
        .callback = myWork,
    });
}
```

## Requirements

- Zig 0.15.1 or later

## Building

```bash
# Build the library
make build

# Run tests
make test

# Quick development iteration
make dev

# Full CI pipeline
make ci
```

## Documentation

See the [docs](docs/) directory for detailed documentation.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Security

See [SECURITY.md](SECURITY.md) for security policy and vulnerability reporting.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.
