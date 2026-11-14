const std = @import("std");
const geode = @import("geode");
const testing = std.testing;

// IoT and Network Device Dataset Integration Test
// Simulates an enterprise network with devices, sensors, and network segments

const NetworkData = struct {
    allocator: std.mem.Allocator,
    graph: *geode.graph_store.GraphStore,
    index_mgr: *geode.index.IndexManager,

    // Node IDs
    devices: std.ArrayList(u64),
    sensors: std.ArrayList(u64),
    routers: std.ArrayList(u64),
    subnets: std.ArrayList(u64),
    datacenters: std.ArrayList(u64),

    pub fn init(allocator: std.mem.Allocator) !NetworkData {
        const graph = try allocator.create(geode.graph_store.GraphStore);
        graph.* = try geode.graph_store.GraphStore.init(allocator);

        const index_mgr = try allocator.create(geode.index.IndexManager);
        index_mgr.* = geode.index.IndexManager.init(allocator);

        return .{
            .allocator = allocator,
            .graph = graph,
            .index_mgr = index_mgr,
            .devices = std.ArrayList(u64).init(allocator),
            .sensors = std.ArrayList(u64).init(allocator),
            .routers = std.ArrayList(u64).init(allocator),
            .subnets = std.ArrayList(u64).init(allocator),
            .datacenters = std.ArrayList(u64).init(allocator),
        };
    }

    pub fn deinit(self: *NetworkData) void {
        self.devices.deinit();
        self.sensors.deinit();
        self.routers.deinit();
        self.subnets.deinit();
        self.datacenters.deinit();
        self.graph.deinit();
        self.allocator.destroy(self.graph);
        self.index_mgr.deinit();
        self.allocator.destroy(self.index_mgr);
    }
};

test "IoT network - create schema and specialized indexes" {
    const allocator = std.testing.allocator;

    var data = try NetworkData.init(allocator);
    defer data.deinit();

    // Network-specific indexes
    try data.index_mgr.createPropertyIndex("device_ip_idx", "Device", "ip_address", .hash, true);
    try data.index_mgr.createPropertyIndex("device_mac_idx", "Device", "mac_address", .hash, true);
    try data.index_mgr.createPropertyIndex("subnet_cidr_idx", "Subnet", "cidr", .btree, false);
    try data.index_mgr.createSpatialIndex("sensor_location_idx", "Sensor", "location");
    try data.index_mgr.createPropertyIndex("device_status_idx", "Device", "status", .hash, false);
    try data.index_mgr.createPropertyIndex("alert_severity_idx", "Alert", "severity", .btree, false);
    try data.index_mgr.createPropertyIndex("traffic_timestamp_idx", "Traffic", "timestamp", .btree, false);

    // Verify indexes were created
    try testing.expect(data.index_mgr.statistics.total_indexes == 7);
}

