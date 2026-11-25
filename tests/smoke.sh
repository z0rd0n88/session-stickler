#!/usr/bin/env bash
# Smoke test for session-switcher, session-relay and session-airspace. Uses tests/fake-bin/claude
# (and tests/fake-bin/systemd-run for the blast-off-style children), so it needs tmux and python3 but
# no Claude account or systemd. Runs in its own tmux socket dir; touches nothing else.
# Usage: tests/smoke.sh
# shellcheck disable=SC2015  # `ok` always succeeds, so `test && ok || bad` is a safe if/else here
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
export TMUX_TMPDIR="$WORK/tmux"; mkdir -p "$TMUX_TMPDIR"   # private tmux server
export PATH="$ROOT/tests/fake-bin:$ROOT/bin:$PATH"
export SWITCH_SESSION=smoke XDG_RUNTIME_DIR="$WORK/run"; mkdir -p "$XDG_RUNTIME_DIR"
unset TMUX
export FAKE_TAG="smoke-$$"   # names this run's fake background shells, so a parallel suite's are not touched
unset CLAUDE_CODE_ENTRYPOINT   # a Desktop parent would put the switcher in desktop mode
pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
state_of() { awk '/^State:/ {print $2}' "/proc/$1/status" 2>/dev/null; }
cleanup() {
  tmux kill-server 2>/dev/null
  tmux -L blast-off-smoke kill-server 2>/dev/null; tmux -L run-job-smoke kill-server 2>/dev/null
  tmux -L outer kill-server 2>/dev/null; pkill -f "snapshot-bash-$FAKE_TAG" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

cd "$WORK" || exit 1
printf 'first brief\n' > brief.md

echo "session-switcher"
out=$(FAKE_MB=40 SWITCH_TIMEOUT=20 session-switcher brief.md 2>&1)
grep -q '^echo: first brief' <<<"$out" && ok "returns the child's reply" || { bad "returns the child's reply"; echo "$out"; }
A=$(sed -n 's/^launched  window=\(sw-[^ ]*\).*/\1/p' <<<"$out")
[ -n "$A" ] && ok "names the window ($A)" || bad "names the window"
grep -q "session-relay send $A --wait" <<<"$out" && ok "prints the relay follow-up" || bad "prints the relay follow-up"
printf 'second brief\n' > brief2.md
# A new window takes its environment from tmux (the server the first launch started, which holds
# FAKE_MB=40), not from session-switcher's caller, so set child B's size in the session's environment.
tmux set-environment -t smoke FAKE_MB 5
out=$(SWITCH_TIMEOUT=20 session-switcher brief2.md 2>&1)
B=$(sed -n 's/^launched  window=\(sw-[^ ]*\).*/\1/p' <<<"$out")

echo "session-relay"
tmux new-session -d -s other -n $'tab\there\nand newline' 'sleep 1000'   # an unrelated window with a tab and a newline in its name
check "a tab or newline in another window's name does not break discovery" bash -c "session-relay list | grep -q '$A ' && session-airspace status | grep -q '$A '"
list=$(session-relay list)
grep -q "$A .*idle" <<<"$list" && ok "list shows child A idle" || { bad "list shows child A idle"; echo "$list"; }
grep -q 'echo: first brief' <<<"$list" && ok "list shows the last reply" || bad "list shows the last reply"
reply=$(session-relay send "$A" --wait=15 $'line one\nline two' 2>&1)
grep -q 'echo: line one' <<<"$reply" && grep -q 'line two' <<<"$reply" && ok "send --wait returns a multi-line reply" || { bad "send --wait returns a multi-line reply"; echo "$reply"; }
reply=$(session-relay send "$A" --wait=15 'Enter C-c Escape' 2>&1)
grep -q 'echo: Enter C-c Escape' <<<"$reply" && ok "key names are sent as text" || { bad "key names are sent as text"; echo "$reply"; }
check "last prints the full reply" bash -c "session-relay last $A | grep -q 'echo: Enter C-c Escape'"
check "read shows the pane" bash -c "session-relay read $A 40 | grep -q 'fake claude ready'"
check "bare index resolves in \$SWITCH_SESSION" session-relay last 1
session-relay send "$A" 'SLOW first question' >/dev/null
reply=$(session-relay send "$A" --wait=20 'second question' 2>&1)
grep -q 'echo: second question' <<<"$reply" && ! grep -q 'echo: SLOW' <<<"$reply" && grep -q 'waiting for it to finish' <<<"$reply" \
  && ok "send --wait to a busy child waits its turn and returns its own reply" || { bad "send --wait to a busy child"; echo "$reply"; }
session-relay send "$A" 'SLOW third question' >/dev/null
out=$(session-relay send "$A" --wait=1 'never sent' 2>&1); rc=$?
[ "$rc" -eq 2 ] && grep -q 'NOT sent' <<<"$out" && ok "a --wait that runs out before the turn ends sends nothing (exit 2)" || { bad "busy timeout (rc $rc)"; echo "$out"; }
for _ in $(seq 1 30); do session-relay last "$A" | grep -q 'echo: SLOW third' && break; sleep 0.2; done
sleep 1; ! session-relay last "$A" | grep -q 'never sent' && ok "the prompt that timed out was not typed in" || bad "the timed-out prompt was typed in"
check "unknown target is refused" bash -c "! session-relay last nosuch"
session-relay send "$A" 'ASK-PERMISSION run a command' >/dev/null 2>&1
ADIR=$(python3 "$ROOT/lib/session_panes.py" list | awk -F'\t' -v a="$A" '$2 == a {print $10}')
for _ in $(seq 1 25); do session-relay read "$A" 5 | grep -q 'Esc to cancel' && break; sleep 0.2; done
out=$(session-relay send "$A" 'what time is it?' 2>&1); rc=$?
[ "$rc" -eq 5 ] && grep -q "showing a dialog" <<<"$out" && ok "send refuses a child showing a permission prompt (exit 5)" || { bad "send refuses a dialog (rc $rc)"; echo "$out"; }
sleep 1; [ ! -e "$ADIR/approved" ] && ok "the prompt was not approved by send" || bad "send approved the permission prompt"
tmux send-keys -t "smoke:1" 2 Enter   # answer it ("2. No"), as a person would
for _ in $(seq 1 25); do session-relay last "$A" 2>/dev/null | grep -q '^echo: denied' && break; sleep 0.2; done   # its turn has ended
reply=$(session-relay send "$A" --wait=15 'after the dialog' 2>&1)
grep -q 'echo: after the dialog' <<<"$reply" && ok "send works again once the dialog is answered" || { bad "send after the dialog"; echo "$reply"; }
# A slash command writes to the transcript but fires no Stop. Once it is a few seconds old, the
# child must read as idle again, or send --wait waits forever (seen live with /model).
session-relay send "$A" '/status' >/dev/null 2>&1
sleep 6
st=$(python3 "$ROOT/lib/session_panes.py" list | awk -F'\t' -v a="$A" '$2 == a {print $6}')
[ "$st" = idle ] && ok "a slash command (transcript write, no Stop) leaves the child idle" || bad "a slash command leaves the child idle (state $st)"
reply=$(session-relay send "$A" --wait=10 'after a slash command' 2>&1)
grep -q 'echo: after a slash command' <<<"$reply" && ok "send --wait works after a slash command" || { bad "send --wait after a slash command"; echo "$reply"; }
# A picker whose footer has other hints before "Esc to cancel" (seen live with /model, whose Enter
# saves a new default model) is a dialog too.
session-relay send "$A" '/picker' >/dev/null 2>&1
for _ in $(seq 1 25); do session-relay read "$A" 5 | grep -q 'Enter to save' && break; sleep 0.2; done
out=$(session-relay send "$A" 'into the picker' 2>&1); rc=$?
[ "$rc" -eq 5 ] && grep -q "showing a dialog" <<<"$out" && ok "send refuses a picker whose footer ends in Esc to cancel (exit 5)" || { bad "send refuses a picker (rc $rc)"; echo "$out"; }
sleep 1; [ ! -e "$ADIR/picked" ] && ok "nothing was picked in it" || bad "send picked an option in the picker"
tmux send-keys -t "smoke:1" Enter   # close it, as a person would
for _ in $(seq 1 25); do [ -e "$ADIR/picked" ] && break; sleep 0.2; done
sleep 6
# F10: a turn that starts within a second of the last one ending must read as working, not idle.
# Typed straight into the pane (send pauses before Enter), so the turn starts inside that second.
reply=$(session-relay send "$A" --wait=15 'just before' 2>&1)
tmux send-keys -t "smoke:1" -l 'SLOW right after'; tmux send-keys -t "smoke:1" Enter; sleep 0.3
st=$(python3 "$ROOT/lib/session_panes.py" list | awk -F'\t' -v a="$A" '$2 == a {print $6}')
[ "$st" = working ] && ok "a turn started right after the last one reads as working" || bad "state right after a new prompt is '$st', not working"
for _ in $(seq 1 40); do session-relay last "$A" | grep -q 'echo: SLOW right after' && break; sleep 0.2; done

echo "session-airspace"
read -r _ _ apid _ < <(session-relay list >/dev/null; python3 "$ROOT/lib/session_panes.py" list | awk -F'\t' -v a="$A" '$2 == a {print $1, $2, $4, $5}')
achild=$(pgrep -P "$apid" sleep)
check "hold" session-airspace hold "$A"
sleep 2
[ "$(state_of "$apid")" = T ] && ok "claude stays stopped (tmux does not resume it)" || bad "claude stays stopped (state $(state_of "$apid"))"
[ "$(state_of "$achild")" = T ] && ok "its child process is stopped too" || bad "its child process is stopped too"
check "status shows HOLDING" bash -c "session-airspace status | grep -q \"$A .*HOLDING\""
session-relay send "$A" "hello" >/dev/null 2>&1; [ $? -eq 3 ] && ok "relay refuses to send to a held child" || bad "relay refuses to send to a held child"
check "release" session-airspace release "$A"
[ "$(state_of "$apid")" != T ] && [ "$(state_of "$achild")" != T ] && ok "claude and child resumed" || bad "claude and child resumed"
check "a bare PID is not a target" bash -c "! session-airspace hold $$"
check "an index outside the managed session is refused" bash -c "! SWITCH_SESSION=nosuch session-airspace hold 1"

# An old-style launch, where claude is the pane's own process, cannot be held; say so.
D=$(mktemp -d "$XDG_RUNTIME_DIR/switch.XXXXXX")
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"cat > %s/done.json"}]}]}}\n' "$D" > "$D/settings.json"
tmux new-window -d -t smoke -n oldstyle "claude --settings $D/settings.json 'old style'"
sleep 2
check "status marks an old launch not holdable" bash -c "session-airspace status | grep -q 'oldstyle.*not holdable'"
check "hold refuses an old launch" bash -c "! session-airspace hold oldstyle"
session-relay kill oldstyle >/dev/null

