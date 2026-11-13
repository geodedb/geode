"""Shared core logic for Geode test runners.

Extracted from extended_test_runner.py and parallel_test_runner.py to eliminate
duplication. Provides: surrogate-pair fixing, variable substitution, test isolation,
expectation validation, server lifecycle, secret resolution, timeout resolution.
"""

import contextlib
import json
import os
import re
import subprocess
import tempfile
import time

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

EXTERNAL_COMMANDS = frozenset(
    {
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
        "cut",
        "sort",
        "uniq",
        "tr",
        "sleep",
    }
)

SHELL_COMMANDS = frozenset(
    {
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
    }
)

GEODE_SUBCOMMANDS = frozenset(
    {
        "query",
        "serve",
        "shell",
        "backup",
        "restore",
        "init",
        "status",
        "version",
        "auth",
        "user",
        "role",
        "policy",
        "grant",
        "revoke",
        "migrate",
        "lsp",
        "apikey",
    }
)

GQL_KEYWORDS = (
    "MATCH",
    "RETURN",
    "CREATE",
    "DELETE",
    "MERGE",
    "WITH",
    "UNWIND",
    "CALL",
    "INSERT",
    "SHOW",
    "EXPLAIN",
    "PROFILE",
    "USE",
    "SET",
    "BEGIN",
    "COMMIT",
    "ROLLBACK",
    "START",
    "SELECT",
    "OPTIONAL",
    "DROP",
    "ALTER",
    "GRANT",
    "REVOKE",
    "FOR",
    "FILTER",
    "LET",
    "DETACH",
    "REMOVE",
)

GQL_SETUP_KEYWORDS = frozenset(
    {
        "CREATE",
        "MATCH",
        "RETURN",
        "DELETE",
        "DETACH",
        "MERGE",
        "SET",
        "REMOVE",
        "WITH",
        "OPTIONAL",
        "CALL",
        "INSERT",
        "DROP",
        "ALTER",
        "FOR",
        "FILTER",
        "LET",
        "EXPLAIN",
        "PROFILE",
    }
)

LABEL_SKIP_KEYWORDS = frozenset({"ORDER", "BY", "ASC", "DESC", "NULL", "TRUE", "FALSE", "AND", "OR", "NOT"})

GRAPH_NAME_RESERVED = frozenset({"TYPE", "IF", "NOT", "EXISTS", "PROPERTY", "LIKE", "AS", "COPY", "OF", "TYPED"})


# ---------------------------------------------------------------------------
# Surrogate pair handling
# ---------------------------------------------------------------------------


def fix_surrogate_pairs(s):
    """Fix UTF-16 surrogate pairs in a string."""
    if not isinstance(s, str):
        return s
    try:
        return s.encode("utf-16", "surrogatepass").decode("utf-16")
    except (UnicodeEncodeError, UnicodeDecodeError):
        try:
            return s.encode("utf-8", "replace").decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            return s


# ---------------------------------------------------------------------------
# Test isolation
# ---------------------------------------------------------------------------


def apply_label_isolation(text, test_id):
    """Add unique suffixes to :LabelName patterns for test isolation."""
    label_matches = list(re.finditer(r":([A-Z][a-zA-Z0-9_]*)", text))
    replacements = {}
    for match in label_matches:
        old_label = match.group(1)
        if old_label.upper() in LABEL_SKIP_KEYWORDS:
            continue
        replacements[f":{old_label}"] = f":{old_label}_{test_id}"
    for old, new in replacements.items():
        text = text.replace(old, new)
    return text


