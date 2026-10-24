#!/bin/sh
# sign-release-with-identity.sh SHA256SUMS [PUBLIC_KEY] -- the release signing step.
#
# mu300-update refuses a signed SHA256SUMS that does not say which release it is: sums_verdict looks for an entry
# whose file field is "mu300-release" and compares its hash with sha256(tag). This wrapper writes that line when the tag
# is known (MU300_RELEASE_TAG) and then hands the file to tools/sign-release.sh unchanged, which also verifies the
# signature against the public key baked in the images.
set -eu
SUMS=${1:?usage: tools/sign-release-with-identity.sh SHA256SUMS [PUBLIC_KEY]}
[ -n "${MU300_RELEASE_TAG:-}" ] || { echo "sign-release-with-identity: MU300_RELEASE_TAG is not set" >&2; exit 1; }
if ! grep -q " mu300-release$" "$SUMS"; then
    _ts=$(printf "%s\n" "$MU300_RELEASE_TAG" | sha256sum | cut -d" " -f1)
    printf "%s  mu300-release\n" "$_ts" >> "$SUMS"
    echo "identity line added for $MU300_RELEASE_TAG: $_ts" >&2
fi
exec "$(dirname "$0")/sign-release.sh" "$@"
