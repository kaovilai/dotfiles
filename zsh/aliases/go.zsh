alias gofmtgitdiff='git diff --name-only  | xargs -L 1 go fmt'
alias gofmtgitdiffmain='git diff upstream/main --name-only | grep .go$  | xargs -L 1 go fmt'
alias gofmtgitdiffmaster='git diff upstream/master --name-only | grep .go$  | xargs -L 1 go fmt'
alias grf='golangci-lint run --fix'
alias grfw='golangci-lint-with-retry() {
  local max_attempts=30
  local attempt=1
  while [ $attempt -le $max_attempts ]; do
    if output=$(golangci-lint run --fix 2>&1); then
      echo "$output"
      return 0
    elif echo "$output" | grep -q "parallel golangci-lint is running"; then
      echo "Attempt $attempt/$max_attempts: Waiting for parallel golangci-lint to finish..."
      sleep 1
      ((attempt++))
    else
      echo "$output"
      return 1
    fi
  done
  echo "Timeout: golangci-lint still busy after $max_attempts attempts"
  return 1
}; golangci-lint-with-retry'
