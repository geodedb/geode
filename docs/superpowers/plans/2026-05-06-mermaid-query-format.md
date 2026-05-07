# Mermaid Query Format Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--format mermaid` support to the `geode query` command so it emits valid [Mermaid flowchart](https://mermaid.js.org/syntax/flowchart.html) syntax for graph results, end-to-end verified against the official `@mermaid-js/mermaid-cli` (`mmdc`) renderer.

**Architecture:** Mirror the existing DOT/Graphviz format pipeline in `src/client/query_result_accumulator.zig`: extend the `TextMode` enum and `ResultAccumulator` struct to track `wants_mermaid`, dispatch to a new `outputMermaidFormatFromRows` renderer in `render()`, share JSON-row scanning with the DOT path, and emit `flowchart LR` with `n<id>["label"]` nodes and `from -->|"type"| to` edges. Validation happens at three layers — Zig unit tests (golden output strings via `*std.Io.Writer`), `geodetestlab-cli` integration spec (CLI surface and `stdout_contains` assertions), and an external shell harness that pipes real query output into `mmdc` so an actual Mermaid parser approves it.

**Tech Stack:** Zig 0.16+, `std.Io.Writer` / `std.Io.File`, JSON value parsing via `std.json`, `geodetestlab-cli` YAML specs, bash + `npx @mermaid-js/mermaid-cli`.

---

## File Structure

**Modified files:**

- `src/client/query_result_accumulator.zig` — central change. Add `wants_mermaid` field, `mermaid` enum variant, init detection, render dispatch, and the new public `outputMermaidFormatFromRows` renderer with file-private helpers (`getMermaidNodeLabel`, `escapeMermaidLabel`).
- `src/cli/main.zig` — extend the `geode query --help` text on line 261 (format list) and line ~320 (examples) to mention `mermaid` and show an `mmdc` pipeline example.
- `build.zig` — wire a new `b.addTest` for the unit-test file and add it to the `test` step.
- `Makefile` — add a `test-mermaid-integration` target that invokes the external shell script.

**New files:**

- `tests/test_query_result_mermaid.zig` — Zig unit tests, golden-output style. Mirrors the structure of `tests/test_cli_transport_response_parity.zig` but drives `geode.query_result_accumulator.outputMermaidFormatFromRows` via `std.Io.Writer.fixed`.
- `geode-test-harness/geodetestlab-cli/specs/query_output_format_mermaid.yml` — `geodetestlab-cli` spec covering help text, single-node, single-edge, deduplication, and integration scenarios. New file so it stays decoupled from the existing `query_output_formats.yml` (which tests dot/json/csv/table).
- `tests/integration/test_mermaid_external.sh` — bash harness: starts a private geode instance on a high port (per memory: `feedback_validation_strategy.md`), runs queries with `--format mermaid`, pipes each output through `npx @mermaid-js/mermaid-cli`, and asserts a non-empty SVG comes back.
- `tests/integration/mermaid-puppeteer-config.json` — puppeteer config so chromium runs headless without sandboxing (needed under root or container CI).
- `tests/integration/README_mermaid.md` — short doc explaining how to run the external harness.

---

## Mermaid Output Format Specification

The renderer must emit exactly this structure (compare to the equivalent DOT in `src/client/query_result_accumulator.zig:573`):

```
flowchart LR
  n123["Person<br/>Alice"]
  n456["Person<br/>Bob"]
  n123 -->|"KNOWS"| n456
```

