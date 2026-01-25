# JSON Library Migration Plan

> **Status**: IN PROGRESS - Phase 7 Complete (Core Server Files)
> **Created**: 2026-01-24
> **Updated**: 2026-01-24
> **Priority**: HIGH - Technical Debt Reduction
> **Estimated Scope**: 69 files, ~400+ manual JSON composition sites
> **Phase 1 Completed**: Protocol Layer (3 files, 12 frame builders migrated)
> **Phase 2 Completed**: Execution Layer (4 files: crud_operations, value_utilities, execution, eval_extended)
> **Phase 3 Completed**: CLI Layer (2 files: main.zig, backup_cli.zig - HELLO/RUN_GQL/RESTORE messages)
> **Phase 4 Completed**: MCP & Streaming (5 files: tools.zig, resources.zig, client.zig, lsp.zig, cdc_enhanced.zig)
> **Phase 5 Completed**: Supporting Systems (5 files: logger.zig, file_sink.zig, audit.zig, external_kms_client.zig, twophase.zig)
> **Phase 6 Completed**: Testing & Validation (wire protocol tests, streaming encoder fixes, API corrections)
> **Phase 7 Completed**: Final Cleanup - Core Server Files
>   - `transaction_handlers.zig` - 8 patterns migrated (TXN_BEGIN, TXN_COMMIT, TXN_ROLLBACK)
>   - `query_executor.zig` - 70+ patterns migrated (index ops, backup, schema, graph, session)
>   - `cli/main.zig` - 6 patterns migrated (error responses, column defs)
> **Remaining**: 10 files with low-priority patterns (test harness, tools, client, distributed)

## Executive Summary

This document outlines the migration plan for replacing manual JSON string composition throughout the Geode codebase with the extensively-tested external JSON library (`json` module). The library provides RFC 8259 compliance, JSON Schema 2020-12 validation, SIMD acceleration, and type-safe encoding/decoding.

## Current State Analysis

### Manual JSON Composition Locations

**69 files** currently contain manual JSON string composition using patterns such as:
- `writer.writeAll("{\"key\":...")` - Direct string concatenation
- `fmt.allocPrint(..., "{{\"key\":\"{s}\"}}", ...)` - Format string templates
- `ArrayList.append('{')` / `ArrayList.appendSlice("\"key\":")` - Character-by-character building
- `@memcpy()` with pre-computed prefixes - Raw memory operations

### Critical Files (Priority 1)

| File | Description | Impact |
|------|-------------|--------|
| `src/protocol.zig` | Wire protocol frame building | All client communication |
| `src/server/query_executor.zig` | Query result serialization | Core query path |
| `src/execution/crud_operations.zig` | Value-to-JSON conversion | Data persistence |
| `src/cli/main.zig` | CLI response formatting | User interface |
| `src/server/stdio_message_handler.zig` | STDIO protocol | MCP integration |

### High-Impact Files (Priority 2)

| File | Description |
|------|-------------|
| `src/mcp/tools.zig` | MCP tool responses |
| `src/mcp/resources.zig` | MCP resource serialization |
| `src/mcp/client.zig` | MCP client messages |
| `src/streaming/cdc_enhanced.zig` | CDC event encoding |
| `src/audit/logger.zig` | Audit log formatting |
| `src/security/audit.zig` | Security audit events |

### Supporting Files (Priority 3)

- `src/distributed/*.zig` - Distributed coordination messages
- `src/monitoring/*.zig` - Metrics and tracing
- `src/types/*.zig` - Type serialization
- `src/planner/*.zig` - Query plan output
- `src/storage/s3_backup.zig` - Cloud backup metadata
- `src/client/repl/*.zig` - REPL responses

## Available JSON Library

### Library Location
```zig
// build.zig.zon
.json = .{
    .path = "../../../zig/json",
},
```

### Import
```zig
const json = @import("json");
```

### Core Capabilities

#### Encoding (Zig -> JSON)
```zig
// Encode any Zig type to JSON string
const json_str = try json.encode(allocator, value, .{});
defer allocator.free(json_str);

// Stream encoding to writer
try json.encodeToWriter(writer, value, .{});

// Convert to Value tree for manipulation
const json_value = try json.toValue(allocator, zig_value, .{});
```

#### Decoding (JSON -> Zig)
```zig
// Parse JSON and unmarshal to Zig type
const result = try json.unmarshal(MyStruct, allocator, json_input);
defer json.free(MyStruct, allocator, result);

// Parse to Value tree
var doc = try json.parse(allocator, json_input, .{}, null);
defer doc.deinit();
```

