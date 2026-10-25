#!/usr/bin/env bash
#
# test-keyboard-shortcuts.sh —— 快捷键清理脚本的回归测试
#
# 背景(用户实测反馈, 2026-10-25): "无法打开 print 快捷键这样的警告提示"。
# XFCE 默认快捷键绑着一堆极简镜像里没装的程序(xfce4-screenshooter/thunar/
# xfce4-appfinder/orca…��, 按了会弹警告框。
# scripts/fix-keyboard-shortcuts.py 负责把这些失效绑定摘掉, 并下发
# 用户级覆盖(Print 截图键改绑 scrot、Super 方向键窗口操作)。
#
# 这里用假的 rootfs 目录跑一遍, 断言:
#   1. 指向缺失程序的绑定被摘干净
#   2. 还能用的绑定(xfce4-session-logout / exo-open --launch TerminalEmulator)保留
#   3. 摘掉的多行块(带 startup-notify 子属性)不会留下孤儿标签
#   4. 用户级覆盖文件内容正确
#   5. 再跑一次不会重复删(幂等)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXER="${SCRIPT_DIR}/fix-keyboard-shortcuts.py"

PASS=0
FAIL=0

ok()   { printf '  \033[1;32m✅\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[1;31m❌\033[0m %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ROOT="${TMP}/rootfs"
KSDIR="${ROOT}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
mkdir -p "$KSDIR" "${ROOT}/usr/bin" "${ROOT}/home/user"

# 假 rootfs: 只有这几个程序是"装上了"的
for _b in xfce4-terminal xkill xfce4-session-logout xfce4-display-settings exo-open; do
  : > "${ROOT}/usr/bin/${_b}"
  chmod +x "${ROOT}/usr/bin/${_b}"
done

cat > "${KSDIR}/xfce4-keyboard-shortcuts.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-keyboard-shortcuts" version="1.0">
  <property name="commands" type="empty">
    <property name="default" type="empty">
      <property name="&lt;Alt&gt;F1" type="string" value="xfce4-popup-applicationsmenu"/>
      <property name="&lt;Alt&gt;F2" type="string" value="xfce4-appfinder --collapsed">
        <property name="startup-notify" type="bool" value="true"/>
      </property>
      <property name="&lt;Primary&gt;&lt;Alt&gt;Delete" type="string" value="xfce4-session-logout"/>
      <property name="&lt;Primary&gt;&lt;Alt&gt;t" type="string" value="exo-open --launch TerminalEmulator"/>
      <property name="XF86WWW" type="string" value="exo-open --launch WebBrowser"/>
      <property name="Print" type="string" value="xfce4-screenshooter"/>
      <property name="&lt;Alt&gt;Print" type="string" value="xfce4-screenshooter -w"/>
      <property name="&lt;Shift&gt;Print" type="string" value="xfce4-screenshooter -r"/>
      <property name="&lt;Super&gt;e" type="string" value="thunar"/>
      <property name="&lt;Primary&gt;&lt;Alt&gt;f" type="string" value="thunar"/>
      <property name="&lt;Primary&gt;Escape" type="string" value="xfdesktop --menu"/>
      <property name="&lt;Primary&gt;&lt;Shift&gt;Escape" type="string" value="xfce4-taskmanager"/>
      <property name="&lt;Super&gt;r" type="string" value="xfce4-appfinder -c"/>
      <property name="&lt;Alt&gt;&lt;Super&gt;s" type="string" value="orca"/>
    </property>
  </property>
  <property name="xfwm4" type="empty">
    <property name="default" type="empty">
      <property name="&lt;Super&gt;Left" type="string" value="tile_left_key"/>
      <property name="&lt;Super&gt;Up" type="string" value="maximize_window_key"/>
      <property name="&lt;Alt&gt;Tab" type="string" value="cycle_windows_key"/>
      <property name="&lt;Primary&gt;F1" type="string" value="workspace_1_key"/>
    </property>
  </property>
</channel>
EOF

if ! python3 "$FIXER" "$ROOT" --home home/user --quiet; then
  bad "fix-keyboard-shortcuts.py 执行失败"
  printf '\n\033[1;31m❌ 快捷键清理脚本自测失败\033[0m\n' >&2
  exit 1
fi

KS="${KSDIR}/xfce4-keyboard-shortcuts.xml"
USER_XML="${ROOT}/home/user/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-keyboard-shortcuts.xml"

# 1) 失效绑定摘干净
_missing=0
for _bad in xfce4-screenshooter thunar xfce4-appfinder orca xfce4-taskmanager xfdesktop xfce4-popup-applicationsmenu WebBrowser; do
  if grep -q "$_bad" "$KS"; then
    bad "默认快捷键里还残留 ${_bad}"
    _missing=1
  fi
done
[[ $_missing -eq 0 ]] && ok "指向缺失程序的绑定全部摘掉"

# 1b) 键名带 XML 转义的(&lt;Super&gt;e)也要摘掉 —— 按值匹配才找得到
if grep -q 'value="thunar"' "$KS"; then
  bad "转义键名(&lt;Super&gt;e)的失效绑定没摘掉"
else
  ok "转义键名的失效绑定也摘掉了"
fi

# 1c) xfwm4 段里的动作名(tile_left_key 等)不是可执行文件, 绝不能被当成"没装"删掉
#     (踩过的坑: 误删了 60 条窗口操作绑定, 窗口快捷键全废)
_missing2=0
for _act in tile_left_key maximize_window_key cycle_windows_key workspace_1_key; do
  if ! grep -q "$_act" "$KS"; then
    bad "xfwm4 段的动作 ${_act} 被误删了"
    _missing2=1
  fi
done
[[ $_missing2 -eq 0 ]] && ok "xfwmm4 段的动作绑定一条没少(没被当成缺失程序删掉)"

# 2) 还能用的绑定保留
if grep -q 'xfce4-session-logout' "$KS" && grep -q 'exo-open --launch TerminalEmulator' "$KS"; then
  ok "还能用的绑定保留(注销 / 打开终端)"
else
  bad "把还能用的绑定也删了"
fi

# 3) 多行块没留下孤儿标签
if grep -q 'startup-notify' "$KS"; then
  bad "多行块删完留下了孤儿 startup-notify"
elif python3 -c "import xml.etree.ElementTree as ET,sys; ET.parse(sys.argv[1])" "$KS" 2>/dev/null; then
  ok "删完的 XML 依然合法(没留孤儿标签)"
else
  bad "处理后的默认快捷键文件不是合法 XML"
fi

# 4) 用户级覆盖
if [[ ! -f "$USER_XML" ]]; then
  bad "没写出用户级快捷键覆盖文件"
else
  if grep -q '/usr/local/bin/screenshot' "$USER_XML" \
     && grep -q 'tile_left_key' "$USER_XML" \
     && grep -q 'maximize_window_key' "$USER_XML"; then
    ok "用户级覆盖含截图键与窗口快捷键"
  else
    bad "用户级覆盖内容不对(缺截图键或窗口快捷键)"
  fi
fi

# 5) 幂等
_before="$(md5sum "$KS" | cut -d' ' -f1)"
python3 "$FIXER" "$ROOT" --home home/user --quiet
_after="$(md5sum "$KS" | cut -d' ' -f1)"
if [[ "$_before" == "$_after" ]]; then
  ok "再跑一次不重复删(幂等)"
else
  bad "第二次运行又改了文件(不幂等)"
fi

printf '\n'
if [[ $FAIL -eq 0 ]]; then
  printf '\033[1;32m✅ 全部 %d 项通过\033[0m\n' "$PASS"
  exit 0
fi
printf '\033[1;31m❌ %d 项失败\033[0m\n' "$FAIL" >&2
exit 1
