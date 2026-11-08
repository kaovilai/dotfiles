# Fleet usage streaming into llm-usage

Design note for: seeing copilot-api / EnMaaS / hosted-only usage from every
machine in the fleet inside the local `llm-usage` views (CLI tables, `serve`
dashboard, menubar monitor + floating window), live while those machines are
reachable.

Status: implemented (all phases), plus in-flight streaming (`fleet stream`,
see its section). 2026-11-07. Decisions from review:

1. **Aggregation topology** — default: any machine pulls the others (config is
   machine-local); no designated aggregator.
2. **First-sync history** — last 7 days, then incremental backfill in 30d
   chunks per refresh until the peer's oldest events month is covered (the
   export meta carries the months present, so backfill never stops early on a
   quiet month). Bound: the months manifest covers the proxy log only; a
   transcript-heavy peer (copilot usage) instead stops after two consecutive
   empty chunks, so transcript history older than a ~60-day usage gap is not
   pulled — a reliable bound would mean parsing every transcript on the peer
   on every export. Documented tradeoff, not a silent miss.
3. **Fleet membership** — tailscale-reachable hosts only for now (netbird/LAN
   hosts are just another `ssh:` entry when wanted).

## Goal

Every fleet machine runs the same local proxies (copilot-api :4141, EnMaaS
:4146, hosted-only :4148, …) and writes the same `events-YYYY-MM.jsonl` lines
into its own `$LLM_USAGE_DIR` (~/.local/state/llm-usage). Today each machine
only sees its own traffic. We want the machine you are sitting at to also show
the other machines' usage — pulled when they are reachable, clearly marked
stale when they are not — without a new always-on service, a listening port, or
a shared store to babysit.

Non-goals:

- No central server, no cloud store, no new daemon on any machine.
- No cross-machine rerouting or quota sharing — read-only visibility only.
- Remote machines do not need to know they are being watched (no config change
  on their side beyond having current dotfiles, which fleet-sync already
  guarantees).

## Why SSH pull (decision)

The fleet is already fully meshed for SSH: tailscale MagicDNS names, LAN
IPs, and corp netbird. fleet-sync keeps every
machine's dotfiles checkout current. So the aggregation machine can, at any
moment, run a read-only command on any peer and get exactly the data it needs.

| Option | Verdict |
|---|---|
| **SSH pull, on-host export, local merge cache** (chosen) | No new infra. Encrypted, authenticated by existing keys. "Reachable" falls out naturally (ssh succeeds/fails). Remote side is one stdlib-python subcommand that already exists in every checkout. |
| Push events to a git repo (fleet-sync cadence) | Store-and-forward works offline-both-ways, but hourly = not streaming, and months of JSONL in git is churn. Revisit only if pull proves insufficient. |
| Push to a central collector (always-on box) | New service, new auth, new failure mode; one machine must be up for others to report. Rejected. |
| Per-host `llm-usage serve` + HTTP fetch | Listening ports on every machine, auth problem, and `serve` is localhost-only by design today. Rejected. |

Direction: pull-only, one-way (aggregator → peers). Peers never write to the
aggregator, so there is no loop and no write surface. Any machine can be an
aggregator by configuring the others — the fleet config (below) is per-machine
local state, not committed.

## Architecture

```
 peer machine (any configured host)                this machine (aggregator)
 ────────────────────────────────────                ──────────────────────────────
 events-*.jsonl  ← proxies (as today)                 load_proxy / load_auto (today)
 inflight-*.json                                          │
 ~/.claude/projects, ~/.codex/sessions                    ├─ local events  (host = "local")
        │                                                 ├─ STATE/fleet/<host>/events-*.jsonl
        ▼                                                │   (host = <name>, filled by puller)
 `llm-usage export --since T`   ◄── ssh (ControlMaster) ─┘
   merged events + inflight,        `llm-usage fleet refresh`   (lock + TTL guarded)
   host-tagged, stdlib python                                     ▲
                                                                   │ triggers (async, cheap)
                                                    menubar 30 s poll · serve 30 s · tail -f
```

Three pieces:

1. **Remote: `llm-usage export --since <epoch>`** — new subcommand. Runs the
   exact `load_auto` merge the CLI already does (proxy log + transcript fill,
   transcript caches reused), plus the current `inflight` snapshot, and prints
   JSONL on stdout: one event per line, each carrying the full existing event
   schema plus `"host": "<shortname>"` (from `hostname -s` or config) and an
   `"eid"` (see dedup). Non-zero exit with a one-line stderr on failure.
   Stdlib only, works on macOS + Linux peers, needs nothing but the dotfiles
   checkout — i.e. nothing new to deploy.

