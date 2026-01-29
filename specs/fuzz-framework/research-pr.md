> **As of 2025‑09‑28.** Where Zig fuzzing specifics are cited, refer to the Zig 0.15.1 release notes and community threads about `zig build test --fuzz` and `std.testing.fuzz`. ([Zig Programming Language][1])

---

## Deep Research & Build Prompt — Full Fuzz Testing Suite for `spyderorg/geode` (Zig 0.15.1)

### 0) Context & Assumptions (confirm or revise)

* **Language/Tooling:** Zig **0.15.1**, using the **integrated fuzzer** invoked via `zig build test --fuzz` (and optional web UI); fuzz API likely through `std.testing.fuzz` (older posts mention `std.test.fuzzInput`; confirm in 0.15.1). ([Zig Programming Language][1])
* **Repository:** Private/custom graph DB **`spyderorg/geode`** (agent has read/write code access). “**Canary**” denotes an internal invariant or sentinel test already present in the codebase (discover pattern programmatically).
* **Targets/OS:** Prioritize Linux x86_64 CI; note Windows fuzz support may be limited/unstable in some versions. ([GitHub][2])
* **Non‑goals:** Performance benchmarking beyond coverage/unique crash metrics; load testing.

> Document any deviations from these assumptions early.

---

### 1) Objectives & Success Criteria

**Primary goal:** Deliver a **comprehensive fuzz test suite** for *all critical subsystems* of Geode **and** for **every existing canary where a test exists**.

**Definition of Done (DoD):**

* (A) **Inventory** of fuzz targets covering parser/ingest, storage/serialization, transaction/graph mutation APIs, query/planner, network protocols (if any), and concurrency-sensitive structures.
* (B) **Fuzz harnesses** for each target, runnable via `zig build test --fuzz` with per-target corpora.
* (C) **Corpus** bootstrapped from existing tests & fixtures; deduplicated/minimized; dictionaries for tokenized inputs (where relevant).
* (D) **Edge-case generators** (exhaustive boundary inputs + structure-aware random graphs).
* (E) **Canary coverage:** one fuzz harness per canary (where a test exists), with explicit invariants/oracles.
* (F) **Scaffold generator CLI**: `zig build gen-fuzz -- canary <name>` creates a new fuzz target stub wired to the canary.
* (G) **Crash triage + repro** path, **coverage reporting**, and **CI integration** (finite fuzz budget per PR). ([GitHub][3])

---

### 2) Workplan (Phases & Deliverables)

#### Phase I — Repository Recon & Mapping

1. **Codebase scan:**

   * Enumerate modules: parser/query language, on-disk formats/WAL, serializers, storage/indexing, graph algorithms (traversal, pathfinding), concurrency primitives, networking.
   * Identify **“canaries.”** Search for tokens like `canary`, `Canary`, `@canary`, special annotations/comments/macros, or naming patterns in tests and runtime checks.
   * Extract **explicit invariants** (e.g., “no orphan edges,” “IDs unique,” “edge endpoints must exist,” “no overflow on degree counters,” “acyclic constraint for X,” etc.).
   * Output: **Target Map** (YAML/JSON) listing targets, entry points, invariants, and file paths.

2. **Zig fuzz API confirmation (0.15.1):**

   * Verify usable API (prefer `std.testing.fuzz` within `test` blocks; validate with a trivial example and `zig build test --fuzz`).
   * Note web UI availability when `--fuzz`/`--webui` are passed and any port options. ([Zig Programming Language][1])

#### Phase II — Corpus Bootstrapping from Existing Tests

3. **Harvest corpora:**

   * Parse existing **unit/integration tests** and **fixtures** (JSON, binary snapshots, query files, sample graphs).
   * Serialize inputs used by positive/negative tests into **seed files** under `fuzz/corpora/<target>/`.
   * Build **dictionaries** for text grammars (tokens/keywords) where relevant (e.g., query language).
   * Deduplicate & minimize: keep smallest reproducer per behavior/crash; record provenance.

