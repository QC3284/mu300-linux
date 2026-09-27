# MU300 / F50 — initramfs 救援套件

> 这是 2026-09-27 那次 rootfs 事故之后加的东西。
> 目的:**rootfs 坏了不用接电脑,设备自己能修**。

## 目录内容

| 文件 | 说明 |
|---|---|
| `init-rescue` | 打了补丁的 init(基于**现役** boot_b 提取的 339 行版 → 378 行) |
| `sd-restore` | 从 SD 卡一键恢复 rootfs 的脚本(放进 initramfs 的 /usr/bin/) |
| `patch-init.py` | 补丁脚本(对现役 init 施加 4 处改动) |
| `build-rescue-img.py` | 把改好的 ramdisk 装回 boot 镜像 |
| `test-rescue.sh` | **零风险**实测脚本(在设备上 chroot 跑,只碰 /tmp) |
| `README.md` | 本文件 |

## ⚠️ 两条必须遵守的规矩

### ① 绝对不能用仓库里的 `boot/init` 当基线!

- 仓库里那份(333 行)是**通用/旧版**:用 `ROOT_OFFSET=27762098176`(裸区域)+ `/ubuntu` + systemd
- 这台设备**现役的**(339 行)用的是 **fulldumpdb 分区**(`/dev/mmcblk0p54`)+ `/openwrt` + procd
- 现役那份里明确写着:
  ```
  # MU300/F50 local change: this unit's GPT covers the whole eMMC (no free tail region), so the
  # Linux root filesystem lives in the repurposed "fulldumpdb" GPT partition (2 GiB, full-RAM crash
  # dump target, unused in normal operation). Locate it by PARTNAME, like misc/boot_b below.
  ```
- **改错基线 = 做出启动不了的镜像**

**正确做法**:先从设备的 boot_b 提取现役 ramdisk,以它为基线。

### ② 动态链接器/库要打包齐全

initramfs 的 busybox 是**静态**的,里面**没有 ld-musl**,也没有任何 .so。
而设备的 e2fsck 是 musl **动态**链接的 → 必须一起打包:

```
/lib/ld-musl-aarch64.so.1   → libc.so
/lib/libc.so                590,852 字节
/lib/libgcc_s.so.1          131,088 字节   ★ 最容易漏!漏了 e2fsck 根本起不来 ★
/usr/lib/libext2fs.so.2     399,243
/usr/lib/libe2p.so.2         30,474
/usr/lib/libcom_err.so.0     12,298
/usr/lib/libblkid.so.1      287,609
/usr/lib/libuuid.so.1        28,728
/usr/sbin/e2fsck            305,171
/usr/sbin/mke2fs            110,819
+ fsck.ext2/3/4、mkfs.ext2/3/4 的符号链接
共约 1.9 MB
```

**漏 libgcc_s 的症状**(我们实际踩过):
```
Error relocating /usr/lib/libblkid.so.1: __subtf3: symbol not found
Error relocating /usr/lib/libblkid.so.1: __floatditf: symbol not found
```

## 补丁做了哪 4 件事

1. **提高 loglevel** —— 设备 cmdline 是 `loglevel=1`,以前串口/dmesg 什么都看不到;
   现在早期就 `echo 7 > /proc/sys/kernel/printk`
2. **挂载失败自动 e2fsck** —— `mount` 失败 → `fsck.ext4 -fy` → 重试挂载
   (当晚那场"日志坏了导致挂不上"的灾难,以后会自动修好)
3. **故障自诊断** —— 打印分区/大小/魔数/fsck日志/挂载错误 + 4 条救援办法,
   并写进 `http://192.168.77.1` 的救援首页
4. **sd-restore** —— 从 SD 卡 `/f50-backup/` 一键恢复 rootfs

## 怎么做新镜像

