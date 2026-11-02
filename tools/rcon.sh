#!/bin/bash
# rcon.sh - run a console command on the server, over rcon, from inside its
# network namespace.
#
#   tools/rcon.sh status
#   tools/rcon.sh changelevel c2m1_highway
#
# UP TO v1.3 THE README SAID `docker compose exec l4d2-server rcon status`. The
# pinned image has no rcon program in it (`command -v rcon` inside it comes
# back empty), and no python3 either, so this runs the rcon client from the
# same pinned python image tools/steam-uptodate.sh asks A2S with, in the
# server's network namespace. CI runs `status` against the real server and
# needs the hostname line back, and a wrong password refused.
#
# THE SERVER'S OWN ADDRESS, whatever the network looks like outside:
# published on the host, behind a relay, or on a bridge nobody has mapped.
# srcds binds the address of its interface, not 0.0.0.0, so that address is
# tried before loopback.
#
# THE PASSWORD TRAVELS ON STDIN, never in argv, where `ps` on the host would
# show it to every user. It is read from .env, the file the server got it from.
#
# THE END OF A REPLY. Source servers answer an empty packet sent after the
# command once all of the command's output has gone out, which marks the end.
# A server that does not is read until it has been quiet for a second and a
# half, so a reply is never cut short and a missing marker never hangs.
#
# Read whole before it runs: one brace group, ending in exit
# (tools/steam-uptodate.sh, "READ WHOLE BEFORE IT RUNS", says why).
{
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

[ "$#" -gt 0 ] || { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
COMPOSE_FILE=${L4D2_COMPOSE_FILE:-l4d2-server-docker-compose.yml}
PROJECT=${COMPOSE_PROJECT_NAME:-l4d2}
SERVICE=l4d2-server
# The same pinned image as the Steam check's probe.
PROBE_IMAGE=${STEAM_UPTODATE_PROBE_IMAGE:-python:3.13-alpine@sha256:7984cf56ceaddebe4fefeb75d64000b9f45d8b77b11a09b24524da6cdc3af0c8}
PORT=$(sed -n 's/^L4D2_SERVER_PORT=\([0-9]*\).*/\1/p' .env 2>/dev/null | tail -1)
PORT=${PORT:-27015}
pw=$(sed -n 's/^L4D2_SERVER_RCON_PASSWORD=//p' .env 2>/dev/null | tail -1)
pw=${pw%\"}; pw=${pw#\"}; pw=${pw%\'}; pw=${pw#\'}
[ -n "$pw" ] || { echo "L4D2_SERVER_RCON_PASSWORD is not set in .env" >&2; exit 1; }
cid=$(docker compose -f "$COMPOSE_FILE" -p "$PROJECT" ps -q --status running "$SERVICE" 2>/dev/null | head -1)
[ -n "$cid" ] || { echo "$SERVICE is not running" >&2; exit 1; }
ip=$(docker inspect "$cid" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null)

printf '%s\n' "$pw" | docker run --rm -i --network "container:$cid" "$PROBE_IMAGE" python3 -c '
import socket, struct, sys
port, ips, cmd = int(sys.argv[1]), sys.argv[2].split(), " ".join(sys.argv[3:])
pw = sys.stdin.readline().rstrip("\n")
def packet(i, kind, body):
    b = struct.pack("<ii", i, kind) + body.encode() + b"\x00\x00"
    return struct.pack("<i", len(b)) + b
def take(s, n):
    d = b""
    while len(d) < n:
        c = s.recv(n - len(d))
        if not c:
            raise EOFError("the server closed the connection")
        d += c
    return d
def read(s):
    n = struct.unpack("<i", take(s, 4))[0]
    d = take(s, n)
    i, kind = struct.unpack("<ii", d[:8])
    return i, kind, d[8:-2]
try:
    ips.append(socket.gethostbyname(socket.gethostname()))
except OSError:
    pass
ips.append("127.0.0.1")
s = None
for ip in dict.fromkeys(ips):
    try:
        s = socket.create_connection((ip, port), timeout=10)
        break
    except OSError:
        continue
if s is None:
    sys.exit("rcon: nothing accepted a connection on port %d" % port)
s.sendall(packet(1, 3, pw))                   # SERVERDATA_AUTH
while True:
    i, kind, _ = read(s)
    if kind == 2:                             # SERVERDATA_AUTH_RESPONSE
        break
if i == -1:
    print("rcon: the server refused the password", file=sys.stderr)
    sys.exit(2)
s.sendall(packet(2, 2, cmd))                  # SERVERDATA_EXECCOMMAND
s.sendall(packet(3, 0, ""))                   # the end marker, if it is answered
out = b""
s.settimeout(5)                               # for the first packet of the reply
try:
    while True:
        i, kind, body = read(s)
        if i == 3:
            break
        if i == 2:
            out += body
        s.settimeout(1.5)                     # then: quiet this long is the end
except (socket.timeout, EOFError):
    pass
sys.stdout.write(out.decode("utf-8", "replace"))
' "$PORT" "$ip" "$@"
exit
}
