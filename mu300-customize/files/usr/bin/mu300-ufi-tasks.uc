#!/usr/bin/ucode
// mu300-ufi-tasks:执行 UFI 格式的定时任务(/etc/mu300/ufi-tasks.json)
//   由 mu300-statusd 每分钟调用一次;动作直接复用后端的 goform_set_cmd_process ✓
//   用法: mu300-ufi-tasks [HH:MM]
//   ★ 坑:ucode 的 system() 只返回退出码,拿输出必须用 fs.popen ✓
'use strict';
let fs = require('fs');
function cmdout(c) {
  let o = '';
  try { let h = fs.popen(c, 'r'); if (h) { o = h.read('all') || ''; h.close(); } } catch (e) { }
  return trim(o);
}
let now = (ARGV[0] != null) ? ARGV[0] : cmdout('date +%H:%M');
let today = cmdout('date +%F');
let p = '/etc/mu300/ufi-tasks.json';
let ts = {};
try { ts = json(fs.readfile(p) || '{}') || {}; } catch (e) { }
let tasks = ts.tasks || {};
let changed = false;
for (let id in tasks) {
  let v = tasks[id];
  if (v.enabled == false) continue;
  if ('' + v.time != now) continue;
  if (v.last == today && today != '') continue;
  let act = v.action || {};
  let qs = '';
  for (let k in act) {
    if (qs != '') qs += '&';
    let val = '' + act[k];
    qs += k + '=' + replace(replace(val, / /g, '%20'), /[\r\n]/g, '');
  }
  if (qs != '') {
    cmdout(sprintf("curl -s -m 20 -X POST -d '%s' http://127.0.0.1:2333/api/goform/goform_set_cmd_process", replace(qs, /'/g, '')));
  }
  v.last = today;
  changed = true;
  try { fs.writefile('/tmp/ufi-tasks.log', sprintf('%s 执行任务 %s -> %s\n', now, id, qs)); } catch (e) { }
}
if (changed) { try { fs.writefile(p, sprintf('%.J', ts)); } catch (e) { } }