echo "session-airspace guard"
out=$(AIRSPACE_TEST_PCT=95 session-airspace guard --once 2>&1)
grep -q "HOLDING smoke:.* (pid $apid" <<<"$out" && ok "guard holds the largest child ($A, 40MB)" || { bad "guard holds the largest child"; echo "$out"; }
out=$(AIRSPACE_TEST_PCT=95 session-airspace guard --once 2>&1)
grep -q '1 child flying; leaving it running' <<<"$out" && ok "guard always leaves one child flying" || { bad "guard always leaves one child flying"; echo "$out"; }
session-airspace hold "$B" >/dev/null
out=$(AIRSPACE_TEST_PCT=50 session-airspace guard --once 2>&1)
grep -q "FLYING pid $apid" <<<"$out" && ok "guard releases its own hold" || { bad "guard releases its own hold"; echo "$out"; }
out=$(AIRSPACE_TEST_PCT=50 session-airspace guard --once 2>&1)
check "guard leaves a manual hold alone" bash -c "session-airspace status | grep -q \"$B .*HOLDING\""
check "guard rejects a bad threshold" bash -c "! session-airspace guard --threshold 5 --once"

echo "session-airspace guard: stale entries and crashes never strand a hold"
HELD="$XDG_RUNTIME_DIR/session-airspace-$(id -u)/guard-held"
session-airspace release "$B" >/dev/null
AIRSPACE_TEST_PCT=95 session-airspace guard --once >/dev/null 2>&1
echo "999999 1" >> "$HELD"   # a child that is gone (e.g. closed with session-relay kill), as the last line
out=$(AIRSPACE_TEST_PCT=50 session-airspace guard --once 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q "FLYING pid $apid" <<<"$out" && ok "a stale last entry does not stop the guard (it releases $A)" || { bad "stale last entry (rc $rc)"; echo "$out"; }
! grep -q '^999999 ' "$HELD" && ok "the stale entry is dropped" || bad "the stale entry is dropped"
# A copy of the tools whose discovery (session_panes.py list) fails once $WORK/fail-list exists,
# so a running guard hits a real `set -e` error; `tree` keeps working, so it can still release.
mkdir -p "$WORK/copy/bin" "$WORK/copy/lib"
cp "$ROOT/bin/session-airspace" "$WORK/copy/bin/"; cp "$ROOT"/lib/* "$WORK/copy/lib/"
mv "$WORK/copy/lib/session_panes.py" "$WORK/copy/lib/session_panes_real.py"
cat > "$WORK/copy/lib/session_panes.py" <<PY
import os, runpy, sys
if sys.argv[1:2] == ["list"] and os.path.exists("$WORK/fail-list"):
    sys.exit("injected discovery failure")
runpy.run_path("$WORK/copy/lib/session_panes_real.py", run_name="__main__")
PY
rm -f "$WORK/fail-list"
AIRSPACE_TEST_PCT=95 "$WORK/copy/bin/session-airspace" guard --interval 1 > "$WORK/guard.log" 2>&1 & gpid=$!
for _ in $(seq 1 30); do grep -q HOLDING "$WORK/guard.log" && break; sleep 0.2; done
touch "$WORK/fail-list"   # the guard's next tick fails under set -e
for _ in $(seq 1 30); do kill -0 "$gpid" 2>/dev/null || break; sleep 0.2; done
wait "$gpid"; rc=$?
[ "$rc" -ne 0 ] && [ "$(state_of "$apid")" != T ] && grep -q "released 1" "$WORK/guard.log" \
  && ok "a guard that dies on an error releases its holds" || { bad "a guard that dies on an error releases its holds (rc $rc, state $(state_of "$apid"))"; cat "$WORK/guard.log"; }
rm -f "$WORK/fail-list"
AIRSPACE_TEST_PCT=95 session-airspace guard --interval 1 > "$WORK/guard.log" 2>&1 & gpid=$!
for _ in $(seq 1 30); do grep -q HOLDING "$WORK/guard.log" && break; sleep 0.2; done
kill -TERM "$gpid"; wait "$gpid"; rc=$?
[ "$rc" -eq 143 ] && [ "$(state_of "$apid")" != T ] && ok "SIGTERM stops the guard and releases its holds" || { bad "SIGTERM (rc $rc, state $(state_of "$apid"))"; cat "$WORK/guard.log"; }
session-airspace hold "$B" >/dev/null

echo "session-relay kill"
bpid=$(python3 "$ROOT/lib/session_panes.py" list | awk -F'\t' -v b="$B" '$2 == b {print $4}')
spane=$(tmux split-window -dP -F '#{pane_id}' -t "smoke:$B" "sleep 1000")   # a pane the user split off beside it
check "kill closes a held child" session-relay kill "$B"
sleep 1
[ ! -d "/proc/$bpid" ] || [ "$(state_of "$bpid")" = Z ] && ok "its claude process is gone" || bad "its claude process is gone (state $(state_of "$bpid"))"
tmux list-panes -a -F '#{pane_id}' | grep -qx "$spane" && ok "kill leaves a pane split off beside the child" || bad "kill leaves a pane split off beside the child"
tmux kill-pane -t "$spane" 2>/dev/null

# blast-off: a private server per job, each child a window running claude under systemd-run --scope,
# its dir named blast-off-<job>-child.XXXXXX with Stop and StopFailure hooks (blast-off lib/child.sh).
echo "blast-off children (private tmux server)"
BO=blast-off-smoke; JOB="$WORK/job"; mkdir -p "$JOB"
tmux -f /dev/null -L $BO new-session -d -s job-smoke -c "$WORK"
tmux -L $BO set-option -g remain-on-exit on
bo_child() {   # bo_child <n> [env...]: launch child <n> the way child_launch does; prints its dir
  local n=$1 d; shift
  d=$(mktemp -d "$XDG_RUNTIME_DIR/$BO-child.XXXXXX")
  sed "s|@DIR@|$d|g" > "$d/settings.json" <<'JSON'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"cat > @DIR@/done.tmp && mv @DIR@/done.tmp @DIR@/done.json"}]}],"StopFailure":[{"hooks":[{"type":"command","command":"cat > @DIR@/failed.tmp && mv @DIR@/failed.tmp @DIR@/failed.json"}]}]}}
JSON
  tmux -L $BO new-window -d -t job-smoke -c "$WORK" -e JOB_DIR="$JOB" -e JOB_CHILD="$n" "$@" \
    "systemd-run --user --scope --quiet --collect --slice=blast-off.slice --unit=$BO-child-$n.scope claude --settings $d/settings.json 'continue the job'; rc=\$?; echo \$rc > $d/exit; exit \$rc"
  echo "$d"
}
bo_child 1 -e FAKE_MB=80 >/dev/null
bo_child 2 -e FAKE_FAIL=rate_limit >/dev/null
sleep 3
list=$(session-relay list)
C1=$(awk -v s="$BO/job-smoke:" 'index($1, s) == 1 && /echo: continue the job/ {print $1}' <<<"$list")
C2=$(awk -v s="$BO/job-smoke:" 'index($1, s) == 1 && /failed/ {print $1}' <<<"$list")
[ -n "$C1" ] && grep -q "^$C1 .* blast-off .*idle" <<<"$list" && ok "list shows a blast-off child ($C1) with its runner" || { bad "list shows a blast-off child with its runner"; echo "$list"; }
[ -n "$C2" ] && grep -q "^$C2 .* blast-off .*failed .*turn failed: rate_limit" <<<"$list" && ok "list shows failed when failed.json is newest" || { bad "list shows failed"; echo "$list"; }
grep -q "^smoke:[0-9]* *$A .*switcher .*idle" <<<"$list" && ok "default-server children are still listed (runner switcher)" || { bad "default-server children are still listed"; echo "$list"; }
check "last works on a blast-off child" bash -c "session-relay last $C1 | grep -qx 'echo: continue the job'"
check "last reports the failure" bash -c "session-relay last $C2 | grep -q 'turn failed: rate_limit'"
check "read works on a blast-off child" bash -c "session-relay read $C1 | grep -q 'fake claude ready'"
out=$(session-relay send "$C1" "hello" 2>&1); rc=$?
[ "$rc" -eq 4 ] && grep -q -- '--force' <<<"$out" && ok "send refuses a blast-off child without --force" || { bad "send refuses a blast-off child without --force (rc $rc)"; echo "$out"; }
reply=$(session-relay send "$C1" --force --wait=15 'forced prompt' 2>&1)
grep -q 'echo: forced prompt' <<<"$reply" && ok "send --force reaches it on its own server" || { bad "send --force reaches it on its own server"; echo "$reply"; }
out=$(session-relay kill "$C1" 2>&1); rc=$?
[ "$rc" -eq 4 ] && grep -q "blast-off stop $JOB" <<<"$out" && ok "kill refuses and names blast-off stop <job-dir>" || { bad "kill refuses and names blast-off stop <job-dir> (rc $rc)"; echo "$out"; }
c1pid=$(python3 "$ROOT/lib/session_panes.py" list | awk -F'\t' -v c="$C1" '$1 == c {print $4}')
[ -d "/proc/$c1pid" ] && ok "the refused kill left claude running" || bad "the refused kill left claude running"
# F10 on a private server: the footer must be read from the child's own server and pane. Child 1
# is window 1 here and window 1 on the default server is also a fake claude, so reading the wrong
# server would see an idle screen.
c1pane=$(python3 "$ROOT/lib/session_panes.py" list | awk -F'\t' -v c="$C1" '$1 == c {print $12}')
tmux -L $BO send-keys -t "$c1pane" -l 'SLOW on its own server'; tmux -L $BO send-keys -t "$c1pane" Enter; sleep 0.3
st=$(python3 "$ROOT/lib/session_panes.py" list | awk -F'\t' -v c="$C1" '$1 == c {print $6}')
[ "$st" = working ] && ok "a new turn on a private server reads as working (footer from its own pane)" || bad "state of a new turn on a private server is '$st', not working"
for _ in $(seq 1 25); do session-relay last "$C1" 2>/dev/null | grep -q 'SLOW on its own server' && break; sleep 0.2; done
check "hold refuses a blast-off child without --force" bash -c "! session-airspace hold $C1"
check "status marks it skipped by the guard" bash -c "session-airspace status | grep -q \"^$C1 .*guard skips\""
out=$(AIRSPACE_TEST_PCT=95 session-airspace guard --once 2>&1)
grep -q "HOLDING smoke:" <<<"$out" && [ "$(state_of "$c1pid")" != T ] && ok "guard holds a smaller default-server child, not the 80MB blast-off one" || { bad "guard skips blast-off children"; echo "$out"; }
session-airspace release "$A" >/dev/null
out=$(session-airspace hold --force "$C1" 2>&1)
[ "$(state_of "$c1pid")" = T ] && grep -q 'JOB_CHILD_TIMEOUT' <<<"$out" && ok "hold --force holds it, with a timeout warning" || { bad "hold --force holds it, with a timeout warning"; echo "$out"; }
check "release on its server" session-airspace release "$C1"
check "a bare index never reaches another server" bash -c "! SWITCH_SESSION=job-smoke session-relay last 1"
check "default/ prefix resolves a default-server child" bash -c "session-relay last default/\$(session-relay list | awk -v a=$A '\$2 == a {print \$1}')"

# run-job (big-next-job) copies blast-off's private server: -L run-job-<name>, session job-<name>,
# a job.XXXXXX dir, Stop + StopFailure hooks, and `claude ...; echo $? > <dir>/exit` in the window.
echo "run-job children (private tmux server)"
RJ=run-job-smoke
tmux -f /dev/null -L $RJ new-session -d -s job-smoke -c "$WORK"
tmux -L $RJ set-option -g remain-on-exit on
R=$(mktemp -d "$XDG_RUNTIME_DIR/job.XXXXXX")
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"cat > %s/done.tmp && mv %s/done.tmp %s/done.json"}]}],"StopFailure":[{"hooks":[{"type":"command","command":"cat > %s/failed.tmp && mv %s/failed.tmp %s/failed.json"}]}]}}\n' \
  "$R" "$R" "$R" "$R" "$R" "$R" > "$R/settings.json"
tmux -L $RJ new-window -d -t job-smoke -c "$WORK" "claude --settings $R/settings.json 'run-job prompt'; echo \$? > $R/exit"
# A socket file with no server behind it (a crashed server leaves one) must be skipped quietly.
python3 -c 'import socket, sys; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$TMUX_TMPDIR/tmux-$(id -u)/stale-smoke"
sleep 2
err=$(session-relay list 2>&1 >/dev/null)
[ -z "$err" ] && ok "a stale socket is skipped quietly" || { bad "a stale socket is skipped quietly"; echo "$err"; }
list=$(session-relay list)
RT=$(awk -v s="$RJ/job-smoke:" 'index($1, s) == 1 {print $1}' <<<"$list")
[ -n "$RT" ] && grep -q "^$RT .* run-job .*idle .*echo: run-job prompt" <<<"$list" && ok "list shows a run-job child ($RT) with its runner" || { bad "list shows a run-job child with its runner"; echo "$list"; }
reply=$(session-relay send "$RT" --wait=15 'no force needed' 2>&1)
grep -q 'echo: no force needed' <<<"$reply" && ok "send reaches a run-job child without --force" || { bad "send reaches a run-job child without --force"; echo "$reply"; }
rpid=$(python3 "$ROOT/lib/session_panes.py" list | awk -F'\t' -v c="$RT" '$1 == c {print $4}')
session-airspace hold "$RT" >/dev/null 2>&1
[ "$(state_of "$rpid")" = T ] && ok "hold works on a run-job child" || bad "hold works on a run-job child (state $(state_of "$rpid"))"
out=$(session-relay kill "$RT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'treats a killed child as a crash' <<<"$out" && ok "kill closes a run-job child, with a warning" || { bad "kill closes a run-job child, with a warning (rc $rc)"; echo "$out"; }

echo "session-switcher checks (#4, #5)"
SP=/tmp/claude-1000/-home-me-repo/0b5e1c2d-3f4a-4b6c-9d8e-7f6a5b4c3d2e
printf '# Next\nRead %s/scratchpad/review/a.md.\nAlso see (%s/tasks/b1.output), and /tmp/claude-1000/-home-me-repo/not-a-uuid/x.\n' "$SP" "$SP" > tempbrief.md
before=$(tmux list-windows -a 2>/dev/null | wc -l)
out=$(SWITCH_TIMEOUT=20 session-switcher tempbrief.md 2>&1); rc=$?
after=$(tmux list-windows -a 2>/dev/null | wc -l)
[ "$rc" -eq 1 ] && [ "$before" -eq "$after" ] && ok "a brief pointing into a session's scratchpad is refused before launch" || { bad "scratchpad brief refused (rc $rc, windows $before -> $after)"; echo "$out"; }
grep -qx "  $SP/scratchpad/review/a.md" <<<"$out" && grep -qx "  $SP/tasks/b1.output" <<<"$out" && ok "the refusal names each path, without trailing punctuation" || { bad "the refusal names each path"; echo "$out"; }
! grep -q 'not-a-uuid' <<<"$out" && ok "a claude-<uid> path without a session uuid is not flagged" || bad "a claude-<uid> path without a session uuid is not flagged"
printf '# Next\nRead docs/handoff/review.md and /tmp/build.log.\n' > durable.md
out=$(SWITCH_ALLOW_TEMP=0 SWITCH_TIMEOUT=0 session-switcher durable.md 2>&1); rc=$?
! grep -q 'temporary dirs' <<<"$out" && ok "a brief with durable paths passes the check" || { bad "durable brief passes"; echo "$out"; }
[ "$rc" -eq 2 ] && grep -q 'still running in window sw-' <<<"$out" && grep -q 'raise SWITCH_TIMEOUT' <<<"$out" && grep -q 'tmux attach -t smoke' <<<"$out" \
  && ok "a timeout exits 2 and says how to wait longer and how to attach" || { bad "timeout message (rc $rc)"; echo "$out"; }
out=$(SWITCH_ALLOW_TEMP=1 SWITCH_TIMEOUT=0 session-switcher tempbrief.md 2>&1); rc=$?
[ "$rc" -eq 2 ] && grep -q 'launching anyway' <<<"$out" && grep -q '^launched' <<<"$out" && ok "SWITCH_ALLOW_TEMP=1 warns and launches anyway" || { bad "SWITCH_ALLOW_TEMP=1 launches (rc $rc)"; echo "$out"; }
out=$(SWITCH_TIMEOUT=2m session-switcher durable.md 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q 'whole number of seconds' <<<"$out" && ok "a non-numeric SWITCH_TIMEOUT is refused" || { bad "non-numeric SWITCH_TIMEOUT (rc $rc)"; echo "$out"; }
session-switcher --help | grep -q 'SWITCH_TIMEOUT=180' && session-switcher --help | grep -q '240000 ms' && ok "--help gives the 180 s default and the Bash-tool timeout advice" || bad "--help timeout text"

echo "status-line parsing"
fp() { printf '%b' "$1" | python3 "$ROOT/lib/session_panes.py" footer; }
R=$(printf '─%.0s' $(seq 1 40))
T="● Ran 2 shell commands · 3 background tasks\n$R\n❯ \n$R\n"
[ "$(fp "$T  ⏵⏵ auto mode on · 1 shell · ↓ to manage")" = "0 1 0" ] && ok "one shell, and the transcript above the rule is ignored" || bad "one shell: $(fp "$T  ⏵⏵ auto mode on · 1 shell · ↓ to manage")"
[ "$(fp "$T  ⏵⏵ auto mode on · 1 shell, 2 monitors · esc to interrupt")" = "1 3 0" ] && ok "the comma form, during a turn" || bad "comma form: $(fp "$T  ⏵⏵ auto mode on · 1 shell, 2 monitors · esc to interrupt")"
[ "$(fp "$T  ⏵⏵ auto mode on · 1 monitor")" = "0 1 0" ] && ok "a monitor alone" || bad "monitor alone"
[ "$(fp "$T  ⏵⏵ auto mode on · 3 background tasks\n  ● main\n  ◯ general-purpose  Run 4 shells · waiting on 1 shell, 1 monitor")" = "0 3 1" ] \
  && ok "background tasks with a subagent row; the row's own words are not counted" || bad "background tasks: $(fp "$T  ⏵⏵ auto mode on · 3 background tasks\n  ● main\n  ◯ general-purpose  Run 4 shells · waiting on 1 shell, 1 monitor")"
[ "$(fp "$T  ⏵⏵ auto mode on\n  ● main\n  ◯ general-purpose  Explore\n  ◯ Plan  Write it up")" = "0 2 2" ] && ok "subagent rows count with no count in the status line" || bad "rows alone"
[ "$(fp "$T  ⏵⏵ auto mode on · /tasks to see subagents")" = "0 0 0" ] && ok "the /tasks hint after a subagent ended is not work" || bad "/tasks hint"
[ "$(fp "$T  ⏵⏵ auto mode on · 2 tasks\n  ◯ /ide for Visual Studio Code")" = "0 0 0" ] && ok "a task count, and a ◯ line with no ● main row above it, are not work" || bad "tasks / stray ◯: $(fp "$T  ⏵⏵ auto mode on · 2 tasks\n  ◯ /ide for Visual Studio Code")"
[ "$(fp "$T  ⏵⏵ bypass permissions on (shift+tab to cycle) · 1 shell · esc to\n  interrupt")" = "1 1 0" ] && ok "esc to interrupt wrapped onto two lines still reads as a turn" || bad "wrapped busy: $(fp "$T  ⏵⏵ bypass permissions on (shift+tab to cycle) · 1 shell · esc to\n  interrupt")"
[ "$(fp "old text · 9 shells\nmore text\n⏵⏵ auto mode on · 1 shell\n  ● main\n  ◯ general-purpose  Run 5 shells")" = "0 1 1" ] \
  && ok "with no rule: the status line and the rows under it" || bad "no rule: $(fp "old text · 9 shells\nmore text\n⏵⏵ auto mode on · 1 shell\n  ● main\n  ◯ general-purpose  Run 5 shells")"

echo "background shells"
state() { session-relay list | awk -v g="$1" '$2 == g {print $4}'; }
# wait_state <window> <state> <seconds>: poll until the STATE column reads <state>
wait_state() { local i; for ((i = 0; i < $3 * 5; i++)); do [ "$(state "$1")" = "$2" ] && return 0; sleep 0.2; done; return 1; }
printf 'BACKGROUND first turn\n' > bgbrief.md
out=$(SWITCH_TIMEOUT=30 session-switcher bgbrief.md 2>&1); rc=$?
G=$(sed -n 's/^launched  window=\(sw-[^ ]*\).*/\1/p' <<<"$out")
[ "$rc" -eq 0 ] && grep -q 'background work running' <<<"$out" && grep -q '^echo: background finished' <<<"$out" \
  && ok "switcher waits through a background shell for the turn it starts" || { bad "switcher waits through a background shell (rc $rc)"; echo "$out"; }
wait_state "$G" idle 10 || bad "child $G never settled to idle (state $(state "$G"))"
session-relay send "$G" 'BACKGROUND second' >/dev/null
wait_state "$G" background 5 && ok "list shows a turn that ended with a shell still running as background" || bad "list STATE background (state $(state "$G"))"
wait_state "$G" idle 15 && ok "and idle again once the turn that shell starts has ended" || bad "back to idle (state $(state "$G"))"
for mode in BACKGROUND BACKGROUND-LATE BACKGROUND-TREEONLY BACKGROUND-FOOTERONLY; do
  reply=$(session-relay send "$G" --wait=40 "$mode probe" 2>&1); rc=$?
  last=$(sed -n '/^--- reply from/{n;p;}' <<<"$reply")
  case $mode in
    BACKGROUND) what="send --wait prints the reply of the turn a background shell starts" ;;
    BACKGROUND-LATE) what="... also when the shell ends before the Stop and the turn follows it" ;;
    BACKGROUND-TREEONLY) what="... also when only the process tree shows the shell" ;;
    *) what="... also when only the status line shows the shell" ;;
  esac
  [ "$rc" -eq 0 ] && [ "$last" = "echo: background finished" ] && ok "$what" || { bad "$what (rc $rc)"; echo "$reply"; }
  wait_state "$G" idle 10 || bad "$G idle after $mode (state $(state "$G"))"