2. **Local: `llm-usage fleet refresh`** — the puller. For each configured host,
   concurrently (ThreadPoolExecutor, 60 s hard timeout per export, ssh
   compression on — a first sync streams a full 7d payload, ~12MB uncompressed
   on a busy peer):
   `ssh -o ControlMaster=auto -o ControlPath=/tmp/llm-usage-fleet-<uid>/cm-%C -o
   ControlPersist=15m -o BatchMode=yes -o ConnectTimeout=3 <target> '<dotfiles>/scripts/llm-usage export --since <T>'`
   and store the result in `$STATE/fleet/<host>/events-YYYY-MM.jsonl`. The
   ControlPath dir is only used after lstat validation (real dir, our uid, no
   group/other bits) or falls back to `$STATE/fleet`; multiplexing is dropped
   entirely when even that path is too long for a unix socket. ControlMaster
   keeps the steady-state cost one reused TCP connection; the Tailscale/
   WireGuard path is already warm.

   Guarded so any caller can trigger it cheaply:
   - `flock` on `$STATE/fleet/refresh.lock` — one refresh at a time, later
     callers exit 0 immediately instead of waiting.
   - TTL: if `fleet/<host>/status.json` says last success < 25 s ago, skip that
     host (the menubar's 30 s poll then usually hits nothing but the lock).

   Per-host state in `status.json`: `{"last_ok": <ts>, "last_error": "…",
   "last_event_t": <ts>, "pull_ms": <n>, "version": "llm-usage git describe"}`.
   The pull since-time is `last_event_t - 2 s` (small overlap for safety);
   overlap is deduped on ingest by `id`.

3. **Merge layer** — `load()` (and `menubar_data`) extend from "local events"
   to "local events + every `fleet/<host>/events-*.jsonl`". Each event gets
   `host` = `"local"` for this machine's own files, the configured name for
   pulled files. Because every request is served by exactly one machine's
   proxy (ports are per-machine loopback), hosts are disjoint by construction:
   the merge is a concatenation, no cross-host dedup needed beyond the per-host
   ingest dedup. `LLM_USAGE_FLEET=off` (or no config) restores today's
   single-machine behavior exactly.

### Event identity (dedup on ingest)

Today's events have no unique id. `export` synthesizes an `eid` field
(`event_eid`): for transcript events, a hash of the message `id` alone — usage
grows while a reply streams, so the identity must not depend on token counts;
a changed line under the same eid is a revision and replaces the stored one
(and a revision whose new timestamp crossed a UTC month boundary is relocated
from the neighbouring month file). For proxy events, a
`sha1(t | start | port | served | requested | in | out | cache_read)` — both
writers emit `start` with millisecond precision, which separates same-second
requests. The host is not part of the hash (it is stamped at ingest instead,
from the config name). On ingest the puller drops eids already present in the
host's month file (`_fleet_month_eids` scans the month whole; only the months
a pull touches are read). Residual collision: identical requests starting in
the same millisecond.

### Copilot is transcript-derived — export handles that

copilot-api (4141) has no usage callback; its events come from Claude Code /
Codex transcripts on each machine. `export` therefore must run the transcript
parsers remotely (they already have mtime-based caches under `STATE/cache-*`),
and the aggregator must **not** re-derive remote copilot usage from its own
transcripts. The `via: transcript` events arrive pre-tagged `host: <name>` and
flow through the same merge as proxy events. Transcript-derived rows carry no
latency/error data; the UI already flags them `source: transcript`.

## Configuration

`~/.config/llm-usage/fleet.json` (not committed; machine-local by design),
env-overridable per the repo's existing pattern:

```jsonc
{
  "hosts": [
    {"name": "laptop", "ssh": "laptop.example.ts.net"},
    {"name": "server", "ssh": "server", "dir": "~/git/dotfiles"},
    {"name": "devbox", "ssh": "devbox.local", "dir": "~/git/dotfiles"}
  ]
}
```

