#!/bin/sh
# Post-build pass for the CI image: reproduce the host-side additions the device image needs.
# Usage: ci-postbuild.sh ROOTFS.tar.gz   (run as root on an arm64 runner)
set -eu
TAR=${1:?rootfs tar}
W=$(mktemp -d)
R=$W/root
mkdir -p "$R"
tar -xzf "$TAR" -C "$R"
echo "postbuild: unpacked $(find "$R" -type f | wc -l) files"

# --- DNS for apk inside the chroot, then the OpenWrt convention
rm -f "$R/etc/resolv.conf"
cp /etc/resolv.conf "$R/etc/resolv.conf"
mount -t proc proc "$R/proc" 2>/dev/null || true
mount --bind /dev "$R/dev" 2>/dev/null || true
chroot "$R" /bin/sh -c 'apk update >/dev/null 2>&1 || true; apk add openssh-server openssh-client openssh-sftp-server openssh-sftp-client' || echo 'postbuild: apk add failed'
umount "$R/dev" 2>/dev/null || true
umount "$R/proc" 2>/dev/null || true
rm -f "$R/etc/resolv.conf"
ln -sfn /tmp/resolv.conf "$R/etc/resolv.conf"
printf 'mu300\n' > "$R/etc/hostname"

# --- dropbear stays installed but never starts
rm -f "$R"/etc/rc.d/*dropbear* 2>/dev/null || true

# --- sshd: password login for root, autostart at 50
mkdir -p "$R/etc/ssh/sshd_config.d"
printf 'PermitRootLogin yes\nPasswordAuthentication yes\nKbdInteractiveAuthentication no\nAuthorizedKeysFile .ssh/authorized_keys\nPermitEmptyPasswords no\n' > "$R/etc/ssh/sshd_config.d/05-mu300-auth.conf"
chmod 644 "$R/etc/ssh/sshd_config.d/05-mu300-auth.conf"
ln -sf ../init.d/sshd "$R/etc/rc.d/S50sshd"

# --- root password: hash for 'password' with a numeric lastchg
HASH=$(openssl passwd -6 password)
DAYS=$(($(date +%s) / 86400))
awk -v h="$HASH" -v d="$DAYS" -F: 'BEGIN{OFS=":"} $1=="root"{$2=h;$3=d;$4=0;$5=99999;$6=7} {print}' "$R/etc/shadow" > "$R/etc/shadow.new"
mv "$R/etc/shadow.new" "$R/etc/shadow"
chmod 600 "$R/etc/shadow"

# --- sshd privsep dir (the image's /var is a symlink to /tmp)
mkdir -p "$R/tmp/empty"
chmod 0755 "$R/tmp/empty"

# --- attendedsysupgrade: no login-time update check
printf "config client 'client'\n\toption login_check_for_upgrades '0'\n" > "$R/etc/config/attendedsysupgrade"
chmod 644 "$R/etc/config/attendedsysupgrade"
cat > "$R/etc/uci-defaults/99-mu300-attendedsysupgrade-off" <<'EOF'
#!/bin/sh
uci -q get attendedsysupgrade.client >/dev/null 2>&1 || uci -q set attendedsysupgrade.client='client'
uci -q set attendedsysupgrade.client.login_check_for_upgrades='0'
uci -q commit attendedsysupgrade 2>/dev/null || true
exit 0
EOF
chmod 755 "$R/etc/uci-defaults/99-mu300-attendedsysupgrade-off"

# --- gates
grep -q '^PermitRootLogin yes$' "$R/etc/ssh/sshd_config.d/05-mu300-auth.conf"
[ -L "$R/etc/rc.d/S50sshd" ] || { echo 'postbuild: S50sshd missing' >&2; exit 1; }
[ -z "$(ls "$R"/etc/rc.d/*dropbear* 2>/dev/null)" ] || { echo 'postbuild: dropbear link present' >&2; exit 1; }
grep -q '^root:\$6\$' "$R/etc/shadow" || { echo 'postbuild: no root hash' >&2; exit 1; }
[ "$(awk -F: '$1=="root"{print $3}' "$R/etc/shadow")" -gt 19000 ] || { echo 'postbuild: lastchg not numeric' >&2; exit 1; }
[ -d "$R/tmp/empty" ] || { echo 'postbuild: tmp/empty missing' >&2; exit 1; }

# --- repack with root ownership
tar --owner=0 --group=0 -czf "$TAR" -C "$R" .
python3 - "$TAR" <<'PY'
import sys, tarfile
bad = 0
with tarfile.open(sys.argv[1]) as t:
    for m in t.getmembers():
        if m.uid != 0 or m.gid != 0:
            bad += 1
print('postbuild: non-root entries =', bad)
sys.exit(1 if bad else 0)
PY
rm -rf "$W"
echo 'postbuild: done'