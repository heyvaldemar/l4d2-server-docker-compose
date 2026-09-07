# L4D2 server using Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/l4d2-server-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/l4d2-server-docker-compose/actions/workflows/deployment-verification.yml)
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
docker compose -p l4d2 ps          # healthy once srcds is up
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

## SourceMod

Install [MetaMod:Source](https://www.sourcemm.net/downloads.php) and [SourceMod](https://www.sourcemod.net/downloads.php) for L4D2 into `addons/` on the host, then compile the plugins in `sourcemod/scripting/` with the compiler SourceMod ships and copy the `.smx` files to `addons/sourcemod/plugins/`. CI compiles all three on every push with a pinned compiler, so a plugin that stops compiling is a red run rather than a server silently running without it.

| plugin | command | what it does |
|---|---|---|
| `l4d2_campaign_cycle` | `sm_cyclenext` (admin) | next campaign after each finale, looping forever |
| `l4d2_join_rescue` | — | a human stuck in Spectator is put on the survivor team |
| `l4d2_character_select` | `!char <name>`, `!chars`, `sm_setchar <player> <name>` (admin) | choose your survivor without `sv_cheats` |

## Hiding your home address

If you run this at home and want nothing listening on your router, put the game container in the network namespace of a WireGuard sidecar that dials out to a cheap relay. That pattern, including the local door so players in your own house do not travel to another country and back — measured at 90 ms of ping to the next room on this very game — is [game-server-wireguard-relay-docker-compose](https://github.com/heyvaldemar/game-server-wireguard-relay-docker-compose).

## Administration

```bash
docker compose -p l4d2 exec l4d2-server rcon status
docker compose -p l4d2 exec l4d2-server rcon changelevel c2m1_highway
docker compose -p l4d2 exec l4d2-server rcon sm_cyclenext
```

## Updating

The pin lives in the `x-images` block at the top of the compose file, as an interpolation default, so a `git pull` delivers the image this repository has tested. The tag is `master` because upstream publishes no version numbers: the digest is the version. When Valve ships an update the image is rebuilt, the daily freshness check goes red, and the pin moves deliberately.

## Testing

CI boots this one for real. The image is small enough for a runner: `docker compose up` with placeholder secrets, wait for the health check, then an A2S_INFO query on the published port from inside the container's namespace — the reply must carry the `0x49` header, which proves srcds is listening where the file says it binds, not merely alive. The three plugins are compiled with a pinned SourceMod compiler. `tests/e2e-healthcheck.sh` runs the health check in both directions against a fixture with no game download. All of it on every push, alongside shell and workflow linting, a Trivy scan of the pinned image, and a daily check that the pin still resolves to what upstream publishes.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
