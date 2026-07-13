#!/bin/bash
# set -e is deliberately NOT enabled. The SIGTERM path (term_handler) runs
# several best-effort commands that return nonzero by design - pgrep/kill with
# no matching process, wineserver -k, killing Xvfb - and `wait "$child"`
# itself returns 143 once the trap fires. Under set -e any of those would abort
# the handler partway, skipping wineserver -k and the Xvfb kill, i.e. skipping
# shutdown cleanup.
# set -u is also off: the base image's functions.sh Log() reads $3/$4 that the
# LogInfo/LogError wrappers never pass, which is fatal under nounset.
set -o pipefail
# shellcheck source=/dev/null
source /opt/scripts/functions.sh

# ADMIN_PASSWORD backs the REST API basic-auth and in-game admin; no default.
require_env ADMIN_PASSWORD

# INSTALL_DIR is the PVC mount root. The Windows build lays the game down under
# $INSTALL_DIR (PalServer.exe at the root, the real server binary under
# Pal/Binaries/Win64). WINEPREFIX also lives on the volume so the wine bottle
# survives restarts.
mkdir -p "$INSTALL_DIR"
export WINEPREFIX="${WINEPREFIX:-$INSTALL_DIR/.wine}"
export WINEDEBUG="${WINEDEBUG:--all}"
export DISPLAY="${DISPLAY:-:99}"

CONFIG_DIR="$INSTALL_DIR/Pal/Saved/Config/WindowsServer"
CONFIG_FILE="$CONFIG_DIR/PalWorldSettings.ini"
DEFAULT_CONFIG="$INSTALL_DIR/DefaultPalWorldSettings.ini"
# The Windows build's actual server process (what wine shows in the process
# table); PalServer.exe at the install root is only a launcher.
SERVER_EXE="$INSTALL_DIR/Pal/Binaries/Win64/PalServer-Win64-Shipping-Cmd.exe"
SERVER_PROC="PalServer-Win64"

#================================================================
# 1. Initialize the wine prefix on first boot.
#    mscoree/mshtml are disabled so wineboot doesn't prompt to install
#    mono/gecko; vcrun2022 is the MSVC runtime PalServer needs.
#================================================================
if [ ! -f "$WINEPREFIX/system.reg" ]; then
    LogAction "Initializing wine prefix at $WINEPREFIX"
    WINEDLLOVERRIDES="mscoree,mshtml=" wineboot --init
    wineserver -w
    LogInfo "Installing vcrun2022 into the new prefix (one-time)"
    if ! winetricks --optout -f -q vcrun2022; then
        LogWarn "winetricks vcrun2022 failed; the server may not start"
    fi
else
    LogInfo "Existing wine prefix found at $WINEPREFIX"
fi

#================================================================
# 2. Install/update the Windows server build via SteamCMD.
#    The base steamcmd_update helper does not set the platform type, so the
#    Windows depot has to be pulled by invoking steamcmd.sh directly with
#    +@sSteamCmdForcePlatformType windows BEFORE login.
#================================================================
steam_update() {
    /home/steam/steamcmd/steamcmd.sh \
        +@sSteamCmdForcePlatformType windows \
        +force_install_dir "$INSTALL_DIR" \
        +login anonymous \
        "$@" \
        +app_update "$STEAMAPPID" validate \
        +quit
}

# steamcmd sometimes fails the first pull of a platform-forced depot with
# "Missing configuration" (stale/unpopulated appinfo cache), and it can exit 0
# on failure - so success is judged by the server exe existing, not the exit
# code. Retry with the appcache cleared and an explicit appinfo refresh.
steam_update_with_retry() {
    local attempt
    for attempt in 1 2 3; do
        if [ "$attempt" -gt 1 ]; then
            LogWarn "steamcmd attempt $((attempt - 1)) did not produce $SERVER_EXE; clearing appcache and retrying"
            rm -rf /home/steam/Steam/appcache
            steam_update +app_info_update 1
        else
            steam_update
        fi
        [ -f "$SERVER_EXE" ] && return 0
    done
    LogError "steamcmd failed to install app $STEAMAPPID after 3 attempts"
    return 1
}

