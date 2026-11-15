# Geode Type System Quick Reference

> The blocks below are signature listings, not statements: an argument such
> as `geom1` stands for a value you supply, and an expression runs inside a
> statement (`RETURN upper('a')`). This page lists the names; it does not
> check that each one is implemented (see `docs/API_REFERENCE_GENERATED.md`
> for the function catalogue).

## Type Constructor Examples

```text
-- Numeric Types
SmallInt(42)                           -- i16
Int(1000000)                           -- i32
BigInt(9223372036854775807)            -- i64
Real(3.14159)                          -- f32
Double(2.718281828)                    -- f64
Decimal("123.45", 2)                   -- Decimal128 with scale

-- String Types
Char("Hello", 10)                      -- Fixed 10 chars (trailing spaces ignored in comparison)
Varchar("World", 50)                   -- Max 50 chars
Text("Unlimited text...")              -- Unlimited length

-- Temporal Types
Date("2024-09-28")                     -- ISO date
Time("14:30:00.123456")                -- Time with microseconds
TimeTZ("14:30:00", 3600)               -- Time with timezone offset (seconds)
Timestamp("2024-09-28 14:30:00")       -- Timestamp
TimestampTZ("2024-09-28 14:30:00+02:00") -- Timestamp with timezone (stored as UTC)
Interval("P1Y2M3DT4H5M6S")             -- ISO duration  (Geode extension: both unit groups)
MakeInterval(12, 30, 1000000)          -- 12 months, 30 days, 1M microseconds

-- Binary/JSON Types
Bytea("\\xDEADBEEF")                   -- Binary data as hex
Json('{"key": "value"}')               -- JSON text
Jsonb('{"key": "value"}')              -- Binary JSON (canonical)
Xml('<root><child/></root>')           -- Well-formed XML

-- Network Types
IpAddr("192.168.1.1")                  -- IPv4
IpAddr("2001:db8::1")                  -- IPv6 (RFC 5952 canonical)
Subnet("192.168.0.0/16")               -- CIDR notation
Mac("AA:BB:CC:DD:EE:FF")               -- MAC address

-- Cryptographic Types
Hash("SHA3-256", "3a985da74fe225b2...")  -- Hash with algorithm

-- Locale/Currency Types
Currency("USD")                        -- ISO-4217 code (auto-uppercase)
LanguageTag("en-US")                   -- BCP-47 (canonicalized)

-- Geographic Types
LatLon(51.5074, -0.1278)              -- London coordinates
LatLonAlt(51.5074, -0.1278, 45.0, "ellipsoid")  -- With altitude
GeometryFromText("POINT(30 10)")      -- WKT to geometry

-- Physical Quantities
Temperature(37.0, "C")                 -- 37°C (stored as Kelvin)
Pressure(1013.25, "hPa")              -- Atmospheric pressure

-- Advanced Types
Url("https://example.com/path?q=1")   -- WHATWG normalized
Domain("example.com")                  -- FQDN with punycode
UUID("550e8400-e29b-41d4-a716-446655440000")  -- UUID
Enum("Priority", "HIGH")               -- Enum type with value
Array([1, 2, 3])                       -- Homogeneous array
Bit("B'10101'")                        -- Bit string
VarBit("B'10101'")                     -- Variable bit string
Range("int4", 1, 10, "[)")            -- Half-open range [1, 10)

-- Vector/ML Types
Vector([0.1, 0.2, 0.3, 0.4])         -- Float32 vector
```

## Common Function Patterns

### Numeric Operations

```text
decimal_add(Decimal("10.50", 2), Decimal("5.25", 2))  -- 15.75
decimal_mul(a, b)                                      -- Multiplication
decimal_div(a, b)                                      -- Division (banker's rounding)
```

### String Functions

```text
length_chars(text)                     -- Character count (Unicode)
trim(text)                            -- Remove whitespace
lower(text) / upper(text)             -- Case conversion
```

### Temporal Functions

```text
now()                                  -- Current timestamp
current_date / current_time           -- Current date/time
date_add(date, interval)              -- Add interval
ts_sub(timestamp, interval)           -- Subtract interval
age(ts1, ts2)                        -- Interval between timestamps
date_part("year", timestamp)         -- Extract component
```

### Network Predicates

```text
ip_contains(Subnet("10.0.0.0/8"), IpAddr("10.1.2.3"))     -- true
ip_overlaps(subnet1, subnet2)                              -- Check overlap
ip_is_private(ip)                                          -- RFC private ranges
ip_family(ip)                                              -- Returns 4 or 6
```

### MAC Address Functions