```sh
# ① 从设备提取现役 boot_b(64MB)
ssh root@192.168.77.1 'dd if=/dev/block/by-name/boot_b bs=1M' > bootb-live.img

# ② 解包:解析 Android boot v4 头 → 取 ramdisk 段 → lz4 -d → cpio -idm
python3 - <<'EOF'
import struct, pathlib
d = pathlib.Path('bootb-live.img').read_bytes()
ks = struct.unpack_from('<I', d, 8)[0]
rs = struct.unpack_from('<I', d, 12)[0]
ro = 4096 + ((ks + 4095)//4096)*4096
pathlib.Path('/tmp/ramdisk.lz4').write_bytes(d[ro:ro+rs])
print('ramdisk 偏移', ro, '大小', rs)
EOF
lz4 -d -f /tmp/ramdisk.lz4 /tmp/ramdisk.cpio
mkdir -p work && cd work && cpio -idm --quiet < /tmp/ramdisk.cpio

# ③ 放 e2fs 工具(见上面清单)到 work/lib、work/usr/lib、work/usr/sbin
# ④ 把 sd-restore 放到 work/usr/bin/ 并 chmod 755
# ⑤ 施加 init 补丁
python3 patch-init.py work/init

# ⑥ 重新打包(root 权限,保证设备节点)
sudo sh -c 'cd work && find . | cpio -o -H newc --quiet > /tmp/new.cpio'
lz4 -l -12 -c /tmp/new.cpio > /tmp/new.ramdisk.lz4

# ⑦ 装回镜像(更新头部的 ramdisk_size!)
python3 build-rescue-img.py

# ⑧ ★ 先测再刷 ★
#    见 test-rescue.sh
```

## 刷写(boot_b)

```sh
# 传镜像(校验 sha256)
cat bootb-rescue.img | ssh root@192.168.77.1 'cat > /tmp/rescue.img'
ssh root@192.168.77.1 'sha256sum /tmp/rescue.img'

# 写 boot_b(★ 从 Linux 写是安全的:boot_b 没被挂载,内核已在内存 ★)
ssh root@192.168.77.1 'dd if=/tmp/rescue.img of=/dev/block/by-name/boot_b bs=4M && sync'

# 武装 slot b(写 misc 偏移 2048 的 32 字节)
cat boot-linux-nocfi.misc-slot-b-trial.bin | ssh root@192.168.77.1 \
  'cat > /tmp/bc.bin; dd if=/tmp/bc.bin of=/dev/block/by-name/misc bs=1 seek=2048 conv=notrunc && sync'

# 重启
ssh root@192.168.77.1 'sync; reboot'
```

## ★ 关键设备布局(必须记住)

```
rootfs      = fulldumpdb 分区 = /dev/mmcblk0p54  (LBA 7841792,2 GB)
              —— 上游把这台设备的崩溃转储区改造成了 Linux rootfs
/boot_a     = /dev/mmcblk0p37  (64 MB)
/boot_b     = /dev/mmcblk0p38  (64 MB)
/misc       = /dev/mmcblk0p3   (1 MB)
userdata    = /dev/mmcblk0p75

boot_b 内部分三段:
  0-39 MB   镜像本体(内核 28 MB + ramdisk)
  39-48 MB  AVB 数据
  48-64 MB  ★ 8 MB 持久日志区(init 写的,比 pstore 更耐断电)★

所以 boot_b 的分区内容 ≠ 单纯的镜像文件 —— 对比时要分段算 sha256。
```

## ★ 救援能力实测(chroot 法,零风险)

```sh
# 在设备上跑 test-rescue.sh,它会:
#   1. 建一个 20MB 测试文件
#   2. 用镜像里的 mke2fs 格式化
#   3. 挂载 + 写 hello.txt/subdir/x.txt
#   4. ★ 故意毁掉主超级块 ★
#   5. 用镜像里的 e2fsck -fy 修
#   6. ★ 验证挂载成功 + 数据完好 ★
#
# 全程只在 /tmp,不碰任何真分区。
```

实测结果(2026-09-28):
```
✓ mke2fs 1.47.3 格式化成功
✓ e2fsck 1.47.3 修复成功("FILE SYSTEM WAS MODIFIED")
✓ 挂载成功,hello.txt = [HELLO-FROM-TEST]、subdir/x.txt = [abc]
```

## 版本

- v2(2026-09-28 01:0x)—— `sha256 26d581741e8260268d6045865f5518db339fd77bf254c294d4dea3ce876df829`
  ramdisk 9,240,019 字节,含 libgcc_s(修复 v1 的致命缺陷)
- v1 —— 9,179,105 字节,**缺 libgcc_s,已废弃**
