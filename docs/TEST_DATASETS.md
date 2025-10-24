# Test Dataset Schemas

## Overview

This document describes the schemas and data models used in Geode's integration tests. Each dataset is designed to test specific features and performance characteristics at scale.

## Social Network Dataset

### Schema

#### Labels (Node Types)

**User**
```gql
CREATE LABEL User {
  id: STRING PRIMARY KEY,
  username: STRING UNIQUE NOT NULL,
  email: STRING UNIQUE,
  email_domain: Domain,
  password_hash: Hash,
  created_at: TIMESTAMP,
  last_login: TIMESTAMP,
  bio: STRING,
  location: LatLon,
  follower_count: INTEGER,
  following_count: INTEGER,
  post_count: INTEGER,
  verified: BOOLEAN,
  profile_jsonb: Jsonb,
  avatar: Bytea,
  homepage: Url,
  preferences: JSONB
}
```

**Post**
```gql
CREATE LABEL Post {
  id: STRING PRIMARY KEY,
  content: STRING NOT NULL,
  created_at: TIMESTAMP,
  updated_at: TIMESTAMP,
  like_count: INTEGER DEFAULT 0,
  comment_count: INTEGER DEFAULT 0,
  share_count: INTEGER DEFAULT 0,
  embedding: Vector(512),  // For content similarity
  hashtags: Array[STRING],
  mentions: Array[STRING],
  media_urls: Array[Url],
  metadata: Json,
  content_xml: Xml,
  language: LanguageTag,
  sentiment_score: FLOAT
}
```

**Group**
```gql
CREATE LABEL Group {
  id: STRING PRIMARY KEY,
  name: STRING NOT NULL,
  description: STRING,
  created_at: TIMESTAMP,
  member_count: INTEGER,
  post_count: INTEGER,
  category: STRING,
  privacy: ENUM('public', 'private', 'secret'),
  rules: JSONB,
  cover_image: Url
}
```

**Event**
```gql
CREATE LABEL Event {
  id: STRING PRIMARY KEY,
  title: STRING NOT NULL,
  description: STRING,
  start_time: TIMESTAMP,
  end_time: TIMESTAMP,
  location: LatLon,
  venue: STRING,
  capacity: INTEGER,
  attendee_count: INTEGER,
  ticket_price: Currency,
  tags: Array[STRING],
  organizer_id: STRING REFERENCES User(id)
}
```

#### Edge Types (Relationships)

- `FOLLOWS`: User -> User (follower relationship)
- `FRIENDS_WITH`: User <-> User (bidirectional friendship)
- `POSTED`: User -> Post (content creation)
- `LIKED`: User -> Post (engagement)
- `COMMENTED`: User -> Post (with comment text)
- `MEMBER_OF`: User -> Group (membership)
- `ATTENDING`: User -> Event (event participation)
- `ORGANIZED`: User -> Event (event organization)

### Data Characteristics

- **User Distribution**: Power-law follower distribution (few influencers, many regular users)
- **Posting Frequency**: Temporal patterns with peak hours
- **Engagement Rates**: 10% like rate, 2% comment rate, 1% share rate
- **Group Sizes**: Log-normal distribution (many small groups, few large ones)
- **Geographic Distribution**: Clustered around major population centers

## IoT Network Dataset

### Schema

#### Labels (Node Types)

**Device**
```gql
CREATE LABEL Device {
  id: STRING PRIMARY KEY,
  device_id: STRING UNIQUE,
  device_type: ENUM('sensor', 'gateway', 'actuator', 'controller'),
  manufacturer: STRING,
  model: STRING,
  firmware_version: Version,
  ip_address: IpAddr,
  mac_address: Mac,
  location: LatLon,
  installation_date: DATE,
  last_seen: TIMESTAMP,
  status: ENUM('active', 'inactive', 'maintenance', 'error'),
  trust_score: INTEGER,
  network_segment: Subnet,
  mgmt_url: Url,
  feature_flags: VarBit
}
```

**Sensor**
```gql
CREATE LABEL Sensor {
  id: STRING PRIMARY KEY,
  sensor_type: STRING,
  unit: STRING,
  min_value: FLOAT,
  max_value: FLOAT,
  accuracy: FLOAT,
  sampling_rate_hz: FLOAT,
  calibration_date: DATE,
  location: LatLon,
  elevation: FLOAT
}
```

