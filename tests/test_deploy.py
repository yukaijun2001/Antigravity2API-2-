"""Exercise deployment updates and recovery with Docker CLI, without a daemon.

Run: python3 -m unittest discover -s tests -p 'test_deploy.py'
"""

import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SCRIPT = PROJECT / "deploy.sh"

COMMAND_STUB = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
import subprocess

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
state_file = Path(os.environ["MOCK_STATE"])
state = json.loads(state_file.read_text())
state["calls"].append([tool, *args])

def done(text="", code=0):
    state_file.write_text(json.dumps(state))
    if text:
        print(text)
    sys.exit(code)

def container(reference):
    return next((item for item in state["containers"]
                 if reference in (item["id"], item["name"])), None)

failure = os.environ.get("MOCK_FAILURE", "")
if tool == "uname":
    done(os.environ.get("MOCK_OS", "Linux") if "-s" in args else "x86_64")
if tool == "flock":
    done(code=1 if failure == "locked" else 0)
if tool == "sleep":
    done()
if tool == "hostname":
    done("192.0.2.10")
if tool == "getenforce":
    done("Enforcing" if os.environ.get("MOCK_SELINUX") else "Disabled")
if tool in ("systemctl", "service"):
    done()
if tool == "ufw":
    done("Status: active" if args == ["status"] else "Rule added")
if tool == "firewall-cmd":
    done("running" if args == ["--state"] else "success")
if tool == "curl":
    if "https://api.ipify.org" in args:
        done("203.0.113.10")
    done(json.dumps({"enabled": failure != "health-disabled"}))
if tool != "docker":
    done(code=2)
if args == ["info"] or args == ["buildx", "version"]:
    done("mock Docker")
if args[:2] == ["compose", "version"]:
    done("Docker Compose mock")
if args[:2] == ["compose", "up"] and "--help" in args:
    done("old Compose" if failure == "old-compose" else "--wait-timeout SECONDS")
if args[0] == "compose":
    commands = ("config", "build", "up", "down", "stop", "logs", "create")
    offset = next(index for index, arg in enumerate(args) if arg in commands)
    action = args[offset]
    global_options = args[:offset]
    if action == "config":
        if failure == "config":
            done("invalid Compose definition", code=1)
        result = subprocess.run([os.environ["REAL_DOCKER"], *args], capture_output=True, text=True)
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        done(result.stdout.rstrip(), result.returncode)
    result = subprocess.run([os.environ["REAL_DOCKER"], *global_options, "config", "--format", "json"],
                            capture_output=True, text=True)
    if result.returncode:
        print(result.stderr, file=sys.stderr)
        done(code=result.returncode)
    config = json.loads(result.stdout)
    service = config["services"]["antigravity2api"]
    image = service["image"]
    if action == "build":
        if failure == "build":
            done(code=1)
        state["image_sequence"] += 1
        state["images"][image] = "sha256:image-" + str(state["image_sequence"])
        done()
    if action == "logs":
        done("mock application startup failure")
    if action == "stop":
        for item in state["containers"]:
            if item.get("project") == config["name"]:
                item["running"] = False
        done()
    if action == "down":
        state["containers"] = [item for item in state["containers"]
                               if item.get("project") != config["name"]]
        done()
    if action in ("up", "create"):
        # Compose replaces its own service, while a renamed legacy container
        # without Compose labels remains available until migration succeeds.
        state["containers"] = [item for item in state["containers"]
                               if item.get("project") != config["name"]]
        rollback = ":rollback-" in image
        fails = failure in ("startup", "run") and not rollback
        state["sequence"] += 1
        item = {
            "id": "container-" + str(state["sequence"]),
            "name": service["container_name"],
            "owner": service["labels"]["io.antigravity2api.deploy"],
            "running": action == "up" and not fails,
            "project": config["name"],
            "service": "antigravity2api",
            "image": state["images"][image],
            "config": service,
        }
        state["containers"].append(item)
        done(item["id"], code=1 if fails else 0)
    done(code=2)
