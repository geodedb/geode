const std = @import("std");
const geode = @import("geode");
const schema = @import("schema");

const execution = geode.execution;
const graph_store = geode.graph_store;
const proto_util = geode.proto_util;
const Value = geode.value_types.Value;
const eval_ext = geode.eval_ext;
const arrays = geode.types.arrays;
const geographic = geode.types.geographic;
const range_types = geode.types.range;
const url_types = geode.types.url;

const index_manager_mod = geode.index_manager;
const advanced_optimizer = geode.advanced_types_optimizer;

var test_mutex: std.Thread.Mutex = .{};

// CANARY: REQ=REQ-GQL-ADVANCED-TYPES-GA-001; FEATURE="AdvancedTypesGAConformance"; ASPECT=Integration; STATUS=TESTED; TEST=tests/test_advanced_property_ga_conformance.zig; OWNER=engine; UPDATED=2026-04-01

const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        index_manager_mod.cleanupGlobalIndexManager();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmp.dir.realpathAlloc(allocator, ".");
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        index_manager_mod.cleanupGlobalIndexManager();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, self.allocator);
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.allocator, parsed.program.statements[0], self.ctx);
    }
};

fn nodeHasLabel(node: *const graph_store.Node, label: []const u8) bool {
    for (node.labels) |candidate| {
        if (std.mem.eql(u8, candidate, label)) return true;
    }
    return false;
}

fn findNodeIdByStringProperty(store: *graph_store.GraphStore, label: []const u8, key: []const u8, expected: []const u8) ?u64 {
    var iter = store.nodes.iterator();
    while (iter.next()) |entry| {
        const node = entry.value_ptr;
        if (!nodeHasLabel(node, label)) continue;
        const prop = node.properties.get(key) orelse continue;
        switch (prop) {
            .String => |actual| {
                if (std.mem.eql(u8, actual, expected)) return node.id;
            },
            else => {},
        }
    }
    return null;
}

fn expectNullValue(value: Value) !void {
    switch (value) {
        .Null => {},
        else => return error.ExpectedNull,
    }
}

fn expectTextValue(value: Value, expected: []const u8) !void {
    switch (value) {
        .Str => |actual| try std.testing.expectEqualStrings(expected, actual),
        .Text => |actual| try std.testing.expectEqualStrings(expected, actual),
        else => return error.UnexpectedValueTag,
    }
}

fn expectNumericValue(value: Value, expected: i64) !void {
    switch (value) {
        .Int => |actual| try std.testing.expectEqual(expected, actual),
        .SmallInt => |actual| try std.testing.expectEqual(expected, actual),
        .BigInt => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.UnexpectedValueTag,
    }
}

fn expectUuidValue(value: Value, allocator: std.mem.Allocator, expected: []const u8) !void {
    _ = allocator;
    switch (value) {
        .UUID => |uuid| {
            var buf: [36]u8 = undefined;
            const actual = uuid.toString(&buf);
            try std.testing.expectEqualStrings(expected, actual);
        },
        .ExtValue => |ext| switch (ext) {
            .UUID => |uuid| {
                var buf: [36]u8 = undefined;
                const actual = uuid.toString(&buf);
                try std.testing.expectEqualStrings(expected, actual);
            },
            else => return error.UnexpectedValueTag,
        },
        else => return error.UnexpectedValueTag,
    }
}

fn expectUrlValue(value: Value, expected_host: []const u8) !void {
    switch (value) {
        .Url => |parsed| try std.testing.expectEqualStrings(expected_host, parsed.getHost()),
        .ExtValue => |ext| switch (ext) {
            .Url => |parsed| try std.testing.expectEqualStrings(expected_host, parsed.getHost()),
            else => return error.UnexpectedValueTag,
        },
        else => return error.UnexpectedValueTag,
    }
}

fn expectDomainValue(value: Value, expected: []const u8) !void {
    switch (value) {
        .Domain => |domain| {
            const actual = try domain.toString(std.testing.allocator);
            defer std.testing.allocator.free(actual);
            try std.testing.expectEqualStrings(expected, actual);
        },
        .ExtValue => |ext| switch (ext) {
            .Domain => |domain| {
                const actual = try domain.toString(std.testing.allocator);
                defer std.testing.allocator.free(actual);
                try std.testing.expectEqualStrings(expected, actual);
            },
            else => return error.UnexpectedValueTag,
        },
        else => return error.UnexpectedValueTag,
    }
}

