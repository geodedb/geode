#!/bin/sh

echo "=== Test: Vendor Server with Different Configurations ==="
pkill -KILL quic-server 2>/dev/null || true
sleep 1

# Generate test certs
cd vendor/quic
mkdir -p test_certs
openssl req -x509 -newkey rsa:2048 -keyout test_certs/test.key -out test_certs/test.crt -days 1 -nodes -subj "/CN=test" 2>/dev/null

# Test 1: insecure mode (no TLS)
echo ""
echo "Test 1: Starting server in insecure mode..."
./zig-out/bin/quic-server --bind 127.0.0.1:4433 --insecure > /tmp/vendor_insecure.log 2>&1 &
sleep 3

echo "Sending netcat packet to insecure server..."
echo "test1" | nc -u 127.0.0.1 4433 &
sleep 2

pkill -KILL quic-server 2>/dev/null || true
sleep 1

if grep -q "recvfrom got" /tmp/vendor_insecure.log; then
    echo "✅ Insecure mode: Packets RECEIVED"
else
    echo "❌ Insecure mode: Packets NOT received"
fi

# Test 2: real TLS mode
echo ""
echo "Test 2: Starting server in real TLS mode..."
./zig-out/bin/quic-server --bind 127.0.0.1:4433 --real-tls --cert test_certs/test.crt --key test_certs/test.key > /tmp/vendor_realtls.log 2>&1 &
sleep 3

echo "Sending netcat packet to TLS server..."
echo "test2" | nc -u 127.0.0.1 4433 &
sleep 2

pkill -KILL quic-server 2>/dev/null || true

if grep -q "recvfrom got" /tmp/vendor_realtls.log; then
    echo "✅ Real TLS mode: Packets RECEIVED"
else
    echo "❌ Real TLS mode: Packets NOT received"
fi

echo ""
echo "=== Logs ==="
echo "Insecure mode (grep recvfrom):"
grep "recvfrom" /tmp/vendor_insecure.log | head -5

echo ""
echo "Real TLS mode (grep recvfrom):"
grep "recvfrom" /tmp/vendor_realtls.log | head -5

cd ../..
