# Type System & Indexing Extensions for Geode

## Overview

This document describes the new first-class types and persisted indexes added to Geode v0.16.0, including constructors, built-in functions, binary encodings, and index persistence formats.

## New Types

### Network Types

#### IpAddr
- **Constructor**: `IpAddr(text)`
- **Storage**: IPv4 (4 bytes) or IPv6 (16 bytes), network byte order
- **JSON**: `{"IpAddr": "192.168.1.1"}` or `{"IpAddr": "2001:db8::1"}`
- **Canonicalization**: IPv6 follows RFC 5952

#### Subnet (CIDR)
- **Constructor**: `Subnet(text)`
- **Storage**: IP address + prefix length, host bits zeroed
- **JSON**: `{"Subnet": "192.168.0.0/16"}`

#### Mac
- **Constructor**: `Mac(text)`
- **Storage**: 6 bytes (EUI-48)
- **JSON**: `{"Mac": "AA:BB:CC:DD:EE:FF"}`
- **Format**: Uppercase with colons

### Security Types

#### Hash
- **Constructor**: `Hash(algorithm, hex_string)`
- **Algorithms**: 
  - SHA3-256 (32 bytes output)
  - SHA3-512 (64 bytes output)
  - BLAKE3 (32 bytes output)
  - BLAKE2b-256 (32 bytes output)
  - BLAKE2b-512 (64 bytes output)
  - BLAKE2s-256 (32 bytes output)
  - Argon2id (32 bytes output, password hashing)
- **Storage**: Algorithm code + digest bytes + optional salt/params for Argon2id
- **JSON**: `{"Hash": "SHA3-256:3a985da74fe..."}`
- **Password Hashing**: `Argon2idHash(password, salt, iterations, memory_kb, parallelism)`

### Financial Types

#### Currency
- **Constructor**: `Currency(code)`
- **Storage**: 3 uppercase ASCII bytes (ISO 4217)
- **JSON**: `{"Currency": "USD"}`

### Internationalization Types

#### LanguageTag
- **Constructor**: `LanguageTag(text)`
- **Storage**: Canonical BCP-47 tag
- **JSON**: `{"LanguageTag": "en-US"}`
- **Canonicalization**: Language lowercase, Script Title, region UPPER
- **Aliases**: `iw→he`, `mo→ro`

### Geographic Types

#### LatLon
- **Constructor**: `LatLon(lat, lon)`
- **Storage**: Two f64 values (little-endian)
- **JSON**: `{"LatLon": {"lat": 51.5, "lon": -0.1}}`

#### LatLonAlt
- **Constructor**: `LatLonAlt(lat, lon, alt, ref)`
- **Storage**: Three f64 values + reference enum
- **Reference**: "ellipsoid" or "geoid"

#### Geometry
- **Constructor**: `GeometryFromText(wkt)`
- **Storage**: WKB (Well-Known Binary)
- **JSON**: GeoJSON format
- **Example**: `{"type": "Point", "coordinates": [30, 10]}`

### Scientific Types

#### Temperature
- **Constructor**: `Temperature(value, unit)`
- **Units**: K, C, F
- **Storage**: Canonical Kelvin + original unit
- **JSON**: `{"Temperature": {"value": 300, "unit": "K"}}`

#### Pressure
- **Constructor**: `Pressure(value, unit)`
- **Units**: Pa, kPa/hPa, bar, atm
- **Storage**: Canonical Pascals + original unit

### Vector Types

#### VectorF32
- **Constructor**: `Vector(list_of_numbers)`
- **Storage**: Dimension (u16) + packed f32 array
- **JSON**: `{"VectorF32": [1.0, 2.0, 3.0]}`
- **SIMD**: Optimized operations when dimension % 4 == 0

## Built-in Functions

### IP/CIDR Functions
- `ip_contains(subnet, ip|subnet) → bool`
- `ip_overlaps(subnet, subnet) → bool`
- `ip_family(ip|subnet) → "IPv4"|"IPv6"`
- `ip_is_private(ip) → bool`

