#!/bin/bash
set -uo pipefail
SCRATCH="$(cd "$(dirname "$0")" && pwd)"
LogInfo(){ echo "  INFO  $*"; }; LogWarn(){ echo "  WARN  $*"; }
LogError(){ echo "  ERROR $*"; }; LogAction(){ echo "  ACT   $*"; }
LogSuccess(){ echo "  OK    $*"; }
: >"$SCRATCH/dlcount"
curl(){ local out=""; while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
  echo x >>"$SCRATCH/dlcount"; [ -n "$out" ] && { mkdir -p "$(dirname "$out")"; echo zip > "$out"; }; return 0; }
unzip(){ local dir=""; while [ $# -gt 0 ]; do case "$1" in -d) dir="$2"; shift 2;; *) shift;; esac; done
  [ -n "$dir" ] && { mkdir -p "$dir"; echo dwmapi > "$dir/dwmapi.dll"; }; return 0; }
source "$SCRATCH/install_ue4ss.sh"

PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

setup(){
  UE4SS_DIR="$SCRATCH/ue4ss_sandbox/Win64"
  rm -rf "$SCRATCH/ue4ss_sandbox"; mkdir -p "$UE4SS_DIR"
  UE4SS_MARKER="$UE4SS_DIR/.ue4ss-version"
  UE4SS_VERSION="experimental-palworld"
  export UE4SS_DIR UE4SS_MARKER UE4SS_VERSION
  : >"$SCRATCH/dlcount"
}
run_gate(){ source "$SCRATCH/ue4ss_gate.sh"; }

echo "==== A: fresh (no marker), FORCE=false -> installs ===="
setup; UE4SS_ENABLED=true; UE4SS_FORCE_REINSTALL=false
out="$(run_gate 2>&1)"; echo "$out"
[ "$(wc -l <"$SCRATCH/dlcount")" -eq 1 ] && ok "downloaded once on fresh" || bad "dl=$(wc -l <"$SCRATCH/dlcount")"
[ "$(cat "$UE4SS_MARKER")" = "experimental-palworld" ] && ok "marker written" || bad "marker missing"

echo "==== B: marker present, same version, FORCE=false -> SKIP ===="
UE4SS_ENABLED=true; UE4SS_FORCE_REINSTALL=false; : >"$SCRATCH/dlcount"
out="$(run_gate 2>&1)"; echo "$out"
[ "$(wc -l <"$SCRATCH/dlcount")" -eq 0 ] && ok "no re-download when marker matches" || bad "dl=$(wc -l <"$SCRATCH/dlcount")"
echo "$out" | grep -q "already at" && ok "logged skip" || bad "no skip log"

echo "==== C: marker present, same version, FORCE=true -> REINSTALL ===="
UE4SS_ENABLED=true; UE4SS_FORCE_REINSTALL=true; : >"$SCRATCH/dlcount"
rm -f "$UE4SS_DIR/dwmapi.dll"
out="$(run_gate 2>&1)"; echo "$out"
[ "$(wc -l <"$SCRATCH/dlcount")" -eq 1 ] && ok "forced re-download despite matching marker" || bad "dl=$(wc -l <"$SCRATCH/dlcount")"
echo "$out" | grep -q "UE4SS_FORCE_REINSTALL=true" && ok "logged forced action prominently" || bad "no force log"
[ -f "$UE4SS_DIR/dwmapi.dll" ] && ok "re-extracted (dwmapi.dll back)" || bad "not re-extracted"
[ "$(cat "$UE4SS_MARKER")" = "experimental-palworld" ] && ok "marker rewritten" || bad "marker not rewritten"

echo "==== D: UE4SS_ENABLED=false -> skip entirely ===="
setup; UE4SS_ENABLED=false; UE4SS_FORCE_REINSTALL=true; : >"$SCRATCH/dlcount"
out="$(run_gate 2>&1)"; echo "$out"
[ "$(wc -l <"$SCRATCH/dlcount")" -eq 0 ] && ok "disabled short-circuits force" || bad "dl=$(wc -l <"$SCRATCH/dlcount")"

echo; echo "==== RESULT: PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
