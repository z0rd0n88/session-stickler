---
name: session-relay
description: Headless and Claude Desktop-friendly terminal bridge for managing background agent sessions without requiring tmux attach.
---

# Session Relay

`session-relay` lets you inspect, steer, and manage background agent sessions running in tmux directly from headless environments or Claude Desktop (where `tmux attach` is unavailable).

## Quick Start

```bash
# List active sessions and their current terminal preview
session-relay list

# Send follow-up prompt to a session without attaching
session-relay send 1 "Run pytest and summarize failures"

# Read the latest terminal output from a session
session-relay read 1 30

# Terminate a finished session
session-relay kill 1
```

## Why It Matters

In Claude Desktop on Windows/WSL, terminal standard input is not a TTY, meaning `tmux attach` cannot be invoked interactively. `session-relay` allows full bidirectional interaction through clean CLI subcommands.