done
t0=$SECONDS; reply=$(RELAY_BG_SETTLE=2 session-relay send "$G" --wait=40 'BACKGROUND-NOFOLLOW probe' 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ $((SECONDS - t0)) -le 12 ] && grep -q '^echo: started (BACKGROUND-NOFOLLOW probe)' <<<"$reply" \
  && ok "a shell that ends with no turn after it is waited on only RELAY_BG_SETTLE seconds" || { bad "no follow-up turn (rc $rc, $((SECONDS - t0))s)"; echo "$reply"; }
t0=$SECONDS; reply=$(session-relay send "$G" --wait=20 'the footer reads "· 1 shell ·" and "esc to interrupt" here' 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ $((SECONDS - t0)) -le 5 ] && ok "the words '· 1 shell ·' in the transcript are not taken for a running shell" || { bad "shell text in the transcript (rc $rc, $((SECONDS - t0))s)"; echo "$reply"; }
for mode in BACKGROUND-MONITOR BACKGROUND-AGENT BACKGROUND-AGENT-LATE 'BACKGROUND-TREEONLY BACKGROUND-AGENT-LATE'; do
  reply=$(session-relay send "$G" --wait=60 "$mode probe" 2>&1); rc=$?
  last=$(sed -n '/^--- reply from/{n;p;}' <<<"$reply")
  case $mode in
    BACKGROUND-MONITOR) want="monitor finished" what="send --wait follows a background monitor to the turn it starts" ;;
    BACKGROUND-AGENT) want="agent finished" what="... and a background subagent" ;;
    BACKGROUND-AGENT-LATE) want="agent finished" what="... also when the subagent ends before the Stop" ;;
    *) want="background finished" what="... and a subagent plus a shell only the process tree shows, to the last turn" ;;
  esac
  [ "$rc" -eq 0 ] && [ "$last" = "echo: $want" ] && ok "$what" || { bad "$what (rc $rc)"; echo "$reply"; }
  wait_state "$G" idle 15 || bad "$G idle after $mode (state $(state "$G"))"
