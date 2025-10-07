import subprocess
import json

# Test current_user() without token
result = subprocess.run(['./zig-out/bin/geode', 'query', '--no-quic', 'RETURN current_user() AS user'], 
                       capture_output=True, text=True)
print(f"Without token: {result.stdout.strip()}")
parsed = json.loads(result.stdout)
assert parsed['columns'] == ['user']
assert parsed['rows'][0][0] == 'system'

# Test current_user() with token  
result = subprocess.run(['./zig-out/bin/geode', 'query', '--no-quic', '--token', 'api_token_xyz', 'RETURN current_user() AS user'], 
                       capture_output=True, text=True)
print(f"With token: {result.stdout.strip()}")
parsed = json.loads(result.stdout)
assert parsed['columns'] == ['user']
assert parsed['rows'][0][0] == 'authenticated_user'

print("✓ Token authentication tests passed!")