fn expectJsonbContains(value: Value, expected_fragment: []const u8) !void {
    switch (value) {
        .Jsonb => |doc| try std.testing.expect(std.mem.indexOf(u8, doc.data, expected_fragment) != null),
        .ExtValue => |ext| switch (ext) {
            .Jsonb => |doc| try std.testing.expect(std.mem.indexOf(u8, doc.data, expected_fragment) != null),
            else => return error.UnexpectedValueTag,
        },
        else => return error.UnexpectedValueTag,
    }
}

fn expectIntRangeValue(value: Value, lower: i32, upper: i32) !void {
    switch (value) {
        .IntRange => |actual| {
            try std.testing.expectEqual(lower, actual.lower.?);
            try std.testing.expectEqual(upper, actual.upper.?);
        },
        .ExtValue => |ext| switch (ext) {
            .IntRange => |actual| {
                try std.testing.expectEqual(lower, actual.lower.?);
                try std.testing.expectEqual(upper, actual.upper.?);
            },
            else => return error.UnexpectedValueTag,
        },
        else => return error.UnexpectedValueTag,
    }
}

fn expectIpValue(value: Value) !void {
    switch (value) {
        .ExtValue => |ext| switch (ext) {
            .IpAddr => {},
            else => return error.UnexpectedValueTag,
        },
        else => return error.UnexpectedValueTag,
    }
}

fn expectSubnetValue(value: Value, expected_prefix: u8) !void {
    switch (value) {
        .ExtValue => |ext| switch (ext) {
            .Subnet => |subnet| try std.testing.expectEqual(expected_prefix, subnet.prefix_len),
            else => return error.UnexpectedValueTag,
        },
        else => return error.UnexpectedValueTag,
    }
}

fn expectVectorValue(value: Value, expected_dim: u16, expected_first: f32) !void {
    switch (value) {
        .ExtValue => |ext| switch (ext) {
            .VectorF32 => |vec| {
                try std.testing.expectEqual(expected_dim, vec.dim);
                try std.testing.expectEqual(expected_first, vec.data[0]);
            },
            else => return error.UnexpectedValueTag,
        },
        else => return error.UnexpectedValueTag,
    }
}

fn expectIntList(value: Value, expected: []const i64) !void {
    switch (value) {
        .List => |items| {
            try std.testing.expectEqual(expected.len, items.len);
            for (items, expected) |item, want| {
                try expectNumericValue(item, want);
            }
        },
        else => return error.UnexpectedValueTag,
    }
}