if args[:2] == ["image", "tag"]:
    state["images"][args[-1]] = state["images"].get(args[-2], args[-2])
    done()
if args[:2] == ["image", "rm"]:
    state["images"].pop(args[-1], None)
    done()
if args[:2] == ["container", "inspect"]:
    item = container(args[-1])
    if not item:
        done(code=1)
    template = args[args.index("--format") + 1]
    if template == "{{.Id}}":
        done(item["id"])
    if template == "{{.State.Running}}":
        done(str(item["running"]).lower())
    if template == "{{.Image}}":
        done(item["image"])
    if '"com.docker.compose.project"' in template:
        done(item.get("project", ""))
    if '"com.docker.compose.service"' in template:
        done(item.get("service", ""))
    done(item["owner"])
if args[0] == "stop":
    container(args[-1])["running"] = False
    done()
if args[0] == "rename":
    item = container(args[1])
    if not item or container(args[2]):
        done(code=1)
    item["name"] = args[2]
    done()
if args[0] == "rm":
    item = container(args[-1])
    if not item:
        done(code=1)
    state["containers"].remove(item)
    done()
if args[0] == "start":
    container(args[-1])["running"] = True
    done()
if args[0] == "logs":
    done("mock application startup failure")
done(code=2)
'''


class DeployTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.real_docker = shutil.which("docker")
        if not cls.real_docker:
            raise unittest.SkipTest("Docker CLI with Compose is required; no daemon needed")
        probe = subprocess.run([cls.real_docker, "compose", "version"], capture_output=True)
        if probe.returncode:
            raise unittest.SkipTest("Docker Compose CLI is required; no daemon needed")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="antigravity-deploy-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.remote = self.root / "remote"
        self.remote.mkdir()
        self.install = self.root / "deployment with spaces"
        self.state_file = self.root / "docker.json"
        self.state_file.write_text(json.dumps({
            "calls": [], "containers": [], "sequence": 0, "images": {}, "image_sequence": 0,
        }))
        self.git(self.remote, "init", "--initial-branch=main")
        (self.remote / "Dockerfile").write_text("FROM scratch\n")
        (self.remote / ".env.example").write_text((PROJECT / ".env.example").read_text())
        (self.remote / "compose.yaml").write_text((PROJECT / "compose.yaml").read_text())
        self.commit("Initial source")

        commands = self.root / "commands"
        commands.mkdir()
        stub = commands / "stub"
        stub.write_text(COMMAND_STUB)
        stub.chmod(0o755)
        for tool in ("uname", "docker", "curl", "sleep", "flock", "ufw", "firewall-cmd",
                     "hostname", "getenforce", "systemctl", "service"):
            (commands / tool).symlink_to(stub)
        self.environment = dict(
            os.environ,
            PATH=str(commands) + os.pathsep + os.environ["PATH"],
            DEPLOY_SCRIPT=str(SCRIPT),
            DEPLOY_DIR=str(self.install),
            REPO_URL=str(self.remote),
            BRANCH="main",
            MOCK_STATE=str(self.state_file),
            REAL_DOCKER=self.real_docker,
        )

    def git(self, directory, *args):
        return subprocess.run(
            ["git", "-C", str(directory), *args], check=True,
            capture_output=True, text=True,
        ).stdout.strip()

    def commit(self, message):
        self.git(self.remote, "add", ".")
        self.git(self.remote, "-c", "user.name=Deploy Test", "-c", "user.email=deploy@example.com",
                 "commit", "-m", message)

    def deploy(self, failure="", extra="", expected=0):
        # Dependency installation/root escalation are host operations. Everything
        # after them uses real Git/filesystem operations and a stateful Docker stub.
        code = '''source "$DEPLOY_SCRIPT"
