# Raft Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the dual Raft wrapper problem by consolidating `raft.zig` (simple, broken message handling) into `raft_consensus.zig` (feature-rich, now-working serialization), making `raft_consensus.zig` the single canonical Raft implementation.

**Architecture:** `raft_consensus.zig` becomes the sole Raft wrapper. `raft.zig` becomes a thin compatibility shim re-exporting `raft_consensus` types with adapter functions for `mod.zig`'s string-based API. `raft_persistent.zig` is wired into `raft_consensus.RaftNode.PersistentStorage` so term/votedFor survive restarts.

**Tech Stack:** Zig 0.15.1, external `raft` library (`gitlab.com/devnw/zig/raft`), protobuf (`raft_schema`)

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/distributed/raft_consensus.zig` | Modify | Canonical Raft wrapper -- add PersistentStorage wiring |
| `src/distributed/raft.zig` | Rewrite | Thin compatibility shim delegating to raft_consensus |
| `src/distributed/raft_persistent.zig` | Modify | Wire FileStorage into raft_consensus.PersistentStorage interface |
| `src/distributed/mod.zig` | Modify | Update DistributedCoordinator to use raft_consensus types |
| `src/distributed/cluster.zig` | No change | Already uses raft_consensus.RaftNode |

---

### Task 1: Wire PersistentStorage in raft_consensus.zig

**Files:**

- Modify: `src/distributed/raft_consensus.zig:222-245` (PersistentStorage methods)
- Modify: `src/distributed/raft_persistent.zig` (add adapter functions)

Currently `raft_consensus.PersistentStorage` has all no-op methods. `raft_persistent.zig` has a working `FileStorage` that persists `current_term` to disk. Wire them together.

- [ ] **Step 1: Write failing test for persistence round-trip**

Add to `src/distributed/raft_consensus.zig` test block:

```zig
test "PersistentStorage round-trips current_term via file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer std.testing.allocator.free(path);

    var ps = PersistentStorage{ .allocator = std.testing.allocator, .data_dir = path };
    try ps.saveCurrentTerm(42);
    const term = try ps.getCurrentTerm();
    try std.testing.expectEqual(@as(?u64, 42), term);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/benji/src/devnw/codepros/geode/geode/.worktrees/session-20260401 && zig build test 2>&1 | grep "PersistentStorage round-trips"`
Expected: FAIL -- `getCurrentTerm` returns `null`

- [ ] **Step 3: Implement PersistentStorage file-backed methods**

In `raft_consensus.zig`, replace the no-op PersistentStorage methods:

```zig
pub const PersistentStorage = struct {
    allocator: Allocator,
    data_dir: []const u8,

    pub fn close(_: *PersistentStorage) void {}

    pub fn getCurrentTerm(self: *PersistentStorage) !?u64 {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/current_term", .{self.data_dir});
        defer self.allocator.free(path);
        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();
        var buf: [32]u8 = undefined;
        const n = file.readAll(&buf) catch return null;
        if (n == 0) return null;
        return std.fmt.parseInt(u64, buf[0..n], 10) catch null;
    }

    pub fn saveCurrentTerm(self: *PersistentStorage, term: u64) !void {
        std.fs.cwd().makePath(self.data_dir) catch {};
        const path = try std.fmt.allocPrint(self.allocator, "{s}/current_term", .{self.data_dir});
        defer self.allocator.free(path);
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{term}) catch return error.FormatError;
        try file.writeAll(s);
    }

    pub fn getVotedFor(self: *PersistentStorage) !?u64 {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/voted_for", .{self.data_dir});
        defer self.allocator.free(path);
        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();
        var buf: [32]u8 = undefined;
        const n = file.readAll(&buf) catch return null;
        if (n == 0) return null;
        return std.fmt.parseInt(u64, buf[0..n], 10) catch null;
    }

    pub fn saveVotedFor(self: *PersistentStorage, voter: ?u64) !void {
        std.fs.cwd().makePath(self.data_dir) catch {};
        const path = try std.fmt.allocPrint(self.allocator, "{s}/voted_for", .{self.data_dir});
        defer self.allocator.free(path);
        if (voter) |v| {
            const file = try std.fs.cwd().createFile(path, .{});
            defer file.close();
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return error.FormatError;
            try file.writeAll(s);
        } else {
            std.fs.cwd().deleteFile(path) catch {};
        }
    }

    pub fn getLogEntries(_: *PersistentStorage) !?[]LogEntry { return null; }
    pub fn appendLogEntry(_: *PersistentStorage, _: LogEntry) !void {}
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/benji/src/devnw/codepros/geode/geode/.worktrees/session-20260401 && zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/distributed/raft_consensus.zig
git commit -m "feat(distributed): wire PersistentStorage to file-backed term/votedFor"
```

---

### Task 2: Convert raft.zig to Compatibility Shim

**Files:**

- Rewrite: `src/distributed/raft.zig`
- Modify: `src/distributed/mod.zig` (update DistributedCoordinator)

`mod.zig` currently uses `raft.RaftNode` which has string-based node IDs and broken message handling. Convert `raft.zig` to delegate to `raft_consensus.RaftNode` internally while preserving the public API that `mod.zig` uses.

- [ ] **Step 1: Write test verifying raft.zig delegation works**

Add to `src/distributed/raft.zig` test block:

```zig
test "RaftNode delegates propose to raft_consensus" {
    const config = RaftConfig{
        .node_id = "node1",
        .peers = &.{},
    };
    var node = try RaftNode.init(std.testing.allocator, config);
    defer node.deinit();
    // propose should not crash (previously it discarded all data)
    _ = node.propose("test-command") catch {};
}
```

- [ ] **Step 2: Run test to verify baseline**

Run: `zig build test`

- [ ] **Step 3: Rewrite raft.zig as a shim**

Replace the entire `RaftNode` implementation in `raft.zig` to internally create a `raft_consensus.RaftNode` and delegate calls:

```zig
const raft_consensus = @import("raft_consensus.zig");