if [ "$SKIPUPDATE" != "true" ]; then
    LogAction "Installing/updating Palworld Windows build (app id $STEAMAPPID)"
    steam_update_with_retry
elif [ ! -f "$SERVER_EXE" ]; then
    LogWarn "SKIPUPDATE=true but the server binary is missing; installing anyway"
    steam_update_with_retry
else
    LogWarn "SKIPUPDATE=true, not updating the game"
fi

if [ ! -f "$SERVER_EXE" ]; then
    LogError "Install finished but $SERVER_EXE is missing"
    exit 1
fi

#================================================================
# 3. Seed PalWorldSettings.ini from the shipped default template.
#    Editing DefaultPalWorldSettings.ini directly has no effect; the server
#    only reads the copy under Pal/Saved/Config/WindowsServer/.
#================================================================
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_FILE" ]; then
    if [ -f "$DEFAULT_CONFIG" ]; then
        LogInfo "Seeding PalWorldSettings.ini from DefaultPalWorldSettings.ini"
        cp "$DEFAULT_CONFIG" "$CONFIG_FILE"
    else
        LogWarn "DefaultPalWorldSettings.ini not found; writing a minimal OptionSettings line"
        printf '[/Script/Pal.PalGameWorldSettings]\nOptionSettings=()\n' > "$CONFIG_FILE"
    fi
fi

#================================================================
# 4. Patch only the managed keys inside the single OptionSettings=(...) line.
#    Unmanaged keys (and any hand edits to them) are preserved: each managed
#    key is anchored to its leading ( or , delimiter and rewritten in place.
#    If a managed key is absent from the template it is injected right after
#    the opening paren so the setting still takes effect.
#================================================================
tobool() { case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in true|1|yes) echo True;; *) echo False;; esac; }

# Escape a value for the RHS of sed s/// with / as the delimiter.
sed_repl_escape() { printf '%s' "$1" | sed -e 's/[\/&\\]/\\&/g'; }

# patch_key <key> <value> <quoted|bare>
patch_key() {
    local key="$1" value="$2" mode="$3" esc
    esc="$(sed_repl_escape "$value")"
    if grep -qE "[(,]${key}=" "$CONFIG_FILE"; then
        if [ "$mode" = "quoted" ]; then
            sed -i -E "s/([(,]${key}=)\"[^\"]*\"/\1\"${esc}\"/" "$CONFIG_FILE"
        else
            sed -i -E "s/([(,]${key}=)[^,)]*/\1${esc}/" "$CONFIG_FILE"
        fi
    else
        if [ "$mode" = "quoted" ]; then
            sed -i -E "s/(OptionSettings=\()/\1${key}=\"${esc}\",/" "$CONFIG_FILE"
        else
            sed -i -E "s/(OptionSettings=\()/\1${key}=${esc},/" "$CONFIG_FILE"
        fi
    fi
}

LogAction "Applying managed PalWorldSettings keys from environment"
patch_key ServerName          "$SERVER_NAME"                       quoted
patch_key ServerDescription   "$SERVER_DESCRIPTION"                quoted
patch_key AdminPassword       "$ADMIN_PASSWORD"                    quoted
patch_key ServerPassword      "$SERVER_PASSWORD"                   quoted
patch_key PublicIP            "$PUBLIC_IP"                         quoted
patch_key PublicPort          "${PUBLIC_PORT:-$GAME_PORT}"         bare
patch_key ServerPlayerMaxNum  "$MAX_PLAYERS"                       bare
patch_key RESTAPIEnabled      "$(tobool "$RESTAPI_ENABLED")"       bare
patch_key RESTAPIPort         "$RESTAPI_PORT"                      bare
patch_key bEnableInvaderEnemy "$(tobool "$ENABLE_INVADER_ENEMY")"  bare

