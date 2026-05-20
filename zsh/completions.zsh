
# Cache infrastructure provided by command-cache.zsh (sourced via .zshrc or below)
if [[ -z "$ZSH_COMPLETION_CACHE_DIR" ]]; then
  _safe_source ~/git/dotfiles/zsh/command-cache.zsh
fi

# Run completion setup in an anonymous function to properly scope local variables.
# Without this, 'local' at the top level of a sourced file is a no-op in ZSH,
# leaving variables like docker_completion_file, gh_completion_cache, etc. in
# the global namespace. Functions defined here are still globally accessible.
() {

# Helper: serve cached completion from fpath; regenerate in background when stale.
# Usage: _regen_tool_completion <tool>
# Assumes the tool supports `<tool> completion zsh`.
_regen_tool_completion() {
  local tool="$1"
  local cache_file="$ZSH_COMPLETION_CACHE_DIR/_${tool}_generated"
  [[ -f "$cache_file" ]] && cp "$cache_file" "${fpath[1]}/_${tool}" &!
  if completion_cache_expired "$cache_file"; then
    ("$tool" completion zsh > "${cache_file}.tmp" 2>/dev/null \
      && mv "${cache_file}.tmp" "$cache_file") &!
  fi
}

# -- PHASE 1: Essential completions (foreground) --

# VS Code shell integration (if we're running in VS Code)
[[ "$TERM_PROGRAM" == "vscode" ]] && command -v code &>/dev/null && . "$(code --locate-shell-integration-path zsh)"

# AWS uses its own completer mechanism (critical for AWS workflows)
if has_command aws_completer; then
  complete -C aws_completer aws
fi

# Docker completion - use centralized cache location (most commonly used)
if has_command docker; then
  local docker_completion_file="$ZSH_COMPLETION_CACHE_DIR/_docker"
  if [[ -f "$docker_completion_file" ]]; then
    cp "$docker_completion_file" "${fpath[1]}/_docker" &!
  fi
  
  # Update check and download in the background
  if [[ "$TERM_PROGRAM" != "vscode" ]] && has_command curl; then
    if completion_cache_expired "$docker_completion_file" $CACHE_TTL_STABLE; then  # 30 days for stable tools
      (curl -sLm 10 https://raw.githubusercontent.com/docker/docker-ce/master/components/cli/contrib/completion/zsh/_docker > "${docker_completion_file}.tmp" && 
      mv "${docker_completion_file}.tmp" "$docker_completion_file" || 
      rm -f "${docker_completion_file}.tmp") &!
    fi
  fi
fi

# -- PHASE 2: Direct completion generation --
# Each completion is generated and written to fpath directly

# OpenShift Install - uses cached file to avoid generating completion on every shell start
if has_command openshift-install; then
  cp ~/git/dotfiles/openshift-install-completion-zsh.txt "${fpath[1]}/_openshift-install" &!
fi

# GitHub CLI completion - cache for stable tools
if has_command gh; then
  local gh_completion_cache="$ZSH_COMPLETION_CACHE_DIR/_gh_generated"
  [[ -f "$gh_completion_cache" ]] && cp "$gh_completion_cache" "${fpath[1]}/_gh" &!
  if completion_cache_expired "$gh_completion_cache"; then  # 7 days
    (gh completion -s zsh > "${gh_completion_cache}.tmp" 2>/dev/null && mv "${gh_completion_cache}.tmp" "$gh_completion_cache") &!
  fi
fi

# Kubernetes CLI - cache for stable tools
has_command kubectl && _regen_tool_completion kubectl

# OpenShift Client - cache for stable tools
has_command oc && _regen_tool_completion oc

# Podman completion - use centralized cache location
if has_command podman; then
  local podman_completion_file="$ZSH_COMPLETION_CACHE_DIR/_podman"
  
  if [[ -f "$podman_completion_file" ]]; then
    cp "$podman_completion_file" "${fpath[1]}/_podman" &!
  fi
  
  # Update check and download in the background
  if [[ "$TERM_PROGRAM" != "vscode" ]] && has_command curl; then
    if completion_cache_expired "$podman_completion_file" $CACHE_TTL_STABLE; then  # 30 days for stable tools
      (curl -sLm 10 https://raw.githubusercontent.com/containers/podman/main/completions/zsh/_podman > "${podman_completion_file}.tmp" && 
      mv "${podman_completion_file}.tmp" "$podman_completion_file" || 
      rm -f "${podman_completion_file}.tmp") &!
    fi
  fi
fi

# Rosa CLI - cached
has_command rosa && _regen_tool_completion rosa

# CCOCTL - cached
has_command ccoctl && _regen_tool_completion ccoctl

# Velero - cached
has_command velero && _regen_tool_completion velero

# YQ - cached
has_command yq && _regen_tool_completion yq

# Kind - cached
has_command kind && _regen_tool_completion kind

# Helm - cached
has_command helm && _regen_tool_completion helm

# Kustomize - cached
has_command kustomize && _regen_tool_completion kustomize

# Direnv - cached
if has_command direnv; then
  local direnv_completion_cache="$ZSH_COMPLETION_CACHE_DIR/_direnv_generated"
  if completion_cache_expired "$direnv_completion_cache"; then
    direnv hook zsh > "$direnv_completion_cache" 2>/dev/null
  fi
  [[ -f "$direnv_completion_cache" ]] && source "$direnv_completion_cache"
fi

# Pipenv - cached
if has_command pipenv; then
  local pipenv_completion_cache="$ZSH_COMPLETION_CACHE_DIR/_pipenv_generated"
  if completion_cache_expired "$pipenv_completion_cache"; then
    _PIPENV_COMPLETE=zsh_source pipenv > "$pipenv_completion_cache" 2>/dev/null
  fi
  [[ -f "$pipenv_completion_cache" ]] && cp "$pipenv_completion_cache" "${fpath[1]}/_pipenv" &!
fi

# IBM Cloud completion - if needed
if [[ -f /usr/local/ibmcloud/autocomplete/zsh_autocomplete ]]; then
  cp /usr/local/ibmcloud/autocomplete/zsh_autocomplete "${fpath[1]}/_ibmcloud" &!
fi

# Claude Code CLI - download from community-maintained repo
if has_command claude || has_command happy; then
  local claude_completion_file="$ZSH_COMPLETION_CACHE_DIR/_claude"
  if [[ -f "$claude_completion_file" ]]; then
    cp "$claude_completion_file" "${fpath[1]}/_claude" &!
    # Also register completions for happy (claude is aliased to happy)
    sed 's/^#compdef claude/#compdef claude happy/' "$claude_completion_file" > "${fpath[1]}/_happy" &!
  fi
  if has_command curl && completion_cache_expired "$claude_completion_file"; then  # 7 days
    (curl -sLm 10 https://raw.githubusercontent.com/wbingli/zsh-claudecode-completion/main/_claude > "${claude_completion_file}.tmp" &&
    mv "${claude_completion_file}.tmp" "$claude_completion_file" &&
    cp "$claude_completion_file" "${fpath[1]}/_claude" &&
    sed 's/^#compdef claude/#compdef claude happy/' "$claude_completion_file" > "${fpath[1]}/_happy" ||
    rm -f "${claude_completion_file}.tmp") &!
  fi
fi

# Netbird - cached
has_command netbird && _regen_tool_completion netbird

# Custom code-git completion
cat << EOF > "${fpath[1]}/_code-git" &!
#compdef code-git

_code-git() {
    local -a files
    files=(~/git/*(N/:t))
    _describe 'files' files
}

_code-git
EOF

} # end anonymous function

# Help command to view cache status
zsh_completion_cache_status() {
  echo "ZSH completion cache directory: $ZSH_COMPLETION_CACHE_DIR"
  echo "Cache files:"
  local file
  for file in "$ZSH_COMPLETION_CACHE_DIR"/_*(N); do
    if [[ -f "$file" ]]; then
      local modified size
      modified=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$file" 2>/dev/null || stat -c "%y" "$file" 2>/dev/null | cut -d'.' -f1)
      size=$(du -h "$file" | cut -f1)
      local name="${file:t}"
      echo "  $name ($size) - Last updated: $modified"
    fi
  done
}

# Command to clear the completion cache
zsh_completion_cache_clear() {
  echo "Clearing ZSH completion cache..."
  rm -f "$ZSH_COMPLETION_CACHE_DIR"/_*
  echo "Cache cleared. Restart your shell to regenerate completions."
}
