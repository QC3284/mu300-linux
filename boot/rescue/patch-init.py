#!/usr/bin/env python3
import pathlib
p = pathlib.Path('/tmp/initramfs-live/init')
t = p.read_text()
orig = t
n = 0

old1 = 'log "stage=devfs-ready"'
if old1 in t and 'loglevel(fixed)' not in t:
    t = t.replace(old1, old1 + """
# MU300 local change: raise the console log level so the serial console and dmesg are useful.
# The device cmdline carries loglevel=1, which hides everything useful during a rescue.
echo 7 > /proc/sys/kernel/printk 2>/dev/null
echo "loglevel(fixed)" > /dev/kmsg 2>/dev/null""", 1)
    n += 1

old2 = '''if [ -n "$rootloop" ] && [ -b "$rootloop" ] \\
   && [ "$(dd if="$rootloop" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' ')" = 53ef ] \\
   && mount -t ext4 -o noatime "$rootloop" /disk 2>>/run/rootmount.err \\
   && rootdir=$(pick_root) && [ -n "$rootdir" ]; then'''
new2 = '''# MU300 local change: if the filesystem refuses to mount (typically a dirty journal after an
# unclean shutdown) run e2fsck once and retry. Without this the only way to repair the rootfs
# was to attach a computer and use the telnet shell by hand.
rootok=0
if [ -n "$rootloop" ] && [ -b "$rootloop" ] \\
   && [ "$(dd if="$rootloop" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' ')" = 53ef ]; then
    if mount -t ext4 -o noatime "$rootloop" /disk 2>>/run/rootmount.err; then
        rootok=1
    else
        log "stage=rootfs-mount-failed (running e2fsck)"
        umount /disk 2>/dev/null
        sync
        /usr/sbin/fsck.ext4 -fy "$rootloop" >> /run/fsck.log 2>&1
        log "stage=fsck-done (log /run/fsck.log)"
        sync
        if mount -t ext4 -o noatime "$rootloop" /disk 2>>/run/rootmount.err; then
            rootok=1
            log "stage=rootfs-mounted-after-fsck"
        fi
    fi
fi
if [ "$rootok" = 1 ] && rootdir=$(pick_root) && [ -n "$rootdir" ]; then'''
if old2 in t:
    t = t.replace(old2, new2, 1); n += 1
else:
    print('!! 2 no match')

old3 = 'log "stage=rootfs-unavailable $(cat /run/rootmount.err)"'
new3 = '''log "stage=rootfs-unavailable $(cat /run/rootmount.err)"
{
  echo "================ MU300 rescue ================"
  echo "rootfs part: $rootloop"
  if [ -n "$rootloop" ]; then
    echo "  size: $(blockdev --getsize64 "$rootloop" 2>/dev/null)"
    echo "  magic: $(dd if="$rootloop" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' ')"
    echo "  fsck log:"; sed 's/^/    /' /run/fsck.log 2>/dev/null | tail -15
  fi
  echo "mount error:"; sed 's/^/  /' /run/rootmount.err 2>/dev/null | tail -5
  echo "== rescue options =="
  echo "  1) restore from SD:     sd-restore"
  echo "  2) repair filesystem:   fsck.ext4 -fy $rootloop"
  echo "  3) keep Linux running:  touch /run/stay"
  echo "  4) back to Android:     reboot"
  echo "=============================================="
} > /run/www/index.html 2>/dev/null
cat /run/www/index.html > /dev/kmsg 2>/dev/null'''
if old3 in t:
    t = t.replace(old3, new3, 1); n += 1
else:
    print('!! 3 no match')

p.write_text(t)
print('changed:', n, 'places; lines', len(orig.split(chr(10))), '->', len(t.split(chr(10))))
