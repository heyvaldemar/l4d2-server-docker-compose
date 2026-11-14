#!/bin/bash
# tools/steam-uptodate.sh against a container that really crashes.
#
# Not the game: a container named as this template's server, with Docker's
# restart policy, that prints a crash line and exits 3 every twelve seconds
# (longer than a run of the script, so a run never lands mid-restart).
# Steam's answer is stubbed "current", so the only thing the script can say
# is about restarts. The order, each step a run of the script:
#   first run                 writes the count down, says nothing
#   after the first crash     says it once, with the exit code and the crash
#                             line from the log, exit 0
#   the run after             says nothing
#   after `docker restart`    the count is back at 0: says nothing
#   three restarts later      3 or more in 24 hours: exit 1
# and a second container, 16 MB of memory, that eats more: the kill for
# memory is named from Docker's oom event, with exit 137 (SIGKILL), because a
# restarted container's own state no longer says so. And a third, as srcds_run
# behaves: the container stays up while the game process in it dies once and
# is started again; said once, from the game process's start time, with the
# crash line and srcds_run's own, while Docker's count stays at 0.
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }
SERVICE=$(sed -n 's/^SERVICE=//p' tools/steam-uptodate.sh)
GAME_PROC=$(sed -n 's/^GAME_PROC=\([a-z0-9_]*\).*/\1/p' tools/steam-uptodate.sh)
T="$(mktemp -d)"; P="restarts-test-$$"
cleanup() { docker compose -p "$P" -f "$T/compose.yml" down -t 0 >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/repo/tools"
cp tools/steam-uptodate.sh "$T/repo/tools/"
cat >"$T/compose.yml" <<YAML
services:
  $SERVICE:
    image: alpine:3.22
    restart: on-failure:5
    command: ["sh", "-c", "sleep 12; echo 'FATAL ERROR: Ran out of networkable entities'; exit 3"]
YAML
cid() { docker compose -p "$P" -f "$T/compose.yml" ps -q "$SERVICE"; }
count() { docker inspect -f '{{.RestartCount}}' "$(cid)"; }
running() {  # wait until it runs again
  for _ in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Running}}' "$(cid)")" = true ] && return 0; sleep 0.5; done; return 1
}
until_count() {  # n: wait until Docker has restarted it n times, and it runs
  for _ in $(seq 1 180); do [ "$(count)" -ge "$1" ] && running && return 0; sleep 1; done; return 1
}
run() {
  out=$(cd "$T/repo" && STEAM_UPTODATE_COMPOSE_FILE="$T/compose.yml" COMPOSE_PROJECT_NAME="$P" \
    STEAM_UPTODATE_PROBE="echo 11191711 0 1 -" STEAM_UPTODATE_HOST_LOCK="$T/lock" STEAM_UPTODATE_HOST_STAMP="$T/last" \
    tools/steam-uptodate.sh 2>&1); rc=$?
}

echo "=== a container that crashes, under Docker's restart policy ==="
docker compose -p "$P" -f "$T/compose.yml" up -d >/dev/null 2>&1 || { echo "cannot start the test container"; exit 1; }
running; run
[ "$rc" = 0 ] && [[ $out != *restarted* ]] && pass "first run: the count written down, nothing said (exit 0)" || fail "first run: exit $rc, $out"
until_count 1; run
[ "$rc" = 0 ] && [[ $out == *"the server restarted 1 time since"*", last exit code 3, "*"its log before that: FATAL ERROR: Ran out of networkable entities"* ]] \
  && pass "after the first crash: said once, exit code 3 and the crash line, exit 0" || fail "after the crash: exit $rc, $out"
