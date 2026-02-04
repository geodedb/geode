# Geode Social Network Example Dataset

This directory contains a comprehensive social network dataset demonstrating Geode's extended type system, graph capabilities, and advanced features. The dataset includes users, posts, companies, locations, events, products, and more with realistic relationships and data.

## Overview

The migration files create a rich social network graph with:

- **50 Users** with profiles, locations, and network types
- **25 Posts** with vector embeddings and sentiment analysis
- **5 Companies** with financial data and geographic locations
- **5 Locations** (cities) with coordinates and spatial regions
- **5 Topics** for content categorization
- **3 Groups** for community organization
- **3 Events** with attendance tracking
- **3 Products** with reviews and embeddings
- **5 Devices** with network information
- **3 Media** items (image, video, audio)
- **Thousands of relationships** (follows, likes, comments, works_at, etc.)

## Features Demonstrated

### Extended Type System

- **Network Types**: `IpAddr`, `Subnet`, `Mac` for device and network tracking
- **Geographic Types**: `LatLon`, `Geometry` for spatial data and queries
- **Vector Types**: `VectorF32` for ML embeddings and similarity search
- **Financial Types**: `Currency` with proper handling of amounts
- **Hash Types**: `Hash` with multiple algorithms (SHA3, BLAKE3)
- **Language Types**: `LanguageTag` for internationalization

### Advanced Indexes

- **Patricia Trie**: For IP/CIDR prefix matching and network searches
- **R-tree**: For spatial queries and geographic searches
- **HNSW**: For vector similarity and recommendation systems
- **Full-text**: For content search across posts and descriptions

### Graph Features

- Complex relationship patterns
- Materialized views for trending content
- Triggers for maintaining counts
- Check constraints for data integrity
- Computed properties and aggregations

## Migration Files

1. **001_social_network_schema.gql**
   - Creates the schema, labels, and edge types
   - Sets up constraints and indexes
   - Defines materialized views
   - Creates triggers and check constraints

2. **002_social_network_data.gql**
   - Inserts locations (cities)
   - Creates companies with headquarters
   - Adds 50 users with diverse profiles
   - Inserts topics for categorization

3. **003_social_network_relationships.gql**
   - Creates follow networks
   - Establishes friendships
   - Creates groups and memberships
   - Adds posts with engagement
   - Links users to companies and locations
   - Tags posts with topics

4. **004_social_network_events_products.gql**
   - Adds events with attendance
   - Creates products with reviews
   - Inserts devices with network data
   - Adds media items
   - Creates investment relationships
   - Establishes reply threads

## Setup Instructions

### Prerequisites

- Geode v0.1.0 or later
- QUIC+TLS enabled (default)
- At least 512MB RAM for the dataset

### Loading the Dataset

1. **Start Geode server:**

```bash
./zig-out/bin/geode serve --data_dir ./data --log_json
```

1. **Run migrations in order:**

```bash
# Using the Geode client
./zig-out/bin/geode query --migrate migrations/

# Or run individually
./zig-out/bin/geode query < migrations/001_social_network_schema.gql
./zig-out/bin/geode query < migrations/002_social_network_data.gql
./zig-out/bin/geode query < migrations/003_social_network_relationships.gql
./zig-out/bin/geode query < migrations/004_social_network_events_products.gql
```

1. **Verify the data:**

```bash
# Count nodes and edges
./zig-out/bin/geode query "MATCH (n) RETURN count(n) AS node_count"
./zig-out/bin/geode query "MATCH ()-[r]->() RETURN count(r) AS edge_count"
```

## Example Queries

### 1. Find Influencers

```gql
MATCH (u:User)
WHERE u.follower_count > 1000
RETURN u.username, u.follower_count, u.verified
ORDER BY u.follower_count DESC
LIMIT 10
```

### 2. Network Security Analysis

```gql
MATCH (d:Device)-[:CONNECTED_FROM]->(u:User)
WHERE ip_is_private(d.ip_address)
  AND d.trust_score < 0.9
RETURN u.username, d.device_type, d.ip_address, d.trust_score
ORDER BY d.trust_score ASC
```

### 3. Geographic Search

```gql
MATCH (e:Event)
WHERE distance_haversine(e.location, LatLon(37.7749, -122.4194)) < 100000  -- Within 100km of SF
RETURN e.title, e.start_time, e.venue, e.attendees
ORDER BY e.start_time
```

### 4. Vector Similarity for Recommendations