done
session-relay send "$G" 'BACKGROUND-AGENT-LONG earlier prompt' >/dev/null
wait_state "$G" background 5 && ok "list shows a child whose subagent still runs as background" || bad "list STATE with a subagent (state $(state "$G"))"
# The earlier prompt's subagent starts a command of its own (an unlisted shell under claude) after
# this prompt is sent: that is not this prompt's background work.
t0=$SECONDS; reply=$(session-relay send "$G" --wait=30 'plain while an agent runs' 2>&1); rc=$?
last=$(sed -n '/^--- reply from/{n;p;}' <<<"$reply")
[ "$rc" -eq 0 ] && [ $((SECONDS - t0)) -le 6 ] && [ "$last" = "echo: plain while an agent runs" ] \
  && ok "an earlier prompt's subagent, and the commands it starts, don't hold up the next reply" || { bad "earlier subagent holds up the reply (rc $rc, $((SECONDS - t0))s)"; echo "$reply"; }
# idle shows for a moment between the subagent's end and the turn it starts, so wait for that turn
for _ in $(seq 1 125); do [ "$(session-relay last "$G")" = "echo: agent finished" ] && break; sleep 0.2; done
wait_state "$G" idle 10 || bad "$G idle after the long agent's turn (state $(state "$G"))"
t0=$SECONDS; reply=$(session-relay send "$G" --wait=20 'the screen says ◯ general-purpose and · 3 background tasks · 1 shell, 2 monitors here' 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ $((SECONDS - t0)) -le 5 ] && grep -q '^echo: the screen says' <<<"$reply" \
  && ok "agent, task and monitor words in the transcript are not taken for background work" || { bad "work words in the transcript (rc $rc, $((SECONDS - t0))s)"; echo "$reply"; }
