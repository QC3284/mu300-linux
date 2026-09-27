// 汇总客户端信息 -> JSON(给 LuCI 客户端管理页读)
// 注意:ucode 的 `for (x in array)` 拿到的是【下标】,必须自己索引取值
let fs = require('fs');
let CLIENTS_DB = '/etc/mu300/clients.json';
let OUT = '/tmp/mu300-clients.json';

let names = {};
try { names = json(fs.readfile(CLIENTS_DB) || '{}') || {}; } catch (e) { names = {}; }

function lines_of(path) {
	let s = '';
	try { s = fs.readfile(path) || ''; } catch (e) { s = ''; }
	return split(s, '\n');
}

// ① DHCP 租约: 到期时间 MAC IP 主机名 [client-id]
let lease_ip = {}, lease_host = {};
let L = lines_of('/tmp/dhcp.leases');
for (let i = 0; i < length(L); i++) {
	let f = split(trim(L[i]), ' ');
	if (length(f) < 4) continue;
	let mac = lc(f[1]);
	lease_ip[mac] = f[2];
	lease_host[mac] = (f[3] == '*' ? '' : f[3]);
}

// ② 无线客户端(iw station dump)
let wifi = {}, cur = null;
let S = lines_of('/tmp/mu300-wifi-stations.raw');
for (let i = 0; i < length(S); i++) {
	let ln = S[i];
	let m = match(ln, /^Station ([0-9a-fA-F:]+)/);
	if (m) { cur = lc(m[1]); wifi[cur] = {}; continue; }
	if (cur == null) continue;
	let k = match(trim(ln), /^([a-z_]+):[ \t]*(.*)$/);
	if (k) wifi[cur][k[1]] = trim(k[2]);
}

// ③ 邻居表(在线判定)
let neigh = {};
let N = lines_of('/tmp/mu300-neigh.raw');
for (let i = 0; i < length(N); i++) {
	let f = split(trim(N[i]), ' ');
	if (length(f) < 2) continue;
	// 两种形态:
	//   192.168.77.2 lladdr 02:50:00:00:77:02 REACHABLE   (4 字段)
	//   192.168.77.213 FAILED                            (2 字段,没有 MAC)
	let ip = f[0], mac = '', iface = '', state = f[length(f) - 1];
	for (let j = 1; j < length(f) - 1; j++) {
		if (f[j] == 'lladdr') mac = lc(f[j + 1]);
		else if (f[j] == 'dev') iface = f[j + 1];
	}
	if (!length(mac)) continue;
	neigh[mac] = { iface: iface, state: state };
	// 静态配了 IP 的设备(比如我们这台测试机)没有 DHCP 租约,IP 从邻居表补
	if (lease_ip[mac] == null) lease_ip[mac] = ip;
}

// 合并三个来源的 MAC
// ══ 网桥 FDB:每个 MAC 落在哪个物理口(★ 内核的表最可靠,sprd 的 iw station dump 常空 ✗)══
let brport = {};
let B = lines_of("/tmp/mu300-brports.raw");
for (let i = 0; i < length(B); i++) {
	let f = split(trim(B[i]), " ");
	if (length(f) >= 2) {
		// sysfs 的 port_no 是十六进制(0x1),brctl 输出是十进制(1)→ 统一成十进制 ✓
		let pn = '' + f[0];
		if (match(pn, /^0x/)) pn = '' + int(hex(substr(pn, 2)));
		brport[pn] = f[1];
	}
}
let fdb = {};
let F = lines_of("/tmp/mu300-brfdb.raw");
for (let i = 1; i < length(F); i++) {
	// ★ brctl showmacs 用 TAB 分隔 ✗ → 先归一化空白再切 ✓
	let f = split(replace(trim(F[i]), /[ \t]+/g, " "), " ");
	if (length(f) >= 3 && f[2] == "no") fdb[lc(f[1])] = brport[f[0]] || "";
}

let macs = {};
let keys = [];
for (let m in lease_ip) { if (!(m in macs)) { macs[m] = 1; push(keys, m); } }
for (let m in wifi)     { if (!(m in macs)) { macs[m] = 1; push(keys, m); } }
for (let m in neigh)    { if (!(m in macs)) { macs[m] = 1; push(keys, m); } }

let list = [];
for (let i = 0; i < length(keys); i++) {
	let m = keys[i], w = wifi[m] || {}, n = neigh[m] || {};
	push(list, {
		mac: m,
		name: names[m] || '',
		ip: lease_ip[m] || '',
		hostname: lease_host[m] || '',
		iface: (fdb[m] || (length(w) ? 'wlan0' : (n.iface || ''))),
		is_wifi: ((fdb[m] == 'wlan0') || length(w)) ? 1 : 0,
		online: (n.state != null && match(n.state, /REACHABLE|STALE|DELAY|PROBE/) != null),
		signal: w.signal || '',
		rx: w['rx bytes'] || '',
		tx: w['tx bytes'] || '',
		connected: w.connected_time || ''
	});
}
sort(list, (a, b) => {
	let an = split(a.ip || '255.255.255.255', '.'), bn = split(b.ip || '255.255.255.255', '.');
	for (let i = 0; i < 4; i++) { let x = +(an[i] || 0), y = +(bn[i] || 0); if (x != y) return x - y; }
	return 0;
});

fs.writefile(OUT, sprintf('%.J', { updated: time(), clients: list }));
print(sprintf('clients: %d (租约 %d, 无线 %d, 邻居 %d)\n', length(list), length(lease_ip), length(wifi), length(neigh)));