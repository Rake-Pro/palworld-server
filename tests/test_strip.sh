#!/bin/bash
# Functional test harness for strip_zip_wrapper, extracted verbatim from
# init.sh (tests/strip_zip_wrapper.sh). Same conventions as test_reconcile.sh:
# Log* stubs, a throwaway sandbox tree, ok/bad pass counters.
set -uo pipefail

SCRATCH="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRATCH/sandbox_strip"

LogInfo()    { echo "  INFO  $*"; }
LogWarn()    { echo "  WARN  $*"; }
LogError()   { echo "  ERROR $*"; }
LogAction()  { echo "  ACT   $*"; }
LogSuccess() { echo "  OK    $*"; }

source "$SCRATCH/strip_zip_wrapper.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

reset_tree() {
    rm -rf "$ROOT"
    mkdir -p "$ROOT"
}

echo "================ TEST 1: wrapped zip (single dir) -> stripped ================"
reset_tree
mkdir -p "$ROOT/ModName-1.2.3/sub dir with spaces"
echo x > "$ROOT/ModName-1.2.3/dll_mods.lua"
echo y > "$ROOT/ModName-1.2.3/sub dir with spaces/file.txt"
strip_zip_wrapper "$ROOT"
[ ! -d "$ROOT/ModName-1.2.3" ] && ok "wrapper dir removed" || bad "wrapper dir still present"
[ -f "$ROOT/dll_mods.lua" ] && ok "wrapper file moved up" || bad "dll_mods.lua missing at root"
[ -f "$ROOT/sub dir with spaces/file.txt" ] && ok "nested dir-with-spaces moved up intact" || bad "spaced subdir missing/broken"

echo "================ TEST 2: flat zip (multiple root entries) -> untouched ================"
reset_tree
mkdir -p "$ROOT/dlls"
echo x > "$ROOT/main.lua"
echo y > "$ROOT/dlls/helper.dll"
before="$(find "$ROOT" | sort)"
strip_zip_wrapper "$ROOT"
after="$(find "$ROOT" | sort)"
[ "$before" = "$after" ] && ok "flat zip left byte-for-byte untouched" || bad "flat zip was modified: $after"

echo "================ TEST 3: wrapped zip with __MACOSX junk -> junk removed, wrapper stripped ================"
reset_tree
mkdir -p "$ROOT/ModName/inner" "$ROOT/__MACOSX"
echo x > "$ROOT/ModName/main.lua"
echo x > "$ROOT/ModName/inner/data.bin"
echo x > "$ROOT/__MACOSX/._main.lua"
touch "$ROOT/.DS_Store"
strip_zip_wrapper "$ROOT"
[ ! -d "$ROOT/__MACOSX" ] && ok "__MACOSX junk removed" || bad "__MACOSX still present"
[ ! -f "$ROOT/.DS_Store" ] && ok ".DS_Store junk removed" || bad ".DS_Store still present"
[ ! -d "$ROOT/ModName" ] && ok "wrapper dir removed once junk excluded from the count" || bad "wrapper dir still present"
[ -f "$ROOT/main.lua" ] && ok "wrapper file moved up past junk" || bad "main.lua missing at root"
[ -f "$ROOT/inner/data.bin" ] && ok "nested content moved up intact" || bad "inner/data.bin missing"

echo "================ TEST 4: single root FILE (not dir) -> must not strip ================"
reset_tree
echo x > "$ROOT/OnlyFile.lua"
before="$(find "$ROOT" | sort)"
strip_zip_wrapper "$ROOT"
after="$(find "$ROOT" | sort)"
[ "$before" = "$after" ] && ok "single root file left untouched" || bad "single root file was modified: $after"
[ -f "$ROOT/OnlyFile.lua" ] && ok "OnlyFile.lua still at root, unmoved" || bad "OnlyFile.lua missing"

echo "================ TEST 5: idempotent-safe - second call on an already-flat result is a no-op ================"
reset_tree
mkdir -p "$ROOT/ModName"
echo x > "$ROOT/ModName/a.lua"
echo y > "$ROOT/ModName/b.lua"
strip_zip_wrapper "$ROOT"
first="$(find "$ROOT" | sort)"
strip_zip_wrapper "$ROOT"
second="$(find "$ROOT" | sort)"
[ "$first" = "$second" ] && ok "second call is a no-op (idempotent-safe)" || bad "second call changed the tree: $second"
[ -f "$ROOT/a.lua" ] && [ -f "$ROOT/b.lua" ] && ok "both files survive both calls" || bad "files lost across calls"

echo "================ TEST 6: single root entry is a symlink -> never followed/stripped ================"
reset_tree
mkdir -p "$SCRATCH/outside_target"
echo secret > "$SCRATCH/outside_target/keepme"
ln -s "$SCRATCH/outside_target" "$ROOT/link-to-outside"
before="$(find "$ROOT" | sort)"
strip_zip_wrapper "$ROOT"
after="$(find "$ROOT" | sort)"
[ "$before" = "$after" ] && ok "symlink-only root left untouched" || bad "symlink root was modified: $after"
[ -L "$ROOT/link-to-outside" ] && ok "symlink itself still present, unresolved" || bad "symlink was consumed"
[ -f "$SCRATCH/outside_target/keepme" ] && ok "target outside the mod dir untouched" || bad "outside-target content touched!"
rm -rf "$SCRATCH/outside_target"

echo "================ TEST 7: name-with-spaces wrapper dir -> stripped correctly ================"
reset_tree
mkdir -p "$ROOT/My Mod Name v1.0"
echo x > "$ROOT/My Mod Name v1.0/config.json"
strip_zip_wrapper "$ROOT"
[ ! -d "$ROOT/My Mod Name v1.0" ] && ok "spaced wrapper dir removed" || bad "spaced wrapper dir still present"
[ -f "$ROOT/config.json" ] && ok "spaced-wrapper content moved up" || bad "config.json missing"

echo "================ TEST 8: empty target (nothing extracted) -> no-op, no error ================"
reset_tree
strip_zip_wrapper "$ROOT"
rc=$?
[ $rc -eq 0 ] && ok "empty target exits 0" || bad "empty target rc=$rc"
[ -d "$ROOT" ] && ok "empty target dir still exists" || bad "empty target dir was removed"

echo
echo "================ RESULT: PASS=$PASS FAIL=$FAIL ================"
[ "$FAIL" -eq 0 ]