#### Streaming API
```zig
// For large documents or real-time output
var encoder = json.streamingEncoder(allocator, writer, .{});
try encoder.beginObject();
try encoder.field("key");
try encoder.string("value");
try encoder.endObject();
```

### Type Mapping

| Zig Type | JSON Output |
|----------|-------------|
| `bool` | `true` / `false` |
| `integers` | Number |
| `floats` | Number (NaN/Inf -> `null`) |
| `[]const u8` | String (with proper escaping) |
| `?T` | Value or `null` |
| `enum` | String (tag name) |
| `struct` | Object |
| `[]T`, `[N]T` | Array |
| `union(enum)` | `{"tag": value}` |

### Key Features

- **RFC 8259 Compliant**: Strict JSON parsing with optional JSON5 extensions
- **Proper Escaping**: Handles all Unicode, control characters, surrogate pairs
- **Type Safety**: Compile-time reflection for correct serialization
- **Error Locations**: Line, column, and byte offset for parse errors
- **SIMD Acceleration**: Fast parsing and encoding
- **Streaming Support**: Memory-efficient for large documents

## Migration Strategy

### Phase 1: Protocol Layer (Week 1-2)

**Goal**: Migrate core protocol frame building to ensure all client communication uses the JSON library.

#### 1.1 Create Protocol Response Types

Define structs matching the wire protocol:

```zig
// src/protocol.zig additions

pub const SchemaResponse = struct {
    status_class: []const u8 = "00000",
    result: SchemaResult,

    pub const SchemaResult = struct {
        type: []const u8 = "SCHEMA",
        columns: []const SchemaCol,
        additional_statuses: ?[]const []const u8 = null,
        flagger_findings: ?[]const []const u8 = null,
    };
};

pub const BindingsResponse = struct {
    status_class: []const u8 = "00000",
    result: BindingsResult,

    pub const BindingsResult = struct {
        type: []const u8 = "BINDINGS",
        ordered: bool,
        order_keys: []const []const u8,
        rows: json.Value, // Already-parsed rows
        final: bool,
        additional_statuses: ?[]const []const u8 = null,
        flagger_findings: ?[]const []const u8 = null,
    };
};

pub const ErrorResponse = struct {
    status_class: []const u8,
    status_subclass: ?[]const u8 = null,
    error: []const u8,
    flagger_findings: ?[]const []const u8 = null,
};
```

#### 1.2 Replace Frame Builders

**Before** (`buildSchemaLine`):
```zig
pub fn buildSchemaLine(allocator: std.mem.Allocator, cols: []const SchemaCol, additional: []const []const u8, flags: []const []const u8) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 16) catch return error.OutOfMemory;
    const w = buf.writer(allocator);
    try w.writeAll("{\"status_class\":\"00000\",\"result\":{\"type\":\"SCHEMA\",\"columns\":[");
    var i: usize = 0;
    while (i < cols.len) : (i += 1) {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":\"");
        try w.writeAll(cols[i].name);
        // ... more manual building
    }
    // ...
}
```

**After**:
```zig
pub fn buildSchemaLine(allocator: std.mem.Allocator, cols: []const SchemaCol, additional: []const []const u8, flags: []const []const u8) ![]u8 {
    const response = SchemaResponse{
        .result = .{
            .columns = cols,
            .additional_statuses = if (additional.len > 0) additional else null,
            .flagger_findings = if (flags.len > 0) flags else null,
        },
    };

    const json_str = try json.encode(allocator, response, .{});
    defer allocator.free(json_str);

    // Add newline for wire protocol
    const result = try allocator.alloc(u8, json_str.len + 1);
    @memcpy(result[0..json_str.len], json_str);
    result[json_str.len] = '\n';
    return result;
}
```

#### 1.3 Files to Update

1. `src/protocol.zig` - `buildSchemaLine`, `buildBindingsLine`, `buildExplainLine`, `buildProfileLine`, `buildErrorLine*`, `buildCdc*Line`
2. `src/server/query_executor.zig` - `bindingValueRowToJson`
3. `src/server/stdio_message_handler.zig` - Response formatting

### Phase 2: Execution Layer (Week 2-3) - COMPLETED

**Goal**: Replace value serialization in execution paths.