test "IoT network - populate network topology" {
    const allocator = std.testing.allocator;

    var data = try NetworkData.init(allocator);
    defer data.deinit();

    // Create indexes
    try data.index_mgr.createPropertyIndex("device_ip_idx", "Device", "ip_address", .hash, true);
    try data.index_mgr.createPropertyIndex("subnet_cidr_idx", "Subnet", "cidr", .btree, false);

    // Create datacenters
    const dc_locations = [_]struct { name: []const u8, region: []const u8, lat: f64, lon: f64 }{
        .{ .name = "DC-US-EAST", .region = "us-east-1", .lat = 38.7469, .lon = -77.4758 },
        .{ .name = "DC-US-WEST", .region = "us-west-1", .lat = 37.4419, .lon = -122.1430 },
        .{ .name = "DC-EU-WEST", .region = "eu-west-1", .lat = 53.4059, .lon = -6.2256 },
        .{ .name = "DC-AP-SOUTH", .region = "ap-south-1", .lat = 19.0760, .lon = 72.8777 },
    };

    for (dc_locations) |dc| {
        const datacenter = try data.graph.createNode(&.{});
        try data.datacenters.append(datacenter);
        try data.graph.addNodeLabel(datacenter, "Datacenter");
        try data.graph.setNodeProperty(datacenter, "name", .{ .String = dc.name });
        try data.graph.setNodeProperty(datacenter, "region", .{ .String = dc.region });

        const lat_str = try std.fmt.allocPrint(allocator, "{d:.4}", .{dc.lat});
        defer allocator.free(lat_str);
        try data.graph.setNodeProperty(datacenter, "latitude", .{ .String = lat_str });

        const lon_str = try std.fmt.allocPrint(allocator, "{d:.4}", .{dc.lon});
        defer allocator.free(lon_str);
        try data.graph.setNodeProperty(datacenter, "longitude", .{ .String = lon_str });
    }

    // Create network subnets for each datacenter
    var subnet_counter: u32 = 0;
    for (data.datacenters.items, 0..) |dc, dc_idx| {
        // Create multiple subnets per datacenter
        var subnet_idx: u32 = 0;
        while (subnet_idx < 5) : (subnet_idx += 1) {
            const subnet = try data.graph.createNode(&.{});
            try data.subnets.append(subnet);
            try data.graph.addNodeLabel(subnet, "Subnet");

            // Generate subnet CIDR (10.dc.subnet.0/24)
            const cidr = try std.fmt.allocPrint(allocator, "10.{}.{}.0/24", .{ dc_idx, subnet_idx });
            defer allocator.free(cidr);
            try data.graph.setNodeProperty(subnet, "cidr", .{ .String = cidr });
            try data.index_mgr.insertIntoPropertyIndex("subnet_cidr_idx", cidr, subnet);

            const vlan_id = try std.fmt.allocPrint(allocator, "{}", .{100 + subnet_counter});
            defer allocator.free(vlan_id);
            try data.graph.setNodeProperty(subnet, "vlan_id", .{ .String = vlan_id });

            // Link subnet to datacenter
            _ = try data.graph.createEdge(subnet, dc, "LOCATED_IN");

            subnet_counter += 1;
        }
    }

    try testing.expect(data.datacenters.items.len == 4);
    try testing.expect(data.subnets.items.len == 20); // 5 subnets per datacenter
}

