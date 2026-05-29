# OTel Phase B — geode-emitted tracing (Increment 1: query.execute span + safe facade)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make geode emit its own OpenTelemetry spans — starting with a `geode.query.execute` SERVER span per query — through a thread-safe facade that is provably crash-free under concurrent QUIC load on the current otel pin (455ad2b8), and verify the spans land in the docker-compose collector.

**Architecture:** geode already has a working `TracerProvider` + OTLP/HTTP exporter (Phase A) but emits zero spans. The blocker was the otel BatchSpanProcessor: its concurrent-producer queue race is **fixed** in the current pin (0c34ce9), but (a) the `id_generator` is a shared non-thread-safe `std.Random.DefaultPrng`, and (b) a span-reuse UAF triggers on concurrent *double-end* of the same span. We add a small `GeodeSpan` facade that (1) serializes span creation behind a facade mutex `g_span_mu` (same pattern as the existing metrics guard `g_query_mu`), and (2) enforces **exactly-once `end()`** via a per-span atomic so the double-end UAF can never fire from geode. Spans are thread-confined (created and ended on one request thread). We re-add the `geode.query.execute` span (rolled back earlier on a stale pin assumption) using this facade.

**Tech Stack:** Zig 0.16, otel `0.1.5` @ 455ad2b8, the Phase A docker-compose collector for verification.

---

## File Structure
- Modify: `src/monitoring/otel_metrics.zig` — add the `GeodeSpan` facade type, `g_span_mu`, and `startQuerySpan(...)`/helpers next to the existing `tracer()` (line ~499).
- Modify: `src/execution.zig:1064` `executeStatementWithContext` — re-add the `geode.query.execute` span via the facade, with op-name classification; update the stale rollback comment (lines 1074-1082).
- Create: `tests/test_otel_span_facade.zig` — unit test: a `geode.query.execute` span is recorded with correct name/attributes via an in-memory recorder; exactly-once `end()` invariant.
- Create: `tests/test_otel_span_concurrency.zig` — stress: N threads each start+end a query span through the real BSP + recorder; assert no crash and each span recorded exactly once (guards the id-gen race + UAF on the current pin).
- Modify: `build.zig` — wire the two new test files as `test-otel-span-facade` and `test-otel-span-concurrency` steps (mirror the existing `test-otel-otlp-transport` wiring).

---

### Task 1: GeodeSpan facade (thread-safe, exactly-once end)

**Files:** Modify `src/monitoring/otel_metrics.zig`

- [ ] **Step 1: Write the failing facade test**

Create `tests/test_otel_span_facade.zig`:
```zig
const std = @import("std");
const otel_metrics = @import("otel_metrics");
const otel = @import("otel");

// CANARY: REQ=REQ-OTEL-TRACE-001; FEATURE="Geode Emitted Spans"; ASPECT=QueryExecuteSpan; STATUS=TESTED; TEST=tests/test_otel_span_facade.zig; OWNER=monitoring; UPDATED=2026-05-29
test "geode.query.execute span is recorded with attributes via the facade" {
    const alloc = std.testing.allocator;
    var recorder = otel_metrics.InMemoryRecorder.init(alloc);
    defer recorder.deinit();
    try otel_metrics.initForTracingTest(alloc, &recorder);
    defer otel_metrics.shutdown();

    var span = otel_metrics.startQuerySpan("MATCH", "social", false);
    span.setIntAttr("geode.result.row_count", 7);
    span.end(); // exactly-once
    span.end(); // second end must be a no-op (idempotent)

    try otel_metrics.forceFlushTraces(1_000);
    try std.testing.expectEqual(@as(usize, 1), recorder.spans.items.len);
    const s = recorder.spans.items[0];
    try std.testing.expectEqualStrings("geode.query.execute", s.name);
}
```

- [ ] **Step 2: Run it — confirm it FAILS** (no `startQuerySpan`/`GeodeSpan`/`setIntAttr`)

