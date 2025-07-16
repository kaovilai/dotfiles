alias gofmtgitdiff='git diff --name-only  | xargs -L 1 go fmt'
alias gofmtgitdiffmain='git diff upstream/main --name-only | grep .go$  | xargs -L 1 go fmt'
alias gofmtgitdiffmaster='git diff upstream/master --name-only | grep .go$  | xargs -L 1 go fmt'
alias grf='golangci-lint run --fix'
