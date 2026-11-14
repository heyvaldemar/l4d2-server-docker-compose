#!/bin/bash
# steam-uptodate.sh - ask Steam whether this server runs the build it
# requires, and bring it up to date while nobody is on it. Run it from the
# timer in systemd/, every fifteen minutes.
#
#   tools/steam-uptodate.sh            update if behind and nobody is on
#   tools/steam-uptodate.sh --check    say whether Steam calls it current
#                                      (exit 0), behind (1) or cannot tell (3)
#   tools/steam-uptodate.sh --dry-run  go as far as deciding, change nothing
#
# WHY IT EXISTS. On the machine this template comes from, Team Fortress 2 ran
# out of date for days in October 2026 while every check passed: the container
# was healthy, A2S answered, Steam listed the server, and no image watcher said
# a word, because the image had not changed. It was built in August, and
# "updates arrive as a new image" assumed the image followed Valve. Players on
# the current client cannot join a server Steam calls out of date. Steam
# answers the question directly: ISteamApps/UpToDateCheck takes the version a
# server reports over A2S and says whether that version is still allowed.
#
# WHAT IT DOES, each run, in one line of output:
#   current                    -> nothing; exit 0
#   behind, people on          -> says so once and waits: an update drops
#                                 them; exit 0
#   behind, nobody on          -> updates it, then asks Steam again until
#                                 Steam calls it current: the proof is
#                                 Steam's answer, never the update's exit
#                                 code; exit 0, or 1 when Steam never agrees
#   behind, game in the image  -> says so once: nothing here can update it,
#                                 it needs a newer image; exit 1 every run
#   still behind after 3 updates in 24 hours
#                              -> says so once and stops trying; exit 1
#   no answer (A2S or Steam)   -> nothing decided; exit 0 until the silence
#                                 has lasted STEAM_UPTODATE_SILENCE seconds
#                                 (six hours), then 1. A span, not a count of
#                                 runs: a count assumes how often it runs.
#   restarted since the last run -> says how often, why if it can tell (an
#                                 oom event, or the crash line from the log)
#                                 and when; said once, exit 0
#   3 or more of those in 24 hours -> the same, and exit 1
#
# A CRASH IS INVISIBLE TO THE HEALTH CHECK. The check runs inside the
# container, and a crash, then Docker's restart, give it a fresh one that
# answers again: green throughout. On a CS2 server I run with real players,
# the game crashed this way eleven times (out of networkable entities) before
# anyone saw it; this script is the same in every template that ships it. Docker counts its restart-policy restarts (RestartCount) on the
# host, where this runs: each run compares the container's name, id and count
# with what the last run wrote down. The first run only writes them down: it
# cannot date restarts from before it. A new id (the container recreated by
# an update or a release) starts afresh, and so does a count that went down:
# `docker restart`, this script's own update included, sets it back to 0. The
# price: a crash in the same window as a restart by hand is not seen.
# Measured on a server I run with real players: `docker restart` took the
# count from 1 to 0.
#
# A GAME THAT DIES IS BROUGHT BACK INSIDE ITS CONTAINER, here. Valve's
# srcds_run restarts the game when it exits, unless told -norestart, so a
# crash ends in a new game process in the same container: Docker counts no
# restart and the health check misses a few answers at most. Each run also
# writes down when the game process (GAME_PROC) started; a newer one in a
# container that did not itself restart since the last run is said once, as
# a restart, with the crash line from the log since then, and counts toward
# the same three in 24 hours.
#
# tests/steam-uptodate.sh drives every branch against stubbed answers:
#   STEAM_UPTODATE_PROBE   a command printing the probe's line, in place of
#                          asking A2S and Steam (tests)
#
# READ WHOLE BEFORE IT RUNS. bash reads a script as it executes it and, after
# each command, reads on from the same byte offset in whatever the file holds
# by then. On the machine this template comes from, a timer started a script
# while its file was being edited in place: a syntax error and a failed unit.
# The body is one brace group, which bash parses in full before the first line
# runs, and it ends in exit, so nothing past the closing brace is ever read.
# tests/read-whole.sh rewrites this file under a running copy both ways.
{
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# ------------------------------------------------------------- this server
GAME="Left 4 Dead 2"
SERVICE=l4d2-server
APPID=550
# How the game gets updated: "image" - it is baked into the image, so the
# script only says when Steam stops accepting it ("restart" and a one-shot
# service are the other two kinds, in the templates that can update).
HOW=image
PORT=$(sed -n 's/^L4D2_SERVER_PORT=\([0-9]*\).*/\1/p' .env 2>/dev/null | tail -1)
PORT=${PORT:-27015}
COMPOSE_FILE=${STEAM_UPTODATE_COMPOSE_FILE:-l4d2-server-docker-compose.yml}
PROJECT=${COMPOSE_PROJECT_NAME:-l4d2}
# ----------------------------------------------------------------------------

MODE=run
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --dry-run) MODE=dry-run ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

