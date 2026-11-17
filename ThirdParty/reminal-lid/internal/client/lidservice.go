// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Harshal Gajjar
// Modified 2026 for Clamshell Assistant.
//
// RunLidService is what the "lid-agent" remote session used to provide to the
// closed-lid feature, without the session: the idle-sleep inhibitor every
// Reminal agent holds (keepawake.Start, main.go), the always-unlocked display
// inhibitor (Agent.setStayUnlocked, windows.go/agent.go) and the closed-lid
// display census + lid dimmer in its session form (vdisplayLoop with
// isDaemon=false), which defers to a full Reminal daemon when one owns the
// census. Unlike a session, the inhibitors are held only while their setting
// is on. It ends when stop closes.

package client

import (
	"time"

	"reminal/internal/config"
	"reminal/internal/keepawake"
)

var settingsPoll = 2 * time.Second

func RunLidService(stop <-chan struct{}) {
	keepawake.ReapOrphans()
	done := make(chan struct{})
	go func() { vdisplayLoop(stop, false); close(done) }()
	var stopIdle, stopDisplay func()
	release := func(f *func()) {
		if *f != nil {
			(*f)()
			*f = nil
		}
	}
	defer release(&stopIdle)
	defer release(&stopDisplay)
	for {
		s := config.LoadSettings()
		if s.ClosedLid && stopIdle == nil {
			stopIdle = keepawake.Start()
		} else if !s.ClosedLid {
			release(&stopIdle)
		}
		if s.StayUnlocked && stopDisplay == nil {
			stopDisplay = keepawake.StartDisplay()
		} else if !s.StayUnlocked {
			release(&stopDisplay)
		}
		if sleepOrStop(stop, settingsPoll) {
			<-done
			return
		}
	}
}
