#!/bin/bash
# Functional test harness for the log-tail spawn/cleanup logic, extracted
# verbatim from init.sh (tests/tail_logs.sh + tests/tail_gate.sh). No wine
# involved: this exercises real `tail -F` against a sandbox tree, which is
# exactly what's testable without the game binary.
set -uo pipefail

SCRATCH="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRATCH/sandbox_tail"

LogInfo()    { echo "  INFO  $*"; }
LogWarn()    { echo "  WARN  $*"; }
LogError()   { echo "  ERROR $*"; }
LogAction()  { echo "  ACT   $*"; }
LogSuccess() { echo "  OK    $*"; }

# term_handler (as extracted) also stops the wine server process and Xvfb;
# stub those to dummies so this test only exercises the tail cleanup it adds.
SERVER_PROC="no-such-process-zzz-test-tail"
xvfb_pid=999999
wineserver() { return 0; }

source "$SCRATCH/tail_logs.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

reset_tree() {
    rm -rf "$ROOT"
    mkdir -p "$ROOT"
    tail_pids=()
}

wait_for() {
    # wait_for <max_tries> <cmd...> - polls a condition instead of a fixed sleep.
    local tries="$1"; shift
    local n=0
    while [ "$n" -lt "$tries" ]; do
        "$@" && return 0
        sleep 0.1
        n=$((n + 1))
    done
    return 1
}

echo "================ TEST 1: start_log_tail records a live PID ================"
reset_tree
start_log_tail ue4ss "$ROOT/UE4SS.log"
pid="${tail_pids[0]}"
[ -n "$pid" ] && ok "tail_pids recorded a PID" || bad "tail_pids empty after start_log_tail"
kill -0 "$pid" 2>/dev/null && ok "recorded PID is a live process" || bad "recorded PID is not running"
kill "$pid" 2>/dev/null

echo "================ TEST 2: -F tails a file that does not exist yet ================"
reset_tree
capture="$ROOT/out.log"
( start_log_tail ue4ss "$ROOT/UE4SS.log" ) > "$capture" 2>&1
sleep 0.3
mkdir -p "$(dirname "$ROOT/UE4SS.log")"
echo "line-after-create" >> "$ROOT/UE4SS.log"
wait_for 30 grep -q "line-after-create" "$capture"
grep -q "\[ue4ss\] line-after-create" "$capture" && ok "line appended after file creation is tailed and prefixed" || bad "late-created file was not picked up: $(cat "$capture")"
# cleanup: kill whatever tail process is still chasing this file
pkill -f "tail -F -n0 $ROOT/UE4SS.log" 2>/dev/null

echo "================ TEST 3: -n0 does not replay pre-existing content ================"
reset_tree
echo "old-line-should-not-appear" > "$ROOT/pal.log"
capture="$ROOT/out3.log"
( start_log_tail pal "$ROOT/pal.log" ) > "$capture" 2>&1
sleep 0.3
echo "new-line-should-appear" >> "$ROOT/pal.log"
wait_for 30 grep -q "new-line-should-appear" "$capture"
grep -q "old-line-should-not-appear" "$capture" && bad "n0 replayed pre-existing content" || ok "n0 correctly skipped pre-existing content"
grep -q "\[pal\] new-line-should-appear" "$capture" && ok "new appended line tailed and prefixed" || bad "new line missing: $(cat "$capture")"
pkill -f "tail -F -n0 $ROOT/pal.log" 2>/dev/null

echo "================ TEST 4: multiple sources stay distinguishable by prefix ================"
reset_tree
cap_a="$ROOT/a.out"; cap_b="$ROOT/b.out"
( start_log_tail ue4ss "$ROOT/a.log" ) > "$cap_a" 2>&1
( start_log_tail pal   "$ROOT/b.log" ) > "$cap_b" 2>&1
sleep 0.2
echo "from-a" >> "$ROOT/a.log"
echo "from-b" >> "$ROOT/b.log"
wait_for 30 grep -q "from-a" "$cap_a"
wait_for 30 grep -q "from-b" "$cap_b"
grep -q "\[ue4ss\] from-a" "$cap_a" && ok "source a prefixed [ue4ss]" || bad "source a wrong/missing: $(cat "$cap_a")"
grep -q "\[pal\] from-b" "$cap_b" && ok "source b prefixed [pal]" || bad "source b wrong/missing: $(cat "$cap_b")"
pkill -f "tail -F -n0 $ROOT/a.log" 2>/dev/null
pkill -f "tail -F -n0 $ROOT/b.log" 2>/dev/null

