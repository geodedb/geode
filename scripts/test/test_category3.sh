#!/bin/sh

echo "Testing Category 3 System Features"
echo "===================================="
echo ""

echo "1. TDE invalid provider:"
echo "CALL tde.configure_provider('InvalidProvider') YIELD status RETURN status" | ./zig-out/bin/geode query --server 127.0.0.1:3141 --insecure --format json - 2>&1
exitcode1=$?
echo "[Exit code: $exitcode1]"
echo ""

echo "2. CDC invalid guardrail:"
echo "CALL cdc.set_guardrail('invalid_threshold', -1) YIELD status RETURN status" | ./zig-out/bin/geode query --server 127.0.0.1:3141 --insecure --format json - 2>&1
exitcode2=$?
echo "[Exit code: $exitcode2]"
echo ""

echo "3. CDC unknown command:"
echo "CALL cdc.invalid_command() YIELD status RETURN status" | ./zig-out/bin/geode query --server 127.0.0.1:3141 --insecure --format json - 2>&1
exitcode3=$?
echo "[Exit code: $exitcode3]"
echo ""

echo "4. Audit get recent events:"
echo "CALL audit.get_recent_events({limit: 5}) YIELD seq_no, timestamp, event_type RETURN seq_no, timestamp, event_type" | ./zig-out/bin/geode query --server 127.0.0.1:3141 --insecure --format json - 2>&1
exitcode4=$?
echo "[Exit code: $exitcode4]"
echo ""

echo "Summary:"
echo "--------"
[ $exitcode1 -eq 1 ] && echo "✓ TDE validation returns error" || echo "✗ TDE validation failed"
[ $exitcode2 -eq 1 ] && echo "✓ CDC validation returns error" || echo "✗ CDC validation failed"
[ $exitcode3 -eq 1 ] && echo "✓ CDC unknown command returns error" || echo "✗ CDC unknown command failed"
[ $exitcode4 -eq 0 ] && echo "✓ Audit logging works" || echo "✗ Audit logging failed"
