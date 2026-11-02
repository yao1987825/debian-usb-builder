#!/usr/bin/env bash
#
# test-rime-config.sh —— Rime(中文输入法)配置的集成回归测试
#
# 背景(2026-11-02 真机实测): 镜像里 Rime 的功能性配置**一个都没生效**。
#
# 根因: Rime 启动时先加载 ".default" 方案(编译后的 build/default.yaml),
# 然后由 Switcher 按 schema_list 切到真正在用的 luna_pinyin_simp;
# 切换之后引擎读的是**切换后**那个方案的配置。
# 而 Shift 切中英文、候选词数量、自定义词库全都写在 default.custom.yaml 里 ——
# 那些补丁留在没人用的 ".default" 方案里, 一个都不生效。
#
# 构建期的断言查的也是 default.custom.yaml, 所以"断言一直过、真机上一个都不生效"。
# 这类 bug 光靠"文件在不在"永远发现不了, 必须守"配置写在哪个文件里"。
#
# 这里守:
#   1) 功能性配置写在**活动方案**的补丁文件 luna_pinyin_simp.custom.yaml 里;
#   2) default.custom.yaml 只留 schema_list(不给它加功能配置);
#   3) Shift 用扁平键写法("ascii_composer/switch_key/Shift_L": inline_ascii),
#      不是给整个键赋字符串;
#   4) 自定义词库挂成副词库(translator/packs: [user]), 不是拼在
#      translator/dictionary 里(librime 1.8.5 会把后者当成**一个**词典名);
#   5) 词库文件格式对: 有 "..." 结束标记、词条是"词<TAB>音节"、不用 entries:;
#   6) 构建期断言查的是活动方案那一份, 不是 default.custom.yaml。
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

RIME_DIR="overlay/home/user/.local/share/fcitx5/rime"
DEF_CFG="${RIME_DIR}/default.custom.yaml"
SCHEMA_CFG="${RIME_DIR}/luna_pinyin_simp.custom.yaml"
DICT="${RIME_DIR}/user.dict.yaml"

echo "== 文件齐全 =="
[[ -f "$DEF_CFG" ]] && ok "default.custom.yaml 在 Rime 用户目录里" \
  || fail "缺 ${DEF_CFG}(必须放在 ~/.local/share/fcitx5/rime/, 放 ~/.config 下 Rime 不看)"
[[ -f "$SCHEMA_CFG" ]] && ok "luna_pinyin_simp.custom.yaml 在 Rime 用户目录里" \
  || fail "缺 ${SCHEMA_CFG} —— 活动方案的配置全靠它, 缺了等于没配"
[[ -f "$DICT" ]] && ok "user.dict.yaml 在 Rime 用户目录里" \
  || fail "缺 ${DICT}"

echo "== 活动方案的补丁(这才是真正生效的那一份) =="
if grep -qE 'ascii_composer/switch_key/(Shift_L|Shift_R)"?: inline_ascii' "$SCHEMA_CFG" 2>/dev/null; then
  ok "Shift 切中英文用扁平键写在活动方案里"
elif grep -q 'ascii_composer/switch_key' "$SCHEMA_CFG" 2>/dev/null; then
  fail "ascii_composer 写成了字符串而不是 键->动作 映射, Shift 永远不会生效"
else
  fail "活动方案里没配 Shift 切中英文"
fi
grep -q 'ascii_composer/good_old_caps_lock' "$SCHEMA_CFG" 2>/dev/null \
  && ok "另配了 CapsLock 切换键" || fail "没配 CapsLock 切换键"
grep -q '"menu/page_size"' "$SCHEMA_CFG" 2>/dev/null \
  && ok "候选词数量配在活动方案里" || fail "候选词数量没配在活动方案里"

echo "== default.custom.yaml 不许再放功能配置 =="
if grep -q 'ascii_composer\|"menu/page_size"\|"translator/' "$DEF_CFG" 2>/dev/null; then
  fail "default.custom.yaml 里还有功能配置 —— 这些补丁落在没人用的 '.default' 方案里, 不会生效"
else
  ok "default.custom.yaml 里没有功能配置"
