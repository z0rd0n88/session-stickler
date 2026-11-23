# shellcheck shell=bash
# Shared helpers for session-relay and session-airspace. Sourced, not run.
# Needs: tmux, python3, and $LIB set to this folder by the caller.

SWITCH_SESSION="${SWITCH_SESSION:-handoff}"

managed_rows() { python3 "$LIB/session_panes.py" list; }

# resolve_target <target>: find one managed child and set T_TARGET T_NAME T_PANE T_CLAUDE
# T_WRAPPED T_STATE T_RSS T_DIR T_SOCKET T_PANE_ID T_RUNNER T_JOB. A target is a window name
# (sw-ab12cd, as session-switcher names them), "session:index" or "session:name" on the default
# tmux server, "socket/session:index" or "socket/session:name" on any server (blast-off's are
# "blast-off-<job>/job-<job>:3"), or a bare index in $SWITCH_SESSION on the default server.
# Only managed children resolve, so a typo can never reach an unrelated process.
resolve_target() {
  local want="$1" rows match n
  [ -n "$want" ] || { echo "error: no target given" >&2; return 1; }
  want="${want#default/}"
  rows=$(managed_rows)
  match=$(awk -F'\t' -v w="$want" -v s="$SWITCH_SESSION" '
    { sn = $1; sub(/:[^:]*$/, "", sn) }       # sn: "session" or "socket/session"
    $1 == w || $2 == w || (sn ":" $2) == w || ($11 == "default" && w ~ /^[0-9]+$/ && $1 == s ":" w)
  ' <<<"$rows")
  n=$(grep -c . <<<"$match" || true)
  if [ "$n" -eq 0 ]; then
    echo "error: no managed Claude child matches '$want' (see: session-relay list)" >&2; return 1
  elif [ "$n" -gt 1 ]; then
    echo "error: '$want' matches $n children; use the TARGET column of session-relay list" >&2; return 1
  fi
  # shellcheck disable=SC2034  # read by the sourcing script
  IFS=$'\t' read -r T_TARGET T_NAME T_PANE T_CLAUDE T_WRAPPED T_STATE T_RSS _ _ T_DIR \
    T_SOCKET T_PANE_ID T_RUNNER T_JOB _ <<<"$match"
}

# tm <tmux args>: tmux on the resolved child's server, so every command reaches the right one.
tm() { tmux -L "$T_SOCKET" "$@"; }

# blast_off_stop_hint: the command that stops the resolved blast-off child's job.
blast_off_stop_hint() {
  if [ "$T_JOB" != - ]; then echo "blast-off stop $T_JOB"; else echo "blast-off stop <job-dir>"; fi
}

# hold_tree / release_tree <claude_pid>: stop or continue claude and everything under it
# (Bash-tool commands, MCP servers, subagents). Stop parents first so nothing new is spawned;
# continue children first so claude never wakes to find a frozen child.
hold_tree() {
  local p
  for p in $(python3 "$LIB/session_panes.py" tree "$1"); do kill -STOP "$p" 2>/dev/null || true; done
}
release_tree() {
  local p pids
  pids=$(python3 "$LIB/session_panes.py" tree "$1")
  for p in $(tr ' ' '\n' <<<"$pids" | tac); do kill -CONT "$p" 2>/dev/null || true; done
}

proc_state() { awk '/^State:/ {print $2}' "/proc/$1/status" 2>/dev/null || echo "?"; }

human_age() {
  local s=$1
  if [ "$s" -lt 60 ]; then echo "${s}s"
  elif [ "$s" -lt 3600 ]; then echo "$((s / 60))m"
  else echo "$((s / 3600))h$(( (s % 3600) / 60 ))m"; fi
}
