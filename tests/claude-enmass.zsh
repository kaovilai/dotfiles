#!/bin/zsh
# Offline unit/launcher contracts. All curl and daemon operations are mocked;
# no listener is started, inspected, adopted or shut down by this suite.
emulate -LR zsh
setopt err_exit pipe_fail
umask 077
local repo="${0:A:h:h}" tmp run_pid=''
tmp=$(mktemp -d "${TMPDIR:-/tmp}/claude-enmass-tests.XXXXXXXX")
trap '[[ -n "$run_pid" ]] && kill -TERM "$run_pid" 2>/dev/null; rm -rf -- "$tmp"' EXIT

# Load actual shared helpers without unrelated wrapper startup configuration.
source <(python3 - "$repo/zsh/functions/claude/common.zsh" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
for name in ('_claude_copilot_latest_model', '_claude_picker_args', '_claude_copilot_unset_env'):
    print(re.search(r'^' + name + r'\(\) \{\n.*?^\}', s, re.M | re.S).group())
print(re.search(r'^typeset -ga _claude_copilot_env_names=\(\n.*?^\)', s, re.M | re.S).group())
PY
)
source "$repo/zsh/functions/claude/providers/enmass.zsh"
# Preserve the real emitted helper for isolated Python tests, then replace the
# launcher seam before any claude-enmass call can reach an actual daemon.
_claude_enmass_program > "$tmp/actual-daemon.py"

