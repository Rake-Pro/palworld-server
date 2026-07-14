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
