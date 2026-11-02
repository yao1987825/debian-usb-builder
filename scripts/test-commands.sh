#!/usr/bin/env bash
#
# test-commands.sh —— 镜像里"用户会敲的命令"的回归测试
#
# 背景(2026-11-02 审计): overlay/usr/local/bin 下有 23 个命令, 但只有 13 个
# 有回归测试覆盖。另外 10 个 —— 恰恰是**用户开机第一眼就会碰到的那批** ——
# 完全没有测试:
#
#   keyboard-fix  music-im-fix  net-doctor  net-rescue  proxy
#   screen-fit    terminal-keepalive  terminal-new  terminal-setup  terminal-welcome
#
# 终端体系(keepalive/new/setup/welcome)尤其关键: 桌面上没有面板也没有图标,
# 用户关掉最后一个终端就只剩黑屏, 守护脚本是唯一的兜底 —— 它们坏了没人知道。
#
# 这里守:
#   1) 每个命令都存在、有 shebang、语法正确;
#   2) 每个命令都被构建期断言("文件在"这件事不能靠人记);
#   3) 每个命令都能在**沙箱**里跑出一个明确的结果:
#      要么按预期干活, 要么**明确报错** —— 不能静悄悄地什么都不干。
#      (静悄悄地什么都不干是最难查的一类问题。)
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

BIN_DIR="overlay/usr/local/bin"

# 这 10 个命令以前一个测试都没有
CMDS=(keyboard-fix music-im-fix net-doctor net-rescue proxy screen-fit
      terminal-keepalive terminal-new terminal-setup terminal-welcome)

# 用户会在 AI 面前提到的命令(AGENTS.md 里必须列出来)
AI_VISIBLE=(keyboard-fix music-im-fix net-doctor net-rescue proxy screen-fit
            terminal-keepalive terminal-welcome)

echo "== 文件与语法 =="
for c in "${CMDS[@]}"; do
  f="${BIN_DIR}/${c}"
  if [[ -f "$f" ]]; then
    ok "${c} 在 overlay 里"
  else
    fail "缺 ${f}"
    continue
  fi
  head -1 "$f" | grep -q '^#!.*bash' \
    && ok "${c} 有 bash shebang" || fail "${c} 没有 bash shebang"
  bash -n "$f" 2>/dev/null \
    && ok "${c} 语法正确" || fail "${c} 语法错误"
done

echo "== 构建期断言 =="
for c in "${CMDS[@]}"; do
  if grep -q "/usr/local/bin/${c}\"" scripts/build-image.sh \
     || grep -q "/usr/local/bin/${c}\\[\\]" scripts/build-image.sh \
     || grep -qE 'for _[a-z]+ in .*'"${c}" scripts/build-image.sh; then
    ok "构建脚本断言了 ${c}"
  else
    fail "构建脚本没断言 ${c}"
  fi
done

echo "== AGENTS.md 里提到用户会敲的命令 =="
for c in "${AI_VISIBLE[@]}"; do
  grep -q "$c" overlay/home/user/.config/opencode/AGENTS.md \
    && ok "AGENTS.md 提到了 ${c}" || fail "AGENTS.md 没提 ${c}"
done

# ---- 行为检查: 全部在沙箱里跑, 不碰真实系统 ----
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "${SB}/home" "${SB}/stub"

# 沙箱里的 HOME 与一个只有桩程序的 PATH:
#   xfce4-terminal —— terminal-new/setup 需要它, 桩程序记录调用参数;
#   xfconf-query  —— keyboard-fix/terminal-setup 用它改快捷键, 桩程序啥也不干。
cat > "${SB}/stub/xfce4-terminal" <<'STUB'
#!/bin/sh
echo "XFCE4-TERMINAL-CALLED $*" >> "${STUB_LOG}"
exit 0
STUB
cat > "${SB}/stub/xfconf-query" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "${SB}/stub/"*
export STUB_LOG="${SB}/stub.log"
: > "$STUB_LOG"

run_sandbox() {  # run_sandbox <命令> [参数...]
  local c="$1"; shift
  HOME="${SB}/home" \
  PATH="${SB}/stub:${PATH}" \
  STUB_LOG="$STUB_LOG" \
  timeout 20 bash "${BIN_DIR}/${c}" "$@" 2>&1
}

