# Geode Data Types and Functions Reference

## Table of Contents

- [Core Data Types](#core-data-types)
- [Advanced Data Types](#advanced-data-types)
- [First-Class Types](#first-class-types)
- [Constructor Functions](#constructor-functions)
- [Built-in Functions](#built-in-functions)
- [Type Conversions](#type-conversions)
- [Indexes and Performance](#indexes-and-performance)

## Core Data Types

### Basic Types

#### Null

- **Storage**: 1 byte (tag only)
- **Tag**: `0x00`
- **Description**: Represents absence of value
- **SQL Semantics**: Propagates through operations

#### Boolean

- **Storage**: 1 byte + 1 byte value
- **Tag**: `0x01`
- **Values**: `true`, `false`, `NULL`
- **Constructor**: `Bool(x)`

#### Integer (i64)

- **Storage**: 1 byte tag + 8 bytes LE
- **Tag**: `0x02`
- **Range**: -9,223,372,036,854,775,808 to 9,223,372,036,854,775,807
- **Default integer type**

#### String

- **Storage**: 1 byte tag + 4 bytes length + UTF-8 bytes
- **Tag**: `0x03`
- **Encoding**: UTF-8
- **Legacy string type**

## Advanced Data Types

### Numeric Types

#### SmallInt (i16)

- **Storage**: 1 byte tag + 2 bytes LE
- **Tag**: `0x20`
- **Range**: -32,768 to 32,767
- **Constructor**: `SmallInt(value)`

#### Int (i32)

- **Storage**: 1 byte tag + 4 bytes LE
- **Tag**: `0x02` (reuses legacy Int tag)
- **Range**: -2,147,483,648 to 2,147,483,647
- **Constructor**: `Int(value)`

#### BigInt (i64)

- **Storage**: 1 byte tag + 8 bytes LE
- **Tag**: `0x21`
- **Range**: -9,223,372,036,854,775,808 to 9,223,372,036,854,775,807
- **Constructor**: `BigInt(value)`

#### Real (f32)

- **Storage**: 1 byte tag + 4 bytes LE
- **Tag**: `0x22`
- **Constraints**: Forbids NaN/Inf (returns `ERR_FLOAT_NAN`)
- **Constructor**: `Real(value)`

#### Double (f64)

- **Storage**: 1 byte tag + 8 bytes LE
- **Tag**: `0x23`
- **Constraints**: Forbids NaN/Inf (returns `ERR_FLOAT_NAN`)
- **Constructor**: `Double(value)`

#### Decimal128

- **Storage**: 1 byte tag + 16 bytes coefficient (LE) + 2 bytes scale
- **Tag**: `0x24`
- **Precision**: Up to 38 decimal digits
- **Rounding**: Half-even (banker's rounding)
- **Constructor**: `Decimal(value, scale)`
- **Functions**:
  - `decimal_add(a, b)` - Addition with scale preservation
  - `decimal_sub(a, b)` - Subtraction with scale preservation
  - `decimal_mul(a, b)` - Multiplication
  - `decimal_div(a, b)` - Division (returns `ERR_DEC_DIV_ZERO` on zero)

### String Types

#### Char(n)

- **Storage**: Tag + 2 bytes n + 4 bytes length + UTF-8 bytes
- **Tag**: `0x25`
- **Constraint**: Fixed character length n
- **Comparison**: Ignores trailing spaces (U+0020)
- **Constructor**: `Char(text, n)`
- **Error**: `ERR_CHAR_LEN` if length > n

#### Varchar(n)

- **Storage**: Tag + 2 bytes n + 4 bytes length + UTF-8 bytes
- **Tag**: `0x26`
- **Constraint**: Maximum character length n
- **Constructor**: `Varchar(text, n)`
- **Error**: `ERR_CHAR_LEN` if length > n

#### Text

- **Storage**: Tag + 4 bytes length + UTF-8 bytes
- **Tag**: `0x27`
- **Unlimited length UTF-8 text
- **Constructor**: `Text(text)`

### Temporal Types

#### Date

- **Storage**: Tag + 4 bytes days since epoch (LE)
- **Tag**: `0x28`
- **Epoch**: 1970-01-01
- **Format**: ISO-8601 "YYYY-MM-DD"
- **Constructor**: `Date("YYYY-MM-DD")`

#### Time

- **Storage**: Tag + 8 bytes microseconds since midnight (LE)
- **Tag**: `0x29`
- **Precision**: Microseconds
- **Format**: "HH:MM:SS[.us]"
- **Constructor**: `Time("HH:MM[:SS[.us]]")`; a string with a zone
  (`Z`, `+HH:MM`, `-HH:MM`) gives a TimeTZ that keeps its offset; trailing
  text is a TimeParse error (SONNY-2808)

#### TimeTZ

- **Storage**: Tag + 8 bytes micros + 4 bytes offset seconds (LE)
- **Tag**: `0x2A`
- **Offset Range**: ±18:00
- **Constructor**: `TimeTZ("HH:MM:SS[.us]", offset)`

#### Timestamp

- **Storage**: Tag + 8 bytes microseconds since epoch (LE)
- **Tag**: `0x2B`
- **Epoch**: 1970-01-01 00:00:00
- **Constructor**: `Timestamp("YYYY-MM-DD HH:MM:SS[.us]")`

#### TimestampTZ

- **Storage**: Tag + 8 bytes UTC microseconds (LE)
- **Tag**: `0x2C`
- **Storage**: Always UTC internally
- **Format**: ISO-8601 with timezone
- **Constructor**: `TimestampTZ("YYYY-MM-DDTHH:MM:SS[.us](Z|±HH:MM)")`; the
  zone designator ends the string. `datetime(str)` takes the same string
  (its offset gives the instant), or one without a zone (read as UTC), or a
  date (midnight UTC) (SONNY-2808)

#### Interval

- **Storage**: Tag + 4 bytes months + 4 bytes days + 8 bytes microseconds
- **Tag**: `0x2D`
- **Components**: months, days, microseconds
- **Format**: ISO-8601 duration "P1Y2M3DT4H5M6S"; every component
  optional, a component may be negative (`P-1D`), seconds may carry a
  fraction (`PT1.5S`, microsecond precision) (SONNY-2808)
- **Constructor**: `Interval("P...")` or `MakeInterval(months, days, micros)`

### Binary and JSON Types

#### Bytea

- **Storage**: Tag + 4 bytes length + raw bytes
- **Tag**: `0x2E`
- **I/O Format**: `\xDEADBEEF` (hex)
- **Constructor**: `Bytea(hex_string)`
- **Functions**:
  - `to_hex(bytea)` - Convert to hex string
  - `from_hex(str)` - Parse hex string

#### Json

- **Storage**: Tag + 4 bytes length + UTF-8 JSON text
- **Tag**: `0x2F`
- **Validation**: Must be valid JSON
- **Constructor**: `Json(text)`

#### Jsonb

- **Storage**: Tag + 4 bytes length + canonical binary format
- **Tag**: `0x30`
- **Features**: Keys sorted, duplicates removed, canonical form
- **Constructor**: `Jsonb(text)`
- **Functions**:
  - `jsonb_get(obj, path)` - Extract value by path
  - `jsonb_exists(obj, key)` - Check key existence
  - `jsonb_typeof()` - Get JSON type
  - `jsonb_set(obj, path, value)` - Update value

#### XML

- **Storage**: Tag + 4 bytes length + UTF-8 XML
- **Tag**: `0x31`
- **Validation**: Well-formedness check (no DTD)
- **Constructor**: `Xml(text)`
- **Functions**:
  - `xml_is_well_formed(text)` - Validate XML

## First-Class Types

### Network Types

#### IpAddr

- **Storage**: Two variants with different tags
  - IPv4: Tag `0x04` + 4 bytes (big-endian)
  - IPv6: Tag `0x05` + 16 bytes (big-endian)
- **Canonicalization**: RFC 5952 for IPv6
- **Constructor**: `IpAddr(text)`
- **Functions**:
  - `ip_family(ip)` - Returns 4 or 6
  - `ip_is_private(ip)` - Check RFC private ranges

#### Subnet (CIDR)

- **Storage**:
  - IPv4: Tag `0x06` + 4 bytes BE + 1 byte prefix
  - IPv6: Tag `0x07` + 16 bytes BE + 1 byte prefix
- **Host Bits**: Always zeroed
- **Constructor**: `Subnet(text)`
- **Functions**:
  - `ip_contains(subnet, ip|subnet)` - Containment check
  - `ip_overlaps(subnet, subnet)` - Overlap check

#### Mac (EUI-48)

- **Storage**: Tag `0x08` + 6 bytes
- **Tag**: `0x08`
- **Format**: Accepts `:` or `-`, outputs uppercase `:`
- **Constructor**: `Mac(text)`
- **Functions**:
  - `mac_is_local(mac)` - Check local bit
  - `mac_is_multicast(mac)` - Check multicast bit
  - `oui(mac)` - Extract OUI (first 24 bits)

### Cryptographic Types

#### Hash

- **Storage**: Tag `0x09` + 1 byte algorithm + digest bytes
- **Algorithms**:
  - SHA3-256 (32 bytes)
  - SHA3-512 (64 bytes)
  - BLAKE3 (32 bytes, optional)
- **Format**: "ALG:hex"
- **Constructor**: `Hash(algorithm, hex_digest)`
- **Functions**:
  - `hash_equals(a, b)` - Constant-time comparison
  - `hash_alg(h)` - Get algorithm name

### Locale and Currency Types

#### Currency (ISO-4217)

- **Storage**: Tag `0x0A` + 3 ASCII uppercase bytes
- **Tag**: `0x0A`
- **Validation**: 3-letter uppercase code
- **Constructor**: `Currency(code)`
- **Functions**:
  - `minor_units(cur)` - Get decimal places (e.g., USD=2, JPY=0, BHD=3)

#### LanguageTag (BCP-47)

- **Storage**: Tag `0x0B` + 4 bytes length + UTF-8 canonical tag
- **Tag**: `0x0B`
- **Canonicalization**: lang-Script-REGION format
- **Aliases**: `iw→he`, `mo→ro`
- **Constructor**: `LanguageTag(text)`
- **Functions**:
  - `lang_canonicalize(text)` - Normalize tag
  - `lang_match(ranges_list, tag)` - Basic filtering

### Geographic Types

#### LatLon

- **Storage**: Tag `0x12` + 8 bytes lat (LE) + 8 bytes lon (LE)
- **Tag**: `0x12`
- **Units**: Decimal degrees (WGS84)
- **Range**: Latitude [-90,90], Longitude [-180,180]
- **Constructor**: `LatLon(text)` - Parse from "lat,lon" string
- **String Formats**:
  - `"40.7128,-74.0060"` (decimal degrees)
  - `"(40.7128, -74.0060)"` (parenthesized)
- **Functions**:
  - `distanceKm(p1, p2)` - Haversine distance in kilometers
  - `bearingTo(p1, p2)` - Initial bearing in degrees [0,360)
  - `isValid(p)` - Coordinate validation
- **Index Support**: R-tree spatial index for bounding box and radius queries

#### LatLonAlt

- **Storage**: Tag `0x13` + lat + lon + alt (8 bytes each LE)
- **Tag**: `0x13`
- **Units**: Decimal degrees + meters altitude
- **Constructor**: `LatLonAlt(text)` - Parse from "lat,lon,alt" string
- **String Formats**:
  - `"40.7128,-74.0060,100.0"` (decimal with altitude)
- **Functions**:
  - `distance3D(p1, p2)` - 3D Euclidean distance in meters
  - `distanceKm(p1, p2)` - 2D Haversine distance (ignores altitude)
  - `altitude(p)` - Extract altitude in meters
- **Index Support**: R-tree spatial index (2D projection for geographic queries)

#### GeoPoint

- **Storage**: Tag `0x14` + lat + lon + optional alt (8 bytes each LE)
- **Tag**: `0x14`
- **Enhanced**: Extended geographic point with metadata support
- **Constructor**: `GeoPoint(text)` - Parse from coordinate string
- **Functions**:
  - All LatLon/LatLonAlt functions plus enhanced metadata access
  - `precision()` - Get coordinate precision
- **Index Support**: Full R-tree spatial indexing with metadata queries

#### Geometry

- **Storage**: Tag `0x0E` + 4 bytes length + WKB bytes
- **Tag**: `0x0E`
- **Format**: Well-Known Binary (WKB)
- **Output**: GeoJSON
- **Constructor**: `GeometryFromText(wkt)` - parses WKT (POINT, LINESTRING,
  POLYGON single exterior ring, MULTIPOINT, MULTILINESTRING/MULTIPOLYGON first
  member) into real WKB; unparseable WKT is a stable error (GAP-0877, see
  `tests/test_gap0877_advanced_types.zig`)
- **Functions**:
  - `st_asText(geom)` - Convert to WKT
  - `st_asGeoJSON(geom)` - Convert to GeoJSON
  - `st_contains(a, b)` - Containment test (Polygon⊇Point, Point=Point)
  - `st_intersects(a, b)` - Intersection test (Point/Point, Point/Polygon,
    LineString/LineString, Polygon/Polygon incl. edge crossings)
  - `st_within(a, b)` - Within test (inverse of `st_contains(b, a)`)
- **Unsupported relation combinations** return the stable
  `error.UnsupportedGeometryRelation` - never a silent `false` (GAP-0877)

### Physical Quantities

#### Temperature

- **Storage**: Tag `0x0F` + 8 bytes value_K (LE) + 1 byte unit_in
- **Tag**: `0x0F`
- **Canonical**: Kelvin internally
- **Units**: K (0), C (1), F (2)
- **Constructor**: `Temperature(value, unit)`

#### Pressure

- **Storage**: Tag `0x10` + 8 bytes value_Pa (LE) + 1 byte unit_in
- **Tag**: `0x10`
- **Canonical**: Pascals internally
- **Units**: Pa (0), kPa (1), bar (2), atm (3)
- **Constructor**: `Pressure(value, unit)`

### Vector and ML Types

#### VectorF32

- **Storage**: Tag `0x10` + 2 bytes dimension + packed f32 array (LE)
- **Tag**: `0x10`
- **Precision**: Single-precision floating-point (32-bit)
- **Max Dimension**: 65,535 elements
- **Constructor**: `VectorF32(text)` - Parse from vector string
- **String Formats**:
  - `"[1.0, 2.0, 3.0]"` (bracketed)
  - `"1.0,2.0,3.0"` (comma-separated)
- **Functions** (the implemented set — see [API_REFERENCE.md](API_REFERENCE.md#vector-operations)):
  - `distance(a, b [, metric])` - Distance, default L2; metric ∈ `l2`/`euclidean`, `cosine`, `dot`
  - `euclidean(a, b)` / `vector_l2(a, b)` - Euclidean (L2) distance
  - `manhattan(a, b)` - L1 (Manhattan) distance
  - `similarity(a, b [, metric])` / `cosine(a, b)` / `vector_cosine(a, b)` - Cosine similarity [-1,1]
  - `vector_dot(a, b)` - Dot product
  - `vector_knn(property_name, query_vector, k, metric)` / `knn(...)` - K nearest ids
- **Index Support**: HNSW (Hierarchical Navigable Small World) for approximate nearest neighbor search
- **SIMD**: Optimized operations where available

#### VectorI32

- **Storage**: Tag `0x11` + 2 bytes dimension + packed i32 array (LE)
- **Tag**: `0x11`
- **Precision**: 32-bit signed integers
- **Max Dimension**: 65,535 elements
- **Constructor**: `VectorI32(text)` - Parse from vector string
- **String Formats**:
  - `"[1, 2, 3]"` (bracketed integers)
  - `"1,2,3"` (comma-separated)
- **Functions**: the same set as `VectorF32` above — a `VectorI32` argument is
  converted to f32 before the distance/similarity is computed.
- **Index Support**: HNSW with automatic f32 conversion for indexing
- **Use Cases**: Discrete features, categorical embeddings, sparse vectors

### Advanced Types

#### URL/URI

- **Storage**: Tag `0x32` + structured components
- **Tag**: `0x32`
- **Canonicalization**: WHATWG URL Standard
- **IDNA**: Automatic conversion
- **Constructor**: `Url(text)`
- **Functions**:
  - `url_host(url)` - Extract host
  - `url_scheme(url)` - Extract scheme
  - `url_path(url)` - Extract path
  - `url_query(url)` - Extract query
  - `url_origin(url)` - Get origin

#### Domain/FQDN

- **Storage**: Tag `0x33` + label count + concatenated labels
- **Tag**: `0x33`
- **Format**: Lowercase ASCII, punycode for IDN
- **Limits**: Labels ≤63, total ≤253
- **Constructor**: `Domain(text)`
- **Functions**:
  - `domain_root(domain)` - Registrable domain (eTLD+1) evaluated against a
    bundled trimmed Public Suffix List snapshot
    (`src/types/data/public_suffix_list.dat`): exact, wildcard (`*.ck`) and
    exception (`!www.ck`) rules; unknown TLDs fall back to the last two
    labels; a bare public suffix returns NULL (GAP-0877, verified by
    `tests/test_gap0877_advanced_types.zig` / `zig build test-gap0877`)
  - `domain_labels(domain)` - Get label array

#### UUID

- **Storage**: Tag `0x34` + 16 bytes (big-endian)
- **Tag**: `0x34`
- **Format**: Canonical 8-4-4-4-12
- **Constructor**: `UUID(text)`
- **Functions**:
  - `uuid_v4()` - Generate version 4
  - `uuid_v7()` - Generate version 7
  - `uuid_equal(a, b)` - Bytewise comparison

#### Enum

- **Storage**: Tag `0x35` + 4 bytes type_id + 4 bytes ordinal
- **Tag**: `0x35`
- **Catalog**: Schema-backed type registry
- **Ordering**: By ordinal value
- **Constructor**: `Enum(type_name, value)`
- **Functions**:
  - `enum_values(type_name)` - List all values

#### Array

- **Storage**: Tag `0x36` + 2 bytes elem_type + 4 bytes count + elements
- **Tag**: `0x36`
- **Constraint**: Homogeneous element type
- **NULL Handling**: NULL for entire array, not elements
- **Constructor**: `Array(elem_list)`
- **Functions**:
  - `array_length(a)` - Get length
  - `array_contains(a, x)` - Check membership
  - `array_get(a, i)` - Get element by index

#### BitString

- **Storage**: Tag `0x37`/`0x38` + 4 bytes bit_len + packed bytes
- **Tags**: `0x37` (bit), `0x38` (varbit)
- **Format**: B'10101' notation
- **Bit Order**: MSB first per byte
- **Constructors**: `Bit(bits)`, `VarBit(bits)`
- **Functions**:
  - `bit_and(a, b)` - Bitwise AND
  - `bit_or(a, b)` - Bitwise OR
  - `bit_xor(a, b)` - Bitwise XOR
  - `bit_count(bits)` - Count set bits
  - `bit_get(bits, i)` - Get bit at position
  - `bit_set(bits, i, val)` - Set bit value

#### Range

- **Storage**: Tag `0x39` + base_type + bounds + lower/upper values
- **Tag**: `0x39`
- **Bounds**: `[)`, `[]`, `()`, `(]`
- **Constructor**: `Range(base_type, lower, upper, bounds)`
- **Functions**:
  - `range_contains(r, x)` - Point containment
  - `range_overlaps(r1, r2)` - Range overlap
  - `lower(r)` - Get lower bound
  - `upper(r)` - Get upper bound
  - `bounds(r)` - Get bounds type

## Temporal Functions

### Current Time

- `now()` - Current timestamp with microseconds
- `current_date` - Today's date
- `current_time` - Current time

### Date/Time Arithmetic

Operators (ISO/IEC 39075:2024 20.26 and 20.28; SONNY-2797):

- `instant + duration`, `duration + instant`, `instant - duration` for a
  date, time, zoned time, local or zoned datetime: the months as calendar
  months, the day clamped to the target month (`2024-01-31 + P1M` is
  `2024-02-29`), then the day-to-second part; a date takes its whole days,
  a time of day wraps at 24 hours.
- `duration + duration`, `duration - duration`: part by part, the
  day-to-second part normalized (`PT20H + PT20H` is `P1DT16H`).
- `duration * number`, `number * duration`, `duration / number`: a result
  with a fraction of a month is refused (22023: a month has no fixed length);
  a fraction of a microsecond is truncated; `/ 0` is 22012.
- `instant - instant` (one type): the day-to-second duration between them
  (Geode extension for `DURATION_BETWEEN`); two types are 22G04.
- A result out of range is 22003.

Functions:

- `date_add(date, interval)` - Add interval to date
- `date_sub(date, interval)` - Subtract interval
- `ts_add(timestamp, interval)` - Add to timestamp
- `ts_sub(timestamp, interval)` - Subtract from timestamp
- `age(ts1, ts2)` - Calculate interval between timestamps

### Extraction

- `date_part(part, date|timestamp)` - Extract year/month/day/hour/etc.
- `time_part(part, time)` - Extract hour/minute/second
- Member access `v.year`, `.month`, `.day`, `.hour`, `.minute`, `.second`,
  `.millisecond`, `.microsecond` on a date, time, zoned time, local or zoned
  datetime: the fields of the value's ISO 8601 representation, the time of
  day taken modulo 24 hours (so a datetime before 1970 has hours 0-23); a
  zoned datetime is held as its UTC instant, so its fields are UTC's; a
  field the value lacks (`date(...).hour`) is NULL (SONNY-2796).

## List Functions

### `range(start, end[, step])`

A Geode extension (ISO/IEC 39075:2024 has no `range` function): the list of
integers from `start` up to, **not including**, `end`, stepping by `step`
(default 1). The end is exclusive, as in Python's `range`; openCypher's
`range()` includes its end, so a query ported from Cypher must move the end
by one step.

| Call | Result |
|---|---|
| `range(1, 4)` | `[1, 2, 3]` |
| `range(1, 7, 2)` | `[1, 3, 5]` |
| `range(5, 1, -2)` | `[5, 3]` |
| `range(3, 3)` | `[]` |
| `range(1, 4, 0)` | `NULL` (a zero step) |

A non-integer argument returns `NULL`; more than 10,000,000 elements is
refused (`RangeTooLarge`). `FOR i IN range(1, 1500)` runs 1,499 times.

## Distance and Spatial Functions

### Haversine Distance

```gql
distance_haversine(point1, point2)
```

- **Earth Radius**: 6,371,000 meters
- **Returns**: Distance in meters (rounded)
- **Example**: `distance_haversine(LatLon(0,0), LatLon(0,1))` → 111,195 m

## Indexes and Performance

### Patricia Trie (CIDR Index)

- **Purpose**: IP prefix matching and LPM (Longest Prefix Match)
- **File Format**: `.pfx` snapshot + `.pfx.wal` WAL
- **Operations**: O(prefix_bits) lookup
- **Persistence**: Atomic checkpoint with rename
- **Query Optimization**: Automatic for `ip_contains(subnet_col, const_ip)`

### R-tree (Spatial Index)

- **Purpose**: 2D spatial queries for geographic types
- **Supported Types**: LatLon, LatLonAlt, GeoPoint
- **Node Capacity**: M=8 entries (configurable)
- **File Format**: `.rtree` snapshot + `.rtree.wal` WAL
- **Query Types**:
  - Bounding box search: `searchBoundingBox(min_lat, min_lon, max_lat, max_lon)`
  - Radius search: `searchRadius(center_lat, center_lon, radius_meters)`
  - K-nearest neighbors: `searchKNearest(center_lat, center_lon, k)`
- **Distance Calculation**: Haversine formula for accurate geographic distances
- **Optimization**: Approximate distance filtering with exact refinement
- **Index Management**: `SpatialIndexManager` for multiple named indexes
- **Performance**: Automatic hierarchical search for large datasets (>50k points)

### HNSW (Vector Index)

- **Purpose**: Approximate k-nearest neighbor search for high-dimensional vectors
- **Supported Types**: VectorF32, VectorI32 (auto-converted to f32)
- **Parameters**:
  - M=16 (max connections per node)
  - ef_construction=200 (search width during construction)
  - Configurable ef_search for query-time accuracy/speed tradeoff
- **File Format**: `.hnsw` graph + `.vec` vectors
- **Distance Metrics**: L2 (Euclidean), Cosine similarity, Dot product
- **Optimization Features**:
  - SIMD vectorized distance calculations (4x f32 vectors)
  - Dynamic ef_search selection based on result count
  - Vector quantization for memory efficiency (4-8 bit)
  - Approximate search for large datasets (>10k vectors)
- **Index Management**: `VectorIndexManager` for multiple named indexes
- **Performance**: O(log N) search complexity with >90% recall
- **Fallback**: Exact brute-force search for small datasets or when index unavailable

### Interval Tree (Range Index)

- **Purpose**: Range overlap queries
- **Structure**: Augmented BST
- **File Format**: `.gdir` snapshot + WAL
- **Operations**: Contains, overlaps

### JSONB Inverted Index

- **Purpose**: JSON path queries
- **Structure**: (doc_id, path_hash) → posting list
- **File Format**: `.gdjb` snapshot + WAL
- **Query Types**: Path existence, value lookup

### Domain Trie

- **Purpose**: Domain suffix matching
- **Structure**: Reverse-label trie
- **File Format**: `.gddn` snapshot + WAL
- **Operations**: Suffix search, label extraction

## Error Codes

### Numeric Errors

- `ERR_FLOAT_NAN` - NaN or Inf not allowed
- `ERR_DEC_OVERFLOW` - Decimal overflow
- `ERR_DEC_DIV_ZERO` - Division by zero

### String Errors

- `ERR_CHAR_LEN` - Character limit exceeded
- `ERR_HEX` - Invalid hex format

### Format Errors

- `ERR_TIME_PARSE` - Invalid temporal format
- `ERR_JSON_INVALID` - Malformed JSON
- `ERR_XML_WELLFORMED` - XML not well-formed
- `ERR_URL_PARSE` - Invalid URL syntax
- `ERR_DOMAIN_SYNTAX` - Invalid domain name
- `ERR_IDNA` - IDNA conversion failed
- `ERR_UUID_PARSE` - Invalid UUID format

### Type Errors

- `ERR_ENUM_TYPE` - Unknown enum type
- `ERR_ENUM_VALUE` - Unknown enum value
- `ERR_ARRAY_ELEM_TYPE` - Mixed array types
- `ERR_INDEX` - Array index out of bounds
- `ERR_BIT_PARSE` - Invalid bit string
- `ERR_RANGE_BOUNDS` - Invalid range bounds

### Index Errors

- `ERR_INDEX_VERSION` - Unknown index format version
- `ERR_TAG_UNKNOWN` - Unknown storage tag

## Type Conversion Rules

### Implicit Conversions

- SmallInt → Int → BigInt
- Real → Double
- Int → Decimal (scale 0)
- Char → Varchar → Text

### String Rendering (`stringify` / string comparison contexts)

- Date/Time/TimeTZ/Timestamp/TimestampTZ/Interval render canonical ISO-8601
  (`2026-06-10`, `13:45:30[.ffffff]`, `13:45:30+02:00`,
  `2026-06-10T13:45:30`, `...Z`, `P1Y2M3DT4H5M6S`); Url/Domain render their
  actual value; Bytea renders `\x`-prefixed hex (GAP-0877,
  `tests/test_gap0877_advanced_types.zig`).
- Values that do not fit the fixed 64-byte stringify buffer return a stable
  `Unsupported` error - never a truncated or placeholder string.
- **Still placeholder** (not canonical values): Enum stringifies as `"enum"`,
  BitString as `"bitstring"`, VarBit as `"varbit"`, IntRange as `"range"`.
  Use the dedicated functions (`enum_values`, `to_hex`, range accessors) for
  real values.

### NULL Propagation

- Any operation with NULL input returns NULL
- Exceptions: `IS NULL`, `IS NOT NULL`, `COALESCE`

### Comparison Ordering

1. Type precedence (by tag value)
2. Within type: natural ordering
3. Special cases:
   - Char ignores trailing spaces
   - Enum compares by ordinal
   - UUID compares bytewise
   - Numbers (INT, SMALLINT, BIGINT, DECIMAL, REAL, DOUBLE) compare by their
     exact numerical value, whatever their types (ISO/IEC 39075:2024 19.3,
     General Rule 3a). `=`, the order operators, IN, GROUP BY, DISTINCT,
     ORDER BY, joins, inline property maps, MERGE and index seeks share this
     one rule: `1 = 1.0 = DOUBLE 1.0`, `DOUBLE 0.5 = 0.5`, but the DOUBLE
     nearest 0.1 (0.1000000000000000055...) is not the DECIMAL 0.1 and is
     greater than it. NaN equals nothing under `=` (IEEE 754) and is one
     value for GROUP BY and DISTINCT, sorting after every number
     (SONNY-2807).
   - Strings (STRING, TEXT, VARCHAR, CHAR values) compare by the UTF-8 bytes
     of their Unicode Normalization Form C (UAX #15, Unicode 15.1): a
     precomposed `'é'` equals `'e'` + U+0301, U+212B ANGSTROM SIGN equals
     `'Å'`. `=`, the order operators, IN, GROUP BY, DISTINCT, ORDER BY,
     joins, inline property maps, MERGE, UNIQUE and the index seeks share
     this one rule; values are stored as written (SONNY-3055).

## Performance Characteristics

### Storage Efficiency

- Compact binary encodings
- Canonical forms reduce duplication
- Compression-friendly layouts

### Query Performance

- SIMD vector operations: 2x+ speedup
- Patricia trie: O(32) for IPv4, O(128) for IPv6
- HNSW: O(log N) approximate KNN
- R-tree: Sub-linear spatial queries

### Index Persistence

- Atomic checkpoints
- WAL for durability
- Fast recovery via replay
