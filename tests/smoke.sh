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
pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
state_of() { awk '/^State:/ {print $2}' "/proc/$1/status" 2>/dev/null; }
cleanup() {
  tmux kill-server 2>/dev/null
  tmux -L blast-off-smoke kill-server 2>/dev/null; tmux -L run-job-smoke kill-server 2>/dev/null
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
out=$(FAKE_MB=5 SWITCH_TIMEOUT=20 session-switcher brief2.md 2>&1)
B=$(sed -n 's/^launched  window=\(sw-[^ ]*\).*/\1/p' <<<"$out")

echo "session-relay"
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

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
