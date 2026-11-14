#!/bin/sh
# Audit an update image: what makes an update carry the user's files over must be in it, and sound.
#   tools/check-update-audit.sh IMAGE.tar.gz BUSYBOX_PATH UNION[,UNION...]
#
# An update to an image without these keeps only the places keep_list names and replaces everything else: the
# config-migration gap of v2026.11.08.1 and every image of this line before it. opt/mu300/bin/mu300-carry is the
# helper the carry block runs, BUSYBOX_PATH the static shell that runs the helper (the updater also unpacks through
# it), the union manifests tell a release file of an older system from the user's, and etc/mu300/image-manifest.gz
# is the image's own list. The manifest is checked against the files of the tarball, two implementations held
# against each other (tools/image-manifest.py), as tools/make-release.sh always did.
#
# env:
#   MU300_AUDIT_TOOLS=DIR       where image-manifest.py is (default: this script's directory)
#   MU300_AUDIT_EXACT_UNIONS=1  the image must have no union manifest of a system other than UNIONs (the older
#                               per-system images); a layout release serves every OpenWrt system, so it has more
set -eu
IMG=${1:?usage: tools/check-update-audit.sh IMAGE.tar.gz BUSYBOX_PATH UNION[,UNION...]}
BB=${2:?usage: tools/check-update-audit.sh IMAGE.tar.gz BUSYBOX_PATH UNION[,UNION...]}
UNIONS=${3:?usage: tools/check-update-audit.sh IMAGE.tar.gz BUSYBOX_PATH UNION[,UNION...]}
TOOLS=${MU300_AUDIT_TOOLS:-$(cd "$(dirname "$0")" && pwd)}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
L=$T/members
tar -tzf "$IMG" | sed 's|^\./||' > "$L" || { echo "$IMG: not a readable tarball" >&2; exit 1; }
fail=0
needs() {
    grep -qx -- "$1" "$L" || { echo "$IMG lacks $1: an update to it would not carry everything over" >&2; fail=1; }
}
needs opt/mu300/bin/mu300-carry
needs "$BB"
needs opt/mu300/bin/mu300-update
needs etc/mu300/image-manifest.gz
for u in $(printf '%s\n' "$UNIONS" | tr ',' ' '); do
    needs "opt/mu300/lib/image-manifests/$u.gz"
done
# the helper is a static AArch64 binary: one built by the amd64 kbuild container (or with the host's cc) cannot run
# in the image at all, and the update would fall back to the list of places it was supposed to replace
tar -xzf "$IMG" -C "$T" ./opt/mu300/bin/mu300-carry 2>/dev/null || true
C=$T/opt/mu300/bin/mu300-carry
if [ -e "$C" ]; then
    [ -x "$C" ] || { echo "$IMG: opt/mu300/bin/mu300-carry is not executable" >&2; fail=1; }
    if command -v readelf >/dev/null 2>&1; then
        LC_ALL=C readelf -h "$C" > "$T/elf" 2>/dev/null || : > "$T/elf"
        if ! grep -q 'Machine:.*AArch64' "$T/elf"; then
            echo "$IMG: opt/mu300/bin/mu300-carry is not an AArch64 ELF (built on the amd64 host instead of the target?)" >&2
            fail=1
        fi
        if LC_ALL=C readelf -l "$C" 2>/dev/null | grep -q 'INTERP'; then
            echo "$IMG: opt/mu300/bin/mu300-carry is dynamically linked: the image runs it without a loader" >&2
            fail=1
        fi
    elif command -v file >/dev/null 2>&1; then
        LC_ALL=C file "$C" | grep -q 'ARM aarch64' || { echo "$IMG: opt/mu300/bin/mu300-carry is not an AArch64 binary" >&2; fail=1; }
    fi
fi
if [ "${MU300_AUDIT_EXACT_UNIONS:-0}" = 1 ]; then
    want=$(printf '%s\n' "$UNIONS" | tr ',' '\n' | grep -c . || true)
    have=$(grep -c '^opt/mu300/lib/image-manifests/.*\.gz$' "$L" || true)
    [ "$have" = "$want" ] || { echo "$IMG has manifests of another system in opt/mu300/lib/image-manifests" >&2; fail=1; }
fi
[ "$fail" = 0 ] || exit 1
python3 "$TOOLS/image-manifest.py" check "$IMG" || exit 1
echo "audit: $IMG carries mu300-carry (static AArch64), $BB, its manifest and the unions of $UNIONS"