python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); (p/'bin').mkdir()
files = {
'mock-daemon.py': r'''import json, os, sys, time
from pathlib import Path
p = Path(os.environ['ENMASS_TEST_CAPTURE'])
op = sys.argv[1]
if op == 'ensure':
 (p/'ensure.json').write_text(json.dumps({'argv':sys.argv[2:]}))
 (p/'session-path').write_text(str(Path(__file__).parent))
 (p/'program-mode').write_text(oct(Path(__file__).stat().st_mode & 0o777))
 (p/'directory-mode').write_text(oct(Path(__file__).parent.stat().st_mode & 0o777))
 if os.environ.get('ENMASS_TEST_ENSURE_FAIL') == '1': sys.exit(51)
 print(p/'runtime')
elif op == 'lease':
 registration = json.load(sys.stdin)
 (p/'lease.pid').write_text(str(os.getpid()))
 (p/'owner.pid').write_text(str(os.getppid())+'\n')
 if os.environ.get('ENMASS_TEST_LEASE_FAIL') == '1': sys.exit(52)
 (p/'registration.tmp').write_text(json.dumps(registration))
 (p/'registration.tmp').replace(p/'registration.json')
 while True: time.sleep(.1)
else:
 raise AssertionError('test mock prohibits serve/shutdown and unknown operations')
''',
'bin/uv': r'''#!/bin/zsh
print -ru2 -- 'FAIL - unit suite must not launch uv'
exit 99
''',
'bin/curl': r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p = Path(os.environ['ENMASS_TEST_ROOT']); c = Path(os.environ['ENMASS_TEST_CAPTURE'])
args = sys.argv[1:]; endpoint = args[-1]
headers = sys.stdin.read() if '--config' in args else ''
if not endpoint.startswith('http://127.0.0.1:58123'):
 # Registration readiness is token- and marker-scoped, with no HTTP listener.
 if not (c/'registration.json').exists(): sys.exit(22)
 r = json.loads((c/'registration.json').read_text())
 expected = 'Authorization: Bearer '+r['token']
 if headers:
  if expected not in headers: sys.exit(22)
 elif args[args.index('-H')+1] != expected: sys.exit(22)
 marker = 'wrong-tenant-marker' if os.environ.get('ENMASS_TEST_WRONG_MARKER') == '1' else r['marker']
 print(json.dumps({'data':[{'id':marker}]})); sys.exit(0)
native = 'x-api-key: upstream-test-secret' in headers and 'anthropic-version: 2023-06-01' in headers
bearer = 'Authorization: Bearer upstream-test-secret' in headers
path = endpoint.removeprefix('http://127.0.0.1:58123')
with (p/'discovery.jsonl').open('a') as f:
 f.write(json.dumps({'native':native, 'bearer':bearer, 'path':path, 'argv':args})+'\n')
if not (native or bearer) or os.environ.get('ENMASS_TEST_TRANSPORT_FAIL') == '1': sys.exit(22)
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
p = Path(os.environ['ENMASS_TEST_CAPTURE'])
(p/'claude.json').write_text(json.dumps({'argv':sys.argv[1:], 'env':dict(os.environ)}))
(p/'claude.pid').write_text(str(os.getpid()))
if os.environ.get('ENMASS_TEST_CLAUDE_WAIT') == '1':
 while True: time.sleep(.1)
sys.exit(int(os.environ.get('ENMASS_TEST_CLAUDE_STATUS','0')))
'''
}
for name, text in files.items():
    f = p/name; f.write_text(text)
    if name.startswith('bin/'): f.chmod(0o700)
PY
_claude_enmass_program() { print -r -- "$(<"$tmp/mock-daemon.py")"; }
export ENMASS_API_BASE_URL='http://127.0.0.1:58123/v1/messages' ENMASS_API_KEY='upstream-test-secret'
export PATH="$tmp/bin:$PATH" ENMASS_TEST_ROOT="$tmp" ENMASS_TEST_CAPTURE="$tmp/capture" CLAUDE_ENMASS_PROXY_START_TIMEOUT=3
mkdir "$ENMASS_TEST_CAPTURE"

_claude_enmass_assert() {
    local description="$1"; shift
    if "$@"; then print -r -- "ok - $description"
    else print -ru2 -- "FAIL - $description"; exit 1; fi
}

_claude_enmass_assert 'gateway root normalization' test "$(_claude_enmass_root "$ENMASS_API_BASE_URL")" = 'http://127.0.0.1:58123'
for endpoint in '' '/v1/' '/v1/models' '/v1/messages' '/v1/chat/completions' '/v1/responses'; do
    _claude_enmass_assert 'HTTPS endpoint normalization' test "$(_claude_enmass_root "https://gateway.example${endpoint}")" = 'https://gateway.example'
done
for bad in 'http://example.com' 'https://user:secret@example.com/v1' 'https://example.com/v1?key=secret' 'https://example.com/#fragment' 'https://example.com/unexpected' 'https://example.com:99999' 'file:///etc/passwd' 'https://example.com\@elsewhere' $'https://example.com\n'; do
    if _claude_enmass_root "$bad" >/dev/null 2>&1; then print -ru2 -- 'FAIL - rejected URL accepted'; exit 1; fi
done
print 'ok - untrusted URLs rejected'
unset CLAUDE_ENMASS_PROXY_PORT
_claude_enmass_assert 'shared default port is 4146 without probing a listener' test "$(_claude_enmass_port)" = 4146
for port in 1 65535 05123; do
    export CLAUDE_ENMASS_PROXY_PORT="$port"
    _claude_enmass_assert 'valid explicit port normalized' test "$(_claude_enmass_port)" -eq "$port"
done
for port in 0 65536 -1 '1.5' ' 4146' abc '１２３'; do
    export CLAUDE_ENMASS_PROXY_PORT="$port"
    if _claude_enmass_port >/dev/null 2>&1; then print -ru2 -- 'FAIL - invalid port accepted'; exit 1; fi
done
unset CLAUDE_ENMASS_PROXY_PORT
print 'ok - invalid ports rejected'

# Inherited wrapper values must not leak into the EnMaaS child or mutate parent.
export ANTHROPIC_BASE_URL='https://unrelated.example' ANTHROPIC_AUTH_TOKEN='parent-token' ANTHROPIC_API_KEY='parent-key'
export CLAUDE_CODE_USE_VERTEX=1 CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_FOUNDRY=1 ANTHROPIC_CUSTOM_HEADERS='x-parent: sensitive'
export ANTHROPIC_FOUNDRY_API_KEY='foundry-secret' CLAUDE_CODE_API_KEY_HELPER='parent-helper'
typeset -g _cop_base='parent-cop-base' _cop_master_key='parent-cop-key'
local parent_snapshot="$(typeset -p ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_FOUNDRY_API_KEY CLAUDE_CODE_API_KEY_HELPER _cop_base _cop_master_key)"
export ENMASS_TEST_CLAUDE_STATUS=37
local rc=0
claude-enmass --model=gemini-3-pro --print 'argument with spaces' >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
if [[ "$rc" != 37 ]]; then
    print -ru2 -- "FAIL - first launcher returned $rc: $(<"$tmp/stderr")"
fi
_claude_enmass_assert 'Claude exit status retained' test "$rc" = 37
_claude_enmass_assert 'parent environment and shared state unchanged' test "$parent_snapshot" = "$(typeset -p ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_FOUNDRY_API_KEY CLAUDE_CODE_API_KEY_HELPER _cop_base _cop_master_key)"
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
assert m['rits/zai-org/glm-5-3']['model']=='anthropic/rits/zai-org/glm-5-3'
assert all(row['api_key']=='os.environ/ENMASS_API_KEY' for row in m.values())
assert reg['upstream_key']=='upstream-test-secret'
assert (c/'program-mode').read_text()=='0o600'; assert (c/'directory-mode').read_text()=='0o700'
assert launch['argv'][2:]==['--model=gemini-3-pro','--print','argument with spaces']
settings=json.loads(launch['argv'][1]); assert settings['apiKeyHelper']==''
assert settings['modelSettings']=={'rits/zai-org/glm-5-3':{'effortLevel':'medium'}}
opts=settings['modelPicker']['options']; ids=[r['model'] for r in opts]; assert ids.count('ambiguous')==1
assert any('GLM 5.3' in row['label'] for row in opts)
assert any(row['label'].startswith('Claude Sonnet 4.6') for row in opts if row['model']=='claude-sonnet-4-6')
assert any(row['label'].startswith('GPT-6.1 Sol') for row in opts if row['model']=='gpt-6.1-sol')
assert '_claude-enmass-ready-' not in json.dumps(opts)
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
assert 'ENMASS_API_KEY' not in e, 'upstream key inherited by Claude child'
assert not Path((c/'session-path').read_text()).exists(), 'private directory survives return'
try: os.kill(int((c/'lease.pid').read_text()),0)
except ProcessLookupError: pass
else: raise AssertionError('owned mock lease survives return')
requests=[json.loads(l) for l in (p/'discovery.jsonl').read_text().splitlines()]
assert any(r['native'] for r in requests) and any(r['bearer'] for r in requests)
assert any(r['path']=='/v1/responses/../models' and r['bearer'] and not r['native'] for r in requests)
assert all('upstream-test-secret' not in json.dumps(r['argv']) and '-L' not in r['argv'] and '--location' not in r['argv'] for r in requests)
assert 'gpt-6.1-sol' in ids and 'gpt-6-luna' in ids
assert 'upstream-test-secret' not in (p/'stdout').read_text()+(p/'stderr').read_text()+json.dumps(settings)
assert json.loads((c/'ensure.json').read_text())['argv']==['4146','1.97.0','0.136.3','3']
print('ok - routing, discovery union, settings, auth, argv, modes and lease-only cleanup')
PY
local first_token=$(jq -r '.token' "$ENMASS_TEST_CAPTURE/registration.json")
local config=$(_claude_enmass_config 'https://gateway.example' 'test-token' '{"data":[]}' 'test-marker' 'custom')
_claude_enmass_assert 'config enables explicit Chat conversion' test "$(jq -r '.litellm_settings.use_chat_completions_url_for_anthropic_messages' <<< "$config")" = true
_claude_enmass_assert 'config contains no literal upstream credential' test "$(jq -r '.model_list | all(.litellm_params.api_key == "os.environ/ENMASS_API_KEY")' <<< "$config")" = true

export ENMASS_TEST_CLAUDE_STATUS=0
touch "$tmp/openai-unavailable"
claude-enmass >"$tmp/stdout" 2>"$tmp/stderr"
_claude_enmass_assert 'OpenAI outage warns without losing other catalogs' grep -q 'GPT models may be omitted' "$tmp/stderr"
rm "$tmp/openai-unavailable"

# Exact unknown CLI IDs and tier aliases can be pinned with explicit dialects.
export CLAUDE_ENMASS_MODEL='default-exact'
export CLAUDE_ENMASS_OPUS_MODEL='custom-opus' CLAUDE_ENMASS_SONNET_MODEL='custom-sonnet'
export CLAUDE_ENMASS_HAIKU_MODEL='custom-haiku' CLAUDE_ENMASS_FABLE_MODEL='custom-fable'
export CLAUDE_ENMASS_MODEL_DIALECTS='unknown-exact=responses custom-opus=chat default-exact=anthropic ambiguous=chat'
claude-enmass --model unknown-exact --print 'exact id' >"$tmp/stdout" 2>"$tmp/stderr"
python3 - "$ENMASS_TEST_CAPTURE" "$first_token" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1]); reg=json.loads((p/'registration.json').read_text()); m={row['model_name']:row['litellm_params'] for row in reg['model_list']}
e=json.loads((p/'claude.json').read_text())['env']
assert m['unknown-exact']['model']=='openai/responses/unknown-exact'
assert m['ambiguous']['model']=='openai/ambiguous'
assert m['default-exact']['model']=='anthropic/default-exact'
assert e['ANTHROPIC_DEFAULT_OPUS_MODEL']=='custom-opus' and e['ANTHROPIC_DEFAULT_FABLE_MODEL']=='custom-fable'
assert e['ANTHROPIC_MODEL']=='unknown-exact'
assert reg['token']!=sys.argv[2]
assert e['ANTHROPIC_BASE_URL']=='http://127.0.0.1:4146'
print('ok - exact dialect overrides, tier overrides, separated --model and per-launch auth')
PY
claude-enmass --model opus >"$tmp/stdout" 2>"$tmp/stderr"
_claude_enmass_assert 'CLI family aliases preserve selected tier' test "$(jq -r '.env.ANTHROPIC_MODEL' "$ENMASS_TEST_CAPTURE/claude.json")" = custom-opus
unset CLAUDE_ENMASS_MODEL CLAUDE_ENMASS_OPUS_MODEL CLAUDE_ENMASS_SONNET_MODEL CLAUDE_ENMASS_HAIKU_MODEL CLAUDE_ENMASS_FABLE_MODEL CLAUDE_ENMASS_MODEL_DIALECTS

# Merge a caller's final settings layer, preserving wrapper-owned transport.
claude-enmass --settings '{"effortLevel":"low","env":{"KEEP_ME":"yes","ANTHROPIC_BASE_URL":"https://other.example","CLAUDE_CODE_USE_VERTEX":"1"},"modelSettings":{"custom":{"effortLevel":"low"},"rits/zai-org/glm-5-3":{"effortLevel":"high"}}}' --print 'settings test' >"$tmp/stdout" 2>"$tmp/stderr"
python3 - "$ENMASS_TEST_CAPTURE" <<'PY'
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
claude-enmass --settings '{"earlier":"ignored"}' "--settings=$tmp/caller-settings.json" >"$tmp/stdout" 2>"$tmp/stderr"
_claude_enmass_assert 'final settings file preserved' test "$(jq -r '.argv[1] | fromjson | .env.FROM_FILE' "$ENMASS_TEST_CAPTURE/claude.json")" = yes
_claude_enmass_assert 'earlier settings occurrence ignored like Claude' test "$(jq -r '.argv[1] | fromjson | has("earlier")' "$ENMASS_TEST_CAPTURE/claude.json")" = false
for invalid in '' 'not-json' '[]'; do
    rc=0; claude-enmass --settings "$invalid" >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
    _claude_enmass_assert 'invalid caller settings fail' test "$rc" = 1
done
rc=0; claude-enmass --settings >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
_claude_enmass_assert 'missing caller settings fail' test "$rc" = 1

export CLAUDE_ENMASS_PROXY_PORT=5143
claude-enmass >"$tmp/stdout" 2>"$tmp/stderr"
_claude_enmass_assert 'port override forwarded to controller' test "$(jq -r '.argv[0]' "$ENMASS_TEST_CAPTURE/ensure.json")" = 5143
_claude_enmass_assert 'port override used in child transport' test "$(jq -r '.env.ANTHROPIC_BASE_URL' "$ENMASS_TEST_CAPTURE/claude.json")" = 'http://127.0.0.1:5143'
unset CLAUDE_ENMASS_PROXY_PORT

# Controller/lease/readiness failures never call Claude. All seams are mocks.
for failure in ENSURE_FAIL LEASE_FAIL WRONG_MARKER; do
    rm -f "$ENMASS_TEST_CAPTURE/claude.json" "$ENMASS_TEST_CAPTURE/registration.json"
    export "ENMASS_TEST_${failure}=1" CLAUDE_ENMASS_PROXY_START_TIMEOUT=1
    rc=0; claude-enmass >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
    _claude_enmass_assert "$failure propagated" test "$rc" = 1
    _claude_enmass_assert "$failure does not launch Claude" test ! -e "$ENMASS_TEST_CAPTURE/claude.json"
    _claude_enmass_assert "$failure removes private session files" test ! -e "$(<"$ENMASS_TEST_CAPTURE/session-path")"
    unset "ENMASS_TEST_${failure}"
done
export CLAUDE_ENMASS_PROXY_START_TIMEOUT=3
for bad in 'bad=not-a-dialect' 'bad' '=chat'; do
    export CLAUDE_ENMASS_MODEL_DIALECTS="$bad"
    rc=0; claude-enmass >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
    _claude_enmass_assert 'malformed dialect override fails' test "$rc" = 1
done
unset CLAUDE_ENMASS_MODEL_DIALECTS
for invalid in '--model=' '--model'; do
    rc=0; claude-enmass "$invalid" >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
    _claude_enmass_assert 'empty or missing CLI model fails' test "$rc" = 1
done
for timeout in 0 601 abc; do
    export CLAUDE_ENMASS_PROXY_START_TIMEOUT="$timeout"
    rc=0; claude-enmass >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
    _claude_enmass_assert 'invalid startup timeout fails' test "$rc" = 1
done
export CLAUDE_ENMASS_PROXY_START_TIMEOUT=3

# Discovery is advisory; exact selections still work with an empty/broken catalog.
for catalog in empty unavailable; do
    touch "$tmp/catalog-$catalog"
    rc=0; claude-enmass >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
    _claude_enmass_assert "$catalog catalog without explicit model fails" test "$rc" = 1
    claude-enmass --model undiscovered-exact >"$tmp/stdout" 2>"$tmp/stderr"
    _claude_enmass_assert "$catalog catalog accepts exact CLI model" test "$(jq -r '.env.ANTHROPIC_MODEL' "$ENMASS_TEST_CAPTURE/claude.json")" = undiscovered-exact
    export CLAUDE_ENMASS_MODEL='rits/zai-org/glm-5-3'
    claude-enmass >"$tmp/stdout" 2>"$tmp/stderr"
    _claude_enmass_assert "$catalog catalog accepts configured model" test "$(jq -r '.env.ANTHROPIC_MODEL' "$ENMASS_TEST_CAPTURE/claude.json")" = rits/zai-org/glm-5-3
    unset CLAUDE_ENMASS_MODEL
    rm "$tmp/catalog-$catalog"
done
export ENMASS_TEST_TRANSPORT_FAIL=1
claude-enmass --model offline-exact >"$tmp/stdout" 2>"$tmp/stderr"
_claude_enmass_assert 'transport failure accepts explicit selection' test "$(jq -r '.env.ANTHROPIC_MODEL' "$ENMASS_TEST_CAPTURE/claude.json")" = offline-exact
unset ENMASS_TEST_TRANSPORT_FAIL
for credential in ENMASS_API_KEY ENMASS_API_BASE_URL; do
    rc=0
    (unset "$credential"; claude-enmass) >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
    _claude_enmass_assert "missing $credential fails" test "$rc" = 1
done
rc=0
( export ENMASS_API_KEY=$'invalid\nkey'; claude-enmass ) >"$tmp/stdout" 2>"$tmp/stderr" || rc=$?
_claude_enmass_assert 'control characters in key rejected' test "$rc" = 1

# TERM only reaches invocation-owned mock lease/client children, never a daemon.
mkdir "$tmp/signal-capture"
export ENMASS_TEST_CAPTURE="$tmp/signal-capture" ENMASS_TEST_CLAUDE_WAIT=1
claude-enmass >"$tmp/stdout" 2>"$tmp/stderr" &
run_pid=$!
for i in {1..80}; do [[ -s "$ENMASS_TEST_CAPTURE/claude.json" ]] && break; sleep 0.1; done
if [[ ! -s "$ENMASS_TEST_CAPTURE/claude.json" ]]; then
    print -ru2 -- "FAIL - signal fixture did not launch Claude: $(<"$tmp/stderr")"
    exit 1
fi
local owner_pid=''
IFS= read -r owner_pid < "$ENMASS_TEST_CAPTURE/owner.pid"
kill -TERM "$owner_pid"
rc=0; wait "$run_pid" || rc=$?
run_pid=''
_claude_enmass_assert 'TERM interrupts running Claude with status 143' test "$rc" = 143
python3 - "$ENMASS_TEST_CAPTURE" <<'PY'
import os, sys
from pathlib import Path
p=Path(sys.argv[1])
for name in ('claude.pid','lease.pid'):
 try: os.kill(int((p/name).read_text()),0)
 except ProcessLookupError: pass
 else: raise AssertionError(name+' survives TERM')
assert not Path((p/'session-path').read_text()).exists()
print('ok - TERM removes only mock Claude, lease and private files')
PY
unset ENMASS_TEST_CLAUDE_WAIT

# Exercise actual emitted controller functions with patched sockets/processes.
# Never invoke serve/shutdown, and never touch a real runtime or listener.
python3 - "$tmp/actual-daemon.py" "$tmp" <<'PY'
import hashlib, io, json, os, runpy, sys
from pathlib import Path
from unittest.mock import patch
p=Path(sys.argv[2]); g=runpy.run_path(sys.argv[1]); info={'protocol':1,'instance':'unit-instance','pid':999999,'port':4146,'versions':['1.97.0','0.136.3'], 'source_hash':hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest()}
exchanges=[]
def exchange(root, body):
 exchanges.append(body)
 return {'instance':info['instance'],'pid':info['pid'],'port':info['port']}
g['verified'].__globals__['exchange']=exchange
with patch.object(g['os'], 'kill', return_value=None):
 assert g['verified'](p, info)
 assert exchanges==[{'op':'ping','instance':'unit-instance'}]
 assert not g['verified'](p, {'protocol':2})
 g['verified'].__globals__['exchange']=lambda *args: {'instance':'wrong','pid':info['pid'],'port':info['port']}
 assert not g['verified'](p, info)
 g['verified'].__globals__['exchange']=lambda *args: {'instance':info['instance'],'pid':1,'port':info['port']}
 assert not g['verified'](p, info)
 g['verified'].__globals__['exchange']=lambda *args: {'instance':info['instance'],'pid':info['pid'],'port':5143}
 assert not g['verified'](p, info)
g['verified'].__globals__['exchange']=exchange
with patch.object(g['os'], 'kill', side_effect=ProcessLookupError):
 assert not g['verified'](p, info)

root=p/'controller-runtime'; root.mkdir(mode=0o700)
(root/'daemon.json').write_text(json.dumps(info)); (root/'daemon.json').chmod(0o600)
assert g['metadata'](root)==info
(root/'daemon.json').chmod(0o644)
try: g['metadata'](root)
except RuntimeError: pass
else: raise AssertionError('public metadata accepted')
(root/'daemon.json').chmod(0o600)

namespace=g['ensure'].__globals__
namespace['private_runtime']=lambda port: root
namespace['verified']=lambda root, identity: bool(identity)
class FakeSocket:
 def __init__(self, *args): self.sent=[]
 def __enter__(self): return self
 def __exit__(self, *args): pass
 def bind(self, address): raise OSError('occupied mocked port')
 def setsockopt(self, *args): pass
 def settimeout(self, timeout): pass
 def connect(self, address): assert address==str(root/'control.sock')
 def sendall(self, data): self.sent.append(json.loads(data))
 def makefile(self, mode): return io.BytesIO(b'{"ok":true}\n')

# Reuse requires authenticated identity and exact dependency versions.
with patch.object(namespace['socket'], 'socket', side_effect=AssertionError('reuse must not probe listener')), patch.object(namespace['subprocess'], 'Popen', side_effect=AssertionError('reuse must not spawn')):
 with patch.object(sys, 'stdout', io.StringIO()) as output:
  g['ensure'](4146,'1.97.0','0.136.3',1)
  assert output.getvalue().strip()==str(root)
 try: g['ensure'](4146,'different','0.136.3',1)
 except RuntimeError as e: assert 'versions differ' in str(e)
 else: raise AssertionError('dependency mismatch accepted')

namespace['verified']=lambda *args: False
with patch.object(namespace['socket'], 'socket', FakeSocket), patch.object(namespace['subprocess'], 'Popen', side_effect=AssertionError('occupied port must not spawn')), patch.object(namespace['os'], 'killpg', side_effect=AssertionError('occupied port must not signal')):
 try: g['ensure'](4146,'1.97.0','0.136.3',1)
 except RuntimeError as e: assert 'refusing to adopt or replace' in str(e)
 else: raise AssertionError('unverified occupied port accepted')
assert g['metadata'](root)==info, 'failed challenge altered identity'

# A new controller launch filters credentials before spawning pinned uv.
(root/'daemon.json').unlink()
class AvailableSocket(FakeSocket):
 def bind(self, address): assert address==('127.0.0.1',4146)
class FakeChild:
 pid=999999
 def poll(self): return None
spawned=[]
def spawn(argv, **kwargs):
 spawned.append((argv, kwargs))
 identity=dict(info, instance=argv[-3])
 (root/'daemon.json').write_text(json.dumps(identity)); (root/'daemon.json').chmod(0o600)
 return FakeChild()
namespace['verified']=lambda root, identity: bool(identity)
with patch.object(namespace['socket'], 'socket', AvailableSocket), patch.object(namespace['subprocess'], 'Popen', spawn), patch.dict(os.environ, {'ENMASS_API_KEY':'unit-upstream-secret','ANTHROPIC_API_KEY':'other-provider-secret'}), patch.object(sys, 'stdout', io.StringIO()):
 g['ensure'](4146,'1.97.0','0.136.3',1)
argv, options=spawned[0]
assert 'litellm[proxy]==1.97.0' in argv and 'fastapi==0.136.3' in argv
assert 'unit-upstream-secret' not in json.dumps(argv)+json.dumps(options)
assert 'ENMASS_API_KEY' not in options['env'] and 'ANTHROPIC_API_KEY' not in options['env']
assert options['start_new_session'] is True
assert (root/'daemon.py').stat().st_mode & 0o777==0o600

# Registration is stdin payload over a private control socket, not CLI args.
registration={'token':'test-token-'+'a'*32,'marker':'ready-unit','model_list':[], 'upstream_key':'unit-upstream-secret'}
sockets=[]
def lease_socket(*args):
 s=FakeSocket(); sockets.append(s); return s
with patch.object(namespace['socket'], 'socket', lease_socket), patch.object(namespace['os'], 'getppid', side_effect=[42,1]), patch.object(sys, 'stdin', io.StringIO(json.dumps(registration))):
 g['lease'](root)
assert len(sockets)==1
assert sockets[0].sent[0]==dict(registration, op='register', instance=g['metadata'](root)['instance'])
print('ok - real helper identity/version checks, occupied-port refusal, sanitized spawn and stdin lease (all mocked)')
PY
print 'All claude-enmass unit/launcher tests passed.'
