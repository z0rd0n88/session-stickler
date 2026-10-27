# session-switcher

Open a new Claude Code session from inside a running one and hand it a brief. Only `claude`, `tmux`, and a shell.

```bash
bin/session-switcher examples/brief.md   # launches, waits, prints the child's first reply
tmux attach -t handoff                   # continue the child by hand
```

The mechanism is lifted from Orca's `worktree create --agent claude --prompt`: brief as one argv, identity in env, Claude `Stop` hook as the return channel.

Skill: `skills/session-switcher/SKILL.md`. Link it with

```bash
ln -s ~/session-switcher/skills/session-switcher ~/.claude/skills/session-switcher
```

and put `bin/` on your PATH.