STATE=${STEAM_UPTODATE_STATE:-.steam-uptodate-state}       # "<since> [warned] [stuck]"
HISTORY=${STEAM_UPTODATE_HISTORY:-.steam-uptodate-updates} # one epoch per update tried
SILENT=${STEAM_UPTODATE_SILENT_FILE:-.steam-uptodate-silent} # "<since> [warned]"
RESTARTS=${STEAM_UPTODATE_RESTARTS_FILE:-.steam-uptodate-restarts} # "<name> <container id> <restart count> <since>"
CRASHES=${STEAM_UPTODATE_CRASHES_FILE:-.steam-uptodate-crashes}    # one "<epoch> <restarts>" per run that saw some
CRASH_LIMIT=${STEAM_UPTODATE_CRASH_LIMIT:-3}                       # restarts in 24 h that make it exit 1
GAMEFILE=${STEAM_UPTODATE_GAME_FILE:-.steam-uptodate-game}         # "<container id> <its start> <game process start> <when read>"
GAME_PROC=srcds_linux   # the game's process name: srcds_run restarts it inside the container
HOST_LOCK=${STEAM_UPTODATE_HOST_LOCK:-/var/tmp/steam-uptodate.lock}
HOST_STAMP=${STEAM_UPTODATE_HOST_STAMP:-/var/tmp/steam-uptodate.last}
# The probe runs python from this image, inside the server's network namespace;
# pinned by digest, so the tag being moved cannot change what runs there.
PROBE_IMAGE=${STEAM_UPTODATE_PROBE_IMAGE:-python:3.13-alpine@sha256:7984cf56ceaddebe4fefeb75d64000b9f45d8b77b11a09b24524da6cdc3af0c8}
MAX_TRIES=${STEAM_UPTODATE_MAX_TRIES:-3}
WAIT=${STEAM_UPTODATE_WAIT:-1200}         # for Steam to call the new version current
POLL=${STEAM_UPTODATE_POLL:-15}
PASS=${STEAM_UPTODATE_PASS:-900}          # the timer's period: one update per pass
TOLERANCE=${STEAM_UPTODATE_SILENCE:-21600}
UPDATE_TIMEOUT=${STEAM_UPTODATE_UPDATE_TIMEOUT:-3600}

compose() { docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }
# timeout(1) is GNU coreutils: without it the command runs unbounded rather
# than not at all. It runs programs, not shell functions, so whatever it bounds
# is spelled out as `docker compose ...`, never as `compose`.
limit() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi; }
now() { date +%s; }
say() { echo "$(date '+%F %T') $*"; }
tell() {  # message: once, to whoever STEAM_UPTODATE_NOTIFY reaches
  if [ "$MODE" != run ] || [ -z "${STEAM_UPTODATE_NOTIFY:-}" ]; then return 0; fi
  printf '%s\n' "$1" | limit 30 sh -c "$STEAM_UPTODATE_NOTIFY" >/dev/null 2>&1 \
    || say "STEAM_UPTODATE_NOTIFY failed; the message was: $1"
}

