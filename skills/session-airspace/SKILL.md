---
name: session-airspace
description: Air Traffic Control memory management for background agent sessions. Freezes sessions with SIGSTOP when RAM pressure is high, and releases them with SIGCONT when headroom opens up.
---

# Session Airspace

`session-airspace` provides POSIX-level process holding patterns for parallel Claude Code and agent sessions. It monitors WSL/Linux memory usage and prevents silent kernel OOM termination.

## Quick Start

```bash
# Check memory overview and process holding states
session-airspace status

# Put a background session on hold (SIGSTOP)
session-airspace hold 1

# Resume a paused session (SIGCONT)
session-airspace release 1

# Guard against OOM: hold the largest session while RAM >= 85%, check every 5s
session-airspace guard --threshold 85 --interval 5

# One check and exit (respects --threshold); positional `guard 85 5` also works
session-airspace guard --threshold 90 --once
```

## States

* **`FLYING`**: Process is active and running or sleeping normally (`State != T`).
* **`HOLDING`**: Process is paused via `SIGSTOP` (`State == T`), consuming memory but 0% CPU, waiting for clearance.