**Status**: COMPLETE (2026-01-24)
- `src/execution/crud_operations.zig` - Migrated `valueMapToJson`, `encodeValueToStream`, `formatDecimalForJson`
- `src/execution/value_utilities.zig` - Added JSON library import, `writeJsonEscapedString` helper
- `src/execution.zig` - Migrated `toJsonWithFlags` to use streaming encoder
- `src/eval_extended.zig` - Migrated `wkbToGeoJson` for GeoJSON output
- Build.zig updated to provide `json` module to test modules

#### 2.1 Value Type Encoding

**Before** (`src/execution/crud_operations.zig`):
```zig
fn valueToJsonAppend(allocator: std.mem.Allocator, value: Value, output: *std.ArrayList(u8)) !void {
    switch (value) {
        .Null => try output.appendSlice(allocator, "null"),
        .Int => |i| {
            var buf: [32]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "{d}", .{i}) catch "0";
            try output.appendSlice(allocator, formatted);
        },
        .Str => |s| {
            try output.append(allocator, '"');
            for (s) |c| {
                switch (c) {
                    '"' => try output.appendSlice(allocator, "\\\""),
                    '\\' => try output.appendSlice(allocator, "\\\\"),
                    // ... manual escaping
                }
            }
            try output.append(allocator, '"');
        },
        // ...
    }
}
```

**After**:
```zig
fn valueToJson(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    // Convert Value to json.Value tree
    const json_val = try valueToJsonValue(allocator, value);
    return try json.stringify(allocator, json_val);
}

fn valueToJsonValue(allocator: std.mem.Allocator, value: Value) !json.Value {
    return switch (value) {
        .Null => .null,
        .Int => |i| .{ .num = json.Number.fromInt(i) },
        .Bool => |b| .{ .bool = b },
        .Str => |s| .{ .str = s },
        .List => |list| blk: {
            var arr = try allocator.alloc(json.Value, list.len);
            for (list, 0..) |item, idx| {
                arr[idx] = try valueToJsonValue(allocator, item);
            }
            break :blk .{ .arr = arr };
        },
        .Map => |map| try mapToJsonObject(allocator, map),
        else => .null,
    };
}
```

#### 2.2 Files to Update

1. `src/execution/crud_operations.zig` - `valueMapToJson`, `valueToJsonAppend`
2. `src/execution/value_utilities.zig` - Value serialization helpers
3. `src/execution.zig` - Result building
4. `src/eval_extended.zig` - Extended value encoding

### Phase 3: CLI Layer (Week 3-4) - COMPLETED

**Goal**: Replace manual JSON in CLI handlers.

**Status**: COMPLETE (2026-01-24)
- `src/cli/main.zig` - Added json_lib import, CliHelloMessage/CliRunGqlMessage/CliErrorResponse structs
  - Migrated HELLO message encoding (2 locations)
  - Migrated RUN_GQL message encoding
  - Migrated dynamic error responses
- `src/cli/backup_cli.zig` - Added json_lib import, BackupHelloMessage/BackupRunGqlMessage structs
  - Migrated execMigrationScript HELLO/RUN_GQL messages
  - Migrated executeRemoteBackup HELLO message
  - Migrated restore HELLO and RESTORE messages
- Build.zig updated to provide `json` module to cli_tests

#### 3.1 Response Standardization

Create CLI-specific response types:

```zig
// src/cli/responses.zig

pub const CliError = struct {
    status_class: []const u8,
    error: []const u8,

    pub fn encode(self: CliError, allocator: std.mem.Allocator) ![]u8 {
        return json.encode(allocator, self, .{});
    }
};

pub const CliResult = struct {
    status_class: []const u8 = "00000",
    result: ResultPayload,

    pub const ResultPayload = union(enum) {
        schema: SchemaPayload,
        bindings: BindingsPayload,
        error: ErrorPayload,
    };
};
```

#### 3.2 Files to Update

1. `src/cli/main.zig` - All `allocPrint` with JSON templates
2. `src/cli/backup_cli.zig` - Backup response formatting
3. `src/cli/security/session_storage.zig` - Session data persistence

### Phase 4: MCP & Streaming (Week 4-5) - COMPLETED

**Goal**: Migrate MCP protocol and CDC streaming.