Rules:
- Header line: `flowchart LR\n` (matches DOT's `rankdir=LR`).
- Indentation: 2 spaces (matches DOT).
- Node ID: `n` + raw integer/string ID (mermaid IDs cannot start with a digit, so the `n` prefix is required).
- Node label: `["..."]` quoted square brackets. Multi-part labels join with `<br/>` (mermaid's HTML-style break, equivalent to DOT's `\n`).
- Edge: `from -->|"label"| to`. Quoted edge label is mermaid-safe when the label contains spaces or special characters.
- Special characters inside any quoted label string are escaped via HTML entities: `&` → `&amp;` (must run first), `"` → `&quot;`, `<` → `&lt;`, `>` → `&gt;`. The `<br/>` separator we insert between label parts is preserved as a literal sequence; user content is escaped before the separator is added.
- Node deduplication mirrors DOT: track seen IDs in a `std.StringHashMap(void)` so the same node mentioned in many rows only renders once.
- Empty graph: header line only, no body, no trailing close (mermaid has no closing brace).

Trailing newline after the last line is required so consumers see a clean EOF.

---

## Task 1: Wire mermaid into TextMode, init, and render dispatch (TDD: header-only golden)

**Files:**
- Create: `tests/test_query_result_mermaid.zig`
- Modify: `src/client/query_result_accumulator.zig:11` (TextMode enum), `:19-63` (struct + init), `:137-154` (render), `:235` (appendPageText mode), `:336-338` (valueToText mode check)
- Modify: `build.zig` near line 1377 (wire test target) and line 1816 (add to `test` step)

- [ ] **Step 1: Create the failing unit test for the empty-graph header**

Create `tests/test_query_result_mermaid.zig`:

```zig
const std = @import("std");
const geode = @import("geode");
const query_results = geode.query_result_accumulator;

fn renderMermaidToSlice(
    allocator: std.mem.Allocator,
    rows: []const std.ArrayList([]const u8),
) ![]u8 {
    var out_buf: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out_buf);
    try query_results.outputMermaidFormatFromRows(allocator, rows, &writer);
    return try allocator.dupe(u8, writer.buffered());
}

test "mermaid format: empty rows emit only flowchart header" {
    const allocator = std.testing.allocator;

    const rows: []const std.ArrayList([]const u8) = &.{};

    const rendered = try renderMermaidToSlice(allocator, rows);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("flowchart LR\n", rendered);
}
```

- [ ] **Step 2: Wire the test target into build.zig**

In `build.zig`, locate the `cli_transport_parity_tests` block at lines 1366-1377. Immediately after `cli_transport_parity_step.dependOn(&run_cli_transport_parity_tests.step);`, insert:

```zig
    // Mermaid query format unit tests (companion to dot format)
    const mermaid_format_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_query_result_mermaid.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    mermaid_format_tests.root_module.addImport("geode", root_mod);
    const run_mermaid_format_tests = b.addRunArtifact(mermaid_format_tests);
    const mermaid_format_step = b.step("test-mermaid-format", "Run mermaid query format unit tests");
    mermaid_format_step.dependOn(&run_mermaid_format_tests.step);
```

Then locate line 1816 `test_step.dependOn(&run_cli_transport_parity_tests.step);` and add immediately after it:

```zig
    test_step.dependOn(&run_mermaid_format_tests.step);
```

- [ ] **Step 3: Run the test, verify it fails to compile**

Run: `zig build test-mermaid-format`
Expected: FAIL with a compile error like `error: no member named 'outputMermaidFormatFromRows' in struct 'query_result_accumulator'` — the symbol does not exist yet.

- [ ] **Step 4: Add `mermaid` to TextMode enum**

In `src/client/query_result_accumulator.zig:11`, change:

```zig
const TextMode = enum { display, dot };
```

to:

```zig
const TextMode = enum { display, dot, mermaid };
```

- [ ] **Step 5: Add `wants_mermaid` field and init detection**

In `src/client/query_result_accumulator.zig:23` (after `wants_dot: bool,`), add:

```zig
    wants_mermaid: bool,
```

In `src/client/query_result_accumulator.zig:43-50` (the `init` function header), change:

```zig
    pub fn init(allocator: std.mem.Allocator, format: []const u8) !ResultAccumulator {
        const wants_json = std.mem.eql(u8, format, "json");
        const wants_dot = std.mem.eql(u8, format, "dot");
        var result = ResultAccumulator{
            .allocator = allocator,
            .format = try allocator.dupe(u8, format),
            .wants_json = wants_json,
            .wants_dot = wants_dot,
            .columns = try std.ArrayList(ColumnInfo).initCapacity(allocator, 16),
```

to:

```zig
    pub fn init(allocator: std.mem.Allocator, format: []const u8) !ResultAccumulator {
        const wants_json = std.mem.eql(u8, format, "json");
        const wants_dot = std.mem.eql(u8, format, "dot");
        const wants_mermaid = std.mem.eql(u8, format, "mermaid");
        var result = ResultAccumulator{
            .allocator = allocator,
            .format = try allocator.dupe(u8, format),
            .wants_json = wants_json,
            .wants_dot = wants_dot,
            .wants_mermaid = wants_mermaid,
            .columns = try std.ArrayList(ColumnInfo).initCapacity(allocator, 16),
```

The `if (wants_json) { ... } else { rows_text = ... }` block at lines 57-61 stays as-is — mermaid uses text rows like dot does.

- [ ] **Step 6: Update `render()` to dispatch to mermaid output**

In `src/client/query_result_accumulator.zig:137-154`, change:

```zig
    pub fn render(self: *ResultAccumulator, stdout: anytype, stderr: anytype) !bool {
        if (self.wants_dot) {
            if (self.rows_text) |rows| {
                try outputDotFormatFromRows(self.allocator, rows.items, stdout);
            }
            return self.indicatesFailure();
        }

        return transport_response.renderTransportResponseWithStreams(
            self.allocator,
            stdout,
            stderr,
            self.format,
            if (self.rows_text) |*rows| rows else null,
            if (self.rows_json) |*rows| rows else null,
            self.view(),
        );
    }
```

to:

```zig
    pub fn render(self: *ResultAccumulator, stdout: anytype, stderr: anytype) !bool {
        if (self.wants_dot) {
            if (self.rows_text) |rows| {
                try outputDotFormatFromRows(self.allocator, rows.items, stdout);
            }
            return self.indicatesFailure();
        }

        if (self.wants_mermaid) {
            if (self.rows_text) |rows| {
                try outputMermaidFormatFromRows(self.allocator, rows.items, stdout);
            }
            return self.indicatesFailure();
        }

        return transport_response.renderTransportResponseWithStreams(
            self.allocator,
            stdout,
            stderr,
            self.format,
            if (self.rows_text) |*rows| rows else null,
            if (self.rows_json) |*rows| rows else null,
            self.view(),
        );
    }
```

- [ ] **Step 7: Update `appendPageText` mode selection**

In `src/client/query_result_accumulator.zig:235`, change:

```zig
                } else if (self.rows_text) |*rows| {
                    try appendPageText(self.allocator, page, rows, if (self.wants_dot) .dot else .display);
                }
```

to:

```zig
                } else if (self.rows_text) |*rows| {
                    const mode: TextMode = if (self.wants_dot)
                        .dot
                    else if (self.wants_mermaid)
                        .mermaid
                    else
                        .display;
                    try appendPageText(self.allocator, page, rows, mode);
                }
```

- [ ] **Step 8: Update `valueToText` to treat mermaid like dot**

In `src/client/query_result_accumulator.zig:336-338`, change:

```zig
            else => blk: {
                if (mode == .dot) {
                    break :blk try valueToJsonString(allocator, value);
                }
```

to:

```zig
            else => blk: {
                if (mode == .dot or mode == .mermaid) {
                    break :blk try valueToJsonString(allocator, value);
                }
```

- [ ] **Step 9: Add the minimal `outputMermaidFormatFromRows` body that satisfies the empty-rows test**

At the end of `src/client/query_result_accumulator.zig` (after the existing `outputDotFormatFromRows` function ends near line 631), append:

```zig
pub fn outputMermaidFormatFromRows(
    allocator: std.mem.Allocator,
    rows: []const std.ArrayList([]const u8),
    stdout: anytype,
) !void {
    _ = allocator;
    _ = rows;
    const io = std.Io.Threaded.global_single_threaded.io();
    var out = if (@TypeOf(stdout) == std.Io.File) transport_response.Stream.init(stdout, io) else stdout;
    try out.writeAll("flowchart LR\n");
}
```

- [ ] **Step 10: Run unit test and verify empty-rows golden passes**

Run: `zig build test-mermaid-format`
Expected: PASS — single test "mermaid format: empty rows emit only flowchart header" passes.

- [ ] **Step 11: Commit**

```bash
git add src/client/query_result_accumulator.zig tests/test_query_result_mermaid.zig build.zig
git commit -m "feat(cli): scaffold --format mermaid with empty-graph header

Adds wants_mermaid field, mermaid TextMode variant, render-dispatch, and
outputMermaidFormatFromRows stub that emits the 'flowchart LR' header.
Wires tests/test_query_result_mermaid.zig into the test step.

Empty-rows golden test passes; node and edge rendering follow."
```

---

## Task 2: Render single nodes (TDD: node golden)

**Files:**
- Modify: `tests/test_query_result_mermaid.zig` (add new tests)
- Modify: `src/client/query_result_accumulator.zig` (extend `outputMermaidFormatFromRows` and add helpers)

- [ ] **Step 1: Write failing tests for single-node rendering**

Append to `tests/test_query_result_mermaid.zig`:

```zig
fn rowFromCells(allocator: std.mem.Allocator, cells: []const []const u8) !std.ArrayList([]const u8) {
    var row = try std.ArrayList([]const u8).initCapacity(allocator, cells.len);
    errdefer {
        for (row.items) |c| allocator.free(c);
        row.deinit(allocator);
    }
    for (cells) |c| try row.append(allocator, try allocator.dupe(u8, c));
    return row;
}

fn deinitRows(allocator: std.mem.Allocator, rows: *std.ArrayList(std.ArrayList([]const u8))) void {
    for (rows.items) |*row| {
        for (row.items) |cell| allocator.free(cell);
        row.deinit(allocator);
    }
    rows.deinit(allocator);
}

test "mermaid format: single node with labels and name property" {
    const allocator = std.testing.allocator;

    var rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 1);
    defer deinitRows(allocator, &rows);

    const node_json =
        \\{"id":123,"labels":["Person"],"properties":{"name":"Alice"}}
    ;
    try rows.append(allocator, try rowFromCells(allocator, &.{node_json}));

    const rendered = try renderMermaidToSlice(allocator, rows.items);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "flowchart LR\n  n123[\"Person<br/>Alice\"]\n",
        rendered,
    );
}

test "mermaid format: single node falls back to id when no labels match" {
    const allocator = std.testing.allocator;

    var rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 1);
    defer deinitRows(allocator, &rows);

    const node_json =
        \\{"id":7,"labels":[],"properties":{}}
    ;
    try rows.append(allocator, try rowFromCells(allocator, &.{node_json}));

    const rendered = try renderMermaidToSlice(allocator, rows.items);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "flowchart LR\n  n7[\"7\"]\n",
        rendered,
    );
}

test "mermaid format: multi-label node joins labels with colon" {
    const allocator = std.testing.allocator;

    var rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 1);
    defer deinitRows(allocator, &rows);

    const node_json =
        \\{"id":42,"labels":["User","Admin"],"properties":{"username":"root"}}
    ;
    try rows.append(allocator, try rowFromCells(allocator, &.{node_json}));

    const rendered = try renderMermaidToSlice(allocator, rows.items);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "flowchart LR\n  n42[\"User:Admin<br/>root\"]\n",
        rendered,
    );
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `zig build test-mermaid-format`
Expected: FAIL on the new tests with assertion mismatches showing only `flowchart LR\n` was produced (because the renderer body is currently a stub).

- [ ] **Step 3: Implement the node rendering and helpers**

In `src/client/query_result_accumulator.zig`, replace the stub `outputMermaidFormatFromRows` body added in Task 1 with the full version:

```zig
pub fn outputMermaidFormatFromRows(
    allocator: std.mem.Allocator,
    rows: []const std.ArrayList([]const u8),
    stdout: anytype,
) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var out = if (@TypeOf(stdout) == std.Io.File) transport_response.Stream.init(stdout, io) else stdout;

    try out.writeAll("flowchart LR\n");

    var seen_nodes = std.StringHashMap(void).init(allocator);
    defer {
        var iter = seen_nodes.keyIterator();
        while (iter.next()) |key| allocator.free(key.*);
        seen_nodes.deinit();
    }

    for (rows) |row| {
        for (row.items) |cell| {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, cell, .{}) catch continue;
            defer parsed.deinit();

            if (parsed.value != .object) continue;
            const obj = parsed.value.object;

            if (obj.get("labels")) |labels_val| {
                const node_id = getDotNodeId(allocator, obj) orelse continue;
                defer allocator.free(node_id);

                if (!seen_nodes.contains(node_id)) {
                    try seen_nodes.put(try allocator.dupe(u8, node_id), {});

                    const label = getMermaidNodeLabel(allocator, obj, labels_val) catch try allocator.dupe(u8, node_id);
                    defer allocator.free(label);

                    try out.writeAll("  n");
                    try out.writeAll(node_id);
                    try out.writeAll("[\"");
                    try out.writeAll(label);
                    try out.writeAll("\"]\n");
                }
            }
        }
    }
}

