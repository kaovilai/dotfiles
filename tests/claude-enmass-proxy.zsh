#!/bin/zsh
# Real LiteLLM regression test with a loopback gateway and stub Claude client.
# Cache the pinned uv dependencies first; UV_OFFLINE=1 prevents network installs.
emulate -LR zsh
export ENMASS_TEST_REPO="${0:A:h:h}"
python3 - <<'PY'
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

records = []
class Gateway(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def json(self, data, status=200):
        payload = json.dumps(data).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def sse(self, text):
        payload = text.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == '/v1/responses/../models':
            if self.headers.get('Authorization') not in ('Bearer offline-key-a',):
                return self.json({'error': 'wrong key'}, 401)
            return self.json({'data': [{'id': 'gpt-6-luna'}]})
        if self.path != '/v1/models':
            return self.json({'error': 'unexpected catalog path'}, 404)
        native = self.headers.get('x-api-key') in ('offline-key-a',)
        if not native and self.headers.get('Authorization') not in ('Bearer offline-key-a',):
            return self.json({'error': 'wrong key'}, 401)
        data = [{'id': 'claude-sonnet-5-5'}, {'id': 'claude-opus-5-5'}, {'id': 'claude-haiku-4-5'}]
        if not native:
            data.append({'id': 'offline-chat'})
        self.json({'data': data, 'has_more': False})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        native = self.path == '/v1/messages'
        records.append({'path': self.path, 'model': body.get('model'),
                        'auth': self.headers.get('x-api-key') if native else self.headers.get('Authorization'),
                        'version': self.headers.get('anthropic-version'), 'stream': body.get('stream', False),
                        'credential_in_body': any(secret in json.dumps(body) for secret in ('offline-key-a', 'sk-enmass-'))})
        if body.get('model') == 'offline-error':
            return self.json({'error': {'message': 'fixture failure', 'type': 'invalid_request_error'}}, 400)
        if native:
            data = {'id': 'msg_fixture', 'type': 'message', 'role': 'assistant', 'model': body['model'],
                    'content': [{'type': 'text', 'text': 'hello'}], 'stop_reason': 'end_turn',
                    'stop_sequence': None, 'usage': {'input_tokens': 1, 'output_tokens': 1}}
            if body.get('stream'):
                events = [('message_start', {'type': 'message_start', 'message': dict(data, content=[], stop_reason=None)}),
                          ('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}}),
                          ('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'hello'}}),
                          ('content_block_stop', {'type': 'content_block_stop', 'index': 0}),
                          ('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn', 'stop_sequence': None}, 'usage': {'output_tokens': 1}}),
                          ('message_stop', {'type': 'message_stop'})]
                return self.sse(''.join('event: ' + e + '\ndata: ' + json.dumps(v) + '\n\n' for e, v in events))
            return self.json(data)
        if self.path == '/v1/chat/completions':
            if body.get('stream'):
                choices = [{'index': 0, 'delta': {'role': 'assistant', 'content': 'hello'}, 'finish_reason': None},
                           {'index': 0, 'delta': {}, 'finish_reason': 'stop'}]
                return self.sse(''.join('data: ' + json.dumps({'id': 'chat_fixture', 'object': 'chat.completion.chunk',
                    'created': 1, 'model': body['model'], 'choices': [c]}) + '\n\n' for c in choices) + 'data: [DONE]\n\n')
            message = {'role': 'assistant', 'content': 'hello'}
            finish = 'stop'
            if body.get('tools'):
                message = {'role': 'assistant', 'content': None, 'tool_calls': [{'id': 'call_fixture', 'type': 'function',
                           'function': {'name': 'fixture_tool', 'arguments': '{"ok":true}'}}]}
                finish = 'tool_calls'
            return self.json({'id': 'chat_fixture', 'object': 'chat.completion', 'created': 1, 'model': body['model'],
                              'choices': [{'index': 0, 'message': message, 'finish_reason': finish}],
                              'usage': {'prompt_tokens': 1, 'completion_tokens': 1, 'total_tokens': 2}})
        if self.path == '/v1/responses':
            return self.json({'id': 'resp_fixture', 'object': 'response', 'created_at': 1, 'status': 'completed',
                'model': body['model'], 'output': [{'type': 'message', 'id': 'msg_out', 'role': 'assistant', 'status': 'completed',
                'content': [{'type': 'output_text', 'text': 'hello', 'annotations': []}]}],
                'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}, 'error': None, 'incomplete_details': None,
                'parallel_tool_calls': True, 'tools': [], 'tool_choice': 'auto'})
        self.json({'error': 'unexpected path'}, 404)

stub = '''#!/usr/bin/env python3
import json, os, time, urllib.error, urllib.request
from pathlib import Path
base = os.environ['ANTHROPIC_BASE_URL']
token = os.environ['ANTHROPIC_AUTH_TOKEN']
print('SESSION_BASE:' + base, flush=True)
Path(os.environ['ENMASS_TEST_CLIENT_CAPTURE']).write_text(json.dumps({'base': base, 'token': token, 'settings': json.loads(__import__('sys').argv[2])}))
try:
    urllib.request.urlopen(urllib.request.Request(base + '/v1/models', headers={'Authorization': 'Bearer sk-invalid-token'}))
    raise AssertionError('unknown token accepted')
except urllib.error.HTTPError as e:
    # Database-free LiteLLM rejects non-master keys with its no-db error.
    error = json.load(e)
    assert e.code == 400 and error['error']['message'] == 'No connected db.', error
def request(model, **extra):
    body = {'model': model, 'max_tokens': 32, 'messages': [{'role': 'user', 'content': 'offline fixture'}], **extra}
    req = urllib.request.Request(base + '/v1/messages', data=json.dumps(body).encode(),
          headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json', 'anthropic-version': '2023-06-01'})
    return urllib.request.urlopen(req, timeout=25)
for model in ['claude-sonnet-5-5', 'offline-chat', 'offline-responses', 'gpt-6-luna', 'rits/zai-org/glm-5-3']:
    with request(model) as r: data = json.load(r)
    assert data['content'][0]['text'] == 'hello', (model, data)
for model in ['claude-sonnet-5-5', 'offline-chat']:
    with request(model, stream=True) as r: text = r.read().decode()
    assert 'hello' in text and 'message_stop' in text, (model, text)
with request('offline-chat', tools=[{'name': 'fixture_tool', 'description': 'offline',
     'input_schema': {'type': 'object', 'properties': {'ok': {'type': 'boolean'}}}}]) as r: data = json.load(r)
assert data['content'][0]['type'] == 'tool_use' and data['content'][0]['input'] == {'ok': True}, data
try:
    request('offline-error')
    raise AssertionError('upstream error lost')
except urllib.error.HTTPError as e:
    assert e.code == 400, e.code
print('PASS: all dialects, Messages/Chat streaming, tool conversion and HTTP error propagation', flush=True)
if os.environ['ENMASS_TEST_CLIENT_INDEX'] == '1':
    deadline = time.monotonic() + 30
    while not Path(os.environ['ENMASS_TEST_FIRST_EXIT']).exists():
        assert time.monotonic() < deadline, 'first client did not exit'
        time.sleep(.1)
    with request('offline-chat') as response:
        assert json.load(response)['content'][0]['text'] == 'hello'
    print('PASS: remaining Claude client works after its peer exits', flush=True)
'''

repo = Path(os.environ['ENMASS_TEST_REPO'])
gateway = ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
threading.Thread(target=gateway.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='enmass-real-tests-') as tmp:
        client = Path(tmp) / 'claude'
        client.write_text(stub)
        client.chmod(0o700)
        env = dict(os.environ)
        for key in list(env):
            if key.startswith(('ENMASS', 'CLAUDE_ENMASS')):
                env.pop(key)
        import socket
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            proxy_port = probe.getsockname()[1]
        env.update({'PATH': tmp + ':' + env['PATH'], 'ENMASS_TEST_REPO': str(repo),
                    'CLAUDE_ENMASS_PROXY_PORT': str(proxy_port),
                    'ENMASS_API_BASE_URL': f'http://127.0.0.1:{gateway.server_port}/v1', 'ENMASS_API_KEY': 'offline-key-a',
                    'CLAUDE_ENMASS_MODEL_DIALECTS': 'offline-responses=responses offline-error=chat', 'UV_OFFLINE': '1',
                    'ANTHROPIC_AUTH_TOKEN': 'parent-token', 'ANTHROPIC_API_KEY': 'parent-key',
                    'CLAUDE_CODE_USE_VERTEX': '1', 'CLAUDE_CODE_USE_BEDROCK': '1'})
        script = '''source "$ENMASS_TEST_REPO/zsh/functions/claude/load.zsh"
claude-enmass
result=$?
[[ $ANTHROPIC_AUTH_TOKEN == parent-token && $ANTHROPIC_API_KEY == parent-key && $CLAUDE_CODE_USE_VERTEX == 1 && $CLAUDE_CODE_USE_BEDROCK == 1 ]] || exit 99
exit $result
'''
        def launch(index):
            client_env = dict(env, ENMASS_TEST_CLIENT_INDEX=str(index),
                              ENMASS_TEST_FIRST_EXIT=str(Path(tmp) / 'first-exited'))
            client_env['ENMASS_TEST_CLIENT_CAPTURE'] = str(Path(tmp) / ('client-%s.json' % index))
            result = subprocess.run(['zsh', '-f', '-c', script], env=client_env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)
            if index == 0:
                (Path(tmp) / 'first-exited').touch()
            return result
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            runs = list(pool.map(launch, range(2)))
        bases = []
        for run in runs:
            print(run.stdout, end='')
            if run.stderr:
                print(run.stderr, end='')
            assert run.returncode == 0, run.returncode
            bases += [line for line in run.stdout.splitlines() if line.startswith('SESSION_BASE:')]
        assert len(set(bases)) == 1, bases
        captures = [json.loads((Path(tmp) / ('client-%s.json' % index)).read_text()) for index in range(2)]
        assert captures[0]['token'] == captures[1]['token'], 'sessions did not reuse shared proxy token'
        import urllib.request, urllib.error, time
        for capture in captures:
            with urllib.request.urlopen(urllib.request.Request(capture['base'] + '/v1/models',
                 headers={'Authorization': 'Bearer ' + capture['token']}), timeout=2) as response:
                assert response.status == 200, 'client exit stopped shared proxy'
        runtime = Path('/tmp') / ('claude-enmass-proxy-%s-%s' % (os.getuid(), proxy_port))
        info = json.loads((runtime / 'proxy.json').read_text())
        assert info['port'] == proxy_port and (runtime.stat().st_mode & 0o777) == 0o700
        assert not any('offline-key-' in p.read_text() for p in runtime.iterdir() if p.is_file())
        for r in records:
            assert not r['credential_in_body'], 'proxy credentials leaked into request JSON'
            assert r['auth'] in (('offline-key-a',) if r['path'] == '/v1/messages' else ('Bearer offline-key-a',)), r
            if r['path'] == '/v1/messages':
                assert r['version'], r
        expected = {'claude-sonnet-5-5': '/v1/messages', 'offline-chat': '/v1/chat/completions',
                    'offline-responses': '/v1/responses', 'gpt-6-luna': '/v1/responses',
                    'rits/zai-org/glm-5-3': '/v1/messages'}
        for model, endpoint in expected.items():
            assert any(r['model'] == model and r['path'] == endpoint for r in records), (model, endpoint)
        print('PASS: exact model IDs, per-model dialect authentication, shared standard proxy and parent environment isolation')
        stop = subprocess.run(['zsh', '-f', '-c', 'source "$ENMASS_TEST_REPO/zsh/functions/claude/providers/enmass.zsh"; claude-enmass-kill'],
                              env=env, text=True, capture_output=True, timeout=30)
        assert stop.returncode == 0, stop.stderr
finally:
    if 'env' in locals():
        subprocess.run(['zsh', '-f', '-c', 'source "$ENMASS_TEST_REPO/zsh/functions/claude/providers/enmass.zsh"; claude-enmass-kill'],
                       env=env, text=True, capture_output=True, timeout=30)
    gateway.shutdown()
PY
