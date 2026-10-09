#!/bin/zsh
# Offline ordering tests for the actual shared picker helper.
emulate -LR zsh
setopt err_exit pipe_fail
local repo="${0:A:h:h}"
source <(python3 - "$repo/zsh/functions/claude/common.zsh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
print(re.search(r'^_claude_picker_args\(\) \{\n.*?^\}', text, re.M | re.S).group())
PY
)
local -a reply
_claude_picker_args \
    'fable=claude-sonnet-5-5|Claude Sonnet 5.5' \
    'sonnet=claude-sonnet-5-5|Claude Sonnet 5.5' \
    'opus=claude-opus-5-5|Claude Opus 5.5' \
    'haiku=claude-haiku-4-5|Claude Haiku 4.5' \
    '=rits/zai-org/glm-5-3|GLM 5.3' \
    '=claude-opus-4-8|Claude Opus 4.8' \
    '=claude-opus-5|Claude Opus 5' \
    '=claude-sonnet-4-6|Claude Sonnet 4.6' \
    '=gpt-5.9|GPT 5.9' \
    '=gpt-5.10|GPT 5.10' \
    '=gpt-5.10-mini|GPT 5.10 mini' \
    '=openai/gpt-5.10-nano|GPT 5.10 nano' \
    '=gpt-4.1-mini|GPT 4.1 mini' \
    '=gemini-3.8-flash|Gemini 3.8 Flash' \
    '=custom-local|Custom local' \
    '=claude-opus-5-5|Duplicate Opus' \
    '=claude-sonnet-4-5-20250929|Dated snapshot'
print -rn -- "$reply[2]" | python3 -c '
import json, sys
s = json.load(sys.stdin); options = s["modelPicker"]["options"]
ids = [row["model"] for row in options]
index = ids.index
assert len(ids) == len(set(ids)), "duplicate model IDs"
assert index("claude-sonnet-5-5") < index("gpt-5.10")
assert index("claude-opus-5-5") < index("gpt-5.10")
for alternative in ("gpt-5.10", "gpt-5.10-mini", "openai/gpt-5.10-nano", "rits/zai-org/glm-5-3", "gemini-3.8-flash"):
    for legacy in ("claude-haiku-4-5", "claude-opus-4-8", "claude-sonnet-4-6"):
        assert index(alternative) < index(legacy), (alternative, legacy, ids)
assert index("gpt-5.10") < index("gpt-5.9"), "numeric GPT version ordering"
assert index("gpt-5.10-mini") < index("gpt-4.1-mini"), "current GPT mini ahead of legacy mini"
assert "custom-local" in ids
assert "claude-sonnet-4-5-20250929" in ids, "shared helper must not drop caller-supplied IDs"
sonnet = next(row for row in options if row["model"] == "claude-sonnet-5-5")
assert "fable" in sonnet["label"] and "sonnet" in sonnet["label"], "shared tier labels lost"
haiku = next(row for row in options if row["model"] == "claude-haiku-4-5")
assert "haiku" in haiku["label"], "moved Haiku lost its tier alias"
print("PASS: newest Claude, current GPT/alternatives, legacy choices, numeric versions and alias preservation")
'
# Older versions within the same Claude major generation move down too.
_claude_picker_args 'opus=claude-opus-5-5|Opus 5.5' '=claude-opus-5|Opus 5' '=gpt-5.10-mini|GPT mini' '=rits/zai-org/glm-5-3|GLM'
print -rn -- "$reply[2]" | python3 -c '
import json, sys
ids = [r["model"] for r in json.load(sys.stdin)["modelPicker"]["options"]]
assert ids.index("gpt-5.10-mini") < ids.index("claude-opus-5"), ids
assert ids.index("rits/zai-org/glm-5-3") < ids.index("claude-opus-5"), ids
print("PASS: earlier same-major Claude moved below alternatives")
'
# Older GPT versions are retained but should not crowd out current alternatives.
_claude_picker_args '=gpt-5.10|GPT 5.10' '=gpt-5.9|GPT 5.9' '=gemini-3.8-flash|Gemini' '=custom|Custom'
print -rn -- "$reply[2]" | python3 -c '
import json, sys
ids = [r["model"] for r in json.load(sys.stdin)["modelPicker"]["options"]]
assert ids.index("gpt-5.10") < ids.index("gemini-3.8-flash") < ids.index("gpt-5.9"), ids
assert "custom" in ids
print("PASS: legacy GPT moved below current alternatives")
'
# A newer major generation must beat a numerically larger old minor version.
_claude_picker_args 'opus=claude-opus-6-1|Opus 6.1' 'sonnet=claude-sonnet-5-10|Sonnet 5.10' '=gpt-6.1-mini|GPT 6.1 mini' '=gpt-5.10-mini|GPT 5.10 mini'
print -rn -- "$reply[2]" | python3 -c '
import json, sys
ids = [r["model"] for r in json.load(sys.stdin)["modelPicker"]["options"]]
assert ids.index("claude-opus-6-1") < ids.index("gpt-6.1-mini") < ids.index("claude-sonnet-5-10"), ids
assert ids.index("gpt-6.1-mini") < ids.index("gpt-5.10-mini"), ids
print("PASS: major/minor generation comparison")
'
# Catalogs often repeat the raw ID as display_name; keep human names but format IDs.
_claude_picker_args \
    '=gpt-6.1-sol|gpt-6.1-sol' \
    '=gpt-6-astra|gpt-6-astra' \
    '=gpt-6-luna|gpt-6-luna' \
    '=gpt-5.6-terra|gpt-5.6-terra' \
    '=gpt-5.4-mini|gpt-5.4-mini' \
    '=openai/gpt-5.4-mini|openai/gpt-5.4-mini' \
    'opus=claude-opus-5-5|Claude Opus 5.5 (Vertex AI)' \
    '=gpt-5.5-pro|Premium GPT display' \
    '=claude-sonnet-5-5[1m]|claude-sonnet-5-5'
print -rn -- "$reply[2]" | python3 -c '
import json, sys
labels = {r["model"]: r["label"] for r in json.load(sys.stdin)["modelPicker"]["options"]}
for model, label in {
    "gpt-6.1-sol": "GPT-6.1 Sol",
    "gpt-6-astra": "GPT-6 Astra",
    "gpt-6-luna": "GPT-6 Luna",
    "gpt-5.6-terra": "GPT-5.6 Terra",
    "gpt-5.4-mini": "GPT-5.4 Mini",
    "openai/gpt-5.4-mini": "GPT-5.4 Mini",
    "claude-opus-5-5": "Claude Opus 5.5 (Vertex AI) (opus)",
    "gpt-5.5-pro": "Premium GPT display",
    "claude-sonnet-5-5[1m]": "Claude Sonnet 5.5 1M",
}.items():
    assert labels[model] == label, (model, labels[model], label)
print("PASS: raw catalog IDs prettified, explicit names and routing IDs preserved")
'
# Providers with only one family or a custom model must still populate the picker.
_claude_picker_args 'haiku=claude-haiku-4-5|Haiku' '=custom-only|Custom'
print -rn -- "$reply[2]" | python3 -c '
import json, sys
options = json.load(sys.stdin)["modelPicker"]["options"]
assert {r["model"] for r in options} == {"claude-haiku-4-5", "custom-only"}
print("PASS: single-generation and custom models retained")
'