4. **Edge-case set (deterministic seeds):**

   * Include boundary values (empty/1‑byte/huge inputs), overlong identifiers, invalid UTF‑8, NaNs/±Inf, integer boundaries, deep nesting, circular refs, multi‑edges, self‑loops, extremely high‑degree nodes, disconnected components, very long paths, and near‑limit property payloads.

> Rationale: Structure‑aware seed corpora accelerate coverage‑guided fuzzing; Zig’s integrated fuzzer can be driven via `zig build test --fuzz` per Phase III. ([phoenixk.net][4])

#### Phase III — Fuzz Harness Design & Implementation

5. **Harness patterns (choose per target):**

   * **Byte‑oriented decoder/serializer harnesses:** Map `[]const u8` to deserializer and assert round‑trip oracles; add size limits to avoid pathological OOM.
   * **Text/grammar harnesses:** Feed query/DSL strings; verify parser never panics, and planner/executor preserves invariants on a sandbox graph; equip token dictionaries.
   * **Stateful API harnesses:** Interpret fuzz bytes as operation sequences (create/delete node/edge, set props, commit/rollback); assert graph invariants after each step.
   * **Storage/WAL harnesses:** Fuzz snapshot or log segments; open/close/recover cycle; confirm metadata checksums and index consistency.
   * **Concurrency/stress harnesses:** Randomized interleavings using worker threads where safe; also provide non‑coverage “stress” tests when coverage‑guided can’t orchestrate threads.
   * **Allocator failure harness:** Wrap with `std.testing.FailingAllocator` to fuzz allocation‑failure paths (exposes latent clean‑up bugs). ([ryanliptak.com][5])

6. **Canary-specific harnesses:**

   * For every canary test, **derive a harness** that: (i) reproduces the canary’s setup, (ii) exposes its pre/post conditions as oracles, (iii) fuzzes the minimal input surface that can violate the invariant.

7. **Safety rails & timeouts:**

   * Bound input sizes, loop iterations, recursion depth; reject dangerous sizes early.
   * Ensure reproducibility: save crashing inputs under `fuzz/crashes/<target>/…` and provide a `repro` test per crash.

#### Phase IV — Scaffold Generator (CLI) & Developer Experience

8. **`gen-fuzz` CLI:**

   * Command: `zig build gen-fuzz -- canary <name> [--module <path>] [--target <id>]`
   * Behavior: parse source to locate the canary, infer entry function/type surfaces, emit `fuzz/targets/<sanitized>_fuzz.zig` using a template (see code stub below), create `fuzz/corpora/<sanitized>/seed-000` with any existing example input, and register it in build.zig.
   * Add guardrails: if signature inference fails, generate TODOs with type hints and links to the symbol.

#### Phase V — Coverage, CI & Triage

9. **Coverage & gating:**

   * Use the fuzzer’s coverage info (and/or web UI) to monitor increasing “points of interest”; track **branch/edge coverage** delta per target; define **minimum corpus** sizes and **fuzz budgets** (e.g., iterations/time) for CI. ([Zig Programming Language][1])
   * CI job: `zig build test --fuzz=<time_or_iters>` (finite mode) for smoke coverage on PRs; nightly longer runs. ([GitHub][3])

10. **Crash triage:**

    * Auto‑minimize failures; deduplicate by backtrace/signature; file issues with repro test PRs; tag by target and invariant.

---

### 3) Output Artifacts (deliver all)

* **Fuzz Target Map** (JSON/YAML): targets → entry points, invariants, file paths.
* **`fuzz/` tree:**

  * `targets/*.zig` (harnesses), `corpora/<target>/*`, `dicts/<target>.dict`, `crashes/<target>/*`, `README.md` (runbook).
* **Scaffold generator:** `tools/gen_fuzz.zig` + build integration + usage docs.
* **CI config:** jobs that run finite fuzz (`--fuzz=<limit>`) and preserve crash artifacts.
* **Coverage report snapshot** & trend notes.
* **Changelist/PR(s)** with code and docs.

