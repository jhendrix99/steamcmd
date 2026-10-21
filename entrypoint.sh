#!/bin/bash
#
# HXSHost SteamCMD runtime entrypoint.
#
# Drop-in replacement for the entrypoint in ghcr.io/parkervcp/steamcmd (debian
# and proton). Everything except the SteamCMD update matches upstream, and the
# update reads the same variables, so an egg can switch images without any
# other change. Upstream's original is MIT licensed:
# Copyright (c) 2021 Matthew Penner and contributors.
#
# What changed is the update step. Upstream runs SteamCMD unbounded before the
# server starts, so a client that cannot finish updating itself (it relaunches
# "by request" forever, or segfaults, or arrives truncated) holds the server
# offline indefinitely and nothing in the egg can intervene, because this runs
# before the startup command. Here:
#
#   - a missing or broken client is replaced with a freshly downloaded,
#     verified one
#   - every SteamCMD run has a time limit, so a loop costs minutes, not the day
#   - if the update still cannot run, the server starts on the files it has,
#     which is what a customer wants far more than a server that never starts
#
# Only ./steamcmd is ever deleted. Steam/ is left alone because it holds the
# saved login for servers that use a real Steam account, and wiping it would
# trigger Steam Guard on every repair.

# Wait for the container to fully initialize
sleep 1

# Default the TZ environment variable to UTC.
TZ=${TZ:-UTC}
export TZ

# Set environment variable that holds the Internal Docker IP
INTERNAL_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
export INTERNAL_IP

# Set environment for Steam Proton
if [ -f "/usr/local/bin/proton" ]; then
    if [ ! -z ${SRCDS_APPID} ]; then
        mkdir -p /home/container/.steam/steam/steamapps/compatdata/${SRCDS_APPID}
        export STEAM_COMPAT_CLIENT_INSTALL_PATH="/home/container/.steam/steam"
        export STEAM_COMPAT_DATA_PATH="/home/container/.steam/steam/steamapps/compatdata/${SRCDS_APPID}"
        # Fix for pipx with protontricks
        export PATH=$PATH:/root/.local/bin
    else
        echo -e "----------------------------------------------------------------------------------"
        echo -e "WARNING!!! Proton needs variable SRCDS_APPID, else it will not work. Please add it"
        echo -e "Server stops now"
        echo -e "----------------------------------------------------------------------------------"
        exit 1
    fi
fi

# Switch to the container's working directory
cd /home/container || exit 1

# Overridable only so the tests can serve a deliberately truncated download.
STEAMCMD_URL="${HXS_STEAMCMD_URL:-https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz}"
# An installed, healthy client answers +quit quickly, even with an update pending.
PROBE_TIMEOUT=${HXS_STEAMCMD_PROBE_TIMEOUT:-300}
# A freshly downloaded client updates itself on its first run (tens of MB), so
# it gets longer. Probing it with the short limit kills it mid-bootstrap, and
# on a slow link that would condemn every fresh client as broken.
BOOTSTRAP_TIMEOUT=${HXS_STEAMCMD_BOOTSTRAP_TIMEOUT:-900}
# Game updates are deltas here (the egg's installer does first installs), so
# this is generous, but finite.
UPDATE_TIMEOUT=${HXS_STEAMCMD_UPDATE_TIMEOUT:-10800}

steam_say() { echo -e "[steam] $*"; }

steamcmd_present() { [ -x ./steamcmd/steamcmd.sh ] && [ -s ./steamcmd/linux32/steamcmd ]; }

# Runs the client once and reports whether it came up. $1 is the time limit.
#
# A healthy client asks to be relaunched once while it updates itself. One that
# cannot persist its update asks over and over, so three requests is a loop and
# it is stopped then, rather than leaving the console silent for the whole limit
# (which looks hung, and gets restarted, which starts the wait over).
#
# The client is always stopped by signalling the timeout wrapper, never the
# client: timeout takes its whole process tree with it, while killing
# steamcmd.sh alone orphans the real binary, which would then keep running
# beside the game server.
steamcmd_starts() {
    local limit=$1 log pid waited=0 restarts rc
    log=$(mktemp) || return 1
    timeout "$limit" ./steamcmd/steamcmd.sh +quit >"$log" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 2
        waited=$((waited + 2))
        restarts=$(grep -c 'Restarting steamcmd by request' "$log" 2>/dev/null)
        if [ "${restarts:-0}" -ge 3 ]; then
            steam_say "  SteamCMD keeps relaunching itself without finishing its own update."
            kill -TERM "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            rm -f "$log"
            return 1
        fi
        if [ $((waited % 30)) -eq 0 ]; then
            steam_say "  still waiting on SteamCMD (${waited}s of ${limit}s)..."
        fi
    done
    wait "$pid"
    rc=$?
    if [ "$rc" -eq 124 ]; then
        steam_say "  SteamCMD did not finish starting within ${limit}s."
    elif [ "$rc" -ne 0 ]; then
        steam_say "  SteamCMD exited with code $rc."
    fi
    rm -f "$log"
    return "$rc"
}

