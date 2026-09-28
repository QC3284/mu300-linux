# MU300 / F50 — initramfs 救援套件

> 这是 2026-09-27 那次 rootfs 事故之后加的东西。
> 目的:**rootfs 坏了不用接电脑,设备自己能修**。

## 目录内容

| 文件 | 说明 |
|---|---|
| `init-rescue` | 打了补丁的 init(基于**现役** boot_b 提取的 339 行版 → 379 行)= **现役 v5 镜像里那份** |
| `sd-restore` | 从 SD 卡一键恢复 rootfs 的脚本(放进 initramfs 的 /usr/bin/) |
| `patch-init.py` | 补丁脚本(对现役 init 施加 6 处改动;结果与 `init-rescue` 逐字节相同) |
| `build-rescue-img.py` | 把改好的 ramdisk 装回 boot 镜像(路径写死在文件开头,按需改) |
| `compare-ramdisk.py` | **重建复核工具**:按「数据段」比对两个 ramdisk/boot 镜像,忽略 cpio 元数据差异 |
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

## 补丁做了哪 6 件事

1. **提高 loglevel** —— 设备 cmdline 是 `loglevel=1`,以前串口/dmesg 什么都看不到;
   现在早期就 `echo 7 > /proc/sys/kernel/printk`
2. **挂载失败自动 e2fsck** —— `mount` 失败 → `fsck.ext4 -fy` → 重试挂载
   (当晚那场"日志坏了导致挂不上"的灾难,以后会自动修好)
3. **故障自诊断** —— 打印分区/大小/魔数/fsck日志/挂载错误 + 4 条救援办法,
   并写进 `http://192.168.77.1` 的救援首页
4. **sd-restore** —— 从 SD 卡 `/f50-backup/` 一键恢复 rootfs
5. **PATH 补全** —— 原版 init 是 `PATH=/bin:/sbin`,而 `sd-restore` 在 `/usr/bin`、
   `e2fsck`/`mke2fs` 在 `/usr/sbin`。**不补 PATH,救援时敲 `sd-restore` 直接 "not found"**
   (2026-09-28 真实演练时踩到,当年写在临时脚本 `fix_bugs_v3.py` 里,现已并回本目录)
6. **救援诊断页不被覆盖** —— 第 3 条的诊断块原来写 `/run/www/index.html`,
   但原版 init 之后会用首页覆盖它 —— 等于白写。现在先写 `/run/www/rescue.txt` 再追加进首页

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
mkdir -p work

# ★ 解包必须用 sudo ★ 现役归档里有 dev/console(crw------- root:root 5,1);
#   普通用户解包会「mknod: 不允许的操作」,节点直接缺失(cpio 退出码 2)
sudo sh -c 'cd work && cpio -idm --quiet < /tmp/ramdisk.cpio'

# ③ 放 e2fs 工具(见上面清单)到 work/lib、work/usr/lib、work/usr/sbin
sudo cp -a initramfs-extra/. work/                 # 套件在 mu300-work/initramfs-extra/
sudo chown -R "$USER":"$USER" work                 # 现役归档属主 = 1000:1000
sudo chown root:root work/dev/console              # 只有 dev/console 是 root:root(与现役一致)

# ④ ★ 先建 /usr/bin ★ 现役 ramdisk 里根本没有 /usr 目录,不建这步会 cp 失败(以前漏写了)
sudo mkdir -p work/usr/bin
sudo cp sd-restore work/usr/bin/ && sudo chmod 755 work/usr/bin/sd-restore

# ⑤ 施加 init 补丁(6 处);结果应与 init-rescue 逐字节相同
python3 patch-init.py work/init
sha256sum work/init   # 现役 v5 = 36b210be4927c635a9db13e753970bd0a893d1af1b611ac214704d95fe61fbbd

# ⑥ 重新打包
#   ★ 不要用 sudo 打包 ★ 以 root 打包会把所有条目属主写成 root(现役是 1000:1000),
#   设备节点在 ② 已经拿到了。lz4 用 -l -12(legacy 格式 + 最高压缩,与现役一致)
sh -c 'cd work && find . | cpio -o -H newc --quiet > /tmp/new.cpio'
lz4 -l -12 -c /tmp/new.cpio > /tmp/new.ramdisk.lz4
sha256sum /tmp/new.ramdisk.lz4   # ★ 不会等于现役,属正常 —— 见下一节

# ⑦ 装回镜像(更新头部的 ramdisk_size!)
python3 build-rescue-img.py