session-relay send "$G" 'BACKGROUND-FOREVER dev server' >/dev/null
for _ in $(seq 1 25); do session-relay last "$G" | grep -q 'started (BACKGROUND-FOREVER dev server)' && break; sleep 0.2; done
t0=$SECONDS; reply=$(session-relay send "$G" --wait=20 'plain question' 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ $((SECONDS - t0)) -le 5 ] && grep -q '^echo: plain question' <<<"$reply" \
  && ok "a shell left running by an earlier prompt (a dev server) does not hold up the next reply" || { bad "earlier shell holds up the reply (rc $rc, $((SECONDS - t0))s)"; echo "$reply"; }
t0=$SECONDS; reply=$(session-relay send "$G" --wait=5 'BACKGROUND-FOREVER second' 2>&1); rc=$?
[ "$rc" -eq 2 ] && [ $((SECONDS - t0)) -le 12 ] && grep -q '^echo: started (BACKGROUND-FOREVER second)' <<<"$reply" && grep -q 'still working' <<<"$reply" \
  && ok "a new shell that never ends: exit 2 at the --wait deadline, with the reply so far" || { bad "never-ending shell at the deadline (rc $rc, $((SECONDS - t0))s)"; echo "$reply"; }
( sleep 2; session-airspace hold "$G" >/dev/null 2>&1 ) &
reply=$(session-relay send "$G" --wait=30 'BACKGROUND held mid-wait' 2>&1); rc=$?; wait
[ "$rc" -eq 3 ] && grep -q 'held by session-airspace while waiting' <<<"$reply" && ok "a child held during the wait ends it with exit 3" || { bad "held during the wait (rc $rc)"; echo "$reply"; }
session-airspace release "$G" >/dev/null 2>&1
session-relay kill "$G" >/dev/null 2>&1
printf 'BACKGROUND-FOREVER first turn\n' > bgforever.md
out=$(SWITCH_TIMEOUT=6 session-switcher bgforever.md 2>&1); rc=$?
[ "$rc" -eq 2 ] && grep -q '^echo: started (BACKGROUND-FOREVER first turn)' <<<"$out" && grep -q 'still working' <<<"$out" \
  && ok "switcher: still working at SWITCH_TIMEOUT is exit 2, with the reply so far" || { bad "switcher timeout with a shell running (rc $rc)"; echo "$out"; }