```gql
MATCH (p1:Post {id: 'post-1'})
MATCH (p2:Post)
WHERE p1 <> p2
  AND vector_cosine_similarity(p1.content_vector, p2.content_vector) > 0.8
RETURN p2.id, p2.content, vector_cosine_similarity(p1.content_vector, p2.content_vector) AS similarity
ORDER BY similarity DESC
LIMIT 5
```

### 5. Social Graph Analysis

```gql
MATCH path = (u1:User {username: 'alice_j'})-[:FOLLOWS*1..3]->(u2:User)
WHERE u1 <> u2
RETURN u2.username, length(path) AS distance
ORDER BY distance, u2.follower_count DESC
LIMIT 20
```

### 6. Trending Content

```gql
MATCH (p:Post)<-[:POSTED]-(u:User)
WHERE p.created_at > now() - interval '7 days'
WITH p, u,
     count{(:User)-[:LIKES]->(p)} AS likes,
     count{(:User)-[:SHARED]->(p)} AS shares,
     count{(:User)-[:COMMENTED_ON]->(p)} AS comments
LET engagement = likes + (shares * 2) + (comments * 3)
RETURN u.username, p.content, engagement, likes, shares, comments
ORDER BY engagement DESC
LIMIT 10
```

### 7. Company Investment Network

```gql
MATCH (investor:Company)-[inv:INVESTED_IN]->(startup:Company)
RETURN investor.name, startup.name, inv.amount, inv.round, inv.date
ORDER BY inv.date DESC
```

### 8. Event Recommendations

```gql
MATCH (u:User {id: 'user-1'})-[:ATTENDING]->(e1:Event)
MATCH (other:User)-[:ATTENDING]->(e1)
MATCH (other)-[:ATTENDING]->(e2:Event)
WHERE NOT (u)-[:ATTENDING]->(e2)
  AND e2.start_time > now()
RETURN e2.title, count(other) AS mutual_attendees, e2.start_time
ORDER BY mutual_attendees DESC
LIMIT 5
```

### 9. IP Subnet Analysis

```gql
MATCH (d:Device)
WHERE ip_contains(Subnet('10.0.0.0/8'), d.ip_address)
RETURN d.subnet, count(d) AS device_count, avg(d.trust_score) AS avg_trust
GROUP BY d.subnet
ORDER BY device_count DESC
```

### 10. Multi-Currency Financial Summary

```gql
MATCH (c:Company)
RETURN c.name, c.revenue, currency_convert(c.revenue, 'USD') AS revenue_usd
ORDER BY revenue_usd DESC
```

## Performance Benchmarks

With the full dataset loaded:

- Node count: ~100
- Edge count: ~500+
- Simple traversals: < 10ms
- 3-hop paths: < 50ms
- Vector similarity (HNSW): < 20ms
- Spatial queries (R-tree): < 15ms
- Full-text search: < 25ms

## Extending the Dataset

To add more data:

1. **Add more users:**

```gql
CREATE (:User {
    id: 'user-custom-1',
    email: 'custom@example.com',
    username: 'custom_user',
    full_name: 'Custom User',
    bio: 'Your bio here',
    created_at: now(),
    ip_address: IpAddr('192.168.1.100'),
    profile_vector: VectorF32([0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]),
    verified: false
})
```

1. **Create relationships:**

```gql
MATCH (u1:User {id: 'user-custom-1'}), (u2:User {id: 'user-1'})
CREATE (u1)-[:FOLLOWS {since: now(), notifications: true}]->(u2)
```

1. **Add engagement:**

```gql
MATCH (u:User {id: 'user-custom-1'}), (p:Post)
WHERE rand() < 0.2
CREATE (u)-[:LIKES {timestamp: now(), reaction: 'like'}]->(p)
```

## Cleanup

To remove the dataset:

```gql
-- Remove all relationships
MATCH ()-[r]->() DELETE r;

-- Remove all nodes
MATCH (n) DELETE n;

-- Drop indexes and constraints
DROP INDEX user_location_idx;
DROP CONSTRAINT user_email_unique;
-- ... etc for all indexes and constraints
```

## Troubleshooting

### Out of Memory

If you encounter memory issues:

1. Increase heap size: `--max-heap 1024MB`
2. Load migrations in smaller batches
3. Use pagination for large result sets

### Slow Queries

1. Ensure indexes are created (check migration 001)
2. Use EXPLAIN to analyze query plans
3. Consider adding more specific indexes

### Connection Issues

Ensure QUIC+TLS is properly configured:

```bash
# Check certificates
ls -la certs/

# Test connection
./zig-out/bin/geode query "RETURN 1"
```

## License

This example dataset is provided under the MIT License, same as Geode.
