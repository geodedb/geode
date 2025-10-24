const std = @import("std");
const testing = std.testing;

// Import advanced types
const types = @import("geode").types;
const vector = types.vector;
const geographic = types.geographic;
const cryptographic = types.cryptographic;

// CANARY: REQ=REQ-GQL-ADVANCED-TYPES-REGRESSION; FEATURE="Advanced Types Regression Tests"; ASPECT=Testing; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_ADVANCED_TYPES_REGRESSION_All; OWNER=testing; UPDATED=2025-01-03

test "TestCANARY_REQ_GQL_VECTOR_TYPES_001_VectorF32 comprehensive functionality" {
    const allocator = testing.allocator;

    // Test string parsing
    const vec1 = try vector.VectorF32.fromString("[1.0, 2.0, 3.0]", allocator);
    defer vec1.deinit(allocator);

    try testing.expectEqual(@as(u16, 3), vec1.dim);
    try testing.expectEqual(@as(f32, 1.0), vec1.data[0]);
    try testing.expectEqual(@as(f32, 2.0), vec1.data[1]);
    try testing.expectEqual(@as(f32, 3.0), vec1.data[2]);

    // Test string formatting
    const vec_str = try vec1.toString(allocator);
    defer allocator.free(vec_str);
    try testing.expect(std.mem.startsWith(u8, vec_str, "["));
    try testing.expect(std.mem.endsWith(u8, vec_str, "]"));

    // Test vector operations
    const vec2 = try vector.VectorF32.fromString("[4.0, 5.0, 6.0]", allocator);
    defer vec2.deinit(allocator);

    const distance = try vec1.distance(vec2);
    try testing.expect(distance > 5.0 and distance < 6.0);

    const dot_product = try vec1.dotProduct(vec2);
    try testing.expectEqual(@as(f32, 32.0), dot_product);

    const cosine_sim = try vec1.cosineSimilarity(vec2);
    try testing.expect(cosine_sim > 0.9 and cosine_sim < 1.0);

    const norm = vec1.norm();
    try testing.expect(norm > 3.7 and norm < 3.8);

    // Test vector addition
    const vec_sum = try vec1.add(vec2, allocator);
    defer vec_sum.deinit(allocator);
    try testing.expectEqual(@as(f32, 5.0), vec_sum.data[0]);
    try testing.expectEqual(@as(f32, 7.0), vec_sum.data[1]);
    try testing.expectEqual(@as(f32, 9.0), vec_sum.data[2]);

    // Test vector scaling
    const vec_scaled = try vec1.scale(2.0, allocator);
    defer vec_scaled.deinit(allocator);
    try testing.expectEqual(@as(f32, 2.0), vec_scaled.data[0]);
    try testing.expectEqual(@as(f32, 4.0), vec_scaled.data[1]);
    try testing.expectEqual(@as(f32, 6.0), vec_scaled.data[2]);

    // Test normalization
    const vec_normalized = try vec1.normalize(allocator);
    defer vec_normalized.deinit(allocator);
    const normalized_norm = vec_normalized.norm();
    try testing.expect(normalized_norm > 0.99 and normalized_norm < 1.01);
}

test "TestCANARY_REQ_GQL_VECTOR_TYPES_002_VectorI32 comprehensive functionality" {
    const allocator = testing.allocator;

    // Test string parsing
    const vec1 = try vector.VectorI32.fromString("[1, 2, 3]", allocator);
    defer vec1.deinit(allocator);

    try testing.expectEqual(@as(u16, 3), vec1.dim);
    try testing.expectEqual(@as(i32, 1), vec1.data[0]);
    try testing.expectEqual(@as(i32, 2), vec1.data[1]);
    try testing.expectEqual(@as(i32, 3), vec1.data[2]);

    // Test vector operations
    const vec2 = try vector.VectorI32.fromString("[4, 5, 6]", allocator);
    defer vec2.deinit(allocator);

    const manhattan_dist = try vec1.manhattanDistance(vec2);
    try testing.expectEqual(@as(i64, 9), manhattan_dist);

    const hamming_dist = try vec1.hammingDistance(vec2);
    try testing.expectEqual(@as(u32, 3), hamming_dist);

    const dot_product = try vec1.dotProduct(vec2);
    try testing.expectEqual(@as(i64, 32), dot_product);

    // Test vector addition
    const vec_sum = try vec1.add(vec2, allocator);
    defer vec_sum.deinit(allocator);
    try testing.expectEqual(@as(i32, 5), vec_sum.data[0]);
    try testing.expectEqual(@as(i32, 7), vec_sum.data[1]);
    try testing.expectEqual(@as(i32, 9), vec_sum.data[2]);

    // Test vector scaling
    const vec_scaled = try vec1.scale(3, allocator);
    defer vec_scaled.deinit(allocator);
    try testing.expectEqual(@as(i32, 3), vec_scaled.data[0]);
    try testing.expectEqual(@as(i32, 6), vec_scaled.data[1]);
    try testing.expectEqual(@as(i32, 9), vec_scaled.data[2]);
}

