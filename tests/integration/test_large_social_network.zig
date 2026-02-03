const std = @import("std");
const geode = @import("geode");
const testing = std.testing;

// Large-scale social network dataset integration test
// Simulates a social media platform with users, posts, relationships, and events

const SocialNetworkData = struct {
    allocator: std.mem.Allocator,
    graph: *geode.graph_store.GraphStore,
    index_mgr: *geode.index.IndexManager,

    // Node IDs
    users: std.ArrayList(u64),
    posts: std.ArrayList(u64),
    events: std.ArrayList(u64),
    groups: std.ArrayList(u64),

    pub fn init(allocator: std.mem.Allocator) !SocialNetworkData {
        const graph = try allocator.create(geode.graph_store.GraphStore);
        graph.* = geode.graph_store.GraphStore.init(allocator);

        const index_mgr = try allocator.create(geode.index.IndexManager);
        index_mgr.* = geode.index.IndexManager.init(allocator);

        return .{
            .allocator = allocator,
            .graph = graph,
            .index_mgr = index_mgr,
            .users = std.ArrayList(u64).init(allocator),
            .posts = std.ArrayList(u64).init(allocator),
            .events = std.ArrayList(u64).init(allocator),
            .groups = std.ArrayList(u64).init(allocator),
        };
    }

    pub fn deinit(self: *SocialNetworkData) void {
        self.users.deinit();
        self.posts.deinit();
        self.events.deinit();
        self.groups.deinit();
        self.graph.deinit();
        self.allocator.destroy(self.graph);
        self.index_mgr.deinit();
        self.allocator.destroy(self.index_mgr);
    }
};

test "large social network - create schema and indexes" {
    const allocator = std.testing.allocator;

    var data = try SocialNetworkData.init(allocator);
    defer data.deinit();

    // Create indexes for the social network
    try data.index_mgr.createPropertyIndex("user_username_idx", "User", "username", .hash, true);
    try data.index_mgr.createPropertyIndex("user_email_idx", "User", "email", .hash, true);
    try data.index_mgr.createPropertyIndex("user_created_idx", "User", "created_at", .btree, false);
    try data.index_mgr.createPropertyIndex("post_created_idx", "Post", "created_at", .btree, false);
    try data.index_mgr.createFullTextIndex("post_content_idx", "Post", &[_][]const u8{"content"});
    try data.index_mgr.createVectorIndex("post_embedding_idx", "Post", "embedding", 256);
    try data.index_mgr.createSpatialIndex("event_location_idx", "Event", "location");
    try data.index_mgr.createPropertyIndex("group_name_idx", "Group", "name", .btree, false);

    // Verify indexes were created
    try testing.expect(data.index_mgr.statistics.total_indexes == 8);
}

test "large social network - populate 10k users" {
    const allocator = std.testing.allocator;

    var data = try SocialNetworkData.init(allocator);
    defer data.deinit();

    // Create indexes
    try data.index_mgr.createPropertyIndex("user_username_idx", "User", "username", .hash, true);
    try data.index_mgr.createPropertyIndex("user_follower_idx", "User", "follower_count", .btree, false);

    var timer = try std.time.Timer.start();
    timer.reset();

    // Create 10,000 users
    const num_users = 10000;
    var rng = std.rand.DefaultPrng.init(42);
    const random = rng.random();

    var i: u64 = 0;
    while (i < num_users) : (i += 1) {
        const user = try data.graph.createNode(&.{});
        try data.users.append(user);

        const username = try std.fmt.allocPrint(allocator, "user_{}", .{i});
        defer allocator.free(username);
        try data.graph.setNodeProperty(user, "username", .{ .String = username });
        try data.graph.addNodeLabel(user, "User");

        const email = try std.fmt.allocPrint(allocator, "user_{}@example.com", .{i});
        defer allocator.free(email);
        try data.graph.setNodeProperty(user, "email", .{ .String = email });

        const follower_count = random.intRangeAtMost(u32, 0, 100000);
        const followers_str = try std.fmt.allocPrint(allocator, "{}", .{follower_count});
        defer allocator.free(followers_str);
        try data.graph.setNodeProperty(user, "follower_count", .{ .String = followers_str });

        const created = std.time.timestamp() - random.intRangeAtMost(i64, 0, 365 * 24 * 3600);
        const created_str = try std.fmt.allocPrint(allocator, "{}", .{created});
        defer allocator.free(created_str);
        try data.graph.setNodeProperty(user, "created_at", .{ .String = created_str });

        // Add to indexes
        try data.index_mgr.insertIntoPropertyIndex("user_username_idx", username, user);
        try data.index_mgr.insertIntoPropertyIndex("user_follower_idx", followers_str, user);

        // Add verification status for some users (influencers)
        if (follower_count > 10000) {
            try data.graph.setNodeProperty(user, "verified", .{ .String = "true" });
        }
    }

    const creation_time = timer.read();
    std.debug.print("\nCreated {} users in {}ms\n", .{ num_users, creation_time / 1_000_000 });

    try testing.expect(data.users.items.len == num_users);
    try testing.expect(creation_time < 10_000_000_000); // Less than 10 seconds
}

