#!/bin/sh
# The regulatory database has to be a signed pair: this kernel line is built with
# CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y, so a regulatory.db whose .p7s does not verify is rejected and cfg80211
# falls back to the world regdomain - 5 GHz ch36 becomes NO-IR and hostapd disables the AP (the v2026.11.08.5
# device test). The wireless-regdb package ships only regulatory.db, and a package upgrade can leave the signature
# of the base image behind, so an image can carry a database with the signature of another version. This gate
# reads the pair out of the image and verifies it; tools/check-update-audit.sh calls it, so a release with a
# mismatched pair fails its build.
#   tools/check-regdb.sh IMAGE.tar.gz
#
# An image with no regulatory database at all is not failed (the kernel uses the database built into it); a
# database without a signature, or a signature without a database, is.
set -eu
IMG=${1:?usage: tools/check-regdb.sh IMAGE.tar.gz}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
D=$T/lib/firmware/regulatory.db
S=$T/lib/firmware/regulatory.db.p7s
DB=$(tar -tzf "$IMG" 2>/dev/null | grep -m1 "lib/firmware/regulatory.db$" || true)
SG=$(tar -tzf "$IMG" 2>/dev/null | grep -m1 "lib/firmware/regulatory.db.p7s$" || true)
[ -z "$DB" ] || tar -xzf "$IMG" -C "$T" "$DB" 2>/dev/null || true
[ -z "$SG" ] || tar -xzf "$IMG" -C "$T" "$SG" 2>/dev/null || true
if [ ! -f "$D" ] && [ ! -f "$S" ]; then
    echo "check-regdb: $IMG carries no regulatory database (the kernel built-in one is used)"
    exit 0
fi
[ -f "$D" ] || { echo "$IMG has lib/firmware/regulatory.db.p7s but no regulatory.db" >&2; exit 1; }
[ -f "$S" ] || {
    echo "$IMG has lib/firmware/regulatory.db without its signature: the kernel rejects it and falls back to the world regdomain" >&2
    exit 1
}
command -v openssl >/dev/null 2>&1 || {
    echo "$IMG: openssl is needed to verify the regulatory database signature" >&2
    exit 1
}
if ! openssl smime -verify -in "$S" -inform DER -content "$D" -noverify -out /dev/null 2>"$T/err"; then
    echo "$IMG: the regulatory database does not match its signature:" >&2
    sed 's/^/  /' "$T/err" | head -n 3 >&2
    exit 1
fi
echo "check-regdb: $IMG carries a regulatory database whose signature verifies"