# A state file that is a symlink could be pointed at anything this user can
# write; it is refused, and so is one that cannot be written.
for f in "$STATE" "$HISTORY" "$SILENT" "$RESTARTS" "$CRASHES" "$GAMEFILE"; do
  [ -L "$f" ] && { say "$f is a symlink; refusing to use it"; exit 1; }
done
put() {  # file [line]: replace the file's content, or remove it
  [ "$MODE" = run ] || return 0
  if [ -z "${2:-}" ]; then rm -f "$1"; return; fi
  local tmp
  tmp=$(mktemp "$1.XXXXXX") || { say "cannot write beside $1"; exit 1; }
  if ! { printf '%s\n' "$2" >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$1"; }; then
    rm -f "$tmp"; say "cannot write $1"; exit 1
  fi
}

# "<version> <humans> <up_to_date 1|0|?> <required|->", or "?" when A2S did not
# answer. One container, in the server's own network namespace, asks both A2S
# and Steam, so it works however the server reaches the outside: published
# ports, a relay, or none.
probe() {
  if [ -n "${STEAM_UPTODATE_PROBE:-}" ]; then sh -c "$STEAM_UPTODATE_PROBE"; return; fi
  local cid ip
  cid=$(compose ps -q --status running "$SERVICE" 2>/dev/null | head -1)
  [ -n "$cid" ] || { echo "?"; return; }
  # srcds binds the address of its interface, not 0.0.0.0, so the query goes
  # to that address first; loopback is the fallback for one that binds both.
  ip=$(docker inspect "$cid" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null)
  # shellcheck disable=SC2086   # $ip is a list of addresses, one argument each
  limit 60 docker run --rm --network "container:$cid" "$PROBE_IMAGE" python3 -c '
import json, socket, sys, urllib.request
appid, port, ips = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
try:
    ips.append(socket.gethostbyname(socket.gethostname()))
except OSError:
    pass
ips.append("127.0.0.1")
Q = b"\xff\xff\xff\xffTSource Engine Query\x00"
def info(ip):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
    try:
        s.sendto(Q, (ip, port)); d = s.recvfrom(4096)[0]
        if d[4:5] == b"A":                    # a challenge: ask again, carrying it
            s.sendto(Q + d[5:9], (ip, port)); d = s.recvfrom(4096)[0]
    finally:
        s.close()
    if d[4:5] != b"I":
        raise ValueError("not an A2S_INFO reply")
    b = d[6:]
    for _ in range(4):                        # name, map, folder, game
        b = b[b.index(b"\x00") + 1:]
    players, bots = b[2], b[4]                # after the 16-bit app id
    v = b[9:]
    return v[:v.index(b"\x00")].decode(), max(players - bots, 0)
for ip in dict.fromkeys(ips):
    try:
        version, humans = info(ip)
        break
    except Exception:
        continue
else:
    print("?"); sys.exit()
try:
    r = json.load(urllib.request.urlopen(
        "https://api.steampowered.com/ISteamApps/UpToDateCheck/v1/?appid=%s&version=%s&format=json" % (appid, version),
        timeout=10))["response"]
    if not r.get("success"):
        raise ValueError(r)
    # CS2 answers required_version 14194, an internal number, and puts the
    # version a person would recognise in the message instead.
    req = r.get("message", "").partition("required: ")[2].strip() or str(r.get("required_version") or "-")
    print(version, humans, 1 if r.get("up_to_date") else 0, req.replace(" ", "_"))
except Exception:
    print(version, humans, "?", "-")
' "$APPID" "$PORT" $ip 2>/dev/null || echo "?"
}

if [ -z "$(compose ps -q --status running "$SERVICE" 2>/dev/null)" ]; then
  say "$SERVICE is not running; nothing to ask Steam about"
  [ "$MODE" = check ] && exit 3
  exit 0
fi

# ------------------------------------------------------------- restarts
when() { date -d "@$1" '+%F %T' 2>/dev/null || date -r "$1" '+%F %T' 2>/dev/null || echo "$1"; }
if [ "$MODE" != check ]; then
  rcid=$(compose ps -q --status running "$SERVICE" 2>/dev/null | head -1)
  # One inspect, no Health in it: a container without a health check has no
  # .State.Health, and naming it fails the whole template.
  if ! info=$(docker inspect "$rcid" --format '{{.Name}} {{.Id}} {{.RestartCount}} {{.State.FinishedAt}} {{.State.StartedAt}}' 2>/dev/null) || [ -z "$info" ]; then
    say "cannot read the restart count of $SERVICE; nothing written"
    exit 1
  fi
  read -r rname rid rcount rfin rstart <<<"$info"
  case ${rcount:-} in ''|*[!0-9]*) say "cannot read the restart count of $SERVICE ($rcount); nothing written"; exit 1 ;; esac
  read -r bname bid bcount bsince 2>/dev/null <"$RESTARTS" || true
  case ${bcount:-} in ''|*[!0-9]*) bcount="" ;; esac
  case ${bsince:-} in ''|*[!0-9]*) bsince=$(now) ;; esac
  if [ "${bname:-}" = "$rname" ] && [ "${bid:-}" = "$rid" ] && [ -n "$bcount" ] && [ "$rcount" -gt "$bcount" ]; then
    more=$(( rcount - bcount ))
    # WHY, when it can tell, from Docker's events: once Docker has restarted
    # a container, its .State says exit code 0 and not killed for memory again
    # (both measured), so only the events keep them. An "oom" event is the one
    # sign of a kill for memory; 137 alone could be any SIGKILL. Read from a
    # minute before the last run to two seconds from now: an "until" of this
    # very second missed a die of this very second, "now" and "0s" alike
    # (measured), and a moment ahead waits for it. Older than the daemon's
    # memory of them: exit "?".
    ev=$(docker events --since $(( bsince - 60 )) --until $(( $(now) + 2 )) --filter "container=$rid" --filter event=die --filter event=oom \
      --format '{{.Action}} {{index .Actor.Attributes "exitCode"}}' 2>/dev/null)
    rexit=$(awk '$1 == "die" { c = $2 } END { print c }' <<<"$ev")
    # A KILL FOR MEMORY CAN BE STORED LATE. On a GitHub runner (Docker 29.4.2)
    # the oom event of 1 kill in 20 was not there when the die was, and was
    # 10 seconds later. A 137 with no oom event yet is read again, for up to
    # ten seconds, before it is called a plain SIGKILL.
    if [ "$rexit" = 137 ] && ! grep -q '^oom' <<<"$ev"; then
      for _ in 1 2 3 4 5; do
        sleep 2
        ev=$(docker events --since $(( bsince - 60 )) --until $(( $(now) + 2 )) --filter "container=$rid" --filter event=die --filter event=oom \
          --format '{{.Action}} {{index .Actor.Attributes "exitCode"}}' 2>/dev/null)
        grep -q '^oom' <<<"$ev" && break
      done
    fi
    case "$rexit" in
      134) rexit="134 (SIGABRT)" ;; 137) rexit="137 (SIGKILL)" ;; 139) rexit="139 (SIGSEGV)" ;; 143) rexit="143 (SIGTERM)" ;;
    esac
    why=""
    if grep -q '^oom' <<<"$ev"; then
      why="killed for memory (oom event, exit ${rexit:-?})"
    else
      # The last crash line the game printed before Docker started it again.
      # Anything 24 characters or longer is masked: a crash dump can repeat
      # the command line, and a token with it. A game that logs only to
      # files leaves this empty.
      why=$(docker logs --until "$rstart" --tail 400 "$rid" 2>&1 | grep -a -i -E 'fatal|segmentation|core dumped|panic|abort' | tail -1 \
        | sed -E 's/[A-Za-z0-9+\/=_-]{24,}/<masked>/g' | tr -d '\r' | cut -c1-200)
      [ -n "$why" ] && why="its log before that: $why"
    fi
    crashed="the server restarted $more time$( [ "$more" = 1 ] || echo s) since $(when "$bsince"), last exit code ${rexit:-?}, last finished ${rfin:-?}${why:+; $why}"
    before=0
    [ -f "$CRASHES" ] && before=$(awk -v t=$(( $(now) - 86400 )) '$1 > t { n += $2 } END { print n + 0 }' "$CRASHES")
    recent=$(( before + more ))
    if [ "$MODE" = run ]; then echo "$(now) $more" >>"$CRASHES" && chmod 600 "$CRASHES"; fi
    put "$RESTARTS" "$rname $rid $rcount $(now)"
    say "$crashed ($recent in 24 h)"
    tell "$GAME: $crashed. Docker brought it back and its health check is green again, so nothing else says so. docker compose -p $PROJECT logs --since 2h $SERVICE"
    [ "$recent" -ge "$CRASH_LIMIT" ] && exit 1
  elif [ "${bname:-}" != "$rname" ] || [ "${bid:-}" != "$rid" ] || [ -z "$bcount" ] || [ "$rcount" -lt "$bcount" ]; then
    put "$RESTARTS" "$rname $rid $rcount $(now)"
  fi