test "IoT network - create 10k devices with IP/MAC" {
    const allocator = std.testing.allocator;

    var data = try NetworkData.init(allocator);
    defer data.deinit();

    // Create indexes
    try data.index_mgr.createPropertyIndex("device_ip_idx", "Device", "ip_address", .hash, true);
    try data.index_mgr.createPropertyIndex("device_mac_idx", "Device", "mac_address", .hash, true);

    // Create subnets first
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const subnet = try data.graph.createNode(&.{});
        try data.subnets.append(subnet);
        try data.graph.addNodeLabel(subnet, "Subnet");

        const cidr = try std.fmt.allocPrint(allocator, "192.168.{}.0/24", .{i});
        defer allocator.free(cidr);
        try data.graph.setNodeProperty(subnet, "cidr", .{ .String = cidr });
    }

    // Create devices
    const num_devices = 10000;
    var rng = std.rand.DefaultPrng.init(42);
    const random = rng.random();

    var timer = try std.time.Timer.start();
    timer.reset();

    i = 0;
    while (i < num_devices) : (i += 1) {
        const device = try data.graph.createNode(&.{});
        try data.devices.append(device);
        try data.graph.addNodeLabel(device, "Device");

        // Generate unique IP address
        const subnet_id = i / 250; // ~250 devices per subnet
        const host_id = (i % 250) + 2; // Start from .2 (reserve .1 for gateway)
        const ip = try std.fmt.allocPrint(allocator, "192.168.{}.{}", .{ subnet_id % 256, host_id });
        defer allocator.free(ip);
        try data.graph.setNodeProperty(device, "ip_address", .{ .String = ip });
        try data.index_mgr.insertIntoPropertyIndex("device_ip_idx", ip, device);

        // Generate MAC address
        const mac = try std.fmt.allocPrint(allocator, "aa:bb:cc:{x:0>2}:{x:0>2}:{x:0>2}", .{
            (i >> 16) & 0xFF,
            (i >> 8) & 0xFF,
            i & 0xFF,
        });
        defer allocator.free(mac);
        try data.graph.setNodeProperty(device, "mac_address", .{ .String = mac });
        try data.index_mgr.insertIntoPropertyIndex("device_mac_idx", mac, device);

        // Device hostname
        const hostname = try std.fmt.allocPrint(allocator, "device-{:0>5}", .{i});
        defer allocator.free(hostname);
        try data.graph.setNodeProperty(device, "hostname", .{ .String = hostname });

        // Device type
        const types = [_][]const u8{ "server", "workstation", "printer", "switch", "ap", "camera", "sensor" };
        const device_type = types[random.intRangeAtMost(usize, 0, types.len - 1)];
        try data.graph.setNodeProperty(device, "type", .{ .String = device_type });

        // Status
        const status = if (random.float(f32) < 0.95) "online" else "offline";
        try data.graph.setNodeProperty(device, "status", .{ .String = status });

        // Trust score (0-100)
        const trust_score = random.intRangeAtMost(u32, 60, 100);
        const trust_str = try std.fmt.allocPrint(allocator, "{}", .{trust_score});
        defer allocator.free(trust_str);
        try data.graph.setNodeProperty(device, "trust_score", .{ .String = trust_str });

        // Link to subnet
        if (data.subnets.items.len > 0) {
            const subnet_idx = @min(i / 1000, @as(u32, @intCast(data.subnets.items.len - 1)));
            const subnet = data.subnets.items[subnet_idx];
            _ = try data.graph.createEdge(device, subnet, "IN_SUBNET");
        }
    }

    const creation_time = timer.read();
    std.debug.print("\nCreated {} devices in {}ms\n", .{ num_devices, creation_time / 1_000_000 });

    try testing.expect(data.devices.items.len == num_devices);
    try testing.expect(creation_time < 15_000_000_000); // Less than 15 seconds
}

