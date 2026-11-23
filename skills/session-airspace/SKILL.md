---
name: session-airspace
description: Pause and resume Claude child sessions on the default tmux server (from session-switcher, or a run-job that uses job-* sessions there) to keep RAM under control, or run a guard that does it automatically. Use when several parallel sessions are running, RAM is high, WSL is near its memory cap, or the user asks to pause, hold, freeze or resume a background session.
---

# Session Airspace

Holds a Claude child with `SIGSTOP` (it and every process under it stop, using no CPU and growing no further) and releases it with `SIGCONT`. Tested on live sessions: a child held for 90 seconds mid-reply, or during a Bash-tool command, finished its turn normally after release.

## Commands

```bash
session-airspace status                       # RAM, then each child FLYING/HOLDING and its memory
session-airspace hold sw-ab12cd               # pause it (targets come from `session-relay list`)
session-airspace release sw-ab12cd            # resume it
session-airspace guard                        # watch: hold at >= 85% RAM, release at <= 75%
session-airspace guard --threshold 80 --interval 10
session-airspace guard --once                 # one check, then exit (cron-friendly)
```

## Guard rules

- At or above the threshold, it holds the flying child with the most memory, one per tick.
- It always leaves one child flying, so work keeps moving even when the pressure comes from elsewhere.
- At 10 points or more below the threshold, it releases one child **it** held. A hold you placed by hand stays until you release it.
- However the guard stops (`Ctrl-C`, `SIGTERM`, a hangup, or an error), it releases everything it was holding. Only `SIGKILL` can strand a hold.

`guard` runs until stopped. Start it in a spare terminal or tmux window, not in a blocking Bash tool call.

## Limits

- A hold stops growth; it frees no memory (the kernel can swap held pages out). A child that alone exceeds RAM still needs to be closed (`session-relay kill`).
- A held child keeps any file or git lock it holds. Release it before another session needs that repository's lock.
- `status` marks a child `not holdable` when it was launched by an older session-switcher or run-job, where `claude` is the tmux pane's own process. tmux resumes such a process instantly, so a hold cannot stick. Relaunch it with the current tools.
- `run-job` pauses a child's `JOB_CHILD_TIMEOUT` clock while it is held. A `session-switcher` child keeps counting toward `SWITCH_TIMEOUT`.