test "large social network - create follow relationships" {
    const allocator = std.testing.allocator;

    var data = try SocialNetworkData.init(allocator);
    defer data.deinit();

    // Create a smaller set of users for relationship testing
    const num_users = 1000;
    var i: u64 = 0;
    while (i < num_users) : (i += 1) {
        const user = try data.graph.createNode(&.{});
        try data.users.append(user);
        try data.graph.addNodeLabel(user, "User");
    }

    var timer = try std.time.Timer.start();
    timer.reset();

    // Create follow relationships (power law distribution)
    var rng = std.rand.DefaultPrng.init(42);
    const random = rng.random();

    var relationships: u64 = 0;
    for (data.users.items) |follower| {
        // Each user follows a random number of others (power law)
        const num_following = random.intRangeAtMost(u32, 1, 50);

        var j: u32 = 0;
        while (j < num_following) : (j += 1) {
            const followed_idx = random.intRangeAtMost(usize, 0, num_users - 1);
            const followed = data.users.items[followed_idx];

            if (follower != followed) {
                const edge = try data.graph.createEdge(follower, followed, "FOLLOWS");

                const timestamp = std.time.timestamp();
                const ts_str = try std.fmt.allocPrint(allocator, "{}", .{timestamp});
                defer allocator.free(ts_str);
                try data.graph.setEdgeProperty(edge, "since", .{ .String = ts_str });

                relationships += 1;
            }
        }
    }

    const relationship_time = timer.read();
    std.debug.print("Created {} relationships in {}ms\n", .{ relationships, relationship_time / 1_000_000 });

    try testing.expect(relationships > num_users); // Should have more edges than nodes
}

test "large social network - posts with embeddings" {
    const allocator = std.testing.allocator;

    var data = try SocialNetworkData.init(allocator);
    defer data.deinit();

    // Create vector index for post embeddings
    try data.index_mgr.createVectorIndex("post_embedding_idx", "Post", "embedding", 128);

    // Create users
    const num_users = 100;
    var i: u64 = 0;
    while (i < num_users) : (i += 1) {
        const user = try data.graph.createNode(&.{});
        try data.users.append(user);
    }

    // Create posts with embeddings
    const num_posts = 5000;
    var rng = std.rand.DefaultPrng.init(42);
    const random = rng.random();

    i = 0;
    while (i < num_posts) : (i += 1) {
        const post = try data.graph.createNode(&.{});
        try data.posts.append(post);
        try data.graph.addNodeLabel(post, "Post");

        const content = try std.fmt.allocPrint(allocator, "Post content {} with hashtags #geode #graphdb", .{i});
        defer allocator.free(content);
        try data.graph.setNodeProperty(post, "content", .{ .String = content });

        // Create random embedding
        var embedding: [128]f32 = undefined;
        for (&embedding) |*val| {
            val.* = random.float(f32);
        }

        // Normalize embedding
        var norm: f32 = 0;
        for (embedding) |val| {
            norm += val * val;
        }
        norm = @sqrt(norm);
        for (&embedding) |*val| {
            val.* /= norm;
        }

        // Add to vector index
        try data.index_mgr.insertIntoVectorIndex("post_embedding_idx", &embedding, post);

        // Link post to author
        const author_idx = random.intRangeAtMost(usize, 0, num_users - 1);
        const author = data.users.items[author_idx];
        const authored = try data.graph.createEdge(author, post, "AUTHORED");
    }

    // Test vector similarity search
    var query_embedding: [128]f32 = undefined;
    for (&query_embedding) |*val| {
        val.* = random.float(f32);
    }

    // Normalize query
    var norm: f32 = 0;
    for (query_embedding) |val| {
        norm += val * val;
    }
    norm = @sqrt(norm);
    for (&query_embedding) |*val| {
        val.* /= norm;
    }

    const similar_posts = try data.index_mgr.knnSearchVectorIndex("post_embedding_idx", &query_embedding, 10);
    defer allocator.free(similar_posts);

    try testing.expect(similar_posts.len == 10);

    // Verify results are sorted by similarity
    for (1..similar_posts.len) |j| {
        try testing.expect(similar_posts[j].score <= similar_posts[j - 1].score);
    }
}

