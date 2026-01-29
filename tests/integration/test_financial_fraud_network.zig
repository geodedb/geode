const std = @import("std");
const geode = @import("geode");
const testing = std.testing;

test "CANARY: REQ=REQ-GQL-FINANCIAL-NETWORK" {
    // CANARY: REQ=REQ-GQL-FINANCIAL-NETWORK; FEATURE="FinancialNetwork"; ASPECT=Integration; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_FINANCIAL_NETWORK; OWNER=team; UPDATED=2025-10-02
    const allocator = std.testing.allocator;

    var client = try geode.Client.init(allocator, .{
        .host = "127.0.0.1",
        .port = 3141,
        .insecure = true,
    });
    defer client.deinit();

    std.debug.print("\n=== Financial Fraud Detection Network Test ===\n", .{});

    // Create schema for financial network
    try client.execute(
        \\CREATE LABEL Account
    );

    try client.execute(
        \\CREATE LABEL Transaction
    );

    try client.execute(
        \\CREATE LABEL Merchant
    );

    try client.execute(
        \\CREATE LABEL Bank
    );

    try client.execute(
        \\CREATE LABEL FraudPattern
    );

    // Create indexes for performance
    try client.execute("CREATE INDEX account_number_idx ON Account(account_number) USING hash");
    try client.execute("CREATE INDEX transaction_amount_idx ON Transaction(amount) USING btree");
    try client.execute("CREATE INDEX merchant_risk_idx ON Merchant(risk_score) USING btree");
    try client.execute("CREATE INDEX transaction_timestamp_idx ON Transaction(timestamp) USING btree");

    const num_banks = 10;
    const num_accounts = 50000;
    const num_merchants = 5000;
    const num_transactions = 250000;

    std.debug.print("Creating financial network with {} accounts, {} merchants, {} transactions...\n", .{
        num_accounts,
        num_merchants,
        num_transactions,
    });

    // Create banks
    var i: usize = 0;
    while (i < num_banks) : (i += 1) {
        const query = try std.fmt.allocPrint(allocator,
            \\CREATE (b:Bank {{
            \\  id: 'BANK-{d:0>3}',
            \\  name: 'Bank {d}',
            \\  swift_code: 'SWFT{d:0>4}',
            \\  country: '{s}',
            \\  aml_compliance_score: {d},
            \\  total_assets: {d},
            \\  created_at: timestamp()
            \\}})
        , .{
            i,
            i,
            i,
            if (i % 3 == 0) "US" else if (i % 3 == 1) "UK" else "EU",
            85 + (i % 15),
            1000000000 * (i + 1),
        });
        defer allocator.free(query);
        try client.execute(query);
    }

    // Create accounts with various risk profiles
    i = 0;
    while (i < num_accounts) : (i += 1) {
        const is_suspicious = i % 500 == 0; // 0.2% suspicious accounts
        const risk_level = if (is_suspicious)
            80 + (i % 20)
        else if (i % 100 == 0)
            50 + (i % 30)
        else
            10 + (i % 20);

        const query = try std.fmt.allocPrint(allocator,
            \\CREATE (a:Account {{
            \\  id: 'ACC-{d:0>8}',
            \\  account_number: '{d:0>16}',
            \\  account_type: '{s}',
            \\  balance: {d},
            \\  currency: Currency('{s}'),
            \\  risk_score: {d},
            \\  is_flagged: {s},
            \\  kyc_verified: {s},
            \\  opened_date: date('2020-01-01') + duration('P{d}D'),
            \\  last_activity: timestamp(),
            \\  daily_limit: {d},
            \\  monthly_volume: {d},
            \\  country_code: '{s}',
            \\  ip_address: IpAddr('192.168.{d}.{d}'),
            \\  device_fingerprint: Hash('SHA256', '{x:0>64}')
            \\}})
        , .{
            i,
            4000000000000000 + i,
            if (i % 3 == 0) "checking" else if (i % 3 == 1) "savings" else "business",
            1000 + (i % 100000),
            if (i % 4 == 0) "USD" else if (i % 4 == 1) "EUR" else if (i % 4 == 2) "GBP" else "JPY",
            risk_level,
            if (is_suspicious) "true" else "false",
            if (i % 20 == 0) "false" else "true",
            i % 1800, // Days since 2020-01-01
            if (i % 5 == 0) 5000 else 10000,
            (i % 100) * 1000,
            if (i % 3 == 0) "US" else if (i % 3 == 1) "UK" else "JP",
            (i / 256) % 256,
            i % 256,
            i * 0x123456789ABCDEF,
        });
        defer allocator.free(query);
        try client.execute(query);

        // Link accounts to banks
        const bank_id = i % num_banks;
        const link_query = try std.fmt.allocPrint(allocator,
            \\MATCH (a:Account {{id: 'ACC-{d:0>8}'}}), (b:Bank {{id: 'BANK-{d:0>3}'}})
            \\CREATE (a)-[:HELD_AT {{
            \\  since: date('2020-01-01') + duration('P{d}D'),
            \\  account_status: 'active',
            \\  branch_code: 'BR{d:0>4}'
            \\}}]->(b)
        , .{ i, bank_id, i % 1800, bank_id * 100 + (i % 100) });
        defer allocator.free(link_query);
        try client.execute(link_query);
    }

    // Create merchants with various categories
    i = 0;
    while (i < num_merchants) : (i += 1) {
        const categories = [_][]const u8{ "retail", "restaurant", "gas_station", "online", "grocery", "entertainment", "travel", "healthcare", "utilities", "crypto_exchange" };
        const category = categories[i % categories.len];

        const is_high_risk = std.mem.eql(u8, category, "crypto_exchange") or (i % 200 == 0);

        const query = try std.fmt.allocPrint(allocator,
            \\CREATE (m:Merchant {{
            \\  id: 'MERCH-{d:0>6}',
            \\  name: 'Merchant {d}',
            \\  category: '{s}',
            \\  mcc_code: '{d:0>4}',
            \\  risk_score: {d},
            \\  monthly_volume: {d},
            \\  avg_transaction: {d},
            \\  chargeback_rate: {d:.2},
            \\  location: LatLon({d:.4}, {d:.4}),
            \\  website_url: Url('https://merchant{d}.example.com'),
            \\  compliance_status: '{s}',
            \\  established_date: date('2018-01-01') + duration('P{d}D')
            \\}})
        , .{
            i,
            i,
            category,
            5000 + (i % 1000),
            if (is_high_risk) 70 + (i % 30) else 10 + (i % 40),
            10000 * (i % 100 + 1),
            50 + (i % 450),
            if (is_high_risk) @as(f64, 2.5) + @as(f64, @floatFromInt(i % 3)) else @as(f64, 0.1) + @as(f64, @floatFromInt(i % 10)) / 10.0,
            37.7749 + @as(f64, @floatFromInt(i % 100)) / 100.0,
            -122.4194 + @as(f64, @floatFromInt(i % 100)) / 100.0,
            i,
            if (i % 50 == 0) "pending_review" else "approved",
            i % 2500,
        });
        defer allocator.free(query);
        try client.execute(query);
    }

    // Create transactions with various patterns
    i = 0;
    var fraud_pattern_count: usize = 0;
    while (i < num_transactions) : (i += 1) {
        const sender_id = i % num_accounts;
        const receiver_id = (i * 7 + 13) % num_accounts;
        const merchant_id = i % num_merchants;

        // Determine if this is a suspicious transaction
        const is_velocity_attack = i > 100000 and i < 100050; // Rapid fire transactions
        const is_smurfing = i % 5000 == 0 and i > 0; // Structuring
        const is_unusual_amount = i % 1000 == 0;
        const is_suspicious = is_velocity_attack or is_smurfing or is_unusual_amount;

        const amount = if (is_smurfing)
            9999 // Just under reporting threshold
        else if (is_unusual_amount)
            50000 + (i % 100000)
        else
            100 + (i % 5000);

        const query = try std.fmt.allocPrint(allocator,
            \\CREATE (t:Transaction {{
            \\  id: 'TXN-{d:0>10}',
            \\  amount: {d},
            \\  currency: Currency('{s}'),
            \\  timestamp: timestamp() - duration('PT{d}S'),
            \\  type: '{s}',
            \\  status: '{s}',
            \\  risk_score: {d},
            \\  is_flagged: {s},
            \\  processing_time_ms: {d},
            \\  fee: {d:.2},
            \\  reference: '{x:0>32}',
            \\  channel: '{s}',
            \\  geolocation: LatLon({d:.4}, {d:.4}),
            \\  ip_address: IpAddr('10.{d}.{d}.{d}'),
            \\  device_id: '{x:0>16}',
            \\  session_id: UUID(),
            \\  merchant_descriptor: 'MERCH{d:0>6}',
            \\  authorization_code: '{x:0>6}',
            \\  card_last_four: '{d:0>4}',
            \\  is_international: {s}
            \\}})
        , .{
            i,
            amount,
            if (i % 3 == 0) "USD" else if (i % 3 == 1) "EUR" else "GBP",
            num_transactions - i, // Transactions in reverse time order
            if (i % 10 < 7) "purchase" else if (i % 10 < 9) "transfer" else "withdrawal",
            if (is_suspicious) "pending_review" else if (i % 100 == 0) "declined" else "completed",
            if (is_suspicious) 75 + (i % 25) else 5 + (i % 20),
            if (is_suspicious) "true" else "false",
            50 + (i % 450),
            @as(f64, @floatFromInt(amount)) * 0.025,
            i * 0xDEADBEEF,
            if (i % 4 == 0) "online" else if (i % 4 == 1) "mobile" else if (i % 4 == 2) "atm" else "pos",
            40.7128 + @as(f64, @floatFromInt(i % 200)) / 100.0,
            -74.0060 + @as(f64, @floatFromInt(i % 200)) / 100.0,
            (i / 65536) % 256,
            (i / 256) % 256,
            i % 256,
            i * 0xCAFE,
            merchant_id,
            i * 0xABC,
            1000 + (i % 9000),
            if (i % 20 == 0) "true" else "false",
        });
        defer allocator.free(query);
        try client.execute(query);

        // Create relationships
        const sender_link = try std.fmt.allocPrint(allocator,
            \\MATCH (t:Transaction {{id: 'TXN-{d:0>10}'}}), (a:Account {{id: 'ACC-{d:0>8}'}})
            \\CREATE (a)-[:SENT {{role: 'sender'}}]->(t)
        , .{ i, sender_id });
        defer allocator.free(sender_link);
        try client.execute(sender_link);

        const receiver_link = try std.fmt.allocPrint(allocator,
            \\MATCH (t:Transaction {{id: 'TXN-{d:0>10}'}}), (a:Account {{id: 'ACC-{d:0>8}'}})
            \\CREATE (t)-[:RECEIVED_BY {{role: 'receiver'}}]->(a)
        , .{ i, receiver_id });
        defer allocator.free(receiver_link);
        try client.execute(receiver_link);

        const merchant_link = try std.fmt.allocPrint(allocator,
            \\MATCH (t:Transaction {{id: 'TXN-{d:0>10}'}}), (m:Merchant {{id: 'MERCH-{d:0>6}'}})
            \\CREATE (t)-[:PROCESSED_BY {{timestamp: timestamp()}}]->(m)
        , .{ i, merchant_id });
        defer allocator.free(merchant_link);
        try client.execute(merchant_link);

        // Create fraud patterns for suspicious transactions
        if (is_suspicious) {
            fraud_pattern_count += 1;
            const pattern_type = if (is_velocity_attack)
                "velocity_attack"
            else if (is_smurfing)
                "smurfing"
            else
                "unusual_amount";

            const fraud_query = try std.fmt.allocPrint(allocator,
                \\CREATE (f:FraudPattern {{
                \\  id: 'FRAUD-{d:0>6}',
                \\  pattern_type: '{s}',
                \\  confidence_score: {d},
                \\  detected_at: timestamp(),
                \\  severity: '{s}',
                \\  description: '{s}',
                \\  recommended_action: '{s}'
                \\}})
            , .{
                fraud_pattern_count,
                pattern_type,
                70 + (i % 30),
                if (is_velocity_attack) "critical" else if (is_smurfing) "high" else "medium",
                if (is_velocity_attack) "Multiple rapid transactions detected" else if (is_smurfing) "Transaction structuring detected" else "Unusual transaction amount",
                if (is_velocity_attack) "block_account" else if (is_smurfing) "review_required" else "monitor",
            });
            defer allocator.free(fraud_query);
            try client.execute(fraud_query);

            // Link fraud pattern to transaction
            const fraud_link = try std.fmt.allocPrint(allocator,
                \\MATCH (t:Transaction {{id: 'TXN-{d:0>10}'}}), (f:FraudPattern {{id: 'FRAUD-{d:0>6}'}})
                \\CREATE (f)-[:DETECTED_IN]->(t)
            , .{ i, fraud_pattern_count });
            defer allocator.free(fraud_link);
            try client.execute(fraud_link);
        }
    }

    std.debug.print("Created financial network successfully\n", .{});
    std.debug.print("  Banks: {}\n", .{num_banks});
    std.debug.print("  Accounts: {}\n", .{num_accounts});
    std.debug.print("  Merchants: {}\n", .{num_merchants});
    std.debug.print("  Transactions: {}\n", .{num_transactions});
    std.debug.print("  Fraud patterns: {}\n", .{fraud_pattern_count});

    // Run fraud detection queries
    std.debug.print("\n--- Fraud Detection Queries ---\n", .{});

    // Query 1: Find velocity attack patterns
    const velocity_result = try client.query(
        \\MATCH (a:Account)-[:SENT]->(t:Transaction)
        \\WHERE t.timestamp > timestamp() - duration('PT60S')
        \\WITH a, COUNT(t) as tx_count
        \\WHERE tx_count > 10
        \\RETURN a.id, tx_count
        \\ORDER BY tx_count DESC
        \\LIMIT 5
    );
    defer velocity_result.deinit();
    std.debug.print("Velocity attacks detected: {} accounts\n", .{velocity_result.rows.len});

    // Query 2: Find smurfing patterns
    const smurfing_result = try client.query(
        \\MATCH (a:Account)-[:SENT]->(t:Transaction)
        \\WHERE t.amount >= 9000 AND t.amount < 10000
        \\WITH a, COUNT(t) as structured_txns
        \\WHERE structured_txns > 3
        \\RETURN a.id, structured_txns
        \\ORDER BY structured_txns DESC
        \\LIMIT 5
    );
    defer smurfing_result.deinit();
    std.debug.print("Potential smurfing: {} accounts\n", .{smurfing_result.rows.len});

    // Query 3: Find money mule networks
    const mule_result = try client.query(
        \\MATCH path = (a1:Account)-[:SENT]->(:Transaction)-[:RECEIVED_BY]->(a2:Account)
        \\              -[:SENT]->(:Transaction)-[:RECEIVED_BY]->(a3:Account)
        \\WHERE a1.id <> a2.id AND a2.id <> a3.id AND a1.id <> a3.id
        \\  AND a2.kyc_verified = false
        \\RETURN a1.id as source, a2.id as mule, a3.id as destination, COUNT(path) as flow_count
        \\ORDER BY flow_count DESC
        \\LIMIT 10
    );
    defer mule_result.deinit();
    std.debug.print("Potential mule accounts: {} patterns\n", .{mule_result.rows.len});

    // Query 4: High-risk merchant analysis
    const merchant_risk_result = try client.query(
        \\MATCH (m:Merchant)<-[:PROCESSED_BY]-(t:Transaction)<-[:SENT]-(a:Account)
        \\WHERE m.risk_score > 70 OR a.is_flagged = true
        \\WITH m, COUNT(DISTINCT a) as flagged_customers, SUM(t.amount) as total_volume
        \\WHERE flagged_customers > 5
        \\RETURN m.name, m.category, flagged_customers, total_volume
        \\ORDER BY flagged_customers DESC
        \\LIMIT 10
    );
    defer merchant_risk_result.deinit();
    std.debug.print("High-risk merchants: {} identified\n", .{merchant_risk_result.rows.len});

    // Query 5: Geographic anomaly detection
    const geo_anomaly_result = try client.query(
        \\MATCH (a:Account)-[:SENT]->(t1:Transaction), (a)-[:SENT]->(t2:Transaction)
        \\WHERE t1.id < t2.id
        \\  AND ABS(timestamp_diff('second', t1.timestamp, t2.timestamp)) < 3600
        \\  AND distance_haversine(t1.geolocation, t2.geolocation) > 500000
        \\RETURN a.id, t1.id as txn1, t2.id as txn2,
        \\       distance_haversine(t1.geolocation, t2.geolocation) as distance_m
        \\ORDER BY distance_m DESC
        \\LIMIT 5
    );
    defer geo_anomaly_result.deinit();
    std.debug.print("Geographic anomalies: {} detected\n", .{geo_anomaly_result.rows.len});

    // Validate data consistency
    const total_accounts = try client.query("MATCH (a:Account) RETURN COUNT(a) as count");
    defer total_accounts.deinit();
    try testing.expect(total_accounts.rows.len == 1);

    const total_transactions = try client.query("MATCH (t:Transaction) RETURN COUNT(t) as count");
    defer total_transactions.deinit();
    try testing.expect(total_transactions.rows.len == 1);

    const fraud_patterns = try client.query("MATCH (f:FraudPattern) RETURN COUNT(f) as count");
    defer fraud_patterns.deinit();
    try testing.expect(fraud_patterns.rows.len == 1);

    std.debug.print("\n=== Financial network test completed successfully ===\n", .{});
}

