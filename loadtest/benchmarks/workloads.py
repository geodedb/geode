#!/usr/bin/env python3
# CANARY: REQ=REQ-LOADTEST-WORKLOADS-001; FEATURE="WorkloadPatterns"; ASPECT=Definition; STATUS=IMPL; OWNER=loadtest; UPDATED=2026-01-03
"""
Geode Workload Pattern Definitions

Defines realistic workload patterns for internet-scale graph testing.
"""

from dataclasses import dataclass
from typing import List, Dict
from enum import Enum


class WorkloadType(Enum):
    """Types of workload patterns."""
    READ_HEAVY = "read_heavy"
    WRITE_HEAVY = "write_heavy"
    MIXED = "mixed"
    ANALYTICAL = "analytical"
    TRAVERSAL = "traversal"
    BURST = "burst"


@dataclass
class WorkloadPattern:
    """Definition of a workload pattern."""
    name: str
    workload_type: WorkloadType
    description: str
    read_ratio: float  # 0.0 - 1.0
    write_ratio: float  # 0.0 - 1.0
    query_mix: Dict[str, float]  # Query category -> ratio
    target_qps: int
    duration_seconds: int
    ramp_up_seconds: int = 30
    concurrent_users: int = 10


# Workload pattern definitions
WORKLOAD_PATTERNS = {
    "web_app": WorkloadPattern(
        name="Web Application",
        workload_type=WorkloadType.READ_HEAVY,
        description="Typical web application with mostly reads",
        read_ratio=0.95,
        write_ratio=0.05,
        query_mix={
            "point_lookup": 0.50,
            "traversal": 0.30,
            "aggregation": 0.15,
            "write": 0.05
        },
        target_qps=1000,
        duration_seconds=300,
        concurrent_users=50
    ),

    "social_network": WorkloadPattern(
        name="Social Network",
        workload_type=WorkloadType.MIXED,
        description="Social network with feed generation and posts",
        read_ratio=0.80,
        write_ratio=0.20,
        query_mix={
            "traversal": 0.40,
            "point_lookup": 0.25,
            "aggregation": 0.15,
            "write": 0.20
        },
        target_qps=500,
        duration_seconds=300,
        concurrent_users=100
    ),

    "fraud_detection": WorkloadPattern(
        name="Fraud Detection",
        workload_type=WorkloadType.ANALYTICAL,
        description="Real-time fraud detection with pattern matching",
        read_ratio=0.90,
        write_ratio=0.10,
        query_mix={
            "pattern": 0.35,
            "traversal": 0.30,
            "analytical": 0.25,
            "write": 0.10
        },
        target_qps=200,
        duration_seconds=600,
        concurrent_users=20
    ),

    "recommendation_engine": WorkloadPattern(
        name="Recommendation Engine",
        workload_type=WorkloadType.TRAVERSAL,
        description="Collaborative filtering and recommendations",
        read_ratio=0.85,
        write_ratio=0.15,
        query_mix={
            "traversal": 0.50,
            "aggregation": 0.20,
            "analytical": 0.15,
            "write": 0.15
        },
        target_qps=300,
        duration_seconds=300,
        concurrent_users=30
    ),

    "network_monitoring": WorkloadPattern(
        name="Network Monitoring",
        workload_type=WorkloadType.WRITE_HEAVY,
        description="High-velocity network event ingestion",
        read_ratio=0.30,
        write_ratio=0.70,
        query_mix={
            "write": 0.70,
            "point_lookup": 0.15,
            "traversal": 0.10,
            "aggregation": 0.05
        },
        target_qps=5000,
        duration_seconds=300,
        concurrent_users=10
    ),

    "burst_traffic": WorkloadPattern(
        name="Burst Traffic",
        workload_type=WorkloadType.BURST,
        description="Simulates traffic spikes",
        read_ratio=0.80,
        write_ratio=0.20,
        query_mix={
            "point_lookup": 0.40,
            "traversal": 0.30,
            "write": 0.20,
            "aggregation": 0.10
        },
        target_qps=2000,
        duration_seconds=120,
        ramp_up_seconds=10,
        concurrent_users=200
    ),

    "analytics_batch": WorkloadPattern(
        name="Analytics Batch",
        workload_type=WorkloadType.ANALYTICAL,
        description="Batch analytics workload",
        read_ratio=1.0,
        write_ratio=0.0,
        query_mix={
            "analytical": 0.60,
            "aggregation": 0.30,
            "traversal": 0.10
        },
        target_qps=10,
        duration_seconds=3600,
        concurrent_users=5
    ),

    "internet_scale_ingest": WorkloadPattern(
        name="Internet Scale Ingestion",
        workload_type=WorkloadType.WRITE_HEAVY,
        description="Billion-scale data ingestion",
        read_ratio=0.05,
        write_ratio=0.95,
        query_mix={
            "write": 0.95,
            "point_lookup": 0.05
        },
        target_qps=50000,
        duration_seconds=3600,
        concurrent_users=20
    ),
}


def get_workload(name: str) -> WorkloadPattern:
    """Get a workload pattern by name."""
    if name not in WORKLOAD_PATTERNS:
        raise ValueError(f"Unknown workload: {name}. Available: {list(WORKLOAD_PATTERNS.keys())}")
    return WORKLOAD_PATTERNS[name]


def list_workloads() -> List[str]:
    """List all available workload patterns."""
    return list(WORKLOAD_PATTERNS.keys())


if __name__ == "__main__":
    print("Available Workload Patterns:")
    print("-" * 60)
    for name, pattern in WORKLOAD_PATTERNS.items():
        print(f"\n{name}:")
        print(f"  Type: {pattern.workload_type.value}")
        print(f"  Description: {pattern.description}")
        print(f"  Read/Write: {pattern.read_ratio * 100:.0f}% / {pattern.write_ratio * 100:.0f}%")
        print(f"  Target QPS: {pattern.target_qps}")
        print(f"  Duration: {pattern.duration_seconds}s")
        print(f"  Concurrent Users: {pattern.concurrent_users}")
