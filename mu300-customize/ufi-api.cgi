#!/usr/bin/ucode
// ufi-api:UFI-TOOLS 兼容后台(CGI,部署为 /www/ufi/api)
//   uhttpd -h /www/ufi -x /api -p 0.0.0.0:2333
//   ⚠ ucode 的 exit() 在 uhttpd CGI 下不 flush 输出 → 一律用 return
//   ⚠ 没有 isNaN/Math/JSON/数组方法;map 是全局函数;没有 urldecode
'use strict';
let fs = require('fs');
let PW_HASH = 'ae8ce4b50a5605fd6cf30183a68661d06cccce17e510bffc4ea310bf61fd6f97';

function readjson(p) { try { return json(fs.readfile(p) || '{}') || {}; } catch (e) { return {}; } }
function readstr(p) { try { return fs.readfile(p) || ''; } catch (e) { return ''; } }
function num(v) { let n = +v; return (n != n) ? 0 : n; }
function reply(code, ctype, b) {
	printf('Status: %d\r\nContent-Type: %s; charset=utf-8\r\nCache-Control: no-store\r\n\r\n', code, ctype || 'application/json');
	print(b || '');
}
function jreply(o) { reply(200, 'application/json', sprintf('%.J', o)); }
function urldec(s) {
	let out = '', i = 0, n = length(s);
	while (i < n) {
		let c = substr(s, i, 1);
		if (c == '%' && i + 2 < n) { out += chr(hex(substr(s, i + 1, 2))); i += 3; }
		else if (c == '+') { out += ' '; i++; }
		else { out += c; i++; }
	}
	return out;
}
function qget(qs, key) {
	for (let kv in split(qs, '&')) {
		let kvp = split(kv, '=');
		if (kvp[0] == key) return urldec(kvp[1] || '');
	}
	return '';
}