test "large social network - events with spatial data" {
    const allocator = std.testing.allocator;

    var data = try SocialNetworkData.init(allocator);
    defer data.deinit();

    // Create spatial index
    try data.index_mgr.createSpatialIndex("event_location_idx", "Event", "location");

    // Major cities coordinates
    const cities = [_]struct { name: []const u8, lat: f64, lon: f64 }{
        .{ .name = "New York", .lat = 40.7128, .lon = -74.0060 },
        .{ .name = "Los Angeles", .lat = 34.0522, .lon = -118.2437 },
        .{ .name = "Chicago", .lat = 41.8781, .lon = -87.6298 },
        .{ .name = "Houston", .lat = 29.7604, .lon = -95.3698 },
        .{ .name = "Phoenix", .lat = 33.4484, .lon = -112.0740 },
        .{ .name = "Philadelphia", .lat = 39.9526, .lon = -75.1652 },
        .{ .name = "San Antonio", .lat = 29.4241, .lon = -98.4936 },
        .{ .name = "San Diego", .lat = 32.7157, .lon = -117.1611 },
        .{ .name = "Dallas", .lat = 32.7767, .lon = -96.7970 },
        .{ .name = "San Jose", .lat = 37.3382, .lon = -121.8863 },
    };

    // Create events in various cities
    const num_events = 1000;
    var rng = std.rand.DefaultPrng.init(42);
    const random = rng.random();

    var i: u64 = 0;
    while (i < num_events) : (i += 1) {
        const event = try data.graph.createNode(&.{});
        try data.events.append(event);
        try data.graph.addNodeLabel(event, "Event");

        const title = try std.fmt.allocPrint(allocator, "Event_{}", .{i});
        defer allocator.free(title);
        try data.graph.setNodeProperty(event, "title", .{ .String = title });

        // Pick a random city and add some noise to coordinates
        const city_idx = random.intRangeAtMost(usize, 0, cities.len - 1);
        const city = cities[city_idx];

        // Add random offset within ~50km
        const lat_offset = (random.float(f64) - 0.5) * 0.9; // ~50km
        const lon_offset = (random.float(f64) - 0.5) * 0.9;

        const lat = city.lat + lat_offset;
        const lon = city.lon + lon_offset;

        // Create MBR around the point (small area around event)
        const mbr = geode.index.rtree.MBR{
            .min_x = lon - 0.01,
            .min_y = lat - 0.01,
            .max_x = lon + 0.01,
            .max_y = lat + 0.01,
        };

        try data.index_mgr.insertIntoSpatialIndex("event_location_idx", mbr, event);

        try data.graph.setNodeProperty(event, "city", .{ .String = city.name });

        const lat_str = try std.fmt.allocPrint(allocator, "{d:.6}", .{lat});
        defer allocator.free(lat_str);
        try data.graph.setNodeProperty(event, "latitude", .{ .String = lat_str });

        const lon_str = try std.fmt.allocPrint(allocator, "{d:.6}", .{lon});
        defer allocator.free(lon_str);
        try data.graph.setNodeProperty(event, "longitude", .{ .String = lon_str });
    }

    // Search for events near New York
    const ny_region = geode.index.rtree.MBR{
        .min_x = -74.5, // West
        .min_y = 40.4, // South
        .max_x = -73.5, // East
        .max_y = 41.0, // North
    };

    const ny_events = try data.index_mgr.searchSpatialIndex("event_location_idx", ny_region);
    defer allocator.free(ny_events);

    std.debug.print("Found {} events near New York\n", .{ny_events.len});

    // Should find roughly 1/10 of events (since we have 10 cities)
    try testing.expect(ny_events.len > num_events / 20);
    try testing.expect(ny_events.len < num_events / 5);
}

