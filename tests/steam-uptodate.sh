#!/bin/bash
# tools/steam-uptodate.sh, every branch, against stubbed answers.
#
# No game and no Steam: the probe's line is supplied (STEAM_UPTODATE_PROBE),
# one answer per call from a queue, the last one repeated, and docker is a
# stub that writes down what it was asked to do. Each case runs a fresh copy
# of the script in a scratch checkout with its own state files and its own
# host lock.
#
#   branches  current; current again; behind with people on (said once);
#             behind and empty -> updated, proven by Steam, by a restart and
#             by a one-shot service; an update Steam does not accept;
#             three tries in a day; the game baked into
#             the image (said once, exit 1 every run); the image updating on
#             restart; A2S silent, tolerated and then not; Steam silent;
#             another update on this host, by its lock and by its stamp;
#             --dry-run; --check; a stopped server; a symlinked state file;
#             restarts Docker did (said once with the crash line, masked; 3 in
#             24 h exit 1; a count back at 0 or a new container counted afresh;
#             out of memory; an inspect that fails)
#   plants    four copies with one rule taken out each - the player count,
#             the proof by Steam, the host lock, the daily limit - and each
#             is seen doing exactly what the rule prevents, so the cases
#             above can tell the rule from its absence
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
# shellcheck disable=SC2016   # the plants are sed expressions that name the script's own variables
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

TOOL=tools/steam-uptodate.sh
SERVICE=$(sed -n 's/^SERVICE=//p' "$TOOL")
HOW=$(sed -n 's/^HOW=//p' "$TOOL")
[ -n "$SERVICE" ] && [ -n "$HOW" ] && pass "the script names its service ($SERVICE) and how it updates ($HOW)" \
  || { fail "cannot read SERVICE= and HOW= from $TOOL"; exit 1; }

# A stub docker: logs every call; `ps -q` names a container unless the case
# says the server is down; the one-shot's logs end in its outcome line.
mkdir -p "$T/bin"
cat >"$T/bin/docker" <<'STUB'
#!/bin/bash
echo "$*" >>"$CASE/docker.log"
case " $* " in
  *" ps -q "*) [ -e "$CASE/down" ] || echo 0123456789ab ;;
  *" logs --until "*) cat "$CASE/crashlog" 2>/dev/null ;;
  *" logs "*) echo "${HOW_UNDER_TEST}: updated build 1 -> 2" ;;
  *RestartCount*) [ -e "$CASE/inspect-fails" ] && exit 1
                  echo "/game-server $(cat "$CASE/restarts" 2>/dev/null || echo "c1 0") 2026-11-14T08:12:31Z 2026-11-14T08:12:40Z" ;;
  *" events "*) if [ -n "${OOM:-}" ]; then printf 'oom \ndie 137\n'; else echo "die 139"; fi ;;
  *" inspect "*) echo "172.18.0.2 " ;;
  *" restart "*) echo "c1 0" >"$CASE/restarts" ;;
esac
exit 0
STUB
# The probe: one line per call from the case's queue, the last one repeated.
cat >"$T/bin/probe" <<'STUB'
#!/bin/sh
q="$CASE/answers"
head -1 "$q"
if [ "$(wc -l <"$q")" -gt 1 ]; then tail -n +2 "$q" >"$q.next" && mv "$q.next" "$q"; fi
STUB
cat >"$T/bin/notify" <<'STUB'
#!/bin/sh
cat >>"$CASE/notified"
STUB
chmod +x "$T/bin/docker" "$T/bin/probe" "$T/bin/notify"

