# One-shot lifecycle controller for the standard shared EnMaaS proxy (the Go
# binary; the LiteLLM impl is retired). No request server, tenant registry or
# session leases live here.
_claude_enmaas_proxy_program() {
    command cat <<'PY'
import ast
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request


# State lives under ~/.local/state, not /tmp: the proxy runs for days and an
# aged-out /tmp entry used to strand a live proxy nobody could adopt or stop.
# CLAUDE_ENMAAS_RUNTIME_DIR overrides the parent (tests).
def runtime_name(port):
    return 'claude-enmaas-proxy-%s-%s' % (os.getuid(), port)


def legacy_runtime(port):
    return Path('/tmp') / runtime_name(port)


def runtime(port):
    base = Path(os.environ.get('CLAUDE_ENMAAS_RUNTIME_DIR')
                or Path(os.environ.get('XDG_STATE_HOME') or Path.home() / '.local' / 'state'))
    base.mkdir(mode=0o700, parents=True, exist_ok=True)
    root = base / runtime_name(port)
    root.mkdir(mode=0o700, exist_ok=True)
    st = root.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise RuntimeError('unsafe proxy runtime directory')
    return root


def locate(root, port):
    # The runtime dir holding the recorded, still-running proxy: <root>, else
    # the pre-move /tmp one (a proxy started before the move keeps running
    # from there until it is restarted).
    info = read_private(root / 'proxy.json')
    if not owned(info):
        legacy = legacy_runtime(port)
        try:
            old = read_private(legacy / 'proxy.json') if legacy.is_dir() else None
        except RuntimeError:
            old = None
        if owned(old):
            return legacy, old
    return root, info


def read_private(path):
    if not path.exists():
        return None
    st = path.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise RuntimeError('unsafe proxy runtime file')
    return json.loads(path.read_text())


def write_private(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream)
    path.chmod(0o600)


def birth(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart='], text=True, capture_output=True)
    return result.stdout.strip() if result.returncode == 0 else ''


def listeners(port):
    result = subprocess.run(['lsof', '-nP', '-t', '-iTCP:%s' % port, '-sTCP:LISTEN'],
                            text=True, capture_output=True)
    return {int(p) for p in result.stdout.split() if p.isdecimal()}


def notice(message):
    print('claude-enmaas: ' + message, file=sys.stderr)


def busy(port):
    # Client connections the proxy is serving right now (ESTABLISHED sockets
    # whose local end is the port). Restarting then would cut off a request.
    result = subprocess.run(['lsof', '-nP', '-iTCP:%s' % port, '-sTCP:ESTABLISHED', '-Fn'],
                            text=True, capture_output=True)
    return any(line.startswith('n') and (':%s->' % port) in line for line in result.stdout.splitlines())


def stray(port, root):
    # Listeners that are an earlier EnMaaS proxy of this user whose state files
    # are gone: same uid, and the command line names this port's config under
    # <root> or the legacy runtime dir. Anything else is never touched.
    names = ('%s/config.json' % root, '%s/config.json' % legacy_runtime(port))
    found = set()
    for pid in listeners(port):
        result = subprocess.run(['ps', '-p', str(pid), '-o', 'uid=,command='], text=True, capture_output=True)
        uid, _, command = result.stdout.strip().partition(' ')
        if uid.strip() == str(os.getuid()) and any(name in command for name in names):
            try:
                found.add(os.getpgid(pid))
            except ProcessLookupError:
                pass
    return found


def stop_stray(groups, port, root):
    for group in groups:
        try:
            os.killpg(group, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline and stray(port, root):
        time.sleep(.1)
    for group in stray(port, root):
        os.killpg(group, signal.SIGKILL)


def child_serving(log):
    """True when the proxy.log (truncated at spawn, so it holds only the
    replacement's output) shows the startup line printed right before
    Serve() — binding the port is not serving."""
    try:
        with open(log, 'rb') as stream:
            return b'upstream retries off, limit rewrite=' in stream.read()
    except OSError:
        return False


def _port_conflict(log):
    """True when the child's log tail shows the port could not be bound (the
    pre-SO_REUSEPORT listener case), as opposed to any other boot failure."""
    try:
        with open(log, 'rb') as stream:
            stream.seek(0, os.SEEK_END)
            size = stream.tell()
            stream.seek(max(0, size - 4096))
            tail = stream.read().decode('utf-8', 'replace').lower()
    except OSError:
        return False
    return 'address already in use' in tail or 'cannot share the port' in tail


def wait_port_free(port):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and listeners(port):
        time.sleep(.1)


def owned(info):
    if not info or not isinstance(info.get('pid'), int) or not info.get('birth'):
        return False
    try:
        return birth(info['pid']) == info['birth'] and os.getpgid(info['pid']) == info['pid']
    except ProcessLookupError:
        return False


def ready(info, root):
    if not owned(info):
        return False
    pids = listeners(info['port'])
    if not pids:
        return False
    try:
        if any(os.getpgid(pid) != info['pid'] for pid in pids):
            return False
    except ProcessLookupError:
        return False
    request = urllib.request.Request('http://127.0.0.1:%s/v1/models' % info['port'],
                                     headers={'Authorization': 'Bearer ' + info['token']})
    try:
        with urllib.request.urlopen(request, timeout=2) as response:
            return isinstance(json.load(response).get('data'), list)
    except (OSError, ValueError, urllib.error.URLError):
        return False


def signature(key, token):
    return hmac.new(token.encode(), key.encode(), hashlib.sha256).hexdigest()


# The child is the Go proxy; these env prefixes reach it (knobs, usage log
# dir, search-MCP hint for the strip note).
CHILD_ENV_PREFIXES = ('HOSTED_ONLY_', 'GLM_HYBRID_', 'ENMAAS_RESPONSES_',
                      'ENMAAS_DNS_', 'LLM_USAGE_', 'T3_WEB_SEARCH_')


def go_impl():
    # The Go proxy is the only impl (the LiteLLM impl is retired; the openai
    # and vertex launchers still run LiteLLM for their own flavors). It serves
    # Claude Code over /v1/messages for every catalog model, GPT/Gemini
    # included, converting Messages <-> chat/Responses itself (translate*.go).
    # Mirrored by _claude_enmaas_impl in proxies.zsh.
    impl = (os.environ.get('CLAUDE_ENMAAS_PROXY_IMPL')
            or os.environ.get('LLM_PROXY_IMPL') or 'go').strip().lower()
    if impl not in ('', 'auto', 'go'):
        raise RuntimeError('the LiteLLM impl is retired; the Go proxy is the only impl '
                           '(install a go toolchain). CLAUDE_ENMAAS_PROXY_IMPL must be go, got %r' % impl)
    if not shutil.which('go'):
        raise RuntimeError('go not found (the Go proxy is the only impl; install a go toolchain)')
    return 'go'


def go_source():
    explicit = os.environ.get('CLAUDE_ENMAAS_GO_SRC')
    if not explicit:
        raise RuntimeError('CLAUDE_ENMAAS_GO_SRC is not set')
    return Path(explicit)


def go_source_hash(src):
    # The canonical Go source hash, identical to _hosted_only_go_hash in
    # scripts/hosted-only-proxy.zsh: sha256 over go.mod then every *.go in
    # C-locale (byte) order. Both launchers stamp the same source.sha, so a
    # different algorithm here made each alternating launch rebuild the binary.
    digest = hashlib.sha256()
    digest.update((src / 'go.mod').read_bytes())
    for path in sorted(src.glob('*.go'), key=lambda p: p.name.encode()):
        digest.update(path.read_bytes())
    return digest.hexdigest()


def go_binary():
    """Build (or reuse) the Go proxy; returns (binary path, source hash)."""
    src = go_source()
    out = Path(os.environ.get('XDG_STATE_HOME') or Path.home() / '.local' / 'state') / 'hosted-only-go'
    out.mkdir(mode=0o700, parents=True, exist_ok=True)
    want = go_source_hash(src)
    binary = out / 'hosted-only-proxy'
    stamp = out / 'source.sha'
    if not binary.is_file() or not stamp.is_file() or stamp.read_text().strip() != want:
        # Build to a private name and rename into place (the zsh launcher does
        # the same): go build -o removes and rewrites its target, so a hosted-
        # only launch execing the shared binary while this controller rebuilds
        # could otherwise run a half-written file.
        tmp = out / ('hosted-only-proxy.%d' % os.getpid())
        try:
            subprocess.run(['go', 'build', '-trimpath', '-o', str(tmp), '.'], cwd=str(src), check=True)
            tmp.chmod(0o700)
            os.replace(tmp, binary)
        finally:
            tmp.unlink(missing_ok=True)
        stamp.write_text(want)
    return str(binary), want


def stop(root, info, port=None):
    if not owned(info):
        groups = stray(port, root) if port is not None else set()
        if not groups:
            raise RuntimeError('no verified EnMaaS proxy; no process was stopped')
        stop_stray(groups, port, root)
        return
    # Only the process group started and recorded by this controller, never a
    # PID discovered by its port. Verify birth time again before escalation.
    os.killpg(info['pid'], signal.SIGTERM)
    # Longer than the Go proxy's 10 s graceful drain, so a SIGTERMed proxy
    # finishes its in-flight requests before this escalates to SIGKILL.
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline and owned(info):
        time.sleep(.1)
    if owned(info):
        os.killpg(info['pid'], signal.SIGKILL)
    if read_private(root / 'proxy.json') == info:
        (root / 'proxy.json').unlink(missing_ok=True)


def changes(info_root, info, root, config, versions, key, hooks, required):
    """What differs between the recorded proxy and this launch: a list of
    reasons (empty = up to date), the previous/proposed route maps and
    whether a required model's route changed."""
    old = read_private(info_root / 'config.json')
    previous = {r['model_name']: r['litellm_params'] for r in old['model_list']}
    proposed = {r['model_name']: r['litellm_params'] for r in config['model_list']}
    changed = []
    if (info['versions'] != versions or info['key_signature'] != signature(key, info['token'])
            or old['model_list'][0]['litellm_params']['api_base'] != config['model_list'][0]['litellm_params']['api_base']):
        changed.append('gateway/key or dependency settings')
    if info.get('hooks', '') != hooks:
        changed.append('hook code or knobs')
    if info_root != root:
        changed.append('runtime location')
    rerouted = any(proposed[model] != previous.get(model, dict(previous['*'], model=previous['*']['model'].replace('*', model)))
                   for model in required)
    if rerouted:
        changed.append('model routing')
    return changed, previous, proposed, rerouted


def knob_digest():
    """Stable digest of the knob env the child proxy reads. The Go source
    hash cannot see HOSTED_ONLY_VISION_FALLBACK & friends, so without this a
    knob change would leave check() reporting fresh and the running proxy
    serving the old value. HOSTED_ONLY_OUTAGE_STATE is controller-set per
    runtime dir (already covered by the runtime-location reason) and excluded.
    T3_WEB_SEARCH_* is ambient session wiring (an interactive shell exports
    it, the hourly timer's fleet-sync does not): hashing it made the timer
    and an interactive sync fight over the identity, restarting the proxy
    every cycle, so it is excluded too. Of the LLM_USAGE_* family only
    LLM_USAGE_DIR is a child knob (the usage log dir): the rest are tooling
    locators, and the menubar helper's launchd env exports LLM_USAGE_BIN —
    hashing it made every check run from that env (the float's detached
    status kick) report a terminal-launched proxy as 'gateway/key or
    dependency settings', a permanent false "update pending" (2026-11-11)."""
    items = sorted((k, v) for k, v in os.environ.items()
                   if ((k.startswith(CHILD_ENV_PREFIXES) and not k.startswith('LLM_USAGE_'))
                       or k == 'LLM_USAGE_DIR')
                   and k != 'HOSTED_ONLY_OUTAGE_STATE'
                   and not k.startswith('T3_WEB_SEARCH_'))
    return hashlib.sha256(repr(items).encode()).hexdigest()


def check(root, port, config, required):
    """Dry run for the restart-required check: {'state': down|fresh|stale,
    'changed': [...], 'busy': bool}; nothing is started, stopped or written."""
    go_impl()
    _, gohash = go_binary()
    versions = [gohash, knob_digest(), 'go']   # last element stays 'go': the zero-gap swap branch keys on it   # a list: the recorded identity holds one (argv slices were lists)
    info_root, info = locate(root, port)
    if not owned(info):
        if listeners(port):
            return {'state': 'stale', 'changed': ['no state files for the listener'], 'busy': busy(port)}
        return {'state': 'down', 'changed': [], 'busy': False}
    if not ready(info, info_root):
        return {'state': 'stale', 'changed': ['recorded proxy is not ready'], 'busy': busy(port)}
    changed, _, _, _ = changes(info_root, info, root, config, versions, os.environ['ENMAAS_API_KEY'],
                               gohash, required)
    return {'state': 'stale' if changed else 'fresh', 'changed': changed, 'busy': busy(port)}


def ensure(root, port, config, timeout, required):
    go_impl()
    gobin, gohash = go_binary()
    versions = [gohash, knob_digest(), 'go']   # last element stays 'go': the zero-gap swap branch keys on it   # a list: the recorded identity holds one (argv slices were lists)
    info_root, info = locate(root, port)
    key = os.environ['ENMAAS_API_KEY']
    hooks = gohash
    swap = None
    if owned(info):
        if not ready(info, info_root):
            raise RuntimeError('recorded proxy is not ready; run claude-enmaas-kill before relaunching')
        changed, previous, proposed, rerouted = changes(info_root, info, root, config, versions, key, hooks, required)
        forced = bool(os.environ.get('CLAUDE_ENMAAS_FORCE_RESTART'))
        if forced and not changed:
            changed = ['restart requested']
        if changed and (not busy(port) or forced):
            # Nobody is mid-request (or a swap is forced, which loses nothing):
            # apply the change now instead of refusing.
            if (info.get('versions') or ['', ''])[-1] == 'go':
                # Zero-refuse restart: the replacement starts ALONGSIDE the old
                # Go listener (both bind SO_REUSEPORT) and the old group is
                # retired only once the new one is up, so a request arriving
                # mid-restart is never refused. The token is kept so a client
                # that holds it is valid on either listener while both run.
                notice('%s changed; restarting the proxy (zero-gap swap)' % ', '.join(changed))
                swap = (info_root, info)
            else:
                notice('%s changed; restarting the idle proxy' % ', '.join(changed))
                stop(info_root, info, port)
                wait_port_free(port)
        elif rerouted:
            raise RuntimeError('model routing changed or is not loaded while the proxy is serving requests; '
                               'run claude-enmaas-restart once they finish')
        else:
            if changed:
                # Serving requests: keep the running proxy (it still works with
                # its older config) rather than fail this launch.
                notice('%s changed; the proxy is serving requests, so the running one is reused '
                       '(claude-enmaas-restart applies it now)' % ', '.join(changed))
            # Frozen routes remain authoritative; do not rewrite or restart a proxy
            # merely because discovery or one session's selected tier changed.
            return dict(info, runtime=str(info_root), models=[model for model, want in proposed.items()
                if previous.get(model, dict(previous['*'], model=previous['*']['model'].replace('*', model))) == want])
    if swap is None:
        groups = stray(port, root)
        if groups:
            if busy(port):
                raise RuntimeError('an earlier EnMaaS proxy without its state files is serving requests; '
                                   'run claude-enmaas-restart once they finish')
            notice('replacing an earlier EnMaaS proxy whose state files are gone')
            stop_stray(groups, port, root)
            wait_port_free(port)
        if listeners(port):
            raise RuntimeError('proxy port is occupied; refusing to adopt or stop its listener')
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                probe.bind(('127.0.0.1', port))
            except OSError:
                raise RuntimeError('proxy port is occupied; refusing to adopt or stop its listener')
    token = swap[1]['token'] if swap else 'sk-enmaas-' + secrets.token_hex(32)
    config['general_settings']['master_key'] = token
    write_private(root / 'config.json', config)
    # The Go proxy reads the generated config.json: model_list is its route
    # table (dialect, api_base, #responses siblings), master_key its local token.
    args = [gobin, '--flavor', 'enmaas', '--config', str(root / 'config.json'), '--port', str(port)]
    env = {k: v for k, v in os.environ.items() if k in
           ('PATH', 'HOME', 'TMPDIR', 'XDG_CACHE_HOME', 'XDG_STATE_HOME', 'LANG', 'LC_ALL')
           or k.startswith(CHILD_ENV_PREFIXES)}
    env.update(ENMAAS_API_KEY=key,
               # the Go proxy's outage backoff survives restarts via this file
               HOSTED_ONLY_OUTAGE_STATE=str(root / 'outage-streak.json'))
    # A boot failure (bad config, hook import error) must leave a trace.
    log = root / 'proxy.log'

    def spawn():
        logfd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        try:
            return subprocess.Popen(args, env=env, stdin=subprocess.DEVNULL, stdout=logfd,
                                    stderr=logfd, start_new_session=True)
        finally:
            os.close(logfd)

    def identity(process):
        return {'pid': process.pid, 'birth': birth(process.pid), 'port': port, 'token': token,
                'versions': versions, 'key_signature': signature(key, token), 'hooks': hooks}

    child = spawn()
    info = identity(child)
    if swap is not None:
        swap_root, swap_info = swap

        def accepting():
            # a listener whose process group is the new child's
            for pid in listeners(port):
                try:
                    if os.getpgid(pid) == child.pid:
                        return True
                except ProcessLookupError:
                    pass
            return False

        until = time.monotonic() + min(timeout, 30)
        while time.monotonic() < until and child.poll() is None and not accepting():
            time.sleep(.05)
        verified = False
        if child.poll() is None and accepting():
            # Binding the port is not serving: the replacement must reach its
            # serve loop before the healthy old proxy is retired (the log is
            # spawn-truncated, so the line can only be the new child's).
            until_ready = time.monotonic() + min(timeout, 30)
            while time.monotonic() < until_ready and child.poll() is None:
                if child_serving(log):
                    verified = True
                    break
                time.sleep(.1)
        if verified:
            write_private(root / 'proxy.json', info)
            # Retire the old group only now; the recorded identity is already
            # the new one, so never through stop() (it would unlink it). Signal
            # it only while it is still the verified old proxy: if it exited
            # during the replacement's startup its group id may have been reused
            # by an unrelated process.
            try:
                if owned(swap_info):
                    os.killpg(swap_info['pid'], signal.SIGTERM)
            except ProcessLookupError:
                pass
            # wait out the Go proxy's 10 s graceful drain before escalating
            until = time.monotonic() + 15
            while time.monotonic() < until and owned(swap_info):
                time.sleep(.05)
            if owned(swap_info):
                os.killpg(swap_info['pid'], signal.SIGKILL)
            if swap_root != root and read_private(swap_root / 'proxy.json') == swap_info:
                (swap_root / 'proxy.json').unlink(missing_ok=True)
        else:
            # The overlap start did not take. Only a confirmed port-sharing
            # failure (a Go build from before SO_REUSEPORT) justifies stopping
            # the WORKING old proxy for the legacy stop-then-start order; any
            # other failure keeps the old proxy serving and raises instead of
            # trading it for a start that already failed once.
            conflict = _port_conflict(log)
            if child.poll() is None:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if not conflict:
                raise RuntimeError('the replacement proxy failed to start; the old one keeps serving (see %s)' % log)
            notice('overlap start did not take (the old listener cannot share the port); stopping it first')
            stop(swap_root, swap_info, port)
            wait_port_free(port)
            swap = None
            child = spawn()
            info = identity(child)
    if swap is None:
        write_private(root / 'proxy.json', info)
    # Boot wait: a dot per second on stderr so the (up to `timeout` long)
    # litellm startup shows progress instead of a blank terminal.
    deadline = time.monotonic() + timeout
    ticks = 0
    try:
        while time.monotonic() < deadline:
            if ready(info, root):
                return dict(info, runtime=str(root), models=[row['model_name'] for row in config['model_list']])
            if child.poll() is not None:
                raise RuntimeError('standard LiteLLM proxy failed to start; see %s' % log)
            time.sleep(.2)
            ticks += 1
            if not ticks % 5:
                print('.', end='', flush=True, file=sys.stderr)
    finally:
        if ticks:
            print(file=sys.stderr)
    if child.poll() is not None:
        if owned(info):
            stop(root, info)
        raise RuntimeError('standard LiteLLM proxy failed to start; see %s' % log)
    # Deadline with a live child: it is still booting (a small host can need
    # 96 s+). Killing it just made the next launch start over; leave it, it
    # answers once up, and the health the launcher needs is only a poll away.
    print('still booting past the deadline; left running (see %s)' % log, file=sys.stderr)
    return dict(info, runtime=str(root), models=[row['model_name'] for row in config['model_list']])


if __name__ == '__main__':
    os.umask(0o077)
    try:
        op, port = sys.argv[1], int(sys.argv[2])
        root = runtime(port)
        fd = os.open(root / 'startup.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as lock:
            deadline = time.monotonic() + 60
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError('shared proxy startup lock timed out')
                    time.sleep(.1)
            if op == 'ensure':
                info = ensure(root, port, json.load(sys.stdin), int(sys.argv[3]), sys.argv[4:])
                print(json.dumps({'token': info['token'], 'runtime': info['runtime'], 'models': info['models']}))
            elif op == 'check':
                # Same argument layout as ensure (argv[3], the timeout, is unused).
                print(json.dumps(check(root, port, json.load(sys.stdin), sys.argv[4:])))
            elif op == 'stop':
                info_root, info = locate(root, port)
                stop(info_root, info, port)
            else:
                raise RuntimeError('invalid proxy operation')
    except Exception as error:
        print('claude-enmaas: ' + (str(error) if isinstance(error, RuntimeError) else 'proxy operation failed'), file=sys.stderr)
        sys.exit(1)
PY
}
