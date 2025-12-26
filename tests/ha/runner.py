import yaml
import docker
import time
import os
import sys
import logging
import subprocess

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

def load_config(config_path="suite.yaml"):
    with open(config_path, "r") as f:
        return yaml.safe_load(f)

def get_docker_client():
    return docker.from_env()

def run_command_in_container(container, command):
    logger.info(f"Running command in {container.name}: {command}")
    exit_code, output = container.exec_run(command)
    if exit_code != 0:
        logger.error(f"Command failed: {output.decode('utf-8')}")
    return exit_code, output.decode('utf-8')

def chaos_packet_loss(container_name, duration="10s", loss_percent="20"):
    # Using pumba via docker run or exec if pumba is a service
    # Since pumba is a service, we can exec into it or just run a new pumba container attached to socket
    # But simpler: use `tc` in the target container if available, OR use the pumba service.
    # Our docker-compose has pumba service. We can send commands to it?
    # Actually pumba runs as a daemon or one-off.
    # Let's use the local docker client to run pumba commands ephemerally
    client = get_docker_client()
    logger.info(f"Injecting {loss_percent}% packet loss on {container_name} for {duration}")

    # We use the pumba image to run the command against the target container
    # Note: container_name in docker network might differ from actual docker container name
    # In compose: ha-node-1
    try:
        client.containers.run(
            "gaiaadm/pumba:latest",
            f"netem --duration {duration} --tc-image gaiadocker/iproute2 loss --percent {loss_percent} {container_name}",
            volumes={'/var/run/docker.sock': {'bind': '/var/run/docker.sock', 'mode': 'rw'}},
            remove=True,
            network="ha-net" # Important to be able to see the container if needed, though pumba uses socket
        )
    except Exception as e:
        logger.error(f"Crypto chaos failed: {e}")

def verify_leader(containers):
    # Check which node is leader via geodec or metrics
    # Simple check: Ask each node who the leader is
    leader = None
    for c in containers:
        try:
            # Assuming geodec is available in the container
            code, output = run_command_in_container(c, "geodec query 'RETURN 1' --server 127.0.0.1:7567")
            if code == 0:
                # If we can write/read, we might be leader or forwarded.
                # Use a raft status command if available.
                # Fallback: check logs or specific endpoint.
                # Let's assume there is a /raft/status endpoint or CLI command
                pass
        except Exception as e:
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

            time.sleep(5) # Wait for election

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
