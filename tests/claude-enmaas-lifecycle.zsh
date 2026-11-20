#!/bin/zsh
# One standard EnMaaS service (the Go proxy — the only impl), tested on
# fixture-owned ports. Skipped when `go` is not installed.
emulate -LR zsh
if ! command -v go >/dev/null; then
    print -ru2 -- "skip: go not installed"
    exit 0
fi
export ENMAAS_TEST_REPO="${0:A:h:h}"
python3 - <<'PY'
import concurrent.futures
import json
import os
from pathlib import Path
import runpy
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

repo = Path(os.environ['ENMAAS_TEST_REPO'])
env = dict(os.environ, ENMAAS_API_KEY='offline-lifecycle-key',
           CLAUDE_ENMAAS_GO_SRC=str(repo / 'scripts' / 'hosted-only-go'))
# subprocess env values must be strings: an unset XDG_STATE_HOME would put
# None into the child environment and every subprocess.run would TypeError.
if os.environ.get('CLAUDE_ENMAAS_RUNTIME_DIR'):
    env['XDG_STATE_HOME'] = os.environ['CLAUDE_ENMAAS_RUNTIME_DIR']
elif os.environ.get('XDG_STATE_HOME'):
    env['XDG_STATE_HOME'] = os.environ['XDG_STATE_HOME']


def wait_for(check, description, timeout=15):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if check():
            return
        time.sleep(.1)
    raise AssertionError(description)


