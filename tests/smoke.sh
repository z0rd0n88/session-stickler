#!/usr/bin/env bash
# Smoke test for session-switcher, session-relay and session-airspace. Uses tests/fake-bin/claude,
# so it needs tmux and python3 but no Claude account. Runs in its own tmux socket; touches nothing else.
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
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
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
# F10: a turn that starts within a second of the last one ending must read as working, not idle.
# Typed straight into the pane (send pauses before Enter), so the turn starts inside that second.
reply=$(session-relay send "$A" --wait=15 'just before' 2>&1)
tmux send-keys -t "smoke:1" -l 'SLOW right after'; tmux send-keys -t "smoke:1" Enter; sleep 0.3
st=$(session-relay list | awk -v a="$A" '$2 == a {print $3}')
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
check "kill closes a held child" session-relay kill "$B"
sleep 1
[ ! -d "/proc/$bpid" ] || [ "$(state_of "$bpid")" = Z ] && ok "its claude process is gone" || bad "its claude process is gone (state $(state_of "$bpid"))"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
