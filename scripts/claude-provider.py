"""Prepare existing ZSH providers, then supervise only the invocation's Claude."""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
TRANSPORT = (
    "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY",
    "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "ANTHROPIC_DEFAULT_FABLE_MODEL", "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_FOUNDRY",
    "ANTHROPIC_CUSTOM_HEADERS", "CLAUDE_CODE_API_KEY_HELPER",
)


def merge(left, right):
    result = dict(left)
    for key, value in right.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge(result[key], value)
        else:
            result[key] = value
    return result


def read_settings(value):
    if value.lstrip().startswith("{"):
        result = json.loads(value)
    else:
        result = json.loads(Path(value).read_text())
    if not isinstance(result, dict):
        raise ValueError("settings must be an object")
    return result


def capture(destination):
    raw = sys.stdin.buffer.read().split(b"\0")
    args = [item.decode() for item in raw[:-1]]
    settings, forwarded = {}, []
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--":
            forwarded.extend(args[index:])
            break
        if arg == "--settings":
            index += 1
            if index >= len(args):
                raise ValueError("missing settings")
            settings = merge(settings, read_settings(args[index]))
        elif arg.startswith("--settings="):
            settings = merge(settings, read_settings(arg.split("=", 1)[1]))
        else:
            forwarded.append(arg)
        index += 1
    # Wrapper-selected transport wins over a saved/caller transport. Preserve
    # unrelated SDK settings, options, permissions and environment entries.
    transport = {key: os.environ.get(key, "") for key in TRANSPORT}
    transport.update({"CLAUDE_CODE_USE_VERTEX": "0", "CLAUDE_CODE_USE_BEDROCK": "0",
                      "CLAUDE_CODE_USE_FOUNDRY": "0", "ANTHROPIC_API_KEY": ""})
    settings = merge(settings, {"env": transport})
    tiers = {"t3-" + tier: os.environ.get("ANTHROPIC_DEFAULT_" + tier.upper() + "_MODEL")
             for tier in ("sonnet", "opus", "haiku", "fable")}
    index = 0
    while index < len(forwarded):
        arg = forwarded[index]
        if arg == "--":
            break
        if arg == "--model" and index + 1 < len(forwarded):
            index += 1
            value = forwarded[index]
            if value in tiers:
                if not tiers[value]:
                    raise ValueError("requested tier is unavailable")
                forwarded[index] = tiers[value]
        elif arg.startswith("--model="):
            value = arg.split("=", 1)[1]
            if value in tiers:
                if not tiers[value]:
                    raise ValueError("requested tier is unavailable")
                forwarded[index] = "--model=" + tiers[value]
        index += 1
    environment = dict(os.environ)
    # Upstream gateway keys stay with the proxies, not the Claude child.
    for key in ("ENMASS_API_KEY", "OPENAI_API_KEY"):
        environment.pop(key, None)
    for key in list(environment):
        if key.startswith("CLAUDE_PROVIDER_"):
            environment.pop(key, None)
    environment.update(transport)
    Path(destination).write_text(json.dumps({"args": forwarded, "settings": settings,
                                          "env": environment, "tiers": tiers}))
    os.chmod(destination, 0o600)


class Cancelled(Exception):
    def __init__(self, signum):
        self.signum = signum


def terminate(child, group=False):
    if child is None or child.poll() is not None:
        return
    try:
        if group:
            os.killpg(child.pid, signal.SIGTERM)
        else:
            child.terminate()
        child.wait(timeout=5)
    except ProcessLookupError:
        pass
    except subprocess.TimeoutExpired:
        if group:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(child.pid, signal.SIGKILL)
        else:
            child.kill()
        child.wait()


