# 官方 kmod 固定镜像(ImmortalWrt armsr/armv8,内核 6.18.52)

> t16(builder)· 2026-09-28 · **只做镜像:不碰设备、不刷写**
> 分支:**qc/kmod-mirror**;目的:把官方 snapshot 的虚拟 kernel 包与几个样本 kmod **钉在 fork 里**,
> 设备侧用 raw.githubusercontent.com 的 **commit-pinned** URL 当 apk feed,不再受 snapshot 漂移影响。

## 1. 文件清单(官方原文件名 + 原目录结构)

| 镜像内路径 | 大小 | sha256 |
|---|---|---|
| snapshots/targets/armsr/armv8/packages/packages.adb | 15,512 B | f1097ac6b900b24b675a355652855ffe5a85cb2a876625ca6c9e18cf0bda801e |
| snapshots/targets/armsr/armv8/packages/kernel-6.18.52~2e107f3f74eefa4459193e9332551c74-r1.apk | 7,722 B | 7f37a054206b1e3977eea5bec882e9e3807125977b497e6fe5360645b1e4c527 |
| snapshots/targets/armsr/armv8/kmods/6.18.52-1-2e107f3f74eefa4459193e9332551c74/packages.adb | 174,226 B | 48c5120e2b65e616d9d265ab22013ea0be2e96f11f557ff0249ab706d98e5746 |
| …/kmod-nf-nat-6.18.52-r1.apk | 20,767 B | 60a12ce9b37395e6651dae3f224ead2a8f1a888419b3561a09e1b41e46aa19f3 |
| …/kmod-nf-nathelper-6.18.52-r1.apk | 7,957 B | 2e448b2816c8dd6125c706793bfda3d9cdf9bab2de7d9162c7f2bd8cf54a22c4 |
| …/kmod-pppoe-6.18.52-r1.apk | 10,630 B | 4234ef24640af94b43571f5fcf8bac94046404eb6065fd9b0c767837ee3e1d83 |
| …/kmod-tun-6.18.52-r1.apk | 30,045 B | c4aeea61cdbb122c7cb3ffd7b4f316a741f333babca6beaa9c86af009ee912f4 |
| snapshots/targets/armsr/armv8/SHA256SUMS | 见文件 | 只保留上面 7 个文件对应的官方条目(整份官方文件的 sha256 记在 SHA256SUMS-official-relevant.txt) |

## 2. 来源(抓取时用的官方 URL)

~~~text
前缀: https://downloads.immortalwrt.org/snapshots/targets/armsr/armv8
目标 feed : <前缀>/packages/packages.adb
kmods feed: <前缀>/kmods/6.18.52-1-2e107f3f74eefa4459193e9332551c74/packages.adb
校验基准  : <前缀>/sha256sums(整份 201,333 B;sha256 见同目录 SHA256SUMS-official-relevant.txt)
~~~

## 3. 校验(逐文件)

1. **与官方 sha256sums 比对:7/7 一致**(每个文件 sha256 与官方发布条目逐字符相同);
2. **与官方 apk index 的条目比对**:index 里这几个包的 version / installed-size 与实际包一致 ——
   kernel 6.18.52~2e107f3f74eefa4459193e9332551c74-r1 / 28,909 B;kmod-nf-nat 6.18.52-r1 / 56,460 B;
   kmod-nf-nathelper / 25,140 B;kmod-pppoe / 27,409 B;kmod-tun / 78,358 B;
3. **如实说明一处口径差异**:apk v3 的 index 里 hashes 字段是 64 位十六进制(**索引哈希**),
   而 .apk 文件内部 hashes 字段是 40 位十六进制(**内容块哈希**)——两者算法/范围不同,不能直接互相比对
   (opkg 时代 Packages 的 C:/S: 才是同一口径)。所以权威依据是第 1 条;此外 index 用的是**官方原文件**,
   签名/哈希原样保留,没有重打包。

