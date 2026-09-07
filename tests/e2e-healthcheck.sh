#!/bin/bash
# Does the health check notice when the GAME dies and the wrapper does not?
#
# This image runs `srcds_linux` directly under `bash -c`, with no
# `srcds_run` between them, so the wrapper is `bash` and a substring
# check does not lie here the way it does for the Laclede's LAN images.
# The exact form is kept anyway: the next image update may add one.
#
# Docker does not restart an unhealthy container by itself, so a check that
# stays green with the game dead is a check nobody else corrects.
#
# No game download involved: two processes with the right names are enough,
# and the check reads /proc, not the game.
set -uo pipefail

RUN="l4d2-server-hc-$$"
PASSED=0; FAILED=0
cleanup() { docker rm -f "$RUN" >/dev/null 2>&1; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

EXACT='grep -qsx srcds_linux /proc/[0-9]*/comm'

echo "=== the health check, in both directions ==="
echo

docker rm -f "$RUN" >/dev/null 2>&1
# debian, not alpine: busybox dispatches on argv[0], so a copy of its sleep
# named srcds_linux is not an applet it knows and exits immediately. A real standalone
# binary takes the name it is invoked under, which is what /proc/N/comm reads.
docker run -d --name "$RUN" debian:stable-slim sh -c '
  g=srcds; g="${g}_linux"
  cp /bin/sleep "/tmp/$g"
  cp /bin/sleep /tmp/bash
  "/tmp/$g" 3600 &
  /tmp/bash 3600 &
  wait' >/dev/null 2>&1 || { echo "cannot start the fixture container"; exit 1; }

# Both processes have to exist before anything is asserted, or a pass below
# would only mean the container was slow.
ready=false
for _ in $(seq 1 40); do
  if docker exec "$RUN" sh -c "$EXACT" 2>/dev/null; then ready=true; break; fi
  sleep 0.5
done
if [ "$ready" = true ]; then
  pass "with the game running, the exact check is green"
else
  fail "the fixture never came up; nothing below would mean anything"
  docker logs "$RUN" 2>&1 | tail -5 | sed 's/^/        /'
  echo; echo "passed: $PASSED   failed: $FAILED"; exit 1
fi

# Both names are present, so the loose form is green too. It has to be, or the
# comparison below proves nothing.

# THE CASE THIS EXISTS FOR: kill the game, leave the wrapper.
#
# /proc rather than pgrep: debian:stable-slim ships no procps, and a missing
# command exits non-zero, which a naive check reads as "the process is gone".
# The first version of this file did exactly that and reported a kill that
# never happened - the same shape of silent no-op the health check itself is
# written to avoid.
docker exec "$RUN" sh -c 'for p in /proc/[0-9]*; do
  [ "$(tr "\0" "\n" < "$p/cmdline" 2>/dev/null | head -1)" = "/tmp/srcds_linux" ] && kill -9 "${p##*/}" 2>/dev/null
done; true' >/dev/null 2>&1
# Waiting on something OTHER than the assertion. Waiting until $EXACT fails and
# then asserting that $EXACT fails proves nothing at all; this reads the comm
# files itself and counts.
gone=false
for _ in $(seq 1 20); do
  n="$(docker exec "$RUN" sh -c 'c=0; for p in /proc/[0-9]*; do
        [ "$(tr "\0" "\n" < "$p/cmdline" 2>/dev/null | head -1)" = "/tmp/srcds_linux" ] && c=$((c+1)); done; echo "$c"' 2>/dev/null)"
  if [ "${n:-1}" = "0" ]; then gone=true; break; fi
  sleep 0.5
done
if [ "$gone" != true ]; then
  fail "could not kill the game process, so the assertion below is meaningless"
else
  if docker exec "$RUN" sh -c "$EXACT" 2>/dev/null; then
    fail "the exact check stayed green with the game dead"
  else
    pass "with the game dead, the exact check goes red"
  fi

  # No wrapper here shares text with the game name, so a substring form would
  # go red too - there is no lie to demonstrate, and this file does not pretend
  # there is one.
fi

# And the wrapper is genuinely still there, so "green" above was about it.
if docker exec "$RUN" sh -c 'for p in /proc/[0-9]*; do [ "$(tr "\0" "\n" < "$p/cmdline" 2>/dev/null | head -1)" = "/tmp/bash" ] && exit 0; done; exit 1' 2>/dev/null; then
  pass "the wrapper is still running, so the check went red for the right reason"
else
  fail "the wrapper died too, so the scenario was not the one described"
fi

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
