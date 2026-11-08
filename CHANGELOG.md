# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **The Docker Engine 29.4.2 note links GitHub's runner-image issue and its fix.** [actions/runner-images#14790](https://github.com/actions/runner-images/issues/14790) is the ubuntu-26.04 image shipping that release; [actions/runner-images#15205](https://github.com/actions/runner-images/pull/15205) moves it to 29.7.2. Documentation only.

## [1.3.4] - 2026-11-08

### Security

- **The RCON password is no longer on the server's command line.** It was passed to srcds as `+rcon_password <password>`, so it sat in its arguments for as long as the server ran, where every user on the host reads it with `ps` (`/proc/<pid>/cmdline` is world-readable, and the host sees every container's processes). The compose file now hands it to the container as an environment variable; a short entrypoint writes it with the shell's own `printf` into `cfg/secrets/rcon.cfg`, on a tmpfs so it never touches a disk, mode 600, then hands over to the image's own entrypoint, and `server.cfg` executes it with `exec secrets/rcon.cfg` on every map load. Not `+exec` on the command line, as the change first had it: Left 4 Dead 2 drops an `rcon_password` set that early, and the right password was refused (CI run 42497766414; Black Mesa's engine keeps it, Left 4 Dead 2's does not, measured side by side in tf2-server-docker-compose run 42499988775). **If you keep your own `server.cfg`, add the line `exec secrets/rcon.cfg` to it**, or RCON refuses every password. A password holding a double quote, which a Source config line cannot carry, stops the start with a message instead of being cut. CI starts the real image with a random password, reads every command line on the runner and in the container and requires it on none; RCON still answers with the password and refuses a wrong one.

### Fixed

- **CI boots the game again on GitHub's ubuntu-26.04 runner.** Since 2026-11-07 `ubuntu-latest` is that image, which ships Docker Engine 29.4.2, and that release alone answers the 32-bit `socketcall` system call with ENOSYS in its default seccomp profile ([moby/moby#52506](https://github.com/moby/moby/issues/52506)). Left 4 Dead 2's 32-bit srcds died before it opened its port and restarted, seventeen times in 150 seconds, never healthy, with Steam and the network both up. On 29.4.2, and only there, CI now gives the daemon the profile Docker 29.4.3 ships (moby/profiles seccomp v0.2.3, pinned by commit and checksum) before it starts the server; anywhere else the step does nothing. Measured on every affected template's pinned image in tf2-server-docker-compose run 42496129688.

### Changed

- **The README names Docker Engine 29.4.2.** That release alone stops this server: Left 4 Dead 2's srcds is 32-bit and makes every socket with the system call it blocks: upgrade to 29.4.3 or later, which reverted the rule, or point the daemon's `seccomp-profile` at the profile 29.4.3 ships. Ubuntu 26.04's own `docker.io` (27.5.1) never had it.
## [1.3.3] - 2026-11-01

### Changed

- **The fall-back night is shown on a neutral zone.** `tests/timers.sh` reads Berlin's fall-back on 25 October 2026; any zone with a fall-back shows the same skip, and the test still fails on a calendar without `UTC`. The README and the timer's comment no longer name the night by date and hour.
## [1.3.2] - 2026-11-01

### Fixed

- **rcon works.** The README said `docker compose -p l4d2 exec l4d2-server rcon status`; the pinned image has no rcon program (`command -v rcon` inside it is empty), so the command could only fail. `tools/rcon.sh` speaks the protocol from the server's network namespace, with python from the pinned image the Steam check already uses, since this one carries no python3, and takes the password from `.env` on stdin, never in argv. CI runs `status` against the booted server and needs the hostname line back, and a wrong password refused.
## [1.3.1] - 2026-11-01

### Changed

- **The Steam check's probe image is pinned by digest.** `tools/steam-uptodate.sh` asks A2S and Steam from a python container in the server's network namespace; 1.3.0 named it by tag, `python:3.13-alpine`, so whoever moved that tag decided what ran there. It is now `python:3.13-alpine@sha256:7984cf56…`, and `STEAM_UPTODATE_PROBE_IMAGE` still overrides it.
## [1.3.0] - 2026-11-01

### Added

- **CI asks Steam whether the booted server is current.** A2S proved the server listened; nothing asked whether anyone could join it. Steam enforces the version and answers that directly: `UpToDateCheck` takes the version the server reports. CI now fails unless Steam calls the server current, and a stale version written into `steam.inf` must turn the check red. On the machine this template comes from, Team Fortress 2 sat out of date for days while every check there was green, because none of them asked.
- **`tools/steam-uptodate.sh` and a systemd timer, asking the same question every fifteen minutes on the host.** The game is baked into this image, so the script has nothing to update: when Steam stops accepting the version the image carries, it says so once, and fails every run until a newer image arrives in a template release. A silent server or Steam decides nothing, for up to six hours. Something new also goes to `STEAM_UPTODATE_NOTIFY` when it is set. The timer is on UTC with an `OnUnitActiveSec` net (`tests/timers.sh`), the script is one brace group read whole before it runs (`tests/read-whole.sh`), and `tests/steam-uptodate.sh` drives every branch against stubbed answers, with four plants, one rule taken out each.
## [1.2.1] - 2026-10-21

