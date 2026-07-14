start_log_tail() {
    local prefix="$1" path="$2"
    tail -F -n0 "$path" 2>/dev/null > >(sed -u "s/^/[${prefix}] /") &
    tail_pids+=("$!")
}

child=""
# shellcheck disable=SC2317  # invoked indirectly via the SIGTERM trap
term_handler() {
    LogAction "Caught SIGTERM, stopping server"
    kill -SIGTERM "$(pgrep -f "$SERVER_PROC")" 2>/dev/null
    wait "${child:-}" 2>/dev/null
    wineserver -k 2>/dev/null
    kill "$xvfb_pid" 2>/dev/null
    local tail_pid
    for tail_pid in "${tail_pids[@]}"; do
        kill "$tail_pid" 2>/dev/null
    done
}