require_root() { :; }
install_dependencies() { :; }
check_port() { :; }
'''
        result = subprocess.run(
            ["bash", "-c", code + extra + "\nmain"],
            env=dict(self.environment, MOCK_FAILURE=failure), capture_output=True,
            text=True, timeout=30,
        )
        if expected == 0:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def state(self):
        return json.loads(self.state_file.read_text())

    @property
    def env_file(self):
        return self.install / "data" / ".env"

    def values(self):
        result = {}
        for line in self.env_file.read_text().splitlines():
            if re.match(r"^[A-Z][A-Z0-9_]*=", line):
                key, raw = line.split("=", 1)
                result[key] = json.loads(raw) if raw.startswith('"') else raw
        return result

    def seed_legacy_container(self, running=True):
        self.env_file.parent.mkdir(parents=True)
        self.env_file.write_text(
            'LISTEN=0.0.0.0:8017\nADMIN_AUTH_ENABLED=true\n'
            'ADMIN_USERNAME=legacy_admin\nADMIN_PASSWORD="legacy secret"\nAPI_KEYS=legacy-key\n'
        )
        account = self.env_file.parent / "auth" / "account.json"
        account.parent.mkdir()
        account.write_text("legacy account")
        existing = {
            "id": "legacy-id", "name": "antigravity2api", "running": running,
            "owner": str(self.install.resolve()), "image": "sha256:legacy-image",
        }
        state = self.state()
        state["containers"].append(existing)
        self.state_file.write_text(json.dumps(state))
        return existing

    def test_first_deploy_configures_credentials_port_and_persistence(self):
        result = self.deploy()
        values = self.values()
        self.assertEqual(values["ADMIN_USERNAME"], "sys_wutong")
        self.assertEqual(values["ADMIN_PASSWORD"], "f3RggbXHH6d5T8UKKakg")
        self.assertEqual(values["ADMIN_AUTH_ENABLED"], "true")
        self.assertEqual(values["LISTEN"], "0.0.0.0:8017")
        self.assertRegex(values["API_KEYS"], r"^sk-[0-9a-f]{48}$")
        self.assertEqual(self.env_file.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.env_file.parent.stat().st_mode & 0o777, 0o700)
        container = self.state()["containers"][0]
        self.assertTrue(container["running"])
        service = container["config"]
        self.assertEqual(container["project"], "antigravity2api")
        self.assertEqual(service["ports"][0]["published"], "10005")
        self.assertEqual(service["ports"][0]["target"], 8017)
        self.assertEqual(service["restart"], "unless-stopped")
        self.assertEqual(service["logging"]["options"], {"max-size": "10m", "max-file": "3"})
        self.assertEqual(service["volumes"][0]["source"], f"{self.install.resolve()}/data")
        self.assertEqual(service["volumes"][0]["target"], "/data")
        self.assertEqual(service["healthcheck"]["test"],
                         ["CMD", "antigravity2api", "status", "--listen", "127.0.0.1:8017"])
        self.assertTrue((self.install / "compose.yaml").is_file())
        self.assertEqual(service["environment"], {"TZ": "Asia/Shanghai"})
        self.assertFalse(any(call[:2] == ["docker", "run"] for call in self.state()["calls"]))
        self.assertNotIn(values["API_KEYS"], result.stdout + result.stderr)
        self.assertNotIn(values["ADMIN_PASSWORD"], result.stdout + result.stderr)
        self.assertFalse(list(self.install.glob(".deploy-*")))
        self.assertIn(["ufw", "allow", "10005/tcp"], self.state()["calls"])
        self.assertIn(["firewall-cmd", "--permanent", "--add-port=10005/tcp"], self.state()["calls"])

    def test_update_fetches_latest_and_preserves_accounts_settings_and_credentials(self):
        self.deploy()
        old_id = self.state()["containers"][0]["id"]
        initial_key = self.values()["API_KEYS"]
        settings = {
            "ADMIN_USERNAME": "changed_admin", "ADMIN_PASSWORD": "changed # $() secret",
            "API_KEYS": initial_key + ",another-key", "PROXY": "socks5://proxy.example:1080",
            "SYSTEM_PROMPT_USER_TEMPLATE": "a literal $(touch /never-evaluate)\nsecond line",
        }
        with self.env_file.open("a") as output:
            for key, value in settings.items():
                output.write(f"{key}={json.dumps(value)}\n")
        account = self.install / "data" / "auth" / "account.json"
        account.parent.mkdir()
        account.write_text("existing account")
        runtime = self.install / "data" / "runtime" / "requests.db"
        runtime.parent.mkdir()
        runtime.write_bytes(b"existing runtime data")
        (self.remote / "version.txt").write_text("next version")
        self.commit("Next version")
        self.deploy()
        self.assertEqual(self.git(self.install / "source", "rev-parse", "HEAD"),
                         self.git(self.remote, "rev-parse", "HEAD"))
        for key, value in settings.items():
            self.assertEqual(self.values()[key], value)
        self.assertEqual(account.read_text(), "existing account")
        self.assertEqual(runtime.read_bytes(), b"existing runtime data")
        self.assertEqual(len(self.state()["containers"]), 1)
        self.assertNotEqual(self.state()["containers"][0]["id"], old_id)

    def test_build_failure_keeps_old_service_and_config(self):
        self.deploy()
        old_container = self.state()["containers"][0]
        old_config = self.env_file.read_bytes()
        old_compose = (self.install / "compose.yaml").read_bytes()
        result = self.deploy(failure="build", expected=1)
        self.assertEqual(self.state()["containers"], [old_container])
        self.assertEqual(self.env_file.read_bytes(), old_config)
        self.assertEqual((self.install / "compose.yaml").read_bytes(), old_compose)
        self.assertFalse(any(":rollback-" in tag for tag in self.state()["images"]))
        self.assertNotIn("部署成功", result.stdout)

    def test_failed_replacement_restores_old_container_and_config(self):
        for failure in ("startup", "run", "health-disabled"):
            with self.subTest(failure=failure):
                self.deploy()
                old_container = self.state()["containers"][0]
                with self.env_file.open("a") as output:
                    output.write("ADMIN_AUTH_ENABLED=false\n")
                old_config = self.env_file.read_bytes()
                result = self.deploy(failure=failure, expected=1)
                restored = self.state()["containers"]
                self.assertEqual(len(restored), 1)
                self.assertTrue(restored[0]["running"])
                self.assertEqual(restored[0]["image"], old_container["image"])
                self.assertEqual(restored[0]["project"], old_container["project"])
                self.assertIn(":rollback-", restored[0]["config"]["image"])
                self.assertEqual(self.env_file.read_bytes(), old_config)
                self.assertNotIn("部署成功", result.stdout)
                self.assertFalse(list(self.install.glob(".deploy-*")))

    def test_failed_first_deploy_does_not_report_success_or_leave_container(self):
        self.deploy(failure="startup", expected=1)
        self.assertEqual(self.state()["containers"], [])
        self.assertFalse(self.env_file.exists())
        self.assertTrue(self.env_file.parent.exists())
        self.assertFalse((self.install / "compose.yaml").exists())

    def test_legacy_deployment_is_migrated_without_changing_credentials_or_accounts(self):
        self.seed_legacy_container()
        self.deploy()
        self.assertEqual(len(self.state()["containers"]), 1)
        self.assertEqual(self.state()["containers"][0]["project"], "antigravity2api")
        self.assertEqual(self.values()["ADMIN_USERNAME"], "legacy_admin")
        self.assertEqual(self.values()["ADMIN_PASSWORD"], "legacy secret")
        self.assertEqual(self.values()["API_KEYS"], "legacy-key")
        self.assertEqual((self.env_file.parent / "auth" / "account.json").read_text(), "legacy account")
        self.assertTrue((self.install / "compose.yaml").exists())

    def test_failed_migration_restores_original_legacy_container_and_credentials(self):
        old_container = self.seed_legacy_container()
        old_config = self.env_file.read_bytes()
        self.deploy(failure="startup", expected=1)
        self.assertEqual(self.state()["containers"], [old_container])
        self.assertEqual(self.env_file.read_bytes(), old_config)
        self.assertFalse((self.install / "compose.yaml").exists())

    def test_failed_update_preserves_previously_stopped_service(self):
        self.deploy()
        state = self.state()
        state["containers"][0]["running"] = False
        old_image = state["containers"][0]["image"]
        self.state_file.write_text(json.dumps(state))
        self.deploy(failure="startup", expected=1)
        self.assertEqual(len(self.state()["containers"]), 1)
        self.assertFalse(self.state()["containers"][0]["running"])
        self.assertEqual(self.state()["containers"][0]["image"], old_image)

    def test_invalid_compose_definition_leaves_existing_service_untouched(self):
        self.deploy()
        old_container = self.state()["containers"][0]
        old_config = self.env_file.read_bytes()
        old_compose = (self.install / "compose.yaml").read_bytes()
        self.deploy(failure="config", expected=1)
        self.assertEqual(self.state()["containers"], [old_container])
        self.assertEqual(self.env_file.read_bytes(), old_config)
        self.assertEqual((self.install / "compose.yaml").read_bytes(), old_compose)

    def test_old_compose_version_is_rejected_before_source_or_container_changes(self):
        self.deploy(failure="old-compose", expected=1)
        self.assertFalse((self.install / "source").exists())
        self.assertEqual(self.state()["containers"], [])

    def test_foreign_container_is_not_replaced(self):
        state = self.state()
        existing = {"id": "foreign", "name": "antigravity2api", "running": True, "owner": "other"}
        state["containers"].append(existing)
        self.state_file.write_text(json.dumps(state))
        self.deploy(expected=1)
        self.assertEqual(self.state()["containers"], [existing])
        self.assertFalse((self.install / "source").exists())

    def test_dirty_checkout_is_not_discarded(self):
        self.deploy()
        old_container = self.state()["containers"][0]
        marker = self.install / "source" / "uncommitted.txt"
        marker.write_text("local edits")
        self.deploy(expected=1)
        self.assertEqual(marker.read_text(), "local edits")
        self.assertEqual(self.state()["containers"], [old_container])

    def test_local_commits_are_not_deployed_as_latest_remote_source(self):
        self.deploy()
        old_container = self.state()["containers"][0]
        source = self.install / "source"
        (source / "local.txt").write_text("local commit")
        self.git(source, "add", ".")
        self.git(source, "-c", "user.name=Deploy Test", "-c", "user.email=deploy@example.com",
                 "commit", "-m", "Local changes")
        self.deploy(expected=1)
        self.assertEqual(self.state()["containers"], [old_container])

    def test_selinux_host_labels_data_for_container_access(self):
        self.environment["MOCK_SELINUX"] = "1"
        self.deploy()
        volume = self.state()["containers"][0]["config"]["volumes"][0]
        self.assertEqual(volume["source"], f"{self.install.resolve()}/data")
        self.assertEqual(volume["bind"]["selinux"], "Z")

    def test_concurrent_deployment_exits_before_touching_service(self):
        self.deploy()
        old_container = self.state()["containers"][0]
        self.deploy(failure="locked", expected=1)
        self.assertEqual(self.state()["containers"], [old_container])

    def test_occupied_port_is_reported(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("0.0.0.0", 0))
            listener.listen()
            result = subprocess.run(
                ["bash", "-c", 'source "$DEPLOY_SCRIPT"; HOST_PORT="$TEST_PORT"; check_port'],
                env=dict(self.environment, TEST_PORT=str(listener.getsockname()[1])),
                capture_output=True, text=True, timeout=10,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("不可用", result.stderr)

    def test_non_linux_host_exits_before_installation(self):
        result = subprocess.run(
            ["bash", str(SCRIPT)], env=dict(self.environment, MOCK_OS="Darwin"),
            capture_output=True, text=True, timeout=10,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Linux", result.stderr)
        self.assertEqual(self.state()["containers"], [])


if __name__ == "__main__":
    unittest.main()
