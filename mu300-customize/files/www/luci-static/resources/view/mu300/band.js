'use strict';
'require view';
'require fs';
'require poll';

// 5G(NR) 已知映射(来自 ZTE 框架日志实测)
var NR_KNOWN = [ { band: 1, mask: 0, bit: 0 }, { band: 28, mask: 0, bit: 9 }, { band: 41, mask: 2, bit: 4 }, { band: 78, mask: 2, bit: 8 } ];
// 4G(LTE) 标准 E-UTRA 位图(已实测:mask3=band1-32,mask1=band33-64)
var LTE_BANDS = [ 1, 3, 5, 8, 34, 38, 39, 40, 41 ];
function ltePos(b) {
	if (b >= 1 && b <= 32) return { mask: 3, bit: b - 1 };
	if (b >= 33 && b <= 64) return { mask: 1, bit: b - 33 };
	return null;
}
function toMasks(s) { return String(s || '').split(',').map(function(x) { return Number(x) || 0; }); }
function fromMasks(m) { while (m.length < 5) m.push(0); return m.join(','); }

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

		var info = E('div');
		var nrRaw = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:100%;max-width:22em;font-family:monospace' });
		var lteRaw = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:100%;max-width:22em;font-family:monospace' });

		// 复选框只建一次,不再每次刷新重建 —— 否则:(1) 用户刚勾的被 5 秒轮询冲掉 (2) 重建过程出错会留下旧状态(现场出现过)
		var dirty = false;
		function mkBoxes(list, prefix) {
			return list.map(function(item) {
				var cb = E('input', { type: 'checkbox' });
				cb.addEventListener('change', function() { dirty = true; say('已修改选择(点“应用”生效;先写入配置,重启后才真正生效)'); });
				return { cb: cb, pos: item.pos, node: E('label', { style: 'display:inline-block;min-width:5.5em;margin:.15em .8em .15em 0;white-space:nowrap' }, [ cb, ' ' + prefix + item.band ]) };
			});
		}
		var nrBoxes = mkBoxes(NR_KNOWN.map(function(k) { return { band: k.band, pos: { mask: k.mask, bit: k.bit } }; }), 'n');
		var lteBoxes = mkBoxes(LTE_BANDS.map(function(b) { return { band: b, pos: ltePos(b) }; }), 'B');
		var nrBoxNode = E('div', {}, nrBoxes.map(function(x) { return x.node; }));
		var lteBoxNode = E('div', {}, lteBoxes.map(function(x) { return x.node; }));

		var lastNr = '', lastLte = '';
		function setChecked(boxes, masks) {
			boxes.forEach(function(x) { x.cb.checked = !!((masks[x.pos.mask] || 0) & (1 << x.pos.bit)); });
		}

		function collect(boxes, base) {
			var m = base.slice();
			boxes.forEach(function(x) {
				if (x.cb.checked) m[x.pos.mask] |= (1 << x.pos.bit);
				else m[x.pos.mask] &= ~(1 << x.pos.bit);
			});
			return m;
		}

		function draw(d) {
			var nrStr = String(d.nr_band_mask || ''), lteStr = String(d.lte_band_mask || '');
			if (!nrStr.length && !lteStr.length) {
				info.replaceChildren(E('p', {}, '还没读到频段信息(AT 采集约 90 秒一次,稍等)。'));
				return;
			}
			var nr = toMasks(nrStr), lte = toMasks(lteStr);

			// 只有"数据变了 + 用户没在编辑"时才同步复选框,避免把手动勾选冲掉
			if ((nrStr != lastNr || lteStr != lastLte) && !dirty) {
				setChecked(nrBoxes, nr);
				setChecked(lteBoxes, lte);
				lastNr = nrStr; lastLte = lteStr;
			}
			nrRaw.value = nrStr; lteRaw.value = lteStr;

			var nrNow = NR_KNOWN.filter(function(k) { return (nr[k.mask] || 0) & (1 << k.bit); }).map(function(k) { return 'n' + k.band; }).join(', ') || '(无)';
			var lteNow = LTE_BANDS.filter(function(b) { var p = ltePos(b); return p && ((lte[p.mask] || 0) & (1 << p.bit)); }).map(function(b) { return 'B' + b; }).join(', ') || '(无)';

			info.replaceChildren(E('div', { style: 'overflow-x:auto' }, E('table', { class: 'table' }, E('tbody', {}, [
				[ '5G 锁定频段', (nrNow + '   掩码: ' + (nrStr || '-')) ],
				[ '4G 锁定频段', (lteNow + '   掩码: ' + (lteStr || '-')) ],
				[ '模组支持 5G', d.supported_nr ? ('n' + String(d.supported_nr).split(',').join(', n')) : '-' ]
			].map(function(r) {
				return E('tr', { class: 'tr' }, [
					E('td', { class: 'td left', width: '20%' }, E('strong', {}, r[0])),
					E('td', { class: 'td left', style: 'word-break:break-all' }, r[1])
				]);
			})))));
		}

		function refresh() {
			fs.read('/tmp/mu300-status.json').then(function(s) { draw(JSON.parse(s)); }).catch(function() { });
		}

		function writeRaw(mode, input) {
			var v = (input.value || '').trim();
			if (!/^\d+(,\d+)*$/.test(v)) { say('格式应为: 513,0,272,0,0'); return; }
			runAT('AT+SPLBAND=' + mode + ',' + fromMasks(toMasks(v)));
		}

		function apply(boxes, mode, curStr) {
			var m = collect(boxes, toMasks(curStr));
			if (confirm('写入配置: ' + fromMasks(m) + '\n\n注意:只写配置,不断网;要真正生效需要重启设备(或重启网络栈)。继续?'))
				runAT('AT+SPLBAND=' + mode + ',' + fromMasks(m));
		}

		refresh();
		poll.add(refresh, 10);

		return E([], [
			E('h2', {}, '频段锁'),
			E('div', { class: 'cbi-section' }, [
				E('p', {}, '直接对模组发 AT+SPLBAND(Linux 原生支持)。读:5G 用 =3、4G 用 =0;写:5G 用 mode 2、4G 用 mode 1。'),
				E('p', { style: 'opacity:.75' }, '⚠ 写入只改配置、不会立刻断网;要真正生效需要重启设备(最稳)或重启网络栈。'),
				info
			]),
			E('div', { class: 'cbi-section' }, [
				E('h4', {}, '5G (NR) 频段'),
				nrBoxNode,
				E('div', { style: 'margin-top:.6em' }, [
					E('button', { class: 'cbi-button cbi-button-apply', click: function() { apply(nrBoxes, 2, nrRaw.value); } }, '应用 5G 选择'), ' ',
					E('button', { class: 'cbi-button', click: function() { dirty = false; runAT('AT+SPLBAND=3'); } }, '读当前值'), ' ',
					E('button', { class: 'cbi-button cbi-button-remove', click: function() {
						if (confirm('放开全部 5G 频段(取消 5G 锁频)?')) runAT('AT+SPLBAND=2,4294967295,4294967295,4294967295,4294967295,4294967295');
					} }, '放开全部 5G')
				]),
				E('p', { style: 'opacity:.75' }, '已知映射:n1 / n28 / n41 / n78(其余频段位未知,可用下面的掩码直接写)')
			]),
			E('div', { class: 'cbi-section' }, [
				E('h4', {}, '4G (LTE) 频段'),
				lteBoxNode,
				E('div', { style: 'margin-top:.6em' }, [
					E('button', { class: 'cbi-button cbi-button-apply', click: function() { apply(lteBoxes, 1, lteRaw.value); } }, '应用 4G 选择'), ' ',
					E('button', { class: 'cbi-button', click: function() { dirty = false; runAT('AT+SPLBAND=0'); } }, '读当前值'), ' ',
					E('button', { class: 'cbi-button cbi-button-remove', click: function() {
						if (confirm('放开全部 4G 频段(取消 4G 锁频)?')) runAT('AT+SPLBAND=1,4294967295,4294967295,4294967295,4294967295,4294967295');
					} }, '放开全部 4G')
				]),
				E('p', { style: 'opacity:.75' }, '已实测:mask3 = band1-32(bit=band-1)、mask1 = band33-64(bit=band-33)')
			]),
			E('div', { class: 'cbi-section' }, [
				E('h4', {}, '高级:直接编辑掩码(5 个,逗号分隔)'),
				E('div', { style: 'overflow-x:auto' }, E('table', { class: 'table' }, E('tbody', {}, [
					E('tr', { class: 'tr' }, [ E('td', { class: 'td left', width: '20%' }, '5G'), E('td', { class: 'td left' }, [ nrRaw, ' ', E('button', { class: 'cbi-button', click: function() { writeRaw(2, nrRaw); } }, '写入') ]) ]),
					E('tr', { class: 'tr' }, [ E('td', { class: 'td left' }, '4G'), E('td', { class: 'td left' }, [ lteRaw, ' ', E('button', { class: 'cbi-button', click: function() { writeRaw(1, lteRaw); } }, '写入') ]) ])
				]))),
				hint
			])
		]);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});