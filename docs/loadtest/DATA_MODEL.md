# Internet-Scale Data Model for Load Testing

This document describes the data model designed for load testing Geode at internet scale. The model simulates a social network with content sharing, representing realistic graph patterns found in production systems.

## Scale Targets

| Metric | Target | Rationale |
|--------|--------|-----------|
| Nodes | 100M - 1B | Typical social network scale |
| Edges | 10B - 100B | Average 100-1000 connections per node |
| Properties per node | 5-20 | Realistic entity attributes |
| Properties per edge | 2-5 | Relationship metadata |
| Concurrent queries | 10,000+ | Production workload simulation |
| Query latency (p99) | <100ms | User-facing SLA target |

## Node Types

### 1. User (Target: 100M nodes)

Represents platform users with authentication and profile data.

| Property | Type | Description | Cardinality |
|----------|------|-------------|-------------|
| id | INT64 | Unique identifier | 1 |
| username | STRING | Unique handle | 1 |
| email | STRING | Contact email (indexed) | 1 |
| display_name | STRING | Public name | 1 |
| bio | STRING | Profile description | 0..1 |
| avatar_url | STRING | Profile image URL | 0..1 |
| created_at | DATETIME | Account creation | 1 |
| last_active | DATETIME | Last activity timestamp | 1 |
| verified | BOOLEAN | Verification status | 1 |
| follower_count | INT32 | Cached follower count | 1 |
| following_count | INT32 | Cached following count | 1 |
| location | POINT | Geographic coordinates | 0..1 |
| embedding | VECTOR(128) | User interest embedding | 0..1 |

**Distribution**: Power-law for follower/following counts (most users have few connections, few users have millions).

### 2. Post (Target: 500M nodes)

Content created by users.

| Property | Type | Description | Cardinality |
|----------|------|-------------|-------------|
| id | INT64 | Unique identifier | 1 |
| content | STRING | Post text (max 10KB) | 1 |
| created_at | DATETIME | Publication time | 1 |
| updated_at | DATETIME | Last edit time | 0..1 |
| like_count | INT32 | Cached like count | 1 |
| reply_count | INT32 | Cached reply count | 1 |
| repost_count | INT32 | Cached repost count | 1 |
| language | STRING | ISO language code | 0..1 |
| sensitive | BOOLEAN | Content warning flag | 1 |
| embedding | VECTOR(384) | Content embedding | 0..1 |

**Distribution**: Exponential decay by time (newer posts queried more frequently).

### 3. Topic (Target: 1M nodes)

Tags and categories for content organization.

| Property | Type | Description | Cardinality |
|----------|------|-------------|-------------|
| id | INT64 | Unique identifier | 1 |
| name | STRING | Topic name (indexed) | 1 |
| description | STRING | Topic description | 0..1 |
| post_count | INT32 | Posts using this topic | 1 |
| trending_score | FLOAT | Current trend score | 1 |
| created_at | DATETIME | First usage | 1 |
| category | STRING | Parent category | 0..1 |

**Distribution**: Zipf distribution (few topics dominate most content).

### 4. Media (Target: 200M nodes)

Attached images, videos, and documents.

| Property | Type | Description | Cardinality |
|----------|------|-------------|-------------|
| id | INT64 | Unique identifier | 1 |
| url | STRING | Storage URL | 1 |
| media_type | STRING | MIME type | 1 |
| width | INT32 | Pixel width | 0..1 |
| height | INT32 | Pixel height | 0..1 |
| duration_ms | INT32 | Video/audio duration | 0..1 |
| file_size | INT64 | Size in bytes | 1 |
| alt_text | STRING | Accessibility text | 0..1 |
| blurhash | STRING | Placeholder hash | 0..1 |
| embedding | VECTOR(512) | Visual embedding | 0..1 |

### 5. Conversation (Target: 50M nodes)

Direct message threads between users.

| Property | Type | Description | Cardinality |
|----------|------|-------------|-------------|
| id | INT64 | Unique identifier | 1 |
| created_at | DATETIME | Thread start | 1 |
| last_message_at | DATETIME | Most recent message | 1 |
| message_count | INT32 | Total messages | 1 |
| participant_count | INT32 | Number of participants | 1 |

### 6. Message (Target: 2B nodes)

Individual messages in conversations.

| Property | Type | Description | Cardinality |
|----------|------|-------------|-------------|
| id | INT64 | Unique identifier | 1 |
| content | STRING | Message text | 1 |
| created_at | DATETIME | Send time | 1 |
| read | BOOLEAN | Read receipt | 1 |
| edited | BOOLEAN | Edit flag | 1 |

