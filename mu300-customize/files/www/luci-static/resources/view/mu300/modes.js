'use strict';
'require view';
'require fs';
'require poll';

// 系统模式页:性能模式(UFI 9.1)+ CPU 状态(UFI 6.6)+ 高铁模式(UFI AT 快捷指令)
//   性能模式 走厂商工具 mu300-toolkit profile eco|balanced|performance(含 GPU)
//   高铁模式 模组只提供读(SP5GCMDS get nr synch_param,44),写不支持 → 只显示
return view.extend({
	load: function() { return null; },

	render: function() {
		var hint = E('span', { style: 'opacity:.75;margin-left:.8em' }, '');
		var cont = E('div', {}, E('p', {}, '载入中…'));
		// ---- 网络:APN + 5G 开关(输入框只建一次,draw 只更新值 —— 否则编辑会被刷新冲掉 ✗)----
		var apnIn = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:16em;margin:0', placeholder: '留空=运营商默认' });
		var apnHint = E('span', { style: 'opacity:.75' }, '');
		var fivHint = E('span', { style: 'opacity:.75' }, '');
		var fivRow = E('div', {}, '读取中…');
		function saveApn() {
			var v = (apnIn.value || '').trim().replace(/[^A-Za-z0-9._-]/g, '');
			if (!confirm('把 APN 设为【' + (v || '运营商默认') + '】并重新拨号?\n\n会短暂断网(约 10 秒)。')) return;
			fs.write('/tmp/mu300-modes.req', 'apn:' + v).then(function() { apnHint.textContent = '已提交,正在重新拨号…'; })
				.catch(function(e) { apnHint.textContent = '提交失败: ' + e; });
		}
		function toggle5g() { location.href = '#'; }
		function set5g(v) {
			if (!confirm((v == '1' ? '打开' : '关闭') + ' 5G?\n\n关闭后只能用 4G/3G。会短暂断网。')) return;
			fs.write('/tmp/mu300-modes.req', '5gran:' + v).then(function() { fivHint.textContent = '已提交…'; })
				.catch(function(e) { fivHint.textContent = '提交失败: ' + e; });
		}
		// ---- Ping 工具(对齐 UFI 顶部的 Ping)----
		var pingHost = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:18em;margin:0', value: '223.5.5.5', placeholder: 'IP 或域名' });
		var pingHint = E('span', { style: 'opacity:.75' }, '');
		function doPing() {
			var h = (pingHost.value || '').trim().replace(/[^A-Za-z0-9.:_-]/g, '');
			if (!h) { pingHint.textContent = '请填主机名或 IP'; return; }
			fs.write('/tmp/mu300-tools.req', 'ping:' + h).then(function() { pingHint.textContent = '已提交,约 5 秒…'; })
				.catch(function(e) { pingHint.textContent = '提交失败: ' + e; });
		}
		var pingOut = E('pre', { style: 'white-space:pre-wrap;max-height:12em;overflow:auto;margin-top:.5em;font-size:.85em' }, '');
		function pollPing() {
			fs.read('/tmp/mu300-tools.out').then(function(s) {
				if (pingOut.textContent !== s) pingOut.textContent = s;
			}).catch(function() { });
		}
		var PROFS = [
			[ 'eco', '节能', 'schedutil,频率上限压到约 60%(发热最低)' ],
			[ 'balanced', '均衡', 'schedutil,全频(默认)' ],
			[ 'performance', '性能', 'performance governor,全频(最快,发热最高)' ]
		];

		
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

function mhz(v) { v = Number(v) || 0; return v ? Math.round(v / 1000) + ' MHz' : '-'; }

		function apply(p) {
			if (!confirm('切换到【' + p + '】档?\n\n性能档发热与耗电会明显上升,节能档会限制最高频率。')) return;
			fs.write('/tmp/mu300-modes.req', 'profile ' + p).then(function() {
				hint.textContent = '已提交切换…(约 3 秒)';
				setTimeout(function() { hint.textContent = '已切换为 ' + p + ' ✓'; }, 4000);
			}).catch(function(e) { hint.textContent = '提交失败: ' + e; });
		}

		function section(t, rows) {
			return E('div', { class: 'cbi-section' }, [
				E('h4', {}, t),
				E('table', { class: 'table' }, E('tbody', {}, rows.map(function(r) {
					return E('tr', { class: 'tr' }, [
						E('td', { class: 'td left', width: '26%' }, E('strong', {}, r[0])),
						E('td', { class: 'td left' }, r[1])
					]);
				})))
			]);
		}

		function draw(d) {
			var prof = d.profile || '-',
				pname = { eco: '节能', balanced: '均衡', performance: '性能' }[prof] || prof;
			var rail = (d.rail === '1') ? '已开启 ✓' : (d.rail === '0' ? '已关闭' : '读取不到');
			var btns = PROFS.map(function(p) {
				return E('button', {
					class: 'cbi-button ' + (p[0] == prof ? 'cbi-button-apply' : ''),
					style: 'margin-right:.5em' + (p[0] == prof ? ';font-weight:bold' : ''),
					title: p[2] + (p[0] == prof ? '(当前)' : ''),
					click: function() { apply(p[0]); }
				}, p[1] + (p[0] == prof ? ' ●' : ''));
			});
			cont.replaceChildren(
				E('div', { class: 'cbi-section' }, [
					E('h4', {}, '性能模式'),
					E('p', { style: 'opacity:.75' }, '调整 CPU/GPU 的运行策略(散热与性能的取舍)。测速、跑代理/插件时可选性能档;日常均衡即可。'),
					// 注意:btn 是数组,必须展开(直接放进 children 会渲染成 [object HTMLButtonElement] ✗)
					E('div', {}, btns.concat([ hint ])),
					E('p', { style: 'margin-top:.5em' }, '当前:  ' + pname + '(governor ' + (d.governor || '-') + ')')
				]),
				section('CPU 与内存', [
					[ 'CPU 负载', (d.load1 || '-') + ' / ' + (d.load5 || '-') + ' / ' + (d.load15 || '-') ],
					[ '大核 (cpu4)', mhz(d.cpu4 && d.cpu4.cur) + '  /  上限 ' + mhz(d.cpu4 && d.cpu4.max) + '  (硬件最高 ' + mhz(d.cpu4 && d.cpu4.hwmax) + ')' ],
					[ '小核 (cpu0)', mhz(d.cpu0 && d.cpu0.cur) + '  /  上限 ' + mhz(d.cpu0 && d.cpu0.max) + '  (硬件最高 ' + mhz(d.cpu0 && d.cpu0.hwmax) + ')' ],
					[ '内存', (d.mem_used || 0) + ' / ' + (d.mem_total || 0) + ' MiB' ],
					[ '温度', (d.temperature || '-') + ' °C' ]
				]),
				section('高铁模式', [
					[ '状态', rail ]
				]),
				// 网络:APN + 5G 开关(值在这里更新,控件本身不重建)
				(function() {
					if (document.activeElement !== apnIn) apnIn.value = d.apn || '';
					var fg = (d.fiveg === '1');
					fivRow.replaceChildren(
						E('span', { style: 'margin-right:.8em' }, fg ? '5G:已开启 ✓' : '5G:已关闭'),
						E('button', { class: 'cbi-button ' + (fg ? 'cbi-button-remove' : 'cbi-button-apply'), click: function() { set5g(fg ? '0' : '1'); } }, fg ? '关闭 5G' : '打开 5G'),
						E('span', { style: 'opacity:.75;margin-left:.8em' }, '当前网络:' + ({ '11': '5G SA(NR)', '7': '4G(LTE)', '2': '3G', '0': '2G' }[d.rat] || ('act=' + (d.rat || '?'))))
					);
					return '';
				})(),
				E('div', { class: 'cbi-section' }, [
					E('h4', {}, '网络(APN / 5G)'),
					E('p', { style: 'opacity:.75' }, 'APN 留空表示用运营商默认;改完会自动重新拨号。5G 开关是模组的 AT+SP5GRAN。'),
					E('div', { style: 'display:flex;align-items:center;flex-wrap:wrap;gap:.5em' }, [
						E('span', {}, 'APN:'), apnIn,
						E('button', { class: 'cbi-button cbi-button-apply', click: saveApn }, '保存并重拨'), apnHint
					]),
					E('div', { style: 'display:flex;align-items:center;flex-wrap:wrap;gap:.5em;margin-top:.6em' }, [ fivRow, fivHint ])
				]),
				// 全部热区(对齐 UFI:它显示十几个,我们原来只有 1 个 ✗)
				section('温度(全部热区)', [
					[ '热区数', (d.temps || []).length + ' 个' ],
					[ '各点温度', (d.temps || []).map(function(t) { return t.t.replace('-thmzone', '') + ' ' + t.v + '°'; }).join(' · ') || '-' ]
				]),
				section('存储', (d.storage && d.storage.length) ? d.storage.map(function(s) {
					return [ s.mount, s.size_mb + ' MiB  ·  已用 ' + s.used_mb + ' MiB (' + s.pct + ')' ];
				}) : [ [ '存储', '-' ] ])
			);
		}

		function refresh() {
			fs.read('/tmp/mu300-modes.json').then(function(s) { draw(JSON.parse(s)); }).catch(function() {
				cont.replaceChildren(E('p', {}, '还没采集到(守护 60 秒一轮),稍等…'));
			});
		}
		refresh();
		var rc = mkRefresh('modes', 10, refresh);

		return E([], [
			E('h2', {}, '系统模式'),
			rc,
			cont,
			E('div', { class: 'cbi-section' }, [
				E('h4', {}, 'Ping 工具'),
				E('p', { style: 'opacity:.75' }, '在设备上 ping 一个主机(4 个包)。判断是“设备没网”还是“某个站点不通”。'),
				E('div', { style: 'display:flex;align-items:center;flex-wrap:wrap;gap:.5em' }, [
					pingHost, ' ', E('button', { class: 'cbi-button cbi-button-apply', click: doPing }, 'Ping'), ' ', pingHint
				]),
				pingOut
			]),
			E('div', { class: 'cbi-section' }, E('p', { style: 'opacity:.75' },
				'性能模式由厂商工具 mu300-toolkit 执行(CPU 两个簇 + GPU 一起调)。' +
				'高铁模式是模组的移动性优化开关,模组只开放读取,切换需要厂商接口(安卓侧)。'))
		]);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});