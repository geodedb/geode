#!/usr/bin/env python3
"""Debug comparison between working and broken clients."""

import asyncio
import json
from pathlib import Path
import sys

# Add Python client to path
sys.path.insert(0, str(Path(__file__).parent / "clients" / "python"))

from aioquic.asyncio import connect
from aioquic.quic.configuration import QuicConfiguration
from geode_client import Client

async def test_simple():
    """Test with simple aioquic (WORKS)."""
    print("\n=== TESTING SIMPLE AIOQUIC (should work) ===")
    
    configuration = QuicConfiguration(
        is_client=True,
        alpn_protocols=["geode/1"],
    )
    configuration.verify_mode = False
    
    try:
        async with connect("localhost", 9999, configuration=configuration) as client:
            print("✓ Connected")
            reader, writer = await client.create_stream()
            print("✓ Stream created")
            
            hello_msg = json.dumps({"type": "HELLO", "client_name": "simple", "client_ver": "1.0"}) + "\n"
            writer.write(hello_msg.encode())
            await writer.drain()
            print("✓ HELLO sent")
            
            response = await asyncio.wait_for(reader.read(4096), timeout=5.0)
            print(f"✓ Response: {response.decode()[:50]}")
            return True
    except Exception as e:
        print(f"✗ Error: {e}")
        return False

async def test_library():
    """Test with geode_client library (BROKEN)."""
    print("\n=== TESTING GEODE_CLIENT LIBRARY (currently broken) ===")
    
    client = Client(host="localhost", port=9999, skip_verify=True)
    
    try:
        connection = await client.connect()
        print("✓ Connected")
        return True
    except Exception as e:
        print(f"✗ Error: {e}")
        return False

async def main():
    result1 = await test_simple()
    await asyncio.sleep(1)
    result2 = await test_library()
    
    print("\n=== RESULTS ===")
    print(f"Simple aioquic: {'PASS' if result1 else 'FAIL'}")
    print(f"Geode library:  {'PASS' if result2 else 'FAIL'}")
    
    return result1 and result2

if __name__ == "__main__":
    result = asyncio.run(main())
    sys.exit(0 if result else 1)
