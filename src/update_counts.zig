// CANARY: REQ=REQ-SONNY-2822-UPDATE-COUNTS; FEATURE="WireProtocol"; ASPECT=StatementUpdateCounts; STATUS=TESTED; TEST=tests/test_sonny2822_update_counts.zig; OWNER=execution; UPDATED=2026-11-22
//! SONNY-2822: what a statement changed, for the `update_counts` of its
//! result's final DataPage (src/proto/geode.proto `UpdateCounts`).
//!
//! The counts are made where the writes are, never inferred from result
//! rows: the statement undo record counts each change it records
//! (`statement_undo.append` / `appendCreated`, which every graph-store write
//! method feeds while a statement is open), and the QUIC write fast paths,
//! which skip the record, count what their adapter primitive reports. A
//! statement's counts reach this thread's tally (`noteCommitted`) only once
//! it succeeded; a failed statement's undo is not counted (capture is
//! suspended for it), and a ROLLBACK in the same program takes back what the
//! transaction body counted (`execution.executeProgramInScratch`).
//!
//! Semantics follow the openCypher / Bolt query statistics: a SET or a
//! REMOVE of a property each count one `properties_set` (setting a property
//! to the value it holds too; removing one the node lacks changes nothing);
//! a created node counts its labels in `labels_added` and its properties in
//! `properties_set`; a deleted node or relationship counts nothing else.

const std = @import("std");
const txn_undo_log = @import("txn_undo_log.zig");

pub const UpdateCounts = struct {
    nodes_created: u64 = 0,
    nodes_deleted: u64 = 0,
    relationships_created: u64 = 0,
    relationships_deleted: u64 = 0,
    properties_set: u64 = 0,
    labels_added: u64 = 0,
    labels_removed: u64 = 0,

    pub fn add(self: *UpdateCounts, other: UpdateCounts) void {
        inline for (@typeInfo(UpdateCounts).@"struct".fields) |f| {
            @field(self, f.name) +|= @field(other, f.name);
        }
    }

    /// The change one undo entry records.
    pub fn countEntry(self: *UpdateCounts, entry: txn_undo_log.UndoEntry) void {
        switch (entry) {
            .CreateNode => self.nodes_created +|= 1,
            .CreateEdge => self.relationships_created +|= 1,
            .DeleteNode => self.nodes_deleted +|= 1,
            .DeleteEdge => self.relationships_deleted +|= 1,
            .SetNodeProperty, .SetEdgeProperty, .RemoveNodeProperty, .RemoveEdgeProperty => self.properties_set +|= 1,
            .AddNodeLabel => self.labels_added +|= 1,
            .RemoveNodeLabel => self.labels_removed +|= 1,
        }
    }
};

/// The counts of the statements this thread's program committed so far.
threadlocal var t_committed: UpdateCounts = .{};

/// A statement of this thread succeeded with `counts`.
pub fn noteCommitted(counts: UpdateCounts) void {
    t_committed.add(counts);
}

/// The tally so far (a mark `restore` can go back to).
pub fn committed() UpdateCounts {
    return t_committed;
}

/// Go back to `mark` (a ROLLBACK took back what was counted since).
pub fn restore(mark: UpdateCounts) void {
    t_committed = mark;
}

/// Start a program's tally; returns the enclosing one, for `endProgram`.
pub fn beginProgram() UpdateCounts {
    const outer = t_committed;
    t_committed = .{};
    return outer;
}

/// End a program's tally: its counts, with the enclosing tally restored
/// and the program's counts added to it.
pub fn endProgram(outer: UpdateCounts) UpdateCounts {
    const mine = t_committed;
    t_committed = outer;
    t_committed.add(mine);
    return mine;
}
