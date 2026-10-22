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
chmod +x "$TMP/bin/mountpoint" "$TMP/home/.venvs/music/bin/python"

export PATH="$TMP/bin:$PATH"
export HOME="$TMP/home"
export SONG_DIR="$TMP/songdisk"
export VENV_MUSIC="$TMP/home/.venvs/music"
export SINGLE_PY="$TMP/single.py"

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

echo
if (( FAIL == 0 )); then
  echo "✅ 全部 ${PASS} 项通过"
  exit 0
else
  echo "❌ ${FAIL} 项失败(共 ${PASS} 项通过)"
  exit 1
fi
