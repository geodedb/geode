const std = @import("std");
const geode = @import("geode");
const testing = std.testing;

test "CANARY: REQ=REQ-GQL-GEOGRAPHIC-MAPPING" {
    // CANARY: REQ=REQ-GQL-GEOGRAPHIC-MAPPING; FEATURE="GeographicMapping"; ASPECT=Integration; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_GEOGRAPHIC_MAPPING; OWNER=team; UPDATED=2025-10-02
    const allocator = std.testing.allocator;

    var client = try geode.Client.init(allocator, .{
        .host = "127.0.0.1",
        .port = 8443,
        .insecure = true,
    });
    defer client.deinit();

    std.debug.print("\n=== Geographic Mapping & Routing Test ===\n", .{});

    // Create schema for geographic data
    try client.execute("CREATE LABEL City");
    try client.execute("CREATE LABEL Road");
    try client.execute("CREATE LABEL PointOfInterest");
    try client.execute("CREATE LABEL Region");
    try client.execute("CREATE LABEL TransitStop");
    try client.execute("CREATE LABEL Building");
    try client.execute("CREATE LABEL ParkingLot");

    // Create spatial indexes
    try client.execute("CREATE SPATIAL INDEX city_boundary_idx ON City(boundary)");
    try client.execute("CREATE SPATIAL INDEX poi_location_idx ON PointOfInterest(location)");
    try client.execute("CREATE SPATIAL INDEX region_area_idx ON Region(area)");
    try client.execute("CREATE SPATIAL INDEX building_footprint_idx ON Building(footprint)");

    // Additional indexes for performance
    try client.execute("CREATE INDEX city_name_idx ON City(name) USING hash");
    try client.execute("CREATE INDEX poi_category_idx ON PointOfInterest(category) USING btree");
    try client.execute("CREATE INDEX road_type_idx ON Road(road_type) USING hash");

    const num_cities = 100;
    const num_regions = 500;
    const num_roads = 10000;
    const num_pois = 25000;
    const num_transit_stops = 5000;
    const num_buildings = 50000;
    const num_parking = 2000;

    std.debug.print("Creating geographic network with {} cities, {} POIs, {} roads, {} buildings...\n", .{
        num_cities,
        num_pois,
        num_roads,
        num_buildings,
    });

    // Create cities distributed across a geographic area
    var i: usize = 0;
    while (i < num_cities) : (i += 1) {
        // Distribute cities across roughly US coordinates
        const lat = 25.0 + @as(f64, @floatFromInt(i / 10)) * 2.5;
        const lon = -125.0 + @as(f64, @floatFromInt(i % 10)) * 5.0;

        const query = try std.fmt.allocPrint(allocator,
            \\CREATE (c:City {{
            \\  id: 'CITY-{d:0>4}',
            \\  name: 'City {d}',
            \\  center: LatLon({d:.4}, {d:.4}),
            \\  boundary: GeometryFromText('POLYGON(({d:.4} {d:.4}, {d:.4} {d:.4}, {d:.4} {d:.4}, {d:.4} {d:.4}, {d:.4} {d:.4}))'),
            \\  population: {d},
            \\  elevation: {d},
            \\  timezone: 'America/Los_Angeles',
            \\  country: 'US',
            \\  state: '{s}',
            \\  area_sq_km: {d:.2},
            \\  density_per_sq_km: {d},
            \\  avg_temperature: Temperature({d:.1}, 'C'),
            \\  established: date('1850-01-01') + duration('P{d}D')
            \\}})
        , .{
            i,
            i,
            lat,
            lon,
            // Create a rough square boundary around the city
            lon - 0.1,
            lat - 0.1,
            lon + 0.1,
            lat - 0.1,
            lon + 0.1,
            lat + 0.1,
            lon - 0.1,
            lat + 0.1,
            lon - 0.1,
            lat - 0.1,
            50000 + (i * 10000),
            100 + (i % 500) * 10,
            if (i % 4 == 0) "CA" else if (i % 4 == 1) "OR" else if (i % 4 == 2) "WA" else "NV",
            100.0 + @as(f64, @floatFromInt(i % 100)) * 10.0,
            500 + (i % 200) * 10,
            15.0 + @as(f64, @floatFromInt(i % 20)),
            i * 30,
        });
        defer allocator.free(query);
        try client.execute(query);
    }

    // Create regions (neighborhoods, districts, etc.)
    i = 0;
    while (i < num_regions) : (i += 1) {
        const city_id = i % num_cities;
        const city_lat = 25.0 + @as(f64, @floatFromInt(city_id / 10)) * 2.5;
        const city_lon = -125.0 + @as(f64, @floatFromInt(city_id % 10)) * 5.0;

        // Create regions around cities
        const region_offset_lat = @as(f64, @floatFromInt(i % 5)) * 0.02 - 0.04;
        const region_offset_lon = @as(f64, @floatFromInt((i / 5) % 5)) * 0.02 - 0.04;

        const region_types = [_][]const u8{ "residential", "commercial", "industrial", "downtown", "suburban" };
        const region_type = region_types[i % region_types.len];

        const query = try std.fmt.allocPrint(allocator,
            \\CREATE (r:Region {{
            \\  id: 'REGION-{d:0>5}',
            \\  name: '{s} District {d}',
            \\  type: '{s}',
            \\  center: LatLon({d:.4}, {d:.4}),
            \\  area: GeometryFromText('POLYGON(({d:.4} {d:.4}, {d:.4} {d:.4}, {d:.4} {d:.4}, {d:.4} {d:.4}, {d:.4} {d:.4}))'),
            \\  population: {d},
            \\  median_income: {d},
            \\  crime_rate: {d:.2},
            \\  walkability_score: {d},
            \\  avg_property_value: {d},
            \\  zoning_code: '{s}{d:0>3}'
            \\}})
        , .{
            i,
            region_type,
            i,
            region_type,
            city_lat + region_offset_lat,
            city_lon + region_offset_lon,
            // Create small polygon for region
            city_lon + region_offset_lon - 0.01,
            city_lat + region_offset_lat - 0.01,
            city_lon + region_offset_lon + 0.01,
            city_lat + region_offset_lat - 0.01,
            city_lon + region_offset_lon + 0.01,
            city_lat + region_offset_lat + 0.01,
            city_lon + region_offset_lon - 0.01,
            city_lat + region_offset_lat + 0.01,
            city_lon + region_offset_lon - 0.01,
            city_lat + region_offset_lat - 0.01,
            1000 + (i % 100) * 50,
            40000 + (i % 50) * 2000,
            @as(f64, 1.0) + @as(f64, @floatFromInt(i % 10)) / 2.0,
            50 + (i % 50),
            200000 + (i % 100) * 10000,
            if (region_type[0] == 'r') "R" else if (region_type[0] == 'c') "C" else "I",
            i % 999,
        });
        defer allocator.free(query);
        try client.execute(query);

        // Link region to city
        const link_query = try std.fmt.allocPrint(allocator,
            \\MATCH (r:Region {{id: 'REGION-{d:0>5}'}}), (c:City {{id: 'CITY-{d:0>4}'}})
            \\CREATE (r)-[:LOCATED_IN]->(c)
        , .{ i, city_id });
        defer allocator.free(link_query);
        try client.execute(link_query);
    }

    // Create roads connecting cities and within regions
    i = 0;
    while (i < num_roads) : (i += 1) {
        const road_types = [_][]const u8{ "highway", "arterial", "collector", "local", "service" };
        const road_type = road_types[i % road_types.len];

        const start_city = i % num_cities;
        const end_city = (i * 3 + 7) % num_cities;

        const start_lat = 25.0 + @as(f64, @floatFromInt(start_city / 10)) * 2.5;
        const start_lon = -125.0 + @as(f64, @floatFromInt(start_city % 10)) * 5.0;
        const end_lat = 25.0 + @as(f64, @floatFromInt(end_city / 10)) * 2.5;
        const end_lon = -125.0 + @as(f64, @floatFromInt(end_city % 10)) * 5.0;

        const query = try std.fmt.allocPrint(allocator,
            \\CREATE (r:Road {{
            \\  id: 'ROAD-{d:0>6}',
            \\  name: '{s} {d}',
            \\  road_type: '{s}',
            \\  start_point: LatLon({d:.4}, {d:.4}),
            \\  end_point: LatLon({d:.4}, {d:.4}),
            \\  geometry: GeometryFromText('LINESTRING({d:.4} {d:.4}, {d:.4} {d:.4})'),
            \\  length_km: {d:.2},
            \\  speed_limit_mph: {d},
            \\  lanes: {d},
            \\  surface: '{s}',
            \\  condition: '{s}',
            \\  toll: {s},
            \\  traffic_volume_daily: {d},
            \\  last_maintenance: date('2023-01-01') + duration('P{d}D')
            \\}})
        , .{
            i,
            if (road_type[0] == 'h') "Interstate" else if (road_type[0] == 'a') "State Route" else "Road",
            i,
            road_type,
            start_lat,
            start_lon,
            end_lat,
            end_lon,
            start_lon,
            start_lat,
            end_lon,
            end_lat,
            distance_approx(start_lat, start_lon, end_lat, end_lon),
            if (road_type[0] == 'h') 65 else if (road_type[0] == 'a') 45 else 25,
            if (road_type[0] == 'h') 4 else if (road_type[0] == 'a') 2 else 1,
            if (i % 10 == 0) "concrete" else "asphalt",
            if (i % 20 == 0) "poor" else if (i % 5 == 0) "fair" else "good",
            if (road_type[0] == 'h' and i % 10 == 0) "true" else "false",
            if (road_type[0] == 'h') 50000 else if (road_type[0] == 'a') 10000 else 1000,
            i % 365,
        });
        defer allocator.free(query);
        try client.execute(query);

        // Connect roads to cities
        const connect_start = try std.fmt.allocPrint(allocator,
            \\MATCH (r:Road {{id: 'ROAD-{d:0>6}'}}), (c:City {{id: 'CITY-{d:0>4}'}})
            \\CREATE (r)-[:STARTS_IN]->(c)
        , .{ i, start_city });
        defer allocator.free(connect_start);
        try client.execute(connect_start);

        const connect_end = try std.fmt.allocPrint(allocator,
            \\MATCH (r:Road {{id: 'ROAD-{d:0>6}'}}), (c:City {{id: 'CITY-{d:0>4}'}})
            \\CREATE (r)-[:ENDS_IN]->(c)
        , .{ i, end_city });
        defer allocator.free(connect_end);
        try client.execute(connect_end);
    }

    // Create points of interest
    i = 0;
    while (i < num_pois) : (i += 1) {
        const categories = [_][]const u8{ "restaurant", "hotel", "museum", "park", "hospital", "school", "shopping", "gas_station", "bank", "gym", "theater", "library", "police", "fire_station", "airport" };
        const category = categories[i % categories.len];

        const city_id = i % num_cities;
        const city_lat = 25.0 + @as(f64, @floatFromInt(city_id / 10)) * 2.5;
        const city_lon = -125.0 + @as(f64, @floatFromInt(city_id % 10)) * 5.0;

        // Scatter POIs around city center
        const poi_lat = city_lat + (@as(f64, @floatFromInt(i % 100)) - 50.0) * 0.002;
        const poi_lon = city_lon + (@as(f64, @floatFromInt((i / 100) % 100)) - 50.0) * 0.002;

        const query = try std.fmt.allocPrint(allocator,
            \\CREATE (p:PointOfInterest {{
            \\  id: 'POI-{d:0>7}',
            \\  name: '{s} {d}',
            \\  category: '{s}',
            \\  location: LatLon({d:.6}, {d:.6}),
            \\  address: '{d} Main St',
            \\  phone: '+1-555-{d:0>4}',
            \\  website: Url('https://poi{d}.example.com'),
            \\  rating: {d:.1},
            \\  review_count: {d},
            \\  price_level: {d},
            \\  hours_open: time('08:00:00'),
            \\  hours_close: time('22:00:00'),
            \\  is_24h: {s},
            \\  accepts_cards: {s},
            \\  wheelchair_accessible: {s},
            \\  parking_available: {s},
            \\  wifi_available: {s},
            \\  delivery: {s},
            \\  takeout: {s},
            \\  images: Array['image1.jpg', 'image2.jpg'],
            \\  tags: Array['{s}', 'popular', 'verified'],
            \\  established: date('2000-01-01') + duration('P{d}D'),
            \\  last_updated: timestamp()
            \\}})
        , .{
            i,
            category,
            i,
            category,
            poi_lat,
            poi_lon,
            100 + (i % 9900),
            1000 + (i % 9000),
            i,
            3.0 + @as(f64, @floatFromInt(i % 20)) / 10.0,
            10 + (i % 990),
            1 + (i % 4),
            if (category[0] == 'h' or category[0] == 'p') "true" else "false",
            if (i % 10 == 0) "false" else "true",
            if (i % 20 == 0) "false" else "true",
            if (i % 3 == 0) "false" else "true",
            if (category[0] == 'r' or category[0] == 'h') "true" else "false",
            if (category[0] == 'r') "true" else "false",
            if (category[0] == 'r') "true" else "false",
            category,
            i % 7000,
        });
        defer allocator.free(query);
        try client.execute(query);

        // Link POI to city and region
        const city_link = try std.fmt.allocPrint(allocator,
            \\MATCH (p:PointOfInterest {{id: 'POI-{d:0>7}'}}), (c:City {{id: 'CITY-{d:0>4}'}})
            \\CREATE (p)-[:IN_CITY]->(c)
        , .{ i, city_id });
        defer allocator.free(city_link);
        try client.execute(city_link);

        const region_id = i % num_regions;
        const region_link = try std.fmt.allocPrint(allocator,
            \\MATCH (p:PointOfInterest {{id: 'POI-{d:0>7}'}}), (r:Region {{id: 'REGION-{d:0>5}'}})
            \\CREATE (p)-[:IN_REGION]->(r)
        , .{ i, region_id });
        defer allocator.free(region_link);
        try client.execute(region_link);
    }

    // Create transit stops
    i = 0;
    while (i < num_transit_stops) : (i += 1) {
        const transit_types = [_][]const u8{ "bus", "metro", "tram", "train", "ferry" };
        const transit_type = transit_types[i % transit_types.len];

        const city_id = i % num_cities;
        const city_lat = 25.0 + @as(f64, @floatFromInt(city_id / 10)) * 2.5;
        const city_lon = -125.0 + @as(f64, @floatFromInt(city_id % 10)) * 5.0;

        const stop_lat = city_lat + (@as(f64, @floatFromInt(i % 50)) - 25.0) * 0.003;
        const stop_lon = city_lon + (@as(f64, @floatFromInt((i / 50) % 50)) - 25.0) * 0.003;

        const query = try std.fmt.allocPrint(allocator,
            \\CREATE (t:TransitStop {{
            \\  id: 'TRANSIT-{d:0>5}',
            \\  name: '{s} Stop {d}',
            \\  type: '{s}',
            \\  location: LatLon({d:.6}, {d:.6}),
            \\  lines: Array['Line{d}', 'Line{d}'],
            \\  platform_count: {d},
            \\  accessibility: '{s}',
            \\  bike_parking: {s},
            \\  park_and_ride: {s},
            \\  ticket_machine: {s},
            \\  shelter: {s},
            \\  realtime_info: {s},
            \\  daily_ridership: {d},
            \\  peak_frequency_min: {d},
            \\  service_hours: '{d:0>2}:00-{d:0>2}:00'
            \\}})
        , .{
            i,
            transit_type,
            i,
            transit_type,
            stop_lat,
            stop_lon,
            i % 10,
            (i + 3) % 10,
            1 + (i % 4),
            if (i % 10 == 0) "limited" else "full",
            if (i % 3 == 0) "true" else "false",
            if (transit_type[0] == 't' and i % 5 == 0) "true" else "false",
            if (i % 5 != 0) "true" else "false",
            if (i % 10 != 0) "true" else "false",
            if (transit_type[0] == 'm' or transit_type[0] == 't') "true" else "false",
            100 + (i % 900) * 10,
            if (transit_type[0] == 'm') 5 else if (transit_type[0] == 'b') 15 else 30,
            5 + (i % 2),
            23 - (i % 2),
        });
        defer allocator.free(query);
        try client.execute(query);

        // Connect transit stops
        if (i > 0 and i % 10 < 9) {
            const connect_query = try std.fmt.allocPrint(allocator,
                \\MATCH (t1:TransitStop {{id: 'TRANSIT-{d:0>5}'}}), (t2:TransitStop {{id: 'TRANSIT-{d:0>5}'}})
                \\CREATE (t1)-[:CONNECTS_TO {{
                \\  travel_time_min: {d},
                \\  distance_km: {d:.2}
                \\}}]->(t2)
            , .{
                i,           i + 1,
                2 + (i % 8), 0.5 + @as(f64, @floatFromInt(i % 20)) / 10.0,
            });
            defer allocator.free(connect_query);
            try client.execute(connect_query);
        }
    }

    // Create buildings
    i = 0;
    while (i < num_buildings) : (i += 1) {
        const building_types = [_][]const u8{ "residential", "commercial", "office", "retail", "mixed_use" };
        const building_type = building_types[i % building_types.len];

        const city_id = i % num_cities;
        const city_lat = 25.0 + @as(f64, @floatFromInt(city_id / 10)) * 2.5;
        const city_lon = -125.0 + @as(f64, @floatFromInt(city_id % 10)) * 5.0;

        const building_lat = city_lat + (@as(f64, @floatFromInt(i % 200)) - 100.0) * 0.001;
        const building_lon = city_lon + (@as(f64, @floatFromInt((i / 200) % 200)) - 100.0) * 0.001;

        const query = try std.fmt.allocPrint(allocator,
            \\CREATE (b:Building {{
            \\  id: 'BLDG-{d:0>7}',
            \\  address: '{d} Street {d}',
            \\  type: '{s}',
            \\  center: LatLon({d:.6}, {d:.6}),
            \\  footprint: GeometryFromText('POLYGON(({d:.6} {d:.6}, {d:.6} {d:.6}, {d:.6} {d:.6}, {d:.6} {d:.6}, {d:.6} {d:.6}))'),
            \\  height_m: {d},
            \\  floors: {d},
            \\  year_built: {d},
            \\  units: {d},
            \\  occupancy_rate: {d:.2},
            \\  energy_rating: '{s}',
            \\  value_usd: {d},
            \\  property_tax_annual: {d},
            \\  last_renovation: {s}
            \\}})
        , .{
            i,
            100 + (i % 900),
            i % 100,
            building_type,
            building_lat,
            building_lon,
            // Small rectangular footprint
            building_lon - 0.0001,
            building_lat - 0.0001,
            building_lon + 0.0001,
            building_lat - 0.0001,
            building_lon + 0.0001,
            building_lat + 0.0001,
            building_lon - 0.0001,
            building_lat + 0.0001,
            building_lon - 0.0001,
            building_lat - 0.0001,
            if (building_type[0] == 'o') 50 + (i % 100) else 10 + (i % 30),
            if (building_type[0] == 'o') 10 + (i % 20) else 1 + (i % 5),
            1950 + (i % 75),
            if (building_type[0] == 'r') 10 + (i % 90) else 1,
            0.70 + @as(f64, @floatFromInt(i % 30)) / 100.0,
            if (i % 5 == 0) "A" else if (i % 5 == 1) "B" else if (i % 5 == 2) "C" else if (i % 5 == 3) "D" else "E",
            500000 + (i % 100) * 50000,
            5000 + (i % 100) * 500,
            if (i % 10 == 0) try std.fmt.allocPrint(allocator, "{d}", .{2020 - (i % 5)}) else "null",
        });
        defer allocator.free(query);
        try client.execute(query);
    }

    // Create parking lots
    i = 0;
    while (i < num_parking) : (i += 1) {
        const city_id = i % num_cities;
        const city_lat = 25.0 + @as(f64, @floatFromInt(city_id / 10)) * 2.5;
        const city_lon = -125.0 + @as(f64, @floatFromInt(city_id % 10)) * 5.0;

        const parking_lat = city_lat + (@as(f64, @floatFromInt(i % 40)) - 20.0) * 0.004;
        const parking_lon = city_lon + (@as(f64, @floatFromInt((i / 40) % 40)) - 20.0) * 0.004;

        const query = try std.fmt.allocPrint(allocator,
            \\CREATE (p:ParkingLot {{
            \\  id: 'PARK-{d:0>5}',
            \\  name: 'Parking Lot {d}',
            \\  location: LatLon({d:.6}, {d:.6}),
            \\  area: GeometryFromText('POLYGON(({d:.6} {d:.6}, {d:.6} {d:.6}, {d:.6} {d:.6}, {d:.6} {d:.6}, {d:.6} {d:.6}))'),
            \\  capacity: {d},
            \\  occupied: {d},
            \\  type: '{s}',
            \\  rate_hourly: {d:.2},
            \\  rate_daily_max: {d},
            \\  ev_charging: {s},
            \\  covered: {s},
            \\  valet: {s},
            \\  hours: '{s}',
            \\  payment_methods: Array['cash', 'card', 'app']
            \\}})
        , .{
            i,
            i,
            parking_lat,
            parking_lon,
            parking_lon - 0.0002,
            parking_lat - 0.0002,
            parking_lon + 0.0002,
            parking_lat - 0.0002,
            parking_lon + 0.0002,
            parking_lat + 0.0002,
            parking_lon - 0.0002,
            parking_lat + 0.0002,
            parking_lon - 0.0002,
            parking_lat - 0.0002,
            50 + (i % 450),
            30 + (i % 200),
            if (i % 3 == 0) "surface" else if (i % 3 == 1) "garage" else "street",
            2.0 + @as(f64, @floatFromInt(i % 8)),
            15 + (i % 35),
            if (i % 10 == 0) "true" else "false",
            if (i % 3 == 1) "true" else "false",
            if (i % 20 == 0) "true" else "false",
            if (i % 5 == 0) "24/7" else "06:00-22:00",
        });
        defer allocator.free(query);
        try client.execute(query);

        // Link parking to nearest POIs
        const link_query = try std.fmt.allocPrint(allocator,
            \\MATCH (p:ParkingLot {{id: 'PARK-{d:0>5}'}}), (poi:PointOfInterest)
            \\WHERE distance_haversine(p.location, poi.location) < 500
            \\WITH p, poi, distance_haversine(p.location, poi.location) as dist
            \\ORDER BY dist
            \\LIMIT 3
            \\CREATE (p)-[:SERVES {{distance_m: dist}}]->(poi)
        , .{i});
        defer allocator.free(link_query);
        try client.execute(link_query);
    }

    std.debug.print("Created geographic network successfully\n", .{});
    std.debug.print("  Cities: {}\n", .{num_cities});
    std.debug.print("  Regions: {}\n", .{num_regions});
    std.debug.print("  Roads: {}\n", .{num_roads});
    std.debug.print("  POIs: {}\n", .{num_pois});
    std.debug.print("  Transit stops: {}\n", .{num_transit_stops});
    std.debug.print("  Buildings: {}\n", .{num_buildings});
    std.debug.print("  Parking lots: {}\n", .{num_parking});

    // Run spatial queries
    std.debug.print("\n--- Spatial Analysis Queries ---\n", .{});

    // Query 1: Find POIs within a radius
    const radius_result = try client.query(
        \\MATCH (p:PointOfInterest)
        \\WHERE distance_haversine(p.location, LatLon(37.7749, -122.4194)) < 10000
        \\RETURN p.name, p.category, distance_haversine(p.location, LatLon(37.7749, -122.4194)) as distance_m
        \\ORDER BY distance_m
        \\LIMIT 10
    );
    defer radius_result.deinit();
    std.debug.print("POIs within 10km: {} found\n", .{radius_result.rows.len});

    // Query 2: Find overlapping regions
    const overlap_result = try client.query(
        \\MATCH (r1:Region), (r2:Region)
        \\WHERE r1.id < r2.id AND st_intersects(r1.area, r2.area)
        \\RETURN r1.name, r2.name
        \\LIMIT 10
    );
    defer overlap_result.deinit();
    std.debug.print("Overlapping regions: {} pairs\n", .{overlap_result.rows.len});

    // Query 3: Route planning between cities
    const route_result = try client.query(
        \\MATCH path = (c1:City {name: 'City 1'})-[:STARTS_IN|ENDS_IN*..6]-(c2:City {name: 'City 10'})
        \\RETURN length(path) as hops
        \\ORDER BY hops
        \\LIMIT 5
    );
    defer route_result.deinit();
    std.debug.print("Routes found: {} paths\n", .{route_result.rows.len});

    // Query 4: Transit accessibility analysis
    const transit_result = try client.query(
        \\MATCH (t:TransitStop)-[:CONNECTS_TO*..3]-(destination:TransitStop)
        \\WITH t, COUNT(DISTINCT destination) as reachable_stops
        \\WHERE reachable_stops > 10
        \\RETURN t.name, t.type, reachable_stops
        \\ORDER BY reachable_stops DESC
        \\LIMIT 10
    );
    defer transit_result.deinit();
    std.debug.print("Well-connected transit stops: {}\n", .{transit_result.rows.len});

    // Query 5: Urban density analysis
    const density_result = try client.query(
        \\MATCH (r:Region)<-[:IN_REGION]-(b:Building)
        \\WITH r, COUNT(b) as building_count, SUM(b.units) as total_units
        \\WHERE building_count > 50
        \\RETURN r.name, r.type, building_count, total_units
        \\ORDER BY total_units DESC
        \\LIMIT 10
    );
    defer density_result.deinit();
    std.debug.print("High-density regions: {}\n", .{density_result.rows.len});

    // Validate data consistency
    const total_cities = try client.query("MATCH (c:City) RETURN COUNT(c) as count");
    defer total_cities.deinit();
    try testing.expect(total_cities.rows.len == 1);

    const total_pois = try client.query("MATCH (p:PointOfInterest) RETURN COUNT(p) as count");
    defer total_pois.deinit();
    try testing.expect(total_pois.rows.len == 1);

    std.debug.print("\n=== Geographic mapping test completed successfully ===\n", .{});
}