fi

# ------------------------------------------------------------- the game, restarted inside
if [ "$MODE" != check ]; then
  # The oldest process of that name: the game, not a helper it forks. Its
  # start time, field 22 of /proc/<pid>/stat, in clock ticks since boot.
  # shellcheck disable=SC2016   # expanded by the container's sh, on purpose
  gnow=$(docker exec "$rcid" sh -c 'for p in /proc/[0-9]*; do c=$(cat "$p/comm" 2>/dev/null) || continue; [ "$c" = "$1" ] && cut -d" " -f22 "$p/stat" 2>/dev/null; done' sh "$GAME_PROC" 2>/dev/null | sort -n | head -1)
  case "$gnow" in ''|*[!0-9]*) gnow="" ;; esac
  if [ -n "$gnow" ]; then
    gid=""; gstarted=""; gstart=""; gsince=""
    read -r gid gstarted gstart gsince 2>/dev/null <"$GAMEFILE" || true
    case ${gsince:-} in ''|*[!0-9]*) gsince=$(now) ;; esac
    if [ "$gid" = "$rid" ] && [ "$gstarted" = "$rstart" ] && [ -n "$gstart" ] && [ "$gnow" != "$gstart" ]; then
      # The crash line, and srcds_run's own, since the last run; 24
      # characters or more masked, as above.
      gwhy=$(docker logs --since "$gsince" "$rid" 2>&1 | grep -a -i -E 'fatal|segmentation|core dumped|panic|abort|restart in' | tail -2 \
        | sed -E 's/[A-Za-z0-9+\/=_-]{24,}/<masked>/g' | tr -d '\r' | cut -c1-160 | paste -sd ';' -)
      before=0
      [ -f "$CRASHES" ] && before=$(awk -v t=$(( $(now) - 86400 )) '$1 > t { n += $2 } END { print n + 0 }' "$CRASHES")
      recent=$(( before + 1 ))
      if [ "$MODE" = run ]; then echo "$(now) 1" >>"$CRASHES" && chmod 600 "$CRASHES"; fi
      put "$GAMEFILE" "$rid $rstart $gnow $(now)"
      inside="the game restarted inside its container since $(when "$gsince"): srcds_run brought it back, and Docker saw no restart${gwhy:+; its log: $gwhy}"
      say "$inside ($recent in 24 h)"
      tell "$GAME: $inside. Its health check is green again, so nothing else says so. docker compose -p $PROJECT logs --since 2h $SERVICE"
      [ "$recent" -ge "$CRASH_LIMIT" ] && exit 1
    else
      put "$GAMEFILE" "$rid $rstart $gnow $(now)"
    fi
  fi
