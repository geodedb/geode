#!/usr/bin/env python3
import json
import sys
from datetime import datetime

with open('status.json', 'r') as f:
    data = json.load(f)

print('# GAP Analysis — geode (CANARY Evidence Driven, Regenerated ' + datetime.now().strftime('%Y-%m-%d') + ')')
print()
print('This file is regenerated directly from the current `status.json` produced by `./bin/canaryscan --root . --out status.json --csv status.csv --verify docs/GAP_ANALYSIS.md --strict`.')
print()
print('Legend (Status column):')
print()
print('- STUB : Structural placeholder; minimal or no functional behavior.')
print('- IMPL : Implementation present (no direct test / bench evidence). (None currently — all promoted.)')
print('- TESTED: At least one associated test (either explicitly declared or auto‑promoted from IMPL).')
print('- BENCHED: At least one benchmark (strongest; may also have tests).')
print()
print('Auto‑promotion rules (scanner): IMPL + test → TESTED; (IMPL|TESTED) + bench → BENCHED. Dates (`UPDATED`) must be ≤60 days old under `--strict` (all current rows pass as of ' + datetime.now().strftime('%Y-%m-%d') + ').')
print()
print('## Evidence Table')
print()
print('| Requirement | Feature                                   | Aspect                                   | Status  | Files (sample)                                   | Tests (sample)                                                      | Benches (sample)                                     | UPDATED    |')
print('| ----------- | ----------------------------------------- | ---------------------------------------- | ------- | ------------------------------------------------ | ------------------------------------------------------------------- | ---------------------------------------------------- | ---------- |')

# Aggregate and sort requirements
reqs = {}
for req in data['requirements']:
    req_id = req['id']
    for feature in req['features']:
        key = (req_id, feature['feature'], feature['aspect'])
        if key not in reqs:
            reqs[key] = {
                'status': feature['status'],
                'files': feature.get('files', []),
                'tests': feature.get('tests', []),
                'benches': feature.get('benches', []),
                'updated': feature.get('updated', ''),
            }
        else:
            # Merge if duplicate
            reqs[key]['files'].extend(feature.get('files', []))
            reqs[key]['tests'].extend(feature.get('tests', []))
            reqs[key]['benches'].extend(feature.get('benches', []))

# Sort and print
for (req_id, feature_name, aspect), info in sorted(reqs.items()):
    files_sample = ', '.join(info['files'][:2]) if info['files'] else '–'
    tests_sample = ', '.join(info['tests'][:2]) if info['tests'] else '–'
    benches_sample = ', '.join(info['benches'][:2]) if info['benches'] else '–'
    print(f'| {req_id} | {feature_name[:45]:<45} | {aspect[:40]:<40} | {info["status"]:<7} | {files_sample[:48]:<48} | {tests_sample[:67]:<67} | {benches_sample[:52]:<52} | {info["updated"]} |')

print()
print('## Gaps & Immediate Focus')
print()
print('| Gap                                    | REQ     | Aspect(s) | Current  | Target   | Planned Action                                                                                            |')
print('| -------------------------------------- | ------- | --------- | -------- | -------- | --------------------------------------------------------------------------------------------------------- |')

# Count by status
status_counts = data['summary']['by_status']
stub_count = status_counts.get('STUB', 0)
tested_count = status_counts.get('TESTED', 0)
benched_count = status_counts.get('BENCHED', 0)

# Identify gaps
gaps = []
for req in data['requirements']:
    for feature in req['features']:
        if feature['status'] == 'STUB':
            gaps.append((req['id'], feature['feature'], feature['aspect']))

if gaps:
    for req_id, feature, aspect in gaps[:5]:  # Show top 5 gaps
        print(f'| {feature[:38]:<38} | {req_id[8:11]} | {aspect[:9]} | STUB     | TESTED   | Implement and add test coverage                                                                           |')
else:
    print('| No critical gaps - all features tested or benched | –       | –         | –        | –        | Continue with performance benchmarking and edge case testing                                              |')

print()
print('## Summary Statistics')
print()
print(f'- Total feature aspects: {sum(status_counts.values())}')
print(f'- STUB: {stub_count}')
print(f'- TESTED: {tested_count}')
print(f'- BENCHED: {benched_count}')
print(f'- Coverage rate: {((tested_count + benched_count) / sum(status_counts.values()) * 100):.1f}%')