test "IoT network - sensor data with telemetry" {
    const allocator = std.testing.allocator;

    var data = try NetworkData.init(allocator);
    defer data.deinit();

    // Create spatial index for sensor locations
    try data.index_mgr.createSpatialIndex("sensor_location_idx", "Sensor", "location");
    try data.index_mgr.createPropertyIndex("sensor_reading_idx", "Reading", "timestamp", .btree, false);

    // Create sensor network across a facility (warehouse/factory floor)
    const num_sensors = 1000;
    var rng = std.rand.DefaultPrng.init(42);
    const random = rng.random();

    // Facility dimensions (in meters)
    const facility_width = 200.0;
    const facility_height = 100.0;

    var i: u64 = 0;
    while (i < num_sensors) : (i += 1) {
        const sensor = try data.graph.createNode(&.{});
        try data.sensors.append(sensor);
        try data.graph.addNodeLabel(sensor, "Sensor");

        const sensor_id = try std.fmt.allocPrint(allocator, "SENSOR-{:0>4}", .{i});
        defer allocator.free(sensor_id);
        try data.graph.setNodeProperty(sensor, "sensor_id", .{ .String = sensor_id });

        // Sensor types
        const sensor_types = [_][]const u8{ "temperature", "humidity", "motion", "pressure", "light", "vibration" };
        const sensor_type = sensor_types[random.intRangeAtMost(usize, 0, sensor_types.len - 1)];
        try data.graph.setNodeProperty(sensor, "type", .{ .String = sensor_type });

        // Location within facility
        const x = random.float(f64) * facility_width;
        const y = random.float(f64) * facility_height;

        // Store as spatial data (using lon/lat representation for the facility grid)
        const mbr = geode.index.rtree.MBR{
            .min_x = x - 0.5,
            .min_y = y - 0.5,
            .max_x = x + 0.5,
            .max_y = y + 0.5,
        };
        try data.index_mgr.insertIntoSpatialIndex("sensor_location_idx", mbr, sensor);

        const x_str = try std.fmt.allocPrint(allocator, "{d:.2}", .{x});
        defer allocator.free(x_str);
        try data.graph.setNodeProperty(sensor, "x_position", .{ .String = x_str });

        const y_str = try std.fmt.allocPrint(allocator, "{d:.2}", .{y});
        defer allocator.free(y_str);
        try data.graph.setNodeProperty(sensor, "y_position", .{ .String = y_str });

        // Battery level
        const battery = random.intRangeAtMost(u32, 10, 100);
        const battery_str = try std.fmt.allocPrint(allocator, "{}", .{battery});
        defer allocator.free(battery_str);
        try data.graph.setNodeProperty(sensor, "battery_level", .{ .String = battery_str });

        // Create recent readings for each sensor
        const num_readings = 10;
        var j: u32 = 0;
        while (j < num_readings) : (j += 1) {
            const reading = try data.graph.createNode(&.{});
            try data.graph.addNodeLabel(reading, "Reading");

            // Timestamp (last 24 hours)
            const timestamp = std.time.timestamp() - @as(i64, @intCast((num_readings - j) * 3600));
            const ts_str = try std.fmt.allocPrint(allocator, "{}", .{timestamp});
            defer allocator.free(ts_str);
            try data.graph.setNodeProperty(reading, "timestamp", .{ .String = ts_str });
            try data.index_mgr.insertIntoPropertyIndex("sensor_reading_idx", ts_str, reading);

            // Value based on sensor type
            const value = switch (sensor_type[0]) {
                't' => random.float(f32) * 10 + 20, // temperature: 20-30°C
                'h' => random.float(f32) * 40 + 40, // humidity: 40-80%
                'm' => if (random.float(f32) < 0.1) @as(f32, 1) else @as(f32, 0), // motion: 10% chance
                'p' => random.float(f32) * 20 + 1000, // pressure: 1000-1020 hPa
                'l' => random.float(f32) * 1000, // light: 0-1000 lux
                'v' => random.float(f32) * 10, // vibration: 0-10 mm/s
                else => random.float(f32) * 100,
            };

            const value_str = try std.fmt.allocPrint(allocator, "{d:.2}", .{value});
            defer allocator.free(value_str);
            try data.graph.setNodeProperty(reading, "value", .{ .String = value_str });

            // Link reading to sensor
            _ = try data.graph.createEdge(sensor, reading, "MEASURED");
        }
    }

    // Test spatial queries - find sensors in a specific area
    const search_area = geode.index.rtree.MBR{
        .min_x = 50.0,
        .min_y = 25.0,
        .max_x = 100.0,
        .max_y = 75.0,
    };

    const sensors_in_area = try data.index_mgr.searchSpatialIndex("sensor_location_idx", search_area);
    defer allocator.free(sensors_in_area);

    std.debug.print("Found {} sensors in search area\n", .{sensors_in_area.len});

    // Should find roughly 1/4 of sensors (area is 1/4 of facility)
    try testing.expect(sensors_in_area.len > num_sensors / 8);
    try testing.expect(sensors_in_area.len < num_sensors / 2);
}

