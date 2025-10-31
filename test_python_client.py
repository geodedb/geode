#!/usr/bin/env python3
"""Test the Python client connectivity."""
import asyncio
import sys
import os

# Add client to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'clients/python'))

from geode_client import Client


async def test_connection():
    """Test basic connection and query."""
    print("Testing Python client...")
    print("=" * 50)

    # Create client with skip_verify for self-signed certs
    client = Client(host="127.0.0.1", port=3141, skip_verify=True)

    try:
        # Connect
        print("Connecting to server...")
        async with client.connection() as conn:
            print("✓ Connected!")

            # Simple query
            print("\nExecuting query: RETURN 1 AS x, 'Hello from Python' AS msg")
            page, _ = await conn.query("RETURN 1 AS x, 'Hello from Python' AS msg")

            print(f"✓ Query executed successfully!")
            print(f"  Columns: {[col.name for col in page.columns]}")
            print(f"  Rows: {len(page.rows)}")

            for row in page.rows:
                print(f"  Result: x={row['x'].value}, msg={row['msg'].value}")

            print("\n✅ Python client test PASSED!")
            return 0

    except Exception as e:
        print(f"\n❌ Test FAILED: {e}")
        import traceback
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    exit_code = asyncio.run(test_connection())
    sys.exit(exit_code)
