# L4D2 server using Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/l4d2-server-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/l4d2-server-docker-compose/actions/workflows/deployment-verification.yml)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/14891/badge)](https://www.bestpractices.dev/projects/14891)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A Left 4 Dead 2 co-op server for a group of friends, pinned by digest, with a campaign rotation that actually rotates and three SourceMod plugins written for the problems a real group ran into.

```bash
git clone https://github.com/heyvaldemar/l4d2-server-docker-compose
cd l4d2-server-docker-compose
cp .env.example .env && $EDITOR .env          # an rcon password
docker compose -f l4d2-server-docker-compose.yml -p l4d2 up -d
```

The game is baked into the image, so the first start is a 3 GB pull and then a map load. Watch it:

```bash
docker compose -p l4d2 logs -f l4d2-server
docker compose -p l4d2 ps          # healthy once the game answers A2S_INFO
```

Players connect with `connect your-address:27015` from the developer console. No Steam token is needed for that; a token only matters for the public browser, and a server for friends has no reason to be in it.

## What this file knows that a fresh one does not

**Direct connect is off by default.** `sv_allow_lobby_connect_only 1` is the game's default, and with it the server accepts only clients arriving through a Steam lobby. `connect host:port` is refused with nothing useful said. server.cfg sets it to 0.

**The campaign rotation the image ships points at nothing.** Its `mapcycle.txt` lists four maps from the first game under their pre-port names — `l4d_hospital01_apartment` and friends — which do not exist in this build, so after every finale the server restarted the same campaign. The one shipped here lists all fourteen campaigns by their real first chapter, every name checked with `maps` on a running server rather than taken from memory.

**The rotation is done by a plugin, not by the engine, because nobody can see whether the engine reads that file at all.** L4D2 has no `nextlevel`, `sv_nextlevel`, `mapcyclefile` or `map_transition` command — all four answer "Unknown command" — so there is no way to verify the built-in cycle in co-op, and a rotation nobody can verify is not a rotation. `l4d2_campaign_cycle` hooks `finale_win`, an event the game definitely fires, and exposes `sm_cyclenext` so the behaviour can be tested without playing four hours to reach a finale. It matches on the campaign prefix, because the finale runs on the last chapter (`c9m2_lots`, not `c9m1_alleys`) and a whole-name comparison would never match.

**Addons live outside the container or they do not live.** The game sits in the image's writable layer, so every recreate starts from a clean copy. A SourceMod installed inside works until the next image update and then vanishes without a word. `addons/` and `cfg/sourcemod/` are bind mounts; put SourceMod and MetaMod there once.

**Only the `sourcemod` subdirectory of `cfg/` is mounted.** The game ships its own `cfg/` with `360controller.cfg`, `config_default.cfg` and the rest; mounting over the whole directory hides them and the server starts missing files it has always had.

**A human dropped into Spectator gets put back.** The engine's own bot takeover sometimes does not fire — the log says "looking for bots to take over", then "joined team Spectator", and the player sits there while three friends wait. Typing `jointeam 2` in the console fixes it, and a server should not require that of its players. `l4d2_join_rescue` does it for them, timidly: it waits so the engine gets first refusal, acts only on a human in Spectator with a survivor bot free to take over, tries twice per connection and then leaves them alone, and runs in co-op only.

**A player can choose their survivor.** The roster is fixed by the campaign and which of the four you get is the server's choice. The only vanilla route needs `sv_cheats 1`, which turns cheats on for everyone to solve one person's preference. `!char zoey` sets both the character property and the model — either alone changes the voice but not the body, or the reverse. Written rather than downloaded: a forum attachment is a binary of unknown provenance running inside the game server.

**The memory ceiling is measured, not guessed.** A four-player co-op server peaked at 432 MB; the 3 GB limit exists so a leak here cannot get some other container killed instead.

