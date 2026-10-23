# Release layout (upstream-compatible)

`tools/make-release-layout.sh ROOTFS OUTDIR [TREE]` produces a release in the layout upstream's
`mu300-update` consumes, so our releases can be applied by the stock updater.

| our Magisk layout | upstream layout asset | notes |
|---|---|---|
| `mu300-immortalwrt-<ver>-rootfs.tar.gz` | `mu300-openwrt-rootfs.tar.gz` | same tree + a `./features` marker (`sdcard`, `gpt-root`; **not** `linux-slot`, we install on slot b only) |
| `mu300-update` (from the tree) | `mu300-update` | the updater script itself, so a device can switch to it before changing anything |
| `boot-linux.img` (64 MiB flashable) | **open gap**: `mu300-kernel-7.2.tar.gz` needs `./Image` + `./lib/modules/7.2.8` + `./features` | the kernel side is not derivable from the flashable image; a bundle needs the kernel build's `Image` and ramdisk segment. Until that exists, releases carry the rootfs + updater only, and the kernel is updated by the Magisk path. |
| `SHA256SUMS` | `SHA256SUMS` | over every asset |

## Built 2026-10-24 (from rootfs `aad9ca47`)

| asset | size | sha256 |
|---|---|---|
| `mu300-openwrt-rootfs.tar.gz` | 29,081,189 B | `5e3ed2aad4644410a9e53e33a8f96b73935a33023b30ea874b5672f13564783a` |
| `mu300-update` | 281,070 B | `79048d1c04722f2d628adb180b387f785b03598bdad9a5998304470d589ef12c` |
