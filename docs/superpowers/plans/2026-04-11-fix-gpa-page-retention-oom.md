# Fix GPA Page Retention OOM (txn-complex-operations-chunked) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the intermittent `txn-complex-operations-chunked` test failure by replacing the server's main allocator with one that returns freed memory to the OS, so RSS does not grow linearly with connection count.

**Architecture:** The server currently uses `std.heap.GeneralPurposeAllocator(.{}){}`. In Debug and ReleaseSafe (the two safety-enabled modes), the GPA's defaults set `never_unmap = true` and `retain_metadata = true` — freed pages stay mapped forever so the allocator can detect use-after-free. The geodetestlab harness runs the server in ReleaseSafe or Debug, opens ~3 QUIC connections per test across ~12 prior tests before `txn-complex-operations-chunked`, and each handler touches pages that never return to RSS. By the time the complex test sends 703 statements across 2 chunks, the server is at ~800MB+ RSS and the additional load pushes it past process memory limits, causing the harness to observe it as hung and force-kill it.

The fix is to use `std.heap.smp_allocator` — a lock-free thread-safe allocator in Zig's standard library designed for server workloads — as the server's top-level allocator. `smp_allocator` uses mmap+munmap for large allocations and shared thread-local pools for small allocations, properly returning memory to the OS on free. We keep GPA available behind a build option for local leak detection, but the default server build uses `smp_allocator`.

**Tech Stack:** Zig 0.15.1+, `std.heap.smp_allocator`, existing ReleaseSafe build pipeline, geodetestlab test harness.

---

## File Structure

| File | Role |
|---|---|
| `src/server/main.zig` | Server entrypoint. Owns the top-level allocator. Change from `GeneralPurposeAllocator(.{}){}` to `smp_allocator` (with a `-Denable-gpa-debug` build flag to opt back in for leak debugging). |
| `build.zig` | Adds the `enable-gpa-debug` build option and threads it through to the server executable as a comptime config. |
| `src/server/allocator_config.zig` (new) | Thin module that exposes `pub const top_level_allocator: std.mem.Allocator` based on the build option. Keeps main.zig clean. |
| `tests/integration/test_server_memory_pressure.zig` (new) | Regression test. Spins up a server subprocess, runs N connections in a loop, asserts RSS stays below a bound. Fails the previous build, passes the new one. |
| `Makefile` | Add `make memtest` target wrapping the new regression test for easy local runs. |

Tasks progress strictly bottom-up: introduce the allocator module first (with a failing test proving the problem exists), switch main.zig to use it, verify the geodetestlab suite passes, then add the build-option escape hatch.

---

## Task 1: Regression Test — Prove the Leak Exists

Write the failing memory-pressure test **first**, in the style of the existing `tests/integration/` tests, so we have hard evidence the bug exists and a green signal once it's fixed.

The test launches the real server binary as a subprocess, runs 60 sequential simple queries against it, samples the server's RSS via `/proc/<pid>/status`, and asserts the growth is bounded. The current binary will fail this test (RSS grows ~19MB per connection → ~1.1GB after 60); the fixed binary will pass it.

**Files:**

- Create: `tests/integration/test_server_memory_pressure.zig`
- Modify: `build.zig` (register the new test)

- [ ] **Step 1: Create the regression test file**

Create `tests/integration/test_server_memory_pressure.zig`:

```zig
// Copyright 2024-2026 CodePros
// SPDX-License-Identifier: Apache-2.0
//
// Regression test: server RSS must not grow unboundedly with connection count.
//
// Background: GPA's default never_unmap=true in Debug/ReleaseSafe retained freed
// pages forever, so every QUIC connection appeared to leak ~19MB of RSS.  Under
// load this OOM-crashed the server (see txn-complex-operations-chunked).
//
// This test launches the built server binary, opens 60 sequential QUIC
// connections (each runs a 3-statement query and disconnects) and asserts
// the RSS growth stays under a generous bound.  If the main allocator
// regresses to GPA defaults, this test fails.

const std = @import("std");
const testing = std.testing;

/// Read /proc/<pid>/status VmRSS in KB.  Returns 0 on failure (non-Linux).
fn readRssKb(pid: std.os.linux.pid_t) usize {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid}) catch return 0;
    const file = std.fs.openFileAbsolute(path, .{}) catch return 0;
    defer file.close();
    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return 0;
    const contents = buf[0..n];
    const needle = "VmRSS:";
    const start = std.mem.indexOf(u8, contents, needle) orelse return 0;
    var i = start + needle.len;
    while (i < contents.len and (contents[i] == ' ' or contents[i] == '\t')) i += 1;
    var end = i;
    while (end < contents.len and contents[end] >= '0' and contents[end] <= '9') end += 1;
    const kb = std.fmt.parseInt(usize, contents[i..end], 10) catch return 0;
    return kb;
}

test "server RSS stays bounded across 60 connections" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    const alloc = testing.allocator;

    // Create a temp data dir for the server.
    var tmp_path_buf: [64]u8 = undefined;
    const tmp_tpl = "/tmp/geode_memtest_XXXXXX";
    @memcpy(tmp_path_buf[0..tmp_tpl.len], tmp_tpl);
    tmp_path_buf[tmp_tpl.len] = 0;
    const tmp_c: [*:0]u8 = @ptrCast(&tmp_path_buf);
    const tmp_dir_c = std.c.mkdtemp(tmp_c);
    if (tmp_dir_c == null) return error.SkipZigTest;
    const tmp_dir_len = std.mem.len(tmp_dir_c.?);
    const tmp_dir = tmp_dir_c.?[0..tmp_dir_len];

    // Launch the real server binary so the test covers the shipping allocator.
    // Port 0 is not supported by the server; choose a free high port.
    const port: u16 = 34717;
    var port_buf: [24]u8 = undefined;
    const listen = try std.fmt.bufPrint(&port_buf, "127.0.0.1:{d}", .{port});

    const argv = [_][]const u8{
        "./zig-out/bin/geode", "serve",
        "--data-dir",          tmp_dir,
        "--listen",            listen,
        "--disable-auth",      "--insecure",
        "--log-level",         "error",
    };

    var env_map = try std.process.getEnvMap(alloc);
    defer env_map.deinit();
    try env_map.put("GEODE_ALLOW_NO_AUTH", "1");
    try env_map.put("GEODE_ADMIN_PASSWORD", "GeodeTestPassword123!");

    var child = std.process.Child.init(&argv, alloc);
    child.env_map = &env_map;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    defer _ = child.kill() catch {};

    // Give the server time to bind its port.
    std.time.sleep(3 * std.time.ns_per_s);
    const pid = @as(std.os.linux.pid_t, @intCast(child.id));

    // Warm up: one query to touch initial thread stacks.
    try runOneQuery(alloc, listen, "RETURN 1 AS warmup");
    const baseline_kb = readRssKb(pid);
    try testing.expect(baseline_kb > 0);

    // Run 60 more connections — representative of ~12 prior tests worth of traffic.
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const query = try std.fmt.allocPrint(
            alloc,
            "CREATE (n:MemTest {{id: {d}}}); MATCH (n:MemTest {{id: {d}}}) SET n.v = {d}; MATCH (n:MemTest {{id: {d}}}) RETURN n.v AS v",
            .{ i, i, i * 10, i },
        );
        defer alloc.free(query);
        try runOneQuery(alloc, listen, query);
    }

    const final_kb = readRssKb(pid);
    const growth_kb = if (final_kb > baseline_kb) final_kb - baseline_kb else 0;
    std.debug.print("RSS baseline={d}KB final={d}KB growth={d}KB\n", .{ baseline_kb, final_kb, growth_kb });

    // Bound: 60 connections must not grow RSS by more than 120MB.
    // With the old GPA (never_unmap=true) this was ~1.1GB and the test fails.
    // With smp_allocator this is typically <40MB.
    const max_growth_kb: usize = 120 * 1024;
    try testing.expect(growth_kb < max_growth_kb);
}

fn runOneQuery(alloc: std.mem.Allocator, listen: []const u8, query: []const u8) !void {
    const argv = [_][]const u8{
        "./zig-out/bin/geode", "query",
        "--insecure",          "--server",
        listen,                "-U",
        "geode",               "-P",
        "GeodeTestPassword123!",
        query,
    };
    var child = std.process.Child.init(&argv, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    _ = try child.wait();
}
```

- [ ] **Step 2: Register the test in build.zig**

Find the integration test registration block and add the new file to the test step. The exact shape depends on the project's build conventions — inspect the existing pattern for, e.g., `tests/integration/test_concurrent_quic.zig` and mirror it.

Run: `grep -n 'tests/integration/test_' build.zig | head -5`

Take the shape of whatever is already there and append the new test file in the same step. Do not invent a new test step.

- [ ] **Step 3: Run the test to verify it FAILS on current HEAD**

First build the binary so the test has something to spawn:

Run: `zig build`

Then run the test:

Run: `zig build test -Dtest-filter="server RSS stays bounded"`

