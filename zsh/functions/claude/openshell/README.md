# Claude Code in an OpenShell sandbox

`openshell-copilot`, `openshell-vertex`, `openshell-enmass` and
`openshell-openai` run the matching `claude-<backend>` wrapper with Claude Code
inside an [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) sandbox.
Implementation: `../providers/openshell.zsh`.

## Setup

```zsh
brew install nvidia/openshell/openshell     # >= 0.1 (Brewfile)
brew services restart openshell             # local gateway, podman driver
openshell gateway add https://localhost:17670 --local --name openshell
openshell-claude-image-build                # localhost/openshell-claude:latest
```

Podman must be running (`podman machine start`). The image pins Claude Code
to the host's `claude --version`; rebuild after upgrading Claude Code
(`CLAUDE_OPENSHELL_CLAUDE_VERSION=latest openshell-claude-image-build` to
override).

## Use

```zsh
cd ~/git/some-repo
openshell-copilot                     # interactive
openshell-vertex -p 'explain main.go' # print mode; stdin/stdout piping works
openshell-claude-ls                   # wrapper-created sandboxes + saved patches
openshell-claude-clean [name...]      # save changes, delete leftovers
```

Each run:

1. The `claude-<backend>` wrapper runs on the host as usual: proxy start, hot
   reload, model detection, `/model` picker.
2. A new sandbox `cl-<backend>-<id>` is created (labels
   `managed-by=claude-openshell`, `backend`, `repo`). The git work tree
   containing `$PWD` is uploaded to `/sandbox/<repo>`, and claude starts in
   the matching subdirectory. A non-git directory is refused unless
   `CLAUDE_OPENSHELL_ALLOW_UNFILTERED=1`, because its upload would be
   unfiltered.
3. The upload is snapshotted into a hidden git dir
   (`/sandbox/.claude-openshell/baseline.git`).
4. The wrapper's transport env is written to a 0600 settings file, uploaded
   to `/sandbox/.claude-openshell/settings.json`. That covers base URL,
   token, models, and the other values the wrappers export.
   `localhost`/`127.0.0.1` becomes `host.openshell.internal`, both there and
   in any caller `--settings` env block, merged in with the last `--settings`
   winning as in Claude Code.
5. `claude --bare --settings <that file>` then runs via
   `openshell sandbox exec`, so no token appears on any process argv (`ps`).
6. On exit, including Ctrl-C, TERM or HUP, claude's changes are saved to
   `~/.local/state/claude-openshell/<sandbox>.patch` (0600). The patch is
   **never applied automatically**: review it, then
   `git -C <repo> apply <patch>`. Gitignored files claude created are listed
   but not saved, so `node_modules/` doesn't swamp the patch;
   `CLAUDE_OPENSHELL_INCLUDE_IGNORED=1` saves them too. The sandbox is then
   deleted. If saving fails, the sandbox is kept for
   `openshell-claude-clean`.

`openshell-claude-clean` only touches sandboxes carrying the
`managed-by=claude-openshell` label. Without arguments it skips sessions
whose recorded pid is still running; naming a sandbox overrides that check,
e.g. for a hung session.

| Variable | Default | Effect |
|---|---|---|
| `CLAUDE_OPENSHELL_GATEWAY` | `openshell` | Gateway (always pinned; must be local for `host.openshell.internal`) |
| `CLAUDE_OPENSHELL_IMAGE` | `localhost/openshell-claude:latest` | Sandbox image |
| `CLAUDE_OPENSHELL_KEEP` | unset | `1` keeps the sandbox after exit |
| `CLAUDE_OPENSHELL_BARE` | `1` | `0` drops `--bare` (claude then finds no host config in the sandbox anyway) |
| `CLAUDE_OPENSHELL_NO_UPLOAD` | unset | `1` starts with an empty `/sandbox`; nothing is saved on exit (no baseline to diff) |
| `CLAUDE_OPENSHELL_ALLOW_UNFILTERED` | unset | `1` permits uploading a non-git directory (no `.gitignore` filtering) |
| `CLAUDE_OPENSHELL_INCLUDE_IGNORED` | unset | `1` saves gitignored files claude created into the patch |
| `CLAUDE_OPENSHELL_ENV` | unset | Extra exported env var names to forward |
| `CLAUDE_OPENSHELL_BINARIES` | `/usr/local/bin/claude` | Policy's allowed client binaries |

