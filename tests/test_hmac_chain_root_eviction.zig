// Gap 0034 (data-ingest enterprise review, 2026-07-03): fresh-store FALSE
// "POSSIBLE TAMPERING" alarms from the periodic HMAC verifier.
//
// Live signature: an env-bootstrapped FRESH store logs
//   PERIODIC HMAC CHECK FAILED - POSSIBLE TAMPERING error=MissingChainRoot
// every 5 minutes (7-15 alarms per fresh store) while a bulk ingest runs; a
// clean shutdown -> reopen makes the alarms disappear. Cry-wolf risk on the
// one signal that flagged a genuinely corrupted store.
//
// Root cause (NOT a persistence gap): bootstrapDefaultAdmin's sealChain()
// persists the AuthChainRoot node SYNCHRONOUSLY at bootstrap — write-through
// to the engine (graph_store.setNodeProperty's vtable branch) on the
// __geode_security graph, which gap 0026 pins to sync_each_commit. The false
// alarm is a READ-side hole: UserStorageBackend.loadChainRoot resolves the
// root's node id from the (unbounded) label index, then reads the node BODY
// via GraphStore.getNodePtr — a raw lookup on the BOUNDED resident node
// cache (default cap 1M, FIFO eviction). A bulk ingest evicts the
// bootstrap-era chain-root body (oldest inserts first), getNodePtr returns
// null, loadChainRoot returns null, and verifyChain reports
// error.MissingChainRoot — "root missing" — even though the durable engine
// holds a perfectly good root. After a restart the small security graph is
// resident again and nothing evicts it, which is why the alarms vanished on
// reopen.
//
// Fix under test: loadChainRoot reads the node body HYDRATE-ON-MISS
// (GraphStore.getNodePtrHydrated, the node twin of getEdgePtrHydrated), so
// "evicted from the resident cache" is never confused with "missing from
// the store". The tamper signal is PRESERVED: a root that is genuinely
// absent (deleted) or corrupted in the ENGINE still fails verification
// loudly.
//
// RED-first at HEAD:
//   * "evicted chain root must not alarm"       — FAILS (MissingChainRoot)
//   * corrupted-root phase 2 (corrupt + evict)  — FAILS (MissingChainRoot
//     instead of the correct ChainHashMismatch)
// The baseline / deleted-root / corrupted-resident tests pin behavior that
// must not regress with the fix.

const std = @import("std");
const testing = std.testing;

const geode = @import("geode");
const graph_store = geode.graph_store;
const auth_graph_manager = @import("auth_graph_manager");
const AuthGraphManager = auth_graph_manager.AuthGraphManager;

// Zig 0.16: std.process.setEnvVar/std.posix.setenv removed; use libc directly
// (same pattern as tests/test_security_wal_durability.zig).
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const ADMIN_PASSWORD_ENV = "GEODE_ADMIN_PASSWORD";
const DEFAULT_PASSWORD_ENV = "GEODE_DEFAULT_PASSWORD";

fn setEnv(name: [:0]const u8, value: [:0]const u8) !void {
    if (setenv(name.ptr, value.ptr, 1) != 0) return error.SetEnvFailed;
}

fn unsetEnv(name: [:0]const u8) void {
    _ = unsetenv(name.ptr);
}

const HMAC_KEY = [_]u8{0x5a} ** 32;

/// Fresh engine-backed store + bootstrapped AGM. The caller owns teardown:
/// `mgr.deinit()` then `graph_store.deinitGlobalStore()`.
///
/// page_allocator for the store/manager (mirrors the gap0026 suite: the
/// store's global-singleton lifetime does not fit testing.allocator's
/// per-test leak scope); testing.allocator only for the path string.
fn bootstrapFreshStore(data_dir: []const u8) !struct { store: *graph_store.GraphStore, mgr: AuthGraphManager } {
    const pa = std.heap.page_allocator;
    const store = try graph_store.initGlobalStore(pa, data_dir);
    errdefer graph_store.deinitGlobalStore();

    var mgr = try AuthGraphManager.init(pa, store);
    errdefer mgr.deinit();

    const boot = try mgr.bootstrapDefaultAdmin(&HMAC_KEY);
    pa.free(boot.username);
    pa.free(boot.password);

    return .{ .store = store, .mgr = mgr };
}