### MAC Functions
- `mac_is_local(mac) → bool` - Check local bit
- `mac_is_multicast(mac) → bool` - Check multicast bit
- `oui(mac) → u24` - Extract OUI

### Hash Functions
- `hash_equals(a, b) → bool` - Constant-time comparison
- `hash_alg(hash) → string` - Get algorithm name
- `HashData(algorithm, data) → Hash` - Create hash from data
- `Argon2idHash(password, salt, iterations, memory_kb, parallelism) → Hash` - Password hashing
- `Blake2bKdf(out_len, context, key) → Bytea` - Blake2b key derivation
- `Blake2sKdf(out_len, context, key) → Bytea` - Blake2s key derivation (max 32 bytes)

### Currency Functions
- `minor_units(currency) → u8` - Get decimal places (0 for JPY, 2 for USD, 3 for BHD)

### Language Functions
- `lang_canonicalize(text) → LanguageTag`
- `lang_match(ranges_list, tag) → bool` - Basic filtering

### Geographic Functions
- `distance_haversine(a, b) → meters` - Earth radius: 6,371,000m
- `latitude(point) → decimal`
- `longitude(point) → decimal`
- `altitude(point) → decimal|null`
- `alt_ref(point) → string|null`

### Geometry Functions (OGC-style)
- `st_asText(geom) → WKT`
- `st_asGeoJSON(geom) → GeoJSON`
- `st_contains(a, b) → bool`
- `st_intersects(a, b) → bool`
- `st_within(a, b) → bool`

### Vector Functions
- `vector_dot(a, b) → f64`
- `vector_l2(a, b) → f64` - Euclidean distance
- `vector_cosine(a, b) → f64|null` - NULL if zero-norm
- `vector_knn(property, query_vec, k, metric) → list`

## Persisted Indexes

### Patricia Trie (CIDR Index)

**Use Case**: IP prefix matching, CIDR containment queries

**Files**:
- `*.pfx` - Snapshot file
- `*.pfx.wal` - Write-ahead log

**Snapshot Format**:
```
Header {
    magic: "GDXP"
    version: u16
    family: u8 (4=IPv4, 6=IPv6, 255=both)
    node_count: u64
    key_count: u64
}
Nodes: array of {
    bit_index: u16
    prefix_len: u16
    child0_off: u64
    child1_off: u64
    payload_count: u32
    payloads: [u64...]
}
```

**Planner Integration**: `ip_contains(subnet_col, const_ip)` → Patricia index scan

### R-tree (2D Spatial Index)

**Use Case**: Spatial queries, bounding box searches

**Files**:
- `*.rtree` - Snapshot file
- `*.rtree.wal` - Write-ahead log

**Snapshot Format**:
```
Header {
    magic: "GDRT"
    version: u16
    M: u16 (max entries per node, default 50)
    count: u64
    height: u16
}
Nodes: level-order traversal
```

**Query Operations**: `st_intersects`, `st_contains` with filter-then-refine

### HNSW (Vector Similarity Index)

**Use Case**: Approximate k-nearest neighbor search

**Files**:
- `*.hnsw` - Graph structure
- `*.vec` - Raw vectors
- `*.hnsw.wal` - Write-ahead log

**Parameters**:
- M = 16 (connectivity)
- efConstruction = 100
- Metrics: L2, cosine, dot product

**Snapshot Format**:
```
Header {
    magic: "GDHW"
    version: u16
    M: u16
    ef: u16
    max_level: u8
    entry_point: u64
    dim: u16
}
Graph: adjacency lists per level
Vectors: dim * f32 per row
```

**Fallback**: If disabled, `vector_knn` uses SIMD full-scan

## Binary Encoding Tags