fn getMermaidNodeLabel(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    labels_val: std.json.Value,
) ![]const u8 {
    var raw = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer raw.deinit(allocator);

    if (labels_val == .array) {
        for (labels_val.array.items, 0..) |label, idx| {
            if (idx > 0) try raw.append(allocator, ':');
            if (label == .string) try raw.appendSlice(allocator, label.string);
        }
    }

    const display_props = [_][]const u8{ "name", "title", "label", "username", "email" };
    if (obj.get("properties")) |props_val| {
        if (props_val == .object) {
            for (display_props) |prop| {
                if (props_val.object.get(prop)) |val| {
                    if (val == .string and val.string.len > 0) {
                        try raw.appendSlice(allocator, "<br/>");
                        try raw.appendSlice(allocator, val.string);
                        break;
                    }
                }
            }
        }
    }

    if (raw.items.len == 0) {
        if (getDotNodeId(allocator, obj)) |id| {
            defer allocator.free(id);
            return try escapeMermaidLabel(allocator, id);
        }
        return try allocator.dupe(u8, "node");
    }

    return try escapeMermaidLabel(allocator, raw.items);
}

fn escapeMermaidLabel(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, raw.len);
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        switch (c) {
            '<' => {
                if (i + 4 < raw.len and std.mem.eql(u8, raw[i .. i + 5], "<br/>")) {
                    try out.appendSlice(allocator, "<br/>");
                    i += 4;
                } else {
                    try out.appendSlice(allocator, "&lt;");
                }
            },
            '&' => try out.appendSlice(allocator, "&amp;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            else => try out.append(allocator, c),
        }
    }

    return try out.toOwnedSlice(allocator);
}
```

Notes:
- `getDotNodeId` already exists at `src/client/query_result_accumulator.zig:527` — reused as-is (returns the raw integer/string ID without the `n` prefix; the renderer adds the prefix).
- `escapeMermaidLabel` preserves the `<br/>` separator we just inserted by treating it as a literal sequence; everything else gets HTML-entity escaped. The `<br/>` recognition guard runs *before* the `<` escape so we don't break our own separators. We escape raw `&` characters (which only come from user content here, since the renderer never emits its own `&`), so this is safe.

- [ ] **Step 4: Run tests, verify all node tests pass**

Run: `zig build test-mermaid-format`
Expected: PASS — three new node tests + the empty-graph test all pass.

- [ ] **Step 5: Commit**

```bash
git add src/client/query_result_accumulator.zig tests/test_query_result_mermaid.zig
git commit -m "feat(cli): mermaid format renders nodes with labels and properties

