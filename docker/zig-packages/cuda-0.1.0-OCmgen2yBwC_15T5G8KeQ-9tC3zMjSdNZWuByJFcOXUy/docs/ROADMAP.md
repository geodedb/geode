# Roadmap

This document outlines the development roadmap for the Zig CUDA library. All issues are tracked in [GitLab Issues](https://gitlab.com/devnw/zig/cuda/-/issues).

## Milestones

### v0.2.0 - Critical Fixes
**Focus**: Address critical bugs and safety issues

| Issue | Title | Labels | Status |
|-------|-------|--------|--------|
| [#1](https://gitlab.com/devnw/zig/cuda/-/issues/1) | Fix potential buffer overflow in kernel name handling | bug, critical, security | Open |
| [#2](https://gitlab.com/devnw/zig/cuda/-/issues/2) | Add thread-safety to module kernel cache | bug, critical | Open |
| [#3](https://gitlab.com/devnw/zig/cuda/-/issues/3) | Add LaunchConfig validation | bug, critical | Open |
| [#4](https://gitlab.com/devnw/zig/cuda/-/issues/4) | Fix stream synchronization edge case | bug | Open |
| [#5](https://gitlab.com/devnw/zig/cuda/-/issues/5) | Implement true pinned memory allocation | enhancement, critical, performance | Open |

### v0.3.0 - Core Features
**Focus**: Implement missing core functionality

| Issue | Title | Labels | Status |
|-------|-------|--------|--------|
| [#6](https://gitlab.com/devnw/zig/cuda/-/issues/6) | Implement unified memory support | enhancement | Open |
| [#7](https://gitlab.com/devnw/zig/cuda/-/issues/7) | Add multi-GPU support | enhancement | Open |
| [#8](https://gitlab.com/devnw/zig/cuda/-/issues/8) | Add CUBIN module loading support | enhancement | Open |
| [#9](https://gitlab.com/devnw/zig/cuda/-/issues/9) | Add stream priority support | enhancement | Open |
| [#10](https://gitlab.com/devnw/zig/cuda/-/issues/10) | Add kernel occupancy calculator | enhancement, performance | Open |
| [#21](https://gitlab.com/devnw/zig/cuda/-/issues/21) | Add edge case and boundary condition tests | testing | Open |
| [#22](https://gitlab.com/devnw/zig/cuda/-/issues/22) | Add error recovery tests | testing | Open |
| [#25](https://gitlab.com/devnw/zig/cuda/-/issues/25) | Add CUDA error string support | enhancement | Open |
| [#26](https://gitlab.com/devnw/zig/cuda/-/issues/26) | Add CUDA driver version checking | enhancement | Open |
| [#28](https://gitlab.com/devnw/zig/cuda/-/issues/28) | Add memory alignment constants and validation | enhancement | Open |

### v0.4.0 - Performance & Polish
**Focus**: Performance optimizations and API improvements

| Issue | Title | Labels | Status |
|-------|-------|--------|--------|
| [#11](https://gitlab.com/devnw/zig/cuda/-/issues/11) | Add async transfer batching | enhancement, performance | Open |
| [#12](https://gitlab.com/devnw/zig/cuda/-/issues/12) | Normalize memory API parameter ordering | api, enhancement | Open |
| [#13](https://gitlab.com/devnw/zig/cuda/-/issues/13) | Add memory pool fragmentation handling | enhancement, performance | Open |
| [#14](https://gitlab.com/devnw/zig/cuda/-/issues/14) | Add GPU event-based profiling | enhancement, performance | Open |
| [#15](https://gitlab.com/devnw/zig/cuda/-/issues/15) | Add NVRTC compilation options configuration | enhancement | Open |
| [#16](https://gitlab.com/devnw/zig/cuda/-/issues/16) | Add type-safe kernel arguments | api, enhancement | Open |
| [#17](https://gitlab.com/devnw/zig/cuda/-/issues/17) | Add explicit context switching API | api, enhancement | Open |
| [#23](https://gitlab.com/devnw/zig/cuda/-/issues/23) | Add performance regression tests | testing, performance | Open |

### v1.0.0 - Stable Release
**Focus**: API stabilization, documentation, and cross-platform support

| Issue | Title | Labels | Status |
|-------|-------|--------|--------|
| [#18](https://gitlab.com/devnw/zig/cuda/-/issues/18) | Add comprehensive API documentation | documentation | Open |
| [#19](https://gitlab.com/devnw/zig/cuda/-/issues/19) | Add architecture decision records | documentation | Open |
| [#20](https://gitlab.com/devnw/zig/cuda/-/issues/20) | Add integration and usage guides | documentation | Open |
| [#24](https://gitlab.com/devnw/zig/cuda/-/issues/24) | Add cross-platform support (macOS, Windows) | enhancement | Open |
| [#27](https://gitlab.com/devnw/zig/cuda/-/issues/27) | Define thread-safety guarantees | api, documentation | Open |

## Priority Legend

- **critical**: Must be fixed before any release
- **security**: Security-related issue
- **bug**: Something isn't working correctly
- **enhancement**: New feature or improvement
- **performance**: Performance optimization
- **api**: API design change
- **documentation**: Documentation improvement
- **testing**: Test coverage improvement

## Contributing

See the [Contributing Guide](../README.md#contributing) for how to get involved.

Pick an issue from the roadmap, comment on it to claim it, and submit a merge request when ready.