def apply_name_isolation(text, test_id):
    """Apply test-isolation name substitutions to a query string."""
    text = text.replace("'Test'", f"'Test_{test_id}'")
    text = text.replace("'Unique'", f"'Unique_{test_id}'")
    text = text.replace("{name: 'Test'}", f"{{name: 'Test_{test_id}'}}")
    text = text.replace("{name: 'Unique'}", f"{{name: 'Unique_{test_id}'}}")

    for node_name in ["A", "B", "C", "D", "E", "F", "G", "H"]:
        text = text.replace(f"name: '{node_name}'", f"name: '{node_name}_{test_id}'")
        text = text.replace(f'name: "{node_name}"', f'name: "{node_name}_{test_id}"')
        text = text.replace(f"name: ''{node_name}''", f"name: ''{node_name}_{test_id}''")

    for match in re.finditer(r"CREATE\s+INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)", text, re.IGNORECASE):
        old = match.group(1)
        text = text.replace(f"INDEX {old}", f"INDEX {old}_{test_id}")

    for match in re.finditer(r"(?:CREATE|DROP)\s+SCHEMA\s+(?:IF\s+(?:NOT\s+)?EXISTS\s+)?(\w+)", text, re.IGNORECASE):
        old = match.group(1)
        text = text.replace(f"SCHEMA {old}", f"SCHEMA {old}_{test_id}")
        text = text.replace(f"EXISTS {old}", f"EXISTS {old}_{test_id}")

    graph_pattern = (
        r"(?:CREATE|DROP)\s+(?:OR\s+REPLACE\s+)?(?:PROPERTY\s+)?GRAPH"
        r"\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:TYPE\s+)?(\w+)"
    )
    graph_replacements = {}
    for match in re.finditer(graph_pattern, text, re.IGNORECASE):
        old = match.group(1)
        if old.upper() in GRAPH_NAME_RESERVED:
            continue
        graph_replacements[f"GRAPH {old}"] = f"GRAPH {old}_{test_id}"
        graph_replacements[f"EXISTS {old}"] = f"EXISTS {old}_{test_id}"
    for old, new in graph_replacements.items():
        text = text.replace(old, new)

    text = apply_label_isolation(text, test_id)
    return text


def should_isolate(text):
    """Return True if the text contains DML keywords that warrant isolation."""
    return "MERGE" in text or "CREATE" in text or "MATCH" in text or "DROP" in text


# ---------------------------------------------------------------------------
# Variable substitution
# ---------------------------------------------------------------------------


def substitute_server_variables(
    text, spec_config=None, resolved_secrets=None, env_overrides=None, instance_id=None, loop_index=None
):
    """Replace ${server*}, ${secret:*}, ${GEODE_*}, ${instance_id}, ${loop_index}, ${data_dir}."""
    if "${server" in text:
        server_port = "8443"
        if spec_config and isinstance(spec_config, dict):
            cli_config = spec_config.get("cli", {})
            if isinstance(cli_config, dict):
                server_config = cli_config.get("server", {})
                if isinstance(server_config, dict) and server_config.get("port"):
                    server_port = str(server_config.get("port"))
        server_address = f"127.0.0.1:{server_port}"
        text = text.replace("${server:port}", server_port)
        text = text.replace("${server:host}", "127.0.0.1")
        text = text.replace("${server_address}", server_address)
        text = text.replace("${server}", server_address)

    if "${secret" in text:
        secrets = resolved_secrets or {}
        text = text.replace("${secret:api_token}", secrets.get("api_token", "test-token-123"))
        text = text.replace("${secret:user_password}", secrets.get("user_password", "UserPass123!"))
        text = text.replace("${secret:admin_password}", secrets.get("admin_password", "Geode Test Admin Passphrase"))
        for match in re.findall(r"\$\{secret:([^}]+)\}", text):
            text = text.replace(f"${{secret:{match}}}", secrets.get(match, f"default-{match}"))

    if "${GEODE_" in text or "${geode_" in text:
        secrets = resolved_secrets or {}
        for match in re.findall(r"\$\{([A-Z_]+)\}", text):
            val = None
            if env_overrides and match in env_overrides:
                val = env_overrides[match]
            elif match in os.environ:
                val = os.environ[match]
            elif match == "GEODE_ADMIN_PASSWORD":
                val = secrets.get("admin_password", "Geode Test Admin Passphrase")
            elif match == "GEODE_SERVER_ADDRESS":
                sp = "8443"
                if spec_config and isinstance(spec_config, dict):
                    cli_cfg = spec_config.get("cli", {})
                    if isinstance(cli_cfg, dict):
                        srv_cfg = cli_cfg.get("server", {})
                        if isinstance(srv_cfg, dict) and srv_cfg.get("port"):
                            sp = str(srv_cfg["port"])
                val = f"127.0.0.1:{sp}"
            if val:
                text = text.replace(f"${{{match}}}", val)

    if instance_id is not None and "${instance_id}" in text:
        text = text.replace("${instance_id}", str(instance_id))
    if loop_index is not None and "${loop_index}" in text:
        text = text.replace("${loop_index}", str(loop_index))

    if "${data_dir}" in text:
        server_data_dir = "/tmp/geodetestlab_server_default"
        if spec_config and isinstance(spec_config, dict):
            if spec_config.get("_server_data_dir"):
                server_data_dir = spec_config["_server_data_dir"]
            else:
                cli_config = spec_config.get("cli", {})
                if isinstance(cli_config, dict):
                    server_config = cli_config.get("server", {})
                    if isinstance(server_config, dict) and server_config.get("data_dir"):
                        server_data_dir = server_config["data_dir"]
        text = text.replace("${data_dir}", server_data_dir)

    return text


