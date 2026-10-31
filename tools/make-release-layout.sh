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