**Docker Engine 29.4.2 stops this server, and only that release does.** Its default seccomp profile answers the 32-bit `socketcall` system call with "not implemented" ([moby/moby#52506](https://github.com/moby/moby/issues/52506); for GitHub Actions, the ubuntu-26.04 runner image ships it: [actions/runner-images#14790](https://github.com/actions/runner-images/issues/14790), with the move to 29.7.2 in [actions/runner-images#15205](https://github.com/actions/runner-images/pull/15205)), and Left 4 Dead 2's srcds is a 32-bit program that makes every socket with it: the server starts, dies before it opens its port, and starts again, with nothing in its log to say why. Measured in [a CI run on GitHub's ubuntu-26.04 runner, which ships 29.4.2](https://github.com/heyvaldemar/tf2-server-docker-compose/blob/main/docs/evidence/docker-29.4.2-socketcall.md): seventeen starts in 150 seconds and never healthy on the default profile, healthy at once with the profile Docker 29.4.3 ships. 29.4.3 reverted the rule, and Ubuntu 26.04's own `docker.io` (27.5.1) never had it. Check with `docker version --format '{{.Server.Version}}'` and upgrade; until you can, point [`seccomp-profile` in `daemon.json`](https://docs.docker.com/reference/cli/dockerd/#daemon-configuration-file) at [moby/profiles seccomp v0.2.3](https://github.com/moby/profiles/blob/836ae4d37ef2ec995c77c99fc55f5b5f3af3a897/seccomp/default.json) and restart Docker.

## SourceMod

Install [MetaMod:Source](https://github.com/alliedmodders/metamod-source/releases) and [SourceMod](https://github.com/alliedmodders/sourcemod/releases) for L4D2 into `addons/` on the host, then compile the plugins in `sourcemod/scripting/` with the compiler SourceMod ships and copy the `.smx` files to `addons/sourcemod/plugins/`. CI compiles all three on every push with a pinned compiler, so a plugin that stops compiling is a red run rather than a server silently running without it.

| plugin | command | what it does |
|---|---|---|
| `l4d2_campaign_cycle` | `sm_cyclenext` (admin) | next campaign after each finale, looping forever |
| `l4d2_join_rescue` | — | a human stuck in Spectator is put on the survivor team |
| `l4d2_character_select` | `!char <name>`, `!chars`, `sm_setchar <player> <name>` (admin) | choose your survivor without `sv_cheats` |

## Hiding your home address

If you run this at home and want nothing listening on your router, put the game container in the network namespace of a WireGuard sidecar that dials out to a cheap relay. That pattern, including the local door so players in your own house do not travel to another country and back — measured at 90 ms of ping to the next room on this very game — is [game-server-wireguard-relay-docker-compose](https://github.com/heyvaldemar/game-server-wireguard-relay-docker-compose).

## Administration

```bash
# rcon, using the password from .env
tools/rcon.sh status
tools/rcon.sh changelevel c2m1_highway
tools/rcon.sh sm_cyclenext
```

Up to v1.3 this said `docker compose -p l4d2 exec l4d2-server rcon status`. The image has no rcon program, so that command could only fail. `tools/rcon.sh` speaks the rcon protocol from the server's network namespace, with python from the same pinned image the Steam check uses (this image carries none), takes the password from `.env` on stdin rather than the command line where `ps` would show it, and CI checks `status` against the real server and a wrong password refused.

## Keeping the game current

**The health check asks the game, not its process.** `tools/healthcheck.sh` sends A2S_INFO, the query every server browser sends, to the game port and is healthy only on the engine's reply. Up to v1.3.4 it looked for `srcds_linux` in `/proc`: a hung or stopped game keeps its process, and on Docker Engine 29.4.2 Black Mesa's 32-bit server, built like this one, ran with no socket at all and stayed healthy. The log is not read either. A map change silences it for seconds; one check tries twice, and Docker allows three misses at a 60-second interval. Each check ends within 7 seconds. **It asks from inside the container**, at the address it answers on (the one it is bound to, or the container's own when it binds 0.0.0.0, as Left 4 Dead 2 does): healthy proves the server answers there, not that the port is published on the host or open in your firewall. Check that from outside, with a server browser or `tools/steam-uptodate.sh --check`.

**A healthy server is not a joinable one.** On the machine this template comes from, Team Fortress 2 ran out of date for days in October 2026 while every check passed: the container was healthy, A2S answered, Steam listed the server, and the image watchers had nothing to say because the image had not changed. Players on the current client cannot join a server Steam calls out of date. Steam answers that question directly: `ISteamApps/UpToDateCheck` takes the version a server reports over A2S and says whether it is still accepted. `tools/steam-uptodate.sh` asks it every fifteen minutes. In this template the game is baked into the image, so there is nothing for the script to update: when Steam stops accepting the version the image carries, it says so once, and fails on every run after that, so the timer shows up in `systemctl --failed` until a newer image arrives in a template release and `./update.sh` takes it. The image has not needed one in the server's lifetime; this is how its reader would find out the day it does. A server that does not answer, or a Steam that does not, decides nothing, for up to six hours (`STEAM_UPTODATE_SILENCE`).

"Says so" is one line in the journal every run, and, when `STEAM_UPTODATE_NOTIFY` is set, a message on its stdin the first time something new happens: a webhook, mail, anything that reads stdin. The service file has an example.

```bash
# edit the two paths in the service file to where this repository is checked out
sudo cp systemd/steam-uptodate.service systemd/steam-uptodate.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now steam-uptodate.timer
tools/steam-uptodate.sh --check      # what Steam says right now
```

**The timer runs on UTC, with a net under it.** The night the clocks went back an hour, the server this template comes from ran none of its local-time timers for that hour: systemd reads a local calendar in wall-clock time and took the repeated hour as already gone. A calendar in UTC has no repeated hour, and `OnUnitActiveSec=16min` makes up a run missed for any other reason. `tests/timers.sh` checks both with `systemd-analyze` from one second before a fall-back (Berlin's, on 25 October 2026). The script is one brace group read whole before it runs, so an edit to its file mid-run cannot change what the run does (`tests/read-whole.sh`).

## Updating

The pin lives in the `x-images` block at the top of the compose file, as an interpolation default, so a `git pull` delivers the image this repository has tested. The tag is `master` because upstream publishes no version numbers: the digest is the version. When Valve ships an update the image is rebuilt, the daily freshness check goes red, and the pin moves deliberately. `./update.sh` does that on purpose: it moves to the latest release tag, refuses to cross a major unattended, and names any new required variable before anything has moved.

## Testing

CI boots this one for real. The image is small enough for a runner: `docker compose up` with placeholder secrets, wait for the health check, then an A2S_INFO query on the published port from inside the container's namespace — the reply must carry the `0x49` header, which proves srcds is listening where the file says it binds, not merely alive. The health check itself runs in the pinned image against a stand-in (answers, answers after a challenge, silent, no socket), then on the real server across a map change, and with the game process stopped by SIGSTOP it must go red while the old `/proc` check stays green. Then it asks Steam, with `tools/steam-uptodate.sh --check`, whether the version the server reports is current, and fails unless it is. The plant: the version before the current one written into `steam.inf`, which the check must call out of date and the timer's script must report as needing a newer image. `tests/steam-uptodate.sh` drives every branch of the script against stubbed answers, with four plants, one rule taken out each; `tests/read-whole.sh` and `tests/timers.sh` check the script and its timer. The three plugins are compiled with a pinned SourceMod compiler. `tests/e2e-healthcheck.sh` runs the health check in both directions against a fixture with no game download. All of it on every push, alongside shell and workflow linting, a Trivy scan of the pinned image, and a daily check that the pin still resolves to what upstream publishes.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · CNCF Ambassador · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
