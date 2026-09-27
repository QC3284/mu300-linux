# 安卓 UFI-TOOLS 的接口规格(实测采集)

用 `mu300-work/dump_android.py` / `dump_more.py` 采集,存放在 android-dump/。
设备:安卓侧 192.168.88.2:2333,口令 CHANGE_ME
签名:kano-sign = SHA256(SHA256(hmac[0:8]) + SHA256(hmac[8:16])),hmac = HMAC_MD5('minikano'+METHOD+PATH+ts, KEY)

## 采集量
- GET 端点 37 个(33 个有数据)
- goform 字段 45 个的真实值
- POST 端点 8 个的回复
- 插件列表 42 个(通过 /api/get_custom_head 注入)

## 采集过程中发现并修正的差异(全部按安卓为准)
单位:monthly_*_bytes=字节 · monthly_time/boot_time=uptime 秒 · cpu_temp=毫摄氏度
形状:is_weak_token{is_weak_token} · volte_status/vonr_status{enabled} · connInfo{result,data{tcp…}}
      usb_status{maxSpeed,details{…}} · sms_forward_blacklist{keywords,phone} · sms_forward_method=SMTP
      download_apk_status{status,percent,error} · get_res_server{res_server} · adb_wifi_setting{enabled}
值:sim_slot=1 · usb_port_switch=1 · ppp_status=ipv4_ipv6_connected · data_volume_limit_switch=1
    Lte_ca_status=off · cr_version=MU300_ZYV1.0.0B09 · network_information=空 · network_signalbar=空(填 signalbar)
    rssi=信号等级(4)不是 dBm · cell_id=空 · battery_*=空
结构:cpuFreqInfo{cpuN:{cur,max}} · cpuUsageInfo{cpu,cpuN} · memInfo{mem_*_kb}(原来完全没有 ✗)
关键:goform 的 loginfo 必须返回 'ok'(前端 login() 的唯一判据 ★)
