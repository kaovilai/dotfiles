#!/bin/zsh
# One standard LiteLLM service, tested on fixture-owned ports with cached deps.
emulate -LR zsh
export ENMASS_TEST_REPO="${0:A:h:h}"
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

repo = Path(os.environ['ENMASS_TEST_REPO'])
env = dict(os.environ, UV_OFFLINE='1', ENMASS_API_KEY='offline-lifecycle-key')


def wait_for(check, description, timeout=15):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if check():
            return
        time.sleep(.1)
    raise AssertionError(description)


with tempfile.TemporaryDirectory(prefix='enmass-lifecycle-') as tmp:
    program = Path(tmp) / 'proxy.py'
    emitted = subprocess.run(['zsh', '-f', '-c',
        'source "$ENMASS_TEST_REPO/zsh/functions/enmass-proxy.zsh"; _claude_enmass_proxy_program'],
        env=dict(env, ENMASS_TEST_REPO=str(repo)), text=True, capture_output=True, check=True)
    program.write_text(emitted.stdout)
    program.chmod(0o600)
    helper = runpy.run_path(str(program))
    config = {'model_list': [{'model_name': model, 'litellm_params': {
        'model': route, 'api_base': 'http://127.0.0.1:1/v1', 'api_key': 'os.environ/ENMASS_API_KEY'}}
        for model, route in [('*', 'openai/*'), ('offline-model', 'openai/offline-model')]],
        'general_settings': {'master_key': ''}, 'litellm_settings': {'drop_params': True}}

    def controller(op, port, value=config, required=('offline-model',), key=None):
        args = [str(port), '1.97.0', '0.136.3', '90', *required] if op == 'ensure' else [str(port)]
        return subprocess.run(['python3', str(program), op, *args],
            env=dict(env, ENMASS_API_KEY=key or env['ENMASS_API_KEY']), input=json.dumps(value),
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
    root = Path('/tmp') / ('claude-enmass-proxy-%s-%s' % (os.getuid(), port))
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
            'api_key': 'os.environ/ENMASS_API_KEY'}})
        reused = controller('ensure', port, changed, ('new-chat',))
        assert reused.returncode == 0, reused.stderr
        assert json.loads((root / 'proxy.json').read_text())['pid'] == original_pid
        assert (root / 'config.json').read_bytes() == original_config
        changed['model_list'][-1]['litellm_params']['model'] = 'openai/responses/new-chat'
        rejected = controller('ensure', port, changed, ('new-chat',))
        assert rejected.returncode != 0 and 'routing changed' in rejected.stderr, rejected.stderr
        rejected = controller('ensure', port, key='different-key')
        assert rejected.returncode != 0 and 'gateway/key' in rejected.stderr, rejected.stderr
        assert helper['ready'](info, root), 'config mismatch stopped existing service'
        print('PASS: selection changes reuse; incompatible routing/key requires explicit restart')

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
            assert error.code == 400 and body['error']['message'] == 'No connected db.', body
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