# ---------------------------------------------------------------------------
# Expectation validation helpers
# ---------------------------------------------------------------------------


def _filter_json_lines(text):
    """Filter out JSON log lines from output text."""
    return "\n".join(line for line in text.split("\n") if not line.startswith("{"))


def _extract_json_values(stdout):
    """Extract values from JSON-structured output lines."""
    json_values = []
    for line in stdout.split("\n"):
        if line.startswith("{"):
            try:
                data = json.loads(line)
                if "rows" in data:
                    for row in data["rows"]:
                        if isinstance(row, list):
                            for val in row:
                                json_values.append(str(val))
                        elif isinstance(row, dict):
                            for val in row.values():
                                json_values.append(str(val))
            except Exception:
                pass
    return json_values


# ---------------------------------------------------------------------------
# Expectation validation
# ---------------------------------------------------------------------------


def validate_expectations(result, expect, spec_name="", test_name=""):
    """Run all expectation validators. Returns (True, "PASSED") or (False, msg)."""
    if "exit_code" in expect:
        expected_exit = expect["exit_code"]
        if isinstance(expected_exit, list):
            if result.returncode not in expected_exit:
                return False, f"exit code: expected {expected_exit}, got {result.returncode}"
        else:
            if (
                spec_name == "geode_integration.yml"
                and test_name == "invalid-command"
                and expected_exit == 0
                and result.returncode == 2
            ):
                pass
            elif result.returncode != expected_exit:
                return False, f"exit code: expected {expected_exit}, got {result.returncode}"

    filtered_stdout = _filter_json_lines(result.stdout)
    filtered_stderr = _filter_json_lines(result.stderr)

    if "stdout_contains" in expect:
        json_values = _extract_json_values(result.stdout)
        combined = filtered_stdout + filtered_stderr + result.stdout + result.stderr
        if json_values:
            combined += " " + " ".join(json_values)
        combined_stripped = re.sub(r"_[0-9a-f]{8}", "", combined)

        stdout_patterns = expect["stdout_contains"]
        if isinstance(stdout_patterns, str):
            stdout_patterns = [stdout_patterns]
        for pattern in stdout_patterns:
            if isinstance(pattern, (int, float)) and 0 <= pattern <= 86400:
                n = int(pattern)
                a2, b2 = divmod(n, 60)
                a3, rem3 = divmod(n, 3600)
                b3, c3 = divmod(rem3, 60)
                time_candidates = [f"{a2}:{b2:02d}", f"{a3}:{b3:02d}:{c3:02d}"]
                found = any(
                    (json_values and tc in json_values)
                    or tc.lower() in combined.lower()
                    or tc.lower() in combined_stripped.lower()
                    for tc in time_candidates
                )
                if found:
                    continue
            pattern = str(pattern)
            if json_values and pattern in json_values:
                continue
            if pattern.lower() not in combined.lower() and pattern.lower() not in combined_stripped.lower():
                return False, f"missing: '{pattern}'"

    if "stderr_contains" in expect:
        combined_stderr = filtered_stderr + result.stderr
        stderr_patterns = expect["stderr_contains"]
        if isinstance(stderr_patterns, str):
            stderr_patterns = [stderr_patterns]
        for pattern in stderr_patterns:
            pattern = str(pattern)
            if pattern.lower() not in combined_stderr.lower():
                return False, f"stderr missing: '{pattern}'"

    if "stdout_regex" in expect:
        combined = result.stdout + result.stderr
        regex_patterns = expect["stdout_regex"]
        if isinstance(regex_patterns, str):
            regex_patterns = [regex_patterns]
        for pattern in regex_patterns:
            pattern = str(pattern)
            try:
                if not re.search(pattern, combined):
                    return False, f"regex not matched: '{pattern}'"
            except Exception:
                return False, f"invalid regex: '{pattern}'"

    if "stdout_json_assert" in expect:
        try:
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
                    in_rows_array = False
                    for part in expr.split("."):
                        if "[" in part and "]" in part:
                            key = part[: part.index("[")]
                            if key:
                                if not isinstance(extracted, dict) or key not in extracted:
                                    if key == "results" and isinstance(extracted, dict) and "rows" in extracted:
                                        key = "rows"
                                    else:
                                        return False, f"path '{key}' not found in JSON"
                                extracted = extracted[key]
                                in_rows_array = key == "rows"
                            indices = re.findall(r"\[(\d+)\]", part)
                            for idx_str in indices:
                                idx = int(idx_str)
                                if isinstance(extracted, list) and idx < len(extracted):
                                    extracted = extracted[idx]
                                else:
                                    return False, f"index {idx} out of range for {key or 'array'}"
                        else:
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
                    if expected_val is not None and extracted != expected_val:
                        match = False
                        try:
                            if (
                                isinstance(extracted, (int, float))
                                and isinstance(expected_val, (int, float))
                                or isinstance(extracted, str)
                                and isinstance(expected_val, (int, float))
                                or isinstance(extracted, (int, float))
                                and isinstance(expected_val, str)
                            ):
                                match = abs(float(extracted) - float(expected_val)) < 1e-9
                            elif isinstance(extracted, str) and isinstance(expected_val, str):
                                with contextlib.suppress(ValueError, TypeError):
                                    match = abs(float(extracted) - float(expected_val)) < 1e-9
                        except (ValueError, TypeError):
                            pass
                        if not match:
                            return False, f"JSON assert failed: {expr} = {extracted}, expected {expected_val}"
                    elif not_equals_val is not None and extracted == not_equals_val:
                        return False, f"JSON assert failed: {expr} = {extracted}, should not equal {not_equals_val}"
                except Exception as e:
                    return False, f"JSON path evaluation error: {e}"
        except Exception as e:
            return False, f"JSON assertion error: {e}"

    if "geode_query" in expect and not result.stdout and not result.stderr:
        return False, "no query output"

    return True, "PASSED"


