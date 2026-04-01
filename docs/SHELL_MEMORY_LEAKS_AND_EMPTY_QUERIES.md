# Shell Exit Memory Leaks & Empty Query Results

**Date**: 2026-04-01
**Status**: Root causes identified, errdefer fix applied, remaining fixes pending
**Severity**: Medium (memory leaks), High (empty query results)

---

## Issue 1: GPA Memory Leaks on Shell Exit

### Symptoms

When exiting the Geode shell via `/q`, `\quit`, or `Ctrl+C`, the GeneralPurposeAllocator reports ~29 leaked memory addresses. The leak count is consistent across sessions, indicating systematic missing cleanup rather than a race condition.

### Root Cause: Vendor QUIC Library Incomplete Cleanup

**Primary leak site**: `src/transport/quic.zig:862-875` — `QuicClient.deinit()`

The client's `deinit()` calls `api.endpointDeinit(ep)` (line 868) to destroy the QUIC endpoint, then destroys the `quic_config`. However, the vendor QUIC library (`gitlab.com/devnw/zig/quic` v0.1.11) does not fully free all internal allocations during `endpointDeinit`. The ~29 leaked addresses correspond to the endpoint's internal structures:

- Connection tracking state
- TLS session buffers
- Crypto handshake material
- Socket/IO buffers
- ALPN protocol strings
- Stream state arrays

**Evidence**: The leaks are all allocated via the same allocator passed to `api.endpointInit()` at `src/transport/quic.zig:929`. The Geode shell code itself properly cleans up all its own allocations — `QuicTransportConnection`, `TransportConnection`, keepalive thread join, stream close — as verified in:

- `src/client/repl/quic_transport.zig:167-182` (`quicDeinit`)
- `src/client/repl/repl_dispatch.zig:561-595` (`ClientSession.deinit`)
- `src/client/repl/repl_loop.zig:357-364` (`ReplState.deinit`)
- `src/client/repl/repl.zig:155-159` (`History.deinit`)

### Fixed: Missing `errdefer` in Transport Connection Setup

**File**: `src/client/repl/quic_transport.zig:244-248`

Added `errdefer` to free the `QuicTransportConnection` and join the keepalive thread if the subsequent `TransportConnection` allocation fails. Previously, an OOM on line 259 would leak the impl allocation and leave the keepalive thread running.

### Remaining Fix Needed

**Vendor QUIC library** (`/home/benji/src/devnw/zig/quic/`): Audit `endpointDeinit` to ensure all internal allocations are freed. The ~29 leaks are all inside the vendor library. Workaround: wrap the QUIC client endpoint allocator in an `ArenaAllocator`.

---

## Issue 2: Queries Return 0 Rows Despite Data on Disk

### Symptoms

- `/graphs` correctly shows `abs_eagle` graph exists
- `/use abs_eagle` succeeds
- `MATCH (u:User) RETURN ...` returns `(0 rows)`
- Data files exist on disk at `/var/lib/geode`
- Intermittent: one instance showed `(2 rows)`

### Root Cause A: Data Loading Order at Startup

**Files**: `src/server/server_init.zig:219-227`, `src/schema/catalog.zig:348-394`, `src/graph_store.zig:2807-2898`

The server startup has a documented ordering issue (catalog.zig line 387-389): the initial `loadFromFile` during `initGlobalStore` runs before graph engines are opened in the adapter, finding nothing. A second `loadFromFile()` at catalog.zig:390 compensates. If `openOrCreateGraphWithUuid()` (line 376) fails silently for a graph, the second load also finds nothing. The graph name appears in the catalog (so `/graphs` shows it) but no nodes load into memory.

### Root Cause B: Node ID Mismatch (IdMap)

**File**: `src/graph_store.zig:2862-2867`

When loading nodes, slot_ids are mapped to UUIDs via IdMap. If `id_map.bin` is missing or stale (crash before checkpoint), nodes load with wrong IDs, breaking adjacency lookups and MATCH traversal.

### Root Cause C: `getGlobalStore` Re-initialization Race

**File**: `src/graph_store.zig:3676-3745`

The `initialized` flag and `global_store` pointer lack mutex protection. Concurrent threads during startup can race: one thread re-initializes with loaded data while another queries against the empty pre-reinit store. This explains the intermittent behavior.

### Diagnostic Steps

1. Check server logs: `geode serve ... 2>&1 | grep -E "loadFromAdapter|scanned nodes|Failed to"`
2. Check IdMap: `ls -la /var/lib/geode/graphs/abs_eagle/` (look for `id_map.bin`)
3. Verify node count: `RETURN count { MATCH (n) RETURN n } AS total;`
4. Check storage files: `ls -la /var/lib/geode/graphs/abs_eagle/*.store`

### Recommended Fixes

1. Add startup diagnostic logging after catalog.zig:390 — log per-graph node/edge count
2. Add mutex around `getGlobalStore` re-initialization (lines 3704-3744)
3. Validate IdMap consistency during `loadFromAdapter`
4. Add `/stats` shell command for per-graph node/edge counts