session-relay kill "$(sed -n 's/^launched  window=\(sw-[^ ]*\).*/\1/p' <<<"$out")" >/dev/null 2>&1
printf 'BACKGROUND-AGENT first turn\n' > bgagent.md
out=$(SWITCH_TIMEOUT=40 session-switcher bgagent.md 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'background work running' <<<"$out" && grep -q '^echo: agent finished' <<<"$out" \
  && ok "switcher follows a background subagent to the turn it starts" || { bad "switcher background agent (rc $rc)"; echo "$out"; }
session-relay kill "$(sed -n 's/^launched  window=\(sw-[^ ]*\).*/\1/p' <<<"$out")" >/dev/null 2>&1
# Inside another tmux server (a run-job child calling the switcher), the child's window is on that
# server; the status-line check must read it there, not the default server.
printf 'BACKGROUND-FOOTERONLY first turn\n' > bgfooter.md
tmux -L outer new-session -d -s outer "cd '$WORK' && SWITCH_TIMEOUT=30 SWITCH_SESSION=inner session-switcher bgfooter.md > inner.out 2>&1; echo \$? > inner.rc"
for _ in $(seq 1 150); do [ -s inner.rc ] && break; sleep 0.2; done
[ "$(cat inner.rc 2>/dev/null)" = 0 ] && grep -q '^echo: background finished' inner.out \
  && ok "switcher inside another tmux server reads its child's status line there" || { bad "switcher inside tmux (rc $(cat inner.rc 2>/dev/null))"; cat inner.out; }
tmux -L outer kill-server 2>/dev/null
pkill -f "snapshot-bash-$FAKE_TAG" 2>/dev/null

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
