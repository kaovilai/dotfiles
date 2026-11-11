# Hosted-only GHA reviewer

`.github/workflows/hosted-only-review.yml` — PRs from branches in this repo get a
review from the `claude-hosted-only` profile (EnMaaS GLM, free tier) through the
same hosted-only proxy as the local launcher. The workflow must exist on the
default branch (install/update via the skill, below). Fork PRs get no automatic
review: GitHub hides repo secrets (`ENMAAS_API_KEY`) from fork-`pull_request`
runs, so the proxy cannot start.

- **Proxy**: cloned from this repo at `DOTFILES_REF` (default `main`), Go binary
  cached per dotfiles sha, port 4148. Same engine as local: GLM→DeepSeek reroute
  for image-bearing requests, thinking cutoff for the classifier, 429 reset
  rewrite, retry caps. Model ids follow this repo (`_hop_glm`) — a GLM bump here
  updates the reviewer on the next run, no workflow edit needed.
- **Secrets**: `ENMAAS_API_KEY` (inference). `APP_ID`/`APP_PRIVATE_KEY` optional
  (custom GitHub App) — reviews post under the app identity; when absent the
  action falls back to `github.token` (whose comments don't retrigger CI).
- **`@claude` mentions: opt-in** — the job gate requires repo variable
  `HOSTED_ONLY_CLAUDE_MENTIONS=true` (set with
  `gh variable set HOSTED_ONLY_CLAUDE_MENTIONS --repo kaovilai/dotfiles --body true`)
  and only OWNER/MEMBER/COLLABORATOR comments trigger, so bots quoting `@claude`
  in review bodies never fire it. Off by default because `claude.yml` already
  answers `@claude` via the Claude subscription OAuth; enable here only after
  disabling that workflow.
- **Install/update/switch**: managed by the `claude-gha-hosted-only` skill in
  [kaovilai/.claude](https://github.com/kaovilai/.claude) —
  `install-reviewer.sh kaovilai/dotfiles` (re-run = refresh to current template;
  `--direct` = no-proxy variant for text-only repos, no image fallback).
