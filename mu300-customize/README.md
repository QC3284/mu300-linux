# MU300 / ZTE F50 Linux 定制包

把**刷机后需要恢复的一切**集中在这里,一键装回。

## 用法

```bash
# 设备起来后(默认 root@192.168.77.1,口令 CHANGE_ME)
bash install.sh

# 换目标
HOST=root@192.168.5.9 bash install.sh
```

幂等 ✓ —— 反复跑不会出问题。

## 里面是什么

| 路径 | 内容 |
|---|---|
| `files/usr/bin/mu300-*` | 自研脚本:状态采集(三档)、流量累计、LED、AT 控制台、IPv6 透传、短信、客户端、定时任务 |
| `files/etc/init.d/mu300-*` | 八个守护(全部开机自启):led / statusd / trafd / atweb / v6-relay / smsd / clientsd / scheduled |
| `files/etc/hotplug.d/iface/99-mu300-ipv6` | IPv6:WAN 起来后设 `fe80::1`、accept_ra、MTU 1432 |
| `files/www/luci-static/resources/view/mu300/*.js` | LuCI **七个页面**:5G 状态 / 流量统计 / 短信 / 客户端管理 / 频段锁 / 定时任务 / AT 控制台 |
| `files/usr/share/luci/menu.d/luci-app-mu300.json` | 菜单(父项带 `firstchild`,避免 404) |
| `files/usr/share/rpcd/acl.d/luci-app-mu300.json` | ACL(放行状态/信号/流量/短信/客户端/AT/频段/小区锁相关文件) |
| `install.sh` | 一键安装 + 配置 + 启服务 + 验证 |

## 状态采集是三档的(2026-09-27 起)

| 档 | 周期 | 写哪个文件 | 内容 |
|---|---|---|---|
| 快 | **5 秒** | `/tmp/mu300-live.json` | 速率、流量计数、在线时长、温度、WiFi 客户端、地址(纯 sysfs,~1 秒) |
| 中 | **20 秒** | `/tmp/mu300-signal.json` | 信号 RSRP/RSRQ/SINR/质量(**只发 1 条 `AT+CESQ`**) |
| 慢 | **5 分钟** | `/tmp/mu300-status.json` | 制式、运营商、小区 ID/TAC、频段锁、模组支持集、固件 |

页面渲染时按 快 → 中 → 慢 合并(快的覆盖慢的同名键)。

## ⚠️ AT 操作安全须知(踩过三次坑)

1. **`AT+SPLBAND` 的模式**:0=读 4G 锁、3=读 5G 锁、4=读 5G 支持集、5=读 4G 支持集;
   **1=写 4G 锁、2=写 5G 锁** ✗ —— 写模式**必须带 5 个掩码参数**,
   单发 `AT+SPLBAND=2` 会把频段锁清成 0(已发生过一次 ✗)。
2. **不要遍历"参数空间"**:只发带 `?` 或 `get` 的只读命令 ✓。
3. **不要高频发 AT**:手工连发会把通道打爆(症状:`AT+CESQ` 返回全 255、命令返回空),
   只能重启设备恢复 ✓。正常采集是 3 条/分钟,安全 ✓。
4. 改 AT 相关功能前,先发一条 `AT+CESQ`,看有没有 255(通道健康检查)✓。
5. **不要**覆盖上游的 `/etc/init.d/mu300-atd`(AT 通道守护,保持 `/dev/stty_nr1` 打开;关掉会把通道卡死)。
6. **不要**动 `/etc/init.d/mu300-modem-log`(S92):它 drain 模组的 SIPC spool 通道,
   不 drain 的话 ring 满 → 模组约 90 秒后不再响应 SIPC,AT 就哑了。

## 频段锁 / 小区锁(都是 Linux 侧直接对模组发 AT)

```
读 5G 锁:AT+SPLBAND=3      写 5G 锁:AT+SPLBAND=2,<m0>,<m1>,<m2>,<m3>,<m4>
读 4G 锁:AT+SPLBAND=0      写 4G 锁:AT+SPLBAND=1,<m0..m4>
放开 5G:AT+SPLBAND=2,4294967295 x5      放开 4G:AT+SPLBAND=1,4294967295 x5

锁小区:AT+SPFORCEFRQ=<rat>,1,<earfcn>,<pci>   解锁:AT+SPFORCEFRQ=<rat>,0
      rat: 16=NR、12=LTE(模组**没有**读回命令,页面自己记一份到 /etc/mu300/celllock.json)

⚠ 两者都是"写配置",不会立刻断网;**要重启设备才真正生效**(已验证)。
```

**已知位映射**(靠实测 + `AT+SPLBAND=4` 的 `553,0,528` 交叉验证):
```
5G mask0 = 低段,顺序 [n1, n2, n3, n5, n7, n8, n20, n25, n26, n28, …]
   → bit0=n1  bit3=n5  bit5=n8  bit9=n28
5G mask2 = 高段 → bit4=n41  bit8=n78
4G mask3 = band1-32(bit=band-1)、mask1 = band33-64(bit=band-33)   ← 标准 E-UTRA 位图
n6 只在 "get nr support_band" 里出现,掩码无独立位(补上行频段)
```

## 必须固化的配置项(install.sh 会写)

| 项 | 值 | 为什么 |
|---|---|---|
| `firewall.@defaults[0].flow_offloading` | **0** | 厂商内核**没有 flowtable**;不关掉规则集报错、WAN 未绑定 → **客户端没 NAT 上不了网** |
| `firewall.@defaults[0].flow_offloading_hw` | **0** | 同上 |
| `network.wan.mtu` | **1432** | 运营商 RA 下发 1432,接口默认 1500 → 大包被丢、大文件下载中途卡死 |
| `dhcp.lan.start/limit/leasetime` | 100 / 254 / 24h | 与用户主路由一致 |
| `dhcp.@dnsmasq[0].filter_aaaa` | 0 | 要给客户端真 IPv6 |
| apk 源 | **mirror.nju.edu.cn** | SJTU 镜像太慢(`apk update` 150 秒超时 → 换源后 5 秒) |

## 数据文件(运行期产生)

| 文件 | 说明 |
|---|---|
| `/tmp/mu300-live.json` | 快档快照(5 秒) |
| `/tmp/mu300-signal.json` | 中档信号快照(20 秒) |
| `/tmp/mu300-status.json` | 慢档快照(5 分钟) |
| `/tmp/mu300-traffic.json` | 流量快照(30 秒) |
| `/etc/mu300/traffic.json` | **流量按天累计,重启不丢**(要保留历史就备份它) |
| `/etc/mu300/sms-messages.json` | 短信(收件 + 本地记的发件,上限 200 条) |
| `/etc/mu300/clients.json` | 客户端备注名(按 MAC) |
| `/etc/mu300/schedule.json` | 定时任务配置(定时重启 / 定时重载无线) |
| `/etc/mu300/celllock.json` | 小区锁记录(模组读不回,页面自己记) |

## LED

内核 `pattern` 触发器做 ms 级追色(红→白→蓝),WAN 起来即停;
运行态:5G=白、4G=蓝、无服务=红。`LED_PATTERN_MS` / `LED_USE_PATTERN` / `LED_DEMO` 可调。

## 页面开发:自己截图核对

改动 UI 后**必须自己截图确认**(别只看代码):
```bash
cd /home/qc233/zte/mu300-work
.venv-ui/bin/python ui-shot.py status 1366,900 ui-shots/x.png dark   # 会用 Chrome 自动登录 + 截图
```
(依赖:chromedriver156 + .venv-ui/selenium;截图时关缓存、模拟 `prefers-color-scheme: dark`)
