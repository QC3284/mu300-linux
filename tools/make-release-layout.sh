#!/bin/bash
# Build a release in the UPSTREAM layout so upstream's mu300-update can consume it:
#   mu300-openwrt-rootfs.tar.gz   our rootfs, plus ./features (capability marker)
#   mu300-kernel-7.2.tar.gz       kernel bundle (./Image + ./lib/modules + ./features) when an Image is available
#   mu300-update                  the updater script from this tree
#   SHA256SUMS                    every asset
# Mapping: our Magisk layout -> upstream layout
#   mu300-immortalwrt-25.12.2-rootfs.tar.gz -> mu300-openwrt-rootfs.tar.gz (byte-identical payload + ./features)
#   boot-linux.img                          -> stays a Magisk/installer asset; the kernel bundle needs ./Image,
#                                              which is NOT derivable from the flashable image (open gap) 
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
if [ -n "$TAG" ]; then
    printf '%s\n' "$TAG" > "$OUT/r/etc/mu300/image-version"
    tar --owner=0 --group=0 -czf "$OUT/manifest-stage.tar.gz" -C "$OUT/r" .
    python3 "$TREE/tools/image-manifest.py" make "$OUT/manifest-stage.tar.gz" openwrt-luci "$TAG" 2>/dev/null | gzip -9 > "$OUT/r/etc/mu300/image-manifest.gz"
    rm -f "$OUT/manifest-stage.tar.gz"
fi
chmod 644 "$OUT/r/features"
tar --owner=0 --group=0 -czf "$OUT/mu300-openwrt-rootfs.tar.gz" -C "$OUT/r" .
rm -rf "$OUT/r"
echo "  mu300-openwrt-rootfs.tar.gz $(stat -c%s "$OUT/mu300-openwrt-rootfs.tar.gz") B"
echo '== updater asset =='
cp "$TREE/rootfs/overlay/opt/mu300/bin/mu300-update" "$OUT/mu300-update"
chmod 755 "$OUT/mu300-update"
echo '== kernel bundle =='
if [ -n "${IMAGE_FILE:-}" ] && [ -f "$IMAGE_FILE" ]; then
    mkdir -p "$OUT/k/lib/modules" "$OUT/k/features.d"
    cp "$IMAGE_FILE" "$OUT/k/Image"
    tar -xzf "$ROOTFS" -C "$OUT/k" ./lib/modules/7.2.8 2>/dev/null || true
    printf 'linux-slot\ngpt-root\n' > "$OUT/k/features"
    tar --owner=0 --group=0 -czf "$OUT/mu300-kernel-7.2.tar.gz" -C "$OUT/k" .
    rm -rf "$OUT/k"
    echo "  mu300-kernel-7.2.tar.gz $(stat -c%s "$OUT/mu300-kernel-7.2.tar.gz") B"
else
    echo '  SKIPPED: no Image file (see the mapping note: our boot-linux.img is a flashable image, not Image+ramdisk)'
fi
echo '== SHA256SUMS =='
cd "$OUT" && sha256sum mu300-openwrt-rootfs.tar.gz mu300-update ${IMAGE_FILE:+mu300-kernel-7.2.tar.gz} 2>/dev/null | tee SHA256SUMS | sed 's/^/  /'
ls -l "$OUT" | sed 's/^/  /'