#================================================================
# 5. UE4SS install/upgrade (idempotent, version-marker gated).
#    The UE4SS-Palworld.zip ships dwmapi.dll (the DLL proxy the game loads)
#    plus a ue4ss/ folder at the zip root; both extract flat into
#    Pal/Binaries/Win64/ next to the server binary. Lua/script mods live
#    under ue4ss/Mods.
#================================================================
UE4SS_DIR="$INSTALL_DIR/Pal/Binaries/Win64"
UE4SS_MARKER="$UE4SS_DIR/.ue4ss-version"
UE4SS_MODS_DIR="$UE4SS_DIR/ue4ss/Mods"

install_ue4ss() {
    local url="https://github.com/Okaetsu/RE-UE4SS/releases/download/${UE4SS_VERSION}/UE4SS-Palworld.zip"
    local tmp; tmp="$(mktemp -d)"
    LogInfo "Installing UE4SS ($UE4SS_VERSION) into $UE4SS_DIR"
    if ! curl -fsSL "$url" -o "$tmp/ue4ss.zip"; then
        LogError "Failed to download UE4SS from $url"
        rm -rf "$tmp"; return 1
    fi
    if ! unzip -oq "$tmp/ue4ss.zip" -d "$UE4SS_DIR"; then
        LogError "Failed to extract UE4SS archive"
        rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
    echo "$UE4SS_VERSION" > "$UE4SS_MARKER"
    LogSuccess "UE4SS ($UE4SS_VERSION) installed"
}

if [ "$UE4SS_ENABLED" = "true" ]; then
    if [ "$UE4SS_FORCE_REINSTALL" = "true" ]; then
        LogAction "UE4SS_FORCE_REINSTALL=true: forcing re-download and re-extract of UE4SS regardless of the install marker (the fork ships a single rolling '$UE4SS_VERSION' tag; the on-volume copy will be overwritten)"
        install_ue4ss || LogError "UE4SS forced reinstall failed; continuing without it"
    elif [ ! -f "$UE4SS_MARKER" ] || [ "$(cat "$UE4SS_MARKER" 2>/dev/null)" != "$UE4SS_VERSION" ]; then
        install_ue4ss || LogError "UE4SS install failed; continuing without it"
    else
        LogInfo "UE4SS already at $UE4SS_VERSION; skipping (set UE4SS_FORCE_REINSTALL=true for one boot to refresh the rolling tag)"
    fi
else
    LogInfo "UE4SS_ENABLED != true; skipping UE4SS install"
fi