test "large social network - groups and memberships" {
    const allocator = std.testing.allocator;

    var data = try SocialNetworkData.init(allocator);
    defer data.deinit();

    // Create users
    const num_users = 5000;
    var i: u64 = 0;
    while (i < num_users) : (i += 1) {
        const user = try data.graph.createNode(&.{});
        try data.users.append(user);
        try data.graph.addNodeLabel(user, "User");
    }

    // Create groups with various sizes
    const num_groups = 500;
    var rng = std.rand.DefaultPrng.init(42);
    const random = rng.random();

    i = 0;
    while (i < num_groups) : (i += 1) {
        const group = try data.graph.createNode(&.{});
        try data.groups.append(group);
        try data.graph.addNodeLabel(group, "Group");

        const name = try std.fmt.allocPrint(allocator, "Group_{}", .{i});
        defer allocator.free(name);
        try data.graph.setNodeProperty(group, "name", .{ .String = name });

        // Categories: tech, sports, music, gaming, education, etc.
        const categories = [_][]const u8{ "tech", "sports", "music", "gaming", "education", "business", "health", "travel" };
        const category = categories[random.intRangeAtMost(usize, 0, categories.len - 1)];
        try data.graph.setNodeProperty(group, "category", .{ .String = category });

        // Group size (power law distribution)
        const size = random.intRangeAtMost(u32, 10, 10000);
        const size_str = try std.fmt.allocPrint(allocator, "{}", .{size});
        defer allocator.free(size_str);
        try data.graph.setNodeProperty(group, "member_count", .{ .String = size_str });
    }

    // Create memberships
    var memberships: u64 = 0;
    for (data.users.items) |user| {
        // Each user joins 0-20 groups (most join few)
        const num_groups_joined = random.intRangeAtMost(u32, 0, 20);

        var j: u32 = 0;
        while (j < num_groups_joined) : (j += 1) {
            const group_idx = random.intRangeAtMost(usize, 0, num_groups - 1);
            const group = data.groups.items[group_idx];

            const membership = try data.graph.createEdge(user, group, "MEMBER_OF");

            // Add join date
            const days_ago = random.intRangeAtMost(u32, 0, 730); // Up to 2 years
            const join_date = std.time.timestamp() - @as(i64, days_ago * 24 * 3600);
            const date_str = try std.fmt.allocPrint(allocator, "{}", .{join_date});
            defer allocator.free(date_str);
            try data.graph.setEdgeProperty(membership, "joined_at", .{ .String = date_str });

            // Some users are admins
            if (random.float(f32) < 0.05) { // 5% chance
                try data.graph.setEdgeProperty(membership, "role", .{ .String = "admin" });
            } else {
                try data.graph.setEdgeProperty(membership, "role", .{ .String = "member" });
            }

            memberships += 1;
        }
    }

    std.debug.print("Created {} group memberships\n", .{memberships});

    try testing.expect(memberships > num_users); // Most users join at least one group
    try testing.expect(memberships < num_users * 20); // But not more than max
}

test "large social network - complex queries" {
    const allocator = std.testing.allocator;

    var data = try SocialNetworkData.init(allocator);
    defer data.deinit();

    // Set up a smaller but complete social network
    const num_users = 100;

    // Create users with properties
    var i: u64 = 0;
    while (i < num_users) : (i += 1) {
        const user = try data.graph.createNode(&.{});
        try data.users.append(user);
        try data.graph.addNodeLabel(user, "User");

        const username = try std.fmt.allocPrint(allocator, "user_{}", .{i});
        defer allocator.free(username);
        try data.graph.setNodeProperty(user, "username", .{ .String = username });

        // Some users are influencers
        if (i < 10) {
            try data.graph.setNodeProperty(user, "influencer", .{ .String = "true" });
            try data.graph.setNodeProperty(user, "follower_count", .{ .String = "50000" });
        }
    }

    // Create follow network
    var rng = std.rand.DefaultPrng.init(42);
    const random = rng.random();

    // Everyone follows the influencers
    for (data.users.items[10..]) |follower| {
        for (data.users.items[0..10]) |influencer| {
            if (random.float(f32) < 0.7) { // 70% chance
                _ = try data.graph.createEdge(follower, influencer, "FOLLOWS");
            }
        }
    }

    // Regular users follow each other
    for (data.users.items[10..]) |user1| {
        // Follow 5-15 random other users
        const num_follows = random.intRangeAtMost(u32, 5, 15);
        var j: u32 = 0;
        while (j < num_follows) : (j += 1) {
            const idx = random.intRangeAtMost(usize, 10, num_users - 1);
            const user2 = data.users.items[idx];
            if (user1 != user2) {
                _ = try data.graph.createEdge(user1, user2, "FOLLOWS");
            }
        }
    }

    // Test: Find mutual followers (users who follow each other)
    var mutual_follows: u64 = 0;
    for (data.users.items) |user1| {
        const outgoing = try data.graph.getOutgoingEdges(allocator, user1);
        defer allocator.free(outgoing);

        for (outgoing) |edge| {
            const target = edge.to_id;

            // Check if target also follows user1
            const target_outgoing = try data.graph.getOutgoingEdges(allocator, target);
            defer allocator.free(target_outgoing);

            for (target_outgoing) |reverse_edge| {
                const reverse_target = reverse_edge.to_id;
                if (reverse_target == user1) {
                    mutual_follows += 1;
                    break;
                }
            }
        }
    }

    std.debug.print("Found {} mutual follow relationships\n", .{mutual_follows / 2}); // Divide by 2 as we count each pair twice

    // Test: Find influencers (nodes with many incoming edges)
    var influencer_count: u64 = 0;
    for (data.users.items) |user| {
        const incoming = try data.graph.getIncomingEdges(allocator, user);
        defer allocator.free(incoming);

        if (incoming.len > 50) {
            influencer_count += 1;
        }
    }

    std.debug.print("Found {} influencers (>50 followers)\n", .{influencer_count});
    try testing.expect(influencer_count >= 10); // We created 10 influencers
}