**Metric**
```gql
CREATE LABEL Metric {
  id: STRING PRIMARY KEY,
  timestamp: TIMESTAMP,
  value: FLOAT,
  unit: STRING,
  quality: ENUM('good', 'uncertain', 'bad'),
  raw_value: BYTEA,
  processed: BOOLEAN,
  anomaly_score: FLOAT
}
```

**Alert**
```gql
CREATE LABEL Alert {
  id: STRING PRIMARY KEY,
  alert_type: STRING,
  severity: ENUM('info', 'warning', 'error', 'critical'),
  message: STRING,
  timestamp: TIMESTAMP,
  acknowledged: BOOLEAN,
  acknowledged_by: STRING,
  resolved: BOOLEAN,
  resolution_time: TIMESTAMP,
  correlation_id: UUID
}
```

**NetworkTraffic**
```gql
CREATE LABEL NetworkTraffic {
  id: STRING PRIMARY KEY,
  source_ip: IpAddr,
  dest_ip: IpAddr,
  source_port: INTEGER,
  dest_port: INTEGER,
  protocol: STRING,
  bytes_sent: BIGINT,
  bytes_received: BIGINT,
  packets_sent: BIGINT,
  packets_received: BIGINT,
  start_time: TIMESTAMP,
  end_time: TIMESTAMP,
  flags: BIT(8)
}
```

#### Edge Types

- `HAS_SENSOR`: Device -> Sensor (device owns sensor)
- `COLLECTED`: Sensor -> Metric (data collection)
- `GENERATED`: Device -> Alert (alert generation)
- `CONNECTED_TO`: Device -> Device (network topology)
- `COMMUNICATES`: Device -> NetworkTraffic -> Device (traffic flow)
- `TRIGGERED_BY`: Alert -> Metric (alert causation)

### Data Characteristics

- **Device Distribution**: Hierarchical network topology (gateways -> devices -> sensors)
- **Metric Generation**: Time-series data with seasonal patterns
- **Alert Frequency**: Poisson distribution with occasional bursts
- **Network Traffic**: Power-law distribution (few heavy communicators)
- **Geographic Clustering**: Devices clustered by facility/region

## Financial Network Dataset

### Schema

#### Labels (Node Types)

**Bank**
```gql
CREATE LABEL Bank {
  id: STRING PRIMARY KEY,
  name: STRING NOT NULL,
  swift_code: STRING UNIQUE,
  country: STRING,
  aml_compliance_score: INTEGER,
  total_assets: BIGINT,
  created_at: TIMESTAMP
}
```

**Account**
```gql
CREATE LABEL Account {
  id: STRING PRIMARY KEY,
  account_number: STRING UNIQUE,
  account_type: ENUM('checking', 'savings', 'business'),
  balance: DECIMAL,
  currency: Currency,
  risk_score: INTEGER,
  is_flagged: BOOLEAN,
  kyc_verified: BOOLEAN,
  opened_date: DATE,
  last_activity: TIMESTAMP,
  daily_limit: DECIMAL,
  monthly_volume: DECIMAL,
  country_code: STRING,
  ip_address: IpAddr,
  device_fingerprint: Hash
}
```

**Transaction**
```gql
CREATE LABEL Transaction {
  id: STRING PRIMARY KEY,
  amount: DECIMAL NOT NULL,
  currency: Currency,
  timestamp: TIMESTAMP,
  type: ENUM('purchase', 'transfer', 'withdrawal', 'deposit'),
  status: ENUM('pending', 'completed', 'failed', 'pending_review'),
  risk_score: INTEGER,
  is_flagged: BOOLEAN,
  processing_time_ms: INTEGER,
  fee: DECIMAL,
  reference: STRING,
  channel: ENUM('online', 'mobile', 'atm', 'pos'),
  geolocation: LatLon,
  ip_address: IpAddr,
  device_id: STRING,
  session_id: UUID,
  merchant_descriptor: STRING,
  authorization_code: STRING,
  card_last_four: STRING,
  is_international: BOOLEAN
}
```