# ⑧ ★ 先测再刷 ★
#    见 test-rescue.sh
```

### ③b 没有 root 怎么办(fakeroot「保状态」法)

非 root 造不出真的字符设备节点,但可以让 fakeroot 把「这个文件是 c 5,1」记进状态文件,
打包时再读回来:

```sh
FR=/tmp/fakeroot.state
fakeroot -s $FR -- sh -c 'cd work && cpio -idm --quiet < /tmp/ramdisk.cpio'   # 代替 ② 里的 sudo 解包
# ③ ④ ⑤ 照做(③④ 不用 sudo,文件属主就是你自己)
fakeroot -i $FR -s $FR -- sh -c 'cd work && find . | cpio -o -H newc --quiet > /tmp/new.cpio'   # 代替 ⑥
```

代价:这样打出来的包,**所有条目 uid/gid 都是 0**(现役是 1000:1000)。功能上无影响
(内核解包时一律按 root 处理),只影响 sha256。
2026-09-28 实测:用这条路径重建出的包,`compare-ramdisk.py` 报告 `数据段不一致条目数: 0`。

## ★ 为什么重建出的镜像 sha256 和现役不一样(打包不确定性)

GNU cpio 的 newc 归档头里带着**宿主文件系统**的痕迹,它们每次都不一样:

| 字段 | 是什么 | 现役 v5 实测 |
|---|---|---|
| `ino` | inode 号(tmpfs 全局自增,每次解包都不同) | 0..6809;重建时 525 条都不同 |
| `st_dev` | 归档来源文件系统的 dev | `0,43`(同一台机器换一次启动就变成 `0,44`) |
| `mtime` | 解包/新建目录的时间(= 重建时刻) | 28 条不同 |
| 条目顺序 | `find` 走的是 tmpfs readdir 顺序 | 现役 `usr` 排在 `lib` 前 |
| 名称前缀 | `find . \| cpio` 会写出 `./usr/...` | 现役无前缀,打包后大 887 字节 |
| `dev/console` | 非 root 解不出字符设备 | `crw------- root:root 5,1` |

实测(2026-09-28,同一台机器、同一输入、同一条流程**连跑两次**):

```
526 个条目的【数据段】完全相同,但 ino 差 525 条、mtime 差 24 条 → 两次镜像的 sha256 不同
```

**所以「sha256 是否等于现役」不是有效的验收标准**,有效的是「数据段是否一致」:

```sh
python3 compare-ramdisk.py bootb-rescue5.img /tmp/new-bootb-rescue.img
#   数据段不一致条目数: 0   → 重建内容正确(元数据差异会列出来,但不算失败)
#   退出码 0 = 通过;1 = 有条目缺失 / 内容不同
```

要**逐字节**复现,得把这些字段也钉死 —— 把参考归档的头部元数据套回重建出来的数据上(「归一化」)。
2026-09-28 的复现就是这么做,最终得到与现役**逐字节相同**的 `sha256 718e0fbb…`。

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

- **v5(2026-09-28 02:13)—— 现役**,`sha256 718e0fbb442b50d968d79c2cb6764b2f607a7bd69a311a22905b65caffe5ffb7`
  ramdisk 9,240,458 字节;init 补丁 6 处(与本目录 `init-rescue` 逐字节相同);sd-restore 全部动态化(不写死 SD 卡 UUID/设备名)
- v4 / v3 —— 救援调试的中间版(`mu300-work/bootb-rescue4.img` / `bootb-rescue3.img`)
- v2(2026-09-28 01:0x)—— `sha256 26d581741e8260268d6045865f5518db339fd77bf254c294d4dea3ce876df829`
  ramdisk 9,240,019 字节,含 libgcc_s(修复 v1 的致命缺陷)
- v1 —— 9,179,105 字节,**缺 libgcc_s,已废弃**

## 变更记录

- 2026-09-28(**本次**):把当年临时脚本 `fix_bugs_v3.py` 的两处修复并进 `patch-init.py`
  (PATH 补 `/usr/bin:/usr/sbin`、救援诊断页改用 `rescue.txt`);README 补 `sudo` 解包、
  `mkdir -p work/usr/bin`、`dev/console` 与「打包不确定性」说明;新增 `compare-ramdisk.py`。
  依据:t5 字节级复现报告(重建 init 与现役 `36b210be…` 逐字节相同;归一化后整镜像与现役 `718e0fbb…` 逐字节相同)。
- 2026-09-28:sd-restore 全部动态化(不写死 SD 卡 UUID / 设备名),即现役 v5。