// ---------------------------------------------------------------------------
// Baseline — the chain root is sealed and readable IMMEDIATELY after an
// env-seeded first-boot bootstrap: the very first periodic verify round on a
// fresh store must pass. (Green at HEAD; pins the "persisted synchronously
// at bootstrap" half of the root-cause analysis.)
// ---------------------------------------------------------------------------
test "gap0034: fresh-store bootstrap seals chain root synchronously; first verify round passes" {
    const ta = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(ta, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer ta.free(data_dir);

    unsetEnv(DEFAULT_PASSWORD_ENV);
    try setEnv(ADMIN_PASSWORD_ENV, "bootpass0034a");
    defer unsetEnv(ADMIN_PASSWORD_ENV);

    var ctx = try bootstrapFreshStore(data_dir);
    defer graph_store.deinitGlobalStore();
    defer ctx.mgr.deinit();

    // The root node exists, is resident, and the chain verifies.
    const root_id = ctx.mgr.storage.chain_root_node orelse return error.ChainRootNotSealedAtBootstrap;
    try testing.expect(ctx.store.getNodePtr(root_id) != null);
    try ctx.mgr.verifyChain(&HMAC_KEY);
}

// ---------------------------------------------------------------------------
// THE gap-0034 reproduction — RED at HEAD.
//
// Evict the chain-root node body from the bounded resident cache exactly the
// way ingest pressure does (unlink + retire; the label index, the AGM's
// in-memory record caches, and the durable ENGINE row are all untouched —
// that is precisely the evicted-but-live state). The periodic verify must
// read the durable truth and pass, NOT alarm MissingChainRoot.
// ---------------------------------------------------------------------------
test "gap0034: chain-root eviction from bounded node cache must not raise MissingChainRoot" {
    const ta = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(ta, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer ta.free(data_dir);

    unsetEnv(DEFAULT_PASSWORD_ENV);
    try setEnv(ADMIN_PASSWORD_ENV, "bootpass0034b");
    defer unsetEnv(ADMIN_PASSWORD_ENV);

    var ctx = try bootstrapFreshStore(data_dir);
    defer graph_store.deinitGlobalStore();
    defer ctx.mgr.deinit();

    const root_id = ctx.mgr.storage.chain_root_node orelse return error.ChainRootNotSealedAtBootstrap;

    // Sanity: verifies while resident.
    try ctx.mgr.verifyChain(&HMAC_KEY);

    // Simulate bulk-ingest cache pressure: unlink+retire the root's node
    // body (BoundedNodeCache.remove is the same unlink+retire path the
    // capacity evictor uses). Prove the pre-fix failure condition holds:
    // the raw resident lookup now misses.
    ctx.store.nodes.remove(root_id);
    try testing.expect(ctx.store.getNodePtr(root_id) == null);

    // RED at HEAD: error.MissingChainRoot (the false "POSSIBLE TAMPERING"
    // alarm). GREEN with the fix: the verifier hydrates the root body from
    // the durable engine and the chain verifies.
    try ctx.mgr.verifyChain(&HMAC_KEY);

    // Harder variant: evict EVERY security-graph node body (users + roles
    // too — a long ingest evicts them all). Per-record HMAC reads already
    // hydrate (getNodeProperty), and with the fix the root does too, so the
    // round still passes.
    var uit = ctx.mgr.storage.user_nodes.valueIterator();
    while (uit.next()) |nid| ctx.store.nodes.remove(nid.*);
    var rit = ctx.mgr.storage.role_nodes.valueIterator();
    while (rit.next()) |nid| ctx.store.nodes.remove(nid.*);
    ctx.store.nodes.remove(root_id);

    try ctx.mgr.verifyChain(&HMAC_KEY);
}

// ---------------------------------------------------------------------------
// Tamper signal preserved #1 — a chain root GENUINELY deleted from the store
// (cache + label index + engine) while credentialed user records exist is
// exactly the tamper case: the loud MissingChainRoot error must remain.
// ---------------------------------------------------------------------------
test "gap0034: genuinely deleted chain root with user records present still raises MissingChainRoot" {
    const ta = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(ta, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer ta.free(data_dir);

    unsetEnv(DEFAULT_PASSWORD_ENV);
    try setEnv(ADMIN_PASSWORD_ENV, "bootpass0034c");
    defer unsetEnv(ADMIN_PASSWORD_ENV);

    var ctx = try bootstrapFreshStore(data_dir);
    defer graph_store.deinitGlobalStore();
    defer ctx.mgr.deinit();

    const root_id = ctx.mgr.storage.chain_root_node orelse return error.ChainRootNotSealedAtBootstrap;
    try ctx.mgr.verifyChain(&HMAC_KEY);

    // Real delete (write-through): removes the node from the resident cache,
    // the label index, AND the engine. User records remain.
    ctx.store.deleteNode(root_id);

    try testing.expect(ctx.mgr.storage.user_cache.count() > 0);
    try testing.expectError(error.MissingChainRoot, ctx.mgr.verifyChain(&HMAC_KEY));
}

// ---------------------------------------------------------------------------
// Tamper signal preserved #2 — a CORRUPTED chain hash fails loudly, both
// while the root body is resident AND after it is evicted (the fix's
// hydrate-on-miss must faithfully rebuild the corrupted value from the
// engine, not mask it). Phase 2 is RED at HEAD for the WRONG reason
// (MissingChainRoot instead of ChainHashMismatch).
// ---------------------------------------------------------------------------
test "gap0034: corrupted chain root hash raises ChainHashMismatch, resident or evicted" {
    const ta = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(ta, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer ta.free(data_dir);

    unsetEnv(DEFAULT_PASSWORD_ENV);
    try setEnv(ADMIN_PASSWORD_ENV, "bootpass0034d");
    defer unsetEnv(ADMIN_PASSWORD_ENV);

    var ctx = try bootstrapFreshStore(data_dir);
    defer graph_store.deinitGlobalStore();
    defer ctx.mgr.deinit();

    const root_id = ctx.mgr.storage.chain_root_node orelse return error.ChainRootNotSealedAtBootstrap;
    try ctx.mgr.verifyChain(&HMAC_KEY);

    // Corrupt the sealed hash (64 hex chars, valid shape, wrong value). The
    // write goes through setNodeProperty, so the ENGINE copy is corrupted
    // too — a faithful stand-in for on-disk tampering.
    const bogus_hash = "ab" ** 32;
    try ctx.store.setNodeProperty(root_id, "chain_hash", .{ .String = bogus_hash });

    // Phase 1 — resident: loud mismatch.
    try testing.expectError(error.ChainHashMismatch, ctx.mgr.verifyChain(&HMAC_KEY));

    // Phase 2 — evicted: the verifier must hydrate the corrupted root from
    // the engine and STILL report the mismatch (RED at HEAD: reports
    // MissingChainRoot, conflating eviction with tampering).
    ctx.store.nodes.remove(root_id);
    try testing.expect(ctx.store.getNodePtr(root_id) == null);
    try testing.expectError(error.ChainHashMismatch, ctx.mgr.verifyChain(&HMAC_KEY));
}