---

### 4) Engineering Details & Templates

#### 4.1 Minimal byte‑oriented harness (Zig 0.15.1)

```zig
const std = @import("std");

// Target under test (replace with actual module)
const storage = @import("geode/storage.zig");

fn fuzz_decode(_: void, input: []const u8) !void {
    // Guardrails
    if (input.len > 1 << 20) return; // 1 MiB cap
    // Example oracle: decode must not crash; if it succeeds, re-encode must round-trip
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const alloc = gpa.allocator();

    var s = storage.Snapshot.init(alloc);
    defer s.deinit();

    if (s.decode(input)) |ok| {
        const out = try s.encode(alloc);
        defer alloc.free(out);
        // Optional weak round-trip check
        // try std.testing.expect(std.mem.eql(u8, input, out));
        _ = ok;
    } else |_| {
        // Decoding errors are allowed; they just must not UB/panic.
    }
}

test "fuzz storage snapshot decode" {
    // Zig 0.15.1 fuzz API: confirm at build time; this form is seen in 0.15.
    try std.testing.fuzz({}, fuzz_decode, .{});
}
```

> **Note:** If `std.testing.fuzz` isn’t available under that name in your 0.15.1 toolchain, fall back to the pattern documented by the community (“mark a test as fuzz and run `zig build test --fuzz`”). Validate with a small sample before mass‑adoption. ([GitHub][6])

#### 4.2 Text/grammar harness (parser)

```zig
const std = @import("std");
const parser = @import("geode/query/parser.zig");

fn fuzz_query(_: void, bytes: []const u8) !void {
    if (bytes.len > 64 * 1024) return;
    // Ensure UTF-8 (or allow arbitrary bytes if parser accepts them)
    const src = bytes;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Parser must never panic; if AST builds, planner must uphold invariants
    const res = parser.parse(src, .{ .allocator = arena.allocator() });
    switch (res) {
        .ok => |ast| {
            // Lightweight planning/execution sandbox here
            try parser.quickSanity(ast);
        },
        .err => {}, // parse errors are fine; no UB
    }
}

test "fuzz query parser" {
    try std.testing.fuzz({}, fuzz_query, .{});
}
```

#### 4.3 Stateful API harness (operation sequences)

```zig
const std = @import("std");
const api = @import("geode/api.zig");
const op = @import("fuzz/lib/opseq.zig"); // helper: maps bytes -> ops

fn fuzz_ops(_: void, input: []const u8) !void {
    var g = try api.openEphemeral(.{}); // isolated in-mem DB
    defer g.close();

    var it = op.Iterator.init(input);
    var steps: usize = 0;
    while (it.next()) |action| : (steps += 1) {
        if (steps > 10_000) break;
        try action.apply(&g) catch {}; // errors allowed, but must leave DB consistent
        // Canary-like invariants enforced each step:
        try api.assertInvariants(&g);
    }
}

test "fuzz graph mutation sequences" {
    try std.testing.fuzz({}, fuzz_ops, .{});
}
```

#### 4.4 Allocation‑failure fuzz (find cleanup bugs)

```zig
const std = @import("std");
const lib = @import("geode/lib.zig");

fn fuzz_alloc_fail(_: void, bytes: []const u8) !void {
    var fa = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = bytes.len % 128 });
    const alloc = fa.allocator();
    _ = try lib.mutateWithAllocator(alloc, bytes);
}
test "fuzz allocation failure paths" {
    try std.testing.fuzz({}, fuzz_alloc_fail, .{});
}
```

*(Motivation for failing allocator fuzzing.)* ([ryanliptak.com][5])

---

### 5) Corpus & Dictionaries Layout

```
fuzz/
  targets/
    snapshot_decode_fuzz.zig
    query_parser_fuzz.zig
    opseq_fuzz.zig
    ...
  corpora/
    snapshot_decode/ seed-000 ...
    query_parser/ seed-*.qry
    opseq/ seed-*.bin
  dicts/
    query_parser.dict   # tokens/keywords/operators
  crashes/
    <target>/
  README.md
```

