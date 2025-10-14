#!/bin/bash

echo "Testing TDE error exit code..."
echo "CALL tde.configure_provider('InvalidProvider') YIELD status RETURN status" | ./zig-out/bin/geode query --no-quic --format json - >/dev/null 2>&1
tde_exit=$?
echo "TDE error exit code: $tde_exit"

echo ""
echo "Testing CDC error exit code..."
echo "CALL cdc.set_guardrail('invalid', -1) YIELD status RETURN status" | ./zig-out/bin/geode query --no-quic --format json - >/dev/null 2>&1
cdc_exit=$?
echo "CDC error exit code: $cdc_exit"

echo ""
echo "Testing successful query exit code..."
echo "RETURN 1" | ./zig-out/bin/geode query --no-quic --format json - >/dev/null 2>&1
success_exit=$?
echo "Success exit code: $success_exit"
