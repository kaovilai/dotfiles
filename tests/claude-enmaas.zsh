#!/bin/zsh
# Offline unit/launcher contracts. All curl and daemon operations are mocked;
# no listener is started, inspected, adopted or shut down by this suite.
emulate -LR zsh
setopt err_exit pipe_fail
umask 077
local repo="${0:A:h:h}" tmp run_pid=''
tmp=$(mktemp -d "${TMPDIR:-/tmp}/claude-enmaas-tests.XXXXXXXX")
trap '[[ -n "$run_pid" ]] && kill -TERM "$run_pid" 2>/dev/null; rm -rf -- "$tmp"' EXIT

# Load actual shared helpers without unrelated wrapper startup configuration.
source <(python3 - "$repo/zsh/functions/claude/common.zsh" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
for name in ('_claude_copilot_latest_model', '_claude_picker_args', '_claude_copilot_unset_env', '_claude_invoke'):
    print(re.search(r'^' + name + r'\(\) \{\n.*?^\}', s, re.M | re.S).group())
print(re.search(r'^typeset -ga _claude_copilot_env_names=\(\n.*?^\)', s, re.M | re.S).group())
PY
)
source "$repo/zsh/functions/claude/providers/enmaas.zsh"
# Preserve the real emitted helper for isolated Python tests, then replace the
# launcher seam before any claude-enmaas call can reach an actual daemon.
_claude_enmaas_proxy_program > "$tmp/actual-daemon.py"

