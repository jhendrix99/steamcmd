#!/bin/bash
# Exercises the entrypoint through the built image, as the container user, the
# way Wings runs it. Needs Docker and network access to Steam.
#   docker build --build-arg BASE=ghcr.io/parkervcp/steamcmd:debian -t steamcmd-test:debian .
#   docker build --build-arg BASE=ghcr.io/parkervcp/steamcmd:proton -t steamcmd-test:proton .
#   bash test/run.sh
set -u
W=$(mktemp -d)
PASS=0; FAIL=0
ok()   { echo "    ok   $*"; PASS=$((PASS+1)); }
bad()  { echo "    FAIL $*"; FAIL=$((FAIL+1)); }

fresh() {
  rm -rf "$W/v"; mkdir -p "$W/v/Steam/config"
  # A file SteamCMD does not own, standing in for a saved Steam login.
  echo keep > "$W/v/Steam/config/hxs_marker"
  echo keep > "$W/v/server_save.dat"
  # Run as the "server": any SteamCMD still alive at this point was orphaned.
  cat > "$W/v/strays.sh" <<'S'
n=0; for f in /proc/[0-9]*/cmdline; do c=$(tr '\0' ' ' < "$f" 2>/dev/null); case "$c" in *steamcmd*) n=$((n+1));; esac; done; echo "STRAYS=$n"
S
  chown -R 1000:1000 "$W/v"
}
stub() {
  mkdir -p "$W/v/steamcmd/linux32"; echo x > "$W/v/steamcmd/linux32/steamcmd"
  printf '#!/bin/bash\n%s\n' "$1" > "$W/v/steamcmd/steamcmd.sh"
  chmod +x "$W/v/steamcmd/steamcmd.sh"; chown -R 1000:1000 "$W/v"
}
# $1 image, rest docker args
run() { local img=$1; shift; timeout 900 docker run --rm -v "$W/v":/home/container "$@" "$img" 2>&1; }
started()  { grep -q SERVER_STARTED <<<"$1" && ok "server started" || bad "server did not start"; }
kept()     { [ -s "$W/v/Steam/config/hxs_marker" ] && [ -s "$W/v/server_save.dat" ] && ok "Steam/ and server files untouched" || bad "Steam/ or server files were deleted"; }
has()      { grep -qF -- "$2" <<<"$1" && ok "$3" || bad "$3 (missing: $2)"; }
hasnt()    { grep -qF -- "$2" <<<"$1" && bad "$3 (unexpected: $2)" || ok "$3"; }
E=(-e SRCDS_APPID=1007 -e STARTUP='bash strays.sh; echo SERVER_STARTED')
nostray() { grep -q "STRAYS=0" <<<"$1" && ok "no SteamCMD left running beside the server" || bad "orphaned SteamCMD: $(grep -o 'STRAYS=[0-9]*' <<<"$1")"; }

echo "1. AUTO_UPDATE=0 runs the startup and nothing else"
for f in debian proton; do
  fresh; o=$(run steamcmd-test:$f "${E[@]}" -e AUTO_UPDATE=0)
  started "$o"; kept; hasnt "$o" "[steam]" "$f: no SteamCMD activity"
done

echo "2. empty volume: installs a client, updates, starts"
fresh; o=$(run steamcmd-test:debian "${E[@]}" -e AUTO_UPDATE=1)
started "$o"; kept; has "$o" "Success! App '1007'" "real update ran"

echo "3. second boot on that healthy volume takes the fast path"
s=$(date +%s); o=$(run steamcmd-test:debian "${E[@]}" -e AUTO_UPDATE=1); t=$(( $(date +%s)-s ))
started "$o"; hasnt "$o" "Installing a fresh copy" "no repair on a healthy client"; echo "         (${t}s)"

echo "4. client stuck relaunching itself: replaced, update runs"
fresh; stub 'echo "Restarting steamcmd by request..."; sleep 9999'
s=$(date +%s); o=$(run steamcmd-test:debian "${E[@]}" -e AUTO_UPDATE=1 -e HXS_STEAMCMD_PROBE_TIMEOUT=15); t=$(( $(date +%s)-s ))
started "$o"; kept; has "$o" "SteamCMD is working again" "loop detected and client replaced"; has "$o" "Success! App '1007'" "update ran after repair"; echo "         (${t}s)"

echo "5. client that segfaults: replaced"
fresh; stub 'exit 139'
o=$(run steamcmd-test:debian "${E[@]}" -e AUTO_UPDATE=1)
started "$o"; kept; has "$o" "SteamCMD is working again" "segfaulting client replaced"

echo "6. stuck client and no network: gives up within bounds and starts anyway"
fresh; stub 'sleep 9999'
s=$(date +%s); o=$(run steamcmd-test:debian "${E[@]}" --network none -e AUTO_UPDATE=1 -e HXS_STEAMCMD_PROBE_TIMEOUT=10); t=$(( $(date +%s)-s ))
started "$o"; kept; has "$o" "Starting with the existing server files" "fell back to existing files"
[ "$t" -lt 120 ] && ok "bounded (${t}s)" || bad "took ${t}s"