with tempfile.TemporaryDirectory(prefix='enmaas-lifecycle-') as tmp:
    env['CLAUDE_ENMAAS_RUNTIME_DIR'] = str(Path(tmp) / 'state')
    os.environ['CLAUDE_ENMAAS_RUNTIME_DIR'] = env['CLAUDE_ENMAAS_RUNTIME_DIR']
    # Keep the child's usage tables (and the busy() reads below) inside the
    # fixture: LLM_USAGE_DIR is honored by both the Go child and the
    # controller's in-flight check. It must reach the test process's own
    # environment too — helper['busy'] resolves it from os.environ.
    env['LLM_USAGE_DIR'] = str(Path(tmp) / 'usage')
    os.environ['LLM_USAGE_DIR'] = env['LLM_USAGE_DIR']
    program = Path(tmp) / 'proxy.py'
    emitted = subprocess.run(['zsh', '-f', '-c',
        'source "$ENMAAS_TEST_REPO/zsh/functions/claude/providers/enmaas-proxy.zsh"; _claude_enmaas_proxy_program'],
        env=dict(env, ENMAAS_TEST_REPO=str(repo)), text=True, capture_output=True, check=True)
    program.write_text(emitted.stdout)
    program.chmod(0o600)
    helper = runpy.run_path(str(program))
    config = {'model_list': [{'model_name': model, 'litellm_params': {
        'model': route, 'api_base': 'http://127.0.0.1:1/v1', 'api_key': 'os.environ/ENMAAS_API_KEY'}}
        for model, route in [('*', 'openai/*'), ('offline-model', 'openai/offline-model')]],
        'general_settings': {'master_key': ''}, 'litellm_settings': {'drop_params': True}}

    def controller(op, port, value=config, required=('offline-model',), key=None):
        args = [str(port), '90', *required] if op == 'ensure' else [str(port)]
        return subprocess.run(['python3', str(program), op, *args],
            env=dict(env, ENMAAS_API_KEY=key or env['ENMAAS_API_KEY']), input=json.dumps(value),
            text=True, capture_output=True, timeout=110)

    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        port = listener.getsockname()[1]
        result = controller('ensure', port)
        assert result.returncode != 0 and 'refusing to adopt' in result.stderr, result.stderr
        result = controller('stop', port)
        assert result.returncode != 0 and 'no process was stopped' in result.stderr, result.stderr
        with socket.create_connection(('127.0.0.1', port), timeout=2):
            pass
    print('PASS: unrelated listener is neither adopted nor stopped')

    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    root = Path(env['CLAUDE_ENMAAS_RUNTIME_DIR']) / ('claude-enmaas-proxy-%s-%s' % (os.getuid(), port))
    info = None
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: controller('ensure', port), range(2)))
        assert all(r.returncode == 0 for r in results), [r.stderr for r in results]
        assert len({json.loads(r.stdout)['token'] for r in results}) == 1
        info = json.loads((root / 'proxy.json').read_text())
        original_pid, original_token = info['pid'], info['token']
        original_config = (root / 'config.json').read_bytes()
        assert 'offline-lifecycle-key' not in original_config.decode()
        assert helper['ready'](info, root)
        print('PASS: concurrent launch reuses one standard proxy and token')

        # Selection/discovery changes don't rewrite or restart existing routes.
        changed = json.loads(json.dumps(config))
        changed['model_list'].append({'model_name': 'new-chat', 'litellm_params': {
            'model': 'openai/new-chat', 'api_base': 'http://127.0.0.1:1/v1',
            'api_key': 'os.environ/ENMAAS_API_KEY'}})
        reused = controller('ensure', port, changed, ('new-chat',))
        assert reused.returncode == 0, reused.stderr
        assert json.loads((root / 'proxy.json').read_text())['pid'] == original_pid
        assert (root / 'config.json').read_bytes() == original_config
        changed['model_list'][-1]['litellm_params']['model'] = 'openai/responses/new-chat'
        # Serving = a request actually in flight, reported by the Go child's
        # usage table — not an open client socket: idle keep-alive connections
        # must not hold restarts back (the Go lifecycle reads the same tables).
        usage_dir = Path(env['LLM_USAGE_DIR'])
        child_inflight = usage_dir / ('inflight-%s-%s.json' % (port, info['pid']))
        wait_for(child_inflight.exists, 'the Go child did not write its (empty) in-flight table at startup')
        assert not helper['busy'](port), 'a live reporter with an empty table must read idle'
        with socket.create_connection(('127.0.0.1', port), timeout=2):
            assert not helper['busy'](port), 'an idle client connection is not a request in flight'
        # Fake the busy state as a SECOND live reporter owned by this test
        # process's pid instead of overwriting the child's table: the child's
        # 30 s idle heartbeat republishes its own file, which would race the
        # restore below. busy() merges live reporters — any non-empty table
        # reads busy — and the heartbeat never touches this file.
        fake_reporter = usage_dir / ('inflight-%s-%d.json' % (port, os.getpid()))
        helper['write_private'](fake_reporter, {'pid': os.getpid(), 'port': port,
            'updated': time.time(), 'requests': {'r1': {'t': time.time(),
            'model': 'offline-model', 'requested': 'offline-model'}}})
        wait_for(lambda: helper['busy'](port), 'a live reporter with a request must read busy')
        rejected = controller('ensure', port, changed, ('new-chat',))
        assert rejected.returncode != 0 and 'routing changed' in rejected.stderr, rejected.stderr
        reused = controller('ensure', port, key='different-key')
        assert reused.returncode == 0 and 'serving requests' in reused.stderr, reused.stderr
        assert json.loads((root / 'proxy.json').read_text())['pid'] == original_pid
        fake_reporter.unlink(missing_ok=True)
        wait_for(lambda: not helper['busy'](port), 'removing the fake reporter still read busy')
        assert helper['ready'](info, root), 'config mismatch stopped a busy service'
        print('PASS: busy (in-flight) proxy is reused on key change; incompatible routing requires explicit restart')

        # Idle: the same key change swaps the proxy (zero-gap; the Go swap
        # keeps the token so a client holding it stays valid on either listener).
        wait_for(lambda: not helper['busy'](port), 'closed client connection still busy')
        restarted = controller('ensure', port, key='different-key')
        assert restarted.returncode == 0 and 'zero-gap swap' in restarted.stderr, restarted.stderr
        info = json.loads((root / 'proxy.json').read_text())
        assert info['pid'] != original_pid and info['token'] == original_token
        original_pid, original_token = info['pid'], info['token']
        print('PASS: idle proxy swaps on key change, token kept')

        # Kill only the recorded, birth-time-verified group owned by this fixture.
        assert helper['owned'](info)
        os.killpg(info['pid'], signal.SIGKILL)
        wait_for(lambda: not helper['owned'](info), 'owned crash not observed')
        restarted = controller('ensure', port)
        assert restarted.returncode == 0, restarted.stderr
        info = json.loads((root / 'proxy.json').read_text())
        assert info['pid'] != original_pid and info['token'] != original_token
        try:
            urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:%s/v1/models' % port,
                headers={'Authorization': 'Bearer ' + original_token}), timeout=2)
            raise AssertionError('old proxy token accepted')
        except urllib.error.HTTPError as error:
            body = json.load(error)
            assert (error.code, body['error']['message']) == (401, 'invalid proxy token'), (error.code, body)
        print('PASS: crash/restart uses new identity and rejects old token')

        stopped = controller('stop', port)
        assert stopped.returncode == 0, stopped.stderr
        wait_for(lambda: not helper['listeners'](port), 'explicit stop left listener')
        assert not (root / 'proxy.json').exists()
        print('PASS: verified explicit stop removes proxy identity')
    finally:
        if info is not None and (root / 'proxy.json').exists():
            current = json.loads((root / 'proxy.json').read_text())
            if current['pid'] == info['pid'] and current['birth'] == info['birth']:
                controller('stop', port)
PY
