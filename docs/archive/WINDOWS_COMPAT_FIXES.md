# Windows Compatibility Fixes

**Date**: 2025-09-29  
**Zig Version**: 0.15.1

## Summary

Fixed Windows build errors for cross-platform compatibility. The main issues were related to POSIX-specific APIs that are not available on Windows.

## Issues Fixed

### 1. Environment Variable Access
**Problem**: `std.posix.getenv()` is not available on Windows  
**Solution**: Use `std.process.getEnvVarOwned()` with proper error handling

```zig
// Before (Unix-only):
if (std.posix.getenv("ENV_VAR")) |v| { ... }

// After (Cross-platform):
if (std.process.getEnvVarOwned(allocator, "ENV_VAR") catch null) |v| {
    defer allocator.free(v);
    // use v
}
```

### 2. File Descriptors for Standard I/O
**Problem**: `std.posix.STDOUT_FILENO` not available on Windows  
**Solution**: Use platform-specific file handle creation

```zig
// Cross-platform stdout/stderr/stdin:
const stdout = if (builtin.os.tag == .windows)
    std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
else
    std.fs.File{ .handle = std.posix.STDOUT_FILENO };

// Then use file methods:
try stdout.writeAll(data);
```

### 3. Process Arguments
**Problem**: `std.process.args()` not available on Windows  
**Solution**: Use `std.process.argsAlloc()` instead

```zig
// Before (Unix-only):
var args = std.process.args();
_ = args.next(); // skip program name
const arg1 = args.next() orelse "default";

// After (Cross-platform):
const args_list = try std.process.argsAlloc(allocator);
defer std.process.argsFree(allocator, args_list);
const arg1 = if (args_list.len > 1) args_list[1] else "default";
```

### 4. File Permissions
**Problem**: `chmod()` not supported on Windows  
**Solution**: Conditionally skip permission changes on Windows

```zig
// Only set permissions on Unix-like systems:
if (builtin.os.tag != .windows) {
    try file.chmod(0o600);
}
```

### 5. Socket Operations (libc dependency)
**Problem**: QUIC socket operations require libc on Windows  
**Solution**: Link libc for Windows builds in build.zig

```zig
// In build.zig:
const geoded_exe = b.addExecutable(.{ ... });
if (target.result.os.tag == .windows) {
    geoded_exe.linkLibC();
}
```

## Files Modified

### Benchmark Files
- `benchmark_federation_mismatch_latency.zig`
- `benchmark_bias_clamp_variance.zig`
- `benchmark_federation_mismatch_frequency.zig`
- `benchmarks/benchmark_remote_kms_unwrap_concurrency.zig`

### Tool Files
- `tools/gen_fuzz.zig`
- `src/tools/fed_latency_aggregate.zig`
- `src/tools/fed_latency_streak.zig`
- `src/tools/fed_latency_validate.zig`
- `src/tools/fed_latency_governance.zig`
- `src/tools/bench_regress.zig`
- `src/tools/bench_extract.zig`
- `src/tools/implementation_reality_delta.zig`

### Core Files
- `src/lib.zig` - Environment variable handling
- `src/client/main.zig` - Environment variable handling
- `src/server/main.zig` - Environment variable handling
- `src/transport/quic.zig` - File permissions and builtin import
- `src/gql/main.zig` - Standard I/O handling
- `src/log/logger.zig` - Standard error handling
- `build.zig` - Added libc linking for Windows

## Testing

All changes have been tested to ensure:
1. ✅ Build succeeds on both Unix and Windows platforms
2. ✅ No functionality is lost on Unix systems
3. ✅ Windows-specific code paths are properly isolated
4. ✅ All tests pass with the compatibility changes

## Best Practices for Future Development

1. **Always use `builtin` for platform detection**:
   ```zig
   const builtin = @import("builtin");
   if (builtin.os.tag == .windows) { ... }
   ```

2. **Prefer cross-platform APIs**:
   - Use `std.process.getEnvVarOwned()` over `std.posix.getenv()`
   - Use `std.process.argsAlloc()` over `std.process.args()`
   - Use `std.fs.File` methods over direct POSIX calls

3. **Handle platform differences explicitly**:
   - Don't assume Unix-like behavior
   - Test for feature availability at compile time
   - Provide fallbacks or skip operations when not supported

4. **Link required libraries**:
   - Windows socket operations often require libc
   - Add platform-specific linking in build.zig

## CI/CD Considerations

The Windows CI pipeline should now successfully:
- Build all executables
- Run all tests (except those requiring Unix-specific features)
- Generate all benchmark binaries

Note: Some features like file permissions (chmod) are silently skipped on Windows as they're not critical for functionality.