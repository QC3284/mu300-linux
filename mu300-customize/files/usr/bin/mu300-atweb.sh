#!/bin/sh
# Web AT 控制台的执行端(轮询请求文件 → 执行 → 写结果文件)
# 注意:名字用 mu300-atweb,不要用 mu300-atd —— 后者是上游的 AT 通道守护(/etc/init.d/mu300-atd)
export PATH="$PATH:/opt/mu300/busybox-bin"
REQ=/tmp/mu300-atweb.req
OUT=/tmp/mu300-atweb.out
while :; do
  if [ -s $REQ ]; then
    cmd=$(cat $REQ 2>/dev/null | head -1)
    rm -f $REQ
    if [ -n "$cmd" ]; then
      res=$(/opt/mu300/busybox-bin/timeout 25 /usr/bin/mu300-at-cmd "$cmd" 2>&1 || echo '(执行失败或超时)')
      { echo "CMD: $cmd"; echo "TIME: $(date '+%Y-%m-%d %H:%M:%S')"; echo '---'; echo "$res"; } > $OUT
    fi
  fi
  sleep 1
done