## 4. 设备侧 feed 样例(mu300-spoof.list)

把 COMMIT 换成 qc/kmod-mirror 的提交号(不可变):
~~~text
https://raw.githubusercontent.com/QC3284/mu300-linux/COMMIT/snapshots/targets/armsr/armv8/packages/packages.adb
https://raw.githubusercontent.com/QC3284/mu300-linux/COMMIT/snapshots/targets/armsr/armv8/kmods/6.18.52-1-2e107f3f74eefa4459193e9332551c74/packages.adb
~~~
★ apk v3 的 repositories 行**直接指向 packages.adb**(与设备现有 /etc/apk/repositories.d/*.list 同款)。

## 5. 安装命令(镜像版,替换 v7/FINAL-v7.md §4 的 ① ② ③)

~~~sh
COMMIT=<qc/kmod-mirror 的提交号>
cat > /etc/apk/repositories.d/mu300-spoof.list <<EOF
https://raw.githubusercontent.com/QC3284/mu300-linux/$COMMIT/snapshots/targets/armsr/armv8/packages/packages.adb
https://raw.githubusercontent.com/QC3284/mu300-linux/$COMMIT/snapshots/targets/armsr/armv8/kmods/6.18.52-1-2e107f3f74eefa4459193e9332551c74/packages.adb
EOF
apk update                     # 期望:索引里出现 6.18.52 的 kernel 与 4 个样本 kmod(镜像只有这些)

apk add --allow-untrusted 'kernel=6.18.52~2e107f3f74eefa4459193e9332551c74-r1'
apk info -v | grep '^kernel'  # 期望:kernel-6.18.52~2e107f3f74eefa4459193e9332551c74-r1

apk add --allow-untrusted kmod-nf-nat kmod-nf-nathelper kmod-pppoe kmod-tun
ls /lib/modules/6.18.52/; modinfo -F vermagic /lib/modules/6.18.52/*.ko | sort -u   # 期望:6.18.52 SMP mod_unload aarch64
~~~
回退:apk del -r kmod-nf-nat kmod-nf-nathelper kmod-pppoe kmod-tun;apk del kernel;rm -f /etc/apk/repositories.d/mu300-spoof.list;apk update

## 6. 信任

镜像里的 index 是官方原件,但签名公钥是 **master snapshot 的**(设备目前只信任 immortalwrt-25.12.pem / openwrt-25.12.pem)
⇒ 试验仍用 **--allow-untrusted**(不落盘信任);要长期用,再把 master 公钥放进 /etc/apk/keys/(本镜像 keys/ 下作参考)。

## 7. 范围与维护

- 本镜像**只含这 7 个文件**(1 个虚拟 kernel 包 + 4 个样本 kmod + 2 个 index + 校验清单);
- 要别的 kmod:按同样方式补进镜像(改一次 commit),或临时改回官方 snapshot URL;
- 镜像按 commit 钉死;更新就在本分支再提交一次,并同步改设备上的 COMMIT。

## 8. 复现(重新抓取 + 校验)

~~~sh
B=https://downloads.immortalwrt.org/snapshots/targets/armsr/armv8
K=$B/kmods/6.18.52-1-2e107f3f74eefa4459193e9332551c74
curl -fsSL -o packages/packages.adb $B/packages/packages.adb
curl -fsSL -o 'packages/kernel-6.18.52~2e107f3f74eefa4459193e9332551c74-r1.apk' "$B/packages/kernel-6.18.52~2e107f3f74eefa4459193e9332551c74-r1.apk"
curl -fsSL -o kmods/packages.adb $K/packages.adb
for m in kmod-nf-nat kmod-nf-nathelper kmod-pppoe kmod-tun; do curl -fsSL -o "kmods/$m-6.18.52-r1.apk" "$K/$m-6.18.52-r1.apk"; done
curl -fsSL -o sha256sums-official $B/sha256sums   # 逐文件 sha256sum 与它比对(结果见 §1 表)
~~~