- `ssh`: anything ~/.ssh/config resolves (tailscale name, LAN IP, alias).
- `dir`: dotfiles checkout on the peer (default `~/git/dotfiles`; matches
  fleet-sync's `FLEET_DOTFILES_DIR`). The remote command is
  `<dir>/scripts/llm-usage export …` — no shell profile needed, works from
  BatchMode ssh.
- `LLM_USAGE_FLEET` env: `off` disables; a comma list `name=ssh-target`
  overrides/extends when a file is overkill (same style as
  `LLM_USAGE_PORT_NAMES`).
- Commit only `fleet.json.example` + this doc; hostnames/IPs stay machine-local
  (the repo is public).

Hardening (optional, later): restrict the key used for fleet pulls with a
`command="…/llm-usage export"` forced-command entry on peers, so that key can
do nothing but export usage.

## UI

### CLI

- Global `--host <name>` filter (default all: local + fleet) and
  `summary --by host`, `--by host,model` for a per-machine table.
- `llm-usage status`: new Fleet section — host, reachable (last ssh ok),
  staleness, event counts, pull latency.
- New `llm-usage fleet` subcommand: `refresh` (manual pull), `status`
  (per-host detail incl. last_error), `hosts` (resolved config).
- `llm-usage tail -f --fleet`: the follow loop reads the local + fleet caches
  every 1 s and prints new remote events with a `HOST` column; the TTL-guarded
  background refresh pulls peers, so peer deltas land roughly every 25 s plus
  pull latency.

### menubar-data (JSON)

Additive keys, existing consumers keep working:

```jsonc
{"fleet": {
   "enabled": true,
   "hosts": [ {"name": "server", "state": "up" | "stale" | "down",
               "last_ok_s": 42, "last_event_s": 12,
               "m15": {…}, "h1": {…}, "inflight": {…}} ],
   "stale_after_s": 180
 }}
```

and every existing aggregate (proxies, by_model, by_proxy, series,
by_vendor) computed over local + fleet events, each event carrying `host`.
`state`: `up` = pulled fresh; `stale` = unreachable but has cached events
(show them dimmed with age); `down` = never synced. Local machine shows as
host `local` and is always `up`.

### Swift menubar helper

- **Menu**: a Fleet section under the proxies list — one row per host:
  colored dot (green/red/gray = up/down/stale), name, `12 req · 1 err · 15m`,
  stale-age subtitle, `last synced 18:42`. Click → per-host submenu with its
  provider share (same vendor logos/colors as the status cluster).
- **Floating window**: a compact fleet strip — per-host one line
  (name · sparkline of the hour · reqs · errors) above or beside the existing
  provider panel; hovering a host row filters the traffic graph to that host's
  per-minute series — the requests chart's counts and the tokens chart's tok/s,
  the stacked view's tokens panel included (`--hover host:<name>`, the same
  plumbing as `--hover vendor:` — implemented). Latency/ttft carry no per-host
  series, so a host hover changes nothing there.
- The helper's existing 30 s `poll()` is the trigger cadence: `menubar-data`
  fires the lock-guarded async refresh, then reads the cache — the UI path
  never blocks on ssh.

### serve dashboard

Host filter dropdown (local / each fleet host / all) applied to every graph;
the per-minute stacked bars gain an optional "stack by host" toggle. Reuses
the same `host` field; no schema change beyond what menubar-data gets.

## Streaming semantics (what "live" means here)

| Surface | Cadence | Mechanism |
|---|---|---|
| Menubar + floating window | ≤ 30 s + pull latency | 30 s poll → async fleet refresh (lock+TTL) → cached events |
| `tail -f --fleet` | ≈ 25 s (refresh TTL) + pull latency | follow loop reads the cache every 1 s; the TTL-guarded background refresh pulls peers |
| `serve` | 30 s | dashboard refresh thread triggers the same refresh |
| In-flight "now" | immediate (stream) / next pull (fallback) | `fleet stream` (below): one long-lived ssh per peer pushes `watch-inflight` snapshots into `fleet/<host>/inflight.json` on every request boundary; the pull path's `--inflight` export is the fallback when no stream runs |

A machine that goes offline keeps its last-synced events in the cache and the
UI marks them stale — history never disappears, only freshness does. When it
comes back, the next pull resumes from `last_event_t` with no gap. While the
aggregator itself is offline (or a peer needs a tailscale reauth), the
automatic kick backs off: a host whose last pull failed is retried once per
5 minutes, not once per poll (`llm-usage fleet refresh` by hand always tries).

## In-flight streaming (`fleet stream`)

Events do not need sub-second latency; in-flight membership does — a wait bar
that lags 30 s shows requests that already ended and misses ones that just
started. A literal websocket would need a listening port per peer (rejected
above); an ssh **stdio stream** gives the same push semantics over the existing
auth and transport:

- **Peer side: `llm-usage watch-inflight`** — prints a `{"_watch": 1}` hello,
  then one `{"t", "requests"}` snapshot whenever the local in-flight set
  changes (polled every 0.25 s; the files are tiny), plus a heartbeat every
  15 s while unchanged so a long request never trips the reader's staleness
  drop. Same read-only surface as `export`, so a forced-command key can be
  pinned to it.
