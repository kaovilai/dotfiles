# One-shot lifecycle controller for the standard shared LiteLLM CLI proxy.
# No request server, tenant registry or session leases live here.
_claude_enmaas_proxy_program() {
    command cat <<'PY'
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


def runtime(port):
    root = Path('/tmp') / ('claude-enmaas-proxy-%s-%s' % (os.getuid(), port))
    root.mkdir(mode=0o700, exist_ok=True)
    st = root.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise RuntimeError('unsafe proxy runtime directory')
    return root


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


def hook_digest(files):
    # Hook code and the knobs the hooks read; a change needs a proxy restart.
    if not files:
        return ''
    digest = hashlib.sha256()
    for path in files:
        digest.update(path.name.encode() + b'\0' + path.read_bytes() + b'\0')
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


def stop(root, info):
    if not owned(info):
        raise RuntimeError('no verified EnMaaS proxy; no process was stopped')
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


def ensure(root, port, config, versions, timeout, required):
    info = read_private(root / 'proxy.json')
    key = os.environ['ENMAAS_API_KEY']
    files = hook_files()
    hooks = hook_digest(files)
    if owned(info):
        if not ready(info, root):
            raise RuntimeError('recorded proxy is not ready; run claude-enmaas-kill before relaunching')
        old = read_private(root / 'config.json')
        if (info['versions'] != versions or info['key_signature'] != signature(key, info['token'])
                or old['model_list'][0]['litellm_params']['api_base'] != config['model_list'][0]['litellm_params']['api_base']):
            raise RuntimeError('shared gateway/key or dependency settings changed; run claude-enmaas-kill and relaunch')
        if info.get('hooks', '') != hooks:
            raise RuntimeError('proxy hook code or knobs changed; run claude-enmaas-kill and relaunch')
        previous = {r['model_name']: r['litellm_params'] for r in old['model_list']}
        proposed = {r['model_name']: r['litellm_params'] for r in config['model_list']}
        for model in required:
            want = proposed[model]
            actual = previous.get(model, dict(previous['*'], model=previous['*']['model'].replace('*', model)))
            if actual != want:
                raise RuntimeError('model routing changed or is not loaded; run claude-enmaas-kill and relaunch')
        # Frozen routes remain authoritative; do not rewrite or restart a proxy
        # merely because discovery or one session's selected tier changed.
        return dict(info, models=[model for model, want in proposed.items()
            if previous.get(model, dict(previous['*'], model=previous['*']['model'].replace('*', model))) == want])
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
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if ready(info, root):
            return dict(info, models=[row['model_name'] for row in config['model_list']])
        if child.poll() is not None:
            raise RuntimeError('standard LiteLLM proxy failed to start; see %s' % log)
        time.sleep(.2)
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
                print(json.dumps({'token': info['token'], 'runtime': str(root), 'models': info['models']}))
            elif op == 'stop':
                stop(root, read_private(root / 'proxy.json'))
            else:
                raise RuntimeError('invalid proxy operation')
    except Exception as error:
        print('claude-enmaas: ' + (str(error) if isinstance(error, RuntimeError) else 'proxy operation failed'), file=sys.stderr)
        sys.exit(1)
PY
}