test "IoT network - network traffic patterns" {
    const allocator = std.testing.allocator;

    var data = try NetworkData.init(allocator);
    defer data.deinit();

    // Create a simplified network
    const num_devices = 100;
    var i: u64 = 0;
    while (i < num_devices) : (i += 1) {
        const device = try data.graph.createNode(&.{});
        try data.devices.append(device);
        try data.graph.addNodeLabel(device, "Device");

        const ip = try std.fmt.allocPrint(allocator, "10.0.0.{}", .{i + 1});
        defer allocator.free(ip);
        try data.graph.setNodeProperty(device, "ip_address", .{ .String = ip });
    }

    // Create routers
    const num_routers = 5;
    i = 0;
    while (i < num_routers) : (i += 1) {
        const router = try data.graph.createNode(&.{});
        try data.routers.append(router);
        try data.graph.addNodeLabel(router, "Router");

        const router_id = try std.fmt.allocPrint(allocator, "RTR-{:0>2}", .{i});
        defer allocator.free(router_id);
        try data.graph.setNodeProperty(router, "router_id", .{ .String = router_id });
    }

    // Create traffic flows between devices
    var rng = std.rand.DefaultPrng.init(42);
    const random = rng.random();

    var total_flows: u64 = 0;
    for (data.devices.items) |source| {
        // Each device communicates with 5-20 other devices
        const num_destinations = random.intRangeAtMost(u32, 5, 20);

        var j: u32 = 0;
        while (j < num_destinations) : (j += 1) {
            const dest_idx = random.intRangeAtMost(usize, 0, num_devices - 1);
            const destination = data.devices.items[dest_idx];

            if (source != destination) {
                const flow = try data.graph.createEdge(source, destination, "TRAFFIC_FLOW");

                // Traffic properties
                const protocol = if (random.float(f32) < 0.7) "TCP" else if (random.float(f32) < 0.5) "UDP" else "ICMP";
                try data.graph.setEdgeProperty(flow, "protocol", .{ .String = protocol });

                const port = random.intRangeAtMost(u32, 1, 65535);
                const port_str = try std.fmt.allocPrint(allocator, "{}", .{port});
                defer allocator.free(port_str);
                try data.graph.setEdgeProperty(flow, "port", .{ .String = port_str });

                // Bytes transferred
                const bytes = random.intRangeAtMost(u64, 1000, 10000000);
                const bytes_str = try std.fmt.allocPrint(allocator, "{}", .{bytes});
                defer allocator.free(bytes_str);
                try data.graph.setEdgeProperty(flow, "bytes", .{ .String = bytes_str });

                // Anomaly score (0-100, higher is more suspicious)
                const anomaly = if (random.float(f32) < 0.05)
                    random.intRangeAtMost(u32, 70, 100) // 5% suspicious
                else
                    random.intRangeAtMost(u32, 0, 30); // 95% normal

                const anomaly_str = try std.fmt.allocPrint(allocator, "{}", .{anomaly});
                defer allocator.free(anomaly_str);
                try data.graph.setEdgeProperty(flow, "anomaly_score", .{ .String = anomaly_str });

                total_flows += 1;
            }
        }

        // Route through routers
        if (data.routers.items.len > 0) {
            const router_idx = random.intRangeAtMost(usize, 0, data.routers.items.len - 1);
            const router = data.routers.items[router_idx];

            const route = try data.graph.createEdge(source, router, "ROUTES_THROUGH");

            const latency = random.intRangeAtMost(u32, 1, 100);
            const latency_str = try std.fmt.allocPrint(allocator, "{}ms", .{latency});
            defer allocator.free(latency_str);
            try data.graph.setEdgeProperty(route, "latency", .{ .String = latency_str });
        }
    }

    std.debug.print("Created {} traffic flows\n", .{total_flows});

    // Find suspicious traffic (high anomaly scores)
    var suspicious_flows: u64 = 0;
    for (data.devices.items) |device| {
        const outgoing = try data.graph.getOutgoingEdges(device, allocator);
        defer allocator.free(outgoing);

        for (outgoing) |edge| {
            const anomaly_str = try data.graph.getEdgeProperty(edge, "anomaly_score");
            if (anomaly_str) |score_str| {
                const score = std.fmt.parseInt(u32, score_str, 10) catch continue;
                if (score > 70) {
                    suspicious_flows += 1;
                }
            }
        }
    }

    std.debug.print("Found {} suspicious traffic flows (>70 anomaly score)\n", .{suspicious_flows});

    // Should find roughly 5% suspicious
    try testing.expect(suspicious_flows > total_flows / 40); // At least 2.5%
    try testing.expect(suspicious_flows < total_flows / 10); // At most 10%
}

