# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Async transfer batching with TransferBatch for efficient batch memory operations (#11)
- Memory pool fragmentation handling with PoolStats, defragment(), compact() (#13)
- GPU event-based profiling with EventProfiler and ScopedProfiler (#14)
- NVRTC compilation options configuration with NvrtcOptions struct (#15)
- Type-safe kernel arguments with TypedKernelArgs and kernelParams() (#16)
- Explicit context switching API with pushContext/popContext and ContextScope (#17)
- NvrtcCompiler.compileToPtxWithOptions() for full compilation control
- NvrtcCompiler.getCompilationLog() for debugging compilation issues

### Changed
- Memory API parameters already follow consistent dst, src, size, stream pattern (#12)

## [0.2.0] - 2025-01-XX

### Added
- Unified memory support (cuMemAllocManaged, cuMemPrefetchAsync, cuMemAdvise)
- Multi-GPU support with device enumeration and peer access
- CUBIN module loading from files and binary data
- Stream priority support (create high/low priority streams)
- Kernel occupancy calculator (getMaxActiveBlocksPerSM, getOptimalBlockSize)
- New device.zig module for multi-GPU management
- UnifiedBuffer type with prefetch and advise methods
- StreamPriority type with range queries
- OccupancyResult type for launch configuration optimization
- Function attribute queries (registers, shared memory, etc.)

### Changed
- Stream struct now tracks priority
- MemoryStats now includes unified_bytes_allocated

### Fixed
- Buffer overflow in kernel name handling (MAX_KERNEL_NAME_LEN=255)
- Thread-unsafe module kernel cache (added mutex protection)
- LaunchConfig validation missing (added validate/validateWithLimits)
- Stream synchronization edge case for invalid null handle state
- True pinned memory support via cuMemAllocHost/cuMemFreeHost

## [0.1.0] - 2024-01-XX

### Added
- Initial release
- Dynamic CUDA driver loading via dlopen (Linux)
- Graceful degradation when CUDA unavailable
- Device probing and enumeration
- Memory management with buffer pooling
- Stream and event support
- PTX module loading
- NVRTC JIT compilation support
- Performance profiling utilities
- Support for Kepler (SM 3.0) through Blackwell (SM 10.0) architectures

### Architecture Support
- Kepler (SM 3.0 - 3.7)
- Maxwell (SM 5.0 - 5.3)
- Pascal (SM 6.0 - 6.2)
- Volta (SM 7.0)
- Turing (SM 7.5)
- Ampere (SM 8.0 - 8.9)
- Ada Lovelace (SM 8.9)
- Hopper (SM 9.0)
- Blackwell (SM 10.0)

[Unreleased]: https://gitlab.com/devnw/zig/cuda/-/compare/v0.1.0...HEAD
[0.1.0]: https://gitlab.com/devnw/zig/cuda/-/releases/v0.1.0