function run(pi, qs, auth) {
	// need_token=false → 前端【完全不显示登录框】(UFI 自己的开关 ✓)
	// 我们这边没有中兴网站,第二个密码永远校验不过 ✗ → 干脆关掉登录
	if (pi == '/need_token')      { jreply({ need_token: true }); return; }
	if (pi == '/version_info')    { jreply({ app_ver: '4.1.5', app_ver_code: '20260919', model: 'F50', nickname: 'ImmortalWrt', accept_terms: true }); return; }
	if (pi == '/SELinux')         { jreply({ selinux: 'Permissive' }); return; }
	if (pi == '/get_theme')       { jreply(readjson('/etc/mu300/ufi-theme.json')); return; }
	if (pi == '/get_custom_head') { reply(200, 'text/plain', ''); return; }
	if (pi == '/set_cookie')      {
		try {
			// CGI 的 POST 体从 stdin 读(简单起见:给多少存多少)
			let body = fs.stdin.read('all') || '';
			let m2 = match(body, /"cookie"\s*:\s*"([^"]*)"/);
			if (m2) fs.write('/etc/mu300/ufi-admin-pwd', m2[1]);
		} catch (e) { }
		reply(200, 'application/json', '{"result":true}'); return; }
	if (pi == '/get_cookie')      { jreply({ cookie: 'immortalwrt-lan-ok' }); return; }   // 非空:前端用真假判登录 ✓
	if (pi == '/get_official_web_password') { jreply({ pwd: readstr('/etc/mu300/ufi-admin-pwd') }); return; }
	if (pi == '/accept_terms')    { reply(200, 'application/json', '{"result":"success"}'); return; }
	if (pi == '/is_weak_token')   { jreply({ is_weak_token: false }); return; }
	if (pi == '/login' || pi == '/user') { jreply({ result: 'success', user: 'admin' }); return; }
	// ⚠ 鉴权从宽:前端在"登录"前后都会调这些接口,硬拦会显示"登录失败 请检查网络" ✗
	//   需要收紧时改成: if (auth != PW_HASH && pi != '/adb_alive' && ...) …
	let authed = (auth == PW_HASH);

	let live    = readjson('/tmp/mu300-live.json');
	let signal  = readjson('/tmp/mu300-signal.json');
	let cells   = readjson('/tmp/mu300-cells.json');
	let status  = readjson('/tmp/mu300-status.json');
	let modes   = readjson('/tmp/mu300-modes.json');
	let traffic = readjson('/etc/mu300/traffic.json');

	if (pi == '/AT') {
		let cmd = trim(qget(qs, 'command'));
		if (substr(lc(cmd), 0, 2) != 'at') { jreply({ error: 'AT 指令需要以 AT 开头' }); return; }
		let safe = '';
		for (let ch in split(cmd, '')) { if (match(ch, /[A-Za-z0-9+,=_:"$?.!#\/ -]/)) safe += ch; }
		let out = '';
		let fh = fs.popen("/opt/mu300/bin/mu300-at -t 12 '" + safe + "' 2>&1", 'r');
		if (fh) { out = fh.read('all') || ''; fh.close(); }
		out = trim(replace(replace(out, /\r/g, ''), /\n/g, ' '));
		if (substr(lc(out), length(out) - 2) == 'ok') out = trim(substr(out, 0, length(out) - 2)) + ' OK';
		if (!out) out = '(无输出)';
		jreply({ result: out });
		return;
	}

	if (pi == '/baseDeviceInfo') {
		let days = traffic.days || {}, total = 0, today = 0;
		for (let k in days) { total += num(days[k].rx) + num(days[k].tx); }
		if (traffic.today && days[traffic.today]) today = num(days[traffic.today].rx) + num(days[traffic.today].tx);

		// CPU 占用:两次 /proc/stat 采样求差(存上一次到 /tmp)
		let cpu_usage = 0;
		try {
			let st = fs.readfile('/proc/stat') || '';
			let l1 = split(split(st, '\n')[0], ' ');
			let idle = num(l1[4]) + num(l1[5]);
			let tot = 0;
			for (let m in slice(l1, 1, 9)) { tot += num(m); }
			let prev = readjson('/tmp/ufi-cpu-prev.json');
			if (prev.t && prev.i != null && tot > prev.t) {
				cpu_usage = int((1 - (idle - prev.i) / (tot - prev.t)) * 100);
				if (cpu_usage < 0) cpu_usage = 0;
				if (cpu_usage > 100) cpu_usage = 100;
			}
			fs.write('/tmp/ufi-cpu-prev.json', sprintf('{"t":%d,"i":%d}', tot, idle));
		} catch (e) { }


		// 每核 CPU 占用 + 每核频率(安卓 UFI 的 cpuUsageInfo / cpuFreqInfo ✓)
		let cpuUsageInfo = {}, cpuFreqInfo = {}, coreT = {}, coreI = {};
		try {
			let prev2 = readjson('/tmp/ufi-percpu-prev.json');
			for (let ln in split(trim(fs.readfile('/proc/stat') || ''), '\n')) {
				if (!match(ln, /^cpu[0-9]+ /)) continue;
				let p2 = split(ln, ' ');
				let id = substr(p2[0], 3);
				let idle2 = num(p2[4]) + num(p2[5]), tot2 = 0;
				for (let m2 in slice(p2, 1, 9)) { tot2 += num(m2); }
				coreT[id] = tot2; coreI[id] = idle2;
				if (prev2[id] && tot2 > prev2[id].t) {
					let u = int((1 - (idle2 - prev2[id].i) / (tot2 - prev2[id].t)) * 100);
					if (u < 0) u = 0; if (u > 100) u = 100;
					cpuUsageInfo['cpu' + id] = sprintf('%.1f', u);
				}
			}
			let save2 = {};
			for (let id in coreT) { save2[id] = { t: coreT[id], i: coreI[id] }; }
			fs.write('/tmp/ufi-percpu-prev.json', sprintf('%.J', save2));
			// 每核频率(kHz → MHz)
			for (let n2 = 0; n2 < 8; n2++) {
				let base2 = '/sys/devices/system/cpu/cpu' + n2 + '/cpufreq/';
				let cur2 = num(readstr(base2 + 'scaling_cur_freq'));
				let mx2 = num(readstr(base2 + 'cpuinfo_max_freq'));
				if (cur2 > 0) cpuFreqInfo['cpu' + n2] = { cur: int(cur2 / 1000), max: int(mx2 / 1000) };
			}
		} catch (e) { }

		// 内存占用百分比
		let mem_usage = 0;
		if (num(modes.mem_total) > 0) mem_usage = int(num(modes.mem_used) * 100 / num(modes.mem_total));

		// 开机时间(unix 秒)
		let boot_time = 0;
		try { let up = num(split(trim(fs.readfile('/proc/uptime') || '0'), ' ')[0]); boot_time = time() - up; } catch (e) { }

		// 存储(取根分区)
		let isz = 0, iused = 0;
		for (let s2 in (modes.storage || [])) {
			if (s2.mount == '/' || s2.mount == '/mnt/mu300-disk') { isz = num(s2.size_mb); iused = num(s2.used_mb); break; }
		}

		let tp = (modes.temps || []);
		jreply({ app_ver: '4.1.5', app_ver_code: '20260919', model: 'F50',
			battery: '0', voltage_now: '0', current_now: '0',
			client_ip: getenv('REMOTE_ADDR') || '',
			boot_time: num(live.uptime),
			cpu_usage: cpu_usage,
			cpuUsageInfo: cpuUsageInfo,
			cpuFreqInfo: cpuFreqInfo,
			memInfo: { mem_total_kb: num(modes.mem_total) * 1024, mem_used_kb: num(modes.mem_used) * 1024, mem_available_kb: (num(modes.mem_total) - num(modes.mem_used)) * 1024 },
			mem_usage: mem_usage,
			cpu_temp: (function() { let mx = 0; for (let q in tp) { if (num(q.v) > mx) mx = num(q.v); } return int(mx * 1000 + 0.5); })(),
			cpu_temp_list: map(tp, function(t) { return { type: t.t, temp: int(num(t.v) * 1000 + 0.5) }; }),
			daily_data: today, monthly_data: total,
			is_reached_data_flow_limit: false,
			internal_total_storage: isz * 1024 * 1024,
			internal_used_storage: iused * 1024 * 1024,
			internal_available_storage: (isz - iused) * 1024 * 1024,
			external_total_storage: 0, external_used_storage: 0, external_available_storage: 0 });
		return;
	}

	if (pi == '/goform/goform_set_cmd_process') {
		// 前端登录会发 goformId=LOGIN;我们这边没有中兴网站 → 一律成功 ✓
		jreply({ result: 'success' });
		return;
	}

	if (pi == '/goform/goform_get_cmd_process') {
		let cmds = qget(qs, 'cmd'), o = {};
		// 实时速率:用 live 计数的两次采样求差
		let rx_rate = 0, tx_rate = 0;
		try {
			let now2 = { t: time(), rx: num(live.rx_bytes), tx: num(live.tx_bytes) };
			let pv = readjson('/tmp/ufi-rate-prev.json');
			if (pv.t && now2.t > pv.t) {
				let dt = now2.t - pv.t;
				rx_rate = int((now2.rx - num(pv.rx)) / dt); if (rx_rate < 0) rx_rate = 0;
				tx_rate = int((now2.tx - num(pv.tx)) / dt); if (tx_rate < 0) tx_rate = 0;
			}
			fs.write('/tmp/ufi-rate-prev.json', sprintf('{"t":%d,"rx":%d,"tx":%d}', now2.t, now2.rx, now2.tx));
		} catch (e) { }
		let days2 = traffic.days || {}, m_rx = 0, m_tx = 0;
		for (let k in days2) { m_rx += num(days2[k].rx); m_tx += num(days2[k].tx); }
		let smslist = readjson('/tmp/mu300-sms.json');
		let unread = 0;
		for (let s3 in (smslist.messages || [])) { if (!s3.read) unread++; }
		let clients = readjson('/tmp/mu300-clients.json');
		for (let c in split(cmds, ',')) {
			if (c == 'network_type')            o[c] = status.rat || '-';
			else if (c == 'network_information') o[c] = '';
			else if (c == 'network_provider')   o[c] = '中国联通';
			else if (c == 'network_signalbar')  o[c] = '';
			else if (c == 'signalbar')          o[c] = (num(signal.rsrp) > -95 ? '5' : (num(signal.rsrp) > -105 ? '4' : '3'));
			else if (c == 'rssi')               o[c] = (num(signal.rsrp) > -95 ? '5' : (num(signal.rsrp) > -105 ? '4' : '3'));
			else if (c == 'network_rssi')       o[c] = signal.rsrp || '';
			else if (c == 'Z5g_rsrp')           o[c] = signal.rsrp || '';
			else if (c == 'lte_rsrp')           o[c] = signal.rsrp || '';
			else if (c == 'Z5g_rsrq')           o[c] = signal.rsrq || '';
			else if (c == 'Z5g_snr')            o[c] = signal.sinr || '';
			else if (c == 'wan_ipaddr')         o[c] = split(live.wan4 || '', '/')[0];
			else if (c == 'ipv6_wan_ipaddr')    o[c] = '';
			else if (c == 'lan_ipaddr')         o[c] = '192.168.77.1';
			else if (c == 'mac_address')        o[c] = readstr('/sys/class/net/br-lan/address') || '';
			else if (c == 'cell_id')            o[c] = '';
			else if (c == 'sim_slot')           o[c] = '1';
			else if (c == 'dual_sim_support')   o[c] = '0';
			else if (c == 'usb_port_switch')    o[c] = '1';
			else if (c == 'ppp_status')         o[c] = 'ipv4_ipv6_connected';
			else if (c == 'realtime_rx_thrpt')  o[c] = '' + rx_rate;
			else if (c == 'realtime_tx_thrpt')  o[c] = '' + tx_rate;
			else if (c == 'realtime_time')      o[c] = '' + num(live.uptime);
			else if (c == 'monthly_rx_bytes')   o[c] = '' + m_rx;
			else if (c == 'monthly_tx_bytes')   o[c] = '' + m_tx;
			else if (c == 'monthly_time')       o[c] = '' + num(live.uptime);
			else if (c == 'sms_unread_num' || c == 'sms_sim_unread_num') o[c] = '' + unread;
			else if (c == 'sms_received_flag')  o[c] = unread ? '1' : '0';
			else if (c == 'wifi_access_sta_num') o[c] = '' + length(clients.clients || clients.list || []);
			else if (c == 'battery_value' || c == 'battery_charging' || c == 'battery_vol_percent') o[c] = '';
			else if (c == 'imei' || c == 'imsi' || c == 'iccid' || c == 'msisdn' || c == 'sim_msisdn') o[c] = readjson('/etc/mu300/ufi-ident.json')[c] || '';
			else if (c == 'data_volume_limit_switch') o[c] = '1';
			else if (c == 'data_volume_limit_size' || c == 'data_volume_alert_percent') o[c] = '0';
			else if (c == 'Lte_ca_status')      o[c] = 'off';
			else if (c == 'loginfo')            o[c] = 'ok';   // ★ 前端 login() 靠这个判登录成功
			else if (c == 'cr_version')         o[c] = 'MU300_ZYV1.0.0B09';
			else if (c == 'neighbor_cell_info')
				o[c] = sprintf('%.J', map(cells.neighbors || [], function(n) {
					return { band: replace('' + (n.band || ''), /^n/, ''), earfcn: n.arfcn, pci: n.pci, rsrp: n.rsrp, rsrq: n.rsrq, sinr: n.sinr }; }));
			else if (c == 'locked_cell_info')   o[c] = '[]';
			else o[c] = '';
		}
		jreply(o);
		return;
	}

	if (pi == '/getSupportNrBandList') { jreply({ slot: 0, band_list: [ 6, 41, 78, 1, 8, 28, 5 ] }); return; }
	if (pi == '/device_id')   { jreply({ device_id: readstr('/etc/mu300/ufi-device-id') || '0a36488d00922a29' }); return; }
	if (pi == '/hasTTYD')     { jreply({ code: '200', ip: '192.168.77.1:22' }); return; }
	if (pi == '/usb_status')  { jreply({ maxSpeed: 0, details: { typec_mode: 'gadget', gadget_speed: 'USB 3.0 (5Gbps)', devices: [] } }); return; }
	if (pi == '/adb_alive')   { jreply({ result: 'false' }); return; }
	if (pi == '/root_shell' || pi == '/one_click_shell' || pi == '/user_shell') { jreply({ result: 'success' }); return; }
	if (pi == '/get_log_status') { jreply({ debug_log_enabled: 'false' }); return; }
	if (pi == '/volte_status')   { jreply({ enabled: true }); return; }
	if (pi == '/vonr_status')    { jreply({ enabled: false }); return; }
	if (pi == '/get_data_limit') { jreply({ data_flow_limit_enabled: '0', data_flow_max_limit: -1, data_flow_check_daily_or_monthly: 'monthly', data_check_reference: 'default', data_limit_status_forward_enabled: '0' }); return; }
	if (pi == '/list_tasks' || pi == '/get_task') { jreply({ tasks: [] }); return; }
	if (pi == '/power_status_forward_enabled') { jreply({ enabled: '0' }); return; }
	if (pi == '/sms_forward_enabled')  { jreply({ enabled: '1' }); return; }
	if (pi == '/sms_forward_method')   { jreply({ sms_forward_method: 'SMTP' }); return; }
	if (pi == '/sms_forward_dingtalk') { jreply({ webhook_url: '', secret: '', forward_dev_info: '0' }); return; }
	if (pi == '/sms_forward_mail')     { jreply({ smtp_host: '', smtp_port: '', smtp_to: '', smtp_username: '', smtp_password: '', smtp_from: '', smtp_from_name: '', forward_dev_info: '0' }); return; }
	if (pi == '/sms_forward_curl')     { jreply({ curl_text: '' }); return; }
	if (pi == '/sms_forward_blacklist'){ jreply({ keywords: '', phone: '' }); return; }
	if (pi == '/check_update')  { jreply({ has_update: false, latest_version: '4.1.5' }); return; }
	if (pi == '/plugins_store') { jreply({ plugins: [] }); return; }
	if (pi == '/speedtest')     { jreply(readjson('/tmp/mu300-speed.json')); return; }
	if (pi == '/connInfo') {
		let st2 = readjson('/tmp/ufi-conninfo.json');
		if (!st2.t || time() - st2.t > 8) {
			let s4 = '';
			try { s4 = fs.popen("awk 'NR>1{n[$4]++} END{for(k in n) printf \"%s=%d\\n\", k, n[k]}' /proc/net/tcp /proc/net/tcp6 /proc/net/udp 2>/dev/null", 'r').read('all') || ''; } catch (e) { }
			let c2 = { tcp: 0, tcp_active: 0, tcp_other: 0, tcp6: 0, udp: 0, udp6: 0, unix: 0 };
			for (let ln2 in split(trim(s4), '\n')) { let kv = split(ln2, '='); if (length(kv) == 2) c2[kv[0]] = num(kv[1]); }
			c2.tcp_active = c2.tcp;
			st2 = { t: time(), v: c2 };
			fs.write('/tmp/ufi-conninfo.json', sprintf('%.J', st2));
		}
		jreply({ result: 'success', data: st2.v || {} });
		return;
	}
	if (pi == '/cellularUsage') { jreply({ result: 'success', data: [] }); return; }
	if (pi == '/adb_wifi_setting') { jreply({ enabled: true }); return; }
	if (pi == '/disable_fota')    { jreply({ result: '执行成功,如需强力禁用请使用高级功能!' }); return; }
	if (pi == '/download_apk_status') { jreply({ status: 'idle', percent: 0, error: '' }); return; }
	if (pi == '/get_res_server')  { jreply({ res_server: readstr('/etc/mu300/ufi-res-server') || 'https://pan.kanokano.cn' }); return; }

	try { fs.write('/tmp/ufi-api-404.log', (fs.readfile('/tmp/ufi-api-404.log') || '') + pi + '\n'); } catch (e) { }
	reply(404, 'application/json', sprintf('%.J', { error: 'not implemented', path: pi }));
}

try {
	run(getenv('PATH_INFO') || '', getenv('QUERY_STRING') || '', getenv('HTTP_AUTHORIZATION') || '');
} catch (e) {
	try { fs.write('/tmp/ufi-api-err.log', sprintf('%s\n%.J\n', e, e)); } catch (x) { }
	printf('Status: 500 Internal Server Error\r\nContent-Type: application/json\r\n\r\n{"error":"internal"}');
}
