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
                    case "$kind" in
                        ue4ss|palschema) strip_zip_wrapper "$target" ;;
                    esac
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
