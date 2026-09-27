'use strict';
'require view';
'require fs';
'require ui';
'require poll';

return view.extend({
	load: function() { return null; },

	render: function() {
		var box = E('div', {}, E('p', {}, '载入中…'));
		var status = E('div', { class: 'cbi-section' }, E('p', {}, ''));
		var to = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:14em', placeholder: '手机号,如 10086' });
		var body = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:60%', placeholder: '短信内容(支持 emoji)' });

		
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

function say(s) { status.lastElementChild.textContent = s; }

		function refresh(show_status) {
			fs.read('/tmp/mu300-sms.json').then(function(s) { draw(JSON.parse(s)); }).catch(function() {
				box.replaceChildren(E('p', {}, '还没有短信数据(守护 mu300-smsd 每 20 秒轮询一次)。'));
			}).then(function() {
				if (!show_status) return;
				fs.read('/tmp/mu300-sms.out').then(function(o) { say(o); }).catch(function() { });
			});
		}

		function ask(keys) {
			return fs.write('/tmp/mu300-sms.req', keys + '\n').then(function() {
				say('已提交,执行中…');
				setTimeout(function() { refresh(true); }, 4000);
				setTimeout(function() { refresh(true); }, 9000);
			}).catch(function(e) { say('写入请求失败: ' + e); });
		}

		function draw(d) {
			var msgs = (d && d.messages) || [];
			if (!msgs.length) { box.replaceChildren(E('p', {}, '收件箱是空的。')); return; }
			box.replaceChildren.apply(box, msgs.map(function(m) {
				var out = (m.dir == 'out');
				// 主题无关:用左侧色条区分收发,不用浅底色(深色主题下才不刺眼)
				return E('div', { style: 'border:1px solid var(--border-color,var(--border-color-low,rgba(127,127,127,.30)));border-left:3px solid ' + (out ? 'var(--card-accent,var(--primary,#4a90d9))' : 'var(--border-color,var(--border-color-low,rgba(127,127,127,.30)))') + ';border-radius:4px;padding:8px;margin:8px 0' }, [
					E('div', {}, [
						E('span', { style: out ? 'color:var(--card-accent,var(--primary,#4a90d9));margin-right:.6em' : 'opacity:.8;margin-right:.6em' }, out ? '已发送 →' : '收到'),
						E('strong', {}, (out ? (m.to || m.from) : m.from) || '未知'),
						E('span', { style: 'opacity:.65;margin-left:1em' }, m.date || ''),
						E('span', { style: 'opacity:.5;margin-left:1em' }, out ? '' : ('#' + (m.index || ''))),
						out ? '' : E('button', { class: 'cbi-button cbi-button-remove', style: 'float:right', click: function() {
							if (confirm('删除这条短信?')) ask('action=delete\nindex=' + m.index);
						} }, '删除')
					]),
					E('div', { style: 'white-space:pre-wrap;margin-top:6px' }, m.text || '')
				]);
			}));
		}

		function send() {
			var n = (to.value || '').trim(), t = (body.value || '').trim();
			if (!n || !t) { say('请填手机号和内容'); return; }
			ask('action=send\nnumber=' + n + '\ntext=' + t);
		}

		// ---------------- 短信转发(对齐 UFI 8.2)----------------
		var CONF = '/etc/mu300/sms-forward.json';
		var fwEn = E('input', { type: 'checkbox', style: 'margin:0' });
		var fwMethod = E('select', { class: 'cbi-select', style: 'width:11em' }, [
			E('option', { value: 'dingtalk' }, '钉钉机器人'),
			E('option', { value: 'curl' }, '自定义 URL'),
			E('option', { value: 'smtp' }, '邮件 SMTP')
		]);
		var fwTok = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:24em', placeholder: '钉钉 access_token' });
		var fwUrl = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:24em', placeholder: 'https://…(POST,内容放在 msg 字段)' });
		var fwHdr = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:24em', placeholder: '可选请求头,如 Content-Type: application/json' });
		var fwSrv = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:16em', placeholder: 'smtp.qq.com' });
		var fwPort = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:5em', placeholder: '465' });
		var fwUser = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:18em', placeholder: '发件邮箱' });
		var fwPass = E('input', { type: 'password', class: 'cbi-input-text', style: 'width:18em', placeholder: '授权码' });
		var fwTo = E('input', { type: 'text', class: 'cbi-input-text', style: 'width:18em', placeholder: '收件邮箱' });
		var fwHint = E('span', { style: 'opacity:.75;margin-left:.6em' }, '');

		function fwShow() {
			var m = fwMethod.value;
			fwTok.parentNode.style.display = (m == 'dingtalk') ? '' : 'none';
			fwUrl.parentNode.style.display = (m == 'curl') ? '' : 'none';
			fwHdr.parentNode.style.display = (m == 'curl') ? '' : 'none';
			var sm = (m == 'smtp') ? '' : 'none';
			[ fwSrv, fwPort, fwUser, fwPass, fwTo ].forEach(function(x) { x.parentNode.style.display = sm; });
		}
		fwMethod.addEventListener('change', fwShow);

		function fwLoad() {
			fs.read(CONF).then(function(s) {
				var o = {}; try { o = JSON.parse(s) || {}; } catch (e) { o = {}; }
				fwEn.checked = !!o.enabled;
				if (o.method) fwMethod.value = o.method;
				fwTok.value = o.dingtalk_token || ''; fwUrl.value = o.curl_url || ''; fwHdr.value = o.curl_header || '';
				fwSrv.value = o.smtp_server || ''; fwPort.value = o.smtp_port || ''; fwUser.value = o.smtp_user || '';
				fwPass.value = o.smtp_pass || ''; fwTo.value = o.smtp_to || '';
				fwShow();
			}).catch(function() { fwShow(); });
		}
		function fwSave() {
			var o = {
				enabled: !!fwEn.checked, method: fwMethod.value,
				dingtalk_token: fwTok.value.trim(), curl_url: fwUrl.value.trim(), curl_header: fwHdr.value.trim(),
				smtp_server: fwSrv.value.trim(), smtp_port: fwPort.value.trim(), smtp_user: fwUser.value.trim(),
				smtp_pass: fwPass.value, smtp_to: fwTo.value.trim()
			};
			fs.write(CONF, JSON.stringify(o, null, '\t') + '\n').then(function() { fwHint.textContent = '已保存 ✓'; })
				.catch(function(e) { fwHint.textContent = '保存失败: ' + e; });
		}
		fwLoad();

		refresh(false);
		var rc = mkRefresh('sms', 20, function() { refresh(false); });

		return E([], [
			E('h2', {}, '短信'),
			rc,
			E('div', { class: 'cbi-section' }, [
				E('h4', {}, '发送'),
				E('div', {}, [ to, ' ', body, ' ', E('button', { class: 'cbi-button cbi-button-apply', click: send }, '发送') ])
			]),
			E('div', { class: 'cbi-section' }, [
				E('h4', {}, [ '收件箱 ', E('button', { class: 'cbi-button', click: function() { ask('action=refresh'); } }, '刷新'), ' ', E('button', { class: 'cbi-button cbi-button-remove', click: function() { if (confirm('删除全部短信?')) ask('action=delete\nindex=all'); } }, '清空') ]),
				box
			]),
			E('div', { class: 'cbi-section' }, [
				E('h4', {}, '短信转发'),
				E('p', { style: 'opacity:.75' }, '收到新短信时自动转发出去(守护每 10 秒检查一次)。支持钉钉机器人、自定义 URL、邮件 SMTP。'),
				E('div', { style: 'display:flex;align-items:center;flex-wrap:wrap;gap:.5em' }, [
					E('label', { style: 'display:inline-flex;align-items:center;gap:.35em' }, [ fwEn, E('span', {}, '启用') ]),
					fwMethod,
					fwHint
				]),
				E('div', { style: 'margin:.5em 0' }, fwTok),
				E('div', { style: 'margin:.5em 0' }, [ fwUrl, ' ', fwHdr ]),
				E('div', { style: 'margin:.5em 0' }, [ fwSrv, ':', fwPort, ' ', fwUser, ' ', fwPass, ' ', fwTo ]),
				E('div', { style: 'margin-top:.6em' }, [
					E('button', { class: 'cbi-button cbi-button-apply', click: fwSave }, '保存'),
					' ',
					E('button', { class: 'cbi-button', click: function() { ask('action=forward-test'); } }, '测试转发(发最新一条)')
				])
			]),
			status
		]);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});