Run: `zig build test-otel-span-facade` (after Step 4 wires it). Expected: compile error (undefined `startQuerySpan`). That is a valid RED for a new API once the build step exists; wire Step 4 first if needed to get a compile-fail.

- [ ] **Step 3: Implement the facade in `src/monitoring/otel_metrics.zig`**

Add near the `tracer()` function (~line 514). Use the existing `Tracer`/`Span`/`SpanKind` aliases and `attrs.Entry`:
```zig
/// Serializes span CREATION (id generation) — the otel id_generator is a
/// shared std.Random.DefaultPrng that is not safe for concurrent nextTraceId/
/// nextSpanId from multiple QUIC query threads. Same discipline as g_query_mu
/// for the metric SDK. Held only across startSpan (nanoseconds).
var g_span_mu: std.Io.Mutex = std.Io.Mutex.init;

/// Thread-confined span wrapper that guarantees otel `Span.end()` is invoked
/// EXACTLY ONCE, even if geode code double-ends (defer + explicit) or a future
/// refactor shares the span. This closes the otel BSP span-reuse UAF at the
/// geode boundary (the UAF needs a concurrent double-end of the same span).
pub const GeodeSpan = struct {
    span: otel.api.trace.Span,
    ended: std.atomic.Value(bool) = .init(false),

    pub fn end(self: *GeodeSpan) void {
        if (self.ended.swap(true, .acq_rel)) return;
        self.span.end(null);
    }
    pub fn setIntAttr(self: *GeodeSpan, key: []const u8, value: i64) void {
        self.span.setIntAttribute(key, value) catch {};
    }
    pub fn setStrAttr(self: *GeodeSpan, key: []const u8, value: []const u8) void {
        self.span.setStringAttribute(key, value) catch {};
    }
    pub fn setError(self: *GeodeSpan, err: anyerror) void {
        self.span.setStatus(.error_, @errorName(err));
        self.span.setStringAttribute("error.type", @errorName(err)) catch {};
    }
    pub fn setOk(self: *GeodeSpan) void {
        self.span.setStatus(.ok, "");
    }
};

/// Start a `geode.query.execute` SERVER span (new trace; cross-process
/// propagation is a later phase). `op_name` must be a BOUNDED enum-like string
/// (MATCH/CREATE/...). `namespace` is the current graph name (bounded). Never
/// pass raw query text or user values (unbounded cardinality).
pub fn startQuerySpan(op_name: []const u8, namespace: []const u8, is_mutation: bool) GeodeSpan {
    const t = tracer(); // noop tracer if OTEL_TRACES_EXPORTER unset -> zero cost
    g_span_mu.lockUncancelable(initIo());
    defer g_span_mu.unlock(initIo());
    const attrs_buf = [_]otel.internal.attributes.Entry{
        .{ .key = "db.system.name", .value = .{ .string = "codepros.geode" } },
        .{ .key = "db.operation.name", .value = .{ .string = op_name } },
        .{ .key = "db.namespace", .value = .{ .string = namespace } },
        .{ .key = "geode.query.is_mutation", .value = .{ .bool = is_mutation } },
    };
    const span = t.startSpan(.empty(), "geode.query.execute", .{
        .kind = .server,
        .initial_attributes = &attrs_buf,
    }) catch return .{ .span = otel.api.trace.Span.noop };
    return .{ .span = span };
}
```
(Verify the exact import paths: `otel.api.trace.Span`, `otel.internal.attributes.Entry`, `.empty()` on Context, and `Span.noop`. Adjust to the aliases already in the file — `Tracer`, `Span` are aliased near line 40-72; reuse them. `initIo()` exists at line 84.)

- [ ] **Step 4: Wire the test step in `build.zig`**

Mirror the `test-otel-otlp-transport` step: add a `test-otel-span-facade` step compiling `tests/test_otel_span_facade.zig` with imports `otel_metrics` (and `otel`), deriving from the same `otel_mod`. Find the existing `test-otel-otlp-transport` block and copy its shape.

- [ ] **Step 5: Run — confirm PASS**