test "CANARY: REQ=REQ-GQL-LARGE-DATASET" {
    // CANARY: REQ=REQ-GQL-LARGE-DATASET; FEATURE="LargeDataset"; ASPECT=Scalability; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_LARGE_DATASET; OWNER=team; UPDATED=2025-10-02
    const allocator = std.testing.allocator;

    var data = try SocialNetworkData.init(allocator);
    defer data.deinit();

    // Create comprehensive indexes
    try data.index_mgr.createPropertyIndex("user_id_idx", "User", "id", .hash, true);
    try data.index_mgr.createPropertyIndex("timestamp_idx", "Event", "timestamp", .btree, false);
    try data.index_mgr.createVectorIndex("content_embedding", "Content", "embedding", 64);

    var timer = try std.time.Timer.start();

    // Phase 1: Create nodes
    timer.reset();
    const num_nodes = 50000;
    var i: u64 = 0;
    while (i < num_nodes) : (i += 1) {
        const node = try data.graph.createNode(&.{});

        const id_str = try std.fmt.allocPrint(allocator, "node_{}", .{i});
        defer allocator.free(id_str);

        try data.graph.setNodeProperty(node, "id", .{ .String = id_str });
        try data.index_mgr.insertIntoPropertyIndex("user_id_idx", id_str, node);

        if (i % 10000 == 0) {
            std.debug.print("Created {} nodes...\n", .{i});
        }
    }
    const node_time = timer.read();

    // Phase 2: Create relationships
    timer.reset();
    var rng = std.rand.DefaultPrng.init(42);
    const random = rng.random();

    const num_edges = 100000;
    i = 0;
    while (i < num_edges) : (i += 1) {
        const source = random.intRangeAtMost(u64, 0, num_nodes - 1);
        const target = random.intRangeAtMost(u64, 0, num_nodes - 1);

        if (source != target) {
            _ = try data.graph.createEdge(source, target, "CONNECTED");
        }
    }
    const edge_time = timer.read();

    // Phase 3: Test query performance
    timer.reset();
    const lookup_id = try std.fmt.allocPrint(allocator, "node_{}", .{num_nodes / 2});
    defer allocator.free(lookup_id);

    const found_node = try data.index_mgr.lookupPropertyIndex("user_id_idx", lookup_id);
    const lookup_time = timer.read();

    try testing.expect(found_node != null);

    // Performance assertions
    std.debug.print("\nLarge Dataset Performance:\n", .{});
    std.debug.print("  Created {} nodes in {}ms\n", .{ num_nodes, node_time / 1_000_000 });
    std.debug.print("  Created {} edges in {}ms\n", .{ num_edges, edge_time / 1_000_000 });
    std.debug.print("  Index lookup in {}μs\n", .{lookup_time / 1_000});

    // Performance requirements
    try testing.expect(node_time < 30_000_000_000); // Less than 30 seconds for 50k nodes
    try testing.expect(edge_time < 60_000_000_000); // Less than 60 seconds for 100k edges
    try testing.expect(lookup_time < 1_000_000); // Less than 1ms for indexed lookup
}
