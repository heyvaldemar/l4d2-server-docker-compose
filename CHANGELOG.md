# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

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

[Unreleased]: https://github.com/heyvaldemar/l4d2-server-docker-compose/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/heyvaldemar/l4d2-server-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/l4d2-server-docker-compose/releases/tag/v1.0.0