**Status**: COMPLETE (2026-01-24)
- `src/mcp/tools.zig` - Migrated formatToolResult, formatErrorResponse
- `src/mcp/resources.zig` - Migrated formatResourceResponse, formatResourceError
- `src/mcp/client.zig` - Migrated query() with streaming encoder, explain()
- `src/mcp/lsp.zig` - Migrated validation, completion, hover response formatting
- `src/streaming/cdc_enhanced.zig` - Migrated serializeEvent, exportDiagnostics, malformedLogSnapshots
- Build.zig updated to provide `json` module to mcp_cli_mod

#### 4.1 MCP Tool Responses

```zig
// src/mcp/tools.zig

pub const ToolResult = struct {
    content: []const Content,
    isError: bool = false,

    pub const Content = struct {
        type: []const u8 = "text",
        text: []const u8,
    };
};

pub fn buildToolResponse(allocator: std.mem.Allocator, text: []const u8, is_error: bool) ![]u8 {
    const result = ToolResult{
        .content = &[_]ToolResult.Content{.{ .text = text }},
        .isError = is_error,
    };
    return json.encode(allocator, result, .{});
}
```

#### 4.2 CDC Event Encoding

```zig
// src/streaming/cdc_enhanced.zig

pub const CdcEvent = struct {
    type: []const u8,
    timestamp: i64,
    graph: []const u8,
    operation: []const u8,
    data: json.Value,
};
```

#### 4.3 Files to Update

1. `src/mcp/tools.zig` - Tool responses
2. `src/mcp/resources.zig` - Resource responses
3. `src/mcp/client.zig` - Client messages
4. `src/mcp/lsp.zig` - LSP protocol
5. `src/streaming/cdc_enhanced.zig` - CDC events

### Phase 5: Supporting Systems (Week 5-6)

**Goal**: Complete migration of remaining systems.

#### 5.1 Audit & Security
- `src/audit/logger.zig`
- `src/audit/file_sink.zig`
- `src/security/audit.zig`
- `src/security/kms.zig`
- `src/security/external_kms_client.zig`

#### 5.2 Distributed Systems
- `src/distributed/twophase.zig`
- `src/distributed/raft.zig`
- `src/distributed/cluster.zig`

#### 5.3 Monitoring & Diagnostics
- `src/monitoring/tracing.zig`
- `src/monitoring/metrics.zig`
- `src/gpu/telemetry.zig`

#### 5.4 Storage & Backup
- `src/storage/s3_backup.zig`
- `src/cli/backup_cli.zig`

#### 5.5 Types & Utilities
- `src/types/extended_functions.zig`
- `src/types/uuid.zig`
- `src/types/datetime.zig`
- `src/types/decimal128.zig`
- `src/types/network/mac.zig`
- `src/types/cryptographic.zig`
- `src/util/yaml.zig`

### Phase 6: Testing & Validation (Week 6-7)

**Goal**: Ensure complete compatibility and no regressions.

#### 6.1 Wire Protocol Compatibility Tests

```zig
test "wire protocol JSON compatibility" {
    // Test that new encoding produces byte-identical output
    const old_output = try buildSchemaLineOld(allocator, cols, &.{}, &.{});
    defer allocator.free(old_output);

    const new_output = try buildSchemaLine(allocator, cols, &.{}, &.{});
    defer allocator.free(new_output);

    // Parse both and compare semantically
    var old_doc = try json.parse(allocator, old_output, .{}, null);
    defer old_doc.deinit();
    var new_doc = try json.parse(allocator, new_output, .{}, null);
    defer new_doc.deinit();

    try std.testing.expect(json.Value.eql(old_doc.root, new_doc.root));
}
```

#### 6.2 Client Compatibility Matrix

Test with all client libraries:
- [ ] `geode-client-go` - All operations
- [ ] `geode-client-python` - All operations
- [ ] `geode-client-rust` - All operations
- [ ] `geode-client-zig` - All operations

#### 6.3 Geodetestlab Validation

```bash
# Run full test suite after each phase
make geodetestlab-comprehensive

# Target: Maintain 97.4% pass rate (1644/1688 tests)
```

## Migration Patterns

### Pattern 1: Simple Object Encoding

**Before**:
```zig
try fmt.allocPrint(allocator, "{{\"status\":\"{s}\",\"message\":\"{s}\"}}", .{status, message});
```

**After**:
```zig
const Response = struct { status: []const u8, message: []const u8 };
try json.encode(allocator, Response{ .status = status, .message = message }, .{});
```

### Pattern 2: Writer-Based Building

**Before**:
```zig
try writer.writeAll("{\"type\":\"");
try writer.writeAll(type_name);
try writer.writeAll("\",\"data\":");
try writer.writeAll(data_json);
try writer.writeAll("}");
```

