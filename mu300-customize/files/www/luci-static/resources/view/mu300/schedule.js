'use strict';
'require view';
'require fs';
'require ui';
'require rpc';

var DB = '/etc/mu300/schedule.json';
var callReboot = rpc.declare({ object: 'system', method: 'reboot' });
var DAYS = [ [ 1, '周一' ], [ 2, '周二' ], [ 3, '周三' ], [ 4, '周四' ], [ 5, '周五' ], [ 6, '周六' ], [ 7, '周日' ] ];

// 复选框统一用 inline-flex 包住,避免主题(argon)把 input 变块级后跟文字换行 —— 之前的错位就是这个
var ROW = 'display:flex;align-items:center;flex-wrap:wrap;gap:.5em';
var GRID7 = 'display:grid;grid-template-columns:repeat(7,5em);justify-content:start;gap:.35em .6em;margin-top:.5em';
var GRID_DAY = 'display:inline-flex;align-items:center;gap:.4em';
var LBL = 'display:inline-flex;align-items:center;line-height:1.3;gap:.4em;white-space:nowrap';
var CB = 'margin:0;vertical-align:middle;position:static';

return view.extend({
	load: function() {
		return fs.read(DB).then(function(s) { try { return JSON.parse(s); } catch (e) { return {}; } }).catch(function() { return {}; });
	},

	render: function(cfg) {
		cfg = cfg || {};
		var hint = E('span', { style: 'opacity:.75;margin-left:.8em' }, '');
		function say(s) { hint.textContent = s || ''; }

		function timeInput(v) {
			return E('input', { type: 'text', class: 'cbi-input-text', style: 'width:5em;text-align:center', maxlength: 5, value: v || '', placeholder: 'HH:MM' });
		}

		// 复选框对象预先创建好,后面插进 label(同一个实例,保存时能读到) 
		var rbEnable = E('input', { type: 'checkbox', style: CB, checked: !!(cfg.reboot && cfg.reboot.enabled) });
		var wfEnable = E('input', { type: 'checkbox', style: CB, checked: !!(cfg.wifi && cfg.wifi.enabled) });
		var rbTime = timeInput((cfg.reboot && cfg.reboot.time) || '04:00');
		var wfTime = timeInput((cfg.wifi && cfg.wifi.time) || '05:00');

		var daySel = (cfg.reboot && cfg.reboot.days) || '*';
		var dayBoxes = DAYS.map(function(d) {
			var on = (!daySel || daySel == '*' || (',' + daySel + ',').indexOf(',' + d[0] + ',') >= 0);
			var cb = E('input', { type: 'checkbox', style: CB, checked: on });
			return { cb: cb, val: d[0], node: E('label', { style: LBL }, [ cb, E('span', {}, d[1]) ]) };
		});

		function dayStr() {
			var out = [];
			dayBoxes.forEach(function(x) { if (x.cb.checked) out.push(x.val); });
			return out.length ? out.join(',') : '*';
		}

		function save() {
			var rb = rbTime.value.trim(), wf = wfTime.value.trim();
			if (!/^\d{1,2}:\d{2}$/.test(rb) || !/^\d{1,2}:\d{2}$/.test(wf)) { say('时间格式要像 04:00'); return; }
			var o = {
				reboot: { enabled: !!rbEnable.checked, time: rb, days: dayStr(), last: (cfg.reboot && cfg.reboot.last) || '' },
				wifi: { enabled: !!wfEnable.checked, time: wf, days: '*', last: (cfg.wifi && cfg.wifi.last) || '' }
			};
			fs.write(DB, JSON.stringify(o, null, '\t') + '\n').then(function() {
				say('已保存,守护下一次检查(≤25 秒)就会用新配置');
			}).catch(function(e) { say('保存失败: ' + e); });
		}

		return E([], [
			E('h2', {}, '定时任务'),

			E('div', { class: 'cbi-section' }, [
				E('h4', {}, '定时重启'),
				E('div', { style: ROW }, [
					E('label', { style: LBL }, [ rbEnable, E('span', {}, '启用') ]),
					E('span', {}, '每天'), rbTime, E('span', { style: 'opacity:.75' }, '(24 小时制)')
				]),
				E('div', { style: GRID7 }, dayBoxes.map(function(x) { return x.node; })),
				E('p', { style: 'opacity:.75' }, '不勾任何星期 = 每天都执行。到点会先 sync 再重启,避免丢配置。')
			]),

			E('div', { class: 'cbi-section' }, [
				E('h4', {}, '定时重载无线'),
				E('div', { style: ROW }, [
					E('label', { style: LBL }, [ wfEnable, E('span', {}, '启用') ]),
					E('span', {}, '每天'), wfTime, E('span', { style: 'opacity:.75' }, '(24 小时制)')
				]),
				E('p', { style: 'opacity:.75' }, '客户端连不上时,重载一次无线通常能救回来(不影响 5G 数据连接)。')
			]),

			E('div', { class: 'cbi-section' }, [
				E('div', { style: ROW }, [ E('button', { class: 'cbi-button cbi-button-apply', click: save }, '保存'), hint ]),
				E('p', { style: 'opacity:.75' }, '上次执行 —— 重启: ' + ((cfg.reboot && cfg.reboot.last) || '从未')
					+ ';重载无线: ' + ((cfg.wifi && cfg.wifi.last) || '从未'))
			]),

			E('div', { class: 'cbi-section' }, [
				E('h4', {}, '立即重启设备'),
				E('button', { class: 'cbi-button cbi-button-remove', click: function(ev) {
					if (!confirm('确定重启?5G 会断约 1 分钟。')) return;
					ev.target.disabled = true; ev.target.textContent = '重启中…';
					callReboot().catch(function() { });
				} }, '重启')
			])
		]);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});