// 把 `sms list` 的着色输出解析成 JSON(收件箱快照)
let fs = require('fs');
let RAW = '/tmp/mu300-sms-list.raw';
let DB = '/etc/mu300/sms-messages.json';
let LIVE = '/tmp/mu300-sms.json';

let raw = '';
try { raw = fs.readfile(RAW) || ''; } catch (e) { raw = ''; }

let lines = split(raw, '\n');
let msgs = [], cur = null, part = 0;
for (let i = 0; i < length(lines); i++) {
	let l = lines[i];
	let m = match(l, /^#([0-9,]+)[ \t]+from[ \t]+([^ \t]+)[ \t]+(.*)$/);
	if (m) {
		cur = { index: m[1], from: m[2], date: trim(m[3]), text: '' };
		push(msgs, cur);
	} else if (cur != null) {
		// 正文行以 4 空格缩进;空行结束当前消息
		if (substr(l, 0, 4) == '    ')
			cur.text += (length(cur.text) ? '\n' : '') + substr(l, 4);
	}
}

let o = { updated: time(), messages: msgs };
let s = sprintf('%.J', o);
fs.writefile(DB + '.tmp', s);
fs.rename(DB + '.tmp', DB);
fs.writefile(LIVE, s);
print(sprintf('parsed %d messages\n', length(msgs)));