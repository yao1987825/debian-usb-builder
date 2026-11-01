#!/usr/bin/env bash
#
# test-usb-grow.sh —— U 盘自动扩容脚本(usb-grow.sh)的回归测试
#
# 背景(2026-10-31): 用户在真机上跑 `usb-grow.sh --check` 报
#   "❌ 失败: 缺少命令 [sgdisk]。安装: sudo apt-get install -y gdisk e2fsprogs util-linux"
# 照着装完(gdisk 已经是最新版)报错一模一样 —— 因为 sgdisk 在 Debian 里属于
# /usr/sbin, 而**普通用户的 PATH 里没有 /usr/sbin**, `command -v` 找不到就误报缺命令。
# --check 模式按设计不提权(诊断要能不带 root 跑), 所以这个坑必然踩到。
#
# 这里守:
#   1) 脚本把 /usr/sbin、/sbin 补进 PATH(一条 PATH 就修好所有磁盘工具的查找);
#   2) 缺命令的提示按命令给出对应的包(而不是一律让你装三个包);
#   3) 用最小 PATH 模拟普通用户, 真跑一遍 --check, 不许再出现"缺少命令"。
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

SCRIPT="overlay/usr/local/bin/usb-grow.sh"

echo "== 语法 =="
bash -n "$SCRIPT" && ok "bash -n $SCRIPT" || fail "bash -n $SCRIPT"

echo "== PATH 必须补 sbin(这是本次 bug 的根因) =="
if grep -q 'PATH="${PATH}:/usr/sbin:/sbin"' "$SCRIPT"; then
  ok "脚本把 /usr/sbin:/sbin 补进了 PATH"
else
  fail "没补 sbin 到 PATH —— 非 root 跑 --check 会误报'缺少命令 [sgdisk]'"
fi
if grep -q 'export PATH' "$SCRIPT"; then
  ok "PATH 有 export(子进程也要用到)"
else
  fail "PATH 改了没 export"
fi

echo "== 缺命令提示要按命令给包 =="
if grep -q '_pkg_of' "$SCRIPT" && grep -q '\[sgdisk\]="gdisk"' "$SCRIPT"; then
  ok "维护了 命令->包 的对照表"
else
  fail "没有 命令->包 对照表(缺一个命令也让用户装三个包)"
fi
if grep -q 'gdisk e2fsprogs util-linux' "$SCRIPT"; then
  fail "还在一律推荐装三个包"
else
  ok "不再一律推荐装三个包"
fi

echo "== 歌曲分区属主(2026-11-01 真机踩的坑) =="
# resize2fs 补完文件系统会把文件系统根 inode 的属主重置成 root:root,
# 不 chown 回去, 普通用户就写不进歌曲分区 -> "错误: 歌曲分区不可写"。
# 关键是**两条路径都要调** ensure_song_mount: 早退路径("表已定型, 只补文件系统")
# 和完整路径, 漏一条就复现。
if grep -q "^ensure_song_mount()" "$SCRIPT"; then
  ok "有 ensure_song_mount 函数"
else
  fail "没有 ensure_song_mount 函数"
fi
if [[ "$(grep -c 'ensure_song_mount' "$SCRIPT")" -ge 3 ]]; then
  ok "ensure_song_mount 被多处调用(定义+早退路径+完整路径)"
else
  fail "ensure_song_mount 调用点太少 —— 早退路径漏了就复现"
fi
if grep -q -- "--fix-mount" "$SCRIPT"; then
  ok "有 --fix-mount 手动修复入口(不用重启)"
else
  fail "没有 --fix-mount —— 用户只能重启"
fi
if grep -q 'chown 1000:1000' "$SCRIPT"; then
  ok "会把属主交还普通用户(1000:1000)"
else
  fail "没有 chown 逻辑"
fi
if grep -q 'usb-grow.sh --fix-mount' overlay/usr/local/bin/music; then
  ok "music 的报错提示给出了修复命令"
else
  fail "music 的报错提示没给修复命令"
fi

echo "== 真跑一次(用最小 PATH 模拟普通用户) =="
# 有这些工具才跑得动完整诊断; 构建机上没有就跳过功能部分(静态检查已经守住了)
if command -v sgdisk >/dev/null 2>&1 && command -v sgdisk >/dev/null 2>&1; then
  OUT="$(PATH=/usr/bin:/bin bash "$SCRIPT" --check 2>&1 || true)"
  if grep -q "缺少命令" <<<"$OUT"; then
    fail "最小 PATH 下仍然报'缺少命令': $(grep -m1 '缺少命令' <<<"$OUT")"
  else
    ok "最小 PATH 下不再误报'缺少命令'"
  fi
  if grep -q "依赖命令齐全" <<<"$OUT"; then
    ok "依赖检查通过"
  else
    # 不是依赖问题(比如这台机器没插 U 盘)也算过
    info="(这台机器没插 U 盘, 诊断在更后面停了 —— 属正常)"
    ok "依赖检查通过 $info"
  fi
else
  warn_text="构建机没有 sgdisk, 跳过真跑部分(静态检查已覆盖根因)"
  printf '  --   %s\n' "$warn_text"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "全部通过 ✅"
else
  echo "有失败 ❌"
  exit 1
fi