**Merchant**
```gql
CREATE LABEL Merchant {
  id: STRING PRIMARY KEY,
  name: STRING NOT NULL,
  category: STRING,
  mcc_code: STRING,
  risk_score: INTEGER,
  monthly_volume: DECIMAL,
  avg_transaction: DECIMAL,
  chargeback_rate: FLOAT,
  location: LatLon,
  website_url: Url,
  compliance_status: ENUM('approved', 'pending_review', 'suspended'),
  established_date: DATE
}
```

**FraudPattern**
```gql
CREATE LABEL FraudPattern {
  id: STRING PRIMARY KEY,
  pattern_type: ENUM('velocity_attack', 'smurfing', 'unusual_amount', 'geo_anomaly'),
  confidence_score: INTEGER,
  detected_at: TIMESTAMP,
  severity: ENUM('low', 'medium', 'high', 'critical'),
  description: STRING,
  recommended_action: ENUM('monitor', 'review_required', 'block_account', 'notify_authorities')
}
```

#### Edge Types

- `HELD_AT`: Account -> Bank (account ownership)
- `SENT`: Account -> Transaction (sender)
- `RECEIVED_BY`: Transaction -> Account (receiver)
- `PROCESSED_BY`: Transaction -> Merchant (merchant processing)
- `DETECTED_IN`: FraudPattern -> Transaction (fraud detection)
- `LINKED_TO`: Account -> Account (related accounts)

### Data Characteristics

- **Transaction Patterns**: 
  - Normal: Small amounts, regular intervals
  - Suspicious: Velocity attacks, structuring, unusual amounts
- **Account Risk Distribution**: 
  - 95% low risk (score < 30)
  - 4% medium risk (score 30-70)
  - 1% high risk (score > 70)
- **Fraud Patterns**: 0.1-0.5% of transactions flagged
- **Geographic Distribution**: Transactions clustered by time zones

## Geographic Dataset

### Schema

#### Labels (Node Types)

**City**
```gql
CREATE LABEL City {
  id: STRING PRIMARY KEY,
  name: STRING NOT NULL,
  center: LatLon,
  boundary: Geometry,  // Polygon
  population: INTEGER,
  elevation: INTEGER,
  timezone: STRING,
  country: STRING,
  state: STRING,
  area_sq_km: FLOAT,
  density_per_sq_km: INTEGER,
  avg_temperature: Temperature,
  established: DATE
}
```

**Region**
```gql
CREATE LABEL Region {
  id: STRING PRIMARY KEY,
  name: STRING NOT NULL,
  type: ENUM('residential', 'commercial', 'industrial', 'downtown', 'suburban'),
  center: LatLon,
  area: Geometry,  // Polygon
  population: INTEGER,
  median_income: INTEGER,
  crime_rate: FLOAT,
  walkability_score: INTEGER,
  avg_property_value: INTEGER,
  zoning_code: STRING
}
```

**Road**
```gql
CREATE LABEL Road {
  id: STRING PRIMARY KEY,
  name: STRING,
  road_type: ENUM('highway', 'arterial', 'collector', 'local', 'service'),
  start_point: LatLon,
  end_point: LatLon,
  geometry: Geometry,  // LineString
  length_km: FLOAT,
  speed_limit_mph: INTEGER,
  lanes: INTEGER,
  surface: ENUM('asphalt', 'concrete', 'gravel'),
  condition: ENUM('good', 'fair', 'poor'),
  toll: BOOLEAN,
  traffic_volume_daily: INTEGER,
  last_maintenance: DATE
}
```

**PointOfInterest**
```gql
CREATE LABEL PointOfInterest {
  id: STRING PRIMARY KEY,
  name: STRING NOT NULL,
  category: STRING,
  location: LatLon,
  address: STRING,
  phone: STRING,
  website: Url,
  rating: FLOAT,
  review_count: INTEGER,
  price_level: INTEGER,
  hours_open: TIME,
  hours_close: TIME,
  is_24h: BOOLEAN,
  accepts_cards: BOOLEAN,
  wheelchair_accessible: BOOLEAN,
  parking_available: BOOLEAN,
  wifi_available: BOOLEAN,
  delivery: BOOLEAN,
  takeout: BOOLEAN,
  images: Array[STRING],
  tags: Array[STRING],
  established: DATE,
  last_updated: TIMESTAMP
}
```

