#!/bin/zsh
# codex-t3-enmaas end to end, offline: the real launcher + real shared LiteLLM
# proxy (cached pinned deps, UV_OFFLINE=1) against a loopback fake gateway, with
# a stub `codex` that records what the launcher hands it. Asserts the launcher's
# -c overrides replace T3's direct-to-gateway launchArgs, the generated model
# catalog, and what the gateway actually receives for GLM, DeepSeek and GPT ids.
emulate -LR zsh
export ENMAAS_TEST_REPO="${0:A:h:h}"
python3 - <<'PY'
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GLM = 'rits/zai-org/glm-5-3'
DS = 'rits/deepseek-ai/DeepSeek-V4.1-Flash-1017'
records = []


class Gateway(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, data, status=200, headers=None, raw=None):
        payload = raw if raw is not None else json.dumps(data).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json' if raw is None else 'text/plain')
        self.send_header('Content-Length', str(len(payload)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == '/v1/responses/../models':
            return self.reply({'data': [{'id': 'gpt-5.5'}]})
        if self.path == '/v1/models':
            return self.reply({'data': [{'id': 'claude-sonnet-5-5'}], 'has_more': False})
        self.reply({'error': 'unexpected'}, 404)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        records.append({'path': self.path, 'body': body,
                        'auth': self.headers.get('Authorization') or self.headers.get('x-api-key')})
        if 'LIMIT' in json.dumps(body):
            return self.reply(None, 429, raw=b'token budget exhausted')
        if self.path == '/v1/messages':
            return self.reply({'id': 'msg_f', 'type': 'message', 'role': 'assistant', 'model': body['model'],
                'content': [{'type': 'text', 'text': 'hello'}], 'stop_reason': 'end_turn', 'stop_sequence': None,
                'usage': {'input_tokens': 1, 'output_tokens': 1}})
        if self.path == '/v1/responses':
            return self.reply({'id': 'resp_f', 'object': 'response', 'created_at': 1, 'status': 'completed',
                'model': body['model'], 'output': [{'type': 'message', 'id': 'msg_o', 'role': 'assistant',
                'status': 'completed', 'content': [{'type': 'output_text', 'text': 'hello', 'annotations': []}]}],
                'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}, 'error': None,
                'incomplete_details': None, 'parallel_tool_calls': True, 'tools': [], 'tool_choice': 'auto'})
        self.reply({'error': 'unexpected path'}, 404)


stub = r'''#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
if a == ['--version']:
    print('codex-cli 0.0.0-test'); sys.exit(0)
if a[:2] == ['debug', 'models']:
    print(json.dumps({'models': [{'slug': 'gpt-5.5', 'display_name': 'GPT-5.5', 'visibility': 'list', 'priority': 1,
        'input_modalities': ['text', 'image'], 'context_window': 272000, 'max_context_window': 272000,
        'tool_mode': 'code_mode_only', 'supports_search_tool': True, 'upgrade': {'model': 'x'},
        'auto_review_model_override': 'codex-auto-review'}]})); sys.exit(0)
json.dump({'argv': a, 'key': os.environ.get('ENMAAS_API_KEY')}, open(os.environ['STUB_CAPTURE'], 'w'))
'''

def stop_proxy():
    if env is not None:
        subprocess.run(['zsh', '-f', '-c', 'source "$ENMAAS_TEST_REPO/zsh/functions/claude/providers/enmaas.zsh"; claude-enmaas-kill'],
                       env=dict(env, ENMAAS_TEST_REPO=os.environ['ENMAAS_TEST_REPO']), text=True, capture_output=True, timeout=30)


launcher = Path(os.environ['ENMAAS_TEST_REPO']) / 'scripts' / 'codex-provider.zsh'
gateway = ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
threading.Thread(target=gateway.serve_forever, daemon=True).start()
env = None
try:
    with tempfile.TemporaryDirectory(prefix='codex-enmaas-tests-') as tmp:
        tmp = Path(tmp)
        (tmp / 'codex').write_text(stub)
        (tmp / 'codex').chmod(0o700)
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            proxy_port = probe.getsockname()[1]
        env = {k: v for k, v in os.environ.items() if not k.startswith(('ENMAAS', 'CLAUDE_ENMAAS', 'HOSTED_ONLY', 'GLM_HYBRID', 'CODEX_'))}
        env.update({'CODEX_PROVIDER_NATIVE_BINARY': str(tmp / 'codex'), 'STUB_CAPTURE': str(tmp / 'capture.json'),
                    'ENMAAS_API_BASE_URL': f'http://127.0.0.1:{gateway.server_port}/v1', 'ENMAAS_API_KEY': 'offline-key-a',
                    'CLAUDE_ENMAAS_PROXY_PORT': str(proxy_port), 'UV_OFFLINE': '1',
                    'XDG_STATE_HOME': str(tmp / 'state'), 'LLM_USAGE_DIR': str(tmp / 'usage')})
        t3_args = ['-c', 'model_provider="enmaas"', '-c', 'model_providers.enmaas.name="EnMaaS"',
                   '-c', 'model_providers.enmaas.base_url="https://api.enmaas.devshift.net/v1"',
                   '-c', 'model_providers.enmaas.env_key="ENMAAS_API_KEY"',
                   '-c', 'model_providers.enmaas.wire_api="responses"',
                   '-c', 'model_providers.enmaas.requires_openai_auth=false', '-c', 'model_context_window=1000000',
                   '-c', 'review_model="rits/zai-org/glm-5-3"', '-c', 'approvals_reviewer=auto_review']

        def launch(*args, **extra):
            (tmp / 'capture.json').unlink(missing_ok=True)
            result = subprocess.run(['zsh', '-f', str(launcher), 'enmaas', *args], env=dict(env, **extra),
                                    text=True, capture_output=True, timeout=240)
            assert result.returncode == 0, result.stderr
            return json.loads((tmp / 'capture.json').read_text())

        # 1. T3-style launch: ours replaces the direct provider keys, the rest stays.
        cap = launch('exec', *t3_args, '-m', GLM, 'a prompt')
        argv = cap['argv']
        assert argv[0] == 'exec' and argv[-3:] == ['-m', GLM, 'a prompt'], argv
        pairs = [argv[i + 1] for i, a in enumerate(argv) if a == '-c']
        keys = [p.split('=', 1)[0] for p in pairs]
        assert pairs.count('model_provider=enmaas') == 1 and keys.count('model_providers.enmaas.base_url') == 1, pairs
        assert not any('api.enmaas.devshift.net' in p or p == 'model_provider="enmaas"' for p in pairs), 'T3 direct base_url survived'
        base = next(p for p in pairs if p.startswith('model_providers.enmaas.base_url=')).split('=', 1)[1].strip('"')
        assert base == f'http://127.0.0.1:{proxy_port}/v1', base
        assert 'model_context_window=1000000' in pairs and 'approvals_reviewer=auto_review' in pairs
        assert 'review_model="rits/zai-org/glm-5-3"' in pairs, 'caller defaults must survive'
        catalog_arg = next(p for p in pairs if p.startswith('model_catalog_json='))
        token = cap['key']
        assert token and token != 'offline-key-a', 'Codex must get the proxy token, not the gateway key'
        catalog = json.loads(Path(catalog_arg.split('=', 1)[1].strip('"')).read_text())
        models = {m['slug']: m for m in catalog['models']}
        assert set(models) == {'gpt-5.5', GLM, DS}, set(models)
        assert models['gpt-5.5']['tool_mode'] == 'code_mode_only', 'bundled entries are kept untouched'
        assert models[GLM]['input_modalities'] == ['text'] and models[DS]['input_modalities'] == ['text', 'image']
        assert all(models[m]['tool_mode'] == 'direct' and models[m]['supports_search_tool'] is False for m in (GLM, DS))
        assert models[GLM]['auto_review_model_override'] == DS
        print('PASS: launcher overrides T3 launchArgs, keeps caller defaults, writes merged catalog')

        # --config=/-c= spellings and a bare invocation (no subcommand) are handled too.
        cap2 = launch('exec', '--config=model_providers.enmaas.base_url="https://elsewhere.example/v1"',
                      '--config', 'model_provider="other"', 'prompt')
        assert not any('elsewhere.example' in a or a == 'model_provider="other"' for a in cap2['argv']), cap2['argv']
        assert cap2['key'] == token, 'second launch must reuse the same proxy'
        cap3 = launch('--model', GLM)
        assert cap3['argv'][0] == '-c' and cap3['argv'][-2:] == ['--model', GLM], cap3['argv']

        def post(path, body, headers=None):
            req = urllib.request.Request(f'http://127.0.0.1:{proxy_port}{path}', data=json.dumps(body).encode(),
                headers={'Authorization': 'Bearer ' + token, 'x-api-key': token, 'anthropic-version': '2023-06-01',
                         'Content-Type': 'application/json', **(headers or {})})
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    return r.status, dict(r.headers), json.load(r)
            except urllib.error.HTTPError as e:
                return e.code, dict(e.headers), e.read().decode()

        tools = [{'type': 'custom', 'name': 'apply_patch', 'format': {'type': 'grammar', 'syntax': 'lark', 'definition': 'start: x'}},
                 {'type': 'web_search'}, {'type': 'function', 'name': 'f', 'parameters': {'type': 'object', 'properties': {}}}]
        responses_input = [{'role': 'developer', 'content': [{'type': 'input_text', 'text': ''}]},
                           {'role': 'user', 'content': [{'type': 'input_text', 'text': 'hi'}]}]

        # 2. Hosted vLLM models on /v1/responses: Responses passthrough with the workarounds applied.
        for model in (GLM, DS):
            records.clear()
            status, _, data = post('/v1/responses', {'model': model, 'input': responses_input, 'tools': tools})
            assert status == 200 and data['output'][0]['content'][0]['text'] == 'hello', (model, status, data)
            sent = records[-1]
            assert sent['path'] == '/v1/responses' and sent['body']['model'] == model, sent
            assert sent['auth'] == 'Bearer offline-key-a', 'gateway key must reach the gateway'
            sent_tools = sent['body']['tools']
            assert [t['type'] for t in sent_tools] == ['custom', 'function'], sent_tools
            assert 'format' not in sent_tools[0], 'grammar format must be stripped for vLLM'
            assert [i.get('role') for i in sent['body']['input']] == ['user'], 'empty developer item must be dropped'
        print('PASS: GLM and DeepSeek /v1/responses: passthrough, grammar strip, no web_search, no empty developer item')

        # 3. GPT is untouched: same tools, same input, its own id.
        records.clear()
        status, _, data = post('/v1/responses', {'model': 'gpt-5.5', 'input': responses_input, 'tools': tools})
        assert status == 200, (status, data)
        sent = records[-1]
        assert sent['path'] == '/v1/responses' and sent['body']['model'] == 'gpt-5.5', sent
        assert [t['type'] for t in sent['body']['tools']] == ['custom', 'web_search', 'function'], sent['body']['tools']
        assert sent['body']['tools'][0]['format']['type'] == 'grammar'
        print('PASS: GPT /v1/responses reaches the gateway unchanged')

        # 4. Claude Code flavor on the same port: Messages dialect, default thinking off on hosted models.
        for model in (GLM, DS):
            records.clear()
            status, _, data = post('/v1/messages', {'model': model, 'max_tokens': 16, 'messages': [{'role': 'user', 'content': 'hi'}]})
            assert status == 200 and data['content'][0]['text'] == 'hello', (model, status, data)
            assert records[-1]['path'] == '/v1/messages' and records[-1]['auth'] == 'offline-key-a'
            assert records[-1]['body'].get('thinking') == {'type': 'disabled'}, records[-1]['body']
        print('PASS: GLM and DeepSeek /v1/messages on the same proxy')

        # 5. EnMaaS 429 -> reset data Codex reads (x-codex-* headers, error.resets_at).
        status, headers, data = post('/v1/responses', {'model': GLM, 'input': [{'role': 'user', 'content': 'LIMIT'}]})
        low = {k.lower(): v for k, v in headers.items()}
        assert status == 429 and 'x-codex-primary-reset-at' in low and 'retry-after' in low, (status, low)
        assert json.loads(data)['error']['resets_at'] == int(low['x-codex-primary-reset-at']), data
        print('PASS: 429 rewritten with Codex reset headers')

        # 6. Opt-out: direct to the gateway with the caller's args and the real key.
        cap4 = launch('exec', *t3_args, CODEX_ENMAAS_DIRECT='1')
        assert cap4['argv'] == ['exec', *t3_args] and cap4['key'] == 'offline-key-a', cap4
        print('PASS: CODEX_ENMAAS_DIRECT=1 keeps the old direct behavior')
        stop_proxy()
finally:
    stop_proxy()
    gateway.shutdown()
PY