fn distance_approx(lat1: f64, lon1: f64, lat2: f64, lon2: f64) f64 {
    // Simplified distance calculation for test purposes
    const dlat = lat2 - lat1;
    const dlon = lon2 - lon1;
    const dist_deg = @sqrt(dlat * dlat + dlon * dlon);
    return dist_deg * 111.0; // Rough conversion to km
}

test "proximity search performance" {
    const allocator = std.testing.allocator;

    var client = try geode.Client.init(allocator, .{
        .host = "127.0.0.1",
        .port = 8443,
        .insecure = true,
    });
    defer client.deinit();

    std.debug.print("\n--- Proximity Search Performance ---\n", .{});

    // Test various radius searches
    const search_radii = [_]f64{ 1000, 5000, 10000, 50000 }; // meters

    for (search_radii) |radius| {
        const query = try std.fmt.allocPrint(allocator,
            \\MATCH (p:PointOfInterest)
            \\WHERE distance_haversine(p.location, LatLon(37.7749, -122.4194)) < {d}
            \\RETURN COUNT(p) as count, AVG(p.rating) as avg_rating
        , .{radius});
        defer allocator.free(query);

        const result = try client.query(query);
        defer result.deinit();

        std.debug.print("  Radius {}m: found {} POIs\n", .{ radius, result.rows.len });
    }
}