Implements outputMermaidFormatFromRows full body, plus
getMermaidNodeLabel and escapeMermaidLabel helpers. Reuses the existing
getDotNodeId for ID extraction. Nodes with empty labels fall back to
their id; multi-label nodes join with colons; first matching display
property (name/title/label/username/email) is appended after a
<br/> separator."
```

---

## Task 3: Render edges with relationship type labels (TDD: edge golden)

**Files:**
- Modify: `tests/test_query_result_mermaid.zig` (add edge tests)
- Modify: `src/client/query_result_accumulator.zig` (extend `outputMermaidFormatFromRows` to handle edges)

- [ ] **Step 1: Write failing tests for edge rendering**

Append to `tests/test_query_result_mermaid.zig`:

```zig
test "mermaid format: edge between two nodes uses relationship label" {
    const allocator = std.testing.allocator;

    var rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 1);
    defer deinitRows(allocator, &rows);

    const a_json =
        \\{"id":1,"labels":["Person"],"properties":{"name":"Alice"}}
    ;
    const r_json =
        \\{"id":99,"from":1,"to":2,"label":"KNOWS","properties":{}}
    ;
    const b_json =
        \\{"id":2,"labels":["Person"],"properties":{"name":"Bob"}}
    ;
    try rows.append(allocator, try rowFromCells(allocator, &.{ a_json, r_json, b_json }));

    const rendered = try renderMermaidToSlice(allocator, rows.items);
    defer allocator.free(rendered);

    const expected =
        "flowchart LR\n" ++
        "  n1[\"Person<br/>Alice\"]\n" ++
        "  n2[\"Person<br/>Bob\"]\n" ++
        "  n1 -->|\"KNOWS\"| n2\n";
    try std.testing.expectEqualStrings(expected, rendered);
}

test "mermaid format: edge accepts type field instead of label" {
    const allocator = std.testing.allocator;

    var rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 1);
    defer deinitRows(allocator, &rows);

    const r_json =
        \\{"id":99,"from":3,"to":4,"type":"FRIENDS_WITH"}
    ;
    try rows.append(allocator, try rowFromCells(allocator, &.{r_json}));

    const rendered = try renderMermaidToSlice(allocator, rows.items);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "flowchart LR\n  n3 -->|\"FRIENDS_WITH\"| n4\n",
        rendered,
    );
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `zig build test-mermaid-format`
Expected: FAIL on both new edge tests — the expected strings include `n1 -->|"KNOWS"| n2` lines that the current renderer does not emit (it only handles nodes).

- [ ] **Step 3: Add the edge-rendering branch**

In `src/client/query_result_accumulator.zig`, locate the `outputMermaidFormatFromRows` function and replace its inner row loop. The current loop body (added in Task 2) looks like:

```zig
            if (obj.get("labels")) |labels_val| {
                const node_id = getDotNodeId(allocator, obj) orelse continue;
                defer allocator.free(node_id);

                if (!seen_nodes.contains(node_id)) {
                    try seen_nodes.put(try allocator.dupe(u8, node_id), {});

                    const label = getMermaidNodeLabel(allocator, obj, labels_val) catch try allocator.dupe(u8, node_id);
                    defer allocator.free(label);

                    try out.writeAll("  n");
                    try out.writeAll(node_id);
                    try out.writeAll("[\"");
                    try out.writeAll(label);
                    try out.writeAll("\"]\n");
                }
            }
```

Replace with:

```zig
            if (obj.get("labels")) |labels_val| {
                const node_id = getDotNodeId(allocator, obj) orelse continue;
                defer allocator.free(node_id);

                if (!seen_nodes.contains(node_id)) {
                    try seen_nodes.put(try allocator.dupe(u8, node_id), {});

                    const label = getMermaidNodeLabel(allocator, obj, labels_val) catch try allocator.dupe(u8, node_id);
                    defer allocator.free(label);

                    try out.writeAll("  n");
                    try out.writeAll(node_id);
                    try out.writeAll("[\"");
                    try out.writeAll(label);
                    try out.writeAll("\"]\n");
                }
            } else if (obj.get("label") orelse obj.get("type")) |type_val| {
                if (type_val != .string) continue;

                const start_id = getDotIdString(allocator, obj.get("from")) orelse
                    getDotIdString(allocator, obj.get("start_node")) orelse continue;
                defer allocator.free(start_id);

                const end_id = getDotIdString(allocator, obj.get("to")) orelse
                    getDotIdString(allocator, obj.get("end_node")) orelse continue;
                defer allocator.free(end_id);

                const escaped_type = try escapeMermaidLabel(allocator, type_val.string);
                defer allocator.free(escaped_type);

                try out.writeAll("  n");
                try out.writeAll(start_id);
                try out.writeAll(" -->|\"");
                try out.writeAll(escaped_type);
                try out.writeAll("\"| n");
                try out.writeAll(end_id);
                try out.writeAll("\n");
            }
```

This mirrors the DOT edge handling at `src/client/query_result_accumulator.zig:608-626` but emits the mermaid `from -->|"label"| to` syntax. `getDotIdString` is reused as-is from line 520.

- [ ] **Step 4: Run tests, verify edge tests pass**

Run: `zig build test-mermaid-format`
Expected: PASS — both edge tests plus all earlier tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/client/query_result_accumulator.zig tests/test_query_result_mermaid.zig
git commit -m "feat(cli): mermaid format renders relationships as labeled arrows