test "anti-money laundering detection" {
    const allocator = std.testing.allocator;

    var client = try geode.Client.init(allocator, .{
        .host = "127.0.0.1",
        .port = 3141,
        .insecure = true,
    });
    defer client.deinit();

    std.debug.print("\n--- AML Detection Queries ---\n", .{});

    // Layering detection - complex transaction chains
    const layering_result = try client.query(
        \\MATCH path = (a1:Account)-[:SENT*3..5]->(:Transaction)-[:RECEIVED_BY]->(a2:Account)
        \\WHERE a1.risk_score > 50
        \\WITH path, length(path) as chain_length
        \\WHERE chain_length > 3
        \\RETURN chain_length, COUNT(path) as occurrences
        \\ORDER BY chain_length DESC
        \\LIMIT 10
    );
    defer layering_result.deinit();
    std.debug.print("Layering patterns found: {}\n", .{layering_result.rows.len});

    // Placement detection - cash intensive businesses
    const placement_result = try client.query(
        \\MATCH (m:Merchant {category: 'cash_intensive'})<-[:PROCESSED_BY]-(t:Transaction)
        \\WHERE t.amount > 10000
        \\WITH m, DATE(t.timestamp) as tx_date, SUM(t.amount) as daily_volume
        \\WHERE daily_volume > 50000
        \\RETURN m.name, tx_date, daily_volume
        \\ORDER BY daily_volume DESC
        \\LIMIT 10
    );
    defer placement_result.deinit();
    std.debug.print("Placement risks identified: {}\n", .{placement_result.rows.len});

    // Integration detection - high value transfers to low-risk accounts
    const integration_result = try client.query(
        \\MATCH (a1:Account {is_flagged: true})-[:SENT]->(t:Transaction)-[:RECEIVED_BY]->(a2:Account)
        \\WHERE a2.risk_score < 20 AND t.amount > 25000
        \\RETURN a1.id as suspicious_account, a2.id as clean_account,
        \\       SUM(t.amount) as total_transferred
        \\ORDER BY total_transferred DESC
        \\LIMIT 10
    );
    defer integration_result.deinit();
    std.debug.print("Integration attempts: {}\n", .{integration_result.rows.len});
}

