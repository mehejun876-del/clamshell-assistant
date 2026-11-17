// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Harshal Gajjar
// Modified 2026 for Clamshell Assistant: the functions below are copied
// verbatim from Reminal v3.19.4 internal/client (windows.go, mirror.go,
// capture_helper.go, directoryhost.go, service.go) so the closed-lid files
// build without the remote-access code that surrounds them. The helper search
// is reduced to "next to this binary" (the release behaviour; no PATH).

package client

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

var buildVersion = "dev"

func SetBuildVersion(v string) { buildVersion = v }

func isReleaseBuild(version string) bool { return version != "" && version != "dev" }

const runCeiling = 30 * time.Second

func run(name string, args ...string) (string, error) { return runTimeout(runCeiling, name, args...) }

func runTimeout(d time.Duration, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), d)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.WaitDelay = 2 * time.Second
	out, err := cmd.Output()
	if ctx.Err() != nil {
		return "", fmt.Errorf("%s: gave up after %s", name, d)
	}
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok && len(ee.Stderr) > 0 {
			return "", fmt.Errorf("%s: %s", name, strings.TrimSpace(string(ee.Stderr)))
		}
		return "", fmt.Errorf("%s: %w", name, err)
	}
	return strings.TrimSpace(string(out)), nil
}

func atoi(s string) int {
	n, _ := strconv.Atoi(strings.TrimSpace(s))
	return n
}

func sleepOrStop(stop <-chan struct{}, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-stop:
		return true
	case <-t.C:
		return false
	}
}

type lineLogger struct {
	mu     sync.Mutex
	prefix string
	buf    []byte
	out    io.Writer
}

func (l *lineLogger) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, c := range p {
		if c == '\n' {
			out := l.out
			if out == nil {
				out = os.Stderr
			}
			fmt.Fprintf(out, "%s%s\n", l.prefix, l.buf)
			l.buf = l.buf[:0]
			continue
		}
		if len(l.buf) < 4096 {
			l.buf = append(l.buf, c)
		}
	}
	return len(p), nil
}

func captureHelperPath() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	cand := filepath.Join(filepath.Dir(exe), "reminal-capture")
	if st, err := os.Stat(cand); err == nil && !st.IsDir() {
		return cand, nil
	}
	return "", errors.New("reminal-capture not found")
}

func helperCommand(path string, args ...string) *exec.Cmd {
	cmd := exec.Command(path, args...)
	cmd.Env = filterHelperEnv(os.Environ(), isReleaseBuild(buildVersion))
	return cmd
}

func filterHelperEnv(env []string, release bool) []string {
	out := make([]string, 0, len(env))
	for _, kv := range env {
		name, _, _ := strings.Cut(kv, "=")
		switch {
		case strings.HasPrefix(name, "DYLD_"), strings.HasPrefix(name, "LD_"),
			name == "REMINAL_CAPTURE_HELPER", name == "REMINAL_OVERLAY_BIN",
			name == "REMINAL_LIDDIM_FAKE" && release:
			continue
		}
		out = append(out, kv)
	}
	return out
}
