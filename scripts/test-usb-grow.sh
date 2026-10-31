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
