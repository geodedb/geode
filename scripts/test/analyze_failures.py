#!/usr/bin/env python3
import json
import sys

with open('test_logs/run_20251013_160206/summary.json', 'r') as f:
    data = json.load(f)

specs = data['spec_results']
failed_tests = []

for spec in specs:
    if 'test_results' in spec:
        for test in spec['test_results']:
            if not test.get('success', True):
                failed_tests.append({
                    'spec': spec.get('spec_file', 'unknown'),
                    'test': test['test_name'],
                    'message': test.get('message', 'unknown'),
                    'exit_code': test.get('exit_code'),
                    'stdout': test.get('stdout', '')[:200],
                    'stderr': test.get('stderr', '')[:200]
                })

print(f'Total failed: {len(failed_tests)}\n')
print('First 30 failures:\n')
for i, t in enumerate(failed_tests[:30], 1):
    print(f"{i}. {t['spec']} -> {t['test']}")
    print(f"   Message: {t['message']}")
    print(f"   Exit code: {t['exit_code']}")
    if t['stderr']:
        print(f"   Stderr: {t['stderr']}")
    if t['stdout']:
        print(f"   Stdout: {t['stdout']}")
    print()

# Group by failure message prefix
message_groups = {}
for t in failed_tests:
    prefix = t['message'].split(':')[0] if ':' in t['message'] else t['message'][:50]
    message_groups[prefix] = message_groups.get(prefix, 0) + 1

print('\nFailure patterns:')
for msg, count in sorted(message_groups.items(), key=lambda x: -x[1])[:10]:
    print(f'{count:3d} tests: {msg}')
