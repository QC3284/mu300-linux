'use strict';
'require view';
'require fs';
'require ui';
'require rpc';

var DB = '/etc/mu300/schedule.json';
var callReboot = rpc.declare({ object: 'system', method: 'reboot' });

var DAYS = [ [ 1, '周一' ], [ 2, '周二' ], [ 3, '周三' ], [ 4, '周四' ], [ 5, '周五' ], [ 6, '周六' ], [ 7, '周日' ] ];

return view.extend({
	load: function() {
		return fs.read(DB).then(function(s) { try { return JSON.parse(s); } catch (e) { return {}; } }).catch(function() { return {}; });
	},

	render: function(cfg) {
		cfg = cfg || {};
		var hint = E('span', { style: 'opacity:.7;margin-left:.8em' }, '');
		function say(s) { hint.textContent = s || ''; }

		function timeInput(v) {
			return E('input', { type: 'text', class: 'cbi-input-text', style: 'width:5em;text-align:center', maxlength: 5, value: v || '', placeholder: 'HH:MM' });
		}

		function daysRow(sel) {
			var boxes = DAYS.map(function(d) {
				var on = (!sel || sel == '*' || (',' + sel + ',').indexOf(',' + d[0] + ',') >= 0);
				return E('label', { style: 'margin-right:.6em;white-space:nowrap' }, [ E('input', { type: 'checkbox', checked: on }), ' ' + d[1] ]);
			});
			return { boxes: boxes, node: E('div', { style: 'margin-top:.4em' }, boxes) };
		}

		function dayStr(boxes) {
			var out = [];
			DAYS.forEach(function(d, i) { if (boxes[i].checked) out.push(d[0]); });
			return out.length ? out.join(',') : '*';
		}

		var rbEnable = E('input', { type: 'checkbox', checked: !!(cfg.reboot && cfg.reboot.enabled) });
		var rbTime = timeInput((cfg.reboot && cfg.reboot.time) || '04:00');
		var rbD = daysRow(cfg.reboot && cfg.reboot.days);
		var wfEnable = E('input', { type: 'checkbox', checked: !!(cfg.wifi && cfg.wifi.enabled) });
		var wfTime = timeInput((cfg.wifi && cfg.wifi.time) || '05:00');

		function save() {
			var rb = rbTime.value.trim(), wf = wfTime.value.trim();
			if (!/^\d{1,2}:\d{2}$/.test(rb) || !/^\d{1,2}:\d{2}$/.test(wf)) { say('时间格式要像 04:00'); return; }
			var o = {
				reboot: { enabled: !!rbEnable.checked, time: rb, days: dayStr(rbD.boxes), last: (cfg.reboot && cfg.reboot.last) || '' },
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
				E('div', {}, [ E('label', {}, [ rbEnable, ' 启用' ]), ' 每天 ', rbTime, ' (24 小时制)' ]),
				rbD.node,
				E('p', { style: 'opacity:.7' }, '不勾任何星期 = 每天都执行。到点会先 sync 再重启,避免丢配置。')
			]),

			E('div', { class: 'cbi-section' }, [
				E('h4', {}, '定时重载无线'),
				E('div', {}, [ E('label', {}, [ wfEnable, ' 启用' ]), ' 每天 ', wfTime ]),
				E('p', { style: 'opacity:.7' }, '客户端连不上时,重载一次无线通常能救回来(不影响 5G 数据连接)。')
			]),

			E('div', { class: 'cbi-section' }, [
				E('button', { class: 'cbi-button cbi-button-apply', click: save }, '保存'),
				hint,
				E('p', { style: 'opacity:.7' }, '上次执行 —— 重启: ' + ((cfg.reboot && cfg.reboot.last) || '从未')
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