fi
grep -q 'schema: luna_pinyin_simp' "$DEF_CFG" 2>/dev/null \
  && ok "schema_list 锁定了简体方案 luna_pinyin_simp" || fail "schema_list 没锁定简体方案"

echo "== 自定义词库的挂法 =="
grep -q '"translator/packs"' "$SCHEMA_CFG" 2>/dev/null \
  && ok "词库挂成副词库(translator/packs)" \
  || fail "没有 translator/packs —— 词库挂不上去"
if awk '/"translator\/packs"/ {getline; gsub(/^[ \t]+|[ \t]+$/,""); sub(/^-[ \t]*/,""); print; exit}' "$SCHEMA_CFG" 2>/dev/null | grep -qx 'user'; then
  ok "packs 里就是 user"
else
  fail "packs 里不是 user"
fi
# 反向检查: 不能把词库拼进 translator/dictionary —— librime 1.8.5 会当成一个词典名,
# 找不到 "luna_pinyin user.dict.yaml", 整个方案部署直接失败。
if grep -qE '"translator/dictionary"[^"]*user' "$SCHEMA_CFG" "$DEF_CFG" 2>/dev/null; then
  fail "把 user 拼进了 translator/dictionary —— librime 1.8.5 会当成一个词典名, 部署必挂"
else
  ok "没有把 user 拼进 translator/dictionary"
fi

echo "== 词库文件格式(Rime 读 .dict.yaml 的规矩) =="
grep -qx '\.\.\.' "$DICT" 2>/dev/null \
  && ok "有 YAML 结束标记 '...'" \
  || fail "缺 '...' 结束标记 —— Rime 会把整个文件当 YAML 读, 词条一条都上不了屏"
if grep -qE '^\s*entries:' "$DICT" 2>/dev/null; then
  fail "用了 entries: 的 YAML 写法 —— Rime 的词库读取器不认"
else
  ok "没用 entries: 的 YAML 写法"
fi
# 词条必须排在 "..." 之后, 且是"词<TAB>音节"
_awk_entries='!/^[[:space:]]*#/ && NF>=2 && $1 !~ /^[[:space:]]/ {n++} END {print n+0}'
_entries="$(awk -F'\t' "$_awk_entries" "$DICT" 2>/dev/null)"
[[ "${_entries:-0}" -ge 50 ]] \
  && ok "认出 ${_entries} 条词条(>=50)" \
  || fail "只认出 ${_entries:-0} 条词条 —— 词条格式或位置不对"
# "..." 之后必须还有词条
_after="$(awk -F'\t' '/^\.\.\.$/{seen=1; next} seen && !/^[[:space:]]*#/ && NF>=2 && $1 !~ /^[[:space:]]/ {n++} END {print n+0}' "$DICT" 2>/dev/null)"
[[ "${_after:-0}" -ge 50 ]] \
  && ok "词条都在 '...' 之后(${_after} 条)" \
  || fail "'...' 之后只有 ${_after:-0} 条词条 —— 词条写在了结束标记前面, Rime 读不到"

echo "== 构建期断言查的是活动方案那一份 =="
grep -q 'RIME_SCHEMA_CFG' scripts/build-image.sh \
  && ok "构建脚本定义了活动方案配置文件变量" \
  || fail "构建脚本没区分 default.custom.yaml 与活动方案配置"
grep -q 'luna_pinyin_simp.custom.yaml' scripts/verify-image.sh \
  && ok "verify-image.sh 也查活动方案那一份" \
  || fail "verify-image.sh 没查活动方案那一份"
grep -q 'translator/packs' scripts/build-image.sh \
  && ok "构建期断言了副词库挂法" || fail "构建期没断言副词库挂法"
grep -q 'user.dict.yaml' scripts/build-image.sh \
  && ok "构建期断言了词库文件" || fail "构建期没断言词库文件"

echo "== 文档 =="
grep -q 'luna_pinyin_simp.custom.yaml' README.md \
  && ok "README 里说明了配置文件放在活动方案那一份" \
  || fail "README 里没提 luna_pinyin_simp.custom.yaml"

echo
if [[ $FAIL -eq 0 ]]; then
  echo "全部通过 ✅"
else
  echo "有失败 ❌"
  exit 1
fi
