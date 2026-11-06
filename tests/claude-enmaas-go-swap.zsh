#!/bin/zsh
# EnMaaS controller + the real Go proxy: zero-refuse restarts. The controller
# starts the replacement ALONGSIDE the old Go listener (SO_REUSEPORT), keeps the
# token, and retires the old group once the new one is up; an old listener that
# cannot share the port falls back to stop-then-start once. No network, no
# LiteLLM: a stub gateway stands in for EnMaaS. Skipped when `go` is missing.
emulate -LR zsh
if ! command -v go >/dev/null; then
    print -ru2 -- "skip: go not installed"
    exit 0
fi
export ENMAAS_TEST_REPO="${0:A:h:h}"
python3 - <<'PY'
import json
import os
from pathlib import Path
import runpy
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

repo = Path(os.environ['ENMAAS_TEST_REPO'])


def wait_for(check, description, timeout=20):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if check():
            return
        time.sleep(.05)
    raise AssertionError(description)


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


class Gateway(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        payload = json.dumps({'id': 'm', 'type': 'message', 'content': [], 'usage': {'input_tokens': 1, 'output_tokens': 1}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


gateway = ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
threading.Thread(target=gateway.serve_forever, daemon=True).start()
gateway_url = 'http://127.0.0.1:%d' % gateway.server_address[1]

with tempfile.TemporaryDirectory(prefix='enmaas-go-swap-', dir=os.environ.get('TMPDIR')) as tmp:
    state = Path(tmp) / 'state'
    env = dict(os.environ, ENMAAS_API_KEY='offline-swap-key', CLAUDE_ENMAAS_PROXY_IMPL='go',
               CLAUDE_ENMAAS_GO_SRC=str(repo / 'scripts' / 'hosted-only-go'),
               CLAUDE_ENMAAS_RUNTIME_DIR=str(state), XDG_STATE_HOME=str(state),
               LLM_USAGE_DIR=str(Path(tmp) / 'usage'))
    os.environ.update(env)
    program = Path(tmp) / 'proxy.py'
    emitted = subprocess.run(['zsh', '-f', '-c',
        'source "$ENMAAS_TEST_REPO/zsh/functions/claude/providers/enmaas-proxy.zsh"; _claude_enmaas_proxy_program'],
        env=env, text=True, capture_output=True, check=True)
    program.write_text(emitted.stdout)
    program.chmod(0o600)
    helper = runpy.run_path(str(program))
    config = {'model_list': [{'model_name': model, 'litellm_params': {
        'model': route, 'api_base': gateway_url, 'api_key': 'os.environ/ENMAAS_API_KEY'}}
        for model, route in [('*', 'anthropic/*'), ('offline-model', 'anthropic/offline-model')]],
        'general_settings': {'master_key': ''}, 'litellm_settings': {'drop_params': True}}

    def controller(op, port, key=None, extra=None):
        args = [str(port), 'unused', 'unused', '90', 'offline-model'] if op == 'ensure' else [str(port)]
        run_env = dict(env, ENMAAS_API_KEY=key or env['ENMAAS_API_KEY'], **(extra or {}))
        return subprocess.run(['python3', str(program), op, *args], env=run_env, input=json.dumps(config),
                              text=True, capture_output=True, timeout=120)

    port = free_port()
    root = state / ('claude-enmaas-proxy-%s-%s' % (os.getuid(), port))
    try:
        first = controller('ensure', port)
        assert first.returncode == 0, first.stderr
        info1 = json.loads((root / 'proxy.json').read_text())
        assert info1['versions'][-1] == 'go', info1
        token = json.loads(first.stdout)['token']
        print('PASS: the controller starts the Go proxy')

        # A probe running every 30 ms through the whole swap must never be refused.
        refused, stop_probe = [], threading.Event()

        def probe():
            request = urllib.request.Request('http://127.0.0.1:%d/v1/models' % port,
                                             headers={'Authorization': 'Bearer ' + token})
            while not stop_probe.is_set():
                try:
                    with urllib.request.urlopen(request, timeout=2) as response:
                        response.read()
                except (OSError, urllib.error.URLError) as error:
                    refused.append(repr(error))
                time.sleep(.03)

        prober = threading.Thread(target=probe, daemon=True)
        prober.start()
        # keep an (empty) in-flight table so the idle check reads idle between probes
        usage = Path(env['LLM_USAGE_DIR'])
        swapped = controller('ensure', port, key='different-key')
        stop_probe.set()
        prober.join(5)
        assert swapped.returncode == 0, swapped.stderr
        assert 'zero-gap swap' in swapped.stderr, swapped.stderr
        assert 'overlap start did not take' not in swapped.stderr, swapped.stderr
        info2 = json.loads((root / 'proxy.json').read_text())
        assert info2['pid'] != info1['pid'], 'the proxy was not replaced'
        assert info2['token'] == token, 'the swap must keep the token'
        assert json.loads(swapped.stdout)['token'] == token
        wait_for(lambda: not helper['owned'](info1), 'the old group was not retired')
        assert len(helper['listeners'](port)) == 1, helper['listeners'](port)
        assert helper['ready'](info2, root)
        assert not refused, 'the swap refused %d probe(s): %s' % (len(refused), refused[:2])
        print('PASS: an idle Go proxy swaps without refusing a request, token kept')

        # A forced restart with nothing changed swaps too (the restart command's path).
        forced = controller('ensure', port, key='different-key', extra={'CLAUDE_ENMAAS_FORCE_RESTART': '1'})
        assert forced.returncode == 0 and 'zero-gap swap' in forced.stderr, forced.stderr
        info3 = json.loads((root / 'proxy.json').read_text())
        assert info3['pid'] != info2['pid']
        wait_for(lambda: not helper['owned'](info2), 'the forced swap did not retire the old group')
        print('PASS: a forced restart swaps')

        # An old listener that cannot share the port (no SO_REUSEPORT): the new
        # process exits at bind and the controller falls back to stop-then-start.
        assert controller('stop', port).returncode == 0
        wait_for(lambda: not helper['listeners'](port), 'stop left a listener')

        class Models(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                payload = json.dumps({'data': [{'id': 'offline-model'}]}).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        fake_server = Path(tmp) / 'fake_old.py'
        fake_server.write_text(
            'import json, sys\n'
            'from http.server import BaseHTTPRequestHandler, HTTPServer\n'
            'class H(BaseHTTPRequestHandler):\n'
            '    def log_message(self, *a): pass\n'
            '    def do_GET(self):\n'
            '        p = json.dumps({"data": [{"id": "offline-model"}]}).encode()\n'
            '        self.send_response(200); self.send_header("Content-Length", str(len(p))); self.end_headers(); self.wfile.write(p)\n'
            'HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()\n')
        old = subprocess.Popen([sys.executable, str(fake_server), str(port)], start_new_session=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for(lambda: helper['listeners'](port), 'fake old listener did not start')
        old_token = 'sk-enmaas-' + 'a' * 64
        legacy_config = json.loads(json.dumps(config))
        legacy_config['general_settings']['master_key'] = old_token
        root.mkdir(mode=0o700, exist_ok=True)
        helper['write_private'](root / 'config.json', legacy_config)
        legacy_info = {'pid': old.pid, 'birth': helper['birth'](old.pid), 'port': port, 'token': old_token,
                       'versions': ['stale-hash', 'go'], 'key_signature': 'stale', 'hooks': 'stale'}
        helper['write_private'](root / 'proxy.json', legacy_info)
        assert helper['owned'](legacy_info)
        fallback = controller('ensure', port)
        assert fallback.returncode == 0, fallback.stderr
        assert 'overlap start did not take' in fallback.stderr, fallback.stderr
        info4 = json.loads((root / 'proxy.json').read_text())
        assert info4['pid'] != old.pid and info4['token'] != old_token or info4['pid'] != old.pid
        wait_for(lambda: old.poll() is not None, 'the legacy listener was not stopped')
        assert helper['ready'](info4, root)
        print('PASS: a listener that cannot share the port falls back to stop-then-start')
    finally:
        controller('stop', port)
        gateway.shutdown()
PY