n=0
fresh() {  # how [sed expression for the copy]: a new case directory
  n=$((n + 1))
  CASE="$T/case$n"
  mkdir -p "$CASE/repo/tools"
  sed -e "s/^HOW=.*/HOW=$1/" ${2:+-e "$2"} "$TOOL" >"$CASE/repo/tools/steam-uptodate.sh"
  chmod +x "$CASE/repo/tools/steam-uptodate.sh"
  : >"$CASE/docker.log"
  export CASE HOW_UNDER_TEST="$1"
}
answers() { printf '%s\n' "$@" >"$CASE/answers"; }
run() {  # args: run the case's copy; output in $out, status in $rc
  out=$(cd "$CASE/repo" && PATH="$T/bin:$PATH" \
    STEAM_UPTODATE_PROBE="$T/bin/probe" STEAM_UPTODATE_NOTIFY="$T/bin/notify" \
    STEAM_UPTODATE_HOST_LOCK="$CASE/host.lock" STEAM_UPTODATE_HOST_STAMP="$CASE/host.last" \
    STEAM_UPTODATE_POLL=0 STEAM_UPTODATE_WAIT=2 tools/steam-uptodate.sh "$@" 2>&1)
  rc=$?
}
told() { [ -f "$CASE/notified" ] && grep -c . "$CASE/notified" || echo 0; }
asked() { grep -c -- "$1" "$CASE/docker.log"; }
state() { cat "$CASE/repo/.steam-uptodate-state" 2>/dev/null; }
OLD="10828683 0 0 11191711"; NEW="11191711 0 1 -"; BUSY="10828683 3 0 11191711"
# A server whose game is baked into its image never updates, so the branches
# that do are run on copies set to update on restart.
UPD=$HOW; [ "$HOW" = image ] && UPD=restart
[ "$HOW" = image ] && echo "(this server's game is in its image: the update branches run on copies set to update on restart)"

echo "=== current ==="
fresh "$HOW"; answers "$NEW"; run
[ "$rc" = 0 ] && [[ $out == *"current: version 11191711"* ]] && [ -z "$(state)" ] && [ "$(told)" = 0 ] \
  && pass "Steam calls it current: exit 0, nothing written, nothing said" || fail "current: exit $rc, $out"
echo 1700000000 >"$CASE/repo/.steam-uptodate-state"; run
[ "$rc" = 0 ] && [[ $out == *"current again"* ]] && [ ! -e "$CASE/repo/.steam-uptodate-state" ] \
  && pass "current again after being behind: the state is cleared" || fail "current again: exit $rc, $out"

echo "=== behind, people on ==="
fresh "$UPD"; answers "$BUSY"; run
[ "$rc" = 0 ] && [[ $out == *"3 on it, so it waits"* ]] && [ "$(asked ' stop \| restart \| up ')" = 0 ] \
  && [ "$(told)" = 1 ] && [[ $(state) == *warned* ]] \
  && pass "3 on it: not touched, said once, exit 0" || fail "behind with people on: exit $rc, told $(told), $out"
run
[ "$rc" = 0 ] && [ "$(told)" = 1 ] && [ "$(asked ' stop \| restart \| up ')" = 0 ] \
  && pass "the next run, still 3 on: says nothing new" || fail "second run with people on: told $(told), $out"

echo "=== behind, nobody on ==="
# Every kind of update the script knows, whichever this server uses: a
# restart, and a one-shot service run before the server starts.
for how in $(printf '%s\n' "$UPD" restart game-update | sort -u); do
  fresh "$how"; answers "$OLD" "$OLD" "$NEW"; run
  if [ "$how" = restart ]; then did=$(asked " restart $SERVICE"); else did=$(( $(asked " stop $SERVICE") + $(asked " up -d $SERVICE") )); fi
  [ "$rc" = 0 ] && [[ $out == *"updated: version 10828683 -> 11191711, which Steam calls current"* ]] \
    && [ "$did" -ge 1 ] && [ "$(grep -c . "$CASE/repo/.steam-uptodate-updates")" = 1 ] \
    && [ ! -e "$CASE/repo/.steam-uptodate-state" ] && [ -s "$CASE/host.last" ] && [ "$(told)" = 1 ] \
    && pass "$how: empty and behind -> updated, and Steam's answer is the proof" || fail "$how update: exit $rc, $out"
done
fresh game-update; answers "$OLD" "$NEW"; run
[[ $(tr '\n' '|' <"$CASE/docker.log") == *"stop $SERVICE"*"up -d $SERVICE"* ]] && [[ $out == *"(game-update: updated build 1 -> 2)"* ]] \
  && pass "a one-shot: the server is stopped before the one-shot runs, and the one-shot's last line is quoted" \
  || fail "one-shot order: $(tr '\n' '|' <"$CASE/docker.log") / $out"