def run(backend, native, args):
    os.umask(0o077)
    preparation_only = args == ["--prepare"]
    if preparation_only:
        args = []
    # Separate backend locks prevent concurrent config writes/startup through
    # these launchers. Interactive shells retain their existing lifecycle.
    state = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
    locks = state / "claude-provider"
    locks.mkdir(parents=True, exist_ok=True, mode=0o700)
    child = None
    native_group = False
    def cancelled(signum, frame):
        raise Cancelled(signum)
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, cancelled)
    try:
        with tempfile.TemporaryDirectory(prefix="claude-provider-") as temporary:
            profile_path = Path(temporary) / "profile.json"
            environment = dict(os.environ)
            environment["CLAUDE_PROVIDER_PROFILE"] = str(profile_path)
            environment["CLAUDE_PROVIDER_PREPARATION_ONLY"] = str(int(preparation_only))
            environment["CLAUDE_PROVIDER_CONFIG_DIR_PRESENT"] = str(int("CLAUDE_CONFIG_DIR" in environment))
            environment["CLAUDE_PROVIDER_CONFIG_DIR"] = environment.get("CLAUDE_CONFIG_DIR", "")
            # --prepare may take a cold-start minute; do it before T3's SDK probe.
            with (locks / (backend + ".lock")).open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                child = subprocess.Popen([
                    "/bin/zsh", "-f", "-c",
                    'source "$1"; shift; claude-provider-prepare "$@"',
                    "claude-provider", str(ROOT / "scripts/claude-provider-prepare.zsh"),
                    str(ROOT), backend, *args,
                ], env=environment, stdin=subprocess.DEVNULL, stdout=sys.stderr,
                   start_new_session=True)
                native_group = True
                result = child.wait()
                child = None
                if result:
                    return result if result >= 0 else 128 - result
                profile = json.loads(profile_path.read_text())
            if preparation_only:
                # Only transport metadata/model names; never credential values.
                print(json.dumps({"backend": backend,
                                  "endpoint": profile["env"]["ANTHROPIC_BASE_URL"],
                                  "tiers": profile["tiers"],
                                  "models": profile["settings"].get("modelPicker", {}).get("options", [])}))
                return 0
            settings_path = Path(temporary) / "settings.json"
            # T3 has no TUI: blast-radius holds tool.call on a Pane nobody can answer.
            profile["settings"].setdefault("enabledPlugins", {})["blast-radius@local-mods"] = False
            settings_path.write_text(json.dumps(profile["settings"]))
            # The private settings file keeps transport credentials off argv.
            profile_path.unlink()
            child = subprocess.Popen([native, "--settings", str(settings_path), *profile["args"]],
                                     env=profile["env"], start_new_session=True)
            native_group = True
            result = child.wait()
            child = None
            return result if result >= 0 else 128 - result
    except Cancelled as error:
        # Do not interrupt cleanup with a second TERM from the SDK.
        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(signum, signal.SIG_IGN)
        terminate(child, native_group)
        return 128 + error.signum


def main():
    try:
        if len(sys.argv) == 3 and sys.argv[1] in ("--catalog-read", "--catalog-write"):
            identity = sys.argv[2]
            if len(identity) != 64 or any(c not in "0123456789abcdef" for c in identity):
                raise ValueError("invalid cache identity")
            directory = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "claude-provider"
            destination = directory / (identity + ".json")
            if sys.argv[1] == "--catalog-read":
                if not destination.is_file() or time.time() - destination.stat().st_mtime > 21600:
                    return 3
                catalog = json.loads(destination.read_text())
                print(json.dumps(catalog))
            else:
                catalog = json.load(sys.stdin)
                if not isinstance(catalog, dict) or not isinstance(catalog.get("data"), list):
                    raise ValueError("invalid catalog")
                directory.mkdir(parents=True, exist_ok=True, mode=0o700)
                destination.write_text(json.dumps(catalog))
                os.chmod(destination, 0o600)
            return 0
        if len(sys.argv) == 3 and sys.argv[1] == "--capture":
            capture(sys.argv[2])
            return 0
        if len(sys.argv) >= 4 and sys.argv[1] == "--background":
            with open(sys.argv[2], "ab") as log:
                subprocess.Popen(sys.argv[3:], stdin=subprocess.DEVNULL, stdout=log,
                                 stderr=log, start_new_session=True)
            return 0
        backend, native, *args = sys.argv[1:]
        if backend not in ("copilot", "vertex", "openai", "enmass"):
            raise ValueError("invalid provider")
        return run(backend, native, args)
    except (ValueError, OSError, KeyError, json.JSONDecodeError):
        # Parsing exceptions can contain credentials: report no raw values.
        print("claude-provider: preparation/settings failed; check the credential source and settings format.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