Adds edge handling alongside the node branch in
outputMermaidFormatFromRows. Edges accept either 'label' or 'type'
keys and 'from'/'to' or 'start_node'/'end_node' endpoint fields,
matching the dot path's tolerance. Output uses mermaid's
'from -->|\"label\"| to' syntax with HTML-escaped labels."
```

---

## Task 4: Lock deduplication and special-character escaping (TDD: edge cases)

**Files:**
- Modify: `tests/test_query_result_mermaid.zig` (add dedup + escape tests)

The implementation already covers these (deduplication via `seen_nodes` from Task 2; escaping via `escapeMermaidLabel`). This task adds tests to lock the behavior in. If any test fails here, fix Task 2/3 implementations.

- [ ] **Step 1: Write tests for deduplication and escaping**

Append to `tests/test_query_result_mermaid.zig`:

```zig
test "mermaid format: duplicate nodes across rows render once" {
    const allocator = std.testing.allocator;

    var rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 2);
    defer deinitRows(allocator, &rows);

    const node_json =
        \\{"id":7,"labels":["Person"],"properties":{"name":"Carol"}}
    ;
    try rows.append(allocator, try rowFromCells(allocator, &.{node_json}));
    try rows.append(allocator, try rowFromCells(allocator, &.{node_json}));

    const rendered = try renderMermaidToSlice(allocator, rows.items);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "flowchart LR\n  n7[\"Person<br/>Carol\"]\n",
        rendered,
    );
}

test "mermaid format: label with quotes is HTML-escaped" {
    const allocator = std.testing.allocator;

    var rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 1);
    defer deinitRows(allocator, &rows);

    const node_json =
        \\{"id":11,"labels":["Person"],"properties":{"name":"He said \"hi\""}}
    ;
    try rows.append(allocator, try rowFromCells(allocator, &.{node_json}));

    const rendered = try renderMermaidToSlice(allocator, rows.items);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "flowchart LR\n  n11[\"Person<br/>He said &quot;hi&quot;\"]\n",
        rendered,
    );
}

test "mermaid format: label with ampersand is HTML-escaped without breaking br tags" {
    const allocator = std.testing.allocator;

    var rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 1);
    defer deinitRows(allocator, &rows);

    const node_json =
        \\{"id":12,"labels":["Co"],"properties":{"name":"R&D"}}
    ;
    try rows.append(allocator, try rowFromCells(allocator, &.{node_json}));

    const rendered = try renderMermaidToSlice(allocator, rows.items);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "flowchart LR\n  n12[\"Co<br/>R&amp;D\"]\n",
        rendered,
    );
}

test "mermaid format: edge label with angle bracket is escaped" {
    const allocator = std.testing.allocator;

    var rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 1);
    defer deinitRows(allocator, &rows);

    const r_json =
        \\{"id":50,"from":1,"to":2,"label":"A<B"}
    ;
    try rows.append(allocator, try rowFromCells(allocator, &.{r_json}));

    const rendered = try renderMermaidToSlice(allocator, rows.items);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "flowchart LR\n  n1 -->|\"A&lt;B\"| n2\n",
        rendered,
    );
}
```

- [ ] **Step 2: Run tests — they should pass without code changes**

Run: `zig build test-mermaid-format`
Expected: PASS — the existing dedup logic and `escapeMermaidLabel` already produce these outputs. If anything fails, revisit Task 2-3 implementations.

- [ ] **Step 3: Commit**

```bash
git add tests/test_query_result_mermaid.zig
git commit -m "test(cli): lock mermaid format dedup and HTML-entity escaping behavior"
```

---

## Task 5: Update `--format` help text in `geode query`

**Files:**
- Modify: `src/cli/main.zig:261` (query format option line)
- Modify: `src/cli/main.zig:320` (query examples block)

The shell command's `--format` enum at `src/cli/main.zig:2856-2864` only accepts `json/table/csv` and does not go through `ResultAccumulator`. The other `--format <fmt>` help lines in `main.zig` belong to user/storage/audit subcommands that also do not use `ResultAccumulator`. We only update the **query** command's help.

- [ ] **Step 1: Update the query format option line**

In `src/cli/main.zig:261`, change:

```zig
        "  --format <fmt>         Output format: json|table|csv|dot (default: json)\n" ++
```

to:

```zig
        "  --format <fmt>         Output format: json|table|csv|dot|mermaid (default: json)\n" ++
```

- [ ] **Step 2: Add the mermaid example in the query examples block**

In `src/cli/main.zig:320`, immediately after the existing dot example line:

```zig
        "  geode query --format dot \"MATCH (a)-[r]->(b) RETURN a, r, b\" | dot -Tpng -o graph.png\n" ++
```

insert a new line:

```zig
        "  geode query --format mermaid \"MATCH (a)-[r]->(b) RETURN a, r, b\" | npx -y -p @mermaid-js/mermaid-cli mmdc -i - -o graph.svg\n" ++
```

So the resulting block reads:

```zig
        "  geode query --format dot \"MATCH (a)-[r]->(b) RETURN a, r, b\" | dot -Tpng -o graph.png\n" ++
        "  geode query --format mermaid \"MATCH (a)-[r]->(b) RETURN a, r, b\" | npx -y -p @mermaid-js/mermaid-cli mmdc -i - -o graph.svg\n" ++
        "  geode query --param id 123 \"MATCH (n) WHERE id(n) = $id RETURN n\"\n" ++
```

- [ ] **Step 3: Build and check the help text manually**

Run: `zig build && ./zig-out/bin/geode query --help 2>&1 | grep -E "mermaid|format"`
Expected output includes both:
```
  --format <fmt>         Output format: json|table|csv|dot|mermaid (default: json)
  geode query --format mermaid "MATCH (a)-[r]->(b) RETURN a, r, b" | npx -y -p @mermaid-js/mermaid-cli mmdc -i - -o graph.svg
```

- [ ] **Step 4: Commit**

```bash
git add src/cli/main.zig
git commit -m "docs(cli): advertise --format mermaid in geode query --help

Lists mermaid alongside json/table/csv/dot in the format option line and
adds a runnable mmdc-pipeline example."
```

---

## Task 6: `geodetestlab-cli` integration spec for mermaid

**Files:**
- Create: `geode-test-harness/geodetestlab-cli/specs/query_output_format_mermaid.yml`

This spec runs through the full transport stack (geode server + QUIC client + format dispatch). It is structurally a clone of the dot subset of `query_output_formats.yml` but targets mermaid.

- [ ] **Step 1: Create the spec file**

Create `geode-test-harness/geodetestlab-cli/specs/query_output_format_mermaid.yml`:

```yaml
version: '1.0'
name: Query Output Format Tests - Mermaid
description: 'Tests for --format mermaid (graph results as Mermaid flowchart syntax)'
cli:
  binary: ./zig-out/bin/geode
  server:
    enabled: true
    port:
    data_dir:
    startup_timeout_ms: 30000
    cleanup: true
    args:
    - --log-level
    - warn
    env:
      GEODE_ALLOW_TEST_AUDIT_KEYS: '1'
  client:
    timeout_ms: 10000
    tls_verify: false
    format: json