```text
mac_is_local(mac)                     -- Check local admin bit
mac_is_multicast(mac)                 -- Check multicast bit
oui(mac)                              -- Extract OUI (vendor ID)
```

### Hash Operations

```text
hash_equals(hash1, hash2)             -- Constant-time comparison
hash_alg(hash)                        -- Get algorithm name
```

### Currency/Language Functions

```text
minor_units(Currency("USD"))         -- Returns 2 (cents)
minor_units(Currency("JPY"))         -- Returns 0 (no subunit)
lang_canonicalize("EN-us")           -- Returns "en-US"
lang_match(["fr-CA", "fr"], "fr-FR") -- Returns true
```

### Geographic Functions

```text
distance_haversine(p1, p2)           -- Distance in meters
latitude(point) / longitude(point)    -- Extract coordinates
altitude(point) / alt_ref(point)      -- Extract altitude info
```

### Geometry Functions (OGC-style)

```text
st_asText(geometry)                   -- Convert to WKT
st_asGeoJSON(geometry)               -- Convert to GeoJSON
st_contains(geom1, geom2)            -- Spatial containment
st_intersects(geom1, geom2)          -- Spatial intersection
st_within(geom1, geom2)              -- Spatial within test
```

### JSON/JSONB Functions

```text
jsonb_get(doc, "$.path.to.value")    -- Extract by path
jsonb_exists(doc, "key")             -- Check key existence
jsonb_typeof(value)                  -- Get JSON type
jsonb_set(doc, path, new_value)      -- Update value
```

### URL/Domain Functions

```text
url_host(url)                        -- Extract host
url_scheme(url)                      -- Extract scheme (http/https)
url_path(url)                        -- Extract path
url_query(url)                       -- Extract query string
url_origin(url)                      -- Get origin
domain_labels(domain)                -- Split into labels
```

### UUID Functions

```text
uuid_v4()                            -- Generate version 4 UUID
uuid_v7()                            -- Generate version 7 UUID
uuid_equal(uuid1, uuid2)             -- Bytewise comparison
```

### Array Functions

```text
array_length(arr)                    -- Get array length
array_contains(arr, value)           -- Check membership
array_get(arr, index)               -- Get element by index
```

### Bit String Functions

```text
bit_and(bits1, bits2)               -- Bitwise AND
bit_or(bits1, bits2)                -- Bitwise OR
bit_xor(bits1, bits2)               -- Bitwise XOR
bit_count(bits)                     -- Count set bits
bit_get(bits, position)             -- Get bit at position
bit_set(bits, position, value)     -- Set bit value
```

### Range Functions

```text
range_contains(range, value)        -- Check if value in range
range_overlaps(range1, range2)     -- Check range overlap
lower(range)                        -- Get lower bound
upper(range)                        -- Get upper bound
bounds(range)                       -- Get bounds type ("[)", "[]", etc.)
```

### Vector Operations (ML/AI)

```text
vector_dot(vec1, vec2)              -- Dot product
vector_l2(vec1, vec2)               -- Euclidean distance
vector_cosine(vec1, vec2)           -- Cosine similarity (NULL if zero-norm)
vector_knn(property, query_vec, 5, "cosine")  -- K-nearest neighbors
```

## Index Usage Patterns

### Automatic Index Selection

```text
-- Patricia trie automatically used for:
WHERE ip_contains(subnet_column, '192.168.1.5'::IpAddr)

-- R-tree automatically used for:
WHERE st_intersects(geom_column, query_geom)
WHERE st_contains(geom_column, point)

-- HNSW automatically used for:
SELECT vector_knn(embedding, query_vector, 10, 'cosine')

-- JSONB inverted index used for:
WHERE jsonb_exists(doc_column, 'key')
WHERE jsonb_get(doc_column, '$.path') = 'value'

-- Domain trie used for:
WHERE domain_suffix_match(domain_column, 'example.com')
```

## Common Type Conversions

### Implicit Conversions

```text
SmallInt → Int → BigInt              -- Numeric widening
Real → Double                         -- Float widening
Int → Decimal (scale 0)              -- Int to decimal
Char → Varchar → Text                -- String widening
```

### Explicit Casts

```text
CAST(value AS TypeName)              -- Standard SQL cast
value::TypeName                      -- PostgreSQL-style cast
```

`CAST` follows ISO/IEC 39075:2024 20.8 (Table 4 and General Rules g to k).
A value stored on a node converts as the value it is (a stored DOUBLE is a
DOUBLE). No combination answers a silent NULL; `CAST(NULL AS T)` is NULL.