| Tag | Type | Size |
|-----|------|------|
| 0x00 | Null | 1 |
| 0x01 | Bool | 2 |
| 0x02 | Int | 9 |
| 0x03 | String | 5 + len |
| 0x04 | IPv4 | 5 |
| 0x05 | IPv6 | 17 |
| 0x06 | Subnet4 | 6 |
| 0x07 | Subnet6 | 18 |
| 0x08 | Mac | 7 |
| 0x09 | Hash | 2 + digest_len + salt_len + params |
| 0x0A | Currency | 4 |
| 0x0B | LanguageTag | 5 + len |
| 0x0C | LatLon | 17 |
| 0x0D | LatLonAlt | 26 |
| 0x0E | Geometry | 5 + wkb_len |
| 0x0F | Temperature | 10 |
| 0x10 | Pressure | 10 |
| 0x11 | VectorF32 | 3 + dim*4 |

## Error Codes

- `ERR_TAG_UNKNOWN` - Unknown type tag in decode
- `ERR_INDEX_VERSION` - Unsupported index format version
- `ERR_FLOAT_NAN` - NaN/Inf not allowed
- `InvalidIpAddress` - Malformed IP string
- `InvalidPrefix` - Prefix length out of range
- `InvalidMac` - Invalid MAC format
- `InvalidHashAlg` - Unknown hash algorithm
- `InvalidHashLength` - Wrong digest length
- `InvalidCurrency` - Not 3-letter code
- `InvalidLatitude` - Outside ±90°
- `InvalidLongitude` - Outside ±180°
- `InvalidWkt` - Malformed WKT
- `InvalidTempUnit` - Unknown temperature unit
- `InvalidPressureUnit` - Unknown pressure unit
- `DimensionMismatch` - Vector dimensions don't match

## Usage Examples

### Constructors
```gql
IpAddr("2001:db8::1")
Subnet("192.168.0.0/16")
Mac("aa-bb-cc-dd-ee-ff")
Hash("SHA3-256", "3A985D...")
Hash("BLAKE2b-256", "4B7F8E...")
Hash("BLAKE2b-512", "A1B2C3...")
Hash("BLAKE2s-256", "D4E5F6...")
Hash("Argon2id", "789ABC...")
HashData("BLAKE2b-256", "my data to hash")
HashData("BLAKE2s-256", "compact data")
Argon2idHash("password123", "saltsalt", 4, 65536, 1)
Blake2bKdf(32, "context-v1", "master-key")
Blake2sKdf(16, "auth", "secret")
Currency("USD")
LanguageTag("en-US")
LatLon(51.5074, -0.1278)
GeometryFromText("POINT(30 10)")
Temperature(37.0, "C")
Pressure(1013.25, "hPa")
Vector([1.0, 2.0, 3.0])
```

### Predicates
```gql
ip_contains(Subnet("10.0.0.0/8"), IpAddr("10.1.2.3"))
st_intersects(poly1, poly2)
vector_knn("embedding", Vector([0.9, 0.1]), 2, "cosine")
hash_equals(user.password_hash, Argon2idHash($password, user.salt, 4, 65536, 1))
hash_alg(document.signature) = "BLAKE2b-512"
```

## Performance Characteristics

- **IPv6 parsing**: ~1M ops/sec
- **Haversine distance**: Rounded to nearest meter
- **Vector SIMD**: ≥2× speedup vs scalar
- **Patricia LPM**: O(prefix_bits)
- **R-tree search**: Sub-linear with bbox filtering
- **HNSW k-NN**: O(log N) with high recall
- **BLAKE2b hashing**: ~500 MB/s throughput
- **BLAKE2s hashing**: Optimized for 32-bit platforms
- **Argon2id**: Memory-hard, configurable time/memory tradeoff
- **Hash comparison**: Constant-time to prevent timing attacks

## Index Recovery

All indexes support atomic checkpoint with write-temp+rename pattern:

1. Open snapshot file
2. Replay WAL entries
3. On checkpoint: write temp snapshot, fsync, rename
4. Truncate WAL

Unknown versions return `ERR_INDEX_VERSION` for safe forward compatibility.