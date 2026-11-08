#!/bin/bash
# healthcheck.sh - healthy only when the game itself answers.
#
# Sends A2S_INFO, the Source engine's own server query (the one every server
# browser sends), to the game port inside the container, and
# exits 0 only on the engine's reply. Only a running engine writes one: srcds
# reads the query in its frame and answers it there.
#
# NOT THE PROCESS. The check used to look for the server's process in /proc.
# On Docker Engine 29.4.2, whose seccomp profile answers 32-bit socketcall(2)
# with ENOSYS, Black Mesa's 32-bit srcds ran with no socket at all and stayed
# healthy (run 42503040679); a hung or stopped server keeps its process too.
#
# NOT THE LOG. An empty server hibernates and writes nothing for hours while
# it is perfectly well; it still answers A2S_INFO, which is how a server
# browser lists an empty server.
#
# A MAP CHANGE stops the answers for the seconds the next map takes to load,
# so one check tries twice, a second apart, and Docker's retries cover the
# rest: three misses in a row at the compose file's interval. Every read
# times out after 1.5 seconds (a running server answers in milliseconds);
# with two addresses to try, a silent server costs the whole check 7 seconds,
# inside the 10 Docker gives it.
#
# THE CHALLENGE. Since 2020 Source servers may answer the first A2S_INFO with
# S2C_CHALLENGE ('A' and four bytes); the query is then sent again with those
# bytes appended, and only the info reply ('I') counts.
#
# THE ADDRESS IT ANSWERS ON. The addresses come from /proc/net/udp, every
# socket bound to the game port; no socket there at all is unhealthy at once.
# Bound to one address, that address. Bound to 0.0.0.0 (Left 4 Dead 2), the
# container's own address from /etc/hosts first, then 127.0.0.1: such a
# server did not answer a query sent to 127.0.0.1 (CI, 2026-11-08), and the
# query CI had always sent went to the container's address.
#
# INSIDE THE CONTAINER. This proves the server answers in its own network
# namespace. It does not prove the port is published on the host, nor that a
# firewall lets players in.
#
# Usage: healthcheck.sh [port]   (default 27015). Needs bash, timeout, head,
# od and tr, which the image has (tests/e2e-healthcheck.sh runs it there).
#
# Read whole before it runs: one brace group, ending in exit
# (tools/steam-uptodate.sh, "READ WHOLE BEFORE IT RUNS", says why).
{
set -u
port=${1:-27015}
req='\xff\xff\xff\xffTSource Engine Query\x00'

addrs=()   # every address a UDP socket on the game port is bound to
want=$(printf '%04X' "$port")
while read -r _ local _; do
  [[ $local == *:"$want" ]] || continue
  h=${local%%:*}
  if [ "$h" = 00000000 ]; then
    cands=()
    read -r me < /etc/hostname 2>/dev/null || me=
    while read -r ip name _; do
      [[ -n $me && $name == "$me" && $ip == *.*.*.* ]] && cands+=("$ip")
    done < /etc/hosts
    cands+=(127.0.0.1)
  else
    cands=("$(printf '%d.%d.%d.%d' "0x${h:6:2}" "0x${h:4:2}" "0x${h:2:2}" "0x${h:0:2}")")
  fi
  for a in "${cands[@]}"; do
    [[ " ${addrs[*]-} " == *" $a "* ]] || addrs+=("$a")
  done
done < <(tail -n +2 /proc/net/udp)
if [ "${#addrs[@]}" = 0 ]; then
  echo "unhealthy: nothing is bound to UDP port $port" >&2
  exit 1
fi

ask() {  # address, a printf format of the request -> the reply's first 9 bytes, in hex
  { exec 3<>"/dev/udp/$1/$port"; } 2>/dev/null || return 0
  # shellcheck disable=SC2059   # the request is a printf format on purpose: \xHH escapes
  printf "$2" >&3
  timeout 1.5 head -c 9 <&3 | od -An -v -tx1 | tr -d ' \n'
  exec 3>&-
}

for try in 1 2; do
  for a in "${addrs[@]}"; do
    r=$(ask "$a" "$req")
    if [[ $r == ffffffff41* && ${#r} -eq 18 ]]; then
      c=${r:10:8}
      r=$(ask "$a" "$req\\x${c:0:2}\\x${c:2:2}\\x${c:4:2}\\x${c:6:2}")
    fi
    if [[ $r == ffffffff49* ]]; then
      echo "healthy: the game answered A2S_INFO on $a:$port"
      exit 0
    fi
  done
  [ "$try" = 1 ] && sleep 1
done
echo "unhealthy: a socket is bound to UDP port $port (${addrs[*]}), and no A2S_INFO reply came" >&2
exit 1
}
