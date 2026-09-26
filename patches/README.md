# 我们的补丁(自用,不提交上游)

## sipa-delegate-uaf-fix.patch

修 `sipa_dele` 在 probe 失败后的 use-after-free:每轮启动 **t≈93.7 s 必 panic**。

- 现象:`Kernel panic - not syncing: CFI failure (target: 0x0)`,栈 `conn_thread+0x2c8/0x2f0 [sipa_dele]`
- 链条:`sipa_rm_add_dependency()` 因 `SIPA_RM_RES_PROD_CP does not exist` 返回 -22 →
  `cp_delegator_init()` 失败 → probe 返回非 0 → `devm_kzalloc` 回收 delegator →
  `conn_thread` 线程仍在跑 → `on_cmd` 读出 NULL → 间接调用空指针 → CFI abort → panic
- 修法:①两个 Wi-Fi 依赖注册失败不再让 probe 失败(打 warning 继续);②`conn_thread` 六处回调加 NULL 守卫
- 验证(2026-09-26):设备 uptime > 285 s 无 panic,chan 120 握手正常,`sipa_eth0 rx_packets` 0→272,
  `ping 223.5.5.5` 0% 丢包,真实 TCP 下载成功,出口公网 IP `218.28.134.28`

应用:**对 vendor 内核树**(Enceka/android_kernel_zte_ums9620_mifi_u30air @ `b50db5b6224c`):

```bash
patch -p1 < patches/sipa-delegate-uaf-fix.patch
```

本地编译见工作区记录 `f50_kernel/BUILD-2026-09-26-local-module-build.md`(容器 clang-12,单模块 ≈40 s)。