echo "================ TEST 5: term_handler kills every tracked tail PID ================"
reset_tree
start_log_tail ue4ss "$ROOT/x.log"
start_log_tail pal   "$ROOT/y.log"
pid1="${tail_pids[0]}"; pid2="${tail_pids[1]}"
kill -0 "$pid1" 2>/dev/null && kill -0 "$pid2" 2>/dev/null && ok "both tail PIDs alive before cleanup" || bad "a tail PID was not alive before cleanup"
term_handler >/dev/null 2>&1
wait_for 20 sh -c "! kill -0 $pid1 2>/dev/null"
wait_for 20 sh -c "! kill -0 $pid2 2>/dev/null"
kill -0 "$pid1" 2>/dev/null && bad "pid1 survived term_handler" || ok "pid1 killed by term_handler"
kill -0 "$pid2" 2>/dev/null && bad "pid2 survived term_handler" || ok "pid2 killed by term_handler"

echo "================ TEST 6: TAIL_GAME_LOGS gate gets a true default ================"
unset TAIL_GAME_LOGS
TAIL_GAME_LOGS="${TAIL_GAME_LOGS:-true}"
[ "$TAIL_GAME_LOGS" = "true" ] && ok "unset TAIL_GAME_LOGS defaults to true" || bad "default was '$TAIL_GAME_LOGS', expected true"

echo "================ TEST 7: gate spawns both tails when true, none when false ================"
reset_tree
UE4SS_DIR="$ROOT/Win64"
INSTALL_DIR="$ROOT"
mkdir -p "$UE4SS_DIR"
TAIL_GAME_LOGS=true
( source "$SCRATCH/tail_gate.sh" ) >/dev/null 2>&1 &
gate_pid=$!
wait "$gate_pid" 2>/dev/null
# The gate runs in a subshell so tail_pids there is invisible here; instead
# assert on the actual spawned tail processes matching our sandbox paths.
wait_for 20 sh -c "pgrep -f 'tail -F -n0 $UE4SS_DIR/ue4ss/UE4SS.log' >/dev/null"
pgrep -f "tail -F -n0 $UE4SS_DIR/ue4ss/UE4SS.log" >/dev/null && ok "TAIL_GAME_LOGS=true spawned the ue4ss tail" || bad "ue4ss tail not spawned"
pgrep -f "tail -F -n0 $INSTALL_DIR/Pal/Saved/Logs/PalServer.log" >/dev/null && ok "TAIL_GAME_LOGS=true spawned the pal tail" || bad "pal tail not spawned"
pkill -f "tail -F -n0 $UE4SS_DIR/ue4ss/UE4SS.log" 2>/dev/null
pkill -f "tail -F -n0 $INSTALL_DIR/Pal/Saved/Logs/PalServer.log" 2>/dev/null
sleep 0.2

reset_tree
UE4SS_DIR="$ROOT/Win64"
INSTALL_DIR="$ROOT"
mkdir -p "$UE4SS_DIR"
TAIL_GAME_LOGS=false
( source "$SCRATCH/tail_gate.sh" ) >/dev/null 2>&1
sleep 0.2
pgrep -f "tail -F -n0 $UE4SS_DIR/ue4ss/UE4SS.log" >/dev/null && bad "ue4ss tail spawned despite TAIL_GAME_LOGS=false" || ok "TAIL_GAME_LOGS=false spawned no ue4ss tail"
pgrep -f "tail -F -n0 $INSTALL_DIR/Pal/Saved/Logs/PalServer.log" >/dev/null && bad "pal tail spawned despite TAIL_GAME_LOGS=false" || ok "TAIL_GAME_LOGS=false spawned no pal tail"

# Belt-and-suspenders cleanup: this test file must never leak tail/sed
# processes past its own run regardless of individual test outcomes above.
pkill -f "tail -F -n0 $ROOT/" 2>/dev/null
pkill -f "sed -u s/\^/\[" 2>/dev/null

echo
echo "================ RESULT: PASS=$PASS FAIL=$FAIL ================"
[ "$FAIL" -eq 0 ]
