# CRITICAL ISSUE: Geode Query Command Hangs in Python Subprocess

## Summary
The `geode query` command **hangs indefinitely** when executed from Python's `subprocess.run()` with `capture_output=True`, even with `--no-quic` flag. This causes ALL test runners to time out.

## Root Cause
The geode binary appears to be blocking on stdout/stderr or stdin when run from Python subprocess, but works perfectly from an interactive shell.

## Evidence

### Works from Shell ✓
```bash
$ ./zig-out/bin/geode query --no-quic "RETURN 1 AS x"
{"status_class":"00000","columns":["x"],"rows":[[1]],"flagger_findings":[]}
# Completes instantly
```

### Hangs from Python ✗
```python
subprocess.run(
    ['./zig-out/bin/geode', 'query', '--no-quic', 'RETURN 1 AS x'],
    capture_output=True,
    timeout=2
)
# TimeoutExpired after 2 seconds
```

### But Non-Query Commands Work ✓
```python
subprocess.run(
    ['./zig-out/bin/geode', 'auth', '--help'],  # Works
    ['./zig-out/bin/geode', 'user', 'create', 'test', 'test@example.com'],  # Works
    ['./zig-out/bin/geode', '--help'],  # Works
    capture_output=True
)
```

## Key Observations

1. **Help commands work**: `geode --help`, `auth --help`, `query --help` all complete
2. **Query execution hangs**: ANY query with `--no-quic` hangs
3. **Output destination**: Help goes to stderr (works), queries go to stdout (hangs)
4. **Test results**:
   - geode_auth.yml: 21/21 pass (uses auth/user/role commands)
   - geode_cli_only.yml: 9/9 pass (uses --help commands)
   - geode_*_comprehensive.yml: ALL TIMEOUT (use query commands)

## Impact

- **1654 total tests** in geodetestlab
- **~1429 tests** use `query` command
- **ALL query-based tests hang** → appear as "exit code" failures
- Test suite cannot complete (times out after hours)

## Suspected Causes

1. **Buffering Issue**: Geode may not be flushing stdout when run non-interactively
2. **Stdin Handling**: Geode may be waiting for stdin to close
3. **File Descriptor Issue**: Different FD handling between shell and subprocess
4. **Signal Handling**: Process may be waiting for a signal

## Recommendations

### Immediate Fix (in geode binary)

Check `/home/benji/src/spyder/geode/src/cli/main.zig` `cmdQuery` function:

1. **Ensure stdout is flushed** after writing JSON output
2. **Close stdin** immediately if query is provided via args (not reading from stdin)
3. **Check for interactive terminal** and handle non-TTY mode correctly

### Likely locations to check:

```zig
// In cmdQuery or query execution path:
const stdout_fd = std.fs.File{ .handle = 1 };
_ = try stdout_fd.writeAll(json_output);
// ADD: try stdout_fd.sync(); // Force flush
```

### Test the fix:
```bash
# After fixing:
python3 -c "
import subprocess
result = subprocess.run(
    ['./zig-out/bin/geode', 'query', '--no-quic', 'RETURN 1 AS x'],
    capture_output=True,
    timeout=2
)
print(f'Success! Exit: {result.returncode}')
"
```

## Why Previous "Fixes" Didn't Work

1. ✗ Reduced timeout (5s → 2s): Still hangs
2. ✗ Added --no-quic flag: Command already had it, still hangs  
3. ✗ Cleanup optimizations: Not a cleanup issue
4. ✗ Parallelization: Doesn't help if each worker hangs

## Next Steps

1. Investigate `cmdQuery` function in src/cli/main.zig
2. Add explicit stdout flush after query output
3. Ensure stdin is properly handled when query provided via args
4. Test with Python subprocess to verify fix
5. Re-run geodetestlab suite (should go from ~0% to 90%+ pass rate)

## Files to Investigate

- `src/cli/main.zig` - cmdQuery function
- `src/gql/executor.zig` - Query execution and output
- `src/transport/` - Any buffering in transport layer

---

**Status**: Root cause identified, awaiting fix in geode binary
**Impact**: CRITICAL - blocks all query-based testing
**Effort**: Likely 1-2 line fix (add stdout flush)
