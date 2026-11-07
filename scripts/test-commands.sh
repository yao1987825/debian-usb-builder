#!/usr/bin/env bash
#
# test-commands.sh —— 镜像里"用户会敲的命令"的回归测试
#
# 背景(2026-11-02 审计): overlay/usr/local/bin 下有 23 个命令, 但只有 13 个
# 有回归测试覆盖。另外 10 个 —— 恰恰是**用户开机第一眼就会碰到的那批** ——
# 完全没有测试:
#
#   keyboard-fix  music-im-fix  net-doctor  net-rescue
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
CMDS=(keyboard-fix music-im-fix net-doctor net-rescue screen-fit
      terminal-keepalive terminal-new terminal-setup terminal-welcome help)

# 用户会在 AI 面前提到的命令(AGENTS.md 里必须列出来)
AI_VISIBLE=(keyboard-fix music-im-fix net-doctor net-rescue screen-fit
            terminal-keepalive terminal-welcome help)

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

echo "== 每个命令头部必须有一行简介(给 help 索引用) =="
# help 是运行时扫 /usr/local/bin、读头部 "# 名 —— 简介" 生成索引的,
# 没有静态清单 —— 所以"每个脚本都得有这行"就是索引质量的唯一兜底。
# 新脚本忘了写, 这里立刻红, 不会等用户在 help 里看到"(缺简介)"才发现。
for f in "${BIN_DIR}"/*; do
  [[ -f "$f" ]] || continue
  c="$(basename "$f")"
  if sed -n '2,12p' "$f" | grep -qE '^# .*—— '; then
    ok "${c} 有头部简介"
  else
    fail "${c} 头部缺 '# ${c} —— 简介' 行(help 索引会出空条目)"
  fi
done

echo "== 文本文件里不能有 NUL 字节 =="
# 真实踩过(2026-11-02): overlay/.../AGENTS.md 的尾部被写成"- `/e" + 350 个 NUL,
# 后面该有的内容全被截断了。文件大小看着差不多, git 正常提交,
# 所有"文件存在"类断言都还是绿的 —— 但 AI 读到的 AGENTS.md 少了半截。
# 而且 grep 会把这种文件当二进制, 排查时特别费劲。
_nul_bad=""
while IFS= read -r _f; do
  # bash 的 $'\x00' 是空串(变量里存不了 NUL), 所以不能用 grep 匹配 NUL。
  # 改用"去掉 NUL 后还剩多少字节"和"原文件多少字节"比 —— 不一样就说明有 NUL。
  if [[ "$(tr -d '\000' < "$_f" | wc -c)" != "$(wc -c < "$_f")" ]]; then
    _nul_bad="${_nul_bad} ${_f}"
  fi
done < <(find overlay -type f \
           \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' -o -name '*.json' \
              -o -name '*.sh' -o -name '*.py' -o -name '*.desktop' -o -name '*.conf' \
              -o -name '*.txt' -o -name '*.service' -o -name '*.list' \) \
           -not -path '*/__pycache__/*' 2>/dev/null)
if [[ -z "${_nul_bad}" ]]; then
  ok "overlay 文本文件里没有 NUL 字节"
else
  fail "这些文件里有 NUL 字节(内容被截断):${_nul_bad}"
fi

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

echo "== 代理功能必须已经删干净 =="
# v1.9.0 起镜像不再预置代理。删不干净的后果很具体:
# 只要 99-proxy.sh 还在, 每个终端都会自动 export http_proxy,
# 镜像自己的 train(12306)/travel(高德)/bus(公交) 就全连不上国内接口了
# (真机实测: bus 走代理 curl 直接 http=000, train 报"打不开余票页")。
if [[ ! -e "overlay/usr/local/bin/proxy" ]]; then
  ok "overlay 里没有 proxy 命令了"
else
  fail "overlay 里还有 proxy 命令 —— 代理功能没删干净"
fi
# 注意别去 grep "99-proxy.sh" 这个词 —— 构建脚本里还留着**断言**
# ("镜像里不该再有 99-proxy.sh"), 那正是我们要的。要查的是**生成**动作。
if grep -qE 'proxy --print-profile-d|> *\$\{ROOTFS\}/etc/profile\.d/99-proxy\.sh' scripts/build-image.sh; then
  fail "构建脚本还在生成 /etc/profile.d/99-proxy.sh —— 代理功能没删干净"
else
  ok "构建脚本不再生成 99-proxy.sh"
fi
if grep -qE 'PROXY_URL_DEFAULT' scripts/build-image.sh; then
  fail "构建脚本里还有 PROXY_URL_DEFAULT —— 代理功能没删干净"
else
  ok "构建脚本里没有 PROXY_URL_DEFAULT 了"
fi
if grep -q 'proxy status\|proxy on\|proxy off' overlay/home/user/.config/opencode/AGENTS.md; then
  fail "AGENTS.md 里还在教用户用 proxy 命令 —— 那个命令已经没了"
else
  ok "AGENTS.md 里不再提 proxy 命令"
fi
# 反过来: 镜像不管代理, 但用户自己 export 时, 走国内接口的工具必须能绕开
for _f in overlay/usr/local/bin/bus overlay/usr/local/lib/chenzhou_bus/client.py; do
  if grep -q 'http_proxy' "$_f"; then
    ok "$(basename "$_f") 里有忽略环境代理变量的护栏"
  else
    fail "$(basename "$_f") 没有忽略环境代理变量的护栏 —— 用户 export 一下就又坏了"
  fi
done

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
# --help 绝不能掉进修复模式(那里面有 apt-get 安装分支; 真机 2026-11-07 实测
# --help 会跑 8 秒的全量修复)。断言: 快速退出 + 只输出用法。
out="$(run_sandbox music-im-fix --help 2>&1)"
if [[ $? -eq 0 ]] && grep -q '用法' <<<"$out" && ! grep -qE '✅|❌|apt-get' <<<"$out"; then
  ok "music-im-fix --help 只输出用法, 没掉进修复模式"
else
  fail "music-im-fix --help 掉进了修复模式或没给用法"
fi

echo "== 行为: screenshot =="
# --help 不能真的去拍照(真机 2026-11-07: screenshot --help 触发了 scrot)。
out="$(run_sandbox screenshot --help 2>&1)"
if [[ $? -eq 0 ]] && grep -q '用法' <<<"$out" && ! grep -qiE 'scrot|截图失败' <<<"$out"; then
  ok "screenshot --help 只输出用法, 没真去拍照"
else
  fail "screenshot --help 真去拍照了或没给用法"
fi

echo "== 行为: net-doctor =="
# 注意: net-doctor 是诊断工具, 退出码有含义 —— 0 = 全部通过, 1 = **发现了问题**。
# 所以不能断言"退出码 0"(CI 的 runner 上本来就有一堆问题)。要断言的是:
# 它**跑完了**、把自检结果打出来了, 而且退出码落在 0/1 这个语义区间里。
# 跑到一半崩掉、或者被 timeout 杀掉, 才是真问题。
out="$(run_sandbox net-doctor)"
rc=$?
if ! grep -q '网络自检' <<<"$out"; then
  fail "net-doctor 没有输出自检结果(退出码 ${rc})"
elif [[ $rc -eq 0 || $rc -eq 1 ]]; then
  ok "net-doctor 跑完并输出自检结果(退出码 ${rc}: 0=全部通过 1=发现问题)"
else
  fail "net-doctor 退出码 ${rc} —— 不在 0/1 里, 中途崩了或被超时杀掉了"
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

echo "== 行为: help =="
# help 必须能在**没有 +x** 的工作区里跑(git mode 100644, 构建期才 chmod),
# 所以用 bash 直接拉起, 并把索引目录指到 overlay。
_sb_help() {  # _sb_help [参数...]
  HOME="${SB}/home" \
  HELP_BIN_DIR="$PWD/${BIN_DIR}" \
  PATH="/usr/bin:/bin" \
  timeout 20 bash "${BIN_DIR}/help" "$@" 2>&1
}
out="$(_sb_help)"
rc=$?
if [[ $rc -eq 0 ]] && grep -q "YAO\*OS 命令索引" <<<"$out" \
   && grep -qE '^  music ' <<<"$out" && grep -qE '^  bus ' <<<"$out"; then
  ok "help 列出全部命令(含 music/bus)"
else
  fail "help 列表不对(rc=${rc}): $(head -3 <<<"$out")"
fi
if grep -qE '\(无简介|\(缺简介' <<<"$out"; then
  fail "help 里有缺简介的条目(脚本头部没写简介)"
else
  ok "help 索引每条都带出简介"
fi
out="$(_sb_help music)"
rc=$?
if [[ $rc -eq 0 ]] && grep -q "用法" <<<"$out"; then
  ok "help <命令> 转发 --help"
else
  fail "help music 没转发成功(rc=${rc}): $(head -2 <<<"$out")"
fi
out="$(_sb_help nosuchcmd)"
rc=$?
if [[ $rc -ne 0 ]] && grep -q "没有叫" <<<"$out"; then
  ok "help <不存在的命令> 明确报错"
else
  fail "help nosuchcmd 没有明确报错(rc=${rc})"
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