test "TestCANARY_REQ_GQL_GEO_TYPES_001_LatLon comprehensive functionality" {
    const allocator = testing.allocator;

    // Test coordinate creation and validation
    const coord1 = try geographic.LatLon.fromCoords(40.7128, -74.0060); // New York
    const coord2 = try geographic.LatLon.fromCoords(34.0522, -118.2437); // Los Angeles

    try testing.expect(coord1.isValid());
    try testing.expect(coord2.isValid());

    // Test string parsing various formats
    const coord3 = try geographic.LatLon.fromString("40.7128,-74.0060");
    try testing.expectEqual(coord1.lat, coord3.lat);
    try testing.expectEqual(coord1.lon, coord3.lon);

    const coord4 = try geographic.LatLon.fromString("(34.0522, -118.2437)");
    try testing.expectEqual(coord2.lat, coord4.lat);
    try testing.expectEqual(coord2.lon, coord4.lon);

    const coord5 = try geographic.LatLon.fromString("40.7128 -74.0060");
    try testing.expectEqual(coord1.lat, coord5.lat);
    try testing.expectEqual(coord1.lon, coord5.lon);

    // Test string representation
    const coord_str = try coord1.toString(allocator);
    defer allocator.free(coord_str);
    try testing.expect(std.mem.indexOf(u8, coord_str, "40.7128") != null);
    try testing.expect(std.mem.indexOf(u8, coord_str, "-74.006") != null);

    // Test distance calculation (NY to LA is approximately 3944 km)
    const distance = coord1.distanceKm(coord2);
    try testing.expect(distance > 3900.0 and distance < 4000.0);

    // Test bearing calculation (NY to LA should be southwest)
    const bearing = coord1.bearingTo(coord2);
    try testing.expect(bearing > 240.0 and bearing < 260.0);

    // Test bounding box check
    const sw = try geographic.LatLon.fromCoords(40.0, -75.0);
    const ne = try geographic.LatLon.fromCoords(41.0, -74.0);
    try testing.expect(coord1.isWithinBounds(sw, ne));

    // Test movement by bearing
    const moved = coord1.moveByBearing(100.0, 90.0); // Move 100km east
    try testing.expect(moved.lon > coord1.lon); // Should be more east
    try testing.expect(@abs(moved.lat - coord1.lat) < 1.0); // Should be roughly same latitude
}

test "TestCANARY_REQ_GQL_GEO_TYPES_002_LatLonAlt comprehensive functionality" {
    const allocator = testing.allocator;

    // Test 3D coordinates
    const coord1 = try geographic.LatLonAlt.fromCoords(40.7128, -74.0060, 100.0);
    const coord2 = try geographic.LatLonAlt.fromCoords(40.7128, -74.0060, 200.0);

    try testing.expect(coord1.isValid());
    try testing.expect(coord2.isValid());

    // Test string parsing
    const coord3 = try geographic.LatLonAlt.fromString("40.7128,-74.0060,100.0");
    try testing.expectEqual(coord1.lat, coord3.lat);
    try testing.expectEqual(coord1.lon, coord3.lon);
    try testing.expectEqual(coord1.alt, coord3.alt);

    const coord4 = try geographic.LatLonAlt.fromString("(40.7128, -74.0060, 100.0)");
    try testing.expectEqual(coord1.lat, coord4.lat);
    try testing.expectEqual(coord1.lon, coord4.lon);
    try testing.expectEqual(coord1.alt, coord4.alt);

    // Test string representation
    const coord_str = try coord1.toString(allocator);
    defer allocator.free(coord_str);
    try testing.expect(std.mem.indexOf(u8, coord_str, "100") != null);

    // Test 3D distance (should be approximately 0.1 km due to altitude difference)
    const distance = coord1.distance3D(coord2);
    try testing.expect(distance > 0.09 and distance < 0.11);

    // Test conversion to LatLon
    const latlon = coord1.toLatLon();
    try testing.expectEqual(coord1.lat, latlon.lat);
    try testing.expectEqual(coord1.lon, latlon.lon);
}