echo "== 行为: proxy =="
out="$(run_sandbox proxy --print-profile-d 'socks5://127.0.0.1:1080')"
if [[ -n "$out" ]] && printf '%s\n' "$out" | grep -q '127.0.0.1:1080'; then
  ok "proxy --print-profile-d 能生成模板且带着代理地址"
else
  fail "proxy --print-profile-d 没输出预期的模板"
fi
if printf '%s\n' "$out" | bash -n 2>/dev/null; then
  ok "proxy 生成的模板是合法 shell(/etc/profile.d 会 source 它)"
else
  fail "proxy 生成的模板语法错误 —— 一 source 整个登录就废"
fi

echo "== 行为: screen-fit =="
if run_sandbox screen-fit --self-test >/dev/null 2>&1; then
  ok "screen-fit --self-test 通过(EDID/xrandr 解析逻辑没坏)"
else
  fail "screen-fit --self-test 失败 —— 会匹配错分辨率"
fi

echo "== 行为: music-im-fix =="
if run_sandbox music-im-fix --check >/dev/null 2>&1; then
  ok "music-im-fix --check 能跑完(只检查不改)"
else
  fail "music-im-fix --check 失败"
fi

echo "== 行为: net-doctor =="
out="$(run_sandbox net-doctor)"
if [[ $? -eq 0 ]] && grep -q '网络自检' <<<"$out"; then
  ok "net-doctor 正常输出自检结果"
else
  fail "net-doctor 没有正常输出自检结果"
fi

echo "== 行为: net-rescue =="
out="$(run_sandbox net-rescue --help)"
if [[ $? -eq 0 ]] && grep -q '用法' <<<"$out"; then
  ok "net-rescue --help 有用法说明"
else
  fail "net-rescue --help 没给出用法"
fi

echo "== 行为: terminal-keepalive =="
out="$(run_sandbox terminal-keepalive --help)"
if [[ $? -eq 0 ]] && grep -q '用法' <<<"$out"; then
  ok "terminal-keepalive --help 有用法说明"
else
  fail "terminal-keepalive --help 没给出用法"
fi

echo "== 行为: terminal-new =="
: > "$STUB_LOG"
if run_sandbox terminal-new >/dev/null 2>&1; then
  ok "terminal-new 在有 xfce4-terminal 时能正常开标签页"
else
  fail "terminal-new 失败了"
fi
if grep -q 'XFCE4-TERMINAL-CALLED' "$STUB_LOG"; then
  ok "terminal-new 确实调用了 xfce4-terminal"
else
  fail "terminal-new 没调用 xfce4-terminal"
fi
# 没有 xfce4-terminal 时必须**明确失败**, 不能静悄悄地什么都不干
out="$(HOME="${SB}/home" PATH="/usr/bin:/bin" timeout 20 /bin/bash "${BIN_DIR}/terminal-new" 2>&1)"
rc=$?
if [[ $rc -ne 0 ]] && grep -qi 'xfce4-terminal' <<<"$out"; then
  ok "terminal-new 在缺 xfce4-terminal 时明确报错(不是静悄悄地不干活)"
else
  fail "terminal-new 缺 xfce4-terminal 时没有明确报错(rc=${rc})"
fi

echo "== 行为: terminal-setup =="
out="$(run_sandbox terminal-setup)"
if [[ $? -eq 0 ]]; then
  ok "terminal-setup 能跑完"
else
  fail "terminal-setup 跑失败了"
fi
out="$(HOME="${SB}/home" PATH="/usr/bin:/bin" timeout 20 /bin/bash "${BIN_DIR}/terminal-setup" 2>&1)"
rc=$?
if [[ $rc -ne 0 ]] && grep -q 'xfce4-terminal' <<<"$out"; then
  ok "terminal-setup 在缺 xfce4-terminal 时明确报错"
else
  fail "terminal-setup 缺 xfce4-terminal 时没有明确报错(rc=${rc})"
fi

echo "== 行为: terminal-welcome =="
if run_sandbox terminal-welcome >/dev/null 2>&1; then
  ok "terminal-welcome 能跑完"
else
  fail "terminal-welcome 跑失败了"
fi

echo "== 行为: keyboard-fix =="
if run_sandbox keyboard-fix >/dev/null 2>&1; then
  ok "keyboard-fix 能跑完(改快捷键失败也要静默, 不能把开机搞崩)"
else
  fail "keyboard-fix 跑失败了"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "全部通过 ✅"
else
  echo "有失败 ❌"
  exit 1
fi
