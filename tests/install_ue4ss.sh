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
