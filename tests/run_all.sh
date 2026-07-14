#!/bin/bash
# Runs every tests/test_*.sh harness and checks that the fixtures
# (reconcile_mods.sh, install_ue4ss.sh, ue4ss_gate.sh, strip_zip_wrapper.sh,
# tail_logs.sh, tail_gate.sh - each a verbatim extract of the matching
# scripts/init.sh region) have not drifted out of sync with init.sh itself.
# Drift here means a test would be exercising stale logic without anyone
# noticing, so it fails the run loudly rather than silently.
set -uo pipefail

SCRATCH="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRATCH/.." && pwd)"
INIT_SH="$REPO_ROOT/scripts/init.sh"

DRIFT=0
check_drift() {
    # Anchor on the fixture's first line (must be a unique line in init.sh)
    # and take exactly as many lines as the fixture has. Any edit to the
    # region in init.sh - content OR length - changes what this slice
    # captures and is reported as drift; that's the point.
    local fixture="$1" first n startline got want
    first="$(head -n1 "$SCRATCH/$fixture")"
    n="$(wc -l < "$SCRATCH/$fixture")"
    want="$(cat "$SCRATCH/$fixture")"
    startline="$(grep -n -F -x "$first" "$INIT_SH" | head -1 | cut -d: -f1)"
    if [ -z "$startline" ]; then
        echo "  DRIFT $fixture: anchor line '$first' not found in scripts/init.sh - re-extract it"
        DRIFT=1
        return
    fi
    got="$(sed -n "${startline},$((startline + n - 1))p" "$INIT_SH")"
    if [ "$got" = "$want" ]; then
        echo "  OK    $fixture matches scripts/init.sh"
    else
        echo "  DRIFT $fixture no longer matches scripts/init.sh - re-extract it"
        DRIFT=1
    fi
}

echo "==== fixture drift check ===="
for fixture in reconcile_mods.sh install_ue4ss.sh ue4ss_gate.sh strip_zip_wrapper.sh tail_logs.sh tail_gate.sh; do
    check_drift "$fixture"
done
if [ "$DRIFT" -ne 0 ]; then
    echo "One or more test fixtures have drifted from scripts/init.sh; re-extract them before trusting the results below."
fi
echo

TOTAL_FAIL=0
for t in test_reconcile.sh test_ue4ss.sh test_strip.sh test_tail.sh; do
    echo "==== running $t ===="
    if "$SCRATCH/$t"; then
        echo "==== $t: PASS ===="
    else
        echo "==== $t: FAIL ===="
        TOTAL_FAIL=1
    fi
    echo
done

[ "$DRIFT" -eq 0 ] && [ "$TOTAL_FAIL" -eq 0 ]