test "ga advanced property families round-trip through storage" {
    test_mutex.lock();
    defer test_mutex.unlock();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    {
        var create = try h.exec(
            "CREATE (:AdvancedMatrix {" ++
                "rid: 'matrix'," ++
                "uuidv: UUID('550e8400-e29b-41d4-a716-446655440000')," ++
                "link: Url('HTTP://ExAmple.com:80/a%2F?x=1#f')," ++
                "dom: Domain('example.com')," ++
                "doc: Jsonb('{\"items\":[1,2,3],\"nested\":{\"name\":\"ok\"}}')," ++
                "rng: Range('int4', 1, 4, '[)')," ++
                "ip: IpAddr('10.0.0.5')," ++
                "cidr: Subnet('10.0.0.0/8')," ++
                "embedding: VectorF32('[1.0, 0.0]')" ++
                "})",
        );
        defer create.deinit(allocator);
    }

    var result = try h.exec(
        "MATCH (n:AdvancedMatrix {rid: 'matrix'}) " ++
            "RETURN n.uuidv AS uuidv, n.link AS link, n.dom AS dom, n.doc AS doc, " ++
            "n.rng AS rng, n.ip AS ip, n.cidr AS cidr, n.embedding AS embedding",
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try expectUuidValue(result.rows[0][0], allocator, "550e8400-e29b-41d4-a716-446655440000");
    try expectUrlValue(result.rows[0][1], "example.com");
    try expectDomainValue(result.rows[0][2], "example.com");
    try expectJsonbContains(result.rows[0][3], "\"nested\"");
    try expectIntRangeValue(result.rows[0][4], 1, 4);
    try expectIpValue(result.rows[0][5]);
    try expectSubnetValue(result.rows[0][6], 8);
    try expectVectorValue(result.rows[0][7], 2, 1.0);
}

test "ga relationship all-properties replacement removes stale keys and preserves advanced values" {
    test_mutex.lock();
    defer test_mutex.unlock();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    {
        var create = try h.exec(
            "CREATE (a:RelNode {rid: 'a'})-[r:REL {legacy: 'old', score: SmallInt(1)}]->(b:RelNode {rid: 'b'})",
        );
        defer create.deinit(allocator);
    }

    {
        var replace = try h.exec(
            "MATCH (a:RelNode {rid: 'a'})-[r:REL]->(b:RelNode {rid: 'b'}) " ++
                "SET r = {cidr: Subnet('10.2.0.0/16'), rank: SmallInt(9), dom: Domain('example.com')}",
        );
        defer replace.deinit(allocator);
    }

    var result = try h.exec(
        "MATCH (:RelNode {rid: 'a'})-[r:REL]->(:RelNode {rid: 'b'}) " ++
            "RETURN r.legacy AS legacy, r.cidr AS cidr, r.rank AS rank, r.dom AS dom",
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try expectNullValue(result.rows[0][0]);
    try expectSubnetValue(result.rows[0][1], 16);
    try expectNumericValue(result.rows[0][2], 9);
    try expectDomainValue(result.rows[0][3], "example.com");
}

test "ga advanced runtime indexes populate and vector_knn uses scan and index paths" {
    test_mutex.lock();
    defer test_mutex.unlock();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    {
        var seed = try h.exec(
            "CREATE " ++
                "(v1:VecThing {rid: 'alpha', embedding: VectorF32('[1.0, 0.0]')}), " ++
                "(v2:VecThing {rid: 'beta', embedding: VectorF32('[0.0, 1.0]')}), " ++
                "(v3:VecThing {rid: 'gamma', embedding: VectorF32('[0.7, 0.3]')}), " ++
                "(g:GeoThing {rid: 'geo', point: LatLon(37.7749, -122.4194)}), " ++
                "(n:NetThing {rid: 'net', cidr: Subnet('10.2.0.0/16')}), " ++
                "(r:RangeThing {rid: 'range', span: Range('int4', 10, 20, '[)')}), " ++
                "(d:DocThing {rid: 'doc', payload: Jsonb('{\"a\":1,\"b\":[2,3]}')}), " ++
                "(s:SiteThing {rid: 'site', host: Domain('example.com')})",
        );
        defer seed.deinit(allocator);
    }

    const store = graph_store.getGlobalStore(allocator);
    const alpha_id = findNodeIdByStringProperty(store, "VecThing", "rid", "alpha") orelse return error.NodeNotFound;
    const gamma_id = findNodeIdByStringProperty(store, "VecThing", "rid", "gamma") orelse return error.NodeNotFound;
    const net_id = findNodeIdByStringProperty(store, "NetThing", "rid", "net") orelse return error.NodeNotFound;
    const range_id = findNodeIdByStringProperty(store, "RangeThing", "rid", "range") orelse return error.NodeNotFound;
    const doc_id = findNodeIdByStringProperty(store, "DocThing", "rid", "doc") orelse return error.NodeNotFound;
    const site_id = findNodeIdByStringProperty(store, "SiteThing", "rid", "site") orelse return error.NodeNotFound;

    {
        var pre_index = try h.exec(
            "RETURN vector_knn('embedding', VectorF32('[0.95, 0.05]'), 2, 'cosine') AS ids",
        );
        defer pre_index.deinit(allocator);
        try expectIntList(pre_index.rows[0][0], &[_]i64{ @intCast(alpha_id), @intCast(gamma_id) });
    }

    {
        var idx = try h.exec("CREATE INDEX vec_idx FOR (n:VecThing) ON (n.embedding) USING vector_f32");
        defer idx.deinit(allocator);
    }
    {
        var idx = try h.exec("CREATE INDEX geo_idx FOR (n:GeoThing) ON (n.point) USING spatial_geographic");
        defer idx.deinit(allocator);
    }
    {
        var idx = try h.exec("CREATE INDEX net_idx FOR (n:NetThing) ON (n.cidr) USING network_cidr");
        defer idx.deinit(allocator);
    }
    {
        var idx = try h.exec("CREATE INDEX range_idx FOR (n:RangeThing) ON (n.span) USING interval_tree");
        defer idx.deinit(allocator);
    }
    {
        var idx = try h.exec("CREATE INDEX doc_idx FOR (n:DocThing) ON (n.payload) USING jsonb_inverted");
        defer idx.deinit(allocator);
    }
    {
        var idx = try h.exec("CREATE INDEX domain_idx FOR (n:SiteThing) ON (n.host) USING domain_trie");
        defer idx.deinit(allocator);
    }

    const manager = index_manager_mod.getGlobalIndexManager() orelse return error.MissingIndexManager;
    try std.testing.expect(manager.advanced_vector_indexes.contains("vec_idx"));
    try std.testing.expect(manager.advanced_spatial_indexes.contains("geo_idx"));
    try std.testing.expect(manager.advanced_network_indexes.contains("net_idx"));
    try std.testing.expect(manager.advanced_interval_indexes.contains("range_idx"));
    try std.testing.expect(manager.advanced_jsonb_indexes.contains("doc_idx"));
    try std.testing.expect(manager.advanced_domain_indexes.contains("domain_idx"));
    try std.testing.expectEqualStrings("vec_idx", manager.findAdvancedVectorIndexForProperty("embedding").?);

    {
        var with_index = try h.exec(
            "RETURN vector_knn('embedding', VectorF32('[0.95, 0.05]'), 2, 'cosine') AS ids",
        );
        defer with_index.deinit(allocator);
        try expectIntList(with_index.rows[0][0], &[_]i64{ @intCast(alpha_id), @intCast(gamma_id) });
    }

    const vector_query = vector: {
        const data = [_]f32{ 0.95, 0.05 };
        break :vector geode.types.vector.VectorF32{ .dim = data.len, .data = &data };
    };
    const vector_results = try manager.queryAdvancedVectorIndexWithMetric("vec_idx", vector_query, 2, .cosine);
    defer manager.allocator.free(vector_results);
    try std.testing.expectEqual(@as(usize, 2), vector_results.len);
    try std.testing.expectEqual(alpha_id, vector_results[0].node_id);

    const center = geographic.LatLon.initUnchecked(37.7749, -122.4194);
    const spatial_results = try manager.queryAdvancedSpatialIndex("geo_idx", center, 5.0);
    defer manager.allocator.free(spatial_results);
    try std.testing.expectEqual(@as(usize, 1), spatial_results.len);

    const subnet = geode.heap.Subnet{
        .addr = .{ .v4 = .{ 10, 2, 0, 0 } },
        .prefix_len = 16,
    };
    const network_results = try manager.advanced_network_indexes.get("net_idx").?.searchInSubnet(subnet, allocator);
    defer allocator.free(network_results);
    try std.testing.expectEqual(@as(usize, 1), network_results.len);
    try std.testing.expectEqual(net_id, network_results[0].node_id);

    const overlap = try range_types.IntRange.init(12, 18, .inclusive_exclusive);
    const range_results = try manager.advanced_interval_indexes.get("range_idx").?.tree.queryOverlaps(overlap, allocator);
    defer allocator.free(range_results);
    try std.testing.expectEqual(@as(usize, 1), range_results.len);
    try std.testing.expectEqual(@as(usize, @intCast(range_id)), range_results[0]);

    const jsonb_results = try manager.advanced_jsonb_indexes.get("doc_idx").?.queryPath("a", allocator);
    defer allocator.free(jsonb_results);
    try std.testing.expectEqual(@as(usize, 1), jsonb_results.len);
    try std.testing.expectEqual(@as(usize, @intCast(doc_id)), jsonb_results[0]);

    const query_domain = try url_types.Domain.fromString(allocator, "www.example.com");
    const domain_results = try manager.advanced_domain_indexes.get("domain_idx").?.querySuffix(query_domain, allocator);
    defer allocator.free(domain_results);
    try std.testing.expectEqual(@as(usize, 1), domain_results.len);
    try std.testing.expectEqual(@as(usize, @intCast(site_id)), domain_results[0]);
}

test "ga protocol extended lists and arrays project through the wire boundary" {
    test_mutex.lock();
    defer test_mutex.unlock();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const ext_items = try allocator.alloc(eval_ext.ExtValue, 3);
    ext_items[0] = .{ .Int = 7 };
    ext_items[1] = .{ .Bool = true };
    ext_items[2] = .{ .Text = try allocator.dupe(u8, "wire") };

    const list_value = Value{ .ExtValue = .{ .List = ext_items } };
    var proto_list = try proto_util.valueToProto(allocator, list_value);
    defer proto_list.deinit(allocator);

    const decoded_list = try proto_util.protoValueToValue(allocator, proto_list, 0);
    switch (decoded_list) {
        .List => |items| {
            try std.testing.expectEqual(@as(usize, 3), items.len);
            try expectNumericValue(items[0], 7);
            switch (items[1]) {
                .Bool => |actual| try std.testing.expect(actual),
                else => return error.UnexpectedValueTag,
            }
            try expectTextValue(items[2], "wire");
        },
        else => return error.UnexpectedValueTag,
    }

    var dyn_array = try arrays.DynamicArray.fromInts(allocator, &[_]i64{ 4, 5, 6 });
    defer dyn_array.deinit();
    const array_value = Value{ .ExtValue = .{ .Array = dyn_array } };
    var proto_array_bytes = try proto_util.valueToProto(allocator, array_value);
    defer proto_array_bytes.deinit(allocator);
    const decoded_array_bytes = try proto_util.protoValueToValue(allocator, proto_array_bytes, 0);
    try expectIntList(decoded_array_bytes, &[_]i64{ 4, 5, 6 });

    const annotated_array = schema.Value{
        .kind = .{ .ext_val = .{
            .type_name = "ARRAY",
            .data = .{ .text = "[1, 2, 3]" },
        } },
    };
    const decoded_annotated_array = try proto_util.protoValueToValue(allocator, annotated_array, 0);
    try expectIntList(decoded_annotated_array, &[_]i64{ 1, 2, 3 });
}

test "ga json array member access returns structured values" {
    test_mutex.lock();
    defer test_mutex.unlock();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    var result = try h.exec(
        "RETURN " ++
            "Json('{\"items\":[{\"name\":\"first\"},{\"name\":\"second\"}]}').items[1].name AS picked, " ++
            "Json('{\"items\":[1,2,3]}').items[0] AS first_item",
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try expectTextValue(result.rows[0][0], "second");
    try expectNumericValue(result.rows[0][1], 1);
}

test "ga advanced optimizer reorders vector and spatial index work by effectiveness" {
    test_mutex.lock();
    defer test_mutex.unlock();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var optimizer = advanced_optimizer.AdvancedTypesOptimizer.init(allocator);
    defer optimizer.deinit();

    var plan = advanced_optimizer.QueryPlan.init(allocator);
    defer plan.deinit();

    try plan.operations.append(allocator, .{ .Scan = .{ .table_name = "VecThing", .estimated_rows = 1000 } });
    try plan.operations.append(allocator, .{ .SpatialSearch = .{
        .index_name = "geo_idx",
        .search_type = .radius,
        .radius_km = 250.0,
    } });
    try plan.operations.append(allocator, .{ .VectorSimilarity = .{
        .index_name = "vec_idx",
        .dimension = 8,
        .k = 1,
        .similarity_threshold = 0.99,
    } });

    try optimizer.optimizeQuery(&plan);

    try std.testing.expect(plan.operations.items.len >= 3);
    try std.testing.expect(plan.operations.items[0] == .VectorSimilarity);
    try std.testing.expect(plan.operations.items[1] == .SpatialSearch);
}
