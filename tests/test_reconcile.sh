#!/bin/bash
# Functional test harness for reconcile_mods extracted verbatim from init.sh.
set -uo pipefail

SCRATCH="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRATCH/sandbox"

# --- stubs -----------------------------------------------------------------
LogInfo()    { echo "  INFO  $*"; }
LogWarn()    { echo "  WARN  $*"; }
LogError()   { echo "  ERROR $*"; }
LogAction()  { echo "  ACT   $*"; }
LogSuccess() { echo "  OK    $*"; }

# curl stub: -o <path> is the last arg; just create a file there.
curl() {
    local out=""
    while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
    [ -n "$out" ] && { mkdir -p "$(dirname "$out")"; echo "stub-payload" > "$out"; }
    return 0
}
# unzip stub: -d <dir> gives extract dir; drop a marker file in it.
unzip() {
    local dir=""
    while [ $# -gt 0 ]; do case "$1" in -d) dir="$2"; shift 2;; *) shift;; esac; done
    [ -n "$dir" ] && { mkdir -p "$dir"; echo "extracted" > "$dir/extracted.txt"; }
    return 0
}

source "$SCRATCH/reconcile_mods.sh"

reset_tree() {
    rm -rf "$ROOT"
    INSTALL_DIR="$ROOT"
    PAKS_ROOT="$INSTALL_DIR/Pal/Content/Paks"
    UE4SS_MODS_DIR="$INSTALL_DIR/Pal/Binaries/Win64/ue4ss/Mods"
    PALSCHEMA_MODS_DIR="$UE4SS_MODS_DIR/PalSchema/mods"
    mkdir -p "$INSTALL_DIR/Pal/Content/Paks/~mods" \
             "$INSTALL_DIR/Pal/Content/Paks/LogicMods" \
             "$UE4SS_MODS_DIR"
    export INSTALL_DIR PAKS_ROOT UE4SS_MODS_DIR PALSCHEMA_MODS_DIR
}

PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "================ TEST 1: valid entries install into correct roots ================"
reset_tree
MAN="$INSTALL_DIR/.mods-manifest"
( reconcile_mods "$MAN" pak "$PAKS_ROOT" "alpha@https://x/alpha.pak" "logicmods:beta@https://x/beta.zip" )
rc=$?
[ $rc -eq 0 ] && ok "valid pak reconcile exits 0" || bad "valid pak reconcile rc=$rc"
[ -f "$INSTALL_DIR/Pal/Content/Paks/~mods/alpha/alpha.pak" ] && ok "alpha.pak in ~mods" || bad "alpha.pak missing"
[ -f "$INSTALL_DIR/Pal/Content/Paks/LogicMods/beta/extracted.txt" ] && ok "beta zip in LogicMods" || bad "beta missing"
grep -qP '^alpha\t' "$MAN" && ok "alpha in manifest" || bad "alpha not tracked"
grep -qP '^beta\t'  "$MAN" && ok "beta in manifest"  || bad "beta not tracked"

echo "================ TEST 2: name '../evil' exits 1 BEFORE any write ================"
reset_tree
MAN="$INSTALL_DIR/.mods-manifest"
before="$(find "$INSTALL_DIR/Pal/Content/Paks" -mindepth 2 | sort)"
out="$( ( reconcile_mods "$MAN" pak "$PAKS_ROOT" "../evil@https://x/e.pak" ) 2>&1 )"
rc=$?
[ $rc -eq 1 ] && ok "illegal name exits 1" || bad "illegal name rc=$rc (expected 1)"
echo "$out" | grep -q "illegal mod name" && ok "logged illegal name error" || bad "no illegal-name log"
after="$(find "$INSTALL_DIR/Pal/Content/Paks" -mindepth 2 | sort)"
[ "$before" = "$after" ] && ok "no filesystem write before exit" || bad "filesystem changed: $after"
[ ! -f "$MAN" ] && ok "manifest not created before validation exit" || bad "manifest was touched"

echo "================ TEST 2b: name with slash exits 1 ================"
reset_tree
MAN="$INSTALL_DIR/.mods-manifest"
( reconcile_mods "$MAN" pak "$PAKS_ROOT" "foo/bar@https://x/e.pak" ) >/dev/null 2>&1
[ $? -eq 1 ] && ok "slash name exits 1" || bad "slash name did not exit 1"

echo "================ TEST 3: duplicate name -> warn + skip second ================"
reset_tree
MAN="$INSTALL_DIR/.mods-manifest"
out="$( ( reconcile_mods "$MAN" pak "$PAKS_ROOT" "dup@https://x/a.pak" "dup@https://x/b.pak" ) 2>&1 )"
rc=$?
[ $rc -eq 0 ] && ok "duplicate reconcile exits 0" || bad "duplicate rc=$rc"
echo "$out" | grep -q "duplicate mod name 'dup'" && ok "warned on duplicate" || bad "no duplicate warning"
cnt=$(grep -cP '^dup\t' "$MAN")
[ "$cnt" -eq 1 ] && ok "dup recorded exactly once" || bad "dup recorded $cnt times"

echo "================ TEST 4: de-list removes exactly the right dir ================"
reset_tree
MAN="$INSTALL_DIR/.mods-manifest"
( reconcile_mods "$MAN" pak "$PAKS_ROOT" "keep@https://x/k.pak" "drop@https://x/d.pak" ) >/dev/null 2>&1
[ -d "$INSTALL_DIR/Pal/Content/Paks/~mods/keep" ] && ok "keep installed" || bad "keep missing"
[ -d "$INSTALL_DIR/Pal/Content/Paks/~mods/drop" ] && ok "drop installed" || bad "drop missing"
# Second pass drops 'drop' from the list.
out="$( ( reconcile_mods "$MAN" pak "$PAKS_ROOT" "keep@https://x/k.pak" ) 2>&1 )"
echo "$out" | grep -q "removing de-listed mod drop" && ok "logged de-list of drop" || bad "no de-list log"
[ -d "$INSTALL_DIR/Pal/Content/Paks/~mods/keep" ] && ok "keep survived" || bad "keep was removed!"
[ ! -d "$INSTALL_DIR/Pal/Content/Paks/~mods/drop" ] && ok "drop dir removed" || bad "drop dir still present"
grep -qP '^keep\t' "$MAN" && ! grep -qP '^drop\t' "$MAN" && ok "manifest reflects de-list" || bad "manifest wrong after de-list"

echo "================ TEST 5: manifest path OUTSIDE mods root -> warn, NOT removed ================"
reset_tree
MAN="$INSTALL_DIR/.mods-manifest"
# Craft a corrupt manifest pointing outside the paks root, plus a traversal one.
victim="$SCRATCH/victim_outside"
mkdir -p "$victim"; echo "precious" > "$victim/keepme"
trav="$INSTALL_DIR/Pal/Content/Paks/../../../victim_traversal"
mkdir -p "$trav"; echo "precious" > "$trav/keepme"
printf 'evil\t%s\n' "$victim" >  "$MAN"
printf 'travo\t%s\n' "$trav"  >> "$MAN"
# Reconcile with empty want-list: both should be de-list candidates but blocked.
out="$( ( reconcile_mods "$MAN" pak "$PAKS_ROOT" "" ) 2>&1 )"
rc=$?
[ $rc -eq 0 ] && ok "corrupt-manifest reconcile exits 0" || bad "rc=$rc"
echo "$out" | grep -q "resolves outside" && ok "warned outside-root" || bad "no outside-root warning"
[ -f "$victim/keepme" ] && ok "outside-root dir NOT removed" || bad "outside-root dir was removed!"
[ -f "$trav/keepme" ]  && ok "traversal path NOT removed"   || bad "traversal path was removed!"
grep -qP '^evil\t'  "$MAN" && ok "outside entry kept in manifest"  || bad "outside entry dropped"
grep -qP '^travo\t' "$MAN" && ok "traversal entry kept in manifest" || bad "traversal entry dropped"

echo "================ TEST 6: ue4ss kind installs into ue4ss/Mods ================"
reset_tree
MAN="$INSTALL_DIR/.ue4ss-mods-manifest"
( reconcile_mods "$MAN" ue4ss "$UE4SS_MODS_DIR" "PalSchema@https://x/PalSchema.zip" ) >/dev/null 2>&1
[ -f "$UE4SS_MODS_DIR/PalSchema/extracted.txt" ] && ok "ue4ss mod extracted into ue4ss/Mods" || bad "ue4ss mod missing"
# de-list from ue4ss root works and is bounded to ue4ss root
out="$( ( reconcile_mods "$MAN" ue4ss "$UE4SS_MODS_DIR" "" ) 2>&1 )"
[ ! -d "$UE4SS_MODS_DIR/PalSchema" ] && ok "ue4ss de-list removed dir" || bad "ue4ss de-list failed"

echo "================ TEST 7: malformed (no @) exits 1 ================"
reset_tree
MAN="$INSTALL_DIR/.mods-manifest"
( reconcile_mods "$MAN" pak "$PAKS_ROOT" "noaturl" ) >/dev/null 2>&1
[ $? -eq 1 ] && ok "malformed entry exits 1" || bad "malformed entry did not exit 1"

echo "================ TEST 8: exact-match idempotency (no substring false-positive) ================"
reset_tree
MAN="$INSTALL_DIR/.mods-manifest"
( reconcile_mods "$MAN" pak "$PAKS_ROOT" "mod@https://x/mod.pak" ) >/dev/null 2>&1
# Now request 'mod2' which shares the 'mod' prefix; must NOT be seen as installed.
out="$( ( reconcile_mods "$MAN" pak "$PAKS_ROOT" "mod@https://x/mod.pak" "mod2@https://x/mod2.pak" ) 2>&1 )"
echo "$out" | grep -q "installing mod2" && ok "mod2 installed (no prefix false-match)" || bad "mod2 wrongly skipped"
echo "$out" | grep -q "mod already installed" && ok "mod exact-match skip" || bad "mod not recognized as installed"

echo "================ TEST 9: palschema kind installs flat under PalSchema/mods ================"
reset_tree
MAN="$INSTALL_DIR/.palschema-mods-manifest"
mkdir -p "$UE4SS_MODS_DIR/PalSchema"   # simulate PalSchema itself already present
( reconcile_mods "$MAN" palschema "$PALSCHEMA_MODS_DIR" "SomeSchemaMod@https://x/SomeSchemaMod.zip" ) >/dev/null 2>&1
[ -f "$PALSCHEMA_MODS_DIR/SomeSchemaMod/extracted.txt" ] && ok "palschema sub-mod extracted into PalSchema/mods" || bad "palschema sub-mod missing"
grep -qP '^SomeSchemaMod\t' "$MAN" && ok "palschema sub-mod tracked in its own manifest" || bad "palschema sub-mod not tracked"

echo "================ TEST 10: palschema de-list removal, bounded to its own root ================"
reset_tree
MAN="$INSTALL_DIR/.palschema-mods-manifest"
mkdir -p "$UE4SS_MODS_DIR/PalSchema"
( reconcile_mods "$MAN" palschema "$PALSCHEMA_MODS_DIR" "keep@https://x/keep.zip" "drop@https://x/drop.zip" ) >/dev/null 2>&1
[ -d "$PALSCHEMA_MODS_DIR/keep" ] && [ -d "$PALSCHEMA_MODS_DIR/drop" ] && ok "both palschema sub-mods installed" || bad "palschema sub-mod install failed"
out="$( ( reconcile_mods "$MAN" palschema "$PALSCHEMA_MODS_DIR" "keep@https://x/keep.zip" ) 2>&1 )"
echo "$out" | grep -q "removing de-listed mod drop" && ok "logged de-list of palschema drop" || bad "no palschema de-list log"
[ -d "$PALSCHEMA_MODS_DIR/keep" ] && ok "palschema keep survived" || bad "palschema keep was removed!"
[ ! -d "$PALSCHEMA_MODS_DIR/drop" ] && ok "palschema drop dir removed" || bad "palschema drop dir still present"
# UE4SS_MODS_DIR itself (one level up) must be untouched by the palschema-scoped removal.
[ -d "$UE4SS_MODS_DIR/PalSchema" ] && ok "PalSchema install dir untouched by sub-mod de-list" || bad "PalSchema install dir was disturbed!"

echo "================ TEST 11: palschema name '../evil' rejected, no write ================"
reset_tree
MAN="$INSTALL_DIR/.palschema-mods-manifest"
mkdir -p "$UE4SS_MODS_DIR/PalSchema"
before="$(find "$UE4SS_MODS_DIR" -mindepth 1 | sort)"
out="$( ( reconcile_mods "$MAN" palschema "$PALSCHEMA_MODS_DIR" "../evil@https://x/e.zip" ) 2>&1 )"
rc=$?
[ $rc -eq 1 ] && ok "palschema illegal name exits 1" || bad "palschema illegal name rc=$rc (expected 1)"
echo "$out" | grep -q "illegal mod name" && ok "logged palschema illegal-name error" || bad "no palschema illegal-name log"
after="$(find "$UE4SS_MODS_DIR" -mindepth 1 | sort)"
[ "$before" = "$after" ] && ok "no filesystem write before palschema validation exit" || bad "filesystem changed: $after"

echo "================ TEST 12: missing-PalSchema warning path (init.sh call-site logic) ================"
# Mirrors the exact conditional in init.sh section 6: warns (but still installs)
# when PALSCHEMA_MODS is non-empty and ue4ss/Mods/PalSchema does not exist yet.
reset_tree
MAN="$INSTALL_DIR/.palschema-mods-manifest"
PALSCHEMA_MODS="SomeSchemaMod@https://x/SomeSchemaMod.zip"
# PalSchema NOT pre-created here (unlike tests 9-11) - the missing-parent case.
out="$( {
    if [ -n "$(printf '%s' "$PALSCHEMA_MODS" | tr -d '[:space:]')" ] && [ ! -d "$UE4SS_MODS_DIR/PalSchema" ]; then
        LogWarn "PALSCHEMA_MODS set but PalSchema is not installed under ue4ss/Mods (hint: add PalSchema to UE4SS_MODS); installing the sub-mod files anyway, they stay inert until PalSchema is present"
    fi
    mkdir -p "$PALSCHEMA_MODS_DIR"
    reconcile_mods "$MAN" palschema "$PALSCHEMA_MODS_DIR" $PALSCHEMA_MODS
} 2>&1 )"
echo "$out" | grep -q "PalSchema is not installed under ue4ss/Mods" && ok "warned when PalSchema parent missing" || bad "no missing-PalSchema warning"
[ -f "$PALSCHEMA_MODS_DIR/SomeSchemaMod/extracted.txt" ] && ok "sub-mod still installed despite missing PalSchema" || bad "sub-mod install skipped"
# Now install PalSchema itself and re-run: warning must NOT fire.
mkdir -p "$UE4SS_MODS_DIR/PalSchema"
out2="$( {
    if [ -n "$(printf '%s' "$PALSCHEMA_MODS" | tr -d '[:space:]')" ] && [ ! -d "$UE4SS_MODS_DIR/PalSchema" ]; then
        LogWarn "PALSCHEMA_MODS set but PalSchema is not installed under ue4ss/Mods (hint: add PalSchema to UE4SS_MODS); installing the sub-mod files anyway, they stay inert until PalSchema is present"
    fi
} 2>&1 )"
[ -z "$out2" ] && ok "no warning once PalSchema is present" || bad "unexpected warning: $out2"

echo
echo "================ RESULT: PASS=$PASS FAIL=$FAIL ================"
[ "$FAIL" -eq 0 ]
