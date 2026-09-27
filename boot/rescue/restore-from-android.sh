#!/bin/sh
# ═══════════════════════════════════════════════════════════════
#  MU300 / F50 — rootfs 恢复脚本(★ 正确的流程,踩过坑的 ★)
#
#  为什么不直接 ssh 进 Linux 里 dd?
#    ★ 因为那样写的是【正在使用的文件系统】!!
#      内核的脏页回写会把你刚写的数据覆盖掉 → 分区变 0xFF(我们实际踩过)
#
#  正确姿势:
#    ① 让设备进【安卓】(或 initramfs)—— 那时 rootfs 没被挂载
#    ② 从安卓用 adb+su 写(最干净,还快:151MB/s)
#    ③ 写完必须 e2fsck 洗一遍
#    ④ 武装 slot b → 重启
# ═══════════════════════════════════════════════════════════════
# 用法(在主机上跑,设备已启动到安卓):
#   ./restore-from-android.sh check         只检查不写
#   ./restore-from-android.sh <镜像路径>     写进去(会二次确认)
#
set -e

IMG="$1"
ROOTPART=/dev/block/mmcblk0p54     # = fulldumpbox 分区,就是 Linux rootfs

echo "=== ① 检查 adb ==="
adb devices | tail -n +2 | grep -q device || { echo "✗ adb 连不上安卓"; exit 1; }
echo "  ✓ 设备在线"

echo "=== ② 检查 root ==="
adb shell su -c id 2>/dev/null | grep -q 'uid=0' || { echo "✗ 安卓没有 root"; exit 1; }
echo "  ✓ 有 root"

echo "=== ③ 确认目标分区 ==="
adb shell su -c "ls -la /dev/block/by-name/fulldumpdb; blockdev --getsize64 $ROOTPART" 2>&1 | sed 's/^/  /'

if [ "$IMG" = "check" ] || [ -z "$IMG" ]; then
    echo
    echo "check 模式,不动任何东西。"
    echo "正式恢复请用: $0 <镜像路径>"
    echo "例如: $0 /home/qc233/zte/backups/rootfs-CLEAN.img.gz"
    exit 0
fi

[ -f "$IMG" ] || { echo "✗ 找不到 $IMG"; exit 1; }
SZ=$(stat -c%s "$IMG" 2>/dev/null || wc -c < "$IMG")
echo
echo "★★★ 即将把 $IMG ($SZ 字节) 写入 $ROOTPART ★★★"
echo "    这会完全覆盖当前 rootfs!"
printf "    确认?输入 yes: "
read a
[ "$a" = "yes" ] || { echo "已取消"; exit 0; }

echo "=== ④ 推送到设备(快) ==="
adb push "$IMG" /data/local/tmp/rootfs-restore.img.gz

echo "=== ⑤ ★ 写入(从安卓,rootfs 未挂载)★ ==="
# ★ 注意:不要加 conv=fsync —— 安卓的 toybox dd 不认,会写出 0 字节(实际踩过)
adb shell su -c "gzip -dc /data/local/tmp/rootfs-restore.img.gz | dd of=$ROOTPART bs=4M"
adb shell su -c "sync; sync"

echo "=== ⑥ ★ 洗一遍文件系统(必须!)★ ==="
echo "  原因:live 快照的 ext4 日志可能是坏的,不修会挂不上"
adb shell su -c "e2fsck -fy $ROOTPART" 2>&1 | tail -12 | sed 's/^/    /'

echo "=== ⑦ 验证魔数(应为 53ef) ==="
adb shell su -c "dd if=$ROOTPART bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1" | sed 's/^/  /'

echo "=== ⑧ 武装 slot b(用现成的 32 字节) ==="
BC=/home/qc233/zte/mu300-work/boot-linux-nocfi.misc-slot-b-trial.bin
if [ -f "$BC" ]; then
    adb push "$BC" /data/local/tmp/bc.bin >/dev/null
    adb shell su -c "dd if=/data/local/tmp/bc.bin of=/dev/block/by-name/misc bs=1 seek=2048 conv=notrunc && sync"
    echo "  ✓ 已武装"
else
    echo "  ⚠ 找不到 $BC,需要手动武装 slot b"
fi

echo
echo "★★★ 完成!现在拔插 USB 或重启进 Linux ★★★"
echo "    安卓里执行:adb reboot"
