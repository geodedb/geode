// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Thin thread-local sentinel for the ShardedCoordinator shard-worker threads.
//!
//! Kept as a standalone leaf file (no imports) so that modules with disjoint
//! dependency graphs (e.g. src/transactions/manager.zig via the `txn` build
//! module) can read the flag without pulling in the full group_commit.zig
//! transitive closure and triggering a "file exists in modules" error.
//!
//! group_commit.zig's shardLoop sets/clears this on entry/exit.
//! manager.zig reads it in the Debug-only write-write conflict guard.

pub threadlocal var t_is_shard_worker: bool = false;