#================================================================
# 6. Declarative mod reconcile.
#    reconcile_mods <manifest> <kind> <mods_root> <entries...>
#    - pak entries: name@url, or logicmods:name@url to target LogicMods
#      instead of ~mods (both under mods_root). url may be a direct .pak or a
#      .zip.
#    - ue4ss / palschema entries: name@url where url is a zip extracted
#      directly into mods_root/<name>.
#    - every install is recorded in the manifest as "name<TAB>dir". Entries
#      dropped from the env list have their recorded dir removed. Nothing
#      outside the manifest is ever deleted, so hand-installed mods survive.
#    Shared by all three declarative lists (MODS, UE4SS_MODS, PALSCHEMA_MODS);
#    only the pak kind has ~mods/LogicMods subdirs, every other kind installs
#    flat under mods_root.
#================================================================
reconcile_mods() {
    local manifest="$1" kind="$2" mods_root="$3"; shift 3
    # The root every install for this kind must live under. The removal pass
    # refuses to rm anything that resolves outside it (legacy/corrupt manifest).
    local resolved_root
    resolved_root="$(realpath -m "$mods_root")"

    # Phase 1: parse and validate every entry BEFORE any filesystem write.
    # A name that fails validation (so it can never contain / or ..) fails the
    # whole boot loudly rather than being silently skipped.
    declare -A want=() want_url=() want_target=()
    local entry raw name url dest_root
    for entry in "$@"; do
        [ -z "$entry" ] && continue
        raw="$entry"
        dest_root="$mods_root"
        if [ "$kind" = "pak" ]; then
            dest_root="$mods_root/~mods"
            case "$raw" in
                logicmods:*) raw="${raw#logicmods:}"; dest_root="$mods_root/LogicMods";;
            esac
        fi
        if [[ "$raw" != *@* ]]; then
            LogError "[$kind] malformed entry '$entry' (expected name@url)"
            exit 1
        fi
        name="${raw%%@*}"
        url="${raw#*@}"
        if ! [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
            LogError "[$kind] illegal mod name in entry '$entry' (name must match ^[A-Za-z0-9][A-Za-z0-9._-]*\$)"
            exit 1
        fi
        if [ -n "${want[$name]+x}" ]; then
            LogWarn "[$kind] duplicate mod name '$name'; skipping the second occurrence"
            continue
        fi
        want["$name"]=1
        want_url["$name"]="$url"
        want_target["$name"]="$dest_root/$name"
    done

    # Phase 2: install wanted entries not already recorded. Manifest existence
    # is an exact field match, not a regex prefix match.
    touch "$manifest"
    local target ok tmp
    for name in "${!want[@]}"; do
        url="${want_url[$name]}"
        target="${want_target[$name]}"
        if awk -F'\t' -v n="$name" '$1 == n { found = 1 } END { exit !found }' "$manifest"; then
            LogInfo "[$kind] $name already installed; skipping"
            continue
        fi
        LogInfo "[$kind] installing $name from $url"
        tmp="$(mktemp -d)"
        mkdir -p "$target"
        ok=false
        case "$url" in
            *.zip)
                if curl -fsSL "$url" -o "$tmp/mod.zip" && unzip -oq "$tmp/mod.zip" -d "$target"; then
                    ok=true
                fi
                ;;
            *)
                if curl -fsSL "$url" -o "$target/$name.pak"; then
                    ok=true
                fi
                ;;
        esac
        rm -rf "$tmp"
        if [ "$ok" = true ]; then
            printf '%s\t%s\n' "$name" "$target" >> "$manifest"
            LogSuccess "[$kind] $name installed"
        else
            LogError "[$kind] failed to install $name"
            rm -rf "$target"
        fi
    done

    # Phase 3: remove manifest-tracked entries no longer requested. Exact-match
    # de-list, and only rm a path that resolves under this kind's mods root.
    local tmpm; tmpm="$(mktemp)"
    local m_name m_path resolved_path
    while IFS=$'\t' read -r m_name m_path; do
        [ -z "$m_name" ] && continue
        if [ -n "${want[$m_name]+x}" ]; then
            printf '%s\t%s\n' "$m_name" "$m_path" >> "$tmpm"
            continue
        fi
        if [ -z "$m_path" ]; then
            LogWarn "[$kind] manifest entry '$m_name' has no recorded path; leaving it"
            printf '%s\t%s\n' "$m_name" "$m_path" >> "$tmpm"
            continue
        fi
        resolved_path="$(realpath -m "$m_path")"
        if [ "$resolved_path" = "$resolved_root" ] || [ "${resolved_path#"$resolved_root"/}" = "$resolved_path" ]; then
            LogWarn "[$kind] manifest path for '$m_name' ($m_path) resolves outside $mods_root; refusing to remove, keeping the manifest entry"
            printf '%s\t%s\n' "$m_name" "$m_path" >> "$tmpm"
            continue
        fi
        LogInfo "[$kind] removing de-listed mod $m_name ($m_path)"
        rm -rf "$m_path"
    done < "$manifest"
    mv "$tmpm" "$manifest"
}

PAKS_ROOT="$INSTALL_DIR/Pal/Content/Paks"
# PalSchema itself arrives via UE4SS_MODS (it is a ue4ss Lua mod); its own
# sub-mods live one level deeper, under its mods/ folder.
PALSCHEMA_MODS_DIR="$UE4SS_MODS_DIR/PalSchema/mods"

LogAction "Reconciling pak mods (MODS)"
# shellcheck disable=SC2086
reconcile_mods "$INSTALL_DIR/.mods-manifest" pak "$PAKS_ROOT" $MODS

