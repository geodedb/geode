# Cluster Authentication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `GEODE_CLUSTER_TOKEN` authentication to all unauthenticated inter-node communication paths: Raft listener, JOIN_CLUSTER, 2PC transport, and query_transport -- using the same auth pattern already proven in `federation.zig`.

**Architecture:** Reuse `federation.zig:buildFederationHelloRequest()` as the canonical auth builder. Add a shared `cluster_auth.zig` module with `validateClusterToken()` (extracted from `quic_connection_handler.zig:validateFederationAuth`). Wire HELLO handshake into 2PC transport and query_transport. Add token validation to cluster.zig's Raft listener.

**Tech Stack:** Zig 0.15.1, QUIC transport, protobuf `schema.HelloRequest`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/distributed/cluster_auth.zig` | Create | Shared cluster token validation + HELLO builder |
| `src/distributed/cluster.zig` | Modify | Add token validation to networkLoop/handleJoinCluster |
| `src/distributed/twophase.zig` | Modify | Add HELLO handshake to TwoPhaseTransport |
| `src/distributed/query_transport.zig` | Modify | Replace empty credentials with cluster token |
| `src/distributed/federation.zig` | Modify | Delegate to cluster_auth.zig |

---

### Task 1: Extract Shared Cluster Auth Module

**Files:**

- Create: `src/distributed/cluster_auth.zig`

- [ ] **Step 1: Write test for token validation**

```zig
// src/distributed/cluster_auth.zig
const std = @import("std");
const schema = @import("schema");

pub fn validateClusterToken(password: []const u8) bool {
    const expected = std.posix.getenv("GEODE_CLUSTER_TOKEN") orelse return false;
    if (expected.len == 0 or password.len == 0) return false;
    if (password.len != expected.len) return false;
    var buf_a: [256]u8 = [_]u8{0} ** 256;
    var buf_b: [256]u8 = [_]u8{0} ** 256;
    const n = @min(password.len, 256);
    @memcpy(buf_a[0..n], password[0..n]);
    @memcpy(buf_b[0..n], expected[0..n]);
    return std.crypto.timing_safe.eql([256]u8, buf_a, buf_b);
}

pub fn buildClusterHelloRequest(allocator: std.mem.Allocator) schema.HelloRequest {
    const token = std.posix.getenv("GEODE_CLUSTER_TOKEN") orelse {
        return .{ .username = "", .password = "", .tenant_id = null, .client_name = "geode-cluster", .client_version = "", .wanted_conformance = "" };
    };
    const password_copy = allocator.dupe(u8, token) catch {
        return .{ .username = "", .password = "", .tenant_id = null, .client_name = "geode-cluster", .client_version = "", .wanted_conformance = "" };
    };
    return .{ .username = "geode-cluster", .password = password_copy, .tenant_id = null, .client_name = "geode-cluster", .client_version = "", .wanted_conformance = "" };
}

test "validateClusterToken rejects empty" {
    // Without GEODE_CLUSTER_TOKEN set, should reject
    try std.testing.expect(!validateClusterToken("any-token"));
    try std.testing.expect(!validateClusterToken(""));
}
```

- [ ] **Step 2: Run test**

Run: `zig build test`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add src/distributed/cluster_auth.zig
git commit -m "feat(distributed): add shared cluster authentication module"
```

---

### Task 2: Add HELLO Handshake to query_transport.zig

**Files:**

- Modify: `src/distributed/query_transport.zig:604-611`

- [ ] **Step 1: Replace empty credentials with cluster token**

In `query_transport.zig`, find the `Connection.connect()` method (around line 604-611). Replace:

```zig
const hello_req = schema.HelloRequest{
    .username = "",
    .password = "",
    ...
};
```

With:

```zig
const cluster_auth = @import("cluster_auth.zig");
// ... at the top of the file

// In connect(), replace the hello_req construction:
const hello_req = cluster_auth.buildClusterHelloRequest(self.allocator);
```

- [ ] **Step 2: Run test**

Run: `zig build test`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add src/distributed/query_transport.zig
git commit -m "fix(distributed): use cluster token in query_transport HELLO handshake"
```

---

### Task 3: Add HELLO Handshake to 2PC Transport

**Files:**

- Modify: `src/distributed/twophase.zig` (TwoPhaseTransport.getConnection and sendMessage one-shot)

The 2PC transport currently sends raw protobuf without any HELLO handshake. Add a HELLO exchange after QUIC connect.

- [ ] **Step 1: Add HELLO to getConnection (around line 175-190)**

After `try client.waitForHandshake(5);` and getting the stream, add:

```zig
const cluster_auth = @import("cluster_auth.zig");
const s = @import("schema");
// ...