tests:
- name: query-help-shows-mermaid-format
  description: Verify query --help advertises mermaid format
  args:
  - query
  - --help
  expect:
    exit_code: 0
    stderr_contains:
    - --format
    - mermaid
  tags:
  - help
  - mermaid
- name: query-help-shows-mermaid-example
  description: Verify query --help shows the mmdc pipeline example
  args:
  - query
  - --help
  expect:
    exit_code: 0
    stderr_contains:
    - --format mermaid
    - mmdc
  tags:
  - help
  - mermaid
- name: mermaid-format-empty-graph
  description: Test mermaid format with no nodes returns just the header
  args:
  - query
  - --format
  - mermaid
  - RETURN 1 AS x
  expect:
    exit_code: 0
    stdout_contains:
    - flowchart LR
  tags:
  - format
  - mermaid
- name: mermaid-format-single-node
  description: Test mermaid format with single node renders id-prefixed name
  args:
  - query
  - --format
  - mermaid
  - "CREATE (n:Person {name: 'Alice'}) RETURN n"
  expect:
    exit_code: 0
    stdout_contains:
    - flowchart LR
    - Person
    - Alice
    - '<br/>'
  tags:
  - format
  - mermaid
  - node
- name: mermaid-format-relationship
  description: Test mermaid format with relationship renders arrow with label
  args:
  - query
  - --format
  - mermaid
  - "CREATE (a:Person {name: 'A'})-[r:KNOWS]->(b:Person {name: 'B'}) RETURN a, r, b"
  expect:
    exit_code: 0
    stdout_contains:
    - flowchart LR
    - '-->'
    - KNOWS
  tags:
  - format
  - mermaid
  - relationship
- name: mermaid-format-edge-label-quoted
  description: Test mermaid format quotes the edge type label
  args:
  - query
  - --format
  - mermaid
  - CREATE (a:Person)-[r:FRIENDS_WITH]->(b:Person) RETURN a, r, b
  expect:
    exit_code: 0
    stdout_contains:
    - '|"FRIENDS_WITH"|'
  tags:
  - format
  - mermaid
  - edge
- name: mermaid-format-multiple-nodes
  description: Test mermaid format handles multiple nodes in a row
  args:
  - query
  - --format
  - mermaid
  - CREATE (a:A), (b:B), (c:C) RETURN a, b, c
  expect:
    exit_code: 0
    stdout_contains:
    - flowchart LR
  tags:
  - format
  - mermaid
  - multiple
- name: mermaid-format-chain
  description: Test mermaid format with chain of nodes and edges
  args:
  - query
  - --format
  - mermaid
  - CREATE (a:Start)-[r1:NEXT]->(b:Middle)-[r2:NEXT]->(c:End) RETURN a, r1, b, r2, c
  expect:
    exit_code: 0
    stdout_contains:
    - flowchart LR
    - NEXT
    - '-->'
  tags:
  - format
  - mermaid
  - chain
- name: mermaid-format-full-graph
  description: Test mermaid format on a MATCH query against pre-existing data
  setup:
  - args:
    - query
    - "CREATE (a:Person {name: 'Alice'})-[:KNOWS]->(b:Person {name: 'Bob'})"
    expect:
      exit_code: 0
  args:
  - query
  - --format
  - mermaid
  - MATCH (a)-[r]->(b) RETURN a, r, b
  expect:
    exit_code: 0
    stdout_contains:
    - flowchart LR
    - '-->'
    - KNOWS
  tags:
  - format
  - mermaid
  - integration
- name: mermaid-format-id-prefix
  description: Test mermaid format prefixes node ids with 'n' to make valid identifiers
  args:
  - query
  - --format
  - mermaid
  - "CREATE (n:Item {sku: 'X1'}) RETURN n"
  expect:
    exit_code: 0
    stdout_contains:
    - flowchart LR
    - '  n'
    - Item
  tags:
  - format
  - mermaid
  - id-prefix
```

- [ ] **Step 2: Run the spec against a freshly built geode**

```bash
cd /data/home/benji/src/devnw/codepros/geode/geode && zig build
cd /data/home/benji/src/devnw/codepros/geode/geode-test-harness
GEODE_BINARY=/data/home/benji/src/devnw/codepros/geode/geode/zig-out/bin/geode \
    make test-spec SPEC=query_output_format_mermaid.yml
```

Expected: All tests pass. The spec runs `geode serve` via the harness machinery, then runs each `geode query --format mermaid ...` invocation in turn.

- [ ] **Step 3: Commit (in geode-test-harness repo)**

```bash
cd /data/home/benji/src/devnw/codepros/geode/geode-test-harness
git add geodetestlab-cli/specs/query_output_format_mermaid.yml
git commit -m "test(harness): add geode query --format mermaid integration spec

Mirrors the dot subset of query_output_formats.yml but asserts on
mermaid syntax: 'flowchart LR' header, '-->' arrows, and the
'|\"LABEL\"|' edge-label form. Covers help text, single nodes, edges,
chains, and a setup+match scenario."
cd /data/home/benji/src/devnw/codepros/geode/geode
```

---

## Task 7: External mermaid validation script (real `mmdc` parser)

**Files:**
- Create: `tests/integration/test_mermaid_external.sh`
- Create: `tests/integration/mermaid-puppeteer-config.json`
- Create: `tests/integration/README_mermaid.md`

The script:
1. Asserts `node` and `npx` are on PATH (per environment check: `node v24.14.1` is present in the dev env).
2. Picks an unprivileged port in 49152-65535 and starts geode on it (per memory `feedback_validation_strategy.md` — never touch the system geode).
3. Waits for the server to come up.
4. Runs three queries with `--format mermaid` and pipes each output through `npx -y -p @mermaid-js/mermaid-cli mmdc -i <tmpfile> -o <svgfile> --quiet --puppeteerConfigFile <pup-config>`.
5. Asserts each SVG is non-empty and contains `<svg`.
6. Cleans up the geode process and tempdir on EXIT.

The puppeteer config file is needed because most CI sandboxes run as root and need `--no-sandbox`.

- [ ] **Step 1: Create the integration directory**

```bash
mkdir -p tests/integration
```

- [ ] **Step 2: Create the puppeteer config**

Create `tests/integration/mermaid-puppeteer-config.json`:

```json
{
  "args": ["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage"]
}
```

- [ ] **Step 3: Create the integration script**

Create `tests/integration/test_mermaid_external.sh`:

```bash
#!/usr/bin/env bash
# External mermaid integration test for `geode query --format mermaid`.
#
# Builds geode (if needed), starts a private instance on a high port,
# runs three representative queries through `--format mermaid`, and
# pipes each output to `npx @mermaid-js/mermaid-cli mmdc` to verify
# the output is *actually* valid mermaid (rendered to SVG).
#
# Requirements: node + npx on PATH. The first run will install
# @mermaid-js/mermaid-cli into npx's cache, which downloads chromium
# (~200 MB). Subsequent runs are fast.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

