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
		var summary = E('tbody');
		var sumtbl = E('table', { class: 'table' }, summary);
		var bars = E('div');
		var sess_rx = 0, sess_tx = 0;   // 本次开机接口计数(从 5G 状态的 JSON 取)

		function draw(t) {
			var days = t.days || {}, today = t.today || '', month = today.length >= 7 ? today.substring(0, 7) : '';
			var t_rx = 0, t_tx = 0, m_rx = 0, m_tx = 0, list = [];

			for (var d in days) {
				var rx = Number(days[d].rx) || 0, tx = Number(days[d].tx) || 0;
				if (d === today) { t_rx = rx; t_tx = tx; }
				if (month && d.substring(0, 7) === month) { m_rx += rx; m_tx += tx; }
				list.push([ d, rx, tx ]);
			}
			list.sort(function(a, b) { return a[0] < b[0] ? 1 : (a[0] > b[0] ? -1 : 0); });

			summary.replaceChildren.apply(summary, [
				[ '今日', '%s / %s'.format(fbytes(t_rx), fbytes(t_tx)) ],
				[ '本月', '%s / %s'.format(fbytes(m_rx), fbytes(m_tx)) ],
				[ '本次开机(接口计数)', '%s / %s'.format(fbytes(sess_rx), fbytes(sess_tx)) ]
			].map(function(r) {
				return E('tr', { class: 'tr' }, [
					E('td', { class: 'td left', width: '40%' }, E('strong', {}, r[0])),
					E('td', { class: 'td left' }, r[1])
				]);
			}));

			var recent = list.slice(0, 7), max = 1;
			recent.forEach(function(r) { if (r[1] + r[2] > max) max = r[1] + r[2]; });

			// 用表格排版(比固定宽度 inline-block 更抗窄屏,避免错位)
			bars.replaceChildren.apply(bars, recent.length ? [
				E('div', { style: 'overflow-x:auto' }, E('table', { class: 'table' }, E('tbody', {}, recent.map(function(r) {
					return E('tr', { class: 'tr' }, [
						E('td', { class: 'td left', style: 'white-space:nowrap' }, r[0]),
						E('td', { class: 'td left', style: 'white-space:nowrap' }, '%s / %s'.format(fbytes(r[1]), fbytes(r[2]))),
						E('td', { class: 'td left', width: '40%' }, E('div', { style: 'background:rgba(127,127,127,.22);border-radius:3px;height:14px;width:100%;overflow:hidden' },
							E('div', { style: 'background:var(--card-accent,var(--primary,#4a90d9));border-radius:3px;height:14px;width:%d%%'.format(Math.max(2, Math.round((r[1] + r[2]) * 100 / max))) }, '')))
					]);
				}))))
			] : [ E('p', {}, '还没有数据(守护每 30 秒采一次)。') ]);
		}

		function draw_all() {
			readjson('/tmp/mu300-status.json', function(s) {
				sess_rx = Number(s.rx_bytes) || 0;
				sess_tx = Number(s.tx_bytes) || 0;
				readjson('/tmp/mu300-traffic.json', draw);
			});
		}

		draw_all();
		poll.add(draw_all, 15);

		return E([], [
			E('h2', {}, '流量统计'),
			E('div', { class: 'cbi-section' }, sumtbl),
			E('div', { class: 'cbi-section' }, [ E('h4', {}, '最近 7 天'), bars ]),
			E('div', { class: 'cbi-section' }, E('p', {}, '按天累计,存在 /etc/mu300/traffic.json,重启不丢。'))
		]);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});