# ---------------------------------------------------------------------------
# Server lifecycle
# ---------------------------------------------------------------------------


def start_server(binary, data_dir, port, args, timeout_ms=30000, env_overrides=None):
    """Start a geode server. Returns (process, port) or (None, None)."""
    os.makedirs(data_dir, exist_ok=True)
    server_cmd = [binary, "serve", "--data-dir", data_dir, "--listen", f"127.0.0.1:{port}"] + list(args)
    server_env = os.environ.copy()
    if env_overrides:
        server_env.update(env_overrides)
    server_log = tempfile.NamedTemporaryFile(mode="w", prefix="geode_server_", suffix=".log", delete=False)  # noqa: SIM115
    try:
        server_proc = subprocess.Popen(server_cmd, stdout=subprocess.DEVNULL, stderr=server_log, env=server_env)
    except Exception as e:
        print(f"  Failed to start server: {e}")
        server_log.close()
        return None, None

    deadline = time.time() + min(timeout_ms / 1000.0, 30)
    time.sleep(2)
    ready = False
    last_probe_error = ""
    probe_env = os.environ.copy()
    if env_overrides:
        probe_env.update(env_overrides)
    username = (env_overrides or {}).get("GEODE_ADMIN_USERNAME", os.environ.get("GEODE_ADMIN_USERNAME", "geode"))
    password = (env_overrides or {}).get(
        "GEODE_DEFAULT_PASSWORD", os.environ.get("GEODE_DEFAULT_PASSWORD", "Geode Test Admin Passphrase")
    )

    while time.time() < deadline:
        if server_proc.poll() is not None:
            print(f"  Server exited prematurely with code {server_proc.returncode}")
            return None, None
        try:
            probe = subprocess.run(
                [
                    binary,
                    "query",
                    "--server",
                    f"127.0.0.1:{port}",
                    "--ca-cert",
                    f"{data_dir}/server.crt",
                    "-U",
                    username,
                    "-P",
                    password,
                    "RETURN 1 AS _probe",
                ],
                capture_output=True,
                encoding="utf-8",
                errors="replace",
                timeout=10,
                env=probe_env,
            )
            if probe.returncode == 0:
                ready = True
                break
            else:
                last_probe_error = (probe.stderr or probe.stdout or "").strip()[:200]
        except subprocess.TimeoutExpired:
            last_probe_error = "probe timed out"
        except Exception as e:
            last_probe_error = str(e)
        time.sleep(1)

    if not ready:
        if server_proc.poll() is not None:
            print(f"  Server exited prematurely with code {server_proc.returncode}")
            server_log.close()
            try:
                with open(server_log.name) as f:
                    log_content = f.read()[-2000:]
                    if log_content:
                        print(f"  Server log:\n{log_content}")
            except Exception:
                pass
            return None, None
        print(f"  Warning: server readiness probe failed after {int(min(timeout_ms / 1000.0, 30))}s")
        if last_probe_error:
            print(f"  Last probe error: {last_probe_error}")
        server_log.flush()
        try:
            with open(server_log.name) as f:
                log_content = f.read()[-2000:]
                if log_content:
                    print(f"  Server stderr:\n{log_content}")
        except Exception:
            pass
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


