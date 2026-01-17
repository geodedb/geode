#!/usr/bin/env python3
# CANARY: REQ=REQ-LOADTEST-CLUSTER-001; FEATURE="ClusterOrchestrator"; ASPECT=Main; STATUS=EXEMPT; OWNER=loadtest; UPDATED=2026-01-03
"""
Geode Distributed Cluster Orchestrator

Manages distributed scale testing across multiple nodes.
Supports Docker, Kubernetes, and SSH-based deployment.
"""

import json
import time
import argparse
import subprocess
from dataclasses import dataclass, field, asdict
from typing import List, Dict, Optional
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from enum import Enum
import socket
import threading


class DeploymentMode(Enum):
    """Deployment modes for cluster orchestration."""
    DOCKER = "docker"
    KUBERNETES = "kubernetes"
    SSH = "ssh"
    LOCAL = "local"


class NodeRole(Enum):
    """Roles for cluster nodes."""
    SERVER = "server"
    GENERATOR = "generator"
    METRICS = "metrics"


@dataclass
class ClusterNode:
    """Represents a node in the test cluster."""
    id: str
    host: str
    port: int
    role: NodeRole
    status: str = "unknown"
    metrics: Dict = field(default_factory=dict)
    last_heartbeat: float = 0


@dataclass
class ClusterConfig:
    """Configuration for a test cluster."""
    name: str
    deployment_mode: DeploymentMode
    server_nodes: int = 1
    generator_nodes: int = 4
    metrics_node: bool = True
    geode_image: str = "geode:latest"
    network_name: str = "geode-loadtest"
    base_port: int = 3141


