'use strict';
'require view';
'require fs';
'require ui';

return view.extend({
	load: function() { return null; },

	render: function() {
		// ---- 输出区:交给主题的 .cbi-section 上色,行内做 OK/ERROR 染色 ----
		var out = E('pre', { style: 'white-space:pre-wrap;word-break:break-all;background:transparent;color:inherit;font-family:monospace;margin:0;padding:10px;min-height:8em;max-height:26em;overflow:auto' }, '还没有执行过命令。');
		var outBox = E('div', { class: 'cbi-section', style: 'border:1px solid var(--border-color,var(--border-color-low,rgba(127,127,127,.25)));border-radius:4px' }, out);

		var hint = E('span', { style: 'opacity:.7;margin-left:.8em' }, '');
		function say(s) { hint.textContent = s || ''; }

		// ---- 命令历史(上下键,localStorage 持久)----
		var HIST_KEY = 'mu300-at-history';
		var history = [];
		try { history = JSON.parse(localStorage.getItem(HIST_KEY) || '[]') || []; } catch (e) { history = []; }
		var hpos = history.length;
		function remember(cmd) {
			if (history[history.length - 1] !== cmd) history.push(cmd);
			while (history.length > 50) history.shift();
			hpos = history.length;
			try { localStorage.setItem(HIST_KEY, JSON.stringify(history)); } catch (e) { }
		}

		var input = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:60%;font-family:monospace', placeholder: 'AT+CSQ / AT+COPS? / AT+SP5GCMDS="get nr support_band"' });

		function render_out(text) {
			var lines = String(text == null ? '' : text).split('\n');
			out.replaceChildren.apply(out, lines.map(function(line) {
				var style = '';
				if (/^OK\b/.test(line) || /^\+CMGS:/.test(line)) style = 'color:#3f9c46';                       // 成功
				else if (/ERROR/.test(line)) style = 'color:#d9534f';                                              // 失败
				else if (/^(CMD|TIME):/.test(line)) style = 'opacity:.65';                                         // 元信息
				return E('div', { style: style }, line === '' ? ' ' : line);
			}));
		}

		function refresh() {
			fs.read('/tmp/mu300-atweb.out').then(function(s) { render_out(s); }).catch(function() { });
		}

		function run() {
			var c = (input.value || '').trim();
			if (!c) return;
			remember(c);
			out.replaceChildren(E('div', { style: 'opacity:.7' }, '已提交,执行中…(AT 通道要排队,通常 5~20 秒)'));
			say('');
			fs.write('/tmp/mu300-atweb.req', c + '\n').then(function() {
				setTimeout(refresh, 2500);
				setTimeout(refresh, 6000);
				setTimeout(refresh, 12000);
				setTimeout(refresh, 20000);
			}).catch(function(e) { render_out('写入请求失败: ' + e); });
		}

		function copy_out() {
			var t = out.textContent || '';
			function fallback() {
				var r = document.createRange(); r.selectNodeContents(out);
				var sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(r);
				try { document.execCommand('copy'); say('已复制(兼容方式)'); } catch (e) { say('复制失败,请手动选择'); }
			}
			if (navigator.clipboard && navigator.clipboard.writeText)
				navigator.clipboard.writeText(t).then(function() { say('已复制 ' + t.length + ' 字符'); }, fallback);
			else fallback();
		}

		input.addEventListener('keydown', function(ev) {
			if (ev.key === 'ArrowUp') {
				ev.preventDefault();
				if (hpos > 0) { hpos--; input.value = history[hpos]; }
			} else if (ev.key === 'ArrowDown') {
				ev.preventDefault();
				if (hpos < history.length - 1) { hpos++; input.value = history[hpos]; }
				else { hpos = history.length; input.value = ''; }
			} else if (ev.key === 'Enter') {
				run();
			} else if (ev.key === 'Escape') {
				input.value = ''; hpos = history.length;
			}
		});

		refresh();

		return E([], [
			E('h2', {}, 'AT 控制台'),
			E('div', { class: 'cbi-section' }, [
				E('p', {}, '直接向 MU300 模组发 AT 命令。查询类安全;写类(锁频、改 APN、复位)请谨慎。'),
				E('div', {}, [
					input, ' ',
					E('button', { class: 'cbi-button cbi-button-apply', click: run }, '执行'), ' ',
					E('button', { class: 'cbi-button', click: refresh }, '刷新输出'), ' ',
					E('button', { class: 'cbi-button', click: copy_out }, '复制输出'),
					hint
				]),
				E('p', { style: 'opacity:.7;margin-top:.6em' }, '↑ ↓ 翻历史命令(保留最近 50 条),Enter 执行,Esc 清空输入。')
			]),
			E('h4', {}, '输出'),
			outBox
		]);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});