fresh restart; answers "$OLD"; run
[ "$rc" = 1 ] && [[ $out == *"update did not take"* ]] && [[ $(state) == *warned* ]] \
  && [ "$(grep -c . "$CASE/repo/.steam-uptodate-updates")" = 1 ] \
  && pass "an update Steam does not accept: exit 1, tried once, said" || fail "update not accepted: exit $rc, $out"

echo "=== three tries in a day ==="
fresh restart; answers "$OLD"; now=$(date +%s)
printf '%s\n' $((now - 7200)) $((now - 3600)) $((now - 60)) >"$CASE/repo/.steam-uptodate-updates"; run
[ "$rc" = 1 ] && [[ $out == *"3 updates in 24 h did not fix it"* ]] && [ "$(asked ' restart ')" = 0 ] && [ "$(told)" = 1 ] \
  && pass "after 3 tries in 24 h: no fourth, said once, exit 1" || fail "three tries: exit $rc, $out"
run
[ "$rc" = 1 ] && [ "$(told)" = 1 ] && pass "the next run says nothing new" || fail "stuck, second run: told $(told)"
fresh restart; answers "$OLD" "$NEW"
printf '%s\n' $((now - 90000)) $((now - 88000)) $((now - 87000)) >"$CASE/repo/.steam-uptodate-updates"; run
[ "$rc" = 0 ] && [[ $out == *"updated:"* ]] && pass "tries older than 24 h do not count" || fail "old tries: exit $rc, $out"

echo "=== the game baked into the image ==="
fresh image; answers "$OLD"; run
[ "$rc" = 1 ] && [[ $out == *"baked into the image"* ]] && [ "$(asked ' stop \| restart \| up ')" = 0 ] && [ "$(told)" = 1 ] \
  && pass "behind, nothing here can update it: said once, exit 1" || fail "image: exit $rc, $out"
run
[ "$rc" = 1 ] && [ "$(told)" = 1 ] && pass "exit 1 on every run, said only the first time" || fail "image, second run: exit $rc, told $(told)"

echo "=== no answer ==="
fresh "$HOW"; answers "?"; run
[ "$rc" = 0 ] && [[ $out == *"did not answer A2S; nothing decided"* ]] && [ -s "$CASE/repo/.steam-uptodate-silent" ] \
  && pass "A2S silent: nothing decided, the silence noted, exit 0" || fail "A2S silent: exit $rc, $out"
echo "$(( $(date +%s) - 30000 ))" >"$CASE/repo/.steam-uptodate-silent"; run
[ "$rc" = 1 ] && [[ $out == *"has not been able to tell"* ]] && [ "$(told)" = 1 ] \
  && pass "silent for over six hours: exit 1, said once" || fail "long silence: exit $rc, $out"
run; [ "$(told)" = 1 ] && pass "and not said again" || fail "long silence said twice"
answers "$NEW"; run
[ "$rc" = 0 ] && [ ! -e "$CASE/repo/.steam-uptodate-silent" ] && pass "an answer clears the silence" || fail "silence not cleared"
echo "$(( $(date +%s) + 99999 ))" >"$CASE/repo/.steam-uptodate-silent"; answers "?"; run
[ "$rc" = 0 ] && pass "a silence stamped in the future is re-anchored, not trusted" || fail "future stamp: exit $rc, $out"
fresh "$HOW"; answers "10828683 0 ? -"; run
[ "$rc" = 0 ] && [[ $out == *"Steam did not answer about version 10828683"* ]] && [ "$(asked ' stop \| restart \| up ')" = 0 ] \
  && pass "Steam silent: nothing decided, nothing touched" || fail "Steam silent: exit $rc, $out"

echo "=== one update per pass, per host ==="
fresh restart; answers "$OLD"
( flock 8; sleep 3 ) 8>>"$CASE/host.lock" & sleep 0.5; run; wait
[ "$rc" = 0 ] && [[ $out == *"another server on this host is updating"* ]] && [ "$(asked ' restart ')" = 0 ] \
  && [ ! -e "$CASE/repo/.steam-uptodate-updates" ] \
  && pass "the host lock is held: waits for the next pass, no try counted" || fail "host lock: exit $rc, $out"
