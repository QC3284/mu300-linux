#!/bin/sh
# add-theme-variant.sh STAGE <aurora|argon> - install a theme into a rootfs stage (the VARIANT build step).
#
# One theme per image: a variant carries its own theme, sets luci.main.mediaurlbase to it, and the image marker
# /etc/mu300/image-theme names it. Switching variants on a device is then an update, not a runtime toggle.
#
# aurora: already in the base image - only mediaurlbase is asserted.
# argon:  luci-theme-argon + luci-app-argon-config + luci-i18n-argon-config-zh-cn are installed into the stage.
#         apk-tools 3 is required: the 25.12 packages are in the v3 "ADBd" format that apk 2.x cannot read (verified:
#         apk-tools 2.14.4 answers "IO ERROR"), which is why this step runs in CI, not on a maintainer desktop.
set -eu
STAGE=${1:?usage: tools/add-theme-variant.sh STAGE <aurora|argon>}
THEME=${2:?usage: tools/add-theme-variant.sh STAGE <aurora|argon>}
FEED=${MU300_FEED_URL:-https://mirrors.ustc.edu.cn/immortalwrt/releases/25.12.2/packages/aarch64_generic/luci}
ARCH=${MU300_ARCH:-aarch64_generic}
case $THEME in aurora|argon) ;; *) echo "theme must be aurora or argon" >&2; exit 1 ;; esac
if [ "$THEME" = argon ]; then
    command -v apk >/dev/null 2>&1 || { echo "apk-tools 3 is needed for the argon packages" >&2; exit 1; }
    apk --root "$STAGE" --arch "$ARCH" --allow-untrusted --repository "$FEED" \
        --keys-dir "$STAGE/etc/apk/keys" --initdb --no-scripts \
        add luci-theme-argon luci-app-argon-config luci-i18n-argon-config-zh-cn
fi
[ -d "$STAGE/www/luci-static/$THEME" ] || { echo "$STAGE has no /www/luci-static/$THEME" >&2; exit 1; }
C="$STAGE/etc/config/luci"
if [ -f "$C" ]; then
    sed -i "s#option mediaurlbase .*#option mediaurlbase '/luci-static/$THEME'#" "$C"
    grep -q "mediaurlbase '/luci-static/$THEME'" "$C" || printf "\toption mediaurlbase '/luci-static/%s'\n" "$THEME" >> "$C"
fi
echo "theme $THEME installed into $STAGE (mediaurlbase /luci-static/$THEME)"