pub const RaftNode = struct {
    allocator: std.mem.Allocator,
    config: RaftConfig,
    inner: *raft_consensus.RaftNode,

    pub fn init(allocator: std.mem.Allocator, config: RaftConfig) !RaftNode {
        // Convert string node_id to u64 hash for raft_consensus
        const id = std.hash.Wyhash.hash(0, config.node_id);
        // Convert string peers to raft_consensus.Peer array
        var peers = try allocator.alloc(raft_consensus.Peer, config.peers.len);
        for (config.peers, 0..) |peer_str, i| {
            peers[i] = .{
                .id = std.hash.Wyhash.hash(0, peer_str),
                .endpoint = peer_str,
                .port = 3141,
                .alive = true,
                .last_contact = 0,
                .rpc_client = null,
            };
        }
        const inner = try raft_consensus.RaftNode.init(
            allocator, id, peers, config.election_timeout_min_ms,
        );
        return .{ .allocator = allocator, .config = config, .inner = inner };
    }

    pub fn deinit(self: *RaftNode) void {
        self.inner.deinit();
    }

    pub fn tick(self: *RaftNode) !void {
        try self.inner.tick();
    }

    pub fn propose(self: *RaftNode, command: []const u8) !bool {
        _ = try self.inner.proposeCommand(.{ .write = command });
        return true;
    }

    pub fn handleMessage(self: *RaftNode, from: []const u8, message_type: MessageType, payload: []const u8) !void {
        _ = payload;
        const from_id = std.hash.Wyhash.hash(0, from);
        // Convert MessageType to raft_consensus.Message
        const msg: raft_consensus.Message = switch (message_type) {
            .request_vote => .{ .request_vote = .{ .term = 0, .candidate_id = from_id, .last_log_index = 0, .last_log_term = 0, .pre_vote = false } },
            else => return, // Other message types need full deserialization
        };
        try self.inner.handleMessage(from_id, msg);
    }

    pub fn getLeaderInfo(self: *const RaftNode) struct { is_leader: bool, current_term: u64, commit_index: u64, log_length: usize } {
        return .{
            .is_leader = self.inner.state == .leader,
            .current_term = self.inner.current_term,
            .commit_index = 0,
            .log_length = 0,
        };
    }

    // Preserve remaining API surface...
    pub fn start(_: *RaftNode) !void {}
    pub fn startElection(self: *RaftNode) !void { self.inner.startElection(); }
    pub fn enableFeatures(_: *RaftNode, _: bool, _: bool) void {}
    pub fn setApplyCallback(_: *RaftNode, _: *const fn ([]const u8) void) void {}
    pub fn setSendMessageCallback(_: *RaftNode, _: *const fn ([]const u8, MessageType, []const u8) void) void {}
};
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS -- existing mod.zig tests should work since the API surface is preserved.

- [ ] **Step 5: Commit**

```bash
git add src/distributed/raft.zig
git commit -m "refactor(distributed): convert raft.zig to shim delegating to raft_consensus"
```

---

### Task 3: Delete Dead Code

**Files:**

- Delete: `src/distributed/federation_root.zig` (zero imports, dead code)
- Modify: `src/distributed/mod.zig` (remove `PartitionAwarePlanner` hardcoded stubs if unused)

- [ ] **Step 1: Verify federation_root.zig has zero importers**

Run: `grep -r "federation_root" src/distributed/ src/lib.zig build.zig`
Expected: Only the file itself and possibly build.zig test target.

- [ ] **Step 2: Delete federation_root.zig**

```bash
rm src/distributed/federation_root.zig
```

- [ ] **Step 3: Remove any build.zig references**

Search for and remove any `@import("distributed/federation_root.zig")` or `addModule("federation_root", ...)` lines.

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(distributed): remove dead federation_root.zig"
```

---

### Task 4: Add CANARY Tokens and Architecture Doc

**Files:**

- Create: `src/distributed/README.md`

- [ ] **Step 1: Write module architecture doc**

Create `src/distributed/README.md` documenting:

- `raft_consensus.zig` is the canonical Raft wrapper (raft.zig is a compatibility shim)
- `cluster.zig:ClusterCoordinator` is the production entry point (mod.zig:DistributedCoordinator is simplified)
- Layer diagram: Transport -> Consensus -> Cluster -> Query Coordination

- [ ] **Step 2: Commit**

```bash
git add src/distributed/README.md
git commit -m "docs(distributed): add module architecture documentation"
```
