#!/bin/sh
# check-rpcd-plugins.sh ROOTFS.tar.gz | ROOTDIR
#
# rpcd treats a plugin it cannot exec as a ucode program: a shell plugin without its exec bit or its shebang then dies
# with "Syntax error" at load and rpcd drops the whole plugin set (the luci object disappears, LuCI shows
# "Object not found"). This gate fails a build whose rpcd plugins would land that way, and it also sanity-checks the
# ucode plugins (balanced braces) because those are parsed by rpcd too.
set -u
SRC=${1:?rootfs tar.gz or directory}
tmp=''
case $SRC in
    *.tar.gz|*.tgz) tmp=$(mktemp -d) ; tar xzf "$SRC" -C "$tmp" ./usr/libexec/rpcd ./usr/share/rpcd/ucode 2>/dev/null || true ;;
    *) tmp=$SRC ;;
esac
fail=0
for f in "$tmp"/usr/libexec/rpcd/*; do
    [ -e "$f" ] || continue
    name=${f##*/}
    [ -x "$f" ] || { echo "FAIL: $name is not executable (rpcd would parse it as ucode)" >&2; fail=1; }
    head -c 2 "$f" | grep -q '#!' || { echo "FAIL: $name has no shebang" >&2; fail=1; }
done
for f in "$tmp"/usr/share/rpcd/ucode/*; do
    [ -e "$f" ] || continue
    name=${f##*/}
    if command -v ucode >/dev/null 2>&1; then
        ucode -c "$f" 2>/dev/null || { echo "FAIL: ucode plugin $name does not parse" >&2; fail=1; }
    else
        o=$(tr -cd '{' < "$f" | wc -c); c=$(tr -cd '}' < "$f" | wc -c)
        [ "$o" = "$c" ] || { echo "WARN: $name braces {=$o }=$c (no ucode here to parse it)" >&2; }
    fi
done
[ -n "$tmp" ] && [ "$tmp" != "$SRC" ] && rm -rf "$tmp"
[ "$fail" = 0 ] && echo "rpcd plugins OK"
exit "$fail"
