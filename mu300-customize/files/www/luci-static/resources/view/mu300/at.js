'use strict';
'require view';
'require fs';
'require ui';

return view.extend({
	load: function() { return null; },

	render: function() {
		var out = E('pre', { style: 'white-space:pre-wrap;word-break:break-all;background:#f5f5f5;padding:10px;border:1px solid #ddd;min-height:8em' }, '还没有执行过命令。');

		var input = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:60%;font-family:monospace', placeholder: 'AT+CSQ / AT+COPS? / AT+SP5GCMDS="get nr support_band"' });

		function refresh() {
			fs.read('/tmp/mu300-atweb.out').then(function(s) { out.textContent = s; }).catch(function() { });
		}

		function run() {
			var c = (input.value || '').trim();
			if (!c) return;
			out.textContent = '已提交,执行中…';
			fs.write('/tmp/mu300-atweb.req', c + '\n').then(function() {
				setTimeout(refresh, 2500);
				setTimeout(refresh, 6000);
			}).catch(function(e) { out.textContent = '写入请求失败: ' + e; });
		}

		input.addEventListener('keydown', function(ev) { if (ev.key === 'Enter') run(); });
		refresh();

		return E([], [
			E('h2', {}, 'AT 控制台'),
			E('div', { class: 'cbi-section' }, [
				E('p', {}, '直接向 MU300 模组发 AT 命令。查询类安全;写类(锁频、改 APN、复位)请谨慎。'),
				E('div', {}, [ input, ' ', E('button', { class: 'cbi-button cbi-button-apply', click: run }, '执行'), ' ', E('button', { class: 'cbi-button', click: refresh }, '刷新输出') ])
			]),
			E('div', { class: 'cbi-section' }, [ E('h4', {}, '输出'), out ])
		]);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});