GEODE_BIN="${GEODE_BIN:-$REPO_ROOT/zig-out/bin/geode}"
PORT="${MERMAID_TEST_PORT:-$((RANDOM % 16383 + 49152))}"
TMPDIR="$(mktemp -d)"
SERVER_PID=""

cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

# 1. Sanity-check tooling
if ! command -v node >/dev/null 2>&1; then
    echo "FAIL: node not found on PATH" >&2
    exit 1
fi
if ! command -v npx >/dev/null 2>&1; then
    echo "FAIL: npx not found on PATH" >&2
    exit 1
fi

# 2. Build geode if the binary is missing
if [ ! -x "$GEODE_BIN" ]; then
    echo "Building geode..."
    zig build
fi
if [ ! -x "$GEODE_BIN" ]; then
    echo "FAIL: $GEODE_BIN missing after build" >&2
    exit 1
fi

# 3. Start a private geode instance on a high port
echo "Starting geode on 127.0.0.1:$PORT (data: $TMPDIR/data)..."
mkdir -p "$TMPDIR/data"
GEODE_DEFAULT_PASSWORD=MermaidTestPassword123! \
"$GEODE_BIN" serve \
    --listen "127.0.0.1:$PORT" \
    --data-dir "$TMPDIR/data" \
    --no-cluster \
    --log-level warn \
    >"$TMPDIR/server.log" 2>&1 &
SERVER_PID=$!

