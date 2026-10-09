"""Offline bridge regressions: no real credentials, gateways, or inference."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("bridge", REPO / "scripts/claude-provider.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class ProviderBridge(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="claude-provider-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for directory in ("scripts", "zsh/aliases", "zsh", "bin"):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        for name in ("claude-provider.zsh", "claude-provider.py", "claude-provider-prepare.zsh"):
            shutil.copyfile(REPO / "scripts" / name, self.root / "scripts" / name)
        (self.root / "zsh/paths.zsh").write_text("")
        (self.root / "zsh/aliases/claude-enmass.zsh").write_text("")
        (self.root / "zsh/aliases/claude-copilot.zsh").write_text('''
_claude_fixture() {
    local root='deliberate dynamic-scope shadow'
    [[ "$CLAUDE_PROVIDER_NO_RESTART" == 1 ]] || return 93
    [[ "$FIXTURE_FAIL" == 1 ]] && return 23
    if [[ "$FIXTURE_PREP_WAIT" == 1 ]]; then
        _claude_proxy_start "$FIXTURE_SHARED_LOG" python3 -c \
            'import os,pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(120)' "$FIXTURE_SHARED_PID"
        python3 -c 'import os,pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(120)' "$FIXTURE_READY"
        return 0
    fi
    export ANTHROPIC_BASE_URL="http://127.0.0.1:4411/$1"
    export ANTHROPIC_AUTH_TOKEN='fixture-local-token'
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$1-sonnet"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$1-opus"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$1-haiku"
    print -ru2 -- "preparing $1"
    shift
    _claude_invoke --settings '{"modelPicker":{"options":[{"model":"fixture-model"}]},"wrapper":true}' "$@"
}
claude-copilot() { _claude_fixture copilot "$@"; }
claude-vertex() { ( _claude_fixture vertex "$@" ); }
claude-openai() { _claude_fixture openai "$@"; }
claude-enmass() ( _claude_fixture enmass "$@" )
''')
        self.native = self.root / "bin/native"
        self.native.write_text('''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
if sys.argv[1:] == ['--version']:
    print('fixture Claude 1.0'); sys.exit(0)
settings = json.loads(pathlib.Path(sys.argv[2]).read_text())
if os.environ.get('FIXTURE_WAIT') == '1':
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'])
    pathlib.Path(os.environ['FIXTURE_READY']).write_text(json.dumps({'parent':os.getpid(),'child':child.pid}))
    try: time.sleep(120)
    finally: child.wait()
else:
    print(json.dumps({'args':sys.argv[3:], 'settings':settings,
        'stdin':sys.stdin.read(), 'cwd':os.getcwd(),
        'configDir':os.environ.get('CLAUDE_CONFIG_DIR'),
        'upstreamKeyLeaked':any(k in os.environ for k in ['OPENAI_API_KEY','ENMASS_API_KEY']),
        'settingsPath':sys.argv[2]}))
    sys.exit(int(os.environ.get('FIXTURE_EXIT','0')))
''')
        self.native.chmod(0o700)
        self.credentials = self.root / "credentials.zsh"
        self.credentials.write_text('''
print -r -- 'credential-bootstrap-output-must-not-leak'
export OPENAI_API_KEY='fixture-upstream-key'
export ENMASS_API_KEY='fixture-upstream-key'
export CLAUDE_CONFIG_DIR='/wrong/source/home'
print loaded > "$FIXTURE_BOOTSTRAPPED"
''')
        self.env = dict(os.environ, CLAUDE_PROVIDER_NATIVE_BINARY=str(self.native),
                        CLAUDE_PROVIDER_CREDENTIALS_FILE=str(self.credentials),
                        CLAUDE_CONFIG_DIR='/t3/config', XDG_STATE_HOME=str(self.root / "state"),
                        TMPDIR=str(self.root), FIXTURE_BOOTSTRAPPED=str(self.root / "loaded"))
        for key in list(self.env):
            if key.startswith("ANTHROPIC_") or key in ("FIXTURE_WAIT", "FIXTURE_FAIL", "FIXTURE_EXIT"):
                self.env.pop(key, None)

    def command(self, backend, *args):
        return ["/bin/zsh", "-f", "-c", 'source "$1" "$2" "${@:3}"',
                "bridge-test", str(self.root / "scripts/claude-provider.zsh"), backend, *args]

    def invoke(self, backend="copilot", *args, env=None):
        return subprocess.run(self.command(backend, *args), env=env or self.env,
                              cwd=self.root, input="protocol-input\n", text=True,
                              capture_output=True, timeout=15)

    def test_four_backends_merge_and_forward(self):
        for backend in ("copilot", "vertex", "openai", "enmass"):
            with self.subTest(backend=backend):
                result = self.invoke(backend, "--model", "t3-sonnet", "--settings",
                    '{"sdk":true,"env":{"KEEP":"yes","ANTHROPIC_AUTH_TOKEN":"wrong"}}',
                    "--resume", "session with spaces", "--", "literal $argument")
                self.assertEqual(result.returncode, 0, result.stderr)
                data = json.loads(result.stdout)
                self.assertEqual(data["args"], ["--model", backend + "-sonnet", "--resume",
                                                "session with spaces", "--", "literal $argument"])
                self.assertTrue(data["settings"]["sdk"])
                self.assertTrue(data["settings"]["wrapper"])
                self.assertEqual(data["settings"]["env"]["KEEP"], "yes")
                self.assertEqual(data["settings"]["env"]["ANTHROPIC_AUTH_TOKEN"], "fixture-local-token")
                self.assertFalse(data["upstreamKeyLeaked"])
                self.assertEqual(data["configDir"], "/t3/config")
                self.assertEqual(data["stdin"], "protocol-input\n")
                self.assertEqual(Path(data["cwd"]).resolve(), self.root.resolve())
                self.assertFalse(Path(data["settingsPath"]).exists())
                self.assertNotIn("credential-bootstrap-output", result.stdout + result.stderr)
                self.assertNotIn("fixture-upstream-key", result.stdout + result.stderr)

    def test_version_skips_credentials_and_preparation(self):
        before = time.monotonic()
        result = self.invoke("vertex", "--version")
        self.assertEqual(result.stdout, "fixture Claude 1.0\n")
        self.assertEqual(result.returncode, 0)
        self.assertFalse((self.root / "loaded").exists())
        self.assertLess(time.monotonic() - before, 4)

    def test_prepare_only_and_file_settings(self):
        result = self.invoke("enmass", "--prepare")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["backend"], "enmass")
        self.assertNotIn("fixture-local-token", result.stdout)
        file = self.root / "caller.json"
        file.write_text('{"sdk":"file"}')
        result = self.invoke("openai", "--settings=" + str(file), "--model=t3-opus")
        data = json.loads(result.stdout)
        self.assertEqual(data["settings"]["sdk"], "file")
        self.assertEqual(data["args"], ["--model=openai-opus"])

    def test_failures_and_exit_status(self):
        self.assertEqual(self.invoke("copilot", env=dict(self.env, FIXTURE_FAIL="1")).returncode, 23)
        self.assertEqual(self.invoke("openai", env=dict(self.env, FIXTURE_EXIT="17")).returncode, 17)
        result = self.invoke("vertex", "--settings", "invalid-sensitive-value")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("invalid-sensitive-value", result.stderr)
        self.assertFalse(list(self.root.glob("claude-provider-*/settings.json")))

    def test_cancel_native_tree_preserves_unrelated_process(self):
        ready = self.root / "ready"
        unrelated = subprocess.Popen([sys_executable(), "-c", "import time; time.sleep(120)"])
        self.addCleanup(lambda: bridge.terminate(unrelated))
        child = subprocess.Popen(self.command("copilot"), env=dict(self.env, FIXTURE_WAIT="1",
            FIXTURE_READY=str(ready)), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: bridge.terminate(child))
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.exists())
        pids = json.loads(ready.read_text())
        child.send_signal(signal.SIGTERM)
        child.communicate(timeout=10)
        self.assertEqual(child.returncode, 143)
        self.assertIsNone(unrelated.poll())
        # The process group has no surviving members (including Claude's child).
        with self.assertRaises(ProcessLookupError):
            os.killpg(pids["parent"], 0)
        self.assertFalse(list(self.root.glob("claude-provider-*/settings.json")))

    def test_cancel_preparation_preserves_detached_proxy(self):
        ready, shared = self.root / "ready", self.root / "shared"
        child = subprocess.Popen(self.command("copilot", "--prepare"),
            env=dict(self.env, FIXTURE_PREP_WAIT="1", FIXTURE_READY=str(ready),
                     FIXTURE_SHARED_PID=str(shared), FIXTURE_SHARED_LOG=str(self.root / "shared.log")),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: bridge.terminate(child))
        deadline = time.monotonic() + 10
        while (not ready.exists() or not shared.exists()) and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.exists() and shared.exists())
        preparation_pid, proxy_pid = int(ready.read_text()), int(shared.read_text())
        def stop_fixture_proxy():
            try:
                os.kill(proxy_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        self.addCleanup(stop_fixture_proxy)
        child.send_signal(signal.SIGTERM)
        child.communicate(timeout=10)
        self.assertEqual(child.returncode, 143)
        with self.assertRaises(ProcessLookupError):
            os.kill(preparation_pid, 0)
        os.kill(proxy_pid, 0)

    def test_catalog_cache_is_private_and_credential_scoped(self):
        environment = dict(self.env, XDG_CACHE_HOME=str(self.root / "cache"))
        program = str(self.root / "scripts/claude-provider.py")
        identity = "a" * 64
        cache = self.root / "cache/claude-provider" / (identity + ".json")
        write = subprocess.run([sys_executable(), program, "--catalog-write", identity],
            input='{"data":[{"id":"fixture-model"}]}', text=True, capture_output=True, env=environment)
        self.assertEqual(write.returncode, 0)
        self.assertEqual(cache.stat().st_mode & 0o777, 0o600)
        read = subprocess.run([sys_executable(), program, "--catalog-read", identity],
                              capture_output=True, text=True, env=environment)
        self.assertEqual(json.loads(read.stdout)["data"][0]["id"], "fixture-model")
        changed = subprocess.run([sys_executable(), program, "--catalog-read", "b" * 64],
                                 capture_output=True, env=environment)
        self.assertEqual(changed.returncode, 3)
        os.utime(cache, (0, 0))
        stale = subprocess.run([sys_executable(), program, "--catalog-read", identity],
                               capture_output=True, env=environment)
        self.assertEqual(stale.returncode, 3)


def sys_executable():
    import sys
    return sys.executable


if __name__ == "__main__":
    unittest.main()
