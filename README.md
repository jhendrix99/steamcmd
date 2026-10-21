# steamcmd

SteamCMD runtime images for HXSHost game servers (Caelum/Wings).

| Image | Built from |
|---|---|
| `ghcr.io/jhendrix99/steamcmd:debian` | `ghcr.io/parkervcp/steamcmd:debian` |
| `ghcr.io/jhendrix99/steamcmd:proton` | `ghcr.io/parkervcp/steamcmd:proton` |

The only change from the base images is `/entrypoint.sh`. Upstream runs SteamCMD
unbounded before the server starts, so a client stuck updating itself holds the
server offline indefinitely, and nothing in the egg can intervene because the
entrypoint runs before the startup command. This one:

- replaces a missing or broken client with a freshly downloaded, verified one
- puts a time limit on every SteamCMD run
- starts the server on its existing files when the update cannot run

It reads the same variables as upstream (`AUTO_UPDATE`, `SRCDS_APPID`,
`STEAM_USER`, `STEAM_PASS`, `STEAM_AUTH`, `SRCDS_BETAID`, `SRCDS_BETAPASS`,
`HLDS_GAME`, `INSTALL_FLAGS`, `WINDOWS_INSTALL`, `VALIDATE`), so switching an egg
is a change of image owner and nothing else. `VALIDATE` accepts `true` as well as
`1`. Optional: `HXS_STEAMCMD_PROBE_TIMEOUT` (default 300s), `HXS_STEAMCMD_BOOTSTRAP_TIMEOUT`
(default 900s, the first run of a freshly downloaded client) and
`HXS_STEAMCMD_UPDATE_TIMEOUT` (default 10800s).

Only `./steamcmd` is ever deleted during a repair. `Steam/` holds the saved login
for servers on a real Steam account, so it is never touched.

Built and pushed by GitHub Actions on every push to `main` and weekly, after a
smoke test.