fi

read -r ver humans ok req < <(probe)
t=$(now)

# ------------------------------------------------------------- no answer
if [ -z "${ver:-}" ] || [ "$ver" = "?" ] || [ "${ok:-?}" = "?" ]; then
  if [ -z "${ver:-}" ] || [ "$ver" = "?" ]; then what="the server did not answer A2S"; else what="Steam did not answer about version $ver"; fi
  [ "$MODE" = check ] && { say "$what"; exit 3; }
  read -r since flags 2>/dev/null <"$SILENT" || true
  since=${since:-$t}
  case $since in ''|*[!0-9]*) since=$t ;; esac
  [ "$since" -gt "$t" ] && since=$t       # a stamp from the future is re-anchored
  quiet=$(( t - since ))
  if [ "$quiet" -lt "$TOLERANCE" ]; then
    put "$SILENT" "$since ${flags:-}"
    say "$what; nothing decided (no answer for $(( quiet / 60 )) min, tolerated for $(( TOLERANCE / 3600 )) h)"
    exit 0
  fi
  say "$what, for $(( quiet / 60 )) min: this check has not been able to tell for over $(( TOLERANCE / 3600 )) h"
  if [[ " ${flags:-} " != *" warned "* ]]; then
    tell "$GAME: $what for $(( quiet / 3600 )) h, so nobody can say whether it is up to date. Is the server up, and can it reach api.steampowered.com?"
  fi
  put "$SILENT" "$since warned"
  exit 1
