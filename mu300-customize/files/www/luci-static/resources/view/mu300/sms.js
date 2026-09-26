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
				return E('div', { style: 'border:1px solid ' + (out ? '#b9d3ee' : '#ddd') + ';background:' + (out ? '#f4f8fd' : 'transparent') + ';border-radius:4px;padding:8px;margin:8px 0' }, [
					E('div', {}, [
						E('span', { style: 'color:' + (out ? '#33689e' : '#333') + ';margin-right:.6em' }, out ? '已发送 →' : '收到'),
						E('strong', {}, (out ? (m.to || m.from) : m.from) || '未知'),
						E('span', { style: 'color:#888;margin-left:1em' }, m.date || ''),
						E('span', { style: 'color:#aaa;margin-left:1em' }, out ? '' : ('#' + (m.index || ''))),
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

		refresh(false);
		poll.add(function() { refresh(false); }, 20);

		return E([], [
			E('h2', {}, '短信'),
			E('div', { class: 'cbi-section' }, [
				E('h4', {}, '发送'),
				E('div', {}, [ to, ' ', body, ' ', E('button', { class: 'cbi-button cbi-button-apply', click: send }, '发送') ])
			]),
			E('div', { class: 'cbi-section' }, [
				E('h4', {}, [ '收件箱 ', E('button', { class: 'cbi-button', click: function() { ask('action=refresh'); } }, '刷新'), ' ', E('button', { class: 'cbi-button cbi-button-remove', click: function() { if (confirm('删除全部短信?')) ask('action=delete\nindex=all'); } }, '清空') ]),
				box
			]),
			status
		]);
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});