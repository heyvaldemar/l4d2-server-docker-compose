#!/bin/bash
# Does the health check go by the game's own answer, run in the pinned image?
#
# tools/healthcheck.sh sends A2S_INFO, the engine's server query, to the game
# port and is healthy only on the engine's reply. Here it runs in the image
# the compose file pins, so bash, timeout, head, od and tr are proven to be
# there, against a stand-in that speaks just enough A2S
# (tests/fixtures/fake-a2s.py), in the stand-in's network namespace:
#
#   answers     bound to the interface address, as srcds binds it: healthy
#   challenge   S2C_CHALLENGE first, the info reply only to a query carrying
#               its bytes: healthy
#   silent      a socket on the port that never answers: unhealthy, and the
#               check is over within the 10 seconds Docker gives it
#   no socket   nothing bound to the port, which is a process that stands
#               without a network, as Black Mesa's did on Docker 29.4.2:
#               unhealthy
#
# The stand-in is not a server. The real one is the boot job in CI, which
# also stops the game process and requires the check to go red.
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }
IMAGE=$(grep -m1 -oE '\$\{L4D2_SERVER_IMAGE_TAG:-.*' l4d2-server-docker-compose.yml | sed -E -e ':a' -e 's/\$\{[A-Z0-9_]+:-([^{}]*)\}/\1/' -e 'ta')
PY=python:3.13-alpine@sha256:7984cf56ceaddebe4fefeb75d64000b9f45d8b77b11a09b24524da6cdc3af0c8
NET="l4d2-hc-net-$$"
cleanup() { docker rm -f "$NET" >/dev/null 2>&1; }
trap cleanup EXIT

standin() {  # mode bind: a fresh stand-in, waited for until it is bound
  docker rm -f "$NET" >/dev/null 2>&1
  docker run -d --name "$NET" -v "$PWD/tests/fixtures/fake-a2s.py:/fake-a2s.py:ro" "$PY" \
    python3 -u /fake-a2s.py "$1" 27015 "$2" >/dev/null || return 1
  for _ in $(seq 1 40); do
    docker logs "$NET" 2>&1 | grep -q '^bound' && return 0
    sleep 0.25
  done
  return 1
}
empty() {  # a namespace with nothing bound to the port
  docker rm -f "$NET" >/dev/null 2>&1
  docker run -d --name "$NET" "$PY" sleep 300 >/dev/null
}
check() {  # run the health check in the pinned image, in the stand-in's namespace: sets rc, out, secs
  out=$(docker run --rm --platform linux/amd64 --network "container:$NET" --entrypoint bash \
    -v "$PWD/tools/healthcheck.sh:/healthcheck.sh:ro" "$IMAGE" \
    -c 's=$SECONDS; bash /healthcheck.sh 27015; rc=$?; echo "secs=$((SECONDS - s))"; exit $rc' 2>&1); rc=$?
  secs=$(sed -n 's/^secs=//p' <<<"$out"); out=$(grep -v '^secs=' <<<"$out")
}

echo "=== the health check, in the pinned image, against a stand-in ==="
echo

standin answers iface || { fail "the stand-in never bound its port"; echo; echo "passed: $PASSED   failed: $FAILED"; exit 1; }
check
[ "$rc" = 0 ] && grep -q "^healthy:" <<<"$out" && pass "an answer on the interface address: healthy ($out)" || fail "answers: exit $rc, $out"

standin challenge iface || fail "the challenge stand-in never bound its port"
check
[ "$rc" = 0 ] && pass "a challenge first, then the answer: healthy" || fail "challenge: exit $rc, $out"

standin silent iface || fail "the silent stand-in never bound its port"
check
[ "$rc" = 1 ] && [[ $out == *"no A2S_INFO reply"* ]] && pass "a socket that never answers: unhealthy" || fail "silent: exit $rc, $out"
[ -n "$secs" ] && [ "$secs" -le 9 ] && pass "and the check was over in ${secs}s, inside Docker's 10" || fail "silent: the check took ${secs:-?}s"

empty
check
[ "$rc" = 1 ] && [[ $out == *"nothing is bound"* ]] && pass "no socket on the port: unhealthy" || fail "no socket: exit $rc, $out"

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