Expected: FAIL. The assertion `growth_kb < max_growth_kb` triggers, log output shows growth of ~1.1GB. This is the RED signal — we are reproducing the bug.

If the test builds but does not fail, the bug may already be fixed by accident (e.g., someone else ran over `main.zig` first) — in which case stop, fetch origin/main, and re-verify before continuing.

- [ ] **Step 4: Commit the failing test**

```bash
git add tests/integration/test_server_memory_pressure.zig build.zig
git commit -m "test: add server RSS regression test (currently failing)

Reproduces the GPA page-retention OOM that causes
txn-complex-operations-chunked to fail intermittently under load.

60 sequential QUIC connections currently grow RSS by ~1.1GB
because GeneralPurposeAllocator(.{}){} defaults to never_unmap=true
in Debug and ReleaseSafe. The fix (next commit) switches the server
to smp_allocator, which returns freed pages to the OS."
```

---

## Task 2: Allocator Config Module

Introduce a small module that owns the top-level allocator decision so `main.zig` stays focused on wiring.

**Files:**

- Create: `src/server/allocator_config.zig`

- [ ] **Step 1: Create the allocator config module**

Create `src/server/allocator_config.zig`:

```zig
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
/// a GeneralPurposeAllocator instance that must be deinitialised on exit.
pub const Handle = struct {
    gpa: ?std.heap.GeneralPurposeAllocator(.{}) = null,
    allocator: std.mem.Allocator,

    pub fn init() Handle {
        switch (mode) {
            .smp => return .{ .allocator = std.heap.smp_allocator },
            .gpa_debug => {
                var h = Handle{
                    .gpa = std.heap.GeneralPurposeAllocator(.{}){},
                    .allocator = undefined,
                };
                h.allocator = h.gpa.?.allocator();
                return h;
            },
        }
    }

    pub fn deinit(self: *Handle) void {
        if (self.gpa) |*gpa| _ = gpa.deinit();
    }
};
```

- [ ] **Step 2: Verify it compiles (no test yet)**

Run: `zig build` (no `-Denable-gpa-debug`)

Expected: build fails with "no member named 'enable_gpa_debug' in build_options" — we will wire the build option in Task 3. **Do not commit yet.**

---

## Task 3: Wire `enable-gpa-debug` Build Option

**Files:**

- Modify: `build.zig`

- [ ] **Step 1: Find the existing options table**

Run: `grep -n 'b.option\|addOptions\|build_options' build.zig | head -20`

Read the matching lines — there is almost certainly an existing `const options = b.addOptions();` block (or similar) in this project; we append to it rather than creating a new one.

- [ ] **Step 2: Add the option and pass it through**

In the existing options block, add:

```zig
const enable_gpa_debug = b.option(
    bool,
    "enable-gpa-debug",
    "Use GeneralPurposeAllocator(.{}){} for the server main allocator (leak detection; default: smp_allocator)",
) orelse false;
options.addOption(bool, "enable_gpa_debug", enable_gpa_debug);
```

Locate the `options` identifier used elsewhere in the file to match the existing style. If the server exe already imports `build_options`, no further wiring is needed. If it does not, add `exe.root_module.addOptions("build_options", options);` on the server executable.

- [ ] **Step 3: Verify the allocator_config module now compiles**

Run: `zig build`

Expected: build succeeds.

- [ ] **Step 4: Commit the module + build option**

```bash
git add build.zig src/server/allocator_config.zig
git commit -m "build: add enable-gpa-debug option and allocator_config module

Introduces src/server/allocator_config.zig which selects the server's
top-level allocator at build time:
 - default: std.heap.smp_allocator (returns memory to OS)
 - -Denable-gpa-debug: GeneralPurposeAllocator (leak detection)

No behavioural change yet — main.zig still uses GPA directly.
The next commit switches main.zig to read from this module."
```

---

## Task 4: Switch main.zig to the New Allocator

**Files:**

- Modify: `src/server/main.zig:322-326`

- [ ] **Step 1: Read the exact current contents**

Run: `sed -n '322,326p' src/server/main.zig`

Expected output:

```
pub fn main() !void {
    // P2-3: Use GeneralPurposeAllocator instead of page_allocator for server main
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();
```

- [ ] **Step 2: Replace the block**

Edit `src/server/main.zig` — replace lines 323-326 with:

