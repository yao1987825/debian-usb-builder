#!/usr/bin/env bash
#
# test-music-cli.sh —— music 命令行的回归测试
#
# 重点防住 "参数被 shift 吃掉" 这类 bug:
#   case 分支已经 shift 掉子命令名, cmd_single / cmd_search 内部就绝不能再 shift,
#   否则 "music single 周杰伦 夜曲 --list" 会变成 "music single --list",
#   关键词丢失, 搜不到任何东西, 而且不报错 —— 非常难发现。
#
# 用法:
#   bash scripts/test-music-cli.sh
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# MUSIC_BIN 可以指向镜像里已安装的那份, 用来验证"产物里的脚本"而不是仓库里的
MUSIC_BIN="${MUSIC_BIN:-${REPO_DIR}/overlay/usr/local/bin/music}"

PASS=0
FAIL=0
ok()  { printf '  \033[1;32m✅\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  \033[1;31m❌\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

[[ -f "$MUSIC_BIN" ]] || { echo "找不到 music 脚本: ${MUSIC_BIN}" >&2; exit 1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ---- 造一套假的运行环境 ----
# 1) 假的 mountpoint: 永远返回 0, 让歌曲分区预检通过
mkdir -p "$TMP/bin" "$TMP/home/.venvs/music/bin" "$TMP/songdisk" "$TMP/project"
cat > "$TMP/bin/mountpoint" <<'EOF'
#!/bin/sh
exit 0
EOF
# 2) 假的 venv python: 原样打印收到的参数
cat > "$TMP/home/.venvs/music/bin/python" <<'EOF'
#!/bin/sh
printf '%s\n' "$@"
EOF
# 3) 假的 single.py: 只占位, 不会被真的执行
: > "$TMP/single.py"
# 4) 假的 quark_login.py: 同样只占位, 用来验证"参数有没有原样透传过去"
: > "$TMP/quark_login.py"
chmod +x "$TMP/bin/mountpoint" "$TMP/home/.venvs/music/bin/python"

export PATH="$TMP/bin:$PATH"
export HOME="$TMP/home"
export SONG_DIR="$TMP/songdisk"
export VENV_MUSIC="$TMP/home/.venvs/music"
export SINGLE_PY="$TMP/single.py"
export QUARK_PY="$TMP/quark_login.py"

run_music() { bash "$MUSIC_BIN" "$@"; }

echo "== music 命令行参数传递测试"

# ---- 1. single 必须把关键词原样传下去 ----
out="$(run_music single "周杰伦 夜曲" --list)"
expected="$TMP/single.py
周杰伦 夜曲
--list"
if [[ "$out" == "$expected" ]]; then
  ok "single 保留关键词与选项: [$(echo "$out" | tr '\n' ' ')]"
else
  bad "single 参数被改动"
  printf '       期望: %s\n' "$(echo "$expected" | tr '\n' ' ')"
  printf '       实际: %s\n' "$(echo "$out" | tr '\n' ' ')"
fi

# ---- 2. single --index 必须保留 ----
out="$(run_music single "夜曲" --index 2)"
if [[ "$out" == "$TMP/single.py
夜曲
--index
2" ]]; then
  ok "single 保留 --index 参数"
else
  bad "single --index 参数被改动: [$(echo "$out" | tr '\n' ' ')]"
fi

# ---- 3. search 等价于 single --list ----
out="$(run_music search "夜曲")"
if [[ "$out" == "$TMP/single.py
夜曲
--list" ]]; then
  ok "search 追加 --list 且保留关键词"
else
  bad "search 参数被改动: [$(echo "$out" | tr '\n' ' ')]"
fi

# ---- 4. 缺关键词时要报用法, 而不是把 --list 当关键词 ----
set +e
out="$(run_music single --list 2>&1)"
rc=$?
set -e
if (( rc == 2 )); then
  ok "缺少关键词时返回 2 并打印用法"
else
  bad "缺少关键词时退出码是 ${rc}(期望 2): [$(echo "$out" | tr '\n' ' ')]"
fi

# ---- 5. 别名 download / dl 与 single 等价 ----
out="$(run_music download "五月天" --list)"
if [[ "$out" == "$TMP/single.py
五月天
--list" ]]; then
  ok "download 别名与 single 行为一致"
else
  bad "download 别名参数被改动: [$(echo "$out" | tr '\n' ' ')]"
fi

# ---- 6. doctor / out / which 不应崩 ----
if run_music doctor >/dev/null 2>&1; then ok "doctor 正常退出"; else bad "doctor 执行失败"; fi
if [[ "$(run_music out)" == "$SONG_DIR" ]]; then ok "out 打印歌曲分区路径"; else bad "out 输出不对"; fi
if run_music which >/dev/null 2>&1; then ok "which 正常退出"; else bad "which 执行失败"; fi

# ---- 7. 夸克登录的参数透传 ----
# 这一组是照着真机上真出过的 bug 写的: 壳子里 sub 参数被 shift 掉之后,
# 剩下的 --help / --url-only 这类以 - 开头的选项要重新拼回去, 否则用户
# 打 `music quark --help` 会被当成"直接开始登录"。
out="$(run_music quark-login --url-only --timeout 120)"
if [[ "$out" == "$TMP/quark_login.py
--url-only
--timeout
120" ]]; then
  ok "quark-login 透传 --url-only 与 --timeout"
else
  bad "quark-login 参数被改动: [$(echo "$out" | tr '\n' ' ')]"
fi

out="$(run_music quark --help)"
if [[ "$out" == "$TMP/quark_login.py
--help" ]]; then
  ok "music quark --help 透传 --help(不会误触发登录)"
else
  bad "music quark --help 被吃掉了: [$(echo "$out" | tr '\n' ' ')]"
fi

out="$(run_music quark-status)"
if [[ "$out" == "$TMP/quark_login.py
--status" ]]; then
  ok "quark-status 转成 --status"
else
  bad "quark-status 参数不对: [$(echo "$out" | tr '\n' ' ')]"
fi

out="$(run_music quark-clear)"
if [[ "$out" == "$TMP/quark_login.py
--clear" ]]; then
  ok "quark-clear 转成 --clear"
else
  bad "quark-clear 参数不对: [$(echo "$out" | tr '\n' ' ')]"
fi

set +e
out="$(run_music quark 不存在的子命令 2>&1)"; rc=$?
set -e
if (( rc == 2 )); then
  ok "未知 quark 子命令返回 2"
else
  bad "未知 quark 子命令退出码是 ${rc}(期望 2)"
fi

echo
if (( FAIL == 0 )); then
  echo "✅ 全部 ${PASS} 项通过"
  exit 0
else
  echo "❌ ${FAIL} 项失败(共 ${PASS} 项通过)"
  exit 1
fi
