# MU300/F50 自编内核模块

这些模块【原内核里没有】,是用**源码 + 原始 config**自编出来的,
现在放在设备 `/lib/modules/5.4.254-gb50db5b6224c/extra/`,由
`/etc/init.d/mu300-kmods` 开机自动加载。

## 清单(11 个,全部实测可加载 ✓)

| 模块 | 用途 |
|---|---|
| nfnetlink_acct | **nlbwmon 流量统计**(关键 ✓) |
| sch_netem / sch_sfb / sch_drr / sch_qfq / sch_hhf / sch_pie | **QoS 队列算法**(SQM 可选面) |
| cls_flower | 流量分类 |
| pppoe | **PPPoE 拨号**(配 ppp/ppp-mod-pppoe 用) |
| nbd | 网络块设备 |
| vhost_net | KVM 网络加速 |

## ★ 三个会导致内核崩溃的,已排除(勿加载)

- `act_ipt` —— 已废弃的 iptables action,**加载即崩内核** ✗
- `bonding` —— 网卡绑定,**加载即崩内核** ✗
- `ip_vs` —— LVS 负载均衡,**加载即崩内核** ✗

(文件本身完好 md5 一致 ✓ 是这些模块在 5.4.254 厂商树上有问题 ✗
 三个都不是路由器必需功能,直接不用 ✓)

## 怎么重新编译

**前提**:内核源码 + 原始 config + 上游的 kbuild 镜像

```sh
# ① 原始 config(从设备拿,不要merge一堆,否则符号CRC会变 ✗)
ssh root@设备 'zcat /proc/config.gz' > kernel.config

# ② 只打开需要的选项(见 build-fragment.txt)
cp kernel.config $O/.config
sed -i 's/^# CONFIG_PPPOE is not set/CONFIG_PPPOE=m/' $O/.config

# ③ 容器里交叉编译(★ 三个关键:LLVM_IAS=1 + 完整工具链 + CROSS_COMPILE ★)
docker run --rm -v $SRC:/src/kernel -v $O:/src/out mu300-kbuild bash -c '
  cd /src/kernel
  K="O=/src/out ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LLVM_IAS=1"
  C="CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip"
  make $K $C olddefconfig
  make $K $C -j2 modules_prepare
  make $K $C -j2 M=drivers/net/ppp modules
'

# ④ 产物丢进设备的 extra/ + 重新生成 modules.dep(见下)
```

## ★★ 两个大坑 ★★

1. **必须用原始 config,只改要编的那个选项**
   改动多了 → `autoconf.h` 变 → 符号 CRC 变 → 内核报
   `disagrees about version of symbol XXX` → 拒载 ✗

2. **设备上的 depmod 是坏的(kmod 32 段错误)**
   用容器里的 depmod(kmod 27)生成:
   ```sh
   docker run --rm -v $WORK/lib/modules:/lib/modules mu300-kbuild depmod 5.4.254-gb50db5b6224c
   ```
   ★ 必须生成 modules.dep**.bin**,kmod 的 modprobe 只读二进制索引 ★
   (现成脚本:`mu300-work/mu300-depmod-fix.sh`)

## 传输注意事项

★ **传完必须 `sync`** ★ —— 否则一旦内核崩,ext4 日志回滚会把这些**未落盘的写入全丢掉** ✗
(踩过:13 个模块传完没 sync → 崩 → 文件全没了 ✓)
