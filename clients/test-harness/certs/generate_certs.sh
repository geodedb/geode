#!/bin/bash
set -e

# Navigate to the certs directory
cd "$(dirname "$0")"

echo "Generating test certificates for Geode client test harness..."

# 1. Generate CA certificate (valid for 10 years)
echo "1. Generating CA certificate..."
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout ca.key \
  -out ca.crt \
  -days 3650 \
  -subj "/C=US/ST=Test/L=Test/O=Geode Test/OU=Test CA/CN=Geode Test CA" \
  2>/dev/null

echo "   ✓ CA certificate created: ca.crt"

# 2. Generate server private key
echo "2. Generating server private key..."
openssl genrsa -out server.key 2048 2>/dev/null
echo "   ✓ Server private key created: server.key"

# 3. Create OpenSSL config file with SAN extensions
echo "3. Creating OpenSSL configuration with SAN..."
cat > san.cnf << 'EOFSAN'
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
C = US
ST = Test
L = Test
O = Geode Test
OU = Test Server
CN = localhost

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = *.localhost
IP.1 = 127.0.0.1
IP.2 = ::1
IP.3 = 0.0.0.0
EOFSAN

# 4. Generate certificate signing request (CSR)
echo "4. Generating certificate signing request..."
openssl req -new -key server.key -out server.csr -config san.cnf 2>/dev/null
echo "   ✓ CSR created: server.csr"

# 5. Sign the server certificate with the CA (valid for 1 year)
echo "5. Signing server certificate with CA..."
openssl x509 -req -in server.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt \
  -days 365 \
  -sha256 \
  -extensions v3_req \
  -extfile san.cnf \
  2>/dev/null

echo "   ✓ Server certificate created: server.crt"

# 6. Verify the certificate chain
echo "6. Verifying certificate chain..."
if openssl verify -CAfile ca.crt server.crt >/dev/null 2>&1; then
    echo "   ✓ Certificate chain valid"
else
    echo "   ✗ Certificate chain verification failed"
    exit 1
fi

# 7. Display certificate details
echo ""
echo "Certificate Details:"
echo "===================="
echo ""
echo "Subject:"
openssl x509 -in server.crt -noout -subject | sed 's/^/  /'
echo ""
echo "Issuer:"
openssl x509 -in server.crt -noout -issuer | sed 's/^/  /'
echo ""
echo "Validity:"
openssl x509 -in server.crt -noout -dates | sed 's/^/  /'
echo ""
echo "Subject Alternative Names:"
openssl x509 -in server.crt -noout -text | grep -A1 "Subject Alternative Name" | tail -1 | sed 's/^/  /'
echo ""

# 8. Set appropriate permissions
chmod 600 ca.key server.key
chmod 644 ca.crt server.crt

# 9. Clean up temporary files
rm -f san.cnf server.csr ca.srl

echo "✓ Certificate generation complete!"
echo ""
echo "Files created:"
echo "  - ca.crt       (CA certificate for clients)"
echo "  - ca.key       (CA private key)"
echo "  - server.crt   (Server certificate)"
echo "  - server.key   (Server private key)"
echo ""
echo "To use these certificates:"
echo "  Server: Use server.crt and server.key"
echo "  Clients: Trust ca.crt"