**After**:
```zig
var encoder = json.streamingEncoder(allocator, writer, .{});
try encoder.beginObject();
try encoder.field("type");
try encoder.string(type_name);
try encoder.field("data");
try encoder.raw(data_json); // Pre-encoded JSON
try encoder.endObject();
```

### Pattern 3: ArrayList Building

**Before**:
```zig
var result = std.ArrayList(u8).init(allocator);
try result.append('{');
try result.appendSlice("\"key\":");
// ...
```

**After**:
```zig
const obj = MyStruct{ .key = value };
const json_str = try json.encode(allocator, obj, .{});
```

### Pattern 4: Conditional Fields

**Before**:
```zig
try writer.writeAll("{\"status\":\"ok\"");
if (has_data) {
    try writer.writeAll(",\"data\":");
    try writer.writeAll(data);
}
try writer.writeAll("}");
```

**After**:
```zig
const Response = struct {
    status: []const u8 = "ok",
    data: ?[]const u8 = null,
};
try json.encode(allocator, Response{ .data = if (has_data) data else null }, .{});
```

## Testing Requirements

### Unit Tests
- [ ] Each migrated function has before/after comparison test
- [ ] Edge cases: empty arrays, null values, Unicode strings, special characters
- [ ] Error handling: allocation failures, invalid inputs

### Integration Tests
- [ ] Wire protocol round-trip with all client libraries
- [ ] CDC event parsing by consumers
- [ ] Audit log parsing by log aggregators
- [ ] MCP protocol compliance

### Performance Tests
- [ ] Encoding throughput comparison (before/after)
- [ ] Memory allocation patterns
- [ ] No performance regression in hot paths

## Rollback Plan

Each phase includes a rollback capability:

1. **Feature Flag**: Add `USE_JSON_LIB` compile-time flag
2. **Old Functions**: Rename to `*_legacy` during migration
3. **Gradual Cutover**: Enable per-subsystem

```zig
const USE_JSON_LIB = @import("build_options").use_json_lib;

pub fn buildSchemaLine(...) ![]u8 {
    if (USE_JSON_LIB) {
        return buildSchemaLineNew(...);
    } else {
        return buildSchemaLineLegacy(...);
    }
}
```

## Success Criteria

### Functional
- [ ] All 69 files migrated to use JSON library
- [ ] Zero wire protocol changes (byte-level compatibility)
- [ ] All client libraries pass existing tests
- [ ] Geodetestlab pass rate maintained at 97.4%+

### Quality
- [ ] No manual string escaping in codebase
- [ ] No `writeAll("{\"` patterns remain
- [ ] No `allocPrint(..., "{{\"` patterns remain
- [ ] All JSON encoding uses type-safe structs

### Performance
- [ ] No measurable latency increase in query path
- [ ] Memory allocation patterns similar or improved
- [ ] SIMD acceleration utilized where beneficial

## CANARY Markers

Add tracking markers for migration progress:

```zig
// CANARY: REQ=REQ-LIB-MIGRATION-JSON-001; FEATURE="JSON Library Migration"; ASPECT=Protocol; STATUS=IMPL; OWNER=core; UPDATED=2026-01-24
// CANARY: REQ=REQ-LIB-MIGRATION-JSON-002; FEATURE="JSON Library Migration"; ASPECT=Execution; STATUS=PENDING; OWNER=execution; UPDATED=2026-01-24
// CANARY: REQ=REQ-LIB-MIGRATION-JSON-003; FEATURE="JSON Library Migration"; ASPECT=CLI; STATUS=PENDING; OWNER=cli; UPDATED=2026-01-24
// CANARY: REQ=REQ-LIB-MIGRATION-JSON-004; FEATURE="JSON Library Migration"; ASPECT=MCP; STATUS=PENDING; OWNER=mcp; UPDATED=2026-01-24
// CANARY: REQ=REQ-LIB-MIGRATION-JSON-005; FEATURE="JSON Library Migration"; ASPECT=Streaming; STATUS=PENDING; OWNER=streaming; UPDATED=2026-01-24
// CANARY: REQ=REQ-LIB-MIGRATION-JSON-006; FEATURE="JSON Library Migration"; ASPECT=Audit; STATUS=PENDING; OWNER=security; UPDATED=2026-01-24
```

## File Inventory