| Source \ Target | INTEGER / INT / BIGINT | DECIMAL(p, s) / NUMERIC | FLOAT / DOUBLE / REAL | STRING / VARCHAR / TEXT | BOOLEAN | DATE / TIME / TIMESTAMP |
|---|---|---|---|---|---|---|
| INTEGER | itself | exact, 22003 past i128 | the nearest DOUBLE | digits | Geode extension: `<> 0` | 22G03 |
| DECIMAL | truncated, 22003 past i64 | rescaled (truncated) | the nearest DOUBLE | its digits at its scale | 22G03 | 22G03 |
| DOUBLE | truncated, 22003 out of range | truncated at `s`, 22003 out of range | itself | shortest literal: `1.5E0`, `1.0E-1`, `0E0` | 22G03 | 22G03 |
| STRING | trimmed numeric literal, exponent allowed, truncated; else 22018; 22003 out of range | the same | trimmed numeric literal (no `nan`, `inf`, `_`, hex), else 22018; 22003 out of range | itself | trimmed `true` / `false` (any case), Geode extension `1` / `0`; else 22018 | trimmed ISO 8601 literal, else 22007 |
| BOOLEAN | Geode extension: 1 / 0 | 22G03 | 22G03 | `TRUE` / `FALSE` | itself | 22G03 |
| DATE, TIME, TIMESTAMP, zoned, DURATION | 22G03 | 22G03 | 22G03 | its ISO 8601 literal | 22G03 | itself; DATE from TIMESTAMP, TIME from TIMESTAMP, TIMESTAMP from DATE; other pairs 22G03 (the standard also allows zoned to local: not implemented) |
| LIST, RECORD, NODE, EDGE, PATH, extension types | 22G03 | 22G03 | 22G03 | 22G03 | 22G03 | 22G03 |

22G03 (invalid value type) is the standard's exception for a value whose
type has no conversion to the target (20.8 GR 7 d ii); 22018 (invalid
character value for cast) and 22007 are for text that is not a literal of
the target (GR g ii, i ii, k i, l i).

An unknown target type name (`CAST(x AS DURATION)`, `AS ZONED DATETIME`)
is 0A000. Every type with a character form reads back from it as the same
value (`CAST(CAST(x AS STRING) AS T) = x`).

### Durations: unit groups

ISO/IEC 39075 types a duration as year-to-month (`P1Y2M`) or day-to-second
(`P3DT4H`); a duration string naming both (`P1M1D`) is 22G0H there (20.29
GR 1). Geode accepts it as an extension: a mixed duration holds both parts,
renders as `P1M1D` and reads back as itself. Adding or subtracting a
year-to-month and a day-to-second duration is 22G14 (incompatible temporal
instant unit groups, 20.28 GR 5c ii); a mixed operand is added part by part.
A component past its field's range (`P999999999Y`) is 22015 (interval field
overflow); text that is not an ISO 8601 duration is 22G0H.

## Error Handling

### Common Error Codes

- `ERR_FLOAT_NAN` - NaN/Inf not allowed in Real/Double
- `ERR_CHAR_LEN` - String exceeds char(n)/varchar(n) limit
- `ERR_DEC_DIV_ZERO` - Decimal division by zero
- `ERR_TIME_PARSE` - Invalid temporal format
- `ERR_JSON_INVALID` - Malformed JSON
- `ERR_URL_PARSE` - Invalid URL syntax
- `ERR_ARRAY_ELEM_TYPE` - Mixed types in array
- `ERR_INDEX` - Array index out of bounds

## Storage Tags Reference

| Tag Range | Type Category |
|-----------|--------------|
| 0x00-0x03 | Legacy core types (Null, Bool, Int, String) |
| 0x04-0x11 | First-class types (Network, Hash, Geographic, etc.) |
| 0x20-0x39 | Advanced types (Decimal, Temporal, JSON, etc.) |

## Performance Tips

1. **Use appropriate numeric types**: SmallInt for small ranges saves space
2. **Prefer JSONB over JSON**: Binary format is faster and canonical
3. **Use CIDR indexes**: Patricia tries make IP lookups O(prefix_bits)
4. **Leverage SIMD vectors**: VectorF32 operations are hardware-accelerated
5. **Consider HNSW for KNN**: Much faster than full scan for large datasets
6. **Use appropriate string type**: char(n) for fixed-length, varchar(n) for bounded, text for unlimited

## Type System Philosophy

- **Fail closed**: Invalid data rejected at construction
- **Canonical storage**: One normalized form per value
- **NULL propagation**: SQL-compatible three-valued logic
- **Type safety**: No implicit dangerous conversions
- **Performance**: SIMD where possible, efficient encodings
- **Persistence**: All indexes support snapshot + WAL
