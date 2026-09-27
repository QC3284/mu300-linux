#!/bin/sh
# MU300 短信守护
#  ① sms watch:每 20 秒轮询一次收件箱,有新消息就调 mu300-sms-hook 落库(JSON)
#  ② 同时轮询 /tmp/mu300-sms.req 处理页面请求(send / delete / refresh)
# 注意:`sms` 是厂商脚本,内部走 mu300-atd 排队,不会自己抢 AT 通道(那条通道抢了会卡死)
export PATH="$PATH:/opt/mu300/bin:/opt/mu300/busybox-bin"
# ---- 单实例锁(避免 restart 没杀干净导致重复采集/重复转发)----
LOCK=/var/run/mu300-smsd.lock
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null)
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    echo "mu300-smsd 已在运行 (pid $old),退出" >&2
    exit 0
  fi
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"; exit 0' TERM INT EXIT

REQ=/tmp/mu300-sms.req
OUT=/tmp/mu300-sms.out
HOOK=/usr/bin/mu300-sms-hook
mkdir -p /etc/mu300

# ---- ① 收件:厂商脚本负责 PDU 解码/多段拼接,我们只负责把结果落成 JSON ----
# 重启后 /tmp 是空的,先主动刷一次,否则页面在收到新短信之前一直显示"没有数据"
/usr/bin/mu300-sms-refresh >/dev/null 2>&1
( sms watch "$HOOK" >/dev/null 2>&1 ) &
WATCH=$!

# ---- ③ 短信转发(对齐 UFI 8.2):发现新消息就调转发脚本 ----
# 用 /tmp/mu300-sms.json 里最新一条的 index 做"新消息"判定;启动时先记住当前值,不转发历史短信
(
  LAST=$(jsonfilter -i /tmp/mu300-sms.json -e '@.messages[0].index' 2>/dev/null)
  while :; do
    sleep 10
    cur=$(jsonfilter -i /tmp/mu300-sms.json -e '@.messages[0].index' 2>/dev/null)
    if [ -n "$cur" ] && [ "$cur" != "$LAST" ]; then
      LAST="$cur"
      /usr/bin/mu300-sms-forward >/dev/null 2>&1
    fi
  done
) &

reply() { { echo "TIME: $(date '+%Y-%m-%d %H:%M:%S')"; echo "ACTION: $1"; echo '---'; echo "$2"; } > $OUT; }

while :; do
  if [ -s $REQ ]; then
    action=''; number=''; text=''; index=''
    while IFS='=' read -r k v; do
      case $k in
        action) action=$v ;;
        number) number=$v ;;
        text)   text=$v ;;
        index)  index=$v ;;
      esac
    done < $REQ
    rm -f $REQ
    case $action in
      send)
        if [ -n "$number" ] && [ -n "$text" ]; then
          res=$(sms send "$number" "$text" 2>&1)
          reply send "$res"
          # 厂商 sms list 只读收件箱,发件箱模组不一定存 -> 自己记一条(成功才记)
          case $res in
            sent*) /usr/bin/mu300-sms-out "$number" "$text" >/dev/null 2>&1 ;;
          esac
          # 发完立刻刷新一次收件箱(把已发消息也带进来)
          /usr/bin/mu300-sms-refresh >/dev/null 2>&1
        else
          reply send '参数不完整(需要 number 和 text)'
        fi ;;
      delete)
        if [ -n "$index" ]; then
          case $index in
            all|read) res=$(sms delete $index 2>&1) ;;
            *)        res=$(sms delete $index 2>&1) ;;
          esac
          reply delete "$res"
          /usr/bin/mu300-sms-refresh >/dev/null 2>&1
        else
          reply delete '缺少 index'
        fi ;;
      forward-test)
        /usr/bin/mu300-sms-forward > /tmp/mu300-sms-fwd.out 2>&1
        sleep 3
        { echo "TIME: $(date '+%Y-%m-%d %H:%M:%S')"; echo 'ACTION: forward-test'; echo '---'; cat /tmp/mu300-sms-fwd.out /tmp/mu300-sms-forward.log 2>/dev/null | tail -20; } > $OUT
        ;;
      refresh)
        /usr/bin/mu300-sms-refresh >/dev/null 2>&1
        reply refresh '已刷新' ;;
      *) reply '?' "未知动作: $action" ;;
    esac
  fi
  # 每 3 分钟主动刷一次收件箱(防止 sms watch 因重启/priming 漏消息)
  RNOW=$(date +%s)
  if [ -z "$RLAST" ]; then RLAST=0; fi
  if [ $((RNOW - RLAST)) -ge 180 ]; then
    RLAST=$RNOW
    /usr/bin/mu300-sms-refresh >/dev/null 2>&1
  fi
  sleep 2
done