### Priority 1 - Critical (5 files) - Phase 1 Complete
- [x] `src/protocol.zig` - **COMPLETED** (12 frame builders migrated)
- [x] `src/server/query_executor.zig` - **COMPLETED** (bindingValueRowToJson, writeJsonValue)
- [ ] `src/execution/crud_operations.zig`
- [ ] `src/cli/main.zig`
- [x] `src/server/stdio_message_handler.zig` - **COMPLETED** (error response encoding)

### Priority 2 - High Impact (11 files) - Phase 4 Complete
- [x] `src/mcp/tools.zig` - **COMPLETED** (formatToolResult, formatErrorResponse)
- [x] `src/mcp/resources.zig` - **COMPLETED** (formatResourceResponse, formatResourceError)
- [x] `src/mcp/client.zig` - **COMPLETED** (query, explain - streaming encoder)
- [x] `src/mcp/lsp.zig` - **COMPLETED** (validation, completion, hover responses)
- [x] `src/streaming/cdc_enhanced.zig` - **COMPLETED** (serializeEvent, exportDiagnostics)
- [ ] `src/audit/logger.zig`
- [ ] `src/audit/file_sink.zig`
- [ ] `src/security/audit.zig`
- [ ] `src/security/kms.zig`
- [ ] `src/security/external_kms_client.zig`
- [ ] `src/server/transaction_handlers.zig`

### Priority 3 - Supporting (53 files)
<details>
<summary>Full list of remaining files</summary>

- [ ] `src/distributed/twophase.zig`
- [ ] `src/distributed/raft.zig`
- [ ] `src/distributed/cluster.zig`
- [ ] `src/monitoring/tracing.zig`
- [ ] `src/monitoring/metrics.zig`
- [ ] `src/gpu/telemetry.zig`
- [ ] `src/storage/s3_backup.zig`
- [ ] `src/cli/backup_cli.zig`
- [ ] `src/cli/security/session_storage.zig`
- [ ] `src/types/extended_functions.zig`
- [ ] `src/types/uuid.zig`
- [ ] `src/types/datetime.zig`
- [ ] `src/types/decimal128.zig`
- [ ] `src/types/network/mac.zig`
- [ ] `src/types/cryptographic.zig`
- [ ] `src/util/yaml.zig`
- [ ] `src/index/jsonb_inverted.zig`
- [ ] `src/fle_integration.zig`
- [ ] `src/keys/manager.zig`
- [ ] `src/server/main.zig`
- [ ] `src/server/quic_connection_handler.zig`
- [ ] `src/security/tde_key_manager.zig`
- [ ] `src/security/kms_remote.zig`
- [ ] `src/security/tde.zig`
- [ ] `src/performance/json_optimized.zig`
- [ ] `src/performance/json_optimized_fixed.zig`
- [ ] `src/performance/test_json_optimization.zig`
- [ ] `src/eval_extended.zig`
- [ ] `src/fts/bm25.zig`
- [ ] `src/execution/value_utilities.zig`
- [ ] `src/test_harness.zig`
- [ ] `src/tools/security_progress.zig`
- [ ] `src/tools/implementation_reality_delta.zig`
- [ ] `src/tools/cert_gen.zig`
- [ ] `src/tools/bench_regress.zig`
- [ ] `src/tools/run_variance_benches.zig`
- [ ] `src/tools/fed_latency_aggregate.zig`
- [ ] `src/dist/scaffold.zig`
- [ ] `src/benchmarks/pagination_execution_variance.zig`
- [ ] `src/benchmarks/adaptive_replan_autotune_variance.zig`
- [ ] `src/benchmarks/pagination_variance.zig`
- [ ] `src/client/main.zig`
- [ ] `src/client/repl/repl_dispatch.zig`
- [ ] `src/client/repl/session_state.zig`
- [ ] `src/client/repl/test_repl_advanced_features.zig`
- [ ] `src/execution.zig`
- [ ] `src/schema/catalog.zig`
- [ ] `src/transport/quic.zig`
- [ ] `src/admin/fle_commands.zig`
- [ ] `src/planner/cost_explain.zig`
- [ ] `src/planner/cbo.zig`
- [ ] `src/planner/path_cache.zig`
- [ ] `src/test_harness_old.zig`

</details>

## Appendix A: JSON Library Quick Reference

### Encoding
```zig
const json = @import("json");

// Basic encoding
const str = try json.encode(allocator, my_struct, .{});
defer allocator.free(str);

// Streaming
try json.encodeToWriter(writer, my_struct, .{});

// Pretty print
const pretty = try json.encode(allocator, my_struct, .{ .indent = 2 });
```