```zig
    // Top-level allocator chosen at build time — see src/server/allocator_config.zig.
    // Default: smp_allocator (returns freed memory to OS, required for sustained load).
    // Opt-in GPA for leak detection: `zig build -Denable-gpa-debug`.
    var alloc_handle = @import("allocator_config.zig").Handle.init();
    defer alloc_handle.deinit();
    const gpa = alloc_handle.allocator;
```

If `@import("allocator_config.zig")` does not resolve (build error about missing file), check the relative path — `main.zig` and `allocator_config.zig` are both in `src/server/` so `@import("allocator_config.zig")` is correct. Do not change the import style.

- [ ] **Step 3: Build and run unit tests**

Run: `zig build test`

Expected: all existing unit tests pass. If any fail, the failure is almost certainly because a test assumes GPA-specific behaviour (e.g., asserts on a specific allocation error) — fix those tests to use a hard-coded GPA inside the test, not the server's top-level allocator.

- [ ] **Step 4: Run the memory-pressure regression test**

Run: `zig build test -Dtest-filter="server RSS stays bounded"`

Expected: PASS. The log output shows growth < 120MB (typically <40MB).

If it still fails:

 1. Confirm the build picked up the new code: `zig build` should have compiled `main.zig` and `allocator_config.zig`.
 2. Print `alloc_handle.allocator.ptr` and compare to `std.heap.smp_allocator.ptr` — they should match in the default build.
 3. Check that no *other* code path in `server/main.zig` creates a second GPA instance. Run `grep -n 'GeneralPurposeAllocator' src/server/main.zig` — the answer must be zero matches after this step.

- [ ] **Step 5: Commit the switch**

```bash
git add src/server/main.zig
git commit -m "fix: switch server main allocator to smp_allocator

Replaces GeneralPurposeAllocator(.{}){} with smp_allocator via the
new allocator_config module.  GPA's default never_unmap=true in
Debug/ReleaseSafe retained freed pages forever, causing server RSS
to grow ~19MB per QUIC connection and OOM the process under load
(manifested as intermittent txn-complex-operations-chunked failures).

smp_allocator uses mmap/munmap for large allocations and returns
memory to the OS on free.  The memory regression test
(tests/integration/test_server_memory_pressure.zig) now passes:
60 sequential connections grow RSS by <40MB instead of ~1.1GB.

Developers who need leak detection can opt back into GPA with
\`zig build -Denable-gpa-debug\`."
```

---

## Task 5: Verify the Full geodetestlab Suite

**Files:** none (test-only)

- [ ] **Step 1: Build the binary the test harness uses**

Run: `zig build` (default Debug — matches what `GEODE_BINARY` points at in the harness)

Expected: success.

- [ ] **Step 2: Run the specific failing spec in isolation first**

Run:

```bash
cd ../geode-test-harness && \
GEODE_BINARY=../geode/zig-out/bin/geode \
geodetestlab run --spec geodetestlab-cli/specs/transaction_chunked_execution.yml -v 2>&1 | tail -30
```

Expected: `19 passed, 0 failed`. Every retry loop from the previous runs is gone.

If `txn-complex-operations-chunked` still fails:

- Check the server's RSS while the test runs: `ps -p $(pgrep -f 'geode serve.*geode-test') -o rss=,cmd=`
- If RSS grows >50MB per connection, `main.zig` is not using the new allocator — re-verify Task 4 Step 4's `grep -n 'GeneralPurposeAllocator' src/server/main.zig`.
- If RSS stays bounded but the test still hangs, the issue is *not* GPA retention — it's a second-order bug that this plan does not cover. Stop and escalate.

- [ ] **Step 3: Run the full geodetestlab suite**

Run:

```bash
cd ../geode-test-harness && GEODE_BINARY=../geode/zig-out/bin/geode make test 2>&1 | tail -15
```

Expected: `{"summary":{"total":4132,"passed":4128,"failed":0,"skipped":4}}`

Compared to the previous baseline (4127 passed, 1 failed), we should see 4128 passing and 0 failures. The skipped count stays at 4 (unrelated skips).

If any previously-passing test regresses:

- Inspect the first failing spec's output. If the test depends on process-lifetime leaked state (extremely unlikely but possible), it may need adjustment.
- Do NOT adjust the test to mask the regression. Find the real cause.

- [ ] **Step 4: Commit nothing, just record the result**

No code changes in this task. If results are green, continue to Task 6.

---

## Task 6: Add `make memtest` Target

**Files:**

- Modify: `Makefile`

- [ ] **Step 1: Find an existing test target to mirror**

Run: `grep -n '^[a-z].*:$\|^[a-z].*:.*$' Makefile | head -20`

Find a simple existing target like `test:` and note its indentation and shape.