fi
put "$SILENT"
req=${req//_/ }

# ------------------------------------------------------------- current
if [ "$ok" = 1 ]; then
  if [ -s "$STATE" ]; then say "current again: version $ver"; else say "current: version $ver"; fi
  put "$STATE"
  exit 0
fi

# ------------------------------------------------------------- behind
[ "$MODE" = check ] && { say "out of date: version $ver, Steam requires $req"; exit 1; }
read -r since flags 2>/dev/null <"$STATE" || true
since=${since:-$t}
case $since in ''|*[!0-9]*) since=$t ;; esac
flags=" ${flags:-} "
# Written down at first sight, so every later line can say how long it has
# been known - not how long it has been true, which only Steam's own history
# could say.
[ -s "$STATE" ] || put "$STATE" "$since"
behind="$GAME reports version $ver; Steam requires $req and calls it out of date. Players on the current client cannot join it."
known="known for $(( (t - since) / 60 )) min"

if [ "$HOW" = image ]; then
  say "out of date: version $ver, required $req ($known); the game is baked into the image, so it needs a newer image"
  if [[ "$flags" != *" warned "* ]]; then
    tell "$behind The game is baked into this template's image, so nothing here can update it: it needs a newer image. Check for a new release of the template and run ./update.sh. Nothing has been changed."
    put "$STATE" "$since warned"
  fi
  exit 1
fi

if [ "$humans" != 0 ]; then
  say "out of date: version $ver, required $req ($known); $humans on it, so it waits for them to leave"
  if [[ "$flags" != *" warned "* ]]; then
    tell "$behind $humans $( [ "$humans" = 1 ] && echo "player is" || echo "players are") on it, so it has NOT been updated: that would drop them. It updates on its own once it is empty."
    put "$STATE" "$since warned"
  fi
  exit 0
fi

tries=0
if [ -f "$HISTORY" ]; then
  tries=$(awk -v t=$(( t - 86400 )) '$1 > t' "$HISTORY" | wc -l | tr -d ' ')
fi
if [ "$tries" -ge "$MAX_TRIES" ]; then
  say "out of date: version $ver, required $req ($known); $tries updates in 24 h did not fix it, so no more are tried"
  if [[ "$flags" != *" stuck "* ]]; then
    tell "$behind It was updated $tries times in 24 hours and still reports $ver, so another try would only repeat whatever is failing. Left for a human: docker compose -p $PROJECT logs $SERVICE$( [ "$HOW" != restart ] && printf ' %s' "$HOW")"
    put "$STATE" "$since warned stuck"
  fi
  exit 1