fresh restart; answers "$OLD"; echo "$(( $(date +%s) - 300 )) cs2" >"$CASE/host.last"; run
[ "$rc" = 0 ] && [[ $out == *"cs2 on this host was updated 5 min ago"* ]] && [ "$(asked ' restart ')" = 0 ] \
  && pass "another server was updated 5 min ago: waits for the next pass" || fail "host stamp: exit $rc, $out"

echo "=== --dry-run, --check, a stopped server, a symlink ==="
fresh restart; answers "$OLD"; run --dry-run
[ "$rc" = 0 ] && [[ $out == *"would update it"* ]] && [ "$(asked ' restart ')" = 0 ] && [ -z "$(state)" ] && [ "$(told)" = 0 ] \
  && pass "--dry-run decides and changes nothing" || fail "--dry-run: exit $rc, $out"
fresh "$HOW"; answers "$NEW"; run --check; a=$rc; answers "$OLD"; run --check; b=$rc; answers "?"; run --check; c=$rc
[ "$a$b$c" = 013 ] && [ -z "$(state)" ] && pass "--check: 0 current, 1 behind, 3 cannot tell; nothing written" || fail "--check gave $a$b$c"
fresh "$HOW"; answers "$OLD"; touch "$CASE/down"; run; a=$rc; run --check; b=$rc
[ "$a$b" = 03 ] && [[ $out == *"is not running"* ]] && pass "a stopped server: nothing to ask (exit 0; --check 3)" || fail "stopped: $a$b $out"
fresh "$HOW"; answers "$OLD"; ln -s /etc/passwd "$CASE/repo/.steam-uptodate-state"; run
[ "$rc" = 1 ] && [[ $out == *"symlink"* ]] && pass "a symlinked state file is refused" || fail "symlink: exit $rc, $out"

echo "=== restarts Docker did, which the health check cannot see ==="
rst() { cat "$CASE/repo/.steam-uptodate-restarts" 2>/dev/null; }
fresh "$HOW"; answers "$NEW"; echo "c1 0" >"$CASE/restarts"; run
[ "$rc" = 0 ] && [[ $(rst) == "/game-server c1 0 "* ]] && [ "$(told)" = 0 ] \
  && pass "the first run writes down name, container and count, and says nothing" || fail "restart baseline: exit $rc, $out"
echo "c1 2" >"$CASE/restarts"
printf '%s\n' 'map de_dust2 loaded' 'FATAL ERROR: Ran out of networkable entities +sv_setsteamaccount 0123456789ABCDEF0123456789ABCDEF' >"$CASE/crashlog"; run
[ "$rc" = 0 ] && [[ $out == *"the server restarted 2 times since "*", last exit code 139 (SIGSEGV), last finished 2026-11-14T08:12:31Z; its log before that: FATAL ERROR: Ran out of networkable entities +sv_setsteamaccount <masked> (2 in 24 h)"* ]] \
  && [ "$(told)" = 1 ] && pass "two restarts: said once, with the crash line and a long token masked, exit 0 below the limit" || fail "restarts seen: exit $rc, told $(told), $out"
run
[ "$rc" = 0 ] && [ "$(told)" = 1 ] && pass "the next run, nothing new: says nothing" || fail "after the restarts: exit $rc, $out"
echo "c1 0" >"$CASE/restarts"; run
[ "$rc" = 0 ] && [ "$(told)" = 1 ] && [[ $(rst) == "/game-server c1 0 "* ]] \
  && pass "the count back at 0 (a restart by hand): the new starting point, nothing said" || fail "count reset: exit $rc, $out"
echo "c1 1" >"$CASE/restarts"; rm -f "$CASE/crashlog"; run
[ "$rc" = 1 ] && [[ $out == *"restarted 1 time since"*"(3 in 24 h)"* ]] && [ "$(told)" = 2 ] \
  && pass "a third restart in 24 hours: exit 1" || fail "the limit: exit $rc, $out"