python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); (p/'bin').mkdir()
files = {
'mock-daemon.py': r'''import json, os, secrets, sys
from pathlib import Path
p = Path(os.environ['ENMAAS_TEST_CAPTURE'])
op = sys.argv[1]
if op == 'ensure':
 config = json.load(sys.stdin)
 token = 'sk-enmaas-' + secrets.token_hex(8)
 (p/'ensure.json').write_text(json.dumps({'argv':sys.argv[2:]}))
 (p/'registration.json').write_text(json.dumps({'token':token, 'model_list':config['model_list'], 'config':config,
     'upstream_key':os.environ['ENMAAS_API_KEY'],
     'hook_files':os.environ.get('CLAUDE_ENMAAS_HOOK_FILES'), 'routes':os.environ.get('ENMAAS_RESPONSES_ROUTES')}))
 (p/'session-path').write_text(str(Path(__file__).parent))
 (p/'program-mode').write_text(oct(Path(__file__).stat().st_mode & 0o777))
 (p/'directory-mode').write_text(oct(Path(__file__).parent.stat().st_mode & 0o777))
 if os.environ.get('ENMAAS_TEST_ENSURE_FAIL') == '1': sys.exit(51)
 print(json.dumps({'token':token, 'runtime':str(p/'runtime'), 'models':[r['model_name'] for r in config['model_list']]}))
else:
 raise AssertionError('test mock prohibits every operation but ensure')
''',
'bin/uv': r'''#!/bin/zsh
print -ru2 -- 'FAIL - unit suite must not launch uv'
exit 99
''',
'bin/curl': r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p = Path(os.environ['ENMAAS_TEST_ROOT']); c = Path(os.environ['ENMAAS_TEST_CAPTURE'])
args = sys.argv[1:]; endpoint = args[-1]
headers = sys.stdin.read() if '--config' in args else ''
native = 'x-api-key: upstream-test-secret' in headers and 'anthropic-version: 2023-06-01' in headers
bearer = 'Authorization: Bearer upstream-test-secret' in headers
path = endpoint.removeprefix('http://127.0.0.1:58123')
with (p/'discovery.jsonl').open('a') as f:
 f.write(json.dumps({'native':native, 'bearer':bearer, 'path':path, 'argv':args})+'\n')
if not (native or bearer) or os.environ.get('ENMAAS_TEST_TRANSPORT_FAIL') == '1': sys.exit(22)
a = [
 {'id':'claude-sonnet-4-5-20250929', 'display_name':'Claude Sonnet 4.5'},
 {'id':'claude-sonnet-4-6', 'display_name':'Claude Sonnet 4.6'},
 {'id':'claude-opus-4-6', 'display_name':'Claude Opus 4.6'},
 {'id':'claude-haiku-4-5', 'display_name':'Claude Haiku 4.5'},
 {'id':'ambiguous', 'display_name':'Gateway native', 'owned_by':'openai'},
 {'id':'native-claude', 'display_name':'Native metadata', 'dialect':'anthropic'}]
b = a + [{'id':'gemini-3-pro', 'owned_by':'anthropic'}, {'id':'response-model', 'dialect':'responses'}]
r = [{'id':i} for i in ('gpt-6.1-sol', 'gpt-6-luna', 'gpt-5-mini', 'gpt-5-mini-2025-08-07',
                        'gpt-realtime', 'gpt-image-1', 'text-embedding-3-small', 'o3-mini')]
if path == '/v1/responses/../models':
 assert bearer and not native and '--path-as-is' in args
 if (p/'openai-unavailable').exists(): sys.exit(22)
elif path != '/v1/models': sys.exit(22)
if (p/'catalog-unavailable').exists(): print('not-json'); sys.exit(0)
data = r if path == '/v1/responses/../models' else (a if native else b)
print(json.dumps({'data':[] if (p/'catalog-empty').exists() else data}))
''',
'bin/claude': r'''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
p = Path(os.environ['ENMAAS_TEST_CAPTURE'])
(p/'claude.json').write_text(json.dumps({'argv':sys.argv[1:], 'env':dict(os.environ)}))
(p/'claude.pid').write_text(str(os.getpid()))
if os.environ.get('ENMAAS_TEST_CLAUDE_WAIT') == '1':
 while True: time.sleep(.1)
sys.exit(int(os.environ.get('ENMAAS_TEST_CLAUDE_STATUS','0')))
'''
}
for name, text in files.items():
    f = p/name; f.write_text(text)
    if name.startswith('bin/'): f.chmod(0o700)
PY
_claude_enmaas_proxy_program() { print -r -- "$(<"$tmp/mock-daemon.py")"; }
export ENMAAS_API_BASE_URL='http://127.0.0.1:58123/v1/messages' ENMAAS_API_KEY='upstream-test-secret'
export PATH="$tmp/bin:$PATH" ENMAAS_TEST_ROOT="$tmp" ENMAAS_TEST_CAPTURE="$tmp/capture" CLAUDE_ENMAAS_PROXY_START_TIMEOUT=3
mkdir "$ENMAAS_TEST_CAPTURE"

_claude_enmaas_assert() {
    local description="$1"; shift
    if "$@"; then print -r -- "ok - $description"
    else print -ru2 -- "FAIL - $description"; exit 1; fi
}

_claude_enmaas_assert 'gateway root normalization' test "$(_claude_enmaas_root "$ENMAAS_API_BASE_URL")" = 'http://127.0.0.1:58123'
for endpoint in '' '/v1/' '/v1/models' '/v1/messages' '/v1/chat/completions' '/v1/responses'; do
    _claude_enmaas_assert 'HTTPS endpoint normalization' test "$(_claude_enmaas_root "https://gateway.example${endpoint}")" = 'https://gateway.example'
done
for bad in 'http://example.com' 'https://user:secret@example.com/v1' 'https://example.com/v1?key=secret' 'https://example.com/#fragment' 'https://example.com/unexpected' 'https://example.com:99999' 'file:///etc/passwd' 'https://example.com\@elsewhere' $'https://example.com\n'; do
    if _claude_enmaas_root "$bad" >/dev/null 2>&1; then print -ru2 -- 'FAIL - rejected URL accepted'; exit 1; fi
done
print 'ok - untrusted URLs rejected'
unset CLAUDE_ENMAAS_PROXY_PORT
_claude_enmaas_assert 'shared default port is 4146 without probing a listener' test "$(_claude_enmaas_port)" = 4146
for port in 1 65535 05123; do
    export CLAUDE_ENMAAS_PROXY_PORT="$port"
    _claude_enmaas_assert 'valid explicit port normalized' test "$(_claude_enmaas_port)" -eq "$port"
done
for port in 0 65536 -1 '1.5' ' 4146' abc '１２３'; do
    export CLAUDE_ENMAAS_PROXY_PORT="$port"
    if _claude_enmaas_port >/dev/null 2>&1; then print -ru2 -- 'FAIL - invalid port accepted'; exit 1; fi
done
unset CLAUDE_ENMAAS_PROXY_PORT
print 'ok - invalid ports rejected'

# Inherited wrapper values must not leak into the EnMaaS child or mutate parent.
export ANTHROPIC_BASE_URL='https://unrelated.example' ANTHROPIC_AUTH_TOKEN='parent-token' ANTHROPIC_API_KEY='parent-key'
export CLAUDE_CODE_USE_VERTEX=1 CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_FOUNDRY=1 ANTHROPIC_CUSTOM_HEADERS='x-parent: sensitive'
export ANTHROPIC_FOUNDRY_API_KEY='foundry-secret' CLAUDE_CODE_API_KEY_HELPER='parent-helper'
typeset -g _cop_base='parent-cop-base' _cop_master_key='parent-cop-key'
local parent_snapshot="$(typeset -p ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_FOUNDRY_API_KEY CLAUDE_CODE_API_KEY_HELPER _cop_base _cop_master_key)"
export ENMAAS_TEST_CLAUDE_STATUS=37
local rc=0
claude-enmaas --model=gemini-3-pro --print 'argument with spaces' >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
if [[ "$rc" != 37 ]]; then
    print -ru2 -- "FAIL - first launcher returned $rc: $(<"$tmp/stderr")"
fi
_claude_enmaas_assert 'Claude exit status retained' test "$rc" = 37
_claude_enmaas_assert 'parent environment and shared state unchanged' test "$parent_snapshot" = "$(typeset -p ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_FOUNDRY_API_KEY CLAUDE_CODE_API_KEY_HELPER _cop_base _cop_master_key)"
python3 - "$tmp" <<'PY'
import json, os, sys
from pathlib import Path
p=Path(sys.argv[1]); c=p/'capture'; reg=json.loads((c/'registration.json').read_text()); launch=json.loads((c/'claude.json').read_text())
m={row['model_name']:row['litellm_params'] for row in reg['model_list']}
root='http://127.0.0.1:58123'
assert m['claude-sonnet-4-6']['model']=='anthropic/claude-sonnet-4-6'
assert m['claude-sonnet-4-6']['api_base']==root
assert m['ambiguous']['model']=='anthropic/ambiguous', 'Anthropic membership lost during union'
assert m['gemini-3-pro']['model']=='openai/gemini-3-pro', 'owned_by must not choose dialect'
assert m['gemini-3-pro']['api_base']==root+'/v1'
assert m['response-model']['model']=='openai/responses/response-model'
assert m['gpt-6.1-sol']['model']=='openai/responses/gpt-6.1-sol'
assert m['gpt-6-luna']['api_base']==root+'/v1'
assert m['o3-mini']['model']=='openai/responses/o3-mini'
assert not any(i in m for i in ('gpt-realtime','gpt-image-1','text-embedding-3-small','gpt-5-mini-2025-08-07'))
assert m['native-claude']['model']=='anthropic/native-claude'
assert m['*']['model']=='openai/*'
glm='rits/zai-org/glm-5-3'; ds='rits/deepseek-ai/DeepSeek-V4.1-Flash-1017'
assert m[glm]['model']=='anthropic/'+glm and m[glm]['api_base']==root
assert m[ds]['model']=='anthropic/'+ds and m[ds]['api_base']==root, 'DeepSeek must use the Messages dialect at the gateway root'
# Responses passthrough siblings for Codex: same upstream id, /v1, no anthropic bridge
for hosted in (glm, ds):
    assert m[hosted+'#responses']['model']=='openai/'+hosted and m[hosted+'#responses']['api_base']==root+'/v1'
assert reg['routes']==glm+','+ds
hooks=reg['hook_files'].split('\n')
assert [Path(h).name for h in hooks]==['hosted_only_hooks.py','unwrap_tools_middleware.py','enmaas_proxy_hooks.py','litellm_usage_log.py'], hooks
assert all(Path(h).is_file() for h in hooks)
assert 'router_settings' not in reg['config'], 'no paid-model vision fallback unless asked for'
assert all(row['api_key']=='os.environ/ENMAAS_API_KEY' for row in m.values())
assert reg['upstream_key']=='upstream-test-secret'
assert (c/'program-mode').read_text()=='0o600'; assert (c/'directory-mode').read_text()=='0o700'
assert launch['argv'][2:]==['--model=gemini-3-pro','--print','argument with spaces']
settings=json.loads(launch['argv'][1]); assert settings['apiKeyHelper']==''
assert settings['modelSettings']=={glm:{'effortLevel':'medium'}, ds:{'effortLevel':'medium'}}
opts=settings['modelPicker']['options']; ids=[r['model'] for r in opts]; assert ids.count('ambiguous')==1
assert any('GLM 5.3' in row['label'] for row in opts)
assert any(row['model']==ds and 'DeepSeek' in row['label'] for row in opts)
assert any(row['label'].startswith('Claude Sonnet 4.6') for row in opts if row['model']=='claude-sonnet-4-6')
assert any(row['label'].startswith('GPT-6.1 Sol') for row in opts if row['model']=='gpt-6.1-sol')
assert '_claude-enmaas-ready-' not in json.dumps(opts)
e=launch['env']; assert e['ANTHROPIC_MODEL']=='gemini-3-pro'
assert e['ANTHROPIC_DEFAULT_SONNET_MODEL']=='claude-sonnet-4-6'
assert e['ANTHROPIC_DEFAULT_OPUS_MODEL']=='claude-opus-4-6'
assert e['ANTHROPIC_DEFAULT_HAIKU_MODEL']=='claude-haiku-4-5'
assert e['ANTHROPIC_DEFAULT_FABLE_MODEL']=='claude-sonnet-4-6'
assert e['ANTHROPIC_API_KEY']=='' and e['ANTHROPIC_AUTH_TOKEN']==reg['token']
assert e['ANTHROPIC_AUTH_TOKEN']!='upstream-test-secret'
assert e['ANTHROPIC_BASE_URL']=='http://127.0.0.1:4146'
assert settings['env']['ANTHROPIC_BASE_URL']==e['ANTHROPIC_BASE_URL']
assert settings['env']['ANTHROPIC_AUTH_TOKEN']==e['ANTHROPIC_AUTH_TOKEN']
assert settings['env']['ANTHROPIC_API_KEY']==''
assert all(e[k]=='0' for k in ('CLAUDE_CODE_USE_VERTEX','CLAUDE_CODE_USE_BEDROCK','CLAUDE_CODE_USE_FOUNDRY'))
assert e['ANTHROPIC_CUSTOM_HEADERS']==''
assert 'ANTHROPIC_FOUNDRY_API_KEY' not in e and 'CLAUDE_CODE_API_KEY_HELPER' not in e
assert 'ENMAAS_API_KEY' not in e, 'upstream key inherited by Claude child'
assert not Path((c/'session-path').read_text()).exists(), 'private directory survives return'
requests=[json.loads(l) for l in (p/'discovery.jsonl').read_text().splitlines()]
assert any(r['native'] for r in requests) and any(r['bearer'] for r in requests)
assert any(r['path']=='/v1/responses/../models' and r['bearer'] and not r['native'] for r in requests)
assert all('upstream-test-secret' not in json.dumps(r['argv']) and '-L' not in r['argv'] and '--location' not in r['argv'] for r in requests)
assert 'gpt-6.1-sol' in ids and 'gpt-6-luna' in ids
assert 'upstream-test-secret' not in (p/'stdout').read_text()+(p/'stderr').read_text()+json.dumps(settings)
argv=json.loads((c/'ensure.json').read_text())['argv']
assert argv==['4146','1.97.0','0.136.3','3','gemini-3-pro','claude-opus-4-6','claude-sonnet-4-6','claude-haiku-4-5','claude-sonnet-4-6',glm,ds,glm+'#responses',ds+'#responses'], argv
print('ok - routing, discovery union, hosted routes, hooks, settings, auth, argv, modes and private-file cleanup')
PY
local config=$(_claude_enmaas_config 'https://gateway.example' 'test-token' '{"data":[]}' 'custom')
_claude_enmaas_assert 'config enables explicit Chat conversion' test "$(jq -r '.litellm_settings.use_chat_completions_url_for_anthropic_messages' <<< "$config")" = true
_claude_enmaas_assert 'config contains no literal upstream credential' test "$(jq -r '.model_list | all(.litellm_params.api_key == "os.environ/ENMAAS_API_KEY")' <<< "$config")" = true

export ENMAAS_TEST_CLAUDE_STATUS=0
touch "$tmp/openai-unavailable"
claude-enmaas >"$tmp/stdout" 2>"$tmp/stderr"
_claude_enmaas_assert 'OpenAI outage warns without losing other catalogs' grep -q 'GPT models may be omitted' "$tmp/stderr"
rm "$tmp/openai-unavailable"

# Exact unknown CLI IDs and tier aliases can be pinned with explicit dialects.
export CLAUDE_ENMAAS_MODEL='default-exact'
export CLAUDE_ENMAAS_OPUS_MODEL='custom-opus' CLAUDE_ENMAAS_SONNET_MODEL='custom-sonnet'
export CLAUDE_ENMAAS_HAIKU_MODEL='custom-haiku' CLAUDE_ENMAAS_FABLE_MODEL='custom-fable'
export CLAUDE_ENMAAS_MODEL_DIALECTS='unknown-exact=responses custom-opus=chat default-exact=anthropic ambiguous=chat'
claude-enmaas --model unknown-exact --print 'exact id' >"$tmp/stdout" 2>"$tmp/stderr"
python3 - "$ENMAAS_TEST_CAPTURE" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1]); reg=json.loads((p/'registration.json').read_text()); m={row['model_name']:row['litellm_params'] for row in reg['model_list']}
e=json.loads((p/'claude.json').read_text())['env']
assert m['unknown-exact']['model']=='openai/responses/unknown-exact'
assert m['ambiguous']['model']=='openai/ambiguous'
assert m['default-exact']['model']=='anthropic/default-exact'
assert e['ANTHROPIC_DEFAULT_OPUS_MODEL']=='custom-opus' and e['ANTHROPIC_DEFAULT_FABLE_MODEL']=='custom-fable'
assert e['ANTHROPIC_MODEL']=='unknown-exact'
assert e['ANTHROPIC_BASE_URL']=='http://127.0.0.1:4146'
print('ok - exact dialect overrides, tier overrides and separated --model')
PY
claude-enmaas --model opus >"$tmp/stdout" 2>"$tmp/stderr"
_claude_enmaas_assert 'CLI family aliases preserve selected tier' test "$(jq -r '.env.ANTHROPIC_MODEL' "$ENMAAS_TEST_CAPTURE/claude.json")" = custom-opus
unset CLAUDE_ENMAAS_MODEL CLAUDE_ENMAAS_OPUS_MODEL CLAUDE_ENMAAS_SONNET_MODEL CLAUDE_ENMAAS_HAIKU_MODEL CLAUDE_ENMAAS_FABLE_MODEL CLAUDE_ENMAAS_MODEL_DIALECTS

# Merge a caller's final settings layer, preserving wrapper-owned transport.
claude-enmaas --settings '{"effortLevel":"low","env":{"KEEP_ME":"yes","ANTHROPIC_BASE_URL":"https://other.example","CLAUDE_CODE_USE_VERTEX":"1"},"modelSettings":{"custom":{"effortLevel":"low"},"rits/zai-org/glm-5-3":{"effortLevel":"high"}}}' --print 'settings test' >"$tmp/stdout" 2>"$tmp/stderr"
python3 - "$ENMAAS_TEST_CAPTURE" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1]); launch=json.loads((p/'claude.json').read_text()); args=launch['argv']
assert args.count('--settings')==1
s=json.loads(args[1]); assert args[2:]==['--print','settings test']
assert s['effortLevel']=='low' and s['env']['KEEP_ME']=='yes'
assert s['env']['ANTHROPIC_BASE_URL']==launch['env']['ANTHROPIC_BASE_URL']
assert s['env']['CLAUDE_CODE_USE_VERTEX']=='0' and s['apiKeyHelper']==''
assert s['modelSettings']['custom']['effortLevel']=='low'
assert s['modelSettings']['rits/zai-org/glm-5-3']['effortLevel']=='medium'
assert s['modelPicker']['options']
print('ok - caller settings merge preserves isolation, picker and GLM effort')
PY
print -r -- '{"effortLevel":"high","env":{"FROM_FILE":"yes"}}' > "$tmp/caller-settings.json"
claude-enmaas --settings '{"earlier":"ignored"}' "--settings=$tmp/caller-settings.json" >"$tmp/stdout" 2>"$tmp/stderr"
_claude_enmaas_assert 'final settings file preserved' test "$(jq -r '.argv[1] | fromjson | .env.FROM_FILE' "$ENMAAS_TEST_CAPTURE/claude.json")" = yes
_claude_enmaas_assert 'earlier settings occurrence ignored like Claude' test "$(jq -r '.argv[1] | fromjson | has("earlier")' "$ENMAAS_TEST_CAPTURE/claude.json")" = false
for invalid in '' 'not-json' '[]'; do
    rc=0; claude-enmaas --settings "$invalid" >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
    _claude_enmaas_assert 'invalid caller settings fail' test "$rc" = 1
done
rc=0; claude-enmaas --settings >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
_claude_enmaas_assert 'missing caller settings fail' test "$rc" = 1

export CLAUDE_ENMAAS_PROXY_PORT=5143
claude-enmaas >"$tmp/stdout" 2>"$tmp/stderr"
_claude_enmaas_assert 'port override forwarded to controller' test "$(jq -r '.argv[0]' "$ENMAAS_TEST_CAPTURE/ensure.json")" = 5143
_claude_enmaas_assert 'port override used in child transport' test "$(jq -r '.env.ANTHROPIC_BASE_URL' "$ENMAAS_TEST_CAPTURE/claude.json")" = 'http://127.0.0.1:5143'
unset CLAUDE_ENMAAS_PROXY_PORT

# Controller failures never call Claude. All seams are mocks.
for failure in ENSURE_FAIL; do
    rm -f "$ENMAAS_TEST_CAPTURE/claude.json" "$ENMAAS_TEST_CAPTURE/registration.json"
    export "ENMAAS_TEST_${failure}=1" CLAUDE_ENMAAS_PROXY_START_TIMEOUT=1
    rc=0; claude-enmaas >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
    _claude_enmaas_assert "$failure propagated" test "$rc" = 1
    _claude_enmaas_assert "$failure does not launch Claude" test ! -e "$ENMAAS_TEST_CAPTURE/claude.json"
    _claude_enmaas_assert "$failure removes private session files" test ! -e "$(<"$ENMAAS_TEST_CAPTURE/session-path")"
    unset "ENMAAS_TEST_${failure}"
done
export CLAUDE_ENMAAS_PROXY_START_TIMEOUT=3
for bad in 'bad=not-a-dialect' 'bad' '=chat'; do
    export CLAUDE_ENMAAS_MODEL_DIALECTS="$bad"
    rc=0; claude-enmaas >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
    _claude_enmaas_assert 'malformed dialect override fails' test "$rc" = 1
done
unset CLAUDE_ENMAAS_MODEL_DIALECTS
for invalid in '--model=' '--model'; do
    rc=0; claude-enmaas "$invalid" >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
    _claude_enmaas_assert 'empty or missing CLI model fails' test "$rc" = 1
done
for timeout in 0 601 abc; do
    export CLAUDE_ENMAAS_PROXY_START_TIMEOUT="$timeout"
    rc=0; claude-enmaas >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
    _claude_enmaas_assert 'invalid startup timeout fails' test "$rc" = 1
done
export CLAUDE_ENMAAS_PROXY_START_TIMEOUT=3

# Discovery is advisory; exact selections still work with an empty/broken catalog.
for catalog in empty unavailable; do
    touch "$tmp/catalog-$catalog"
    rc=0; claude-enmaas >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
    _claude_enmaas_assert "$catalog catalog without explicit model fails" test "$rc" = 1
    claude-enmaas --model undiscovered-exact >"$tmp/stdout" 2>"$tmp/stderr"
    _claude_enmaas_assert "$catalog catalog accepts exact CLI model" test "$(jq -r '.env.ANTHROPIC_MODEL' "$ENMAAS_TEST_CAPTURE/claude.json")" = undiscovered-exact
    export CLAUDE_ENMAAS_MODEL='rits/zai-org/glm-5-3'
    claude-enmaas >"$tmp/stdout" 2>"$tmp/stderr"
    _claude_enmaas_assert "$catalog catalog accepts configured model" test "$(jq -r '.env.ANTHROPIC_MODEL' "$ENMAAS_TEST_CAPTURE/claude.json")" = rits/zai-org/glm-5-3
    unset CLAUDE_ENMAAS_MODEL
    rm "$tmp/catalog-$catalog"
done
export ENMAAS_TEST_TRANSPORT_FAIL=1
claude-enmaas --model offline-exact >"$tmp/stdout" 2>"$tmp/stderr"
_claude_enmaas_assert 'transport failure accepts explicit selection' test "$(jq -r '.env.ANTHROPIC_MODEL' "$ENMAAS_TEST_CAPTURE/claude.json")" = offline-exact
unset ENMAAS_TEST_TRANSPORT_FAIL
for credential in ENMAAS_API_KEY ENMAAS_API_BASE_URL; do
    rc=0
    (unset "$credential"; claude-enmaas) >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
    _claude_enmaas_assert "missing $credential fails" test "$rc" = 1
done
rc=0
( export ENMAAS_API_KEY=$'invalid\nkey'; claude-enmaas ) >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
_claude_enmaas_assert 'control characters in key rejected' test "$rc" = 1

# TERM only reaches the invocation's own Claude child and private files, never the proxy.
mkdir "$tmp/signal-capture"
export ENMAAS_TEST_CAPTURE="$tmp/signal-capture" ENMAAS_TEST_CLAUDE_WAIT=1
claude-enmaas >"$tmp/stdout" 2>"$tmp/stderr" &
run_pid=$!
for i in {1..80}; do [[ -s "$ENMAAS_TEST_CAPTURE/claude.json" ]] && break; sleep 0.1; done
if [[ ! -s "$ENMAAS_TEST_CAPTURE/claude.json" ]]; then
    print -ru2 -- "FAIL - signal fixture did not launch Claude: $(<"$tmp/stderr")"
    exit 1
fi
# $run_pid is only the backgrounding wrapper; TERM must reach the claude-enmaas
# subshell, two levels above Claude (claude-enmaas -> _claude_invoke subshell -> claude).
local claude_pid invoke_pid owner_pid
claude_pid=$(<"$ENMAAS_TEST_CAPTURE/claude.pid")
invoke_pid=$(ps -o ppid= -p "$claude_pid"); owner_pid=$(ps -o ppid= -p "${invoke_pid// }")
kill -TERM "${owner_pid// }"
rc=0; wait "$run_pid" || rc=$?
run_pid=''
_claude_enmaas_assert 'TERM interrupts running Claude with status 143' test "$rc" = 143
python3 - "$ENMAAS_TEST_CAPTURE" <<'PY'
import os, sys, time
from pathlib import Path
p=Path(sys.argv[1])
pid=int((p/'claude.pid').read_text())
for _ in range(50):
    try: os.kill(pid,0)
    except ProcessLookupError: break
    time.sleep(.1)
else: raise AssertionError('claude.pid survives TERM')
assert not Path((p/'session-path').read_text()).exists()
print('ok - TERM removes only mock Claude and private files')
PY
unset ENMAAS_TEST_CLAUDE_WAIT

# Opt-in LiteLLM fallback for a failed GLM request (paid model, so never default).
mkdir "$tmp/fallback-capture"
export ENMAAS_TEST_CAPTURE="$tmp/fallback-capture"
CLAUDE_ENMAAS_VISION_FALLBACK_MODEL=claude-sonnet-4-6 claude-enmaas >"$tmp/stdout" 2>"$tmp/stderr"
_claude_enmaas_assert 'explicit vision fallback model is routed' test "$(jq -c '.config.router_settings.fallbacks' "$ENMAAS_TEST_CAPTURE/registration.json")" = '[{"rits/zai-org/glm-5-3":["claude-sonnet-4-6"]}]'

# Hook env: every hook module exists and loads as a dotted LiteLLM callback name
# (LiteLLM splits on '.', so a file path or `file.py:name` breaks proxy boot).
( _claude_enmaas_hook_env; python3 - "$CLAUDE_ENMAAS_HOOK_FILES" <<'PY'
import re, sys
from pathlib import Path
for f in map(Path, sys.argv[1].split('\n')):
    assert f.is_file() and re.fullmatch(r'[A-Za-z_]\w*', f.stem), f
    assert 'proxy_handler_instance' in f.read_text(), f
print('ok - hook modules exist and expose proxy_handler_instance')
PY
)

# Exercise the actual emitted controller functions with patched sockets/processes.
# Never touches a real runtime or listener.
python3 - "$tmp/actual-daemon.py" "$tmp" <<'PY'
import json, os, runpy, sys
from pathlib import Path
from unittest.mock import patch
p=Path(sys.argv[2]); g=runpy.run_path(sys.argv[1]); ns=g['ensure'].__globals__

# Hook digest follows hook code and the knobs the hooks read, nothing else.
hdir=p/'hooks'; hdir.mkdir()
for name in ('first_hook.py','second_hook.py'): (hdir/name).write_text('proxy_handler_instance = 1\n')
files=[hdir/'first_hook.py', hdir/'second_hook.py']
with patch.dict(os.environ, {'CLAUDE_ENMAAS_HOOK_FILES': '\n'.join(map(str, files))}):
    assert g['hook_files']()==files
    d0=g['hook_digest'](files)
    (hdir/'second_hook.py').write_text('proxy_handler_instance = 2\n')
    d1=g['hook_digest'](files); assert d1!=d0, 'hook code change not detected'
    with patch.dict(os.environ, {'HOSTED_ONLY_VISION_FALLBACK':'0'}):
        assert g['hook_digest'](files)!=d1, 'hook knob change not detected'
    with patch.dict(os.environ, {'UNRELATED_KNOB':'x'}):
        assert g['hook_digest'](files)==d1
assert g['hook_digest']([])==''
root=p/'runtime-hooks'; root.mkdir(mode=0o700)
assert g['install_hooks'](root, files)==['first_hook.proxy_handler_instance','second_hook.proxy_handler_instance']
assert (root/'first_hook.py').stat().st_mode & 0o777==0o600

# ensure(): not owned -> spawn pinned uv with dotted callbacks, a proxy log and a filtered env.
config={'model_list':[{'model_name':'*','litellm_params':{'model':'openai/*','api_base':'http://x/v1'}}],
        'general_settings':{'master_key':''},'litellm_settings':{'drop_params':True}}
spawned=[]
class FakeChild:
    pid=999999
    def poll(self): return None
def spawn(argv, **kwargs):
    spawned.append((argv, kwargs)); return FakeChild()
class OpenSocket:
    def __init__(self,*a): pass
    def __enter__(self): return self
    def __exit__(self,*a): pass
    def setsockopt(self,*a): pass
    def bind(self,*a): pass
env={'ENMAAS_API_KEY':'unit-upstream-secret','ANTHROPIC_API_KEY':'other-secret','HOSTED_ONLY_VISION_FALLBACK':'0',
     'LLM_USAGE_DIR':str(p/'usage'),'CLAUDE_ENMAAS_HOOK_FILES':'\n'.join(map(str, files)),'ENMAAS_RESPONSES_ROUTES':'a,b'}
froot=p/'runtime-spawn'; froot.mkdir(mode=0o700)
fresh=lambda: json.loads(json.dumps(config))
with patch.dict(os.environ, env), patch.object(ns['subprocess'],'Popen',spawn), patch.object(ns['socket'],'socket',OpenSocket), \
     patch.dict(ns, {'listeners':lambda port:set(),'birth':lambda pid:'t0','ready':lambda info,root:True}):
    g['ensure'](froot, 4166, fresh(), ['1.97.0','0.136.3'], 3, [])
argv,options=spawned[0]
cfg=json.loads((froot/'config.json').read_text())
assert cfg['litellm_settings']['callbacks']==['first_hook.proxy_handler_instance','second_hook.proxy_handler_instance'], cfg
assert all('/' not in c and ':' not in c and c.count('.')==1 for c in cfg['litellm_settings']['callbacks'])
assert (froot/'first_hook.py').exists() and (froot/'second_hook.py').exists(), 'hooks must sit next to config.json'
assert 'litellm[proxy]==1.97.0' in argv and 'fastapi==0.136.3' in argv and str(froot/'config.json') in argv
e=options['env']
assert e['HOSTED_ONLY_VISION_FALLBACK']=='0' and e['LLM_USAGE_DIR']==str(p/'usage') and e['ENMAAS_RESPONSES_ROUTES']=='a,b'
assert 'ANTHROPIC_API_KEY' not in e and e['ENMAAS_API_KEY']=='unit-upstream-secret'
assert isinstance(options['stdout'], int) and options['stderr']==options['stdout'], 'boot failures must be logged'
assert (froot/'proxy.log').stat().st_mode & 0o777==0o600
info=json.loads((froot/'proxy.json').read_text())
assert info['hooks'] and info['hooks']!=''

# ensure(): owned + ready -> reuse; hook knob change -> refuse restart.
patched={'owned':lambda i:True,'ready':lambda i,r:True}
with patch.dict(os.environ, env), patch.dict(ns, patched), patch.object(ns['subprocess'],'Popen',side_effect=AssertionError('reuse must not spawn')):
    assert g['ensure'](froot, 4166, fresh(), ['1.97.0','0.136.3'], 3, [])['token']==info['token']
with patch.dict(os.environ, dict(env, HOSTED_ONLY_VISION_FALLBACK='1')), patch.dict(ns, patched):
    try: g['ensure'](froot, 4166, fresh(), ['1.97.0','0.136.3'], 3, [])
    except RuntimeError as error: assert 'hook code or knobs changed' in str(error), error
    else: raise AssertionError('changed hook knob accepted by a running proxy')
print('ok - hook digest, dotted callbacks next to config, proxy log, env passthrough, reuse and hook-change refusal (all mocked)')
PY
print 'All claude-enmaas unit/launcher tests passed.'