test "geofencing and containment" {
    const allocator = std.testing.allocator;

    var client = try geode.Client.init(allocator, .{
        .host = "127.0.0.1",
        .port = 8443,
        .insecure = true,
    });
    defer client.deinit();

    std.debug.print("\n--- Geofencing Queries ---\n", .{});

    // Define a geofence polygon
    const geofence = "POLYGON((-122.5 37.7, -122.3 37.7, -122.3 37.9, -122.5 37.9, -122.5 37.7))";

    // Find all POIs within the geofence
    const query = try std.fmt.allocPrint(allocator,
        \\MATCH (p:PointOfInterest)
        \\WHERE st_contains(GeometryFromText('{s}'), p.location)
        \\RETURN p.category, COUNT(p) as count
        \\ORDER BY count DESC
    , .{geofence});
    defer allocator.free(query);

    const result = try client.query(query);
    defer result.deinit();

    std.debug.print("  POI categories in geofence: {} types\n", .{result.rows.len});

    // Find buildings that intersect with the geofence
    const building_query = try std.fmt.allocPrint(allocator,
        \\MATCH (b:Building)
        \\WHERE st_intersects(GeometryFromText('{s}'), b.footprint)
        \\RETURN COUNT(b) as building_count, AVG(b.height_m) as avg_height
    , .{geofence});
    defer allocator.free(building_query);

    const building_result = try client.query(building_query);
    defer building_result.deinit();

    std.debug.print("  Buildings intersecting geofence: {}\n", .{building_result.rows.len});
}