* **Seeds from tests:** Convert literals/fixtures from existing tests into files; compress large ones if needed; add a script to refresh corpora when tests change.
* **Minimization:** Keep smallest reproducer; retain provenance in filename or sidecar JSON.

---

### 6) Scaffold Generator (`gen-fuzz`)

**Goal:** Given a canary, generate a ready‑to‑fill fuzz harness + corpus folder.

**Interface:**

* `zig build gen-fuzz -- canary <name> [--module <path>] [--target <id>]`

**Implementation sketch:**

* Add a **custom build step** that runs a small Zig tool `tools/gen_fuzz.zig`.
* The tool locates the canary symbol via basic source parsing (or a simple symbol index if present), infers likely input surfaces, and writes `fuzz/targets/<sanitized>_fuzz.zig` with a `std.testing.fuzz` stub plus TODOs.
* It also creates `fuzz/corpora/<sanitized>/seed-000` from any example used in the canary test.

**Toy tool (`tools/gen_fuzz.zig`)**:

```zig
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const alloc = gpa.allocator();

    var args = std.process.args();
    _ = args.next(); // prog
    if (args.next()) |sub| {
        if (!std.mem.eql(u8, sub, "canary")) return error.InvalidUsage;
    } else return error.InvalidUsage;
    const name = args.next() orelse return error.InvalidUsage;

    const sanitized = try sanitize(alloc, name);
    const dir = try std.fs.cwd().makePath(try std.fmt.allocPrint(alloc, "fuzz/targets", .{}));
    _ = dir;

    const path = try std.fmt.allocPrint(alloc, "fuzz/targets/{s}_fuzz.zig", .{sanitized});
    var f = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
    defer f.close();

    try f.writer().print(
        \\const std = @import("std");
        \\const geode = @import("root"); // adjust if needed
        \\
        \\fn fuzz_{s}(_: void, input: []const u8) !void {
        \\    // TODO: map `input` to {s}’s input surface and assert canary invariants.
        \\}
        \\
        \\test "fuzz {s}" {{
        \\    try std.testing.fuzz({{}}, fuzz_{s}, .{{}});
        \\}}
        \\
        , .{ sanitized, sanitized, sanitized });

    // Create corpus dir + seed
    const corpdir = try std.fmt.allocPrint(alloc, "fuzz/corpora/{s}", .{sanitized});
    try std.fs.cwd().makePath(corpdir);
    var seed = try std.fs.cwd().createFile(try std.fmt.allocPrint(alloc, "{s}/seed-000", .{corpdir}), .{});
    seed.close();
}

fn sanitize(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf = try alloc.alloc(u8, s.len);
    var n: usize = 0;
    for (s) |c| {
        buf[n] = if (std.ascii.isAlNum(c)) c else '_';
        n += 1;
    }
    return buf[0..n];
}
```

**Build integration (conceptual):**

```zig
// build.zig (0.15.x uses root_module; adjust to your layout)
const std = @import("std");

pub fn build(b: *std.Build) void {
    // Normal targets/tests…

    const gen = b.addExecutable(.{
        .name = "gen_fuzz",
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/gen_fuzz.zig") }),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    b.installArtifact(gen);

    const gen_step = b.step("gen-fuzz", "Generate a fuzz target from a canary");
    const run_gen = b.addRunArtifact(gen);
    run_gen.addArgs(&.{ "canary" });
    // Forward args after `--`
    run_gen.stdio = .inherit;
    gen_step.dependOn(&run_gen.step);
}
```

> Adjust build API to your project’s structure per 0.15.x changes (notably `.root_module`). ([Zig Programming Language][1])

---

### 7) CI & Developer Runbook

* **Local:**

  * `zig build test --fuzz` (infinite mode); `zig build test --fuzz=<limit>` for finite runs if supported in your toolchain snapshot. ([GitHub][3])
  * Optional: `--webui` to view fuzzer coverage/time report in the browser. ([Zig Programming Language][1])