- **Aggregator side: `llm-usage fleet stream`** — one long-lived ssh per host
  (ControlMaster, ServerAlive so a network change ends both ends within ~45 s)
  reading those snapshots and atomically rewriting the same
  `fleet/<host>/inflight.json` the pull path fills (unique tmp name per write:
  the two hold different locks and may write concurrently). Reconnects with a
  doubling backoff capped at the pull backoff; a connection that held ≥ 60 s
  is healthy and resets it. Singleton via `flock` on `fleet/stream.lock`, so
  every consumer can spawn it fire-and-forget: the menubar helper does so at
  startup, `tail -f --fleet` and `serve` via `fleet_stream_kick()`
  (kick-file guarded, 60 s). `LLM_USAGE_FLEET_STREAM=off` disables.
  `local_dir` peers (tests, second state dirs) are polled in process instead.
  Every fleet ssh (pulls too) carries `ServerAlive*`: whichever invocation
  creates the shared `cm-%C` master defines its keepalives, so a pull-created
  master must not leave a multiplexed stream reader blocked on a blackhole.
  The singleton rescans `fleet_hosts()` every 60 s, so a peer added to
  `fleet.json` gets its thread without a restart (a REMOVED peer keeps
  streaming until restart — its snapshots age out like any other); on
  SIGINT/SIGTERM it terminates the ssh children (EOF unblocks their readers)
  and joins the workers before releasing the lock.
- **Pull/stream coordination**: while the stream is live (flock held AND its
  snapshot heartbeat-fresh), a pull skips its in-flight write — the pull
  captured the peer's state earlier and would resurrect requests the stream
  already watched finish. A stale or dead stream hands ownership back to the
  pull, so the fallback is automatic.
- **Division of labor**: the stream owns *freshness* of in-flight only; the
  TTL refresh stays the source of truth (events, up/down state, backfill,
  status.json). A dead stream costs accuracy, never correctness —
  `read_fleet_inflight`'s age drop still removes ghosts once the snapshot's
  `t` goes stale.
- **Menubar**: a vnode watch covers one directory's entries, not its
  descendants — so the helper watches the fleet base dir for host dirs
  appearing/vanishing and each `fleet/<host>/` for its `inflight.json`
  tmp+rename (reconciled on every base-dir event). `refreshInflight` reads
  `fleet/<host>/inflight.json` directly, gated on the last payload's fleet
  config (enabled + configured hosts, like `read_fleet_inflight`), and a host
  with a successfully read snapshot — even an empty one — is owned by the
  file: the 30 s payload must not re-add requests the stream watched finish.
  Peer wait bars move at request boundaries like local ones.
  The spawned streamer deliberately outlives the app: `serve` and the CLI
  read the same cache, and the flock means a relaunch adopts the running one.

## Privacy & security

- Transport: ssh (encrypted, key-authenticated, BatchMode — no prompts).
- Remote surface: one read-only subcommand over stdin/stdout. Optional
  forced-command key restriction pins even that.
- Data: model names, token counts, latencies, error classes — no prompts, no
  transcript content (transcript parsing extracts usage only, as today).
- Config with hostnames stays in `~/.config` (uncommitted); repo gets only an
  example file.

## Testing (extends tests/llm-usage.zsh)

- `export` fixtures: given a STATE dir + transcript fixtures, output is the
  expected merged, host-tagged, id-carrying JSONL (reuse existing fixture
  builders).
- Ingest dedup: pull the same window twice → no duplicate ids; overlapping
  since-window → only new lines appended.
- Merge: local + two fake fleet dirs (via `LLM_USAGE_FLEET` pointing at a
  fixture config whose hosts use `{"local_dir": "<fixture state>"}` — a
  second transport beside `ssh` that reads a directory in-process; also the
  natural seam for tests) → `summary --by host` counts add up, `--host x`
  filters.
- menubar-data: golden JSON with fleet keys; hosts down → `state: "down"`,
  cached events still present.
- Staleness: freeze `now` (the codebase already threads `now=` through
  `menubar_data`) → stale thresholds.

## Rollout

1. **Phase 1 — data plane**: `export` subcommand + `fleet refresh` + config +
   merge + `--host`/`--by host` + `status` fleet section. Verified with the
   `local_dir` transport (two STATE dirs on this machine) before any ssh.
2. **Phase 2 — UI**: menubar-data fleet keys, Swift menu/window sections,
   `serve` host filter.
3. **Phase 3 — live**: `tail -f --fleet`, inflight passthrough into the
   window's wait bars, hover-by-host filtering.
4. **Later (only if wanted)**: forced-command key hardening; a peer-side
   `fleet-sync`-installed sshd `Match` block so pulls survive password-less
   headless boots; per-host provider-key staleness (which machine's EnMaaS
   quota is about to trip).

Take-effect: config file + code live immediately (fresh process per
invocation); the menubar helper picks fleet data up on its next 30 s poll —
no restart needed (see docs/notes/change-take-effect.md).

## Decisions (resolved; see top of file)

1. Any machine pulls the others — no designated aggregator.
2. First sync = last 7 days, then 30d backfill chunks per refresh until the
   peer's oldest events month is covered (export meta lists the months).
3. Tailscale-reachable hosts only for now; a netbird/LAN host is just another
   `ssh:` config entry when wanted.