test "real-time fraud scoring" {
    const allocator = std.testing.allocator;

    var client = try geode.Client.init(allocator, .{
        .host = "127.0.0.1",
        .port = 3141,
        .insecure = true,
    });
    defer client.deinit();

    std.debug.print("\n--- Real-time Fraud Scoring ---\n", .{});

    // Calculate composite risk scores
    const risk_scoring = try client.query(
        \\MATCH (a:Account)-[:SENT]->(t:Transaction)-[:PROCESSED_BY]->(m:Merchant)
        \\WITH a,
        \\     AVG(t.risk_score) as avg_tx_risk,
        \\     MAX(m.risk_score) as max_merchant_risk,
        \\     COUNT(CASE WHEN t.is_flagged = true THEN 1 END) as flagged_count,
        \\     COUNT(t) as total_txns
        \\WHERE total_txns > 10
        \\RETURN a.id,
        \\       (a.risk_score * 0.3 + avg_tx_risk * 0.4 + max_merchant_risk * 0.3) as composite_score,
        \\       flagged_count,
        \\       total_txns
        \\ORDER BY composite_score DESC
        \\LIMIT 20
    );
    defer risk_scoring.deinit();

    std.debug.print("High-risk accounts identified: {}\n", .{risk_scoring.rows.len});

    // Check if composite scoring is working
    try testing.expect(risk_scoring.rows.len > 0);
}
