'use strict';
'require view';
'require fs';
'require ui';
'require poll';


// ---- 刷新控制条(模仿 UFI-TOOLS:立即刷新 + 间隔可选 + 停止)----
//   说明:原本做成独立模块,但本版 LuCI 的 require 不认普通对象/函数/Class 三种导出 ✗
//   所以内联进每个页面(能跑最重要)✓
function mkRefresh(key, defSec, fn) {
	var PREFIX = 'mu300-rf-';
	var SECS = [ 1, 2, 5, 10, 30, 60, 0 ];
	var raw = localStorage.getItem(PREFIX + key);
	var sec = (raw === null || raw === '' || isNaN(Number(raw))) ? defSec : Number(raw);
	var lastRun = 0;
	var info = E('span', { style: 'opacity:.55;font-size:.9em' }, '');
	var sel = E('select', { class: 'cbi-select', style: 'width:6.5em;margin:0' }, SECS.map(function(s) {
		var label = (s == 0) ? '停止' : (s + ' 秒');
	return (s == sec) ? E('option', { value: s, selected: true }, label) : E('option', { value: s }, label);
	}));
	function run() {
		lastRun = Date.now();
		try { fn(); } catch (e) { }
		info.textContent = '更新于 ' + new Date().toLocaleTimeString();
	}
	sel.addEventListener('change', function() {
		sec = Number(sel.value) || 0;
		localStorage.setItem(PREFIX + key, String(sec));
		lastRun = 0; if (sec) run();
	});
	var btn = E('button', { class: 'cbi-button', style: 'margin:0;padding:.25em .7em', title: '立即刷新' }, '↻ 刷新');
	btn.addEventListener('click', function(ev) { ev.preventDefault(); run(); });
	poll.add(function() { if (sec && Date.now() - lastRun >= sec * 1000) run(); }, 1);
	if (sec) setTimeout(run, 50);
	return E('div', { style: 'display:flex;align-items:center;flex-wrap:wrap;gap:.5em;margin:.4em 0' }, [
		btn, ' 刷新:', sel, info
	]);
}

function fbytes(n) {
	n = Number(n) || 0;
	var u = [ 'B', 'KiB', 'MiB', 'GiB', 'TiB' ], i = 0;
	while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
	return '%.2f %s'.format(n, u[i]);
}

function fsec(s) {
	s = Number(s) || 0;
	var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
	if (h > 0) return '%dh %dm'.format(h, m);
	if (m > 0) return '%dm'.format(m);
	return '%ds'.format(s);
}

return view.extend({
	load: function() { return null; },

	render: function() {
		var box = E('div', {}, E('p', {}, '载入中…'));
		var hint = E('span', { style: 'opacity:.7;margin-left:.8em' }, '');
		function say(s) { hint.textContent = s || ''; }

		function ask(keys) {
			return fs.write('/tmp/mu300-clients.req', keys + '\n').then(function() {
				say('已提交…');
				setTimeout(refresh, 3000);
				setTimeout(function() { refresh(); show_out(); }, 7000);
			}).catch(function(e) { say('写入请求失败: ' + e); });
		}

		function show_out() {
			fs.read('/tmp/mu300-clients.out').then(function(o) { say(o.replace(/^[\s\S]*?---\n/, '').trim()); }).catch(function() { });
		}

		function refresh() {
			fs.read('/tmp/mu300-clients.json').then(function(s) { draw(JSON.parse(s)); }).catch(function() {
				box.replaceChildren(E('p', {}, '还没有客户端数据(守护每 30 秒采集一次)。'));
			});
		}

		function draw(d) {
			var cs = (d && d.clients) || [];
			if (!cs.length) { box.replaceChildren(E('p', {}, '目前没有客户端。')); return; }

			var head = E('tr', { class: 'tr' }, [ '备注名', 'IP', 'MAC', '接口', '信号', '时长', '流量收/发', '状态', '操作' ].map(function(h) {
				return E('th', { class: 'th' }, h);
			}));

			var rows = cs.map(function(c) {
				var nameIn = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:9em', value: c.name || '', placeholder: c.hostname || '' });
				nameIn.addEventListener('keydown', function(ev) {
					if (ev.key === 'Enter') ask('action=rename\nmac=' + c.mac + '\nname=' + nameIn.value);
				});
				return E('tr', { class: 'tr' }, [
					E('td', { class: 'td' }, nameIn),
					E('td', { class: 'td' }, c.ip || '-'),
					E('td', { class: 'td', style: 'font-family:monospace;font-size:.9em' }, c.mac),
					E('td', { class: 'td' }, c.iface || '-'),
					E('td', { class: 'td' }, c.signal ? (c.signal + ' dBm') : '-'),
					E('td', { class: 'td' }, c.connected ? fsec(c.connected) : '-'),
					E('td', { class: 'td' }, (c.rx ? fbytes(c.rx) : '-') + ' / ' + (c.tx ? fbytes(c.tx) : '-')),
					E('td', { class: 'td' }, c.online ? '在线' : '离线'),
					E('td', { class: 'td' }, [
						E('button', { class: 'cbi-button', click: function() { ask('action=rename\nmac=' + c.mac + '\nname=' + nameIn.value); } }, '存名字'), ' ',
						E('button', { class: 'cbi-button cbi-button-remove', click: function() {
							if (confirm('把 ' + (c.name || c.ip || c.mac) + ' 踢下线?')) ask('action=kick\nmac=' + c.mac);
						} }, '踢下线'), ' ',
						E('button', { class: 'cbi-button', click: function() {
							var ip = prompt('给这个 MAC 固定一个 IP:', c.ip || '');
							if (ip) ask('action=static\nmac=' + c.mac + '\nip=' + ip + '\nname=' + (nameIn.value || ''));
						} }, '固定IP')
					])
				]);
			});

			// 表格列多,包一层横向滚动,避免窄屏撑破布局(用户反馈过“错位”)
			box.replaceChildren(E('div', { style: 'overflow-x:auto' }, E('table', { class: 'table' }, [ E('thead', {}, head), E('tbody', {}, rows) ])));
		}

		refresh();
		var rc = mkRefresh('clients', 15, refresh);

		return E([], [
			E('h2', {}, '客户端管理'),
			rc,
			E('div', { class: 'cbi-section' }, [
				E('p', {}, '备注名会保存在设备上(按 MAC 记);踢下线对无线客户端是 deauth,有线设备无效。'),
				E('div', {}, [ E('button', { class: 'cbi-button cbi-button-apply', click: function() { ask('action=refresh'); } }, '刷新'), hint ])
			]),
			E('h4', {}, '在线客户端'),
			box
		]);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});