test "TestCANARY_REQ_GQL_GEO_TYPES_003_GeoPoint comprehensive functionality" {
    const allocator = testing.allocator;

    // Test point creation
    const point1 = try geographic.GeoPoint.fromCoords(40.7128, -74.0060);
    const point2 = try geographic.GeoPoint.fromString("34.0522,-118.2437");

    // Test distance
    const distance = point1.distanceKm(point2);
    try testing.expect(distance > 3900.0 and distance < 4000.0);

    // Test with properties
    const props = "{\"name\":\"New York\",\"population\":8175133}";
    const point_with_props = point1.withProperties(props);
    try testing.expectEqualStrings(props, point_with_props.properties.?);

    // Test string representation
    const point_str = try point1.toString(allocator);
    defer allocator.free(point_str);
    try testing.expect(std.mem.indexOf(u8, point_str, "40.7128") != null);
}

test "TestCANARY_REQ_GQL_CRYPTO_TYPES_001_Signature comprehensive functionality" {
    const allocator = testing.allocator;

    // Test signature creation from hex
    const sig = try cryptographic.Signature.fromHex(.Ed25519, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", allocator);
    defer sig.deinit(allocator);

    try testing.expectEqual(cryptographic.Signature.SignatureAlg.Ed25519, sig.alg);
    try testing.expectEqual(@as(usize, 64), sig.signature.len);
    try testing.expectEqual(@as(usize, 32), sig.public_key.?.len);

    // Test string representation
    const sig_str = try sig.toString(allocator);
    defer allocator.free(sig_str);
    try testing.expect(std.mem.startsWith(u8, sig_str, "Ed25519:"));

    // Test signature parsing from string
    const parsed_sig = try cryptographic.Signature.fromString(sig_str, allocator);
    defer parsed_sig.deinit(allocator);
    try testing.expectEqual(sig.alg, parsed_sig.alg);
    try testing.expectEqualSlices(u8, sig.signature, parsed_sig.signature);

    // Test verification placeholder
    const is_valid = try sig.verify("test data");
    try testing.expect(is_valid);

    // Test algorithm string conversion
    try testing.expectEqualStrings("Ed25519", sig.alg.toString());

    const alg_parsed = try cryptographic.Signature.SignatureAlg.fromString("ECDSA-P256");
    try testing.expectEqual(cryptographic.Signature.SignatureAlg.ECDSA_P256, alg_parsed);
}

test "TestCANARY_REQ_GQL_CRYPTO_TYPES_002_HMAC comprehensive functionality" {
    const allocator = testing.allocator;

    // Test HMAC computation
    const key = "secret_key";
    const data = "hello world";

    const hmac = try cryptographic.Hmac.compute(.HMAC_SHA256, key, data, allocator);
    defer hmac.deinit(allocator);

    try testing.expectEqual(cryptographic.Hmac.HmacAlg.HMAC_SHA256, hmac.alg);
    try testing.expectEqual(@as(usize, 32), hmac.digest.len);

    // Test verification
    const is_valid = try hmac.verify(data, allocator);
    try testing.expect(is_valid);

    // Test different data should fail verification
    const is_invalid = try hmac.verify("different data", allocator);
    try testing.expect(!is_invalid);

    // Test string representation
    const hmac_str = try hmac.toString(allocator);
    defer allocator.free(hmac_str);
    try testing.expect(std.mem.startsWith(u8, hmac_str, "HMAC-SHA256:"));

    // Test algorithm properties
    try testing.expectEqual(@as(usize, 32), hmac.alg.digestSize());
    try testing.expectEqualStrings("HMAC-SHA256", hmac.alg.toString());
}

test "TestCANARY_REQ_GQL_CRYPTO_TYPES_003_KeyPair comprehensive functionality" {
    const allocator = testing.allocator;

    // Test key pair generation
    const keypair = try cryptographic.KeyPair.generate(.Ed25519, allocator);
    defer keypair.deinit(allocator);

    try testing.expectEqual(cryptographic.Signature.SignatureAlg.Ed25519, keypair.alg);
    try testing.expectEqual(@as(usize, 64), keypair.private_key.len);
    try testing.expectEqual(@as(usize, 32), keypair.public_key.len);

    // Test signing
    const signature = try keypair.sign("test message", allocator);
    defer signature.deinit(allocator);

    try testing.expectEqual(keypair.alg, signature.alg);
    try testing.expectEqual(@as(usize, 64), signature.signature.len);
    try testing.expect(signature.public_key != null);
    try testing.expectEqualSlices(u8, keypair.public_key, signature.public_key.?);
}

test "TestCANARY_REQ_GQL_ADVANCED_TYPES_004_Binary encoding round-trip" {
    const allocator = testing.allocator;
    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    // Test VectorF32 encoding/decoding
    const vec_f32 = try vector.VectorF32.fromString("[1.5, 2.5, 3.5]", allocator);
    defer vec_f32.deinit(allocator);

    try vec_f32.encode(fbs.writer());
    fbs.pos = 0;
    const decoded_f32 = try vector.VectorF32.decode(fbs.reader(), allocator);
    defer decoded_f32.deinit(allocator);

    try testing.expectEqual(vec_f32.dim, decoded_f32.dim);
    for (0..vec_f32.dim) |i| {
        try testing.expectEqual(vec_f32.data[i], decoded_f32.data[i]);
    }

    // Test LatLon encoding/decoding
    fbs.pos = 0;
    const coord = try geographic.LatLon.fromCoords(40.7128, -74.0060);

    try coord.encode(fbs.writer());
    fbs.pos = 0;
    const decoded_coord = try geographic.LatLon.decode(fbs.reader());

    try testing.expectEqual(coord.lat, decoded_coord.lat);
    try testing.expectEqual(coord.lon, decoded_coord.lon);

    // Test Signature encoding/decoding
    fbs.pos = 0;
    const sig = try cryptographic.Signature.fromHex(.Ed25519, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", allocator);
    defer sig.deinit(allocator);

    try sig.encode(fbs.writer());
    fbs.pos = 0;
    const decoded_sig = try cryptographic.Signature.decode(fbs.reader(), allocator);
    defer decoded_sig.deinit(allocator);

    try testing.expectEqual(sig.alg, decoded_sig.alg);
    try testing.expectEqualSlices(u8, sig.signature, decoded_sig.signature);
    try testing.expectEqualSlices(u8, sig.public_key.?, decoded_sig.public_key.?);
}

test "TestCANARY_REQ_GQL_ADVANCED_TYPES_005_Error handling comprehensive" {
    const allocator = testing.allocator;

    // Vector error cases
    try testing.expectError(error.InvalidVectorFormat, vector.VectorF32.fromString("[1.0, invalid]", allocator));
    try testing.expectError(error.EmptyVector, vector.VectorF32.fromString("[]", allocator));

    const vec1 = try vector.VectorF32.fromString("[1.0, 2.0]", allocator);
    defer vec1.deinit(allocator);
    const vec2 = try vector.VectorF32.fromString("[1.0, 2.0, 3.0]", allocator);
    defer vec2.deinit(allocator);
    try testing.expectError(error.DimensionMismatch, vec1.distance(vec2));

    // Geographic error cases
    try testing.expectError(error.InvalidLatitude, geographic.LatLon.fromCoords(91.0, 0.0));
    try testing.expectError(error.InvalidLongitude, geographic.LatLon.fromCoords(0.0, 181.0));
    try testing.expectError(error.InvalidCoordinateFormat, geographic.LatLon.fromString("invalid"));
    try testing.expectError(error.InvalidCoordinateFormat, geographic.LatLon.fromString("40.7128"));

    // Cryptographic error cases
    try testing.expectError(error.InvalidSignatureAlgorithm, cryptographic.Signature.SignatureAlg.fromString("Invalid"));
    try testing.expectError(error.InvalidSignatureLength, cryptographic.Signature.fromHex(.Ed25519, "short", null, allocator));
    try testing.expectError(error.InvalidPublicKeyLength, cryptographic.Signature.fromHex(.Ed25519, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "short", allocator));
}

test "TestCANARY_REQ_GQL_ADVANCED_TYPES_006_Performance and memory efficiency" {
    const allocator = testing.allocator;

    // Performance test: create and operate on many objects quickly
    const iterations = 100;

    // Vector performance
    for (0..iterations) |i| {
        const vec_str = try std.fmt.allocPrint(allocator, "[{d}, {d}, {d}]", .{ i, i + 1, i + 2 });
        defer allocator.free(vec_str);

        const vec = try vector.VectorF32.fromString(vec_str, allocator);
        defer vec.deinit(allocator);

        const norm = vec.norm();
        try testing.expect(norm > 0.0);
    }

    // Geographic performance
    for (0..iterations) |i| {
        const lat = 40.0 + @as(f64, @floatFromInt(i)) * 0.01;
        const lon = -74.0 + @as(f64, @floatFromInt(i)) * 0.01;

        const coord = try geographic.LatLon.fromCoords(lat, lon);
        try testing.expect(coord.isValid());

        const coord_str = try coord.toString(allocator);
        allocator.free(coord_str);
    }

    // Memory efficiency tests
    try testing.expectEqual(@sizeOf(f64) * 2, @sizeOf(geographic.LatLon));
    try testing.expectEqual(@sizeOf(f64) * 3, @sizeOf(geographic.LatLonAlt));
}

test "TestCANARY_REQ_GQL_ADVANCED_TYPES_007_Cross-type operations" {
    const allocator = testing.allocator;

    // Test vector operations with geographic coordinates
    const coord1 = try geographic.LatLon.fromCoords(40.7128, -74.0060);
    const coord2 = try geographic.LatLon.fromCoords(34.0522, -118.2437);

    // Create vectors from coordinate differences
    const lat_diff = coord2.lat - coord1.lat;
    const lon_diff = coord2.lon - coord1.lon;

    const coord_vec = try vector.VectorF32.fromString(try std.fmt.allocPrint(allocator, "[{d}, {d}]", .{ lat_diff, lon_diff }), allocator);
    defer {
        allocator.free(coord_vec.data);
        coord_vec.deinit(allocator);
    }

    try testing.expectEqual(@as(u16, 2), coord_vec.dim);

    // Test cryptographic hashing of geographic data
    const coord_str = try coord1.toString(allocator);
    defer allocator.free(coord_str);

    const hmac = try cryptographic.Hmac.compute(.HMAC_SHA256, "geo_key", coord_str, allocator);
    defer hmac.deinit(allocator);

    try testing.expectEqual(@as(usize, 32), hmac.digest.len);
}

test "TestCANARY_REQ_GQL_ADVANCED_TYPES_008_Integration with existing types" {
    const allocator = testing.allocator;

    // Test that advanced types work with basic operations
    const vec = try vector.VectorF32.fromString("[1.0, 2.0, 3.0]", allocator);
    defer vec.deinit(allocator);

    // Vector should have expected properties
    try testing.expectEqual(@as(u16, 3), vec.dim);
    try testing.expect(vec.data.len == 3);

    const coord = try geographic.LatLon.fromCoords(0.0, 0.0);
    try testing.expect(coord.isValid());
    try testing.expectEqual(@as(f64, 0.0), coord.lat);
    try testing.expectEqual(@as(f64, 0.0), coord.lon);

    // Test that signature algorithms have expected properties
    const ed25519_sig_size = cryptographic.Signature.SignatureAlg.Ed25519.expectedSignatureSize();
    const ed25519_key_size = cryptographic.Signature.SignatureAlg.Ed25519.expectedPublicKeySize();
    try testing.expectEqual(@as(usize, 64), ed25519_sig_size);
    try testing.expectEqual(@as(usize, 32), ed25519_key_size);
}