### 7. Group (Target: 10M nodes)

Community groups for shared interests.

| Property | Type | Description | Cardinality |
|----------|------|-------------|-------------|
| id | INT64 | Unique identifier | 1 |
| name | STRING | Group name | 1 |
| description | STRING | Group description | 0..1 |
| privacy | STRING | public/private/secret | 1 |
| member_count | INT32 | Cached member count | 1 |
| created_at | DATETIME | Creation time | 1 |
| cover_url | STRING | Cover image | 0..1 |

## Edge Types

### 1. FOLLOWS (Target: 50B edges)

User follows another user.

| Property | Type | Description |
|----------|------|-------------|
| created_at | DATETIME | Follow timestamp |
| notifications | BOOLEAN | Notifications enabled |

**Pattern**: Highly asymmetric power-law distribution.

### 2. AUTHORED (Target: 500M edges)

User created a post.

| Property | Type | Description |
|----------|------|-------------|
| via | STRING | Client used (web/mobile/api) |

**Pattern**: One-to-many from User to Post.

### 3. LIKES (Target: 20B edges)

User liked a post.

| Property | Type | Description |
|----------|------|-------------|
| created_at | DATETIME | Like timestamp |

**Pattern**: Many-to-many with power-law on posts.

### 4. REPLIED_TO (Target: 1B edges)

Post is a reply to another post.

| Property | Type | Description |
|----------|------|-------------|
| depth | INT32 | Reply thread depth |

**Pattern**: Tree structure with shallow depth (95% < 5 levels).

### 5. REPOSTED (Target: 2B edges)

User reposted content.

| Property | Type | Description |
|----------|------|-------------|
| created_at | DATETIME | Repost timestamp |
| quote | STRING | Optional quote text |

### 6. TAGGED_WITH (Target: 2B edges)

Post is tagged with a topic.

| Property | Type | Description |
|----------|------|-------------|
| position | INT32 | Tag order in post |

### 7. MENTIONS (Target: 500M edges)

Post mentions a user.

| Property | Type | Description |
|----------|------|-------------|
| position | INT32 | Character offset |

### 8. ATTACHED (Target: 300M edges)

Post has attached media.

| Property | Type | Description |
|----------|------|-------------|
| position | INT32 | Media order |

### 9. PARTICIPATES_IN (Target: 200M edges)

User is part of a conversation.

| Property | Type | Description |
|----------|------|-------------|
| joined_at | DATETIME | Join timestamp |
| last_read_at | DATETIME | Last read position |
| muted | BOOLEAN | Notifications muted |

### 10. SENT (Target: 2B edges)

User sent a message.

| Property | Type | Description |
|----------|------|-------------|
| (none) | | |

### 11. IN_CONVERSATION (Target: 2B edges)

Message belongs to conversation.

| Property | Type | Description |
|----------|------|-------------|
| (none) | | |

### 12. MEMBER_OF (Target: 100M edges)

User is member of a group.

| Property | Type | Description |
|----------|------|-------------|
| role | STRING | member/moderator/admin |
| joined_at | DATETIME | Join timestamp |

### 13. BLOCKS (Target: 500M edges)

User blocks another user.

| Property | Type | Description |
|----------|------|-------------|
| created_at | DATETIME | Block timestamp |
| reason | STRING | Optional reason code |

### 14. SIMILAR_TO (Target: 1B edges)

Content similarity relationship (computed).

| Property | Type | Description |
|----------|------|-------------|
| score | FLOAT | Similarity score 0-1 |
| algorithm | STRING | Computation method |

## Data Generation Strategy

### ID Generation

- **Snowflake IDs**: 64-bit with timestamp, machine ID, sequence
- **Temporal locality**: Recent IDs clustered for cache efficiency

### Distribution Models

1. **Power-law (follower counts)**:

   ```
   P(k) ~ k^(-γ), γ ≈ 2.1
   ```

2. **Exponential decay (temporal)**:

   ```
   P(t) ~ e^(-λt), λ adjusted for 30-day half-life
   ```

3. **Zipf (topic popularity)**:

   ```
   P(rank) ~ 1/rank^s, s ≈ 1.0
   ```

### Batch Generation

