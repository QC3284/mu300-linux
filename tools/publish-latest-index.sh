#!/bin/sh
# publish-latest-index.sh TAG [REPO] [THEMES] - the static index mu300-update reads when the API is unreachable.
#
# Every release publishes one tiny asset per theme (latest-aurora, latest-argon), one line each:
#     mu300-latest 1 <tag>
# They are read through releases/latest/download/<name>, a download path, so no API call is involved. Run this after
# the release assets are uploaded; it writes, uploads with --clobber and then checks the public path.
set -eu
TAG=${1:?usage: tools/publish-latest-index.sh TAG [REPO] [THEMES]}
REPO=${2:-QC3284/mu300-linux}
THEMES=${3:-aurora argon}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
for t in $THEMES; do
    printf 'mu300-latest 1 %s\n' "$TAG" > "$W/latest-$t"
    printf '  %s: %s' "latest-$t" "$(cat "$W/latest-$t" | tr -d '\n')"; echo
    gh release upload "$TAG" --repo "$REPO" --clobber "$W/latest-$t" >/dev/null
done
rc=0
for t in $THEMES; do
    code=$(curl -s -o "$W/i" -w '%{http_code}' --max-time 25 --range 0-60 "https://github.com/$REPO/releases/latest/download/latest-$t" || echo 000)
    body=$(tr -d '\n' < "$W/i" 2>/dev/null | head -c 60)
    printf '  check latest-%s: %s %s\n' "$t" "$code" "$body"
    case $code in 200|206) ;; *) rc=1 ;; esac
done
exit $rc
