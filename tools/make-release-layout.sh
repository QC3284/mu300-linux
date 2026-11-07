#!/bin/bash
# Build a release in the UPSTREAM layout so upstream's mu300-update can consume it:
#   mu300-immortalwrt-rootfs.tar.gz   our rootfs, plus ./features (capability marker)
#   mu300-kernel-7.2.tar.gz       kernel bundle (./Image + ./ramdisk-generic.lz4 + ./modules + ./devices + ./features)
#                                   when an Image (IMAGE_FILE) and a generic ramdisk (RAMDISK_GENERIC) are available
#   mu300-update                  the updater script from this tree
#   SHA256SUMS                    every asset
# Mapping: our Magisk layout -> upstream layout
#   mu300-immortalwrt-<ver>-rootfs.tar.gz -> mu300-immortalwrt-rootfs.tar.gz (byte-identical payload + ./features;
#   the asset name is the image's identity, immortalwrt, which the installed image's own manifest head says too)
#   boot-linux.img                          -> stays a Magisk/installer asset; the kernel bundle needs ./Image
#                                              (IMAGE_FILE) and ./ramdisk-generic.lz4 (RAMDISK_GENERIC, built with
#                                              build-boot-image.py --generic-ramdisk)
#!/bin/bash
set -eu
ROOTFS=${1:?rootfs tar}
# Pin the input: with MU300_ROOTFS_SHA256 set, only that exact tarball may be packed, so a stale build in the
# same directory cannot slip into a release (it did once: the module was cut with the p4 rootfs).
PIN=${MU300_ROOTFS_SHA256:-}
if [ -n "$PIN" ]; then
    got=$(sha256sum "$ROOTFS" | cut -d" " -f1)
    [ "$got" = "$PIN" ] || { echo "rootfs mismatch: $ROOTFS is $got, pinned $PIN" >&2; exit 1; }
    echo "rootfs pinned: $PIN"
fi
OUT=${2:?outdir}
THEME=${MU300_THEME:-aurora}   # aurora (default) or argon; the marker the updater filters on
TAG="$MU300_TAG"   # sets image-version + manifest head to the release tag
TREE=${3:-/tmp/sync-wt}
rm -rf "$OUT" && mkdir -p "$OUT/stage"
echo '== rootfs asset =='
mkdir -p "$OUT/r"
tar -xzf "$ROOTFS" -C "$OUT/r"
printf 'sdcard\ngpt-root\ntheme=%s\n' "$THEME" > "$OUT/r/features"
# The boot directory's tag names the release the kernel came from; the panel offers an update while it differs from the
# installed image-version. A release that ships a boot image writes it here.
mkdir -p "$OUT/r/boot"
printf '%s\n' "$TAG" > "$OUT/r/boot/installed.tag"
printf '%s\n' "$THEME" > "$OUT/r/etc/mu300/image-theme"
# Two entries that do not belong on this device: the attended-sysupgrade page and the stock Terminal (ours is
# admin/system/terminal). Removing them here makes it deterministic, not first-boot dependent.
rm -f "$OUT/r/usr/share/luci/menu.d/luci-app-attendedsysupgrade.json" \
      "$OUT/r/usr/share/luci/menu.d/luci-app-ttyd.json"
# Two entries that do not belong: the attended-sysupgrade page and the stock Terminal (ours is admin/system/terminal).
rm -f "$OUT/r/usr/share/luci/menu.d/luci-app-attendedsysupgrade.json" "$OUT/r/usr/share/luci/menu.d/luci-app-ttyd.json"
# The image carries the union manifest of its own image name (opt/mu300/lib/image-manifests, tools/image-manifest.py
# union): the file an update uses to carry a system whose own image has no manifest. The tree's is the newest (it holds
# every release of this image name, this one included: it is made from the image once the image is built, so building
# this release a second time puts this release's lines into the image); the input image's other union files stay as
# they are. An image built without it still updates; a system whose image has its own manifest - every release from
# v2026.10.16 on - needs no union. It is copied before the manifest is made: the image carries its own manifest of
# every file it holds, so a file that comes after that would be one its manifest does not know.
_iu="$TREE/rootfs/overlay/opt/mu300/lib/image-manifests/immortalwrt.gz"
if [ -f "$_iu" ]; then
    mkdir -p "$OUT/r/opt/mu300/lib/image-manifests"
    cp "$_iu" "$OUT/r/opt/mu300/lib/image-manifests/immortalwrt.gz"
