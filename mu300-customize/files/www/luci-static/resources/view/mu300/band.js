'use strict';
'require view';
'require fs';
'require poll';
'require rpc';

var CELLDB = '/etc/mu300/celllock.json';
var callReboot = rpc.declare({ object: 'system', method: 'reboot' });

// 5G(NR) 已知映射(来自 ZTE 框架日志实测)
// 5G 频段位映射。已知 4 个点 + 用 AT+SPLBAND=4 返回的 553(bit0/3/5/9)交叉验证:
//   mask0 = 低段,顺序表 [n1, n2, n3, n5, n7, n8, n20, n25, n26, n28, ...]
//     → bit0=n1、bit3=n5、bit5=n8、bit9=n28   (553 = 0b1000101001 = 这四个 ✓)
//   mask2 = 高段 → bit4=n41、bit8=n78
// n6 只出现在 "get nr support_band" 里,掩码中没有对应位(补上行频段,不需要单独锁)
var NR_KNOWN = [
	{ band: 1, mask: 0, bit: 0 }, { band: 5, mask: 0, bit: 3 }, { band: 8, mask: 0, bit: 5 }, { band: 28, mask: 0, bit: 9 },
	{ band: 41, mask: 2, bit: 4 }, { band: 78, mask: 2, bit: 8 }
];
// 4G(LTE) 标准 E-UTRA 位图(已实测:mask3=band1-32,mask1=band33-64)
// 4G:mask3 = band1-32、mask1 = band33-64(已实测),所以 1-64 都能列出来
var LTE_BANDS = [ 1, 2, 3, 4, 5, 7, 8, 12, 13, 17, 18, 19, 20, 25, 26, 28, 30, 34, 38, 39, 40, 41, 42, 43 ];
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
				var cb = E('input', { type: 'checkbox', style: 'margin:0;vertical-align:middle;position:static' });
				cb.addEventListener('change', function() { dirty = true; say('已修改选择(点“应用”生效;先写入配置,重启后才真正生效)'); });
				return { cb: cb, pos: item.pos, node: E('label', { style: 'display:inline-flex;align-items:center;line-height:1.3;gap:.4em;white-space:nowrap' }, [ cb, E('span', { style: 'line-height:1.3' }, prefix + item.band) ]) };
			});
		}
		var nrBoxes = mkBoxes(NR_KNOWN.map(function(k) { return { band: k.band, pos: { mask: k.mask, bit: k.bit } }; }), 'n');
		var lteBoxes = mkBoxes(LTE_BANDS.map(function(b) { return { band: b, pos: ltePos(b) }; }), 'B');
		// grid 排列:每个频段占等宽一列,视觉上整齐对齐(主题/字体差异也不会参差)
		var GRID = 'display:grid;grid-template-columns:repeat(auto-fill,6em);justify-content:start;gap:.35em .6em';
		var nrBoxNode = E('div', { style: GRID }, nrBoxes.map(function(x) { return x.node; }));
		var lteBoxNode = E('div', { style: GRID }, lteBoxes.map(function(x) { return x.node; }));

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

		// ---------- 小区锁(AT+SPFORCEFRQ)----------
		// 命令已实测:锁 = <rat>,1,<earfcn>,<pci>;解锁 = <rat>,0(rat: 16=NR / 12=LTE)
		// 模组没有可用的"读已锁小区"命令(16,3 只回显),所以本页自己记一份到 /etc/mu300/celllock.json
		var cellRat = E('select', { class: 'cbi-select', style: 'width:7em;margin:0' }, [
			E('option', { value: '16' }, 'NR (5G)'), E('option', { value: '12' }, 'LTE (4G)')
		]);
		var cellEarfcn = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:9em;margin:0', placeholder: '如 422910' });
		var cellPci = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:6em;margin:0', placeholder: '如 111' });
		var cellNow = E('div', { style: 'margin:.4em 0 .6em' }, '(读取中…)');
		var cellHint = E('span', { style: 'opacity:.75;margin-left:.8em' }, '');
		function sayCell(s) { cellHint.textContent = s || ''; }

		function loadCell() {
			fs.read(CELLDB).then(function(s) {
				var o = {};
				try { o = JSON.parse(s) || {}; } catch (e) { o = {}; }
				if (o && o.rat && o.earfcn && o.pci) {
					cellNow.replaceChildren(E('span', {}, '已锁定 ' + (o.rat == '16' ? 'NR' : 'LTE') + ':earfcn ' + o.earfcn + ',pci ' + o.pci));
					cellRat.value = o.rat; cellEarfcn.value = o.earfcn; cellPci.value = o.pci;
				} else {
					cellNow.replaceChildren(E('span', { style: 'opacity:.75' }, '未锁定(或不是通过本页锁的)'));
				}
			}).catch(function() {
				cellNow.replaceChildren(E('span', { style: 'opacity:.75' }, '未锁定(或不是通过本页锁的)'));
			});
		}

		function lockCell() {
			var rat = cellRat.value, ea = (cellEarfcn.value || '').trim(), pc = (cellPci.value || '').trim();
			if (!/^\d+$/.test(ea) || !/^\d+$/.test(pc)) { sayCell('earfcn 和 pci 都要填数字'); return; }
			var name = (rat == '16' ? 'NR' : 'LTE');
			if (!confirm('锁定到 ' + name + ' earfcn=' + ea + ' pci=' + pc + '?\n\n注意:锁死一个小区会失去移动性(信号变差也不会自动切换);写入后需要重启设备才生效。')) return;
			var cmd = 'AT+SPFORCEFRQ=' + rat + ',1,' + ea + ',' + pc;
			runAT(cmd);
			fs.write(CELLDB, JSON.stringify({ rat: rat, earfcn: ea, pci: pc, at: cmd, ts: Math.floor(Date.now() / 1000) }, null, '\t') + '\n')
				.then(function() { loadCell(); sayCell('已提交 ' + cmd + ';重启设备后生效'); })
				.catch(function(e) { sayCell('记录失败: ' + e); });
		}

		function unlockCell() {
			if (!confirm('解除小区锁?')) return;
			var rat = cellRat.value;
			runAT('AT+SPFORCEFRQ=' + rat + ',0');
			fs.write(CELLDB, '{}\n').then(function() { loadCell(); sayCell('已提交解锁;重启设备后生效'); });
		}

		loadCell();
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
				E('p', { style: 'opacity:.75' }, '已知映射:n1 / n5 / n8 / n28(低段)与 n41 / n78(高段);n6 是补上行频段,掩码里没有独立位')
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
				E('h4', {}, '小区锁(锁基站)'),
				cellNow,
				E('div', { style: 'display:flex;align-items:center;flex-wrap:wrap;gap:.5em' }, [
					cellRat, cellEarfcn, cellPci,
					E('button', { class: 'cbi-button cbi-button-apply', click: lockCell }, '锁定'),
					E('button', { class: 'cbi-button cbi-button-remove', click: unlockCell }, '解锁'),
					cellHint
				]),
				E('p', { style: 'opacity:.75' }, '直接对模组发 AT+SPFORCEFRQ(rat: 16=NR、12=LTE)。earfcn/pci 可以在安卓侧的 UFI-TOOLS 或工程模式里查到。'),
				E('p', { style: 'opacity:.75' }, '⚠ 锁死一个小区就没有移动性了(信号变差也不会自动切换),一般只在"附近有更强/更稳的指定基站"时用;写入后需要重启设备才生效。'),
				E('div', { style: 'margin-top:.6em' }, [
					E('button', { class: 'cbi-button cbi-button-remove', click: function(ev) {
						if (!confirm('现在重启设备?5G 会断约 1 分钟,重启后新配置生效。')) return;
						ev.target.disabled = true; ev.target.textContent = '重启中…';
						callReboot().catch(function() { });
					} }, '重启设备生效')
				])
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