# Replaces ./steamcmd with a fresh client. The archive is tested before it is
# extracted, because a transfer cut short still "succeeds" and leaves a client
# that segfaults on launch.
steamcmd_fetch() {
    local tmp
    tmp=$(mktemp) || return 1
    if ! curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 --max-time 300 -o "$tmp" "$STEAMCMD_URL"; then
        steam_say "  download failed."
        rm -f "$tmp"
        return 1
    fi
    if ! gzip -t "$tmp" 2>/dev/null; then
        steam_say "  download was cut short ($(stat -c%s "$tmp" 2>/dev/null) bytes), discarding it."
        rm -f "$tmp"
        return 1
    fi
    rm -rf ./steamcmd
    mkdir -p ./steamcmd
    if ! tar -xzf "$tmp" -C ./steamcmd --no-same-owner; then
        steam_say "  extraction failed."
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    steamcmd_present
}

# A usable client, or a non-zero return. Tries the one on disk first.
steamcmd_ready() {
    steam_say "Checking the SteamCMD client..."
    if steamcmd_present && steamcmd_starts "$PROBE_TIMEOUT"; then
        return 0
    fi
    steam_say "SteamCMD is missing or will not start. Installing a fresh copy."
    local n
    for n in 1 2; do
        steam_say "  downloading SteamCMD (attempt $n of 2)..."
        if steamcmd_fetch && steamcmd_starts "$BOOTSTRAP_TIMEOUT"; then
            steam_say "SteamCMD is working again."
            return 0
        fi
        steam_say "  attempt $n of 2 did not produce a working client."
        sleep 5
    done
    return 1
}

## Update server via SteamCMD if AUTO_UPDATE is 1 or not set
if [ -z ${AUTO_UPDATE} ] || [ "${AUTO_UPDATE}" == "1" ]; then
    echo -e "Checking for game server updates..."
    # Check for set App ID
    if [ ! -z ${SRCDS_APPID} ]; then
        # Set default credentials if they are missing
        if [ "${STEAM_USER}" == "" ]; then
            echo -e "Steam user is not set. Defaulting to anonymous user."
            STEAM_USER=anonymous
            STEAM_PASS=""
            STEAM_AUTH=""
        fi

        # Upstream only ever honoured "1", while several eggs document "true".
        VALIDATE_FLAG=""
        case "${VALIDATE}" in
            1|true|TRUE|True) VALIDATE_FLAG="validate" ;;
        esac

        if steamcmd_ready; then
            timeout "$UPDATE_TIMEOUT" ./steamcmd/steamcmd.sh +force_install_dir /home/container +login ${STEAM_USER} ${STEAM_PASS} ${STEAM_AUTH} $( [[ "${WINDOWS_INSTALL}" == "1" ]] && printf %s '+@sSteamCmdForcePlatformType windows' ) +app_update 1007 +app_update ${SRCDS_APPID} $( [[ -z ${SRCDS_BETAID} ]] || printf %s "-beta ${SRCDS_BETAID}" ) $( [[ -z ${SRCDS_BETAPASS} ]] || printf %s "-betapassword ${SRCDS_BETAPASS}" ) $( [[ -z ${HLDS_GAME} ]] || printf %s "+app_set_config 90 mod ${HLDS_GAME}" ) ${INSTALL_FLAGS} ${VALIDATE_FLAG} +quit
            rc=$?
            if [ $rc -eq 124 ]; then
                steam_say "The update did not finish within $((UPDATE_TIMEOUT / 60)) minutes. Starting with the existing server files."
            elif [ $rc -ne 0 ]; then
                steam_say "The update exited with code $rc. Starting with the existing server files."
            fi
        else
            steam_say "SteamCMD could not be made to work on this boot. Starting with the existing server files."
            steam_say "If this keeps happening, the machine's connection to Steam is the likely cause."
        fi
    else
        echo -e "No App ID set! Skipping check."
    fi
else
    echo -e "Skipping game server update check; Auto Update is set to 0."
fi

# Replace Startup Variables
MODIFIED_STARTUP=$(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g')

# Run the Server
echo -e "Starting server..."
echo -e ":/home/container$ ${MODIFIED_STARTUP}"
eval ${MODIFIED_STARTUP}
