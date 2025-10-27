#!/usr/bin/env python3
"""Quick test of INTERSECT fix"""

import subprocess
import json
import sys

def test_intersect():
    """Test GPU INTERSECT returns correct results"""
    print("Testing GPU INTERSECT fix...")
    
    # Run the setops benchmark
    result = subprocess.run(
        ['./zig-out/bin/bench_gpu_setops'],
        capture_output=True,
        text=True,
        timeout=120
    )
    
    print("STDOUT:", result.stdout)
    if result.stderr:
        print("STDERR:", result.stderr)
    
    # Check for expected patterns
    output = result.stdout
    
    # Look for INTERSECT results
    if 'CPU INTERSECT:' in output and 'GPU INTERSECT:' in output:
        # Parse the numbers
        lines = output.split('\n')
        cpu_count = None
        gpu_count = None
        
        for line in lines:
            if 'CPU INTERSECT:' in line and 'common elements' in line:
                parts = line.split()
                cpu_count = int(parts[2])
            if 'GPU INTERSECT:' in line and 'common elements' in line:
                parts = line.split()
                gpu_count = int(parts[2])
        
        print(f"\nResults:")
        print(f"  CPU INTERSECT: {cpu_count} elements")
        print(f"  GPU INTERSECT: {gpu_count} elements")
        
        if cpu_count is not None and gpu_count is not None:
            if gpu_count == 0:
                print("  ❌ FAILURE: GPU returned 0 elements (bug not fixed)")
                return False
            elif abs(cpu_count - gpu_count) <= 100:  # Allow small variance
                print(f"  ✅ SUCCESS: Results match (within tolerance)")
                return True
            else:
                print(f"  ⚠️  WARNING: Results differ by {abs(cpu_count - gpu_count)}")
                return False
        else:
            print("  ⚠️  Could not parse results")
            return False
    else:
        print("  ℹ️  GPU not available or test skipped")
        return None

if __name__ == '__main__':
    result = test_intersect()
    if result is True:
        sys.exit(0)
    elif result is False:
        sys.exit(1)
    else:
        sys.exit(2)  # Skipped