### Fixed

- **The SourceMod compile check fetched its compiler from a server that no longer serves it.** AlliedModders publishes SourceMod and MetaMod:Source as GitHub releases now, and from 2026-10-21 every path under `sm.alliedmods.net/smdrop/` answers 404, so the scheduled run failed before compiling anything. CI fetches the same pinned build, 1.12.0.7253, from its GitHub release; GitHub's digest for that asset is the checksum already pinned, so the compiler is byte for byte the one CI used before. The README's download links, both dead, point to the two projects' GitHub releases.

### Changed

- **The freshness check has its own workflow, Pin Freshness.** It ran inside Deployment Verification, whose badge is the one at the top of this README. Across the fleet, nine red runs in ten were a pin one version behind - which the fleet's triage moves within the day - and a reader cannot tell that from a stack that does not boot. The badge now says whether the stack boots. The job itself is unchanged.

### Fixed

- **`update.sh` no longer stops without a word when a release adds a variable and no compose file requires one.** The search for `${VAR:?}` came back empty, and under `pipefail` that empty result ended the script with status 1 right after it listed the new variables.
- **`update.sh` stops on a `.env` it cannot read, before the checkout.** It used to fall through: every new required variable read as "not set", or, with none, the tree moved to the new tag and `docker compose up` failed on the permission. Now it names the file, its owner and mode, and changes nothing.

## [1.2.0] - 2026-09-22

### Added

- **`L4D2_SERVER_TIMEZONE`: the game gets the household clock too.** Every timestamp this server writes — a ban, a join, the crash it leaves behind — is read next to a log line from somewhere else, and two clocks turn that into arithmetic. Six of this fleet's eleven game templates already carried the setting and this one did not. It defaults to UTC, which is now a choice rather than an accident, and the image carries the whole tz database so any zone name works. Measured against the pinned image: unset gives `UTC`, set gives the zone asked for.

## [1.1.0] - 2026-09-07

### Added

- **`update.sh`: move between release tags on purpose.** It updates to the latest release (a combination this repository's CI has booted and smoke-tested), refuses to cross a major version unattended, refuses to run over local changes, and names any new required variable before anything has moved. `--dry-run` says what would happen.

`sv_allow_lobby_connect_only 0` in server.cfg;
  the game's default accepts only lobby arrivals and refuses `connect
  host:port` with nothing useful said.
- **A campaign rotation that rotates.** The file the image ships lists four
  maps from the first game under names that do not exist in this build, so
  every finale restarted the same campaign. Fourteen campaigns by their real
  first chapter, each name checked with `maps` on a running server.
- **Three SourceMod plugins, compiled in CI with a pinned compiler.**
  `l4d2_campaign_cycle` moves the group to the next campaign on `finale_win`,
  because L4D2 exposes no way to see whether the engine reads mapcycle.txt in
  co-op at all; `l4d2_join_rescue` puts a human dropped into Spectator back on
  the survivor team when the engine's own takeover does not fire;
  `l4d2_character_select` lets a player pick their survivor without turning
  `sv_cheats` on for everybody.
- **Addons and the sourcemod config directory bind-mounted from the host**,
  because the game sits in the image's writable layer and anything installed
  inside vanishes on the next recreate without a word. Only the `sourcemod`
  subdirectory of `cfg/` is mounted, so the game's own cfg files stay visible.
- **An exact-match health check** on the game binary, with
  `tests/e2e-healthcheck.sh` proving it against a real container.
- **Measured limits.** A four-player server peaked at 432 MB; the 3 GB ceiling
  exists so a leak here cannot get some other container OOM-killed in its
  place.
- **Deployment Verification CI that boots the real image**: `docker compose
  up`, a health check going green, and an A2S_INFO query answered on the
  published port. The image is 3.3 GB compressed, which a runner can hold —
  the one Source server in this family for which that is true.

[Unreleased]: https://github.com/heyvaldemar/l4d2-server-docker-compose/compare/v1.3.4...HEAD
[1.3.4]: https://github.com/heyvaldemar/l4d2-server-docker-compose/compare/v1.3.3...v1.3.4
[1.3.3]: https://github.com/heyvaldemar/l4d2-server-docker-compose/compare/v1.3.2...v1.3.3
[1.3.2]: https://github.com/heyvaldemar/l4d2-server-docker-compose/compare/v1.3.1...v1.3.2
[1.3.1]: https://github.com/heyvaldemar/l4d2-server-docker-compose/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/heyvaldemar/l4d2-server-docker-compose/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/heyvaldemar/l4d2-server-docker-compose/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/heyvaldemar/l4d2-server-docker-compose/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/l4d2-server-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/l4d2-server-docker-compose/releases/tag/v1.0.0
