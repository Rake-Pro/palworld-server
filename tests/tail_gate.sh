if [ "$TAIL_GAME_LOGS" = "true" ]; then
    LogInfo "Tailing game/mod logs into stdout (TAIL_GAME_LOGS=true)"
    start_log_tail ue4ss "$UE4SS_DIR/ue4ss/UE4SS.log"
    start_log_tail pal   "$INSTALL_DIR/Pal/Saved/Logs/PalServer.log"
else
    LogInfo "TAIL_GAME_LOGS != true; not tailing game/mod logs"
fi