# Wait for the port to accept connections (up to 30s)
for _ in $(seq 1 60); do
    if (echo > /dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then
        break
    fi
    sleep 0.5
done
if ! (echo > /dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then
    echo "FAIL: geode did not start on port $PORT" >&2
    cat "$TMPDIR/server.log" >&2
    exit 1
fi

# 4. Run three representative queries and validate via mmdc
PUP_CONFIG="$REPO_ROOT/tests/integration/mermaid-puppeteer-config.json"

run_case() {
    local name="$1"
    local query="$2"
    local mmd_file="$TMPDIR/$name.mmd"
    local svg_file="$TMPDIR/$name.svg"

    echo "--- Case: $name ---"
    "$GEODE_BIN" query \
        --server "127.0.0.1:$PORT" \
        --insecure-tls-skip-verify \
        --user geode \
        --password "MermaidTestPassword123!" \
        --format mermaid \
        "$query" \
        > "$mmd_file"

    if [ ! -s "$mmd_file" ]; then
        echo "FAIL[$name]: empty mermaid output" >&2
        return 1
    fi

    if ! grep -q "^flowchart LR$" "$mmd_file"; then
        echo "FAIL[$name]: missing 'flowchart LR' header" >&2
        cat "$mmd_file" >&2
        return 1
    fi

    # Run the official mermaid renderer. Exit code 0 + non-empty SVG = valid mermaid.
    if ! npx -y -p @mermaid-js/mermaid-cli mmdc \
        -i "$mmd_file" \
        -o "$svg_file" \
        --quiet \
        --puppeteerConfigFile "$PUP_CONFIG" 2> "$TMPDIR/$name.mmdc.log"; then
        echo "FAIL[$name]: mmdc rejected geode output" >&2
        echo "--- mermaid input ---" >&2
        cat "$mmd_file" >&2
        echo "--- mmdc stderr ---" >&2
        cat "$TMPDIR/$name.mmdc.log" >&2
        return 1
    fi

    if [ ! -s "$svg_file" ]; then
        echo "FAIL[$name]: mmdc produced empty SVG" >&2
        return 1
    fi

    if ! grep -q "<svg" "$svg_file"; then
        echo "FAIL[$name]: mmdc output is not SVG" >&2
        head -c 200 "$svg_file" >&2
        return 1
    fi

    echo "OK[$name]: mermaid valid, SVG $(wc -c < "$svg_file") bytes"
}

# Case 1: empty graph (just header)
run_case "empty" "RETURN 1 AS x"

# Case 2: single node
run_case "single-node" "CREATE (n:Person {name: 'Alice'}) RETURN n"

# Case 3: relationship
run_case "relationship" "CREATE (a:Person {name: 'Alice'})-[r:KNOWS]->(b:Person {name: 'Bob'}) RETURN a, r, b"

echo ""
echo "ALL MERMAID INTEGRATION TESTS PASSED"
```

Make it executable:

```bash
chmod +x tests/integration/test_mermaid_external.sh
```

- [ ] **Step 4: Create the README**

Create `tests/integration/README_mermaid.md`:

```markdown
# Mermaid External Integration Tests

`test_mermaid_external.sh` runs `geode query --format mermaid` against a
private geode instance on a high port and pipes the output through
`@mermaid-js/mermaid-cli` (the official Mermaid renderer) to verify the
output is real, parseable Mermaid syntax that produces a valid SVG.

## Running

    ./tests/integration/test_mermaid_external.sh

The first run downloads `@mermaid-js/mermaid-cli` and chromium via npx
(~200 MB). Subsequent runs reuse the cache.

## Requirements

- `node` and `npx` on PATH (any recent Node.js >= 18).
- The geode binary at `./zig-out/bin/geode` (the script will run
  `zig build` if it's missing).
- ~200 MB of disk for the npx/puppeteer cache on first run.

## What it checks

For each of three queries (empty graph, single node, single relationship):

1. The mermaid output starts with `flowchart LR`.
2. `mmdc` renders the output to an SVG without parser errors.
3. The resulting SVG is non-empty and starts with `<svg`.

## Make target

    make test-mermaid-integration
```

- [ ] **Step 5: Smoke-run the script locally**

Run: `./tests/integration/test_mermaid_external.sh`
Expected: All three cases (`empty`, `single-node`, `relationship`) pass and the script ends with `ALL MERMAID INTEGRATION TESTS PASSED`. The first run is slow (npx pulls down chromium); subsequent runs complete in ~30 seconds.

- [ ] **Step 6: Commit**

```bash
git add tests/integration/test_mermaid_external.sh \
        tests/integration/mermaid-puppeteer-config.json \
        tests/integration/README_mermaid.md
git commit -m "test(integration): external mermaid validation via @mermaid-js/mermaid-cli

Adds a bash harness that starts a private geode instance on a high
port (per feedback_validation_strategy memory: never disturb the
system geode), runs three representative queries through
'--format mermaid', and pipes each output through 'mmdc' to confirm
the output is real Mermaid syntax. Asserts SVG is produced for each
case. Includes puppeteer config so chromium runs without sandboxing
(needed under root or container CI)."
```

---

## Task 8: Wire mermaid integration into Makefile

**Files:**
- Modify: `Makefile` (add `test-mermaid-integration` target)

- [ ] **Step 1: Locate the test targets section**

Run: `grep -n "^\.PHONY\|^test-" Makefile | head -20`

Identify a sensible insertion point near other integration test targets.

- [ ] **Step 2: Add the new target**

Append the following block to the end of `Makefile`:

```makefile
# External mermaid integration test (uses @mermaid-js/mermaid-cli to
# verify --format mermaid output is real, parseable Mermaid).
.PHONY: test-mermaid-integration
test-mermaid-integration:
	@echo "Running external mermaid integration tests..."
	@./tests/integration/test_mermaid_external.sh
```

- [ ] **Step 3: Smoke-run the new target**

Run: `make test-mermaid-integration`
Expected: `ALL MERMAID INTEGRATION TESTS PASSED` after ~30s (or longer on first run while chromium downloads).

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "build(make): add test-mermaid-integration target"
```

---

## Task 9: End-to-end verification

This task pulls every layer together to confirm nothing regressed and the new format is fully wired.

- [ ] **Step 1: Run the focused unit tests**

Run: `zig build test-mermaid-format`
Expected: All mermaid format unit tests pass (10 tests covering empty rows, single node, multi-label, fallback id, edges with `label` and `type`, dedup, quote escape, ampersand escape, edge `<` escape).

- [ ] **Step 2: Run the dot-format harness spec to confirm no regression**

```bash
cd /data/home/benji/src/devnw/codepros/geode/geode-test-harness
GEODE_BINARY=/data/home/benji/src/devnw/codepros/geode/geode/zig-out/bin/geode \
    make test-spec SPEC=query_output_formats.yml
cd /data/home/benji/src/devnw/codepros/geode/geode
```

Expected: All dot/json/csv/table tests still pass. Mermaid is additive — the dot path was untouched semantically.

- [ ] **Step 3: Run the new mermaid harness spec**

```bash
cd /data/home/benji/src/devnw/codepros/geode/geode-test-harness
GEODE_BINARY=/data/home/benji/src/devnw/codepros/geode/geode/zig-out/bin/geode \
    make test-spec SPEC=query_output_format_mermaid.yml
cd /data/home/benji/src/devnw/codepros/geode/geode
```

Expected: All 10 mermaid integration tests pass.

- [ ] **Step 4: Run the external mmdc-backed validation**

Run: `make test-mermaid-integration`
Expected: `ALL MERMAID INTEGRATION TESTS PASSED`.

- [ ] **Step 5: Manual sanity check — pipeline to file**

```bash
zig build
TMPDIR=$(mktemp -d)
./zig-out/bin/geode serve --listen 127.0.0.1:43141 --data-dir "$TMPDIR/data" --no-cluster --log-level warn &
SERVER=$!
sleep 2
GEODE_DEFAULT_PASSWORD=ManualTestPassword123! ./zig-out/bin/geode query \
    --server 127.0.0.1:43141 \
    --insecure-tls-skip-verify \
    --user geode \
    --password "ManualTestPassword123!" \
    --format mermaid \
    "CREATE (a:Person {name: 'Alice'})-[r:KNOWS]->(b:Person {name: 'Bob'}) RETURN a, r, b"
kill $SERVER
rm -rf "$TMPDIR"
```

Expected output (exact integer IDs depend on the database):

```
flowchart LR
  n1["Person<br/>Alice"]
  n2["Person<br/>Bob"]
  n1 -->|"KNOWS"| n2
```

- [ ] **Step 6: Run the broader test suite to catch unrelated regressions**

Run: `zig build test`
Expected: All unit tests pass that were passing before. Per the memory `preexisting_test_failures.md`, some perf/coordinator tests may already be failing on `main`; do not chase those — only investigate failures that mention mermaid, format, accumulator, or transport response.

- [ ] **Step 7: Final commit (only if doc/build tweaks remain)**

If anything was missed, stage and commit. Otherwise this task is verification only, no commit needed.

---

## Self-Review

**1. Spec coverage:**

The user's request had three parts. Each is covered:
- "Add mermaid support for the `geode query` command like the dot support" → Tasks 1-5 add `--format mermaid` to `geode query` end-to-end (TextMode, accumulator field, render dispatch, output renderer, helpers, help text).
- "like the dot support" → Tasks 1-3 mirror the DOT structure exactly (same enum, same field placement, same render dispatch, same helper layout in `query_result_accumulator.zig`).
- "fully verified using external mermaid integration tests to ensure it's properly built" → Task 7 runs the actual `@mermaid-js/mermaid-cli` against geode output and asserts the renderer accepts it (SVG produced). Task 6 covers the CLI surface in the geodetestlab harness. Task 9 is the end-to-end sweep.

**2. Placeholder scan:**

No placeholders. Every step has either exact code, exact CLI, or exact expected output.

**3. Type and method consistency:**

- `outputMermaidFormatFromRows` is the renderer entry point used in Tasks 1, 2, 3 and tested in Tasks 1, 2, 3, 4 — name matches everywhere.
- `getMermaidNodeLabel` and `escapeMermaidLabel` are introduced in Task 2 and `escapeMermaidLabel` is reused in Task 3 — names match.
- `wants_mermaid` field on `ResultAccumulator` introduced in Task 1, referenced in Task 1 (render dispatch and appendPageText mode selection) — name matches.
- `TextMode.mermaid` enum variant introduced in Task 1, used in Task 1 (`appendPageText` mode selection and `valueToText` mode check) — name matches.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-06-mermaid-query-format.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — A fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
