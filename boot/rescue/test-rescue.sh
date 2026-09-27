#!/bin/sh
# ★ 零风险:只在 /tmp 的测试文件上练 ★
ISO=/tmp/isochroot
rm -rf $ISO /tmp/mnt_test; mkdir -p $ISO/dev /tmp/mnt_test
cp -a /tmp/e2test/. $ISO/
mknod $ISO/dev/null c 1 3 2>/dev/null; chmod 666 $ISO/dev/null
echo '=== 1 建 20MB 测试文件 ==='
dd if=/dev/zero of=$ISO/test.img bs=1M count=20 2>/dev/null
echo '=== 2 ★ 用 initramfs 的 mke2fs 格式化 ★ ==='
chroot $ISO /usr/sbin/mke2fs -t ext4 -F -q /test.img 2>&1 | tail -3
echo '=== 3 挂载 + 写入标记文件 ==='
if mount -o loop $ISO/test.img /tmp/mnt_test 2>/dev/null; then
  echo '  OK 挂载成功'
  echo 'HELLO-FROM-TEST' > /tmp/mnt_test/hello.txt
  mkdir -p /tmp/mnt_test/subdir; echo abc > /tmp/mnt_test/subdir/x.txt
  sync; umount /tmp/mnt_test
  echo '  已写 hello.txt + subdir/x.txt'
else echo '  FAIL 挂载失败'; exit 1; fi
echo '=== 4 ★★ 故意毁掉主超级块 ★★ ==='
dd if=/dev/zero of=$ISO/test.img bs=1 seek=1024 count=2048 conv=notrunc 2>/dev/null
echo '  主超级块已清零(模拟我们今晚遇到的那种损坏)'
echo '=== 5 试挂载(应失败)=== '
mount -o loop $ISO/test.img /tmp/mnt_test 2>/dev/null && echo '  意外:居然挂上了' || echo '  OK 预期内挂不上'
echo '=== 6 ★★★ 用 initramfs 的 e2fsck 修 ★★★ ==='
chroot $ISO /usr/sbin/fsck.ext4 -fy /test.img 2>&1 | tail -16
echo '=== 7 ★ 验证数据回来了吗 ★ ==='
if mount -o loop $ISO/test.img /tmp/mnt_test 2>/dev/null; then
  echo '  ★★★ 挂载成功 —— 自动修复有效!★★★'
  echo '  根目录:'; ls /tmp/mnt_test 2>/dev/null | head -5 | sed 's/^/    /'
  echo "  hello.txt = [$(cat /tmp/mnt_test/hello.txt 2>/dev/null)]"
  echo "  subdir/x.txt = [$(cat /tmp/mnt_test/subdir/x.txt 2>/dev/null)]"
  umount /tmp/mnt_test
else echo '  ✗ 还是挂不上'; fi