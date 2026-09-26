'use strict';
'require view';
'require fs';
'require poll';

// ── 掩码 ↔ 频段 映射 ───────────────────────────────────────────
// 5G(NR):实测 4 个点(来自 ZTE 框架日志)
var NR_KNOWN = [
	{ band: 1,  mask: 0, bit: 0 },
	{ band: 28, mask: 0, bit: 9 },
	{ band: 41, mask: 2, bit: 4 },
	{ band: 78, mask: 2, bit: 8 }
];
// 4G(LTE):标准 E-UTRA 位图 —— 已实测确认(加/删 band8 生效)
//   mask3 = band 1..32 (bit = band-1)、mask1 = band 33..64 (bit = band-33)
var LTE_BANDS = [ 1, 3, 5, 8, 34, 38, 39, 40, 41 ];
function ltePos(b) {
	if (b >= 1 && b <= 32) return { mask: 3, bit: b - 1 };
	if (b >= 33 && b <= 64) return { mask: 1, bit: b - 33 };
	return null;
}

function toMasks(s) { return String(s || '').split(',').map(function(x) { return Number(x) || 0; }); }
function fromMasks(m) { while (m.length < 5) m.push(0); return m.join(','); }
function has(m, k) { return !!((m[k.mask] || 0) & (1 << k.bit)); }

