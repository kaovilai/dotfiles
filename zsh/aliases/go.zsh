_gofmt_files() {
    local diff_args=("$@")
    if ! command -v go &>/dev/null; then
        echo "❌ go not found. Install it with: brew install go" >&2
        return 1
    fi
    local files
    files=$(git diff "${diff_args[@]}" --name-only | grep "\.go$")
    if [[ -z "$files" ]]; then
        echo "No modified .go files to format"
        return 0
    fi
    xargs -L 1 go fmt <<< "$files"
}
gofmtgitdiff()       { _gofmt_files; }
gofmtgitdiffmain()   { _gofmt_files upstream/main; }
gofmtgitdiffmaster() { _gofmt_files upstream/master; }
gofmtgitdiffoadp()   { _gofmt_files upstream/oadp-dev; }
alias grf='golangci-lint run --fix'
golangci-lint-with-retry() {
  if ! command -v golangci-lint &>/dev/null; then
    echo "❌ golangci-lint not found. Install it with: brew install golangci-lint" >&2
    return 1
  fi
  local max_attempts=30
  local attempt=1
  local output
  while [[ $attempt -le $max_attempts ]]; do
    if output=$(golangci-lint run --fix 2>&1); then
      echo "$output"
      return 0
    elif grep -q "parallel golangci-lint is running" <<< "$output"; then
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
}
alias grfw='golangci-lint-with-retry'

# Vulnerability scanning
alias govulncheck='govulncheck ./...'

# Go test shortcuts
alias gotest-race='go test -race ./...'
alias gotest-v='go test -v ./...'
alias gotest-cover='go test -coverprofile=coverage.out ./... && go tool cover -html=coverage.out'

# Cross-compilation presets
alias gobuild-linux-amd64='GOOS=linux GOARCH=amd64 go build'
alias gobuild-linux-arm64='GOOS=linux GOARCH=arm64 go build'

# Update all golang.org/x dependencies
alias go-update-x='go list -m all | grep golang.org/x | cut -d'"'"' '"'"' -f1 | xargs go get && go mod tidy'