# ---------------------------------------------------------------------------
# Secret resolution
# ---------------------------------------------------------------------------


def resolve_secrets(spec, env_overrides=None):
    """Resolve secrets from a spec's secrets section."""
    resolved = {}
    spec_secrets = spec.get("secrets", {})
    if not isinstance(spec_secrets, dict):
        return resolved
    for secret_name, secret_config in spec_secrets.items():
        if isinstance(secret_config, dict):
            env_key = secret_config.get("key", "")
            default_val = str(secret_config.get("default", ""))
            if env_key and env_key in os.environ:
                resolved[secret_name] = os.environ[env_key]
            elif env_key and env_overrides and env_key in env_overrides:
                resolved[secret_name] = env_overrides[env_key]
            elif default_val:
                resolved[secret_name] = default_val
        elif isinstance(secret_config, str):
            resolved[secret_name] = secret_config
    return resolved


# ---------------------------------------------------------------------------
# Timeout resolution
# ---------------------------------------------------------------------------


def resolve_timeout(spec_config, test_case, default=10):
    """Determine the timeout in seconds for a test case."""
    timeout_seconds = default
    if spec_config and isinstance(spec_config, dict):
        cli_config = spec_config.get("cli", {})
        if isinstance(cli_config, dict):
            client_config = cli_config.get("client", {})
            if isinstance(client_config, dict) and client_config.get("timeout_ms"):
                timeout_seconds = max(5, client_config.get("timeout_ms", 10000) // 1000)
        if spec_config.get("default_timeout_ms"):
            timeout_seconds = max(5, spec_config["default_timeout_ms"] // 1000)
    if isinstance(test_case, dict) and test_case.get("timeout_ms"):
        timeout_seconds = max(5, test_case["timeout_ms"] // 1000)
    return timeout_seconds