## Verified behavior (OpenShell 0.1.3, podman machine on macOS, 2026-10-14)

- **No `inference.local`.** OpenShell 0.1.0 removed it and `openshell
  inference` (docs/upgrade/0-1-0.mdx). The old
  `ANTHROPIC_BASE_URL=https://inference.local` recipe only works on 0.0.x.
- **Host proxies are reachable as they are.** They listen on `127.0.0.1`
  only, yet the sandbox reaches them at `host.openshell.internal:<port>`
  through a policy endpoint with no `protocol` (L4). No `0.0.0.0` rebinding
  is needed.
- **Everything else is blocked.** Egress is denied by default (a request to
  `api.github.com` fails). Only the proxy's port and the claude binary are
  allowed.
- **Sandbox layout.** Create plus upload takes about 1.5s. `HOME` is
  `/sandbox`, so claude's state lands beside the repo copy and never in the
  patch.
- **Upload filtering.** `--upload` applies `.gitignore` and skips `.git`. A
  directory upload lands at `<dest>/<basename>`. `sandbox download` only
  reads paths under `/sandbox`.
- **Auth works from the settings file alone.** `claude --bare` works with
  `ANTHROPIC_AUTH_TOKEN`, and `claude --bare --settings <file>` takes base
  URL, token and model from the file's `env` block with none of them in the
  process env. `sandbox upload` keeps the file's 0600 mode.
- **Gateway quirks.** It caps sandbox names at 19 characters, hence
  `cl-<backend>-<id>` plus labels. `openshell status` exits 0 even for an
  unknown gateway.
- **Tested end to end:** copilot, vertex and enmass in print mode; under a
  pseudo-terminal; TERM mid-session (patch saved, sandbox deleted, exit 143);
  KEEP plus clean; the gitignored-file report; the NO_UPLOAD discard notice;
  refusal of non-git directories and unlabeled clean targets.
- **Stale CLI binary.** A stale 0.0.x `openshell` earlier in `PATH`, such as
  `~/.local/bin` from `install.sh`, fails with `workspace_scope is required`.
  Preflight checks for >= 0.1.
- **The sandbox env is limited to what the wrappers export.** Caller-shell
  leftovers like `ANTHROPIC_SMALL_FAST_MODEL` stay out. Note that
  `claude-vertex` still honors an inherited `ANTHROPIC_DEFAULT_*_MODEL`, the
  same as without a sandbox.

## Deferred

- **T3 Code launchers** (`claude-t3-openshell-<backend>`): extend the backend
  case in `scripts/claude-provider.zsh` and `_T3_CLAUDE_BACKENDS`
  (`zsh/functions/t3-migrate.zsh`). The Python bridge's final `Popen` would
  call `openshell sandbox exec` instead of the native binary, reusing the
  `capture()` transport and the base-URL rewrite here.
- **`claude-mode` options:** add `openshell-*` arms to `claude-mode` and the
  `claude` dispatcher in `mode.zsh`, and sync the usage strings.
- **Full (non-`--bare`) setup:** upload a curated subset of `~/.claude`
  (CLAUDE.md, skills, hooks, settings) and allow remote MCP endpoints in the
  policy. Telemetry hosts stay blocked; Monitor needs
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` unset, so don't silence it that
  way.
- **ollama / mlx / vertex-native-adc:** these call `command claude` directly.
  Switching them to `_claude_invoke` makes them wrappable. vertex-native-adc
  has no proxy, so it would need Vertex endpoints and ADC in the sandbox
  instead.
- **Proxy keys as provider profiles:** the `sk-enmass-*` key is the local
  proxy's per-start master key (`enmass-proxy.zsh`). The real
  `ENMASS_API_KEY` never enters the sandbox, and the key travels in the
  0600 settings file rather than on argv. A provider profile would
  additionally hide it from processes inside the sandbox, but it needs L7
  inspection, which these plain-HTTP L4 endpoints don't have.
- **Git history in the sandbox:** `.git` isn't uploaded, so claude has no
  `git log` or `git blame`. Optionally uploading it (`--no-git-ignore` on
  `<repo>/.git`) is possible; the hidden baseline dir would still drive the
  patch.
- **Patch pruning:** patches accumulate in `~/.local/state/claude-openshell/`.
- **Remote gateways:** the registered remote gateway `tiger` runs 0.0.109 and
  fails with "workspace 'default' not found". `host.openshell.internal`
  wouldn't reach this machine from it in any case.