```
Phase 1: Generate Users (100M)
  - Create user nodes with properties
  - Generate interest embeddings

Phase 2: Generate Social Graph (50B FOLLOWS)
  - Use preferential attachment model
  - Target power-law degree distribution

Phase 3: Generate Content (500M Posts)
  - Assign to users proportionally
  - Generate content embeddings
  - Create AUTHORED edges

Phase 4: Generate Interactions (25B edges)
  - LIKES, REPLIES, REPOSTS
  - Temporal correlation with post age

Phase 5: Generate Topics and Tags (2B edges)
  - Create topic nodes
  - Assign topics to posts

Phase 6: Generate Media (200M)
  - Create media nodes
  - Attach to posts

Phase 7: Generate Messages (2B)
  - Create conversations
  - Generate message threads

Phase 8: Generate Groups (10M)
  - Create group nodes
  - Assign memberships
```

## Query Workload

### Read Queries (90% of load)

1. **Timeline Query** (40%)

   ```gql
   MATCH (u:User {id: $userId})-[:FOLLOWS]->(f:User)
   MATCH (f)-[:AUTHORED]->(p:Post)
   WHERE p.created_at > $since
   RETURN p ORDER BY p.created_at DESC LIMIT 50
   ```

2. **User Profile** (20%)

   ```gql
   MATCH (u:User {id: $userId})
   OPTIONAL MATCH (u)-[:AUTHORED]->(p:Post)
   RETURN u, collect(p)[0..10] AS recent_posts
   ```

3. **Post Detail** (15%)

   ```gql
   MATCH (p:Post {id: $postId})
   MATCH (a:User)-[:AUTHORED]->(p)
   OPTIONAL MATCH (p)-[:ATTACHED]->(m:Media)
   OPTIONAL MATCH (p)-[:TAGGED_WITH]->(t:Topic)
   RETURN p, a, collect(m) AS media, collect(t) AS topics
   ```

4. **Search** (10%)

   ```gql
   CALL vector.search('post_embeddings', $query_vector, 50)
   YIELD node, score
   MATCH (a:User)-[:AUTHORED]->(node)
   RETURN node, a, score
   ```

5. **Notifications** (5%)

   ```gql
   MATCH (u:User {id: $userId})<-[:MENTIONS|LIKES|REPLIED_TO]-(activity)
   WHERE activity.created_at > $lastCheck
   RETURN activity ORDER BY activity.created_at DESC LIMIT 100
   ```

### Write Queries (10% of load)

1. **Create Post** (4%)
2. **Like/Unlike** (3%)
3. **Follow/Unfollow** (2%)
4. **Send Message** (1%)

## Indexing Strategy

### Primary Indexes

| Node/Edge | Property | Index Type | Purpose |
|-----------|----------|------------|---------|
| User | id | B-tree | Primary lookup |
| User | username | B-tree unique | Username lookup |
| User | email | B-tree unique | Auth lookup |
| User | embedding | HNSW | Similarity search |
| Post | id | B-tree | Primary lookup |
| Post | created_at | B-tree | Timeline queries |
| Post | embedding | HNSW | Content search |
| Topic | name | B-tree unique | Tag lookup |
| Media | id | B-tree | Primary lookup |

### Composite Indexes

| Nodes | Pattern | Purpose |
|-------|---------|---------|
| User-FOLLOWS-User | Adjacency list | Social graph traversal |
| User-AUTHORED-Post | Adjacency + time | User timeline |
| Post-TAGGED_WITH-Topic | Adjacency | Topic pages |

## Performance Targets

| Query Type | p50 | p95 | p99 |
|------------|-----|-----|-----|
| Timeline | 10ms | 30ms | 100ms |
| User Profile | 5ms | 15ms | 50ms |
| Post Detail | 3ms | 10ms | 30ms |
| Vector Search | 20ms | 50ms | 150ms |
| Graph Traversal (3 hops) | 50ms | 150ms | 500ms |

## Monitoring Metrics

1. **Throughput**: Queries per second by type
2. **Latency**: p50/p95/p99 by query type
3. **Error Rate**: Failed queries percentage
4. **Resource Utilization**: CPU, memory, disk I/O, network
5. **Cache Hit Rate**: Index and data page cache
6. **Connection Pool**: Active/idle/waiting connections

## Schema Evolution

The model supports schema evolution through:

1. **Property Addition**: New properties with defaults
2. **Index Addition**: Online index building
3. **Label Addition**: New node/edge types
4. **Property Migration**: Gradual type changes

## References

- [Twitter's Graph Database](https://blog.twitter.com/engineering)
- [Facebook TAO](https://www.usenix.org/conference/atc13/technical-sessions/presentation/bronson)
- [LinkedIn's LIX](https://engineering.linkedin.com/blog/2020/graph-services)
