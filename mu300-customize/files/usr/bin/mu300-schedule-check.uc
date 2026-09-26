#!/usr/bin/ucode
// 判断定时任务该不该执行;该执行就打印 <动作>:<时间> 并更新 last
let fs = require('fs');
let DB = '/etc/mu300/schedule.json';
let db = {};
try { db = json(fs.readfile(DB) || '{}') || {}; } catch (e) { print(''); exit(0); }

// ucode 的 localtime() 字段: year/mon(1-12)/mday/hour/min/sec/wday(1=周一..7=周日,与 date +%u 一致)
// ⚠️ 不是 C 的 struct tm(没有 month/day,mon 已经是 1-based)
let now = localtime(time());
let hm = sprintf('%02d:%02d', now.hour, now.min);
let wd = now.wday;
let today = sprintf('%04d-%02d-%02d', now.year, now.mon, now.mday);

function day_match(days) {
	days = trim(days || '*');
	if (days == '' || days == '*') return true;
	let want = split(days, ',');
	for (let i = 0; i < length(want); i++)
		if (+trim(want[i]) == wd) return true;
	return false;
}

let fired = '';
let changed = false;
for (let name in [ 'reboot', 'wifi' ]) {
	let t = db[name];
	if (t == null || !t.enabled) continue;
	if (trim(t.time || '') != hm) continue;
	if (!day_match(t.days)) continue;
	if (t.last == today + ' ' + hm) continue;    // 同一分钟/同一天已执行过
	t.last = today + ' ' + hm;
	changed = true;
	fired = name + ':' + hm;
	break;
}

if (changed) {
	fs.writefile(DB + '.tmp', sprintf('%.J', db));
	fs.rename(DB + '.tmp', DB);
	print(fired);
}