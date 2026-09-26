'use strict';
'require view';
'require fs';
'require poll';

// 已知的 位 -> 5G 频段 映射(从 ZTE 框架的解码日志实测得到)
var KNOWN = [
	{ band: 1,  mask: 0, bit: 0 },
	{ band: 28, mask: 0, bit: 9 },
	{ band: 41, mask: 2, bit: 4 },
	{ band: 78, mask: 2, bit: 8 }
];

function masks(str) {
	return String(str || '').split(',').map(function(x) { return Number(x) || 0; });
}

return view.extend({
	load: function() { return null; },

	render: function() {
		var box = E('div', {}, E('p', {}, '载入中…'));
		var hint = E('span', { style: 'opacity:.7;margin-left:.8em' }, '');
		function say(s) { hint.textContent = s || ''; }

		// 通过 AT 控制台的请求文件执行 AT(复用已有守护,不用新服务)
		function runAT(cmd, cb) {
			fs.write('/tmp/mu300-atweb.req', cmd + '\n').then(function() {
				say('已提交: ' + cmd + ' …');
				setTimeout(function() {
					fs.read('/tmp/mu300-atweb.out').then(function(o) { if (cb) cb(o); say(o.replace(/\n/g, ' ').slice(0, 140)); }).catch(function() { });
				}, 6000);
			}).catch(function(e) { say('写入请求失败: ' + e); });
		}

		function draw(d) {
			var nr = masks(d.nr_band_mask), lte = masks(d.lte_band_mask);
			if (!nr.length || !String(d.nr_band_mask || '').length) {
				box.replaceChildren(E('p', {}, '还没读到频段信息(状态采集每 120 秒跑一次,稍等)。'));
				return;
			}

			var cur = KNOWN.filter(function(k) { return (nr[k.mask] || 0) & (1 << k.bit); })
				.map(function(k) { return 'n' + k.band; }).join(', ') || '(无已知频段)';

			var checks = KNOWN.map(function(k) {
				var on = !!((nr[k.mask] || 0) & (1 << k.bit));
				var cb = E('input', { type: 'checkbox', checked: on, 'data-mask': k.mask, 'data-bit': k.bit });
				return E('label', { style: 'display:inline-block;min-width:6em;margin-right:.8em' }, [ cb, ' n' + k.band ]);
			});

			var rawIn = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:24em;font-family:monospace', value: (d.nr_band_mask || '') });

			function apply() {
				var m = nr.slice();
				while (m.length < 5) m.push(0);
				KNOWN.forEach(function(k, i) {
					var on = checks[i].firstElementChild ? checks[i].firstElementChild.checked : false;
					if (on) m[k.mask] = m[k.mask] | (1 << k.bit);
					else m[k.mask] = m[k.mask] & ~(1 << k.bit);
				});
				runAT('AT+SPLBAND=2,' + m.join(','));
			}

			function writeRaw() {
				var v = (rawIn.value || '').trim();
				if (!/^\d+(,\d+)*$/.test(v)) { say('格式应为: 513,0,272,0,0'); return; }
				var m = masks(v); while (m.length < 5) m.push(0);
				runAT('AT+SPLBAND=2,' + m.join(','));
			}

			box.replaceChildren(
				E('div', { class: 'cbi-section' }, [
					E('h4', {}, '当前 5G 频段锁'),
					E('p', {}, [ '原始掩码: ', E('code', {}, d.nr_band_mask || '-'), '   已知频段: ', E('strong', {}, cur) ].map(function(x) { return x; })),
					E('p', { style: 'opacity:.7' }, '模组支持的全部 5G 频段: n' + String(d.supported_nr || '').split(',').join(', n'))
				]),
				E('div', { class: 'cbi-section' }, [
					E('h4', {}, '选择频段(已知映射的 4 个)'),
					E('div', {}, checks),
					E('p', { style: 'margin-top:.6em' }, [
						E('button', { class: 'cbi-button cbi-button-apply', click: apply }, '应用'), ' ',
						E('button', { class: 'cbi-button', click: function() { runAT('AT+SPLBAND=3'); } }, '读当前值'),
						hint
					]),
					E('p', { style: 'opacity:.7' }, '⚠ 锁定会立即改变搜网范围,可能短暂断网;写错掩码可点下面的“恢复读取到的值”。')
				]),
				E('div', { class: 'cbi-section' }, [
					E('h4', {}, '高级:直接编辑掩码(5 个,逗号分隔)'),
					E('div', {}, [ rawIn, ' ', E('button', { class: 'cbi-button cbi-button-apply', click: writeRaw }, '写入') ]),
					E('p', { style: 'opacity:.7' }, '格式与 AT+SPLBAND=3 的返回一致;已知: 513 = n1+n28、272 = n41+n78、全 1 = 放开全部')
				]),
				E('div', { class: 'cbi-section' }, [
					E('h4', {}, '恢复 / 放开'),
					E('button', { class: 'cbi-button', click: function() { writeRawLater(d.nr_band_mask); } }, '恢复为读取到的值'), ' ',
					E('button', { class: 'cbi-button cbi-button-remove', click: function() {
						if (confirm('放开全部频段(= 取消锁频)?')) runAT('AT+SPLBAND=2,4294967295,4294967295,4294967295,4294967295,4294967295');
					} }, '放开全部频段')
				])
			);

			function writeRawLater(v) {
				var m = masks(v); while (m.length < 5) m.push(0);
				runAT('AT+SPLBAND=2,' + m.join(','));
			}
		}

		function refresh() {
			fs.read('/tmp/mu300-status.json').then(function(s) { draw(JSON.parse(s)); }).catch(function() {
				box.replaceChildren(E('p', {}, '还没有状态数据。'));
			});
		}

		refresh();
		poll.add(refresh, 15);

		return E([], [
			E('h2', {}, '频段锁'),
			E('div', { class: 'cbi-section' }, E('p', {}, '直接对模组发 AT+SPLBAND(Linux 侧原生支持,不依赖安卓)。读用 =3,写用 mode 2 + 5 个掩码。')),
			box
		]);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});