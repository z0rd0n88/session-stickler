---
name: session-relay
description: Headless and Claude Desktop-friendly terminal bridge for managing background agent sessions without requiring tmux attach.
---

# Session Relay

`session-relay` lets you inspect, steer, and manage background agent sessions running in tmux directly from headless environments or Claude Desktop (where `tmux attach` is unavailable).

## Quick Start

The command ships in this plugin as `${CLAUDE_PLUGIN_ROOT}/scripts/session-relay`; run it by that path, as below. When the skill is installed on its own instead of as a plugin, that path has no plugin directory in front of it: run the bare `session-relay` from `PATH` instead.

```bash
# List active sessions and their current terminal preview
"${CLAUDE_PLUGIN_ROOT}/scripts/session-relay" list

# Send follow-up prompt to a session without attaching
"${CLAUDE_PLUGIN_ROOT}/scripts/session-relay" send 1 "Run pytest and summarize failures"

# Read the latest terminal output from a session
"${CLAUDE_PLUGIN_ROOT}/scripts/session-relay" read 1 30

# Terminate a finished session
"${CLAUDE_PLUGIN_ROOT}/scripts/session-relay" kill 1
```

## Why It Matters

In Claude Desktop on Windows/WSL, terminal standard input is not a TTY, meaning `tmux attach` cannot be invoked interactively. `session-relay` allows full bidirectional interaction through clean CLI subcommands.
