# When a change takes effect

Canonical answer for "do I need to restart X?". Every seam in the dotfiles
should name its class from this table in a short comment; extend the table when
a new kind of state shows up.

Terms: **fleet-sync** = `zsh ~/git/dotfiles/scripts/fleet-sync.zsh` (Linux: hourly
systemd user timer). **Turn** = one T3 run, which spawns a fresh client process.

| What you changed | Takes effect |
|---|---|
| `scripts/llm-usage` (CLI) | immediately — every invocation is a fresh process |
| `scripts/llm-usage` dashboard (`serve`) code | the running `serve` re-execs itself within ~5 s of the script changing (a `serve.json` watchdog; it also replaces a stale-code instance on the next start, and a second start per state dir is a no-op). The menubar helper prefers the serve endpoint while it is up, so a serve that outlived its code used to shadow the helper with old data |
| `~/.config/llm-usage/fleet.json` (fleet peers) | next poll / `llm-usage fleet refresh` — the config is read fresh each time; a removed host's cached events under `~/.local/state/llm-usage/fleet/` stop being shown but stay on disk until deleted |
| `scripts/llm-usage-menubar/main.swift` | `llm-usage menubar build` (or `menubar install`) then `launchctl kickstart -k gui/$UID/com.kaovilai.llm-usage-menubar` — rebuild alone leaves the old process running |
| Claude/Codex launcher logic: `zsh/functions/claude/providers/*`, `scripts/claude-provider.py`, `scripts/claude-provider-prepare.zsh`, `scripts/codex-provider.zsh` | next client launch = **next turn**; a new terminal `claude`/`codex` session; T3 version probes pick it up on their next probe |
| Claude settings knobs written via `--settings` (models, `CLAUDE_CODE_*`) | next turn. The bridge also exports them into the client's environment, so knobs that are read at startup win too |
| Proxy code or config: `scripts/hosted-only-go` (the Go proxy), `scripts/hosted-only-proxy.zsh`, `zsh/functions/claude/providers/enmaas-proxy.zsh`, `zsh/functions/claude/providers/enmaas.zsh` config parts | fingerprint/source-hash change → the **idle** proxy restarts on the next client launch, or during the next fleet-sync run (`llm-proxy-sync`); a source change rebuilds the binary first. A busy proxy is never cut: `llm-proxy-watch` waits for the first idle moment (~50 ms detection) |
| Max output tokens (`HOSTED_ONLY_MAX_OUTPUT_TOKENS` / `ENMAAS_MAX_OUTPUT_TOKENS`, default 128000), the client compaction window (`CLAUDE_CODE_AUTO_COMPACT_WINDOW`, derived from the cap; knobs `HOSTED_ONLY_AUTO_COMPACT_WINDOW` / `ENMAAS_AUTO_COMPACT_WINDOW` / `HOSTED_ONLY_COMPACT_DRIFT_MARGIN`) and the compaction hint (`HOSTED_ONLY_MIN_OUTPUT`, the Go proxy's clamp in `scripts/hosted-only-go`) | **coupled** — change together. Output cap + compaction window: next turn per client launch (both are launcher settings env). Hint/clamp: proxy restart as in the row above. The window makes the client compact before the edge; the proxy trims `max_tokens` and, below `MIN_OUTPUT`, answers a "prompt is too long" 400 as the backstop; see `docs/notes/hosted-only-context-edge.md` |
| `zsh/functions/claude/proxies.zsh`, `scripts/llm-proxy-watch.zsh`, `scripts/fleet-sync.zsh` | next shell for direct use; fleet-sync/the timer uses the new code on its next run |
| Hosted-only proxy ports (#599 merge) | one shared proxy on :4148 serves both flavors; `llm-proxy-sync` restarts it when idle after the config change. An already-running Codex client still pointing at a split :4147 keeps working until it relaunches (a split proxy serves the same merged config) |
| T3 provider instances (`t3/provider-instances.json` → `import-t3-providers`) | next T3 server/app start; the running server does not hot-reload instance settings |
| Skills (`~/.claude/skills`, synced links into Codex/Gemini) | next agent session/turn that loads the skill |
| Hooks (`~/.claude/hooks`, `~/.codex/hooks.json` + trust) | per hook invocation; Codex needs `sync-harnesses.sh` trust refresh after a hooks.json edit |
| Shell functions/aliases/completions (zsh) | new shell (`exec zsh` or a new terminal) |
| launchd/systemd units | `launchctl kickstart`/`bootout`+`bootstrap`; systemd `daemon-reload` + restart |
| Anything on disk (configs, credentials) | processes that read it at start need their restart class above; fleet-sync reports what it restarted |
| Machine restart | nothing special: everything reloads from disk. Only stale *state* (pid files, runtime dirs) matters, and fleet-sync reconciles that |

Rule of thumb: **sync alone never touches a running process.** It updates files
and (for proxies) restarts only what is idle; everything else waits for its own
class above. When in doubt, `llm-proxy-restart required` lists stale proxies and
restarts them on demand.
