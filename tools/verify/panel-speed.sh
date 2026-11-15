#!/bin/sh
# The dashboard's status lane, measured the way the page polls it.
#
# usage: sh tools/verify/panel-speed.sh CHROOT_DIR [REPO]
#
# CHROOT_DIR is an extracted image root (prepare-chroot.py's output, or a rootfs
# unpacked by hand). The probe starts the image's own ubusd/rpcd in that chroot,
# polls mu300status.status 120 times, and then proves the 2 s reply copies work
# (two identical calls inside one TTL must not run the adapter twice). Run it on
# a native arm64 machine: under qemu every call is seconds and the numbers mean
# nothing about the device.
#
#   MU300_VERIFY_RUNTIME=direct (default; needs root/sudo for the mounts) or docker
#   MU300_VERIFY_DOCKER_IMAGE=ubuntu:24.04   the arm64 container for docker mode
#   MU300_PANEL_POLLS=120                    the poll count
set -eu
R=${1:?usage: panel-speed.sh CHROOT_DIR [REPO]}
REPO=${2:-$(cd "$(dirname "$0")/../.." && pwd)}
[ -x "$R/usr/bin/ucode" ] || { echo "panel-speed: $R is not an image root" >&2; exit 1; }
TMP=$R/tmp
mkdir -p "$TMP"
cat > "$TMP/panel-speed-inner.sh" <<'INNER'
#!/bin/sh
set -u
POLLS=${MU300_PANEL_POLLS:-120}
U=/var/run/ubus/ubus.sock
pkill -f '^/sbin/ubusd' 2>/dev/null || true
pkill -f '^/sbin/rpcd' 2>/dev/null || true
rm -f "$U"
mkdir -p /var/run/ubus
/sbin/ubusd -s "$U" &
sleep 1
MU300_PANEL_STATUS_TTL=1.5 MU300_DASH_CACHE_TTL=2 /sbin/rpcd 2>/dev/null &
sleep 3
ubus list 2>/dev/null | grep -qx mu300status || { echo "PANEL FAILED no mu300status object"; exit 1; }
# the first call makes rpcd load the ucode providers; never part of the numbers
ubus call mu300status status '{"slot":"0"}' >/dev/null 2>&1
now_cs() { cut -d' ' -f1 /proc/uptime | tr -d '.'; }
cpu_line() { sed -n '1p' /proc/stat; }
SAMPLES=/tmp/panel-speed-samples
: > "$SAMPLES"
fails=0; errs=0; nulls=0; i=0
CPU0=$(cpu_line)
while [ $i -lt "$POLLS" ]; do
    t0=$(now_cs)
    if ubus call mu300status status '{"slot":"0"}' > /tmp/panel-speed-one.json 2>/dev/null; then
        t1=$(now_cs)
        echo $(( (t1 - t0) * 10 )) >> "$SAMPLES"
        e=$(jsonfilter -i /tmp/panel-speed-one.json -e '@.error' 2>/dev/null)
        # an absent key prints nothing; only a present, non-null error counts
        if [ -n "$e" ] && [ "$e" != "null" ]; then errs=$((errs+1)); fi
        case $(jsonfilter -i /tmp/panel-speed-one.json -e '@.cell' 2>/dev/null) in
            ''|null) nulls=$((nulls+1)) ;; esac
    else
        t1=$(now_cs); fails=$((fails+1)); echo $(( (t1 - t0) * 10 )) >> "$SAMPLES"
    fi
    i=$((i+1))
done
CPU1=$(cpu_line)
sort -n "$SAMPLES" > "$SAMPLES.sorted"
awk -v n="$POLLS" '{ a[NR] = $1; sum += $1 }
    END {
        if (NR == 0) { print "PANEL median_ms=NA p95_ms=NA max_ms=NA min_ms=NA"; exit }
        med = a[int((NR + 1) / 2)]; p95 = a[int(NR * 0.95) < 1 ? 1 : int(NR * 0.95)]
        printf "PANEL median_ms=%d p95_ms=%d max_ms=%d min_ms=%d avg_ms=%d\n", med, p95, a[NR], a[1], sum / NR
    }' "$SAMPLES.sorted"
set -- $CPU0
t0=0; for v in "$@"; do t0=$((t0 + v)); done
idle0=$5
set -- $CPU1
t1=0; for v in "$@"; do t1=$((t1 + v)); done
idle1=$5
busy=0; dt=$((t1 - t0)); di=$((idle1 - idle0))
[ "$dt" -gt 0 ] && busy=$(( (dt - di) * 100 / dt ))
load1=$(cut -d' ' -f1 /proc/loadavg)
echo "PANEL polls=$POLLS fails=$fails errors=$errs null_cells=$nulls"
echo "PANEL resolution_ms=10 load1=$load1 cpu_busy_pct=$busy"
# the reply copies: two calls inside one TTL answer the same bytes and leave a cache file
pkill -f '^/sbin/rpcd' 2>/dev/null || true
sleep 1
rm -rf /run/mu300-dash-cache /run/mu300/panel-status-0.json
MU300_PANEL_STATUS_TTL=60 MU300_DASH_CACHE_TTL=60 /sbin/rpcd 2>/dev/null &
sleep 3
ubus call mu300status status '{"slot":"0"}' > /tmp/cache-a.json 2>/dev/null
ubus call mu300status status '{"slot":"0"}' > /tmp/cache-b.json 2>/dev/null
same=no; cmp -s /tmp/cache-a.json /tmp/cache-b.json && same=yes
cached=no; [ -s /run/mu300/panel-status-0.json ] && cached=yes
echo "PANEL status_cache same=$same file=$cached"
for m in cpu_get sms_list traffic_get lock_get; do
    ubus call mu300dash $m '{}' > /tmp/cache-a.json 2>/dev/null
    ubus call mu300dash $m '{}' > /tmp/cache-b.json 2>/dev/null
    same=no; cmp -s /tmp/cache-a.json /tmp/cache-b.json && same=yes
    echo "PANEL cache method=$m same=$same"
done
if [ -d /run/mu300-dash-cache ]; then
    echo "PANEL dash_cache files=$(ls /run/mu300-dash-cache | wc -l)"
else
    echo "PANEL dash_cache files=0"
fi
echo "PANEL DONE"
INNER
chmod 755 "$TMP/panel-speed-inner.sh"
RUNTIME=${MU300_VERIFY_RUNTIME:-direct}
case $RUNTIME in
    docker)
        docker run --rm --privileged --platform linux/arm64 -e MU300_PANEL_POLLS -v "$R:/rfs" "${MU300_VERIFY_DOCKER_IMAGE:-ubuntu:24.04}" \
            /bin/sh -c "mount -t proc proc /rfs/proc; mount -t sysfs sys /rfs/sys; mount --bind /dev /rfs/dev; exec chroot /rfs /bin/sh /tmp/panel-speed-inner.sh" ;;
    direct)
        sudo MU300_PANEL_POLLS="${MU300_PANEL_POLLS:-120}" sh -c "
            mount -t proc proc \"$R/proc\" || exit 1
            mount -t sysfs sys \"$R/sys\" || exit 1
            mount --bind /dev \"$R/dev\" || exit 1
            chroot \"$R\" /bin/sh /tmp/panel-speed-inner.sh
            rc=\$?
            umount \"$R/dev\" 2>/dev/null || true
            umount \"$R/sys\" 2>/dev/null || true
            umount \"$R/proc\" 2>/dev/null || true
            exit \$rc
        " ;;
    *) echo "MU300_VERIFY_RUNTIME must be direct or docker" >&2; exit 1 ;;
esac
