# Hosted-only GHA reviewer

`.github/workflows/hosted-only-review.yml` — every PR gets a review from the
`claude-hosted-only` profile (EnMaaS GLM, free tier) through the same hosted-only
proxy as the local launcher.

- **Proxy**: cloned from this repo at `DOTFILES_REF` (default `main`), Go binary
  cached per dotfiles sha, port 4148. Same engine as local: GLM→DeepSeek reroute
  for image-bearing requests, thinking cutoff for the classifier, 429 reset
  rewrite, retry caps. Model ids follow this repo (`_hop_glm`) — a GLM bump here
  updates the reviewer on the next run, no workflow edit needed.
- **Secrets**: `ENMAAS_API_KEY` (inference). `APP_ID`/`APP_PRIVATE_KEY` optional
  (custom GitHub App) — enables `@claude` mention conversations on PRs; when
  absent the action falls back to `github.token` (auto-reviews only, comments
  don't retrigger CI — no loops).
- **Triggers**: `pull_request` (opened/synchronize/reopened → auto review),
  `issue_comment` and `pull_request_review_comment` containing `@claude`.
- **Install/update/switch**: managed by the `claude-gha-hosted-only` skill in
  [kaovilai/.claude](https://github.com/kaovilai/.claude) —
  `install-reviewer.sh kaovilai/dotfiles` (re-run = refresh to current template;
  `--direct` = no-proxy variant for text-only repos, no image fallback).
