#!/usr/bin/env python3
"""Debug QUIC connection issue"""
import asyncio
import sys
sys.path.insert(0, '/home/benji/src/geode/geode/clients/python')

from geode_client import Client

async def test():
    try:
        print("Creating client...")
        client = Client(host="127.0.0.1", port=56795, skip_verify=True)

        print("Connecting...")
        conn = await asyncio.wait_for(client.connect(), timeout=15.0)

        print("SUCCESS! Connected")

        print("Executing query...")
        result = await conn.execute("RETURN 1 AS x")
        print(f"Result: {result}")

        await conn.close()
        print("Test passed!")

    except Exception as e:
        print(f"ERROR: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()
        return 1

    return 0

if __name__ == "__main__":
    sys.exit(asyncio.run(test()))
