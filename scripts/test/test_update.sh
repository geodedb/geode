OUTPUT=$(timeout 5 ./zig-out/bin/geodec "$query" --server 127.0.0.1:3141 --insecure 2>&1 || true)
