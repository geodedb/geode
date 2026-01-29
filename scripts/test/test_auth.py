import json
import subprocess

# Test current_user() without token
result = subprocess.run(
    ["./zig-out/bin/geode", "query", "--server 127.0.0.1:3141 --insecure", "RETURN current_user() AS user"],
    capture_output=True,
    text=True,
)
print(f"Without token: {result.stdout.strip()}")
parsed = json.loads(result.stdout)
assert parsed["columns"] == ["user"]
assert parsed["rows"][0][0] == "system"

# Test current_user() with token
result = subprocess.run(
    [
        "./zig-out/bin/geode",
        "query",
        "--server 127.0.0.1:3141 --insecure",
        "--token",
        "api_token_xyz",
        "RETURN current_user() AS user",
    ],
    capture_output=True,
    text=True,
)
print(f"With token: {result.stdout.strip()}")
parsed = json.loads(result.stdout)
assert parsed["columns"] == ["user"]
assert parsed["rows"][0][0] == "authenticated_user"

print("✓ Token authentication tests passed!")
