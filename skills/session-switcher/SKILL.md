---
name: session-switcher
description: Open a new Claude Code session from the current one, hand it a brief file, and get its first reply back. Use for "hand this off", "start a new session with this", "switch sessions".
---

# Session Switcher

Hands work to a fresh Claude Code session. It has two modes. **tmux mode** (the default in a terminal) starts the child in tmux and returns its first reply. **Desktop mode** (the default inside Claude Desktop) opens the child in Claude Desktop and returns nothing. Needs a shell and `python3`; tmux mode also needs `claude` and `tmux`.

## Steps

1. Write the brief to a file (for example `handoff.md`). Put everything the child needs in it; the child shares no context with you. Start it with a heading, not a `-`. Don't point it at files in your scratchpad or task-output dirs (`/tmp/claude-<uid>/<project>/<session-uuid>/...`): they belong to your session and may be gone when the child reads them, so `session-switcher` refuses such a brief and names each path. Copy those files somewhere durable (a gitignored dir in the repo) and point the brief there.
2. Run:

```bash
session-switcher handoff.md [workdir]
```

   Set `CLAUDE_FLAGS="--dangerously-skip-permissions"` when the child must use tools unattended. `SWITCH_TIMEOUT` (seconds, default 180) bounds the wait. Give this Bash call a longer timeout than that (for example `timeout: 240000`); the Bash tool's default 120 s ends the call before `session-switcher` does. `SWITCH_MODE=tmux` or `SWITCH_MODE=desktop` overrides the default mode.
3. If the output starts with `asked Claude Desktop to open`, follow **Desktop mode** below and stop here.
4. Otherwise read the output: `launched window=sw-<id>`, `child session: <id>`, `transcript: <path>`, and the child's last message. Relay the message to the user.
5. The child stays open as window `sw-<id>`. Continue it with `session-relay send sw-<id> --wait "<prompt>"` (the `session-relay` skill), and close it with `session-relay kill sw-<id>`. In a terminal, `tmux attach -t handoff` also works; from Claude Desktop it does not.

## Desktop mode

`session-switcher` copies the brief to `<dir>/brief.md` and opens a `claude://code/new` link that pre-fills a prompt: work in `<workdir>`, read that brief. Desktop does not take the folder from the link and does not send the prompt.

- Tell the user: in Desktop, pick an environment that can reach `<workdir>`, then press Enter.
- No session id or reply comes back. Tell the user to continue in Desktop.
- If no window appears, give the user the link `session-switcher` printed.
- When you need the reply back, rerun with `SWITCH_MODE=tmux`.
- There is no tmux child, so `session-relay` and `session-airspace` cannot see or steer it.

## What the child sees (tmux mode)

- argv: `claude --settings <dir>/settings.json '<brief>'`, started by a shell that stays as its parent (`claude ...; :`), so `session-airspace` can hold it.
- env: `SWITCH_ID`, `SWITCH_DIR`, `SWITCH_PARENT` (your session id). No `CLAUDECODE` vars leak, so the child does not think it is nested.
- Its `Stop` event (`session_id`, `transcript_path`, `last_assistant_message`) is written to `$SWITCH_DIR/done.json`.

## Limits (tmux mode)

- One brief in, first reply out. For a running conversation, use `session-relay`.
- `Stop` fires every turn; `done.json` holds the latest one. If the first turn ends with a shell still running in the background, `session-switcher` says so and keeps waiting (within `SWITCH_TIMEOUT`) for the turn Claude starts when that shell finishes, and prints that reply. If it is still working when time is up, it prints the reply so far with a note and exits 2. Once a background shell was seen, the reply is taken only after `SWITCH_BG_SETTLE` quiet seconds (10), since Claude starts its follow-up turn about a second after the shell ends. A background subagent or monitor is not waited on; a note after the reply says one is still running.
- The brief is a command-line argument, so any process of the same user can read it from `/proc`. Fine on a single-user box; for secrets, put a file path in the brief instead of the secret.
- A folder the child has never opened shows Claude's trust dialog. `session-switcher` answers it only when the workdir is the parent's own directory; otherwise it times out and someone must answer it in a terminal (`tmux attach -t handoff`).
- A warning before launch means RAM is already at `SWITCH_RAM_WARN` percent (default 85) or more; check `session-airspace status` before adding children.
- Exit 1 with a list of paths means the brief points into a session's temporary dirs; copy the files and rerun (or `SWITCH_ALLOW_TEMP=1` to launch anyway).
- Exit 2 means timeout; the child is still running. Check it with `session-relay read sw-<id>`, and get the reply later with `session-relay last sw-<id>`.