fi

if [ "$MODE" = dry-run ]; then
  say "out of date: version $ver, required $req ($known); nobody on: would update it ($HOW)"
  exit 0
fi

# ------------------------------------------------------------- one update per pass
for f in "$HOST_LOCK" "$HOST_STAMP"; do
  [ -L "$f" ] && { say "$f is a symlink; refusing to use it"; exit 1; }
done
exec 9>>"$HOST_LOCK" || { say "cannot open the host lock $HOST_LOCK"; exit 1; }
if ! flock -n 9; then
  say "out of date: version $ver, required $req ($known); another server on this host is updating, so this one waits for the next pass"
  exit 0
fi
read -r last who 2>/dev/null <"$HOST_STAMP" || true
case ${last:-} in ''|*[!0-9]*) last=0 ;; esac
if [ $(( t - last )) -lt "$PASS" ] && [ "$last" -le "$t" ]; then
  say "out of date: version $ver, required $req ($known); ${who:-a server} on this host was updated $(( (t - last) / 60 )) min ago, so this one waits for the next pass"
  exit 0
fi

if ! { echo "$t" >>"$HISTORY" && chmod 600 "$HISTORY"; }; then say "cannot write $HISTORY"; exit 1; fi
say "out of date: version $ver, required $req ($known); nobody on: updating ($HOW)"
note=""
case $HOW in
  restart)
    limit "$UPDATE_TIMEOUT" docker compose -f "$COMPOSE_FILE" -p "$PROJECT" restart "$SERVICE" >/dev/null 2>&1 ;;
  *)
    # The one-shot runs before the server starts, so the server is stopped
    # first: the game is never updated under a running server. Starting the
    # server runs the one-shot again, and its last line says what it did.
    since_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    compose stop "$SERVICE" >/dev/null 2>&1
    limit "$UPDATE_TIMEOUT" docker compose -f "$COMPOSE_FILE" -p "$PROJECT" up -d "$SERVICE" >/dev/null 2>&1
    note=$(compose logs --no-log-prefix --since "$since_ts" "$HOW" 2>/dev/null | grep -a "^$HOW:" | tail -1)
    # An update that ran out of time, or a one-shot that failed, leaves the
    # server stopped; it comes back on the game it has rather than staying
    # down until somebody notices.
    [ -n "$(compose ps -q --status running "$SERVICE" 2>/dev/null)" ] \
      || compose up -d --no-deps "$SERVICE" >/dev/null 2>&1 ;;
esac
printf '%s %s\n' "$(now)" "$PROJECT" >"$HOST_STAMP" 2>/dev/null

# PROVEN BY STEAM, not by the update having exited 0: the same question that
# found it behind, asked until the answer changes.
new="" t0=$(now)
while [ $(( $(now) - t0 )) -lt "$WAIT" ]; do
  sleep "$POLL"
  read -r v2 _ ok2 _ < <(probe)
  [ "${ok2:-}" = 1 ] && { new=$v2; break; }
done
took=$(( $(now) - t0 ))
printf '%s %s\n' "$(now)" "$PROJECT" >"$HOST_STAMP" 2>/dev/null

if [ -n "$new" ]; then
  put "$STATE"
  say "updated: version $ver -> $new, which Steam calls current, ${took} s after the update${note:+ ($note)}"
  tell "$GAME updated to the version Steam requires: it reported $ver (required $req), nobody was on it, and it now reports $new, which Steam calls current.${note:+ ($note)}"
  exit 0
fi
put "$STATE" "$since warned"
say "update did not take: Steam still does not call it current ${took} s later${note:+ ($note)}"
tell "$behind Nobody was on it, so it was updated, but $(( WAIT / 60 )) min later Steam still does not accept what it reports.${note:+ ($note)} It is tried again on a later pass, up to $MAX_TRIES times in 24 hours."
exit 1
}
