const std = @import("std");

// CANARY: REQ=REQ-QUIC-MUX-004; FEATURE="ActiveStreamRegistry"; ASPECT=ConnectionStreamOwnership; STATUS=IMPL; OWNER=server; UPDATED=2026-04-08
// The first stream is accepted before the acceptor loop starts. Additional
// peer-initiated streams are capped separately to prevent resource exhaustion.
pub const max_additional_streams_per_connection: u32 = 64;
pub const max_total_streams_per_connection: u32 = max_additional_streams_per_connection + 1;

pub const RegistryError = error{
    StreamRegistryFull,
};

pub const ActiveStreamRegistry = struct {
    mu: std.Thread.Mutex = .{},
    len: usize = 0,
    ids: [max_total_streams_per_connection]u64 = [_]u64{0} ** max_total_streams_per_connection,

    pub fn register(self: *ActiveStreamRegistry, stream_id: u64) RegistryError!bool {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.containsLocked(stream_id)) return false;
        if (self.len == self.ids.len) return error.StreamRegistryFull;

        self.ids[self.len] = stream_id;
        self.len += 1;
        return true;
    }

    pub fn unregister(self: *ActiveStreamRegistry, stream_id: u64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.unregisterLocked(stream_id);
    }

    pub fn contains(self: *ActiveStreamRegistry, stream_id: u64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.containsLocked(stream_id);
    }

    pub fn count(self: *ActiveStreamRegistry) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.len;
    }

    fn containsLocked(self: *const ActiveStreamRegistry, stream_id: u64) bool {
        for (self.ids[0..self.len]) |active_stream_id| {
            if (active_stream_id == stream_id) return true;
        }
        return false;
    }

    fn unregisterLocked(self: *ActiveStreamRegistry, stream_id: u64) bool {
        for (self.ids[0..self.len], 0..) |active_stream_id, index| {
            if (active_stream_id == stream_id) {
                self.len -= 1;
                self.ids[index] = self.ids[self.len];
                self.ids[self.len] = 0;
                return true;
            }
        }
        return false;
    }
};
