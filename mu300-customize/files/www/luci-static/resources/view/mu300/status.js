'use strict';
'require view';
'require fs';
'require poll';

function fbytes(n) {
	n = Number(n) || 0;
	var u = [ 'B', 'KiB', 'MiB', 'GiB', 'TiB' ], i = 0;
	while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
	return '%.2f %s'.format(n, u[i]);
}

function frate(n) { return '%s/s'.format(fbytes(n)); }

function fup(s) {
	s = Number(s) || 0;
	var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
	if (d > 0) return '%dd %dh %dm'.format(d, h, m);
	if (h > 0) return '%dh %dm'.format(h, m);
	return '%dm %ds'.format(m, s % 60);
}

function readjson(p, cb) {
	fs.read(p).then(function(s) {
		var o = {};
		try { o = JSON.parse(s); } catch (e) { o = {}; }
		cb(o);
	}).catch(function() { cb({}); });
}

return view.extend({
	load: function() { return null; },

	render: function() {
		var cont = E('div');

		function section(title, rows) {
			return E('div', { class: 'cbi-section' }, [
				E('h4', {}, title),
				E('table', { class: 'table' }, E('tbody', {}, rows.map(function(r) {
					return E('tr', { class: 'tr' }, [
						E('td', { class: 'td left', width: '32%' }, E('strong', {}, r[0])),
						E('td', { class: 'td left', style: 'word-break:break-all;overflow-wrap:anywhere' }, (r[1] == null || r[1] === '') ? '-' : String(r[1]))
					]);
				})))
			]);
		}

		function draw(d) {
			var sig = (d.rsrp ? '%s dBm'.format(d.rsrp) : '-');
			if (d.quality) sig += ' (%s)'.format(d.quality);
			var sig2 = [];
			if (d.rsrq) sig2.push('RSRQ %s dB'.format(d.rsrq));
			if (d.sinr) sig2.push('SINR %s dB'.format(d.sinr));
			if (d.signal_src) sig2.push('(%s 测量)'.format(d.signal_src));

			var net = [
				[ '连接状态', d.wan4 ? '已连接' : '未连接' ],
				[ '网络制式', d.rat ],
				[ '运营商', (d.operator_name || d.operator) + (d.operator ? ' (%s)'.format(d.operator) : '') ],
				[ 'APN', d.apn ],
				[ 'WAN IPv4', d.wan4 ],
				[ 'WAN IPv6', d.wan6 ],
				[ '内网 IPv4', d.lan4 ],
				[ '内网 IPv6 前缀', d.lan6 ]
			];
			// 频段锁(掩码解码:5G 已知 4 个频段;4G 用标准 E-UTRA 位图)
			var NRK = [ { b: 1, m: 0, bit: 0 }, { b: 28, m: 0, bit: 9 }, { b: 41, m: 2, bit: 4 }, { b: 78, m: 2, bit: 8 } ];
			var LTE_B = [ 1, 3, 5, 8, 34, 38, 39, 40, 41 ];
			function mk(s) { return String(s || '').split(',').map(function(x) { return Number(x) || 0; }); }
			var nrm = mk(d.nr_band_mask), ltem = mk(d.lte_band_mask);
			var nrLock = NRK.filter(function(k) { return (nrm[k.m] || 0) & (1 << k.bit); }).map(function(k) { return 'n' + k.b; }).join(', ');
			var lteLock = LTE_B.filter(function(b) { var m = b <= 32 ? 3 : 1, bit = b <= 32 ? b - 1 : b - 33; return (ltem[m] || 0) & (1 << bit); }).map(function(b) { return 'B' + b; }).join(', ');
			// "当前正在用哪个频段"模组不提供(UFI-TOOLS 那也是走安卓厂商接口)✗
			// 能做的是:模组支持集 ∩ 锁定集 = 它实际可以在的频段集合 ✓(比只看锁定更准)
			var nrsup = mk(d.nr_supported_mask), ltesup = mk(d.lte_supported_mask);
			var nrUse = NRK.filter(function(k) { return ((nrm[k.m] || 0) & (1 << k.bit)) && ((nrsup[k.m] || 0) & (1 << k.bit)); }).map(function(k) { return 'n' + k.b; }).join(', ');
			var lteUse = LTE_B.filter(function(b) { var m = b <= 32 ? 3 : 1, bit = b <= 32 ? b - 1 : b - 33; return ((ltem[m] || 0) & (1 << bit)) && ((ltesup[m] || 0) & (1 << bit)); }).map(function(b) { return 'B' + b; }).join(', ');
			var band = [
				[ '当前可用 5G', (d.nr_supported_mask ? (nrUse || '无(锁定的频段模组不支持?)') : '(采集稍后)') ],
				[ '当前可用 4G', (d.lte_supported_mask ? (lteUse || '无') : '(采集稍后)') ],
				[ '5G 锁定频段', nrLock ? nrLock + '   (掩码 ' + (d.nr_band_mask || '-') + ')' : (d.nr_band_mask ? '未锁(掩码 ' + d.nr_band_mask + ')' : '-') ],
				[ '4G 锁定频段', lteLock ? lteLock + '   (掩码 ' + (d.lte_band_mask || '-') + ')' : (d.lte_band_mask ? '未锁(掩码 ' + d.lte_band_mask + ')' : '-') ],
				[ '模组支持 5G', d.supported_nr ? 'n' + String(d.supported_nr).split(',').join(', n') : '-' ]
			];
			// 服务小区 / 邻区(来自 /tmp/mu300-cells.json:工程模式 60 秒采一次)
			var cl = d.cells || {};
			var srv = cl.serving || {}, nbrs = cl.neighbors || [];
			var srvTxt = srv.pci ? ('PCI ' + srv.pci + ' @ ARFCN ' + srv.arfcn + '  (' + srv.band + ')' + (srv.rsrp ? '   RSRP ' + srv.rsrp + ' dBm' : '')) : '(采集稍后)';
			var nbrTxt = nbrs.map(function(n) { return 'PCI ' + n.pci + ' ' + n.band + ' ' + n.rsrp + 'dBm'; }).join('  /  ');
			var radio = [
				[ '信号强度', sig ],
				[ '质量参数', sig2.join(', ') ],
				[ '服务小区', srvTxt ],
				[ '可见小区', nbrTxt || '-' ],
				[ '5G 小区 (NR)', d.nr_cell ? (d.nr_cell + (d.nr_tac ? '    TAC ' + d.nr_tac : '')) : '-' ],
				[ '4G 小区 (LTE)', (d.lte_cell || d.cell || '-') + ((d.lte_tac || d.tac) ? '    TAC ' + (d.lte_tac || d.tac) : '') ]
			];
			var traf = [
				[ '今日 收 / 发', '%s / %s'.format(fbytes(d.today_rx), fbytes(d.today_tx)) ],
				[ '本次开机 收 / 发', '%s / %s'.format(fbytes(d.rx_bytes), fbytes(d.tx_bytes)) ],
				[ '实时速率 收 / 发', '%s / %s'.format(frate(d.rx_rate), frate(d.tx_rate)) ]
			];
			var wifi = [
				[ 'SSID', d.ssid ],
				[ '信道 / 频宽', (d.channel ? '%s MHz'.format(d.channel) : '-') + (d.wifi_band ? ' / %s'.format(d.wifi_band) : '') ],
				[ '已连客户端', d.clients ]
			];
			var dev = [
				[ '运行时间', fup(d.uptime) ],
				[ '温度', d.temperature ? '%s °C'.format(d.temperature) : '-' ],
				[ '固件', d.firmware ],
				[ '内核', d.kernel ]
			];

			cont.replaceChildren.apply(cont, [
				section('网络', net),
				section('信号', radio),
				section('频段锁', band),
				section('流量', traf),
				section('无线热点', wifi),
				section('设备', dev)
			]);
		}

		function draw_all() {
			// 慢档:制式/运营商/小区/频段(5 分钟一次)
			readjson('/tmp/mu300-status.json', function(s) {
				// 中档:信号 RSRP/RSRQ/SINR(20 秒一次,1 条 AT)
				readjson('/tmp/mu300-signal.json', function(sg) {
					for (var k in sg) s[k] = sg[k];
				// 服务小区 / 邻区(工程模式 AT+SPENGMD=0,14,1 / =2,60 秒一次)
				readjson('/tmp/mu300-cells.json', function(cl) {
					s.cells = cl;
				// 快档:速率/计数/在线时长/温度/WiFi(5 秒一次,纯 sysfs)
				readjson('/tmp/mu300-live.json', function(lv) {
					for (var k2 in lv) s[k2] = lv[k2];
					readjson('/tmp/mu300-traffic.json', function(t) {
						s.today_rx = 0; s.today_tx = 0;
						if (t.days && t.today && t.days[t.today]) {
							s.today_rx = Number(t.days[t.today].rx) || 0;
							s.today_tx = Number(t.days[t.today].tx) || 0;
						}
						draw(s);
					});
				});
				});
			});
			});
		}

		draw_all();
		poll.add(draw_all, 5);

		return E([], [
			E('h2', {}, '5G 状态'),
			cont,
			E('div', { class: 'cbi-section' }, E('p', { style: 'opacity:.75' }, '流量/速率/在线时长每 5 秒;信号每 20 秒;制式、运营商、小区、频段每 5 分钟(这些要查询模组,查询本身需要几秒)。'))
		]);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});