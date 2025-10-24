OUTPUT=$(timeout 5 ./zig-out/bin/geodec "$query" --no-quic 2>&1 || true)