echo "7. truncated client download is rejected, not extracted"
fresh
curl -fsSL -o "$W/full.tgz" https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
head -c 1500000 "$W/full.tgz" > "$W/steamcmd_linux.tar.gz"
docker network create hxs-steamtest >/dev/null 2>&1
docker run -d --rm --name hxs-steamtest-web --network hxs-steamtest -v "$W":/srv:ro -w /srv python:3-alpine python -m http.server 8000 >/dev/null
sleep 2
o=$(run steamcmd-test:debian "${E[@]}" --network hxs-steamtest -e AUTO_UPDATE=1 -e HXS_STEAMCMD_URL=http://hxs-steamtest-web:8000/steamcmd_linux.tar.gz)
docker rm -f hxs-steamtest-web >/dev/null 2>&1; docker network rm hxs-steamtest >/dev/null 2>&1
started "$o"; kept; has "$o" "download was cut short" "truncation caught"
[ ! -e "$W/v/steamcmd/steamcmd.sh" ] && ok "nothing extracted from the bad archive" || bad "bad archive was extracted"

echo "8. update that hangs: bounded, server still starts"
fresh; stub 'if [ "$1" = "+quit" ]; then exit 0; fi; sleep 9999'
o=$(run steamcmd-test:debian "${E[@]}" -e AUTO_UPDATE=1 -e HXS_STEAMCMD_UPDATE_TIMEOUT=10)
started "$o"; has "$o" "did not finish within" "hung update cut off"

echo "9. update that fails: server still starts"
fresh; stub 'if [ "$1" = "+quit" ]; then exit 0; fi; exit 8'
o=$(run steamcmd-test:debian "${E[@]}" -e AUTO_UPDATE=1)
started "$o"; has "$o" "exited with code 8" "failure reported"

echo "9b. production's loop (relaunch requests, default limits): caught by behaviour, fast"
fresh; stub 'while true; do echo "steamcmd.sh[17]: Restarting steamcmd by request..."; sleep 3; done'
s=$(date +%s); o=$(run steamcmd-test:debian "${E[@]}" -e AUTO_UPDATE=1); t=$(( $(date +%s)-s ))
started "$o"; kept; nostray "$o"; has "$o" "keeps relaunching itself" "loop recognised by its relaunch requests"
has "$o" "SteamCMD is working again" "client replaced"
[ "$t" -lt 120 ] && ok "recovered in ${t}s with the default 300s limit untouched" || bad "took ${t}s"

echo "9c. a slow client never leaves the console silent"
fresh; stub 'if [ "$1" = "+quit" ]; then sleep 70; exit 0; fi; echo updated'
o=$(run steamcmd-test:debian "${E[@]}" -e AUTO_UPDATE=1)
started "$o"; has "$o" "still waiting on SteamCMD (30s" "progress at 30s"; has "$o" "still waiting on SteamCMD (60s" "progress at 60s"
hasnt "$o" "Installing a fresh copy" "slow but healthy client was not condemned"

echo "10. same SteamCMD arguments as upstream for every variable combination"
ARGSTUB='if [ "$1" = "+quit" ]; then exit 0; fi; echo "ARGS: $*"'
combos=(
  ""
  "-e STEAM_USER=hxsuser -e STEAM_PASS=hxspass -e STEAM_AUTH=ABC12"
  "-e SRCDS_BETAID=experimental -e SRCDS_BETAPASS=secret"
  "-e WINDOWS_INSTALL=1"
  "-e HLDS_GAME=cstrike"
  "-e INSTALL_FLAGS=-validate_custom"
  "-e VALIDATE=1"
)
for c in "${combos[@]}"; do
  fresh; stub "$ARGSTUB"; up=$(run upstream-test:debian "${E[@]}" -e AUTO_UPDATE=1 $c | grep '^ARGS:')
  fresh; stub "$ARGSTUB"; me=$(run steamcmd-test:debian "${E[@]}" -e AUTO_UPDATE=1 $c | grep '^ARGS:')
  [ -n "$up" ] && [ "$up" = "$me" ] && ok "identical: ${c:-defaults}" || { bad "differs: ${c:-defaults}"; echo "      up: $up"; echo "      me: $me"; }
done

echo "11. VALIDATE=true now validates (upstream ignored it)"
fresh; stub "$ARGSTUB"; o=$(run steamcmd-test:debian "${E[@]}" -e AUTO_UPDATE=1 -e VALIDATE=true)
has "$o" " validate +quit" "validate passed to SteamCMD"

echo "12. startup {{VAR}} substitution matches upstream"
for img in upstream-test:debian steamcmd-test:debian; do
  fresh; r=$(run $img -e AUTO_UPDATE=0 -e SRCDS_APPID=1007 -e SERVER_PORT=2302 -e STARTUP='echo PORT={{SERVER_PORT}} APP={{SRCDS_APPID}}' | grep '^PORT=')
  eval "out_${img%%-*}=\"\$r\""
done
[ "$out_upstream" = "$out_steamcmd" ] && [ -n "$out_steamcmd" ] && ok "same expansion: $out_steamcmd" || bad "upstream '$out_upstream' vs ours '$out_steamcmd'"

echo "13. proton: real update and the compat data path"
fresh; o=$(run steamcmd-test:proton "${E[@]}" -e AUTO_UPDATE=1)
started "$o"; kept; has "$o" "Success! App '1007'" "update ran on proton"
[ -d "$W/v/.steam/steam/steamapps/compatdata/1007" ] && ok "compatdata created" || bad "compatdata missing"

echo "14. proton without SRCDS_APPID still refuses, like upstream"
fresh; o=$(run steamcmd-test:proton -e STARTUP='echo SERVER_STARTED' -e AUTO_UPDATE=0)
has "$o" "Proton needs variable SRCDS_APPID" "refused"; hasnt "$o" "SERVER_STARTED" "did not start"

rm -rf "$W"
echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
