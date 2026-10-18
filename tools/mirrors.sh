#!/bin/sh
# 交互式软件源镜像切换工具
# 兼容 opkg (24.10 及更早) 和 apk (25.12 及更新)

show_menu() {
  echo ""
  echo "========== 选择软件源镜像 =========="
  echo "1) 官方 ImmortalWrt (downloads.immortalwrt.org)"
  echo "2) 自定义镜像  (dl-esa-cn-1-immortalwrt.3284123.xyz)"
  echo "3) 中科大 USTC   (mirrors.ustc.edu.cn)"
  echo "4) 清华 TUNA    (mirrors.tuna.tsinghua.edu.cn)"
  echo "5) 阿里云        (mirrors.aliyun.com)"
  echo "6) 腾讯云        (mirrors.cloud.tencent.com)"
  echo "7) vsean         (mirrors.vsean.net)"
  echo "===================================="
}

select_mirror() {
  case "$1" in
    1) MIRROR="https://downloads.immortalwrt.org"; PREFIX="" ;;
    2|"") MIRROR="https://dl-esa-cn-1-immortalwrt.3284123.xyz"; PREFIX="" ;;
    3) MIRROR="https://mirrors.ustc.edu.cn"; PREFIX="/immortalwrt" ;;
    4) MIRROR="https://mirrors.tuna.tsinghua.edu.cn"; PREFIX="/immortalwrt" ;;
    5) MIRROR="https://mirrors.aliyun.com"; PREFIX="/openwrt" ;;
    6) MIRROR="https://mirrors.cloud.tencent.com"; PREFIX="/immortalwrt" ;;
    7) MIRROR="https://mirrors.vsean.net"; PREFIX="/openwrt" ;;
    *) echo "无效选择，使用自定义镜像 (2)" ; MIRROR="https://dl-esa-cn-1-immortalwrt.3284123.xyz"; PREFIX="" ;;
  esac
}

replace_mirror() {
  f="$1"
  t="$1.tmp"
  # 替换前备份 (仅首次)
  bak="${f}.bak"
  [ -f "$f" ] && [ ! -f "$bak" ] && cp "$f" "$bak"
  # 先用占位符 __M__ 替换所有远端 URL (避免结果被后续匹配再次替换)
  # 已知镜像路径前缀 /openwrt, /immortalwrt, /lede 会被去除
  if sed -r \
       -e "s@https?://[^/]+(/openwrt|/immortalwrt|/lede)?/@__M__@g" \
       -e "s@__M__@${MIRROR}${PREFIX}/@g" \
       "$f" > "$t" 2>/dev/null; then
    :
  else
    # busybox 不支持 -r 时回退：多次匹配但不重复处理
    sed \
      -e "s@https\?://[^/]*/openwrt/@__M__@g" \
      -e "s@https\?://[^/]*/immortalwrt/@__M__@g" \
      -e "s@https\?://[^/]*/lede/@__M__@g" \
      -e "s@https\?://[^/]*/@__M__@g" \
      -e "s@__M__@${MIRROR}${PREFIX}/@g" \
      "$f" > "$t"
  fi
  mv "$t" "$f" && echo "已更新: $f"
  rm -f "$t"
}

do_replace() {
  # opkg (24.10 及更早版本)
  for f in /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf; do
    [ -f "$f" ] && replace_mirror "$f"
  done

  # apk (25.12 及更新版本) — 优先处理 repositories.d/ 目录，兼容单文件 repositories
  if [ -d /etc/apk/repositories.d ]; then
    for f in /etc/apk/repositories.d/*.list; do
      [ -f "$f" ] && replace_mirror "$f"
    done
  elif [ -f /etc/apk/repositories ]; then
    replace_mirror /etc/apk/repositories
  fi

  echo ""
  echo "所有软件源已切换至: ${MIRROR}${PREFIX}"
}

# 支持命令行参数直接指定 (如: mirrors.sh 2)
if [ -n "$1" ]; then
  select_mirror "$1"
  do_replace
  exit 0
fi

# 交互模式
show_menu
printf "请输入序号 [2]: "
read choice
select_mirror "$choice"
do_replace
