# Release layout (upstream-compatible)

`tools/make-release-layout.sh ROOTFS OUTDIR [TREE]` produces a release in the layout upstream's
`mu300-update` consumes, so our releases can be applied by the stock updater.

| our Magisk layout | upstream layout asset | notes |
|---|---|---|
| `mu300-immortalwrt-<ver>-rootfs.tar.gz` | `mu300-immortalwrt-rootfs.tar.gz` | same tree + a `./features` marker (`sdcard`, `gpt-root`; **not** `linux-slot`, we install on slot b only). The asset name is the image's identity, `immortalwrt`, as the image's own `etc/mu300/image-manifest.gz` head says; a system in a legacy `openwrt`/`openwrt-luci` directory takes it too (`mu300-update` `rootfs_asset`) |
| `mu300-update` (from the tree) | `mu300-update` | the updater script itself, so a device can switch to it before changing anything |
| `boot-linux.img` (64 MiB flashable) | **open gap**: `mu300-kernel-7.2.tar.gz` needs `./Image` + `./lib/modules/7.2.8` + `./features` | the kernel side is not derivable from the flashable image; a bundle needs the kernel build's `Image` and ramdisk segment. Until that exists, releases carry the rootfs + updater only, and the kernel is updated by the Magisk path. |
| `SHA256SUMS` | `SHA256SUMS` | over every asset |

## The image must carry the updater's helper

`make-release-layout.sh` builds (or takes `MU300_CARRY`) a static AArch64 `opt/mu300/bin/mu300-carry` and copies it
into the image **before** `etc/mu300/image-manifest.gz` is made and the rootfs tarball is packed, so the manifest knows
it is one of the image's own files. With it in the image, an update **to** this image carries every file of the user's
over (`carry_ready`) and delta updates work; without it only the old keep-list could be kept. Since v2026.11.08.2 an
image without it is **refused**: `mu300-update apply` says the image does not bring what carries the files over and
changes nothing, unless the old behaviour is asked for on purpose with `MU300_UPDATE_KEEP=list` (which then also writes
`etc/mu300/update-report` naming what that replaces).

The layout then runs `tools/check-update-audit.sh` on the finished rootfs asset: the helper is there, executable,
static and AArch64 (an x86-64 helper built on an amd64 host is refused), the updater and `etc/mu300/image-manifest.gz`
are there, the image carries exactly the unions it ships, the regulatory database pair verifies
(`tools/check-regdb.sh`), and `tools/image-manifest.py check` passes. `tools/make-release.sh` runs the same script
for its images.

## The image must carry a signed regulatory database

`make-release-layout.sh` copies the signed pair of the wireless-regdb release — `lib/firmware/regulatory.db` and
`lib/firmware/regulatory.db.p7s` from `rootfs/overlay/lib/firmware` — over the upgraded image, and
`tools/check-update-audit.sh` runs `tools/check-regdb.sh` on the finished rootfs asset: the pair must verify
(`openssl smime -verify`). The kernel is built with `CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y`, so an image carrying a
database with another version signature boots with the world regdomain (5 GHz ch36 NO-IR, hostapd AP-DISABLED: the
v2026.11.08.5 device test). The wireless-regdb package ships only `regulatory.db`, so the package upgrade replaces the
database and leaves the signature of the image it was relabelled from behind; the tree carries the pair of the release
itself (2026.09.03, signed by CN=wens).

## Built 2026-10-24 (from rootfs `aad9ca47`)

| asset | size | sha256 |
|---|---|---|
| `mu300-openwrt-rootfs.tar.gz` | 29,081,189 B | `5e3ed2aad4644410a9e53e33a8f96b73935a33023b30ea874b5672f13564783a` |
| `mu300-update` | 281,070 B | `79048d1c04722f2d628adb180b387f785b03598bdad9a5998304470d589ef12c` |