run
[ "$rc" = 0 ] && [[ $out != *restarted* ]] && pass "the run after: nothing said" || fail "the run after: exit $rc, $out"
docker restart -t 0 "$(cid)" >/dev/null; running
[ "$(count)" = 0 ] && pass "docker restart sets the count back to 0 (measured here)" || fail "after docker restart the count is $(count)"
run
[ "$rc" = 0 ] && [[ $out != *restarted* ]] && pass "after a restart by hand: the new starting point, nothing said" || fail "after the restart by hand: exit $rc, $out"
until_count 3; run
[ "$rc" = 1 ] && [[ $out == *"the server restarted 3 times since"*"in 24 h)"* ]] \
  && pass "three restarts by the policy since, four in 24 hours: exit 1" || fail "the limit: exit $rc, $out"

echo
echo "=== a container killed for memory, under the same policy ==="
docker compose -p "$P" -f "$T/compose.yml" down -t 0 >/dev/null 2>&1
rm -f "$T/repo/.steam-uptodate-"*
cat >"$T/compose.yml" <<YAML
services:
  $SERVICE:
    image: alpine:3.22
    restart: on-failure:5
    mem_limit: 16m
    memswap_limit: 16m
    command: ["sh", "-c", "sleep 4; tail /dev/zero"]
YAML
docker compose -p "$P" -f "$T/compose.yml" up -d >/dev/null 2>&1 || { echo "cannot start the memory test container"; exit 1; }
running; run
[ "$rc" = 0 ] && [[ $out != *restarted* ]] && pass "first run: nothing said" || fail "memory, first run: exit $rc, $out"
until_count 1; run
[ "$rc" = 0 ] && [[ $out == *"the server restarted 1 time since"*"; killed for memory (oom event, exit 137 (SIGKILL))"* ]] \
  && pass "killed for memory: named from the oom event, exit 137 (SIGKILL)" || fail "memory: exit $rc, $out"

echo
echo "=== a game that dies and comes back inside its container, as srcds_run brings it back ==="
docker compose -p "$P" -f "$T/compose.yml" down -t 0 >/dev/null 2>&1
rm -f "$T/repo/.steam-uptodate-"*
cat >"$T/compose.yml" <<YAML
services:
  $SERVICE:
    image: alpine:3.22
    restart: on-failure:5
    command:
      - sh
      - -c
      - |
        printf '#!/bin/sh\n[ -e /tmp/once ] && while :; do sleep 1; done\ntouch /tmp/once; sleep 8; echo "Segmentation fault (core dumped)"; exit 139\n' >/tmp/$GAME_PROC
        chmod +x /tmp/$GAME_PROC
        while :; do /tmp/$GAME_PROC; echo "Server restart in 10 seconds"; sleep 2; done
YAML
game_start() { docker exec "$(cid)" sh -c 'for p in /proc/[0-9]*; do [ "$(cat "$p/comm" 2>/dev/null)" = "$1" ] && cut -d" " -f22 "$p/stat"; done' sh "$GAME_PROC" 2>/dev/null | sort -n | head -1; }
docker compose -p "$P" -f "$T/compose.yml" up -d >/dev/null 2>&1 || { echo "cannot start the srcds_run test container"; exit 1; }
running
for _ in $(seq 1 20); do [ -n "$(game_start)" ] && break; sleep 0.5; done
first=$(game_start); run
[ "$rc" = 0 ] && [[ $out != *restarted* ]] && pass "first run: the game's start written down, nothing said" || fail "srcds_run, first run: exit $rc, $out"
for _ in $(seq 1 60); do g=$(game_start); [ -n "$g" ] && [ "$g" != "$first" ] && break; sleep 1; done
run
[ "$rc" = 0 ] && [[ $out == *"the game restarted inside its container since "*"srcds_run brought it back, and Docker saw no restart; its log: Segmentation fault (core dumped);Server restart in 10 seconds (1 in 24 h)"* ]] && [ "$(count)" = 0 ] \
  && pass "the game died and came back inside: said once, with the crash line and srcds_run's own; Docker's count still 0" || fail "srcds_run, after the crash: exit $rc, count $(count), $out"
run
[ "$rc" = 0 ] && [[ $out != *restarted* ]] && pass "the run after: nothing said" || fail "srcds_run, the run after: exit $rc, $out"

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
