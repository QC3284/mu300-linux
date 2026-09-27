#!/bin/bash
# 在【主机】上跑:用容器的 depmod(kmod27)为设备生成 modules.dep
# 用法: mu300-depmod-fix.sh   (自动从设备拉 → 生成 → 推回)
set -e
K=5.4.254-gb50db5b6224c
W=/home/qc233/zte/depmod-work
mkdir -p $W/lib/modules/$K
echo '[1/4] 从设备拉模块目录…'
ssh root@192.168.77.1 "cd /lib/modules/$K && tar cf - ." | (cd $W/lib/modules/$K && tar xf -)
echo '[2/4] 用容器 depmod 生成…'
docker run --rm -v $W/lib/modules:/lib/modules mu300-kbuild depmod $K 2>&1 | grep -v 'modules.order\|modules.builtin' || true
echo '[3/4] 推回设备…'
for f in modules.dep modules.dep.bin modules.alias modules.alias.bin modules.symbols modules.symbols.bin modules.softdep modules.devname; do
  [ -f $W/lib/modules/$K/$f ] && ssh root@192.168.77.1 "cat > /lib/modules/$K/$f" < $W/lib/modules/$K/$f
done
echo '[4/4] 完成 ✓'