- [ ] **Step 2: Add the memtest target**

Append to `Makefile`:

```makefile
# Fast regression check for server memory pressure.  Fails if RSS grows
# unboundedly with connection count (GPA page retention regression).
memtest:
 $(ZIG) build test -Dtest-filter="server RSS stays bounded"

.PHONY: memtest
```

Use the same tab/leading-whitespace conventions as the other targets. Do not use spaces.

- [ ] **Step 3: Run it**

Run: `make memtest`

Expected: PASS (same result as Task 4 Step 4).

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "build: add 'make memtest' target for RSS regression check

Wraps the server memory-pressure integration test so developers can
quickly verify the main allocator still returns memory to the OS."
```

---

## Task 7: Document the Allocator Choice

**Files:**

- Modify: `CLAUDE.md` (append to the "Development Setup" or similar section)

- [ ] **Step 1: Find the right insertion point**

Run: `grep -n '^## ' CLAUDE.md | head -20`

Identify the section that covers build/server configuration — likely "🔧 Development Setup" or similar.

- [ ] **Step 2: Append the allocator note**

Add this subsection in the appropriate place:

```markdown
### Server Allocator

The server process uses `std.heap.smp_allocator` by default.  GPA's
default `never_unmap=true` in Debug/ReleaseSafe retains freed pages,
which causes RSS to grow ~19MB per QUIC connection under load — and
eventually OOM-crashes the process under sustained geodetestlab runs
(historical bug: intermittent `txn-complex-operations-chunked` failure).

If you need leak detection locally, opt back into GPA with:

    zig build -Denable-gpa-debug

Never ship a release with `enable-gpa-debug` set.  The allocator
decision lives in `src/server/allocator_config.zig` and is exercised
by `tests/integration/test_server_memory_pressure.zig` (also runnable
as `make memtest`).
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document smp_allocator choice and gpa-debug opt-in"
```

---

## Task 8: Push and Close Out

**Files:** none

- [ ] **Step 1: Review the log**

Run: `git log --oneline origin/main..HEAD`

Expected: six commits in this order

```
<sha> docs: document smp_allocator choice and gpa-debug opt-in
<sha> build: add 'make memtest' target for RSS regression check
<sha> fix: switch server main allocator to smp_allocator
<sha> build: add enable-gpa-debug option and allocator_config module
<sha> test: add server RSS regression test (currently failing)
```

(Task 5 is test-only and has no commit.)

- [ ] **Step 2: Push**

Run: `git push`

Expected: all pre-push hooks (`zig build`, `zig build test`, `cross-compile`, CANARY lint) pass. The test suite run as part of pre-push should now be green because both the unit tests and the new memory regression test pass.

If any hook fails, do not force-push. Fix the underlying issue and amend the relevant commit.

- [ ] **Step 3: Final verification**

Run once more from a clean checkout to confirm nothing is hiding in your local cache:

```bash
cd ../geode-test-harness && GEODE_BINARY=../geode/zig-out/bin/geode make test 2>&1 | tail -5
```

Expected: `passed: 4128, failed: 0, skipped: 4`.

---

## Self-Review Notes

**Spec coverage:** Every requirement in the problem statement is mapped to a task — Task 1 proves the bug exists (RED), Task 4 fixes it (GREEN), Task 5 validates the full suite, Task 6 makes the regression test easy to run, Task 7 documents why the change was made. Task 8 pushes everything.

**No placeholders:** Every code block is complete. Every command is runnable. Every expected output is explicit.

**Type consistency:** `Handle.init()` / `Handle.deinit()` / `Handle.allocator` in `allocator_config.zig` are used in `main.zig` with exactly those names. The build option is spelled `enable-gpa-debug` at the CLI layer and `enable_gpa_debug` inside `build_options` (Zig's automatic kebab→snake conversion).

**Risk: `std.heap.smp_allocator` API shape.** This plan assumes `std.heap.smp_allocator` is a zero-argument global in Zig 0.15.1. If the API is instead `std.heap.SmpAllocator{}` or similar, Task 2 Step 1's `Handle` constructor needs a one-line adjustment. Before writing `allocator_config.zig`, verify with `zig build run -- --version` isn't the check — instead:

    grep -rn "smp_allocator\|SmpAllocator" ~/.local/share/mise/installs/zig/0.15.2/lib/std/heap.zig | head -5

If the result shows `pub const smp_allocator: Allocator = ...`, the plan is correct as written. If it shows a struct type requiring instantiation, adjust the `smp` branch of `Handle.init()` to own an instance.