fi
# The image carries the updater of this release, the same file as the mu300-update asset: the updater an installed
# system runs is the image's (apply hands its run over to the release's, but what the next boot starts is the image's),
# so an image relabelled from an older one would send devices back to the updater of that older release. It comes before
# the manifest for the same reason as the union above: the image's manifest lists every file it holds.
_uu="$TREE/rootfs/overlay/opt/mu300/bin/mu300-update"
if [ -f "$_uu" ]; then
    mkdir -p "$OUT/r/opt/mu300/bin"
    cp "$_uu" "$OUT/r/opt/mu300/bin/mu300-update"
    chmod 755 "$OUT/r/opt/mu300/bin/mu300-update"
fi
# The image carries this tree's release source, the file the updater reads before it asks anything: an image
# relabelled from an older one would otherwise hand a fresh install the old chain (gh-proxy first, whose Range
# probe the release check makes answers 000), and an update carries /etc/mu300 over from the installed system, so
# the file an image carried is the one devices keep. Last in this group, before the manifest.
_uc="$TREE/rootfs/overlay/etc/mu300/update-source"
if [ -f "$_uc" ]; then
    mkdir -p "$OUT/r/etc/mu300"
    cp "$_uc" "$OUT/r/etc/mu300/update-source"
fi
# The image carries the AT client and the SIM-slot files of this release, again because the rootfs input is a
# prebuilt image: mu300-at is where a slot-1 request with no slot-1 reader is answered instead of opening the
# active card's tty, the uci-defaults script gives an updated device (whose /etc/config the update keeps) the
# sim_slots option the panel's slot-1 objects key off, and the SMS daemon init only starts its second
# instance where a slot-1 AT reader exists. All three come before the manifest for the same reason as above.
for _of in "opt/mu300/bin/mu300-at" "etc/uci-defaults/94-mu300-sim-slots" "etc/init.d/mu300-smsd"; do
    [ -f "$TREE/rootfs/overlay/$_of" ] || { echo "overlay file missing from the tree: $_of" >&2; exit 1; }
    mkdir -p "$OUT/r/$(dirname "$_of")"
    cp "$TREE/rootfs/overlay/$_of" "$OUT/r/$_of"
    chmod "$([ "${_of#etc/uci-defaults/}" != "$_of" ] && echo 644 || echo 755)" "$OUT/r/$_of"
done
# The rpcd providers the tree owns (the UFI panel's objects and the unisoc-* settings): copied from the tree
# like the updater above, because the rootfs input is a prebuilt image and a relabelled image cannot grow new
# files. The list is explicit so a missing one fails the build instead of shipping a quietly half-complete
# image; it comes before the manifest for the same reason as the files above.
# data-sim is on the list although the image already has it: the base image carries the adapter
# non-executable (the package's own chmod list sets the mode in images built from this tree, the relabelled
# base image keeps the mode it was built with), and the panel's data_sim_get runs it as a program. The tree's
# copy is byte-identical; it is copied for the mode.
# The rpcd providers and adapters the UFI panel needs (its objects, the author's shapes, and the
# SIM/CPU/radio helpers behind them): copied from the tree, because the rootfs input is a prebuilt
# image and a relabelled image cannot grow new files. The list is explicit so a missing file fails
# the build instead of shipping a quietly half-complete image. data-sim is on it although the image
# already has it: the base image carries the adapter non-executable, and the panel runs it as a
# program. Every file here is the tree's, so the image and the package agree.
# The image carries the tree's cpuinfo: the stock one reads the x86 "model name" and prints "? x 8" on this
# arm64 SoC; the tree's names the cores from their CPU part (the format the user picked). The rootfs input
# is a prebuilt image, so a relabelled image would keep the stock script and the fix would never reach a release.
_ucpu="$TREE/rootfs/overlay/sbin/cpuinfo"
if [ -f "$_ucpu" ]; then
    mkdir -p "$OUT/r/sbin"
    cp "$_ucpu" "$OUT/r/sbin/cpuinfo"
    chmod 755 "$OUT/r/sbin/cpuinfo"
fi
P=$TREE/openwrt/luci-app-mu300/root
for _pf in \
    usr/libexec/rpcd/mu300dash \
    usr/libexec/rpcd/mu300-charge \
    usr/libexec/rpcd/unisoc-cpu-cores usr/libexec/rpcd/unisoc-cpu-idle usr/libexec/rpcd/unisoc-network-performance \
    usr/libexec/unisoc-modem/cpu-cores usr/libexec/unisoc-modem/cpu-cores.uc \
    usr/libexec/unisoc-modem/cpu-idle usr/libexec/unisoc-modem/cpu-idle.uc \
    usr/libexec/unisoc-modem/network-performance usr/libexec/unisoc-modem/network-performance.uc \
    usr/libexec/unisoc-modem/data-sim usr/libexec/unisoc-modem/dashboard-rates \
    usr/libexec/unisoc-modem/apn usr/libexec/unisoc-modem/apn.uc \
    usr/libexec/unisoc-modem/sms-forward usr/libexec/unisoc-modem/device-usb \
    usr/libexec/unisoc-modem/charge.uc \
    usr/libexec/unisoc-modem/cpu-policy usr/libexec/unisoc-modem/cpu-policy.uc \
    usr/libexec/unisoc-modem/cpu-voltage-panel usr/libexec/unisoc-modem/cpu-voltage-panel.uc \
    usr/libexec/unisoc-modem/dashboard-equipment \
    usr/libexec/unisoc-modem/wifi-ciphers usr/libexec/unisoc-modem/wifi-ciphers.uc \
    usr/libexec/unisoc-modem/panel-cpu-get usr/libexec/unisoc-modem/panel-cpu-voltage-get \
    usr/libexec/unisoc-modem/traffic usr/libexec/unisoc-modem/traffic-mu300 \
    usr/libexec/unisoc-modem/cell usr/libexec/unisoc-modem/cell-kick \
    usr/share/rpcd/ucode/mu300rates.uc usr/share/rpcd/ucode/mu300status.uc \
    usr/share/ucode/mu300/info.uc usr/share/ucode/mu300/rates.uc \
    usr/share/rpcd/acl.d/luci-app-mu300.json \
    usr/share/rpcd/acl.d/unisoc-cpu-cores.json usr/share/rpcd/acl.d/unisoc-cpu-idle.json \
    usr/share/rpcd/acl.d/unisoc-network-performance.json usr/share/rpcd/acl.d/mu300-wifi-ciphers.json \
    etc/config/unisoc_modem \
    opt/mu300/bin/mu300-sim-radio opt/mu300/bin/mu300-radio-allowed opt/mu300/bin/mu300-v50-sim \
    opt/mu300/lib/v50-card.sh; do
    [ -f "$P/$_pf" ] || { echo "provider file missing from the tree: $_pf" >&2; exit 1; }
    mkdir -p "$OUT/r/$(dirname "$_pf")"
    cp "$P/$_pf" "$OUT/r/$_pf"
done
# the adapters and plugins run as programs (the .uc modules are data)
chmod 755 "$OUT/r/usr/libexec/rpcd/mu300dash" "$OUT/r/usr/libexec/rpcd/mu300-charge" \
    "$OUT/r/usr/libexec/rpcd/unisoc-cpu-cores" "$OUT/r/usr/libexec/rpcd/unisoc-cpu-idle" \
    "$OUT/r/usr/libexec/rpcd/unisoc-network-performance" \
    "$OUT/r/usr/libexec/unisoc-modem/cpu-cores" "$OUT/r/usr/libexec/unisoc-modem/cpu-idle" \
    "$OUT/r/usr/libexec/unisoc-modem/network-performance" "$OUT/r/usr/libexec/unisoc-modem/data-sim" \
    "$OUT/r/usr/libexec/unisoc-modem/apn" "$OUT/r/usr/libexec/unisoc-modem/sms-forward" \
    "$OUT/r/usr/libexec/unisoc-modem/device-usb" "$OUT/r/usr/libexec/unisoc-modem/cpu-policy" \
    "$OUT/r/usr/libexec/unisoc-modem/cpu-voltage-panel" "$OUT/r/usr/libexec/unisoc-modem/dashboard-equipment" \
    "$OUT/r/usr/libexec/unisoc-modem/wifi-ciphers" "$OUT/r/usr/libexec/unisoc-modem/panel-cpu-get" \
    "$OUT/r/usr/libexec/unisoc-modem/panel-cpu-voltage-get" "$OUT/r/usr/libexec/unisoc-modem/traffic" \
    "$OUT/r/usr/libexec/unisoc-modem/traffic-mu300" \
    "$OUT/r/usr/libexec/unisoc-modem/cell" "$OUT/r/usr/libexec/unisoc-modem/cell-kick" \
    "$OUT/r/usr/libexec/unisoc-modem/dashboard-rates" \
    "$OUT/r/opt/mu300/bin/mu300-sim-radio" "$OUT/r/opt/mu300/bin/mu300-radio-allowed" \
    "$OUT/r/opt/mu300/bin/mu300-v50-sim"
if [ -n "$TAG" ]; then
    printf '%s\n' "$TAG" > "$OUT/r/etc/mu300/image-version"
    tar --owner=0 --group=0 -czf "$OUT/manifest-stage.tar.gz" -C "$OUT/r" .
    python3 "$TREE/tools/image-manifest.py" make "$OUT/manifest-stage.tar.gz" immortalwrt "$TAG" 2>/dev/null | gzip -9 > "$OUT/r/etc/mu300/image-manifest.gz"
    rm -f "$OUT/manifest-stage.tar.gz"
fi
chmod 644 "$OUT/r/features"
tar --owner=0 --group=0 -czf "$OUT/mu300-immortalwrt-rootfs.tar.gz" -C "$OUT/r" .
rm -rf "$OUT/r"
echo "  mu300-immortalwrt-rootfs.tar.gz $(stat -c%s "$OUT/mu300-immortalwrt-rootfs.tar.gz") B"
echo '== updater asset =='
cp "$TREE/rootfs/overlay/opt/mu300/bin/mu300-update" "$OUT/mu300-update"
chmod 755 "$OUT/mu300-update"
echo '== kernel bundle =='
if [ -n "${IMAGE_FILE:-}" ]; then
    [ -f "$IMAGE_FILE" ] || { echo "IMAGE_FILE $IMAGE_FILE does not exist" >&2; exit 1; }
    # The updater's boot subcommand consumes the UPSTREAM bundle layout: ./Image, ./ramdisk-generic.lz4,
    # ./kernel.release, a flat ./modules/, ./devices and ./features. The legacy layout (./lib/modules and a
    # features file without sdcard) is not consumable: boot would refuse the bundle. The generic ramdisk is
    # built separately with build-boot-image.py --generic-ramdisk; a bundle without it cannot boot-update.
    [ -n "${RAMDISK_GENERIC:-}" ] && [ -f "$RAMDISK_GENERIC" ] || { echo "RAMDISK_GENERIC is required with IMAGE_FILE (build it with build-boot-image.py --generic-ramdisk)" >&2; exit 1; }
    KREL=${KERNEL_RELEASE:-$(tar -tzf "$ROOTFS" | sed -n 's|^\./lib/modules/\([^/]\+\)/\?$|\1|p' | head -n1)}
    [ -n "$KREL" ] || { echo "cannot derive kernel.release from $ROOTFS" >&2; exit 1; }
    mkdir -p "$OUT/k/modules"
    cp "$IMAGE_FILE" "$OUT/k/Image"
    cp "$RAMDISK_GENERIC" "$OUT/k/ramdisk-generic.lz4"
    # build-boot-image.py writes the manifest next to --out with the suffix swapped (with_suffix('.json')):
    # ramdisk-generic.lz4 -> ramdisk-generic.json
    GJSON="${RAMDISK_GENERIC%.lz4}.json"
    [ -f "$GJSON" ] && cp "$GJSON" "$OUT/k/ramdisk-generic.json" || true
    printf '%s\n' "$KREL" > "$OUT/k/kernel.release"
    tar -xzf "$ROOTFS" -C "$OUT/k" "./lib/modules/$KREL" 2>/dev/null || true
    cp "$OUT/k/lib/modules/$KREL"/*.ko "$OUT/k/modules/" 2>/dev/null || true
    cp "$OUT/k/lib/modules/$KREL"/modules.builtin "$OUT/k/lib/modules/$KREL"/modules.builtin.modinfo "$OUT/k/" 2>/dev/null || true
    rm -rf "$OUT/k/lib"
    printf '%s\n' "${MU300_DEVICES:-f50 u30air v50}" > "$OUT/k/devices"
    printf 'sdcard\nlinux-slot\ngpt-root\n' > "$OUT/k/features"
    tar --owner=0 --group=0 -czf "$OUT/mu300-kernel-7.2.tar.gz" -C "$OUT/k" .
    rm -rf "$OUT/k"
    echo "  mu300-kernel-7.2.tar.gz $(stat -c%s "$OUT/mu300-kernel-7.2.tar.gz") B"
else
    echo '  SKIPPED: no Image file (see the mapping note: our boot-linux.img is a flashable image, not Image+ramdisk)'
fi
echo '== SHA256SUMS =='
cd "$OUT" && sha256sum mu300-immortalwrt-rootfs.tar.gz mu300-update ${IMAGE_FILE:+mu300-kernel-7.2.tar.gz} 2>/dev/null | tee SHA256SUMS | sed 's/^/  /'
ls -l "$OUT" | sed 's/^/  /'