### Decoding
```zig
// Unmarshal to struct
const result = try json.unmarshal(MyStruct, allocator, json_input);
defer json.free(MyStruct, allocator, result);

// Parse to Value tree
var doc = try json.parse(allocator, json_input, .{}, null);
defer doc.deinit();
```

### Streaming Encoder
```zig
var encoder = json.streamingEncoder(allocator, writer, .{});
try encoder.beginObject();
try encoder.field("name");
try encoder.string("value");
try encoder.field("count");
try encoder.number(42);
try encoder.endObject();
```

---

## Phase 1 Completion Summary (2026-01-24)

### Files Migrated
1. **`src/protocol.zig`** - Core wire protocol frame builders
   - `buildSchemaLine()` - Uses `json.encode()` with `SchemaResponse` struct
   - `buildBindingsLine()` - Uses streaming encoder for raw JSON embedding
   - `buildExplainLine()` - Uses streaming encoder for raw JSON embedding
   - `buildProfileLine()` - Uses streaming encoder with overflow protection
   - `buildCdcDiagnosticsLine()` - Uses streaming encoder
   - `buildCdcControlLine()` - Uses `json.encode()` with `CdcControlResponse` struct
   - `buildErrorLine()` - Uses `json.encode()` with `ErrorResponse` struct
   - `buildErrorLineWithFlags()` - Uses `json.encode()` with optional fields
   - `buildErrorLineWithFlagsCustomStatus()` - Uses `json.encode()` with status override

2. **`src/server/query_executor.zig`** - Query result serialization
   - `bindingValueRowToJson()` - Uses streaming encoder for dynamic field names
   - `writeJsonValue()` - Added proper RFC 8259 string escaping
   - Added `writeEscapedJsonString()` helper for proper escape sequences
   - Added `formatDecimalValue()` helper for precise decimal representation

3. **`src/server/stdio_message_handler.zig`** - STDIO protocol
   - Error response encoding using `StdioErrorResponse` struct
   - Added `json_lib` import

### Response Type Structs Added
- `SchemaResponse` - SCHEMA frame encoding
- `BindingsResponse` - BINDINGS frame encoding
- `ExplainResponse` - EXPLAIN frame encoding
- `ProfileResponse` - PROFILE frame encoding
- `CdcDiagnosticsResponse` - CDC_DIAGNOSTICS frame encoding
- `CdcControlResponse` - CDC_CONTROL frame encoding
- `ErrorResponse` - ERROR frame encoding
- `StdioErrorResponse` - STDIO error encoding

### CANARY Markers Added
- REQ-LIB-MIGRATION-JSON-002 through REQ-LIB-MIGRATION-JSON-014

### Tests Added
- `TestCANARY_REQ_LIB_MIGRATION_JSON_002_SchemaLineFormat`
- `TestCANARY_REQ_LIB_MIGRATION_JSON_003_BindingsLineFormat`
- `TestCANARY_REQ_LIB_MIGRATION_JSON_007_CdcControlLineFormat`
- `TestCANARY_REQ_LIB_MIGRATION_JSON_008_ErrorLineFormat`
- `TestCANARY_REQ_LIB_MIGRATION_JSON_009_ErrorLineWithFlagsFormat`

### Verification
- Build: **PASSED**
- Unit Tests: **PASSED**
- Wire protocol compatibility: **MAINTAINED**

---

## Phase 4 Completion Summary (2026-01-24)

### Files Migrated
1. **`src/mcp/tools.zig`** - MCP tool responses
   - Added `json_lib` import and `McpToolContent`/`McpToolResult` structs
   - Migrated `formatToolResult()` to use `json.encode()`
   - Migrated `formatErrorResponse()` to use `json.encode()`
   - Removed manual `escapeJsonString` function

2. **`src/mcp/resources.zig`** - MCP resource serialization
   - Added `json_lib` import and `McpResourceResponse`/`McpResourceError` structs
   - Migrated `formatResourceResponse()` to use `json.encode()`
   - Migrated `formatResourceError()` to use `json.encode()`
   - Updated tests to verify JSON library escaping

3. **`src/mcp/client.zig`** - MCP client messages
   - Added `json_lib` import and `ClientRunGqlMessage` struct
   - Migrated `query()` to use streaming encoder for params embedding
   - Migrated `explain()` to use `json.encode()`
   - Removed manual `escapeJsonString` function and related tests

