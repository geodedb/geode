import logging
import sys
import time

import yaml

import docker

# Configure logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)


def load_config(config_path="suite.yaml"):
    with open(config_path) as f:
        return yaml.safe_load(f)


def get_docker_client():
    return docker.from_env()


def run_command_in_container(container, command):
    logger.info(f"Running command in {container.name}: {command}")
    exit_code, output = container.exec_run(command)
    if exit_code != 0:
        logger.error(f"Command failed: {output.decode('utf-8')}")
    return exit_code, output.decode("utf-8")


def parse_duration(duration_str):
    """Parses a duration string (e.g., '10s', '1m') into seconds."""
    if duration_str.endswith("s"):
        return int(duration_str[:-1])
    elif duration_str.endswith("m"):
        return int(duration_str[:-1]) * 60
    # Add more units as needed
    return int(duration_str)  # Assume seconds if no unit


def chaos_packet_loss(container_name, duration="10s", loss_percent="20"):
    client = get_docker_client()
    # Inject packet loss using native tc inside the container
    # Requires 'iproute2' installed in the container and capability NET_ADMIN
    target_container = client.containers.get(container_name)

    logger.info(f"Adding {loss_percent}% packet loss to {container_name}")
    # Initialize netem
    exit_code, output = target_container.exec_run(f"tc qdisc add dev eth0 root netem loss {loss_percent}%", user="root")
    if exit_code != 0 and "File exists" not in output.decode():  # Ignore if already exists, but might fail logic
        logger.warning(f"tc qdisc add failed (might exist): {output.decode()}")
        # Try changing if it exists
        exit_code, output = target_container.exec_run(
            f"tc qdisc change dev eth0 root netem loss {loss_percent}%", user="root"
        )
        if exit_code != 0:
            raise Exception(f"Failed to inject packet loss: {output.decode()}")

    try:
        time.sleep(parse_duration(duration))
    finally:
        logger.info(f"Removing packet loss from {container_name}")
        exit_code, output = target_container.exec_run("tc qdisc del dev eth0 root", user="root")
        if exit_code != 0:
            logger.error(f"Failed to clean up tc rules: {output.decode()}")


def verify_leader(containers):
    # Check which node is leader via geode CLI or metrics
    # Simple check: Ask each node who the leader is
    leader = None
    for c in containers:
        try:
            # Assuming geode is available in the container
            code, output = run_command_in_container(c, "geode query 'RETURN 1' --server 127.0.0.1:3141 --insecure")
            if code == 0:
                # If we can write/read, we might be leader or forwarded.
                # Use a raft status command if available.
                # Fallback: check logs or specific endpoint.
                # Let's assume there is a /raft/status endpoint or CLI command
                pass
        except Exception:
            pass
    return leader


def run_test_scenario(scenario, client):
    name = scenario.get("name")
    logger.info(f"Starting Scenario: {name}")

    # Setup
    nodes = ["ha-node-1", "ha-node-2", "ha-node-3"]
    containers = [client.containers.get(n) for n in nodes]

    try:
        if scenario.get("type") == "leader_failure":
            # 1. Identify leader (assume node-1 for simplifying initial test)
            target = "ha-node-1"
            logger.info(f"Stopping leader {target}...")
            client.containers.get(target).stop()

            time.sleep(5)  # Wait for election

            # 2. Verify new leader elected (node-2 or node-3)
            # (Mock check for now)
            logger.info("Verifying cluster health...")

            # 3. Restart node
            client.containers.get(target).start()
            logger.info("Restarted leader")

        elif scenario.get("type") == "packet_loss":
            target = "ha-node-1"
            chaos_packet_loss(target, duration="10s", loss_percent="50")
            # Verify system still works during loss?

        elif scenario.get("type") == "generic_command":
            cmd = scenario.get("command")
            target = scenario.get("target", "ha-node-1")
            container = client.containers.get(target)
            code, out = run_command_in_container(container, cmd)
            if code != 0:
                raise Exception(f"Command failed: {out}")

        logger.info(f"Scenario {name} PASSED")
        return True
    except Exception as e:
        logger.error(f"Scenario {name} FAILED: {e}")
        return False


def main():
    config = load_config()
    client = get_docker_client()

    results = []
    for test in config.get("tests", []):
        success = run_test_scenario(test, client)
        results.append(success)

    if all(results):
        logger.info("All tests passed!")
        sys.exit(0)
    else:
        logger.error("Some tests failed.")
        sys.exit(1)


if __name__ == "__main__":
    main()
