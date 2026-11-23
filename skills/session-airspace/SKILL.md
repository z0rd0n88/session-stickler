---
name: session-airspace
description: Air Traffic Control memory management for background agent sessions. Freezes sessions with SIGSTOP when RAM pressure is high, and releases them with SIGCONT when headroom opens up.
---

# Session Airspace

`session-airspace` provides POSIX-level process holding patterns for parallel Claude Code and agent sessions. It monitors WSL/Linux memory usage and prevents silent kernel OOM termination.

## Quick Start

The command ships in this plugin as `${CLAUDE_PLUGIN_ROOT}/scripts/session-airspace`; run it by that path, as below. When the skill is installed on its own instead of as a plugin, that path has no plugin directory in front of it: run the bare `session-airspace` from `PATH` instead.

```bash
# Check memory overview and process holding states
"${CLAUDE_PLUGIN_ROOT}/scripts/session-airspace" status

# Put a background session on hold (SIGSTOP)
"${CLAUDE_PLUGIN_ROOT}/scripts/session-airspace" hold 1

# Resume a paused session (SIGCONT)
"${CLAUDE_PLUGIN_ROOT}/scripts/session-airspace" release 1

# Guard against OOM: hold the largest session while RAM >= 85%, check every 5s
"${CLAUDE_PLUGIN_ROOT}/scripts/session-airspace" guard --threshold 85 --interval 5

# One check and exit (respects --threshold); positional `guard 85 5` also works
"${CLAUDE_PLUGIN_ROOT}/scripts/session-airspace" guard --threshold 90 --once
```

## States

* **`FLYING`**: Process is active and running or sleeping normally (`State != T`).
* **`HOLDING`**: Process is paused via `SIGSTOP` (`State == T`), consuming memory but 0% CPU, waiting for clearance.