test "IoT network - security alerts and incidents" {
    const allocator = std.testing.allocator;

    var data = try NetworkData.init(allocator);
    defer data.deinit();

    // Create index for alerts
    try data.index_mgr.createPropertyIndex("alert_severity_idx", "Alert", "severity", .btree, false);
    try data.index_mgr.createPropertyIndex("alert_timestamp_idx", "Alert", "timestamp", .btree, false);

    // Create devices
    const num_devices = 500;
    var i: u64 = 0;
    while (i < num_devices) : (i += 1) {
        const device = try data.graph.createNode(&.{});
        try data.devices.append(device);
        try data.graph.addNodeLabel(device, "Device");

        const hostname = try std.fmt.allocPrint(allocator, "host-{:0>4}", .{i});
        defer allocator.free(hostname);
        try data.graph.setNodeProperty(device, "hostname", .{ .String = hostname });
    }

    // Generate security alerts
    var rng = std.rand.DefaultPrng.init(42);
    const random = rng.random();

    const num_alerts = 2000;
    var alerts = std.ArrayList(u64).init(allocator);
    defer alerts.deinit();

    i = 0;
    while (i < num_alerts) : (i += 1) {
        const alert = try data.graph.createNode(&.{});
        try alerts.append(alert);
        try data.graph.addNodeLabel(alert, "Alert");

        // Alert types
        const alert_types = [_][]const u8{
            "MALWARE_DETECTED",
            "BRUTE_FORCE_ATTEMPT",
            "DATA_EXFILTRATION",
            "PRIVILEGE_ESCALATION",
            "ANOMALOUS_TRAFFIC",
            "UNAUTHORIZED_ACCESS",
            "POLICY_VIOLATION",
            "DOS_ATTACK",
        };
        const alert_type = alert_types[random.intRangeAtMost(usize, 0, alert_types.len - 1)];
        try data.graph.setNodeProperty(alert, "type", .{ .String = alert_type });

        // Severity (1-5, 5 being critical)
        const severity_weights = [_]u32{ 40, 30, 20, 8, 2 }; // Weighted probabilities
        var severity: u32 = 1;
        const rand_val = random.intRangeAtMost(u32, 0, 99);
        var cumulative: u32 = 0;
        for (severity_weights, 1..) |weight, sev| {
            cumulative += weight;
            if (rand_val < cumulative) {
                severity = @intCast(sev);
                break;
            }
        }

        const severity_str = try std.fmt.allocPrint(allocator, "{}", .{severity});
        defer allocator.free(severity_str);
        try data.graph.setNodeProperty(alert, "severity", .{ .String = severity_str });
        try data.index_mgr.insertIntoPropertyIndex("alert_severity_idx", severity_str, alert);

        // Timestamp (last 7 days)
        const timestamp = std.time.timestamp() - random.intRangeAtMost(i64, 0, 7 * 24 * 3600);
        const ts_str = try std.fmt.allocPrint(allocator, "{}", .{timestamp});
        defer allocator.free(ts_str);
        try data.graph.setNodeProperty(alert, "timestamp", .{ .String = ts_str });
        try data.index_mgr.insertIntoPropertyIndex("alert_timestamp_idx", ts_str, alert);

        // Link to affected device
        const device_idx = random.intRangeAtMost(usize, 0, num_devices - 1);
        const device = data.devices.items[device_idx];
        _ = try data.graph.createEdge(alert, device, "AFFECTS");

        // Add response status
        const status = if (severity >= 4) "investigating" else if (random.float(f32) < 0.7) "resolved" else "pending";
        try data.graph.setNodeProperty(alert, "status", .{ .String = status });
    }

    // Create incidents from related alerts
    var incidents = std.ArrayList(u64).init(allocator);
    defer incidents.deinit();

    // Group high-severity alerts into incidents
    for (alerts.items) |alert| {
        const severity_val = data.graph.getNodeProperty(alert, "severity");
        if (severity_val) |sev| switch (sev) {
            .String => |sev_str| {
                const severity = std.fmt.parseInt(u32, sev_str, 10) catch continue;

                if (severity >= 4) {
                    // Create or find incident
                    const incident = if (incidents.items.len < 10) blk: {
                        const inc = try data.graph.createNode(&.{});
                        try incidents.append(inc);
                        try data.graph.addNodeLabel(inc, "Incident");

                        const inc_id = try std.fmt.allocPrint(allocator, "INC-{:0>4}", .{incidents.items.len});
                        defer allocator.free(inc_id);
                        try data.graph.setNodeProperty(inc, "incident_id", .{ .String = inc_id });

                        break :blk inc;
                    } else incidents.items[random.intRangeAtMost(usize, 0, incidents.items.len - 1)];

                    // Link alert to incident
                    _ = try data.graph.createEdge(alert, incident, "PART_OF");
                }
            },
            else => {},
        };
    }

    std.debug.print("Created {} alerts and {} incidents\n", .{ num_alerts, incidents.items.len });

    // Count critical alerts
    var critical_count: u64 = 0;
    for (alerts.items) |alert| {
        const severity_val = data.graph.getNodeProperty(alert, "severity");
        if (severity_val) |sev| switch (sev) {
            .String => |sev_str| {
                const severity = std.fmt.parseInt(u32, sev_str, 10) catch continue;
                if (severity == 5) {
                    critical_count += 1;
                }
            },
            else => {},
        };
    }

    std.debug.print("Critical alerts (severity 5): {}\n", .{critical_count});

    // Should have ~2% critical alerts based on weights
    try testing.expect(critical_count > num_alerts / 100); // At least 1%
    try testing.expect(critical_count < num_alerts / 20); // At most 5%
}

