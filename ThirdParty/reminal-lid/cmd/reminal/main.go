// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Harshal Gajjar
// Modified 2026 for Clamshell Assistant: a closed-lid-only build of Reminal.
// Kept: `settings` (non-interactive form of cmd/reminal/settings.go, same
// ~/.reminal/settings.json and output) and `service` (see RunLidService).
// Removed: every remote feature — terminal sharing, sessions, relay, window and
// desktop mirroring/control, file transfer, port exposure, owners/machines,
// upgrades, MCP and agent integrations.

package main

import (
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"reminal/internal/client"
	"reminal/internal/config"
)

const version = "3.19.4-lid"

type row struct {
	key string
	get func(*config.Settings) bool
	set func(*config.Settings, bool)
}

var rows = []row{
	{"always-unlocked", func(s *config.Settings) bool { return s.StayUnlocked }, func(s *config.Settings, v bool) { s.StayUnlocked = v }},
	{"closed-lid", func(s *config.Settings) bool { return s.ClosedLid }, func(s *config.Settings, v bool) { s.ClosedLid = v }},
}

func onOff(v bool) string {
	if v {
		return "on"
	}
	return "off"
}

func settings(args []string) error {
	s := config.LoadSettings()
	if len(args) == 0 {
		fmt.Println("reminal settings:")
		for _, r := range rows {
			fmt.Printf("  %-20s %s\n", r.key, onOff(r.get(&s)))
		}
		return nil
	}
	if len(args) != 2 {
		return fmt.Errorf("usage: reminal settings <always-unlocked|closed-lid> on|off")
	}
	for _, r := range rows {
		if r.key == strings.ToLower(args[0]) {
			var v bool
			switch strings.ToLower(args[1]) {
			case "on":
				v = true
			case "off":
			default:
				return fmt.Errorf("expected on|off, got %q", args[1])
			}
			r.set(&s, v)
			if err := config.SaveSettings(s); err != nil {
				return err
			}
			// Sleep (pmset disablesleep) is applied by Clamshell Assistant itself;
			// the inhibitors and the display half are picked up by `service`.
			fmt.Printf("%s → %s\n", r.key, onOff(v))
			return nil
		}
	}
	return fmt.Errorf("unknown setting %q", args[0])
}

func main() {
	client.SetBuildVersion(version)
	var err error
	switch arg := append(os.Args[1:], "")[0]; arg {
	case "settings":
		err = settings(os.Args[2:])
	case "service":
		// Runs until stdin closes (the parent's lifeline) or SIGINT/SIGTERM.
		stop := make(chan struct{})
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
		go func() { _, _ = io.Copy(io.Discard, os.Stdin); sig <- syscall.SIGTERM }()
		go func() { <-sig; close(stop) }()
		client.RunLidService(stop)
	case "version":
		fmt.Println("reminal " + version + " (closed-lid build for Clamshell Assistant)")
	default:
		err = fmt.Errorf("usage: reminal settings [name on|off] | service | version")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "reminal:", err)
		os.Exit(1)
	}
}
