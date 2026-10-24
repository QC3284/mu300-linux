#!/bin/sh
# Verify that rootfs/overlay/opt/mu300/bin/mobile-data keeps the strict p4 bring-up gating:
#   (a) AT+CGDATA must answer CONNECT or the dial FAILS on the primary slot (no optimistic "up"),
#   (b) the dial waits for the native SIM radio (/run/mu300/sim-radio-ready, MU300_NATIVE_RADIO_WAIT) before its first AT,
#   (c) the bounded/tree_kill wrappers it relies on are present.
# Run from the repo root. Exits 1 with the first missing guard.
set -u
F=${1:-rootfs/overlay/opt/mu300/bin/mobile-data}
[ -f "$F" ] || { echo "missing $F" >&2; exit 1; }
fail=0
grep -q 'AT+CGDATA=\\*M-ETHER' "$F" >/dev/null 2>&1 || true
if ! grep -q 'if ! at "AT+CGDATA' "$F"; then
    echo 'GUARD MISSING: AT+CGDATA is not checked with a failing branch' >&2; fail=1
fi
if ! grep -q 'SIM_SLOT\" != 1 \] || return 1' "$F"; then
    echo 'GUARD MISSING: the missing-CONNECT branch does not fail the primary slot' >&2; fail=1
fi
if ! grep -q 'sim-radio-ready' "$F"; then
    echo 'GUARD MISSING: no pre-dial sim-radio-ready wait' >&2; fail=1
fi
if ! grep -q 'MU300_NATIVE_RADIO_WAIT' "$F"; then
    echo 'GUARD MISSING: the pre-dial wait has no MU300_NATIVE_RADIO_WAIT deadline' >&2; fail=1
fi
for h in '^bounded()' '^tree_kill()'; do
    grep -q "$h" "$F" || { echo "GUARD MISSING: helper $h" >&2; fail=1; }
done
[ "$fail" = 0 ] && echo "mobile-data gating OK ($F)"
exit "$fail"
