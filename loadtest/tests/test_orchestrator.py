#!/usr/bin/env python3
# CANARY: REQ=REQ-LOADTEST-TESTS-004; FEATURE="OrchestratorTests"; ASPECT=UnitTests; STATUS=IMPL; OWNER=loadtest; UPDATED=2026-01-03
"""
Unit tests for Geode Cluster Orchestrator
"""

import unittest
import sys
from pathlib import Path
from unittest.mock import patch, MagicMock

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from cluster.orchestrator import (
    DeploymentMode,
    NodeRole,
    ClusterNode,
    ClusterConfig,
    ClusterOrchestrator,
)


class TestDeploymentMode(unittest.TestCase):
    """Tests for DeploymentMode enum."""

    def test_deployment_modes_exist(self):
        """Verify all expected deployment modes exist."""
        expected_modes = ["DOCKER", "KUBERNETES", "SSH", "LOCAL"]
        for mode_name in expected_modes:
            self.assertTrue(hasattr(DeploymentMode, mode_name))

    def test_deployment_mode_values(self):
        """Verify deployment mode values."""
        self.assertEqual(DeploymentMode.DOCKER.value, "docker")
        self.assertEqual(DeploymentMode.KUBERNETES.value, "kubernetes")
        self.assertEqual(DeploymentMode.SSH.value, "ssh")
        self.assertEqual(DeploymentMode.LOCAL.value, "local")


class TestNodeRole(unittest.TestCase):
    """Tests for NodeRole enum."""

    def test_node_roles_exist(self):
        """Verify all expected node roles exist."""
        expected_roles = ["SERVER", "GENERATOR", "METRICS"]
        for role_name in expected_roles:
            self.assertTrue(hasattr(NodeRole, role_name))

    def test_node_role_values(self):
        """Verify node role values."""
        self.assertEqual(NodeRole.SERVER.value, "server")
        self.assertEqual(NodeRole.GENERATOR.value, "generator")
        self.assertEqual(NodeRole.METRICS.value, "metrics")


class TestClusterNode(unittest.TestCase):
    """Tests for ClusterNode dataclass."""

    def test_cluster_node_creation(self):
        """Test creating a ClusterNode instance."""
        node = ClusterNode(
            id="server-0",
            host="localhost",
            port=3141,
            role=NodeRole.SERVER
        )
        self.assertEqual(node.id, "server-0")
        self.assertEqual(node.host, "localhost")
        self.assertEqual(node.port, 3141)
        self.assertEqual(node.role, NodeRole.SERVER)

    def test_cluster_node_defaults(self):
        """Test default values for ClusterNode."""
        node = ClusterNode(
            id="test",
            host="localhost",
            port=3141,
            role=NodeRole.SERVER
        )
        self.assertEqual(node.status, "unknown")
        self.assertEqual(node.metrics, {})
        self.assertEqual(node.last_heartbeat, 0)


class TestClusterConfig(unittest.TestCase):
    """Tests for ClusterConfig dataclass."""

    def test_cluster_config_creation(self):
        """Test creating a ClusterConfig instance."""
        config = ClusterConfig(
            name="test-cluster",
            deployment_mode=DeploymentMode.DOCKER
        )
        self.assertEqual(config.name, "test-cluster")
        self.assertEqual(config.deployment_mode, DeploymentMode.DOCKER)

    def test_cluster_config_defaults(self):
        """Test default values for ClusterConfig."""
        config = ClusterConfig(
            name="test",
            deployment_mode=DeploymentMode.LOCAL
        )
        self.assertEqual(config.server_nodes, 1)
        self.assertEqual(config.generator_nodes, 4)
        self.assertTrue(config.metrics_node)
        self.assertEqual(config.geode_image, "geode:latest")
        self.assertEqual(config.network_name, "geode-loadtest")
        self.assertEqual(config.base_port, 3141)

    def test_cluster_config_custom_values(self):
        """Test ClusterConfig with custom values."""
        config = ClusterConfig(
            name="custom",
            deployment_mode=DeploymentMode.KUBERNETES,
            server_nodes=3,
            generator_nodes=8,
            metrics_node=False,
            geode_image="geode:v2.0",
            base_port=4000
        )
        self.assertEqual(config.server_nodes, 3)
        self.assertEqual(config.generator_nodes, 8)
        self.assertFalse(config.metrics_node)
        self.assertEqual(config.geode_image, "geode:v2.0")
        self.assertEqual(config.base_port, 4000)


