#!/bin/sh
# make-bisect-init.sh [INIT] [OUT] -- the same init with stage markers written to pmsg/ramoops first thing.
#
# The markers answer "how far did it get" from ONE boot: the LK handover, the kernel decompress, the early init, the
# preinit. Each line goes to /dev/pmsg0 (the ramoops pmsg device, readable on the next boot via /sys/fs/pstore) and,
# once devtmpfs exists, to /dev/kmsg as well.
set -eu
TOP=$(cd "$(dirname "$0")/.." && pwd)
IN=${1:-$TOP/boot/init}
OUT=${2:-${IN%.sh}.stagemark}
[ -f "$IN" ] || { echo "no init at $IN" >&2; exit 1; }
cat > "$OUT" <<'EOF'
#!/bin/sh
# BISECT VARIANT: stage markers to pmsg before anything else runs. Remove after the investigation.
stage() {
    _l="mu300-stage: $* uptime=$(cut -d. -f1 /proc/uptime 2>/dev/null)"
    echo "$_l" > /dev/pmsg0 2>/dev/null || true
    echo "$_l" > /dev/kmsg 2>/dev/null || true
}
stage init-start
EOF
sed -n '2,$p' "$IN" >> "$OUT"
chmod 755 "$OUT"
echo "wrote $OUT"