**Building**
```gql
CREATE LABEL Building {
  id: STRING PRIMARY KEY,
  address: STRING,
  type: ENUM('residential', 'commercial', 'office', 'retail', 'mixed_use'),
  center: LatLon,
  footprint: Geometry,  // Polygon
  height_m: INTEGER,
  floors: INTEGER,
  year_built: INTEGER,
  units: INTEGER,
  occupancy_rate: FLOAT,
  energy_rating: STRING,
  value_usd: INTEGER,
  property_tax_annual: INTEGER,
  last_renovation: INTEGER
}
```

**TransitStop**
```gql
CREATE LABEL TransitStop {
  id: STRING PRIMARY KEY,
  name: STRING NOT NULL,
  type: ENUM('bus', 'metro', 'tram', 'train', 'ferry'),
  location: LatLon,
  lines: Array[STRING],
  platform_count: INTEGER,
  accessibility: ENUM('full', 'limited', 'none'),
  bike_parking: BOOLEAN,
  park_and_ride: BOOLEAN,
  ticket_machine: BOOLEAN,
  shelter: BOOLEAN,
  realtime_info: BOOLEAN,
  daily_ridership: INTEGER,
  peak_frequency_min: INTEGER,
  service_hours: STRING
}
```

#### Edge Types

- `LOCATED_IN`: Region -> City (containment)
- `STARTS_IN`: Road -> City (road endpoints)
- `ENDS_IN`: Road -> City (road endpoints)
- `IN_CITY`: PointOfInterest -> City (location)
- `IN_REGION`: PointOfInterest -> Region (location)
- `CONNECTS_TO`: TransitStop -> TransitStop (transit lines)
- `SERVES`: ParkingLot -> PointOfInterest (proximity)

### Data Characteristics

- **City Distribution**: Grid pattern across coordinate space
- **POI Density**: Higher in downtown/commercial areas
- **Road Network**: Hierarchical (highways connect cities, local roads within)
- **Transit Coverage**: Hub-and-spoke pattern with transfer points
- **Building Heights**: Power-law distribution (many low, few high)

## Index Usage by Dataset

### Social Network
- **Hash indexes**: username, email (unique lookups)
- **B-tree indexes**: created_at, follower_count (range queries)
- **Vector indexes**: post embeddings (similarity search)
- **Full-text indexes**: post content, user bio (text search)

### IoT Network
- **Patricia trie**: IP addresses, subnets (network queries)
- **B-tree indexes**: timestamps (time-series queries)
- **Spatial indexes**: device locations (proximity queries)
- **Hash indexes**: device_id, mac_address (exact lookups)

### Financial Network
- **Hash indexes**: account_number (exact lookups)
- **B-tree indexes**: amount, timestamp (range/time queries)
- **Composite indexes**: (account_id, timestamp) for history
- **Bitmap indexes**: flags, status fields

### Geographic Dataset
- **R-tree indexes**: all geometry fields (spatial queries)
- **Hash indexes**: city names, POI categories
- **B-tree indexes**: ratings, prices (range queries)
- **Composite indexes**: (category, location) for filtered spatial

## Performance Benchmarks

### Expected Query Performance

| Dataset | Query Type | Scale | Expected Time |
|---------|-----------|-------|---------------|
| Social | Find influencers | 10K users | < 50ms |
| Social | Content recommendation | 50K posts | < 100ms |
| IoT | Device proximity | 25K devices | < 20ms |
| IoT | Alert correlation | 10K alerts | < 30ms |
| Financial | Fraud detection | 250K transactions | < 200ms |
| Financial | AML patterns | 50K accounts | < 500ms |
| Geographic | POI search (10km) | 25K POIs | < 50ms |
| Geographic | Route planning | 10K roads | < 100ms |

### Scalability Metrics

- Linear scaling up to 100K nodes
- Sub-linear scaling 100K-1M nodes  
- Index overhead: ~20% of data size
- Memory usage: ~2GB per 1M nodes
- Write throughput: 10K+ nodes/second
- Read throughput: 100K+ queries/second