4. **`src/mcp/lsp.zig`** - LSP protocol responses
   - Added `json_lib` import and response type structs:
     - `ValidationResponse`, `DiagnosticJson`
     - `CompletionResponse`, `CompletionItemJson`
     - `HoverResponse`
   - Migrated `formatValidationResponse()` to use `json.encode()`
   - Migrated `formatCompletionResponse()` to use `json.encode()` with optional field handling
   - Migrated `formatHoverResponse()` to use `json.encode()`
   - Removed manual `appendEscaped` and `appendInt` helper functions

5. **`src/streaming/cdc_enhanced.zig`** - CDC event encoding
   - Added `json_lib` import and response type structs:
     - `MalformedSnapshotEntry`, `MalformedHashJsonEntry`
     - `CDCDiagnosticsConfig`, `CDCDiagnosticsEngine`
     - `CDCDiagnosticsResponse`, `CDCChangeEventJson`
   - Migrated `serializeEvent()` to use `json.encode()`
   - Migrated `malformedLogSnapshots()` to use `json.encode()`
   - Migrated `exportDiagnostics()` to use `json.encode()` with nested struct encoding
   - Added `collectMalformedSnapshots()` and `collectMalformedHashes()` helpers
   - Removed manual `writeInt`, `writeFloat`, `writeIntSigned` helpers
   - Removed `MalformedRing.writeJson()` and `MalformedHashStore.writeJson()` methods

### Build Configuration Updated
- Added `json` module to `mcp_cli_mod` in `build.zig`

### CANARY Markers Added
- REQ-LIB-MIGRATION-JSON-042 through REQ-LIB-MIGRATION-JSON-055

### Tests Updated
- Replaced `escapeJsonString` tests with JSON library escaping verification tests
- Updated `appendEscaped` test to verify JSON library handles special characters

### Verification
- Build: **PASSED**
- All migrations use type-safe struct encoding
- Manual JSON string composition eliminated in migrated files

---

## Phase 7 Completion Summary (2026-01-24)

### Files Migrated

1. **`src/server/transaction_handlers.zig`** - Transaction response encoding
   - Added `json_lib` import and response type structs:
     - `TxnStateError` - Transaction state error responses
     - `SerializationError` - MVCC serialization failure responses
     - `CommitError` - Transaction commit failure responses
     - `TxnSuccessResponse` - TXN_BEGIN/COMMIT/ROLLBACK success responses
   - Migrated 8 manual JSON patterns for transaction operations
   - All transaction responses now use type-safe struct encoding

2. **`src/server/query_executor.zig`** - Query operation responses
   - Added `StatusResponse`, `BackupSuccessResponse`, `BackupVerifyResponse` structs
   - Added `encodeStatusResponse()` helper function for consistent formatting
   - Migrated 70+ manual JSON patterns:
     - Index operations (CREATE INDEX, DROP INDEX)
     - Backup operations (BACKUP, RESTORE, VERIFY)
     - Schema operations (CREATE/DROP SCHEMA)
     - Graph operations (CREATE/DROP GRAPH, GRAPH TYPE)
     - Session management (SET/RESET)
   - All query executor responses now use type-safe struct encoding

3. **`src/cli/main.zig`** - CLI error responses
   - Added additional response type structs:
     - `CliStatusError` - Generic status error responses
     - `CliTypeError` - Typed error responses with message
     - `CliResultError` - Result-wrapped error responses
     - `CliColumnDef` - Column definition encoding
   - Migrated 6 manual JSON patterns in QUIC and STDIO server modes
   - All CLI error responses now use type-safe struct encoding

### CANARY Markers Added
- REQ-LIB-MIGRATION-JSON-056 (TransactionHandlers)
- REQ-LIB-MIGRATION-JSON-057 (QueryExecutorResponses)
- REQ-LIB-MIGRATION-JSON-058 (CLIErrorTypes)

### Pattern Migration Summary
- **Total patterns migrated in Phase 7**: ~84 patterns
- **Remaining files with patterns**: 10 files (low-priority: test harness, tools, client, distributed)

### Verification
- Build: **PASSED**
- All migrations use type-safe struct encoding
- Proper memory management with `defer allocator.free()`
- Variable shadowing issues resolved

---

*Document created as part of Geode technical debt reduction initiative.*
*Last updated: 2026-01-24*