test "CANARY: REQ=REQ-GQL-IOT-NETWORK" {
    // CANARY: REQ=REQ-GQL-IOT-NETWORK; FEATURE="IoTNetwork"; ASPECT=Domain; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_IOT_NETWORK; OWNER=team; UPDATED=2026-11-14
    const allocator = std.testing.allocator;

    var data = try NetworkData.init(allocator);
    defer data.deinit();

    // Create comprehensive IoT network test
    try data.index_mgr.createPropertyIndex("device_trust_idx", "Device", "trust_score", .btree, false);
    try data.index_mgr.createSpatialIndex("device_location_idx", "Device", "location");
    try data.index_mgr.createPropertyIndex("metric_timestamp_idx", "Metric", "timestamp", .btree, false);

    var timer = try std.time.Timer.start();
    var rng = std.rand.DefaultPrng.init(42);
    const random = rng.random();

    // Phase 1: Create IoT infrastructure
    timer.reset();

    // Create edge gateways
    const num_gateways = 10;
    var gateways = std.ArrayList(u64).init(allocator);
    defer gateways.deinit();

    var i: u64 = 0;
    while (i < num_gateways) : (i += 1) {
        const gateway = try data.graph.createNode(&.{});
        try gateways.append(gateway);
        try data.graph.addNodeLabel(gateway, "Gateway");

        const gw_id = try std.fmt.allocPrint(allocator, "GW-{:0>3}", .{i});
        defer allocator.free(gw_id);
        try data.graph.setNodeProperty(gateway, "gateway_id", .{ .String = gw_id });

        // Gateway location (distributed across facility)
        const x = @as(f64, @floatFromInt(i % 5)) * 50.0;
        const y = @as(f64, @floatFromInt(i / 5)) * 50.0;

        const mbr = geode.index.rtree.MBR{
            .min_x = x - 1.0,
            .min_y = y - 1.0,
            .max_x = x + 1.0,
            .max_y = y + 1.0,
        };
        try data.index_mgr.insertIntoSpatialIndex("device_location_idx", mbr, gateway);
    }

    // Create IoT devices
    const num_iot_devices = 25000;
    i = 0;
    while (i < num_iot_devices) : (i += 1) {
        const device = try data.graph.createNode(&.{});
        try data.devices.append(device);
        try data.graph.addNodeLabel(device, "IoTDevice");

        const device_id = try std.fmt.allocPrint(allocator, "IOT-{:0>8}", .{i});
        defer allocator.free(device_id);
        try data.graph.setNodeProperty(device, "device_id", .{ .String = device_id });

        // Device metrics
        const trust_score = 50 + random.intRangeAtMost(u32, 0, 50);
        const trust_str = try std.fmt.allocPrint(allocator, "{}", .{trust_score});
        defer allocator.free(trust_str);
        try data.graph.setNodeProperty(device, "trust_score", .{ .String = trust_str });
        try data.index_mgr.insertIntoPropertyIndex("device_trust_idx", trust_str, device);

        // Connect to nearest gateway
        const gateway_idx = i % num_gateways;
        const gateway = gateways.items[gateway_idx];
        const edge = try data.graph.createEdge(device, gateway, "CONNECTS_TO");

        // Connection quality
        const rssi = -30 - random.intRangeAtMost(i32, 0, 70); // -30 to -100 dBm
        const rssi_str = try std.fmt.allocPrint(allocator, "{}dBm", .{rssi});
        defer allocator.free(rssi_str);
        try data.graph.setEdgeProperty(edge, "rssi", .{ .String = rssi_str });

        if (i % 5000 == 0) {
            std.debug.print("Created {} IoT devices...\n", .{i});
        }
    }

    const infrastructure_time = timer.read();

    // Phase 2: Generate telemetry data
    timer.reset();

    const num_metrics = 50000;
    i = 0;
    while (i < num_metrics) : (i += 1) {
        const metric = try data.graph.createNode(&.{});
        try data.graph.addNodeLabel(metric, "Metric");

        // Random device
        const device_idx = random.intRangeAtMost(usize, 0, data.devices.items.len - 1);
        const device = data.devices.items[device_idx];

        // Metric timestamp
        const timestamp = std.time.timestamp() - random.intRangeAtMost(i64, 0, 3600);
        const ts_str = try std.fmt.allocPrint(allocator, "{}", .{timestamp});
        defer allocator.free(ts_str);
        try data.graph.setNodeProperty(metric, "timestamp", .{ .String = ts_str });
        try data.index_mgr.insertIntoPropertyIndex("metric_timestamp_idx", ts_str, metric);

        // Metric type and value
        const metric_types = [_][]const u8{ "cpu", "memory", "disk", "network", "temperature", "power" };
        const metric_type = metric_types[random.intRangeAtMost(usize, 0, metric_types.len - 1)];
        try data.graph.setNodeProperty(metric, "type", .{ .String = metric_type });

        const value = random.float(f32) * 100;
        const value_str = try std.fmt.allocPrint(allocator, "{d:.2}", .{value});
        defer allocator.free(value_str);
        try data.graph.setNodeProperty(metric, "value", .{ .String = value_str });

        // Link to device
        _ = try data.graph.createEdge(device, metric, "REPORTED");
    }

    const telemetry_time = timer.read();

    // Performance summary
    std.debug.print("\nIoT Network Canary Results:\n", .{});
    std.debug.print("  Infrastructure ({} devices): {}ms\n", .{ num_iot_devices, infrastructure_time / 1_000_000 });
    std.debug.print("  Telemetry ({} metrics): {}ms\n", .{ num_metrics, telemetry_time / 1_000_000 });

    // Performance requirements
    try testing.expect(infrastructure_time < 45_000_000_000); // Less than 45 seconds for 25k devices
    try testing.expect(telemetry_time < 60_000_000_000); // Less than 60 seconds for 50k metrics

    // Verify data integrity
    try testing.expect(data.devices.items.len == num_iot_devices);
    try testing.expect(gateways.items.len == num_gateways);
}
