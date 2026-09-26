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
| `files/usr/bin/mu300-*` | 自研脚本:状态采集、流量累计、LED、AT 控制台、IPv6 透传、AT 白名单 |
| `files/etc/init.d/mu300-*` | 五个守护(开机自启) |
| `files/etc/hotplug.d/iface/99-mu300-ipv6` | IPv6 相关:WAN 起来后设 `fe80::1`、accept_ra、MTU 1432 |
| `files/www/luci-static/resources/view/mu300/*.js` | LuCI 三个页面(5G 状态 / 流量统计 / AT 控制台) |
| `files/usr/share/luci/menu.d/luci-app-mu300.json` | 菜单(父项带 `firstchild`,避免 404) |
| `files/usr/share/rpcd/acl.d/luci-app-mu300.json` | ACL(只放行 `/tmp` 下四个文件) |
| `install.sh` | 一键安装 + 配置 + 启服务 + 验证 |

## 必须固化的配置项(install.sh 会写)

| 项 | 值 | 为什么 |
|---|---|---|
| `firewall.@defaults[0].flow_offloading` | **0** | 厂商内核**没有 flowtable**;不关掉规则集报错、WAN 未绑定 → **客户端没 NAT 上不了网** |
| `firewall.@defaults[0].flow_offloading_hw` | **0** | 同上 |
| `network.wan.mtu` | **1432** | 运营商 RA 下发 1432,接口默认 1500 → 大包被丢、大文件下载中途卡死 |
| `dhcp.lan.start/limit/leasetime` | 100 / 254 / 24h | 与用户主路由一致 |
| `dhcp.@dnsmasq[0].filter_aaaa` | 0 | 要给客户端真 IPv6 |
| apk 源 | **mirror.nju.edu.cn** | SJTU 镜像太慢(`apk update` 150 秒超时 → 换源后 5 秒) |

## 数据文件(运行期产生,不用备份)

- `/tmp/mu300-status.json` —— 状态快照(每 120 秒刷)  给 LuCI 读
- `/tmp/mu300-traffic.json` —— 流量快照(每 30 秒刷)  给 LuCI 读
- `/etc/mu300/traffic.json` —— **流量按天累计,重启不丢**(要保留历史就备份它)

## 注意

- **不要**覆盖上游的 `/etc/init.d/mu300-atd`(它是 AT 通道守护,保持 `/dev/stty_nr1` 打开;关掉会把通道卡死)
- **不要**高频发 AT 命令(采集 120 秒一次足够;手工连发会把通道打爆,连带数据面一起废)
- LED 用 `pattern` 触发器做 ms 级追色;`LED_PATTERN_MS` / `LED_USE_PATTERN` / `LED_DEMO` 可调