return view.extend({
	load: function() { return null; },

	render: function() {
		var hint = E('span', { style: 'opacity:.75;margin-left:.8em' }, '');
		function say(s) { hint.textContent = s || ''; }

		function runAT(cmd) {
			fs.write('/tmp/mu300-atweb.req', cmd + '\n').then(function() {
				say('已提交: ' + cmd);
				setTimeout(function() {
					fs.read('/tmp/mu300-atweb.out').then(function(o) { say(o.replace(/\n/g, ' ').slice(0, 150)); }).catch(function() { });
				}, 7000);
			}).catch(function(e) { say('写请求失败: ' + e); });
		}

		var nrBox = E('div'), lteBox = E('div'), info = E('div');
		var nrRaw = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:100%;max-width:22em;font-family:monospace' });
		var lteRaw = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:100%;max-width:22em;font-family:monospace' });

		function bandChecks(list, cur, container, onApply) {
			var boxes = list.map(function(item) {
				var b = item.band, pos = item.pos;
				var on = !!((cur[pos.mask] || 0) & (1 << pos.bit));
				var cb = E('input', { type: 'checkbox', checked: on });
				return { cb: cb, pos: pos, node: E('label', { style: 'display:inline-block;min-width:5.5em;margin:.15em .8em .15em 0;white-space:nowrap' }, [ cb, ' ' + (item.prefix || '') + b ]) };
			});
			container.replaceChildren.apply(container, boxes.map(function(x) { return x.node; }));
			return { boxes: boxes, onApply: onApply };
		}

		var nrState = null, lteState = null;

		function draw(d) {
			var nr = toMasks(d.nr_band_mask), lte = toMasks(d.lte_band_mask);
			if (!String(d.nr_band_mask || '').length) {
				info.replaceChildren(E('p', {}, '还没读到频段信息(状态采集每 120 秒一次,稍等或点“读当前值”)。'));
				return;
			}
			nrRaw.value = d.nr_band_mask;
			lteRaw.value = d.lte_band_mask;

			var nrNow = NR_KNOWN.filter(function(k) { return has(nr, k); }).map(function(k) { return 'n' + k.band; }).join(', ') || '(无)';
			var lteNow = LTE_BANDS.filter(function(b) { return has(lte, ltePos(b)); }).map(function(b) { return 'B' + b; }).join(', ') || '(无)';

			info.replaceChildren(
				E('table', { class: 'table' }, E('tbody', {}, [
					[ '5G 锁定频段', (nrNow + '   掩码: ' + d.nr_band_mask) ],
					[ '4G 锁定频段', (lteNow + '   掩码: ' + d.lte_band_mask) ],
					[ '模组支持', '5G: n' + String(d.supported_nr || '').split(',').join(', n') ]
				].map(function(r) {
					return E('tr', { class: 'tr' }, [
						E('td', { class: 'td left', width: '22%' }, E('strong', {}, r[0])),
						E('td', { class: 'td left', style: 'word-break:break-all' }, r[1])
					]);
				})))
			);

			nrState = bandChecks(NR_KNOWN.map(function(k) { return { band: k.band, pos: k, prefix: 'n' }; }), nr, nrBox, function() {
				var m = nr.slice();
				nrState.boxes.forEach(function(x) {
					if (x.cb.checked) m[x.pos.mask] |= (1 << x.pos.bit);
					else m[x.pos.mask] &= ~(1 << x.pos.bit);
				});
				runAT('AT+SPLBAND=2,' + fromMasks(m));
			});

			lteState = bandChecks(LTE_BANDS.map(function(b) { return { band: b, pos: ltePos(b), prefix: 'B' }; }), lte, lteBox, function() {
				var m = lte.slice();
				lteState.boxes.forEach(function(x) {
					if (x.cb.checked) m[x.pos.mask] |= (1 << x.pos.bit);
					else m[x.pos.mask] &= ~(1 << x.pos.bit);
				});
				runAT('AT+SPLBAND=1,' + fromMasks(m));
			});
		}

		function refresh() {
			fs.read('/tmp/mu300-status.json').then(function(s) { draw(JSON.parse(s)); }).catch(function() {
				info.replaceChildren(E('p', {}, '还没有状态数据。'));
			});
		}

		function writeRaw(cmd, input) {
			var v = (input.value || '').trim();
			if (!/^\d+(,\d+)*$/.test(v)) { say('格式应为: 513,0,272,0,0'); return; }
			runAT('AT+SPLBAND=' + cmd + ',' + fromMasks(toMasks(v)));
		}

		refresh();
		poll.add(refresh, 20);

		return E([], [
			E('h2', {}, '频段锁'),
			E('div', { class: 'cbi-section' }, [
				E('p', {}, '直接对模组发 AT+SPLBAND(Linux 原生支持)。读:5G 用 =3、4G 用 =0;写:5G 用 mode 2、4G 用 mode 1。'),
				info
			]),
			E('div', { class: 'cbi-section' }, [
				E('h4', {}, '5G (NR) 频段'),
				nrBox,
				E('div', { style: 'margin-top:.6em' }, [
					E('button', { class: 'cbi-button cbi-button-apply', click: function() { nrState && nrState.onApply(); } }, '应用 5G 选择'), ' ',
					E('button', { class: 'cbi-button', click: function() { runAT('AT+SPLBAND=3'); } }, '读当前值'), ' ',
					E('button', { class: 'cbi-button cbi-button-remove', click: function() {
						if (confirm('放开全部 5G 频段(取消 5G 锁频)?')) runAT('AT+SPLBAND=2,4294967295,4294967295,4294967295,4294967295,4294967295');
					} }, '放开全部 5G')
				]),
				E('p', { style: 'opacity:.75' }, '已知映射:n1 / n28 / n41 / n78(其余频段的位未知,可用下面的掩码直接写)')
			]),
			E('div', { class: 'cbi-section' }, [
				E('h4', {}, '4G (LTE) 频段'),
				lteBox,
				E('div', { style: 'margin-top:.6em' }, [
					E('button', { class: 'cbi-button cbi-button-apply', click: function() { lteState && lteState.onApply(); } }, '应用 4G 选择'), ' ',
					E('button', { class: 'cbi-button', click: function() { runAT('AT+SPLBAND=0'); } }, '读当前值'), ' ',
					E('button', { class: 'cbi-button cbi-button-remove', click: function() {
						if (confirm('放开全部 4G 频段(取消 4G 锁频)?')) runAT('AT+SPLBAND=1,4294967295,4294967295,4294967295,4294967295,4294967295');
					} }, '放开全部 4G')
				]),
				E('p', { style: 'opacity:.75' }, '已实测:mask3 = band1-32(bit=band-1)、mask1 = band33-64(bit=band-33),即标准 E-UTRA 位图')
			]),
			E('div', { class: 'cbi-section' }, [
				E('h4', {}, '高级:直接编辑掩码(5 个,逗号分隔)'),
				E('table', { class: 'table' }, E('tbody', {}, [
					E('tr', { class: 'tr' }, [ E('td', { class: 'td left', width: '22%' }, '5G'), E('td', { class: 'td left' }, [ nrRaw, ' ', E('button', { class: 'cbi-button', click: function() { writeRaw(2, nrRaw); } }, '写入') ]) ]),
					E('tr', { class: 'tr' }, [ E('td', { class: 'td left' }, '4G'), E('td', { class: 'td left' }, [ lteRaw, ' ', E('button', { class: 'cbi-button', click: function() { writeRaw(1, lteRaw); } }, '写入') ]) ])
				])),
				hint
			]),
			E('div', { class: 'cbi-section' }, E('p', { style: 'opacity:.75' }, '⚠ 改频段会立即影响搜网,可能短暂断网;写错可用“读当前值”看回来,或“放开全部”。'))
		]);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});