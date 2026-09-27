#!/system/bin/sh
# MU300: 在安卓里备份 Linux rootfs(rootfs 未挂载,备份 100% 一致)
# ★ 动态找 SD 卡路径,没有写死的 UUID ★
# ★ 带前置检查 + 完整验证 ★

LOG=/data/local/tmp/backup.log
echo "START $(date)" > $LOG

# ① 找 rootfs 分区:按名字找(安卓里叫 fulldumpdb)
ROOT=
for d in /dev/block/mmcblk0p54 /dev/block/by-name/fulldumpdb; do
    [ -b "$d" ] && { ROOT=$d; break; }
done
[ -n "$ROOT" ] || { echo "ERR: no rootfs partition" >> $LOG; exit 1; }
echo "rootfs: $ROOT" >> $LOG

# ② ★ 动态找 SD 卡路径:遍历 /mnt/media_rw/*,看哪个能写 ★
SDROOT=
for p in /mnt/media_rw/*; do
    [ -d "$p" ] || continue
    case "$p" in */usbdisk|*/self|*/emulated) continue;; esac
    # 试着创建目录,能成就说明可写
    if mkdir -p "$p/f50-backup" 2>/dev/null; then
        SDROOT=$p
        break
    fi
done
if [ -z "$SDROOT" ]; then
    echo "ERR: no writable SD card found under /mnt/media_rw" >> $LOG
    ls -la /mnt/media_rw/ >> $LOG 2>&1
    exit 1
fi
echo "SD root: $SDROOT" >> $LOG

OUT="$SDROOT/f50-backup/rootfs-shutdown.img.gz"
echo "output: $OUT" >> $LOG

# ③ 检查空间(至少要 1GB)
AVAIL=$(df -k "$SDROOT" 2>/dev/null | tail -1 | awk '{print $4}')
echo "available KB: $AVAIL" >> $LOG
if [ -n "$AVAIL" ] && [ "$AVAIL" -lt 1048576 ]; then
    echo "ERR: not enough space on SD" >> $LOG
    exit 1
fi

# ④ 备份
echo "dd starting..." >> $LOG
dd if="$ROOT" bs=4M 2>/dev/null | gzip -3 > "$OUT"
RC=$?
sync
echo "dd rc=$RC" >> $LOG
SZ=$(ls -la "$OUT" 2>/dev/null | awk '{print $5}')
echo "SIZE=$SZ" >> $LOG

# ⑤ ★ 立即验证:完整解压,字节数必须对 ★
echo "verifying (full decompress)..." >> $LOG
FULL=$(gzip -dc "$OUT" 2>/data/local/tmp/gzerr.txt | wc -c)
GERR=$(cat /data/local/tmp/gzerr.txt 2>/dev/null | head -1)
echo "DECOMPRESSED=$FULL" >> $LOG
echo "GZIP_ERR=$GERR" >> $LOG
if [ "$FULL" = "2147483648" ] && [ -z "$GERR" ]; then
    echo "VERIFY=OK" >> $LOG
else
    echo "VERIFY=FAIL (expected 2147483648)" >> $LOG
fi
echo "DONE $(date)" >> $LOG