* **CI matrix:** Linux x86_64 (Debug and ReleaseSafe). Consider excluding Windows fuzz jobs if upstream support is incomplete. ([GitHub][2])
* **Artifacts:** Upload `fuzz/crashes/**`, minimized repro inputs, and coverage summaries.

---

### 8) Quality Gates & Measurement

* **Per‑target gates:** minimum seeds present; no regressions in total covered edges/branches; zero **new** unique crashes over baseline; crash repro tests added within 24h of discovery (policy knob).
* **Documentation:** each target README lists entry point, invariants, corpus strategy, and how to triage failures.

---

### 9) Risks & Mitigations

* **Fuzz instability on some platforms:** prefer Linux in CI; isolate web UI if flaky; track Zig issues linked in references. ([GitHub][7])
* **Stateful explosion:** cap sequence length; layer corpora by phase; add lightweight model checks to prune invalid states early.
* **False positives from allocation‑failure fuzz:** whitelist expected `error.OutOfMemory`; assert clean teardown instead of hard failure.

---

## References (confirm during implementation)

* **Zig 0.15.1 release notes** (web UI, `--fuzz` integration, build API changes — `root_module`): Zig Software Foundation. *Zig 0.15.1 Release Notes*. Accessed 2025‑09‑28. ([Zig Programming Language][1])
* **Example fuzz API usage (`std.testing.fuzz`)**: *Trivial fuzz testing fails…* (issue shows current usage pattern), GitHub ziglang/zig #24222. Accessed 2025‑09‑28. ([GitHub][6])
* **Fuzz CLI behavior (`zig build --fuzz` finite/infinite modes)**: GitHub ziglang/zig #20702 and #22900. Accessed 2025‑09‑28. ([GitHub][3])
* **Intro/blog on using Zig’s fuzzer & web server**: Phoenix K., *Using Zig’s fuzzer*. Accessed 2025‑09‑28. ([phoenixk.net][4])
* **Allocator failure fuzzing**: Ryan Liptak, *Improving Fuzz Testing with Zig Allocators*. Accessed 2025‑09‑28. ([ryanliptak.com][5])
* **Platform caveats (Windows support)**: GitHub ziglang/zig #20987. Accessed 2025‑09‑28. ([GitHub][2])

---

### Hand‑off Notes

* Start by generating the **Target Map** and a **list of detected canaries** with paths and inferred invariants; then iterate through Phase II–V.
* Keep all implementation choices reproducible in a `docs/fuzzing.md` with exact commands, limits, and known flakes.
* Prefer **small, reviewable PRs**: one per subsystem + a final PR to wire CI gates.

---

If you want, I can also tailor this to any specific modules/files you point me to in `geode` (e.g., parser/serializer paths) and pre‑fill the harness stubs with the right calls and invariants.

[1]: https://ziglang.org/download/0.15.1/release-notes.html "0.15.1 Release Notes ⚡ The Zig Programming Language"
[2]: https://github.com/ziglang/zig/issues/20987?utm_source=chatgpt.com "fuzz testing: support Windows · Issue #20987 · ziglang/zig"
[3]: https://github.com/ziglang/zig/issues/20702?utm_source=chatgpt.com "integrated fuzz testing · Issue #20702 · ziglang/zig"
[4]: https://phoenixk.net/zig-fuzz?utm_source=chatgpt.com "Using Zig's fuzzer / blog."
[5]: https://www.ryanliptak.com/blog/improving-fuzz-testing-with-zig-allocators/?utm_source=chatgpt.com "Improving Fuzz Testing with Zig Allocators"
[6]: https://github.com/ziglang/zig/issues/24222 "Trivial fuzz testing fails with Fuzz/WebServer.zig error · Issue #24222 · ziglang/zig · GitHub"
[7]: https://github.com/ziglang/zig/issues/25317?utm_source=chatgpt.com "zig fuzzer panic on basic zig init example · Issue #25317"
