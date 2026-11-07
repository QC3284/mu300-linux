#!/bin/sh
# E gates: the CPU voltage ABI checker and its callers must stay the reviewed ones.
# usage: tools/check-cpu-voltage.sh TREE KERNEL_BUNDLE
set -eu
TREE=${1:?usage: tools/check-cpu-voltage.sh TREE KERNEL_BUNDLE}
BUNDLE=${2:?usage: tools/check-cpu-voltage.sh TREE KERNEL_BUNDLE}
want=caef5333cd027f625105304c2f63d37105d2c3be09acb33c70a19f08eb8cf2b1
checker=$TREE/rootfs/overlay/opt/mu300/bin/sml-voltage-check
platform=$TREE/rootfs/overlay/opt/mu300/bin/cpu-voltage-platform
init=$TREE/rootfs/overlay/etc/init.d/unisoc-cpu
[ -f "$checker" ] || { echo "missing $checker" >&2; exit 1; }
[ -f "$platform" ] || { echo "missing $platform" >&2; exit 1; }
[ -f "$init" ] || { echo "missing $init" >&2; exit 1; }
got=$(sha256sum "$checker" | cut -d" " -f1)
# The checker is a static aarch64 binary reviewed by sha; a different one is a different decision.
[ "$got" = "$want" ] || { echo "sml-voltage-check is $got, not the reviewed $want" >&2; exit 1; }
file -b "$checker" | grep -q "ELF 64-bit LSB executable, ARM aarch64" || { echo "sml-voltage-check is not a static aarch64 ELF" >&2; exit 1; }
file -b "$checker" | grep -q "statically linked" || { echo "sml-voltage-check is not statically linked" >&2; exit 1; }
# The module must expose the parameter the platform passes; otherwise the platform must not pass it.
LC_ALL=C grep -aq "parm=voltage_offset_uv:" "$platform" || { echo "cpu-voltage-platform does not gate on the module parameter" >&2; exit 1; }
# S99 confirms the armed boot state after the boot-args pass.
grep -q "cpu-voltage confirm" "$init" || { echo "unisoc-cpu does not confirm the armed voltage state at boot" >&2; exit 1; }
# The shipped cpufreq driver carries that parameter (the platform never guesses it).
member=$(tar -tzf "$BUNDLE" | grep "sprd-cpufreq-v2-driver\.ko$" | head -n 1)
[ -n "$member" ] || { echo "the kernel bundle has no sprd-cpufreq-v2-driver.ko" >&2; exit 1; }
tar -xOf "$BUNDLE" "$member" | LC_ALL=C grep -aq "parm=voltage_offset_uv:" || { echo "the bundle driver has no voltage_offset_uv parameter" >&2; exit 1; }
echo "cpu-voltage gates: checker sha, module parameter, boot confirm OK"