Run: `zig build test-otel-span-facade`. Expected: PASS, exactly one span named `geode.query.execute`.

- [ ] **Step 6: Commit**
```bash
git add src/monitoring/otel_metrics.zig tests/test_otel_span_facade.zig build.zig docs/status.csv
git commit -m "feat(otel): add thread-safe GeodeSpan facade (exactly-once end, guarded id-gen)"
```

---

### Task 2: Concurrency stress test (no crash, exactly-once under load)

**Files:** Create `tests/test_otel_span_concurrency.zig`; Modify `build.zig`

- [ ] **Step 1: Write the stress test**

Create `tests/test_otel_span_concurrency.zig`:
```zig
const std = @import("std");
const otel_metrics = @import("otel_metrics");

// CANARY: REQ=REQ-OTEL-TRACE-002; FEATURE="Geode Emitted Spans"; ASPECT=ConcurrencySafety; STATUS=TESTED; TEST=tests/test_otel_span_concurrency.zig; OWNER=monitoring; UPDATED=2026-05-29
test "concurrent query spans: no crash, each recorded exactly once" {
    const alloc = std.testing.allocator;
    var recorder = otel_metrics.InMemoryRecorder.init(alloc);
    defer recorder.deinit();
    try otel_metrics.initForTracingTest(alloc, &recorder);
    defer otel_metrics.shutdown();

    const N = 8;
    const PER = 500;
    const Worker = struct {
        fn run() void {
            var i: usize = 0;
            while (i < PER) : (i += 1) {
                var s = otel_metrics.startQuerySpan("MATCH", "g", false);
                s.setIntAttr("geode.result.row_count", @intCast(i));
                s.end();
            }
        }
    };
    var threads: [N]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{});
    for (&threads) |t| t.join();

    try otel_metrics.forceFlushTraces(5_000);
    try std.testing.expectEqual(@as(usize, N * PER), recorder.spans.items.len);
}
```
(If `initForTracingTest`'s recorder is not safe for concurrent record from the SimpleSpanProcessor path, switch the test to the real BatchSpanProcessor wiring used in production, or guard the recorder — but do NOT weaken the exactly-once count assertion. The point is to prove the production startQuerySpan/end path is crash-free and exactly-once under N threads.)

- [ ] **Step 2: Wire `test-otel-span-concurrency` in build.zig** (mirror Task 1 Step 4).

- [ ] **Step 3: Run — confirm PASS (and under TSan if available)**

Run: `zig build test-otel-span-concurrency`. Expected: PASS, `N*PER` spans, no crash/panic. If a panic/UAF occurs, STOP — the current pin is unsafe for this path and the otel pin bump (9fa2e97) + ecosystem convergence becomes necessary; report it.

- [ ] **Step 4: Commit**
```bash
git add tests/test_otel_span_concurrency.zig build.zig docs/status.csv
git commit -m "test(otel): concurrency stress for GeodeSpan (no crash, exactly-once under 8 threads)"
```

---

### Task 3: Re-add the `geode.query.execute` span in execution.zig

**Files:** Modify `src/execution.zig` (executeStatementWithContext, ~1064-1087)

- [ ] **Step 1: Replace the stale rollback comment + add the span**

In `executeStatementWithContext` (execution.zig:1064), derive a bounded op-name from the statement and bracket execution with the facade span. Replace the rollback comment block (1074-1082) with:
```zig
    // geode.query.execute span — re-enabled on the current pin. The
    // concurrent-producer race (otel 0c34ce9) is fixed in 455ad2b8; the
    // span-reuse UAF is closed at the geode boundary by GeodeSpan's
    // exactly-once end() + g_span_mu-guarded creation. Thread-confined:
    // created and ended on this request's worker thread.
    const op_name: []const u8 = switch (stmt) {
        .Query => "MATCH",
        .Create => "CREATE",
        .Insert => "INSERT",
        .Delete => "DELETE",
        .Set => "SET",
        .Merge => "MERGE",
        .Call => "CALL",
        else => @tagName(stmt),
    };
    const ns: []const u8 = if (context.session_state) |ss| ss.graph else "";
    var qspan = om.startQuerySpan(op_name, ns, !(@as(om.QueryType, qt) == .read));
    defer qspan.end();
```
(VERIFY the exact `ast.Statement` union tag names by reading the type; use the real tags. `context.session_state.graph` access must match the real field path — adjust if the graph name lives elsewhere on ExecutionContext.)

- [ ] **Step 2: Set outcome/error on the span at the existing defer**

Augment the existing outcome `defer` (1084-1087) so the span carries the result. Add after the metric record:
```zig
    defer {
        const dur_s = @as(f64, @floatFromInt(otel_lib.internal.clock.unixNanoNow() - t0_exec)) / 1_000_000_000.0;
        om.recordQueryExecution(op_name, op_name, qt, dur_s, exec_outcome, null);
        if (exec_outcome == .error_) qspan.setError(error.QueryFailed) else qspan.setOk();
    }
```
(Order: ensure `qspan`'s `defer end()` runs AFTER this outcome defer — in Zig, defers run LIFO, so declare `qspan`'s `defer end()` BEFORE this outcome block so end() runs last. Re-check ordering when implementing; the span must be ended after attributes are set.)

- [ ] **Step 3: Build + run existing + new tests**

Run: `zig build -Doptimize=ReleaseSafe` then `zig build test-otel-span-facade test-otel-span-concurrency` and the existing `zig build test-bsp-race-regression` (if it is a wired step; otherwise the relevant execution test). Expected: all PASS.

- [ ] **Step 4: Commit**
```bash
git add src/execution.zig
git commit -m "feat(otel): emit geode.query.execute span via the safe facade (re-enabled)"
```

---

### Task 4: End-to-end verification in the docker-compose collector

- [ ] **Step 1: Verify spans land (REQUIRE_SPANS=1)**

Run: `REQUIRE_SPANS=1 scripts/otel-compose-verify.sh`
Expected: `PASS: geode metrics reached the collector (spans required=1, seen>=1)` and the summary's `span-indicator lines` is > 0 (a `geode.query.execute` span with scope `com.geodedb.geode` appears in the collector).

- [ ] **Step 2: Concurrent-load smoke (no crash)**

Bring the stack up, then drive concurrent queries against the container geode for ~30s and confirm geode does not crash (no SIGABRT) and spans keep arriving. Run a small loop of `docker compose -f docker-compose.otel.yml exec -T geode geode query ...` across a few background shells, or reuse the harness. Confirm `docker inspect -f '{{.State.Status}}' geode-otel` stays `running`.

- [ ] **Step 3: Update the baseline doc**

Append to `docs/otel-compose-baseline-2026-05-29.md` a "Phase B update" noting spans now land (with the span name + a sample) and the concurrent-load result.

- [ ] **Step 4: Commit**
```bash
git add docs/otel-compose-baseline-2026-05-29.md
git commit -m "docs(otel): Phase B — geode.query.execute spans land in the collector"
```

---

## Self-Review checklist
- Facade serializes id-gen (g_span_mu) ✔ Task 1; exactly-once end (atomic) ✔ Task 1; concurrency proven ✔ Task 2; execute span wired ✔ Task 3; spans land in collector ✔ Task 4.
- Cardinality: only bounded attributes (op_name enum, namespace, is_mutation, row_count, error.type); NO raw query text / params.
- Safety: if Task 2 or Task 4 Step 2 crashes, the current pin is unsafe → escalate (otel pin bump + convergence needed). Expected: safe (producer race fixed; double-end prevented by facade).

## Follow-up (Phase B Increment 2 — separate plan)
Child spans parented to `geode.query.execute`: `geode.query.parse` (lib.zig), storage/wal spans, plan span. Thread the parent SpanContext via ExecutionContext or the existing threadlocal `g_active_context`. Cross-process propagation (client traceparent) — needs an `ExecuteRequest.trace_context` wire field; deferred.
