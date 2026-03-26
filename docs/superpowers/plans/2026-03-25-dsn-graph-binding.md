# DSN Graph Binding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add graph name support to the DSN so clients can bind a connection to a specific graph at connect time, auto-create the graph if the user has permission, and enforce single-graph isolation for the lifetime of that connection.

**Architecture:** The DSN gains an optional path component (`quic://host:3141/mygraph`) that maps to a new `graph` field on `HelloRequest`. The server resolves the graph during HELLO: validates it exists (or creates it if the user's role allows), sets `session_state.graph`, and marks the session as "graph-bound." A graph-bound session rejects any subsequent `USE GRAPH` statements with a protocol error. Both QUIC and gRPC handlers implement identical logic. The `HelloResponse` gains a `graph` field echoing the resolved graph name back to the client.

**Tech Stack:** Zig 0.15.1, Protobuf (hand-written schema in `src/proto/schema.zig`), QUIC transport, gRPC transport

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `src/proto/geode.proto` | Add `graph` field to `HelloRequest` (field 7) and `HelloResponse` (field 6) |
| Modify | `src/proto/schema.zig` | Add `graph` field to Zig `HelloRequest` and `HelloResponse` structs + descriptor tables |
| Modify | `src/server/server_state.zig` | Add `graph_bound: bool` flag to `ServerState` |
| Modify | `src/server/quic_connection_handler.zig` | HELLO handler: resolve graph, auto-create, set bound flag |
| Modify | `src/transport/grpc_server.zig` | gRPC HELLO handler: same graph resolution logic; pass graph to `createSession` |
| Modify | `src/execution.zig` | `UseGraph` handler: reject when `graph_bound` is true |
| Modify | `src/cli/main.zig` | Extend `DsnParseResult` with `graph` field; parse path from DSN; send in HELLO |
| Modify | `docs/DSN.md` | Document graph path, new proto fields, auto-create semantics, isolation rules |
| Create | `tests/dsn_graph_binding_test.zig` | Unit tests for DSN parsing with graph path |

---

### Task 1: Add `graph` Field to Protobuf Schema

**Files:**

- Modify: `src/proto/geode.proto:77-91`
- Modify: `src/proto/schema.zig:39-59` (HelloRequest), `src/proto/schema.zig:61-79` (HelloResponse)

- [ ] **Step 1: Add graph field to HelloRequest in geode.proto**

In `src/proto/geode.proto`, add field 7 to `HelloRequest` and field 6 to `HelloResponse`:

```proto
message HelloRequest {
  string username = 1;
  string password = 2;
  optional string tenant_id = 3;
  string client_name = 4;
  string client_version = 5;
  string wanted_conformance = 6;
  optional string graph = 7;
}

message HelloResponse {
  bool success = 1;
  string session_id = 2;
  string error_message = 3;
  repeated string capabilities = 4;
  bool password_reset_required = 5;
  optional string graph = 6;
}
```

- [ ] **Step 2: Add graph field to Zig HelloRequest struct**

In `src/proto/schema.zig`, add `graph` to the `HelloRequest` struct and its descriptor table:

```zig
pub const HelloRequest = struct {
    username: []const u8 = "",
    password: []const u8 = "",
    tenant_id: ?[]const u8 = null,
    client_name: []const u8 = "",
    client_version: []const u8 = "",
    wanted_conformance: []const u8 = "",
    graph: ?[]const u8 = null,

    pub const _desc_table = .{
        .username = fd(1, .{ .scalar = .string }),
        .password = fd(2, .{ .scalar = .string }),
        .tenant_id = fd(3, .{ .scalar = .string }),
        .client_name = fd(4, .{ .scalar = .string }),
        .client_version = fd(5, .{ .scalar = .string }),
        .wanted_conformance = fd(6, .{ .scalar = .string }),
        .graph = fd(7, .{ .scalar = .string }),
    };

    pub fn deinit(self: *HelloRequest, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};
```

- [ ] **Step 3: Add graph field to Zig HelloResponse struct**

In `src/proto/schema.zig`, add `graph` to the `HelloResponse` struct and its descriptor table:

```zig
pub const HelloResponse = struct {
    success: bool = false,
    session_id: []const u8 = "",
    error_message: []const u8 = "",
    capabilities: std.ArrayList([]const u8),
    password_reset_required: bool = false,
    graph: ?[]const u8 = null,

    pub const _desc_table = .{
        .success = fd(1, .{ .scalar = .bool }),
        .session_id = fd(2, .{ .scalar = .string }),
        .error_message = fd(3, .{ .scalar = .string }),
        .capabilities = fd(4, .{ .repeated = .{ .scalar = .string } }),
        .password_reset_required = fd(5, .{ .scalar = .bool }),
        .graph = fd(6, .{ .scalar = .string }),
    };

    pub fn deinit(self: *HelloResponse, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};
```

- [ ] **Step 4: Verify build compiles**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -20`
Expected: Compiles without errors (existing tests pass since new fields are optional with defaults)

- [ ] **Step 5: Commit**

```bash
git add src/proto/geode.proto src/proto/schema.zig
git commit -m "feat: add graph field to HelloRequest/HelloResponse protobuf schema"
```

---

### Task 2: Add `graph_bound` Flag to ServerState

**Files:**

- Modify: `src/server/server_state.zig:351-354`

- [ ] **Step 1: Add graph_bound field to ServerState**

In `src/server/server_state.zig`, add `graph_bound` immediately after `current_graph`:

```zig
    // CANARY: REQ=REQ-MULTI-GRAPH-004; FEATURE="MultiGraphSupport"; ASPECT=SessionGraph; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-20
    // Current graph for this session (set by USE GRAPH command)
    current_graph: ?[]const u8 = null,

    // CANARY: REQ=REQ-DSN-GRAPH-BIND-001; FEATURE="DSNGraphBinding"; ASPECT=SessionGraphBound; STATUS=IMPL; OWNER=engine; UPDATED=2026-03-25
    // When true, this session was bound to a graph via DSN/HELLO and USE GRAPH is rejected
    graph_bound: bool = false,
```

- [ ] **Step 2: Verify build compiles**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -20`
Expected: Compiles without errors (new field has default `false`, no callers affected)

- [ ] **Step 3: Commit**

```bash
git add src/server/server_state.zig
git commit -m "feat: add graph_bound flag to ServerState for DSN graph binding"
```

---

### Task 3: Enforce Graph Binding in USE GRAPH Handler

**Files:**

- Modify: `src/execution.zig:1436-1467`
- Test: `tests/dsn_graph_binding_test.zig` (created in this task)

- [ ] **Step 1: Write the failing test**

Create `tests/dsn_graph_binding_test.zig`:

```zig
const std = @import("std");
const execution = @import("../src/execution.zig");
const graph_store = @import("../src/graph_store.zig");
const schema_mod = @import("../src/schema/catalog.zig");

test "USE GRAPH rejected when session is graph-bound" {
    const allocator = std.testing.allocator;

    var session = execution.SessionState.init(allocator);
    defer session.deinit();
    session.graph = try allocator.dupe(u8, "bound_graph");

    var catalog = try schema_mod.Catalog.init(allocator);
    defer catalog.deinit();
    try catalog.addGraph("other_graph");

    var context = execution.ExecutionContext{
        .catalog = &catalog,
        .session_state = &session,
        .graph_bound = true,
    };

    const stmt = execution.Statement{ .UseGraph = .{ .graph_name = "other_graph" } };
    const result = execution.executeStatement(allocator, stmt, &context);

    // Should fail with GraphBoundError
    try std.testing.expectError(error.GraphBound, result);
}

test "USE GRAPH allowed when session is not graph-bound" {
    const allocator = std.testing.allocator;

    var session = execution.SessionState.init(allocator);
    defer session.deinit();

    var catalog = try schema_mod.Catalog.init(allocator);
    defer catalog.deinit();
    try catalog.addGraph("target_graph");

    var context = execution.ExecutionContext{
        .catalog = &catalog,
        .session_state = &session,
        .graph_bound = false,
    };

    const stmt = execution.Statement{ .UseGraph = .{ .graph_name = "target_graph" } };
    const result = try execution.executeStatement(allocator, stmt, &context);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("target_graph", session.graph.?);
}
```

> **Note:** The exact import paths and types may need adjustment based on how `execution.zig` exports its symbols. The test file structure matches the existing test patterns in the `tests/` directory. The `graph_bound` field on `ExecutionContext` doesn't exist yet — that's intentional (RED phase).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test --test-filter "USE GRAPH rejected" 2>&1 | tail -10`
Expected: FAIL — `graph_bound` field doesn't exist on `ExecutionContext`, and `error.GraphBound` is not defined

- [ ] **Step 3: Add graph_bound to ExecutionContext**

In `src/execution.zig`, find the `ExecutionContext` struct (around line 345) and add:

```zig
pub const ExecutionContext = struct {
    catalog: *schema.Catalog,
    user: ?[]const u8 = null,
    role: ?auth.Role = null,
    token: ?[]const u8 = null,
    strict_offset_validation: bool = false,
    session_state: ?*SessionState = null,
    transaction_state: TransactionState = .None,
    query_param_names: []const []const u8 = &.{},
    query_param_values: []const Value = &.{},
    optimizer_hints: ?*OptimizationHints = null,
    graph_bound: bool = false,
};
```

- [ ] **Step 4: Add GraphBound error and enforcement to UseGraph handler**

In `src/execution.zig`, at the top of the `.UseGraph` handler (around line 1436), add the graph-bound check before the existing graph validation:

```zig
        .UseGraph => |ug| {
            // CANARY: REQ=REQ-DSN-GRAPH-BIND-002; FEATURE="DSNGraphBinding"; ASPECT=UseGraphRejection; STATUS=IMPL; OWNER=engine; UPDATED=2026-03-25
            // Reject USE GRAPH when session is bound to a graph via DSN
            if (context.graph_bound) {
                return error.GraphBound;
            }

            // CANARY: REQ=REQ-MULTI-GRAPH-032; FEATURE="MultiGraphIsolation"; ASPECT=UseGraphValidation; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-27
            // USE GRAPH implementation - switch active graph context
            // Must validate graph exists before switching
            const graph_name = ug.graph_name;
            // ... rest of existing handler unchanged ...
```

Also add `GraphBound` to the error set if the function uses an explicit error set. If it uses `!ExecutionResult` (inferred), the error will be added automatically.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test --test-filter "USE GRAPH" 2>&1 | tail -10`
Expected: Both tests PASS

- [ ] **Step 6: Commit**

```bash
git add src/execution.zig tests/dsn_graph_binding_test.zig
git commit -m "feat: reject USE GRAPH when session is graph-bound via DSN"
```

---

### Task 4: QUIC HELLO Handler — Graph Resolution and Auto-Create

**Files:**

- Modify: `src/server/quic_connection_handler.zig:787-860`

This is the core server-side logic. After authentication succeeds, if the HELLO request contains a `graph` field, the server:

1. Checks if the graph exists (catalog + store)
2. If it doesn't exist and the user has Admin or ReadWrite role, creates it
3. If it doesn't exist and the user lacks permission, returns an auth error
4. Sets `state.current_graph` and `state.graph_bound = true`
5. Echoes the graph name in the HelloResponse

- [ ] **Step 1: Add graph resolution logic after authentication in QUIC HELLO handler**

In `src/server/quic_connection_handler.zig`, find the HELLO handler (line 787). After the tenant_id handling block (lines 841-849) and before session_id generation (line 851), add the graph resolution block:

```zig
            // --- existing tenant_id handling ends here (line 849) ---

            // CANARY: REQ=REQ-DSN-GRAPH-BIND-003; FEATURE="DSNGraphBinding"; ASPECT=QuicGraphResolution; STATUS=IMPL; OWNER=transport; UPDATED=2026-03-25
            // Resolve graph from HELLO request — validate, auto-create, bind session
            var resolved_graph: ?[]const u8 = null;
            if (hello_req.graph) |requested_graph| {
                if (requested_graph.len > 0) {
                    const store = graph_store.getGlobalStore(gpa);
                    const cat = if (state.catalog) |c| c else null;

                    const in_store = store.graphExists(requested_graph);
                    const in_catalog = if (cat) |c| c.hasGraph(requested_graph) else false;

                    if (in_store or in_catalog) {
                        // Graph exists — bind session to it
                        if (state.exec_session.graph) |old| gpa.free(old);
                        state.exec_session.graph = try gpa.dupe(u8, requested_graph);
                        state.graph_bound = true;
                        resolved_graph = state.exec_session.graph;
                    } else {
                        // Graph does not exist — check if user can create it
                        const role_val = state.authenticated_role;
                        const can_create = if (role_val) |r| blk: {
                            const role = @as(user_mgmt.Role, @enumFromInt(r));
                            break :blk role == .Admin or role == .ReadWrite;
                        } else !user_mgmt.isAuthEnabled(); // No auth = allow

                        if (can_create) {
                            // Auto-create the graph
                            if (cat) |c| {
                                c.addGraph(requested_graph) catch |err| {
                                    if (err != error.GraphAlreadyExists) {
                                        log.err("Failed to add graph to catalog", &.{
                                            Attr.string("graph", requested_graph),
                                            Attr.string("error", @errorName(err)),
                                        });
                                    }
                                };
                            }
                            _ = store.createGraph(requested_graph) catch |err| {
                                log.debug("Graph storage creation failed", &.{
                                    Attr.string("graph", requested_graph),
                                    Attr.string("error", @errorName(err)),
                                });
                            };

                            if (state.exec_session.graph) |old| gpa.free(old);
                            state.exec_session.graph = try gpa.dupe(u8, requested_graph);
                            state.graph_bound = true;
                            resolved_graph = state.exec_session.graph;
                        } else {
                            // User lacks permission to create graph
                            const resp = schema.QuicServerMessage{ .hello = .{
                                .success = false,
                                .session_id = try gpa.dupe(u8, ""),
                                .error_message = try gpa.dupe(u8, "Graph does not exist and user lacks permission to create it"),
                                .capabilities = caps,
                            } };
                            try sendQuicMessage(gpa, stream, resp);
                            return;
                        }
                    }
                }
            }

            // --- existing session_id generation continues here ---
```

- [ ] **Step 2: Include resolved graph in HelloResponse**

Modify the HelloResponse construction (around line 852-859) to include the graph field:

```zig
            const session_id = try generateSessionId(gpa);
            const resp = schema.QuicServerMessage{ .hello = .{
                .success = true,
                .session_id = session_id,
                .error_message = try gpa.dupe(u8, ""),
                .capabilities = caps,
                .password_reset_required = state.password_reset_required,
                .graph = if (resolved_graph) |g| try gpa.dupe(u8, g) else null,
            } };
            try sendQuicMessage(gpa, stream, resp);
```

- [ ] **Step 3: Wire graph_bound into ExecutionContext construction**

Find where `ExecutionContext` is built in `quic_connection_handler.zig` (around line 1038-1049) and add the `graph_bound` field:

```zig
const exec_context = execution.ExecutionContext{
    .catalog = catalog,
    .user = state.authenticated_user,
    .role = role,
    .token = null,
    .strict_offset_validation = false,
    .session_state = if (state.exec_session) |*s| s else null,
    .transaction_state = if (state.in_txn) .Active else .None,
    .query_param_names = bindings.names,
    .query_param_values = bindings.values,
    .optimizer_hints = if (plan_handle != null) &optimizer_hints_storage else null,
    .graph_bound = state.graph_bound,
};
```

> **Note:** There may be multiple places in the file where `ExecutionContext` is constructed. Search for all `.catalog = catalog,` patterns and add `.graph_bound = state.graph_bound,` to each one.

- [ ] **Step 4: Verify build compiles**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -30`
Expected: Compiles without errors

- [ ] **Step 5: Commit**

```bash
git add src/server/quic_connection_handler.zig
git commit -m "feat: QUIC HELLO handler resolves graph, auto-creates, and binds session"
```

---

### Task 5: gRPC HELLO Handler — Graph Resolution and Auto-Create

**Files:**

- Modify: `src/transport/grpc_server.zig:938-1012`
- Modify: `src/transport/grpc_server.zig:107-137` (createSession)

The gRPC handler follows the same logic as QUIC but uses the `SessionStore` pattern. Graph resolution happens in `handleHandshake`, and the graph + bound flag are passed through `createSession`.

- [ ] **Step 1: Extend createSession to accept graph and graph_bound**

In `src/transport/grpc_server.zig`, modify the `createSession` function signature and body to accept and store the graph:

```zig
pub fn createSession(
    self: *SessionStore,
    username: []const u8,
    password: []const u8,
    role: ?user_mgmt.Role,
    tenant_id: ?[]const u8,
    graph: ?[]const u8,
) ![]const u8 {
    // ... existing session creation logic ...

    // After state initialization, before inserting into sessions map:
    if (graph) |g| {
        if (g.len > 0) {
            state.exec_session.graph = try self.allocator.dupe(u8, g);
            state.graph_bound = true;
        }
    }

    // ... rest of existing logic ...
}
```

- [ ] **Step 2: Add graph resolution to handleHandshake**

In `src/transport/grpc_server.zig`, modify `handleHandshake` (line 938). After authentication succeeds and before creating the session, add graph resolution logic:

```zig
    // After auth_result is obtained (around line 993):

    // CANARY: REQ=REQ-DSN-GRAPH-BIND-004; FEATURE="DSNGraphBinding"; ASPECT=GrpcGraphResolution; STATUS=IMPL; OWNER=transport; UPDATED=2026-03-25
    // Resolve graph from HELLO request
    var resolved_graph: ?[]const u8 = null;
    if (req.graph) |requested_graph| {
        if (requested_graph.len > 0) {
            const gstore = graph_store.getGlobalStore(allocator);
            const graph_exists = gstore.graphExists(requested_graph);

            if (graph_exists) {
                resolved_graph = requested_graph;
            } else {
                // Check if user can create the graph
                const can_create = if (auth_result.role) |r| r == .Admin or r == .ReadWrite else !user_mgmt.isAuthEnabled();

                if (can_create) {
                    _ = gstore.createGraph(requested_graph) catch |err| {
                        log.debug("Graph storage creation failed", &.{
                            Attr.string("graph", requested_graph),
                            Attr.string("error", @errorName(err)),
                        });
                    };
                    resolved_graph = requested_graph;
                } else {
                    const resp = schema.HelloResponse{
                        .success = false,
                        .session_id = "",
                        .error_message = "Graph does not exist and user lacks permission to create it",
                        .capabilities = caps,
                    };
                    return encodeMessage(allocator, resp);
                }
            }
        }
    }

    const session_id = try store.createSession(req.username, req.password, auth_result.role, req.tenant_id, resolved_graph);
    const resp = schema.HelloResponse{
        .success = true,
        .session_id = try allocator.dupe(u8, session_id),
        .error_message = "",
        .capabilities = caps,
        .password_reset_required = auth_result.password_reset_required,
        .graph = if (resolved_graph) |g| try allocator.dupe(u8, g) else null,
    };
    return encodeMessage(allocator, resp);
```

- [ ] **Step 3: Update no-auth session creation call**

The no-auth path (around line 1004) also needs the graph parameter:

```zig
    // No-auth path — same graph resolution applies
    var resolved_graph_noauth: ?[]const u8 = null;
    if (req.graph) |requested_graph| {
        if (requested_graph.len > 0) {
            const gstore = graph_store.getGlobalStore(allocator);
            if (!gstore.graphExists(requested_graph)) {
                _ = gstore.createGraph(requested_graph) catch {};
            }
            resolved_graph_noauth = requested_graph;
        }
    }

    const session_id = try store.createSession("", "", null, req.tenant_id, resolved_graph_noauth);
    const resp = schema.HelloResponse{
        .success = true,
        .session_id = try allocator.dupe(u8, session_id),
        .error_message = "",
        .capabilities = caps,
        .graph = if (resolved_graph_noauth) |g| try allocator.dupe(u8, g) else null,
    };
    return encodeMessage(allocator, resp);
```

- [ ] **Step 4: Wire graph_bound into gRPC ExecutionContext**

Search `grpc_server.zig` for all `ExecutionContext` constructions and add `.graph_bound = entry.state.graph_bound,` to each.

- [ ] **Step 5: Verify build compiles**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -30`
Expected: Compiles without errors

- [ ] **Step 6: Commit**

```bash
git add src/transport/grpc_server.zig
git commit -m "feat: gRPC HELLO handler resolves graph, auto-creates, and binds session"
```

---

### Task 6: Extend CLI DSN Parsing to Support Graph Path

**Files:**

- Modify: `src/cli/main.zig:720-785` (DsnParseResult, parseDsnArg)
- Modify: `src/cli/main.zig:1239+` (cmdQuery — wire graph from DSN into HELLO)
- Modify: `src/cli/main.zig:3610+` (cmdShell — wire graph from DSN into HELLO)

- [ ] **Step 1: Add graph field to DsnParseResult**

In `src/cli/main.zig`, modify the `DsnParseResult` struct (line 722):

```zig
const DsnParseResult = struct {
    host_port: []const u8,
    use_grpc: bool,
    username: ?[]const u8,
    password: ?[]const u8,
    graph: ?[]const u8,
};
```

- [ ] **Step 2: Parse graph path in parseDsnArg**

In `src/cli/main.zig`, modify `parseDsnArg` (line 729). After stripping the query string and extracting credentials, parse the path component. The graph name is the path segment after host:port — e.g., `quic://host:3141/mygraph`.

Find the section where `host_port` is determined (after credential extraction). Before the `return`, add path parsing:

```zig
    // After credentials are extracted, `rest` contains "host:port/graph?params" or "host:port/graph"
    // Query params were already stripped, so `rest` is "host:port/graph" or "host:port"

    // Extract graph from path (everything after first /)
    var graph: ?[]const u8 = null;
    var host_port = rest;
    if (std.mem.indexOf(u8, rest, "/")) |slash_idx| {
        host_port = rest[0..slash_idx];
        const path = rest[slash_idx + 1 ..];
        if (path.len > 0) {
            graph = path;
        }
    }

    return DsnParseResult{
        .host_port = host_port,
        .use_grpc = use_grpc,
        .username = username,
        .password = password,
        .graph = graph,
    };
```

> **Important:** Query parameters are stripped earlier in the function (look for `?` handling). The path parsing must happen AFTER query stripping but the current code strips query params from `rest` before credential extraction. Verify the exact order and adjust accordingly.

- [ ] **Step 3: Wire DSN graph into cmdQuery HELLO message**

In `src/cli/main.zig`, find where DSN is used in `cmdQuery` (around line 1239). The DSN graph should override the `--graph` flag:

```zig
if (dsn) |dsn_str| {
    const parsed = parseDsnArg(dsn_str) orelse {
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    };
    server = parsed.host_port;
    use_grpc = parsed.use_grpc;
    if (parsed.username) |u| user = u;
    if (parsed.password) |p| password = p;
    if (parsed.graph) |g| graph = g;  // DSN graph overrides --graph flag
}
```

Then find where the HELLO message is constructed (search for `HelloRequest` in the query command). Add the `graph` field:

```zig
const hello = schema.HelloRequest{
    .username = user orelse "",
    .password = password orelse "",
    .client_name = "geode-cli",
    .client_version = version_string,
    .graph = graph,
    // ... other existing fields ...
};
```

- [ ] **Step 4: Wire DSN graph into cmdShell HELLO message**

Same pattern in `cmdShell` (around line 3610). Find the HELLO construction and add `.graph = graph,`.

- [ ] **Step 5: Verify build compiles**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -30`
Expected: Compiles without errors

- [ ] **Step 6: Commit**

```bash
git add src/cli/main.zig
git commit -m "feat: CLI DSN parser extracts graph path component and sends in HELLO"
```

---

### Task 7: Handle GraphBound Error in Query Execution Error Mapping

**Files:**

- Modify: `src/server/quic_connection_handler.zig` (error handling in execute path)
- Modify: `src/transport/grpc_server.zig` (error handling in execute path)

The `error.GraphBound` from the execution engine needs to be mapped to a proper protocol error response so the client gets a clear message.

- [ ] **Step 1: Find error mapping in QUIC handler**

In `src/server/quic_connection_handler.zig`, search for where execution errors are caught and mapped to protocol error responses. Look for patterns like `error.GraphNotFound` to find the error mapping block. Add `GraphBound` alongside:

```zig
error.GraphBound => {
    // CANARY: REQ=REQ-DSN-GRAPH-BIND-005; FEATURE="DSNGraphBinding"; ASPECT=GraphBoundError; STATUS=IMPL; OWNER=transport; UPDATED=2026-03-25
    const err_resp = schema.QuicServerMessage{ .execute = .{
        .status = .{ .status_class = "42000", .status_subclass = "" },
        .payload = .{ .error = .{
            .code = "42000",
            .message = try gpa.dupe(u8, "USE GRAPH not allowed: session is bound to a graph via DSN connection string"),
            .type = "ERROR",
            .anchor = "",
        } },
    } };
    try sendQuicMessage(gpa, stream, err_resp);
},
```

> **Note:** The exact error response construction depends on the existing patterns. Match the error format used by `GraphNotFound` or similar execution errors.

- [ ] **Step 2: Add same mapping in gRPC handler**

In `src/transport/grpc_server.zig`, find the execute error handling and add the same `GraphBound` mapping.

- [ ] **Step 3: Verify build compiles**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | head -30`
Expected: Compiles without errors

- [ ] **Step 4: Commit**

```bash
git add src/server/quic_connection_handler.zig src/transport/grpc_server.zig
git commit -m "feat: map GraphBound error to protocol error response in QUIC and gRPC"
```

---

### Task 8: Update DSN Documentation

**Files:**

- Modify: `docs/DSN.md`

- [ ] **Step 1: Update DSN Format section**

Replace the DSN Format section in `docs/DSN.md` with:

```markdown
## DSN Format

```

<scheme>://[<username>:<password>@]<host>[:<port>][/<graph>][?<parameters>]

```

### Alternative Formats

For convenience, these alternative formats are also supported:

```

# Scheme-less (defaults to quic://)

<host>:<port>[/<graph>][?<parameters>]
<host>[/<graph>][?<parameters>]

```
```

- [ ] **Step 2: Add Graph Specification section after Host Specification**

Add after the "Host Specification" section (after line ~63):

```markdown
## Graph Specification

An optional graph name can be specified as a path component after the host and port. When provided, the connection is **bound** to that graph for its entire lifetime.

### Graph Binding Behavior

| Scenario | Result |
|----------|--------|
| Graph exists | Session bound to graph; `USE GRAPH` rejected for session lifetime |
| Graph does not exist + user has Admin/ReadWrite role | Graph auto-created, session bound |
| Graph does not exist + user has ReadOnly/User role | HELLO fails with permission error |
| Graph does not exist + auth disabled | Graph auto-created, session bound |
| No graph in DSN | Normal behavior; `USE GRAPH` allowed as usual |

### Graph Isolation

A graph-bound session enforces **single-graph isolation**:

- All queries execute against the bound graph
- `USE GRAPH` statements return error `42000`: "USE GRAPH not allowed: session is bound to a graph via DSN connection string"
- The graph name is echoed in the `HelloResponse.graph` field

### Examples

```

# Bind to existing graph "social"

quic://localhost:3141/social

# Auto-create graph "analytics" (if user has permission)

quic://admin:secret@localhost:3141/analytics

# gRPC with graph binding

grpc://localhost:50051/social

# With authentication and graph

quic://admin:secret@geode.example.com:3141/myapp?page_size=500

# IPv6 with graph

quic://[::1]:3141/social

```
```

- [ ] **Step 3: Add graph query parameter alias**

In the "Standard Parameters" table, add:

```markdown
| `graph` | string | - | Graph name (alternative to path-based specification) |
```

> **Note:** The path-based format (`/graph`) is the primary format. The query parameter `?graph=name` is reserved for future use by client libraries that may need it. For this implementation, only the path format is supported.

- [ ] **Step 4: Update the Examples section**

Add graph examples to the "Full Examples" section:

```markdown
### With Graph Binding

```

# QUIC with graph (recommended)

quic://localhost:3141/social

# Auto-create graph on connect

quic://admin:secret@localhost:3141/new_project

# gRPC with graph and mTLS

grpc://localhost:50051/analytics?ca=/path/to/ca.crt&cert=/path/to/client.crt&key=/path/to/client.key

# IPv6 with graph

quic://admin:secret@[2001:db8::1]:3141/social

```
```

- [ ] **Step 5: Update Protocol section**

Add a new "Protocol Changes" section before "Environment Variables":

```markdown
## Protocol Changes (v1.1.0)

### HelloRequest

| Field | Number | Type | Description |
|-------|--------|------|-------------|
| `graph` | 7 | optional string | Graph to bind this session to |

### HelloResponse

| Field | Number | Type | Description |
|-------|--------|------|-------------|
| `graph` | 6 | optional string | Resolved graph name (echoed back on success) |

### Auto-Create Semantics

When `graph` is specified in `HelloRequest` and the graph does not exist:

1. Server checks if the authenticated user has `Admin` or `ReadWrite` role
2. If authorized: graph is created (equivalent to `CREATE GRAPH IF NOT EXISTS <name>`) and session is bound
3. If unauthorized: HELLO fails with error "Graph does not exist and user lacks permission to create it"
4. If auth is disabled: graph is always auto-created

### Graph-Bound Session Enforcement

Once a session is graph-bound (via HELLO `graph` field):

- `USE GRAPH` returns SQLSTATE `42000` with message: "USE GRAPH not allowed: session is bound to a graph via DSN connection string"
- `DROP GRAPH` on the bound graph is NOT prevented (DDL operations remain available to authorized users)
- `CREATE GRAPH` for other graphs is NOT prevented (but data operations remain scoped to the bound graph)
```

- [ ] **Step 6: Update Environment Variables table**

Add to the environment variables table:

```markdown
| `GEODE_GRAPH` | Default graph name if not specified in DSN |
```

- [ ] **Step 7: Update Version History**

```markdown
| 1.1.0 | 2026-03-25 | Add graph path support, graph-bound sessions, auto-create semantics |
```

- [ ] **Step 8: Update Client Implementation Reference table**

Update the table to note the graph field:

```markdown
## Client Implementation Reference

| Client | File | Function | Graph Support |
|--------|------|----------|---------------|
| Go | `config.go` | `ParseDSN()` | Parse `/<graph>` path; send in `HelloRequest.graph` |
| Rust | `src/dsn.rs` | `Dsn::parse()` | Parse `/<graph>` path; send in `HelloRequest.graph` |
| Python | `geode_client/transport.py` | `parse_dsn()` | Parse `/<graph>` path; send in `HelloRequest.graph` |
| Zig | `src/config.zig` | `parseDSN()`, `parseDSNStrict()` | Parse `/<graph>` path; send in `HelloRequest.graph` |
| Node.js | `src/config.ts` | `parseDSN()` | Parse `/<graph>` path; send in `HelloRequest.graph` |
```

- [ ] **Step 9: Commit**

```bash
git add docs/DSN.md
git commit -m "docs: update DSN specification with graph path support and binding semantics"
```

---

### Task 9: Integration Test — End-to-End Graph Binding via DSN

**Files:**

- Create: `geodetestlab/specs/dsn_graph_binding.yml` (if geodetestlab supports YAML specs)

This task creates an integration test that exercises the full flow: connect with graph in DSN, verify graph is created, verify USE GRAPH is rejected.

- [ ] **Step 1: Create geodetestlab spec for DSN graph binding**

Check the existing spec format by reading a sample:

Run: `head -50 /home/benji/src/devnw/codepros/geode/geode/geodetestlab/specs/multi_graph.yml`

Then create `geodetestlab/specs/dsn_graph_binding.yml` following that format. The spec should test:

1. **Connect with graph in DSN** — server accepts, graph is created
2. **Query runs against bound graph** — data is isolated
3. **USE GRAPH rejected** — returns error 42000
4. **HelloResponse contains graph** — verify echoed back

> **Note:** The exact spec format depends on the test harness capabilities. The test harness may not support DSN graph binding natively yet (it currently uses `--graph` flag). If the harness passes `--dsn`, the graph will be sent via HELLO. If not, this test may need to use the CLI with `--dsn quic://localhost:{port}/testgraph` directly.

- [ ] **Step 2: Run the spec**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && python3 scripts/test/extended_test_runner.py --spec geodetestlab/specs/dsn_graph_binding.yml 2>&1 | tail -20`

- [ ] **Step 3: Fix any failures**

Address failures by debugging the server-side logic. Common issues:

- Graph store not initialized at HELLO time (check initialization order in `handleQuicConnection`)
- Catalog not available during HELLO (check if `state.catalog` is set before HELLO processing)
- Protobuf encoding issues with optional fields

- [ ] **Step 4: Commit**

```bash
git add geodetestlab/specs/dsn_graph_binding.yml
git commit -m "test: add geodetestlab integration spec for DSN graph binding"
```

---

### Task 10: Verify Full Build and Existing Tests

- [ ] **Step 1: Run full build**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && make build 2>&1 | tail -20`

- [ ] **Step 2: Run unit tests**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && zig build test 2>&1 | tail -30`

- [ ] **Step 3: Run geodetestlab multi_graph spec (regression)**

Run: `cd /home/benji/src/devnw/codepros/geode/geode && python3 scripts/test/extended_test_runner.py --spec geodetestlab/specs/multi_graph.yml 2>&1 | tail -20`

Existing multi_graph tests must still pass — the `graph_bound` default is `false`, so unbound sessions behave identically to before.

- [ ] **Step 4: Fix any regressions**

If any existing tests fail, the most likely cause is:

- New `graph_bound` field on `ExecutionContext` missing from a construction site (search for all `ExecutionContext{` patterns)
- New `graph` parameter on gRPC `createSession` missing from a call site

- [ ] **Step 5: Final commit if fixes needed**

```bash
git add -A
git commit -m "fix: resolve regressions from DSN graph binding implementation"
```
