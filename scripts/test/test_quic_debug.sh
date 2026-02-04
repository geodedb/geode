#!/bin/bash

# Simple QUIC test script to verify debug logging

set -e

echo "Starting QUIC debug test..."

# Clean up any previous test certificates and data
rm -rf /tmp/geode_test_certs
rm -rf /tmp/geode_debug_test_data

# Create test directories
mkdir -p /tmp/geode_test_certs
mkdir -p /tmp/geode_debug_test_data

# Generate test certificates using OpenSSL
echo "Generating test certificates..."

# Generate CA private key
openssl genrsa -out /tmp/geode_test_certs/ca-key.pem 2048

# Generate CA certificate
openssl req -new -x509 -key /tmp/geode_test_certs/ca-key.pem -out /tmp/geode_test_certs/ca-cert.pem -days 365 -subj "/C=US/ST=Test/L=Test/O=Geode Test/CN=Geode Test CA"

# Generate server private key
openssl genrsa -out /tmp/geode_test_certs/server-key.pem 2048

# Generate server certificate signing request
openssl req -new -key /tmp/geode_test_certs/server-key.pem -out /tmp/geode_test_certs/server.csr -subj "/C=US/ST=Test/L=Test/O=Geode Test/CN=127.0.0.1"

# Create SAN configuration for server certificate
cat > /tmp/geode_test_certs/server.conf << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = US
ST = Test
L = Test
O = Geode Test
CN = 127.0.0.1

[v3_req]
keyUsage = digitalSignature, keyEncipherment, keyAgreement
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
EOF

# Generate server certificate
openssl x509 -req -in /tmp/geode_test_certs/server.csr -CA /tmp/geode_test_certs/ca-cert.pem -CAkey /tmp/geode_test_certs/ca-key.pem -CAcreateserial -out /tmp/geode_test_certs/server-cert.pem -days 365 -extensions v3_req -extfile /tmp/geode_test_certs/server.conf

echo "Certificates generated successfully"

# Set certificate paths for Geode
export GEODE_CERT_PATH="/tmp/geode_test_certs/server-cert.pem"
export GEODE_KEY_PATH="/tmp/geode_test_certs/server-key.pem"
export GEODE_CA_PATH="/tmp/geode_test_certs/ca-cert.pem"

# Create certs directory in current working directory and copy certificates there
# (this is where Geode looks for certificates by default)
mkdir -p certs
cp /tmp/geode_test_certs/server-cert.pem certs/server.crt
cp /tmp/geode_test_certs/server-key.pem certs/server.key
cp /tmp/geode_test_certs/ca-cert.pem certs/ca.crt

echo "Starting Geode server with debug logging..."

# Start Geode server in background
./zig-out/bin/geode serve --listen 127.0.0.1:8443 --data-dir /tmp/geode_debug_test_data --disable-auth &
SERVER_PID=$!

# Give server time to start
sleep 2

echo "Attempting to connect with Geode client..."

# Try to connect with the client - this should show our debug logging
timeout 15s ./zig-out/bin/geode query "RETURN 1 AS test" --format json --server 127.0.0.1:8443 --insecure || {
    echo "Client connection attempt completed (may have timed out as expected)"
}

echo "Stopping server..."
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true

echo "QUIC debug test completed"
