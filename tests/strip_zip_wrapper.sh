strip_zip_wrapper() {
    local target="$1"

    # Junk extraction artifacts never count toward "exactly one entry" and
    # are removed either way.
    find "$target" -mindepth 1 -maxdepth 1 \( -name '__MACOSX' -o -name '.DS_Store' \) -exec rm -rf -- {} +

    local entries=() entry
    while IFS= read -r -d '' entry; do
        entries+=("$entry")
    done < <(find "$target" -mindepth 1 -maxdepth 1 -print0)

    [ "${#entries[@]}" -eq 1 ] || return 0
    local only="${entries[0]}"
    # A symlink is never treated as the wrapper, even if it points at a
    # directory: "moving its contents" would mean following it outside
    # $target, which is exactly what must not happen.
    [ -L "$only" ] && return 0
    [ -d "$only" ] || return 0

    LogInfo "Stripping single wrapper directory '$(basename "$only")' from $target"
    find "$only" -mindepth 1 -maxdepth 1 -exec mv -- {} "$target"/ \;
    rmdir "$only"
}
