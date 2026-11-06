package main

import (
	"os"
	"os/exec"
	"syscall"
)

const logRotateBytes = 8 << 20

// backgroundMode is claude-provider.py --background: spawn a detached process
// (its own session, stdin from /dev/null, output appended to the log with one
// generation kept past 8 MB). Used by the proxy launch paths through
// claude-provider-prepare.zsh's _claude_proxy_start.
func backgroundMode(logPath string, argv []string) int {
	if st, err := os.Stat(logPath); err == nil && st.Size() > logRotateBytes {
		_ = os.Rename(logPath, logPath+".1")
	}
	log, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return 1
	}
	defer log.Close()
	devnull, err := os.OpenFile(os.DevNull, os.O_RDONLY, 0)
	if err != nil {
		return 1
	}
	defer devnull.Close()
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdin = devnull
	cmd.Stdout = log
	cmd.Stderr = log
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return 1
	}
	return 0
}
