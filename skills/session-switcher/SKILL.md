---
name: session-switcher
description: Open a new Claude Code session from the current one, hand it a brief file, and get its first reply back. Use for "hand this off", "start a new session with this", "switch sessions".
---

# Session Switcher

Hands work to a fresh Claude Code session the way Orca does: the brief travels as one shell argument, identity travels as env vars, and a `Stop` hook sends the child's first reply back as a file. Needs only `claude`, `tmux`, and a shell.

## Steps

1. Write the brief to a file (for example `handoff.md`). Put everything the child needs in it; the child shares no context with you. Start it with a heading, not a `-`.
2. Run:

```bash
session-switcher handoff.md [workdir]
```

   Set `CLAUDE_FLAGS="--dangerously-skip-permissions"` when the child must use tools unattended. `SWITCH_TIMEOUT` (seconds, default 90) bounds the wait.
3. Read the output: `child session: <id>`, `transcript: <path>`, and the child's last message. Relay the message to the user.
4. The child stays open in tmux window `handoff:<n>`. Tell the user `tmux attach -t handoff` to continue it, `tmux kill-session -t handoff` to close it.

## What the child sees

- argv: `claude --settings <dir>/settings.json '<brief>'`
- env: `SWITCH_ID`, `SWITCH_DIR`, `SWITCH_PARENT` (your session id). No `CLAUDECODE` vars leak, so the child does not think it is nested.
- Its `Stop` event (`session_id`, `transcript_path`, `last_assistant_message`) is written to `$SWITCH_DIR/done.json`.

## Limits

- One brief in, first reply out. For a running conversation, attach to the tmux window.
- `Stop` fires every turn; `done.json` holds the latest one.
- The brief is a command-line argument, so any process of the same user can read it from `/proc`. Fine on a single-user box; for secrets, put a file path in the brief instead of the secret.
- A folder the child has never opened shows Claude's trust dialog. The script answers it only when the workdir is the parent's own directory; otherwise it times out and you attach to answer by hand.
- Exit 2 means timeout; the child is still running.
