# One-shot lifecycle controller for the standard shared LiteLLM CLI proxy.
# No request server, tenant registry or session leases live here.
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


# Hook modules (CLAUDE_ENMAAS_HOOK_FILES, newline separated absolute paths, in
# callback order) are copied next to the config and loaded as dotted modules:
# LiteLLM splits a callback on '.', so a file path or `file.py:name` cannot work.
HOOK_ENV_PREFIXES = ('HOSTED_ONLY_', 'GLM_HYBRID_', 'ENMAAS_RESPONSES_')
CHILD_ENV_PREFIXES = HOOK_ENV_PREFIXES + ('LLM_USAGE_',)


def hook_files():
    return [Path(p) for p in os.environ.get('CLAUDE_ENMAAS_HOOK_FILES', '').split('\n') if p]


def code_text(path):
    # What the proxy actually runs: the AST without comments, docstrings or
    # formatting, so editing a comment does not count as a hook change.
    data = path.read_bytes()
    if path.suffix != '.py':
        return data
    try:
        tree = ast.parse(data)
    except SyntaxError:
        return data
    for node in ast.walk(tree):
        body = getattr(node, 'body', None)
        if (isinstance(body, list) and body and isinstance(body[0], ast.Expr)
                and isinstance(body[0].value, ast.Constant) and isinstance(body[0].value.value, str)):
            node.body = body[1:] or [ast.Pass()]
    return ast.dump(tree).encode()


def hook_digest(files):
    # Hook code and the knobs the hooks read; a change needs a proxy restart.
    if not files:
        return ''
    digest = hashlib.sha256()
    for path in files:
        digest.update(path.name.encode() + b'\0' + code_text(path) + b'\0')
    for name in sorted(os.environ):
        if name.startswith(HOOK_ENV_PREFIXES):
            digest.update(('%s=%s\0' % (name, os.environ[name])).encode())
    return digest.hexdigest()


def install_hooks(root, files):
    for path in files:
        fd = os.open(root / path.name, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(path.read_bytes())
    return [path.stem + '.proxy_handler_instance' for path in files]


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
    deadline = time.monotonic() + 8
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


def check(root, port, config, versions, required):
    """Dry run for `llm-proxy-restart required`: {'state': down|fresh|stale,
    'changed': [...], 'busy': bool}; nothing is started, stopped or written."""
    info_root, info = locate(root, port)
    if not owned(info):
        if listeners(port):
            return {'state': 'stale', 'changed': ['no state files for the listener'], 'busy': busy(port)}
        return {'state': 'down', 'changed': [], 'busy': False}
    if not ready(info, info_root):
        return {'state': 'stale', 'changed': ['recorded proxy is not ready'], 'busy': busy(port)}
    changed, _, _, _ = changes(info_root, info, root, config, versions, os.environ['ENMAAS_API_KEY'],
                               hook_digest(hook_files()), required)
    return {'state': 'stale' if changed else 'fresh', 'changed': changed, 'busy': busy(port)}


def ensure(root, port, config, versions, timeout, required):
    info_root, info = locate(root, port)
    key = os.environ['ENMAAS_API_KEY']
    files = hook_files()
    hooks = hook_digest(files)
    if owned(info):
        if not ready(info, info_root):
            raise RuntimeError('recorded proxy is not ready; run claude-enmaas-kill before relaunching')
        changed, previous, proposed, rerouted = changes(info_root, info, root, config, versions, key, hooks, required)
        if changed and not busy(port):
            # Nobody is mid-request: apply the change now instead of refusing.
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
    token = 'sk-enmaas-' + secrets.token_hex(32)
    config['general_settings']['master_key'] = token
    if files:
        config.setdefault('litellm_settings', {})['callbacks'] = install_hooks(root, files)
    write_private(root / 'config.json', config)
    args = ['uv', 'tool', 'run', '--with', 'fastapi==' + versions[1],
            '--from', 'litellm[proxy]==' + versions[0], 'litellm',
            '--config', str(root / 'config.json'), '--host', '127.0.0.1', '--port', str(port),
            '--telemetry', 'False']
    env = {k: v for k, v in os.environ.items() if k in
           ('PATH', 'HOME', 'TMPDIR', 'UV_CACHE_DIR', 'UV_OFFLINE', 'XDG_CACHE_HOME', 'XDG_STATE_HOME', 'LANG', 'LC_ALL')
           or k.startswith(CHILD_ENV_PREFIXES)}
    env.update(ENMAAS_API_KEY=key, LITELLM_LOG=os.environ.get('CLAUDE_ENMAAS_LITELLM_LOG') or 'ERROR')
    # A boot failure (bad config, hook import error) must leave a trace.
    log = root / 'proxy.log'
    logfd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    try:
        child = subprocess.Popen(args, env=env, stdin=subprocess.DEVNULL, stdout=logfd,
                                 stderr=logfd, start_new_session=True)
    finally:
        os.close(logfd)
    info = {'pid': child.pid, 'birth': birth(child.pid), 'port': port, 'token': token,
            'versions': versions, 'key_signature': signature(key, token), 'hooks': hooks}
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
    if owned(info):
        stop(root, info)
    raise RuntimeError('standard LiteLLM proxy startup timed out; see %s' % log)


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
                info = ensure(root, port, json.load(sys.stdin), sys.argv[3:5], int(sys.argv[5]), sys.argv[6:])
                print(json.dumps({'token': info['token'], 'runtime': info['runtime'], 'models': info['models']}))
            elif op == 'check':
                # Same argument layout as ensure (argv[5], the timeout, is unused).
                print(json.dumps(check(root, port, json.load(sys.stdin), sys.argv[3:5], sys.argv[6:])))
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
