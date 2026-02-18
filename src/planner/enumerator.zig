const std = @import("std");

// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanEnumerationEngine; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_PlanEnumerationEngine; BENCH=BenchmarkCANARY_REQ_GQL_024_PlanEnumerationVarianceEnvelope; OWNER=planner; UPDATED=2025-09-26
// After tests/bench run this will promote automatically.

pub const LogicalOp = enum {
    scan,
    filter,
    project,
    join,
    aggregate,
    sort,
    limit,
};

pub const LogicalPlan = struct {
    op: LogicalOp,
    children: []LogicalPlan,
};

pub const CandidatePlan = struct {
    cost: f64,
    plan: LogicalPlan,
    // simple hash of structure for collision tracking
    signature: u64,
};

pub const EnumeratorConfig = struct {
    max_plans: usize = 256,
    enable_join_commutativity: bool = true,
    enable_join_associativity: bool = true,
    enable_prune: bool = true,
    // prune_factor: if candidate cost exceeds best_cost * prune_factor, skip exploring its children
    prune_factor: f64 = 4.0,
};

pub const EnumeratorStats = struct {
    generated: usize = 0,
    pruned: usize = 0,
    explored_levels: usize = 0,
    unique_join_signatures: usize = 0, // count of distinct join tree structural signatures
};

pub const PlanEnumerator = struct {
    allocator: std.mem.Allocator,
    config: EnumeratorConfig,
    stats: EnumeratorStats = .{},
    best_cost: f64 = std.math.inf(f64),
    join_sig_set: std.AutoHashMap(u64, void) = undefined,

    pub fn init(alloc: std.mem.Allocator, config: EnumeratorConfig) PlanEnumerator {
        return .{ .allocator = alloc, .config = config, .join_sig_set = std.AutoHashMap(u64, void).init(alloc) };
    }

    pub fn enumerate(self: *PlanEnumerator, root: LogicalPlan, list: *std.ArrayList(CandidatePlan)) !void {
        self.best_cost = std.math.inf(f64);
        self.join_sig_set.clearRetainingCapacity();
        try self.generateArrayList(root, list, 0);
        self.stats.unique_join_signatures = self.join_sig_set.count();
    }

    pub fn enumerateUnmanaged(self: *PlanEnumerator, root: LogicalPlan, gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(CandidatePlan)) !void {
        self.best_cost = std.math.inf(f64);
        self.join_sig_set.clearRetainingCapacity();
        try self.generateUnmanaged(root, gpa, list, 0);
        self.stats.unique_join_signatures = self.join_sig_set.count();
    }

    pub fn selectBestUnmanaged(self: *PlanEnumerator, root: LogicalPlan, gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(CandidatePlan)) !?CandidatePlan {
        // Enumerate (reusing provided buffer) and return lowest cost candidate
        buf.clearRetainingCapacity();
        try self.enumerateUnmanaged(root, gpa, buf);
        if (buf.items.len == 0) return null;
        var best = buf.items[0];
        for (buf.items[1..]) |cp| {
            if (cp.cost < best.cost) best = cp;
        }
        return best;
    }

    fn generateArrayList(self: *PlanEnumerator, node: LogicalPlan, list: *std.ArrayList(CandidatePlan), depth: usize) !void {
        self.stats.explored_levels = @max(self.stats.explored_levels, depth + 1);
        const max_plans = self.config.max_plans;
        if (list.items.len < max_plans) {
            const sig = self.signatureOf(node);
            try list.append(.{ .cost = self.estimateCost(node), .plan = node, .signature = sig });
            self.stats.generated += 1;
            if (list.items[list.items.len - 1].cost < self.best_cost) self.best_cost = list.items[list.items.len - 1].cost;
            if (node.op == .join) _ = try self.join_sig_set.put(sig, {});
        }
        // pruning guard
        if (self.config.enable_prune and self.best_cost < std.math.inf(f64)) {
            const projected = self.estimateCost(node);
            if (projected > self.best_cost * self.config.prune_factor) return; // skip deep exploration
        }
        for (node.children) |child| try self.generateArrayList(child, list, depth + 1);
        if (node.op == .join and node.children.len == 2 and self.config.enable_join_commutativity and list.items.len < max_plans) {
            var swapped = node;
            var buf: [2]LogicalPlan = .{ node.children[1], node.children[0] };
            swapped.children = buf[0..];
            const sig2 = self.signatureOf(swapped);
            try list.append(.{ .cost = self.estimateCost(swapped) * 0.98, .plan = swapped, .signature = sig2 });
            self.stats.generated += 1;
            _ = try self.join_sig_set.put(sig2, {});
        }
    }

    fn generateUnmanaged(self: *PlanEnumerator, node: LogicalPlan, gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(CandidatePlan), depth: usize) !void {
        self.stats.explored_levels = @max(self.stats.explored_levels, depth + 1);
        const max_plans = self.config.max_plans;
        if (list.items.len < max_plans) {
            const sig = self.signatureOf(node);
            try list.append(gpa, .{ .cost = self.estimateCost(node), .plan = node, .signature = sig });
            self.stats.generated += 1;
            if (list.items[list.items.len - 1].cost < self.best_cost) self.best_cost = list.items[list.items.len - 1].cost;
            if (node.op == .join) _ = try self.join_sig_set.put(sig, {});
        }
        if (self.config.enable_prune and self.best_cost < std.math.inf(f64)) {
            const projected = self.estimateCost(node);
            if (projected > self.best_cost * self.config.prune_factor) return;
        }
        for (node.children) |child| try self.generateUnmanaged(child, gpa, list, depth + 1);
        if (node.op == .join and node.children.len == 2 and self.config.enable_join_commutativity and list.items.len < max_plans) {
            var swapped = node;
            var buf: [2]LogicalPlan = .{ node.children[1], node.children[0] };
            swapped.children = buf[0..];
            const sig2 = self.signatureOf(swapped);
            try list.append(gpa, .{ .cost = self.estimateCost(swapped) * 0.98, .plan = swapped, .signature = sig2 });
            self.stats.generated += 1;
            _ = try self.join_sig_set.put(sig2, {});
        }
    }

    fn estimateCost(self: *PlanEnumerator, node: LogicalPlan) f64 {
        // naive structural heuristic cost: op weight + children sum
        var base: f64 = switch (node.op) {
            .scan => 10,
            .filter => 5,
            .project => 3,
            .join => 25,
            .aggregate => 15,
            .sort => 20,
            .limit => 1,
        };
        for (node.children) |c| base += 0.5 * self.estimateCost(c);
        return base;
    }

    fn signatureOf(self: *PlanEnumerator, node: LogicalPlan) u64 {
        var h: u64 = @intFromEnum(node.op) ^ (@as(u64, node.children.len) << 8);
        for (node.children, 0..) |c, i| {
            // simple mixing (not cryptographic)
            h ^= (self.signatureOf(c) +% (@as(u64, i) << 16)) *% 0x9E3779B185EBCA87;
        }
        return h;
    }

    pub fn deinit(self: *PlanEnumerator) void {
        self.join_sig_set.deinit();
    }
};