// After getting stream:
const hello_req = cluster_auth.buildClusterHelloRequest(self.allocator);
const hello_msg = s.ServerMessage{ .hello = hello_req };
// Write HELLO using existing writeProtoMessage pattern
try writeProtoMessage(self.allocator, stream, hello_msg);
// Read HELLO response (optional -- server may not send one for 2PC)
```

- [ ] **Step 2: Add HELLO to one-shot sendMessage (around line 340-360)**

Same pattern after QUIC connect in the one-shot path.

- [ ] **Step 3: Run test**

Run: `zig build test`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add src/distributed/twophase.zig
git commit -m "fix(distributed): add cluster token HELLO handshake to 2PC transport"
```

---

### Task 4: Add Token Validation to Cluster Raft Listener

**Files:**

- Modify: `src/distributed/cluster.zig:471-492` (handleQuicConnection)

This is the most critical security fix. Currently the Raft listener accepts any QUIC connection.

- [ ] **Step 1: Add token validation before processing Raft frames**

In `handleQuicConnection`, after accepting the stream, require a HELLO handshake:

```zig
fn handleQuicConnection(self: *ClusterCoordinator, conn: *quic.QuicConnection) !void {
    const stream = try conn.acceptStream();

    // Require cluster token authentication before processing Raft frames
    const cluster_auth = @import("cluster_auth.zig");
    const auth_frame = readProtoMessage(self.allocator, stream) catch |err| {
        log.warn("Raft connection auth failed: no HELLO received", .{});
        return err;
    };
    defer if (auth_frame) |f| self.allocator.free(f);

    // Validate the HELLO contains valid cluster token
    // (simplified: check password field against GEODE_CLUSTER_TOKEN)
    const hello = parseHelloFromFrame(auth_frame) catch {
        log.warn("Raft connection auth failed: invalid HELLO frame", .{});
        return error.AuthenticationFailed;
    };
    if (!cluster_auth.validateClusterToken(hello.password)) {
        log.warn("Raft connection rejected: invalid cluster token", .{});
        return error.AuthenticationFailed;
    }

    // Proceed with Raft frame processing (existing code)
    while (!self.shutdown_flag.load(.acquire)) {
        const frame_res = raft_consensus.readRaftFrame(self.allocator, stream) catch |err| {
            // ... existing error handling
        };
        // ... existing Raft handling
    }
}
```

- [ ] **Step 2: Add token validation to handleJoinCluster**

In `handleJoinCluster` (around line 499), add token check before processing:

```zig
pub fn handleJoinCluster(self: *ClusterCoordinator, msg: *const Message) !Response {
    // Validate cluster token from message metadata
    if (msg.auth_token) |token| {
        if (!cluster_auth.validateClusterToken(token)) {
            return Response{ .status = .UNAUTHORIZED };
        }
    } else {
        return Response{ .status = .UNAUTHORIZED };
    }
    // ... existing join logic
}
```

- [ ] **Step 3: Run test**

Run: `zig build test`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add src/distributed/cluster.zig
git commit -m "fix(distributed): require cluster token for Raft listener and JOIN_CLUSTER"
```

---

### Task 5: Consolidate TLS Environment Variables

**Files:**

- Modify: `src/distributed/cluster_auth.zig` (add TLS config)
- Modify: `src/distributed/federation.zig` (delegate TLS check)

- [ ] **Step 1: Add unified TLS config to cluster_auth.zig**

```zig
pub fn isInsecureModeAllowed() bool {
    const env = std.posix.getenv("GEODE_CLUSTER_INSECURE") orelse return false;
    return std.mem.eql(u8, env, "1");
}
```

- [ ] **Step 2: Update federation.zig to use cluster_auth.isInsecureModeAllowed()**

Replace the `GEODE_FEDERATION_INSECURE` env var check in federation.zig with a call to `cluster_auth.isInsecureModeAllowed()`.

- [ ] **Step 3: Run test and commit**

```bash
zig build test
git add src/distributed/cluster_auth.zig src/distributed/federation.zig
git commit -m "refactor(distributed): consolidate TLS insecure env var to cluster_auth"
```
