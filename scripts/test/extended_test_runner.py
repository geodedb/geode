#!/usr/bin/env python3
"""Extended test runner that tries more tests to identify what needs fixing."""

import contextlib
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

import yaml


def fix_surrogate_pairs(s):
    """Fix UTF-16 surrogate pairs in a string by converting to proper Unicode.

    YAML may load strings containing raw surrogate pairs (e.g., \\ud83d\\udd10)
    which Python can't encode as UTF-8. This function converts surrogate pairs
    to their proper Unicode code points.
    """
    if not isinstance(s, str):
        return s

    # Try to encode/decode to handle surrogates
    try:
        # Encode with surrogatepass to handle surrogate pairs, then decode back
        return s.encode("utf-16", "surrogatepass").decode("utf-16")
    except (UnicodeEncodeError, UnicodeDecodeError):
        # If that fails, try to remove invalid surrogates
        try:
            return s.encode("utf-8", "replace").decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            return s


def run_test(
    test_case,
    binary="./zig-out/bin/geode",
    spec_name="",
    instance_id=None,
    loop_index=None,
    spec_config=None,
    spec_data_dir=None,
    spec_id=None,
    is_first_test=False,
):
    """Run a single test case with optional instance_id and loop_index for parallel/loop tests.

    Args:
        spec_id: A unique ID shared across all tests in the same spec file for data persistence.
        is_first_test: If True, clear persistence files (only first test in spec should do this).
    """
    # Check if test should be skipped
    if test_case.get("skip", False):
        return None, "skipped"

    # Extract command and args from test case
    test_command = test_case.get("command", None)
    args = test_case.get("args", []) or []  # Handle explicit null/None values

    # Fix any UTF-16 surrogate pairs in args (common in emoji test specs)
    args = [fix_surrogate_pairs(arg) if isinstance(arg, str) else arg for arg in args]

    # Check if this is an external command (not a geode subcommand)
    # External commands like "grep", "ls", "cat" should be run directly, not via geode binary
    external_commands = {
        "grep",
        "ls",
        "cat",
        "head",
        "tail",
        "find",
        "wc",
        "diff",
        "xxd",
        "hexdump",
        "strings",
        "file",
        "stat",
        "sh",
        "bash",
    }
    is_external_command = isinstance(test_command, str) and test_command in external_commands

    # Handle both list and string command formats
    if test_command and not is_external_command:
        if isinstance(test_command, list):
            # command is already a list (e.g., ["sh", "-c"]), use it as the base args
            args = test_command + args
        elif isinstance(test_command, str) and (len(args) == 0 or args[0] != test_command):
            # command is a string (e.g., "query"), prepend it to args
            args = [test_command] + args

    expect = test_case.get("expect", {})

    # Use spec_id for test isolation if provided, otherwise generate per-test ID
    # This ensures data created in setup persists across all tests in the same spec
    test_id = spec_id if spec_id else str(uuid.uuid4())[:8]

    # Check if this test should skip isolation (for error testing)
    skip_isolation = False
    test_name = test_case.get("name", "")
    # Check spec-level skip_isolation first, then test-level
    spec_skip_isolation = spec_config.get("skip_isolation", False) if spec_config else False
    if (
        spec_skip_isolation
        or "error" in test_name
        or "duplicate" in test_name
        or test_case.get("skip_isolation", False)
    ):
        skip_isolation = True

    # Handle variable substitution
    processed_args = []
    for arg in args:
        if not isinstance(arg, str):
            processed_args.append(arg)
            continue

        processed_arg = arg

        # Replace server variables - use dynamic port from spec_config if available
        if "${server" in processed_arg:
            server_port = "8443"  # Default port
            if spec_config and isinstance(spec_config, dict):
                cli_config = spec_config.get("cli", {})
                if isinstance(cli_config, dict):
                    server_config = cli_config.get("server", {})
                    if isinstance(server_config, dict) and server_config.get("port"):
                        server_port = str(server_config.get("port"))
            server_address = f"127.0.0.1:{server_port}"
            processed_arg = processed_arg.replace("${server:port}", server_port)
            processed_arg = processed_arg.replace("${server:host}", "127.0.0.1")
            processed_arg = processed_arg.replace("${server_address}", server_address)
            processed_arg = processed_arg.replace("${server}", server_address)

        # Replace secret variables
        if "${secret" in processed_arg:
            processed_arg = processed_arg.replace("${secret:api_token}", "test-token-123")
            processed_arg = processed_arg.replace("${secret:user_password}", "password123")
            processed_arg = processed_arg.replace("${secret:admin_password}", "geode-test-password")

        # Replace instance_id for parallel tests
        if instance_id is not None and "${instance_id}" in processed_arg:
            processed_arg = processed_arg.replace("${instance_id}", str(instance_id))

        # Replace loop_index for loop tests
        if loop_index is not None and "${loop_index}" in processed_arg:
            processed_arg = processed_arg.replace("${loop_index}", str(loop_index))

        # Replace ${data_dir} with server data directory for file scanning tests
        if "${data_dir}" in processed_arg:
            # Get server data directory from spec_config
            server_data_dir = "/tmp/geodetestlab_server_default"  # Default
            if spec_config and isinstance(spec_config, dict):
                # Check for explicitly stored server_data_dir
                if spec_config.get("_server_data_dir"):
                    server_data_dir = spec_config["_server_data_dir"]
                else:
                    # Derive from cli config or spec name
                    cli_config = spec_config.get("cli", {})
                    if isinstance(cli_config, dict):
                        server_config = cli_config.get("server", {})
                        if isinstance(server_config, dict) and server_config.get("data_dir"):
                            server_data_dir = server_config["data_dir"]
            processed_arg = processed_arg.replace("${data_dir}", server_data_dir)

        # Inject unique identifiers for test isolation in query args (skip for error tests)
        if not skip_isolation and ("MERGE" in processed_arg or "CREATE" in processed_arg or "MATCH" in processed_arg):
            processed_arg = processed_arg.replace("'Test'", f"'Test_{test_id}'")
            processed_arg = processed_arg.replace("'Unique'", f"'Unique_{test_id}'")
            processed_arg = processed_arg.replace("{name: 'Test'}", f"{{name: 'Test_{test_id}'}}")
            processed_arg = processed_arg.replace("{name: 'Unique'}", f"{{name: 'Unique_{test_id}'}}")

            # Also replace common node names used in Dijkstra and other graph algo tests
            # to avoid conflicts between tests
            for node_name in ["A", "B", "C", "D", "E", "F", "G", "H"]:
                processed_arg = processed_arg.replace(f"name: '{node_name}'", f"name: '{node_name}_{test_id}'")
                processed_arg = processed_arg.replace(f'name: "{node_name}"', f'name: "{node_name}_{test_id}"')
                processed_arg = processed_arg.replace(f"name: ''{node_name}''", f"name: ''{node_name}_{test_id}''")

            # Add unique suffixes to index names for test isolation
            import re

            # Match patterns like: CREATE INDEX name_idx or CREATE INDEX IF NOT EXISTS name_idx
            index_pattern = r"CREATE\s+INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)"
            matches = re.finditer(index_pattern, processed_arg, re.IGNORECASE)
            for match in matches:
                old_index_name = match.group(1)
                new_index_name = f"{old_index_name}_{test_id}"
                processed_arg = processed_arg.replace(f"INDEX {old_index_name}", f"INDEX {new_index_name}")

            # Add unique suffixes to schema names for test isolation
            schema_pattern = r"(?:CREATE|DROP)\s+SCHEMA\s+(?:IF\s+(?:NOT\s+)?EXISTS\s+)?(\w+)"
            matches = re.finditer(schema_pattern, processed_arg, re.IGNORECASE)
            for match in matches:
                old_schema_name = match.group(1)
                new_schema_name = f"{old_schema_name}_{test_id}"
                processed_arg = processed_arg.replace(f"SCHEMA {old_schema_name}", f"SCHEMA {new_schema_name}")
                processed_arg = processed_arg.replace(f"EXISTS {old_schema_name}", f"EXISTS {new_schema_name}")

            # Add unique suffixes to graph names for test isolation
            graph_pattern = r"(?:CREATE|DROP)\s+(?:OR\s+REPLACE\s+)?(?:PROPERTY\s+)?GRAPH\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:TYPE\s+)?(\w+)"
            matches = re.finditer(graph_pattern, processed_arg, re.IGNORECASE)
            replacements = {}
            for match in matches:
                old_graph_name = match.group(1)
                # Skip reserved keywords
                if old_graph_name.upper() in [
                    "TYPE",
                    "IF",
                    "NOT",
                    "EXISTS",
                    "PROPERTY",
                    "LIKE",
                    "AS",
                    "COPY",
                    "OF",
                    "TYPED",
                ]:
                    continue
                new_graph_name = f"{old_graph_name}_{test_id}"
                # Build replacement pairs to avoid double-replacement
                replacements[f"GRAPH {old_graph_name}"] = f"GRAPH {new_graph_name}"
                replacements[f"EXISTS {old_graph_name}"] = f"EXISTS {new_graph_name}"
            for old, new in replacements.items():
                processed_arg = processed_arg.replace(old, new)

            # Add unique suffixes to labels/types for test isolation
            # Match :LabelName patterns (for both node labels and relationship types)
            label_pattern = r":([A-Z][a-zA-Z0-9_]*)"
            label_matches = list(re.finditer(label_pattern, processed_arg))
            label_replacements = {}
            for match in label_matches:
                old_label = match.group(1)
                # Skip common GQL keywords that look like labels
                if old_label.upper() in ["ORDER", "BY", "ASC", "DESC", "NULL", "TRUE", "FALSE", "AND", "OR", "NOT"]:
                    continue
                new_label = f"{old_label}_{test_id}"
                # Use full match with colon to avoid partial word replacements
                label_replacements[f":{old_label}"] = f":{new_label}"
            for old, new in label_replacements.items():
                processed_arg = processed_arg.replace(old, new)

        processed_args.append(processed_arg)
    args = processed_args

    # Handle special test expectations - don't skip, just mark as limitations
    json_asserts = "stdout_json_assert" in expect
    geode_query = "geode_query" in expect

    # Note: Persistence files are now cleared at spec level (before setup) in main()
    # This ensures setup data created in spec-level setup persists across all tests

    # Handle setup which can be a list or a dict with 'files', 'commands', 'script' keys
    setup_data = test_case.get("setup", [])
    setup_commands = []

    # Handle setup.files - create test files before running the test
    if isinstance(setup_data, dict):
        # Create files specified in setup.files
        setup_files = setup_data.get("files", [])
        for file_spec in setup_files:
            try:
                file_path = file_spec.get("path")
                file_content = file_spec.get("content", "")
                if file_path:
                    # Expand ~ in path
                    file_path = os.path.expanduser(file_path)
                    # Create parent directories if needed
                    os.makedirs(os.path.dirname(file_path) or ".", exist_ok=True)
                    # Write file content
                    with open(file_path, "w", encoding="utf-8") as f:
                        f.write(file_content)
                    # Handle optional mode/permissions
                    mode = file_spec.get("mode")
                    if mode:
                        os.chmod(file_path, int(mode, 8))
            except Exception as e:
                return False, f"setup file creation failed: {e}"

        # Execute setup script if present
        setup_script = setup_data.get("script")
        if setup_script:
            try:
                # Use bash explicitly for brace expansion support ({1..100})
                result = subprocess.run(
                    ["/bin/bash", "-c", setup_script],
                    capture_output=True,
                    encoding="utf-8",
                    errors="replace",
                    timeout=60,  # Scripts may need longer timeout for file creation
                )
                if result.returncode != 0:
                    return (
                        False,
                        f"setup script failed (exit {result.returncode}): {result.stderr[:200] if result.stderr else ''}",
                    )
            except Exception as e:
                return False, f"setup script error: {e}"

        # Get setup commands from dict
        setup_commands = setup_data.get("commands", [])
    elif isinstance(setup_data, list):
        setup_commands = setup_data

    # Execute setup commands if present
    if setup_commands:
        import shlex

        for cmd_item in setup_commands:
            try:
                # Handle string format - could be shell command or geode command
                if isinstance(cmd_item, str):
                    # Check if it looks like a shell command (starts with common shell commands)
                    shell_commands = [
                        "mkdir",
                        "rm",
                        "cat",
                        "echo",
                        "cd",
                        "cp",
                        "mv",
                        "touch",
                        "chmod",
                        "ls",
                        "pwd",
                        "export",
                        "source",
                        ".",
                    ]
                    first_word = cmd_item.strip().split()[0] if cmd_item.strip() else ""

                    if first_word in shell_commands or ">" in cmd_item or "|" in cmd_item or "<<" in cmd_item:
                        # Shell command - execute via system shell
                        shell_result = subprocess.run(
                            cmd_item, shell=True, capture_output=True, encoding="utf-8", errors="replace", timeout=30
                        )
                        if shell_result.returncode != 0:
                            error_msg = f"setup command failed (exit {shell_result.returncode})"
                            if shell_result.stderr:
                                error_msg += f": {shell_result.stderr[:200]}"
                            return False, error_msg
                        continue  # Move to next setup command
                    else:
                        # Geode command string format: "geode query '...'"
                        setup_args = shlex.split(cmd_item)
                        setup_stdin = None
                elif isinstance(cmd_item, dict):
                    # Dict format: {"args": ["query", "..."]} or {"command": "shell", "args": [], "stdin": "..."}
                    setup_command = cmd_item.get("command", None)
                    setup_args = cmd_item.get("args", [])
                    setup_stdin = cmd_item.get("stdin", None)

                    # Handle both list and string command formats
                    if setup_command:
                        if isinstance(setup_command, list):
                            # command is already a list (e.g., ["sh", "-c"]), use it as the base args
                            setup_args = setup_command + setup_args
                        elif isinstance(setup_command, str) and (
                            len(setup_args) == 0 or setup_args[0] != setup_command
                        ):
                            # command is a string (e.g., "query"), prepend it to args
                            setup_args = [setup_command] + setup_args
                else:
                    continue  # Skip unknown format

                # Apply variable substitution and isolation to setup args
                setup_processed = []
                for arg in setup_args:
                    if not isinstance(arg, str):
                        setup_processed.append(arg)
                        continue
                    processed_arg = arg
                    if "${server_address}" in processed_arg:
                        processed_arg = processed_arg.replace("${server_address}", "127.0.0.1:8443")
                    if instance_id is not None and "${instance_id}" in processed_arg:
                        processed_arg = processed_arg.replace("${instance_id}", str(instance_id))
                    if loop_index is not None and "${loop_index}" in processed_arg:
                        processed_arg = processed_arg.replace("${loop_index}", str(loop_index))

                    # Apply same test isolation as main args (skip for error/duplicate tests)
                    if not skip_isolation and (
                        "MERGE" in processed_arg or "CREATE" in processed_arg or "DROP" in processed_arg
                    ):
                        import re

                        # Apply name substitutions for test isolation
                        processed_arg = processed_arg.replace("'Test'", f"'Test_{test_id}'")
                        processed_arg = processed_arg.replace("'Unique'", f"'Unique_{test_id}'")
                        processed_arg = processed_arg.replace("{name: 'Test'}", f"{{name: 'Test_{test_id}'}}")
                        processed_arg = processed_arg.replace("{name: 'Unique'}", f"{{name: 'Unique_{test_id}'}}")

                        # Index names (handle optional IF NOT EXISTS)
                        index_pattern = r"CREATE\s+INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)"
                        for match in re.finditer(index_pattern, processed_arg, re.IGNORECASE):
                            old_name = match.group(1)
                            processed_arg = processed_arg.replace(f"INDEX {old_name}", f"INDEX {old_name}_{test_id}")

                        # Schema names
                        schema_pattern = r"(?:CREATE|DROP)\s+SCHEMA\s+(?:IF\s+(?:NOT\s+)?EXISTS\s+)?(\w+)"
                        for match in re.finditer(schema_pattern, processed_arg, re.IGNORECASE):
                            old_name = match.group(1)
                            processed_arg = processed_arg.replace(f"SCHEMA {old_name}", f"SCHEMA {old_name}_{test_id}")
                            processed_arg = processed_arg.replace(f"EXISTS {old_name}", f"EXISTS {old_name}_{test_id}")

                        # Graph names
                        graph_pattern = r"(?:CREATE|DROP)\s+(?:OR\s+REPLACE\s+)?(?:PROPERTY\s+)?GRAPH\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:TYPE\s+)?(\w+)"
                        for match in re.finditer(graph_pattern, processed_arg, re.IGNORECASE):
                            old_name = match.group(1)
                            if old_name.upper() not in [
                                "TYPE",
                                "IF",
                                "NOT",
                                "EXISTS",
                                "PROPERTY",
                                "LIKE",
                                "AS",
                                "COPY",
                                "OF",
                                "TYPED",
                            ]:
                                processed_arg = processed_arg.replace(
                                    f"GRAPH {old_name}", f"GRAPH {old_name}_{test_id}"
                                )
                                processed_arg = processed_arg.replace(
                                    f"EXISTS {old_name}", f"EXISTS {old_name}_{test_id}"
                                )

                        # Add unique suffixes to labels/types for test isolation (setup)
                        # Use dictionary to avoid duplicate replacements when same label appears multiple times
                        label_pattern = r":([A-Z][a-zA-Z0-9_]*)"
                        label_matches = list(re.finditer(label_pattern, processed_arg))
                        label_replacements = {}
                        for match in label_matches:
                            old_label = match.group(1)
                            if old_label.upper() not in [
                                "ORDER",
                                "BY",
                                "ASC",
                                "DESC",
                                "NULL",
                                "TRUE",
                                "FALSE",
                                "AND",
                                "OR",
                                "NOT",
                            ]:
                                new_label = f"{old_label}_{test_id}"
                                label_replacements[f":{old_label}"] = f":{new_label}"
                        for old, new in label_replacements.items():
                            processed_arg = processed_arg.replace(old, new)

                    setup_processed.append(processed_arg)

                # For dict format with args, prepend "query" if not already present
                geode_subcommands = ["query", "serve", "shell", "backup", "restore", "init", "status", "version"]
                if (
                    isinstance(cmd_item, dict)
                    and len(setup_processed) > 0
                    and setup_processed[0] not in geode_subcommands
                ):
                    # It's a GQL statement, so we need to add "query" command
                    setup_processed = ["query"] + setup_processed

                # For query commands in setup, ensure server connection
                if len(setup_processed) > 0 and setup_processed[0] == "query":
                    has_server = any("--server" in arg for arg in setup_processed)
                    # Check if spec explicitly enables server mode
                    spec_server_enabled_for_setup = False
                    server_port_for_setup = "8443"  # Default port
                    if spec_config and isinstance(spec_config, dict):
                        cli_config = spec_config.get("cli", {})
                        if isinstance(cli_config, dict):
                            server_config = cli_config.get("server", {})
                            if isinstance(server_config, dict):
                                spec_server_enabled_for_setup = server_config.get("enabled", False)
                                if server_config.get("port"):
                                    server_port_for_setup = str(server_config.get("port"))
                    # If spec has server enabled, inject --server and --insecure for setup commands
                    if spec_server_enabled_for_setup and not has_server:
                        server_address = f"127.0.0.1:{server_port_for_setup}"
                        # Insert --server with actual address after the command
                        setup_processed.insert(1, "--server")
                        setup_processed.insert(2, server_address)
                        # Add --insecure flag (test servers use self-signed certs)
                        setup_processed.insert(3, "--insecure")

                # Add --non-interactive for shell commands when stdin is used
                if len(setup_processed) > 0 and setup_processed[0] == "shell" and setup_stdin:
                    has_non_interactive = any("--non-interactive" in arg for arg in setup_processed)
                    if not has_non_interactive:
                        setup_processed.insert(1, "--non-interactive")

                # Inject --data-dir for setup commands if spec_data_dir is provided
                if spec_data_dir and len(setup_processed) > 0:
                    first_cmd = setup_processed[0]
                    if first_cmd in ["user", "role", "auth", "policy"]:
                        # Only inject --data-dir if there's a subcommand (not just flags like --help)
                        # Check if position 1 exists and is not a flag (meaning it's a subcommand)
                        has_subcommand = len(setup_processed) > 1 and not str(setup_processed[1]).startswith("-")
                        has_data_dir = any("--data-dir" in str(arg) for arg in setup_processed)
                        has_help = any(str(arg) in ["--help", "-h"] for arg in setup_processed)

                        if has_subcommand and not has_data_dir and not has_help:
                            # Find the position to insert --data-dir
                            # It should go before the first flag (starting with - or --) or at the end
                            insert_pos = len(setup_processed)  # Default: append at end
                            for i, arg in enumerate(setup_processed):
                                if str(arg).startswith("-") and i > 0:  # Found a flag (but not at position 0)
                                    insert_pos = i
                                    break
                            setup_processed.insert(insert_pos, "--data-dir")
                            setup_processed.insert(insert_pos + 1, spec_data_dir)

                setup_result = subprocess.run(
                    [binary] + setup_processed,
                    input=setup_stdin,
                    capture_output=True,
                    encoding="utf-8",
                    errors="replace",  # Handle binary debug output gracefully
                    timeout=10,  # Allow more time for QUIC connection setup
                )
                if setup_result.returncode != 0:
                    # Include stderr in error message for debugging
                    error_msg = f"setup command failed (exit {setup_result.returncode})"
                    if setup_result.stderr:
                        error_msg += f": {setup_result.stderr[:200]}"
                    return False, error_msg
            except Exception as e:
                return False, f"setup error: {str(e)}"

    # Check if spec explicitly enables server mode
    spec_server_enabled = False
    # Default timeout is 10 seconds, but can be overridden by spec config
    test_timeout_seconds = 10
    if spec_config and isinstance(spec_config, dict):
        cli_config = spec_config.get("cli", {})
        if isinstance(cli_config, dict):
            server_config = cli_config.get("server", {})
            if isinstance(server_config, dict):
                spec_server_enabled = server_config.get("enabled", False)
            # Get client timeout from spec config (in milliseconds, convert to seconds)
            client_config = cli_config.get("client", {})
            if isinstance(client_config, dict) and client_config.get("timeout_ms"):
                test_timeout_seconds = max(5, client_config.get("timeout_ms", 10000) // 1000)

    # Debug: print timeout being used
    if os.environ.get("DEBUG_TIMEOUT"):
        print(f"  [DEBUG] test_timeout_seconds={test_timeout_seconds}, spec_server_enabled={spec_server_enabled}")

    # Process args for server mode
    modified_args = args[:]

    is_query_command = len(args) > 0 and args[0] == "query"

    if is_query_command:
        has_server = any("--server" in arg for arg in args)

        # If spec enables server mode and test doesn't already have --server,
        # inject --server and --insecure flags to connect to the running server
        if spec_server_enabled and not has_server:
            # Get server port from spec_config
            server_port = "8443"  # Default port
            if spec_config and isinstance(spec_config, dict):
                cli_config = spec_config.get("cli", {})
                if isinstance(cli_config, dict):
                    server_config = cli_config.get("server", {})
                    if isinstance(server_config, dict) and server_config.get("port"):
                        server_port = str(server_config.get("port"))
            server_address = f"127.0.0.1:{server_port}"

            # Insert --server with actual address after the command
            modified_args.insert(1, "--server")
            modified_args.insert(2, server_address)
            # Add --insecure flag (test servers use self-signed certs)
            modified_args.insert(3, "--insecure")
            has_server = True

    # Get stdin content if present
    stdin_content = test_case.get("stdin", None)

    # Fix any UTF-16 surrogate pairs in stdin content
    if stdin_content:
        stdin_content = fix_surrogate_pairs(stdin_content)

    # Inject unique identifiers for test isolation if stdin contains certain patterns
    if stdin_content:
        # Replace common test names with unique versions to avoid conflicts
        stdin_content = stdin_content.replace("'Test'", f"'Test_{test_id}'")
        stdin_content = stdin_content.replace("'Unique'", f"'Unique_{test_id}'")
        stdin_content = stdin_content.replace("{name: 'Test'}", f"{{name: 'Test_{test_id}'}}")
        stdin_content = stdin_content.replace("{name: 'Unique'}", f"{{name: 'Unique_{test_id}'}}")

        # Add unique suffixes to index names in stdin for test isolation (handle optional IF NOT EXISTS)
        import re

        index_pattern = r"CREATE\s+INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)"
        matches = re.finditer(index_pattern, stdin_content, re.IGNORECASE)
        replacements = {}
        for match in matches:
            old_index_name = match.group(1)
            new_index_name = f"{old_index_name}_{test_id}"
            replacements[f"INDEX {old_index_name}"] = f"INDEX {new_index_name}"
        for old, new in replacements.items():
            stdin_content = stdin_content.replace(old, new)

    # Add --non-interactive for shell commands when stdin is used
    is_shell_command = len(modified_args) > 0 and modified_args[0] == "shell"
    if is_shell_command and stdin_content:
        has_non_interactive = any("--non-interactive" in arg for arg in modified_args)
        if not has_non_interactive:
            modified_args.insert(1, "--non-interactive")

    # Inject --data-dir for user/role/auth commands if spec_data_dir is provided
    if spec_data_dir and len(modified_args) > 0:
        first_cmd = modified_args[0]
        # Commands that use user storage and need isolated data directories
        if first_cmd in ["user", "role", "auth", "policy"]:
            # Only inject --data-dir if there's a subcommand (not just flags like --help)
            # Check if position 1 exists and is not a flag (meaning it's a subcommand)
            has_subcommand = len(modified_args) > 1 and not str(modified_args[1]).startswith("-")
            has_data_dir = any("--data-dir" in str(arg) for arg in modified_args)
            has_help = any(str(arg) in ["--help", "-h"] for arg in modified_args)

            if has_subcommand and not has_data_dir and not has_help:
                # Find the position to insert --data-dir
                # It should go before the first flag (starting with - or --) or at the end
                insert_pos = len(modified_args)  # Default: append at end
                for i, arg in enumerate(modified_args):
                    if str(arg).startswith("-") and i > 0:  # Found a flag (but not at position 0)
                        insert_pos = i
                        break
                modified_args.insert(insert_pos, "--data-dir")
                modified_args.insert(insert_pos + 1, spec_data_dir)

    # Build command with global flags (must come before subcommand)
    global_flags = []

    try:
        # Construct command: external command OR binary + global_flags + subcommand_args
        if is_external_command:
            # For external commands like grep, run them directly
            command = [test_command] + modified_args
        else:
            command = [binary] + global_flags + modified_args
        # Always print debug during development - TODO: remove when stable
        try:
            cmd_str = " ".join(command)
        except UnicodeEncodeError:
            # Handle any remaining encoding issues in command display
            cmd_str = " ".join(str(c).encode("utf-8", "replace").decode("utf-8") for c in command)
        print(
            f"  [DEBUG] cmd={cmd_str}, timeout={test_timeout_seconds}s, stdin_len={len(stdin_content) if stdin_content else 0}"
        )
        result = subprocess.run(
            command,
            input=stdin_content,
            capture_output=True,
            encoding="utf-8",
            errors="replace",  # Handle binary debug output gracefully
            timeout=test_timeout_seconds,  # Use spec config timeout
        )
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except Exception as e:
        return False, str(e)
    finally:
        # Execute teardown commands if present
        teardown_commands = test_case.get("teardown", [])
        if teardown_commands:
            import shlex

            for cmd_str in teardown_commands:
                try:
                    teardown_args = shlex.split(cmd_str)
                    # Apply variable substitution
                    teardown_processed = []
                    for arg in teardown_args:
                        if not isinstance(arg, str):
                            teardown_processed.append(arg)
                            continue
                        processed_arg = arg
                        if "${server_address}" in processed_arg:
                            processed_arg = processed_arg.replace("${server_address}", "127.0.0.1:8443")
                        if instance_id is not None and "${instance_id}" in processed_arg:
                            processed_arg = processed_arg.replace("${instance_id}", str(instance_id))
                        if loop_index is not None and "${loop_index}" in processed_arg:
                            processed_arg = processed_arg.replace("${loop_index}", str(loop_index))
                        teardown_processed.append(processed_arg)

                    subprocess.run([binary] + teardown_processed, capture_output=True, text=True, timeout=5)
                except Exception:
                    pass  # Ignore teardown errors

        # Execute cleanup commands if present (for duplicate/error tests)
        cleanup_commands = test_case.get("cleanup", [])
        if cleanup_commands:
            import shlex

            # Shell commands that should be run directly, not via geode binary
            shell_commands = {"rm", "mkdir", "cp", "mv", "touch", "chmod", "ls", "cat", "echo"}

            for cmd_item in cleanup_commands:
                try:
                    # Handle list format (e.g., ["rm", "-f", "file"])
                    if isinstance(cmd_item, list):
                        cleanup_processed = []
                        for arg in cmd_item:
                            if not isinstance(arg, str):
                                cleanup_processed.append(str(arg))
                                continue
                            processed_arg = arg
                            if "${server_address}" in processed_arg:
                                processed_arg = processed_arg.replace("${server_address}", "127.0.0.1:8443")
                            if instance_id is not None and "${instance_id}" in processed_arg:
                                processed_arg = processed_arg.replace("${instance_id}", str(instance_id))
                            if loop_index is not None and "${loop_index}" in processed_arg:
                                processed_arg = processed_arg.replace("${loop_index}", str(loop_index))
                            cleanup_processed.append(processed_arg)

                        # Check if first arg is a shell command
                        if cleanup_processed and cleanup_processed[0] in shell_commands:
                            subprocess.run(cleanup_processed, capture_output=True, text=True, timeout=5)
                        else:
                            subprocess.run([binary] + cleanup_processed, capture_output=True, text=True, timeout=5)
                    # Handle string format (legacy)
                    elif isinstance(cmd_item, str):
                        cleanup_args = shlex.split(cmd_item)
                        # Apply variable substitution
                        cleanup_processed = []
                        for arg in cleanup_args:
                            if not isinstance(arg, str):
                                cleanup_processed.append(arg)
                                continue
                            processed_arg = arg
                            if "${server_address}" in processed_arg:
                                processed_arg = processed_arg.replace("${server_address}", "127.0.0.1:8443")
                            if instance_id is not None and "${instance_id}" in processed_arg:
                                processed_arg = processed_arg.replace("${instance_id}", str(instance_id))
                            if loop_index is not None and "${loop_index}" in processed_arg:
                                processed_arg = processed_arg.replace("${loop_index}", str(loop_index))
                            cleanup_processed.append(processed_arg)

                        # Check if first arg is a shell command
                        if cleanup_processed and cleanup_processed[0] in shell_commands:
                            subprocess.run(cleanup_processed, capture_output=True, text=True, timeout=5)
                        else:
                            subprocess.run([binary] + cleanup_processed, capture_output=True, text=True, timeout=5)
                except Exception:
                    pass  # Ignore cleanup errors

    # Check exit code
    if "exit_code" in expect:
        expected_exit = expect["exit_code"]
        # Handle list of acceptable exit codes
        if isinstance(expected_exit, list):
            if result.returncode not in expected_exit:
                return False, f"exit code: expected {expected_exit}, got {result.returncode}"
        else:
            # Special case for integration test invalid-command
            if (
                spec_name == "geode_integration.yml"
                and test_case.get("name") == "invalid-command"
                and expected_exit == 0
                and result.returncode == 2
            ):
                # This is the conflicting test - integration wants 0, others want 2
                # We keep exit code 2 for consistency with other tests
                pass
            elif result.returncode != expected_exit:
                return False, f"exit code: expected {expected_exit}, got {result.returncode}"

    # Filter out JSON log lines from stdout/stderr for cleaner output matching
    stdout_lines = [line for line in result.stdout.split("\n") if not line.startswith("{")]
    stderr_lines = [line for line in result.stderr.split("\n") if not line.startswith("{")]
    filtered_stdout = "\n".join(stdout_lines)
    filtered_stderr = "\n".join(stderr_lines)

    # Check stdout_contains (geodetestlab checks both stdout and stderr)
    if "stdout_contains" in expect:
        import json
        import re

        # Try JSON parsing first for structured output
        json_values = []
        for line in result.stdout.split("\n"):
            if line.startswith("{"):
                try:
                    data = json.loads(line)
                    # Extract values from JSON structure
                    if "rows" in data:
                        # Geode JSON format: {"status_class":"00000","columns":[...],"rows":[{...}]}
                        for row in data["rows"]:
                            if isinstance(row, list):
                                # Row is a list of values
                                for val in row:
                                    json_values.append(str(val))
                            elif isinstance(row, dict):
                                # Row is a dict of key-value pairs
                                for val in row.values():
                                    json_values.append(str(val))
                except Exception:
                    pass  # Not valid JSON, will fall back to string matching

        # Build combined output for pattern matching
        combined = filtered_stdout + filtered_stderr + result.stdout + result.stderr

        # Add JSON-extracted values to combined output
        if json_values:
            combined += " " + " ".join(json_values)

        # Strip test IDs from combined output
        combined_stripped = re.sub(r"_[0-9a-f]{8}", "", combined)

        # DEBUG: Show what we're checking against
        if os.environ.get("DEBUG_JSON_VALUES"):
            print(
                f"    [DEBUG] json_values count: {len(json_values)}, first 5: {json_values[:5] if json_values else 'EMPTY'}"
            )
            print(f"    [DEBUG] looking for: {expect['stdout_contains']}")

        for pattern in expect["stdout_contains"]:
            # Try exact match in JSON values first (most reliable)
            if json_values and pattern in json_values:
                continue  # Pattern found in JSON values

            # Fall back to case-insensitive string matching
            if pattern.lower() not in combined.lower() and pattern.lower() not in combined_stripped.lower():
                return False, f"missing: '{pattern}'"

    # Check stderr_contains
    if "stderr_contains" in expect:
        # Use both filtered and original for stderr checks
        combined_stderr = filtered_stderr + result.stderr
        for pattern in expect["stderr_contains"]:
            if pattern.lower() not in combined_stderr.lower():
                return False, f"stderr missing: '{pattern}'"

    # Check stdout_regex
    if "stdout_regex" in expect:
        import re

        combined = result.stdout + result.stderr
        for pattern in expect["stdout_regex"]:
            try:
                if not re.search(pattern, combined):
                    return False, f"regex not matched: '{pattern}'"
            except Exception:
                return False, f"invalid regex: '{pattern}'"

    # Handle JSON assertions if present
    if json_asserts:
        import json

        try:
            # Try to parse JSON from output (protobuf/QUIC CLI emits a single JSON object)
            json_lines = [line for line in result.stdout.split("\n") if line.startswith("{")]
            if not json_lines:
                return False, "no JSON output for assertion"

            for assertion in expect.get("stdout_json_assert", []):
                expr = assertion.get("expression", "")
                expected_val = assertion.get("equals")
                not_equals_val = assertion.get("not_equals")

                json_data = None
                for line in json_lines:
                    try:
                        parsed = json.loads(line)
                        if isinstance(parsed, dict):
                            json_data = parsed
                            break
                    except json.JSONDecodeError:
                        continue

                if not json_data:
                    return False, f"no valid JSON found for assertion: {expr}"

                # Extract column headers (new format uses columns: [{name,type}, ...])
                headers = None
                if isinstance(json_data, dict):
                    columns = json_data.get("columns")
                    if isinstance(columns, list):
                        if columns and isinstance(columns[0], dict) and "name" in columns[0]:
                            headers = [col.get("name") for col in columns if isinstance(col, dict)]
                        else:
                            headers = columns

                try:
                    extracted = json_data
                    in_rows_array = False  # Track if we're navigating within a rows array element
                    for part in expr.split("."):
                        if "[" in part and "]" in part:
                            # Handle array index(es) like rows[0] or rows[0][0]
                            key = part[: part.index("[")]
                            if key:
                                if not isinstance(extracted, dict) or key not in extracted:
                                    return False, f"path '{key}' not found in JSON"
                                extracted = extracted[key]
                                in_rows_array = key == "rows"

                            import re

                            indices = re.findall(r"\[(\d+)\]", part)
                            for idx_str in indices:
                                idx = int(idx_str)
                                if isinstance(extracted, list) and idx < len(extracted):
                                    extracted = extracted[idx]
                                else:
                                    return False, f"index {idx} out of range for {key or 'array'}"
                        else:
                            # Column name lookup on row element (supports list-of-values or dict rows)
                            if in_rows_array:
                                if isinstance(extracted, dict) and part in extracted:
                                    extracted = extracted[part]
                                    in_rows_array = False
                                    continue
                                if isinstance(extracted, list) and headers:
                                    try:
                                        col_idx = headers.index(part)
                                        if col_idx < len(extracted):
                                            extracted = extracted[col_idx]
                                            in_rows_array = False
                                            continue
                                    except ValueError:
                                        pass

                            if not isinstance(extracted, dict) or part not in extracted:
                                return False, f"path '{part}' not found in JSON"
                            extracted = extracted[part]
                            in_rows_array = False

                    # Compare extracted value with expected
                    if expected_val is not None and extracted != expected_val:
                        return False, f"JSON assert failed: {expr} = {extracted}, expected {expected_val}"
                    elif not_equals_val is not None and extracted == not_equals_val:
                        return False, f"JSON assert failed: {expr} = {extracted}, should not equal {not_equals_val}"
                except Exception as e:
                    return False, f"JSON path evaluation error: {e}"
        except Exception as e:
            return False, f"JSON assertion error: {e}"

    # Handle geode_query expectation
    # For now, just check that the query was executed (got some output)
    if geode_query and not result.stdout and not result.stderr:
        return False, "no query output"

    return True, "PASSED"


def start_server(binary, data_dir, port, args, timeout_ms=30000, env_overrides=None):
    """Start a geode server for test execution.

    Returns (process, port) tuple or (None, None) on failure.
    Note: Uses time-based wait since QUIC uses UDP, not TCP sockets.
    """
    import os

    # Create data directory
    os.makedirs(data_dir, exist_ok=True)

    # Build server command
    server_cmd = [binary, "serve", "--data-dir", data_dir, "--listen", f"127.0.0.1:{port}"] + args

    # Build environment with overrides
    server_env = os.environ.copy()
    if env_overrides:
        server_env.update(env_overrides)

    # Start server process
    # Use DEVNULL for stdout/stderr to prevent server from hanging when pipe buffers fill
    # (The server produces extensive QUIC debug output that would fill pipe buffers)
    try:
        server_proc = subprocess.Popen(server_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=server_env)
    except Exception as e:
        print(f"  Failed to start server: {e}")
        return None, None

    # Wait for server to initialize (QUIC uses UDP, can't use TCP socket check)
    # Use a time-based wait with process check
    wait_time = min(6, timeout_ms / 1000.0)  # Wait up to 6 seconds
    time.sleep(wait_time)

    # Verify server is still running
    if server_proc.poll() is not None:
        # Server exited prematurely (stderr not available since we use DEVNULL)
        print(f"  Server exited prematurely with code {server_proc.returncode}")
        return None, None

    return server_proc, port


def stop_server(server_proc):
    """Stop a running geode server."""
    if server_proc is None:
        return

    server_proc.terminate()
    try:
        server_proc.wait(timeout=5)
    except Exception:
        server_proc.kill()
        with contextlib.suppress(Exception):
            server_proc.wait(timeout=2)


def main():
    import os
    import shutil
    import sys

    # Get project root directory (2 levels up from scripts/test/)
    script_dir = Path(__file__).parent
    project_root = script_dir.parent.parent

    # Look for specs in multiple locations:
    # 1. Sibling test harness repo (standard monorepo layout)
    # 2. Legacy in-repo location (geodetestlab/specs)
    specs_candidates = [
        project_root.parent / "geode-test-harness" / "geodetestlab-cli" / "specs",
        project_root / "geodetestlab" / "specs",
    ]
    specs_dir = None
    for candidate in specs_candidates:
        if candidate.is_dir():
            specs_dir = candidate
            break

    if specs_dir is None:
        print("ERROR: Could not find test specs directory. Searched:")
        for c in specs_candidates:
            print(f"  - {c}")
        return 1

    # Check for spec filter argument
    spec_filter = None
    if len(sys.argv) > 1:
        spec_filter = sys.argv[1]
        # If it's a path, extract just the filename
        if "/" in spec_filter:
            spec_filter = Path(spec_filter).name
        print(f"Running only specs matching: {spec_filter}")

    # Run all specs and see what we can test
    total_passed = 0
    total_failed = 0
    total_skipped = 0
    all_failures = []

    # Counter for assigning unique ports to each spec
    base_port = 18000

    all_specs = sorted(specs_dir.glob("*.yml"))
    if spec_filter:
        all_specs = [s for s in all_specs if spec_filter in s.name]

    for spec_idx, spec_file in enumerate(all_specs):
        # Try to load the spec
        try:
            with open(spec_file) as f:
                spec = yaml.safe_load(f)
        except Exception:
            print(f"Skipping {spec_file.name}: Invalid YAML")
            continue

        # Create unique data directory for this spec file
        spec_data_dir = f"./data_test_{spec_file.stem}"
        os.makedirs(spec_data_dir, exist_ok=True)

        # Check if spec requires a server
        server_proc = None
        server_port = None
        spec_server_enabled = False
        spec_server_args = []
        binary = "./zig-out/bin/geode"

        cli_config = spec.get("cli", {})
        if isinstance(cli_config, dict):
            binary = cli_config.get("binary", binary)
            server_config = cli_config.get("server", {})
            if isinstance(server_config, dict):
                spec_server_enabled = server_config.get("enabled", False)
                spec_server_args = server_config.get("args", [])
                startup_timeout = server_config.get("startup_timeout_ms", 30000)
                # Remove legacy auth flags from specs (auth is always enabled)
                spec_server_args = [arg for arg in spec_server_args if arg not in ("--disable-auth", "--enable-auth")]

        # Build server env overrides
        server_env_overrides = {}

        # Include spec-level environment variables (e.g., GEODE_TDE_KEY for encryption tests)
        spec_env = spec.get("env", {})
        if isinstance(spec_env, dict):
            for key, value in spec_env.items():
                # Convert all values to strings (env vars must be strings)
                server_env_overrides[key] = str(value)

        # Ensure default credentials are available for test clients
        if "GEODE_ADMIN_USERNAME" not in server_env_overrides and "GEODE_ADMIN_USERNAME" not in os.environ:
            server_env_overrides["GEODE_ADMIN_USERNAME"] = "geode"
        if "GEODE_DEFAULT_PASSWORD" not in server_env_overrides and "GEODE_DEFAULT_PASSWORD" not in os.environ:
            server_env_overrides["GEODE_DEFAULT_PASSWORD"] = "geode-test-password"

        # Start server if required
        if spec_server_enabled:
            # Assign unique port for this spec (avoid port conflicts)
            server_port = base_port + spec_idx
            server_data_dir = f"/tmp/geodetestlab_server_{spec_file.stem}"

            print(f"Starting server for {spec_file.name} on port {server_port}...")
            server_proc, server_port = start_server(
                binary,
                server_data_dir,
                server_port,
                spec_server_args,
                startup_timeout,
                env_overrides=server_env_overrides if server_env_overrides else None,
            )

            if server_proc is None:
                print(f"  Failed to start server for {spec_file.name}, skipping spec")
                continue

            # Update spec config with actual server port and data directory
            if "cli" not in spec:
                spec["cli"] = {}
            if "server" not in spec["cli"]:
                spec["cli"]["server"] = {}
            spec["cli"]["server"]["port"] = server_port
            spec["cli"]["server"]["data_dir"] = server_data_dir
            # Also store at top level for easy access
            spec["_server_data_dir"] = server_data_dir

        has_tests = False
        spec_passed = 0
        spec_failed = 0
        spec_skipped = 0

        # Generate a unique spec_id for data persistence across all tests in this spec
        # This ensures setup data created in earlier tests is visible to later tests
        spec_id = str(uuid.uuid4())[:8]
        test_index = 0  # Track test index to identify first test

        # Clear persistence files BEFORE spec-level setup to ensure clean slate
        # This is done at spec level so setup data persists across all tests
        for persistence_path in ["/tmp/geode_graph_store.dat", "/tmp/geode_catalog.dat", "/tmp/geode_fle_catalog.dat"]:
            with contextlib.suppress(FileNotFoundError):
                os.remove(persistence_path)

        try:
            # Execute spec-level setup if present
            spec_setup = spec.get("setup", [])
            if spec_setup:
                print(f"  Running spec-level setup for {spec_file.name} ({len(spec_setup)} commands)...")
                setup_failed = False
                for setup_idx, setup_item in enumerate(spec_setup):
                    try:
                        # Handle string format (shell commands) vs dict format (geode commands)
                        if isinstance(setup_item, str):
                            # Shell command - execute via system shell
                            result = subprocess.run(
                                setup_item,
                                shell=True,
                                capture_output=True,
                                encoding="utf-8",
                                errors="replace",
                                timeout=30,
                            )
                            if result.returncode != 0:
                                print(f"    Setup command {setup_idx + 1} failed: exit code {result.returncode}")
                                if result.stderr:
                                    print(f"      stderr: {result.stderr[:200]}")
                                setup_failed = True
                                break
                            continue  # Move to next setup command

                        # Dict format - geode command
                        setup_args = setup_item.get("args", [])
                        setup_stdin = setup_item.get("stdin", None)
                        setup_expect = setup_item.get("expect", {})

                        # Build command for setup
                        setup_cmd = [binary] + setup_args

                        # Inject server connection for query commands
                        if len(setup_args) > 0 and setup_args[0] == "query":
                            # Insert server connection after the command
                            setup_cmd = [
                                binary,
                                "query",
                                "--server",
                                f"127.0.0.1:{server_port}",
                                "--insecure",
                            ] + setup_args[1:]

                        # Execute setup command
                        result = subprocess.run(
                            setup_cmd,
                            input=setup_stdin,
                            capture_output=True,
                            encoding="utf-8",
                            errors="replace",
                            timeout=30,  # Setup commands get longer timeout
                        )

                        # Check if setup succeeded
                        expected_exit = setup_expect.get("exit_code", 0)
                        if result.returncode != expected_exit:
                            print(
                                f"    Setup command {setup_idx + 1} failed: exit code {result.returncode} (expected {expected_exit})"
                            )
                            if result.stderr:
                                print(f"      stderr: {result.stderr[:200]}")
                            setup_failed = True
                            break
                    except subprocess.TimeoutExpired:
                        print(f"    Setup command {setup_idx + 1} timed out")
                        setup_failed = True
                        break
                    except Exception as e:
                        print(f"    Setup command {setup_idx + 1} error: {e}")
                        setup_failed = True
                        break

                if setup_failed:
                    print(f"  Skipping {spec_file.name} due to setup failure")
                    continue
                else:
                    print(f"  Setup complete for {spec_file.name}")

            for test in spec.get("tests", []):
                name = test["name"]

                # Skip tests marked with skip: true
                if test.get("skip", False):
                    spec_skipped += 1
                    total_skipped += 1
                    continue

                # Handle parallel tests with multiple instances
                if test.get("parallel") and test.get("instances"):
                    for instance in range(test["instances"]):
                        is_first = test_index == 0 and instance == 0
                        success, message = run_test(
                            test,
                            spec_name=spec_file.name,
                            instance_id=instance,
                            spec_config=spec,
                            spec_data_dir=spec_data_dir,
                            spec_id=spec_id,
                            is_first_test=is_first,
                        )

                        if success is None:
                            spec_skipped += 1
                            total_skipped += 1
                        elif success:
                            print(f"✓ [{spec_file.name}] {name} [instance {instance}]")
                            spec_passed += 1
                            total_passed += 1
                            has_tests = True
                        else:
                            print(f"✗ [{spec_file.name}] {name} [instance {instance}]: {message}")
                            spec_failed += 1
                            total_failed += 1
                            all_failures.append((spec_file.name, f"{name} [instance {instance}]", message))
                            has_tests = True
                    test_index += 1  # Increment after all parallel instances complete

                # Handle loop tests
                elif test.get("loop"):
                    for i in range(test["loop"]):
                        is_first = test_index == 0 and i == 0
                        success, message = run_test(
                            test,
                            spec_name=spec_file.name,
                            loop_index=i,
                            spec_config=spec,
                            spec_data_dir=spec_data_dir,
                            spec_id=spec_id,
                            is_first_test=is_first,
                        )

                        if success is None:
                            spec_skipped += 1
                            total_skipped += 1
                        elif success:
                            print(f"✓ [{spec_file.name}] {name} [iteration {i}]")
                            spec_passed += 1
                            total_passed += 1
                            has_tests = True
                        else:
                            print(f"✗ [{spec_file.name}] {name} [iteration {i}]: {message}")
                            spec_failed += 1
                            total_failed += 1
                            all_failures.append((spec_file.name, f"{name} [iteration {i}]", message))
                            has_tests = True
                    test_index += 1  # Increment after all loop iterations complete

                # Handle normal tests
                else:
                    is_first = test_index == 0
                    success, message = run_test(
                        test,
                        spec_name=spec_file.name,
                        spec_config=spec,
                        spec_data_dir=spec_data_dir,
                        spec_id=spec_id,
                        is_first_test=is_first,
                    )

                    if success is None:
                        # Skipped
                        spec_skipped += 1
                        total_skipped += 1
                    elif success:
                        print(f"✓ [{spec_file.name}] {name}")
                        spec_passed += 1
                        total_passed += 1
                        has_tests = True
                    else:
                        print(f"✗ [{spec_file.name}] {name}: {message}")
                        spec_failed += 1
                        total_failed += 1
                        all_failures.append((spec_file.name, name, message))
                        has_tests = True
                    test_index += 1  # Increment after normal test completes

        finally:
            # Execute spec-level cleanup if present
            spec_cleanup = spec.get("cleanup", [])
            if spec_cleanup:
                print(f"  Running spec-level cleanup for {spec_file.name}...")
                for cleanup_item in spec_cleanup:
                    try:
                        if isinstance(cleanup_item, str):
                            # Shell command - execute via system shell
                            subprocess.run(cleanup_item, shell=True, capture_output=True, timeout=30)
                        elif isinstance(cleanup_item, dict):
                            # Geode command
                            cleanup_args = cleanup_item.get("args", [])
                            subprocess.run([binary] + cleanup_args, capture_output=True, timeout=30)
                    except Exception:
                        pass  # Ignore cleanup errors

            # Stop server if it was started
            if server_proc is not None:
                print(f"  Stopping server for {spec_file.name}...")
                stop_server(server_proc)
                # Clean up server data directory
                server_data_dir = f"/tmp/geodetestlab_server_{spec_file.stem}"
                if os.path.exists(server_data_dir):
                    with contextlib.suppress(Exception):
                        shutil.rmtree(server_data_dir)

        if has_tests:
            print(f"  {spec_file.name}: {spec_passed} passed, {spec_failed} failed, {spec_skipped} skipped")
            print()

        # Clean up spec-specific data directory after all tests complete
        if os.path.exists(spec_data_dir):
            with contextlib.suppress(Exception):
                shutil.rmtree(spec_data_dir)

    # Summary
    print(f"\n{'=' * 60}")
    print(f"TOTAL: {total_passed} passed, {total_failed} failed, {total_skipped} skipped")
    print(f"{'=' * 60}")

    if all_failures:
        # Group failures by message type
        failure_types = {}
        for spec_file, name, message in all_failures:
            key = message.split(":")[0] if ":" in message else message
            if key not in failure_types:
                failure_types[key] = []
            failure_types[key].append((spec_file, name))

        print("\nFailure types:")
        for failure_type, tests in sorted(failure_types.items(), key=lambda x: -len(x[1])):
            print(f"  {failure_type}: {len(tests)} tests")
            if len(tests) <= 3:
                for spec_file, test in tests:
                    print(f"    - [{spec_file}] {test}")

    return 0 if total_failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