if [ "$UE4SS_ENABLED" = "true" ]; then
    LogAction "Reconciling UE4SS mods (UE4SS_MODS)"
    mkdir -p "$UE4SS_MODS_DIR"
    # shellcheck disable=SC2086
    reconcile_mods "$INSTALL_DIR/.ue4ss-mods-manifest" ue4ss "$UE4SS_MODS_DIR" $UE4SS_MODS

    # PalSchema sub-mods (PALSCHEMA_MODS), reconciled AFTER UE4SS_MODS above
    # since PalSchema itself is delivered through that list.
    if [ -n "$(printf '%s' "$PALSCHEMA_MODS" | tr -d '[:space:]')" ] && [ ! -d "$UE4SS_MODS_DIR/PalSchema" ]; then
        LogWarn "PALSCHEMA_MODS set but PalSchema is not installed under ue4ss/Mods (hint: add PalSchema to UE4SS_MODS); installing the sub-mod files anyway, they stay inert until PalSchema is present"
    fi
    LogAction "Reconciling PalSchema sub-mods (PALSCHEMA_MODS)"
    mkdir -p "$PALSCHEMA_MODS_DIR"
    # shellcheck disable=SC2086
    reconcile_mods "$INSTALL_DIR/.palschema-mods-manifest" palschema "$PALSCHEMA_MODS_DIR" $PALSCHEMA_MODS
elif [ -n "$(printf '%s' "$UE4SS_MODS$PALSCHEMA_MODS" | tr -d '[:space:]')" ]; then
    LogWarn "UE4SS_MODS/PALSCHEMA_MODS set but UE4SS_ENABLED != true; ignoring"
fi

#================================================================
# 7. Launch under wine.
#    Wine needs an X display even for a console server; a minimal Xvfb on :99
#    is enough (no xvfb-run, no wine virtual desktop). Flags per the official
#    dedicated-server docs.
#================================================================
FLAGS=(
    "-port=$GAME_PORT"
    "-queryport=$QUERY_PORT"
    "-players=$MAX_PLAYERS"
    "-logformat=text"
    "-useperfthreads"
    "-NoAsyncLoadingThread"
    "-UseMultithreadForDS"
)
[ "$PUBLIC_LOBBY" = "true" ] && FLAGS+=("-publiclobby")
[ -n "$PUBLIC_IP" ]   && FLAGS+=("-publicip=$PUBLIC_IP")
[ -n "$PUBLIC_PORT" ] && FLAGS+=("-publicport=$PUBLIC_PORT")

LogInfo "Starting Xvfb on $DISPLAY"
Xvfb "$DISPLAY" -ac -nolisten tcp -screen 0 640x480x24 &
xvfb_pid=$!

# Wait for the X display to be ready before launching wine. xdpyinfo (x11-utils)
# is not installed in this image, so poll for the X11 socket instead
# (DISPLAY :99 -> /tmp/.X11-unix/X99). ~10s timeout (50 * 0.2s).
x_socket="/tmp/.X11-unix/X${DISPLAY#:}"
x_ready=false
x_tries=0
while [ "$x_tries" -lt 50 ]; do
    if [ -S "$x_socket" ]; then
        x_ready=true
        break
    fi
    sleep 0.2
    x_tries=$((x_tries + 1))
done
if [ "$x_ready" != "true" ]; then
    LogError "Xvfb display $DISPLAY not ready after ~10s ($x_socket never appeared)"
    kill "$xvfb_pid" 2>/dev/null
    exit 1
fi
LogInfo "Xvfb display $DISPLAY ready"

child=""
# shellcheck disable=SC2317  # invoked indirectly via the SIGTERM trap
term_handler() {
    LogAction "Caught SIGTERM, stopping server"
    kill -SIGTERM "$(pgrep -f "$SERVER_PROC")" 2>/dev/null
    wait "${child:-}" 2>/dev/null
    wineserver -k 2>/dev/null
    kill "$xvfb_pid" 2>/dev/null
}
trap 'term_handler' SIGTERM

LogAction "Starting Palworld dedicated server under wine"
cd "$INSTALL_DIR" || exit 1
wine "$SERVER_EXE" "${FLAGS[@]}" &
child=$!
wait "$child"