class ClusterOrchestrator:
    """Orchestrates distributed load testing clusters."""

    def __init__(self, config: ClusterConfig):
        self.config = config
        self.nodes: Dict[str, ClusterNode] = {}
        self.lock = threading.Lock()

    def deploy(self) -> bool:
        """Deploy the cluster based on configuration."""
        print(f"Deploying cluster '{self.config.name}' in {self.config.deployment_mode.value} mode...")

        if self.config.deployment_mode == DeploymentMode.DOCKER:
            return self._deploy_docker()
        elif self.config.deployment_mode == DeploymentMode.KUBERNETES:
            return self._deploy_kubernetes()
        elif self.config.deployment_mode == DeploymentMode.SSH:
            return self._deploy_ssh()
        elif self.config.deployment_mode == DeploymentMode.LOCAL:
            return self._deploy_local()
        else:
            raise ValueError(f"Unknown deployment mode: {self.config.deployment_mode}")

    def _deploy_docker(self) -> bool:
        """Deploy cluster using Docker."""
        # Create network
        subprocess.run(
            ["docker", "network", "create", self.config.network_name],
            capture_output=True
        )

        # Deploy server nodes
        for i in range(self.config.server_nodes):
            node_id = f"server-{i}"
            port = self.config.base_port + i
            container_name = f"geode-{self.config.name}-{node_id}"

            result = subprocess.run([
                "docker", "run", "-d",
                "--name", container_name,
                "--network", self.config.network_name,
                "-p", f"{port}:3141",
                "-e", f"GEODE_NODE_ID={node_id}",
                "-e", "GEODE_CLUSTER_MODE=true",
                self.config.geode_image,
                "serve", "--listen", "0.0.0.0:3141"
            ], capture_output=True, text=True)

            if result.returncode == 0:
                self.nodes[node_id] = ClusterNode(
                    id=node_id,
                    host="localhost",
                    port=port,
                    role=NodeRole.SERVER,
                    status="running"
                )
                print(f"  Started {node_id} on port {port}")
            else:
                print(f"  Failed to start {node_id}: {result.stderr}")
                return False

        # Deploy generator nodes
        for i in range(self.config.generator_nodes):
            node_id = f"generator-{i}"
            container_name = f"geode-{self.config.name}-{node_id}"

            result = subprocess.run([
                "docker", "run", "-d",
                "--name", container_name,
                "--network", self.config.network_name,
                "-e", f"GEODE_NODE_ID={node_id}",
                "-e", "GEODE_ROLE=generator",
                "-v", f"{Path.cwd()}/loadtest:/loadtest",
                self.config.geode_image,
                "sleep", "infinity"  # Keep container running
            ], capture_output=True, text=True)

            if result.returncode == 0:
                self.nodes[node_id] = ClusterNode(
                    id=node_id,
                    host=container_name,
                    port=0,
                    role=NodeRole.GENERATOR,
                    status="running"
                )
                print(f"  Started {node_id}")

        # Deploy metrics collector
        if self.config.metrics_node:
            node_id = "metrics"
            container_name = f"geode-{self.config.name}-metrics"
            metrics_port = self.config.base_port + 1000

            result = subprocess.run([
                "docker", "run", "-d",
                "--name", container_name,
                "--network", self.config.network_name,
                "-p", f"{metrics_port}:9090",
                "-v", f"{Path.cwd()}/loadtest/metrics:/metrics",
                "prom/prometheus:latest",
                "--config.file=/metrics/prometheus.yml"
            ], capture_output=True, text=True)

            if result.returncode == 0:
                self.nodes[node_id] = ClusterNode(
                    id=node_id,
                    host="localhost",
                    port=metrics_port,
                    role=NodeRole.METRICS,
                    status="running"
                )
                print(f"  Started metrics on port {metrics_port}")

        return True

    def _deploy_kubernetes(self) -> bool:
        """Deploy cluster using Kubernetes."""
        # Generate Kubernetes manifests
        manifests = self._generate_k8s_manifests()

        # Apply manifests
        for name, manifest in manifests.items():
            manifest_path = f"/tmp/geode-{name}.yaml"
            with open(manifest_path, "w") as f:
                f.write(manifest)

            result = subprocess.run(
                ["kubectl", "apply", "-f", manifest_path],
                capture_output=True, text=True
            )
            if result.returncode != 0:
                print(f"Failed to apply {name}: {result.stderr}")
                return False
            print(f"  Applied {name}")

        # Wait for pods to be ready
        print("  Waiting for pods...")
        subprocess.run([
            "kubectl", "wait", "--for=condition=ready", "pod",
            "-l", f"app=geode,cluster={self.config.name}",
            "--timeout=120s"
        ], capture_output=True)

        return True

    def _generate_k8s_manifests(self) -> Dict[str, str]:
        """Generate Kubernetes manifests."""
        return {
            "namespace": f"""
apiVersion: v1
kind: Namespace
metadata:
  name: geode-loadtest-{self.config.name}
""",
            "server": f"""
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: geode-server
  namespace: geode-loadtest-{self.config.name}
spec:
  serviceName: geode-server
  replicas: {self.config.server_nodes}
  selector:
    matchLabels:
      app: geode
      role: server
      cluster: {self.config.name}
  template:
    metadata:
      labels:
        app: geode
        role: server
        cluster: {self.config.name}
    spec:
      containers:
      - name: geode
        image: {self.config.geode_image}
        ports:
        - containerPort: 3141
        args: ["serve", "--listen", "0.0.0.0:3141"]
        resources:
          requests:
            memory: "2Gi"
            cpu: "1"
          limits:
            memory: "8Gi"
            cpu: "4"
---
apiVersion: v1
kind: Service
metadata:
  name: geode-server
  namespace: geode-loadtest-{self.config.name}
spec:
  selector:
    app: geode
    role: server
  ports:
  - port: 3141
    targetPort: 3141
  clusterIP: None
""",
            "generator": f"""
apiVersion: apps/v1
kind: Deployment
metadata:
  name: geode-generator
  namespace: geode-loadtest-{self.config.name}
spec:
  replicas: {self.config.generator_nodes}
  selector:
    matchLabels:
      app: geode
      role: generator
      cluster: {self.config.name}
  template:
    metadata:
      labels:
        app: geode
        role: generator
        cluster: {self.config.name}
    spec:
      containers:
      - name: generator
        image: {self.config.geode_image}
        command: ["sleep", "infinity"]
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
"""
        }

    def _deploy_ssh(self) -> bool:
        """Deploy cluster using SSH to remote hosts."""
        # This would read host configuration from a file
        print("SSH deployment not fully implemented - use Docker or Kubernetes")
        return False

    def _deploy_local(self) -> bool:
        """Deploy cluster locally for development."""
        for i in range(self.config.server_nodes):
            node_id = f"server-{i}"
            port = self.config.base_port + i

            # Start local geode process
            proc = subprocess.Popen(
                ["./zig-out/bin/geode", "serve", "--listen", f"0.0.0.0:{port}"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE
            )

            self.nodes[node_id] = ClusterNode(
                id=node_id,
                host="localhost",
                port=port,
                role=NodeRole.SERVER,
                status="running"
            )
            print(f"  Started {node_id} on port {port} (pid: {proc.pid})")

        return True

    def run_load_test(
        self,
        workload: str,
        target_nodes: int = 1_000_000,
        target_edges: int = 10_000_000,
        duration_seconds: int = 300
    ) -> Dict:
        """Run distributed load test."""
        print(f"\nStarting load test: {workload}")
        print(f"  Targets: {target_nodes:,} nodes, {target_edges:,} edges")
        print(f"  Duration: {duration_seconds}s")

        # Distribute work across generators
        generators = [n for n in self.nodes.values() if n.role == NodeRole.GENERATOR]
        if not generators:
            print("  No generators available, using direct execution")
            generators = [ClusterNode("local", "localhost", 0, NodeRole.GENERATOR)]

        nodes_per_generator = target_nodes // len(generators)
        edges_per_generator = target_edges // len(generators)

        results = []
        with ThreadPoolExecutor(max_workers=len(generators)) as executor:
            futures = []
            for i, gen in enumerate(generators):
                future = executor.submit(
                    self._run_generator,
                    gen,
                    i,
                    len(generators),
                    nodes_per_generator,
                    edges_per_generator,
                    duration_seconds
                )
                futures.append(future)

            for future in as_completed(futures):
                try:
                    result = future.result()
                    results.append(result)
                except Exception as e:
                    print(f"  Generator error: {e}")

        # Aggregate results
        total_nodes = sum(r.get("nodes_created", 0) for r in results)
        total_edges = sum(r.get("edges_created", 0) for r in results)
        total_time = max(r.get("duration_seconds", 0) for r in results)

        return {
            "workload": workload,
            "total_nodes": total_nodes,
            "total_edges": total_edges,
            "duration_seconds": total_time,
            "nodes_per_second": total_nodes / total_time if total_time > 0 else 0,
            "edges_per_second": total_edges / total_time if total_time > 0 else 0,
            "generator_results": results
        }

    def _run_generator(
        self,
        generator: ClusterNode,
        shard_id: int,
        total_shards: int,
        target_nodes: int,
        target_edges: int,
        duration_seconds: int
    ) -> Dict:
        """Run load generation on a single generator node."""
        start_time = time.time()

        if self.config.deployment_mode == DeploymentMode.DOCKER:
            cmd = [
                "docker", "exec", f"geode-{self.config.name}-{generator.id}",
                "python3", "/loadtest/generator/run.py",
                "--nodes", str(target_nodes),
                "--edges", str(target_edges),
                "--shard", str(shard_id),
                "--total-shards", str(total_shards)
            ]
        else:
            # Local execution
            server_node = next(
                (n for n in self.nodes.values() if n.role == NodeRole.SERVER),
                None
            )
            server_host = f"localhost:{server_node.port}" if server_node else "localhost:3141"

            cmd = [
                "./zig-out/bin/geode-loadgen",
                "-n", str(target_nodes),
                "-e", str(target_edges),
                "--shard", str(shard_id),
                "--total-shards", str(total_shards),
                "-q"
            ]

        result = subprocess.run(cmd, capture_output=True, text=True, timeout=duration_seconds + 60)
        elapsed = time.time() - start_time

        return {
            "generator_id": generator.id,
            "shard_id": shard_id,
            "nodes_created": target_nodes,
            "edges_created": target_edges,
            "duration_seconds": elapsed,
            "success": result.returncode == 0,
            "output": result.stdout[:1000] if result.stdout else "",
            "error": result.stderr[:500] if result.stderr else ""
        }

    def teardown(self) -> bool:
        """Tear down the cluster."""
        print(f"\nTearing down cluster '{self.config.name}'...")

        if self.config.deployment_mode == DeploymentMode.DOCKER:
            # Stop and remove containers
            for node_id in list(self.nodes.keys()):
                container_name = f"geode-{self.config.name}-{node_id}"
                subprocess.run(["docker", "stop", container_name], capture_output=True)
                subprocess.run(["docker", "rm", container_name], capture_output=True)
                print(f"  Removed {node_id}")

            # Remove network
            subprocess.run(
                ["docker", "network", "rm", self.config.network_name],
                capture_output=True
            )

        elif self.config.deployment_mode == DeploymentMode.KUBERNETES:
            subprocess.run([
                "kubectl", "delete", "namespace",
                f"geode-loadtest-{self.config.name}"
            ], capture_output=True)

        self.nodes.clear()
        return True

    def status(self) -> Dict:
        """Get cluster status."""
        status = {
            "name": self.config.name,
            "deployment_mode": self.config.deployment_mode.value,
            "nodes": {}
        }

        for node_id, node in self.nodes.items():
            status["nodes"][node_id] = {
                "host": node.host,
                "port": node.port,
                "role": node.role.value,
                "status": node.status
            }

        return status


def main():
    parser = argparse.ArgumentParser(description="Geode Cluster Orchestrator")
    parser.add_argument("action", choices=["deploy", "teardown", "status", "run"],
                        help="Action to perform")
    parser.add_argument("--name", default="loadtest", help="Cluster name")
    parser.add_argument("--mode", choices=["docker", "kubernetes", "local"],
                        default="local", help="Deployment mode")
    parser.add_argument("--servers", type=int, default=1, help="Number of server nodes")
    parser.add_argument("--generators", type=int, default=4, help="Number of generator nodes")
    parser.add_argument("--workload", default="web_app", help="Workload pattern for run")
    parser.add_argument("--nodes", type=int, default=1_000_000, help="Target nodes")
    parser.add_argument("--edges", type=int, default=10_000_000, help="Target edges")
    parser.add_argument("--duration", type=int, default=300, help="Test duration in seconds")

    args = parser.parse_args()

    config = ClusterConfig(
        name=args.name,
        deployment_mode=DeploymentMode(args.mode),
        server_nodes=args.servers,
        generator_nodes=args.generators
    )

    orchestrator = ClusterOrchestrator(config)

    if args.action == "deploy":
        success = orchestrator.deploy()
        if success:
            print("\nCluster deployed successfully!")
            print(json.dumps(orchestrator.status(), indent=2))
        else:
            print("\nCluster deployment failed!")
            exit(1)

    elif args.action == "teardown":
        orchestrator.teardown()
        print("Cluster torn down.")

    elif args.action == "status":
        print(json.dumps(orchestrator.status(), indent=2))

    elif args.action == "run":
        # Deploy first if needed
        if not orchestrator.nodes:
            orchestrator.deploy()

        results = orchestrator.run_load_test(
            workload=args.workload,
            target_nodes=args.nodes,
            target_edges=args.edges,
            duration_seconds=args.duration
        )
        print("\nLoad Test Results:")
        print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