class TestClusterOrchestrator(unittest.TestCase):
    """Tests for ClusterOrchestrator class."""

    def setUp(self):
        """Set up test fixtures."""
        self.config = ClusterConfig(
            name="test-cluster",
            deployment_mode=DeploymentMode.LOCAL,
            server_nodes=2,
            generator_nodes=2
        )
        self.orchestrator = ClusterOrchestrator(self.config)

    def test_orchestrator_initialization(self):
        """Test orchestrator initializes correctly."""
        self.assertEqual(self.orchestrator.config, self.config)
        self.assertEqual(len(self.orchestrator.nodes), 0)

    def test_status_empty_cluster(self):
        """Test status of empty cluster."""
        status = self.orchestrator.status()
        self.assertEqual(status["name"], "test-cluster")
        self.assertEqual(status["deployment_mode"], "local")
        self.assertEqual(len(status["nodes"]), 0)

    def test_status_with_nodes(self):
        """Test status with nodes added."""
        self.orchestrator.nodes["server-0"] = ClusterNode(
            id="server-0",
            host="localhost",
            port=3141,
            role=NodeRole.SERVER,
            status="running"
        )
        status = self.orchestrator.status()
        self.assertEqual(len(status["nodes"]), 1)
        self.assertIn("server-0", status["nodes"])
        self.assertEqual(status["nodes"]["server-0"]["status"], "running")

    def test_generate_k8s_manifests(self):
        """Test Kubernetes manifest generation."""
        config = ClusterConfig(
            name="k8s-test",
            deployment_mode=DeploymentMode.KUBERNETES,
            server_nodes=3,
            generator_nodes=4
        )
        orchestrator = ClusterOrchestrator(config)
        manifests = orchestrator._generate_k8s_manifests()

        self.assertIn("namespace", manifests)
        self.assertIn("server", manifests)
        self.assertIn("generator", manifests)

        # Check namespace
        self.assertIn("geode-loadtest-k8s-test", manifests["namespace"])

        # Check server replicas
        self.assertIn("replicas: 3", manifests["server"])

        # Check generator replicas
        self.assertIn("replicas: 4", manifests["generator"])

    @patch('subprocess.run')
    def test_deploy_docker_creates_network(self, mock_run):
        """Test Docker deployment creates network."""
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        config = ClusterConfig(
            name="docker-test",
            deployment_mode=DeploymentMode.DOCKER,
            server_nodes=1,
            generator_nodes=0,
            metrics_node=False
        )
        orchestrator = ClusterOrchestrator(config)
        orchestrator._deploy_docker()

        # Verify network create was called
        calls = mock_run.call_args_list
        network_call = calls[0]
        self.assertIn("docker", network_call[0][0])
        self.assertIn("network", network_call[0][0])

    @patch('subprocess.run')
    @patch('subprocess.Popen')
    def test_deploy_local(self, mock_popen, mock_run):
        """Test local deployment starts processes."""
        mock_process = MagicMock()
        mock_process.pid = 12345
        mock_popen.return_value = mock_process

        config = ClusterConfig(
            name="local-test",
            deployment_mode=DeploymentMode.LOCAL,
            server_nodes=2,
            generator_nodes=0
        )
        orchestrator = ClusterOrchestrator(config)
        result = orchestrator._deploy_local()

        self.assertTrue(result)
        self.assertEqual(len(orchestrator.nodes), 2)
        self.assertIn("server-0", orchestrator.nodes)
        self.assertIn("server-1", orchestrator.nodes)

    @patch('subprocess.run')
    def test_teardown_docker(self, mock_run):
        """Test Docker teardown stops containers."""
        mock_run.return_value = MagicMock(returncode=0)

        config = ClusterConfig(
            name="teardown-test",
            deployment_mode=DeploymentMode.DOCKER
        )
        orchestrator = ClusterOrchestrator(config)
        orchestrator.nodes["server-0"] = ClusterNode(
            id="server-0",
            host="localhost",
            port=3141,
            role=NodeRole.SERVER
        )

        result = orchestrator.teardown()

        self.assertTrue(result)
        self.assertEqual(len(orchestrator.nodes), 0)

    def test_deploy_ssh_not_implemented(self):
        """Test SSH deployment returns False (not implemented)."""
        config = ClusterConfig(
            name="ssh-test",
            deployment_mode=DeploymentMode.SSH
        )
        orchestrator = ClusterOrchestrator(config)
        result = orchestrator._deploy_ssh()
        self.assertFalse(result)


class TestLoadTestWorkflow(unittest.TestCase):
    """Integration tests for load test workflow."""

    def test_run_load_test_without_generators(self):
        """Test load test falls back to local execution without generators."""
        config = ClusterConfig(
            name="no-gen-test",
            deployment_mode=DeploymentMode.LOCAL,
            server_nodes=1,
            generator_nodes=0
        )
        orchestrator = ClusterOrchestrator(config)
        orchestrator.nodes["server-0"] = ClusterNode(
            id="server-0",
            host="localhost",
            port=3141,
            role=NodeRole.SERVER,
            status="running"
        )

        # This should not raise an exception
        with patch('subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(
                returncode=0,
                stdout="",
                stderr=""
            )
            results = orchestrator.run_load_test(
                workload="web_app",
                target_nodes=100,
                target_edges=500,
                duration_seconds=10
            )

        self.assertIn("workload", results)
        self.assertEqual(results["workload"], "web_app")


if __name__ == "__main__":
    unittest.main()