echo "c2 0" >"$CASE/restarts"; run
[ "$rc" = 0 ] && [[ $(rst) == "/game-server c2 0 "* ]] && pass "a new container (recreated): counted afresh, nothing said" || fail "new container: exit $rc, $out"
fresh "$HOW"; answers "$NEW"; echo "c1 0" >"$CASE/restarts"; run; echo "c1 1" >"$CASE/restarts"; OOM=true run
[[ $out == *"restarted 1 time since"*"; killed for memory (oom event, exit 137 (SIGKILL))"* ]] && pass "an oom event: killed for memory, exit 137 named" || fail "OOM: $out"
fresh "$HOW"; answers "$NEW"; echo "c1 0" >"$CASE/restarts"; run; touch "$CASE/inspect-fails"; before=$(rst); run
[ "$rc" = 1 ] && [[ $out == *"cannot read the restart count"* ]] && [ "$(rst)" = "$before" ] \
  && pass "an inspect that fails: exit 1, the state untouched" || fail "inspect fails: exit $rc, $out"
fresh restart; answers "$OLD" "$OLD" "$NEW"; echo "c1 2" >"$CASE/restarts"; run; answers "$OLD" "$OLD" "$NEW"
printf '%s\n' "$(( $(date +%s) - 7200 ))" >"$CASE/repo/.steam-uptodate-updates"; run; r1=$rc; answers "$NEW"; run
[ "$rc" = 0 ] && [ "$(told)" -le 1 ] && [[ $(rst) == "/game-server c1 0 "* ]] \
  && pass "the script's own update restart sets the count to 0: no alarm after it" || fail "own restart: exits $r1 $rc, told $(told), $out"
fresh "$HOW"; answers "$NEW"; echo "c1 0" >"$CASE/restarts"; run; echo "c1 1" >"$CASE/restarts"; run --check
[ "$rc" = 0 ] && pass "--check says only what Steam says" || fail "--check with a restart: exit $rc, $out"

echo "=== plants: each rule taken out, and seen gone ==="
fresh restart 's/^if \[ "\$humans" != 0 \]; then$/if false; then/'; answers "$BUSY" "11191711 3 1 -"; run
[ "$(asked ' restart ')" -ge 1 ] && pass "without the player count it restarts with 3 on: the people-on case can tell" \
  || fail "the player-count plant did not restart ($out)"
fresh restart 's/^  \[ "\${ok2:-}" = 1 \] && { new=\$v2; break; }$/  new=$v2; break/'; answers "$OLD"; run
[ "$rc" = 0 ] && [[ $out == *"updated:"* ]] && pass "without the proof it reports an update Steam never accepted: the case above can tell" \
  || fail "the proof plant did not claim success (exit $rc, $out)"
fresh restart 's/^if ! flock -n 9; then$/if false; then/'; answers "$OLD"
( flock 8; sleep 3 ) 8>>"$CASE/host.lock" & sleep 0.5; run; wait
[ "$(asked ' restart ')" -ge 1 ] && pass "without the host lock it updates while another server does: the lock case can tell" \
  || fail "the lock plant did not update ($out)"
fresh "$HOW" 's/ || \[ "\$rcount" -lt "\$bcount" \]; then$/; then/'; answers "$NEW"
echo "c1 2" >"$CASE/restarts"; run; echo "c1 0" >"$CASE/restarts"; run; echo "c1 1" >"$CASE/restarts"; run
[ "$rc" = 0 ] && [[ $out != *"restarted"* ]] && pass "without a fallen count as the new start, a crash after a restart by hand goes unseen: the reset case can tell" \
  || fail "the reset plant still saw it ($out)"
fresh restart 's/^if \[ "\$tries" -ge "\$MAX_TRIES" \]; then$/if false; then/'; answers "$OLD"
printf '%s\n' $((now - 7200)) $((now - 3600)) $((now - 60)) >"$CASE/repo/.steam-uptodate-updates"; run
[ "$(asked ' restart ')" -ge 1 ] && pass "without the daily limit it tries a fourth time: the limit case can tell" \
  || fail "the limit plant did not try again ($out)"

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
